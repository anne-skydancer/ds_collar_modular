/* =============================================================
   MODULE:  ds_collar_kmod_auth.lsl  (Authoritative ACL + Policies)
   ROLE  :  Sole source of truth for ACL + policy flags per toucher
   POLICIES (centralized, per your spec):
     - policy_tpe:
         * Wearer: only plugins that explicitly declare tpe_min_acl==0
         * Toucher: unaffected (uses normal ACL mapping)
     - policy_public_only:
         * Outsider in public mode: only min_acl==1
     - policy_owned_only:
         * Wearer owned (owner set, not in TPE): min_acl<=2
         * Toucher: normal ACL mapping
     - policy_trustee_access:
         * Wearer: allowed only when unowned (to set trustees pre-owner)
         * Toucher: if ACL==3 then only min_acl==3 (no others)
     - policy_wearer_unowned:
         * Wearer unowned (not TPE): min_acl<=4 (not 5-only functionality)
     - policy_primary_owner:
         * Toucher ACL==5: only min_acl==5
   OUTPUT: {"type":"acl_result", ... , policy_* flags, is_wearer, owner_set}
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[AUTH] " + s); return 0; }

/* ---------- Protocol ---------- */
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
string KEY_OWNER_KEY     = "owner_key";
string KEY_TRUSTEES      = "trustees";
string KEY_BLACKLIST     = "blacklist";
string KEY_PUBLIC_ACCESS = "public_mode";
string KEY_TPE_MODE      = "tpe_mode";

/* ---------- ACL constants ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Cached settings ---------- */
key     g_owner_key          = NULL_KEY;
list    g_trustees           = [];
list    g_blacklist          = [];
integer g_public_mode        = FALSE;
integer g_tpe_mode           = FALSE;

/* ---------- Helpers ---------- */
integer json_has(string j, list path){
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return FALSE;
    return TRUE;
}
integer is_json_obj(string s){ if (llGetSubString(s,0,0) == "{") return TRUE; return FALSE; }
integer is_json_arr(string s){ if (llGetSubString(s,0,0) == "[") return TRUE; return FALSE; }
list json_arr_to_list(string s){ if (!is_json_arr(s)) return []; return llJson2List(s); }
integer list_has_str(list L, string x){ if (llListFindList(L,[x]) != -1) return TRUE; return FALSE; }

/* ---------- Settings intake ---------- */
integer apply_settings_sync(string sync_json){
    if (!json_has(sync_json, ["type"])) return 0;
    if (llJsonGetValue(sync_json, ["type"]) != MSG_SETTINGS_SYNC) return 0;
    if (!json_has(sync_json, ["kv"])) return 0;

    string kv = llJsonGetValue(sync_json, ["kv"]);
    if (!is_json_obj(kv)) return 0;

    /* defaults */
    g_owner_key   = NULL_KEY;
    g_trustees    = [];
    g_blacklist   = [];
    g_public_mode = FALSE;
    g_tpe_mode    = FALSE;

    if (json_has(kv, [KEY_OWNER_KEY]))     g_owner_key   = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
    if (json_has(kv, [KEY_TRUSTEES]))      g_trustees    = json_arr_to_list(llJsonGetValue(kv, [KEY_TRUSTEES]));
    if (json_has(kv, [KEY_BLACKLIST]))     g_blacklist   = json_arr_to_list(llJsonGetValue(kv, [KEY_BLACKLIST]));
    if (json_has(kv, [KEY_PUBLIC_ACCESS])) g_public_mode = (integer)llJsonGetValue(kv, [KEY_PUBLIC_ACCESS]);
    if (json_has(kv, [KEY_TPE_MODE]))      g_tpe_mode    = (integer)llJsonGetValue(kv, [KEY_TPE_MODE]);

    logd("Settings applied.");
    return 1;
}

integer request_settings_sync(){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j,["type"],MSG_SETTINGS_GET);
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, j, NULL_KEY);
    return 0;
}

