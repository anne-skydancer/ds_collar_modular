/*--------------------
SCRIPT: ds_collar_update_coordinator.lsl
VERSION: 1.00
REVISION: 8
PURPOSE: Autonomous update coordinator injected via llRemoteLoadScriptPin
ARCHITECCTURE: Arrives RUNNING, orchestrates update, then triggers activator shim
CHANGES:
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
integer ExpectedItems = 0;
integer ReceivedItems = 0;
list ItemInventory = [];  // Track what we receive

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
    list acl_entries = [];
    integer i = 0;
    
    while (i < llGetListLength(all_keys)) {
        string ld_key = llList2String(all_keys, i);
        if (llSubStringIndex(ld_key, "acl_cache_") == 0) {
            string value = llLinksetDataRead(ld_key);
            acl_entries += [ld_key, value];
        }
        i += 1;
    }
    
    // Store ACL backup as JSON array
    if (llGetListLength(acl_entries) > 0) {
        string acl_json = llList2Json(JSON_ARRAY, acl_entries);
        llLinksetDataWrite("ACL.UPDATE", acl_json);
    }
}

/* -------------------- INVENTORY CLEARING -------------------- */

clear_inventory() {
    // Soft reset all scripts first
    string msg = llList2Json(JSON_OBJECT, ["type", "soft_reset_all"]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    
    llSleep(1.0);  // Give scripts time to reset
    
    // Remove all scripts except self and kmod_remote
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    integer removed = 0;
    
    while (i < count) {
        string script_name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (script_name != llGetScriptName() && script_name != "ds_collar_kmod_remote") {
            llRemoveInventory(script_name);
            removed += 1;
        }
        i += 1;
    }
    
    // Remove all animations
    count = llGetInventoryNumber(INVENTORY_ANIMATION);
    i = 0;
    while (i < count) {
        string anim_name = llGetInventoryName(INVENTORY_ANIMATION, i);
        llRemoveInventory(anim_name);
        removed += 1;
        i += 1;
    }
    
    // Remove all objects (except those we're about to receive)
    count = llGetInventoryNumber(INVENTORY_OBJECT);
    i = 0;
    while (i < count) {
        string obj_name = llGetInventoryName(INVENTORY_OBJECT, i);
        llRemoveInventory(obj_name);
        removed += 1;
        i += 1;
    }
    
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

handle_item_transfer(string message) {
    if (!json_has(message, ["name"])) return;
    
    string item_name = llJsonGetValue(message, ["name"]);
    
    // Wait for item to settle in inventory
    llSleep(0.5);
    
    // Track item (scripts or objects)
    integer item_type = llGetInventoryType(item_name);
    if (item_type != INVENTORY_SCRIPT && item_type != INVENTORY_OBJECT) {
        return;  // Unknown type
    }
    
    ItemInventory += [item_name];
    ReceivedItems += 1;
    
    // Acknowledge receipt
    string ack = llList2Json(JSON_OBJECT, [
        "type", "item_received",
        "name", item_name,
        "session", UpdateSession,
        "count", (string)ReceivedItems,
        "total", (string)ExpectedItems
    ]);
    llRegionSayTo(UpdaterKey, SecureChannel, ack);
    
    // Check if complete
    if (ReceivedItems >= ExpectedItems) {
        finalize_update();
    }
}

/* -------------------- ACTIVATOR SHIM TRIGGER -------------------- */

trigger_activator() {
    // Signal updater to inject activator shim as final step
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ready_for_activator",
        "session", UpdateSession
    ]);
    llRegionSayTo(UpdaterKey, SecureChannel, msg);
}

/* -------------------- UPDATE FINALIZATION -------------------- */

finalize_update() {
    llSetTimerEvent(0.0);  // Stop timer
    
    llOwnerSay("All items received. Preparing for activation...");
    
    // Signal updater to inject activator shim
    trigger_activator();
    
    llSleep(2.0);  // Brief wait for activator injection message to send
    
    // Clear script PIN
    llSetRemoteScriptAccessPin(0);
    
    // Self-destruct - activator shim will handle the rest
    llRemoveInventory(llGetScriptName());
}

/* -------------------- ABORT HANDLING -------------------- */

abort_update(string reason) {
    llSetTimerEvent(0.0);
    llSetRemoteScriptAccessPin(0);
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "update_aborted",
        "reason", reason,
        "session", UpdateSession
    ]);
    llRegionSayTo(UpdaterKey, SecureChannel, msg);
    
    // Self-destruct
    llRemoveInventory(llGetScriptName());
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Guard: Check if we're in an updater object (stay dormant if so)
        string object_name = llToLower(llGetObjectName());
        integer in_updater_object = (llSubStringIndex(object_name, "updater") != -1);
        integer has_updater_script = (llGetInventoryType("ds_collar_update") == INVENTORY_SCRIPT || llGetInventoryType("ds_collar_update_source") == INVENTORY_SCRIPT);
        
        if (in_updater_object || has_updater_script) {
            // We're in an updater object - stay dormant
            return;
        }
        
        // Get secure channel from start parameter (passed by llRemoteLoadScriptPin)
        SecureChannel = llGetStartParameter();
        
        // If not injected via PIN (SecureChannel == 0), remain dormant
        if (SecureChannel == 0) {
            return;  // Stay dormant
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
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            abort_update("Ownership changed during update");
        }
    }
}
