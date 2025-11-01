# DS Collar Modular - JSON Messaging Comprehensive Analysis

## Overview
The DS Collar system uses a sophisticated JSON-based messaging architecture with two distinct communication layers:
1. **Internal (Link Messages)** - Between scripts in the same object
2. **External (Listen/Say)** - Between different objects (HUD and collar)

---

## JSON Functions Used

### Creating JSON
- `llList2Json(JSON_OBJECT, list)` - Create JSON objects from key-value lists
- `llList2Json(JSON_ARRAY, list)` - Create JSON arrays from lists
- Examples:
  ```lsl
  llList2Json(JSON_OBJECT, ["type", "register", "context", "bell"])
  llList2Json(JSON_ARRAY, ["value1", "value2", "value3"])
  ```

### Parsing JSON
- `llJsonGetValue(json_str, path)` - Extract values using path arrays
- `llJson2List(json_str)` - Convert JSON arrays to lists
- Examples:
  ```lsl
  llJsonGetValue(msg, ["type"])                    // Get top-level field
  llJsonGetValue(settings, ["settings", "leash"])  // Nested path
  llJson2List(owner_array)                         // Convert array to list
  ```

### Modifying JSON
- `llJsonSetValue(json_str, path, value)` - Set/update values in JSON
- `llJsonValueType(json_str, path)` - Check value type

### Helper Functions
- `jsonHas(json, path)` - Check if path exists (returns true if value != JSON_INVALID)

---

## Communication Channels

### Internal Communication (Link Messages via llMessageLinked)

| Channel | Name | Purpose | Usage |
|---------|------|---------|-------|
| 500 | KERNEL_LIFECYCLE | Plugin registration, heartbeat, lifecycle | Kernel ↔ All plugins |
| 700 | AUTH_BUS | ACL queries and responses | Plugins ↔ Auth module |
| 800 | SETTINGS_BUS | Settings sync and delta updates | Plugins ↔ Settings module |
| 900 | UI_BUS | UI commands (menus, dialogs, effects) | Modules ↔ UI components |
| 950 | DIALOG_BUS | Dialog system operations | Plugins ↔ Dialog manager |

### External Communication (Listen/Say - llRegionSay & llRegionSayTo)

| Channel | Name | Purpose | Direction |
|---------|------|---------|-----------|
| -8675309 | PUBLIC_DISCOVERY_CHAN | Collar discovery broadcasts | HUD → All collars (broadcast) |
| -8675310 | PUBLIC_DISCOVERY_REPLY_CHAN | Collar responses to discovery | Collar → All HUDs (broadcast) |
| -8675320 + offset | SESSION_BASE_CHAN | Derived per-session channels | HUD ↔ Collar (derived) |
| -8000000 + offset | DIALOG channels | Dynamic dialog listener channels | Dialog system (internal) |
| -8888 | LEASH_CHAN_LM | Lockmeister/OpenCollar protocol | Leash ↔ Holder objects |
| -192837465 | LEASH_CHAN_DS | DS Holder protocol | Leash ↔ DS Holder objects |

#### Session Channel Derivation
```lsl
integer deriveSessionChannel(integer base_channel, key hud_wearer, key collar_owner) {
    integer seed1 = (integer)("0x" + llGetSubString((string)hud_wearer, 0, 7));
    integer seed2 = (integer)("0x" + llGetSubString((string)collar_owner, 0, 7));
    integer combined = (seed1 ^ seed2);  // XOR for uniqueness
    return base_channel + (combined % 1000000);
}
```
Creates unique per-session channels:
- Query channel: derived from SESSION_BASE_CHAN
- Reply channel: Query - 1
- Menu channel: Query - 2

---

## Message Types (43 total)

### Lifecycle Messages
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `register` | Plugin → Kernel | context, label, min_acl, script | Plugin registration |
| `register_now` | Kernel → Plugins | type | Request all plugins register |
| `pong` | Plugin → Kernel | type, context | Heartbeat response |
| `ping` | Kernel → Plugins | type | Heartbeat ping |
| `soft_reset` | Kernel → Modules | type, from | Soft reset with authorization |

### Plugin List Management
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `plugin_list_request` | Any → Kernel | type | Request registered plugins |
| `plugin_list` | Kernel → All | type, plugins (array) | List of registered plugins |

### ACL (Access Control) Messages
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `acl_query` | Plugin → Auth | type, avatar | Query ACL level for avatar |
| `acl_result` | Auth → Plugin | type, avatar, level, is_wearer, is_blacklisted, owner_set, policy_* | ACL response with policies |
| `acl_query_external` | HUD → Collar | type, avatar, hud, target_avatar | External ACL query from HUD |
| `acl_result_external` | Collar → HUD | type, avatar, level, collar_owner | External ACL response |

