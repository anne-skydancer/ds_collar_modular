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

## Additional Resources

- **Official LSL Wiki:** https://wiki.secondlife.com/wiki/LSL_Portal
- **LSL Style Guide:** https://wiki.secondlife.com/wiki/LSL_Style_Guide
- **Common LSL Mistakes:** https://wiki.secondlife.com/wiki/Common_Script_Mistakes

---

## Document Version

**Version:** 1.0
**Last Updated:** 2025-10-28
**Maintained by:** DS Collar Modular Project

---

*This document is intended as a practical reference. For comprehensive API documentation, consult the official Second Life LSL Wiki.*
