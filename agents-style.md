# AGENTS-STYLE.MD — LSL Coding Style, Documentation & Best Practices

> Style guide and documentation standards for LSL code. This complements `agents.md` (technical requirements). For syntax and language constraints, see `agents.md`.

---

## 1) Naming, Style & Structure

* **No chained declarations** in output; declare one symbol per line for clarity.
* Use consistent casing:
  * **UPPER_SNAKE** for constants
  * **PascalCase** for global variables
  * **snake_case** for local variables
* Group **constants, link numbers, and strings** at the top with comments.
* Write **small, single‑purpose** functions; keep event bodies tiny.
* Prefer explicit returns and early guards over deep nesting.
* **No UTF-8 characters in code** - Use only ASCII characters (0-127) for maximum readability and compatibility. This includes:
  * Variable names, function names, comments
  * String literals (user-facing text should use escape sequences or be loaded from notecards)
  * All code structure and whitespace

**Example:**
```lsl
// Constants
integer DEBUG = FALSE;
integer PRODUCTION = TRUE;
integer MAX_RETRIES = 3;

// Global state
string SessionId = "";
key CurrentUser = NULL_KEY;
integer IsActive = FALSE;

// Function with early guard
integer validate_input(string msg) {
    if (msg == "") return FALSE;
    if (llStringLength(msg) > 1024) return FALSE;
    return TRUE;
}
```

---

## 2) Commenting & Documentation Guidelines

**Purpose:** Make intent, risks, and rationale clear so maintainers can safely modify code without re‑deriving design choices.

### 2.1) File Header Template

**MANDATORY header format for ALL scripts:**

ALL scripts (modules, plugins, kmods, HUDs, standalone scripts) MUST use this structure with the appropriate TYPE PREFIX for the script category:

```lsl
/*--------------------
MODULE: ds_collar_kernel.lsl
VERSION: 1.00
REVISION: 34
PURPOSE: Plugin registry, lifecycle management, heartbeat monitoring
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Event-driven plugin registration queue replaces broadcast storms
- Adaptive timer shifts between batch processing and heartbeat modes
- Inventory discovery detects new or updated plugin scripts automatically
- Authorized reset handling protects against unauthorized soft resets
- Deferred plugin list responses avoid race conditions during registration
--------------------*/

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;
```

**For plugins, use `PLUGIN:` prefix:**

```lsl
/*--------------------
PLUGIN: ds_collar_plugin_bell.lsl
VERSION: 1.00
REVISION: 10
PURPOSE: Bell visibility and jingling control for the collar
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Add independent toggles for bell visibility and sound playback
- Enable jingle loop while wearer moves with adjustable volume levels
--------------------*/

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;
```

**For standalone scripts (HUDs, external tools), use descriptive prefix:**

```lsl
/*--------------------
CONTROL HUD: ds_collar_control_hud.lsl
VERSION: 1.00
REVISION: 5
PURPOSE: Auto-detect nearby collars and connect automatically
ARCHITECTURE: RLV relay-style broadcast and listen workflow
CHANGES:
- Auto-scan on attach with timeout
- Auto-connect to single collar or show selection dialog
- ACL level verification before menu display
--------------------*/

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;
```

### 2.2) File Header Components

**TYPE PREFIX:** Use appropriate prefix for script type:
- `MODULE:` for kernel modules (ds_collar_kmod_*.lsl)
- `PLUGIN:` for plugins (ds_collar_plugin_*.lsl)
- `KERNEL:` or `MODULE:` for the main kernel (ds_collar_kernel.lsl)
- Descriptive name for standalone scripts (e.g., `CONTROL HUD:`, `LEASH HOLDER:`)

**VERSION:** Semantic version number (e.g., 1.00, 1.01, 2.00)

**REVISION:** Integer revision counter, increments with each change

**PURPOSE:** Brief description of what the script does (one or two lines maximum)

**ARCHITECTURE:** Brief note on the system architecture or design pattern used

