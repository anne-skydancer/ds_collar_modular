# DS Collar - Next Generation (NG) Branch

## Version 4.00 - Kanban Messaging System

This directory contains the **next generation** implementation of the DS Collar modular system, featuring the **Kanban messaging architecture**.

### Versioning Scheme

- **v4.00** - Starting version (Kanban messaging system)
- **Fixes** - No version change (bug fixes, corrections)
- **Enhancements** - +0.01 increment (4.00 → 4.01)
- **Major improvements** - +0.1 increment (4.00 → 4.10)
- **Complete overhauls** - +1.0 increment (4.00 → 5.00)

## Status

**🚧 Under Development - Not for Production Use**

This is an active migration branch where we are converting from the legacy message format (v3.x) to the new Kanban packet format (v4.00).

---

## What's Different?

### Legacy Message Format (stable/dev)
```lsl
llMessageLinked(LINK_SET, 500, llList2Json(JSON_OBJECT, [
    "type", "register",
    "context", "bell",
    "label", "Bell",
    "min_acl", 1,
    "script", llGetScriptName()
]), NULL_KEY);
```

### Kanban Message Format (ng)
```lsl
kSend("bell", "kernel", 500,
    kPayload(["label", "Bell", "min_acl", 1, "script", llGetScriptName()]),
    NULL_KEY
);
```

**All messages use standardized structure:**
```json
{
  "from": "sender_context",
  "payload": { /* message data */ },
  "to": "recipient_context"
}
```

---

## Kanban Messaging System

### The Universal Helper (~500-800 bytes)

**Two functions handle ALL messaging:**

```lsl
kSend(from, to, channel, payload, key)  // Send any message
kRecv(msg, my_context)                   // Receive and parse any message
```

**Optional payload builders:**
```lsl
kPayload(list)           // Simple key-value payload
kDeltaSet(key, val)      // Delta SET operation
kDeltaAdd(key, elem)     // Delta LIST_ADD operation
kDeltaDel(key, elem)     // Delta LIST_REMOVE operation
```

### Benefits

✅ **Memory efficient**: Saves 4-7KB per script vs legacy
✅ **Consistent**: Same 3-field structure for all messages
✅ **Simple**: ONE function for all outbound messages
✅ **Flexible**: Handles full JSON and delta JSON seamlessly
✅ **Debuggable**: Clear from/to routing in every message

---

## Migration Plan

### Phase 1: Core Modules (Priority)
- [ ] ds_collar_kernel.lsl
- [ ] ds_collar_kmod_auth.lsl
- [ ] ds_collar_kmod_settings.lsl
- [ ] ds_collar_kmod_dialogs.lsl

### Phase 2: Feature Modules
- [ ] ds_collar_kmod_ui.lsl
- [ ] ds_collar_kmod_remote.lsl
- [ ] ds_collar_kmod_leash.lsl
- [ ] ds_collar_kmod_particles.lsl
- [ ] ds_collar_kmod_bootstrap.lsl

### Phase 3: Plugins (15 total)
- [ ] ds_collar_plugin_bell.lsl
- [ ] ds_collar_plugin_owner.lsl
- [ ] ds_collar_plugin_blacklist.lsl
- [ ] ds_collar_plugin_leash.lsl
- [ ] ds_collar_plugin_status.lsl
- [ ] ds_collar_plugin_animate.lsl
- [ ] ds_collar_plugin_lock.lsl
- [ ] ds_collar_plugin_maintenance.lsl
- [ ] ds_collar_plugin_public.lsl
- [ ] ds_collar_plugin_rlvexceptions.lsl
- [ ] ds_collar_plugin_rlvrelay.lsl
- [ ] ds_collar_plugin_rlvrestrict.lsl
- [ ] ds_collar_plugin_sos.lsl
- [ ] ds_collar_plugin_tpe.lsl

### Phase 4: External
- [ ] ds_collar_control_hud.lsl
- [ ] ds_collar_leash_holder.lsl

---

## File Inventory

**Total files:** 26 LSL scripts + 1 helper library

**Breakdown:**
- Core modules: 4 (kernel, auth, settings, dialogs)
- Feature modules: 5 (ui, remote, leash, particles, bootstrap)
- Plugins: 15 (bell, owner, blacklist, animate, lock, etc.)
- External: 2 (HUD, leash holder)
- Helper reference: 1 (ds_collar_kanban_universal.lsl) - Used as copy template ✅

