/* =============================================================
   PLUGIN: ds_collar_rlvrestrict.lsl (DS Collar Canonical, Strict LSL)
   PURPOSE: RLV Restriction Plugin (Core 1.4+)
   AUTHOR:  [Your Name or Project]
   DATE:    2025-08-02
   ============================================================= */

/* ---- CANONICAL PROTOCOL CONSTANTS ---- */
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";

/* ---- PLUGIN PARAMETERS ---- */
string  PLUGIN_CONTEXT      = "core_rlvrestrict";
string  ROOT_CONTEXT        = "core_root";
string  PLUGIN_LABEL        = "Restrict";
integer PLUGIN_MIN_ACL      = 3;
integer PLUGIN_SN           = 0;

/* ---- CHANNELS ---- */
integer PLUGIN_REG_QUERY_NUM = 500;
integer PLUGIN_REG_REPLY_NUM = 501;
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;
integer UI_SHOW_MENU_NUM     = 601;

/* ---- UI CONSTANTS ---- */
string  BACK_BTN_LABEL   = "Back";
string  FILLER_BTN_LABEL = "~";
string  PREV_BTN_LABEL   = "<<";
string  NEXT_BTN_LABEL   = ">>";
string  SAFEWORD_LABEL   = "Safeword";
string  EXCEPTIONS_LABEL = "Exceptions";
integer DIALOG_TIMEOUT   = 180;

/* ---- RLV ACL ---- */
integer ACL_OWNER    = 1;
integer ACL_TRUSTEE  = 2;
integer ACL_WEARER   = 3;
integer ACL_PUBLIC   = 4;
integer ACL_NONE     = 5;

/* ---- SESSION STATE ---- */
key     sess_user        = NULL_KEY;
integer sess_chan        = 0;
integer sess_listen      = 0;
string  sess_context     = "";
string  sess_param1      = "";
string  sess_param2      = "";
string  sess_stepdata    = "";

/* ---- RLV RESTRICTION STATE ---- */
integer MAX_RESTRICTIONS = 32;
list g_restrictions = [];
key     collar_owner = NULL_KEY;
list    collar_trustees = [];
list    collar_blacklist = [];
integer collar_public_access = FALSE;

/* ---- CATEGORY DEFINITIONS ---- */
list CAT_INV    = [ "@detachall", "@addoutfit", "@remoutfit", "@remattach", "@addattach", "@attachall", "@showinv", "@viewnote", "@viewscript" ];
list CAT_SPEECH = [ "@sendchat", "@recvim", "@sendim", "@startim", "@chatshout", "@chatwhisper" ];
list CAT_TRAVEL = [ "@tptlm", "@tploc", "@tplure" ];
list CAT_OTHER  = [ "@edit", "@rez", "@touchall", "@touchworld", "@accepttp", "@shownames", "@sit", "@unsit", "@stand" ];

list LABEL_INV    = [ "Det. All:", "+ Outfit:", "- Outfit:", "- Attach:", "+ Attach:", "Att. All:", "Inv:", "Notes:", "Scripts:" ];
list LABEL_SPEECH = [ "Chat:", "Recv IM:", "Send IM:", "Start IM:", "Shout:", "Whisper:" ];
list LABEL_TRAVEL = [ "Map TP:", "Loc. TP:", "TP:" ];
list LABEL_OTHER  = [ "Edit:", "Rez:", "Touch:", "Touch Wld:", "OK TP:", "Names:", "Sit:", "Unsit:", "Stand:" ];

/* ---- PAGINATION ---- */
integer DIALOG_PAGE_SIZE = 9;

