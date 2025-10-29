# LSL Function Declaration Reference

## Overview

This document provides a comprehensive reference for valid function declaration types in Linden Scripting Language (LSL), based on the official LSL Wiki and API documentation.

**Reference Sources:**
- [LSL Portal - Second Life Wiki](https://wiki.secondlife.com/wiki/LSL_Portal)
- [LSL Types - Second Life Wiki](https://wiki.secondlife.com/wiki/Category:LSL_Types)
- [LSL Functions - Second Life Wiki](https://wiki.secondlife.com/wiki/Category:LSL_Functions)

## Function Declaration Syntax

### Basic Syntax

```lsl
return_type function_name(parameter_type parameter_name, ...) {
    // function body
    return value;  // if return_type is not void
}
```

### Key Rules

1. **User-defined functions** must be declared before `default` state or any other state blocks
2. **Function names** in this codebase follow **camelCase** convention (see STYLE_GUIDE.md)
3. **LSL uses pass-by-value** semantics for all types - functions receive copies, not references
4. **Built-in LSL functions** follow naming pattern `llFunctionName()` with the `ll` prefix (Linden Library)

## Valid LSL Data Types

LSL supports exactly **seven (7)** data types for function declarations:

| Type | Description | Example Values |
|------|-------------|----------------|
| `integer` | 32-bit signed integers | `0`, `42`, `-100`, `0xFFFFFFFF` |
| `float` | Single-precision floating-point | `0.0`, `3.14159`, `-2.5` |
| `string` | Text data | `"Hello"`, `""`, `"multi\nline"` |
| `key` | UUID identifiers | `"550e8400-e29b-41d4-a716-446655440000"`, `NULL_KEY` |
| `vector` | 3D coordinates (x, y, z) | `<1.0, 2.0, 3.0>`, `ZERO_VECTOR` |
| `rotation` | Quaternion orientation | `<0.0, 0.0, 0.0, 1.0>`, `ZERO_ROTATION` |
| `list` | Ordered collection of mixed types | `[]`, `[1, "text", <0,0,1>]` |

### Special Return Type: Void Functions

Functions that do not return a value have **no explicit return type** in LSL. Simply omit the return type:

```lsl
// Void function - no return type specified
cacheName(key k, string n) {
    // performs action but returns nothing
}
```

**Note:** In LSL, there is no `void` keyword. Functions without a return type declaration are implicitly void.

## Function Declaration Examples

### Integer Return Type

```lsl
// Returns TRUE (1) or FALSE (0)
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

// Returns computed access control level
integer compute_acl_level(key av) {
    if (is_owner(av)) return 100;
    if (listHasKey(TrusteeKeys, av)) return 80;
    return 0;
}

// Returns current Unix timestamp
integer now() {
    integer unix_time = llGetUnixTime();
    if (unix_time < 0) {
        llOwnerSay("ERROR: Unix timestamp overflow detected!");
        return 0;
    }
    return unix_time;
}

// Returns count from inventory
integer countScripts() {
    integer count = 0;
    integer i;
    integer inv_count = llGetInventoryNumber(INVENTORY_SCRIPT);
    for (i = 0; i < inv_count; i = i + 1) {
        count = count + 1;
    }
    return count;
}
```

**Common Uses:**
- Boolean flags (TRUE/FALSE)
- Counters and indices
- Access control levels
- Timestamps
- Error codes

### Float Return Type

```lsl
// Returns distance between two positions
float getDistance(vector pos1, vector pos2) {
    return llVecDist(pos1, pos2);
}

// Returns angle in radians
float getAngle(vector direction) {
    return llAtan2(direction.y, direction.x);
}
```

**Common Uses:**
- Mathematical calculations
- Distances and measurements
- Time intervals (seconds)
- Angles and rotations
- Percentages and ratios

### String Return Type

```lsl
// Returns session identifier
string genSession() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

// Returns cached name or requests it
string getName(key k) {
    if (k == NULL_KEY) return "";
    integer idx = llListFindList(NameCache, [k]);
    if (idx != -1) {
        return llList2String(NameCache, idx + 1);
    }
    // Fallback: request name from dataserver
    llRequestAgentData(k, DATA_NAME);
    return "...";
}

// Returns truncated string
string truncateName(string name, integer max_len) {
    if (llStringLength(name) <= max_len) return name;
    return llGetSubString(name, 0, max_len - 4) + "...";
}

// Returns normalized boolean string
string normalize_bool(string s) {
    s = llToLower(llStringTrim(s, STRING_TRIM));
    if (s == "1" || s == "true" || s == "yes" || s == "on") return "1";
    if (s == "0" || s == "false" || s == "no" || s == "off") return "0";
    return s;
}
```

**Common Uses:**
- Session IDs and tokens
- Formatted messages and reports
- Name lookups and caching
- JSON string construction
- Configuration values

### Key Return Type

```lsl
// Returns primary owner's key
key getPrimaryOwner() {
    if (MultiOwnerMode && llGetListLength(OwnerKeys) > 0) {
        return llList2Key(OwnerKeys, 0);
    }
    if (OwnerKey != NULL_KEY) {
        return OwnerKey;
    }
    return llGetOwner();
}

// Returns prim key by name search
key primByName(string wantLower) {
    integer link_count = llGetNumberOfPrims();
    integer i;
    for (i = 1; i <= link_count; i = i + 1) {
        string name = llToLower(llGetLinkName(i));
        if (name == wantLower) {
            return llGetLinkKey(i);
        }
    }
    return NULL_KEY;
}

// Returns leash attachment point key
key leashPrimKey() {
    key k = primByName("leashpoint");
    if (k == NULL_KEY) k = primByDesc("leashpoint");
    if (k == NULL_KEY) k = llGetLinkKey(1);
    return k;
}
```

**Common Uses:**
- Avatar and object identifiers
- Owner/user lookups
- Prim/link references
- Query IDs from dataserver
- Unique tokens

### Vector Return Type

```lsl
// Returns position offset for particles
vector getLeashOffset() {
    return <0.0, 0.0, 0.1>;
}

// Returns color from settings
vector getColor() {
    return <1.0, 1.0, 1.0>;  // White
}

// Returns midpoint between two positions
vector getMidpoint(vector pos1, vector pos2) {
    return (pos1 + pos2) / 2.0;
}
```

**Common Uses:**
- Positions (x, y, z coordinates)
- Colors (RGB values 0.0-1.0)
- Velocities and forces
- Offsets and directions
- Particle system parameters

### Rotation Return Type

```lsl
// Returns look-at rotation toward target
rotation getLookRotation(vector target_pos) {
    vector my_pos = llGetPos();
    vector direction = llVecNorm(target_pos - my_pos);
    return llRotBetween(<1.0, 0.0, 0.0>, direction);
}

// Returns relative rotation
rotation getRelativeRotation(rotation base, rotation offset) {
    return base * offset;
}
```

**Common Uses:**
- Object orientations
- Rotational transforms
- Look-at calculations
- Relative rotations
- Quaternion math

### List Return Type

```lsl
// Returns list of blacklisted names
list blacklist_names() {
    list names = [];
    integer i;
    integer len = llGetListLength(Blacklist);
    for (i = 0; i < len; i = i + 1) {
        key k = llList2Key(Blacklist, i);
        names = names + [getName(k)];
    }
    return names;
}

// Returns filtered plugin list
list get_session_filtered_plugins(integer session_idx) {
    integer acl = get_session_acl(session_idx);
    list filtered = [];
    integer i;
    integer len = llGetListLength(RegisteredPlugins);
    for (i = 0; i < len; i = i + STRIDE) {
        integer min_acl = llList2Integer(RegisteredPlugins, i + IDX_MIN_ACL);
        if (acl >= min_acl) {
            string ctx = llList2String(RegisteredPlugins, i + IDX_CONTEXT);
            string lbl = llList2String(RegisteredPlugins, i + IDX_LABEL);
            filtered = filtered + [ctx, lbl];
        }
    }
    return filtered;
}

// Returns list with all instances of value removed
list list_remove_all(list source_list, string s) {
    list result = [];
    integer i;
    integer len = llGetListLength(source_list);
    for (i = 0; i < len; i = i + 1) {
        string item = llList2String(source_list, i);
        if (item != s) {
            result = result + [item];
        }
    }
    return result;
}

// Returns list with duplicate values removed
list list_unique(list source_list) {
    list result = [];
    integer i;
    integer len = llGetListLength(source_list);
    for (i = 0; i < len; i = i + 1) {
        string item = llList2String(source_list, i);
        if (llListFindList(result, [item]) == -1) {
            result = result + [item];
        }
    }
    return result;
}
```

**Common Uses:**
- Collections of mixed data
- Function parameters for multiple values
- Menu button lists
- Filtered/transformed datasets
- Strided data structures

### Void Functions (No Return Type)

Functions that perform actions but don't return values omit the return type entirely:

```lsl
// Caches avatar name
cacheName(key k, string n) {
    if (k == NULL_KEY || n == "" || n == " ") return;
    integer idx = llListFindList(NameCache, [k]);
    if (idx == -1) {
        NameCache = NameCache + [k, n];
    } else {
        NameCache = llListReplaceList(NameCache, [k, n], idx, idx + 1);
    }
}

// Registers plugin with kernel
registerSelf() {
    string msg = llJsonSetValue("{}",
        ["sys"], "register",
        ["context"], PLUGIN_CONTEXT,
        ["label"], PLUGIN_LABEL,
        ["min_acl"], (string)MIN_ACL
    );
    llMessageLinked(LINK_THIS, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

// Applies settings synchronously
applySettingsSync(string msg) {
    if (!jsonHas(msg, ["kv"])) return;
    string kv = llJsonGetValue(msg, ["kv"]);
    // ... apply settings logic
}

// Cleans up dialog session
cleanupSession() {
    if (SessionId != "") {
        llMessageLinked(LINK_THIS, DIALOG_BUS,
            llJsonSetValue("{}", ["sys"], "close", ["session"], SessionId),
            NULL_KEY
        );
    }
    SessionId = "";
    CurrentUser = NULL_KEY;
}
```

**Common Uses:**
- State modification (setters)
- Message broadcasting
- UI display functions
- Cleanup and initialization
- Event handlers

## Parameter Declaration

### Single Parameter

```lsl
integer isOwner(key k) {
    return (k == OwnerKey);
}
```

### Multiple Parameters

```lsl
cacheName(key k, string n) {
    // function body
}

integer listHasKey(list search_list, key k) {
    return (llListFindList(search_list, [k]) != -1);
}

string truncateName(string name, integer max_len) {
    if (llStringLength(name) <= max_len) return name;
    return llGetSubString(name, 0, max_len - 4) + "...";
}
```

### No Parameters

```lsl
string genSession() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

integer now() {
    return llGetUnixTime();
}
```

## Type Casting in Return Statements

LSL requires explicit type casting when converting between types:

```lsl
string genSession() {
    // Cast integer to string using (string)
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

integer hasOwner() {
    // Explicitly return integer TRUE/FALSE
    return (OwnerKey != NULL_KEY);
}

string getAclString(integer acl) {
    // Cast integer to string
    return (string)acl;
}
```

## Best Practices

### 1. Function Naming

- **User-defined functions:** Use `camelCase` (this codebase standard)
  - `getName()`, `isOwner()`, `genSession()`
- **Built-in LSL functions:** Always start with `ll` prefix
  - `llGetPos()`, `llSay()`, `llMessageLinked()`
- **Event handlers:** Use `snake_case` (LSL requirement)
  - `state_entry()`, `link_message()`, `timer()`

### 2. Return Type Selection

Choose the most appropriate type for the data:

| If you need to return... | Use type... |
|-------------------------|-------------|
| Boolean/flag | `integer` (TRUE=1, FALSE=0) |
| Count/index | `integer` |
| Measurements | `float` |
| Text/identifiers | `string` |
| Avatar/object ID | `key` |
| Position/color | `vector` |
| Orientation | `rotation` |
| Mixed collection | `list` |
| No return value | (no type - void) |

### 3. Parameter Design

- Use descriptive parameter names: `key av` not just `key k`
- Order parameters logically: most important first
- Limit parameter count (LSL has memory constraints)
- Document complex parameter expectations

### 4. Documentation

```lsl
// Returns TRUE if the avatar is an owner
// Parameters:
//   av - Avatar key to check
// Returns:
//   integer - 1 if owner, 0 otherwise
integer isOwner(key av) {
    if (MultiOwnerMode) {
        return (llListFindList(OwnerKeys, [av]) != -1);
    }
    return (av == OwnerKey);
}
```

## Common Patterns in This Codebase

### Debug Logging (Returns Integer)

```lsl
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[MODULE] " + msg);
    return FALSE;  // Allows use in conditionals
}
```

### JSON Validation (Returns Integer)

```lsl
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
```

### Session Generation (Returns String)

```lsl
string genSession() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}
```

### Name Caching (Void and String)

```lsl
// Void: stores name in cache
cacheName(key k, string n) {
    if (k == NULL_KEY || n == "" || n == " ") return;
    // ... caching logic
}

// String: retrieves name from cache
string getName(key k) {
    if (k == NULL_KEY) return "";
    integer idx = llListFindList(NameCache, [k]);
    if (idx != -1) {
        return llList2String(NameCache, idx + 1);
    }
    return "...";
}
```

## LSL vs Other Languages

### Key Differences

| Feature | LSL | C/C++/Java |
|---------|-----|------------|
| Void functions | No `void` keyword, omit return type | Explicit `void` keyword |
| Pass-by-reference | Not supported | Supported with `&` or `*` |
| Function overloading | Not supported | Supported |
| Default parameters | Not supported | Supported |
| Variadic functions | Not supported | Supported |

### Example Comparison

**LSL:**
```lsl
// No void keyword
cacheName(key k, string n) {
    // function body
}

// Explicit type required
integer isOwner(key av) {
    return 1;
}
```

**C/Java:**
```c
// Explicit void keyword
void cacheName(string k, string n) {
    // function body
}

// Boolean type available
boolean isOwner(string av) {
    return true;
}
```

## Built-in LSL Function Categories

The LSL API organizes built-in functions by return type:

- **Returns integer:** `llAbs()`, `llGetUnixTime()`, `llGetPermissions()`
- **Returns float:** `llSqrt()`, `llPow()`, `llVecDist()`
- **Returns string:** `llGetObjectName()`, `llGetDate()`, `llJsonGetValue()`
- **Returns key:** `llGetOwner()`, `llGetKey()`, `llRequestAgentData()`
- **Returns vector:** `llGetPos()`, `llGetColor()`, `llGetVel()`
- **Returns rotation:** `llGetRot()`, `llEuler2Rot()`, `llAxisAngle2Rot()`
- **Returns list:** `llGetObjectDetails()`, `llParseString2List()`, `llListSort()`
- **Returns nothing:** `llSay()`, `llSetColor()`, `llMessageLinked()`

## Reference Documentation

For complete LSL API reference, see:
- **LSL Portal:** https://wiki.secondlife.com/wiki/LSL_Portal
- **LSL Types:** https://wiki.secondlife.com/wiki/Category:LSL_Types
- **LSL Functions:** https://wiki.secondlife.com/wiki/Category:LSL_Functions
- **LSL Tutorial:** https://wiki.secondlife.com/wiki/LSL_101

## Version History

- **v1.0** (2025-10-29): Initial documentation based on LSL Wiki and ds_collar_modular codebase analysis

---

**Note:** This document reflects the LSL language as implemented in Second Life. For OpenSim or other LSL-compatible environments, some functions or behaviors may differ.
