/*--------------------
MODULE: ds_collar_kmod_bootstrap.lsl
VERSION: 1.00
REVISION: 27
PURPOSE: Startup coordination, RLV detection, owner name resolution
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Rate-limited display name requests to avoid viewer throttling
- Owner change detection prevents bootstrap on teleports and region crossings
- Soft reset handling now validates authorized senders before acting
- Multi-channel RLV detection listens on 4711 and relay channels
- Startup workflow delivers IM status updates during initialization
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- RLV DETECTION CONFIG -------------------- */
integer RLV_PROBE_TIMEOUT_SEC = 30;
integer RLV_RETRY_INTERVAL_SEC = 4;
integer RLV_MAX_RETRIES = 8;
integer RLV_INITIAL_DELAY_SEC = 1;

// Probe multiple channels for better compatibility
integer UseFixed4711;
integer UseRelayChan;
integer RELAY_CHAN = -1812221819;
integer ProbeRelayBothSigns;  // Also try positive relay channel

/* -------------------- DISPLAY NAME REQUEST RATE LIMITING -------------------- */
float NAME_REQUEST_INTERVAL_SEC = 2.5;  // Space requests 2.5s apart to avoid throttling

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_KEYS = "owner_keys";
string KEY_OWNER_HON = "owner_hon";
string KEY_OWNER_HONS = "owner_honorifics";

/* -------------------- STATE -------------------- */
integer BootstrapComplete = FALSE;

// Owner tracking
key LastOwner = NULL_KEY;

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

// Name request queue (rate-limited)
list PendingNameRequests = [];  // List of owner keys waiting for display name requests
integer NextNameRequestTime = 0;  // Timestamp when next request can be sent

/* -------------------- HELPERS -------------------- */


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
string get_msg_type(string msg) {
    if (!json_has(msg, ["type"])) return "";
    return llJsonGetValue(msg, ["type"]);
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

// Owner change detection (prevents unnecessary resets on teleport)
integer check_owner_changed() {
    key current_owner = llGetOwner();
    if (current_owner == NULL_KEY) return FALSE;

    if (LastOwner != NULL_KEY && current_owner != LastOwner) {
        LastOwner = current_owner;
        llResetScript();
        return TRUE;
    }

    LastOwner = current_owner;
    return FALSE;
}

/* -------------------- RLV DETECTION - Multi-Channel Approach -------------------- */

addProbeChannel(integer ch) {
    if (ch == 0) return;
    if (llListFindList(RlvChannels, [ch]) != -1) return;  // Already added
    
    integer handle = llListen(ch, "", NULL_KEY, "");  // Accept from anyone (NULL_KEY important!)
    RlvChannels += [ch];
    RlvListenHandles += [handle];
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
}

start_rlv_probe() {
    if (RlvProbing) {
        return;
    }
    
    if (!isAttached()) {
        // Not attached, can't detect RLV
        RlvReady = TRUE;
        RlvActive = FALSE;
        RlvVersion = "";
        return;
    }
    
    RlvProbing = TRUE;
    RlvActive = FALSE;
    RlvVersion = "";
    RlvRetryCount = 0;
    RlvReady = FALSE;
    
    clearProbeChannels();
    
    // Set up multiple probe channels
    if (UseFixed4711) addProbeChannel(4711);
    if (UseRelayChan) {
        addProbeChannel(RELAY_CHAN);
        if (ProbeRelayBothSigns) {
            addProbeChannel(-RELAY_CHAN);  // Try opposite sign too
        }
    }
    
    RlvProbeDeadline = now() + RLV_PROBE_TIMEOUT_SEC;
    RlvNextRetry = now() + RLV_INITIAL_DELAY_SEC;  // Initial delay before first probe
    
    sendIM("Detecting RLV...");
}

stop_rlv_probe() {
    clearProbeChannels();
    RlvProbing = FALSE;
    RlvReady = TRUE;
    
    if (RlvActive) {
        sendIM("RLV: " + RlvVersion);
    }
    else {
        sendIM("RLV: Not detected");
    }
}

/* -------------------- SETTINGS LOADING -------------------- */

request_settings() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
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
        if (llJsonValueType(owner_keys_json, []) == JSON_ARRAY) {
            OwnerKeys = llJson2List(owner_keys_json);
        }
    }
    
    if (json_has(kv_json, [KEY_OWNER_HON])) {
        OwnerHonorific = llJsonGetValue(kv_json, [KEY_OWNER_HON]);
    }
    
    if (json_has(kv_json, [KEY_OWNER_HONS])) {
        string owner_hons_json = llJsonGetValue(kv_json, [KEY_OWNER_HONS]);
        if (llJsonValueType(owner_hons_json, []) == JSON_ARRAY) {
            OwnerHonorifics = llJson2List(owner_hons_json);
        }
    }
    
    SettingsReceived = TRUE;
    
    // Start name resolution
    start_name_resolution();
}

