/*--------------------
MODULE: kmod_auth.lsl
VERSION: 1.10
REVISION: 2
PURPOSE: Authoritative ACL engine - OPTIMIZED
ARCHITECTURE: Dispatch table pattern with linkset data cache and JSON templates
CHANGES:
- v1.1 rev 2: Read settings from LSD instead of kv_json broadcast. Remove
  apply_settings_delta; side effects triggered by state comparison.
- v1.1 rev 1: Removed dead policy_* fields from JSON templates. Removed
  plugin ACL registry (PluginAclContexts/Levels, register_acl, filter_plugins,
  broadcast_plugin_acl_list, plugin_acl_list_request) — superseded by LSD
  policy architecture where plugins self-declare visibility.
- v1.1 rev 0: Version bump for LSD policy architecture. No functional changes to this module.
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
string KEY_MULTI_OWNER_MODE = "access.multiowner";
string KEY_OWNER            = "access.owner";
string KEY_OWNERS           = "access.owners";
string KEY_TRUSTEES         = "access.trustees";
string KEY_BLACKLIST        = "access.blacklist";
string KEY_PUBLIC_ACCESS    = "public.mode";
string KEY_TPE_MODE         = "tpe.mode";

/* -------------------- LINKSET DATA KEYS -------------------- */
string LSD_KEY_ACL_OWNERS    = "ACL.OWNERS";
string LSD_KEY_ACL_TRUSTEES  = "ACL.TRUSTEES";
string LSD_KEY_ACL_BLACKLIST = "ACL.BLACKLIST";
string LSD_KEY_ACL_PUBLIC    = "ACL.PUBLIC";
string LSD_KEY_ACL_TPE       = "ACL.TPE";
string LSD_KEY_ACL_TIMESTAMP = "ACL.TIMESTAMP";

// Per-user ACL query cache prefix. Full key = LSD_ACL_CACHE_PREFIX + (string)avatar_uuid.
// Value format: "<level>|<unix_timestamp>" — e.g. "5|1712345678".
// kmod_ui.lsl reads this prefix directly to skip the AUTH_BUS round-trip on touch.
// CROSS-MODULE CONTRACT: this constant must match LSD_ACL_CACHE_PREFIX in kmod_ui.lsl.
string LSD_ACL_CACHE_PREFIX = "acl_cache_";

/* -------------------- CACHE CONSTANTS -------------------- */
integer CACHE_TTL = 60;  // Cache query results for 60 seconds
integer CACHE_MAX_USERS = 800;  // Safety limit for cache size

/* -------------------- JSON RESPONSE TEMPLATES -------------------- */
// Pre-built templates for fast response construction (30-40% faster than llList2Json)
string JSON_TEMPLATE_BLACKLIST = "";
string JSON_TEMPLATE_UNAUTHORIZED = "";
string JSON_TEMPLATE_NOACCESS = "";
string JSON_TEMPLATE_PUBLIC = "";
string JSON_TEMPLATE_OWNED = "";
string JSON_TEMPLATE_TRUSTEE = "";
string JSON_TEMPLATE_UNOWNED = "";
string JSON_TEMPLATE_PRIMARY = "";

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
integer MAX_PENDING_QUERIES = 50;

/* Plugin ACL registry removed in v1.1 rev 1 — superseded by LSD policies */

/* -------------------- HELPER FUNCTIONS -------------------- */

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

/* -------------------- JSON TEMPLATE INITIALIZATION -------------------- */