**Note**: LSL does not support includes, so the ~500-800 byte helper block is embedded directly in each script.

---

## Development Guidelines

### 1. Embed the Kanban Helper Functions

**IMPORTANT**: LSL does not support includes. The Kanban helper functions (~500-800 bytes) must be copied directly into each script.

Add this block near the top of every script (after constants):

```lsl
/* ===== KANBAN MESSAGING HELPERS (v4.00) ===== */

string kFrom = "";
string kTo = "";

kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, ["from", from, "payload", payload, "to", to]),
        k
    );
}

string kRecv(string msg, string my_context) {
    if (llGetSubString(msg, 0, 0) != "{") return "";
    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";
    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";
    if (to != "" && to != my_context) return "";
    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";
    kFrom = from;
    kTo = to;
    return payload;
}

string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

string kDeltaSet(string key, string val) {
    return llList2Json(JSON_OBJECT, ["op", "set", "key", key, "value", val]);
}

string kDeltaAdd(string key, string elem) {
    return llList2Json(JSON_OBJECT, ["op", "list_add", "key", key, "elem", elem]);
}

string kDeltaDel(string key, string elem) {
    return llList2Json(JSON_OBJECT, ["op", "list_remove", "key", key, "elem", elem]);
}

/* ===== END KANBAN HELPERS ===== */
```

### 2. Define Your Context and Version

```lsl
string CONTEXT = "bell";           // Your plugin/module context name
string VERSION = "4.00";           // Version number
```

### 3. Send Messages

```lsl
// Registration
kSend(CONTEXT, "kernel", 500,
    kPayload(["label", "Bell", "min_acl", 1]),
    NULL_KEY
);

// Settings delta
kSend(CONTEXT, "", 800,
    kDeltaSet("bell_visible", "1"),
    NULL_KEY
);
```

### 4. Receive Messages

```lsl
link_message(integer sender, integer num, string msg, key id) {
    string payload = kRecv(msg, CONTEXT);
    if (payload == "") return;

    // Route by channel + kFrom
    if (num == 700 && kFrom == "auth") {
        handleAuth(payload);
    }
}
```

---

## Testing Strategy

1. **Unit testing**: Each migrated script tested independently
2. **Integration testing**: Test message flows between modules
3. **Compatibility testing**: Ensure delta and full JSON work together
4. **Performance testing**: Verify memory savings and no performance regression
5. **Regression testing**: All existing features must continue to work

---

## Documentation References

See root directory:
- `KANBAN_UNIVERSAL_APPROACH.md` - Complete guide with examples
- `KANBAN_MESSAGING_PROPOSAL.md` - Original design specification
- `KANBAN_MEMORY_ANALYSIS.md` - Memory cost analysis
- `KANBAN_PROOF_OF_CONCEPT.md` - Side-by-side comparisons

---

## Migration Status

**Last Updated:** 2025-11-01

| Category | Files | Migrated | % Complete |
|----------|-------|----------|------------|
| Core Modules | 4 | 0 | 0% 🚧 |
| Feature Modules | 5 | 0 | 0% 🚧 |
| Plugins | 15 | 0 | 0% 🚧 |
| External | 2 | 0 | 0% 🚧 |
| **Total Scripts** | **26** | **0** | **0%** |

**Helper Template**: ds_collar_kanban_universal.lsl available as reference (functions embedded in each script)

---

## Contributing

When migrating a script:

1. **Start from stable baseline** (already copied to ng/)
2. **Update header** - Set version to "4.00", add Kanban note
3. **Embed Kanban helpers** - Copy the helper block (~500-800 bytes) after constants
4. **Define CONTEXT** - Add `string CONTEXT = "scriptname";` constant
5. **Define VERSION** - Add `string VERSION = "4.00";` constant
6. **Convert all outbound messages** to use `kSend()`
7. **Convert all inbound parsing** to use `kRecv()`
8. **Test thoroughly** - all existing functionality must work
9. **Update migration status** in this README
10. **Commit with clear message** - "migrate [script] to Kanban v4.00"

---

## Notes

- **Backward compatibility**: NG scripts will NOT be compatible with stable/dev
- **Complete migration required**: All scripts must be migrated together
- **Testing environment needed**: Test in isolated environment before production
- **Memory benefits compound**: More scripts migrated = more savings

---

## Questions?

See documentation in root directory or ask the maintainer.

**This is the future of DS Collar messaging!** 🚀
