/*--------------------
PLUGIN: plugin_restrict.lsl
VERSION: 1.10
REVISION: 6
PURPOSE: Manage RLV restriction toggles grouped by functional category
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 6: Honor kernel.reset.factory in addition to kernel.reset.soft,
  and handle sos.restrict.clear by clearing all RLV restrictions. Factory
  reset previously left cached state; SOS emergency clear wasn't wired.
- v1.1 rev 5: Wire-type rename (Phase 2). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.reset→kernel.reset.soft.
- v1.1 rev 4: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.1 rev 3: Namespace internal message type strings (kernel.*, ui.*, settings.*).
- v1.1 rev 2: Migrate dialog buttons to button_data format with context-based routing.
- v1.1 rev 1: Migrate from JSON broadcast payloads to direct LSD reads.
  Remove apply_settings_delta() and request_settings_sync(). apply_settings_sync()
  is now parameterless and reads restrict.list from LSD. Uses previous-state
  comparison to clear old RLV restrictions and apply new ones on change.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL / RESTRICT_MIN_ACL checks with policy reads
  via get_policy_buttons() and btn_allowed(). Removed PLUGIN_MIN_ACL,
  RESTRICT_MIN_ACL, and min_acl from kernel registration message.
--------------------*/


/* -------------------- CHANNELS (v2 Consolidated Architecture) -------------------- */

integer KERNEL_LIFECYCLE = 500;  // register, ping/pong, soft_reset
integer SETTINGS_BUS     = 800;  // Settings sync and delta
integer UI_BUS           = 900;  // UI navigation (start, return, close)
integer DIALOG_BUS       = 950;  // Centralized dialog management

/* -------------------- PLUGIN IDENTITY -------------------- */

string  PLUGIN_CONTEXT = "ui.core.rlvrestrict";
string  PLUGIN_LABEL   = "Restrict";

/* -------------------- SETTINGS KEYS -------------------- */

string KEY_RESTRICTIONS = "restrict.list";

/* -------------------- RESTRICTION STATE -------------------- */

integer MAX_RESTRICTIONS = 32;
list Restrictions = [];  // List of active RLV commands (e.g., "@shownames")

/* -------------------- CATEGORIES -------------------- */

string CAT_NAME_INVENTORY = "Inventory";
string CAT_NAME_SPEECH    = "Speech";
string CAT_NAME_TRAVEL    = "Travel";
string CAT_NAME_OTHER     = "Other";

list CAT_INV    = ["@detachall", "@addoutfit", "@remoutfit", "@remattach", "@addattach", "@attachall", "@showinv", "@viewnote", "@viewscript"];
list CAT_SPEECH = ["@sendchat", "@recvim", "@sendim", "@startim", "@chatshout", "@chatwhisper"];
list CAT_TRAVEL = ["@tptlm", "@tploc", "@tplure"];
list CAT_OTHER  = ["@edit", "@rez", "@touchall", "@touchworld", "@accepttp", "@shownames", "@sit", "@unsit", "@stand"];

list LABEL_INV    = ["Det. All:", "+ Outfit:", "- Outfit:", "- Attach:", "+ Attach:", "Att. All:", "Inv:", "Notes:", "Scripts:"];
list LABEL_SPEECH = ["Chat:", "Recv IM:", "Send IM:", "Start IM:", "Shout:", "Whisper:"];
list LABEL_TRAVEL = ["Map TP:", "Loc. TP:", "TP:"];
list LABEL_OTHER  = ["Edit:", "Rez:", "Touch:", "Touch Wld:", "OK TP:", "Names:", "Sit:", "Unsit:", "Stand:"];

/* -------------------- UI SESSION STATE -------------------- */

string SessionId = "";
key CurrentUser = NULL_KEY;
integer UserAcl = 0;
list gPolicyButtons = [];

string MenuContext = "";      // "main", "category"
string CurrentCategory = "";
integer CurrentPage = 0;

integer DIALOG_PAGE_SIZE = 9;  // 9 items + 3 nav buttons = 12 total

/* -------------------- FORCE SIT STATE -------------------- */

