/* =============================================================
   MODULE:  ds_collar_kmod_auth.lsl
   ROLE:    Authoritative ACL (sole source of truth)
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Link numbers ---------- */
integer ACL_QUERY_NUM      = 700;  /* In : {"type":"acl_query","avatar":"<key>"} */
integer ACL_RESULT_NUM     = 710;  /* Out: {"type":"acl_result","avatar":"<key>","level":<int>} */
integer SETTINGS_QUERY_NUM = 800;  /* Out: {"type":"settings_get"} */
integer SETTINGS_SYNC_NUM  = 870;  /* In : {"type":"settings_sync","kv":{...}}  */

/* ---------- Settings keys ---------- */
string KEY_OWNER_KEY        = "owner_key";
string KEY_OWNER_HON        = "owner_hon";
string KEY_TRUSTEES         = "trustees";
string KEY_TRUSTEE_HONS     = "trustee_honorifics";
string KEY_BLACKLIST        = "blacklist";
string KEY_PUBLIC_ACCESS    = "public_mode";

/* ---------- ACL constants ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Cached state ---------- */
key     g_owner_key          = NULL_KEY;
string  g_owner_hon          = "";
list    g_trustees           = [];
list    g_trustee_hons       = [];
list    g_blacklist          = [];
integer g_public_access_flag = FALSE;

/* ---------- Helpers ---------- */
integer json_has(string j, list path) {
    string v = llJsonGetValue(j, path);
    return (v != JSON_INVALID);
}
integer is_json_obj(string s) { return llGetSubString(s, 0, 0) == "{"; }
integer is_json_arr(string s) { return llGetSubString(s, 0, 0) == "["; }
list json_array_to_list(string jarr) {
    if (!is_json_arr(jarr)) return [];
    return llJson2List(jarr);
}
integer list_has_str(list L, string needle) {
    return (llListFindList(L, [needle]) != -1);
}

/* ---------- Settings intake ---------- */
integer apply_settings_sync(string sync_json) {
    if (!json_has(sync_json, ["type"])) return 0;
    if (llJsonGetValue(sync_json, ["type"]) != "settings_sync") return 0;
    if (!json_has(sync_json, ["kv"])) return 0;

    string kv = llJsonGetValue(sync_json, ["kv"]);
    if (!is_json_obj(kv)) return 0;

    g_owner_key          = NULL_KEY;
    g_owner_hon          = "";
    g_trustees           = [];
    g_trustee_hons       = [];
    g_blacklist          = [];
    g_public_access_flag = FALSE;

    if (json_has(kv, [KEY_OWNER_KEY])) {
        g_owner_key = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
    }
    if (json_has(kv, [KEY_OWNER_HON])) {
        g_owner_hon = llJsonGetValue(kv, [KEY_OWNER_HON]);
    }
    if (json_has(kv, [KEY_TRUSTEES])) {
        g_trustees = json_array_to_list(llJsonGetValue(kv, [KEY_TRUSTEES]));
    }
    if (json_has(kv, [KEY_TRUSTEE_HONS])) {
        g_trustee_hons = json_array_to_list(llJsonGetValue(kv, [KEY_TRUSTEE_HONS]));
    }
    if (json_has(kv, [KEY_BLACKLIST])) {
        g_blacklist = json_array_to_list(llJsonGetValue(kv, [KEY_BLACKLIST]));
    }
    if (json_has(kv, [KEY_PUBLIC_ACCESS])) {
        g_public_access_flag = (integer)llJsonGetValue(kv, [KEY_PUBLIC_ACCESS]);
    }
    return 1;
}

/* ---------- ACL evaluation ---------- */
integer compute_acl_level(key av) {
    key    wearer = llGetOwner();
    string avs    = (string)av;

    /* 1) BLACKLIST FIRST — always overrides everything */
    if (list_has_str(g_blacklist, avs)) {
        return ACL_BLACKLIST;
    }

    /* 2) OWNER BRANCH */
    if (g_owner_key != NULL_KEY) {
        if (av == g_owner_key) return ACL_PRIMARY_OWNER;
        if (list_has_str(g_trustees, avs)) return ACL_TRUSTEE;
        if (av == wearer) {
            if (!g_public_access_flag) return ACL_NOACCESS;
            return ACL_OWNED;
        }
    } 
    else {
        /* No owner set → wearer defaults to UNOWNED (4) */
        if (av == wearer) return ACL_UNOWNED;
    }

    /* 3) PUBLIC (if enabled) */
    if (g_public_access_flag) return ACL_PUBLIC;

    /* 4) NOACCESS */
    return ACL_NOACCESS;
}

/* ---------- Outbound JSON ---------- */
integer send_acl_result(key av, integer level) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   "acl_result");
    j = llJsonSetValue(j, ["avatar"], (string)av);
    j = llJsonSetValue(j, ["level"],  (string)level);
    llMessageLinked(LINK_SET, ACL_RESULT_NUM, j, NULL_KEY);
    return 0;
}

integer request_settings_sync() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], "settings_get");
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, j, NULL_KEY);
    return 0;
}

/* ---------- Events ---------- */
default
{
    state_entry() {
        request_settings_sync();
    }

    link_message(integer sender, integer num, string str, key id)
    {
        if (num == SETTINGS_SYNC_NUM) {
            apply_settings_sync(str);
            return;
        }

        if (num == ACL_QUERY_NUM) {
            if (!json_has(str, ["type"])) return;
            if (llJsonGetValue(str, ["type"]) != "acl_query") return;
            if (!json_has(str, ["avatar"])) return;

            key av = (key)llJsonGetValue(str, ["avatar"]);
            if (av == NULL_KEY) return;

            integer level = compute_acl_level(av);
            send_acl_result(av, level);
            return;
        }
    }
}
