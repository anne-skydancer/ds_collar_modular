/* ===============================================================
   MODULE: ds_collar_kernel.lsl (v1.0 - Consolidated ABI)
   SECURITY AUDIT: ALL ISSUES FIXED

   PURPOSE: Plugin registry, lifecycle management, heartbeat monitoring

   CHANNELS:
   - 500 (KERNEL_LIFECYCLE): All lifecycle operations

   PREVENTS UNINTENDED UI:
   - Plugin registration does NOT trigger UI display
   - Only explicit touch events show UI
   - Heartbeat is silent
   - Resets are silent

   SECURITY FIXES APPLIED:
   - [CRITICAL] Soft reset now requires authorized sender
   - [MEDIUM] JSON construction uses proper encoding (no string injection)
   - [MEDIUM] Integer overflow protection for timestamps
   - [LOW] Production mode guards debug logging
   - [LOW] Late registration debounced to prevent broadcast storms
   =============================================================== */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */
integer KERNEL_LIFECYCLE = 500;

/* ===============================================================
   CONSTANTS
   =============================================================== */
float   PING_INTERVAL_SEC     = 5.0;
integer PING_TIMEOUT_SEC      = 15;
float   INV_SWEEP_INTERVAL    = 3.0;
float   REGISTRATION_WINDOW_SEC = 2.0;  // Window to collect registrations before first broadcast

/* Registry stride: [context, label, min_acl, script, last_seen_unix] */
integer REG_STRIDE = 5;
integer REG_CONTEXT = 0;
integer REG_LABEL = 1;
integer REG_MIN_ACL = 2;
integer REG_SCRIPT = 3;
integer REG_LAST_SEEN = 4;

/* Authorized senders for privileged operations */
list AUTHORIZED_RESET_SENDERS = ["bootstrap", "maintenance"];

/* ===============================================================
   STATE
   =============================================================== */
list PluginRegistry = [];
integer LastPingUnix = 0;
integer LastInvSweepUnix = 0;
key LastOwner = NULL_KEY;
integer RegistrationWindowOpen = FALSE;
integer RegistrationWindowStartTime = 0;
integer PendingListRequest = FALSE;  // Track if someone requested list during window
integer LastScriptCount = 0;  // Track script count to detect add/remove
integer PendingLateBroadcast = FALSE;  // Debounce late registrations

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[KERNEL] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer now() {
    integer unix_time = llGetUnixTime();
    // INTEGER OVERFLOW PROTECTION: Handle year 2038 problem
    if (unix_time < 0) {
        llOwnerSay("[KERNEL] ERROR: Unix timestamp overflow detected!");
        return 0;
    }
    return unix_time;
}

integer countScripts() {
    integer count = 0;
    integer i;
    integer inv_count = llGetInventoryNumber(INVENTORY_SCRIPT);
    for (i = 0; i < inv_count; i = i + 1) {
        count = count + 1;
    }
    return count;
}

integer isAuthorizedSender(string sender_name) {
    integer i;
    integer len = llGetListLength(AUTHORIZED_RESET_SENDERS);
    for (i = 0; i < len; i = i + 1) {
        if (llList2String(AUTHORIZED_RESET_SENDERS, i) == sender_name) {
            return TRUE;
        }
    }
    return FALSE;
}

/* ===============================================================
   REGISTRY MANAGEMENT
   =============================================================== */

// Find plugin index in registry by context
integer registryFind(string context) {
    integer i = 0;
    integer len = llGetListLength(PluginRegistry);
    while (i < len) {
        if (llList2String(PluginRegistry, i + REG_CONTEXT) == context) {
            return i;
        }
        i += REG_STRIDE;
    }
    return -1;
}

// Add or update plugin in registry
integer registryUpsert(string context, string label, integer min_acl, string script) {
    integer idx = registryFind(context);
    integer now_unix = now();
    
    if (idx == -1) {
        // New plugin
        PluginRegistry += [context, label, min_acl, script, now_unix];
        logd("Registered: " + context + " (" + label + ")");
        return TRUE;
    }
    else {
        // Update existing (consolidated into single list operation for efficiency)
        PluginRegistry = llListReplaceList(PluginRegistry,
            [label, min_acl, script, now_unix],
            idx + REG_LABEL, idx + REG_LAST_SEEN);
        logd("Updated: " + context);
        return FALSE;
    }
}

// Update last_seen timestamp for plugin
updateLastSeen(string context) {
    integer idx = registryFind(context);
    if (idx != -1) {
        integer now_unix = now();
        PluginRegistry = llListReplaceList(PluginRegistry, [now_unix], idx + REG_LAST_SEEN, idx + REG_LAST_SEEN);
    }
}

