# AGENTS.md — General Guide to Writing Correct LSL

A project‑agnostic playbook for humans and AI agents to produce **compile‑ready**, **safe**, and **efficient** Linden Scripting Language (LSL) code for any Second Life build: HUDs, attachments, rezzers, vendors, vehicles, RP tools, etc.

---

## 0) North‑Star Principles

1. **Compilation first.** Only use syntax supported by LSL. Favor clarity over cleverness.
2. **Event‑driven design.** Keep logic small inside events; push reusable work into helpers.
3. **Safety by default.** Guard listeners, validate input, deny if unsure.
4. **Resource awareness.** Work within LSL’s memory/time limits.
5. **Predictable UX.** Clear menus, minimal chat spam, graceful failure.

---

## 1) Language Rules & Gotchas

- **No ternary operator** (`cond ? a : b`).
- **No `switch`** in LSL; use `if/else` chains.
- **No `break` statement**. Use early `return` in functions or flags in loops to emulate breaking.
- **One variable per declaration**; no chained declarations.
- **Explicit casting**: `(integer)`, `(float)`, `(string)`; avoid implicit conversions.
- **Dialog buttons**: must be a multiple of 3; pad with exactly one space `" "`.
- **Memory**: avoid giant lists/strings; reuse data; watch for stack‑heap collisions.
- **State usage**: use sparingly; prefer flags instead of many states.
- **Events**: all code runs inside events; there is no main loop.

JSON helpers:
```lsl
integer json_has(string j, list p){ return (llJsonGetValue(j,p) != JSON_INVALID); }
integer json_int(string j, list p, integer def){ string v=llJsonGetValue(j,p); if(v==JSON_INVALID||v=="") return def; return (integer)v; }
string  json_str(string j, list p, string def){ string v=llJsonGetValue(j,p); if(v==JSON_INVALID) return def; return v; }
```

---

## 2) Best Practices (Deep Dive)

### 2.1 Communication & Chat
- Prefer **targeted channels** over broadcast:
  - `llRegionSayTo`/`llInstantMessage` for targeted messages to avatars; avoid spamming region chat.  
  - `llOwnerSay` only reaches the owner **in the same region**; use IM if the owner may be elsewhere.
- Avoid channel 0 for scripted traffic. Use a **random negative channel** for dialogs and private chat.
- **Throttle awareness**:
  - DEBUG channel messages are throttled region‑wide; excessive debug spam will be dropped.
- Always **filter listeners** by channel **and** speaker key; remove or disable listeners when not in use.

### 2.2 Listeners & Dialogs
- One active `llListen` per menu/session; close it on `Back`, on timeout, and on reset.
- Dialog buttons must be a **multiple of 3**; pad with a single space `" "`.
- `llListen` channel must fit in a 32‑bit integer; out‑of‑range literals resolve to `-1`.

### 2.3 Memory & Data
- Watch free memory with `llGetFreeMemory()`; avoid large transient lists/strings.
- The **heap never shrinks** at runtime; repeated concatenations grow memory usage permanently.
- Prefer integers/enums/bit‑flags over strings; reuse buffers; avoid `llListSort` in hot paths.
- For JSON, extract fields directly (`llJsonGetValue`) instead of converting whole structures.

### 2.4 Events & Flow Control
- Keep work **short inside events**; offload heavy work via timers/state transitions.
- **No `break`** in LSL: exit loops by flags or restructure into helper functions and **early `return`**.
- Avoid long `llSleep()` in events; it blocks the event queue for that script.
- Be mindful of the **64‑event queue**; high‑volume listeners/sensors can starve other events.

### 2.5 Timers & Sensors
- Use **modest timer intervals** (≥0.2–0.5s for UI, seconds for background tasks).
- Sensors: narrow **range and arc**; schedule with timers; prefer raycasts or region APIs when appropriate.

### 2.6 HTTP & External I/O
- Respect HTTP throttles (per‑object and per‑owner). Queue/pace requests; retry on 503.
- Body sizes: incoming `http_request` body is limited (~2048 bytes), headers ~255 bytes per header.
- Batch large transfers; compress or chunk payloads; service your event queue while throttled.

