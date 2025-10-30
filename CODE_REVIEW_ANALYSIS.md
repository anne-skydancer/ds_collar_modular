# Code Review Analysis: Long-Touch SOS Feature
## Branch: claude/add-long-touch-support-011CUddHQS8UsVo238CABTXw

This document analyzes critical and high-priority issues found in the code review.

---

## P0 CRITICAL: Plugin Filtering Breaks Root Sessions

**File:** `src/stable/ds_collar_kmod_ui.lsl:203`

### Issue
The `create_session()` function now filters plugins using `context == context_filter`. When a root session is created with `ROOT_CONTEXT = "core_root"`, it filters for plugins matching exactly "core_root". However, actual plugins register with their own specific contexts like:
- `"core_leash"`
- `"core_owner"`
- `"core_animate"`
- `"core_rlvrelay"`
- etc.

### Impact
**This completely breaks the root menu.** All root sessions end up with an empty filtered list, showing "No plugins are currently installed" to users. The entire UI is non-functional except for the SOS menu.

### Current Code (lines 198-208)
```lsl
while (i < len) {
    string context = llList2String(AllPlugins, i + PLUGIN_CONTEXT);
    string label = llList2String(AllPlugins, i + PLUGIN_LABEL);
    integer min_acl = llList2Integer(AllPlugins, i + PLUGIN_MIN_ACL);

    if (acl >= min_acl && context == context_filter) {
        filtered += [context, label, min_acl];
    }

    i += PLUGIN_STRIDE;
}
```

### Root Cause
The filtering logic was changed to support SOS context filtering, but it incorrectly applies the same logic to root sessions. The SOS context should be special-cased, while root sessions should show all plugins that meet ACL requirements.

### Proposed Fix Strategy
**Option 1: Special-case SOS filtering**
```lsl
if (acl >= min_acl) {
    // For SOS context, only show SOS-tagged plugins
    if (context_filter == SOS_CONTEXT && context != SOS_CONTEXT) {
        // Skip non-SOS plugins when in SOS context
        i += PLUGIN_STRIDE;
        continue;
    }
    // For root context or matching plugins, include
    filtered += [context, label, min_acl];
}
```

**Option 2: Explicit context matching logic**
```lsl
integer should_include = FALSE;

if (acl >= min_acl) {
    if (context_filter == SOS_CONTEXT) {
        // SOS context: only include SOS plugins
        should_include = (context == SOS_CONTEXT);
    } else {
        // Root context: include all non-SOS plugins
        should_include = (context != SOS_CONTEXT);
    }

    if (should_include) {
        filtered += [context, label, min_acl];
    }
}
```

**Recommendation:** Option 2 is clearer and more maintainable. It explicitly defines that:
- SOS sessions only show SOS plugins
- Root sessions show all non-SOS plugins (the normal collar functions)

---

## P1 HIGH: Paging Buttons Don't Respect Session Context

**File:** `src/stable/ds_collar_kmod_ui.lsl:454-472`

### Issue
The `handle_button_click()` function always calls `show_root_menu(user)` when handling pagination buttons ("<<" and ">>"), regardless of the current session context.

### Impact
If a user is viewing the SOS emergency menu and clicks to navigate pages, they're immediately kicked back to the root menu, completely breaking the SOS navigation flow.

### Current Code (lines 454-472)
```lsl
if (button == "<<") {
    current_page -= 1;
    if (current_page < 0) current_page = total_pages - 1;
    Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
    show_root_menu(user);  // ❌ Always root!
    return;
}

if (button == "Close") {
    cleanup_session(user);
    return;
}

if (button == ">>") {
    current_page += 1;
    if (current_page >= total_pages) current_page = 0;
    Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);
    show_root_menu(user);  // ❌ Always root!
    return;
}
```

### Root Cause
The session stores context information but the paging logic doesn't retrieve and use it.

### Proposed Fix
Retrieve the session context and call the appropriate menu function:

