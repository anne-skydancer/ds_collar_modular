# AGENTS.md — LSL Technical Requirements & Coding Constraints

> A practical reference for agents and assistants that generate or review **Linden Scripting Language (LSL)** code. This document covers TECHNICAL REQUIREMENTS ONLY. For style, documentation, and best practices, see `agents-style.md`.

---

## 0) Prerequisites & Workflow

### 0.1) Tool Installation
**REQUIRED:** Before any LSL coding session, install `lslint`:
```bash
# Clone and build lslint
git clone https://github.com/Makopo/lslint.git /tmp/lslint
cd /tmp/lslint && make
cp lslint /usr/local/bin/lslint
```

### 0.2) Code Analysis Before Coding
**REQUIRED:** Before writing or modifying any LSL code:
1. **Parse in its entirety the LSL API reference and best practices** (official LSL documentation - https://wiki.secondlife.com/wiki/LSL_Portal)
2. Parse the project-specific agents.md (this file - LSL quirks, limitations, and project conventions)
3. Read existing code files in the working directory
4. Identify patterns, ABI versions, and conventions in use
5. Check which branch you're working in (stable/ vs ng/)
6. Never assume - always verify

### 0.3) Syntax Verification After Coding
**MANDATORY:** After writing ANY LSL code:
1. Save the file
2. Run `lslint <filename>.lsl` to verify syntax
3. Fix ALL errors and warnings before proceeding
4. Re-run lslint until it passes cleanly
5. **No excuses:** Knowledge of other languages is NOT an excuse for LSL syntax errors
6. **Zero tolerance:** Ternaries, switch statements, reserved keywords as variables - these are HARD FAILURES

---

## 1) Scope & Goals

* Produce **compile‑ready** LSL (no unsupported syntax or APIs).
* Prefer **robust, secure, and performant** patterns over "clever" code.
* Keep scripts **event‑driven** and **single‑thread friendly**; avoid blocking.

## 2) Hard Language Constraints (must‑remember)

* **No ternary operator** (`cond ? a : b`) — use explicit `if/else` chains.
* **Constants and global variables must be declared before use**
* **No `break` / `continue`** keywords — use structured logic or `jump` labels.
* **No `switch`** statement — use `if/else if/else` ladders.
* **No exceptions / try–catch** — handle errors with guards and return codes.
* **No function overloading or default params** — unique names, explicit args.
* **Single timer per script** (`llSetTimerEvent`) — design accordingly.
* **Event‑driven model** only — no custom threads; yields occur on event exit.
* **Blocking calls stall the script** — prefer async APIs (dataserver, HTTP, etc.).
* **Memory is tight** (Mono VM; heap/stack are limited) — avoid bloat.
* **Max 12 dialog buttons** (3×4 grid). Pad to multiples of 3 with a single space (`" "`).
* **Listen filters matter** — avoid wide open listeners; always scope to avatar/channel.
* **Key/UUID is a string** (`key`), treat as opaque; validate when needed.

## 3) Core Event Model

Common events to implement thoughtfully:

* `state_entry`, `on_rez`, `changed`, `attach` — init/reset/ownership transitions.
* UI/input: `touch_start`, `listen`, `timer` — keep responsive; never heavy work inside.
* Async: `dataserver`, `http_response`, `link_message`, `run_time_permissions` — always validate payloads and request IDs.

**Guidelines**

* Keep event handlers short; offload to small helpers.
* Never assume ordering across different events; persist minimal shared state in globals.
* Guard against reentrancy (e.g., ignore stale responses using request IDs).

## 4) States (finite‑state organization)

* Use states to separate **modes** (e.g., idle vs active). Each state has its own event set.
* Transition with `state newState;` only after you've cleaned up listeners, timers, particles, etc.
* Use `state_entry` to (re)initialize **only** what the new state needs.
* Data must be in **globals** (or persisted externally); locals do not survive state changes.
* Avoid ping‑ponging states for simple flags — a single state with booleans is often cheaper.

## 5) Performance & Memory

* Minimize allocations in hot paths (lists, JSON strings). Reuse buffers.
* Avoid large lists and repeated `llList2List/llDeleteSubList` chains in loops.
* Prefer integer arithmetic; trim floats early.
* Cache values you read often (owner key, names) and **invalidate** on `changed` when needed.
* Keep timer intervals sensible; **don't use sub‑second timers** unless absolutely necessary.
* Avoid frequent `llSleep`; it stalls the event queue.
* Use `DEBUG` flags and lightweight `logd()` helpers; strip or gate noisy logs.

## 6) Dialogs & Listeners (UI)

* **Layout indexing:** `llDialog` lays out buttons **bottom‑left → top‑right**. Plan button array order and any "reserved index" (e.g., Relax at index 3) with this in mind.
* **Padding:** Not required for functional dialogs. Use padding to multiples of 3 only when it improves layout cosmetics. Do not pad in modal dialogs (e.g., single **OK**) or confirmation dialogs (e.g., **OK/Cancel**), where fewer buttons are expected.
* **Command vs. Label:** Prefer routing dialog responses by a **command/label pair** instead of only by label. This lets you change button labels (for localization or cosmetics) without breaking the underlying command logic.
* One dialog = one private negative channel; use a **random negative int** per session.
* **Scope listens**: `llListen(chan, "", avatar, "")`. Remove with `llListenRemove` promptly.
* Don't open duplicate dialogs; track current session (avatar, channel, listen id).
* Provide a **Back** path; on exit, **return control** to the caller if you have one.

## 7) Communication & Security

* Prefer **link messages** (`llMessageLinked`) for intra‑object comms.
* For chat: use **negative channels**; never listen on public chat (`0`) for control flows.
* Validate every inbound payload:

  * Check a `type` field and only accept known values.
  * Verify expected sender or session/req IDs.
  * Reject or ignore malformed JSON.
* Throttle potentially spammy actions; be mindful of rate limits.

## 8) Permissions & Animations

* Request only what you need via `llRequestPermissions` and handle `run_time_permissions`.
* Re‑request on ownership/attach changes; release gracefully when detached.
* Don't call animation or control APIs until permissions are granted.
* Provide a **Relax/Stop** action to clear animations or controls.

## 9) Data Handling (JSON, lists, strings)

* Use `llList2Json/llJsonSetValue/llJsonGetValue` for structured data.
* Guard with a helper `json_has(j, path)` before reading.
* Keep JSON paths shallow to avoid stack/heap pressure.
* Be explicit converting strings ↔ ints/floats; handle `JSON_INVALID`.
* When size matters, use compact keys and flat arrays (stride lists) to lower overhead.

## 10) Error Handling & Logging

* Add `DEBUG` boolean + `logd()`; keep production logs minimal.
* Fail **closed** on unknown messages or permission denials (do nothing, or show polite error).
* Use owner‑visible notices sparingly; prefer IMs or controlled chat when helpful.

## 11) Initialization & Lifecycle

* On `state_entry`/`on_rez`: reset session vars, clear listeners, stop particles, cancel timers.
* On `changed( CHANGED_OWNER | CHANGED_REGION )`: re‑init ownership, names, permissions.
* On soft resets, re‑register with any local controller and re‑establish heartbeats.

## 12) Asset & Inventory Access

* Inventory lookups (`llGetInventoryNumber`, etc.) can be slow; cache counts and names.
* Always check asset presence before use; handle empty inventories gracefully.
* When giving items (`llGiveInventory`), confirm existence; handle failures politely.

## 13) UI/UX Conventions (llDialog specifics)

* Buttons are laid out **bottom‑left → top‑right**.
* Reserve a label (e.g., `"Back"`) consistently; ensure it exists on sub‑pages.
* When paginating, use `<<` and `>>` and keep page size consistent.
* For blank fillers, use exactly a single space character `" "` (not tildes or empty strings).

## 14) Safety Patterns (must‑do)

* Always **remove listeners** when a dialog closes or the user navigates away.
* Treat **all inbound data as untrusted**; validate types and ranges.
* Use **private negative channels**; never expose control flows on public chat.
* Provide a **soft‑reset** path (cleanup + re‑register) to recover from silence.
* Keep a **heartbeat** (ping/pong) only when truly needed; don't repurpose heartbeats for unrelated syncs.

## 15) Common Gotchas (quick checklist)

* ❌ Ternary (`?:`), `switch`, `break`/`continue`, try–catch, default params.
* ❌ Duplicate dialogs / orphaned listeners.
* ❌ Public chat listeners or unscoped `llListen`.
* ❌ Timers left running across state transitions.
* ❌ Overuse of `llSleep` and sub‑second timers.
* ❌ Large JSON objects built per click without reuse.
* ❌ **CRITICAL: Use of LSL reserved terms as variable names** — See Section 15.1 for complete list.

### 15.1) LSL Reserved Terms — NEVER Use as Variable Names

**⚠️ CRITICAL WARNING:** Using any LSL reserved term as a variable, function, parameter, label, or state name will cause compilation failure or undefined behavior. This is a hard language constraint.

#### Flow Control Keywords (NEVER use as variable names)
* `do`, `else`, `for`, `if`, `jump`, `return`, `while`

#### Data Type Keywords (NEVER use as variable names)
* `float`, `integer`, `key`, `list`, `quaternion`, `rotation`, `string`, `vector`

#### State Keywords (NEVER use as variable names)
* `default`, `state`

#### Event Names (NEVER use as variable names)
All 44 LSL event handler names are reserved:
* `at_rot_target`, `at_target`, `attach`, `changed`, `collision`, `collision_end`, `collision_start`
* `control`, `dataserver`, `email`, `experience_permissions`, `experience_permissions_denied`
* `final_damage`, `game_control`, `http_request`, `http_response`
* `land_collision`, `land_collision_end`, `land_collision_start`, `link_message`, `linkset_data`, `listen`
* `money`, `moving_end`, `moving_start`, `no_sensor`, `not_at_rot_target`, `not_at_target`
* `object_rez`, `on_damage`, `on_death`, `on_rez`, `path_update`, `remote_data`
* `run_time_permissions`, `sensor`, `state_entry`, `state_exit`
* `timer`, `touch`, `touch_end`, `touch_start`, `transaction_result`

#### Common Built-in Constants (NEVER use as variable names)
LSL has 690+ built-in constants. The most common ones include:
* Boolean: `TRUE`, `FALSE`
* Keys: `NULL_KEY`
* Vectors: `ZERO_VECTOR`
* Rotations: `ZERO_ROTATION`
* Math: `PI`, `TWO_PI`, `PI_BY_TWO`
* Other: `EOF`
* Plus hundreds of constant flags (PRIM_*, CHANGED_*, PERMISSION_*, STATUS_*, etc.)

#### Function Prefix Restriction
* All function names starting with `ll` (lowercase L's) are reserved for "Linden Library" built-in functions
* Never create user-defined functions starting with `ll`

#### Safe Alternatives
When you need a variable name related to a reserved term, use these patterns:
* ✅ `reg_delta` instead of ❌ `changed`
* ✅ `avatar_key` instead of ❌ `key`
* ✅ `current_state` instead of ❌ `state`
* ✅ `is_attached` instead of ❌ `attach`
* ✅ `obj_rotation` instead of ❌ `rotation`
* ✅ `tick_timer` instead of ❌ `timer`

#### Enforcement Rule
**Before declaring any variable, function, parameter, label, or state name:**
1. Check it against this list
2. If in doubt, prefix it (e.g., `my_`, `local_`, or use a more descriptive name)
3. NEVER assume a term is safe — verify it's not reserved

## 16) Minimal Reusable Snippets

**Debug logger**

```lsl
integer DEBUG = FALSE;
integer logd(string s) {
    if (DEBUG) llOwnerSay(s);
    return 0;
}
```

**JSON guard**

```lsl
integer json_has(string j, list path) {
    if (llJsonGetValue(j, path) == JSON_INVALID) return FALSE;
    return TRUE;
}
```

**Dialog helper (pads to multiples of 3)**

```lsl
integer dialog_to(key who, string body, list buttons, integer chan) {
    integer n = llGetListLength(buttons);
    while ((n % 3) != 0) {
        buttons += " ";
        n += 1;
    }
    llDialog(who, body, buttons, chan);
    return 0;
}
```

**Listener hygiene**

```lsl
integer gListen = 0;
integer reset_listen() {
    if (gListen) llListenRemove(gListen);
    gListen = 0;
    return 0;
}
```

---

## Additional Resources

- **Official LSL Wiki:** https://wiki.secondlife.com/wiki/LSL_Portal
- **LSL Style Guide:** https://wiki.secondlife.com/wiki/LSL_Style_Guide
- **Common LSL Mistakes:** https://wiki.secondlife.com/wiki/Common_Script_Mistakes
- **Project Style Guide:** See `agents-style.md` in this repository

---

**Document Version:** 2.0
**Last Updated:** 2025-11-03
**Maintained by:** DS Collar Modular Project
