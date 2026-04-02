# DS Collar Settings Card Reference Guide

**Version 1.0** — Comprehensive reference for the DS Collar Modular settings system

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

The settings card is **NOT** a traditional Second Life notecard that you read and write directly. Instead, it's a **runtime data store** managed by the `ds_collar_kmod_settings.lsl` module that:

1. Reads initial configuration from a notecard at startup
2. Maintains settings as a JSON object in memory
3. Provides a message-based API for plugins to read/modify settings
4. Enforces security policies (role separation, key whitelisting, etc.)

### Persistence Model (Three Tiers)

The collar uses a **three-tier persistence model**, not simple RAM-only storage:

| Tier | Storage | Survives Relog | Survives Script Reset | Survives Owner Change |
|------|---------|:-:|:-:|:-:|
| **Linkset Data (LSD)** | `llLinksetDataWrite` in `ds_collar_kmod_auth.lsl` | Yes | Yes | No (script resets) |
| **Script Globals** | `KvJson` in `ds_collar_kmod_settings.lsl` | Yes (same owner) | No | No |
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

# Owner — JSON object format: {"uuid":"honorific"}
owners = {"12345678-1234-1234-1234-123456789abc":"Master"}

# Trustees (optional) — same format as owners
trustees = {"a1b2c3d4-e5f6-7890-abcd-111111111111":"Sir", "b2c3d4e5-f6a7-8901-bcde-222222222222":"Lady"}

# Access Control
public_mode = 0
tpe_mode = 0
locked = 0
runaway_enabled = 1

# Bell Settings
bell_visible = 1
bell_sound_enabled = 1
bell_volume = 0.5
# NOTE: These override the code defaults (0, 0, 0.3) to enable the bell
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
| `multi_owner_mode` | boolean (0/1) | `0` | Enable multiple owners | **Notecard-only** — Cannot be changed via UI |
| `owners` | JSON object | `{}` | Owners keyed by UUID with honorifics | Format: `{"uuid":"honorific"}`; ACL level 5 |
| `trustees` | JSON object | `{}` | Trusted users keyed by UUID with honorifics | Format: `{"uuid":"honorific"}`; ACL level 3 |
| `blacklist` | JSON array | `[]` | List of blocked UUIDs | Blacklisted users have no access (ACL level -1) |

### Access Modes

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `public_mode` | boolean (0/1) | `0` | Allow public (non-owner) access to certain features |
| `tpe_mode` | boolean (0/1) | `0` | Total Power Exchange — wearer has no control |
| `locked` | boolean (0/1) | `0` | Collar is locked (cannot be detached) |
| `runaway_enabled` | boolean (0/1) | `1` | Allow wearer self-release without owner permission |

### RLV Exception Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `ex_owner_tp` | boolean (0/1) | `0` | Owner can bypass TP restrictions |
| `ex_owner_im` | boolean (0/1) | `0` | Owner can bypass IM restrictions |
| `ex_trustee_tp` | boolean (0/1) | `0` | Trustees can bypass TP restrictions |
| `ex_trustee_im` | boolean (0/1) | `0` | Trustees can bypass IM restrictions |

### Bell Plugin Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bell_visible` | boolean (0/1) | `0` | Show/hide bell prim |
| `bell_sound_enabled` | boolean (0/1) | `0` | Enable sound on movement |
| `bell_volume` | float (0.0-1.0) | `0.3` | Sound volume |

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

**Lists (JSON arrays):** Enclosed in brackets, comma-separated
```
blacklist = [uuid1, uuid2]
```

**JSON Objects:** Enclosed in braces, for `owners` and `trustees`
```
owners = {"uuid1":"Master", "uuid2":"Mistress"}
trustees = {"uuid1":"Sir", "uuid2":"Lady"}
```
**Warning:** Array syntax `[...]` is rejected for `owners` and `trustees` — use JSON object format `{...}` instead.