list SitCandidates = [];  // Stride list: [name, key, name, key, ...]
integer SitPage = 0;
float SIT_SCAN_RANGE = 10.0;  // Scan range in meters
key ScanInitiator = NULL_KEY;  // Track who initiated the scan to prevent race conditions

/* -------------------- HELPER FUNCTIONS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string generate_session_id() {
    return llGetScriptName() + "_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD POLICY HELPER -------------------- */
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
    // Write button visibility policy to LSD (default-deny per ACL level)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Force Sit,Force Unsit",
        "2", "Force Sit,Force Unsit",
        "3", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "4", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "5", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit"
    ]));

    // Register with kernel
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
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }

    SessionId = "";
    CurrentUser = NULL_KEY;
    UserAcl = 0;
    gPolicyButtons = [];
    MenuContext = "";
    CurrentCategory = "";
    CurrentPage = 0;
}

/* -------------------- SETTINGS PERSISTENCE -------------------- */

persist_restrictions() {
    string csv = llDumpList2String(Restrictions, ",");

    // Write to LSD immediately so restrictions survive relog
    llLinksetDataWrite(KEY_RESTRICTIONS, csv);

    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_RESTRICTIONS,
        "value", csv
    ]), NULL_KEY);
}

apply_settings_sync() {
    string csv = llLinksetDataRead(KEY_RESTRICTIONS);
    list new_list = [];
    if (csv != "") {
        new_list = llParseString2List(csv, [","], []);
    }

    // Compare with current state; if unchanged, nothing to do
    if (llDumpList2String(new_list, ",") == llDumpList2String(Restrictions, ",")) return;

    // Clear all current restrictions
    integer i = 0;
    integer count = llGetListLength(Restrictions);
    while (i < count) {
        string restr_cmd = llList2String(Restrictions, i);
        llOwnerSay("@clear=" + llGetSubString(restr_cmd, 1, -1));
        i = i + 1;
    }

    // Apply new restrictions
    Restrictions = new_list;
    i = 0;
    count = llGetListLength(Restrictions);
    while (i < count) {
        llOwnerSay(llList2String(Restrictions, i) + "=y");
        i = i + 1;
    }
}

/* -------------------- RESTRICTION LOGIC -------------------- */

integer restriction_idx(string restr_cmd) {
    return llListFindList(Restrictions, [restr_cmd]);
}

toggle_restriction(string restr_cmd) {
    integer idx = restriction_idx(restr_cmd);

    if (idx != -1) {
        // Remove restriction
        Restrictions = llDeleteSubList(Restrictions, idx, idx);
        llOwnerSay("@clear=" + llGetSubString(restr_cmd, 1, -1));
    }
    else {
        // Add restriction
        if (llGetListLength(Restrictions) >= MAX_RESTRICTIONS) {
            llRegionSayTo(CurrentUser, 0, "Cannot add restriction: limit reached.");
            return;
        }

        Restrictions += [restr_cmd];
        llOwnerSay(restr_cmd + "=y");
    }

    persist_restrictions();
}

remove_all_restrictions() {
    integer i = 0;
    integer count = llGetListLength(Restrictions);
    while (i < count) {
        string restr_cmd = llList2String(Restrictions, i);
        llOwnerSay("@clear=" + llGetSubString(restr_cmd, 1, -1));
        i = i + 1;
    }

    Restrictions = [];
    persist_restrictions();
}

/* -------------------- CATEGORY HELPERS -------------------- */

list get_category_list(string cat_name) {
    if (cat_name == CAT_NAME_INVENTORY) return CAT_INV;
    if (cat_name == CAT_NAME_SPEECH) return CAT_SPEECH;
    if (cat_name == CAT_NAME_TRAVEL) return CAT_TRAVEL;
    if (cat_name == CAT_NAME_OTHER) return CAT_OTHER;
    return [];
}

list get_category_labels(string cat_name) {
    if (cat_name == CAT_NAME_INVENTORY) return LABEL_INV;
    if (cat_name == CAT_NAME_SPEECH) return LABEL_SPEECH;
    if (cat_name == CAT_NAME_TRAVEL) return LABEL_TRAVEL;
    if (cat_name == CAT_NAME_OTHER) return LABEL_OTHER;
    return [];
}

/* -------------------- FORCE SIT/UNSIT -------------------- */

