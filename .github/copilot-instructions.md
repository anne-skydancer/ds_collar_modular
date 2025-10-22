# VS Code Copilot Instructions for DS Collar v2.0 Development

## Language: Linden Scripting Language (LSL)

You are assisting with **Linden Scripting Language (LSL)** development for Second Life/OpenSim. LSL is NOT JavaScript, C, or any other language. Follow these rules strictly.

---

## CRITICAL LSL LANGUAGE CONSTRAINTS

### Syntax Limitations (NEVER suggest these)

❌ **NO ternary operator**: `condition ? true_val : false_val`
✅ **USE**: if/else blocks or boolean expressions

❌ **NO "key" as variable name**: It's a reserved type
✅ **USE**: Different names like `avatar_key`, `target_key`, `user_key`

❌ **NO "continue" in loops**: Not supported in LSL
✅ **USE**: Conditional logic or loop restructuring

### CRITICAL LSL Structure Rules

⚠️ **ALL helper functions MUST be defined BEFORE the default state**
```lsl
// ✅ CORRECT ORDER:
integer DEBUG = TRUE;
string CONSTANT = "value";

// Helper functions go here
integer my_helper(string arg) {
    return 0;
}

string another_helper() {
    return "value";
}

// Default state comes LAST
default {
    state_entry() {
        // Can call helpers defined above
        my_helper("test");
    }
}

// ❌ WRONG - Function after state:
default {
    state_entry() { }
}

integer my_helper() { }  // ERROR: Functions cannot be defined after states
```

### Reserved Terms (NEVER use as variable names)

LSL has many reserved words that cannot be used as variable names:

❌ **NEVER use these as variable names:**
```lsl
// Reserved types
key, integer, float, string, vector, rotation, list, quaternion

// Reserved keywords  
if, else, for, do, while, return, state, jump, default

// Event names
state_entry, state_exit, touch_start, touch_end, touch, timer, 
listen, collision_start, collision_end, collision, dataserver,
email, http_response, http_request, changed, attach, run_time_permissions,
sensor, no_sensor, control, at_target, not_at_target, at_rot_target,
not_at_rot_target, money, moving_end, moving_start, object_rez,
on_rez, remote_data, link_message, land_collision_start, 
land_collision_end, land_collision, path_update, transaction_result

// Common function names that might be tempting
event, message, data, time, type
```

✅ **DO use descriptive alternatives:**
```lsl
// Instead of:          Use:
key key;              key avatar_key;
string type;          string msg_type;
string message;       string chat_msg;
integer event;        integer event_type;
string data;          string response_data;
float time;           float elapsed_time;
```

❌ **NO switch/case statements**: Not in LSL
✅ **USE**: if/else if chains

❌ **NO try/catch**: No exception handling
✅ **USE**: Defensive checks before operations

❌ **NO classes/objects**: LSL is procedural
✅ **USE**: Functions and global state

❌ **NO foreach loops**: Not supported
✅ **USE**: while loops with counters

❌ **NO default parameters**: Functions don't support them
✅ **USE**: Function overloading or NULL_KEY checks

❌ **NO array literals**: `[1, 2, 3]` is for lists only
✅ **USE**: Lists for collections

❌ **NO string interpolation**: `"Hello ${name}"`
✅ **USE**: Concatenation with `+`

### Script Structure Requirements

**CRITICAL: Function Definition Order**

In LSL, ALL function definitions MUST appear BEFORE any state definitions:

```lsl
/* ✅ CORRECT STRUCTURE */

// 1. Global variables and constants at top
integer DEBUG = TRUE;
string PLUGIN_CONTEXT = "example";

// 2. ALL helper functions next
integer logd(string msg) {
    if (DEBUG) llOwnerSay(msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

// 3. States LAST (default state must exist)
default {
    state_entry() {
        logd("Started");  // Can call helpers defined above
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (json_has(msg, ["type"])) {  // Can call helpers
            // Process message
        }
    }
}

/* ❌ WRONG - THIS WILL CAUSE COMPILATION ERRORS */

default {
    state_entry() {
        my_helper();  // ERROR: my_helper not defined yet
    }
}

// Functions after states - COMPILER ERROR
integer my_helper() {
    return 0;
}
```

