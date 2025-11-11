/*--------------------
MODULE: ds_collar_kmod_ui.lsl
VERSION: 1.00
REVISION: 41
PURPOSE: Session management, ACL filtering, and plugin list orchestration
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Split UI logic from menu rendering to delegate visuals to ds_collar_menu.lsl
- Added UUID-based plugin change detection to avoid registration races
- Enforced touch range validation and blacklist checks during session start
- Revalidated ACL levels on session return with time-based expiry
- Guarded debug logging for production and handled owner change resets
- PERFORMANCE: Pre-sort AllPlugins at registration, eliminate sort from hot path
--------------------*/

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

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

/* Plugin list stride */
integer PLUGIN_STRIDE = 3;
integer PLUGIN_CONTEXT = 0;
integer PLUGIN_LABEL = 1;
integer PLUGIN_MIN_ACL = 2;

/* Session list stride - SECURITY FIX: Added SESSION_CREATED_TIME */
integer SESSION_STRIDE = 9;
integer SESSION_USER = 0;
integer SESSION_ACL = 1;
integer SESSION_IS_BLACKLISTED = 2;
integer SESSION_PAGE = 3;
integer SESSION_TOTAL_PAGES = 4;
integer SESSION_ID = 5;
integer SESSION_FILTERED_START = 6;
integer SESSION_CREATED_TIME = 7;  // SECURITY FIX: Timestamp for ACL refresh
integer SESSION_CONTEXT = 8;  // Context filter for this session (root or sos)

/* Plugin state list stride: [context, state] */
integer PLUGIN_STATE_STRIDE = 2;
integer PLUGIN_STATE_CONTEXT = 0;
integer PLUGIN_STATE_VALUE = 1;

integer MAX_SESSIONS = 5;
integer SESSION_MAX_AGE = 60;  // Seconds before ACL refresh required

/* Touch tracking stride */
integer TOUCH_DATA_STRIDE = 2;
integer TOUCH_DATA_KEY = 0;
integer TOUCH_DATA_START_TIME = 1;

/* Pending ACL stride - tracks avatar and requested context */
integer PENDING_ACL_STRIDE = 2;
integer PENDING_ACL_AVATAR = 0;
integer PENDING_ACL_CONTEXT = 1;

/* -------------------- STATE -------------------- */
list AllPlugins = [];
list Sessions = [];
list FilteredPluginsData = [];
list PendingAcl = [];
list TouchData = [];
list PluginStates = [];  // Stores toggle button states [context, state]

