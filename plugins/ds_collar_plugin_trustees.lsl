/* =============================================================
   PLUGIN: ds_collar_trustees.lsl (DS Collar Canonical, Strict LSL)
   PURPOSE: Trustees Plugin (Core 1.4+)
   AUTHOR:  [Your Name or Project]
   DATE:    2025-08-02
   ============================================================= */

/* ---- CANONICAL PROTOCOL CONSTANTS ---- */
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";

/* ---- PLUGIN PARAMETERS ---- */
string  PLUGIN_CONTEXT      = "core_trustees";
string  ROOT_CONTEXT        = "core_root";
string  PLUGIN_LABEL        = "Trustees";
integer PLUGIN_MIN_ACL      = 1;
integer PLUGIN_SN           = 0;
integer MAX_TRUSTEES        = 4;

/* ---- CHANNELS ---- */
integer PLUGIN_REG_QUERY_NUM = 500;
integer PLUGIN_REG_REPLY_NUM = 501;
integer SETTINGS_SYNC_NUM    = 870;
integer UI_SHOW_MENU_NUM     = 601;
integer SETTINGS_QUERY_NUM   = 800;
string  SETTINGS_SET_PREFIX  = "set_";

/* ---- UI CONSTANTS ---- */
string  BACK_BTN_LABEL       = "Back";
string  TRUSTEE_ADD_LABEL    = "Trustee +";
string  TRUSTEE_REMOVE_LABEL = "Trustee -";
string  FILLER_BTN_LABEL     = "~";
integer DIALOG_TIMEOUT       = 180;

/* ---- SESSION STATE ---- */
key     sess_user        = NULL_KEY;
integer sess_chan        = 0;
integer sess_listen      = 0;
string  sess_context     = "";
string  sess_param1      = "";
string  sess_param2      = "";
string  sess_stepdata    = "";

/* ---- TRUSTEE STATE ---- */
key   collar_owner = NULL_KEY;
list  collar_trustees = [];
list  collar_trustee_honorifics = [];

