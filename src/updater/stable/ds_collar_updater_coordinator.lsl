/*--------------------
SCRIPT: ds_collar_updater_coordinator.lsl
VERSION: 1.00
REVISION: 1
PURPOSE: Hot-swap coordinator for in-place collar updates
USAGE: Transferred to collar during update, performs atomic script replacement
ARCHITECTURE: System 2 coordinator - manages orderly shutdown and script replacement
CHANGES:
- Initial version for hot-swap coordination
- Backs up settings to linkset data
- Removes old scripts atomically
- Activates new scripts
- Restores settings
- Self-destructs after completion
--------------------*/

/* -------------------- CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

integer EXTERNAL_ACL_REPLY_CHAN = -8675310;  // Report status to updater

/* -------------------- STATE -------------------- */
string SessionId = "";
key UpdaterKey = NULL_KEY;

list OldScripts = [];
list NewScripts = [];
integer RemovalIndex = 0;

integer BackupComplete = FALSE;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    string val = llJsonGetValue(j, path);
    if (val == JSON_INVALID) return FALSE;
    return TRUE;
}

/* -------------------- COORDINATION PHASES -------------------- */

start_coordination(string session, key updater) {
    SessionId = session;
    UpdaterKey = updater;
    
    // Request settings backup
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get",
        "reply_to", "coordinator"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    
    llSetTimerEvent(30.0);  // Timeout for settings backup
}

backup_settings(string kv_json) {
    // Store in linkset data for recovery
    integer result = llLinksetDataWrite("backup_settings", kv_json);
    if (result < 0) {
        llOwnerSay("ERROR: Failed to backup settings!");
        // Continue anyway - prefer update over aborting
    }
    
    BackupComplete = TRUE;
    
    // Phase 2: Scan for old and new scripts
    scan_scripts();
}

scan_scripts() {
    OldScripts = [];
    NewScripts = [];
    
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    string self_name = llGetScriptName();
    
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        
        // Skip self
        if (name != self_name) {
            if (llSubStringIndex(name, ".new") != -1) {
                // New script
                NewScripts += [name];
            }
            else {
                // Old script (will be removed during update)
                OldScripts += [name];
            }
        }
        
        i += 1;
    }
    
    if (llGetListLength(NewScripts) == 0) {
        llOwnerSay("ERROR: No new scripts found!");
        abort_update();
        return;
    }
    
    // Phase 3: Soft reset all scripts
    soft_reset_all();
}

soft_reset_all() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "soft_reset"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    
    llSleep(2.0);  // Give scripts time to reset
    
    // Phase 4: Remove old scripts
    remove_old_scripts();
}

remove_old_scripts() {
    RemovalIndex = 0;
    remove_next_old_script();
}

remove_next_old_script() {
    if (RemovalIndex >= llGetListLength(OldScripts)) {
        // All old scripts removed
        activate_new_scripts();
        return;
    }
    
    string old_name = llList2String(OldScripts, RemovalIndex);
    
    // CRITICAL: Only remove scripts, never notecards
    // Notecards contain settings data that kernel reads
    // LSL cannot write notecards, so they must be preserved
    if (llGetInventoryType(old_name) == INVENTORY_SCRIPT) {
        llRemoveInventory(old_name);
    }
    
    RemovalIndex += 1;
    
    // Small delay to avoid inventory spam
    llSleep(0.5);
    remove_next_old_script();
}

activate_new_scripts() {
    integer i = 0;
    integer count = llGetListLength(NewScripts);
    
    while (i < count) {
        string new_name = llList2String(NewScripts, i);
        
        // Remove ".new" suffix
        string final_name = llGetSubString(new_name, 0, llStringLength(new_name) - 5);
        
        // Set script to running
        llSetScriptState(new_name, TRUE);
        
        llSleep(0.5);
        i += 1;
    }
    
    // Phase 6: Restore settings
    restore_settings();
}

restore_settings() {
    llSleep(2.0);  // Give scripts time to initialize
    
    // Read from linkset data
    string kv_json = llLinksetDataRead("backup_settings");
    
    if (kv_json == "" || kv_json == JSON_INVALID) {
        llOwnerSay("WARNING: Could not restore settings backup.");
        // Continue anyway
        finalize_update();
        return;
    }
    
    // Broadcast restored settings
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_sync",
        "kv", kv_json
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    
    llSleep(1.0);
    
    // Clean up linkset data
    llLinksetDataDelete("backup_settings");
    
    finalize_update();
}

finalize_update() {
    // Notify updater of completion
    string msg = llList2Json(JSON_OBJECT, [
        "type", "update_complete",
        "session", SessionId
    ]);
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, msg);
    
    llOwnerSay("=================================");
    llOwnerSay("HOT-SWAP UPDATE COMPLETE");
    llOwnerSay("All scripts updated");
    llOwnerSay("All settings restored");
    llOwnerSay("=================================");
    
    // Self-destruct after delay
    llSleep(5.0);
    llRemoveInventory(llGetScriptName());
}

abort_update() {
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
            // Custom messages (future use)
            if (msg_type == "start_coordination") {
                if (json_has(msg, ["session"]) && json_has(msg, ["updater"])) {
                    string session = llJsonGetValue(msg, ["session"]);
                    key updater = (key)llJsonGetValue(msg, ["updater"]);
                    start_coordination(session, updater);
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
            // Check if we should auto-start (all .new scripts present)
            if (SessionId == "" && !BackupComplete) {
                // Auto-start if we detect .new scripts
                integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
                integer has_new = FALSE;
                integer i = 0;
                
                while (i < count) {
                    string name = llGetInventoryName(INVENTORY_SCRIPT, i);
                    if (llSubStringIndex(name, ".new") != -1) {
                        has_new = TRUE;
                        i = count;  // Break
                    }
                    i += 1;
                }
                
                if (has_new) {
                    start_coordination("auto_" + (string)llGetUnixTime(), NULL_KEY);
                }
            }
        }
    }
}