```lsl
// Get session context (need to add SESSION_CONTEXT to session data if not present)
string session_context = llList2String(Sessions, session_idx + SESSION_CONTEXT);

if (button == "<<") {
    current_page -= 1;
    if (current_page < 0) current_page = total_pages - 1;
    Sessions = llListReplaceList(Sessions, [current_page], session_idx + SESSION_PAGE, session_idx + SESSION_PAGE);

    // Respect the session context
    if (session_context == SOS_CONTEXT) {
        show_sos_menu(user);
    } else {
        show_root_menu(user);
    }
    return;
}

// Same for ">>" button
```

**Note:** Need to verify if `SESSION_CONTEXT` is already stored in the Sessions list. If not, it must be added to the session data structure.

---

## SECURITY: Emergency Relay Clear Missing Wearer Check

**File:** `src/stable/ds_collar_plugin_rlvrelay.lsl:838-843`

### Issue
The `emergency_relay_clear` handler executes for ANY message on UI_BUS with that type, without verifying the sender is the collar wearer.

### Impact
**Critical security vulnerability.** Any script in the linkset can send a link_message on UI_BUS to trigger emergency relay clear, even if not authorized.

### Current Code (lines 838-843)
```lsl
else if (msg_type == "emergency_relay_clear") {
    // Emergency SOS clear - bypasses ACL (ACL 0 emergency access)
    safeword_clear_all();
    llOwnerSay("[SOS] All relay restrictions cleared.");
    logd("Emergency relay clear executed");
}
```

### Root Cause
Missing identity verification. The emergency functions are designed to bypass ACL for the wearer, but they don't verify that the request actually came from the wearer.

### Proposed Fix
Extract and validate the sender ID from the message:

```lsl
else if (msg_type == "emergency_relay_clear") {
    // Emergency SOS clear - only allow if sender is the collar wearer
    if (json_has(msg, ["id"])) {
        string sender_id = llJsonGetValue(msg, ["id"]);
        if (sender_id == (string)llGetOwner()) {
            safeword_clear_all();
            llOwnerSay("[SOS] All relay restrictions cleared.");
            logd("Emergency relay clear executed");
        } else {
            logd("Emergency relay clear denied: sender is not owner.");
        }
    } else {
        logd("Emergency relay clear denied: missing id field.");
    }
}
```

**Note:** Need to verify that the SOS plugin actually sends the `id` field in its emergency messages. Looking at plugin_sos.lsl:132-134, it currently sends:
```lsl
llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
    "type", "emergency_relay_clear"
]), CurrentUser);
```

The `id` is passed as the 4th parameter (`CurrentUser`), not in the JSON message. So the fix should check the `id` parameter instead:

```lsl
else if (msg_type == "emergency_relay_clear") {
    // Emergency SOS clear - only allow if sender is the collar wearer
    // The id parameter contains the requesting user's key
    if (id == llGetOwner()) {
        safeword_clear_all();
        llOwnerSay("[SOS] All relay restrictions cleared.");
        logd("Emergency relay clear executed");
    } else {
        logd("Emergency relay clear denied: sender " + llKey2Name(id) + " is not wearer.");
    }
}
```

---

## SECURITY: Emergency Restrict Clear Missing Wearer Check

**File:** `src/stable/ds_collar_plugin_rlvrestrict.lsl:609-614`

### Issue
Identical to the relay clear issue - the handler doesn't verify the sender is the wearer.

### Impact
**Critical security vulnerability.** Any script can trigger emergency RLV restriction clearing.

### Current Code (lines 609-614)
```lsl
else if (type == "emergency_restrict_clear") {
    // Emergency SOS clear - bypasses ACL (ACL 0 emergency access)
    remove_all_restrictions();
    llOwnerSay("[SOS] All RLV restrictions cleared.");
    logd("Emergency restrict clear executed");
}
```

### Proposed Fix
```lsl
else if (type == "emergency_restrict_clear") {
    // Emergency SOS clear - only allow if sender is the collar wearer
    // The id parameter contains the requesting user's key
    if (id == llGetOwner()) {
        remove_all_restrictions();
        llOwnerSay("[SOS] All RLV restrictions cleared.");
        logd("Emergency restrict clear executed");
    } else {
        logd("Emergency restrict clear denied: sender " + llKey2Name(id) + " is not wearer.");
    }
}
```

---

## SECURITY: Emergency Leash Release Missing Wearer Check

**File:** `src/stable/ds_collar_kmod_leash.lsl:991-999`

