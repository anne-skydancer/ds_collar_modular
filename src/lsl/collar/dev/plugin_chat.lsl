/*--------------------
PLUGIN: plugin_chat.lsl
VERSION: 1.10
REVISION: 3
PURPOSE: Configuration UI for kmod_chat — change command prefix and toggle
         public chat (channel 0) listening.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
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

/* -------------------- CONSTANTS -------------------- */
integer INPUT_CHAN    = -7654321;  // Private channel for prefix input
float   INPUT_TIMEOUT = 30.0;

/* -------------------- STATE -------------------- */
string  ChatPrefix   = "";
integer PublicChat   = FALSE;

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

register_self() {
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "4", "Set Prefix,Toggle Public",
        "5", "Set Prefix,Toggle Public"
    ]));

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register",
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
}

persist_prefix(string new_prefix) {
    ChatPrefix = new_prefix;
    llLinksetDataWrite(KEY_PREFIX, new_prefix);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_PREFIX,
        "value", new_prefix
    ]), NULL_KEY);
}

persist_public_chat(integer enabled) {
    PublicChat = enabled;
    string val = (string)enabled;
    llLinksetDataWrite(KEY_PUBLIC_CHAT, val);
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
                  "\nChannel 0: " + public_label +
                  "\n\nChannel 1 is always active.\nChannel 0 allows public commands.";

    list button_data = [btn("Back", "back")];
    if (btn_allowed("Set Prefix"))    button_data += [btn("Set Prefix", "set_prefix")];
    if (btn_allowed("Toggle Public")) button_data += [btn(public_label, "toggle_public")];

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

prompt_for_prefix() {
    MenuContext = "input_prefix";

    if (InputListen != 0) llListenRemove(InputListen);
    InputListen = llListen(INPUT_CHAN, "", CurrentUser, "");
    llSetTimerEvent(INPUT_TIMEOUT);

    llRegionSayTo(CurrentUser, 0,
        "Type the new prefix on channel " + (string)INPUT_CHAN +
        " (e.g. /" + (string)INPUT_CHAN + " ab). 1-8 characters. Type 'cancel' to abort.");
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
        if (channel != INPUT_CHAN) return;
        if (id != CurrentUser) return;
        handle_prefix_input(message);
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.registernow") {
                register_self();
                apply_settings_sync();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset") {
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
