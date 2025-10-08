/* =============================================================
   MODULE:  ds_collar_kmod_auth.lsl  (Authoritative ACL + Policies)
   ROLE  :  Sole source of truth for ACL + policy flags per toucher
   OPTIMIZATIONS:
     - Single-pass JSON construction (reduced memory allocations)
     - Cached string constants (reduced string operations)
     - Streamlined boolean logic
     - Optimized helper functions
     - Early returns for performance
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[AUTH] " + s); return 0; }

/* ---------- Protocol (cached constants) ---------- */
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
key     OwnerKey          = NULL_KEY;
list    TrusteeList       = [];
list    Blacklist         = [];
integer PublicMode        = FALSE;
integer TpeMode           = FALSE;
integer SettingsReady     = FALSE;
list    PendingQueries    = [];

/* Cache wearer key to avoid repeated llGetOwner() calls */
key     WearerKey         = NULL_KEY;

/* ---------- Optimized Helpers ---------- */
// Fast JSON validity check - checks first character only
integer is_json_obj(string s){ return llGetSubString(s,0,0) == "{"; }
integer is_json_arr(string s){ return llGetSubString(s,0,0) == "["; }

// Optimized JSON array to list conversion
list json_arr_to_list(string s){
    if (llGetSubString(s,0,0) != "[") return [];
    return llJson2List(s);
}

// Fast list membership check using ~ instead of llListFindList
integer list_has_key(list L, key k){
    return ~llListFindList(L, [(string)k]);
}

/* ---------- Settings intake ---------- */
integer apply_settings_sync(string sync_json){
    // Early validation with single JSON_INVALID check
    string msg_type = llJsonGetValue(sync_json, ["type"]);
    if (msg_type == JSON_INVALID || msg_type != MSG_SETTINGS_SYNC) return 0;
    
    string kv = llJsonGetValue(sync_json, ["kv"]);
    if (!is_json_obj(kv)) return 0;

    // Reset to defaults
    OwnerKey     = NULL_KEY;
    TrusteeList  = [];
    Blacklist    = [];
    PublicMode   = FALSE;
    TpeMode      = FALSE;

    // Single-pass extraction with cached lookups
    string temp_val;
    
    temp_val = llJsonGetValue(kv, [KEY_OWNER_KEY]);
    if (temp_val != JSON_INVALID) OwnerKey = (key)temp_val;
    
    temp_val = llJsonGetValue(kv, [KEY_TRUSTEES]);
    if (temp_val != JSON_INVALID) TrusteeList = json_arr_to_list(temp_val);
    
    temp_val = llJsonGetValue(kv, [KEY_BLACKLIST]);
    if (temp_val != JSON_INVALID) Blacklist = json_arr_to_list(temp_val);
    
    temp_val = llJsonGetValue(kv, [KEY_PUBLIC_ACCESS]);
    if (temp_val != JSON_INVALID) PublicMode = (integer)temp_val;
    
    temp_val = llJsonGetValue(kv, [KEY_TPE_MODE]);
    if (temp_val != JSON_INVALID) TpeMode = (integer)temp_val;

    SettingsReady = TRUE;

    // Process pending queries with optimized loop
    integer qn = llGetListLength(PendingQueries);
    if (qn) {
        integer qi;
        key av;
        for (qi = 0; qi < qn; ++qi){
            av = (key)llList2String(PendingQueries, qi);
            if (av != NULL_KEY){
                send_acl_result(av, compute_acl_level(av));
            }
        }
        PendingQueries = [];
    }

    logd("Settings applied.");
    return 1;
}

integer request_settings_sync(){
    // Single-shot JSON construction
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, 
        llList2Json(JSON_OBJECT, ["type", MSG_SETTINGS_GET]), 
        NULL_KEY);
    return 0;
}

/* ---------- ACL evaluation ---------- */
integer compute_acl_level(key av){
    // Fast path: check owner first (most privileged)
    if (av == OwnerKey && OwnerKey != NULL_KEY) return ACL_PRIMARY_OWNER;
    
    // Check if wearer
    integer is_wearer = (av == WearerKey);
    if (is_wearer){
        if (TpeMode) return ACL_NOACCESS;
        if (OwnerKey != NULL_KEY) return ACL_OWNED;
        return ACL_UNOWNED;
    }
    
    // Check trustee
    if (list_has_key(TrusteeList, av)) return ACL_TRUSTEE;
    
    // Check blacklist
    if (list_has_key(Blacklist, av)) return ACL_BLACKLIST;
    
    // Public or blacklist based on public mode
    if (PublicMode) return ACL_PUBLIC;
    return ACL_BLACKLIST;
}

/* ---------- Central policy emission ---------- */
integer send_acl_result(key av, integer level){
    integer is_wearer = (av == WearerKey);
    integer owner_set = (OwnerKey != NULL_KEY);

    // Compute policy flags with optimized boolean logic
    integer policy_tpe = is_wearer && TpeMode;
    integer policy_owned_only = is_wearer && owner_set && !TpeMode;
    integer policy_wearer_unowned = is_wearer && !owner_set && !TpeMode;
    integer policy_trustee_access = (is_wearer && !owner_set) || (level == ACL_TRUSTEE);
    integer policy_public_only = !is_wearer && PublicMode;
    integer policy_primary_owner = level == ACL_PRIMARY_OWNER;

    // Single-pass JSON construction - all values in one llList2Json call
    string j = llList2Json(JSON_OBJECT, [
        "type", MSG_ACL_RESULT,
        "avatar", (string)av,
        "level", (string)level,
        "is_wearer", (string)is_wearer,
        "owner_set", (string)owner_set,
        "policy_tpe", (string)policy_tpe,
        "policy_public_only", (string)policy_public_only,
        "policy_owned_only", (string)policy_owned_only,
        "policy_trustee_access", (string)policy_trustee_access,
        "policy_wearer_unowned", (string)policy_wearer_unowned,
        "policy_primary_owner", (string)policy_primary_owner
    ]);

    llMessageLinked(LINK_SET, ACL_RESULT_NUM, j, NULL_KEY);
    return 0;
}

/* ---------- Events ---------- */
default{
    state_entry(){
        SettingsReady  = FALSE;
        PendingQueries = [];
        WearerKey      = llGetOwner();  // Cache wearer key
        request_settings_sync();
    }

    link_message(integer sender, integer num, string msg, key id){
        // Fast path: handle most common case first
        if (num == ACL_QUERY_NUM){
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type != MSG_ACL_QUERY) return;
            
            key av = (key)llJsonGetValue(msg, ["avatar"]);
            if (av == NULL_KEY) return;

            // Queue if not ready
            if (!SettingsReady){
                if (!list_has_key(PendingQueries, av)){
                    PendingQueries += [(string)av];
                }
                return;
            }

            // Process immediately
            send_acl_result(av, compute_acl_level(av));
            return;
        }

        if (num == SETTINGS_SYNC_NUM){
            apply_settings_sync(msg);
        }
    }
}
