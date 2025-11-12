/*--------------------
MODULE: ds_collar_kmod_auth.lsl
VERSION: 1.00
REVISION: 21
PURPOSE: Authoritative ACL and policy engine
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Owner change detection resets the module to prevent stale ACL data
- Corrected default ACL response to return NOACCESS instead of BLACKLIST
- Reordered blacklist evaluation to run before other access checks
- Enforced role exclusivity and capped pending query growth
- Guarded debug logging for safer production deployments
--------------------*/

integer DEBUG = TRUE;
integer PRODUCTION = FALSE;  // Set FALSE for development builds

string SCRIPT_ID = "kmod_auth";

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

/* -------------------- HELPERS -------------------- */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[AUTH] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

integer list_has_key(list search_list, key k) {
    return (llListFindList(search_list, [(string)k]) != -1);
}

/* -------------------- MESSAGE ROUTING -------------------- */

integer is_message_for_me(string msg) {
    if (llGetSubString(msg, 0, 0) != "{") return FALSE;
    
    integer to_pos = llSubStringIndex(msg, "\"to\"");
    if (to_pos == -1) return TRUE;  // No routing = broadcast
    
    string header = llGetSubString(msg, 0, to_pos + 100);
    
    if (llSubStringIndex(header, "\"*\"") != -1) return TRUE;
    if (llSubStringIndex(header, SCRIPT_ID) != -1) return TRUE;
    if (llSubStringIndex(header, "\"kmod:*\"") != -1) return TRUE;
    
    return FALSE;
}

string create_routed_message(string to_id, list fields) {
    list routed = ["from", SCRIPT_ID, "to", to_id] + fields;
    return llList2Json(JSON_OBJECT, routed);
}

string create_broadcast(list fields) {
    return create_routed_message("*", fields);
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
    
    // SECURITY FIX: Default is NOACCESS (not BLACKLIST)
    // BLACKLIST is explicit denial, NOACCESS is simply no privileges
    return ACL_NOACCESS;
}

/* -------------------- PLUGIN ACL MANAGEMENT -------------------- */

// Register or update plugin ACL requirement
register_plugin_acl(string context, integer min_acl) {
    // Find existing entry
    integer i = 0;
    integer len = llGetListLength(PluginAclRegistry);
    while (i < len) {
        if (llList2String(PluginAclRegistry, i + PLUGIN_ACL_CONTEXT) == context) {
            // Update existing
            PluginAclRegistry = llListReplaceList(PluginAclRegistry, [min_acl],
                i + PLUGIN_ACL_MIN_ACL, i + PLUGIN_ACL_MIN_ACL);
            logd("Updated plugin ACL: " + context + " requires " + (string)min_acl);
            return;
        }
        i += PLUGIN_ACL_STRIDE;
    }

    // Add new entry
    PluginAclRegistry += [context, min_acl];
    logd("Registered plugin ACL: " + context + " requires " + (string)min_acl);
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

    // Build array - manual construction required because acl_data contains
    // pre-serialized JSON objects; llList2Json would quote them incorrectly
    string acl_array = "[";
    integer j;
    integer acl_data_len = llGetListLength(acl_data);
    for (j = 0; j < acl_data_len; j = j + 1) {
        if (j > 0) acl_array += ",";
        acl_array += llList2String(acl_data, j);
    }
    acl_array += "]";

    // Manual outer object construction with routing
    string msg = "{\"from\":\"" + SCRIPT_ID + "\",\"to\":\"*\",\"type\":\"plugin_acl_list\",\"acl_data\":" + acl_array + "}";
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
    logd("Broadcast plugin ACL list: " + (string)llGetListLength(acl_data) + " entries");
}

// Check if user can access a specific plugin
integer can_access_plugin(key user, string context) {
    // Find plugin's ACL requirement
    integer i = 0;
    integer len = llGetListLength(PluginAclRegistry);
    while (i < len) {
        if (llList2String(PluginAclRegistry, i + PLUGIN_ACL_CONTEXT) == context) {
            integer required_acl = llList2Integer(PluginAclRegistry, i + PLUGIN_ACL_MIN_ACL);
            integer user_acl = compute_acl_level(user);
            return (user_acl >= required_acl);
        }
        i += PLUGIN_ACL_STRIDE;
    }

    // Plugin not registered - deny by default
    return FALSE;
}

