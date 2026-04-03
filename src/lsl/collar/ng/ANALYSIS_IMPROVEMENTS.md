# Proposed Improvements - Prioritized

> **NOTE (2026-04-02):** See staleness disclaimer in [ANALYSIS_OVERVIEW.md](./ANALYSIS_OVERVIEW.md). IMP-3 reference to `kmod_auth.lsl:166-177` is stale (that code was in the removed plugin ACL registry). IMP-6 (`enforce_role_exclusivity`) line numbers may have shifted. The "30 scripts" count in IMP-1 is now 26.

**Principle:** All improvements preserve existing functionality and function signatures. Changes are categorized by impact and effort.

---

## Priority 1: High Impact, Low Effort

### IMP-1: Eliminate Double JSON Reads (All Scripts)
**Impact:** ~2-3ms saved per message handler invocation
**Effort:** Search-and-replace pattern
**Risk:** None

Replace the `json_has()` + `llJsonGetValue()` double-read pattern:

```lsl
// BEFORE (4-6ms):
if (json_has(msg, ["type"])) {
    string t = llJsonGetValue(msg, ["type"]);
}

// AFTER (2-3ms):
string t = llJsonGetValue(msg, ["type"]);
if (t != JSON_INVALID) { ... }
```

**Affected scripts:** All 26. Highest-traffic paths:
- `kernel.lsl` link_message handler (~every 5s per plugin)
- `kmod_auth.lsl` ACL queries
- `kmod_ui.lsl` button clicks and session management
- Every plugin's link_message handler

### IMP-2: Replace count_scripts() with Direct Call (kernel.lsl)
**Impact:** Eliminates unnecessary loop
**Effort:** 1 line change
**Risk:** None

```lsl
// BEFORE:
integer count_scripts() {
    integer count = 0;
    integer i;
    integer inv_count = llGetInventoryNumber(INVENTORY_SCRIPT);
    for (i = 0; i < inv_count; i = i + 1) {
        count = count + 1;
    }
    return count;
}

// AFTER:
integer count_scripts() {
    return llGetInventoryNumber(INVENTORY_SCRIPT);
}
```

### IMP-3: Replace Manual JSON Array Building with llDumpList2String (kernel.lsl, kmod_auth.lsl)
**Impact:** Fewer temporary strings, less heap fragmentation
**Effort:** ~5 lines changed per instance
**Risk:** None

```lsl
// BEFORE (kernel.lsl:445-457):
string plugins_array = "[";
integer j;
for (j = 0; j < llGetListLength(plugins); j = j + 1) {
    if (j > 0) plugins_array += ",";
    plugins_array += llList2String(plugins, j);
}
plugins_array += "]";

// AFTER:
string plugins_array = "[" + llDumpList2String(plugins, ",") + "]";
```

~~Apply same pattern in `kmod_auth.lsl:166-177`.~~ (Removed in v1.1 — was in dead plugin ACL registry code.)

### IMP-4: Remove Unused function_name Parameter (6 scripts)
**Impact:** ~48 bytes saved across scripts
**Effort:** Trivial
**Risk:** None (parameter is never used)

Remove `string function_name` parameter from `validate_required_fields()` in:
- kernel.lsl
- kmod_settings.lsl
- kmod_ui.lsl
- kmod_dialogs.lsl
- kmod_remote.lsl
- (any other script with this function)

Update all call sites to remove the third argument.

---

## Priority 2: Medium Impact, Medium Effort

### IMP-5: Optimize list_remove_all() (kmod_settings.lsl)
**Impact:** O(n) instead of O(n^2) for list element removal
**Effort:** Replace function body
**Risk:** Low - same behavior, better algorithm

```lsl
// BEFORE (O(n^2) - repeated llDeleteSubList copies entire list):
list list_remove_all(list source_list, string s) {
    integer idx = llListFindList(source_list, [s]);
    while (idx != -1) {
        source_list = llDeleteSubList(source_list, idx, idx);
        idx = llListFindList(source_list, [s]);
    }
    return source_list;
}

// AFTER (O(n) - single pass, builds new list):
list list_remove_all(list source_list, string s) {
    list result = [];
    integer i = 0;
    integer len = llGetListLength(source_list);
    while (i < len) {
        if (llList2String(source_list, i) != s) {
            result += [llList2String(source_list, i)];
        }
        i += 1;
    }
    return result;
}
```

### IMP-6: Optimize enforce_role_exclusivity() (kmod_auth.lsl)
**Impact:** Fewer list copies during role changes
**Effort:** Refactor function
**Risk:** Low - same behavior

Current pattern does repeated `llListFindList` + `llDeleteSubList` which copies the list on each delete. For lists with multiple matches, this is O(n*m). Use the build-new-list pattern instead.

### IMP-7: Add TextBox Injection Prevention (kmod_dialogs.lsl)
**Impact:** Prevents dialog-to-textbox hijacking
**Effort:** Add 3-line sanitization before llDialog()
**Risk:** None

```lsl
// Add before llDialog() call in handle_dialog_open():
integer b = 0;
while (b < llGetListLength(buttons)) {
    string label = llList2String(buttons, b);
    if (llSubStringIndex(label, "!!llTextBox!!") != -1) {
        buttons = llListReplaceList(buttons, ["[invalid]"], b, b);
    }
    b += 1;
}
```