**Key Points:**
- Functions cannot be defined inside states (unlike C/JavaScript)
- Functions cannot be defined after states
- All functions must be at script global scope
- Default state is required and must come after all functions

### Additional Reserved Terms to Avoid

Beyond basic types, avoid these as variable names:

❌ **Event handler names:**
```lsl
// Don't use as variables:
collision, touch, timer, listen, sensor, dataserver, changed,
attach, money, email, http_response, control, link_message
```

❌ **Common constants (case-sensitive, but avoid similar names):**
```lsl
// Don't shadow these:
TRUE, FALSE, PI, TWO_PI, PI_BY_TWO, DEG_TO_RAD, RAD_TO_DEG,
ZERO_VECTOR, ZERO_ROTATION, NULL_KEY
```

❌ **Ambiguous names that might confuse:**
```lsl
// Avoid:                     Use instead:
string event;               string event_type;
string message;             string chat_message;
key key;                    key avatar_key;
string type;                string msg_type;
string data;                string payload_data;
list list;                  list item_list;
integer state;              integer current_state;
```

### LSL-Specific Types

```lsl
// LSL has these primitive types:
integer   // 32-bit signed
float     // 32-bit float
string    // UTF-8 string
key       // UUID (00000000-0000-0000-0000-000000000000)
vector    // <x, y, z>
rotation  // <x, y, z, s>
list      // Heterogeneous list

// Special constants
NULL_KEY          // 00000000-0000-0000-0000-000000000000
ZERO_VECTOR       // <0.0, 0.0, 0.0>
ZERO_ROTATION     // <0.0, 0.0, 0.0, 1.0>
```

---

## DS COLLAR V2.0 ARCHITECTURE RULES

### Channel Constants (ALWAYS use these)

```lsl
// NEVER hardcode channel numbers
// ALWAYS use these constants:
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;
```

### Message Format (ALWAYS follow this)

```lsl
// ALL messages MUST be JSON with "type" field
// ✅ CORRECT:
string msg = llList2Json(JSON_OBJECT, [
    "type", "message_type",
    "field1", "value1",
    "field2", "value2"
]);
llMessageLinked(LINK_SET, CHANNEL_CONSTANT, msg, NULL_KEY);

// ❌ WRONG:
llMessageLinked(LINK_SET, 500, "some_string", NULL_KEY);
```

### Naming Conventions (ALWAYS follow)

```lsl
// PascalCase for globals
integer GlobalVariable = 0;
string GlobalString = "";
list GlobalList = [];

// ALL CAPS for constants
integer CONSTANT_VALUE = 100;
string CONSTANT_STRING = "value";

// snake_case for locals
some_function() {
    integer local_var = 0;
    string local_string = "";
    key local_key = NULL_KEY;
}
```

---

## PLUGIN DEVELOPMENT RULES

### 1. ALWAYS Start from Template

When creating a new plugin:
1. Copy `ds_collar_plugin_template_v2.lsl`
2. Set plugin identity constants
3. Follow template structure exactly
4. Don't remove template patterns

### 2. Plugin Identity Block

```lsl
// ALWAYS include at top of plugin:
string PLUGIN_CONTEXT = "unique_name";     // NO spaces, lowercase
string PLUGIN_LABEL = "Display Name";     // What users see
integer PLUGIN_MIN_ACL = 3;               // 1-5, see ACL table
```

### 3. Required Functions (NEVER omit)

```lsl
// Lifecycle (REQUIRED)
register_self()        // Send registration to kernel
send_pong()           // Respond to heartbeat

// Settings (REQUIRED)
apply_settings_sync(string msg)    // Handle full settings load
apply_settings_delta(string msg)   // Handle incremental updates

// ACL (REQUIRED)
request_acl(key user)              // Query user's access level
handle_acl_result(string msg)      // Process ACL response

// UI (REQUIRED if plugin has menus)
show_main_menu()                   // Display primary menu
handle_button_click(string button) // Process button clicks
return_to_root()                   // Return to collar root menu
cleanup_session()                  // Clear user session state

// Message Router (REQUIRED)
link_message(integer sender, integer num, string msg, key id) {
    // MUST check for "type" field
    // MUST route by channel number
}
```

