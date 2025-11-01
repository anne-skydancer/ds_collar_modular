/* =============================================================================
   PLUGIN: ds_collar_plugin_maintenance.lsl (v3.0 - Kanban Messaging Migration)

   PURPOSE: Maintenance and utility functions

   FEATURES:
   - View ALL settings (including unset ones)
   - Display access list with honorifics
   - Reload settings from notecard
   - Clear leash (unclip and clear particles)
   - Give HUD to users
   - Give user manual

   ACL REQUIREMENTS:
   - View: Public+ (1,2,3,4,5)
   - Full: Owned+ (2,3,4,5)

   TIER: 1 (Simple - informational with basic actions)

   KANBAN MIGRATION (v3.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "core_maintenance";

/* ═══════════════════════════════════════════════════════════
   KANBAN UNIVERSAL HELPER (~500-800 bytes)
   ═══════════════════════════════════════════════════════════ */

string kFrom = "";  // Sender context (populated by kRecv)
string kTo = "";    // Recipient context (populated by kRecv)

kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, [
            "from", from,
            "payload", payload,
            "to", to
        ]),
        k
    );
}

string kRecv(string msg, string my_context) {
    // Quick validation: must be JSON object
    if (llGetSubString(msg, 0, 0) != "{") return "";

    // Extract from
    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    // Extract to
    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast "" or direct to my_context)
    if (to != "" && to != my_context) return "";

    // Extract payload
    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    // Set globals for routing
    kFrom = from;
    kTo = to;

    return payload;
}

string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

integer DEBUG = FALSE;

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ═══════════════════════════════════════════════════════════
   PLUGIN IDENTITY
   ═══════════════════════════════════════════════════════════ */
string PLUGIN_LABEL = "Maintenance";
integer PLUGIN_MIN_ACL = 1;  // Public can view (limited options)

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* ═══════════════════════════════════════════════════════════
   ACL TIERS
   ═══════════════════════════════════════════════════════════ */
list ALLOWED_ACL_VIEW = [1, 2, 3, 4, 5];  // Can see menu
list ALLOWED_ACL_FULL = [2, 3, 4, 5];     // Can use admin functions

/* ═══════════════════════════════════════════════════════════
   ALL POSSIBLE SETTINGS
   ═══════════════════════════════════════════════════════════ */
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

/* ═══════════════════════════════════════════════════════════
   INVENTORY ITEMS
   ═══════════════════════════════════════════════════════════ */
string HUD_ITEM = "D/s Collar control HUD";
string MANUAL_NOTECARD = "D/s Collar User Manual";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
string CachedSettings = "";
integer SettingsReady = FALSE;

key CurrentUser = NULL_KEY;
integer CurrentUserAcl = -999;
string SessionId = "";

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[MAINT] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

