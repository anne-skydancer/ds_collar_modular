/* ===============================================================
   DS Collar - Leash Plugin (v1.0 OFFER DIALOG)
   
   PURPOSE: User interface and configuration for leashing system
   
   CHANGES v1.0:
   - Added offer acceptance dialog (targets can Accept/Decline offers)
   - Handles offer_pending messages from kernel module
   - Manages offer dialog state separately from menu dialogs
   
   CHANGES v1.0:
   - Removed wasteful button reversal logic - buttons now built in correct order
   - Added IsOfferMode flag to distinguish Offer from Pass actions
   - ACL 2 no longer gets "Get Holder" button (unnecessary for owned wearers)
   - Offer action properly routed as "offer" to kernel module
   
   FEATURES:
   - Menu system (main, settings, length, pass/offer)
   - ACL enforcement
   - Sensor for Pass/Offer menus
   - Settings adjustment (length, turn-to-face)
   - Give holder object (ACL 3+ only)
   
   COMMUNICATION:
   - Receives leash_state updates from core plugin
   - Sends leash_action commands to core plugin
   - Uses centralized dialog system (no listen handles)
   
   CHANNELS:
   - 500: Kernel lifecycle
   - 700: Auth queries
   - 900: UI/command bus
   - 950: Dialog system
   =============================================================== */

integer DEBUG = FALSE;
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_CONTEXT = "core_leash";
string PLUGIN_LABEL = "Leash";
integer PLUGIN_MIN_ACL = 1;
string ROOT_CONTEXT = "core_root";

list ALLOWED_ACL_GRAB  = [1, 3, 4, 5];
list ALLOWED_ACL_SETTINGS = [3, 4, 5];

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
integer IsOfferMode = FALSE;  // TRUE if ACL 2 offering, FALSE if higher ACL passing

// Offer dialog state (NEW v1.0)
string OfferDialogSession = "";
key OfferTarget = NULL_KEY;
key OfferOriginator = NULL_KEY;

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
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
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
    // Build buttons in display order (left-to-right, top-to-bottom)
    list buttons = ["Back"];
    
    // Action buttons
    if (!Leashed) {
        if (in_allowed_list(UserAcl, ALLOWED_ACL_GRAB)) {
            buttons += ["Clip"];
        }
        if (UserAcl == 2) {
            buttons += ["Offer"];
        }
    }
    else {
        if (UserAcl == 2) {
            buttons += ["Unclip"];
        }
        else if (CurrentUser == Leasher) {
            buttons += ["Unclip", "Pass", "Yank"];
        }
    }
    
    // Get Holder button - ACL 1, 3, 4, 5 (NOT ACL 2)
    if (UserAcl == 1 || UserAcl >= 3) {
        buttons += ["Get Holder"];
    }
    
    // Settings button - ACL 1, 3, 4, 5 (NOT ACL 2)
    if (UserAcl == 1 || in_allowed_list(UserAcl, ALLOWED_ACL_SETTINGS)) {
        buttons += ["Settings"];
    }
    
    string body;
    if (Leashed) {
        body = "Leashed to: " + llKey2Name(Leasher) + "\nLength: " + (string)LeashLength + "m";
    }
    else {
        body = "Not leashed";
    }
    
    show_menu("main", "Leash", body, buttons);
}

show_settings_menu() {
    list buttons = ["Back", "Length"];
    if (TurnToFace) {
        buttons += ["Turn: On"];
    }
    else {
        buttons += ["Turn: Off"];
    }
    
    string body = "Leash Settings\nLength: " + (string)LeashLength + "m\nTurn to face: " + (string)TurnToFace;
    show_menu("settings", "Settings", body, buttons);
}

show_length_menu() {
    show_menu("length", "Length", "Select leash length\nCurrent: " + (string)LeashLength + "m", 
              ["<<", ">>", "Back", "1m", "3m", "5m", "10m", "15m", "20m"]);
}

