/*--------------------
SCRIPT: ds_collar_updater.lsl
VERSION: 1.00
REVISION: 4
PURPOSE: PIN-based update transmitter using llRemoteLoadScriptPin
ARCHITECTURE: Touch-activated, orchestrates complete update flow
CHANGES:
- Rev 4: Added object transfer support (control HUD, leash holder)
- Rev 3: Updated for activator shim pattern
- Coordinator injected first via PIN (arrives running)
- Collar scripts and objects transferred via llGiveInventory (scripts arrive inactive)
- Activator shim injected last via PIN (arrives running, activates scripts)
- Three-phase update: coordinator → collar items (scripts + objects) → activator shim
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
integer TotalItems = 0;

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
    
    // Scan objects (control HUD, leash holder)
    count = llGetInventoryNumber(INVENTORY_OBJECT);
    i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_OBJECT, i);
        key uuid = llGetInventoryKey(name);
        manifest += [name, (string)uuid];
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
    
    // CRITICAL: Verify this is an UPDATE scenario, not INSTALL
    // Update requires: ds_collar_kernel present AND ds_collar_receiver NOT present
    integer has_kernel = FALSE;
    integer has_receiver = FALSE;
    
    if (json_has(msg, ["has_kernel"])) {
        has_kernel = (integer)llJsonGetValue(msg, ["has_kernel"]);
    }
    if (json_has(msg, ["has_receiver"])) {
        has_receiver = (integer)llJsonGetValue(msg, ["has_receiver"]);
    }
    
    if (!has_kernel || has_receiver) {
        // Not an update scenario - either fresh install or invalid state
        llRegionSayTo(Wearer, 0, "Collar is not in update mode. Use installer for fresh installs.");
        cleanup();
        return;
    }
    
    CollarKey = detected_collar;
    ScriptPin = (integer)llJsonGetValue(msg, ["pin"]);
    
    llOwnerSay("Collar found and ready for update!");
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
    
    // First coordinator_ready: send manifest
    if (llGetListLength(Manifest) == 0) {
        llOwnerSay("Coordinator ready. Preparing manifest...");
        
        // Scan inventory
        Manifest = scan_update_inventory();
        TotalItems = llGetListLength(Manifest) / MANIFEST_STRIDE;
        
        if (TotalItems == 0) {
            llOwnerSay("ERROR: No items to transfer!");
            abort_update();
            return;
        }
        
        // Send manifest to coordinator
        string manifest_msg = llList2Json(JSON_OBJECT, [
            "type", "begin_update",
            "updater", (string)llGetKey(),
            "session", SessionId,
            "total", TotalItems
        ]);
        llRegionSayTo(CollarKey, SecureChannel, manifest_msg);
        
        llOwnerSay("Starting transfer of " + (string)TotalItems + " items...");
        llSetTimerEvent(0.0);
        
        // Wait for coordinator to clear inventory and signal ready again
    }
    // Second coordinator_ready: start transfers
    else {
        llOwnerSay("Coordinator ready for content. Starting transfers...");
        transfer_next_item();
    }
}

handle_item_received(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    if (!json_has(msg, ["count"])) return;
    if (!json_has(msg, ["total"])) return;
    
    integer received = (integer)llJsonGetValue(msg, ["count"]);
    integer total = (integer)llJsonGetValue(msg, ["total"]);
    
    llOwnerSay("Progress: " + (string)received + "/" + (string)total + " items");
    
    // Transfer next item
    if (received < total) {
        llSleep(TRANSFER_DELAY);
        transfer_next_item();
    }
    // Note: Don't mark complete here - wait for ready_for_activator signal
}

handle_ready_for_activator(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    llOwnerSay("All items transferred. Injecting activator...");
    
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

transfer_next_item() {
    if (TransferIndex >= (llGetListLength(Manifest) / MANIFEST_STRIDE)) {
        return;  // No more items
    }
    
    string item_name = llList2String(Manifest, TransferIndex * MANIFEST_STRIDE);
    key item_uuid = (key)llList2String(Manifest, (TransferIndex * MANIFEST_STRIDE) + 1);
    
    llOwnerSay("Transferring: " + item_name);
    
    // Notify coordinator item is coming
    string notify = llList2Json(JSON_OBJECT, [
        "type", "item_transfer",
        "session", SessionId,
        "name", item_name,
        "uuid", (string)item_uuid
    ]);
    llRegionSayTo(CollarKey, SecureChannel, notify);
    
    // Transfer item via llGiveInventory (scripts arrive INACTIVE, objects arrive active)
    llGiveInventory(CollarKey, item_name);
    
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
            else if (msg_type == "item_received") {
                handle_item_received(msg);
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
