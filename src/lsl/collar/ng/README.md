# DS Collar NG (Next Generation)

**DS Collar NG** is the next-generation branch of the DS Collar Modular system for Second Life.  
It introduces the **LSD (Linkset Data) policy architecture** for declarative, per-plugin button visibility, replacing the former ACL registration model.

This branch builds on the stable v1.0 kernel + plugin architecture, adding a policy layer that lets each plugin self-declare which buttons are visible at each ACL level.

---

## What's New in v1.1

- **LSD Policy Architecture** — Each plugin writes a `policy:<context>` key to linkset data on registration, mapping ACL levels to CSV lists of visible buttons. `kmod_ui` reads these policies to filter menus per-user. This replaces the old `min_acl` registration field and the dead plugin ACL registry.
- **Simplified Registration** — Plugins register with 3 fields: `context`, `label`, `script`. No `min_acl` needed.
- **Cleaner ACL Responses** — `kmod_auth` responses contain only essential fields: `type`, `avatar`, `level`, `is_wearer`, `is_blacklisted`, `owner_set`. Dead `policy_*` fields removed.
- **Registry Stride 5** — Kernel registry entries: `[context, label, script, script_uuid, last_seen_unix]`.

---

## Features

- **Modular kernel design** — central kernel (v1.1) with swappable modules and plugins.
- **Consolidated ABI** — 5-channel architecture (500/700/800/900/950) using structured JSON messaging.
- **LSD Policy Model** — plugins self-declare button visibility per ACL level via linkset data.
- **Access Control (ACL)** — unified ACL engine with support for owners, trustees, public access, and blacklist.
- **14 Plugins** — covering access management, leash, animations, RLV relay/restrictions/exceptions, bell, lock, public toggle, TPE mode, blacklist, status, maintenance, and SOS.
- **9 Kernel Modules** — auth, settings, dialogs, leash engine, particles, remote HUD, bootstrap, menu rendering, and UI/session management.
- **RLVa Integration** — comprehensive RLV support including relay, restrictions, exceptions, and Lockmeister protocol.
- **Security-hardened** — authorization validation, ACL re-validation, overflow protection, rate limiting.
- **Heartbeat & auto-recover** — kernel monitors plugin health, prunes dead plugins, handles script additions/removals.
- **Centralized dialogs** — single dialog management module eliminates per-plugin listeners.
- **External HUD support** — remote control via separate HUD with ACL enforcement.

---

## Project Structure

```
src/lsl/collar/ng/v1.1/
├── collar_kernel.lsl              # Core kernel (v1.1)
├── control_hud.lsl                # External HUD controller
├── leash_holder.lsl               # Leash holder object
│
├── Kernel Modules (kmod_*)
│   ├── kmod_auth.lsl              # ACL and policy engine
│   ├── kmod_bootstrap.lsl         # Startup coordination, RLV detection
│   ├── kmod_dialogs.lsl           # Centralized dialog management
│   ├── kmod_leash.lsl             # Leashing engine services
│   ├── kmod_menu.lsl              # Menu rendering service
│   ├── kmod_particles.lsl         # Visual renderer + Lockmeister
│   ├── kmod_remote.lsl            # External HUD bridge
│   ├── kmod_settings.lsl          # Persistent key-value store
│   └── kmod_ui.lsl                # UI session management + touch handler
│
└── Plugins (plugin_*)
    ├── plugin_access.lsl          # Owner/trustee management
    ├── plugin_animate.lsl         # Animation menu
    ├── plugin_bell.lsl            # Bell controls
    ├── plugin_blacklist.lsl       # Blacklist management
    ├── plugin_leash.lsl           # Leash UI and config
    ├── plugin_lock.lsl            # Lock/unlock toggle
    ├── plugin_maint.lsl           # Maintenance utilities
    ├── plugin_public.lsl          # Public access toggle
    ├── plugin_relay.lsl           # RLV relay modes
    ├── plugin_restrict.lsl        # RLV restriction management
    ├── plugin_rlvex.lsl           # RLV exception management
    ├── plugin_sos.lsl             # Emergency SOS menu
    ├── plugin_status.lsl          # Status information display
    └── plugin_tpe.lsl             # Total Power Exchange mode
```

- **Kernel** — manages plugin registry, lifecycle, heartbeats, and consolidated ABI.
- **Modules** — headless system components providing core services.
- **Plugins** — user-facing features that register with the kernel, declare LSD policies, and provide menu-driven functionality.

---

## Architecture & ABI

### Consolidated ABI v1.1

The system uses a **5-channel architecture** for all inter-script communication:

| Channel | Name | Purpose |
|---------|------|---------|
| **500** | `KERNEL_LIFECYCLE` | Plugin registration, heartbeat (ping/pong), soft resets |
| **700** | `AUTH_BUS` | ACL queries and results |
| **800** | `SETTINGS_BUS` | Settings sync, delta updates, notecard loading |
| **900** | `UI_BUS` | UI navigation (start, return, close) |
| **950** | `DIALOG_BUS` | Centralized dialog management |

### LSD Policy Architecture

Each plugin declares its button visibility in linkset data on registration:

```lsl
llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
    "3", "Clip,Unclip,Settings",    // Trustee sees these buttons
    "4", "Clip,Unclip,Settings",    // Unowned wearer
    "5", "Clip,Unclip,Pass,Settings" // Owner sees all buttons
]));
```

`kmod_ui` reads these policies to filter which buttons each user sees, decluttering the interface based on ACL level.

### ACL Levels

| Level | Name | Description |
|-------|------|-------------|
| **-1** | Blacklisted | Explicitly denied access |
| **0** | No Access | Default for unknown users, wearer in TPE mode |
| **1** | Public | Any user (when public mode enabled) |
| **2** | Owned | Wearer (when owner is set) |
| **3** | Trustee | Trusted users with elevated permissions |
| **4** | Unowned | Wearer (when no owner is set) |
| **5** | Primary Owner | Full administrative control |

### Plugin Registration (v1.1)

Plugins register with 3 fields (no `min_acl`):

```json
{
    "type": "register",
    "context": "plugin_leash",
    "label": "Leash",
    "script": "plugin_leash"
}
```

The kernel maintains a 5-stride registry: `[context, label, script, script_uuid, last_seen_unix]`.

---

## Installation & Setup

1. Rez a prim in Second Life.
2. Drop `collar_kernel.lsl` and all **9 kernel modules** (`kmod_*.lsl`) into it.
3. Add the **plugins** you want (all 14 recommended for full functionality).
4. (Optional) Add a `settings` notecard for pre-configured owners/trustees.
5. Wear the prim as a collar.
6. On reset, the collar will:
   - Bootstrap and detect RLV capability
   - Load settings from notecard (if present)
   - Register all plugins with the kernel (each writes its LSD policy)
   - Open the UI menu on touch

**Note:** All scripts are in `src/lsl/collar/ng/v1.1/`. The HUD and leash holder are separate objects.

---

## Documentation

- **[CLAUDE.md](../../../../CLAUDE.md)** — LSL coding requirements & best practices
- **[SETTINGS_REFERENCE.md](./SETTINGS_REFERENCE.md)** — Settings card reference
- **[USER_GUIDE.md](./USER_GUIDE.md)** — End-user guide
- **[TODO.md](./TODO.md)** — Major outstanding work items
- **[ANALYSIS_OVERVIEW.md](./ANALYSIS_OVERVIEW.md)** — LSL best practices analysis

---

## License

GPL v3 License — see [LICENSE](../../../../LICENSE) for details.
