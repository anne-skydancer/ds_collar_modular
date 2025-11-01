/* =============================================================================
   DS Collar - Lock Plugin (v2.0 - Kanban Messaging Migration)

   PURPOSE: Toggle collar lock/unlock with RLV detach control

   SIMPLIFIED: No menu - just toggles state immediately when clicked

   ACL: Unowned (4) and Primary Owner (5) only

   KANBAN MIGRATION (v2.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "lock";

/* ═══════════════════════════════════════════════════════════
   KANBAN UNIVERSAL HELPER (~500-800 bytes)
   ═══════════════════════════════════════════════════════════ */

string kFrom = "";  // Sender context (populated by kRecv)
string kTo = "";    // Recipient context (populated by kRecv)

kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, [
            "from", from,
            "payload", payload,
            "to", to
        ]),
        k
    );
}

string kRecv(string msg, string my_context) {
    // Quick validation: must be JSON object
    if (llGetSubString(msg, 0, 0) != "{") return "";

    // Extract from
    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    // Extract to
    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast "" or direct to my_context)
    if (to != "" && to != my_context) return "";

    // Extract payload
    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    // Set globals for routing
    kFrom = from;
    kTo = to;

    return payload;
}

string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

string kDeltaSet(string setting_key, string val) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", setting_key,
        "value", val
    ]);
}

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* ═══════════════════════════════════════════════════════════
   PLUGIN IDENTITY
   ═══════════════════════════════════════════════════════════ */
string PLUGIN_LABEL_LOCKED = "Locked: Y";    // Label when locked
string PLUGIN_LABEL_UNLOCKED = "Locked: N";    // Label when unlocked
integer PLUGIN_MIN_ACL = 4;  // Unowned wearer or owner

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
string KEY_LOCKED = "locked";

/* ═══════════════════════════════════════════════════════════
   SOUND
   ═══════════════════════════════════════════════════════════ */
string SOUND_TOGGLE = "3aacf116-f060-b4c8-bb58-07aefc0af33a";
float SOUND_VOLUME = 1.0;

/* ═══════════════════════════════════════════════════════════
   VISUAL PRIM NAMES (optional)
   ═══════════════════════════════════════════════════════════ */
string PRIM_LOCKED = "locked";
string PRIM_UNLOCKED = "unlocked";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
integer Locked = FALSE;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[LOCK] " + msg);
    return FALSE;
}

integer json_has(string json_data, list path) {
    return (llJsonGetValue(json_data, path) != JSON_INVALID);
}

play_toggle_sound() {
    llTriggerSound(SOUND_TOGGLE, SOUND_VOLUME);
}

/* ═══════════════════════════════════════════════════════════
   LIFECYCLE MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

register_self() {
    // Register with appropriate label based on current lock state
    string current_label = PLUGIN_LABEL_UNLOCKED;
    if (Locked) {
        current_label = PLUGIN_LABEL_LOCKED;
    }

    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload([
            "label", current_label,
            "min_acl", PLUGIN_MIN_ACL,
            "script", llGetScriptName()
        ]),
        NULL_KEY
    );
    logd("Registered as: " + current_label);
}

send_pong() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload(["pong", 1]),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS CONSUMPTION
   ═══════════════════════════════════════════════════════════ */

apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    
    integer old_locked = Locked;
    Locked = FALSE;
    
    if (json_has(kv_json, [KEY_LOCKED])) {
        Locked = (integer)llJsonGetValue(kv_json, [KEY_LOCKED]);
    }
    
    if (old_locked != Locked) {
        apply_lock_state();
    }
    
    logd("Settings sync: locked=" + (string)Locked);
}

