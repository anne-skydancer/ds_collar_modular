/* ===============================================================
   MODULE: ds_collar_kmod_ui.lsl (v1.0 - Security Hardened)
   SECURITY AUDIT: ENHANCEMENTS APPLIED
   
   PURPOSE: Root touch menu with paged plugin list and ACL filtering
   
   CHANNELS:
   - 500 (KERNEL_LIFECYCLE): Plugin list subscription
   - 700 (AUTH_BUS): ACL queries and results
   - 900 (UI_BUS): Navigation (start/return/close)
   - 950 (DIALOG_BUS): Dialog display
   
   MULTI-SESSION: Supports multiple concurrent users with independent sessions
   
   SECURITY ENHANCEMENTS:
   - [MEDIUM] Touch range validation fixed (ZERO_VECTOR rejection)
   - [MEDIUM] ACL re-validation on session return (time-based)
   - [LOW] Production mode guard for debug
   - [LOW] Owner change handler
   - [LOW] Blacklist check in button handler
   =============================================================== */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ===============================================================
   CONSTANTS
   =============================================================== */
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

/* Session list stride - SECURITY FIX: Added SESSION_CREATED_TIME */
integer SESSION_STRIDE = 8;
integer SESSION_USER = 0;
integer SESSION_ACL = 1;
integer SESSION_IS_BLACKLISTED = 2;
integer SESSION_PAGE = 3;
integer SESSION_TOTAL_PAGES = 4;
integer SESSION_ID = 5;
integer SESSION_FILTERED_START = 6;
integer SESSION_CREATED_TIME = 7;  // SECURITY FIX: Timestamp for ACL refresh

integer MAX_SESSIONS = 5;
integer SESSION_MAX_AGE = 60;  // Seconds before ACL refresh required

/* ===============================================================
   STATE
   =============================================================== */
list AllPlugins = [];
list Sessions = [];
list FilteredPluginsData = [];
list PendingAcl = [];

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    // SECURITY FIX: Production mode guard
    if (DEBUG && !PRODUCTION) llOwnerSay("[UI] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generateSessionId(key user) {
    return "ui_" + (string)user + "_" + (string)llGetUnixTime();
}

/* ===============================================================
   SESSION MANAGEMENT
   =============================================================== */

