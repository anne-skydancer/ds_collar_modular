/*--------------------
MODULE: ds_collar_kmod_auth.lsl
VERSION: 1.00
REVISION: 23
PURPOSE: Authoritative ACL and policy engine
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- REVISION 23: Changed default ACL for unauthorized users from 0 (NOACCESS) to -1 (BLACKLIST)
  to distinguish public touchers when public mode is off from TPE wearers (who stay at 0).
  - SECURITY: Prevents unauthorized users from accessing SOS menu (ACL 0) by exploiting
    the ambiguity between "Public Access Off" and "TPE Restricted Wearer".
- Implemented event-driven ACL invalidation (broadcast_acl_change)
- Enforced immediate session revocation on role changes
- Owner change detection resets the module to prevent stale ACL data
- Corrected default ACL response to return NOACCESS instead of BLACKLIST
- Reordered blacklist evaluation to run before other access checks
- Enforced role exclusivity and capped pending query growth
- Guarded debug logging for safer production deployments
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;

/* -------------------- ACL CONSTANTS -------------------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY        = "owner_key";
string KEY_OWNER_KEYS       = "owner_keys";
string KEY_TRUSTEES         = "trustees";
string KEY_BLACKLIST        = "blacklist";
string KEY_PUBLIC_ACCESS    = "public_mode";
string KEY_TPE_MODE         = "tpe_mode";

/* -------------------- LINKSET DATA KEYS -------------------- */
string LSD_KEY_ACL_OWNERS    = "ACL.OWNERS";
string LSD_KEY_ACL_TRUSTEES  = "ACL.TRUSTEES";
string LSD_KEY_ACL_BLACKLIST = "ACL.BLACKLIST";
string LSD_KEY_ACL_PUBLIC    = "ACL.PUBLIC";
string LSD_KEY_ACL_TPE       = "ACL.TPE";
string LSD_KEY_ACL_TIMESTAMP = "ACL.TIMESTAMP";

/* -------------------- STATE (CACHED SETTINGS) -------------------- */
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

/* Plugin ACL registry: [context, min_acl, context, min_acl, ...] */
list PluginAclRegistry = [];
integer PLUGIN_ACL_STRIDE = 2;
integer PLUGIN_ACL_CONTEXT = 0;
integer PLUGIN_ACL_MIN_ACL = 1;

/* -------------------- ACL CACHE HELPERS -------------------- */

