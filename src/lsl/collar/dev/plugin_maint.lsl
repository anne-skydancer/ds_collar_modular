/*--------------------
PLUGIN: plugin_maint.lsl
VERSION: 1.10
REVISION: 7
PURPOSE: Maintenance and utility functions for collar management
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 7: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.1 rev 6: Switch Clear Leash to force_release and add confirmation dialog.
  force_release is authorized by wearer identity or ACL >= 3, bypassing the
  leasher-identity check so it works on bad-actor leashes. Confirmation
  dialog prevents accidental or malicious triggers.
- v1.1 rev 5: Namespace internal message type strings (kernel.*, ui.*, etc.)
- v1.1 rev 4: Fix phantom owner/trustee/blacklist count in View Settings
  and Access List. llCSV2List("") returns [""] (a single empty entry),
  not []. Routed all CSV reads through a csv_read() helper.
- v1.1 rev 3: Two-mode access model. View Settings and Access List read
  primary owner from access.owner scalar (single mode) or access.owneruuids
  CSV (multi mode). Names come pre-resolved from kmod_settings.
- v1.1 rev 2: Add Factory Reset (wearer-only, confirmation required).
  Wipes all LSD data and resets all scripts to defaults.
- v1.1 rev 1: Migrate from JSON broadcast payloads to direct LSD reads.
  Remove CachedSettings/SettingsReady; do_view_settings() and
  do_display_access_list() now read individual keys from LSD on demand.
  Remove apply_settings_sync()/apply_settings_delta() and settings_get request.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded ALLOWED_ACL_FULL list with policy reads via
  get_policy_buttons() and btn_allowed(). Removed PLUGIN_MIN_ACL and
  min_acl from kernel registration message.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.maintenance";
string PLUGIN_LABEL = "Maintenance";

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* -------------------- INVENTORY ITEMS -------------------- */
string HUD_ITEM = "D/s Collar control HUD";
string MANUAL_NOTECARD = "D/s Collar User Manual";

/* -------------------- STATE -------------------- */
key CurrentUser = NULL_KEY;
integer CurrentUserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
string MenuContext = "main";

/* -------------------- HELPERS -------------------- */

string generate_session_id() {
    return "maint_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
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

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

/* -------------------- LIFECYCLE -------------------- */

register_self() {
    // Write button visibility policy to LSD (default-deny per ACL level)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Get HUD,User Manual",
        "2", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual,Factory Reset",
        "3", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        "4", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual,Factory Reset",
        "5", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual"
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

/* -------------------- MENU DISPLAY -------------------- */

// Helper: create a button_data entry with label and command context
string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

show_main_menu() {
    MenuContext = "main";
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, CurrentUserAcl);

    string body = "Maintenance:\n\n";
    list button_data = [btn("Back", "back")];

    if (btn_allowed("View Settings"))    button_data += [btn("View Settings", "view_settings")];
    if (btn_allowed("Reload Settings"))  button_data += [btn("Reload Settings", "reload_settings")];
    if (btn_allowed("Access List"))      button_data += [btn("Access List", "access_list")];
    if (btn_allowed("Reload Collar"))    button_data += [btn("Reload Collar", "reload_collar")];
    if (btn_allowed("Clear Leash"))      button_data += [btn("Clear Leash", "clear_leash")];
    if (btn_allowed("Get HUD"))          button_data += [btn("Get HUD", "get_hud")];
    if (btn_allowed("User Manual"))      button_data += [btn("User Manual", "user_manual")];
    if (btn_allowed("Factory Reset"))    button_data += [btn("Factory Reset", "factory_reset")];

    if (btn_allowed("View Settings")) {
        body += "System utilities and documentation.";
    }
    else {
        body += "Get HUD or user manual.";
    }

    SessionId = generate_session_id();

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Maintenance",
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);
}

/* -------------------- ACTIONS -------------------- */

// Format a boolean as ON/OFF; unset defaults to OFF (matches runtime behaviour)
string fmt_bool(string raw) {
    if ((integer)raw) return "ON";
    return "OFF";
}

