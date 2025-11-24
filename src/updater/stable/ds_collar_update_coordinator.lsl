/*--------------------
SCRIPT: ds_collar_update_coordinator.lsl
VERSION: 1.00
REVISION: 16
PURPOSE: Autonomous update coordinator injected via llRemoteLoadScriptPin
ARCHITECTURE: Arrives RUNNING, orchestrates update, then triggers activator shim
CHANGES:
- Rev 16: Integrated settings restoration (removed activator shim dependency)
- Rev 15: Fixed self-destruct on rez/reset (added on_rez and guarded changed event)
- Rev 15: Fixed ACL backup format to match activator expectations (JSON object with keys/values)
- Rev 14: Don't self-destruct in abort_update() unless actually injected (prevents deletion from updater)
- Rev 13: Store expected item count in linkset data for activator verification
- Rev 12: Only accept negative start params as SecureChannel (distinguish injection from object rez)
- Rev 11: Simplified dormancy check - only check SecureChannel (if 0, we're in updater not injected)
- Rev 10: Delete kmod_remote immediately (only needed for injection), fix item count (script_count - 1)
- Rev 9: Build deletion lists BEFORE removing any items to avoid "Missing inventory item" errors
  Increased sleep to 3.0s to ensure kernel fully initializes before deletion
- Rev 8: Coordinator stays dormant in updater inventory (SecureChannel == 0)
  When injected via PIN into collar, activates and self-destructs from collar when done
- Rev 7: Fixed missing initial coordinator_ready signal after injection
- Rev 6: Added support for object transfers (control HUD, leash holder)
- Rev 5: Removed unnecessary len variable optimizations
- Rev 4: Simplified flow - backs up settings, clears inventory, signals updater for activator shim injection
- Activator shim (injected last) handles script activation and settings restoration
- Coordinator self-destructs from COLLAR after triggering activator injection
- No script activation or settings restoration in coordinator
--------------------*/

/* -------------------- CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- STATE -------------------- */
integer SecureChannel = 0;
key UpdaterKey = NULL_KEY;
string UpdateSession = "";
string PendingItem = "";
integer ExpectedItems = 0;
integer ReceivedItems = 0;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* -------------------- SETTINGS BACKUP -------------------- */

backup_settings() {
    // Request full settings from settings module
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get",
        "key", ""  // Empty key = get all settings
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    
    // Backup ACL cache from linkset data
    list all_keys = llLinksetDataListKeys(0, 1000);
    list acl_keys = [];
    list acl_values = [];
    integer i = 0;
    
    while (i < llGetListLength(all_keys)) {
        string ld_key = llList2String(all_keys, i);
        if (llSubStringIndex(ld_key, "acl_cache_") == 0) {
            string value = llLinksetDataRead(ld_key);
            acl_keys += [ld_key];
            acl_values += [value];
        }
        i += 1;
    }
    
    // Store ACL backup as JSON object with keys/values arrays
    if (llGetListLength(acl_keys) > 0) {
        string acl_json = llList2Json(JSON_OBJECT, [
            "keys", llList2Json(JSON_ARRAY, acl_keys),
            "values", llList2Json(JSON_ARRAY, acl_values)
        ]);
        llLinksetDataWrite("ACL.UPDATE", acl_json);
    }
}

/* -------------------- INVENTORY CLEARING -------------------- */

