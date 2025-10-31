# DS Collar Modular - User Guide

Welcome to the DS Collar Modular system! This guide will help you understand and use all features of your collar, whether you're a collar wearer or an owner/dominant.

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

**DS Collar Modular** is a modern, lightweight D/s (Dominant/submissive) collar system for Second Life. It provides comprehensive control features including:

- Owner and trustee management
- Multi-mode leashing system
- RLV (Restrained Love) integration
- Animation controls
- Bell system with customizable sounds
- Total Power Exchange (TPE) mode
- Emergency safety features

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
4. **Long-touch (1.5+ seconds)** - Access emergency SOS menu at any time

### For Owners/Dominants

1. **Touch the collar** - Open the main menu
2. **Select "Owner"** - Access owner management
3. **Claim ownership** - Set yourself as owner
4. **Explore features** - Leash, RLV, animations, and more
5. **Configure settings** - Customize lock, TPE, public access

---

## Understanding Access Levels

The collar uses 7 access levels ranging from -1 to 5 in its Access Control List (ACL) system to determine who can do what:

| Level | Name | Who Has It | What They Can Do |
|-------|------|-----------|------------------|
| **-1** | Blacklisted | Users explicitly blocked | Nothing - complete denial of access |
| **0** | No Access | Unknown users, wearer in TPE mode | No collar access except SOS menu |
| **1** | Public | Anyone (when public mode enabled) | Limited features like status view |
| **2** | Owned | Collar wearer (when owned) | Personal animations, bell, limited settings |
| **3** | Trustee | Trusted users set by owner | Leashing, some RLV, but not ownership changes |
| **4** | Unowned | Collar wearer (when not owned) | Full self-control, can set owners |
| **5** | Primary Owner | The owner(s) | Complete control over all features |

**Important:** Blacklist (ACL -1) always takes precedence. If someone is blacklisted, they cannot interact with the collar regardless of other permissions.

---

## Basic Operations

### Opening the Menu

**Regular Touch:** Touch the collar once to open the main menu. You'll see all options you have permission to access.

**Long Touch (Emergency):** Touch and hold the collar for 1.5+ seconds to access the emergency SOS menu. This works even when you have no normal access.

### Navigating Menus

- **Menu Buttons:** Click any button to select that option
- **<< and >>:** Navigation arrows for multi-page menus
- **↩ BACK:** Return to previous menu
- **✗ CLOSE:** Close all menus
- **Timeout:** Menus automatically close after 60 seconds of inactivity

### Menu Structure

```
Main Menu
├── Owner          (Owner & trustee management)
├── Leash          (Leashing controls)
├── RLV Relay      (RLV relay settings)
├── RLV Restrict   (RLV restrictions)
├── RLV Exceptions (RLV bypass rules)
├── Animate        (Animation menu)
├── Bell           (Bell settings)
├── Lock           (Lock/unlock toggle)
├── Public         (Public access toggle)
├── TPE            (Total Power Exchange mode)
├── Status         (View collar status)
├── Blacklist      (Manage blocked users)
├── Maintenance    (View settings)
└── SOS            (Emergency menu - long touch)
```

---

## Owner & Access Management

### Setting Ownership

**For Unowned Wearers (ACL 4):**

1. Touch collar → **Owner**
2. Select **Set Owner**
3. Owner will receive a confirmation dialog
4. Owner clicks **Accept** to claim ownership
5. Ownership is established

**Important:** Once owned, the wearer becomes ACL 2 (Owned) and cannot change ownership without owner permission.

### Releasing Ownership

**Owner-Initiated Release:**
1. Touch collar → **Owner** → **Release**
2. Both owner and wearer receive confirmation dialogs
3. Both must accept to complete the release
4. Wearer returns to ACL 4 (Unowned)

**Wearer Self-Release (Runaway):**
- Available only if enabled by owner
- Touch collar → **Owner** → **Runaway** (if available)
- Immediate self-release without owner confirmation
- Use responsibly - this is for emergency situations

