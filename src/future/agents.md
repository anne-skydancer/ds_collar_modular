# AGENTS.md — LSL Coding Requirements & Best Practices for LSL

> A practical checklist for agents and assistants that generate or review **Linden Scripting Language (LSL)** code. This is **generic** guidance (not project‑specific) and assumes standard Second Life capabilities.

---

## 1) Scope & Goals

* Produce **compile‑ready** LSL (no unsupported syntax or APIs).
* Prefer **robust, secure, and performant** patterns over “clever” code.
* Keep scripts **event‑driven** and **single‑thread friendly**; avoid blocking.

## 2) Hard Language Constraints (must‑remember)

* **No ternary operator** (`cond ? a : b`) — use explicit `if/else` chains.
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
* Transition with `state newState;` only after you’ve cleaned up listeners, timers, particles, etc.
* Use `state_entry` to (re)initialize **only** what the new state needs.
* Data must be in **globals** (or persisted externally); locals do not survive state changes.
* Avoid ping‑ponging states for simple flags — a single state with booleans is often cheaper.

## 5) Performance & Memory

* Minimize allocations in hot paths (lists, JSON strings). Reuse buffers.
* Avoid large lists and repeated `llList2List/llDeleteSubList` chains in loops.
* Prefer integer arithmetic; trim floats early.
* Cache values you read often (owner key, names) and **invalidate** on `changed` when needed.
* Keep timer intervals sensible; **don’t use sub‑second timers** unless absolutely necessary.
* Avoid frequent `llSleep`; it stalls the event queue.
* Use `DEBUG` flags and lightweight `logd()` helpers; strip or gate noisy logs.

## 6) Dialogs & Listeners (UI)

* **Layout indexing:** `llDialog` lays out buttons **bottom‑left → top‑right**. Plan button array order and any “reserved index” (e.g., Relax at index 3) with this in mind.
* **Padding:** Not required for functional dialogs. Use padding to multiples of 3 only when it improves layout cosmetics. Do not pad in modal dialogs (e.g., single **OK**) or confirmation dialogs (e.g., **OK/Cancel**), where fewer buttons are expected.
* **Command vs. Label:** Prefer routing dialog responses by a **command/label pair** instead of only by label. This lets you change button labels (for localization or cosmetics) without breaking the underlying command logic.
* One dialog = one private negative channel; use a **random negative int** per session.
* **Scope listens**: `llListen(chan, "", avatar, "")`. Remove with `llListenRemove` promptly.
* Don’t open duplicate dialogs; track current session (avatar, channel, listen id).
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
* Don’t call animation or control APIs until permissions are granted.
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

## 13) Naming, Style & Structure

* **No chained declarations** in output; declare one symbol per line for clarity.
* Use consistent casing (e.g., UPPER\_SNAKE for constants, PascalCase for globals, lower\_snake for locals).
* Group **constants, link numbers, and strings** at the top with comments.
* Write **small, single‑purpose** functions; keep event bodies tiny.
* Prefer explicit returns and early guards over deep nesting.

## 14) UI/UX Conventions (llDialog specifics)

* Buttons are laid out **bottom‑left → top‑right**.
* Reserve a label (e.g., `"Back"`) consistently; ensure it exists on sub‑pages.
* When paginating, use `<<` and `>>` and keep page size consistent.
* For blank fillers, use exactly a single space character `" "` (not tildes or empty strings).

## 15) Testing & Diagnostics

* Provide a **debug mode** that prints key transitions and payloads.
* Use a **test harness** object or script to simulate common events (touch, auth, messages).
* Log request IDs for async flows (dataserver, http, link\_message) to correlate responses.

## 16) Safety Patterns (must‑do)

* Always **remove listeners** when a dialog closes or the user navigates away.
* Treat **all inbound data as untrusted**; validate types and ranges.
* Use **private negative channels**; never expose control flows on public chat.
* Provide a **soft‑reset** path (cleanup + re‑register) to recover from silence.
* Keep a **heartbeat** (ping/pong) only when truly needed; don’t repurpose heartbeats for unrelated syncs.

## 17) Common Gotchas (quick checklist)

* ❌ Ternary (`?:`), `switch`, `break`/`continue`, try–catch, default params.
* ❌ Duplicate dialogs / orphaned listeners.
* ❌ Public chat listeners or unscoped `llListen`.
* ❌ Timers left running across state transitions.
* ❌ Overuse of `llSleep` and sub‑second timers.
* ❌ Large JSON objects built per click without reuse.
* ❌ Use of **reserved expressions or keywords as variable names** (e.g., `state`, `vector`, `default`).

