\# VS Code Copilot Instructions for DS Collar v2.0 Development



\## Language: Linden Scripting Language (LSL)



You are assisting with \*\*Linden Scripting Language (LSL)\*\* development for Second Life/OpenSim. LSL is NOT JavaScript, C, or any other language. Follow these rules strictly.



---



\## CRITICAL LSL LANGUAGE CONSTRAINTS



\### Syntax Limitations (NEVER suggest these)



âŒ \*\*NO ternary operator\*\*: `condition ? true\_val : false\_val`

âœ… \*\*USE\*\*: if/else blocks or boolean expressions



âŒ \*\*NO "key" as variable name\*\*: It's a reserved type

âœ… \*\*USE\*\*: Different names like `avatar\_key`, `target\_key`, `user\_key`



âŒ \*\*NO "continue" in loops\*\*: Not supported in LSL

âœ… \*\*USE\*\*: Conditional logic or loop restructuring



\### CRITICAL LSL Structure Rules



âš ï¸ \*\*ALL helper functions MUST be defined BEFORE the default state\*\*

```lsl

// âœ… CORRECT ORDER:

integer DEBUG = TRUE;

string CONSTANT = "value";



// Helper functions go here

integer my\_helper(string arg) {

&nbsp;   return 0;

}



string another\_helper() {

&nbsp;   return "value";

}



// Default state comes LAST

default {

&nbsp;   state\_entry() {

&nbsp;       // Can call helpers defined above

&nbsp;       my\_helper("test");

&nbsp;   }

}



// âŒ WRONG - Function after state:

default {

&nbsp;   state\_entry() { }

}



integer my\_helper() { }  // ERROR: Functions cannot be defined after states

```



\### Reserved Terms (NEVER use as variable names)



LSL has many reserved words that cannot be used as variable names:



âŒ \*\*NEVER use these as variable names:\*\*

```lsl

// Reserved types

key, integer, float, string, vector, rotation, list, quaternion



// Reserved keywords  

if, else, for, do, while, return, state, jump, default



// Event names

state\_entry, state\_exit, touch\_start, touch\_end, touch, timer, 

listen, collision\_start, collision\_end, collision, dataserver,

email, http\_response, http\_request, changed, attach, run\_time\_permissions,

sensor, no\_sensor, control, at\_target, not\_at\_target, at\_rot\_target,

not\_at\_rot\_target, money, moving\_end, moving\_start, object\_rez,

on\_rez, remote\_data, link\_message, land\_collision\_start, 

land\_collision\_end, land\_collision, path\_update, transaction\_result



// Common function names that might be tempting

event, message, data, time, type

```



âœ… \*\*DO use descriptive alternatives:\*\*

```lsl

// Instead of:          Use:

key key;              key avatar\_key;

string type;          string msg\_type;

string message;       string chat\_msg;

integer event;        integer event\_type;

string data;          string response\_data;

float time;           float elapsed\_time;

```



âŒ \*\*NO switch/case statements\*\*: Not in LSL

âœ… \*\*USE\*\*: if/else if chains



âŒ \*\*NO try/catch\*\*: No exception handling

âœ… \*\*USE\*\*: Defensive checks before operations



âŒ \*\*NO classes/objects\*\*: LSL is procedural

âœ… \*\*USE\*\*: Functions and global state



âŒ \*\*NO foreach loops\*\*: Not supported

âœ… \*\*USE\*\*: while loops with counters



âŒ \*\*NO default parameters\*\*: Functions don't support them

âœ… \*\*USE\*\*: Function overloading or NULL\_KEY checks



âŒ \*\*NO array literals\*\*: `\[1, 2, 3]` is for lists only

âœ… \*\*USE\*\*: Lists for collections



âŒ \*\*NO string interpolation\*\*: `"Hello ${name}"`

âœ… \*\*USE\*\*: Concatenation with `+`



\### Script Structure Requirements



\*\*CRITICAL: Function Definition Order\*\*



In LSL, ALL function definitions MUST appear BEFORE any state definitions:



```lsl

/\* âœ… CORRECT STRUCTURE \*/



// 1. Global variables and constants at top

integer DEBUG = TRUE;

string PLUGIN\_CONTEXT = "example";



// 2. ALL helper functions next

integer logd(string msg) {

&nbsp;   if (DEBUG) llOwnerSay(msg);

&nbsp;   return FALSE;

}



integer json\_has(string j, list path) {

&nbsp;   return (llJsonGetValue(j, path) != JSON\_INVALID);

}



string generate\_id() {

&nbsp;   return PLUGIN\_CONTEXT + "\_" + (string)llGetUnixTime();

}



// 3. States LAST (default state must exist)

default {

&nbsp;   state\_entry() {

&nbsp;       logd("Started");  // Can call helpers defined above

&nbsp;   }

&nbsp;   

&nbsp;   link\_message(integer sender, integer num, string msg, key id) {

&nbsp;       if (json\_has(msg, \["type"])) {  // Can call helpers

&nbsp;           // Process message

&nbsp;       }

&nbsp;   }

}



/\* âŒ WRONG - THIS WILL CAUSE COMPILATION ERRORS \*/



default {

&nbsp;   state\_entry() {

&nbsp;       my\_helper();  // ERROR: my\_helper not defined yet

&nbsp;   }

}



// Functions after states - COMPILER ERROR

integer my\_helper() {

&nbsp;   return 0;

}

```



\*\*Key Points:\*\*

\- Functions cannot be defined inside states (unlike C/JavaScript)

\- Functions cannot be defined after states

\- All functions must be at script global scope

\- Default state is required and must come after all functions



\### Additional Reserved Terms to Avoid



Beyond basic types, avoid these as variable names:



âŒ \*\*Event handler names:\*\*

```lsl

// Don't use as variables:

collision, touch, timer, listen, sensor, dataserver, changed,

attach, money, email, http\_response, control, link\_message

```



âŒ \*\*Common constants (case-sensitive, but avoid similar names):\*\*

```lsl

// Don't shadow these:

TRUE, FALSE, PI, TWO\_PI, PI\_BY\_TWO, DEG\_TO\_RAD, RAD\_TO\_DEG,

ZERO\_VECTOR, ZERO\_ROTATION, NULL\_KEY

```



âŒ \*\*Ambiguous names that might confuse:\*\*

```lsl

// Avoid:                     Use instead:

string event;               string event\_type;

string message;             string chat\_message;

key key;                    key avatar\_key;

string type;                string msg\_type;

string data;                string payload\_data;

list list;                  list item\_list;

integer state;              integer current\_state;

```



\### LSL-Specific Types



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

NULL\_KEY          // 00000000-0000-0000-0000-000000000000

ZERO\_VECTOR       // <0.0, 0.0, 0.0>

ZERO\_ROTATION     // <0.0, 0.0, 0.0, 1.0>

```



---



\## DS COLLAR V2.0 ARCHITECTURE RULES



\### Channel Constants (ALWAYS use these)



```lsl

// NEVER hardcode channel numbers

// ALWAYS use these constants:

integer KERNEL\_LIFECYCLE = 500;

integer AUTH\_BUS = 700;

integer SETTINGS\_BUS = 800;

integer UI\_BUS = 900;

integer DIALOG\_BUS = 950;

```



\### Message Format (ALWAYS follow this)



```lsl

// ALL messages MUST be JSON with "type" field

// âœ… CORRECT:

string msg = llList2Json(JSON\_OBJECT, \[

&nbsp;   "type", "message\_type",

&nbsp;   "field1", "value1",

&nbsp;   "field2", "value2"

]);

llMessageLinked(LINK\_SET, CHANNEL\_CONSTANT, msg, NULL\_KEY);



// âŒ WRONG:

llMessageLinked(LINK\_SET, 500, "some\_string", NULL\_KEY);

```



\### Naming Conventions (ALWAYS follow)



```lsl

// PascalCase for globals

integer GlobalVariable = 0;

string GlobalString = "";

list GlobalList = \[];



// ALL CAPS for constants

integer CONSTANT\_VALUE = 100;

string CONSTANT\_STRING = "value";



// snake\_case for locals

some\_function() {

&nbsp;   integer local\_var = 0;

&nbsp;   string local\_string = "";

&nbsp;   key local\_key = NULL\_KEY;

}

```



---



\## PLUGIN DEVELOPMENT RULES



\### 1. ALWAYS Start from Template



When creating a new plugin:

1\. Copy `ds\_collar\_plugin\_template\_v2.lsl`

2\. Set plugin identity constants

3\. Follow template structure exactly

4\. Don't remove template patterns



\### 2. Plugin Identity Block



```lsl

// ALWAYS include at top of plugin:

string PLUGIN\_CONTEXT = "unique\_name";     // NO spaces, lowercase

string PLUGIN\_LABEL = "Display Name";     // What users see

integer PLUGIN\_MIN\_ACL = 3;               // 1-5, see ACL table

