/*--------------------
PLUGIN: ds_collar_plugin_maintenance.lsl
VERSION: 1.00
REVISION: 20
PURPOSE: Maintenance and utility functions for collar management
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Displays full settings snapshot including unset keys
- Presents access list with honorifics for quick review
- Provides actions to reload settings notecard and clear leash state
- Offers HUD and user manual handouts to authorized users
- Enforces ACL tiers separating view and administrative functions
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_maintenance";
string PLUGIN_LABEL = "Maintenance";
integer PLUGIN_MIN_ACL = 1;  // Public can view (limited options)
string ROOT_CONTEXT = "core_root";

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* -------------------- ACL TIERS -------------------- */
list ALLOWED_ACL_VIEW = [1, 2, 3, 4, 5];  // Can see menu
list ALLOWED_ACL_FULL = [2, 3, 4, 5];     // Can use admin functions

/* -------------------- ALL POSSIBLE SETTINGS -------------------- */
list ALL_SETTINGS = [
    "multi_owner_mode",
    "owner_key",
    "owner_keys",
    "owner_hon",
    "owner_honorifics",
    "trustees",
    "trustee_honorifics",
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
string SessionId = "";

/* -------------------- HELPERS -------------------- */


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

string generate_session_id() {
    return "maint_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

/* -------------------- LIFECYCLE -------------------- */

register_self() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
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
    if (!json_has(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    CachedSettings = kv_json;
    SettingsReady = TRUE;
}

apply_settings_delta(string msg) {
    // Request full sync to update our display cache
    string request = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, request, NULL_KEY);
}

/* -------------------- ACL MANAGEMENT -------------------- */

request_acl(key user_key) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

handle_acl_result(string msg) {
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    CurrentUserAcl = level;
    
    if (llListFindList(ALLOWED_ACL_VIEW, [level]) == -1) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        return_to_root();
        return;
    }
    
    show_main_menu();
}

/* -------------------- MENU DISPLAY -------------------- */

show_main_menu() {
    string body = "Maintenance:\n\n";
    
    list buttons;
    
    if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
        body += "System utilities and documentation.";
        buttons = [
            "Back",
            "View Settings", "Reload Settings",
            "Access List", "Reload Collar",
            "Clear Leash",
            "Get HUD", "User Manual"
        ];
    }
    else {
        body += "Get HUD or user manual.";
        buttons = [
            "Back",
            "Get HUD", "User Manual"
        ];
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
    integer len = llGetListLength(ALL_SETTINGS);
    
    while (i < len) {
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
    if (json_has(CachedSettings, ["multi_owner_mode"])) {
        multi_mode = (integer)llJsonGetValue(CachedSettings, ["multi_owner_mode"]);
    }
    
    // Owner(s)
    if (multi_mode) {
        output += "OWNERS:\n";
        string owners_json = llJsonGetValue(CachedSettings, ["owner_keys"]);
        string honors_json = llJsonGetValue(CachedSettings, ["owner_honorifics"]);
        
        if (owners_json != JSON_INVALID && is_json_arr(owners_json)) {
            list owners = llJson2List(owners_json);
            list honors = [];
            if (honors_json != JSON_INVALID && is_json_arr(honors_json)) {
                honors = llJson2List(honors_json);
            }
            
            if (llGetListLength(owners) > 0) {
                integer i = 0;
                integer count = llGetListLength(owners);
                integer honors_count = llGetListLength(honors);
                while (i < count) {
                    string owner_key = llList2String(owners, i);
                    string honor = "Owner";
                    if (i < honors_count) {
                        honor = llList2String(honors, i);
                    }
                    output += "  " + honor + " - " + owner_key + "\n";
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
    }
    else {
        output += "OWNER:\n";
        string owner_key = llJsonGetValue(CachedSettings, ["owner_key"]);
        string honor = llJsonGetValue(CachedSettings, ["owner_hon"]);
        
        if (owner_key != JSON_INVALID && owner_key != "" && (key)owner_key != NULL_KEY) {
            if (honor == JSON_INVALID || honor == "") honor = "Owner";
            output += "  " + honor + " - " + owner_key + "\n";
        }
        else {
            output += "  (none)\n";
        }
    }
    
    // Trustees
    output += "\nTRUSTEES:\n";
    string trustees_json = llJsonGetValue(CachedSettings, ["trustees"]);
    string t_honors_json = llJsonGetValue(CachedSettings, ["trustee_honorifics"]);
    
    if (trustees_json != JSON_INVALID && is_json_arr(trustees_json)) {
        list trustees = llJson2List(trustees_json);
        list t_honors = [];
        if (t_honors_json != JSON_INVALID && is_json_arr(t_honors_json)) {
            t_honors = llJson2List(t_honors_json);
        }
        
        if (llGetListLength(trustees) > 0) {
            integer i = 0;
            integer count = llGetListLength(trustees);
            integer honors_count = llGetListLength(t_honors);
            while (i < count) {
                string trustee_key = llList2String(trustees, i);
                string honor = "Trustee";
                if (i < honors_count) {
                    honor = llList2String(t_honors, i);
                }
                output += "  " + honor + " - " + trustee_key + "\n";
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
        "action", "release",
        "acl_verified", "1"
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

close_ui() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "close",
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
    SessionId = "";
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (!json_has(msg, ["button"])) return;
    
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    
    string button = llJsonGetValue(msg, ["button"]);
    
    // Navigation
    if (button == "Back") {
        return_to_root();
        return;
    }
    
    // Admin actions (ACL check)
    if (button == "View Settings") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            do_view_settings();
            show_main_menu();
        }
        return;
    }
    
    if (button == "Access List") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            do_display_access_list();
            show_main_menu();
        }
        return;
    }
    
    if (button == "Reload Settings") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            do_reload_settings();
            show_main_menu();
        }
        return;
    }
    
    if (button == "Clear Leash") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            do_clear_leash();
            show_main_menu();
        }
        return;
    }
    
    if (button == "Reload Collar") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            do_reload_collar();
            show_main_menu();
        }
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
    if (!json_has(msg, ["session_id"])) return;
    
    string session = llJsonGetValue(msg, ["session_id"]);
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
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
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
                if (json_has(msg, ["context"])) {
                    string target_context = llJsonGetValue(msg, ["context"]);
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
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
                return;
            }
            
            if (msg_type == "settings_delta") {
                apply_settings_delta(msg);
                return;
            }
            
            return;
        }
        
        /* -------------------- ACL RESULTS -------------------- */if (num == AUTH_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "acl_result") {
                handle_acl_result(msg);
                return;
            }
            
            return;
        }
        
        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "start") {
                if (!json_has(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                
                if (id == NULL_KEY) return;
                
                CurrentUser = id;
                request_acl(id);
                return;
            }
            
            return;
        }
        
        /* -------------------- DIALOG RESPONSE -------------------- */if (num == DIALOG_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);

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
                if (json_has(msg, ["session_id"])) {
                    string session = llJsonGetValue(msg, ["session_id"]);
                    if (session == SessionId) {
                        // Don't send another dialog_close since we're responding to one
                        CurrentUser = NULL_KEY;
                        CurrentUserAcl = -999;
                        SessionId = "";
                    }
                }
                return;
            }

            return;
        }
    }
}
