# Per-Script Analysis - Plugins & UI

> **NOTE (2026-04-02):** See staleness disclaimer in [ANALYSIS_OVERVIEW.md](./ANALYSIS_OVERVIEW.md). Script file names below use the old `ds_collar_` prefix; v1.1 uses short names (e.g. `plugin_access.lsl`, `kmod_ui.lsl`). The workstation-specific duplicate file mentioned at the end has been removed.

---

## UI Layer

### ds_collar_menu.lsl (240 lines)
**Purpose:** Menu rendering and visual presentation
**Compliance:** 88%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Button reordering builds temporary lists for display | Perf | - | Low |
| No persistent state (pure rendering service) | Mem | - | Good |
| Clean separation of concerns from kmod_ui | Architecture | - | Good |

**Proposed improvements:** None critical. Well-structured rendering service.

---

### ds_collar_control_hud.lsl (100 lines)
**Purpose:** Auto-detect nearby collars and connect
**Compliance:** 80%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Long-touch tracking uses `llGetTime()` (resets on script reset) | Reliability | - | Low |
| Emergency SOS bypass for wearer - intentional design | Security | - | OK |
| No collar response authentication | Security | - | Medium |

**Proposed improvements:**
1. Validate collar scan responses more strictly (check for expected JSON structure)

---

## Plugin Modules

### ds_collar_plugin_leash.lsl (~1000 lines)
**Purpose:** Leash UI and configuration
**Compliance:** 76%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| 5 `key` globals at 102 bytes each | Mem | 49-60 | Medium |
| `SensorCandidates` list can grow unbounded from sensor results | Mem | 54 | Medium |
| `llGetAgentList(AGENT_LIST_PARCEL)` returns all agents (efficient) | Perf | 237 | Good |
| Avatar list capped at 9 per page | Mem | 244 | Good |
| Offer dialog properly cleaned up on timeout | Reliability | 390-397 | Good |
| Stack-heap collision previously fixed (rev 21) | Mem | header | Good |

**Proposed improvements:**
1. Convert infrequently-accessed key globals to string type
2. Cap `SensorCandidates` to maximum needed (e.g., 36 for 4 pages of 9)
3. Clear `SensorCandidates` when leaving sensor menus

---

### ds_collar_plugin_access.lsl (900 lines)
**Purpose:** Owner, trustee, honorific management
**Compliance:** 78%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| `NameCache` limited to 10 entries (20 list elements) | Mem | 101-102 | Good |
| `llGetDisplayName()` called before cache check in `get_name()` | Perf | 112-113 | Low |
| `show_candidates()` doesn't initialize loop variable `i` | Bug | 347 | Medium |
| `CandidateKeys` populated by sensor but not size-capped | Mem | - | Low |
| Runaway disable requires wearer consent (security pattern) | Security | 466-484 | Good |
| Dual confirmation for ownership changes | Security | - | Good |

**Proposed improvements:**
1. **Bug fix:** Initialize `integer i` to 0 in `show_candidates()` line 347 (currently undefined - LSL defaults to 0 but explicit init is best practice)
2. Check cache before calling `llGetDisplayName()` in `get_name()`
3. Cap sensor results

---

### ds_collar_plugin_bell.lsl (465 lines)
**Purpose:** Bell sound on movement, volume/visibility controls
**Compliance:** 82%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Movement detection uses `moving_start`/`moving_end` events | Perf | - | Good |
| Sound throttling prevents spam | Perf | - | Good |
| Settings properly persisted via settings bus | Architecture | - | Good |

**Proposed improvements:** None critical.

---

### ds_collar_plugin_animate.lsl (450 lines)
**Purpose:** Animation playback with pose management
**Compliance:** 80%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Permission re-request on attach/owner change | Reliability | - | Good |
| Animation list from inventory (cached) | Perf | - | Good |

**Proposed improvements:**
1. Cache inventory animation count and invalidate on `CHANGED_INVENTORY`

---

### ds_collar_plugin_lock.lsl (360 lines)
**Purpose:** Lock/unlock collar with PIN protection
**Compliance:** 82%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| PIN stored in settings (not hardcoded) | Security | - | Good |
| Lock state synchronized via settings delta | Architecture | - | Good |

