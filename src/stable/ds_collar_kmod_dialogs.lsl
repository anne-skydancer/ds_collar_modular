/*--------------------
MODULE: ds_collar_kmod_dialogs.lsl
VERSION: 1.00
REVISION: 24
PURPOSE: Centralized dialog management for shared listener handling
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- ARCHITECTURE CHANGE: Split button map into parallel arrays for O(1) lookup
- Optimized listen handler to use native llListFindList instead of loops
- Updated handle_dialog_open to accept pre-split button/context arrays
- Removed complex JSON parsing logic
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer DIALOG_BUS = 950;

/* -------------------- CONSTANTS -------------------- */
integer SESSION_MAX = 10;  // Maximum concurrent sessions

/* Session list stride: [session_id, user_key, channel, listen_handle, timeout_unix, buttons_json, contexts_json] */
integer SESSION_STRIDE = 7;
integer SESSION_ID = 0;
integer SESSION_USER = 1;
integer SESSION_CHANNEL = 2;
integer SESSION_LISTEN = 3;
integer SESSION_TIMEOUT = 4;
integer SESSION_BUTTONS = 5;   // JSON array of button labels
integer SESSION_CONTEXTS = 6;  // JSON array of contexts

/* -------------------- STATE -------------------- */
list Sessions = [];
integer NextChannelOffset = 1;

/* -------------------- HELPERS -------------------- */

integer now() {
    return llGetUnixTime();
}

/* -------------------- SESSION MANAGEMENT -------------------- */

integer find_session_idx(string session_id) {
    integer idx = llListFindList(Sessions, [session_id]);
    if (idx != -1 && (idx % SESSION_STRIDE) == SESSION_ID) {
        return idx;
    }
    return -1;
}

close_session_at_idx(integer idx) {
    if (idx < 0) return;
    
    integer listen_handle = llList2Integer(Sessions, idx + SESSION_LISTEN);
    if (listen_handle != 0) {
        llListenRemove(listen_handle);
    }
    
    string session_id = llList2String(Sessions, idx + SESSION_ID);
    
    Sessions = llDeleteSubList(Sessions, idx, idx + SESSION_STRIDE - 1);
}

close_session(string session_id) {
    integer idx = find_session_idx(session_id);
    if (idx != -1) {
        close_session_at_idx(idx);
    }
}

prune_expired_sessions() {
    integer now_unix = now();
    integer i = 0;
    
    while (i < llGetListLength(Sessions)) {
        integer timeout = llList2Integer(Sessions, i + SESSION_TIMEOUT);
        
        if (timeout > 0 && now_unix >= timeout) {
            // Session expired, send timeout message
            string session_id = llList2String(Sessions, i + SESSION_ID);
            key user = llList2Key(Sessions, i + SESSION_USER);
            
            string timeout_msg = llList2Json(JSON_OBJECT, [
                "type", "dialog_timeout",
                "session_id", session_id,
                "user", (string)user
            ]);
            llMessageLinked(LINK_SET, DIALOG_BUS, timeout_msg, NULL_KEY);
            
            close_session_at_idx(i);
            // Don't increment i, list shifted
        }
        else {
            i += SESSION_STRIDE;
        }
    }
}

// SECURITY FIX: Check if channel is already in use
integer is_channel_in_use(integer channel) {
    integer i = 0;
    while (i < llGetListLength(Sessions)) {
        if (llList2Integer(Sessions, i + SESSION_CHANNEL) == channel) {
            return TRUE;
        }
        i += SESSION_STRIDE;
    }
    return FALSE;
}

integer get_next_channel() {
    // Use large negative range (-1 to -2 billion)
    // Collision probability is extremely low, O(1) operation
    return -1 - (integer)llFrand(2.0E09);
}

/* -------------------- DIALOG DISPLAY -------------------- */