start_sit_scan() {
    SitCandidates = [];
    SitPage = 0;
    MenuContext = "sit_scan";
    ScanInitiator = CurrentUser;  // Lock scan to this user

    llRegionSayTo(CurrentUser, 0, "Scanning for nearby objects...");
    llSensor("", NULL_KEY, PASSIVE | ACTIVE | SCRIPTED, SIT_SCAN_RANGE, PI);
}

display_sit_targets() {
    integer total_items = llGetListLength(SitCandidates) / 2;

    if (total_items == 0) {
        llRegionSayTo(CurrentUser, 0, "No objects found nearby.");
        show_main();
        return;
    }

    SessionId = generate_session_id();
    MenuContext = "sit_select";

    // Calculate pagination (9 items per page to leave room for nav buttons)
    integer items_per_page = 9;
    integer total_pages = (total_items + items_per_page - 1) / items_per_page;
    integer start_idx = SitPage * items_per_page;
    integer end_idx = start_idx + items_per_page;
    if (end_idx > total_items) end_idx = total_items;

    // Build numbered list body
    string body = "Select object to sit on:\n\n";
    integer i = start_idx;
    integer display_num = 1;
    while (i < end_idx) {
        string obj_name = llList2String(SitCandidates, i * 2);
        // Truncate long names for display
        if (llStringLength(obj_name) > 20) {
            obj_name = llGetSubString(obj_name, 0, 17) + "...";
        }
        body += (string)display_num + ". " + obj_name + "\n";
        display_num = display_num + 1;
        i = i + 1;
    }

    if (total_pages > 1) {
        body += "\nPage " + (string)(SitPage + 1) + "/" + (string)total_pages;
    }

    // Build button_data: Back, <<, >>, then numbered buttons
    list button_data = [btn("Back", "back"), btn("<<", "prev_page"), btn(">>", "next_page")];
    i = 1;
    while (i <= (end_idx - start_idx)) {
        button_data += [btn((string)i, "sit_" + (string)i)];
        i = i + 1;
    }

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Force Sit",
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);
}

force_sit_on(key target) {
    if (target == NULL_KEY) return;

    llOwnerSay("@sit:" + (string)target + "=force");
    llRegionSayTo(CurrentUser, 0, "Forcing sit...");
}

force_unsit() {
    llOwnerSay("@unsit=force");
    llRegionSayTo(CurrentUser, 0, "Forcing unsit...");
}

/* -------------------- UI NAVIGATION -------------------- */

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]), NULL_KEY);

    cleanup_session();
}

/* -------------------- MENUS -------------------- */

