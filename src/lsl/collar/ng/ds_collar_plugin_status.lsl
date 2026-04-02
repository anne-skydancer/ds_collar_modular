/*--------------------
PLUGIN: ds_collar_plugin_status.lsl
VERSION: 1.00
REVISION: 25
PURPOSE: Read-only collar status display for owners and observers
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- REVISION 25: Trustees and owner_honorifics parsed as JSON objects {uuid:honorific}
- REVISION 24: Added trustee display name resolution via async dataserver queries
- REVISION 23: Fixed request_settings_sync to use correct "settings_get" message type
- REVISION 22: Added request_settings_sync() call on state_entry for independent reset recovery
- Consolidates status presentation into single dialog page
- Renders owner and trustee lists with honorific annotations
- Reflects public, lock, and TPE modes from settings cache
- Resolves avatar display names asynchronously for readability
- Supports multi-owner mode by tracking ordered owner sets
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_status";
string PLUGIN_LABEL = "Status";
integer PLUGIN_MIN_ACL = 1;  // Public can view

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_OWNERS = "owners";
string KEY_TRUSTEES = "trustees";
string KEY_BLACKLIST = "blacklist";
string KEY_PUBLIC_ACCESS = "public_mode";
string KEY_LOCKED = "locked";
string KEY_TPE_MODE = "tpe_mode";

/* -------------------- STATE -------------------- */
// Settings cache
list OwnerKeys = [];
string OwnersJson = "{}";
list TrusteeKeys = [];
string TrusteesJson = "{}";
list BlacklistKeys = [];
integer PublicAccess = FALSE;
integer Locked = FALSE;
integer TpeMode = FALSE;

// Owner display names
list OwnerDisplayNames = [];
list OwnerNameQueries = [];

// Trustee display names
list TrusteeDisplayNames = [];
list TrusteeNameQueries = [];

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

