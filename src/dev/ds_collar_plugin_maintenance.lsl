/* ===============================================================
   PLUGIN: ds_collar_plugin_maintenance.lsl (v1.0 - Enhanced)
   
   PURPOSE: Maintenance and utility functions
   
   FEATURES:
   - View ALL settings (including unset ones)
   - Display access list with honorifics
   - Reload settings from notecard
   - Clear leash (soft reset leash plugin)
   - Give HUD to users
   - Give user manual
   
   ACL REQUIREMENTS:
   - View: Public+ (1,2,3,4,5)
   - Full: Owned+ (2,3,4,5)
   
   TIER: 1 (Simple - informational with basic actions)
   =============================================================== */

integer DEBUG = FALSE;

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ===============================================================
   PLUGIN IDENTITY
   =============================================================== */
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

/* ===============================================================
   ACL TIERS
   =============================================================== */
list ALLOWED_ACL_VIEW = [1, 2, 3, 4, 5];  // Can see menu
list ALLOWED_ACL_FULL = [2, 3, 4, 5];     // Can use admin functions

/* ===============================================================
   ALL POSSIBLE SETTINGS
   =============================================================== */
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

/* ===============================================================
   INVENTORY ITEMS
   =============================================================== */
string HUD_ITEM = "D/s Collar control HUD";
string MANUAL_NOTECARD = "D/s Collar User Manual";

/* ===============================================================
   STATE
   =============================================================== */
string CachedSettings = "";
integer SettingsReady = FALSE;

key CurrentUser = NULL_KEY;
integer CurrentUserAcl = -999;
string SessionId = "";

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[MAINT] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer isJsonArr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

string generateSessionId() {
    return "maint_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

/* ===============================================================
   LIFECYCLE
   =============================================================== */

registerSelf() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Registered");
}

sendPong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* ===============================================================
   SETTINGS MANAGEMENT
   =============================================================== */

applySettingsSync(string msg) {
    if (!jsonHas(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    CachedSettings = kv_json;
    SettingsReady = TRUE;
    
    logd("Settings sync applied");
}

applySettingsDelta(string msg) {
    // Request full sync to update our display cache
    string request = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, request, NULL_KEY);
    
    logd("Settings delta received, requesting full sync");
}

/* ===============================================================
   ACL MANAGEMENT
   =============================================================== */

requestAcl(key user_key) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
    logd("Requested ACL for " + llKey2Name(user_key));
}

