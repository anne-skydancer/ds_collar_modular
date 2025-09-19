/* =============================================================
   MODULE: ds_collar_kmod_auth.lsl  (HEADLESS)
   ROLE  : Compute ACL level for a given avatar (Restricted → wearer only)
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[AUTH] " + s); return 0; }

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
string T_SETTINGS_SUB      = "settings_sub";
string T_SETTINGS_SNAPSHOT = "settings_snapshot";
string T_SETTINGS_SYNC     = "settings_sync";
string T_AUTH_QUERY        = "auth_query";
string T_AUTH_RESULT       = "auth_result";
string T_ERROR             = "error";

/* Cache */
string  OwnerKey;
integer SelfOwned;
integer PublicMode;
integer RestrictedMode;
list    Trustees;

string lc(string s){ return llToLower(s); }

integer list_has_str(list L, string needle){
    integer i = 0;
    integer n = llGetListLength(L);
    while (i < n){
        if (llList2String(L, i) == needle) return TRUE;
        i += 1;
    }
    return FALSE;
}

list json_array_strings_to_list(string jarr){
    list out = [];
    integer i = 0;
    integer done = FALSE;
    while (!done){
        string v = llJsonGetValue(jarr, [(string)i]);
        if (v == JSON_INVALID){
            done = TRUE;
        }
        else{
            if (llGetSubString(v, 0, 0) == "\"" && llGetSubString(v, -1, -1) == "\""){
                v = llGetSubString(v, 1, llStringLength(v) - 2);
            }
            out += lc(v);
            i += 1;
        }
    }
    return out;
}

/* Outbound */
integer sub_core(){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], T_SETTINGS_SUB);
    j = llJsonSetValue(j, ["from"], "auth");
    j = llJsonSetValue(j, ["to"], "settings");
    j = llJsonSetValue(j, ["prefix"], "core.");
    j = llJsonSetValue(j, ["req_id"], "auth-sub-core");
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

/* Apply settings object (sync or snapshot 'values') */
integer apply_obj(string obj){
    string v;

    v = llJsonGetValue(obj, ["core.owner.key"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.owner.key", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) OwnerKey = "";
        else {
            if (llGetSubString(v, 0, 0) == "\"" && llGetSubString(v, -1, -1) == "\""){
                v = llGetSubString(v, 1, llStringLength(v) - 2);
            }
            OwnerKey = lc(v);
        }
    }

    v = llJsonGetValue(obj, ["core.self.owned"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.self.owned", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) SelfOwned = 0;
        else SelfOwned = (integer)v;
    }

    v = llJsonGetValue(obj, ["core.public.mode"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.public.mode", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) PublicMode = 0;
        else PublicMode = (integer)v;
    }

    v = llJsonGetValue(obj, ["core.restricted.mode"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.restricted.mode", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) RestrictedMode = 0;
        else RestrictedMode = (integer)v;
    }

    v = llJsonGetValue(obj, ["core.trustees"]);
    if (v == JSON_INVALID) v = llJsonGetValue(obj, ["core.trustees", "value"]);
    if (v != JSON_INVALID){
        if (v == JSON_NULL) Trustees = [];
        else Trustees = json_array_strings_to_list(v);
    }
    return TRUE;
}

/* Level logic (Restricted → wearer only) */
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

/* Events */
default{
    state_entry(){
        OwnerKey = "";
        SelfOwned = TRUE;
        PublicMode = FALSE;
        RestrictedMode = FALSE;
        Trustees = [];
        sub_core();
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_AUTH_IN) return;
        string t = llJsonGetValue(msg, ["type"]);

        if (t == T_SETTINGS_SNAPSHOT){
            if (llJsonGetValue(msg, ["to"]) != "auth") return;
            string v = llJsonGetValue(msg, ["values"]);
            if (v != JSON_INVALID) apply_obj(v);
            return;
        }

        if (t == T_SETTINGS_SYNC){
            string ch = llJsonGetValue(msg, ["changed"]);
            if (ch != JSON_INVALID) apply_obj(ch);
            return;
        }

        if (t == T_AUTH_QUERY){
            string from = llJsonGetValue(msg, ["from"]);
            string rid  = llJsonGetValue(msg, ["req_id"]);
            string av   = llJsonGetValue(msg, ["avatar"]);
            if (av == JSON_INVALID || av == "") return;
            send_auth_result(from, rid, av, compute_level(av));
            return;
        }

        if (t == T_ERROR){
            logd("ERR " + llGetSubString(msg, 0, 180));
            return;
        }
    }
}
