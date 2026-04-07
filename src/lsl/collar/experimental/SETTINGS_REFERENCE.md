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

The DS Collar Modular system uses a persistent **settings store** for
configuration management. As of v1.1 rev 3, the store is a **flat key-value
scheme backed by Linkset Data (LSD)** — there is no JSON object payload
layer. Each setting is either a scalar value or a parallel CSV. The store:

- **Initializes** from a notecard named `"settings"` in the collar inventory
- **Persists** all values in linkset data (`llLinksetDataWrite`) so they
  survive script resets and detach/reattach
- **Broadcasts** lightweight `settings_sync` signals when values change so
  plugins can re-read directly from LSD
- **Validates** all modifications through security guards

### What is the "Settings Card"?

The settings card is **NOT** a traditional Second Life notecard that you
read and write directly. Instead, it's a **runtime data store** managed by
the `kmod_settings.lsl` module that:

1. Reads initial configuration from a notecard at startup
2. Stores each setting as its own LSD key (scalar or CSV)
3. Provides a message-based API for plugins to read/modify settings
4. Enforces security policies (role separation, TPE validation, etc.)

### Key Naming Convention

All settings keys use **dotted `namespace.setting` format**. This is a hard convention in the experimental branch — underscore key names from older branches are not recognized.

- Core access keys: `access.*`, `public.*`, `tpe.*`, `lock.*`, `rlvex.*`
- Plugin keys: `bell.*`, `restrict.*`, etc.

### Persistence Model

The collar uses **Linkset Data (LSD) as the single source of truth** for
all settings:

| Tier | Storage | Survives Relog | Survives Script Reset | Survives Owner Change |
|------|---------|:-:|:-:|:-:|
| **Linkset Data (LSD)** | `llLinksetDataWrite` (one key per setting) | Yes | Yes | No (cleared on owner change) |
| **Notecard** | `settings` notecard in collar inventory | Yes | Yes | Yes |

**Key Insights:**
- **All settings persist across relogs and script resets.** Owners,
  trustees, blacklist, public mode, TPE mode, bell config, RLV exceptions,
  and every other key are written to LSD by `kmod_settings.lsl` and read
  back directly by consumers.
- **The notecard is a seed**, not the sole source of truth. It provides
  initial values on first load. Removing the notecard triggers a factory
  reset; editing it re-parses every key and clears the owner/trustee/
  blacklist data first so removed entries don't persist as stale state.
- **On owner change**, all scripts reset and LSD is cleared, then the
  notecard is re-read.

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
access.owner = 12345678-1234-1234-1234-123456789abc
access.ownerhonorific = Master

# Trustees (optional — parallel CSVs)
access.trusteeuuids = aaaaaaaa-1111-2222-3333-444444444444,bbbbbbbb-5555-6666-7777-888888888888
access.trusteehonorifics = Sir,Lady

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

Single-owner mode uses **scalars**; multi-owner mode uses **parallel CSVs**
(uuids and honorifics in the same order). Display names are resolved
asynchronously by `kmod_settings` and stored in companion `*names` keys —
you only supply UUIDs and honorifics in the notecard.

| Key | Type | Default | Description | Notes |
|-----|------|---------|-------------|-------|
| `access.multiowner` | boolean (0/1) | `0` | Enable multi-owner mode | **Notecard-only** — Cannot be changed via UI |
| `access.owner` | bare UUID | (unset) | Single owner UUID | Single-owner mode only |
| `access.ownerhonorific` | string | (unset) | Honorific for the single owner | Single-owner mode only |
| `access.owneruuids` | CSV of UUIDs | (unset) | Multi-owner UUID list | **Notecard-only**; multi-owner mode only |
| `access.ownerhonorifics` | CSV of strings | (unset) | Honorifics, parallel to `access.owneruuids` | Multi-owner mode only |
| `access.trusteeuuids` | CSV of UUIDs | (unset) | Trusted users (ACL level 3) | **Notecard-only** |
| `access.trusteehonorifics` | CSV of strings | (unset) | Honorifics, parallel to `access.trusteeuuids` | |
| `blacklist.blklistuuid` | CSV of UUIDs | (unset) | Blocked users (ACL level -1) | |

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

