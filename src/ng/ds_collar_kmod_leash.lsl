/*--------------------
MODULE: ds_collar_kmod_leash.lsl
VERSION: 1.00
REVISION: 22
PURPOSE: Leashing engine providing leash services to plugins
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- REVISION 22: Stack-heap collision fix: Inlined all wrapper calls in grab/coffle/post
  functions to reduce call depth by 4-5 levels. Prevents runtime crashes. 1,050 lines.
- REVISION 21: Memory optimization (-180 LOC): ACL tick pattern, inlined wrappers,
  removed unused variables. Reduced from 1,142 to 962 lines (15.8% reduction).
- Added avatar, coffle, and post leash modes with distance enforcement
- Introduced offer acceptance dialog and notifications with timeout handling
- Corrected ACL verification flow for offer and pass actions to prevent deadlocks
- Implemented yank rate limiting and enhanced session security safeguards
- Improved holder detection, offsim handling, and auto-reclip resilience
--------------------*/

integer DEBUG = TRUE;
integer PRODUCTION = FALSE;  // Set FALSE for development

string SCRIPT_ID = "kmod_leash";

integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* -------------------- PROTOCOL CONSTANTS - Moved to top for easy maintenance -------------------- */

// Lockmeister/OpenCollar channel
integer LEASH_CHAN_LM = -8888;
integer LEASH_CHAN_DS = -192837465;

string PLUGIN_CONTEXT = "core_leash";

// Leash mode constants
integer MODE_AVATAR = 0;  // Standard leash to avatar
integer MODE_COFFLE = 1;  // Collar-to-collar leashpoint connection
integer MODE_POST = 2;    // Posted to a static object

// Settings keys
string KEY_LEASHED = "leashed";
string KEY_LEASHER = "leasher_key";
string KEY_LEASH_LENGTH = "leash_length";
string KEY_LEASH_TURNTO = "leash_turnto";

// Leash state
integer Leashed = FALSE;
key Leasher = NULL_KEY;
integer LeashLength = 3;
integer TurnToFace = FALSE;
integer LeashMode = MODE_AVATAR;  // Current leash mode
key LeashTarget = NULL_KEY;       // Target object for coffle/post modes
key CoffleTargetAvatar = NULL_KEY; // Avatar wearing the target collar (coffle mode only)

// Follow mechanics
integer FollowActive = FALSE;
vector LastTargetPos = ZERO_VECTOR;
float LastDistance = -1.0;
integer ControlsOk = FALSE;

// Turn-to-face throttling (NEW)
float LastTurnAngle = -999.0;
float TURN_THRESHOLD = 0.1;  // ~5.7 degrees

// Holder protocol state machine (IMPROVED)
integer HOLDER_STATE_IDLE = 0;
integer HOLDER_STATE_DS_PHASE = 1;
integer HOLDER_STATE_OC_PHASE = 2;
integer HOLDER_STATE_COMPLETE = 4;

integer HolderState = 0;
integer HolderPhaseStart = 0;
integer HolderListen = 0;
integer HolderListenOC = 0;
key HolderTarget = NULL_KEY;
integer HolderSession = 0;
float DS_PHASE_DURATION = 2.0;   // 2 seconds for DS native
float OC_PHASE_DURATION = 2.0;   // 2 seconds for OC

// Offsim detection & auto-reclip (IMPROVED)
integer OffsimDetected = FALSE;
integer OffsimStartTime = 0;
float OFFSIM_GRACE = 6.0;
integer ReclipScheduled = 0;
key LastLeasher = NULL_KEY;
integer ReclipAttempts = 0;
integer MAX_RECLIP_ATTEMPTS = 3;

// ACL verification system (NEW)
key PendingActionUser = NULL_KEY;
string PendingAction = "";
key PendingPassTarget = NULL_KEY;
integer AclPending = FALSE;
key PendingPassOriginalUser = NULL_KEY;  // NEW: Track original passer for error messages
integer PendingIsOffer = FALSE;  // TRUE if this is an offer, not a pass

// Lockmeister authorization (NEW)
key AuthorizedLmController = NULL_KEY;

// Yank rate limiting (NEW)
integer LastYankTime = 0;
float YANK_COOLDOWN = 5.0;  // 5 seconds between yanks

// Timers
float FOLLOW_TICK = 0.5;

/* -------------------- HELPERS -------------------- */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[LEASH-KMOD] " + msg);
    return FALSE;
}
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
string jsonGet(string j, string k, string default_val) {
    if (jsonHas(j, [k])) return llJsonGetValue(j, [k]);
    return default_val;
}

/* -------------------- MESSAGE ROUTING -------------------- */