### Transferring Ownership

1. Current owner: Touch collar → **Owner** → **Transfer**
2. Touch the new owner avatar
3. New owner receives offer dialog
4. Current owner and new owner must both accept
5. Ownership transfers completely

### Managing Trustees

Trustees (ACL 3) have elevated permissions but cannot change ownership.

**Adding a Trustee:**
1. Owner: Touch collar → **Owner** → **Trustee+**
2. Touch the person you want to add
3. They are immediately added as trustee

**Removing a Trustee:**
1. Owner: Touch collar → **Owner** → **Trustee-**
2. Select trustee from list
3. They are immediately removed

**Setting Trustee Honorifics:**
1. Touch collar → **Owner** → **Trustee Hon**
2. Select the trustee from list
3. Choose honorific: Master, Mistress, Daddy, Mommy, King, Queen, or None

### Multi-Owner Mode

The collar supports multiple owners sharing ACL 5 access.

**Enabling Multi-Owner Mode:**
1. Add "multi_owner_mode=1" to settings notecard, OR
2. Use maintenance tools to modify settings

**Adding Additional Owners:**
- Same process as adding trustees, but they receive ACL 5
- All owners have equal control
- Any owner can add/remove other owners

### Managing the Blacklist

Blacklisted users (ACL -1) are completely blocked from collar interaction.

**Adding to Blacklist:**
1. Touch collar → **Blacklist** → **Add**
2. Touch the person to blacklist
3. They are immediately blocked

**Removing from Blacklist:**
1. Touch collar → **Blacklist** → **Remove**
2. Select person from list
3. They are unblocked

**Viewing Blacklist:**
- Touch collar → **Blacklist** → **List**
- Shows all blacklisted users with display names

---

## Leash System

The DS Collar Modular features a sophisticated multi-mode leashing system supporting three different leash types.

### Leash Modes

#### 1. Avatar Mode (Default)
Leash the wearer to follow another avatar.

**To Leash (Avatar Mode):**
1. Touch collar → **Leash** → **Grab**
2. You are now holding the leash
3. Wearer will follow you automatically

**To Unleash:**
1. Touch collar → **Leash** → **Unleash**
2. Or: Wearer uses SOS menu → **Unleash**

**Features:**
- Automatic follow mechanics
- Adjustable leash length (1m - 20m)
- Turn-to-face option
- Visual leash particle effect
- Works with or without RLV

#### 2. Coffle Mode
Leash one collar to another collar (collar-to-collar).

**Requirements:**
- ACL 3 or higher (Trustee or Owner only)
- Both avatars wearing DS Collar Modular

**To Create Coffle:**
1. Touch first collar → **Leash** → **Mode** → **Coffle**
2. Touch first collar → **Leash** → **Grab**
3. Touch second avatar's collar
4. Coffle is established

**Use Case:** Chain multiple submissives together in a train.

#### 3. Post Mode
Leash wearer to a fixed object or position.

**To Leash to Post:**
1. Touch collar → **Leash** → **Mode** → **Post**
2. Touch collar → **Leash** → **Grab**
3. Touch the object or point to leash to
4. Wearer is anchored to that position

**Use Case:** Tether submissive to furniture, poles, or fixed locations.

### Leash Settings

**Adjusting Leash Length:**
1. Touch collar → **Leash** → **Length**
2. Select from: 1m, 2m, 3m, 5m, 10m, 15m, 20m
3. Length changes immediately

**Turn-to-Face:**
1. Touch collar → **Leash** → **Turn2Face**
2. Toggle ON/OFF
3. When ON: Wearer automatically faces leash holder

**Yank Feature:**
- Leash holder can "yank" the leash to pull wearer closer
- Rate limited to prevent abuse (5 second cooldown)
- Provides instant feedback

### Leash Protocols

The collar supports multiple leashing protocols for compatibility:

