/* =============================================================================
   MODULE: ds_collar_kernel.lsl (v3.4 - Active Plugin Discovery)
   SECURITY AUDIT: ALL ISSUES FIXED

   ROLE: Plugin registry, lifecycle management, heartbeat monitoring

   ARCHITECTURE: Unix modprobe-style plugin queue system with active discovery
   - Event-driven registration (no arbitrary time windows)
   - Conditional timer (0.1s batch mode, 5s heartbeat mode)
   - Batch queue processing (prevents broadcast storms)
   - UUID-based change detection (script UUID = version, no counters needed)
   - Atomic operations (consistent state transitions)
   - Deferred plugin_list responses during active registration
   - Active plugin discovery (pull-based, detects new/recompiled scripts)

   ACTIVE DISCOVERY:
   - Periodic inventory enumeration (every 5 seconds)
   - Detects new plugin scripts added to inventory
   - Detects UUID changes (recompiled/replaced scripts)
   - Automatically triggers registration for discovered changes
   - No manual intervention required for dynamic plugin loading

   PERFORMANCE OPTIMIZATIONS:
   - Timer only runs at 0.1s when queue has items (batch window)
   - Automatically switches to 5s heartbeat mode when queue empty
   - Eliminates CPU waste from constant 0.5s polling
   - link_message events trigger batch timer on-demand
   - Discovery only scans plugin scripts (filters system modules)

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
   - [CRITICAL] Race condition fix: deferred plugin_list_request during batch
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
integer AUTH_BUS = 700;
integer UI_BUS = 900;

/* ═══════════════════════════════════════════════════════════
   CONSTANTS
   ═══════════════════════════════════════════════════════════ */
float   PING_INTERVAL_SEC     = 5.0;
integer PING_TIMEOUT_SEC      = 15;
float   INV_SWEEP_INTERVAL    = 3.0;
float   BATCH_WINDOW_SEC      = 0.1;  // Small batch window during startup burst
float   DISCOVERY_INTERVAL_SEC = 5.0;  // Active plugin discovery interval

/* Registry stride: [context, label, script, script_uuid, last_seen_unix, min_acl] */
integer REG_STRIDE = 6;
integer REG_CONTEXT = 0;
integer REG_LABEL = 1;
integer REG_SCRIPT = 2;
integer REG_SCRIPT_UUID = 3;
integer REG_LAST_SEEN = 4;
integer REG_MIN_ACL = 5;    // Stored for auth module recovery (not used for decisions)

/* Plugin operation queue stride: [op_type, context, label, script, min_acl, timestamp] */
integer QUEUE_STRIDE = 6;
integer QUEUE_OP_TYPE = 0;    // "REG" or "UNREG"
integer QUEUE_CONTEXT = 1;
integer QUEUE_LABEL = 2;
integer QUEUE_SCRIPT = 3;
integer QUEUE_MIN_ACL = 4;    // Stored for auth module recovery (not used for decisions)
integer QUEUE_TIMESTAMP = 5;  // Registration timestamp

/* Authorized senders for privileged operations */
list AUTHORIZED_RESET_SENDERS = ["bootstrap", "maintenance"];

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
list PluginRegistry = [];           // Active plugin registry
list RegistrationQueue = [];        // Pending operations queue (Unix modprobe style)
integer PendingBatchTimer = FALSE;  // TRUE if batch timer is active
integer PendingPluginListRequest = FALSE;  // TRUE if plugin_list_request received during batch
integer LastPingUnix = 0;
integer LastInvSweepUnix = 0;
integer LastDiscoveryUnix = 0;      // Track last active plugin discovery
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

integer is_plugin_script(string script_name) {
    // Plugins all start with ds_collar_plugin_
    return (llSubStringIndex(script_name, "ds_collar_plugin_") == 0);
}

/* ═══════════════════════════════════════════════════════════
   QUEUE MANAGEMENT (Unix modprobe-style)
   ═══════════════════════════════════════════════════════════ */

// Add operation to queue (deduplicates by context)
// Schedules batch processing if not already scheduled
// Returns: 1 (void function)
//
// PERFORMANCE NOTE: Deduplication is O(n) but intentional:
// - Typical startup has ~15 plugins (n is small)
// - Deduplicating at insertion prevents duplicate operations in batch
// - Guarantees queue contains at most one operation per context
// - Alternative (defer to batch) would process duplicates and cause multiple broadcasts
integer queue_add(string op_type, string context, string label, string script, integer min_acl) {
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
    new_queue += [op_type, context, label, script, min_acl, timestamp];
    RegistrationQueue = new_queue;

    logd("Queued " + op_type + ": " + context + " (" + label + ") min_acl=" + (string)min_acl);

    // Schedule batch processing if not already scheduled
    // This creates a small batching window for startup bursts
    if (!PendingBatchTimer) {
        PendingBatchTimer = TRUE;
        llSetTimerEvent(BATCH_WINDOW_SEC);
        logd("Batch timer started (" + (string)BATCH_WINDOW_SEC + "s window)");
    }

    return 1;
}

