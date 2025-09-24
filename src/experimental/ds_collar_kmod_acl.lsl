/* =============================================================
 MODULE: ds_collar_kmod_acl.lsl (API-CONFORMANT + HARDENED + DEDUPE)
 ROLE  : ACL policy engine (reads Settings; queries AUTH)
 NOTES : - Unique req_id on settings_sub
         - One-shot subscribe guard
         - Dedupe in-flight req_ids so we never double-send auth_query
 ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[ACL] " + s); return 0; }

/* === ABI & Lanes === */
integer ABI_VERSION   = 1;
integer L_API         = -1000;

/* Types */
string T_SETTINGS_SUB        = "settings_sub";
string T_SETTINGS_GET        = "settings_get";
string T_SETTINGS_PUT        = "settings_put";
string T_SETTINGS_SNAPSHOT   = "settings_snapshot";
string T_SETTINGS_SYNC       = "settings_sync";
string T_SETTINGS_ACK        = "settings_ack";

string T_AUTH_QUERY          = "auth_query";
string T_AUTH_RESULT         = "auth_result";

string T_ACL_REGISTER        = "acl_register_feature";
string T_ACL_REGISTER_ACK    = "acl_register_ack";
string T_ACL_SET_POLICY      = "acl_set_policy";
string T_ACL_SET_POLICY_ACK  = "acl_set_policy_ack";
string T_ACL_QUERY           = "acl_query";
string T_ACL_RESULT          = "acl_result";
string T_ACL_FILTER          = "acl_filter";
string T_ACL_FILTER_RESULT   = "acl_filter_result";

string T_ERROR               = "error";

/* Registry & pending */
list    Registry;          integer REG_STRIDE = 3; // [fid, defaultMin, effectiveMin]
list    Pending;           integer PEND_STRIDE = 4; // [rid, toMod, fid, avatar]
list    PendingFilter;     integer PF_STRIDE   = 4; // [rid, toMod, avatar, featsJSON]

/* Subscribe guard */
integer gSubDone = FALSE;
string  gSubRid  = "";

/* ----------------- Helpers ----------------- */
string lc(string s){ return llToLower(s); }
integer clamp_level(integer n){ if (n < -1) return -1; if (n > 5) return 5; return n; }
integer is_uuid(string s){ key k = (key)s; if ((string)k == s) return TRUE; return FALSE; }
integer starts_with(string s, string p){ if (llSubStringIndex(s, p) == 0) return TRUE; return FALSE; }

/* allow letters, digits, underscore, dash, dot; min len 3 */
integer is_valid_fid(string fid){
    integer L = llStringLength(fid);
    if (L < 3) return FALSE;
    integer i = 0;
    while (i < L){
        string c = llGetSubString(fid, i, i);
        integer code = llOrd(c, 0);
        if (!(
            (code >= 65 && code <= 90) || (code >= 97 && code <= 122) ||
            (code >= 48 && code <= 57) || code == 95 || code == 45 || code == 46
        )) return FALSE;
        i += 1;
    }
    return TRUE;
}

integer reg_index(string fid){
    integer i = 0; integer n = llGetListLength(Registry);
    while (i < n){
        if (llList2String(Registry, i) == fid) return i;
        i += REG_STRIDE;
    }
    return -1;
}
integer reg_set(string fid, integer defMin, integer effMin){
    integer i = reg_index(fid);
    if (i == -1) Registry += [fid, defMin, effMin];
    else Registry = llListReplaceList(Registry, [fid, defMin, effMin], i, i + REG_STRIDE - 1);
    return TRUE;
}
integer reg_get_effective(string fid){ integer i = reg_index(fid); if (i == -1) return 5; return llList2Integer(Registry, i + 2); }
integer reg_get_default(string fid){ integer i = reg_index(fid); if (i == -1) return 5; return llList2Integer(Registry, i + 1); }
string policy_path(string fid){ return "core.acl.policies." + lc(fid); }

/* Dedupe guard */
integer has_pending_reqid(string rid){
    integer i = 0; integer n = llGetListLength(Pending);
    while (i < n){ if (llList2String(Pending, i) == rid) return TRUE; i += PEND_STRIDE; }
    integer j = 0; integer m = llGetListLength(PendingFilter);
    while (j < m){ if (llList2String(PendingFilter, j) == rid) return TRUE; j += PF_STRIDE; }
    return FALSE;
}

