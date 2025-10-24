/* =============================================================================
   PLUGIN: ds_collar_plugin_public.lsl (v2.0 - Consolidated ABI)
   
   PURPOSE: Manage public access mode (enable/disable)
   
   FEATURES:
   - Simple enable/disable toggle
   - Settings persistence (public_mode key)
   - Settings sync and delta consumption
   - Dynamic registration based on owner state (hides from wearer when owned)
   - Restricted ACL: Trustee, Unowned, Primary Owner only
   
   TIER: 1 (Simple - binary toggle with settings)
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
string PLUGIN_CONTEXT = "core_public";
string PLUGIN_LABEL = "Public";
integer PLUGIN_MIN_ACL = 3;  // Trustee minimum
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
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
string KEY_PUBLIC_MODE = "public_mode";
string KEY_OWNER_KEY = "owner_key";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
// Settings cache
integer PublicModeEnabled = FALSE;
key OwnerKey = NULL_KEY;
integer IsOwned = FALSE;

// Session management
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[PUBLIC] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   LIFECYCLE MANAGEMENT
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
    logd("Registered with kernel");
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS CONSUMPTION
   ═══════════════════════════════════════════════════════════ */

apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    
    // Reset to defaults
    PublicModeEnabled = FALSE;
    OwnerKey = NULL_KEY;
    IsOwned = FALSE;
    
    // Load public mode
    if (json_has(kv_json, [KEY_PUBLIC_MODE])) {
        PublicModeEnabled = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_MODE]);
    }
    
    // Load owner key
    if (json_has(kv_json, [KEY_OWNER_KEY])) {
        string owner_str = llJsonGetValue(kv_json, [KEY_OWNER_KEY]);
        OwnerKey = (key)owner_str;
        IsOwned = (OwnerKey != NULL_KEY);
    }
    
    logd("Settings sync: public=" + (string)PublicModeEnabled + ", owned=" + (string)IsOwned);
}

apply_settings_delta(string msg) {
    if (!json_has(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (json_has(changes, [KEY_PUBLIC_MODE])) {
            PublicModeEnabled = (integer)llJsonGetValue(changes, [KEY_PUBLIC_MODE]);
            logd("Delta: public_mode = " + (string)PublicModeEnabled);
        }
        
        if (json_has(changes, [KEY_OWNER_KEY])) {
            string owner_str = llJsonGetValue(changes, [KEY_OWNER_KEY]);
            key old_owner = OwnerKey;
            integer was_owned = IsOwned;
            
            OwnerKey = (key)owner_str;
            IsOwned = (OwnerKey != NULL_KEY);
            
            // If ownership state changed, re-register to update visibility
            if (was_owned != IsOwned) {
                logd("Ownership state changed, re-registering");
                register_self();
            }
        }
    }
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS MODIFICATION
   ═══════════════════════════════════════════════════════════ */

persist_public_mode(integer new_value) {
    // Normalize to 0 or 1
    if (new_value != 0) new_value = 1;
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_PUBLIC_MODE,
        "value", (string)new_value
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    logd("Persisting public_mode=" + (string)new_value);
}

/* ═══════════════════════════════════════════════════════════
   ACL VALIDATION
   ═══════════════════════════════════════════════════════════ */

request_acl(key user) {
    AclPending = TRUE;
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_acl"
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

handle_acl_result(string msg) {
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    
    AclPending = FALSE;
    UserAcl = level;
    
    // Check minimum ACL (Trustee = 3)
    if (level < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanup_session();
        return;
    }
    
    // User has access, show menu
    show_main_menu();
}

/* ═══════════════════════════════════════════════════════════
   UI / MENU SYSTEM
   ═══════════════════════════════════════════════════════════ */

show_main_menu() {
    SessionId = generate_session_id();
    
    // Build buttons based on current state
    list buttons;
    
    if (PublicModeEnabled) {
        buttons = ["Disable", "Back"];
    }
    else {
        buttons = ["Enable", "Back"];
    }
    
    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    
    // Build message
    string message = "Public access is currently ";
    if (PublicModeEnabled) {
        message += "ENABLED.\nDisable public access?";
    }
    else {
        message += "DISABLED.\nEnable public access?";
    }
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
    logd("Menu shown to " + llKey2Name(CurrentUser));
}

/* ═══════════════════════════════════════════════════════════
   BUTTON HANDLING
   ═══════════════════════════════════════════════════════════ */

handle_button_click(string button) {
    // Back button - return to root menu
    if (button == "Back") {
        ui_return_root();
        cleanup_session();
        return;
    }
    
    // Enable button
    if (button == "Enable") {
        PublicModeEnabled = TRUE;
        persist_public_mode(TRUE);
        show_main_menu();
        return;
    }
    
    // Disable button
    if (button == "Disable") {
        PublicModeEnabled = FALSE;
        persist_public_mode(FALSE);
        show_main_menu();
        return;
    }
    
    // Unknown button - redraw menu
    show_main_menu();
}

/* ═══════════════════════════════════════════════════════════
   UI NAVIGATION
   ═══════════════════════════════════════════════════════════ */

ui_return_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* ═══════════════════════════════════════════════════════════
   SESSION CLEANUP
   ═══════════════════════════════════════════════════════════ */

cleanup_session() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    AclPending = FALSE;
    SessionId = "";
    logd("Session cleaned up");
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default {
    state_entry() {
        cleanup_session();
        
        // Reset settings to defaults
        PublicModeEnabled = FALSE;
        OwnerKey = NULL_KEY;
        IsOwned = FALSE;
        
        register_self();
        
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
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            // Registration request
            if (msg_type == "register_now") {
                register_self();
                return;
            }
            
            // Heartbeat ping
            if (msg_type == "ping") {
                send_pong();
                return;
            }
            
            return;
        }
        
        // ===== SETTINGS SYNC/DELTA =====
        if (num == SETTINGS_BUS) {
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
        
        // ===== UI START =====
        if (num == UI_BUS) {
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
        
        // ===== AUTH RESULT =====
        if (num == AUTH_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "acl_result") {
                if (!AclPending) return;
                handle_acl_result(msg);
                return;
            }
            
            return;
        }
        
        // ===== DIALOG RESPONSE =====
        if (num == DIALOG_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "dialog_response") {
                if (!json_has(msg, ["session_id"])) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
                
                if (!json_has(msg, ["button"])) return;
                string button = llJsonGetValue(msg, ["button"]);
                
                if (!json_has(msg, ["user"])) return;
                key user = (key)llJsonGetValue(msg, ["user"]);
                
                if (user != CurrentUser) return;
                
                // Re-validate ACL
                if (UserAcl < PLUGIN_MIN_ACL) {
                    llRegionSayTo(user, 0, "Access denied.");
                    cleanup_session();
                    return;
                }
                
                handle_button_click(button);
                return;
            }
            
            if (msg_type == "dialog_timeout") {
                if (!json_has(msg, ["session_id"])) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
                
                cleanup_session();
                logd("Dialog timeout");
                return;
            }
            
            return;
        }
    }
}
