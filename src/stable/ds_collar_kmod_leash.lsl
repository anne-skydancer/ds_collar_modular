/* =============================================================================
   DS Collar - Leash Kernel Module (v2.0)
   
   ROLE: Leashing engine - provides leash services to plugins
   
   FEATURES:
   - Grab/Release/Pass/Yank leash actions
   - Multi-protocol: DS Holder, Avatar Direct, Lockmeister
   - Offsim detection with auto-release (6s grace)
   - Auto-reclip when leasher returns
   - RLV follow + MoveToTarget enforcement
   - Turn-to-face support
   
   ARCHITECTURE:
   - Kernel module (infrastructure, not a plugin)
   - Receives leash_action commands from plugin_leash UI
   - Sends leash_state updates to plugin_leash UI
   - Integrates with particles module for visual rendering
   - Uses settings module for persistence
   
   CHANNELS:
   - 800: Settings persistence
   - 900: UI/command bus
   - -192837465: DS Holder protocol
   ============================================================================= */

integer DEBUG = FALSE;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

string PLUGIN_CONTEXT = "core_leash";
string PLUGIN_LABEL = "Leash";

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

// Follow mechanics
integer FollowActive = FALSE;
vector LastTargetPos = ZERO_VECTOR;
float LastDistance = -1.0;
integer ControlsOk = FALSE;

// DS Holder protocol
integer LEASH_HOLDER_CHAN = -192837465;
integer HolderListen = 0;
key HolderTarget = NULL_KEY;
integer HolderSession = 0;
integer HolderWaiting = FALSE;
integer HolderDeadline = 0;
integer HOLDER_WAIT_SEC = 8;

// Offsim detection & auto-reclip
integer OffsimDetected = FALSE;
integer OffsimStartTime = 0;
float OFFSIM_GRACE = 6.0;
integer ReclipScheduled = 0;
key LastLeasher = NULL_KEY;

// Timers
float FOLLOW_TICK = 0.5;

// ===== HELPERS =====
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[LEASH] " + msg);
    return FALSE;
}
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
integer now() {
    return llGetUnixTime();
}

// ===== DS HOLDER PROTOCOL =====
open_holder_listen() {
    if (HolderListen == 0) {
        HolderListen = llListen(LEASH_HOLDER_CHAN, "", NULL_KEY, "");
logd("Holder listen opened");
    }
}
close_holder_listen() {
    if (HolderListen != 0) {
        llListenRemove(HolderListen);
        HolderListen = 0;
logd("Holder listen closed");
    }
}
begin_holder_handshake(key user) {
    HolderSession = (integer)llFrand(2147483000.0);
    HolderWaiting = TRUE;
    HolderDeadline = now() + HOLDER_WAIT_SEC;
    open_holder_listen();
    string msg = llList2Json(JSON_OBJECT, [
        "type", "leash_req",
        "wearer", (string)llGetOwner(),
        "collar", (string)llGetKey(),
        "controller", (string)user,
        "session", (string)HolderSession,
        "origin", "leashpoint"
    ]);
    llRegionSay(LEASH_HOLDER_CHAN, msg);
logd("Holder handshake started");
}
handle_holder_response(string msg) {
    if (!HolderWaiting) return;
    if (llJsonGetValue(msg, ["type"]) != "leash_target") return;
    if (llJsonGetValue(msg, ["ok"]) != "1") return;
    integer session = (integer)llJsonGetValue(msg, ["session"]);
    if (session != HolderSession) return;
    HolderTarget = (key)llJsonGetValue(msg, ["holder"]);
    string holder_name = llJsonGetValue(msg, ["name"]);
logd("Holder response: target=" + (string)HolderTarget + " name=" + holder_name);
    HolderWaiting = FALSE;
    HolderDeadline = 0;
    close_holder_listen();
    string particles_msg = llList2Json(JSON_OBJECT, [
        "type", "particles_start",
        "source", PLUGIN_CONTEXT,
        "target", (string)HolderTarget,
        "style", "chain"
    ]);
    llMessageLinked(LINK_SET, UI_BUS, particles_msg, NULL_KEY);
logd("Holder mode activated");
}

