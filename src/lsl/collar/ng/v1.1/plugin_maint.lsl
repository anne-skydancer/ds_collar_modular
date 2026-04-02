/*--------------------
PLUGIN: ds_collar_plugin_maintenance.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Maintenance and utility functions for collar management
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded ALLOWED_ACL_FULL list with policy reads via
  get_policy_buttons() and btn_allowed(). Removed PLUGIN_MIN_ACL and
  min_acl from kernel registration message.
- REVISION 24: Owner storage consolidated — owner/owners as JSON objects
- REVISION 23: Trustees parsed as JSON object; removed trustee_honorifics from settings list
- Displays full settings snapshot including unset keys
- Presents access list with honorifics for quick review
- Provides actions to reload settings notecard and clear leash state
- Offers HUD and user manual handouts to authorized users
- Enforces ACL tiers separating view and administrative functions
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_maintenance";
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

/* -------------------- ALL POSSIBLE SETTINGS -------------------- */
list ALL_SETTINGS = [
    "multi_owner_mode",
    "owner",
    "owners",
    "trustees",
    "blacklist",
    "public_mode",
    "locked",
    "tpe_mode",
    "runaway_enabled",
    "restrictions",
    "rlv_tp_exceptions",
    "rlv_im_exceptions"
];

/* -------------------- INVENTORY ITEMS -------------------- */
string HUD_ITEM = "D/s Collar control HUD";
string MANUAL_NOTECARD = "D/s Collar User Manual";

/* -------------------- STATE -------------------- */
string CachedSettings = "";
integer SettingsReady = FALSE;

key CurrentUser = NULL_KEY;
integer CurrentUserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";

/* -------------------- HELPERS -------------------- */



integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

string generate_session_id() {
    return "maint_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
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

/* -------------------- LIFECYCLE -------------------- */

register_self() {
    // Write button visibility policy to LSD (default-deny per ACL level)
    llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Get HUD,User Manual",
        "2", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        "3", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        "4", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        "5", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual"
    ]));

    // Register with kernel
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
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

apply_settings_sync(string msg) {
    string kv_json = llJsonGetValue(msg, ["kv"]);
    if (kv_json == JSON_INVALID) return;
    CachedSettings = kv_json;
    SettingsReady = TRUE;
}

apply_settings_delta() {
    // Request full sync to update our display cache
    // (msg is unused because we just request a full sync regardless of what changed)
    string request = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, request, NULL_KEY);
}


/* -------------------- MENU DISPLAY -------------------- */

show_main_menu() {
    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, CurrentUserAcl);

    string body = "Maintenance:\n\n";
    list buttons = ["Back"];

    // Build menu from policy
    if (btn_allowed("View Settings"))    buttons += ["View Settings"];
    if (btn_allowed("Reload Settings"))  buttons += ["Reload Settings"];
    if (btn_allowed("Access List"))      buttons += ["Access List"];
    if (btn_allowed("Reload Collar"))    buttons += ["Reload Collar"];
    if (btn_allowed("Clear Leash"))      buttons += ["Clear Leash"];
    if (btn_allowed("Get HUD"))          buttons += ["Get HUD"];
    if (btn_allowed("User Manual"))      buttons += ["User Manual"];

    // Adjust body text based on available buttons
    if (btn_allowed("View Settings")) {
        body += "System utilities and documentation.";
    }
    else {
        body += "Get HUD or user manual.";
    }

    SessionId = generate_session_id();

    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Maintenance",
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- ACTIONS -------------------- */

do_view_settings() {
    if (!SettingsReady || CachedSettings == "") {
        llRegionSayTo(CurrentUser, 0, "Settings not loaded yet. Try again.");
        return;
    }

    string output = "=== Collar Settings ===\n";

    // Iterate through ALL known settings
    integer i = 0;

    while (i < llGetListLength(ALL_SETTINGS)) {
        string setting_key = llList2String(ALL_SETTINGS, i);
        string value = llJsonGetValue(CachedSettings, [setting_key]);

        // Show (not set) for missing keys
        if (value == JSON_INVALID || value == "") {
            value = "(not set)";
        }

        output += setting_key + " = " + value + "\n";
        i += 1;
    }

    llRegionSayTo(CurrentUser, 0, output);
}

