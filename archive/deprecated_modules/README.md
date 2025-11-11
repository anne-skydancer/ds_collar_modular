# Deprecated Modules Archive

This directory contains modules that have been superseded by improved implementations.

## ds_collar_kmod_leash_v2.0_multimode.lsl

**Deprecated:** 2025-11-04
**Replaced By:** `src/stable/ds_collar_kmod_leash.lsl` (v3.0 UNIFIED TETHER)
**Reason:** Architectural improvement - v3.0 eliminates redundant state tracking

### Why Deprecated?

The v2.0 MULTI-MODE version used an explicit `LeashMode` variable to track whether the leash was in Avatar, Coffle, or Post mode. This created potential for state desynchronization bugs where the mode variable could get out of sync with the actual key values.

**v2.0 Approach (deprecated):**
```lsl
integer LeashMode = MODE_AVATAR;  // Explicit mode tracking
key LeashTarget = NULL_KEY;
key CoffleTargetAvatar = NULL_KEY;

// Had to manually set mode everywhere:
LeashMode = MODE_COFFLE;
LeashTarget = target_object;
CoffleTargetAvatar = avatar;
```

**v3.0 Approach (current):**
```lsl
// No mode variable! State is implicitly determined:
//   - LeashTarget == NULL_KEY: Avatar mode
//   - LeashTarget != NULL_KEY && CoffleTargetAvatar != NULL_KEY: Coffle
//   - LeashTarget != NULL_KEY && CoffleTargetAvatar == NULL_KEY: Post

key LeashTarget = NULL_KEY;
key CoffleTargetAvatar = NULL_KEY;

// State is automatically correct based on keys:
LeashTarget = target_object;
CoffleTargetAvatar = avatar;
// Mode is implicitly COFFLE
```

### Benefits of v3.0

1. **No state desync bugs** - impossible to have mode/key mismatch
2. **Simpler code** - single unified follow path vs. three separate branches
3. **Better maintainability** - fewer places to update during changes
4. **Smaller memory footprint** - one less global variable
5. **Self-documenting** - state is clear from key values

### Migration Notes

If you need to reference the old implementation for any reason, it's preserved here. However, the v3.0 version is functionally identical with a cleaner architecture.

**See:** `/LEASH_MODULE_COMPARISON.md` for detailed analysis.
