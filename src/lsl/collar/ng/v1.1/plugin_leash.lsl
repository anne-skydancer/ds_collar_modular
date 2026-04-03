/*--------------------
PLUGIN: plugin_leash.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: User interface and configuration for the leashing system
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded ALLOWED_ACL_* lists and inAllowedList() with policy reads.
  Button list built from get_policy_buttons() + state-dependent logic.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_leash";
string PLUGIN_LABEL = "Leash";

/* -------------------- CONFIGURATION -------------------- */
float STATE_QUERY_DELAY = 0.5;  // 500ms delay for non-blocking state queries

/* -------------------- STATE -------------------- */
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
list gPolicyButtons = [];  // Cached policy buttons for current user's ACL
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

// Registration state (SYN/ACK pattern for active discovery)
integer IsRegistered = FALSE;

/* -------------------- HELPERS -------------------- */


string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD POLICY HELPER -------------------- */
list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("policy:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}


/* -------------------- UNIFIED MENU DISPLAY -------------------- */
showMenu(string context, string title, string body, list buttons) {
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

/* -------------------- PLUGIN REGISTRATION -------------------- */
register_self() {
    // Write button visibility policy to LSD (default-deny per ACL level)
    llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Clip,Post,Get Holder,Settings",
        "2", "Offer",
        "3", "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings",
        "4", "Clip,Unclip,Pass,Yank,Coffle,Post,Get Holder,Settings",
        "5", "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings"
    ]));

    // Register with kernel
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- MENU SYSTEM -------------------- */
showMainMenu() {
    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    list buttons = ["Back"];

    // Action buttons — policy defines the superset, state logic narrows
    if (!Leashed) {
        if (btn_allowed("Clip"))    buttons += ["Clip"];
        if (btn_allowed("Offer"))   buttons += ["Offer"];
        if (btn_allowed("Coffle"))  buttons += ["Coffle"];
    }
    else {
        // Unclip: policy + must be leasher or ACL 3+
        if (btn_allowed("Unclip") && (CurrentUser == Leasher || UserAcl >= 3)) {
            buttons += ["Unclip"];
        }
        // Pass/Yank: policy + must be current leasher
        if (CurrentUser == Leasher) {
            if (btn_allowed("Pass")) buttons += ["Pass"];
            if (btn_allowed("Yank")) buttons += ["Yank"];
        }
        // Take: policy + not current leasher + ACL 3+
        if (btn_allowed("Take") && CurrentUser != Leasher && UserAcl >= 3) {
            buttons += ["Take"];
        }
    }
    // Post: available regardless of leash state
    if (btn_allowed("Post"))    buttons += ["Post"];

    if (btn_allowed("Get Holder")) buttons += ["Get Holder"];
    if (btn_allowed("Settings"))   buttons += ["Settings"];

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

    key wearer = llGetOwner();
    SensorCandidates = [];
    integer i = 0;
    integer count = 0;

    while (i < llGetListLength(nearby) && count < 9) {
        key detected = llList2Key(nearby, i);
        if (detected != wearer && detected != Leasher) {
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

/* -------------------- OFFER DIALOG (NEW v1.0) -------------------- */
showOfferDialog(key target, key originator) {
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
    
}

handleOfferResponse(string button) {
    if (button == "Accept") {
        // Send grab action to kernel with target as leasher
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type", "leash_action",
            "action", "grab"
        ]), OfferTarget);
        
        llRegionSayTo(OfferOriginator, 0, llKey2Name(OfferTarget) + " accepted your leash offer.");
    }
    else {
        llRegionSayTo(OfferOriginator, 0, llKey2Name(OfferTarget) + " declined your leash offer.");
        llRegionSayTo(OfferTarget, 0, "You declined the leash offer.");
    }
    
    // Clear offer state
    OfferDialogSession = "";
    OfferTarget = NULL_KEY;
    OfferOriginator = NULL_KEY;
}

cleanupOfferDialog() {
    if (OfferDialogSession != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "dialog_close",
            "session_id", OfferDialogSession
        ]), NULL_KEY);
    }
    if (OfferOriginator != NULL_KEY) {
        llRegionSayTo(OfferOriginator, 0, "Leash offer to " + llKey2Name(OfferTarget) + " timed out.");
    }
    OfferDialogSession = "";
    OfferTarget = NULL_KEY;
    OfferOriginator = NULL_KEY;
}