show_pass_menu() {
    SensorMode = "pass";
    MenuContext = "pass";
    llSensor("", NULL_KEY, AGENT, 96.0, PI);
}

// ===== OFFER DIALOG (NEW v1.0) =====
show_offer_dialog(key target, key originator) {
    OfferDialogSession = generate_session_id();
    OfferTarget = target;
    OfferOriginator = originator;
    
    string offerer_name = llKey2Name(originator);
    key wearer = llGetOwner();
    string wearer_name = llKey2Name(wearer);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", OfferDialogSession,
        "user", (string)target,
        "title", "Leash Offer",
        "body", offerer_name + " (" + wearer_name + ") is offering you their leash.",
        "buttons", llList2Json(JSON_ARRAY, ["Accept", "Decline"]),
        "timeout", 60
    ]), NULL_KEY);
    
    logd("Offer dialog shown to " + llKey2Name(target) + " from " + offerer_name);
}

handle_offer_response(string button) {
    if (button == "Accept") {
        // Send grab action to kernel with target as leasher
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type", "leash_action",
            "action", "grab",
            "acl_verified", "1"
        ]), OfferTarget);
        
        llRegionSayTo(OfferOriginator, 0, llKey2Name(OfferTarget) + " accepted your leash offer.");
        logd("Offer accepted by " + llKey2Name(OfferTarget));
    }
    else {
        llRegionSayTo(OfferOriginator, 0, llKey2Name(OfferTarget) + " declined your leash offer.");
        llRegionSayTo(OfferTarget, 0, "You declined the leash offer.");
        logd("Offer declined by " + llKey2Name(OfferTarget));
    }
    
    // Clear offer state
    OfferDialogSession = "";
    OfferTarget = NULL_KEY;
    OfferOriginator = NULL_KEY;
}

cleanup_offer_dialog() {
    if (OfferOriginator != NULL_KEY) {
        llRegionSayTo(OfferOriginator, 0, "Leash offer to " + llKey2Name(OfferTarget) + " timed out.");
    }
    OfferDialogSession = "";
    OfferTarget = NULL_KEY;
    OfferOriginator = NULL_KEY;
    logd("Offer dialog timed out");
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
        "action", action,
        "acl_verified", "1"
    ]), CurrentUser);
}

send_leash_action_with_target(string action, key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", action,
        "target", (string)target,
        "acl_verified", "1"
    ]), CurrentUser);
}

send_set_length(integer length) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", "set_length",
        "length", (string)length,
        "acl_verified", "1"
    ]), CurrentUser);
}

