/*--------------------
PLUGIN: plugin_chat.lsl
VERSION: 1.10
REVISION: 8
PURPOSE: Configuration UI for kmod_chat — change command prefix and toggle
         public chat (channel 0) listening.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 8: Self-declare menu presence via LSD (plugin.reg.<ctx>).
  Label updates write the same LSD key directly; ui.label.update link_messages
  are gone. Reset handlers delete plugin.reg.<ctx> and acl.policycontext:<ctx>
  before llResetScript so kmod_ui drops the button immediately.
- v1.1 rev 7: Honor kernel.reset.factory as well as kernel.reset.soft.
  Previously ignored factory reset, leaving cached session state after
  factory wipe. Now self-resets on either.
- v1.1 rev 6: Wire-type rename (Phase 2). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.reset→kernel.reset.soft.
- v1.1 rev 5: Add configurable secondary channel ("Set Channel" button).
  Uses llTextBox like prefix input; valid range 1-9, not 0.
- v1.1 rev 4: Replace negative-channel chat input with llTextBox popup for
  prefix input. Removes the need for the user to type on a private channel.
- v1.1 rev 3: Guard ui.menu.start handler against raw (unrouted) dispatches
  from kmod_chat. Messages without an acl field are ignored; only messages
  routed through kmod_ui (which adds the acl field) are processed. Fixes
  spurious "Access denied" when chat commands were used.
- v1.1 rev 2: Remove trustee (ACL 3) from Chat config entirely. Policy entry
  for ACL 3 dropped; ui.menu.start handler now rejects any caller with acl < 4
  before opening the menu.
- v1.1 rev 1: Restrict "Set Prefix" to unowned wearer (ACL 4) and primary
  owner (ACL 5); trustees (ACL 3) retained "Toggle Public" only.
- v1.1 rev 0: Initial implementation. Shows current prefix and public-chat
  status; allows owner/trustee to change prefix via local chat input and
  toggle channel 0 listening on/off.
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.chat";
string PLUGIN_LABEL   = "Chat";

/* -------------------- SETTINGS KEYS -------------------- */
// Must match kmod_chat.lsl KEY_* constants.
string KEY_PREFIX      = "chat.prefix";
string KEY_PUBLIC_CHAT = "chat.public";
string KEY_CHAT_CHAN   = "chat.channel";

/* -------------------- CONSTANTS -------------------- */
float   INPUT_TIMEOUT = 30.0;

/* -------------------- STATE -------------------- */
string  ChatPrefix   = "";
integer PublicChat   = FALSE;
integer ChatChan     = 1;

key    CurrentUser    = NULL_KEY;
integer UserAcl       = 0;
list   gPolicyButtons = [];
string SessionId      = "";
string MenuContext    = "";
integer InputListen   = 0;

/* -------------------- HELPERS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

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

/* -------------------- LIFECYCLE -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
write_plugin_reg(string label) {
    llLinksetDataWrite("plugin.reg." + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "label",  label,
        "script", llGetScriptName()
    ]));
}

register_self() {
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "4", "Set Prefix,Set Channel,Toggle Public",
        "5", "Set Prefix,Set Channel,Toggle Public"
    ]));

    // Self-declared menu presence for kmod_ui.
    write_plugin_reg(PLUGIN_LABEL);

    // Register with kernel (for ping/pong health tracking and alias table).
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

cleanup_session() {
    if (InputListen != 0) {
        llListenRemove(InputListen);
        InputListen = 0;
    }
    llSetTimerEvent(0.0);

    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }

    SessionId     = "";
    CurrentUser   = NULL_KEY;
    UserAcl       = 0;
    gPolicyButtons = [];
    MenuContext   = "";
}

/* -------------------- SETTINGS -------------------- */

apply_settings_sync() {
    string stored_prefix = llLinksetDataRead(KEY_PREFIX);
    string stored_public  = llLinksetDataRead(KEY_PUBLIC_CHAT);

    if (stored_prefix != "") ChatPrefix = stored_prefix;
    if (stored_public != "") PublicChat = (integer)stored_public;
    string stored_chan = llLinksetDataRead(KEY_CHAT_CHAN);
    if (stored_chan != "") ChatChan = (integer)stored_chan;
}

persist_prefix(string new_prefix) {
    ChatPrefix = new_prefix;
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_PREFIX,
        "value", new_prefix
    ]), NULL_KEY);
}

persist_chat_chan(integer new_chan) {
    ChatChan = new_chan;
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key",  KEY_CHAT_CHAN,
        "value", (string)new_chan
    ]), NULL_KEY);
}

persist_public_chat(integer enabled) {
    PublicChat = enabled;
    string val = (string)enabled;
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_PUBLIC_CHAT,
        "value", val
    ]), NULL_KEY);
}

/* -------------------- UI -------------------- */

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

