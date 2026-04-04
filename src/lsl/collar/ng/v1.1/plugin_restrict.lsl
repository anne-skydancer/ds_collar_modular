/*--------------------
PLUGIN: plugin_restrict.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Manage RLV restriction toggles grouped by functional category
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
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

string  PLUGIN_CONTEXT = "core_rlvrestrict";
string  PLUGIN_LABEL   = "Restrict";

/* -------------------- SETTINGS KEYS -------------------- */

string KEY_RESTRICTIONS = "rlvrestrict_list";

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


string generate_session_id() {
    return llGetScriptName() + "_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
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

/* -------------------- LIFECYCLE -------------------- */

register_self() {
    // Write button visibility policy to LSD (default-deny per ACL level)
    llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Force Sit,Force Unsit",
        "2", "Force Sit,Force Unsit",
        "3", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "4", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "5", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit"
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

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "dialog_close",
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

    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_RESTRICTIONS,
        "value", csv
    ]), NULL_KEY);
}

apply_settings_sync(string msg) {
    string kv = llJsonGetValue(msg, ["kv"]);
    if (kv == JSON_INVALID) return;

    string csv = llJsonGetValue(kv, [KEY_RESTRICTIONS]);
    if (csv != JSON_INVALID) {

        if (csv != "") {
            Restrictions = llParseString2List(csv, [","], []);

            // Reapply all restrictions
            integer i = 0;
            integer count = llGetListLength(Restrictions);
            while (i < count) {
                string restr_cmd = llList2String(Restrictions, i);
                llOwnerSay(restr_cmd + "=y");
                i = i + 1;
            }
        }
        else {
            Restrictions = [];
        }
    }
}

