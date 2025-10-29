/* ===============================================================
   CONTROL HUD: ds_collar_control_hud.lsl (v1.0 - Auto-Detect)

   PURPOSE: Auto-detect nearby collars and connect automatically
            Works like RLV relay - broadcast and listen for responses
   
   COMPATIBLE WITH: ds_collar_kmod_remote_v2.lsl
   
   FEATURES:
   - Auto-scan on attach
   - Auto-connect to single collar
   - Multi-collar selection dialog
   - ACL level verification
   - RLV relay-style workflow
   =============================================================== */

integer DEBUG = FALSE;

/* ===============================================================
   EXTERNAL PROTOCOL CHANNELS

   These channels are derived from the wearer's UUID to provide
   per-avatar unique channels, reducing eavesdropping risk.
   =============================================================== */
integer COLLAR_ACL_QUERY_CHAN;
integer COLLAR_ACL_REPLY_CHAN;
integer COLLAR_MENU_CHAN;

/* ===============================================================
   ACL LEVELS
   =============================================================== */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ===============================================================
   DIALOG SETTINGS
   =============================================================== */
float QUERY_TIMEOUT_SEC = 3.0;
float COLLAR_SCAN_TIME = 2.0;
integer DIALOG_CHANNEL = -98765;

/* ===============================================================
   STATE (PascalCase for globals)
   =============================================================== */
key HudWearer = NULL_KEY;
integer CollarListenHandle = 0;
integer DialogListenHandle = 0;

integer ScanningForCollars = FALSE;
integer AclPending = FALSE;
integer AclLevel = ACL_NOACCESS;

key TargetCollarKey = NULL_KEY;
key TargetAvatarKey = NULL_KEY;
string TargetAvatarName = "";

/* Detected collars: [avatar_key, collar_key, avatar_name, ...] */
list DetectedCollars = [];
integer COLLAR_STRIDE = 3;

/* ===============================================================
   HELPERS
   =============================================================== */

integer logd(string msg) {
    if (DEBUG) llOwnerSay("[HUD] " + msg);
    return FALSE;
}

integer jsonHas(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

/* Derive secure channels based on wearer's UUID
   Both HUD and collar use this function to calculate matching channels */
integer deriveSecureChannel(integer base_channel, key owner_key) {
    integer seed = (integer)("0x" + llGetSubString((string)owner_key, 0, 7));
    return base_channel + (seed % 1000000);
}

/* ===============================================================
   SESSION MANAGEMENT
   =============================================================== */

cleanupSession() {
    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
        CollarListenHandle = 0;
    }
    if (DialogListenHandle != 0) {
        llListenRemove(DialogListenHandle);
        DialogListenHandle = 0;
    }
    
    ScanningForCollars = FALSE;
    AclPending = FALSE;
    AclLevel = ACL_NOACCESS;
    TargetCollarKey = NULL_KEY;
    TargetAvatarKey = NULL_KEY;
    TargetAvatarName = "";
    DetectedCollars = [];
    llSetTimerEvent(0.0);
}

/* ===============================================================
   COLLAR DETECTION
   =============================================================== */

addDetectedCollar(key avatar_key, key collar_key, string avatar_name) {
    // Check if already detected
    integer i = 0;
    while (i < llGetListLength(DetectedCollars)) {
        if (llList2Key(DetectedCollars, i) == avatar_key) {
            return;  // Already have this one
        }
        i += COLLAR_STRIDE;
    }
    
    DetectedCollars += [avatar_key, collar_key, avatar_name];
    logd("Detected collar on " + avatar_name);
}

broadcastCollarScan() {
    // Broadcast to find all nearby collars
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
}

processScanResults() {
    ScanningForCollars = FALSE;
    llSetTimerEvent(0.0);
    
    integer num_collars = llGetListLength(DetectedCollars) / COLLAR_STRIDE;
    
    if (num_collars == 0) {
        llOwnerSay("No collars found nearby.");
        cleanup_session();
        return;
    }
    
    if (num_collars == 1) {
        // AUTO-CONNECT to single collar (RLV relay style!)
        key avatar_key = llList2Key(DetectedCollars, 0);
        string avatar_name = llList2String(DetectedCollars, 2);
        
        llOwnerSay("Auto-connecting to " + avatar_name + "...");
        request_acl_from_collar(avatar_key);
        return;
    }
    
    // Multiple collars - show dialog
    show_collar_selection_dialog();
}

/* ===============================================================
   COLLAR SELECTION DIALOG
   =============================================================== */

