/* ===============================================================
   DS Collar - Leash Kernel Module (v2.0 MULTI-MODE)

   PURPOSE: Leashing engine - provides leash services to plugins

   NEW FEATURES v2.0:
   - Added three leash modes: Avatar, Coffle, Post
   - ALL modes enforce distance limit using existing follow mechanics
   - Avatar mode: PRESERVES ALL EXISTING LOGIC (holder detection, offsim, etc.)
   - Coffle: Collar-to-collar - follow the other collar wearer, stay within LeashLength
   - Post: Object tether - stay within LeashLength of post object
   - Mode-specific ACL restrictions (Coffle: ACL 3,5 | Post: ACL 1,3,5)
   
   NEW FEATURES v1.0:
   - Added offer acceptance dialog for leash offers
   - Target receives Accept/Decline dialog with 60s timeout
   - Originator receives notification of acceptance/decline/timeout
   
   BUG FIXES v1.0:
   - CRITICAL: Fixed offer/pass target ACL verification deadlock
   - request_acl_for_pass_target now updates PendingActionUser to target
   - Prevents handle_acl_result from rejecting target's ACL response
   
   NEW FEATURES v1.0:
   - Added "offer" action for ACL 2 (Owned wearer)
   - Offer allows owned wearer to offer leash when not currently leashed
   - Separate from "pass" action with distinct permissions and behavior
   
   BUG FIXES v1.0:
   - CRITICAL: Fixed auto-reclip after explicit unleash bug
   - CRITICAL: Fixed LM protocol to send controller UUID instead of wearer UUID
   - Added holder name constant to top for easy maintenance
   - Optimized link_message by checking "type" once at top
   - Added channel constants (LEASH_CHAN_LM, LEASH_CHAN_DS) to top
   
   SECURITY FIXES v1.0:
   - Added yank rate limiting (5s cooldown) to prevent griefing
   - Fixed pass target ACL verification to preserve original passer context
   - Added Y2038 timestamp overflow protection
   - Improved session randomness with multiple entropy sources
   - Added production debug guard (dual-gate logging)
   
   SECURITY FIXES v1.0:
   - Added ACL verification system (no longer trusts plugin flags)
   - Implemented holder detection state machine (no race conditions)
   - Added auto-reclip attempt limiting
   - Improved offsim detection with separate avatar/holder tracking
   - Enhanced session security with better randomness
   - Added turn-to-face throttling to reduce RLV spam
   - Implemented Lockmeister authorization validation
   
   FEATURES:
   - Grab/Release/Pass/Offer/Yank leash actions
   - Multi-protocol: DS Holder, OpenCollar 8.x, Avatar Direct, Lockmeister
   - Cascading holder detection (2s DS native -> 2s OC -> avatar direct)
   - Offsim detection with auto-release (6s grace)
   - Auto-reclip when leasher returns (limited attempts)
   - RLV follow + MoveToTarget enforcement
   - Turn-to-face support (throttled)
   
   ARCHITECTURE:
   - Kernel module (infrastructure, not a plugin)
   - Receives leash_action commands from plugin_leash UI
   - Sends leash_state updates to plugin_leash UI
   - Integrates with particles module for visual rendering
   - Uses settings module for persistence
   - Uses auth module for ACL verification
   
   CHANNELS:
   - 700: Auth queries
   - 800: Settings persistence
   - 900: UI/command bus
   - -192837465: DS Holder protocol
   - -8888: OpenCollar holder protocol
   =============================================================== */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* ===============================================================
   PROTOCOL CONSTANTS - Moved to top for easy maintenance
   =============================================================== */

// Holder object name (change here if needed)
string DS_HOLDER_NAME = "DS Leash Holder";

// Lockmeister/OpenCollar channel
integer LEASH_CHAN_LM = -8888;
integer LEASH_CHAN_DS = -192837465;

string PLUGIN_CONTEXT = "core_leash";
string PLUGIN_LABEL = "Leash";

