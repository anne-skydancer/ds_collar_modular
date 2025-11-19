/*--------------------
MODULE: ds_collar_kmod_ui.lsl
VERSION: 1.00
REVISION: 45
PURPOSE: Session management, ACL filtering, and plugin list orchestration
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Implemented shared filter caching for memory optimization
- Added reactive session cleanup on ACL update events
- Split UI logic from menu rendering to delegate visuals to ds_collar_menu.lsl
- Added UUID-based plugin change detection to avoid registration races
- Enforced touch range validation and blacklist checks during session start
- Revalidated ACL levels on session return with time-based expiry
- Guarded debug logging for production and handled owner change resets
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

/* Plugin list stride */
integer PLUGIN_STRIDE = 3;
integer PLUGIN_CONTEXT = 0;
integer PLUGIN_LABEL = 1;
integer PLUGIN_MIN_ACL = 2;

/* Filtered Data Stride: [context, button_json] */
integer FILTERED_STRIDE = 2;
integer FILTERED_CONTEXT = 0;
integer FILTERED_JSON = 1;

/* Session list stride - SECURITY FIX: Added SESSION_CREATED_TIME */
integer SESSION_STRIDE = 10;
integer SESSION_USER = 0;
integer SESSION_ACL = 1;
integer SESSION_IS_BLACKLISTED = 2;
integer SESSION_PAGE = 3;
integer SESSION_TOTAL_PAGES = 4;
integer SESSION_ID = 5;
integer SESSION_FILTERED_START = 6;
integer SESSION_CREATED_TIME = 7;  // SECURITY FIX: Timestamp for ACL refresh
integer SESSION_CONTEXT = 8;  // Context filter for this session (root or sos)
integer SESSION_FILTERED_COUNT = 9; // Cached count of filtered plugins

integer MAX_SESSIONS = 5;
integer SESSION_MAX_AGE = 60;  // Seconds before ACL refresh required

/* Filter Cache Stride: [acl, is_blacklisted, context, start_idx, count] */
integer FILTER_CACHE_STRIDE = 5;
integer FILTER_CACHE_ACL = 0;
integer FILTER_CACHE_BLACKLISTED = 1;
integer FILTER_CACHE_CONTEXT = 2;
integer FILTER_CACHE_START = 3;
integer FILTER_CACHE_COUNT = 4;

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
list FilterCache = []; // Cache for filtered plugin lists
list PendingAcl = [];
list TouchData = [];

/* -------------------- HELPERS -------------------- */


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
            return FALSE;
        }
        i += 1;
    }
    return TRUE;
}

string generate_session_id(key user) {
    return "ui_" + (string)user + "_" + (string)llGetUnixTime();
}


/* -------------------- SESSION MANAGEMENT -------------------- */

integer find_session_idx(key user) {
    return llListFindList(Sessions, [user]);
}

integer get_session_filtered_start(integer session_idx) {
    return llList2Integer(Sessions, session_idx + SESSION_FILTERED_START);
}

integer get_session_filtered_count(integer session_idx) {
    return llList2Integer(Sessions, session_idx + SESSION_FILTERED_COUNT);
}

list get_session_filtered_plugins(integer session_idx) {
    integer start = get_session_filtered_start(session_idx);
    integer count = get_session_filtered_count(session_idx);
    integer end = start + (count * FILTERED_STRIDE);
    
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

    // MEMORY OPTIMIZATION: Do NOT delete from FilteredPluginsData
    // Data is now cached and shared between sessions.
    // FilteredPluginsData is only cleared when AllPlugins changes.

    Sessions = llDeleteSubList(Sessions, idx, idx + SESSION_STRIDE - 1);
}

