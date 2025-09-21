# AGENTS.md — General Guide to Writing Correct LSL

A project‑agnostic playbook for humans and AI agents to produce **compile‑ready**, **safe**, and **efficient** Linden Scripting Language (LSL) code for any Second Life build: HUDs, attachments, rezzers, vendors, vehicles, RP tools, etc.

---

## 0) North‑Star Principles

1. **Compilation first.** Use only syntax supported by LSL. Favor explicit code over cleverness.
2. **Event‑driven design.** Keep logic short inside events; push reusable work into helpers.
3. **Safety by default.** Gate by avatar, validate input, and clean up listeners/timers.
4. **Resource awareness.** Optimize for tight memory and time slices.
5. **Predictable UX.** Clear dialogs, minimal chat spam, graceful failure.

---

## 1) Language Rules & Gotchas (Hard Constraints)

- **No ternary operator** (`cond ? a : b`).
- **No chained declarations** on one line; declare one variable per statement.
- **Avoid `switch`**. Use `if/else`.
- **`break` only works in loops.**
- **String ↔ number**: explicit casts (`(integer)`, `(float)`), never rely on implicit.
- **JSON**: `llJsonGetValue` returns `JSON_INVALID` if missing; always check.
- **Dialogs**: buttons count must be a multiple of 3; pad with exactly one space `" "`.
- **Memory**: large lists/strings lead to stack‑heap collisions; reuse data structures.
- **States**: use `state` sparingly; many problems can be solved with flags and events.

Helpers:
```lsl
integer json_has(string j, list p){ return (llJsonGetValue(j,p) != JSON_INVALID); }
integer json_int(string j, list p, integer def){ string v=llJsonGetValue(j,p); if(v==JSON_INVALID||v=="") return def; return (integer)v; }
string  json_str(string j, list p, string def){ string v=llJsonGetValue(j,p); if(v==JSON_INVALID) return def; return v; }
```

---

## 2) Core Event Reference (What to use and why)

- **`state_entry`**: initialize globals, load inventory, start timers.
- **`on_rez`**: usually `llResetScript()` to boot cleanly after rez/attach.
- **`attach`**: for attachments; request permissions or setup HUD offsets.
- **`touch_start`/`touch_end`**: primary UI entry point; identify toucher with `llDetectedKey(0)`.
- **`listen`**: handle dialog/chat responses. Always filter by channel **and** speaker key.
- **`timer`**: short periodic tasks; never heavy work.
- **`sensor`/`no_sensor`**: proximity logic; avoid frequent, wide scans.
- **`run_time_permissions`**: confirm granted permissions; degrade gracefully if missing.
- **`link_message`**: intra‑linkset communication; prefer JSON payloads.
- **`dataserver`**: async notecard/name lookups; store transaction IDs.
- **`changed`**: watch for `CHANGED_OWNER`, `CHANGED_REGION`, `CHANGED_TELEPORT`, `CHANGED_INVENTORY`.

---

## 3) Common Patterns (Copy‑Ready)

### A) Dialog + Safe Listener
```lsl
integer gListen=0; integer gChan=0; key gUser=NULL_KEY;
integer reset_listen(){ if(gListen) llListenRemove(gListen); gListen=0; gChan=0; return 0; }
integer dialog_to(key who, string body, list buttons){
    reset_listen(); while((llGetListLength(buttons)%3)!=0) buttons += " ";
    gChan = -100000 - (integer)llFrand(1000000.0);
    gListen = llListen(gChan, "", who, "");
    llDialog(who, body, buttons, gChan); return 0;
}
```

### B) Permissions Request (generic)
```lsl
integer gHasAnim=FALSE; key gOwner;
request_perms(){ gOwner = llGetOwner(); llRequestPermissions(gOwner, PERMISSION_TRIGGER_ANIMATION|PERMISSION_TAKE_CONTROLS); }
run_time_permissions(integer p){ if(p & PERMISSION_TRIGGER_ANIMATION) gHasAnim=TRUE; }
```

### C) Inventory Scans
```lsl
list load_items(integer invType){ list L=[]; integer n=llGetInventoryNumber(invType); integer i=0; for(i=0;i<n;++i) L += llGetInventoryName(invType,i); return L; }
```

### D) Particles
```lsl
start_particles(){ llParticleSystem([ PSYS_PART_MAX_AGE,1.5, PSYS_SRC_MAX_AGE,0.0 ]); }
stop_particles(){ llParticleSystem([]); }
```

### E) Simple Link Message Bus
```lsl
integer BUS=1000; // choose your lane
send(string t, string payload){ string j=llList2Json(JSON_OBJECT,[]); j=llJsonSetValue(j,["type"],t); j=llJsonSetValue(j,["data"],payload); llMessageLinked(LINK_SET,BUS,j,NULL_KEY); }
```

---

## 4) Access Control (Generalized)

- Attachments often have a single principal: **the wearer** (`llGetOwner()`).
- Rezzed objects may have a creator/owner and public users; gate on:
  - owner‐only: `(av == llGetOwner())`
  - group‐only: `llSameGroup(av)` + group active tag
  - public: allow touch but restrict privileged actions
- Always validate keys: `if (av == NULL_KEY) return;` and ignore non‑human agents if desired.

---

## 5) Inter‑Object Communication