handle_dialog_open(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["user"]) == JSON_INVALID) {
        return;
    }

    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    // Check for numbered list type
    if (llJsonGetValue(msg, ["dialog_type"]) == "numbered_list") {
        handle_numbered_list_dialog(msg, session_id, user);
        return;
    }

    // Standard dialog - optimized for parallel arrays
    list buttons = [];
    string buttons_json = "[]";
    string contexts_json = "[]";

    if (llJsonGetValue(msg, ["buttons"]) != JSON_INVALID && llJsonGetValue(msg, ["contexts"]) != JSON_INVALID) {
        // New optimized format: pre-split arrays
        buttons_json = llJsonGetValue(msg, ["buttons"]);
        contexts_json = llJsonGetValue(msg, ["contexts"]);
        buttons = llJson2List(buttons_json);
    }
    else if (llJsonGetValue(msg, ["button_data"]) != JSON_INVALID) {
        // Legacy format support (fallback)
        string button_data_json = llJsonGetValue(msg, ["button_data"]);
        list button_data_list = llJson2List(button_data_json);
        list contexts = [];
        
        integer i = 0;
        integer len = llGetListLength(button_data_list);
        while (i < len) {
            string item = llList2String(button_data_list, i);
            if (llGetSubString(item, 0, 0) == "{" && 
                llJsonValueType(item, []) == JSON_OBJECT &&
                llJsonGetValue(item, ["context"]) != JSON_INVALID && llJsonGetValue(item, ["label"]) != JSON_INVALID) {
                
                buttons += [llJsonGetValue(item, ["label"])];
                contexts += [llJsonGetValue(item, ["context"])];
            }
            else {
                buttons += [item];
                contexts += [""];
            }
            i++;
        }
        buttons_json = llList2Json(JSON_ARRAY, buttons);
        contexts_json = llList2Json(JSON_ARRAY, contexts);
    }
    else {
        return;
    }

    string title = "Menu";
    string message = "Select an option:";
    integer timeout = 60;

    if (llJsonGetValue(msg, ["title"]) != JSON_INVALID) {
        title = llJsonGetValue(msg, ["title"]);
    }
    if (llJsonGetValue(msg, ["body"]) != JSON_INVALID) {
        message = llJsonGetValue(msg, ["body"]);
    }
    else if (llJsonGetValue(msg, ["message"]) != JSON_INVALID) {
        message = llJsonGetValue(msg, ["message"]);
    }
    if (llJsonGetValue(msg, ["timeout"]) != JSON_INVALID) {
        timeout = (integer)llJsonGetValue(msg, ["timeout"]);
    }

    // Close existing session with same ID
    integer existing_idx = find_session_idx(session_id);
    if (existing_idx != -1) {
        close_session_at_idx(existing_idx);
    }

    // Enforce session limit
    if (llGetListLength(Sessions) / SESSION_STRIDE >= SESSION_MAX) {
        // Close oldest session
        close_session_at_idx(0);
    }

    // Get channel and create listen
    integer channel = get_next_channel();
    integer listen_handle = llListen(channel, "", user, "");

    // Calculate timeout timestamp
    integer timeout_unix = 0;
    if (timeout > 0) {
        timeout_unix = now() + timeout;
    }

    // Add to sessions (store parallel JSON arrays)
    Sessions += [session_id, user, channel, listen_handle, timeout_unix, buttons_json, contexts_json];

    // Show dialog
    llDialog(user, title + "\n\n" + message, buttons, channel);

}