// Remove dead plugins (haven't responded to ping in PING_TIMEOUT_SEC)
integer pruneDeadPlugins() {
    integer now_unix = now();
    if (now_unix == 0) return 0; // Overflow protection
    
    integer cutoff = now_unix - PING_TIMEOUT_SEC;
    if (cutoff < 0) cutoff = 0; // Additional overflow protection
    
    integer pruned = 0;
    
    list new_registry = [];
    integer i = 0;
    integer len = llGetListLength(PluginRegistry);
    
    while (i < len) {
        string context = llList2String(PluginRegistry, i + REG_CONTEXT);
        integer last_seen = llList2Integer(PluginRegistry, i + REG_LAST_SEEN);
        
        if (last_seen >= cutoff) {
            // Keep this plugin
            new_registry += llList2List(PluginRegistry, i, i + REG_STRIDE - 1);
        }
        else {
            // Prune dead plugin
            logd("Pruned dead plugin: " + context);
            pruned += 1;
        }
        
        i += REG_STRIDE;
    }
    
    PluginRegistry = new_registry;
    return pruned;
}

// Remove plugins whose scripts no longer exist in inventory
integer pruneMissingScripts() {
    list new_registry = [];
    integer pruned = 0;
    integer i = 0;
    integer len = llGetListLength(PluginRegistry);
    
    while (i < len) {
        string script = llList2String(PluginRegistry, i + REG_SCRIPT);
        string context = llList2String(PluginRegistry, i + REG_CONTEXT);
        
        if (llGetInventoryType(script) == INVENTORY_SCRIPT) {
            // Script still exists, keep plugin
            new_registry += llList2List(PluginRegistry, i, i + REG_STRIDE - 1);
        }
        else {
            // Script missing, prune plugin
            logd("Pruned missing script: " + context + " (" + script + ")");
            pruned += 1;
        }
        
        i += REG_STRIDE;
    }
    
    PluginRegistry = new_registry;
    return pruned;
}

/* ===============================================================
   BROADCASTING
   =============================================================== */

// Request all plugins to register
broadcastRegisterNow() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register_now"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    
    // Open registration window
    RegistrationWindowOpen = TRUE;
    RegistrationWindowStartTime = now();
    
    logd("Broadcast: register_now (window open for " + (string)REGISTRATION_WINDOW_SEC + "s)");
}

// Heartbeat ping to all plugins
broadcastPing() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ping"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    // Ping logging disabled - too noisy
}

// Send current plugin list (only when explicitly requested)
// SECURITY FIX: Use proper JSON encoding to prevent string injection
broadcastPluginList() {
    list plugins = [];
    integer i = 0;
    integer len = llGetListLength(PluginRegistry);
    
    while (i < len) {
        string context = llList2String(PluginRegistry, i + REG_CONTEXT);
        string label = llList2String(PluginRegistry, i + REG_LABEL);
        integer min_acl = llList2Integer(PluginRegistry, i + REG_MIN_ACL);
        
        // Build individual plugin object with proper JSON encoding
        string plugin_obj = llList2Json(JSON_OBJECT, [
            "context", context,
            "label", label,
            "min_acl", min_acl
        ]);
        
        plugins += [plugin_obj];
        i += REG_STRIDE;
    }
    
    // Convert list of JSON objects into JSON array string
    string plugins_array = "[";
    integer j;
    for (j = 0; j < llGetListLength(plugins); j = j + 1) {
        if (j > 0) plugins_array += ",";
        plugins_array += llList2String(plugins, j);
    }
    plugins_array += "]";
    
    // Build final message
    string msg = "{\"type\":\"plugin_list\",\"plugins\":" + plugins_array + "}";
    
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Broadcast: plugin_list (" + (string)llGetListLength(plugins) + " plugins)");
}

// Close registration window and broadcast collected plugins
closeRegistrationWindow() {
    if (!RegistrationWindowOpen) return;
    
    RegistrationWindowOpen = FALSE;
    PendingListRequest = FALSE;  // Clear pending flag
    
    integer plugin_count = llGetListLength(PluginRegistry) / REG_STRIDE;
    logd("Registration window closed (" + (string)plugin_count + " plugins registered)");
    
    // Always broadcast when window closes (satisfies any pending requests)
    broadcastPluginList();
}

// Soft reset request to all modules
broadcastSoftReset() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "soft_reset",
        "from", "kernel"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Broadcast: soft_reset");
}

/* ===============================================================
   OWNER CHANGE DETECTION
   =============================================================== */

integer checkOwnerChanged() {
    key current_owner = llGetOwner();
    if (current_owner == NULL_KEY) return FALSE;
    
    if (LastOwner != NULL_KEY && current_owner != LastOwner) {
        logd("Owner changed: " + (string)LastOwner + " -> " + (string)current_owner);
        LastOwner = current_owner;
        llResetScript();
        return TRUE;
    }
    
    LastOwner = current_owner;
    return FALSE;
}

/* ===============================================================
   MESSAGE HANDLERS
   =============================================================== */

handleRegister(string msg) {
    if (!jsonHas(msg, ["context"])) return;
    if (!jsonHas(msg, ["label"])) return;
    if (!jsonHas(msg, ["min_acl"])) return;
    if (!jsonHas(msg, ["script"])) return;
    
    string context = llJsonGetValue(msg, ["context"]);
    string label = llJsonGetValue(msg, ["label"]);
    integer min_acl = (integer)llJsonGetValue(msg, ["min_acl"]);
    string script = llJsonGetValue(msg, ["script"]);
    
    integer was_new = registryUpsert(context, label, min_acl, script);
    
    // If registration window is CLOSED and this is a new plugin,
    // schedule a deferred broadcast to prevent storms
    if (!RegistrationWindowOpen && was_new) {
        logd("Late registration detected, scheduling deferred broadcast");
        PendingLateBroadcast = TRUE;
    }
    
    // CRITICAL: Do NOT broadcast during registration window
    // This would cause UI to show on every plugin registration during startup
}

