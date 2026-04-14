/*--------------------
PLUGIN: plugin_folders.lsl
VERSION: 1.10
REVISION: 6
PURPOSE: Manage RLV shared folders — enumerate, attach, detach, and lock #RLV subfolders
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility.
             Uses @getinv RLV command to enumerate actual #RLV subfolders in real-time;
             no text input required. Only the locked-folder list is persisted.
CHANGES:
- v1.10 rev 6: Folder number buttons use same slot-mapping as plugin_animate —
  items read top-to-bottom, left-to-right. Full 12-slot grid pre-filled with
  spaces; nav at slots 0-2, folders mapped into slots 9-11 (row4), 6-8 (row3),
  3-5 (row2).
- v1.10 rev 5: Folder list uses numbered body text with [+]/[-]/[ ] worn
  indicators and * for locked; buttons are plain numbers 1-9. Worn status
  also shown in the per-folder action sub-menu.
- v1.10 rev 4: Use @getinvworn instead of @getinv to get worn state per folder.
  Buttons show ● (worn), ◑ (partial), or no prefix (not worn).
- v1.10 rev 3: Redesign UI flow — scan #RLV folders on menu entry, show folder
  list, then per-folder Attach/Detach/Lock/Unlock sub-menu. Removes action-
  first picker (old Attach/Detach/Lock/Unlock top-level buttons).
- v1.10 rev 2: Fix @getinv RLV command syntax — was missing the path separator
  colon, so the viewer never responded. Correct form is @getinv:=<chan> for
  the #RLV root (empty path). Without the colon the command is silently
  ignored and the RLV timeout fires.
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
string  MenuContext       = "";   // "scanning" | "pick" | "action"
string  SelectedFolder    = "";   // Folder chosen in the "pick" context
    list    DiscoveredFolders = [];   // Populated from @getinvworn response
    list    WornStates        = [];   // Parallel to DiscoveredFolders: "0","1","2"
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
    SelectedFolder    = "";
    DiscoveredFolders = [];
    WornStates        = [];
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

// On menu entry, immediately scan #RLV folders. Once the viewer responds,
// show_folder_pick() presents the list. The user then picks a folder and
// sees per-folder Attach / Detach / Lock / Unlock action buttons.
show_main() {
    gPolicyButtons    = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);
    DiscoveredFolders = [];
    SelectedFolder    = "";
    PickPage          = 0;
    MenuContext       = "scanning";
    stop_rlv_listen();
    RlvListenHandle = llListen(RLV_CHAN, "", llGetOwner(), "");
    llOwnerSay("@getinvworn:=" + (string)RLV_CHAN);
    llSetTimerEvent(RLV_TIMEOUT);
    llRegionSayTo(CurrentUser, 0, "[" + PLUGIN_LABEL + "] Reading #RLV folders...");
}

// Shows a paginated numbered list of discovered #RLV folders in the body.
// Buttons are 1..N mapped top-to-bottom, left-to-right (same layout as
// plugin_animate). Nav row [Back][<<][>>] anchors the bottom (slots 0-2).
// Folder number buttons fill slots top-down: row4=9-11, row3=6-8, row2=3-5.
// Unused slots are padded with a single space.
show_folder_pick(integer page) {
    integer total = llGetListLength(DiscoveredFolders);
    if (total == 0) {
        llRegionSayTo(CurrentUser, 0, "No accessible folders found in #RLV.");
        return_to_root();
        return;
    }

    integer max_page = (total - 1) / PAGE_SIZE;
    if (page < 0) page = 0;
    if (page > max_page) page = max_page;
    PickPage    = page;
    SessionId   = generate_session_id();
    MenuContext = "pick";

    integer start   = page * PAGE_SIZE;
    integer end_idx = start + PAGE_SIZE;
    if (end_idx > total) end_idx = total;

    string body = "Tap a number to manage a folder.\n" +
                  "[+]=worn  [-]=partial  *=locked\n" +
                  "Page " + (string)(page + 1) + " of " + (string)(max_page + 1) + "\n\n";

    // Slot order for top-to-bottom visual reading (row4 first, then row3, row2)
    list target_slots = [9, 10, 11, 6, 7, 8, 3, 4, 5];

    // Initialise full 12-slot grid: nav at bottom, spaces in folder slots
    list final_buttons = [
        btn("Back", "back"), btn("<<", "prev"), btn(">>", "next"),
        btn(" ", "noop"), btn(" ", "noop"), btn(" ", "noop"),
        btn(" ", "noop"), btn(" ", "noop"), btn(" ", "noop"),
        btn(" ", "noop"), btn(" ", "noop"), btn(" ", "noop")
    ];

    integer i        = start;
    integer item_num = 1;
    integer slot_idx = 0;
    while (i < end_idx) {
        string folder_name = llList2String(DiscoveredFolders, i);
        string worn        = llList2String(WornStates, i);
        string worn_ind;
        if (worn == "1")      worn_ind = "[+]";
        else if (worn == "2") worn_ind = "[-]";
        else                  worn_ind = "[ ]";
        string lock_mark = "";
        if (llListFindList(LockedNames, [folder_name]) != -1) lock_mark = "*";
        body += (string)item_num + ". " + worn_ind + " " + folder_name + lock_mark + "\n";

        integer target_slot = llList2Integer(target_slots, slot_idx);
        final_buttons = llListReplaceList(final_buttons,
            [btn((string)item_num, "pick:" + (string)i)],
            target_slot, target_slot);

        item_num += 1;
        slot_idx += 1;
        i += 1;
    }

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",        "ui.dialog.open",
        "session_id",  SessionId,
        "user",        (string)CurrentUser,
        "title",       PLUGIN_LABEL,
        "body",        body,
        "button_data", llList2Json(JSON_ARRAY, final_buttons),
        "timeout",     60
    ]), NULL_KEY);
}

// Shows Attach / Detach / Lock (or Unlock) action buttons for a chosen folder.
show_folder_action(string folder_name) {
    SelectedFolder = folder_name;
    SessionId      = generate_session_id();
    MenuContext    = "action";

    string lock_status;
    if (llListFindList(LockedNames, [folder_name]) != -1) lock_status = "Locked";
    else                                                  lock_status = "Unlocked";

    string worn_status = "Not worn";
    integer folder_idx = llListFindList(DiscoveredFolders, [folder_name]);
    if (folder_idx != -1) {
        string worn = llList2String(WornStates, folder_idx);
        if (worn == "1")      worn_status = "Worn";
        else if (worn == "2") worn_status = "Partially worn";
    }

    string body = folder_name + "\n" + worn_status + " / " + lock_status + "\n\nChoose an action:";

    list button_data = [btn("Back", "back")];
    if (btn_allowed("Attach"))  button_data += [btn("Attach",  "attach")];
    if (btn_allowed("Detach"))  button_data += [btn("Detach",  "detach")];
    if (btn_allowed("Lock"))    button_data += [btn("Lock",    "lock")];
    if (btn_allowed("Unlock"))  button_data += [btn("Unlock",  "unlock")];

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

// Executes app_action on folder_name then returns to the folder list.
apply_folder_action(string folder_name, string app_action) {
    if (app_action == "attach") {
        attach_folder(folder_name);
        llRegionSayTo(CurrentUser, 0, "Attaching: " + folder_name);
    }
    else if (app_action == "detach") {
        if (llListFindList(LockedNames, [folder_name]) != -1) {
            llRegionSayTo(CurrentUser, 0, folder_name + " is locked. Unlock it first.");
        }
        else {
            detach_folder(folder_name);
            llRegionSayTo(CurrentUser, 0, "Detaching: " + folder_name);
        }
    }
    else if (app_action == "lock") {
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
    else if (app_action == "unlock") {
        integer idx = llListFindList(LockedNames, [folder_name]);
        if (idx == -1) {
            llRegionSayTo(CurrentUser, 0, folder_name + " is not locked.");
        }
        else {
            LockedNames = llDeleteSubList(LockedNames, idx, idx);
            unlock_folder(folder_name);
            persist_locked();
            llRegionSayTo(CurrentUser, 0, "Unlocked: " + folder_name);
        }
    }
    show_folder_pick(PickPage);
}

/* -------------------- DIALOG HANDLER -------------------- */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

    key response_user = (key)llJsonGetValue(msg, ["user"]);
    if (response_user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";

    if (MenuContext == "pick") {
        if (ctx == "back") {
            return_to_root();
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
                show_folder_action(llList2String(DiscoveredFolders, idx));
            }
        }
    }
    else if (MenuContext == "action") {
        if (ctx == "back") {
            show_folder_pick(PickPage);
        }
        else if (ctx == "attach" || ctx == "detach" || ctx == "lock" || ctx == "unlock") {
            apply_folder_action(SelectedFolder, ctx);
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
    WornStates        = [];
    if (message != "") {
        // @getinvworn returns "name|wornstate" pairs separated by commas.
        // wornstate: 0=not worn, 1=worn, 2=partially worn.
        list raw = llParseString2List(message, [","], []);
        integer i = 0;
        integer len = llGetListLength(raw);
        while (i < len) {
            string entry = llStringTrim(llList2String(raw, i), STRING_TRIM);
            if (entry != "") {
                integer pipe_pos = llSubStringIndex(entry, "|");
                string folder_name;
                string worn_state;
                if (pipe_pos == -1) {
                    folder_name = entry;
                    worn_state  = "0";
                }
                else {
                    folder_name = llGetSubString(entry, 0, pipe_pos - 1);
                    worn_state  = llGetSubString(entry, pipe_pos + 1, -1);
                }
                DiscoveredFolders += [folder_name];
                WornStates        += [worn_state];
            }
            i += 1;
        }
    }

    if (llGetListLength(DiscoveredFolders) == 0) {
        llRegionSayTo(CurrentUser, 0, "No shared folders found in #RLV.");
        return_to_root();
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
            llRegionSayTo(CurrentUser, 0, "[" + PLUGIN_LABEL + "] RLV not responding. Is RLV mode enabled?");
            return_to_root();
        }
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
