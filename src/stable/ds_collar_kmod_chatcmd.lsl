/* ===============================================================
   DS Collar - Chat Command Kernel Module (v1.0)

   PURPOSE: Generic chat command routing infrastructure

   FEATURES:
   - Listens on channel 0 (public, toggleable) and private channel (always active)
   - Generic command registry (plugins register their commands)
   - Routes commands to appropriate plugin via UI_BUS
   - ACL verification before routing
   - Persistent settings (enabled, prefix, private channel)

   ARCHITECTURE:
   - Kernel module (infrastructure, not a plugin)
   - Receives routed commands from kernel (kernel extracts from registration)
   - Module routes commands back to plugins via chatcmd_invoke
   - Plugin handles ACL and execution logic
   - Configuration plugin controls enable/prefix/channel

   CHANNELS:
   - 700: Auth queries
   - 800: Settings persistence
   - 900: UI/command bus (receives chatcmd_register from kernel)
   - 0: Public chat (toggleable via Enabled flag)
   - Configurable: Private chat channel (always active, default 1)

   COMMAND REGISTRY:
   - Stride list: [command_name, plugin_context, command_name, plugin_context, ...]
   - Example: ["grab", "core_leash", "release", "core_leash", "bell", "core_bell"]

   PROTOCOL:
   Plugin registers (includes optional commands field):
   {
     "type": "register",
     "context": "core_leash",
     "label": "Leash",
     "min_acl": 1,
     "script": "ds_collar_plugin_leash.lsl",
     "commands": ["grab", "release", "yank", "length"]
   }

   Module routes to plugin:
   {
     "type": "chatcmd_invoke",
     "command": "grab",
     "args": ["arg1", "arg2"],
     "user": "<uuid>",
     "acl_level": 3
   }

   SECURITY:
   - ACL verification before routing
   - Public chat (ch 0): Toggleable for security
   - Private chat: Always active for accessibility

   SETTINGS KEYS:
   - chatcmd_enabled: 0/1 (controls public channel 0 listener only)
   - chatcmd_prefix: Command prefix string
   - chatcmd_private_chan: Private channel number (always active)
   =============================================================== */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;

integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* Settings keys */
string KEY_ENABLED = "chatcmd_enabled";
string KEY_PREFIX = "chatcmd_prefix";
string KEY_PRIVATE_CHAN = "chatcmd_private_chan";

/* Chat command state */
integer Enabled = TRUE;
string CommandPrefix = "!";
integer PrivateChannel = 1;

/* Listen handles */
integer ListenPublic = 0;
integer ListenPrivate = 0;

/* Command registry: [command_name, plugin_context, command_name, plugin_context, ...] */
list CommandRegistry = [];

/* ACL verification state */
key PendingCommandUser = NULL_KEY;
string PendingCommand = "";
list PendingArgs = [];
integer AclPending = FALSE;

/* ===== HELPERS ===== */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[CHATCMD-KMOD] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string jsonGet(string j, string k, string default_val) {
    if (jsonHas(j, [k])) return llJsonGetValue(j, [k]);
    return default_val;
}

/* ===== COMMAND REGISTRY ===== */
registerCommand(string command_name, string plugin_context) {
    string cmd_lower = llToLower(command_name);

    integer idx = llListFindList(CommandRegistry, [cmd_lower]);
    if (idx != -1) {
        CommandRegistry = llListReplaceList(CommandRegistry, [plugin_context], idx + 1, idx + 1);
        logd("Updated command: " + cmd_lower + " -> " + plugin_context);
    }
    else {
        CommandRegistry += [cmd_lower, plugin_context];
        logd("Registered command: " + cmd_lower + " -> " + plugin_context);
    }
}

string findPluginForCommand(string command_name) {
    string cmd_lower = llToLower(command_name);
    integer idx = llListFindList(CommandRegistry, [cmd_lower]);

    if (idx == -1) return "";

    return llList2String(CommandRegistry, idx + 1);
}

/* ===== LISTEN MANAGEMENT ===== */
setupListeners() {
    closeListeners();

    // Public listener (channel 0) is toggleable via Enabled flag
    if (Enabled) {
        ListenPublic = llListen(0, "", NULL_KEY, "");
        logd("Listening on channel 0 (public)");
    }

    // Private listener is always active (channel is configurable)
    if (PrivateChannel != 0) {
        ListenPrivate = llListen(PrivateChannel, "", NULL_KEY, "");
        logd("Listening on channel " + (string)PrivateChannel + " (private)");
    }
}

closeListeners() {
    if (ListenPublic != 0) {
        llListenRemove(ListenPublic);
        ListenPublic = 0;
    }
    if (ListenPrivate != 0) {
        llListenRemove(ListenPrivate);
        ListenPrivate = 0;
    }
    logd("Listeners closed");
}

