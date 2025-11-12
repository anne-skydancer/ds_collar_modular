# LSL Development Tools Installation Summary

**Date:** November 12, 2025  
**Project:** DS Collar Modular v2.0

## ✅ Successfully Installed

### 1. lslint (Syntax Checker)
- **Version:** nightly_build_20230410045235
- **Location:** `~/.local/bin/lslint.exe`
- **Source:** https://github.com/Makopo/lslint
- **Usage:**
  ```bash
  lslint <file.lsl>
  lslint --version
  ```

### 2. lslopt (SEI-LISA LSL Compiler/Optimizer)
- **Version:** 0.3.0beta  
- **Location:** `~/.local/bin/lslopt` (wrapper script)
- **Source:** https://github.com/Sei-Lisa/LSL-PyOptimizer
- **Requires:** Python 3 (detected: Python 3.13.9)
- **Usage:**
  ```bash
  lslopt --help
  lslopt -o output.lsl input.lsl
  lslopt -H input.lsl  # Add Firestorm header
  ```

### 3. Project Lint Scripts
- **lint-stable.sh:** Lints all files in src/stable branch
- **setup-lsl-tools.sh:** Master installation script (for future use)
- **setup-lsl-tools.ps1:** PowerShell wrapper for installation

## Installation Directories

```
~/.local/bin/                    # Executables (added to PATH)
├── lslint.exe                   # LSL syntax checker
└── lslopt                       # LSL compiler wrapper

~/.lsl-tools/                    # Tool repositories
├── lslint/                      # lslint source (cloned)
├── LSL-PyOptimizer/             # Compiler source (cloned)
└── lslint_win64.zip            # Downloaded binary
```

## PATH Configuration

Added to `~/.bashrc`:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

**Note:** Restart Git Bash or run `source ~/.bashrc` to apply.

## Verification

Run in Git Bash:
```bash
# Check installations
lslint.exe --version
lslopt --help

# Lint a file
lslint.exe path/to/file.lsl

# Compile/optimize a file
lslopt -o optimized.lsl original.lsl
```

## Project Integration

### Lint Stable Branch
```bash
cd /c/Users/annes/OneDrive/Documents/GitHub/ds_collar_modular
bash scripts/lint-stable.sh
```

### Lint Single File
```bash
lslint.exe src/stable/ds_collar_kernel.lsl
```

## Important Notes

### Debug Stripping Issue
❌ **Automated debug code removal failed** - The strip-debug-v2.ps1 script broke 10 files:
- ds_collar_kernel.lsl
- ds_collar_kmod_dialogs.lsl  
- ds_collar_kmod_particles.lsl
- ds_collar_kmod_remote.lsl
- ds_collar_kmod_settings.lsl
- ds_collar_kmod_ui.lsl
- ds_collar_leash_holder.lsl
- ds_collar_menu.lsl
- ds_collar_plugin_leash.lsl
- ds_collar_plugin_rlvrestrict.lsl

**Solution:** Restored stable branch from dev branch (working files with debug code intact).

**Recommendation:** Manual debug removal should be done carefully on a per-file basis, or use `#ifdef DEBUG` preprocessor directives with lslopt's preprocessor support.

### Current Branch Status
- **dev/:** DEBUG=TRUE, PRODUCTION=FALSE (with timing diagnostics)
- **ng/:** DEBUG=TRUE, PRODUCTION=FALSE (with timing diagnostics)
- **stable/:** Currently has debug code (restored from dev after failed stripping)

## Next Steps

1. **Test in-world:** Upload dev branch to Second Life, test responsiveness
2. **Analyze timing:** Review diagnostic logs to confirm no delays
3. **Manual optimization:** Selectively remove debug code from stable by hand
4. **Preprocessor approach:** Consider using `#ifdef DEBUG` for cleaner production builds

## Tool Documentation

- **lslint:** https://github.com/Makopo/lslint
- **LSL-PyOptimizer:** https://github.com/Sei-Lisa/LSL-PyOptimizer
- **LSL Wiki:** https://wiki.secondlife.com/wiki/LSL_Portal
- **LSL Style Guide:** https://wiki.secondlife.com/wiki/LSL_Style_Guide

## Troubleshooting

### lslint not found
```bash
# Check if in PATH
which lslint.exe

# Add to current session
export PATH="$HOME/.local/bin:$PATH"

# Permanent fix
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Python errors with lslopt
```bash
# Check Python
python --version  # or python3 --version

# Test lslopt
lslopt --version
```

### Lint errors after editing
- Run lslint before committing changes
- Use `bash scripts/lint-stable.sh` to check all files
- Compare with working version if syntax errors appear

---

**Installation completed by:** GitHub Copilot Agent  
**Total setup time:** ~15 minutes  
**Files processed:** 28 LSL scripts  
**Tools verified:** ✅ lslint, ✅ lslopt, ✅ Python 3.13.9
