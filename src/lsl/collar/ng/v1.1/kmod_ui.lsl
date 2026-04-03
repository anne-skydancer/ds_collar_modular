/*--------------------
MODULE: kmod_ui.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Session management, LSD policy filtering, and plugin list orchestration
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 0: Replaced min_acl filtering with LSD policy reads. Root menu
  visibility now determined by llLinksetDataRead("policy:<context>"). Removed
  PluginMinACLs parallel list and plugin_acl_list_request/response flow.
  Each plugin self-declares its policy via llLinksetDataWrite on registration.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- CONSTANTS -------------------- */
string ROOT_CONTEXT = "core_root";
string SOS_CONTEXT = "sos_root";
string SOS_PREFIX = "sos_";  // Prefix for SOS plugin contexts
integer MAX_FUNC_BTNS = 9;
float TOUCH_RANGE_M = 5.0;
float LONG_TOUCH_THRESHOLD = 1.5;

/* Plugin list stride removed in v1.1 — no min_acl in plugin data */

integer MAX_SESSIONS = 5;
integer SESSION_MAX_AGE = 60;  // Seconds before ACL refresh required

/* ACL levels (mirrors auth module) */
integer ACL_BLACKLIST = -1;
integer ACL_NOACCESS = 0;
integer ACL_PUBLIC = 1;
integer ACL_OWNED = 2;
integer ACL_TRUSTEE = 3;
integer ACL_UNOWNED = 4;
integer ACL_PRIMARY_OWNER = 5;

/* Linkset data cache keys */
string LSD_KEY_ACL_OWNERS    = "ACL.OWNERS";
string LSD_KEY_ACL_TRUSTEES  = "ACL.TRUSTEES";
string LSD_KEY_ACL_BLACKLIST = "ACL.BLACKLIST";
string LSD_KEY_ACL_PUBLIC    = "ACL.PUBLIC";
string LSD_KEY_ACL_TPE       = "ACL.TPE";
string LSD_KEY_ACL_TIMESTAMP = "ACL.TIMESTAMP";

/* -------------------- STATE -------------------- */
// Parallel Lists for Plugins
list PluginContexts;
list PluginLabels;

// Parallel Lists for Sessions
list SessionUsers;
list SessionACLs;
list SessionBlacklisted;
list SessionPages;
list SessionTotalPages;
list SessionIDs;
list SessionFilteredStarts;
list SessionFilteredCounts;
list SessionCreatedTimes;
list SessionContexts;

// Filtered Data (Stores indices into Plugin lists)
list FilteredPluginIndices;

// Parallel Lists for Pending ACL
list PendingAclAvatars;
list PendingAclContexts;

// Parallel Lists for Touch Data
list TouchKeys;
list TouchStartTimes;

// Parallel Lists for Plugin States
list PluginStateContexts;
list PluginStateValues;

// Cache
list CachedOwners = [];
list CachedTrustees = [];
list CachedBlacklist = [];
integer CachedPublicMode = FALSE;
integer CachedTpeMode = FALSE;
integer CachedAclTimestamp = 0;

/* -------------------- HELPERS -------------------- */


string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

// MEMORY OPTIMIZATION: Compact field validation helper
integer validate_required_fields(string json_str, list field_names) {
    integer i = 0;
    integer len = llGetListLength(field_names);
    while (i < len) {
        string field = llList2String(field_names, i);
        if (llJsonGetValue(json_str, [field]) == JSON_INVALID) {
            return FALSE;
        }
        i += 1;
    }
    return TRUE;
}

string generate_session_id(key user) {
    return "ui_" + (string)user + "_" + (string)llGetUnixTime();
}

/* -------------------- PLUGIN STATE MANAGEMENT -------------------- */

integer find_plugin_state_idx(string context) {
    return llListFindList(PluginStateContexts, [context]);
}

integer get_plugin_state(string context) {
    integer idx = find_plugin_state_idx(context);
    if (idx == -1) {
        return 0;  // Default state
    }
    return llList2Integer(PluginStateValues, idx);
}