- **DS Holder** - Native DS collar holder protocol
- **OpenCollar 8.x** - Compatible with OpenCollar holders
- **Avatar Direct** - Direct avatar-to-avatar leashing
- **Lockmeister** - Classic Lockmeister chain protocol

### Who Can Leash?

- **Avatar Mode:** ACL 1+ (Public if enabled, Trustee, Owner)
- **Coffle Mode:** ACL 3+ (Trustee, Owner only)
- **Post Mode:** ACL 1, 3, 5 (Public if enabled, Trustee, Owner)

---

## RLV Features

RLV (Restrained Love Viewer) provides advanced control over the wearer's viewer capabilities. **RLV-compatible viewer required** (Firestorm, RLVa, etc.).

### RLV Relay

The RLV Relay allows scripted objects (furniture, traps, cages) to control the collar wearer.

**Relay Modes:**

1. **OFF** - Relay disabled, no external control
2. **ON** - Relay enabled with normal restrictions
3. **HARDCORE** - Relay enabled with maximum restrictions

**Setting Relay Mode:**
1. Touch collar → **RLV Relay**
2. Select: **OFF**, **ON**, or **HARDCORE**
3. Mode persists across sessions

**How It Works:**
- Compatible devices send relay requests to collar
- Collar validates and applies restrictions
- Works with ORG relay specification
- Includes safeword support

### RLV Restrictions

RLV Restrictions directly limit what the wearer can do in Second Life.

**Restriction Categories:**

#### Inventory Restrictions
- **Detach** - Prevent removing worn items
- **Add/Remove Outfit** - Block outfit changes
- **Add/Remove Clothing** - Control clothing layers
- **Show/Edit Scripts** - Hide script contents

#### Speech Restrictions
- **Send Chat** - Block local chat
- **Send IM** - Block instant messages
- **Receive Chat** - Block receiving chat
- **Receive IM** - Block receiving IMs
- **Hear/Read Chat** - Sensory deprivation options

#### Travel Restrictions
- **Teleport** - Block teleporting
- **Accept TP** - Block accepting TP offers
- **Stand** - Force sitting
- **Sit** - Block sitting

#### Other Restrictions
- **Edit** - Prevent building/editing
- **Rez** - Block rezzing objects
- **Touch** - Limit touching objects
- **Show Names** - Hide avatar names (anonymity)

**Applying Restrictions:**
1. Touch collar → **RLV Restrict**
2. Select category: **Inventory**, **Speech**, **Travel**, **Other**
3. Select specific restriction
4. Restriction applies immediately

**Removing Restrictions:**
1. Same menu path
2. Restrictions marked with checkmarks are active
3. Click active restriction to remove it

**Clearing All Restrictions:**
- Touch collar → **RLV Restrict** → **Clear All**
- Or use SOS menu → **Clear RLV**

### RLV Exceptions

Exceptions allow specific people to bypass certain RLV restrictions.

**Common Exceptions:**

- **IM Exception** - Allow IMs from owner/trustees even when IMs blocked
- **TP Exception** - Allow TPs from owner/trustees even when TPs blocked
- **Touch Exception** - Allow owner/trustees to be touched

**Setting Exceptions:**
1. Touch collar → **RLV Exceptions**
2. Select exception type
3. Choose who gets exception: Owner, Trustees, or Both
4. Exception applies immediately

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
- Wearer (ACL 2, 4) can play animations on themselves
- Owner/Trustees (ACL 3, 5) can animate the wearer

### Bell System

The collar bell provides visual and audio feedback for movement.

**Bell Controls:**
1. Touch collar → **Bell**
2. Available options:

**Show/Hide Bell:**
- **Show** - Bell visible on collar
- **Hide** - Bell invisible

**Bell Sound:**
- **Sound On** - Jingle plays on movement
- **Sound Off** - Silent operation

**Volume Control:**
- Adjustable from 0% to 100% in 10% increments
- Select **Volume** → Choose level
- Only affects bell sound, not other collar sounds

**Bell Settings Persist:**
All bell preferences are saved and restored after logout/login.

