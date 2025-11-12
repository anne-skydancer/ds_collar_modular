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

integer DEBUG = TRUE;
integer PRODUCTION = FALSE;

string SCRIPT_ID = "plugin_public";

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
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[PUBLIC] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* -------------------- MESSAGE ROUTING -------------------- */

integer is_message_for_me(string msg) {
    if (llGetSubString(msg, 0, 0) != "{") return FALSE;
    integer to_pos = llSubStringIndex(msg, "\"to\"");
    if (to_pos == -1) return TRUE;
    string header = llGetSubString(msg, 0, to_pos + 100);
    if (llSubStringIndex(header, "\"*\"") != -1) return TRUE;
    if (llSubStringIndex(header, SCRIPT_ID) != -1) return TRUE;
    if (llSubStringIndex(header, "\"plugin:*\"") != -1) return TRUE;
    return FALSE;
}

string create_routed_message(string to_id, list fields) {
    list routed = ["from", SCRIPT_ID, "to", to_id] + fields;
    return llList2Json(JSON_OBJECT, routed);
}

string create_broadcast(list fields) {
    return create_routed_message("*", fields);
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
    logd("Registered with kernel as: " + label);
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
    // PHASE 2: Read directly from linkset data
    integer old_state = PublicModeEnabled;
    
    string val = llLinksetDataRead(KEY_PUBLIC_MODE);
    if (val != "") {
        PublicModeEnabled = (integer)val;
    }
    else {
        PublicModeEnabled = FALSE;
    }
    
    logd("Settings sync: public=" + (string)PublicModeEnabled);
    
    // If state changed, update label
    if (old_state != PublicModeEnabled) {
        register_self();
    }
}

apply_settings_delta(string msg) {
    // PHASE 2: Simplified - just re-read affected key from linkset data
    if (!json_has(msg, ["key"])) return;
    
    string key_name = llJsonGetValue(msg, ["key"]);
    
    if (key_name == KEY_PUBLIC_MODE) {
        integer old_state = PublicModeEnabled;
        string val = llLinksetDataRead(KEY_PUBLIC_MODE);
        if (val != "") {
            PublicModeEnabled = (integer)val;
        }
        else {
            PublicModeEnabled = FALSE;
        }
        logd("Delta: public_mode = " + (string)PublicModeEnabled);
        
        // If state changed, update label
        if (old_state != PublicModeEnabled) {
            register_self();
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
    logd("Persisting public_mode=" + (string)new_value);
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
    
    logd("Updated UI label to: " + new_label + " and returning to root");
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
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != expected_user) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    
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
        if (!is_message_for_me(msg)) return;
        
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
        
        /* -------------------- UI DIRECT TOGGLE -------------------- */if (num == UI_BUS) {
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
        
        /* -------------------- ACL RESULTS -------------------- */if (num == AUTH_BUS) {
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
