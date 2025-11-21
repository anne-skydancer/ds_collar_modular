/*--------------------
PLUGIN: ds_collar_plugin_blacklist.lsl
VERSION: 1.00
REVISION: 21
PURPOSE: Blacklist management with sensor-based avatar selection
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Added nearby avatar sensor flow for quick blacklist additions
- Supports removing entries and persisting updates via settings module
- Handles JSON array and legacy CSV formats for stored keys
- Restricts use to Owned and higher ACL levels for safety
- Integrates with kernel registration and heartbeat protocols
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_blacklist";
string PLUGIN_LABEL = "Blacklist";
integer PLUGIN_MIN_ACL = 2;  // Owned minimum

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* -------------------- ACL REQUIREMENTS -------------------- */
list ALLOWED_ACL_LEVELS = [2, 3, 4, 5];  // Owned+

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_BLACKLIST = "blacklist";

/* -------------------- UI CONSTANTS -------------------- */
string BTN_BACK = "Back";
string BTN_ADD = "+Blacklist";
string BTN_REMOVE = "-Blacklist";
float BLACKLIST_RADIUS = 5.0;

/* -------------------- STATE -------------------- */
// Settings cache
list Blacklist = [];

// Session management
key CurrentUser = NULL_KEY;
integer CurrentUserAcl = -999;
string SessionId = "";
string MenuContext = "";  // "main", "add_scan", "add_pick", "remove"

// Sensor results
list CandidateKeys = [];

/* -------------------- HELPERS -------------------- */


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return "blacklist_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

integer in_allowed_levels(integer level) {
    return (llListFindList(ALLOWED_ACL_LEVELS, [level]) != -1);
}

list blacklist_names() {
    list out = [];
    integer i = 0;
    integer count = llGetListLength(Blacklist);
    while (i < count) {
        key k = (key)llList2String(Blacklist, i);
        string nm = llGetDisplayName(k);
        if (nm == "") nm = (string)k;
        out += [nm];
        i += 1;
    }
    return out;
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
    apply_blacklist_payload(kv_json);
}

apply_settings_delta(string msg) {
    if (!json_has(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (json_has(changes, [KEY_BLACKLIST])) {
            string new_value = llJsonGetValue(changes, [KEY_BLACKLIST]);
            parse_blacklist_value(new_value);
        }
    }
    else if (op == "list_add") {
        if (!json_has(msg, ["key"])) return;
        if (!json_has(msg, ["elem"])) return;
        
        string setting_key = llJsonGetValue(msg, ["key"]);
        if (setting_key == KEY_BLACKLIST) {
            string elem = llJsonGetValue(msg, ["elem"]);
            if (llListFindList(Blacklist, [elem]) == -1) {
                Blacklist += [elem];
            }
        }
    }
    else if (op == "list_remove") {
        if (!json_has(msg, ["key"])) return;
        if (!json_has(msg, ["elem"])) return;
        
        string setting_key = llJsonGetValue(msg, ["key"]);
        if (setting_key == KEY_BLACKLIST) {
            string elem = llJsonGetValue(msg, ["elem"]);
            integer idx = llListFindList(Blacklist, [elem]);
            if (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
            }
        }
    }
}

apply_blacklist_payload(string kv_json) {
    if (!json_has(kv_json, [KEY_BLACKLIST])) {
        Blacklist = [];
        return;
    }
    
    string raw = llJsonGetValue(kv_json, [KEY_BLACKLIST]);
    parse_blacklist_value(raw);
}

parse_blacklist_value(string raw) {
    if (raw == JSON_INVALID || raw == "[]" || raw == "" || raw == " ") {
        Blacklist = [];
        return;
    }
    
    // Try JSON array format first
    if (llGetSubString(raw, 0, 0) == "[") {
        list parsed = llJson2List(raw);
        list updated = [];
        integer i = 0;
        integer count = llGetListLength(parsed);
        while (i < count) {
            string val = llList2String(parsed, i);
            if (val != "" && llListFindList(updated, [val]) == -1) {
                updated += [val];
            }
            i += 1;
        }
        Blacklist = updated;
        return;
    }
    
    // Fall back to legacy CSV format
    list csv = llParseStringKeepNulls(raw, [","], []);
    list updated = [];
    integer j = 0;
    integer csv_len = llGetListLength(csv);
    while (j < csv_len) {
        string entry = llStringTrim(llList2String(csv, j), STRING_TRIM);
        if (entry != "" && llListFindList(updated, [entry]) == -1) {
            updated += [entry];
        }
        j += 1;
    }
    Blacklist = updated;
}

persist_blacklist() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_BLACKLIST,
        "values", llList2Json(JSON_ARRAY, Blacklist)
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
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
    
    // Check access
    if (!in_allowed_levels(level)) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        return_to_root();
        return;
    }
    
    show_main_menu();
}

