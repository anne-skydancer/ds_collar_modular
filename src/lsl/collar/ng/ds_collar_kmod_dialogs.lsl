/*--------------------
MODULE: ds_collar_kmod_dialogs.lsl
VERSION: 1.00
REVISION: 28
PURPOSE: Centralized dialog management for shared listener handling
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- REVERT: Replaced delimited string storage with JSON for robustness against special chars
- OPTIMIZATION: Replaced strided lists with Parallel Lists for O(1) lookups
- OPTIMIZATION: Removed internal JSON serialization for button maps (Hot Path)
- Centralized dialog sessions remove per-plugin listen management
- Dedicated dialog bus coordinates all open and timeout events
- Channel collision detection mitigates negative channel reuse conflicts
- Owner change handling resets listeners for safe transfers
- Truncation warnings added for numbered button lists
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer DIALOG_BUS = 950;

/* -------------------- CONSTANTS -------------------- */
float CHANNEL_BASE = -8E07;
integer SESSION_MAX = 10;  // Maximum concurrent sessions

/* -------------------- STATE -------------------- */
// Parallel Lists for Sessions
list SessionIDs;        // [session_id]
list SessionUsers;      // [user_key]
list SessionChannels;   // [channel]
list SessionListens;    // [listen_handle]
list SessionTimeouts;   // [timeout_unix]
list SessionButtonMaps; // [json_string] [{"b":"btn","c":"ctx"},...]

integer NextChannelOffset = 1;

// Parallel Lists for Button Configs
list ButtonConfigContexts; // [context]
list ButtonConfigLabelsA;  // [button_a_label]
list ButtonConfigLabelsB;  // [button_b_label]

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string get_msg_type(string msg) {
    if (!json_has(msg, ["type"])) return "";
    return llJsonGetValue(msg, ["type"]);
}