// Process all pending queue operations (atomic batch)
// Returns TRUE if any changes were made to registry
// Resets timer to heartbeat interval after processing
integer process_queue() {
    if (llGetListLength(RegistrationQueue) == 0) {
        // No operations in queue - switch to heartbeat mode
        if (PendingBatchTimer) {
            PendingBatchTimer = FALSE;
            llSetTimerEvent(PING_INTERVAL_SEC);
            logd("Batch timer stopped - switching to heartbeat mode");
        }
        return FALSE;
    }

    integer changes_made = FALSE;
    integer i = 0;
    integer len = llGetListLength(RegistrationQueue);

    logd("Processing queue: " + (string)(len / QUEUE_STRIDE) + " operations");

    while (i < len) {
        string op_type = llList2String(RegistrationQueue, i + QUEUE_OP_TYPE);
        string context = llList2String(RegistrationQueue, i + QUEUE_CONTEXT);
        string label = llList2String(RegistrationQueue, i + QUEUE_LABEL);
        string script = llList2String(RegistrationQueue, i + QUEUE_SCRIPT);
        integer min_acl = llList2Integer(RegistrationQueue, i + QUEUE_MIN_ACL);

        if (op_type == "REG") {
            // Returns TRUE if new plugin OR if existing plugin data changed
            integer reg_delta = registry_upsert(context, label, script, min_acl);
            if (reg_delta) changes_made = TRUE;
        }
        else if (op_type == "UNREG") {
            integer was_removed = registry_remove(context);
            if (was_removed) changes_made = TRUE;
        }

        i += QUEUE_STRIDE;
    }

    // Clear queue
    RegistrationQueue = [];

    // Reset to heartbeat mode
    PendingBatchTimer = FALSE;
    llSetTimerEvent(PING_INTERVAL_SEC);

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

integer registry_find_by_script(string script_name) {
    integer i = 0;
    integer len = llGetListLength(PluginRegistry);
    while (i < len) {
        if (llList2String(PluginRegistry, i + REG_SCRIPT) == script_name) {
            return i;
        }
        i += REG_STRIDE;
    }
    return -1;
}

// Add or update plugin in registry
// Returns TRUE if new plugin added OR script UUID changed (recompiled/updated)
// Returns FALSE only if re-registering with identical UUID
integer registry_upsert(string context, string label, string script, integer min_acl) {
    integer idx = registry_find(context);
    integer now_unix = now();

    // Get script UUID - changes when script is recompiled/replaced
    // PERFORMANCE NOTE: llGetInventoryKey() is called on every upsert (intentional):
    // - This is the ONLY way to detect script recompilation
    // - Caching would defeat the purpose (we need to detect UUID changes)
    // - Inventory lookup is O(1) by name, not expensive for single-prim design
    // - Only called during registration bursts, not in steady state
    key script_uuid = llGetInventoryKey(script);

    if (idx == -1) {
        // New plugin - add to registry
        PluginRegistry += [context, label, script, script_uuid, now_unix, min_acl];
        logd("Registered: " + context + " (" + label + ") min_acl=" + (string)min_acl + " UUID=" + (string)script_uuid);
        return TRUE;
    }
    else {
        // Existing plugin - check if script UUID changed
        key old_uuid = llList2Key(PluginRegistry, idx + REG_SCRIPT_UUID);

        integer uuid_changed = (old_uuid != script_uuid);

        // Update registry (timestamp and min_acl always update)
        PluginRegistry = llListReplaceList(PluginRegistry, [label], idx + REG_LABEL, idx + REG_LABEL);
        PluginRegistry = llListReplaceList(PluginRegistry, [script], idx + REG_SCRIPT, idx + REG_SCRIPT);
        PluginRegistry = llListReplaceList(PluginRegistry, [script_uuid], idx + REG_SCRIPT_UUID, idx + REG_SCRIPT_UUID);
        PluginRegistry = llListReplaceList(PluginRegistry, [now_unix], idx + REG_LAST_SEEN, idx + REG_LAST_SEEN);
        PluginRegistry = llListReplaceList(PluginRegistry, [min_acl], idx + REG_MIN_ACL, idx + REG_MIN_ACL);

        if (uuid_changed) {
            logd("Updated (UUID changed): " + context + " (" + label + ") min_acl=" + (string)min_acl + " " +
                 (string)old_uuid + " -> " + (string)script_uuid);
        }
        else {
            logd("Updated (no change): " + context + " min_acl=" + (string)min_acl);
        }

        return uuid_changed;
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
// Returns: 1 (void function)
integer update_last_seen(string context) {
    integer idx = registry_find(context);
    if (idx != -1) {
        integer now_unix = now();
        PluginRegistry = llListReplaceList(PluginRegistry, [now_unix], idx + REG_LAST_SEEN, idx + REG_LAST_SEEN);
    }

    return 1;
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
   PLUGIN DISCOVERY (Active pull-based detection)
   ═══════════════════════════════════════════════════════════ */

// Actively discover new or changed plugin scripts
// Enumerates inventory, detects new/recompiled plugins, triggers registration
integer discover_plugins() {
    integer inv_count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i;
    integer discoveries = 0;

    for (i = 0; i < inv_count; i = i + 1) {
        string script_name = llGetInventoryName(INVENTORY_SCRIPT, i);

        // Only check plugin scripts (not kernel modules)
        if (!is_plugin_script(script_name)) jump next_script;

        key script_uuid = llGetInventoryKey(script_name);
        integer idx = registry_find_by_script(script_name);

        // New script - not in registry
        if (idx == -1) {
            discoveries = discoveries + 1;
            logd("Discovered new plugin: " + script_name);
            jump next_script;
        }

        // Check if UUID changed (recompiled/replaced)
        key registered_uuid = llList2Key(PluginRegistry, idx + REG_SCRIPT_UUID);
        if (registered_uuid != script_uuid) {
            discoveries = discoveries + 1;
            logd("Detected UUID change: " + script_name);
        }

        @next_script;
    }

    // If we found new/changed scripts, broadcast register_now
    if (discoveries > 0) {
        logd("Active discovery: " + (string)discoveries + " new/changed plugins");
        broadcast_register_now();
    }

    return discoveries;
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

// Send current plugin list (only when registry changes)
// SECURITY FIX: Use proper JSON encoding to prevent string injection
broadcast_plugin_list() {
    list plugins = [];
    integer i = 0;
    integer len = llGetListLength(PluginRegistry);

    while (i < len) {
        string context = llList2String(PluginRegistry, i + REG_CONTEXT);
        string label = llList2String(PluginRegistry, i + REG_LABEL);

        // Build individual plugin object with proper JSON encoding
        string plugin_obj = llList2Json(JSON_OBJECT, [
            "context", context,
            "label", label
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

    // Build final message (no version - UUID tracking handles change detection)
    string msg = "{\"type\":\"plugin_list\",\"plugins\":" + plugins_array + "}";

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Broadcast: plugin_list (" + (string)llGetListLength(plugins) + " plugins)");
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

    // Add to lifecycle queue (kernel stores min_acl for auth recovery, not enforcement)
    queue_add("REG", context, label, script, min_acl);

    // Forward ACL requirement to auth module (auth's concern for enforcement)
    string auth_msg = llList2Json(JSON_OBJECT, [
        "type", "register_acl",
        "context", context,
        "min_acl", min_acl
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, auth_msg, NULL_KEY);

    // Forward chat commands to chat command module (if present)
    if (json_has(msg, ["commands"])) {
        string commands_json = llJsonGetValue(msg, ["commands"]);
        string chatcmd_msg = llList2Json(JSON_OBJECT, [
            "type", "chatcmd_register",
            "context", context,
            "commands", commands_json
        ]);
        llMessageLinked(LINK_SET, UI_BUS, chatcmd_msg, NULL_KEY);
        logd("Routed commands to chat module: " + context);
    }
}

handle_pong(string msg) {
    if (!json_has(msg, ["context"])) return;
    
    string context = llJsonGetValue(msg, ["context"]);
    update_last_seen(context);
    // Pong logging disabled - too noisy
}

handle_plugin_list_request() {
    // RACE CONDITION FIX: If batch timer is active, defer broadcast
    // until registration window completes
    if (PendingBatchTimer) {
        PendingPluginListRequest = TRUE;
        logd("Plugin list request deferred - waiting for registration batch to complete");
        return;
    }

    // Process any pending queue operations first
    process_queue();

    // Broadcast current list
    broadcast_plugin_list();
    logd("Plugin list broadcast (immediate response)");
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
    PendingBatchTimer = FALSE;
    PendingPluginListRequest = FALSE;
    LastPingUnix = now();
    LastInvSweepUnix = now();
    LastDiscoveryUnix = now();
    llSetTimerEvent(PING_INTERVAL_SEC);
    broadcast_register_now();
}

handle_acl_registry_request() {
    // Auth module requesting ACL repopulation (recovery from reset)
    // Send all ACL data from kernel's registry
    logd("ACL registry request received from auth module");

    integer i = 0;
    integer len = llGetListLength(PluginRegistry);

    while (i < len) {
        string context = llList2String(PluginRegistry, i + REG_CONTEXT);
        integer min_acl = llList2Integer(PluginRegistry, i + REG_MIN_ACL);

        // Send register_acl message for each plugin
        string auth_msg = llList2Json(JSON_OBJECT, [
            "type", "register_acl",
            "context", context,
            "min_acl", min_acl
        ]);
        llMessageLinked(LINK_SET, AUTH_BUS, auth_msg, NULL_KEY);

        i += REG_STRIDE;
    }

    logd("ACL registry sent: " + (string)(len / REG_STRIDE) + " entries");
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
        PendingBatchTimer = FALSE;
        PendingPluginListRequest = FALSE;
        LastPingUnix = now();
        LastInvSweepUnix = now();
        LastDiscoveryUnix = now();
        LastScriptCount = count_scripts();

        logd("Kernel started (UUID-based change detection, active plugin discovery)");

        // Immediately broadcast register_now (plugins add to queue)
        broadcast_register_now();

        // Start timer in heartbeat mode (batch timer will override when needed)
        llSetTimerEvent(PING_INTERVAL_SEC);
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

        // DUAL-MODE TIMER: Batch mode (0.1s) or Heartbeat mode (5s)
        if (PendingBatchTimer) {
            // Batch mode: Process queue and broadcast
            integer changes = process_queue();

            // RACE CONDITION FIX: Broadcast if changes OR if plugin_list_request pending
            if (changes || PendingPluginListRequest) {
                broadcast_plugin_list();
                if (PendingPluginListRequest) {
                    logd("Plugin list broadcast (deferred response to request)");
                }
                PendingPluginListRequest = FALSE;
            }
            // process_queue() automatically switches back to heartbeat mode
        }
        else {
            // Heartbeat mode: Periodic maintenance only
            integer ping_elapsed = now_unix - LastPingUnix;
            if (ping_elapsed < 0) ping_elapsed = 0; // Overflow protection

            if (ping_elapsed >= PING_INTERVAL_SEC) {
                broadcast_ping();

                // Prune dead plugins and broadcast if any removed
                integer pruned = prune_dead_plugins();
                if (pruned > 0) {
                    logd("Pruned " + (string)pruned + " dead plugins");
                    broadcast_plugin_list();
                }

                LastPingUnix = now_unix;
            }

            // Periodic inventory sweep
            integer inv_elapsed = now_unix - LastInvSweepUnix;
            if (inv_elapsed < 0) inv_elapsed = 0; // Overflow protection

            if (inv_elapsed >= INV_SWEEP_INTERVAL) {
                // Prune missing scripts and broadcast if any removed
                integer pruned = prune_missing_scripts();
                if (pruned > 0) {
                    logd("Pruned " + (string)pruned + " missing scripts");
                    broadcast_plugin_list();
                }

                LastInvSweepUnix = now_unix;
            }

            // Periodic active plugin discovery
            integer discovery_elapsed = now_unix - LastDiscoveryUnix;
            if (discovery_elapsed < 0) discovery_elapsed = 0; // Overflow protection

            if (discovery_elapsed >= DISCOVERY_INTERVAL_SEC) {
                // Discover new/changed plugins (triggers register_now if found)
                discover_plugins();
                LastDiscoveryUnix = now_unix;
            }
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!json_has(msg, ["type"])) return;

        string msg_type = llJsonGetValue(msg, ["type"]);

        if (num == KERNEL_LIFECYCLE) {
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
        else if (num == AUTH_BUS) {
            if (msg_type == "acl_registry_request") {
                handle_acl_registry_request();
            }
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
                PendingBatchTimer = FALSE;
                PendingPluginListRequest = FALSE;
                llSetTimerEvent(PING_INTERVAL_SEC);
                broadcast_register_now();
            }
        }
    }
}
