---
name: LSD-based plugin registration migration
description: Planned retooling of plugin registration from heartbeat/ping-pong to LSD-persistent model for sim restart resilience
type: project
---

Replace the current heartbeat-based plugin registration in the experimental kernel with an LSD-persistent model.

**Why:** The current system has a confirmed vulnerability where sim restarts (ground-rezzed collar) cause all plugins to be pruned due to stale `last_seen` timestamps, with no recovery path. `CHANGED_REGION_START` is not handled, pongs from unknown plugins are silently discarded, and discovery can't detect desync because UUIDs haven't changed. User experienced "No plugins are currently installed" after being offline for a few hours (2026-04-04).

**How to apply:** When implementing, follow the migration plan discussed in conversation:
- Plugins write `reg:<context>` to LSD in `register_self()`, announce via `"registered"` link_message
- Kernel rebuilds from LSD via `rebuild_from_lsd()` using `llLinksetDataFindKeys("^reg:", 0, 50)`
- Single 60s watchdog timer replaces four overlapping mechanisms (batch queue, heartbeat, discovery, inventory sweep)
- Fire-and-forget announcements, kernel-only cleanup, event-driven with lazy watchdog
- ~390 lines removed across 15 files, kernel drops from ~634 to ~350-380 lines
- Normalize plugin_lock's deferred registration pattern
- Files: `src/lsl/collar/experimental/collar_kernel.lsl` + all 14 `plugin_*.lsl`
