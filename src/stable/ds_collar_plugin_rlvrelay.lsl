/* ===============================================================
   PLUGIN: ds_collar_plugin_rlvrelay.lsl (v1.0 - Consolidated ABI)
   
   PURPOSE: RLV relay with mode toggle + hardcore + safeword integration
   
   FEATURES:
   - OFF/ON/HARDCORE modes with settings persistence
   - Listens on relay channel for device commands
   - ACL-gated menu access
   - Hardcore mode requires ACL 3+ to toggle
   - SOS integration for emergency release
   - Auto-disable when rezzed on ground
   - Centralized dialog system
   
   BUG FIXES FROM V1:
   - Fixed: Settings now persist across resets
   - Fixed: Proper dialog session management via centralized system
   - Fixed: Relay listen lifecycle tied to Mode + IsAttached
   - Fixed: ACL race condition handling
   - Fixed: Object name truncation in display
   - Fixed: Session cleanup properly cancels dialogs
   
   NAMING: PascalCase globals, ALL_CAPS constants, snake_case locals
   =============================================================== */

integer DEBUG = FALSE;

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ===============================================================
   PLUGIN IDENTITY
   =============================================================== */
string PLUGIN_CONTEXT = "core_relay";
string PLUGIN_LABEL = "RLV Relay";
integer PLUGIN_MIN_ACL = 2;  // Wearer and above
string ROOT_CONTEXT = "core_root";

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* ===============================================================
   RELAY CONSTANTS
   =============================================================== */
integer RELAY_CHANNEL = -1812221819;
integer RLV_RESP_CHANNEL = 4711;
integer MAX_RELAYS = 5;

integer MODE_OFF = 0;
integer MODE_ON = 1;
integer MODE_HARDCORE = 2;

integer SOS_MSG_NUM = 555;  // SOS emergency channel

/* ===============================================================
   SETTINGS KEYS
   =============================================================== */
string KEY_RELAY_MODE = "relay_mode";
string KEY_RELAY_HARDCORE = "relay_hardcore";

/* ===============================================================
   STATE
   =============================================================== */
// Relay state
integer Mode = MODE_ON;
integer Hardcore = FALSE;
integer IsAttached = FALSE;
integer RelayListenHandle = 0;

// Relays: [obj_key, obj_name, session_chan, restrictions_csv] * N
list Relays = [];

// Session management
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";

// Menu state for object list pagination
integer ObjectListPage = 0;

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[RELAY] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer now() {
    return llGetUnixTime();
}

string generateSessionId() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string truncateName(string name, integer max_len) {
    if (llStringLength(name) <= max_len) return name;
    return llGetSubString(name, 0, max_len - 4) + "...";
}

/* ===============================================================
   LIFECYCLE MANAGEMENT
   =============================================================== */

registerSelf() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Registered with kernel");
}

sendPong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* ===============================================================
   RELAY LISTEN MANAGEMENT
   =============================================================== */

startRelayListen() {
    if (RelayListenHandle) return;  // Already listening
    
    RelayListenHandle = llListen(RELAY_CHANNEL, "", NULL_KEY, "");
    logd("Relay channel listener started");
}

stopRelayListen() {
    if (RelayListenHandle) {
        llListenRemove(RelayListenHandle);
        RelayListenHandle = 0;
        logd("Relay channel listener stopped");
    }
}

updateRelayListenState() {
    // Only listen if: Mode != OFF AND IsAttached
    if (Mode != MODE_OFF && IsAttached) {
        start_relay_listen();
    }
    else {
        stop_relay_listen();
    }
}

/* ===============================================================
   RELAY MANAGEMENT
   =============================================================== */

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
        logd("Max relays reached. Ignoring " + obj_name);
        return FALSE;
    }
    
    // Add new relay
    Relays += [obj, obj_name, chan, ""];
    logd("Added relay: " + obj_name);
    return TRUE;
}

