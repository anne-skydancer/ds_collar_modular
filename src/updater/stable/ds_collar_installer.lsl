/*--------------------
SCRIPT: ds_collar_installer.lsl
VERSION: 1.00
REVISION: 3
PURPOSE: Fresh installation transmitter (dormant until activated)
USAGE: Stays dormant until ds_collar_update.lsl detects no kmod_remote and sends link_message
ARCHITECTURE: Activated by link_message("start_install") from updater script
CHANGES:
- Rev 3: Automatic installation flow - starts immediately when activated, no second touch needed
- Rev 2: Dormant mode - only activates when updater detects Install mode needed
- Initial version for fresh collar installations
- Broadcasts on installation channel -87654321
- Scans inventory and transfers all assets
- Handles chunked transfer with acknowledgments
--------------------*/

/* -------------------- INSTALLATION PROTOCOL -------------------- */
integer INSTALL_CHANNEL = -87654321;
float TIMEOUT_RESPONSE = 30.0;  // 30 seconds for receiver response
float TIMEOUT_ITEM = 15.0;      // 15 seconds per item transfer
float TRANSFER_DELAY = 2.0;     // 2 seconds between items

/* -------------------- STATE -------------------- */
integer Active = FALSE;  // TRUE when activated by updater
string SessionId = "";
key TargetKey = NULL_KEY;
key TargetOwner = NULL_KEY;
integer ListenHandle = 0;

list Manifest = [];  // [type, name, type, name, ...]
integer MANIFEST_STRIDE = 2;
integer TransferIndex = 0;
integer TotalItems = 0;

integer Installing = FALSE;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return "install_" + (string)llGetUnixTime();
}

/* -------------------- INVENTORY SCANNING -------------------- */

list scan_inventory() {
    list manifest = [];
    string script_name = llGetScriptName();
    
    // Scan scripts (exclude self)
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != script_name) {
            manifest += ["script", name];
        }
        i += 1;
    }
    
    // Scan animations
    count = llGetInventoryNumber(INVENTORY_ANIMATION);
    i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_ANIMATION, i);
        manifest += ["animation", name];
        i += 1;
    }
    
    // Scan objects
    count = llGetInventoryNumber(INVENTORY_OBJECT);
    i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_OBJECT, i);
        manifest += ["object", name];
        i += 1;
    }
    
    // Scan notecards
    count = llGetInventoryNumber(INVENTORY_NOTECARD);
    i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_NOTECARD, i);
        manifest += ["notecard", name];
        i += 1;
    }
    
    return manifest;
}

/* -------------------- MESSAGE SENDING -------------------- */

send_installer_hello() {
    SessionId = generate_session_id();
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "installer_hello",
        "session", SessionId,
        "donor", (string)llGetKey(),
        "version", "2.0"
    ]);
    
    llRegionSay(INSTALL_CHANNEL, msg);
    llOwnerSay("Broadcasting installation offer...");
    
    llSetTimerEvent(TIMEOUT_RESPONSE);
}

send_manifest() {
    string items_json = llList2Json(JSON_ARRAY, Manifest);
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "manifest",
        "session", SessionId,
        "items", items_json,
        "total", TotalItems
    ]);
    
    llRegionSay(INSTALL_CHANNEL, msg);
    llOwnerSay("Sending manifest: " + (string)TotalItems + " items");
}

send_transfer_item() {
    if (TransferIndex >= llGetListLength(Manifest)) {
        // All items sent
        send_install_complete();
        return;
    }
    
    string item_type = llList2String(Manifest, TransferIndex);
    string item_name = llList2String(Manifest, TransferIndex + 1);
    
    llOwnerSay("Transferring: " + item_name);
    
    // Send notification
    string msg = llList2Json(JSON_OBJECT, [
        "type", "transfer_item",
        "session", SessionId,
        "item_type", item_type,
        "item_name", item_name,
        "index", (TransferIndex / MANIFEST_STRIDE) + 1,
        "total", TotalItems
    ]);
    llRegionSay(INSTALL_CHANNEL, msg);
    
    // Give item to target
    llGiveInventory(TargetKey, item_name);
    
    // Set timeout for acknowledgment
    llSetTimerEvent(TIMEOUT_ITEM);
}

