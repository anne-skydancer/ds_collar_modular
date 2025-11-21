/*--------------------
SCRIPT: ds_collar_updater_source.lsl
VERSION: 1.00
REVISION: 1
PURPOSE: In-place update transmitter using existing remote listener
USAGE: Drop in updater object, wearer touches to initiate update
ARCHITECTURE: Touch-based updater for System 2 (In-Place Update)
CHANGES:
- Initial version for in-place collar updates
- Uses existing remote channels (-8675309, -8675310, -8675311)
- Touch-based initiation (owner validation)
- Transfers scripts with ".new" suffix for hot-swap
--------------------*/

/* -------------------- REMOTE PROTOCOL CHANNELS -------------------- */
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;  // Update discovery
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;  // Collar responses
integer EXTERNAL_MENU_CHAN      = -8675311;  // Update commands

float MAX_DETECTION_RANGE = 20.0;

/* -------------------- STATE -------------------- */
string SessionId = "";
key CollarKey = NULL_KEY;
key CollarOwner = NULL_KEY;
key Wearer = NULL_KEY;
integer ListenHandle = 0;
integer DialogListenHandle = 0;
integer DialogChannel = 0;

list Manifest = [];  // [name, name, ...]
integer TransferIndex = 0;
integer TotalItems = 0;

integer Updating = FALSE;
string CurrentVersion = "2.0";

// Multiple collar detection
list DetectedCollars = [];  // [key, version, key, version, ...]
integer COLLAR_STRIDE = 2;
float DETECTION_TIMEOUT = 5.0;  // Wait 5s for all collars to respond

float TRANSFER_DELAY = 2.5;  // 2.5 seconds between items
float TIMEOUT_ITEM = 20.0;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return "update_" + (string)llGetUnixTime();
}

integer generate_dialog_channel() {
    return -1000000 - (integer)llFrand(1000000);
}

/* -------------------- INVENTORY SCANNING -------------------- */

list scan_update_inventory() {
    list manifest = [];
    string script_name = llGetScriptName();
    
    // Scan scripts (exclude self and coordinator for now)
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        // Skip self and coordinator (coordinator transferred last)
        if (name != script_name && name != "ds_collar_updater_coordinator") {
            manifest += [name];
        }
        i += 1;
    }
    
    // TODO: Add animations, objects, notecards if needed for updates
    
    return manifest;
}

/* -------------------- MESSAGE SENDING -------------------- */

send_update_discover() {
    SessionId = generate_session_id();
    DetectedCollars = [];  // Clear previous detection
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "update_discover",
        "version", CurrentVersion,
        "updater", (string)llGetKey(),
        "session", SessionId
    ]);
    
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);
    llOwnerSay("Discovering nearby D/s Collars...");
    
    llSetTimerEvent(DETECTION_TIMEOUT);  // Wait for all collars to respond
}

send_prepare_update() {
    string manifest_json = llList2Json(JSON_ARRAY, Manifest);
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "prepare_update",
        "updater", (string)llGetKey(),
        "session", SessionId,
        "manifest", manifest_json,
        "total", TotalItems
    ]);
    
    llRegionSay(EXTERNAL_MENU_CHAN, msg);
    llOwnerSay("Collar found. Preparing for update...");
}

send_transfer_script() {
    if (TransferIndex >= llGetListLength(Manifest)) {
        // All scripts sent, now send coordinator
        send_coordinator();
        return;
    }
    
    string script_name = llList2String(Manifest, TransferIndex);
    string new_name = script_name + ".new";
    
    llOwnerSay("Transferring: " + script_name + " -> " + new_name);
    
    // Notify collar
    string msg = llList2Json(JSON_OBJECT, [
        "type", "transfer_script",
        "session", SessionId,
        "script_name", script_name,
        "new_name", new_name,
        "index", TransferIndex + 1,
        "total", TotalItems
    ]);
    llRegionSay(EXTERNAL_MENU_CHAN, msg);
    
    // Give inventory item to collar wearer (it will appear in collar inventory)
    llGiveInventory(CollarKey, script_name);
    
    llSetTimerEvent(TIMEOUT_ITEM);
}

