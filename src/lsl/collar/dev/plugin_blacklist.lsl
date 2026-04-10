/*--------------------
PLUGIN: plugin_blacklist.lsl
VERSION: 1.10
REVISION: 5
PURPOSE: Blacklist management with sensor-based avatar selection
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 5: Namespace internal message type strings (kernel.*, settings.*,
  ui.*) for consistency with consolidated ABI naming conventions.
- v1.1 rev 4: Honor soft_reset / soft_reset_all from KERNEL_LIFECYCLE so
  factory reset clears cached blacklist state.
- v1.1 rev 3: Migrate to flat CSV blacklist storage. Use new blacklist_add /
  blacklist_remove API messages instead of generic list set/persist.
- v1.1 rev 2: Migrate dialog buttons to button_data format with context-based routing.
- v1.1 rev 1: Migrate settings reads from JSON broadcast payloads to direct
  llLinksetDataRead. Remove apply_settings_delta — full re-read on every sync.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL, ALLOWED_ACL_LEVELS, and in_allowed_levels()
  with policy reads. Button list built from get_policy_buttons() + btn_allowed().
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_blacklist";
string PLUGIN_LABEL = "Blacklist";

/* -------------------- CONSTANTS -------------------- */
integer MAX_NUMBERED_LIST_ITEMS = 11;  // 12 dialog buttons - 1 Back button

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
string KEY_BLACKLIST = "blacklist.blklistuuid";

/* -------------------- UI CONSTANTS -------------------- */
string BTN_BACK = "Back";
string BTN_ADD = "+Blacklist";
string BTN_REMOVE = "-Blacklist";
float BLACKLIST_RADIUS = 5.0;

/* -------------------- STATE -------------------- */
// Settings cache
list Blacklist = [];

// Session management
key CurrentUser = NULL_KEY;
integer CurrentUserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
string MenuContext = "";  // "main", "add_scan", "add_pick", "remove"

// Sensor results
list CandidateKeys = [];

/* -------------------- HELPERS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string generate_session_id() {
    return "blacklist_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
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

list blacklist_names() {
    list out = [];
    integer i = 0;
    integer count = llGetListLength(Blacklist);
    while (i < count) {
        key k = (key)llList2String(Blacklist, i);
        string nm = llGetDisplayName(k);
        if (nm == "") nm = (string)k;
        out += [nm];
        i += 1;
    }
    return out;
}

/* -------------------- LIFECYCLE -------------------- */

register_self() {
    // Write button visibility policy to LSD (Owned+ can manage blacklist)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "2", "+Blacklist,-Blacklist",
        "3", "+Blacklist,-Blacklist",
        "4", "+Blacklist,-Blacklist",
        "5", "+Blacklist,-Blacklist"
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
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- SETTINGS MANAGEMENT -------------------- */

apply_settings_sync() {
    string raw = llLinksetDataRead(KEY_BLACKLIST);
    if (raw == "") Blacklist = [];
    else           Blacklist = llCSV2List(raw);
}

send_blacklist_add(string uuid_str) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.blacklistadd",
        "uuid", uuid_str
    ]), NULL_KEY);
}

send_blacklist_remove(string uuid_str) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.blacklistremove",
        "uuid", uuid_str
    ]), NULL_KEY);
}

/* -------------------- MENU DISPLAY -------------------- */

show_main_menu() {
    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, CurrentUserAcl);

    integer count = llGetListLength(Blacklist);
    string body = "Blacklist Management\n\n";
    body += "Currently blacklisted: " + (string)count;

    list button_data = [btn(BTN_BACK, "back")];
    if (btn_allowed("+Blacklist")) button_data += [btn(BTN_ADD, "add")];
    if (btn_allowed("-Blacklist")) button_data += [btn(BTN_REMOVE, "remove")];

    SessionId = generate_session_id();
    MenuContext = "main";

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Blacklist",
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

