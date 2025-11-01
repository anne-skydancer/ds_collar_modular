/* =============================================================================
   DS Collar - Status Plugin (v2.0 - Kanban Messaging Migration)

   PURPOSE: Display collar status information (read-only)

   FEATURES:
   - Shows owner(s) with honorifics
   - Shows trustees with honorifics
   - Shows public access state
   - Shows lock state
   - Shows TPE mode state
   - Resolves display names via dataserver
   - Supports multi-owner mode

   KANBAN MIGRATION (v2.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "status";

/* ═══════════════════════════════════════════════════════════
   KANBAN UNIVERSAL HELPER (~500-800 bytes)
   ═══════════════════════════════════════════════════════════ */

string kFrom = "";  // Sender context (populated by kRecv)
string kTo = "";    // Recipient context (populated by kRecv)

kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, [
            "from", from,
            "payload", payload,
            "to", to
        ]),
        k
    );
}

string kRecv(string msg, string my_context) {
    // Quick validation: must be JSON object
    if (llGetSubString(msg, 0, 0) != "{") return "";

    // Extract from
    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    // Extract to
    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast "" or direct to my_context)
    if (to != "" && to != my_context) return "";

    // Extract payload
    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    // Set globals for routing
    kFrom = from;
    kTo = to;

    return payload;
}

string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

string kDeltaSet(string setting_key, string val) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", setting_key,
        "value", val
    ]);
}

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_LABEL = "Status";
integer PLUGIN_MIN_ACL = 1;  // Public can view

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
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

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
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

// ===== HELPERS =====
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[STATUS] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

string generate_session_id() {
    return CONTEXT + "_" + (string)llGetUnixTime();
}

// ===== PLUGIN REGISTRATION =====
register_self() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload([
            "label", PLUGIN_LABEL,
            "min_acl", PLUGIN_MIN_ACL,
            "script", llGetScriptName()
        ]),
        NULL_KEY
    );
}

send_pong() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload(["pong", 1]),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS CONSUMPTION
   ═══════════════════════════════════════════════════════════ */

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
    
    logd("Settings sync applied");
    
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
        string setting_key = llJsonGetValue(msg, ["key"]);

        if (setting_key == KEY_OWNER_KEYS || setting_key == KEY_TRUSTEES ||
            setting_key == KEY_OWNER_HONS || setting_key == KEY_TRUSTEE_HONS) {
            // Request full sync to refresh lists
            logd("List changed, requesting full sync");
        }
    }
}

/* ═══════════════════════════════════════════════════════════
   OWNER NAME RESOLUTION
   ═══════════════════════════════════════════════════════════ */

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
        
        logd("Requested " + (string)count + " display names");
    }
    else {
        if (OwnerKey != NULL_KEY) {
            OwnerDisplay = "";
            OwnerDisplayQuery = llRequestDisplayName(OwnerKey);
            OwnerLegacyQuery = llRequestAgentData(OwnerKey, DATA_NAME);
            logd("Requested owner display name");
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

/* ═══════════════════════════════════════════════════════════
   STATUS REPORT BUILDING
   ═══════════════════════════════════════════════════════════ */

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

// ===== UNIFIED MENU DISPLAY =====
show_status_menu() {
    SessionId = generate_session_id();

    string status_report = build_status_report();

    list buttons = ["Back"];

    kSend(CONTEXT, "dialogs", DIALOG_BUS,
        kPayload([
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", PLUGIN_LABEL,
            "body", status_report,
            "buttons", llList2Json(JSON_ARRAY, buttons),
            "timeout", 60
        ]),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   BUTTON HANDLING
   ═══════════════════════════════════════════════════════════ */

handle_button_click(string button) {
    if (button == "Back") {
        ui_return_root();
        cleanup_session();
        return;
    }
    
    // Unknown button - shouldn't happen
    logd("Unhandled button: " + button);
}

// ===== NAVIGATION =====
ui_return_root() {
    kSend(CONTEXT, "ui", UI_BUS,
        kPayload(["user", (string)CurrentUser]),
        NULL_KEY
    );
}

cleanup_session() {
    CurrentUser = NULL_KEY;
    SessionId = "";
    logd("Session cleaned up");
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

// ===== EVENT HANDLERS =====
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

        // Request settings from settings module
        kSend(CONTEXT, "settings", SETTINGS_BUS,
            kPayload(["get", 1]),
            NULL_KEY
        );

        logd("Status plugin initialized - requested settings");
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
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        // Route by channel + kFrom + payload structure

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE && kFrom == "kernel") {
            // Targeted soft_reset: has "context" field
            if (json_has(payload, ["context"])) {
                string target_context = llJsonGetValue(payload, ["context"]);
                if (target_context != "" && target_context != CONTEXT) {
                    return; // Not for us
                }
                llResetScript();
            }
            // Soft reset with "reset" marker
            else if (json_has(payload, ["reset"])) {
                llResetScript();
            }
            // Register now: has "register_now" marker
            else if (json_has(payload, ["register_now"])) {
                register_self();
            }
            // Ping: has "ping" marker
            else if (json_has(payload, ["ping"])) {
                send_pong();
            }
        }

        /* ===== SETTINGS BUS ===== */
        else if (num == SETTINGS_BUS && kFrom == "settings") {
            // Full sync: has "kv" field
            if (json_has(payload, ["kv"])) {
                apply_settings_sync(payload);
            }
            // Delta update: has "op" field
            else if (json_has(payload, ["op"])) {
                apply_settings_delta(payload);
            }
        }

        /* ===== UI START ===== */
        else if (num == UI_BUS) {
            // UI start: for our context
            if (kTo == CONTEXT && json_has(payload, ["user"])) {
                CurrentUser = id;
                show_status_menu();
            }
        }

        /* ===== DIALOG RESPONSE ===== */
        else if (num == DIALOG_BUS && kFrom == "dialogs") {
            // Dialog response: has "session_id" and "button" fields
            if (json_has(payload, ["session_id"]) && json_has(payload, ["button"])) {
                string response_session = llJsonGetValue(payload, ["session_id"]);
                if (response_session != SessionId) return;

                string button = llJsonGetValue(payload, ["button"]);
                handle_button_click(button);
            }
            // Dialog timeout: has "session_id" but no "button"
            else if (json_has(payload, ["session_id"]) && !json_has(payload, ["button"])) {
                string timeout_session = llJsonGetValue(payload, ["session_id"]);
                if (timeout_session != SessionId) return;

                logd("Dialog timeout");
                cleanup_session();
            }
        }
    }
    
    dataserver(key query_id, string data) {
        // Multi-owner mode
        if (MultiOwnerMode) {
            integer idx = llListFindList(OwnerNameQueries, [query_id]);
            if (idx != -1) {
                if (idx < llGetListLength(OwnerDisplayNames)) {
                    OwnerDisplayNames = llListReplaceList(OwnerDisplayNames, [data], idx, idx);
                    logd("Received display name: " + data);
                }
            }
        }
        // Single owner mode
        else {
            if (query_id == OwnerDisplayQuery) {
                OwnerDisplay = data;
                logd("Owner display name resolved: " + data);
            }
            else if (query_id == OwnerLegacyQuery) {
                if (OwnerDisplay == "") {
                    OwnerDisplay = data;
                    logd("Owner legacy name resolved: " + data);
                }
            }
        }
    }
}
