# Comprehensive Codebase Audit Report
## DS Collar Modular System

**Audit Date:** 2025-10-29
**Audit Type:** Security, Syntax, Consistency, Redundancy
**Total Files:** 24 LSL scripts
**Auditor:** Claude (Anthropic AI)

---

## Executive Summary

This comprehensive audit examined all 24 LSL files for security vulnerabilities, syntax errors, code consistency issues, and redundancies. The audit builds upon the previous security audit (SECURITY_AUDIT_REPORT.md) and focuses on identifying new issues.

### Overall Assessment: **CRITICAL ISSUES FOUND**

**Key Findings:**
- **CRITICAL:** 2 files have function name mismatches that will cause script crashes
- **SECURITY:** No new security vulnerabilities identified (previous audit findings remain valid)
- **SYNTAX:** Multiple missing return type declarations
- **CONSISTENCY:** Naming convention violations across 2 files
- **REDUNDANCY:** Significant code duplication across helper functions

---

## 1. CRITICAL SYNTAX ERRORS (IMMEDIATE FIX REQUIRED)

### 1.1 Function Name Mismatch - ds_collar_plugin_tpe.lsl

**Severity:** CRITICAL - Script will crash on every function call
**File:** `/home/user/ds_collar_modular/src/stable/ds_collar_plugin_tpe.lsl`

**Problem:** Functions are **defined** using camelCase but **called** using snake_case throughout the file. LSL is case-sensitive and will not find these functions, causing runtime errors.

**Affected Functions:**

| Defined As (Line) | Called As (Lines) | Impact |
|-------------------|-------------------|--------|
| `genSession()` (96) | `gen_session()` (287) | Undefined function error |
| `cleanupSession()` (100) | `cleanup_session()` (207, 229, 275, 342, 482) | Script crash |
| `closeUiForUser()` (106) | `close_ui_for_user()` (195, 217, 470) | Script crash |
| `persistTpeMode()` (157) | `persist_tpe_mode()` (177, 253) | Script crash |
| `registerWithKernel()` (120) | `register_with_kernel()` (344, 370) | Script crash |
| `sendPong()` (137) | `send_pong()` (373) | Script crash |
| `requestSettingsSync()` (149) | `request_settings_sync()` (346) | Script crash |
| `applySettingsSync()` (307) | `apply_settings_sync()` (385) | Script crash |
| `applySettingsDelta()` (314) | `apply_settings_delta()` (389) | Script crash |
| `handleTpeClick()` (237) | `handle_tpe_click()` (444) | Script crash |
| `handleButtonClick()` (173) | `handle_button_click()` (457) | Script crash |
| `jsonHas()` (88) | `json_has()` (308, 315, 320, 323, 383, 425, 435) | Script crash |

**Total Affected Lines:** 28+ function calls will fail

---

### 1.2 Function Name Mismatch - ds_collar_plugin_lock.lsl

**Severity:** CRITICAL - Script will crash on every function call
**File:** `/home/user/ds_collar_modular/src/stable/ds_collar_plugin_lock.lsl`

**Problem:** Same issue - functions defined in camelCase but called in snake_case.

**Affected Functions:**

| Defined As (Line) | Called As (Lines) | Impact |
|-------------------|-------------------|--------|
| `jsonHas()` (60) | `json_has()` (103, 110, 122, 127, 130, 338, 356, 374, 378, 393, 398, 401) | Script crash (12 calls) |
| `playToggleSound()` (64) | `play_toggle_sound()` (267) | Script crash |
| `registerSelf()` (72) | `register_self()` (320, 342) | Script crash |
| `sendPong()` (90) | `send_pong()` (347) | Script crash |
| `applySettingsSync()` (102) | `apply_settings_sync()` (360) | Script crash |
| `applySettingsDelta()` (121) | `apply_settings_delta()` (365) | Script crash |
| `persistLocked()` (158) | `persist_locked()` (273) | Script crash |
| `applyLockState()` (171) | `apply_lock_state()` (115, 135, 270, 321) | Script crash |
| `showLockedPrim()` (192) | `show_locked_prim()` (177) | Script crash |
| `showUnlockedPrim()` (208) | `show_unlocked_prim()` (183) | Script crash |
| `updateUiLabelAndReturn()` (228) | `update_ui_label_and_return()` (284) | Script crash |
| `toggleLock()` (256) | `toggle_lock()` (310) | Script crash |
| `requestAclAndToggle()` (291) | `request_acl_and_toggle()` (384) | Script crash |
| `handleAclResult()` (300) | `handle_acl_result()` (403) | Script crash |

