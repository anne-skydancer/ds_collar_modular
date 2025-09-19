/* =============================================================
   MODULE: ds_collar_kmod_acl.lsl  (HEADLESS)
   ROLE  : ACL policy engine (policies in Settings)
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[ACL] " + s); return 0; }

/* === DS Collar ABI & Lanes (CANONICAL) === */
integer ABI_VERSION   = 1;
integer L_API         = -1000;
integer L_BROADCAST   = -1001;
integer L_SETTINGS_IN = -1300;
integer L_AUTH_IN     = -1400;
integer L_ACL_IN      = -1500;
integer L_UI_BE_IN    = -1600;
integer L_UI_FE_IN    = -1700;
integer L_IDENTITY_IN = -1800;

/* Types */
string TYPE_SETTINGS_SUB        = "settings_sub";
string TYPE_SETTINGS_GET        = "settings_get"; 
string TYPE_SETTINGS_PUT        = "settings_put";
string TYPE_SETTINGS_SNAPSHOT   = "settings_snapshot";
string TYPE_SETTINGS_SYNC       = "settings_sync";
string TYPE_AUTH_QUERY          = "auth_query"; 
string TYPE_AUTH_RESULT         = "auth_result";
string TYPE_ACL_REGISTER        = "acl_register_feature";
string TYPE_ACL_REGISTER_ACK    = "acl_register_ack";
string TYPE_ACL_SET_POLICY      = "acl_set_policy"; 
string TYPE_ACL_SET_POLICY_ACK  = "acl_set_policy_ack";
string TYPE_ACL_QUERY           = "acl_query"; 
string TYPE_ACL_RESULT          = "acl_result";
string TYPE_ACL_FILTER          = "acl_filter";
string TYPE_ACL_FILTER_RESULT   = "acl_filter_result";
string TYPE_ERROR               = "error";

/* Registry & pending */
list    Registry;
integer REG_STRIDE = 3;

list    Pending;
integer PEND_STRIDE = 4;

list    PendingFilter;
integer PF_STRIDE = 4;

/* Helpers */
string lc(string s){ return llToLower(s); }

integer clamp_level(integer n){
    if (n < -1) return -1;
    if (n > 5) return 5;
    return n;
}

integer reg_index(string fid){
    integer i = 0;
    integer n = llGetListLength(Registry);
    while (i < n){
        if (llList2String(Registry, i) == fid) return i;
        i += REG_STRIDE;
    }
    return -1;
}

integer reg_set(string fid, integer defMin, integer effMin){
    integer i = reg_index(fid);
    if (i == -1){
        Registry += [fid, defMin, effMin];
    }
    else{
        Registry = llListReplaceList(Registry, [fid, defMin, effMin], i, i + REG_STRIDE - 1);
    }
    return TRUE;
}

integer reg_get_effective(string fid){
    integer i = reg_index(fid);
    if (i == -1) return 5;
    return llList2Integer(Registry, i + 2);
}

integer reg_get_default(string fid){
    integer i = reg_index(fid);
    if (i == -1) return 5;
    return llList2Integer(Registry, i + 1);
}

string policy_path(string fid){
    return "core.acl.policies." + lc(fid);
}

/* API send */
integer api_send(string type, string to, string reqId, list kv){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], type);
    j = llJsonSetValue(j, ["from"], "acl");
    j = llJsonSetValue(j, ["to"], to);
    if (reqId != "") j = llJsonSetValue(j, ["req_id"], reqId);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);

    integer i = 0;
    integer n = llGetListLength(kv);
    while (i + 1 < n){
        j = llJsonSetValue(j, [llList2String(kv, i)], llList2String(kv, i + 1));
        i += 2;
    }
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

integer settings_subscribe_core_acl(){
    return api_send(TYPE_SETTINGS_SUB, "settings", "acl-sub-core-acl", ["prefix", "core.acl."]);
}
integer settings_get_policy(string fid, string rid){
    string arr = llList2Json(JSON_ARRAY, [policy_path(fid)]);
    return api_send(TYPE_SETTINGS_GET, "settings", rid, ["paths", arr]);
}
integer settings_put_policy(string fid, integer minL, string rid){
    return api_send(TYPE_SETTINGS_PUT, "settings", rid,
        ["path", policy_path(fid), "vtype", "int", "value", (string)minL]);
}

