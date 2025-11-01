/* ===============================================================
   MODULE: ds_collar_kanban_standard.lsl (v1.0)

   PURPOSE: Standard Kanban helpers - Balanced feature set
            For typical plugins with moderate message complexity

   ESTIMATED SIZE: ~3-4KB compiled

   INCLUDES:
   - All minimal helpers (creation, extraction, validation)
   - Routing helpers (isForMe, isFrom)
   - Simple creation shortcuts (createSimple, broadcast)
   - Payload access helpers (payloadGet, payloadHas)
   - Delta helpers (deltaSet, deltaListAdd, deltaListRemove)

   NOT INCLUDED:
   - Convenience message functions (use full library)
     (kanbanSendRegistration, kanbanQueryAcl, etc.)

   USAGE:
   #include "ds_collar_kanban_standard.lsl"

   RECOMMENDED FOR:
   - Medium plugins (15-25 messages)
   - Most typical use cases
   - Balance between features and memory
   =============================================================== */

/* ===============================================================
   CORE PACKET FUNCTIONS
   =============================================================== */

/**
 * Create standard Kanban packet
 */
string kanbanCreate(string from, string to, string payload_json) {
    return llList2Json(JSON_OBJECT, [
        "from", from,
        "payload", payload_json,
        "to", to
    ]);
}

/**
 * Create Kanban packet with simple key-value payload
 */
string kanbanCreateSimple(string from, string to, list payload_kvp) {
    return llList2Json(JSON_OBJECT, [
        "from", from,
        "payload", llList2Json(JSON_OBJECT, payload_kvp),
        "to", to
    ]);
}

/**
 * Create broadcast packet (to: "")
 */
string kanbanBroadcast(string from, string payload_json) {
    return kanbanCreate(from, "", payload_json);
}

/**
 * Create broadcast packet with simple payload
 */
string kanbanBroadcastSimple(string from, list payload_kvp) {
    return kanbanCreateSimple(from, "", payload_kvp);
}

/**
 * Validate packet structure
 */
integer kanbanIsValid(string packet) {
    return (jsonHas(packet, ["from"]) &&
            jsonHas(packet, ["payload"]) &&
            jsonHas(packet, ["to"]));
}

/**
 * Extract "from" field
 */
string kanbanGetFrom(string packet) {
    return llJsonGetValue(packet, ["from"]);
}

/**
 * Extract "to" field
 */
string kanbanGetTo(string packet) {
    return llJsonGetValue(packet, ["to"]);
}

/**
 * Extract "payload" field
 */
string kanbanGetPayload(string packet) {
    return llJsonGetValue(packet, ["payload"]);
}

/**
 * Check if message is for this context
 */
integer kanbanIsForMe(string packet, string my_context) {
    string to = kanbanGetTo(packet);
    return (to == "" || to == my_context);
}

/**
 * Check if message is from specific sender
 */
integer kanbanIsFrom(string packet, string sender_context) {
    string from = kanbanGetFrom(packet);
    return (from == sender_context);
}

/* ===============================================================
   DELTA PAYLOAD HELPERS
   =============================================================== */

/**
 * Create delta: SET operation
 */
string deltaSet(string key, string value) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", key,
        "value", value
    ]);
}

/**
 * Create delta: LIST_ADD operation
 */
string deltaListAdd(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_add",
        "key", key,
        "elem", elem
    ]);
}

/**
 * Create delta: LIST_REMOVE operation
 */
string deltaListRemove(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_remove",
        "key", key,
        "elem", elem
    ]);
}

/**
 * Get delta operation type
 */
string deltaGetOp(string payload) {
    return llJsonGetValue(payload, ["op"]);
}

/**
 * Get delta key
 */
string deltaGetKey(string payload) {
    return llJsonGetValue(payload, ["key"]);
}

/**
 * Get delta value (SET operation)
 */
string deltaGetValue(string payload) {
    return llJsonGetValue(payload, ["value"]);
}

/**
 * Get delta element (LIST operations)
 */
string deltaGetElem(string payload) {
    return llJsonGetValue(payload, ["elem"]);
}

/* ===============================================================
   PAYLOAD ACCESS HELPERS
   =============================================================== */

/**
 * Get value from payload with default
 */
string payloadGet(string payload, string key, string default_val) {
    if (jsonHas(payload, [key])) {
        return llJsonGetValue(payload, [key]);
    }
    return default_val;
}

/**
 * Check if payload field exists
 */
integer payloadHas(string payload, string key) {
    return jsonHas(payload, [key]);
}

/**
 * Check if JSON path exists
 */
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* ===============================================================
   EXAMPLE USAGE
   =============================================================== */

/*
// SENDING:

// Registration with simple payload
llMessageLinked(LINK_SET, 500,
    kanbanCreateSimple("bell", "kernel", [
        "label", "Bell",
        "min_acl", 1,
        "script", llGetScriptName()
    ]),
    NULL_KEY
);

// Settings delta - broadcast
llMessageLinked(LINK_SET, 800,
    kanbanBroadcast("settings", deltaSet("bell_visible", "1")),
    NULL_KEY
);

// List add delta
llMessageLinked(LINK_SET, 800,
    kanbanBroadcast("settings", deltaListAdd("trustees", (string)new_trustee)),
    NULL_KEY
);


// RECEIVING:

link_message(integer sender, integer num, string msg, key id) {
    if (!kanbanIsValid(msg)) return;
    if (!kanbanIsForMe(msg, "bell")) return;

    string from = kanbanGetFrom(msg);
    string payload = kanbanGetPayload(msg);

    if (num == 700 && kanbanIsFrom(msg, "auth")) {
        // ACL result
        integer level = (integer)payloadGet(payload, "level", "0");
        handleAclLevel(level);
    }
    else if (num == 800 && kanbanIsFrom(msg, "settings")) {
        // Settings update
        string op = deltaGetOp(payload);

        if (op == "set") {
            string key = deltaGetKey(payload);
            string value = deltaGetValue(payload);
            applySettingChange(key, value);
        }
        else {
            // Full sync
            if (payloadHas(payload, "bell_visible")) {
                integer visible = (integer)payloadGet(payload, "bell_visible", "0");
                setBellVisibility(visible);
            }
        }
    }
}
*/