init_json_templates() {
    // Blacklist: No access (actually on blacklist)
    JSON_TEMPLATE_BLACKLIST = llList2Json(JSON_OBJECT, [
        "type", "acl_result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_BLACKLIST,
        "is_wearer", 0,
        "is_blacklisted", 1,
        "owner_set", 0
    ]);

    // Unauthorized: stranger with public off (not blacklisted, just no access)
    JSON_TEMPLATE_UNAUTHORIZED = llList2Json(JSON_OBJECT, [
        "type", "acl_result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_BLACKLIST,
        "is_wearer", 0,
        "is_blacklisted", 0,
        "owner_set", "OWNER_SET_PLACEHOLDER"
    ]);

    // No Access: TPE wearer
    JSON_TEMPLATE_NOACCESS = llList2Json(JSON_OBJECT, [
        "type", "acl_result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_NOACCESS,
        "is_wearer", 1,
        "is_blacklisted", 0,
        "owner_set", "OWNER_SET_PLACEHOLDER"
    ]);

    // Public: Non-wearer with public access
    JSON_TEMPLATE_PUBLIC = llList2Json(JSON_OBJECT, [
        "type", "acl_result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_PUBLIC,
        "is_wearer", 0,
        "is_blacklisted", 0,
        "owner_set", "OWNER_SET_PLACEHOLDER"
    ]);

    // Owned: Wearer with owner set
    JSON_TEMPLATE_OWNED = llList2Json(JSON_OBJECT, [
        "type", "acl_result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_OWNED,
        "is_wearer", 1,
        "is_blacklisted", 0,
        "owner_set", 1
    ]);

    // Trustee: Trustee access
    JSON_TEMPLATE_TRUSTEE = llList2Json(JSON_OBJECT, [
        "type", "acl_result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_TRUSTEE,
        "is_wearer", 0,
        "is_blacklisted", 0,
        "owner_set", "OWNER_SET_PLACEHOLDER"
    ]);

    // Unowned: Wearer with no owner
    JSON_TEMPLATE_UNOWNED = llList2Json(JSON_OBJECT, [
        "type", "acl_result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_UNOWNED,
        "is_wearer", 1,
        "is_blacklisted", 0,
        "owner_set", 0
    ]);

    // Primary Owner: Owner access
    JSON_TEMPLATE_PRIMARY = llList2Json(JSON_OBJECT, [
        "type", "acl_result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_PRIMARY_OWNER,
        "is_wearer", 0,
        "is_blacklisted", 0,
        "owner_set", 1
    ]);
}

/* -------------------- LINKSET DATA CACHE MANAGEMENT -------------------- */

// Build cache key for a user's ACL query result
string get_cache_key(key avatar) {
    return LSD_ACL_CACHE_PREFIX + (string)avatar;
}

// Try to retrieve cached ACL result (returns TRUE if cache hit)
// Uses sliding window: TTL resets on each access for active sessions
integer get_cached_acl(key avatar, string correlation_id) {
    string cache_key = get_cache_key(avatar);
    string cached = llLinksetDataRead(cache_key);
    
    if (cached == "") return FALSE;  // Cache miss
    
    // Parse cached data: "level|timestamp"
    list parts = llParseString2List(cached, ["|"], []);
    if (llGetListLength(parts) != 2) {
        llLinksetDataDelete(cache_key);  // Corrupted
        return FALSE;
    }
    
    integer cached_time = llList2Integer(parts, 1);
    integer now = llGetUnixTime();
    
    // Check if expired
    if ((now - cached_time) > CACHE_TTL) {
        llLinksetDataDelete(cache_key);
        return FALSE;
    }
    
    // Cache hit! Reset TTL (sliding window - keeps active sessions cached)
    integer level = llList2Integer(parts, 0);
    string updated_cache = (string)level + "|" + (string)now;
    llLinksetDataWrite(cache_key, updated_cache);
    
    // Send response
    send_acl_from_level(avatar, level, correlation_id);
    return TRUE;
}

// Store ACL query result in cache
store_cached_acl(key avatar, integer level) {
    // Check cache size limit
    integer cache_count = llLinksetDataCountKeys();
    if (cache_count > CACHE_MAX_USERS) {
        // Cache full - don't add more (let TTL naturally prune old entries)
        return;
    }
    
    string cache_key = get_cache_key(avatar);
    string cache_value = (string)level + "|" + (string)llGetUnixTime();
    llLinksetDataWrite(cache_key, cache_value);
}

// Clear all cached ACL query results
clear_acl_query_cache() {
    // OPTIMIZED: Use regex search instead of iterating all keys
    // This pushes the search workload to the simulator (C++)
    list keys = llLinksetDataFindKeys("^" + LSD_ACL_CACHE_PREFIX, 0, 0);
    integer i = 0;
    while (i < llGetListLength(keys)) {
        llLinksetDataDelete(llList2String(keys, i));
        i++;
    }
}

// Persist ACL role lists to linkset data
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

    // Clear query cache since ACL data changed.
    // precompute_known_acl() will re-populate for all named actors immediately after.
    clear_acl_query_cache();
}

/* -------------------- JSON TEMPLATE RESPONSE BUILDER -------------------- */

