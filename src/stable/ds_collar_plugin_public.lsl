/* ==================================================================================
   PLUGIN: ds_collar_plugin_public.lsl (v1.0 - Toggle Mode)
   
   PURPOSE: Toggle public access mode (direct button click)
   
   FEATURES:
   - Direct toggle from main menu (no submenu)
   - Dynamic button label (Public: Y / Public: N)
   - Settings persistence (public_mode key)
   - Settings sync and delta consumption
   - Restricted ACL: Trustee, Unowned, Primary Owner only
   
   TIER: 1 (Simple - binary toggle with settings)
   ============================================================================== */

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
string PLUGIN_CONTEXT = "core_public";
string PLUGIN_LABEL_ON = "Public: Y";
string PLUGIN_LABEL_OFF = "Public: N";
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

/* ===============================================================
   SETTINGS KEYS
   =============================================================== */
string KEY_PUBLIC_MODE = "public_mode";

/* ===============================================================
   STATE
   =============================================================== */
integer PublicModeEnabled = FALSE;

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[PUBLIC] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* ===============================================================
   LIFECYCLE MANAGEMENT
   =============================================================== */

register_self() {
    string label = PLUGIN_LABEL_OFF;
    if (PublicModeEnabled) {
        label = PLUGIN_LABEL_ON;
    }
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", label,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Registered with kernel as: " + label);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* ===============================================================
   SETTINGS CONSUMPTION
   =============================================================== */

apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    
    integer old_state = PublicModeEnabled;
    PublicModeEnabled = FALSE;
    
    if (json_has(kv_json, [KEY_PUBLIC_MODE])) {
        PublicModeEnabled = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_MODE]);
    }
    
    logd("Settings sync: public=" + (string)PublicModeEnabled);
    
    // If state changed, update label
    if (old_state != PublicModeEnabled) {
        register_self();
    }
}

apply_settings_delta(string msg) {
    if (!json_has(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (json_has(changes, [KEY_PUBLIC_MODE])) {
            integer old_state = PublicModeEnabled;
            PublicModeEnabled = (integer)llJsonGetValue(changes, [KEY_PUBLIC_MODE]);
            logd("Delta: public_mode = " + (string)PublicModeEnabled);
            
            // If state changed, update label
            if (old_state != PublicModeEnabled) {
                register_self();
            }
        }
    }
}

/* ===============================================================
   SETTINGS MODIFICATION
   =============================================================== */

persist_public_mode(integer new_value) {
    if (new_value != 0) new_value = 1;
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_PUBLIC_MODE,
        "value", (string)new_value
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    logd("Persisting public_mode=" + (string)new_value);
}

/* ===============================================================
   UI LABEL UPDATE
   =============================================================== */

update_ui_label_and_return(key user) {
    string new_label = PLUGIN_LABEL_OFF;
    if (PublicModeEnabled) {
        new_label = PLUGIN_LABEL_ON;
    }
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "update_label",
        "context", PLUGIN_CONTEXT,
        "label", new_label
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
    
    // Return user to root menu
    msg = llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)user
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
    
    logd("Updated UI label to: " + new_label + " and returning to root");
}

/* ===============================================================
   DIRECT TOGGLE ACTION
   =============================================================== */

toggle_public_access(key user, integer acl_level) {
    // Verify ACL (Trustee = 3 minimum)
    if (acl_level < PLUGIN_MIN_ACL) {
        llRegionSayTo(user, 0, "Access denied.");
        return;
    }
    
    // Toggle state
    PublicModeEnabled = !PublicModeEnabled;
    
    // Persist change
    persist_public_mode(PublicModeEnabled);
    
    // Notify user
    if (PublicModeEnabled) {
        llRegionSayTo(user, 0, "Public access enabled.");
    }
    else {
        llRegionSayTo(user, 0, "Public access disabled.");
    }
    
    // Update UI label and return to root menu
    update_ui_label_and_return(user);
}

/* ===============================================================
   ACL VALIDATION
   =============================================================== */

request_acl_and_toggle(key user) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_toggle"
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

handle_acl_result(string msg, key expected_user) {
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != expected_user) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    
    // Toggle immediately with this ACL level
    toggle_public_access(avatar, level);
}

/* ===============================================================
   EVENTS
   =============================================================== */

default {
    state_entry() {
        PublicModeEnabled = FALSE;
        
        register_self();
        
        // Request settings
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
        
        // ===== UI DIRECT TOGGLE =====
        if (num == UI_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "start") {
                if (!json_has(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                
                if (id == NULL_KEY) return;
                
                // Request ACL and toggle
                request_acl_and_toggle(id);
                return;
            }
            
            return;
        }
        
        // ===== ACL RESULTS =====
        if (num == AUTH_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "acl_result") {
                if (!json_has(msg, ["id"])) return;
                string correlation = llJsonGetValue(msg, ["id"]);
                
                if (correlation == PLUGIN_CONTEXT + "_toggle") {
                    if (!json_has(msg, ["avatar"])) return;
                    key user = (key)llJsonGetValue(msg, ["avatar"]);
                    handle_acl_result(msg, user);
                }
                return;
            }
            
            return;
        }
    }
}
