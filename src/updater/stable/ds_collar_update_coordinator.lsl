/*--------------------
SCRIPT: ds_collar_update_coordinator.lsl
VERSION: 1.00
REVISION: 5
PURPOSE: Autonomous update coordinator injected via llRemoteLoadScriptPin
ARCHITECCTURE: Arrives RUNNING, orchestrates update, then triggers activator shim
CHANGES:
- Rev 4: Simplified flow - backs up settings, clears inventory, signals updater for activator shim injection
- Activator shim (injected last) handles script activation and settings restoration
- Coordinator self-destructs after triggering activator injection
- No script activation or settings restoration in coordinator
--------------------*/

/* -------------------- CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- STATE -------------------- */
integer SecureChannel = 0;
key UpdaterKey = NULL_KEY;
string UpdateSession = "";
integer ExpectedScripts = 0;
integer ReceivedScripts = 0;
list ScriptInventory = [];  // Track what we receive

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

/* -------------------- SCRIPT RECEPTION -------------------- */

handle_script_transfer(string message) {
    if (!json_has(message, ["name"])) return;
    
    string script_name = llJsonGetValue(message, ["name"]);
    
    // Wait for script to settle in inventory
    llSleep(0.5);
    
    if (llGetInventoryType(script_name) != INVENTORY_SCRIPT) {
        return;
    }
    
    ScriptInventory += [script_name];
    ReceivedScripts += 1;
    
    // Acknowledge receipt
    string ack = llList2Json(JSON_OBJECT, [
        "type", "script_received",
        "name", script_name,
        "session", UpdateSession,
        "count", (string)ReceivedScripts,
        "total", (string)ExpectedScripts
    ]);
    llRegionSayTo(UpdaterKey, SecureChannel, ack);
    
    // Check if complete
    if (ReceivedScripts >= ExpectedScripts) {
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
    
    llOwnerSay("All scripts received. Preparing for activation...");
    
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
        // Get secure channel from start parameter (passed by llRemoteLoadScriptPin)
        SecureChannel = llGetStartParameter();
        
        if (SecureChannel == 0) {
            llRemoveInventory(llGetScriptName());
            return;
        }
        
        // Listen on secure channel for updater instructions
        llListen(SecureChannel, "", NULL_KEY, "");
        
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
            ExpectedScripts = (integer)llJsonGetValue(message, ["total"]);
            
            // Begin update process
            backup_settings();
            clear_inventory();
            return;
        }
        
        // Script transfer notification
        if (msg_type == "script_transfer") {
            if (llJsonGetValue(message, ["session"]) != UpdateSession) return;
            handle_script_transfer(message);
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
