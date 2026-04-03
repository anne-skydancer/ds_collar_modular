/*--------------------
MODULE: kmod_bootstrap.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Startup coordination, RLV detection, owner name resolution
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 0: Version bump for LSD policy architecture. Bootstrap no longer
  manages UI policies — each plugin self-declares via llLinksetDataWrite.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- RLV DETECTION CONFIG -------------------- */
integer RLV_PROBE_TIMEOUT_SEC = 60;
integer RLV_RETRY_INTERVAL_SEC = 5;
integer RLV_MAX_RETRIES = 10;
integer RLV_INITIAL_DELAY_SEC = 5;

// Probe multiple channels for better compatibility
integer UseFixed4711;
integer UseRelayChan;
integer RELAY_CHAN = -1812221819;
integer ProbeRelayBothSigns;  // Also try positive relay channel

/* -------------------- DISPLAY NAME REQUEST RATE LIMITING -------------------- */
float NAME_REQUEST_INTERVAL_SEC = 2.5;  // Space requests 2.5s apart to avoid throttling

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER = "owner";
string KEY_OWNERS = "owners";

/* -------------------- BOOTSTRAP CONFIG -------------------- */
integer BOOTSTRAP_TIMEOUT_SEC = 90;
integer SETTINGS_RETRY_INTERVAL_SEC = 5;
integer SETTINGS_MAX_RETRIES = 3;
integer SETTINGS_INITIAL_DELAY_SEC = 5; // Wait for linkset data + notecard load

/* -------------------- STATE -------------------- */
integer BootstrapComplete = FALSE;
integer BootstrapDeadline = 0;

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
integer SettingsRetryCount = 0;
integer SettingsNextRetry = 0;
integer MultiOwnerMode = FALSE;
key OwnerKey = NULL_KEY;
list OwnerKeys = [];
string OwnerHonorific = "";
string OwnersJson = "{}";

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


string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
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
    while (i < llGetListLength(RlvListenHandles)) {
        integer handle = llList2Integer(RlvListenHandles, i);
        if (handle) llListenRemove(handle);
        i += 1;
    }
    RlvChannels = [];
    RlvListenHandles = [];
}

sendRlvQueries() {
    integer i = 0;
    while (i < llGetListLength(RlvChannels)) {
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
}

/* -------------------- SETTINGS LOADING -------------------- */

request_settings() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

apply_settings_sync(string msg) {
    string kv_json = llJsonGetValue(msg, ["kv"]);
    if (kv_json == JSON_INVALID) return;

    // Reset
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    OwnerHonorific = "";
    OwnersJson = "{}";

    // Load
    string tmp = llJsonGetValue(kv_json, [KEY_MULTI_OWNER_MODE]);
    if (tmp != JSON_INVALID) {
        MultiOwnerMode = (integer)tmp;
    }

    // Single owner: JSON object {uuid:honorific}
    string obj = llJsonGetValue(kv_json, [KEY_OWNER]);
    if (obj != JSON_INVALID) {
        if (llJsonValueType(obj, []) == JSON_OBJECT) {
            list pairs = llJson2List(obj);
            if (llGetListLength(pairs) >= 2) {
                OwnerKey = (key)llList2String(pairs, 0);
                OwnerHonorific = llList2String(pairs, 1);
            }
        }
    }

    // Multi-owner: JSON object {uuid:honorific, ...}
    obj = llJsonGetValue(kv_json, [KEY_OWNERS]);
    if (obj != JSON_INVALID) {
        if (llJsonValueType(obj, []) == JSON_OBJECT) {
            OwnersJson = obj;
            list pairs = llJson2List(obj);
            integer pi = 0;
            integer plen = llGetListLength(pairs);
            while (pi < plen) {
                OwnerKeys += [llList2String(pairs, pi)];
                pi += 2;
            }
        }
    }
    
    SettingsReceived = TRUE;
    
    // Start name resolution
    start_name_resolution();
}

/* -------------------- NAME RESOLUTION -------------------- */

// Process next queued display name request (rate-limited)
process_next_name_request() {
    integer current_time = llGetUnixTime();
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

    integer current_time = llGetUnixTime();
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
        while (i < llGetListLength(OwnerKeys)) {
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
    SettingsRetryCount = 0;
    NameResolutionDeadline = 0;
    PendingNameRequests = [];
    NextNameRequestTime = 0;
    
    BootstrapDeadline = now() + BOOTSTRAP_TIMEOUT_SEC;
    
    sendIM("D/s Collar starting up. Please wait...");
    
    start_rlv_probe();
    
    // OPTIMIZATION: Delay initial settings request to allow notecard loading
    // This prevents "double bootstrap" where we get defaults then reset on notecard_loaded
    SettingsNextRetry = now() + SETTINGS_INITIAL_DELAY_SEC;
    
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
    // RLV Status
    if (RlvActive) {
        sendIM("RLV: " + RlvVersion);
    }
    else {
        sendIM("RLV: Not detected");
    }

    // Mode notification
    if (!SettingsReceived) {
        sendIM("WARNING: Settings timed out. Using defaults.");
    }

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
                string owner_uuid = llList2String(OwnerKeys, i);
                string hon = llJsonGetValue(OwnersJson, [owner_uuid]);
                if (hon == JSON_INVALID) hon = "";
                
                string display_name = "";
                if (i < llGetListLength(OwnerDisplayNames)) {
                    display_name = llList2String(OwnerDisplayNames, i);
                }
                
                if (hon != "") {
                    owner_parts += [hon + " " + display_name];
                }
                else {
                    owner_parts += [display_name];
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
        
        state starting;
    }
}

state starting
{
    state_entry() {
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
        integer current_time = llGetUnixTime();
        if (current_time == 0) return; // Overflow protection

        // GLOBAL TIMEOUT CHECK
        if (!BootstrapComplete && BootstrapDeadline > 0 && current_time >= BootstrapDeadline) {
            sendIM("WARNING: Bootstrap timed out. Forcing completion.");
            
            // Force completion of pending tasks
            if (!RlvReady) stop_rlv_probe();
            if (!SettingsReceived) {
                SettingsReceived = TRUE; // Assume defaults
                // Start name resolution with defaults (likely just wearer if unowned)
                start_name_resolution(); 
            }
            
            // Clear pending name queries
            OwnerNameQueries = [];
            PendingNameRequests = [];
            
            BootstrapComplete = TRUE;
            announce_status();
            state running;
            return;
        }

        // Handle Settings Retries
        if (!SettingsReceived && current_time >= SettingsNextRetry) {
            if (SettingsRetryCount < SETTINGS_MAX_RETRIES) {
                request_settings();
                SettingsRetryCount++;
                SettingsNextRetry = current_time + SETTINGS_RETRY_INTERVAL_SEC;
            }
        }

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
            state running;
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

state running
{
    state_entry() {
        llSetTimerEvent(0.0);
    }

    on_rez(integer start_param) {
        check_owner_changed();
    }

    attach(key id) {
        if (id == NULL_KEY) return;
        llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;
        
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "notecard_loaded") {
                llResetScript();
            }
            else if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
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
