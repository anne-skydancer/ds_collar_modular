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

# Check for build tools
MISSING_TOOLS=""
if ! command -v flex &> /dev/null; then MISSING_TOOLS="$MISSING_TOOLS flex"; fi
if ! command -v bison &> /dev/null; then MISSING_TOOLS="$MISSING_TOOLS bison"; fi
if ! command -v make &> /dev/null; then MISSING_TOOLS="$MISSING_TOOLS make"; fi
if ! command -v g++ &> /dev/null; then MISSING_TOOLS="$MISSING_TOOLS g++"; fi

# Check for Python 2 (Required for kwdb)
HAS_PY2=false
if command -v python2 &> /dev/null; then HAS_PY2=true; fi
if [ "$HAS_PY2" = false ] && command -v python &> /dev/null; then
    VER=$(python -c 'import sys; print(sys.version_info[0])')
    if [ "$VER" == "2" ]; then HAS_PY2=true; fi
fi

if [ -n "$MISSING_TOOLS" ] || [ "$HAS_PY2" = false ]; then
    echo "❌ CRITICAL: Missing build environment!"
    echo ""
    echo "This script attempts to compile the Sei-Lisa LSL Compiler (lslcomp) from C++ source."
    echo "It requires a full MinGW/MSYS2 build environment which is NOT present."
    echo ""
    echo "Missing components:"
    if [ -n "$MISSING_TOOLS" ]; then echo "  • Build Tools:$MISSING_TOOLS"; fi
    if [ "$HAS_PY2" = false ]; then echo "  • Python 2.x (Required for kwdb generation)"; fi
    echo ""
    
    # Check if lslopt is installed (the likely intended tool)
    if command -v lslopt &> /dev/null || [ -f "$HOME/.local/bin/lslopt" ]; then
        echo "✅ GOOD NEWS: You already have 'lslopt' (Sei-Lisa Optimizer) installed!"
        echo "   Most developers only need the optimizer/shrinker."
        echo "   You only need 'lslcomp' if you want to generate LSO/Mono assembly code."
        echo ""
    else
        echo "💡 DID YOU MEAN THE OPTIMIZER?"
        echo "   If you want the Sei-Lisa LSL Optimizer (to shrink scripts), run:"
        echo "   ./scripts/setup-lsl-tools.ps1"
        echo ""
    fi

    echo "HOW TO FIX THIS (If you really need lslcomp):"
    echo "1. Install MSYS2 from https://www.msys2.org/"
    echo "2. Open MSYS2 terminal and run:"
    echo "   pacman -S base-devel gcc python2 git"
    echo "3. Run this script again from the MSYS2 terminal."
    echo ""
    exit 1
fi

# Clone and setup kwdb (keyword database)
echo ""
echo "→ Cloning kwdb (LSL keyword database)..."
if [ -d "kwdb" ]; then
    rm -rf kwdb
fi
git clone -q https://github.com/Sei-Lisa/kwdb.git
echo "✓ kwdb cloned"

# Setup kwdb
echo "→ Setting up kwdb..."
cd kwdb

# Ensure Python 2 is used
if command -v python2 &> /dev/null; then
    PYTHON_CMD=python2
elif command -v python2.7 &> /dev/null; then
    PYTHON_CMD=python2.7
elif command -v python &> /dev/null && python --version &> /dev/null; then
    # Verify it is python 2
    VER=$(python -c 'import sys; print(sys.version_info[0])')
    if [ "$VER" == "2" ]; then
        PYTHON_CMD=python
    else
        echo "⚠ Python 2 not found (python is version $VER). kwdb build may fail."
        PYTHON_CMD=python
    fi
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

# Install lslcomp to local bin
echo ""
INSTALL_BIN_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_BIN_DIR"

echo "→ Installing lslcomp to $INSTALL_BIN_DIR..."
cp lslcomp "$INSTALL_BIN_DIR/"
chmod +x "$INSTALL_BIN_DIR/lslcomp"
echo "✓ Installation complete"

# Store paths for future reference
INSTALL_INFO_DIR="$HOME/.local/share/lsl-compiler"
mkdir -p "$INSTALL_INFO_DIR"
cat > "$INSTALL_INFO_DIR/paths.txt" << EOF
Installation Date: $(date)
KWDB Path: $KWDB_PATH
Compiler Path: $INSTALL_DIR/LSL-compiler
Binary Location: $INSTALL_BIN_DIR/lslcomp
EOF
echo "✓ Installation info saved to $INSTALL_INFO_DIR/paths.txt"

echo ""
echo "========================================="
echo "✓ Sei-Lisa LSL Compiler Installed!"
echo "========================================="
echo ""
echo "Compiler location: $INSTALL_BIN_DIR/lslcomp"
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