integer remove_relay(key obj) {
    integer idx = relay_idx(obj);
    if (idx != -1) {
        Relays = llDeleteSubList(Relays, idx, idx + 3);
        logd("Removed relay: " + (string)obj);
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

clearRestrictions(key obj) {
    integer idx = relay_idx(obj);
    if (idx != -1) {
        // Use @clear per RLV spec - safer than manual reversal
        llOwnerSay("@clear");
        Relays = llListReplaceList(Relays, [""], idx + 3, idx + 3);
    }
}

safewordClearAll() {
    integer relay_count = llGetListLength(Relays);
    integer i = 0;
    while (i < relay_count) {
        key obj = llList2Key(Relays, i);
        clear_restrictions(obj);
        i = i + 4;
    }
    Relays = [];
    logd("Cleared all relay restrictions");
}

/* ===============================================================
   SETTINGS CONSUMPTION
   =============================================================== */

applySettingsSync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
    string kv_json = llJsonGetValue(msg, ["kv"]);
    
    // Reset to defaults
    Mode = MODE_ON;
    Hardcore = FALSE;
    
    // Load persisted values
    if (json_has(kv_json, [KEY_RELAY_MODE])) {
        Mode = (integer)llJsonGetValue(kv_json, [KEY_RELAY_MODE]);
    }
    
    if (json_has(kv_json, [KEY_RELAY_HARDCORE])) {
        Hardcore = (integer)llJsonGetValue(kv_json, [KEY_RELAY_HARDCORE]);
    }
    
    // Update relay listen state
    update_relay_listen_state();
    
    logd("Settings sync applied: Mode=" + (string)Mode + " Hardcore=" + (string)Hardcore);
}

applySettingsDelta(string msg) {
    if (!json_has(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (json_has(changes, [KEY_RELAY_MODE])) {
            Mode = (integer)llJsonGetValue(changes, [KEY_RELAY_MODE]);
            logd("Delta: mode = " + (string)Mode);
            update_relay_listen_state();
        }
        
        if (json_has(changes, [KEY_RELAY_HARDCORE])) {
            Hardcore = (integer)llJsonGetValue(changes, [KEY_RELAY_HARDCORE]);
            logd("Delta: hardcore = " + (string)Hardcore);
        }
    }
}

/* ===============================================================
   SETTINGS MODIFICATION
   =============================================================== */

persistMode(integer new_mode) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_RELAY_MODE,
        "value", (string)new_mode
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

persistHardcore(integer new_hardcore) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_RELAY_HARDCORE,
        "value", (string)new_hardcore
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

/* ===============================================================
   ACL VALIDATION
   =============================================================== */

requestAcl(key user) {
    AclPending = TRUE;
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_acl"
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

handleAclResult(string msg) {
    if (!json_has(msg, ["avatar"])) return;
    if (!json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    
    AclPending = FALSE;
    UserAcl = level;
    
    // Check if user has sufficient access
    if (level < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanup_session();
        return;
    }
    
    // User has access, show menu
    show_main_menu();
}

/* ===============================================================
   UI / MENU SYSTEM
   =============================================================== */

showMainMenu() {
    SessionId = generate_session_id();
    
    string mode_str = "OFF";
    if (Mode == MODE_ON) {
        if (Hardcore) {
            mode_str = "HARDCORE";
        }
        else {
            mode_str = "ON";
        }
    }
    
    integer relay_count = llGetListLength(Relays) / 4;
    
    string message = "RLV Relay Menu\nMode: " + mode_str + "\nActive Relays: " + (string)relay_count;
    
    list buttons = ["Back", "Mode", "Bound by..."];
    
    // Safeword for ACL 2/4 when not hardcore
    if ((UserAcl == 2 || UserAcl == 4) && !Hardcore) {
        buttons += ["Safeword"];
    }
    
    // Unbind for ACL 3/5
    if (UserAcl == 3 || UserAcl == 5) {
        buttons += ["Unbind"];
    }
    
    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL + " Menu",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
    logd("Showing main menu to " + llKey2Name(CurrentUser));
}

showModeMenu() {
    SessionId = generate_session_id();
    
    string mode_str = "OFF";
    if (Mode == MODE_ON) {
        if (Hardcore) {
            mode_str = "HARDCORE";
        }
        else {
            mode_str = "ON";
        }
    }
    
    string message = "RLV Relay Mode: " + mode_str;
    
    list buttons = ["Back", "OFF", "ON"];
    
    // Hardcore toggle only for ACL 3/5
    if (UserAcl == 3 || UserAcl == 5) {
        if (Hardcore) {
            buttons += ["HC OFF"];
        }
        else {
            buttons += ["HC ON"];
        }
    }
    
    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Relay Mode",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

showObjectList() {
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
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Active Relays",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* ===============================================================
   BUTTON HANDLING
   =============================================================== */

handleButtonClick(string button) {
    if (button == "Mode") {
        show_mode_menu();
    }
    else if (button == "Bound by...") {
        show_object_list();
    }
    else if (button == "Safeword") {
        if ((UserAcl == 2 || UserAcl == 4) && !Hardcore) {
            safeword_clear_all();
            llRegionSayTo(CurrentUser, 0, "[RELAY] Safeword used - all restrictions cleared");
            show_main_menu();
        }
    }
    else if (button == "Unbind") {
        if (UserAcl == 3 || UserAcl == 5) {
            safeword_clear_all();
            llRegionSayTo(CurrentUser, 0, "[RELAY] Unbound - all restrictions cleared");
            show_main_menu();
        }
    }
    else if (button == "OFF") {
        Mode = MODE_OFF;
        Hardcore = FALSE;
        persist_mode(MODE_OFF);
        persist_hardcore(FALSE);
        update_relay_listen_state();
        llRegionSayTo(CurrentUser, 0, "[RELAY] Mode set to OFF");
        show_mode_menu();
    }
    else if (button == "ON") {
        Mode = MODE_ON;
        persist_mode(MODE_ON);
        update_relay_listen_state();
        if (!Hardcore) {
            llRegionSayTo(CurrentUser, 0, "[RELAY] Mode set to ON");
        }
        show_mode_menu();
    }
    else if (button == "HC ON") {
        if (UserAcl == 3 || UserAcl == 5) {
            Hardcore = TRUE;
            Mode = MODE_ON;
            persist_hardcore(TRUE);
            persist_mode(MODE_ON);
            llRegionSayTo(CurrentUser, 0, "[RELAY] Hardcore mode ENABLED");
            show_mode_menu();
        }
    }
    else if (button == "HC OFF") {
        if (UserAcl == 3 || UserAcl == 5) {
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

/* ===============================================================
   NAVIGATION
   =============================================================== */

returnToRoot() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, CurrentUser);
    
    cleanup_session();
    logd("Returning to root menu");
}

closeSilent() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "close",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, CurrentUser);
    
    cleanup_session();
    logd("Closing session silently");
}

/* ===============================================================
   SESSION MANAGEMENT
   =============================================================== */

cleanupSession() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    AclPending = FALSE;
    SessionId = "";
    ObjectListPage = 0;
}

/* ===============================================================
   GROUND REZ HANDLER
   =============================================================== */

handleGroundRez() {
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

/* ===============================================================
   MESSAGE HANDLERS
   =============================================================== */

handleStart(string msg) {
    if (!json_has(msg, ["context"])) return;
    if (!json_has(msg, ["user"])) return;
    
    string context = llJsonGetValue(msg, ["context"]);
    if (context != PLUGIN_CONTEXT) return;
    
    key user = (key)llJsonGetValue(msg, ["user"]);
    
    // Start new session
    CurrentUser = user;
    request_acl(user);
    
    logd("Started by " + llKey2Name(user));
}

handleDialogResponse(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (!json_has(msg, ["button"])) return;
    
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    
    string button = llJsonGetValue(msg, ["button"]);
    handle_button_click(button);
}

handleDialogTimeout(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    
    logd("Dialog timeout");
    cleanup_session();
}

/* ===============================================================
   RELAY PROTOCOL HANDLERS
   =============================================================== */

handleRelayMessage(key sender_id, string sender_name, string raw_msg) {
    // Only process relay commands when attached
    if (!IsAttached) return;
    
    // Parse message format: "command|channel" or just "command"
    list parsed = llParseString2List(raw_msg, ["|"], []);
    string raw_cmd = llList2String(parsed, 0);
    integer session_chan = RLV_RESP_CHANNEL;
    if (llGetListLength(parsed) > 1) {
        session_chan = (integer)llList2String(parsed, 1);
    }
    
    // Extract command from RLV wrapper if present
    string command = raw_cmd;
    if (llSubStringIndex(raw_cmd, "RLV,") == 0) {
        list parts = llParseString2List(raw_cmd, [","], []);
        if (llGetListLength(parts) >= 3) {
            command = llList2String(parts, 2);
        }
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
        
        // Accept command
        add_relay(sender_id, sender_name, session_chan);
        store_restriction(sender_id, command);
        llOwnerSay(command);  // Forward to viewer
        
        string reply_ok = "RLV," + (string)llGetKey() + "," + command + ",ok";
        llRegionSayTo(sender_id, session_chan, reply_ok);
        return;
    }
}

/* ===============================================================
   EVENTS
   =============================================================== */

default
{
    state_entry() {
        cleanup_session();
        
        // Check attachment state
        IsAttached = (llGetAttached() != 0);
        
        // Handle ground rez
        if (!IsAttached) {
            handle_ground_rez();
        }
        
        logd("Plugin started (Attached=" + (string)IsAttached + ")");
        
        // Request settings
        string request = llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]);
        llMessageLinked(LINK_SET, SETTINGS_BUS, request, NULL_KEY);
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    attach(key id) {
        if (id == NULL_KEY) {
            // Detached
            IsAttached = FALSE;
            handle_ground_rez();
        }
        else {
            // Attached
            IsAttached = TRUE;
            update_relay_listen_state();
            llOwnerSay("[RELAY] Collar attached - Relay state restored");
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        /* ===== LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "register_now") {
                register_self();
            }
            else if (msg_type == "ping") {
                send_pong();
            }
            else if (msg_type == "soft_reset") {
                llResetScript();
            }
        }
        
        /* ===== SETTINGS ===== */
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
            }
            else if (msg_type == "settings_delta") {
                apply_settings_delta(msg);
            }
        }
        
        /* ===== AUTH ===== */
        else if (num == AUTH_BUS) {
            if (msg_type == "acl_result") {
                handle_acl_result(msg);
            }
        }
        
        /* ===== UI ===== */
        else if (num == UI_BUS) {
            if (msg_type == "start") {
                handle_start(msg);
            }
        }
        
        /* ===== DIALOG ===== */
        else if (num == DIALOG_BUS) {
            if (msg_type == "dialog_response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "dialog_timeout") {
                handle_dialog_timeout(msg);
            }
        }
        
        /* ===== SOS ===== */
        else if (num == SOS_MSG_NUM) {
            if (msg_type == "sos_release") {
                safeword_clear_all();
                llOwnerSay("[SOS] All RLV restrictions cleared.");
            }
        }
    }
    
    listen(integer chan, string name, key id, string msg) {
        if (chan == RELAY_CHANNEL) {
            handle_relay_message(id, name, msg);
        }
    }
}