integer is_message_for_me(string msg) {
    if (llGetSubString(msg, 0, 0) != "{") return FALSE;
    
    integer to_pos = llSubStringIndex(msg, "\"to\"");
    if (to_pos == -1) return TRUE;  // No routing = broadcast
    
    string header = llGetSubString(msg, 0, to_pos + 100);
    
    if (llSubStringIndex(header, "\"*\"") != -1) return TRUE;
    if (llSubStringIndex(header, SCRIPT_ID) != -1) return TRUE;
    if (llSubStringIndex(header, "\"kmod:*\"") != -1) return TRUE;
    
    return FALSE;
}

/* -------------------- PROTOCOL MESSAGE HELPERS - State-based delta pattern -------------------- */
// These define JSON contracts with other modules/objects

/* -------------------- LOCKMEISTER PROTOCOL -------------------- */
setLockmeisterState(integer enabled, key controller) {
    string msg;
    if (enabled) {
        msg = llList2Json(JSON_OBJECT, [
            "type", "lm_enable",
            "controller", (string)controller
        ]);
    } else {
        msg = llList2Json(JSON_OBJECT, [
            "type", "lm_disable"
        ]);
    }
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- PARTICLES PROTOCOL -------------------- */
setParticlesState(integer active, key target) {
    string msg;
    if (active) {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles_start",
            "source", PLUGIN_CONTEXT,
            "target", (string)target,
            "style", "chain"
        ]);
    } else {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles_stop",
            "source", PLUGIN_CONTEXT
        ]);
    }
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}





/* -------------------- STATE MANAGEMENT HELPERS -------------------- */

// Clamp leash length to valid range
integer clampLeashLength(integer len) {
    if (len < 1) return 1;
    if (len > 20) return 20;
    return len;
}

// Close all holder protocol listeners
closeAllHolderListens() {
    if (HolderListen != 0) {
        llListenRemove(HolderListen);
        HolderListen = 0;
    }
    if (HolderListenOC != 0) {
        llListenRemove(HolderListenOC);
        HolderListenOC = 0;
    }
    logd("Holder listens closed");
}

// Clear all leash state (used by release and auto-release)
clearLeashState(integer clear_reclip) {
    Leashed = FALSE;
    Leasher = NULL_KEY;
    LeashMode = MODE_AVATAR;
    LeashTarget = NULL_KEY;
    CoffleTargetAvatar = NULL_KEY;
    persistLeashState(FALSE, NULL_KEY);
    HolderTarget = NULL_KEY;
    HolderState = HOLDER_STATE_IDLE;
    AuthorizedLmController = NULL_KEY;
    closeAllHolderListens();

    if (clear_reclip) {
        LastLeasher = NULL_KEY;
        ReclipScheduled = 0;
        ReclipAttempts = 0;
    }

    setLockmeisterState(FALSE, NULL_KEY);
    setParticlesState(FALSE, NULL_KEY);
    stopFollow();
    broadcastState();
}

/* -------------------- NOTIFICATION HELPERS -------------------- */

// Notify all parties about a leash action
notifyLeashAction(key actor, string action_msg, string owner_details) {
    llRegionSayTo(actor, 0, action_msg);

    if (owner_details != "") {
        llOwnerSay(action_msg + " - " + owner_details);
    } else {
        llOwnerSay(action_msg);
    }

    logd(action_msg);
}



/* -------------------- ACL VERIFICATION SYSTEM (NEW) -------------------- */
requestAclForAction(key user, string action, key pass_target) {
    AclPending = TRUE;
    PendingActionUser = user;
    PendingAction = action;
    PendingPassTarget = pass_target;
    
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user
    ]), user);
    
    logd("ACL query for " + action + " by " + llKey2Name(user));
}

