/*--------------------
PLUGIN: plugin_relay.lsl
VERSION: 1.10
REVISION: 2
PURPOSE: Provide ORG-compliant RLV relay with hardcore mode and safeword hooks
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 2: Namespace internal message type strings (kernel.*, ui.*, settings.*, sos.*).
- v1.1 rev 1: Migrate settings reads from JSON broadcast to direct LSD reads.
  Remove apply_settings_delta(); fold side effects into apply_settings_sync()
  via previous-state comparison. Both settings_sync and settings_delta call
  parameterless apply_settings_sync(). Remove settings_get request; call
  apply_settings_sync() directly from state_entry.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded ACL checks with policy reads via get_policy_buttons()
  and btn_allowed(). Removed PLUGIN_MIN_ACL and min_acl from kernel
  registration message.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_relay";
string PLUGIN_LABEL = "RLV Relay";

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* -------------------- RELAY CONSTANTS -------------------- */
integer RELAY_CHANNEL = -1812221819;
integer RLV_RESP_CHANNEL = 4711;
integer MAX_RELAYS = 5;

integer MODE_OFF = 0;
integer MODE_ON  = 1;
integer MODE_ASK = 2;

integer ASK_TIMEOUT_SEC = 30;  // Wearer has 30 seconds to respond to an ASK dialog

integer SOS_MSG_NUM = 555;  // SOS emergency channel

// ORG relay spec wildcard UUID (accepts commands from any avatar)
key WILDCARD_UUID = "ffffffff-ffff-ffff-ffff-ffffffffffff";

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_RELAY_MODE = "relay.mode";
string KEY_RELAY_HARDCORE = "relay.hardcoremode";

/* -------------------- STATE -------------------- */
// Relay state
integer Mode = MODE_ASK;
integer Hardcore = FALSE;
integer IsAttached = FALSE;
integer RelayListenHandle = 0;
key WearerKey = NULL_KEY;  // Cached owner UUID for performance

// Relays: [obj_key, obj_name, session_chan, restrictions_csv] * N
list Relays = [];

// ASK mode: objects the wearer has accepted this session (not re-prompted)
list SessionTrustedKeys = [];

// ASK mode: one pending prompt at a time
// Batches all commands from the same object until wearer responds
key PendingAskKey = NULL_KEY;
string PendingAskName = "";
integer PendingAskChan = 0;
list PendingAskCommands = [];
integer AskListenHandle = 0;
integer AskDialogChan = 0;

// Session management
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";

// Menu state for object list pagination
integer ObjectListPage = 0;

/* -------------------- HELPERS -------------------- */

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string truncate_name(string name, integer max_len) {
    if (llStringLength(name) <= max_len) return name;
    return llGetSubString(name, 0, max_len - 4) + "...";
}

/* -------------------- LSD POLICY HELPER -------------------- */
list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("acl.policycontext:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

register_self() {
    // Write button visibility policy to LSD (default-deny per ACL level)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "2", "Mode,Bound by...,Safeword",
        "3", "Mode,Bound by...,Unbind,HC OFF,HC ON",
        "4", "Mode,Bound by...,Safeword",
        "5", "Mode,Bound by...,Unbind,HC OFF,HC ON"
    ]));

    // Register with kernel
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- RELAY LISTEN MANAGEMENT -------------------- */

start_relay_listen() {
    if (RelayListenHandle) return;  // Already listening

    RelayListenHandle = llListen(RELAY_CHANNEL, "", NULL_KEY, "");
}

stop_relay_listen() {
    if (RelayListenHandle) {
        llListenRemove(RelayListenHandle);
        RelayListenHandle = 0;
    }
}

update_relay_listen_state() {
    // Only listen if: Mode != OFF AND IsAttached
    if (Mode != MODE_OFF && IsAttached) {
        start_relay_listen();
    }
    else {
        stop_relay_listen();
    }
}

/* -------------------- RELAY MANAGEMENT -------------------- */