// ===== OFFSIM DETECTION & AUTO-RECLIP =====
check_leasher_presence() {
    if (!Leashed || Leasher == NULL_KEY) return;
    integer present = (llGetAgentInfo(Leasher) != 0) || (HolderTarget != NULL_KEY && llGetListLength(llGetObjectDetails(HolderTarget, [OBJECT_POS])) > 0);
    if (!present) {
        if (!OffsimDetected) { OffsimDetected = TRUE; OffsimStartTime = now(); logd("Offsim grace started"); }
        else if ((float)(now() - OffsimStartTime) >= OFFSIM_GRACE) { LastLeasher = Leasher; auto_release_offsim(); ReclipScheduled = now() + 2; }
    } else if (OffsimDetected) { OffsimDetected = FALSE; OffsimStartTime = 0; logd("Leasher returned"); }
}
auto_release_offsim() {
    Leashed = FALSE; Leasher = NULL_KEY; persist_leash_state(FALSE, NULL_KEY);
    HolderTarget = NULL_KEY; HolderWaiting = FALSE; HolderDeadline = 0; close_holder_listen();
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, ["type", "particles_stop", "source", PLUGIN_CONTEXT]), NULL_KEY);
    stop_follow(); llOwnerSay("Auto-released (offsim)"); 
    broadcast_state(); // Notify config
logd("Auto-released");
}
check_auto_reclip() {
    if (ReclipScheduled == 0 || now() < ReclipScheduled) return;
    if (LastLeasher != NULL_KEY && llGetAgentInfo(LastLeasher) != 0) { grab_leash(LastLeasher); llOwnerSay("Auto-reattached"); }
    ReclipScheduled = now() + 2;
}

// ===== PLUGIN REGISTRATION =====
// Note: As a kmod, we don't register with the kernel
// The plugin_leash UI registers as the user-facing feature

// ===== SETTINGS PERSISTENCE =====
persist_setting(string setting_key, string value) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, ["type", "set", "key", setting_key, "value", value]), NULL_KEY);
}
persist_leash_state(integer leashed, key leasher) {
    persist_setting(KEY_LEASHED, (string)leashed);
    persist_setting(KEY_LEASHER, (string)leasher);
}
persist_length(integer length) { persist_setting(KEY_LEASH_LENGTH, (string)length); }
persist_turnto(integer turnto) { persist_setting(KEY_LEASH_TURNTO, (string)turnto); }

apply_settings_sync(string msg) {
    if (!json_has(msg, ["settings"])) return;
    string settings_json = llJsonGetValue(msg, ["settings"]);
    if (json_has(settings_json, [KEY_LEASHED])) {
        Leashed = (integer)llJsonGetValue(settings_json, [KEY_LEASHED]);
    }
    if (json_has(settings_json, [KEY_LEASHER])) {
        Leasher = (key)llJsonGetValue(settings_json, [KEY_LEASHER]);
    }
    if (json_has(settings_json, [KEY_LEASH_LENGTH])) {
        LeashLength = (integer)llJsonGetValue(settings_json, [KEY_LEASH_LENGTH]);
        if (LeashLength < 1) LeashLength = 1;
        if (LeashLength > 20) LeashLength = 20;
    }
    if (json_has(settings_json, [KEY_LEASH_TURNTO])) {
        TurnToFace = (integer)llJsonGetValue(settings_json, [KEY_LEASH_TURNTO]);
    }
logd("Settings loaded");
}
apply_settings_delta(string msg) {
    if (json_has(msg, ["key"]) && json_has(msg, ["value"])) {
        string setting_key = llJsonGetValue(msg, ["key"]);
        string value = llJsonGetValue(msg, ["value"]);
        if (setting_key == KEY_LEASHED) Leashed = (integer)value;
        else if (setting_key == KEY_LEASHER) Leasher = (key)value;
        else if (setting_key == KEY_LEASH_LENGTH) {
            LeashLength = (integer)value;
            if (LeashLength < 1) LeashLength = 1;
            if (LeashLength > 20) LeashLength = 20;
        }
        else if (setting_key == KEY_LEASH_TURNTO) TurnToFace = (integer)value;
    }
}

