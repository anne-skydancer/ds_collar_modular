/*--------------------
SCRIPT: ds_collar_update.lsl
VERSION: 1.00
REVISION: 10
PURPOSE: Unified installer and updater with automatic mode detection
ARCHITECTURE: Touch → query kmod_remote → auto-select Install or Update mode
CHANGES:
- Rev 10: Included ds_collar_kmod_remote in update manifest to ensure restoration
- Rev 10: Changed install mode to give "Collar Receiver" object instead of script
- Rev 10: Explicitly excluded ds_collar_receiver from update manifest
- Rev 9: Added installer timeout - fail gracefully if installer script doesn't respond
- Rev 8: Exclude ds_collar_kmod_remote from manifest (only needed for injection, not operation)
- Rev 7: Added animations to manifest, fixed llGiveInventory to use root prim (CollarKey)
- Rev 6: Auto-detect mode based on kmod_remote presence
  - Touch sends query to kmod_remote on EXTERNAL_ACL_QUERY_CHAN
  - Response received = Update mode (existing collar with kmod_remote)
  - No response (timeout) = Install mode (empty collar, no kmod_remote)
  - Installer path handled via link_message to ds_collar_installer.lsl
- Rev 5: Fixed root prim targeting, owner/wearer validation, duplicate response handling
- Rev 4: Added object transfer support (control HUD, leash holder)
- Rev 3: Updated for activator shim pattern
--------------------*/

/* -------------------- REMOTE PROTOCOL CHANNELS -------------------- */
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;  // Update discovery
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;  // Collar responses

/* -------------------- STATE -------------------- */
// Mode detection
integer DetectingMode = FALSE;  // TRUE while waiting for kmod_remote response

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

// Mode flags
integer Updating = FALSE;
integer Installing = FALSE;

float DETECTION_TIMEOUT = 5.0;
float TRANSFER_DELAY = 1.0;

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
        
        // Skip: self, installer, coordinator, activator shim, receiver
        // Note: ds_collar_kmod_remote MUST be included so it is restored in the collar
        if (name != script_name && 
            name != "ds_collar_installer" &&
            name != "ds_collar_update_coordinator" && 
            name != "ds_collar_activator_shim" &&
            name != "ds_collar_receiver") {
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
    
    // Scan objects - EXCLUDE "Collar Receiver" (updater object)
    count = llGetInventoryNumber(INVENTORY_OBJECT);
    i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_OBJECT, i);
        key uuid = llGetInventoryKey(name);
        
        // Only include collar objects, not updater objects
        if (name != "Collar Receiver") {
            manifest += [name, (string)uuid];
        }
        i += 1;
    }
    
    return manifest;
}

/* -------------------- MODE DETECTION -------------------- */

send_mode_detect_query() {
    SessionId = generate_session_id();
    DetectingMode = TRUE;
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "update_discover",
        "updater", (string)llGetKey(),
        "session", SessionId
    ]);
    
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);
    llOwnerSay("Detecting collar mode...");
    
    llSetTimerEvent(DETECTION_TIMEOUT);
}

/* -------------------- MESSAGE HANDLING -------------------- */

