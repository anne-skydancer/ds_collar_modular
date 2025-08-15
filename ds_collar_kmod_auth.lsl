/* =============================================================
   MODULE:  ds_collar_kmod_auth.lsl  (AUTHORITATIVE + POLICY FLAGS)
   ROLE:    Sole source of ACL truth + policy for UI filtering
            ACL levels per spec:
              5 = owner
              4 = wearer unowned (owner_key == NULL_KEY)
              3 = trustee
              2 = wearer owned   (owner_key != NULL_KEY)
              1 = public (non-owner/non-wearer/non-trustee; public_mode ON)
              0 = wearer in TPE (no access)
             -1 = blacklist (outsider on blacklist) OR outsider when public_mode OFF
   ============================================================= */

integer DEBUG = FALSE;

integer logd(string msg) { if (DEBUG) llOwnerSay("[AUTH] " + msg); return 0; }

/* ---------- Protocol constants ---------- */
string MSG_SETTINGS_GET   = "settings_get";
string MSG_SETTINGS_SYNC  = "settings_sync";
string MSG_ACL_QUERY      = "acl_query";
string MSG_ACL_RESULT     = "acl_result";

/* ---------- Link numbers ---------- */
integer ACL_QUERY_NUM      = 700;
integer ACL_RESULT_NUM     = 710;
integer SETTINGS_QUERY_NUM = 800;
integer SETTINGS_SYNC_NUM  = 870;

/* ---------- Settings keys ---------- */
string KEY_OWNER_KEY        = "owner_key";
string KEY_TRUSTEES         = "trustees";
string KEY_BLACKLIST        = "blacklist";
string KEY_PUBLIC_ACCESS    = "public_mode";
string KEY_TPE_MODE         = "tpe_mode";

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
list    g_trustees           = [];
list    g_blacklist          = [];
integer g_public_access_flag = FALSE;
integer g_tpe_mode           = FALSE;

/* ---------- Helpers ---------- */
integer json_has(string j, list path) {
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return FALSE;
    return TRUE;
}
integer is_json_obj(string s) {
    if (llGetSubString(s, 0, 0) == "{") return TRUE;
    return FALSE;
}
integer is_json_arr(string s) {
    if (llGetSubString(s, 0, 0) == "[") return TRUE;
    return FALSE;
}
list json_array_to_list(string jarr) { if (!is_json_arr(jarr)) return []; return llJson2List(jarr); }
integer list_has_str(list L, string needle) { if (llListFindList(L, [needle]) != -1) return TRUE; return FALSE; }

/* ---------- Settings intake ---------- */
integer apply_settings_sync(string sync_json) {
    if (!json_has(sync_json, ["type"])) return 0;
    if (llJsonGetValue(sync_json, ["type"]) != MSG_SETTINGS_SYNC) return 0;
    if (!json_has(sync_json, ["kv"])) return 0;

    string kv = llJsonGetValue(sync_json, ["kv"]);
    if (!is_json_obj(kv)) return 0;

    g_owner_key          = NULL_KEY;
    g_trustees           = [];
    g_blacklist          = [];
    g_public_access_flag = FALSE;
    g_tpe_mode           = FALSE;

    if (json_has(kv, [KEY_OWNER_KEY]))        g_owner_key          = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
    if (json_has(kv, [KEY_TRUSTEES]))         g_trustees           = json_array_to_list(llJsonGetValue(kv, [KEY_TRUSTEES]));
    if (json_has(kv, [KEY_BLACKLIST]))        g_blacklist          = json_array_to_list(llJsonGetValue(kv, [KEY_BLACKLIST]));
    if (json_has(kv, [KEY_PUBLIC_ACCESS]))    g_public_access_flag = (integer)llJsonGetValue(kv, [KEY_PUBLIC_ACCESS]);
    if (json_has(kv, [KEY_TPE_MODE]))         g_tpe_mode           = (integer)llJsonGetValue(kv, [KEY_TPE_MODE]);

    if (DEBUG) {
        llOwnerSay("[AUTH] Settings applied");
        llOwnerSay("[AUTH] owner_key=" + (string)g_owner_key);
        llOwnerSay("[AUTH] trustees=" + llList2CSV(g_trustees));
        llOwnerSay("[AUTH] blacklist=" + llList2CSV(g_blacklist));
        llOwnerSay("[AUTH] public_mode=" + (string)g_public_access_flag + " tpe_mode=" + (string)g_tpe_mode);
    }
    return 1;
}