// Format relay.mode integer as label
string fmt_relay_mode(string raw) {
    integer m = (integer)raw;
    if (m == 1) return "ON";
    if (m == 2) return "ASK";
    return "OFF";
}

// Format parallel CSV lists (uuids, names, honorifics) into one block.
// Returns the formatted block, or fallback_str if uuids is empty.
string fmt_csv_person_lines(string uuids_csv, string names_csv, string hons_csv, string fallback_str) {
    // Guard: llCSV2List("") returns [""] (length 1), not [].
    if (uuids_csv == "") return fallback_str;
    list uuids = llCSV2List(uuids_csv);
    list names = llCSV2List(names_csv);
    list hons  = llCSV2List(hons_csv);
    integer count = llGetListLength(uuids);
    if (count == 0) return fallback_str;

    string block = "";
    integer i = 0;
    while (i < count) {
        string p_uuid = llList2String(uuids, i);
        string p_name = "";
        if (i < llGetListLength(names)) p_name = llList2String(names, i);
        string p_hon = "";
        if (i < llGetListLength(hons)) p_hon = llList2String(hons, i);
        if (p_hon != "") block += "  " + p_hon + " " + p_name + " (" + p_uuid + ")\n";
        else             block += "  " + p_name + " (" + p_uuid + ")\n";
        i += 1;
    }
    return block;
}

do_view_settings() {
    integer multi = (integer)llLinksetDataRead("access.multiowner");

    string locked = llLinksetDataRead("lock.locked");
    string lock_str;
    if ((integer)locked) lock_str = "LOCKED";
    else                 lock_str = "UNLOCKED";

    string restr_csv = llLinksetDataRead("restrict.list");
    string restr_str;
    if (restr_csv != "") {
        list restr_list = llParseString2List(restr_csv, [","], []);
        restr_str = (string)llGetListLength(restr_list) + " active";
    }
    else {
        restr_str = "none";
    }

    string output = "\n=== Collar Settings ===\n";

    // --- Owner(s) ---
    if (multi) {
        string owner_block = fmt_csv_person_lines(
            llLinksetDataRead("access.owneruuids"),
            llLinksetDataRead("access.ownernames"),
            llLinksetDataRead("access.ownerhonorifics"),
            "");
        if (owner_block == "") {
            output += "Owners: Uncommitted\n";
        }
        else {
            output += "Owners:\n" + owner_block;
        }
    }
    else {
        string owner_uuid = llLinksetDataRead("access.owner");
        if (owner_uuid != "") {
            string p_name = llLinksetDataRead("access.ownername");
            string p_hon  = llLinksetDataRead("access.ownerhonorific");
            if (p_hon != "") output += "Owner: " + p_hon + " " + p_name + " (" + owner_uuid + ")\n";
            else             output += "Owner: " + p_name + " (" + owner_uuid + ")\n";
        }
        else {
            output += "Owner: Uncommitted\n";
        }
    }

    // --- Trustees ---
    string trustee_block = fmt_csv_person_lines(
        llLinksetDataRead("access.trusteeuuids"),
        llLinksetDataRead("access.trusteenames"),
        llLinksetDataRead("access.trusteehonorifics"),
        "");
    if (trustee_block == "") {
        output += "Trustees: none\n";
    }
    else {
        output += "Trustees:\n" + trustee_block;
    }

    // --- Behavioural settings ---
    output += "Access: multi-owner " + fmt_bool(llLinksetDataRead("access.multiowner"));
    output += " | runaway " + fmt_bool(llLinksetDataRead("access.enablerunaway")) + "\n";
    output += "Lock: " + lock_str;
    output += " | public " + fmt_bool(llLinksetDataRead("public.mode"));
    output += " | TPE " + fmt_bool(llLinksetDataRead("tpe.mode")) + "\n";
    output += "Relay: " + fmt_relay_mode(llLinksetDataRead("relay.mode"));
    output += " | hardcore " + fmt_bool(llLinksetDataRead("relay.hardcoremode")) + "\n";
    output += "Owner TP/IM: " + fmt_bool(llLinksetDataRead("rlvex.ownertp"));
    output += "/" + fmt_bool(llLinksetDataRead("rlvex.ownerim")) + "\n";
    output += "Trustee TP/IM: " + fmt_bool(llLinksetDataRead("rlvex.trusteetp"));
    output += "/" + fmt_bool(llLinksetDataRead("rlvex.trusteeim")) + "\n";
    output += "Restrictions: " + restr_str;

    llRegionSayTo(CurrentUser, 0, output);
}

