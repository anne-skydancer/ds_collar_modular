/*--------------------
PLUGIN: plugin_status.lsl
VERSION: 1.10
REVISION: 5
PURPOSE: Read-only collar status display for owners and observers
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 5: Namespace internal message type strings (kernel.*, ui.*, settings.*).
- v1.1 rev 4: Honor soft_reset / soft_reset_all from KERNEL_LIFECYCLE so
  factory reset clears cached session state.
- v1.1 rev 3: Fix phantom owner/trustee count. llCSV2List("") returns
  [""] (a single empty entry), not []. Routed all CSV reads through a
  csv_read() helper that returns [] for empty raw values.
- v1.1 rev 2: Two-mode access model. Read primary owner from access.owner
  scalar (single mode) or access.owneruuids CSV (multi mode). Display
  names come pre-resolved from kmod_settings via access.ownername /
  access.ownernames / access.trusteenames — no async resolution here.
  Removed all llRequestDisplayName / dataserver name handling.
- v1.1 rev 1: Read all settings directly from LSD (authoritative runtime
  state) instead of kv_json broadcast. Removes settings_get roundtrip;
  apply_settings_sync is now parameterless. Fixes status dialog showing
  "Uncommitted" when bootstrap correctly displayed the registered owner.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads via
  get_policy_buttons() and btn_allowed(). Removed PLUGIN_MIN_ACL and
  min_acl from kernel registration message. View-only plugin with empty
  button lists — visible in root menu but no action buttons beyond Back.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_status";
string PLUGIN_LABEL = "Status";

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE  = "access.multiowner";
string KEY_OWNER             = "access.owner";
string KEY_OWNER_NAME        = "access.ownername";
string KEY_OWNER_HONORIFIC   = "access.ownerhonorific";
string KEY_OWNER_UUIDS       = "access.owneruuids";
string KEY_OWNER_NAMES       = "access.ownernames";
string KEY_OWNER_HONORIFICS  = "access.ownerhonorifics";
string KEY_TRUSTEE_UUIDS     = "access.trusteeuuids";
string KEY_TRUSTEE_NAMES     = "access.trusteenames";
string KEY_TRUSTEE_HONORIFICS = "access.trusteehonorifics";
string KEY_PUBLIC_ACCESS     = "public.mode";
string KEY_LOCKED            = "lock.locked";
string KEY_TPE_MODE          = "tpe.mode";

/* -------------------- STATE -------------------- */
// Session management
key CurrentUser = NULL_KEY;
list gPolicyButtons = [];
string SessionId = "";

/* -------------------- HELPERS -------------------- */

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

// llCSV2List("") returns [""] (length 1), not []. This wrapper returns a
// truly empty list when the LSD key is unset/empty.
list csv_read(string lsd_key) {
    string raw = llLinksetDataRead(lsd_key);
    if (raw == "") return [];
    return llCSV2List(raw);
}

/* -------------------- LSD POLICY HELPER -------------------- */
list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("acl.policycontext:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

register_self() {
    // Write button visibility policy to LSD (view-only, empty button lists for all ACL levels)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "",
        "2", "",
        "3", "",
        "4", "",
        "5", ""
    ]));

    // Register with kernel
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
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

/* -------------------- STATUS REPORT BUILDING -------------------- */

