/* ===============================================================
   PLUGIN: ds_collar_plugin_lock.lsl (v1.0 - Direct Toggle)

   PURPOSE: Toggle collar lock/unlock with RLV detach control
   
   SIMPLIFIED: No menu - just toggles state immediately when clicked
   
   ACL: Unowned (4) and Primary Owner (5) only
   =============================================================== */

integer DEBUG = FALSE;

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* ===============================================================
   PLUGIN IDENTITY
   =============================================================== */
string PLUGIN_CONTEXT = "core_lock";
string PLUGIN_LABEL_LOCKED = "Locked: Y";    // Label when locked
string PLUGIN_LABEL_UNLOCKED = "Locked: N";    // Label when unlocked
integer PLUGIN_MIN_ACL = 4;  // Unowned wearer or owner
string ROOT_CONTEXT = "core_root";

/* ===============================================================
   SETTINGS KEYS
   =============================================================== */
string KEY_LOCKED = "locked";

/* ===============================================================
   SOUND
   =============================================================== */
string SOUND_TOGGLE = "3aacf116-f060-b4c8-bb58-07aefc0af33a";
float SOUND_VOLUME = 1.0;

/* ===============================================================
   VISUAL PRIM NAMES (optional)
   =============================================================== */
string PRIM_LOCKED = "locked";
string PRIM_UNLOCKED = "unlocked";

/* ===============================================================
   STATE
   =============================================================== */
integer Locked = FALSE;

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[LOCK] " + msg);
    return FALSE;
}

integer jsonHas(string json_data, list path) {
    return (llJsonGetValue(json_data, path) != JSON_INVALID);
}

playToggleSound() {
    llTriggerSound(SOUND_TOGGLE, SOUND_VOLUME);
}

/* ===============================================================
   LIFECYCLE MANAGEMENT
   =============================================================== */

registerSelf() {
    // Register with appropriate label based on current lock state
    string current_label = PLUGIN_LABEL_UNLOCKED;
    if (Locked) {
        current_label = PLUGIN_LABEL_LOCKED;
    }
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", current_label,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Registered as: " + current_label);
}

sendPong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* ===============================================================
   SETTINGS CONSUMPTION
   =============================================================== */

applySettingsSync(string msg) {
    if (!jsonHas(msg, ["kv"])) return;

    string kv_json = llJsonGetValue(msg, ["kv"]);

    integer old_locked = Locked;
    Locked = FALSE;

    if (jsonHas(kv_json, [KEY_LOCKED])) {
        Locked = (integer)llJsonGetValue(kv_json, [KEY_LOCKED]);
    }

    if (old_locked != Locked) {
        applyLockState();
    }

    logd("Settings sync: locked=" + (string)Locked);
}

applySettingsDelta(string msg) {
    if (!jsonHas(msg, ["op"])) return;

    string op = llJsonGetValue(msg, ["op"]);

    if (op == "set") {
        if (!jsonHas(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);

        if (jsonHas(changes, [KEY_LOCKED])) {
            integer old_locked = Locked;
            Locked = (integer)llJsonGetValue(changes, [KEY_LOCKED]);

            if (old_locked != Locked) {
                applyLockState();
                // Only update label, don't return to menu (no active user in delta context)
                string new_label = PLUGIN_LABEL_UNLOCKED;
                if (Locked) {
                    new_label = PLUGIN_LABEL_LOCKED;
                }
                string msg = llList2Json(JSON_OBJECT, [
                    "type", "update_label",
                    "context", PLUGIN_CONTEXT,
                    "label", new_label
                ]);
                llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
            }

            logd("Delta: locked=" + (string)Locked);
        }
    }
}

/* ===============================================================
   SETTINGS MODIFICATION
   =============================================================== */

persistLocked(integer new_value) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_LOCKED,
        "value", (string)new_value
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

/* ===============================================================
   LOCK STATE APPLICATION
   =============================================================== */

applyLockState() {
    key owner = llGetOwner();

    if (Locked) {
        // Lock collar - prevent detach
        llOwnerSay("@detach=n");
        showLockedPrim();
        logd("Applied lock state: LOCKED");
    }
    else {
        // Unlock collar - allow detach
        llOwnerSay("@detach=y");
        showUnlockedPrim();
        logd("Applied lock state: UNLOCKED");
    }
}

/* ===============================================================
   VISUAL FEEDBACK (optional prims)
   =============================================================== */

showLockedPrim() {
    integer link_count = llGetNumberOfPrims();
    integer i;

    for (i = 1; i <= link_count; i++) {
        string name = llGetLinkName(i);

        if (name == PRIM_LOCKED) {
            llSetLinkAlpha(i, 1.0, ALL_SIDES);
        }
        else if (name == PRIM_UNLOCKED) {
            llSetLinkAlpha(i, 0.0, ALL_SIDES);
        }
    }
}

showUnlockedPrim() {
    integer link_count = llGetNumberOfPrims();
    integer i;

    for (i = 1; i <= link_count; i++) {
        string name = llGetLinkName(i);

        if (name == PRIM_LOCKED) {
            llSetLinkAlpha(i, 0.0, ALL_SIDES);
        }
        else if (name == PRIM_UNLOCKED) {
            llSetLinkAlpha(i, 1.0, ALL_SIDES);
        }
    }
}

/* ===============================================================
   UI LABEL UPDATE
   =============================================================== */

updateUiLabelAndReturn(key user) {
    // Tell UI our new label
    string new_label = PLUGIN_LABEL_UNLOCKED;
    if (Locked) {
        new_label = PLUGIN_LABEL_LOCKED;
    }

    string msg = llList2Json(JSON_OBJECT, [
        "type", "update_label",
        "context", PLUGIN_CONTEXT,
        "label", new_label
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);

    // Return user to root menu to see the updated button
    msg = llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)user
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);

    logd("Updated UI label to: " + new_label + " and returning to root");
}

