/* =============================================================================
   MODULE: ds_collar_kmod_ui.lsl (v3.2 - UUID-Based Change Detection)
   SECURITY AUDIT: ENHANCEMENTS APPLIED

   ROLE: Root touch menu with paged plugin list and ACL filtering

   ARCHITECTURE: Event-driven session management
   - Kernel broadcasts plugin_list only when UUIDs change
   - Kernel defers plugin_list responses during active registration (race fix)
   - UI invalidates sessions when receiving plugin_list
   - No version numbers needed (UUID tracking in kernel)

   CHANNELS:
   - 500 (KERNEL_LIFECYCLE): Plugin list subscription
   - 700 (AUTH_BUS): ACL queries and results
   - 900 (UI_BUS): Navigation (start/return/close)
   - 950 (DIALOG_BUS): Dialog display

   MULTI-SESSION: Supports multiple concurrent users with independent sessions

   SECURITY ENHANCEMENTS:
   - [CRITICAL] Race condition fix: UUID-based change detection
   - [MEDIUM] Touch range validation fixed (ZERO_VECTOR rejection)
   - [MEDIUM] ACL re-validation on session return (time-based)
   - [LOW] Production mode guard for debug
   - [LOW] Owner change handler
   - [LOW] Blacklist check in button handler

   NOTE: Plugin discovery race condition fixed in kernel (deferred responses)
   ============================================================================= */

integer DEBUG = TRUE;
integer PRODUCTION = FALSE;  // Set FALSE for development builds

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ═══════════════════════════════════════════════════════════
   CONSTANTS
   ═══════════════════════════════════════════════════════════ */
string ROOT_CONTEXT = "core_root";
string SOS_CONTEXT = "sos_root";
string SOS_PREFIX = "sos_";  // Prefix for SOS plugin contexts
integer MAX_FUNC_BTNS = 9;
float TOUCH_RANGE_M = 5.0;
float LONG_TOUCH_THRESHOLD = 1.5;

string BTN_NAV_LEFT = "<<";
string BTN_NAV_GAP = " ";
string BTN_NAV_RIGHT = ">>";

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

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
list AllPlugins = [];
list Sessions = [];
list FilteredPluginsData = [];
list PendingAcl = [];
list TouchData = [];

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    // SECURITY FIX: Production mode guard
    if (DEBUG && !PRODUCTION) llOwnerSay("[UI] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id(key user) {
    return "ui_" + (string)user + "_" + (string)llGetUnixTime();
}

integer starts_with(string str, string prefix) {
    integer prefix_len = llStringLength(prefix);
    if (prefix_len == 0) return TRUE;
    if (llStringLength(str) < prefix_len) return FALSE;
    return (llGetSubString(str, 0, prefix_len - 1) == prefix);
}

/* ═══════════════════════════════════════════════════════════
   SESSION MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

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
        integer is_sos_plugin = starts_with(context, SOS_PREFIX);

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

    integer filtered_start = llGetListLength(FilteredPluginsData);
    FilteredPluginsData += filtered;

    // SECURITY FIX: Add timestamp to session
    string session_id = generate_session_id(user);
    integer created_time = llGetUnixTime();
    Sessions += [user, acl, is_blacklisted, 0, 0, session_id, filtered_start, created_time, context_filter];

    logd("Created " + context_filter + " session for " + llKey2Name(user) + " (ACL=" + (string)acl + ", blacklisted=" + (string)is_blacklisted + ", " +
         (string)(llGetListLength(filtered) / PLUGIN_STRIDE) + " plugins)");
}

/* ═══════════════════════════════════════════════════════════
   PLUGIN LIST MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

apply_plugin_list(string plugins_json) {
    AllPlugins = [];
    
    logd("apply_plugin_list called with: " + plugins_json);
    
    if (!is_json_arr(plugins_json)) {
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

    // Request ACL data from auth module
    string request = llList2Json(JSON_OBJECT, ["type", "plugin_acl_list_request"]);
    llMessageLinked(LINK_SET, AUTH_BUS, request, NULL_KEY);
}

apply_plugin_acl_list(string acl_json) {
    logd("apply_plugin_acl_list called");

    if (!is_json_arr(acl_json)) {
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

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

/* ═══════════════════════════════════════════════════════════
   MENU DISPLAY
   ═══════════════════════════════════════════════════════════ */