```



\### 3. Required Functions (NEVER omit)



```lsl

// Lifecycle (REQUIRED)

register\_self()        // Send registration to kernel

send\_pong()           // Respond to heartbeat



// Settings (REQUIRED)

apply\_settings\_sync(string msg)    // Handle full settings load

apply\_settings\_delta(string msg)   // Handle incremental updates



// ACL (REQUIRED)

request\_acl(key user)              // Query user's access level

handle\_acl\_result(string msg)      // Process ACL response



// UI (REQUIRED if plugin has menus)

show\_main\_menu()                   // Display primary menu

handle\_button\_click(string button) // Process button clicks

return\_to\_root()                   // Return to collar root menu

cleanup\_session()                  // Clear user session state



// Message Router (REQUIRED)

link\_message(integer sender, integer num, string msg, key id) {

&nbsp;   // MUST check for "type" field

&nbsp;   // MUST route by channel number

}

```



\### 4. Session Management Pattern



```lsl

// ALWAYS maintain session state:

key CurrentUser = NULL\_KEY;

integer UserAcl = -999;

string SessionId = "";



// ALWAYS generate unique session IDs:

string generate\_session\_id() {

&nbsp;   return PLUGIN\_CONTEXT + "\_" + (string)llGetUnixTime();

}



// ALWAYS cleanup on exit/timeout:

cleanup\_session() {

&nbsp;   CurrentUser = NULL\_KEY;

&nbsp;   UserAcl = -999;

&nbsp;   SessionId = "";

}

```



\### 5. Dialog Pattern (NEVER use llListen directly)

**CRITICAL: llDialog Button Layout**

⚠️ llDialog builds button grids from **BOTTOM-LEFT to TOP-RIGHT**:
- Buttons are arranged in a 3x4 grid (12 buttons max)
- First button goes in BOTTOM-LEFT corner
- Fills LEFT-TO-RIGHT across bottom row
- Then moves up to next row
- Any dialog design MUST account for this layout

```
Visual layout for 9 buttons:
[7] [8] [9]     ← Top row (buttons 7-9)
[4] [5] [6]     ← Middle row (buttons 4-6)
[1] [2] [3]     ← Bottom row (buttons 1-3)
```

Example: To center a "Back" button at the bottom:
```lsl
list buttons = [" ", "Back", " "];  // [empty] [Back] [empty] = centered bottom
```




```lsl

// âŒ WRONG - Don't manage listens yourself:

integer Listen = llListen(chan, "", user, "");



// âœ… CORRECT - Use dialog module:

show\_main\_menu() {

&nbsp;   SessionId = generate\_session\_id();

&nbsp;   

&nbsp;   list buttons = \["Button1", "Button2", "Back"];

&nbsp;   

&nbsp;   string msg = llList2Json(JSON\_OBJECT, \[

&nbsp;       "type", "dialog\_open",

&nbsp;       "session\_id", SessionId,

&nbsp;       "user", (string)CurrentUser,

&nbsp;       "title", "Menu Title",

&nbsp;       "message", "Select an option:",

&nbsp;       "buttons", llList2Json(JSON\_ARRAY, buttons),

&nbsp;       "timeout", 60

&nbsp;   ]);

&nbsp;   

&nbsp;   llMessageLinked(LINK\_SET, DIALOG\_BUS, msg, NULL\_KEY);

}

```



\### 6. Settings Persistence Pattern



```lsl

// ALWAYS use settings module for persistence:



// Scalar value:

persist\_setting(string new\_value) {

&nbsp;   string msg = llList2Json(JSON\_OBJECT, \[

&nbsp;       "type", "set",

&nbsp;       "key", KEY\_YOUR\_SETTING,

&nbsp;       "value", new\_value

&nbsp;   ]);

&nbsp;   llMessageLinked(LINK\_SET, SETTINGS\_BUS, msg, NULL\_KEY);

}



// Add to list:

add\_to\_list(string element) {

&nbsp;   string msg = llList2Json(JSON\_OBJECT, \[

&nbsp;       "type", "list\_add",

&nbsp;       "key", KEY\_YOUR\_LIST,

&nbsp;       "elem", element

&nbsp;   ]);

&nbsp;   llMessageLinked(LINK\_SET, SETTINGS\_BUS, msg, NULL\_KEY);

}



// Remove from list:

remove\_from\_list(string element) {

&nbsp;   string msg = llList2Json(JSON\_OBJECT, \[

&nbsp;       "type", "list\_remove",

&nbsp;       "key", KEY\_YOUR\_LIST,

&nbsp;       "elem", element

&nbsp;   ]);

&nbsp;   llMessageLinked(LINK\_SET, SETTINGS\_BUS, msg, NULL\_KEY);

}