**Single-owner scalars:** Bare UUID and honorific on separate lines
```
access.owner = 12345678-1234-1234-1234-123456789abc
access.ownerhonorific = Master
```

**Multi-owner parallel CSVs:** UUIDs and honorifics in the same order
```
access.multiowner = 1
access.owneruuids = uuid1,uuid2
access.ownerhonorifics = Master,Mistress
```

**Trustees (parallel CSVs):**
```
access.trusteeuuids = uuid1,uuid2
access.trusteehonorifics = Sir,Lady
```

**Blacklist (CSV of UUIDs):**
```
blacklist.blklistuuid = uuid1,uuid2,uuid3
```

**Booleans:** Automatically normalized to `0` or `1` using integer cast
```
public.mode = 1      # Enabled
tpe.mode = 0         # Disabled
```
**Warning:** Only numeric values work. Non-numeric strings like `true` or `false` will be cast to `0` by LSL's `(integer)` conversion. Use `1` and `0` only.

### Syntax Rules (CRITICAL)

*   **No JSON object syntax.** Owner and trustee data are stored as flat
    scalars (single mode) or parallel CSVs (multi mode). The parser will
    not accept `{uuid: honorific}` JSON object syntax.
    *   ✅ `access.owner = 12345678-1234-1234-1234-123456789abc`
    *   ✅ `access.ownerhonorific = Master`
    *   ❌ `access.owner = {"12345678-...": "Master"}` (rejected)
*   **Parallel CSVs must stay in order.** `access.owneruuids` and
    `access.ownerhonorifics` are positional — the first uuid pairs with
    the first honorific, and so on. Same for trustee CSVs.
*   **Case Sensitivity:** Keys are case-sensitive (e.g., `access.owner`,
    not `Access.Owner`).
*   **Whitespace:** Spaces around `=` are optional but recommended for
    readability.

### Configuration Patterns

#### Pattern A: Single Owner (Default)
```
access.multiowner = 0
access.owner = 12345678-1234-1234-1234-123456789abc
access.ownerhonorific = Master
```

#### Pattern B: Multiple Owners
```
access.multiowner = 1
access.owneruuids = uuid1,uuid2,uuid3
access.ownerhonorifics = Master,Mistress,Owner
```
**Note:** With multi-owner mode, all owners have equal administrative
access (ACL level 5). Multi-owner data is **notecard-only** — there is no
runtime API to add or remove owners in multi-owner mode.

#### Pattern C: Owner + Trustees
```
access.multiowner = 0
access.owner = 12345678-1234-1234-1234-123456789abc
access.ownerhonorific = Master
access.trusteeuuids = uuid-friend-1,uuid-friend-2
access.trusteehonorifics = Sir,Lady
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
access.owner = 12345678-1234-1234-1234-123456789abc
access.ownerhonorific = Master
tpe.mode = 1
```
**Important:** TPE mode removes all control from the wearer. The wearer cannot:
- Access the collar menu
- Modify settings
- Remove the owner
- Detach the collar (if `lock.locked = 1`)

**Security Requirement:** Cannot enable TPE mode without an external owner set.

**CRITICAL NOTECARD ORDERING:** When configuring TPE mode in the notecard,
you MUST set the owner (`access.owner` in single mode, or
`access.owneruuids` in multi mode) BEFORE `tpe.mode`. The collar validates
the external owner requirement line-by-line during notecard parsing. If
`tpe.mode = 1` appears before the owner is set, the collar will reject it
and display an error.

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
1. Verify `access.owner` is set correctly in single-owner mode (bare UUID,
   with `access.ownerhonorific` on a separate line)
2. In multi-owner mode, ensure the UUID is in the `access.owneruuids` CSV
3. Check owner is not in `blacklist.blklistuuid`
4. Confirm the menu's ACL requirement (some features require ACL level 5)

