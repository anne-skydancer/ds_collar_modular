/* ===============================================================
   MODULE: ds_collar_kanban_universal.lsl (v1.0)

   PURPOSE: Universal Kanban helper - ONE function for all messaging
            True Kanban philosophy: standardized card, minimal code

   ESTIMATED SIZE: ~500-800 bytes compiled

   USAGE:
   #include "ds_collar_kanban_universal.lsl"

   // Send ANY message
   kSend("bell", "kernel", 500, kPayload(["label", "Bell"]), NULL_KEY);

   // Receive ANY message
   link_message(integer sender, integer num, string msg, key id) {
       string payload = kRecv(msg, "bell");
       if (payload == "") return;
       // Use kFrom to route: if (num == 700 && kFrom == "auth") { ... }
   }

   =============================================================== */

/* ===============================================================
   GLOBALS (Set by kRecv)
   =============================================================== */

string kFrom = "";  // Sender context (populated by kRecv)
string kTo = "";    // Recipient context (populated by kRecv)

/* ===============================================================
   CORE FUNCTIONS (Required - ~300 bytes)
   =============================================================== */

/**
 * Send any Kanban message (UNIVERSAL OUTBOUND)
 *
 * Handles: registration, ACL queries, settings (full/delta),
 *          dialogs, leash, particles, everything!
 *
 * @param from Your context (e.g., "bell", "leash", "auth")
 * @param to Target context (e.g., "kernel", "dialogs", "" for broadcast)
 * @param channel Link message channel (500=kernel, 700=auth, 800=settings, etc.)
 * @param payload Pre-built JSON payload (use kPayload() or build manually)
 * @param k Correlation key (typically user UUID or NULL_KEY)
 *
 * Example:
 *   kSend("bell", "kernel", 500, kPayload(["label", "Bell", "min_acl", 1]), NULL_KEY);
 */
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

/**
 * Receive and parse any Kanban message (UNIVERSAL INBOUND)
 *
 * Validates structure, checks if for you, extracts payload.
 * Sets globals: kFrom, kTo (use for routing)
 *
 * @param msg Message string from link_message
 * @param my_context Your context (for filtering)
 * @return Payload JSON if valid and for you, else ""
 *
 * Example:
 *   string payload = kRecv(msg, "bell");
 *   if (payload == "") return;  // Not for me
 *   if (num == 700 && kFrom == "auth") { handleAcl(payload); }
 */
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

/* ===============================================================
   OPTIONAL SHORTCUTS (~200-300 bytes)

   You can omit these and build payloads manually if you want
   to save ~200-300 bytes. Core kSend/kRecv work without them.
   =============================================================== */

/**
 * Build simple key-value payload
 *
 * @param kvp Key-value pair list: ["key1", "val1", "key2", "val2", ...]
 * @return JSON object payload
 *
 * Example:
 *   kPayload(["label", "Bell", "min_acl", 1])
 *   → {"label":"Bell","min_acl":1}
 */
string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

/**
 * Build delta SET payload (scalar value change)
 *
 * @param key Setting key name
 * @param val New value as string
 * @return Delta payload JSON
 *
 * Example:
 *   kDeltaSet("bell_visible", "1")
 *   → {"op":"set","key":"bell_visible","value":"1"}
 */
string kDeltaSet(string key, string val) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", key,
        "value", val
    ]);
}

/**
 * Build delta LIST_ADD payload (add element to list)
 *
 * @param key Setting key name (list)
 * @param elem Element to add (UUID or string)
 * @return Delta payload JSON
 *
 * Example:
 *   kDeltaAdd("trustees", (string)new_trustee)
 *   → {"op":"list_add","key":"trustees","elem":"uuid-here"}
 */
string kDeltaAdd(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_add",
        "key", key,
        "elem", elem
    ]);
}

/**
 * Build delta LIST_REMOVE payload (remove element from list)
 *
 * @param key Setting key name (list)
 * @param elem Element to remove (UUID or string)
 * @return Delta payload JSON
 *
 * Example:
 *   kDeltaDel("blacklist", (string)removed_user)
 *   → {"op":"list_remove","key":"blacklist","elem":"uuid-here"}
 */
