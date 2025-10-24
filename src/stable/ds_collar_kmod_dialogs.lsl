/* =============================================================================
   MODULE: ds_collar_kmod_dialogs.lsl (v2.0 - Consolidated ABI)
   
   ROLE: Centralized dialog management - eliminates per-plugin listen handles
   
   CHANNELS:
   - 950 (DIALOG_BUS): All dialog operations
   
   BENEFIT: Plugins don't need to manage their own listen handles or channels
   ============================================================================= */

integer DEBUG = TRUE;

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer DIALOG_BUS = 950;

/* ═══════════════════════════════════════════════════════════
   CONSTANTS
   ═══════════════════════════════════════════════════════════ */
integer CHANNEL_BASE = -8000000;
integer SESSION_MAX = 10;  // Maximum concurrent sessions

/* Session list stride: [session_id, user_key, channel, listen_handle, timeout_unix] */
integer SESSION_STRIDE = 5;
integer SESSION_ID = 0;
integer SESSION_USER = 1;
integer SESSION_CHANNEL = 2;
integer SESSION_LISTEN = 3;
integer SESSION_TIMEOUT = 30;

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
list Sessions = [];
integer NextChannelOffset = 1;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[DIALOGS] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer now() {
    return llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   SESSION MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

integer find_session_idx(string session_id) {
    integer i = 0;
    integer len = llGetListLength(Sessions);
    while (i < len) {
        if (llList2String(Sessions, i + SESSION_ID) == session_id) {
            return i;
        }
        i += SESSION_STRIDE;
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
    logd("Closed session: " + session_id);
    
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
            
            logd("Session timeout: " + session_id);
            
            close_session_at_idx(i);
            // Don't increment i, list shifted
        }
        else {
            i += SESSION_STRIDE;
        }
    }
}

integer get_next_channel() {
    integer channel = CHANNEL_BASE - NextChannelOffset;
    NextChannelOffset += 1;
    if (NextChannelOffset > 1000000) NextChannelOffset = 1;
    return channel;
}

/* ═══════════════════════════════════════════════════════════
   DIALOG DISPLAY
   ═══════════════════════════════════════════════════════════ */

handle_dialog_open(string msg) {
    if (!json_has(msg, ["session_id"])) {
        logd("ERROR: dialog_open missing session_id");
        return;
    }
    if (!json_has(msg, ["user"])) {
        logd("ERROR: dialog_open missing user");
        return;
    }
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);
    
    // Check for numbered list type
    if (json_has(msg, ["dialog_type"]) && llJsonGetValue(msg, ["dialog_type"]) == "numbered_list") {
        handle_numbered_list_dialog(msg, session_id, user);
        return;
    }
    
    // Standard dialog
    if (!json_has(msg, ["buttons"])) {
        logd("ERROR: dialog_open missing buttons");
        return;
    }
    
    string title = "Menu";
    string message = "Select an option:";
    integer timeout = 60;
    
    if (json_has(msg, ["title"])) {
        title = llJsonGetValue(msg, ["title"]);
    }
    if (json_has(msg, ["body"])) {
        message = llJsonGetValue(msg, ["body"]);
    }
    else if (json_has(msg, ["message"])) {
        message = llJsonGetValue(msg, ["message"]);
    }
    if (json_has(msg, ["timeout"])) {
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
        logd("Session limit reached, closed oldest");
    }
    
    // Get channel and create listen
    integer channel = get_next_channel();
    integer listen_handle = llListen(channel, "", user, "");
    
    // Calculate timeout timestamp
    integer timeout_unix = 0;
    if (timeout > 0) {
        timeout_unix = now() + timeout;
    }
    
    // Add to sessions
    Sessions += [session_id, user, channel, listen_handle, timeout_unix];
    
    // Parse buttons
    string buttons_json = llJsonGetValue(msg, ["buttons"]);
    list buttons = llJson2List(buttons_json);
    
    // Show dialog
    llDialog(user, title + "\n\n" + message, buttons, channel);
    
    logd("Opened dialog: " + session_id + " for " + llKey2Name(user) + " on channel " + (string)channel);
}

handle_numbered_list_dialog(string msg, string session_id, key user) {
    if (!json_has(msg, ["items"])) {
        logd("ERROR: numbered_list missing items");
        return;
    }
    
    string title = "Select Item";
    string prompt = "Choose:";
    integer timeout = 60;
    
    if (json_has(msg, ["title"])) {
        title = llJsonGetValue(msg, ["title"]);
    }
    if (json_has(msg, ["prompt"])) {
        prompt = llJsonGetValue(msg, ["prompt"]);
    }
    if (json_has(msg, ["timeout"])) {
        timeout = (integer)llJsonGetValue(msg, ["timeout"]);
    }
    
    // Parse items
    string items_json = llJsonGetValue(msg, ["items"]);
    list items = llJson2List(items_json);
    integer item_count = llGetListLength(items);
    
    if (item_count == 0) {
        logd("ERROR: numbered_list has no items");
        return;
    }
    
    // Build body text with numbered list (max 11 items to leave room for Back button)
    string body = prompt + "\n\n";
    list buttons = ["Back"];
    
    integer max_items = 11;
    if (item_count > max_items) item_count = max_items;
    
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
        logd("Session limit reached, closed oldest");
    }
    
    // Get channel and create listen
    integer channel = get_next_channel();
    integer listen_handle = llListen(channel, "", user, "");
    
    // Calculate timeout timestamp
    integer timeout_unix = 0;
    if (timeout > 0) {
        timeout_unix = now() + timeout;
    }
    
    // Add to sessions
    Sessions += [session_id, user, channel, listen_handle, timeout_unix];
    
    // Show dialog
    llDialog(user, title + "\n\n" + body, buttons, channel);
    
    logd("Opened numbered list: " + session_id + " (" + (string)item_count + " items)");
}

handle_dialog_close(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    close_session(session_id);
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default
{
    state_entry() {
        Sessions = [];
        NextChannelOffset = 1;
        
        logd("Dialog manager started");
        
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
                if (id != session_user) {
                    i += SESSION_STRIDE;
                    jump next_session;
                }
                
                string session_id = llList2String(Sessions, i + SESSION_ID);
                
                // Send response message
                string response = llList2Json(JSON_OBJECT, [
                    "type", "dialog_response",
                    "session_id", session_id,
                    "user", (string)id,
                    "button", message
                ]);
                llMessageLinked(LINK_SET, DIALOG_BUS, response, NULL_KEY);
                
                logd("Button click: " + message + " from " + llKey2Name(id));
                
                // Close session after response
                close_session_at_idx(i);
                return;
            }
            
            @next_session;
            i += SESSION_STRIDE;
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (num != DIALOG_BUS) return;
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type == "dialog_open") {
            handle_dialog_open(msg);
        }
        else if (msg_type == "dialog_close") {
            handle_dialog_close(msg);
        }
    }
}
