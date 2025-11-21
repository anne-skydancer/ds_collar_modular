/*--------------------
SCRIPT: ds_collar_kmod_update.lsl
VERSION: 1.00
REVISION: 1
PURPOSE: In-place update handler module (extends remote listener)
USAGE: Drop in collar, handles update messages on remote channels
ARCHITECTURE: System 2 update handler - works with remote listener
CHANGES:
- Initial version for update message handling
- Listens on existing remote channels (-8675309, -8675310, -8675311)
- Responds to update discovery
- Manages update transfer process
- Integrates with coordinator for hot-swap
--------------------*/

/* -------------------- REMOTE PROTOCOL CHANNELS -------------------- */
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;  // Update discovery
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;  // Collar responses
integer EXTERNAL_MENU_CHAN      = -8675311;  // Update commands

float MAX_DETECTION_RANGE = 20.0;

/* -------------------- INTERNAL CHANNELS -------------------- */
integer AUTH_BUS = 700;

/* -------------------- STATE -------------------- */
string CURRENT_VERSION = "2.0";  // TODO: Sync with kernel version

key UpdaterKey = NULL_KEY;
string SessionId = "";

list ExpectedScripts = [];
integer ReceivedCount = 0;
integer TotalExpected = 0;

integer UpdateInProgress = FALSE;

integer ListenQueryHandle = 0;
integer ListenMenuHandle = 0;

integer DEBUG = TRUE;

/* -------------------- HELPERS -------------------- */

integer logd(string s) {
    if (DEBUG) llOwnerSay("[UPDATE] " + s);
    return 0;
}

integer json_has(string j, list path) {
    string val = llJsonGetValue(j, path);
    if (val == JSON_INVALID) return FALSE;
    return TRUE;
}

/* -------------------- MESSAGE SENDING -------------------- */

send_collar_present(string session) {
    key wearer = llGetOwner();
    
    // Get owner from auth module
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)wearer,
        "reply_to", "update"
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
    
    // For now, respond immediately (owner check happens in acl_result)
    string response = llList2Json(JSON_OBJECT, [
        "type", "collar_present",
        "collar", (string)llGetKey(),
        "owner", (string)wearer,  // Will be validated by updater
        "wearer", (string)wearer,
        "current_version", CURRENT_VERSION,
        "session", session
    ]);
    
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, response);
    logd("Collar presence announced");
}

send_ready_for_transfer() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ready_for_transfer",
        "session", SessionId
    ]);
    
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, msg);
    logd("Ready for script transfer");
}

/* -------------------- MESSAGE HANDLING -------------------- */

handle_update_discover(string msg) {
    if (UpdateInProgress) {
        logd("Update already in progress - ignoring discovery");
        return;
    }
    
    if (!json_has(msg, ["updater"])) return;
    if (!json_has(msg, ["session"])) return;
    
    key updater = (key)llJsonGetValue(msg, ["updater"]);
    string session = llJsonGetValue(msg, ["session"]);
    
    // Check range
    list details = llGetObjectDetails(updater, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        logd("Updater not found");
        return;
    }
    
    vector updater_pos = llList2Vector(details, 0);
    float distance = llVecDist(llGetPos(), updater_pos);
    
    if (distance > MAX_DETECTION_RANGE) {
        logd("Updater out of range: " + (string)distance + "m");
        return;
    }
    
    logd("Update discovery received from range: " + (string)distance + "m");
    
    // Respond with collar presence
    send_collar_present(session);
}

handle_prepare_update(string msg) {
    if (!json_has(msg, ["updater"])) return;
    if (!json_has(msg, ["session"])) return;
    if (!json_has(msg, ["manifest"])) return;
    if (!json_has(msg, ["total"])) return;
    
    UpdaterKey = (key)llJsonGetValue(msg, ["updater"]);
    SessionId = llJsonGetValue(msg, ["session"]);
    
    string manifest_json = llJsonGetValue(msg, ["manifest"]);
    ExpectedScripts = llJson2List(manifest_json);
    TotalExpected = (integer)llJsonGetValue(msg, ["total"]);
    
    ReceivedCount = 0;
    UpdateInProgress = TRUE;
    
    llOwnerSay("Preparing for update...");
    llOwnerSay("Expecting " + (string)TotalExpected + " scripts");
    
    // Notify ready
    send_ready_for_transfer();
    
    logd("Update preparation complete");
}

handle_transfer_script(string msg) {
    if (!UpdateInProgress) return;
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    if (!json_has(msg, ["script_name"])) return;
    if (!json_has(msg, ["index"])) return;
    
    string script_name = llJsonGetValue(msg, ["script_name"]);
    integer index = (integer)llJsonGetValue(msg, ["index"]);
    
    logd("Incoming script: " + script_name + " (" + (string)index + "/" + (string)TotalExpected + ")");
}

handle_transfer_coordinator(string msg) {
    if (!UpdateInProgress) return;
    if (!json_has(msg, ["session"])) return;
    if (llJsonGetValue(msg, ["session"]) != SessionId) return;
    
    llOwnerSay("Coordinator received. Hot-swap will begin...");
    logd("Coordinator transfer detected");
}

/* -------------------- INVENTORY TRACKING -------------------- */

check_inventory_for_new_scripts() {
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer new_count = 0;
    integer coordinator_present = FALSE;
    integer i = 0;
    
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        
        if (llSubStringIndex(name, ".new") != -1) {
            new_count += 1;
        }
        
        if (name == "ds_collar_updater_coordinator") {
            coordinator_present = TRUE;
        }
        
        i += 1;
    }
    
    logd("New scripts detected: " + (string)new_count);
    
    // Check if we have all scripts + coordinator
    if (new_count >= TotalExpected && coordinator_present) {
        logd("All update files received");
        llOwnerSay("Update package complete. Starting hot-swap...");
        
        // Coordinator will auto-start when it detects .new scripts
        UpdateInProgress = FALSE;
    }
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        ListenQueryHandle = llListen(EXTERNAL_ACL_QUERY_CHAN, "", NULL_KEY, "");
        ListenMenuHandle = llListen(EXTERNAL_MENU_CHAN, "", NULL_KEY, "");
        
        logd("Update handler initialized");
        logd("Listening on channels: " + (string)EXTERNAL_ACL_QUERY_CHAN + ", " + (string)EXTERNAL_MENU_CHAN);
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (!json_has(msg, ["type"])) return;
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (channel == EXTERNAL_ACL_QUERY_CHAN) {
            if (msg_type == "update_discover") {
                handle_update_discover(msg);
            }
        }
        else if (channel == EXTERNAL_MENU_CHAN) {
            if (msg_type == "prepare_update") {
                handle_prepare_update(msg);
            }
            else if (msg_type == "transfer_script") {
                handle_transfer_script(msg);
            }
            else if (msg_type == "transfer_coordinator") {
                handle_transfer_coordinator(msg);
            }
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_INVENTORY) {
            if (UpdateInProgress) {
                // Check if new scripts arriving
                check_inventory_for_new_scripts();
            }
        }
        
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