/* -------------------- HELPERS -------------------- */
integer logd(string msg) {
    // SECURITY FIX: Production mode guard
    if (DEBUG && !PRODUCTION) llOwnerSay("[UI] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
string get_msg_type(string msg) {
    if (!json_has(msg, ["type"])) return "";
    return llJsonGetValue(msg, ["type"]);
}


// MEMORY OPTIMIZATION: Compact field validation helper
integer validate_required_fields(string json_str, list field_names, string function_name) {
    integer i = 0;
    integer len = llGetListLength(field_names);
    while (i < len) {
        string field = llList2String(field_names, i);
        if (!json_has(json_str, [field])) {
            if (DEBUG && !PRODUCTION) {
                logd("ERROR: " + function_name + " missing '" + field + "' field");
            }
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
    integer i = 0;
    integer len = llGetListLength(PluginStates);
    while (i < len) {
        if (llList2String(PluginStates, i + PLUGIN_STATE_CONTEXT) == context) {
            return i;
        }
        i += PLUGIN_STATE_STRIDE;
    }
    return -1;
}

integer get_plugin_state(string context) {
    integer idx = find_plugin_state_idx(context);
    if (idx == -1) {
        return 0;  // Default state
    }
    return llList2Integer(PluginStates, idx + PLUGIN_STATE_VALUE);
}

set_plugin_state(string context, integer button_state) {
    integer idx = find_plugin_state_idx(context);

    if (idx != -1) {
        // Update existing state
        PluginStates = llListReplaceList(PluginStates, [button_state], idx + PLUGIN_STATE_VALUE, idx + PLUGIN_STATE_VALUE);
        logd("Updated state for " + context + ": " + (string)button_state);
    }
    else {
        // Add new state
        PluginStates += [context, button_state];
        logd("Registered state for " + context + ": " + (string)button_state);
    }
}

/* -------------------- SESSION MANAGEMENT -------------------- */

integer find_session_idx(key user) {
    integer i = 0;
    integer len = llGetListLength(Sessions);
    while (i < len) {
        if (llList2Key(Sessions, i + SESSION_USER) == user) {
            return i;
        }
        i += SESSION_STRIDE;
    }
    return -1;
}

integer get_session_filtered_start(integer session_idx) {
    return llList2Integer(Sessions, session_idx + SESSION_FILTERED_START);
}

integer get_session_filtered_count(integer session_idx) {
    integer start = get_session_filtered_start(session_idx);
    integer next_session_idx = session_idx + SESSION_STRIDE;
    
    integer end;
    if (next_session_idx < llGetListLength(Sessions)) {
        end = llList2Integer(Sessions, next_session_idx + SESSION_FILTERED_START);
    }
    else {
        end = llGetListLength(FilteredPluginsData);
    }
    
    return (end - start) / PLUGIN_STRIDE;
}

list get_session_filtered_plugins(integer session_idx) {
    integer start = get_session_filtered_start(session_idx);
    integer count = get_session_filtered_count(session_idx);
    integer end = start + (count * PLUGIN_STRIDE);
    
    if (end > start) {
        return llList2List(FilteredPluginsData, start, end - 1);
    }
    return [];
}

cleanup_session(key user) {
    integer idx = find_session_idx(user);
    if (idx == -1) return;

    // BUGFIX: Close dialog before cleaning up session
    string session_id = llList2String(Sessions, idx + SESSION_ID);
    string close_msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_close",
        "session_id", session_id
    ]);
    llMessageLinked(LINK_SET, DIALOG_BUS, close_msg, NULL_KEY);

    integer start = get_session_filtered_start(idx);
    integer count = get_session_filtered_count(idx);
    integer end = start + (count * PLUGIN_STRIDE);

    if (count > 0) {
        FilteredPluginsData = llDeleteSubList(FilteredPluginsData, start, end - 1);
    }

    integer shift_amount = count * PLUGIN_STRIDE;
    integer i = idx + SESSION_STRIDE;
    while (i < llGetListLength(Sessions)) {
        integer old_start = llList2Integer(Sessions, i + SESSION_FILTERED_START);
        Sessions = llListReplaceList(Sessions, [old_start - shift_amount], i + SESSION_FILTERED_START, i + SESSION_FILTERED_START);
        i += SESSION_STRIDE;
    }

    Sessions = llDeleteSubList(Sessions, idx, idx + SESSION_STRIDE - 1);

    logd("Session cleaned up for " + llKey2Name(user));
}

create_session(key user, integer acl, integer is_blacklisted, string context_filter) {
    integer existing_idx = find_session_idx(user);
    if (existing_idx != -1) {
        logd("Session already exists for " + llKey2Name(user) + ", updating");
        cleanup_session(user);
    }

    if (llGetListLength(Sessions) / SESSION_STRIDE >= MAX_SESSIONS) {
        key oldest_user = llList2Key(Sessions, 0 + SESSION_USER);
        logd("Session limit reached, removing oldest: " + llKey2Name(oldest_user));
        cleanup_session(oldest_user);
    }

    // Build filtered list based on ACL and context (SOS vs root)
    list filtered = [];
    integer i = 0;
    integer len = llGetListLength(AllPlugins);

    while (i < len) {
        string context = llList2String(AllPlugins, i + PLUGIN_CONTEXT);
        string label = llList2String(AllPlugins, i + PLUGIN_LABEL);
        integer min_acl = llList2Integer(AllPlugins, i + PLUGIN_MIN_ACL);

        integer should_include = FALSE;
        integer is_sos_plugin = (llSubStringIndex(context, SOS_PREFIX) == 0);

        // First check ACL
        if (acl >= min_acl) {
            if (context_filter == SOS_CONTEXT) {
                // SOS context: only include plugins with sos_ prefix
                should_include = is_sos_plugin;
            } else {
                // Root context: include all non-SOS plugins (no sos_ prefix)
                should_include = !is_sos_plugin;
            }
        }

        if (should_include) {
            filtered += [context, label, min_acl];
        }

        i += PLUGIN_STRIDE;
    }

    // Filtered list is already alphabetical (AllPlugins is pre-sorted)
    // No sorting needed here - filtering preserves order

    integer filtered_start = llGetListLength(FilteredPluginsData);
    FilteredPluginsData += filtered;

    // SECURITY FIX: Add timestamp to session
    string session_id = generate_session_id(user);
    integer created_time = llGetUnixTime();
    Sessions += [user, acl, is_blacklisted, 0, 0, session_id, filtered_start, created_time, context_filter];

    // MEMORY OPTIMIZATION: Only build debug string if actually debugging
    if (DEBUG && !PRODUCTION) {
        integer plugin_count = llGetListLength(filtered) / PLUGIN_STRIDE;
        logd("Created " + context_filter + " session for " + llKey2Name(user) + " (ACL=" + (string)acl + ", blacklisted=" + (string)is_blacklisted + ", " +
             (string)plugin_count + " plugins)");
    }
}

/* -------------------- PLUGIN LIST MANAGEMENT -------------------- */

apply_plugin_list(string plugins_json) {
    AllPlugins = [];
    
    logd("apply_plugin_list called with: " + plugins_json);

    if (llJsonValueType(plugins_json, []) != JSON_ARRAY) {
        logd("ERROR: Not a JSON array!");
        return;
    }
    
    integer count = 0;
    while (llJsonValueType(plugins_json, [count]) != JSON_INVALID) {
        count += 1;
    }
    
    logd("Array length: " + (string)count);
    
    integer i = 0;
    while (i < count) {
        string plugin_obj = llJsonGetValue(plugins_json, [i]);

        if (json_has(plugin_obj, ["context"]) &&
            json_has(plugin_obj, ["label"])) {

            string context = llJsonGetValue(plugin_obj, ["context"]);
            string label = llJsonGetValue(plugin_obj, ["label"]);

            // Add with default min_acl=0 (will be updated when ACL list arrives)
            // RACE MITIGATION: Sessions are invalidated when plugin_list updates,
            // so no active sessions exist during this window. New sessions only
            // created after ACL query completes (handle_acl_result), ensuring
            // ACL data is always present before access decisions are made.
            AllPlugins += [context, label, 0];
        }

        i += 1;
    }

    logd("Plugin list updated: " + (string)(llGetListLength(AllPlugins) / PLUGIN_STRIDE) + " plugins");

    // PERFORMANCE: Pre-sort plugin list alphabetically by label
    // Eliminates need to sort on every session creation (10-20ms saved per touch)
    integer plugin_count = llGetListLength(AllPlugins) / PLUGIN_STRIDE;
    if (plugin_count > 1) {
        AllPlugins = llListSortStrided(AllPlugins, PLUGIN_STRIDE, PLUGIN_LABEL, TRUE);
        logd("Pre-sorted " + (string)plugin_count + " plugins alphabetically");
    }

    // Request ACL data from auth module
    string request = llList2Json(JSON_OBJECT, ["type", "plugin_acl_list_request"]);
    llMessageLinked(LINK_SET, AUTH_BUS, request, NULL_KEY);
}

apply_plugin_acl_list(string acl_json) {
    logd("apply_plugin_acl_list called");

    if (llJsonValueType(acl_json, []) != JSON_ARRAY) {
        logd("ERROR: Not a JSON array!");
        return;
    }

    integer count = 0;
    while (llJsonValueType(acl_json, [count]) != JSON_INVALID) {
        count += 1;
    }

    logd("ACL array length: " + (string)count);

    integer i = 0;
    while (i < count) {
        string acl_obj = llJsonGetValue(acl_json, [i]);

        if (json_has(acl_obj, ["context"]) && json_has(acl_obj, ["min_acl"])) {
            string context = llJsonGetValue(acl_obj, ["context"]);
            integer min_acl = (integer)llJsonGetValue(acl_obj, ["min_acl"]);

            // Find this context in AllPlugins and update min_acl
            // OPTIMIZATION: Jump to next_acl after match (acts as break)
            // Each context appears at most once, so no need to continue searching
            integer j = 0;
            integer len = llGetListLength(AllPlugins);
            while (j < len) {
                if (llList2String(AllPlugins, j + PLUGIN_CONTEXT) == context) {
                    AllPlugins = llListReplaceList(AllPlugins, [min_acl], j + PLUGIN_MIN_ACL, j + PLUGIN_MIN_ACL);
                    jump next_acl;  // Break after match (each context is unique)
                }
                j += PLUGIN_STRIDE;
            }

            @next_acl;
        }

        i += 1;
    }

    logd("Plugin ACL data updated");
}

/* -------------------- MENU RENDERING (delegated to ds_collar_menu.lsl) -------------------- */

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
        logd("ERROR: No session for " + llKey2Name(user));
        return;
    }

    list filtered = get_session_filtered_plugins(session_idx);
    integer plugin_count = llGetListLength(filtered) / PLUGIN_STRIDE;

    if (plugin_count == 0) {
        integer user_acl = llList2Integer(Sessions, session_idx + SESSION_ACL);
        integer is_blacklisted = llList2Integer(Sessions, session_idx + SESSION_IS_BLACKLISTED);

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

    integer current_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);

    integer total_pages = (plugin_count + MAX_FUNC_BTNS - 1) / MAX_FUNC_BTNS;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;

    // Batch update for performance (SESSION_PAGE=3, SESSION_TOTAL_PAGES=4 are consecutive)
    Sessions = llListReplaceList(Sessions, [current_page, total_pages], session_idx + SESSION_PAGE, session_idx + SESSION_TOTAL_PAGES);

    // Build button data with context and state
    list button_data = [];
    integer start_idx = current_page * MAX_FUNC_BTNS * PLUGIN_STRIDE;
    integer end_idx = start_idx + (MAX_FUNC_BTNS * PLUGIN_STRIDE);
    if (end_idx > llGetListLength(filtered)) {
        end_idx = llGetListLength(filtered);
    }

    integer i = start_idx;
    while (i < end_idx) {
        string context = llList2String(filtered, i + PLUGIN_CONTEXT);
        string label = llList2String(filtered, i + PLUGIN_LABEL);
        integer button_state = get_plugin_state(context);

        // Create button data object with context, label, and state
        string btn_obj = llList2Json(JSON_OBJECT, [
            "context", context,
            "label", label,
            "state", button_state
        ]);
        button_data += [btn_obj];
        i += PLUGIN_STRIDE;
    }

    string buttons_json = llList2Json(JSON_ARRAY, button_data);
    string session_id = llList2String(Sessions, session_idx + SESSION_ID);

    // DESIGN DECISION: Navigation row is ALWAYS present (DO NOT CHANGE)
    // Rationale: Provides consistent UI layout and muscle memory for users
    // regardless of plugin count. Single-page menus still show <<, >>, Close
    // for UI consistency. This is intentional and not open to modification.
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

    // MEMORY OPTIMIZATION: Only build debug string if actually debugging
    if (DEBUG && !PRODUCTION) {
        logd("Sent render request for " + menu_type + " menu to " + llKey2Name(user) + " (page " +
             (string)(current_page + 1) + "/" + (string)total_pages + ", " +
             (string)llGetListLength(button_data) + " buttons)");
    }
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(key user, string button, string context) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
        logd("ERROR: No session for button click from " + llKey2Name(user));
        return;
    }

    // SECURITY FIX: Check blacklist status
    integer is_blacklisted = llList2Integer(Sessions, session_idx + SESSION_IS_BLACKLISTED);
    if (is_blacklisted) {
        send_message(user, "You have been barred from using this collar.");
        cleanup_session(user);
        return;
    }

    integer current_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);
    integer total_pages = llList2Integer(Sessions, session_idx + SESSION_TOTAL_PAGES);
    string session_context = llList2String(Sessions, session_idx + SESSION_CONTEXT);

    // Handle navigation buttons (no context)
    if (button == "<<") {
        current_page -= 1;
        if (current_page < 0) current_page = total_pages - 1;
        Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
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
        Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
        send_render_menu(user, session_context);
        return;
    }

    // Plugin button clicked - use context directly for fast lookup
    if (context != "") {
        // Find plugin by context
        integer i = 0;
        integer len = llGetListLength(AllPlugins);
        while (i < len) {
            if (llList2String(AllPlugins, i + PLUGIN_CONTEXT) == context) {
                integer min_acl = llList2Integer(AllPlugins, i + PLUGIN_MIN_ACL);
                integer user_acl = llList2Integer(Sessions, session_idx + SESSION_ACL);

                // ACL check - CRITICAL for collar security
                if (user_acl < min_acl) {
                    send_message(user, "Access denied.");
                    return;
                }

                string msg = llList2Json(JSON_OBJECT, [
                    "type", "start",
                    "context", context,
                    "user", (string)user
                ]);

                llMessageLinked(LINK_SET, UI_BUS, msg, user);
                logd("Starting plugin: " + context + " for " + llKey2Name(user));
                return;
            }
            i += PLUGIN_STRIDE;
        }

        logd("WARNING: No plugin found for context: " + context);
        return;
    }

    logd("WARNING: Button click with no context: " + button);
}

