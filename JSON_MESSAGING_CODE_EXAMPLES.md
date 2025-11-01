# JSON Messaging - Actual Code Examples

This document shows real code examples extracted from the collar system.

## JSON Creation Examples

### Creating a Simple Object
```lsl
// From: ds_collar_kernel.lsl - broadcastRegisterNow()
string msg = llList2Json(JSON_OBJECT, [
    "type", "register_now"
]);
llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
```

### Creating an Object with Multiple Fields
```lsl
// From: ds_collar_plugin_bell.lsl - registerSelf()
llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
    "type", "register",
    "context", PLUGIN_CONTEXT,
    "label", PLUGIN_LABEL,
    "min_acl", PLUGIN_MIN_ACL,
    "script", llGetScriptName()
]), NULL_KEY);
```

### Creating with Nested Objects
```lsl
// From: ds_collar_kernel.lsl - broadcastPluginList()
string plugin_obj = llList2Json(JSON_OBJECT, [
    "context", context,
    "label", label,
    "min_acl", min_acl
]);
```

### Creating with Arrays
```lsl
// From: ds_collar_plugin_bell.lsl - showMenu()
llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
    "type", "dialog_open",
    "session_id", SessionId,
    "user", (string)CurrentUser,
    "title", title,
    "body", body,
    "buttons", llList2Json(JSON_ARRAY, buttons),  // Array of button strings
    "timeout", 60
]), NULL_KEY);
```

## JSON Parsing Examples

### Extract Single Value
```lsl
// From: ds_collar_kernel.lsl - handleRegister()
string context = llJsonGetValue(msg, ["context"]);
string label = llJsonGetValue(msg, ["label"]);
integer min_acl = (integer)llJsonGetValue(msg, ["min_acl"]);
```

### Check if Field Exists
```lsl
// From: multiple files - common pattern
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

// Usage
if (!jsonHas(msg, ["context"])) return;  // Safe to access now
```

### Extract with Default Value
```lsl
// From: ds_collar_kmod_leash.lsl
string jsonGet(string j, string k, string default_val) {
    if (jsonHas(j, [k])) return llJsonGetValue(j, [k]);
    return default_val;
}

// Usage
string holder_name = jsonGet(msg, "name", "Unknown");
```

### Convert JSON Array to List
```lsl
// From: ds_collar_kmod_settings.lsl - kvListAddUnique()
string arr = kvGet(key_name);
list current_list = [];
if (isJsonArr(arr)) {
    current_list = llJson2List(arr);  // Convert "[uuid1", "uuid2"]  to list
}
```

### Nested Path Access
```lsl
// From: ds_collar_kmod_auth.lsl - sendAclResult()
string kv = llJsonGetValue(msg, ["kv"]);  // Nested path example

// In ds_collar_plugin_owner.lsl
if (jsonHas(kv, [KEY_MULTI_OWNER_MODE])) {
    MultiOwnerMode = (integer)llJsonGetValue(kv, [KEY_MULTI_OWNER_MODE]);
}
```

## JSON Modification Examples

### Set/Update Values
```lsl
// From: ds_collar_kmod_auth.lsl - sendAclResult()
string msg = llList2Json(JSON_OBJECT, [
    "type", "acl_result",
    "avatar", (string)av,
    "level", level
]);

// Add correlation ID to existing message
if (correlation_id != "") {
    msg = llJsonSetValue(msg, ["id"], correlation_id);
}
```

### Update Settings Value
```lsl
// From: ds_collar_kmod_settings.lsl - kvSetScalar()
integer kvSetScalar(string key_name, string value) {
    string old_val = kvGet(key_name);
    if (old_val == value) return FALSE;  // No change
    
    KvJson = llJsonSetValue(KvJson, [key_name], value);
    logd("SET " + key_name + " = " + value);
    return TRUE;
}
```

### Update Array in JSON
```lsl
// From: ds_collar_kmod_settings.lsl - kvSetList()
integer kvSetList(string key_name, list values) {
    string new_arr = llList2Json(JSON_ARRAY, values);
    string old_arr = kvGet(key_name);
    if (old_arr == new_arr) return FALSE;
    
    KvJson = llJsonSetValue(KvJson, [key_name], new_arr);
    logd("SET " + key_name + " count=" + (string)llGetListLength(values));
    return TRUE;
}
```

## Message Handling Pattern

### Complete Message Handler
```lsl
// From: ds_collar_kernel.lsl - link_message event
link_message(integer sender, integer num, string msg, key id) {
    // SECURITY: Check channel
    if (num != KERNEL_LIFECYCLE) return;
    
    // SECURITY: Verify message has type field
    if (!jsonHas(msg, ["type"])) return;
    
    // Dispatch to handler
    string msg_type = llJsonGetValue(msg, ["type"]);
    
    if (msg_type == "register") {
        handleRegister(msg);
    }
    else if (msg_type == "pong") {
        handlePong(msg);
    }
    else if (msg_type == "soft_reset") {
        handleSoftReset(msg);
    }
}
```

