# LSL Quirks & Limitations Reference

> **Comprehensive guide to Linden Scripting Language (LSL) quirks, limitations, and non-obvious behaviors**
>
> This document catalogs the specific limitations and quirks of LSL that differ from conventional programming languages. Use this as a reference when coding or debugging LSL scripts.

---

## Table of Contents

1. [Syntax Limitations](#syntax-limitations)
2. [Control Flow Restrictions](#control-flow-restrictions)
3. [Function-Specific Quirks](#function-specific-quirks)
4. [Memory Management](#memory-management)
5. [Event Model](#event-model)
6. [State Management](#state-management)
7. [Data Types & Structures](#data-types--structures)
8. [Communication & Listeners](#communication--listeners)
9. [JSON Handling](#json-handling)
10. [Performance Considerations](#performance-considerations)
11. [Quick Reference: Common Pitfalls](#quick-reference-common-pitfalls)
12. [Reserved Keywords](#reserved-keywords-cannot-use-as-variable-names)
13. [Code Review Checklist](#code-review-checklist)
14. [Documentation Guidelines](#documentation-guidelines)
15. [Coding Standards](#coding-standards)
16. [Versioning Specification](#versioning-specification)

---

## Syntax Limitations

### No Ternary Operator

**Does NOT work:**
```lsl
integer z = (a > b) ? 3 : 5;  // SYNTAX ERROR
```

**Must use:**
```lsl
integer z;
if (a > b) {
    z = 3;
}
else {
    z = 5;
}
```

**Why:** LSL does not support the ternary conditional operator (`? :`). Always use explicit `if/else` statements.

---

### No Switch Statement

**Does NOT work:**
```lsl
switch (value) {  // SYNTAX ERROR
    case 1:
        doSomething();
        break;
    case 2:
        doOther();
        break;
}
```

**Must use:**
```lsl
if (value == 1) {
    doSomething();
}
else if (value == 2) {
    doOther();
}
```

**Note:** Some third-party preprocessors (Firestorm Preprocessor, LSL PyOptimizer) add switch support, but native LSL does not have it.

---

### No Break or Continue in Loops

**Does NOT work:**
```lsl
while (condition) {
    if (skipCondition) continue;  // SYNTAX ERROR
    if (exitCondition) break;     // SYNTAX ERROR
}
```

**Must use jump labels:**
```lsl
while (condition) {
    if (skipCondition) jump skip;
    if (exitCondition) jump done;

    // normal processing

    @skip;
}
@done;
```

**Alternative - return from function:**
```lsl
doWork() {
    integer i;
    for (i = 0; i < 10; i++) {
        if (shouldExit) return;  // Exit function entirely
        // work
    }
}
```

---

### No Chained Declarations

**Does NOT work:**
```lsl
integer a = 1, b = 2, c = 3;  // SYNTAX ERROR
```

**Must declare separately:**
```lsl
integer a = 1;
integer b = 2;
integer c = 3;
```

---

### No Function Overloading or Default Parameters

**Does NOT work:**
```lsl
myFunction(integer a) { }
myFunction(integer a, integer b) { }  // SYNTAX ERROR - duplicate function

myFunction(integer a, integer b = 5) { }  // SYNTAX ERROR - default params not supported
```

**Must use unique names:**
```lsl
myFunction(integer a) { }
myFunctionWithB(integer a, integer b) { }
```

---

## Control Flow Restrictions

### Do-While Requires Explicit Structure

**Correct syntax:**
```lsl
do {
    // code
} while (condition);
```

**Note:** The body MUST be enclosed in braces `{}` even for single statements.

---

### Jump Labels Are Case-Sensitive

```lsl
@MyLabel;
jump mylabel;  // ERROR - does not match case
jump MyLabel;  // OK
```

---

## Function-Specific Quirks

### llDialog - Button Order (CRITICAL)

**Button Layout:** llDialog arranges buttons in a **3x4 grid** from **bottom-left to top-right**.

**List order → Display position:**
```
List:     [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

Display:  [9] [10] [11]     Row 4 (top)
          [6]  [7]  [8]     Row 3
          [3]  [4]  [5]     Row 2
          [0]  [1]  [2]     Row 1 (bottom)
```

**Example - Counterintuitive ordering:**
```lsl
list buttons = ["A", "B", "C", "D", "E", "F"];

llDialog(user, "Pick one:", buttons, channel);

// User sees:
//  [D] [E] [F]
//  [A] [B] [C]
```

**Helper function to reverse order:**
```lsl
list order_buttons(list btns) {
    return
        llList2List(btns, -3, -1) +   // Last 3 items
        llList2List(btns, -6, -4) +   // Next 3
        llList2List(btns, -9, -7) +   // Next 3
        llList2List(btns, -12, -10);  // First 3
}
```

**Constraints:**
- Maximum **12 buttons**
- Each button label max **24 characters**
- Use single space `" "` for padding (not empty string `""`)

**Padding to multiples of 3:**
```lsl
list buttons = ["OK", "Cancel"];
// Add padding
while (llGetListLength(buttons) % 3 != 0) {
    buttons += " ";  // Single space, not ""
}
// Result: ["OK", "Cancel", " "]
```

---

### llListen - Automatic Cleanup

**Listener Lifecycle:**
```lsl
integer gListen;

default {
    state_entry() {
        gListen = llListen(123, "", NULL_KEY, "");
        // Listener is ACTIVE
    }

    // Changing state AUTOMATICALLY removes ALL listeners
    touch_start(integer num) {
        state other;
        // gListen is now INVALID - no need to call llListenRemove
    }
}

state other {
    state_entry() {
        // Old listener from default state is GONE
        // Must create new listener if needed
    }
}
```

**Best Practice:**
- Use `llListenRemove()` only when removing listener **within the same state**
- State changes automatically clean up listeners
- Always scope listeners: `llListen(chan, "", avatar, "")` not `llListen(chan, "", NULL_KEY, "")`
- **NEVER** listen on channel 0 (PUBLIC_CHANNEL) unless absolutely necessary - causes lag

---

### llSetTimerEvent - Single Timer Limit

**Only ONE timer per script:**
```lsl
llSetTimerEvent(5.0);   // Timer fires every 5 seconds
llSetTimerEvent(10.0);  // Previous timer REPLACED - now fires every 10 seconds
```

**Calling llSetTimerEvent resets the clock:**
```lsl
llSetTimerEvent(5.0);
llSleep(4.0);
llSetTimerEvent(5.0);  // Timer RESETS - another 5 seconds from NOW
```

**Timer persists across state changes:**
```lsl
default {
    state_entry() {
        llSetTimerEvent(5.0);
        state other;  // Timer KEEPS RUNNING
    }
}

state other {
    timer() {
        // This will fire - timer persisted
        llSetTimerEvent(0.0);  // Stop it explicitly
    }
}
```

**Minimum practical interval:** ~0.2 seconds
- Intervals below 0.2s are unreliable
- Accuracy degrades with high script count (>4000 scripts in sim)
- Affected by time dilation and event queue backlog

---

### llGetFreeMemory - Historic Minimum

**Returns lowest EVER memory, not current:**
```lsl
llOwnerSay((string)llGetFreeMemory());  // e.g., 50000
someHeavyOperation();                   // Uses 30000 bytes temporarily
llOwnerSay((string)llGetFreeMemory());  // Still shows 20000 (historic low)
// Memory freed after operation, but llGetFreeMemory shows worst case
```

**What it measures:** The **lowest amount of free memory** the script has had since the last reset.

**Why this matters:** You can't use llGetFreeMemory to detect temporary spikes; it only tells you the worst-case memory usage.

---

### llSensor / llSensorRepeat - State Behavior

**Sensors DO NOT persist across states:**
```lsl
default {
    state_entry() {
        llSensorRepeat("", NULL_KEY, AGENT, 96.0, PI, 5.0);
        state other;  // Sensor STOPS
    }
}

state other {
    sensor(integer num) {
        // This will NEVER fire - sensor was cleared on state change
    }
}
```

**Contrast with llTarget:**
- `llTarget` and `llRotTarget` **DO** persist across state changes
- `llSensor` and `llSensorRepeat` **DO NOT** persist

---

## Memory Management

### Memory Limits

| VM Type | Memory Available |
|---------|------------------|
| LSL2 (legacy) | 16 KB |
| Mono | 64 KB |

**Recommendation:** Always compile as Mono for 4x more memory.

---

### Stack-Heap Collision

**Architecture:**
```
|<-- Bytecode -->|<-- Statics -->|<-- Heap ⟶|     |⟵ Stack -->|
                                  grows →        ← grows
```

**Collision occurs when:**
- Stack (function calls, local variables) grows down
- Heap (strings, lists, dynamic allocations) grows up
- They meet in the middle → **Stack-Heap Collision**

**Error message:**
```
Script run-time error: Stack-Heap Collision
```

**Common causes:**
1. Deep nested function calls
2. Large lists in local variables
3. Building large strings inside functions
4. Recursive functions (very dangerous in LSL)

**Prevention strategies:**
```lsl
// BAD - large list as local variable
myFunction() {
    list bigList = [];
    integer i;
    for (i = 0; i < 1000; i++) {
        bigList += [i];  // Growing list on stack
    }
}

// GOOD - use global
list gBigList = [];
myFunction() {
    integer i;
    for (i = 0; i < 1000; i++) {
        gBigList += [i];  // Growing list in heap
    }
}
```

**Check before heavy operations:**
```lsl
if (llGetFreeMemory() < 4096) {
    llOwnerSay("Low memory - skipping operation");
    return;
}
```

---

### List Memory Usage

**Lists are expensive:**
- Each list element: ~68 bytes overhead + data
- Strings in lists: overhead + string length
- Concatenation creates NEW list (original + new items)

**Example:**
```lsl
list data = ["hello", "world"];
// Uses approximately: 68*2 + 5 + 5 = 146 bytes

data += ["foo"];
// Creates NEW list: ~214 bytes
// Old list is garbage collected
```

**Optimization:**
```lsl
// BAD - creates new list each iteration
list result = [];
integer i;
for (i = 0; i < 100; i++) {
    result += [i];  // 100 list allocations
}

// BETTER - build in chunks or use stride pattern
list result = [];
integer i;
for (i = 0; i < 100; i += 4) {
    result += [i, i+1, i+2, i+3];  // 25 allocations
}
```

---

## Event Model

### Events Are Never Concurrent

**Key principle:** Only ONE event executes at a time.

```lsl
touch_start(integer num) {
    llSleep(5.0);  // Blocks for 5 seconds
    // Timer events queued during this time will wait
}

timer() {
    // Won't execute until touch_start completes
}
```

**Event Queue:**
- Events are queued when handler is busy
- **Queue limit:** ~300 events
- Exceeding queue limit drops oldest events
- No guaranteed ordering between different event types

---

### Event Delays

**Default event delays per event type:**
- touch: 0.1s minimum between events
- collision: 0.2s minimum
- sensor: user-specified via llSensorRepeat

**Impact:**
```lsl
touch_start(integer num) {
    llOwnerSay("Touched");
}
// Rapid clicking: max 10 touch events/second
```

---

### state_entry Misconceptions

**Common mistake:**
```lsl
// WRONG assumption: state_entry fires every time object is rezzed
default {
    state_entry() {
        llOwnerSay("I'm alive!");  // May not see this on rez from inventory
    }
}
```

**Reality:**
- `state_entry` fires only when entering a new state
- When saved to inventory, **current state is preserved**
- When rezzed from inventory with saved state, no state change = no `state_entry`

**Solution - Always-run initialization:**
```lsl
init() {
    // Initialization code
    llOwnerSay("Initialized");
}

default {
    state_entry() {
        init();
    }

    on_rez(integer start_param) {
        init();  // Also run on rez
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            init();  // Also run on owner change
        }
    }
}
```

---

## State Management

### State Changes Clear Event Queue

```lsl
default {
    touch_start(integer num) {
        llSensorRepeat("", NULL_KEY, AGENT, 10.0, PI, 1.0);
        state scanning;
        // All pending events CLEARED
    }
}

state scanning {
    state_entry() {
        // Event queue is empty now
        // Sensor must be restarted (it was stopped)
    }
}
```

### What Persists Across State Changes

| Feature | Persists? |
|---------|-----------|
| Global variables | ✅ YES |
| Local variables | ❌ NO |
| Timers (llSetTimerEvent) | ✅ YES |
| Listeners (llListen) | ❌ NO |
| Sensors (llSensorRepeat) | ❌ NO |
| Targets (llTarget, llRotTarget) | ✅ YES |
| Pending events | ❌ NO (cleared) |
| Particle systems | ✅ YES |

**Best practice:**
```lsl
state_exit() {
    // Clean up before leaving
    llSetTimerEvent(0.0);        // Stop timer if not needed
    llSensorRemove();             // Redundant but explicit
    // Listeners auto-removed
}

state_entry() {
    // Set up new state
    llSetTimerEvent(5.0);
    gListen = llListen(chan, "", NULL_KEY, "");
}
```

---

## Data Types & Structures

### No Nested Lists

**Does NOT work:**
```lsl
list nested = [
    [1, 2, 3],      // FLATTENED
    [4, 5, 6]
];
// Result: [1, 2, 3, 4, 5, 6] - single flat list
```

**Workaround - Use JSON:**
```lsl
string nested = llList2Json(JSON_ARRAY, [
    llList2Json(JSON_ARRAY, [1, 2, 3]),
    llList2Json(JSON_ARRAY, [4, 5, 6])
]);
// nested = "[[1,2,3],[4,5,6]]"
```

---

### No Associative Arrays / Dictionaries

**No built-in key-value maps.**

**Workarounds:**

1. **Stride lists:**
```lsl
// [key, value, key, value, ...]
list data = ["name", "Alice", "age", "30"];
integer STRIDE = 2;

integer find_key(string key) {
    integer i;
    for (i = 0; i < llGetListLength(data); i += STRIDE) {
        if (llList2String(data, i) == key) {
            return i;
        }
    }
    return -1;
}

string get_value(string key) {
    integer idx = find_key(key);
    if (idx != -1) {
        return llList2String(data, idx + 1);
    }
    return "";
}
```

2. **JSON objects:**
```lsl
string data = llList2Json(JSON_OBJECT, [
    "name", "Alice",
    "age", 30
]);

string name = llJsonGetValue(data, ["name"]);  // "Alice"
```

---

### String Limitations

**No escape sequences beyond basics:**
- `\n` - newline (works)
- `\t` - tab (works)
- `\"` - quote (works)
- `\\` - backslash (works)
- Unicode escapes: **NOT SUPPORTED**

**No multiline string literals:**
```lsl
// Does NOT work
string text = "Line 1
               Line 2";  // SYNTAX ERROR

// Must use
string text = "Line 1\nLine 2";
```

---

### Type Coercion Quirks

**String to Integer:**
```lsl
(integer)"123"     // 123
(integer)"123abc"  // 123 (stops at first non-digit)
(integer)"abc"     // 0
(integer)""        // 0
```

**String to Float:**
```lsl
(float)"3.14"      // 3.14
(float)"3.14abc"   // 3.14
(float)"abc"       // 0.0
```

**Integer to String:**
```lsl
(string)123        // "123"
(string)(-5)       // "-5"
```

**Float precision loss:**
```lsl
float f = 1.23456789;
llOwnerSay((string)f);  // "1.234568" - precision lost
```

---

## Communication & Listeners

### llListen Performance

**Channel 0 (PUBLIC_CHANNEL) is EXPENSIVE:**
```lsl
// BAD - listens to ALL chat from EVERYONE
llListen(0, "", NULL_KEY, "");

// BETTER - filter by avatar
llListen(0, "", avatarKey, "");

// BEST - use private channel
integer chan = -1000000 - (integer)llFrand(1000000);
llListen(chan, "", avatarKey, "");
```

**Performance impact:**
- Open listen on quiet channel: minimal (single integer check)
- Open listen on channel 0: expensive (checks every message)
- Filtered listen: moderate (checks message against filter)

---

### Listener Limit

**Maximum active listeners per script:** 64

```lsl
list handles = [];
integer i;
for (i = 0; i < 65; i++) {
    handles += llListen(i, "", NULL_KEY, "");
    // 65th call returns 0 (failed)
}
```

**Workaround:** Remove unused listeners with `llListenRemove()`

---

### llMessageLinked Performance

**Fastest inter-script communication.**

```lsl
// In sending script
llMessageLinked(LINK_SET, 100, "data", NULL_KEY);

// In receiving script(s)
link_message(integer sender, integer num, string str, key id) {
    if (num == 100) {
        // Process message
    }
}
```

**Best practices:**
- Use JSON for structured data
- Use `num` parameter for message type routing
- `LINK_SET` broadcasts to all scripts in object
- No queuing issues (instant delivery)

---

## JSON Handling

### JSON_INVALID Return Values

**Critical quirk:**
```lsl
string json = llList2Json(JSON_OBJECT, ["key", "value"]);

// Non-existent key
string val = llJsonGetValue(json, ["badkey"]);
// val = JSON_INVALID (U+FDDO)

// But empty string values
json = llList2Json(JSON_OBJECT, ["key", ""]);
val = llJsonGetValue(json, ["key"]);
// val = JSON_NULL, not JSON_INVALID!

// And navigating through empty string
val = llJsonGetValue(json, ["key", "subkey"]);
// val = JSON_NULL (not JSON_INVALID as you'd expect)
```

**Safe checking:**
```lsl
integer json_has(string json, list path) {
    string val = llJsonGetValue(json, path);
    return (val != JSON_INVALID && val != JSON_NULL);
}
```

---

### llJsonSetValue Never Fails (Almost)

**Automatic type coercion:**
```lsl
string json = llList2Json(JSON_OBJECT, ["key", "value"]);

// Try to set array index on an object
json = llJsonSetValue(json, ["key", 0], "newval");
// Result: {"key":["newval"]} - object REPLACED with array!

// Try to set object key on an array
json = llList2Json(JSON_ARRAY, [1, 2, 3]);
json = llJsonSetValue(json, ["newkey"], "value");
// Result: {"newkey":"value"} - array REPLACED with object!
```

**Only failure:** negative array index or index > array length
```lsl
string json = llList2Json(JSON_ARRAY, [1, 2, 3]);
json = llJsonSetValue(json, [-1], "value");  // Returns JSON_INVALID
json = llJsonSetValue(json, [10], "value");  // Returns JSON_INVALID
```

---

### Integer Keys Auto-Convert

**In llJsonGetValue:**
```lsl
string json = llList2Json(JSON_OBJECT, ["123", "value"]);

// Integer specifier auto-converts to string
string val = llJsonGetValue(json, [123]);  // Works! Returns "value"
```

**In llJsonSetValue and llList2Json:**
```lsl
// Does NOT auto-convert
string json = llList2Json(JSON_OBJECT, [123, "value"]);  // Returns JSON_INVALID

// Must explicitly convert
json = llList2Json(JSON_OBJECT, [(string)123, "value"]);  // OK
```

---

### JSON Performance

**JSON is SLOWER than lists:**
```lsl
// llJsonSetValue is ~2.8x SLOWER than llListReplaceList for single value updates
```

**When to use JSON:**
- Inter-script messaging (human-readable, structured)
- Persistent storage (notecard format)
- Complex nested structures

**When to use lists:**
- Performance-critical local operations
- Simple arrays
- Stride-based structures

---

### Float Precision Loss in JSON

```lsl
float precise = 3.14159265358979;
string json = llList2Json(JSON_ARRAY, [precise]);
float restored = llJson2List(json)[0];
// restored = 3.141593 (precision lost)
```

**Workaround for precision-critical values:** Store as strings
```lsl
string json = llList2Json(JSON_OBJECT, ["value", (string)precise]);
```

---

## Performance Considerations

### Operator Performance

**Fastest to slowest:**
1. Integer arithmetic (`+`, `-`, `*`, `/`, `%`)
2. Float arithmetic
3. String concatenation (small strings)
4. List operations (`+`, `llListReplaceList`)
5. String operations on large strings
6. JSON operations
7. Dataserver queries
8. HTTP requests

---

### Function Call Overhead

**Inline simple operations when performance matters:**

```lsl
// BAD for hot path
integer add(integer a, integer b) {
    return a + b;
}

integer result = add(x, y);

// GOOD for hot path
integer result = x + y;
```

**But:** Prefer functions for readability except in tight loops.

---

### llSleep Is Evil

**Blocks the entire script:**
```lsl
touch_start(integer num) {
    llSleep(10.0);  // Script frozen for 10 seconds
    // No other events can process
}
```

**Alternatives:**
1. Use `llSetTimerEvent` for delays
2. Use state changes with timer
3. Use dataserver for async operations

---

### List Slicing Performance

**Extracting sublist:**
```lsl
// Fast - single operation
list sub = llList2List(bigList, 5, 10);

// Slow - multiple operations
list sub = [];
integer i;
for (i = 5; i <= 10; i++) {
    sub += llList2String(bigList, i);
}
```

---

### Cache Frequently-Used Values

```lsl
// BAD - repeated function calls
touch_start(integer num) {
    llOwnerSay("Owner: " + (string)llGetOwner());
    llMessageLinked(LINK_SET, 0, (string)llGetOwner(), NULL_KEY);
    llGiveInventory(llGetOwner(), "Object");
}

// GOOD - cache once
key gOwner;

state_entry() {
    gOwner = llGetOwner();
}

touch_start(integer num) {
    llOwnerSay("Owner: " + (string)gOwner);
    llMessageLinked(LINK_SET, 0, (string)gOwner, NULL_KEY);
    llGiveInventory(gOwner, "Object");
}

changed(integer change) {
    if (change & CHANGED_OWNER) {
        gOwner = llGetOwner();  // Update cache
    }
}
```

---

## Quick Reference: Common Pitfalls

| Issue | Symptom | Solution |
|-------|---------|----------|
| Ternary operator | Syntax error | Use `if/else` |
| Switch statement | Syntax error | Use `if/else if` chain |
| Break/continue | Syntax error | Use `jump` labels or `return` |
| Dialog buttons wrong order | Buttons appear scrambled | Remember bottom-left → top-right layout |
| Listener leak | Script lag, listener limit hit | Remove listeners with `llListenRemove()` or use state changes |
| Timer not firing | Timer seems broken | Check if `llSetTimerEvent()` called twice (resets clock) |
| State_entry not firing | Initialization skipped | Also call init code in `on_rez()` |
| Stack-Heap Collision | Script crashes with error | Move large data to globals, reduce nesting |
| JSON returns JSON_INVALID | Can't get value | Check for empty string values (return JSON_NULL) |
| List flattening | Nested list becomes flat | Use JSON for nested structures |
| Float precision loss | Numbers rounded | Store critical values as strings |
| Listen on channel 0 lag | Region lag | Use private negative channels |
| Memory reported incorrectly | llGetFreeMemory seems wrong | Returns historic minimum, not current |

---

## Reserved Keywords (Cannot Use as Variable Names)

### Control Flow
`default`, `do`, `else`, `for`, `if`, `jump`, `return`, `state`, `while`

### Types
`integer`, `float`, `string`, `key`, `list`, `vector`, `rotation`, `quaternion`

### Events
`at_rot_target`, `at_target`, `attach`, `changed`, `collision`, `collision_end`, `collision_start`, `control`, `dataserver`, `email`, `experience_permissions`, `experience_permissions_denied`, `http_request`, `http_response`, `land_collision`, `land_collision_end`, `land_collision_start`, `link_message`, `listen`, `money`, `moving_end`, `moving_start`, `no_sensor`, `not_at_rot_target`, `not_at_target`, `object_rez`, `on_rez`, `path_update`, `remote_data`, `run_time_permissions`, `sensor`, `state_entry`, `state_exit`, `timer`, `touch`, `touch_end`, `touch_start`, `transaction_result`

**Also avoid:** Built-in function names (e.g., `llDialog`, `llGetOwner`) and constants (e.g., `NULL_KEY`, `TRUE`, `FALSE`, `PI`).

---

## Code Review Checklist

**Use this end-of-pass checklist to confirm a script is release-ready.** Each bullet is a concrete requirement — do not ship until all apply.

### Syntax & Language Rules

- [ ] Must compile under LSL: no ternary (`?:`), no `switch`, no `break`/`continue`, no chained declarations, no default params/overloads
- [ ] Only supported LSL APIs are called (verify against the LSL reference)
- [ ] One symbol per line; all variables explicitly typed

### Events & States

- [ ] Event handlers are short (≈25 lines or fewer) and guarded against invalid input
- [ ] Persistent data lives in globals; no reliance on locals across state changes
- [ ] Every state transition **cleans up**: listeners removed, timers cancelled, particles/controls/animations stopped
- [ ] `on_rez`, `attach`, and `changed` handle resets and ownership/region transitions safely

### UI / Dialogs & Listeners

- [ ] ≤ 12 dialog buttons; padded to a multiple of 3 with a single space (`" "`)
- [ ] **Back** button present where navigation requires it; pagination uses `<<` and `>>` consistently
- [ ] If a special button (e.g., **Relax**) is reserved, its index is enforced and documented
- [ ] Dialog channel is a **random negative integer** per session; listeners are scoped to `(avatar, channel)` and removed on close

### Permissions & Animations

- [ ] Requests only the permissions it needs; no action taken before `run_time_permissions` grants them
- [ ] Denial paths are handled (user refusal does not break the script)
- [ ] Provides a **Relax/Stop** action to clear controls/animations

### Communication & Security

- [ ] Intra-object comms use link messages with JSON payloads that include a `type` field
- [ ] All inbound data is validated (expected sender, request/session IDs, schema)
- [ ] No control flow on public chat channel `0`; private **negative** channels only
- [ ] Output is throttled where appropriate to avoid spam and rate limits

### Performance & Memory (Stack-Heap Safety)

- [ ] No `llSleep` in hot paths; timers use sane intervals (≥ 1s unless justified)
- [ ] Buffers are reused; avoid repeated list slicing (`llList2List`, `llDeleteSubList`) in loops
- [ ] Strings are built with a **join-once** pattern; JSON kept shallow/compact
- [ ] Inventory counts, page indices, and heavy computations are cached and invalidated when needed
- [ ] Large temporaries are nulled after use; UI pages precomputed where possible
- [ ] `llGetFreeMemory()` checked before heavy operations; script degrades gracefully if low

### Logging & Debug

- [ ] `DEBUG` flag gates verbose logs; release builds default `DEBUG = FALSE`
- [ ] Log tags are consistent (e.g., `[MODULE]`); async flows include IDs for correlation
- [ ] No owner-spam during normal operation

### Documentation & Comments

- [ ] File header includes: ROLE, ABI & link numbers, permissions, events used, resource notes, constraints, known issues/TODOs
- [ ] Non-trivial functions document purpose, inputs/outputs, side effects, assumptions, and failure modes
- [ ] Inline comments explain **why** (design/rationale), and mark `TODO:`, `FIXME:`, `HACK:` with dates

### Lifecycle & Safety

- [ ] Soft-reset path exists and performs cleanup + (re)registration as applicable
- [ ] Heartbeats (if any) are used only for liveness, **not** for unrelated syncing
- [ ] Ownership/region changes trigger safe re-init and permission re-requests as needed
- [ ] Script fails **closed** on bad inputs (ignores/denies) without crashing

### Final Gate

- [ ] Trace a full happy path: touch → auth → UI open → click → action → Back → main. No leaks, no duplicates
- [ ] No orphaned listeners; memory before vs. after basic interaction remains stable
- [ ] Free memory after init meets project policy (e.g., > 4 KiB) or documented if tighter
- [ ] Version string present; `DEBUG` default confirmed for release

---

## Documentation Guidelines

### File Header Template

**Standard header format for all scripts:**

```lsl
/* =============================================================
   SCRIPT: <name>.lsl
   ROLE  : <what this script does>
   NOTES : <quirks, ABI versions, permissions, UI rules>
   ============================================================= */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

integer logd(string s) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[<TAG>] " + s);
    return 0;
}
```

### File Header Components

**ROLE / Summary:** One sentence on what the script does.

**ABI & Dependencies:** Link numbers used, message types, external modules.

**Permissions:** What is requested and why.

**Events Used:** Key events and the reason each exists.

**Resource Notes:** Timers, listeners, particles, HTTP caps.

**Constraints:** Known sim limits, viewer quirks, race conditions.

**Known Issues / TODO:** List with short bullets and dates.

### Function Documentation

For each non-trivial function include:

- **What it does / Why it exists** (primary intent, not line-by-line narration)
- **Inputs / Outputs** (types, units, ranges; `NULL_KEY` handling)
- **Side Effects** (listeners opened/removed, timers set, global mutations)
- **Assumptions / Invariants** (e.g., menu size ≤ 12, channel is negative)
- **Failure Modes** (e.g., permission not granted, JSON invalid)

### Inline Comments

- Prefer **why** over **what**; the code already says *what*
- Mark **problem areas** (race windows, throttles, rate limits) with `NOTE:`
- Mark **workarounds** for SL quirks (e.g., dataserver latency) with `WHY:`
- Document **UI layout logic** (e.g., why Relax sits at index 3; padding rules)
- Call out **magic numbers** and derive them briefly

### Change Rationale Blocks

At major edits, add a short `/* WHY: ... DATE: YYYY-MM-DD */` block near the change.

**Example:**
```lsl
/* WHY: We pin page size to 8 because one slot is reserved for "Relax" and we
   must keep the dialog a multiple of 3; see §14. DATE: 2025-09-23 */
```

### Comment Tags

- `TODO:` for planned work
- `FIXME:` for known bugs
- `HACK:` for temporary compromises

### Comment Style

- Use `//` for short notes; `/* ... */` for multi-line context
- Keep comments accurate; delete stale ones immediately

---

## Coding Standards

### Safe Defaults

- Use **negative, randomized dialog channels** per session
- Keep a **single, centralized** place for link numbers and message type strings
- Prefer **explicit** `if/else` over clever one-liners
- Return early on invalid input

### Memory Efficiency Best Practices

**Reuse buffers:**
```lsl
// Keep reusable strings/lists in globals; clear with "" or [] after use
list gBuffer = [];

buildData() {
    gBuffer = [1, 2, 3];
    llMessageLinked(LINK_SET, 0, llList2Json(JSON_ARRAY, gBuffer), NULL_KEY);
    gBuffer = [];  // Free memory
}
```

**Join strings once:**
```lsl
// BAD - repeated concatenation
string result = "";
integer i;
for (i = 0; i < 100; i++) {
    result += (string)i + " ";  // 100 allocations
}

// GOOD - join once
list parts = [];
integer i;
for (i = 0; i < 100; i++) {
    parts += (string)i;
}
string result = llDumpList2String(parts, " ");  // 1 allocation
```

**Precompute UI pages:**
```lsl
// Precompute/persist button pages; do not rebuild on every click
list gButtonPages = [];  // Built once in state_entry
```

### Helper Functions

**Debug logger:**
```lsl
integer DEBUG = FALSE;
integer logd(string s) {
    if (DEBUG) llOwnerSay("[TAG] " + s);
    return 0;
}
```

**JSON validation:**
```lsl
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
```

**Listener cleanup:**
```lsl
integer gListen = 0;

integer reset_listen() {
    if (gListen) llListenRemove(gListen);
    gListen = 0;
    return 0;
}
```

**Dialog with padding:**
```lsl
integer dialog_to(key who, string body, list buttons, integer chan) {
    integer n = llGetListLength(buttons);
    while ((n % 3) != 0) {
        buttons += " ";
        n += 1;
    }
    llDialog(who, body, buttons, chan);
    return 0;
}
```

**Memory guard:**
```lsl
integer mem_ok(integer need) {
    return (llGetFreeMemory() > need);
}
```

---

## Additional Resources

- **Official LSL Wiki:** https://wiki.secondlife.com/wiki/LSL_Portal
- **LSL Style Guide:** https://wiki.secondlife.com/wiki/LSL_Style_Guide
- **Common LSL Mistakes:** https://wiki.secondlife.com/wiki/Common_Script_Mistakes

---

## Versioning Specification

**Official versioning scheme for DS Collar Modular project**

### Version Format

```
[MAJOR].[MINOR]_[ENHANCEMENT]
```

**Components:**
- **MAJOR** - Major version number (integer)
- **MINOR** - Minor version number (integer, represents feature additions)
- **ENHANCEMENT** - Enhancement letter (a, b, c, etc., represents non-breaking improvements)

---

### Version Change Rules

#### 1. Security Fixes, Patches, and Hotfixes → **NO VERSION CHANGE**

**Definition:**
- Security vulnerability fixes
- Bug fixes that restore intended behavior
- Hotfixes for critical issues
- Performance optimizations that don't change behavior
- Code refactoring without functionality changes

**Versioning:**
- Version number **remains unchanged**
- Update header notes to document the fix

**Examples:**
```lsl
// BEFORE FIX
/* MODULE: ds_collar_kernel.lsl (v1.0 - Consolidated ABI)
   SECURITY AUDIT: ALL ISSUES FIXED */

// AFTER SECURITY FIX (version stays 1.0)
/* MODULE: ds_collar_kernel.lsl (v1.0 - Consolidated ABI)
   SECURITY AUDIT: ALL ISSUES FIXED

   SECURITY FIXES APPLIED:
   - [CRITICAL] Fixed authorization bypass in soft reset (2025-10-28)
   - [MEDIUM] Added overflow protection for timestamps (2025-10-28) */
```

**Rationale:** Security fixes and bug patches are maintenance activities that restore the contract promised by the current version. They do not add new functionality or change behavior beyond fixing defects.

---

#### 2. Enhancements → **MINOR INCREMENT** (underscore notation)

**Definition:**
- Quality-of-life improvements
- UI/UX refinements
- Behavior tweaks that improve user experience
- Non-breaking changes to existing features
- Optimizations that visibly improve performance
- Additional options/settings for existing features

**Versioning:**
- Append `_a` to current version
- Subsequent enhancements increment the letter: `_b`, `_c`, etc.
- After `_z`, use `_aa`, `_ab`, etc.

**Examples:**

| Current Version | Change | New Version |
|----------------|--------|-------------|
| `1.0` | Add volume slider to bell | `1.0_a` |
| `1.0_a` | Improve dialog layout | `1.0_b` |
| `1.0_b` | Add color options to existing menu | `1.0_c` |
| `2.3` | Enhance animation smoothness | `2.3_a` |

**Code Example:**
```lsl
// BEFORE ENHANCEMENT
/* PLUGIN: ds_collar_plugin_bell.lsl (v1.0 - Consolidated ABI)

   FEATURES:
   - Bell visibility toggle
   - Sound on/off */

// AFTER ENHANCEMENT (volume control added)
/* PLUGIN: ds_collar_plugin_bell.lsl (v1.0_a - Volume Control)

   FEATURES:
   - Bell visibility toggle
   - Sound on/off
   - Volume adjustment (10% increments) */
```

**Rationale:** Enhancements improve existing functionality without fundamentally changing what the script does or adding entirely new capabilities. The underscore notation indicates these are "polish" updates to the current feature set.

---

#### 3. Feature Additions → **DOT INCREMENT** (minor version)

**Definition:**
- New features/commands
- New menu sections
- New plugins
- New kernel modules
- Integration with new external systems
- Breaking changes to existing features (with migration path)

**Versioning:**
- Increment MINOR version: `1.0` → `1.1` → `1.2`
- Reset enhancement letter (remove `_x` suffix)
- MAJOR version stays the same

**Examples:**

| Current Version | Change | New Version |
|----------------|--------|-------------|
| `1.0` | Add TPE mode plugin | `1.1` |
| `1.1` | Add RLV relay plugin | `1.2` |
| `1.2_c` | Add blacklist management | `1.3` |
| `2.0` | Add coffle system | `2.1` |

**Code Example:**
```lsl
// NEW FEATURE - version increments from 1.2 to 1.3
/* PLUGIN: ds_collar_plugin_trustees.lsl (v1.3 - New Feature)

   PURPOSE: Trustee management system

   FEATURES:
   - Add trustees via sensor
   - Remove trustees from list
   - View current trustees */
```

**Rationale:** Feature additions expand the capabilities of the system. Each new feature represents a meaningful expansion of what the collar can do, warranting a version increment that clearly signals "this version can do more than the last."

---

#### 4. Major Overhauls → **MAJOR VERSION CHANGE**

**Definition:**
- Complete architectural redesign
- Breaking API/ABI changes
- Migration from old system to new system
- Fundamental changes to how the system works
- Removal of deprecated features
- Changes requiring user data migration

**Versioning:**
- Increment MAJOR version: `1.x` → `2.0`
- Reset MINOR to `0`
- Remove enhancement letter

**Examples:**

| Current Version | Change | New Version |
|----------------|--------|-------------|
| `1.9` | Rewrite to consolidated ABI | `2.0` |
| `2.5_d` | Move to microservices architecture | `3.0` |
| `3.2` | Complete protocol overhaul | `4.0` |

**Code Example:**
```lsl
// MAJOR OVERHAUL - v1.x → v2.0
/* MODULE: ds_collar_kernel.lsl (v2.0 - Event-Driven Architecture)

   BREAKING CHANGES FROM v1.x:
   - Migrated from polling to event-driven model
   - Removed deprecated LEGACY_CHANNEL (600)
   - Changed JSON payload format (see MIGRATION.md)
   - Requires all plugins to be updated to v2.0+ */
```

**Rationale:** Major overhauls represent fundamental changes that may break compatibility with older scripts or require users to adapt. The major version change signals "this is a new generation of the system."

---

### Version Application Guidelines

#### Header Format

**Standard header with version:**
```lsl
/* =============================================================================
   [TYPE]: [filename].lsl (v[VERSION] - [DESCRIPTION])

   [Additional header content...]
   ============================================================================= */
```

**Types:**
- `MODULE:` for kernel modules
- `PLUGIN:` for plugins
- `CONTROL HUD:` for HUD scripts
- `LEASH HOLDER:` for holder scripts

#### When to Update Versions

**Update immediately when:**
- Adding a new feature (dot increment)
- Pushing an enhancement (underscore increment)
- Completing a major overhaul (major increment)

**Do NOT update when:**
- Fixing bugs
- Applying security patches
- Refactoring code
- Adding comments/documentation
- Optimizing existing behavior

#### Documenting Changes

**For security fixes/patches (no version change):**
```lsl
/* MODULE: ds_collar_kernel.lsl (v1.0 - Consolidated ABI)
   SECURITY AUDIT: ALL ISSUES FIXED

   SECURITY FIXES APPLIED:
   - [CRITICAL] Description of fix (DATE: YYYY-MM-DD)
   - [MEDIUM] Description of fix (DATE: YYYY-MM-DD)
   ============================================================================= */
```

**For enhancements:**
```lsl
/* PLUGIN: ds_collar_plugin_bell.lsl (v1.0_a - Volume Control)

   ENHANCEMENTS IN v1.0_a:
   - Added volume adjustment slider (10% increments)
   - Improved jingle sound continuity
   ============================================================================= */
```

**For feature additions:**
```lsl
/* PLUGIN: ds_collar_plugin_trustees.lsl (v1.3 - New Feature)

   NEW IN v1.3:
   - Trustee management system
   - Sensor-based avatar selection
   - Persistent trustee list storage
   ============================================================================= */
```

**For major overhauls:**
```lsl
/* MODULE: ds_collar_kernel.lsl (v2.0 - Event-Driven Architecture)

   BREAKING CHANGES FROM v1.x:
   - [List breaking changes]
   - [Migration requirements]

   NEW IN v2.0:
   - [List new capabilities]
   ============================================================================= */
```

---

### Version Progression Examples

**Example 1: Feature Development Lifecycle**

```
v1.0           Initial release (kernel + 8 modules + 10 plugins)
v1.0           Security fix: Authorization bypass patch (no version change)
v1.0_a         Enhancement: Improved dialog layouts
v1.0_a         Hotfix: Memory leak in particle system (no version change)
v1.0_b         Enhancement: Added color customization
v1.1           Addition: New TPE mode plugin
v1.1           Bug fix: Timer cleanup issue (no version change)
v1.1_a         Enhancement: TPE confirmation dialog improvements
v1.2           Addition: New coffle system
v2.0           Major overhaul: Consolidated ABI migration
```

**Example 2: Single Script Evolution**

```
ds_collar_plugin_bell.lsl

v1.0           - Initial release (visibility toggle, sound on/off)
v1.0           - Security fix: Channel leak prevention
v1.0_a         - Enhancement: Volume adjustment added (10% increments)
v1.0_b         - Enhancement: Movement detection improved
v1.1           - Addition: Multiple bell sounds support
v1.1           - Bug fix: Sound persistence issue
v1.1_a         - Enhancement: Sound preview in menu
v2.0           - Major overhaul: Integrated with new audio engine
```

---

### Edge Cases and Special Situations

**Case 1: Multiple Changes in One Update**

If an update contains multiple types of changes, use the highest-impact rule:

- Security fix + Enhancement = **Enhancement** (version changes to `_a`)
- Enhancement + Feature addition = **Feature addition** (version increments minor)
- Feature addition + Major overhaul = **Major overhaul** (version increments major)

**Example:**
```
Current: v1.2_a
Changes: Bug fix + new feature
Result: v1.3 (feature addition wins)
```

**Case 2: Reverting an Enhancement**

If an enhancement is rolled back:
- Keep the version number (don't decrement)
- Document the reversion in the header

```lsl
/* PLUGIN: ds_collar_plugin_bell.lsl (v1.0_b - Reverted Volume Control)

   CHANGES IN v1.0_b:
   - Reverted volume control feature (compatibility issues)
   - Restored v1.0 behavior
   ============================================================================= */
```

**Case 3: Enhancement After Feature Addition**

Enhancements reset after feature additions:

```
v1.2     → Feature added
v1.2_a   → Enhancement to v1.2
v1.2_b   → Another enhancement
v1.3     → New feature added (enhancement suffix removed)
v1.3_a   → Enhancement to v1.3
```

**Case 4: Long Enhancement Chains**

After `_z`, continue with double letters:

```
v1.0_y
v1.0_z
v1.0_aa
v1.0_ab
v1.0_az
v1.0_ba
```

**Recommendation:** If you reach `_z`, consider whether you should be doing a minor version increment (v1.1) instead, as you may have accumulated enough enhancements to constitute a meaningful update.

**Case 5: Hotfix During Development**

If working on v1.1 but need to hotfix v1.0:

1. Apply hotfix to v1.0 (version stays v1.0)
2. Merge hotfix into v1.1 development
3. v1.1 remains v1.1 (hotfix doesn't change target version)

**Case 6: Independent Script Versions**

Scripts can have different versions:

```
ds_collar_kernel.lsl           v1.5
ds_collar_kmod_auth.lsl        v1.5_a
ds_collar_plugin_bell.lsl      v1.3_b
ds_collar_plugin_tpe.lsl       v1.5
```

However, for production releases, synchronize versions where possible:

```
Production Release v1.0:
  - All kernel modules: v1.0
  - All plugins: v1.0
  - HUD: v1.0
  - Holder: v1.0
```

---

### Version Compatibility

**ABI Compatibility Matrix:**

| Version Type | ABI Compatible? | Can Mix Versions? |
|--------------|-----------------|-------------------|
| Security fixes (same version) | ✅ Yes | ✅ Yes |
| Enhancements (`_a`, `_b`) | ✅ Yes | ✅ Yes |
| Feature additions (1.0 → 1.1) | ✅ Usually* | ⚠️ Check notes |
| Major overhauls (1.x → 2.0) | ❌ No | ❌ No |

**\* Feature additions are ABI-compatible unless they modify core channels or message formats. Always check release notes.**

**Compatibility Guidelines:**

Safe mixing:
```
Kernel: v1.2
Modules: v1.2, v1.2_a, v1.2_b (OK - all compatible)
Plugins: v1.2_a, v1.2_c (OK - all compatible)
```

Unsafe mixing:
```
Kernel: v2.0
Modules: v1.9 (NOT OK - major version mismatch)
```

When in doubt:
- Same MAJOR.MINOR = Compatible
- Different MAJOR = Incompatible
- Different enhancements = Compatible

---

### Summary Chart

| Change Type | Version Change | Example | Compatibility |
|------------|----------------|---------|---------------|
| **Security fix** | None | v1.0 → v1.0 | ✅ Full |
| **Bug fix** | None | v1.2_a → v1.2_a | ✅ Full |
| **Hotfix** | None | v1.5 → v1.5 | ✅ Full |
| **Enhancement** | Add/increment `_x` | v1.0 → v1.0_a | ✅ Full |
| **Feature addition** | Increment minor | v1.0_b → v1.1 | ⚠️ Usually |
| **Major overhaul** | Increment major | v1.9 → v2.0 | ❌ Breaking |

---

### Release Checklist

Before releasing a version:

- [ ] Determine change type (security/enhancement/addition/overhaul)
- [ ] Apply appropriate version number to all affected scripts
- [ ] Update script headers with version and change description
- [ ] Document changes in commit message
- [ ] For major versions: Create MIGRATION.md guide
- [ ] For features: Update README.md with new capabilities
- [ ] Test compatibility with existing scripts
- [ ] Tag release in git with format: `vMAJOR.MINOR` or `vMAJOR.MINOR_ENHANCEMENT`

---

### Git Tag Format

**Tag format:**
```
v[MAJOR].[MINOR]
v[MAJOR].[MINOR]_[ENHANCEMENT]
```

**Examples:**
```bash
git tag -a v1.0 -m "Initial production release"
git tag -a v1.0_a -m "Enhanced bell volume control"
git tag -a v1.1 -m "Added TPE mode plugin"
git tag -a v2.0 -m "Consolidated ABI overhaul"
```

---

### FAQ

**Q: What if I fix a bug while adding a feature?**

**A:** The feature addition takes precedence. Increment the minor version (e.g., v1.0 → v1.1). The bug fix is included as part of the new version.

**Q: Can I skip enhancement letters (e.g., v1.0_a → v1.0_c)?**

**A:** No. Enhancement letters should increment sequentially to provide a clear history of changes.

**Q: What if I want to add a feature to an old version?**

**A:** Create a branch for the old version, add the feature there (increment minor), and merge forward if needed. Example: v1.2 branch receives a feature → becomes v1.2.1 in that branch.

Alternatively, use a different branch name scheme:
```
v1.2.1 (feature backport to v1.2)
v1.3   (mainline with original features)
```

**Q: How do I version a completely new script?**

**A:** New scripts start at the project's current major version with minor 0:
- If project is at v1.x: New script starts at v1.0
- If project is at v2.x: New script starts at v2.0

**Q: What about experimental/beta features?**

**A:** Use branch names or tags with suffixes:
```
v1.1-beta
v1.1-experimental
v1.1-rc1 (release candidate)
```

Once stable, release as v1.1 without suffix.

---

## Document Version

**Version:** 1.0
**Last Updated:** 2025-10-28
**Maintained by:** DS Collar Modular Project

---

*This document is intended as a practical reference. For comprehensive API documentation, consult the official Second Life LSL Wiki.*
