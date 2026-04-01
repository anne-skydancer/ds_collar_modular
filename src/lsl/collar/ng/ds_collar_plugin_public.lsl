/*--------------------
PLUGIN: ds_collar_plugin_public.lsl
VERSION: 1.00
REVISION: 20
PURPOSE: Toggle public access mode directly from main menu
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Replaces submenu with single main-menu toggle button
- Updates button label dynamically to reflect public mode state
- Persists public_mode flag via settings sync and delta handlers
- Restricts toggle to trustee and owner-tier ACL levels
- Returns control to root context after state changes
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
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

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_PUBLIC_MODE = "public_mode";

/* -------------------- STATE -------------------- */
integer PublicModeEnabled = FALSE;

/* -------------------- HELPERS -------------------- */


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

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
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- SETTINGS CONSUMPTION -------------------- */

apply_settings_sync(string msg) {
    string kv_json = llJsonGetValue(msg, ["kv"]);
    if (kv_json == JSON_INVALID) return;

    integer old_state = PublicModeEnabled;
    PublicModeEnabled = FALSE;

    string public_val = llJsonGetValue(kv_json, [KEY_PUBLIC_MODE]);
    if (public_val != JSON_INVALID) {
        PublicModeEnabled = (integer)public_val;
    }
    
    
    // If state changed, update label
    if (old_state != PublicModeEnabled) {
        register_self();
    }
}

apply_settings_delta(string msg) {
    string op = llJsonGetValue(msg, ["op"]);
    if (op == JSON_INVALID) return;

    if (op == "set") {
        string changes = llJsonGetValue(msg, ["changes"]);
        if (changes == JSON_INVALID) return;

        string public_val = llJsonGetValue(changes, [KEY_PUBLIC_MODE]);
        if (public_val != JSON_INVALID) {
            integer old_state = PublicModeEnabled;
            PublicModeEnabled = (integer)public_val;
            
            // If state changed, update label
            if (old_state != PublicModeEnabled) {
                register_self();
            }
        }
    }
}

/* -------------------- SETTINGS MODIFICATION -------------------- */

persist_public_mode(integer new_value) {
    if (new_value != 0) new_value = 1;
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_PUBLIC_MODE,
        "value", (string)new_value
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

/* -------------------- UI LABEL UPDATE -------------------- */

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
}

/* -------------------- DIRECT TOGGLE ACTION -------------------- */

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

/* -------------------- ACL VALIDATION -------------------- */

request_acl_and_toggle(key user) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_toggle"
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

handle_acl_result(string msg, key expected_user) {
    string avatar_str = llJsonGetValue(msg, ["avatar"]);
    string level_str = llJsonGetValue(msg, ["level"]);
    if (avatar_str == JSON_INVALID || level_str == JSON_INVALID) return;

    key avatar = (key)avatar_str;
    if (avatar != expected_user) return;

    integer level = (integer)level_str;
    
    // Toggle immediately with this ACL level
    toggle_public_access(avatar, level);
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        PublicModeEnabled = FALSE;
        
        register_self();
        
        // Request settings
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
                apply_settings_delta(msg);
                return;
            }
            
            return;
        }
        
        /* -------------------- UI DIRECT TOGGLE -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "start") {
                string context = llJsonGetValue(msg, ["context"]);
                if (context == JSON_INVALID || context != PLUGIN_CONTEXT) return;
                
                if (id == NULL_KEY) return;
                
                // Request ACL and toggle
                request_acl_and_toggle(id);
                return;
            }
            
            return;
        }
        
        /* -------------------- ACL RESULTS -------------------- */if (num == AUTH_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "acl_result") {
                string correlation = llJsonGetValue(msg, ["id"]);
                if (correlation == JSON_INVALID) return;

                if (correlation == PLUGIN_CONTEXT + "_toggle") {
                    string user_str = llJsonGetValue(msg, ["avatar"]);
                    if (user_str == JSON_INVALID) return;
                    key user = (key)user_str;
                    handle_acl_result(msg, user);
                }
                return;
            }
            
            return;
        }
    }
}