show_main() {
    SessionId    = generate_session_id();
    MenuContext  = "main";
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string public_label;
    if (PublicChat) {
        public_label = "Public: ON";
    }
    else {
        public_label = "Public: OFF";
    }

    string prefix_display = ChatPrefix;
    if (prefix_display == "") prefix_display = "(none)";

    string body = "Chat Commands\n\nPrefix: " + prefix_display +
                  "\nChannel: " + (string)ChatChan +
                  "\nPublic chat: " + public_label +
                  "\n\nChannel " + (string)ChatChan + " is the private channel." +
                  "\nChannel 0 allows public commands.";

    list button_data = [btn("Back", "back")];
    if (btn_allowed("Set Prefix"))    button_data += [btn("Set Prefix",   "set_prefix")];
    if (btn_allowed("Set Channel"))   button_data += [btn("Set Channel",  "set_channel")];
    if (btn_allowed("Toggle Public")) button_data += [btn(public_label,   "toggle_public")];

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);
}

prompt_for_channel() {
    MenuContext = "input_channel";

    if (InputListen != 0) llListenRemove(InputListen);
    integer input_chan = -1 - (integer)llFrand(2000000);
    InputListen = llListen(input_chan, "", CurrentUser, "");
    llSetTimerEvent(INPUT_TIMEOUT);

    llTextBox(CurrentUser,
        "Enter secondary channel number (1-9, not 0).\nLeave blank or type 'cancel' to abort.",
        input_chan);
}

prompt_for_prefix() {
    MenuContext = "input_prefix";

    if (InputListen != 0) llListenRemove(InputListen);
    // Use a random negative channel so concurrent textboxes don't collide
    integer input_chan = -1 - (integer)llFrand(2000000);
    InputListen = llListen(input_chan, "", CurrentUser, "");
    llSetTimerEvent(INPUT_TIMEOUT);

    llTextBox(CurrentUser,
        "Enter new prefix (1-8 characters).\nLeave blank or type 'cancel' to abort.",
        input_chan);
}

/* -------------------- DIALOG HANDLER -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    if (user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";

    if (MenuContext == "main") {
        if (ctx == "back") {
            return_to_root();
        }
        else if (ctx == "set_channel") {
            if (!btn_allowed("Set Channel")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            prompt_for_channel();
        }
        else if (ctx == "set_prefix") {
            if (!btn_allowed("Set Prefix")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            prompt_for_prefix();
        }
        else if (ctx == "toggle_public") {
            if (!btn_allowed("Toggle Public")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            if (PublicChat) {
                persist_public_chat(FALSE);
                llRegionSayTo(CurrentUser, 0, "Public chat commands disabled.");
            }
            else {
                persist_public_chat(TRUE);
                llRegionSayTo(CurrentUser, 0, "Public chat commands enabled.");
            }
            show_main();
        }
    }
}

handle_dialog_timeout(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
    cleanup_session();
}

/* -------------------- CHAT INPUT HANDLER -------------------- */

handle_channel_input(string raw) {
    if (InputListen != 0) {
        llListenRemove(InputListen);
        InputListen = 0;
    }
    llSetTimerEvent(0.0);

    raw = llStringTrim(raw, STRING_TRIM);

    if (raw == "cancel" || raw == "") {
        llRegionSayTo(CurrentUser, 0, "Cancelled.");
        show_main();
        return;
    }

    integer new_chan = (integer)raw;
    if (new_chan < 1 || new_chan > 9) {
        llRegionSayTo(CurrentUser, 0, "Invalid channel. Must be 1-9.");
        show_main();
        return;
    }

    persist_chat_chan(new_chan);
    llRegionSayTo(CurrentUser, 0, "Channel set to: " + (string)new_chan);
    show_main();
}

handle_prefix_input(string new_prefix) {
    if (InputListen != 0) {
        llListenRemove(InputListen);
        InputListen = 0;
    }
    llSetTimerEvent(0.0);

    new_prefix = llStringTrim(new_prefix, STRING_TRIM);

    if (new_prefix == "cancel" || new_prefix == "") {
        llRegionSayTo(CurrentUser, 0, "Cancelled.");
        show_main();
        return;
    }

    if (llStringLength(new_prefix) > 8) {
        llRegionSayTo(CurrentUser, 0, "Prefix too long (max 8 characters). Try again.");
        show_main();
        return;
    }

    persist_prefix(new_prefix);
    llRegionSayTo(CurrentUser, 0, "Prefix set to: " + new_prefix);
    show_main();
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        cleanup_session();
        apply_settings_sync();
        register_self();
    }

    on_rez(integer param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    timer() {
        if (InputListen != 0) {
            llListenRemove(InputListen);
            InputListen = 0;
        }
        llSetTimerEvent(0.0);
        if (CurrentUser != NULL_KEY) {
            llRegionSayTo(CurrentUser, 0, "Input timed out.");
        }
        show_main();
    }

    listen(integer channel, string name, key id, string message) {
        if (id != CurrentUser) return;
        if (MenuContext == "input_prefix")  handle_prefix_input(message);
        else if (MenuContext == "input_channel") handle_channel_input(message);
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.refresh") {
                register_self();
                apply_settings_sync();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                apply_settings_sync();
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                string context = llJsonGetValue(msg, ["context"]);
                if (context != PLUGIN_CONTEXT) return;
                // Ignore raw dispatches from kmod_chat (no acl field).
                // Only process messages already routed through kmod_ui.
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                integer req_acl = (integer)llJsonGetValue(msg, ["acl"]);
                if (req_acl < 4) {
                    llRegionSayTo(id, 0, "[Chat] Access denied.");
                    return;
                }
                CurrentUser = id;
                UserAcl = req_acl;
                show_main();
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
            }
        }
    }
}
