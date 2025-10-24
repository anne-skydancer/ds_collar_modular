/* =============================================================================
   MODULE: ds_collar_kmod_bootstrap.lsl (v2.1 - Enhanced Startup)
   
   ROLE: Startup coordination, RLV detection, owner name resolution
   
   FEATURES:
   - IM notifications during startup (visible to wearer)
   - Multi-channel RLV detection (4711, relay channels)
   - Accepts RLV responses from wearer OR NULL_KEY
   - Progressive status updates
   - Retry logic for RLV detection
   
   CHANNELS:
   - 500 (KERNEL_LIFECYCLE): Soft reset coordination
   - 700 (AUTH_BUS): ACL queries for wearer
   - 800 (SETTINGS_BUS): Initial settings request
   ============================================================================= */

integer DEBUG = TRUE;

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;

/* ═══════════════════════════════════════════════════════════
   RLV DETECTION CONFIG
   ═══════════════════════════════════════════════════════════ */
integer RLV_PROBE_TIMEOUT_SEC = 30;
integer RLV_RETRY_INTERVAL_SEC = 4;
integer RLV_MAX_RETRIES = 8;
integer RLV_INITIAL_DELAY_SEC = 1;

// Probe multiple channels for better compatibility
integer USE_FIXED_4711 = TRUE;
integer USE_RELAY_CHAN = TRUE;
integer RELAY_CHAN = -1812221819;
integer PROBE_RELAY_BOTH_SIGNS = TRUE;  // Also try positive relay channel

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_KEYS = "owner_keys";
string KEY_OWNER_HON = "owner_hon";
string KEY_OWNER_HONS = "owner_honorifics";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
integer BootstrapComplete = FALSE;

// RLV detection
list RlvChannels = [];          // List of channels we're listening on
list RlvListenHandles = [];     // Corresponding listen handles
integer RlvProbing = FALSE;
integer RlvActive = FALSE;
string RlvVersion = "";
integer RlvProbeDeadline = 0;
integer RlvNextRetry = 0;
integer RlvRetryCount = 0;
integer RlvReady = FALSE;

// Settings
integer SettingsReceived = FALSE;
integer MultiOwnerMode = FALSE;
key OwnerKey = NULL_KEY;
list OwnerKeys = [];
string OwnerHonorific = "";
list OwnerHonorifics = [];

// Name resolution
list OwnerNameQueries = [];
integer NAME_QUERY_STRIDE = 2;
list OwnerDisplayNames = [];

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[BOOTSTRAP] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

integer now() {
    return llGetUnixTime();
}

sendIM(string msg) {
    key wearer = llGetOwner();
    if (wearer != NULL_KEY && msg != "") {
        llInstantMessage(wearer, msg);
    }
}

integer isAttached() {
    return ((integer)llGetAttached() != 0);
}

/* ═══════════════════════════════════════════════════════════
   RLV DETECTION - Multi-Channel Approach
   ═══════════════════════════════════════════════════════════ */

addProbeChannel(integer ch) {
    if (ch == 0) return;
    if (llListFindList(RlvChannels, [ch]) != -1) return;  // Already added
    
    integer handle = llListen(ch, "", NULL_KEY, "");  // Accept from anyone (NULL_KEY important!)
    RlvChannels += [ch];
    RlvListenHandles += [handle];
    logd("RLV probe channel added: " + (string)ch);
}

clearProbeChannels() {
    integer i = 0;
    integer len = llGetListLength(RlvListenHandles);
    while (i < len) {
        integer handle = llList2Integer(RlvListenHandles, i);
        if (handle) llListenRemove(handle);
        i += 1;
    }
    RlvChannels = [];
    RlvListenHandles = [];
}

sendRlvQueries() {
    integer i = 0;
    integer len = llGetListLength(RlvChannels);
    while (i < len) {
        integer ch = llList2Integer(RlvChannels, i);
        llOwnerSay("@versionnew=" + (string)ch);
        i += 1;
    }
    logd("RLV @versionnew sent (attempt " + (string)(RlvRetryCount + 1) + ")");
}

