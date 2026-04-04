/*--------------------
PLUGIN: plugin_lock.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Toggle collar lock and RLV detach control labels
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL and ACL checks in toggle_lock()
  with policy reads. Uses btn_allowed("toggle") for access control.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_lock";
string PLUGIN_LABEL_LOCKED = "Locked: Y";    // Label when locked
string PLUGIN_LABEL_UNLOCKED = "Locked: N";    // Label when unlocked

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_LOCKED = "lock.locked";

/* -------------------- SOUND -------------------- */
string SOUND_TOGGLE = "3aacf116-f060-b4c8-bb58-07aefc0af33a";
float SOUND_VOLUME = 1.0;

/* -------------------- VISUAL PRIM NAMES (optional) -------------------- */
string PRIM_LOCKED = "locked";
string PRIM_UNLOCKED = "unlocked";

/* -------------------- STATE -------------------- */
integer Locked = FALSE;
list gPolicyButtons = [];

/* -------------------- HELPERS -------------------- */

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

play_toggle_sound() {
    llTriggerSound(SOUND_TOGGLE, SOUND_VOLUME);
}

/* -------------------- LSD POLICY HELPER -------------------- */
list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("policy:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

register_self() {
    // Write button visibility policy to LSD (only ACL 4 and 5 can toggle)
    llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "4", "toggle",
        "5", "toggle"
    ]));

    // Register with appropriate label based on current lock state
    string current_label = PLUGIN_LABEL_UNLOCKED;
    if (Locked) {
        current_label = PLUGIN_LABEL_LOCKED;
    }

    // Register with kernel
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", current_label,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- SETTINGS CONSUMPTION -------------------- */

apply_settings_sync(string msg) {
    string kv_json = llJsonGetValue(msg, ["kv"]);
    if (kv_json == JSON_INVALID) return;

    string lsd_val = llLinksetDataRead(KEY_LOCKED);
    if (lsd_val != "") {
        // LSD is authoritative — restore persisted runtime state
        Locked = (integer)lsd_val;
        apply_lock_state();
    }
    else {
        // First wear: seed from notecard and write to LSD
        Locked = FALSE;  // Secure default
        string tmp = llJsonGetValue(kv_json, [KEY_LOCKED]);
        if (tmp != JSON_INVALID) {
            Locked = (integer)tmp;
        }
        apply_lock_state();
        llLinksetDataWrite(KEY_LOCKED, (string)Locked);
    }
}

apply_settings_delta(string msg) {
    string op = llJsonGetValue(msg, ["op"]);
    if (op == JSON_INVALID) return;

    if (op == "set") {
        string changes = llJsonGetValue(msg, ["changes"]);
        if (changes == JSON_INVALID) return;

        if ((llJsonGetValue(changes, [KEY_LOCKED]) != JSON_INVALID)) {
            integer old_locked = Locked;
            Locked = (integer)llJsonGetValue(changes, [KEY_LOCKED]);
            llLinksetDataWrite(KEY_LOCKED, (string)Locked);

            if (old_locked != Locked) {
                apply_lock_state();
                // Only update label, don't return to menu (no active user in delta context)
                string new_label = PLUGIN_LABEL_UNLOCKED;
                if (Locked) {
                    new_label = PLUGIN_LABEL_LOCKED;
                }
                string label_msg = llList2Json(JSON_OBJECT, [
                    "type", "update_label",
                    "context", PLUGIN_CONTEXT,
                    "label", new_label
                ]);
                llMessageLinked(LINK_SET, UI_BUS, label_msg, NULL_KEY);
            }
        }
    }
    else if (op == "delete") {
        // SECURE DEFAULT: If lock setting is deleted, revert to unlocked
        string deleted_key = llJsonGetValue(msg, ["key"]);
        if (deleted_key == JSON_INVALID) return;

        if (deleted_key == KEY_LOCKED) {
            if (Locked) {
                // Was locked, now reverting to unlocked
                Locked = FALSE;
                llLinksetDataWrite(KEY_LOCKED, "0");
                apply_lock_state();
                llOwnerSay("Lock setting deleted - reverting to unlocked state");

                // Update UI label
                string label_msg = llList2Json(JSON_OBJECT, [
                    "type", "update_label",
                    "context", PLUGIN_CONTEXT,
                    "label", PLUGIN_LABEL_UNLOCKED
                ]);
                llMessageLinked(LINK_SET, UI_BUS, label_msg, NULL_KEY);
            }
        }
    }
}

/* -------------------- SETTINGS MODIFICATION -------------------- */

persist_locked(integer new_value) {
    // Write to LSD immediately so state survives relog
    llLinksetDataWrite(KEY_LOCKED, (string)new_value);

    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_LOCKED,
        "value", (string)new_value
    ]), NULL_KEY);
}

/* -------------------- LOCK STATE APPLICATION -------------------- */

apply_lock_state() {

    if (Locked) {
        // Lock collar - prevent detach
        llOwnerSay("@detach=n");
        show_locked_prim();
    }
    else {
        // Unlock collar - allow detach
        llOwnerSay("@detach=y");
        show_unlocked_prim();
    }
}

/* -------------------- VISUAL FEEDBACK (optional prims) -------------------- */

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

/* -------------------- UI LABEL UPDATE -------------------- */

update_ui_label_and_return(key user) {
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
}

/* -------------------- DIRECT TOGGLE ACTION -------------------- */

toggle_lock(key user, integer acl_level) {
    // Verify ACL via policy
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("toggle")) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

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


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        gPolicyButtons = [];
        // Restore from LSD immediately (survives relog); first-wear seeding happens via settings_sync
        string lsd_val = llLinksetDataRead(KEY_LOCKED);
        if (lsd_val != "") {
            Locked = (integer)lsd_val;
            apply_lock_state();
        }
        // Request settings to complete registration and handle first-wear seeding
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]), NULL_KEY);
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
        /* -------------------- KERNEL LIFECYCLE -------------------- */if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "register_now") {
                // Re-request settings after kernel reset to restore lock state
                llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
                    "type", "settings_get"
                ]), NULL_KEY);
                return;
            }

            if (msg_type == "ping") {
                send_pong();
                return;
            }

            return;
        }

        /* -------------------- SETTINGS SYNC/DELTA -------------------- */if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
                register_self();  // Register after settings applied with correct state
                return;
            }

            if (msg_type == "settings_delta") {
                apply_settings_delta(msg);
                return;
            }

            return;
        }

        /* -------------------- UI START (TOGGLE ACTION) -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "start") {
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                integer acl = (integer)llJsonGetValue(msg, ["acl"]);
                toggle_lock(id, acl);
                return;
            }

            return;
        }

    }
}