create_session(key user, integer acl, integer is_blacklisted, string context_filter) {
    integer existing_idx = find_session_idx(user);
    if (existing_idx != -1) {
        cleanup_session(user);
    }

    if (llGetListLength(Sessions) / SESSION_STRIDE >= MAX_SESSIONS) {
        key oldest_user = llList2Key(Sessions, 0 + SESSION_USER);
        cleanup_session(oldest_user);
    }

    // Check Cache
    integer filtered_start = -1;
    integer filtered_count = 0;
    
    integer i = 0;
    integer cache_len = llGetListLength(FilterCache);
    while (i < cache_len) {
        if (llList2Integer(FilterCache, i + FILTER_CACHE_ACL) == acl &&
            llList2Integer(FilterCache, i + FILTER_CACHE_BLACKLISTED) == is_blacklisted &&
            llList2String(FilterCache, i + FILTER_CACHE_CONTEXT) == context_filter) {
            
            filtered_start = llList2Integer(FilterCache, i + FILTER_CACHE_START);
            filtered_count = llList2Integer(FilterCache, i + FILTER_CACHE_COUNT);
            jump cache_found;
        }
        i += FILTER_CACHE_STRIDE;
    }

    // Cache Miss - Build filtered list
    list filtered = [];
    i = 0;
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
            // Pre-build JSON for rendering speed
            string btn_json = llList2Json(JSON_OBJECT, ["context", context, "label", label]);
            filtered += [context, btn_json];
        }

        i += PLUGIN_STRIDE;
    }

    // OPTIMIZATION: Removed sorting here as AllPlugins is pre-sorted
    integer plugin_count = llGetListLength(filtered) / FILTERED_STRIDE;

    filtered_start = llGetListLength(FilteredPluginsData);
    filtered_count = plugin_count;
    FilteredPluginsData += filtered;
    
    // Add to Cache
    FilterCache += [acl, is_blacklisted, context_filter, filtered_start, filtered_count];

    @cache_found;

    // SECURITY FIX: Add timestamp to session
    string session_id = generate_session_id(user);
    integer created_time = llGetUnixTime();
    Sessions += [user, acl, is_blacklisted, 0, 0, session_id, filtered_start, created_time, context_filter, filtered_count];
}

/* -------------------- PLUGIN LIST MANAGEMENT -------------------- */

apply_plugin_list(string plugins_json) {
    AllPlugins = [];

    list plugins = llJson2List(plugins_json);
    integer count = llGetListLength(plugins);
    
    integer i = 0;
    while (i < count) {
        string plugin_obj = llList2String(plugins, i);

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

    // OPTIMIZATION: Sort AllPlugins once at initialization
    if (llGetListLength(AllPlugins) > PLUGIN_STRIDE) {
        AllPlugins = llListSortStrided(AllPlugins, PLUGIN_STRIDE, PLUGIN_LABEL, TRUE);
    }

    // Request ACL data from auth module
    string request = llList2Json(JSON_OBJECT, ["type", "plugin_acl_list_request"]);
    llMessageLinked(LINK_SET, AUTH_BUS, request, NULL_KEY);
}

apply_plugin_acl_list(string acl_json) {

    list acl_list = llJson2List(acl_json);
    integer count = llGetListLength(acl_list);

    integer i = 0;
    while (i < count) {
        string acl_obj = llList2String(acl_list, i);

        if (json_has(acl_obj, ["context"]) && json_has(acl_obj, ["min_acl"])) {
            string context = llJsonGetValue(acl_obj, ["context"]);
            integer min_acl = (integer)llJsonGetValue(acl_obj, ["min_acl"]);

            // Find this context in AllPlugins and update min_acl
            integer j = llListFindList(AllPlugins, [context]);
            if (j != -1) {
                AllPlugins = llListReplaceList(AllPlugins, [min_acl], j + PLUGIN_MIN_ACL, j + PLUGIN_MIN_ACL);
            }
        }

        i += 1;
    }
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
        return;
    }

    list filtered = get_session_filtered_plugins(session_idx);
    integer plugin_count = llGetListLength(filtered) / FILTERED_STRIDE;

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
    // OPTIMIZATION: Only write if changed to reduce list churn
    integer stored_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);
    integer stored_total = llList2Integer(Sessions, session_idx + SESSION_TOTAL_PAGES);
    
    if (current_page != stored_page || total_pages != stored_total) {
        Sessions = llListReplaceList(Sessions, [current_page, total_pages], session_idx + SESSION_PAGE, session_idx + SESSION_TOTAL_PAGES);
    }

    // Build button data with context and state
    list button_data = [];
    integer start_idx = current_page * MAX_FUNC_BTNS * FILTERED_STRIDE;
    integer end_idx = start_idx + (MAX_FUNC_BTNS * FILTERED_STRIDE);
    if (end_idx > llGetListLength(filtered)) {
        end_idx = llGetListLength(filtered);
    }

    integer i = start_idx;
    while (i < end_idx) {
        // Direct JSON access - massive speedup
        string btn_json = llList2String(filtered, i + FILTERED_JSON);
        button_data += [btn_json];
        i += FILTERED_STRIDE;
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
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(key user, string button, string context) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
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
    if (button == "<<" || button == ">>") {
        if (button == "<<") {
            current_page -= 1;
            if (current_page < 0) current_page = total_pages - 1;
        } else {
            current_page += 1;
            if (current_page >= total_pages) current_page = 0;
        }

        // OPTIMIZATION: Combined update of Page (3) through Timestamp (7)
        // Preserves: TOTAL_PAGES (4), ID (5), FILTERED_START (6)
        // Updates: PAGE (3), CREATED_TIME (7)
        integer total = llList2Integer(Sessions, session_idx + SESSION_TOTAL_PAGES);
        string sess_id = llList2String(Sessions, session_idx + SESSION_ID);
        integer f_start = llList2Integer(Sessions, session_idx + SESSION_FILTERED_START);
        
        Sessions = llListReplaceList(Sessions, [
            current_page, total, sess_id, f_start, llGetUnixTime()
        ], session_idx + SESSION_PAGE, session_idx + SESSION_CREATED_TIME);

        send_render_menu(user, session_context);
        return;
    }

    if (button == "Close") {
        cleanup_session(user);
        return;
    }

    // Plugin button clicked - use context directly for fast lookup
    if (context != "") {
        // Update session activity timestamp
        Sessions = llListReplaceList(Sessions, [llGetUnixTime()], session_idx + SESSION_CREATED_TIME, session_idx + SESSION_CREATED_TIME);

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
                return;
            }
            i += PLUGIN_STRIDE;
        }
        return;
    }
}

