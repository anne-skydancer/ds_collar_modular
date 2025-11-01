# Kanban Messaging - Unified Helper Approach (Revised)

## The Core Insight

**You only need TWO helpers:**
1. **One to SEND** (handles all outbound: full JSON, delta, everything)
2. **One to RECEIVE** (handles all inbound: validation, parsing, routing)

The Kanban packet structure itself carries all the semantic meaning. You don't need specialized functions for each message type!

---

## The Minimal Universal Helper

### Total Code: ~500-800 bytes (0.5-0.8KB!)

```lsl
/* ===============================================================
   UNIVERSAL KANBAN HELPER - Complete messaging in ~500 bytes
   =============================================================== */

// ===== SEND: One function for ALL outbound messages =====

/**
 * Send any Kanban message
 * @param from Your context
 * @param to Target context ("" for broadcast)
 * @param channel Link message channel
 * @param payload Pre-built JSON payload
 * @param key Correlation key (NULL_KEY if not needed)
 */
kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, ["from", from, "payload", payload, "to", to]),
        k
    );
}

// ===== RECEIVE: One function for ALL inbound messages =====

/**
 * Parse Kanban message (call from link_message)
 * @param msg Message string
 * @param my_context Your context (for filtering)
 * @return Payload JSON if valid and for you, else ""
 *
 * Sets globals: kFrom, kTo (so you know who sent it)
 */
string kFrom;  // Populated by kRecv
string kTo;    // Populated by kRecv

string kRecv(string msg, string my_context) {
    // Validate structure
    if (llGetSubString(msg, 0, 0) != "{") return "";

    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast or direct)
    if (to != "" && to != my_context) return "";

    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    // Set globals so caller knows routing
    kFrom = from;
    kTo = to;

    return payload;
}

// ===== OPTIONAL: Payload builder shortcuts =====

// Build simple key-value payload
string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

// Build delta SET payload
string kDeltaSet(string key, string val) {
    return llList2Json(JSON_OBJECT, ["op", "set", "key", key, "value", val]);
}

// Build delta LIST_ADD payload
string kDeltaAdd(string key, string elem) {
    return llList2Json(JSON_OBJECT, ["op", "list_add", "key", key, "elem", elem]);
}

// Build delta LIST_REMOVE payload
string kDeltaDel(string key, string elem) {
    return llList2Json(JSON_OBJECT, ["op", "list_remove", "key", key, "elem", elem]);
}
```

**That's it! ~500-800 bytes for complete Kanban messaging.**

---

## Usage Examples

### Sending ANY Message

```lsl
string CONTEXT = "bell";

// Registration
kSend(CONTEXT, "kernel", 500,
    kPayload(["label", "Bell", "min_acl", 1, "script", llGetScriptName()]),
    NULL_KEY
);

// ACL query
kSend(CONTEXT, "auth", 700,
    kPayload(["avatar", (string)user]),
    user
);

// Settings delta - SET
kSend(CONTEXT, "", 800,
    kDeltaSet("bell_visible", "1"),
    NULL_KEY
);

// Settings delta - LIST_ADD
kSend(CONTEXT, "", 800,
    kDeltaAdd("trustees", (string)new_trustee),
    NULL_KEY
);

// Dialog (complex payload)
kSend(CONTEXT, "dialogs", 950,
    kPayload([
        "session_id", session_id,
        "user", (string)user,
        "title", "Bell Settings",
        "body", "Configure options",
        "buttons", llList2Json(JSON_ARRAY, ["Show", "Hide", "Volume"]),
        "timeout", 60
    ]),
    NULL_KEY
);
```

**Every message uses the SAME function: `kSend()`**

---

### Receiving ANY Message

