#!/bin/bash
# LSL Linting Script for DS Collar Modular
# Usage: ./lint.sh [file|directory]
# If no argument is provided, lints all .lsl files in src/

set -e

LSLINT="lslint"
LSLINT_FLAGS="-m -p"  # Mono mode, show file paths

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

total_errors=0
total_warnings=0
files_checked=0

lint_file() {
    local file="$1"
    echo -e "${YELLOW}Linting: $file${NC}"

    # Run lslint and capture output
    if output=$($LSLINT $LSLINT_FLAGS "$file" 2>&1); then
        echo "$output"
    else
        echo "$output"
    fi

    # Extract error and warning counts
    if echo "$output" | grep -q "TOTAL::"; then
        errors=$(echo "$output" | grep "TOTAL::" | sed -n 's/.*Errors: \([0-9]*\).*/\1/p')
        warnings=$(echo "$output" | grep "TOTAL::" | sed -n 's/.*Warnings: \([0-9]*\).*/\1/p')
        total_errors=$((total_errors + errors))
        total_warnings=$((total_warnings + warnings))
    fi

    ((files_checked++))
    echo ""
}

# Main logic
if [ $# -eq 0 ]; then
    # No arguments - lint all files in src/
    echo -e "${GREEN}Linting all LSL files in src/${NC}"
    echo ""

    while IFS= read -r -d '' file; do
        lint_file "$file"
    done < <(find src -name "*.lsl" -print0 | sort -z)

elif [ -f "$1" ]; then
    # Single file
    lint_file "$1"

elif [ -d "$1" ]; then
    # Directory
    echo -e "${GREEN}Linting all LSL files in $1${NC}"
    echo ""

    while IFS= read -r -d '' file; do
        lint_file "$file"
    done < <(find "$1" -name "*.lsl" -print0 | sort -z)

else
    echo -e "${RED}Error: $1 is not a valid file or directory${NC}"
    exit 1
fi

# Summary
echo "========================================"
echo -e "${GREEN}Linting Summary${NC}"
echo "Files checked: $files_checked"
echo -e "Total errors: ${RED}$total_errors${NC}"
echo -e "Total warnings: ${YELLOW}$total_warnings${NC}"
echo "========================================"

if [ $total_errors -gt 0 ]; then
    exit 1
fi

exit 0