/* -------------------- NAME RESOLUTION -------------------- */

// Process next queued display name request (rate-limited)
process_next_name_request() {
    integer current_time = now();
    if (current_time == 0) return;  // Overflow protection

    // Check if we have any pending requests
    if (llGetListLength(PendingNameRequests) == 0) return;

    // Check if we're allowed to make a request yet
    if (NextNameRequestTime > 0 && current_time < NextNameRequestTime) return;

    // Get next owner key from queue
    key owner = llList2Key(PendingNameRequests, 0);
    PendingNameRequests = llDeleteSubList(PendingNameRequests, 0, 0);

    // Make the request
    if (owner != NULL_KEY) {
        key query_id = llRequestDisplayName(owner);
        OwnerNameQueries += [query_id, owner];

        // Find the index for this owner
        integer owner_idx = -1;
        if (MultiOwnerMode) {
            owner_idx = llListFindList(OwnerKeys, [(string)owner]);
        }
        else {
            if (owner == OwnerKey) owner_idx = 0;
        }

        // Initialize display name placeholder
        if (owner_idx != -1) {
            if (owner_idx >= llGetListLength(OwnerDisplayNames)) {
                OwnerDisplayNames += ["(loading...)"];
            }
        }


        // Schedule next request (cast needed: NAME_REQUEST_INTERVAL_SEC is float)
        integer next_time = current_time + (integer)NAME_REQUEST_INTERVAL_SEC;
        if (next_time > current_time) {  // Overflow protection
            NextNameRequestTime = next_time;
        }
        else {
            NextNameRequestTime = current_time;
        }
    }
}

start_name_resolution() {
    OwnerNameQueries = [];
    OwnerDisplayNames = [];
    PendingNameRequests = [];
    NextNameRequestTime = 0;

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
        // Multi-owner: queue all owner keys for rate-limited requests
        integer i = 0;
        integer len = llGetListLength(OwnerKeys);
        while (i < len) {
            string owner_str = llList2String(OwnerKeys, i);
            key owner = (key)owner_str;
            if (owner != NULL_KEY) {
                PendingNameRequests += [owner];
                OwnerDisplayNames += ["(loading...)"];
            }
            i += 1;
        }
    }
    else {
        // Single owner: queue one request
        if (OwnerKey != NULL_KEY) {
            PendingNameRequests += [OwnerKey];
            OwnerDisplayNames += ["(loading...)"];
        }
    }

    // If no owners, we're done
    if (llGetListLength(PendingNameRequests) == 0) {
        check_bootstrap_complete();
    }
    else {
        // Start processing the queue
        process_next_name_request();
    }
}

handle_dataserver_name(key query_id, string name) {
    // Find this query
    integer idx = llListFindList(OwnerNameQueries, [query_id]);
    if (idx != -1) {
        key owner = llList2Key(OwnerNameQueries, idx + 1);
        
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
        }
        
        // Remove this query
        OwnerNameQueries = llDeleteSubList(OwnerNameQueries, idx, idx + NAME_QUERY_STRIDE - 1);
        
        // Check if all names resolved
        if (llGetListLength(OwnerNameQueries) == 0) {
            check_bootstrap_complete();
        }
    }
}