---

## Safety & Emergency Features

### SOS Emergency Menu

**The most important safety feature of the collar.**

**Accessing SOS Menu:**
1. **Long-touch** the collar (hold for 1.5+ seconds)
2. SOS menu appears **even if you have ACL 0 (no access)**
3. Available at all times, cannot be disabled

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
1. Touch collar → **Lock**
2. Collar locks immediately
3. If RLV enabled: Prevents detaching collar
4. Lock state persists

**Unlocking the Collar:**
1. Touch collar → **Lock** (again)
2. Collar unlocks immediately
3. Wearer can now detach collar

**Who Can Lock/Unlock?**
- ACL 4 (Unowned wearer) - Can lock/unlock own collar
- ACL 5 (Owner) - Can lock/unlock collar

**Visual Feedback:**
- Locked state shown in Status display
- Audio confirmation on lock/unlock

### Public Access Toggle

Controls whether strangers (ACL 1) can interact with collar.

**Enabling Public Access:**
1. Touch collar → **Public** → **Enable**
2. Any nearby person can now use limited features
3. Status shows "Public: ON"

**Disabling Public Access:**
1. Touch collar → **Public** → **Disable**
2. Only owner, trustees, and wearer have access
3. Status shows "Public: OFF"

**Who Can Toggle Public?**
- ACL 3+ (Trustee or Owner)

**What Can Public Users Do?**
- View status
- Use leash (avatar and post modes)
- Limited menu access
- Cannot change settings or ownership

### Total Power Exchange (TPE) Mode

TPE mode gives complete control to the owner by removing wearer's collar access.

**Enabling TPE (Owner):**
1. Touch collar → **TPE** → **Enable**
2. Wearer receives confirmation dialog: "Accept TPE mode? You will have no collar access."
3. Wearer must click **Accept**
4. Wearer becomes ACL 0 (No Access)

**Disabling TPE (Owner):**
1. Touch collar → **TPE** → **Disable**
2. No confirmation required
3. Wearer returns to ACL 2 (Owned)

**Important Notes:**
- **Wearer always retains SOS menu access** (long-touch)
- Only Primary Owner (ACL 5) can enable/disable TPE
- TPE state persists across logins
- Use responsibly with trusted partners

---

## Control HUD (Remote Control)

The DS Collar Control HUD allows owners/trustees to control the collar from a distance.

### Setting Up the HUD

1. **Rez the HUD object** in Second Life
2. **Add the control HUD script**: Drop `ds_collar_control_hud.lsl` into the object
3. **Wear the HUD**: Attach it to your screen position
4. **HUD auto-detects** nearby collars automatically

### Using the HUD

**Auto-Detection:**
- HUD automatically scans for nearby DS Collars
- If one collar found: Auto-connects
- If multiple collars found: Shows selection menu

**Remote Menu Access:**
- All collar menus accessible through HUD
- Same ACL restrictions apply
- Works within 20 meter range

**HUD Features:**
- ACL level verification
- Rate limiting (2 second cooldown per request)
- Session management
- Range checking

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
3. Add configuration in `key=value` format
4. Save notecard
5. Reset collar scripts to load

**Settings Notecard Format:**

```
# DS Collar Settings
# Lines starting with # are comments
# Format: key=value
# Lists: key=[uuid1,uuid2,uuid3]

# Ownership
owner_key=12345678-1234-1234-1234-123456789abc
owner_hon=Master
multi_owner_mode=0

# Access Control
public_mode=1
trustees=[uuid1,uuid2,uuid3]
trustee_honorifics=[Mistress,Master,Daddy]
blacklist=[uuid4,uuid5]

# Collar State
locked=0
tpe_mode=0

# Bell Settings
bell_visible=1
bell_sound_enabled=1
bell_volume=0.3

# RLV Settings
rlv_relay_mode=1
rlv_restrictions=[]
rlv_exceptions=[]

# Leash Settings
leash_length=3
leash_turn2face=1
```