integer relay_idx(key obj) {
    return llListFindList(Relays, [obj]);
}

integer add_relay(key obj, string obj_name, integer chan) {
    integer idx = relay_idx(obj);
    if (idx != -1) {
        // Update existing relay
        Relays = llListReplaceList(Relays, [obj, obj_name, chan, ""], idx, idx + 3);
        return TRUE;
    }

    // Check max relays
    if (llGetListLength(Relays) >= (MAX_RELAYS * 4)) {
        return FALSE;
    }

    // Add new relay
    Relays += [obj, obj_name, chan, ""];
    return TRUE;
}

integer remove_relay(key obj) {
    integer idx = relay_idx(obj);
    if (idx != -1) {
        Relays = llDeleteSubList(Relays, idx, idx + 3);
        return TRUE;
    }
    return FALSE;
}

integer store_restriction(key obj, string rlv_cmd) {
    integer idx = relay_idx(obj);
    if (idx != -1) {
        string current_csv = llList2String(Relays, idx + 3);
        if (current_csv == "") {
            current_csv = rlv_cmd;
        }
        else {
            current_csv += "," + rlv_cmd;
        }
        Relays = llListReplaceList(Relays, [current_csv], idx + 3, idx + 3);
        return TRUE;
    }
    return FALSE;
}

clear_restrictions(key obj) {
    integer idx = relay_idx(obj);
    if (idx != -1) {
        // Use @clear per RLV spec - safer than manual reversal
        llOwnerSay("@clear");
        Relays = llListReplaceList(Relays, [""], idx + 3, idx + 3);
    }
}

safeword_clear_all() {
    clear_pending_ask();
    SessionTrustedKeys = [];

    integer relay_count = llGetListLength(Relays);
    integer i = 0;
    while (i < relay_count) {
        key obj = llList2Key(Relays, i);
        clear_restrictions(obj);
        i = i + 4;
    }
    Relays = [];
}

/* -------------------- ASK MODE HELPERS -------------------- */

// Returns TRUE if a command removes restrictions rather than adding them.
// Removal commands are always auto-accepted in ASK mode per ORG spec.
integer is_removal_command(string cmd) {
    if (llGetSubString(cmd, -2, -1) == "=y") return TRUE;
    if (llSubStringIndex(cmd, "@clear") == 0) return TRUE;
    return FALSE;
}

// Opens a direct llDialog prompt to the wearer for an incoming ASK request.
// Uses its own private negative channel — independent of the collar UI dialog system.
show_ask_dialog() {
    AskDialogChan = -1000000 - (integer)llFrand(1000000000.0);
    if (AskListenHandle) llListenRemove(AskListenHandle);
    AskListenHandle = llListen(AskDialogChan, "", WearerKey, "");

    integer cmd_count = llGetListLength(PendingAskCommands);
    string body = "[RELAY] " + PendingAskName +
                  "\nwants to apply " + (string)cmd_count +
                  " restriction(s).\n\nAllow or deny?";

    // Three buttons: Deny left, Allow right, blank centre for spacing
    llDialog(WearerKey, body, ["Deny", " ", "Allow"], AskDialogChan);
    llSetTimerEvent((float)ASK_TIMEOUT_SEC);
}

// Wearer accepted: trust the object for this session and execute pending commands.
accept_ask() {
    if (llListFindList(SessionTrustedKeys, [(string)PendingAskKey]) == -1) {
        SessionTrustedKeys += [(string)PendingAskKey];
    }

    add_relay(PendingAskKey, PendingAskName, PendingAskChan);

    integer i = 0;
    while (i < llGetListLength(PendingAskCommands)) {
        string cmd = llList2String(PendingAskCommands, i);
        store_restriction(PendingAskKey, cmd);
        llOwnerSay(cmd);
        llRegionSayTo(PendingAskKey, PendingAskChan,
            "RLV," + (string)llGetKey() + "," + cmd + ",ok");
        i++;
    }

    llRegionSayTo(WearerKey, 0, "[RELAY] Allowed: " + PendingAskName);
    clear_pending_ask();
}