### Settings Messages
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `settings_get` | Module → Settings | type | Request full settings sync |
| `settings_sync` | Settings → All | type, kv (JSON object) | Full settings broadcast |
| `settings_delta` | Settings → All | type, op (set/list_add/list_remove), changes/key/elem | Incremental settings update |

### Dialog Messages
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `dialog_open` | Plugin → Dialog | type, session_id, user, title, body, buttons (array), timeout | Open dialog for user |
| `dialog_response` | Dialog → Plugin | type, session_id, user, button_index, button_text | User's dialog response |
| `dialog_timeout` | Dialog → Plugin | type, session_id, user | Dialog timed out |
| `dialog_close` | Plugin → Dialog | type, session_id | Close dialog session |

### Leash-Specific Messages
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `leash_action` | Plugin → Kernel | type, action (grab/pass/offer/yank/release), target, ... | Leash action request |
| `leash_state` | Kernel → Plugin | type, leashed, leasher, length, turnto, mode, target | Leash state update |
| `leash_req` | Kernel → Holder | type, controller | Leash request to holder |
| `leash_target` | Holder → Kernel | type, ok, session, holder, name | Holder response |
| `offer_pending` | Kernel → Plugin | type, target, originator | Leash offer notification |

### Particle/Visual Effects Messages
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `particles_start` | Kernel → UI | type, source, target, style | Start particle effects |
| `particles_stop` | Kernel → UI | type, source | Stop particle effects |
| `particles_update` | Kernel → UI | type, target | Update particle target |

### Lockmeister/OpenCollar Protocol
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `lm_enable` | Kernel → Holder | type, controller | Enable Lockmeister control |
| `lm_disable` | Kernel → Holder | type | Disable Lockmeister control |
| `lm_grabbed` | Holder → Kernel | type | Leash grabbed event |
| `lm_released` | Holder → Kernel | type | Leash released event |

### HUD/Remote Control Messages
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `collar_scan` | HUD → Collar | type, hud_wearer | Discovery broadcast |
| `collar_scan_response` | Collar → HUD | type, collar_owner | Discovery response |
| `session_establish` | HUD → Collar | type, hud_wearer, collar_owner, session_query/reply/menu | Session setup |
| `session_established_ack` | Collar → HUD | type | Session acknowledgment |
| `menu_request_external` | HUD → Collar | type, avatar | Request to open menu |

### Utility Messages
| Type | Direction | Payload | Purpose |
|------|-----------|---------|---------|
| `start` | Remote → UI | type, context | Start menu for context |
| `set` | Settings → Plugins | type, ... | Generic set operation |
| `update_label` | Any → Kernel | type, context, label | Update plugin label |
| `return` | UI → Requester | type, data | Generic return value |
| `list_add` | Settings → Consumers | type, key, elem | Add to list in settings |
| `list_remove` | Settings → Consumers | type, key, elem | Remove from list in settings |
| `sync_request` | Module → Settings | type | Request settings synchronization |
| `close` | Dialog → Session | type | Close session notification |

---

## Message Flow Examples

### Plugin Registration Flow
```
1. Kernel broadcasts: {"type": "register_now"}
2. Plugin sends: {"type": "register", "context": "bell", "label": "Bell", 
                   "min_acl": 1, "script": "ds_collar_plugin_bell"}
3. Kernel collects registrations (2s window)
4. Kernel broadcasts: {"type": "plugin_list", "plugins": [...]}
```

### ACL Query Flow (Internal)
```
1. Plugin sends: {"type": "acl_query", "avatar": "<user_uuid>"}
2. Auth module queries settings and computes level
3. Auth responds: {"type": "acl_result", "avatar": "<uuid>", "level": 3, 
                   "is_wearer": 0, "owner_set": 1, "policy_trustee_access": 1, ...}
```

### HUD Discovery & Control Flow
```
1. HUD broadcasts: {"type": "collar_scan", "hud_wearer": "<hud_uuid>"}
2. Collar responds: {"type": "collar_scan_response", "collar_owner": "<collar_owner_uuid>"}
3. HUD sends: {"type": "session_establish", "hud_wearer": "<hud_uuid>", 
               "collar_owner": "<owner>", "session_query": -8675432, ...}
4. Collar acknowledges: {"type": "session_established_ack"}
5. HUD sends: {"type": "acl_query_external", "avatar": "<hud_user>", ...}
6. Collar responds: {"type": "acl_result_external", "level": 5, ...}
7. HUD sends: {"type": "menu_request_external", "avatar": "<hud_user>"}
8. Collar triggers menu via: {"type": "start", "context": "core_root"}
```