request_settings_sync() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

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
    
    list previous_owners = OwnerKeys;

    // Reset to defaults
    OwnerKeys = [];
    OwnersJson = "{}";
    TrusteeKeys = [];
    TrusteesJson = "{}";
    BlacklistKeys = [];
    PublicAccess = FALSE;
    Locked = FALSE;
    TpeMode = FALSE;
    
    // Load values
    if (json_has(kv_json, [KEY_OWNERS])) {
        string raw = llJsonGetValue(kv_json, [KEY_OWNERS]);
        if (llJsonValueType(raw, []) == JSON_OBJECT) {
            OwnersJson = raw;
            list pairs = llJson2List(raw);
            integer pi = 0;
            integer plen = llGetListLength(pairs);
            while (pi < plen) {
                OwnerKeys += [llList2String(pairs, pi)];
                pi += 2;
            }
        }
    }

    if (json_has(kv_json, [KEY_TRUSTEES])) {
        string trustees_raw = llJsonGetValue(kv_json, [KEY_TRUSTEES]);
        if (llJsonValueType(trustees_raw, []) == JSON_OBJECT) {
            TrusteesJson = trustees_raw;
            list pairs = llJson2List(trustees_raw);
            TrusteeKeys = [];
            integer pi = 0;
            integer plen = llGetListLength(pairs);
            while (pi < plen) {
                TrusteeKeys += [llList2String(pairs, pi)];
                pi += 2;
            }
        }
        else if (is_json_arr(trustees_raw)) {
            TrusteeKeys = llJson2List(trustees_raw);
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
    if (OwnerKeys != previous_owners) {
        request_owner_names();
    }

    // Always refresh trustee names on full sync
    request_trustee_names();
}

apply_settings_delta(string msg) {
    if (!json_has(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (json_has(changes, [KEY_OWNERS])) {
            string raw = llJsonGetValue(changes, [KEY_OWNERS]);
            OwnersJson = "{}";
            OwnerKeys = [];
            if (llJsonValueType(raw, []) == JSON_OBJECT) {
                OwnersJson = raw;
                list pairs = llJson2List(raw);
                integer pi = 0;
                integer plen = llGetListLength(pairs);
                while (pi < plen) {
                    OwnerKeys += [llList2String(pairs, pi)];
                    pi += 2;
                }
            }
            request_owner_names();
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
        
        // Trustees changed (full JSON object broadcast)
        if (json_has(changes, [KEY_TRUSTEES])) {
            string trustees_raw = llJsonGetValue(changes, [KEY_TRUSTEES]);
            if (llJsonValueType(trustees_raw, []) == JSON_OBJECT) {
                TrusteesJson = trustees_raw;
                list pairs = llJson2List(trustees_raw);
                TrusteeKeys = [];
                integer ti = 0;
                integer tlen = llGetListLength(pairs);
                while (ti < tlen) {
                    TrusteeKeys += [llList2String(pairs, ti)];
                    ti += 2;
                }
                request_trustee_names();
            }
        }

    }
}

/* -------------------- OWNER NAME RESOLUTION -------------------- */

request_owner_names() {
    OwnerDisplayNames = [];
    OwnerNameQueries = [];

    integer i;
    integer count = llGetListLength(OwnerKeys);
    for (i = 0; i < count; i++) {
        key owner_key = llList2Key(OwnerKeys, i);
        OwnerDisplayNames += [""];  // Placeholder aligned with OwnerKeys
        if (owner_key != NULL_KEY) {
            key query_id = llRequestDisplayName(owner_key);
            OwnerNameQueries += [query_id];
        }
        else {
            OwnerNameQueries += [NULL_KEY];
        }
    }
}

request_trustee_names() {
    TrusteeDisplayNames = [];
    TrusteeNameQueries = [];

    integer i;
    integer count = llGetListLength(TrusteeKeys);
    for (i = 0; i < count; i++) {
        key trustee_key = llList2Key(TrusteeKeys, i);
        TrusteeDisplayNames += [""];  // Placeholder aligned with TrusteeKeys
        if (trustee_key != NULL_KEY) {
            key query_id = llRequestDisplayName(trustee_key);
            TrusteeNameQueries += [query_id];
        }
        else {
            TrusteeNameQueries += [NULL_KEY];
        }
    }
}

/* -------------------- STATUS REPORT BUILDING -------------------- */

string build_status_report() {
    string status_text = "Collar Status:\n\n";
    
    // Owner information
    integer owner_count = llGetListLength(OwnerKeys);
    if (owner_count > 0) {
        if (owner_count == 1) {
            status_text += "Owner: ";
        }
        else {
            status_text += "Owners:\n";
        }

        integer i;
        integer disp_count = llGetListLength(OwnerDisplayNames);
        for (i = 0; i < owner_count; i++) {
            key owner_key = llList2Key(OwnerKeys, i);
            string honorific = llJsonGetValue(OwnersJson, [(string)owner_key]);
            if (honorific == JSON_INVALID) honorific = "";

            string display_name = "";
            if (i < disp_count) {
                display_name = llList2String(OwnerDisplayNames, i);
            }

            if (display_name == "") {
                display_name = llKey2Name(owner_key);
            }

            if (owner_count == 1) {
                if (honorific != "") {
                    status_text += honorific + " " + display_name + "\n";
                }
                else {
                    status_text += display_name + "\n";
                }
            }
            else {
                if (honorific != "") {
                    status_text += "  " + honorific + " " + display_name + "\n";
                }
                else {
                    status_text += "  " + display_name + "\n";
                }
            }
        }
    }
    else {
        status_text += "Owner: Uncommitted\n";
    }
    
    // Trustee information
    integer trustee_count = llGetListLength(TrusteeKeys);
    if (trustee_count > 0) {
        status_text += "Trustees:\n";

        integer i;
        integer tdisp_count = llGetListLength(TrusteeDisplayNames);
        for (i = 0; i < trustee_count; i++) {
            key trustee_key = llList2Key(TrusteeKeys, i);
            string honorific = llJsonGetValue(TrusteesJson, [(string)trustee_key]);
            if (honorific == JSON_INVALID) honorific = "";

            string display_name = "";
            if (i < tdisp_count) {
                display_name = llList2String(TrusteeDisplayNames, i);
            }

            if (display_name == "") {
                display_name = llKey2Name(trustee_key);
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
        OwnerDisplayNames = [];
        OwnerNameQueries = [];
        TrusteeDisplayNames = [];
        TrusteeNameQueries = [];

        register_self();
        request_settings_sync();
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
        // Check trustee name queries first
        integer tidx = llListFindList(TrusteeNameQueries, [query_id]);
        if (tidx != -1) {
            if (tidx < llGetListLength(TrusteeDisplayNames)) {
                TrusteeDisplayNames = llListReplaceList(TrusteeDisplayNames, [data], tidx, tidx);
            }
            return;
        }

        // Owner name queries
        integer idx = llListFindList(OwnerNameQueries, [query_id]);
        if (idx != -1) {
            if (idx < llGetListLength(OwnerDisplayNames)) {
                OwnerDisplayNames = llListReplaceList(OwnerDisplayNames, [data], idx, idx);
            }
        }
    }
}
