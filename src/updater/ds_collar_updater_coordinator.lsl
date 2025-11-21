/*--------------------
SCRIPT: ds_collar_updater_coordinator.lsl
VERSION: 1.00
REVISION: 2
PURPOSE: Hot-swap coordinator for in-place collar updates
USAGE: Transferred to collar during update, performs atomic script replacement
ARCHITECTURE: System 2 coordinator - manages orderly shutdown and script replacement
CHANGES:
- Rev 2: Redesigned update flow - remove all scripts/anims first, then receive new ones
- Saves settings to linkset data SETTINGS.UPDATE
- Clears inventory (except self and notecards)
- Signals updater when ready for new content
- Restores settings after update complete
--------------------*/

/* -------------------- CHANNELS -------------------- */
integer SETTINGS_BUS = 800;
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;  // Report status to updater

/* -------------------- STATE -------------------- */
string SessionId = "";
key UpdaterKey = NULL_KEY;

integer ExpectedScripts = 0;
integer ExpectedAnimations = 0;

integer BackupComplete = FALSE;
integer InventoryCleared = FALSE;
integer UpdateComplete = FALSE;

integer DEBUG = TRUE;

/* -------------------- HELPERS -------------------- */

integer logd(string s) {
    if (DEBUG) llOwnerSay("[COORDINATOR] " + s);
    return 0;
}

integer json_has(string j, list path) {
    string val = llJsonGetValue(j, path);
    if (val == JSON_INVALID) return FALSE;
    return TRUE;
}

/* -------------------- COORDINATION PHASES -------------------- */

start_coordination(string session, key updater, integer script_count, integer anim_count) {
    SessionId = session;
    UpdaterKey = updater;
    ExpectedScripts = script_count;
    ExpectedAnimations = anim_count;
    
    logd("Coordination started");
    logd("Expecting " + (string)script_count + " scripts, " + (string)anim_count + " animations");
    logd("Phase 1: Backing up settings...");
    
    // Request settings backup
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get",
        "reply_to", "coordinator"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    
    llSetTimerEvent(30.0);  // Timeout for settings backup
}

backup_settings(string kv_json) {
    logd("Settings backed up to linkset data");
    
    // Store settings in linkset data with special key
    integer result = llLinksetDataWrite("SETTINGS.UPDATE", kv_json);
    if (result < 0) {
        llOwnerSay("ERROR: Failed to backup settings!");
        abort_update();
        return;
    }
    
    // CRITICAL: Also backup all ACL cache entries from linkset data
    // ACL cache is stored as acl_cache_<uuid> keys
    logd("Backing up ACL cache...");
    
    list acl_keys = [];
    list acl_values = [];
    
    // Iterate through linkset data to find all acl_cache_* entries
    list keys = llLinksetDataListKeys(0, 999);  // Get all keys
    integer i = 0;
    integer count = llGetListLength(keys);
    
    while (i < count) {
        string k = llList2String(keys, i);
        if (llSubStringIndex(k, "acl_cache_") == 0) {
            string v = llLinksetDataRead(k);
            acl_keys += [k];
            acl_values += [v];
        }
        i += 1;
    }
    
    logd("Found " + (string)llGetListLength(acl_keys) + " ACL cache entries");
    
    // Store ACL backup as JSON
    if (llGetListLength(acl_keys) > 0) {
        string acl_backup = llList2Json(JSON_OBJECT, [
            "keys", llList2Json(JSON_ARRAY, acl_keys),
            "values", llList2Json(JSON_ARRAY, acl_values)
        ]);
        
        result = llLinksetDataWrite("ACL.UPDATE", acl_backup);
        if (result < 0) {
            llOwnerSay("WARNING: Failed to backup ACL cache!");
        }
    }
    
    BackupComplete = TRUE;
    
    // Stop timeout timer
    llSetTimerEvent(0.0);
    
    // Phase 2: Clear inventory
    clear_inventory();
}