// Filter plugin list for user - returns list of accessible contexts
list filter_plugins_for_user(key user, list plugin_contexts) {
    list accessible = [];
    integer user_acl = compute_acl_level(user);

    integer i = 0;
    integer len = llGetListLength(plugin_contexts);
    while (i < len) {
        string context = llList2String(plugin_contexts, i);

        // Find plugin's ACL requirement
        integer j = 0;
        integer reg_len = llGetListLength(PluginAclRegistry);
        while (j < reg_len) {
            if (llList2String(PluginAclRegistry, j + PLUGIN_ACL_CONTEXT) == context) {
                integer required_acl = llList2Integer(PluginAclRegistry, j + PLUGIN_ACL_MIN_ACL);
                if (user_acl >= required_acl) {
                    accessible += [context];
                }
                jump next_plugin;
            }
            j += PLUGIN_ACL_STRIDE;
        }

        @next_plugin;
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
    string msg = create_broadcast([
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

/* -------------------- SETTINGS CONSUMPTION (PHASE 2: Linkset Data) -------------------- */

apply_settings_sync(string msg) {
    // PHASE 2: No "kv" payload - read directly from linkset data
    
    // Reset to defaults
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    TrusteeList = [];
    Blacklist = [];
    PublicMode = FALSE;
    TpeMode = FALSE;
    
    // Load values from linkset data
    string val = llLinksetDataRead(KEY_MULTI_OWNER_MODE);
    if (val != "") {
        MultiOwnerMode = (integer)val;
    }
    
    val = llLinksetDataRead(KEY_OWNER_KEY);
    if (val != "") {
        OwnerKey = (key)val;
    }
    
    val = llLinksetDataRead(KEY_OWNER_KEYS);
    if (val != "" && is_json_arr(val)) {
        OwnerKeys = llJson2List(val);
    }
    
    val = llLinksetDataRead(KEY_TRUSTEES);
    if (val != "" && is_json_arr(val)) {
        TrusteeList = llJson2List(val);
    }
    
    val = llLinksetDataRead(KEY_BLACKLIST);
    if (val != "" && is_json_arr(val)) {
        Blacklist = llJson2List(val);
    }
    
    val = llLinksetDataRead(KEY_PUBLIC_ACCESS);
    if (val != "") {
        PublicMode = (integer)val;
    }
    
    val = llLinksetDataRead(KEY_TPE_MODE);
    if (val != "") {
        TpeMode = (integer)val;
    }
    
    // SECURITY FIX: Enforce role exclusivity after loading
    enforce_role_exclusivity();
    
    SettingsReady = TRUE;
    logd("Settings sync applied (multi_owner=" + (string)MultiOwnerMode + ")");
    
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
    // PHASE 2: Simplified - just re-read affected keys from linkset data
    if (!json_has(msg, ["key"])) return;
    
    string key_name = llJsonGetValue(msg, ["key"]);
    string val = llLinksetDataRead(key_name);
    
    // Update cached values based on which key changed
    if (key_name == KEY_PUBLIC_ACCESS) {
        PublicMode = (integer)val;
        logd("Delta: public_mode = " + (string)PublicMode);
    }
    else if (key_name == KEY_TPE_MODE) {
        TpeMode = (integer)val;
        logd("Delta: tpe_mode = " + (string)TpeMode);
    }
    else if (key_name == KEY_OWNER_KEY) {
        OwnerKey = (key)val;
        logd("Delta: owner_key = " + (string)OwnerKey);
        enforce_role_exclusivity();
    }
    else if (key_name == KEY_OWNER_KEYS) {
        if (val != "" && is_json_arr(val)) {
            OwnerKeys = llJson2List(val);
            logd("Delta: owner_keys updated");
            enforce_role_exclusivity();
        }
    }
    else if (key_name == KEY_TRUSTEES) {
        if (val != "" && is_json_arr(val)) {
            TrusteeList = llJson2List(val);
            logd("Delta: trustees updated");
            enforce_role_exclusivity();
        }
    }
    else if (key_name == KEY_BLACKLIST) {
        if (val != "" && is_json_arr(val)) {
            Blacklist = llJson2List(val);
            logd("Delta: blacklist updated");
        }
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
            logd("WARNING: Pending query limit reached, discarding oldest");
            PendingQueries = llDeleteSubList(PendingQueries, 0, PENDING_STRIDE - 1);
        }

        // Queue this query
        PendingQueries += [av, correlation_id];
        logd("Queued ACL query for " + llKey2Name(av));
        return;
    }

    // Compute and send result
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
    string response = create_broadcast([
        "type", "filtered_plugins",
        "user", (string)user,
        "contexts", accessible_json
    ]);

    llMessageLinked(LINK_SET, AUTH_BUS, response, NULL_KEY);
    logd("Filtered plugins for " + llKey2Name(user) + ": " + (string)llGetListLength(accessible) + "/" + (string)llGetListLength(contexts));
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

        logd("Auth module started (with plugin ACL registry)");

        // Request ACL registry repopulation from kernel (P1 security fix)
        string acl_request = create_routed_message("ds_collar_kernel", [
            "type", "acl_registry_request"
        ]);
        llMessageLinked(LINK_SET, AUTH_BUS, acl_request, NULL_KEY);

        // Request settings
        string request = create_routed_message("kmod_settings", [
            "type", "settings_get"
        ]);
        llMessageLinked(LINK_SET, SETTINGS_BUS, request, NULL_KEY);
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        // Early filter: ignore messages not for us
        if (!is_message_for_me(msg)) return;
        
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
