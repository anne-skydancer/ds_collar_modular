/* =============================================================================
   MODULE: ds_collar_kernel.lsl (v3.0 - Unix Kernel-Style Queue Architecture)
   SECURITY AUDIT: ALL ISSUES FIXED

   ROLE: Plugin registry, lifecycle management, heartbeat monitoring

   ARCHITECTURE: Unix modprobe-style plugin queue system
   - Event-driven registration (no arbitrary time windows)
   - Batch queue processing (prevents broadcast storms)
   - Registry versioning (tracks changes, enables deduplication)
   - Atomic operations (consistent state transitions)

   CHANNELS:
   - 500 (KERNEL_LIFECYCLE): All lifecycle operations

   PREVENTS UNINTENDED UI:
   - Plugin registration does NOT trigger UI display
   - Only explicit touch events show UI
   - Heartbeat is silent
   - Resets are silent

   SECURITY FIXES APPLIED:
   - [CRITICAL] Soft reset now requires authorized sender
   - [CRITICAL] Race condition fix: queue-based plugin management
   - [MEDIUM] JSON construction uses proper encoding (no string injection)
   - [MEDIUM] Integer overflow protection for timestamps
   - [LOW] Production mode guards debug logging
   ============================================================================= */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;

/* ═══════════════════════════════════════════════════════════
   CONSTANTS
   ═══════════════════════════════════════════════════════════ */
float   PING_INTERVAL_SEC     = 5.0;
integer PING_TIMEOUT_SEC      = 15;
float   INV_SWEEP_INTERVAL    = 3.0;
float   QUEUE_PROCESS_INTERVAL = 0.5;  // Process queue twice per second

/* Registry stride: [context, label, min_acl, script, last_seen_unix] */
integer REG_STRIDE = 5;
integer REG_CONTEXT = 0;
integer REG_LABEL = 1;
integer REG_MIN_ACL = 2;
integer REG_SCRIPT = 3;
integer REG_LAST_SEEN = 4;

/* Plugin operation queue stride: [op_type, context, label, min_acl, script, timestamp] */
integer QUEUE_STRIDE = 6;
integer QUEUE_OP_TYPE = 0;    // "REG" or "UNREG"
integer QUEUE_CONTEXT = 1;
integer QUEUE_LABEL = 2;
integer QUEUE_MIN_ACL = 3;
integer QUEUE_SCRIPT = 4;
integer QUEUE_TIMESTAMP = 5;

/* Authorized senders for privileged operations */
list AUTHORIZED_RESET_SENDERS = ["bootstrap", "maintenance"];

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
list PluginRegistry = [];           // Active plugin registry
list RegistrationQueue = [];        // Pending operations queue (Unix modprobe style)
integer RegistryVersion = 0;        // Increments on any registry change
integer LastQueueProcessUnix = 0;   // Last queue processing time
integer LastPingUnix = 0;
integer LastInvSweepUnix = 0;
key LastOwner = NULL_KEY;
integer LastScriptCount = 0;        // Track script count to detect add/remove

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[KERNEL] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
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

integer count_scripts() {
    integer count = 0;
    integer i;
    integer inv_count = llGetInventoryNumber(INVENTORY_SCRIPT);
    for (i = 0; i < inv_count; i = i + 1) {
        count = count + 1;
    }
    return count;
}

integer is_authorized_sender(string sender_name) {
    integer i;
    integer len = llGetListLength(AUTHORIZED_RESET_SENDERS);
    for (i = 0; i < len; i = i + 1) {
        if (llList2String(AUTHORIZED_RESET_SENDERS, i) == sender_name) {
            return TRUE;
        }
    }
    return FALSE;
}

/* ═══════════════════════════════════════════════════════════
   QUEUE MANAGEMENT (Unix modprobe-style)
   ═══════════════════════════════════════════════════════════ */

// Add operation to queue (deduplicates by context)
queue_add(string op_type, string context, string label, integer min_acl, string script) {
    // Remove any existing queue entry for this context (newest operation wins)
    list new_queue = [];
    integer i = 0;
    integer len = llGetListLength(RegistrationQueue);
    while (i < len) {
        string queued_context = llList2String(RegistrationQueue, i + QUEUE_CONTEXT);
        if (queued_context != context) {
            new_queue += llList2List(RegistrationQueue, i, i + QUEUE_STRIDE - 1);
        }
        i += QUEUE_STRIDE;
    }

    // Add new operation to queue
    integer timestamp = now();
    new_queue += [op_type, context, label, min_acl, script, timestamp];
    RegistrationQueue = new_queue;

    logd("Queued " + op_type + ": " + context + " (" + label + ")");
}

