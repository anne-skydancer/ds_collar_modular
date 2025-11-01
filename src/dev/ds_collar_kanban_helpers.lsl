/* ===============================================================
   MODULE: ds_collar_kanban_helpers.lsl (v1.0)

   PURPOSE: Kanban messaging system helpers - Standardized packet
            creation and parsing for from/payload/to message structure

   KANBAN PACKET STRUCTURE:
   {
       "from": "sender_context",
       "payload": { ... },
       "to": "recipient_context"
   }

   USAGE:
   Include this file in any script that uses Kanban messaging.
   Do NOT compile this file standalone.

   EXAMPLE:
   // Send registration
   llMessageLinked(LINK_SET, KERNEL_LIFECYCLE,
       kanbanCreateSimple("bell", "kernel", [
           "label", "Bell",
           "min_acl", 1
       ]),
       NULL_KEY
   );

   // Receive and parse
   link_message(integer sender, integer num, string msg, key id) {
       if (!kanbanIsValid(msg)) return;
       if (!kanbanIsForMe(msg, "bell")) return;

       string from = kanbanGetFrom(msg);
       string payload = kanbanGetPayload(msg);
       // Handle payload...
   }
   =============================================================== */

/* ===============================================================
   CORE KANBAN HELPERS
   =============================================================== */

/**
 * Create standard Kanban packet with pre-built JSON payload
 * @param from Sender context (e.g., "bell", "leash", "auth")
 * @param to Recipient context (e.g., "kernel", "dialogs", "" for broadcast)
 * @param payload_json Pre-built JSON object as string
 * @return Complete Kanban packet as JSON string
 */
string kanbanCreate(string from, string to, string payload_json) {
    return llList2Json(JSON_OBJECT, [
        "from", from,
        "payload", payload_json,
        "to", to
    ]);
}

/**
 * Create Kanban packet with simple key-value list payload
 * @param from Sender context
 * @param to Recipient context
 * @param payload_kvp Key-value pair list [key1, val1, key2, val2, ...]
 * @return Complete Kanban packet as JSON string
 */
string kanbanCreateSimple(string from, string to, list payload_kvp) {
    return llList2Json(JSON_OBJECT, [
        "from", from,
        "payload", llList2Json(JSON_OBJECT, payload_kvp),
        "to", to
    ]);
}

/**
 * Create Kanban packet for broadcast (empty "to" field)
 * @param from Sender context
 * @param payload_json Pre-built JSON payload
 * @return Complete Kanban packet as JSON string
 */
string kanbanBroadcast(string from, string payload_json) {
    return kanbanCreate(from, "", payload_json);
}

/**
 * Create broadcast Kanban packet with simple payload
 * @param from Sender context
 * @param payload_kvp Key-value pair list
 * @return Complete Kanban packet as JSON string
 */
string kanbanBroadcastSimple(string from, list payload_kvp) {
    return kanbanCreateSimple(from, "", payload_kvp);
}

/**
 * Validate Kanban packet structure
 * @param packet JSON string to validate
 * @return TRUE if packet has required from/payload/to fields
 */
integer kanbanIsValid(string packet) {
    return (jsonHas(packet, ["from"]) &&
            jsonHas(packet, ["payload"]) &&
            jsonHas(packet, ["to"]));
}

/**
 * Extract "from" field from Kanban packet
 * @param packet Kanban packet JSON string
 * @return Sender context or JSON_INVALID if missing
 */
string kanbanGetFrom(string packet) {
    return llJsonGetValue(packet, ["from"]);
}

/**
 * Extract "to" field from Kanban packet
 * @param packet Kanban packet JSON string
 * @return Recipient context, "" for broadcast, or JSON_INVALID if missing
 */
string kanbanGetTo(string packet) {
    return llJsonGetValue(packet, ["to"]);
}

/**
 * Extract "payload" field from Kanban packet
 * @param packet Kanban packet JSON string
 * @return Payload JSON or JSON_INVALID if missing
 */
string kanbanGetPayload(string packet) {
    return llJsonGetValue(packet, ["payload"]);
}

/**
 * Check if message is intended for this context
 * @param packet Kanban packet JSON string
 * @param my_context This script's context name
 * @return TRUE if broadcast or addressed to my_context
 */
integer kanbanIsForMe(string packet, string my_context) {
    string to = kanbanGetTo(packet);
    return (to == "" || to == my_context);
}