send_install_complete() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "install_complete",
        "session", SessionId,
        "total_transferred", TotalItems
    ]);
    
    llRegionSay(INSTALL_CHANNEL, msg);
    llOwnerSay("Installation complete! All " + (string)TotalItems + " items transferred.");
    
    // Reset state
    Installing = FALSE;
    TransferIndex = 0;
    TargetKey = NULL_KEY;
    llSetTimerEvent(0.0);
}

/* -------------------- MESSAGE HANDLING -------------------- */

handle_receiver_ready(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    if (!json_has(msg, ["object"])) return;
    if (!json_has(msg, ["owner"])) return;
    
    TargetKey = (key)llJsonGetValue(msg, ["object"]);
    TargetOwner = (key)llJsonGetValue(msg, ["owner"]);
    
    // Validate range
    list details = llGetObjectDetails(TargetKey, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        llOwnerSay("ERROR: Target collar not found");
        Installing = FALSE;
        return;
    }
    
    vector target_pos = llList2Vector(details, 0);
    float distance = llVecDist(llGetPos(), target_pos);
    
    if (distance > 10.0) {
        llOwnerSay("ERROR: Target too far away. Must be within 10m.");
        Installing = FALSE;
        return;
    }
    
    llOwnerSay("Receiver found: " + llKey2Name(TargetOwner));
    
    // Scan inventory and send manifest
    Manifest = scan_inventory();
    TotalItems = llGetListLength(Manifest) / MANIFEST_STRIDE;
    
    if (TotalItems == 0) {
        llOwnerSay("ERROR: No items to transfer!");
        Installing = FALSE;
        return;
    }
    
    send_manifest();
}

handle_manifest_ack(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    llOwnerSay("Manifest acknowledged. Starting transfer...");
    
    // Start transferring items
    TransferIndex = 0;
    llSleep(TRANSFER_DELAY);
    send_transfer_item();
}

handle_item_ack(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    if (!json_has(msg, ["received"])) return;
    integer success = (integer)llJsonGetValue(msg, ["received"]);
    
    if (success) {
        // Move to next item
        TransferIndex += MANIFEST_STRIDE;
        
        if (TransferIndex < llGetListLength(Manifest)) {
            llSleep(TRANSFER_DELAY);
            send_transfer_item();
        }
        else {
            // All items transferred
            send_install_complete();
        }
    }
    else {
        // Transfer failed - retry once
        llOwnerSay("WARNING: Transfer failed, retrying...");
        llSleep(TRANSFER_DELAY);
        send_transfer_item();
    }
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Stay dormant until activated by updater
        Active = FALSE;
        ListenHandle = llListen(INSTALL_CHANNEL, "", NULL_KEY, "");
    }
    
    link_message(integer sender, integer num, string str, key id) {
        // Activated by updater when Install mode detected
        if (str == "start_install") {
            Active = TRUE;
            key wearer = id;
            
            llOwnerSay("=== D/s Collar Fresh Installation Mode ===");
            llOwnerSay("Broadcasting installation offer...");
            
            // Immediately start installation flow
            if (Installing) {
                llOwnerSay("Installation already in progress!");
                return;
            }
            
            Installing = TRUE;
            send_installer_hello();
            llSetTimerEvent(TIMEOUT_RESPONSE);
        }
    }
    
    touch_start(integer num) {
        // Installation starts automatically - touch only shows status
        if (Active && Installing) {
            llRegionSayTo(llDetectedKey(0), 0, "Installation in progress...");
        }
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (!Active || !Installing) return;  // Only process during active installation
        if (channel != INSTALL_CHANNEL) return;
        if (!json_has(msg, ["type"])) return;
        if (!Installing) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type == "receiver_ready") {
            handle_receiver_ready(msg);
        }
        else if (msg_type == "manifest_ack") {
            handle_manifest_ack(msg);
        }
        else if (msg_type == "item_ack") {
            handle_item_ack(msg);
        }
        else if (msg_type == "installer_done") {
            llOwnerSay("Installation confirmed by receiver.");
            Installing = FALSE;
            TransferIndex = 0;
            TargetKey = NULL_KEY;
            llSetTimerEvent(0.0);
        }
    }
    
    timer() {
        llOwnerSay("ERROR: Installation timeout. No response from receiver.");
        Installing = FALSE;
        TransferIndex = 0;
        TargetKey = NULL_KEY;
        llSetTimerEvent(0.0);
    }
}