// ===== STATE BROADCAST =====
// Notify config plugin of current state
broadcast_state() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "leash_state",
        "leashed", (string)Leashed,
        "leasher", (string)Leasher,
        "length", (string)LeashLength,
        "turnto", (string)TurnToFace
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

// ===== LEASH ACTIONS =====
grab_leash(key user) {
    if (Leashed) {
        llRegionSayTo(user, 0, "Already leashed to " + llKey2Name(Leasher));
        return;
    }
    Leashed = TRUE; Leasher = user; LastLeasher = user;
    persist_leash_state(TRUE, user);
    begin_holder_handshake(user);
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, ["type", "lm_enable", "controller", (string)user]), NULL_KEY);
    start_follow();
    llRegionSayTo(user, 0, "Leash grabbed.");
    llOwnerSay("Leashed by " + llKey2Name(user));
    broadcast_state();
logd("Grabbed by " + llKey2Name(user));
}
release_leash(key user) {
    if (!Leashed) {
        llRegionSayTo(user, 0, "Not currently leashed.");
        return;
    }
    if (user != Leasher) {
        llRegionSayTo(user, 0, "Only " + llKey2Name(Leasher) + " can release the leash.");
        return;
    }
    key old_leasher = Leasher;
    Leashed = FALSE; Leasher = NULL_KEY;
    persist_leash_state(FALSE, NULL_KEY);
    HolderTarget = NULL_KEY; HolderWaiting = FALSE; HolderDeadline = 0; close_holder_listen();
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, ["type", "lm_disable"]), NULL_KEY);
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, ["type", "particles_stop", "source", PLUGIN_CONTEXT]), NULL_KEY);
    stop_follow();
    llRegionSayTo(user, 0, "Leash released.");
    llOwnerSay("Released by " + llKey2Name(old_leasher));
    broadcast_state();
logd("Released by " + llKey2Name(user));
}
pass_leash(key new_leasher) {
    if (!Leashed) return;
    key old_leasher = Leasher;
    Leasher = new_leasher; LastLeasher = new_leasher;
    persist_leash_state(TRUE, new_leasher);
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, ["type", "particles_update", "target", (string)new_leasher]), NULL_KEY);
    llRegionSayTo(old_leasher, 0, "Leash passed to " + llKey2Name(new_leasher));
    llRegionSayTo(new_leasher, 0, "Leash received from " + llKey2Name(old_leasher));
    llOwnerSay("Leash passed to " + llKey2Name(new_leasher));
    broadcast_state();
