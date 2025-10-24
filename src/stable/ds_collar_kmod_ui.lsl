/* =============================================================================
   MODULE: ds_collar_kmod_ui.lsl (v2.0 - Multi-Session Support)
   
   ROLE: Root touch menu with paged plugin list and ACL filtering
   
   CHANNELS:
   - 500 (KERNEL_LIFECYCLE): Plugin list subscription
   - 700 (AUTH_BUS): ACL queries and results
   - 900 (UI_BUS): Navigation (start/return/close)
   - 950 (DIALOG_BUS): Dialog display
   
   MULTI-SESSION: Supports multiple concurrent users with independent sessions
   ============================================================================= */

integer DEBUG = TRUE;

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
integer MAX_FUNC_BTNS = 9;
float TOUCH_RANGE_M = 5.0;

string BTN_NAV_LEFT = "<<";
string BTN_NAV_GAP = " ";
string BTN_NAV_RIGHT = ">>";

/* Plugin list stride */
integer PLUGIN_STRIDE = 3;
integer PLUGIN_CONTEXT = 0;
integer PLUGIN_LABEL = 1;
integer PLUGIN_MIN_ACL = 2;

/* Session list stride */
integer SESSION_STRIDE = 6;
integer SESSION_USER = 0;
integer SESSION_ACL = 1;
integer SESSION_PAGE = 2;
integer SESSION_TOTAL_PAGES = 3;
integer SESSION_ID = 4;
integer SESSION_FILTERED_START = 5;  // Pointer to where this session's filtered plugins start in FilteredPluginsData

integer MAX_SESSIONS = 5;  // Maximum concurrent sessions

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
list AllPlugins = [];        // All registered plugins (shared)

// Multi-session tracking
list Sessions = [];          // [user, acl, page, total_pages, session_id, filtered_start, user, acl, ...]
list FilteredPluginsData = []; // Concatenated filtered plugin lists for all sessions

// Pending ACL queries
list PendingAcl = [];        // [user, user, ...] users waiting for ACL

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[UI] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id(key user) {
    return "ui_" + (string)user + "_" + (string)llGetUnixTime();
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
    // Count how many filtered plugins this session has
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
    
    // Remove session's filtered plugins from data
    integer start = get_session_filtered_start(idx);
    integer count = get_session_filtered_count(idx);
    integer end = start + (count * PLUGIN_STRIDE);
    
    if (count > 0) {
        FilteredPluginsData = llDeleteSubList(FilteredPluginsData, start, end - 1);
    }
    
    // Update all subsequent sessions' filtered_start pointers
    integer shift_amount = count * PLUGIN_STRIDE;
    integer i = idx + SESSION_STRIDE;
    while (i < llGetListLength(Sessions)) {
        integer old_start = llList2Integer(Sessions, i + SESSION_FILTERED_START);
        Sessions = llListReplaceList(Sessions, [old_start - shift_amount], i + SESSION_FILTERED_START, i + SESSION_FILTERED_START);
        i += SESSION_STRIDE;
    }
    
    // Remove session
    Sessions = llDeleteSubList(Sessions, idx, idx + SESSION_STRIDE - 1);
    
    logd("Session cleaned up for " + llKey2Name(user));
}