**Booleans:** Automatically normalized to `0` or `1` using integer cast
```
public_mode = 1      # Enabled
tpe_mode = 0         # Disabled
```
**Warning:** Only numeric values work. Non-numeric strings like `true` or `false` will be cast to `0` by LSL's `(integer)` conversion. Use `1` and `0` only.

**Invalid Lines:** Skipped with a warning in chat

### Syntax Rules (CRITICAL)

*   **No Quotes:** Do **NOT** enclose UUIDs or strings in quotes. The system reads values literally.
    *   ✅ `owners = {"12345678-1234-1234-1234-123456789abc":"Master"}`
    *   ❌ `owners = {"\"12345678-1234-1234-1234-123456789abc\"":"Master"}` (no extra quotes around UUID)
*   **Lists:** Enclosed in brackets `[]`, comma-separated (for `blacklist`).
    *   ✅ `blacklist = [uuid1, uuid2]`
*   **JSON Objects:** Enclosed in braces `{}` (for `owners`, `trustees`).
    *   ✅ `owners = {"uuid1":"Master", "uuid2":"Mistress"}`
    *   ✅ `trustees = {"uuid1":"Sir", "uuid2":"Lady"}`
*   **Case Sensitivity:** Keys are case-sensitive (e.g., `owners`, not `Owners`).
*   **Whitespace:** Spaces around `=` are optional but recommended for readability.

### Configuration Patterns

#### Pattern A: Single Owner (Default)
```
owners = {"12345678-1234-1234-1234-123456789abc":"Master"}
```

#### Pattern B: Multiple Owners
```
multi_owner_mode = 1
owners = {"uuid1":"Master", "uuid2":"Mistress", "uuid3":"Owner"}
```
**Note:** With multi-owner mode, all owners have equal administrative access (ACL level 5). The `multi_owner_mode` flag controls whether the UI allows adding additional owners.

#### Pattern C: Owner + Trustees
```
owners = {"12345678-1234-1234-1234-123456789abc":"Master"}
trustees = {"uuid-friend-1":"Sir", "uuid-friend-2":"Lady"}
```

#### Pattern D: Public Access (No Owner)
```
public_mode = 1
```
**Warning:** This allows anyone to access the collar. Use with caution!

#### Pattern E: TPE Mode (Total Power Exchange)
```
owners = {"12345678-1234-1234-1234-123456789abc":"Master"}
tpe_mode = 1
```
**Important:** TPE mode removes all control from the wearer. The wearer cannot:
- Access the collar menu
- Modify settings
- Remove the owner
- Detach the collar (if `locked = 1`)

**Security Requirement:** Cannot enable TPE mode without an external owner set.

**⚠️ CRITICAL NOTECARD ORDERING:** When configuring TPE mode in the notecard, you MUST set `owners` BEFORE `tpe_mode`. The collar validates the external owner requirement line-by-line during notecard parsing. If `tpe_mode = 1` appears before owners are set, the collar will reject it and display an error.

---

## Troubleshooting

### Settings Don't Load

**Symptom:** Your notecard configuration isn't being applied

**Solutions:**
1. Verify notecard is named exactly `settings` (lowercase, no extension)
2. Check the notecard exists in the collar's **Content** tab
3. Note that invalid lines (missing `=` separator) and unknown keys are **silently skipped** — there is no chat warning. Double-check your syntax manually.
4. Ensure key names match exactly (case-sensitive)
5. Try detaching and re-attaching the collar
6. As a last resort, reset all scripts in the collar

### Owner Can't Access Menus

**Symptom:** Owner is denied access to certain features