### Available Settings Keys

| Key | Type | Description | Example |
|-----|------|-------------|---------|
| `owner_key` | UUID | Owner's avatar UUID | `12345678-1234-...` |
| `owner_hon` | String | Owner's honorific | `Master`, `Mistress` |
| `multi_owner_mode` | 0/1 | Enable multi-owner | `0` = off, `1` = on |
| `public_mode` | 0/1 | Public access | `0` = off, `1` = on |
| `locked` | 0/1 | Lock state | `0` = unlocked, `1` = locked |
| `tpe_mode` | 0/1 | TPE mode | `0` = off, `1` = on |
| `bell_visible` | 0/1 | Bell visibility | `0` = hidden, `1` = visible |
| `bell_sound_enabled` | 0/1 | Bell sound | `0` = silent, `1` = enabled |
| `bell_volume` | Float | Bell volume | `0.0` to `1.0` |
| `leash_length` | Integer | Leash length in meters | `1` to `20` |
| `leash_turn2face` | 0/1 | Turn to face | `0` = off, `1` = on |
| `trustees` | List | Trustee UUIDs | `[uuid1,uuid2]` |
| `trustee_honorifics` | List | Trustee titles | `[Master,Mistress]` |
| `blacklist` | List | Blacklisted UUIDs | `[uuid1,uuid2]` |
| `rlv_relay_mode` | 0/1/2 | Relay mode | `0`=OFF, `1`=ON, `2`=HARDCORE |
| `rlv_restrictions` | List | Active restrictions | `[detach,sendchat]` |
| `rlv_exceptions` | List | RLV exceptions | `[im_owner,tp_trustee]` |

### Finding Avatar UUIDs

To add UUIDs to the settings notecard:

**Method 1: In-World Script**
```lsl
// Touch this prim to get your UUID
default {
    touch_start(integer num) {
        llSay(0, "UUID: " + (string)llDetectedKey(0));
    }
}
```

**Method 2: Viewer Profile**
- Right-click avatar
- Select "Copy Key" (if available in your viewer)

