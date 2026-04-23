/*--------------------
PLUGIN: plugin_lock.lsl
VERSION: 1.10
REVISION: 12
PURPOSE: Toggle collar lock and RLV detach control labels
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility,
  namespaced internal message protocol
CHANGES:
- v1.1 rev 12: write_plugin_reg guards idempotent writes (read-before-
  write). Same-value re-registrations on state_entry and
  kernel.register.refresh no longer fire linkset_data, so kmod_ui's
  debounced rebuild + session invalidation stops triggering on
  register.refresh cascades — wearer's open menu survives the event.
- v1.1 rev 11: Use the existing state-based label resolution path instead
  of writing labels to plugin.reg.<ctx> on every toggle. register_self now
  registers a buttonconfig (ui.dialog.buttonconfig.register) for the
  Locked:Y / Locked:N pair once, and emits ui.state.update with the
  current state. Toggle paths (set_lock_state, toggle_lock,
  apply_settings_sync) send ui.state.update; plugin.reg.<ctx> is written
  once at registration and then left alone. Eliminates the LSD write,
  linkset_data fire, debounce, and rebuild that used to happen on every
  single lock/unlock.
- v1.1 rev 10: apply_settings_sync now plays the toggle sound on settings-
  driven state changes so notecard-reload lock/unlock events are audibly
  consistent with menu toggles. Paired with kmod_settings rev 9, which
  makes "Reload Settings" actually re-read the notecard — the sound now
  accompanies a real state change (e.g. wearer unlocked via menu, then
  reload re-applies lock.locked=1 from the notecard).
- v1.1 rev 9: Add dormancy guard in state_entry — script parks itself
  if the prim's object description is "COLLAR_UPDATER" so it stays dormant
  when staged in an updater installer prim.
- v1.1 rev 8: Self-declare menu presence via LSD (plugin.reg.<ctx>) instead
  of relying on the kernel to broadcast the plugin list. Label updates write
  the same LSD key directly; ui.label.update link_messages are gone. Reset
  handlers delete plugin.reg.<ctx> and acl.policycontext:<ctx> before
  llResetScript so kmod_ui drops the button as soon as the reset lands.
- v1.1 rev 7: "lock locked"/"lock unlocked" chat subpaths no longer
  trigger ui.menu.return (which was reopening root menu after a bare
  chat command). Label update is now sent without menu navigation for
  chat-originated state changes. Toggle (menu-click + bare "lock" chat)
  still returns to root, matching menu-click expectations.
- v1.1 rev 6: Chat command support (Phase 3). Registers "lock" alias.
  "<prefix> lock" toggles (same as menu click); "lock locked" /
  "lock unlocked" set state idempotently. All routes share the same
  btn_allowed("toggle") ACL gate.
- v1.1 rev 5: Wire-type rename (Phase 2). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.reset→kernel.reset.soft,
  kernel.resetall→kernel.reset.factory.
- v1.1 rev 4: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.1 rev 3: Namespaced internal message types. All type strings now use
  dot-delimited namespace convention (e.g. kernel.register, ui.label.update,
  settings.set). No behavioral changes.
- v1.1 rev 2: Honor soft_reset / soft_reset_all from KERNEL_LIFECYCLE so
  factory reset clears cached lock state.
- v1.1 rev 1: Migrate settings reads from JSON broadcast to direct LSD reads.
  Remove apply_settings_delta(); fold side effects into apply_settings_sync()
  via previous-state comparison. Both settings_sync and settings_delta call
  parameterless apply_settings_sync(). Remove settings_get request; call
  apply_settings_sync() directly from state_entry.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL and ACL checks in toggle_lock()
  with policy reads. Uses btn_allowed("toggle") for access control.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.lock";
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
    string policy = llLinksetDataRead("acl.policycontext:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
write_plugin_reg(string label) {
    string k = "plugin.reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, [
        "label",  label,
        "script", llGetScriptName()
    ]);
    // Skip the write (and its linkset_data event) when the stored value
    // is already what we would write. Idempotent re-registrations on
    // state_entry or kernel.register.refresh then no longer trigger
    // kmod_ui's debounced rebuild + session invalidation.
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

// Tell kmod_dialogs how to render this plugin's button based on state:
//   state == 0 → PLUGIN_LABEL_UNLOCKED
//   state != 0 → PLUGIN_LABEL_LOCKED
// Registered once per state_entry; kmod_dialogs resolves labels per render.
register_button_config() {
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",     "ui.dialog.buttonconfig.register",
        "context",  PLUGIN_CONTEXT,
        "button_a", PLUGIN_LABEL_UNLOCKED,
        "button_b", PLUGIN_LABEL_LOCKED
    ]), NULL_KEY);
}

// Push the current toggle state to kmod_ui. Drives the rendered label via
// the buttonconfig registered above — no need to write a label string
// anywhere.
send_state_update() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.state.update",
        "context", PLUGIN_CONTEXT,
        "state",   Locked
    ]), NULL_KEY);
}

register_self() {
    // Write button visibility policy to LSD (only ACL 4 and 5 can toggle)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "4", "toggle",
        "5", "toggle"
    ]));

    // Self-declared menu presence for kmod_ui. The label here is just the
    // kmod_dialogs fallback used before buttonconfig lands (cold start) —
    // stable default, never rewritten on toggle.
    write_plugin_reg(PLUGIN_LABEL_UNLOCKED);

    // State-based label resolution.
    register_button_config();
    send_state_update();

    // Register with kernel (for ping/pong health tracking and alias table).
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL_UNLOCKED,
        "script", llGetScriptName()
    ]), NULL_KEY);

    // Declare chat alias.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "lock",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- SETTINGS CONSUMPTION -------------------- */

