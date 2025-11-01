# Kanban Messaging - Proof of Concept

This document shows a side-by-side comparison of the Bell plugin before and after Kanban refactoring.

---

## Side-by-Side: Registration

### Before (Current)
```lsl
registerSelf() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}
```

### After (Kanban)
```lsl
registerSelf() {
    kanbanSendRegistration(PLUGIN_CONTEXT, PLUGIN_LABEL, PLUGIN_MIN_ACL);
}
```

**Savings**: 6 lines → 1 line, helper handles all boilerplate

---

## Side-by-Side: ACL Query

### Before (Current)
```lsl
requestAcl(key user) {
    AclPending = TRUE;
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user
    ]), user);
    logd("ACL query sent for " + llKey2Name(user));
}
```

### After (Kanban)
```lsl
requestAcl(key user) {
    AclPending = TRUE;
    kanbanQueryAcl(PLUGIN_CONTEXT, user, user);
    logd("ACL query sent for " + llKey2Name(user));
}
```

**Savings**: 5 lines → 1 line for message creation

---

## Side-by-Side: Settings Request

### Before (Current)
```lsl
requestSettings() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]), NULL_KEY);
}
```

### After (Kanban)
```lsl
requestSettings() {
    kanbanSettingsRequest(PLUGIN_CONTEXT);
}
```

**Savings**: Clear intent, no JSON construction needed

---

## Side-by-Side: Settings Update

### Before (Current)
```lsl
saveBellVisible(integer visible) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_BELL_VISIBLE,
        "value", (string)visible
    ]), NULL_KEY);
}
```

### After (Kanban)
```lsl
saveBellVisible(integer visible) {
    kanbanSettingsSet(PLUGIN_CONTEXT, KEY_BELL_VISIBLE, (string)visible);
}
```

**Savings**: Cleaner, delta operation built-in

---

## Side-by-Side: Message Reception (Complex Example)

### Before (Current)
```lsl
link_message(integer sender, integer num, string msg, key id) {
    // Validate JSON
    if (!jsonHas(msg, ["type"])) return;

    string msg_type = llJsonGetValue(msg, ["type"]);

    // KERNEL_LIFECYCLE messages
    if (num == KERNEL_LIFECYCLE) {
        if (msg_type == "register_now") {
            registerSelf();
        }
        else if (msg_type == "ping") {
            sendPong();
        }
    }

    // AUTH_BUS messages
    else if (num == AUTH_BUS) {
        if (msg_type == "acl_result") {
            if (!jsonHas(msg, ["avatar"])) return;
            key avatar = (key)llJsonGetValue(msg, ["avatar"]);
            if (avatar != CurrentUser) return;

            integer level = (integer)llJsonGetValue(msg, ["level"]);
            UserAcl = level;
            AclPending = FALSE;

            if (level >= PLUGIN_MIN_ACL) {
                showMainMenu();
            }
        }
    }

    // SETTINGS_BUS messages
    else if (num == SETTINGS_BUS) {
        if (msg_type == "settings_sync") {
            applySettingsSync(msg);
        }
        else if (msg_type == "settings_delta") {
            applySettingsDelta(msg);
        }
    }
}
```

### After (Kanban)
```lsl
link_message(integer sender, integer num, string msg, key id) {
    // Validate Kanban packet
    if (!kanbanIsValid(msg)) return;

    // Check if message is for me (or broadcast)
    if (!kanbanIsForMe(msg, PLUGIN_CONTEXT)) return;

    // Extract components
    string from = kanbanGetFrom(msg);
    string payload = kanbanGetPayload(msg);

    // Route by channel + sender
    if (num == KERNEL_LIFECYCLE && from == "kernel") {
        handleKernelMessage(payload);
    }
    else if (num == AUTH_BUS && from == "auth") {
        handleAclResult(payload, id);
    }
    else if (num == SETTINGS_BUS && from == "settings") {
        handleSettingsUpdate(payload);
    }
}

handleKernelMessage(string payload) {
    // Kernel sends empty payloads for register_now and ping
    // We determine which by context - both trigger same actions
    registerSelf();
}

handleAclResult(string payload, key correlation_key) {
    if (correlation_key != CurrentUser) return;

    integer level = (integer)payloadGet(payload, "level", "0");
    UserAcl = level;
    AclPending = FALSE;

    if (level >= PLUGIN_MIN_ACL) {
        showMainMenu();
    }
}

handleSettingsUpdate(string payload) {
    string op = deltaGetOp(payload);

    if (op == "set") {
        // Delta update
        string key = deltaGetKey(payload);
        string value = deltaGetValue(payload);

        if (key == KEY_BELL_VISIBLE) {
            BellVisible = (integer)value;
            setBellVisibility(BellVisible);
        }
        else if (key == KEY_BELL_SOUND_ENABLED) {
            BellSoundEnabled = (integer)value;
        }
        // ... etc
    }
    else {
        // Full sync - payload IS the settings object
        if (payloadHas(payload, KEY_BELL_VISIBLE)) {
            BellVisible = (integer)payloadGet(payload, KEY_BELL_VISIBLE, "0");
            setBellVisibility(BellVisible);
        }
        if (payloadHas(payload, KEY_BELL_SOUND_ENABLED)) {
            BellSoundEnabled = (integer)payloadGet(payload, KEY_BELL_SOUND_ENABLED, "0");
        }
        // ... etc
    }
}
```

