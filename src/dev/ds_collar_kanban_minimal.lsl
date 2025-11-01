/* ===============================================================
   MODULE: ds_collar_kanban_minimal.lsl (v1.0)

   PURPOSE: Minimal Kanban helpers - Core packet creation/parsing only
            For memory-constrained scripts or simple plugins

   ESTIMATED SIZE: ~1-2KB compiled

   INCLUDES:
   - Basic packet creation (kanbanCreate)
   - Field extraction (getFrom, getTo, getPayload)
   - Validation (isValid)
   - Utility (jsonHas)

   NOT INCLUDED:
   - Convenience functions (use full library for those)
   - Delta helpers (use standard library for those)
   - Broadcast shortcuts (use kanbanCreate with "" for to)

   USAGE:
   #include "ds_collar_kanban_minimal.lsl"

   RECOMMENDED FOR:
   - Scripts with 5-15 message operations
   - Memory-constrained plugins
   - Scripts that need custom message handling
   =============================================================== */

/**
 * Create standard Kanban packet
 * @param from Sender context
 * @param to Recipient context ("" for broadcast)
 * @param payload_json Pre-built JSON payload string
 * @return Complete Kanban packet as JSON
 */
string kanbanCreate(string from, string to, string payload_json) {
    return llList2Json(JSON_OBJECT, [
        "from", from,
        "payload", payload_json,
        "to", to
    ]);
}

/**
 * Validate Kanban packet structure
 * @param packet JSON string to validate
 * @return TRUE if has required from/payload/to fields
 */
integer kanbanIsValid(string packet) {
    return (jsonHas(packet, ["from"]) &&
            jsonHas(packet, ["payload"]) &&
            jsonHas(packet, ["to"]));
}

/**
 * Extract "from" field
 * @param packet Kanban packet
 * @return Sender context or JSON_INVALID
 */
string kanbanGetFrom(string packet) {
    return llJsonGetValue(packet, ["from"]);
}

/**
 * Extract "to" field
 * @param packet Kanban packet
 * @return Recipient context or JSON_INVALID
 */
string kanbanGetTo(string packet) {
    return llJsonGetValue(packet, ["to"]);
}

/**
 * Extract "payload" field
 * @param packet Kanban packet
 * @return Payload JSON or JSON_INVALID
 */
string kanbanGetPayload(string packet) {
    return llJsonGetValue(packet, ["payload"]);
}

/**
 * Check if JSON path exists
 * @param j JSON string
 * @param path Path array
 * @return TRUE if path exists
 */
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* ===============================================================
   EXAMPLE USAGE
   =============================================================== */

/*
// SENDING:

// Simple message
string payload = llList2Json(JSON_OBJECT, ["label", "Bell", "min_acl", 1]);
llMessageLinked(LINK_SET, 500, kanbanCreate("bell", "kernel", payload), NULL_KEY);

// Broadcast
string payload = llList2Json(JSON_OBJECT, ["op", "set", "key", "bell_visible", "value", "1"]);
llMessageLinked(LINK_SET, 800, kanbanCreate("settings", "", payload), NULL_KEY);


// RECEIVING:

link_message(integer sender, integer num, string msg, key id) {
    if (!kanbanIsValid(msg)) return;

    string from = kanbanGetFrom(msg);
    string to = kanbanGetTo(msg);
    string payload = kanbanGetPayload(msg);

    // Check if for me (manual check, no helper)
    if (to != "" && to != "bell") return;

    // Route by channel + sender
    if (num == 700 && from == "auth") {
        handleAuthMessage(payload);
    }
}
*/