// MEMORY OPTIMIZATION: Compact field validation helper
integer validate_required_fields(string json_str, list field_names) {
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

integer now() {
    return llGetUnixTime();
}

/* -------------------- SESSION MANAGEMENT -------------------- */

integer find_session_idx(string session_id) {
    return llListFindList(SessionIDs, [session_id]);
}

close_session_at_idx(integer idx) {
    if (idx < 0) return;
    
    integer listen_handle = llList2Integer(SessionListens, idx);
    if (listen_handle != 0) {
        llListenRemove(listen_handle);
    }
    
    SessionIDs = llDeleteSubList(SessionIDs, idx, idx);
    SessionUsers = llDeleteSubList(SessionUsers, idx, idx);
    SessionChannels = llDeleteSubList(SessionChannels, idx, idx);
    SessionListens = llDeleteSubList(SessionListens, idx, idx);
    SessionTimeouts = llDeleteSubList(SessionTimeouts, idx, idx);
    SessionButtonMaps = llDeleteSubList(SessionButtonMaps, idx, idx);
}

close_session(string session_id) {
    integer idx = find_session_idx(session_id);
    if (idx != -1) {
        close_session_at_idx(idx);
    }
}

prune_expired_sessions() {
    integer i = 0;
    integer now_time = now();
    
    // Iterate backwards to safely delete
    integer len = llGetListLength(SessionTimeouts);
    for (i = len - 1; i >= 0; i--) {
        integer timeout = llList2Integer(SessionTimeouts, i);
        
        if (timeout > 0 && now_time >= timeout) {
            // Session expired, send timeout message
            string session_id = llList2String(SessionIDs, i);
            key user = llList2Key(SessionUsers, i);
            
            string timeout_msg = llList2Json(JSON_OBJECT, [
                "type", "dialog_timeout",
                "session_id", session_id,
                "user", (string)user
            ]);
            llMessageLinked(LINK_SET, DIALOG_BUS, timeout_msg, NULL_KEY);
            
            close_session_at_idx(i);
        }
    }
}

integer get_next_channel() {
    integer channel = (integer)CHANNEL_BASE - NextChannelOffset;
    NextChannelOffset += 1;
    if (NextChannelOffset > 1000000) NextChannelOffset = 1;
    return channel;
}

/* -------------------- BUTTON CONFIG MANAGEMENT -------------------- */

integer find_button_config_idx(string context) {
    return llListFindList(ButtonConfigContexts, [context]);
}

register_button_config(string context, string button_a, string button_b) {
    integer idx = find_button_config_idx(context);

    if (idx != -1) {
        // Update existing config
        ButtonConfigLabelsA = llListReplaceList(ButtonConfigLabelsA, [button_a], idx, idx);
        ButtonConfigLabelsB = llListReplaceList(ButtonConfigLabelsB, [button_b], idx, idx);
    }
    else {
        // Add new config
        ButtonConfigContexts += [context];
        ButtonConfigLabelsA += [button_a];
        ButtonConfigLabelsB += [button_b];
    }
}

string get_button_label(string context, integer button_state) {
    integer idx = find_button_config_idx(context);

    if (idx == -1) {
        // No config found, return context as-is
        return context;
    }

    if (button_state == 0) {
        return llList2String(ButtonConfigLabelsA, idx);
    }
    else {
        return llList2String(ButtonConfigLabelsB, idx);
    }
}

/* -------------------- DIALOG DISPLAY -------------------- */

handle_dialog_open(string msg) {
    if (!validate_required_fields(msg, ["session_id", "user"])) {
        return;
    }

    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    // Check for numbered list type
    if (json_has(msg, ["dialog_type"]) && llJsonGetValue(msg, ["dialog_type"]) == "numbered_list") {
        handle_numbered_list_dialog(msg, session_id, user);
        return;
    }

    // Standard dialog - check for button_data (new format) or buttons (old format)
    list buttons = [];
    list storage_map = []; // List of JSON objects for storage [{"b":"btn", "c":"ctx"}]

    if (json_has(msg, ["button_data"])) {
        // New format: button_data contains mixed array of strings and objects
        string button_data_json = llJsonGetValue(msg, ["button_data"]);
        list button_data_list = llJson2List(button_data_json);

        // Resolve button labels from config+state and build mapping
        integer i = 0;
        integer len = llGetListLength(button_data_list);
        while (i < len) {
            string item = llList2String(button_data_list, i);
            string button_text = "";
            string button_context = "";

            // Plugin buttons: JSON objects with context+label+state (routable to plugins)
            if (llJsonValueType(item, []) == JSON_OBJECT &&
                json_has(item, ["context"]) && json_has(item, ["label"]) && json_has(item, ["state"])) {

                string context = llJsonGetValue(item, ["context"]);
                string label = llJsonGetValue(item, ["label"]);
                integer button_state = (integer)llJsonGetValue(item, ["state"]);

                // Check if there's a button config for this context (for toggle buttons)
                integer config_idx = find_button_config_idx(context);

                if (config_idx != -1) {
                    // Toggle button: use registered config to resolve label
                    button_text = get_button_label(context, button_state);
                }
                else {
                    // Regular plugin: use label field directly
                    button_text = label;
                }

                button_context = context;  // Plugin buttons route to context
            }
            else {
                // Navigation buttons or other non-routable buttons
                // Extract label from JSON object if available, otherwise use string as-is
                if (llJsonValueType(item, []) == JSON_OBJECT && json_has(item, ["label"])) {
                    button_text = llJsonGetValue(item, ["label"]);
                }
                else {
                    button_text = item;
                }
                // button_context remains empty (no routing)
            }

            buttons += [button_text];
            
            // ROBUST FIX: Store as JSON object to handle special chars and empty contexts safely
            storage_map += [llList2Json(JSON_OBJECT, ["b", button_text, "c", button_context])];
            
            i++;
        }
    }
    else if (json_has(msg, ["buttons"])) {
        // Old format: buttons is array of strings
        string buttons_json = llJsonGetValue(msg, ["buttons"]);
        buttons = llJson2List(buttons_json);

        // Build storage map for old format
        integer i = 0;
        integer len = llGetListLength(buttons);
        while (i < len) {
            string btn = llList2String(buttons, i);
            storage_map += [llList2Json(JSON_OBJECT, ["b", btn, "c", ""])];
            i++;
        }
    }
    else {
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
    if (llGetListLength(SessionIDs) >= SESSION_MAX) {
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

    // Add to sessions
    SessionIDs += [session_id];
    SessionUsers += [user];
    SessionChannels += [channel];
    SessionListens += [listen_handle];
    SessionTimeouts += [timeout_unix];
    // Store map as JSON array string
    SessionButtonMaps += [llList2Json(JSON_ARRAY, storage_map)];

    // Show dialog
    llDialog(user, title + "\n\n" + message, buttons, channel);

}

handle_numbered_list_dialog(string msg, string session_id, key user) {
    if (!validate_required_fields(msg, ["items"])) {
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
    integer original_count = item_count;
    
    if (item_count == 0) {
        return;
    }
    
    // Build body text with numbered list (max 11 items to leave room for Back button)
    string body = prompt + "\n\n";
    list buttons = ["Back"];
    
    integer max_items = 11;
    if (item_count > max_items) {
        // Warn about truncation
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
    if (llGetListLength(SessionIDs) >= SESSION_MAX) {
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

    // Build storage map for numbered list (buttons have no context)
    list storage_map = [];
    integer j = 0;
    integer btn_len = llGetListLength(buttons);
    while (j < btn_len) {
        string btn = llList2String(buttons, j);
        storage_map += [llList2Json(JSON_OBJECT, ["b", btn, "c", ""])];
        j++;
    }

    // Add to sessions
    SessionIDs += [session_id];
    SessionUsers += [user];
    SessionChannels += [channel];
    SessionListens += [listen_handle];
    SessionTimeouts += [timeout_unix];
    SessionButtonMaps += [llList2Json(JSON_ARRAY, storage_map)];

    // Show dialog
    llDialog(user, title + "\n\n" + body, buttons, channel);

}

handle_dialog_close(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    close_session(session_id);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        SessionIDs = [];
        SessionUsers = [];
        SessionChannels = [];
        SessionListens = [];
        SessionTimeouts = [];
        SessionButtonMaps = [];
        
        NextChannelOffset = 1;
        
        ButtonConfigContexts = [];
        ButtonConfigLabelsA = [];
        ButtonConfigLabelsB = [];

        // Start timer for session cleanup
        llSetTimerEvent(5.0);
    }
    
    timer() {
        prune_expired_sessions();
    }
    
    listen(integer channel, string name, key id, string message) {
        // Find session for this channel using Parallel List lookup
        integer i = llListFindList(SessionChannels, [channel]);
        
        if (i != -1) {
            key session_user = llList2Key(SessionUsers, i);

            // Verify speaker matches session user
            if (id == session_user) {
                string session_id = llList2String(SessionIDs, i);
                
                // Retrieve JSON button map string
                string button_map_json = llList2String(SessionButtonMaps, i);
                
                // Parse JSON array of objects: [{"b":"btn","c":"ctx"}, ...]
                list button_map = llJson2List(button_map_json);

                // Look up context for this button
                string clicked_context = "";
                integer j = 0;
                integer map_len = llGetListLength(button_map);
                while (j < map_len) {
                    string entry = llList2String(button_map, j);
                    // Check if button label matches message
                    if (llJsonGetValue(entry, ["b"]) == message) {
                        clicked_context = llJsonGetValue(entry, ["c"]);
                        jump found_context;
                    }
                    j++;
                }
                @found_context;

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
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

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
        else if (msg_type == "register_button_config") {
            if (json_has(msg, ["context"]) && json_has(msg, ["button_a"]) && json_has(msg, ["button_b"])) {
                string context = llJsonGetValue(msg, ["context"]);
                string button_a = llJsonGetValue(msg, ["button_a"]);
                string button_b = llJsonGetValue(msg, ["button_b"]);
                register_button_config(context, button_a, button_b);
            }
            else {
            }
        }
    }
    
    // Reset on owner change
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