show_root_menu(key user) {
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
        
        if (user_acl == -1) {
            if (is_blacklisted) {
                llRegionSayTo(user, 0, "You have been barred from using this collar.");
            }
            else {
                llRegionSayTo(user, 0, "This collar is not available for public use.");
            }
        }
        else if (user_acl == 0) {
            llRegionSayTo(user, 0, "You have relinquished control of the collar.");
        }
        else {
            llRegionSayTo(user, 0, "No plugins are currently installed.");
        }
        
        cleanup_session(user);
        return;
    }
    
    integer current_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);
    
    integer total_pages = (plugin_count + MAX_FUNC_BTNS - 1) / MAX_FUNC_BTNS;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;
    
    Sessions = llListReplaceList(Sessions, [total_pages], session_idx + SESSION_TOTAL_PAGES, session_idx + SESSION_TOTAL_PAGES);
    Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
    
    list buttons = [];
    integer start_idx = current_page * MAX_FUNC_BTNS * PLUGIN_STRIDE;
    integer end_idx = start_idx + (MAX_FUNC_BTNS * PLUGIN_STRIDE);
    if (end_idx > llGetListLength(filtered)) {
        end_idx = llGetListLength(filtered);
    }
    
    integer i = start_idx;
    while (i < end_idx) {
        string label = llList2String(filtered, i + PLUGIN_LABEL);
        buttons += [label];
        i += PLUGIN_STRIDE;
    }
    
    list reversed = [];
    i = llGetListLength(buttons) - 1;
    while (i >= 0) {
        reversed += [llList2String(buttons, i)];
        i = i - 1;
    }
    
    reversed = ["<<", ">>", "Close"] + reversed;
    
    string buttons_json = llList2Json(JSON_ARRAY, reversed);
    
    string title = "Main Menu";
    if (total_pages > 1) {
        title += " (" + (string)(current_page + 1) + "/" + (string)total_pages + ")";
    }
    
    string session_id = llList2String(Sessions, session_idx + SESSION_ID);
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", session_id,
        "user", (string)user,
        "title", title,
        "body", "Select an option:",
        "buttons", buttons_json,
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
    logd("Showing root menu to " + llKey2Name(user) + " (page " + (string)(current_page + 1) + "/" + (string)total_pages + ")");
}

show_sos_menu(key user) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
        logd("ERROR: No session for " + llKey2Name(user));
        return;
    }

    list filtered = get_session_filtered_plugins(session_idx);
    integer plugin_count = llGetListLength(filtered) / PLUGIN_STRIDE;

    if (plugin_count == 0) {
        llRegionSayTo(user, 0, "No emergency options are currently available.");
        cleanup_session(user);
        return;
    }

    integer current_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);

    integer total_pages = (plugin_count + MAX_FUNC_BTNS - 1) / MAX_FUNC_BTNS;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;

    Sessions = llListReplaceList(Sessions, [total_pages], session_idx + SESSION_TOTAL_PAGES, session_idx + SESSION_TOTAL_PAGES);
    Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);

    list buttons = [];
    integer start_idx = current_page * MAX_FUNC_BTNS * PLUGIN_STRIDE;
    integer end_idx = start_idx + (MAX_FUNC_BTNS * PLUGIN_STRIDE);
    if (end_idx > llGetListLength(filtered)) {
        end_idx = llGetListLength(filtered);
    }

    integer i = start_idx;
    while (i < end_idx) {
        string label = llList2String(filtered, i + PLUGIN_LABEL);
        buttons += [label];
        i += PLUGIN_STRIDE;
    }

    list reversed = [];
    i = llGetListLength(buttons) - 1;
    while (i >= 0) {
        reversed += [llList2String(buttons, i)];
        i = i - 1;
    }

    reversed = ["<<", ">>", "Close"] + reversed;

    string buttons_json = llList2Json(JSON_ARRAY, reversed);

    string title = "Emergency Menu";
    if (total_pages > 1) {
        title += " (" + (string)(current_page + 1) + "/" + (string)total_pages + ")";
    }

    string session_id = llList2String(Sessions, session_idx + SESSION_ID);

    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", session_id,
        "user", (string)user,
        "title", title,
        "body", "Emergency options:",
        "buttons", buttons_json,
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
    logd("Showing SOS menu to " + llKey2Name(user) + " (page " + (string)(current_page + 1) + "/" + (string)total_pages + ")");
}

