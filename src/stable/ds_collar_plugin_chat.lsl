/* ===============================================================
   DS Collar - Chat Commands Plugin (v1.0)

   PURPOSE: User interface for chat command configuration

   FEATURES:
   - Enable/disable chat commands
   - Configure command prefix
   - Configure private channel
   - View current configuration
   - ACL-restricted (Trustee+ for configuration)

   COMMUNICATION:
   - Receives chatcmd_state updates from kmod_chatcmd
   - Sends chatcmd_action commands to kmod_chatcmd
   - Uses centralized dialog system (no listen handles)

   CHANNELS:
   - 500: Kernel lifecycle
   - 700: Auth queries
   - 900: UI/command bus
   - 950: Dialog system

   ACL REQUIREMENTS:
   - Configuration: ACL 2+ (Owned, Trustee, Unowned, Owner)
   - View status: ACL 1+ (Public, Owned, Trustee, Unowned, Owner)
   =============================================================== */

integer DEBUG = FALSE;
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_CONTEXT = "core_chatcmd";
string PLUGIN_LABEL = "Chat Cmds";
integer PLUGIN_MIN_ACL = 1;

list ALLOWED_ACL_CONFIG = [2, 3, 4, 5];

/* Current state (synced from kmod) */
integer Enabled = TRUE;
string CommandPrefix = "!";
integer PrivateChannel = 1;

/* Session/menu state */
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";
string MenuContext = "";
integer ChatListen = 0;

/* Command listing state */
list AvailableCommands = [];
integer CommandsPage = 0;
integer COMMANDS_PER_PAGE = 9;

/* ===== HELPERS ===== */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[CHATCMD-UI] " + msg);
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

/* ===== MENU DISPLAY ===== */
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

/* ===== ACL QUERIES ===== */
requestAcl(key user) {
    AclPending = TRUE;
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user
    ]), user);
    logd("ACL query sent for " + llKey2Name(user));
}

/* ===== PLUGIN REGISTRATION ===== */
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

/* ===== MENU SYSTEM ===== */
showMainMenu() {
    list buttons = ["Back"];

    string status_text;
    if (Enabled) {
        status_text = "Enabled: Yes";
        if (inAllowedList(UserAcl, ALLOWED_ACL_CONFIG)) {
            buttons += ["Disable"];
        }
    }
    else {
        status_text = "Enabled: No";
        if (inAllowedList(UserAcl, ALLOWED_ACL_CONFIG)) {
            buttons += ["Enable"];
        }
    }

    buttons += ["Commands"];

    if (inAllowedList(UserAcl, ALLOWED_ACL_CONFIG)) {
        buttons += ["Settings"];
    }

    string body = "Chat Commands\n\n" + status_text + "\n";
    body += "Prefix: " + CommandPrefix + "\n";
    body += "Private Ch: " + (string)PrivateChannel;

    showMenu("main", "Chat Commands", body, buttons);
}

showSettingsMenu() {
    list buttons = ["Back", "Set Prefix", "Set Channel"];

    string body = "Chat Command Settings\n\n";
    body += "Command prefix: " + CommandPrefix + "\n";
    body += "Private channel: " + (string)PrivateChannel + "\n\n";
    body += "Use chat to configure:\n";
    body += "Prefix: Say prefix in chat\n";
    body += "Channel: Say channel number";

    showMenu("settings", "Settings", body, buttons);
}

