/*--------------------
PLUGIN: plugin_folders.lsl
VERSION: 1.10
REVISION: 1
PURPOSE: Manage RLV shared folders — enumerate, attach, detach, and lock #RLV subfolders
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility.
             Uses @getinv RLV command to enumerate actual #RLV subfolders in real-time;
             no text input required. Only the locked-folder list is persisted.
CHANGES:
- v1.10 rev 1: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.10 rev 0: Folder buttons are built from the wearer's actual #RLV inventory.
  Removed FolderNames persistence; only LockedNames is stored. Supports Attach,
  Detach, Lock, and Unlock actions via paginated folder-picker dialog.
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.folders";
string PLUGIN_LABEL   = "Folders";

/* -------------------- SETTINGS KEYS & CONSTANTS -------------------- */
integer DEBUG       = FALSE;
string  KEY_LOCKED  = "folders.locked";  // CSV of folder names locked via @detachallthis

integer RLV_CHAN    = 1888753;   // Private positive channel for @getinv responses
float   RLV_TIMEOUT = 10.0;     // Seconds to wait for viewer RLV reply
integer PAGE_SIZE   = 9;        // Folder buttons per page (fills 3 rows above nav row)

/* -------------------- STATE -------------------- */
list    LockedNames       = [];   // Folder paths locked via @detachallthis:name=n

key     CurrentUser       = NULL_KEY;
integer UserAcl           = 0;
list    gPolicyButtons    = [];
string  SessionId         = "";
string  MenuContext       = "";   // "main" | "pick" | "unlock_pick"
string  PendingAction     = "";   // "attach" | "detach" | "lock"
list    DiscoveredFolders = [];   // Populated from @getinv response
integer PickPage          = 0;
integer RlvListenHandle   = 0;

/* -------------------- HELPERS -------------------- */

integer logd(string msg) {
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string truncate(string s, integer max_len) {
    if (llStringLength(s) <= max_len) return s;
    return llGetSubString(s, 0, max_len - 1);
}

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
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
        "3", "Attach,Detach,Lock,Unlock",
        "4", "Attach,Detach,Lock,Unlock",
        "5", "Attach,Detach,Lock,Unlock"
    ]));
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "kernel.register",
        "context", PLUGIN_CONTEXT,
        "label",   PLUGIN_LABEL,
        "script",  llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

stop_rlv_listen() {
    if (RlvListenHandle != 0) {
        llListenRemove(RlvListenHandle);
        RlvListenHandle = 0;
    }
    llSetTimerEvent(0.0);
}

cleanup_session() {
    stop_rlv_listen();

    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type",       "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }

    SessionId         = "";
    CurrentUser       = NULL_KEY;
    UserAcl           = 0;
    gPolicyButtons    = [];
    MenuContext       = "";
    PendingAction     = "";
    DiscoveredFolders = [];
    PickPage          = 0;
}

/* -------------------- SETTINGS -------------------- */

apply_settings_sync() {
    string csv = llLinksetDataRead(KEY_LOCKED);
    list new_locked = [];
    if (csv != "") new_locked = llParseString2List(csv, [","], []);

    // Lift locks that are no longer in the persisted list
    integer i = 0;
    integer len = llGetListLength(LockedNames);
    while (i < len) {
        string folder_name = llList2String(LockedNames, i);
        if (llListFindList(new_locked, [folder_name]) == -1) {
            llOwnerSay("@detachallthis:" + folder_name + "=y");
        }
        i += 1;
    }

    LockedNames = new_locked;

    // Reapply all current locks
    i = 0;
    len = llGetListLength(LockedNames);
    while (i < len) {
        llOwnerSay("@detachallthis:" + llList2String(LockedNames, i) + "=n");
        i += 1;
    }
}

persist_locked() {
    string csv = llDumpList2String(LockedNames, ",");
    llLinksetDataWrite(KEY_LOCKED, csv);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type",  "settings.set",
        "key",   KEY_LOCKED,
        "value", csv
    ]), NULL_KEY);
}

/* -------------------- RLV FOLDER COMMANDS -------------------- */

attach_folder(string folder_name) {
    llOwnerSay("@attachall:" + folder_name + "=force");
}

detach_folder(string folder_name) {
    llOwnerSay("@detachall:" + folder_name + "=force");
}

lock_folder(string folder_name) {
    llOwnerSay("@detachallthis:" + folder_name + "=n");
}

unlock_folder(string folder_name) {
    llOwnerSay("@detachallthis:" + folder_name + "=y");
}

/* -------------------- UI -------------------- */

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user",    (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