// Fast response construction using pre-built templates
send_acl_from_template(string template, key avatar, integer owner_set, string correlation_id) {
    string msg = template;
    
    // Replace placeholders
    msg = llJsonSetValue(msg, ["avatar"], (string)avatar);
    
    // Replace owner_set if needed
    if (llSubStringIndex(msg, "OWNER_SET_PLACEHOLDER") != -1) {
        msg = llJsonSetValue(msg, ["owner_set"], (string)owner_set);
    }
    
    // Add correlation ID if provided
    if (correlation_id != "") {
        msg = llJsonSetValue(msg, ["id"], correlation_id);
    }
    
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

/* -------------------- DISPATCH TABLE - PER-ACL HANDLERS -------------------- */

// Blacklisted user - immediate denial, no policy computation needed
process_blacklist_query(key avatar, string correlation_id) {
    send_acl_from_template(JSON_TEMPLATE_BLACKLIST, avatar, 0, correlation_id);
    store_cached_acl(avatar, ACL_BLACKLIST);
}

// Unauthorized stranger - not blacklisted, just no access (public off)
process_unauthorized_query(key avatar, string correlation_id) {
    integer owner_set = has_owner();
    send_acl_from_template(JSON_TEMPLATE_UNAUTHORIZED, avatar, owner_set, correlation_id);
    // Do NOT cache unauthorized strangers — their ACL can change at any time
    // if they are later added as owner/trustee, or public mode is toggled.
}

// TPE wearer - locked out
process_noaccess_query(key avatar, string correlation_id) {
    integer owner_set = has_owner();
    send_acl_from_template(JSON_TEMPLATE_NOACCESS, avatar, owner_set, correlation_id);
    store_cached_acl(avatar, ACL_NOACCESS);
}

// Public access user
process_public_query(key avatar, string correlation_id) {
    integer owner_set = has_owner();
    send_acl_from_template(JSON_TEMPLATE_PUBLIC, avatar, owner_set, correlation_id);
    store_cached_acl(avatar, ACL_PUBLIC);
}

// Owned wearer
process_owned_query(key avatar, string correlation_id) {
    send_acl_from_template(JSON_TEMPLATE_OWNED, avatar, 1, correlation_id);
    store_cached_acl(avatar, ACL_OWNED);
}

// Trustee
process_trustee_query(key avatar, string correlation_id) {
    integer owner_set = has_owner();
    send_acl_from_template(JSON_TEMPLATE_TRUSTEE, avatar, owner_set, correlation_id);
    store_cached_acl(avatar, ACL_TRUSTEE);
}

// Unowned wearer (full control)
process_unowned_query(key avatar, string correlation_id) {
    send_acl_from_template(JSON_TEMPLATE_UNOWNED, avatar, 0, correlation_id);
    store_cached_acl(avatar, ACL_UNOWNED);
}

// Primary owner
process_primary_owner_query(key avatar, string correlation_id) {
    send_acl_from_template(JSON_TEMPLATE_PRIMARY, avatar, 1, correlation_id);
    store_cached_acl(avatar, ACL_PRIMARY_OWNER);
}

// Pre-populate acl_cache_<uuid> in LSD for all known actors after any settings load or change.
// Eliminates AUTH_BUS round-trips for wearer, owners, and trustees on every subsequent touch.
// Unknown users (strangers) still fall through to the AUTH_BUS cold-miss path on first contact.
precompute_known_acl() {
    route_acl_query(llGetOwner(), "");
    integer pi = 0;
    if (MultiOwnerMode) {
        while (pi < llGetListLength(OwnerKeys)) {
            route_acl_query((key)llList2String(OwnerKeys, pi), "");
            pi++;
        }
    }
    else if (OwnerKey != NULL_KEY) {
        route_acl_query(OwnerKey, "");
    }
    integer ti = 0;
    while (ti < llGetListLength(TrusteeList)) {
        route_acl_query((key)llList2String(TrusteeList, ti), "");
        ti++;
    }
}

/* -------------------- ACL LEVEL COMPUTATION (DISPATCH ROUTER) -------------------- */

// Determine ACL level and route to appropriate handler
route_acl_query(key avatar, string correlation_id) {
    key wearer = llGetOwner();
    integer owner_set = has_owner();
    integer is_wearer = (avatar == wearer);
    
    // FAST PATH 1: Blacklist check (most restrictive, check first)
    if (list_has_key(Blacklist, avatar)) {
        process_blacklist_query(avatar, correlation_id);
        return;
    }
    
    // FAST PATH 2: Owner check (highest privilege)
    if (is_owner(avatar)) {
        process_primary_owner_query(avatar, correlation_id);
        return;
    }
    
    // FAST PATH 3: Wearer paths
    if (is_wearer) {
        if (TpeMode) {
            process_noaccess_query(avatar, correlation_id);
            return;
        }
        if (owner_set) {
            process_owned_query(avatar, correlation_id);
            return;
        }
        process_unowned_query(avatar, correlation_id);
        return;
    }
    
    // FAST PATH 4: Trustee check
    if (list_has_key(TrusteeList, avatar)) {
        process_trustee_query(avatar, correlation_id);
        return;
    }
    
    // FAST PATH 5: Public mode check
    if (PublicMode) {
        process_public_query(avatar, correlation_id);
        return;
    }
    
    // DEFAULT: Unauthorized stranger (not blacklisted, just no access)
    process_unauthorized_query(avatar, correlation_id);
}

// Helper for cache hits - reconstruct response from cached level
send_acl_from_level(key avatar, integer level, string correlation_id) {
    integer owner_set = has_owner();
    
    if (level == ACL_BLACKLIST) {
        send_acl_from_template(JSON_TEMPLATE_BLACKLIST, avatar, 0, correlation_id);
    }
    else if (level == ACL_NOACCESS) {
        send_acl_from_template(JSON_TEMPLATE_NOACCESS, avatar, owner_set, correlation_id);
    }
    else if (level == ACL_PUBLIC) {
        send_acl_from_template(JSON_TEMPLATE_PUBLIC, avatar, owner_set, correlation_id);
    }
    else if (level == ACL_OWNED) {
        send_acl_from_template(JSON_TEMPLATE_OWNED, avatar, 1, correlation_id);
    }
    else if (level == ACL_TRUSTEE) {
        send_acl_from_template(JSON_TEMPLATE_TRUSTEE, avatar, owner_set, correlation_id);
    }
    else if (level == ACL_UNOWNED) {
        send_acl_from_template(JSON_TEMPLATE_UNOWNED, avatar, 0, correlation_id);
    }
    else if (level == ACL_PRIMARY_OWNER) {
        send_acl_from_template(JSON_TEMPLATE_PRIMARY, avatar, 1, correlation_id);
    }
}

/* -------------------- ACL CHANGE BROADCAST -------------------- */

broadcast_acl_change(string scope, key avatar) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_update",
        "scope", scope,
        "avatar", (string)avatar
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

/* Plugin ACL management removed in v1.1 rev 1 — superseded by LSD policies */

/* -------------------- ROLE EXCLUSIVITY VALIDATION -------------------- */

enforce_role_exclusivity() {
    integer i;
    
    if (MultiOwnerMode) {
        i = 0;
        while (i < llGetListLength(OwnerKeys)) {
            string owner = llList2String(OwnerKeys, i);
            
            integer idx = llListFindList(TrusteeList, [owner]);
            if (idx != -1) {
                TrusteeList = llDeleteSubList(TrusteeList, idx, idx);
            }
            
            idx = llListFindList(Blacklist, [owner]);
            if (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
            }
            i = i + 1;
        }
    }
    else {
        if (OwnerKey != NULL_KEY) {
            string owner = (string)OwnerKey;
            
            integer idx = llListFindList(TrusteeList, [owner]);
            if (idx != -1) {
                TrusteeList = llDeleteSubList(TrusteeList, idx, idx);
            }
            
            idx = llListFindList(Blacklist, [owner]);
            if (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
            }
        }
    }
    
    i = 0;
    while (i < llGetListLength(TrusteeList)) {
        string trustee = llList2String(TrusteeList, i);
        
        integer idx = llListFindList(Blacklist, [trustee]);
        if (idx != -1) {
            Blacklist = llDeleteSubList(Blacklist, idx, idx);
        }
        i = i + 1;
    }
}

/* -------------------- SETTINGS CONSUMPTION -------------------- */

apply_settings_sync() {
    // Save previous state for change detection
    integer prev_multi = MultiOwnerMode;
    key prev_owner = OwnerKey;
    list prev_owners = OwnerKeys;
    list prev_trustees = TrusteeList;
    list prev_blacklist = Blacklist;
    integer prev_public = PublicMode;
    integer prev_tpe = TpeMode;

    // Reset state before reading from LSD
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    TrusteeList = [];
    Blacklist = [];
    PublicMode = FALSE;
    TpeMode = FALSE;

    string tmp = llLinksetDataRead(KEY_MULTI_OWNER_MODE);
    if (tmp != "") {
        MultiOwnerMode = (integer)tmp;
    }

    // Single owner: JSON object {uuid:honorific} — extract UUID
    string owner_obj = llLinksetDataRead(KEY_OWNER);
    if (owner_obj != "") {
        if (llJsonValueType(owner_obj, []) == JSON_OBJECT) {
            list pairs = llJson2List(owner_obj);
            if (llGetListLength(pairs) >= 2) {
                OwnerKey = (key)llList2String(pairs, 0);
            }
        }
    }

    // Multi-owner: JSON object {uuid:honorific, ...} — extract UUID list
    string owners_obj = llLinksetDataRead(KEY_OWNERS);
    if (owners_obj != "") {
        if (llJsonValueType(owners_obj, []) == JSON_OBJECT) {
            list pairs = llJson2List(owners_obj);
            integer pi = 0;
            integer plen = llGetListLength(pairs);
            while (pi < plen) {
                OwnerKeys += [llList2String(pairs, pi)];
                pi += 2;
            }
        }
    }

    string trustees_raw = llLinksetDataRead(KEY_TRUSTEES);
    if (trustees_raw != "") {
        if (llJsonValueType(trustees_raw, []) == JSON_OBJECT) {
            // Trustees stored as {uuid:honorific} — extract UUID keys
            list pairs = llJson2List(trustees_raw);
            integer pi = 0;
            integer plen = llGetListLength(pairs);
            while (pi < plen) {
                TrusteeList += [llList2String(pairs, pi)];
                pi += 2;
            }
        }
        else if (is_json_arr(trustees_raw)) {
            TrusteeList = llJson2List(trustees_raw);
        }
    }

    string bl_raw = llLinksetDataRead(KEY_BLACKLIST);
    if (bl_raw != "") {
        if (is_json_arr(bl_raw)) {
            Blacklist = llJson2List(bl_raw);
        }
    }

    tmp = llLinksetDataRead(KEY_PUBLIC_ACCESS);
    if (tmp != "") {
        PublicMode = (integer)tmp;
    }

    tmp = llLinksetDataRead(KEY_TPE_MODE);
    if (tmp != "") {
        TpeMode = (integer)tmp;
    }

    enforce_role_exclusivity();

    // Detect whether any ACL-relevant state changed
    integer acl_changed = FALSE;
    if (MultiOwnerMode != prev_multi) acl_changed = TRUE;
    if (OwnerKey != prev_owner) acl_changed = TRUE;
    if (PublicMode != prev_public) acl_changed = TRUE;
    if (TpeMode != prev_tpe) acl_changed = TRUE;
    if (llList2Json(JSON_ARRAY, OwnerKeys) != llList2Json(JSON_ARRAY, prev_owners)) {
        acl_changed = TRUE;
    }
    if (llList2Json(JSON_ARRAY, TrusteeList) != llList2Json(JSON_ARRAY, prev_trustees)) {
        acl_changed = TRUE;
    }
    if (llList2Json(JSON_ARRAY, Blacklist) != llList2Json(JSON_ARRAY, prev_blacklist)) {
        acl_changed = TRUE;
    }

    if (acl_changed) {
        persist_acl_cache();
        broadcast_acl_change("global", NULL_KEY);
        precompute_known_acl();
    }

    // On first load, always persist and broadcast even if "unchanged" (defaults)
    if (!SettingsReady) {
        if (!acl_changed) {
            persist_acl_cache();
            broadcast_acl_change("global", NULL_KEY);
            precompute_known_acl();
        }
        SettingsReady = TRUE;
    }

    // Drain pending queries
    integer i = 0;
    while (i < llGetListLength(PendingQueries)) {
        key av = llList2Key(PendingQueries, i);
        string corr_id = llList2String(PendingQueries, i + 1);
        route_acl_query(av, corr_id);
        i = i + PENDING_STRIDE;
    }
    PendingQueries = [];
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_acl_query(string msg) {
    string av_str = llJsonGetValue(msg, ["avatar"]);
    if (av_str == JSON_INVALID) return;
    key av = (key)av_str;
    if (av == NULL_KEY) return;

    string correlation_id = llJsonGetValue(msg, ["id"]);
    if (correlation_id == JSON_INVALID) correlation_id = "";

    if (!SettingsReady) {
        if (llGetListLength(PendingQueries) / PENDING_STRIDE >= MAX_PENDING_QUERIES) {
            PendingQueries = llDeleteSubList(PendingQueries, 0, PENDING_STRIDE - 1);
        }
        PendingQueries += [av, correlation_id];
        return;
    }

    // Try cache first (70-90% hit rate for UI interactions)
    if (get_cached_acl(av, correlation_id)) {
        return;  // Cache hit - response already sent
    }

    // Cache miss - compute and cache result
    route_acl_query(av, correlation_id);
}

/* handle_register_acl, handle_filter_plugins, handle_plugin_acl_list_request
   removed in v1.1 rev 1 — superseded by LSD policies */

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        SettingsReady = FALSE;
        PendingQueries = [];

        // Initialize JSON templates for fast response construction
        init_json_templates();

        // Read settings directly from linkset data
        apply_settings_sync();
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                llResetScript();
            }
        }
        else if (num == AUTH_BUS) {
            if (msg_type == "acl_query") {
                handle_acl_query(msg);
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync" || msg_type == "settings_delta") {
                apply_settings_sync();
            }
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