### 4. Session Management Pattern

```lsl
// ALWAYS maintain session state:
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
string SessionId = "";

// ALWAYS generate unique session IDs:
string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

// ALWAYS cleanup on exit/timeout:
cleanup_session() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    SessionId = "";
}
```

### 5. Dialog Pattern (NEVER use llListen directly)

```lsl
// ❌ WRONG - Don't manage listens yourself:
integer Listen = llListen(chan, "", user, "");

// ✅ CORRECT - Use dialog module:
show_main_menu() {
    SessionId = generate_session_id();
    
    list buttons = ["Button1", "Button2", "Back"];
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Menu Title",
        "message", "Select an option:",
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}
```

### 6. Settings Persistence Pattern

```lsl
// ALWAYS use settings module for persistence:

// Scalar value:
persist_setting(string new_value) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_YOUR_SETTING,
        "value", new_value
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

// Add to list:
add_to_list(string element) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "list_add",
        "key", KEY_YOUR_LIST,
        "elem", element
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

// Remove from list:
remove_from_list(string element) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "list_remove",
        "key", KEY_YOUR_LIST,
        "elem", element
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}
```

### 7. ACL Validation Pattern

```lsl
// ALWAYS check ACL before operations:
handle_acl_result(string msg) {
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    UserAcl = level;
    
    // Check minimum access
    if (level < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanup_session();
        return;
    }
    
    // User has access
    show_main_menu();
}
```

### 8. Link Message Router Pattern

```lsl
// ALWAYS structure link_message this way:
link_message(integer sender, integer num, string msg, key id) {
    // FIRST: Validate JSON
    if (!json_has(msg, ["type"])) return;
    string msg_type = llJsonGetValue(msg, ["type"]);
    
    // SECOND: Route by channel (fast integer comparison)
    if (num == KERNEL_LIFECYCLE) {
        if (msg_type == "register_now") register_self();
        else if (msg_type == "ping") send_pong();
        else if (msg_type == "soft_reset") llResetScript();
    }
    else if (num == SETTINGS_BUS) {
        if (msg_type == "settings_sync") apply_settings_sync(msg);
        else if (msg_type == "settings_delta") apply_settings_delta(msg);
    }
    else if (num == AUTH_BUS) {
        if (msg_type == "acl_result") handle_acl_result(msg);
    }
    else if (num == UI_BUS) {
        if (msg_type == "start") handle_start(msg);
    }
    else if (num == DIALOG_BUS) {
        if (msg_type == "dialog_response") handle_dialog_response(msg);
        else if (msg_type == "dialog_timeout") handle_dialog_timeout(msg);
    }
}
```

---

## CODE QUALITY RULES

### JSON Handling

```lsl
// ALWAYS check JSON fields exist:
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

// ALWAYS validate before accessing:
if (json_has(msg, ["field"])) {
    string value = llJsonGetValue(msg, ["field"]);
}

// Check if string is JSON array:
integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}
```

### Loop Patterns

```lsl
// ✅ CORRECT LSL loop:
integer i = 0;
integer len = llGetListLength(myList);
while (i < len) {
    string item = llList2String(myList, i);
    // Process item
    i += 1;  // MUST increment manually
}

// ❌ WRONG - No foreach in LSL:
foreach (item in myList) { }

// ❌ WRONG - No continue in LSL:
while (i < len) {
    if (skip_condition) continue;  // ERROR
    i += 1;
}

// ✅ CORRECT - Use conditional:
while (i < len) {
    if (!skip_condition) {
        // Process
    }
    i += 1;
}
```

### Conditional Patterns

```lsl
// ❌ WRONG - No ternary in LSL:
string result = condition ? "yes" : "no";

// ✅ CORRECT - Use if/else:
string result;
if (condition) {
    result = "yes";
}
else {
    result = "no";
}

// ✅ ALSO CORRECT - Boolean trick for binary values:
integer result = (integer)condition;  // 1 or 0
```