handleAclResult(string msg) {
    if (!jsonHas(msg, ["avatar"])) return;
    if (!jsonHas(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    CurrentUserAcl = level;
    
    if (llListFindList(ALLOWED_ACL_VIEW, [level]) == -1) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        returnToRoot();
        return;
    }
    
    logd("ACL result: " + (string)level + " for " + llKey2Name(avatar));
    showMainMenu();
}

/* ===============================================================
   MENU DISPLAY
   =============================================================== */

showMainMenu() {
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
    
    SessionId = generateSessionId();
    
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
    logd("Showing menu to " + llKey2Name(CurrentUser));
}

/* ===============================================================
   ACTIONS
   =============================================================== */

doViewSettings() {
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

doDisplayAccessList() {
    if (!SettingsReady || CachedSettings == "") {
        llRegionSayTo(CurrentUser, 0, "Settings not loaded yet. Try again.");
        return;
    }
    
    string output = "=== Access Control List ===\n\n";
    
    // Multi-owner mode check
    integer multi_mode = 0;
    if (jsonHas(CachedSettings, ["multi_owner_mode"])) {
        multi_mode = (integer)llJsonGetValue(CachedSettings, ["multi_owner_mode"]);
    }
    
    // Owner(s)
    if (multi_mode) {
        output += "OWNERS:\n";
        string owners_json = llJsonGetValue(CachedSettings, ["owner_keys"]);
        string honors_json = llJsonGetValue(CachedSettings, ["owner_honorifics"]);
        
        if (owners_json != JSON_INVALID && isJsonArr(owners_json)) {
            list owners = llJson2List(owners_json);
            list honors = [];
            if (honors_json != JSON_INVALID && isJsonArr(honors_json)) {
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
    
    if (trustees_json != JSON_INVALID && isJsonArr(trustees_json)) {
        list trustees = llJson2List(trustees_json);
        list t_honors = [];
        if (t_honors_json != JSON_INVALID && isJsonArr(t_honors_json)) {
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
    
    if (blacklist_json != JSON_INVALID && isJsonArr(blacklist_json)) {
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

doReloadSettings() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Settings reload requested.");
    logd("Settings reload requested by " + llKey2Name(CurrentUser));
}

doClearLeash() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "soft_reset",
        "context", "core_leash",
        "from", "maintenance"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Leash cleared.");
    logd("Leash cleared by " + llKey2Name(CurrentUser));
}

doReloadCollar() {
    // Broadcast soft reset to all plugins (no context = all plugins)
    string msg = llList2Json(JSON_OBJECT, [
        "type", "soft_reset",
        "from", "maintenance"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Collar reload initiated.");
    logd("Collar reload requested by " + llKey2Name(CurrentUser));
}

doGiveHud() {
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

doGiveManual() {
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

/* ===============================================================
   NAVIGATION
   =============================================================== */

returnToRoot() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
    cleanupSession();
}

closeUi() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "close",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
    cleanupSession();
}

/* ===============================================================
   SESSION CLEANUP
   =============================================================== */

cleanupSession() {
    CurrentUser = NULL_KEY;
    CurrentUserAcl = -999;
    SessionId = "";
    logd("Session cleaned up");
}

/* ===============================================================
   DIALOG HANDLERS
   =============================================================== */

handleDialogResponse(string msg) {
    if (!jsonHas(msg, ["session_id"])) return;
    if (!jsonHas(msg, ["button"])) return;
    
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    
    string button = llJsonGetValue(msg, ["button"]);
    logd("Button pressed: " + button);
    
    // Navigation
    if (button == "Back") {
        returnToRoot();
        return;
    }
    
    // Admin actions (ACL check)
    if (button == "View Settings") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            doViewSettings();
            showMainMenu();
        }
        return;
    }
    
    if (button == "Access List") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            doDisplayAccessList();
            showMainMenu();
        }
        return;
    }
    
    if (button == "Reload Settings") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            doReloadSettings();
            showMainMenu();
        }
        return;
    }
    
    if (button == "Clear Leash") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            doClearLeash();
            showMainMenu();
        }
        return;
    }
    
    if (button == "Reload Collar") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            doReloadCollar();
            showMainMenu();
        }
        return;
    }
    
    // Public actions
    if (button == "Get HUD") {
        doGiveHud();
        showMainMenu();
        return;
    }
    
    if (button == "User Manual") {
        doGiveManual();
        showMainMenu();
        return;
    }
}

handleDialogTimeout(string msg) {
    if (!jsonHas(msg, ["session_id"])) return;
    
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    
    cleanupSession();
    logd("Dialog timeout");
}

/* ===============================================================
   EVENTS
   =============================================================== */

default {
    state_entry() {
        cleanupSession();
        registerSelf();
        
        // Request initial settings
        string msg = llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]);
        llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
        
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
        // ===== KERNEL LIFECYCLE =====
        if (num == KERNEL_LIFECYCLE) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);

            if (msg_type == "register_now") {
                registerSelf();
                return;
            }

            if (msg_type == "ping") {
                sendPong();
                return;
            }

            if (msg_type == "soft_reset") {
                // Check if this is a targeted reset
                if (jsonHas(msg, ["context"])) {
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
        
        // ===== SETTINGS SYNC/DELTA =====
        if (num == SETTINGS_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "settings_sync") {
                applySettingsSync(msg);
                return;
            }
            
            if (msg_type == "settings_delta") {
                applySettingsDelta(msg);
                return;
            }
            
            return;
        }
        
        // ===== ACL RESULTS =====
        if (num == AUTH_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "acl_result") {
                handleAclResult(msg);
                return;
            }
            
            return;
        }
        
        // ===== UI START =====
        if (num == UI_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "start") {
                if (!jsonHas(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                
                if (id == NULL_KEY) return;
                
                CurrentUser = id;
                requestAcl(id);
                return;
            }
            
            return;
        }
        
        // ===== DIALOG RESPONSE =====
        if (num == DIALOG_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "dialog_response") {
                handleDialogResponse(msg);
                return;
            }
            
            if (msg_type == "dialog_timeout") {
                handleDialogTimeout(msg);
                return;
            }
            
            return;
        }
    }
}