handleAclResult(string msg) {
    if (!AclPending) return;
    if (!jsonHas(msg, ["avatar"]) || !jsonHas(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != PendingActionUser) return;
    
    integer acl = (integer)llJsonGetValue(msg, ["level"]);
    AclPending = FALSE;
    integer authorized = FALSE;
    
    // Special: release (leasher OR acl>=2)
    if (PendingAction == "release") {
        if (PendingActionUser == Leasher || acl >= 2) {
            releaseLeashInternal(PendingActionUser);
            authorized = TRUE;
        }
    }
    // Special: pass (leasher OR acl>=3, then verify target)
    else if (PendingAction == "pass") {
        if (PendingActionUser == Leasher || acl >= 3) {
            requestAclForPassTarget(PendingPassTarget);
            return;
        }
    }
    // Special: offer (acl==2 when not leashed, then verify target)
    else if (PendingAction == "offer") {
        if (acl == 2 && !Leashed) {
            PendingIsOffer = TRUE;
            requestAclForPassTarget(PendingPassTarget);
            return;
        }
        else if (Leashed) {
            llRegionSayTo(PendingActionUser, 0, "Cannot offer: already leashed");
        }
    }
    // Special: pass_target_check (verify target ACL for pass/offer)
    else if (PendingAction == "pass_target_check") {
        if (acl >= 1) {
            if (PendingIsOffer) {
                llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                    "type", "offer_pending",
                    "target", (string)PendingPassTarget,
                    "originator", (string)PendingPassOriginalUser
                ]), NULL_KEY);
            }
            else {
                passLeashInternal(PendingPassTarget);
            }
            authorized = TRUE;
        }
        else {
            llRegionSayTo(PendingPassOriginalUser, 0, "Target lacks permission");
        }
        PendingPassOriginalUser = NULL_KEY;
        PendingIsOffer = FALSE;
    }
    // Standard ACL checks
    else if (PendingAction == "grab") {
        if (acl >= 1) {
            grabLeashInternal(PendingActionUser);
            authorized = TRUE;
        }
    }
    else if (PendingAction == "coffle") {
        if (acl == 3 || acl == 5) {
            coffleLeashInternal(PendingActionUser, PendingPassTarget);
            authorized = TRUE;
        }
    }
    else if (PendingAction == "post") {
        if (acl == 1 || acl == 3 || acl == 5) {
            postLeashInternal(PendingActionUser, PendingPassTarget);
            authorized = TRUE;
        }
    }
    else if (PendingAction == "set_length") {
        if (acl >= 3) {
            setLengthInternal((integer)((string)PendingPassTarget));
            authorized = TRUE;
        }
    }
    else if (PendingAction == "toggle_turn") {
        if (acl >= 3) {
            toggleTurnInternal();
            authorized = TRUE;
        }
    }
    
    if (!authorized) {
        llRegionSayTo(PendingActionUser, 0, "Access denied");
    }
    
    PendingActionUser = NULL_KEY;
    PendingAction = "";
    PendingPassTarget = NULL_KEY;
}

requestAclForPassTarget(key target) {
    // Save original passer for error messages
    PendingPassOriginalUser = PendingActionUser;
    
    // UPDATE: Set PendingActionUser to target so handle_acl_result accepts it
    PendingActionUser = target;
    
    // Reuse pending state for target check
    PendingAction = "pass_target_check";
    AclPending = TRUE;
    
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)target
    ]), target);
    
    logd("ACL query for pass target " + llKey2Name(target));
}

/* -------------------- DS HOLDER PROTOCOL (IMPROVED STATE MACHINE) -------------------- */
beginHolderHandshake(key user) {
    // Improved randomness for session ID using multiple entropy sources
    integer key_entropy = (integer)("0x" + llGetSubString((string)llGetOwner(), 0, 7));
    HolderSession = (integer)(llFrand(999999.0) +
                              (llGetUnixTime() % 1000000) +
                              (key_entropy % 1000));
    HolderState = HOLDER_STATE_DS_PHASE;
    HolderPhaseStart = llGetUnixTime();

    // Phase 1: DS native only
    if (HolderListen == 0) {
        HolderListen = llListen(LEASH_CHAN_DS, "", NULL_KEY, "");
        logd("DS holder listen opened");
    }
    
    // Send DS native JSON format on DS channel
    string msg = llList2Json(JSON_OBJECT, [
        "type", "leash_req",
        "wearer", (string)llGetOwner(),
        "collar", (string)llGetKey(),
        "controller", (string)user,
        "session", (string)HolderSession,
        "origin", "leashpoint"
    ]);
    llRegionSay(LEASH_CHAN_DS, msg);
    
    logd("Holder handshake Phase 1 (DS native, 2s)");
}

handleHolderResponseDs(string msg) {
    if (HolderState != HOLDER_STATE_DS_PHASE && HolderState != HOLDER_STATE_OC_PHASE) return;
    if (llJsonGetValue(msg, ["type"]) != "leash_target") return;
    if (llJsonGetValue(msg, ["ok"]) != "1") return;
    integer session = (integer)llJsonGetValue(msg, ["session"]);
    if (session != HolderSession) return;
    
    HolderTarget = (key)llJsonGetValue(msg, ["holder"]);
    string holder_name = llJsonGetValue(msg, ["name"]);
    
    logd("DS holder response: target=" + (string)HolderTarget + " name=" + holder_name);

    HolderState = HOLDER_STATE_COMPLETE;
    closeAllHolderListens();

    setParticlesState(TRUE, HolderTarget);

    logd("DS holder mode activated");
}

handleHolderResponseOc(key holder_prim, string msg) {
    if (HolderState != HOLDER_STATE_OC_PHASE) return;
    // CRITICAL: Must match the UUID we sent in the ping (Leasher, not wearer)
    string expected = (string)Leasher + "handle ok";
    if (msg != expected) return;
    
    HolderTarget = holder_prim;

    logd("OC holder response: target=" + (string)HolderTarget);

    HolderState = HOLDER_STATE_COMPLETE;
    closeAllHolderListens();

    setParticlesState(TRUE, HolderTarget);

    logd("OC holder mode activated");
}