/* ---------- ACL evaluation ---------- */
integer compute_acl_level(key av){
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

    if (!isOwner && !isWearer && !isTrustee){
        if (list_has_str(g_blacklist, (string)av)) isBlack = TRUE;
    }

    if (isOwner) return ACL_PRIMARY_OWNER;
    if (isWearer){
        if (g_tpe_mode) return ACL_NOACCESS;   /* TPE wearer maps to 0; policy_tpe refines visibility */
        if (ownerSet)   return ACL_OWNED;      /* 2 */
        return ACL_UNOWNED;                    /* 4 */
    }
    if (isTrustee) return ACL_TRUSTEE;
    if (isBlack)   return ACL_BLACKLIST;

    if (g_public_mode) return ACL_PUBLIC;      /* 1 */
    return ACL_BLACKLIST;                      /* outsider while public OFF */
}

/* ---------- Central policy emission ---------- */
integer send_acl_result(key av, integer level){
    key wearer = llGetOwner();
    integer isWearer = FALSE;
    if (av == wearer) isWearer = TRUE;

    integer ownerSet = FALSE;
    if (g_owner_key != NULL_KEY) ownerSet = TRUE;

    /* Policy flags (boolean 0/1), per your spec */
    integer policy_tpe            = 0; /* wearer-only: show only plugins with tpe_min_acl==0 */
    integer policy_public_only    = 0; /* outsiders in public mode: only min_acl==1 */
    integer policy_owned_only     = 0; /* wearer owned (not TPE): cap at min_acl<=2 */
    integer policy_trustee_access = 0; /* wearer unowned may manage trustees; touchers with acl==3: only ==3 */
    integer policy_wearer_unowned = 0; /* wearer unowned (not TPE): cap at min_acl<=4 */
    integer policy_primary_owner  = 0; /* touchers with acl==5: only ==5 */

    if (isWearer){
        if (g_tpe_mode) policy_tpe = 1;
        else {
            if (ownerSet) policy_owned_only = 1;
            else policy_wearer_unowned = 1;
        }
        /* trustee_access (wearer side): only if UNOWNED */
        if (!ownerSet) policy_trustee_access = 1;
    } else {
        /* non-wearers */
        if (g_public_mode) policy_public_only = 1;
        if (level == ACL_TRUSTEE) policy_trustee_access = 1;
        if (level == ACL_PRIMARY_OWNER) policy_primary_owner = 1;
    }

    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j,["type"],      MSG_ACL_RESULT);
    j = llJsonSetValue(j,["avatar"],    (string)av);
    j = llJsonSetValue(j,["level"],     (string)level);
    j = llJsonSetValue(j,["is_wearer"], (string)isWearer);
    j = llJsonSetValue(j,["owner_set"], (string)ownerSet);

    /* policy flags */
    j = llJsonSetValue(j,["policy_tpe"],            (string)policy_tpe);
    j = llJsonSetValue(j,["policy_public_only"],    (string)policy_public_only);
    j = llJsonSetValue(j,["policy_owned_only"],     (string)policy_owned_only);
    j = llJsonSetValue(j,["policy_trustee_access"], (string)policy_trustee_access);
    j = llJsonSetValue(j,["policy_wearer_unowned"], (string)policy_wearer_unowned);
    j = llJsonSetValue(j,["policy_primary_owner"],  (string)policy_primary_owner);

    llMessageLinked(LINK_SET, ACL_RESULT_NUM, j, NULL_KEY);
    return 0;
}

/* ---------- Events ---------- */
default{
    state_entry(){ request_settings_sync(); }

    link_message(integer sender, integer num, string msg, key id){
        if (num == SETTINGS_SYNC_NUM){
            apply_settings_sync(msg);
            return;
        }

        if (num == ACL_QUERY_NUM){
            if (!json_has(msg,["type"])) return;
            if (llJsonGetValue(msg,["type"]) != MSG_ACL_QUERY) return;
            if (!json_has(msg,["avatar"])) return;

            key av = (key)llJsonGetValue(msg,["avatar"]);
            if (av == NULL_KEY) return;

            integer lvl = compute_acl_level(av);
            send_acl_result(av, lvl);
            return;
        }
    }
}