**Method 3: Online Tools**
- Use a web-based UUID lookup service
- Search by avatar name

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
4. Try long-touch for SOS menu

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
1. Check if TPE mode is enabled (you'll have ACL 0)
2. Use SOS menu (long-touch) to check status
3. If TPE enabled, contact owner to disable
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
   - Collar version (shown in Status menu)
4. **Community Support:** Contact the collar creator or community

---

## FAQ

### General Questions

**Q: Do I need RLV to use the collar?**
A: No. Basic features (owner management, leash, animations, bell) work without RLV. However, RLV features (relay, restrictions) require an RLV-compatible viewer like Firestorm.

**Q: Can I customize the appearance of the collar?**
A: Yes. The collar is a standard Second Life prim object. You can texture it, resize it, and make it invisible. The scripts work independently of appearance.

**Q: How many plugins can I add?**
A: The collar supports unlimited plugins within Second Life's script limits (typically 64 scripts per object in most regions). Currently there are 13 standard plugins.

**Q: Is this compatible with OpenCollar?**
A: Partially. The leash system supports OpenCollar 8.x holder protocol. However, menus and commands are not compatible. This is a separate, independent collar system.

**Q: Can I copy this collar to give to others?**
A: Check the LICENSE (MIT) and object permissions. Generally yes, but respect creator permissions and attribution.

### Ownership Questions

**Q: Can I have multiple owners?**
A: Yes. Enable `multi_owner_mode=1` in settings. All owners have equal ACL 5 access.

**Q: What happens if my owner disappears/quits SL?**
A: If unowned access is available, you can use the Runaway feature (if enabled). Otherwise, you'll need to reset the collar (which clears ownership) or contact the creator for assistance.

**Q: Can trustees change ownership?**
A: No. Only owners (ACL 5) can modify ownership. Trustees (ACL 3) have elevated control but cannot add/remove owners.

**Q: Can I be my own owner?**
A: Yes. As unowned wearer (ACL 4), set yourself as owner. This gives you full ACL 5 control over your own collar.

### RLV Questions

**Q: What's the difference between ON and HARDCORE relay modes?**
A: Both allow external devices to control the collar. HARDCORE mode typically allows more severe/permanent restrictions. Check specific relay device documentation for details.

**Q: Can I use a safeword with RLV relay?**
A: Yes. The collar implements ORG relay specification which includes safeword support. Configure your safeword in your RLV viewer settings.

**Q: What if I get stuck in restrictions?**
A: Use the SOS menu (long-touch collar) → **Clear RLV** or **Clear Relay**. This always works regardless of restrictions.

**Q: Do RLV exceptions work for everyone?**
A: No. Exceptions only apply to owner and/or trustees as configured. They bypass specific restrictions only for authorized users.

### Leash Questions

**Q: What's the difference between leash modes?**
A:
- **Avatar Mode:** Leash to follow another avatar (most common)
- **Coffle Mode:** Chain collar-to-collar (multiple submissives)
- **Post Mode:** Anchor to fixed object or point

**Q: Can I be leashed if public mode is off?**
A: Only by users with ACL 3+ (trustees and owners). Public mode must be ON for strangers to leash.

**Q: Does leashing require RLV?**
A: No. Basic leashing works without RLV using movement scripts. RLV enhances the experience but isn't required.

**Q: Can I unleash myself?**
A: Yes, via the SOS menu (long-touch) → **Unleash**. This always works as an emergency safety feature.

### Safety Questions

**Q: Can someone lock me in restrictions permanently?**
A: No. The SOS menu (long-touch) is always accessible and provides emergency release options regardless of restrictions or access levels.

**Q: What if I accidentally enable TPE mode?**
A: TPE requires wearer confirmation. If enabled, contact your owner to disable it. The SOS menu remains accessible for emergencies.

**Q: Can the blacklist be used to trap me?**
A: No. The blacklist prevents others from accessing the collar. As the wearer, you always retain your own access level (ACL 2 or 4) and SOS menu access.

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
A: Replace old scripts with new scripts from the latest release. The kernel version compatibility ensures plugins work across versions. Always backup your settings notecard first.

**Q: Why doesn't the collar use llDialog for menus?**
A: The collar uses llDialog extensively. All menus are standard SL dialog boxes. The centralized dialog system (channel 950) ensures efficient dialog management across all plugins.

### Feature Requests

**Q: Can you add [feature]?**
A: The collar is modular and extensible. You can:
1. Request features via GitHub issues
2. Write your own plugin (see agents.md for development guide)
3. Contribute code via pull requests

**Q: I want to customize the menu structure. How?**
A: Modify `kmod_ui.lsl` for main menu structure. Individual plugin menus are in their respective plugin scripts. The modular architecture makes customization straightforward.

---

## Additional Resources

- **Main README:** [README.md](README.md) - Technical overview and architecture
- **Developer Guide:** [agents.md](agents.md) - LSL coding standards and plugin development
- **Security Documentation:** [SECURITY_AUDIT_REPORT.md](SECURITY_AUDIT_REPORT.md)
- **GitHub Repository:** https://github.com/anne-skydancer/ds_collar_modular

---

## Version Information

This user guide corresponds to:
- **Kernel Version:** v3.4
- **Module Versions:** v2.1 - v3.2
- **Plugin Versions:** v2.0+

Check your collar version: Touch collar → **Maintenance** → **View Settings** (look for version information in console output).

---

## Support & Community

For support:
- **GitHub Issues:** Report bugs and request features
- **Documentation:** Check README.md and this user guide
- **Source Code:** Review scripts for detailed behavior

**Remember:** The SOS menu (long-touch) is always available for emergencies. Stay safe and enjoy your collar!

---

*DS Collar Modular - A modern, secure, and extensible D/s collar system for Second Life.*
*Licensed under MIT License - See LICENSE file for details.*
