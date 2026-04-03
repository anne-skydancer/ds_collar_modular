# Per-Script Analysis - DS Collar NG

> **NOTE (2026-04-02):** See staleness disclaimer in [ANALYSIS_OVERVIEW.md](./ANALYSIS_OVERVIEW.md). Script file names below use the old `ds_collar_` prefix; v1.1 uses short names (e.g. `collar_kernel.lsl`, `kmod_auth.lsl`). References to removed functions (`broadcast_plugin_acl_list`, `filter_plugins_for_user`, `enforce_role_exclusivity` line numbers) are stale.

**Cross-referenced against:** SL Wiki LSL Script Efficiency, LSL Script Memory, LSL Style Guide, project CLAUDE.md

---

## Kernel & Core Modules

### ds_collar_kernel.lsl (783 lines)
**Purpose:** Plugin registry, lifecycle management, heartbeat monitoring
**Compliance:** 75%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| `count_scripts()` is a no-op loop around `llGetInventoryNumber()` | Perf | 97-105 | Medium |
| Manual JSON array construction via string concat | Perf/Mem | 445-457 | Medium |
| Double JSON reads in `json_has()` + `llJsonGetValue()` | Perf | 64-70 | Medium |
| `validate_required_fields()` has unused `function_name` param | Mem | 74-85 | Low |
| Y2038 `llOwnerSay()` fires on every `now()` call post-overflow | Perf | 91 | Low |
| No `llGetFreeMemory()` guard before registry operations | Mem | 254 | Low |
| `is_authorized_sender()` uses linear scan (OK for 2-element list) | Perf | 107-116 | Negligible |

**Proposed improvements:**
1. Replace `count_scripts()` with direct `llGetInventoryNumber(INVENTORY_SCRIPT)`
2. Replace manual JSON array loop with `llDumpList2String(plugins, ",")`
3. Inline `json_has` checks: use `llJsonGetValue` directly and compare to `JSON_INVALID`
4. Remove unused `function_name` parameter from `validate_required_fields()`
5. Add one-time Y2038 warning flag instead of per-call warning

---

### ds_collar_kmod_auth.lsl (638 lines)
**Purpose:** Authoritative ACL and policy engine
**Compliance:** 82%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Manual JSON array construction in `broadcast_plugin_acl_list()` | Perf/Mem | 166-177 | Medium |
| `enforce_role_exclusivity()` iterates lists with `llListFindList` + `llDeleteSubList` | Perf | 302-350 | Medium |
| Double JSON reads pattern | Perf | 62-63 | Medium |
| `filter_plugins_for_user()` uses `jump` as break (functional but non-idiomatic) | Style | 218 | Low |
| `compute_acl_level()` calls `list_has_key()` for blacklist/trustee (correct) | - | 92-122 | OK |
| Blacklist checked FIRST before any grants | Security | 101 | Good |

**Proposed improvements:**
1. Replace manual JSON array building with `llDumpList2String()`
2. In `enforce_role_exclusivity()`, batch-build new lists instead of modifying in-place with repeated `llDeleteSubList` (which copies the list each time)
3. Inline `json_has` pattern

---

### ds_collar_kmod_settings.lsl (731 lines)
**Purpose:** Persistent key-value store with notecard loading
**Compliance:** 80%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| `list_remove_all()` uses repeated `llDeleteSubList` in while loop | Perf | 89-96 | Medium |
| `list_unique()` is O(n^2) via `list_contains` per element | Perf | 98-110 | Medium |
| CSV parsing for lists could be exploited if values contain commas | Security | 411 | Low |
| `has_external_owner()` re-parses JSON array on every call | Perf | 166-191 | Low |
| `is_allowed_key()` is a long if-chain (OK, no better LSL pattern) | Style | 359-379 | Negligible |
| Role exclusivity guards properly broadcast deltas | Security | 212-309 | Good |