show_main() {
    SessionId      = generate_session_id();
    MenuContext    = "main";
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    integer locked_count = llGetListLength(LockedNames);

    string body = "Shared Folder Manager\n\nLocked: " + (string)locked_count +
                  " folder(s)\n\nSelect an action:";

    list button_data = [btn("Back", "back")];
    if (btn_allowed("Attach")) button_data += [btn("Attach", "attach")];
    if (btn_allowed("Detach")) button_data += [btn("Detach", "detach")];
    if (btn_allowed("Lock"))   button_data += [btn("Lock",   "lock")];
    if (btn_allowed("Unlock")) button_data += [btn("Unlock", "unlock")];

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",        "ui.dialog.open",
        "session_id",  SessionId,
        "user",        (string)CurrentUser,
        "title",       PLUGIN_LABEL,
        "body",        body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout",     60
    ]), NULL_KEY);
}

// Sends @getinv to enumerate actual #RLV subfolders before showing a pick dialog.
query_folders(string action_type) {
    PendingAction     = action_type;
    DiscoveredFolders = [];
    PickPage          = 0;
    stop_rlv_listen();
    RlvListenHandle = llListen(RLV_CHAN, "", llGetOwner(), "");
    llOwnerSay("@getinv=" + (string)RLV_CHAN);
    llSetTimerEvent(RLV_TIMEOUT);
    llRegionSayTo(CurrentUser, 0, "[" + PLUGIN_LABEL + "] Reading #RLV folders...");
}

// Shows a paginated list of DiscoveredFolders as pick buttons.
// Nav row: [Back][<<][>>] at bottom; folders fill above.
show_folder_pick(integer page) {
    integer total = llGetListLength(DiscoveredFolders);
    if (total == 0) {
        llRegionSayTo(CurrentUser, 0, "No accessible folders found in #RLV.");
        show_main();
        return;
    }

    integer max_page = (total - 1) / PAGE_SIZE;
    if (page < 0) page = 0;
    if (page > max_page) page = max_page;
    PickPage    = page;
    SessionId   = generate_session_id();
    MenuContext = "pick";

    integer start = page * PAGE_SIZE;
    integer end   = start + PAGE_SIZE;
    if (end > total) end = total;

    string action_label;
    if (PendingAction == "attach")      action_label = "Attach";
    else if (PendingAction == "detach") action_label = "Detach";
    else if (PendingAction == "lock")   action_label = "Lock";
    else                                action_label = PendingAction;

    string body = action_label + " an #RLV folder\n\n" +
                  "Page " + (string)(page + 1) + " of " + (string)(max_page + 1);

    // Nav buttons anchor the bottom row; folders fill the rows above
    list button_data = [btn("Back", "back"), btn("<<", "prev"), btn(">>", "next")];

    integer i = start;
    while (i < end) {
        string folder_name = llList2String(DiscoveredFolders, i);
        string label;
        if (llListFindList(LockedNames, [folder_name]) != -1) {
            label = "[L] " + truncate(folder_name, 20);
        }
        else {
            label = truncate(folder_name, 24);
        }
        button_data += [btn(label, "pick:" + (string)i)];
        i += 1;
    }

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",        "ui.dialog.open",
        "session_id",  SessionId,
        "user",        (string)CurrentUser,
        "title",       action_label + " Folder",
        "body",        body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout",     60
    ]), NULL_KEY);
}

// Shows locked folders directly from LockedNames (no RLV query needed).
show_unlock_pick() {
    integer total = llGetListLength(LockedNames);
    if (total == 0) {
        llRegionSayTo(CurrentUser, 0, "No folders are currently locked.");
        show_main();
        return;
    }

    SessionId   = generate_session_id();
    MenuContext = "unlock_pick";

    string body = "Select a folder to unlock:\n\nCurrently locked: " + (string)total;
    list button_data = [btn("Back", "back")];

    integer i = 0;
    integer end = total;
    if (end > 11) end = 11;  // 12 button max; 1 reserved for Back
    while (i < end) {
        string folder_name = llList2String(LockedNames, i);
        button_data += [btn(truncate(folder_name, 24), "unlock:" + (string)i)];
        i += 1;
    }

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",        "ui.dialog.open",
        "session_id",  SessionId,
        "user",        (string)CurrentUser,
        "title",       "Unlock Folder",
        "body",        body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout",     60
    ]), NULL_KEY);
}