advanceHolderStateMachine() {
    if (HolderState == HOLDER_STATE_IDLE || HolderState == HOLDER_STATE_COMPLETE) return;
    
    float elapsed = (float)(llGetUnixTime() - HolderPhaseStart);
    
    if (HolderState == HOLDER_STATE_DS_PHASE) {
        if (elapsed >= DS_PHASE_DURATION) {
            // Transition to OC phase
            logd("Holder handshake Phase 2 (OC, 2s)");
            HolderState = HOLDER_STATE_OC_PHASE;
            HolderPhaseStart = llGetUnixTime();
            if (HolderListen != 0) {
                llListenRemove(HolderListen);
                HolderListen = 0;
            }
            if (HolderListenOC == 0) {
                HolderListenOC = llListen(LEASH_CHAN_LM, "", NULL_KEY, "");
                logd("OC holder listen opened");
            }
            
            // CRITICAL FIX: Send controller UUID + "collar" AND "handle" per LM protocol (Code Review Fix #4)
            // The holder script expects the controller's UUID, not the wearer's UUID
            // Send BOTH messages as per the LM protocol specification
            llRegionSayTo(Leasher, LEASH_CHAN_LM, (string)Leasher + "collar");
            llRegionSayTo(Leasher, LEASH_CHAN_LM, (string)Leasher + "handle");
        }
    }
    else if (HolderState == HOLDER_STATE_OC_PHASE) {
        if (elapsed >= OC_PHASE_DURATION) {
            // Fallback to avatar direct
            logd("Holder timeout - using avatar direct mode");
            HolderState = HOLDER_STATE_COMPLETE;
            closeAllHolderListens();

            if (Leasher != NULL_KEY) {
                setParticlesState(TRUE, Leasher);
            }
        }
    }
}

/* -------------------- OFFSIM DETECTION & AUTO-RECLIP (IMPROVED) -------------------- */
checkLeasherPresence() {
    if (!Leashed || Leasher == NULL_KEY) return;
    
    integer now_time = llGetUnixTime();
    
    // Y2038 protection
    if (now_time < 0 || OffsimStartTime < 0) {
        logd("WARNING: Timestamp overflow detected, resetting offsim timer");
        OffsimStartTime = 0;
        OffsimDetected = FALSE;
        return;
    }
    
    // Check both avatar and holder separately
    integer avatar_present = (llGetAgentInfo(Leasher) != 0);
    integer holder_present = FALSE;
    
    if (HolderTarget != NULL_KEY) {
        holder_present = (llGetListLength(llGetObjectDetails(HolderTarget, [OBJECT_POS])) > 0);
    }
    
    integer present = avatar_present || holder_present;
    
    // Notify if holder-only mode (avatar offline, holder remains)
    if (!avatar_present && holder_present && !OffsimDetected) {
        llOwnerSay("Leasher offline, leash held by object");
    }
    
    if (!present) {
        if (!OffsimDetected) {
            OffsimDetected = TRUE;
            OffsimStartTime = now_time;
            logd("Offsim grace started");
        }
        else if ((float)(now_time - OffsimStartTime) >= OFFSIM_GRACE) {
            LastLeasher = Leasher;
            autoReleaseOffsim();
            ReclipScheduled = now_time + 2;
            ReclipAttempts = 0;
        }
    }
    else if (OffsimDetected) {
        OffsimDetected = FALSE;
        OffsimStartTime = 0;
        logd("Leasher returned");
    }
}

autoReleaseOffsim() {
    clearLeashState(FALSE);  // FALSE = don't clear reclip (we want to try reclipping)
    llOwnerSay("Auto-released (offsim)");
}

checkAutoReclip() {
    if (ReclipScheduled == 0 || llGetUnixTime() < ReclipScheduled) return;
    
    if (ReclipAttempts >= MAX_RECLIP_ATTEMPTS) {
        logd("Max reclip attempts reached, giving up");
        ReclipScheduled = 0;
        LastLeasher = NULL_KEY;
        ReclipAttempts = 0;
        return;
    }
    
    if (LastLeasher != NULL_KEY && llGetAgentInfo(LastLeasher) != 0) {
        logd("Attempting auto-reclip (attempt " + (string)(ReclipAttempts + 1) + "/" + (string)MAX_RECLIP_ATTEMPTS + ")");
        
        // Request ACL verification before reclip
        requestAclForAction(LastLeasher, "grab", NULL_KEY);
        
        ReclipAttempts = ReclipAttempts + 1;
        ReclipScheduled = llGetUnixTime() + 2;
    }
}

/* -------------------- SETTINGS PERSISTENCE -------------------- */
persistSetting(string setting_key, string value) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", setting_key,
        "value", value
    ]), NULL_KEY);
}

persistLeashState(integer leashed, key leasher) {
    persistSetting(KEY_LEASHED, (string)leashed);
    persistSetting(KEY_LEASHER, (string)leasher);
}

