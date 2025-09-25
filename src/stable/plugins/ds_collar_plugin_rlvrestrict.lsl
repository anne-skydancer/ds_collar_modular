// =============================================================
// PLUGIN: ds_collar_rlvrestrict.lsl (Migrated to Boilerplate, No ternaries)
// PURPOSE: RLV Restriction Plugin (Core 1.4+, New Arch)
// =============================================================

integer DEBUG = TRUE;

/* ---------- Link numbers ---------- */
integer K_PLUGIN_REG_QUERY   = 500;
integer K_PLUGIN_REG_REPLY   = 501;
integer K_PLUGIN_SOFT_RESET  = 504;
integer K_PLUGIN_PING        = 650;
integer K_PLUGIN_PONG        = 651;
integer AUTH_QUERY_NUM       = 700;
integer AUTH_RESULT_NUM      = 710;
integer K_SETTINGS_QUERY     = 800;
integer K_SETTINGS_SYNC      = 870;
integer K_PLUGIN_START       = 900;
integer K_PLUGIN_RETURN_NUM  = 901;

/* ---------- Magic words ---------- */
string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_REGISTER_NOW      = "register_now";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";
string CONS_MSG_ACL_QUERY          = "acl_query";
string CONS_MSG_ACL_RESULT         = "acl_result";

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT   = "core_rlvrestrict";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Restrict";
integer PLUGIN_SN        = 0;

/* ---------- ACL levels ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_WEARER        = 4;
integer ACL_PRIMARY_OWNER = 5;

list ALLOWED_ACL_LEVELS = [ACL_TRUSTEE, ACL_WEARER, ACL_OWNED, ACL_PRIMARY_OWNER];

/* ---------- UI/session ---------- */
integer DIALOG_TIMEOUT_SEC = 180;
key     User      = NULL_KEY;
integer Listen    = 0;
integer MenuChan = 0;
integer AclPending = FALSE;
integer AclLevel   = ACL_TRUSTEE;

/* ---------- RLV restriction state ---------- */
integer MAX_RESTRICTIONS = 32;
integer DIALOG_PAGE_SIZE = 9;

string BACK_BTN_LABEL   = "Back";
string FILLER_BTN_LABEL = "~";
string PREV_BTN_LABEL   = "<<";
string NEXT_BTN_LABEL   = ">>";
string SAFEWORD_LABEL   = "Safeword";
string EXCEPTIONS_LABEL = "Exceptions";

list Restrictions = [];

/* ---------- Categories ---------- */
list CAT_INV    = [ "@detachall", "@addoutfit", "@remoutfit", "@remattach", "@addattach", "@attachall", "@showinv", "@viewnote", "@viewscript" ];
list CAT_SPEECH = [ "@sendchat", "@recvim", "@sendim", "@startim", "@chatshout", "@chatwhisper" ];
list CAT_TRAVEL = [ "@tptlm", "@tploc", "@tplure" ];
list CAT_OTHER  = [ "@edit", "@rez", "@touchall", "@touchworld", "@accepttp", "@shownames", "@sit", "@unsit", "@stand" ];

list LABEL_INV    = [ "Det. All:", "+ Outfit:", "- Outfit:", "- Attach:", "+ Attach:", "Att. All:", "Inv:", "Notes:", "Scripts:" ];
list LABEL_SPEECH = [ "Chat:", "Recv IM:", "Send IM:", "Start IM:", "Shout:", "Whisper:" ];
list LABEL_TRAVEL = [ "Map TP:", "Loc. TP:", "TP:" ];
list LABEL_OTHER  = [ "Edit:", "Rez:", "Touch:", "Touch Wld:", "OK TP:", "Names:", "Sit:", "Unsit:", "Stand:" ];

/* ---------- Context ---------- */
string MenuCtxName = "";
integer MenuCtxPage = 0;

/* ---------- Helpers ---------- */
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer logd(string s) {
    if (DEBUG) llOwnerSay("[PLUGIN " + PLUGIN_CONTEXT + "] " + s);
    return 0;
}

integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  "0");
    j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    return 0;
}

integer notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    return 0;
}

integer in_allowed_levels(integer lvl) {
    return (llListFindList(ALLOWED_ACL_LEVELS, [lvl]) != -1);
}

integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    AclPending = TRUE;
    return 0;
}

integer reset_listen() {
    if (Listen) llListenRemove(Listen);
    Listen = 0;
    MenuChan = 0;
    return 0;
}

integer begin_dialog(key user, string body, list buttons) {
    reset_listen();
    User = user;
    while ((llGetListLength(buttons) % 3) != 0) buttons += " ";
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    Listen    = llListen(MenuChan, "", User, "");
    llDialog(User, body, buttons, MenuChan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}

/* ---------- Restriction helpers ---------- */
integer restriction_idx(string restr_cmd) {
    return llListFindList(Restrictions, [restr_cmd]);
}

string get_label_for_command(string cmd, list cat_cmds, list cat_labels) {
    integer idx = llListFindList(cat_cmds, [cmd]);
    if (idx != -1) return llList2String(cat_labels, idx);
    return cmd + ":";
}

string get_short_label(string cmd, integer is_active, list cat_cmds, list cat_labels) {
    string label = get_label_for_command(cmd, cat_cmds, cat_labels);
    if (is_active) label += "OFF"; else label += "ON";
    return label;
}

string label_to_command(string label, list cat_cmds, list cat_labels) {
    integer i;
    integer n = llGetListLength(cat_labels);
    for (i = 0; i < n; i++) {
        string base_label = llList2String(cat_labels, i);
        if (label == base_label + "ON" || label == base_label + "OFF") {
            return llList2String(cat_cmds, i);
        }
    }
    return "";
}

list get_category_list(string catname) {
    if (catname == "Inventory") return CAT_INV;
    if (catname == "Speech") return CAT_SPEECH;
    if (catname == "Travel") return CAT_TRAVEL;
    if (catname == "Other") return CAT_OTHER;
    return [];
}

list get_category_labels(string catname) {
    if (catname == "Inventory") return LABEL_INV;
    if (catname == "Speech") return LABEL_SPEECH;
    if (catname == "Travel") return LABEL_TRAVEL;
    if (catname == "Other") return LABEL_OTHER;
    return [];
}

list make_category_buttons(list cat_cmds, list cat_labels, integer page) {
    list btns = [];
    integer count = llGetListLength(cat_cmds);
    integer start = page * DIALOG_PAGE_SIZE;
    integer end = start + DIALOG_PAGE_SIZE - 1;
    if (end >= count) end = count - 1;
    integer i;
    for (i = start; i <= end; i++) {
        if (i < count) {
            string cmd = llList2String(cat_cmds, i);
            integer restr_on = (restriction_idx(cmd) != -1);
            btns += [ get_short_label(cmd, restr_on, cat_cmds, cat_labels) ];
        }
    }
    while (llGetListLength(btns) < DIALOG_PAGE_SIZE) btns += FILLER_BTN_LABEL;
    return btns;
}

toggle_restriction(string restr_cmd) {
    integer ridx = restriction_idx(restr_cmd);
    if (ridx != -1) {
        Restrictions = llDeleteSubList(Restrictions, ridx, ridx);
        llOwnerSay(restr_cmd + "=y");
    } else if (llGetListLength(Restrictions) < MAX_RESTRICTIONS) {
        Restrictions += restr_cmd;
        llOwnerSay(restr_cmd + "=n");
    }
}

clear_all_restrictions() {
    Restrictions = [];
    llOwnerSay("@clear");
}

/* ---------- UI ---------- */
integer show_menu(key user) {
    list btns = [FILLER_BTN_LABEL, BACK_BTN_LABEL, FILLER_BTN_LABEL,
                 "Other", SAFEWORD_LABEL, EXCEPTIONS_LABEL,
                 "Inventory", "Speech", "Travel"];
    begin_dialog(user, "RLV Restriction Menu:\nSelect a category.", btns);
    return 0;
}

integer show_category_menu(key user, string catname, integer page) {
    list catlist = get_category_list(catname);
    list catlabels = get_category_labels(catname);
    integer num_items = llGetListLength(catlist);
    integer max_page = 0;
    if (num_items > 0) max_page = (num_items - 1) / DIALOG_PAGE_SIZE;

    string prev = FILLER_BTN_LABEL;
    string next = FILLER_BTN_LABEL;
    if (page > 0) prev = PREV_BTN_LABEL;
    if (page < max_page) next = NEXT_BTN_LABEL;

    list btns = [prev, BACK_BTN_LABEL, next];
    btns += make_category_buttons(catlist, catlabels, page);

    MenuCtxName = catname;
    MenuCtxPage = page;

    begin_dialog(user, catname + " Restrictions:\nClick to toggle.", btns);
    return 0;
}

/* ---------- Events ---------- */
default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_plugin();
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == K_PLUGIN_PING && json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_PING
            && json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
            string pong = llList2Json(JSON_OBJECT, []);
            pong = llJsonSetValue(pong, ["type"], CONS_TYPE_PLUGIN_PONG);
            pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
            return;
        }
        if (num == K_PLUGIN_REG_QUERY && json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW
            && json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
            register_plugin();
            return;
        }
        if (num == K_PLUGIN_START && json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START
            && json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
            User = id;
            request_acl(User);
            return;
        }
        if (num == AUTH_RESULT_NUM && AclPending && json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_MSG_ACL_RESULT
            && json_has(msg, ["avatar"]) && (key)llJsonGetValue(msg, ["avatar"]) == User
            && json_has(msg, ["level"])) {
            AclLevel = (integer)llJsonGetValue(msg, ["level"]);
            AclPending = FALSE;
            if (in_allowed_levels(AclLevel)) {
                show_menu(User);
            } else {
                llRegionSayTo(User, 0, "Access denied.");
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"], CONS_TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, User);
                User = NULL_KEY;
                reset_listen();
                llSetTimerEvent(0.0);
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string msg) {
        if (chan != MenuChan || id != User) return;
        if (msg == BACK_BTN_LABEL) {
            if (MenuCtxName != "") {
                MenuCtxName = "";
                MenuCtxPage = 0;
                show_menu(id);
            } else {
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"], CONS_TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, User);
                reset_listen();
                User = NULL_KEY;
                llSetTimerEvent(0.0);
            }
            return;
        }
        if (MenuCtxName == "") {
            if (msg == "Inventory" || msg == "Speech" || msg == "Travel" || msg == "Other") {
                MenuCtxName = msg;
                MenuCtxPage = 0;
                show_category_menu(id, MenuCtxName, 0);
                return;
            }
            if (msg == SAFEWORD_LABEL) {
                clear_all_restrictions();
                llRegionSayTo(id, 0, "All restrictions cleared by Safeword.");
                show_menu(id);
                return;
            }
            if (msg == EXCEPTIONS_LABEL) {
                llRegionSayTo(id, 0, "Exceptions menu not yet implemented.");
                show_menu(id);
                return;
            }
        } else {
            if (msg == PREV_BTN_LABEL && MenuCtxPage > 0) {
                show_category_menu(id, MenuCtxName, MenuCtxPage - 1);
                return;
            }
            integer max_page = 0;
            integer num_items = llGetListLength(get_category_list(MenuCtxName));
            if (num_items > 0) max_page = (num_items - 1) / DIALOG_PAGE_SIZE;
            if (msg == NEXT_BTN_LABEL && MenuCtxPage < max_page) {
                show_category_menu(id, MenuCtxName, MenuCtxPage + 1);
                return;
            }
            string cmd = label_to_command(msg, get_category_list(MenuCtxName), get_category_labels(MenuCtxName));
            if (cmd != "" && in_allowed_levels(AclLevel)) {
                toggle_restriction(cmd);
                show_category_menu(id, MenuCtxName, MenuCtxPage);
            }
        }
    }

    timer() {
        reset_listen();
        User = NULL_KEY;
        llSetTimerEvent(0.0);
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }
}
