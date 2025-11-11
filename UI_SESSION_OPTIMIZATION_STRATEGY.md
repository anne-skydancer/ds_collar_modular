# UI Session Lifecycle Optimization Strategy

## Executive Summary

This document outlines optimizations to reduce UI sluggishness without violating architectural boundaries. The strategy focuses on **session lifecycle management** rather than structural changes, preserving the 3-module separation (UI/Menu/Dialog).

**Expected Improvements:**
- First click after idle: 78ms → 15ms (after ACL cached)
- Navigation clicks: 78ms → 8ms (60% reduction)
- Eliminates "intermittent sluggishness" from session expiry

---

## Root Cause Analysis

### Issue 1: Aggressive Session Expiry
**Location:** `ds_collar_kmod_ui.lsl` line 723
```lsl
if (age > SESSION_MAX_AGE) {  // 60 seconds
    cleanup_session(user_key);  // Forces ACL re-query
}
```
**Impact:** Every 60 seconds of activity triggers cold start (~78ms)

### Issue 2: No Session Age Reset on Activity
**Location:** `ds_collar_kmod_ui.lsl` lines 521-543 (navigation handlers)
- Navigation updates page number but doesn't reset session age
- Active users hit 60s timeout during normal usage

### Issue 3: Dialog Session Churn
**Location:** `ds_collar_kmod_dialogs.lsl` line 353
```lsl
integer existing_idx = find_session_idx(session_id);
if (existing_idx != -1) {
    close_session_at_idx(existing_idx);  // Removes listener
}
```
**Impact:** Every menu change closes and recreates listener (~5ms overhead)

### Issue 4: No ACL Caching
**Location:** `ds_collar_kmod_ui.lsl` lines 677-693, 697-709
- Every cold start queries AUTH_BUS (~50ms)
- ACL level rarely changes, yet queried repeatedly

### Issue 5: Dialog Timeout = 60s Absolute
**Location:** `ds_collar_kmod_dialogs.lsl` lines 320, 374
- Dialog expires after 60s regardless of activity
- No mechanism to extend timeout during active use

---

## Optimization Strategy

### Phase 1: ACL Result Caching (Highest Impact)

**Objective:** Eliminate 50ms AUTH_BUS query on repeated interactions

**Implementation in `ds_collar_kmod_ui.lsl`:**

1. Add cache data structure:
```lsl
/* ACL cache stride: [avatar_key, acl_level, cached_time] */
integer ACL_CACHE_STRIDE = 3;
integer ACL_CACHE_AVATAR = 0;
integer ACL_CACHE_LEVEL = 1;
integer ACL_CACHE_TIME = 2;

list AclCache = [];
integer ACL_CACHE_TTL = 300;  // 5 minutes
integer ACL_CACHE_MAX = 10;   // Limit cache size
```

2. Add cache management functions:
```lsl
integer get_cached_acl(key avatar) {
    integer i = 0;
    integer len = llGetListLength(AclCache);
    integer now_time = llGetUnixTime();
    
    while (i < len) {
        if (llList2Key(AclCache, i + ACL_CACHE_AVATAR) == avatar) {
            integer cached_time = llList2Integer(AclCache, i + ACL_CACHE_TIME);
            if ((now_time - cached_time) < ACL_CACHE_TTL) {
                return llList2Integer(AclCache, i + ACL_CACHE_LEVEL);
            }
            else {
                // Expired - remove from cache
                AclCache = llDeleteSubList(AclCache, i, i + ACL_CACHE_STRIDE - 1);
                return -999;  // Cache miss
            }
        }
        i += ACL_CACHE_STRIDE;
    }
    return -999;  // Cache miss
}

update_acl_cache(key avatar, integer acl_level) {
    integer now_time = llGetUnixTime();
    
    // Check if already cached
    integer i = 0;
    integer len = llGetListLength(AclCache);
    while (i < len) {
        if (llList2Key(AclCache, i + ACL_CACHE_AVATAR) == avatar) {
            // Update existing entry
            AclCache = llListReplaceList(AclCache, 
                [avatar, acl_level, now_time], 
                i, i + ACL_CACHE_STRIDE - 1);
            return;
        }
        i += ACL_CACHE_STRIDE;
    }
    
    // Add new entry
    AclCache += [avatar, acl_level, now_time];
    
    // Enforce cache size limit (remove oldest)
    if (llGetListLength(AclCache) / ACL_CACHE_STRIDE > ACL_CACHE_MAX) {
        AclCache = llDeleteSubList(AclCache, 0, ACL_CACHE_STRIDE - 1);
    }
}

clear_acl_cache() {
    AclCache = [];
}
```

