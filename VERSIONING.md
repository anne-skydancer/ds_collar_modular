# DS Collar Modular - Versioning Specification

> **Official versioning scheme for DS Collar Modular project**
>
> This document defines how version numbers are assigned to scripts based on the type and scope of changes.

---

## Version Format

```
[MAJOR].[MINOR]_[ENHANCEMENT]
```

**Components:**
- **MAJOR** - Major version number (integer)
- **MINOR** - Minor version number (integer, represents feature additions)
- **ENHANCEMENT** - Enhancement letter (a, b, c, etc., represents non-breaking improvements)

---

## Version Change Rules

### 1. Security Fixes, Patches, and Hotfixes → **NO VERSION CHANGE**

**Definition:**
- Security vulnerability fixes
- Bug fixes that restore intended behavior
- Hotfixes for critical issues
- Performance optimizations that don't change behavior
- Code refactoring without functionality changes

**Versioning:**
- Version number **remains unchanged**
- Update header notes to document the fix

**Examples:**
```lsl
// BEFORE FIX
/* MODULE: ds_collar_kernel.lsl (v1.0 - Consolidated ABI)
   SECURITY AUDIT: ALL ISSUES FIXED */

// AFTER SECURITY FIX (version stays 1.0)
/* MODULE: ds_collar_kernel.lsl (v1.0 - Consolidated ABI)
   SECURITY AUDIT: ALL ISSUES FIXED

   SECURITY FIXES APPLIED:
   - [CRITICAL] Fixed authorization bypass in soft reset (2025-10-28)
   - [MEDIUM] Added overflow protection for timestamps (2025-10-28) */
```

**Rationale:** Security fixes and bug patches are maintenance activities that restore the contract promised by the current version. They do not add new functionality or change behavior beyond fixing defects.

---

### 2. Enhancements → **MINOR INCREMENT** (underscore notation)

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
- After `_z`, use `_aa`, `_ab`, etc.

**Examples:**

| Current Version | Change | New Version |
|----------------|--------|-------------|
| `1.0` | Add volume slider to bell | `1.0_a` |
| `1.0_a` | Improve dialog layout | `1.0_b` |
| `1.0_b` | Add color options to existing menu | `1.0_c` |
| `2.3` | Enhance animation smoothness | `2.3_a` |

**Code Example:**
```lsl
// BEFORE ENHANCEMENT
/* PLUGIN: ds_collar_plugin_bell.lsl (v1.0 - Consolidated ABI)

   FEATURES:
   - Bell visibility toggle
   - Sound on/off */

// AFTER ENHANCEMENT (volume control added)
/* PLUGIN: ds_collar_plugin_bell.lsl (v1.0_a - Volume Control)

   FEATURES:
   - Bell visibility toggle
   - Sound on/off
   - Volume adjustment (10% increments) */
```

**Rationale:** Enhancements improve existing functionality without fundamentally changing what the script does or adding entirely new capabilities. The underscore notation indicates these are "polish" updates to the current feature set.

---

### 3. Feature Additions → **DOT INCREMENT** (minor version)

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
- MAJOR version stays the same

**Examples:**

| Current Version | Change | New Version |
|----------------|--------|-------------|
| `1.0` | Add TPE mode plugin | `1.1` |
| `1.1` | Add RLV relay plugin | `1.2` |
| `1.2_c` | Add blacklist management | `1.3` |
| `2.0` | Add coffle system | `2.1` |

**Code Example:**
```lsl
// NEW FEATURE - version increments from 1.2 to 1.3
/* PLUGIN: ds_collar_plugin_trustees.lsl (v1.3 - New Feature)

   PURPOSE: Trustee management system

   FEATURES:
   - Add trustees via sensor
   - Remove trustees from list
   - View current trustees */
```

**Rationale:** Feature additions expand the capabilities of the system. Each new feature represents a meaningful expansion of what the collar can do, warranting a version increment that clearly signals "this version can do more than the last."

---

### 4. Major Overhauls → **MAJOR VERSION CHANGE**

**Definition:**
- Complete architectural redesign
- Breaking API/ABI changes
- Migration from old system to new system
- Fundamental changes to how the system works
- Removal of deprecated features
- Changes requiring user data migration

**Versioning:**
- Increment MAJOR version: `1.x` → `2.0`
- Reset MINOR to `0`
- Remove enhancement letter

**Examples:**

| Current Version | Change | New Version |
|----------------|--------|-------------|
| `1.9` | Rewrite to consolidated ABI | `2.0` |
| `2.5_d` | Move to microservices architecture | `3.0` |
| `3.2` | Complete protocol overhaul | `4.0` |

**Code Example:**
```lsl
// MAJOR OVERHAUL - v1.x → v2.0
/* MODULE: ds_collar_kernel.lsl (v2.0 - Event-Driven Architecture)

   BREAKING CHANGES FROM v1.x:
   - Migrated from polling to event-driven model
   - Removed deprecated LEGACY_CHANNEL (600)
   - Changed JSON payload format (see MIGRATION.md)
   - Requires all plugins to be updated to v2.0+ */
```

