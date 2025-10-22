/* =============================================================
   CONTROL HUD: ds_control_hud.lsl - OPTIMIZED VERSION
   PURPOSE: Auto-detect nearby collars and connect automatically
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Communication Channels ---------- */
integer COLLAR_ACL_QUERY_CHAN = -8675309;
integer COLLAR_ACL_REPLY_CHAN = -8675310;
integer COLLAR_MENU_CHAN      = -8675311;

/* ---------- ACL Levels ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- ACL Level Names (for fast lookup) ---------- */
list ACL_NAMES = [
    "BLACKLISTED",
    "NO ACCESS",
    "PUBLIC",
    "OWNED",
    "TRUSTEE",
    "UNOWNED (wearer)",
    "PRIMARY OWNER"
];

/* ---------- Dialog Settings ---------- */
float QUERY_TIMEOUT_SEC = 3.0;
float COLLAR_SCAN_TIME = 2.0;
integer DIALOG_CHANNEL = -98765;
integer DIALOG_LISTEN_HANDLE = 0;

/* ---------- State Variables (PascalCase globals) ---------- */
key HudWearer = NULL_KEY;
integer CollarListenHandle = 0;

integer ScanningForCollars = FALSE;
integer AclPending = FALSE;
integer AclLevel = ACL_NOACCESS;

key TargetCollarKey = NULL_KEY;
key TargetAvatarKey = NULL_KEY;
string TargetAvatarName = "";

/* Detected collars: [avatar_key, collar_key, avatar_name, ...] */
list DetectedCollars = [];
integer COLLAR_STRIDE = 3;

/* ========================== Helpers ========================== */

integer find_collar_index_by_name(string avatar_name) {
    integer i = 2;
    integer len = llGetListLength(DetectedCollars);
    while (i < len) {
        if (llList2String(DetectedCollars, i) == avatar_name) {
            return i - 2;
        }
        i = i + COLLAR_STRIDE;
    }
    return -1;
}

integer logd(string msg) {
    if (DEBUG) llOwnerSay("[CONTROL_HUD] " + msg);
    return 0;
}

integer json_has(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

/* ========================== Session Management ========================== */

integer cleanup_session() {
    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
        CollarListenHandle = 0;
    }
    if (DIALOG_LISTEN_HANDLE != 0) {
        llListenRemove(DIALOG_LISTEN_HANDLE);
        DIALOG_LISTEN_HANDLE = 0;
    }
    
    ScanningForCollars = FALSE;
    AclPending = FALSE;
    AclLevel = ACL_NOACCESS;
    TargetCollarKey = NULL_KEY;
    TargetAvatarKey = NULL_KEY;
    TargetAvatarName = "";
    DetectedCollars = [];
    llSetTimerEvent(0.0);
    return 0;
}

/* ========================== Collar Detection ========================== */

integer find_collar_index(key avatar_key) {
    integer i = 0;
    integer len = llGetListLength(DetectedCollars);
    while (i < len) {
        if (llList2Key(DetectedCollars, i) == avatar_key) {
            return i;
        }
        i = i + COLLAR_STRIDE;
    }
    return -1;
}

integer add_detected_collar(key avatar_key, key collar_key, string avatar_name) {
    if (find_collar_index(avatar_key) != -1) {
        return 0;
    }
    
    DetectedCollars = DetectedCollars + [avatar_key, collar_key, avatar_name];
    logd("Detected collar on " + avatar_name);
    return 1;
}

integer broadcast_collar_scan() {
    // Build JSON message efficiently
    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "collar_scan",
        "hud_wearer", (string)HudWearer
    ]);
    
    // Listen for collar responses
    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
    }
    CollarListenHandle = llListen(COLLAR_ACL_REPLY_CHAN, "", NULL_KEY, "");
    
    // Broadcast scan
    llRegionSay(COLLAR_ACL_QUERY_CHAN, json_msg);
    
    ScanningForCollars = TRUE;
    DetectedCollars = [];
    llSetTimerEvent(COLLAR_SCAN_TIME);
    
    logd("Broadcasting collar scan...");
    llOwnerSay("Scanning for nearby collars...");
    
    return 0;
}

