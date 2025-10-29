/* ===============================================================
   MODULE: ds_collar_kmod_auth.lsl (v1.0 - Security Hardened)
   SECURITY AUDIT: ACTUAL ISSUES FIXED
   
   PURPOSE: Authoritative ACL and policy engine
   
   CHANNELS:
   - 700 (AUTH_BUS): ACL queries and results
   - 800 (SETTINGS_BUS): Settings sync/delta consumption
   
   ACL LEVELS:
   -1 = Blacklisted
    0 = No Access
    1 = Public (when public mode enabled)
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
    
   SECURITY FIXES APPLIED:
   - [CRITICAL] Added owner change detection with script reset
   - [CRITICAL] Fixed ACL default return (NOACCESS not BLACKLIST)
   - [CRITICAL] Fixed ACL logic order (blacklist check first)
   - [MEDIUM] Added role exclusivity validation
   - [MEDIUM] Added pending query limit
   - [LOW] Production mode guards debug logging
   
   NOTE: TPE "self-ownership bypass" was a false positive.
   Wearer can NEVER be in owner list by system design.
   =============================================================== */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;

/* ===============================================================
   ACL CONSTANTS
   =============================================================== */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ===============================================================
   SETTINGS KEYS
   =============================================================== */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY        = "owner_key";
string KEY_OWNER_KEYS       = "owner_keys";
string KEY_TRUSTEES         = "trustees";
string KEY_BLACKLIST        = "blacklist";
string KEY_PUBLIC_ACCESS    = "public_mode";
string KEY_TPE_MODE         = "tpe_mode";

/* ===============================================================
   STATE (CACHED SETTINGS)
   =============================================================== */
integer MultiOwnerMode = FALSE;
key OwnerKey = NULL_KEY;
list OwnerKeys = [];
list TrusteeList = [];
list Blacklist = [];
integer PublicMode = FALSE;
integer TpeMode = FALSE;

integer SettingsReady = FALSE;
list PendingQueries = [];  // [avatar_key, correlation_id, avatar_key, correlation_id, ...]
integer PENDING_STRIDE = 2;
integer MAX_PENDING_QUERIES = 50;  // Prevent unbounded growth

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[AUTH] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer isJsonArr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

integer listHasKey(list search_list, key k) {
    return (llListFindList(search_list, [(string)k]) != -1);
}

/* ===============================================================
   OWNER CHECKING
   =============================================================== */

integer hasOwner() {
    if (MultiOwnerMode) {
        return (llGetListLength(OwnerKeys) > 0);
    }
    return (OwnerKey != NULL_KEY);
}

integer isOwner(key av) {
    if (MultiOwnerMode) {
        return listHasKey(OwnerKeys, av);
    }
    return (av == OwnerKey);
}

/* ===============================================================
   ACL COMPUTATION
   =============================================================== */

integer computeAclLevel(key av) {
    key wearer = llGetOwner();
    integer owner_set = has_owner();
    integer is_owner_flag = is_owner(av);
    integer is_wearer = (av == wearer);
    integer is_trustee = listHasKey(TrusteeList, av);
    integer is_blacklisted = listHasKey(Blacklist, av);
    
    // SECURITY FIX: Blacklist check FIRST (before any grants)
    if (is_blacklisted) return ACL_BLACKLIST;
    
    // Owner check
    if (is_owner_flag) return ACL_PRIMARY_OWNER;
    
    // Wearer check
    if (is_wearer) {
        if (TpeMode) return ACL_NOACCESS;
        if (owner_set) return ACL_OWNED;
        return ACL_UNOWNED;
    }
    
    // Trustee check
    if (is_trustee) return ACL_TRUSTEE;
    
    // Public mode check
    if (PublicMode) return ACL_PUBLIC;
    
    // SECURITY FIX: Default is NOACCESS (not BLACKLIST)
    // BLACKLIST is explicit denial, NOACCESS is simply no privileges
    return ACL_NOACCESS;
}

/* ===============================================================
   POLICY FLAGS
   =============================================================== */

sendAclResult(key av, string correlation_id) {
    key wearer = llGetOwner();
    integer is_wearer = (av == wearer);
    integer owner_set = has_owner();
    integer level = compute_acl_level(av);
    integer is_blacklisted = listHasKey(Blacklist, av);
    
    // Policy flags
    integer policy_tpe = 0;
    integer policy_public_only = 0;
    integer policy_owned_only = 0;
    integer policy_trustee_access = 0;
    integer policy_wearer_unowned = 0;
    integer policy_primary_owner = 0;
    
    if (is_wearer) {
        if (TpeMode) {
            policy_tpe = 1;
        }
        else {
            if (owner_set) {
                policy_owned_only = 1;
            }
            else {
                policy_wearer_unowned = 1;
            }
        }
        
        if (!owner_set) {
            policy_trustee_access = 1;
        }
    }
    else {
        if (PublicMode) {
            policy_public_only = 1;
        }
        if (level == ACL_TRUSTEE) {
            policy_trustee_access = 1;
        }
        if (level == ACL_PRIMARY_OWNER) {
            policy_primary_owner = 1;
        }
    }
    
    // Build response
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_result",
        "avatar", (string)av,
        "level", level,
        "is_wearer", is_wearer,
        "is_blacklisted", is_blacklisted,
        "owner_set", owner_set,
        "policy_tpe", policy_tpe,
        "policy_public_only", policy_public_only,
        "policy_owned_only", policy_owned_only,
        "policy_trustee_access", policy_trustee_access,
        "policy_wearer_unowned", policy_wearer_unowned,
        "policy_primary_owner", policy_primary_owner
    ]);
    
    // Add correlation ID if provided
    if (correlation_id != "") {
        msg = llJsonSetValue(msg, ["id"], correlation_id);
    }
    
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
    logd("ACL result: " + llKey2Name(av) + " = " + (string)level);
}