**Linkset**: use `llMessageLinked(LINK_THIS/LINK_SET, num, json, id)` with small numeric lanes.  
**Region chat**: prefer `llRegionSayTo(target, chan, msg)` to avoid eavesdropping.  
**HTTP‑in**: throttle‑aware, consider experiences/permissions; persist URLs.

Schema tip:
```lsl
// Minimal message
{"type":"event","context":"optional","data":"..."}
```

---

## 6) UX Conventions

- Reserve nav labels: `<<`, `Back`, `>>` when paging.
- `llDialog` fills bottom‑left → top‑right. Place priority actions accordingly.
- Keep bodies short; multiline is OK but avoid long paragraphs.
- For HUDs, avoid spam and keep updates to ~5–10 Hz visual refresh at most.

---

## 7) Performance & Memory

- Reuse strings/lists; avoid concatenating in loops.
- Cache inventory counts if you open menus frequently.
- Prefer integers/flags over strings; avoid `llListSort` on large lists.
- Sensors: narrow arc/range; schedule with timers, not busy loops.
- Throttle: respect chat/sensor/link‑message limits.

---

## 8) Robustness & Cleanup

- On closing a UI: remove listeners, stop particles/animations.
- On `CHANGED_OWNER`: typically reset.
- On teleport/region change: briefly suppress auto‑reopens unless desired.
- Handle failure paths (permissions denied, missing inventory) with gentle messages.

---

## 9) Testing Checklist

- [ ] Compiles cleanly (no unsupported syntax like ternary or chained decls).
- [ ] Touch opens a menu for the intended user(s).
- [ ] Dialog buttons count is a multiple of 3; padding is a single space.
- [ ] Listener is filtered by channel **and** speaker key; removed on close.
- [ ] Animations/particles start **and stop** across all exits.
- [ ] Timers are short; no heavy loops in events.
- [ ] Permissions paths tested (granted vs denied).
- [ ] No hardcoded UUIDs/channels unless documented.

---

## 10) Debugging Techniques

- Use a `DEBUG` flag and `logd()` helper; keep logs short.
- Binary‑search failures by early returns in events.
- Print key states (current context, flags) sparingly.
- For notecards/dataserver: log the query ID and compare in handler.

---

## 11) Minimal Generic Script Skeleton

```lsl
/* =============================================================
   Script: Generic LSL Skeleton
   Purpose: Safe dialog, touch gate, tidy listeners, heartbeat
   ============================================================= */

integer DEBUG=FALSE; integer logd(string s){ if(DEBUG) llOwnerSay("[S] "+s); return 0; }

key gUser=NULL_KEY; integer gListen=0; integer gChan=0; string gCtx="";

integer reset_listen(){ if(gListen) llListenRemove(gListen); gListen=0; gChan=0; return 0; }
integer dialog_to(key who,string body,list buttons){
    reset_listen(); while((llGetListLength(buttons)%3)!=0) buttons += " ";
    gChan=-100000-(integer)llFrand(1000000.0); gListen=llListen(gChan,"",who,"");
    llDialog(who,body,buttons,gChan); return 0;
}

integer HB_TICK=10; integer gLast=0;
integer hb_init(){ gLast=llGetUnixTime(); llSetTimerEvent((float)HB_TICK); return 0; }
integer hb_tick(){ /* keep light */ return 0; }

integer show_menu_root(key who){ gCtx="menu"; return dialog_to(who,"Example
Choose:",["Do Thing","Settings","Back"]); }

default{
    state_entry(){ reset_listen(); hb_init(); logd("Ready"); }
    on_rez(integer p){ llResetScript(); }
    attach(key id){ /* optional: request_perms(); */ }
    changed(integer c){ if(c & CHANGED_OWNER) llResetScript(); }
    touch_start(integer n){ key av=llDetectedKey(0); gUser=av; show_menu_root(av); }
    listen(integer ch,string nm,key id,string b){ if(ch!=gChan||id!=gUser) return;
        if(b=="Back"){ reset_listen(); gUser=NULL_KEY; gCtx=""; return; }
        if(gCtx=="menu"){ if(b=="Do Thing"){ /* action */ } if(b=="Settings"){ gCtx="settings"; dialog_to(id,"Settings:",["A","B","Back"]); return; } }
        if(gCtx=="settings"){ /* toggle */ show_menu_root(id); return; }
    }
    timer(){ hb_tick(); }
}
```

---

## 12) Optional Modules & Topics (When You Need Them)

- **Vehicles/Physics**: use `llSetVehicleType`, `llSetBuoyancy`, keep timers lean; clamp inputs.
- **HUDs**: position with offsets; avoid region chat; rely on link messages or `llRegionSayTo`.
- **Notecard configs**: load once at startup via `llGetNotecardLine`; cache results.
- **Experiences**: check availability; wrap with graceful fallbacks.
- **Security**: avoid broadcasting secrets on open chat; validate keys; rate‑limit sensitive actions.

---

## 13) Prompting Hints for AI Agents

- “Generate **compile‑ready** LSL with only supported syntax (no ternary/switch/chained decls).”
- “One active dialog listener at a time; pad to multiples of 3 with a single space button.”
- “Filter `listen` by channel and avatar key; ignore unexpected speakers.”
- “Put minimal logic in events; move repeated code into helpers.”
- “Document assumptions and any behavior changes in a brief header comment.”

---

**Use this guide as a baseline for any LSL project.** Adapt lanes, permissions, and UX to your specific build while keeping the safety and performance patterns intact.