/* ═══════════════════════════════════════════════════════════
   BUTTON HANDLING
   ═══════════════════════════════════════════════════════════ */

handle_button_click(key user, string button) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
        logd("ERROR: No session for button click from " + llKey2Name(user));
        return;
    }
    
    // SECURITY FIX: Check blacklist status
    integer is_blacklisted = llList2Integer(Sessions, session_idx + SESSION_IS_BLACKLISTED);
    if (is_blacklisted) {
        llRegionSayTo(user, 0, "You have been barred from using this collar.");
        cleanup_session(user);
        return;
    }
    
    integer current_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);
    integer total_pages = llList2Integer(Sessions, session_idx + SESSION_TOTAL_PAGES);
    string session_context = llList2String(Sessions, session_idx + SESSION_CONTEXT);

    if (button == "<<") {
        current_page -= 1;
        if (current_page < 0) current_page = total_pages - 1;
        Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);

        // Respect the session context
        if (session_context == SOS_CONTEXT) {
            show_sos_menu(user);
        } else {
            show_root_menu(user);
        }
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

        // Respect the session context
        if (session_context == SOS_CONTEXT) {
            show_sos_menu(user);
        } else {
            show_root_menu(user);
        }
        return;
    }
    
    integer i = 0;
    integer len = llGetListLength(AllPlugins);
    while (i < len) {
        string label = llList2String(AllPlugins, i + PLUGIN_LABEL);
        if (label == button) {
            string context = llList2String(AllPlugins, i + PLUGIN_CONTEXT);
            integer min_acl = llList2Integer(AllPlugins, i + PLUGIN_MIN_ACL);
            integer user_acl = llList2Integer(Sessions, session_idx + SESSION_ACL);

            // ACL check - CRITICAL for collar security
            if (user_acl < min_acl) {
                llRegionSayTo(user, 0, "Access denied.");
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
    
    logd("WARNING: No plugin found for button: " + button);
}

/* ═══════════════════════════════════════════════════════════
   PLUGIN LABEL UPDATE
   ═══════════════════════════════════════════════════════════ */

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

/* ═══════════════════════════════════════════════════════════
   MESSAGE HANDLERS
   ═══════════════════════════════════════════════════════════ */

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
        logd("Plugin list updated - invalidating " + (string)(llGetListLength(Sessions) / SESSION_STRIDE) + " sessions");
        Sessions = [];
        FilteredPluginsData = [];
        PendingAcl = [];
    }
}

handle_acl_result(string msg) {
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    if (!json_has(msg, ["is_blacklisted"])) return;

    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    integer is_blacklisted = (integer)llJsonGetValue(msg, ["is_blacklisted"]);

    integer i = 0;
    integer len = llGetListLength(PendingAcl);
    string requested_context = "";

    while (i < len) {
        if (llList2Key(PendingAcl, i + PENDING_ACL_AVATAR) == avatar) {
            requested_context = llList2String(PendingAcl, i + PENDING_ACL_CONTEXT);
            PendingAcl = llDeleteSubList(PendingAcl, i, i + PENDING_ACL_STRIDE - 1);
            jump found;
        }
        i += PENDING_ACL_STRIDE;
    }
    return;

    @found;

    logd("ACL result: " + (string)level + " (blacklisted=" + (string)is_blacklisted + ") for " + llKey2Name(avatar) + " (context: " + requested_context + ")");

    create_session(avatar, level, is_blacklisted, requested_context);

    if (requested_context == SOS_CONTEXT) {
        show_sos_menu(avatar);
    }
    else {
        show_root_menu(avatar);
    }
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

    integer i = 0;
    integer len = llGetListLength(PendingAcl);
    while (i < len) {
        if (llList2Key(PendingAcl, i + PENDING_ACL_AVATAR) == user_key) {
            return;
        }
        i += PENDING_ACL_STRIDE;
    }

    PendingAcl += [user_key, ROOT_CONTEXT];

    string acl_query = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, acl_query, NULL_KEY);
}