/* -------------------- ACTIONS -------------------- */
giveHolderObject() {
    // Policy-driven: Get Holder must be in the allowed buttons list
    if (!btn_allowed("Get Holder")) {
        llRegionSayTo(CurrentUser, 0, "Access denied: Insufficient permissions to receive leash holder.");
        return;
    }

    string holder_name = "D/s Collar leash holder";
    if (llGetInventoryType(holder_name) != INVENTORY_OBJECT) {
        llRegionSayTo(CurrentUser, 0, "Error: Holder object not found in collar inventory.");
        return;
    }
    llGiveInventory(CurrentUser, holder_name);
    llRegionSayTo(CurrentUser, 0, "Leash holder given.");
}

sendLeashAction(string action) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", action
    ]), CurrentUser);
}

sendLeashActionWithTarget(string action, key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", action,
        "target", (string)target
    ]), CurrentUser);
}

sendSetLength(integer length) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash_action",
        "action", "set_length",
        "length", (string)length
    ]), CurrentUser);
}

/* -------------------- BUTTON HANDLERS -------------------- */
handleButtonClick(string button) {
    
    if (MenuContext == "main") {
        if (button == "Clip" || button == "Take") {
            if (btn_allowed(button)) {
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

/* -------------------- NAVIGATION -------------------- */
returnToRoot() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanupSession();
}

cleanupSession() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "dialog_close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    MenuContext = "";
    SensorMode = "";
    SensorCandidates = [];
    SensorPage = 0;
    IsOfferMode = FALSE;
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
}

/* -------------------- EVENT HANDLERS -------------------- */
default
{
    state_entry() {
        cleanupSession();
        register_self();
        queryState();
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
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "register_now") {
                register_self();
                IsRegistered = TRUE;
                return;
            }
            if (msg_type == "ping") {
                send_pong();
                return;
            }
            return;
        }

        if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "start") {
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                CurrentUser = id;
                UserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                scheduleStateQuery("main");
                return;
            }

            if (msg_type == "leash_state") {
                string tmp = llJsonGetValue(msg, ["leashed"]);
                if (tmp != JSON_INVALID) {
                    Leashed = (integer)tmp;
                }
                tmp = llJsonGetValue(msg, ["leasher"]);
                if (tmp != JSON_INVALID) {
                    Leasher = (key)tmp;
                }
                tmp = llJsonGetValue(msg, ["length"]);
                if (tmp != JSON_INVALID) {
                    LeashLength = (integer)tmp;
                }
                tmp = llJsonGetValue(msg, ["turnto"]);
                if (tmp != JSON_INVALID) {
                    TurnToFace = (integer)tmp;
                }
                tmp = llJsonGetValue(msg, ["mode"]);
                if (tmp != JSON_INVALID) {
                    LeashMode = (integer)tmp;
                }
                tmp = llJsonGetValue(msg, ["target"]);
                if (tmp != JSON_INVALID) {
                    LeashTarget = (key)tmp;
                }

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
                }
                return;
            }

            if (msg_type == "offer_pending") {
                if (llJsonGetValue(msg, ["target"]) == JSON_INVALID || llJsonGetValue(msg, ["originator"]) == JSON_INVALID) return;
                key target = (key)llJsonGetValue(msg, ["target"]);
                key originator = (key)llJsonGetValue(msg, ["originator"]);
                showOfferDialog(target, originator);
                return;
            }
        }

        if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "dialog_response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;
                
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
                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                if (timeout_session == JSON_INVALID) return;
                
                // Check if this is an offer dialog timeout
                if (timeout_session == OfferDialogSession) {
                    cleanupOfferDialog();
                    return;
                }
                
                // Otherwise handle menu dialog timeout
                if (timeout_session != SessionId) return;
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

        key wearer = llGetOwner();
        key my_key = llGetKey();
        SensorCandidates = [];
        integer i = 0;

        // Detect ALL objects for coffle/post (no limit, we'll paginate)
        while (i < num) {
            key detected = llDetectedKey(i);
            // Exclude self (collar) and wearer
            if (detected != my_key && detected != wearer) {
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
