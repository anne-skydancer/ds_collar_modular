#!/bin/bash
# Lint all files in the stable branch of DS Collar

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STABLE_DIR="$PROJECT_ROOT/src/stable"

echo "========================================"
echo "Linting DS Collar Stable Branch"
echo "========================================"
echo ""

# Check if lslint is available
if ! command -v lslint.exe &> /dev/null && ! command -v lslint &> /dev/null; then
    echo "❌ lslint not found in PATH"
    echo ""
    echo "To install lslint, run:"
    echo "  bash scripts/setup-lsl-tools.sh"
    exit 1
fi

# Find lslint command
LSLINT=$(command -v lslint.exe 2>/dev/null || command -v lslint 2>/dev/null || echo "$HOME/.local/bin/lslint.exe")

if [ ! -f "$LSLINT" ] && [ ! -x "$LSLINT" ]; then
    echo "❌ lslint executable not found"
    exit 1
fi

echo "Using: $LSLINT"
echo "Directory: $STABLE_DIR"
echo ""

# Count files
TOTAL_FILES=$(find "$STABLE_DIR" -name "*.lsl" -type f | wc -l)
echo "Found $TOTAL_FILES LSL files"
echo ""
echo "----------------------------------------"
echo ""

# Lint each file
ERROR_COUNT=0
SUCCESS_COUNT=0

for file in "$STABLE_DIR"/*.lsl; do
    if [ -f "$file" ]; then
        FILENAME=$(basename "$file")
        printf "%-40s " "$FILENAME"
        
        # Run lslint and capture output
        if OUTPUT=$("$LSLINT" "$file" 2>&1); then
            # Check if there are any errors or warnings
            if echo "$OUTPUT" | grep -q "ERROR\|WARNING"; then
                echo "⚠️  Issues found"
                echo "$OUTPUT" | head -5
                ERROR_COUNT=$((ERROR_COUNT + 1))
            else
                echo "✅ OK"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            fi
        else
            echo "❌ FAILED"
            echo "$OUTPUT" | head -5
            ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
    fi
done

echo ""
echo "========================================"
echo "Lint Summary"
echo "========================================"
echo "Total files:    $TOTAL_FILES"
echo "Passed:         $SUCCESS_COUNT"
echo "Issues/Errors:  $ERROR_COUNT"
echo ""

if [ $ERROR_COUNT -eq 0 ]; then
    echo "✅ All files passed linting!"
    exit 0
else
    echo "⚠️  Some files have issues"
    exit 1
fi