set_plugin_state(string context, integer button_state) {
    integer idx = find_plugin_state_idx(context);

    if (idx != -1) {
        // Update existing state
        PluginStateValues = llListReplaceList(PluginStateValues, [button_state], idx, idx);
    }
    else {
        // Add new state
        PluginStateContexts += [context];
        PluginStateValues += [button_state];
    }
}

/* -------------------- ACL CACHE MANAGEMENT -------------------- */

integer refresh_acl_cache() {
    string timestamp_str = llLinksetDataRead(LSD_KEY_ACL_TIMESTAMP);
    if (timestamp_str == "") {
        return FALSE;
    }
    integer timestamp = (integer)timestamp_str;
    if (timestamp == CachedAclTimestamp) {
        return TRUE;
    }

    string owners_json = llLinksetDataRead(LSD_KEY_ACL_OWNERS);
    if (owners_json == "") {
        owners_json = "[]";
    }
    CachedOwners = llJson2List(owners_json);

    string trustees_json = llLinksetDataRead(LSD_KEY_ACL_TRUSTEES);
    if (trustees_json == "") {
        trustees_json = "[]";
    }
    CachedTrustees = llJson2List(trustees_json);

    string blacklist_json = llLinksetDataRead(LSD_KEY_ACL_BLACKLIST);
    if (blacklist_json == "") {
        blacklist_json = "[]";
    }
    CachedBlacklist = llJson2List(blacklist_json);

    string public_str = llLinksetDataRead(LSD_KEY_ACL_PUBLIC);
    if (public_str == "") {
        public_str = "0";
    }
    CachedPublicMode = (integer)public_str;

    string tpe_str = llLinksetDataRead(LSD_KEY_ACL_TPE);
    if (tpe_str == "") {
        tpe_str = "0";
    }
    CachedTpeMode = (integer)tpe_str;

    CachedAclTimestamp = timestamp;
    return TRUE;
}

list get_cached_acl_result(key av) {
    if (!refresh_acl_cache()) {
        return [];
    }

    integer is_blacklisted = (llListFindList(CachedBlacklist, [(string)av]) != -1);
    if (is_blacklisted) {
        return [ACL_BLACKLIST, TRUE];
    }

    integer owner_set = (llGetListLength(CachedOwners) > 0);
    integer is_owner = (llListFindList(CachedOwners, [(string)av]) != -1);
    integer is_trustee = (llListFindList(CachedTrustees, [(string)av]) != -1);
    integer is_wearer = (av == llGetOwner());

    integer level;
    if (is_owner) {
        level = ACL_PRIMARY_OWNER;
    }
    else if (is_wearer) {
        if (CachedTpeMode) {
            level = ACL_NOACCESS;
        }
        else if (owner_set) {
            level = ACL_OWNED;
        }
        else {
            level = ACL_UNOWNED;
        }
    }
    else if (is_trustee) {
        level = ACL_TRUSTEE;
    }
    else if (CachedPublicMode) {
        level = ACL_PUBLIC;
    }
    else {
        level = ACL_BLACKLIST;
    }

    return [level, FALSE];
}

integer try_cached_session(key user_key, string context_filter) {
    list cached = get_cached_acl_result(user_key);
    if (llGetListLength(cached) == 0) {
        return FALSE;
    }

    integer level = llList2Integer(cached, 0);
    integer is_blacklisted = llList2Integer(cached, 1);

    create_session(user_key, level, is_blacklisted, context_filter);
    send_render_menu(user_key, context_filter);
    return TRUE;
}

integer find_pending_acl_idx(key avatar_key) {
    return llListFindList(PendingAclAvatars, [avatar_key]);
}

/* -------------------- SESSION MANAGEMENT -------------------- */

integer find_session_idx(key user) {
    return llListFindList(SessionUsers, [user]);
}

list get_session_filtered_indices(integer session_idx) {
    integer start = llList2Integer(SessionFilteredStarts, session_idx);
    integer count = llList2Integer(SessionFilteredCounts, session_idx);
    
    if (count > 0) {
        return llList2List(FilteredPluginIndices, start, start + count - 1);
    }
    return [];
}

