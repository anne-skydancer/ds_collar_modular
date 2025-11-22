/*--------------------
SCRIPT: ds_collar_update_source.lsl
VERSION: 1.00
REVISION: 3
PURPOSE: PIN-based update transmitter using llRemoteLoadScriptPin
ARCHITECTURE: Touch-activated, orchestrates complete update flow
CHANGES:
- Rev 3: Updated for activator shim pattern
- Coordinator injected first via PIN (arrives running)
- Collar scripts transferred via llGiveInventory (arrive inactive)
- Activator shim injected last via PIN (arrives running, activates scripts)
- Three-phase update: coordinator → collar scripts → activator shim
--------------------*/

/* -------------------- REMOTE PROTOCOL CHANNELS -------------------- */
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;  // Update discovery
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;  // Collar responses

/* -------------------- STATE -------------------- */
string SessionId = "";
key CollarKey = NULL_KEY;
key Wearer = NULL_KEY;
integer ListenHandle = 0;
integer SecureListenHandle = 0;
integer SecureChannel = 0;
integer ScriptPin = 0;

list Manifest = [];  // [name, uuid, name, uuid, ...]
integer MANIFEST_STRIDE = 2;
integer TransferIndex = 0;
integer TotalScripts = 0;

integer Updating = FALSE;

float DETECTION_TIMEOUT = 5.0;
float TRANSFER_DELAY = 1.0;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return "update_" + (string)llGetUnixTime();
}

integer generate_secure_channel() {
    return -2000000 - (integer)llFrand(1000000);
}

/* -------------------- INVENTORY SCANNING -------------------- */

list scan_update_inventory() {
    list manifest = [];
    string script_name = llGetScriptName();
    
    // Scan all collar scripts (exclude updater scripts)
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        key uuid = llGetInventoryKey(name);
        
        // Skip: self, coordinator, activator shim
        if (name != script_name && 
            name != "ds_collar_updater_coordinator" && 
            name != "ds_collar_activator_shim") {
            manifest += [name, (string)uuid];
        }
        i += 1;
    }
    
    return manifest;
}

/* -------------------- UPDATE DISCOVERY -------------------- */

send_update_discover() {
    SessionId = generate_session_id();
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "update_discover",
        "updater", (string)llGetKey(),
        "session", SessionId
    ]);
    
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);
    llOwnerSay("Discovering collar...");
    
    llSetTimerEvent(DETECTION_TIMEOUT);
}

/* -------------------- MESSAGE HANDLING -------------------- */

handle_collar_ready(string msg) {
    if (!json_has(msg, ["collar"])) return;
    if (!json_has(msg, ["pin"])) return;
    if (!json_has(msg, ["session"])) return;
    
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    key detected_collar = (key)llJsonGetValue(msg, ["collar"]);
    
    // Validate it's the wearer's collar
    list details = llGetObjectDetails(detected_collar, [OBJECT_ROOT]);
    if (llGetListLength(details) == 0) return;
    
    key root = llList2Key(details, 0);
    list avatar_details = llGetObjectDetails(root, [OBJECT_ATTACHED_POINT]);
    if (llGetListLength(avatar_details) == 0 || llList2Integer(avatar_details, 0) == 0) {
        return;  // Not an attachment
    }
    
    CollarKey = detected_collar;
    ScriptPin = (integer)llJsonGetValue(msg, ["pin"]);
    
    llOwnerSay("Collar found and ready!");
    llSetTimerEvent(0.0);
    
    // Generate secure channel and set up listener
    SecureChannel = generate_secure_channel();
    SecureListenHandle = llListen(SecureChannel, "", NULL_KEY, "");
    
    // Inject coordinator
    inject_coordinator();
}

/* -------------------- COORDINATOR INJECTION -------------------- */

inject_coordinator() {
    llOwnerSay("Injecting update coordinator...");
    
    // Verify coordinator exists
    if (llGetInventoryType("ds_collar_updater_coordinator") != INVENTORY_SCRIPT) {
        llOwnerSay("ERROR: Coordinator script not found!");
        abort_update();
        return;
    }
    
    // Inject coordinator with PIN, running=TRUE, start_param=SecureChannel
    llRemoteLoadScriptPin(CollarKey, "ds_collar_updater_coordinator", ScriptPin, TRUE, SecureChannel);
    
    llOwnerSay("Coordinator injected. Waiting for ready signal...");
    llSetTimerEvent(30.0);  // Timeout for coordinator to respond
}

/* -------------------- UPDATE FLOW -------------------- */

handle_coordinator_ready(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    llOwnerSay("Coordinator ready. Preparing manifest...");
    
    // Scan inventory
    Manifest = scan_update_inventory();
    TotalScripts = llGetListLength(Manifest) / MANIFEST_STRIDE;
    
    if (TotalScripts == 0) {
        llOwnerSay("ERROR: No scripts to transfer!");
        abort_update();
        return;
    }
    
    // Send manifest to coordinator
    string manifest_msg = llList2Json(JSON_OBJECT, [
        "type", "begin_update",
        "updater", (string)llGetKey(),
        "session", SessionId,
        "total", TotalScripts
    ]);
    llRegionSayTo(CollarKey, SecureChannel, manifest_msg);
    
    llOwnerSay("Starting transfer of " + (string)TotalScripts + " scripts...");
    llSetTimerEvent(0.0);
    
    // Wait for coordinator to clear inventory and signal ready
}