/**
 * Check if message is from specific sender
 * @param packet Kanban packet JSON string
 * @param sender_context Expected sender context
 * @return TRUE if from matches sender_context
 */
integer kanbanIsFrom(string packet, string sender_context) {
    string from = kanbanGetFrom(packet);
    return (from == sender_context);
}

/* ===============================================================
   DELTA PAYLOAD HELPERS
   =============================================================== */

/**
 * Create delta payload: SET operation (scalar value change)
 * @param key Setting key name
 * @param value New value as string
 * @return Delta payload JSON
 */
string deltaSet(string key, string value) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", key,
        "value", value
    ]);
}

/**
 * Create delta payload: LIST_ADD operation (add element to list)
 * @param key Setting key name (list)
 * @param elem Element to add (UUID or string)
 * @return Delta payload JSON
 */
string deltaListAdd(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_add",
        "key", key,
        "elem", elem
    ]);
}

/**
 * Create delta payload: LIST_REMOVE operation (remove element from list)
 * @param key Setting key name (list)
 * @param elem Element to remove (UUID or string)
 * @return Delta payload JSON
 */
string deltaListRemove(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_remove",
        "key", key,
        "elem", elem
    ]);
}

/**
 * Get delta operation type from payload
 * @param payload Delta payload JSON
 * @return Operation type: "set", "list_add", "list_remove", or JSON_INVALID
 */
string deltaGetOp(string payload) {
    return llJsonGetValue(payload, ["op"]);
}

/**
 * Get delta key from payload
 * @param payload Delta payload JSON
 * @return Key name or JSON_INVALID
 */
string deltaGetKey(string payload) {
    return llJsonGetValue(payload, ["key"]);
}

/**
 * Get delta value from SET payload
 * @param payload Delta payload JSON
 * @return Value or JSON_INVALID
 */
string deltaGetValue(string payload) {
    return llJsonGetValue(payload, ["value"]);
}

/**
 * Get delta element from LIST_ADD/LIST_REMOVE payload
 * @param payload Delta payload JSON
 * @return Element or JSON_INVALID
 */
string deltaGetElem(string payload) {
    return llJsonGetValue(payload, ["elem"]);
}

/* ===============================================================
   CONVENIENCE FUNCTIONS FOR COMMON OPERATIONS
   =============================================================== */

/**
 * Send Kanban registration to kernel
 * @param my_context This plugin's context name
 * @param label Display label
 * @param min_acl Minimum ACL level required
 */
kanbanSendRegistration(string my_context, string label, integer min_acl) {
    llMessageLinked(LINK_SET, 500, // KERNEL_LIFECYCLE
        kanbanCreateSimple(my_context, "kernel", [
            "label", label,
            "min_acl", min_acl,
            "script", llGetScriptName()
        ]),
        NULL_KEY
    );
}

/**
 * Send Kanban pong (heartbeat response) to kernel
 * @param my_context This plugin's context name
 */
kanbanSendPong(string my_context) {
    llMessageLinked(LINK_SET, 500, // KERNEL_LIFECYCLE
        kanbanCreateSimple(my_context, "kernel", []),
        NULL_KEY
    );
}

/**
 * Send Kanban ACL query to auth module
 * @param my_context This plugin's context name
 * @param avatar UUID to query
 * @param correlation_key Key to use for llMessageLinked (typically avatar)
 */
kanbanQueryAcl(string my_context, key avatar, key correlation_key) {
    llMessageLinked(LINK_SET, 700, // AUTH_BUS
        kanbanCreateSimple(my_context, "auth", [
            "avatar", (string)avatar
        ]),
        correlation_key
    );
}

/**
 * Send Kanban settings delta (SET operation)
 * @param my_context This plugin's context name
 * @param key Setting key
 * @param value New value
 */
kanbanSettingsSet(string my_context, string key, string value) {
    llMessageLinked(LINK_SET, 800, // SETTINGS_BUS
        kanbanBroadcast(my_context, deltaSet(key, value)),
        NULL_KEY
    );
}

/**
 * Send Kanban settings delta (LIST_ADD operation)
 * @param my_context This plugin's context name
 * @param key Setting key (list name)
 * @param elem Element to add
 */
kanbanSettingsListAdd(string my_context, string key, string elem) {
    llMessageLinked(LINK_SET, 800, // SETTINGS_BUS
        kanbanBroadcast(my_context, deltaListAdd(key, elem)),
        NULL_KEY
    );
}

