/*--------------------
MODULE: kmod_leash.lsl
VERSION: 1.10
REVISION: 6
PURPOSE: Leashing engine providing leash services to plugins
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 6: Namespace pass — align all cross-module strings with the
  dev bus vocabulary (particles.*, auth.*, settings.*, sos.*, plugin.leash.*,
  kernel-none). PLUGIN_CONTEXT becomes "ui.core.leash", LSD policy key
  moves to "acl.policycontext:", LSD setting keys move to "leash.*".
  External native holder protocol moves to "plugin.leash.request/target".
  No kernel-lifecycle integration added (intentional; see README).
- v1.1 rev 5: Add force_release action for maintenance emergency clear.
  "Clear Leash" in the maintenance plugin now sends force_release instead
  of release, which is authorized if the requesting user is the wearer
  OR has ACL >= 3. Prevents bad actors who leash a public-access collar
  from blocking the wearer's own emergency clear, and also stops stray
  leash particles from persisting indefinitely.
- v1.1 rev 4: Fixed yank anchoring and stiff walking. yankToLeasher now
  pairs llMoveToTarget with llTarget so an at_target event releases the
  physics hold the moment the wearer arrives, instead of leaving them
  glued to the leasher's exact position forever. followTick now stops
  the move target unconditionally when in range (not just on
  out-of-range -> in-range transitions), pulls to 0.85 * length with a
  gentler tau (1.0), and runs at 1.0s instead of 2.0s for responsiveness.
  Offsim/auto-reclip throttle rebalanced to keep its prior ~4s cadence.
- v1.1 rev 3: Reject native-protocol holder responses from objects that are
  not worn by the leasher. beginHolderHandshake() broadcasts via
  llRegionSay on LEASH_CHAN_NATIVE so any in-world native-compatible holder
  could reply with its own UUID, hijacking the leash and pulling
  particles to a random world prim instead of the avatar that just
  accepted an offer. handleHolderResponseNative() now requires the
  responding object to be an attachment owned by the leasher; otherwise
  the response is dropped and the handshake falls through to OC and
  finally to direct-to-avatar attachment.
- v1.1 rev 2: Read settings from LSD instead of kv_json broadcast. Remove
  applySettingsDelta; both sync and delta call parameterless applySettingsSync.
- v1.1 rev 1: Replaced hardcoded ALLOWED_ACL_* lists and inAllowedList() with
  LSD policy reads via policy_allows(). Action permissions now read from the
  same policy:core_leash LSD key that plugin_leash declares.
- v1.1 rev 0: Version bump for LSD policy architecture. No functional changes to this module.
--------------------*/

integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* -------------------- PROTOCOL CONSTANTS - Moved to top for easy maintenance -------------------- */

// Lockmeister/OpenCollar channel
integer LEASH_CHAN_LM = -8888;
integer LEASH_CHAN_NATIVE = -192837465;

string PLUGIN_CONTEXT = "ui.core.leash";

// Policy button labels (must match plugin_leash policy CSV entries)
string POL_CLIP     = "Clip";
string POL_TAKE     = "Take";
string POL_UNCLIP   = "Unclip";
string POL_PASS     = "Pass";
string POL_OFFER    = "Offer";
string POL_COFFLE   = "Coffle";
string POL_POST     = "Post";
string POL_SETTINGS = "Settings";

// Leash mode constants
integer MODE_AVATAR = 0;  // Standard leash to avatar
integer MODE_COFFLE = 1;  // Collar-to-collar leashpoint connection
integer MODE_POST = 2;    // Posted to a static object

// Settings keys
string KEY_LEASHED = "leash.leashedavatar";
string KEY_LEASHER = "leash.leasherkey";
string KEY_LEASH_LENGTH = "leash.length";
string KEY_LEASH_TURNTO = "leash.turnto";

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
integer TickCount = 0;

// Turn-to-face throttling (NEW)
float LastTurnAngle = -999.0;
float TURN_THRESHOLD = 0.1;  // ~5.7 degrees

// Holder protocol state machine (IMPROVED)
integer HOLDER_STATE_IDLE = 0;
integer HOLDER_STATE_NATIVE_PHASE = 1;
integer HOLDER_STATE_OC_PHASE = 2;
integer HOLDER_STATE_COMPLETE = 4;

integer HolderState = 0;
integer HolderPhaseStart = 0;
integer HolderListen = 0;
integer HolderListenOC = 0;
key HolderTarget = NULL_KEY;
integer HolderSession = 0;
float NATIVE_PHASE_DURATION = 2.0;   // 2 seconds for native
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

