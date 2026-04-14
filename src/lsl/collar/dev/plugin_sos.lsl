/*--------------------
PLUGIN: plugin_sos.lsl
VERSION: 1.10
REVISION: 2
PURPOSE: Emergency wearer-accessible actions when ACL is locked out
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 2: Namespace internal message type strings (kernel.*, ui.*, sos.*).
- v1.1 rev 1: Migrate dialog buttons to button_data format with context-based routing.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads.
  Button list built from get_policy_buttons() + btn_allowed().
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.sos.911";
string PLUGIN_LABEL = "SOS";

/* -------------------- STATE -------------------- */
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";

/* -------------------- HELPERS -------------------- */

// Helper: create a button_data entry with label and command context
string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
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

/* -------------------- PLUGIN REGISTRATION -------------------- */
register_self() {
    // Write button visibility policy to LSD (emergency access for ACL 0 only)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "0", "Unleash,Clear RLV,Clear Relay"
    ]));

    // Register with kernel
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- MENU DISPLAY -------------------- */
show_sos_menu() {
    SessionId = generate_session_id();

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    // llDialog displays buttons in rows of 3, bottom-left to top-right
    // Build button list from policy
    list button_data = [btn("Back", "back")];
    if (btn_allowed("Unleash")) button_data += [btn("Unleash", "unleash")];
    if (btn_allowed("Clear RLV")) button_data += [btn("Clear RLV", "clear_rlv")];
    if (btn_allowed("Clear Relay")) button_data += [btn("Clear Relay", "clear_relay")];

    string body = "EMERGENCY ACCESS\n\n";
    body += "Choose an action:\n";
    body += "• Unleash - Release leash\n";
    body += "• Clear RLV - Clear RLV restrictions\n";
    body += "• Clear Relay - Clear relay restrictions";

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "SOS Emergency",
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);

}

/* -------------------- EMERGENCY ACTIONS -------------------- */
action_unleash() {
    // Send emergency leash release on UI_BUS (bypasses ACL)
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "sos.leashrelease"
    ]), CurrentUser);

    llRegionSayTo(CurrentUser, 0, "[SOS] Leash released.");
}

action_clear_rlv() {
    // Send emergency restrict clear on UI_BUS (bypasses ACL)
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "sos.restrictclear"
    ]), CurrentUser);

    // Also send @clear directly to viewer as fallback
    llOwnerSay("@clear");

    llRegionSayTo(CurrentUser, 0, "[SOS] All RLV restrictions cleared.");
}

action_clear_relay() {
    // Send emergency relay clear on UI_BUS (bypasses ACL)
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "sos.relayclear"
    ]), CurrentUser);

    llRegionSayTo(CurrentUser, 0, "[SOS] All relay restrictions cleared.");
}

/* -------------------- BUTTON HANDLER -------------------- */
handle_button_click(string cmd) {

    if (cmd == "back") {
        return_to_root();
        return;
    }

    if (cmd == "unleash") {
        action_unleash();
        show_sos_menu();
        return;
    }

    if (cmd == "clear_rlv") {
        action_clear_rlv();
        show_sos_menu();
        return;
    }

    if (cmd == "clear_relay") {
        action_clear_relay();
        show_sos_menu();
        return;
    }
}

/* -------------------- NAVIGATION -------------------- */
return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)CurrentUser
    ]), NULL_KEY);

    cleanup_session();
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

/* -------------------- EVENT HANDLERS -------------------- */
default {
    state_entry() {
        cleanup_session();
        register_self();
    }

    on_rez(integer start_param) {
        // Preserve state on attach/detach
    }

    changed(integer change_mask) {
        if (change_mask & CHANGED_OWNER) {
            llResetScript();
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.registernow") {
                register_self();
                return;
            }

            if (msg_type == "kernel.ping") {
                send_pong();
                return;
            }

            if (msg_type == "kernel.reset" || msg_type == "kernel.resetall") {
                // Check if this is a targeted reset
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) {
                        return;  // Not for us, ignore
                    }
                }
                // Either no context (broadcast) or matches our context
                llResetScript();
            }

            return;
        }

        /* -------------------- UI START -------------------- */
        if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                CurrentUser = id;
                UserAcl = (integer)llJsonGetValue(msg, ["acl"]);

                show_sos_menu();
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSE -------------------- */
        if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;

                string response_session = llJsonGetValue(msg, ["session_id"]);
                if (response_session != SessionId) return;

                string cmd = llJsonGetValue(msg, ["context"]);
                if (cmd == JSON_INVALID) cmd = "";
                handle_button_click(cmd);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                if (timeout_session == JSON_INVALID) return;
                if (timeout_session != SessionId) return;
                cleanup_session();
                return;
            }

            return;
        }
    }
}