/* -------------------- BOOTSTRAP INITIATION -------------------- */

start_bootstrap() {
    BootstrapComplete = FALSE;
    SettingsReceived = FALSE;
    NameResolutionDeadline = 0;
    PendingNameRequests = [];
    NextNameRequestTime = 0;
    
    sendIM("DS Collar starting up. Please wait...");
    
    start_rlv_probe();
    request_settings();
    
    llSetTimerEvent(1.0);
}

/* -------------------- BOOTSTRAP COMPLETION -------------------- */

check_bootstrap_complete() {
    if (BootstrapComplete) return;

    // Check all conditions
    // CRITICAL: Must check BOTH OwnerNameQueries (sent requests) AND PendingNameRequests (queued requests)
    if (RlvReady && SettingsReceived &&
        llGetListLength(OwnerNameQueries) == 0 &&
        llGetListLength(PendingNameRequests) == 0) {
        BootstrapComplete = TRUE;

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
            list owner_parts = [];
            integer i = 0;
            while (i < owner_count) {
                string hon = "";
                if (i < llGetListLength(OwnerHonorifics)) {
                    hon = llList2String(OwnerHonorifics, i);
                }
                
                string name = "";
                if (i < llGetListLength(OwnerDisplayNames)) {
                    name = llList2String(OwnerDisplayNames, i);
                }
                
                if (hon != "") {
                    owner_parts += [hon + " " + name];
                }
                else {
                    owner_parts += [name];
                }
                
                i += 1;
            }
            sendIM("Owned by " + llDumpList2String(owner_parts, ", "));
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

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        UseFixed4711 = TRUE;
        UseRelayChan = TRUE;
        ProbeRelayBothSigns = TRUE;

        LastOwner = llGetOwner();
        
        start_bootstrap();
    }

    on_rez(integer start_param) {
        // Only reset if owner changed - prevents bootstrap on every teleport
        check_owner_changed();
    }

    attach(key id) {
        if (id == NULL_KEY) return;
        // Bootstrap on attach (covers logon and initial attach)
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
                stop_rlv_probe();
                check_bootstrap_complete();
            }
        }

        // Process queued display name requests (rate-limited)
        if (llGetListLength(PendingNameRequests) > 0) {
            process_next_name_request();
        }

        // Check name resolution timeout
        if ((llGetListLength(OwnerNameQueries) > 0 || llGetListLength(PendingNameRequests) > 0) &&
            NameResolutionDeadline > 0 && current_time >= NameResolutionDeadline) {
            OwnerNameQueries = []; // Clear pending queries
            PendingNameRequests = []; // Clear pending requests
            check_bootstrap_complete();
        }

        // Stop timer if bootstrap complete
        if (BootstrapComplete && !RlvProbing &&
            llGetListLength(OwnerNameQueries) == 0 &&
            llGetListLength(PendingNameRequests) == 0) {
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
        
        // Stop probing immediately
        stop_rlv_probe();
        check_bootstrap_complete();
    }
    
    dataserver(key query_id, string data) {
        // Handle display name responses
        handle_dataserver_name(query_id, data);
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;
        
        /* -------------------- SETTINGS BUS -------------------- */
        if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
            }
        }
        
        /* -------------------- KERNEL LIFECYCLE -------------------- */
        else if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "notecard_loaded") {
                // Settings notecard was loaded/reloaded - re-run bootstrap
                start_bootstrap();
            }
            else if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                // SECURITY FIX (v2.3 - MEDIUM-023): Validate sender authorization
                if (!json_has(msg, ["from"])) {
                    return;
                }
                
                string from = llJsonGetValue(msg, ["from"]);
                
                if (!is_authorized_reset_sender(from)) {
                    return;
                }
                
                // Authorized - proceed with reset
                llResetScript();
            }
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            check_owner_changed();
        }
    }
}