showCommandsMenu() {
    integer total_cmds = llGetListLength(AvailableCommands);
    integer total_pages = (total_cmds + COMMANDS_PER_PAGE - 1) / COMMANDS_PER_PAGE;

    if (total_pages == 0) total_pages = 1;
    if (CommandsPage >= total_pages) CommandsPage = 0;

    string body = "Available Commands\n";
    body += "(Page " + (string)(CommandsPage + 1) + " of " + (string)total_pages + ")\n\n";
    body += "Prefix: " + CommandPrefix + "\n\n";

    // Button layout follows LSL dialog pattern (bottom-left to top-right)
    // Indexes 0, 1, 2 are reserved for navigation:
    // 0 = back nav (<<), 1 = forward nav (>>), 2 = Back button
    // Navigation uses wrap-around (consistent with other plugins)

    integer start_idx = CommandsPage * COMMANDS_PER_PAGE;
    integer end_idx = start_idx + COMMANDS_PER_PAGE - 1;
    if (end_idx >= total_cmds) end_idx = total_cmds - 1;

    // Collect command buttons for this page
    list cmd_buttons = [];
    if (total_cmds > 0) {
        integer i;
        for (i = start_idx; i <= end_idx && i < total_cmds; i++) {
            string cmd = llList2String(AvailableCommands, i);
            body += CommandPrefix + cmd + "\n";
            cmd_buttons += [cmd];
        }
    }
    else {
        body += "No commands registered yet.";
    }

    // Reverse command buttons so they display top-left to bottom-right
    list reversed_cmds = [];
    integer i = llGetListLength(cmd_buttons) - 1;
    while (i >= 0) {
        reversed_cmds += [llList2String(cmd_buttons, i)];
        i = i - 1;
    }

    // Build final button array: navigation buttons + reversed commands
    list buttons = ["<<", ">>", "Back"] + reversed_cmds;

    showMenu("commands", "Available Commands", body, buttons);
}

/* ===== ACTIONS ===== */
sendChatCmdAction(string action) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_action",
        "action", action
    ]), CurrentUser);
}

sendSetPrefix(string prefix) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_action",
        "action", "set_prefix",
        "prefix", prefix
    ]), CurrentUser);
}

sendSetChannel(integer chan) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_action",
        "action", "set_private_chan",
        "channel", (string)chan
    ]), CurrentUser);
}

queryState() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_action",
        "action", "query_state"
    ]), NULL_KEY);
}

queryCommands() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_action",
        "action", "query_commands"
    ]), CurrentUser);
}

/* ===== BUTTON HANDLERS ===== */
handleButtonClick(string button) {
    logd("Button: " + button + " in context: " + MenuContext);

    if (MenuContext == "main") {
        if (button == "Enable" || button == "Disable") {
            if (inAllowedList(UserAcl, ALLOWED_ACL_CONFIG)) {
                sendChatCmdAction("toggle_enabled");
                queryState();
            }
        }
        else if (button == "Commands") {
            CommandsPage = 0;
            queryCommands();
        }
        else if (button == "Settings") {
            if (inAllowedList(UserAcl, ALLOWED_ACL_CONFIG)) {
                showSettingsMenu();
            }
        }
        else if (button == "Back") {
            returnToRoot();
        }
    }
    else if (MenuContext == "commands") {
        if (button == "<<") {
            integer total_cmds = llGetListLength(AvailableCommands);
            integer total_pages = (total_cmds + COMMANDS_PER_PAGE - 1) / COMMANDS_PER_PAGE;
            if (total_pages == 0) total_pages = 1;

            CommandsPage--;
            if (CommandsPage < 0) CommandsPage = total_pages - 1;  // Wrap to last page
            showCommandsMenu();
        }
        else if (button == ">>") {
            integer total_cmds = llGetListLength(AvailableCommands);
            integer total_pages = (total_cmds + COMMANDS_PER_PAGE - 1) / COMMANDS_PER_PAGE;
            if (total_pages == 0) total_pages = 1;

            CommandsPage++;
            if (CommandsPage >= total_pages) CommandsPage = 0;  // Wrap to first page
            showCommandsMenu();
        }
        else if (button == "Back") {
            showMainMenu();
        }
    }
    else if (MenuContext == "settings") {
        if (button == "Set Prefix") {
            if (ChatListen == 0) {
                ChatListen = llListen(0, "", CurrentUser, "");
            }
            llRegionSayTo(CurrentUser, 0, "Say the new command prefix in chat (1-5 characters):");
            MenuContext = "awaiting_prefix";
        }
        else if (button == "Set Channel") {
            if (ChatListen == 0) {
                ChatListen = llListen(0, "", CurrentUser, "");
            }
            llRegionSayTo(CurrentUser, 0, "Say the new private channel number in chat:");
            MenuContext = "awaiting_channel";
        }
        else if (button == "Back") {
            showMainMenu();
        }
    }
}