handlePong(string msg) {
    if (!jsonHas(msg, ["context"])) return;
    
    string context = llJsonGetValue(msg, ["context"]);
    updateLastSeen(context);
    // Pong logging disabled - too noisy
}

handlePluginListRequest() {
    if (RegistrationWindowOpen) {
        // Window still open - mark that someone requested the list
        // We'll broadcast when window closes
        PendingListRequest = TRUE;
        logd("Plugin list requested during window - will broadcast when window closes");
    }
    else {
        // Window closed - respond immediately
        broadcastPluginList();
    }
}

handleSoftReset(string msg) {
    // SECURITY FIX: Verify sender is authorized to request reset
    string from = llJsonGetValue(msg, ["from"]);
    
    if (from == JSON_INVALID || from == "") {
        logd("Rejected soft_reset: missing 'from' field");
        llOwnerSay("[KERNEL] ERROR: Soft reset rejected - sender not identified");
        return;
    }
    
    if (!isAuthorizedSender(from)) {
        logd("Rejected soft_reset from unauthorized sender: " + from);
        llOwnerSay("[KERNEL] ERROR: Soft reset rejected - unauthorized sender: " + from);
        return;
    }
    
    // Authorized - proceed with reset
    logd("Soft reset authorized by: " + from);
    PluginRegistry = [];
    LastPingUnix = now();
    LastInvSweepUnix = now();
    broadcastRegisterNow();
}

/* ===============================================================
   EVENTS
   =============================================================== */

default
{
    state_entry() {
        LastOwner = llGetOwner();
        PluginRegistry = [];
        LastPingUnix = now();
        LastInvSweepUnix = now();
        RegistrationWindowOpen = FALSE;
        RegistrationWindowStartTime = 0;
        PendingListRequest = FALSE;
        PendingLateBroadcast = FALSE;
        LastScriptCount = countScripts();
        
        logd("Kernel started");
        
        // Immediately broadcast register_now (opens registration window)
        broadcastRegisterNow();

        // Start timer for window management, heartbeat, and inventory sweeps
        llSetTimerEvent(1.0);  // Check once per second (reduced from 0.5s for efficiency)
    }
    
    on_rez(integer start_param) {
        checkOwnerChanged();
    }
    
    attach(key id) {
        if (id == NULL_KEY) return;
        checkOwnerChanged();
    }
    
    timer() {
        integer now_unix = now();
        if (now_unix == 0) return; // Overflow protection
        
        // Check if registration window should close
        if (RegistrationWindowOpen) {
            integer elapsed = now_unix - RegistrationWindowStartTime;
            if (elapsed < 0) elapsed = 0; // Overflow protection
            
            if (elapsed >= REGISTRATION_WINDOW_SEC) {
                closeRegistrationWindow();
            }
        }
        
        // Handle pending late broadcast (debounced)
        if (PendingLateBroadcast && !RegistrationWindowOpen) {
            PendingLateBroadcast = FALSE;
            broadcastPluginList();
            logd("Late registration broadcast completed");
        }
        
        // Periodic heartbeat
        integer ping_elapsed = now_unix - LastPingUnix;
        if (ping_elapsed < 0) ping_elapsed = 0; // Overflow protection
        
        if (ping_elapsed >= PING_INTERVAL_SEC) {
            broadcastPing();
            pruneDeadPlugins();
            LastPingUnix = now_unix;
        }
        
        // Periodic inventory sweep
        integer inv_elapsed = now_unix - LastInvSweepUnix;
        if (inv_elapsed < 0) inv_elapsed = 0; // Overflow protection
        
        if (inv_elapsed >= INV_SWEEP_INTERVAL) {
            pruneMissingScripts();
            LastInvSweepUnix = now_unix;
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (num != KERNEL_LIFECYCLE) return;
        if (!jsonHas(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type == "register") {
            handleRegister(msg);
        }
        else if (msg_type == "pong") {
            handlePong(msg);
        }
        else if (msg_type == "plugin_list_request") {
            handlePluginListRequest();
        }
        else if (msg_type == "soft_reset") {
            handleSoftReset(msg);
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            checkOwnerChanged();
        }
        
        if (change & CHANGED_INVENTORY) {
            // Check if SCRIPTS were added/removed (not notecards)
            integer current_script_count = countScripts();
            
            if (current_script_count != LastScriptCount) {
                logd("Script count changed: " + (string)LastScriptCount + " -> " + (string)current_script_count);
                LastScriptCount = current_script_count;
                
                // Trigger re-registration to rebuild plugin list
                PluginRegistry = [];
                broadcastRegisterNow();
            }
        }
    }
}