// Wearer declined or dialog timed out: reject all pending commands with ko.
decline_ask() {
    integer i = 0;
    while (i < llGetListLength(PendingAskCommands)) {
        string cmd = llList2String(PendingAskCommands, i);
        llRegionSayTo(PendingAskKey, PendingAskChan,
            "RLV," + (string)llGetKey() + "," + cmd + ",ko");
        i++;
    }

    llRegionSayTo(WearerKey, 0, "[RELAY] Denied: " + PendingAskName);
    clear_pending_ask();
}

// Cleans up ASK listener, timer, and all pending state.
clear_pending_ask() {
    if (AskListenHandle) {
        llListenRemove(AskListenHandle);
        AskListenHandle = 0;
    }
    llSetTimerEvent(0.0);
    PendingAskKey = NULL_KEY;
    PendingAskName = "";
    PendingAskChan = 0;
    PendingAskCommands = [];
    AskDialogChan = 0;
}

/* -------------------- SETTINGS CONSUMPTION -------------------- */

apply_settings_sync() {
    // Read all settings directly from LSD; compare with previous state
    // and trigger side effects only when values actually change.
    integer prev_mode = Mode;

    Mode = lsd_int(KEY_RELAY_MODE, Mode);
    Hardcore = lsd_int(KEY_RELAY_HARDCORE, Hardcore);

    // Side effect: relay mode changed — update listener state
    if (Mode != prev_mode) {
        update_relay_listen_state();
    }
}

/* -------------------- SETTINGS MODIFICATION -------------------- */