/* ---------- ACL evaluation per your rules ---------- */
integer compute_acl_level(key av) {
    key wearer = llGetOwner();
    integer ownerSet  = FALSE;
    integer isOwner   = FALSE;
    integer isWearer  = FALSE;
    integer isTrustee = FALSE;
    integer isBlack   = FALSE;

    if (g_owner_key != NULL_KEY) ownerSet = TRUE;
    if (av == g_owner_key && ownerSet) isOwner = TRUE;
    if (av == wearer) isWearer = TRUE;
    if (list_has_str(g_trustees, (string)av)) isTrustee = TRUE;

    if (!isOwner && !isWearer && !isTrustee) {
        if (list_has_str(g_blacklist, (string)av)) isBlack = TRUE;
    }

    if (isOwner) return ACL_PRIMARY_OWNER;

    if (isWearer) {
        if (g_tpe_mode) return ACL_NOACCESS;   // wearer in TPE → 0
        if (ownerSet)   return ACL_OWNED;      // wearer owned → 2
        return ACL_UNOWNED;                    // wearer unowned → 4
    }

    if (isTrustee) return ACL_TRUSTEE;

    if (isBlack) return ACL_BLACKLIST;

    if (g_public_access_flag) return ACL_PUBLIC;  // outsider + public ON → 1
    return ACL_BLACKLIST;                         // outsider + public OFF → -1
}

/* ---------- Emit ACL + policy flags ---------- */
integer send_acl_result(key av, integer level) {
    key wearer = llGetOwner();
    integer isWearer = FALSE;
    if (av == wearer) isWearer = TRUE;

    // policy_sos_only: wearer in TPE may only use "core_sos"
    integer policy_sos_only = 0;
    if (isWearer && g_tpe_mode) policy_sos_only = 1;

    // policy_public_only: non-wearer in public mode can only use min_acl==1
    integer policy_public_only = 0;
    if (!isWearer && g_public_access_flag) policy_public_only = 1;

    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   MSG_ACL_RESULT);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    j = llJsonSetValue(j, ["level"],  (string)level);
    j = llJsonSetValue(j, ["is_wearer"],           (string)isWearer);
    j = llJsonSetValue(j, ["policy_sos_only"],     (string)policy_sos_only);
    j = llJsonSetValue(j, ["policy_public_only"],  (string)policy_public_only);

    llMessageLinked(LINK_SET, ACL_RESULT_NUM, j, NULL_KEY);
    return 0;
}

integer request_settings_sync() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], MSG_SETTINGS_GET);
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, j, NULL_KEY);
    return 0;
}

/* ---------- Events ---------- */
default {
    state_entry() { request_settings_sync(); }

    link_message(integer sender, integer num, string str, key id) {
        if (num == SETTINGS_SYNC_NUM) { apply_settings_sync(str); return; }

        if (num == ACL_QUERY_NUM) {
            if (!json_has(str, ["type"])) return;
            if (llJsonGetValue(str, ["type"]) != MSG_ACL_QUERY) return;
            if (!json_has(str, ["avatar"])) return;

            key av = (key)llJsonGetValue(str, ["avatar"]);
            if (av == NULL_KEY) return;

            integer level = compute_acl_level(av);
            send_acl_result(av, level);
            return;
        }
    }
}