handle_numbered_list_dialog(string msg, string session_id, key user) {
    if (llJsonGetValue(msg, ["items"]) == JSON_INVALID) {
        return;
    }
    
    string title = "Select Item";
    string prompt = "Choose:";
    integer timeout = 60;
    
    if (llJsonGetValue(msg, ["title"]) != JSON_INVALID) {
        title = llJsonGetValue(msg, ["title"]);
    }
    if (llJsonGetValue(msg, ["prompt"]) != JSON_INVALID) {
        prompt = llJsonGetValue(msg, ["prompt"]);
    }
    if (llJsonGetValue(msg, ["timeout"]) != JSON_INVALID) {
        timeout = (integer)llJsonGetValue(msg, ["timeout"]);
    }
    
    // Parse items
    string items_json = llJsonGetValue(msg, ["items"]);
    list items = llJson2List(items_json);
    integer item_count = llGetListLength(items);
    integer original_count = item_count;
    
    if (item_count == 0) {
        return;
    }
    
    // Build body text with numbered list (max 11 items to leave room for Back button)
    string body = prompt + "\n\n";
    list buttons = ["Back"];
    
    integer max_items = 11;
    if (item_count > max_items) {
        // SECURITY FIX: Warn about truncation
        llOwnerSay("WARNING: Item list truncated to " + (string)max_items + " items (had " + (string)original_count + ")");
        item_count = max_items;
    }
    
    integer i = 0;
    while (i < item_count) {
        string item = llList2String(items, i);
        body += (string)(i + 1) + ". " + item + "\n";
        buttons += [(string)(i + 1)];
        i += 1;
    }
    
    // Close existing session with same ID
    integer existing_idx = find_session_idx(session_id);
    if (existing_idx != -1) {
        close_session_at_idx(existing_idx);
    }
    
    // Enforce session limit
    if (llGetListLength(Sessions) / SESSION_STRIDE >= SESSION_MAX) {
        close_session_at_idx(0);
    }
    
    // Get channel and create listen
    integer channel = get_next_channel();
    integer listen_handle = llListen(channel, "", user, "");
    
    // Calculate timeout timestamp
    integer timeout_unix = 0;
    if (timeout > 0) {
        timeout_unix = now() + timeout;
    }

    // Build button_map for numbered list (buttons have no context)
    // OPTIMIZATION: Store as parallel arrays
    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    
    // Create empty contexts list of same length
    list contexts = [];
    integer j = 0;
    while (j < llGetListLength(buttons)) {
        contexts += [""];
        j++;
    }
    string contexts_json = llList2Json(JSON_ARRAY, contexts);

    // Add to sessions (store parallel JSON arrays)
    Sessions += [session_id, user, channel, listen_handle, timeout_unix, buttons_json, contexts_json];

    // Show dialog
    llDialog(user, title + "\n\n" + body, buttons, channel);

}

handle_dialog_close(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    close_session(session_id);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        Sessions = [];
        NextChannelOffset = 1;

        // Start timer for session cleanup
        llSetTimerEvent(5.0);
    }
    
    timer() {
        prune_expired_sessions();
    }
    
    listen(integer channel, string name, key id, string message) {
        // Find session for this channel
        integer i = 0;
        integer len = llGetListLength(Sessions);
        
        while (i < len) {
            integer session_channel = llList2Integer(Sessions, i + SESSION_CHANNEL);

            if (session_channel == channel) {
                key session_user = llList2Key(Sessions, i + SESSION_USER);

                // Verify speaker matches session user
                if (id == session_user) {
                    string session_id = llList2String(Sessions, i + SESSION_ID);
                    
                    // Deserialize parallel arrays
                    string buttons_json = llList2String(Sessions, i + SESSION_BUTTONS);
                    string contexts_json = llList2String(Sessions, i + SESSION_CONTEXTS);
                    list buttons = llJson2List(buttons_json);
                    list contexts = llJson2List(contexts_json);

                    // OPTIMIZATION: Native list search instead of loop
                    integer btn_idx = llListFindList(buttons, [message]);
                    string clicked_context = "";
                    
                    if (btn_idx != -1) {
                        clicked_context = llList2String(contexts, btn_idx);
                    }

                    // Send response message with context
                    string response = llList2Json(JSON_OBJECT, [
                        "type", "dialog_response",
                        "session_id", session_id,
                        "user", (string)id,
                        "button", message,
                        "context", clicked_context
                    ]);
                    llMessageLinked(LINK_SET, DIALOG_BUS, response, NULL_KEY);


                    // Close session after response
                    close_session_at_idx(i);
                    return;
                }
            }

            i += SESSION_STRIDE;
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (llJsonGetValue(msg, ["type"]) == JSON_INVALID) return;
        string msg_type = llJsonGetValue(msg, ["type"]);

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                llResetScript();
            }
            return;
        }

        /* -------------------- DIALOG BUS -------------------- */
        if (num != DIALOG_BUS) return;

        if (msg_type == "dialog_open") {
            handle_dialog_open(msg);
        }
        else if (msg_type == "dialog_close") {
            handle_dialog_close(msg);
        }
    }
    
    // SECURITY FIX: Reset on owner change
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