**Rationale:** Major overhauls represent fundamental changes that may break compatibility with older scripts or require users to adapt. The major version change signals "this is a new generation of the system."

---

## Version Application Guidelines

### Header Format

**Standard header with version:**
```lsl
/* =============================================================================
   [TYPE]: [filename].lsl (v[VERSION] - [DESCRIPTION])

   [Additional header content...]
   ============================================================================= */
```

**Types:**
- `MODULE:` for kernel modules
- `PLUGIN:` for plugins
- `CONTROL HUD:` for HUD scripts
- `LEASH HOLDER:` for holder scripts

### When to Update Versions

**Update immediately when:**
- Adding a new feature (dot increment)
- Pushing an enhancement (underscore increment)
- Completing a major overhaul (major increment)

**Do NOT update when:**
- Fixing bugs
- Applying security patches
- Refactoring code
- Adding comments/documentation
- Optimizing existing behavior

### Documenting Changes

**For security fixes/patches (no version change):**
```lsl
/* MODULE: ds_collar_kernel.lsl (v1.0 - Consolidated ABI)
   SECURITY AUDIT: ALL ISSUES FIXED

   SECURITY FIXES APPLIED:
   - [CRITICAL] Description of fix (DATE: YYYY-MM-DD)
   - [MEDIUM] Description of fix (DATE: YYYY-MM-DD)
   ============================================================================= */
```

**For enhancements:**
```lsl
/* PLUGIN: ds_collar_plugin_bell.lsl (v1.0_a - Volume Control)

   ENHANCEMENTS IN v1.0_a:
   - Added volume adjustment slider (10% increments)
   - Improved jingle sound continuity
   ============================================================================= */
```

**For feature additions:**
```lsl
/* PLUGIN: ds_collar_plugin_trustees.lsl (v1.3 - New Feature)

   NEW IN v1.3:
   - Trustee management system
   - Sensor-based avatar selection
   - Persistent trustee list storage
   ============================================================================= */
```

**For major overhauls:**
```lsl
/* MODULE: ds_collar_kernel.lsl (v2.0 - Event-Driven Architecture)

   BREAKING CHANGES FROM v1.x:
   - [List breaking changes]
   - [Migration requirements]

   NEW IN v2.0:
   - [List new capabilities]
   ============================================================================= */
```

---

## Version Progression Examples

### Example 1: Feature Development Lifecycle

```
v1.0           Initial release (kernel + 8 modules + 10 plugins)
v1.0           Security fix: Authorization bypass patch (no version change)
v1.0_a         Enhancement: Improved dialog layouts
v1.0_a         Hotfix: Memory leak in particle system (no version change)
v1.0_b         Enhancement: Added color customization
v1.1           Addition: New TPE mode plugin
v1.1           Bug fix: Timer cleanup issue (no version change)
v1.1_a         Enhancement: TPE confirmation dialog improvements
v1.2           Addition: New coffle system
v2.0           Major overhaul: Consolidated ABI migration
```

### Example 2: Single Script Evolution

```
ds_collar_plugin_bell.lsl

v1.0           - Initial release (visibility toggle, sound on/off)
v1.0           - Security fix: Channel leak prevention
v1.0_a         - Enhancement: Volume adjustment added (10% increments)
v1.0_b         - Enhancement: Movement detection improved
v1.1           - Addition: Multiple bell sounds support
v1.1           - Bug fix: Sound persistence issue
v1.1_a         - Enhancement: Sound preview in menu
v2.0           - Major overhaul: Integrated with new audio engine
```

---

## Edge Cases and Special Situations

### Case 1: Multiple Changes in One Update

**If an update contains multiple types of changes, use the highest-impact rule:**

- Security fix + Enhancement = **Enhancement** (version changes to `_a`)
- Enhancement + Feature addition = **Feature addition** (version increments minor)
- Feature addition + Major overhaul = **Major overhaul** (version increments major)

**Example:**
```
Current: v1.2_a
Changes: Bug fix + new feature
Result: v1.3 (feature addition wins)
```

### Case 2: Reverting an Enhancement