logd("Passed to " + llKey2Name(new_leasher));
}
yank_to_leasher() {
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

// ===== FOLLOW MECHANICS =====
start_follow() {
    if (!Leashed || Leasher == NULL_KEY) return;
    FollowActive = TRUE;
    llOwnerSay("@follow:" + (string)Leasher + "=force");
    llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
logd("Follow started");
}
stop_follow() {
    FollowActive = FALSE;
    llOwnerSay("@follow=clear");
    llStopMoveToTarget();
    LastTargetPos = ZERO_VECTOR;
    LastDistance = -1.0;
logd("Follow stopped");
}
turn_to_leasher() {
    if (!TurnToFace || !Leashed || Leasher == NULL_KEY) return;
    list details = llGetObjectDetails(Leasher, [OBJECT_POS]);
    if (llGetListLength(details) == 0) return;
    vector leasher_pos = llList2Vector(details, 0);
    vector wearer_pos = llGetRootPosition();
    vector direction = llVecNorm(leasher_pos - wearer_pos);
    float angle = llAtan2(direction.y, direction.x);
    llOwnerSay("@setrot:" + (string)angle + "=force");
}
follow_tick() {
    if (!FollowActive || !Leashed || Leasher == NULL_KEY) return;
    vector leasher_pos;
    if (HolderTarget != NULL_KEY) {
        list details = llGetObjectDetails(HolderTarget, [OBJECT_POS]);
        if (llGetListLength(details) == 0) {
            HolderTarget = NULL_KEY;
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, ["type", "particles_update", "target", (string)Leasher]), NULL_KEY);
            return;
        }
        leasher_pos = llList2Vector(details, 0);
    }
    else {
        list details = llGetObjectDetails(Leasher, [OBJECT_POS]);
        if (llGetListLength(details) == 0) return;
        leasher_pos = llList2Vector(details, 0);
    }
    vector wearer_pos = llGetRootPosition();
    float distance = llVecDist(wearer_pos, leasher_pos);
    if (ControlsOk && distance > (float)LeashLength) {
        vector target_pos = leasher_pos + llVecNorm(wearer_pos - leasher_pos) * (float)LeashLength * 0.98;
        if (llVecMag(target_pos - LastTargetPos) > 0.2) {
            llMoveToTarget(target_pos, 0.5);
            LastTargetPos = target_pos;
        }
        if (TurnToFace) turn_to_leasher();
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
        close_holder_listen();
        HolderTarget = NULL_KEY;
        HolderWaiting = FALSE;
        HolderDeadline = 0;
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, ["type", "settings_get"]), NULL_KEY);
        llSetTimerEvent(FOLLOW_TICK);
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
logd("Leash kmod ready");
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
        if (num == UI_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            // Commands from config plugin
            if (msg_type == "leash_action") {
                if (!json_has(msg, ["action"])) return;
                string action = llJsonGetValue(msg, ["action"]);
                key user = id;
                if (action == "grab") grab_leash(user);
                else if (action == "release") release_leash(user);
                else if (action == "pass") {
                    if (json_has(msg, ["target"])) pass_leash((key)llJsonGetValue(msg, ["target"]));
                }
                else if (action == "yank") yank_to_leasher();
                else if (action == "set_length") {
                    if (json_has(msg, ["length"])) {
                        LeashLength = (integer)llJsonGetValue(msg, ["length"]);
                        if (LeashLength < 1) LeashLength = 1;
                        if (LeashLength > 20) LeashLength = 20;
                        persist_length(LeashLength);
                        broadcast_state();
                    }
                }
                else if (action == "toggle_turn") {
                    TurnToFace = !TurnToFace;
                    if (!TurnToFace) llOwnerSay("@setrot=clear");
                    persist_turnto(TurnToFace);
                    broadcast_state();
                }
                else if (action == "query_state") {
                    broadcast_state();
                }
                return;
            }
            // Lockmeister notifications from particles
            if (msg_type == "lm_grabbed") {
                if (!json_has(msg, ["controller"])) return;
                key controller = (key)llJsonGetValue(msg, ["controller"]);
                if (!Leashed) {
                    Leashed = TRUE; Leasher = controller; LastLeasher = controller;
                    persist_leash_state(TRUE, controller);
                    start_follow();
                    llOwnerSay("Leashed by " + llKey2Name(controller) + " (Lockmeister)");
                    broadcast_state();
logd("Lockmeister grab from " + llKey2Name(controller));
                }
                return;
            }
            if (msg_type == "lm_released") {
                if (Leashed) {
                    key old_leasher = Leasher;
                    Leashed = FALSE; Leasher = NULL_KEY;
                    persist_leash_state(FALSE, NULL_KEY);
                    stop_follow();
                    llOwnerSay("Released by " + llKey2Name(old_leasher) + " (Lockmeister)");
                    broadcast_state();
logd("Lockmeister release");
                }
                return;
            }
            return;
        }
        if (num == SETTINGS_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == "settings_sync") apply_settings_sync(msg);
            else if (msg_type == "settings_delta") apply_settings_delta(msg);
            return;
        }
    }
    timer() {
        if (HolderWaiting && now() >= HolderDeadline) {
logd("Holder timeout - using avatar direct mode");
            HolderWaiting = FALSE;
            HolderDeadline = 0;
            close_holder_listen();
            if (Leasher != NULL_KEY) {
                llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, ["type", "particles_start", "source", PLUGIN_CONTEXT, "target", (string)Leasher, "style", "chain"]), NULL_KEY);
            }
        }
        if (Leashed) check_leasher_presence();
        if (!Leashed && ReclipScheduled != 0) check_auto_reclip();
        if (FollowActive && Leashed) follow_tick();
    }
    listen(integer channel, string name, key id, string msg) {
        if (channel == LEASH_HOLDER_CHAN) {
            handle_holder_response(msg);
        }
    }
}