persist_acl_cache() {
    list owners_payload = [];
    if (MultiOwnerMode) {
        owners_payload = OwnerKeys;
    }
    else if (OwnerKey != NULL_KEY) {
        owners_payload = [(string)OwnerKey];
    }

    string owners_json = llList2Json(JSON_ARRAY, owners_payload);
    string trustees_json = llList2Json(JSON_ARRAY, TrusteeList);
    string blacklist_json = llList2Json(JSON_ARRAY, Blacklist);

    llLinksetDataWrite(LSD_KEY_ACL_OWNERS, owners_json);
    llLinksetDataWrite(LSD_KEY_ACL_TRUSTEES, trustees_json);
    llLinksetDataWrite(LSD_KEY_ACL_BLACKLIST, blacklist_json);
    llLinksetDataWrite(LSD_KEY_ACL_PUBLIC, (string)PublicMode);
    llLinksetDataWrite(LSD_KEY_ACL_TPE, (string)TpeMode);

    integer timestamp = llGetUnixTime();
    llLinksetDataWrite(LSD_KEY_ACL_TIMESTAMP, (string)timestamp);

    string update_msg = llList2Json(JSON_OBJECT, [
        "type", "acl_cache_updated",
        "timestamp", (string)timestamp
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, update_msg, NULL_KEY);
}

/* -------------------- HELPERS -------------------- */


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

integer list_has_key(list search_list, key k) {
    return (llListFindList(search_list, [(string)k]) != -1);
}

/* -------------------- OWNER CHECKING -------------------- */

integer has_owner() {
    if (MultiOwnerMode) {
        return (llGetListLength(OwnerKeys) > 0);
    }
    return (OwnerKey != NULL_KEY);
}

integer is_owner(key av) {
    if (MultiOwnerMode) {
        return list_has_key(OwnerKeys, av);
    }
    return (av == OwnerKey);
}

/* -------------------- ACL COMPUTATION -------------------- */

broadcast_acl_change(string scope, key avatar) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_update",
        "scope", scope,
        "avatar", (string)avatar
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

integer compute_acl_level(key av) {
    key wearer = llGetOwner();
    integer owner_set = has_owner();
    integer is_owner_flag = is_owner(av);
    integer is_wearer = (av == wearer);
    integer is_trustee = list_has_key(TrusteeList, av);
    integer is_blacklisted = list_has_key(Blacklist, av);
    
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
    
    // Default for non-authorized users is BLACKLIST (-1) to distinguish from TPE Wearer (0)
    return ACL_BLACKLIST;
}

/* -------------------- PLUGIN ACL MANAGEMENT -------------------- */

// Register or update plugin ACL requirement
register_plugin_acl(string context, integer min_acl) {
    // Find existing entry
    integer idx = llListFindList(PluginAclRegistry, [context]);
    if (idx != -1) {
        // Update existing
        PluginAclRegistry = llListReplaceList(PluginAclRegistry, [min_acl],
            idx + PLUGIN_ACL_MIN_ACL, idx + PLUGIN_ACL_MIN_ACL);
        return;
    }

    // Add new entry
    PluginAclRegistry += [context, min_acl];
}

// Broadcast plugin ACL list to UI
broadcast_plugin_acl_list() {
    list acl_data = [];
    integer i = 0;
    integer len = llGetListLength(PluginAclRegistry);

    while (i < len) {
        string context = llList2String(PluginAclRegistry, i + PLUGIN_ACL_CONTEXT);
        integer min_acl = llList2Integer(PluginAclRegistry, i + PLUGIN_ACL_MIN_ACL);

        string acl_obj = llList2Json(JSON_OBJECT, [
            "context", context,
            "min_acl", min_acl
        ]);

        acl_data += [acl_obj];
        i += PLUGIN_ACL_STRIDE;
    }

    // Build array using native function
    string acl_array = "[" + llDumpList2String(acl_data, ",") + "]";

    // Manual outer object construction for same reason
    string msg = "{\"type\":\"plugin_acl_list\",\"acl_data\":" + acl_array + "}";
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

// Check if user can access a specific plugin


// Filter plugin list for user - returns list of accessible contexts
list filter_plugins_for_user(key user, list plugin_contexts) {
    list accessible = [];
    integer user_acl = compute_acl_level(user);

    integer i = 0;
    integer len = llGetListLength(plugin_contexts);
    while (i < len) {
        string context = llList2String(plugin_contexts, i);

        // Find plugin's ACL requirement
        integer idx = llListFindList(PluginAclRegistry, [context]);
        if (idx != -1) {
            integer required_acl = llList2Integer(PluginAclRegistry, idx + PLUGIN_ACL_MIN_ACL);
            if (user_acl >= required_acl) {
                accessible += [context];
            }
        }
        i++;
    }

    return accessible;
}

/* -------------------- POLICY FLAGS -------------------- */

send_acl_result(key av, string correlation_id) {
    key wearer = llGetOwner();
    integer is_wearer = (av == wearer);
    integer owner_set = has_owner();
    integer level = compute_acl_level(av);
    integer is_blacklisted = list_has_key(Blacklist, av);
    
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
}

/* -------------------- ROLE EXCLUSIVITY VALIDATION -------------------- */

// SECURITY FIX: Enforce role exclusivity (defense-in-depth)
enforce_role_exclusivity() {
    integer i;
    
    // Owners cannot be trustees or blacklisted
    if (MultiOwnerMode) {
        for (i = 0; i < llGetListLength(OwnerKeys); i = i + 1) {
            string owner = llList2String(OwnerKeys, i);
            
            // Remove from trustees
            integer idx = llListFindList(TrusteeList, [owner]);
            if (idx != -1) {
                TrusteeList = llDeleteSubList(TrusteeList, idx, idx);
            }
            
            // Remove from blacklist
            idx = llListFindList(Blacklist, [owner]);
            if (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
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
            }
            
            // Remove from blacklist
            idx = llListFindList(Blacklist, [owner]);
            if (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
            }
        }
    }
    
    // Trustees cannot be blacklisted
    for (i = 0; i < llGetListLength(TrusteeList); i = i + 1) {
        string trustee = llList2String(TrusteeList, i);
        
        integer idx = llListFindList(Blacklist, [trustee]);
        if (idx != -1) {
            Blacklist = llDeleteSubList(Blacklist, idx, idx);
        }
    }
}

/* -------------------- SETTINGS CONSUMPTION -------------------- */

apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
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
    if (json_has(kv_json, [KEY_MULTI_OWNER_MODE])) {
        MultiOwnerMode = (integer)llJsonGetValue(kv_json, [KEY_MULTI_OWNER_MODE]);
    }
    
    if (json_has(kv_json, [KEY_OWNER_KEY])) {
        OwnerKey = (key)llJsonGetValue(kv_json, [KEY_OWNER_KEY]);
    }
    
    if (json_has(kv_json, [KEY_OWNER_KEYS])) {
        string owner_keys_json = llJsonGetValue(kv_json, [KEY_OWNER_KEYS]);
        if (is_json_arr(owner_keys_json)) {
            OwnerKeys = llJson2List(owner_keys_json);
        }
    }
    
    if (json_has(kv_json, [KEY_TRUSTEES])) {
        string trustees_json = llJsonGetValue(kv_json, [KEY_TRUSTEES]);
        if (is_json_arr(trustees_json)) {
            TrusteeList = llJson2List(trustees_json);
        }
    }
    
    if (json_has(kv_json, [KEY_BLACKLIST])) {
        string blacklist_json = llJsonGetValue(kv_json, [KEY_BLACKLIST]);
        if (is_json_arr(blacklist_json)) {
            Blacklist = llJson2List(blacklist_json);
        }
    }
    
    if (json_has(kv_json, [KEY_PUBLIC_ACCESS])) {
        PublicMode = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_ACCESS]);
    }
    
    if (json_has(kv_json, [KEY_TPE_MODE])) {
        TpeMode = (integer)llJsonGetValue(kv_json, [KEY_TPE_MODE]);
    }
    
    // SECURITY FIX: Enforce role exclusivity after loading
    enforce_role_exclusivity();
    persist_acl_cache();
    
    SettingsReady = TRUE;
    
    // Broadcast global update to invalidate stale UI sessions
    broadcast_acl_change("global", NULL_KEY);
    
    // Process pending queries
    integer i = 0;
    integer len = llGetListLength(PendingQueries);
    while (i < len) {
        key av = llList2Key(PendingQueries, i);
        string corr_id = llList2String(PendingQueries, i + 1);
        send_acl_result(av, corr_id);
        i += PENDING_STRIDE;
    }
    PendingQueries = [];
}