/**
 * Send Kanban settings delta (LIST_REMOVE operation)
 * @param my_context This plugin's context name
 * @param key Setting key (list name)
 * @param elem Element to remove
 */
kanbanSettingsListRemove(string my_context, string key, string elem) {
    llMessageLinked(LINK_SET, 800, // SETTINGS_BUS
        kanbanBroadcast(my_context, deltaListRemove(key, elem)),
        NULL_KEY
    );
}

/**
 * Request full settings sync
 * @param my_context This plugin's context name
 */
kanbanSettingsRequest(string my_context) {
    llMessageLinked(LINK_SET, 800, // SETTINGS_BUS
        kanbanCreateSimple(my_context, "settings", []),
        NULL_KEY
    );
}

/* ===============================================================
   UTILITY FUNCTIONS
   =============================================================== */

/**
 * Check if JSON path exists (helper for other functions)
 * @param j JSON string
 * @param path Path array (e.g., ["key"], ["parent", "child"])
 * @return TRUE if path exists and is not JSON_INVALID
 */
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/**
 * Get value from payload with default fallback
 * @param payload Payload JSON
 * @param key Key name
 * @param default_val Default value if key not found
 * @return Value or default
 */
string payloadGet(string payload, string key, string default_val) {
    if (jsonHas(payload, [key])) {
        return llJsonGetValue(payload, [key]);
    }
    return default_val;
}

/**
 * Check if payload field exists
 * @param payload Payload JSON
 * @param key Key name
 * @return TRUE if key exists
 */
integer payloadHas(string payload, string key) {
    return jsonHas(payload, [key]);
}

/* ===============================================================
   EXAMPLE USAGE TEMPLATES
   =============================================================== */

/*
// === SENDING MESSAGES ===

// 1. Plugin registration
kanbanSendRegistration("bell", "Bell", 1);

// 2. Heartbeat response
kanbanSendPong("bell");

// 3. ACL query
kanbanQueryAcl("bell", user, user);

// 4. Settings update (scalar)
kanbanSettingsSet("bell", "bell_visible", "1");

// 5. Settings update (list add)
kanbanSettingsListAdd("owner", "owner_keys", (string)new_owner);

// 6. Settings update (list remove)
kanbanSettingsListRemove("blacklist", "blacklist", (string)removed_user);

// 7. Custom message with full JSON payload
string payload = llList2Json(JSON_OBJECT, [
    "session_id", session_id,
    "user", (string)user,
    "title", "My Dialog",
    "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"])
]);
llMessageLinked(LINK_SET, 950, // DIALOG_BUS
    kanbanCreate("bell", "dialogs", payload),
    NULL_KEY
);


// === RECEIVING MESSAGES ===

link_message(integer sender, integer num, string msg, key id) {
    // Validate Kanban packet
    if (!kanbanIsValid(msg)) {
        // Not a Kanban message, might be legacy format
        return;
    }

    // Check if message is for me
    if (!kanbanIsForMe(msg, "bell")) {
        return;  // Not for me
    }

    // Extract components
    string from = kanbanGetFrom(msg);
    string payload = kanbanGetPayload(msg);

    // Route by channel and sender
    if (num == 700 && from == "auth") {
        // ACL result
        handleAclResult(payload);
    }
    else if (num == 800 && from == "settings") {
        // Settings update
        handleSettingsUpdate(payload);
    }
    else if (num == 500 && from == "kernel") {
        // Kernel message
        handleKernelMessage(payload);
    }
}

// Handle settings delta update
handleSettingsUpdate(string payload) {
    string op = deltaGetOp(payload);

    if (op == "set") {
        string key = deltaGetKey(payload);
        string value = deltaGetValue(payload);
        // Apply scalar update
    }
    else if (op == "list_add") {
        string key = deltaGetKey(payload);
        string elem = deltaGetElem(payload);
        // Apply list add
    }
    else if (op == "list_remove") {
        string key = deltaGetKey(payload);
        string elem = deltaGetElem(payload);
        // Apply list remove
    }
    else {
        // Full sync - payload is entire settings JSON
        if (payloadHas(payload, "bell_visible")) {
            string val = payloadGet(payload, "bell_visible", "0");
            // Apply full sync
        }
    }
}
*/
