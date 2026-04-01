# Integration vs. Separation Deep Dive

**What works best inside one script vs. as separate scripts?**

This analysis maps the DS Collar NG architecture against LSL's concrete runtime
constraints to recommend where consolidation saves resources and where separation
is essential.

---

## LSL Runtime Constraints That Drive the Decision

### Per-Script Costs
- **Memory**: Each Mono script gets its own **64KB** allocation. Scripts only consume
  what they use, but you cannot share memory between scripts.
- **Idle overhead**: Each idle script costs **0.001-0.003ms per frame** to the simulator.
  With 28 scripts in one object, that's 0.028-0.084ms/frame of baseline sim load.
- **Event queue**: Each script has its own **64-event queue**. If a script's queue fills,
  events are **silently dropped** — no error, no retry.
- **Single timer**: Each script gets exactly **one** `llSetTimerEvent()`. You cannot
  multiplex timers within a single script.
- **Single sensor**: Each script gets one `llSensor()`/`llSensorRepeat()` at a time.

### link_message Costs
- **Every** `llMessageLinked(LINK_SET, ...)` is delivered to **every script** in the
  linkset. With 28 scripts, a single `llMessageLinked` generates 28 event deliveries.
- The link_message event fires even if the receiving script immediately returns
  (it still costs queue space and handler execution time).
- **Measured cost**: ~0.3-0.5ms per send, but the **fan-out** is the real expense.

### The Fan-Out Problem in This Codebase

Current message traffic during steady-state operation:

| Event | Frequency | Messages Generated | Scripts Receiving |
|-------|-----------|-------------------|-------------------|
| Kernel ping | Every 5s | 1 `llMessageLinked` | 28 scripts |
| Plugin pong (x15) | Every 5s | 15 `llMessageLinked` | 28 scripts each |
| Plugin list broadcast | On change | 1 `llMessageLinked` | 28 scripts |
| Settings sync | On change | 1 `llMessageLinked` | 28 scripts |
| ACL query + result | Per touch | 2 `llMessageLinked` | 28 scripts each |

**Per heartbeat cycle (5 seconds):**
- 1 ping + 15 pongs = 16 link_messages
- 16 × 28 = **448 event deliveries** every 5 seconds just for heartbeat
- Each delivery triggers a `link_message` handler, parses JSON to check `type`,
  and returns. That's 448 × ~2-3ms of JSON parsing = **~1 second of script time**
  every 5 seconds, just for ping/pong.

This is the single largest performance cost in the architecture.

---

## What Works Best INTEGRATED (Same Script)

### Candidate 1: Merge `kmod_ui.lsl` + `ds_collar_menu.lsl`
**Current:** Two scripts, tightly coupled via link_message on UI_BUS.

| Metric | Separate | Merged |
|--------|----------|--------|
| Scripts | 2 | 1 |
| link_messages for render_menu | 1 per menu display | 0 (direct function call) |
| Combined lines | 899 + 230 = 1129 | ~1050 (remove duplicate helpers) |
| Timer conflict | Neither uses timer | N/A |
| Sensor conflict | Neither uses sensor | N/A |

**Verdict: MERGE.** `ds_collar_menu.lsl` is a pure rendering service with no persistent
state, no timer, no listener, and no sensor. It exists solely to receive `render_menu`
messages from `kmod_ui.lsl` and call `llDialog()`. Merging eliminates:
- 1 script's idle overhead
- 1 link_message per menu display
- 28 wasted event deliveries per menu display
- ~80 bytes of duplicated helper functions

**Risk:** Low. Both scripts are already in the same logical domain. The combined
script stays well under 64KB.

---

### Candidate 2: Merge `plugin_public.lsl` + `plugin_lock.lsl` + `plugin_tpe.lsl`
**Current:** Three separate scripts, all following the identical "direct toggle" pattern.

All three scripts:
- Have **no menu** (direct toggle on button click)
- Have **no timer**
- Have **no listener**
- Have **no sensor**
- Use the identical pattern: register → receive `start` → query ACL → toggle → update label → return
- Each carries ~50 bytes of duplicated `json_has`/lifecycle boilerplate

| Metric | Separate (3 scripts) | Merged (1 script) |
|--------|---------------------|-------------------|
| Scripts | 3 | 1 |
| Heartbeat messages | 3 pongs every 5s | 1 pong every 5s |
| Event deliveries saved | 2 × 28 = 56 per heartbeat | - |
| Combined lines | 305 + 374 + 419 = 1098 | ~700 (shared boilerplate) |
| Memory saved | ~128KB → ~64KB total allocation | 64KB freed |

**How it works merged:**
```
One script registers THREE plugin contexts:
  - "core_public" (min_acl=3, label="Public: Y/N")
  - "core_lock" (min_acl=4, label="Locked: Y/N")
  - "core_tpe" (min_acl=5, label="TPE: Y/N")

On "start" message, check which context was clicked:
  if context == "core_public" → toggle public
  if context == "core_lock" → toggle lock
  if context == "core_tpe" → toggle TPE (with confirmation dialog)

Shared: settings sync/delta, ACL query, json_has, lifecycle
```

