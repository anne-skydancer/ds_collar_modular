/* =============================================================================
   DS Collar - Leash Plugin (v2.0)
   
   ROLE: User interface and configuration for leashing system
   
   FEATURES:
   - Menu system (main, settings, length, pass/offer)
   - ACL enforcement
   - Sensor for Pass menu
   - Settings adjustment (length, turn-to-face)
   - Give holder object
   
   COMMUNICATION:
   - Receives leash_state updates from core plugin
   - Sends leash_action commands to core plugin
   - Uses centralized dialog system (no listen handles)
   
   CHANNELS:
   - 500: Kernel lifecycle
   - 700: Auth queries
   - 900: UI/command bus
   - 950: Dialog system
   ============================================================================= */

integer DEBUG = FALSE;
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_CONTEXT = "core_leash";
string PLUGIN_LABEL = "Leash";
integer PLUGIN_MIN_ACL = 2;  // Level 2 (Owned) and above
string ROOT_CONTEXT = "core_root";

list ALLOWED_ACL_GRAB = [3, 5];        // Trustee, Owner only
list ALLOWED_ACL_SETTINGS = [3, 5];    // Trustee, Owner only (NOT level 2!)

// Current leash state (synced from core)
integer Leashed = FALSE;
key Leasher = NULL_KEY;
integer LeashLength = 3;
integer TurnToFace = FALSE;

// Session/menu state
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";
string MenuContext = "";
string SensorMode = "";
list SensorCandidates = [];

// ===== HELPERS =====
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[LEASH-CFG] " + msg);
    return FALSE;
}
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}
integer in_allowed_list(integer level, list allowed) {
    return (llListFindList(allowed, [level]) != -1);
}

// ===== UNIFIED MENU DISPLAY =====
show_menu(string context, string title, string body, list buttons) {
    SessionId = generate_session_id();
    MenuContext = context;
    
    // Reverse buttons for proper dialog display (bottom-right to top-left)
    list reversed = [];
    integer i = llGetListLength(buttons) - 1;
    while (i >= 0) {
        reversed += [llList2String(buttons, i)];
        i = i - 1;
    }
    
    // For pass/length menus: << at 0, >> at 1, Back at 2
    if (context == "pass" || context == "length") {
        // Remove "Back" from reversed list if present
        integer back_idx = llListFindList(reversed, ["Back"]);
        if (back_idx != -1) {
            reversed = llDeleteSubList(reversed, back_idx, back_idx);
        }
        
        // Build: ["<<", ">>", "Back", ...content]
        reversed = ["<<", ">>", "Back"] + reversed;
    }
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, reversed),
        "timeout", 60
    ]), NULL_KEY);
}

// ===== ACL QUERIES =====
request_acl(key user) {
    AclPending = TRUE;
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user
    ]), user);
logd("ACL query sent for " + llKey2Name(user));
}

// ===== PLUGIN REGISTRATION =====
register_self() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