```



\### 7. ACL Validation Pattern



```lsl

// ALWAYS check ACL before operations:

handle\_acl\_result(string msg) {

&nbsp;   if (!json\_has(msg, \["avatar"])) return;

&nbsp;   if (!json\_has(msg, \["level"])) return;

&nbsp;   

&nbsp;   key avatar = (key)llJsonGetValue(msg, \["avatar"]);

&nbsp;   if (avatar != CurrentUser) return;

&nbsp;   

&nbsp;   integer level = (integer)llJsonGetValue(msg, \["level"]);

&nbsp;   UserAcl = level;

&nbsp;   

&nbsp;   // Check minimum access

&nbsp;   if (level < PLUGIN\_MIN\_ACL) {

&nbsp;       llRegionSayTo(CurrentUser, 0, "Access denied.");

&nbsp;       cleanup\_session();

&nbsp;       return;

&nbsp;   }

&nbsp;   

&nbsp;   // User has access

&nbsp;   show\_main\_menu();

}

```



\### 8. Link Message Router Pattern



```lsl

// ALWAYS structure link\_message this way:

link\_message(integer sender, integer num, string msg, key id) {

&nbsp;   // FIRST: Validate JSON

&nbsp;   if (!json\_has(msg, \["type"])) return;

&nbsp;   string msg\_type = llJsonGetValue(msg, \["type"]);

&nbsp;   

&nbsp;   // SECOND: Route by channel (fast integer comparison)

&nbsp;   if (num == KERNEL\_LIFECYCLE) {

&nbsp;       if (msg\_type == "register\_now") register\_self();

&nbsp;       else if (msg\_type == "ping") send\_pong();

&nbsp;       else if (msg\_type == "soft\_reset") llResetScript();

&nbsp;   }

&nbsp;   else if (num == SETTINGS\_BUS) {

&nbsp;       if (msg\_type == "settings\_sync") apply\_settings\_sync(msg);

&nbsp;       else if (msg\_type == "settings\_delta") apply\_settings\_delta(msg);

&nbsp;   }

&nbsp;   else if (num == AUTH\_BUS) {

&nbsp;       if (msg\_type == "acl\_result") handle\_acl\_result(msg);

&nbsp;   }

&nbsp;   else if (num == UI\_BUS) {

&nbsp;       if (msg\_type == "start") handle\_start(msg);

&nbsp;   }

&nbsp;   else if (num == DIALOG\_BUS) {

&nbsp;       if (msg\_type == "dialog\_response") handle\_dialog\_response(msg);

&nbsp;       else if (msg\_type == "dialog\_timeout") handle\_dialog\_timeout(msg);

&nbsp;   }

}

```



---



\## CODE QUALITY RULES



\### JSON Handling



```lsl

// ALWAYS check JSON fields exist:

integer json\_has(string j, list path) {

&nbsp;   return (llJsonGetValue(j, path) != JSON\_INVALID);

}



// ALWAYS validate before accessing:

if (json\_has(msg, \["field"])) {

&nbsp;   string value = llJsonGetValue(msg, \["field"]);

}



// Check if string is JSON array:

integer is\_json\_arr(string s) {

&nbsp;   return (llGetSubString(s, 0, 0) == "\[");

}

```



\### Loop Patterns



```lsl

// âœ… CORRECT LSL loop:

integer i = 0;

integer len = llGetListLength(myList);

while (i < len) {

&nbsp;   string item = llList2String(myList, i);

&nbsp;   // Process item

&nbsp;   i += 1;  // MUST increment manually

}



// âŒ WRONG - No foreach in LSL:

foreach (item in myList) { }



// âŒ WRONG - No continue in LSL:

while (i < len) {

&nbsp;   if (skip\_condition) continue;  // ERROR

&nbsp;   i += 1;

}



// âœ… CORRECT - Use conditional:

while (i < len) {

&nbsp;   if (!skip\_condition) {

&nbsp;       // Process

&nbsp;   }

&nbsp;   i += 1;

}

```



\### Conditional Patterns



```lsl

// âŒ WRONG - No ternary in LSL:

string result = condition ? "yes" : "no";



// âœ… CORRECT - Use if/else:

string result;

if (condition) {

&nbsp;   result = "yes";

}

else {

&nbsp;   result = "no";

}



// âœ… ALSO CORRECT - Boolean trick for binary values:

integer result = (integer)condition;  // 1 or 0

```



\### String Operations



```lsl

// âŒ WRONG - No interpolation:

string msg = `Hello ${name}`;



// âœ… CORRECT - Concatenation:

string msg = "Hello " + name;



// String functions:

llSubStringIndex(haystack, needle)  // Find position

llGetSubString(str, start, end)     // Extract substring

llStringTrim(str, STRING\_TRIM)      // Trim whitespace

```



\### List Operations



```lsl

// Create list:

list myList = \["item1", "item2", "item3"];



// Access:

string item = llList2String(myList, index);

integer val = llList2Integer(myList, index);

key k = llList2Key(myList, index);



// Modify:

myList += \[new\_item];                              // Append

myList = \[new\_item] + myList;                      // Prepend

myList = llListReplaceList(myList, \[new], idx, idx); // Replace

myList = llDeleteSubList(myList, idx, idx);        // Delete



// Search:

integer idx = llListFindList(myList, \[search\_item]);



// Convert to JSON:

string json = llList2Json(JSON\_ARRAY, myList);



// Convert from JSON:

list result = llJson2List(json\_string);

```



---



\## DEBUGGING RULES



\### Debug Logging Pattern



```lsl

// ALWAYS include debug flag:

integer DEBUG = FALSE;  // Set TRUE during development



// ALWAYS use this helper:

integer logd(string msg) {

&nbsp;   if (DEBUG) llOwnerSay("\[" + PLUGIN\_LABEL + "] " + msg);

&nbsp;   return FALSE;  // Allows: if (condition) return logd("msg");

}



// Use liberally:

logd("Function called");

logd("Variable value: " + (string)var);

logd("Received message: " + msg);

```



\### Error Checking Pattern



```lsl

// ALWAYS validate inputs:

some\_function(key user) {

&nbsp;   if (user == NULL\_KEY) {

&nbsp;       logd("ERROR: Invalid user key");

&nbsp;       return;

&nbsp;   }

&nbsp;   

&nbsp;   // Proceed with operation

}



// ALWAYS check JSON structure:

handle\_message(string msg) {

&nbsp;   if (!json\_has(msg, \["type"])) {

&nbsp;       logd("ERROR: Missing type field");

&nbsp;       return;

&nbsp;   }

&nbsp;   

&nbsp;   string msg\_type = llJsonGetValue(msg, \["type"]);

&nbsp;   // Proceed

}

```



---



\## PERFORMANCE RULES



\### Memory Management



```lsl

// Lists are memory-heavy. Be conservative:

list cache = \[];  // Grows memory usage



// Stride patterns for structured lists:

list owner\_data = \[uuid, "name", level, uuid, "name", level];

integer STRIDE = 3;



integer i = 0;

while (i < llGetListLength(owner\_data)) {

&nbsp;   key uuid = llList2Key(owner\_data, i);

&nbsp;   string name = llList2String(owner\_data, i + 1);

&nbsp;   integer level = llList2Integer(owner\_data, i + 2);

&nbsp;   i += STRIDE;

}

```



\### Script Time



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



\### Efficient Patterns



```lsl

// âœ… GOOD - Early return:

if (condition\_fail) return;

// Rest of function



// âŒ BAD - Deep nesting:

if (condition1) {

&nbsp;   if (condition2) {

&nbsp;       if (condition3) {

&nbsp;           // Code buried deep

&nbsp;       }

&nbsp;   }

}



// âœ… GOOD - Cache list length:

integer len = llGetListLength(myList);

while (i < len) { }



// âŒ BAD - Recalculate every iteration:

while (i < llGetListLength(myList)) { }

```



---



\## SECURITY RULES



\### Always Reset on Owner Change



```lsl

// REQUIRED in every script:

changed(integer change) {

&nbsp;   if (change \& CHANGED\_OWNER) {

&nbsp;       llResetScript();

&nbsp;   }

}

```



\### Validate User Input



```lsl

// ALWAYS validate before persistence:

set\_value(string user\_input) {

&nbsp;   // Check length

&nbsp;   if (llStringLength(user\_input) > MAX\_LENGTH) {

&nbsp;       return;

&nbsp;   }

&nbsp;   

&nbsp;   // Sanitize if needed

&nbsp;   user\_input = llStringTrim(user\_input, STRING\_TRIM);

&nbsp;   

&nbsp;   // Then persist

&nbsp;   persist\_setting(user\_input);

}

```



\### Range Checking



```lsl

// ALWAYS check distance for touch/sensor:

touch\_start(integer num) {

&nbsp;   key user = llDetectedKey(0);

&nbsp;   vector touch\_pos = llDetectedPos(0);

&nbsp;   float distance = llVecDist(touch\_pos, llGetPos());

&nbsp;   

&nbsp;   if (distance > MAX\_RANGE) {

&nbsp;       logd("Touch too far away");

&nbsp;       return;

&nbsp;   }

&nbsp;   

&nbsp;   // Process touch

}

```



---



\## COMMON PITFALLS TO AVOID



\### 0. Function Placement (CRITICAL)



âŒ \*\*DON'T\*\*: Define functions after states

```lsl

default {

&nbsp;   state\_entry() {

&nbsp;       my\_helper();  // Compiler error - not defined yet

&nbsp;   }

}



integer my\_helper() {

&nbsp;   return 0;

}

```



âŒ \*\*DON'T\*\*: Define functions inside states

```lsl

default {

&nbsp;   integer my\_helper() {  // Syntax error - not allowed

&nbsp;       return 0;

&nbsp;   }

&nbsp;   

&nbsp;   state\_entry() {

&nbsp;       my\_helper();

&nbsp;   }

}

```



âœ… \*\*DO\*\*: Define ALL functions before default state

```lsl

// Helpers first

integer my\_helper() {

&nbsp;   return 0;

}



string another\_helper() {

&nbsp;   return "value";

}



// States last

default {

&nbsp;   state\_entry() {

&nbsp;       my\_helper();  // Works correctly

&nbsp;   }

}

```



\### 1. Channel Number Mistakes



âŒ \*\*DON'T\*\*: Hardcode channels

```lsl

llMessageLinked(LINK\_SET, 800, msg, NULL\_KEY);

```



âœ… \*\*DO\*\*: Use constants

```lsl

llMessageLinked(LINK\_SET, SETTINGS\_BUS, msg, NULL\_KEY);

```



\### 2. Channel Number Mistakes



âŒ \*\*DON'T\*\*: Hardcode channels

```lsl

llMessageLinked(LINK\_SET, 800, msg, NULL\_KEY);

```



âœ… \*\*DO\*\*: Use constants

```lsl

llMessageLinked(LINK\_SET, SETTINGS\_BUS, msg, NULL\_KEY);

```



\### 3. Missing Type Field



âŒ \*\*DON'T\*\*: Omit "type"

```lsl

string msg = llList2Json(JSON\_OBJECT, \["key", "value"]);

```



âœ… \*\*DO\*\*: Always include "type"

```lsl

string msg = llList2Json(JSON\_OBJECT, \[

&nbsp;   "type", "message\_type",

&nbsp;   "key", "value"

]);

```



\### 4. Direct Listen Management



âŒ \*\*DON'T\*\*: Create your own listens

```lsl

integer chan = -1000000;

integer handle = llListen(chan, "", user, "");

llDialog(user, msg, buttons, chan);

```



âœ… \*\*DO\*\*: Use dialog module

```lsl

string msg = llList2Json(JSON\_OBJECT, \[

&nbsp;   "type", "dialog\_open",

&nbsp;   "session\_id", SessionId,

&nbsp;   // ... rest of dialog

]);

llMessageLinked(LINK\_SET, DIALOG\_BUS, msg, NULL\_KEY);

```



\### 5. Skipping Session Cleanup



âŒ \*\*DON'T\*\*: Leave sessions hanging

```lsl

handle\_button\_click(string button) {

&nbsp;   if (button == "Close") {

&nbsp;       // Just return, no cleanup

&nbsp;       return;

&nbsp;   }

}

```



âœ… \*\*DO\*\*: Always cleanup

```lsl

handle\_button\_click(string button) {

&nbsp;   if (button == "Close") {

&nbsp;       cleanup\_session();

&nbsp;       return;

&nbsp;   }

}

```



\### 6. Ignoring Settings Delta



âŒ \*\*DON'T\*\*: Only handle sync

```lsl

// Only implements apply\_settings\_sync()

```



âœ… \*\*DO\*\*: Handle both sync and delta

```lsl

apply\_settings\_sync(string msg) { /\* ... \*/ }

apply\_settings\_delta(string msg) { /\* ... \*/ }