### String Operations

```lsl
// ❌ WRONG - No interpolation:
string msg = `Hello ${name}`;

// ✅ CORRECT - Concatenation:
string msg = "Hello " + name;

// String functions:
llSubStringIndex(haystack, needle)  // Find position
llGetSubString(str, start, end)     // Extract substring
llStringTrim(str, STRING_TRIM)      // Trim whitespace
```

### List Operations

```lsl
// Create list:
list myList = ["item1", "item2", "item3"];

// Access:
string item = llList2String(myList, index);
integer val = llList2Integer(myList, index);
key k = llList2Key(myList, index);

// Modify:
myList += [new_item];                              // Append
myList = [new_item] + myList;                      // Prepend
myList = llListReplaceList(myList, [new], idx, idx); // Replace
myList = llDeleteSubList(myList, idx, idx);        // Delete

// Search:
integer idx = llListFindList(myList, [search_item]);

// Convert to JSON:
string json = llList2Json(JSON_ARRAY, myList);

// Convert from JSON:
list result = llJson2List(json_string);
```

---

## DEBUGGING RULES

### Debug Logging Pattern

```lsl
// ALWAYS include debug flag:
integer DEBUG = FALSE;  // Set TRUE during development

// ALWAYS use this helper:
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] " + msg);
    return FALSE;  // Allows: if (condition) return logd("msg");
}

// Use liberally:
logd("Function called");
logd("Variable value: " + (string)var);
logd("Received message: " + msg);
```

### Error Checking Pattern

```lsl
// ALWAYS validate inputs:
some_function(key user) {
    if (user == NULL_KEY) {
        logd("ERROR: Invalid user key");
        return;
    }
    
    // Proceed with operation
}

// ALWAYS check JSON structure:
handle_message(string msg) {
    if (!json_has(msg, ["type"])) {
        logd("ERROR: Missing type field");
        return;
    }
    
    string msg_type = llJsonGetValue(msg, ["type"]);
    // Proceed
}
```

---

## PERFORMANCE RULES

### Memory Management

```lsl
// Lists are memory-heavy. Be conservative:
list cache = [];  // Grows memory usage

// Stride patterns for structured lists:
list owner_data = [uuid, "name", level, uuid, "name", level];
integer STRIDE = 3;

integer i = 0;
while (i < llGetListLength(owner_data)) {
    key uuid = llList2Key(owner_data, i);
    string name = llList2String(owner_data, i + 1);
    integer level = llList2Integer(owner_data, i + 2);
    i += STRIDE;
}
```

### Script Time

```lsl
// Expensive operations (avoid in hot paths):
llSensor()             // Full region scan
llGetObjectDetails()   // External query
llRequestAgentData()   // External query
llParseString2List()   // String manipulation

// Cheap operations:
llGetUnixTime()        // Fast
llGetListLength()      // Fast
llListFindList()       // Fast for small lists
Integer comparison     // Very fast
```

### Efficient Patterns

```lsl
// ✅ GOOD - Early return:
if (condition_fail) return;
// Rest of function

// ❌ BAD - Deep nesting:
if (condition1) {
    if (condition2) {
        if (condition3) {
            // Code buried deep
        }
    }
}

// ✅ GOOD - Cache list length:
integer len = llGetListLength(myList);
while (i < len) { }

// ❌ BAD - Recalculate every iteration:
while (i < llGetListLength(myList)) { }
```

---

## SECURITY RULES

### Always Reset on Owner Change

```lsl
// REQUIRED in every script:
changed(integer change) {
    if (change & CHANGED_OWNER) {
        llResetScript();
    }
}
```

### Validate User Input

```lsl
// ALWAYS validate before persistence:
set_value(string user_input) {
    // Check length
    if (llStringLength(user_input) > MAX_LENGTH) {
        return;
    }
    
    // Sanitize if needed
    user_input = llStringTrim(user_input, STRING_TRIM);
    
    // Then persist
    persist_setting(user_input);
}
```

