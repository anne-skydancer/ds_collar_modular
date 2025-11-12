#!/bin/bash
# Comprehensive linting script for ng branch
# Tests all LSL files for syntax errors

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
NG_DIR="$PROJECT_ROOT/src/ng"

cd "$NG_DIR"

echo "========================================"
echo "Linting NG Branch LSL Files"
echo "========================================"
echo ""

errors=0
warnings=0
total_files=0

# Kernel
echo "--- Kernel ---"
if lslint ds_collar_kernel.lsl 2>&1 | tee /tmp/lint_output.txt; then
    total_files=$((total_files + 1))
    err=$(grep "Errors:" /tmp/lint_output.txt | awk '{print $2}')
    warn=$(grep "Warnings:" /tmp/lint_output.txt | awk '{print $4}')
    errors=$((errors + err))
    warnings=$((warnings + warn))
else
    echo "FAILED to lint ds_collar_kernel.lsl"
    exit 1
fi
echo ""

# Kernel Modules
echo "--- Kernel Modules ---"
for file in ds_collar_kmod_*.lsl; do
    if [ -f "$file" ]; then
        if lslint "$file" 2>&1 | tee /tmp/lint_output.txt; then
            total_files=$((total_files + 1))
            err=$(grep "Errors:" /tmp/lint_output.txt | awk '{print $2}')
            warn=$(grep "Warnings:" /tmp/lint_output.txt | awk '{print $4}')
            errors=$((errors + err))
            warnings=$((warnings + warn))
        else
            echo "FAILED to lint $file"
            exit 1
        fi
        echo ""
    fi
done

# Plugins
echo "--- Plugins ---"
for file in ds_collar_plugin_*.lsl; do
    if [ -f "$file" ]; then
        if lslint "$file" 2>&1 | tee /tmp/lint_output.txt; then
            total_files=$((total_files + 1))
            err=$(grep "Errors:" /tmp/lint_output.txt | awk '{print $2}')
            warn=$(grep "Warnings:" /tmp/lint_output.txt | awk '{print $4}')
            errors=$((errors + err))
            warnings=$((warnings + warn))
        else
            echo "FAILED to lint $file"
            exit 1
        fi
        echo ""
    fi
done

# Additional Scripts
echo "--- Additional Scripts ---"
for file in ds_collar_menu.lsl ds_collar_control_hud.lsl ds_collar_leash_holder.lsl; do
    if [ -f "$file" ]; then
        if lslint "$file" 2>&1 | tee /tmp/lint_output.txt; then
            total_files=$((total_files + 1))
            err=$(grep "Errors:" /tmp/lint_output.txt | awk '{print $2}')
            warn=$(grep "Warnings:" /tmp/lint_output.txt | awk '{print $4}')
            errors=$((errors + err))
            warnings=$((warnings + warn))
        else
            echo "FAILED to lint $file"
            exit 1
        fi
        echo ""
    fi
done

echo "========================================"
echo "SUMMARY"
echo "========================================"
echo "Files linted: $total_files"
echo "Total errors: $errors"
echo "Total warnings: $warnings"
echo ""

if [ $errors -eq 0 ]; then
    echo "✓ All files passed with 0 errors!"
    exit 0
else
    echo "✗ $errors error(s) found!"
    exit 1
fi
