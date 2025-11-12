/*--------------------
PLUGIN: ds_collar_plugin_status.lsl
VERSION: 1.00
REVISION: 20
PURPOSE: Read-only collar status display for owners and observers
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Consolidates status presentation into single dialog page
- Renders owner and trustee lists with honorific annotations
- Reflects public, lock, and TPE modes from settings cache
- Resolves avatar display names asynchronously for readability
- Supports multi-owner mode by tracking ordered owner sets
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_status";
string PLUGIN_LABEL = "Status";
integer PLUGIN_MIN_ACL = 1;  // Public can view
string ROOT_CONTEXT = "core_root";

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_KEYS = "owner_keys";
string KEY_OWNER_HON = "owner_hon";
string KEY_OWNER_HONS = "owner_honorifics";
string KEY_TRUSTEES = "trustees";
string KEY_TRUSTEE_HONS = "trustee_honorifics";
string KEY_BLACKLIST = "blacklist";
string KEY_PUBLIC_ACCESS = "public_mode";
string KEY_LOCKED = "locked";
string KEY_TPE_MODE = "tpe_mode";

/* -------------------- STATE -------------------- */
// Settings cache
integer MultiOwnerMode = FALSE;
key OwnerKey = NULL_KEY;
list OwnerKeys = [];
string OwnerHonorific = "";
list OwnerHonorifics = [];
list TrusteeKeys = [];
list TrusteeHonorifics = [];
list BlacklistKeys = [];
integer PublicAccess = FALSE;
integer Locked = FALSE;
integer TpeMode = FALSE;

// Display name resolution
string OwnerDisplay = "";
key OwnerDisplayQuery = NULL_KEY;
key OwnerLegacyQuery = NULL_KEY;

// Multi-owner display names
list OwnerDisplayNames = [];
list OwnerNameQueries = [];

// Session management
key CurrentUser = NULL_KEY;
string SessionId = "";

/* -------------------- HELPERS -------------------- */


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

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

/* -------------------- SETTINGS CONSUMPTION -------------------- */

apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    
    integer previous_mode = MultiOwnerMode;
    key previous_owner = OwnerKey;
    list previous_owners = OwnerKeys;
    
    // Reset to defaults
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    OwnerHonorific = "";
    OwnerHonorifics = [];
    TrusteeKeys = [];
    TrusteeHonorifics = [];
    BlacklistKeys = [];
    PublicAccess = FALSE;
    Locked = FALSE;
    TpeMode = FALSE;
    
    // Load values
    if (json_has(kv_json, [KEY_MULTI_OWNER_MODE])) {
        MultiOwnerMode = (integer)llJsonGetValue(kv_json, [KEY_MULTI_OWNER_MODE]);
    }
    
    if (json_has(kv_json, [KEY_OWNER_KEY])) {
        string owner_str = llJsonGetValue(kv_json, [KEY_OWNER_KEY]);
        OwnerKey = (key)owner_str;
    }
    
    if (json_has(kv_json, [KEY_OWNER_KEYS])) {
        string owner_keys_json = llJsonGetValue(kv_json, [KEY_OWNER_KEYS]);
        if (is_json_arr(owner_keys_json)) {
            OwnerKeys = llJson2List(owner_keys_json);
        }
    }
    
    if (json_has(kv_json, [KEY_OWNER_HON])) {
        OwnerHonorific = llJsonGetValue(kv_json, [KEY_OWNER_HON]);
    }
    
    if (json_has(kv_json, [KEY_OWNER_HONS])) {
        string hon_json = llJsonGetValue(kv_json, [KEY_OWNER_HONS]);
        if (is_json_arr(hon_json)) {
            OwnerHonorifics = llJson2List(hon_json);
        }
    }
    
    if (json_has(kv_json, [KEY_TRUSTEES])) {
        string trustees_json = llJsonGetValue(kv_json, [KEY_TRUSTEES]);
        if (is_json_arr(trustees_json)) {
            TrusteeKeys = llJson2List(trustees_json);
        }
    }
    
    if (json_has(kv_json, [KEY_TRUSTEE_HONS])) {
        string hon_json = llJsonGetValue(kv_json, [KEY_TRUSTEE_HONS]);
        if (is_json_arr(hon_json)) {
            TrusteeHonorifics = llJson2List(hon_json);
        }
    }
    
    if (json_has(kv_json, [KEY_BLACKLIST])) {
        string blacklist_json = llJsonGetValue(kv_json, [KEY_BLACKLIST]);
        if (is_json_arr(blacklist_json)) {
            BlacklistKeys = llJson2List(blacklist_json);
        }
    }
    
    if (json_has(kv_json, [KEY_PUBLIC_ACCESS])) {
        PublicAccess = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_ACCESS]);
    }
    
    if (json_has(kv_json, [KEY_LOCKED])) {
        Locked = (integer)llJsonGetValue(kv_json, [KEY_LOCKED]);
    }
    
    if (json_has(kv_json, [KEY_TPE_MODE])) {
        TpeMode = (integer)llJsonGetValue(kv_json, [KEY_TPE_MODE]);
    }
    
    // Check if we need to refresh owner names
    integer needs_refresh = FALSE;
    
    if (MultiOwnerMode != previous_mode) {
        needs_refresh = TRUE;
    }
    else if (MultiOwnerMode) {
        if (OwnerKeys != previous_owners) {
            needs_refresh = TRUE;
        }
    }
    else {
        if (OwnerKey != previous_owner) {
            needs_refresh = TRUE;
        }
    }
    
    if (needs_refresh) {
        request_owner_names();
    }
}