create_session(key user, integer acl) {
    // Check if session already exists
    integer existing_idx = find_session_idx(user);
    if (existing_idx != -1) {
        logd("Session already exists for " + llKey2Name(user) + ", updating");
        cleanup_session(user);
    }
    
    // Enforce session limit
    if (llGetListLength(Sessions) / SESSION_STRIDE >= MAX_SESSIONS) {
        // Remove oldest session
        key oldest_user = llList2Key(Sessions, 0 + SESSION_USER);
        logd("Session limit reached, removing oldest: " + llKey2Name(oldest_user));
        cleanup_session(oldest_user);
    }
    
    // Filter plugins for this user's ACL
    list filtered = [];
    integer i = 0;
    integer len = llGetListLength(AllPlugins);
    
    while (i < len) {
        string context = llList2String(AllPlugins, i + PLUGIN_CONTEXT);
        string label = llList2String(AllPlugins, i + PLUGIN_LABEL);
        integer min_acl = llList2Integer(AllPlugins, i + PLUGIN_MIN_ACL);
        
        if (acl >= min_acl) {
            filtered += [context, label, min_acl];
        }
        
        i += PLUGIN_STRIDE;
    }
    
    // Add filtered plugins to data pool
    integer filtered_start = llGetListLength(FilteredPluginsData);
    FilteredPluginsData += filtered;
    
    // Create session
    string session_id = generate_session_id(user);
    Sessions += [user, acl, 0, 0, session_id, filtered_start];
    
    logd("Created session for " + llKey2Name(user) + " (ACL=" + (string)acl + ", " + 
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
    
    // Count array elements
    integer count = 0;
    while (llJsonValueType(plugins_json, [count]) != JSON_INVALID) {
        count += 1;
    }
    
    logd("Array length: " + (string)count);
    
    integer i = 0;
    while (i < count) {
        string plugin_obj = llJsonGetValue(plugins_json, [i]);
        
        if (json_has(plugin_obj, ["context"]) &&
            json_has(plugin_obj, ["label"]) &&
            json_has(plugin_obj, ["min_acl"])) {
            
            string context = llJsonGetValue(plugin_obj, ["context"]);
            string label = llJsonGetValue(plugin_obj, ["label"]);
            integer min_acl = (integer)llJsonGetValue(plugin_obj, ["min_acl"]);
            
            AllPlugins += [context, label, min_acl];
        }
        
        i += 1;
    }
    
    logd("Plugin list updated: " + (string)(llGetListLength(AllPlugins) / PLUGIN_STRIDE) + " plugins");
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
        llRegionSayTo(user, 0, "No plugins available at your access level.");
        cleanup_session(user);
        return;
    }
    
    integer current_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);
    
    // Calculate pages
    integer total_pages = (plugin_count + MAX_FUNC_BTNS - 1) / MAX_FUNC_BTNS;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;
    
    // Update session with calculated total_pages
    Sessions = llListReplaceList(Sessions, [total_pages], session_idx + SESSION_TOTAL_PAGES, session_idx + SESSION_TOTAL_PAGES);
    Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
    
    // Build button list for current page
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
    
    // New layout: Nav buttons in bottom-left, content fills from bottom-right upward
    // [plugin 8] [plugin 9] [plugin 10]
    // [plugin 5] [plugin 6] [plugin 7]
    // [plugin 2] [plugin 3] [plugin 4]
    // [<<]       [>>]       [plugin 1]
    
    // Reverse button order so they display correctly
    list reversed = [];
    i = llGetListLength(buttons) - 1;
    while (i >= 0) {
        reversed += [llList2String(buttons, i)];
        i = i - 1;
    }
    
    // Add navigation in bottom-left (always show, enables wrap-around)
    reversed = ["<<", ">>"] + reversed;
    
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

/* ═══════════════════════════════════════════════════════════
   BUTTON HANDLING
   ═══════════════════════════════════════════════════════════ */