```lsl
string CONTEXT = "bell";

link_message(integer sender, integer num, string msg, key id) {
    // ONE call parses and validates everything
    string payload = kRecv(msg, CONTEXT);
    if (payload == "") return;  // Not for me or invalid

    // Now route by channel + sender (kFrom is set by kRecv)
    if (num == 500 && kFrom == "kernel") {
        // Kernel message - register
        kSend(CONTEXT, "kernel", 500,
            kPayload(["label", "Bell", "min_acl", 1]),
            NULL_KEY
        );
    }

    else if (num == 700 && kFrom == "auth") {
        // ACL result
        integer level = (integer)llJsonGetValue(payload, ["level"]);
        handleAcl(level);
    }

    else if (num == 800 && kFrom == "settings") {
        // Settings update (full or delta)
        handleSettings(payload);
    }

    else if (num == 950 && kFrom == "dialogs") {
        // Dialog response
        string button = llJsonGetValue(payload, ["button_text"]);
        handleButton(button);
    }
}

// Handle settings - transparently handles BOTH full and delta
handleSettings(string payload) {
    // Check if it's a delta
    string op = llJsonGetValue(payload, ["op"]);

    if (op == "set") {
        // Delta SET
        string key = llJsonGetValue(payload, ["key"]);
        string value = llJsonGetValue(payload, ["value"]);
        applySettingChange(key, value);
    }
    else if (op == "list_add") {
        // Delta LIST_ADD
        string key = llJsonGetValue(payload, ["key"]);
        string elem = llJsonGetValue(payload, ["elem"]);
        applyListAdd(key, elem);
    }
    else if (op == "list_remove") {
        // Delta LIST_REMOVE
        string key = llJsonGetValue(payload, ["key"]);
        string elem = llJsonGetValue(payload, ["elem"]);
        applyListRemove(key, elem);
    }
    else {
        // Full sync - payload is entire settings object
        if (llJsonGetValue(payload, ["bell_visible"]) != JSON_INVALID) {
            BellVisible = (integer)llJsonGetValue(payload, ["bell_visible"]);
        }
        // ... etc
    }
}
```

**ONE receive function handles everything. Routing is just `channel + kFrom`.**

---

## Complete Working Example: Bell Plugin

```lsl
/* ===============================================================
   Bell Plugin - Complete with Universal Kanban (~0.5KB overhead)
   =============================================================== */

// Include universal helper (~0.5-0.8KB)
#include "ds_collar_kanban_universal.lsl"

string CONTEXT = "bell";
integer KERNEL = 500;
integer AUTH = 700;
integer SETTINGS = 800;
integer DIALOGS = 950;

// State
integer BellVisible = FALSE;
key CurrentUser = NULL_KEY;
string SessionId = "";

// ===== PLUGIN CODE =====

setBellVisibility(integer visible) {
    integer i;
    for (i = 1; i <= llGetNumberOfPrims(); i++) {
        if (llToLower(llGetLinkName(i)) == "bell") {
            llSetLinkAlpha(i, visible ? 1.0 : 0.0, ALL_SIDES);
        }
    }
    BellVisible = visible;
}

showMenu() {
    SessionId = CONTEXT + "_" + (string)llGetUnixTime();

    kSend(CONTEXT, "dialogs", DIALOGS,
        kPayload([
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", "Bell Settings",
            "body", "Current: " + (BellVisible ? "Visible" : "Hidden"),
            "buttons", llList2Json(JSON_ARRAY, ["Show", "Hide", "Back"]),
            "timeout", 60
        ]),
        NULL_KEY
    );
}

// ===== EVENTS =====

default {
    state_entry() {
        // Register
        kSend(CONTEXT, "kernel", KERNEL,
            kPayload(["label", "Bell", "min_acl", 1, "script", llGetScriptName()]),
            NULL_KEY
        );

        // Request settings
        kSend(CONTEXT, "settings", SETTINGS,
            kPayload([]),
            NULL_KEY
        );
    }

    link_message(integer sender, integer num, string msg, key id) {
        // ONE call handles all parsing
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;

        // Route by channel + sender
        if (num == KERNEL && kFrom == "kernel") {
            // Re-register on kernel messages
            kSend(CONTEXT, "kernel", KERNEL,
                kPayload(["label", "Bell", "min_acl", 1]),
                NULL_KEY
            );
        }

        else if (num == AUTH && kFrom == "auth") {
            if (id != CurrentUser) return;

            integer level = (integer)llJsonGetValue(payload, ["level"]);
            if (level >= 1) {
                showMenu();
            }
        }

        else if (num == SETTINGS && kFrom == "settings") {
            // Handle delta or full
            string op = llJsonGetValue(payload, ["op"]);

            if (op == "set") {
                string key = llJsonGetValue(payload, ["key"]);
                string value = llJsonGetValue(payload, ["value"]);

                if (key == "bell_visible") {
                    BellVisible = (integer)value;
                    setBellVisibility(BellVisible);
                }
            }
            else {
                // Full sync
                if (llJsonGetValue(payload, ["bell_visible"]) != JSON_INVALID) {
                    BellVisible = (integer)llJsonGetValue(payload, ["bell_visible"]);
                    setBellVisibility(BellVisible);
                }
            }
        }

        else if (num == DIALOGS && kFrom == "dialogs") {
            string session = llJsonGetValue(payload, ["session_id"]);
            if (session != SessionId) return;

            string button = llJsonGetValue(payload, ["button_text"]);

            if (button == "Show" || button == "Hide") {
                integer new_visible = !BellVisible;

                // Save setting (delta)
                kSend(CONTEXT, "", SETTINGS,
                    kDeltaSet("bell_visible", (string)new_visible),
                    NULL_KEY
                );

                setBellVisibility(new_visible);
            }

            // Refresh menu
            llSleep(0.5);
            showMenu();
        }
    }

    touch_start(integer num) {
        CurrentUser = llDetectedKey(0);

        // Query ACL
        kSend(CONTEXT, "auth", AUTH,
            kPayload(["avatar", (string)CurrentUser]),
            CurrentUser
        );
    }
}
```