// ACL definitions for leash operations
list ALLOWED_ACL_GRAB = [1, 3, 4, 5];     // Public, Trustee, Unowned, Owner
list ALLOWED_ACL_SETTINGS = [3, 4, 5];    // Trustee, Unowned, Owner
list ALLOWED_ACL_PASS = [3, 4, 5];        // Trustee, Unowned, Owner (plus current leasher)
list ALLOWED_ACL_OFFER = [2];             // Owned wearer only (when not currently leashed)
list ALLOWED_ACL_COFFLE = [3, 5];         // Trustee, Owner only
list ALLOWED_ACL_POST = [1, 3, 5];        // Public, Trustee, Owner

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
integer HOLDER_STATE_FALLBACK = 3;
integer HOLDER_STATE_COMPLETE = 4;

integer HolderState = 0;
integer HolderPhaseStart = 0;
integer HolderListen = 0;
integer HolderListenOC = 0;
key HolderTarget = NULL_KEY;
integer HolderSession = 0;
float DS_PHASE_DURATION = 2.0;   // 2 seconds for DS native
float OC_PHASE_DURATION = 2.0;   // 2 seconds for OC
float TOTAL_TIMEOUT = 4.0;       // Total 4 seconds before fallback

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

// ===== HELPERS =====
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[LEASH-KMOD] " + msg);
    return FALSE;
}
integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
string jsonGet(string j, string key, string default_val) {
    if (jsonHas(j, [key])) return llJsonGetValue(j, [key]);
    return default_val;
}
integer now() {
    return llGetUnixTime();
}
integer inAllowedList(integer level, list allowed) {
    return (llListFindList(allowed, [level]) != -1);
}
denyAccess(key user, string reason, string action, integer acl) {
    llRegionSayTo(user, 0, "Access denied: " + reason);
    logd(action + " denied for ACL " + (string)acl + " - " + reason);
}

/* ===============================================================
   PROTOCOL MESSAGE HELPERS - State-based delta pattern
   These define JSON contracts with other modules/objects
   =============================================================== */

// ===== LOCKMEISTER PROTOCOL =====
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

// ===== PARTICLES PROTOCOL =====
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

updateParticlesTarget(key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "particles_update",
        "target", (string)target
    ]), NULL_KEY);
}

// ===== OFFER PROTOCOL =====
sendOfferPending(key target, key originator) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "offer_pending",
        "target", (string)target,
        "originator", (string)originator
    ]), NULL_KEY);
}

/* ===============================================================
   STATE MANAGEMENT HELPERS
   =============================================================== */

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

/* ===============================================================
   NOTIFICATION HELPERS
   =============================================================== */

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

// For multi-party notifications (like pass)
notifyLeashTransfer(key from_user, key to_user, string action) {
    llRegionSayTo(from_user, 0, "Leash " + action + " to " + llKey2Name(to_user));
    llRegionSayTo(to_user, 0, "Leash received from " + llKey2Name(from_user));
    llOwnerSay("Leash " + action + " to " + llKey2Name(to_user) + " by " + llKey2Name(from_user));
    logd(action + " to " + llKey2Name(to_user) + " by " + llKey2Name(from_user));
}

// ===== ACL VERIFICATION SYSTEM (NEW) =====
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

