/*--------------------
PLUGIN: plugin_public.lsl
VERSION: 1.10
REVISION: 7
PURPOSE: Toggle public access mode directly from main menu
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility,
  namespaced internal message protocol
CHANGES:
- v1.1 rev 7: "public on"/"public off" chat subpaths no longer emit
  ui.menu.return, which was popping up the root menu after a chat-only
  action. set_public_mode now uses send_label_update (label-only); the
  toggle path keeps the full menu-return for menu-click parity.
- v1.1 rev 6: Chat command support (Phase 3). Registers "public" alias.
  "<prefix> public" toggles (same as menu click); "public on" /
  "public off" set state idempotently. All routes share the same
  btn_allowed("toggle") ACL gate.
- v1.1 rev 5: Wire-type rename (Phase 2). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.reset→kernel.reset.soft,
  kernel.resetall→kernel.reset.factory.
- v1.1 rev 4: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.1 rev 3: Namespaced internal message types (kernel.register, settings.set, etc.).
- v1.1 rev 2: Honor soft_reset / soft_reset_all from KERNEL_LIFECYCLE.
  Without this, factory reset wiped LSD but left PublicModeEnabled cached
  in the script globals, so the menu kept showing "Public: Y" and the
  registered label never updated until the next manual toggle.
- v1.1 rev 1: Migrate settings reads from JSON broadcast payloads to direct
  llLinksetDataRead. Remove apply_settings_delta — apply_settings_sync now
  compares previous state and calls register_self() on change.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads via
  get_policy_buttons() and btn_allowed(). Removed PLUGIN_MIN_ACL and
  min_acl from kernel registration message.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.public";
string PLUGIN_LABEL_ON = "Public: Y";
string PLUGIN_LABEL_OFF = "Public: N";

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_PUBLIC_MODE = "public.mode";

/* -------------------- STATE -------------------- */
integer PublicModeEnabled = FALSE;
list gPolicyButtons = [];

/* -------------------- HELPERS -------------------- */


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

register_self() {
    string label = PLUGIN_LABEL_OFF;
    if (PublicModeEnabled) {
        label = PLUGIN_LABEL_ON;
    }

    // Write button visibility policy to LSD (default-deny per ACL level)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "3", "toggle",
        "4", "toggle",
        "5", "toggle"
    ]));

    // Register with kernel
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", label,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

    // Declare chat alias.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "public",
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
    integer old_state = PublicModeEnabled;

    string lsd_val = llLinksetDataRead(KEY_PUBLIC_MODE);
    if (lsd_val != "") {
        PublicModeEnabled = (integer)lsd_val;
    }

    if (old_state != PublicModeEnabled) {
        register_self();
    }
}

/* -------------------- SETTINGS MODIFICATION -------------------- */

persist_public_mode(integer new_value) {
    if (new_value != 0) new_value = 1;

    llLinksetDataWrite(KEY_PUBLIC_MODE, (string)new_value);

    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_PUBLIC_MODE,
        "value", (string)new_value
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

/* -------------------- UI LABEL UPDATE -------------------- */

send_label_update() {
    string new_label = PLUGIN_LABEL_OFF;
    if (PublicModeEnabled) {
        new_label = PLUGIN_LABEL_ON;
    }
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.label.update",
        "context", PLUGIN_CONTEXT,
        "label", new_label
    ]), NULL_KEY);
}

update_ui_label_and_return(key user) {
    send_label_update();

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)user
    ]), NULL_KEY);
}

/* -------------------- DIRECT STATE ACTIONS -------------------- */

// Set public mode to a specific state. No-op with notice if already there.
set_public_mode(key user, integer acl_level, integer target_enabled) {
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("toggle")) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

    if (PublicModeEnabled == target_enabled) {
        if (target_enabled) llRegionSayTo(user, 0, "Public access already enabled.");
        else llRegionSayTo(user, 0, "Public access already disabled.");
        return;
    }

    PublicModeEnabled = target_enabled;
    persist_public_mode(PublicModeEnabled);

    if (PublicModeEnabled) llRegionSayTo(user, 0, "Public access enabled.");
    else llRegionSayTo(user, 0, "Public access disabled.");

    send_label_update();
}

handle_subpath(key user, integer acl_level, string subpath) {
    if (subpath == "on") {
        set_public_mode(user, acl_level, TRUE);
        return;
    }
    if (subpath == "off") {
        set_public_mode(user, acl_level, FALSE);
        return;
    }
    llRegionSayTo(user, 0, "Unknown public subcommand: " + subpath);
}

toggle_public_access(key user, integer acl_level) {
    // Verify ACL via policy
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("toggle")) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

    // Toggle state
    PublicModeEnabled = !PublicModeEnabled;

    // Persist change
    persist_public_mode(PublicModeEnabled);

    // Notify user
    if (PublicModeEnabled) {
        llRegionSayTo(user, 0, "Public access enabled.");
    }
    else {
        llRegionSayTo(user, 0, "Public access disabled.");
    }

    // Update UI label and return to root menu
    update_ui_label_and_return(user);
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        gPolicyButtons = [];
        apply_settings_sync();
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
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) {
                        return;
                    }
                }
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

        /* -------------------- UI DIRECT TOGGLE -------------------- */if (num == UI_BUS) {
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
                toggle_public_access(id, acl);
                return;
            }

            return;
        }

    }
}
