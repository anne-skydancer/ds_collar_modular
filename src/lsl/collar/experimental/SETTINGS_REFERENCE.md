# DS Collar Settings Card Reference Guide

**Version 1.1** — Comprehensive reference for the DS Collar Modular settings system

---

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Settings Keys Reference](#settings-keys-reference)
4. [Notecard Configuration](#notecard-configuration)
5. [Troubleshooting](#troubleshooting)

---

## Overview

The DS Collar Modular system uses a persistent **settings card** for configuration management. Despite the name "settings card," this is actually a sophisticated **JSON-based key-value store** that:

- **Initializes** from a notecard named `"settings"` in the collar inventory
- **Caches** all settings in memory (RAM) for fast access
- **Broadcasts** changes in real-time to all plugins
- **Validates** all modifications through security guards

### What is the "Settings Card"?

The settings card is **NOT** a traditional Second Life notecard that you read and write directly. Instead, it's a **runtime data store** managed by the `kmod_settings.lsl` module that:

1. Reads initial configuration from a notecard at startup
2. Maintains settings as a JSON object in memory
3. Provides a message-based API for plugins to read/modify settings
4. Enforces security policies (role separation, TPE validation, etc.)

### Key Naming Convention

All settings keys use **dotted `namespace.setting` format**. This is a hard convention in the experimental branch — underscore key names from older branches are not recognized.

- Core access keys: `access.*`, `public.*`, `tpe.*`, `lock.*`, `rlvex.*`
- Plugin keys: `bell.*`, `restrict.*`, etc.

### Persistence Model (Three Tiers)

The collar uses a **three-tier persistence model**, not simple RAM-only storage:

| Tier | Storage | Survives Relog | Survives Script Reset | Survives Owner Change |
|------|---------|:-:|:-:|:-:|
| **Linkset Data (LSD)** | `llLinksetDataWrite` in `kmod_auth.lsl` | Yes | Yes | No (script resets) |
| **Script Globals** | `KvJson` in `kmod_settings.lsl` | Yes (same owner) | No | No |
| **Notecard** | `settings` notecard in collar inventory | Yes | Yes | Yes |

**Key Insights:**
- **ACL data persists across relogs.** The auth module writes owners, trustees, blacklist, public mode, and TPE mode to linkset data via `persist_acl_cache()`. This survives script resets, detach/reattach, and relogs.
- **All runtime settings persist across detach/reattach** for the same owner. The settings script only resets on ownership change, so `KvJson` (including values set via UI) survives reattach cycles.
- **The notecard is a seed**, not the sole source of truth. It provides initial values on first load or after owner change. Notecard edits overlay onto existing settings without wiping runtime changes to other keys.

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
access.multiowner = 0
access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}

# Trustees (optional — JSON object, NOT array)
access.trustees = {"uuid-of-trusted-person-1": "Sir", "uuid-of-trusted-person-2": "Lady"}

# Access Control
public.mode = 0
tpe.mode = 0
lock.locked = 0

# Bell Settings
bell.visible = 1
bell.enablesound = 1
bell.volume = 0.5
# NOTE: These override the code defaults (0, 0, 0.3) to enable the bell
bell.sound = 16fcf579-82cb-b110-c1a4-5fa5e1385406
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
| `access.multiowner` | boolean (0/1) | `0` | Enable multiple owners | **Notecard-only** — Cannot be changed via UI |
| `access.owner` | JSON object | `{}` | Single owner `{uuid: honorific}` | Used when `access.multiowner = 0` |
| `access.owners` | JSON object | `{}` | Multiple owners `{uuid: hon, ...}` | Used when `access.multiowner = 1`; **Notecard-only** for bulk set |
| `access.trustees` | JSON object | `{}` | Trusted users `{uuid: hon, ...}` | Trustees have elevated permissions (ACL level 3) |
| `access.blacklist` | CSV in brackets | `[]` | List of blocked UUIDs | Blacklisted users have no access (ACL level -1) |

### Access Modes

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `public.mode` | boolean (0/1) | `0` | Allow public (non-owner) access to certain features |
| `tpe.mode` | boolean (0/1) | `0` | Total Power Exchange — wearer has no control |
| `lock.locked` | boolean (0/1) | `0` | Collar is locked (cannot be detached) |

### RLV Exceptions

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `rlvex.ownertp` | boolean (0/1) | `0` | Allow owner to TP wearer despite restrictions |
| `rlvex.ownerim` | boolean (0/1) | `0` | Allow owner to IM wearer despite restrictions |
| `rlvex.trusteetp` | boolean (0/1) | `0` | Allow trustees to TP wearer despite restrictions |
| `rlvex.trusteeim` | boolean (0/1) | `0` | Allow trustees to IM wearer despite restrictions |

### Access Plugin

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `access.enablerunaway` | boolean (0/1) | `0` | Enable the runaway feature for the wearer |

### Bell Plugin Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bell.visible` | boolean (0/1) | `0` | Show/hide bell prim |
| `bell.enablesound` | boolean (0/1) | `0` | Enable sound on movement |
| `bell.volume` | float (0.0-1.0) | `0.3` | Sound volume |
| `bell.sound` | UUID | `16fcf579-82cb-b110-c1a4-5fa5e1385406` | Sound asset UUID |

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

**JSON Objects:** Owner/trustee keys use `{uuid: honorific}` format
```
access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}
access.trustees = {"uuid1": "Sir", "uuid2": "Lady"}
```

**Bracketed lists (CSV):** Blacklist uses comma-separated values in brackets
```
access.blacklist = [uuid1, uuid2, uuid3]
```

**Booleans:** Automatically normalized to `0` or `1` using integer cast
```
public.mode = 1      # Enabled
tpe.mode = 0         # Disabled
```
**Warning:** Only numeric values work. Non-numeric strings like `true` or `false` will be cast to `0` by LSL's `(integer)` conversion. Use `1` and `0` only.

### Syntax Rules (CRITICAL)

*   **JSON Objects:** `access.owner`, `access.owners`, and `access.trustees` use `{uuid: honorific}` format. Quotes around keys/values are required for valid JSON.
    *   ✅ `access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}`
    *   ❌ `access.owner = 12345678-1234-1234-1234-123456789abc` (bare UUID not accepted for this key)
*   **JSON Arrays:** `access.blacklist` uses bracket notation.
    *   ✅ `access.blacklist = [uuid1, uuid2]`
*   **Case Sensitivity:** Keys are case-sensitive (e.g., `access.owner`, not `Access.Owner`).
*   **Whitespace:** Spaces around `=` are optional but recommended for readability.

### Configuration Patterns

#### Pattern A: Single Owner (Default)
```
access.multiowner = 0
access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}
```

#### Pattern B: Multiple Owners
```
access.multiowner = 1
access.owners = {"uuid1": "Master", "uuid2": "Mistress", "uuid3": "Owner"}
```
**Note:** With multi-owner mode, all owners have equal administrative access (ACL level 5).

#### Pattern C: Owner + Trustees
```
access.multiowner = 0
access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}
access.trustees = {"uuid-friend-1": "Sir", "uuid-friend-2": "Lady"}
```

#### Pattern D: Public Access (No Owner)
```
access.multiowner = 0
public.mode = 1
```
**Warning:** This allows anyone to access the collar. Use with caution!

#### Pattern E: TPE Mode (Total Power Exchange)
```
access.multiowner = 0
access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}
tpe.mode = 1
```
**Important:** TPE mode removes all control from the wearer. The wearer cannot:
- Access the collar menu
- Modify settings
- Remove the owner
- Detach the collar (if `lock.locked = 1`)

**Security Requirement:** Cannot enable TPE mode without an external owner set.

**CRITICAL NOTECARD ORDERING:** When configuring TPE mode in the notecard, you MUST set `access.owner` (or `access.owners`) BEFORE `tpe.mode`. The collar validates the external owner requirement line-by-line during notecard parsing. If `tpe.mode = 1` appears before the owner is set, the collar will reject it and display an error.

---

## Troubleshooting

### Settings Don't Load

**Symptom:** Your notecard configuration isn't being applied

**Solutions:**
1. Verify notecard is named exactly `settings` (lowercase, no extension)
2. Check the notecard exists in the collar's **Content** tab
3. Unknown and invalid keys are **silently skipped** — there is no chat warning. Double-check key names manually.
4. Ensure key names use dotted format and match exactly (case-sensitive)
5. Try detaching and re-attaching the collar
6. As a last resort, reset all scripts in the collar

### Owner Can't Access Menus

**Symptom:** Owner is denied access to certain features

**Solutions:**
1. Verify `access.owner` is set correctly in single-owner mode (JSON object: `{"uuid": "honorific"}`)
2. In multi-owner mode, ensure UUID is in the `access.owners` object
3. Check owner is not in `access.blacklist`
4. Confirm the menu's ACL requirement (some features require ACL level 5)

### Changes Don't Persist

**Symptom:** Settings reset unexpectedly

**Explanation:** The collar uses a three-tier persistence model:
- **ACL data (owners, trustees, blacklist, public mode, TPE)** is written to **linkset data** by the auth module and persists across relogs, script resets, and detach/reattach.
- **All runtime settings** (including values set via UI) persist in script globals (`KvJson`) across detach/reattach for the **same owner**. They are only lost on script reset or ownership change.
- **The notecard** provides initial seed values on first load or after owner change.

**If settings reset after a relog:** This should not normally happen for ACL data. Check that collar scripts haven't been manually reset.

**If settings reset after ownership change:** This is expected — all scripts reset on owner change. Update the `settings` notecard for values that must survive ownership transfers.

**Best Practice:** For most use cases, runtime changes (via UI or API) are sufficient — they persist automatically. Only edit the notecard when you need values to survive an ownership change or full script reset.

### Can't Enable TPE Mode

**Symptom:** Error message when trying to enable TPE mode

**Runtime API Error:**
```
ERROR: Cannot enable TPE - requires external owner
```

**Notecard Error:**
```
ERROR: Cannot enable TPE via notecard - requires external owner
HINT: Set owner or owners BEFORE tpe_mode in notecard
```

**Explanation:** TPE mode requires an external owner (not the wearer) for safety.

**Solutions:**
1. Ensure `access.owner` is set to someone else's UUID (JSON object format)
2. Verify the owner UUID is not the wearer's UUID
3. In multi-owner mode, ensure at least one owner is not the wearer
4. **For notecard configuration:** Ensure `access.owner` or `access.owners` appears BEFORE `tpe.mode` in the notecard (order matters!)

**Correct Notecard Order:**
```
access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}
tpe.mode = 1  # Owner is set, TPE can be enabled
```

**Incorrect Notecard Order:**
```
tpe.mode = 1  # ERROR! No owner set yet
access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}
```

### List Operations Don't Work

**Symptom:** Can't add/remove trustees or blacklist entries

**Solutions:**
1. Ensure list exists in notecard as `key = []` or `key = [item1,item2]`
2. Check list hasn't reached maximum size (64 items)
3. Verify target element exists before removing
4. Confirm proper bracketed CSV format: `[uuid1,uuid2]` not `uuid1,uuid2` (no quotes needed)

### Notecard Changes Not Detected

**Symptom:** Modified notecard isn't reloaded

**Solutions:**
1. After editing notecard, click **Save** in the notecard editor
2. The collar should auto-detect changes and reload
3. If not detected, try detaching and re-attaching
4. Check for inventory change event in debug logs

### Unknown Keys Have No Effect

**Symptom:** A key in your notecard isn't being applied

**Explanation:** The experimental branch enforces **no key whitelist** — `kmod_settings.lsl` accepts any key. Unknown keys in the notecard are silently written to `KvJson` (plain keys) or LSD (dotted `plugin.setting` keys). If a key has no effect, the issue is almost always a typo, wrong format, or the consuming plugin not reading it.

**Solutions:**
1. Check spelling of key name (case-sensitive)
2. Ensure dotted format is used: `access.owner`, `bell.visible`, etc. — not `owner`, `bell_visible`
3. Confirm the consuming plugin actually reads the key from settings

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
# access.owner and access.trustees use JSON object format: {uuid: honorific}
# Omit access.owner or use {} for unowned; replace with real UUID to set owner
access.multiowner = 0
# access.owner = {"your-owner-uuid-here": "Master"}

# Multi-owner mode (uncomment to use)
# access.multiowner = 1
# access.owners = {"uuid1": "Master", "uuid2": "Mistress", "uuid3": "Owner"}

# TRUSTEES
# --------
# Trusted users with elevated permissions (ACL level 3)
access.trustees = {}

# BLACKLIST
# ---------
# Users explicitly denied access (ACL level -1)
access.blacklist = []

# ACCESS CONTROL
# --------------
# Public mode: Allow public access (ACL level 1)
public.mode = 0

# TPE mode: Total Power Exchange (wearer has no control)
# WARNING: Requires external owner. Cannot be enabled without one.
tpe.mode = 0

# Locked: Collar cannot be detached
lock.locked = 0

# RLV EXCEPTIONS
# --------------
rlvex.ownertp = 0
rlvex.ownerim = 0
rlvex.trusteetp = 0
rlvex.trusteeim = 0

# ACCESS PLUGIN
# -------------
access.enablerunaway = 0

# BELL SETTINGS
# -------------
# Bell visibility (default: 0 = hidden)
bell.visible = 0

# Bell sound on movement (default: 0 = off)
bell.enablesound = 0

# Bell volume (0.0 to 1.0, default: 0.3)
bell.volume = 0.3

# Bell sound UUID (default jingle bell sound)
bell.sound = 16fcf579-82cb-b110-c1a4-5fa5e1385406

# ============================================================================
# END OF SETTINGS
# ============================================================================
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-01 | Initial comprehensive reference guide |
| 1.1 | 2025-10-31 | Security fix: Added TPE mode validation to notecard parsing; documented notecard ordering requirement |
| 1.2 | 2026-04-01 | Fact-check corrections: Fixed persistence model to document three-tier storage (LSD, script globals, notecard); corrected bell defaults (visible=0, sound=0, volume=0.3); fixed boolean normalization (only numeric values work, not `true`/`false`); corrected silent handling of unknown/invalid keys; fixed source code path |
| 1.3 | 2026-04-02 | Updated version to 1.1 for ng branch; fixed source code path to v1.1 location |
| 1.4 | 2026-04-04 | Updated all key names to dotted namespace.setting format used in experimental branch; added RLV exceptions and access plugin tables to reference; removed false whitelist claim |

---

**Questions or Issues?**
Please refer to the [main README](./README.md) or review the [source code](./kmod_settings.lsl) for implementation details.