start_rlv_probe() {
    if (RlvProbing) {
        logd("RLV probe already active");
        return;
    }
    
    if (!isAttached()) {
        // Not attached, can't detect RLV
        RlvReady = TRUE;
        RlvActive = FALSE;
        RlvVersion = "";
        logd("Not attached, skipping RLV detection");
        return;
    }
    
    RlvProbing = TRUE;
    RlvActive = FALSE;
    RlvVersion = "";
    RlvRetryCount = 0;
    RlvReady = FALSE;
    
    clearProbeChannels();
    
    // Set up multiple probe channels
    if (USE_FIXED_4711) addProbeChannel(4711);
    if (USE_RELAY_CHAN) {
        addProbeChannel(RELAY_CHAN);
        if (PROBE_RELAY_BOTH_SIGNS) {
            addProbeChannel(-RELAY_CHAN);  // Try opposite sign too
        }
    }
    
    RlvProbeDeadline = now() + RLV_PROBE_TIMEOUT_SEC;
    RlvNextRetry = now() + RLV_INITIAL_DELAY_SEC;  // Initial delay before first probe
    
    logd("RLV probe started on " + (string)llGetListLength(RlvChannels) + " channels");
    sendIM("Detecting RLV...");
}

stop_rlv_probe() {
    clearProbeChannels();
    RlvProbing = FALSE;
    RlvReady = TRUE;
    
    if (RlvActive) {
        logd("RLV detected: " + RlvVersion);
        sendIM("RLV: " + RlvVersion);
    }
    else {
        logd("RLV not detected");
        sendIM("RLV: Not detected");
    }
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS LOADING
   ═══════════════════════════════════════════════════════════ */

request_settings() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    logd("Requested settings");
}

apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    
    // Reset
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    OwnerHonorific = "";
    OwnerHonorifics = [];
    
    // Load
    if (json_has(kv_json, [KEY_MULTI_OWNER_MODE])) {
        MultiOwnerMode = (integer)llJsonGetValue(kv_json, [KEY_MULTI_OWNER_MODE]);
    }
    
    if (json_has(kv_json, [KEY_OWNER_KEY])) {
        OwnerKey = (key)llJsonGetValue(kv_json, [KEY_OWNER_KEY]);
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
    
    SettingsReceived = TRUE;
    logd("Settings received (multi_owner=" + (string)MultiOwnerMode + ")");
    
    // Start owner name resolution
    start_owner_name_resolution();
}

/* ═══════════════════════════════════════════════════════════
   OWNER NAME RESOLUTION
   ═══════════════════════════════════════════════════════════ */

start_owner_name_resolution() {
    OwnerNameQueries = [];
    OwnerDisplayNames = [];
    
    if (MultiOwnerMode) {
        // Multi-owner: resolve all owner names
        integer i = 0;
        integer len = llGetListLength(OwnerKeys);
        while (i < len) {
            key owner = llList2Key(OwnerKeys, i);
            if (owner != NULL_KEY) {
                key query_id = llRequestDisplayName(owner);
                OwnerNameQueries += [query_id, owner];
                OwnerDisplayNames += ["(loading...)"];
                logd("Requesting name for owner " + (string)(i + 1));
            }
            i += 1;
        }
    }
    else {
        // Single owner: resolve one name
        if (OwnerKey != NULL_KEY) {
            key query_id = llRequestDisplayName(OwnerKey);
            OwnerNameQueries += [query_id, OwnerKey];
            OwnerDisplayNames += ["(loading...)"];
            logd("Requesting owner name");
        }
    }
    
    // If no owners, we're done
    if (llGetListLength(OwnerNameQueries) == 0) {
        check_bootstrap_complete();
    }
}

handle_dataserver_name(key query_id, string name) {
    // Find this query
    integer i = 0;
    integer len = llGetListLength(OwnerNameQueries);
    while (i < len) {
        key stored_query = llList2Key(OwnerNameQueries, i);
        if (stored_query == query_id) {
            key owner = llList2Key(OwnerNameQueries, i + 1);
            
            // Update display name
            integer owner_idx = -1;
            if (MultiOwnerMode) {
                owner_idx = llListFindList(OwnerKeys, [(string)owner]);
            }
            else {
                if (owner == OwnerKey) owner_idx = 0;
            }
            
            if (owner_idx != -1 && owner_idx < llGetListLength(OwnerDisplayNames)) {
                OwnerDisplayNames = llListReplaceList(OwnerDisplayNames, [name], owner_idx, owner_idx);
                logd("Resolved name: " + name);
            }
            
            // Remove this query
            OwnerNameQueries = llDeleteSubList(OwnerNameQueries, i, i + NAME_QUERY_STRIDE - 1);
            
            // Check if all names resolved
            if (llGetListLength(OwnerNameQueries) == 0) {
                logd("All owner names resolved");
                check_bootstrap_complete();
            }
            
            return;
        }
        i += NAME_QUERY_STRIDE;
    }
}