string generate_session_id() {
    return "maint_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   LIFECYCLE
   ═══════════════════════════════════════════════════════════ */

register_self() {
    string payload = kPayload([
        "register", 1,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    kSend(CONTEXT, "", KERNEL_LIFECYCLE, payload, NULL_KEY);
    logd("Registered");
}

send_pong() {
    string payload = kPayload(["pong", 1]);
    kSend(CONTEXT, "", KERNEL_LIFECYCLE, payload, NULL_KEY);
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

apply_settings_sync(string payload) {
    if (!json_has(payload, ["kv"])) return;

    string kv_json = llJsonGetValue(payload, ["kv"]);
    CachedSettings = kv_json;
    SettingsReady = TRUE;

    logd("Settings sync applied");
}

apply_settings_delta(string payload) {
    // Request full sync to update our display cache
    string request_payload = kPayload(["settings_get", 1]);
    kSend(CONTEXT, "settings", SETTINGS_BUS, request_payload, NULL_KEY);

    logd("Settings delta received, requesting full sync");
}

/* ═══════════════════════════════════════════════════════════
   ACL MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

request_acl(key user_key) {
    string payload = kPayload([
        "acl_query", 1,
        "avatar", (string)user_key
    ]);
    kSend(CONTEXT, "auth", AUTH_BUS, payload, NULL_KEY);
    logd("Requested ACL for " + llKey2Name(user_key));
}

handle_acl_result(string payload) {
    if (!json_has(payload, ["avatar"])) return;
    if (!json_has(payload, ["level"])) return;

    key avatar = (key)llJsonGetValue(payload, ["avatar"]);
    if (avatar != CurrentUser) return;

    integer level = (integer)llJsonGetValue(payload, ["level"]);
    CurrentUserAcl = level;

    if (llListFindList(ALLOWED_ACL_VIEW, [level]) == -1) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        return_to_root();
        return;
    }

    logd("ACL result: " + (string)level + " for " + llKey2Name(avatar));
    show_main_menu();
}

/* ═══════════════════════════════════════════════════════════
   MENU DISPLAY
   ═══════════════════════════════════════════════════════════ */

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

    string payload = kPayload([
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Maintenance",
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);

    kSend(CONTEXT, "dialogs", DIALOG_BUS, payload, NULL_KEY);
    logd("Showing menu to " + llKey2Name(CurrentUser));
}

/* ═══════════════════════════════════════════════════════════
   ACTIONS
   ═══════════════════════════════════════════════════════════ */

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
    logd("Displayed settings to " + llKey2Name(CurrentUser));
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
                while (i < llGetListLength(owners)) {
                    string owner_key = llList2String(owners, i);
                    string honor = "Owner";
                    if (i < llGetListLength(honors)) {
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
            while (i < llGetListLength(trustees)) {
                string trustee_key = llList2String(trustees, i);
                string honor = "Trustee";
                if (i < llGetListLength(t_honors)) {
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
    logd("Displayed access list to " + llKey2Name(CurrentUser));
}

do_reload_settings() {
    string payload = kPayload(["settings_get", 1]);
    kSend(CONTEXT, "settings", SETTINGS_BUS, payload, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Settings reload requested.");
    logd("Settings reload requested by " + llKey2Name(CurrentUser));
}

do_clear_leash() {
    string payload = kPayload([
        "leash_action", 1,
        "action", "release",
        "acl_verified", "1"
    ]);
    kSend(CONTEXT, "leash", UI_BUS, payload, CurrentUser);

    llRegionSayTo(CurrentUser, 0, "Leash cleared.");
    logd("Leash cleared by " + llKey2Name(CurrentUser));
}

do_reload_collar() {
    // Broadcast soft reset to all plugins
    string payload = kPayload([
        "reset", 1,
        "from", "maintenance"
    ]);
    kSend(CONTEXT, "", KERNEL_LIFECYCLE, payload, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Collar reload initiated.");
    logd("Collar reload requested by " + llKey2Name(CurrentUser));
}

do_give_hud() {
    if (llGetInventoryType(HUD_ITEM) != INVENTORY_OBJECT) {
        llRegionSayTo(CurrentUser, 0, "HUD not found in inventory.");
        logd("HUD not found: " + HUD_ITEM);
    }
    else {
        llGiveInventory(CurrentUser, HUD_ITEM);
        llRegionSayTo(CurrentUser, 0, "HUD sent.");
        logd("HUD given to " + llKey2Name(CurrentUser));
    }
}

do_give_manual() {
    if (llGetInventoryType(MANUAL_NOTECARD) != INVENTORY_NOTECARD) {
        llRegionSayTo(CurrentUser, 0, "Manual not found in inventory.");
        logd("Manual not found: " + MANUAL_NOTECARD);
    }
    else {
        llGiveInventory(CurrentUser, MANUAL_NOTECARD);
        llRegionSayTo(CurrentUser, 0, "Manual sent.");
        logd("Manual given to " + llKey2Name(CurrentUser));
    }
}

/* ═══════════════════════════════════════════════════════════
   NAVIGATION
   ═══════════════════════════════════════════════════════════ */

return_to_root() {
    string payload = kPayload([
        "return", 1,
        "user", (string)CurrentUser
    ]);
    kSend(CONTEXT, "ui", UI_BUS, payload, NULL_KEY);
    cleanup_session();
}

close_ui() {
    string payload = kPayload([
        "close", 1,
        "user", (string)CurrentUser
    ]);
    kSend(CONTEXT, "ui", UI_BUS, payload, NULL_KEY);
    cleanup_session();
}

/* ═══════════════════════════════════════════════════════════
   SESSION CLEANUP
   ═══════════════════════════════════════════════════════════ */

cleanup_session() {
    // Close the dialog session in the dialog manager
    if (SessionId != "") {
        string payload = kPayload([
            "close", 1,
            "session_id", SessionId
        ]);
        kSend(CONTEXT, "dialogs", DIALOG_BUS, payload, NULL_KEY);
    }

    CurrentUser = NULL_KEY;
    CurrentUserAcl = -999;
    SessionId = "";
    logd("Session cleaned up");
}

/* ═══════════════════════════════════════════════════════════
   DIALOG HANDLERS
   ═══════════════════════════════════════════════════════════ */

handle_dialog_response(string payload) {
    if (!json_has(payload, ["session_id"])) return;
    if (!json_has(payload, ["button"])) return;

    string session = llJsonGetValue(payload, ["session_id"]);
    if (session != SessionId) return;

    string button = llJsonGetValue(payload, ["button"]);
    logd("Button pressed: " + button);

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

handle_dialog_timeout(string payload) {
    if (!json_has(payload, ["session_id"])) return;

    string session = llJsonGetValue(payload, ["session_id"]);
    if (session != SessionId) return;

    cleanup_session();
    logd("Dialog timeout");
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default {
    state_entry() {
        cleanup_session();
        register_self();

        // Request initial settings
        string payload = kPayload(["settings_get", 1]);
        kSend(CONTEXT, "settings", SETTINGS_BUS, payload, NULL_KEY);

        logd("Ready");
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
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE) {
            // Register now: has "register_now" marker
            if (json_has(payload, ["register_now"])) {
                register_self();
                return;
            }

            // Ping: has "ping" marker
            if (json_has(payload, ["ping"])) {
                send_pong();
                return;
            }

            // Soft reset: has "reset" marker
            if (json_has(payload, ["reset"])) {
                llResetScript();
                return;
            }
            return;
        }

        /* ===== SETTINGS BUS ===== */
        if (num == SETTINGS_BUS) {
            // Settings sync: has "kv" field
            if (json_has(payload, ["kv"])) {
                apply_settings_sync(payload);
                return;
            }

            // Settings delta: has "op" field
            if (json_has(payload, ["op"])) {
                apply_settings_delta(payload);
                return;
            }
            return;
        }

        /* ===== AUTH BUS ===== */
        if (num == AUTH_BUS) {
            // ACL result: has "level" field
            if (json_has(payload, ["level"])) {
                handle_acl_result(payload);
                return;
            }
            return;
        }

        /* ===== UI START ===== */
        if (num == UI_BUS) {
            // UI start: has "start" marker
            if (json_has(payload, ["start"])) {
                if (id == NULL_KEY) return;

                CurrentUser = id;
                request_acl(id);
                return;
            }
            return;
        }

        /* ===== DIALOG RESPONSE ===== */
        if (num == DIALOG_BUS) {
            // Dialog button response: has "button" field
            if (json_has(payload, ["button"])) {
                handle_dialog_response(payload);
                return;
            }

            // Dialog timeout: has "timeout" field
            if (json_has(payload, ["timeout"])) {
                handle_dialog_timeout(payload);
                return;
            }

            // Dialog close: has "close" field
            if (json_has(payload, ["close"])) {
                // Dialog was closed externally (e.g., replaced by another dialog)
                // Clean up our session if it matches
                if (json_has(payload, ["session_id"])) {
                    string session = llJsonGetValue(payload, ["session_id"]);
                    if (session == SessionId) {
                        // Don't send another dialog_close since we're responding to one
                        CurrentUser = NULL_KEY;
                        CurrentUserAcl = -999;
                        SessionId = "";
                        logd("Dialog closed externally");
                    }
                }
                return;
            }
            return;
        }
    }
}