/* ---- HELPERS ---- */
list trustee_honorifics() {
    return ["Sir", "Miss", "Milord", "Milady"];
}
integer g_idx(list l, key k) { return llListFindList(l, [k]); }
integer get_acl(key av) {
    if (av == collar_owner) return 1; // Owner
    if (av == llGetOwner()) {
        if (collar_owner == NULL_KEY) return 1; // Unowned wearer
        return 3; // Owned wearer
    }
    if (g_idx(collar_trustees, av) != -1) return 2;
    return 5; // All others
}
list make_ok_only() { return ["OK"]; }
list build_numbered_buttons(list items) {
    list out = [];
    integer i;
    for (i = 0; i < llGetListLength(items); ++i) out += (string)(i+1);
    while (llGetListLength(out) % 3 != 0) out += FILLER_BTN_LABEL;
    return out;
}
string format_numbered_list(list items) {
    string out = ""; integer i;
    for (i = 0; i < llGetListLength(items); ++i)
        out += (string)(i+1) + ". " + llList2String(items, i) + "\n";
    return out;
}
string csv_from_list(list l) {
    if (llGetListLength(l) == 0) return " ";
    return llDumpList2String(l, ",");
}
integer persist_trustees() {
    string set_trustees_msg = SETTINGS_SET_PREFIX + "trustees" + "|" + csv_from_list(collar_trustees);
    string set_trusthonor_msg = SETTINGS_SET_PREFIX + "trustees_hon" + "|" + csv_from_list(collar_trustee_honorifics);
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, set_trustees_msg, NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, set_trusthonor_msg, NULL_KEY);
    return TRUE;
}
integer cleanup_session() {
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
    return TRUE;
}
integer show_plugin_menu(key avatar) {
    integer acl = get_acl(avatar);
    if (acl != 1) return FALSE;

    list btns = [];
    if (llGetListLength(collar_trustees) < MAX_TRUSTEES) btns += TRUSTEE_ADD_LABEL;
    else btns += FILLER_BTN_LABEL;
    if (llGetListLength(collar_trustees) > 0) btns += TRUSTEE_REMOVE_LABEL;
    else btns += FILLER_BTN_LABEL;
    btns += BACK_BTN_LABEL;
    while (llGetListLength(btns) % 3 != 0) btns += FILLER_BTN_LABEL;

    if (sess_listen != 0) llListenRemove(sess_listen);
    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    sess_listen = llListen(menu_chan, "", avatar, "");
    sess_user = avatar;
    sess_chan = menu_chan;
    sess_context = "main";
    sess_param1 = "";
    sess_param2 = "";
    sess_stepdata = "";
    llDialog(avatar, "Trustee Management:", btns, menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    return TRUE;
}
integer update_from_settings(list parts) {
    if (llGetListLength(parts) < 8) return FALSE;
    collar_owner = (key)llList2String(parts, 1);
    string trust_csv = llList2String(parts, 3);
    if (trust_csv == " ") collar_trustees = [];
    else collar_trustees = llParseString2List(trust_csv, [","], []);
    string hon_csv = llList2String(parts, 4);
    if (hon_csv == " ") collar_trustee_honorifics = [];
    else collar_trustee_honorifics = llParseString2List(hon_csv, [","], []);
    return TRUE;
}
integer timeout_check() {
    cleanup_session();
    return TRUE;
}

/* =============================================================
   MAIN EVENT LOOP
   ============================================================= */
default
{
    state_entry() {
        PLUGIN_SN = 100000 + (integer)(llFrand(899999));
        string reg_msg = REGISTER_MSG_START + "|" +
                        (string)PLUGIN_SN + "|" + PLUGIN_LABEL + "|" +
                        (string)PLUGIN_MIN_ACL + "|" + PLUGIN_CONTEXT + "|" +
                        llGetScriptName();
        llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg_msg, NULL_KEY);
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
                }
            }
            return;
        }
        if ((num == PLUGIN_REG_QUERY_NUM) && llSubStringIndex(str, REGISTER_NOW_MSG_START + "|") == 0) {
            string script_req = llGetSubString(str, llStringLength(REGISTER_NOW_MSG_START) + 1, -1);
            if (script_req == llGetScriptName()) {
                string msg = REGISTER_MSG_START + "|" + (string)PLUGIN_SN + "|" + PLUGIN_LABEL + "|" + (string)PLUGIN_MIN_ACL + "|" + PLUGIN_CONTEXT + "|" + llGetScriptName();
                llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, msg, NULL_KEY);
            }
            return;
        }
    }
    listen(integer chan, string nm, key av, string msg) {
        if (chan != sess_chan || av != sess_user) return;

        if (sess_context == "main") {
            if (msg == TRUSTEE_ADD_LABEL) {
                llSensor("", NULL_KEY, AGENT, 20.0, PI * 2);
                sess_context = "add_trustee";
                sess_param1 = "";
                sess_param2 = "";
                sess_stepdata = "";
                llSetTimerEvent((float)DIALOG_TIMEOUT);
                return;
            }
            if (msg == TRUSTEE_REMOVE_LABEL) {
                if (llGetListLength(collar_trustees) == 0) {
                    llDialog(av, "There are no trustees to remove.", make_ok_only(), chan);
                    cleanup_session();
                    return;
                }
                list names = [];
                integer i;
                for (i = 0; i < llGetListLength(collar_trustees); ++i)
                    names += llKey2Name(llList2Key(collar_trustees, i));
                list buttons = build_numbered_buttons(names);
                sess_context = "remove_trustee";
                sess_param1 = llDumpList2String(collar_trustees, ",");
                sess_param2 = "";
                sess_stepdata = llDumpList2String(buttons, ",");
                llDialog(av, "Select trustee to remove:\n" + format_numbered_list(names), buttons, chan);
                llSetTimerEvent((float)DIALOG_TIMEOUT);
                return;
            }
            if (msg == BACK_BTN_LABEL) {
                cleanup_session();
                string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)av + "|0";
                llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
                return;
            }
        }
        if (sess_context == "add_trustee_select") {
            list keys = llParseString2List(sess_param1, [","], []);
            integer index = (integer)msg - 1;
            if (index >= 0 && index < llGetListLength(keys)) {
                key selected = llList2Key(keys, index);
                list honors = trustee_honorifics();
                list buttons = build_numbered_buttons(honors);
                sess_context = "add_trustee_honor";
                sess_param1 = (string)selected;
                sess_param2 = "";
                sess_stepdata = llDumpList2String(buttons, ",");
                llDialog(av, "Select an honorific for " + llKey2Name(selected) + ":\n" + format_numbered_list(honors), buttons, chan);
                llSetTimerEvent((float)DIALOG_TIMEOUT);
            }
        }
        if (sess_context == "add_trustee_honor") {
            list honors = trustee_honorifics();
            integer index = (integer)msg - 1;
            if (index >= 0 && index < llGetListLength(honors)) {
                key selected = (key)sess_param1;
                string honor = llList2String(honors, index);
                collar_trustees += selected;
                collar_trustee_honorifics += honor;
                llDialog(av, llKey2Name(selected) + " has been added as trustee (" + honor + ").", make_ok_only(), chan);
                persist_trustees();
                cleanup_session();
            }
        }
        if (sess_context == "remove_trustee") {
            list keys = llParseString2List(sess_param1, [","], []);
            integer index = (integer)msg - 1;
            if (index >= 0 && index < llGetListLength(keys)) {
                collar_trustees = llDeleteSubList(collar_trustees, index, index);
                collar_trustee_honorifics = llDeleteSubList(collar_trustee_honorifics, index, index);
                llDialog(av, "Trustee removed.", make_ok_only(), chan);
                persist_trustees();
                cleanup_session();
            }
        }
    }
    sensor(integer n) {
        if (sess_context == "add_trustee" && sess_user != NULL_KEY) {
            list candidates = [];
            integer j;
            for (j = 0; j < n; ++j) {
                key k = llDetectedKey(j);
                if (k != sess_user && k != collar_owner && g_idx(collar_trustees, k) == -1) candidates += k;
            }
            if (llGetListLength(candidates) == 0) {
                llDialog(sess_user, "No valid candidates nearby.", make_ok_only(), sess_chan);
                cleanup_session();
                return;
            }
            list names = [];
            for (j = 0; j < llGetListLength(candidates); ++j) names += llKey2Name(llList2Key(candidates, j));
            list buttons = build_numbered_buttons(names);
            sess_context = "add_trustee_select";
            sess_param1 = llDumpList2String(candidates, ",");
            sess_param2 = "";
            sess_stepdata = llDumpList2String(buttons, ",");
            llDialog(sess_user, "Select avatar to add as trustee:\n" + format_numbered_list(names), buttons, sess_chan);
            llSetTimerEvent((float)DIALOG_TIMEOUT);
        }
    }
    no_sensor() {
        if (sess_context == "add_trustee" && sess_user != NULL_KEY) {
            llDialog(sess_user, "No one found nearby.", make_ok_only(), sess_chan);
            cleanup_session();
        }
    }
    timer() { timeout_check(); }
    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }
}