**CHANGES:** Bulleted list of notable changes, improvements, or fixes
- Use present tense verbs (e.g., "Adds", "Fixes", "Improves")
- Focus on significant behavioral or architectural changes
- Keep bullets concise and descriptive
- 3-5 bullets recommended, more if needed for clarity

### 2.3) Section Headers

**MANDATORY section header format for ALL scripts:**

ALL scripts MUST use dashed borders for major code sections:

> **Header border style convention:**  
> - **File headers** (at the very top of the script) use compact dashed borders, e.g. `/*-------------------- ... --------------------*/`  
> - **Internal section headers** (for major code sections) use longer dashed borders with centered section names, e.g. `/* -------------------- SECTION NAME -------------------- */`  
>  
> This distinction helps visually separate the file-level metadata from internal code organization. Always follow these conventions for clarity.
```lsl
/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;

/* -------------------- CONSTANTS -------------------- */
float PING_INTERVAL_SEC = 5.0;
integer PING_TIMEOUT_SEC = 15;

/* -------------------- STATE -------------------- */
list PluginRegistry = [];
integer LastPingUnix = 0;

/* -------------------- HELPERS -------------------- */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[TAG] " + msg);
    return FALSE;
}
```

**Common section names:**
- `CONSOLIDATED ABI` - Message bus channel numbers
- `CONSTANTS` - Configuration constants and magic numbers
- `STATE` - Global state variables
- `HELPERS` - Utility functions
- `SETTINGS KEYS` - Persistent settings key strings
- `ACL CONSTANTS` - Access control level definitions
- `DIALOG SETTINGS` - UI configuration

### 2.4) Function Documentation

For each non‑trivial function include:

* **What it does / Why it exists** (primary intent, not line‑by‑line narration)
* **Inputs / Outputs** (types, units, ranges; `NULL_KEY` handling)
* **Side Effects** (listeners opened/removed, timers set, global mutations)
* **Assumptions / Invariants** (e.g., menu size ≤ 12, channel is negative)
* **Failure Modes** (e.g., permission not granted, JSON invalid)

**Example:**
```lsl
/* build_main_menu
 *
 * Constructs the root plugin menu with 6-9 buttons plus Back.
 *
 * Inputs:  acl_level - caller's access level (0-5)
 * Returns: list of button labels
 *
 * Side effects: None (pure function)
 *
 * Assumptions:
 *   - "Relax" is pinned to index 3 (bottom-left of row 2)
 *   - Padding no longer required; llDialog handles layout
 *
 * Failure: Returns empty list if acl_level invalid
 */
list build_main_menu(integer acl_level) {
    // implementation
}
```

### 2.5) Inline Comments (focus on reasoning)

* Prefer **why** over **what**; the code already says *what*.
* Mark **problem areas** (race windows, throttles, rate limits) with `NOTE:`.
* Mark **workarounds** for SL quirks (e.g., dataserver latency) with `WHY:`.
* Document **UI layout logic** (e.g., why Relax sits at index 3; button order rationale).
* Call out **magic numbers** and derive them briefly.
* Comment patches with a `//PATCH` comment including the reason for the patch.

**Examples:**
```lsl
// WHY: llDialog buttons display bottom-left to top-right, so we reverse
list ordered = reverse_for_display(buttons);

// NOTE: 60s silence window before defensive re-register
if (llGetUnixTime() - LastHeartbeat > 60) {
    register_self();
}

// PATCH: Added NULL_KEY check to prevent crash on detach (2025-11-03)
if (avatar == NULL_KEY) return;
```

### 2.6) Change Rationale Blocks

At major edits, add a short `/* WHY: ... DATE: YYYY‑MM‑DD */` block near the change.

**Example:**
```lsl
/* WHY: We pin page size to 8 because one slot is reserved for "Relax" and
   we want consistent pagination across all menus.
   DATE: 2025-09-23 */
integer PAGE_SIZE = 8;
```

### 2.7) Comment Tags

- `TODO:` for planned work
- `FIXME:` for known bugs
- `HACK:` for temporary compromises
- `PATCH:` for bug fixes with rationale

### 2.8) Comment Style