cleanup_session(key user) {
    integer idx = find_session_idx(user);
    if (idx == -1) return;

    // BUGFIX: Close dialog before cleaning up session
    string session_id = llList2String(SessionIDs, idx);
    string close_msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_close",
        "session_id", session_id
    ]);
    llMessageLinked(LINK_SET, DIALOG_BUS, close_msg, NULL_KEY);

    integer start = llList2Integer(SessionFilteredStarts, idx);
    integer count = llList2Integer(SessionFilteredCounts, idx);

    if (count > 0) {
        FilteredPluginIndices = llDeleteSubList(FilteredPluginIndices, start, start + count - 1);
    }

    // Shift subsequent session start indices
    integer i = idx + 1;
    integer len = llGetListLength(SessionUsers);
    while (i < len) {
        integer old_start = llList2Integer(SessionFilteredStarts, i);
        SessionFilteredStarts = llListReplaceList(SessionFilteredStarts, [old_start - count], i, i);
        i++;
    }

    // Remove session from parallel lists
    SessionUsers = llDeleteSubList(SessionUsers, idx, idx);
    SessionACLs = llDeleteSubList(SessionACLs, idx, idx);
    SessionBlacklisted = llDeleteSubList(SessionBlacklisted, idx, idx);
    SessionPages = llDeleteSubList(SessionPages, idx, idx);
    SessionTotalPages = llDeleteSubList(SessionTotalPages, idx, idx);
    SessionIDs = llDeleteSubList(SessionIDs, idx, idx);
    SessionFilteredStarts = llDeleteSubList(SessionFilteredStarts, idx, idx);
    SessionFilteredCounts = llDeleteSubList(SessionFilteredCounts, idx, idx);
    SessionCreatedTimes = llDeleteSubList(SessionCreatedTimes, idx, idx);
    SessionContexts = llDeleteSubList(SessionContexts, idx, idx);
}

create_session(key user, integer acl, integer is_blacklisted, string context_filter) {
    integer existing_idx = find_session_idx(user);
    if (existing_idx != -1) {
        cleanup_session(user);
    }

    if (llGetListLength(SessionUsers) >= MAX_SESSIONS) {
        key oldest_user = llList2Key(SessionUsers, 0);
        cleanup_session(oldest_user);
    }

    // Build filtered list based on LSD policy and context (SOS vs root)
    list filtered_indices = [];
    integer i = 0;
    integer len = llGetListLength(PluginContexts);

    while (i < len) {
        string context = llList2String(PluginContexts, i);

        integer should_include = FALSE;
        integer is_sos_plugin = (llSubStringIndex(context, SOS_PREFIX) == 0);

        // Check LSD policy for this plugin at the user's ACL level
        string policy = llLinksetDataRead("policy:" + context);
        if (policy != "") {
            string csv = llJsonGetValue(policy, [(string)acl]);
            if (csv != JSON_INVALID) {
                // Policy exists for this ACL level — apply context filter
                if (context_filter == SOS_CONTEXT) {
                    should_include = is_sos_plugin;
                } else {
                    should_include = !is_sos_plugin;
                }
            }
        }

        if (should_include) {
            filtered_indices += [i];
        }

        i++;
    }

    integer filtered_start = llGetListLength(FilteredPluginIndices);
    integer filtered_count = llGetListLength(filtered_indices);
    FilteredPluginIndices += filtered_indices;

    // Track session creation time
    string session_id = generate_session_id(user);
    integer created_time = llGetUnixTime();
    
    SessionUsers += [user];
    SessionACLs += [acl];
    SessionBlacklisted += [is_blacklisted];
    SessionPages += [0];
    SessionTotalPages += [0];
    SessionIDs += [session_id];
    SessionFilteredStarts += [filtered_start];
    SessionFilteredCounts += [filtered_count];
    SessionCreatedTimes += [created_time];
    SessionContexts += [context_filter];
}

/* -------------------- PLUGIN LIST MANAGEMENT -------------------- */