**Solutions:**
1. Verify your UUID is in the `owners` JSON object (ensure NO quotes around the outer value, only around inner strings)
2. In multi-owner mode, ensure your UUID is one of the keys in the `owners` object
3. Check owner is not in the `blacklist`
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
HINT: Set owners BEFORE tpe_mode in notecard
```

**Explanation:** TPE mode requires an external owner (not the wearer) for safety.

**Solutions:**
1. Ensure the `owners` object contains someone else's UUID (not the wearer's)
2. Verify the owner UUID is not the wearer's UUID
3. Ensure at least one owner in the `owners` object is not the wearer
4. **For notecard configuration:** Ensure `owners` appears BEFORE `tpe_mode` in the notecard (order matters!)

**Correct Notecard Order:**
```
owners = {"12345678-1234-1234-1234-123456789abc":"Master"}
tpe_mode = 1  # Owner is set, TPE can be enabled
```

**Incorrect Notecard Order:**
```
tpe_mode = 1  # ERROR! No owner set yet
owners = {"12345678-1234-1234-1234-123456789abc":"Master"}
```

### List/Object Operations Don't Work

**Symptom:** Can't add/remove trustees or blacklist entries

**Solutions:**
1. For `blacklist`: use JSON array format `[uuid1, uuid2]`
2. For `owners` and `trustees`: use JSON object format `{"uuid":"honorific"}`
3. Check collection hasn't reached maximum size (64 entries)
4. Verify target element exists before removing
5. **Common mistake:** Using array `[...]` syntax for `owners` or `trustees` — these require object `{...}` syntax

### Notecard Changes Not Detected

**Symptom:** Modified notecard isn't reloaded

**Solutions:**
1. After editing notecard, click **Save** in the notecard editor
2. The collar should auto-detect changes and reload
3. If not detected, try detaching and re-attaching
4. Check for inventory change event in debug logs

### Unknown Keys Have No Effect

**Symptom:** A key in your notecard isn't being applied

**Explanation:** Keys not in the whitelist are **silently ignored** — there is no chat warning. The system only accepts keys defined in `is_allowed_key()` within `ds_collar_kmod_settings.lsl`.

**Solutions:**
1. Check spelling of key name (case-sensitive)
2. Verify the key is one of the 16 recognized settings keys listed in this document
3. If adding a new key, it must be added to the `is_allowed_key()` whitelist in the settings module

---

## Appendix: Complete Settings Notecard Template

```
# ============================================================================
# DS Collar Settings Notecard
# Complete template with all available keys
# ============================================================================

# OWNERSHIP SETTINGS
# ------------------
# Owners — JSON object {"uuid":"honorific"}
# Single owner (default):
owners = {}

# Multi-owner mode (uncomment to use):
# multi_owner_mode = 1
# owners = {"uuid1":"Master", "uuid2":"Mistress", "uuid3":"Owner"}

# TRUSTEES
# --------
# Trusted users with elevated permissions (ACL level 3)
# Same format as owners: {"uuid":"honorific"}
trustees = {}

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

# Runaway: Allow wearer self-release (default: 1 = enabled)
runaway_enabled = 1

# RLV EXCEPTIONS
# ---------------
# Allow owner/trustees to bypass specific RLV restrictions
ex_owner_tp = 0
ex_owner_im = 0
ex_trustee_tp = 0
ex_trustee_im = 0

# BELL SETTINGS
# -------------
# Bell visibility (default: 0 = hidden)
bell_visible = 0

# Bell sound on movement (default: 0 = off)
bell_sound_enabled = 0

# Bell volume (0.0 to 1.0, default: 0.3)
bell_volume = 0.3

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
| 1.0 | 2025-10-01 | Initial comprehensive reference guide |
| 1.1 | 2025-10-31 | Security fix: Added TPE mode validation to notecard parsing; documented notecard ordering requirement |
| 1.2 | 2026-04-01 | Fact-check corrections: Fixed persistence model to document three-tier storage (LSD, script globals, notecard); corrected bell defaults (visible=0, sound=0, volume=0.3); fixed boolean normalization (only numeric values work, not `true`/`false`); corrected silent handling of unknown/invalid keys; fixed source code path |
| 1.3 | 2026-04-02 | Consolidated owner_key/owner_hon/owner_keys/owner_honorifics into single `owners` JSON object; matches `trustees` format; removed trustee_honorifics; added runaway_enabled, RLV exception keys; updated all examples and patterns |

---

**Questions or Issues?**
Please refer to the [main README](./README.md) or review the [source code](./src/lsl/collar/ng/ds_collar_kmod_settings.lsl) for implementation details.