### 2.7 Permissions & Animations
- Request only the permissions you need; verify bits in `run_time_permissions`.
- Stop animations/particles on reset, soft‑reset, detach, and error paths.

### 2.8 Intra‑Object Messaging
- Prefer `llMessageLinked` with **small numeric lanes** and **compact JSON** payloads.
- Validate message `num` and `type` before handling; ignore unknown types safely.

### 2.9 Attachments, HUDs, Rez Objects
- Attachments: wearer is `llGetOwner()`; initialize on `attach()` and `on_rez()`.
- HUDs: avoid region chat; keep visual updates ≤ 10 Hz; don’t assume camera facing.
- Rezzers: check creator/owner permissions; clean up orphaned children; handle failed rez.

### 2.10 UX Conventions
- Keep dialog bodies short (viewer truncation).  
- Consistent nav: `<<`, `Back`, `>>`.  
- Place critical actions with `llDialog`’s **bottom‑left → top‑right** fill order in mind.

### 2.11 Robustness & Recovery
- Handle `CHANGED_OWNER`, `CHANGED_REGION`, `CHANGED_TELEPORT`, `CHANGED_INVENTORY`.
- Close listeners, stop effects, and clear temp state on any reset or soft‑reset.

### 2.12 States
- Use states sparingly. Most control flow can be handled with flags and context variables.
- Good use cases for states:
  - Distinct lifecycle phases (e.g., `init`, `active`, `waiting`).
  - Scripts that must ignore events until setup completes.
  - Long‑lived modes with completely different event logic.
- Bad use cases:
  - Avoid states just to break out of loops or events—use early `return` or helper functions instead.
  - Don’t create many near‑duplicate states; harder to maintain.
- On `state` change:
  - All event queues are cleared; be careful not to lose needed data.
  - Re‑initialize variables if required (globals reset to defaults).
- Document why each state exists. If unclear, prefer staying in `default` with flags.

### 2.13 Micro‑Optimization Reality Check
- Classic micro‑tweaks (like `++a` vs `a++`) **do not matter** under Mono; focus on algorithms and allocations.

---

## 3) Core Event Usage

- **`state_entry`**: initialize globals, load config, start timers.
- **`on_rez`**: usually `llResetScript()` for clean reinit.
- **`attach`**: handle attach/detach; request permissions if needed.
- **`touch_start`**: entry point for user interaction.
- **`listen`**: always filter by channel and speaker key.
- **`timer`**: short, non‑blocking recurring tasks.
- **`sensor`/`no_sensor`**: use narrow arcs, short ranges, modest frequency.
- **`run_time_permissions`**: check granted bits before acting.
- **`link_message`**: use JSON; check `num` and `type` before handling.
- **`dataserver`**: compare query IDs before using data.
- **`changed`**: handle owner/region/inventory changes.

---

## 4) Common Patterns

### Dialog + Listener
```lsl
integer gListen=0; integer gChan=0; key gUser=NULL_KEY;
integer reset_listen(){ if(gListen) llListenRemove(gListen); gListen=0; gChan=0; return 0; }
integer dialog_to(key who,string body,list buttons){
    reset_listen(); while((llGetListLength(buttons)%3)!=0) buttons += " ";
    gChan=-100000-(integer)llFrand(1000000.0);
    gListen=llListen(gChan,"",who,"");
    llDialog(who,body,buttons,gChan); return 0;
}
```

### Permissions
```lsl
integer gHasPerms=FALSE;
request_perms(){ llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION|PERMISSION_TAKE_CONTROLS); }
run_time_permissions(integer p){ if(p & PERMISSION_TRIGGER_ANIMATION) gHasPerms=TRUE; }
```

### Loop Exit (no break)
```lsl
integer stop=FALSE; integer i;
for(i=0;i<10 && !stop;++i){
    if(i==5) stop=TRUE; // emulate break
}
```

### Inventory Scan
```lsl
list load_items(integer type){ list L=[]; integer n=llGetInventoryNumber(type); integer i; for(i=0;i<n;++i) L += llGetInventoryName(type,i); return L; }
```

### Particles
```lsl
start_particles(){ llParticleSystem([ PSYS_PART_MAX_AGE,1.5 ]); }
stop_particles(){ llParticleSystem([]); }
```

---

## 5) Debugging