apply_settings_delta(string msg) {
    if (!json_has(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        integer needs_refresh = FALSE;
        
        if (json_has(changes, [KEY_MULTI_OWNER_MODE])) {
            MultiOwnerMode = (integer)llJsonGetValue(changes, [KEY_MULTI_OWNER_MODE]);
            needs_refresh = TRUE;
        }
        
        if (json_has(changes, [KEY_OWNER_KEY])) {
            OwnerKey = (key)llJsonGetValue(changes, [KEY_OWNER_KEY]);
            needs_refresh = TRUE;
        }
        
        if (json_has(changes, [KEY_OWNER_HON])) {
            OwnerHonorific = llJsonGetValue(changes, [KEY_OWNER_HON]);
        }
        
        if (json_has(changes, [KEY_PUBLIC_ACCESS])) {
            PublicAccess = (integer)llJsonGetValue(changes, [KEY_PUBLIC_ACCESS]);
        }
        
        if (json_has(changes, [KEY_LOCKED])) {
            Locked = (integer)llJsonGetValue(changes, [KEY_LOCKED]);
        }
        
        if (json_has(changes, [KEY_TPE_MODE])) {
            TpeMode = (integer)llJsonGetValue(changes, [KEY_TPE_MODE]);
        }
        
        if (needs_refresh) {
            request_owner_names();
        }
    }
    else if (op == "list_add" || op == "list_remove") {
        if (!json_has(msg, ["key"])) return;
        string list_key = llJsonGetValue(msg, ["key"]);
        
        if (list_key == KEY_OWNER_KEYS || list_key == KEY_TRUSTEES || 
            list_key == KEY_OWNER_HONS || list_key == KEY_TRUSTEE_HONS) {
            // Request full sync to refresh lists
        }
    }
}

/* -------------------- OWNER NAME RESOLUTION -------------------- */

request_owner_names() {
    if (MultiOwnerMode) {
        OwnerDisplayNames = [];
        OwnerNameQueries = [];
        
        integer i;
        integer count = llGetListLength(OwnerKeys);
        for (i = 0; i < count; i++) {
            key owner_key = llList2Key(OwnerKeys, i);
            if (owner_key != NULL_KEY) {
                key query_id = llRequestDisplayName(owner_key);
                OwnerNameQueries += [query_id];
                OwnerDisplayNames += [""];  // Placeholder
            }
        }
        
    }
    else {
        if (OwnerKey != NULL_KEY) {
            OwnerDisplay = "";
            OwnerDisplayQuery = llRequestDisplayName(OwnerKey);
            OwnerLegacyQuery = llRequestAgentData(OwnerKey, DATA_NAME);
        }
        else {
            OwnerDisplay = "";
            OwnerDisplayQuery = NULL_KEY;
            OwnerLegacyQuery = NULL_KEY;
        }
    }
}

string get_owner_label() {
    if (OwnerDisplay != "") {
        return OwnerDisplay;
    }
    else if (OwnerKey != NULL_KEY) {
        return llKey2Name(OwnerKey);
    }
    else {
        return "(unowned)";
    }
}

/* -------------------- STATUS REPORT BUILDING -------------------- */

string build_status_report() {
    string status_text = "Collar Status:\n\n";
    
    // Owner information
    if (MultiOwnerMode) {
        integer owner_count = llGetListLength(OwnerKeys);
        if (owner_count > 0) {
            status_text += "Owners:\n";
            
            integer i;
            for (i = 0; i < owner_count; i++) {
                key owner_key = llList2Key(OwnerKeys, i);
                string honorific = "";
                
                if (i < llGetListLength(OwnerHonorifics)) {
                    honorific = llList2String(OwnerHonorifics, i);
                }
                
                string display_name = "";
                if (i < llGetListLength(OwnerDisplayNames)) {
                    display_name = llList2String(OwnerDisplayNames, i);
                }
                
                if (display_name == "") {
                    display_name = llKey2Name(owner_key);
                }
                
                if (honorific != "") {
                    status_text += "  " + honorific + " " + display_name + "\n";
                }
                else {
                    status_text += "  " + display_name + "\n";
                }
            }
        }
        else {
            status_text += "Owners: Uncommitted\n";
        }
    }
    else {
        if (OwnerKey != NULL_KEY) {
            string owner_label = get_owner_label();
            if (OwnerHonorific != "") {
                status_text += "Owner: " + OwnerHonorific + " " + owner_label + "\n";
            }
            else {
                status_text += "Owner: " + owner_label + "\n";
            }
        }
        else {
            status_text += "Owner: Uncommitted\n";
        }
    }
    
    // Trustee information
    integer trustee_count = llGetListLength(TrusteeKeys);
    if (trustee_count > 0) {
        status_text += "Trustees: ";
        
        integer i;
        for (i = 0; i < trustee_count; i++) {
            if (i != 0) {
                status_text += ", ";
            }
            
            string honorific = "";
            if (i < llGetListLength(TrusteeHonorifics)) {
                honorific = llList2String(TrusteeHonorifics, i);
            }
            
            if (honorific == "") {
                honorific = "trustee";
            }
            
            status_text += honorific;
        }
        status_text += "\n";
    }
    else {
        status_text += "Trustees: none\n";
    }
    
    // Public access
    if (PublicAccess) {
        status_text += "Public Access: On\n";
    }
    else {
        status_text += "Public Access: Off\n";
    }
    
    // Lock status
    if (Locked) {
        status_text += "Collar locked: Yes\n";
    }
    else {
        status_text += "Collar locked: No\n";
    }
    
    // TPE mode
    if (TpeMode) {
        status_text += "TPE Mode: On\n";
    }
    else {
        status_text += "TPE Mode: Off\n";
    }
    
    return status_text;
}

/* -------------------- UI / MENU SYSTEM -------------------- */

show_status_menu() {
    SessionId = generate_session_id();
    
    string status_report = build_status_report();
    
    list buttons = ["Back"];
    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "message", status_report,
        "buttons", buttons_json,
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string button) {
    if (button == "Back") {
        ui_return_root();
        cleanup_session();
        return;
    }
    
    // Unknown button - shouldn't happen
}

/* -------------------- UI NAVIGATION -------------------- */

ui_return_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- SESSION CLEANUP -------------------- */

cleanup_session() {
    CurrentUser = NULL_KEY;
    SessionId = "";
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        cleanup_session();
        
        // Reset display name cache
        OwnerDisplay = "";
        OwnerDisplayQuery = NULL_KEY;
        OwnerLegacyQuery = NULL_KEY;
        OwnerDisplayNames = [];
        OwnerNameQueries = [];
        
        register_self();
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
        
        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "start") {
                if (!json_has(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                
                if (id == NULL_KEY) return;
                
                CurrentUser = id;
                show_status_menu();
                return;
            }
            
            return;
        }
        
        /* -------------------- DIALOG RESPONSE -------------------- */if (num == DIALOG_BUS) {
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
                
                handle_button_click(button);
                return;
            }
            
            if (msg_type == "dialog_timeout") {
                if (!json_has(msg, ["session_id"])) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
                
                cleanup_session();
                return;
            }
            
            return;
        }
    }
    
    dataserver(key query_id, string data) {
        // Multi-owner mode
        if (MultiOwnerMode) {
            integer idx = llListFindList(OwnerNameQueries, [query_id]);
            if (idx != -1) {
                if (idx < llGetListLength(OwnerDisplayNames)) {
                    OwnerDisplayNames = llListReplaceList(OwnerDisplayNames, [data], idx, idx);
                }
            }
        }
        // Single owner mode
        else {
            if (query_id == OwnerDisplayQuery) {
                OwnerDisplay = data;
            }
            else if (query_id == OwnerLegacyQuery) {
                if (OwnerDisplay == "") {
                    OwnerDisplay = data;
                }
            }
        }
    }
}
