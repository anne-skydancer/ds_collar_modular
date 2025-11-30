#!/bin/bash
# setup-lslint.sh - Quick installer for lslint in ephemeral sandbox environments
# Usage: ./setup-lslint.sh
#
# This script downloads and installs a pre-compiled lslint binary from GitHub releases.
# No build dependencies required!

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

echo "Installing lslint..."
echo ""

# Download pre-compiled binary
echo "→ Downloading pre-compiled lslint binary..."
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

wget -q https://github.com/Makopo/lslint/releases/download/nightly_build_20230410045235/lslint_nightly_build_20230410045235_linux64.zip

echo "✓ Download complete"

# Extract binary
echo "→ Extracting binary..."
unzip -q lslint_nightly_build_20230410045235_linux64.zip

echo "✓ Extraction complete"

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
