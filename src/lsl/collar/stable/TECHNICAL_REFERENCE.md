# Technical Reference — D/s Collar Modular

Architecture and internals for developers working on or extending the collar system.

**System version:** 1.1 (all scripts at v1.10)

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Message Bus (ABI)](#message-bus-abi)
3. [Kernel and Plugin Lifecycle](#kernel-and-plugin-lifecycle)
4. [ACL Engine](#acl-engine)
5. [LSD Policy System](#lsd-policy-system)
6. [Settings System](#settings-system)
7. [Dialog System](#dialog-system)
8. [UI Session Flow](#ui-session-flow)
9. [Leash Engine](#leash-engine)
10. [RLV Relay](#rlv-relay)
11. [Persistence Model](#persistence-model)
12. [Security Measures](#security-measures)
13. [Writing a Plugin](#writing-a-plugin)
14. [Script Inventory](#script-inventory)

---

## Architecture Overview

The collar follows a **kernel + module + plugin** architecture. All inter-script communication uses `llMessageLinked` on five numbered channels (the "message bus"). Messages are JSON objects with a `type` field used for dispatch.

```
┌───────���────────────────────────���────────────────────┐
│                    collar_kernel                     │
│         Plugin registry, heartbeat, lifecycle        │
└────────────────────────┬────────────────────────────┘
                         │ KERNEL_LIFECYCLE (500)
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   ┌─────────┐    ┌───────────┐    ┌───────────┐
   │ Modules  │    │  Plugins  │    │  Plugins  │
   │ (kmod_*) │    │ (plugin_*)│    │ (plugin_*)│
   └─────────┘    └───────────┘    └─────��─────┘
        │                │                │
        └────────────────┼────────────────┘
              AUTH_BUS (700)
              SETTINGS_BUS (800)
              UI_BUS (900)
              DIALOG_BUS (950)
```

**Modules** (`kmod_*`) are headless system services — they have no menu presence and are always required. **Plugins** (`plugin_*`) are user-facing features that register with the kernel and appear in the menu.

---

## Message Bus (ABI)

All communication is via `llMessageLinked(LINK_SET, channel, json_payload, key)`.

| Channel | Constant | Purpose |
|---------|----------|---------|
| **500** | `KERNEL_LIFECYCLE` | Plugin registration, heartbeat (ping/pong), soft resets |
| **700** | `AUTH_BUS` | ACL queries and responses |
| **800** | `SETTINGS_BUS` | Key-value store operations (set, get, delta) |
| **900** | `UI_BUS` | Menu session control (start, return, close, show_message, render_menu, update_label, update_state) |
| **950** | `DIALOG_BUS` | Dialog rendering (dialog_open, dialog_close, dialog_response, dialog_timeout) |

### Message Format

Every message is a JSON object with at minimum a `type` field:

```lsl
llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
    "type", "acl_query",
    "avatar", (string)user_key
]), NULL_KEY);
```

### Channel 500 — KERNEL_LIFECYCLE

| Message Type | Direction | Purpose |
|-------------|-----------|---------|
| `register` | Plugin → Kernel | Register with context, label, script name |
| `ping` | Kernel → All | Heartbeat probe |
| `pong` | Plugin → Kernel | Heartbeat response |
| `register_now` | Kernel → All | Request immediate re-registration |
| `plugin_list` | Kernel → kmod_ui | Broadcast current plugin registry |
| `plugin_list_request` | kmod_ui → Kernel | Request current plugin registry |
| `soft_reset` | Authorized → All | Trigger soft reset of a specific plugin |
| `soft_reset_all` | Authorized → All | Trigger soft reset of all plugins |

**Registration payload:**
```json
{
    "type": "register",
    "context": "core_lock",
    "label": "Locked: N",
    "script": "plugin_lock.lsl"
}
```

### Channel 700 — AUTH_BUS

| Message Type | Direction | Purpose |
|-------------|-----------|---------|
| `acl_query` | Any → kmod_auth | Request ACL level for an avatar |
| `acl_result` | kmod_auth → All | ACL result with level and metadata |
| `acl_update` | kmod_auth → All | Broadcast that ACL roles have changed |

**Query:**
```json
{"type": "acl_query", "avatar": "<uuid>"}
```

**Response:**
```json
{
    "type": "acl_result",
    "avatar": "<uuid>",
    "level": 5,
    "is_wearer": 0,
    "is_blacklisted": 0,
    "owner_set": 1
}
```

The response always includes `is_wearer`, `is_blacklisted`, and `owner_set` fields. An optional `id` field is added if the query included a correlation ID.

### Channel 800 — SETTINGS_BUS

| Message Type | Direction | Purpose |
|-------------|-----------|---------|
| `set` | Any → kmod_settings | Write a key-value pair |
| `get` | Any → kmod_settings | Read a key |
| `delta` | kmod_settings → All | Broadcast a single setting change |

**Set:**
```json
{"type": "set", "key": "lock.locked", "value": "1"}
```

**Delta (broadcast):**
```json
{"type": "delta", "key": "lock.locked", "value": "1"}
```

### Channel 900 — UI_BUS

| Message Type | Direction | Purpose |
|-------------|-----------|---------|
| `start` | Any → kmod_ui | Open the main menu for a user |
| `return` | Plugin → kmod_ui | Return to parent menu |
| `close` | Plugin → kmod_ui | Close menus for a session |
| `show_message` | kmod_ui → kmod_menu | Send a status message to a user |
| `render_menu` | kmod_ui → kmod_menu | Render a menu page with button data |
| `update_label` | Plugin → kmod_ui | Update a plugin's menu label |
| `update_state` | Plugin → kmod_ui | Update a plugin's toggle state |

### Channel 950 — DIALOG_BUS

| Message Type | Direction | Purpose |
|-------------|-----------|---------|
| `dialog_open` | Plugin/kmod_menu → kmod_dialogs | Show a dialog to a user |
| `dialog_close` | Any → kmod_dialogs | Close a dialog by session ID |
| `dialog_response` | kmod_dialogs → All | User clicked a button |
| `dialog_timeout` | kmod_dialogs → All | Dialog timed out |

**dialog_open payload:**

`kmod_dialogs` accepts two button formats. Plugins typically use simple `buttons` arrays; `kmod_menu` sends structured `button_data`:

```json
{
    "type": "dialog_open",
    "session_id": "<id>",
    "user": "<uuid>",
    "title": "Leash Settings",
    "body": "Choose an option:",
    "buttons": ["Option A", "Option B", "Back"],
    "timeout": 60
}
```

Or with structured button data (used by `kmod_menu`):

```json
{
    "type": "dialog_open",
    "session_id": "<id>",
    "user": "<uuid>",
    "button_data": "<json array of button objects with context/label/state>",
    "timeout": 60
}
```

---

## Kernel and Plugin Lifecycle

### Startup Sequence

1. `collar_kernel.lsl` starts and sets a short batch timer
2. Plugins send `register` messages on channel 500
3. Kernel queues registrations and processes them in a batch (modprobe-style deduplication)
4. After the batch window, kernel broadcasts the plugin list to `kmod_ui`
5. Kernel switches to heartbeat mode (`PING_INTERVAL_SEC = 10.0`)

### Heartbeat

- Kernel broadcasts `ping` every 10 seconds
- Plugins respond with `pong` containing their context
- Plugins that miss pings for `PING_TIMEOUT_SEC` (30s) are pruned from the registry
- Kernel also sweeps inventory periodically to detect added/removed scripts

### Plugin Registry

The kernel maintains three parallel lists for O(1) lookups:

```lsl
list PluginRegistry = [];    // Stride: [context, label, script, script_uuid, last_seen_unix]
list PluginContexts = [];    // Parallel list for context lookups
list PluginScripts = [];     // Parallel list for script name lookups
```

Registration is deduplicated — if a plugin re-registers with the same context, its entry is updated (upsert).

### Registration Queue

Registrations are queued and batch-processed to handle startup bursts:

```lsl
list RegistrationQueue = [];  // Stride: [op_type, context, label, script, timestamp]
float BATCH_WINDOW_SEC = 0.1;
```

Operations are deduplicated by context at insertion time (newest wins).

---

## ACL Engine

Implemented in `kmod_auth.lsl`. The ACL engine is the single source of truth for access control.

### ACL Levels

| Level | Constant | Meaning |
|-------|----------|---------|
| -1 | `ACL_BLACKLIST` | Explicitly denied |
| 0 | `ACL_NOACCESS` | Wearer in TPE mode |
| 1 | `ACL_PUBLIC` | Any user (when public mode enabled) |
| 2 | `ACL_OWNED` | Wearer (when an owner is set) |
| 3 | `ACL_TRUSTEE` | Trusted users |
| 4 | `ACL_UNOWNED` | Wearer (when no owner is set) |
| 5 | `ACL_PRIMARY_OWNER` | Full administrative control |

### Evaluation Order

```
route_acl_query(avatar):
```

1. Check blacklist → return -1
2. Check if avatar is an owner → return 5
3. Check if avatar is the wearer:
   - TPE mode active → return 0
   - Owner exists → return 2
   - No owner → return 4
4. Check if avatar is a trustee → return 3
5. Check if public mode is active → return 1
6. Default (unauthorized stranger) → return -1 (uses `JSON_TEMPLATE_UNAUTHORIZED` with `ACL_BLACKLIST` level, `is_blacklisted: 0`)

**Note:** Unauthorized strangers receive level -1 with `is_blacklisted: 0`, distinguishing them from actually-blacklisted users who receive level -1 with `is_blacklisted: 1`. The `kmod_ui` session uses the `is_blacklisted` flag to show different denial messages.

### Caching

ACL query results are cached in linkset data with a 60-second TTL:

```lsl
string LSD_ACL_CACHE_PREFIX = "acl_cache_";
// Value format: "<level>|<unix_timestamp>"
```

`kmod_ui.lsl` reads this cache directly to skip the AUTH_BUS round-trip on touch events.

### Multi-Owner Mode

Controlled by `access.multiowner` (notecard-only setting). When enabled:
- `OwnerKeys` list replaces single `OwnerKey`
- All owners share ACL level 5
- Any owner can add/remove other owners

---

## LSD Policy System

Plugins declare their button visibility per ACL level using **linkset data policies**. This replaces the older approach where the kernel maintained a plugin ACL registry.

### How It Works

Each plugin writes a policy to linkset data on `state_entry`:

```lsl
llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
    "4", "toggle",        // Unowned wearer sees "toggle" button
    "5", "toggle"         // Primary owner sees "toggle" button
]));
```

The key is `"policy:<context>"`. The value is a JSON object mapping ACL level strings to comma-separated button labels that level can see.

### Policy Evaluation (kmod_ui.lsl)

When building the menu for a user:

1. Read `"policy:<context>"` from linkset data
2. Look up the user's ACL level in the policy JSON
3. If the level has an entry → include the plugin and filter its buttons
4. If no entry for that level → hide the plugin entirely (default-deny)

```lsl
string policy = llLinksetDataRead("policy:" + context);
string csv = llJsonGetValue(policy, [(string)acl_level]);
if (csv != JSON_INVALID) {
    list visible_buttons = llCSV2List(csv);
    // Show only these buttons
}
```

### Example: Restriction Plugin

```lsl
llLinksetDataWrite("policy:core_rlvrestrict", llList2Json(JSON_OBJECT, [
    "1", "Force Sit,Force Unsit",
    "2", "Force Sit,Force Unsit",
    "3", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
    "4", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
    "5", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit"
]));
```

Public users (level 1) see only Force Sit/Unsit. Trustees and above see full categories.

---

## Settings System

Implemented in `kmod_settings.lsl`. Provides a JSON key-value store with notecard seeding.

### Key Naming

All keys use **dotted namespace format**: `namespace.setting` (e.g., `bell.volume`, `access.owner`).

### Notecard Loading

On startup, `kmod_settings` reads a notecard named `settings` line by line:

```
key = value
```

- Lines starting with `#` are comments
- Whitespace around `=` is trimmed
- Values are stored as strings; consumers cast as needed
- Booleans must be `0` or `1` (LSL casts non-numeric strings to 0)

### Runtime API

Plugins interact with settings via channel 800:

- **Set**: `{"type": "set", "key": "bell.volume", "value": "0.5"}`
- **Get**: not used — plugins read directly from LSD via `llLinksetDataRead`
- **Sync broadcast**: When a value changes, kmod_settings broadcasts a
  lightweight `{"type": "settings_sync"}` signal so consumers can re-read
  from LSD

### Storage

Every setting is stored in linkset data (LSD) as its own key. Single-owner
ownership uses scalar keys (`access.owner`, `access.ownername`,
`access.ownerhonorific`); multi-owner ownership uses parallel CSVs
(`access.owneruuids`, `access.ownernames`, `access.ownerhonorifics`).
Trustees use parallel CSVs as well. There is no in-memory JSON cache
layer — LSD is the single source of truth.

---

## Dialog System

Implemented in `kmod_dialogs.lsl`. All dialog windows are managed centrally to prevent listener leaks and duplicate dialogs.

### Flow

1. Plugin sends `dialog_open` on channel 950 with session ID, user, body, and buttons
2. `kmod_dialogs` opens an `llDialog` on a random negative channel and tracks the listener
3. When the user clicks a button, `kmod_dialogs` broadcasts `dialog_response` on channel 950
4. If the dialog times out (default 60s), `dialog_timeout` is broadcast instead
5. Listeners are automatically cleaned up

### Menu Rendering

`kmod_menu.lsl` handles the visual presentation layer — pagination (`<<` / `>>`), back buttons (`↩ BACK`), close buttons (`✗ CLOSE`), and button layout ordering. It listens on `UI_BUS` (900) for `render_menu` and `show_message` from `kmod_ui`, then sends structured `dialog_open` messages to `kmod_dialogs` on `DIALOG_BUS` (950).

---

## UI Session Flow

`kmod_ui.lsl` manages menu sessions — the state machine that tracks which user has which menu open.

### Touch → Menu Flow

1. User touches the collar
2. `kmod_ui` checks the ACL cache in linkset data (fast path)
3. If cache miss or expired, sends `acl_query` on channel 700
4. Once ACL level is known, reads all `policy:<context>` entries from linkset data
5. Filters the plugin list based on the user's ACL level
6. Sends `render_menu` on channel 900 to `kmod_menu`, which renders the dialog
7. When user selects a plugin, sends `start` to that plugin on channel 900

### SOS (Long-Touch)

`kmod_ui` detects long touches (>1.5s). Only the wearer triggers an SOS session; non-wearers or wearers who are not under TPE receive a notice with no menu and must touch the collar normally to access the UI. `plugin_sos` declares its policy for ACL level 0 only — the wearer in TPE mode who has lost all normal collar access.

---

## Leash Engine

Split across two scripts:

- **`kmod_leash.lsl`** — movement engine, follow mechanics, distance checking
- **`plugin_leash.lsl`** — user interface, mode selection, settings

### Leash Modes

| Mode | Description |
|------|-------------|
| Avatar | Follow another avatar |
| Coffle | Collar-to-collar chaining |
| Post | Anchor to a fixed object or position |

### Protocols

- **D/s Holder** — native protocol using `leash_holder.lsl`
- **OpenCollar 8.x** — compatibility with OC holder objects
- **Lockmeister** — chain point protocol handled by `kmod_particles.lsl`

---

## RLV Relay

Implemented in `plugin_relay.lsl`. ORG-compliant relay supporting three modes:

| Mode | Behaviour |
|------|-----------|
| OFF | Ignore all relay requests |
| ASK | Prompt wearer before accepting (default) |
| ON | Auto-accept relay commands |

### Hardcore Mode

When relay is ON, trustees/owners can toggle hardcore mode. Hardcore prevents the wearer from using the safeword — only owners/trustees can release.

### Integration

The relay listens on the standard RLV relay channel (`-1812221819`) and translates incoming ORG commands into `llOwnerSay(@commands)`.

---

## Persistence Model

Two tiers, from most durable to least:

| Tier | Mechanism | Survives Relog | Survives Script Reset | Survives Owner Change |
|------|-----------|:-:|:-:|:-:|
| **Notecard** | `settings` notecard | Yes | Yes | Yes |
| **Linkset Data** | `llLinksetDataWrite` (one key per setting) | Yes | Yes | No (cleared on owner change) |

- **All settings** (owners, trustees, blacklist, public, TPE, bell, RLV
  exceptions, plugin scalars, etc.) are persisted to linkset data by
  `kmod_settings`. There is no in-memory cache — LSD is the source of
  truth and consumers read it directly.
- **The notecard** seeds initial values on first load and after owner
  change. Removing the notecard triggers a factory reset.

---

## Security Measures

- **Authorization validation** — soft resets restricted to bootstrap/maintenance scripts
- **Integer overflow protection** — Unix timestamp handling for Year 2038
- **JSON injection prevention** — all user-facing strings encoded properly
- **ACL cache with TTL** — 60-second expiry prevents stale authorization
- **Rate limiting** — remote HUD requests are throttled
- **Touch range validation** — rejects `ZERO_VECTOR` touch positions
- **Owner change detection** — automatic script reset on ownership transfer
- **TPE safety** — requires external owner; wearer confirmation required to enable
- **Default-deny policies** — plugins hidden unless explicitly allowed for an ACL level

---

## Writing a Plugin

### Minimal Skeleton

```lsl
/*--------------------
PLUGIN: plugin_example.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Example plugin
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
--------------------*/

integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_CONTEXT = "core_example";
string PLUGIN_LABEL   = "Example";

default {
    state_entry() {
        // Declare visibility policy: only owner (5) and unowned wearer (4)
        llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
            "4", "Do Thing,Other Thing",
            "5", "Do Thing,Other Thing"
        ]));

        // Register with kernel
        llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
            "type", "register",
            "context", PLUGIN_CONTEXT,
            "label", PLUGIN_LABEL,
            "script", llGetScriptName()
        ]), NULL_KEY);
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == "ping") {
                llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
                    "type", "pong",
                    "context", PLUGIN_CONTEXT
                ]), NULL_KEY);
            }
        }
        else if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == "start") {
                string context = llJsonGetValue(msg, ["context"]);
                if (context == PLUGIN_CONTEXT) {
                    // User selected this plugin from the main menu
                    // Open your submenu via DIALOG_BUS here
                }
            }
        }
    }
}
```

### Plugin Checklist

1. Define a unique `PLUGIN_CONTEXT` string (convention: `core_` prefix for standard plugins)
2. Write an LSD policy in `state_entry` declaring which ACL levels see which buttons
3. Send `register` on channel 500
4. Respond to `ping` with `pong` on channel 500
5. Handle `start` on channel 900 to open your submenu
6. Use channel 950 (`DIALOG_BUS`) for all dialog windows — never call `llDialog` directly
7. Use channel 800 (`SETTINGS_BUS`) to read/write persistent settings
8. Send `return` on channel 900 when the user navigates back to the main menu

---

## Script Inventory

All scripts are in `src/lsl/collar/experimental/`.

### Kernel

| File | Description |
|------|-------------|
| `collar_kernel.lsl` | Plugin registry, lifecycle, heartbeat |

### Modules

| File | Description |
|------|-------------|
| `kmod_auth.lsl` | ACL engine with LSD cache and JSON templates |
| `kmod_bootstrap.lsl` | Startup coordination, RLV detection |
| `kmod_dialogs.lsl` | Centralized dialog/listener management |
| `kmod_leash.lsl` | Leash movement engine |
| `kmod_menu.lsl` | Menu rendering and pagination |
| `kmod_particles.lsl` | Leash particle effects, Lockmeister |
| `kmod_remote.lsl` | External HUD communication bridge |
| `kmod_settings.lsl` | Persistent key-value store, notecard loader |
| `kmod_ui.lsl` | Session management, policy filtering, plugin list |

### Plugins

| File | Context | Menu Label |
|------|---------|------------|
| `plugin_access.lsl` | `core_owner` | Access |
| `plugin_animate.lsl` | `core_animate` | Animate |
| `plugin_bell.lsl` | `bell` | Bell |
| `plugin_blacklist.lsl` | `core_blacklist` | Blacklist |
| `plugin_leash.lsl` | `core_leash` | Leash |
| `plugin_lock.lsl` | `core_lock` | Locked: Y / Locked: N |
| `plugin_maint.lsl` | `core_maintenance` | Maintenance |
| `plugin_public.lsl` | `core_public` | Public: Y / Public: N |
| `plugin_relay.lsl` | `core_relay` | RLV Relay |
| `plugin_restrict.lsl` | `core_rlvrestrict` | Restrict |
| `plugin_rlvex.lsl` | `core_rlv_exceptions` | Exceptions |
| `plugin_sos.lsl` | `sos_911` | SOS |
| `plugin_status.lsl` | `core_status` | Status |
| `plugin_tpe.lsl` | `core_tpe` | TPE: Y / TPE: N |

### Companion Objects

| File | Description |
|------|-------------|
| `control_hud.lsl` | Remote control HUD |
| `leash_holder.lsl` | Leash handle responder |