persist_mode(integer new_mode) {
    llLinksetDataWrite(KEY_RELAY_MODE, (string)new_mode);
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_RELAY_MODE,
        "value", (string)new_mode
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

persist_hardcore(integer new_hardcore) {
    llLinksetDataWrite(KEY_RELAY_HARDCORE, (string)new_hardcore);
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_RELAY_HARDCORE,
        "value", (string)new_hardcore
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

/* -------------------- UI / MENU SYSTEM -------------------- */

show_main_menu() {
    SessionId = generate_session_id();

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string mode_str;
    if (!IsAttached) {
        mode_str = "OFF (not worn)";
    }
    else if (Mode == MODE_OFF) {
        mode_str = "OFF";
    }
    else if (Mode == MODE_ASK) {
        mode_str = "ASK";
    }
    else if (Hardcore) {
        mode_str = "HARDCORE";
    }
    else {
        mode_str = "ON";
    }

    integer relay_count = llGetListLength(Relays) / 4;

    string message = "RLV Relay Menu\nMode: " + mode_str + "\nActive Relays: " + (string)relay_count;

    list buttons = ["Back"];

    if (btn_allowed("Mode"))        buttons += ["Mode"];
    if (btn_allowed("Bound by...")) buttons += ["Bound by..."];

    // Safeword only when not hardcore
    if (btn_allowed("Safeword") && !Hardcore) {
        buttons += ["Safeword"];
    }

    if (btn_allowed("Unbind")) buttons += ["Unbind"];

    string buttons_json = llList2Json(JSON_ARRAY, buttons);

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL + " Menu",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

show_mode_menu() {
    SessionId = generate_session_id();

    string mode_str;
    if (!IsAttached) {
        mode_str = "OFF (not worn)";
    }
    else if (Mode == MODE_OFF) {
        mode_str = "OFF";
    }
    else if (Mode == MODE_ASK) {
        mode_str = "ASK";
    }
    else if (Hardcore) {
        mode_str = "HARDCORE";
    }
    else {
        mode_str = "ON";
    }

    string message = "RLV Relay Mode: " + mode_str;

    list buttons = ["Back", "OFF", "ASK", "ON"];

    // Hardcore toggle only available in ON mode, and only if policy allows
    if (Mode == MODE_ON) {
        if (Hardcore) {
            if (btn_allowed("HC OFF")) buttons += ["HC OFF"];
        }
        else {
            if (btn_allowed("HC ON")) buttons += ["HC ON"];
        }
    }

    string buttons_json = llList2Json(JSON_ARRAY, buttons);

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Relay Mode",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

show_object_list() {
    SessionId = generate_session_id();

    integer relay_count = llGetListLength(Relays) / 4;

    string message;
    if (relay_count == 0) {
        message = "No active relays.";
    }
    else {
        message = "Active Relays:\n";
        integer i = 0;
        while (i < relay_count) {
            integer idx = i * 4;
            string obj_name = llList2String(Relays, idx + 1);
            message += (string)(i + 1) + ". " + truncate_name(obj_name, 20) + "\n";
            i++;
        }
    }

    list buttons = ["Back"];
    string buttons_json = llList2Json(JSON_ARRAY, buttons);

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Active Relays",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string button) {
    if (button == "Mode") {
        show_mode_menu();
    }
    else if (button == "Bound by...") {
        show_object_list();
    }
    else if (button == "Safeword") {
        if (btn_allowed("Safeword") && !Hardcore) {
            safeword_clear_all();
            llRegionSayTo(CurrentUser, 0, "[RELAY] Safeword used - all restrictions cleared");
            show_main_menu();
        }
    }
    else if (button == "Unbind") {
        if (btn_allowed("Unbind")) {
            safeword_clear_all();
            llRegionSayTo(CurrentUser, 0, "[RELAY] Unbound - all restrictions cleared");
            show_main_menu();
        }
    }
    else if (button == "OFF") {
        clear_pending_ask();
        SessionTrustedKeys = [];
        Mode = MODE_OFF;
        Hardcore = FALSE;
        persist_mode(MODE_OFF);
        persist_hardcore(FALSE);
        update_relay_listen_state();
        llRegionSayTo(CurrentUser, 0, "[RELAY] Mode set to OFF");
        show_mode_menu();
    }
    else if (button == "ASK") {
        clear_pending_ask();
        Mode = MODE_ASK;
        Hardcore = FALSE;
        persist_mode(MODE_ASK);
        persist_hardcore(FALSE);
        update_relay_listen_state();
        llRegionSayTo(CurrentUser, 0, "[RELAY] Mode set to ASK");
        show_mode_menu();
    }
    else if (button == "ON") {
        clear_pending_ask();
        Mode = MODE_ON;
        persist_mode(MODE_ON);
        update_relay_listen_state();
        if (!Hardcore) {
            llRegionSayTo(CurrentUser, 0, "[RELAY] Mode set to ON");
        }
        show_mode_menu();
    }
    else if (button == "HC ON") {
        if (btn_allowed("HC ON")) {
            Hardcore = TRUE;
            Mode = MODE_ON;
            persist_hardcore(TRUE);
            persist_mode(MODE_ON);
            llRegionSayTo(CurrentUser, 0, "[RELAY] Hardcore mode ENABLED");
            show_mode_menu();
        }
    }
    else if (button == "HC OFF") {
        if (btn_allowed("HC OFF")) {
            Hardcore = FALSE;
            Mode = MODE_ON;
            persist_hardcore(FALSE);
            persist_mode(MODE_ON);
            llRegionSayTo(CurrentUser, 0, "[RELAY] Hardcore mode DISABLED");
            show_mode_menu();
        }
    }
    else if (button == "Back") {
        return_to_root();
    }
    else {
        // Unknown button, reshow menu
        show_main_menu();
    }
}

/* -------------------- NAVIGATION -------------------- */

return_to_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, CurrentUser);

    cleanup_session();
}

/* -------------------- SESSION MANAGEMENT -------------------- */

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    ObjectListPage = 0;
}

/* -------------------- GROUND REZ HANDLER -------------------- */

handle_ground_rez() {
    // Dismiss any outstanding ASK prompt and clear session trust
    clear_pending_ask();
    SessionTrustedKeys = [];

    // Turn off relay mode
    Mode = MODE_OFF;
    Hardcore = FALSE;
    persist_mode(MODE_OFF);
    persist_hardcore(FALSE);

    // Clear any active restrictions
    if (llGetListLength(Relays) > 0) {
        safeword_clear_all();
    }

    // Update listen state
    update_relay_listen_state();

    llOwnerSay("[RELAY] Collar rezzed on ground - Relay turned OFF");
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_start(string msg) {
    if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["user"]) == JSON_INVALID) return;

    string context = llJsonGetValue(msg, ["context"]);
    if (context != PLUGIN_CONTEXT) return;

    key user = (key)llJsonGetValue(msg, ["user"]);

    // Start new session
    CurrentUser = user;
    UserAcl = (integer)llJsonGetValue(msg, ["acl"]);
    show_main_menu();
}

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;

    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;

    string button = llJsonGetValue(msg, ["button"]);
    handle_button_click(button);
}

