/*--------------------
SCRIPT: ds_collar_update.lsl
VERSION: 1.00
REVISION: 13
PURPOSE: Unified updater for D/s Collar
ARCHITECTURE: State-based (Idle -> Detecting -> Updating)
CHANGES:
- Rev 13: Refactored into LSL states for robustness
- Rev 12: Use llRemoteLoadScriptPin for all scripts to ensure they arrive RUNNING
- Rev 11: REMOVED Installer mode. This script is now UPDATER ONLY.
- Rev 10: Included ds_collar_kmod_remote in update manifest to ensure restoration
--------------------*/

/* -------------------- REMOTE PROTOCOL CHANNELS -------------------- */
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;  // Update discovery
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;  // Collar responses

/* -------------------- STATE -------------------- */
// Common state
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

float DETECTION_TIMEOUT = 5.0;
float TRANSFER_DELAY = 1.0;
float TRANSFER_TIMEOUT = 15.0;
integer RetryCount = 0;
integer MAX_RETRIES = 3;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return "update_" + (string)llGetUnixTime();
}

integer generate_secure_channel(string session) {
    // Hash session ID to generate deterministic secure channel
    string hash = llMD5String(session, 0);
    // Convert first 8 hex chars to negative integer
    integer chan = (integer)("0x" + llGetSubString(hash, 0, 7));
    // Ensure negative and in valid range
    if (chan > 0) chan = -chan;
    return chan;
}

/* -------------------- INVENTORY SCANNING -------------------- */

list scan_update_inventory() {
    list manifest = [];
    string script_name = llGetScriptName();
    
    // Scan all collar scripts (exclude updater/installer scripts and kmod_remote)
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        key uuid = llGetInventoryKey(name);
        
        // Skip: self, coordinator
        // Note: ds_collar_kmod_remote MUST be included so it is restored in the collar
        if (name != script_name && 
            name != "ds_collar_update_coordinator") {
            manifest += [name, (string)uuid];
        }
        i += 1;
    }
    
    // Scan animations
    count = llGetInventoryNumber(INVENTORY_ANIMATION);
    i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_ANIMATION, i);
        key uuid = llGetInventoryKey(name);
        manifest += [name, (string)uuid];
        i += 1;
    }
    
    // Scan objects
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

/* -------------------- LOGIC HELPERS -------------------- */

reset_state() {
    SessionId = "";
    CollarKey = NULL_KEY;
    Wearer = NULL_KEY;
    ScriptPin = 0;
    SecureChannel = 0;
    TransferIndex = 0;
    Manifest = [];
    RetryCount = 0;
    
    if (ListenHandle != 0) {
        llListenRemove(ListenHandle);
        ListenHandle = 0;
    }
    if (SecureListenHandle != 0) {
        llListenRemove(SecureListenHandle);
        SecureListenHandle = 0;
    }
}

abort_update() {
    llOwnerSay("Update aborted!");
    if (SecureChannel != 0 && CollarKey != NULL_KEY) {
        string abort_msg = llList2Json(JSON_OBJECT, [
            "type", "abort_update",
            "session", SessionId
        ]);
        llRegionSayTo(CollarKey, SecureChannel, abort_msg);
    }
}

transfer_current_item() {
    if (TransferIndex >= (llGetListLength(Manifest) / MANIFEST_STRIDE)) {
        return;  // No more items
    }
    
    string item_name = llList2String(Manifest, TransferIndex * MANIFEST_STRIDE);
    key item_uuid = (key)llList2String(Manifest, (TransferIndex * MANIFEST_STRIDE) + 1);
    
    if (RetryCount > 0) {
        llOwnerSay("Retrying transfer: " + item_name + " (" + (string)RetryCount + "/" + (string)MAX_RETRIES + ")");
    } else {
        llOwnerSay("Transferring: " + item_name);
    }
    
    // Notify coordinator item is coming
    string notify = llList2Json(JSON_OBJECT, [
        "type", "item_transfer",
        "session", SessionId,
        "name", item_name,
        "uuid", (string)item_uuid
    ]);
    llRegionSayTo(CollarKey, SecureChannel, notify);
    
    // Transfer item to ROOT PRIM of collar (CollarKey is already root)
    // Scripts: Use llRemoteLoadScriptPin to ensure they arrive RUNNING
    // Objects/Anims: Use llGiveInventory
    if (llGetInventoryType(item_name) == INVENTORY_SCRIPT) {
        // Inject script running=TRUE, start_param=0
        llRemoteLoadScriptPin(CollarKey, item_name, ScriptPin, TRUE, 0);
    }
    else {
        // Give object/animation
        llGiveInventory(CollarKey, item_name);
    }
    
    // Set watchdog timer for this item
    llSetTimerEvent(TRANSFER_TIMEOUT);
}

/* -------------------- STATES -------------------- */

default {
    state_entry() {
        reset_state();
        llOwnerSay("=== D/s Collar PIN-Based Updater ===");
        llOwnerSay("Touch to update your worn collar.");
    }
    
    touch_start(integer num) {
        key toucher = llDetectedKey(0);
        Wearer = toucher;
        
        llRegionSayTo(toucher, 0, "Initiating...");
        
        // Start detection
        SessionId = generate_session_id();
        string msg = llList2Json(JSON_OBJECT, [
            "type", "update_discover",
            "updater", (string)llGetKey(),
            "session", SessionId
        ]);
        llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);
        llOwnerSay("Detecting collar mode...");
        
        state detecting;
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
}