send_coordinator() {
    llOwnerSay("Transferring update coordinator...");
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "transfer_coordinator",
        "session", SessionId
    ]);
    llRegionSay(EXTERNAL_MENU_CHAN, msg);
    
    // Check if coordinator exists
    if (llGetInventoryType("ds_collar_updater_coordinator") == INVENTORY_SCRIPT) {
        llGiveInventory(CollarKey, "ds_collar_updater_coordinator");
        llOwnerSay("Coordinator sent. Hot-swap will begin automatically.");
    }
    else {
        llOwnerSay("WARNING: Coordinator script not found. Manual update required.");
    }
    
    llSetTimerEvent(60.0);  // Give coordinator time to work
}

/* -------------------- MESSAGE HANDLING -------------------- */

handle_collar_present(string msg) {
    if (!json_has(msg, ["type"])) return;
    if (llJsonGetValue(msg, ["type"]) != "collar_present") return;
    
    if (!json_has(msg, ["collar"])) return;
    if (!json_has(msg, ["owner"])) return;
    if (!json_has(msg, ["wearer"])) return;
    
    key detected_collar = (key)llJsonGetValue(msg, ["collar"]);
    key collar_owner = (key)llJsonGetValue(msg, ["owner"]);
    key collar_wearer = (key)llJsonGetValue(msg, ["wearer"]);
    
    // Security: Validate wearer matches toucher
    if (collar_wearer != Wearer) {
        return;  // Silently ignore other people's collars
    }
    
    // Validate owner matches wearer (only owner can update their own collar)
    if (collar_owner != Wearer) {
        return;  // Silently ignore collars where wearer is not owner
    }
    
    // Check range
    list details = llGetObjectDetails(detected_collar, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        return;  // Collar not found
    }
    
    vector collar_pos = llList2Vector(details, 0);
    float distance = llVecDist(llGetPos(), collar_pos);
    
    if (distance > MAX_DETECTION_RANGE) {
        return;  // Out of range, silently ignore
    }
    
    string current_version = "unknown";
    if (json_has(msg, ["current_version"])) {
        current_version = llJsonGetValue(msg, ["current_version"]);
    }
    
    // Add to detected collars list (avoid duplicates)
    integer idx = llListFindList(DetectedCollars, [detected_collar]);
    if (idx == -1) {
        DetectedCollars += [detected_collar, current_version];
        llOwnerSay("Detected: Collar v" + current_version + " (" + llGetSubString((string)detected_collar, 0, 7) + "...)");
    }
}

handle_ready_for_transfer(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    llOwnerSay("Collar ready. Starting transfer of " + (string)TotalItems + " scripts...");
    
    TransferIndex = 0;
    llSleep(TRANSFER_DELAY);
    send_transfer_script();
}

handle_script_ack(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    // Move to next script
    TransferIndex += 1;
    
    if (TransferIndex < TotalItems) {
        llSleep(TRANSFER_DELAY);
        send_transfer_script();
    }
    else {
        // All scripts sent
        llSleep(TRANSFER_DELAY);
        send_coordinator();
    }
}

handle_update_complete(string msg) {
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    llOwnerSay("=================================");
    llOwnerSay("UPDATE COMPLETE!");
    llOwnerSay("Collar updated to v" + CurrentVersion);
    llOwnerSay("All settings preserved.");
    llOwnerSay("=================================");
    
    Updating = FALSE;
    TransferIndex = 0;
    CollarKey = NULL_KEY;
    DetectedCollars = [];
    llSetTimerEvent(0.0);
}

/* -------------------- COLLAR SELECTION -------------------- */

process_detection_results() {
    integer collar_count = llGetListLength(DetectedCollars) / COLLAR_STRIDE;
    
    if (collar_count == 0) {
        llOwnerSay("ERROR: No collars detected within range.");
        llOwnerSay("Make sure collar has update module installed.");
        Updating = FALSE;
        return;
    }
    
    if (collar_count == 1) {
        // Only one collar, proceed directly
        CollarKey = llList2Key(DetectedCollars, 0);
        CollarOwner = Wearer;
        string version = llList2String(DetectedCollars, 1);
        
        llOwnerSay("Collar found: v" + version + " -> v" + CurrentVersion);
        proceed_with_update();
    }
    else {
        // Multiple collars, show selection dialog
        show_collar_selection_dialog();
    }
}

