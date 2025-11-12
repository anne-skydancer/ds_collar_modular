/*--------------------
LIBRARY: message_routing.lsl
PURPOSE: Standardized targeted messaging helpers for ng branch
USAGE: Copy these functions into each script's HELPERS section
--------------------*/

/* -------------------- MESSAGE ROUTING HELPERS -------------------- */

// Fast check if message is intended for this script
// Returns TRUE if message should be processed, FALSE if should be ignored
integer is_message_for_me(string msg, string script_id) {
    // Fast path: Check if message starts with JSON
    if (llGetSubString(msg, 0, 0) != "{") return FALSE;
    
    // Check if "to" field exists
    integer to_pos = llSubStringIndex(msg, "\"to\"");
    if (to_pos == -1) {
        // No routing field = broadcast (backward compatible)
        return TRUE;
    }
    
    // Extract routing section (typically in first 100 chars)
    string header = llGetSubString(msg, 0, to_pos + 100);
    
    // Check for broadcast wildcard
    if (llSubStringIndex(header, "\"*\"") != -1) return TRUE;
    
    // Check if our script ID appears in the "to" field
    if (llSubStringIndex(header, script_id) != -1) return TRUE;
    
    // Check for category broadcast (e.g., "plugin:*" or "kmod:*")
    if (llGetSubString(script_id, 0, 6) == "plugin_" &&
        llSubStringIndex(header, "\"plugin:*\"") != -1) return TRUE;
    
    if (llGetSubString(script_id, 0, 4) == "kmod_" &&
        llSubStringIndex(header, "\"kmod:*\"") != -1) return TRUE;
    
    return FALSE;  // Not for us
}

// Helper to create targeted message with routing
string create_routed_message(string from_id, string to_id, list message_fields) {
    // Prepend routing fields to message
    list routed = ["from", from_id, "to", to_id] + message_fields;
    return llList2Json(JSON_OBJECT, routed);
}

// Helper to create broadcast message
string create_broadcast_message(string from_id, list message_fields) {
    return create_routed_message(from_id, "*", message_fields);
}

// Helper to extract sender from message
string get_message_sender(string msg) {
    if (!json_has(msg, ["from"])) return "";
    return llJsonGetValue(msg, ["from"]);
}

/* -------------------- USAGE EXAMPLE -------------------- */

/*
// 1. Define script identity at top of script
string SCRIPT_ID = "kmod_ui";  // or "plugin_leash", etc.

// 2. Use in link_message handler
link_message(integer sender, integer num, string msg, key id) {
    // Early filter - most scripts exit here
    if (!is_message_for_me(msg, SCRIPT_ID)) return;
    
    // Now parse full JSON (only recipient does this)
    if (!json_has(msg, ["type"])) return;
    string msg_type = llJsonGetValue(msg, ["type"]);
    
    // Process message...
}

// 3. Send targeted messages
string msg = create_routed_message(
    SCRIPT_ID,              // from
    "kmod_auth",            // to
    [
        "type", "acl_query",
        "avatar", (string)user
    ]
);
llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);

// 4. Send broadcasts
string broadcast = create_broadcast_message(
    SCRIPT_ID,
    [
        "type", "settings_changed",
        "key", "owner_key"
    ]
);
llMessageLinked(LINK_SET, SETTINGS_BUS, broadcast, NULL_KEY);
*/
