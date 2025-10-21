/* =============================================================
   KERNEL MODULE: ds_collar_kmod_dialogs.lsl
   PURPOSE: Centralized dialog management for all plugins
            - Single-user dialogs (standard menus)
            - Multi-party confirmations (multiple users must approve)
            - Automatic listener cleanup and timeout handling
            - Standard button layouts (Back, pagination, etc)
            - Session tracking per user
   FIXED: Proper button label handling (no empty strings)
   ============================================================= */

integer DEBUG = FALSE;

/* ---------- Link Message Numbers ---------- */
integer K_DIALOG_OPEN       = 950;  // Plugin → Dialog: Open single-user dialog
integer K_DIALOG_RESPONSE   = 951;  // Dialog → Plugin: User clicked button
integer K_DIALOG_TIMEOUT    = 952;  // Dialog → Plugin: Dialog expired
integer K_DIALOG_CLOSE      = 953;  // Plugin → Dialog: Force close session
integer K_DIALOG_PAGINATED  = 954;  // Plugin → Dialog: Open paginated dialog
integer K_DIALOG_CONFIRM    = 955;  // Plugin → Dialog: Open confirmation dialog (single or multi-party)
integer K_DIALOG_INPUT      = 956;  // Plugin → Dialog: Request text input

/* ---------- Dialog Configuration ---------- */
float   DIALOG_TIMEOUT_SEC      = 180.0;
float   INPUT_TIMEOUT_SEC       = 60.0;
float   MULTIPARTY_TIMEOUT_SEC  = 300.0;  // 5 minutes for all parties to confirm
integer REMINDER_INTERVAL       = 60;     // Remind every 60 seconds

string  FILL_BUTTON         = " ";  // Single space - LSL accepts this
string  BACK_BUTTON         = "Back";
string  PREV_BUTTON         = "<<";
string  NEXT_BUTTON         = ">>";
integer ITEMS_PER_PAGE      = 9;

/* ---------- Single-User Dialog Sessions ---------- */
// Format: [user, context, channel, listen_handle, expire_time, session_type, metadata, ...]
list    ActiveSessions      = [];
integer SESSION_STRIDE      = 7;

integer SESSION_USER        = 0;
integer SESSION_CONTEXT     = 1;
integer SESSION_CHANNEL     = 2;
integer SESSION_HANDLE      = 3;
integer SESSION_EXPIRE      = 4;
integer SESSION_TYPE        = 5;  // "dialog", "paginated", "confirm", "input"
integer SESSION_META        = 6;  // JSON metadata for session type

/* ---------- Multi-Party Confirmations ---------- */
// Format: [request_id, initiator, context, action_desc, timeout_epoch, confirmed_list, pending_list, metadata, ...]
list    MultiPartyRequests  = [];
integer MULTIPARTY_STRIDE   = 8;

integer MP_ID               = 0;
integer MP_INITIATOR        = 1;
integer MP_CONTEXT          = 2;
integer MP_ACTION_DESC      = 3;
integer MP_TIMEOUT          = 4;
integer MP_CONFIRMED        = 5;  // JSON array of confirmed avatars
integer MP_PENDING          = 6;  // JSON array of pending avatars
integer MP_METADATA         = 7;  // JSON object with extra data

/* ---------- State ---------- */
integer NextRequestId       = 1;
integer ReminderTimer       = 0;

/* ========================== Helpers ========================== */

integer logd(string msg) {
    if (DEBUG) llOwnerSay("[DIALOGS] " + msg);
    return 0;
}

