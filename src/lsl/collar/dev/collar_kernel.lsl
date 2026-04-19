/*--------------------
MODULE: collar_kernel.lsl
VERSION: 1.10
REVISION: 3
PURPOSE: Plugin registry, lifecycle management, heartbeat monitoring
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 3: KERNEL_LIFECYCLE wire-type rename (Phase 1 of bus
  restructuring). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.pluginlist→
  kernel.plugins.list, kernel.pluginlistrequest→kernel.plugins.request,
  kernel.reset→kernel.reset.soft, kernel.resetall→kernel.reset.factory.
  Plugins still emit old names until Phase 2; this module will not
  register them or respond to their pings until they migrate.
- v1.1 rev 2: Namespaced internal message type strings with "kernel." prefix
  (register_now → kernel.registernow, ping → kernel.ping, etc.).
- v1.1 rev 1: Removed min_acl from registry and registration flow. Plugins no
  longer send min_acl (superseded by LSD policies). Removed route_field to
  AUTH_BUS register_acl and handle_acl_registry_request — auth module no longer
  maintains a plugin ACL registry.
- v1.1 rev 0: Version bump for LSD policy architecture. No functional changes to this module.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;

/* -------------------- CONSTANTS -------------------- */
float   PING_INTERVAL_SEC     = 10.0;
integer PING_TIMEOUT_SEC      = 30;
float   INV_SWEEP_INTERVAL    = 3.0;
float   BATCH_WINDOW_SEC      = 0.1;  // Small batch window during startup burst
float   DISCOVERY_INTERVAL_SEC = 5.0;  // Active plugin discovery interval

/* Registry stride: [context, label, script, script_uuid, last_seen_unix] */
integer REG_STRIDE = 5;
integer REG_CONTEXT = 0;
integer REG_LABEL = 1;
integer REG_SCRIPT = 2;
integer REG_SCRIPT_UUID = 3;
integer REG_LAST_SEEN = 4;

/* Plugin operation queue stride: [op_type, context, label, script, timestamp] */
integer QUEUE_STRIDE = 5;
integer QUEUE_OP_TYPE = 0;    // "REG" or "UNREG"
integer QUEUE_CONTEXT = 1;
integer QUEUE_LABEL = 2;
integer QUEUE_SCRIPT = 3;


/* -------------------- STATE -------------------- */
list PluginRegistry = [];           // Active plugin registry
list PluginContexts = [];           // Parallel list for O(1) context lookups
list PluginScripts = [];            // Parallel list for O(1) script lookups
list RegistrationQueue = [];        // Pending operations queue (Unix modprobe style)
integer PendingBatchTimer = FALSE;  // TRUE if batch timer is active
integer PendingPluginListRequest = FALSE;  // TRUE if plugin_list_request received during batch
integer LastPingUnix = 0;
integer LastInvSweepUnix = 0;
integer LastDiscoveryUnix = 0;      // Track last active plugin discovery
key LastOwner = NULL_KEY;
integer LastScriptCount = 0;        // Track script count to detect add/remove
integer LastRegionCrossUnix = 0;    // Timestamp of last region crossing

/* -------------------- HELPERS -------------------- */


string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

integer now() {
    return llGetUnixTime();
}

integer count_scripts() {
    return llGetInventoryNumber(INVENTORY_SCRIPT);
}


/* -------------------- QUEUE MANAGEMENT (Unix modprobe-style) -------------------- */