// Applies PendingAction to the chosen folder, then returns to main menu.
apply_folder_action(string folder_name) {
    if (PendingAction == "attach") {
        attach_folder(folder_name);
        llRegionSayTo(CurrentUser, 0, "Attaching: " + folder_name);
    }
    else if (PendingAction == "detach") {
        if (llListFindList(LockedNames, [folder_name]) != -1) {
            llRegionSayTo(CurrentUser, 0, folder_name + " is locked. Unlock it first.");
            show_main();
            return;
        }
        detach_folder(folder_name);
        llRegionSayTo(CurrentUser, 0, "Detaching: " + folder_name);
    }
    else if (PendingAction == "lock") {
        if (llListFindList(LockedNames, [folder_name]) != -1) {
            llRegionSayTo(CurrentUser, 0, folder_name + " is already locked.");
        }
        else {
            LockedNames += [folder_name];
            lock_folder(folder_name);
            persist_locked();
            llRegionSayTo(CurrentUser, 0, "Locked: " + folder_name);
        }
    }
    show_main();
}

/* -------------------- DIALOG HANDLER -------------------- */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    if (user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";

    if (MenuContext == "main") {
        if (ctx == "back") {
            return_to_root();
        }
        else if (ctx == "attach" || ctx == "detach" || ctx == "lock") {
            query_folders(ctx);
        }
        else if (ctx == "unlock") {
            show_unlock_pick();
        }
    }
    else if (MenuContext == "pick") {
        if (ctx == "back") {
            show_main();
        }
        else if (ctx == "prev") {
            integer new_page = PickPage - 1;
            if (new_page < 0) new_page = 0;
            show_folder_pick(new_page);
        }
        else if (ctx == "next") {
            integer total = llGetListLength(DiscoveredFolders);
            integer max_page = (total - 1) / PAGE_SIZE;
            integer new_page = PickPage + 1;
            if (new_page > max_page) new_page = max_page;
            show_folder_pick(new_page);
        }
        else if (llSubStringIndex(ctx, "pick:") == 0) {
            integer idx = (integer)llGetSubString(ctx, 5, -1);
            if (idx >= 0 && idx < llGetListLength(DiscoveredFolders)) {
                string folder_name = llList2String(DiscoveredFolders, idx);
                apply_folder_action(folder_name);
            }
        }
    }
    else if (MenuContext == "unlock_pick") {
        if (ctx == "back") {
            show_main();
        }
        else if (llSubStringIndex(ctx, "unlock:") == 0) {
            integer idx = (integer)llGetSubString(ctx, 7, -1);
            if (idx >= 0 && idx < llGetListLength(LockedNames)) {
                string folder_name = llList2String(LockedNames, idx);
                LockedNames = llDeleteSubList(LockedNames, idx, idx);
                unlock_folder(folder_name);
                persist_locked();
                llRegionSayTo(CurrentUser, 0, "Unlocked: " + folder_name);
            }
            show_main();
        }
    }
}

handle_dialog_timeout(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
    cleanup_session();
}

/* -------------------- RLV RESPONSE HANDLER -------------------- */

handle_rlv_response(string message) {
    stop_rlv_listen();
    if (CurrentUser == NULL_KEY) return;

    DiscoveredFolders = [];
    if (message != "") {
        list raw = llParseString2List(message, [","], []);
        integer i = 0;
        integer len = llGetListLength(raw);
        while (i < len) {
            string folder_name = llStringTrim(llList2String(raw, i), STRING_TRIM);
            if (folder_name != "") {
                DiscoveredFolders += [folder_name];
            }
            i += 1;
        }
    }

    if (llGetListLength(DiscoveredFolders) == 0) {
        llRegionSayTo(CurrentUser, 0, "No shared folders found in #RLV.");
        show_main();
        return;
    }

    show_folder_pick(0);
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
        // RLV @getinv query timed out — viewer is not RLV-enabled or not responding
        stop_rlv_listen();
        if (CurrentUser != NULL_KEY) {
            llRegionSayTo(CurrentUser, 0, "RLV not responding. Is RLV mode enabled?");
        }
        show_main();
    }

    listen(integer channel, string name, key id, string message) {
        if (channel == RLV_CHAN && id == llGetOwner()) {
            handle_rlv_response(message);
        }
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
            if (msg_type == "settings.sync") {
                apply_settings_sync();
            }
            else if (msg_type == "settings.delta") {
                string delta_key = llJsonGetValue(msg, ["key"]);
                if (delta_key == KEY_LOCKED) {
                    apply_settings_sync();
                }
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx != PLUGIN_CONTEXT) return;
                CurrentUser = id;
                UserAcl = (integer)llJsonGetValue(msg, ["acl"]);
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
