/*--------------------
SCRIPT: ds_collar_activator_shim.lsl
VERSION: 1.00
REVISION: 2
PURPOSE: Script activation shim for hot-swap updates
USAGE: Transferred during update, activates new scripts and restores settings
ARCHITECTURE: Lightweight shim that runs after coordinator
CHANGES:
- Rev 2: Redesigned to activate all scripts and restore settings from linkset data
- Reads SETTINGS.UPDATE from linkset data
- Activates all scripts except self
- Broadcasts settings_sync to restore settings
- Self-destructs
--------------------*/

/* -------------------- CONSTANTS -------------------- */
integer SETTINGS_BUS = 800;

/* -------------------- ACTIVATION -------------------- */

start_activation() {
    llInstantMessage(llGetOwner(), "Activating collar scripts...");
    llSleep(1.0);
    
    // Activate all scripts except self
    string self_name = llGetScriptName();
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer activated = 0;
    integer i = 0;
    
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        
        if (name != self_name) {
            llSetScriptState(name, TRUE);
            activated += 1;
            llSleep(0.3);  // Small delay between activations
        }
        
        i += 1;
    }
    
    llInstantMessage(llGetOwner(), "Activated " + (string)activated + " scripts.");
    
    // Give scripts time to initialize
    llSleep(3.0);
    
    // Restore settings
    restore_settings();
    
    // Done
    llInstantMessage(llGetOwner(), "Update complete! Collar is ready.");
    llSleep(2.0);
    
    self_destruct();
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
        
        llInstantMessage(llGetOwner(), "Collar activation process underway...");
        // Give inventory time to settle
        llSleep(2.0);
        
        // Start activation
        start_activation();
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