**Proposed improvements:** None critical.

---

### ds_collar_plugin_blacklist.lsl (510 lines)
**Purpose:** Manage blacklist via dialog
**Compliance:** 79%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Sensor-based avatar selection | Reliability | - | Good |
| Blacklist guard integration with settings bus | Security | - | Good |

**Proposed improvements:**
1. Cap sensor results to prevent unbounded list growth

---

### ds_collar_plugin_maintenance.lsl (600 lines)
**Purpose:** Reset/update functionality
**Compliance:** 80%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Authorized sender validation for reset commands | Security | - | Good |
| Update PIN generation for remote loading | Security | - | Good |

**Proposed improvements:** None critical.

---

### ds_collar_plugin_public.lsl (305 lines)
**Purpose:** Toggle public access mode
**Compliance:** 85%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Simple toggle with dynamic label update | Architecture | - | Good |
| Trustee minimum (ACL 3) enforced | Security | - | Good |

**Proposed improvements:** None critical. Clean, minimal plugin.

---

### ds_collar_plugin_sos.lsl (290 lines)
**Purpose:** Emergency wearer-accessible actions
**Compliance:** 84%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| ACL 0 accessible (emergency access) | Security | - | Good |
| Returns to root menu after action | UX | - | Good |

**Proposed improvements:** None critical.

---

### ds_collar_plugin_status.lsl (605 lines)
**Purpose:** Read-only collar status display
**Compliance:** 77%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| String concatenation in loops for building status text | Perf/Mem | - | Medium |
| Async display name resolution | Perf | - | Good |
| Multi-owner mode support | Architecture | - | Good |

**Proposed improvements:**
1. Build status text using list accumulation + `llDumpList2String()` instead of `+=` concatenation:
```lsl
// Instead of:
string text = "";
text += "Owner: " + name + "\n";
text += "Status: " + status + "\n";

// Use:
list parts = [];
parts += ["Owner: " + name];
parts += ["Status: " + status];
string text = llDumpList2String(parts, "\n");
```

---

### ds_collar_plugin_tpe.lsl (419 lines)
**Purpose:** Total Power Exchange mode
**Compliance:** 81%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| External owner validation before TPE enable | Security | - | Good |
| Wearer loses all access in TPE mode | Security | - | By Design |

**Proposed improvements:** None critical.

---

### ds_collar_plugin_rlvrelay.lsl (720 lines)
**Purpose:** ORG-compliant RLV relay
**Compliance:** 80%

| Finding | Type | Line(s) | Severity |
|---------|------|---------|----------|
| Relay listener accepts NULL_KEY (required by ORG spec) | Security | 123 | By Spec |
| Max 5 concurrent relays enforced | Mem | 158 | Good |
| `@clear` used for restriction removal (safer than manual) | Security | 196 | Good |
| Hardcore mode requires trustee ACL | Security | - | Good |
| `WearerKey` cached for performance | Perf | 64 | Good |

**Proposed improvements:**
1. Validate relay command format more strictly (check for expected RLV command prefixes)
2. Add `llGetFreeMemory()` check before adding relay sessions

---

### ds_collar_plugin_rlvrestrict.lsl (573 lines)
**Purpose:** RLV restriction commands
**Compliance:** 79%

**Proposed improvements:**
1. Group related restrictions to reduce individual `llOwnerSay("@...")` calls

---

### ds_collar_plugin_rlvexceptions.lsl (600 lines)
**Purpose:** RLV exception management
**Compliance:** 78%

**Proposed improvements:**
1. Cache exception list to avoid repeated JSON parsing

---

### ds_collar_leash_holder.lsl (100 lines)
**Purpose:** External leash holder object script
**Compliance:** 83%

**Proposed improvements:** None critical. Simple responder script.

---

### ds_collar_plugin_access-MY-WORKSTATION.lsl
**Note:** This appears to be a workstation-specific copy of `plugin_access.lsl`. Identical content (28,131 bytes each). Should be removed or .gitignored to avoid confusion.
