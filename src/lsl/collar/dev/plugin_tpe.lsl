/*--------------------
PLUGIN: plugin_tpe.lsl
VERSION: 1.10
REVISION: 10
PURPOSE: Manage TPE mode with wearer confirmation and owner oversight
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility,
  namespaced internal message protocol
CHANGES:
- v1.1 rev 10: Toggle state now written to plugin.state.<ctx> in LSD
  (via idempotent write_plugin_state helper) instead of pushed via
  ui.state.update link_message. kmod_ui rev 17 reads plugin.state.<ctx>
  live at render time, so the state-cache hop is gone. Reset handler
  now also deletes plugin.state.<ctx> alongside the other LSD cleanup.
- v1.1 rev 9: write_plugin_reg guards idempotent writes (read-before-
  write). Same-value re-registrations on state_entry and
  kernel.register.refresh no longer fire linkset_data, so kmod_ui's
  debounced rebuild + session invalidation stops triggering on
  register.refresh cascades — wearer's open menu survives the event.
- v1.1 rev 8: Switch to state-based label resolution. register_with_kernel
  now registers a buttonconfig for the TPE:Y / TPE:N pair via kmod_dialogs
  and emits ui.state.update with the current state. Toggle paths
  (handle_tpe_click, handle_button_click, apply_settings_sync) send
  ui.state.update; plugin.reg.<ctx> is written once at registration and
  never rewritten on toggle. Removes the LSD write + linkset_data fire +
  debounce + rebuild that used to happen on every TPE flip.
- v1.1 rev 7: Add dormancy guard in state_entry — script parks itself
  if the prim's object description is "COLLAR_UPDATER" so it stays dormant
  when staged in an updater installer prim.
- v1.1 rev 6: Self-declare menu presence via LSD (plugin.reg.<ctx>).
  Label updates write the same LSD key directly; ui.label.update link_messages
  are gone. Reset handlers delete plugin.reg.<ctx> and acl.policycontext:<ctx>
  before llResetScript so kmod_ui drops the button immediately.
- v1.1 rev 5: Wire-type rename (Phase 2). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.reset→kernel.reset.soft,
  kernel.resetall→kernel.reset.factory.
- v1.1 rev 4: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.1 rev 3: Namespaced internal message types (kernel.register, ui.dialog.open, etc.).
- v1.1 rev 2: Migrate dialog buttons to button_data format with context-based routing.
- v1.1 rev 1: Migrate from JSON broadcast payloads to direct LSD reads.
  Remove apply_settings_delta() and request_settings_sync(). apply_settings_sync()
  is now parameterless and reads all keys from LSD. Both settings_sync and
  settings_delta call apply_settings_sync() in link_message.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads via
  get_policy_buttons() and btn_allowed(). Removed PLUGIN_MIN_ACL and
  min_acl from kernel registration message.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.tpe";
string PLUGIN_LABEL_ON = "TPE: Y";
string PLUGIN_LABEL_OFF = "TPE: N";

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access (wearer in TPE mode)
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner (ONLY ACL that can manage TPE)
*/

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_TPE_MODE = "tpe.mode";

/* -------------------- STATE -------------------- */
integer TpeModeEnabled = FALSE;

// Session management for confirmation dialog
key CurrentUser = NULL_KEY;        // Who initiated the action
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
key WearerKey = NULL_KEY;          // Owner of the collar (for confirmation)

/* -------------------- HELPERS -------------------- */

// Helper: create a button_data entry with label and command context
string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string gen_session() {
    return (string)llGetKey() + "_" + (string)llGetUnixTime();
}

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
}

close_ui_for_user(key user) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.close",
        "context", PLUGIN_CONTEXT,
        "user", (string)user
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, user);
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

/* -------------------- KERNEL MESSAGES -------------------- */

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
//   state == 0 → PLUGIN_LABEL_OFF
//   state != 0 → PLUGIN_LABEL_ON
register_button_config() {
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",     "ui.dialog.buttonconfig.register",
        "context",  PLUGIN_CONTEXT,
        "button_a", PLUGIN_LABEL_OFF,
        "button_b", PLUGIN_LABEL_ON
    ]), NULL_KEY);
}