/* -------------------- PLUGIN LABEL UPDATE -------------------- */

update_plugin_label(string context, string new_label) {
    integer i = 0;
    integer len = llGetListLength(AllPlugins);
    
    while (i < len) {
        string all_context = llList2String(AllPlugins, i + PLUGIN_CONTEXT);
        if (all_context == context) {
            AllPlugins = llListReplaceList(AllPlugins, [new_label], i + PLUGIN_LABEL, i + PLUGIN_LABEL);
            logd("Updated label for " + context + " to: " + new_label);
            
            integer j = 0;
            while (j < llGetListLength(FilteredPluginsData)) {
                string filtered_context = llList2String(FilteredPluginsData, j + PLUGIN_CONTEXT);
                if (filtered_context == context) {
                    FilteredPluginsData = llListReplaceList(FilteredPluginsData, [new_label], j + PLUGIN_LABEL, j + PLUGIN_LABEL);
                }
                j += PLUGIN_STRIDE;
            }
            return;
        }
        
        i += PLUGIN_STRIDE;
    }
    
    logd("WARNING: Plugin " + context + " not found for label update");
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_plugin_list(string msg) {
    logd("handle_plugin_list called");

    if (!json_has(msg, ["plugins"])) {
        logd("ERROR: No 'plugins' field in message!");
        return;
    }

    string plugins_json = llJsonGetValue(msg, ["plugins"]);
    apply_plugin_list(plugins_json);

    // Invalidate all sessions when plugin list changes
    // Kernel only broadcasts when UUID changes detected, so this is always meaningful
    if (llGetListLength(Sessions) > 0) {
        integer session_count = llGetListLength(Sessions) / SESSION_STRIDE;
        logd("Plugin list updated - invalidating " + (string)session_count + " sessions");

        // BUGFIX: Close all dialogs before clearing sessions
        integer i = 0;
        while (i < llGetListLength(Sessions)) {
            string session_id = llList2String(Sessions, i + SESSION_ID);
            string close_msg = llList2Json(JSON_OBJECT, [
                "type", "dialog_close",
                "session_id", session_id
            ]);
            llMessageLinked(LINK_SET, DIALOG_BUS, close_msg, NULL_KEY);
            i += SESSION_STRIDE;
        }

        Sessions = [];
        FilteredPluginsData = [];
        PendingAcl = [];
    }
}

handle_acl_result(string msg) {
    if (!validate_required_fields(msg, ["avatar", "level", "is_blacklisted"], "handle_acl_result")) return;

    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    integer is_blacklisted = (integer)llJsonGetValue(msg, ["is_blacklisted"]);

    integer idx = llListFindList(PendingAcl, [avatar]);
    if (idx == -1 || idx % PENDING_ACL_STRIDE != PENDING_ACL_AVATAR) return;

    string requested_context = llList2String(PendingAcl, idx + PENDING_ACL_CONTEXT);
    PendingAcl = llDeleteSubList(PendingAcl, idx, idx + PENDING_ACL_STRIDE - 1);

    logd("ACL result: " + (string)level + " (blacklisted=" + (string)is_blacklisted + ") for " + llKey2Name(avatar) + " (context: " + requested_context + ")");

    create_session(avatar, level, is_blacklisted, requested_context);
    send_render_menu(avatar, requested_context);
}

handle_start(string msg, key user_key) {
    if (!json_has(msg, ["context"])) {
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
    logd("Root session start request from " + llKey2Name(user_key));

    integer idx = llListFindList(PendingAcl, [user_key]);
    if (idx != -1 && idx % PENDING_ACL_STRIDE == PENDING_ACL_AVATAR) return;

    PendingAcl += [user_key, ROOT_CONTEXT];

    string acl_query = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, acl_query, NULL_KEY);
}

start_sos_session(key user_key) {
    logd("SOS session start request from " + llKey2Name(user_key));

    integer idx = llListFindList(PendingAcl, [user_key]);
    if (idx != -1 && idx % PENDING_ACL_STRIDE == PENDING_ACL_AVATAR) return;

    PendingAcl += [user_key, SOS_CONTEXT];

    string acl_query = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, acl_query, NULL_KEY);
}