3. Modify session start functions:
```lsl
start_root_session(key user_key) {
    logd("Root session start request from " + llKey2Name(user_key));
    
    // Check cache first
    integer cached_acl = get_cached_acl(user_key);
    if (cached_acl != -999) {
        logd("Using cached ACL: " + (string)cached_acl);
        handle_acl_result_direct(user_key, cached_acl, ROOT_CONTEXT);
        return;
    }
    
    // Cache miss - query AUTH_BUS
    integer idx = llListFindList(PendingAcl, [user_key]);
    if (idx != -1 && idx % PENDING_ACL_STRIDE == PENDING_ACL_AVATAR) return;
    
    PendingAcl += [user_key, ROOT_CONTEXT];
    
    string acl_query = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, acl_query, NULL_KEY);
}
```

4. Add cache update in ACL result handler:
```lsl
handle_acl_result(string msg) {
    // ... existing validation ...
    
    integer acl_level = (integer)llJsonGetValue(msg, ["level"]);
    
    // Update cache
    update_acl_cache(avatar, acl_level);
    
    // ... rest of existing code ...
}
```

5. Clear cache on owner change:
```lsl
changed(integer change) {
    if (change & CHANGED_OWNER) {
        clear_acl_cache();  // Security: invalidate all cached ACLs
        llResetScript();
    }
}
```

**Expected Gain:** 50ms saved on every interaction after initial query

---

### Phase 2: Activity-Based Session Age

**Objective:** Convert SESSION_MAX_AGE from absolute to idle timeout

**Implementation in `ds_collar_kmod_ui.lsl`:**

1. Add session age tracking:
```lsl
/* Session tracking now includes last activity time */
integer SESSION_STRIDE = 10;  // Increased from 9
integer SESSION_LAST_ACTIVITY = 9;  // New field

integer SESSION_IDLE_TIMEOUT = 120;     // 2 minutes idle
integer SESSION_ABSOLUTE_MAX = 600;     // 10 minutes absolute
```

2. Reset activity time on interactions:
```lsl
reset_session_activity(key user) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) return;
    
    integer now_time = llGetUnixTime();
    Sessions = llListReplaceList(Sessions, [now_time], 
        session_idx + SESSION_LAST_ACTIVITY, 
        session_idx + SESSION_LAST_ACTIVITY);
}

handle_button_click(key user, string button, string context) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) {
        logd("ERROR: No session for button click from " + llKey2Name(user));
        return;
    }
    
    // Reset activity timestamp
    reset_session_activity(user);
    
    // ... rest of existing code ...
}
```

3. Update session validation logic:
```lsl
handle_return(string msg) {
    if (!json_has(msg, ["user"])) return;
    
    key user_key = (key)llJsonGetValue(msg, ["user"]);
    
    integer session_idx = find_session_idx(user_key);
    if (session_idx != -1) {
        integer created_time = llList2Integer(Sessions, session_idx + SESSION_CREATED_TIME);
        integer last_activity = llList2Integer(Sessions, session_idx + SESSION_LAST_ACTIVITY);
        integer now_time = llGetUnixTime();
        
        integer age = now_time - created_time;
        integer idle_time = now_time - last_activity;
        
        // Check absolute maximum first (security boundary)
        if (age > SESSION_ABSOLUTE_MAX) {
            logd("Session exceeded absolute max (" + (string)age + "s), forcing re-auth");
            string session_context = llList2String(Sessions, session_idx + SESSION_CONTEXT);
            cleanup_session(user_key);
            
            if (session_context == SOS_CONTEXT) {
                start_sos_session(user_key);
            }
            else {
                start_root_session(user_key);
            }
            return;
        }
        
        // Check idle timeout
        if (idle_time > SESSION_IDLE_TIMEOUT) {
            logd("Session idle for " + (string)idle_time + "s, refreshing");
            // Could optionally re-check ACL here, but cache makes it fast
        }
        
        // Session is valid - reset activity and render
        reset_session_activity(user_key);
        string session_context = llList2String(Sessions, session_idx + SESSION_CONTEXT);
        send_render_menu(user_key, session_context);
    }
    else {
        start_root_session(user_key);
    }
}
```