string kDeltaDel(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_remove",
        "key", key,
        "elem", elem
    ]);
}

/* ===============================================================
   USAGE EXAMPLES
   =============================================================== */

/*

// ===== SENDING EXAMPLES =====

// Registration
kSend("bell", "kernel", 500,
    kPayload(["label", "Bell", "min_acl", 1, "script", llGetScriptName()]),
    NULL_KEY
);

// Heartbeat (pong)
kSend("bell", "kernel", 500,
    kPayload([]),  // Empty payload
    NULL_KEY
);

// ACL query
kSend("bell", "auth", 700,
    kPayload(["avatar", (string)user]),
    user  // Correlation key
);

// Settings request
kSend("bell", "settings", 800,
    kPayload([]),
    NULL_KEY
);

// Settings update - delta SET
kSend("bell", "", 800,  // Broadcast (to = "")
    kDeltaSet("bell_visible", "1"),
    NULL_KEY
);

// Settings update - delta LIST_ADD
kSend("owner", "", 800,
    kDeltaAdd("owner_keys", (string)new_owner),
    NULL_KEY
);

// Settings update - delta LIST_REMOVE
kSend("blacklist", "", 800,
    kDeltaDel("blacklist", (string)removed_user),
    NULL_KEY
);

// Dialog open
kSend("bell", "dialogs", 950,
    kPayload([
        "session_id", "bell_" + (string)llGetUnixTime(),
        "user", (string)user,
        "title", "Bell Settings",
        "body", "Configure your bell",
        "buttons", llList2Json(JSON_ARRAY, ["Show", "Hide", "Volume"]),
        "timeout", 60
    ]),
    NULL_KEY
);


// ===== RECEIVING EXAMPLES =====

string CONTEXT = "bell";

link_message(integer sender, integer num, string msg, key id) {
    // ONE call parses everything
    string payload = kRecv(msg, CONTEXT);
    if (payload == "") return;  // Not for me or invalid

    // Route by channel + kFrom (global set by kRecv)
    if (num == 500 && kFrom == "kernel") {
        // Kernel message - re-register
        kSend(CONTEXT, "kernel", 500,
            kPayload(["label", "Bell", "min_acl", 1]),
            NULL_KEY
        );
    }

    else if (num == 700 && kFrom == "auth") {
        // ACL result
        if (id != CurrentUser) return;
        integer level = (integer)llJsonGetValue(payload, ["level"]);
        if (level >= 1) {
            showMenu();
        }
    }

    else if (num == 800 && kFrom == "settings") {
        // Settings update - delta OR full
        string op = llJsonGetValue(payload, ["op"]);

        if (op == "set") {
            // Delta SET
            string key = llJsonGetValue(payload, ["key"]);
            string value = llJsonGetValue(payload, ["value"]);

            if (key == "bell_visible") {
                BellVisible = (integer)value;
                setBellVisibility(BellVisible);
            }
        }
        else if (op == "list_add") {
            // Delta LIST_ADD
            string key = llJsonGetValue(payload, ["key"]);
            string elem = llJsonGetValue(payload, ["elem"]);
            // Handle list add
        }
        else if (op == "list_remove") {
            // Delta LIST_REMOVE
            string key = llJsonGetValue(payload, ["key"]);
            string elem = llJsonGetValue(payload, ["elem"]);
            // Handle list remove
        }
        else {
            // Full sync - payload is entire settings object
            if (llJsonGetValue(payload, ["bell_visible"]) != JSON_INVALID) {
                BellVisible = (integer)llJsonGetValue(payload, ["bell_visible"]);
                setBellVisibility(BellVisible);
            }
            // ... apply other settings
        }
    }

    else if (num == 950 && kFrom == "dialogs") {
        // Dialog response
        string session = llJsonGetValue(payload, ["session_id"]);
        if (session != SessionId) return;

        string button = llJsonGetValue(payload, ["button_text"]);
        handleButtonClick(button);
    }
}

*/