do_display_access_list() {
    if (!SettingsReady || CachedSettings == "") {
        llRegionSayTo(CurrentUser, 0, "Settings not loaded yet. Try again.");
        return;
    }

    string output = "=== Access Control List ===\n\n";

    // Multi-owner mode check
    integer multi_mode = 0;
    string tmp = llJsonGetValue(CachedSettings, ["multi_owner_mode"]);
    if (tmp != JSON_INVALID) {
        multi_mode = (integer)tmp;
    }

    // Owner(s) — stored as JSON objects {uuid:honorific}
    if (multi_mode) {
        output += "OWNERS:\n";
        string owners_raw = llJsonGetValue(CachedSettings, ["owners"]);

        if (owners_raw != JSON_INVALID && llJsonValueType(owners_raw, []) == JSON_OBJECT) {
            list pairs = llJson2List(owners_raw);
            integer plen = llGetListLength(pairs);
            if (plen > 0) {
                integer i = 0;
                while (i < plen) {
                    string owner_uuid = llList2String(pairs, i);
                    string honor = llList2String(pairs, i + 1);
                    if (honor == "") honor = "Owner";
                    output += "  " + honor + " - " + owner_uuid + "\n";
                    i += 2;
                }
            }
            else {
                output += "  (none)\n";
            }
        }
        else {
            output += "  (none)\n";
        }
    }
    else {
        output += "OWNER:\n";
        string owner_raw = llJsonGetValue(CachedSettings, ["owner"]);

        if (owner_raw != JSON_INVALID && llJsonValueType(owner_raw, []) == JSON_OBJECT) {
            list pairs = llJson2List(owner_raw);
            if (llGetListLength(pairs) >= 2) {
                string owner_uuid = llList2String(pairs, 0);
                string honor = llList2String(pairs, 1);
                if (honor == "") honor = "Owner";
                output += "  " + honor + " - " + owner_uuid + "\n";
            }
            else {
                output += "  (none)\n";
            }
        }
        else {
            output += "  (none)\n";
        }
    }

    // Trustees (JSON object {uuid:honorific})
    output += "\nTRUSTEES:\n";
    string trustees_raw = llJsonGetValue(CachedSettings, ["trustees"]);

    if (trustees_raw != JSON_INVALID && llJsonValueType(trustees_raw, []) == JSON_OBJECT) {
        list pairs = llJson2List(trustees_raw);
        integer plen = llGetListLength(pairs);
        if (plen > 0) {
            integer i = 0;
            while (i < plen) {
                string trustee_key = llList2String(pairs, i);
                string honor = llList2String(pairs, i + 1);
                if (honor == "") honor = "Trustee";
                output += "  " + honor + " - " + trustee_key + "\n";
                i += 2;
            }
        }
        else {
            output += "  (none)\n";
        }
    }
    else {
        output += "  (none)\n";
    }

    // Blacklist
    output += "\nBLACKLISTED:\n";
    string blacklist_json = llJsonGetValue(CachedSettings, ["blacklist"]);

    if (blacklist_json != JSON_INVALID && is_json_arr(blacklist_json)) {
        list blacklist = llJson2List(blacklist_json);
        if (llGetListLength(blacklist) > 0) {
            integer i = 0;
            while (i < llGetListLength(blacklist)) {
                output += "  " + llList2String(blacklist, i) + "\n";
                i += 1;
            }
        }
        else {
            output += "  (none)\n";
        }
    }
    else {
        output += "  (none)\n";
    }

    llRegionSayTo(CurrentUser, 0, output);
}

do_reload_settings() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Settings reload requested.");
}

do_clear_leash() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", "release"
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, CurrentUser);

    llRegionSayTo(CurrentUser, 0, "Leash cleared.");
}

do_reload_collar() {
    // Broadcast soft reset to all plugins
    string msg = llList2Json(JSON_OBJECT, [
        "type", "soft_reset",
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
        "type", "return",
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
            "type", "dialog_close",
            "session_id", SessionId
        ]);
        llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
    }

    CurrentUser = NULL_KEY;
    CurrentUserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;

    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;

    string button = llJsonGetValue(msg, ["button"]);

    // Navigation
    if (button == "Back") {
        return_to_root();
        return;
    }

    // Admin actions (button only shown to qualified ACL)
    if (button == "View Settings") {
        do_view_settings();
        show_main_menu();
        return;
    }

    if (button == "Access List") {
        do_display_access_list();
        show_main_menu();
        return;
    }

    if (button == "Reload Settings") {
        do_reload_settings();
        show_main_menu();
        return;
    }

    if (button == "Clear Leash") {
        do_clear_leash();
        show_main_menu();
        return;
    }

    if (button == "Reload Collar") {
        do_reload_collar();
        show_main_menu();
        return;
    }

    // Public actions
    if (button == "Get HUD") {
        do_give_hud();
        show_main_menu();
        return;
    }

    if (button == "User Manual") {
        do_give_manual();
        show_main_menu();
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

        // Request initial settings
        string msg = llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]);
        llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
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
                register_self();
                return;
            }

            if (msg_type == "ping") {
                send_pong();
                return;
            }

            if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
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

        /* -------------------- SETTINGS SYNC/DELTA -------------------- */if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
                return;
            }

            if (msg_type == "settings_delta") {
                apply_settings_delta();
                return;
            }

            return;
        }

        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "start") {
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

            if (msg_type == "dialog_response") {
                handle_dialog_response(msg);
                return;
            }

            if (msg_type == "dialog_timeout") {
                handle_dialog_timeout(msg);
                return;
            }

            if (msg_type == "dialog_close") {
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