// Write the current toggle state to LSD at plugin.tpe.state. kmod_dialogs
// reads this at render time (via buttonconfig) to pick the right label.
// Key convention: "plugin.<short>.state" where <short> is the trailing
// dotted segment of the plugin context. Idempotent read-before-write
// skips the linkset_data event when the stored value already matches.
send_state_update() {
    string k = "plugin.tpe.state";
    string v = (string)TpeModeEnabled;
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_with_kernel() {
    // Write button visibility policy to LSD (only primary owner ACL 5 gets toggle)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "5", "toggle"
    ]));

    // Self-declared menu presence for kmod_ui. The label here is the
    // kmod_dialogs fallback used before buttonconfig lands — stable
    // default, never rewritten on toggle.
    write_plugin_reg(PLUGIN_LABEL_OFF);

    // State-based label resolution.
    register_button_config();
    send_state_update();

    // Register with kernel (for ping/pong health tracking and alias table).
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL_OFF,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- SETTINGS MANAGEMENT -------------------- */

persist_tpe_mode(integer new_value) {
    if (new_value != 0) new_value = 1;

    // Write to LSD so state survives relog
    llLinksetDataWrite(KEY_TPE_MODE, (string)new_value);

    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_TPE_MODE,
        "value", (string)new_value
    ]), NULL_KEY);
}

/* -------------------- UI LABEL UPDATE -------------------- */

// Forwarder kept under the old name so existing callers keep working; the
// underlying path now pushes state (not a label) and lets kmod_dialogs
// resolve the final button text via its registered buttonconfig.
update_ui_label() {
    send_state_update();
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string cmd) {
    if (cmd == "confirm") {
        // Wearer confirmed - enable TPE
        TpeModeEnabled = TRUE;
        persist_tpe_mode(TRUE);

        llRegionSayTo(WearerKey, 0, "TPE mode enabled. You have relinquished collar control.");
        if (CurrentUser != WearerKey) {
            llRegionSayTo(CurrentUser, 0, "TPE mode enabled with wearer consent.");
        }

        // Update UI label
        update_ui_label();

        // Close UI for wearer (who clicked the dialog)
        close_ui_for_user(WearerKey);

        // Return owner to root menu to see updated button (if different from wearer)
        if (CurrentUser != WearerKey) {
            string msg = llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return",
                "user", (string)CurrentUser
            ]);
            llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
        }

        cleanup_session();
    }
    else if (cmd == "cancel") {
        // Wearer declined - cancel TPE activation
        llRegionSayTo(WearerKey, 0, "TPE activation cancelled.");
        if (CurrentUser != WearerKey) {
            llRegionSayTo(CurrentUser, 0, "Wearer declined TPE activation.");
        }

        // Close UI for wearer (who clicked the dialog)
        close_ui_for_user(WearerKey);

        // Return owner to root menu (if different from wearer)
        if (CurrentUser != WearerKey) {
            string msg = llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return",
                "user", (string)CurrentUser
            ]);
            llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
        }

        cleanup_session();
    }
}

/* -------------------- TPE TOGGLE LOGIC -------------------- */

