/* =============================================================
   MODULE: ds_collar_api.lsl
   ROLE  : Canonical link-message router (ABI v1)
   ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[API] " + s); return 0; }

/* === DS Collar ABI & Lanes (CANONICAL) === */
integer ABI_VERSION   = 1;
integer L_API         = -1000;
integer L_UI_BE_IN    = -1600;
integer L_UI_FE_IN    = -1700;

/* Requests (must include req_id) */
integer IsRequest(string t){
    /* Settings */
    if (t == "settings_put") return TRUE;
    if (t == "settings_del") return TRUE;
    if (t == "settings_batch") return TRUE;
    if (t == "settings_get") return TRUE;
    if (t == "settings_sub") return TRUE;
    if (t == "settings_unsub") return TRUE;
    /* ACL + Auth + UI */
    if (t == "acl_register_feature") return TRUE;
    if (t == "acl_set_policy") return TRUE;
    if (t == "acl_query") return TRUE;
    if (t == "acl_filter") return TRUE;
    if (t == "auth_query") return TRUE;
    if (t == "ui_touch") return TRUE;
    if (t == "ui_click") return TRUE;
    return FALSE;
}

/* Map "to" → lane */
integer lane_for_module(string mod){
    if (mod == "ui_backend")  return L_UI_BE_IN;
    if (mod == "ui_frontend") return L_UI_FE_IN;
    /* Default: route through API lane */
    return L_API;
}

list Pending;
integer PENDING_STRIDE = 5; /* [req_id, from, to, type, sent] */
integer PENDING_TIMEOUT_SEC = 3;
float   PENDING_SWEEP_SEC   = 1.0;

integer now(){ return llGetUnixTime(); }

integer pending_index(string rid){
    integer i = 0;
    integer n = llGetListLength(Pending);
    while (i < n){
        if (llList2String(Pending, i) == rid) return i;
        i += PENDING_STRIDE;
    }
    return -1;
}

integer pending_add(string rid, string from, string to, string typ){
    integer wasEmpty = (llGetListLength(Pending) == 0);
    Pending += [rid, from, to, typ, now()];
    if (wasEmpty) llSetTimerEvent(PENDING_SWEEP_SEC);
    return TRUE;
}

integer pending_remove_at(integer idx){
    Pending = llDeleteSubList(Pending, idx, idx + (PENDING_STRIDE - 1));
    if (llGetListLength(Pending) == 0){
        llSetTimerEvent(0.0);
    }
    return TRUE;
}

integer emit_error(string toMod, string reqId, string code, string message){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], "error");
    j = llJsonSetValue(j, ["from"], "api");
    j = llJsonSetValue(j, ["to"], toMod);
    if (reqId != "") j = llJsonSetValue(j, ["req_id"], reqId);
    j = llJsonSetValue(j, ["code"], code);
    j = llJsonSetValue(j, ["message"], message);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);

    integer lane = lane_for_module(toMod);
    if (lane == 0) lane = L_API;
    llMessageLinked(LINK_SET, lane, j, NULL_KEY);
    return TRUE;
}

integer forward_to_module(string payload, string toMod){
    integer lane = lane_for_module(toMod);
    if (lane == 0) return FALSE;
    llMessageLinked(LINK_SET, lane, payload, NULL_KEY);
    return TRUE;
}

default{
    state_entry(){
        Pending = [];
        llSetTimerEvent(0.0);
        logd("API up");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_API) return;

        string t       = llJsonGetValue(msg, ["type"]);
        string fromMod = llJsonGetValue(msg, ["from"]);
        string toMod   = llJsonGetValue(msg, ["to"]);
        string reqId   = llJsonGetValue(msg, ["req_id"]);
        integer abi    = (integer)llJsonGetValue(msg, ["abi"]);
        if (abi == 0) abi = ABI_VERSION;

        if (fromMod == "" || t == ""){
            emit_error("log", "", "E_BADREQ", "missing type/from");
            return;
        }
        if (abi != ABI_VERSION){
            emit_error(fromMod, reqId, "E_ABI_MISMATCH", "ABI mismatch");
            return;
        }

        integer isReq = IsRequest(t);
        if (isReq){
            if (reqId == ""){
                emit_error(fromMod, "", "E_BADREQ", "Request missing req_id");
                return;
            }
            if (toMod == ""){
                emit_error(fromMod, reqId, "E_BADREQ", "Missing 'to'");
                return;
            }
            integer ok = forward_to_module(msg, toMod);
            if (!ok){
                emit_error(fromMod, reqId, "E_NOTFOUND", "Unknown 'to' module");
                return;
            }
            pending_add(reqId, fromMod, toMod, t);
            logd("REQ " + t + " " + fromMod + "→" + toMod + " rid=" + reqId);
            return;
        }

        if (reqId != ""){
            integer idx = pending_index(reqId);
            if (idx != -1){
                string requester = llList2String(Pending, idx+1);
                integer ok2 = forward_to_module(msg, requester);
                if (!ok2){
                    emit_error(fromMod, reqId, "E_NOTFOUND", "Requester not present");
                } else {
                    logd("RES " + t + " " + fromMod + "→" + requester + " rid=" + reqId);
                }
                pending_remove_at(idx);
                return;
            }
        }

        if (toMod != ""){
            integer ok3 = forward_to_module(msg, toMod);
            if (!ok3){
                emit_error(fromMod, reqId, "E_NOTFOUND", "Unknown 'to'");
            } else {
                logd("EVT " + t + " " + fromMod + "→" + toMod);
            }
        }
    }

    timer(){
        integer i = 0;
        integer n = llGetListLength(Pending);
        integer tnow = now();
        while (i < n){
            string rid = llList2String(Pending, i+0);
            string from = llList2String(Pending, i+1);
            string to   = llList2String(Pending, i+2);
            string typ  = llList2String(Pending, i+3);
            integer ts  = llList2Integer(Pending, i+4);
            if ((tnow - ts) > PENDING_TIMEOUT_SEC){
                emit_error(from, rid, "E_TIMEOUT", "No response from '"+to+"' for '"+typ+"'");
                pending_remove_at(i);
                n = llGetListLength(Pending);
            } else {
                i += PENDING_STRIDE;
            }
        }
        if (n == 0){
            llSetTimerEvent(0.0);
        }
    }
}
