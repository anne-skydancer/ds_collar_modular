# DS Collar Kmod Settings Technical Reference

## Settings Architecture

### Core Module: `ds_collar_kmod_settings.lsl`

**Location:** `src/stable/ds_collar_kmod_settings.lsl`

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
