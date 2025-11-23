/*--------------------
SCRIPT: ds_collar_activator_shim.lsl
VERSION: 1.00
REVISION: 7
PURPOSE: Script activation shim for hot-swap updates
USAGE: Transferred during update, activates new scripts and restores settings
ARCHITECTURE: Lightweight shim that runs after coordinator
CHANGES:
- Rev 7: Added kernel verification (ping/pong) and wait for coordinator cleanup
- Rev 6: Improved dormancy check - look for coordinator or updater scripts (reliable, not object name)
- Rev 5: Wait for all expected items to arrive before activating (verify inventory count vs EXPECTED_ITEMS)
- Rev 4: Verify script exists before calling llSetScriptState to avoid "Could not find script" errors
- Rev 3: Updated guard to check for ds_collar_update instead of ds_collar_updater
- Rev 2: Redesigned to activate all scripts and restore settings from linkset data
- Reads SETTINGS.UPDATE from linkset data
- Activates all scripts except self
- Broadcasts settings_sync to restore settings
- Self-destructs
--------------------*/

/* -------------------- CONSTANTS -------------------- */
integer SETTINGS_BUS = 800;
integer KERNEL_LIFECYCLE = 500;

integer PingAttempts = 0;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* -------------------- ACTIVATION -------------------- */

wait_for_inventory() {
    // Read expected item count from linkset data
    string expected_str = llLinksetDataRead("EXPECTED_ITEMS");
    if (expected_str == "") {
        llInstantMessage(llGetOwner(), "WARNING: No expected item count found.");
        return;  // Proceed anyway
    }
    
    integer expected = (integer)expected_str;
    llInstantMessage(llGetOwner(), "Waiting for " + (string)expected + " items...");
    
    integer attempts = 0;
    integer max_attempts = 20;  // 20 attempts * 0.5s = 10 seconds max
    
    while (attempts < max_attempts) {
        integer script_count = llGetInventoryNumber(INVENTORY_SCRIPT);
        integer anim_count = llGetInventoryNumber(INVENTORY_ANIMATION);
        integer object_count = llGetInventoryNumber(INVENTORY_OBJECT);
        
        // Count excludes activator itself
        integer current = (script_count - 1) + anim_count + object_count;
        
        if (current >= expected) {
            llInstantMessage(llGetOwner(), "All items present. Starting activation...");
            return;  // All items present
        }
        
        llSleep(0.5);
        attempts += 1;
    }
    
    llInstantMessage(llGetOwner(), "WARNING: Timeout waiting for all items. Proceeding anyway...");
}

start_activation() {
    llInstantMessage(llGetOwner(), "Activating collar scripts...");
    
    // Wait for all items to arrive
    wait_for_inventory();
    
    llSleep(1.0);
    
    // Activate all scripts except self
    string self_name = llGetScriptName();
    integer activated = 0;
    integer i = 0;
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    
    while (i < count) {
        // Read name fresh each iteration (in case inventory changes)
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        
        // Skip if empty name or self
        if (name != "" && name != self_name) {
            // Verify script still exists before trying to set state
            if (llGetInventoryType(name) == INVENTORY_SCRIPT) {
                llSetScriptState(name, TRUE);
                activated += 1;
                llSleep(0.3);  // Small delay between activations
            }
        }
        
        i += 1;
    }
    
    llInstantMessage(llGetOwner(), "Activated " + (string)activated + " scripts.");
    
    // Give scripts time to initialize
    llSleep(3.0);
    
    // Restore settings
    restore_settings();
    
    // Verify kernel
    ping_kernel();
}

ping_kernel() {
    llInstantMessage(llGetOwner(), "Verifying kernel activation...");
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ping",
        "sender", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    
    llSetTimerEvent(5.0);
}

restore_settings() {
    llInstantMessage(llGetOwner(), "Restoring settings...");
    
    // Read settings from linkset data
    string kv_json = llLinksetDataRead("SETTINGS.UPDATE");
    
    if (kv_json == "" || kv_json == JSON_INVALID) {
        llInstantMessage(llGetOwner(), "WARNING: Could not restore settings backup.");
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
    llInstantMessage(llGetOwner(), "Restoring ACL cache...");
    
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
            
            llInstantMessage(llGetOwner(), "Restored " + (string)count + " ACL entries.");
        }
        
        // Clean up ACL backup
        llLinksetDataDelete("ACL.UPDATE");
    }
    
    llInstantMessage(llGetOwner(), "Settings restored.");
}

self_destruct() {
    llInstantMessage(llGetOwner(), "Cleaning up...");
    llRemoveInventory(llGetScriptName());
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Ensure no timers running
        llSetTimerEvent(0.0);
        
        // SAFETY: Only run if we were injected into a collar (not residing in updater)
        // We check for the presence of the main updater script ("ds_collar_update")
        // which ONLY exists in the updater object, never in the collar.
        
        if (llGetInventoryType("ds_collar_update") == INVENTORY_SCRIPT) {
            // Updater script present = we're in the updater object, stay dormant
            return;
        }
        
        // Wait for coordinator to self-destruct to ensure clean state
        // The coordinator triggers us then deletes itself. We must wait for that deletion.
        integer safety = 0;
        integer waiting = TRUE;
        
        while (waiting) {
            if (llGetInventoryType("ds_collar_update_coordinator") != INVENTORY_SCRIPT) {
                waiting = FALSE;
            }
            else {
                if (safety == 0) llInstantMessage(llGetOwner(), "Waiting for update coordinator to finish...");
                llSleep(1.0);
                safety++;
                
                if (safety > 20) {
                     llInstantMessage(llGetOwner(), "WARNING: Coordinator cleanup timed out. Proceeding...");
                     waiting = FALSE;
                }
            }
        }
        
        llInstantMessage(llGetOwner(), "Collar activation process underway...");
        // Give inventory time to settle
        llSleep(2.0);
        
        // Start activation
        start_activation();
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (num == KERNEL_LIFECYCLE) {
            if (json_has(msg, ["type"])) {
                string type = llJsonGetValue(msg, ["type"]);
                if (type == "pong") {
                    llSetTimerEvent(0.0);
                    llInstantMessage(llGetOwner(), "Kernel verified. Update complete!");
                    llSleep(1.0);
                    self_destruct();
                }
            }
        }
    }
    
    timer() {
        llSetTimerEvent(0.0);
        PingAttempts += 1;
        
        if (PingAttempts < 3) {
            llInstantMessage(llGetOwner(), "Kernel not responding, retrying activation...");
            
            // Try to activate kernel specifically if found
            if (llGetInventoryType("ds_collar_kernel") == INVENTORY_SCRIPT) {
                llSetScriptState("ds_collar_kernel", TRUE);
            }
            
            ping_kernel();
        }
        else {
            llInstantMessage(llGetOwner(), "WARNING: Kernel failed to respond after multiple attempts.");
            llInstantMessage(llGetOwner(), "Please manually check that 'ds_collar_kernel' is running.");
            self_destruct();
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
