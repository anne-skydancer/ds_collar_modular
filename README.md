# DS Collar Modular

**DS Collar Modular** is a modular, script-driven D/s collar system for Second Life.  
It provides a modern, lightweight, and extensible framework for collars, emphasizing **security, modularity, and performance**.  

This project replaces the old monolithic collars with a clean kernel + plugin architecture, using JSON messaging and strict ABI conventions.

---

## ✨ Features

- **Modular kernel design** — central kernel with swappable modules.  
- **Plugins** — each feature (owner control, leash, animations, blacklist, public access, trustees, etc.) lives in its own script.  
- **JSON ABI** — all link messages use structured JSON; future-proof and explicit.  
- **Access Control (ACL)** — unified ACL resolution with support for owners, trustees, public access, and blacklist.  
- **RLVa Integration** — optional plugins add RLVa restrictions and relay support.  
- **UI Frontend / Backend split** — responsive dialogs with ACL-filtered menus.  
- **Heartbeat & auto-recover** — kernel pings all plugins, re-registers on silence.  
- **Safe listeners** — one listener per user session, never leaking channels.  

---

## 📂 Project Structure

```
ds_collar_modular/
├── ds_collar_kernel.lsl         # Core kernel
├── ds_collar_api.lsl            # Public API (ABI v1)
├── modules/
│   ├── ds_collar_kmod_acl.lsl
│   ├── ds_collar_kmod_auth.lsl
│   ├── ds_collar_kmod_settings.lsl
│   ├── ds_collar_kmod_bootstrap.lsl
│   ├── ds_collar_kmod_ui_frontend.lsl
│   └── ds_collar_kmod_ui_backend.lsl
└── plugins/
    ├── ds_collar_plugin_owner.lsl
    ├── ds_collar_plugin_leash.lsl
    ├── ds_collar_plugin_blacklist.lsl
    ├── ds_collar_plugin_public.lsl
    ├── ds_collar_plugin_trustees.lsl
    ├── ds_collar_plugin_animate.lsl
    └── ...
```

- **Kernel** — manages plugin registry, heartbeats, and global ABI.  
- **Modules** — headless components (settings, ACL, auth, UI).  
- **Plugins** — user-facing features that register with the kernel.  

---

## 🚀 Installation & Setup

1. Rez a prim in Second Life.  
2. Drop `ds_collar_kernel.lsl` and all **modules** into it.  
3. Add the **plugins** you want to use.  
4. Wear the prim as a collar.  
5. On reset, the collar will bootstrap itself, register all plugins, and open the UI.  

---

## 🔧 Contributing

1. Fork the repo.  
2. Work from the **authoritative baselines** (kernel, modules, plugin skeleton).  
3. Ensure your scripts compile in Second Life.  
4. Submit a pull request with a clear description of your changes.  

---

## 📜 License

MIT License – see [LICENSE](./LICENSE) for details.