integer send_register_ack(string toMod, string reqId, string fid, integer eff){
    return api_send(TYPE_ACL_REGISTER_ACK, toMod, reqId,
        ["feature_id", fid, "min_level", (string)eff]);
}
integer send_set_policy_ack(string toMod, string reqId, string fid, integer eff, integer rev){
    return api_send(TYPE_ACL_SET_POLICY_ACK, toMod, reqId,
        ["feature_id", fid, "min_level", (string)eff, "rev", (string)rev]);
}
integer send_error(string toMod, string reqId, string code, string message){
    return api_send(TYPE_ERROR, toMod, reqId, ["code", code, "message", message]);
}
integer send_acl_result(string toMod, string reqId, string fid, integer allowed, integer required, integer level){
    return api_send(TYPE_ACL_RESULT, toMod, reqId,
        ["feature_id", fid, "allowed", (string)allowed, "required", (string)required, "level", (string)level]);
}
integer send_acl_filter_result(string toMod, string reqId, integer level, list allowedL, list deniedL, list policiesPairs){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_ACL_FILTER_RESULT);
    j = llJsonSetValue(j, ["from"], "acl");
    j = llJsonSetValue(j, ["to"], toMod);
    j = llJsonSetValue(j, ["req_id"], reqId);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    j = llJsonSetValue(j, ["level"], (string)level);
    j = llJsonSetValue(j, ["allowed"], llList2Json(JSON_ARRAY, allowedL));
    j = llJsonSetValue(j, ["denied"], llList2Json(JSON_ARRAY, deniedL));

    string pol = llList2Json(JSON_OBJECT, []);
    integer i = 0;
    integer n = llGetListLength(policiesPairs);
    while (i + 1 < n){
        string k = llList2String(policiesPairs, i);
        string v = (string)llList2Integer(policiesPairs, i + 1);
        pol = llJsonSetValue(pol, [k], v);
        i += 2;
    }
    j = llJsonSetValue(j, ["policies"], pol);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* Apply overrides */