// ===== MENU SYSTEM =====
show_main_menu() {
    list buttons = [];
    if (!Leashed) {
        if (in_allowed_list(UserAcl, ALLOWED_ACL_GRAB)) buttons += ["Grab"];
        if (UserAcl == 2) buttons += ["Offer"];  // Level 2 can offer when NOT leashed
    }
    else {
        if (CurrentUser == Leasher) {
            // Current leasher gets full control
            buttons += ["Release", "Pass", "Yank"];
        }
        else if (UserAcl == 2) {
            // Level 2 (Owned) gets ONLY Unclip when leashed
            buttons += ["Unclip"];
        }
    }
    if (in_allowed_list(UserAcl, ALLOWED_ACL_SETTINGS)) buttons += ["Settings"];
    buttons += ["Back"];
    string body;
    if (Leashed) body = "Leashed to: " + llKey2Name(Leasher) + "\nLength: " + (string)LeashLength + "m";
    else body = "Not leashed";
    show_menu("main", "Leash", body, buttons);
}
show_settings_menu() {
    list buttons;
    if (TurnToFace) buttons = ["Turn: On"];
    else buttons = ["Turn: Off"];
    buttons += ["Length", "Give Holder", "Back"];
    string body = "Leash Settings\nLength: " + (string)LeashLength + "m\nTurn to face: " + (string)TurnToFace;
    show_menu("settings", "Settings", body, buttons);
}
show_length_menu() {
    show_menu("length", "Length", "Select leash length\nCurrent: " + (string)LeashLength + "m", 
              ["1m", "3m", "5m", "10m", "15m", "20m", "Back"]);
}
show_pass_menu() {
    SensorMode = "pass";
    MenuContext = "pass";
    llSensor("", NULL_KEY, AGENT, 96.0, PI);
}
// ===== ACTIONS =====
give_holder_object() {
    string holder_name = "D/s Collar leash holder";
    if (llGetInventoryType(holder_name) != INVENTORY_OBJECT) {
        llRegionSayTo(CurrentUser, 0, "Error: Holder object not found in collar inventory.");
logd("Holder object not in inventory");
        return;
    }
    llGiveInventory(CurrentUser, holder_name);
    llRegionSayTo(CurrentUser, 0, "Leash holder given.");
logd("Gave holder to " + llKey2Name(CurrentUser));
}

send_leash_action(string action) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", action
    ]), CurrentUser);
}
send_leash_action_with_target(string action, key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", action,
        "target", (string)target
    ]), CurrentUser);
}
send_set_length(integer length) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", "set_length",
        "length", (string)length
    ]), CurrentUser);
}

// ===== BUTTON HANDLERS =====
handle_button_click(string button) {
logd("Button: " + button + " in context: " + MenuContext);
    if (MenuContext == "main") {
        if (button == "Grab") { if (in_allowed_list(UserAcl, ALLOWED_ACL_GRAB)) { send_leash_action("grab"); cleanup_session(); } }
        else if (button == "Release") { send_leash_action("release"); cleanup_session(); }
        else if (button == "Pass") show_pass_menu();
        else if (button == "Offer") show_pass_menu();
        else if (button == "Unclip") { if (UserAcl == 2) { send_leash_action("release"); cleanup_session(); } }
        else if (button == "Yank") { send_leash_action("yank"); show_main_menu(); }
        else if (button == "Settings") show_settings_menu();
        else if (button == "Back") return_to_root();
    }
    else if (MenuContext == "settings") {
        if (button == "Length") show_length_menu();
        else if (button == "Give Holder") { give_holder_object(); show_settings_menu(); }
        else if (button == "Turn: On" || button == "Turn: Off") { send_leash_action("toggle_turn"); llSleep(0.1); query_state(); show_settings_menu(); }
        else if (button == "Back") show_main_menu();
    }
    else if (MenuContext == "length") {
        if (button == "Back") { show_settings_menu(); }
        else if (button == "<<") { send_set_length(LeashLength - 1); llSleep(0.1); query_state(); show_length_menu(); }
        else if (button == ">>") { send_set_length(LeashLength + 1); llSleep(0.1); query_state(); show_length_menu(); }
        else {
            integer length = (integer)button;
            if (length >= 1 && length <= 20) { send_set_length(length); llSleep(0.1); query_state(); show_settings_menu(); }
        }
    }
    else if (MenuContext == "pass") {
        if (button == "Back") show_main_menu();
        else if (button == "<<" || button == ">>") show_pass_menu();
        else {
            integer i = 0;
            key selected = NULL_KEY;
            while (i < llGetListLength(SensorCandidates)) {
                if (llList2String(SensorCandidates, i) == button) {
                    selected = llList2Key(SensorCandidates, i + 1);
                    i = llGetListLength(SensorCandidates);
                }
                else i = i + 2;
            }
            if (selected != NULL_KEY) { send_leash_action_with_target("pass", selected); cleanup_session(); }
            else { llRegionSayTo(CurrentUser, 0, "Avatar not found."); show_main_menu(); }
        }
    }
}

