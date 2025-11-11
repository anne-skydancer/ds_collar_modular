// =============================================================
// PLUGIN: ds_collar_plugin_rlvrestrict.lsl (v2)
// PURPOSE: RLV Restriction Management Plugin
// ARCHITECTURE: v2 Consolidated ABI (5 channels)
// =============================================================

integer DEBUG = FALSE;

/* ═══════════════════════════════════════════════════════════
   CHANNELS (v2 Consolidated Architecture)
   ═══════════════════════════════════════════════════════════ */

integer KERNEL_LIFECYCLE = 500;  // register, ping/pong, soft_reset
integer AUTH_BUS         = 700;  // ACL queries and results
integer SETTINGS_BUS     = 800;  // Settings sync and delta
integer UI_BUS           = 900;  // UI navigation (start, return, close)
integer DIALOG_BUS       = 950;  // Centralized dialog management

/* ═══════════════════════════════════════════════════════════
   PLUGIN IDENTITY
   ═══════════════════════════════════════════════════════════ */

string  PLUGIN_CONTEXT = "core_rlvrestrict";
string  PLUGIN_LABEL   = "Restrict";
integer PLUGIN_MIN_ACL = 3;  // Trustee+

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */

string KEY_RESTRICTIONS = "rlvrestrict_list";

/* ═══════════════════════════════════════════════════════════
   RESTRICTION STATE
   ═══════════════════════════════════════════════════════════ */

integer MAX_RESTRICTIONS = 32;
list Restrictions = [];  // List of active RLV commands (e.g., "@shownames")

/* ═══════════════════════════════════════════════════════════
   CATEGORIES
   ═══════════════════════════════════════════════════════════ */

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

/* ═══════════════════════════════════════════════════════════
   UI SESSION STATE
   ═══════════════════════════════════════════════════════════ */

string SessionId = "";
key CurrentUser = NULL_KEY;
integer UserAcl = 0;

string MenuContext = "";      // "main", "category"
string CurrentCategory = "";
integer CurrentPage = 0;

integer DIALOG_PAGE_SIZE = 9;  // 9 items + 3 nav buttons = 12 total

/* ═══════════════════════════════════════════════════════════
   HELPER FUNCTIONS
   ═══════════════════════════════════════════════════════════ */

integer json_has(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

logd(string msg) {
    if (DEBUG) {
        llOwnerSay("[RLVRESTRICT] " + msg);
    }
}

string generate_session_id() {
    return llGetScriptName() + "_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   LIFECYCLE
   ═══════════════════════════════════════════════════════════ */

register_self() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]), NULL_KEY);
    
    logd("Registered with kernel");
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
    MenuContext = "";
    CurrentCategory = "";
    CurrentPage = 0;
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS PERSISTENCE
   ═══════════════════════════════════════════════════════════ */

persist_restrictions() {
    string csv = llDumpList2String(Restrictions, ",");
    
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_RESTRICTIONS,
        "value", csv
    ]), NULL_KEY);
    
    logd("Persisted restrictions: " + csv);
}

apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    
    string kv = llJsonGetValue(msg, ["kv"]);
    
    if (json_has(kv, [KEY_RESTRICTIONS])) {
        string csv = llJsonGetValue(kv, [KEY_RESTRICTIONS]);
        
        if (csv != "") {
            Restrictions = llParseString2List(csv, [","], []);
            logd("Loaded " + (string)llGetListLength(Restrictions) + " restrictions from settings");
            
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
            logd("No restrictions loaded");
        }
    }
}

apply_settings_delta(string msg) {
    if (!json_has(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (json_has(changes, [KEY_RESTRICTIONS])) {
            string csv = llJsonGetValue(changes, [KEY_RESTRICTIONS]);
            
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
            
            logd("Delta: restrictions updated");
        }
    }
}

/* ═══════════════════════════════════════════════════════════
   ACL
   ═══════════════════════════════════════════════════════════ */

request_acl(key user) {
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_acl"
    ]), NULL_KEY);
}