integer allowed_for_level(integer level, integer required){
    if (level >= required) return TRUE;
    return FALSE;
}
integer apply_override_value(string fid, string rawVal){
    integer idx = reg_index(fid);
    if (idx == -1) return FALSE;

    integer def = llList2Integer(Registry, idx + 1);
    integer eff = llList2Integer(Registry, idx + 2);

    integer hasOverride = FALSE;
    integer newMin = def;

    if (rawVal != JSON_INVALID && rawVal != JSON_NULL && rawVal != ""){
        newMin = (integer)rawVal;
        hasOverride = TRUE;
    }
    if (hasOverride) eff = clamp_level(newMin);
    else eff = def;

    Registry = llListReplaceList(Registry, [llList2String(Registry, idx), def, eff], idx, idx + REG_STRIDE - 1);
    logd("Policy " + fid + " eff=" + (string)eff);
    return TRUE;
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        Registry = [];
        Pending = [];
        PendingFilter = [];
        settings_subscribe_core_acl();
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_ACL_IN) return;
        string t = llJsonGetValue(msg, ["type"]);

        /* Snapshot */
        if (t == TYPE_SETTINGS_SNAPSHOT){
            string values = llJsonGetValue(msg, ["values"]);
            if (values != JSON_INVALID){
                integer i = 0;
                integer n = llGetListLength(Registry);
                while (i < n){
                    string fid = llList2String(Registry, i);
                    string p = policy_path(fid);
                    string metaV = llJsonGetValue(values, [p, "value"]);
                    if (metaV != JSON_INVALID) apply_override_value(fid, metaV);
                    i += REG_STRIDE;
                }
            }
            return;
        }

        /* Sync */
        if (t == TYPE_SETTINGS_SYNC){
            string changed_val = llJsonGetValue(msg, ["changed"]);
            if (changed_val != JSON_INVALID){
                integer i2 = 0;
                integer n2 = llGetListLength(Registry);
                while (i2 < n2){
                    string fid2 = llList2String(Registry, i2);
                    string p2 = policy_path(fid2);
                    string v = llJsonGetValue(changed_val, [p2]);
                    if (v != JSON_INVALID) apply_override_value(fid2, v);
                    i2 += REG_STRIDE;
                }
            }
            return;
        }

        /* Register */
        if (t == TYPE_ACL_REGISTER){
            string from = llJsonGetValue(msg, ["from"]);
            string rid  = llJsonGetValue(msg, ["req_id"]);
            string fid  = llJsonGetValue(msg, ["feature_id"]);
            integer def = (integer)llJsonGetValue(msg, ["default_min_level"]);

            if (fid == "" || llStringLength(fid) < 3){
                send_error(from, rid, "E_BADREQ", "missing feature_id");
                return;
            }

            def = clamp_level(def);
            integer idx = reg_index(fid);
            if (idx == -1){
                reg_set(fid, def, def);
            }
            else{
                integer oldDef = reg_get_default(fid);
                integer eff    = reg_get_effective(fid);
                if (oldDef != def) reg_set(fid, def, eff);
            }
            settings_get_policy(fid, "get-ovr-" + fid);
            send_register_ack(from, rid, fid, reg_get_effective(fid));
            return;
        }

        /* Set Policy */
        if (t == TYPE_ACL_SET_POLICY){
            string from = llJsonGetValue(msg, ["from"]);
            string rid  = llJsonGetValue(msg, ["req_id"]);
            string fid  = llJsonGetValue(msg, ["feature_id"]);
            integer minL = (integer)llJsonGetValue(msg, ["min_level"]);

            if (fid == "" || reg_index(fid) == -1){
                send_error(from, rid, "E_NOTFOUND", "unknown feature");
                return;
            }

            minL = clamp_level(minL);
            settings_put_policy(fid, minL, "put-ovr-" + fid);
            integer idx2 = reg_index(fid);
            if (idx2 != -1) reg_set(fid, llList2Integer(Registry, idx2 + 1), minL);
            send_set_policy_ack(from, rid, fid, reg_get_effective(fid), 0);
            return;
        }

        /* ACL Query */
        if (t == TYPE_ACL_QUERY){
            string from   = llJsonGetValue(msg, ["from"]);
            string rid    = llJsonGetValue(msg, ["req_id"]);
            string fid    = llJsonGetValue(msg, ["feature_id"]);
            string avatar = llJsonGetValue(msg, ["avatar"]);

            integer levelHas = FALSE;
            integer level    = 0;
            string lv = llJsonGetValue(msg, ["level"]);
            if (lv != JSON_INVALID && lv != ""){
                levelHas = TRUE;
                level = (integer)lv;
            }

            integer required = reg_get_effective(fid);
            if (!levelHas){
                Pending += [rid, from, fid, avatar];
                api_send(TYPE_AUTH_QUERY, "auth", rid, ["avatar", avatar]);
                return;
            }
            send_acl_result(from, rid, fid, allowed_for_level(level, required), required, level);
            return;
        }

        /* ACL Filter */
        if (t == TYPE_ACL_FILTER){
            string from   = llJsonGetValue(msg, ["from"]);
            string rid    = llJsonGetValue(msg, ["req_id"]);
            string avatar = llJsonGetValue(msg, ["avatar"]);
            string feats  = llJsonGetValue(msg, ["features"]);

            if (feats == JSON_INVALID){
                send_error(from, rid, "E_BADREQ", "missing features");
                return;
            }

            integer levelHas = FALSE;
            integer level    = 0;
            string lv2 = llJsonGetValue(msg, ["level"]);
            if (lv2 != JSON_INVALID && lv2 != ""){
                levelHas = TRUE;
                level = (integer)lv2;
            }

            if (!levelHas){
                PendingFilter += [rid, from, avatar, feats];
                api_send(TYPE_AUTH_QUERY, "auth", rid, ["avatar", avatar]);
                return;
            }

            list allowedL = [];
            list deniedL  = [];
            list polPairs = [];
            integer k = 0;
            integer done = FALSE;
            while (!done){
                string f = llJsonGetValue(feats, [(string)k]);
                if (f == JSON_INVALID){
                    done = TRUE;
                }
                else{
                    integer req = reg_get_effective(f);
                    polPairs += [f, req];
                    if (allowed_for_level(level, req)) allowedL += f;
                    else deniedL += f;
                    k += 1;
                }
            }
            send_acl_filter_result(from, rid, level, allowedL, deniedL, polPairs);
            return;
        }

        /* Auth Result */
        if (t == TYPE_AUTH_RESULT){
            string rid   = llJsonGetValue(msg, ["req_id"]);
            integer level = (integer)llJsonGetValue(msg, ["level"]);

            integer i = 0;
            integer n = llGetListLength(Pending);
            while (i < n){
                if (llList2String(Pending, i) == rid){
                    string toMod = llList2String(Pending, i + 1);
                    string fid   = llList2String(Pending, i + 2);
                    integer req  = reg_get_effective(fid);
                    send_acl_result(toMod, rid, fid, allowed_for_level(level, req), req, level);
                    Pending = llDeleteSubList(Pending, i, i + PEND_STRIDE - 1);
                    n = llGetListLength(Pending);
                }
                else{
                    i += PEND_STRIDE;
                }
            }

            integer j = 0;
            integer m = llGetListLength(PendingFilter);
            while (j < m){
                if (llList2String(PendingFilter, j) == rid){
                    string toMod = llList2String(PendingFilter, j + 1);
                    string feats = llList2String(PendingFilter, j + 3);

                    list allowedL = [];
                    list deniedL  = [];
                    list polPairs = [];
                    integer k2 = 0;
                    integer done2 = FALSE;

                    while (!done2){
                        string f2 = llJsonGetValue(feats, [(string)k2]);
                        if (f2 == JSON_INVALID){
                            done2 = TRUE;
                        }
                        else{
                            integer req2 = reg_get_effective(f2);
                            polPairs += [f2, req2];
                            if (allowed_for_level(level, req2)) allowedL += f2;
                            else deniedL += f2;
                            k2 += 1;
                        }
                    }
                    send_acl_filter_result(toMod, rid, level, allowedL, deniedL, polPairs);
                    PendingFilter = llDeleteSubList(PendingFilter, j, j + PF_STRIDE - 1);
                    m = llGetListLength(PendingFilter);
                }
                else{
                    j += PF_STRIDE;
                }
            }
            return;
        }
    }
}
