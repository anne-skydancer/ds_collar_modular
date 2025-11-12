#!/bin/bash
# Setup script for LSL development tools
# Installs lslint and sei-lisa LSL compiler in Git Bash environment

set -e  # Exit on error

echo "========================================"
echo "LSL Development Tools Setup"
echo "========================================"
echo ""

# Detect installation directory
INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"

# Add to PATH if not already there
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo "Adding $INSTALL_DIR to PATH..."
    echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> "$HOME/.bashrc"
    export PATH="$PATH:$INSTALL_DIR"
fi

echo "Installation directory: $INSTALL_DIR"
echo ""

# ========================================
# Install lslint
# ========================================
echo "Installing lslint..."
echo "----------------------------------------"

LSLINT_DIR="$HOME/.lsl-tools/lslint"
mkdir -p "$LSLINT_DIR"

if [ -f "$INSTALL_DIR/lslint.exe" ]; then
    echo "lslint already installed. Skipping."
else
    echo "Cloning lslint repository..."
    if [ -d "$LSLINT_DIR/.git" ]; then
        cd "$LSLINT_DIR"
        git pull
    else
        git clone https://github.com/Makopo/lslint.git "$LSLINT_DIR"
        cd "$LSLINT_DIR"
    fi
    
    echo "Building lslint..."
    # Check if we have make
    if command -v make &> /dev/null; then
        make
        cp lslint.exe "$INSTALL_DIR/" || cp lslint "$INSTALL_DIR/"
        echo "✅ lslint installed to $INSTALL_DIR"
    else
        echo "❌ 'make' not found. Please install MinGW build tools."
        echo "   You can install via: pacman -S make gcc"
        exit 1
    fi
fi

echo ""

# ========================================
# Install sei-lisa LSL compiler
# ========================================
echo "Installing sei-lisa LSL compiler..."
echo "----------------------------------------"

COMPILER_DIR="$HOME/.lsl-tools/lslopt"
mkdir -p "$COMPILER_DIR"

if [ -f "$INSTALL_DIR/lslopt" ]; then
    echo "lslopt already installed. Skipping."
else
    echo "Cloning LSL-PyOptimizer repository..."
    if [ -d "$COMPILER_DIR/.git" ]; then
        cd "$COMPILER_DIR"
        git pull
    else
        git clone https://github.com/Sei-Lisa/LSL-PyOptimizer.git "$COMPILER_DIR"
        cd "$COMPILER_DIR"
    fi
    
    # Check for Python
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    elif command -v python &> /dev/null; then
        PYTHON_CMD="python"
    else
        echo "❌ Python not found. Please install Python 3."
        exit 1
    fi
    
    echo "Using Python: $PYTHON_CMD"
    
    # Create wrapper script
    cat > "$INSTALL_DIR/lslopt" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$HOME/.lsl-tools/lslopt"
if command -v python3 &> /dev/null; then
    python3 "$SCRIPT_DIR/lslopt.py" "$@"
elif command -v python &> /dev/null; then
    python "$SCRIPT_DIR/lslopt.py" "$@"
else
    echo "Error: Python not found"
    exit 1
fi
EOF
    
    chmod +x "$INSTALL_DIR/lslopt"
    echo "✅ lslopt installed to $INSTALL_DIR"
fi

echo ""

# ========================================
# Verify installations
# ========================================
echo "========================================"
echo "Verifying installations..."
echo "========================================"
echo ""

# Test lslint
if [ -f "$INSTALL_DIR/lslint.exe" ] || [ -f "$INSTALL_DIR/lslint" ]; then
    echo "✅ lslint: INSTALLED"
    LSLINT_PATH=$(command -v lslint.exe 2>/dev/null || command -v lslint 2>/dev/null || echo "$INSTALL_DIR/lslint")
    echo "   Location: $LSLINT_PATH"
else
    echo "❌ lslint: NOT FOUND"
fi

# Test lslopt
if [ -f "$INSTALL_DIR/lslopt" ]; then
    echo "✅ lslopt: INSTALLED"
    echo "   Location: $INSTALL_DIR/lslopt"
    
    # Test Python availability
    if "$INSTALL_DIR/lslopt" --help &> /dev/null; then
        echo "   Python: OK"
    else
        echo "   ⚠️  Python issue detected"
    fi
else
    echo "❌ lslopt: NOT FOUND"
fi

echo ""
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "Usage:"
echo "  lslint <file.lsl>              - Lint a single file"
echo "  lslopt -H <file.lsl>           - Compile and show help"
echo "  lslopt -o output.lsl input.lsl - Compile with optimization"
echo ""
echo "For lslopt documentation, visit:"
echo "  https://github.com/Sei-Lisa/LSL-PyOptimizer"
echo ""
echo "NOTE: If commands not found, restart Git Bash or run:"
echo "  source ~/.bashrc"
echo ""