/* ---- HELPERS ---- */
integer restriction_idx(string restr_cmd) {
    return llListFindList(g_restrictions, [restr_cmd]);
}
integer g_idx(list userlist, key testid) {
    return llListFindList(userlist, [testid]);
}
integer get_acl(key user_id) {
    if (g_idx(collar_blacklist, user_id) != -1) return ACL_NONE;
    if (user_id == collar_owner) return ACL_OWNER;
    if (user_id == llGetOwner()) {
        if (collar_owner == NULL_KEY) return ACL_OWNER;
        return ACL_WEARER;
    }
    if (g_idx(collar_trustees, user_id) != -1) return ACL_TRUSTEE;
    if (collar_public_access == TRUE) return ACL_PUBLIC;
    return ACL_NONE;
}
string get_label_for_command(string cmd, list cat_cmds, list cat_labels)
{
    integer idx = llListFindList(cat_cmds, [cmd]);
    if (idx != -1) {
        return llList2String(cat_labels, idx);
    }
    return cmd + ":";
}
string get_short_label(string cmd, integer is_active, list cat_cmds, list cat_labels)
{
    string label = get_label_for_command(cmd, cat_cmds, cat_labels);
    if (is_active == TRUE) {
        label = label + "OFF";
    } else {
        label = label + "ON";
    }
    return label;
}
string label_to_command(string label, list cat_cmds, list cat_labels)
{
    integer i = 0;
    integer n = llGetListLength(cat_labels);
    while (i < n) {
        string base_label = llList2String(cat_labels, i);
        if (label == base_label + "ON" || label == base_label + "OFF") {
            return llList2String(cat_cmds, i);
        }
        i = i + 1;
    }
    return "";
}
list get_category_list(string catname)
{
    if (catname == "Inventory") return CAT_INV;
    if (catname == "Speech") return CAT_SPEECH;
    if (catname == "Travel") return CAT_TRAVEL;
    if (catname == "Other") return CAT_OTHER;
    return [];
}
list get_category_labels(string catname)
{
    if (catname == "Inventory") return LABEL_INV;
    if (catname == "Speech") return LABEL_SPEECH;
    if (catname == "Travel") return LABEL_TRAVEL;
    if (catname == "Other") return LABEL_OTHER;
    return [];
}
list make_category_buttons(list cat_cmds, list cat_labels, integer page)
{
    list btns = [];
    integer count = llGetListLength(cat_cmds);
    integer start = page * DIALOG_PAGE_SIZE;
    integer end = start + DIALOG_PAGE_SIZE - 1;
    if (end >= count) end = count - 1;
    integer i = start;
    while (i <= end) {
        if (i < count) {
            string cmd = llList2String(cat_cmds, i);
            integer restr_on = FALSE;
            if (restriction_idx(cmd) != -1) restr_on = TRUE;
            btns += [ get_short_label(cmd, restr_on, cat_cmds, cat_labels) ];
        }
        i = i + 1;
    }
    while (llGetListLength(btns) < DIALOG_PAGE_SIZE) {
        btns += [ FILLER_BTN_LABEL ];
    }
    if (llGetListLength(btns) > DIALOG_PAGE_SIZE) {
        btns = llList2List(btns, 0, DIALOG_PAGE_SIZE - 1);
    }
    return btns;
}
toggle_restriction(string restr_cmd, integer acl) {
    integer ridx = restriction_idx(restr_cmd);
    if (ridx != -1) {
        g_restrictions = llDeleteSubList(g_restrictions, ridx, ridx);
        llOwnerSay(restr_cmd + "=y");
    } else {
        if (llGetListLength(g_restrictions) < MAX_RESTRICTIONS) {
            g_restrictions += [ restr_cmd ];
            llOwnerSay(restr_cmd + "=n");
        }
    }
}
clear_all_restrictions() {
    g_restrictions = [];
    llOwnerSay("@clear");
}

/* ---- SETTINGS SYNC (For expansion) ---- */
update_from_settings(list parts) {
    if (llGetListLength(parts) < 8) return;
    collar_owner = (key)llList2String(parts, 1);
    string trustees_csv = llList2String(parts, 3);
    if (trustees_csv == " ") {
        collar_trustees = [];
    } else {
        collar_trustees = llParseString2List(trustees_csv, [","], []);
    }
    string pub_str = llList2String(parts, 6);
    if (pub_str == "1") {
        collar_public_access = TRUE;
    } else {
        collar_public_access = FALSE;
    }
    if (llGetListLength(parts) >= 9) {
        string bl_csv = llList2String(parts, 8);
        if (bl_csv == " " || bl_csv == "") {
            collar_blacklist = [];
        } else {
            collar_blacklist = llParseString2List(bl_csv, [","], []);
        }
    }
}

/* ---- SESSION CLEANUP ---- */
cleanup_session() {
    if (sess_listen != 0) {
        llListenRemove(sess_listen);
    }
    sess_listen = 0;
    sess_user = NULL_KEY;
    sess_chan = 0;
    sess_context = "";
    sess_param1 = "";
    sess_param2 = "";
    sess_stepdata = "";
    llSetTimerEvent(0.0);
}