state detecting {
    state_entry() {
        ListenHandle = llListen(EXTERNAL_ACL_REPLY_CHAN, "", NULL_KEY, "");
        llSetTimerEvent(DETECTION_TIMEOUT);
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (!json_has(msg, ["type"])) return;
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type == "collar_ready") {
            if (!json_has(msg, ["session"])) return;
            if (llJsonGetValue(msg, ["session"]) != SessionId) return;
            
            // Found collar!
            key detected_collar = (key)llJsonGetValue(msg, ["collar"]);
            
            // Validate ownership/wearing
            list details = llGetObjectDetails(detected_collar, [OBJECT_ROOT]);
            if (llGetListLength(details) == 0) return;
            key root = llList2Key(details, 0);
            
            list collar_details = llGetObjectDetails(root, [OBJECT_ATTACHED_POINT, OBJECT_OWNER]);
            if (llGetListLength(collar_details) < 2) return;
            
            integer attach_point = llList2Integer(collar_details, 0);
            key collar_owner = llList2Key(collar_details, 1);
            
            if (attach_point > 0) {
                if (collar_owner != Wearer) {
                    llRegionSayTo(Wearer, 0, "Cannot update: collar not worn by you.");
                    state default;
                }
            } else {
                if (collar_owner != Wearer) {
                    llRegionSayTo(Wearer, 0, "Cannot update: collar not owned by you.");
                    state default;
                }
            }
            
            // Check kernel presence
            integer has_kernel = FALSE;
            if (json_has(msg, ["has_kernel"])) {
                has_kernel = (integer)llJsonGetValue(msg, ["has_kernel"]);
            }
            if (!has_kernel) {
                llRegionSayTo(Wearer, 0, "Collar is not in update mode (Kernel missing).");
                state default;
            }
            
            // Success - Prepare for update
            CollarKey = root;
            ScriptPin = (integer)llJsonGetValue(msg, ["pin"]);
            SecureChannel = generate_secure_channel(SessionId);
            
            llOwnerSay("Collar found! Starting update...");
            state updating;
        }
    }
    
    timer() {
        llOwnerSay("No collar detected (or kmod_remote missing).");
        llRegionSayTo(Wearer, 0, "Could not find a collar to update. Ensure you are wearing it and it has ds_collar_kmod_remote installed.");
        state default;
    }
    
    state_exit() {
        llSetTimerEvent(0.0);
        llListenRemove(ListenHandle);
        ListenHandle = 0;
    }
}

state updating {
    state_entry() {
        SecureListenHandle = llListen(SecureChannel, "", NULL_KEY, "");
        
        // Inject coordinator
        llOwnerSay("Injecting update coordinator...");
        if (llGetInventoryType("ds_collar_update_coordinator") != INVENTORY_SCRIPT) {
            llOwnerSay("ERROR: Coordinator script not found!");
            abort_update();
            state default;
        }
        
        llRemoteLoadScriptPin(CollarKey, "ds_collar_update_coordinator", ScriptPin, TRUE, SecureChannel);
        llSetTimerEvent(30.0); // Wait for coordinator
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (channel != SecureChannel) return;
        if (!json_has(msg, ["type"])) return;
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type == "coordinator_ready") {
            // Coordinator is ready
            if (llGetListLength(Manifest) == 0) {
                // First ready signal - send manifest
                Manifest = scan_update_inventory();
                TotalItems = llGetListLength(Manifest) / MANIFEST_STRIDE;
                
                if (TotalItems == 0) {
                    llOwnerSay("ERROR: No items to transfer!");
                    abort_update();
                    state default;
                }
                
                string manifest_msg = llList2Json(JSON_OBJECT, [
                    "type", "begin_update",
                    "updater", (string)llGetKey(),
                    "session", SessionId,
                    "total", TotalItems
                ]);
                llRegionSayTo(CollarKey, SecureChannel, manifest_msg);
                llSetTimerEvent(60.0); // Wait for next ready signal (allow time for inventory clear)
            }
            else {
                // Second ready signal - start transfer
                llOwnerSay("Coordinator ready. Starting transfers...");
                transfer_current_item();
            }
        }
        else if (msg_type == "item_received") {
            // Item confirmed
            integer received = (integer)llJsonGetValue(msg, ["count"]);
            integer total = (integer)llJsonGetValue(msg, ["total"]);
            
            llOwnerSay("Progress: " + (string)received + "/" + (string)total + " items");
            
            if (received == TransferIndex + 1) {
                TransferIndex += 1;
                RetryCount = 0;
                
                if (TransferIndex < total) {
                    llSleep(TRANSFER_DELAY);
                    transfer_current_item();
                } else {
                    llOwnerSay("=================================");
                    llOwnerSay("UPDATE COMPLETE!");
                    llOwnerSay("Coordinator will restore settings.");
                    llOwnerSay("=================================");
                    state default;
                }
            } else {
                llOwnerSay("WARNING: Item count mismatch.");
            }
        }
        else if (msg_type == "update_aborted") {
            llOwnerSay("Coordinator aborted update: " + llJsonGetValue(msg, ["reason"]));
            state default;
        }
    }
    
    timer() {
        // Watchdog / Retry logic
        if (llGetListLength(Manifest) > 0 && TransferIndex < TotalItems) {
            RetryCount += 1;
            if (RetryCount <= MAX_RETRIES) {
                transfer_current_item();
                return;
            } else {
                llOwnerSay("ERROR: Transfer failed after " + (string)MAX_RETRIES + " retries.");
                abort_update();
                state default;
            }
        }
        
        llOwnerSay("ERROR: Update timeout.");
        abort_update();
        state default;
    }
    
    state_exit() {
        llSetTimerEvent(0.0);
        llListenRemove(SecureListenHandle);
        SecureListenHandle = 0;
        reset_state();
    }
}