```



---



\## WHEN GENERATING CODE



1\. \*\*ALWAYS\*\* check if you're suggesting LSL-incompatible syntax

2\. \*\*ALWAYS\*\* use the template patterns for plugins

3\. \*\*ALWAYS\*\* use channel constants, never hardcode

4\. \*\*ALWAYS\*\* include "type" field in JSON messages

5\. \*\*ALWAYS\*\* follow the naming conventions

6\. \*\*ALWAYS\*\* validate JSON before accessing fields

7\. \*\*ALWAYS\*\* handle both settings sync and delta

8\. \*\*ALWAYS\*\* cleanup sessions properly

9\. \*\*ALWAYS\*\* use dialog module, never direct llListen

10\. \*\*ALWAYS\*\* check ACL before operations



---



\## QUICK REFERENCE



\### ACL Levels

```

-1 = Blacklisted

&nbsp;0 = No Access

&nbsp;1 = Public

&nbsp;2 = Owned (wearer when owner set)

&nbsp;3 = Trustee

&nbsp;4 = Unowned (wearer when no owner)

&nbsp;5 = Primary Owner

```



\### Channels

```

500 = KERNEL\_LIFECYCLE

700 = AUTH\_BUS

800 = SETTINGS\_BUS

900 = UI\_BUS

950 = DIALOG\_BUS

```



\### Common Message Types

```

Lifecycle: register\_now, register, ping, pong, soft\_reset

Auth: acl\_query, acl\_result

Settings: settings\_get, settings\_sync, settings\_delta, set, list\_add, list\_remove

UI: start, return, close

Dialog: dialog\_open, dialog\_response, dialog\_timeout, dialog\_close

```



---



\## EXAMPLE: Well-Formed Plugin Snippet



```lsl

/\* Plugin Identity \*/

string PLUGIN\_CONTEXT = "example";

string PLUGIN\_LABEL = "Example";

integer PLUGIN\_MIN\_ACL = 3;



/\* Channels \*/

integer KERNEL\_LIFECYCLE = 500;

integer SETTINGS\_BUS = 800;

integer DIALOG\_BUS = 950;



/\* Settings \*/

string KEY\_EXAMPLE\_ENABLED = "example\_enabled";



/\* State \*/

integer ExampleEnabled = TRUE;

key CurrentUser = NULL\_KEY;

string SessionId = "";

integer DEBUG = FALSE;



/\* Helpers \*/

integer logd(string msg) {

&nbsp;   if (DEBUG) llOwnerSay("\[" + PLUGIN\_LABEL + "] " + msg);

&nbsp;   return FALSE;

}



integer json\_has(string j, list path) {

&nbsp;   return (llJsonGetValue(j, path) != JSON\_INVALID);

}



string generate\_session\_id() {

&nbsp;   return PLUGIN\_CONTEXT + "\_" + (string)llGetUnixTime();

}



/\* Settings \*/

apply\_settings\_sync(string msg) {

&nbsp;   if (!json\_has(msg, \["kv"])) return;

&nbsp;   string kv\_json = llJsonGetValue(msg, \["kv"]);

&nbsp;   

&nbsp;   ExampleEnabled = TRUE;

&nbsp;   if (json\_has(kv\_json, \[KEY\_EXAMPLE\_ENABLED])) {

&nbsp;       ExampleEnabled = (integer)llJsonGetValue(kv\_json, \[KEY\_EXAMPLE\_ENABLED]);

&nbsp;   }

&nbsp;   

&nbsp;   logd("Settings sync applied");

}



/\* UI \*/

show\_main\_menu() {

&nbsp;   SessionId = generate\_session\_id();

&nbsp;   

&nbsp;   list buttons = \["Toggle", "Back"];

&nbsp;   

&nbsp;   string msg = llList2Json(JSON\_OBJECT, \[

&nbsp;       "type", "dialog\_open",

&nbsp;       "session\_id", SessionId,

&nbsp;       "user", (string)CurrentUser,

&nbsp;       "title", PLUGIN\_LABEL,

&nbsp;       "message", "Status: " + (string)ExampleEnabled,

&nbsp;       "buttons", llList2Json(JSON\_ARRAY, buttons),

&nbsp;       "timeout", 60

&nbsp;   ]);

&nbsp;   

&nbsp;   llMessageLinked(LINK\_SET, DIALOG\_BUS, msg, NULL\_KEY);

}



/\* Events \*/

default {

&nbsp;   link\_message(integer sender, integer num, string msg, key id) {

&nbsp;       if (!json\_has(msg, \["type"])) return;

&nbsp;       string msg\_type = llJsonGetValue(msg, \["type"]);

&nbsp;       

&nbsp;       if (num == SETTINGS\_BUS) {

&nbsp;           if (msg\_type == "settings\_sync") {

&nbsp;               apply\_settings\_sync(msg);

&nbsp;           }

&nbsp;       }

&nbsp;   }

}