- Use `//` for short notes; `/* ... */` for multi‑line context
- Keep comments accurate; delete stale ones immediately
- Briefly comment each function for maintainability and readability
- Additionally, comment each script at the top with a brief description of its intended functionality

---

## 3) Memory Efficiency & Stack‑Heap Safety

**Goal:** Avoid Stack‑Heap Collision by reducing transient allocations and overall footprint.

### 3.1) General Principles

* **Reuse buffers**: keep reusable strings/lists in globals; clear with `""` or `[]` after use to free memory.
* **Prefer lists → join once**: build strings by accumulating pieces in a list, then `llDumpList2String` once.
* **Keep JSON compact**: shallow paths, short keys, avoid rebuilding whole objects inside loops.
* **Favor stride lists** over deeply nested JSON for hot paths.
* **Minimize copies**: avoid `llList2List`/`llDeleteSubList` in tight loops; operate by index math when possible.
* **Cache counts and indexes** (e.g., inventory size, page offsets); recompute only when invalidated.
* **Gate debug output**: excessive logging allocates strings.

### 3.2) Dialog/UI Patterns

* Precompute/persist button pages; do not rebuild on every click.
* **Padding is no longer required** - llDialog handles button layout automatically.

**Example:**
```lsl
// GOOD: Precompute pages in state_entry
list ButtonPages = []; // Global

integer build_pages() {
    // Build once, cache in ButtonPages
    ButtonPages = [];
    integer i;
    for (i = 0; i < total_items; i += 9) {
        list page = get_items_slice(i, 9);
        ButtonPages += [llList2Json(JSON_ARRAY, page)];
    }
    return 0;
}

// BAD: Rebuilding on every click
show_page(integer page_num) {
    list buttons = get_items_slice(page_num * 9, 9); // Allocates
    llDialog(user, text, buttons, chan);              // Allocates
}
```

### 3.3) String Building

* Avoid repeated concatenation in loops (`s += piece` inside a loop); collect pieces and join.
* Trim floats/strings early; store integers where possible.

**Example:**
```lsl
// BAD - repeated concatenation
string result = "";
integer i;
for (i = 0; i < 100; i++) {
    result += (string)i + " ";  // 100 allocations
}

// GOOD - join once
list parts = [];
integer i;
for (i = 0; i < 100; i++) {
    parts += (string)i;
}
string result = llDumpList2String(parts, " ");  // 1 allocation
```

### 3.4) JSON Tips

* Use `json_has(j, path)` before `llJsonGetValue` to avoid handling `JSON_INVALID` branches repeatedly.
* For frequent updates, keep a **flat array** payload and only replace changed indices.

### 3.5) Listeners & Timers

* Keep **one active listener** per session; remove as soon as it's not needed.
* Use sensible timer intervals; avoid sub‑second timers.

### 3.6) Data Lifetime

* Null out large temporaries after sending (`big = []` / `big = ""`).
* Prefer small enums (integers) to string state names in hot paths.

### 3.7) Measuring & Guarding

* Use `llGetFreeMemory()` to check available bytes before heavy operations.
* Add guardrails (e.g., skip building a giant menu if memory falls below a threshold) and degrade gracefully.

**Example:**
```lsl
integer mem_ok(integer need) {
    return (llGetFreeMemory() > need);
}

integer safe_send_dialog(key av, string body, list btns, integer chan) {
    // estimate: body + labels + overhead
    if (!mem_ok(2048)) return 0; // skip if tight
    integer n = llGetListLength(btns);
    while ((n % 3) != 0) {
        btns += " ";
        n += 1;
    }
    llDialog(av, body, btns, chan);
    return 1;
}
```

### 3.8) Patterns that Risk Stack-Heap Collision

* Building large JSON strings within nested loops.
* Re‑creating button arrays and dialog strings every click.
* Deeply nested `llJsonSetValue`/`llJsonGetValue` in hot paths.

---

## 4) Code Review Checklist

Use this end‑of‑pass checklist to confirm a script is **release‑ready**. Each bullet is a concrete requirement — do not ship until all apply.

### 4.1) Syntax & Language Rules