## 18) Minimal Reusable Snippets) Minimal Reusable Snippets

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

## 19) Review Checklist (for agents)

Use this end‑of‑pass checklist to confirm a script is **release‑ready**. Each bullet is a concrete requirement — do not ship until all apply.

### 19.1 Syntax & Language Rules

* Must compile under LSL: no ternary (`?:`), no `switch`, no `break`/`continue`, no chained declarations, no default params/overloads.
* Only supported LSL APIs are called (verify against the LSL reference).
* One symbol per line; all variables explicitly typed.

### 19.2 Events & States

* Event handlers are short (≈25 lines or fewer) and guarded against invalid input.
* Persistent data lives in globals; no reliance on locals across state changes.
* Every state transition **cleans up**: listeners removed, timers cancelled, particles/controls/animations stopped.
* `on_rez`, `attach`, and `changed` handle resets and ownership/region transitions safely.

### 19.3 UI / Dialogs & Listeners

* ≤ 12 dialog buttons; padded to a multiple of 3 with a single space (`" "`).
* **Back** button present where navigation requires it; pagination uses `<<` and `>>` consistently.
* If a special button (e.g., **Relax**) is reserved, its index is enforced and documented.
* Dialog channel is a **random negative integer** per session; listeners are scoped to `(avatar, channel)` and removed on close.

### 19.4 Permissions & Animations

* Requests only the permissions it needs; no action taken before `run_time_permissions` grants them.
* Denial paths are handled (user refusal does not break the script).
* Provides a **Relax/Stop** action to clear controls/animations.

### 19.5 Communication & Security

* Intra‑object comms use link messages with JSON payloads that include a `type` field.
* All inbound data is validated (expected sender, request/session IDs, schema).
* No control flow on public chat channel `0`; private **negative** channels only.
* Output is throttled where appropriate to avoid spam and rate limits.

### 19.6 Performance & Memory (Stack‑Heap Safety)

* No `llSleep` in hot paths; timers use sane intervals (≥ 1s unless justified).
* Buffers are reused; avoid repeated list slicing (`llList2List`, `llDeleteSubList`) in loops.
* Strings are built with a **join‑once** pattern; JSON kept shallow/compact.
* Inventory counts, page indices, and heavy computations are cached and invalidated when needed.
* Large temporaries are nulled after use; UI pages precomputed where possible.
* `llGetFreeMemory()` checked before heavy operations; script degrades gracefully if low.

### 19.7 Logging & Debug

* `DEBUG` flag gates verbose logs; release builds default `DEBUG = FALSE`.
* Log tags are consistent (e.g., `[MODULE]`); async flows include IDs for correlation.
* No owner‑spam during normal operation.

### 19.8 Documentation & Comments

* File header includes: ROLE, ABI & link numbers, permissions, events used, resource notes, constraints, known issues/TODOs.
* Non‑trivial functions document purpose, inputs/outputs, side effects, assumptions, and failure modes.
* Inline comments explain **why** (design/rationale), and mark `TODO:`, `FIXME:`, `HACK:` with dates.

### 19.9 Lifecycle & Safety

* Soft‑reset path exists and performs cleanup + (re)registration as applicable.
* Heartbeats (if any) are used only for liveness, **not** for unrelated syncing.
* Ownership/region changes trigger safe re‑init and permission re‑requests as needed.
* Script fails **closed** on bad inputs (ignores/denies) without crashing.

### 19.10 Final Gate

* Trace a full happy path: touch → auth → UI open → click → action → Back → main. No leaks, no duplicates.
* No orphaned listeners; memory before vs. after basic interaction remains stable.
* Free memory after init meets project policy (e.g., > 4 KiB) or documented if tighter.
* Version string present; `DEBUG` default confirmed for release.

---

### Appendix A — Recommended File Header Template

```lsl
/* =============================================================
   SCRIPT: <name>.lsl
   ROLE  : <what this script does>
   NOTES : <quirks, ABI versions, permissions, UI rules>
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[<TAG>] " + s); return 0; }
```

### Appendix B — Safe Defaults

* Use **negative, randomized dialog channels** per session.
* Keep a **single, centralized** place for link numbers and message type strings.
* Prefer **explicit** `if/else` over clever one‑liners.
* Return early on invalid input.

---