apply_settings_delta(string msg) {
    if (!json_has(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    integer cache_dirty = FALSE;
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (json_has(changes, [KEY_PUBLIC_ACCESS])) {
            PublicMode = (integer)llJsonGetValue(changes, [KEY_PUBLIC_ACCESS]);
            broadcast_acl_change("global", NULL_KEY);
            cache_dirty = TRUE;
        }
        
        if (json_has(changes, [KEY_TPE_MODE])) {
            TpeMode = (integer)llJsonGetValue(changes, [KEY_TPE_MODE]);
            broadcast_acl_change("global", NULL_KEY);
            cache_dirty = TRUE;
        }
        
        if (json_has(changes, [KEY_OWNER_KEY])) {
            OwnerKey = (key)llJsonGetValue(changes, [KEY_OWNER_KEY]);
            // Enforce exclusivity after owner change
            enforce_role_exclusivity();
            broadcast_acl_change("global", NULL_KEY); // Owner change affects everyone
            cache_dirty = TRUE;
        }
    }
    else if (op == "list_add") {
        if (!json_has(msg, ["key"])) return;
        if (!json_has(msg, ["elem"])) return;
        
        string key_name = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);
        
        if (key_name == KEY_OWNER_KEYS) {
            if (llListFindList(OwnerKeys, [elem]) == -1) {
                OwnerKeys += [elem];
                // Enforce exclusivity after adding owner
                enforce_role_exclusivity();
                broadcast_acl_change("global", NULL_KEY);
                cache_dirty = TRUE;
            }
        }
        else if (key_name == KEY_TRUSTEES) {
            if (llListFindList(TrusteeList, [elem]) == -1) {
                TrusteeList += [elem];
                // Enforce exclusivity after adding trustee
                enforce_role_exclusivity();
                broadcast_acl_change("avatar", (key)elem);
                cache_dirty = TRUE;
            }
        }
        else if (key_name == KEY_BLACKLIST) {
            if (llListFindList(Blacklist, [elem]) == -1) {
                Blacklist += [elem];
                broadcast_acl_change("avatar", (key)elem);
                cache_dirty = TRUE;
            }
        }
    }
    else if (op == "list_remove") {
        if (!json_has(msg, ["key"])) return;
        if (!json_has(msg, ["elem"])) return;
        
        string key_name = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);
        
        if (key_name == KEY_OWNER_KEYS) {
            integer idx = llListFindList(OwnerKeys, [elem]);
            while (idx != -1) {
                OwnerKeys = llDeleteSubList(OwnerKeys, idx, idx);
                idx = llListFindList(OwnerKeys, [elem]);
            }
            broadcast_acl_change("global", NULL_KEY);
            cache_dirty = TRUE;
        }
        else if (key_name == KEY_TRUSTEES) {
            integer idx = llListFindList(TrusteeList, [elem]);
            while (idx != -1) {
                TrusteeList = llDeleteSubList(TrusteeList, idx, idx);
                idx = llListFindList(TrusteeList, [elem]);
            }
            broadcast_acl_change("avatar", (key)elem);
            cache_dirty = TRUE;
        }
        else if (key_name == KEY_BLACKLIST) {
            integer idx = llListFindList(Blacklist, [elem]);
            while (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
                idx = llListFindList(Blacklist, [elem]);
            }
            broadcast_acl_change("avatar", (key)elem);
            cache_dirty = TRUE;
        }
    }

    if (cache_dirty) {
        persist_acl_cache();
    }
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_acl_query(string msg) {
    if (!json_has(msg, ["avatar"])) return;

    key av = (key)llJsonGetValue(msg, ["avatar"]);
    if (av == NULL_KEY) return;

    string correlation_id = "";
    if (json_has(msg, ["id"])) {
        correlation_id = llJsonGetValue(msg, ["id"]);
    }

    if (!SettingsReady) {
        // SECURITY FIX: Limit pending query queue size
        if (llGetListLength(PendingQueries) / PENDING_STRIDE >= MAX_PENDING_QUERIES) {
            PendingQueries = llDeleteSubList(PendingQueries, 0, PENDING_STRIDE - 1);
        }

        // Queue this query
        PendingQueries += [av, correlation_id];
        return;
    }

    send_acl_result(av, correlation_id);
}