* Must compile under LSL: no ternary (`?:`), no `switch`, no `break`/`continue`, no chained declarations, no default params/overloads.
* Only supported LSL APIs are called (verify against the LSL reference).
* One symbol per line; all variables explicitly typed.
* **No UTF-8 characters** - Code uses only ASCII (0-127) for readability and compatibility.
* **lslint passes cleanly with zero errors**

### 4.2) Events & States

* Event handlers are short (≈25 lines or fewer) and guarded against invalid input.
* Persistent data lives in globals; no reliance on locals across state changes.
* Every state transition **cleans up**: listeners removed, timers cancelled, particles/controls/animations stopped.
* `on_rez`, `attach`, and `changed` handle resets and ownership/region transitions safely.

### 4.3) UI / Dialogs & Listeners

* ≤ 12 dialog buttons (padding no longer required - llDialog handles layout automatically).
* **Back** button present where navigation requires it; pagination uses `<<` and `>>` consistently.
* If a special button (e.g., **Relax**) is reserved, its index is enforced and documented.
* Dialog channel is a **random negative integer** per session; listeners are scoped to `(avatar, channel)` and removed on close.

### 4.4) Permissions & Animations

* Requests only the permissions it needs; no action taken before `run_time_permissions` grants them.
* Denial paths are handled (user refusal does not break the script).
* Provides a **Relax/Stop** action to clear controls/animations.

### 4.5) Communication & Security

* Intra‑object comms use link messages with JSON payloads that include a `type` field.
* All inbound data is validated (expected sender, request/session IDs, schema).
* No control flow on public chat channel `0`; private **negative** channels only.
* Output is throttled where appropriate to avoid spam and rate limits.

### 4.6) Performance & Memory (Stack‑Heap Safety)

* No `llSleep` in hot paths; timers use sane intervals (≥ 1s unless justified).
* Buffers are reused; avoid repeated list slicing (`llList2List`, `llDeleteSubList`) in loops.
* Strings are built with a **join‑once** pattern; JSON kept shallow/compact.
* Inventory counts, page indices, and heavy computations are cached and invalidated when needed.
* Large temporaries are nulled after use; UI pages precomputed where possible.
* `llGetFreeMemory()` checked before heavy operations; script degrades gracefully if low.

### 4.7) Logging & Debug

* `DEBUG` flag gates verbose logs; release builds default `DEBUG = FALSE`.
* Log tags are consistent (e.g., `[MODULE]`); async flows include IDs for correlation.
* No owner‑spam during normal operation.

### 4.8) Documentation & Comments

* File header includes: ROLE, ABI & link numbers, permissions, events used, resource notes, constraints, known issues/TODOs.
* Non‑trivial functions document purpose, inputs/outputs, side effects, assumptions, and failure modes.
* Inline comments explain **why** (design/rationale), and mark `TODO:`, `FIXME:`, `HACK:`, `PATCH:` with dates.

### 4.9) Lifecycle & Safety

* Soft‑reset path exists and performs cleanup + (re)registration as applicable.
* Heartbeats (if any) are used only for liveness, **not** for unrelated syncing.
* Ownership/region changes trigger safe re‑init and permission re‑requests as needed.
* Script fails **closed** on bad inputs (ignores/denies) without crashing.

### 4.10) Final Gate

* Trace a full happy path: touch → auth → UI open → click → action → Back → main. No leaks, no duplicates.
* No orphaned listeners; memory before vs. after basic interaction remains stable.
* Free memory after init meets project policy (e.g., > 4 KiB) or documented if tighter.
* Version string present; `DEBUG` default confirmed for release.

---

## 5) Safe Defaults

* Use **negative, randomized dialog channels** per session.
* Keep a **single, centralized** place for link numbers and message type strings.
* Prefer **explicit** `if/else` over clever one‑liners.
* Return early on invalid input.

**Example:**
```lsl
// Centralized constants
integer K_PLUGIN_START = 900;
integer K_PLUGIN_RETURN = 901;
string MSG_TYPE_REGISTER = "register";
string MSG_TYPE_AUTH_REQ = "auth_request";

// Random negative channel per session
integer DialogChannel = 0;

integer init_dialog_channel() {
    DialogChannel = -1000000 - (integer)llFrand(1000000);
    return 0;
}
```

