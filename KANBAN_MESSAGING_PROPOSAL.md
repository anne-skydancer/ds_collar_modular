# Kanban Messaging System Proposal

## Concept

Standardize all JSON messaging using a simple three-field "Kanban card" structure inspired by just-in-time manufacturing:

```json
{
  "from": "sender_context",
  "payload": { /* message data */ },
  "to": "recipient_context"
}
```

**Key Principle**: Like Kanban cards moving between workstations, messages are standardized containers that clearly identify origin, destination, and contents.

---

## Message Structure

### Standard Kanban Packet (Always 3 fields in this order)

```lsl
string kanban = llList2Json(JSON_OBJECT, [
    "from", sender_context,
    "payload", payload_json,
    "to", recipient_context
]);
```

### Field Definitions

| Field | Type | Purpose | Examples |
|-------|------|---------|----------|
| `from` | string | Sender identification | "bell", "leash", "kmod_auth", "hud" |
| `payload` | JSON object/array | Message data (full or delta) | Settings JSON, action data, state updates |
| `to` | string | Recipient identification | "dialogs", "settings", "auth", "" (broadcast) |

### Special Values

- **`to: ""`** - Broadcast to all listeners (replaces LINK_SET broadcasts)
- **`from: "system"`** - System-level messages (kernel, bootstrap)
- **`to: "reply"`** - Reply to sender (correlation handled by channel)

---

## Full vs Delta Payloads

### Full JSON Payload
Complete data structure - used for initialization, sync, complex operations

```json
{
  "from": "bell",
  "payload": {
    "session_id": "bell_1730450123",
    "user": "uuid-here",
    "title": "Bell Settings",
    "body": "Configure bell options",
    "buttons": ["Visible", "Sound", "Volume"],
    "timeout": 60
  },
  "to": "dialogs"
}
```

### Delta JSON Payload
Incremental changes only - used for efficient updates

```json
{
  "from": "settings",
  "payload": {
    "op": "set",
    "key": "bell_visible",
    "value": "1"
  },
  "to": ""
}
```

```json
{
  "from": "settings",
  "payload": {
    "op": "list_add",
    "key": "trustees",
    "elem": "uuid-here"
  },
  "to": ""
}
```

---

## Current vs Kanban Examples

### Example 1: Plugin Registration

**Current:**
```lsl
llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
    "type", "register",
    "context", "bell",
    "label", "Bell",
    "min_acl", 1,
    "script", llGetScriptName()
]), NULL_KEY);
```

**Kanban:**
```lsl
llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
    "from", "bell",
    "payload", llList2Json(JSON_OBJECT, [
        "label", "Bell",
        "min_acl", 1,
        "script", llGetScriptName()
    ]),
    "to", "kernel"
]), NULL_KEY);
```

**What's Better:**
- No "type" field needed - routing is clear from from/to
- "context" is now "from" - DRY principle
- Handler knows it's a registration because it came TO kernel on LIFECYCLE channel

---

### Example 2: ACL Query

**Current:**
```lsl
llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
    "type", "acl_query",
    "avatar", (string)user
]), user);
```

**Kanban:**
```lsl
llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
    "from", "bell",
    "payload", llList2Json(JSON_OBJECT, [
        "avatar", (string)user
    ]),
    "to", "auth"
]), user);
```

**What's Better:**
- "from" clearly identifies which plugin made the request
- No "type" ambiguity - it's on AUTH_BUS going TO auth, so it's a query
- Can reply back using "to": "bell"

---

### Example 3: Settings Delta

**Current:**
```lsl
string changes = llList2Json(JSON_OBJECT, [key_name, new_value]);
string msg = llList2Json(JSON_OBJECT, [
    "type", "settings_delta",
    "op", "set",
    "changes", changes
]);
llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
```

**Kanban (Delta):**
```lsl
llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
    "from", "settings",
    "payload", llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", key_name,
        "value", new_value
    ]),
    "to", ""
]), NULL_KEY);
```

**What's Better:**
- Delta in payload - minimal data transfer
- Broadcast with `to: ""`
- "op" in payload clearly indicates operation type
- No nested "changes" object - flatter structure

---

### Example 4: Dialog Opening (Full JSON)

**Current:**
```lsl
llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
    "type", "dialog_open",
    "session_id", SessionId,
    "user", (string)CurrentUser,
    "title", title,
    "body", body,
    "buttons", llList2Json(JSON_ARRAY, buttons),
    "timeout", 60
]), NULL_KEY);
```

**Kanban (Full JSON):**
```lsl
llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
    "from", "bell",
    "payload", llList2Json(JSON_OBJECT, [
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]),
    "to", "dialogs"
]), NULL_KEY);
```