### Range Checking

```lsl
// ALWAYS check distance for touch/sensor:
touch_start(integer num) {
    key user = llDetectedKey(0);
    vector touch_pos = llDetectedPos(0);
    float distance = llVecDist(touch_pos, llGetPos());
    
    if (distance > MAX_RANGE) {
        logd("Touch too far away");
        return;
    }
    
    // Process touch
}
```

---

## COMMON PITFALLS TO AVOID

### 0. Function Placement (CRITICAL)

❌ **DON'T**: Define functions after states
```lsl
default {
    state_entry() {
        my_helper();  // Compiler error - not defined yet
    }
}

integer my_helper() {
    return 0;
}
```

❌ **DON'T**: Define functions inside states
```lsl
default {
    integer my_helper() {  // Syntax error - not allowed
        return 0;
    }
    
    state_entry() {
        my_helper();
    }
}
```

✅ **DO**: Define ALL functions before default state
```lsl
// Helpers first
integer my_helper() {
    return 0;
}

string another_helper() {
    return "value";
}

// States last
default {
    state_entry() {
        my_helper();  // Works correctly
    }
}
```

### 1. Channel Number Mistakes

❌ **DON'T**: Hardcode channels
```lsl
llMessageLinked(LINK_SET, 800, msg, NULL_KEY);
```

✅ **DO**: Use constants
```lsl
llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
```

### 2. Channel Number Mistakes

❌ **DON'T**: Hardcode channels
```lsl
llMessageLinked(LINK_SET, 800, msg, NULL_KEY);
```

✅ **DO**: Use constants
```lsl
llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
```

### 3. Missing Type Field

❌ **DON'T**: Omit "type"
```lsl
string msg = llList2Json(JSON_OBJECT, ["key", "value"]);
```

✅ **DO**: Always include "type"
```lsl
string msg = llList2Json(JSON_OBJECT, [
    "type", "message_type",
    "key", "value"
]);
```

### 4. Direct Listen Management

❌ **DON'T**: Create your own listens
```lsl
integer chan = -1000000;
integer handle = llListen(chan, "", user, "");
llDialog(user, msg, buttons, chan);
```

✅ **DO**: Use dialog module
```lsl
string msg = llList2Json(JSON_OBJECT, [
    "type", "dialog_open",
    "session_id", SessionId,
    // ... rest of dialog
]);
llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
```

### 5. Skipping Session Cleanup

❌ **DON'T**: Leave sessions hanging
```lsl
handle_button_click(string button) {
    if (button == "Close") {
        // Just return, no cleanup
        return;
    }
}
```

✅ **DO**: Always cleanup
```lsl
handle_button_click(string button) {
    if (button == "Close") {
        cleanup_session();
        return;
    }
}
```

### 6. Ignoring Settings Delta

❌ **DON'T**: Only handle sync
```lsl
// Only implements apply_settings_sync()
```

✅ **DO**: Handle both sync and delta
```lsl
apply_settings_sync(string msg) { /* ... */ }
apply_settings_delta(string msg) { /* ... */ }
```

---

## WHEN GENERATING CODE

1. **ALWAYS** check if you're suggesting LSL-incompatible syntax
2. **ALWAYS** use the template patterns for plugins
3. **ALWAYS** use channel constants, never hardcode
4. **ALWAYS** include "type" field in JSON messages
5. **ALWAYS** follow the naming conventions
6. **ALWAYS** validate JSON before accessing fields
7. **ALWAYS** handle both settings sync and delta
8. **ALWAYS** cleanup sessions properly
9. **ALWAYS** use dialog module, never direct llListen
10. **ALWAYS** check ACL before operations

---

## QUICK REFERENCE

### ACL Levels
```
-1 = Blacklisted
 0 = No Access
 1 = Public
 2 = Owned (wearer when owner set)
 3 = Trustee
 4 = Unowned (wearer when no owner)
 5 = Primary Owner
```

### Channels
```
500 = KERNEL_LIFECYCLE
700 = AUTH_BUS
800 = SETTINGS_BUS
900 = UI_BUS
950 = DIALOG_BUS
```