// Yank arrival detection (rev 4): llTarget handle so at_target can release
// the physics hold the moment the wearer reaches the leasher.
integer YankTargetHandle = 0;

// Timers
float FOLLOW_TICK = 1.0;

/* -------------------- HELPERS -------------------- */

string jsonGet(string j, string k, string default_val) {
    string v = llJsonGetValue(j, [k]);
    if (v == JSON_INVALID) return default_val;
    return v;
}
integer now() {
    return llGetUnixTime();
}
// Check if a button label is allowed at the given ACL level via LSD policy
integer policy_allows(string btn_label, integer acl_level) {
    string policy = llLinksetDataRead("acl.policycontext:" + PLUGIN_CONTEXT);
    if (policy == "") return FALSE;
    string csv = llJsonGetValue(policy, [(string)acl_level]);
    if (csv == JSON_INVALID) return FALSE;
    return (llListFindList(llCSV2List(csv), [btn_label]) != -1);
}
denyAccess(key user, string reason) {
    llRegionSayTo(user, 0, "Access denied: " + reason);
}

/* -------------------- PROTOCOL MESSAGE HELPERS - State-based delta pattern -------------------- */
// These define JSON contracts with other modules/objects

/* -------------------- LOCKMEISTER PROTOCOL -------------------- */
setLockmeisterState(integer enabled, key controller) {
    string msg;
    if (enabled) {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles.lmenable",
            "controller", (string)controller
        ]);
    } else {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles.lmdisable"
        ]);
    }
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- PARTICLES PROTOCOL -------------------- */
setParticlesState(integer active, key target) {
    string msg;
    if (active) {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles.start",
            "source", PLUGIN_CONTEXT,
            "target", (string)target,
            "style", "chain"
        ]);
    } else {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles.stop",
            "source", PLUGIN_CONTEXT
        ]);
    }
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

updateParticlesTarget(key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "particles.update",
        "target", (string)target
    ]), NULL_KEY);
}

/* -------------------- OFFER PROTOCOL -------------------- */
sendOfferPending(key target, key originator) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.offerpending",
        "target", (string)target,
        "originator", (string)originator
    ]), NULL_KEY);
}

/* -------------------- STATE MANAGEMENT HELPERS -------------------- */

// Helper to set common leash state
setLeashState(key user, integer mode, key target, key coffle_target) {
    Leashed = TRUE;
    Leasher = user;
    LastLeasher = user;
    LeashMode = mode;
    LeashTarget = target;
    CoffleTargetAvatar = coffle_target;
    persistLeashState(TRUE, user);
    broadcastState();
}

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
}

// For multi-party notifications (like pass)
notifyLeashTransfer(key from_user, key to_user, string action) {
    llRegionSayTo(from_user, 0, "Leash " + action + " to " + llKey2Name(to_user));
    llRegionSayTo(to_user, 0, "Leash received from " + llKey2Name(from_user));
    llOwnerSay("Leash " + action + " to " + llKey2Name(to_user) + " by " + llKey2Name(from_user));
}

/* -------------------- ACL VERIFICATION SYSTEM (NEW) -------------------- */
requestAclForAction(key user, string action, key pass_target) {
    AclPending = TRUE;
    PendingActionUser = user;
    PendingAction = action;
    PendingPassTarget = pass_target;
    
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "auth.aclquery",
        "avatar", (string)user
    ]), user);
    
}