handle_dialog_timeout(string msg) {
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session == JSON_INVALID) return;
    if (session != SessionId) return;
    cleanup_session();
}

/* -------------------- RELAY PROTOCOL HANDLERS -------------------- */

handle_relay_message(key sender_id, string sender_name, string raw_msg) {
    // Only process relay commands when attached
    if (!IsAttached) return;

    // Parse message format: "command|channel" or just "command"
    list parsed = llParseString2List(raw_msg, ["|"], []);
    string raw_cmd = llList2String(parsed, 0);
    integer session_chan = RLV_RESP_CHANNEL;
    if (llGetListLength(parsed) > 1) {
        session_chan = (integer)llList2String(parsed, 1);
    }

    // Parse ORG standard format: "<ident>,<target_uuid>,<commands>"
    list parts = llParseString2List(raw_cmd, [","], []);
    string command = raw_cmd;

    // Validate ORG format: check if parts[1] looks like a UUID
    // UUIDs are 36 chars (8-4-4-4-12) with hyphens at positions 8,13,18,23
    if (llGetListLength(parts) >= 3) {
        string potential_uuid = llList2String(parts, 1);
        integer uuid_len = llStringLength(potential_uuid);

        // Check if this looks like a UUID (36 chars with hyphens in right places)
        if (uuid_len == 36 &&
            llGetSubString(potential_uuid, 8, 8) == "-" &&
            llGetSubString(potential_uuid, 13, 13) == "-" &&
            llGetSubString(potential_uuid, 18, 18) == "-" &&
            llGetSubString(potential_uuid, 23, 23) == "-") {

            // This is ORG format, validate target UUID
            key target_uuid = (key)potential_uuid;

            // Check if command is meant for this wearer (or wildcard)
            if (target_uuid != WearerKey && target_uuid != WILDCARD_UUID) {
                // Command not meant for this wearer, ignore it
                return;
            }

            // Extract commands (field 2 onwards)
            command = llList2String(parts, 2);
        }
        // else: not ORG format, treat entire raw_cmd as command
    }

    // Handle version queries
    if (command == "@version" || command == "@versionnew") {
        add_relay(sender_id, sender_name, session_chan);
        string reply = "RLV," + (string)llGetKey() + "," + command + ",ok";
        llRegionSayTo(sender_id, session_chan, reply);
        return;
    }

    // Handle release commands
    if (command == "!release" || command == "!release_fail") {
        clear_restrictions(sender_id);
        remove_relay(sender_id);
        string reply = "RLV," + (string)llGetKey() + "," + command + ",ok";
        llRegionSayTo(sender_id, session_chan, reply);
        return;
    }

    // Handle RLV commands
    if (llSubStringIndex(command, "@") == 0) {
        // Reject if mode is OFF
        if (Mode == MODE_OFF) {
            string reply_ko = "RLV," + (string)llGetKey() + "," + command + ",ko";
            llRegionSayTo(sender_id, session_chan, reply_ko);
            return;
        }

        // ASK mode: prompt wearer before executing restrictive commands from untrusted objects.
        // Removal commands (=y, @clear) are always auto-accepted per ORG spec.
        // Objects the wearer has accepted this session are also auto-accepted without re-prompting.
        if (Mode == MODE_ASK && !is_removal_command(command)) {
            integer already_trusted = (llListFindList(SessionTrustedKeys, [(string)sender_id]) != -1);
            if (!already_trusted) {
                if (PendingAskKey == NULL_KEY) {
                    // No active prompt — start one for this object
                    PendingAskKey = sender_id;
                    PendingAskName = sender_name;
                    PendingAskChan = session_chan;
                    PendingAskCommands = [command];
                    show_ask_dialog();
                }
                else if (PendingAskKey == sender_id) {
                    // Same object sent another command before wearer responded — batch it
                    PendingAskCommands += [command];
                }
                else {
                    // Different object arrived while a prompt is already open — reject
                    llRegionSayTo(sender_id, session_chan,
                        "RLV," + (string)llGetKey() + "," + command + ",ko");
                }
                return;
            }
            // already_trusted: fall through to accept below
        }

        // Accept command (MODE_ON, or MODE_ASK for trusted objects / removal commands)
        add_relay(sender_id, sender_name, session_chan);
        store_restriction(sender_id, command);
        llOwnerSay(command);  // Forward to viewer

        string reply_ok = "RLV," + (string)llGetKey() + "," + command + ",ok";
        llRegionSayTo(sender_id, session_chan, reply_ok);
        return;
    }
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        cleanup_session();
        clear_pending_ask();
        SessionTrustedKeys = [];

        // Check attachment state
        IsAttached = (llGetAttached() != 0);
        WearerKey = llGetOwner();

        if (!IsAttached) {
            // Ground rez: reset to safe defaults (LSD will be updated via handle_ground_rez)
            handle_ground_rez();
        }
        else {
            // Attached: restore runtime state from LSD immediately
            Mode = lsd_int(KEY_RELAY_MODE, MODE_ASK);
            Hardcore = lsd_int(KEY_RELAY_HARDCORE, FALSE);
            update_relay_listen_state();
        }

        register_self();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    timer() {
        // ASK dialog timed out — treat as denial
        if (PendingAskKey != NULL_KEY) {
            llRegionSayTo(WearerKey, 0, "[RELAY] Request timed out: " + PendingAskName);
            decline_ask();
        }
    }

    attach(key id) {
        if (id == NULL_KEY) {
            // Detached — dismiss any pending ASK and reset session trust
            clear_pending_ask();
            SessionTrustedKeys = [];
            IsAttached = FALSE;
            handle_ground_rez();
        }
        else {
            // Attached
            IsAttached = TRUE;
            WearerKey = id;  // Update cached wearer UUID
            update_relay_listen_state();
            llOwnerSay("[RELAY] Collar attached - Relay state restored");
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        /* -------------------- LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.registernow") {
                register_self();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset" || msg_type == "kernel.resetall") {
                llResetScript();
            }
        }

        /* -------------------- SETTINGS -------------------- */
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                apply_settings_sync();
            }
        }

        /* -------------------- UI -------------------- */
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                handle_start(msg);
            }
        }

        /* -------------------- DIALOG -------------------- */
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
            }
        }

        /* -------------------- SOS -------------------- */
        else if (num == SOS_MSG_NUM) {
            if (msg_type == "sos.release") {
                safeword_clear_all();
                llOwnerSay("[SOS] All RLV restrictions cleared.");
            }
        }
    }

    listen(integer chan, string name, key id, string msg) {
        if (chan == RELAY_CHANNEL) {
            handle_relay_message(id, name, msg);
        }
        else if (chan == AskDialogChan && id == WearerKey) {
            if (msg == "Allow") {
                accept_ask();
            }
            else if (msg == "Deny") {
                decline_ask();
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