// Process all pending queue operations (atomic batch)
// Returns TRUE if any changes were made to registry
integer process_queue() {
    if (llGetListLength(RegistrationQueue) == 0) return FALSE;

    integer changes_made = FALSE;
    integer i = 0;
    integer len = llGetListLength(RegistrationQueue);

    logd("Processing queue: " + (string)(len / QUEUE_STRIDE) + " operations");

    while (i < len) {
        string op_type = llList2String(RegistrationQueue, i + QUEUE_OP_TYPE);
        string context = llList2String(RegistrationQueue, i + QUEUE_CONTEXT);
        string label = llList2String(RegistrationQueue, i + QUEUE_LABEL);
        integer min_acl = llList2Integer(RegistrationQueue, i + QUEUE_MIN_ACL);
        string script = llList2String(RegistrationQueue, i + QUEUE_SCRIPT);

        if (op_type == "REG") {
            integer was_new = registry_upsert(context, label, min_acl, script);
            if (was_new) changes_made = TRUE;
        }
        else if (op_type == "UNREG") {
            integer was_removed = registry_remove(context);
            if (was_removed) changes_made = TRUE;
        }

        i += QUEUE_STRIDE;
    }

    // Clear queue
    RegistrationQueue = [];

    // Increment version if changes were made
    if (changes_made) {
        RegistryVersion = RegistryVersion + 1;
        logd("Registry updated to version " + (string)RegistryVersion);
    }

    return changes_made;
}

/* ═══════════════════════════════════════════════════════════
   REGISTRY MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

// Find plugin index in registry by context
integer registry_find(string context) {
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
// Returns TRUE if new plugin added, FALSE if updated existing
integer registry_upsert(string context, string label, integer min_acl, string script) {
    integer idx = registry_find(context);
    integer now_unix = now();

    if (idx == -1) {
        // New plugin
        PluginRegistry += [context, label, min_acl, script, now_unix];
        logd("Registered: " + context + " (" + label + ")");
        return TRUE;
    }
    else {
        // Update existing
        PluginRegistry = llListReplaceList(PluginRegistry, [label], idx + REG_LABEL, idx + REG_LABEL);
        PluginRegistry = llListReplaceList(PluginRegistry, [min_acl], idx + REG_MIN_ACL, idx + REG_MIN_ACL);
        PluginRegistry = llListReplaceList(PluginRegistry, [script], idx + REG_SCRIPT, idx + REG_SCRIPT);
        PluginRegistry = llListReplaceList(PluginRegistry, [now_unix], idx + REG_LAST_SEEN, idx + REG_LAST_SEEN);
        logd("Updated: " + context);
        return FALSE;
    }
}

// Remove plugin from registry
// Returns TRUE if plugin was removed, FALSE if not found
integer registry_remove(string context) {
    integer idx = registry_find(context);
    if (idx == -1) return FALSE;

    PluginRegistry = llDeleteSubList(PluginRegistry, idx, idx + REG_STRIDE - 1);
    logd("Unregistered: " + context);
    return TRUE;
}

// Update last_seen timestamp for plugin
update_last_seen(string context) {
    integer idx = registry_find(context);
    if (idx != -1) {
        integer now_unix = now();
        PluginRegistry = llListReplaceList(PluginRegistry, [now_unix], idx + REG_LAST_SEEN, idx + REG_LAST_SEEN);
    }
}

// Remove dead plugins (haven't responded to ping in PING_TIMEOUT_SEC)
integer prune_dead_plugins() {
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
integer prune_missing_scripts() {
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

/* ═══════════════════════════════════════════════════════════
   BROADCASTING
   ═══════════════════════════════════════════════════════════ */

// Request all plugins to register (no time window - event-driven)
broadcast_register_now() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register_now"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

    logd("Broadcast: register_now (queue-based processing)");
}

// Heartbeat ping to all plugins
broadcast_ping() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ping"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    // Ping logging disabled - too noisy
}

// Send current plugin list with version number
// SECURITY FIX: Use proper JSON encoding to prevent string injection
broadcast_plugin_list() {
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

    // Build final message with version
    string msg = "{\"type\":\"plugin_list\",\"version\":" + (string)RegistryVersion +
                 ",\"plugins\":" + plugins_array + "}";

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Broadcast: plugin_list v" + (string)RegistryVersion + " (" + (string)llGetListLength(plugins) + " plugins)");
}


// Soft reset request to all modules
broadcast_soft_reset() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "soft_reset",
        "from", "kernel"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Broadcast: soft_reset");
}

/* ═══════════════════════════════════════════════════════════
   OWNER CHANGE DETECTION
   ═══════════════════════════════════════════════════════════ */

