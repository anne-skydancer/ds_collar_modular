/* =============================================================================
   MODULE: ds_collar_kmod_bootstrap.lsl (v2.0 - Consolidated ABI)
   
   ROLE: Startup coordination, RLV detection, owner name resolution
   
   CHANNELS:
   - 500 (KERNEL_LIFECYCLE): Soft reset coordination
   - 700 (AUTH_BUS): ACL queries for wearer
   - 800 (SETTINGS_BUS): Initial settings request
   
   STARTUP SEQUENCE:
   1. Detect RLV capabilities
   2. Request settings sync
   3. Query wearer ACL
   4. Resolve owner display names
   5. Signal ready state
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
integer RLV_PROBE_TIMEOUT_SEC = 5;
integer RLV_CHANNEL = -1812221819;  // Standard RLV relay channel

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_KEYS = "owner_keys";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
integer BootstrapComplete = FALSE;

// RLV detection
integer RlvProbing = FALSE;
integer RlvListenHandle = 0;
integer RlvProbeDeadline = 0;
integer RlvActive = FALSE;
string RlvVersion = "";

// Settings
integer SettingsReceived = FALSE;
integer MultiOwnerMode = FALSE;
key OwnerKey = NULL_KEY;
list OwnerKeys = [];

// Name resolution
list OwnerNameQueries = [];  // [query_id, owner_key, query_id, owner_key, ...]
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

/* ═══════════════════════════════════════════════════════════
   RLV DETECTION
   ═══════════════════════════════════════════════════════════ */

start_rlv_probe() {
    if (RlvProbing) return;
    
    RlvProbing = TRUE;
    RlvActive = FALSE;
    RlvVersion = "";
    RlvProbeDeadline = now() + RLV_PROBE_TIMEOUT_SEC;
    
    // Open listen
    if (RlvListenHandle != 0) {
        llListenRemove(RlvListenHandle);
    }
    RlvListenHandle = llListen(RLV_CHANNEL, "", NULL_KEY, "");
    
    // Send probe
    llOwnerSay("@versionnew=" + (string)RLV_CHANNEL);
    
    logd("RLV probe started");
}

stop_rlv_probe() {
    if (RlvListenHandle != 0) {
        llListenRemove(RlvListenHandle);
        RlvListenHandle = 0;
    }
    RlvProbing = FALSE;
    
    if (RlvActive) {
        logd("RLV detected: " + RlvVersion);
    }
    else {
        logd("RLV not detected");
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
    if (!RlvProbing && SettingsReceived && llGetListLength(OwnerNameQueries) == 0) {
        BootstrapComplete = TRUE;
        logd("Bootstrap complete");
        
        // Announce status
        announce_status();
    }
}

announce_status() {
    string status = "Collar initialized";
    
    if (RlvActive) {
        status += " [RLV: " + RlvVersion + "]";
    }
    else {
        status += " [RLV: not detected]";
    }
    
    if (MultiOwnerMode) {
        integer owner_count = llGetListLength(OwnerKeys);
        if (owner_count > 0) {
            status += " | Owners: ";
            integer i = 0;
            while (i < owner_count && i < 3) {  // Show max 3 names
                if (i > 0) status += ", ";
                status += llList2String(OwnerDisplayNames, i);
                i += 1;
            }
            if (owner_count > 3) {
                status += " (+" + (string)(owner_count - 3) + " more)";
            }
        }
        else {
            status += " | No owner set";
        }
    }
    else {
        if (OwnerKey != NULL_KEY) {
            status += " | Owner: " + llList2String(OwnerDisplayNames, 0);
        }
        else {
            status += " | No owner set";
        }
    }
    
    llOwnerSay(status);
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
        
        // Start RLV detection
        start_rlv_probe();
        
        // Request settings
        request_settings();
        
        // Start timer for RLV probe timeout
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
        // Check RLV probe timeout
        if (RlvProbing && now() >= RlvProbeDeadline) {
            stop_rlv_probe();
            check_bootstrap_complete();
        }
        
        // Stop timer if bootstrap complete
        if (BootstrapComplete) {
            llSetTimerEvent(0.0);
        }
    }
    
    listen(integer channel, string name, key id, string message) {
        if (channel == RLV_CHANNEL && RlvProbing) {
            // RLV response format: "RestrainedLove viewer v1.23.4 (RLVa 1.2.3)"
            if (llSubStringIndex(message, "RestrainedLove") == 0 ||
                llSubStringIndex(message, "RLV") == 0) {
                RlvActive = TRUE;
                RlvVersion = message;
                stop_rlv_probe();
                check_bootstrap_complete();
            }
        }
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
            if (msg_type == "soft_reset") {
                llResetScript();
            }
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
        
        if (change & CHANGED_REGION || change & CHANGED_TELEPORT) {
            // Re-probe RLV on region change
            if (BootstrapComplete) {
                logd("Region change detected, re-probing RLV");
                BootstrapComplete = FALSE;
                start_rlv_probe();
                llSetTimerEvent(1.0);
            }
        }
    }
}