**What's Better:**
- Full context in payload - all dialog data
- Clear routing: bell → dialogs
- No "type" field - it's going TO dialogs, so it's a dialog open request

---

## Helper Functions

### Core Helpers

```lsl
// ===== KANBAN PACKET HELPERS =====

// Create standard Kanban packet with full JSON payload
string kanbanCreate(string from, string to, string payload_json) {
    return llList2Json(JSON_OBJECT, [
        "from", from,
        "payload", payload_json,
        "to", to
    ]);
}

// Create Kanban packet with simple key-value payload
string kanbanCreateSimple(string from, string to, list payload_kvp) {
    return llList2Json(JSON_OBJECT, [
        "from", from,
        "payload", llList2Json(JSON_OBJECT, payload_kvp),
        "to", to
    ]);
}

// Create Kanban packet for broadcast (empty "to")
string kanbanBroadcast(string from, string payload_json) {
    return kanbanCreate(from, "", payload_json);
}

// Validate Kanban packet structure
integer kanbanIsValid(string packet) {
    return (jsonHas(packet, ["from"]) &&
            jsonHas(packet, ["payload"]) &&
            jsonHas(packet, ["to"]));
}

// Extract fields
string kanbanGetFrom(string packet) {
    return llJsonGetValue(packet, ["from"]);
}

string kanbanGetTo(string packet) {
    return llJsonGetValue(packet, ["to"]);
}

string kanbanGetPayload(string packet) {
    return llJsonGetValue(packet, ["payload"]);
}

// Check if message is for me
integer kanbanIsForMe(string packet, string my_context) {
    string to = kanbanGetTo(packet);
    return (to == "" || to == my_context);  // Broadcast or direct
}

// Helper: Check if exists
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
```

### Delta Payload Helpers

```lsl
// ===== DELTA PAYLOAD HELPERS =====

// Create delta: set operation
string deltaSet(string key, string value) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", key,
        "value", value
    ]);
}

// Create delta: list add operation
string deltaListAdd(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_add",
        "key", key,
        "elem", elem
    ]);
}

// Create delta: list remove operation
string deltaListRemove(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_remove",
        "key", key,
        "elem", elem
    ]);
}

// Apply delta to settings
applyDelta(string payload) {
    if (!jsonHas(payload, ["op"])) return;

    string op = llJsonGetValue(payload, ["op"]);

    if (op == "set") {
        string key = llJsonGetValue(payload, ["key"]);
        string value = llJsonGetValue(payload, ["value"]);
        // Apply set operation
    }
    else if (op == "list_add") {
        string key = llJsonGetValue(payload, ["key"]);
        string elem = llJsonGetValue(payload, ["elem"]);
        // Apply list add operation
    }
    else if (op == "list_remove") {
        string key = llJsonGetValue(payload, ["key"]);
        string elem = llJsonGetValue(payload, ["elem"]);
        // Apply list remove operation
    }
}
```

---

## Usage Examples

### Sending Messages

```lsl
// Registration (full JSON)
llMessageLinked(LINK_SET, KERNEL_LIFECYCLE,
    kanbanCreateSimple("bell", "kernel", [
        "label", "Bell",
        "min_acl", 1,
        "script", llGetScriptName()
    ]),
    NULL_KEY
);

// Settings delta (efficient update)
llMessageLinked(LINK_SET, SETTINGS_BUS,
    kanbanBroadcast("settings", deltaSet("bell_visible", "1")),
    NULL_KEY
);

// ACL query
llMessageLinked(LINK_SET, AUTH_BUS,
    kanbanCreateSimple("bell", "auth", [
        "avatar", (string)user
    ]),
    user
);
```

### Receiving Messages

```lsl
link_message(integer sender, integer num, string msg, key id) {
    // Validate Kanban structure
    if (!kanbanIsValid(msg)) return;

    // Check if message is for me
    if (!kanbanIsForMe(msg, "bell")) return;

    // Extract sender and payload
    string from = kanbanGetFrom(msg);
    string payload = kanbanGetPayload(msg);

    // Route by sender and channel
    if (num == AUTH_BUS && from == "auth") {
        handleAclResult(payload);
    }
    else if (num == SETTINGS_BUS && from == "settings") {
        handleSettingsUpdate(payload);
    }
    else if (num == DIALOG_BUS && from == "dialogs") {
        handleDialogResponse(payload);
    }
}
```

---

## Migration Strategy

### Phase 1: Create Helper Library
1. Create `ds_collar_kanban_helpers.lsl` include file
2. Add all helper functions
3. Test with isolated module

### Phase 2: Pilot Implementation
1. **Pick one module**: HUD communication (most complex routing)
2. Refactor to use Kanban packets
3. Test thoroughly
4. Document lessons learned

