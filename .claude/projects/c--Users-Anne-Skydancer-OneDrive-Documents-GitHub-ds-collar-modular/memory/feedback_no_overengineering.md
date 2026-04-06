---
name: No overengineering in LSL
description: Keep LSL scripts lean — no debug scaffolding, no unnecessary abstractions, prioritize small size and efficiency
type: feedback
---

Do not add debug logging infrastructure (DEBUG flags, logd() helpers) to LSL scripts. LSL predilects efficiency and small size. Follow the Unix philosophy: do one thing and do it well. Avoid overengineering.

**Why:** User explicitly called out debug scaffolding as overengineered. LSL has tight memory constraints and every global/function costs heap.

**How to apply:** When writing LSL, keep scripts minimal. Use llOwnerSay() inline during development if truly needed, but don't ship debug infrastructure. Prefer fewer globals, fewer helpers, direct code.
