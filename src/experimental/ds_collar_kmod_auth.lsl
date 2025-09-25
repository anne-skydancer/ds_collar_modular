/* =============================================================
 MODULE: ds_collar_kmod_auth.lsl (HEADLESS, API-STRICT)
 ROLE  : Compute ACL level for a given avatar (baseline-compatible)
 ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[AUTH] " + s); return 0; }

/* === DS Collar ABI & Lanes (match ds_collar_api.lsl) === */
integer ABI_VERSION   = 1;
integer L_API         = -1000;

/* Types (baseline) */
string T_SETTINGS_SUB      = "settings_sub";
string T_SETTINGS_SNAPSHOT = "settings_snapshot";
string T_SETTINGS_SYNC     = "settings_sync";

string T_AUTH_QUERY        = "auth_query";
string T_AUTH_RESULT       = "auth_result";

string T_ERROR             = "error";

/* ---------- Cached state (baseline semantics) ---------- */
string  OwnerKey = "";   // core.owner.key
integer SelfOwned = TRUE;      // core.self.owned
integer PublicMode = FALSE;    // core.public.mode
integer RestrictedMode = FALSE;// core.restricted.mode
list    Trustees = [];         // core.trustees (strings, lowercased)

/* ---------- Helpers ---------- */
string lc(string s){ return llToLower(s); }
integer is_uuid(string s){ key k = (key)s; if ((string)k == s) return TRUE; return FALSE; }

integer list_has_str(list L, string needle){
    integer i = 0; integer n = llGetListLength(L);
    while (i < n){ if (llList2String(L, i) == needle) return TRUE; i += 1; }
    return FALSE;
}

list json_array_strings_to_list(string jarr){
    list out = []; integer i = 0; integer done = FALSE;
    while (!done){
        string v = llJsonGetValue(jarr, [(string)i]);
        if (v == JSON_INVALID){ done = TRUE; }
        else{
            /* normalize to plain lowercased string */
            if (llGetSubString(v, 0, 0) == "\"" && llGetSubString(v, -1, -1) == "\""){
                v = llGetSubString(v, 1, llStringLength(v) - 2);
            }
            out += lc(v);
            i += 1;
        }
    }
    return out;
}

/* ---------- Outbound ---------- */
integer sub_core(){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], T_SETTINGS_SUB);
    j = llJsonSetValue(j, ["from"], "auth");
    j = llJsonSetValue(j, ["to"], "settings");
    j = llJsonSetValue(j, ["prefix"], "core.");
    j = llJsonSetValue(j, ["req_id"], "auth-sub-core");
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

integer send_auth_result(string toMod, string reqId, string avatar, integer level){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], T_AUTH_RESULT);
    j = llJsonSetValue(j, ["from"], "auth");
    j = llJsonSetValue(j, ["to"], toMod);
    j = llJsonSetValue(j, ["req_id"], reqId);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    j = llJsonSetValue(j, ["avatar"], avatar);
    j = llJsonSetValue(j, ["level"], (string)level);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* ---------- Apply settings object (snapshot/ sync) ---------- */
