#!/usr/bin/env python3
"""
Standardize LSL section headers and debug/production flags.
- Replaces boxed headers like:
  /* ═══\n     SECTION\n     ═══ */
  with
  /* -------------------- SECTION -------------------- */
- Ensures DEBUG/PRODUCTION flags per branch folder:
  src/dev, src/ng -> DEBUG = TRUE, PRODUCTION = FALSE
  src/stable      -> DEBUG = FALSE, PRODUCTION = TRUE

Run from repository root.
"""
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
lsl_files = list(root.glob('src/**/**/*.lsl')) + list(root.glob('src/**/*.lsl'))
lsl_files = sorted({p for p in lsl_files})

# regex to match the boxed header block. We look for patterns like:
# /* ═══...\n   SOME TITLE LINE\n   ═══... */
box_re = re.compile(r"/\*\s*\u2550+\s*\n(\s*)(?P<title>[^\n\r]+?)\s*\n\s*\u2550+\s*\*/", re.M)
# fallback: match sequences of '═' char U+2550 may not be present in all files; also match long sequences of '=' or '-' or similar
box_re_alt = re.compile(r"/\*\s*[-=~*]{5,}\s*\n(\s*)(?P<title>[^\n\r]+?)\s*\n\s*[-=~*]{5,}\s*\*/", re.M)

changes = []
for path in lsl_files:
    text = path.read_text(encoding='utf-8')
    new = text
    def replace_box(m):
        title = m.group('title').strip()
        # Collapse multiple spaces to single, remove leading/trailing non-word chars
        title_clean = re.sub(r"\s+", ' ', title)
        return f"/* -------------------- {title_clean} -------------------- */"
    new = box_re.sub(replace_box, new)
    new = box_re_alt.sub(replace_box, new)

    # Now ensure DEBUG/PRODUCTION flags according to branch folder
    # Determine if file under src/dev, src/ng, or src/stable
    rel = path.relative_to(root)
    parts = rel.parts
    desired_debug = None
    desired_production = None
    if parts[0] == 'src' and len(parts) >= 2:
        branch = parts[1]
        if branch in ('dev', 'ng'):
            desired_debug = 'TRUE'
            desired_production = 'FALSE'
        elif branch == 'stable':
            desired_debug = 'FALSE'
            desired_production = 'TRUE'
    # replace or insert flags
    if desired_debug is not None:
        # replace existing definitions
        new = re.sub(r"integer\s+DEBUG\s*=\s*(TRUE|FALSE)\s*;", f"integer DEBUG = {desired_debug};", new)
        new = re.sub(r"integer\s+PRODUCTION\s*=\s*(TRUE|FALSE)\s*;", f"integer PRODUCTION = {desired_production};", new)
        # if PRODUCTION not present and DEBUG present, insert after DEBUG line
        if 'integer DEBUG' in new and 'integer PRODUCTION' not in new:
            new = re.sub(r"(integer\s+DEBUG\s*=\s*.+?;)(\s*)", r"\1\ninteger PRODUCTION = %s;\2" % desired_production, new, count=1)
        # if DEBUG not present but PRODUCTION present, insert DEBUG before PRODUCTION
        if 'integer PRODUCTION' in new and 'integer DEBUG' not in new:
            new = re.sub(r"(integer\s+PRODUCTION\s*=\s*.+?;)(\s*)", r"integer DEBUG = %s;\n\1\2" % desired_debug, new, count=1)

    if new != text:
        path.write_text(new, encoding='utf-8')
        changes.append(str(path))

# report
print('Updated %d files' % len(changes))
for p in changes:
    print(p)