apply_plugin_list(string plugins_json) {
    // Clear parallel lists
    PluginContexts = [];
    PluginLabels = [];

    if (llJsonValueType(plugins_json, []) != JSON_ARRAY) {
        return;
    }

    // Temporary strided list for sorting
    list temp_plugins = [];
    integer SORT_STRIDE = 2;

    integer count = llGetListLength(llJson2List(plugins_json));

    integer i = 0;
    while (i < count) {
        string plugin_obj = llJsonGetValue(plugins_json, [i]);

        if ((llJsonGetValue(plugin_obj, ["context"]) != JSON_INVALID) &&
            (llJsonGetValue(plugin_obj, ["label"]) != JSON_INVALID)) {

            string context = llJsonGetValue(plugin_obj, ["context"]);
            string label = llJsonGetValue(plugin_obj, ["label"]);

            temp_plugins += [context, label];
        }

        i += 1;
    }

    // Sort once to avoid per-session sorting overhead
    if (llGetListLength(temp_plugins) > SORT_STRIDE) {
        temp_plugins = llListSortStrided(temp_plugins, SORT_STRIDE, 1, TRUE);
    }

    // Split into parallel lists
    i = 0;
    integer len = llGetListLength(temp_plugins);
    while (i < len) {
        PluginContexts += [llList2String(temp_plugins, i)];
        PluginLabels += [llList2String(temp_plugins, i + 1)];
        i += SORT_STRIDE;
    }
    // No ACL list request needed — policies are in LSD, written by plugins
}

// apply_plugin_acl_list removed in v1.1 — ACL filtering via LSD policies

/* -------------------- MENU RENDERING (delegated to kmod_menu.lsl) -------------------- */

send_message(key user, string message_text) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "show_message",
        "user", (string)user,
        "message", message_text
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

send_render_menu(key user, string menu_type) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
        return;
    }

    list filtered_indices = get_session_filtered_indices(session_idx);
    integer plugin_count = llGetListLength(filtered_indices);

    if (plugin_count == 0) {
        integer user_acl = llList2Integer(SessionACLs, session_idx);
        integer is_blacklisted = llList2Integer(SessionBlacklisted, session_idx);

        if (menu_type == SOS_CONTEXT) {
            send_message(user, "No emergency options are currently available.");
        }
        else {
            if (user_acl == -1) {
                if (is_blacklisted) {
                    send_message(user, "You have been barred from using this collar.");
                }
                else {
                    send_message(user, "This collar is not available for public use.");
                }
            }
            else if (user_acl == 0) {
                send_message(user, "You have relinquished control of the collar.");
            }
            else {
                send_message(user, "No plugins are currently installed.");
            }
        }

        cleanup_session(user);
        return;
    }

    integer current_page = llList2Integer(SessionPages, session_idx);

    integer total_pages = (plugin_count + MAX_FUNC_BTNS - 1) / MAX_FUNC_BTNS;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;

    // Update session state
    SessionPages = llListReplaceList(SessionPages, [current_page], session_idx, session_idx);
    SessionTotalPages = llListReplaceList(SessionTotalPages, [total_pages], session_idx, session_idx);

    // Build button data with context and state
    list button_data = [];
    integer start_idx = current_page * MAX_FUNC_BTNS;
    integer end_idx = start_idx + MAX_FUNC_BTNS;
    if (end_idx > plugin_count) {
        end_idx = plugin_count;
    }

    integer i = start_idx;
    while (i < end_idx) {
        integer plugin_idx = llList2Integer(filtered_indices, i);
        
        string context = llList2String(PluginContexts, plugin_idx);
        string label = llList2String(PluginLabels, plugin_idx);
        integer button_state = get_plugin_state(context);

        // Create button data object with context, label, and state
        string btn_obj = llList2Json(JSON_OBJECT, [
            "context", context,
            "label", label,
            "state", button_state
        ]);
        button_data += [btn_obj];
        i++;
    }

    string buttons_json = llList2Json(JSON_ARRAY, button_data);
    string session_id = llList2String(SessionIDs, session_idx);

    // DESIGN DECISION: Navigation row is ALWAYS present (DO NOT CHANGE)
    integer has_nav = 1;

    string msg = llList2Json(JSON_OBJECT, [
        "type", "render_menu",
        "user", (string)user,
        "session_id", session_id,
        "menu_type", menu_type,
        "page", current_page,
        "total_pages", total_pages,
        "buttons", buttons_json,
        "has_nav", has_nav
    ]);

    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(key user, string button, string context) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
        return;
    }

    // Blacklist gate
    integer is_blacklisted = llList2Integer(SessionBlacklisted, session_idx);
    if (is_blacklisted) {
        send_message(user, "You have been barred from using this collar.");
        cleanup_session(user);
        return;
    }

    integer current_page = llList2Integer(SessionPages, session_idx);
    integer total_pages = llList2Integer(SessionTotalPages, session_idx);
    string session_context = llList2String(SessionContexts, session_idx);

    // Handle navigation buttons (no context)
    if (button == "<<") {
        current_page -= 1;
        if (current_page < 0) current_page = total_pages - 1;
        SessionPages = llListReplaceList(SessionPages, [current_page], session_idx, session_idx);
        send_render_menu(user, session_context);
        return;
    }

    if (button == "Close") {
        cleanup_session(user);
        return;
    }

    if (button == ">>") {
        current_page += 1;
        if (current_page >= total_pages) current_page = 0;
        SessionPages = llListReplaceList(SessionPages, [current_page], session_idx, session_idx);
        send_render_menu(user, session_context);
        return;
    }

    // Plugin button clicked - use context directly for fast lookup
    if (context != "") {
        // Find plugin by context
        integer i = llListFindList(PluginContexts, [context]);
        if (i != -1) {
            integer user_acl = llList2Integer(SessionACLs, session_idx);

            // LSD policy filter — verify user still has access
            string policy = llLinksetDataRead("policy:" + context);
            if (policy == "") {
                send_message(user, "Access denied.");
                return;
            }
            string csv = llJsonGetValue(policy, [(string)user_acl]);
            if (csv == JSON_INVALID) {
                send_message(user, "Access denied.");
                return;
            }

            string msg = llList2Json(JSON_OBJECT, [
                "type", "start",
                "context", context,
                "user", (string)user,
                "acl", user_acl
            ]);

            llMessageLinked(LINK_SET, UI_BUS, msg, user);
            return;
        }
        return;
    }
}