/* ------------- API send ------------- */
integer api_send(string type, string to, string rid, list kv){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], type);
    j = llJsonSetValue(j, ["from"], "acl");
    j = llJsonSetValue(j, ["to"], to);
    if (rid != "") j = llJsonSetValue(j, ["req_id"], rid);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    integer i = 0; integer n = llGetListLength(kv);
    while (i + 1 < n){
        j = llJsonSetValue(j, [llList2String(kv, i)], llList2String(kv, i + 1));
        i += 2;
    }
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* Shortcuts */
integer settings_subscribe_core_acl_once(){
    if (gSubDone) return TRUE;
    integer t = llGetUnixTime();
    integer r = (integer)llFrand(1e6);
    gSubRid = "acl-sub-core-acl-" + (string)t + "-" + (string)r;
    return api_send(T_SETTINGS_SUB, "settings", gSubRid, ["prefix", "core.acl."]);
}
integer settings_get_policy(string fid, string rid){
    string arr = llList2Json(JSON_ARRAY, [policy_path(fid)]);
    return api_send(T_SETTINGS_GET, "settings", rid, ["paths", arr]);
}
integer settings_put_policy(string fid, integer minL, string rid){
    return api_send(T_SETTINGS_PUT, "settings", rid, ["path", policy_path(fid), "vtype", "int", "value", (string)minL]);
}
integer send_register_ack(string toMod, string rid, string fid, integer eff){
    return api_send(T_ACL_REGISTER_ACK, toMod, rid, ["feature_id", fid, "min_level", (string)eff]);
}
integer send_set_policy_ack(string toMod, string rid, string fid, integer eff, integer rev){
    return api_send(T_ACL_SET_POLICY_ACK, toMod, rid, ["feature_id", fid, "min_level", (string)eff, "rev", (string)rev]);
}
integer send_error(string toMod, string rid, string code, string message){
    return api_send(T_ERROR, toMod, rid, ["code", code, "message", message]);
}
integer send_acl_result(string toMod, string rid, string fid, integer allowed, integer required, integer level){
    return api_send(T_ACL_RESULT, toMod, rid, ["feature_id", fid, "allowed", (string)allowed, "required", (string)required, "level", (string)level]);
}
integer send_acl_filter_result(string toMod, string rid, integer level, list allowedL, list deniedL, list policiesPairs){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], T_ACL_FILTER_RESULT);
    j = llJsonSetValue(j, ["from"], "acl");
    j = llJsonSetValue(j, ["to"], toMod);
    j = llJsonSetValue(j, ["req_id"], rid);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    j = llJsonSetValue(j, ["level"], (string)level);
    j = llJsonSetValue(j, ["allowed"], llList2Json(JSON_ARRAY, allowedL));
    j = llJsonSetValue(j, ["denied"], llList2Json(JSON_ARRAY, deniedL));
    string pol = llList2Json(JSON_OBJECT, []);
    integer i = 0; integer n = llGetListLength(policiesPairs);
    while (i + 1 < n){
        string k = llList2String(policiesPairs, i);
        string v = (string)llList2Integer(policiesPairs, i + 1);
        pol = llJsonSetValue(pol, [k], v);
        i += 2;
    }
    j = llJsonSetValue(j, ["policies"], pol);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    logd("→ acl_filter_result rid=" + rid + " level=" + (string)level +
         " allowed=" + (string)llGetListLength(allowedL) +
         " denied="  + (string)llGetListLength(deniedL));
    return TRUE;
}

/* Apply overrides (from Settings) */
integer apply_override_value(string fid, string rawVal){
    integer idx = reg_index(fid); if (idx == -1) return FALSE;
    integer def = llList2Integer(Registry, idx + 1);
    integer eff = llList2Integer(Registry, idx + 2);
    integer hasOverride = FALSE; integer newMin = def;

    if (rawVal != JSON_INVALID && rawVal != JSON_NULL && rawVal != ""){
        newMin = (integer)rawVal; hasOverride = TRUE;
    }
    if (hasOverride) eff = clamp_level(newMin); else eff = def;
    Registry = llListReplaceList(Registry, [llList2String(Registry, idx), def, eff], idx, idx + REG_STRIDE - 1);
    logd("Policy " + fid + " eff=" + (string)eff);
    return TRUE;
}