apply_settings_delta(string msg) {
    string op = llJsonGetValue(msg, ["op"]);
    if (op == JSON_INVALID) return;

    if (op == "set") {
        string changes = llJsonGetValue(msg, ["changes"]);
        if (changes == JSON_INVALID) return;

        string csv = llJsonGetValue(changes, [KEY_RESTRICTIONS]);
        if (csv != JSON_INVALID) {

            // Clear all current restrictions
            integer i = 0;
            integer count = llGetListLength(Restrictions);
            while (i < count) {
                string restr_cmd = llList2String(Restrictions, i);
                llOwnerSay("@clear=" + llGetSubString(restr_cmd, 1, -1));
                i = i + 1;
            }

            // Load new list
            if (csv != "") {
                Restrictions = llParseString2List(csv, [","], []);
            }
            else {
                Restrictions = [];
            }

            // Apply new restrictions
            i = 0;
            count = llGetListLength(Restrictions);
            while (i < count) {
                string restr_cmd = llList2String(Restrictions, i);
                llOwnerSay(restr_cmd + "=y");
                i = i + 1;
            }
        }
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

string label_to_command(string btn_label, list cat_cmds, list cat_labels) {
    // Remove checkbox prefix
    string clean_label = btn_label;
    if (llGetSubString(btn_label, 0, 3) == "[X] " || llGetSubString(btn_label, 0, 3) == "[ ] ") {
        clean_label = llGetSubString(btn_label, 4, -1);
    }

    integer label_idx = llListFindList(cat_labels, [clean_label]);
    if (label_idx != -1) {
        return llList2String(cat_cmds, label_idx);
    }
    return "";
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

    // Build buttons: Back, <<, >>, then numbered buttons
    list buttons = ["Back", "<<", ">>"];
    i = 1;
    while (i <= (end_idx - start_idx)) {
        buttons += [(string)i];
        i = i + 1;
    }

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Force Sit",
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
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
        "type", "return",
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
    list buttons = ["Back"];

    // Build menu from policy
    if (btn_allowed("Inventory"))  buttons += [CAT_NAME_INVENTORY];
    if (btn_allowed("Speech"))     buttons += [CAT_NAME_SPEECH];
    if (btn_allowed("Travel"))     buttons += [CAT_NAME_TRAVEL];
    if (btn_allowed("Other"))      buttons += [CAT_NAME_OTHER];
    if (btn_allowed("Clear all"))  buttons += ["Clear all"];
    if (btn_allowed("Force Sit"))  buttons += ["Force Sit"];
    if (btn_allowed("Force Unsit")) buttons += ["Force Unsit"];

    // Adjust body text based on available buttons
    if (btn_allowed("Inventory")) {
        body = "RLV Restrictions\n\nActive: " + (string)llGetListLength(Restrictions) + "/" + (string)MAX_RESTRICTIONS;
    }
    else {
        body = "RLV Actions\n\nForce sit or unsit the wearer.";
    }

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
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

    // Build button list with checkbox prefixes
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

        page_buttons += [label];
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
    reversed = ["Back", "<<", ">>"] + reversed;

    string body = cat_name + " (" + (string)(page_num + 1) + "/" + (string)(max_page + 1) + ")\n\nActive: " + (string)llGetListLength(Restrictions);

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", cat_name,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, reversed),
        "timeout", 60
    ]), NULL_KEY);
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["button"]) == JSON_INVALID || llJsonGetValue(msg, ["user"]) == JSON_INVALID) return;

    string recv_session = llJsonGetValue(msg, ["session_id"]);
    if (recv_session != SessionId) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    if (user != CurrentUser) return;

    string button = llJsonGetValue(msg, ["button"]);

    // Main menu
    if (MenuContext == "main") {
        if (button == "Back") {
            return_to_root();
        }
        else if (button == CAT_NAME_INVENTORY || button == CAT_NAME_SPEECH ||
                 button == CAT_NAME_TRAVEL || button == CAT_NAME_OTHER) {
            // Restriction categories require policy approval
            if (!btn_allowed(button)) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            show_category_menu(button, 0);
        }
        else if (button == "Clear all") {
            // Clear all requires policy approval
            if (!btn_allowed("Clear all")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            remove_all_restrictions();
            llRegionSayTo(CurrentUser, 0, "All restrictions removed.");
            show_main();
        }
        else if (button == "Force Sit") {
            start_sit_scan();
        }
        else if (button == "Force Unsit") {
            force_unsit();
            show_main();
        }
    }
    // Sit selection menu
    else if (MenuContext == "sit_select") {
        if (button == "Back") {
            show_main();
        }
        else if (button == "<<") {
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
        else if (button == ">>") {
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
            // Numbered button selection
            integer button_num = (integer)button;
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
    // Category menu
    else if (MenuContext == "category") {
        if (button == "Back") {
            show_main();
        }
        else if (button == "<<") {
            list cat_cmds = get_category_list(CurrentCategory);
            integer total_items = llGetListLength(cat_cmds);
            integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;

            if (CurrentPage == 0) {
                // Wrap to last page
                show_category_menu(CurrentCategory, max_page);
            }
            else {
                show_category_menu(CurrentCategory, CurrentPage - 1);
            }
        }
        else if (button == ">>") {
            list cat_cmds = get_category_list(CurrentCategory);
            integer total_items = llGetListLength(cat_cmds);
            integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;

            if (CurrentPage >= max_page) {
                // Wrap to first page
                show_category_menu(CurrentCategory, 0);
            }
            else {
                show_category_menu(CurrentCategory, CurrentPage + 1);
            }
        }
        else {
            // Toggle restriction
            list cat_cmds = get_category_list(CurrentCategory);
            list cat_labels = get_category_labels(CurrentCategory);

            string restr_cmd = label_to_command(button, cat_cmds, cat_labels);

            if (restr_cmd != "") {
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
        register_self();

        // Request settings
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
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

    link_message(integer sender, integer num, string msg, key id) {
        string type = llJsonGetValue(msg, ["type"]);
        if (type == JSON_INVALID) return;

        // Kernel lifecycle
        if (num == KERNEL_LIFECYCLE) {
            if (type == "register_now") {
                register_self();
                // CRITICAL FIX: Re-request settings after kernel reset to reapply RLV restrictions
                llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
                    "type", "settings_get"
                ]), NULL_KEY);
            }
            else if (type == "ping") {
                send_pong();
            }
            else if (type == "soft_reset") {
                llResetScript();
            }
        }
        // Settings
        else if (num == SETTINGS_BUS) {
            if (type == "settings_sync") {
                apply_settings_sync(msg);
            }
            else if (type == "settings_delta") {
                apply_settings_delta(msg);
            }
        }
        // UI
        else if (num == UI_BUS) {
            if (type == "start") {
                string context = llJsonGetValue(msg, ["context"]);
                if (context == JSON_INVALID) return;

                if (context == PLUGIN_CONTEXT) {
                    CurrentUser = id;
                    UserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                    show_main();
                }
            }
        }
        // Dialogs
        else if (num == DIALOG_BUS) {
            if (type == "dialog_response") {
                handle_dialog_response(msg);
            }
            else if (type == "dialog_timeout") {
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