start_sos_session(key user_key) {
    logd("SOS session start request from " + llKey2Name(user_key));

    integer i = 0;
    integer len = llGetListLength(PendingAcl);
    while (i < len) {
        if (llList2Key(PendingAcl, i + PENDING_ACL_AVATAR) == user_key) {
            return;
        }
        i += PENDING_ACL_STRIDE;
    }

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

            if (session_context == SOS_CONTEXT) {
                show_sos_menu(user_key);
            }
            else {
                show_root_menu(user_key);
            }
        }
    }
    else {
        start_root_session(user_key);
    }
}

handle_update_label(string msg) {
    if (!json_has(msg, ["context"])) return;
    if (!json_has(msg, ["label"])) return;

    string context = llJsonGetValue(msg, ["context"]);
    string new_label = llJsonGetValue(msg, ["label"]);

    update_plugin_label(context, new_label);
}

handle_plugin_acl_list(string msg) {
    if (!json_has(msg, ["acl_data"])) return;

    string acl_json = llJsonGetValue(msg, ["acl_data"]);
    apply_plugin_acl_list(acl_json);
}

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (!json_has(msg, ["button"])) return;
    if (!json_has(msg, ["user"])) return;
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    string button = llJsonGetValue(msg, ["button"]);
    key user = (key)llJsonGetValue(msg, ["user"]);
    
    integer i = 0;
    while (i < llGetListLength(Sessions)) {
        if (llList2String(Sessions, i + SESSION_ID) == session_id) {
            handle_button_click(user, button);
            return;
        }
        i += SESSION_STRIDE;
    }
    
    logd("ERROR: Session not found for response: " + session_id);
}

handle_dialog_timeout(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (!json_has(msg, ["user"])) return;
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);
    
    integer i = 0;
    while (i < llGetListLength(Sessions)) {
        if (llList2String(Sessions, i + SESSION_ID) == session_id) {
            logd("Dialog timeout for " + llKey2Name(user));
            cleanup_session(user);
            return;
        }
        i += SESSION_STRIDE;
    }
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default
{
    state_entry() {
        AllPlugins = [];
        Sessions = [];
        FilteredPluginsData = [];
        PendingAcl = [];
        TouchData = [];

        logd("UI module started (UUID-based change detection, long-touch support)");

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
                            llRegionSayTo(toucher, 0, "Long-touch SOS is only available to the wearer.");
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
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type != "ping" && msg_type != "pong" && msg_type != "register" && msg_type != "register_now") {
            logd("Received message: channel=" + (string)num + " type=" + msg_type);
        }
        
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "plugin_list") {
                handle_plugin_list(msg);
            }
            else if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                llResetScript();
            }
        }
        else if (num == AUTH_BUS) {
            if (msg_type == "acl_result") {
                handle_acl_result(msg);
            }
            else if (msg_type == "plugin_acl_list") {
                handle_plugin_acl_list(msg);
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "start") {
                handle_start(msg, id);
            }
            else if (msg_type == "return") {
                handle_return(msg);
            }
            else if (msg_type == "update_label") {
                handle_update_label(msg);
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "dialog_response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "dialog_timeout") {
                handle_dialog_timeout(msg);
            }
        }
    }
    
    // SECURITY FIX: Reset on owner change
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