integer allowed_for_level(integer level, integer required){
    if (level >= required) return TRUE;
    return FALSE;
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        Registry = []; Pending = []; PendingFilter = [];
        gSubDone = FALSE; gSubRid = "";
        settings_subscribe_core_acl_once();
        logd("ACL up (ABI v1).");
    }
    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_API) return;

        string t   = llJsonGetValue(msg, ["type"]);
        string rid = llJsonGetValue(msg, ["req_id"]);
        string frm = llJsonGetValue(msg, ["from"]);
        string to  = llJsonGetValue(msg, ["to"]);
        integer abi = (integer)llJsonGetValue(msg, ["abi"]);
        if (abi == 0) abi = ABI_VERSION;
        if (abi != ABI_VERSION) return;
        if (t == "" || frm == "") return;

        /* subscribe ack recognition (one-shot) */
        if (t == T_SETTINGS_ACK && frm == "settings"){
            if (!gSubDone && rid != JSON_INVALID && rid == gSubRid){
                gSubDone = TRUE;
                logd("SUB acked rid=" + gSubRid);
            }else{
                logd("IGN settings_ack");
            }
            return;
        }

        /* drop diagnostics/control to avoid ping-pong */
        if (t == T_ERROR){ logd("IGN error from " + frm + " rid=" + (string)rid); return; }

        /* ---------- SETTINGS: snapshot/sync (trusted) ---------- */
        if (t == T_SETTINGS_SNAPSHOT || t == T_SETTINGS_SYNC){
            if (frm != "settings") return;

            if (t == T_SETTINGS_SNAPSHOT){
                string values = llJsonGetValue(msg, ["values"]);
                if (values != JSON_INVALID){
                    integer i = 0; integer n = llGetListLength(Registry);
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

            if (t == T_SETTINGS_SYNC){
                string changed_val = llJsonGetValue(msg, ["changed"]);
                if (changed_val != JSON_INVALID){
                    integer i2 = 0; integer n2 = llGetListLength(Registry);
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
        }

        /* ---------- AUTH RESULT (accept regardless of 'to') ---------- */
        if (t == T_AUTH_RESULT){
            if (frm != "auth") return;       // trusted sender only
            if (rid == "" || rid == JSON_INVALID) return;

            integer resolved = FALSE;

            /* Resolve ACL_QUERY pendings */
            integer i = 0; integer n = llGetListLength(Pending);
            while (i < n){
                if (llList2String(Pending, i) == rid){
                    resolved = TRUE;
                    string toMod = llList2String(Pending, i + 1);
                    string fid   = llList2String(Pending, i + 2);
                    integer level = (integer)llJsonGetValue(msg, ["level"]);
                    integer req = reg_get_effective(fid);
                    send_acl_result(toMod, rid, fid, allowed_for_level(level, req), req, level);
                    Pending = llDeleteSubList(Pending, i, i + PEND_STRIDE - 1);
                    n = llGetListLength(Pending);
                }else{
                    i += PEND_STRIDE;
                }
            }

            /* Resolve ACL_FILTER pendings */
            integer j = 0; integer m = llGetListLength(PendingFilter);
            while (j < m){
                if (llList2String(PendingFilter, j) == rid){
                    resolved = TRUE;
                    string toMod = llList2String(PendingFilter, j + 1);
                    string feats  = llList2String(PendingFilter, j + 3);
                    integer level2 = (integer)llJsonGetValue(msg, ["level"]);
                    list allowedL = []; list deniedL = []; list polPairs = [];
                    integer k2 = 0; integer done2 = FALSE;
                    while (!done2){
                        string f2 = llJsonGetValue(feats, [(string)k2]);
                        if (f2 == JSON_INVALID){ done2 = TRUE; }
                        else{
                            if (is_valid_fid(f2)){
                                integer req2 = reg_get_effective(f2);
                                polPairs += [f2, req2];
                                if (allowed_for_level(level2, req2)) allowedL += f2; else deniedL += f2;
                            }
                            k2 += 1;
                        }
                    }
                    send_acl_filter_result(toMod, rid, level2, allowedL, deniedL, polPairs);
                    PendingFilter = llDeleteSubList(PendingFilter, j, j + PF_STRIDE - 1);
                    m = llGetListLength(PendingFilter);
                }else{
                    j += PF_STRIDE;
                }
            }

            if (!resolved){
                logd("Dropping unsolicited auth_result rid=" + rid);
            }
            return;
        }

        /* ---------- REQUESTS TO ACL (must be explicitly addressed) ---------- */

        /* Register feature */
        if (t == T_ACL_REGISTER){
            if (to != "acl") return;
            if (rid == "" || rid == JSON_INVALID) return;

            string fid = llJsonGetValue(msg, ["feature_id"]);
            integer def = (integer)llJsonGetValue(msg, ["default_min_level"]);

            if (!is_valid_fid(fid)){ send_error(frm, rid, "E_BADREQ", "invalid feature_id"); return; }

            def = clamp_level(def);
            integer idx = reg_index(fid);
            if (idx == -1){ reg_set(fid, def, def); }
            else{
                integer oldDef = reg_get_default(fid);
                integer eff    = reg_get_effective(fid);
                if (oldDef != def) reg_set(fid, def, eff);
            }

            settings_get_policy(fid, "get-ovr-" + fid);
            send_register_ack(frm, rid, fid, reg_get_effective(fid));
            return;
        }

        /* Set Policy (this script does not call PUT on its own unless requested) */
        if (t == T_ACL_SET_POLICY){
            if (to != "acl") return;
            if (rid == "" || rid == JSON_INVALID) return;

            string fid  = llJsonGetValue(msg, ["feature_id"]);
            integer minL = (integer)llJsonGetValue(msg, ["min_level"]);

            if (!is_valid_fid(fid)){ send_error(frm, rid, "E_BADREQ", "invalid feature_id"); return; }
            if (reg_index(fid) == -1){ send_error(frm, rid, "E_NOTFOUND", "unknown feature"); return; }

            minL = clamp_level(minL);
            settings_put_policy(fid, minL, "put-ovr-" + fid); // only on explicit request
            integer idx2 = reg_index(fid);
            if (idx2 != -1) reg_set(fid, llList2Integer(Registry, idx2 + 1), minL);
            send_set_policy_ack(frm, rid, fid, reg_get_effective(fid), 0);
            return;
        }

        /* ACL Query */
        if (t == T_ACL_QUERY){
            if (to != "acl") return;
            if (rid == "" || rid == JSON_INVALID) return;

            string fid    = llJsonGetValue(msg, ["feature_id"]);
            string avatar = llJsonGetValue(msg, ["avatar"]);

            if (!is_valid_fid(fid)){ send_error(frm, rid, "E_BADREQ", "invalid feature_id"); return; }
            if (!is_uuid(avatar)){ send_error(frm, rid, "E_BADREQ", "invalid avatar uuid"); return; }

            integer levelHas = FALSE; integer level = 0;
            string lv = llJsonGetValue(msg, ["level"]);
            if (lv != JSON_INVALID && lv != ""){ levelHas = TRUE; level = (integer)lv; }

            integer required = reg_get_effective(fid);
            if (!levelHas){
                if (has_pending_reqid(rid)){ logd("dedupe: already pending rid=" + rid); return; }
                Pending += [rid, frm, fid, avatar];
                api_send(T_AUTH_QUERY, "auth", rid, ["avatar", avatar]);
                logd("→ auth_query rid=" + rid + " avatar=" + avatar);
                return;
            }
            send_acl_result(frm, rid, fid, allowed_for_level(level, required), required, level);
            return;
        }

        /* ACL Filter */
        if (t == T_ACL_FILTER){
            if (to != "acl") return;
            if (rid == "" || rid == JSON_INVALID) return;

            string avatar = llJsonGetValue(msg, ["avatar"]);
            string feats  = llJsonGetValue(msg, ["features"]);

            if (!is_uuid(avatar)){ send_error(frm, rid, "E_BADREQ", "invalid avatar uuid"); return; }
            if (feats == JSON_INVALID){ send_error(frm, rid, "E_BADREQ", "missing features"); return; }

            integer levelHas = FALSE; integer level = 0;
            string lv2 = llJsonGetValue(msg, ["level"]);
            if (lv2 != JSON_INVALID && lv2 != ""){ levelHas = TRUE; level = (integer)lv2; }

            if (!levelHas){
                if (has_pending_reqid(rid)){ logd("dedupe: already pending rid=" + rid); return; }
                PendingFilter += [rid, frm, avatar, feats];
                api_send(T_AUTH_QUERY, "auth", rid, ["avatar", avatar]);
                logd("→ auth_query (filter) rid=" + rid + " avatar=" + avatar);
                return;
            }

            list allowedL = []; list deniedL = []; list polPairs = [];
            integer k = 0; integer done = FALSE;
            while (!done){
                string f = llJsonGetValue(feats, [(string)k]);
                if (f == JSON_INVALID){ done = TRUE; }
                else{
                    if (is_valid_fid(f)){
                        integer req = reg_get_effective(f);
                        polPairs += [f, req];
                        if (allowed_for_level(level, req)) allowedL += f; else deniedL += f;
                    }
                    k += 1;
                }
            }
            send_acl_filter_result(frm, rid, level, allowedL, deniedL, polPairs);
            return;
        }

        /* ---------- Unknown ---------- */
        if (to == "acl"){
            if (rid == JSON_INVALID) rid = "";
            send_error(frm, rid, "E_BADREQ", "unknown type");
            logd("DENY unknown type '" + t + "' from " + frm + " rid=" + rid);
        }
        /* not for us → ignore */
    }
}