### IMP-8: Scope RLV Probe Listeners (kmod_bootstrap.lsl)
**Impact:** Reduces attack surface during 30s probe window
**Effort:** Change NULL_KEY to llGetOwner()
**Risk:** Low - RLV responses come from the avatar's viewer

```lsl
// BEFORE:
integer handle = llListen(ch, "", NULL_KEY, "");

// AFTER:
integer handle = llListen(ch, "", llGetOwner(), "");
```

### IMP-9: Convert Low-Frequency Key Globals to String (kmod_leash.lsl)
**Impact:** ~288 bytes saved (6 keys * 48 bytes)
**Effort:** Add (key) casts at usage points
**Risk:** Low - cosmetic change, same behavior

Convert these rarely-accessed globals from `key` to `string`:
- `PendingPassTarget` -> `string PendingPassTarget = "";`
- `PendingPassOriginalUser` -> `string PendingPassOriginalUser = "";`
- `AuthorizedLmController` -> `string AuthorizedLmController = "";`
- `CoffleTargetAvatar` -> `string CoffleTargetAvatar = "";`
- `LeashTarget` -> `string LeashTarget = "";`
- `HolderTarget` -> `string HolderTarget = "";`

Keep `Leasher` and `PendingActionUser` as `key` since they're used frequently in comparisons.

---

## Priority 3: Low Impact, Defensive Hardening

### IMP-10: Add llGetFreeMemory() Guards (High-Memory Scripts)
**Impact:** Graceful degradation instead of stack-heap crashes
**Effort:** Add checks before heavy operations
**Risk:** None

```lsl
// Add at start of heavy JSON operations:
if (llGetFreeMemory() < 4096) {
    llOwnerSay("[MODULE] WARNING: Low memory, operation skipped");
    return;
}
```

Priority targets: `kmod_leash.lsl`, `plugin_leash.lsl`, `kmod_ui.lsl`, `plugin_access.lsl`

### IMP-12: One-Time Y2038 Warning (kernel.lsl, bootstrap.lsl)
**Impact:** Prevents llOwnerSay spam post-2038
**Effort:** Add flag variable
**Risk:** None

```lsl
integer Y2038Warned = FALSE;
integer now() {
    integer unix_time = llGetUnixTime();
    if (unix_time < 0) {
        if (!Y2038Warned) {
            llOwnerSay("[KERNEL] ERROR: Unix timestamp overflow detected!");
            Y2038Warned = TRUE;
        }
        return 0;
    }
    return unix_time;
}
```

### IMP-13: Build Status Text with List Join (plugin_status.lsl)
**Impact:** Fewer temporary string allocations
**Effort:** Refactor string building
**Risk:** None

Use `llDumpList2String(parts, "\n")` instead of repeated `+=` concatenation.

### IMP-14: Remove Workstation-Specific File
**Impact:** Reduces confusion, prevents divergent copies
**Effort:** Delete or .gitignore
**Risk:** None

`ds_collar_plugin_access-MY-WORKSTATION.lsl` is byte-identical to `ds_collar_plugin_access.lsl`.

---

## Summary Matrix

| ID | Category | Scripts Affected | Memory Saved | Speed Gain | Risk |
|----|----------|-----------------|-------------|------------|------|
| IMP-1 | Performance | 26 | - | ~2-3ms/msg | None |
| IMP-2 | Performance | 1 | ~80 bytes | Negligible | None |
| IMP-3 | Perf/Memory | 2 | Variable | Reduced fragmentation | None |
| IMP-4 | Memory | 6 | ~48 bytes | - | None |
| IMP-5 | Performance | 1 | - | O(n) vs O(n^2) | Low |
| IMP-6 | Performance | 1 | - | Fewer list copies | Low |
| IMP-7 | Security | 1 | - | - | None |
| IMP-8 | Security | 1 | - | - | Low |
| IMP-9 | Memory | 1 | ~288 bytes | - | Low |
| IMP-10 | Reliability | 4 | - | - | None |
| IMP-11 | Memory | 1 | - | - | None |
| IMP-12 | Performance | 2 | ~16 bytes | Prevents spam | None |
| IMP-13 | Memory | 1 | Variable | - | None |
| IMP-14 | Hygiene | 1 | 28KB disk | - | None |

---

## What's Already Done Well

The codebase demonstrates several best practices that should be preserved:

1. **Consolidated message bus** - Clean ABI with named channels (500, 700, 800, 900, 950)
2. **Listener hygiene** - Every listener is tracked and removed on cleanup
3. **Blacklist-first ACL** - Security fix correctly evaluates blacklist before any grants
4. **Role exclusivity** - Defense-in-depth prevents conflicting roles
5. **Session timeouts** - Dialog sessions expire and clean up automatically
6. **Owner change resets** - All modules reset state on `CHANGED_OWNER`
7. **Region crossing grace** - Kernel suppresses plugin pruning during region transitions
8. **Batch registration** - Queue-based registration prevents broadcast storms
9. **Yank rate limiting** - Prevents leash yank spam
10. **TPE external owner validation** - Cannot enable TPE without an external owner
11. **Self-ownership prevention** - Wearer cannot be added as owner
12. **Authorized reset senders** - Only bootstrap/maintenance can trigger soft resets
13. **Touch range validation** - Rejects touches beyond 5m
14. **Event-driven design** - No blocking `llSleep()` calls in any hot path
15. **Delta broadcasts** - Settings changes broadcast diffs, not full syncs