/* ===== NAVIGATION ===== */
returnToRoot() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanupSession();
}

cleanupSession() {
    if (ChatListen != 0) {
        llListenRemove(ChatListen);
        ChatListen = 0;
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    AclPending = FALSE;
    SessionId = "";
    MenuContext = "";
    AvailableCommands = [];
    CommandsPage = 0;
    logd("Session cleaned up");
}

/* ===== EVENT HANDLERS ===== */
default
{
    state_entry() {
        cleanupSession();
        registerSelf();
        queryState();
        logd("Chat Commands UI ready (v1.0)");
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    timer() {
        llSetTimerEvent(0.0);
        queryState();
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

            if (msg_type == "chatcmd_state") {
                if (jsonHas(msg, ["enabled"])) {
                    Enabled = (integer)llJsonGetValue(msg, ["enabled"]);
                }
                if (jsonHas(msg, ["prefix"])) {
                    CommandPrefix = llJsonGetValue(msg, ["prefix"]);
                }
                if (jsonHas(msg, ["private_chan"])) {
                    PrivateChannel = (integer)llJsonGetValue(msg, ["private_chan"]);
                }
                logd("State synced");

                if (CurrentUser != NULL_KEY) {
                    if (MenuContext == "main") {
                        showMainMenu();
                    }
                    else if (MenuContext == "settings") {
                        showSettingsMenu();
                    }
                }
                return;
            }

            if (msg_type == "chatcmd_list") {
                if (id != CurrentUser) return;

                AvailableCommands = [];
                if (jsonHas(msg, ["commands"]) && jsonHas(msg, ["count"])) {
                    string commands_json = llJsonGetValue(msg, ["commands"]);
                    integer num_commands = (integer)llJsonGetValue(msg, ["count"]);

                    integer i;
                    for (i = 0; i < num_commands; i++) {
                        string cmd = llJsonGetValue(commands_json, [i]);
                        if (cmd != JSON_INVALID && cmd != "") {
                            AvailableCommands += [cmd];
                        }
                    }
                }

                logd("Received " + (string)llGetListLength(AvailableCommands) + " commands");
                MenuContext = "commands";
                showCommandsMenu();
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
                    MenuContext = "main";
                    logd("ACL received: " + (string)UserAcl + " for " + llKey2Name(avatar));
                    queryState();
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
                if (response_session != SessionId) return;

                string button = llJsonGetValue(msg, ["button"]);
                handleButtonClick(button);
                return;
            }

            if (msg_type == "dialog_timeout") {
                if (!jsonHas(msg, ["session_id"])) return;

                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                if (timeout_session != SessionId) return;

                logd("Dialog timeout");
                cleanupSession();
                return;
            }
            return;
        }
    }

    listen(integer channel, string speaker_name, key speaker, string msg_text) {
        if (speaker != CurrentUser) return;
        if (MenuContext != "awaiting_prefix" && MenuContext != "awaiting_channel") return;

        if (!inAllowedList(UserAcl, ALLOWED_ACL_CONFIG)) return;

        string trimmed = llStringTrim(msg_text, STRING_TRIM);

        if (MenuContext == "awaiting_prefix") {
            integer len = llStringLength(trimmed);
            if (len < 1 || len > 5) {
                llRegionSayTo(CurrentUser, 0, "Prefix must be 1-5 characters. Try again or close the menu.");
                return;
            }
            sendSetPrefix(trimmed);
            if (ChatListen != 0) {
                llListenRemove(ChatListen);
                ChatListen = 0;
            }
            MenuContext = "settings";
            queryState();
        }
        else if (MenuContext == "awaiting_channel") {
            integer chan = (integer)trimmed;
            // Local validation for immediate feedback (kernel also validates)
            if (chan <= 0) {
                llRegionSayTo(CurrentUser, 0, "Channel must be a positive number. Try again or close the menu.");
                return;
            }
            sendSetChannel(chan);
            if (ChatListen != 0) {
                llListenRemove(ChatListen);
                ChatListen = 0;
            }
            MenuContext = "settings";
            queryState();
        }
    }
}
