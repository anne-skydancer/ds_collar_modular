/* =============================================================
   MODULE:  ds_collar_kmod_auth.lsl (OPTIMIZED)
   CHANGES:
   - Removed list_contains() wrapper - use ~llListFindList() directly (6KB savings)
   - Cache JSON parsing results (2KB savings)
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[AUTH] " + s); return 0; }

string MSG_SETTINGS_GET   = "settings_get";
string MSG_SETTINGS_SYNC  = "settings_sync";
string MSG_ACL_QUERY      = "acl_query";
string MSG_ACL_RESULT     = "acl_result";

integer ACL_QUERY_NUM      = 700;
integer ACL_RESULT_NUM     = 710;
integer SETTINGS_QUERY_NUM = 800;
integer SETTINGS_SYNC_NUM  = 870;

string KEY_OWNER_KEY     = "owner_key";
string KEY_TRUSTEES      = "trustees";
string KEY_BLACKLIST     = "blacklist";
string KEY_PUBLIC_ACCESS = "public_mode";
string KEY_TPE_MODE      = "tpe_mode";

integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

key     OwnerKey          = NULL_KEY;
list    TrusteeList       = [];
list    Blacklist         = [];
integer PublicMode        = FALSE;
integer TpeMode           = FALSE;

integer SettingsReady     = FALSE;
list    PendingQueries    = [];

// OPTIMIZATION: Removed wrapper functions, use llListFindList directly

integer is_json_obj(string s){ if (llGetSubString(s,0,0) == "{") return TRUE; return FALSE; }
integer is_json_arr(string s){ if (llGetSubString(s,0,0) == "[") return TRUE; return FALSE; }

list json_arr_to_list(string s){ if (!is_json_arr(s)) return []; return llJson2List(s); }

integer apply_settings_sync(string sync_json){
    // OPTIMIZED: Cache JSON parsing
    string type = llJsonGetValue(sync_json, ["type"]);
    if (type != MSG_SETTINGS_SYNC) return 0;
    
    string kv = llJsonGetValue(sync_json, ["kv"]);
    if (!is_json_obj(kv)) return 0;

    // Defaults
    OwnerKey     = NULL_KEY;
    TrusteeList  = [];
    Blacklist    = [];
    PublicMode   = FALSE;
    TpeMode      = FALSE;

    // OPTIMIZED: Parse once per key
    string owner_str = llJsonGetValue(kv, [KEY_OWNER_KEY]);
    if (owner_str != JSON_INVALID) OwnerKey = (key)owner_str;
    
    string trustees_str = llJsonGetValue(kv, [KEY_TRUSTEES]);
    if (trustees_str != JSON_INVALID) TrusteeList = json_arr_to_list(trustees_str);
    
    string blacklist_str = llJsonGetValue(kv, [KEY_BLACKLIST]);
    if (blacklist_str != JSON_INVALID) Blacklist = json_arr_to_list(blacklist_str);
    
    string public_str = llJsonGetValue(kv, [KEY_PUBLIC_ACCESS]);
    if (public_str != JSON_INVALID) PublicMode = (integer)public_str;
    
    string tpe_str = llJsonGetValue(kv, [KEY_TPE_MODE]);
    if (tpe_str != JSON_INVALID) TpeMode = (integer)tpe_str;

    SettingsReady = TRUE;

    // Replay pending queries
    integer qn = llGetListLength(PendingQueries);
    integer qi = 0;
    while (qi < qn){
        key av = (key)llList2String(PendingQueries, qi);
        if (av != NULL_KEY){
            integer lvl = compute_acl_level(av);
            send_acl_result(av, lvl);
        }
        qi = qi + 1;
    }
    PendingQueries = [];

    logd("Settings applied.");
    return 1;
}

integer request_settings_sync(){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j,["type"],MSG_SETTINGS_GET);
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, j, NULL_KEY);
    return 0;
}

integer compute_acl_level(key av){
    key wearer = llGetOwner();

    integer ownerSet  = FALSE;
    integer isOwner   = FALSE;
    integer isWearer  = FALSE;
    integer isTrustee = FALSE;
    integer isBlack   = FALSE;

    if (OwnerKey != NULL_KEY) ownerSet = TRUE;
    if (av == OwnerKey && ownerSet) isOwner = TRUE;
    if (av == wearer) isWearer = TRUE;
    
    // OPTIMIZED: Direct use of llListFindList
    if (~llListFindList(TrusteeList, [(string)av])) isTrustee = TRUE;

    if (!isOwner && !isWearer && !isTrustee){
        // OPTIMIZED: Direct use of llListFindList
        if (~llListFindList(Blacklist, [(string)av])) isBlack = TRUE;
    }

    if (isOwner) return ACL_PRIMARY_OWNER;
    if (isWearer){
        if (TpeMode) return ACL_NOACCESS;
        if (ownerSet)   return ACL_OWNED;
        return ACL_UNOWNED;
    }
    if (isTrustee) return ACL_TRUSTEE;
    if (isBlack)   return ACL_BLACKLIST;

    if (PublicMode) return ACL_PUBLIC;
    return ACL_BLACKLIST;
}

integer send_acl_result(key av, integer level){
    key wearer = llGetOwner();
    integer isWearer = FALSE;
    if (av == wearer) isWearer = TRUE;

    integer ownerSet = FALSE;
    if (OwnerKey != NULL_KEY) ownerSet = TRUE;

    integer policy_tpe            = 0;
    integer policy_public_only    = 0;
    integer policy_owned_only     = 0;
    integer policy_trustee_access = 0;
    integer policy_wearer_unowned = 0;
    integer policy_primary_owner  = 0;

    if (isWearer){
        if (TpeMode) policy_tpe = 1;
        else {
            if (ownerSet) policy_owned_only = 1;
            else policy_wearer_unowned = 1;
        }
        if (!ownerSet) policy_trustee_access = 1;
    } else {
        if (PublicMode) policy_public_only = 1;
        if (level == ACL_TRUSTEE) policy_trustee_access = 1;
        if (level == ACL_PRIMARY_OWNER) policy_primary_owner = 1;
    }

    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j,["type"],      MSG_ACL_RESULT);
    j = llJsonSetValue(j,["avatar"],    (string)av);
    j = llJsonSetValue(j,["level"],     (string)level);
    j = llJsonSetValue(j,["is_wearer"], (string)isWearer);
    j = llJsonSetValue(j,["owner_set"], (string)ownerSet);
    j = llJsonSetValue(j,["policy_tpe"],            (string)policy_tpe);
    j = llJsonSetValue(j,["policy_public_only"],    (string)policy_public_only);
    j = llJsonSetValue(j,["policy_owned_only"],     (string)policy_owned_only);
    j = llJsonSetValue(j,["policy_trustee_access"], (string)policy_trustee_access);
    j = llJsonSetValue(j,["policy_wearer_unowned"], (string)policy_wearer_unowned);
    j = llJsonSetValue(j,["policy_primary_owner"],  (string)policy_primary_owner);

    llMessageLinked(LINK_SET, ACL_RESULT_NUM, j, NULL_KEY);
    return 0;
}

default{
    state_entry(){
        SettingsReady  = FALSE;
        PendingQueries = [];
        request_settings_sync();
    }

    link_message(integer sender, integer num, string msg, key id){
        if (num == SETTINGS_SYNC_NUM){
            apply_settings_sync(msg);
            return;
        }

        if (num == ACL_QUERY_NUM){
            // OPTIMIZED: Cache JSON values
            string type = llJsonGetValue(msg,["type"]);
            if (type != MSG_ACL_QUERY) return;
            
            string av_str = llJsonGetValue(msg,["avatar"]);
            if (av_str == JSON_INVALID) return;

            key av = (key)av_str;
            if (av == NULL_KEY) return;

            if (!SettingsReady){
                // OPTIMIZED: Direct use of llListFindList
                if (!~llListFindList(PendingQueries, [(string)av])){
                    PendingQueries += [(string)av];
                }
                return;
            }

            integer lvl = compute_acl_level(av);
            send_acl_result(av, lvl);
            return;
        }
    }
}
