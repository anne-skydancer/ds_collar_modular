# LSL Testing Environment

This repository includes a complete testing environment for LSL scripts.

## Quick Start

### 1. Install lslint (once per sandbox session)

```bash
./setup-lslint.sh
```

This downloads and installs a pre-compiled lslint binary (~30 seconds).

### 2. Run linting

```bash
# Lint all files in src/
./lint.sh

# Lint a specific file
./lint.sh src/stable/ds_collar_kernel.lsl

# Lint a directory
./lint.sh src/stable/
```

## What Gets Checked

The linter checks for:

- **Syntax errors** - Invalid LSL syntax
- **Type errors** - Type mismatches in assignments and function calls
- **Unused code** - Unused variables and functions
- **Logic issues** - Conditions that are always true/false
- **LSL-specific quirks** - Second Life's unique LSL behaviors

## Understanding Results

### Clean Output
```
Files checked: 1
Total errors: 0
Total warnings: 0
```

### Warnings vs Errors
- **Errors** (red) - Code will not compile in Second Life
- **Warnings** (yellow) - Code will compile but may have issues

### Example Warning
```
ds_collar_kernel.lsl:: WARN:: (69, 9): variable `QUEUE_TIMESTAMP' declared but never used.
```
- **File**: ds_collar_kernel.lsl
- **Location**: Line 69, column 9
- **Issue**: Unused variable

## CI/CD Integration

The project includes GitHub Actions that automatically lint all `.lsl` files on push/PR.
See `.github/workflows/lsl-check.yml` for details.

## Pre-commit Hooks (Optional)

To automatically lint before commits, add to `.git/hooks/pre-commit`:

```bash
#!/bin/bash
./lint.sh
```

See `LINTING.md` for more details.

## Documentation

- `LINTING.md` - Comprehensive linting guide
- `STYLE_GUIDE.md` - Code style standards
- `agents.md` - LSL language reference and best practices
- `LSL_FUNCTION_DECLARATIONS.md` - Function syntax reference
- `LSL_SECURITY_LIMITATIONS.md` - Security considerations

## Troubleshooting

**lslint not found?**
Run `./setup-lslint.sh` to install it.

**Script fails with "cannot execute"?**
Make sure scripts are executable: `chmod +x setup-lslint.sh lint.sh`

**Network errors during setup?**
The setup script requires internet access to download the lslint binary from GitHub.
