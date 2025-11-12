#!/bin/bash
# setup-sei-lisa-compiler.sh - Installer for Sei-Lisa's LSL compiler
# Usage: ./setup-sei-lisa-compiler.sh
#
# This script downloads, builds, and installs Sei-Lisa's LSL compiler.
# The compiler generates LSO and Mono assembly output from LSL scripts.
#
# Requirements: flex, bison, g++, python2, git, wget

set -e  # Exit on error

echo "========================================="
echo "Sei-Lisa LSL Compiler Setup"
echo "========================================="

# Check if lslcomp is already installed
if command -v lslcomp &> /dev/null; then
    echo "✓ lslcomp is already installed"
    echo "  Location: $(which lslcomp)"
    read -p "Reinstall? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Create temporary directory for installation
INSTALL_DIR=$(mktemp -d)
echo "→ Working directory: $INSTALL_DIR"
cd "$INSTALL_DIR"

# Check and install dependencies
echo ""
echo "→ Checking dependencies..."

DEPS_TO_INSTALL=""

if ! command -v flex &> /dev/null; then
    DEPS_TO_INSTALL="$DEPS_TO_INSTALL flex"
fi

if ! command -v bison &> /dev/null; then
    DEPS_TO_INSTALL="$DEPS_TO_INSTALL bison"
fi

if ! command -v g++ &> /dev/null; then
    DEPS_TO_INSTALL="$DEPS_TO_INSTALL g++"
fi

if ! command -v python2 &> /dev/null && ! command -v python2.7 &> /dev/null; then
    DEPS_TO_INSTALL="$DEPS_TO_INSTALL python2"
fi

if ! command -v git &> /dev/null; then
    DEPS_TO_INSTALL="$DEPS_TO_INSTALL git"
fi

if ! command -v wget &> /dev/null; then
    DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget"
fi

if ! command -v make &> /dev/null; then
    DEPS_TO_INSTALL="$DEPS_TO_INSTALL make"
fi

if [ -n "$DEPS_TO_INSTALL" ]; then
    echo "→ Installing dependencies:$DEPS_TO_INSTALL"
    sudo apt-get update -qq
    sudo apt-get install -y $DEPS_TO_INSTALL
    echo "✓ Dependencies installed"
else
    echo "✓ All dependencies already installed"
fi

# Clone and setup kwdb (keyword database)
echo ""
echo "→ Cloning kwdb (LSL keyword database)..."
git clone -q https://bitbucket.org/Sei_Lisa/kwdb.git
echo "✓ kwdb cloned"

# Setup kwdb
echo "→ Setting up kwdb..."
cd kwdb

# Ensure Python 2 is used
if command -v python2 &> /dev/null; then
    PYTHON_CMD=python2
elif command -v python2.7 &> /dev/null; then
    PYTHON_CMD=python2.7
else
    echo "✗ Error: Python 2 is required but not found"
    exit 1
fi

# Build kwdb
echo "→ Building kwdb..."
$PYTHON_CMD setup.py build > /dev/null 2>&1
echo "✓ kwdb built"

KWDB_PATH="$INSTALL_DIR/kwdb"
cd "$INSTALL_DIR"

# Clone LSL-compiler
echo ""
echo "→ Cloning Sei-Lisa's LSL-compiler..."
git clone -q https://github.com/Sei-Lisa/LSL-compiler.git
echo "✓ LSL-compiler cloned"

cd LSL-compiler

# Copy indralex.py to kwdb directory
echo "→ Configuring compiler..."
mkdir -p "$KWDB_PATH/lsl2dfg/lsloutputs"
cp indralex.py "$KWDB_PATH/lsl2dfg/lsloutputs/"
echo "✓ Compiler configured"

# Update Makefile to point to kwdb installation
echo "→ Updating Makefile..."
sed -i "s|^KWDB_DIR = .*|KWDB_DIR = $KWDB_PATH|" Makefile || {
    # If the sed pattern doesn't match, add the line
    echo "KWDB_DIR = $KWDB_PATH" >> Makefile
}
echo "✓ Makefile updated"

# Build the compiler
echo ""
echo "→ Building LSL compiler (this may take a minute)..."
make clean > /dev/null 2>&1 || true
make > /dev/null 2>&1
echo "✓ Compiler built successfully"

# Install lslcomp to /usr/local/bin
echo ""
echo "→ Installing lslcomp to /usr/local/bin..."
sudo cp lslcomp /usr/local/bin/
sudo chmod +x /usr/local/bin/lslcomp
echo "✓ Installation complete"

# Store paths for future reference
INSTALL_INFO_DIR="$HOME/.local/share/lsl-compiler"
mkdir -p "$INSTALL_INFO_DIR"
cat > "$INSTALL_INFO_DIR/paths.txt" << EOF
Installation Date: $(date)
KWDB Path: $KWDB_PATH
Compiler Path: $INSTALL_DIR/LSL-compiler
Binary Location: /usr/local/bin/lslcomp
EOF
echo "✓ Installation info saved to $INSTALL_INFO_DIR/paths.txt"

echo ""
echo "========================================="
echo "✓ Sei-Lisa LSL Compiler Installed!"
echo "========================================="
echo ""
echo "Compiler location: /usr/local/bin/lslcomp"
echo ""
echo "Usage:"
echo "  lslcomp <script.lsl>"
echo ""
echo "Output files generated:"
echo "  • <script>.out    - LSO assembler output"
echo "  • <script>.cil    - Mono assembler output"
echo "  • <script>.lsl.pp - Pretty-printed script"
echo ""
echo "Note: Source files kept at $INSTALL_DIR"
echo "      (You can safely delete this after testing)"
echo ""

# Test the installation
if [ -f "tests/test001.lsl" ]; then
    echo "→ Running test compilation..."
    lslcomp tests/test001.lsl > /dev/null 2>&1 && echo "✓ Test passed!" || echo "⚠ Test failed (compiler may still work)"
    echo ""
fi