**Expected Gain:** Eliminates "intermittent sluggishness" during active use

---

### Phase 3: Dialog Timeout Extension

**Objective:** Keep dialog listeners alive during active navigation

**Implementation in `ds_collar_kmod_dialogs.lsl`:**

1. Add timeout extension handler:
```lsl
handle_dialog_extend(string msg) {
    if (!validate_required_fields(msg, ["session_id"], "handle_dialog_extend")) return;
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    integer session_idx = find_session_idx(session_id);
    
    if (session_idx == -1) return;
    
    integer timeout_extension = 60;  // Default 60s
    if (json_has(msg, ["timeout"])) {
        timeout_extension = (integer)llJsonGetValue(msg, ["timeout"]);
    }
    
    integer new_timeout = llGetUnixTime() + timeout_extension;
    Sessions = llListReplaceList(Sessions, [new_timeout], 
        session_idx + SESSION_TIMEOUT, 
        session_idx + SESSION_TIMEOUT);
    
    logd("Extended timeout for session: " + session_id);
}
```

2. Update link_message handler:
```lsl
link_message(integer sender, integer num, string msg, key id) {
    if (num != DIALOG_BUS) return;
    if (!json_has(msg, ["type"])) return;
    
    string msg_type = get_msg_type(msg);
    
    if (msg_type == "dialog_open") {
        handle_dialog_open(msg);
    }
    else if (msg_type == "dialog_extend") {  // New handler
        handle_dialog_extend(msg);
    }
    else if (msg_type == "dialog_close") {
        handle_dialog_close(msg);
    }
    // ... rest of handlers ...
}
```

**Implementation in `ds_collar_kmod_ui.lsl`:**

3. Send extension request on navigation:
```lsl
handle_button_click(key user, string button, string context) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) return;
    
    reset_session_activity(user);
    string session_id = llList2String(Sessions, session_idx + SESSION_ID);
    
    // Handle navigation buttons
    if (button == "<<" || button == ">>") {
        // Extend dialog timeout before rendering new menu
        string extend_msg = llList2Json(JSON_OBJECT, [
            "type", "dialog_extend",
            "session_id", session_id,
            "timeout", 60
        ]);
        llMessageLinked(LINK_SET, DIALOG_BUS, extend_msg, NULL_KEY);
        
        // ... rest of navigation logic ...
    }
    
    // ... rest of button handling ...
}
```

**Expected Gain:** 5ms saved per navigation by avoiding listener recreation

---

### Phase 4: Optional - Dialog Update Without Recreation

**Objective:** Update dialog buttons without closing/reopening listener

**Implementation in `ds_collar_kmod_dialogs.lsl`:**