handleAclResult(string msg) {
    if (!AclPending) return;
    if (llJsonGetValue(msg, ["avatar"]) == JSON_INVALID || llJsonGetValue(msg, ["level"]) == JSON_INVALID) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != PendingActionUser) return;
    
    integer acl_level = (integer)llJsonGetValue(msg, ["level"]);
    AclPending = FALSE;
    
    
    // Execute pending action with ACL verification

    // Release: current leasher can always release (safety); otherwise policy-gated
    if (PendingAction == "release") {
        if (PendingActionUser == Leasher || policy_allows(POL_UNCLIP, acl_level)) {
            releaseLeashInternal(PendingActionUser);
        } else {
            denyAccess(PendingActionUser, "only leasher or authorized users can release");
        }
    }
    // Force-release: maintenance emergency clear — wearer always allowed; trustees/owners allowed.
    // Does NOT require the user to be the current leasher, so it clears stray leashes
    // from bad actors (e.g., random public users who clip a public-access collar).
    else if (PendingAction == "force_release") {
        if (PendingActionUser == llGetOwner() || acl_level >= 3) {
            releaseLeashInternal(PendingActionUser);
        } else {
            denyAccess(PendingActionUser, "only wearer or authorized users can force-clear leash");
        }
    }
    // Special case: pass (current leasher OR policy-allowed can pass, then verify target)
    else if (PendingAction == "pass") {
        if (PendingActionUser == Leasher || policy_allows(POL_PASS, acl_level)) {
            requestAclForPassTarget(PendingPassTarget);
            return;  // Don't clear pending state yet
        } else {
            denyAccess(PendingActionUser, "insufficient permissions to pass leash");
        }
    }
    // Special case: offer (policy-allowed, when NOT currently leashed, then verify target)
    else if (PendingAction == "offer") {
        if (policy_allows(POL_OFFER, acl_level) && !Leashed) {
            PendingIsOffer = TRUE;
            requestAclForPassTarget(PendingPassTarget);
            return;  // Don't clear pending state yet
        } else if (Leashed) {
            llRegionSayTo(PendingActionUser, 0, "Cannot offer leash: already leashed.");
        } else {
            denyAccess(PendingActionUser, "insufficient permissions to offer leash");
        }
    }
    // Special case: pass_target_check (verifying the target's ACL for pass/offer)
    else if (PendingAction == "pass_target_check") {
        // This is the target verification for pass/offer action
        // Target must be level 1+ (public or higher) to receive leash


        if (acl_level >= 1) {
            // Offer sends message to plugin for dialog, pass directly transfers
            if (PendingIsOffer) {
                // Send offer_pending to plugin - plugin will handle dialog
                sendOfferPending(PendingPassTarget, PendingPassOriginalUser);
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
        }

        // Clear pass-specific state
        PendingPassOriginalUser = NULL_KEY;
        PendingIsOffer = FALSE;
    }
    // Standard ACL pattern for simple actions — read from LSD policy
    else {
        string btn_label = "";

        if (PendingAction == "grab") {
            // "grab" is "Take" (take-over) when already leashed, "Clip" otherwise
            if (Leashed) btn_label = POL_TAKE;
            else btn_label = POL_CLIP;
        }
        else if (PendingAction == "coffle") btn_label = POL_COFFLE;
        else if (PendingAction == "post") btn_label = POL_POST;
        else if (PendingAction == "set_length" || PendingAction == "toggle_turn") btn_label = POL_SETTINGS;

        if (btn_label != "" && policy_allows(btn_label, acl_level)) {
            if (PendingAction == "grab") grabLeashInternal(PendingActionUser, acl_level);
            else if (PendingAction == "coffle") coffleLeashInternal(PendingActionUser, PendingPassTarget);
            else if (PendingAction == "post") postLeashInternal(PendingActionUser, PendingPassTarget);
            else if (PendingAction == "set_length") setLengthInternal((integer)((string)PendingPassTarget));
            else if (PendingAction == "toggle_turn") toggleTurnInternal();
        } else {
            denyAccess(PendingActionUser, "insufficient permissions");
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
        "type", "auth.aclquery",
        "avatar", (string)target
    ]), target);
    
}

/* -------------------- NATIVE HOLDER PROTOCOL (IMPROVED STATE MACHINE) -------------------- */
beginHolderHandshake(key user) {
    // Improved randomness for session ID using multiple entropy sources
    HolderSession = (integer)llFrand(9.0E06);
    HolderState = HOLDER_STATE_NATIVE_PHASE;
    HolderPhaseStart = now();

    // Phase 1: native only
    if (HolderListen == 0) {
        HolderListen = llListen(LEASH_CHAN_NATIVE, "", NULL_KEY, "");
    }
    
    // Send native JSON format on native channel
    string msg = llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.request",
        "wearer", (string)llGetOwner(),
        "collar", (string)llGetKey(),
        "controller", (string)user,
        "session", (string)HolderSession,
        "origin", "leashpoint"
    ]);
    llRegionSay(LEASH_CHAN_NATIVE, msg);
    
}