### Phase 3: Gradual Migration
1. Migrate external communication first (HUD ↔ Collar)
2. Migrate complex modules (leash, dialogs, settings)
3. Migrate simple plugins last
4. Keep backward compatibility during transition

### Phase 4: Full Adoption
1. Update all modules
2. Remove old "type" field handling
3. Simplify message routing logic
4. Update documentation

---

## Benefits

### 1. **Consistency**
- Every message has same structure
- No confusion about "avatar" vs "user" vs "from"
- Easier code review and debugging

### 2. **Routing Clarity**
- Clear sender/recipient in every message
- Can filter/log by from/to fields
- Easier to trace message flows

### 3. **Efficiency**
- Delta payloads reduce data transfer
- No duplicate context information
- "type" implied by routing, not explicit field

### 4. **Debugging**
- Can log all from/to pairs
- Message flow visualization easier
- Clear responsibility boundaries

### 5. **Security**
- Sender clearly identified
- Can validate "from" matches script
- Easier to implement authorization checks

---

## Comparison: Memory Overhead

### Current Message (60 characters)
```json
{"type":"register","context":"bell","label":"Bell","min_acl":1}
```

### Kanban Message (73 characters)
```json
{"from":"bell","payload":{"label":"Bell","min_acl":1},"to":"kernel"}
```

**Overhead: ~13 characters (~20%)**
- Trade-off: Small memory increase for major clarity improvement
- Delta payloads can offset this (delta is more efficient than full sync)

---

## Memory Costs

**See KANBAN_MEMORY_ANALYSIS.md for detailed analysis.**

### Quick Summary

**Message Overhead:**
- ~15-20 bytes per message (+10-15% size increase)
- Temporary memory - released immediately after processing
- Not cumulative - negligible impact

**Helper Library Overhead:**
- Minimal: ~1-2KB (basic functions only)
- Standard: ~3-4KB (includes delta helpers)
- Full: ~6KB (all convenience functions)

**Breakeven Analysis:**

| Script Type | Messages | Recommendation | Net Impact |
|-------------|----------|----------------|------------|
| Tiny plugin | 1-5 | Skip Kanban | Save ~2KB |
| Small plugin | 5-15 | Use minimal | +1KB |
| Medium plugin | 15-25 | Use standard | +0.5KB |
| Large plugin | 25+ | Use full | -1KB (saves!) |
| Core module | 30+ | Use full | -3KB (saves!) |

**Verdict:** Memory costs are acceptable. Large/complex scripts actually SAVE memory due to reduced boilerplate. Choose appropriate helper tier for your needs.

---

## Helper Library Tiers

Three levels of helper libraries to match your memory constraints:

### 1. Minimal (`ds_collar_kanban_minimal.lsl`) - ~1-2KB
- Core packet creation and parsing only
- For simple plugins or memory-constrained scripts
- Manual payload construction

### 2. Standard (`ds_collar_kanban_standard.lsl`) - ~3-4KB
- All minimal functions
- Delta helpers (deltaSet, deltaListAdd, etc.)
- Routing helpers (isForMe, isFrom)
- Payload access (payloadGet, payloadHas)
- **Recommended for most plugins**

### 3. Full (`ds_collar_kanban_helpers.lsl`) - ~6KB
- All standard functions
- Convenience functions (kanbanSendRegistration, kanbanQueryAcl, etc.)
- For complex plugins and core modules
- Maximum code reuse

---

## Open Questions

1. **Should "type" be retained in payload for some messages?**
   - Pro: Explicit operation identification
   - Con: Redundant with from/to routing
   - **Recommendation**: No, use from/to + channel for routing

2. **How to handle correlation IDs?**
   - Option A: Add "id" at top level (from, payload, to, id)
   - Option B: Keep "id" inside payload
   - **Recommendation**: Inside payload (keeps 3-field structure)

3. **Broadcasting to multiple specific recipients?**
   - Current: `to: ""`  broadcasts to all
   - Future: `to: ["bell", "leash", "owner"]` for multi-cast?
   - **Recommendation**: Start with broadcast only, add multi-cast if needed

4. **Backward compatibility during transition?**
   - Support both old and new formats?
   - How long to maintain dual support?
   - **Recommendation**: 2-phase migration with feature flag

---

## Recommendation

**Proceed with Kanban messaging system:**

1. ✅ **Simple**: 3 fields only (from, payload, to)
2. ✅ **Flexible**: Supports both full JSON and delta JSON
3. ✅ **Clear**: Routing is explicit, not inferred
4. ✅ **Efficient**: Delta payloads reduce overhead
5. ✅ **Maintainable**: Standardized structure across all messages

**Start with external HUD communication** as proof-of-concept, then gradually migrate internal messaging.