persistLength(integer length) {
    persistSetting(KEY_LEASH_LENGTH, (string)length);
}

persistTurnto(integer turnto) {
    persistSetting(KEY_LEASH_TURNTO, (string)turnto);
}

applySettingsSync(string msg) {
    if (!jsonHas(msg, ["settings"])) return;
    string settings_json = llJsonGetValue(msg, ["settings"]);
    if (jsonHas(settings_json, [KEY_LEASHED])) {
        Leashed = (integer)llJsonGetValue(settings_json, [KEY_LEASHED]);
    }
    if (jsonHas(settings_json, [KEY_LEASHER])) {
        Leasher = (key)llJsonGetValue(settings_json, [KEY_LEASHER]);
    }
    if (jsonHas(settings_json, [KEY_LEASH_LENGTH])) {
        LeashLength = clampLeashLength((integer)llJsonGetValue(settings_json, [KEY_LEASH_LENGTH]));
    }
    if (jsonHas(settings_json, [KEY_LEASH_TURNTO])) {
        TurnToFace = (integer)llJsonGetValue(settings_json, [KEY_LEASH_TURNTO]);
    }
    logd("Settings loaded");
}

applySettingsDelta(string msg) {
    string setting_key = jsonGet(msg, "key", "");
    string value = jsonGet(msg, "value", "");
    if (setting_key != "" && value != "") {
        if (setting_key == KEY_LEASHED) Leashed = (integer)value;
        else if (setting_key == KEY_LEASHER) Leasher = (key)value;
        else if (setting_key == KEY_LEASH_LENGTH) LeashLength = clampLeashLength((integer)value);
        else if (setting_key == KEY_LEASH_TURNTO) TurnToFace = (integer)value;
    }
}

/* -------------------- STATE BROADCAST -------------------- */
broadcastState() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "leash_state",
        "leashed", (string)Leashed,
        "leasher", (string)Leasher,
        "length", (string)LeashLength,
        "turnto", (string)TurnToFace,
        "mode", (string)LeashMode,
        "target", (string)LeashTarget
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- LEASH ACTIONS (INTERNAL - CALLED AFTER ACL VERIFICATION) -------------------- */
grabLeashInternal(key user) {
    if (Leashed) {
        llRegionSayTo(user, 0, "Already leashed to " + llKey2Name(Leasher));
        return;
    }

    Leashed = TRUE;
    Leasher = user;
    LastLeasher = user;
    LeashMode = MODE_AVATAR;
    LeashTarget = NULL_KEY;
    CoffleTargetAvatar = NULL_KEY;

    // Inline persist to reduce stack depth
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_LEASHED, "value", "1"
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_LEASHER, "value", (string)user
    ]), NULL_KEY);

    beginHolderHandshake(user);

    // Enable Lockmeister - inline to reduce stack depth
    AuthorizedLmController = user;
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "lm_enable",
        "controller", (string)user
    ]), NULL_KEY);

    // Inline startFollow (avatar mode)
    if (Leashed) {
        FollowActive = TRUE;
        if (Leasher != NULL_KEY) {
            llOwnerSay("@follow:" + (string)Leasher + "=force");
        }
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
        logd("Follow started for mode " + (string)LeashMode);
    }

    // Inline notification
    string action_msg = "Leash grabbed";
    llRegionSayTo(user, 0, action_msg);
    llOwnerSay(action_msg + " - by " + llKey2Name(user));
    logd(action_msg);

    // Inline broadcastState
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_state",
        "leashed", "1",
        "leasher", (string)Leasher,
        "length", (string)LeashLength,
        "turnto", (string)TurnToFace,
        "mode", (string)LeashMode,
        "target", (string)LeashTarget
    ]), NULL_KEY);
}

releaseLeashInternal(key user) {
    if (!Leashed) {
        llRegionSayTo(user, 0, "Not currently leashed.");
        return;
    }

    clearLeashState(TRUE);  // TRUE = clear reclip attempts
    notifyLeashAction(user, "Leash released", "by " + llKey2Name(user));
}

passLeashInternal(key new_leasher) {
    if (!Leashed) return;

    key old_leasher = Leasher;
    Leasher = new_leasher;
    LastLeasher = new_leasher;

    // Reset to avatar mode (if was in coffle/post, revert to standard leashing)
    LeashMode = MODE_AVATAR;
    LeashTarget = NULL_KEY;
    CoffleTargetAvatar = NULL_KEY;

    persistLeashState(TRUE, new_leasher);

    // Start holder handshake for new leasher
    beginHolderHandshake(new_leasher);

    // Update Lockmeister authorization
    AuthorizedLmController = new_leasher;
    setLockmeisterState(TRUE, new_leasher);

    llRegionSayTo(old_leasher, 0, "Leash passed to " + llKey2Name(new_leasher));
    llRegionSayTo(new_leasher, 0, "Leash received from " + llKey2Name(old_leasher));
    llOwnerSay("Leash passed to " + llKey2Name(new_leasher) + " by " + llKey2Name(old_leasher));
    broadcastState();
}