clear_inventory() {
    logd("Phase 2: Clearing old inventory...");
    
    string self_name = llGetScriptName();
    
    // Soft reset all scripts first
    logd("Soft resetting all scripts...");
    string msg = llList2Json(JSON_OBJECT, [
        "type", "soft_reset_all"
    ]);
    llMessageLinked(LINK_SET, 500, msg, NULL_KEY);  // KERNEL_LIFECYCLE
    
    llSleep(2.0);
    
    // Remove all scripts except self
    logd("Removing old scripts...");
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = count - 1;  // Start from end
    while (i >= 0) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != self_name) {
            llRemoveInventory(name);
            llSleep(0.2);
        }
        i -= 1;
    }
    
    // Remove all animations
    logd("Removing old animations...");
    count = llGetInventoryNumber(INVENTORY_ANIMATION);
    i = count - 1;
    while (i >= 0) {
        string name = llGetInventoryName(INVENTORY_ANIMATION, i);
        llRemoveInventory(name);
        llSleep(0.2);
        i -= 1;
    }
    
    // CRITICAL: Verify notecards were NOT removed
    integer notecard_count = llGetInventoryNumber(INVENTORY_NOTECARD);
    if (notecard_count > 0) {
        logd("Preserved " + (string)notecard_count + " notecards (settings data)");
    }
    
    InventoryCleared = TRUE;
    
    // Phase 3: Signal updater we're ready for new content
    signal_ready_for_content();
}

signal_ready_for_content() {
    logd("Phase 3: Ready for new content transfer");
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "inventory_cleared",
        "session", SessionId
    ]);
    
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, msg);
    llOwnerSay("Old inventory cleared. Ready for update files...");
}

check_update_complete() {
    // Check if we have all expected content
    integer script_count = llGetInventoryNumber(INVENTORY_SCRIPT) - 1;  // Exclude self
    integer anim_count = llGetInventoryNumber(INVENTORY_ANIMATION);
    
    logd("Current inventory: " + (string)script_count + " scripts, " + (string)anim_count + " animations");
    
    if (script_count >= ExpectedScripts && anim_count >= ExpectedAnimations) {
        UpdateComplete = TRUE;
        finalize_update();
    }
}

finalize_update() {
    logd("Phase 4: Finalizing update...");
    
    // Stop any timers
    llSetTimerEvent(0.0);
    
    llOwnerSay("All update files received. Restoring settings...");
    
    // Read settings from linkset data
    string kv_json = llLinksetDataRead("SETTINGS.UPDATE");
    
    if (kv_json == "" || kv_json == JSON_INVALID) {
        llOwnerSay("WARNING: Could not restore settings backup.");
    }
    else {
        // Wait for activator to start scripts
        logd("Settings ready for restore after activation");
    }
    
    // Transfer control to activator shim
    if (llGetInventoryType("ds_collar_activator_shim") == INVENTORY_SCRIPT) {
        logd("Starting activator shim...");
        llSetScriptState("ds_collar_activator_shim", TRUE);
        
        // Wait a moment for activator to start
        llSleep(2.0);
        
        // Self-destruct
        logd("Coordinator self-destructing...");
        llRemoveInventory(llGetScriptName());
    }
    else {
        llOwnerSay("ERROR: Activator shim not found! Manual script activation required.");
        llSleep(2.0);
        llRemoveInventory(llGetScriptName());
    }
}

abort_update() {
    llSetTimerEvent(0.0);
    llOwnerSay("UPDATE ABORTED - See coordinator log");
    
    // Notify updater
    string msg = llList2Json(JSON_OBJECT, [
        "type", "update_failed",
        "session", SessionId,
        "reason", "Coordinator detected error"
    ]);
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, msg);
    
    // Self-destruct
    llSleep(2.0);
    llRemoveInventory(llGetScriptName());
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        logd("Coordinator loaded and standing by...");
        llSetTimerEvent(120.0);  // Overall timeout
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!json_has(msg, ["type"])) return;
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (num == SETTINGS_BUS) {
            // Settings response
            if (msg_type == "settings_sync") {
                if (!BackupComplete) {
                    if (json_has(msg, ["kv"])) {
                        string kv_json = llJsonGetValue(msg, ["kv"]);
                        backup_settings(kv_json);
                    }
                }
            }
        }
        else if (num == 0) {
            // Custom messages
            if (msg_type == "start_coordination") {
                if (json_has(msg, ["session"]) && json_has(msg, ["updater"]) && 
                    json_has(msg, ["scripts"]) && json_has(msg, ["animations"])) {
                    string session = llJsonGetValue(msg, ["session"]);
                    key updater = (key)llJsonGetValue(msg, ["updater"]);
                    integer scripts = (integer)llJsonGetValue(msg, ["scripts"]);
                    integer animations = (integer)llJsonGetValue(msg, ["animations"]);
                    start_coordination(session, updater, scripts, animations);
                }
            }
        }
    }
    
    timer() {
        if (!BackupComplete) {
            llOwnerSay("ERROR: Coordination timeout");
            abort_update();
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_INVENTORY) {
            if (InventoryCleared && !UpdateComplete) {
                // Check if update files arriving
                check_update_complete();
            }
        }
    }
}