**Verdict: MERGE.** These three scripts are structurally identical. The merged
script would be ~700 lines — well within memory limits. The only complication is
TPE's wearer confirmation dialog, but that uses the centralized dialog system
(no local listener needed).

**Risk:** Low. All three share the same communication pattern. The only potential
issue is that TPE needs a `DIALOG_BUS` handler for the confirmation dialog, which
the other two don't — but adding it costs nothing.

---

### Candidate 3: Merge `kmod_leash.lsl` + `kmod_particles.lsl`
**Current:** Two scripts with a tight producer-consumer relationship.

| Metric | Separate | Merged |
|--------|----------|--------|
| Scripts | 2 | 1 |
| link_messages for particles | 3-4 per leash action | 0 (direct function call) |
| Combined lines | 1063 + 503 = 1566 | ~1400 |
| Timer conflict | **Both use timer** | **CONFLICT** |
| Listener conflict | Leash: 2 (holder), Particles: 1 (LM) | 3 total (OK) |

**Verdict: DO NOT MERGE.** Both scripts use the timer for different purposes:
- `kmod_leash.lsl`: Follow tick (0.5s) for leash movement
- `kmod_particles.lsl`: Particle update rate + LM ping interval

LSL only allows **one timer per script**. Merging would require multiplexing
the timer, which adds complexity and reduces timing precision for the follow
mechanic (which is latency-sensitive).

**Additional concern:** Combined script would be ~1400 lines with substantial
state. Memory pressure is already documented (leash plugin had a stack-heap
collision in rev 21). Keeping them separate gives each its own 64KB allocation.

---

## What Works Best SEPARATE (Different Scripts)

### Must Stay Separate: Scripts Using Exclusive Resources

These scripts **must** remain separate because they use resources that conflict:

| Script | Timer | Sensor | Listener | Why Separate |
|--------|-------|--------|----------|-------------|
| `kernel.lsl` | 5s heartbeat / 0.1s batch | No | No | Heartbeat is system-critical |
| `kmod_bootstrap.lsl` | 1s RLV retry | No | RLV channels | Probe lifecycle independent |
| `kmod_leash.lsl` | 0.5s follow | No | Holder channels | Latency-sensitive follow |
| `kmod_particles.lsl` | 8s LM ping | No | LM channel | Independent update cycle |
| `kmod_dialogs.lsl` | 5s session cleanup | No | Dialog channels | Central listener manager |
| `kmod_remote.lsl` | 60s query cleanup | No | External channels | External protocol handler |
| `plugin_bell.lsl` | Jingle interval | No | No | Sound timing independent |
| `plugin_leash.lsl` | State query delay | Coffle/post scan | No | Sensor for object selection |
| `plugin_access.lsl` | No | Avatar scan | No | Sensor for avatar selection |
| `plugin_blacklist.lsl` | No | Avatar scan | No | Sensor for avatar selection |
| `plugin_rlvrelay.lsl` | No | No | Relay channel | ORG spec requires dedicated listen |
| `plugin_chat.lsl` | No | No | Chat channels | Dedicated listen for emotes |

**Key rule:** If two scripts both need a timer OR both need a sensor, they
**cannot** be merged without significant architectural compromise.

### Must Stay Separate: Memory-Heavy Scripts

These scripts are large enough that merging would risk stack-heap collisions:

| Script | Lines | Estimated Memory Use | Risk if Merged |
|--------|-------|---------------------|---------------|
| `kernel.lsl` | 782 | High (registry lists) | System-critical, isolate |
| `kmod_settings.lsl` | 730 | High (full KV store in JSON) | Data store, isolate |
| `kmod_auth.lsl` | 637 | Medium (ACL lists) | Security-critical, isolate |
| `kmod_ui.lsl` | 899 | High (sessions + filtered plugins) | Most complex module |
| `kmod_leash.lsl` | 1063 | High (state machine + protocol) | Already tight on memory |
| `plugin_leash.lsl` | 1066 | High (menus + sensor results) | Already had stack-heap crash |
| `plugin_access.lsl` | 848 | Medium-High (name cache + candidates) | Complex workflows |
| `plugin_rlvrelay.lsl` | 795 | Medium (relay sessions) | Independent protocol |

**Key rule:** If a script is over ~600 lines or manages large dynamic data
structures (lists, JSON), it should stay isolated for memory safety.

### Should Stay Separate: Functionally Independent Plugins

These plugins have **zero coupling** beyond the standard plugin lifecycle
(register/ping/pong/settings). Merging them saves heartbeat messages but
creates a monolith that's harder to maintain:

| Plugin | Unique Resources | Coupling |
|--------|-----------------|----------|
| `plugin_animate.lsl` | Permissions (animations) | Independent |
| `plugin_rlvrestrict.lsl` | RLV commands | Independent |
| `plugin_rlvexceptions.lsl` | RLV exceptions | Pairs with rlvrestrict |
| `plugin_status.lsl` | Display name queries | Read-only display |
| `plugin_maintenance.lsl` | Reset/update logic | System utility |
| `plugin_chat.lsl` | Chat listeners | Independent |
| `plugin_sos.lsl` | Emergency actions | Must be isolated for safety |

**`plugin_sos.lsl` MUST stay separate.** It's the emergency escape hatch. If it
were merged with another script that crashes due to memory, the wearer loses
their SOS capability. Isolation is a safety requirement.

---

### Candidate 4: Merge `plugin_rlvrestrict.lsl` + `plugin_rlvexceptions.lsl`
**Current:** Two scripts managing related RLV functionality.

| Metric | Separate | Merged |
|--------|----------|--------|
| Scripts | 2 | 1 |
| Combined lines | 573 + 576 = 1149 | ~950 (shared boilerplate) |
| Timer conflict | Neither uses timer | N/A |
| Sensor conflict | Neither uses sensor | N/A |
| Listener conflict | Neither uses listener | N/A |

**Verdict: CONSIDER MERGE.** Both manage RLV restrictions via `llOwnerSay("@...")`
commands. Neither uses timers, sensors, or listeners. They share settings patterns
and could share RLV command helpers.

**Risk:** Medium. Combined ~950 lines is substantial. The RLV exception list
could grow large. Would need `llGetFreeMemory()` guards. Only merge if memory
analysis confirms headroom.

---

## Addressing the Fan-Out Problem

Beyond merging, the biggest performance win comes from reducing message fan-out.

### Option A: Targeted link_message delivery
Replace `LINK_SET` with specific link numbers where possible:
```lsl
// Instead of broadcasting to ALL 28 scripts:
llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);

// Target only the auth script's link:
llMessageLinked(AUTH_LINK, AUTH_BUS, msg, NULL_KEY);
```
**Trade-off:** Requires knowing link numbers at compile time or discovering them
at startup. Link numbers can change if prims are added/removed. Would need a
link-number discovery protocol.

**Verdict:** High effort, fragile. Not recommended for this architecture.

### Option B: Reduce heartbeat frequency
Current: ping every 5 seconds = 448 event deliveries per cycle.

If increased to 10 seconds: 448 deliveries per 10s = **50% reduction**.
The prune timeout (15s) would need to increase proportionally (to 30s).

**Trade-off:** Slower dead-plugin detection. Acceptable for a collar that rarely
has plugins crash mid-session.

**Verdict: RECOMMENDED.** Easy change, significant impact. The 5-second heartbeat
is aggressive for ~15 stable plugins. 10-15 seconds is more appropriate.

### Option C: Replace ping/pong with inventory-based liveness
Instead of polling all plugins every 5s, rely on `llGetInventoryType()` to check
if a plugin script still exists. Only ping when a script's UUID changes or when
the inventory count changes.

**Trade-off:** Cannot detect a script that exists but is stuck/crashed (which
ping/pong can detect via timeout). However, LSL scripts rarely hang — they either
run or crash and get removed.

**Verdict:** Partial adoption. Use inventory checks as the primary liveness
mechanism, with infrequent pings (every 30-60s) as a secondary check.

---

## Summary: Recommended Merges

| Merge | Scripts | Lines Saved | Heartbeats Saved/5s | Memory Freed | Risk |
|-------|---------|-------------|---------------------|-------------|------|
| kmod_ui + menu | 2 → 1 | ~80 | 28 events | 64KB | Low |
| public + lock + tpe | 3 → 1 | ~400 | 112 events | 128KB | Low |
| rlvrestrict + rlvexceptions | 2 → 1 | ~200 | 56 events | 64KB | Medium |
| **Total** | **7 → 3** | **~680** | **196 events/5s** | **256KB** | - |

### Do NOT Merge

| Scripts | Reason |
|---------|--------|
| kernel + anything | System-critical, memory-heavy |
| kmod_settings + anything | Data store, memory-heavy |
| kmod_auth + anything | Security-critical |
| kmod_leash + kmod_particles | Timer conflict |
| plugin_leash + anything | Memory-heavy (already crashed once) |
| plugin_sos + anything | Emergency safety isolation |
| plugin_access + anything | Memory + sensor usage |
| Any two scripts that both use timer | Hard LSL constraint |
| Any two scripts that both use sensor | Hard LSL constraint |

### Heartbeat Optimization (Independent of Merges)

| Change | Impact |
|--------|--------|
| Increase ping interval 5s → 15s | -296 events per cycle |
| Increase prune timeout 15s → 45s | Proportional safety margin |
| Add inventory-based liveness | Eliminates most pongs |

**Combined impact of merges + heartbeat tuning:**
- From 28 scripts to 24 scripts
- From ~448 events/5s to ~150 events/15s (heartbeat)
- ~256KB of Mono allocation freed
- ~680 lines of duplicated boilerplate eliminated
