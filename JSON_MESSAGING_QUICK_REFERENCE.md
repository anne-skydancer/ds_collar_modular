# JSON Messaging - Quick Reference Guide

## Key Files & Their Roles

### Core Messaging Hub
- **kernel.lsl** (Channel 500) - Central registry, plugin lifecycle management
  - Broadcasts: `register_now`, `ping`, `plugin_list`, `soft_reset`
  - Receives: `register`, `pong`, `plugin_list_request`

- **kmod_auth.lsl** (Channel 700) - Access control engine
  - Broadcasts: `acl_result` (with 12+ policy fields)
  - Receives: `acl_query`, `settings_sync`

- **kmod_settings.lsl** (Channel 800) - Persistent key-value store
  - Broadcasts: `settings_sync`, `settings_delta`
  - Receives: `settings_get`, all modification requests

- **kmod_dialogs.lsl** (Channel 950) - Dialog system
  - Broadcasts: `dialog_timeout`, `dialog_response`
  - Receives: `dialog_open`, `dialog_close`

### Feature-Specific Modules
- **kmod_leash.lsl** (Channels 700, 800, 900) - Leashing engine
  - Sends: `leash_action`, receives `leash_state`, `offer_pending`
  - Protocols: Lockmeister (-8888), DS Holder (-192837465)

- **kmod_remote.lsl** (External channels) - HUD bridge
  - Discovery: -8675309/-8675310
  - Session-based: -8675320 + derived offset
  - Handles: collar discovery, ACL queries, menu requests

- **control_hud.lsl** (External) - Control HUD script
  - Two-phase protocol: discovery → session establishment
  - Uses derived session channels for security

## Message Flow Diagram

```
┌─────────────────────────────────────────────┐
│  External HUD (control_hud.lsl)             │
│  Phase 1: Public channels (-8675309/-10)   │
│  Phase 2: Derived session channels          │
└────────────┬────────────────────────────────┘
             │ collar_scan / acl_query_external
             │ menu_request_external
             │
┌────────────▼─────────────────────────────────────────┐
│  DS Collar Object                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │ kmod_remote.lsl (Channel 700, 900)           │   │
│  │ • Handles external HUD communication          │   │
│  │ • Bridge to internal systems                  │   │
│  └───┬──────────────────────┬────────────────────┘   │
│      │                      │                        │
│      │ llMessageLinked      │ llMessageLinked        │
│      │ (channel 700)        │ (channel 900)          │
│      │                      │                        │
│  ┌───▼───────────────────┐  │  ┌──────────────────┐  │
│  │ kmod_auth.lsl (700)   │  │  │ kmod_ui.lsl (900)│  │
│  │ • ACL computation     │  │  │ • Menu display   │  │
│  │ • Policy decisions    │  │  │ • Dialog mgmt    │  │
│  │ • Role validation     │  │  └────────┬─────────┘  │
│  └───┬─────────────┬─────┘  │           │            │
│      │             │        │  ┌────────▼──────────┐ │
│      │ llMsg (700) │        │  │kmod_dialogs(950)   │ │
│      │             │        │  │• Session mgmt      │ │
│  ┌───▼──────────────────────┼──┤• Listener control  │ │
│  │ kmod_settings.lsl (800)  │  └────────┬───────────┘ │
│  │ • Persistent storage     │           │             │
│  │ • Settings delta         │    llListen on          │
│  │ • Notecard loading       │    dynamic channels     │
│  └──────────────────────────┘                        │
│                                                       │
│  ┌──────────────────────────────────────────────┐   │
│  │ ds_collar_kernel.lsl (500)                    │   │
│  │ • Plugin registry                             │   │
│  │ • Heartbeat management                        │   │
│  │ Connects to: all plugins                      │   │
│  └──────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

## Channel Reference Table

| Channel | Type | Purpose | Max | Used By |
|---------|------|---------|-----|---------|
| 500 | LINK | Kernel lifecycle | 100+ | kernel + all plugins |
| 700 | LINK | ACL queries | 50 | plugins, kmod_remote |
| 800 | LINK | Settings ops | unbounded | all, kmod_settings |
| 900 | LINK | UI commands | 100+ | modules, kmod_ui |
| 950 | LINK | Dialog system | 10 | plugins, kmod_dialogs |
| -8675309 | EXTERNAL | Collar discovery broadcast | N/A | HUDs → Collars |
| -8675310 | EXTERNAL | Collar response to discovery | N/A | Collars → HUDs |
| -8675320+offset | EXTERNAL | Session query | Per pair | HUD-collar pairs |
| -8888 | EXTERNAL | Lockmeister protocol | N/A | Leash ↔ Objects |
| -192837465 | EXTERNAL | DS Holder protocol | N/A | Leash ↔ Objects |

## Message Routing Examples

### User Checks Bell Settings (7 step flow)
```
1. Plugin sends: acl_query (700)
   → Auth module checks wearer/owner/trustees/blacklist