```



This snippet follows ALL the rules: proper naming, channel constants, JSON validation, template patterns, and LSL-compatible syntax.



---



\## SCRIPT STRUCTURE TEMPLATE



Every LSL script for DS Collar v2.0 should follow this exact order:



```lsl

/\* =============================================================================

&nbsp;  HEADER COMMENT

&nbsp;  ============================================================================= \*/



/\* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

&nbsp;  SECTION 1: CHANNEL CONSTANTS

&nbsp;  â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• \*/

integer KERNEL\_LIFECYCLE = 500;

integer AUTH\_BUS = 700;

integer SETTINGS\_BUS = 800;

integer UI\_BUS = 900;

integer DIALOG\_BUS = 950;



/\* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

&nbsp;  SECTION 2: PLUGIN IDENTITY

&nbsp;  â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• \*/

string PLUGIN\_CONTEXT = "example";

string PLUGIN\_LABEL = "Example";

integer PLUGIN\_MIN\_ACL = 3;



/\* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

&nbsp;  SECTION 3: CONSTANTS

&nbsp;  â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• \*/

integer DEBUG = FALSE;

string KEY\_SETTING = "setting";



/\* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

&nbsp;  SECTION 4: GLOBAL STATE VARIABLES

&nbsp;  â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• \*/

integer SettingValue = 0;

key CurrentUser = NULL\_KEY;

string SessionId = "";



/\* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

&nbsp;  SECTION 5: HELPER FUNCTIONS (MUST BE BEFORE STATES)

&nbsp;  â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• \*/

integer logd(string msg) {

&nbsp;   if (DEBUG) llOwnerSay("\[" + PLUGIN\_LABEL + "] " + msg);

&nbsp;   return FALSE;

}



integer json\_has(string j, list path) {

&nbsp;   return (llJsonGetValue(j, path) != JSON\_INVALID);

}



string generate\_session\_id() {

&nbsp;   return PLUGIN\_CONTEXT + "\_" + (string)llGetUnixTime();

}



// More helper functions here...



register\_self() {

&nbsp;   string msg = llList2Json(JSON\_OBJECT, \[

&nbsp;       "type", "register",

&nbsp;       "context", PLUGIN\_CONTEXT,

&nbsp;       "label", PLUGIN\_LABEL,

&nbsp;       "min\_acl", PLUGIN\_MIN\_ACL,

&nbsp;       "script", llGetScriptName()

&nbsp;   ]);

&nbsp;   llMessageLinked(LINK\_SET, KERNEL\_LIFECYCLE, msg, NULL\_KEY);

}



apply\_settings\_sync(string msg) {

&nbsp;   // Settings handler

}



show\_main\_menu() {

&nbsp;   // UI handler

}



// All other functions...



/\* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

&nbsp;  SECTION 6: STATES (MUST BE LAST, DEFAULT REQUIRED)

&nbsp;  â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• \*/

default

{

&nbsp;   state\_entry() {

&nbsp;       logd("Script started");

&nbsp;   }

&nbsp;   

&nbsp;   on\_rez(integer start\_param) {

&nbsp;       llResetScript();

&nbsp;   }

&nbsp;   

&nbsp;   link\_message(integer sender, integer num, string msg, key id) {

&nbsp;       if (!json\_has(msg, \["type"])) return;

&nbsp;       string msg\_type = llJsonGetValue(msg, \["type"]);

&nbsp;       

&nbsp;       if (num == KERNEL\_LIFECYCLE) {

&nbsp;           // Handle lifecycle

&nbsp;       }

&nbsp;       else if (num == SETTINGS\_BUS) {

&nbsp;           // Handle settings

&nbsp;       }

&nbsp;       // More handlers...

&nbsp;   }

&nbsp;   

&nbsp;   changed(integer change) {

&nbsp;       if (change \& CHANGED\_OWNER) {

&nbsp;           llResetScript();

&nbsp;       }

&nbsp;   }

}



// NO CODE AFTER THIS POINT - COMPILER ERROR

```



\*\*Critical Rules:\*\*

1\. âœ… Constants at top

2\. âœ… ALL functions defined before states

3\. âœ… Default state required

4\. âœ… Nothing after states

5\. âŒ No functions inside states

6\. âŒ No functions after states



---



Remember: LSL is NOT JavaScript/C/C++. Always validate your suggestions against LSL's actual syntax and capabilities!