show_main() {
    SessionId = generate_session_id();
    MenuContext = "main";

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string body;
    list button_data = [btn("Back", "back")];

    // Build menu from policy
    if (btn_allowed("Inventory"))  button_data += [btn(CAT_NAME_INVENTORY, "cat_inventory")];
    if (btn_allowed("Speech"))     button_data += [btn(CAT_NAME_SPEECH, "cat_speech")];
    if (btn_allowed("Travel"))     button_data += [btn(CAT_NAME_TRAVEL, "cat_travel")];
    if (btn_allowed("Other"))      button_data += [btn(CAT_NAME_OTHER, "cat_other")];
    if (btn_allowed("Clear all"))  button_data += [btn("Clear all", "clear_all")];
    if (btn_allowed("Force Sit"))  button_data += [btn("Force Sit", "force_sit")];
    if (btn_allowed("Force Unsit")) button_data += [btn("Force Unsit", "force_unsit")];

    // Adjust body text based on available buttons
    if (btn_allowed("Inventory")) {
        body = "RLV Restrictions\n\nActive: " + (string)llGetListLength(Restrictions) + "/" + (string)MAX_RESTRICTIONS;
    }
    else {
        body = "RLV Actions\n\nForce sit or unsit the wearer.";
    }

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

show_category_menu(string cat_name, integer page_num) {
    SessionId = generate_session_id();
    MenuContext = "category";
    CurrentCategory = cat_name;
    CurrentPage = page_num;

    list cat_cmds = get_category_list(cat_name);
    list cat_labels = get_category_labels(cat_name);
    integer total_items = llGetListLength(cat_cmds);

    if (total_items == 0) {
        llRegionSayTo(CurrentUser, 0, "Empty category.");
        show_main();
        return;
    }

    // Calculate page bounds
    integer start_idx = page_num * DIALOG_PAGE_SIZE;
    integer end_idx = start_idx + DIALOG_PAGE_SIZE - 1;
    if (end_idx >= total_items) {
        end_idx = total_items - 1;
    }

    // Build button_data list with checkbox prefixes
    list page_buttons = [];
    integer i = start_idx;
    while (i <= end_idx) {
        string cmd = llList2String(cat_cmds, i);
        string label = llList2String(cat_labels, i);

        integer is_active = (restriction_idx(cmd) != -1);
        if (is_active) {
            label = "[X] " + label;
        }
        else {
            label = "[ ] " + label;
        }

        page_buttons += [btn(label, cmd)];
        i = i + 1;
    }

    // Calculate max page
    integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;

    // Reverse the order so items fill bottom-right to top-left
    list reversed = [];
    i = llGetListLength(page_buttons) - 1;
    while (i >= 0) {
        reversed += [llList2String(page_buttons, i)];
        i = i - 1;
    }

    // Add nav buttons in bottom-left corner (positions 0, 1, 2)
    reversed = [btn("Back", "back"), btn("<<", "prev_page"), btn(">>", "next_page")] + reversed;

    string body = cat_name + " (" + (string)(page_num + 1) + "/" + (string)(max_page + 1) + ")\n\nActive: " + (string)llGetListLength(Restrictions);

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", cat_name,
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, reversed),
        "timeout", 60
    ]), NULL_KEY);
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["context"]) == JSON_INVALID || llJsonGetValue(msg, ["user"]) == JSON_INVALID) return;

    string recv_session = llJsonGetValue(msg, ["session_id"]);
    if (recv_session != SessionId) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    if (user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);

    // Main menu
    if (MenuContext == "main") {
        if (ctx == "back") {
            return_to_root();
        }
        else if (ctx == "cat_inventory") {
            if (!btn_allowed("Inventory")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            show_category_menu(CAT_NAME_INVENTORY, 0);
        }
        else if (ctx == "cat_speech") {
            if (!btn_allowed("Speech")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            show_category_menu(CAT_NAME_SPEECH, 0);
        }
        else if (ctx == "cat_travel") {
            if (!btn_allowed("Travel")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            show_category_menu(CAT_NAME_TRAVEL, 0);
        }
        else if (ctx == "cat_other") {
            if (!btn_allowed("Other")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            show_category_menu(CAT_NAME_OTHER, 0);
        }
        else if (ctx == "clear_all") {
            if (!btn_allowed("Clear all")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            remove_all_restrictions();
            llRegionSayTo(CurrentUser, 0, "All restrictions removed.");
            show_main();
        }
        else if (ctx == "force_sit") {
            start_sit_scan();
        }
        else if (ctx == "force_unsit") {
            force_unsit();
            show_main();
        }
    }
    // Sit selection menu
    else if (MenuContext == "sit_select") {
        if (ctx == "back") {
            show_main();
        }
        else if (ctx == "prev_page") {
            integer total_items = llGetListLength(SitCandidates) / 2;
            integer items_per_page = 9;
            integer max_page = (total_items - 1) / items_per_page;

            if (SitPage == 0) {
                SitPage = max_page;
            }
            else {
                SitPage = SitPage - 1;
            }
            display_sit_targets();
        }
        else if (ctx == "next_page") {
            integer total_items = llGetListLength(SitCandidates) / 2;
            integer items_per_page = 9;
            integer max_page = (total_items - 1) / items_per_page;

            if (SitPage >= max_page) {
                SitPage = 0;
            }
            else {
                SitPage = SitPage + 1;
            }
            display_sit_targets();
        }
        else {
            // Numbered button selection: context is "sit_N"
            if (llGetSubString(ctx, 0, 3) == "sit_") {
                integer button_num = (integer)llGetSubString(ctx, 4, -1);
                if (button_num >= 1 && button_num <= 9) {
                    integer items_per_page = 9;
                    integer actual_idx = (SitPage * items_per_page) + (button_num - 1);
                    integer list_idx = actual_idx * 2;  // Stride list: [name, key, ...]

                    if (list_idx + 1 < llGetListLength(SitCandidates)) {
                        key target = (key)llList2String(SitCandidates, list_idx + 1);
                        force_sit_on(target);
                        show_main();
                    }
                }
            }
        }
    }
    // Category menu
    else if (MenuContext == "category") {
        if (ctx == "back") {
            show_main();
        }
        else if (ctx == "prev_page") {
            list cat_cmds = get_category_list(CurrentCategory);
            integer total_items = llGetListLength(cat_cmds);
            integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;

            if (CurrentPage == 0) {
                show_category_menu(CurrentCategory, max_page);
            }
            else {
                show_category_menu(CurrentCategory, CurrentPage - 1);
            }
        }
        else if (ctx == "next_page") {
            list cat_cmds = get_category_list(CurrentCategory);
            integer total_items = llGetListLength(cat_cmds);
            integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;

            if (CurrentPage >= max_page) {
                show_category_menu(CurrentCategory, 0);
            }
            else {
                show_category_menu(CurrentCategory, CurrentPage + 1);
            }
        }
        else {
            // Context is the RLV command directly (e.g., "@detachall")
            string restr_cmd = ctx;
            if (restriction_idx(restr_cmd) != -1 || llGetSubString(restr_cmd, 0, 0) == "@") {
                toggle_restriction(restr_cmd);
                show_category_menu(CurrentCategory, CurrentPage);
            }
        }
    }
}

handle_dialog_timeout(string msg) {
    string recv_session = llJsonGetValue(msg, ["session_id"]);
    if (recv_session == JSON_INVALID) return;
    if (recv_session != SessionId) return;

    cleanup_session();
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

    link_message(integer sender, integer num, string msg, key id) {
        string type = llJsonGetValue(msg, ["type"]);
        if (type == JSON_INVALID) return;

        // Kernel lifecycle
        if (num == KERNEL_LIFECYCLE) {
            if (type == "kernel.register.refresh") {
                register_self();
                apply_settings_sync();
            }
            else if (type == "kernel.ping") {
                send_pong();
            }
            else if (type == "kernel.reset.soft" || type == "kernel.reset.factory") {
                llResetScript();
            }
        }
        // Settings
        else if (num == SETTINGS_BUS) {
            if (type == "settings.sync" || type == "settings.delta") {
                apply_settings_sync();
            }
        }
        // UI
        else if (num == UI_BUS) {
            if (type == "ui.menu.start") {
                string context = llJsonGetValue(msg, ["context"]);
                if (context == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;

                if (context == PLUGIN_CONTEXT) {
                    CurrentUser = id;
                    UserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                    show_main();
                }
            }
            else if (type == "sos.restrict.clear") {
                // Emergency clear from plugin_sos (wearer-only gate enforced
                // upstream). Drop every active RLV restriction.
                remove_all_restrictions();
            }
        }
        // Dialogs
        else if (num == DIALOG_BUS) {
            if (type == "ui.dialog.response") {
                handle_dialog_response(msg);
            }
            else if (type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
            }
        }
    }

    sensor(integer num_detected) {
        if (MenuContext != "sit_scan") return;
        if (CurrentUser == NULL_KEY) return;
        // Verify scan belongs to the user who initiated it (race condition guard)
        if (CurrentUser != ScanInitiator) return;

        key wearer = llGetOwner();
        key my_key = llGetKey();
        SitCandidates = [];

        integer i = 0;
        while (i < num_detected) {
            key detected_key = llDetectedKey(i);
            // Exclude self (collar) and wearer
            if (detected_key != my_key && detected_key != wearer) {
                string detected_name = llDetectedName(i);
                SitCandidates += [detected_name, detected_key];
            }
            i = i + 1;
        }

        display_sit_targets();
    }

    no_sensor() {
        if (MenuContext != "sit_scan") return;
        if (CurrentUser == NULL_KEY) return;
        // Verify scan belongs to the user who initiated it (race condition guard)
        if (CurrentUser != ScanInitiator) return;

        llRegionSayTo(CurrentUser, 0, "No objects found within " + (string)((integer)SIT_SCAN_RANGE) + "m.");
        show_main();
    }
}