show_collar_selection_dialog() {
    list buttons = [];
    integer i = 0;
    integer collar_count = llGetListLength(DetectedCollars) / COLLAR_STRIDE;
    
    while (i < collar_count) {
        string version = llList2String(DetectedCollars, (i * COLLAR_STRIDE) + 1);
        
        // Create button with collar index and version
        string button_label = "#" + (string)(i + 1) + " v" + version;
        buttons += [button_label];
        
        i += 1;
    }
    
    // Add cancel button and pad to multiple of 3
    buttons += ["Cancel"];
    while ((llGetListLength(buttons) % 3) != 0) {
        buttons += [" "];
    }
    
    DialogChannel = generate_dialog_channel();
    DialogListenHandle = llListen(DialogChannel, "", Wearer, "");
    
    string message = "Multiple collars detected (" + (string)collar_count + ").\n\nSelect which collar to update:";
    
    llDialog(Wearer, message, buttons, DialogChannel);
    llSetTimerEvent(60.0);  // Dialog timeout
}

handle_collar_selection(string button) {
    llListenRemove(DialogListenHandle);
    DialogListenHandle = 0;
    
    if (button == "Cancel" || button == " ") {
        llOwnerSay("Update cancelled.");
        Updating = FALSE;
        DetectedCollars = [];
        llSetTimerEvent(0.0);
        return;
    }
    
    // Parse button: "#1 v2.0" -> extract index
    integer hash_pos = llSubStringIndex(button, "#");
    integer space_pos = llSubStringIndex(button, " ");
    
    if (hash_pos == -1 || space_pos == -1) {
        llOwnerSay("ERROR: Invalid selection.");
        Updating = FALSE;
        return;
    }
    
    string index_str = llGetSubString(button, hash_pos + 1, space_pos - 1);
    integer selected_index = (integer)index_str - 1;  // Convert to 0-based
    
    if (selected_index < 0 || selected_index >= (llGetListLength(DetectedCollars) / COLLAR_STRIDE)) {
        llOwnerSay("ERROR: Invalid collar selection.");
        Updating = FALSE;
        return;
    }
    
    // Get selected collar
    CollarKey = llList2Key(DetectedCollars, selected_index * COLLAR_STRIDE);
    CollarOwner = Wearer;
    string version = llList2String(DetectedCollars, (selected_index * COLLAR_STRIDE) + 1);
    
    llOwnerSay("Selected: Collar v" + version + " -> v" + CurrentVersion);
    proceed_with_update();
}

proceed_with_update() {
    // Scan inventory for update
    Manifest = scan_update_inventory();
    TotalItems = llGetListLength(Manifest);
    
    if (TotalItems == 0) {
        llOwnerSay("ERROR: No update scripts found!");
        Updating = FALSE;
        return;
    }
    
    send_prepare_update();
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        ListenHandle = llListen(EXTERNAL_ACL_REPLY_CHAN, "", NULL_KEY, "");
        
        llOwnerSay("=== D/s Collar In-Place Updater ===");
        llOwnerSay("Version: " + CurrentVersion);
        llOwnerSay("Touch to update your worn collar.");
        llOwnerSay("(Works on worn, locked, or RLV-restricted collars)");
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
        if (channel == EXTERNAL_ACL_REPLY_CHAN) {
            if (!json_has(msg, ["type"])) return;
            if (!Updating) return;
            
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "collar_present") {
                handle_collar_present(msg);
            }
            else if (msg_type == "ready_for_transfer") {
                handle_ready_for_transfer(msg);
            }
            else if (msg_type == "script_ack") {
                handle_script_ack(msg);
            }
            else if (msg_type == "update_complete") {
                handle_update_complete(msg);
            }
        }
        else if (channel == DialogChannel) {
            // Dialog response for collar selection
            if (id == Wearer) {
                handle_collar_selection(msg);
            }
        }
    }
    
    timer() {
        // Check if we're in detection phase
        if (llGetListLength(DetectedCollars) > 0 && CollarKey == NULL_KEY) {
            // Detection timeout, process results
            llSetTimerEvent(0.0);
            process_detection_results();
        }
        else {
            // Update timeout
            llOwnerSay("ERROR: Update timeout. Please try again.");
            Updating = FALSE;
            TransferIndex = 0;
            CollarKey = NULL_KEY;
            DetectedCollars = [];
            
            if (DialogListenHandle != 0) {
                llListenRemove(DialogListenHandle);
                DialogListenHandle = 0;
            }
            
            llSetTimerEvent(0.0);
        }
    }
}
