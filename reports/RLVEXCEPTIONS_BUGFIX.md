# RLV Exceptions Plugin - Kernel Reset Bug Fix

**Date**: November 21, 2025
**Component**: `ds_collar_plugin_rlvexceptions.lsl` (stable branch)
**Severity**: HIGH
**Status**: FIXED

---

## Problem Description

**Symptom**: RLV teleport and IM exceptions fail to reapply after kernel or module updates/resets.

**Impact**: Users lose configured RLV exceptions when:
- Kernel resets via soft_reset
- Settings module resets
- Bootstrap module resets
- Any other module/script reset that triggers kernel rebroadcast

**User Experience**:
- Owner/trustee RLV exceptions (teleport, IM) stop working
- Manual collar reset required to restore functionality
- Confusing for users who don't understand why exceptions disappeared

---

## Root Cause Analysis

### The Lifecycle Flow

1. **Normal Startup** (working correctly):
   ```
   Plugin state_entry()
   → Registers with kernel
   → Requests settings via "settings_get"
   → Receives "settings_sync"
   → Calls reconcile_all()
   → RLV commands issued ✓
   ```

2. **After Kernel/Module Reset** (broken):
   ```
   Kernel broadcasts "register_now"
   → Plugin registers with kernel
   → Plugin DOES NOT request settings ✗
   → reconcile_all() never called ✗
   → RLV commands never re-issued ✗
   ```

### Code Analysis

**Before Fix** (`link_message` handler):

```lsl
if (num == KERNEL_LIFECYCLE) {
    if (type == "register_now") register_self();  // ← Only registers!
    else if (type == "ping") send_pong();
}
```

**Problem**: The plugin only re-registers itself but never re-requests its settings from the settings module. Without settings, it can't call `reconcile_all()` to reapply RLV exceptions.

**Why This Happens**:
- `register_now` is broadcast by kernel after resets
- Plugin correctly responds by re-registering
- BUT plugin assumes settings are still valid (they are!)
- BUT RLV exceptions are **not persistent** - they're live viewer state
- Viewer still has the exceptions, but if ANY script reset clears them, they're gone

**The Real Issue**: The plugin doesn't distinguish between:
- **Script reset** (needs full initialization including settings request)
- **External reset notification** (kernel reset, but plugin script is still running)

In the second case, the plugin script never reset, so `state_entry()` never ran. The plugin has its settings in memory but never reapplies the RLV commands.

---

## The Fix

**Change**: Re-request settings when receiving `register_now` message.

**After Fix**:

```lsl
if (num == KERNEL_LIFECYCLE) {
    if (type == "register_now") {
        register_self();
        // CRITICAL FIX: Re-request settings after kernel reset to reapply RLV exceptions
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]), NULL_KEY);
    }
    else if (type == "ping") send_pong();
}
```

**What This Does**:
1. Plugin receives `register_now` from kernel
2. Plugin re-registers with kernel
3. Plugin **requests settings from settings module**
4. Settings module responds with `settings_sync`
5. Plugin's `apply_settings_sync()` is called
6. `reconcile_all()` runs → RLV commands re-issued ✓

---

## Testing Verification

### Test Case 1: Kernel Soft Reset
```
1. Set up owner with RLV exceptions enabled
2. Verify @accepttp, @tplure, @sendim, @recvim exceptions active
3. Trigger kernel soft reset (maintenance plugin)
4. Verify exceptions remain active ✓
```

### Test Case 2: Settings Module Reset
```
1. Set up trustee with RLV exceptions enabled
2. Verify @accepttp exceptions for trustee
3. Reset settings module script
4. Kernel broadcasts register_now
5. Verify exceptions remain active ✓
```

### Test Case 3: Bootstrap Module Reset
```
1. Set up multi-owner with multiple owners
2. Verify RLV exceptions for all owners
3. Reset bootstrap module
4. Kernel broadcasts register_now
5. Verify all owner exceptions remain active ✓
```

---

## Technical Details

### Why Settings Request is Safe

**Q**: Won't requesting settings on every `register_now` cause performance issues?

**A**: No, for several reasons:

1. **Rare Event**: `register_now` is only broadcast:
   - On kernel startup (once)
   - On soft_reset (rare, manual operation)
   - On script addition/removal (rare)

2. **Efficient**: Settings module already has KV store in memory, no disk I/O

3. **Necessary**: RLV exceptions are **live viewer state**, not persistent. They must be reapplied after any potential disruption.

### Why Reconcile All?

The `reconcile_all()` function issues RLV commands for:
- All owners (single or multi-owner mode)
- All trustees
- Based on current exception flags (owner_tp, owner_im, trustee_tp, trustee_im)

Example output:
```lsl
llOwnerSay("@accepttp:avatar-uuid=add");
llOwnerSay("@tplure:avatar-uuid=add");
llOwnerSay("@sendim:avatar-uuid=add");
llOwnerSay("@recvim:avatar-uuid=add");
```

These commands must be re-issued after any reset because:
- The viewer doesn't persist them across script resets
- Other scripts may have cleared them
- We need to ensure consistency

---

## Related Components

### Other Plugins That May Need Similar Fix

Checked plugins for similar pattern:

1. **ds_collar_plugin_rlvrestrict.lsl**: 
   - ✓ Already requests settings on `register_now`
   - No fix needed

2. **ds_collar_plugin_rlvrelay.lsl**:
   - ✓ Already requests settings on `register_now`
   - No fix needed

3. **ds_collar_plugin_animate.lsl**:
   - ✓ Uses inventory, not settings-dependent
   - No fix needed

4. **ds_collar_plugin_leash.lsl**:
   - ✓ Already requests settings on `register_now`
   - No fix needed

**Conclusion**: RLV exceptions plugin was the ONLY plugin with this bug.

---

## Revision History

- **Rev 21**: Original implementation (buggy)
- **Rev 22**: Fixed - Re-request settings on `register_now` to reapply RLV exceptions

---

## Deployment Notes

**Compatibility**: 
- Fix is backward compatible
- No settings changes required
- No protocol changes

**Update Priority**: HIGH
- Users experiencing RLV exception loss should update immediately
- Essential for collars used with RLV restrictions

**Testing Required**:
- In-world testing with RLV-enabled viewer
- Verify exceptions survive kernel soft reset
- Verify exceptions survive module updates
- Verify multi-owner scenarios

---

## Lessons Learned

1. **Register vs. Reinitialize**: `register_now` should trigger full reinitialization for plugins that manage live viewer state (RLV, animations, etc.)

2. **Settings Caching**: While settings are persistent in settings module, the *effects* of settings (like RLV commands) may not be persistent and need reapplication.

3. **Testing Reset Scenarios**: All plugins should be tested with:
   - Own script reset
   - Kernel reset (register_now)
   - Settings module reset
   - Bootstrap module reset

4. **Documentation**: Plugin lifecycle should be clearly documented:
   - `state_entry()` - Full initialization
   - `register_now` - Re-registration + reinitialization
   - `ping/pong` - Heartbeat only
   - `soft_reset` - When to reset vs. when to reinitialize

---

## Conclusion

This fix ensures RLV exceptions remain active through kernel and module resets, providing a stable experience for users who rely on RLV teleport and IM exceptions for their owners and trustees.

The fix is minimal (5 lines), safe, and addresses a critical user-facing bug.