integer json_has(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

integer now() {
    return llGetUnixTime();
}

string generate_request_id() {
    string id = "mpc_" + (string)NextRequestId;
    NextRequestId += 1;
    return id;
}

/* ========================== List Helpers ========================== */

list json_array_to_list(string json_array) {
    list result = [];
    integer i = 0;
    string val = llJsonGetValue(json_array, [i]);
    
    while (val != JSON_INVALID) {
        result += [(key)val];
        i += 1;
        val = llJsonGetValue(json_array, [i]);
    }
    
    return result;
}

string list_to_json_array(list input_list) {
    list json_items = [];
    integer i = 0;
    integer len = llGetListLength(input_list);
    
    while (i < len) {
        json_items += [(string)llList2Key(input_list, i)];
        i += 1;
    }
    
    return llList2Json(JSON_ARRAY, json_items);
}

integer list_contains_key(list haystack, key needle) {
    return (llListFindList(haystack, [needle]) != -1);
}

/* ========================== Single-User Session Management ========================== */

integer find_session_index(key user) {
    integer i = 0;
    integer len = llGetListLength(ActiveSessions);
    
    while (i < len) {
        if (llList2Key(ActiveSessions, i + SESSION_USER) == user) {
            return i;
        }
        i += SESSION_STRIDE;
    }
    
    return -1;
}

integer close_session(key user) {
    integer idx = find_session_index(user);
    if (idx == -1) return FALSE;
    
    integer handle = llList2Integer(ActiveSessions, idx + SESSION_HANDLE);
    if (handle != 0) {
        llListenRemove(handle);
        logd("Removed listen handle " + (string)handle + " for user " + (string)user);
    }
    
    ActiveSessions = llDeleteSubList(ActiveSessions, idx, idx + SESSION_STRIDE - 1);
    return TRUE;
}

integer close_all_sessions() {
    integer i = 0;
    integer len = llGetListLength(ActiveSessions);
    
    while (i < len) {
        integer handle = llList2Integer(ActiveSessions, i + SESSION_HANDLE);
        if (handle != 0) {
            llListenRemove(handle);
        }
        i += SESSION_STRIDE;
    }
    
    ActiveSessions = [];
    logd("Closed all single-user sessions");
    return TRUE;
}

integer create_or_update_session(key user, string context, integer channel, integer handle, string session_type, string metadata) {
    integer idx = find_session_index(user);
    integer expire_time = now() + (integer)DIALOG_TIMEOUT_SEC;
    
    if (session_type == "input") {
        expire_time = now() + (integer)INPUT_TIMEOUT_SEC;
    }
    
    if (idx != -1) {
        integer old_handle = llList2Integer(ActiveSessions, idx + SESSION_HANDLE);
        if (old_handle != 0 && old_handle != handle) {
            llListenRemove(old_handle);
        }
        
        ActiveSessions = llListReplaceList(
            ActiveSessions,
            [user, context, channel, handle, expire_time, session_type, metadata],
            idx,
            idx + SESSION_STRIDE - 1
        );
    } else {
        ActiveSessions += [user, context, channel, handle, expire_time, session_type, metadata];
    }
    
    return TRUE;
}

string get_session_context(key user) {
    integer idx = find_session_index(user);
    if (idx == -1) return "";
    return llList2String(ActiveSessions, idx + SESSION_CONTEXT);
}

string get_session_type(key user) {
    integer idx = find_session_index(user);
    if (idx == -1) return "";
    return llList2String(ActiveSessions, idx + SESSION_TYPE);
}

string get_session_metadata(key user) {
    integer idx = find_session_index(user);
    if (idx == -1) return "";
    return llList2String(ActiveSessions, idx + SESSION_META);
}

/* ========================== Multi-Party Confirmation Management ========================== */

integer find_multiparty_by_id(string request_id) {
    integer i = 0;
    integer len = llGetListLength(MultiPartyRequests);
    
    while (i < len) {
        if (llList2String(MultiPartyRequests, i + MP_ID) == request_id) {
            return i;
        }
        i += MULTIPARTY_STRIDE;
    }
    
    return -1;
}

integer find_multiparty_by_user(key user) {
    integer i = 0;
    integer len = llGetListLength(MultiPartyRequests);
    
    while (i < len) {
        string pending_json = llList2String(MultiPartyRequests, i + MP_PENDING);
        list pending_list = json_array_to_list(pending_json);
        
        if (list_contains_key(pending_list, user)) {
            return i;
        }
        
        i += MULTIPARTY_STRIDE;
    }
    
    return -1;
}

integer create_multiparty_request(string request_id, key initiator, string context, string action_desc, 
                                  list required_avatars, string metadata) {
    integer timeout_epoch = now() + (integer)MULTIPARTY_TIMEOUT_SEC;
    
    string confirmed_json = llList2Json(JSON_ARRAY, []);
    string pending_json = list_to_json_array(required_avatars);
    
    MultiPartyRequests += [
        request_id,
        initiator,
        context,
        action_desc,
        timeout_epoch,
        confirmed_json,
        pending_json,
        metadata
    ];
    
    logd("Created multi-party request: " + request_id + " requires " + (string)llGetListLength(required_avatars) + " avatars");
    
    if (ReminderTimer == 0) {
        ReminderTimer = 1;
        llSetTimerEvent((float)REMINDER_INTERVAL);
    }
    
    return TRUE;
}

integer add_multiparty_confirmation(string request_id, key avatar) {
    integer idx = find_multiparty_by_id(request_id);
    if (idx == -1) return FALSE;
    
    string confirmed_json = llList2String(MultiPartyRequests, idx + MP_CONFIRMED);
    string pending_json = llList2String(MultiPartyRequests, idx + MP_PENDING);
    
    list confirmed_list = json_array_to_list(confirmed_json);
    list pending_list = json_array_to_list(pending_json);
    
    if (list_contains_key(confirmed_list, avatar)) return FALSE;
    if (!list_contains_key(pending_list, avatar)) return FALSE;
    
    confirmed_list += [avatar];
    integer pending_idx = llListFindList(pending_list, [avatar]);
    pending_list = llDeleteSubList(pending_list, pending_idx, pending_idx);
    
    MultiPartyRequests = llListReplaceList(
        MultiPartyRequests,
        [list_to_json_array(confirmed_list), list_to_json_array(pending_list)],
        idx + MP_CONFIRMED,
        idx + MP_PENDING
    );
    
    logd("Avatar " + (string)avatar + " confirmed " + request_id);
    return TRUE;
}

integer remove_multiparty_request(string request_id) {
    integer idx = find_multiparty_by_id(request_id);
    if (idx == -1) return FALSE;
    
    MultiPartyRequests = llDeleteSubList(MultiPartyRequests, idx, idx + MULTIPARTY_STRIDE - 1);
    
    logd("Removed multi-party request: " + request_id);
    
    if (llGetListLength(MultiPartyRequests) == 0) {
        ReminderTimer = 0;
        llSetTimerEvent(0.0);
    }
    
    return TRUE;
}

integer is_multiparty_complete(string request_id) {
    integer idx = find_multiparty_by_id(request_id);
    if (idx == -1) return FALSE;
    
    string pending_json = llList2String(MultiPartyRequests, idx + MP_PENDING);
    list pending_list = json_array_to_list(pending_json);
    
    return (llGetListLength(pending_list) == 0);
}

/* ========================== Dialog Construction ========================== */

list pad_buttons(list buttons) {
    while ((llGetListLength(buttons) % 3) != 0) {
        buttons += FILL_BUTTON;
    }
    return buttons;
}

list build_paginated_buttons(list items, integer page, integer total_pages, integer include_back) {
    integer start_idx = page * ITEMS_PER_PAGE;
    integer end_idx = start_idx + ITEMS_PER_PAGE - 1;
    integer items_count = llGetListLength(items);
    
    if (end_idx >= items_count) {
        end_idx = items_count - 1;
    }
    
    list page_items = llList2List(items, start_idx, end_idx);
    list buttons = page_items;
    
    while ((llGetListLength(buttons) % 3) != 0) {
        buttons += FILL_BUTTON;
    }
    
    if (total_pages > 1) {
        if (page > 0) {
            buttons += PREV_BUTTON;
        } else {
            buttons += FILL_BUTTON;
        }
        
        if (include_back) {
            buttons += BACK_BUTTON;
        } else {
            buttons += FILL_BUTTON;
        }
        
        if (page < total_pages - 1) {
            buttons += NEXT_BUTTON;
        } else {
            buttons += FILL_BUTTON;
        }
    } else {
        if (include_back) {
            buttons += [FILL_BUTTON, BACK_BUTTON, FILL_BUTTON];
        }
    }
    
    return buttons;
}

list apply_layout(list buttons, string layout) {
    // CHANGED: Always ensure we have valid button labels first
    integer i = 0;
    integer len = llGetListLength(buttons);
    list cleaned = [];
    
    while (i < len) {
        string btn = llList2String(buttons, i);
        if (llStringTrim(btn, STRING_TRIM) == "") {
            cleaned += FILL_BUTTON;
        } else {
            cleaned += btn;
        }
        i += 1;
    }
    
    buttons = cleaned;
    buttons = pad_buttons(buttons);
    
    if (layout == "back_center") {
        len = llGetListLength(buttons);
        if (len >= 3) {
            buttons = llListReplaceList(buttons, [FILL_BUTTON, BACK_BUTTON, FILL_BUTTON], len - 3, len - 1);
        }
    }
    
    if (layout == "animate") {
        /* Animate layout: 
           - First 3 buttons: <<, Back, >> (navigation on bottom)
           - 4th button: [Stop] at index 3
           - Remaining: animation names
           - Pad to 12 total */
        while (llGetListLength(buttons) < 12) {
            buttons += FILL_BUTTON;
        }
        if (llGetListLength(buttons) > 12) {
            buttons = llDeleteSubList(buttons, 12, -1);
        }
    }
    
    return buttons;
}

/* ========================== Notification Functions ========================== */

integer notify_pending_users(string request_id) {
    integer idx = find_multiparty_by_id(request_id);
    if (idx == -1) return FALSE;
    
    key initiator = llList2Key(MultiPartyRequests, idx + MP_INITIATOR);
    string action_desc = llList2String(MultiPartyRequests, idx + MP_ACTION_DESC);
    string pending_json = llList2String(MultiPartyRequests, idx + MP_PENDING);
    string confirmed_json = llList2String(MultiPartyRequests, idx + MP_CONFIRMED);
    
    list pending_list = json_array_to_list(pending_json);
    list confirmed_list = json_array_to_list(confirmed_json);
    
    integer confirmed_count = llGetListLength(confirmed_list);
    integer required_count = confirmed_count + llGetListLength(pending_list);
    
    string initiator_name = llKey2Name(initiator);
    
    integer i = 0;
    while (i < llGetListLength(pending_list)) {
        key pending_user = llList2Key(pending_list, i);
        
        string msg = "⚠️ CONFIRMATION REQUIRED ⚠️\n\n";
        msg += initiator_name + " has initiated:\n";
        msg += action_desc + "\n\n";
        msg += "Progress: " + (string)confirmed_count + "/" + (string)required_count + " confirmed\n";
        msg += "Touch to respond.";
        
        llRegionSayTo(pending_user, 0, msg);
        i += 1;
    }
    
    return TRUE;
}

integer show_multiparty_dialog(key user, string request_id) {
    integer idx = find_multiparty_by_id(request_id);
    if (idx == -1) return FALSE;
    
    key initiator = llList2Key(MultiPartyRequests, idx + MP_INITIATOR);
    string action_desc = llList2String(MultiPartyRequests, idx + MP_ACTION_DESC);
    string confirmed_json = llList2String(MultiPartyRequests, idx + MP_CONFIRMED);
    string pending_json = llList2String(MultiPartyRequests, idx + MP_PENDING);
    
    list confirmed_list = json_array_to_list(confirmed_json);
    list pending_list = json_array_to_list(pending_json);
    
    integer confirmed_count = llGetListLength(confirmed_list);
    integer required_count = confirmed_count + llGetListLength(pending_list);
    
    string initiator_name = llKey2Name(initiator);
    
    // Build standard confirmation dialog
    string body = "⚠️ CONFIRMATION REQUIRED ⚠️\n\n";
    body += "Initiated by: " + initiator_name + "\n";
    body += action_desc + "\n\n";
    body += "Progress: " + (string)confirmed_count + "/" + (string)required_count + "\n\n";
    body += "Do you approve?";
    
    list buttons = [
        FILL_BUTTON,
        "APPROVE",
        FILL_BUTTON,
        FILL_BUTTON,
        "DENY",
        FILL_BUTTON
    ];
    
    close_session(user);
    
    integer channel = -100000 - (integer)llFrand(1000000.0);
    integer handle = llListen(channel, "", user, "");
    
    create_or_update_session(user, "multiparty_" + request_id, channel, handle, "multiparty", "");
    
    llDialog(user, body, buttons, channel);
    
    return TRUE;
}

/* ========================== Message Handlers ========================== */

integer handle_dialog_open(string json_msg, key sender) {
    if (!json_has(json_msg, ["user"]) || !json_has(json_msg, ["body"]) || !json_has(json_msg, ["buttons"])) {
        logd("ERROR: dialog_open missing required fields");
        return FALSE;
    }
    
    key user = (key)llJsonGetValue(json_msg, ["user"]);
    string body = llJsonGetValue(json_msg, ["body"]);
    string buttons_json = llJsonGetValue(json_msg, ["buttons"]);
    
    list buttons = [];
    integer i = 0;
    string btn = llJsonGetValue(buttons_json, [i]);
    while (btn != JSON_INVALID) {
        // CHANGED: Ensure we never add empty strings
        if (btn != "") {
            buttons += btn;
        } else {
            buttons += FILL_BUTTON;
        }
        i += 1;
        btn = llJsonGetValue(buttons_json, [i]);
    }
    
    string context = "unknown";
    if (json_has(json_msg, ["context"])) {
        context = llJsonGetValue(json_msg, ["context"]);
    }
    
    string layout = "standard";
    if (json_has(json_msg, ["layout"])) {
        layout = llJsonGetValue(json_msg, ["layout"]);
    }
    
    buttons = apply_layout(buttons, layout);
    
    close_session(user);
    
    integer channel = -100000 - (integer)llFrand(1000000.0);
    integer handle = llListen(channel, "", user, "");
    
    create_or_update_session(user, context, channel, handle, "dialog", "");
    
    llDialog(user, body, buttons, channel);
    
    logd("Opened dialog for " + (string)user + " in context '" + context + "'");
    
    llSetTimerEvent(30.0);
    
    return TRUE;
}

integer handle_dialog_confirm(string json_msg, key sender) {
    if (!json_has(json_msg, ["context"])) {
        logd("ERROR: dialog_confirm missing 'context'");
        return FALSE;
    }
    
    string context = llJsonGetValue(json_msg, ["context"]);
    
    // Check if this is multi-party confirmation
    if (json_has(json_msg, ["required_avatars"])) {
        // Multi-party confirmation
        if (!json_has(json_msg, ["action_desc"])) {
            logd("ERROR: multi-party confirm missing 'action_desc'");
            return FALSE;
        }
        
        string action_desc = llJsonGetValue(json_msg, ["action_desc"]);
        string avatars_json = llJsonGetValue(json_msg, ["required_avatars"]);
        
        string metadata = "{}";
        if (json_has(json_msg, ["metadata"])) {
            metadata = llJsonGetValue(json_msg, ["metadata"]);
        }
        
        list required_avatars = json_array_to_list(avatars_json);
        
        if (llGetListLength(required_avatars) == 0) {
            logd("ERROR: No required avatars specified");
            return FALSE;
        }
        
        string request_id = generate_request_id();
        create_multiparty_request(request_id, sender, context, action_desc, required_avatars, metadata);
        
        string status_msg = llList2Json(JSON_OBJECT, [
            "type", "dialog_response",
            "context", context,
            "button", "multiparty_created",
            "request_id", request_id,
            "confirmed_count", "0",
            "required_count", (string)llGetListLength(required_avatars)
        ]);
        
        llMessageLinked(LINK_SET, K_DIALOG_RESPONSE, status_msg, sender);
        
        notify_pending_users(request_id);
        
        return TRUE;
    } else {
        // Single-party confirmation
        if (!json_has(json_msg, ["user"]) || !json_has(json_msg, ["body"])) {
            logd("ERROR: single-party confirm missing required fields");
            return FALSE;
        }
        
        key user = (key)llJsonGetValue(json_msg, ["user"]);
        string body = llJsonGetValue(json_msg, ["body"]);
        
        string confirm_button = "Yes";
        if (json_has(json_msg, ["confirm_button"])) {
            confirm_button = llJsonGetValue(json_msg, ["confirm_button"]);
        }
        
        string cancel_button = "No";
        if (json_has(json_msg, ["cancel_button"])) {
            cancel_button = llJsonGetValue(json_msg, ["cancel_button"]);
        }
        
        string confirm_response = "confirmed";
        if (json_has(json_msg, ["confirm_response"])) {
            confirm_response = llJsonGetValue(json_msg, ["confirm_response"]);
        }
        
        string cancel_response = "cancelled";
        if (json_has(json_msg, ["cancel_response"])) {
            cancel_response = llJsonGetValue(json_msg, ["cancel_response"]);
        }
        
        list buttons = [
            FILL_BUTTON,
            confirm_button,
            FILL_BUTTON,
            FILL_BUTTON,
            cancel_button,
            FILL_BUTTON
        ];
        
        string metadata = llList2Json(JSON_OBJECT, [
            "confirm_button", confirm_button,
            "cancel_button", cancel_button,
            "confirm_response", confirm_response,
            "cancel_response", cancel_response
        ]);
        
        close_session(user);
        
        integer channel = -100000 - (integer)llFrand(1000000.0);
        integer handle = llListen(channel, "", user, "");
        
        create_or_update_session(user, context, channel, handle, "confirm", metadata);
        
        llDialog(user, body, buttons, channel);
        
        logd("Opened confirm dialog for " + (string)user);
        
        llSetTimerEvent(30.0);
        
        return TRUE;
    }
}

integer handle_dialog_close(string json_msg) {
    if (!json_has(json_msg, ["user"])) {
        logd("ERROR: dialog_close missing 'user' field");
        return FALSE;
    }
    
    key user = (key)llJsonGetValue(json_msg, ["user"]);
    close_session(user);
    
    logd("Closed dialog for " + (string)user);
    return TRUE;
}

/* ========================== Listen Event Handler ========================== */

integer handle_listen_response(integer channel, key speaker, string message) {
    // CHANGED: Ignore filler button clicks
    if (message == FILL_BUTTON) {
        return FALSE;
    }
    
    integer idx = 0;
    integer len = llGetListLength(ActiveSessions);
    key session_user = NULL_KEY;
    string session_context = "";
    string session_type = "";
    string session_meta = "";
    
    while (idx < len) {
        key user = llList2Key(ActiveSessions, idx + SESSION_USER);
        integer sess_channel = llList2Integer(ActiveSessions, idx + SESSION_CHANNEL);
        
        if (speaker == user && channel == sess_channel) {
            session_user = user;
            session_context = llList2String(ActiveSessions, idx + SESSION_CONTEXT);
            session_type = llList2String(ActiveSessions, idx + SESSION_TYPE);
            session_meta = llList2String(ActiveSessions, idx + SESSION_META);
            idx = len;
        } else {
            idx += SESSION_STRIDE;
        }
    }
    
    if (session_user == NULL_KEY) {
        logd("WARNING: Received response from unknown session");
        return FALSE;
    }
    
    // Handle multi-party responses
    if (session_type == "multiparty") {
        string request_id = llGetSubString(session_context, 11, -1);
        integer mp_idx = find_multiparty_by_id(request_id);
        
        if (mp_idx == -1) {
            llRegionSayTo(session_user, 0, "Confirmation request no longer valid.");
            close_session(session_user);
            return TRUE;
        }
        
        key initiator = llList2Key(MultiPartyRequests, mp_idx + MP_INITIATOR);
        string plugin_context = llList2String(MultiPartyRequests, mp_idx + MP_CONTEXT);
        string metadata = llList2String(MultiPartyRequests, mp_idx + MP_METADATA);
        
        if (message == "APPROVE") {
            add_multiparty_confirmation(request_id, session_user);
            llRegionSayTo(session_user, 0, "✓ You have approved this action.");
            close_session(session_user);
            
            if (is_multiparty_complete(request_id)) {
                string response_msg = llList2Json(JSON_OBJECT, [
                    "type", "dialog_response",
                    "context", plugin_context,
                    "button", "multiparty_approved",
                    "request_id", request_id,
                    "metadata", metadata
                ]);
                
                llMessageLinked(LINK_SET, K_DIALOG_RESPONSE, response_msg, initiator);
                
                string confirmed_json = llList2String(MultiPartyRequests, mp_idx + MP_CONFIRMED);
                list confirmed_list = json_array_to_list(confirmed_json);
                
                integer i = 0;
                while (i < llGetListLength(confirmed_list)) {
                    key confirmed_user = llList2Key(confirmed_list, i);
                    llRegionSayTo(confirmed_user, 0, "✓ Action approved by all parties.");
                    i += 1;
                }
                
                remove_multiparty_request(request_id);
            } else {
                string confirmed_json = llList2String(MultiPartyRequests, mp_idx + MP_CONFIRMED);
                string pending_json = llList2String(MultiPartyRequests, mp_idx + MP_PENDING);
                list confirmed_list = json_array_to_list(confirmed_json);
                list pending_list = json_array_to_list(pending_json);
                
                string status_msg = llList2Json(JSON_OBJECT, [
                    "type", "dialog_response",
                    "context", plugin_context,
                    "button", "multiparty_partial",
                    "request_id", request_id,
                    "confirmed_count", (string)llGetListLength(confirmed_list),
                    "required_count", (string)(llGetListLength(confirmed_list) + llGetListLength(pending_list))
                ]);
                
                llMessageLinked(LINK_SET, K_DIALOG_RESPONSE, status_msg, initiator);
                
                notify_pending_users(request_id);
            }
            
            return TRUE;
        }
        
        if (message == "DENY") {
            llRegionSayTo(session_user, 0, "✗ You have denied this action.");
            close_session(session_user);
            
            string response_msg = llList2Json(JSON_OBJECT, [
                "type", "dialog_response",
                "context", plugin_context,
                "button", "multiparty_denied",
                "request_id", request_id,
                "denied_by", (string)session_user,
                "metadata", metadata
            ]);
            
            llMessageLinked(LINK_SET, K_DIALOG_RESPONSE, response_msg, initiator);
            
            string pending_json = llList2String(MultiPartyRequests, mp_idx + MP_PENDING);
            string confirmed_json = llList2String(MultiPartyRequests, mp_idx + MP_CONFIRMED);
            list all_users = json_array_to_list(pending_json) + json_array_to_list(confirmed_json);
            
            string denier_name = llKey2Name(session_user);
            integer i = 0;
            while (i < llGetListLength(all_users)) {
                key notify_user = llList2Key(all_users, i);
                if (notify_user != session_user) {
                    llRegionSayTo(notify_user, 0, "✗ Action denied by " + denier_name);
                }
                i += 1;
            }
            
            remove_multiparty_request(request_id);
            return TRUE;
        }
    }
    
    // Handle single-user confirm
    if (session_type == "confirm") {
        string confirm_btn = llJsonGetValue(session_meta, ["confirm_button"]);
        string cancel_btn = llJsonGetValue(session_meta, ["cancel_button"]);
        string confirm_resp = llJsonGetValue(session_meta, ["confirm_response"]);
        string cancel_resp = llJsonGetValue(session_meta, ["cancel_response"]);
        
        string response_type = message;
        if (message == confirm_btn) {
            response_type = confirm_resp;
        }
        if (message == cancel_btn) {
            response_type = cancel_resp;
        }
        
        string response_msg = llList2Json(JSON_OBJECT, [
            "type", "dialog_response",
            "user", (string)session_user,
            "context", session_context,
            "button", message,
            "response", response_type
        ]);
        
        llMessageLinked(LINK_SET, K_DIALOG_RESPONSE, response_msg, session_user);
        logd("Confirm response: " + response_type);
        return TRUE;
    }
    
    // Standard dialog response
    string response_msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_response",
        "user", (string)session_user,
        "context", session_context,
        "button", message
    ]);
    
    llMessageLinked(LINK_SET, K_DIALOG_RESPONSE, response_msg, session_user);
    
    logd("Dialog response: user=" + (string)session_user + " context=" + session_context + " button=" + message);
    
    return TRUE;
}