handle_tpe_click(key user, integer acl_level) {
    // Load policy buttons and verify toggle is allowed for this ACL
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("toggle")) {
        llRegionSayTo(user, 0, "Access denied. Only primary owner can manage TPE mode.");
        cleanup_session();
        return;
    }

    CurrentUser = user;
    UserAcl = acl_level;
    WearerKey = llGetOwner();

    if (TpeModeEnabled) {
        // TPE is currently ON - disable it directly (no confirmation needed)
        // This allows owner to release TPE without wearer consent
        TpeModeEnabled = FALSE;
        persist_tpe_mode(FALSE);

        llRegionSayTo(user, 0, "TPE mode disabled. Wearer regains collar access.");
        // Notify wearer their access has been restored
        if (user != WearerKey) {
            llRegionSayTo(WearerKey, 0, "Your collar access has been restored.");
        }

        // Update UI label
        update_ui_label();

        // Return owner to root menu (so they see the updated button)
        string msg = llList2Json(JSON_OBJECT, [
            "type", "ui.menu.return",
            "user", (string)user
        ]);
        llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);

        cleanup_session();
    }
    else {
        // TPE is currently OFF - requires wearer consent
        // Send dialog to WEARER, not CurrentUser

        string msg_body = "Your owner wants to enable TPE mode.\n\n";
        msg_body += "By clicking Yes, you relinquish all control of this collar.\n\n";
        msg_body += "You will not be able to access the collar menu while TPE is active.\n\n";
        msg_body += "Do you consent?";

        SessionId = gen_session();

        list button_data = [
            btn("Yes", "confirm"),
            btn("No", "cancel")
        ];

        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.open",
            "session_id", SessionId,
            "user", (string)llGetOwner(),  // Send to WEARER, not CurrentUser
            "title", "TPE Confirmation",
            "body", msg_body,
            "button_data", llList2Json(JSON_ARRAY, button_data),
            "timeout", 60
        ]), NULL_KEY);

    }
}

/* -------------------- SETTINGS CONSUMPTION -------------------- */

apply_settings_sync() {
    integer prev = TpeModeEnabled;
    string lsd_val = llLinksetDataRead(KEY_TPE_MODE);
    if (lsd_val != "") {
        TpeModeEnabled = (integer)lsd_val;
    }

    // If TPE mode changed, persist to LSD (covers delta-driven updates)
    if (TpeModeEnabled != prev) {
        llLinksetDataWrite(KEY_TPE_MODE, (string)TpeModeEnabled);
        send_state_update();
    }
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        WearerKey = llGetOwner();
        cleanup_session();
        apply_settings_sync();
        register_with_kernel();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    link_message(integer sender_num, integer num, string str, key id) {
        // Skip logging kernel lifecycle messages (too noisy)
        // if (num != KERNEL_LIFECYCLE) {
        // }

        if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "kernel.register.refresh") {
                register_with_kernel();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                // Check if this is a targeted reset
                string target_context = llJsonGetValue(str, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) {
                        return; // Not for us, ignore
                    }
                }
                // Either no context (broadcast) or matches our context
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("plugin.tpe.state");
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                apply_settings_sync();
            }
        }
        else if (num == UI_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(str, ["acl"]) == JSON_INVALID) return;
                string context = llJsonGetValue(str, ["context"]);
                if (context != PLUGIN_CONTEXT) return;

                // User key is passed as the id parameter to link_message, not in JSON
                CurrentUser = id;

                // ACL level provided by UI module
                UserAcl = (integer)llJsonGetValue(str, ["acl"]);

                // Handle click - may show confirmation dialog or toggle directly
                handle_tpe_click(CurrentUser, UserAcl);
            }
        }
        else if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "ui.dialog.response") {
                string session_id = llJsonGetValue(str, ["session_id"]);
                if (session_id != SessionId) return;

                string cmd = llJsonGetValue(str, ["context"]);
                if (cmd == JSON_INVALID) cmd = "";

                handle_button_click(cmd);
            }
            else if (msg_type == "ui.dialog.timeout") {
                string session_id = llJsonGetValue(str, ["session_id"]);
                if (session_id != SessionId) return;
                llRegionSayTo(WearerKey, 0, "TPE confirmation timed out.");
                if (CurrentUser != WearerKey) {
                    llRegionSayTo(CurrentUser, 0, "TPE confirmation timed out.");
                }

                // Close UI for wearer
                close_ui_for_user(WearerKey);

                // Return owner to root menu (if different from wearer)
                if (CurrentUser != WearerKey) {
                    string msg = llList2Json(JSON_OBJECT, [
                        "type", "ui.menu.return",
                        "user", (string)CurrentUser
                    ]);
                    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
                }

                cleanup_session();
            }
        }
    }
}