showCollarSelectionDialog() {
    integer num_collars = llGetListLength(DetectedCollars) / COLLAR_STRIDE;
    
    if (num_collars == 0) return;
    
    // Set up dialog listener
    if (DialogListenHandle != 0) {
        llListenRemove(DialogListenHandle);
    }
    DialogListenHandle = llListen(DIALOG_CHANNEL, "", HudWearer, "");
    
    // Build dialog
    string text = "Multiple collars found. Select one:\n\n";
    list buttons = [];
    integer i = 0;
    
    while (i < llGetListLength(DetectedCollars) && (i / COLLAR_STRIDE) < 12) {
        string avatar_name = llList2String(DetectedCollars, i + 2);
        buttons += [avatar_name];
        i += COLLAR_STRIDE;
    }
    
    if (llGetListLength(buttons) < 12) {
        buttons += ["Cancel"];
    }
    
    llDialog(HudWearer, text, buttons, DIALOG_CHANNEL);
    llSetTimerEvent(30.0);
}

/* ===============================================================
   ACL QUERY
   =============================================================== */

requestAclFromCollar(key avatar_key) {
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
}

/* ===============================================================
   MENU TRIGGERING
   =============================================================== */

triggerCollarMenu() {
    if (TargetCollarKey == NULL_KEY) {
        llOwnerSay("Error: No collar connection established.");
        return;
    }
    
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
}

/* ===============================================================
   ACL LEVEL PROCESSING
   =============================================================== */

processAclResult(integer level) {
    string access_msg = "";
    integer has_access = FALSE;
    
    // Check access level (no ternary, nested if/else per preferences)
    if (level == ACL_PRIMARY_OWNER) {
        access_msg = "[OK] Access granted: PRIMARY OWNER";
        has_access = TRUE;
    }
    else {
        if (level == ACL_TRUSTEE) {
            access_msg = "[OK] Access granted: TRUSTEE"; 
            has_access = TRUE;
        }
        else {
            if (level == ACL_OWNED) {
                access_msg = "[OK] Access granted: OWNED";
                has_access = TRUE;
            }
            else {
                if (level == ACL_UNOWNED) {
                    access_msg = "[OK] Access granted: UNOWNED (wearer)";
                    has_access = TRUE;
                }
                else {
                    if (level == ACL_PUBLIC) {
                        access_msg = "[OK] Access granted: PUBLIC";
                        has_access = TRUE;
                    }
                    else {
                        if (level == ACL_NOACCESS) {
                            access_msg = "[FAIL] Access denied: NO ACCESS";
                            has_access = FALSE;
                        }
                        else {
                            if (level == ACL_BLACKLIST) {
                                access_msg = "[FAIL] Access denied: BLACKLISTED";
                                has_access = FALSE;
                            }
                            else {
                                access_msg = "[FAIL] Access denied: Unknown level " + (string)level;
                                has_access = FALSE;
                            }
                        }
                    }
                }
            }
        }
    }
    
    llOwnerSay(access_msg);
    
    if (has_access) {
        trigger_collar_menu();
    }
    else {
        cleanup_session();
    }
}

/* ===============================================================
   EVENTS
   =============================================================== */

default {
    state_entry() {
        cleanup_session();
        HudWearer = llGetOwner();

        // Derive secure channels based on wearer UUID
        COLLAR_ACL_QUERY_CHAN = deriveSecureChannel(-8675309, HudWearer);
        COLLAR_ACL_REPLY_CHAN = COLLAR_ACL_QUERY_CHAN - 1;
        COLLAR_MENU_CHAN = COLLAR_ACL_QUERY_CHAN - 2;

        logd("Control HUD initialized. Owner: " + llKey2Name(HudWearer));
        logd("Secure channels: Query=" + (string)COLLAR_ACL_QUERY_CHAN +
             " Reply=" + (string)COLLAR_ACL_REPLY_CHAN +
             " Menu=" + (string)COLLAR_MENU_CHAN);
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
            llListenRemove(DialogListenHandle);
            DialogListenHandle = 0;
            llSetTimerEvent(0.0);
            
            if (message == "Cancel") {
                llOwnerSay("Selection cancelled.");
                cleanup_session();
                return;
            }
            
            // Find selected collar by name
            integer i = 0;
            key selected_avatar = NULL_KEY;
            while (i < llGetListLength(DetectedCollars)) {
                string avatar_name = llList2String(DetectedCollars, i + 2);
                if (avatar_name == message) {
                    selected_avatar = llList2Key(DetectedCollars, i);
                    i = llGetListLength(DetectedCollars);  // Exit loop
                }
                else {
                    i += COLLAR_STRIDE;
                }
            }
            
            if (selected_avatar != NULL_KEY) {
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
        else {
            if (AclPending) {
                logd("ACL query timeout");
                llOwnerSay("[FAIL] Connection failed: No response from " + TargetAvatarName);
                cleanup_session();
            }
            else {
                logd("Dialog timeout");
                llOwnerSay("Selection dialog timed out.");
                cleanup_session();
            }
        }
    }
}
