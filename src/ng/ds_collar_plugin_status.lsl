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
string SCRIPT_ID = "plugin_status";
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

integer DEBUG = TRUE;

integer logd(string msg) {
    if (DEBUG) llOwnerSay("[STATUS] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- ROUTING HELPERS -------------------- */

integer is_message_for_me(string msg) {
    if (!json_has(msg, ["to"])) return FALSE;  // STRICT: No "to" field = reject
    string to = llJsonGetValue(msg, ["to"]);
    if (to == SCRIPT_ID) return TRUE;  // STRICT: Accept ONLY exact SCRIPT_ID match
    return FALSE;  // STRICT: Reject everything else (broadcasts, wildcards, variants)
}

string create_routed_message(string to_id, list fields) {
    return llList2Json(JSON_OBJECT, ["from", SCRIPT_ID, "to", to_id] + fields);
}

string create_broadcast(list fields) {
    return create_routed_message("*", fields);
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
    // PHASE 2: Read directly from linkset data
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
    
    // Load values from linkset data
    string val_multi = llLinksetDataRead(KEY_MULTI_OWNER_MODE);
    if (val_multi != "") {
        MultiOwnerMode = (integer)val_multi;
    }
    
    string val_owner_key = llLinksetDataRead(KEY_OWNER_KEY);
    if (val_owner_key != "") {
        OwnerKey = (key)val_owner_key;
    }
    
    string val_owner_keys = llLinksetDataRead(KEY_OWNER_KEYS);
    if (val_owner_keys != "" && is_json_arr(val_owner_keys)) {
        OwnerKeys = llJson2List(val_owner_keys);
    }
    
    string val_owner_hon = llLinksetDataRead(KEY_OWNER_HON);
    if (val_owner_hon != "") OwnerHonorific = val_owner_hon;
    
    string val_owner_hons = llLinksetDataRead(KEY_OWNER_HONS);
    if (val_owner_hons != "" && is_json_arr(val_owner_hons)) {
        OwnerHonorifics = llJson2List(val_owner_hons);
    }
    
    string val_trustees = llLinksetDataRead(KEY_TRUSTEES);
    if (val_trustees != "" && is_json_arr(val_trustees)) {
        TrusteeKeys = llJson2List(val_trustees);
    }
    
    string val_trustee_hons = llLinksetDataRead(KEY_TRUSTEE_HONS);
    if (val_trustee_hons != "" && is_json_arr(val_trustee_hons)) {
        TrusteeHonorifics = llJson2List(val_trustee_hons);
    }
    
    string val_blacklist = llLinksetDataRead(KEY_BLACKLIST);
    if (val_blacklist != "" && is_json_arr(val_blacklist)) {
        BlacklistKeys = llJson2List(val_blacklist);
    }
    
    string val_public = llLinksetDataRead(KEY_PUBLIC_ACCESS);
    if (val_public != "") {
        PublicAccess = (integer)val_public;
    }
    
    string val_locked = llLinksetDataRead(KEY_LOCKED);
    if (val_locked != "") {
        Locked = (integer)val_locked;
    }
    
    string val_tpe = llLinksetDataRead(KEY_TPE_MODE);
    if (val_tpe != "") {
        TpeMode = (integer)val_tpe;
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
    // PHASE 2: Simplified - just re-read affected key from linkset data
    if (!json_has(msg, ["key"])) return;
    
    string key_name = llJsonGetValue(msg, ["key"]);
    integer needs_refresh = FALSE;
    
    if (key_name == KEY_MULTI_OWNER_MODE) {
        string val = llLinksetDataRead(KEY_MULTI_OWNER_MODE);
        if (val != "") MultiOwnerMode = (integer)val;
        needs_refresh = TRUE;
    }
    else if (key_name == KEY_OWNER_KEY) {
        string val = llLinksetDataRead(KEY_OWNER_KEY);
        if (val != "") OwnerKey = (key)val;
        needs_refresh = TRUE;
    }
    else if (key_name == KEY_OWNER_HON) {
        string val = llLinksetDataRead(KEY_OWNER_HON);
        if (val != "") OwnerHonorific = val;
    }
    else if (key_name == KEY_OWNER_KEYS) {
        string val = llLinksetDataRead(KEY_OWNER_KEYS);
        if (val != "" && is_json_arr(val)) {
            OwnerKeys = llJson2List(val);
            needs_refresh = TRUE;
        }
    }
    else if (key_name == KEY_OWNER_HONS) {
        string val = llLinksetDataRead(KEY_OWNER_HONS);
        if (val != "" && is_json_arr(val)) {
            OwnerHonorifics = llJson2List(val);
        }
    }
    else if (key_name == KEY_TRUSTEES) {
        string val = llLinksetDataRead(KEY_TRUSTEES);
        if (val != "" && is_json_arr(val)) {
            TrusteeKeys = llJson2List(val);
        }
    }
    else if (key_name == KEY_TRUSTEE_HONS) {
        string val = llLinksetDataRead(KEY_TRUSTEE_HONS);
        if (val != "" && is_json_arr(val)) {
            TrusteeHonorifics = llJson2List(val);
        }
    }
    else if (key_name == KEY_BLACKLIST) {
        string val = llLinksetDataRead(KEY_BLACKLIST);
        if (val != "" && is_json_arr(val)) {
            BlacklistKeys = llJson2List(val);
        }
    }
    else if (key_name == KEY_PUBLIC_ACCESS) {
        string val = llLinksetDataRead(KEY_PUBLIC_ACCESS);
        if (val != "") PublicAccess = (integer)val;
    }
    else if (key_name == KEY_LOCKED) {
        string val = llLinksetDataRead(KEY_LOCKED);
        if (val != "") Locked = (integer)val;
    }
    else if (key_name == KEY_TPE_MODE) {
        string val = llLinksetDataRead(KEY_TPE_MODE);
        if (val != "") TpeMode = (integer)val;
    }
    
    if (needs_refresh) {
        request_owner_names();
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
    string msg = create_routed_message("kmod_ui", [
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
        // ROUTING FILTER: Reject messages not addressed to us
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
