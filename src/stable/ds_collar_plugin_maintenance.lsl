/* =============================================================================
   PLUGIN: ds_collar_plugin_maintenance.lsl (v2.0 - Consolidated ABI)
   
   PURPOSE: Maintenance and utility functions
   
   FEATURES:
   - View current settings
   - Reload settings from notecard
   - Clear leash (soft reset leash plugin)
   - Give HUD to users
   - Give user manual
   
   ACL REQUIREMENTS:
   - View: Trustee+ (1,2,3,4,5)
   - Full: Owned+ (2,3,4,5)
   
   TIER: 1 (Simple - informational with basic actions)
   ============================================================================= */

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

/* ═══════════════════════════════════════════════════════════
   ACL TIERS
   ═══════════════════════════════════════════════════════════ */
list ALLOWED_ACL_VIEW = [1, 2, 3, 4, 5];  // Can see menu
list ALLOWED_ACL_FULL = [2, 3, 4, 5];     // Can use admin functions

/* ═══════════════════════════════════════════════════════════
   INVENTORY ITEMS
   ═══════════════════════════════════════════════════════════ */
string HUD_ITEM = "D/s Collar control HUD";
string MANUAL_NOTECARD = "DS Collar User Manual";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
// Settings cache (for display)
string CachedSettings = "";
integer SettingsReady = FALSE;

// Session tracking
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

string generate_session_id() {
    return "maint_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   LIFECYCLE
   ═══════════════════════════════════════════════════════════ */

register_self() {
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

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    CachedSettings = kv_json;
    SettingsReady = TRUE;
    
    logd("Settings sync applied");
}

apply_settings_delta(string msg) {
    // We don't need to track individual settings, just refresh the cache
    // Request full sync to update our display cache
    string request = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, request, NULL_KEY);
    
    logd("Settings delta received, requesting full sync");
}

/* ═══════════════════════════════════════════════════════════
   ACL MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

request_acl(key user_key) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user_key
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
    logd("Requested ACL for " + llKey2Name(user_key));
}

handle_acl_result(string msg) {
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    CurrentUserAcl = level;
    
    // Check access
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
    
    if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
        body += "System utilities and documentation.";
    }
    else {
        body += "Get HUD or user manual.";
    }
    
    list buttons = [];
    
    if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
        // Full access: admin functions
        buttons = [
            "Back",
            "View Settings", "Reload Settings", "Clear Leash",
            "Get HUD", "User Manual"
        ];
    }
    else {
        // Limited access: just HUD and manual
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
    
    // Parse the JSON and format it nicely
    list keys = llJson2List(CachedSettings);
    integer i = 0;
    integer len = llGetListLength(keys);
    
    while (i < len) {
        string setting_key = llList2String(keys, i);
        string value = llJsonGetValue(CachedSettings, [setting_key]);
        
        output += setting_key + " = " + value + "\n";
        
        i += 2;  // JSON2List returns [key, value, key, value...]
    }
    
    llRegionSayTo(CurrentUser, 0, output);
    logd("Displayed settings to " + llKey2Name(CurrentUser));
}

do_reload_settings() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    
    llRegionSayTo(CurrentUser, 0, "Settings reload requested.");
    logd("Settings reload requested by " + llKey2Name(CurrentUser));
}

do_clear_leash() {
    // Send soft reset to leash plugin
    string msg = llList2Json(JSON_OBJECT, [
        "type", "soft_reset",
        "context", "core_leash"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    
    llRegionSayTo(CurrentUser, 0, "Leash cleared.");
    logd("Leash cleared by " + llKey2Name(CurrentUser));
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

/* ═══════════════════════════════════════════════════════════
   SESSION CLEANUP
   ═══════════════════════════════════════════════════════════ */

cleanup_session() {
    CurrentUser = NULL_KEY;
    CurrentUserAcl = -999;
    SessionId = "";
    logd("Session cleaned up");
}

/* ═══════════════════════════════════════════════════════════
   DIALOG HANDLERS
   ═══════════════════════════════════════════════════════════ */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (!json_has(msg, ["button"])) return;
    
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    
    string button = llJsonGetValue(msg, ["button"]);
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
        }
        else {
            llRegionSayTo(CurrentUser, 0, "Access denied.");
        }
        close_ui();
        return;
    }
    
    if (button == "Reload Settings") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            do_reload_settings();
        }
        else {
            llRegionSayTo(CurrentUser, 0, "Access denied.");
        }
        close_ui();
        return;
    }
    
    if (button == "Clear Leash") {
        if (llListFindList(ALLOWED_ACL_FULL, [CurrentUserAcl]) != -1) {
            do_clear_leash();
        }
        else {
            llRegionSayTo(CurrentUser, 0, "Access denied.");
        }
        close_ui();
        return;
    }
    
    // Public actions
    if (button == "Get HUD") {
        do_give_hud();
        close_ui();
        return;
    }
    
    if (button == "User Manual") {
        do_give_manual();
        close_ui();
        return;
    }
    
    logd("Unknown button: " + button);
    show_main_menu();
}

handle_dialog_timeout(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    
    logd("Dialog timeout");
    cleanup_session();
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default {
    state_entry() {
        cleanup_session();
        register_self();
        
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
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "register_now") {
                register_self();
                return;
            }
            
            if (msg_type == "ping") {
                send_pong();
                return;
            }
            
            return;
        }
        
        /* ===== SETTINGS BUS ===== */
        if (num == SETTINGS_BUS) {
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
        
        /* ===== UI START ===== */
        if (num == UI_BUS) {
            if (msg_type == "start") {
                if (!json_has(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                
                // User wants to start this plugin
                CurrentUser = id;
                request_acl(id);
                return;
            }
            
            return;
        }
        
        /* ===== AUTH RESULT ===== */
        if (num == AUTH_BUS) {
            if (msg_type == "acl_result") {
                handle_acl_result(msg);
                return;
            }
            
            return;
        }
        
        /* ===== DIALOG RESPONSES ===== */
        if (num == DIALOG_BUS) {
            if (msg_type == "dialog_response") {
                handle_dialog_response(msg);
                return;
            }
            
            if (msg_type == "dialog_timeout") {
                handle_dialog_timeout(msg);
                return;
            }
            
            return;
        }
    }
}
