# DS Collar JSON Messaging Analysis - Complete Documentation

This directory now contains comprehensive documentation of all JSON messaging patterns used in the DS Collar modular system.

## Documentation Files

### 1. JSON_MESSAGING_ANALYSIS.md (337 lines)
**Comprehensive Reference Guide** - START HERE

Contains:
- Complete JSON function reference (llList2Json, llJsonGetValue, llJsonSetValue, llJson2List)
- All communication channels (internal 500-950, external -8675309 to -192837465)
- All 43 message types documented in detail
- Message flow examples (registration, ACL queries, HUD discovery, settings sync, leash operations)
- Data structure patterns (ACL levels, settings JSON, plugin registry)
- Security features (authorization, range validation, rate limiting, overflow protection, session security)
- Error handling patterns
- Complete file listing

**Best for:** Understanding the big picture, security architecture, all message types

### 2. JSON_MESSAGING_QUICK_REFERENCE.md (330+ lines)
**Quick Navigation & Implementation Guide**

Contains:
- Key files and their roles (5 core modules, 3 feature modules)
- Message flow diagram (visual representation)
- Channel reference table (channel, type, purpose, usage)
- Three detailed message routing examples (bell settings, leash, external HUD control)
- Payload patterns by category (minimal, query, response, state, action messages)
- Common patterns (correlation IDs, session management, delta updates, safe defaults)
- Implementation checklist for new features

**Best for:** Quick lookups, adding new features, understanding message flow

### 3. JSON_MESSAGING_CODE_EXAMPLES.md (400+ lines)
**Real Code from the System**

Contains:
- JSON creation examples (simple objects, nested objects, arrays)
- JSON parsing examples (single values, field existence checking, default values, arrays, nested paths)
- JSON modification examples (set/update, settings, arrays)
- Complete message handler pattern
- Settings management (full sync, delta updates, consuming settings)
- External communication (discovery flow, session establishment, channel derivation)
- Dialog system examples (opening dialogs, handling responses)
- Leash-specific examples (actions, state updates, persistence)
- Error handling (null handling, type validation, authorization)
- Performance optimization (caching, delta updates, session pruning)

**Best for:** Learning by example, copy-paste reference, understanding real implementations

---

## Quick Start Guide

### For Understanding the System
1. Read: JSON_MESSAGING_ANALYSIS.md - Overview section
2. Read: JSON_MESSAGING_QUICK_REFERENCE.md - Message flow diagram
3. Reference: JSON_MESSAGING_ANALYSIS.md - Message types table

### For Adding a New Feature
1. Review: JSON_MESSAGING_QUICK_REFERENCE.md - Implementation checklist
2. Choose channel from: JSON_MESSAGING_ANALYSIS.md - Communication channels
3. Copy examples from: JSON_MESSAGING_CODE_EXAMPLES.md - Relevant section
4. Reference: JSON_MESSAGING_QUICK_REFERENCE.md - Common patterns

### For Debugging
1. Identify message type from: JSON_MESSAGING_ANALYSIS.md - Message types (43 total)
2. Find message flow in: JSON_MESSAGING_QUICK_REFERENCE.md - Message routing examples
3. Check code examples in: JSON_MESSAGING_CODE_EXAMPLES.md - Relevant operation
4. Verify security in: JSON_MESSAGING_ANALYSIS.md - Security features

---

## Key Statistics

- **Total Message Types:** 43
- **Internal Channels:** 5 (500, 700, 800, 900, 950)
- **External Channels:** 6+ (discovery, session, dialog, leash protocols)
- **Core Modules:** 9 kernel/core modules
- **Plugin Scripts:** 16+ feature plugins
- **JSON Functions Used:** 5 main (llList2Json, llJsonGetValue, llJsonSetValue, llJson2List, etc.)

---

## Message Type Summary