**Total Affected Lines:** 35+ function calls will fail

---

### 1.3 Missing Return Type Declarations

**Severity:** HIGH - Syntax error in LSL
**Issue:** LSL requires explicit return types for all functions

**ds_collar_plugin_tpe.lsl:**
```lsl
// WRONG (Line 100)
cleanupSession() {
    CurrentUser = NULL_KEY;
}

// CORRECT
void cleanupSession() {
    CurrentUser = NULL_KEY;
}
```

**Affected Functions:**
- `ds_collar_plugin_tpe.lsl`: Lines 100, 106, 120, 137, 149, 157, 173, 237, 307, 314 (10 functions)
- `ds_collar_plugin_lock.lsl`: Lines 64, 102, 121, 158, 171, 192, 208, 228, 256, 291, 300 (11 functions)
- `ds_collar_plugin_owner.lsl`: Line 77 (`logd()` function)

**Note:** While some LSL implementations may allow implicit void return types, explicit declarations are best practice and required by strict LSL parsers.

---

## 2. SECURITY AUDIT

### 2.1 Security Assessment: EXCELLENT (No New Issues)

The previous security audit (SECURITY_AUDIT_REPORT.md) remains accurate. All security controls are properly implemented:

✅ **Access Control:** ACL system with blacklist-first checking
✅ **Input Validation:** JSON validation and parameter checking
✅ **Rate Limiting:** DoS protection in place
✅ **Session Management:** Timeout and correlation IDs
✅ **Authorization:** Proper ACL checks before sensitive operations
✅ **Owner Change Detection:** Script reset on ownership transfer
✅ **Role Exclusivity:** Owner/trustee separation enforced

### 2.2 Security Verification

**Verified Security Controls in TPE Plugin (ds_collar_plugin_tpe.lsl):**
- **ACL Enforcement:** Line 239 - Only Primary Owner (ACL 5) can manage TPE
- **Wearer Consent:** Lines 278-300 - Dialog confirmation required for TPE activation
- **Input Validation:** Lines 308, 315, 320, 323, 383, 425, 435 - JSON validation (would work if `jsonHas()` was called correctly)

**Verified Security Controls in Lock Plugin (ds_collar_plugin_lock.lsl):**
- **ACL Enforcement:** Line 258 - Only ACL 4 (unowned wearer) or 5 (owner) can toggle
- **Input Validation:** Multiple `jsonHas()` checks throughout (would work if called correctly)
- **RLV Security:** Lines 176, 182 - Proper RLV detach control

### 2.3 No New Vulnerabilities Identified

The critical syntax errors prevent the scripts from running, but they do not introduce security vulnerabilities. Once fixed, the security controls will function as designed.

---

## 3. CODE CONSISTENCY ISSUES

### 3.1 Naming Convention Violations

**Standard (per STYLE_GUIDE.md):**
- Functions: `camelCase`
- Global Variables: `PascalCase`
- Constants: `UPPER_SNAKE_CASE`
- Local Variables: `camelCase`

**Violations Found:**

| File | Issue | Line Examples |
|------|-------|---------------|
| ds_collar_plugin_tpe.lsl | Functions defined camelCase, called snake_case | All function calls |
| ds_collar_plugin_lock.lsl | Functions defined camelCase, called snake_case | All function calls |