integer process_scan_results() {
    ScanningForCollars = FALSE;
    llSetTimerEvent(0.0);
    
    integer num_collars = llGetListLength(DetectedCollars) / COLLAR_STRIDE;
    
    if (num_collars == 0) {
        llOwnerSay("No collars found nearby.");
        cleanup_session();
        return 0;
    }
    
    if (num_collars == 1) {
        // AUTO-CONNECT to single collar
        key avatar_key = llList2Key(DetectedCollars, 0);
        string avatar_name = llList2String(DetectedCollars, 2);
        
        llOwnerSay("Auto-connecting to " + avatar_name + "...");
        request_acl_from_collar(avatar_key);
        return 0;
    }
    
    // Multiple collars - show dialog
    show_collar_selection_dialog();
    return 0;
}

/* ========================== Collar Selection Dialog ========================== */

integer show_collar_selection_dialog() {
    integer num_collars = llGetListLength(DetectedCollars) / COLLAR_STRIDE;
    
    if (num_collars == 0) return FALSE;
    
    // Set up dialog listener
    if (DIALOG_LISTEN_HANDLE != 0) {
        llListenRemove(DIALOG_LISTEN_HANDLE);
    }
    DIALOG_LISTEN_HANDLE = llListen(DIALOG_CHANNEL, "", HudWearer, "");
    
    // Build dialog
    list buttons = [];
    integer i = 0;
    integer max_buttons = 11;
    
    while (i < llGetListLength(DetectedCollars) && (i / COLLAR_STRIDE) < max_buttons) {
        buttons = buttons + [llList2String(DetectedCollars, i + 2)];
        i = i + COLLAR_STRIDE;
    }
    
    buttons = buttons + ["Cancel"];
    
    llDialog(HudWearer, "Multiple collars found. Select one:", buttons, DIALOG_CHANNEL);
    llSetTimerEvent(30.0);
    
    return TRUE;
}

/* ========================== ACL Query ========================== */

integer request_acl_from_collar(key avatar_key) {
    // Build JSON message efficiently
    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query_external",
        "avatar", (string)HudWearer,
        "hud", (string)llGetKey(),
        "target_avatar", (string)avatar_key
    ]);
    
    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
    }
    CollarListenHandle = llListen(COLLAR_ACL_REPLY_CHAN, "", NULL_KEY, "");
    
    llRegionSay(COLLAR_ACL_QUERY_CHAN, json_msg);
    
    AclPending = TRUE;
    TargetAvatarKey = avatar_key;
    TargetAvatarName = llKey2Name(avatar_key);
    llSetTimerEvent(QUERY_TIMEOUT_SEC);
    
    logd("ACL query sent for " + TargetAvatarName);
    
    return 0;
}

/* ========================== Menu Triggering ========================== */

integer trigger_collar_menu() {
    if (TargetCollarKey == NULL_KEY) {
        llOwnerSay("Error: No collar connection established.");
        return FALSE;
    }
    
    // Build JSON message efficiently
    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "menu_request_external",
        "avatar", (string)HudWearer
    ]);
    
    llRegionSayTo(TargetCollarKey, COLLAR_MENU_CHAN, json_msg);
    
    if (TargetAvatarKey == HudWearer) {
        llOwnerSay("Opening your collar menu...");
    }
    else {
        llOwnerSay("Opening " + TargetAvatarName + "'s collar menu...");
    }
    
    cleanup_session();
    return 0;
}

/* ========================== ACL Level Processing ========================== */

integer process_acl_result(integer level) {
    integer has_access = (level >= ACL_PUBLIC);
    string symbol = "";
    string access_level = "";
    
    if (has_access) {
        symbol = "✓";
    }
    else {
        symbol = "✗";
    }
    
    // Fast lookup using list index
    integer index = level + 1;
    if (index >= 0 && index < llGetListLength(ACL_NAMES)) {
        access_level = llList2String(ACL_NAMES, index);
    }
    else {
        access_level = "Unknown level " + (string)level;
    }
    
    if (has_access) {
        llOwnerSay(symbol + " Access granted: " + access_level);
        trigger_collar_menu();
        return TRUE;
    }
    else {
        llOwnerSay(symbol + " Access denied: " + access_level);
        cleanup_session();
        return FALSE;
    }
}