/* ===== SETTINGS PERSISTENCE ===== */
persistSetting(string setting_key, string value) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", setting_key,
        "value", value
    ]), NULL_KEY);
}

persistEnabled(integer enabled) {
    persistSetting(KEY_ENABLED, (string)enabled);
}

persistPrefix(string prefix) {
    persistSetting(KEY_PREFIX, prefix);
}

persistPrivateChannel(integer chan) {
    persistSetting(KEY_PRIVATE_CHAN, (string)chan);
}

applySettingsSync(string msg) {
    if (!jsonHas(msg, ["settings"])) return;
    string settings_json = llJsonGetValue(msg, ["settings"]);

    integer had_enabled_setting = FALSE;
    if (jsonHas(settings_json, [KEY_ENABLED])) {
        Enabled = (integer)llJsonGetValue(settings_json, [KEY_ENABLED]);
        had_enabled_setting = TRUE;
    }
    else {
        // No persisted setting - use default TRUE and persist it
        Enabled = TRUE;
        persistEnabled(Enabled);
    }

    if (jsonHas(settings_json, [KEY_PREFIX])) {
        CommandPrefix = llJsonGetValue(settings_json, [KEY_PREFIX]);
        if (CommandPrefix == "") CommandPrefix = "!";
    }
    if (jsonHas(settings_json, [KEY_PRIVATE_CHAN])) {
        PrivateChannel = (integer)llJsonGetValue(settings_json, [KEY_PRIVATE_CHAN]);
    }

    setupListeners();
    logd("Settings loaded: enabled=" + (string)Enabled + " prefix=" + CommandPrefix + " chan=" + (string)PrivateChannel);
}

applySettingsDelta(string msg) {
    string setting_key = jsonGet(msg, "key", "");
    string value = jsonGet(msg, "value", "");

    if (setting_key != "" && value != "") {
        if (setting_key == KEY_ENABLED) {
            Enabled = (integer)value;
            setupListeners();
        }
        else if (setting_key == KEY_PREFIX) {
            CommandPrefix = value;
            if (CommandPrefix == "") CommandPrefix = "!";
        }
        else if (setting_key == KEY_PRIVATE_CHAN) {
            PrivateChannel = (integer)value;
            setupListeners();
        }
    }
}

/* ===== STATE BROADCAST ===== */
broadcastState() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "chatcmd_state",
        "enabled", (string)Enabled,
        "prefix", CommandPrefix,
        "private_chan", (string)PrivateChannel
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* ===== COMMAND PARSING ===== */
integer parseCommand(string msg_text, key speaker) {
    string trimmed = llStringTrim(msg_text, STRING_TRIM);

    if (llGetSubString(trimmed, 0, llStringLength(CommandPrefix) - 1) != CommandPrefix) {
        return FALSE;
    }

    string without_prefix = llGetSubString(trimmed, llStringLength(CommandPrefix), -1);
    list parts = llParseString2List(without_prefix, [" "], []);

    if (llGetListLength(parts) == 0) return FALSE;

    string command_name = llToLower(llList2String(parts, 0));
    list args = llList2List(parts, 1, -1);

    string plugin_context = findPluginForCommand(command_name);
    if (plugin_context == "") {
        llRegionSayTo(speaker, 0, "Unknown command: " + CommandPrefix + command_name);
        return FALSE;
    }

    PendingCommandUser = speaker;
    PendingCommand = command_name;
    PendingArgs = args;
    AclPending = TRUE;

    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)speaker
    ]), speaker);

    logd("Command: " + command_name + " by " + llKey2Name(speaker) + " -> " + plugin_context);
    return TRUE;
}

/* ===== ACL VERIFICATION & ROUTING ===== */
handleAclResult(string msg) {
    if (!AclPending) return;
    if (!jsonHas(msg, ["avatar"]) || !jsonHas(msg, ["level"])) return;

    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != PendingCommandUser) return;

    integer acl_level = (integer)llJsonGetValue(msg, ["level"]);
    AclPending = FALSE;

    logd("ACL result: " + (string)acl_level + " for " + PendingCommand);

    string plugin_context = findPluginForCommand(PendingCommand);
    if (plugin_context == "") {
        llRegionSayTo(PendingCommandUser, 0, "Command handler not found.");
        PendingCommandUser = NULL_KEY;
        PendingCommand = "";
        PendingArgs = [];
        return;
    }

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_invoke",
        "command", PendingCommand,
        "args", llList2Json(JSON_ARRAY, PendingArgs),
        "acl_level", (string)acl_level,
        "context", plugin_context
    ]), PendingCommandUser);

    logd("Routed: " + PendingCommand + " -> " + plugin_context + " (ACL " + (string)acl_level + ")");

    PendingCommandUser = NULL_KEY;
    PendingCommand = "";
    PendingArgs = [];
}

