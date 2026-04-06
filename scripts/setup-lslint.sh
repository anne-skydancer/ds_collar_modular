#!/bin/bash
# setup-lslint.sh - Quick installer for lslint in ephemeral sandbox environments
# Usage: ./setup-lslint.sh
#
# Builds lslint from the anne-skydancer fork, which supports newer LSL builtins
# (e.g., llListSortStrided) that the upstream version doesn't recognize.

set -e  # Exit on error

echo "========================================="
echo "LSLint Setup Script"
echo "========================================="

# Check if lslint is already installed
if command -v lslint &> /dev/null; then
    echo "✓ lslint is already installed"
    lslint --version 2>&1 || echo "  (version info not available)"
    exit 0
fi

echo "Installing lslint from anne-skydancer/lslint..."
echo ""

# Build from source
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

echo "→ Cloning lslint repository..."
git clone https://github.com/anne-skydancer/lslint.git
cd lslint

echo "→ Building lslint..."
make

echo "✓ Build complete"

# Install lslint
echo "→ Installing lslint to /usr/local/bin..."
sudo cp lslint /usr/local/bin/
sudo chmod +x /usr/local/bin/lslint

echo "✓ Installation complete"

# Clean up
cd /
rm -rf "$TEMP_DIR"
echo "✓ Cleaned up temporary files"

echo ""
echo "========================================="
echo "✓ lslint successfully installed!"
echo "========================================="
echo ""
lslint --version 2>&1
echo ""
echo "Test it with:"
echo "  ./lint.sh src/stable/ds_collar_kernel.lsl"
echo "  ./lint.sh                                    # Lint all files"
echo ""