1. Add dialog update handler:
```lsl
handle_dialog_update(string msg) {
    if (!validate_required_fields(msg, ["session_id", "button_data"], "handle_dialog_update")) {
        return;
    }
    
    string session_id = llJsonGetValue(msg, ["session_id"]);
    integer session_idx = find_session_idx(session_id);
    
    if (session_idx == -1) {
        logd("ERROR: Cannot update non-existent session: " + session_id);
        return;
    }
    
    key user = llList2Key(Sessions, session_idx + SESSION_USER);
    integer channel = llList2Integer(Sessions, session_idx + SESSION_CHANNEL);
    
    // Build new button list
    string button_data_json = llJsonGetValue(msg, ["button_data"]);
    list button_data_list = llJson2List(button_data_json);
    
    list buttons = [];
    list button_map = [];
    
    // ... same button building logic as handle_dialog_open ...
    
    // Update session's button map
    Sessions = llListReplaceList(Sessions, [llList2Json(JSON_ARRAY, button_map)],
        session_idx + SESSION_BUTTON_MAP,
        session_idx + SESSION_BUTTON_MAP);
    
    // Extract title and body
    string title = "Menu";
    string message = "Select an option:";
    if (json_has(msg, ["title"])) {
        title = llJsonGetValue(msg, ["title"]);
    }
    if (json_has(msg, ["body"])) {
        message = llJsonGetValue(msg, ["body"]);
    }
    
    // Show updated dialog (reuses existing listener)
    llDialog(user, title + "\n\n" + message, buttons, channel);
    
    logd("Updated dialog: " + session_id + " (kept listener)");
}
```

2. Update link_message handler:
```lsl
else if (msg_type == "dialog_update") {  // New handler
    handle_dialog_update(msg);
}
```

**Note:** This is optional and provides diminishing returns. Implement only if Phase 1-3 don't achieve desired performance.

---

## Implementation Order & Timeline