integer findSessionIdx(key user) {
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

integer getSessionFilteredStart(integer session_idx) {
    return llList2Integer(Sessions, session_idx + SESSION_FILTERED_START);
}

integer getSessionFilteredCount(integer session_idx) {
    integer start = getSessionFilteredStart(session_idx);
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

list getSessionFilteredPlugins(integer session_idx) {
    integer start = getSessionFilteredStart(session_idx);
    integer count = getSessionFilteredCount(session_idx);
    integer end = start + (count * PLUGIN_STRIDE);
    
    if (end > start) {
        return llList2List(FilteredPluginsData, start, end - 1);
    }
    return [];
}

cleanupSession(key user) {
    integer idx = findSessionIdx(user);
    if (idx == -1) return;
    
    integer start = getSessionFilteredStart(idx);
    integer count = getSessionFilteredCount(idx);
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

createSession(key user, integer acl, integer is_blacklisted) {
    integer existing_idx = findSessionIdx(user);
    if (existing_idx != -1) {
        logd("Session already exists for " + llKey2Name(user) + ", updating");
        cleanupSession(user);
    }
    
    if (llGetListLength(Sessions) / SESSION_STRIDE >= MAX_SESSIONS) {
        key oldest_user = llList2Key(Sessions, 0 + SESSION_USER);
        logd("Session limit reached, removing oldest: " + llKey2Name(oldest_user));
        cleanupSession(oldest_user);
    }
    
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
    
    integer filtered_start = llGetListLength(FilteredPluginsData);
    FilteredPluginsData += filtered;
    
    // SECURITY FIX: Add timestamp to session
    string session_id = generateSessionId(user);
    integer created_time = llGetUnixTime();
    Sessions += [user, acl, is_blacklisted, 0, 0, session_id, filtered_start, created_time];
    
    logd("Created session for " + llKey2Name(user) + " (ACL=" + (string)acl + ", blacklisted=" + (string)is_blacklisted + ", " + 
         (string)(llGetListLength(filtered) / PLUGIN_STRIDE) + " plugins)");
}

/* ===============================================================
   PLUGIN LIST MANAGEMENT
   =============================================================== */

applyPluginList(string plugins_json) {
    AllPlugins = [];
    
    logd("apply_plugin_list called with: " + plugins_json);
    
    if (!isJsonArr(plugins_json)) {
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
        
        if (jsonHas(plugin_obj, ["context"]) &&
            jsonHas(plugin_obj, ["label"]) &&
            jsonHas(plugin_obj, ["min_acl"])) {
            
            string context = llJsonGetValue(plugin_obj, ["context"]);
            string label = llJsonGetValue(plugin_obj, ["label"]);
            integer min_acl = (integer)llJsonGetValue(plugin_obj, ["min_acl"]);
            
            AllPlugins += [context, label, min_acl];
        }
        
        i += 1;
    }
    
    logd("Plugin list updated: " + (string)(llGetListLength(AllPlugins) / PLUGIN_STRIDE) + " plugins");
}

integer isJsonArr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

/* ===============================================================
   MENU DISPLAY
   =============================================================== */

showRootMenu(key user) {
    integer session_idx = findSessionIdx(user);
    if (session_idx == -1) {
        logd("ERROR: No session for " + llKey2Name(user));
        return;
    }
    
    list filtered = getSessionFilteredPlugins(session_idx);
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
        
        cleanupSession(user);
        return;
    }
    
    integer current_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);
    
    integer total_pages = (plugin_count + MAX_FUNC_BTNS - 1) / MAX_FUNC_BTNS;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;
    
    Sessions = llListReplaceList(Sessions, [total_pages], session_idx + SESSION_TOTAL_PAGES, session_idx + SESSION_TOTAL_PAGES);
    Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);

    // Calculate button range for current page
    integer start_idx = current_page * MAX_FUNC_BTNS * PLUGIN_STRIDE;
    integer end_idx = start_idx + (MAX_FUNC_BTNS * PLUGIN_STRIDE);
    if (end_idx > llGetListLength(filtered)) {
        end_idx = llGetListLength(filtered);
    }

    // Build in reverse order to match llDialog display layout (eliminates reversal loop)
    list buttons = [];
    integer i = end_idx - PLUGIN_STRIDE;
    while (i >= start_idx) {
        string label = llList2String(filtered, i + PLUGIN_LABEL);
        buttons += [label];
        i -= PLUGIN_STRIDE;
    }

    // Prepend navigation buttons
    buttons = ["<<", ">>", "Close"] + buttons;

    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    
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

/* ===============================================================
   BUTTON HANDLING
   =============================================================== */

handleButtonClick(key user, string button) {
    integer session_idx = findSessionIdx(user);
    if (session_idx == -1) {
        logd("ERROR: No session for button click from " + llKey2Name(user));
        return;
    }
    
    // SECURITY FIX: Check blacklist status
    integer is_blacklisted = llList2Integer(Sessions, session_idx + SESSION_IS_BLACKLISTED);
    if (is_blacklisted) {
        llRegionSayTo(user, 0, "You have been barred from using this collar.");
        cleanupSession(user);
        return;
    }
    
    integer current_page = llList2Integer(Sessions, session_idx + SESSION_PAGE);
    integer total_pages = llList2Integer(Sessions, session_idx + SESSION_TOTAL_PAGES);
    list filtered = getSessionFilteredPlugins(session_idx);
    
    if (button == "<<") {
        current_page -= 1;
        if (current_page < 0) current_page = total_pages - 1;
        Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
        showRootMenu(user);
        return;
    }
    
    if (button == "Close") {
        cleanupSession(user);
        return;
    }
    
    if (button == ">>") {
        current_page += 1;
        if (current_page >= total_pages) current_page = 0;
        Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
        showRootMenu(user);
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
            if (user_acl < min_acl) {
                llRegionSayTo(user, 0, "Access denied.");
                logd("ACL insufficient: user=" + (string)user_acl + ", required=" + (string)min_acl);
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

/* ===============================================================
   PLUGIN LABEL UPDATE
   =============================================================== */

updatePluginLabel(string context, string new_label) {
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

/* ===============================================================
   MESSAGE HANDLERS
   =============================================================== */

handlePluginList(string msg) {
    logd("handle_plugin_list called");
    
    if (!jsonHas(msg, ["plugins"])) {
        logd("ERROR: No 'plugins' field in message!");
        return;
    }
    
    string plugins_json = llJsonGetValue(msg, ["plugins"]);
    applyPluginList(plugins_json);
}

handleAclResult(string msg) {
    if (!jsonHas(msg, ["avatar"])) return;
    if (!jsonHas(msg, ["level"])) return;
    if (!jsonHas(msg, ["is_blacklisted"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    integer is_blacklisted = (integer)llJsonGetValue(msg, ["is_blacklisted"]);
    
    integer pending_idx = llListFindList(PendingAcl, [avatar]);
    if (pending_idx == -1) return;
    
    PendingAcl = llDeleteSubList(PendingAcl, pending_idx, pending_idx);
    
    logd("ACL result: " + (string)level + " (blacklisted=" + (string)is_blacklisted + ") for " + llKey2Name(avatar));
    
    createSession(avatar, level, is_blacklisted);
    showRootMenu(avatar);
}

handleStart(string msg, key user_key) {
    if (!jsonHas(msg, ["context"])) {
        startRootSession(user_key);
        return;
    }
    
    string context = llJsonGetValue(msg, ["context"]);
    
    if (context == ROOT_CONTEXT) {
        startRootSession(user_key);
        return;
    }
}

startRootSession(key user_key) {
    logd("External start request from " + llKey2Name(user_key));
    
    if (llListFindList(PendingAcl, [user_key]) == -1) {
        PendingAcl += [user_key];
    }
    
    string acl_query = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, acl_query, NULL_KEY);
}

handleReturn(string msg) {
    if (!jsonHas(msg, ["user"])) return;
    
    key user_key = (key)llJsonGetValue(msg, ["user"]);
    
    logd("Return requested for " + llKey2Name(user_key));
    
    // SECURITY FIX: Check session age and re-validate if stale
    integer session_idx = findSessionIdx(user_key);
    if (session_idx != -1) {
        integer created_time = llList2Integer(Sessions, session_idx + SESSION_CREATED_TIME);
        integer age = llGetUnixTime() - created_time;
        
        if (age > SESSION_MAX_AGE) {
            logd("Session too old (" + (string)age + "s), re-validating ACL");
            cleanupSession(user_key);
            startRootSession(user_key);
        }
        else {
            showRootMenu(user_key);
        }
    }
    else {
        startRootSession(user_key);
    }
}

handleUpdateLabel(string msg) {
    if (!jsonHas(msg, ["context"])) return;
    if (!jsonHas(msg, ["label"])) return;
    
    string context = llJsonGetValue(msg, ["context"]);
    string new_label = llJsonGetValue(msg, ["label"]);
    
    updatePluginLabel(context, new_label);
}

handleDialogResponse(string msg) {
    if (!jsonHas(msg, ["session_id"])) return;
    if (!jsonHas(msg, ["button"])) return;
    if (!jsonHas(msg, ["user"])) return;
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    string button = llJsonGetValue(msg, ["button"]);
    key user = (key)llJsonGetValue(msg, ["user"]);
    
    integer i = 0;
    while (i < llGetListLength(Sessions)) {
        if (llList2String(Sessions, i + SESSION_ID) == session_id) {
            handleButtonClick(user, button);
            return;
        }
        i += SESSION_STRIDE;
    }
    
    logd("ERROR: Session not found for response: " + session_id);
}

handleDialogTimeout(string msg) {
    if (!jsonHas(msg, ["session_id"])) return;
    if (!jsonHas(msg, ["user"])) return;
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);
    
    integer i = 0;
    while (i < llGetListLength(Sessions)) {
        if (llList2String(Sessions, i + SESSION_ID) == session_id) {
            logd("Dialog timeout for " + llKey2Name(user));
            cleanupSession(user);
            return;
        }
        i += SESSION_STRIDE;
    }
}

/* ===============================================================
   EVENTS
   =============================================================== */

default
{
    state_entry() {
        AllPlugins = [];
        Sessions = [];
        FilteredPluginsData = [];
        PendingAcl = [];
        
        logd("UI module started (multi-session)");
        
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
            
            // Valid touch - proceed
            startRootSession(toucher);
            logd("Touch from " + llKey2Name(toucher));
            
            @next_touch;
            i += 1;
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!jsonHas(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type != "ping" && msg_type != "pong" && msg_type != "register" && msg_type != "register_now") {
            logd("Received message: channel=" + (string)num + " type=" + msg_type);
        }
        
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "plugin_list") {
                handlePluginList(msg);
            }
        }
        else if (num == AUTH_BUS) {
            if (msg_type == "acl_result") {
                handleAclResult(msg);
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "start") {
                handleStart(msg, id);
            }
            else if (msg_type == "return") {
                handleReturn(msg);
            }
            else if (msg_type == "update_label") {
                handleUpdateLabel(msg);
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "dialog_response") {
                handleDialogResponse(msg);
            }
            else if (msg_type == "dialog_timeout") {
                handleDialogTimeout(msg);
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
