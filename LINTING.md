# LSL Linting for DS Collar Modular

This repository now includes **lslint**, a powerful static analysis tool for Linden Scripting Language (LSL) that checks for syntactic and semantic issues in your scripts.

## What is lslint?

lslint is a tool that analyzes LSL scripts for:
- Syntax errors
- Type mismatches
- Unused variables and functions
- Unreachable code
- Semantic issues
- Best practice violations

## Installation

lslint is already installed in this development environment. If you need to install it elsewhere:

```bash
git clone https://github.com/Makopo/lslint.git
cd lslint
make
sudo cp lslint /usr/local/bin/
```

### Prerequisites
- C++ compiler (g++)
- flex
- bison
- make

## Usage

### Option 1: Using the Lint Script (Recommended)

A convenient `lint.sh` script is provided in the root directory:

```bash
# Lint all LSL files in src/
./lint.sh

# Lint a specific file
./lint.sh src/stable/ds_collar_kernel.lsl

# Lint all files in a directory
./lint.sh src/stable/
```

The script will:
- Show detailed warnings and errors for each file
- Provide a summary with total error and warning counts
- Use color-coded output for easy reading
- Exit with code 1 if any errors are found

### Option 2: Using lslint Directly

You can also run lslint directly on individual files:

```bash
lslint src/stable/ds_collar_kernel.lsl
```

#### Common lslint Options

- `-m` - Use Mono rules (default, recommended for Second Life)
- `-m-` - Use LSO rules (legacy)
- `-p` - Show file path in output
- `-v` - Verbose output
- `-u` - Warn about unused event parameters
- `-#` - Show error codes
- `--help` - Show all available options

Example with options:
```bash
lslint -m -p -v src/stable/ds_collar_kernel.lsl
```

## Interpreting Results

### Example Output

```
WARN:: ( 69,  9): variable `QUEUE_TIMESTAMP' declared but never used.
WARN:: ( 89,  9): Condition is always false.
WARN:: (435,  1): function `broadcast_soft_reset' declared but never used.
TOTAL:: Errors: 0  Warnings: 4
```

- **(line, column)** - Location of the issue
- **WARN** - Warning (code will compile but may have issues)
- **ERROR** - Error (code will not compile or has serious issues)

### Common Warnings

1. **Unused variables/functions** - Declared but never used, wastes script memory
2. **Condition is always false/true** - Logic error or unreachable code
3. **Type mismatches** - Implicit type conversions that may lose data
4. **Unreachable code** - Code that can never execute

## Best Practices

1. **Run linting before committing** - Catch issues early
2. **Fix errors immediately** - They prevent compilation
3. **Address warnings** - They often indicate real problems
4. **Use in CI/CD** - The lint script exits with code 1 on errors

## Integration with Git

You can add linting to your git workflow:

### Pre-commit Hook

Create `.git/hooks/pre-commit`:
```bash
#!/bin/bash
./lint.sh
```

Make it executable:
```bash
chmod +x .git/hooks/pre-commit
```

### GitHub Actions

Add to `.github/workflows/lint.yml`:
```yaml
name: LSL Linting
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Install lslint
        run: |
          git clone https://github.com/Makopo/lslint.git
          cd lslint
          make
          sudo cp lslint /usr/local/bin/
      - name: Run linting
        run: ./lint.sh
```

## Troubleshooting

### "command not found: lslint"
lslint is not in your PATH. Install it following the instructions above.

### "required file not found" when running lint.sh
The script may have Windows line endings. Fix with:
```bash
sed -i 's/\r$//' lint.sh
```

### Too many warnings
Start by fixing errors first, then gradually address warnings. You can filter by piping through grep:
```bash
lslint file.lsl 2>&1 | grep ERROR
```

## Additional Resources

- [lslint GitHub Repository](https://github.com/Makopo/lslint)
- [LSL Portal](http://wiki.secondlife.com/wiki/LSL_Portal)
- [LSL Style Guide](./STYLE_GUIDE.md)

## Contributing

When contributing to this project:
1. Run `./lint.sh` before committing
2. Fix all errors
3. Address warnings when practical
4. Document any intentional warning suppressions

---

For questions or issues with linting, please open an issue on GitHub.