**Proposed improvements:**
1. In `list_remove_all()`, build a new list excluding the target instead of repeated delete (avoids O(n^2) list copies):
```lsl
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
2. Same pattern for `list_unique()` - already O(n^2) but the inner `list_contains` could use `llListFindList` directly (already does, so this is fine)
3. Cache `has_external_owner()` result after settings sync instead of re-parsing JSON each call

---

### ds_collar_kmod_bootstrap.lsl (590 lines)
**Purpose:** Startup coordination, RLV detection, name resolution
**Compliance:** 76%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| RLV probe listeners accept from `NULL_KEY` (any object) | Security | 142 | Medium |
| `sendIM()` uses `llInstantMessage()` which has 2-second throttle | Perf | 103-107 | Low |
| Display name rate limiting correctly spaces requests 2.5s apart | Perf | 34 | Good |
| Y2038 protection in `now()` | Reliability | 93-99 | Good |
| `check_owner_changed()` pattern duplicated from kernel | Mem | 122-134 | Low |

**Proposed improvements:**
1. Scope RLV probe listeners to `llGetOwner()` since RLV responses come from the avatar's viewer
2. Consider using `llOwnerSay()` instead of `llInstantMessage()` for startup messages (faster, no throttle)

---

### ds_collar_kmod_dialogs.lsl (550 lines)
**Purpose:** Centralized dialog management
**Compliance:** 83%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| No TextBox injection prevention on button labels | Security | 345 | Medium |
| `button_map` serialized as JSON string per session (memory cost) | Mem | 342 | Low |
| Channel collision detection loops 100 times | Perf | 155-165 | Low |
| Session limit properly enforced at 10 | Reliability | - | Good |
| Listener properly scoped to user key | Security | 333 | Good |
| Listeners removed on session close | Security | 94-95 | Good |

**Proposed improvements:**
1. Add TextBox injection sanitization before `llDialog()` call
2. Consider stride-list for button_map instead of JSON serialization (saves ~20 bytes per session and avoids JSON parse on response)

---

### ds_collar_kmod_ui.lsl (900 lines)
**Purpose:** Session management, ACL filtering, plugin list orchestration
**Compliance:** 80%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| `apply_plugin_list()` counts JSON array by iterating until INVALID | Perf | 283-285 | Medium |
| `apply_plugin_acl_list()` same pattern | Perf | 326-328 | Medium |
| `update_plugin_label()` scans both AllPlugins AND FilteredPluginsData | Perf | 534-556 | Low |
| Session age check for ACL refresh (60s) | Security | 667-669 | Good |
| Touch range validation (5m) | Security | 788-789 | Good |
| Blacklist re-check during button click | Security | 468-474 | Good |

**Proposed improvements:**
1. For JSON array counting, consider `llParseString2List` with comma delimiter for faster element counting, or track plugin count as an integer alongside the list
2. `update_plugin_label`: exit early from FilteredPluginsData scan once found (each context appears at most once per session)

---

### ds_collar_kmod_leash.lsl (~1100 lines)
**Purpose:** Leashing engine
**Compliance:** 74%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| 8 `key` globals at 102 bytes each = 816 bytes | Mem | 48-98 | High |
| Holder protocol listeners accept NULL_KEY | Security | 407,469 | Medium |
| ACL verification uses single-pending pattern (can't queue) | Reliability | 90-94 | Medium |
| Yank rate limiting properly implemented (5s cooldown) | Security | 101 | Good |
| Offsim detection with grace period | Reliability | 82-87 | Good |
| `jsonHas`/`jsonGet` naming inconsistent with other scripts | Style | 109-115 | Low |

**Proposed improvements:**
1. Convert low-frequency key globals to string type (save ~384 bytes): `PendingPassTarget`, `PendingPassOriginalUser`, `AuthorizedLmController`, `CoffleTargetAvatar`, `LeashTarget`, `HolderTarget`
2. Rename `jsonHas`/`jsonGet` to match project convention `json_has`/`json_get`
3. Consider queuing ACL requests instead of single-pending to handle rapid interactions

---

### ds_collar_kmod_particles.lsl (480 lines)
**Purpose:** Visual chain rendering with Lockmeister compatibility
**Compliance:** 85%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| LM listener accepts NULL_KEY during ping | Security | - | Low |
| Timer guard prevents unnecessary timer events | Perf | - | Good |
| `needs_timer()` check before `llSetTimerEvent()` | Perf | - | Good |
| Explicit LM authorization required before accepting responses | Security | - | Good |

**Proposed improvements:**
1. Minor: scope LM listener to authorized controller key when known

---

### ds_collar_kmod_remote.lsl (560 lines)
**Purpose:** External HUD communication bridge
**Compliance:** 81%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Rate limit list can grow to 120 entries before pruning | Mem | 91 | Medium |
| `llGetObjectDetails()` for distance check on every scan | Perf | 233 | Low |
| No verification that HUD object is actually a HUD | Security | - | Low |
| Rate limiting per-request-type properly implemented | Security | 70-96 | Good |
| Query timeout (30s) with FIFO eviction | Reliability | - | Good |

**Proposed improvements:**
1. Prune rate limit entries more aggressively (e.g., at 60 entries instead of 120)
2. Cache collar position for distance checks within the same timer tick