clear_inventory() {
    // Soft reset all scripts first
    string msg = llList2Json(JSON_OBJECT, ["type", "soft_reset_all", "from", "coordinator"]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    
    llSleep(3.0);  // Give scripts time to reset and stop (increased for kernel init)
    
    // Build list of items to remove FIRST (before any deletion)
    list scripts_to_remove = [];
    list anims_to_remove = [];
    list objects_to_remove = [];
    
    // Collect script names (including kmod_remote - no longer needed)
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < count) {
        string script_name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (script_name != "" && script_name != llGetScriptName()) {
            scripts_to_remove += [script_name];
        }
        i += 1;
    }
    
    // Collect animation names
    count = llGetInventoryNumber(INVENTORY_ANIMATION);
    i = 0;
    while (i < count) {
        string anim_name = llGetInventoryName(INVENTORY_ANIMATION, i);
        if (anim_name != "") {
            anims_to_remove += [anim_name];
        }
        i += 1;
    }
    
    // Collect object names
    count = llGetInventoryNumber(INVENTORY_OBJECT);
    i = 0;
    while (i < count) {
        string obj_name = llGetInventoryName(INVENTORY_OBJECT, i);
        if (obj_name != "") {
            objects_to_remove += [obj_name];
        }
        i += 1;
    }
    
    // Now delete using the collected lists (safe from index shifting)
    i = 0;
    while (i < llGetListLength(scripts_to_remove)) {
        llRemoveInventory(llList2String(scripts_to_remove, i));
        i += 1;
    }
    
    i = 0;
    while (i < llGetListLength(anims_to_remove)) {
        llRemoveInventory(llList2String(anims_to_remove, i));
        i += 1;
    }
    
    i = 0;
    while (i < llGetListLength(objects_to_remove)) {
        llRemoveInventory(llList2String(objects_to_remove, i));
        i += 1;
    }
    
    // DO NOT remove notecards - they contain settings data
    
    signal_ready_for_content();
}

/* -------------------- UPDATER COMMUNICATION -------------------- */

signal_ready_for_content() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "coordinator_ready",
        "session", UpdateSession
    ]);
    llRegionSayTo(UpdaterKey, SecureChannel, msg);
}

/* -------------------- ITEM RECEPTION -------------------- */

handle_item_transfer(string msg) {
    if (!json_has(msg, ["name"])) return;
    PendingItem = llJsonGetValue(msg, ["name"]);
    
    // Robustness: If item already exists (e.g. retry), delete it first to avoid duplicates
    if (llGetInventoryType(PendingItem) != INVENTORY_NONE) {
        llRemoveInventory(PendingItem);
    }
}

/* -------------------- SETTINGS RESTORATION -------------------- */

restore_settings() {
    llOwnerSay("Restoring settings...");
    
    // Read settings from linkset data
    string kv_json = llLinksetDataRead("SETTINGS.UPDATE");
    
    if (kv_json == "" || kv_json == JSON_INVALID) {
        llOwnerSay("WARNING: Could not restore settings backup.");
        return;
    }
    
    // Broadcast settings to all scripts
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_sync",
        "kv", kv_json
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    
    llSleep(1.0);
    
    // Clean up settings backup
    llLinksetDataDelete("SETTINGS.UPDATE");
    
    // CRITICAL: Restore ACL cache entries
    llOwnerSay("Restoring ACL cache...");
    
    string acl_backup = llLinksetDataRead("ACL.UPDATE");
    if (acl_backup != "" && acl_backup != JSON_INVALID) {
        // Parse ACL backup
        string keys_json = llJsonGetValue(acl_backup, ["keys"]);
        string values_json = llJsonGetValue(acl_backup, ["values"]);
        
        if (llJsonValueType(keys_json, []) == JSON_ARRAY && 
            llJsonValueType(values_json, []) == JSON_ARRAY) {
            
            list acl_keys = llJson2List(keys_json);
            list acl_values = llJson2List(values_json);
            
            integer i = 0;
            integer count = llGetListLength(acl_keys);
            
            while (i < count) {
                string k = llList2String(acl_keys, i);
                string v = llList2String(acl_values, i);
                llLinksetDataWrite(k, v);
                i += 1;
            }
            
            llOwnerSay("Restored " + (string)count + " ACL entries.");
        }
        
        // Clean up ACL backup
        llLinksetDataDelete("ACL.UPDATE");
    }
    
    llOwnerSay("Settings restored.");
}

/* -------------------- UPDATE FINALIZATION -------------------- */

finalize_update() {
    llSetTimerEvent(0.0);  // Stop timer
    
    llOwnerSay("All items received. Restoring configuration...");
    
    // Wait a moment for scripts to initialize
    llSleep(3.0);
    
    // Restore settings
    restore_settings();
    
    // Clear script PIN
    llSetRemoteScriptAccessPin(0);
    
    llOwnerSay("Update Complete!");
    
    // Self-destruct
    llRemoveInventory(llGetScriptName());
}

/* -------------------- ABORT HANDLING -------------------- */