integer check_owner_changed() {
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

/* ═══════════════════════════════════════════════════════════
   MESSAGE HANDLERS
   ═══════════════════════════════════════════════════════════ */

handle_register(string msg) {
    if (!json_has(msg, ["context"])) return;
    if (!json_has(msg, ["label"])) return;
    if (!json_has(msg, ["min_acl"])) return;
    if (!json_has(msg, ["script"])) return;

    string context = llJsonGetValue(msg, ["context"]);
    string label = llJsonGetValue(msg, ["label"]);
    integer min_acl = (integer)llJsonGetValue(msg, ["min_acl"]);
    string script = llJsonGetValue(msg, ["script"]);

    // Add to queue - will be processed in next batch
    queue_add("REG", context, label, min_acl, script);
}

handle_pong(string msg) {
    if (!json_has(msg, ["context"])) return;
    
    string context = llJsonGetValue(msg, ["context"]);
    update_last_seen(context);
    // Pong logging disabled - too noisy
}

handle_plugin_list_request() {
    // Process any pending queue operations first
    integer changes = process_queue();

    // Always broadcast current list (with version)
    broadcast_plugin_list();
}

handle_soft_reset(string msg) {
    // SECURITY FIX: Verify sender is authorized to request reset
    string from = llJsonGetValue(msg, ["from"]);

    if (from == JSON_INVALID || from == "") {
        logd("Rejected soft_reset: missing 'from' field");
        llOwnerSay("[KERNEL] ERROR: Soft reset rejected - sender not identified");
        return;
    }

    if (!is_authorized_sender(from)) {
        logd("Rejected soft_reset from unauthorized sender: " + from);
        llOwnerSay("[KERNEL] ERROR: Soft reset rejected - unauthorized sender: " + from);
        return;
    }

    // Authorized - proceed with reset
    logd("Soft reset authorized by: " + from);
    PluginRegistry = [];
    RegistrationQueue = [];
    RegistryVersion = 0;
    LastQueueProcessUnix = now();
    LastPingUnix = now();
    LastInvSweepUnix = now();
    broadcast_register_now();
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default
{
    state_entry() {
        LastOwner = llGetOwner();
        PluginRegistry = [];
        RegistrationQueue = [];
        RegistryVersion = 0;
        LastQueueProcessUnix = now();
        LastPingUnix = now();
        LastInvSweepUnix = now();
        LastScriptCount = count_scripts();

        logd("Kernel started (queue-based plugin management)");

        // Immediately broadcast register_now (plugins add to queue)
        broadcast_register_now();

        // Start timer for queue processing, heartbeat, and inventory sweeps
        llSetTimerEvent(0.5);  // Check twice per second
    }
    
    on_rez(integer start_param) {
        check_owner_changed();
    }
    
    attach(key id) {
        if (id == NULL_KEY) return;
        check_owner_changed();
    }
    
    timer() {
        integer now_unix = now();
        if (now_unix == 0) return; // Overflow protection

        // Process plugin queue (Unix modprobe-style batch processing)
        integer queue_elapsed = now_unix - LastQueueProcessUnix;
        if (queue_elapsed < 0) queue_elapsed = 0; // Overflow protection

        if (queue_elapsed >= QUEUE_PROCESS_INTERVAL) {
            integer changes = process_queue();
            if (changes) {
                // Registry changed - broadcast new version
                broadcast_plugin_list();
            }
            LastQueueProcessUnix = now_unix;
        }

        // Periodic heartbeat and pruning
        integer ping_elapsed = now_unix - LastPingUnix;
        if (ping_elapsed < 0) ping_elapsed = 0; // Overflow protection

        if (ping_elapsed >= PING_INTERVAL_SEC) {
            broadcast_ping();

            // Prune dead plugins and update registry version if needed
            integer pruned = prune_dead_plugins();
            if (pruned > 0) {
                RegistryVersion = RegistryVersion + 1;
                logd("Pruned " + (string)pruned + " dead plugins - version " + (string)RegistryVersion);
                broadcast_plugin_list();
            }

            LastPingUnix = now_unix;
        }

        // Periodic inventory sweep
        integer inv_elapsed = now_unix - LastInvSweepUnix;
        if (inv_elapsed < 0) inv_elapsed = 0; // Overflow protection

        if (inv_elapsed >= INV_SWEEP_INTERVAL) {
            // Prune missing scripts and update registry version if needed
            integer pruned = prune_missing_scripts();
            if (pruned > 0) {
                RegistryVersion = RegistryVersion + 1;
                logd("Pruned " + (string)pruned + " missing scripts - version " + (string)RegistryVersion);
                broadcast_plugin_list();
            }

            LastInvSweepUnix = now_unix;
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (num != KERNEL_LIFECYCLE) return;
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type == "register") {
            handle_register(msg);
        }
        else if (msg_type == "pong") {
            handle_pong(msg);
        }
        else if (msg_type == "plugin_list_request") {
            handle_plugin_list_request();
        }
        else if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
            handle_soft_reset(msg);
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            check_owner_changed();
        }

        if (change & CHANGED_INVENTORY) {
            // Check if SCRIPTS were added/removed (not notecards)
            integer current_script_count = count_scripts();

            if (current_script_count != LastScriptCount) {
                logd("Script count changed: " + (string)LastScriptCount + " -> " + (string)current_script_count);
                LastScriptCount = current_script_count;

                // Clear registry and queue, trigger re-registration
                PluginRegistry = [];
                RegistrationQueue = [];
                RegistryVersion = 0;
                broadcast_register_now();
            }
        }
    }
}