**Benefits**:
- ✅ Clear routing: `num + from` determines handler
- ✅ No "type" field parsing needed
- ✅ Separated concerns: one handler per source
- ✅ Easy to add correlation checking
- ✅ Delta vs full sync handled explicitly

---

## Complete Refactored Example: Bell Plugin (Simplified)

```lsl
/* ===============================================================
   PLUGIN: ds_collar_plugin_bell.lsl (v2.0 - Kanban Messaging)
   =============================================================== */

#include "ds_collar_kanban_helpers.lsl"

integer DEBUG = FALSE;
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer DIALOG_BUS = 950;

string PLUGIN_CONTEXT = "bell";
string PLUGIN_LABEL = "Bell";
integer PLUGIN_MIN_ACL = 1;

// Settings keys
string KEY_BELL_VISIBLE = "bell_visible";
string KEY_BELL_SOUND_ENABLED = "bell_sound_enabled";
string KEY_BELL_VOLUME = "bell_volume";

// State
integer BellVisible = FALSE;
integer BellSoundEnabled = FALSE;
float BellVolume = 0.3;

key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";

// ===== HELPERS =====
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[BELL] " + msg);
    return FALSE;
}

string generateSessionId() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

// ===== BELL CONTROL =====
setBellVisibility(integer visible) {
    float alpha = visible ? 1.0 : 0.0;
    integer link_count = llGetNumberOfPrims();
    integer i;

    for (i = 1; i <= link_count; i++) {
        if (llToLower(llGetLinkName(i)) == "bell") {
            llSetLinkAlpha(i, alpha, ALL_SIDES);
        }
    }
    BellVisible = visible;
}

// ===== REGISTRATION =====
registerSelf() {
    kanbanSendRegistration(PLUGIN_CONTEXT, PLUGIN_LABEL, PLUGIN_MIN_ACL);
}

// ===== SETTINGS =====
requestSettings() {
    kanbanSettingsRequest(PLUGIN_CONTEXT);
}

saveBellVisible(integer visible) {
    kanbanSettingsSet(PLUGIN_CONTEXT, KEY_BELL_VISIBLE, (string)visible);
}

saveBellSoundEnabled(integer enabled) {
    kanbanSettingsSet(PLUGIN_CONTEXT, KEY_BELL_SOUND_ENABLED, (string)enabled);
}

saveBellVolume(float volume) {
    kanbanSettingsSet(PLUGIN_CONTEXT, KEY_BELL_VOLUME, (string)volume);
}

// ===== ACL =====
requestAcl(key user) {
    AclPending = TRUE;
    kanbanQueryAcl(PLUGIN_CONTEXT, user, user);
    logd("ACL query sent for " + llKey2Name(user));
}

// ===== MENU =====
showMainMenu() {
    if (UserAcl < PLUGIN_MIN_ACL) return;

    SessionId = generateSessionId();

    string visibility_btn = BellVisible ? "Hide" : "Show";
    string sound_btn = BellSoundEnabled ? "Mute" : "Unmute";

    list buttons = [visibility_btn, sound_btn, "Volume"];

    string payload = llList2Json(JSON_OBJECT, [
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Bell Settings",
        "body", "Current: " + (BellVisible ? "Visible" : "Hidden") +
                ", " + (BellSoundEnabled ? "Sound On" : "Muted") +
                "\nVolume: " + (string)((integer)(BellVolume * 100)) + "%",
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS,
        kanbanCreate(PLUGIN_CONTEXT, "dialogs", payload),
        NULL_KEY
    );
}

// ===== MESSAGE HANDLERS =====
handleKernelMessage(string payload) {
    // Register on any kernel message (register_now or ping)
    registerSelf();
}

handleAclResult(string payload, key correlation_key) {
    if (correlation_key != CurrentUser) return;

    integer level = (integer)payloadGet(payload, "level", "0");
    UserAcl = level;
    AclPending = FALSE;

    logd("ACL result: level " + (string)level);

    if (level >= PLUGIN_MIN_ACL) {
        showMainMenu();
    } else {
        llRegionSayTo(CurrentUser, 0, "Access denied. Public access required.");
        CurrentUser = NULL_KEY;
    }
}

handleSettingsUpdate(string payload) {
    string op = deltaGetOp(payload);

    if (op == "set") {
        // Delta update
        string key = deltaGetKey(payload);
        string value = deltaGetValue(payload);

        if (key == KEY_BELL_VISIBLE) {
            BellVisible = (integer)value;
            setBellVisibility(BellVisible);
            logd("Delta: bell_visible = " + value);
        }
        else if (key == KEY_BELL_SOUND_ENABLED) {
            BellSoundEnabled = (integer)value;
            logd("Delta: bell_sound_enabled = " + value);
        }
        else if (key == KEY_BELL_VOLUME) {
            BellVolume = (float)value;
            logd("Delta: bell_volume = " + value);
        }
    }
    else {
        // Full sync
        if (payloadHas(payload, KEY_BELL_VISIBLE)) {
            BellVisible = (integer)payloadGet(payload, KEY_BELL_VISIBLE, "0");
            setBellVisibility(BellVisible);
        }
        if (payloadHas(payload, KEY_BELL_SOUND_ENABLED)) {
            BellSoundEnabled = (integer)payloadGet(payload, KEY_BELL_SOUND_ENABLED, "0");
        }
        if (payloadHas(payload, KEY_BELL_VOLUME)) {
            BellVolume = (float)payloadGet(payload, KEY_BELL_VOLUME, "0.3");
        }
        logd("Full sync applied");
    }
}

handleDialogResponse(string payload) {
    string session = payloadGet(payload, "session_id", "");
    if (session != SessionId) return;

    string button = payloadGet(payload, "button_text", "");

    if (button == "Show" || button == "Hide") {
        integer new_visible = !BellVisible;
        saveBellVisible(new_visible);
        setBellVisibility(new_visible);
    }
    else if (button == "Mute" || button == "Unmute") {
        integer new_enabled = !BellSoundEnabled;
        saveBellSoundEnabled(new_enabled);
    }
    else if (button == "Volume") {
        // Show volume menu
    }

    // Refresh menu
    llSleep(0.5);
    showMainMenu();
}

// ===== UI TRIGGER =====
handleUiStart(string payload) {
    key user = (key)payloadGet(payload, "avatar", "");
    if (user == NULL_KEY) return;

    CurrentUser = user;
    requestAcl(user);
}

// ===== EVENTS =====
default {
    state_entry() {
        registerSelf();
        requestSettings();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        // Validate Kanban packet
        if (!kanbanIsValid(msg)) {
            // Could be legacy message - ignore for now
            return;
        }

        // Check if message is for me (or broadcast)
        if (!kanbanIsForMe(msg, PLUGIN_CONTEXT)) return;

        // Extract components
        string from = kanbanGetFrom(msg);
        string payload = kanbanGetPayload(msg);

        // Route by channel + sender
        if (num == KERNEL_LIFECYCLE && from == "kernel") {
            handleKernelMessage(payload);
        }
        else if (num == AUTH_BUS && from == "auth") {
            handleAclResult(payload, id);
        }
        else if (num == SETTINGS_BUS && from == "settings") {
            handleSettingsUpdate(payload);
        }
        else if (num == DIALOG_BUS && from == "dialogs") {
            handleDialogResponse(payload);
        }
        else if (num == UI_BUS && from == "ui") {
            handleUiStart(payload);
        }
    }
}
```

