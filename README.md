# DS Collar Modular

**DS Collar Modular** is a modular, script-driven D/s collar system for Second Life.  
It provides a modern, lightweight, and extensible framework for collars, emphasizing **security, modularity, and performance**.  

This project replaces the old monolithic collars with a clean kernel + plugin architecture, using JSON messaging and strict ABI conventions.

---

## ✨ Features

- **Modular kernel design** — central kernel (v1.0) with swappable modules and plugins.
- **Consolidated ABI** — 5-channel architecture (500/700/800/900/950) using structured JSON messaging.
- **Access Control (ACL)** — unified ACL engine with support for owners, trustees, public access, and blacklist.
- **Plugins** — 13 plugins covering owner management, leash, animations, RLV relay/restrictions, TPE mode, and more.
- **Kernel Modules** — 8 specialized modules for auth, settings, dialogs, leash engine, particles, remote HUD, bootstrap, and UI.
- **RLVa Integration** — comprehensive RLV support including relay, restrictions, exceptions, and Lockmeister protocol.
- **Security-hardened** — v1.0 includes critical security fixes for authorization, ACL validation, and overflow protection.
- **Heartbeat & auto-recover** — kernel monitors plugin health, prunes dead plugins, handles script additions/removals.
- **Centralized dialogs** — single dialog management module eliminates per-plugin listeners.
- **External HUD support** — remote control via separate HUD with ACL enforcement.  

---

## 📂 Project Structure

```
ds_collar_modular/
├── LICENSE
├── README.md
├── agents.md                    # LSL coding requirements & best practices
└── src/stable/
    ├── ds_collar_kernel.lsl                  # Core kernel (v1.0)
    ├── ds_collar_control_hud.lsl             # External HUD controller
    ├── ds_collar_leash_holder.lsl            # Leash holder object
    │
    ├── Kernel Modules (kmod_*)
    │   ├── ds_collar_kmod_auth.lsl           # ACL and policy engine
    │   ├── ds_collar_kmod_bootstrap.lsl      # Startup coordination, RLV detection
    │   ├── ds_collar_kmod_dialogs.lsl        # Centralized dialog management
    │   ├── ds_collar_kmod_leash.lsl          # Leashing engine services
    │   ├── ds_collar_kmod_particles.lsl      # Visual renderer + Lockmeister
    │   ├── ds_collar_kmod_remote.lsl         # External HUD bridge
    │   ├── ds_collar_kmod_settings.lsl       # Persistent key-value store
    │   └── ds_collar_kmod_ui.lsl             # Root touch menu
    │
    └── Plugins (plugin_*)
        ├── ds_collar_plugin_animate.lsl      # Animation menu
        ├── ds_collar_plugin_bell.lsl         # Bell controls
        ├── ds_collar_plugin_blacklist.lsl    # Blacklist management
        ├── ds_collar_plugin_leash.lsl        # Leash UI and config
        ├── ds_collar_plugin_lock.lsl         # Lock/unlock toggle
        ├── ds_collar_plugin_maintenance.lsl  # Maintenance utilities
        ├── ds_collar_plugin_owner.lsl        # Owner/trustee management
        ├── ds_collar_plugin_public.lsl       # Public access toggle
        ├── ds_collar_plugin_rlvexceptions.lsl # RLV exception management
        ├── ds_collar_plugin_rlvrelay.lsl     # RLV relay modes
        ├── ds_collar_plugin_rlvrestrict.lsl  # RLV restriction management
        ├── ds_collar_plugin_status.lsl       # Status information display
        └── ds_collar_plugin_tpe.lsl          # Total Power Exchange mode
```

- **Kernel** — manages plugin registry, lifecycle, heartbeats, and consolidated ABI (v1.0).
- **Modules** — headless system components providing core services (auth, settings, dialogs, leash engine, particles, remote communication, UI).
- **Plugins** — user-facing features that register with the kernel and provide menu-driven functionality.  

---

## 🏗️ Architecture & ABI

### Consolidated ABI v1.0

The system uses a **5-channel architecture** for all inter-script communication:

| Channel | Name | Purpose |
|---------|------|---------|
| **500** | `KERNEL_LIFECYCLE` | Plugin registration, heartbeat (ping/pong), soft resets |
| **700** | `AUTH_BUS` | ACL queries and results |
| **800** | `SETTINGS_BUS` | Settings sync, delta updates, notecard loading |
| **900** | `UI_BUS` | UI navigation (start, return, close) |
| **950** | `DIALOG_BUS` | Centralized dialog management |

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

### Security Features (v1.0)

- **Authorization validation** for soft resets (only bootstrap/maintenance can trigger)
- **Integer overflow protection** for Unix timestamps (Year 2038 handling)
- **JSON injection prevention** using proper encoding
- **ACL re-validation** with time-based session checks
- **Rate limiting** on remote HUD requests
- **Touch range validation** (rejects ZERO_VECTOR)
- **Owner change detection** with automatic script reset

---

## 🚀 Installation & Setup

1. Rez a prim in Second Life.
2. Drop `ds_collar_kernel.lsl` and all **8 kernel modules** (`ds_collar_kmod_*.lsl`) into it.
3. Add the **plugins** you want to use (all 13 recommended for full functionality).
4. (Optional) Add a "settings" notecard for pre-configured owners/trustees.
5. Wear the prim as a collar.
6. On reset, the collar will:
   - Bootstrap and detect RLV capability
   - Load settings from notecard (if present)
   - Register all plugins with the kernel
   - Open the UI menu on touch

**Note:** All scripts are in `src/stable/` directory. The HUD and leash holder are separate objects.  

---

## 🔧 Contributing

1. Fork the repo.  
2. Work from the **authoritative baselines** (kernel, modules, plugin skeleton).  
3. Ensure your scripts compile in Second Life.  
4. Submit a pull request with a clear description of your changes.  

---

## 📜 License

MIT License – see [LICENSE](./LICENSE) for details.
