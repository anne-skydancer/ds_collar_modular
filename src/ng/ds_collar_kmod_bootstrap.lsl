/* =============================================================================
   MODULE: ds_collar_kmod_bootstrap.lsl (v2.3 - Soft Reset Authorization Fix)
   SECURITY AUDIT: MEDIUM-023 FIX APPLIED
   
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
   
   SECURITY FIXES APPLIED:
   - [MEDIUM-023] Soft reset authorization validation (v2.3)
   - [MEDIUM] Integer overflow protection for timestamps
   - [LOW] Production mode guards debug logging
   - [ENHANCEMENT] Name resolution timeout added (30s)
   
   CHANGELOG v2.3:
   - Added 'from' field validation for soft_reset messages
   - Only authorized senders (kernel, maintenance, bootstrap) can trigger reset
   - Aligns with kernel's security model from v2.0+

   KANBAN MIGRATION (v3.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "bootstrap";

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

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

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
integer NameResolutionDeadline = 0;
integer NAME_RESOLUTION_TIMEOUT_SEC = 30;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[BOOTSTRAP] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

integer now() {
    integer unix_time = llGetUnixTime();
    // INTEGER OVERFLOW PROTECTION: Handle year 2038 problem
    if (unix_time < 0) {
        llOwnerSay("[BOOTSTRAP] ERROR: Unix timestamp overflow detected!");
        return 0;
    }
    return unix_time;
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

// SECURITY: Check if sender is authorized to trigger soft_reset
integer is_authorized_reset_sender(string from) {
    if (from == "kernel") return TRUE;
    if (from == "maintenance") return TRUE;
    if (from == "bootstrap") return TRUE;
    return FALSE;
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
    // Kanban: Send settings_get request (empty payload with request marker)
    kSend(CONTEXT, "settings", SETTINGS_BUS, kPayload(["request", "get"]), NULL_KEY);
    logd("Requested settings");
}

apply_settings_sync(string payload) {
    if (!json_has(payload, ["kv"])) return;

    string kv_json = llJsonGetValue(payload, ["kv"]);
    
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
        string owner_hons_json = llJsonGetValue(kv_json, [KEY_OWNER_HONS]);
        if (is_json_arr(owner_hons_json)) {
            OwnerHonorifics = llJson2List(owner_hons_json);
        }
    }
    
    SettingsReceived = TRUE;
    logd("Settings received");
    
    // Start name resolution
    start_name_resolution();
}

/* ═══════════════════════════════════════════════════════════
   NAME RESOLUTION
   ═══════════════════════════════════════════════════════════ */

start_name_resolution() {
    OwnerNameQueries = [];
    OwnerDisplayNames = [];
    
    integer current_time = now();
    if (current_time > 0) {
        integer deadline = current_time + NAME_RESOLUTION_TIMEOUT_SEC;
        if (deadline > current_time) {
            NameResolutionDeadline = deadline;
        }
        else {
            NameResolutionDeadline = current_time;
        }
    }
    
    if (MultiOwnerMode) {
        // Multi-owner: resolve all names
        integer i = 0;
        integer len = llGetListLength(OwnerKeys);
        while (i < len) {
            string owner_str = llList2String(OwnerKeys, i);
            key owner = (key)owner_str;
            if (owner != NULL_KEY) {
                key query_id = llRequestDisplayName(owner);
                OwnerNameQueries += [query_id, owner];
                OwnerDisplayNames += ["(loading...)"];
                logd("Requesting owner name " + (string)(i + 1));
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
        NameResolutionDeadline = 0;
        
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
        integer current_time = now();
        if (current_time == 0) return; // Overflow protection
        
        // Handle RLV probe retries
        if (RlvProbing && !RlvReady) {
            // Check if we should send another query
            if (RlvNextRetry > 0 && current_time >= RlvNextRetry) {
                if (RlvRetryCount < RLV_MAX_RETRIES) {
                    sendRlvQueries();
                    RlvRetryCount += 1;
                    integer next_retry_time = current_time + RLV_RETRY_INTERVAL_SEC;
                    if (next_retry_time < current_time) next_retry_time = current_time; // Overflow protection
                    RlvNextRetry = next_retry_time;
                }
            }
            
            // Check for timeout
            if (RlvProbeDeadline > 0 && current_time >= RlvProbeDeadline) {
                logd("RLV probe timed out");
                stop_rlv_probe();
                check_bootstrap_complete();
            }
        }
        
        // Check name resolution timeout
        if (llGetListLength(OwnerNameQueries) > 0 && NameResolutionDeadline > 0 && current_time >= NameResolutionDeadline) {
            logd("Name resolution timed out, proceeding with fallback names");
            OwnerNameQueries = []; // Clear pending queries
            check_bootstrap_complete();
        }
        
        // Stop timer if bootstrap complete
        if (BootstrapComplete && !RlvProbing && llGetListLength(OwnerNameQueries) == 0) {
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
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        // Route by channel + sender (kFrom) + payload structure

        /* ===== SETTINGS BUS ===== */
        if (num == SETTINGS_BUS) {
            // Settings sync: has "kv" field
            if (kFrom == "settings" && json_has(payload, ["kv"])) {
                apply_settings_sync(payload);
            }
        }

        /* ===== KERNEL LIFECYCLE ===== */
        else if (num == KERNEL_LIFECYCLE) {
            // Soft reset: has "reset" marker
            if (json_has(payload, ["reset"])) {
                // SECURITY FIX (v2.3 - MEDIUM-023): Validate sender authorization
                // kFrom is automatically set by kRecv() to the sender's context
                if (!is_authorized_reset_sender(kFrom)) {
                    logd("SECURITY: Rejected soft_reset from unauthorized sender: " + kFrom);
                    return;
                }

                // Authorized - proceed with reset
                logd("Accepting soft_reset from: " + kFrom);
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