/* ===============================================================
   DIRECT TOGGLE ACTION
   =============================================================== */

toggleLock(key user, integer acl_level) {
    // Verify ACL (only 4=unowned wearer, 5=owner)
    if (acl_level != 4 && acl_level != 5) {
        llRegionSayTo(user, 0, "Access denied.");
        return;
    }

    // Toggle state
    Locked = !Locked;

    // Play toggle sound
    playToggleSound();

    // Apply immediately
    applyLockState();

    // Persist change
    persistLocked(Locked);

    // Notify user
    if (Locked) {
        llRegionSayTo(user, 0, "Collar locked.");
    }
    else {
        llRegionSayTo(user, 0, "Collar unlocked.");
    }

    // Update UI label and return to root menu
    updateUiLabelAndReturn(user);
}

/* ===============================================================
   ACL VALIDATION
   =============================================================== */

requestAclAndToggle(key user) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_toggle"
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

handleAclResult(string msg, key expected_user) {
    if (!jsonHas(msg, ["avatar"])) return;
    if (!jsonHas(msg, ["level"])) return;

    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != expected_user) return;

    integer level = (integer)llJsonGetValue(msg, ["level"]);

    // Toggle immediately with this ACL level
    toggleLock(avatar, level);
}

/* ===============================================================
   EVENTS
   =============================================================== */

default {
    state_entry() {
        Locked = FALSE;
        registerSelf();
        applyLockState();
        logd("Ready");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        // ===== KERNEL LIFECYCLE =====
        if (num == KERNEL_LIFECYCLE) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);

            if (msg_type == "register_now") {
                registerSelf();
                return;
            }

            if (msg_type == "ping") {
                sendPong();
                return;
            }
            
            return;
        }
        
        // ===== SETTINGS SYNC/DELTA =====
        if (num == SETTINGS_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);

            if (msg_type == "settings_sync") {
                applySettingsSync(msg);
                return;
            }

            if (msg_type == "settings_delta") {
                applySettingsDelta(msg);
                return;
            }
            
            return;
        }
        
        // ===== UI START (TOGGLE ACTION) =====
        if (num == UI_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);

            if (msg_type == "start") {
                if (!jsonHas(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                // Request ACL and toggle when we get it
                requestAclAndToggle(id);
                return;
            }
            
            return;
        }
        
        // ===== AUTH RESULT =====
        if (num == AUTH_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);

            if (msg_type == "acl_result") {
                // Check if this is our toggle request
                if (jsonHas(msg, ["id"])) {
                    string corr_id = llJsonGetValue(msg, ["id"]);
                    if (corr_id == PLUGIN_CONTEXT + "_toggle") {
                        if (!jsonHas(msg, ["avatar"])) return;
                        key user = (key)llJsonGetValue(msg, ["avatar"]);
                        handleAclResult(msg, user);
                    }
                }
                return;
            }
            
            return;
        }
    }
}