// Add operation to queue (deduplicates by context)
// Schedules batch processing if not already scheduled
// Returns: 1 (void function)
//
// PERFORMANCE NOTE: Deduplication is O(n) but intentional:
// - Typical startup has ~15 plugins (n is small)
// - Deduplicating at insertion prevents duplicate operations in batch
// - Guarantees queue contains at most one operation per context
// - Alternative (defer to batch) would process duplicates and cause multiple broadcasts
integer queue_add(string op_type, string context, string label, string script) {
    // Remove any existing queue entry for this context (newest operation wins)
    list new_queue = [];
    integer i = 0;
    integer queue_len = llGetListLength(RegistrationQueue);
    while (i < queue_len) {
        string queued_context = llList2String(RegistrationQueue, i + QUEUE_CONTEXT);
        if (queued_context != context) {
            new_queue += llList2List(RegistrationQueue, i, i + QUEUE_STRIDE - 1);
        }
        i += QUEUE_STRIDE;
    }

    // Add new operation to queue
    integer timestamp = now();
    new_queue += [op_type, context, label, script, timestamp];
    RegistrationQueue = new_queue;


    // Schedule batch processing if not already scheduled
    // This creates a small batching window for startup bursts
    if (!PendingBatchTimer) {
        PendingBatchTimer = TRUE;
        llSetTimerEvent(BATCH_WINDOW_SEC);
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
        }
        return FALSE;
    }

    integer changes_made = FALSE;
    integer i = 0;


    integer reg_queue_len = llGetListLength(RegistrationQueue);
    while (i < reg_queue_len) {
        string op_type = llList2String(RegistrationQueue, i + QUEUE_OP_TYPE);
        string context = llList2String(RegistrationQueue, i + QUEUE_CONTEXT);
        string label = llList2String(RegistrationQueue, i + QUEUE_LABEL);
        string script = llList2String(RegistrationQueue, i + QUEUE_SCRIPT);

        if (op_type == "REG") {
            // Returns TRUE if new plugin OR if existing plugin data changed
            integer reg_delta = registry_upsert(context, label, script);
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

/* -------------------- REGISTRY MANAGEMENT -------------------- */

// Find plugin index in registry by context
integer registry_find(string context) {
    integer idx = llListFindList(PluginContexts, [context]);
    if (idx != -1) {
        return idx * REG_STRIDE;
    }
    return -1;
}

// Add or update plugin in registry
// Returns TRUE if new plugin added OR script UUID changed (recompiled/updated)
// Returns FALSE only if re-registering with identical UUID
integer registry_upsert(string context, string label, string script) {
    integer idx = registry_find(context);

    // Get script UUID - changes when script is recompiled/replaced
    // PERFORMANCE NOTE: llGetInventoryKey() is called on every upsert (intentional):
    // - This is the ONLY way to detect script recompilation
    // - Caching would defeat the purpose (we need to detect UUID changes)
    // - Inventory lookup is O(1) by name, not expensive for single-prim design
    // - Only called during registration bursts, not in steady state
    key script_uuid = llGetInventoryKey(script);

    if (idx == -1) {
        // New plugin - add to registry
        PluginRegistry += [context, label, script, script_uuid, now()];
        PluginContexts += [context];
        PluginScripts += [script];
        return TRUE;
    }
    else {
        // Existing plugin - check if script UUID changed
        key old_uuid = llList2Key(PluginRegistry, idx + REG_SCRIPT_UUID);

        integer uuid_changed = (old_uuid != script_uuid);

        // Update registry (timestamp always updates) - batched for performance
        PluginRegistry = llListReplaceList(PluginRegistry,
            [label, script, script_uuid, now()],
            idx + REG_LABEL,
            idx + REG_LAST_SEEN);

        // Update parallel script list (in case script name changed for same context, though unlikely)
        integer list_idx = idx / REG_STRIDE;
        PluginScripts = llListReplaceList(PluginScripts, [script], list_idx, list_idx);

        // Note: uuid_changed tracked but not logged to reduce spam

        return uuid_changed;
    }
}

// Remove plugin from registry
// Returns TRUE if plugin was removed, FALSE if not found
integer registry_remove(string context) {
    integer idx = registry_find(context);
    if (idx == -1) return FALSE;

    PluginRegistry = llDeleteSubList(PluginRegistry, idx, idx + REG_STRIDE - 1);
    
    integer list_idx = idx / REG_STRIDE;
    PluginContexts = llDeleteSubList(PluginContexts, list_idx, list_idx);
    PluginScripts = llDeleteSubList(PluginScripts, list_idx, list_idx);
    
    return TRUE;
}

// Update last_seen timestamp for plugin
// Returns: 1 (void function)
integer update_last_seen(string context) {
    integer idx = registry_find(context);
    if (idx != -1) {
        PluginRegistry = llListReplaceList(PluginRegistry, [now()], idx + REG_LAST_SEEN, idx + REG_LAST_SEEN);
    }

    return 1;
}

// Remove dead plugins (haven't responded to ping in PING_TIMEOUT_SEC)
integer prune_dead_plugins() {
    integer now_unix = llGetUnixTime();

    // Skip pruning during region crossing grace window
    if (LastRegionCrossUnix > 0 &&
        (now_unix - LastRegionCrossUnix) < PING_TIMEOUT_SEC) return 0;
    LastRegionCrossUnix = 0;

    integer cutoff = now_unix - PING_TIMEOUT_SEC;
    
    integer pruned = 0;
    
    list new_registry = [];
    list new_contexts = [];
    list new_scripts = [];
    integer i = 0;
    integer reg_len = llGetListLength(PluginRegistry);
    while (i < reg_len) {
        integer last_seen = llList2Integer(PluginRegistry, i + REG_LAST_SEEN);
        
        if (last_seen >= cutoff) {
            // Keep this plugin
            new_registry += llList2List(PluginRegistry, i, i + REG_STRIDE - 1);
            new_contexts += [llList2String(PluginRegistry, i + REG_CONTEXT)];
            new_scripts += [llList2String(PluginRegistry, i + REG_SCRIPT)];
        }
        else {
            // Prune dead plugin
            pruned += 1;
        }
        
        i += REG_STRIDE;
    }
    
    PluginRegistry = new_registry;
    PluginContexts = new_contexts;
    PluginScripts = new_scripts;
    return pruned;
}

// Remove plugins whose scripts no longer exist in inventory
integer prune_missing_scripts() {
    list new_registry = [];
    list new_contexts = [];
    list new_scripts = [];
    integer pruned = 0;
    integer i = 0;
    integer reg_len2 = llGetListLength(PluginRegistry);
    while (i < reg_len2) {
        string script = llList2String(PluginRegistry, i + REG_SCRIPT);

        if (llGetInventoryType(script) == INVENTORY_SCRIPT) {
            // Script still exists, keep plugin
            new_registry += llList2List(PluginRegistry, i, i + REG_STRIDE - 1);
            new_contexts += [llList2String(PluginRegistry, i + REG_CONTEXT)];
            new_scripts += [script];
        }
        else {
            // Script missing, prune plugin
            pruned += 1;
        }
        
        i += REG_STRIDE;
    }
    
    PluginRegistry = new_registry;
    PluginContexts = new_contexts;
    PluginScripts = new_scripts;
    return pruned;
}

/* -------------------- PLUGIN DISCOVERY (Active pull-based detection) -------------------- */

// Track all known script UUIDs to detect new/recompiled scripts.
// Name-agnostic: any unrecognized script triggers register_now,
// letting plugins self-identify via registration protocol.
list KnownScriptUUIDs = [];

integer discover_plugins() {
    integer inv_count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i;
    integer discoveries = 0;

    for (i = 0; i < inv_count; i = i + 1) {
        string script_name = llGetInventoryName(INVENTORY_SCRIPT, i);
        key script_uuid = llGetInventoryKey(script_name);

        // Skip self (kernel)
        if (script_name == llGetScriptName()) jump next_script;

        if (llListFindList(KnownScriptUUIDs, [script_uuid]) == -1) {
            discoveries = discoveries + 1;
        }

        @next_script;
    }

    if (discoveries > 0) {
        // Rebuild known UUIDs from current inventory
        KnownScriptUUIDs = [];
        for (i = 0; i < inv_count; i = i + 1) {
            string sn = llGetInventoryName(INVENTORY_SCRIPT, i);
            if (sn != llGetScriptName()) {
                KnownScriptUUIDs += [llGetInventoryKey(sn)];
            }
        }
        broadcast_register_now();
    }

    return discoveries;
}

/* -------------------- BROADCASTING -------------------- */

// Request all plugins to register (no time window - event-driven)
broadcast_register_now() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register.refresh"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

}

// Heartbeat ping to all plugins
broadcast_ping() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.ping"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    // Ping logging disabled - too noisy
}

