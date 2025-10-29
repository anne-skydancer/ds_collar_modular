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

   TWO-PHASE DESIGN:
   1. Discovery Phase: Public channels for scanning (all collars listen)
   2. Session Phase: Per-session secure channels (negotiated after selection)
   =============================================================== */

// Phase 1: Public discovery channels (fixed, not derived)
integer PUBLIC_DISCOVERY_CHAN = -8675309;
integer PUBLIC_DISCOVERY_REPLY_CHAN = -8675310;

// Phase 2: Session channels (derived from HUD wearer + collar owner after selection)
integer SESSION_BASE_CHAN = -8675320;  // Base channel for session derivation
integer SESSION_QUERY_CHAN;
integer SESSION_REPLY_CHAN;
integer SESSION_MENU_CHAN;

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
integer SessionPending = FALSE;  // Waiting for session establishment acknowledgment
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

/* Derive secure session channels from BOTH HUD wearer and collar owner
   This creates a unique channel per HUD-collar pair, preventing crosstalk */
integer deriveSessionChannel(integer base_channel, key hud_wearer, key collar_owner) {
    // Combine both UUIDs to create unique session channel
    integer seed1 = (integer)("0x" + llGetSubString((string)hud_wearer, 0, 7));
    integer seed2 = (integer)("0x" + llGetSubString((string)collar_owner, 0, 7));
    integer combined = (seed1 ^ seed2);  // XOR for uniqueness
    return base_channel + (combined % 1000000);
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
    SessionPending = FALSE;
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
    // Phase 1: Broadcast on PUBLIC discovery channel to find ALL nearby collars
    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "collar_scan",
        "hud_wearer", (string)HudWearer
    ]);

    // Listen for collar responses on public reply channel
    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
    }
    CollarListenHandle = llListen(PUBLIC_DISCOVERY_REPLY_CHAN, "", NULL_KEY, "");

    // Broadcast scan on public discovery channel (all collars listen here)
    llRegionSay(PUBLIC_DISCOVERY_CHAN, json_msg);

    ScanningForCollars = TRUE;
    DetectedCollars = [];
    llSetTimerEvent(COLLAR_SCAN_TIME);

    logd("Broadcasting collar scan on public channel...");
    llOwnerSay("Scanning for nearby collars...");
}

processScanResults() {
    ScanningForCollars = FALSE;
    llSetTimerEvent(0.0);
    
    integer num_collars = llGetListLength(DetectedCollars) / COLLAR_STRIDE;
    
    if (num_collars == 0) {
        llOwnerSay("No collars found nearby.");
        cleanupSession();
        return;
    }

    if (num_collars == 1) {
        // AUTO-CONNECT to single collar (RLV relay style!)
        key avatar_key = llList2Key(DetectedCollars, 0);
        string avatar_name = llList2String(DetectedCollars, 2);

        llOwnerSay("Auto-connecting to " + avatar_name + "...");
        requestAclFromCollar(avatar_key);
        return;
    }

    // Multiple collars - show dialog
    showCollarSelectionDialog();
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
   SESSION ESTABLISHMENT
   =============================================================== */

deriveSessionChannels(key collar_owner) {
    // Phase 2: Derive secure session channels from both HUD wearer + collar owner
    SESSION_QUERY_CHAN = deriveSessionChannel(SESSION_BASE_CHAN, HudWearer, collar_owner);
    SESSION_REPLY_CHAN = SESSION_QUERY_CHAN - 1;
    SESSION_MENU_CHAN = SESSION_QUERY_CHAN - 2;

    logd("Session channels derived:");
    logd("  Query=" + (string)SESSION_QUERY_CHAN);
    logd("  Reply=" + (string)SESSION_REPLY_CHAN);
    logd("  Menu=" + (string)SESSION_MENU_CHAN);
}

requestSessionEstablishment(key collar_owner) {
    // Derive session channels
    deriveSessionChannels(collar_owner);

    // Notify collar about session establishment
    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "session_establish",
        "hud_wearer", (string)HudWearer,
        "collar_owner", (string)collar_owner,
        "session_query", (string)SESSION_QUERY_CHAN,
        "session_reply", (string)SESSION_REPLY_CHAN,
        "session_menu", (string)SESSION_MENU_CHAN
    ]);

    // Send session establishment on public channel (collar still listening there)
    llRegionSay(PUBLIC_DISCOVERY_CHAN, json_msg);

    // Set up listener for session acknowledgment (on public reply channel)
    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
    }
    CollarListenHandle = llListen(PUBLIC_DISCOVERY_REPLY_CHAN, "", NULL_KEY, "");

    SessionPending = TRUE;
    llSetTimerEvent(QUERY_TIMEOUT_SEC);

    logd("Requesting session establishment for " + llKey2Name(collar_owner));
}