### Settings Synchronization Flow
```
1. Module requests: {"type": "settings_get"}
2. Settings responds: {"type": "settings_sync", "kv": {full JSON object}}
3. On change: {"type": "settings_delta", "op": "set", "changes": {"key": "value"}}
4. Or for lists: {"type": "settings_delta", "op": "list_add", "key": "trustees", "elem": "<uuid>"}
```

### Leash Operation Flow
```
1. User triggers grab via UI
2. Plugin sends: {"type": "leash_action", "action": "grab", "target": "<target_uuid>"}
3. Kernel verifies ACL, then controls leash
4. Kernel updates state: {"type": "leash_state", "leashed": 1, "leasher": "<uuid>", 
                          "length": 3, "mode": 0}
5. If using holder object, kernel sends: {"type": "leash_req", "controller": "<uuid>"}
6. Holder responds: {"type": "leash_target", "ok": "1", "holder": "<holder_uuid>", "name": "..."}
```

---

## Data Structure Patterns

### ACL Levels (as JSON integers)
```
-1: BLACKLIST (explicitly denied)
 0: NOACCESS (no access, default)
 1: PUBLIC (when public mode enabled)
 2: OWNED (wearer when owner set)
 3: TRUSTEE (trustees list member)
 4: UNOWNED (wearer when no owner)
 5: PRIMARY_OWNER (owner)
```

### Settings Storage (KvJson)
- Stored as single flat JSON object with string keys
- Arrays stored as JSON arrays within the object
- Examples:
  ```json
  {
    "owner_key": "12345678-...",
    "owner_keys": ["uuid1", "uuid2"],
    "trustees": ["uuid3", "uuid4"],
    "leashed": "0",
    "leasher_key": "00000000-...",
    "leash_length": "3",
    "bell_visible": "1",
    "bell_sound": "16fcf579-82cb-b110-c1a4-5fa5e1385406"
  }
  ```

### Plugin Registry (internal list)
```
List stride of 5: [context, label, min_acl, script, last_seen_unix]
Example: ["bell", "Bell", 1, "ds_collar_plugin_bell", 1730450123]
```

---

## Security Features in JSON Messaging

1. **Authorization Checks**
   - ACL levels enforced for all operations
   - "from" field in soft_reset messages verified against whitelist
   - Correlation IDs for request/response matching

2. **Range Validation**
   - MAX_DETECTION_RANGE (20m) for HUD-collar distance
   - Max list lengths enforced (64 elements)
   - Pending query limits (50 for auth, 20 for remote)

3. **Rate Limiting**
   - 2s cooldown between requests per user
   - 5s cooldown between leash yanks
   - Query timeouts (30s for external, configurable for UI)

4. **Overflow Protection**
   - Y2038 timestamp checks
   - Integer overflow detection in timestamps
   - List size guards during JSON parsing

5. **Role Exclusivity Enforcement**
   - Owners cannot be trustees or blacklisted
   - Trustees cannot be blacklisted
   - Wearer cannot be in owner list

6. **Session Security**
   - Derived session channels use XOR of both UUIDs
   - Per-HUD-collar pair channels prevent crosstalk
   - Session timeouts (configurable, default 60s)

---

## Error Handling

JSON validation patterns:
```lsl
// Check if field exists
if (!jsonHas(msg, ["type"])) return;

// Get value with null check
string val = llJsonGetValue(msg, ["field"]);
if (val == JSON_INVALID) return;

// Type checking
if (llGetSubString(arr, 0, 0) == "[") { /* is array */ }
if (llGetSubString(obj, 0, 0) == "{") { /* is object */ }

// Safe default values
string kvGet(string key_name) {
    string val = llJsonGetValue(KvJson, [key_name]);
    if (val == JSON_INVALID) return "";
    return val;
}
```

---

## Files Using JSON Messaging

**Core Kernel Modules:**
- `/src/dev/ds_collar_kernel.lsl` - Plugin registry & lifecycle
- `/src/dev/ds_collar_kmod_auth.lsl` - ACL engine
- `/src/dev/ds_collar_kmod_settings.lsl` - Settings persistence
- `/src/dev/ds_collar_kmod_dialogs.lsl` - Dialog management
- `/src/dev/ds_collar_kmod_remote.lsl` - HUD communication bridge
- `/src/dev/ds_collar_kmod_leash.lsl` - Leashing engine
- `/src/dev/ds_collar_kmod_particles.lsl` - Visual effects
- `/src/dev/ds_collar_kmod_ui.lsl` - UI display logic
- `/src/dev/ds_collar_kmod_bootstrap.lsl` - Startup sequence

**UI/HUD:**
- `/src/dev/ds_collar_control_hud.lsl` - Control HUD (external)

**Plugins:**
- `/src/dev/ds_collar_plugin_*.lsl` - 16+ plugins (bell, leash, owner, blacklist, etc.)

**Objects:**
- `/src/dev/ds_collar_leash_holder.lsl` - Leash holder object