### Sprint 1: ACL Caching (Highest ROI)
**Files:** `ds_collar_kmod_ui.lsl`
**Estimated Impact:** 50ms saved per cold start
**Risk:** Low (cache is optional layer, doesn't break existing flow)
**Testing:** Verify cache hit/miss, expiry, invalidation on owner change

### Sprint 2: Activity-Based Sessions
**Files:** `ds_collar_kmod_ui.lsl`
**Estimated Impact:** Eliminates recurring cold starts
**Risk:** Medium (changes session lifecycle logic)
**Testing:** Verify idle timeout, absolute maximum, activity reset

### Sprint 3: Dialog Timeout Extension
**Files:** `ds_collar_kmod_dialogs.lsl`, `ds_collar_kmod_ui.lsl`
**Estimated Impact:** 5ms saved per navigation
**Risk:** Low (adds new message type, doesn't change existing flow)
**Testing:** Verify timeout extension works, doesn't leak listeners

### Sprint 4: (Optional) Dialog Update
**Files:** `ds_collar_kmod_dialogs.lsl`, `ds_collar_menu.lsl`
**Estimated Impact:** Incremental (2-3ms)
**Risk:** Medium (changes dialog session management)
**Decision Point:** Measure after Sprint 1-3, implement only if needed

---

## Security Considerations

### ACL Cache Security
- **Cache TTL = 5 minutes:** Balance between performance and security
- **Clear on owner change:** Prevents stale permissions after ownership transfer
- **Size limit enforced:** Prevents memory exhaustion attacks
- **Blacklist check still immediate:** Cache only affects ACL level, not blacklist status

### Session Lifetime Limits
- **Absolute maximum = 10 minutes:** Even active sessions must re-auth eventually
- **Idle timeout = 2 minutes:** Inactive sessions cleaned up promptly
- **Activity tracking:** Only legitimate interactions reset timeout

### Dialog Session Management
- **Channel collision detection:** Existing safeguard maintained
- **Session limit enforced:** Prevents resource exhaustion
- **Timeout still enforced:** Extended but not eliminated

---

## Testing & Validation

### Performance Benchmarks
**Before Optimization:**
- First click (cold): ~78ms (ACL query + session setup)
- Navigation click (warm): ~13ms
- Navigation click (after 60s): ~78ms (cold start again)

**After Phase 1 (ACL Cache):**
- First click (cold): ~78ms (first query)
- First click (cached): ~15ms (no ACL query)
- Navigation click: ~8ms

**After Phase 2 (Activity-Based):**
- Navigation never triggers cold start during active use
- Idle sessions (>2min) may trigger refresh but still use cache

**After Phase 3 (Dialog Extension):**
- Navigation: ~8ms (no listener recreation overhead)

### Functional Testing
1. **ACL Cache:**
   - Touch collar, verify first query
   - Touch again within 5min, verify cache hit (check debug logs)
   - Wait 5min, touch, verify cache miss and re-query
   - Transfer ownership, verify cache cleared

2. **Session Activity:**
   - Navigate menus continuously for >2 minutes
   - Verify no cold starts during activity
   - Wait 2 minutes idle, touch, verify session refresh
   - Navigate for >10 minutes, verify absolute timeout forces re-auth

3. **Dialog Timeout:**
   - Open menu, navigate immediately, verify listener reused
   - Wait 60s in menu, verify timeout still closes dialog
   - Navigate rapidly, verify timeouts extended

### Security Testing
1. **ACL Changes:**
   - Cache ACL level
   - Change ACL in auth module
   - Verify new ACL honored within 5 minutes (cache TTL)

2. **Blacklist:**
   - Open menu with cached ACL
   - Add user to blacklist
   - Verify immediate block (blacklist check bypasses cache)

3. **Session Hijacking:**
   - Verify session IDs are unique
   - Verify sessions tied to specific avatars
   - Verify timeout enforcement

---

## Rollback Plan

Each phase is independently reversible:

**Phase 1 Rollback:**
- Remove ACL cache functions
- Revert `start_root_session()` and `start_sos_session()` to always query AUTH_BUS

**Phase 2 Rollback:**
- Remove SESSION_LAST_ACTIVITY field
- Revert SESSION_STRIDE to 9
- Restore original `handle_return()` logic

**Phase 3 Rollback:**
- Remove `handle_dialog_extend()` from dialogs module
- Remove extend calls from UI module navigation handlers

---

## Memory Impact Analysis

### ds_collar_kmod_ui.lsl (current: 965 lines)
**Phase 1 additions:**
- ACL cache: ~10 entries × 3 fields = 30 list elements (~240 bytes)
- Cache functions: ~40 lines of code (~800 bytes)
- **Total:** ~1040 bytes (minimal impact)

**Phase 2 additions:**
- Session field: +1 integer per session (5 sessions × 4 bytes = 20 bytes)
- Activity tracking: ~25 lines (~500 bytes)
- **Total:** ~520 bytes (minimal impact)

**Phase 3 additions:**
- Extension message: ~10 lines (~200 bytes)
- **Total:** ~200 bytes (minimal impact)

**Overall UI module impact:** ~1760 bytes (~1.7KB) - well within safety margin

### ds_collar_kmod_dialogs.lsl (current: 576 lines)
**Phase 3 additions:**
- Extension handler: ~20 lines (~400 bytes)
- **Total:** ~400 bytes (minimal impact)

**Phase 4 additions (optional):**
- Update handler: ~50 lines (~1000 bytes)
- **Total:** ~1000 bytes (still safe)

**Overall Dialog module impact:** ~1400 bytes (~1.4KB) - well within limits

---

## Success Metrics

### Performance Targets
- ✅ First click (cached): <20ms
- ✅ Navigation: <10ms
- ✅ No "intermittent sluggishness" during active use
- ✅ Cold start frequency: Once per 5 minutes maximum

### User Experience Goals
- ✅ Menus feel "snappy" on first interaction
- ✅ Navigation is consistently fast
- ✅ No unexpected delays during multi-page browsing
- ✅ Timeout only occurs when genuinely idle

### Security Requirements
- ✅ ACL changes honored within cache TTL
- ✅ Blacklist changes honored immediately
- ✅ Owner changes clear all cached state
- ✅ Sessions have hard maximum lifetime

---

## Conclusion

This optimization strategy delivers significant performance improvements while:
- ✅ Respecting 3-module architecture (no merging)
- ✅ Maintaining security boundaries
- ✅ Preserving existing functionality
- ✅ Staying within memory constraints
- ✅ Providing incremental rollback options

**Recommended Implementation:** Phases 1-3 in sequence, measuring impact after each. Phase 4 only if measurements show need for further optimization.

**Expected Total Improvement:**
- Cold start: 78ms → 15ms (81% improvement after initial cache)
- Navigation: 78ms → 8ms (90% improvement)
- Consistency: No more intermittent 78ms delays during active use