### Common Message Types
```
Lifecycle: register_now, register, ping, pong, soft_reset
Auth: acl_query, acl_result
Settings: settings_get, settings_sync, settings_delta, set, list_add, list_remove
UI: start, return, close
Dialog: dialog_open, dialog_response, dialog_timeout, dialog_close
```

---

## EXAMPLE: Well-Formed Plugin Snippet

```lsl
/* Plugin Identity */
string PLUGIN_CONTEXT = "example";
string PLUGIN_LABEL = "Example";
integer PLUGIN_MIN_ACL = 3;

/* Channels */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer DIALOG_BUS = 950;

/* Settings */
string KEY_EXAMPLE_ENABLED = "example_enabled";

/* State */
integer ExampleEnabled = TRUE;
key CurrentUser = NULL_KEY;
string SessionId = "";
integer DEBUG = FALSE;

/* Helpers */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* Settings */
apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    string kv_json = llJsonGetValue(msg, ["kv"]);
    
    ExampleEnabled = TRUE;
    if (json_has(kv_json, [KEY_EXAMPLE_ENABLED])) {
        ExampleEnabled = (integer)llJsonGetValue(kv_json, [KEY_EXAMPLE_ENABLED]);
    }
    
    logd("Settings sync applied");
}

/* UI */
show_main_menu() {
    SessionId = generate_session_id();
    
    list buttons = ["Toggle", "Back"];
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "message", "Status: " + (string)ExampleEnabled,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* Events */
default {
    link_message(integer sender, integer num, string msg, key id) {
        if (!json_has(msg, ["type"])) return;
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
            }
        }
    }
}
```

This snippet follows ALL the rules: proper naming, channel constants, JSON validation, template patterns, and LSL-compatible syntax.

---

## SCRIPT STRUCTURE TEMPLATE

Every LSL script for DS Collar v2.0 should follow this exact order:

```lsl
/* =============================================================================
   HEADER COMMENT
   ============================================================================= */

/* ═══════════════════════════════════════════════════════════
   SECTION 1: CHANNEL CONSTANTS
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ═══════════════════════════════════════════════════════════
   SECTION 2: PLUGIN IDENTITY
   ═══════════════════════════════════════════════════════════ */
string PLUGIN_CONTEXT = "example";
string PLUGIN_LABEL = "Example";
integer PLUGIN_MIN_ACL = 3;

/* ═══════════════════════════════════════════════════════════
   SECTION 3: CONSTANTS
   ═══════════════════════════════════════════════════════════ */
integer DEBUG = FALSE;
string KEY_SETTING = "setting";

/* ═══════════════════════════════════════════════════════════
   SECTION 4: GLOBAL STATE VARIABLES
   ═══════════════════════════════════════════════════════════ */
integer SettingValue = 0;
key CurrentUser = NULL_KEY;
string SessionId = "";

/* ═══════════════════════════════════════════════════════════
   SECTION 5: HELPER FUNCTIONS (MUST BE BEFORE STATES)
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

// More helper functions here...

register_self() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

apply_settings_sync(string msg) {
    // Settings handler
}

show_main_menu() {
    // UI handler
}

// All other functions...

/* ═══════════════════════════════════════════════════════════
   SECTION 6: STATES (MUST BE LAST, DEFAULT REQUIRED)
   ═══════════════════════════════════════════════════════════ */
default
{
    state_entry() {
        logd("Script started");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!json_has(msg, ["type"])) return;
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (num == KERNEL_LIFECYCLE) {
            // Handle lifecycle
        }
        else if (num == SETTINGS_BUS) {
            // Handle settings
        }
        // More handlers...
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

// NO CODE AFTER THIS POINT - COMPILER ERROR
```

**Critical Rules:**
1. ✅ Constants at top
2. ✅ ALL functions defined before states
3. ✅ Default state required
4. ✅ Nothing after states
5. ❌ No functions inside states
6. ❌ No functions after states

---

Remember: LSL is NOT JavaScript/C/C++. Always validate your suggestions against LSL's actual syntax and capabilities!
