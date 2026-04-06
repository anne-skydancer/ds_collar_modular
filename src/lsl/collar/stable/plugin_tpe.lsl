/*--------------------
PLUGIN: plugin_tpe.lsl
VERSION: 1.10
REVISION: 1
PURPOSE: Manage TPE mode with wearer confirmation and owner oversight
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 1: Migrate from JSON broadcast payloads to direct LSD reads.
  Remove apply_settings_delta() and request_settings_sync(). apply_settings_sync()
  is now parameterless and reads all keys from LSD. Both settings_sync and
  settings_delta call apply_settings_sync() in link_message.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads via
  get_policy_buttons() and btn_allowed(). Removed PLUGIN_MIN_ACL and
  min_acl from kernel registration message.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_tpe";
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

string gen_session() {
    return (string)llGetKey() + "_" + (string)llGetUnixTime();
}

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "dialog_close",
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
        "type", "close",
        "context", PLUGIN_CONTEXT,
        "user", (string)user
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, user);
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

/* -------------------- KERNEL MESSAGES -------------------- */

register_with_kernel() {
    // Write button visibility policy to LSD (only primary owner ACL 5 gets toggle)
    llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "5", "toggle"
    ]));

    // Register with kernel
    string initial_label = PLUGIN_LABEL_OFF;
    if (TpeModeEnabled) {
        initial_label = PLUGIN_LABEL_ON;
    }

    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", initial_label,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
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
        "type", "set",
        "key", KEY_TPE_MODE,
        "value", (string)new_value
    ]), NULL_KEY);
}

/* -------------------- UI LABEL UPDATE -------------------- */

update_ui_label() {
    string new_label = PLUGIN_LABEL_OFF;
    if (TpeModeEnabled) {
        new_label = PLUGIN_LABEL_ON;
    }

    string msg = llList2Json(JSON_OBJECT, [
        "type", "update_label",
        "context", PLUGIN_CONTEXT,
        "label", new_label
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string button) {
    if (button == "Yes") {
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
                "type", "return",
                "user", (string)CurrentUser
            ]);
            llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
        }

        cleanup_session();
    }
    else if (button == "No") {
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
                "type", "return",
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
            "type", "return",
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

        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "dialog_open",
            "session_id", SessionId,
            "user", (string)llGetOwner(),  // Send to WEARER, not CurrentUser
            "title", "TPE Confirmation",
            "body", msg_body,
            "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
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
        update_ui_label();
    }
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
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

            if (msg_type == "register_now") {
                register_with_kernel();
            }
            else if (msg_type == "ping") {
                send_pong();
            }
            else if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                // Check if this is a targeted reset
                string target_context = llJsonGetValue(str, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) {
                        return; // Not for us, ignore
                    }
                }
                // Either no context (broadcast) or matches our context
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "settings_sync" || msg_type == "settings_delta") {
                apply_settings_sync();
            }
        }
        else if (num == UI_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "start") {
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

            if (msg_type == "dialog_response") {
                string session_id = llJsonGetValue(str, ["session_id"]);
                if (session_id != SessionId) return;

                string button = llJsonGetValue(str, ["button"]);

                handle_button_click(button);
            }
            else if (msg_type == "dialog_timeout") {
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
                        "type", "return",
                        "user", (string)CurrentUser
                    ]);
                    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
                }

                cleanup_session();
            }
        }
    }
}
