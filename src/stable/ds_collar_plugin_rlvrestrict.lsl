/* ===============================================================
   PLUGIN: ds_collar_plugin_rlvrestrict.lsl (v1.0 - Consolidated ABI)

   PURPOSE: RLV Restriction Management Plugin
   =============================================================== */

integer DEBUG = FALSE;

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */

integer KERNEL_LIFECYCLE = 500;  // register, ping/pong, soft_reset
integer AUTH_BUS         = 700;  // ACL queries and results
integer SETTINGS_BUS     = 800;  // Settings sync and delta
integer UI_BUS           = 900;  // UI navigation (start, return, close)
integer DIALOG_BUS       = 950;  // Centralized dialog management

/* ===============================================================
   PLUGIN IDENTITY
   =============================================================== */

string  PLUGIN_CONTEXT = "core_rlvrestrict";
string  PLUGIN_LABEL   = "Restrict";
integer PLUGIN_MIN_ACL = 3;  // Trustee+

/* ===============================================================
   SETTINGS KEYS
   =============================================================== */

string KEY_RESTRICTIONS = "rlvrestrict_list";

/* ===============================================================
   RESTRICTION STATE
   =============================================================== */

integer MAX_RESTRICTIONS = 32;
list Restrictions = [];  // List of active RLV commands (e.g., "@shownames")

/* ===============================================================
   CATEGORIES
   =============================================================== */

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

/* ===============================================================
   UI SESSION STATE
   =============================================================== */

string SessionId = "";
key CurrentUser = NULL_KEY;
integer UserAcl = 0;

string MenuContext = "";      // "main", "category"
string CurrentCategory = "";
integer CurrentPage = 0;

integer DIALOG_PAGE_SIZE = 9;  // 9 items + 3 nav buttons = 12 total

/* ===============================================================
   HELPER FUNCTIONS
   =============================================================== */

integer jsonHas(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

integer logd(string msg) {
    if (DEBUG) {
        llOwnerSay("[RLVRESTRICT] " + msg);
    }
    return FALSE;
}

string generateSessionId() {
    return llGetScriptName() + "_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

/* ===============================================================
   LIFECYCLE
   =============================================================== */

registerSelf() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]), NULL_KEY);
    
    logd("Registered with kernel");
}

sendPong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

cleanupSession() {
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

/* ===============================================================
   SETTINGS PERSISTENCE
   =============================================================== */

persistRestrictions() {
    string csv = llDumpList2String(Restrictions, ",");
    
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_RESTRICTIONS,
        "value", csv
    ]), NULL_KEY);
    
    logd("Persisted restrictions: " + csv);
}