/* ========================== Events ========================== */

default {
    state_entry() {
        cleanup_session();
        HudWearer = llGetOwner();
        logd("Control HUD initialized. Owner: " + llKey2Name(HudWearer));
        llOwnerSay("Control HUD ready. Touch to scan for collars.");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    attach(key id) {
        if (id != NULL_KEY) {
            llResetScript();
        }
        else {
            cleanup_session();
        }
    }
    
    changed(integer change_mask) {
        if (change_mask & CHANGED_OWNER) {
            llResetScript();
        }
    }
    
    touch_start(integer num_detected) {
        if (ScanningForCollars) {
            llOwnerSay("Scan already in progress...");
            return;
        }
        
        if (AclPending) {
            llOwnerSay("Still waiting for collar response...");
            return;
        }
        
        cleanup_session();
        llOwnerSay("Scanning for collars...");
        broadcast_collar_scan();
    }
    
    listen(integer channel, string name, key id, string message) {
        // Handle collar scan responses
        if (channel == COLLAR_ACL_REPLY_CHAN && ScanningForCollars) {
            if (!json_has(message, ["type"])) return;
            
            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type != "collar_scan_response") return;
            
            if (!json_has(message, ["collar_owner"])) return;
            key collar_owner = (key)llJsonGetValue(message, ["collar_owner"]);
            string owner_name = llKey2Name(collar_owner);
            
            add_detected_collar(collar_owner, id, owner_name);
            return;
        }
        
        // Handle collar selection dialog
        if (channel == DIALOG_CHANNEL) {
            llListenRemove(DIALOG_LISTEN_HANDLE);
            DIALOG_LISTEN_HANDLE = 0;
            llSetTimerEvent(0.0);
            
            if (message == "Cancel") {
                llOwnerSay("Selection cancelled.");
                cleanup_session();
                return;
            }
            
            // Find selected collar by name
            integer idx = find_collar_index_by_name(message);
            
            if (idx != -1) {
                key selected_avatar = llList2Key(DetectedCollars, idx);
                llOwnerSay("Connecting to " + message + "...");
                request_acl_from_collar(selected_avatar);
            }
            else {
                llOwnerSay("Error: Selection not found.");
                cleanup_session();
            }
            return;
        }
        
        // Handle ACL responses
        if (channel == COLLAR_ACL_REPLY_CHAN && AclPending) {
            if (!json_has(message, ["type"])) return;
            
            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type != "acl_result_external") return;
            
            if (!json_has(message, ["avatar"])) return;
            key response_avatar = (key)llJsonGetValue(message, ["avatar"]);
            
            if (response_avatar != HudWearer) return;
            
            if (!json_has(message, ["collar_owner"])) return;
            key collar_owner = (key)llJsonGetValue(message, ["collar_owner"]);
            
            if (collar_owner != TargetAvatarKey) return;
            
            llSetTimerEvent(0.0);
            AclPending = FALSE;
            
            TargetCollarKey = id;
            
            if (json_has(message, ["level"])) {
                AclLevel = (integer)llJsonGetValue(message, ["level"]);
            }
            
            logd("ACL result: level=" + (string)AclLevel);
            process_acl_result(AclLevel);
            
            if (CollarListenHandle != 0) {
                llListenRemove(CollarListenHandle);
                CollarListenHandle = 0;
            }
        }
    }
    
    timer() {
        if (ScanningForCollars) {
            logd("Collar scan complete");
            process_scan_results();
        }
        else if (AclPending) {
            logd("ACL query timeout");
            llOwnerSay("✗ Connection failed: No response from " + TargetAvatarName);
            cleanup_session();
        }
        else {
            logd("Dialog timeout");
            llOwnerSay("Selection dialog timed out.");
            cleanup_session();
        }
    }
}