handle_acl_result(string msg) {
    if (!json_has(msg, ["avatar"]) || !json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    UserAcl = (integer)llJsonGetValue(msg, ["level"]);
    
    if (UserAcl < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanup_session();
        return;
    }
    
    show_main();
}

/* ═══════════════════════════════════════════════════════════
   RESTRICTION LOGIC
   ═══════════════════════════════════════════════════════════ */

integer restriction_idx(string restr_cmd) {
    return llListFindList(Restrictions, [restr_cmd]);
}

toggle_restriction(string restr_cmd) {
    integer idx = restriction_idx(restr_cmd);
    
    if (idx != -1) {
        // Remove restriction
        Restrictions = llDeleteSubList(Restrictions, idx, idx);
        llOwnerSay("@clear=" + llGetSubString(restr_cmd, 1, -1));
        logd("Removed restriction: " + restr_cmd);
    }
    else {
        // Add restriction
        if (llGetListLength(Restrictions) >= MAX_RESTRICTIONS) {
            llRegionSayTo(CurrentUser, 0, "Cannot add restriction: limit reached.");
            return;
        }
        
        Restrictions += [restr_cmd];
        llOwnerSay(restr_cmd + "=y");
        logd("Added restriction: " + restr_cmd);
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
    logd("All restrictions removed via safeword");
}

/* ═══════════════════════════════════════════════════════════
   CATEGORY HELPERS
   ═══════════════════════════════════════════════════════════ */

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

/* ═══════════════════════════════════════════════════════════
   UI NAVIGATION
   ═══════════════════════════════════════════════════════════ */

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]), NULL_KEY);
    
    cleanup_session();
}

/* ═══════════════════════════════════════════════════════════
   MENUS
   ═══════════════════════════════════════════════════════════ */

show_main() {
    SessionId = generate_session_id();
    MenuContext = "main";
    
    string body = "RLV Restrictions\n\nActive: " + (string)llGetListLength(Restrictions) + "/" + (string)MAX_RESTRICTIONS;
    
    list buttons = [
        "Back",
        CAT_NAME_INVENTORY,
        CAT_NAME_SPEECH,
        CAT_NAME_TRAVEL,
        CAT_NAME_OTHER,
        "Clear all"
    ];
    
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
    
    // Layout: Nav buttons in bottom-left, content fills from bottom-right upward
    // [item 8] [item 9] [item 10]
    // [item 5] [item 6] [item 7]
    // [item 2] [item 3] [item 4]
    // [Back]   [<<]     [>>] [item 1]
    
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

/* ═══════════════════════════════════════════════════════════
   DIALOG HANDLERS
   ═══════════════════════════════════════════════════════════ */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"]) || !json_has(msg, ["button"]) || !json_has(msg, ["user"])) return;
    
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
            show_category_menu(button, 0);
        }
        else if (button == "Clear all") {
            remove_all_restrictions();
            llRegionSayTo(CurrentUser, 0, "All restrictions removed.");
            show_main();
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
    if (!json_has(msg, ["session_id"])) return;
    
    string recv_session = llJsonGetValue(msg, ["session_id"]);
    if (recv_session != SessionId) return;
    
    cleanup_session();
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default
{
    state_entry() {
        cleanup_session();
        register_self();
        
        // Request settings
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]), NULL_KEY);
        
        logd("Plugin initialized");
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
        if (!json_has(msg, ["type"])) return;
        
        string type = llJsonGetValue(msg, ["type"]);
        
        // Kernel lifecycle
        if (num == KERNEL_LIFECYCLE) {
            if (type == "register_now") {
                register_self();
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
        // ACL
        else if (num == AUTH_BUS) {
            if (type == "acl_result") {
                handle_acl_result(msg);
            }
        }
        // UI
        else if (num == UI_BUS) {
            if (type == "start") {
                if (!json_has(msg, ["context"])) return;
                string context = llJsonGetValue(msg, ["context"]);
                
                if (context == PLUGIN_CONTEXT) {
                    CurrentUser = id;
                    request_acl(CurrentUser);
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
}