handleHolderResponseNative(string msg) {
    if (HolderState != HOLDER_STATE_NATIVE_PHASE && HolderState != HOLDER_STATE_OC_PHASE) return;
    if (llJsonGetValue(msg, ["type"]) != "plugin.leash.target") return;
    if (llJsonGetValue(msg, ["ok"]) != "1") return;
    integer session = (integer)llJsonGetValue(msg, ["session"]);
    if (session != HolderSession) return;

    key candidate_holder = (key)llJsonGetValue(msg, ["holder"]);
    if (candidate_holder == NULL_KEY) return;

    // Reject in-world holders. The native request is broadcast via llRegionSay,
    // so any native-compatible holder script in the region will reply — including
    // rezzed-in-world props. Only accept holders that are currently worn as
    // an attachment by the leasher; otherwise the leash visually anchors to
    // a random prim instead of the avatar.
    list odetails = llGetObjectDetails(candidate_holder, [OBJECT_ATTACHED_POINT, OBJECT_OWNER]);
    if (llGetListLength(odetails) < 2) return;
    integer attached_point = llList2Integer(odetails, 0);
    key holder_owner       = llList2Key(odetails, 1);
    if (attached_point == 0) return;          // not worn → reject
    if (holder_owner != Leasher) return;      // worn by someone else → reject

    HolderTarget = candidate_holder;

    HolderState = HOLDER_STATE_COMPLETE;
    closeAllHolderListens();

    setParticlesState(TRUE, HolderTarget);
}

handleHolderResponseOc(key holder_prim, string msg) {
    if (HolderState != HOLDER_STATE_OC_PHASE) return;
    // CRITICAL: Must match the UUID we sent in the ping (Leasher, not wearer)
    string expected = (string)Leasher + "handle ok";
    if (msg != expected) return;
    
    HolderTarget = holder_prim;


    HolderState = HOLDER_STATE_COMPLETE;
    closeAllHolderListens();

    setParticlesState(TRUE, HolderTarget);
}