// ===== NAVIGATION =====
return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, ["type", "return", "user", (string)CurrentUser]), NULL_KEY);
    cleanup_session();
}
cleanup_session() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    AclPending = FALSE;
    SessionId = "";
    MenuContext = "";
    SensorMode = "";
    SensorCandidates = [];
logd("Session cleaned up");
}
query_state() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, ["type", "leash_action", "action", "query_state"]), NULL_KEY);
}

// ===== EVENT HANDLERS =====
default
{
    state_entry() {
        cleanup_session();
        register_self();
        query_state();
logd("Leash UI ready");
    }
    on_rez(integer start_param) {
        llResetScript();
    }
    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }
    link_message(integer sender, integer num, string msg, key id) {
        if (num == KERNEL_LIFECYCLE) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == "register_now") {
                register_self();
                return;
            }
            if (msg_type == "ping") {
                send_pong();
                return;
            }
            return;
        }
        if (num == UI_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == "start") {
                if (!json_has(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                CurrentUser = id;
                request_acl(id);
                return;
            }
            if (msg_type == "leash_state") {
                if (json_has(msg, ["leashed"])) Leashed = (integer)llJsonGetValue(msg, ["leashed"]);
                if (json_has(msg, ["leasher"])) Leasher = (key)llJsonGetValue(msg, ["leasher"]);
                if (json_has(msg, ["length"])) LeashLength = (integer)llJsonGetValue(msg, ["length"]);
                if (json_has(msg, ["turnto"])) TurnToFace = (integer)llJsonGetValue(msg, ["turnto"]);
logd("State synced");
                return;
            }
        }
        if (num == AUTH_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == "acl_result") {
                if (!AclPending) return;
                if (!json_has(msg, ["avatar"])) return;
                key avatar = (key)llJsonGetValue(msg, ["avatar"]);
                if (avatar != CurrentUser) return;
                if (json_has(msg, ["level"])) {
                    UserAcl = (integer)llJsonGetValue(msg, ["level"]);
                    AclPending = FALSE;
                    query_state();
                    llSleep(0.1);
                    show_main_menu();
logd("ACL received: " + (string)UserAcl + " for " + llKey2Name(avatar));
                }
                return;
            }
            return;
        }
        if (num == DIALOG_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == "dialog_response") {
                if (!json_has(msg, ["session_id"]) || !json_has(msg, ["button"])) return;
                string response_session = llJsonGetValue(msg, ["session_id"]);
                if (response_session != SessionId) return;
                string button = llJsonGetValue(msg, ["button"]);
                handle_button_click(button);
                return;
            }
            if (msg_type == "dialog_timeout") {
                if (!json_has(msg, ["session_id"])) return;
                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                if (timeout_session != SessionId) return;
logd("Dialog timeout");
                cleanup_session();
                return;
            }
            return;
        }
    }
    sensor(integer num) {
        if (SensorMode == "") return;
        if (CurrentUser == NULL_KEY) return;
        key owner = llGetOwner();
        SensorCandidates = [];
        integer i = 0;
        while (i < num && i < 9) {
            key detected = llDetectedKey(i);
            if (detected != owner && detected != Leasher) {
                SensorCandidates += [llDetectedName(i), detected];
            }
            i = i + 1;
        }
        if (llGetListLength(SensorCandidates) == 0) {
            if (SensorMode == "pass") {
                llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
                show_main_menu();
            }
            SensorMode = "";
            return;
        }
        list names = [];
        i = 0;
        while (i < llGetListLength(SensorCandidates)) {
            names += [llList2String(SensorCandidates, i)];
            i = i + 2;
        }
        names = ["Back"] + names;
        MenuContext = SensorMode;
        string title = "";
        string body = "";
        if (SensorMode == "pass") {
            title = "Pass Leash";
            body = "Select avatar:";
        }
        show_menu(SensorMode, title, body, names);
    }
    no_sensor() {
        if (SensorMode == "") return;
        if (SensorMode == "pass") {
            llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
            show_main_menu();
        }
        SensorMode = "";
    }
}