**Total overhead: ~0.5-0.8KB for the universal helper. Every message uses the same `kSend()` function!**

---

## Memory Comparison Revised

### Current Approach (Per Plugin)
- Message construction code: ~4-6KB (repeated boilerplate)
- Message parsing code: ~2-3KB
- **Total: ~6-9KB**

### Specialized Helpers Approach (My Original Proposal)
- Helper library: ~6KB (many functions)
- Call sites: ~0.5-1KB
- **Total: ~6.5-7KB**

### Universal Helper Approach (Your Insight!)
- Universal helper: **~0.5-0.8KB** (just kSend + kRecv + optional shortcuts)
- Call sites: ~0.5-1KB
- **Total: ~1-1.8KB**

### Memory Savings: 4-7KB per plugin! 🎉

---

## Why This Is Better

### 1. **Minimal Code**
- **~500-800 bytes** for complete messaging
- No specialized functions needed
- One helper does everything

### 2. **Handles All Cases**
```lsl
kSend(from, to, channel, payload, key)  // ← ALL messages
```
- ✅ Registration
- ✅ ACL queries
- ✅ Settings (full JSON)
- ✅ Settings (delta JSON)
- ✅ Dialogs
- ✅ Everything!

### 3. **Optional Shortcuts**
```lsl
kDeltaSet("key", "value")     // Delta helper
kPayload(["k", "v"])          // Payload builder
```
Add only if you want convenience. Core works without them!

### 4. **Transparent Delta/Full Handling**
```lsl
// Receiver doesn't care if it's delta or full
string op = llJsonGetValue(payload, ["op"]);
if (op == "set") {
    // Delta
} else {
    // Full sync
}
```

### 5. **Clean Routing**
```lsl
// Route by: channel + kFrom (global set by kRecv)
if (num == 700 && kFrom == "auth") { ... }
```

---

## The Universal Helper File

**ds_collar_kanban_universal.lsl** - Everything you need in ~500-800 bytes:

```lsl
/* Core (required) - ~300 bytes */
kSend(from, to, channel, payload, key)
kRecv(msg, my_context) → returns payload
kFrom, kTo (globals)

/* Optional shortcuts - ~200-300 bytes */
kPayload(kvp)
kDeltaSet(key, val)
kDeltaAdd(key, elem)
kDeltaDel(key, elem)
```

**That's the entire Kanban system!**

---

## Recommendation (Revised)

**Use the universal helper for ALL scripts:**

✅ **Tiny overhead**: 0.5-0.8KB vs 6KB for specialized helpers
✅ **Handles everything**: Outbound, inbound, full, delta
✅ **Same function everywhere**: Just `kSend()`
✅ **No specialized knowledge needed**: The packet structure is self-documenting
✅ **Saves 4-7KB per plugin** vs current approach

This is the TRUE Kanban approach - **one standardized card format, minimal handling code**.