coffleLeashInternal(key user, key target_collar) {
    if (Leashed) {
        llRegionSayTo(user, 0, "Already leashed. Unclip first.");
        return;
    }

    list details = llGetObjectDetails(target_collar, [OBJECT_POS, OBJECT_NAME, OBJECT_OWNER]);
    if (llGetListLength(details) == 0) {
        llRegionSayTo(user, 0, "Target collar not found or out of range.");
        return;
    }

    key collar_owner = llList2Key(details, 2);
    if (collar_owner == NULL_KEY) {
        llRegionSayTo(user, 0, "Cannot coffle: target collar has no owner.");
        return;
    }
    if (collar_owner == llGetOwner()) {
        llRegionSayTo(user, 0, "Cannot coffle to yourself.");
        return;
    }

    Leashed = TRUE;
    Leasher = user;
    LastLeasher = user;
    LeashMode = MODE_COFFLE;
    LeashTarget = target_collar;
    CoffleTargetAvatar = collar_owner;

    // Inline persist to reduce stack depth
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_LEASHED, "value", "1"
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_LEASHER, "value", (string)user
    ]), NULL_KEY);

    // Inline particles to reduce stack depth
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "particles_start",
        "source", PLUGIN_CONTEXT,
        "target", (string)target_collar,
        "style", "chain"
    ]), NULL_KEY);

    // Inline startFollow (coffle mode)
    if (Leashed) {
        FollowActive = TRUE;
        if (CoffleTargetAvatar != NULL_KEY) {
            llOwnerSay("@follow:" + (string)CoffleTargetAvatar + "=force");
        }
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
        logd("Follow started for mode " + (string)LeashMode);
    }

    // Inline notification
    string target_name = llList2String(details, 1);
    string action_msg = "Coffled to " + llKey2Name(collar_owner);
    llRegionSayTo(user, 0, action_msg);
    llOwnerSay(action_msg + " - " + target_name);
    logd(action_msg);

    // Inline broadcastState
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_state",
        "leashed", "1",
        "leasher", (string)Leasher,
        "length", (string)LeashLength,
        "turnto", (string)TurnToFace,
        "mode", (string)LeashMode,
        "target", (string)LeashTarget
    ]), NULL_KEY);
}

postLeashInternal(key user, key post_object) {
    if (Leashed) {
        llRegionSayTo(user, 0, "Already leashed. Unclip first.");
        return;
    }

    // Verify target is a valid object
    list details = llGetObjectDetails(post_object, [OBJECT_POS, OBJECT_NAME]);
    if (llGetListLength(details) == 0) {
        llRegionSayTo(user, 0, "Post object not found or out of range.");
        return;
    }

    Leashed = TRUE;
    Leasher = user;
    LastLeasher = user;
    LeashMode = MODE_POST;
    LeashTarget = post_object;
    CoffleTargetAvatar = NULL_KEY;

    // Inline persistLeashState to reduce stack depth
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_LEASHED, "value", "1"
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_LEASHER, "value", (string)user
    ]), NULL_KEY);

    // Inline setParticlesState to reduce stack depth
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "particles_start",
        "source", PLUGIN_CONTEXT,
        "target", (string)post_object,
        "style", "chain"
    ]), NULL_KEY);

    // Inline startFollow to reduce stack depth
    if (Leashed) {
        FollowActive = TRUE;
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
        logd("Follow started for mode " + (string)LeashMode);
    }

    // Inline notifyLeashAction to reduce stack depth
    string object_name = llList2String(details, 1);
    string action_msg = "Posted to " + object_name;
    llRegionSayTo(user, 0, action_msg);
    llOwnerSay(action_msg + " - by " + llKey2Name(user));
    logd(action_msg);

    // Inline broadcastState to reduce stack depth
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_state",
        "leashed", "1",
        "leasher", (string)Leasher,
        "length", (string)LeashLength,
        "turnto", (string)TurnToFace,
        "mode", (string)LeashMode,
        "target", (string)LeashTarget
    ]), NULL_KEY);
}

yankToLeasher() {
    if (!Leashed || Leasher == NULL_KEY) return;

    list details = llGetObjectDetails(Leasher, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        llOwnerSay("Cannot yank: leasher not in range.");
        return;
    }

    vector leasher_pos = llList2Vector(details, 0);
    llOwnerSay("@tpto:" + (string)leasher_pos + "=force");
    llOwnerSay("Yanked to " + llKey2Name(Leasher));
    llRegionSayTo(Leasher, 0, llKey2Name(llGetOwner()) + " yanked to you.");
    logd("Yanked to " + llKey2Name(Leasher));
}