handle_collar_ready(string msg) {
    llOwnerSay("DEBUG: handle_collar_ready called");
    
    if (!json_has(msg, ["collar"])) {
        llOwnerSay("DEBUG: Missing collar field");
        return;
    }
    if (!json_has(msg, ["pin"])) {
        llOwnerSay("DEBUG: Missing pin field");
        return;
    }
    if (!json_has(msg, ["session"])) {
        llOwnerSay("DEBUG: Missing session field");
        return;
    }
    
    string msg_session = llJsonGetValue(msg, ["session"]);
    llOwnerSay("DEBUG: Message session: " + msg_session + ", Expected: " + SessionId);
    if (msg_session != SessionId) return;
    
    // CRITICAL: Set Updating flag EARLY so listen() will process subsequent messages
    if (DetectingMode) {
        DetectingMode = FALSE;
        llSetTimerEvent(0.0);
        llOwnerSay("Collar detected with kmod_remote - Update mode");
        Updating = TRUE;
    }
    
    // Guard: Only process first valid collar response
    if (CollarKey != NULL_KEY) {
        llOwnerSay("DEBUG: Already have CollarKey, ignoring duplicate");
        return;
    }
    
    llOwnerSay("DEBUG: Processing collar response");
    key detected_collar = (key)llJsonGetValue(msg, ["collar"]);
    
    // Validate it's the wearer's collar and get ROOT prim
    list details = llGetObjectDetails(detected_collar, [OBJECT_ROOT]);
    if (llGetListLength(details) == 0) {
        llOwnerSay("DEBUG: Failed to get object details");
        return;
    }
    
    key root = llList2Key(details, 0);
    llOwnerSay("DEBUG: Got root prim: " + (string)root);
    
    // CRITICAL: Verify collar is either worn by toucher OR owned by toucher
    list collar_details = llGetObjectDetails(root, [OBJECT_ATTACHED_POINT, OBJECT_OWNER]);
    if (llGetListLength(collar_details) < 2) return;
    
    integer attach_point = llList2Integer(collar_details, 0);
    key collar_owner = llList2Key(collar_details, 1);
    
    if (attach_point > 0) {
        // Worn: verify wearer is toucher
        if (collar_owner != Wearer) {
            llRegionSayTo(Wearer, 0, "Cannot update: collar not worn by you.");
            cleanup();
            return;
        }
    }
    else {
        // Rezzed: verify owner is toucher
        if (collar_owner != Wearer) {
            llRegionSayTo(Wearer, 0, "Cannot update: collar not owned by you.");
            cleanup();
            return;
        }
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
    
    // CRITICAL: Use ROOT prim key, not child prim
    CollarKey = root;
    ScriptPin = (integer)llJsonGetValue(msg, ["pin"]);
    
    llOwnerSay("Collar found and ready for update!");
    llSetTimerEvent(0.0);
    
    // Generate secure channel from session ID and set up listener
    SecureChannel = generate_secure_channel(SessionId);
    SecureListenHandle = llListen(SecureChannel, "", NULL_KEY, "");
    
    // Inject coordinator
    inject_coordinator();
}

/* -------------------- COORDINATOR INJECTION -------------------- */

inject_coordinator() {
    llOwnerSay("Injecting update coordinator...");
    
    // Verify coordinator exists
    if (llGetInventoryType("ds_collar_update_coordinator") != INVENTORY_SCRIPT) {
        llOwnerSay("ERROR: Coordinator script not found!");
        abort_update();
        return;
    }
    
    // Inject coordinator with PIN, running=TRUE, start_param=SecureChannel
    llRemoteLoadScriptPin(CollarKey, "ds_collar_update_coordinator", ScriptPin, TRUE, SecureChannel);
    
    llOwnerSay("Coordinator injected. Waiting for ready signal...");
    llSetTimerEvent(30.0);  // Timeout for coordinator to respond
}

/* -------------------- UPDATE FLOW -------------------- */

handle_coordinator_ready(string msg) {
    llOwnerSay("DEBUG: handle_coordinator_ready called");
    
    if (!json_has(msg, ["session"])) {
        llOwnerSay("DEBUG: coordinator_ready missing session");
        return;
    }
    
    string msg_session = llJsonGetValue(msg, ["session"]);
    llOwnerSay("DEBUG: Coordinator session: " + msg_session + ", Expected: " + SessionId);
    
    // First coordinator_ready has empty session (coordinator doesn't know it yet)
    // Subsequent coordinator_ready messages must match session
    if (msg_session != "" && msg_session != SessionId) {
        llOwnerSay("DEBUG: Session mismatch, ignoring");
        return;
    }
    
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
    
    // Transfer item to ROOT PRIM of collar (CollarKey is already root)
    // Scripts arrive INACTIVE, objects/anims arrive active
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
        
        if (Updating || Installing || DetectingMode) {
            llRegionSayTo(toucher, 0, "Operation already in progress!");
            return;
        }
        
        llRegionSayTo(toucher, 0, "Initiating...");
        
        send_mode_detect_query();
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        llOwnerSay("DEBUG: Received message type: " + msg_type + " on channel: " + (string)channel);
        
        if (channel == EXTERNAL_ACL_REPLY_CHAN) {
            // Collar ready with PIN - process during detection OR update mode
            if (msg_type == "collar_ready") {
                handle_collar_ready(msg);
            }
        }
        else if (channel == SecureChannel) {
            // Coordinator responses - only process during update mode
            if (!Updating) return;
            
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
        llSetTimerEvent(0.0);
        
        // Detection mode timeout = no kmod_remote response = Install mode
        if (DetectingMode) {
            DetectingMode = FALSE;
            llOwnerSay("No kmod_remote detected - Install mode");
            llOwnerSay("Activating installer...");
            
            // Give Collar Receiver object to user
            if (llGetInventoryType("Collar Receiver") == INVENTORY_OBJECT) {
                llGiveInventory(Wearer, "Collar Receiver");
                llRegionSayTo(Wearer, 0, "Collar Receiver object given. Please open it, extract the 'ds_collar_receiver' script, and drop it into the empty collar.");
            }
            else {
                llOwnerSay("ERROR: Collar Receiver object not found in inventory!");
                cleanup();
                return;
            }
            
            // Wake up installer script and let it proceed automatically
            Installing = TRUE;
            llMessageLinked(LINK_THIS, 1, "start_install", Wearer);
            
            // Set timeout for installer response (300 seconds / 5 minutes)
            // This covers user setup time + installation time
            llSetTimerEvent(300.0);
            return;
        }
        
        // Install mode timeout - installer didn't respond
        if (Installing) {
            llOwnerSay("ERROR: Installer timeout - process took too long.");
            llRegionSayTo(Wearer, 0, "Installation failed or timed out. Please try again.");
            cleanup();
            return;
        }
        
        // Update mode timeout
        if (Updating) {
            llOwnerSay("ERROR: Update timeout.");
            abort_update();
        }
    }
}
