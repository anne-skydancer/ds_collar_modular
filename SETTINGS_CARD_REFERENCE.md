# DS Collar Settings Card Reference Guide

**Version 1.0** — Comprehensive reference for the DS Collar Modular settings system

---

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Settings Keys Reference](#settings-keys-reference)
4. [Notecard Configuration](#notecard-configuration)
5. [Settings Architecture](#settings-architecture)
6. [Developer Guide](#developer-guide)
7. [Troubleshooting](#troubleshooting)

---

## Overview

The DS Collar Modular system uses a persistent **settings card** for configuration management. Despite the name "settings card," this is actually a sophisticated **JSON-based key-value store** that:

- **Initializes** from a notecard named `"settings"` in the collar inventory
- **Caches** all settings in memory (RAM) for fast access
- **Broadcasts** changes in real-time to all plugins
- **Validates** all modifications through security guards

### What is the "Settings Card"?

The settings card is **NOT** a traditional Second Life notecard that you read and write directly. Instead, it's a **runtime data store** managed by the `ds_collar_kmod_settings.lsl` module that:

1. Reads initial configuration from a notecard at startup
2. Maintains settings as a JSON object in memory
3. Provides a message-based API for plugins to read/modify settings
4. Enforces security policies (role separation, key whitelisting, etc.)

**Key Insight:** Settings persist only while the collar is worn. To save settings permanently across resets, you must update the `"settings"` notecard in the collar's inventory.

---

## Quick Start

### Creating Your First Settings Notecard

1. In Second Life, right-click your collar and select **Edit**
2. Go to the **Content** tab
3. Click **New Script** → Change type to **New Note**
4. Name it exactly: `settings` (lowercase, no file extension)
5. Add your configuration (see example below)
6. Save the notecard
7. Detach and re-attach your collar (or reset scripts)

### Example Settings Notecard

```
# DS Collar Settings
# Lines starting with # are comments

# Owner Settings (Single Owner Mode)
multi_owner_mode = 0
owner_key = 12345678-1234-1234-1234-123456789abc
owner_hon = Master

# Trustees (optional)
trustees = [uuid-of-trusted-person-1, uuid-of-trusted-person-2]
trustee_honorifics = [Sir, Lady]

# Access Control
public_mode = 0
tpe_mode = 0
locked = 0

# Bell Settings
bell_visible = 1
bell_sound_enabled = 1
bell_volume = 0.5
bell_sound = 16fcf579-82cb-b110-c1a4-5fa5e1385406
```

### Finding UUID Keys

To get someone's UUID in Second Life:
- Right-click their avatar → **Copy Key** (requires a viewer with this feature, like Firestorm)
- Or use an in-world UUID detector tool
- Your own UUID: Create a script with `llOwnerSay((string)llGetOwner());`

---

## Settings Keys Reference

### Ownership & Access Control

| Key | Type | Default | Description | Notes |
|-----|------|---------|-------------|-------|
| `multi_owner_mode` | boolean (0/1) | `0` | Enable multiple owners | **Notecard-only** — Cannot be changed via API |
| `owner_key` | UUID | `NULL_KEY` | Single owner UUID | Used when `multi_owner_mode = 0` |
| `owner_keys` | JSON array | `[]` | List of owner UUIDs | Used when `multi_owner_mode = 1`; **Notecard-only** for bulk set |
| `owner_hon` | string | `""` | Owner's honorific | e.g., "Master", "Mistress", "Owner" |
| `owner_honorifics` | JSON array | `[]` | List of honorifics | Parallel array to `owner_keys` |
| `trustees` | JSON array | `[]` | List of trusted user UUIDs | Trustees have elevated permissions (ACL level 3) |
| `trustee_honorifics` | JSON array | `[]` | List of trustee honorifics | Parallel array to `trustees` |
| `blacklist` | JSON array | `[]` | List of blocked UUIDs | Blacklisted users have no access (ACL level -1) |

### Access Modes

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `public_mode` | boolean (0/1) | `0` | Allow public (non-owner) access to certain features |
| `tpe_mode` | boolean (0/1) | `0` | Total Power Exchange — wearer has no control |
| `locked` | boolean (0/1) | `0` | Collar is locked (cannot be detached) |

### Bell Plugin Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bell_visible` | boolean (0/1) | `1` | Show/hide bell prim |
| `bell_sound_enabled` | boolean (0/1) | `1` | Enable sound on movement |
| `bell_volume` | float (0.0-1.0) | `0.5` | Sound volume |
| `bell_sound` | UUID | Default sound | Sound asset UUID |

---

## Notecard Configuration

### Notecard Format Rules

**File Name:** Must be exactly `settings` (case-sensitive, no extension)

**Syntax:**
```
key = value
```

**Comments:** Lines starting with `#` are ignored
```
# This is a comment
key = value  # This is NOT supported (no inline comments)
```

**Lists:** Enclosed in brackets, comma-separated
```
trustees = [uuid1, uuid2, uuid3]
owner_honorifics = [Master, Mistress, Owner]
```

**Booleans:** Automatically normalized to `0` or `1`
```
public_mode = 1      # Enabled
tpe_mode = 0         # Disabled
locked = true        # Also valid, normalized to 1
```

**Invalid Lines:** Skipped with a warning in chat

### Configuration Patterns

#### Pattern A: Single Owner (Default)
```
multi_owner_mode = 0
owner_key = 12345678-1234-1234-1234-123456789abc
owner_hon = Master
```

#### Pattern B: Multiple Owners
```
multi_owner_mode = 1
owner_keys = [uuid1, uuid2, uuid3]
owner_honorifics = [Master, Mistress, Owner]
```
**Note:** With multi-owner mode, all owners have equal administrative access (ACL level 5).

#### Pattern C: Owner + Trustees
```
multi_owner_mode = 0
owner_key = 12345678-1234-1234-1234-123456789abc
owner_hon = Master
trustees = [uuid-friend-1, uuid-friend-2]
trustee_honorifics = [Sir, Lady]
```

#### Pattern D: Public Access (No Owner)
```
multi_owner_mode = 0
owner_key = 00000000-0000-0000-0000-000000000000
public_mode = 1
```
**Warning:** This allows anyone to access the collar. Use with caution!

#### Pattern E: TPE Mode (Total Power Exchange)
```
multi_owner_mode = 0
owner_key = 12345678-1234-1234-1234-123456789abc
tpe_mode = 1
```
**Important:** TPE mode removes all control from the wearer. The wearer cannot:
- Access the collar menu
- Modify settings
- Remove the owner
- Detach the collar (if `locked = 1`)

**Security Requirement:** Cannot enable TPE mode without an external owner set.

**⚠️ CRITICAL NOTECARD ORDERING:** When configuring TPE mode in the notecard, you MUST set `owner_key` (or `owner_keys`) BEFORE `tpe_mode`. The collar validates the external owner requirement line-by-line during notecard parsing. If `tpe_mode = 1` appears before the owner is set, the collar will reject it and display an error.

---

## Settings Architecture

### Core Module: `ds_collar_kmod_settings.lsl`

**Location:** `src/stable/ds_collar_kmod_settings.lsl` (737 lines)

**Responsibilities:**
- Load settings from notecard at startup
- Maintain in-memory JSON key-value store
- Validate and enforce security policies
- Broadcast changes to all plugins
- Detect notecard modifications and reload

### Communication Channel

**Channel 800 (SETTINGS_BUS)** — All settings operations use this channel for link messages.

### Message Types

Plugins communicate with the settings module via JSON messages:

#### 1. Request Full Settings (Plugin → Settings)
```json
{
  "type": "settings_get"
}
```

#### 2. Full Sync Response (Settings → All Plugins)
```json
{
  "type": "settings_sync",
  "kv": {
    "multi_owner_mode": "0",
    "owner_key": "12345678-1234-1234-1234-123456789abc",
    "owner_hon": "Master",
    "public_mode": "0",
    "trustees": "[uuid1,uuid2]",
    "bell_visible": "1"
  }
}
```

#### 3. Set Scalar Value (Plugin → Settings)
```json
{
  "type": "set",
  "key": "public_mode",
  "value": "1"
}
```

#### 4. Add to List (Plugin → Settings)
```json
{
  "type": "list_add",
  "key": "trustees",
  "elem": "uuid-to-add"
}
```

#### 5. Remove from List (Plugin → Settings)
```json
{
  "type": "list_remove",
  "key": "trustees",
  "elem": "uuid-to-remove"
}
```

#### 6. Delta Update (Settings → All Plugins)
```json
{
  "type": "settings_delta",
  "op": "set",
  "changes": {
    "public_mode": "1"
  }
}
```

---

## Security Features

The settings module enforces several security policies to protect users:

### 1. Role Separation: No Self-Ownership

The wearer **cannot** be added as their own owner. This ensures proper role separation in D/s dynamics.

```
ERROR: Cannot add wearer as owner (role separation required)
```

**Why:** Prevents accidental self-locking and maintains clear owner/submissive boundaries.

### 2. Role Exclusivity

Roles are mutually exclusive:
- **Owners** cannot be trustees (automatically removed from trustee list)
- **Blacklisted** users are removed from all other roles
- **Trustees** cannot be added if they're already owners

### 3. Key Whitelist

Only pre-defined keys can be written to settings. Unknown keys are silently rejected.

**Allowed Keys:**
- All keys listed in the [Settings Keys Reference](#settings-keys-reference)

**Rejected:** Any key not in the whitelist

**Why:** Prevents plugins from polluting the settings namespace with arbitrary data.

### 4. Notecard-Only Keys

Some keys can **only** be set via notecard, never through the API:

| Key | Reason |
|-----|--------|
| `multi_owner_mode` | Defines the fundamental ownership model |
| `owner_keys` | Bulk owner list (individual owners can be added via API in multi-owner mode) |

**Why:** These keys are architectural decisions that should be intentional, not accidentally modified at runtime.

### 5. TPE Mode Protection

Cannot enable TPE mode unless an external owner is set. This validation applies to **both** runtime API changes and notecard configuration.

**Runtime API:**
```
ERROR: Cannot enable TPE - requires external owner
```

**Notecard Parsing:**
```
ERROR: Cannot enable TPE via notecard - requires external owner
HINT: Set owner_key or owner_keys BEFORE tpe_mode in notecard
```

**Why:** Prevents the wearer from locking themselves out with no way to recover.

**Implementation Note:** Notecard parsing is sequential (line-by-line). The owner must be defined in the notecard BEFORE the `tpe_mode` line, otherwise the validation will fail even if an owner is specified later in the notecard.

### 6. List Size Limits

Maximum **64 items** per list (owners, trustees, blacklist).

**Why:** LSL memory constraints and performance optimization.

---

## Developer Guide

### Using Settings in Your Plugin

#### Step 1: Define Key Constants

```lsl
string KEY_PUBLIC_MODE = "public_mode";
string KEY_TRUSTEES = "trustees";
```

#### Step 2: Create Local Cache

```lsl
integer PublicModeEnabled = FALSE;
list Trustees = [];
```

#### Step 3: Handle Settings Sync

```lsl
integer SETTINGS_BUS = 800;

apply_settings_sync(string msg) {
    string kv = llJsonGetValue(msg, ["kv"]);

    // Load scalar value
    if (llJsonGetValue(kv, [KEY_PUBLIC_MODE]) != JSON_INVALID) {
        PublicModeEnabled = (integer)llJsonGetValue(kv, [KEY_PUBLIC_MODE]);
    }

    // Load list value
    string trustees_arr = llJsonGetValue(kv, [KEY_TRUSTEES]);
    if (llGetSubString(trustees_arr, 0, 0) == "[") {
        Trustees = llJson2List(trustees_arr);
    }
}
```

#### Step 4: Handle Delta Updates

```lsl
apply_settings_delta(string msg) {
    string op = llJsonGetValue(msg, ["op"]);

    if (op == "set") {
        string changes = llJsonGetValue(msg, ["changes"]);
        if (llJsonGetValue(changes, [KEY_PUBLIC_MODE]) != JSON_INVALID) {
            PublicModeEnabled = (integer)llJsonGetValue(changes, [KEY_PUBLIC_MODE]);
        }
    }
    else if (op == "list_add") {
        string key = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);

        if (key == KEY_TRUSTEES) {
            if (llListFindList(Trustees, [elem]) == -1) {
                Trustees += [elem];
            }
        }
    }
    else if (op == "list_remove") {
        string key = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);

        if (key == KEY_TRUSTEES) {
            integer idx = llListFindList(Trustees, [elem]);
            if (idx != -1) {
                Trustees = llDeleteSubList(Trustees, idx, idx);
            }
        }
    }
}
```

#### Step 5: Listen for Settings Messages

```lsl
default {
    state_entry() {
        // Request initial settings
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]), NULL_KEY);
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);

            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
            }
            else if (msg_type == "settings_delta") {
                apply_settings_delta(msg);
            }
        }
    }
}
```

#### Step 6: Modify Settings

```lsl
// Set a boolean value
toggle_public_mode() {
    PublicModeEnabled = !PublicModeEnabled;

    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_PUBLIC_MODE,
        "value", (string)PublicModeEnabled
    ]), NULL_KEY);
}

// Add to a list
add_trustee(key user_uuid) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "list_add",
        "key", KEY_TRUSTEES,
        "elem", (string)user_uuid
    ]), NULL_KEY);
}

// Remove from a list
remove_trustee(key user_uuid) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "list_remove",
        "key", KEY_TRUSTEES,
        "elem", (string)user_uuid
    ]), NULL_KEY);
}
```

### Adding New Settings Keys

To add a new settings key to the system:

1. **Define the key in `ds_collar_kmod_settings.lsl`**
   ```lsl
   string KEY_YOUR_NEW_SETTING = "your_new_setting";
   ```

2. **Add to the whitelist in `is_allowed_key()`**
   ```lsl
   integer is_allowed_key(string k) {
       // ... existing keys ...
       if (k == KEY_YOUR_NEW_SETTING) return TRUE;
       return FALSE;
   }
   ```

3. **Document the key** in this reference guide

4. **Use in your plugin** following the patterns above

### Key Validation Functions

The settings module provides helper functions:

```lsl
// Check if a key exists in the store
string kv_get(string key_name)  // Returns "" if not found

// Set a scalar value (returns TRUE if changed)
integer kv_set_scalar(string key_name, string value)

// Set a list value (returns TRUE if changed)
integer kv_set_list(string key_name, list values)

// Add unique element to list (returns TRUE if added)
integer kv_list_add_unique(string key_name, string elem)

// Remove all instances of element (returns TRUE if removed)
integer kv_list_remove_all(string key_name, string elem)
```

---

## Troubleshooting

### Settings Don't Load

**Symptom:** Your notecard configuration isn't being applied

**Solutions:**
1. Verify notecard is named exactly `settings` (lowercase, no extension)
2. Check the notecard exists in the collar's **Content** tab
3. Look for parsing errors in local chat:
   ```
   [SETTINGS] Invalid line (no separator): ...
   ```
4. Ensure key names match exactly (case-sensitive)
5. Try detaching and re-attaching the collar
6. As a last resort, reset all scripts in the collar

### Owner Can't Access Menus

**Symptom:** Owner is denied access to certain features

**Solutions:**
1. Verify `owner_key` is set correctly in single-owner mode
2. In multi-owner mode, ensure UUID is in `owner_keys` list
3. Check owner is not in the `blacklist`
4. Confirm the menu's ACL requirement (some features require ACL level 5)

### Changes Don't Persist

**Symptom:** Settings reset when collar is detached/reattached

**Explanation:** Settings are stored in RAM only during runtime.

**Solution:** To persist settings across resets:
1. Modify the `settings` notecard in the collar's inventory
2. Save the notecard
3. Detach and re-attach the collar

**Best Practice:** Use the collar's runtime API for temporary changes, update the notecard for permanent configuration.

### Can't Enable TPE Mode

**Symptom:** Error message when trying to enable TPE mode

**Runtime API Error:**
```
ERROR: Cannot enable TPE - requires external owner
```

**Notecard Error:**
```
ERROR: Cannot enable TPE via notecard - requires external owner
HINT: Set owner_key or owner_keys BEFORE tpe_mode in notecard
```

**Explanation:** TPE mode requires an external owner (not the wearer) for safety.

**Solutions:**
1. Ensure `owner_key` is set to someone else's UUID
2. Verify the owner UUID is not the wearer's UUID
3. In multi-owner mode, ensure at least one owner is not the wearer
4. **For notecard configuration:** Ensure `owner_key` or `owner_keys` appears BEFORE `tpe_mode` in the notecard (order matters!)

**Correct Notecard Order:**
```
owner_key = 12345678-1234-1234-1234-123456789abc
tpe_mode = 1  # Owner is set, TPE can be enabled
```

**Incorrect Notecard Order:**
```
tpe_mode = 1  # ERROR! No owner set yet
owner_key = 12345678-1234-1234-1234-123456789abc
```

### List Operations Don't Work

**Symptom:** Can't add/remove trustees or blacklist entries

**Solutions:**
1. Ensure list exists in notecard as `key = []` or `key = [item1,item2]`
2. Check list hasn't reached maximum size (64 items)
3. Verify target element exists before removing
4. Confirm proper JSON array format: `[uuid1,uuid2]` not `uuid1,uuid2`

### Notecard Changes Not Detected

**Symptom:** Modified notecard isn't reloaded

**Solutions:**
1. After editing notecard, click **Save** in the notecard editor
2. The collar should auto-detect changes and reload
3. If not detected, try detaching and re-attaching
4. Check for inventory change event in debug logs

### "Unknown key ignored" Warning

**Symptom:** Chat message shows unknown key
```
[SETTINGS] Unknown key ignored: my_custom_key
```

**Explanation:** The key is not in the whitelist for security reasons.

**Solutions:**
1. Check spelling of key name (case-sensitive)
2. Ensure the key is defined in `ds_collar_kmod_settings.lsl`
3. If adding a new key, follow the [Adding New Settings Keys](#adding-new-settings-keys) guide

---

## Lifecycle & Events

### Startup Flow

1. **Collar Rezzes/Attaches**
   - `state_entry()` event in `ds_collar_kmod_settings.lsl`
   - Checks for `settings` notecard in inventory

2. **Notecard Loading** (if found)
   - Reads notecard line-by-line asynchronously
   - Parses each line (skips comments, validates keys)
   - Applies security guards (prevents self-ownership, etc.)
   - Updates internal JSON key-value store
   - Continues until End-Of-File (EOF)

3. **Notecard Complete**
   - Broadcasts full sync to all plugins on channel 800
   - Plugins receive settings and initialize their state

4. **Runtime Ready**
   - Collar is now operational with loaded settings

### Runtime Changes

1. **Plugin Modifies Setting**
   - Sends JSON message on channel 800

2. **Settings Module Validates**
   - Checks key whitelist
   - Applies security guards
   - Updates internal KV store

3. **Broadcasts Delta**
   - Sends incremental update to all plugins
   - Only changed values are transmitted

4. **Plugins Update**
   - Apply delta to local cache
   - Adjust behavior accordingly

### Notecard Change Detection

**If notecard is edited:**
- `changed(CHANGED_INVENTORY)` event triggers
- Settings module detects notecard UUID change
- Restarts notecard reading (overlays onto existing settings)
- Broadcasts full sync to all plugins

**If notecard is deleted:**
- Settings module detects deletion
- Resets to default (empty) settings
- Broadcasts empty settings to all plugins

---

## Performance & Limitations

### Memory Considerations

- **JSON Storage:** All settings stored as a single JSON string in memory
- **Maximum List Size:** 64 items per list (trustees, owners, blacklist)
- **Key Count:** Unlimited keys supported (within LSL memory limits)

**Tip:** Keep settings lean. Don't use settings for large datasets.

### Speed

- **Read:** Instant (in-memory JSON lookup)
- **Write:** Fast (JSON update + broadcast)
- **Notecard Load:** Slow (asynchronous, one line per `dataserver()` event)

**Tip:** Minimize notecard reloads. Load once at startup, modify at runtime via API.

### Concurrency

- **Thread-Safe:** LSL is single-threaded, no race conditions
- **Delta Updates:** Multiple plugins can modify settings simultaneously
- **Broadcast Order:** All plugins receive updates in the same order

---

## Best Practices

### For Users

1. **Always use notecard for initial setup** — Set owners, trustees, and preferences in the notecard before first wear
2. **Keep backups** — Copy your `settings` notecard to inventory for safekeeping
3. **Test TPE mode carefully** — Ensure you trust your owner before enabling TPE mode
4. **Use blacklist sparingly** — Blacklisting is permanent until manually removed

### For Developers

1. **Cache locally** — Store settings in plugin-local variables for fast access
2. **Handle both sync and delta** — Always support both message types
3. **Validate before use** — Check for `JSON_INVALID` before accessing values
4. **Don't spam settings** — Minimize write operations to reduce message traffic
5. **Document your keys** — Add new keys to this reference guide
6. **Use appropriate types** — Booleans as 0/1, UUIDs as strings, lists as JSON arrays
7. **Test edge cases** — Empty lists, missing keys, invalid values

---

## Related Documentation

- **[README.md](./README.md)** — Project overview and architecture
- **[agents.md](./agents.md)** — LSL coding standards and best practices
- **[src/stable/ds_collar_kmod_settings.lsl](./src/stable/ds_collar_kmod_settings.lsl)** — Settings module source code
- **[src/stable/ds_collar_kmod_auth.lsl](./src/stable/ds_collar_kmod_auth.lsl)** — ACL and authorization engine

---

## Appendix: Complete Settings Notecard Template

```
# ============================================================================
# DS Collar Settings Notecard
# Complete template with all available keys
# ============================================================================

# OWNERSHIP SETTINGS
# ------------------
# Single owner mode (default)
multi_owner_mode = 0
owner_key = 00000000-0000-0000-0000-000000000000
owner_hon =

# Multi-owner mode (uncomment to use)
# multi_owner_mode = 1
# owner_keys = [uuid1, uuid2, uuid3]
# owner_honorifics = [Master, Mistress, Owner]

# TRUSTEES
# --------
# Trusted users with elevated permissions (ACL level 3)
trustees = []
trustee_honorifics = []

# BLACKLIST
# ---------
# Users explicitly denied access (ACL level -1)
blacklist = []

# ACCESS CONTROL
# --------------
# Public mode: Allow public access (ACL level 1)
public_mode = 0

# TPE mode: Total Power Exchange (wearer has no control)
# WARNING: Requires external owner. Cannot be enabled without one.
tpe_mode = 0

# Locked: Collar cannot be detached
locked = 0

# BELL SETTINGS
# -------------
# Bell visibility
bell_visible = 1

# Bell sound on movement
bell_sound_enabled = 1

# Bell volume (0.0 to 1.0)
bell_volume = 0.5

# Bell sound UUID (default jingle bell sound)
bell_sound = 16fcf579-82cb-b110-c1a4-5fa5e1385406

# ============================================================================
# END OF SETTINGS
# ============================================================================
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-31 | Initial comprehensive reference guide |
| 1.1 | 2025-10-31 | Security fix: Added TPE mode validation to notecard parsing; documented notecard ordering requirement |

---

**Questions or Issues?**
Please refer to the [main README](./README.md) or review the [source code](./src/stable/ds_collar_kmod_settings.lsl) for implementation details.