/* ===============================================================
   ACL QUERY
   =============================================================== */

requestAclFromCollar(key avatar_key) {
    // First request session establishment (will wait for ack before sending ACL query)
    TargetAvatarKey = avatar_key;
    TargetAvatarName = llKey2Name(avatar_key);
    requestSessionEstablishment(avatar_key);
}

sendAclQuery() {
    // Send ACL query on session channel (called after session is established)
    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query_external",
        "avatar", (string)HudWearer,
        "hud", (string)llGetKey(),
        "target_avatar", (string)TargetAvatarKey
    ]);

    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
    }
    CollarListenHandle = llListen(SESSION_REPLY_CHAN, "", NULL_KEY, "");

    llRegionSay(SESSION_QUERY_CHAN, json_msg);

    AclPending = TRUE;
    llSetTimerEvent(QUERY_TIMEOUT_SEC);

    logd("ACL query sent for " + TargetAvatarName + " on session channel");
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

    llRegionSayTo(TargetCollarKey, SESSION_MENU_CHAN, json_msg);

    if (TargetAvatarKey == HudWearer) {
        llOwnerSay("Opening your collar menu...");
    }
    else {
        llOwnerSay("Opening " + TargetAvatarName + "'s collar menu...");
    }

    cleanupSession();
}

/* ===============================================================
   ACL LEVEL HELPERS
   =============================================================== */

string getAclMessage(integer level) {
    if (level == ACL_PRIMARY_OWNER) return "[OK] Access granted: PRIMARY OWNER";
    if (level == ACL_TRUSTEE) return "[OK] Access granted: TRUSTEE";
    if (level == ACL_OWNED) return "[OK] Access granted: OWNED";
    if (level == ACL_UNOWNED) return "[OK] Access granted: UNOWNED (wearer)";
    if (level == ACL_PUBLIC) return "[OK] Access granted: PUBLIC";
    if (level == ACL_NOACCESS) return "[FAIL] Access denied: NO ACCESS";
    if (level == ACL_BLACKLIST) return "[FAIL] Access denied: BLACKLISTED";
    return "[FAIL] Access denied: Unknown level " + (string)level;
}

integer hasAccess(integer level) {
    if (level == ACL_PRIMARY_OWNER) return TRUE;
    if (level == ACL_TRUSTEE) return TRUE;
    if (level == ACL_OWNED) return TRUE;
    if (level == ACL_UNOWNED) return TRUE;
    if (level == ACL_PUBLIC) return TRUE;
    return FALSE;
}

/* ===============================================================
   ACL LEVEL PROCESSING
   =============================================================== */

processAclResult(integer level) {
    string access_msg = getAclMessage(level);
    integer has_access = hasAccess(level);

    llOwnerSay(access_msg);

    if (has_access) {
        triggerCollarMenu();
    }
    else {
        cleanupSession();
    }
}

/* ===============================================================
   EVENTS
   =============================================================== */