---

## 6) Testing & Diagnostics

* Provide a **debug mode** that prints key transitions and payloads.
* Use a **test harness** object or script to simulate common events (touch, auth, messages).
* Log request IDs for async flows (dataserver, http, link\_message) to correlate responses.

**Example:**
```lsl
integer DEBUG = TRUE; // Enable during development

integer logd(string msg) {
    if (DEBUG) llOwnerSay("[BELL] " + msg);
    return 0;
}

link_message(integer sender, integer num, string str, key id) {
    logd("RX: num=" + (string)num + " str=" + str + " id=" + (string)id);

    if (num == K_PLUGIN_START) {
        string msg_type = llJsonGetValue(str, ["type"]);
        logd("  type=" + msg_type);
        // ... handle message
    }
}
```

---

## 7) Versioning Specification

**Official versioning scheme for DS Collar Modular project**

### 7.1) Version Format

```
[MAJOR].[MINOR]_[ENHANCEMENT]
```

**Components:**
- **MAJOR** - Major version number (integer)
- **MINOR** - Minor version number (integer, represents feature additions)
- **ENHANCEMENT** - Enhancement letter (a, b, c, etc., represents non-breaking improvements)

### 7.2) Version Change Rules

#### Security Fixes, Patches, and Hotfixes → **NO VERSION CHANGE**

**Definition:**
- Security vulnerability fixes
- Bug fixes that restore intended behavior
- Hotfixes for critical issues
- Performance optimizations that don't change behavior
- Code refactoring without functionality changes

**Versioning:**
- Version number **remains unchanged**
- Update header notes to document the fix

#### Enhancements → **MINOR INCREMENT** (underscore notation)

**Definition:**
- Quality-of-life improvements
- UI/UX refinements
- Behavior tweaks that improve user experience
- Non-breaking changes to existing features
- Optimizations that visibly improve performance
- Additional options/settings for existing features

**Versioning:**
- Append `_a` to current version
- Subsequent enhancements increment the letter: `_b`, `_c`, etc.

**Examples:** `1.0` → `1.0_a` → `1.0_b`

#### Feature Additions → **DOT INCREMENT** (minor version)

**Definition:**
- New features/commands
- New menu sections
- New plugins
- New kernel modules
- Integration with new external systems
- Breaking changes to existing features (with migration path)

**Versioning:**
- Increment MINOR version: `1.0` → `1.1` → `1.2`
- Reset enhancement letter (remove `_x` suffix)

#### Major Overhauls → **MAJOR VERSION CHANGE**

**Definition:**
- Complete architectural redesign
- Breaking API/ABI changes
- Migration from old system to new system
- Fundamental changes to how the system works

**Versioning:**
- Increment MAJOR version: `1.x` → `2.0`
- Reset MINOR to `0`
- Remove enhancement letter

### 7.3) Header Format with Version

```lsl
/* =============================================================================
   [TYPE]: [filename].lsl (v[VERSION] - [DESCRIPTION])

   [Additional header content...]
   ============================================================================= */
```

**Examples:**
```lsl
/* MODULE: ds_collar_kernel.lsl (v1.0 - Consolidated ABI) */
/* PLUGIN: ds_collar_plugin_bell.lsl (v1.0_a - Volume Control) */
/* PLUGIN: ds_collar_plugin_trustees.lsl (v1.3 - New Feature) */
```

---

## Additional Resources

- **Official LSL Wiki:** https://wiki.secondlife.com/wiki/LSL_Portal
- **LSL Style Guide:** https://wiki.secondlife.com/wiki/LSL_Style_Guide
- **Common LSL Mistakes:** https://wiki.secondlife.com/wiki/Common_Script_Mistakes
- **Technical Requirements:** See `agents.md` in this repository

---

**Document Version:** 2.1
**Last Updated:** 2025-11-11
**Maintained by:** DS Collar Modular Project