### Issue
Same pattern - emergency leash release doesn't verify the sender is the wearer.

### Impact
**Critical security vulnerability.** Any script can trigger emergency leash release.

### Current Code (lines 991-999)
```lsl
if (msg_type == "emergency_leash_release") {
    // Emergency SOS release - bypasses ACL (ACL 0 emergency access)
    if (Leashed) {
        release_leash_internal(id);
        llOwnerSay("[SOS] Emergency leash release executed.");
        logd("Emergency leash release executed");
    }
    return;
}
```

### Proposed Fix
```lsl
if (msg_type == "emergency_leash_release") {
    // Emergency SOS release - only allow if sender is the collar wearer
    // The id parameter contains the requesting user's key
    if (id == llGetOwner()) {
        if (Leashed) {
            release_leash_internal(id);
            llOwnerSay("[SOS] Emergency leash release executed.");
            logd("Emergency leash release executed");
        }
    } else {
        logd("Emergency leash release denied: sender " + llKey2Name(id) + " is not wearer.");
    }
    return;
}
```

---

## SECURITY: SOS Context Check Uses Wrong Variable

**File:** `src/stable/ds_collar_kmod_remote.lsl:535`

### Issue
The security check to restrict SOS context to the collar wearer uses `CollarOwner` (the owner of the collar, ACL 5) instead of `llGetOwner()` (the wearer of the collar).

### Impact
**Security logic error.** Non-wearers who are the collar owner can access SOS context remotely, which should only be available to the person wearing the collar. Conversely, if the wearer is not the owner, they can't access their own SOS menu remotely (though this is less critical since SOS is primarily for local long-touch).

### Current Code (lines 532-538)
```lsl
// SECURITY: Only allow SOS context for collar wearer
// Non-wearers requesting SOS get downgraded to root menu
string final_context = requested_context;
if (requested_context == SOS_CONTEXT && avatar_key != CollarOwner) {
    final_context = ROOT_CONTEXT;
    logd("SOS context request from non-wearer " + llKey2Name(avatar_key) + " downgraded to root");
}
```

### Root Cause
Confusion between:
- `CollarOwner` - The primary owner (ACL 5), stored from settings
- `llGetOwner()` - The current wearer of the collar (the avatar who owns the object)

### Proposed Fix
```lsl
// SECURITY: Only allow SOS context for collar wearer
// Non-wearers requesting SOS get downgraded to root menu
string final_context = requested_context;
if (requested_context == SOS_CONTEXT && avatar_key != llGetOwner()) {
    final_context = ROOT_CONTEXT;
    logd("SOS context request from non-wearer " + llKey2Name(avatar_key) + " downgraded to root");
}
```

---

## MINOR: Incorrect Button Layout Comment

**File:** `src/stable/ds_collar_plugin_sos.lsl:102-106`

### Issue
The comment describing the llDialog button layout is incorrect.

### Impact
Low - documentation/maintainability issue only.

### Current Code (lines 102-106)
```lsl
// Back button at index 0, followed by 3 action buttons
// llDialog layout (bottom-left to top-right):
// [Clear Relay]
// [Back] [Unleash] [Clear RLV]
list buttons = ["Back", "Unleash", "Clear RLV", "Clear Relay"];
```

### Actual Layout
llDialog renders 3 buttons per row, bottom to top, left to right. With 4 buttons:
```
Row 2: [Clear Relay]
Row 1: [Back] [Unleash] [Clear RLV]
```

### Proposed Fix
```lsl
// llDialog layout (3 buttons per row, bottom-left to top-right):
// Row 2: [Clear Relay]
// Row 1: [Back] [Unleash] [Clear RLV]
list buttons = ["Back", "Unleash", "Clear RLV", "Clear Relay"];
```

Or more accurately:
```lsl
// llDialog displays buttons in rows of 3, bottom-left to top-right
// Row 1 (bottom): [Back] [Unleash] [Clear RLV]
// Row 2 (top):    [Clear Relay]
list buttons = ["Back", "Unleash", "Clear RLV", "Clear Relay"];
```

---

## MINOR: Redundant 'found' Check

**File:** `src/stable/ds_collar_kmod_ui.lsl:808-810`