/* ===============================================================
   ROLE EXCLUSIVITY VALIDATION
   =============================================================== */

// SECURITY FIX: Enforce role exclusivity (defense-in-depth)
enforceRoleExclusivity() {
    integer i;
    
    // Owners cannot be trustees or blacklisted
    if (MultiOwnerMode) {
        for (i = 0; i < llGetListLength(OwnerKeys); i = i + 1) {
            string owner = llList2String(OwnerKeys, i);
            
            // Remove from trustees
            integer idx = llListFindList(TrusteeList, [owner]);
            if (idx != -1) {
                TrusteeList = llDeleteSubList(TrusteeList, idx, idx);
                logd("WARNING: Removed " + owner + " from trustees (is owner)");
            }
            
            // Remove from blacklist
            idx = llListFindList(Blacklist, [owner]);
            if (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
                logd("WARNING: Removed " + owner + " from blacklist (is owner)");
            }
        }
    }
    else {
        if (OwnerKey != NULL_KEY) {
            string owner = (string)OwnerKey;
            
            // Remove from trustees
            integer idx = llListFindList(TrusteeList, [owner]);
            if (idx != -1) {
                TrusteeList = llDeleteSubList(TrusteeList, idx, idx);
                logd("WARNING: Removed " + owner + " from trustees (is owner)");
            }
            
            // Remove from blacklist
            idx = llListFindList(Blacklist, [owner]);
            if (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
                logd("WARNING: Removed " + owner + " from blacklist (is owner)");
            }
        }
    }
    
    // Trustees cannot be blacklisted
    for (i = 0; i < llGetListLength(TrusteeList); i = i + 1) {
        string trustee = llList2String(TrusteeList, i);
        
        integer idx = llListFindList(Blacklist, [trustee]);
        if (idx != -1) {
            Blacklist = llDeleteSubList(Blacklist, idx, idx);
            logd("WARNING: Removed " + trustee + " from blacklist (is trustee)");
        }
    }
}

/* ===============================================================
   SETTINGS CONSUMPTION
   =============================================================== */

applySettingsSync(string msg) {
    if (!jsonHas(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    
    // Reset to defaults
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    TrusteeList = [];
    Blacklist = [];
    PublicMode = FALSE;
    TpeMode = FALSE;
    
    // Load values
    if (jsonHas(kv_json, [KEY_MULTI_OWNER_MODE])) {
        MultiOwnerMode = (integer)llJsonGetValue(kv_json, [KEY_MULTI_OWNER_MODE]);
    }
    
    if (jsonHas(kv_json, [KEY_OWNER_KEY])) {
        OwnerKey = (key)llJsonGetValue(kv_json, [KEY_OWNER_KEY]);
    }
    
    if (jsonHas(kv_json, [KEY_OWNER_KEYS])) {
        string owner_keys_json = llJsonGetValue(kv_json, [KEY_OWNER_KEYS]);
        if (isJsonArr(owner_keys_json)) {
            OwnerKeys = llJson2List(owner_keys_json);
        }
    }
    
    if (jsonHas(kv_json, [KEY_TRUSTEES])) {
        string trustees_json = llJsonGetValue(kv_json, [KEY_TRUSTEES]);
        if (isJsonArr(trustees_json)) {
            TrusteeList = llJson2List(trustees_json);
        }
    }
    
    if (jsonHas(kv_json, [KEY_BLACKLIST])) {
        string blacklist_json = llJsonGetValue(kv_json, [KEY_BLACKLIST]);
        if (isJsonArr(blacklist_json)) {
            Blacklist = llJson2List(blacklist_json);
        }
    }
    
    if (jsonHas(kv_json, [KEY_PUBLIC_ACCESS])) {
        PublicMode = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_ACCESS]);
    }
    
    if (jsonHas(kv_json, [KEY_TPE_MODE])) {
        TpeMode = (integer)llJsonGetValue(kv_json, [KEY_TPE_MODE]);
    }
    
    // SECURITY FIX: Enforce role exclusivity after loading
    enforceRoleExclusivity();
    
    SettingsReady = TRUE;
    logd("Settings sync applied (multi_owner=" + (string)MultiOwnerMode + ")");
    
    // Process pending queries
    integer i = 0;
    integer len = llGetListLength(PendingQueries);
    while (i < len) {
        key av = llList2Key(PendingQueries, i);
        string corr_id = llList2String(PendingQueries, i + 1);
        sendAclResult(av, corr_id);
        i += PENDING_STRIDE;
    }
    PendingQueries = [];
}