do_display_access_list() {
    string output = "=== Access Control List ===\n\n";

    integer multi_mode = (integer)llLinksetDataRead("access.multiowner");

    // Owner(s)
    if (multi_mode) {
        output += "OWNERS:\n";
        list uuids = csv_read("access.owneruuids");
        list names = csv_read("access.ownernames");
        list hons  = csv_read("access.ownerhonorifics");
        integer count = llGetListLength(uuids);
        if (count > 0) {
            integer i;
            for (i = 0; i < count; i++) {
                string nm = "";
                if (i < llGetListLength(names)) nm = llList2String(names, i);
                string hn = "Owner";
                if (i < llGetListLength(hons) && llList2String(hons, i) != "") {
                    hn = llList2String(hons, i);
                }
                output += "  " + hn + " " + nm + " - " + llList2String(uuids, i) + "\n";
            }
        }
        else {
            output += "  (none)\n";
        }
    }
    else {
        output += "OWNER:\n";
        string owner_uuid = llLinksetDataRead("access.owner");
        if (owner_uuid != "") {
            string nm  = llLinksetDataRead("access.ownername");
            string hn  = llLinksetDataRead("access.ownerhonorific");
            if (hn == "") hn = "Owner";
            output += "  " + hn + " " + nm + " - " + owner_uuid + "\n";
        }
        else {
            output += "  (none)\n";
        }
    }

    // Trustees
    output += "\nTRUSTEES:\n";
    list t_uuids = csv_read("access.trusteeuuids");
    list t_names = csv_read("access.trusteenames");
    list t_hons  = csv_read("access.trusteehonorifics");
    integer t_count = llGetListLength(t_uuids);
    if (t_count > 0) {
        integer i;
        for (i = 0; i < t_count; i++) {
            string nm = "";
            if (i < llGetListLength(t_names)) nm = llList2String(t_names, i);
            string hn = "Trustee";
            if (i < llGetListLength(t_hons) && llList2String(t_hons, i) != "") {
                hn = llList2String(t_hons, i);
            }
            output += "  " + hn + " " + nm + " - " + llList2String(t_uuids, i) + "\n";
        }
    }
    else {
        output += "  (none)\n";
    }

    // Blacklist (CSV of UUIDs)
    output += "\nBLACKLISTED:\n";
    list blacklist = csv_read("blacklist.blklistuuid");
    if (llGetListLength(blacklist) > 0) {
        integer i;
        for (i = 0; i < llGetListLength(blacklist); i++) {
            output += "  " + llList2String(blacklist, i) + "\n";
        }
    }
    else {
        output += "  (none)\n";
    }

    llRegionSayTo(CurrentUser, 0, output);
}

show_factory_reset_confirm() {
    MenuContext = "factory_reset";
    SessionId = generate_session_id();

    list button_data = [
        btn("No", "cancel"),
        btn("Yes", "confirm")
    ];

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Factory Reset",
        "body", "This will ERASE ALL settings and return the collar to factory defaults.\n\nOwnership, trustees, lock state, and all other configuration will be lost.\n\nAre you sure?",
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 30
    ]), NULL_KEY);
}

do_factory_reset() {
    llRegionSayTo(CurrentUser, 0, "Factory reset in progress...");
    cleanup_session();

    // Wipe all LSD data
    llLinksetDataReset();

    // Reset all scripts in the linkset
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.resetall",
        "from", "factory_reset"
    ]), NULL_KEY);

    llResetScript();
}

do_reload_settings() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings.get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Settings reload requested.");
}