handle_script_received(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    if (!json_has(msg, ["count"])) return;
    if (!json_has(msg, ["total"])) return;
    
    integer received = (integer)llJsonGetValue(msg, ["count"]);
    integer total = (integer)llJsonGetValue(msg, ["total"]);
    
    llOwnerSay("Progress: " + (string)received + "/" + (string)total + " scripts");
    
    // Transfer next script
    if (received < total) {
        llSleep(TRANSFER_DELAY);
        transfer_next_script();
    }
    // Note: Don't mark complete here - wait for ready_for_activator signal
}

handle_ready_for_activator(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    llOwnerSay("All scripts transferred. Injecting activator...");
    
    // Verify activator shim exists
    if (llGetInventoryType("ds_collar_activator_shim") != INVENTORY_SCRIPT) {
        llOwnerSay("ERROR: Activator shim not found!");
        abort_update();
        return;
    }
    
    // Inject activator shim with PIN, running=TRUE
    llRemoteLoadScriptPin(CollarKey, "ds_collar_activator_shim", ScriptPin, TRUE, 0);
    
    llOwnerSay("=================================");
    llOwnerSay("UPDATE COMPLETE!");
    llOwnerSay("Activator will restore settings.");
    llOwnerSay("=================================");
    
    cleanup();
}

transfer_next_script() {
    if (TransferIndex >= (llGetListLength(Manifest) / MANIFEST_STRIDE)) {
        return;  // No more scripts
    }
    
    string script_name = llList2String(Manifest, TransferIndex * MANIFEST_STRIDE);
    key script_uuid = (key)llList2String(Manifest, (TransferIndex * MANIFEST_STRIDE) + 1);
    
    llOwnerSay("Transferring: " + script_name);
    
    // Notify coordinator script is coming
    string notify = llList2Json(JSON_OBJECT, [
        "type", "script_transfer",
        "session", SessionId,
        "name", script_name,
        "uuid", (string)script_uuid
    ]);
    llRegionSayTo(CollarKey, SecureChannel, notify);
    
    // Transfer script via llGiveInventory (arrives INACTIVE)
    llGiveInventory(CollarKey, script_name);
    
    TransferIndex += 1;
}

/* -------------------- ERROR HANDLING -------------------- */

abort_update() {
    llOwnerSay("Update aborted!");
    
    if (SecureChannel != 0) {
        string abort_msg = llList2Json(JSON_OBJECT, [
            "type", "abort_update",
            "session", SessionId
        ]);
        llRegionSayTo(CollarKey, SecureChannel, abort_msg);
    }
    
    cleanup();
}

cleanup() {
    llSetTimerEvent(0.0);
    
    if (ListenHandle != 0) {
        llListenRemove(ListenHandle);
        ListenHandle = 0;
    }
    
    if (SecureListenHandle != 0) {
        llListenRemove(SecureListenHandle);
        SecureListenHandle = 0;
    }
    
    Updating = FALSE;
    CollarKey = NULL_KEY;
    ScriptPin = 0;
    SecureChannel = 0;
    TransferIndex = 0;
    Manifest = [];
}


default {
    state_entry() {
        ListenHandle = llListen(EXTERNAL_ACL_REPLY_CHAN, "", NULL_KEY, "");
        
        llOwnerSay("=== D/s Collar PIN-Based Updater ===");
        llOwnerSay("Touch to update your worn collar.");
    }
    
    touch_start(integer num) {
        key toucher = llDetectedKey(0);
        Wearer = toucher;
        
        if (Updating) {
            llRegionSayTo(toucher, 0, "Update already in progress!");
            return;
        }
        
        Updating = TRUE;
        llRegionSayTo(toucher, 0, "Initiating collar update...");
        
        send_update_discover();
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (!json_has(msg, ["type"])) return;
        if (!Updating) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (channel == EXTERNAL_ACL_REPLY_CHAN) {
            // Collar ready with PIN
            if (msg_type == "collar_ready") {
                handle_collar_ready(msg);
            }
        }
        else if (channel == SecureChannel) {
            // Coordinator responses
            if (msg_type == "coordinator_ready") {
                handle_coordinator_ready(msg);
            }
            else if (msg_type == "script_received") {
                handle_script_received(msg);
            }
            else if (msg_type == "ready_for_activator") {
                handle_ready_for_activator(msg);
            }
            else if (msg_type == "update_aborted") {
                llOwnerSay("Coordinator aborted update: " + llJsonGetValue(msg, ["reason"]));
                cleanup();
            }
        }
    }
    
    timer() {
        llOwnerSay("ERROR: Update timeout.");
        abort_update();
    }
}