handle_return(string msg) {
    if (!json_has(msg, ["user"])) return;

    key user_key = (key)llJsonGetValue(msg, ["user"]);

    logd("Return requested for " + llKey2Name(user_key));

    // SECURITY FIX: Check session age and re-validate if stale
    integer session_idx = find_session_idx(user_key);
    if (session_idx != -1) {
        integer created_time = llList2Integer(Sessions, session_idx + SESSION_CREATED_TIME);
        integer age = llGetUnixTime() - created_time;

        if (age > SESSION_MAX_AGE) {
            logd("Session too old (" + (string)age + "s), re-validating ACL");
            string session_context = llList2String(Sessions, session_idx + SESSION_CONTEXT);
            cleanup_session(user_key);

            if (session_context == SOS_CONTEXT) {
                start_sos_session(user_key);
            }
            else {
                start_root_session(user_key);
            }
        }
        else {
            string session_context = llList2String(Sessions, session_idx + SESSION_CONTEXT);
            send_render_menu(user_key, session_context);
        }
    }
    else {
        start_root_session(user_key);
    }
}

handle_update_label(string msg) {
    if (!validate_required_fields(msg, ["context", "label"], "handle_update_label")) return;

    string context = llJsonGetValue(msg, ["context"]);
    string new_label = llJsonGetValue(msg, ["label"]);

    update_plugin_label(context, new_label);
}