setLengthInternal(integer length) {
    if (length < 1) length = 1;
    if (length > 20) length = 20;
    LeashLength = length;
    persistLength(LeashLength);
    broadcastState();
    logd("Length set to " + (string)length);
}

toggleTurnInternal() {
    TurnToFace = !TurnToFace;
    if (!TurnToFace) {
        llOwnerSay("@setrot=clear");
        LastTurnAngle = -999.0;
    }
    persistTurnto(TurnToFace);
    broadcastState();
    logd("Turn-to-face: " + (string)TurnToFace);
}

/* -------------------- FOLLOW MECHANICS (IMPROVED TURN THROTTLING) -------------------- */
startFollow() {
    if (!Leashed) return;

    FollowActive = TRUE;

    // Set RLV follow based on mode
    if (LeashMode == MODE_AVATAR && Leasher != NULL_KEY) {
        llOwnerSay("@follow:" + (string)Leasher + "=force");
    }
    else if (LeashMode == MODE_COFFLE && CoffleTargetAvatar != NULL_KEY) {
        llOwnerSay("@follow:" + (string)CoffleTargetAvatar + "=force");
    }
    // Post mode: no RLV follow (we enforce distance manually)

    llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
    logd("Follow started for mode " + (string)LeashMode);
}

stopFollow() {
    FollowActive = FALSE;
    llOwnerSay("@follow=clear");
    llStopMoveToTarget();
    LastTargetPos = ZERO_VECTOR;
    LastDistance = -1.0;
    LastTurnAngle = -999.0;
    logd("Follow stopped");
}

turnToTarget(key target) {
    if (!TurnToFace || !Leashed || target == NULL_KEY) return;
    list details = llGetObjectDetails(target, [OBJECT_POS]);
    if (llGetListLength(details) == 0) return;
    vector target_pos = llList2Vector(details, 0);
    vector wearer_pos = llGetRootPosition();
    vector direction = llVecNorm(target_pos - wearer_pos);
    float angle = llAtan2(direction.y, direction.x);

    // Only send command if angle changed significantly
    if (llFabs(angle - LastTurnAngle) > TURN_THRESHOLD) {
        llOwnerSay("@setrot:" + (string)angle + "=force");
        LastTurnAngle = angle;
    }
}

followTick() {
    if (!FollowActive || !Leashed) return;

    // Determine target position based on mode
    vector target_pos;
    key follow_target = NULL_KEY;

    if (LeashMode == MODE_AVATAR) {
        // Avatar mode: follow holder or leasher
        if (HolderTarget != NULL_KEY) {
            list details = llGetObjectDetails(HolderTarget, [OBJECT_POS]);
            if (llGetListLength(details) == 0) {
                HolderTarget = NULL_KEY;
                llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                    "type", "particles_update",
                    "target", (string)Leasher
                ]), NULL_KEY);
                return;
            }
            target_pos = llList2Vector(details, 0);
            follow_target = Leasher;
        }
        else {
            list details = llGetObjectDetails(Leasher, [OBJECT_POS]);
            if (llGetListLength(details) == 0) return;
            target_pos = llList2Vector(details, 0);
            follow_target = Leasher;
        }
    }
    else if (LeashMode == MODE_COFFLE) {
        // Coffle mode: follow the avatar wearing the target collar
        if (CoffleTargetAvatar == NULL_KEY) return;
        list details = llGetObjectDetails(CoffleTargetAvatar, [OBJECT_POS]);
        if (llGetListLength(details) == 0) return;
        target_pos = llList2Vector(details, 0);
        follow_target = CoffleTargetAvatar;
    }
    else if (LeashMode == MODE_POST) {
        // Post mode: stay near the post object
        if (LeashTarget == NULL_KEY) return;
        list details = llGetObjectDetails(LeashTarget, [OBJECT_POS]);
        if (llGetListLength(details) == 0) return;
        target_pos = llList2Vector(details, 0);
        follow_target = LeashTarget;
    }

    vector wearer_pos = llGetRootPosition();
    float distance = llVecDist(wearer_pos, target_pos);

    if (ControlsOk && distance > (float)LeashLength) {
        vector pull_pos = target_pos + llVecNorm(wearer_pos - target_pos) * (float)LeashLength * 0.98;
        if (llVecMag(pull_pos - LastTargetPos) > 0.2) {
            llMoveToTarget(pull_pos, 0.5);
            LastTargetPos = pull_pos;
        }
        if (TurnToFace && follow_target != NULL_KEY) {
            turnToTarget(follow_target);
        }
    }
    else if (LastDistance >= 0.0 && LastDistance > (float)LeashLength) {
        llStopMoveToTarget();
        LastTargetPos = ZERO_VECTOR;
    }

    LastDistance = distance;
}