---

## Benefits Summary

### 1. **Less Code**
- Registration: 7 lines → 1 line
- ACL query: 5 lines → 1 line
- Settings update: 5 lines → 1 line

### 2. **Clearer Intent**
```lsl
// Before: What is this doing?
llMessageLinked(LINK_SET, 700, llList2Json(JSON_OBJECT, [
    "type", "acl_query",
    "avatar", (string)user
]), user);

// After: Crystal clear!
kanbanQueryAcl(PLUGIN_CONTEXT, user, user);
```

### 3. **Consistent Structure**
- Every message has from/payload/to
- No confusion about "type" vs context
- Routing is explicit

### 4. **Better Message Routing**
```lsl
// Before: Type-based routing (ambiguous)
if (msg_type == "acl_result") { ... }

// After: Source-based routing (explicit)
if (num == AUTH_BUS && from == "auth") { ... }
```

### 5. **Delta Support Built-In**
```lsl
// Receive delta OR full sync seamlessly
string op = deltaGetOp(payload);
if (op == "set") {
    // Handle delta
} else {
    // Handle full sync
}
```

### 6. **Easier Debugging**
```lsl
// Log all messages easily
logd("Received from '" + from + "' to '" + kanbanGetTo(msg) + "' on channel " + (string)num);
```

---

## Migration Path

1. ✅ Create `ds_collar_kanban_helpers.lsl`
2. ✅ Test with one plugin (Bell) - proof of concept
3. ⏳ Migrate core modules (kernel, auth, settings)
4. ⏳ Update all plugins to use Kanban
5. ⏳ Update external communication (HUD ↔ Collar)
6. ⏳ Remove legacy "type" handling

**Estimated effort**: ~2-3 days for full migration with testing