/* -------------------- PLUGIN LABEL UPDATE -------------------- */

update_plugin_label(string context, string new_label) {
    integer i = llListFindList(PluginContexts, [context]);
    
    if (i != -1) {
        PluginLabels = llListReplaceList(PluginLabels, [new_label], i, i);
        return;
    }
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_plugin_list(string msg) {
    if (llJsonGetValue(msg, ["plugins"]) == JSON_INVALID) {
        return;
    }

    string plugins_json = llJsonGetValue(msg, ["plugins"]);
    apply_plugin_list(plugins_json);

    // Invalidate all sessions when plugin list changes
    if (llGetListLength(SessionUsers) > 0) {
        // Close all dialogs before clearing sessions
        integer i = 0;
        integer len = llGetListLength(SessionIDs);
        while (i < len) {
            string session_id = llList2String(SessionIDs, i);
            string close_msg = llList2Json(JSON_OBJECT, [
                "type", "dialog_close",
                "session_id", session_id
            ]);
            llMessageLinked(LINK_SET, DIALOG_BUS, close_msg, NULL_KEY);
            i++;
        }

        SessionUsers = [];
        SessionACLs = [];
        SessionBlacklisted = [];
        SessionPages = [];
        SessionTotalPages = [];
        SessionIDs = [];
        SessionFilteredStarts = [];
        SessionFilteredCounts = [];
        SessionCreatedTimes = [];
        SessionContexts = [];
        
        FilteredPluginIndices = [];
        PendingAclAvatars = [];
        PendingAclContexts = [];
    }
}

handle_acl_cache_update(string msg) {
    string new_timestamp_str = llJsonGetValue(msg, ["timestamp"]);
    if (new_timestamp_str == JSON_INVALID) return;
    integer new_timestamp = (integer)new_timestamp_str;
    if (new_timestamp <= CachedAclTimestamp) {
        return;
    }

    CachedAclTimestamp = 0;
    refresh_acl_cache();
}

handle_acl_result(string msg) {
    if (!validate_required_fields(msg, ["avatar", "level", "is_blacklisted"])) return;

    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    integer is_blacklisted = (integer)llJsonGetValue(msg, ["is_blacklisted"]);

    integer idx = find_pending_acl_idx(avatar);
    if (idx == -1) return;

    string requested_context = llList2String(PendingAclContexts, idx);
    
    PendingAclAvatars = llDeleteSubList(PendingAclAvatars, idx, idx);
    PendingAclContexts = llDeleteSubList(PendingAclContexts, idx, idx);

    create_session(avatar, level, is_blacklisted, requested_context);
    send_render_menu(avatar, requested_context);
}

handle_start(string msg, key user_key) {
    if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) {
        start_root_session(user_key);
        return;
    }

    string context = llJsonGetValue(msg, ["context"]);

    if (context == ROOT_CONTEXT) {
        start_root_session(user_key);
        return;
    }

    if (context == SOS_CONTEXT) {
        start_sos_session(user_key);
        return;
    }
}