apply_settings_delta(string payload) {
    string op = llJsonGetValue(payload, ["op"]);

    if (op == "set") {
        string setting_key = llJsonGetValue(payload, ["key"]);
        string value = llJsonGetValue(payload, ["value"]);

        if (setting_key == KEY_LOCKED) {
            integer old_locked = Locked;
            Locked = (integer)value;

            if (old_locked != Locked) {
                apply_lock_state();
                // Only update label, don't return to menu (no active user in delta context)
                string new_label = PLUGIN_LABEL_UNLOCKED;
                if (Locked) {
                    new_label = PLUGIN_LABEL_LOCKED;
                }
                kSend(CONTEXT, "ui", UI_BUS,
                    kPayload(["update_label", new_label]),
                    NULL_KEY
                );
            }

            logd("Delta: locked=" + value);
        }
    }
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS MODIFICATION
   ═══════════════════════════════════════════════════════════ */

persist_locked(integer new_value) {
    kSend(CONTEXT, "settings", SETTINGS_BUS,
        kDeltaSet(KEY_LOCKED, (string)new_value),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   LOCK STATE APPLICATION
   ═══════════════════════════════════════════════════════════ */

apply_lock_state() {
    key owner = llGetOwner();
    
    if (Locked) {
        // Lock collar - prevent detach
        llOwnerSay("@detach=n");
        show_locked_prim();
        logd("Applied lock state: LOCKED");
    }
    else {
        // Unlock collar - allow detach
        llOwnerSay("@detach=y");
        show_unlocked_prim();
        logd("Applied lock state: UNLOCKED");
    }
}

/* ═══════════════════════════════════════════════════════════
   VISUAL FEEDBACK (optional prims)
   ═══════════════════════════════════════════════════════════ */

show_locked_prim() {
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

show_unlocked_prim() {
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

/* ═══════════════════════════════════════════════════════════
   UI LABEL UPDATE
   ═══════════════════════════════════════════════════════════ */

update_ui_label_and_return(key user) {
    // Tell UI our new label
    string new_label = PLUGIN_LABEL_UNLOCKED;
    if (Locked) {
        new_label = PLUGIN_LABEL_LOCKED;
    }

    kSend(CONTEXT, "ui", UI_BUS,
        kPayload([
            "update_label", new_label
        ]),
        NULL_KEY
    );

    // Return user to root menu to see the updated button
    kSend(CONTEXT, "ui", UI_BUS,
        kPayload(["user", (string)user]),
        NULL_KEY
    );

    logd("Updated UI label to: " + new_label + " and returning to root");
}

/* ═══════════════════════════════════════════════════════════
   DIRECT TOGGLE ACTION
   ═══════════════════════════════════════════════════════════ */

toggle_lock(key user, integer acl_level) {
    // Verify ACL (only 4=unowned wearer, 5=owner)
    if (acl_level != 4 && acl_level != 5) {
        llRegionSayTo(user, 0, "Access denied.");
        return;
    }
    
    // Toggle state
    Locked = !Locked;
    
    // Play toggle sound
    play_toggle_sound();
    
    // Apply immediately
    apply_lock_state();
    
    // Persist change
    persist_locked(Locked);
    
    // Notify user
    if (Locked) {
        llRegionSayTo(user, 0, "Collar locked.");
    }
    else {
        llRegionSayTo(user, 0, "Collar unlocked.");
    }
    
    // Update UI label and return to root menu
    update_ui_label_and_return(user);
}

/* ═══════════════════════════════════════════════════════════
   ACL VALIDATION
   ═══════════════════════════════════════════════════════════ */

request_acl_and_toggle(key user) {
    kSend(CONTEXT, "auth", AUTH_BUS,
        kPayload(["avatar", (string)user]),
        user
    );
}

handle_acl_result(string msg, key expected_user) {
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != expected_user) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    
    // Toggle immediately with this ACL level
    toggle_lock(avatar, level);
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default {
    state_entry() {
        // Always start with safe defaults (unlocked)
        // Settings sync will override these immediately if saved state exists
        Locked = FALSE;
        apply_lock_state();

        register_self();

        // Request settings from settings module
        kSend(CONTEXT, "settings", SETTINGS_BUS,
            kPayload(["get", 1]),
            NULL_KEY
        );

        logd("Lock plugin initialized - requested settings");
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
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        // Route by channel + kFrom + payload structure

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE && kFrom == "kernel") {
            // Targeted soft_reset: has "context" field
            if (json_has(payload, ["context"])) {
                string target_context = llJsonGetValue(payload, ["context"]);
                if (target_context != "" && target_context != CONTEXT) {
                    return; // Not for us
                }
                llResetScript();
            }
            // Soft reset with "reset" marker
            else if (json_has(payload, ["reset"])) {
                llResetScript();
            }
            // Register now: has "register_now" marker
            else if (json_has(payload, ["register_now"])) {
                register_self();
            }
            // Ping: has "ping" marker
            else if (json_has(payload, ["ping"])) {
                send_pong();
            }
        }

        /* ===== SETTINGS BUS ===== */
        else if (num == SETTINGS_BUS && kFrom == "settings") {
            // Full sync: has "kv" field
            if (json_has(payload, ["kv"])) {
                apply_settings_sync(payload);
            }
            // Delta update: has "op" field
            else if (json_has(payload, ["op"])) {
                apply_settings_delta(payload);
            }
        }

        /* ===== UI START (TOGGLE ACTION) ===== */
        else if (num == UI_BUS) {
            // UI start: for our context
            if (kTo == CONTEXT && json_has(payload, ["user"])) {
                request_acl_and_toggle(id);
            }
        }

        /* ===== AUTH RESULT ===== */
        else if (num == AUTH_BUS && kFrom == "auth") {
            // ACL result: has "avatar" and "level" fields
            if (json_has(payload, ["avatar"]) && json_has(payload, ["level"])) {
                handle_acl_result(payload, id);
            }
        }
    }
}