handle_button_click(key user, string button) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
        logd("ERROR: No session for button click from " + llKey2Name(user));
        return;
    }
    
    integer current_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);
    integer total_pages = llList2Integer(Sessions, session_idx + SESSION_TOTAL_PAGES);
    list filtered = get_session_filtered_plugins(session_idx);
    
    // Navigation buttons (wrap-around enabled)
    if (button == "<<") {
        current_page -= 1;
        if (current_page < 0) current_page = total_pages - 1;
        Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
        show_root_menu(user);
        return;
    }
    
    if (button == ">>") {
        current_page += 1;
        if (current_page >= total_pages) current_page = 0;
        Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
        show_root_menu(user);
        return;
    }
    
    // Find plugin by label
    integer i = 0;
    integer len = llGetListLength(filtered);
    while (i < len) {
        string label = llList2String(filtered, i + PLUGIN_LABEL);
        if (label == button) {
            string context = llList2String(filtered, i + PLUGIN_CONTEXT);
            
            // Send plugin start message
            string msg = llList2Json(JSON_OBJECT, [
                "type", "start",
                "context", context,
                "user", (string)user
            ]);
            
            llMessageLinked(LINK_SET, UI_BUS, msg, user);
            logd("Starting plugin: " + context + " for " + llKey2Name(user));
            
            // DON'T cleanup session - keep it for when plugin returns
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
            
            // Update in all active sessions' filtered lists
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
    
    // Plugin list updates are silent - no automatic UI display
}

handle_acl_result(string msg) {
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    
    // Check if this user is pending ACL
    integer pending_idx = llListFindList(PendingAcl, [avatar]);
    if (pending_idx == -1) return;
    
    // Remove from pending
    PendingAcl = llDeleteSubList(PendingAcl, pending_idx, pending_idx);
    
    logd("ACL result: " + (string)level + " for " + llKey2Name(avatar));
    
    // Create session and show menu
    create_session(avatar, level);
    show_root_menu(avatar);
}

handle_start(string msg, key user_key) {
    // Handle external start requests (e.g., from remote module)
    // ONLY process if this is a request for the ROOT menu
    
    if (!json_has(msg, ["context"])) {
        start_root_session(user_key);
        return;
    }
    
    string context = llJsonGetValue(msg, ["context"]);
    
    if (context == ROOT_CONTEXT) {
        start_root_session(user_key);
        return;
    }
    
    // Plugin-specific start - ignore (plugins handle these)
}

start_root_session(key user_key) {
    // Start new session - multiple users can have sessions simultaneously
    logd("External start request from " + llKey2Name(user_key));
    
    // Add to pending ACL list
    if (llListFindList(PendingAcl, [user_key]) == -1) {
        PendingAcl += [user_key];
    }
    
    // Request ACL for this user
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
    
    // Check if session exists
    integer session_idx = find_session_idx(user_key);
    if (session_idx != -1) {
        // Session exists, just show menu again
        show_root_menu(user_key);
    }
    else {
        // No session, create new one
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

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (!json_has(msg, ["button"])) return;
    if (!json_has(msg, ["user"])) return;
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    string button = llJsonGetValue(msg, ["button"]);
    key user = (key)llJsonGetValue(msg, ["user"]);
    
    // Find session by session_id
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
    
    // Find and cleanup session
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
        
        logd("UI module started (multi-session)");
        
        // Request plugin list
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
            
            // Validate touch distance
            if (touch_pos != ZERO_VECTOR) {
                float distance = llVecDist(touch_pos, llGetPos());
                if (distance > TOUCH_RANGE_M) {
                    i += 1;
                    jump next_touch;
                }
            }
            
            // Start session for this user (multiple users allowed)
            start_root_session(toucher);
            logd("Touch from " + llKey2Name(toucher));
            
            @next_touch;
            i += 1;
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        // Filter out noisy messages
        if (msg_type != "ping" && msg_type != "pong" && msg_type != "register" && msg_type != "register_now") {
            logd("Received message: channel=" + (string)num + " type=" + msg_type);
        }
        
        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "plugin_list") {
                handle_plugin_list(msg);
            }
        }
        
        /* ===== AUTH BUS ===== */
        else if (num == AUTH_BUS) {
            if (msg_type == "acl_result") {
                handle_acl_result(msg);
            }
        }
        
        /* ===== UI BUS ===== */
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
        
        /* ===== DIALOG BUS ===== */
        else if (num == DIALOG_BUS) {
            if (msg_type == "dialog_response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "dialog_timeout") {
                handle_dialog_timeout(msg);
            }
        }
    }
}