### Specialized Handler
```lsl
// From: ds_collar_kmod_auth.lsl - handleAclQuery()
handleAclQuery(string msg, key query_sender) {
    // Validate required fields
    if (!jsonHas(msg, ["avatar"])) return;
    if (!jsonHas(msg, ["id"])) return;
    
    // Extract values
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    string correlation_id = llJsonGetValue(msg, ["id"]);
    
    // Compute ACL
    integer acl_level = computeAclLevel(avatar);
    
    // Build response with correlation ID
    sendAclResult(avatar, correlation_id);
}
```

## Settings Management Examples

### Full Sync
```lsl
// From: ds_collar_kmod_settings.lsl - broadcastFullSync()
broadcastFullSync() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_sync",
        "kv", KvJson  // Entire settings object
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    logd("Broadcast: full sync");
}
```

### Delta Update (Efficient)
```lsl
// From: ds_collar_kmod_settings.lsl - broadcastDeltaScalar()
broadcastDeltaScalar(string key_name, string new_value) {
    string changes = llList2Json(JSON_OBJECT, [
        key_name, new_value
    ]);
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_delta",
        "op", "set",
        "changes", changes
    ]);
    
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    logd("Broadcast: delta set " + key_name);
}

// List add delta
broadcastDeltaListAdd(string key_name, string elem) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_delta",
        "op", "list_add",
        "key", key_name,
        "elem", elem
    ]);
    
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}
```

### Consuming Settings
```lsl
// From: ds_collar_plugin_owner.lsl - applySettingsSync()
applySettingsSync(string msg) {
    if (!jsonHas(msg, ["kv"])) return;
    string kv = llJsonGetValue(msg, ["kv"]);
    
    // Extract individual settings
    if (jsonHas(kv, [KEY_OWNER_KEY])) {
        OwnerKey = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
    }
    
    // Extract arrays
    if (jsonHas(kv, [KEY_OWNER_KEYS])) {
        string arr = llJsonGetValue(kv, [KEY_OWNER_KEYS]);
        if (llGetSubString(arr, 0, 0) == "[") {
            OwnerKeys = llJson2List(arr);  // Convert JSON array to list
        }
    }
}
```

## External Communication Examples

### Discovery Flow
```lsl
// From: ds_collar_control_hud.lsl - broadcastCollarScan()
broadcastCollarScan() {
    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "collar_scan",
        "hud_wearer", (string)HudWearer
    ]);

    // Set up listener for responses
    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
    }
    CollarListenHandle = llListen(PUBLIC_DISCOVERY_REPLY_CHAN, "", NULL_KEY, "");

    // Broadcast on public channel
    llRegionSay(PUBLIC_DISCOVERY_CHAN, json_msg);
    
    ScanningForCollars = TRUE;
    llSetTimerEvent(COLLAR_SCAN_TIME);
}
```

### Session Establishment
```lsl
// From: ds_collar_control_hud.lsl - requestSessionEstablishment()
requestSessionEstablishment(key collar_owner) {
    deriveSessionChannels(collar_owner);

    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "session_establish",
        "hud_wearer", (string)HudWearer,
        "collar_owner", (string)collar_owner,
        "session_query", (string)SESSION_QUERY_CHAN,
        "session_reply", (string)SESSION_REPLY_CHAN,
        "session_menu", (string)SESSION_MENU_CHAN
    ]);

    llRegionSay(PUBLIC_DISCOVERY_CHAN, json_msg);
    
    SessionPending = TRUE;
    llSetTimerEvent(QUERY_TIMEOUT_SEC);
}
```

### Session Channel Derivation
```lsl
// From: both HUD and kmod_remote.lsl
integer deriveSessionChannel(integer base_channel, key hud_wearer, key collar_owner) {
    integer seed1 = (integer)("0x" + llGetSubString((string)hud_wearer, 0, 7));
    integer seed2 = (integer)("0x" + llGetSubString((string)collar_owner, 0, 7));
    integer combined = (seed1 ^ seed2);
    return base_channel + (combined % 1000000);
}

// Usage
SESSION_QUERY_CHAN = deriveSessionChannel(SESSION_BASE_CHAN, HudWearer, collar_owner);
SESSION_REPLY_CHAN = SESSION_QUERY_CHAN - 1;
SESSION_MENU_CHAN = SESSION_QUERY_CHAN - 2;
```

### Direct Object Communication
```lsl
// From: ds_collar_control_hud.lsl - triggerCollarMenu()
triggerCollarMenu() {
    if (TargetCollarKey == NULL_KEY) {
        llOwnerSay("Error: No collar connection established.");
        return;
    }

    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "menu_request_external",
        "avatar", (string)HudWearer
    ]);

    llRegionSayTo(TargetCollarKey, SESSION_MENU_CHAN, json_msg);
}
```

## Dialog System Examples