/* -------------------- EVENT HANDLERS -------------------- */
default
{
    state_entry() {
        closeAllHolderListens();
        HolderTarget = NULL_KEY;
        HolderState = HOLDER_STATE_IDLE;
        AclPending = FALSE;
        PendingActionUser = NULL_KEY;
        PendingAction = "";
        PendingPassTarget = NULL_KEY;
        AuthorizedLmController = NULL_KEY;
        
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]), NULL_KEY);
        llSetTimerEvent(FOLLOW_TICK);
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);

        // Memory diagnostics
        integer used = llGetUsedMemory();
        integer free = llGetFreeMemory();
        if (DEBUG && !PRODUCTION) logd("Leash kmod ready (v2.0) - Memory: " + (string)used + " used, " + (string)free + " free");
        if (DEBUG && !PRODUCTION) logd("Leash kmod ready (v2.0 MULTI-MODE)");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }
    
    run_time_permissions(integer perm) {
        if (perm & PERMISSION_TAKE_CONTROLS) {
            ControlsOk = TRUE;
            logd("Controls permission granted");
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        // Early filter: ignore messages not for us
        if (!is_message_for_me(msg)) return;
        
        // OPTIMIZATION: Check "type" once at the top (Code Review Fix #3)
        if (!jsonHas(msg, ["type"])) return;
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (num == UI_BUS) {
            
            // Commands from config plugin - NOW WITH ACL VERIFICATION
            if (msg_type == "leash_action") {
                string action = jsonGet(msg, "action", "");
                if (action == "") return;
                key user = id;
                
                // Query state doesn't need ACL
                if (action == "query_state") {
                    broadcastState();
                    return;
                }
                
                // Yank only works for current leasher (with rate limiting)
                if (action == "yank") {
                    if (user == Leasher) {
                        integer now_time = llGetUnixTime();
                        if ((now_time - LastYankTime) < YANK_COOLDOWN) {
                            integer wait_time = (integer)(YANK_COOLDOWN - (now_time - LastYankTime));
                            llRegionSayTo(user, 0, "Yank on cooldown. Wait " + (string)wait_time + "s.");
                            return;
                        }
                        LastYankTime = now_time;
                        yankToLeasher();
                    } else {
                        llRegionSayTo(user, 0, "Only the current leasher can yank.");
                    }
                    return;
                }
                
                // All other actions require ACL verification
                key target = (key)jsonGet(msg, "target", (string)NULL_KEY);

                // Special case: set_length repurposes target field for length value
                if (action == "set_length") {
                    target = (key)jsonGet(msg, "length", "0");
                }

                // Single call handles all actions
                requestAclForAction(user, action, target);
                return;
            }
            
            // Lockmeister notifications from particles - VERIFY AUTHORIZATION
            if (msg_type == "lm_grabbed") {
                key controller = (key)jsonGet(msg, "controller", (string)NULL_KEY);
                if (controller == NULL_KEY) return;
                
                // SECURITY: Only accept if this controller was authorized
                if (controller != AuthorizedLmController) {
                    logd("Rejected LM grab from unauthorized controller: " + llKey2Name(controller));
                    return;
                }
                
                if (!Leashed) {
                    Leashed = TRUE;
                    Leasher = controller;
                    LastLeasher = controller;
                    persistLeashState(TRUE, controller);
                    startFollow();
                    llOwnerSay("Leashed by " + llKey2Name(controller) + " (Lockmeister)");
                    broadcastState();
                    logd("Lockmeister grab from " + llKey2Name(controller));
                }
                return;
            }
            
            if (msg_type == "lm_released") {
                if (Leashed) {
                    key old_leasher = Leasher;
                    Leashed = FALSE;
                    Leasher = NULL_KEY;
                    persistLeashState(FALSE, NULL_KEY);
                    AuthorizedLmController = NULL_KEY;
                    stopFollow();
                    llOwnerSay("Released by " + llKey2Name(old_leasher) + " (Lockmeister)");
                    broadcastState();
                    logd("Lockmeister release");
                }
                return;
            }
            return;
        }
        
        if (num == AUTH_BUS) {
            if (msg_type == "acl_result") {
                handleAclResult(msg);
            }
            return;
        }
        
        if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync") applySettingsSync(msg);
            else if (msg_type == "settings_delta") applySettingsDelta(msg);
            return;
        }
    }
    
    timer() {
        // Advance holder detection state machine
        advanceHolderStateMachine();
        
        // Check for offsim/auto-release
        if (Leashed) checkLeasherPresence();
        if (!Leashed && ReclipScheduled != 0) checkAutoReclip();
        
        // Follow tick
        if (FollowActive && Leashed) followTick();
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (channel == LEASH_CHAN_DS) {
            handleHolderResponseDs(msg);
        }
        else if (channel == LEASH_CHAN_LM) {
            handleHolderResponseOc(id, msg);
        }
    }
}