handle_update_state(string msg) {
    if (!validate_required_fields(msg, ["context", "state"], "handle_update_state")) return;

    string context = llJsonGetValue(msg, ["context"]);
    integer plugin_state = (integer)llJsonGetValue(msg, ["state"]);

    set_plugin_state(context, plugin_state);
}

handle_plugin_acl_list(string msg) {
    if (!json_has(msg, ["acl_data"])) return;

    string acl_json = llJsonGetValue(msg, ["acl_data"]);
    apply_plugin_acl_list(acl_json);

    // Invalidate all sessions when ACL data changes
    // Sessions need to be recreated with updated ACL requirements
    if (llGetListLength(Sessions) > 0) {
        logd("Plugin ACL data updated - invalidating " + (string)(llGetListLength(Sessions) / SESSION_STRIDE) + " sessions");
        Sessions = [];
        FilteredPluginsData = [];
        PendingAcl = [];
    }
}

handle_dialog_response(string msg) {
    if (!validate_required_fields(msg, ["session_id", "button", "user"], "handle_dialog_response")) return;

    string session_id = llJsonGetValue(msg, ["session_id"]);
    string button = llJsonGetValue(msg, ["button"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    // Extract context (may be empty string for navigation buttons)
    string context = "";
    if (json_has(msg, ["context"])) {
        context = llJsonGetValue(msg, ["context"]);
    }

    integer idx = llListFindList(Sessions, [session_id]);
    if (idx != -1 && idx % SESSION_STRIDE == SESSION_ID) {
        handle_button_click(user, button, context);
        return;
    }

    logd("ERROR: Session not found for response: " + session_id);
}

handle_dialog_timeout(string msg) {
    if (!validate_required_fields(msg, ["session_id", "user"], "handle_dialog_timeout")) return;

    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    integer idx = llListFindList(Sessions, [session_id]);
    if (idx != -1 && idx % SESSION_STRIDE == SESSION_ID) {
        logd("Dialog timeout for " + llKey2Name(user));
        cleanup_session(user);
    }
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        AllPlugins = [];
        Sessions = [];
        FilteredPluginsData = [];
        PendingAcl = [];
        TouchData = [];
        PluginStates = [];

        logd("UI module started (v4.0 - UI/Kmod split - logic only)");

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

            // SECURITY FIX: Reject invalid touches
            if (touch_pos == ZERO_VECTOR) {
                logd("WARNING: Invalid touch position from " + llKey2Name(toucher));
                i += 1;
                jump next_touch;
            }

            // Validate touch distance
            float distance = llVecDist(touch_pos, llGetPos());
            if (distance > TOUCH_RANGE_M) {
                logd("WARNING: Touch outside range (" + (string)distance + "m) from " + llKey2Name(toucher));
                i += 1;
                jump next_touch;
            }

            // Record touch start time
            integer j = 0;
            integer len = llGetListLength(TouchData);

            while (j < len) {
                if (llList2Key(TouchData, j + TOUCH_DATA_KEY) == toucher) {
                    TouchData = llListReplaceList(TouchData, [llGetTime()], j + TOUCH_DATA_START_TIME, j + TOUCH_DATA_START_TIME);
                    jump recorded;
                }
                j += TOUCH_DATA_STRIDE;
            }

            // If we reach here, toucher was not found in TouchData
            TouchData += [toucher, llGetTime()];

            @recorded;
            logd("Touch start from " + llKey2Name(toucher));

            @next_touch;
            i += 1;
        }
    }

    touch_end(integer num_detected) {
        key wearer = llGetOwner();
        integer i = 0;

        while (i < num_detected) {
            key toucher = llDetectedKey(i);

            integer j = 0;
            integer len = llGetListLength(TouchData);

            while (j < len) {
                if (llList2Key(TouchData, j + TOUCH_DATA_KEY) == toucher) {
                    float start_time = llList2Float(TouchData, j + TOUCH_DATA_START_TIME);
                    float duration = llGetTime() - start_time;

                    TouchData = llDeleteSubList(TouchData, j, j + TOUCH_DATA_STRIDE - 1);

                    logd("Touch end from " + llKey2Name(toucher) + " (duration: " + (string)duration + "s)");

                    if (duration >= LONG_TOUCH_THRESHOLD && toucher == wearer) {
                        start_sos_session(toucher);
                    }
                    else {
                        // Provide feedback if non-wearer attempted long-touch (SOS is wearer-only)
                        if (duration >= LONG_TOUCH_THRESHOLD && toucher != wearer) {
                            logd("Non-wearer " + llKey2Name(toucher) + " performed long touch; SOS is wearer-only");
                            send_message(toucher, "Long-touch SOS is only available to the wearer.");
                        }
                        start_root_session(toucher);
                    }

                    jump next_toucher;
                }
                j += TOUCH_DATA_STRIDE;
            }

            @next_toucher;
            i += 1;
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (msg_type != "ping" && msg_type != "pong" && msg_type != "register" && msg_type != "register_now") {
            logd("Received message: channel=" + (string)num + " type=" + msg_type);
        }

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "plugin_list") handle_plugin_list(msg);
            else if (msg_type == "soft_reset" || msg_type == "soft_reset_all") llResetScript();
            return;
        }

        /* -------------------- AUTH BUS -------------------- */
        if (num == AUTH_BUS) {
            if (msg_type == "acl_result") handle_acl_result(msg);
            else if (msg_type == "plugin_acl_list") handle_plugin_acl_list(msg);
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
    
    // SECURITY FIX: Reset on owner change
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}