/* ========================== Timer Management ========================== */

integer check_session_timeouts() {
    integer current_time = now();
    list expired_users = [];
    
    integer i = 0;
    integer len = llGetListLength(ActiveSessions);
    
    while (i < len) {
        integer expire_time = llList2Integer(ActiveSessions, i + SESSION_EXPIRE);
        
        if (current_time >= expire_time) {
            key user = llList2Key(ActiveSessions, i + SESSION_USER);
            expired_users += user;
        }
        
        i += SESSION_STRIDE;
    }
    
    integer exp_count = llGetListLength(expired_users);
    i = 0;
    while (i < exp_count) {
        key user = llList2Key(expired_users, i);
        string context = get_session_context(user);
        
        string timeout_msg = llList2Json(JSON_OBJECT, [
            "type", "dialog_timeout",
            "user", (string)user,
            "context", context
        ]);
        
        llMessageLinked(LINK_SET, K_DIALOG_TIMEOUT, timeout_msg, user);
        
        close_session(user);
        
        logd("Dialog timeout for user " + (string)user);
        i += 1;
    }
    
    if (llGetListLength(ActiveSessions) == 0 && llGetListLength(MultiPartyRequests) == 0) {
        llSetTimerEvent(0.0);
        logd("All sessions expired, timer stopped");
    }
    
    return TRUE;
}

