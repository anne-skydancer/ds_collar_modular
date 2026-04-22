# D/s Collar — User Guide

A D/s collar system for Second Life: lightweight, modular, and RLV-aware. This guide is written for wearers, owners, and everyone in between. It covers what each menu does, how access works, and how to stay in control.

---

## Contents

1. [What it is](#what-it-is)
2. [Quick start](#quick-start)
3. [Access & roles](#access--roles)
4. [Using the collar](#using-the-collar)
5. [The main menu](#the-main-menu)
6. [Ownership & trustees](#ownership--trustees)
7. [Blacklist](#blacklist)
8. [Leash](#leash)
9. [RLV](#rlv)
10. [Animations](#animations)
11. [Bell](#bell)
12. [Lock](#lock)
13. [Public access](#public-access)
14. [TPE mode](#tpe-mode)
15. [SOS — emergency](#sos--emergency)
16. [Control HUD](#control-hud)
17. [Maintenance](#maintenance)
18. [Settings notecard](#settings-notecard)
19. [Chat commands](#chat-commands)
20. [Troubleshooting](#troubleshooting)
21. [FAQ](#faq)
22. [Version & support](#version--support)

---

## What it is

D/s Collar Modular is a collar system built around a small kernel and a set of plugins. Each feature — leash, bell, RLV relay, TPE mode, and so on — is its own plugin, so a collar can ship lean or fully loaded.

Core capabilities:

- Single-owner or multi-owner ownership, with trustees
- Multi-mode leash (avatar, collar-to-collar, fixed post)
- Built-in RLV relay so furniture can restrict the wearer
- Direct RLV restrictions, exceptions, and shared-folder control
- Animation menu driven by the collar's inventory
- Bell with show/hide, volume, and sound toggles
- Lock, public access, and Total Power Exchange (TPE) modes
- SOS long-touch escape for wearers locked out in TPE
- Optional HUD for controlling a collar remotely
- Persistent settings, optionally pre-configured via notecard

---

## Quick start

### Wearer

1. Wear the collar.
2. Touch it to open the main menu. What you see depends on whether you have an owner.
3. If you have no owner, you have full access to everything.
4. If you have an owner, many management buttons are hidden and the leash menu is limited to offering the leash.
5. **The RLV relay defaults to ASK.** The first time a scripted object tries to restrict you, you will be asked to Allow or Deny. Change this in **RLV Relay → Mode** if you want.

### Owner

1. Touch the wearer's collar.
2. Go to **Access** to claim ownership (if unclaimed) or manage trustees.
3. Explore **Leash**, **Restrict**, **RLV Relay**, **Exceptions**, **Animate**, and the mode toggles (Locked, Public, TPE).
4. Collar settings can also be pre-loaded from a notecard — see [Settings notecard](#settings-notecard).

---

## Access & roles

The collar decides what you can do based on your relationship to the wearer. Every action is gated by an **access level**:

| Level | Role | Shorthand |
| --- | --- | --- |
| -1 | Blacklisted | Blocked from all interaction |
| 0 | TPE wearer | Wearer in TPE mode — normal menu hidden, long-touch opens SOS |
| 1 | Public | Any nearby avatar, only when Public is enabled |
| 2 | Owned wearer | The wearer, when an owner is set |
| 3 | Trustee | User appointed by an owner |
| 4 | Unowned wearer | The wearer, when no owner is set |
| 5 | Primary owner | A current owner |

Roles in plain terms:

- **Owner** — full control. Sets restrictions, manages leash, configures the collar, appoints or removes trustees, releases or transfers ownership.
- **Trustee** — elevated helper. Can leash, restrict, animate, and add or remove other trustees, but cannot change ownership.
- **Owned wearer** — can view status, use animations, toggle personal-scoped settings; most control is in the owner's hands.
- **Unowned wearer** — full self-control until someone is added as an owner.
- **Public** — sees a minimal menu (typically status, basic leash, force sit/unsit) only when Public mode is on.
- **Blacklisted** — locked out entirely. Cannot open the menu.

---

## Using the collar

**Short touch** — opens the main menu. Buttons you don't have access to simply won't appear.

**Long touch (≥ 1.5 seconds, wearer only)** — opens the **SOS** session. This is meaningful only for a wearer in TPE mode; for a wearer with normal access it just loads the regular root menu. Non-wearers get a notice and the root menu.

**Menu navigation** — `Back` returns to the previous menu, `<<` and `>>` page through lists, and menus time out automatically after 60 seconds.

---

## The main menu

Plugins sort alphabetically. A fully loaded collar shows:

| Button | Plugin |
| --- | --- |
| Access | Owner and trustee management |
| Animate | Animation library |
| Bell | Bell visibility, sound, volume |
| Blacklist | Block users from interacting |
| Exceptions | RLV carve-outs for owner/trustees |
| Folders | RLV shared-folder control |
| Leash | Leashing and follow |
| Locked: Y/N | Lock toggle (shows current state) |
| Maintenance | Settings, reset, manual, HUD |
| Public: Y/N | Public-access toggle |
| Restrict | Apply RLV restrictions |
| RLV Relay | Relay mode and active bindings |
| Status | Read-only summary |
| TPE: Y/N | Total Power Exchange toggle |

**SOS** is not in the main menu — it opens from a wearer long-touch.

Collars with fewer plugins installed simply show fewer buttons.

---

## Ownership & trustees

### Claiming ownership (unowned wearer)

1. **Access → Add Owner** on the wearer's collar.
2. A sensor lists nearby avatars. Pick one.
3. That avatar receives a dialog, accepts, and chooses an honorific.
4. The wearer then receives a final confirmation and confirms.
5. Ownership is set.

Once a primary owner exists, the wearer can no longer add one themselves.

### Releasing ownership

**Owner-initiated:** **Access → Release**. Both owner and wearer confirm via dialog.

**Wearer self-release (Runaway):** a separate path, only in single-owner mode.

- The owner enables or disables it at **Access → Runaway: On/Off**.
- Enabling is the owner's decision alone; disabling requires the wearer's consent (the wearer gets the dialog).
- When enabled, **Access → Runaway** appears on the wearer's menu. Confirming it performs a **factory reset** of the collar — ownership, trustees, and all persisted settings are cleared.

### Transferring ownership

**Access → Transfer** (single-owner mode only). Sensor pick, target accepts and chooses an honorific, the previous owner is notified.

### Trustees

**Access → Add Trustee** — sensor pick → target accepts → picks honorific.
**Access → Rem Trustee** — pick from the current list; removal is immediate, no confirmation.

Both owners and trustees can add or remove trustees.

### Multi-owner mode

Multi-owner mode can only be enabled via the settings notecard (`access.multiowner=1`). The owner list, names, and honorifics are kept as parallel CSVs in the notecard; the in-world Access menu hides owner-editing buttons while this mode is on. Trustees are still managed through the menu as normal, and all owners have equal standing.

---

## Blacklist

Blacklisted users (level -1) cannot interact with the collar at all.

- **Blacklist → +Blacklist** — sensor pick. Block is immediate.
- **Blacklist → -Blacklist** — pick from the numbered list. Unblock is immediate.

The Blacklist menu also shows the current count.

---

## Leash

Three leashing modes and a small set of movement helpers. Basic leashing works without RLV; with RLV, the experience is smoother.

### Modes

**Avatar** — leash the wearer to another avatar. Default mode.
**Coffle** — collar-to-collar. Both avatars must wear a D/s Collar Modular. Used to train submissives together.
**Post** — anchor the wearer to a fixed object.

### Menu actions

Visibility depends on access level; a wearer sees different buttons than a passing stranger.

| Button | What it does |
| --- | --- |
| Clip | Take the leash yourself |
| Offer | Owned wearer offers the leash to a nearby avatar |
| Pass | Hand the current leash to another avatar |
| Take | Take the leash from the current holder |
| Yank | Pull the wearer toward the holder (5-second cooldown) |
| Coffle | Leash this collar to another collar |
| Post | Leash to a fixed object |
| Unclip | Release the leash |
| Get Holder | Rez a leash-holder object on the ground |
| Settings | Length and turn-to-face toggles |

### Length and turn-to-face

**Leash → Settings → Length** — presets at 1, 3, 5, 10, 15, 20 m, plus `<<` / `>>` for 1-m fine-tuning. Length is clamped to 1–20 m.
**Leash → Settings → Turn: On/Off** — when on, the wearer rotates to face the holder.

### Who can leash

| Action | Public | Owned wearer | Trustee | Unowned wearer | Owner |
| --- | --- | --- | --- | --- | --- |
| Clip (as holder) | ✓ | — | ✓ | ✓ | ✓ |
| Offer (from wearer) | — | ✓ | — | — | — |
| Unclip | holder only | — | ✓ | ✓ | ✓ |
| Coffle | — | — | ✓ | ✓ | ✓ |
| Post | ✓ | — | ✓ | ✓ | ✓ |
| Pass / Yank / Take | — | — | ✓ | wearer: ✓ ✓ — | ✓ |

An owned wearer can force-release the leash regardless of holder via **Maintenance → Clear Leash**. A TPE wearer uses **SOS → Unleash**.

### Protocol compatibility

The leash speaks the native D/s Collar handshake and also falls back to the OpenCollar 8.x holder protocol. Lockmeister chain particles are supported in both cases.

---

## RLV

RLV features require an RLV-capable viewer (Firestorm and most modern third-party viewers support it). The collar probes at startup and will report if RLV is unavailable.

### Relay

The relay lets external scripted objects — cages, furniture, traps — restrict the wearer. The collar translates their commands into RLV and enforces them.

**Modes** (**RLV Relay → Mode**):

- **OFF** — the relay ignores all external objects.
- **ASK** (default) — restrictions from a new object apply immediately, but the wearer is prompted to **Allow** (keep) or **Deny** (release). Timeout after 30 seconds counts as Deny. Objects already accepted this session are not re-prompted. The immediate apply is deliberate: it prevents the object's capture sequence from timing out while the wearer reads the prompt. Denying sends `@clear` and releases the object.
- **ON** — restrictions apply automatically. The wearer can still safeword out unless Hardcore is on.

**Hardcore** — trustees and primary owners see **HC ON** / **HC OFF** when the mode is ON. Hardcore removes the wearer's Safeword button; only an owner or trustee can release the wearer.

**Other Relay menu buttons:**
- **Bound by…** — lists objects currently restricting the wearer.
- **Safeword** — emergency clear. Drops all relay restrictions and releases every bound object. Hidden while Hardcore is active (wearer level) but always available to owners and trustees as **Unbind**.
- **Unbind** — owner/trustee emergency clear; identical effect to Safeword but always available regardless of Hardcore.

The relay mode persists across detach and relog. Active restrictions do **not** persist — on re-attach the collar starts clean and re-handshakes with nearby objects.

### Restrictions

Direct RLV restrictions are in **Restrict**, grouped into four categories plus two force actions. Active restrictions are shown with a checkmark; click an active entry to remove it.

| Category | Buttons |
| --- | --- |
| **Inventory** | Det. All · + Outfit · - Outfit · - Attach · + Attach · Att. All · Inv · Notes · Scripts |
| **Speech** | Chat · Recv IM · Send IM · Start IM · Shout · Whisper |
| **Travel** | Map TP · Loc. TP · TP |
| **Other** | Edit · Rez · Touch · Touch Wld · OK TP · Names · Sit · Unsit · Stand |
| **Force Sit** | Sit the wearer on a nearby object (sensor-picked) |
| **Force Unsit** | Stand the wearer up |

Trustees, the unowned wearer, and the primary owner get the full set plus **Clear all**. Owned wearers and public users see only Force Sit and Force Unsit.

An owned wearer who wants every direct restriction lifted needs the owner or a trustee to click **Clear all** — or, in an emergency, **Maintenance → Clear Leash** / **SOS → Clear RLV**.

### Exceptions

**Exceptions** carves out four independent bypasses so you can stay reachable even under heavy restriction:

- Owner IM exception — owner can IM you even when IMs are blocked
- Owner TP exception — owner can TP you even when TPs are blocked
- Trustee IM exception
- Trustee TP exception

Open **Exceptions → Owner** or **→ Trustee**, pick **IM** or **TP**, and toggle Allow/Deny. Defaults: owner IM and TP are allowed, trustee IM and TP are denied.

### Shared folders

**Folders** lists the wearer's `#RLV` subfolders (queried live from the viewer). Each entry shows its worn status: ● fully worn, ◑ partial, no prefix for unworn; a `*` marks a locked folder.

Per-folder actions:

- **Attach** — wear the folder.
- **Detach** — remove the folder.
- **Lock** — prevent detachment of items in that folder (`@detachallthis:<name>=n`). Lock state persists.
- **Unlock** — release the lock.

---

## Animations

**Animate** enumerates animations in the collar's inventory and paginates them (8 per page). Click the animation name to play; `[Stop]` stops the current animation; `<<` / `>>` paginate.

Adding animations: edit the collar, drop animation files into its contents. They appear in the menu automatically — no scripting needed.

Access: the wearer can play animations on themselves; owners and trustees can animate the wearer.

---

## Bell

**Bell** controls the collar's bell prim and its jingle sound.

- **Show: Y / N** — toggle the bell prim's visibility.
- **Sound: On / Off** — enable or silence the jingle.
- **Volume +** / **Volume -** — one step per click.

All four preferences persist across sessions. The bell menu is available to trustees, the unowned wearer, and the primary owner.

---

## Lock

**Locked: Y / N** on the main menu toggles the collar lock. When locked, the collar sends `@detach=n` — the wearer cannot remove it from their viewer. Unlocking sends `@detach=y`.

Who can toggle: the unowned wearer and the primary owner.

---

## Public access

**Public: Y / N** on the main menu toggles whether nearby strangers can interact with the collar. When Public is on, any avatar gets access-level 1 — enough to see status, clip/unclip the leash (avatar or post mode), and use Force Sit / Force Unsit. Public users cannot change settings, ownership, trustees, the blacklist, or bell.

Toggle permission: trustees and primary owners.

---

## TPE mode

**Total Power Exchange** gives the owner total control by reducing the wearer to access level 0 (no menu access).

**Enable** (owner only, requires at least one primary owner to exist): the wearer receives a consent dialog and must accept. After acceptance, they lose all regular collar access; the long-touch SOS remains their only menu path.

**Disable** (owner only): no wearer dialog — the owner's decision restores the wearer's normal access.

TPE is a serious step. Only engage it with partners you trust, and understand that the wearer's only escape hatches while TPE is active are the SOS long-touch menu and the safeword if the relay permits it.

---

## SOS — emergency

Long-touch the collar for **1.5+ seconds** to open SOS. This is wearer-only; other avatars see the regular menu. The SOS menu only *populates* for a TPE wearer (level 0); a wearer with normal access will see nothing useful there, because every SOS action is also available in the normal menu.

**SOS actions:**

- **Unleash** — release any active leash, no confirmation.
- **Clear RLV** — drop every direct RLV restriction the collar has applied.
- **Clear Relay** — safeword. Clear every restriction applied by external relay objects and send release notifications to them. This bypasses Hardcore, by design.

Use SOS when: you are stuck, your partner is unavailable, you are being griefed, a scene has gone wrong, or the main menu isn't responding.

---

## Control HUD

The Control HUD lets an owner or trustee drive a collar from a HUD instead of touching it directly. Rez the HUD object, drop `control_hud.lsl` into it, and wear it.

**Finding a collar** — the HUD broadcasts on a dedicated channel; any D/s Collar in the region answers. If exactly one collar responds, the HUD auto-connects; otherwise it shows a selection menu.

**Access** — the HUD honours the same access rules as a direct touch. An owner driving the HUD sees owner menus; a trustee sees trustee menus; and so on.

**Range** — region-wide. Messages travel across the whole sim, not just the immediate vicinity.

---

## Maintenance

**Maintenance** collects utilities that don't belong to any feature plugin.

| Button | Action | Who sees it |
| --- | --- | --- |
| View Settings | Print current settings to local chat | Wearer / trustee / owner |
| Reload Settings | Re-read the settings notecard | Wearer / trustee / owner |
| Access List | Show current owners and trustees | Wearer / trustee / owner |
| Reload Collar | Soft-reset all scripts | Wearer / trustee / owner |
| Clear Leash | Force-release the leash regardless of holder | Wearer / trustee / owner |
| Get HUD | Hand the control HUD to the toucher | Everyone |
| User Manual | Hand a copy of this guide to the toucher | Everyone |
| Factory Reset | Wipe all settings, owners, trustees, and blacklist | Wearer only |

Factory Reset is deliberately wearer-only so an owner cannot erase themselves from the collar.

---

## Settings notecard

A notecard named **settings** in the collar's inventory seeds the collar at startup or after a script reset.

### Format

One `key = value` pair per line; lines starting with `#` are comments. Keys use dotted namespaces (`access.owner`, `bell.volume`, and so on). CSVs are plain comma-separated values — no JSON objects.

```
# Example
access.multiowner     = 0
access.owner          = a1b2c3d4-e5f6-7890-abcd-ef1234567890
access.ownerhonorific = Master

access.trusteeuuids       = uuid-1,uuid-2
access.trusteehonorifics  = Mistress,Daddy

blacklist.blklistuuid = uuid-3

public.mode = 0
lock.locked = 0
tpe.mode    = 0

bell.visible     = 1
bell.enablesound = 1
bell.volume      = 0.3
bell.sound       = 16fcf579-82cb-b110-c1a4-5fa5e1385406
```

### Keys at a glance

| Key | Type | Meaning |
| --- | --- | --- |
| `access.multiowner` | 0/1 | Multi-owner mode (**notecard only**) |
| `access.owner` | UUID | Single-owner UUID |
| `access.ownerhonorific` | string | Single-owner honorific |
| `access.owneruuids` | CSV UUIDs | Multi-owner list (**notecard only**) |
| `access.ownerhonorifics` | CSV strings | Multi-owner honorifics, parallel order |
| `access.trusteeuuids` | CSV UUIDs | Trustees |
| `access.trusteehonorifics` | CSV strings | Trustee honorifics, parallel order |
| `access.enablerunaway` | 0/1 | Allow wearer self-release |
| `blacklist.blklistuuid` | CSV UUIDs | Blocked users |
| `public.mode` | 0/1 | Public access |
| `lock.locked` | 0/1 | Lock state |
| `tpe.mode` | 0/1 | TPE mode — refuses to enable if no external owner is set |
| `bell.visible` | 0/1 | Bell prim visibility |
| `bell.enablesound` | 0/1 | Bell sound |
| `bell.volume` | 0.0–1.0 | Bell volume |
| `bell.sound` | UUID | Bell sound asset |
| `rlvex.ownertp` / `ownerim` | 0/1 | Owner RLV exceptions |
| `rlvex.trusteetp` / `trusteeim` | 0/1 | Trustee RLV exceptions |
| `chat.prefix` | string | Chat command prefix. Defaults to the first two characters of the wearer's username. |
| `chat.public` | 0/1 | Whether the collar also listens on channel 0 (local chat) |
| `chat.channel` | 1–9 | Secondary private channel (values outside 1–9 are ignored) |

For full syntax see `SETTINGS_REFERENCE.md`.

### Reload behaviour

The notecard is read:

- on script reset (manual, `Reload Collar`, factory reset, or owner change),
- when the notecard itself is replaced in inventory.

It is **not** re-read on an ordinary detach/re-attach or relog — runtime menu changes survive those. But **when the notecard is read, it overwrites LSD values for every key it contains**. If you want the notecard to carry specific defaults indefinitely, leave them in; if you want runtime changes to stick across resets, remove or comment out the matching keys.

The relay mode, active RLV restrictions, and leash length/turn-to-face are **not** notecard-configurable — set those from the menus.

### Finding UUIDs

Right-click an avatar and choose **Copy Key** (available in Firestorm and most third-party viewers).

---

## Chat commands

Most features also work from chat. The collar listens on two channels:

- **Channel 0** — ordinary local chat. Commands typed straight into the speak bar are heard by everyone nearby. On by default; can be turned off for privacy (`chat.public = 0` or the toggle in the **Chat** menu).
- A **private channel** (default `1`) — always on. Type `/1 <prefix> <command>` to issue commands no one else sees.

Either way, every command starts with the collar's **prefix**, which defaults to the first two characters of the wearer's username.

Prefix, private channel number, and channel-0 listening are all configurable — through the **Chat** menu at runtime, or pre-set in the settings notecard with `chat.prefix`, `chat.channel`, and `chat.public`.

### Form

```
<prefix> <verb> [argument]
```

Examples (prefix `an`):

```
an status
an pose nadu
an leash clip
an lock locked
an safeword
```

Commands are case-insensitive. If you can use the feature in the menu, you can use it in chat.

### Reference

**Animate**
| Command | Action |
| --- | --- |
| `animate` | Open the Animate menu |
| `pose <name>` | Play a named animation |
| `pose stop` / `stand` | Stop the current animation |

**Leash**
| Command | Action |
| --- | --- |
| `leash` | Open the Leash menu |
| `leash clip` / `leash unclip` | Hold or release the leash |
| `leash turn` | Toggle turn-to-face |
| `leash length <m>` | Set leash length in metres |
| `leash pass <username>` | Pass the leash (SL username, in-sim target) |
| `leash coffle` / `leash post` | Open the respective mode flow |

**Lock**
| Command | Action |
| --- | --- |
| `lock` | Toggle |
| `lock locked` / `lock unlocked` | Set idempotently |

**Public access**
| Command | Action |
| --- | --- |
| `public` | Toggle |
| `public on` / `public off` | Set idempotently |

**Bell**
| Command | Action |
| --- | --- |
| `bell` | Open the menu |
| `bell show` / `bell hide` | Toggle visibility |
| `bell sound` / `bell silent` | Toggle sound |
| `bell vol.up` / `bell vol.dn` | Adjust volume |
| `bell jingle` | Play one jingle |

**Status**
| Command | Action |
| --- | --- |
| `status` | Show the status dialog |

**RLV Relay**
| Command | Action |
| --- | --- |
| `relay` | Open the Relay menu |
| `relay on` / `relay off` / `relay ask` | Set mode |
| `safeword` | Emergency relay clear (bypasses Hardcore). Standalone — no prefix needed on the verb. |

**RLV Restrictions**
| Command | Action |
| --- | --- |
| `restrict` | Open the menu |
| `restrict clear` | Clear all restrictions |

**Folders**
| Command | Action |
| --- | --- |
| `folders` | Open the menu |
| `folders attach/detach/lock/unlock <name>` | Per-folder actions |

Folder names that contain a dot must be used from the menu — the dot collides with chat subcommand parsing.

**Access**
| Command | Action |
| --- | --- |
| `access` | Open the menu |
| `access add owner` / `access rem owner` | Start the respective flow (sensor + dialogs) |
| `access add trustee` / `access rem trustee` | Start the respective flow |

**Blacklist**
| Command | Action |
| --- | --- |
| `blacklist` | Open the menu |
| `blacklist add` / `blacklist rem` | Start the sensor or removal flow |

**SOS (wearer-only panic verbs)**
| Command | Action |
| --- | --- |
| `sos` | Open SOS |
| `sosunleash` | Emergency unleash |
| `sosrestrict` | Emergency clear RLV |
| `sosrelay` | Emergency relay safeword |

### Menu-only

Some features have no chat commands on purpose:

- **Chat** settings — mistyping the prefix in chat could lock you out.
- **Maintenance** — destructive actions need menu confirmation.
- **TPE** — wearer consent must be unambiguous.
- **Exceptions** — too many category/target combinations for clean chat syntax.

---

## Troubleshooting

**Touch does nothing.** Edit the collar → Contents → check that the scripts show as Running. If in doubt, right-click → Reset Scripts. If you are in TPE mode, try the long-touch.

**Menu ignores clicks.** Wait for the 60-second timeout, re-open, or reset the collar scripts.

**RLV commands do nothing.** Your viewer may not support RLV, or RLV may be disabled in preferences. Check the viewer settings, relog, and confirm the collar announces RLV as active during startup.

**Leash doesn't follow.** The leash is pull-based, so the holder has to move. Check the length isn't absurd, confirm no conflicting animation is locking position, and try unclip/reclip.

**HUD finds no collars.** The HUD and the collar must be in the same region. If the HUD has been running for a while, reset its script; if the collar never answers, reset the collar scripts too.

**Wearer can't open the menu.** You may be in TPE mode — long-touch to get SOS, then ask the owner to disable TPE. Otherwise, check that you are not blacklisted and that scripts are running.

### Common error notices

- *ACL Denied* — your access level is insufficient for that button.
- *RLV Not Detected* — viewer has RLV disabled or unsupported.
- *Owner Already Set* — you cannot Add Owner while one exists; use Transfer or Release instead.
- *Timeout Waiting for Response* — a cross-script message was dropped; reset the collar.
- *Invalid UUID* — the notecard contains a malformed UUID. Fix the line and reload.

---

## FAQ

### General

**Do I need RLV to use the collar?** No for the basics — owner management, leash, animations, bell all work without it. Yes for the relay, direct restrictions, folders, and exceptions.

**Can I restyle the collar?** Yes. Retexture, resize, and rebuild the prim however you like — the scripts don't touch appearance.

**How many plugins can I use?** As many as Second Life's script limits allow. A full install ships about 16 plugins; a minimal collar runs with two or three.

**Is this OpenCollar-compatible?** Only for the leash holder protocol (OpenCollar 8.x). OpenCollar plugins and add-ons do not work here — this is a separate system.

### Ownership

**Can I have more than one owner?** Yes — set `access.multiowner = 1` in the notecard and list the UUIDs and honorifics. All owners are peers.

**What if my owner disappears?** If the owner enabled Runaway, use **Access → Runaway**. Otherwise, either the owner, a trustee, or a full factory reset (performed by the wearer in Maintenance) breaks the ownership.

**Can a trustee change ownership?** No. Trustees are powerful but never touch the owner list.

**Can I own myself?** You already do, while unowned. You cannot add yourself to the owner list; the collar is designed to require another avatar.

### RLV

**What does ASK mode actually do?** It lets furniture apply restrictions immediately, then asks you to keep or release them within 30 seconds. Allow keeps the restrictions and trusts the object for the rest of the session. Deny (or timeout) sends `@clear` and releases the object. The immediate apply prevents the object from giving up while you read the dialog.

**How do I safeword?** In **RLV Relay → Safeword** (or type `safeword`). It clears every relay restriction and releases every bound object. Unavailable to the wearer while Hardcore is active; always available to owners and trustees as **Unbind**.

**I'm stuck in a trap — what now?** If you are in TPE: long-touch → **Clear RLV** or **Clear Relay**. Otherwise touch the collar → **Restrict → Clear all**, or ask an owner/trustee.

**What exceptions can I set?** Four independent toggles: owner IM, owner TP, trustee IM, trustee TP. Nothing else.

### Leash

**What's the difference between the modes?** Avatar follows a person, Coffle chains two collars, Post anchors to a fixed object.

**Can a stranger leash me?** Only if Public is on. Otherwise, trustees and owners only.

**Does leashing need RLV?** No. It works on standard movement scripting; RLV just makes follow smoother.

**Can I unleash myself?** An unowned wearer can click **Leash → Unclip**. An owned wearer uses **Maintenance → Clear Leash** (this force-releases regardless of holder). A TPE wearer uses **SOS → Unleash**.

### Safety

**Can someone lock me into restrictions I can't escape?** There is always a path out, but it depends on your situation. An owned (non-TPE) wearer needs the owner or a trustee to clear direct restrictions; if communication is also blocked, preconfigured IM exceptions become your lifeline. A TPE wearer uses SOS. Hardcore relay prevents wearer self-release, but owners and trustees can always Unbind.

**What if I regret enabling TPE?** Only the owner can disable it from inside the collar. SOS still works for leash, direct RLV, and the relay, but it does not turn TPE off. If the notecard sets `tpe.mode = 1`, a factory reset or removal of that line is required to keep TPE off across future resets.

**Can the blacklist trap me?** No. It blocks others from using the collar, not you.

**Is my data private?** Everything runs locally in-world. Nothing leaves the collar.

### Technical

**Is the source open?** Yes, MIT licence: https://github.com/anne-skydancer/ds_collar_modular

**How do I update the collar?** Unlock the collar, rez it on the ground, edit → Contents, delete the old scripts, drop in the new ones. Back up your settings notecard first. The kernel keeps older plugins working across revisions.

**Can you add feature X?** The project is modular — open an issue, write a plugin, or submit a PR.

---

## Version & support

- **System version:** 1.1
- **Status:** stable

Revisions are tracked per script in their file headers.

- **Issues and feature requests:** https://github.com/anne-skydancer/ds_collar_modular/issues
- **Source and documentation:** https://github.com/anne-skydancer/ds_collar_modular
- **Related docs:** [README.md](README.md), [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md), [TECHNICAL_REFERENCE.md](TECHNICAL_REFERENCE.md)

Stay safe and enjoy your collar.

---

*D/s Collar Modular — a modular D/s collar system for Second Life. Licensed under MIT.*