integer apply_obj(string obj){
    string v;

    v = llJsonGetValue(obj, ["core.owner.key"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.owner.key", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) OwnerKey = "";
        else{
            if (llGetSubString(v, 0, 0) == "\"" && llGetSubString(v, -1, -1) == "\""){
                v = llGetSubString(v, 1, llStringLength(v) - 2);
            }
            OwnerKey = lc(v);
        }
    }

    v = llJsonGetValue(obj, ["core.self.owned"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.self.owned", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) SelfOwned = 0; else SelfOwned = (integer)v;
    }

    v = llJsonGetValue(obj, ["core.public.mode"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.public.mode", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) PublicMode = 0; else PublicMode = (integer)v;
    }

    v = llJsonGetValue(obj, ["core.restricted.mode"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.restricted.mode", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) RestrictedMode = 0; else RestrictedMode = (integer)v;
    }

    v = llJsonGetValue(obj, ["core.trustees"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.trustees", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) Trustees = [];
        else Trustees = json_array_strings_to_list(v);
    }
    return TRUE;
}

/* ---------- Level logic (baseline semantics) ---------- */
integer compute_level(string avatarKey){
    string av = lc(avatarKey);
    string wearer = lc((string)llGetOwner());
    string owner  = lc(OwnerKey);

    integer hasOwner = FALSE;
    if (owner != "" && owner != (string)NULL_KEY) hasOwner = TRUE;

    integer isSelf = FALSE;
    if (!hasOwner && SelfOwned) isSelf = TRUE;

    if (av == owner) return 5;

    if (av == wearer){
        if (RestrictedMode) return 0;
        if (!hasOwner && isSelf) return 4;
        return 2;
    }

    if (list_has_str(Trustees, av)) return 3;
    if (PublicMode) return 1;

    return -1;
}

/* =========================== EVENTS =========================== */
default{
    state_entry(){
        OwnerKey = ""; SelfOwned = TRUE; PublicMode = FALSE; RestrictedMode = FALSE; Trustees = [];
        sub_core();
        logd("AUTH up (ABI v1)");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_API) return;

        string t   = llJsonGetValue(msg, ["type"]);
        string frm = llJsonGetValue(msg, ["from"]);
        string to  = llJsonGetValue(msg, ["to"]);
        string rid = llJsonGetValue(msg, ["req_id"]);
        integer abi = (integer)llJsonGetValue(msg, ["abi"]);
        if (abi == 0) abi = ABI_VERSION;
        if (abi != ABI_VERSION) return;
        if (t == "" || frm == "") return;

        /* drop error/acks — router noise */
        if (t == T_ERROR){ logd("IGN error from " + frm + " rid=" + (string)rid); return; }
        if (t == "settings_ack" && frm == "settings"){ logd("IGN settings_ack"); return; }

        /* Settings snapshot/sync */
        if (t == T_SETTINGS_SNAPSHOT){
            if (to != "auth") return; // targeted
            string v = llJsonGetValue(msg, ["values"]);
            if (v != JSON_INVALID) apply_obj(v);
            return;
        }
        if (t == T_SETTINGS_SYNC){
            string ch = llJsonGetValue(msg, ["changed"]);
            if (ch != JSON_INVALID) apply_obj(ch);
            return;
        }

        /* auth_query → compute + respond (STRICT: to must be 'auth') */
        if (t == T_AUTH_QUERY){
            if (to != "auth") return;
            if (rid == "" || rid == JSON_INVALID) return;

            string av = llJsonGetValue(msg, ["avatar"]);
            if (av == JSON_INVALID || av == "" || !is_uuid(av)){
                /* hard fail to caller via API */
                string err = llList2Json(JSON_OBJECT, []);
                err = llJsonSetValue(err, ["type"], T_ERROR);
                err = llJsonSetValue(err, ["from"], "auth");
                err = llJsonSetValue(err, ["to"], frm);
                err = llJsonSetValue(err, ["req_id"], rid);
                err = llJsonSetValue(err, ["abi"], (string)ABI_VERSION);
                err = llJsonSetValue(err, ["code"], "E_BADREQ");
                err = llJsonSetValue(err, ["message"], "invalid avatar uuid");
                llMessageLinked(LINK_SET, L_API, err, NULL_KEY);
                logd("DENY auth_query rid=" + rid + " invalid avatar");
                return;
            }

            integer level = compute_level(av);
            send_auth_result(frm, rid, av, level);
            logd("→ auth_result rid=" + rid + " to=" + frm + " level=" + (string)level);
            return;
        }

        /* explicit NAK only if someone mis-addresses to 'auth' */
        if (to == "auth"){
            string err2 = llList2Json(JSON_OBJECT, []);
            err2 = llJsonSetValue(err2, ["type"], T_ERROR);
            err2 = llJsonSetValue(err2, ["from"], "auth");
            err2 = llJsonSetValue(err2, ["to"], frm);
            if (rid != JSON_INVALID) err2 = llJsonSetValue(err2, ["req_id"], rid);
            err2 = llJsonSetValue(err2, ["abi"], (string)ABI_VERSION);
            err2 = llJsonSetValue(err2, ["code"], "E_BADREQ");
            err2 = llJsonSetValue(err2, ["message"], "unknown type");
            llMessageLinked(LINK_SET, L_API, err2, NULL_KEY);
            logd("DENY unknown type '" + t + "' from " + frm + " rid=" + (string)rid);
            return;
        }
        /* otherwise ignore (not for us) */
    }
}