// Reads all data fresh from LSD on each call. No cache, no async name
// resolution — kmod_settings keeps names current in LSD.
string build_status_report() {
    string status_text = "Collar Status:\n\n";

    integer multi_mode = (integer)llLinksetDataRead(KEY_MULTI_OWNER_MODE);

    // Owner information
    if (multi_mode) {
        list uuids = csv_read(KEY_OWNER_UUIDS);
        list names = csv_read(KEY_OWNER_NAMES);
        list hons  = csv_read(KEY_OWNER_HONORIFICS);
        integer owner_count = llGetListLength(uuids);

        if (owner_count > 0) {
            status_text += "Owners:\n";
            integer i;
            for (i = 0; i < owner_count; i++) {
                string nm = "";
                if (i < llGetListLength(names)) nm = llList2String(names, i);
                string hn = "";
                if (i < llGetListLength(hons)) hn = llList2String(hons, i);
                if (hn != "") status_text += "  " + hn + " " + nm + "\n";
                else          status_text += "  " + nm + "\n";
            }
        }
        else {
            status_text += "Owners: Uncommitted\n";
        }
    }
    else {
        string owner_uuid = llLinksetDataRead(KEY_OWNER);
        if (owner_uuid != "") {
            string nm = llLinksetDataRead(KEY_OWNER_NAME);
            string hn = llLinksetDataRead(KEY_OWNER_HONORIFIC);
            if (hn != "") status_text += "Owner: " + hn + " " + nm + "\n";
            else          status_text += "Owner: " + nm + "\n";
        }
        else {
            status_text += "Owner: Uncommitted\n";
        }
    }

    // Trustee information
    list trustee_uuids = csv_read(KEY_TRUSTEE_UUIDS);
    list trustee_names = csv_read(KEY_TRUSTEE_NAMES);
    list trustee_hons  = csv_read(KEY_TRUSTEE_HONORIFICS);
    integer trustee_count = llGetListLength(trustee_uuids);

    if (trustee_count > 0) {
        status_text += "Trustees:\n";
        integer i;
        for (i = 0; i < trustee_count; i++) {
            string nm = "";
            if (i < llGetListLength(trustee_names)) nm = llList2String(trustee_names, i);
            string hn = "";
            if (i < llGetListLength(trustee_hons)) hn = llList2String(trustee_hons, i);
            if (hn != "") status_text += "  " + hn + " " + nm + "\n";
            else          status_text += "  " + nm + "\n";
        }
    }
    else {
        status_text += "Trustees: none\n";
    }

    // Public access
    if ((integer)llLinksetDataRead(KEY_PUBLIC_ACCESS)) status_text += "Public Access: On\n";
    else                                                status_text += "Public Access: Off\n";

    // Lock status
    if ((integer)llLinksetDataRead(KEY_LOCKED)) status_text += "Collar locked: Yes\n";
    else                                         status_text += "Collar locked: No\n";

    // TPE mode
    if ((integer)llLinksetDataRead(KEY_TPE_MODE)) status_text += "TPE Mode: On\n";
    else                                           status_text += "TPE Mode: Off\n";

    return status_text;
}

/* -------------------- UI / MENU SYSTEM -------------------- */

show_status_menu() {
    SessionId = generate_session_id();

    string status_report = build_status_report();

    list buttons = ["Back"];
    string buttons_json = llList2Json(JSON_ARRAY, buttons);

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "message", status_report,
        "buttons", buttons_json,
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string button) {
    if (button == "Back") {
        ui_return_root();
        cleanup_session();
        return;
    }

    // Unknown button - shouldn't happen
}

/* -------------------- UI NAVIGATION -------------------- */

ui_return_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- SESSION CLEANUP -------------------- */

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    gPolicyButtons = [];
    SessionId = "";
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        cleanup_session();
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
        if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "kernel.registernow") {
                register_self();
                return;
            }

            if (msg_type == "kernel.ping") {
                send_pong();
                return;
            }

            if (msg_type == "kernel.reset" || msg_type == "kernel.resetall") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                llResetScript();
            }

            return;
        }

        if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                CurrentUser = id;

                // Load policy buttons (will be empty for view-only plugin)
                integer user_acl = (integer)llJsonGetValue(msg, ["acl"]);
                gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, user_acl);

                show_status_menu();
                return;
            }

            return;
        }

        if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

                string button = llJsonGetValue(msg, ["button"]);
                if (button == JSON_INVALID) return;

                string user_str = llJsonGetValue(msg, ["user"]);
                if (user_str == JSON_INVALID) return;
                key user = (key)user_str;

                if (user != CurrentUser) return;

                handle_button_click(button);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

                cleanup_session();
                return;
            }

            return;
        }
    }
}
