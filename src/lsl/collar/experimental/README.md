# D/s Collar Modular

A modern, modular D/s (Dominant/submissive) collar system for Second Life.

The collar is built around a central kernel with swappable plugins. It supports owner and trustee management, leashing, RLV integration, animations, and more — all controlled through in-world menus.

---

## What's Included

The collar system has three parts:

- **Collar** — the wearable object containing the kernel, modules, and plugins
- **Control HUD** — an optional remote control attachment for owners and trustees
- **Leash Holder** — an optional object that acts as a leash handle

### Collar Scripts

The collar contains a **kernel**, **9 modules**, and up to **14 plugins**.

**Kernel** — `collar_kernel.lsl`
Manages plugin registration, health monitoring, and communication between all scripts.

**Modules** provide behind-the-scenes services:

| Module | Purpose |
|--------|---------|
| `kmod_auth` | Determines who has access and at what level |
| `kmod_bootstrap` | Handles startup, RLV detection, and owner name lookup |
| `kmod_dialogs` | Manages all menu dialog windows |
| `kmod_leash` | Provides the leash movement engine |
| `kmod_menu` | Renders menu buttons and page layouts |
| `kmod_particles` | Draws the visual leash chain effect |
| `kmod_remote` | Bridges communication with the Control HUD |
| `kmod_settings` | Stores and loads all collar settings |
| `kmod_ui` | Decides which menu options each person can see |

**Plugins** are the features you interact with:

| Plugin | What It Does |
|--------|-------------|
| `plugin_access` | Add or remove owners and trustees, manage honorifics |
| `plugin_animate` | Play animations from the collar's inventory |
| `plugin_bell` | Show or hide the bell, toggle its sound and volume |
| `plugin_blacklist` | Block specific people from using the collar |
| `plugin_leash` | Leash controls — clip, unclip, length, and mode |
| `plugin_lock` | Lock or unlock the collar |
| `plugin_maint` | View current settings and system information |
| `plugin_public` | Toggle whether strangers can interact with the collar |
| `plugin_relay` | Built-in RLV relay for furniture and traps |
| `plugin_restrict` | Apply RLV restrictions (block chat, teleport, etc.) |
| `plugin_rlvex` | Set RLV exceptions so owners/trustees can bypass restrictions |
| `plugin_sos` | Emergency menu for TPE wearers via long-touch |
| `plugin_status` | Display collar status information |
| `plugin_tpe` | Total Power Exchange mode (gives full control to owner) |

### Companion Objects

| Script | Purpose |
|--------|---------|
| `control_hud` | Remote control HUD for owners and trustees |
| `leash_holder` | Leash handle that responds to leash requests |

---

## Getting Started

### Setting Up the Collar

1. Rez a prim in Second Life
2. Drop **all** `.lsl` scripts (except `control_hud.lsl` and `leash_holder.lsl`) into it
3. Optionally add a notecard named `settings` to pre-configure owners (see below)
4. Wear the prim as a collar attachment

On startup the collar will detect RLV support, load any settings notecard, and register all plugins automatically.

### Setting Up the Control HUD

1. Rez a separate prim
2. Drop `control_hud.lsl` into it
3. Attach it to your HUD
4. It will automatically detect nearby collars

### Setting Up the Leash Holder

1. Rez a prim
2. Drop `leash_holder.lsl` into it
3. Wear or hold the object — it responds to leash requests from the collar

---

## Using the Collar

**Touch** the collar to open the main menu. You'll see only the options your access level allows.

**Long-touch** (hold for 1.5+ seconds) to access the emergency SOS menu. This is a safety net for the wearer in TPE mode, who has lost normal collar access.

### Who Can Do What

| Role | Access |
|------|--------|
| **Primary Owner** | Full control over all features and settings |
| **Trustee** | Elevated access — can leash, restrict, animate, but cannot change ownership |
| **Wearer (unowned)** | Full self-control until an owner is set |
| **Wearer (owned)** | Personal features only (animations, bell, status) |
| **Public** | Limited features when public mode is enabled |
| **Blacklisted** | No access at all |

### Main Menu

With all plugins installed, the main menu shows (alphabetically):

```
Access         — Manage owners and trustees
Animate        — Play animations
Bell           — Bell visibility and sound
Blacklist      — Block or unblock users
Exceptions     — RLV bypass rules for owners/trustees
Leash          — Leashing controls
Locked: Y/N    — Lock or unlock the collar
Maintenance    — View settings
Public: Y/N    — Toggle public access
Restrict       — Apply RLV restrictions
RLV Relay      — Configure the RLV relay
Status         — View collar information
TPE: Y/N       — Toggle Total Power Exchange
```

The **SOS** menu (wearer long-touch in TPE mode) provides emergency unleash, RLV clear, and relay clear.

---

## Settings Notecard

You can pre-configure the collar by placing a notecard named `settings` in its inventory. The format is `key = value`, one per line. Lines starting with `#` are comments.

### Minimal Example

```
access.owner = {"12345678-1234-1234-1234-123456789abc": "Master"}
lock.locked = 0
```

### Common Settings

| Key | Values | What It Controls |
|-----|--------|-----------------|
| `access.multiowner` | `0` or `1` | Allow multiple owners (notecard only) |
| `access.owner` | `{"uuid": "Honorific"}` | Set the primary owner |
| `access.trustees` | `{"uuid": "Title", ...}` | Set trusted users |
| `access.blacklist` | `[uuid1, uuid2]` | Block specific users |
| `public.mode` | `0` or `1` | Allow public access |
| `tpe.mode` | `0` or `1` | Total Power Exchange |
| `lock.locked` | `0` or `1` | Lock the collar |
| `bell.visible` | `0` or `1` | Show the bell |
| `bell.enablesound` | `0` or `1` | Enable bell sound |
| `bell.volume` | `0.0` to `1.0` | Bell volume |

For the full list of settings keys, notecard syntax rules, and configuration patterns, see [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).

---

## Further Reading

- [USER_GUIDE.md](USER_GUIDE.md) — Detailed walkthrough of every feature
- [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md) — Complete settings key reference and notecard format
- [TECHNICAL_REFERENCE.md](TECHNICAL_REFERENCE.md) — Architecture and internals for developers

---

## License

GPL v3 — see [LICENSE](../../../../LICENSE) for details.