/* ---- MAIN MENU ---- */
show_plugin_menu(key avatar) {
    integer acl = get_acl(avatar);
    if (acl > ACL_WEARER) return;
    list btns = [ FILLER_BTN_LABEL, BACK_BTN_LABEL, FILLER_BTN_LABEL,
                  "Other", SAFEWORD_LABEL, EXCEPTIONS_LABEL,
                  "Inventory", "Speech", "Travel" ];
    if (sess_listen != 0) {
        llListenRemove(sess_listen);
    }
    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    sess_listen = llListen(menu_chan, "", avatar, "");
    sess_user = avatar;
    sess_chan = menu_chan;
    sess_context = "main";
    sess_param1 = "";
    sess_param2 = "";
    sess_stepdata = "";
    llDialog(avatar, "RLV Restriction Menu:\nSelect a category.", btns, menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
}

/* ---- CATEGORY MENU ---- */
show_category_menu(key avatar, string catname, integer page, integer chan) {
    integer acl = get_acl(avatar);
    if (acl > ACL_WEARER) return;
    list catlist = get_category_list(catname);
    list catlabels = get_category_labels(catname);

    integer num_items = llGetListLength(catlist);
    integer max_page = 0;
    if (num_items > 0) {
        max_page = (num_items - 1) / DIALOG_PAGE_SIZE;
    }

    string prev = FILLER_BTN_LABEL;
    string next = FILLER_BTN_LABEL;
    if (page > 0) prev = PREV_BTN_LABEL;
    if (page < max_page) next = NEXT_BTN_LABEL;

    list btns = [ prev, BACK_BTN_LABEL, next ];
    btns += make_category_buttons(catlist, catlabels, page);

    sess_context = "cat";
    sess_param1 = catname;
    sess_param2 = (string)page;
    sess_stepdata = llDumpList2String(catlist, ",");
    sess_user = avatar;
    sess_chan = chan;

    llDialog(avatar, catname + " Restrictions:\nClick to toggle.", btns, chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
}

/* ---- TIMEOUT CHECK ---- */
timeout_check() {
    cleanup_session();
}

/* ---- MAIN EVENT LOOP ---- */
default
{
    state_entry() {
        PLUGIN_SN = 100000 + (integer)(llFrand(899999));
        llSetTimerEvent(1.0);
    }
    link_message(integer sender, integer num, string str, key id)
    {
        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG_START) {
                update_from_settings(parts);
            }
            return;
        }
        if (num == UI_SHOW_MENU_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 3) {
                string ctx = llList2String(parts, 1);
                key avatar = (key)llList2String(parts, 2);
                if (ctx == PLUGIN_CONTEXT) {
                    show_plugin_menu(avatar);
                    return;
                }
            }
        }
        if ((num == PLUGIN_REG_QUERY_NUM) && llSubStringIndex(str, REGISTER_NOW_MSG_START + "|") == 0) {
            string script_req = llGetSubString(str, llStringLength(REGISTER_NOW_MSG_START) + 1, -1);
            if (script_req == llGetScriptName()) {
                string msg = REGISTER_MSG_START + "|" + (string)PLUGIN_SN + "|" + PLUGIN_LABEL + "|" + (string)PLUGIN_MIN_ACL + "|" + PLUGIN_CONTEXT + "|" + llGetScriptName();
                llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, msg, NULL_KEY);
            }
        }
    }
    listen(integer channel, string name, key id, string msg)
    {
        if (channel != sess_chan || id != sess_user) return;
        integer acl = get_acl(id);

        if (sess_context == "main") {
            if (msg == "Inventory")      { show_category_menu(id, "Inventory", 0, channel); return; }
            if (msg == "Speech")         { show_category_menu(id, "Speech", 0, channel); return; }
            if (msg == "Travel")         { show_category_menu(id, "Travel", 0, channel); return; }
            if (msg == "Other")          { show_category_menu(id, "Other", 0, channel); return; }
            if (msg == EXCEPTIONS_LABEL) { return; }
            if (msg == SAFEWORD_LABEL && acl <= ACL_WEARER) {
                clear_all_restrictions();
                llDialog(id, "All restrictions cleared by Safeword.", [ BACK_BTN_LABEL ], channel);
                return;
            }
            if (msg == BACK_BTN_LABEL) {
                string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)id + "|0";
                llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
                cleanup_session();
                return;
            }
        }
        if (sess_context == "cat") {
            string catname = sess_param1;
            integer page = (integer)sess_param2;
            list cat_cmds = get_category_list(catname);
            list cat_labels = get_category_labels(catname);
            integer num_items = llGetListLength(cat_cmds);
            integer max_page = 0;
            if (num_items > 0) {
                max_page = (num_items - 1) / DIALOG_PAGE_SIZE;
            }
            if (msg == BACK_BTN_LABEL) {
                show_plugin_menu(id);
                return;
            }
            if (msg == PREV_BTN_LABEL && page > 0) {
                show_category_menu(id, catname, page - 1, channel);
                return;
            }
            if (msg == NEXT_BTN_LABEL && page < max_page) {
                show_category_menu(id, catname, page + 1, channel);
                return;
            }
            string cmd = label_to_command(msg, cat_cmds, cat_labels);
            if (cmd != "" && acl <= ACL_TRUSTEE) {
                toggle_restriction(cmd, acl);
                show_category_menu(id, catname, page, channel);
                return;
            }
        }
    }
    timer() { timeout_check(); }
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