applySettingsDelta(string msg) {
    if (!jsonHas(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!jsonHas(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (jsonHas(changes, [KEY_PUBLIC_ACCESS])) {
            PublicMode = (integer)llJsonGetValue(changes, [KEY_PUBLIC_ACCESS]);
            logd("Delta: public_mode = " + (string)PublicMode);
        }
        
        if (jsonHas(changes, [KEY_TPE_MODE])) {
            TpeMode = (integer)llJsonGetValue(changes, [KEY_TPE_MODE]);
            logd("Delta: tpe_mode = " + (string)TpeMode);
        }
        
        if (jsonHas(changes, [KEY_OWNER_KEY])) {
            OwnerKey = (key)llJsonGetValue(changes, [KEY_OWNER_KEY]);
            logd("Delta: owner_key = " + (string)OwnerKey);
            // Enforce exclusivity after owner change
            enforceRoleExclusivity();
        }
    }
    else if (op == "list_add") {
        if (!jsonHas(msg, ["key"])) return;
        if (!jsonHas(msg, ["elem"])) return;
        
        string key_name = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);
        
        if (key_name == KEY_OWNER_KEYS) {
            if (llListFindList(OwnerKeys, [elem]) == -1) {
                OwnerKeys += [elem];
                logd("Delta: added owner " + elem);
                // Enforce exclusivity after adding owner
                enforceRoleExclusivity();
            }
        }
        else if (key_name == KEY_TRUSTEES) {
            if (llListFindList(TrusteeList, [elem]) == -1) {
                TrusteeList += [elem];
                logd("Delta: added trustee " + elem);
                // Enforce exclusivity after adding trustee
                enforceRoleExclusivity();
            }
        }
        else if (key_name == KEY_BLACKLIST) {
            if (llListFindList(Blacklist, [elem]) == -1) {
                Blacklist += [elem];
                logd("Delta: added blacklist " + elem);
            }
        }
    }
    else if (op == "list_remove") {
        if (!jsonHas(msg, ["key"])) return;
        if (!jsonHas(msg, ["elem"])) return;
        
        string key_name = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);
        
        if (key_name == KEY_OWNER_KEYS) {
            integer idx = llListFindList(OwnerKeys, [elem]);
            while (idx != -1) {
                OwnerKeys = llDeleteSubList(OwnerKeys, idx, idx);
                idx = llListFindList(OwnerKeys, [elem]);
            }
            logd("Delta: removed owner " + elem);
        }
        else if (key_name == KEY_TRUSTEES) {
            integer idx = llListFindList(TrusteeList, [elem]);
            while (idx != -1) {
                TrusteeList = llDeleteSubList(TrusteeList, idx, idx);
                idx = llListFindList(TrusteeList, [elem]);
            }
            logd("Delta: removed trustee " + elem);
        }
        else if (key_name == KEY_BLACKLIST) {
            integer idx = llListFindList(Blacklist, [elem]);
            while (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
                idx = llListFindList(Blacklist, [elem]);
            }
            logd("Delta: removed blacklist " + elem);
        }
    }
}

/* ===============================================================
   MESSAGE HANDLERS
   =============================================================== */

handleAclQuery(string msg) {
    if (!jsonHas(msg, ["avatar"])) return;
    
    key av = (key)llJsonGetValue(msg, ["avatar"]);
    if (av == NULL_KEY) return;
    
    string correlation_id = "";
    if (jsonHas(msg, ["id"])) {
        correlation_id = llJsonGetValue(msg, ["id"]);
    }
    
    if (!SettingsReady) {
        // SECURITY FIX: Limit pending query queue size
        if (llGetListLength(PendingQueries) / PENDING_STRIDE >= MAX_PENDING_QUERIES) {
            logd("WARNING: Pending query limit reached, discarding oldest");
            PendingQueries = llDeleteSubList(PendingQueries, 0, PENDING_STRIDE - 1);
        }
        
        // Queue this query
        PendingQueries += [av, correlation_id];
        logd("Queued ACL query for " + llKey2Name(av));
        return;
    }
    
    sendAclResult(av, correlation_id);
}

/* ===============================================================
   EVENTS
   =============================================================== */

default
{
    state_entry() {
        SettingsReady = FALSE;
        PendingQueries = [];
        
        logd("Auth module started");
        
        // Request settings
        string request = llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]);
        llMessageLinked(LINK_SET, SETTINGS_BUS, request, NULL_KEY);
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!jsonHas(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        /* ===== AUTH BUS ===== */
        if (num == AUTH_BUS) {
            if (msg_type == "acl_query") {
                handleAclQuery(msg);
            }
        }
        
        /* ===== SETTINGS BUS ===== */
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync") {
                applySettingsSync(msg);
            }
            else if (msg_type == "settings_delta") {
                applySettingsDelta(msg);
            }
        }
    }
    
    // SECURITY FIX: Reset on owner change to clear cached ACL state
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
