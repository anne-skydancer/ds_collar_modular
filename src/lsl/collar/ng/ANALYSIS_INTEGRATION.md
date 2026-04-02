# Integration vs. Separation Deep Dive

> **NOTE (2026-04-02):** See staleness disclaimer in [ANALYSIS_OVERVIEW.md](./ANALYSIS_OVERVIEW.md). Script counts below (28 scripts) reflect the pre-cleanup codebase. v1.1 has 26 scripts. References to `min_acl` in merge candidate code (e.g. the public+lock+tpe merge example) are stale — registration no longer uses `min_acl`. Script file names use the old `ds_collar_` prefix; v1.1 uses short names.

**What works best inside one script vs. as separate scripts?**

This analysis maps the DS Collar NG architecture against LSL's concrete runtime
constraints to recommend where consolidation saves resources and where separation
is essential.

> **CRITICAL CONSTRAINT:** In this codebase, scripts cannot exceed ~1024 lines
> without risking stack-heap collision. `plugin_leash.lsl` already crashed at
> 993 lines and was trimmed to 968 (currently ~882 after chat command removal).
> This ceiling fundamentally limits merge opportunities.

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

### ~~Candidate 1: Merge `kmod_ui.lsl` + `ds_collar_menu.lsl`~~ REJECTED
**Current:** Two scripts, tightly coupled via link_message on UI_BUS.

| Metric | Separate | Merged |
|--------|----------|--------|
| Scripts | 2 | 1 |
| Combined lines | 899 + 230 = 1129 | ~1104 (remove ~25 lines shared boilerplate) |

**Verdict: CANNOT MERGE.** Combined script would be ~1104 lines, exceeding the
~1024 line memory ceiling. `kmod_ui.lsl` is already at 899 lines (88% of limit)
and is itself at risk of needing to shed code.

**Alternative:** Keep separate. The link_message cost per menu display is acceptable
given the memory constraint. If `kmod_ui.lsl` grows further, consider splitting
*it* instead — e.g., extracting session management into a separate module.

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
| `plugin_sos.lsl` | Emergency actions | Must be isolated for safety |

**`plugin_sos.lsl` MUST stay separate.** It's the emergency escape hatch. If it
were merged with another script that crashes due to memory, the wearer loses
their SOS capability. Isolation is a safety requirement.

---

### ~~Candidate 4: Merge `plugin_rlvrestrict.lsl` + `plugin_rlvexceptions.lsl`~~ REJECTED
**Current:** Two scripts managing related RLV functionality.

| Metric | Separate | Merged |
|--------|----------|--------|
| Scripts | 2 | 1 |
| Combined lines | 573 + 576 = 1149 | ~1069 (shared boilerplate) |

**Verdict: CANNOT MERGE.** Combined script would be ~1069 lines, exceeding the
~1024 line memory ceiling. Both scripts individually are in the watch zone
(~56% of limit) and are sized appropriately as separate scripts.

---

## Scripts That Need SPLITTING

The ~1024 line memory ceiling means two scripts are already over-limit and
several more are approaching it. This section is arguably more important
than the merge analysis.

### URGENT: `plugin_leash.lsl` (1066 lines) — Already Crashed

This script previously had a stack-heap collision (rev 21) at 993 lines. After
chat command removal, it is now ~882 lines — comfortably under the ~1024 ceiling.
**No split is currently needed.**

**What it contains (post chat command removal):**
- Plugin lifecycle (register, pong): ~30 lines
- Settings sync/delta: ~50 lines
- ACL query/handling: ~40 lines
- Menu system (main, settings, length, pass, coffle, post menus): ~250 lines
- Button click handlers: ~120 lines
- Sensor handling (coffle/post object selection): ~80 lines
- Offer dialog system: ~70 lines
- State query tracking: ~30 lines
- Helper functions + boilerplate: ~100 lines
- Misc (pagination, cleanup, actions): ~80 lines

**Future split option** (if the script grows again):
Extract the coffle/post sensor UI into a separate script. The sensor results
(`SensorCandidates`, pagination) are only needed during object selection
menus and could be isolated.

---

### URGENT: `kmod_leash.lsl` (1063 lines) — Over Limit

**What it contains:**
- ACL verification system: ~120 lines
- Holder protocol state machine (DS + OC phases): ~100 lines
- Follow mechanics (movement, distance, turn-to-face): ~80 lines
- Offsim detection + auto-reclip: ~70 lines
- Leash actions (grab, release, pass, coffle, post, yank): ~150 lines
- Settings persistence/sync: ~80 lines
- Lockmeister/particles protocol messages: ~40 lines
- Notification helpers: ~30 lines
- State management helpers: ~60 lines
- Event handlers + lifecycle: ~150 lines
- Helper functions + constants: ~100 lines

**Recommended split:**

| New Script | Contents | Est. Lines |
|-----------|----------|-----------|
| `kmod_leash.lsl` | Core leash state, actions, follow, offsim, settings, events | ~700 |
| `kmod_leash_holder.lsl` | Holder detection protocol (DS + OC state machine) | ~350 |

**Why this split works:**
- The holder protocol is a **self-contained state machine** that runs for
  2-4 seconds during leash grab, then goes idle. It uses its own listeners
  (HolderListen, HolderListenOC) and its own state variables.
- The main leash module only needs to know the *result* (HolderTarget key).
  After the handshake completes, it calls `setParticlesState(TRUE, HolderTarget)`.
- Communication: `kmod_leash` sends "find_holder" to the new script;
  the new script responds with "holder_found" + target key.