/* ═══════════════════════════════════════════════════════════
   BOOTSTRAP COMPLETION
   ═══════════════════════════════════════════════════════════ */

check_bootstrap_complete() {
    if (BootstrapComplete) return;
    
    // Check all conditions
    if (RlvReady && SettingsReceived && llGetListLength(OwnerNameQueries) == 0) {
        BootstrapComplete = TRUE;
        logd("Bootstrap complete");
        
        // Announce final status
        announce_status();
    }
}

announce_status() {
    // Mode notification
    if (MultiOwnerMode) {
        integer owner_count = llGetListLength(OwnerKeys);
        sendIM("Mode: Multi-Owner (" + (string)owner_count + ")");
    }
    else {
        sendIM("Mode: Single-Owner");
    }
    
    // Ownership status
    if (MultiOwnerMode) {
        integer owner_count = llGetListLength(OwnerKeys);
        if (owner_count > 0) {
            string owner_line = "Owned by ";
            integer i = 0;
            while (i < owner_count) {
                if (i > 0) owner_line += ", ";
                
                string hon = "";
                if (i < llGetListLength(OwnerHonorifics)) {
                    hon = llList2String(OwnerHonorifics, i);
                }
                
                string name = "";
                if (i < llGetListLength(OwnerDisplayNames)) {
                    name = llList2String(OwnerDisplayNames, i);
                }
                
                if (hon != "") {
                    owner_line += hon + " " + name;
                }
                else {
                    owner_line += name;
                }
                
                i += 1;
            }
            sendIM(owner_line);
        }
        else {
            sendIM("Uncommitted");
        }
    }
    else {
        if (OwnerKey != NULL_KEY) {
            string owner_line = "Owned by ";
            if (OwnerHonorific != "") {
                owner_line += OwnerHonorific + " ";
            }
            owner_line += llList2String(OwnerDisplayNames, 0);
            sendIM(owner_line);
        }
        else {
            sendIM("Uncommitted");
        }
    }
    
    sendIM("Collar startup complete.");
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default
{
    state_entry() {
        BootstrapComplete = FALSE;
        SettingsReceived = FALSE;
        
        logd("Bootstrap started");
        sendIM("DS Collar starting up. Please wait...");
        
        // Start RLV detection
        start_rlv_probe();
        
        // Request settings
        request_settings();
        
        // Start timer for RLV probe management
        llSetTimerEvent(1.0);
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    attach(key id) {
        if (id == NULL_KEY) return;
        llResetScript();
    }
    
    timer() {
        // Handle RLV probe retries
        if (RlvProbing && !RlvReady) {
            integer current_time = now();
            
            // Check if we should send another query
            if (current_time >= RlvNextRetry) {
                if (RlvRetryCount < RLV_MAX_RETRIES) {
                    sendRlvQueries();
                    RlvRetryCount += 1;
                    RlvNextRetry = current_time + RLV_RETRY_INTERVAL_SEC;
                }
            }
            
            // Check for timeout
            if (current_time >= RlvProbeDeadline) {
                logd("RLV probe timed out");
                stop_rlv_probe();
                check_bootstrap_complete();
            }
        }
        
        // Stop timer if bootstrap complete
        if (BootstrapComplete && !RlvProbing) {
            llSetTimerEvent(0.0);
        }
    }
    
    listen(integer channel, string name, key id, string message) {
        // Check if this is one of our probe channels
        if (llListFindList(RlvChannels, [channel]) == -1) return;
        
        // Accept replies from wearer OR NULL_KEY (some viewers use NULL_KEY for RLV)
        key wearer = llGetOwner();
        if (id != wearer && id != NULL_KEY) return;
        
        // Any reply means RLV is active
        RlvActive = TRUE;
        RlvVersion = llStringTrim(message, STRING_TRIM);
        logd("RLV reply on channel " + (string)channel + " from " + (string)id + ": " + RlvVersion);
        
        // Stop probing immediately
        stop_rlv_probe();
        check_bootstrap_complete();
    }
    
    dataserver(key query_id, string data) {
        // Handle display name responses
        handle_dataserver_name(query_id, data);
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        /* ===== SETTINGS BUS ===== */
        if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
            }
        }
        
        /* ===== KERNEL LIFECYCLE ===== */
        else if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                llResetScript();
            }
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