// Send current plugin list (only when registry changes)
broadcast_plugin_list() {
    list plugins = [];
    integer i = 0;
    integer reg_len = llGetListLength(PluginRegistry);
    while (i < reg_len) {
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
    integer plugins_len = llGetListLength(plugins);
    for (j = 0; j < plugins_len; j = j + 1) {
        if (j > 0) plugins_array += ",";
        plugins_array += llList2String(plugins, j);
    }
    plugins_array += "]";

    // Build final message (no version - UUID tracking handles change detection)
    string msg = "{\"type\":\"kernel.plugins.list\",\"plugins\":" + plugins_array + "}";

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- OWNER CHANGE DETECTION -------------------- */

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

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_register(string msg) {
    string context = llJsonGetValue(msg, ["context"]);
    if (context == JSON_INVALID) return;
    string label = llJsonGetValue(msg, ["label"]);
    if (label == JSON_INVALID) return;
    string script = llJsonGetValue(msg, ["script"]);
    if (script == JSON_INVALID) return;

    queue_add("REG", context, label, script);
}

handle_pong(string msg) {
    string context = llJsonGetValue(msg, ["context"]);
    if (context == JSON_INVALID) return;
    update_last_seen(context);
    // Pong logging disabled - too noisy
}

handle_plugin_list_request() {
    // RACE CONDITION FIX: If batch timer is active, defer broadcast
    // until registration window completes
    if (PendingBatchTimer) {
        PendingPluginListRequest = TRUE;
        return;
    }

    // Process any pending queue operations first
    process_queue();

    // Broadcast current list
    broadcast_plugin_list();
}

handle_soft_reset() {
    PluginRegistry = [];
    PluginContexts = [];
    PluginScripts = [];
    RegistrationQueue = [];
    KnownScriptUUIDs = [];
    PendingBatchTimer = FALSE;
    PendingPluginListRequest = FALSE;
    LastPingUnix = now();
    LastInvSweepUnix = now();
    LastDiscoveryUnix = now();
    llSetTimerEvent(PING_INTERVAL_SEC);
    broadcast_register_now();
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        LastOwner = llGetOwner();
        PluginRegistry = [];
        PluginContexts = [];
        PluginScripts = [];
        RegistrationQueue = [];
        PendingBatchTimer = FALSE;
        PendingPluginListRequest = FALSE;
        LastPingUnix = now();
        LastInvSweepUnix = now();
        LastDiscoveryUnix = now();
        LastScriptCount = count_scripts();
        KnownScriptUUIDs = [];

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
        integer t = llGetUnixTime();
        if (t == 0) return; // Overflow protection

        // DUAL-MODE TIMER: Batch mode (0.1s) or Heartbeat mode (5s)
        if (PendingBatchTimer) {
            // Batch mode: Process queue and broadcast
            integer changes = process_queue();

            // RACE CONDITION FIX: Broadcast if changes OR if plugin_list_request pending
            if (changes || PendingPluginListRequest) {
                broadcast_plugin_list();
                PendingPluginListRequest = FALSE;
            }
            // process_queue() automatically switches back to heartbeat mode
        }
        else {
            // Heartbeat mode: Periodic maintenance only
            integer ping_elapsed = t - LastPingUnix;
            if (ping_elapsed < 0) ping_elapsed = 0; // Overflow protection

            if (ping_elapsed >= PING_INTERVAL_SEC) {
                broadcast_ping();

                // Prune dead plugins and broadcast if any removed
                integer pruned = prune_dead_plugins();
                if (pruned > 0) {
                    broadcast_plugin_list();
                }

                LastPingUnix = t;
            }

            // Periodic inventory sweep
            integer inv_elapsed = t - LastInvSweepUnix;
            if (inv_elapsed < 0) inv_elapsed = 0; // Overflow protection

            if (inv_elapsed >= INV_SWEEP_INTERVAL) {
                // Prune missing scripts and broadcast if any removed
                integer pruned = prune_missing_scripts();
                if (pruned > 0) {
                    broadcast_plugin_list();
                }

                LastInvSweepUnix = t;
            }

            // Periodic active plugin discovery
            integer discovery_elapsed = t - LastDiscoveryUnix;
            if (discovery_elapsed < 0) discovery_elapsed = 0; // Overflow protection

            if (discovery_elapsed >= DISCOVERY_INTERVAL_SEC) {
                // Discover new/changed plugins (triggers register_now if found)
                discover_plugins();
                LastDiscoveryUnix = t;
            }
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.declare") {
                handle_register(msg);
            }
            else if (msg_type == "kernel.pong") {
                handle_pong(msg);
            }
            else if (msg_type == "kernel.plugins.request") {
                handle_plugin_list_request();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                handle_soft_reset();
            }
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            check_owner_changed();
        }

        if (change & CHANGED_REGION) {
            // Region crossing: link messages may be lost, causing stale
            // last_seen timestamps. Record crossing time so prune_dead_plugins()
            // skips culling until one full timeout window has elapsed.
            LastRegionCrossUnix = llGetUnixTime();
            LastPingUnix = LastRegionCrossUnix;
            LastInvSweepUnix = LastRegionCrossUnix;
            LastDiscoveryUnix = LastRegionCrossUnix;

            broadcast_register_now();
        }

        if (change & CHANGED_INVENTORY) {
            // Check if SCRIPTS were added/removed (not notecards)
            integer current_script_count = count_scripts();

            if (current_script_count != LastScriptCount) {
                LastScriptCount = current_script_count;

                // Clear registry, known UUIDs, and queue — trigger re-registration
                PluginRegistry = [];
                PluginContexts = [];
                PluginScripts = [];
                RegistrationQueue = [];
                KnownScriptUUIDs = [];
                PendingBatchTimer = FALSE;
                PendingPluginListRequest = FALSE;
                llSetTimerEvent(PING_INTERVAL_SEC);
                broadcast_register_now();
            }
        }
    }
}