**If an enhancement is rolled back:**
- Keep the version number (don't decrement)
- Document the reversion in the header

```lsl
/* PLUGIN: ds_collar_plugin_bell.lsl (v1.0_b - Reverted Volume Control)

   CHANGES IN v1.0_b:
   - Reverted volume control feature (compatibility issues)
   - Restored v1.0 behavior
   ============================================================================= */
```

### Case 3: Enhancement After Feature Addition

**Enhancements reset after feature additions:**

```
v1.2     → Feature added
v1.2_a   → Enhancement to v1.2
v1.2_b   → Another enhancement
v1.3     → New feature added (enhancement suffix removed)
v1.3_a   → Enhancement to v1.3
```

### Case 4: Long Enhancement Chains

**After `_z`, continue with double letters:**

```
v1.0_y
v1.0_z
v1.0_aa
v1.0_ab
v1.0_az
v1.0_ba
```

**Recommendation:** If you reach `_z`, consider whether you should be doing a minor version increment (v1.1) instead, as you may have accumulated enough enhancements to constitute a meaningful update.

### Case 5: Hotfix During Development

**If working on v1.1 but need to hotfix v1.0:**

1. Apply hotfix to v1.0 (version stays v1.0)
2. Merge hotfix into v1.1 development
3. v1.1 remains v1.1 (hotfix doesn't change target version)

### Case 6: Independent Script Versions

**Scripts can have different versions:**

```
ds_collar_kernel.lsl           v1.5
ds_collar_kmod_auth.lsl        v1.5_a
ds_collar_plugin_bell.lsl      v1.3_b
ds_collar_plugin_tpe.lsl       v1.5
```

**However, for production releases, synchronize versions where possible:**

```
Production Release v1.0:
  - All kernel modules: v1.0
  - All plugins: v1.0
  - HUD: v1.0
  - Holder: v1.0
```

---

## Version Compatibility

### ABI Compatibility Matrix

| Version Type | ABI Compatible? | Can Mix Versions? |
|--------------|-----------------|-------------------|
| Security fixes (same version) | ✅ Yes | ✅ Yes |
| Enhancements (`_a`, `_b`) | ✅ Yes | ✅ Yes |
| Feature additions (1.0 → 1.1) | ✅ Usually* | ⚠️ Check notes |
| Major overhauls (1.x → 2.0) | ❌ No | ❌ No |

**\* Feature additions are ABI-compatible unless they modify core channels or message formats. Always check release notes.**

### Compatibility Guidelines

**Safe mixing:**
```
Kernel: v1.2
Modules: v1.2, v1.2_a, v1.2_b (OK - all compatible)
Plugins: v1.2_a, v1.2_c (OK - all compatible)
```

**Unsafe mixing:**
```
Kernel: v2.0
Modules: v1.9 (NOT OK - major version mismatch)
```

**When in doubt:**
- Same MAJOR.MINOR = Compatible
- Different MAJOR = Incompatible
- Different enhancements = Compatible

---

## Summary Chart

| Change Type | Version Change | Example | Compatibility |
|------------|----------------|---------|---------------|
| **Security fix** | None | v1.0 → v1.0 | ✅ Full |
| **Bug fix** | None | v1.2_a → v1.2_a | ✅ Full |
| **Hotfix** | None | v1.5 → v1.5 | ✅ Full |
| **Enhancement** | Add/increment `_x` | v1.0 → v1.0_a | ✅ Full |
| **Feature addition** | Increment minor | v1.0_b → v1.1 | ⚠️ Usually |
| **Major overhaul** | Increment major | v1.9 → v2.0 | ❌ Breaking |

---

## Release Checklist

Before releasing a version:

- [ ] Determine change type (security/enhancement/addition/overhaul)
- [ ] Apply appropriate version number to all affected scripts
- [ ] Update script headers with version and change description
- [ ] Document changes in commit message
- [ ] For major versions: Create MIGRATION.md guide
- [ ] For features: Update README.md with new capabilities
- [ ] Test compatibility with existing scripts
- [ ] Tag release in git with format: `vMAJOR.MINOR` or `vMAJOR.MINOR_ENHANCEMENT`

---

## Git Tag Format

**Tag format:**
```
v[MAJOR].[MINOR]
v[MAJOR].[MINOR]_[ENHANCEMENT]
```

**Examples:**
```bash
git tag -a v1.0 -m "Initial production release"
git tag -a v1.0_a -m "Enhanced bell volume control"
git tag -a v1.1 -m "Added TPE mode plugin"
git tag -a v2.0 -m "Consolidated ABI overhaul"
```

---

## FAQ

### Q: What if I fix a bug while adding a feature?

**A:** The feature addition takes precedence. Increment the minor version (e.g., v1.0 → v1.1). The bug fix is included as part of the new version.

### Q: Can I skip enhancement letters (e.g., v1.0_a → v1.0_c)?

**A:** No. Enhancement letters should increment sequentially to provide a clear history of changes.

### Q: What if I want to add a feature to an old version?

**A:** Create a branch for the old version, add the feature there (increment minor), and merge forward if needed. Example: v1.2 branch receives a feature → becomes v1.2.1 in that branch.

**Alternatively:** Use a different branch name scheme:
```
v1.2.1 (feature backport to v1.2)
v1.3   (mainline with original features)
```

### Q: How do I version a completely new script?

**A:** New scripts start at the project's current major version with minor 0:
- If project is at v1.x: New script starts at v1.0
- If project is at v2.x: New script starts at v2.0

### Q: What about experimental/beta features?

**A:** Use branch names or tags with suffixes:
```
v1.1-beta
v1.1-experimental
v1.1-rc1 (release candidate)
```

Once stable, release as v1.1 without suffix.

---

## Document Version

**Version:** 1.0
**Last Updated:** 2025-10-28
**Maintained by:** DS Collar Modular Project

---

*This versioning specification is authoritative for the DS Collar Modular project. All contributors must follow this scheme.*