default {
    state_entry() {
        cleanupSession();
        HudWearer = llGetOwner();

        // Session channels will be negotiated after collar selection
        SESSION_QUERY_CHAN = 0;
        SESSION_REPLY_CHAN = 0;
        SESSION_MENU_CHAN = 0;

        logd("Control HUD initialized. Owner: " + llKey2Name(HudWearer));
        logd("Public discovery channels: Query=" + (string)PUBLIC_DISCOVERY_CHAN +
             " Reply=" + (string)PUBLIC_DISCOVERY_REPLY_CHAN);
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
            cleanupSession();
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

        cleanupSession();
        llOwnerSay("Scanning for collars...");
        broadcastCollarScan();
    }
    
    listen(integer channel, string name, key id, string message) {
        // Handle collar scan responses (on public reply channel)
        if (channel == PUBLIC_DISCOVERY_REPLY_CHAN && ScanningForCollars) {
            if (!jsonHas(message, ["type"])) return;

            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type != "collar_scan_response") return;

            if (!jsonHas(message, ["collar_owner"])) return;
            key collar_owner = (key)llJsonGetValue(message, ["collar_owner"]);
            string owner_name = llKey2Name(collar_owner);

            addDetectedCollar(collar_owner, id, owner_name);
            return;
        }

        // Handle session establishment acknowledgment (on public reply channel)
        if (channel == PUBLIC_DISCOVERY_REPLY_CHAN && SessionPending) {
            if (!jsonHas(message, ["type"])) return;

            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type != "session_established_ack") return;

            if (!jsonHas(message, ["collar_owner"])) return;
            key collar_owner = (key)llJsonGetValue(message, ["collar_owner"]);

            // Verify this ack is for the collar we're trying to connect to
            if (collar_owner != TargetAvatarKey) return;

            logd("Session established with " + llKey2Name(collar_owner));
            llOwnerSay("Session established with " + TargetAvatarName);

            // Session is ready, now we can send the ACL query
            SessionPending = FALSE;
            TargetCollarKey = id;  // Save collar object key
            sendAclQuery();
            return;
        }
        
        // Handle collar selection dialog
        if (channel == DIALOG_CHANNEL) {
            llListenRemove(DialogListenHandle);
            DialogListenHandle = 0;
            llSetTimerEvent(0.0);

            if (message == "Cancel") {
                llOwnerSay("Selection cancelled.");
                cleanupSession();
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
                requestAclFromCollar(selected_avatar);
            }
            else {
                llOwnerSay("Error: Selection not found.");
                cleanupSession();
            }
            return;
        }
        
        // Handle ACL responses (on session reply channel)
        if (channel == SESSION_REPLY_CHAN && AclPending) {
            if (!jsonHas(message, ["type"])) return;

            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type != "acl_result_external") return;

            if (!jsonHas(message, ["avatar"])) return;
            key response_avatar = (key)llJsonGetValue(message, ["avatar"]);

            if (response_avatar != HudWearer) return;

            if (!jsonHas(message, ["collar_owner"])) return;
            key collar_owner = (key)llJsonGetValue(message, ["collar_owner"]);

            if (collar_owner != TargetAvatarKey) return;

            llSetTimerEvent(0.0);
            AclPending = FALSE;

            TargetCollarKey = id;

            if (jsonHas(message, ["level"])) {
                AclLevel = (integer)llJsonGetValue(message, ["level"]);
            }

            logd("ACL result: level=" + (string)AclLevel);
            processAclResult(AclLevel);

            if (CollarListenHandle != 0) {
                llListenRemove(CollarListenHandle);
                CollarListenHandle = 0;
            }
        }
    }
    
    timer() {
        if (ScanningForCollars) {
            logd("Collar scan complete");
            processScanResults();
        }
        else if (SessionPending) {
            logd("Session establishment timeout");
            llOwnerSay("[FAIL] Session establishment failed: No response from " + TargetAvatarName);
            cleanupSession();
        }
        else if (AclPending) {
            logd("ACL query timeout");
            llOwnerSay("[FAIL] Connection failed: No response from " + TargetAvatarName);
            cleanupSession();
        }
        else {
            logd("Dialog timeout");
            llOwnerSay("Selection dialog timed out.");
            cleanupSession();
        }
    }
}