// ===== BUTTON HANDLERS =====
handle_button_click(string button) {
    logd("Button: " + button + " in context: " + MenuContext);
    
    if (MenuContext == "main") {
        if (button == "Clip") {
            if (in_allowed_list(UserAcl, ALLOWED_ACL_GRAB)) {
                send_leash_action("grab");
                cleanup_session();
            }
        }
        else if (button == "Unclip") {
            send_leash_action("release");
            cleanup_session();
        }
        else if (button == "Pass") {
            IsOfferMode = FALSE;
            show_pass_menu();
        }
        else if (button == "Offer") {
            IsOfferMode = TRUE;
            show_pass_menu();
        }
        else if (button == "Yank") {
            send_leash_action("yank");
            show_main_menu();
        }
        else if (button == "Get Holder") {
            give_holder_object();
            show_main_menu();
        }
        else if (button == "Settings") {
            show_settings_menu();
        }
        else if (button == "Back") {
            return_to_root();
        }
    }
    else if (MenuContext == "settings") {
        if (button == "Length") {
            show_length_menu();
        }
        else if (button == "Turn: On" || button == "Turn: Off") {
            send_leash_action("toggle_turn");
            llSleep(0.1);
            query_state();
            show_settings_menu();
        }
        else if (button == "Back") {
            show_main_menu();
        }
    }
    else if (MenuContext == "length") {
        if (button == "Back") {
            show_settings_menu();
        }
        else if (button == "<<") {
            send_set_length(LeashLength - 1);
            llSleep(0.1);
            query_state();
            show_length_menu();
        }
        else if (button == ">>") {
            send_set_length(LeashLength + 1);
            llSleep(0.1);
            query_state();
            show_length_menu();
        }
        else {
            integer length = (integer)button;
            if (length >= 1 && length <= 20) {
                send_set_length(length);
                llSleep(0.1);
                query_state();
                show_settings_menu();
            }
        }
    }
    else if (MenuContext == "pass") {
        if (button == "Back") {
            show_main_menu();
        }
        else if (button == "<<" || button == ">>") {
            show_pass_menu();
        }
        else {
            // Find selected avatar in SensorCandidates
            key selected = NULL_KEY;
            integer i = 0;
            while (i < llGetListLength(SensorCandidates)) {
                if (llList2String(SensorCandidates, i) == button) {
                    selected = llList2Key(SensorCandidates, i + 1);
                    i = llGetListLength(SensorCandidates);
                }
                else {
                    i = i + 2;
                }
            }
            
            if (selected != NULL_KEY) {
                string action;
                if (IsOfferMode) {
                    action = "offer";
                }
                else {
                    action = "pass";
                }
                send_leash_action_with_target(action, selected);
                cleanup_session();
            }
            else {
                llRegionSayTo(CurrentUser, 0, "Avatar not found.");
                show_main_menu();
            }
        }
    }
}

// ===== NAVIGATION =====
return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]), NULL_KEY);
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
    IsOfferMode = FALSE;
    logd("Session cleaned up");
}

query_state() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", "query_state"
    ]), NULL_KEY);
}

// ===== EVENT HANDLERS =====
default
{
    state_entry() {
        cleanup_session();
        register_self();
        query_state();
        logd("Leash UI ready (v1.0 OFFER DIALOG)");
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
                if (json_has(msg, ["leashed"])) {
                    Leashed = (integer)llJsonGetValue(msg, ["leashed"]);
                }
                if (json_has(msg, ["leasher"])) {
                    Leasher = (key)llJsonGetValue(msg, ["leasher"]);
                }
                if (json_has(msg, ["length"])) {
                    LeashLength = (integer)llJsonGetValue(msg, ["length"]);
                }
                if (json_has(msg, ["turnto"])) {
                    TurnToFace = (integer)llJsonGetValue(msg, ["turnto"]);
                }
                logd("State synced");
                return;
            }
            
            if (msg_type == "offer_pending") {
                if (!json_has(msg, ["target"]) || !json_has(msg, ["originator"])) return;
                key target = (key)llJsonGetValue(msg, ["target"]);
                key originator = (key)llJsonGetValue(msg, ["originator"]);
                show_offer_dialog(target, originator);
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
                string button = llJsonGetValue(msg, ["button"]);
                
                // Check if this is an offer dialog response
                if (response_session == OfferDialogSession) {
                    handle_offer_response(button);
                    return;
                }
                
                // Otherwise handle menu dialog response
                if (response_session != SessionId) return;
                handle_button_click(button);
                return;
            }
            
            if (msg_type == "dialog_timeout") {
                if (!json_has(msg, ["session_id"])) return;
                
                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                
                // Check if this is an offer dialog timeout
                if (timeout_session == OfferDialogSession) {
                    cleanup_offer_dialog();
                    return;
                }
                
                // Otherwise handle menu dialog timeout
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
        
        list menu_buttons = ["<<", ">>", "Back"] + names;
        
        MenuContext = SensorMode;
        string title = "";
        string body = "";
        
        if (SensorMode == "pass") {
            if (IsOfferMode) {
                title = "Offer Leash";
            }
            else {
                title = "Pass Leash";
            }
            body = "Select avatar:";
        }
        
        show_menu(SensorMode, title, body, menu_buttons);
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