/* -------------------- MENU DISPLAY -------------------- */

show_main_menu() {
    integer count = llGetListLength(Blacklist);
    string body = "Blacklist Management\n\n";
    body += "Currently blacklisted: " + (string)count;
    
    list buttons = [
        BTN_BACK,
        BTN_ADD,
        BTN_REMOVE
    ];
    
    SessionId = generate_session_id();
    MenuContext = "main";
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Blacklist",
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

show_remove_menu() {
    if (llGetListLength(Blacklist) == 0) {
        llRegionSayTo(CurrentUser, 0, "Blacklist is empty.");
        show_main_menu();
        return;
    }
    
    list names = blacklist_names();
    
    SessionId = generate_session_id();
    MenuContext = "remove";
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Remove from Blacklist",
        "prompt", "Select avatar to remove:",
        "items", llList2Json(JSON_ARRAY, names),
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

show_add_candidates() {
    if (llGetListLength(CandidateKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        show_main_menu();
        return;
    }
    
    // Build list of names
    list names = [];
    integer i = 0;
    integer len = llGetListLength(CandidateKeys);
    while (i < len && i < 11) {
        key k = (key)llList2String(CandidateKeys, i);
        string name = llGetDisplayName(k);
        if (name == "") name = (string)k;
        names += [name];
        i += 1;
    }
    
    SessionId = generate_session_id();
    MenuContext = "add_pick";
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Add to Blacklist",
        "prompt", "Select avatar to blacklist:",
        "items", llList2Json(JSON_ARRAY, names),
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
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
    CurrentUser = NULL_KEY;
    CurrentUserAcl = -999;
    SessionId = "";
    MenuContext = "";
    CandidateKeys = [];
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (!json_has(msg, ["button"])) return;
    
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    
    string button = llJsonGetValue(msg, ["button"]);
    
    // Re-validate ACL
    if (!in_allowed_levels(CurrentUserAcl)) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        return_to_root();
        return;
    }
    
    // Handle Back button
    if (button == BTN_BACK) {
        if (MenuContext == "main") {
            return_to_root();
            return;
        }
        show_main_menu();
        return;
    }
    
    // Main menu actions
    if (MenuContext == "main") {
        if (button == BTN_ADD) {
            MenuContext = "add_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, BLACKLIST_RADIUS, PI);
            return;
        }
        if (button == BTN_REMOVE) {
            show_remove_menu();
            return;
        }
    }
    
    // Remove menu - numbered selection
    if (MenuContext == "remove") {
        integer idx = (integer)button - 1;
        if (idx >= 0 && idx < llGetListLength(Blacklist)) {
            Blacklist = llDeleteSubList(Blacklist, idx, idx);
            persist_blacklist();
            llRegionSayTo(CurrentUser, 0, "Removed from blacklist.");
        }
        show_main_menu();
        return;
    }
    
    // Add pick menu - numbered selection
    if (MenuContext == "add_pick") {
        integer idx = (integer)button - 1;
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            string entry = llList2String(CandidateKeys, idx);
            if (entry != "" && llListFindList(Blacklist, [entry]) == -1) {
                Blacklist += [entry];
                persist_blacklist();
                llRegionSayTo(CurrentUser, 0, "Added to blacklist.");
            }
        }
        show_main_menu();
        return;
    }
    
    // Unknown context - return to main
    show_main_menu();
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
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        /* -------------------- KERNEL LIFECYCLE -------------------- */
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
        
        /* -------------------- SETTINGS BUS -------------------- */
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
        
        /* -------------------- UI START -------------------- */
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
        
        /* -------------------- AUTH RESULT -------------------- */
        if (num == AUTH_BUS) {
            if (msg_type == "acl_result") {
                handle_acl_result(msg);
                return;
            }
            
            return;
        }
        
        /* -------------------- DIALOG RESPONSES -------------------- */
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
    
    sensor(integer count) {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;
        
        list candidates = [];
        key owner = llGetOwner();
        integer i = 0;
        
        while (i < count) {
            key k = llDetectedKey(i);
            string entry = (string)k;
            
            if (k != owner && llListFindList(Blacklist, [entry]) == -1) {
                candidates += [entry];
            }
            i += 1;
        }
        
        CandidateKeys = candidates;
        show_add_candidates();
    }
    
    no_sensor() {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;
        
        CandidateKeys = [];
        show_add_candidates();
    }
}