handleAclResult(string msg, key id) {
    if (!AclPending) return;
    if (!jsonHas(msg, ["avatar"]) || !jsonHas(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != PendingActionUser) return;
    
    integer acl_level = (integer)llJsonGetValue(msg, ["level"]);
    AclPending = FALSE;
    
    logd("ACL result: " + (string)acl_level + " for " + PendingAction);
    
    // Execute pending action with ACL verification

    // Special case: release (current leasher OR level 2+ can release)
    if (PendingAction == "release") {
        if (PendingActionUser == Leasher || acl_level >= 2) {
            releaseLeashInternal(PendingActionUser);
        } else {
            denyAccess(PendingActionUser, "only leasher or authorized users can release", "release", acl_level);
        }
    }
    // Special case: pass (current leasher OR level 3+ can pass, then verify target)
    else if (PendingAction == "pass") {
        if (PendingActionUser == Leasher || inAllowedList(acl_level, ALLOWED_ACL_PASS)) {
            requestAclForPassTarget(PendingPassTarget);
            return;  // Don't clear pending state yet
        } else {
            denyAccess(PendingActionUser, "insufficient permissions to pass leash", "pass", acl_level);
        }
    }
    // Special case: offer (ACL 2 only, when NOT currently leashed, then verify target)
    else if (PendingAction == "offer") {
        if (inAllowedList(acl_level, ALLOWED_ACL_OFFER) && !Leashed) {
            PendingIsOffer = TRUE;
            requestAclForPassTarget(PendingPassTarget);
            return;  // Don't clear pending state yet
        } else if (Leashed) {
            llRegionSayTo(PendingActionUser, 0, "Cannot offer leash: already leashed.");
            logd("Offer denied: already leashed");
        } else {
            denyAccess(PendingActionUser, "insufficient permissions to offer leash", "offer", acl_level);
        }
    }
    // Special case: pass_target_check (verifying the target's ACL for pass/offer)
    else if (PendingAction == "pass_target_check") {
        // This is the target verification for pass/offer action
        // Target must be level 1+ (public or higher) to receive leash
        key target = (key)llJsonGetValue(msg, ["avatar"]);

        logd("Target ACL check: " + llKey2Name(target) + " has ACL " + (string)acl_level + ", IsOfferMode=" + (string)PendingIsOffer);

        if (acl_level >= 1) {
            // Offer sends message to plugin for dialog, pass directly transfers
            if (PendingIsOffer) {
                // Send offer_pending to plugin - plugin will handle dialog
                sendOfferPending(PendingPassTarget, PendingPassOriginalUser);
                logd("Offer pending sent to plugin: target=" + llKey2Name(PendingPassTarget) + ", originator=" + llKey2Name(PendingPassOriginalUser));
            }
            else {
                passLeashInternal(PendingPassTarget);
            }
        } else {
            // Send error to ORIGINAL passer/offerer, not target
            string action_name;
            if (PendingIsOffer) {
                action_name = "offer";
            }
            else {
                action_name = "pass";
            }
            llRegionSayTo(PendingPassOriginalUser, 0, "Cannot " + action_name + " leash: target has insufficient permissions.");
            logd(action_name + " denied: target ACL " + (string)acl_level + " too low");
        }

        // Clear pass-specific state
        PendingPassOriginalUser = NULL_KEY;
        PendingIsOffer = FALSE;
    }
    // Standard ACL pattern for simple actions
    else {
        list allowed_acl;
        integer authorized = FALSE;

        if (PendingAction == "grab") {
            allowed_acl = ALLOWED_ACL_GRAB;
            authorized = inAllowedList(acl_level, allowed_acl);
            if (authorized) grabLeashInternal(PendingActionUser);
        }
        else if (PendingAction == "coffle") {
            allowed_acl = ALLOWED_ACL_COFFLE;
            authorized = inAllowedList(acl_level, allowed_acl);
            if (authorized) coffleLeashInternal(PendingActionUser, PendingPassTarget);
        }
        else if (PendingAction == "post") {
            allowed_acl = ALLOWED_ACL_POST;
            authorized = inAllowedList(acl_level, allowed_acl);
            if (authorized) postLeashInternal(PendingActionUser, PendingPassTarget);
        }
        else if (PendingAction == "set_length") {
            allowed_acl = ALLOWED_ACL_SETTINGS;
            authorized = inAllowedList(acl_level, allowed_acl);
            if (authorized) setLengthInternal((integer)((string)PendingPassTarget));
        }
        else if (PendingAction == "toggle_turn") {
            allowed_acl = ALLOWED_ACL_SETTINGS;
            authorized = inAllowedList(acl_level, allowed_acl);
            if (authorized) toggleTurnInternal();
        }

        if (!authorized) {
            denyAccess(PendingActionUser, "insufficient permissions", PendingAction, acl_level);
        }
    }
    
    // Clear pending state
    PendingActionUser = NULL_KEY;
    PendingAction = "";
    PendingPassTarget = NULL_KEY;
    PendingIsOffer = FALSE;
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

// ===== DS HOLDER PROTOCOL (IMPROVED STATE MACHINE) =====
beginHolderHandshake(key user) {
    // Improved randomness for session ID using multiple entropy sources
    integer key_entropy = (integer)("0x" + llGetSubString((string)llGetOwner(), 0, 7));
    HolderSession = (integer)(llFrand(999999.0) +
                              (now() % 1000000) +
                              (key_entropy % 1000));
    HolderState = HOLDER_STATE_DS_PHASE;
    HolderPhaseStart = now();

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
    llRegionSay(-192837465, msg);
    
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
    
    float elapsed = (float)(now() - HolderPhaseStart);
    
    if (HolderState == HOLDER_STATE_DS_PHASE) {
        if (elapsed >= DS_PHASE_DURATION) {
            // Transition to OC phase
            logd("Holder handshake Phase 2 (OC, 2s)");
            HolderState = HOLDER_STATE_OC_PHASE;
            HolderPhaseStart = now();
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

// ===== OFFSIM DETECTION & AUTO-RECLIP (IMPROVED) =====
checkLeasherPresence() {
    if (!Leashed || Leasher == NULL_KEY) return;
    
    integer now_time = now();
    
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
    if (ReclipScheduled == 0 || now() < ReclipScheduled) return;
    
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
        ReclipScheduled = now() + 2;
    }
}

// ===== SETTINGS PERSISTENCE =====
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

// ===== STATE BROADCAST =====
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

// ===== LEASH ACTIONS (INTERNAL - CALLED AFTER ACL VERIFICATION) =====
grabLeashInternal(key user) {
    if (Leashed) {
        llRegionSayTo(user, 0, "Already leashed to " + llKey2Name(Leasher));
        return;
    }

    Leashed = TRUE;
    Leasher = user;
    LastLeasher = user;
    LeashMode = MODE_AVATAR;  // Standard avatar leashing
    LeashTarget = NULL_KEY;   // No special target for avatar mode
    CoffleTargetAvatar = NULL_KEY;  // Not used in avatar mode
    persistLeashState(TRUE, user);
    beginHolderHandshake(user);

    // Enable Lockmeister for this authorized controller
    AuthorizedLmController = user;
    setLockmeisterState(TRUE, user);

    startFollow();
    notifyLeashAction(user, "Leash grabbed", "by " + llKey2Name(user));
    broadcastState();
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

    notifyLeashTransfer(old_leasher, new_leasher, "passed");
    broadcastState();
}

coffleLeashInternal(key user, key target_collar) {
    if (Leashed) {
        llRegionSayTo(user, 0, "Already leashed. Unclip first.");
        return;
    }

    // Verify target exists and get its owner
    // NOTE: OBJECT_OWNER returns the avatar wearing the collar, not the ACL owner (Dom)
    // This validation allows coffling between different subs with the same Dom
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
    CoffleTargetAvatar = collar_owner;  // Store the avatar wearing the target collar
    persistLeashState(TRUE, user);

    // Start particles to target collar
    setParticlesState(TRUE, target_collar);

    // Enable follow mechanics to the target avatar (the one wearing the collar)
    startFollow();

    string target_name = llList2String(details, 1);
    notifyLeashAction(user, "Coffled to " + llKey2Name(collar_owner), target_name);
    broadcastState();
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
    CoffleTargetAvatar = NULL_KEY;  // Not used for post mode
    persistLeashState(TRUE, user);

    // Start particles to post object
    setParticlesState(TRUE, post_object);

    // Enable distance enforcement (via follow mechanics)
    startFollow();

    string object_name = llList2String(details, 1);
    notifyLeashAction(user, "Posted to " + object_name, "by " + llKey2Name(user));
    broadcastState();
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

// ===== FOLLOW MECHANICS (IMPROVED TURN THROTTLING) =====
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
                updateParticlesTarget(Leasher);
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

// ===== EVENT HANDLERS =====
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
        logd("Leash kmod ready (v2.0 MULTI-MODE)");
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
                        integer now_time = now();
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
                handleAclResult(msg, id);
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
        if (channel == -192837465) {
            handleHolderResponseDs(msg);
        }
        else if (channel == -8888) {
            handleHolderResponseOc(id, msg);
        }
    }
}
