/*--------------------
MODULE: kmod_chat.lsl
VERSION: 1.10
REVISION: 10
PURPOSE: Local chat command receiver. Listens on channel 1 (always) and
         optionally channel 0 (public chat) for prefixed commands from
         authorised speakers. Dispatches matching commands to UI_BUS so
         plugins receive them identically to menu-driven interactions.
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 10: Remove pre-seed of "menu" alias. kmod_ui re-emits its
  kernel.register for ROOT_CONTEXT/"Menu" in response to kernel.registernow
  (rev 7 of kmod_ui), so the alias is populated before any human can type.
  Pre-seeding was incorrect: it allowed command_is_known("menu") to return
  TRUE before the plugin list had loaded, which could produce an empty menu.
- v1.1 rev 9: Pre-seed "menu" alias to "ui.core.root" at state_entry as a
  belt-and-suspenders fallback in case kmod_ui's registernow response races.
- v1.1 rev 8: Re-enable PublicChat by default. The command_is_known() guard
  makes channel 0 safe; natural words are rejected before dispatch.
- v1.1 rev 7: Remove mandatory space after prefix. command_is_known() now
  guards both channels, so "anmenu" and "an menu" are equivalent. Natural
  words ("and", "an interesting") are rejected on both channels because they
  don't match any alias or dot-namespaced context.
- v1.1 rev 6: Validate channel 0 commands against the alias table and plugin
  context list before dispatching. Natural words that happen to follow the
  prefix (e.g. "an interesting idea") are silently ignored on public chat.
  Channel 1 remains unrestricted since it is a private channel.
- v1.1 rev 5: Revert PublicChat default to FALSE. A short 2-char prefix
  (e.g. "an") collides with natural English words on public chat, causing
  accidental triggers. Channel 0 listening remains available as an opt-in
  via the Chat plugin menu.
- v1.1 rev 4: Require a space after the prefix in strip_prefix. Previously
  any word starting with the prefix (e.g. "and") would match "an" and
  trigger a command. Format is now strictly "<prefix> <command>".
- v1.1 rev 3: Broadcast kernel.registernow on state_entry so kmod_ui and all
  plugins re-emit kernel.register, ensuring CommandAliases is populated even
  when kmod_chat starts after kmod_ui. Without this, 'an menu' failed because
  the 'menu' alias was never built.
- v1.1 rev 2: Default PublicChat to TRUE on first run. Channel 0 listening
  is now on by default; it was previously off and required explicit opt-in
  via the Chat plugin.
- v1.1 rev 1: Auto-build command alias table from kernel.register broadcasts.
  Aliases map lowercase label to context (e.g. "menu" -> "ui.core.root").
  kmod_ui emits a synthetic kernel.register for ROOT_CONTEXT/"Menu" so the
  root menu is reachable via chat without hardcoding.
- v1.1 rev 0: Initial implementation. Auto-derives default prefix from the
  first two characters of the wearer's username (llGetUsername). Prefix and
  public-chat toggle are runtime-configurable via plugin_chat and persisted
  in LSD/settings. Commands are dispatched as ui.menu.start messages so any
  registered plugin can respond without this module knowing plugin internals.
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS         = 700;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;

/* -------------------- SETTINGS KEYS -------------------- */
// Must match plugin_chat.lsl KEY_* constants.
string KEY_PREFIX       = "chat.prefix";
string KEY_PUBLIC_CHAT  = "chat.public";  // "1" = enabled, "0" = disabled

/* -------------------- STATE -------------------- */
string ChatPrefix    = "";   // Set from settings or derived on first run
integer PublicChat   = FALSE; // Channel 0 listening enabled

integer ListenChan0  = 0;    // Handle for channel 0 listener (0 = inactive)
integer ListenChan1  = 0;    // Handle for channel 1 listener (0 = inactive)

// Stride-2 list: [alias, context, alias, context, ...]
// Populated by intercepting kernel.register broadcasts from plugins and kmod_ui.
// alias = llToLower(label), context = PLUGIN_CONTEXT.
list CommandAliases = [];

/* -------------------- HELPERS -------------------- */

integer logd(string msg) {
    return FALSE;
}

// Derive a default prefix from the first two characters of the wearer's username.
// llGetUsername() returns "firstname.lastname" or "firstname" (no spaces).
string derive_default_prefix() {
    string username = llGetUsername(llGetOwner());
    if (llStringLength(username) >= 2) {
        return llToLower(llGetSubString(username, 0, 1));
    }
    if (llStringLength(username) == 1) {
        return llToLower(username);
    }
    return "c";  // fallback
}

// Remove old listeners and establish fresh ones based on current settings.
reset_listeners() {
    if (ListenChan0 != 0) {
        llListenRemove(ListenChan0);
        ListenChan0 = 0;
    }
    if (ListenChan1 != 0) {
        llListenRemove(ListenChan1);
        ListenChan1 = 0;
    }

    if (ChatPrefix == "") return;

    // Channel 1 is always active when a prefix is set
    ListenChan1 = llListen(1, "", NULL_KEY, "");

    // Channel 0 only if explicitly enabled
    if (PublicChat) {
        ListenChan0 = llListen(0, "", NULL_KEY, "");
    }
}

/* -------------------- SETTINGS -------------------- */

