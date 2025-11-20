#!/bin/bash
# lint-and-compile.sh - Lint and compile LSL scripts, then clean up artifacts
# Usage: ./lint-and-compile.sh <file1.lsl> [file2.lsl ...]

set -e  # Exit on error

# Check if lslint exists
if ! command -v lslint &> /dev/null; then
    echo "Error: lslint not found. Run setup-lslint.sh first."
    exit 1
fi

# Check if lslcomp exists
if ! command -v lslcomp &> /dev/null; then
    echo "Error: lslcomp not found in PATH."
    exit 1
fi

# Check if any files were provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <file1.lsl> [file2.lsl ...]"
    exit 1
fi

# Track overall success
ALL_PASSED=true
LINT_ERRORS=0
COMPILE_ERRORS=0

echo "========================================="
echo "LSL Lint & Compile"
echo "========================================="
echo ""

# Process each file
for FILE in "$@"; do
    if [ ! -f "$FILE" ]; then
        echo "⚠️  File not found: $FILE"
        ALL_PASSED=false
        continue
    fi
    
    echo "Processing: $FILE"
    
    # Run lslint
    echo -n "  [LINT] "
    if lslint "$FILE" 2>&1 | grep -q "Errors: 0  Warnings: 0"; then
        echo "✓ Passed"
    else
        echo "✗ Failed"
        lslint "$FILE" 2>&1 | tail -1
        LINT_ERRORS=$((LINT_ERRORS + 1))
        ALL_PASSED=false
    fi
    
    # Run lslcomp
    echo -n "  [COMP] "
    COMPILE_OUTPUT=$(lslcomp "$FILE" 2>&1)
    if [ -z "$COMPILE_OUTPUT" ]; then
        echo "✓ Passed"
    else
        echo "✗ Failed"
        echo "$COMPILE_OUTPUT" | head -5
        COMPILE_ERRORS=$((COMPILE_ERRORS + 1))
        ALL_PASSED=false
    fi
    
    echo ""
done

# Clean up compiler artifacts
echo "Cleaning up compiler artifacts..."
CLEANUP_COUNT=0

# Find and remove .cil, .pp, .out files in the same directories as input files
for FILE in "$@"; do
    DIR=$(dirname "$FILE")
    BASENAME=$(basename "$FILE" .lsl)
    
    # Remove artifacts for this specific file
    for EXT in cil pp out lso compiled; do
        ARTIFACT="${DIR}/${BASENAME}.${EXT}"
        if [ -f "$ARTIFACT" ]; then
            rm -f "$ARTIFACT"
            CLEANUP_COUNT=$((CLEANUP_COUNT + 1))
        fi
    done
done

if [ $CLEANUP_COUNT -gt 0 ]; then
    echo "✓ Removed $CLEANUP_COUNT artifact(s)"
else
    echo "✓ No artifacts to clean"
fi

echo ""
echo "========================================="
echo "Summary"
echo "========================================="
echo "Files processed: $#"
echo "Lint errors:     $LINT_ERRORS"
echo "Compile errors:  $COMPILE_ERRORS"

if [ "$ALL_PASSED" = true ]; then
    echo ""
    echo "✓ All files passed lint and compilation"
    exit 0
else
    echo ""
    echo "✗ Some files failed (see above)"
    exit 1
fi
