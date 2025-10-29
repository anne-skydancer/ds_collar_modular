# LSL Code Style Guide

## Overview
This document defines the coding standards for the DS Collar Modular project's LSL (Linden Scripting Language) codebase.

## Function Naming Convention

### Standard: camelCase
All user-defined functions MUST use camelCase naming convention.

**Examples:**
```lsl
// Correct
genSession()
hasOwner()
getPrimaryOwner()
isOwner(key k)
getName(key k)
cacheName(key k, string n)
registerSelf()
sendPong()
applySettingsSync(string msg)
persistOwner(key owner, string hon)
requestAcl(key user)
handleAclResult(string msg)
showMain()
showCandidates(string context, string title, string prompt)
handleButton(string btn)
cleanupSession()
```

**Incorrect:**
```lsl
// Wrong - snake_case
gen_session()
has_owner()
get_primary_owner()
```

### LSL Built-in Event Handlers
LSL built-in event handlers use snake_case and MUST remain unchanged:
- `state_entry()`
- `on_rez(integer p)`
- `link_message(integer sender, integer num, string msg, key id)`
- `changed(integer c)`
- `sensor(integer count)`
- `no_sensor()`
- `dataserver(key qid, string data)`

## Variable Naming Convention

### Global State Variables: PascalCase
```lsl
integer MultiOwnerMode;
key OwnerKey;
list OwnerKeys;
string OwnerHonorific;
list OwnerHonorifics;
list TrusteeKeys;
integer RunawayEnabled;
key CurrentUser;
integer UserAcl;
string SessionId;
```

### Constants: UPPER_SNAKE_CASE
```lsl
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY = "owner_key";
string PLUGIN_CONTEXT = "core_owner";
string PLUGIN_LABEL = "Access";
```

### Local Variables: camelCase
```lsl
integer idx = llListFindList(NameCache, [k]);
string msgBody = "Your " + hon + " wants to disable runaway.";
key oldOwner = OwnerKey;
```

### Function Parameters: camelCase
```lsl
cacheName(key k, string n)
applySettingsSync(string msg)
persistOwner(key owner, string hon)
```

## Code Organization

### File Header
Every plugin file should include a header block:
```lsl
/* ===============================================================
   PLUGIN: ds_collar_plugin_name.lsl (v1.0 - Memory Optimized)

   PURPOSE: Brief description

   FEATURES:
   - Feature 1
   - Feature 2

   TIER: X (Priority Level)
   =============================================================== */
```

### Section Separators
Use clear section separators:
```lsl
/* ===============================================================
   SECTION NAME
   =============================================================== */
```

Common sections:
- ABI CHANNELS
- IDENTITY
- SETTINGS KEYS
- STATE
- HELPERS
- LIFECYCLE
- SETTINGS
- ACL
- MENUS
- BUTTON HANDLING
- CLEANUP
- EVENTS

## Best Practices

### 1. Function Organization
- Helper functions first
- Lifecycle functions second
- Event handlers last

### 2. Consistency
- Once a naming convention is chosen, apply it consistently throughout the codebase
- All function calls must match their definitions exactly

### 3. Readability
- Use descriptive names for functions and variables
- Avoid abbreviations unless they are well-known (e.g., ACL, UI, ID)

### 4. Comments
- Add comments for complex logic
- Document function purposes when not obvious
- Use inline comments sparingly

## Common Patterns

### JSON Handling
```lsl
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

if (jsonHas(msg, ["kv"])) {
    string kv = llJsonGetValue(msg, ["kv"]);
}
```

### Session Generation
```lsl
string genSession() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}
```

### Name Caching
```lsl
cacheName(key k, string n) {
    if (k == NULL_KEY || n == "" || n == " ") return;
    // ... caching logic
}

string getName(key k) {
    if (k == NULL_KEY) return "";
    // ... retrieval logic with fallback
}
```

## Migration Notes

When fixing naming inconsistencies:
1. Identify all function definitions
2. Search for all function calls using snake_case
3. Replace snake_case calls with camelCase equivalents
4. Use global find/replace with caution - verify each change
5. Test thoroughly after renaming

## Version History

- **v1.0** (2025-10-29): Initial style guide based on ds_collar_plugin_owner.lsl analysis