apply_settings_sync() {
    string stored_prefix = llLinksetDataRead(KEY_PREFIX);
    string stored_public  = llLinksetDataRead(KEY_PUBLIC_CHAT);

    if (stored_prefix != "") {
        ChatPrefix = stored_prefix;
    }
    else {
        // First run: derive from username and persist so plugin_chat can read it
        ChatPrefix = derive_default_prefix();
        llLinksetDataWrite(KEY_PREFIX, ChatPrefix);
    }

    if (stored_public != "") {
        PublicChat = (integer)stored_public;
    }
    else {
        PublicChat = TRUE;
        llLinksetDataWrite(KEY_PUBLIC_CHAT, "1");
    }

    reset_listeners();
}

/* -------------------- COMMAND DISPATCH -------------------- */

// Strip prefix from message, trim whitespace, return remainder.
// Prefix may be immediately followed by the command ("anmenu") or separated
// by whitespace ("an menu") — both forms are accepted.
// Returns "" if message does not start with the prefix.
string strip_prefix(string message) {
    integer prefix_len = llStringLength(ChatPrefix);
    if (llStringLength(message) <= prefix_len) return "";
    string head = llToLower(llGetSubString(message, 0, prefix_len - 1));
    if (head != llToLower(ChatPrefix)) return "";
    return llStringTrim(llGetSubString(message, prefix_len, -1), STRING_TRIM);
}

// Register a label→context alias from a kernel.register message.
register_alias(string label, string context) {
    if (label == "" || context == "") return;
    string alias = llToLower(label);
    integer idx = llListFindList(CommandAliases, [alias]);
    if (idx == -1) {
        CommandAliases += [alias, context];
    }
    else {
        // Update in place (stride 2, alias at idx, context at idx+1)
        CommandAliases = llListReplaceList(CommandAliases, [alias, context], idx, idx + 1);
    }
}

// Returns TRUE if command is a known alias or a dot-namespaced context string.
// Used to reject natural-language false positives on channel 0.
integer command_is_known(string command) {
    string lower = llToLower(command);
    // Exact alias match
    if (llListFindList(CommandAliases, [lower]) != -1) return TRUE;
    // Full context passthrough: must contain a dot (namespaced)
    if (llSubStringIndex(command, ".") != -1) return TRUE;
    return FALSE;
}

// Resolve an alias to a full context string.
// Returns the input unchanged if no alias matches (allows full context passthrough).
string resolve_command(string command) {
    string lower = llToLower(command);
    integer idx = llListFindList(CommandAliases, [lower]);
    if (idx != -1) return llList2String(CommandAliases, idx + 1);
    return command;
}

// Dispatch a recognised command from an authorised speaker.
// The command string is resolved through the alias table before sending,
// so "lock" dispatches as "ui.core.lock" and "menu" as "ui.core.root".
dispatch_command(key speaker, string command) {
    logd("chat cmd: speaker=" + (string)speaker + " cmd=" + command);
    command = resolve_command(command);

    // Query ACL so the receiving plugin can gate on access level.
    // We send ui.menu.start directly; kmod_ui will route it after the ACL
    // round-trip exactly as it does for a touch-initiated session.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.menu.start",
        "context", command,
        "source",  "chat"
    ]), speaker);
}

// Validate that a speaker is authorised to send chat commands.
// We accept the wearer, and if the command arrives on channel 0 we also
// check the ACL cache so only public-or-higher users can drive the collar
// from public chat (prevents griefing).
integer speaker_authorised(key speaker, integer channel) {
    key wearer = llGetOwner();
    if (speaker == wearer) return TRUE;

    // For channel 0 commands from non-wearers, require cached ACL >= 1 (public)
    string raw = llLinksetDataRead("acl." + (string)speaker + ".cache");
    if (raw == "") return FALSE;
    integer sep = llSubStringIndex(raw, "|");
    if (sep == -1) return FALSE;
    integer level = (integer)llGetSubString(raw, 0, sep - 1);
    return (level >= 1);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        ListenChan0 = 0;
        ListenChan1 = 0;
        CommandAliases = [];
        apply_settings_sync();
        // Force all scripts to re-broadcast kernel.register so the alias table
        // is populated regardless of startup order.
        llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
            "type", "kernel.registernow"
        ]), NULL_KEY);
    }

    on_rez(integer param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    listen(integer channel, string name, key id, string message) {
        // Ignore own messages
        if (id == llGetKey()) return;

        // Validate channel scope
        if (channel == 0 && !PublicChat) return;
        if (channel != 0 && channel != 1) return;

        // Strip prefix
        string command = strip_prefix(message);
        if (command == "") return;

        // Only act on recognised commands (known alias or dot-namespaced context).
        // This rejects natural words on both channels (e.g. "and", "an interesting").
        if (!command_is_known(command)) return;

        // Validate speaker authorisation
        if (!speaker_authorised(id, channel)) return;

        dispatch_command(id, command);
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset" || msg_type == "kernel.resetall") {
                llResetScript();
            }
            else if (msg_type == "kernel.register") {
                string reg_label   = llJsonGetValue(msg, ["label"]);
                string reg_context = llJsonGetValue(msg, ["context"]);
                if (reg_label != JSON_INVALID && reg_context != JSON_INVALID) {
                    register_alias(reg_label, reg_context);
                }
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                apply_settings_sync();
            }
        }
    }
}