**Consistent Files (Good Examples):**
- `ds_collar_kernel.lsl` - Consistent camelCase
- `ds_collar_kmod_auth.lsl` - Consistent camelCase
- `ds_collar_kmod_settings.lsl` - Consistent camelCase
- `ds_collar_plugin_blacklist.lsl` - Consistent snake_case throughout
- `ds_collar_plugin_animate.lsl` - Consistent camelCase

### 3.2 Inconsistent Function Naming Across Codebase

**Pattern Analysis:**

Different plugins use different naming styles:
- **camelCase plugins:** animate, status, owner, maintenance (following STYLE_GUIDE.md)
- **snake_case plugins:** blacklist, bell (internally consistent)
- **Mixed/broken plugins:** tpe, lock (definitions don't match calls)

**Recommendation:** Standardize all plugins to camelCase per STYLE_GUIDE.md

---

## 4. REDUNDANCY ANALYSIS

### 4.1 Duplicated Helper Functions

**Pattern:** Common helper functions duplicated across 20+ files

#### `logd()` Function
**Duplication:** Found in ~20 files with identical implementation
```lsl
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[PREFIX] " + msg);
    return FALSE;
}
```

**Files:** kernel, auth, ui, settings, tpe, status, owner, lock, blacklist, animate, bell, and more

**Impact:** 20+ copies of identical code (~3 lines each = ~60 lines of duplicated code)

---

#### `jsonHas()` Function
**Duplication:** Found in ~15 files with identical implementation
```lsl
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
```

**Files:** kernel, auth, ui, settings, tpe, status, lock, animate, bell, and more

**Impact:** 15+ copies of identical code (~3 lines each = ~45 lines of duplicated code)

---

#### `isJsonArr()` Function
**Duplication:** Found in ~5 files
```lsl
integer isJsonArr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}
```

**Files:** kernel, auth, settings, tpe, status

**Impact:** 5+ copies of identical code

---

### 4.2 Inconsistent Session Generation

**Problem:** Session ID generation has 3 different implementations with 4 different names

**Implementation 1 (ds_collar_plugin_tpe.lsl:96):**
```lsl
string genSession() {
    return (string)llGetKey() + "_" + (string)llGetUnixTime();
}
```

**Implementation 2 (ds_collar_plugin_blacklist.lsl):**
```lsl
string generate_session_id() {
    return "blacklist_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}
```

**Implementation 3 (ds_collar_plugin_animate.lsl):**
```lsl
string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}
```

**Implementation 4 (ds_collar_plugin_status.lsl):**
```lsl
string generateSessionId() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}
```

**Issues:**
1. 4 different function names for the same purpose
2. 3 different entropy combinations
3. Inconsistent prefix strategies

**Recommendation:** Standardize to a single implementation with consistent naming

---

### 4.3 Duplicated Settings Patterns

**Pattern:** Settings sync/delta consumption repeated in ~12 plugins

**Common Pattern:**
```lsl
applySettingsSync(string msg) {
    if (jsonHas(msg, ["kv"])) {
        string kv_json = llJsonGetValue(msg, ["kv"]);
        // ... extract specific keys
    }
}

applySettingsDelta(string msg) {
    if (jsonHas(msg, ["op"])) {
        string op = llJsonGetValue(msg, ["op"]);
        if (op == "set") {
            if (jsonHas(msg, ["changes"])) {
                string changes = llJsonGetValue(msg, ["changes"]);
                // ... extract specific keys
            }
        }
    }
}
```

**Found In:** tpe, lock, owner, status, animate, bell, blacklist, and more

**Impact:** ~40-50 lines of nearly identical code per plugin × 12 plugins = ~500 lines of duplicated code

**Consolidation Opportunity:** Could be abstracted into a base plugin template or helper module

---

### 4.4 Duplicated Lifecycle Patterns

**Pattern:** Registration and pong handling repeated in all plugins

```lsl
registerSelf() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

sendPong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}
```

**Found In:** All 14+ plugin files

**Impact:** ~20 lines per plugin × 14 plugins = ~280 lines of duplicated code

---

### 4.5 Summary of Redundancy

| Pattern | Files Affected | Lines Duplicated | Consolidation Opportunity |
|---------|----------------|------------------|---------------------------|
| `logd()` helper | ~20 | ~60 | Shared include or kernel service |
| `jsonHas()` helper | ~15 | ~45 | Shared include or kernel service |
| `isJsonArr()` helper | ~5 | ~15 | Shared include or kernel service |
| Session generation | ~4 | ~20 | Standardized helper function |
| Settings sync/delta | ~12 | ~500 | Base plugin template |
| Lifecycle (register/pong) | ~14 | ~280 | Base plugin template |
| **TOTAL** | | **~920 lines** | |

**Potential Code Reduction:** ~920 lines could be consolidated into shared modules

---

## 5. FILE-BY-FILE STATUS

### Critical Issues (2 files)
- ❌ **ds_collar_plugin_tpe.lsl** - Function name mismatches (28+ calls will fail)
- ❌ **ds_collar_plugin_lock.lsl** - Function name mismatches (35+ calls will fail)

### High Priority Issues (2 files)
- ⚠️ **ds_collar_plugin_tpe.lsl** - Missing return types (10 functions)
- ⚠️ **ds_collar_plugin_lock.lsl** - Missing return types (11 functions)

### Medium Priority Issues (1 file)
- ⚠️ **ds_collar_plugin_owner.lsl** - Missing return type on `logd()` (line 77)

### Good Quality (21 files)
- ✅ All kernel modules (kernel, kmod_auth, kmod_ui, kmod_settings, kmod_dialogs, kmod_leash, kmod_particles, kmod_remote, kmod_bootstrap)
- ✅ Most plugins (animate, bell, blacklist, maintenance, owner, public, rlvexceptions, rlvrelay, rlvrestrict, status, leash)
- ✅ Control HUD (ds_collar_control_hud.lsl)
- ✅ Leash holder (ds_collar_leash_holder.lsl)

---

## 6. RECOMMENDED FIXES

### Phase 1: CRITICAL (Fix Immediately)

**Priority:** URGENT - Scripts are non-functional

#### Fix 1.1: ds_collar_plugin_tpe.lsl

**Option A:** Change all function calls from snake_case to camelCase (RECOMMENDED)
- Change `gen_session()` → `genSession()` (1 occurrence)
- Change `cleanup_session()` → `cleanupSession()` (5 occurrences)
- Change `close_ui_for_user()` → `closeUiForUser()` (3 occurrences)
- Change `persist_tpe_mode()` → `persistTpeMode()` (2 occurrences)
- Change `register_with_kernel()` → `registerWithKernel()` (2 occurrences)
- Change `send_pong()` → `sendPong()` (1 occurrence)
- Change `request_settings_sync()` → `requestSettingsSync()` (1 occurrence)
- Change `apply_settings_sync()` → `applySettingsSync()` (1 occurrence)
- Change `apply_settings_delta()` → `applySettingsDelta()` (1 occurrence)
- Change `handle_tpe_click()` → `handleTpeClick()` (1 occurrence)
- Change `handle_button_click()` → `handleButtonClick()` (1 occurrence)
- Change `json_has()` → `jsonHas()` (7 occurrences)

**Option B:** Change all function definitions from camelCase to snake_case
- Less recommended as it violates STYLE_GUIDE.md

**Recommended:** Option A - Follow camelCase convention

#### Fix 1.2: ds_collar_plugin_lock.lsl

**Apply same fix as above** - change all 35+ snake_case function calls to camelCase

---

### Phase 2: HIGH Priority (Fix Soon)

**Priority:** HIGH - Syntax errors

#### Fix 2.1: Add Return Type Declarations

Add explicit `void` return type to all functions that don't return values:

**ds_collar_plugin_tpe.lsl:**
```lsl
// Line 100
void cleanupSession() { ... }

// Line 106
void closeUiForUser(key user) { ... }

// Line 120
void registerWithKernel() { ... }

// Line 137
void sendPong() { ... }

// Line 149
void requestSettingsSync() { ... }

// Line 157
void persistTpeMode(integer new_value) { ... }

// Line 173
void handleButtonClick(string button) { ... }

// Line 237
void handleTpeClick(key user, integer acl_level) { ... }

// Line 307
void applySettingsSync(string kv_json) { ... }

// Line 314
void applySettingsDelta(string msg) { ... }
```

**ds_collar_plugin_lock.lsl:**
Apply same pattern to all 11 functions missing return types

---

### Phase 3: MEDIUM Priority (Code Quality)

**Priority:** MEDIUM - Improve maintainability

#### Fix 3.1: Standardize Naming Conventions

- Review all plugins and standardize to camelCase per STYLE_GUIDE.md
- Update any remaining snake_case plugins (blacklist, bell) to camelCase
- Document exceptions if any plugins must use snake_case

#### Fix 3.2: Document Entropy Sources

- Add comments to session generation explaining entropy sources
- Reference LSL_SECURITY_LIMITATIONS.md in session generation code

---

### Phase 4: LOW Priority (Optimization)

**Priority:** LOW - Reduce technical debt

#### Fix 4.1: Consolidate Helper Functions

**Option 1:** Create shared include file (if LSL supports includes)
**Option 2:** Move helpers to kernel and expose via message bus
**Option 3:** Accept duplication as LSL limitation

**Helpers to consolidate:**
- `logd()` - 20+ copies
- `jsonHas()` - 15+ copies
- `isJsonArr()` - 5+ copies

#### Fix 4.2: Create Base Plugin Template

Create documentation or template showing standard plugin structure:
- Lifecycle management (register, pong)
- Settings sync/delta consumption
- ACL validation patterns
- Session management

**Benefit:** New plugins can follow template, reducing duplication

#### Fix 4.3: Standardize Session Generation

Choose one implementation and naming convention:
```lsl
// Recommended standard implementation
string generateSessionId() {
    integer time_entropy = llGetUnixTime();
    integer key_entropy = (integer)("0x" + llGetSubString((string)llGetKey(), 0, 7));
    integer random_entropy = (integer)llFrand(999999.0);

    return PLUGIN_CONTEXT + "_" + (string)(time_entropy + key_entropy + random_entropy);
}
```

Apply across all plugins that need session IDs.

---

## 7. TESTING RECOMMENDATIONS

### 7.1 Syntax Testing

**After Phase 1 fixes:**
1. Compile all LSL files with `lslint` or LSL compiler
2. Verify no "undefined function" errors
3. Check for any remaining syntax warnings

### 7.2 Functional Testing

**After Phase 2 fixes:**
1. **TPE Plugin:**
   - Test owner activating TPE mode (should show wearer consent dialog)
   - Test wearer accepting TPE activation
   - Test wearer declining TPE activation
   - Test dialog timeout behavior
   - Test owner deactivating TPE mode
   - Verify wearer ACL changes correctly (ACL 0 when TPE on, ACL 2/4 when off)

2. **Lock Plugin:**
   - Test locking collar (should prevent detach via RLV)
   - Test unlocking collar (should allow detach)
   - Test ACL enforcement (only ACL 4 or 5 can toggle)
   - Verify sound plays on toggle
   - Verify visual prim state changes (if prims exist)
   - Test settings sync/delta for lock state

### 7.3 Integration Testing

**After all fixes:**
1. Test soft reset behavior
2. Test ownership change handling
3. Test settings persistence across script resets
4. Test multi-user scenarios (owner vs wearer interactions)

---

## 8. ESTIMATED FIX TIME

| Phase | Priority | Estimated Time | Scope |
|-------|----------|----------------|-------|
| Phase 1 | CRITICAL | 30-60 minutes | Fix function name mismatches in 2 files |
| Phase 2 | HIGH | 30 minutes | Add return type declarations |
| Phase 3 | MEDIUM | 1-2 hours | Standardize naming, documentation |
| Phase 4 | LOW | 4-8 hours | Consolidate helpers, create templates |
| **TOTAL** | | **6-11 hours** | Full remediation |

**Minimum viable fix (Phases 1-2):** 1-1.5 hours

---

## 9. SECURITY COMPARISON

### 9.1 Previous Audit vs Current Audit

**Previous Audit (SECURITY_AUDIT_REPORT.md):**
- Overall Assessment: GOOD
- No critical vulnerabilities
- Minor naming inconsistencies in plugin_owner.lsl
- Recommendations for documentation improvements

**Current Audit:**
- Overall Assessment: CRITICAL SYNTAX ERRORS BLOCK EXECUTION
- Security design remains sound (when scripts can execute)
- New critical issues in tpe.lsl and lock.lsl
- Extensive redundancy identified

### 9.2 Security Status

**Security Posture:** UNCHANGED (Good design, but 2 files currently non-functional)

The security controls identified in the previous audit remain valid:
- ✅ ACL system properly designed
- ✅ Input validation patterns correct
- ✅ Rate limiting in place
- ✅ Session management sound
- ✅ Owner change detection working

**However:** The critical syntax errors in tpe.lsl and lock.lsl prevent these security controls from executing.

---

## 10. CONCLUSIONS AND RECOMMENDATIONS

### 10.1 Overall Assessment

**Code Quality:** MIXED
- **Excellent:** Core kernel and kmod architecture, security design
- **Good:** Most plugins (21 out of 24 files)
- **Critical Issues:** 2 plugins with broken function calls
- **Technical Debt:** Significant code duplication (~920 lines)

### 10.2 Immediate Actions Required

1. ✅ **URGENT:** Fix function name mismatches in tpe.lsl and lock.lsl
2. ✅ **HIGH:** Add missing return type declarations
3. ✅ **MEDIUM:** Standardize naming conventions project-wide
4. ✅ **LOW:** Consider consolidating duplicated helpers

### 10.3 Long-Term Recommendations

1. **Implement CI/CD with LSL syntax checking**
   - Add pre-commit hooks to catch syntax errors
   - Run `lslint` on all files before merging
   - Add function name consistency checks

2. **Create plugin development guidelines**
   - Base plugin template
   - Standard helper library
   - Copy-paste starter code

3. **Regular code audits**
   - Monthly syntax checks
   - Quarterly security reviews
   - Annual architecture review

### 10.4 Positive Findings

Despite the critical syntax errors, the codebase demonstrates:
- ✅ Strong security architecture
- ✅ Comprehensive ACL system
- ✅ Good documentation (README, STYLE_GUIDE, SECURITY docs)
- ✅ Evidence of prior security hardening
- ✅ Consistent structure across modules
- ✅ Defense-in-depth approach

---

## 11. AUDIT METHODOLOGY

### 11.1 Tools and Techniques Used

1. **Static Code Analysis:**
   - Manual file review of all 24 LSL files
   - Function definition vs call comparison
   - Naming convention verification
   - Pattern matching for duplicated code

2. **Security Analysis:**
   - Verification of ACL enforcement
   - Input validation review
   - Session management audit
   - Rate limiting verification

3. **Consistency Analysis:**
   - Naming convention comparison against STYLE_GUIDE.md
   - Cross-file pattern analysis
   - Code structure review

4. **Redundancy Analysis:**
   - Duplicate function identification
   - Pattern repetition detection
   - Code consolidation opportunities

### 11.2 Audit Scope

**Included:**
- All 24 LSL files in src/stable/
- Security controls and patterns
- Syntax correctness
- Code consistency
- Code duplication

**Excluded:**
- Runtime performance analysis
- Memory usage profiling
- Network traffic analysis
- User experience testing

---

## 12. APPENDICES

### Appendix A: Affected Files List

**Critical Issues:**
1. `/home/user/ds_collar_modular/src/stable/ds_collar_plugin_tpe.lsl`
2. `/home/user/ds_collar_modular/src/stable/ds_collar_plugin_lock.lsl`

**Minor Issues:**
3. `/home/user/ds_collar_modular/src/stable/ds_collar_plugin_owner.lsl`

**Clean Files (21 files):**
- ds_collar_kernel.lsl
- ds_collar_kmod_auth.lsl
- ds_collar_kmod_bootstrap.lsl
- ds_collar_kmod_dialogs.lsl
- ds_collar_kmod_leash.lsl
- ds_collar_kmod_particles.lsl
- ds_collar_kmod_remote.lsl
- ds_collar_kmod_settings.lsl
- ds_collar_kmod_ui.lsl
- ds_collar_control_hud.lsl
- ds_collar_leash_holder.lsl
- ds_collar_plugin_animate.lsl
- ds_collar_plugin_bell.lsl
- ds_collar_plugin_blacklist.lsl
- ds_collar_plugin_leash.lsl
- ds_collar_plugin_maintenance.lsl
- ds_collar_plugin_owner.lsl
- ds_collar_plugin_public.lsl
- ds_collar_plugin_rlvexceptions.lsl
- ds_collar_plugin_rlvrelay.lsl
- ds_collar_plugin_rlvrestrict.lsl
- ds_collar_plugin_status.lsl

### Appendix B: Quick Reference - Function Name Fixes

**ds_collar_plugin_tpe.lsl - Find and Replace:**
```
gen_session()         → genSession()
cleanup_session()     → cleanupSession()
close_ui_for_user(    → closeUiForUser(
persist_tpe_mode(     → persistTpeMode(
register_with_kernel( → registerWithKernel(
send_pong()           → sendPong()
request_settings_sync( → requestSettingsSync(
apply_settings_sync(  → applySettingsSync(
apply_settings_delta( → applySettingsDelta(
handle_tpe_click(     → handleTpeClick(
handle_button_click(  → handleButtonClick(
json_has(             → jsonHas(
```

**ds_collar_plugin_lock.lsl - Find and Replace:**
```
json_has(                   → jsonHas(
play_toggle_sound()         → playToggleSound()
register_self()             → registerSelf()
send_pong()                 → sendPong()
apply_settings_sync(        → applySettingsSync(
apply_settings_delta(       → applySettingsDelta(
persist_locked(             → persistLocked(
apply_lock_state()          → applyLockState()
show_locked_prim()          → showLockedPrim()
show_unlocked_prim()        → showUnlockedPrim()
update_ui_label_and_return( → updateUiLabelAndReturn(
toggle_lock(                → toggleLock(
request_acl_and_toggle(     → requestAclAndToggle(
handle_acl_result(          → handleAclResult(
```

### Appendix C: Redundancy Metrics

| Helper Function | Occurrences | Lines Each | Total Duplicated |
|-----------------|-------------|------------|------------------|
| logd() | 20 | 3 | 60 |
| jsonHas() | 15 | 3 | 45 |
| isJsonArr() | 5 | 3 | 15 |
| Session generation | 4 | 5 | 20 |
| Settings sync | 12 | 40 | 480 |
| Lifecycle (register/pong) | 14 | 20 | 280 |
| **TOTAL** | | | **900 lines** |

---

**End of Audit Report**

*This audit was conducted by an AI assistant and should be validated by human developers before applying fixes to production systems.*