show_remove_menu() {
    if (llGetListLength(Blacklist) == 0) {
        llRegionSayTo(CurrentUser, 0, "Blacklist is empty.");
        show_main_menu();
        return;
    }

    list names = blacklist_names();

    SessionId = generate_session_id();
    MenuContext = "remove";

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Remove from Blacklist",
        "prompt", "Select avatar to remove:",
        "items", llList2Json(JSON_ARRAY, names),
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

show_add_candidates() {
    if (llGetListLength(CandidateKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        show_main_menu();
        return;
    }

    // Build list of names
    list names = [];
    integer i = 0;
    while (i < llGetListLength(CandidateKeys) && i < MAX_NUMBERED_LIST_ITEMS) {
        key k = (key)llList2String(CandidateKeys, i);
        string name = llGetDisplayName(k);
        if (name == "") name = (string)k;
        names += [name];
        i += 1;
    }

    SessionId = generate_session_id();
    MenuContext = "add_pick";

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Add to Blacklist",
        "prompt", "Select avatar to blacklist:",
        "items", llList2Json(JSON_ARRAY, names),
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- NAVIGATION -------------------- */

return_to_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
    cleanup_session();
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
    CurrentUserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    MenuContext = "";
    CandidateKeys = [];
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;

    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;

    string cmd = llJsonGetValue(msg, ["context"]);
    if (cmd == JSON_INVALID) cmd = llJsonGetValue(msg, ["button"]);

    // Handle Back button (context-routed or numbered_list Back)
    if (cmd == "back" || cmd == BTN_BACK) {
        if (MenuContext == "main") {
            return_to_root();
            return;
        }
        show_main_menu();
        return;
    }

    // Main menu actions
    if (MenuContext == "main") {
        if (cmd == "add") {
            MenuContext = "add_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, BLACKLIST_RADIUS, PI);
            return;
        }
        if (cmd == "remove") {
            show_remove_menu();
            return;
        }
    }

    // Remove menu - numbered selection
    if (MenuContext == "remove") {
        integer idx = (integer)cmd - 1;
        if (idx >= 0 && idx < llGetListLength(Blacklist)) {
            send_blacklist_remove(llList2String(Blacklist, idx));
            llRegionSayTo(CurrentUser, 0, "Removed from blacklist.");
        }
        show_main_menu();
        return;
    }

    // Add pick menu - numbered selection
    if (MenuContext == "add_pick") {
        integer idx = (integer)cmd - 1;
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            string entry = llList2String(CandidateKeys, idx);
            if (entry != "") {
                send_blacklist_add(entry);
                llRegionSayTo(CurrentUser, 0, "Added to blacklist.");
            }
        }
        show_main_menu();
        return;
    }

    // Unknown context - return to main
    show_main_menu();
}

handle_dialog_timeout(string msg) {
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session == JSON_INVALID) return;
    if (session != SessionId) return;
    cleanup_session();
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        cleanup_session();
        register_self();
        apply_settings_sync();
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
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                llResetScript();
            }

            return;
        }

        /* -------------------- SETTINGS BUS -------------------- */
        if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                apply_settings_sync();
                return;
            }

            return;
        }

        /* -------------------- UI START -------------------- */
        if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                // User wants to start this plugin
                CurrentUser = id;
                CurrentUserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                show_main_menu();
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSES -------------------- */
        if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
                return;
            }

            return;
        }
    }

    sensor(integer count) {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;

        list candidates = [];
        key owner = llGetOwner();
        integer i = 0;

        while (i < count) {
            key k = llDetectedKey(i);
            string entry = (string)k;

            if (k != owner && llListFindList(Blacklist, [entry]) == -1) {
                candidates += [entry];
            }
            i += 1;
        }

        CandidateKeys = candidates;
        show_add_candidates();
    }

    no_sensor() {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;

        CandidateKeys = [];
        show_add_candidates();
    }
}