- Both need the timer, but this is solvable: the holder protocol currently
  uses the leash timer for phase advancement. In the split, the holder
  script gets its own timer (2s phases), and the leash script keeps the
  follow timer (0.5s).

---

### AT RISK: `kmod_ui.lsl` (899 lines) — 88% of Limit

**Risk:** Any new feature (e.g., additional session fields, new menu types)
will push this over the limit.

**Preemptive split if needed:**

| New Script | Contents | Est. Lines |
|-----------|----------|-----------|
| `kmod_ui.lsl` | Session management, ACL filtering, plugin list, events | ~600 |
| `kmod_ui_touch.lsl` | Touch handling, long-touch SOS detection, touch range validation | ~300 |

The touch_start/touch_end handlers + TouchData management are self-contained
and don't share state with the session management system. The touch handler's
only output is calling `start_root_session()` or `start_sos_session()`, which
can be done via link_message.

---

### AT RISK: `plugin_access.lsl` (848 lines) — 83% of Limit

**Preemptive split if needed:**

| New Script | Contents | Est. Lines |
|-----------|----------|-----------|
| `plugin_access.lsl` | Main menu, owner/trustee management, settings | ~550 |
| `plugin_access_scan.lsl` | Avatar sensor scanning, candidate selection, name resolution | ~300 |

The sensor-based avatar selection (scan → build candidate list → show numbered
dialog) is reusable across access, blacklist, and leash plugins. Extracting it
could serve all three.

---

### Size Budget Summary

| Script | Current | Limit | Headroom | Status |
|--------|---------|-------|----------|--------|
| plugin_leash.lsl | 1066 | ~1024 | **-42** | **OVER - SPLIT NEEDED** |
| kmod_leash.lsl | 1063 | ~1024 | **-39** | **OVER - SPLIT NEEDED** |
| kmod_ui.lsl | 899 | ~1024 | 125 | Watch zone |
| plugin_access.lsl | 848 | ~1024 | 176 | Watch zone |
| plugin_rlvrelay.lsl | 795 | ~1024 | 229 | OK |
| kernel.lsl | 782 | ~1024 | 242 | OK |
| kmod_settings.lsl | 730 | ~1024 | 294 | OK |
| plugin_maintenance.lsl | 646 | ~1024 | 378 | OK |
| kmod_auth.lsl | 637 | ~1024 | 387 | OK |
| kmod_bootstrap.lsl | 622 | ~1024 | 402 | OK |

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

## Summary: Revised Recommendations (with ~1024 Line Ceiling)

The ~1024 line memory constraint fundamentally shifts the analysis from
"what can we merge?" to "what must we split?" Only one merge remains viable.

### Viable Merge (1 only)

| Merge | Scripts | Lines Result | Heartbeats Saved/5s | Memory Freed | Risk |
|-------|---------|-------------|---------------------|-------------|------|
| public + lock + tpe | 3 → 1 | ~540 | 112 events | 128KB | Low |

### Possible Future Splits

| Split | Scripts | Reason | Priority |
|-------|---------|--------|----------|
| kmod_leash → kmod_leash + kmod_leash_holder | 1 → 2 | At 1063 lines (804 code), near limit | Low (within budget) |

### Rejected Merges (exceeded line ceiling)

| Merge | Combined Lines | Over Limit By |
|-------|---------------|---------------|
| ~~kmod_ui + menu~~ | ~1104 | ~80 lines |
| ~~rlvrestrict + rlvexceptions~~ | ~1069 | ~45 lines |

### Do NOT Merge

| Scripts | Reason |
|---------|--------|
| kernel + anything | System-critical, 782 lines already |
| kmod_settings + anything | Data store, 730 lines |
| kmod_auth + anything | Security-critical |
| kmod_leash + kmod_particles | Timer conflict |
| plugin_leash + anything | Memory-heavy, already crashed |
| plugin_sos + anything | Emergency safety isolation |
| plugin_access + anything | 848 lines, sensor usage |
| Any two scripts that both use timer | Hard LSL constraint |
| Any two scripts that both use sensor | Hard LSL constraint |
| Any combination exceeding ~1024 lines | **Hard memory constraint** |

### Heartbeat Optimization (Independent of Merges/Splits)

| Change | Impact |
|--------|--------|
| Increase ping interval 5s → 15s | -296 events per cycle |
| Increase prune timeout 15s → 45s | Proportional safety margin |
| Add inventory-based liveness | Eliminates most pongs |

### Net Effect

| Metric | Before | After |
|--------|--------|-------|
| Total scripts | 28 | 27 (merge 3→1, split 2→4, net -1) |
| Scripts over 1024 lines | 2 | 0 |
| Scripts in danger zone (>800) | 5 | 3 (kmod_ui, plugin_access remain) |
| Heartbeat events/cycle | 448/5s | ~168/15s (with interval increase) |
| Memory freed by merge | - | 128KB |
| Stack-heap crash risk | High (2 scripts) | Low |
| Boilerplate eliminated | - | ~400 lines (toggle merge) |

### Priority Order

1. **Split `plugin_leash.lsl`** — Already crashed, most urgent
2. **Split `kmod_leash.lsl`** — Over limit, timer separation needed
3. **Merge `public + lock + tpe`** — Easy win, saves 2 scripts
4. **Increase heartbeat interval** — Biggest performance win
5. **Monitor `kmod_ui.lsl` and `plugin_access.lsl`** — Pre-plan splits