### Issue
The code uses `jump recorded` when a match is found (line 803), so execution only reaches line 808 if `found == FALSE`. The conditional is therefore redundant.

### Impact
Minimal - minor code inefficiency and reduced readability.

### Current Code (lines 800-816)
```lsl
if (llList2Key(TouchData, j + TOUCH_DATA_KEY) == toucher) {
    TouchData = llListReplaceList(TouchData, [llGetTime()], j + TOUCH_DATA_START_TIME, j + TOUCH_DATA_START_TIME);
    found = TRUE;
    jump recorded;
}
j += TOUCH_DATA_STRIDE;
}

if (found == FALSE) {
    TouchData += [toucher, llGetTime()];
}

@recorded;
logd("Touch start from " + llKey2Name(toucher));
```

### Proposed Fix
```lsl
if (llList2Key(TouchData, j + TOUCH_DATA_KEY) == toucher) {
    TouchData = llListReplaceList(TouchData, [llGetTime()], j + TOUCH_DATA_START_TIME, j + TOUCH_DATA_START_TIME);
    found = TRUE;
    jump recorded;
}
j += TOUCH_DATA_STRIDE;
}

// If we reach here, toucher was not found in TouchData
TouchData += [toucher, llGetTime()];

@recorded;
logd("Touch start from " + llKey2Name(toucher));
```

**Note:** This actually changes behavior slightly - the comment should clarify that if we jump to @recorded, we skip the TouchData append.

---

## Summary & Priority Order

### Critical (Fix Immediately)
1. **P0 - Plugin Filtering:** Breaks entire root menu - NO plugins visible
2. **Security - Emergency handlers:** Missing wearer verification (3 instances)

### High Priority
3. **P1 - Paging buttons:** Breaks SOS menu navigation
4. **Security - SOS context check:** Uses wrong variable for wearer check

### Low Priority
5. **Minor - Comment accuracy:** Documentation issues
6. **Minor - Redundant check:** Code cleanup

---

## Testing Checklist

After fixes are applied:

### P0 Testing
- [ ] Root menu displays all appropriate plugins
- [ ] Root menu respects ACL filtering (only shows plugins user has access to)
- [ ] SOS menu only shows SOS plugin
- [ ] Both menus work correctly for different ACL levels

### P1 Testing
- [ ] Paging through SOS menu with << and >> stays in SOS context
- [ ] Paging through root menu with << and >> stays in root context
- [ ] Multi-page menus work correctly in both contexts

### Security Testing
- [ ] Emergency leash release only works when triggered by wearer
- [ ] Emergency relay clear only works when triggered by wearer
- [ ] Emergency RLV clear only works when triggered by wearer
- [ ] Unauthorized scripts cannot trigger emergency functions
- [ ] SOS context via remote HUD only works for wearer, not for owner
- [ ] Remote owner gets downgraded to root menu when requesting SOS

### Integration Testing
- [ ] Long-touch triggers SOS menu for wearer
- [ ] Long-touch by non-wearer doesn't trigger SOS
- [ ] SOS emergency functions actually clear restrictions/release leash
- [ ] Normal menu flow still works after SOS usage
- [ ] Session cleanup happens correctly in all scenarios

---

## Additional Considerations

### Session Data Structure
The P1 fix requires session context to be stored. Verify that the `Sessions` list includes a `SESSION_CONTEXT` field. If not, the session data structure needs to be updated:

```lsl
// Current session structure (verify this)
// [user_key, acl, is_blacklisted, current_page, total_pages, session_id, filtered_start, created_time]

// May need to add:
// [user_key, acl, is_blacklisted, current_page, total_pages, session_id, filtered_start, created_time, context]
```

### Message Protocol Verification
The emergency handler fixes assume the `id` parameter of `link_message` contains the requester's key. Verify that the SOS plugin correctly passes `CurrentUser` as the 4th parameter in all emergency message calls.

### Alternative Security Approach
Instead of checking `id == llGetOwner()` in each emergency handler, consider:
1. Having the UI module validate wearer identity before forwarding emergency messages
2. Using a different channel for verified wearer-only emergency commands
3. Including a cryptographic session token in emergency messages

However, the simple `id` check is probably sufficient for this use case.