## 21) Memory Efficiency & Stack‑Heap Safety

**Goal:** Avoid Stack‑Heap Collision by reducing transient allocations and overall footprint.

**General Principles:**

* **Reuse buffers**: keep reusable strings/lists in globals; clear with `""` or `[]` after use to free memory.
* **Prefer lists → join once**: build strings by accumulating pieces in a list, then `llDumpList2String` once.
* **Keep JSON compact**: shallow paths, short keys, avoid rebuilding whole objects inside loops.
* **Favor stride lists** over deeply nested JSON for hot paths.
* **Minimize copies**: avoid `llList2List`/`llDeleteSubList` in tight loops; operate by index math when possible.
* **Cache counts and indexes** (e.g., inventory size, page offsets); recompute only when invalidated.
* **Gate debug output**: excessive logging allocates strings.

**Dialog/UI:**

* Precompute/persist button pages; do not rebuild on every click.
* Pad once to multiples of 3; avoid per‑event padding work.

**Strings:**

* Avoid repeated concatenation in loops (`s += piece` inside a loop); collect pieces and join.
* Trim floats/strings early; store integers where possible.

**JSON Tips:**

* Use `json_has(j, path)` before `llJsonGetValue` to avoid handling `JSON_INVALID` branches repeatedly.
* For frequent updates, keep a **flat array** payload and only replace changed indices.

**Listeners & Timers:**

* Keep **one active listener** per session; remove as soon as it’s not needed.
* Use sensible timer intervals; avoid sub‑second timers.

**Data Lifetime:**

* Null out large temporaries after sending (`big = []` / `big = ""`).
* Prefer small enums (integers) to string state names in hot paths.

**Measuring & Guarding:**

* Use `llGetFreeMemory()` to check available bytes before heavy operations.
* Add guardrails (e.g., skip building a giant menu if memory falls below a threshold) and degrade gracefully.

**Patterns that risk SHC:**

* Building large JSON strings within nested loops.
* Re‑creating button arrays and dialog strings every click.
* Deeply nested `llJsonSetValue`/`llJsonGetValue` in hot paths.

**Safe Snippets:**

*Memory guard + degrade:*

```lsl
integer mem_ok(integer need){
    return (llGetFreeMemory() > need);
}

integer safe_send_dialog(key av, string body, list btns, integer chan){
    // estimate: body + labels + overhead
    if (!mem_ok(2048)) return 0; // skip if tight
    integer n = llGetListLength(btns);
    while ((n % 3) != 0){ btns += " "; n += 1; }
    llDialog(av, body, btns, chan);
    return 1;
}
```

*Join once pattern:*

```lsl
list parts = [];
parts += ["Title: ", title];
parts += ["\nPage ", (string)page, "/", (string)pages];
string body = llDumpList2String(parts, ""); // one allocation
```

*Compact stride cache (example):*

```lsl
// stride: [id, label, min_acl]
list reg = [];
integer add_entry(string id, string label, integer acl){ reg += [id, label, acl]; return 0; }
```

---

## 22) Project‑Specific Rules — D/s Collar (Experimental / New‑UI ABI)

**This file is for the `experimental/` directory. Do not mix with Stable ABI.**

### 22.1 Canonical Lanes (Negative Link Channels)

* API hub: `-1000`
* UI Backend IN: `-1600`
* UI Frontend IN: `-1700`

### 22.2 Message Types

* FE → BE: `ui_touch`, `ui_click`
* BE → FE: `ui_render`, `ui_close`

All payloads include at minimum: `type`, and when async: `session` / `req_id`. Use compact, shallow JSON or **stride lists** for hot paths.

### 22.3 Responsibilities Split

**Frontend (FE):**

* Owns `touch_start`, `llDialog`, `listen`.
* Random negative channel per session; listener scoped to `(avatar, channel)` and removed on close.
* Sends **command + label** for routing clicks; labels are cosmetic.

**Backend (BE):**

* Owns ACL resolution, menu schema, paging, and actions.
* Emits `ui_render` to FE; **never** calls `llDialog` directly.
* No Stable numbers (`K_PLUGIN_START`, etc.).

### 22.4 Settings & Heartbeats

* **Event‑driven settings** (`settings_sync`, explicit queries). No periodic 30s loops.
* Heartbeat (if any) is **liveness only**; silence → re‑announce with minimal footprint.

### 22.5 UI Rules

