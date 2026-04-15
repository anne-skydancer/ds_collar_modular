# D/s Collar - User Guide

Welcome to the D/s Collar system! This guide will help you understand and use all features of your collar, whether you're a collar wearer or an owner/dominant.

---

## Table of Contents

1. [Introduction](#introduction)
2. [Quick Start Guide](#quick-start-guide)
3. [Understanding Access Levels](#understanding-access-levels)
4. [Basic Operations](#basic-operations)
5. [Owner & Access Management](#owner--access-management)
6. [Leash System](#leash-system)
7. [RLV Features](#rlv-features)
8. [Animations & Customization](#animations--customization)
9. [Safety & Emergency Features](#safety--emergency-features)
10. [Control HUD (Remote Control)](#control-hud-remote-control)
11. [Configuration & Settings](#configuration--settings)
12. [Troubleshooting](#troubleshooting)
13. [FAQ](#faq)

---

## Introduction

**D/s Collar Modular** is a modern, lightweight D/s (Dominant/submissive) collar system for Second Life. It provides comprehensive control features including:

- Owner and trustee management
- Multi-mode leashing system
- RLV (Restrained Love) integration with built-in relay
- Animation controls
- Bell system with customizable sounds
- Total Power Exchange (TPE) mode
- Emergency safety features

**Important:** The collar includes an **RLV relay** that allows external objects (furniture, traps, cages) to send RLV commands to the wearer. By default, the relay starts in **ASK mode** — the wearer is prompted to accept or deny each request before it takes effect. See the [RLV Relay](#rlv-relay) section for details on how to configure this.

The collar uses a modular architecture with a central kernel and plugins, making it both powerful and efficient.

### Key Features

- **Security First** - Advanced access control and blacklist protection
- **Flexible Ownership** - Single or multi-owner modes with trustees
- **RLV Integration** - Full RLV relay and restriction support
- **Emergency Access** - SOS menu accessible via long-touch
- **Remote Control** - Optional HUD for distance control
- **Persistent Settings** - Your preferences are saved automatically

---

## Quick Start Guide

### For Collar Wearers

1. **Wear the collar** - Attach it to your avatar
2. **Touch the collar** - This opens the main menu
3. **Explore available options** - You'll see menus based on your access level
4. **Long-touch (1.5+ seconds)** - Access emergency SOS menu (only available in TPE mode; owned wearers not in TPE have normal collar access instead)

**Note:** The collar has a built-in RLV relay that defaults to **ASK mode**. When RLV-enabled furniture or objects try to control you, you'll be prompted to accept or deny. You can change this in **RLV Relay** → **Mode**.

### For Owners/Dominants

1. **Touch the collar** - Open the main menu
2. **Select "Access"** - Access owner management
3. **Claim ownership** - Set yourself as owner
4. **Explore features** - Leash, RLV, animations, and more
5. **Configure settings** - Customize lock, TPE, public access

---

## Understanding Access & Permissions

The collar controls who can do what based on roles and relationships:

### Roles

**Owner**
- Complete control over all collar features
- Can set restrictions, manage leash, configure settings
- Can add/remove trustees
- Can release or transfer ownership

**Trustee**
- Trusted users with elevated permissions
- Can leash, apply RLV restrictions, use animations
- Cannot change ownership, but can add or remove other trustees
- Set by owner

**Collar Wearer (When Owned)**
- Can use personal features like animations
- Limited access to settings
- Can view status

- **Note:** SOS emergency menu via long-touch is **not** available to owned wearers in normal operation. It is only ever available for wearers in TPE mode (no access state).

**Collar Wearer (When Unowned)**
- Full self-control
- Can set an owner
- Can manage all features until ownership is claimed

**Public Users (When Public Mode Enabled)**
- Limited features like viewing status
- Can leash (if allowed by settings)
- Cannot change ownership or settings

**Blacklisted Users**
- Complete denial of access - cannot interact with collar at all

---

## Basic Operations

### Opening the Menu

**Regular Touch:** Touch the collar once to open the main menu. You'll see all options you have permission to access.

**Long Touch (SOS):** Touch and hold the collar for 1.5+ seconds to trigger a SOS session. This is specifically designed for wearers in **TPE mode** (who have no normal collar access). Owned wearers not in TPE mode have normal collar access and the SOS options will not be available to them via long-touch.

### Navigating Menus

- **Menu Buttons:** Click any button to select that option
- **<< and >>:** Navigation arrows for multi-page menus
- **Back:** Return to previous menu
- **Close:** Close all menus
- **Timeout:** Menus automatically close after 60 seconds of inactivity

### Menu Structure (assuming a D/s Collar installation with all plugins installed)

Plugins are sorted alphabetically in the main menu. The exact order and which buttons appear depends on the user's access level.

```
Main Menu (alphabetical order)
├── Access         (Owner & trustee management)
├── Animate        (Animation menu)
├── Bell           (Bell settings)
├── Blacklist      (Manage blocked users)
├── Exceptions     (RLV bypass rules)
├── Leash          (Leashing controls)
├── Locked: Y/N    (Lock/unlock toggle)
├── Maintenance    (View settings)
├── Public: Y/N    (Public access toggle)
├── Restrict       (RLV restrictions)
├── RLV Relay      (RLV relay settings)
├── Status         (View collar status)
├── TPE: Y/N       (Total Power Exchange mode)
└── SOS            (Emergency menu - long touch only)
```

---

## Owner & Access Management

### Setting Ownership

**For Unowned Wearers:**

1. Touch collar → **Access**
2. Select **Add Owner**
3. A sensor scan finds nearby avatars and displays a numbered list
4. Select the new owner from the list
5. The selected person receives a confirmation dialog
6. They click **Yes** to accept, then choose their honorific
7. The wearer then receives a final confirmation dialog asking them to submit
8. Wearer clicks **Yes** to confirm
9. Ownership is established

**Important:** Once a primary owner is set, the wearer loses the ability to change owners.

**Note:** Ownership may be set without the need of recurring to the collar interface through the settings notecard. Refer to the settings notecard section for more information.

### Releasing Ownership

**Owner-Initiated Release:**
1. Touch collar → **Access** → **Release**
2. Owner confirms via dialog
3. Wearer then receives a separate confirmation dialog
4. Both must accept to complete the release
5. Wearer returns to unowned status (full self-control)

**Wearer Self-Release (Runaway):**
- Allows wearer to release themselves without owner permission
- Owner can enable/disable this feature: Touch collar → **Access** (as owner) → **Runaway: On/Off**
- Disabling runaway requires wearer consent (the wearer, not the owner, receives the confirmation dialog)
- Enabling runaway requires no consent (owner decision only)
- When available: Touch collar → **Access** → **Runaway** (if button shown)
- Requires confirmation before executing
- **Note:** Runaway is only available in single-owner mode. In multi-owner mode, this functionality is disabled.

### Transferring Ownership

1. Current owner: Touch collar → **Access** → **Transfer**
2. A sensor scan finds nearby avatars and displays a numbered list
3. Select the new owner from the list
4. The selected person receives an acceptance dialog
5. They click **Yes** and choose their honorific
6. Ownership transfers; the previous owner receives a notification
7. **Note:** Transfer is only available in single-owner mode

### Managing Trustees

Trustees have elevated permissions but cannot change ownership.

**Adding a Trustee:**
1. Owner: Touch collar → **Access** → **Add Trustee**
2. Select the person you want to add from the list
3. The selected person receives a dialog to accept the role
4. If they accept, they choose their honorific
5. Once chosen, they are added as a trustee

**Removing a Trustee:**
1. Owner: Touch collar → **Access** → **Rem Trustee**
2. Select trustee from list
3. They are immediately removed

### Multi-Owner Mode

The collar supports multiple owners sharing equal owner access.

**Enabling Multi-Owner Mode:**
- Multi-owner mode can **only** be enabled via the settings notecard
- Add `multi_owner_mode=1` to your settings notecard
- Cannot be changed through collar menus - this is intentional for stability

**Managing Owners in Multi-Owner Mode:**
- Owner lists are managed **exclusively via the settings notecard** (`access.owneruuids`, `access.ownerhonorifics`)
- All owner-editing buttons in the **Access** menu are hidden in multi-owner mode
- All owners have equal control
- Trustee management (add/remove trustees) remains available via the **Access** menu

### Managing the Blacklist

Blacklisted users (ACL -1) are completely blocked from collar interaction.

**Adding to Blacklist:**
1. Touch collar → **Blacklist** → **+Blacklist**
2. A sensor scan finds nearby avatars and displays a numbered list
3. Select the person from the list
4. They are immediately blocked

**Removing from Blacklist:**
1. Touch collar → **Blacklist** → **-Blacklist**
2. Select person from the numbered list
3. They are unblocked

**Viewing Blacklist Count:**
- The blacklist main menu displays the count of currently blacklisted users

---

## Leash System

The D/s Collar Modular features a sophisticated multi-mode leashing system supporting three different leash types.

### Leash Modes

#### 1. Avatar Mode (Default)
Leash the wearer to follow another avatar.

**To Leash (Avatar Mode):**
1. Touch collar → **Leash** → **Clip**
2. You are now holding the leash
3. Wearer will follow you automatically

**To Unleash:**
1. Touch collar → **Leash** → **Unclip**
2. Or: If in TPE mode — long-touch → **Unleash** via SOS menu

**Features:**
- Automatic follow mechanics
- Adjustable leash length (1m - 20m)
- Turn-to-face option
- Visual leash particle effect
- Works with or without RLV

#### 2. Coffle Mode
Leash one collar to another collar (collar-to-collar).

**Requirements:**
- Trustee or Owner only
- Both avatars wearing D/s Collar Modular

**To Create Coffle:**
1. Touch first collar → **Leash** → **Coffle**
2. Select the second avatar's collar from the menu list
3. Coffle is established

**Use Case:** Chain multiple submissives together in a train.

#### 3. Post Mode
Leash wearer to a fixed object or position.

**To Leash to Post:**
1. Touch collar → **Leash** → **Post**
2. Select the object to leash to from the menu list
3. Wearer is anchored to that position

**Use Case:** Tether submissive to furniture, poles, or fixed locations.

### Leash Settings

**Adjusting Leash Length:**
1. Touch collar → **Leash** → **Settings** → **Length**
2. Select from: 1m, 3m, 5m, 10m, 15m, 20m
3. Use **<<** / **>>** to fine-tune in 1m increments
4. Length changes immediately

**Turn-to-Face:**
1. Touch collar → **Leash** → **Settings** → **Turn: On/Off**
2. Toggle ON/OFF
3. When ON: Wearer automatically faces leash holder

**Yank Feature:**
- Leash holder can "yank" the leash to pull wearer closer
- Rate limited to prevent abuse (5 second cooldown)
- Provides instant feedback

### Leash Protocols

The collar supports multiple leashing protocols for compatibility:

- Native D/s collar holder and
- OpenCollar holders
Both modes support the Lockmeister chain protocol.

### Who Can Leash?

- **Leash to Avatar:** Public users (if public mode enabled), Trustees, or Owners
- **Collar-to-collar:** Trustees or Owners only
- **Post Mode:** Public users (if public mode enabled), Trustees, or Owners

---

## RLV Features

RLV (Restrained Love Viewer) provides advanced control over the wearer's viewer capabilities. **RLV-compatible viewer required** (Firestorm, RLVa, etc.).

### RLV Relay

The collar includes a built-in RLV Relay that allows scripted objects (furniture, traps, cages) to send RLV commands that control the collar wearer. The relay is the mechanism that receives and processes these commands.

**The relay defaults to ASK mode** on first wear — the wearer is always prompted before any external object can take control. This can be changed to ON (auto-accept) or OFF (ignore all) via the menu.

**Relay Modes:**

1. **OFF** - Relay disabled, furniture cannot control you
2. **ASK** (default) - Relay enabled, but wearer is prompted to accept or deny each relay request before it takes effect. Objects the wearer has already accepted in the current session are not re-prompted.
3. **ON** - Relay enabled, furniture can send RLV commands automatically. Wearer can use safeword to escape

**Hardcore Toggle:**
When the relay is in **ON** mode, Trustees and Primary Owners can additionally toggle **Hardcore** (HC ON / HC OFF). Hardcore mode prevents the wearer from using the safeword — only owners/trustees can release.

**Setting Relay Mode:**
1. Touch collar → **RLV Relay** → **Mode**
2. Select: **OFF**, **ON**, or **ASK**
3. Trustees and Primary Owners see additional **HC ON** / **HC OFF** buttons (only when mode is ON)
4. Mode persists across sessions

### RLV Restrictions

RLV Restrictions directly limit what the wearer can do in Second Life.

**Restriction Categories:**

#### Inventory Restrictions
- **Det. All** - Prevent removing all worn items
- **+ Outfit / - Outfit** - Block adding/removing outfits
- **- Attach / + Attach** - Block removing/adding attachments
- **Att. All** - Block all attachment changes
- **Inv** - Hide inventory contents
- **Notes** - Block viewing notecards
- **Scripts** - Block viewing scripts

#### Speech Restrictions
- **Chat** - Block sending local chat
- **Send IM** - Block sending instant messages
- **Recv IM** - Block receiving IMs
- **Start IM** - Block starting new IM sessions
- **Shout** - Block shouting
- **Whisper** - Block whispering

#### Travel Restrictions
- **Map TP** - Block map-based teleporting
- **Loc. TP** - Block location-based teleporting
- **TP** - Block teleport lure acceptance

#### Other Restrictions
- **Edit** - Prevent building/editing
- **Rez** - Block rezzing objects
- **Touch / Touch Wld** - Limit touching objects/world
- **OK TP** - Block accepting TP offers
- **Names** - Hide avatar names (anonymity)
- **Sit / Unsit / Stand** - Control sitting and standing

**Applying Restrictions:**
1. Touch collar → **Restrict**
2. Select category: **Inventory**, **Speech**, **Travel**, **Other**
3. Select specific restriction
4. Restriction applies immediately

**Removing Restrictions:**
1. Same menu path
2. Restrictions marked with checkmarks are active
3. Click active restriction to remove it

**Clearing All Restrictions:**
- Touch collar → **Restrict** → **Clear All**
- Or if in TPE mode — long-touch → **Clear RLV** via SOS menu

### RLV Exceptions

Exceptions allow specific people to bypass certain RLV restrictions.

**Available Exceptions:**

- **IM Exception** - Allow IMs from owner/trustees even when IMs blocked
- **TP Exception** - Allow TPs from owner/trustees even when TPs blocked

Each exception can be toggled independently for the owner and for trustees, giving four individual settings:
- Owner TP exception (`rlvex.ownertp`)
- Owner IM exception (`rlvex.ownerim`)
- Trustee TP exception (`rlvex.trusteetp`)
- Trustee IM exception (`rlvex.trusteeim`)

**Setting Exceptions:**
1. Touch collar → **Exceptions**
2. Select exception type and target (Owner or Trustee)
3. Exception applies immediately

**Why Use Exceptions?**
- Maintain control channel even under heavy restrictions
- Emergency communication/recall capability
- Owner bypass for strict restriction scenes

---

## Animations & Customization

### Animation Menu

The collar includes a paginated animation system that automatically detects animations in the collar inventory.

**Using Animations:**
1. Touch collar → **Animate**
2. You'll see up to 8 animations per page
3. Click animation name to play it
4. Use **<<** / **>>** to navigate pages
5. Use **STOP** to stop all animations

**Adding Custom Animations:**
1. Edit the collar object
2. Add your animation files to collar inventory
3. Animations automatically appear in menu
4. No script modification required

**Animation Access:**
- Wearer can play animations on themselves
- Owners and Trustees can animate the wearer

### Bell System

The collar bell provides visual and audio feedback for movement.

**Bell Controls:**
1. Touch collar → **Bell**
2. Available options (available to Trustees, an unowned wearer, or the primary owner):

**Show/Hide Bell:**
- **Show: Y** / **Show: N** - Toggle button; shows or hides the bell prim

**Bell Sound:**
- **Sound: On** / **Sound: Off** - Toggle button; enables or silences the jingle

**Volume Control:**
- **Volume +** - Increase volume one step
- **Volume -** - Decrease volume one step
- Only affects bell sound, not other collar sounds

**Bell Settings Persist:**
All bell preferences are saved and restored after logout/login.

---

## Safety & Emergency Features

### SOS Emergency Menu

**The emergency escape hatch for TPE-mode wearers.**

The SOS menu is specifically designed for wearers in **TPE mode** (ACL level 0 — no normal collar access). Owned wearers not in TPE have full collar access and can use the regular menus to unleash, clear restrictions, etc. The SOS options simply do not appear for them.

**Accessing SOS Menu (TPE wearers only):**
1. **Long-touch** the collar (hold for 1.5+ seconds)
2. SOS options appear

**SOS Menu Options:**

#### Unleash
- Immediately releases any active leash
- No confirmation required
- Instant effect

#### Clear RLV
- Removes all RLV restrictions applied by collar
- Emergency restriction removal
- Does not affect relay devices

#### Clear Relay
- Removes all restrictions from RLV relay sources
- Releases control by external devices
- Sends release commands to all relay sources

**When to Use SOS:**
- Stuck in restrictions
- Lost owner/controller
- Griefing or abuse situation
- Uncomfortable with scene
- Technical issues preventing normal menu access

### Lock/Unlock Feature

The lock prevents unauthorized removal of the collar.

**Locking the Collar:**
1. Touch collar → **Locked: N** (to lock) or **Locked: Y** (to unlock)
2. Collar locks/unlocks immediately
3. If RLV enabled: Prevents detaching collar
4. Lock state persists

**Unlocking the Collar:**
1. Touch collar → **Lock** (again)
2. Collar unlocks immediately
3. Wearer can now detach collar

**Who Can Lock/Unlock?**
- Unowned wearer - Can lock/unlock own collar
- Owner - Can lock/unlock collar

**Visual Feedback:**
- Locked state shown in Status display
- Audio confirmation on lock/unlock

### Public Access Toggle

Controls whether strangers can interact with collar.

**Enabling Public Access:**
1. Touch collar → **Public** → **Enable**
2. Any nearby person can now use limited features
3. Status shows "Public: ON"

**Disabling Public Access:**
1. Touch collar → **Public** → **Disable**
2. Only owner, trustees, and wearer have access
3. Status shows "Public: OFF"

**Who Can Toggle Public?**
- Trustees or Owners

**What Can Public Users Do?**
- View status
- Use leash (avatar and post modes)
- Limited menu access
- Cannot change settings or ownership

### Total Power Exchange (TPE) Mode

TPE mode gives complete control to the owner by removing wearer's collar access.

**Enabling TPE (Owner):**
1. Touch collar → **TPE** (the button toggles; click it to enable)
2. Wearer receives a consent dialog explaining they will relinquish all collar control
3. Wearer must click **Yes** to consent
4. Wearer loses all normal collar access
5. Wearer receives notification: "TPE mode enabled. You have relinquished collar control."

**Disabling TPE (Owner):**
1. Touch collar → **TPE** (click the toggle button again to disable)
2. No wearer confirmation required - owner decision only
3. Wearer returns to normal operation status
4. Wearer receives notification: "Your collar access has been restored."

**Important Notes:**
- **Wearers in TPE mode retain SOS menu access** through long-touch.
- Only the Owner can enable or disable TPE, and TPE is only available when there is at least one primary owner available.
- Use TPE responsibly, and only with trusted partners

---

## Control HUD (Remote Control)

The D/s Collar Control HUD allows owners/trustees to control the collar without relying on touching it directly.

### Setting Up the HUD

1. **Rez the HUD object** in Second Life
2. **Add the control HUD script**: Drop `ds_collar_control_hud.lsl` into the object
3. **Wear the HUD**: Attach it to your screen position
4. **HUD auto-detects** nearby collars automatically

### Using the HUD

**Auto-Detection:**
- HUD automatically scans for nearby D/s Collars
- If one collar found: Auto-connects
- If multiple collars found: Shows selection menu

**Remote Menu Access:**
- All collar menus accessible through HUD
- Same ACL restrictions apply
- Uses region-wide broadcast channels for communication

**HUD Features:**
- ACL level verification
- Session management
- Automatic collar detection via broadcast

**Benefits:**
- Control collar without being physically next to wearer
- Multiple collar management
- Discreet control interface
- Same security as direct touch

---

## Configuration & Settings

### Settings Notecard

The collar supports pre-configuration via a notecard named **"settings"** in the collar inventory.

**Creating Settings Notecard:**

1. Edit the collar object
2. Create new notecard named exactly: **settings**
3. Add configuration in `key = value` format (dotted namespace keys)
4. Save notecard
5. Reset collar scripts to load

**Settings Notecard Format:**

All settings keys use **dotted `namespace.setting` format**. Owner and
trustee data is stored as flat scalars (single-owner mode) or parallel
CSVs (multi-owner mode). The parser does **not** accept JSON object
syntax for ownership keys.

```
# D/s Collar Settings
# Lines starting with # are comments
# Format: key = value

# Ownership (Single Owner)
access.multiowner = 0
access.owner = a1b2c3d4-e5f6-7890-abcd-ef1234567890
access.ownerhonorific = Master

# Trustees (parallel CSVs in the same order)
access.trusteeuuids = 12345678-90ab-cdef-1234-567890abcdef,abcdef01-2345-6789-abcd-ef0123456789
access.trusteehonorifics = Mistress,Daddy

# Blacklist (plain CSV of UUIDs)
blacklist.blklistuuid = fedcba98-7654-3210-fedc-ba9876543210

# Access Control
public.mode = 0
tpe.mode = 0
lock.locked = 0

# Bell Settings
bell.visible = 1
bell.enablesound = 1
bell.volume = 0.3
bell.sound = 16fcf579-82cb-b110-c1a4-5fa5e1385406
```

**Note:** RLV settings (relay mode, restrictions, exceptions) and leash
settings (length, turn-to-face) cannot be pre-configured via notecard.
These must be set through the collar menus after startup.

### Available Settings Keys

**Ownership & Access Control:**

| Key | Type | Description | Example |
|-----|------|-------------|---------|
| `access.multiowner` | 0/1 | Enable multi-owner mode (notecard only) | `0` = off, `1` = on |
| `access.owner` | bare UUID | Single owner UUID | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` |
| `access.ownerhonorific` | string | Honorific for the single owner | `Master` |
| `access.owneruuids` | CSV of UUIDs | Multi-owner UUID list (notecard only) | `uuid1,uuid2` |
| `access.ownerhonorifics` | CSV of strings | Honorifics, parallel to `access.owneruuids` | `Sir,Ma'am` |
| `access.trusteeuuids` | CSV of UUIDs | Trusted user UUIDs | `uuid1,uuid2` |
| `access.trusteehonorifics` | CSV of strings | Honorifics, parallel to `access.trusteeuuids` | `Sir,Lady` |
| `blacklist.blklistuuid` | CSV of UUIDs | Blacklisted users | `fedcba98-...,00000000-...` |
| `access.enablerunaway` | 0/1 | Enable runaway feature for wearer | `0` = off, `1` = on |

**Note:** UUIDs and honorifics are kept in **separate parallel CSVs** in
multi-owner mode — the first uuid pairs with the first honorific, and so
on. Display names are resolved automatically by the collar.

**Collar State:**

| Key | Type | Description | Example |
|-----|------|-------------|---------|
| `public.mode` | 0/1 | Public access | `0` = off, `1` = on |
| `lock.locked` | 0/1 | Lock state | `0` = unlocked, `1` = locked |
| `tpe.mode` | 0/1 | TPE mode | `0` = off, `1` = on |

**Bell Settings:**

| Key | Type | Description | Example |
|-----|------|-------------|---------|
| `bell.visible` | 0/1 | Bell visibility | `0` = hidden, `1` = visible |
| `bell.enablesound` | 0/1 | Bell sound | `0` = silent, `1` = enabled |
| `bell.volume` | Float | Bell volume | `0.0` to `1.0` |
| `bell.sound` | UUID | Bell sound asset UUID | `16fcf579-82cb-b110-c1a4-5fa5e1385406` |

**RLV Exception Settings:**

| Key | Type | Description | Example |
|-----|------|-------------|---------|
| `rlvex.ownertp` | 0/1 | Allow owner to TP wearer despite restrictions | `0` = off, `1` = on |
| `rlvex.ownerim` | 0/1 | Allow owner to IM wearer despite restrictions | `0` = off, `1` = on |
| `rlvex.trusteetp` | 0/1 | Allow trustees to TP wearer despite restrictions | `0` = off, `1` = on |
| `rlvex.trusteeim` | 0/1 | Allow trustees to IM wearer despite restrictions | `0` = off, `1` = on |

**Notes:**
- Keys marked "notecard only" can only be set via settings notecard, not via runtime messages
- RLV relay mode and restriction lists are **not supported** in notecard configuration
- Leash settings (length, turn-to-face) are **not supported** in notecard configuration
- All non-notecard-only settings persist automatically when changed via menus
- For full details on notecard syntax and configuration patterns, see [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md)

### Finding Avatar UUIDs

To add UUIDs to the settings notecard:

**Method 1: Viewer Feature**
- Right-click avatar → Select "Copy Key" (available in Firestorm and most modern viewers)

**Method 2: In-World Script**
```lsl
// Drop in a prim and touch it to see your UUID, or touch another avatar
default {
    touch_start(integer num) {
        llSay(0, "UUID: " + (string)llDetectedKey(0));
    }
}
```

**Method 3: Your Own UUID**
```lsl
default {
    state_entry() {
        llOwnerSay((string)llGetOwner());
    }
}
```

### Viewing Current Settings

**Via Collar Menu:**
1. Touch collar → **Maintenance** → **View Settings**
2. Settings displayed in local chat
3. Shows all current key-value pairs

**What Gets Saved:**
- All settings persist automatically
- Changes sync across all scripts
- Survives logout/login
- Survives script resets

---

## Troubleshooting

### Common Issues

#### Collar Not Responding to Touch
**Symptoms:** Touching collar does nothing.

**Solutions:**
1. Check scripts are running (Edit object → Contents → Scripts not in "Not Running" state)
2. Reset scripts: Right-click → Reset Scripts
3. Check you're within touch range
4. If in TPE mode, long-touch for SOS menu; otherwise check script errors

#### Menu Buttons Not Working
**Symptoms:** Clicking menu buttons has no effect.

**Solutions:**
1. Wait for menu timeout (60 seconds)
2. Close menu and re-open
3. Check for script errors in console
4. Reset collar scripts

#### RLV Features Not Working
**Symptoms:** RLV commands have no effect.

**Solutions:**
1. Verify you're using RLV-compatible viewer (Firestorm recommended)
2. Check RLV is enabled in viewer preferences
3. Verify collar detected RLV at startup (check console)
4. Re-log and reset collar scripts

#### Leash Doesn't Follow
**Symptoms:** Leashed avatar doesn't follow holder.

**Solutions:**
1. Check leash length isn't too long
2. Verify holder is moving (leash is pull-based)
3. Ensure no conflicting animations or AOs
4. Try unleashing and re-leashing
5. Check RLV enabled for best follow performance

#### Can't Access Own Collar
**Symptoms:** Wearer can't open menus.

**Solutions:**
1. Check if TPE mode is enabled (removes collar access)
2. If TPE is enabled: long-touch to access SOS menu, then contact your owner to disable TPE
3. If not in TPE mode, you should still have normal access — check for script errors
4. Check you're not blacklisted (unlikely but possible)

#### Settings Not Saving
**Symptoms:** Changes reset after relog.

**Solutions:**
1. Wait 5 seconds after making changes before relogging
2. Check `kmod_settings` script is present and running
3. Check object permissions allow script modifications
4. Reset collar scripts

#### HUD Not Detecting Collar
**Symptoms:** Control HUD shows no collars.

**Solutions:**
1. Verify collar is within 20 meters
2. Reset HUD script
3. Reset collar scripts
4. Check both HUD and collar scripts running
5. Ensure collar wearer is in same region

### Error Messages

#### "ACL Denied"
- You don't have permission for this action
- Check your ACL level (Status menu)
- Contact owner for access

#### "RLV Not Detected"
- Viewer doesn't support RLV or RLV disabled
- Enable RLV in viewer preferences
- Re-log after enabling

#### "Owner Already Set"
- Collar already has an owner
- Current owner must release before new ownership
- Or use Transfer feature

#### "Timeout Waiting for Response"
- Script communication delay
- Reset collar scripts
- Check script memory limits

#### "Invalid UUID"
- Avatar UUID format incorrect in settings
- Verify UUID format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- Owner UUID uses plain scalar: `access.owner = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- Multiple trustees/owners use CSV format: `access.trusteeuuids = uuid1,uuid2`
- Blacklist uses CSV format: `blacklist.blklistuuid = uuid1,uuid2`
- Do **not** use JSON object or array notation — the parser expects plain scalars and CSVs
- Check for typos in settings notecard

### Performance Issues

#### Lag or Slow Response
**Solutions:**
1. Remove unused plugins to reduce script count
2. Ensure collar is worn as attached prim (not temporary)
3. Check region script limits aren't exceeded
4. Reduce number of active timers (fewer plugins = fewer timers)

#### Script Memory Errors
**Solutions:**
1. LSL scripts have 64KB memory limit per script
2. Remove custom animations if memory is full
3. Consider splitting features across multiple collar objects
4. Remove unused plugins

### Getting Help

If problems persist:

1. **Check Documentation:** Review this guide and README.md
2. **Check GitHub Issues:** https://github.com/anne-skydancer/ds_collar_modular/issues
3. **Report Bugs:** Create detailed issue report with:
   - Exact steps to reproduce
   - Error messages from console
   - Viewer version and RLV status
   - Collar revision (check script headers if possible)
4. **Community Support:** Contact the collar creator or community

---

## FAQ

### General Questions

**Q: Do I need RLV to use the collar?**
A: No. Basic features (owner management, leash, animations, bell) work without RLV. However, RLV features (relay, restrictions) require an RLV-compatible viewer like Firestorm.

**Q: Can I customize the appearance of the collar?**
A: Yes. The collar is a standard Second Life prim object. You can texture it, resize it, and make it invisible. The scripts work independently of appearance.

**Q: How many plugins can I add?**
A: The collar supports unlimited plugins within Second Life's script limits (typically 64 scripts per object in most regions). Currently there are 16 standard plugins in a full installation, but it may have as little as two.

**Q: Is this compatible with OpenCollar?**
A: Partially. The leash system supports OpenCollar 8.x holder protocol. However, OpenCollar plugins and add-ons are not compatible. This is a separate, independent collar system.

**Q: Can I copy this collar to give to others?**
A: Generally yes, as long as the collar is made either no-copy or no-transfer for the next user.

### Ownership Questions

**Q: Can I have multiple owners?**
A: Yes. Enable `multi_owner_mode=1` in settings notecard. All owners have equal owner access.

**Q: What happens if my owner disappears/quits SL?**
A: If unowned access is available, you can use the Runaway feature (if enabled). Otherwise, you'll need to reset the collar (which clears ownership) or contact the creator for assistance.

**Q: Can trustees change ownership?**
A: No. Only owners can modify ownership. Trustees have elevated control but cannot add/remove owners.

**Q: Can I be my own owner?**
A: If you have no owner set, you already have full owner-level access to your collar. When you set a primary owner, you lose that access level - you cannot add yourself to the owner list or make yourself a trustee. The collar is designed so that only other avatars can be added as owners or trustees.

### RLV Questions

**Q: What are the relay modes?**
A: The relay defaults to **ASK** mode, which prompts the wearer to accept or deny each request from external objects. **ON** allows external devices to send RLV commands automatically; the wearer can safeword out. **OFF** disables the relay entirely. When the relay is **ON**, an owner or trustee can additionally toggle **Hardcore** mode, which prevents the wearer from using the safeword.

**Q: Can I use a safeword with RLV relay?**
A: Yes. The collar implements ORG relay specification which includes safeword support. Configure your safeword in your RLV viewer settings.

**Q: What if I get stuck in restrictions?**
A: If you are in **TPE mode**, long-touch the collar to access the SOS menu → **Clear RLV** or **Clear Relay**. If you are an owned wearer not in TPE mode, you have normal collar access — touch the collar and use **Restrict** → **Clear All**, or contact your owner.

**Q: Do RLV exceptions work for everyone?**
A: No. Only TP and IM exceptions are available, and each can be toggled independently for the owner and for trustees. They bypass specific restrictions only for authorized users.

### Leash Questions

**Q: What's the difference between leash modes?**
A:
- **Avatar Mode:** Leash to follow another avatar (most common)
- **Coffle Mode:** Chain collar-to-collar (multiple submissives)
- **Post Mode:** Anchor to fixed object or point

**Q: Can I be leashed if public mode is off?**
A: Only by trustees and owners. Public mode must be ON for strangers to leash.

**Q: Does leashing require RLV?**
A: No. Basic leashing works without RLV using movement scripts. RLV enhances the experience but isn't required.

**Q: Can I unleash myself?**
A: If you have normal collar access (owned non-TPE, or unowned), touch the collar and use **Leash** → **Unclip**. If you are in **TPE mode**, long-touch the collar to access the SOS menu → **Unleash**. In both cases there is always a path to release the leash.

### Safety Questions

**Q: Can someone lock me in restrictions permanently?**
A: No. If you have normal collar access, your owner can always clear restrictions, and you can contact them. If you are in TPE mode, the SOS long-touch menu provides emergency restriction removal. In either case there is a path out.

**Q: What if I accidentally enable TPE mode?**
A: TPE requires wearer confirmation. If enabled, contact your owner to disable it. The SOS menu remains accessible for emergencies.

**Q: Can the blacklist be used to trap me?**
A: No. The blacklist prevents others from accessing the collar. As the wearer, you always retain your own collar access (owned or unowned status). If you are placed in TPE mode, the SOS long-touch menu is also available.

**Q: Is my privacy protected?**
A: The collar operates locally on your avatar. No data is transmitted to external servers. All control is in-world only. Settings are stored in the collar object, not in external databases.

### Technical Questions

**Q: Why does the collar use so many scripts?**
A: The modular architecture uses one script per feature (plugin). This improves performance, maintainability, and allows you to remove features you don't use. Each script is optimized and lightweight.

**Q: What are the script memory limits?**
A: Each LSL script has 64KB memory limit. The collar kernel and modules are optimized to stay well under this limit.

**Q: Can I see the source code?**
A: Yes. The collar is open source. All scripts are available at: https://github.com/anne-skydancer/ds_collar_modular

**Q: How do I update to a new version?**
A: Replace old scripts with new scripts from the latest release. The kernel compatibility ensures plugins work across revisions. Always backup your settings notecard first.

**Q: How does the collar implement menus?**
A: The collar uses llDialog extensively. All menus are standard SL dialog boxes. A centralized dialog bus (link message lane 950) ensures efficient dialog management across all plugins.

### Feature Requests

**Q: Can you add [feature]?**
A: The collar is modular and extensible. You can:
1. Request features via GitHub issues
2. Write your own plugin (see agents.md for development guide)
3. Contribute code via pull requests

---

## Additional Resources

- **Main README:** [README.md](README.md) - Technical overview and architecture
- **Settings Reference:** [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md) - Complete settings key documentation and notecard syntax
- **Developer Guide:** [agents.md](agents.md) - LSL coding standards and plugin development
- **Security Documentation:** [SECURITY_AUDIT_REPORT.md](SECURITY_AUDIT_REPORT.md)
- **GitHub Repository:** https://github.com/anne-skydancer/ds_collar_modular

---

## Version Information

The DS Collar Modular system uses a **Revision-based** versioning scheme.
- **System Version:** Currently **1.0**
- **Revision:** Increments with each update.

This user guide corresponds to:
- **Kernel Revision:** 39
- **Module Revisions:** 26 - 44
- **Plugin Revisions:** 22 - 25

The revision number can be found in the header of each script.

---

## Support & Community

For support:
- **GitHub Issues:** Report bugs and request features
- **Documentation:** Check README.md and this user guide
- **Source Code:** Review scripts for detailed behavior

Stay safe and enjoy your collar!

---

*D/s Collar Modular - A modern, secure, and extensible D/s collar system for Second Life.*
*Licensed as open source software under MIT License