### Opening a Dialog
```lsl
// From: ds_collar_plugin_bell.lsl - showMenu()
showMenu(string context, string title, string body, list buttons) {
    SessionId = generateSessionId();
    MenuContext = context;
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]), NULL_KEY);
}
```

### Handling Dialog Response
```lsl
// From: ds_collar_plugin_bell.lsl - link_message event
else if (msg_type == "dialog_response") {
    if (jsonHas(msg, ["session_id"])) {
        string session = llJsonGetValue(msg, ["session_id"]);
        if (session == SessionId) {
            // This response is for our dialog
            integer button_index = (integer)llJsonGetValue(msg, ["button_index"]);
            string button_text = llJsonGetValue(msg, ["button_text"]);
            
            // Process button click
            handleMenuResponse(button_text);
        }
    }
}
```

## Leash-Specific Examples

### Sending Leash Action
```lsl
// From: ds_collar_plugin_leash.lsl - sendLeashAction()
sendLeashAction(string action, key target, integer session) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", action,
        "avatar", (string)CurrentUser,
        "target", (string)target,
        "session", (string)session
    ]);
    
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}
```

### Handling Leash State Update
```lsl
// From: ds_collar_plugin_leash.lsl - applyLeashState()
applyLeashState(string msg) {
    if (!jsonHas(msg, ["settings"])) return;
    
    string settings_json = llJsonGetValue(msg, ["settings"]);
    
    if (jsonHas(settings_json, [KEY_LEASHED])) {
        Leashed = (integer)llJsonGetValue(settings_json, [KEY_LEASHED]);
    }
    if (jsonHas(settings_json, [KEY_LEASHER])) {
        Leasher = (key)llJsonGetValue(settings_json, [KEY_LEASHER]);
    }
    if (jsonHas(settings_json, [KEY_LEASH_LENGTH])) {
        LeashLength = (integer)llJsonGetValue(settings_json, [KEY_LEASH_LENGTH]);
    }
}
```

### Broadcasting Leash State
```lsl
// From: ds_collar_kmod_leash.lsl - persistLeashState()
persistLeashState(integer leashed, key leasher) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "leash_state",
        "leashed", (string)leashed,
        "leasher", (string)leasher,
        "length", (string)LeashLength,
        "turnto", (string)TurnToFace,
        "mode", (string)LeashMode,
        "target", (string)LeashTarget
    ]);
    
    // Store in settings
    broadcastLeashState(msg);
}
```

## Error Handling Examples

### Graceful Null Handling
```lsl
// From: ds_collar_kmod_settings.lsl - kvGet()
string kvGet(string key_name) {
    string val = llJsonGetValue(KvJson, [key_name]);
    if (val == JSON_INVALID) return "";
    return val;
}

// Usage is safe
string owner_key = kvGet("owner_key");  // Returns "" if not set, not JSON_INVALID
```

### Type Validation
```lsl
// From: multiple files
integer isJsonArr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

integer isJsonObj(string s) {
    return (llGetSubString(s, 0, 0) == "{");
}

// Usage
if (isJsonArr(arr)) {
    list values = llJson2List(arr);
}
```

### Authorization Checking
```lsl
// From: ds_collar_kernel.lsl - handleSoftReset()
handleSoftReset(string msg) {
    string from = llJsonGetValue(msg, ["from"]);
    
    if (from == JSON_INVALID || from == "") {
        llOwnerSay("[KERNEL] ERROR: Soft reset rejected - sender not identified");
        return;
    }
    
    if (!isAuthorizedSender(from)) {
        llOwnerSay("[KERNEL] ERROR: Soft reset rejected - unauthorized sender: " + from);
        return;
    }
    
    // Authorized - proceed
}
```

## Performance Optimization Examples

### Caching Parsed Values
```lsl
// From: ds_collar_plugin_leash.lsl
// Instead of parsing the same JSON multiple times:
if (jsonHas(settings_json, [KEY_LEASHED])) {
    Leashed = (integer)llJsonGetValue(settings_json, [KEY_LEASHED]);
}
// Cache in variable, then use Leashed variable repeatedly
```

### Delta Updates vs Full Sync
```lsl
// INEFFICIENT: Always send full object
broadcastFullSync();  // Sends all 20+ settings

// EFFICIENT: Only send what changed
broadcastDeltaScalar("leashed", "1");
broadcastDeltaListAdd("trustees", new_trustee_uuid);
```

### Session-based Pruning
```lsl
// From: ds_collar_kmod_dialogs.lsl - pruneExpiredSessions()
pruneExpiredSessions() {
    integer now_unix = now();
    integer i = 0;
    
    while (i < llGetListLength(Sessions)) {
        integer timeout = llList2Integer(Sessions, i + SESSION_TIMEOUT);
        
        if (timeout > 0 && now_unix >= timeout) {
            // Remove expired session
            closeSessionAtIdx(i);
            // Don't increment i, list shifted
        }
        else {
            i += SESSION_STRIDE;
        }
    }
}
```

