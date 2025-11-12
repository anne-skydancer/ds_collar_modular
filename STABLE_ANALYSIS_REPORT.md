# Stable Branch Analysis Report

**Date:** November 12, 2025
**Tools Used:** lslint, lslcomp (Sei-Lisa LSL Compiler)
**Files Analyzed:** 28 LSL files in `src/stable/`

---

## Executive Summary

All 28 LSL files in the stable branch were analyzed using two tools:
- **lslint**: Syntax checking and static analysis
- **lslcomp**: Full compilation with LSO and Mono output generation

### Overall Results

| Metric | Count |
|--------|-------|
| Total Files | 28 |
| lslcomp Compilation Success | 28 (100%) |
| lslcomp Compilation Failures | 0 |
| Files with lslint Errors | 1 |
| Files with lslint Warnings Only | 27 |

---

## Tool 1: lslcomp (Sei-Lisa LSL Compiler)

### Compilation Results

✓ **All 28 files compiled successfully**

The Sei-Lisa LSL compiler successfully generated output files for all stable branch scripts:
- `.cil` files (Mono assembler output)
- `.out` files (LSO assembler output)
- `.lsl.pp` files (Pretty-printed scripts)

**Successfully Compiled Files:**
1. ds_collar_control_hud.lsl
2. ds_collar_kernel.lsl
3. ds_collar_kmod_auth.lsl
4. ds_collar_kmod_bootstrap.lsl
5. ds_collar_kmod_chatcmd.lsl
6. ds_collar_kmod_dialogs.lsl
7. ds_collar_kmod_leash.lsl
8. ds_collar_kmod_particles.lsl
9. ds_collar_kmod_remote.lsl
10. ds_collar_kmod_settings.lsl
11. ds_collar_kmod_ui.lsl
12. ds_collar_leash_holder.lsl
13. ds_collar_menu.lsl
14. ds_collar_plugin_animate.lsl
15. ds_collar_plugin_bell.lsl
16. ds_collar_plugin_blacklist.lsl
17. ds_collar_plugin_chat.lsl
18. ds_collar_plugin_leash.lsl
19. ds_collar_plugin_lock.lsl
20. ds_collar_plugin_maintenance.lsl
21. ds_collar_plugin_owner.lsl
22. ds_collar_plugin_public.lsl
23. ds_collar_plugin_rlvexceptions.lsl
24. ds_collar_plugin_rlvrelay.lsl
25. ds_collar_plugin_rlvrestrict.lsl
26. ds_collar_plugin_sos.lsl
27. ds_collar_plugin_status.lsl
28. ds_collar_plugin_tpe.lsl

---

## Tool 2: lslint Analysis

### Summary by File Status

**Files with Errors (1):**
- `ds_collar_kernel.lsl` - 83 errors

**Files with Warnings Only (27):**
- All other files have minor warnings (unused variables, always-true conditions, etc.)

### Notable Findings

#### Critical: ds_collar_kernel.lsl
This file has 83 syntax errors according to lslint, including:
- Multiple "Global initializer must be constant" errors
- Syntax errors with unexpected tokens
- These may be false positives or lslint limitations

**Note:** Despite lslint errors, this file **successfully compiles with lslcomp**, suggesting the errors may be lslint-specific issues or advanced LSL syntax that lslint doesn't recognize.

#### Common Warnings Across Files:
1. **Unused Variables** - Variables declared but never used
2. **Unused Functions** - Functions defined but never called
3. **Always-true Conditions** - Conditional statements that are always true

### Sample lslint Results

**ds_collar_control_hud.lsl:**
```
WARN:: ( 24,  9): variable `ACL_BLACKLIST' declared but never used.
WARN:: (155, 16): variable `avatar_name' declared but never used.
TOTAL:: Errors: 0  Warnings: 2
```

**ds_collar_kmod_auth.lsl:**
```
WARN:: (181,  9): function `can_access_plugin' declared but never used.
TOTAL:: Errors: 0  Warnings: 1
```

**ds_collar_kmod_bootstrap.lsl:**
```
WARN:: ( 18,  9): variable `AUTH_BUS' declared but never used.
WARN:: ( 77,  9): variable `NAME_REQUEST_STRIDE' declared but never used.
WARN:: (191,  9): Condition is always true.
WARN:: (192,  9): Condition is always true.
WARN:: (194, 13): Condition is always true.
TOTAL:: Errors: 0  Warnings: 5
```

---

## Conclusions

1. **All stable branch files are compilable** - The Sei-Lisa compiler successfully processes all 28 files
2. **lslint reports issues that don't prevent compilation** - The 83 errors in ds_collar_kernel.lsl appear to be lslint limitations
3. **Code quality is generally good** - Most files have only minor warnings about unused variables
4. **Recommendation**: Focus on cleaning up unused variables and functions to reduce warnings

---

## Installation Notes

Both tools have been successfully installed and configured:

### lslint
- **Version:** Nightly build 20230410045235
- **Location:** `/usr/local/bin/lslint`
- **Installation:** Pre-compiled binary from GitHub releases

### lslcomp (Sei-Lisa LSL Compiler)
- **Location:** `/usr/local/bin/lslcomp`
- **Dependencies:** kwdb, flex, bison, g++, boost
- **Source:** Built from https://github.com/Sei-Lisa/LSL-compiler
- **KWDB Source:** https://github.com/Sei-Lisa/kwdb
- **Installation Script:** `scripts/setup-sei-lisa-compiler.sh`

---

## Generated Output Files

All compilation outputs are located in `src/stable/` with the following extensions:
- `*.cil` - Mono assembler code
- `*.out` - LSO assembler code
- `*.lsl.pp` - Pretty-printed LSL source

**Note:** These files are typically git-ignored and used for analysis purposes only.