start_root_session(key user_key) {
    integer idx = find_pending_acl_idx(user_key);
    if (idx != -1) return;

    if (try_cached_session(user_key, ROOT_CONTEXT)) {
        return;
    }

    PendingAclAvatars += [user_key];
    PendingAclContexts += [ROOT_CONTEXT];

    string acl_query = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, acl_query, NULL_KEY);
}

start_sos_session(key user_key) {
    integer idx = find_pending_acl_idx(user_key);
    if (idx != -1) return;

    if (try_cached_session(user_key, SOS_CONTEXT)) {
        return;
    }

    PendingAclAvatars += [user_key];
    PendingAclContexts += [SOS_CONTEXT];

    string acl_query = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, acl_query, NULL_KEY);
}

handle_return(string msg) {
    string user_key_str = llJsonGetValue(msg, ["user"]);
    if (user_key_str == JSON_INVALID) return;
    key user_key = (key)user_key_str;

    // Re-validate stale sessions
    integer session_idx = find_session_idx(user_key);
    if (session_idx != -1) {
        integer created_time = llList2Integer(SessionCreatedTimes, session_idx);
        integer age = llGetUnixTime() - created_time;

        if (age > SESSION_MAX_AGE) {
            string session_context = llList2String(SessionContexts, session_idx);
            cleanup_session(user_key);

            if (session_context == SOS_CONTEXT) {
                start_sos_session(user_key);
            }
            else {
                start_root_session(user_key);
            }
        }
        else {
            string session_context = llList2String(SessionContexts, session_idx);
            send_render_menu(user_key, session_context);
        }
    }
    else {
        start_root_session(user_key);
    }
}

handle_update_label(string msg) {
    if (!validate_required_fields(msg, ["context", "label"])) return;

    string context = llJsonGetValue(msg, ["context"]);
    string new_label = llJsonGetValue(msg, ["label"]);

    update_plugin_label(context, new_label);
}

handle_update_state(string msg) {
    if (!validate_required_fields(msg, ["context", "state"])) return;

    string context = llJsonGetValue(msg, ["context"]);
    integer plugin_state = (integer)llJsonGetValue(msg, ["state"]);

    set_plugin_state(context, plugin_state);
}

// handle_plugin_acl_bus removed in v1.1 — ACL filtering via LSD policies

