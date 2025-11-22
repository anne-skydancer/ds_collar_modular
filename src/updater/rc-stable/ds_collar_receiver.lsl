/*--------------------
SCRIPT: ds_collar_receiver.lsl
VERSION: 1.00
REVISION: 1
PURPOSE: Fresh installation receiver for unworn/unlocked collars
USAGE: Drop this script into an empty collar, installer will transfer all assets
ARCHITECTURE: Standalone receiver for System 1 (Fresh Install)
CHANGES:
- Initial version for fresh collar installations
- Listens on installation channel -87654321
- Tracks inventory changes and acknowledges transfers
- Self-destructs after successful installation
--------------------*/

/* -------------------- INSTALLATION PROTOCOL -------------------- */
integer INSTALL_CHANNEL = -87654321;
float TIMEOUT_INSTALL = 300.0;  // 5 minutes total timeout
float TIMEOUT_ITEM = 30.0;      // 30 seconds per item timeout

/* -------------------- STATE -------------------- */
string SessionId = "";
key DonorKey = NULL_KEY;
integer ListenHandle = 0;

list ExpectedManifest = [];  // [type, name, type, name, ...]
integer MANIFEST_STRIDE = 2;
integer TotalItems = 0;
integer ReceivedCount = 0;

string ExpectingItem = "";
integer ExpectingType = INVENTORY_NONE;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return "receiver_" + (string)llGetUnixTime();
}

integer inventory_type_from_string(string type_str) {
    if (type_str == "script") return INVENTORY_SCRIPT;
    if (type_str == "animation") return INVENTORY_ANIMATION;
    if (type_str == "object") return INVENTORY_OBJECT;
    if (type_str == "notecard") return INVENTORY_NOTECARD;
    if (type_str == "texture") return INVENTORY_TEXTURE;
    if (type_str == "sound") return INVENTORY_SOUND;
    return INVENTORY_NONE;
}

/* -------------------- MESSAGE SENDING -------------------- */

send_receiver_ready() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "receiver_ready",
        "session", SessionId,
        "object", (string)llGetKey(),
        "owner", (string)llGetOwner(),
        "mode", "fresh"
    ]);
    llRegionSay(INSTALL_CHANNEL, msg);
    llOwnerSay("Installation receiver ready. Waiting for installer...");
}

send_manifest_ack() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "manifest_ack",
        "session", SessionId,
        "total_items", TotalItems
    ]);
    llRegionSay(INSTALL_CHANNEL, msg);
    llOwnerSay("Manifest received: " + (string)TotalItems + " items expected");
}

send_item_ack(string item_name, integer success) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "item_ack",
        "session", SessionId,
        "item_name", item_name,
        "received", success
    ]);
    llRegionSay(INSTALL_CHANNEL, msg);
    
    if (success) {
        ReceivedCount += 1;
        llOwnerSay("Received " + (string)ReceivedCount + "/" + (string)TotalItems + ": " + item_name);
    }
}

send_installer_done() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "installer_done",
        "session", SessionId,
        "object", (string)llGetKey()
    ]);
    llRegionSay(INSTALL_CHANNEL, msg);
}

/* -------------------- MESSAGE HANDLING -------------------- */

handle_installer_hello(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (!json_has(msg, ["donor"])) return;
    
    SessionId = llJsonGetValue(msg, ["session"]);
    DonorKey = (key)llJsonGetValue(msg, ["donor"]);
    
    // Validate range
    list details = llGetObjectDetails(DonorKey, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        llOwnerSay("ERROR: Installer not found");
        return;
    }
    
    vector donor_pos = llList2Vector(details, 0);
    float distance = llVecDist(llGetPos(), donor_pos);
    
    if (distance > 10.0) {
        llOwnerSay("ERROR: Installer too far away (" + (string)((integer)distance) + "m). Must be within 10m.");
        return;
    }
    
    send_receiver_ready();
    llSetTimerEvent(TIMEOUT_INSTALL);
}

handle_manifest(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    if (!json_has(msg, ["items"])) return;
    
    string items_json = llJsonGetValue(msg, ["items"]);
    ExpectedManifest = llJson2List(items_json);
    TotalItems = llGetListLength(ExpectedManifest) / MANIFEST_STRIDE;
    
    send_manifest_ack();
}

handle_transfer_item(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    if (!json_has(msg, ["item_type"])) return;
    if (!json_has(msg, ["item_name"])) return;
    
    string item_type = llJsonGetValue(msg, ["item_type"]);
    string item_name = llJsonGetValue(msg, ["item_name"]);
    
    ExpectingItem = item_name;
    ExpectingType = inventory_type_from_string(item_type);
    
    // Reset per-item timeout
    llSetTimerEvent(TIMEOUT_ITEM);
}

handle_install_complete(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    llOwnerSay("Installation complete! " + (string)ReceivedCount + "/" + (string)TotalItems + " items received");
    llOwnerSay("Resetting collar scripts...");
    
    send_installer_done();
    
    // Wait a moment for message to send
    llSleep(1.0);
    
    // Remove this receiver script
    llRemoveInventory(llGetScriptName());
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        SessionId = generate_session_id();
        ListenHandle = llListen(INSTALL_CHANNEL, "", NULL_KEY, "");
        
        llOwnerSay("=== D/s Collar Installer ===");
        llOwnerSay("Ready to receive scripts.");
        llOwnerSay("Touch the installer prim to continue.");
        
        // No timeout yet - wait for installer hello
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (channel != INSTALL_CHANNEL) return;
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type == "installer_hello") {
            handle_installer_hello(msg);
        }
        else if (msg_type == "manifest") {
            handle_manifest(msg);
        }
        else if (msg_type == "transfer_item") {
            handle_transfer_item(msg);
        }
        else if (msg_type == "install_complete") {
            handle_install_complete(msg);
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_INVENTORY) {
            // Check if expected item arrived
            if (ExpectingItem != "" && ExpectingType != INVENTORY_NONE) {
                integer inv_type = llGetInventoryType(ExpectingItem);
                
                if (inv_type == ExpectingType) {
                    // Item received successfully
                    send_item_ack(ExpectingItem, TRUE);
                    ExpectingItem = "";
                    ExpectingType = INVENTORY_NONE;
                    
                    // Reset timeout for next item
                    llSetTimerEvent(TIMEOUT_INSTALL);
                    
                    // Check if complete
                    if (ReceivedCount >= TotalItems) {
                        llOwnerSay("All items received!");
                    }
                }
            }
        }
    }
    
    timer() {
        if (ExpectingItem != "") {
            // Item timeout
            llOwnerSay("ERROR: Timeout waiting for item: " + ExpectingItem);
            send_item_ack(ExpectingItem, FALSE);
            ExpectingItem = "";
            ExpectingType = INVENTORY_NONE;
        }
        else {
            // Overall timeout
            llOwnerSay("ERROR: Installation timeout. Receiver still active for retry.");
        }
        
        llSetTimerEvent(0.0);
    }
}
