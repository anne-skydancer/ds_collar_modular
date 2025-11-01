/* =============================================================================
   MODULE: ds_collar_kmod_dialogs.lsl (v3.0 - Kanban Messaging Migration)
   SECURITY AUDIT: MINOR ENHANCEMENTS APPLIED
   MESSAGING: Kanban universal helper (v1.0)

   ROLE: Centralized dialog management - eliminates per-plugin listen handles

   CHANNELS:
   - 950 (DIALOG_BUS): All dialog operations

   BENEFIT: Plugins don't need to manage their own listen handles or channels

   SECURITY ENHANCEMENTS:
   - [MEDIUM] Channel collision detection
   - [LOW] Production mode guard for debug
   - [LOW] Owner change handler
   - [LOW] Truncation warning for numbered lists

   KANBAN MIGRATION (v3.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "dialogs";

/* ═══════════════════════════════════════════════════════════
   KANBAN UNIVERSAL HELPER (~500-800 bytes)
   ═══════════════════════════════════════════════════════════ */

string kFrom = "";  // Sender context (populated by kRecv)
string kTo = "";    // Recipient context (populated by kRecv)

kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, [
            "from", from,
            "payload", payload,
            "to", to
        ]),
        k
    );
}

string kRecv(string msg, string my_context) {
    // Quick validation: must be JSON object
    if (llGetSubString(msg, 0, 0) != "{") return "";

    // Extract from
    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    // Extract to
    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast "" or direct to my_context)
    if (to != "" && to != my_context) return "";

    // Extract payload
    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    // Set globals for routing
    kFrom = from;
    kTo = to;

    return payload;
}

string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

string kDeltaSet(string setting_key, string val) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", setting_key,
        "value", val
    ]);
}

string kDeltaAdd(string setting_key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_add",
        "key", setting_key,
        "elem", elem
    ]);
}

string kDeltaDel(string setting_key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_remove",
        "key", setting_key,
        "elem", elem
    ]);
}

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
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
integer SESSION_TIMEOUT = 4;

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
list Sessions = [];
integer NextChannelOffset = 1;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    // SECURITY FIX: Production mode guard
    if (DEBUG && !PRODUCTION) llOwnerSay("[DIALOGS] " + msg);
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

            string payload = kPayload([
                "session_id", session_id,
                "user", (string)user,
                "timeout", 1
            ]);
            kSend(CONTEXT, "", DIALOG_BUS, payload, NULL_KEY);

            logd("Session timeout: " + session_id);

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
    // SECURITY FIX: Try up to 100 times to find unused channel
    integer attempts = 0;
    integer channel;
    
    while (attempts < 100) {
        channel = CHANNEL_BASE - NextChannelOffset;
        NextChannelOffset += 1;
        if (NextChannelOffset > 1000000) NextChannelOffset = 1;
        
        if (!is_channel_in_use(channel)) {
            return channel;
        }
        
        attempts += 1;
    }
    
    // Fallback: use random channel (collision still possible but very unlikely)
    logd("WARNING: Could not find unused channel after 100 attempts, using random");
    return CHANNEL_BASE - (integer)llFrand(1000000);
}

/* ═══════════════════════════════════════════════════════════
   DIALOG DISPLAY
   ═══════════════════════════════════════════════════════════ */

handle_dialog_open(string payload) {
    if (!json_has(payload, ["session_id"])) {
        logd("ERROR: dialog_open missing session_id");
        return;
    }
    if (!json_has(payload, ["user"])) {
        logd("ERROR: dialog_open missing user");
        return;
    }

    string session_id = llJsonGetValue(payload, ["session_id"]);
    key user = (key)llJsonGetValue(payload, ["user"]);

    // Check for numbered list type
    if (json_has(payload, ["dialog_type"]) && llJsonGetValue(payload, ["dialog_type"]) == "numbered_list") {
        handle_numbered_list_dialog(payload, session_id, user);
        return;
    }

    // Standard dialog
    if (!json_has(payload, ["buttons"])) {
        logd("ERROR: dialog_open missing buttons");
        return;
    }

    string title = "Menu";
    string message = "Select an option:";
    integer timeout = 60;

    if (json_has(payload, ["title"])) {
        title = llJsonGetValue(payload, ["title"]);
    }
    if (json_has(payload, ["body"])) {
        message = llJsonGetValue(payload, ["body"]);
    }
    else if (json_has(payload, ["message"])) {
        message = llJsonGetValue(payload, ["message"]);
    }
    if (json_has(payload, ["timeout"])) {
        timeout = (integer)llJsonGetValue(payload, ["timeout"]);
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
    string buttons_json = llJsonGetValue(payload, ["buttons"]);
    list buttons = llJson2List(buttons_json);
    
    // Show dialog
    llDialog(user, title + "\n\n" + message, buttons, channel);
    
    logd("Opened dialog: " + session_id + " for " + llKey2Name(user) + " on channel " + (string)channel);
}

handle_numbered_list_dialog(string payload, string session_id, key user) {
    if (!json_has(payload, ["items"])) {
        logd("ERROR: numbered_list missing items");
        return;
    }

    string title = "Select Item";
    string prompt = "Choose:";
    integer timeout = 60;

    if (json_has(payload, ["title"])) {
        title = llJsonGetValue(payload, ["title"]);
    }
    if (json_has(payload, ["prompt"])) {
        prompt = llJsonGetValue(payload, ["prompt"]);
    }
    if (json_has(payload, ["timeout"])) {
        timeout = (integer)llJsonGetValue(payload, ["timeout"]);
    }

    // Parse items
    string items_json = llJsonGetValue(payload, ["items"]);
    list items = llJson2List(items_json);
    integer item_count = llGetListLength(items);
    integer original_count = item_count;
    
    if (item_count == 0) {
        logd("ERROR: numbered_list has no items");
        return;
    }
    
    // Build body text with numbered list (max 11 items to leave room for Back button)
    string body = prompt + "\n\n";
    list buttons = ["Back"];
    
    integer max_items = 11;
    if (item_count > max_items) {
        // SECURITY FIX: Warn about truncation
        llOwnerSay("WARNING: Item list truncated to " + (string)max_items + " items (had " + (string)original_count + ")");
        logd("WARNING: Truncated numbered list (" + (string)original_count + " -> " + (string)max_items + ")");
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

handle_dialog_close(string payload) {
    if (!json_has(payload, ["session_id"])) return;

    string session_id = llJsonGetValue(payload, ["session_id"]);
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
                string payload = kPayload([
                    "session_id", session_id,
                    "user", (string)id,
                    "button", message
                ]);
                kSend(CONTEXT, "", DIALOG_BUS, payload, NULL_KEY);

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
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE) {
            // Soft reset: has "reset" marker
            if (json_has(payload, ["reset"])) {
                llResetScript();
            }
            return;
        }

        /* ===== DIALOG BUS ===== */
        if (num != DIALOG_BUS) return;

        // Dialog open: has "session_id" and "user" and "buttons" or "items"
        if (json_has(payload, ["session_id"]) && json_has(payload, ["user"])) {
            if (json_has(payload, ["close"])) {
                handle_dialog_close(payload);
            } else {
                handle_dialog_open(payload);
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