integer check_multiparty_timeouts() {
    integer current_time = now();
    list expired_requests = [];
    
    integer i = 0;
    integer len = llGetListLength(MultiPartyRequests);
    
    while (i < len) {
        integer timeout_epoch = llList2Integer(MultiPartyRequests, i + MP_TIMEOUT);
        
        if (current_time >= timeout_epoch) {
            string request_id = llList2String(MultiPartyRequests, i + MP_ID);
            expired_requests += [request_id];
        }
        
        i += MULTIPARTY_STRIDE;
    }
    
    integer exp_count = llGetListLength(expired_requests);
    i = 0;
    while (i < exp_count) {
        string request_id = llList2String(expired_requests, i);
        integer idx = find_multiparty_by_id(request_id);
        
        if (idx != -1) {
            key initiator = llList2Key(MultiPartyRequests, idx + MP_INITIATOR);
            string context = llList2String(MultiPartyRequests, idx + MP_CONTEXT);
            string metadata = llList2String(MultiPartyRequests, idx + MP_METADATA);
            
            string response_msg = llList2Json(JSON_OBJECT, [
                "type", "dialog_response",
                "context", context,
                "button", "multiparty_timeout",
                "request_id", request_id,
                "metadata", metadata
            ]);
            
            llMessageLinked(LINK_SET, K_DIALOG_RESPONSE, response_msg, initiator);
            
            string pending_json = llList2String(MultiPartyRequests, idx + MP_PENDING);
            string confirmed_json = llList2String(MultiPartyRequests, idx + MP_CONFIRMED);
            list all_users = json_array_to_list(pending_json) + json_array_to_list(confirmed_json);
            
            integer j = 0;
            while (j < llGetListLength(all_users)) {
                key notify_user = llList2Key(all_users, j);
                llRegionSayTo(notify_user, 0, "⏱ Confirmation request timed out.");
                j += 1;
            }
            
            remove_multiparty_request(request_id);
        }
        
        i += 1;
    }
    
    return TRUE;
}