handle_dialog_response(string msg) {
    if (!validate_required_fields(msg, ["session_id", "button", "user"])) return;

    string session_id = llJsonGetValue(msg, ["session_id"]);
    string button = llJsonGetValue(msg, ["button"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    // Extract context (may be empty string for navigation buttons)
    string context = "";
    string tmp = llJsonGetValue(msg, ["context"]);
    if (tmp != JSON_INVALID) {
        context = tmp;
    }

    integer idx = llListFindList(SessionIDs, [session_id]);
    if (idx != -1) {
        handle_button_click(user, button, context);
        return;
    }
}

handle_dialog_timeout(string msg) {
    if (!validate_required_fields(msg, ["session_id", "user"])) return;

    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    integer idx = llListFindList(SessionIDs, [session_id]);
    if (idx != -1) {
        cleanup_session(user);
    }
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        PluginContexts = [];
        PluginLabels = [];
        
        SessionUsers = [];
        SessionACLs = [];
        SessionBlacklisted = [];
        SessionPages = [];
        SessionTotalPages = [];
        SessionIDs = [];
        SessionFilteredStarts = [];
        SessionFilteredCounts = [];
        SessionCreatedTimes = [];
        SessionContexts = [];
        
        FilteredPluginIndices = [];
        
        PendingAclAvatars = [];
        PendingAclContexts = [];
        
        TouchKeys = [];
        TouchStartTimes = [];
        
        PluginStateContexts = [];
        PluginStateValues = [];
        
        CachedOwners = [];
        CachedTrustees = [];
        CachedBlacklist = [];
        CachedPublicMode = FALSE;
        CachedTpeMode = FALSE;
        CachedAclTimestamp = 0;
        refresh_acl_cache();

        // Request plugin list (kernel defers response during active registration)
        string request = llList2Json(JSON_OBJECT, [
            "type", "plugin_list_request"
        ]);
        llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, request, NULL_KEY);
    }
    
    touch_start(integer num_detected) {
        integer i = 0;
        while (i < num_detected) {
            key toucher = llDetectedKey(i);
            vector touch_pos = llDetectedTouchPos(i);

            // Skip invalid touches
            if (touch_pos == ZERO_VECTOR) {
                i += 1;
                jump next_touch;
            }

            // Validate touch distance
            float distance = llVecDist(touch_pos, llGetPos());
            if (distance > TOUCH_RANGE_M) {
                i += 1;
                jump next_touch;
            }

            // Record touch start time
            integer idx = llListFindList(TouchKeys, [toucher]);
            if (idx != -1) {
                TouchStartTimes = llListReplaceList(TouchStartTimes, [llGetTime()], idx, idx);
            } else {
                TouchKeys += [toucher];
                TouchStartTimes += [llGetTime()];
            }

            @next_touch;
            i += 1;
        }
    }

    touch_end(integer num_detected) {
        key wearer = llGetOwner();
        integer i = 0;

        while (i < num_detected) {
            key toucher = llDetectedKey(i);

            integer idx = llListFindList(TouchKeys, [toucher]);
            if (idx != -1) {
                float start_time = llList2Float(TouchStartTimes, idx);
                float duration = llGetTime() - start_time;

                TouchKeys = llDeleteSubList(TouchKeys, idx, idx);
                TouchStartTimes = llDeleteSubList(TouchStartTimes, idx, idx);

                if (duration >= LONG_TOUCH_THRESHOLD && toucher == wearer) {
                    start_sos_session(toucher);
                }
                else {
                    // Provide feedback if non-wearer attempted long-touch (SOS is wearer-only)
                    if (duration >= LONG_TOUCH_THRESHOLD && toucher != wearer) {
                        send_message(toucher, "Long-touch SOS is only available to the wearer.");
                    }
                    start_root_session(toucher);
                }
            }

            i += 1;
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "plugin_list") handle_plugin_list(msg);
            else if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                llResetScript();
            }
            return;
        }

        /* -------------------- AUTH BUS -------------------- */
        if (num == AUTH_BUS) {
            if (msg_type == "acl_result") handle_acl_result(msg);
            else if (msg_type == "acl_cache_updated") handle_acl_cache_update(msg);
            return;
        }

        /* -------------------- UI BUS -------------------- */
        if (num == UI_BUS) {
            if (msg_type == "start") handle_start(msg, id);
            else if (msg_type == "return") handle_return(msg);
            else if (msg_type == "update_label") handle_update_label(msg);
            else if (msg_type == "update_state") handle_update_state(msg);
            return;
        }

        /* -------------------- DIALOG BUS -------------------- */
        if (num == DIALOG_BUS) {
            if (msg_type == "dialog_response") handle_dialog_response(msg);
            else if (msg_type == "dialog_timeout") handle_dialog_timeout(msg);
            return;
        }
    }
    
    // Reset on owner change
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