/* ===== COMMAND LISTING ===== */
sendCommandList(key user) {
    // Build list of unique commands
    list command_list = [];
    integer i = 0;
    integer len = llGetListLength(CommandRegistry);

    while (i < len) {
        string cmd = llList2String(CommandRegistry, i);
        command_list += [cmd];
        i = i + 2;
    }

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "chatcmd_list",
        "commands", llList2Json(JSON_ARRAY, command_list),
        "count", (string)llGetListLength(command_list)
    ]), user);

    logd("Sent command list: " + (string)llGetListLength(command_list) + " commands");
}

/* ===== CONFIGURATION INTERFACE ===== */
handleChatCmdAction(string msg, key user) {
    string action = jsonGet(msg, "action", "");
    if (action == "") return;

    if (action == "query_state") {
        broadcastState();
    }
    else if (action == "query_commands") {
        sendCommandList(user);
    }
    else if (action == "toggle_enabled") {
        Enabled = !Enabled;
        persistEnabled(Enabled);
        setupListeners();
        broadcastState();
        logd("Enabled toggled: " + (string)Enabled);
    }
    else if (action == "set_prefix") {
        string new_prefix = jsonGet(msg, "prefix", "!");
        if (new_prefix == "") new_prefix = "!";
        if (llStringLength(new_prefix) > 5) {
            llRegionSayTo(user, 0, "Prefix too long (max 5 characters)");
            return;
        }
        CommandPrefix = new_prefix;
        persistPrefix(CommandPrefix);
        broadcastState();
        llRegionSayTo(user, 0, "Command prefix set to: " + CommandPrefix);
        logd("Prefix changed to: " + CommandPrefix);
    }
    else if (action == "set_private_chan") {
        integer new_chan = (integer)jsonGet(msg, "channel", "1");
        // Range check for 32-bit signed integer is unnecessary in LSL:
        // LSL's integer type is always a 32-bit signed integer, and the type cast above
        // ((integer)jsonGet(...)) automatically constrains new_chan to this range.
        if (new_chan == 0) {
            llRegionSayTo(user, 0, "Cannot use channel 0 as private channel");
            return;
        }
        PrivateChannel = new_chan;
        persistPrivateChannel(PrivateChannel);
        setupListeners();
        broadcastState();
        llRegionSayTo(user, 0, "Private channel set to: " + (string)PrivateChannel);
        logd("Private channel changed to: " + (string)PrivateChannel);
    }
}

/* ===== CHAT COMMAND REGISTRATION (routed from kernel) ===== */
handleChatCmdRegister(string msg) {
    if (!jsonHas(msg, ["context"]) || !jsonHas(msg, ["commands"])) return;

    string plugin_context = llJsonGetValue(msg, ["context"]);
    string commands_json = llJsonGetValue(msg, ["commands"]);

    string num_str = llJsonGetValue(commands_json, ["length"]);
    if (num_str == JSON_INVALID) return;

    integer num_commands = (integer)num_str;

    integer i = 0;
    while (i < num_commands) {
        string cmd = llJsonGetValue(commands_json, [i]);
        if (cmd != JSON_INVALID && cmd != "") {
            registerCommand(cmd, plugin_context);
        }
        i = i + 1;
    }

    logd("Registered " + (string)num_commands + " commands for " + plugin_context);
}

/* ===== EVENT HANDLERS ===== */
default
{
    state_entry() {
        closeListeners();
        AclPending = FALSE;
        PendingCommandUser = NULL_KEY;
        PendingCommand = "";
        PendingArgs = [];
        CommandRegistry = [];

        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]), NULL_KEY);

        integer used = llGetUsedMemory();
        integer free_mem = llGetFreeMemory();
        logd(("Chat command kmod ready (v1.0) - Memory: " + (string)used + " used, " + (string)free_mem + " free"));
        logd("Chat command kmod ready");
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (!jsonHas(msg, ["type"])) return;
        string msg_type = llJsonGetValue(msg, ["type"]);

        if (num == UI_BUS) {
            if (msg_type == "chatcmd_register") {
                handleChatCmdRegister(msg);
                return;
            }

            if (msg_type == "chatcmd_action") {
                handleChatCmdAction(msg, id);
                return;
            }
        }

        if (num == AUTH_BUS) {
            if (msg_type == "acl_result") {
                handleAclResult(msg);
            }
            return;
        }

        if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync") {
                applySettingsSync(msg);
                broadcastState();
            }
            else if (msg_type == "settings_delta") {
                applySettingsDelta(msg);
            }
            return;
        }
    }

    listen(integer channel, string speaker_name, key speaker, string msg_text) {
        // Ignore messages from the collar object itself
        if (speaker == llGetKey()) return;

        // Public chat (channel 0) requires Enabled flag
        // Private channel is always active
        if (channel == 0 && !Enabled) return;

        parseCommand(msg_text, speaker);
    }
}