integer send_multiparty_reminders() {
    integer i = 0;
    integer len = llGetListLength(MultiPartyRequests);
    
    while (i < len) {
        string request_id = llList2String(MultiPartyRequests, i + MP_ID);
        notify_pending_users(request_id);
        i += MULTIPARTY_STRIDE;
    }
    
    return TRUE;
}

/* ========================== Main Events ========================== */

default {
    state_entry() {
        logd("Dialog kernel initialized");
        close_all_sessions();
        MultiPartyRequests = [];
        NextRequestId = 1;
        ReminderTimer = 0;
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    touch_start(integer num_detected) {
        key toucher = llDetectedKey(0);
        integer idx = find_multiparty_by_user(toucher);
        
        if (idx != -1) {
            string request_id = llList2String(MultiPartyRequests, idx + MP_ID);
            show_multiparty_dialog(toucher, request_id);
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (num == K_DIALOG_OPEN) {
            handle_dialog_open(msg, id);
            return;
        }
        
        if (num == K_DIALOG_CONFIRM) {
            handle_dialog_confirm(msg, id);
            return;
        }
        
        if (num == K_DIALOG_CLOSE) {
            handle_dialog_close(msg);
            return;
        }
    }
    
    listen(integer channel, string name, key speaker, string message) {
        handle_listen_response(channel, speaker, message);
    }
    
    timer() {
        check_session_timeouts();
        check_multiparty_timeouts();
        
        if (ReminderTimer) {
            send_multiparty_reminders();
        }
    }
    
    changed(integer change_mask) {
        if (change_mask & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
