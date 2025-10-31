/* ===============================================================
   DS Collar - Leash Plugin (v2.0 MULTI-MODE)

   PURPOSE: User interface and configuration for leashing system

   NEW FEATURES v2.0:
   - Added Coffle mode (collar-to-collar leashing, ACL 3,5 only)
   - Added Post mode (leash to object, ACL 1,3,5)
   - Uses llGetAgentList for avatar detection (Pass/Offer) - more efficient
   - Sensor only used for object detection (Coffle/Post)

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

float STATE_QUERY_DELAY = 0.15;  // 150ms delay for non-blocking state queries

string PLUGIN_CONTEXT = "core_leash";
string PLUGIN_LABEL = "Leash";
integer PLUGIN_MIN_ACL = 1;
string ROOT_CONTEXT = "core_root";

list ALLOWED_ACL_GRAB  = [1, 3, 4, 5];
list ALLOWED_ACL_SETTINGS = [3, 4, 5];
list ALLOWED_ACL_COFFLE = [3, 5];   // Trustee, Owner
list ALLOWED_ACL_POST = [1, 3, 5];  // Public, Trustee, Owner

// Current leash state (synced from core)
integer Leashed = FALSE;
key Leasher = NULL_KEY;
integer LeashLength = 3;
integer TurnToFace = FALSE;
integer LeashMode = 0;       // 0=avatar, 1=coffle, 2=post
key LeashTarget = NULL_KEY;  // Target for coffle/post

// Session/menu state
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";
string MenuContext = "";
string SensorMode = "";
list SensorCandidates = [];
integer SensorPage = 0;  // Current page for sensor results (0-based)
integer IsOfferMode = FALSE;  // TRUE if ACL 2 offering, FALSE if higher ACL passing

// Offer dialog state (NEW v1.0)
string OfferDialogSession = "";
key OfferTarget = NULL_KEY;
key OfferOriginator = NULL_KEY;

// State query tracking (event-driven, no blocking llSleep)
integer PendingStateQuery = FALSE;
string PendingQueryContext = "";  // Which menu to show after query completes

// ===== HELPERS =====
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[LEASH-CFG] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generateSessionId() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

integer inAllowedList(integer level, list allowed) {
    return (llListFindList(allowed, [level]) != -1);
}

// ===== UNIFIED MENU DISPLAY =====
showMenu(string context, string title, string body, list buttons) {
    SessionId = generateSessionId();
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
requestAcl(key user) {
    AclPending = TRUE;
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user
    ]), user);
    logd("ACL query sent for " + llKey2Name(user));
}

// ===== PLUGIN REGISTRATION =====
registerSelf() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

sendPong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

// ===== MENU SYSTEM =====
showMainMenu() {
    // Build buttons in display order (left-to-right, top-to-bottom)
    list buttons = ["Back"];

    // Action buttons
    if (!Leashed) {
        if (inAllowedList(UserAcl, ALLOWED_ACL_GRAB)) {
            buttons += ["Clip"];
        }
        if (UserAcl == 2) {
            buttons += ["Offer"];
        }
        // Coffle button - ACL 3, 5 only
        if (inAllowedList(UserAcl, ALLOWED_ACL_COFFLE)) {
            buttons += ["Coffle"];
        }
        // Post button - ACL 1, 3, 5
        if (inAllowedList(UserAcl, ALLOWED_ACL_POST)) {
            buttons += ["Post"];
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
    if (UserAcl == 1 || inAllowedList(UserAcl, ALLOWED_ACL_SETTINGS)) {
        buttons += ["Settings"];
    }

    string body;
    if (Leashed) {
        string mode_text = "Avatar";
        if (LeashMode == 1) mode_text = "Coffle";
        else if (LeashMode == 2) mode_text = "Post";

        body = "Mode: " + mode_text + "\n";
        body += "Leashed to: " + llKey2Name(Leasher) + "\n";
        body += "Length: " + (string)LeashLength + "m";

        if (LeashTarget != NULL_KEY) {
            list details = llGetObjectDetails(LeashTarget, [OBJECT_NAME]);
            if (llGetListLength(details) > 0) {
                body += "\nTarget: " + llList2String(details, 0);
            }
        }
    }
    else {
        body = "Not leashed";
    }

    showMenu("main", "Leash", body, buttons);
}

showSettingsMenu() {
    list buttons = ["Back", "Length"];
    if (TurnToFace) {
        buttons += ["Turn: On"];
    }
    else {
        buttons += ["Turn: Off"];
    }
    
    string body = "Leash Settings\nLength: " + (string)LeashLength + "m\nTurn to face: " + (string)TurnToFace;
    showMenu("settings", "Settings", body, buttons);
}

showLengthMenu() {
    showMenu("length", "Length", "Select leash length\nCurrent: " + (string)LeashLength + "m", 
              ["<<", ">>", "Back", "1m", "3m", "5m", "10m", "15m", "20m"]);
}

showPassMenu() {
    SensorMode = "pass";
    MenuContext = "pass";
    buildAvatarMenu();
}

buildAvatarMenu() {
    // Use llGetAgentList for nearby avatars (more efficient than sensor)
    list nearby = llGetAgentList(AGENT_LIST_PARCEL, []);

    key owner = llGetOwner();
    SensorCandidates = [];
    integer i = 0;
    integer count = 0;

    while (i < llGetListLength(nearby) && count < 9) {
        key detected = llList2Key(nearby, i);
        if (detected != owner && detected != Leasher) {
            string name = llKey2Name(detected);
            SensorCandidates += [name, detected];
            count++;
        }
        i++;
    }

    if (llGetListLength(SensorCandidates) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        showMainMenu();
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

    string title = "";
    if (IsOfferMode) {
        title = "Offer Leash";
    }
    else {
        title = "Pass Leash";
    }

    showMenu("pass", title, "Select avatar:", menu_buttons);
}

showCoffleMenu() {
    SensorMode = "coffle";
    MenuContext = "coffle";
    SensorPage = 0;
    SensorCandidates = [];  // Clear previous results
    // Scan for objects (potential collars) within range
    llSensor("", NULL_KEY, SCRIPTED, 96.0, PI);
}

showPostMenu() {
    SensorMode = "post";
    MenuContext = "post";
    SensorPage = 0;
    SensorCandidates = [];  // Clear previous results
    // Scan for all objects (posts) within range
    llSensor("", NULL_KEY, PASSIVE | ACTIVE | SCRIPTED, 96.0, PI);
}

// Display paginated object menu from existing SensorCandidates
// Used for pagination navigation without re-scanning
displayObjectMenu() {
    if (llGetListLength(SensorCandidates) == 0) return;

    // Calculate pagination (9 items per page)
    integer total_items = llGetListLength(SensorCandidates) / 2;
    integer total_pages = (total_items + 8) / 9;  // Ceiling division
    integer start_index = SensorPage * 9;
    integer end_index = start_index + 9;
    if (end_index > total_items) end_index = total_items;

    // Build numbered list body text
    string body = "";
    integer i = start_index;
    integer display_num = 1;
    while (i < end_index) {
        string obj_name = llList2String(SensorCandidates, i * 2);
        body += (string)display_num + ". " + obj_name + "\n";
        display_num++;
        i++;
    }

    // Build numbered buttons (only for items on this page)
    list menu_buttons = ["<<", ">>", "Back"];
    i = 1;
    while (i <= (end_index - start_index)) {
        menu_buttons += [(string)i];
        i++;
    }

    // Add pagination info to body
    if (total_pages > 1) {
        body += "\nPage " + (string)(SensorPage + 1) + "/" + (string)total_pages;
    }

    string title = "";
    if (SensorMode == "coffle") {
        title = "Coffle";
    }
    else if (SensorMode == "post") {
        title = "Post";
    }

    showMenu(SensorMode, title, body, menu_buttons);
}

// ===== OFFER DIALOG (NEW v1.0) =====
showOfferDialog(key target, key originator) {
    OfferDialogSession = generateSessionId();
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

handleOfferResponse(string button) {
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

cleanupOfferDialog() {
    if (OfferOriginator != NULL_KEY) {
        llRegionSayTo(OfferOriginator, 0, "Leash offer to " + llKey2Name(OfferTarget) + " timed out.");
    }
    OfferDialogSession = "";
    OfferTarget = NULL_KEY;
    OfferOriginator = NULL_KEY;
    logd("Offer dialog timed out");
}

// ===== ACTIONS =====
giveHolderObject() {
    // ACL check: Allow ACL 1 (public) and ACL 3+ (trustee/owner)
    // Deny ACL 2 (owned wearer) as per design
    // Deny ACL 0 (no access) and ACL -1 (blacklisted)
    if (UserAcl == 2 || UserAcl < 1) {
        llRegionSayTo(CurrentUser, 0, "Access denied: Insufficient permissions to receive leash holder.");
        logd("Holder request denied for ACL " + (string)UserAcl);
        return;
    }

    string holder_name = "D/s Collar leash holder";
    if (llGetInventoryType(holder_name) != INVENTORY_OBJECT) {
        llRegionSayTo(CurrentUser, 0, "Error: Holder object not found in collar inventory.");
        logd("Holder object not in inventory");
        return;
    }
    llGiveInventory(CurrentUser, holder_name);
    llRegionSayTo(CurrentUser, 0, "Leash holder given.");
    logd("Gave holder to " + llKey2Name(CurrentUser) + " (ACL " + (string)UserAcl + ")");}


sendLeashAction(string action) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", action,
        "acl_verified", "1"
    ]), CurrentUser);
}

sendLeashActionWithTarget(string action, key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", action,
        "target", (string)target,
        "acl_verified", "1"
    ]), CurrentUser);
}

sendSetLength(integer length) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", "set_length",
        "length", (string)length,
        "acl_verified", "1"
    ]), CurrentUser);
}

// ===== BUTTON HANDLERS =====
handleButtonClick(string button) {
    logd("Button: " + button + " in context: " + MenuContext);
    
    if (MenuContext == "main") {
        if (button == "Clip") {
            if (inAllowedList(UserAcl, ALLOWED_ACL_GRAB)) {
                sendLeashAction("grab");
                cleanupSession();
            }
        }
        else if (button == "Unclip") {
            sendLeashAction("release");
            cleanupSession();
        }
        else if (button == "Pass") {
            IsOfferMode = FALSE;
            showPassMenu();
        }
        else if (button == "Offer") {
            IsOfferMode = TRUE;
            showPassMenu();
        }
        else if (button == "Coffle") {
            showCoffleMenu();
        }
        else if (button == "Post") {
            showPostMenu();
        }
        else if (button == "Yank") {
            sendLeashAction("yank");
            showMainMenu();
        }
        else if (button == "Get Holder") {
            giveHolderObject();
            showMainMenu();
        }
        else if (button == "Settings") {
            showSettingsMenu();
        }
        else if (button == "Back") {
            returnToRoot();
        }
    }
    else if (MenuContext == "settings") {
        if (button == "Length") {
            showLengthMenu();
        }
        else if (button == "Turn: On" || button == "Turn: Off") {
            sendLeashAction("toggle_turn");
            scheduleStateQuery("settings");
        }
        else if (button == "Back") {
            showMainMenu();
        }
    }
    else if (MenuContext == "length") {
        if (button == "Back") {
            showSettingsMenu();
        }
        else if (button == "<<") {
            sendSetLength(LeashLength - 1);
            scheduleStateQuery("length");
        }
        else if (button == ">>") {
            sendSetLength(LeashLength + 1);
            scheduleStateQuery("length");
        }
        else {
            integer length = (integer)button;
            if (length >= 1 && length <= 20) {
                sendSetLength(length);
                scheduleStateQuery("settings");
            }
        }
    }
    else if (MenuContext == "pass") {
        if (button == "Back") {
            showMainMenu();
        }
        else if (button == "<<" || button == ">>") {
            showPassMenu();
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
                sendLeashActionWithTarget(action, selected);
                cleanupSession();
            }
            else {
                llRegionSayTo(CurrentUser, 0, "Avatar not found.");
                showMainMenu();
            }
        }
    }
    else if (MenuContext == "coffle") {
        if (button == "Back") {
            showMainMenu();
        }
        else if (button == "<<") {
            // Previous page
            if (SensorPage > 0) {
                SensorPage--;
            }
            displayObjectMenu();
        }
        else if (button == ">>") {
            // Next page
            integer total_items = llGetListLength(SensorCandidates) / 2;
            integer total_pages = (total_items + 8) / 9;
            if (SensorPage < (total_pages - 1)) {
                SensorPage++;
            }
            displayObjectMenu();
        }
        else {
            // Numbered selection - convert to actual index
            integer button_num = (integer)button;
            if (button_num >= 1 && button_num <= 9) {
                integer actual_index = (SensorPage * 9) + (button_num - 1);
                integer list_index = actual_index * 2;  // SensorCandidates is [name, key, name, key, ...]

                if (list_index < llGetListLength(SensorCandidates)) {
                    key selected = llList2Key(SensorCandidates, list_index + 1);
                    sendLeashActionWithTarget("coffle", selected);
                    cleanupSession();
                }
                else {
                    llRegionSayTo(CurrentUser, 0, "Invalid selection.");
                    showMainMenu();
                }
            }
            else {
                llRegionSayTo(CurrentUser, 0, "Invalid selection.");
                showMainMenu();
            }
        }
    }
    else if (MenuContext == "post") {
        if (button == "Back") {
            showMainMenu();
        }
        else if (button == "<<") {
            // Previous page
            if (SensorPage > 0) {
                SensorPage--;
            }
            displayObjectMenu();
        }
        else if (button == ">>") {
            // Next page
            integer total_items = llGetListLength(SensorCandidates) / 2;
            integer total_pages = (total_items + 8) / 9;
            if (SensorPage < (total_pages - 1)) {
                SensorPage++;
            }
            displayObjectMenu();
        }
        else {
            // Numbered selection - convert to actual index
            integer button_num = (integer)button;
            if (button_num >= 1 && button_num <= 9) {
                integer actual_index = (SensorPage * 9) + (button_num - 1);
                integer list_index = actual_index * 2;  // SensorCandidates is [name, key, name, key, ...]

                if (list_index < llGetListLength(SensorCandidates)) {
                    key selected = llList2Key(SensorCandidates, list_index + 1);
                    sendLeashActionWithTarget("post", selected);
                    cleanupSession();
                }
                else {
                    llRegionSayTo(CurrentUser, 0, "Invalid selection.");
                    showMainMenu();
                }
            }
            else {
                llRegionSayTo(CurrentUser, 0, "Invalid selection.");
                showMainMenu();
            }
        }
    }
}

// ===== NAVIGATION =====
returnToRoot() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanupSession();
}

cleanupSession() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    AclPending = FALSE;
    SessionId = "";
    MenuContext = "";
    SensorMode = "";
    SensorCandidates = [];
    SensorPage = 0;
    IsOfferMode = FALSE;
    logd("Session cleaned up");
}

queryState() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", "query_state"
    ]), NULL_KEY);
}

// Schedule a state query after brief delay, then show specified menu
// Replaces blocking llSleep() + queryState() pattern
scheduleStateQuery(string next_menu_context) {
    PendingStateQuery = TRUE;
    PendingQueryContext = next_menu_context;
    llSetTimerEvent(STATE_QUERY_DELAY);
    logd("Scheduled state query, will show: " + next_menu_context);
}

// ===== EVENT HANDLERS =====
default
{
    state_entry() {
        cleanupSession();
        registerSelf();
        queryState();
        logd("Leash UI ready (v2.0 MULTI-MODE)");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    timer() {
        // Handle pending state query (replaces blocking llSleep pattern)
        if (PendingStateQuery) {
            PendingStateQuery = FALSE;
            llSetTimerEvent(0.0);  // Stop timer
            queryState();
            // Menu will be shown when leash_state response arrives
            logd("Timer fired: querying state for " + PendingQueryContext);
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == KERNEL_LIFECYCLE) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "register_now") {
                registerSelf();
                return;
            }
            if (msg_type == "ping") {
                sendPong();
                return;
            }
            return;
        }
        
        if (num == UI_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "start") {
                if (!jsonHas(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                CurrentUser = id;
                requestAcl(id);
                return;
            }
            
            if (msg_type == "leash_state") {
                if (jsonHas(msg, ["leashed"])) {
                    Leashed = (integer)llJsonGetValue(msg, ["leashed"]);
                }
                if (jsonHas(msg, ["leasher"])) {
                    Leasher = (key)llJsonGetValue(msg, ["leasher"]);
                }
                if (jsonHas(msg, ["length"])) {
                    LeashLength = (integer)llJsonGetValue(msg, ["length"]);
                }
                if (jsonHas(msg, ["turnto"])) {
                    TurnToFace = (integer)llJsonGetValue(msg, ["turnto"]);
                }
                if (jsonHas(msg, ["mode"])) {
                    LeashMode = (integer)llJsonGetValue(msg, ["mode"]);
                }
                if (jsonHas(msg, ["target"])) {
                    LeashTarget = (key)llJsonGetValue(msg, ["target"]);
                }
                logd("State synced");

                // If we were waiting for state update, show the pending menu
                if (PendingQueryContext != "") {
                    string menu_to_show = PendingQueryContext;
                    PendingQueryContext = "";  // Clear before showing menu

                    if (menu_to_show == "settings") {
                        showSettingsMenu();
                    }
                    else if (menu_to_show == "length") {
                        showLengthMenu();
                    }
                    else if (menu_to_show == "main") {
                        showMainMenu();
                    }
                    logd("Showed pending menu: " + menu_to_show);
                }
                return;
            }
            
            if (msg_type == "offer_pending") {
                if (!jsonHas(msg, ["target"]) || !jsonHas(msg, ["originator"])) return;
                key target = (key)llJsonGetValue(msg, ["target"]);
                key originator = (key)llJsonGetValue(msg, ["originator"]);
                showOfferDialog(target, originator);
                return;
            }
        }
        
        if (num == AUTH_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "acl_result") {
                if (!AclPending) return;
                if (!jsonHas(msg, ["avatar"])) return;
                
                key avatar = (key)llJsonGetValue(msg, ["avatar"]);
                if (avatar != CurrentUser) return;
                
                if (jsonHas(msg, ["level"])) {
                    UserAcl = (integer)llJsonGetValue(msg, ["level"]);
                    AclPending = FALSE;
                    scheduleStateQuery("main");
                    logd("ACL received: " + (string)UserAcl + " for " + llKey2Name(avatar));
                }
                return;
            }
            return;
        }
        
        if (num == DIALOG_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "dialog_response") {
                if (!jsonHas(msg, ["session_id"]) || !jsonHas(msg, ["button"])) return;
                
                string response_session = llJsonGetValue(msg, ["session_id"]);
                string button = llJsonGetValue(msg, ["button"]);
                
                // Check if this is an offer dialog response
                if (response_session == OfferDialogSession) {
                    handleOfferResponse(button);
                    return;
                }
                
                // Otherwise handle menu dialog response
                if (response_session != SessionId) return;
                handleButtonClick(button);
                return;
            }
            
            if (msg_type == "dialog_timeout") {
                if (!jsonHas(msg, ["session_id"])) return;
                
                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                
                // Check if this is an offer dialog timeout
                if (timeout_session == OfferDialogSession) {
                    cleanupOfferDialog();
                    return;
                }
                
                // Otherwise handle menu dialog timeout
                if (timeout_session != SessionId) return;
                logd("Dialog timeout");
                cleanupSession();
                return;
            }
            return;
        }
    }
    
    sensor(integer num) {
        // Sensor only used for coffle and post (object detection)
        // Avatar detection uses llGetAgentList instead
        if (SensorMode == "") return;
        if (CurrentUser == NULL_KEY) return;
        if (SensorMode != "coffle" && SensorMode != "post") return;

        key owner = llGetOwner();
        key my_key = llGetKey();
        SensorCandidates = [];
        integer i = 0;

        // Detect ALL objects for coffle/post (no limit, we'll paginate)
        while (i < num) {
            key detected = llDetectedKey(i);
            // Exclude self (collar) and owner avatar
            if (detected != my_key && detected != owner) {
                string name = llDetectedName(i);
                SensorCandidates += [name, detected];
            }
            i = i + 1;
        }

        if (llGetListLength(SensorCandidates) == 0) {
            if (SensorMode == "coffle") {
                llRegionSayTo(CurrentUser, 0, "No nearby objects found for coffle.");
            }
            else if (SensorMode == "post") {
                llRegionSayTo(CurrentUser, 0, "No nearby objects found to post to.");
            }
            showMainMenu();
            SensorMode = "";
            return;
        }

        // Display the menu (starts at page 0)
        displayObjectMenu();
    }
    
    no_sensor() {
        // Only handles coffle and post (pass/offer use llGetAgentList)
        if (SensorMode == "") return;
        if (CurrentUser == NULL_KEY) return;
        if (SensorMode != "coffle" && SensorMode != "post") return;

        if (SensorMode == "coffle") {
            llRegionSayTo(CurrentUser, 0, "No nearby objects found for coffle.");
        }
        else if (SensorMode == "post") {
            llRegionSayTo(CurrentUser, 0, "No nearby objects found to post to.");
        }
        showMainMenu();
        SensorMode = "";
    }
}