applySettingsSync(string msg) {
    if (!jsonHas(msg, ["kv"])) return;
    
    string kv = llJsonGetValue(msg, ["kv"]);
    
    if (jsonHas(kv, [KEY_RESTRICTIONS])) {
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

applySettingsDelta(string msg) {
    if (!jsonHas(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!jsonHas(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (jsonHas(changes, [KEY_RESTRICTIONS])) {
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

/* ===============================================================
   ACL
   =============================================================== */

requestAcl(key user) {
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_acl"
    ]), NULL_KEY);
}

handleAclResult(string msg) {
    if (!jsonHas(msg, ["avatar"]) || !jsonHas(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    UserAcl = (integer)llJsonGetValue(msg, ["level"]);
    
    if (UserAcl < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanupSession();
        return;
    }
    
    showMain();
}

/* ===============================================================
   RESTRICTION LOGIC
   =============================================================== */

integer restrictionIdx(string restr_cmd) {
    return llListFindList(Restrictions, [restr_cmd]);
}

toggleRestriction(string restr_cmd) {
    integer idx = restrictionIdx(restr_cmd);
    
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
    
    persistRestrictions();
}

removeAllRestrictions() {
    integer i = 0;
    integer count = llGetListLength(Restrictions);
    while (i < count) {
        string restr_cmd = llList2String(Restrictions, i);
        llOwnerSay("@clear=" + llGetSubString(restr_cmd, 1, -1));
        i = i + 1;
    }
    
    Restrictions = [];
    persistRestrictions();
    logd("All restrictions removed via safeword");
}

/* ===============================================================
   CATEGORY HELPERS
   =============================================================== */

list getCategoryList(string cat_name) {
    if (cat_name == CAT_NAME_INVENTORY) return CAT_INV;
    if (cat_name == CAT_NAME_SPEECH) return CAT_SPEECH;
    if (cat_name == CAT_NAME_TRAVEL) return CAT_TRAVEL;
    if (cat_name == CAT_NAME_OTHER) return CAT_OTHER;
    return [];
}

list getCategoryLabels(string cat_name) {
    if (cat_name == CAT_NAME_INVENTORY) return LABEL_INV;
    if (cat_name == CAT_NAME_SPEECH) return LABEL_SPEECH;
    if (cat_name == CAT_NAME_TRAVEL) return LABEL_TRAVEL;
    if (cat_name == CAT_NAME_OTHER) return LABEL_OTHER;
    return [];
}

string labelToCommand(string btn_label, list cat_cmds, list cat_labels) {
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

/* ===============================================================
   UI NAVIGATION
   =============================================================== */

returnToRoot() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]), NULL_KEY);
    
    cleanupSession();
}

/* ===============================================================
   MENUS
   =============================================================== */

showMain() {
    SessionId = generateSessionId();
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

showCategoryMenu(string cat_name, integer page_num) {
    SessionId = generateSessionId();
    MenuContext = "category";
    CurrentCategory = cat_name;
    CurrentPage = page_num;
    
    list cat_cmds = getCategoryList(cat_name);
    list cat_labels = getCategoryLabels(cat_name);
    integer total_items = llGetListLength(cat_cmds);
    
    if (total_items == 0) {
        llRegionSayTo(CurrentUser, 0, "Empty category.");
        showMain();
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
        
        integer is_active = (restrictionIdx(cmd) != -1);
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

/* ===============================================================
   DIALOG HANDLERS
   =============================================================== */

handleDialogResponse(string msg) {
    if (!jsonHas(msg, ["session_id"]) || !jsonHas(msg, ["button"]) || !jsonHas(msg, ["user"])) return;
    
    string recv_session = llJsonGetValue(msg, ["session_id"]);
    if (recv_session != SessionId) return;
    
    key user = (key)llJsonGetValue(msg, ["user"]);
    if (user != CurrentUser) return;
    
    string button = llJsonGetValue(msg, ["button"]);
    
    // Main menu
    if (MenuContext == "main") {
        if (button == "Back") {
            returnToRoot();
        }
        else if (button == CAT_NAME_INVENTORY || button == CAT_NAME_SPEECH || 
                 button == CAT_NAME_TRAVEL || button == CAT_NAME_OTHER) {
            showCategoryMenu(button, 0);
        }
        else if (button == "Clear all") {
            removeAllRestrictions();
            llRegionSayTo(CurrentUser, 0, "All restrictions removed.");
            showMain();
        }
    }
    // Category menu
    else if (MenuContext == "category") {
        if (button == "Back") {
            showMain();
        }
        else if (button == "<<") {
            list cat_cmds = getCategoryList(CurrentCategory);
            integer total_items = llGetListLength(cat_cmds);
            integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;
            
            if (CurrentPage == 0) {
                // Wrap to last page
                showCategoryMenu(CurrentCategory, max_page);
            }
            else {
                showCategoryMenu(CurrentCategory, CurrentPage - 1);
            }
        }
        else if (button == ">>") {
            list cat_cmds = getCategoryList(CurrentCategory);
            integer total_items = llGetListLength(cat_cmds);
            integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;
            
            if (CurrentPage >= max_page) {
                // Wrap to first page
                showCategoryMenu(CurrentCategory, 0);
            }
            else {
                showCategoryMenu(CurrentCategory, CurrentPage + 1);
            }
        }
        else {
            // Toggle restriction
            list cat_cmds = getCategoryList(CurrentCategory);
            list cat_labels = getCategoryLabels(CurrentCategory);
            
            string restr_cmd = labelToCommand(button, cat_cmds, cat_labels);
            
            if (restr_cmd != "") {
                toggleRestriction(restr_cmd);
                showCategoryMenu(CurrentCategory, CurrentPage);
            }
        }
    }
}

handleDialogTimeout(string msg) {
    if (!jsonHas(msg, ["session_id"])) return;
    
    string recv_session = llJsonGetValue(msg, ["session_id"]);
    if (recv_session != SessionId) return;
    
    cleanupSession();
}

/* ===============================================================
   EVENTS
   =============================================================== */

default
{
    state_entry() {
        cleanupSession();
        registerSelf();
        
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
        if (!jsonHas(msg, ["type"])) return;
        
        string type = llJsonGetValue(msg, ["type"]);
        
        // Kernel lifecycle
        if (num == KERNEL_LIFECYCLE) {
            if (type == "register_now") {
                registerSelf();
            }
            else if (type == "ping") {
                sendPong();
            }
            else if (type == "soft_reset") {
                llResetScript();
            }
        }
        // Settings
        else if (num == SETTINGS_BUS) {
            if (type == "settings_sync") {
                applySettingsSync(msg);
            }
            else if (type == "settings_delta") {
                applySettingsDelta(msg);
            }
        }
        // ACL
        else if (num == AUTH_BUS) {
            if (type == "acl_result") {
                handleAclResult(msg);
            }
        }
        // UI
        else if (num == UI_BUS) {
            if (type == "start") {
                if (!jsonHas(msg, ["context"])) return;
                string context = llJsonGetValue(msg, ["context"]);
                
                if (context == PLUGIN_CONTEXT) {
                    CurrentUser = id;
                    requestAcl(CurrentUser);
                }
            }
        }
        // Dialogs
        else if (num == DIALOG_BUS) {
            if (type == "dialog_response") {
                handleDialogResponse(msg);
            }
            else if (type == "dialog_timeout") {
                handleDialogTimeout(msg);
            }
        }
    }
}