2. Auth responds: acl_result (700) with ACL level
3. If ACL_PUBLIC+: Plugin sends dialog_open (950)
4. Dialog manager creates session, sends to Dialog module
5. Dialog displays llDialog on DIALOG_CHANNEL
6. User clicks button → Dialog manager collects response
7. Dialog manager sends dialog_response (950) to plugin
```

### User Leashes Target Avatar (6 step flow)
```
1. Plugin receives dialog response: button clicked
2. Plugin sends: leash_action with target (900)
3. kmod_leash verifies ACL via acl_query (700)
4. If allowed: sends leash_req to holder object (-192837465)
5. Holder responds: leash_target
6. kmod_leash sends leash_state update (900) to plugin
```

### External User Controls Collar via HUD (9 step flow)
```
1. HUD sends collar_scan on -8675309
2. Collar responds on -8675310
3. HUD sends session_establish on -8675309
4. Collar derives session channels, acknowledges
5. HUD sends acl_query_external on SESSION_QUERY_CHAN
6. Collar's kmod_remote sends acl_query (700) internally
7. Auth responds acl_result (700)
8. Collar sends acl_result_external on SESSION_REPLY_CHAN
9. If access granted: HUD sends menu_request_external
10. Collar triggers UI via kmod_ui ("start" message on 900)
```

## Payload Patterns by Category

### Minimal Messages (just type)
```json
{"type": "register_now"}
{"type": "ping"}
{"type": "pong"}  // Just type + context
{"type": "soft_reset"}  // + from field
```

### Query Messages (type + single field)
```json
{"type": "acl_query", "avatar": "uuid"}
{"type": "settings_get"}
{"type": "plugin_list_request"}
```

### Response Messages (type + result fields)
```json
{"type": "acl_result", "avatar": "uuid", "level": 3, "is_wearer": 0, ...12 more fields...}
{"type": "settings_sync", "kv": {entire JSON settings object}}
{"type": "plugin_list", "plugins": [{obj}, {obj}, ...]}
```

### State Update Messages (comprehensive state dump)
```json
{"type": "settings_delta", "op": "set", "changes": {"key": "value"}}
{"type": "leash_state", "leashed": 1, "leasher": "uuid", "length": 3, "mode": 0, "target": "uuid"}
{"type": "dialog_response", "session_id": "bell_1730450123", "user": "uuid", "button_index": 2, "button_text": "Save"}
```

### Action Request Messages (command + parameters)
```json
{"type": "leash_action", "action": "grab", "target": "uuid"}
{"type": "dialog_open", "session_id": "id", "user": "uuid", "title": "...", "body": "...", "buttons": [...], "timeout": 60}
{"type": "menu_request_external", "avatar": "uuid"}
```

## Common Patterns

### Correlation IDs
```lsl
// Request with ID
llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
    "type", "acl_query",
    "avatar", user,
    "id", "correlation_" + (string)llGetUnixTime()
]), user);

// Response includes ID
msg = llJsonSetValue(msg, ["id"], correlation_id);
```

### Session Management
```lsl
// Timeout tracking
session_data = [session_id, user_key, channel, listen_handle, timeout_unix];
// Prune expired in timer() event
```

### Delta Updates (avoid sending full state)
```json
{"type": "settings_delta", "op": "set", "changes": {"single_key": "value"}}
{"type": "settings_delta", "op": "list_add", "key": "trustees", "elem": "uuid"}
{"type": "settings_delta", "op": "list_remove", "key": "blacklist", "elem": "uuid"}
```

### Safe Defaults
```lsl
// All handlers check type first
if (!jsonHas(msg, ["type"])) return;
string msg_type = llJsonGetValue(msg, ["type"]);
if (msg_type != "expected_type") return;

// All value retrievals check for JSON_INVALID
string val = llJsonGetValue(msg, ["field"]);
if (val == JSON_INVALID) use_default;
```

## Implementation Checklist for New Features

- [ ] Choose channel (or define new one)
- [ ] Define message types (in comments at top of script)
- [ ] Create helper function: sendMyMessage()
- [ ] Create handler function: handleMyMessage()
- [ ] Add to link_message event dispatcher
- [ ] For queries: add correlation_id support
- [ ] For dialogs: manage session in kmod_dialogs
- [ ] For external: use llRegionSay/llRegionSayTo
- [ ] Add rate limiting if high frequency
- [ ] Test with security checks (ACL, ownership, etc.)