advanceHolderStateMachine() {
    if (HolderState == HOLDER_STATE_IDLE || HolderState == HOLDER_STATE_COMPLETE) return;
    
    float elapsed = (float)(now() - HolderPhaseStart);
    
    if (HolderState == HOLDER_STATE_NATIVE_PHASE) {
        if (elapsed >= NATIVE_PHASE_DURATION) {
            // Transition to OC phase
            HolderState = HOLDER_STATE_OC_PHASE;
            HolderPhaseStart = now();
            if (HolderListen != 0) {
                llListenRemove(HolderListen);
                HolderListen = 0;
            }
            if (HolderListenOC == 0) {
                HolderListenOC = llListen(LEASH_CHAN_LM, "", NULL_KEY, "");
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
    }
}

autoReleaseOffsim() {
    clearLeashState(FALSE);  // FALSE = don't clear reclip (we want to try reclipping)
    llOwnerSay("Auto-released (offsim)");
}

checkAutoReclip() {
    if (ReclipScheduled == 0 || now() < ReclipScheduled) return;
    
    if (ReclipAttempts >= MAX_RECLIP_ATTEMPTS) {
        ReclipScheduled = 0;
        LastLeasher = NULL_KEY;
        ReclipAttempts = 0;
        return;
    }
    
    if (LastLeasher != NULL_KEY && llGetAgentInfo(LastLeasher) != 0) {
        
        // Request ACL verification before reclip
        requestAclForAction(LastLeasher, "grab", NULL_KEY);
        
        ReclipAttempts = ReclipAttempts + 1;
        ReclipScheduled = now() + 2;
    }
}

/* -------------------- SETTINGS PERSISTENCE -------------------- */
persistSetting(string setting_key, string value) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
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

applySettingsSync() {
    string tmp = llLinksetDataRead(KEY_LEASHED);
    if (tmp != "") Leashed = (integer)tmp;
    tmp = llLinksetDataRead(KEY_LEASHER);
    if (tmp != "") Leasher = (key)tmp;
    tmp = llLinksetDataRead(KEY_LEASH_LENGTH);
    if (tmp != "") LeashLength = clampLeashLength((integer)tmp);
    tmp = llLinksetDataRead(KEY_LEASH_TURNTO);
    if (tmp != "") TurnToFace = (integer)tmp;
}

/* -------------------- STATE BROADCAST -------------------- */
broadcastState() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.state",
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
grabLeashInternal(key user, integer acl_level) {
    if (Leashed) {
        // Allow stealing if requester is Trustee (3) or higher
        if (acl_level >= 3) {
            llRegionSayTo(Leasher, 0, "Leash taken by " + llKey2Name(user));
            // Proceed to take leash (overwrite existing leasher)
        }
        else {
            llRegionSayTo(user, 0, "Already leashed to " + llKey2Name(Leasher));
            return;
        }
    }

    setLeashState(user, MODE_AVATAR, NULL_KEY, NULL_KEY);
    beginHolderHandshake(user);

    // Enable Lockmeister for this authorized controller
    AuthorizedLmController = user;
    setLockmeisterState(TRUE, user);

    startFollow();
    notifyLeashAction(user, "Leash grabbed", "by " + llKey2Name(user));
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
    
    // Reset to avatar mode (if was in coffle/post, revert to standard leashing)
    setLeashState(new_leasher, MODE_AVATAR, NULL_KEY, NULL_KEY);

    // Start holder handshake for new leasher
    beginHolderHandshake(new_leasher);

    // Update Lockmeister authorization
    AuthorizedLmController = new_leasher;
    setLockmeisterState(TRUE, new_leasher);

    notifyLeashTransfer(old_leasher, new_leasher, "passed");
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

    setLeashState(user, MODE_COFFLE, target_collar, collar_owner);

    // Start particles to target collar
    setParticlesState(TRUE, target_collar);

    // Enable follow mechanics to the target avatar (the one wearing the collar)
    startFollow();

    string target_name = llList2String(details, 1);
    notifyLeashAction(user, "Coffled to " + llKey2Name(collar_owner), target_name);
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

    setLeashState(user, MODE_POST, post_object, NULL_KEY);

    // Start particles to post object
    setParticlesState(TRUE, post_object);

    // Enable distance enforcement (via follow mechanics)
    startFollow();

    string object_name = llList2String(details, 1);
    notifyLeashAction(user, "Posted to " + object_name, "by " + llKey2Name(user));
}

yankToLeasher() {
    if (!Leashed || Leasher == NULL_KEY) return;

    list details = llGetObjectDetails(Leasher, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        llOwnerSay("Cannot yank: leasher not in range.");
        return;
    }

    vector leasher_pos = llList2Vector(details, 0);

    if (ControlsOk) {
        // Physics yank: pull hard, but register an llTarget so at_target
        // releases llMoveToTarget the moment the wearer arrives. Without
        // this, the move target persists indefinitely and anchors the
        // wearer to the leasher's exact position.
        if (YankTargetHandle != 0) {
            llTargetRemove(YankTargetHandle);
            YankTargetHandle = 0;
        }
        llMoveToTarget(leasher_pos, 0.3);
        YankTargetHandle = llTarget(leasher_pos, 1.5);
        llOwnerSay("Yanked to " + llKey2Name(Leasher));
        llRegionSayTo(Leasher, 0, llKey2Name(llGetOwner()) + " yanked to you.");
    } else {
        llOwnerSay("Cannot yank: controls not active.");
    }
}

setLengthInternal(integer length) {
    if (length < 1) length = 1;
    if (length > 20) length = 20;
    LeashLength = length;
    persistLength(LeashLength);
    broadcastState();
}

toggleTurnInternal() {
    TurnToFace = !TurnToFace;
    if (!TurnToFace) {
        llOwnerSay("@setrot=clear");
        LastTurnAngle = -999.0;
    }
    persistTurnto(TurnToFace);
    broadcastState();
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
}

stopFollow() {
    FollowActive = FALSE;
    llOwnerSay("@follow=clear");
    llStopMoveToTarget();
    if (YankTargetHandle != 0) {
        llTargetRemove(YankTargetHandle);
        YankTargetHandle = 0;
    }
    LastTargetPos = ZERO_VECTOR;
    LastDistance = -1.0;
    LastTurnAngle = -999.0;
}

turnToTarget(vector target_pos) {
    if (!TurnToFace || !Leashed) return;
    
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
    key target_key = NULL_KEY;

    if (LeashMode == MODE_AVATAR) {
        follow_target = Leasher;
        // Prefer holder if active
        if (HolderTarget != NULL_KEY) {
            target_key = HolderTarget;
        } else {
            target_key = Leasher;
        }
    }
    else if (LeashMode == MODE_COFFLE) {
        follow_target = CoffleTargetAvatar;
        target_key = CoffleTargetAvatar;
    }
    else if (LeashMode == MODE_POST) {
        follow_target = LeashTarget;
        target_key = LeashTarget;
    }

    if (target_key == NULL_KEY) return;

    list details = llGetObjectDetails(target_key, [OBJECT_POS]);
    
    // Handle HolderTarget disappearing (special case for Avatar mode)
    if (llGetListLength(details) == 0) {
        if (LeashMode == MODE_AVATAR && target_key == HolderTarget) {
            HolderTarget = NULL_KEY;
            updateParticlesTarget(Leasher);
            // Fallback to leasher immediately
            target_key = Leasher;
            details = llGetObjectDetails(target_key, [OBJECT_POS]);
        }
    }

    if (llGetListLength(details) == 0) return;
    target_pos = llList2Vector(details, 0);

    vector wearer_pos = llGetRootPosition();
    float distance = llVecDist(wearer_pos, target_pos);

    if (ControlsOk && distance > (float)LeashLength) {
        // Pull to 0.85 * length (not 0.98) so there is slack on arrival
        // and the wearer is not pinned at the leash limit. Gentler tau
        // (1.0) keeps walking in the leashed direction feasible.
        vector pull_pos = target_pos + llVecNorm(wearer_pos - target_pos) * (float)LeashLength * 0.85;
        if (llVecMag(pull_pos - LastTargetPos) > 0.2) {
            llMoveToTarget(pull_pos, 1.0);
            LastTargetPos = pull_pos;
        }
        if (TurnToFace && follow_target != NULL_KEY) {
            turnToTarget(target_pos);
        }
    }
    else {
        // In range: always release the move target. The previous
        // implementation only stopped on out-of-range -> in-range
        // transitions, leaving the wearer pinned by leftover physics
        // (and, after a yank, anchored permanently). Skip the call when
        // a yank is still in flight so we do not cancel its arrival pull.
        if (LastTargetPos != ZERO_VECTOR && YankTargetHandle == 0) {
            llStopMoveToTarget();
            LastTargetPos = ZERO_VECTOR;
        }
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
        
        applySettingsSync();
        llSetTimerEvent(FOLLOW_TICK);
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);

        // Memory diagnostics
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
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        // OPTIMIZATION: Check "type" once at the top (Code Review Fix #3)
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;
        
        if (num == UI_BUS) {
            
            // Commands from config plugin - NOW WITH ACL VERIFICATION
            if (msg_type == "plugin.leash.action") {
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

            // Emergency release from SOS plugin
            if (msg_type == "sos.leashrelease") {
                // Verify sender is owner/wearer to prevent abuse
                if (id == llGetOwner()) {
                    releaseLeashInternal(id);
                }
                return;
            }
            
            // Lockmeister notifications from particles - VERIFY AUTHORIZATION
            if (msg_type == "particles.lmgrabbed") {
                key controller = (key)jsonGet(msg, "controller", (string)NULL_KEY);
                if (controller == NULL_KEY) return;
                
                // Only accept from the controller we initiated the LM handshake for
                if (controller != AuthorizedLmController) {
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
                }
                return;
            }
            
            if (msg_type == "particles.lmreleased") {
                if (Leashed) {
                    key old_leasher = Leasher;
                    Leashed = FALSE;
                    Leasher = NULL_KEY;
                    persistLeashState(FALSE, NULL_KEY);
                    AuthorizedLmController = NULL_KEY;
                    stopFollow();
                    llOwnerSay("Released by " + llKey2Name(old_leasher) + " (Lockmeister)");
                    broadcastState();
                }
                return;
            }
            return;
        }
        
        if (num == AUTH_BUS) {
            if (msg_type == "auth.aclresult") {
                handleAclResult(msg);
            }
            return;
        }
        
        if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                applySettingsSync();
            }
            return;
        }
    }
    
    timer() {
        // Advance holder detection state machine
        advanceHolderStateMachine();
        
        TickCount++;
        // Check for offsim/auto-release (~4s cadence at 1.0s FOLLOW_TICK)
        if (TickCount % 4 == 0) {
            if (Leashed) checkLeasherPresence();
            if (!Leashed && ReclipScheduled != 0) checkAutoReclip();
        }

        // Follow tick
        if (FollowActive && Leashed) followTick();
    }

    at_target(integer tnum, vector target_pos, vector my_pos) {
        // Yank arrival: release the physics hold so the wearer is not
        // anchored to the leasher's exact position after a yank.
        if (tnum == YankTargetHandle) {
            llTargetRemove(YankTargetHandle);
            YankTargetHandle = 0;
            llStopMoveToTarget();
            LastTargetPos = ZERO_VECTOR;
        }
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (channel == LEASH_CHAN_NATIVE) {
            handleHolderResponseNative(msg);
        }
        else if (channel == LEASH_CHAN_LM) {
            handleHolderResponseOc(id, msg);
        }
    }
}
