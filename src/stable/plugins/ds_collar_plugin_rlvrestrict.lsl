// =============================================================
// PLUGIN: ds_collar_rlvrestrict.lsl (Optimized & Consistent)
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
integer MenuChan  = 0;
integer AclPending = FALSE;
integer AclLevel   = ACL_TRUSTEE;

/* ---------- RLV restriction state ---------- */
integer MAX_RESTRICTIONS = 32;
integer DIALOG_PAGE_SIZE = 9;

/* ---------- Button Labels ---------- */
string BACK_BTN_LABEL   = "Back";
string FILLER_BTN_LABEL = "~";
string PREV_BTN_LABEL   = "<<";
string NEXT_BTN_LABEL   = ">>";
string SAFEWORD_LABEL   = "Safeword";
string EXCEPTIONS_LABEL = "Exceptions";

/* ---------- Category Names ---------- */
string CAT_NAME_INVENTORY = "Inventory";
string CAT_NAME_SPEECH    = "Speech";
string CAT_NAME_TRAVEL    = "Travel";
string CAT_NAME_OTHER     = "Other";

/* ---------- Restriction Lists ---------- */
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
integer json_has(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

integer logd(string log_msg) {
    if (DEBUG) llOwnerSay("[PLUGIN " + PLUGIN_CONTEXT + "] " + log_msg);
    return 0;
}

integer register_plugin() {
    string json_obj = llList2Json(JSON_OBJECT, []);
    json_obj = llJsonSetValue(json_obj, ["type"],     CONS_TYPE_REGISTER);
    json_obj = llJsonSetValue(json_obj, ["sn"],       (string)PLUGIN_SN);
    json_obj = llJsonSetValue(json_obj, ["label"],    PLUGIN_LABEL);
    json_obj = llJsonSetValue(json_obj, ["min_acl"],  "0");
    json_obj = llJsonSetValue(json_obj, ["context"],  PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, json_obj, NULL_KEY);
    return 0;
}

integer notify_soft_reset() {
    string json_obj = llList2Json(JSON_OBJECT, []);
    json_obj = llJsonSetValue(json_obj, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    json_obj = llJsonSetValue(json_obj, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, json_obj, NULL_KEY);
    return 0;
}

integer in_allowed_levels(integer acl_level) {
    return (llListFindList(ALLOWED_ACL_LEVELS, [acl_level]) != -1);
}

integer request_acl(key avatar_id) {
    string json_obj = llList2Json(JSON_OBJECT, []);
    json_obj = llJsonSetValue(json_obj, ["type"],   CONS_MSG_ACL_QUERY);
    json_obj = llJsonSetValue(json_obj, ["avatar"], (string)avatar_id);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, json_obj, NULL_KEY);
    AclPending = TRUE;
    return 0;
}

integer reset_listen() {
    if (Listen) llListenRemove(Listen);
    Listen = 0;
    MenuChan = 0;
    return 0;
}

integer begin_dialog(key user_id, string dialog_body, list dialog_buttons) {
    reset_listen();
    User = user_id;
    while ((llGetListLength(dialog_buttons) % 3) != 0) dialog_buttons += " ";
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    Listen   = llListen(MenuChan, "", User, "");
    llDialog(User, dialog_body, dialog_buttons, MenuChan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}

/* ---------- Restriction helpers ---------- */
integer restriction_idx(string restr_cmd) {
    return llListFindList(Restrictions, [restr_cmd]);
}

string get_label_for_command(string restr_cmd, list cat_cmds, list cat_labels) {
    integer cmd_idx = llListFindList(cat_cmds, [restr_cmd]);
    if (cmd_idx != -1) {
        return llList2String(cat_labels, cmd_idx);
    }
    return restr_cmd + ":";
}

string get_short_label(string restr_cmd, integer is_active, list cat_cmds, list cat_labels) {
    string base_label = get_label_for_command(restr_cmd, cat_cmds, cat_labels);
    if (is_active) {
        base_label += "OFF";
    } else {
        base_label += "ON";
    }
    return base_label;
}

string label_to_command(string button_label, list cat_cmds, list cat_labels) {
    integer label_idx;
    integer num_labels = llGetListLength(cat_labels);
    for (label_idx = 0; label_idx < num_labels; label_idx++) {
        string base_label = llList2String(cat_labels, label_idx);
        if (button_label == base_label + "ON" || button_label == base_label + "OFF") {
            return llList2String(cat_cmds, label_idx);
        }
    }
    return "";
}

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

list make_category_buttons(list cat_cmds, list cat_labels, integer current_page) {
    list button_list = [];
    integer cmd_count = llGetListLength(cat_cmds);
    integer start_idx = current_page * DIALOG_PAGE_SIZE;
    integer end_idx = start_idx + DIALOG_PAGE_SIZE - 1;
    if (end_idx >= cmd_count) end_idx = cmd_count - 1;
    
    integer cmd_idx;
    for (cmd_idx = start_idx; cmd_idx <= end_idx; cmd_idx++) {
        if (cmd_idx < cmd_count) {
            string restr_cmd = llList2String(cat_cmds, cmd_idx);
            integer restr_on = (restriction_idx(restr_cmd) != -1);
            button_list += [ get_short_label(restr_cmd, restr_on, cat_cmds, cat_labels) ];
        }
    }
    while (llGetListLength(button_list) < DIALOG_PAGE_SIZE) {
        button_list += FILLER_BTN_LABEL;
    }
    return button_list;
}

integer toggle_restriction(string restr_cmd) {
    integer restr_idx = restriction_idx(restr_cmd);
    if (restr_idx != -1) {
        Restrictions = llDeleteSubList(Restrictions, restr_idx, restr_idx);
        llOwnerSay(restr_cmd + "=y");
    } else if (llGetListLength(Restrictions) < MAX_RESTRICTIONS) {
        Restrictions += restr_cmd;
        llOwnerSay(restr_cmd + "=n");
    }
    return 0;
}

integer clear_all_restrictions() {
    Restrictions = [];
    llOwnerSay("@clear");
    return 0;
}

/* ---------- UI ---------- */
integer show_menu(key user_id) {
    list main_buttons = [FILLER_BTN_LABEL, BACK_BTN_LABEL, FILLER_BTN_LABEL,
                         CAT_NAME_OTHER, SAFEWORD_LABEL, EXCEPTIONS_LABEL,
                         CAT_NAME_INVENTORY, CAT_NAME_SPEECH, CAT_NAME_TRAVEL];
    begin_dialog(user_id, "RLV Restriction Menu:\nSelect a category.", main_buttons);
    return 0;
}

integer show_category_menu(key user_id, string cat_name, integer current_page) {
    list cat_list = get_category_list(cat_name);
    list cat_labels = get_category_labels(cat_name);
    integer num_items = llGetListLength(cat_list);
    integer max_page = 0;
    if (num_items > 0) {
        max_page = (num_items - 1) / DIALOG_PAGE_SIZE;
    }

    string prev_btn = FILLER_BTN_LABEL;
    string next_btn = FILLER_BTN_LABEL;
    if (current_page > 0) {
        prev_btn = PREV_BTN_LABEL;
    }
    if (current_page < max_page) {
        next_btn = NEXT_BTN_LABEL;
    }

    list category_buttons = [prev_btn, BACK_BTN_LABEL, next_btn];
    category_buttons += make_category_buttons(cat_list, cat_labels, current_page);

    MenuCtxName = cat_name;
    MenuCtxPage = current_page;

    begin_dialog(user_id, cat_name + " Restrictions:\nClick to toggle.", category_buttons);
    return 0;
}

/* ---------- Events ---------- */
default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_plugin();
    }

    link_message(integer sender_num, integer msg_num, string msg_str, key msg_id) {
        if (msg_num == K_PLUGIN_PING && json_has(msg_str, ["type"]) && llJsonGetValue(msg_str, ["type"]) == CONS_TYPE_PLUGIN_PING
            && json_has(msg_str, ["context"]) && llJsonGetValue(msg_str, ["context"]) == PLUGIN_CONTEXT) {
            string pong_json = llList2Json(JSON_OBJECT, []);
            pong_json = llJsonSetValue(pong_json, ["type"], CONS_TYPE_PLUGIN_PONG);
            pong_json = llJsonSetValue(pong_json, ["context"], PLUGIN_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong_json, NULL_KEY);
            return;
        }
        if (msg_num == K_PLUGIN_REG_QUERY && json_has(msg_str, ["type"]) && llJsonGetValue(msg_str, ["type"]) == CONS_TYPE_REGISTER_NOW
            && json_has(msg_str, ["script"]) && llJsonGetValue(msg_str, ["script"]) == llGetScriptName()) {
            register_plugin();
            return;
        }
        if (msg_num == K_PLUGIN_START && json_has(msg_str, ["type"]) && llJsonGetValue(msg_str, ["type"]) == CONS_TYPE_PLUGIN_START
            && json_has(msg_str, ["context"]) && llJsonGetValue(msg_str, ["context"]) == PLUGIN_CONTEXT) {
            User = msg_id;
            request_acl(User);
            return;
        }
        if (msg_num == AUTH_RESULT_NUM && AclPending && json_has(msg_str, ["type"]) && llJsonGetValue(msg_str, ["type"]) == CONS_MSG_ACL_RESULT
            && json_has(msg_str, ["avatar"]) && (key)llJsonGetValue(msg_str, ["avatar"]) == User
            && json_has(msg_str, ["level"])) {
            AclLevel = (integer)llJsonGetValue(msg_str, ["level"]);
            AclPending = FALSE;
            if (in_allowed_levels(AclLevel)) {
                show_menu(User);
            } else {
                llRegionSayTo(User, 0, "Access denied.");
                string return_json = llList2Json(JSON_OBJECT, []);
                return_json = llJsonSetValue(return_json, ["type"], CONS_TYPE_PLUGIN_RETURN);
                return_json = llJsonSetValue(return_json, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, return_json, User);
                User = NULL_KEY;
                reset_listen();
                llSetTimerEvent(0.0);
            }
            return;
        }
    }

    listen(integer listen_chan, string speaker_name, key speaker_id, string button_msg) {
        if (listen_chan != MenuChan || speaker_id != User) return;
        
        if (button_msg == BACK_BTN_LABEL) {
            if (MenuCtxName != "") {
                MenuCtxName = "";
                MenuCtxPage = 0;
                show_menu(speaker_id);
            } else {
                string return_json = llList2Json(JSON_OBJECT, []);
                return_json = llJsonSetValue(return_json, ["type"], CONS_TYPE_PLUGIN_RETURN);
                return_json = llJsonSetValue(return_json, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, return_json, User);
                reset_listen();
                User = NULL_KEY;
                llSetTimerEvent(0.0);
            }
            return;
        }
        
        if (MenuCtxName == "") {
            if (button_msg == CAT_NAME_INVENTORY || button_msg == CAT_NAME_SPEECH || 
                button_msg == CAT_NAME_TRAVEL || button_msg == CAT_NAME_OTHER) {
                MenuCtxName = button_msg;
                MenuCtxPage = 0;
                show_category_menu(speaker_id, MenuCtxName, 0);
                return;
            }
            if (button_msg == SAFEWORD_LABEL) {
                clear_all_restrictions();
                llRegionSayTo(speaker_id, 0, "All restrictions cleared by Safeword.");
                show_menu(speaker_id);
                return;
            }
            if (button_msg == EXCEPTIONS_LABEL) {
                llRegionSayTo(speaker_id, 0, "Exceptions menu not yet implemented.");
                show_menu(speaker_id);
                return;
            }
        } else {
            if (button_msg == PREV_BTN_LABEL && MenuCtxPage > 0) {
                show_category_menu(speaker_id, MenuCtxName, MenuCtxPage - 1);
                return;
            }
            integer max_page = 0;
            integer num_items = llGetListLength(get_category_list(MenuCtxName));
            if (num_items > 0) {
                max_page = (num_items - 1) / DIALOG_PAGE_SIZE;
            }
            if (button_msg == NEXT_BTN_LABEL && MenuCtxPage < max_page) {
                show_category_menu(speaker_id, MenuCtxName, MenuCtxPage + 1);
                return;
            }
            string restr_cmd = label_to_command(button_msg, get_category_list(MenuCtxName), get_category_labels(MenuCtxName));
            if (restr_cmd != "" && in_allowed_levels(AclLevel)) {
                toggle_restriction(restr_cmd);
                show_category_menu(speaker_id, MenuCtxName, MenuCtxPage);
            }
        }
    }

    timer() {
        reset_listen();
        User = NULL_KEY;
        llSetTimerEvent(0.0);
    }

    changed(integer change_flags) {
        if (change_flags & CHANGED_OWNER) llResetScript();
    }
}