/* -------------------- PLUGIN LABEL UPDATE -------------------- */

update_plugin_label(string context, string new_label) {
    integer i = 0;
    integer len = llGetListLength(AllPlugins);
    
    while (i < len) {
        string all_context = llList2String(AllPlugins, i + PLUGIN_CONTEXT);
        if (all_context == context) {
            AllPlugins = llListReplaceList(AllPlugins, [new_label], i + PLUGIN_LABEL, i + PLUGIN_LABEL);
            
            integer j = 0;
            while (j < llGetListLength(FilteredPluginsData)) {
                string filtered_context = llList2String(FilteredPluginsData, j + FILTERED_CONTEXT);
                if (filtered_context == context) {
                    string new_json = llList2Json(JSON_OBJECT, ["context", context, "label", new_label]);
                    FilteredPluginsData = llListReplaceList(FilteredPluginsData, [new_json], j + FILTERED_JSON, j + FILTERED_JSON);
                }
                j += FILTERED_STRIDE;
            }
            return;
        }
        
        i += PLUGIN_STRIDE;
    }
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_acl_update(string msg) {
    if (!json_has(msg, ["scope"])) return;
    string scope = llJsonGetValue(msg, ["scope"]);
    
    if (scope == "global") {
        // Invalidate ALL sessions
        while (llGetListLength(Sessions) > 0) {
            key user = llList2Key(Sessions, SESSION_USER);
            cleanup_session(user);
        }
    }
    else if (scope == "avatar") {
        if (!json_has(msg, ["avatar"])) return;
        key avatar = (key)llJsonGetValue(msg, ["avatar"]);
        cleanup_session(avatar);
    }
}

handle_plugin_list(string msg) {

    if (!json_has(msg, ["plugins"])) {
        return;
    }

    string plugins_json = llJsonGetValue(msg, ["plugins"]);
    apply_plugin_list(plugins_json);

    // Invalidate all sessions when plugin list changes
    // Kernel only broadcasts when UUID changes detected, so this is always meaningful
    if (llGetListLength(Sessions) > 0) {
        integer session_count = llGetListLength(Sessions) / SESSION_STRIDE;

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
        FilterCache = []; // Clear cache
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


    // SECURITY FIX: Check session age and re-validate if stale
    integer session_idx = find_session_idx(user_key);
    if (session_idx != -1) {
        integer created_time = llList2Integer(Sessions, session_idx + SESSION_CREATED_TIME);
        integer age = llGetUnixTime() - created_time;

        if (age > SESSION_MAX_AGE) {
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
            // Update session activity timestamp
            Sessions = llListReplaceList(Sessions, [llGetUnixTime()], session_idx + SESSION_CREATED_TIME, session_idx + SESSION_CREATED_TIME);

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

handle_plugin_acl_list(string msg) {
    if (!json_has(msg, ["acl_data"])) return;

    string acl_json = llJsonGetValue(msg, ["acl_data"]);
    apply_plugin_acl_list(acl_json);

    // Invalidate all sessions when ACL data changes
    // Sessions need to be recreated with updated ACL requirements
    if (llGetListLength(Sessions) > 0) {
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
}

handle_dialog_timeout(string msg) {
    if (!validate_required_fields(msg, ["session_id", "user"], "handle_dialog_timeout")) return;

    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    integer idx = llListFindList(Sessions, [session_id]);
    if (idx != -1 && idx % SESSION_STRIDE == SESSION_ID) {
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
            else if (msg_type == "acl_update") handle_acl_update(msg);
            else if (msg_type == "plugin_acl_list") handle_plugin_acl_list(msg);
            return;
        }

        /* -------------------- UI BUS -------------------- */
        if (num == UI_BUS) {
            if (msg_type == "start") handle_start(msg, id);
            else if (msg_type == "return") handle_return(msg);
            else if (msg_type == "update_label") handle_update_label(msg);
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