abort_update(string reason) {
    llSetTimerEvent(0.0);
    llSetRemoteScriptAccessPin(0);
    
    // Only send abort message if we're actually in an update (have updater key and channel)
    if (UpdaterKey != NULL_KEY && SecureChannel != 0) {
        string msg = llList2Json(JSON_OBJECT, [
            "type", "update_aborted",
            "reason", reason,
            "session", UpdateSession
        ]);
        llRegionSayTo(UpdaterKey, SecureChannel, msg);
        
        // Self-destruct ONLY if we're injected (in collar doing update)
        llRemoveInventory(llGetScriptName());
    }
    // If dormant in updater (no UpdaterKey), do nothing - stay dormant
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Get start parameter (could be from llRemoteLoadScriptPin OR object rez)
        integer start = llGetStartParameter();
        
        // Only accept negative channels (secure channels from injection)
        // Object rez params are typically 0 or positive
        if (start < 0) {
            SecureChannel = start;
        }
        
        // If SecureChannel still 0, we're dormant in updater
        if (SecureChannel == 0) {
            return;  // Stay dormant - not injected via PIN
        }
        
        // Injected into collar via PIN - activate
        
        // Listen on secure channel for updater instructions
        llListen(SecureChannel, "", NULL_KEY, "");
        
        // Signal updater that we're ready for manifest
        // (We don't know UpdaterKey or UpdateSession yet, so use llRegionSay)
        string ready_msg = llList2Json(JSON_OBJECT, [
            "type", "coordinator_ready",
            "session", ""  // Will be set when we receive begin_update
        ]);
        llRegionSay(SecureChannel, ready_msg);
        
        // Start timeout timer (5 minutes)
        llSetTimerEvent(300.0);
    }
    
    listen(integer channel, string name, key speaker, string message) {
        if (channel != SecureChannel) return;
        if (!json_has(message, ["type"])) return;
        
        string msg_type = llJsonGetValue(message, ["type"]);
        
        // Initial handshake: updater sends manifest
        if (msg_type == "begin_update") {
            if (!json_has(message, ["updater"])) return;
            if (!json_has(message, ["session"])) return;
            if (!json_has(message, ["total"])) return;
            
            UpdaterKey = (key)llJsonGetValue(message, ["updater"]);
            UpdateSession = llJsonGetValue(message, ["session"]);
            ExpectedItems = (integer)llJsonGetValue(message, ["total"]);
            
            // Begin update process
            backup_settings();
            clear_inventory();
            return;
        }
        
        // Item transfer notification
        if (msg_type == "item_transfer") {
            if (llJsonGetValue(message, ["session"]) != UpdateSession) return;
            handle_item_transfer(message);
            return;
        }
        
        // Abort command
        if (msg_type == "abort_update") {
            abort_update("Updater requested abort");
            return;
        }
    }
    
    timer() {
        // Timeout - cleanup and abort
        abort_update("Timeout - no response from updater");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            abort_update("Ownership changed during update");
        }
        
        if (change & CHANGED_INVENTORY) {
            // Guard: Only process if we are in an active update
            if (SecureChannel == 0 || UpdaterKey == NULL_KEY) return;

            // Check if PendingItem has arrived
            if (PendingItem != "" && llGetInventoryType(PendingItem) != INVENTORY_NONE) {
                
                // Update count
                integer script_count = llGetInventoryNumber(INVENTORY_SCRIPT);
                integer anim_count = llGetInventoryNumber(INVENTORY_ANIMATION);
                integer object_count = llGetInventoryNumber(INVENTORY_OBJECT);
                
                // Subtract only coordinator from script count
                ReceivedItems = (script_count - 1) + anim_count + object_count;
                
                // Acknowledge receipt
                string ack = llList2Json(JSON_OBJECT, [
                    "type", "item_received",
                    "session", UpdateSession,
                    "count", (string)ReceivedItems,
                    "total", (string)ExpectedItems
                ]);
                llRegionSayTo(UpdaterKey, SecureChannel, ack);
                
                // Clear pending
                PendingItem = "";
                
                // Check if complete
                if (ReceivedItems >= ExpectedItems) {
                    finalize_update();
                }
            }
        }
    }
}