### By Category
- **Lifecycle:** 5 types (register, register_now, pong, ping, soft_reset)
- **Plugin List:** 2 types (plugin_list_request, plugin_list)
- **ACL:** 4 types (acl_query, acl_result, acl_query_external, acl_result_external)
- **Settings:** 3 types (settings_get, settings_sync, settings_delta)
- **Dialog:** 4 types (dialog_open, dialog_response, dialog_timeout, dialog_close)
- **Leash:** 5 types (leash_action, leash_state, leash_req, leash_target, offer_pending)
- **Particles:** 3 types (particles_start, particles_stop, particles_update)
- **Lockmeister:** 4 types (lm_enable, lm_disable, lm_grabbed, lm_released)
- **HUD/Remote:** 5 types (collar_scan, collar_scan_response, session_establish, session_established_ack, menu_request_external)
- **Utility:** 8+ types (start, set, update_label, return, list_add, list_remove, sync_request, close)

---

## Security Highlights

This system implements:
- **ACL verification** for all operations (6 ACL levels: -1 to 5)
- **Correlation IDs** for request/response matching
- **Rate limiting** (2s per user default, 5s for yanks)
- **Timeout management** (30s external, configurable UI)
- **Authorization checks** ("from" field validation, whitelist enforcement)
- **Range validation** (20m max distance for HUD-collar)
- **Overflow protection** (Y2038 timestamp checks)
- **Role exclusivity** (owners can't be trustees, etc.)
- **Session security** (derived channels via XOR of UUIDs)
- **Delta updates** (efficient incremental changes)

---

## Architecture Overview

```
External Layer (llRegionSay/llListen):
  HUD Discovery (-8675309/-8675310)
  Session Establishment (-8675320 + derived)
  Leash Holder Communication (-192837465, -8888)

Internal Layer (llMessageLinked):
  Kernel Registry (500)
  ACL Engine (700)
  Settings Store (800)
  UI Commands (900)
  Dialog System (950)
```

---

## Files Analyzed

### Core Modules
- ds_collar_kernel.lsl - Plugin registry
- ds_collar_kmod_auth.lsl - ACL engine
- ds_collar_kmod_settings.lsl - Settings persistence
- ds_collar_kmod_dialogs.lsl - Dialog management
- ds_collar_kmod_remote.lsl - HUD bridge
- ds_collar_kmod_leash.lsl - Leashing engine
- ds_collar_kmod_particles.lsl - Visual effects
- ds_collar_kmod_ui.lsl - UI display
- ds_collar_kmod_bootstrap.lsl - Startup

### External/HUD
- ds_collar_control_hud.lsl - Control HUD

### Plugins & Objects
- ds_collar_plugin_*.lsl - 16+ feature plugins
- ds_collar_leash_holder.lsl - Leash holder object

---

## Common Patterns

### Safe JSON Access
```lsl
if (!jsonHas(msg, ["field"])) return;
string val = llJsonGetValue(msg, ["field"]);
```

### Delta Updates
```lsl
{"type": "settings_delta", "op": "set", "changes": {"key": "value"}}
{"type": "settings_delta", "op": "list_add", "key": "trustees", "elem": "uuid"}
```

### Message Dispatch
```lsl
string msg_type = llJsonGetValue(msg, ["type"]);
if (msg_type == "expected") { handle(); }
```

### Session Management
```lsl
string session_id = context + "_" + (string)llGetUnixTime();
// Store: [session_id, user_key, channel, listen_handle, timeout_unix]
```

---

## Troubleshooting Guide

| Issue | Check |
|-------|-------|
| Message not received | Verify channel number (500-950 for internal) |
| JSON parsing fails | Verify message has "type" field, use jsonHas() |
| Security rejection | Check ACL level, authorization field, range |
| Performance lag | Use delta updates instead of full sync |
| Session conflicts | Ensure unique session IDs, proper cleanup |
| Dialog not showing | Verify dialog_open sent to DIALOG_BUS (950) |

---

## Related Files

- `/src/dev/` - Development source code (all .lsl files)
- `/src/stable/` - Stable release versions

---

## Document Generation Date
Generated through comprehensive analysis of entire codebase.

## Contact & Updates
For questions about JSON messaging patterns, refer to the three documentation files in order of need.