* ≤ 12 buttons; **padding only when beneficial** (never for 1 or 2 button dialogs).
* Layout bottom‑left → top‑right; document any reserved positions (e.g., Relax at index 3).
* Pagination uses `<<` / `>>` with consistent page size.

### 22.6 Final Experimental Checklist

* Uses only **Experimental** lanes (`-1000`, `-1600`, `-1700`).
* Clear FE/BE split; no kernel plugin numbers.
* Command+label routing; listener cleanup verified.
* No settings sync on timers; no public chat control.

---

## 23) Project‑Specific Append — Collar (Public Chat + Dialog UI)

> This section **appends** project rules without altering the generic guidance above. Where conflicts exist (e.g., public chat listeners), the rules below define the **explicit exception** for this collar.

### 23.1 ACL (Authoritative)

* **Level 0 — Toggleable lockout:** Deny **UI and public‑chat command** access. The wearer may be assigned to level 0 as well, but this must be gated to allow only wearers with a primary controller to be assigned to ACL level 0.
* **Level 1 — Public/visitors:** Conditional, toggleable, **non‑privileged** UI and public‑chat command access for non-blacklisted avatars **not** the wearer, primary, or secondaries.
* **Level 2 — Wearer (owned):** **Basic, unprivileged** UI and public‑chat command access for **wearer avatars with a primary controller set**.
* **Level 3 — Secondary controllers:** **Non‑critical, privileged** UI and command access for controllers designated as **secondary** (maximum **4**, stored as UUIDs; UI shows resolved display names).
* **Level 4 — Primary controller:** **Critical, privileged** UI and command access for the **primary controller** (single UUID; UI shows resolved display name). **Also applies to the wearer when no primary controller is designated.**

**Rules:** Blacklist overrides all. ACL checks apply identically to **dialogs** and **public chat commands.** UI and chat command access for ACL levels 3 and 4 must be granted regardless of whether ACL level 1 has been toggled.**.

### 23.2 Public Chat Commands (Required)

* **Channel:** Public chat (`0`).
* **Format:** `<prefix><command> [args…]` (e.g., `!leash clip <uuid>`, `!lock on`, `!anim play "Kneel"`).
* **Prefix:** Configurable in settings (default suggested: `!`).
* **Parsing:** Case‑insensitive commands; arguments are case‑preserving. Support quoted strings.
* **Security:**

  * Parse **only** lines beginning with the prefix.
  * Resolve issuer → ACL; **reject** if below the feature’s `min_acl`.
  * Never echo sensitive data to public chat; concise success/failure only. Rate‑limit outputs.
* **Examples:**

  * `!status`
  * `!leash clip <uuid>` / `!leash unclip`
  * `!leash set length <meters>`
  * `!anim play "Kneel"` / `!anim stop`
  * `!lock on` / `!lock off`

### 23.3 Dialog UI Rules (Confirmed)

* **Standard dialogs:** `llDialog` **paginated**, multi‑user safe, **bottom‑left → top‑right** layout.
* **Padding:** **No padding** unless it improves cosmetics/readability.
* **Modal dialogs:** **Single‑button** layout.
* **Confirmation dialogs:** Two buttons: **OK** / **Cancel**.
* **Navigation:** Reserve `<<`, `Back`, `>>` as needed; document any reserved feature positions (e.g., **Relax** index).

### 23.4 Exception to Generic Rule 7 (Public Chat)

* The base guideline “never listen on public chat (`0`) for control flows” is **overridden** for this project **only** for **prefixed** commands. The listener must:

  * Activate a lightweight parser **only** for messages starting with the prefix.
  * Perform **ACL** and **blacklist** checks before any action.
  * Throttle responses and avoid verbose logs to public chat.

### 23.5 Release Checklist (Collar‑specific)

* ACL levels enforced across **both** dialog and public chat flows.
* Public chat **prefix** is configurable and documented; parser ignores non‑prefixed lines.
* Secondary controllers limited to **4**; names resolved for UI.
* Wearer treated as **Level 4** when no primary controller is set.
* Dialogs adhere to modal/confirmation layout rules; no unnecessary padding.
* Public chat outputs are minimal and rate‑limited; no sensitive state leaked.
* Listeners (dialog and public chat) are cleaned up or remain lightweight and guarded.

### 23.6 Additional security considerations:

* Components that deal with the internal workings of the system (auth, settings, etc.) must be treated as modules that are a part of the kernel itself and must never register into the kernel as plugins. 
* Components that involve user interaction register with the kernel as plugins.