handle_register_acl(string msg) {
    if (!json_has(msg, ["context"])) return;
    if (!json_has(msg, ["min_acl"])) return;

    string context = llJsonGetValue(msg, ["context"]);
    integer min_acl = (integer)llJsonGetValue(msg, ["min_acl"]);

    register_plugin_acl(context, min_acl);
}

handle_filter_plugins(string msg) {
    if (!json_has(msg, ["user"])) return;
    if (!json_has(msg, ["contexts"])) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    string contexts_json = llJsonGetValue(msg, ["contexts"]);

    // Parse contexts array
    list contexts = llJson2List(contexts_json);

    // Filter based on user's ACL
    list accessible = filter_plugins_for_user(user, contexts);

    // Build response
    string accessible_json = llList2Json(JSON_ARRAY, accessible);
    string response = llList2Json(JSON_OBJECT, [
        "type", "filtered_plugins",
        "user", (string)user,
        "contexts", accessible_json
    ]);

    llMessageLinked(LINK_SET, AUTH_BUS, response, NULL_KEY);
}

handle_plugin_acl_list_request() {
    broadcast_plugin_acl_list();
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        SettingsReady = FALSE;
        PendingQueries = [];
        PluginAclRegistry = [];


        // Request ACL registry repopulation from kernel (P1 security fix)
        string acl_request = llList2Json(JSON_OBJECT, [
            "type", "acl_registry_request"
        ]);
        llMessageLinked(LINK_SET, AUTH_BUS, acl_request, NULL_KEY);

        // Request settings
        string request = llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]);
        llMessageLinked(LINK_SET, SETTINGS_BUS, request, NULL_KEY);
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!json_has(msg, ["type"])) return;

        string msg_type = llJsonGetValue(msg, ["type"]);

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                llResetScript();
            }
        }

        /* -------------------- AUTH BUS -------------------- */
        else if (num == AUTH_BUS) {
            if (msg_type == "acl_query") {
                handle_acl_query(msg);
            }
            else if (msg_type == "register_acl") {
                handle_register_acl(msg);
            }
            else if (msg_type == "filter_plugins") {
                handle_filter_plugins(msg);
            }
            else if (msg_type == "plugin_acl_list_request") {
                handle_plugin_acl_list_request();
            }
        }
        
        /* -------------------- SETTINGS BUS -------------------- */
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
            }
            else if (msg_type == "settings_delta") {
                apply_settings_delta(msg);
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