show_clear_leash_confirm() {
    MenuContext = "clear_leash";
    SessionId = generate_session_id();

    list button_data = [
        btn("No", "cancel"),
        btn("Yes", "confirm")
    ];

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Clear Leash",
        "body", "Force-release the current leash?\n\nThis bypasses normal permission checks and clears any leash, including one held by a bad actor.\n\nAre you sure?",
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 30
    ]), NULL_KEY);
}

do_clear_leash() {
    // Use force_release rather than the normal release action.
    // release requires the user to be the active leasher or hold Unclip
    // policy; force_release is authorized by wearer identity or ACL >= 3,
    // allowing an owned wearer (ACL 2) to escape a bad-actor leash and
    // clearing stray leash particles in all cases.
    string msg = llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", "force_release"
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, CurrentUser);

    llRegionSayTo(CurrentUser, 0, "Leash cleared.");
}

do_reload_collar() {
    // Broadcast soft reset to all plugins
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.reset",
        "from", "maintenance"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Collar reload initiated.");
}

do_give_hud() {
    if (llGetInventoryType(HUD_ITEM) != INVENTORY_OBJECT) {
        llRegionSayTo(CurrentUser, 0, "HUD not found in inventory.");
    }
    else {
        llGiveInventory(CurrentUser, HUD_ITEM);
        llRegionSayTo(CurrentUser, 0, "HUD sent.");
    }
}

do_give_manual() {
    if (llGetInventoryType(MANUAL_NOTECARD) != INVENTORY_NOTECARD) {
        llRegionSayTo(CurrentUser, 0, "Manual not found in inventory.");
    }
    else {
        llGiveInventory(CurrentUser, MANUAL_NOTECARD);
        llRegionSayTo(CurrentUser, 0, "Manual sent.");
    }
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
    // Close the dialog session in the dialog manager
    if (SessionId != "") {
        string msg = llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]);
        llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
    }

    CurrentUser = NULL_KEY;
    CurrentUserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    MenuContext = "main";
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;

    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;

    string cmd = llJsonGetValue(msg, ["context"]);
    if (cmd == JSON_INVALID) cmd = "";

    // Navigation
    if (cmd == "back") {
        if (MenuContext != "main") {
            show_main_menu();
        }
        else {
            return_to_root();
        }
        return;
    }

    // Confirmation dialogs — route by menu context
    if (MenuContext == "factory_reset") {
        if (cmd == "confirm") {
            do_factory_reset();
            return;
        }
        show_main_menu();
        return;
    }

    if (MenuContext == "clear_leash") {
        if (cmd == "confirm") {
            do_clear_leash();
            return;
        }
        show_main_menu();
        return;
    }

    // Main menu commands
    if (cmd == "view_settings") {
        do_view_settings();
        show_main_menu();
        return;
    }
    if (cmd == "access_list") {
        do_display_access_list();
        show_main_menu();
        return;
    }
    if (cmd == "reload_settings") {
        do_reload_settings();
        show_main_menu();
        return;
    }
    if (cmd == "clear_leash") {
        show_clear_leash_confirm();
        return;
    }
    if (cmd == "reload_collar") {
        do_reload_collar();
        show_main_menu();
        return;
    }
    if (cmd == "get_hud") {
        do_give_hud();
        show_main_menu();
        return;
    }
    if (cmd == "user_manual") {
        do_give_manual();
        show_main_menu();
        return;
    }
    if (cmd == "factory_reset") {
        show_factory_reset_confirm();
        return;
    }
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
                        return; // Not for us, ignore
                    }
                }
                // Either no context (broadcast) or matches our context
                llResetScript();
            }

            return;
        }

        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                CurrentUser = id;
                CurrentUserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                show_main_menu();
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSE -------------------- */if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
                return;
            }

            if (msg_type == "ui.dialog.close") {
                // Dialog was closed externally (e.g., replaced by another dialog)
                // Clean up our session if it matches
                string session = llJsonGetValue(msg, ["session_id"]);
                if (session != JSON_INVALID) {
                    if (session == SessionId) {
                        // Don't send another dialog_close since we're responding to one
                        CurrentUser = NULL_KEY;
                        CurrentUserAcl = -999;
                        gPolicyButtons = [];
                        SessionId = "";
                    }
                }
                return;
            }

            return;
        }
    }
}