### Changes Don't Persist

**Symptom:** Settings reset unexpectedly

**Explanation:** The collar stores every setting in linkset data (LSD).
LSD survives relogs, script resets, and detach/reattach for the same
owner. The notecard provides initial seed values on first load or after
owner change.

**If settings reset after a relog:** This should not normally happen.
Check that collar scripts haven't been manually reset and that the
notecard hasn't been removed (removing the notecard triggers a factory
reset).

**If settings reset after ownership change:** This is expected — all
scripts reset on owner change and LSD is cleared. Update the `settings`
notecard for values that must survive ownership transfers.

**Best Practice:** For most use cases, runtime changes (via UI or API)
are sufficient — they persist automatically in LSD. Only edit the
notecard when you need values to survive an ownership change.

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
1. Ensure `access.owner` (single mode) or `access.owneruuids` (multi mode)
   contains a UUID that is not the wearer's
2. Verify the owner UUID is not the wearer's UUID
3. In multi-owner mode, ensure at least one owner is not the wearer
4. **For notecard configuration:** Ensure the owner key appears BEFORE
   `tpe.mode` in the notecard (order matters!)

**Correct Notecard Order:**
```
access.owner = 12345678-1234-1234-1234-123456789abc
access.ownerhonorific = Master
tpe.mode = 1  # Owner is set, TPE can be enabled
```

**Incorrect Notecard Order:**
```
tpe.mode = 1  # ERROR! No owner set yet
access.owner = 12345678-1234-1234-1234-123456789abc
```

### List Operations Don't Work

**Symptom:** Can't add/remove trustees or blacklist entries

**Solutions:**
1. Ensure CSV keys exist in the notecard (e.g., `access.trusteeuuids = uuid1,uuid2`)
2. Check the list hasn't reached the maximum size (64 entries)
3. Verify the target element exists before removing
4. Use plain CSV format with no brackets and no quotes: `uuid1,uuid2`

### Notecard Changes Not Detected

**Symptom:** Modified notecard isn't reloaded

**Solutions:**
1. After editing notecard, click **Save** in the notecard editor
2. The collar should auto-detect changes and reload
3. If not detected, try detaching and re-attaching
4. Check for inventory change event in debug logs

### Unknown Keys Have No Effect

**Symptom:** A key in your notecard isn't being applied

**Explanation:** `kmod_settings.lsl` enforces **no key whitelist** — any
dotted `namespace.setting` key is silently written through to LSD as a
scalar. If a key has no effect, the issue is almost always a typo, wrong
format, or the consuming plugin not reading it.

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
# access.owner is a bare UUID; access.ownerhonorific is the title
# Omit both for an unowned collar
access.multiowner = 0
# access.owner = your-owner-uuid-here
# access.ownerhonorific = Master

# Multi-owner mode (uncomment to use)
# Parallel CSVs: first uuid pairs with first honorific, etc.
# access.multiowner = 1
# access.owneruuids = uuid1,uuid2,uuid3
# access.ownerhonorifics = Master,Mistress,Owner

# TRUSTEES
# --------
# Trusted users with elevated permissions (ACL level 3)
# Parallel CSVs in the same order
# access.trusteeuuids = uuid1,uuid2
# access.trusteehonorifics = Sir,Lady

# BLACKLIST
# ---------
# Users explicitly denied access (ACL level -1)
# blacklist.blklistuuid = uuid1,uuid2

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
| 1.5 | 2026-04-07 | Removed JSON object syntax for owners/trustees (no longer supported by parser); replaced with flat scalars (single mode) and parallel CSVs (multi mode); replaced `access.blacklist = [...]` bracket form with `blacklist.blklistuuid` CSV; rewrote persistence model to reflect LSD-as-source-of-truth (KvJson removed in rev 2) |

---

**Questions or Issues?**
Please refer to the [main README](./README.md) or review the [source code](./kmod_settings.lsl) for implementation details.