- Use a `DEBUG` flag and helper like `logd()` to control chat output.
- Log only essentials; avoid flooding chat.
- Use early returns to isolate where logic breaks.
- Print IDs for notecard/dataserver queries.

---

## 6) Minimal Generic Skeleton

```lsl
integer DEBUG=FALSE; integer logd(string s){ if(DEBUG) llOwnerSay("[S] "+s); return 0; }

key gUser=NULL_KEY; integer gListen=0; integer gChan=0; string gCtx="";

integer reset_listen(){ if(gListen) llListenRemove(gListen); gListen=0; gChan=0; return 0; }
integer dialog_to(key who,string body,list buttons){
    reset_listen(); while((llGetListLength(buttons)%3)!=0) buttons+=" ";
    gChan=-100000-(integer)llFrand(1000000.0);
    gListen=llListen(gChan,"",who,"");
    llDialog(who,body,buttons,gChan); return 0;
}

default{
    state_entry(){ logd("Ready"); }
    on_rez(integer p){ llResetScript(); }
    changed(integer c){ if(c & CHANGED_OWNER) llResetScript(); }
    touch_start(integer n){ key av=llDetectedKey(0); gUser=av; dialog_to(av,"Menu",["Do","Settings","Back"]); }
    listen(integer ch,string nm,key id,string msg){ if(ch!=gChan||id!=gUser) return;
        if(msg=="Back"){ reset_listen(); gUser=NULL_KEY; return; }
        if(msg=="Do"){ llOwnerSay("Did something"); }
    }
}
```

---

## 7) Prompting Hints for AI Agents

- “Generate **compile‑ready** LSL with only supported syntax.”
- “Do not use ternary, `switch`, or `break`.”
- “Always clean up listeners when leaving a menu.”
- “Pad dialog buttons to a multiple of 3 with a single space.”
- “Filter listeners by channel and avatar key.”
- “Use early return or flags instead of break.”
- “Keep per‑event code minimal.”

---

**This document is a living reference.** Extend it with domain‑specific best practices (HUDs, vendors, vehicles, etc.) as needed.


## 12) Best Practices for **States** in LSL

States are powerful but easy to overuse. Treat them as **coarse‑grained modes** (setup, idle, active, error) rather than replacing simple flags.

### 12.1 When to Use States
- **Modal behavior**: substantially different event handling (e.g., setup vs. runtime vs. error‑recovery).
- **Lifecycle gates**: permission negotiation, HTTP server sessions, sensor sweep phases, multi‑step interactions.
- **Performance control**: disable heavy listeners/sensors entirely in states where they’re not needed.

### 12.2 When **Not** to Use States
- Minor toggles (on/off, a single option) — prefer a boolean flag.
- Small UI subpages — keep one state and track a `context` string/enum.
- To emulate `break`/`continue` — use early `return` and loop flags instead.

### 12.3 Entering & Leaving States
- Use `state_entry` to (re)initialize **only what this state needs**:
  - set/clear timers with `llSetTimerEvent`
  - (re)open listeners for this mode only
  - reset per‑state variables and UI
- Use `state_exit` to stop effects:
  - remove/close listeners (defensive), stop particles/animations, save transient state if needed
- **Queues & timing**: moving state clears pending events for the old state; schedule critical work before switching.
- **Variables**: global variables persist across states; reinitialize intentionally to avoid stale data.

### 12.4 Patterns
- **Two‑state setup**: `state Setup` → load config/permissions → `state Idle` when ready.
- **Error trap**: `state Error` with a small menu (Retry/Reset/Report); exit back to Idle when healthy.
- **Activity mode**: `state Active` enables listeners/sensors only while a session is running; `state Idle` keeps them off.

### 12.5 Anti‑Patterns
- Splitting nearly identical logic across many states → hard to reason and test.
- Re‑implementing the same helper in multiple states — keep helpers outside states and share.
- Forgetting to re‑arm the timer/listener in `state_entry` and assuming it carried over.

### 12.6 Testing States
- Verify that **each** state has a clean `state_entry` and that leaving the state stops timers/listeners/effects.
- Exercise unexpected transitions (teleport, detach, owner change) and ensure you don’t strand particles or open listens.
- Log the current state name on transitions (guarded by `DEBUG`).