apply_settings_sync() {
    // Read lock state directly from LSD; compare with previous state
    // and trigger side effects only when the value actually changes.
    // If LSD key is missing/deleted, llLinksetDataRead returns "" which
    // casts to 0 (unlocked) — this naturally handles the delete case.
    integer prev_locked = Locked;
    Locked = lsd_int(KEY_LOCKED, FALSE);

    if (Locked != prev_locked) {
        apply_lock_state();
        play_toggle_sound();
        send_state_update();
    }
}

/* -------------------- SETTINGS MODIFICATION -------------------- */

persist_locked(integer new_value) {
    // Write to LSD immediately so state survives relog
    llLinksetDataWrite(KEY_LOCKED, (string)new_value);

    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
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
    send_state_update();

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)user
    ]), NULL_KEY);
}

/* -------------------- DIRECT STATE ACTIONS -------------------- */

// Set the lock to a specific state. No-op with notice if already there.
set_lock_state(key user, integer acl_level, integer target_locked) {
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("toggle")) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

    if (Locked == target_locked) {
        if (target_locked) llRegionSayTo(user, 0, "Collar already locked.");
        else llRegionSayTo(user, 0, "Collar already unlocked.");
        return;
    }

    Locked = target_locked;
    play_toggle_sound();
    apply_lock_state();
    persist_locked(Locked);

    if (Locked) llRegionSayTo(user, 0, "Collar locked.");
    else llRegionSayTo(user, 0, "Collar unlocked.");

    send_state_update();
}

// Execute a chat subcommand. Empty subpath handled by caller (toggle).
handle_subpath(key user, integer acl_level, string subpath) {
    if (subpath == "locked") {
        set_lock_state(user, acl_level, TRUE);
        return;
    }
    if (subpath == "unlocked") {
        set_lock_state(user, acl_level, FALSE);
        return;
    }
    llRegionSayTo(user, 0, "Unknown lock subcommand: " + subpath);
}

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
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        gPolicyButtons = [];
        // Restore from LSD immediately (survives relog)
        Locked = lsd_int(KEY_LOCKED, FALSE);
        apply_lock_state();
        register_self();
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

            if (msg_type == "kernel.register.refresh") {
                apply_settings_sync();
                register_self();
                return;
            }

            if (msg_type == "kernel.ping") {
                send_pong();
                return;
            }

            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
                llResetScript();
            }

            return;
        }

        /* -------------------- SETTINGS SYNC/DELTA -------------------- */if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                apply_settings_sync();
                return;
            }

            return;
        }

        /* -------------------- UI START (TOGGLE ACTION) -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                integer acl = (integer)llJsonGetValue(msg, ["acl"]);

                string subpath = "";
                string sp = llJsonGetValue(msg, ["subpath"]);
                if (sp != JSON_INVALID) subpath = sp;

                if (subpath != "") {
                    handle_subpath(id, acl, subpath);
                    return;
                }

                // Empty subpath: toggle (matches menu-click behavior).
                toggle_lock(id, acl);
                return;
            }

            return;
        }

    }
}
