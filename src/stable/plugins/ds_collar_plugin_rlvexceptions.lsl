// =============================================================
//  PLUGIN: ds_collar_plugin_rlv_exceptions.lsl (Canonical, DS Collar 1.4+)
//  PURPOSE: RLV Owner/Trustee Exceptions, persistent, canonical protocol
//  DATE:    2025-08-01 (Flat "Back" routing as specified, full compliance)
// =============================================================

integer DEBUG = TRUE;

// === Canonical protocol roots ===
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";
string SETTINGS_SET_PREFIX     = "set_";

string PLUGIN_CONTEXT      = "core_rlv_exceptions";
string ROOT_CONTEXT        = "core_root";

// Protocol channels
integer PLUGIN_REG_QUERY_NUM = 500;
integer PLUGIN_REG_REPLY_NUM = 501;
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;
integer UI_SHOW_MENU_NUM     = 601;

integer PLUGIN_SN        = 0;
string  PLUGIN_LABEL     = "Exceptions";
integer PLUGIN_MIN_ACL   = 1;

// Submenu context labels
string CTX_MAIN         = "main";
string CTX_OWNER        = "owner";
string CTX_OWNER_IM     = "owner_im";
string CTX_OWNER_TP     = "owner_tp";
string CTX_TRUSTEE      = "trustee";
string CTX_TRUSTEE_IM   = "trustee_im";
string CTX_TRUSTEE_TP   = "trustee_tp";

// Exception state (persistent)
integer g_ex_owner_im      = TRUE;   // Owner IM allowed
integer g_ex_owner_tp      = TRUE;   // Owner force TP allowed
integer g_ex_trustee_im    = TRUE;   // Trustee IM allowed
integer g_ex_trustee_tp    = FALSE;  // Trustee TP allowed (default FALSE!)

// Settings keys
string EX_OWNER_IM_KEY      = "ex_owner_im";
string EX_OWNER_TP_KEY      = "ex_owner_tp";
string EX_TRUSTEE_IM_KEY    = "ex_trustee_im";
string EX_TRUSTEE_TP_KEY    = "ex_trustee_tp";

// Session helpers (Animate/Status)
list    g_sessions;
integer s_idx(key av) { return llListFindList(g_sessions, [av]); }
integer s_set(key av, integer page, string csv, float expiry, string ctx, string param, string step, string menucsv, integer chan)
{
    integer i = s_idx(av);
    if (~i) {
        integer old = llList2Integer(g_sessions, i+9);
        if (old != -1) llListenRemove(old);
        g_sessions = llDeleteSubList(g_sessions, i, i+9);
    }
    integer lh = llListen(chan, "", av, "");
    g_sessions += [av, page, csv, expiry, ctx, param, step, menucsv, chan, lh];
    return TRUE;
}
integer s_clear(key av)
{
    integer i = s_idx(av);
    if (~i) {
        integer old = llList2Integer(g_sessions, i+9);
        if (old != -1) llListenRemove(old);
        g_sessions = llDeleteSubList(g_sessions, i, i+9);
    }
    return TRUE;
}
list s_get(key av)
{
    integer i = s_idx(av);
    if (~i) return llList2List(g_sessions, i, i+9);
    return [];
}

// --- Persistence: canonical protocol (SETTINGS_SET_PREFIX, 800)
persist_exception(string pname, integer value)
{
    string msg = SETTINGS_SET_PREFIX + pname + "|" + (string)value;
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, msg, NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);
    if (DEBUG) llOwnerSay("[RLVEX] Persisted: " + pname + "=" + (string)value);
}

// === UI helpers for each menu level ===
show_main_menu(key user)
{
    list btns = ["~", "Back", "~", "Owner", "~", "Trustee"];
    while (llGetListLength(btns) % 3 != 0) btns += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, CTX_MAIN, "", "", "", menu_chan);

    string msg = "RLV Exceptions Menu\nChoose Owner or Trustee exceptions to manage.";
    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[RLVEX] Main menu → " + (string)user + " chan=" + (string)menu_chan);
}
show_owner_menu(key user)
{
    list btns = ["~", "Back", "~", "IM", "~", "TP"];
    while (llGetListLength(btns) % 3 != 0) btns += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, CTX_OWNER, "", "", "", menu_chan);

    string msg = "Owner Exceptions:\nChoose which exception to edit.";
    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[RLVEX] Owner menu → " + (string)user + " chan=" + (string)menu_chan);
}
show_trustee_menu(key user)
{
    list btns = ["~", "Back", "~", "IM", "~", "TP"];
    while (llGetListLength(btns) % 3 != 0) btns += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, CTX_TRUSTEE, "", "", "", menu_chan);

    string msg = "Trustee Exceptions:\nChoose which exception to edit.";
    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[RLVEX] Trustee menu → " + (string)user + " chan=" + (string)menu_chan);
}

show_exception_menu(key user, string ctx, string persist_key, string plus_label, string minus_label, integer current_val)
{
    list btns = ["~", "Back", "~", plus_label, "~", minus_label];
    while (llGetListLength(btns) % 3 != 0) btns += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, ctx, persist_key, "", "", menu_chan);

    string msg = "";
    if (persist_key == EX_OWNER_IM_KEY)
        msg = "Owner IM Exception:\n";
    else if (persist_key == EX_OWNER_TP_KEY)
        msg = "Owner TP Exception:\n";
    else if (persist_key == EX_TRUSTEE_IM_KEY)
        msg = "Trustee IM Exception:\n";
    else if (persist_key == EX_TRUSTEE_TP_KEY)
        msg = "Trustee TP Exception:\n";
    if (current_val)
        msg += "Current: ALLOWED\n";
    else
        msg += "Current: DENIED\n";
    msg += "\nChoose to allow (+) or deny (-).";
    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[RLVEX] Exception menu ("+ctx+") → " + (string)user + " chan=" + (string)menu_chan);
}

// --- MAIN EVENT LOOP ---
default
{
    state_entry()
    {
        PLUGIN_SN = (integer)(llFrand(1.0e5));
        string reg_msg = REGISTER_MSG_START + "|" +
                         (string)PLUGIN_SN + "|" +
                         PLUGIN_LABEL + "|" +
                         (string)PLUGIN_MIN_ACL + "|" +
                         PLUGIN_CONTEXT + "|" +
                         llGetScriptName();
        llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg_msg, NULL_KEY);

        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);

        if (DEBUG) llOwnerSay("[RLVEX] Ready, SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        if ((num == PLUGIN_REG_QUERY_NUM) && llSubStringIndex(str, REGISTER_NOW_MSG_START + "|") == 0)
        {
            string script_req = llGetSubString(str, llStringLength(REGISTER_NOW_MSG_START) + 1, -1);
            if (script_req == llGetScriptName())
            {
                string reg_msg = REGISTER_MSG_START + "|" +
                                 (string)PLUGIN_SN + "|" +
                                 PLUGIN_LABEL + "|" +
                                 (string)PLUGIN_MIN_ACL + "|" +
                                 PLUGIN_CONTEXT + "|" +
                                 llGetScriptName();
                llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg_msg, NULL_KEY);
                if (DEBUG) llOwnerSay("[RLVEX] Registration reply sent.");
            }
            return;
        }

        // SETTINGS SYNC (canonical)
        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG_START) {
                integer k;
                for (k = 1; k < llGetListLength(parts); ++k) {
                    string kv = llList2String(parts, k);
                    integer eq = llSubStringIndex(kv, "=");
                    if (eq != -1) {
                        string pname = llGetSubString(kv, 0, eq-1);
                        string pval  = llGetSubString(kv, eq+1, -1);
                        if (pname == EX_OWNER_IM_KEY) {
                            if (pval == "1") g_ex_owner_im = TRUE; else g_ex_owner_im = FALSE;
                        } else if (pname == EX_OWNER_TP_KEY) {
                            if (pval == "1") g_ex_owner_tp = TRUE; else g_ex_owner_tp = FALSE;
                        } else if (pname == EX_TRUSTEE_IM_KEY) {
                            if (pval == "1") g_ex_trustee_im = TRUE; else g_ex_trustee_im = FALSE;
                        } else if (pname == EX_TRUSTEE_TP_KEY) {
                            if (pval == "1") g_ex_trustee_tp = TRUE; else g_ex_trustee_tp = FALSE;
                        }
                    }
                }
                if (DEBUG) llOwnerSay("[RLVEX] Settings sync: ownerIM=" + (string)g_ex_owner_im +
                    " ownerTP=" + (string)g_ex_owner_tp +
                    " trusteeIM=" + (string)g_ex_trustee_im +
                    " trusteeTP=" + (string)g_ex_trustee_tp );
            }
            return;
        }

        // UI menu dispatch
        if ((num == UI_SHOW_MENU_NUM)) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 3) {
                string ctx = llList2String(parts, 1);
                key user = (key)llList2String(parts, 2);
                if (ctx == PLUGIN_CONTEXT) {
                    show_main_menu(user);
                    return;
                }
            }
        }
    }

    listen(integer chan, string name, key id, string msg)
    {
        list sess = s_get(id);
        if (llGetListLength(sess) == 10 && chan == llList2Integer(sess, 8)) {
            string ctx = llList2String(sess, 4);
            string persist_key = llList2String(sess, 5);

            // --- Back button logic (flat, as specified) ---
            if (msg == "Back") {
                if (ctx == CTX_MAIN) {
                    // From plugin main menu: Back → root
                    string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)id + "|0";
                    llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
                    s_clear(id);
                    return;
                } else {
                    // From any other submenu, Back → plugin main menu
                    show_main_menu(id);
                    return;
                }
            }

            // --- Main menu navigation
            if (ctx == CTX_MAIN) {
                if (msg == "Owner") {
                    show_owner_menu(id);
                    return;
                }
                if (msg == "Trustee") {
                    show_trustee_menu(id);
                    return;
                }
            }
            // Owner submenu
            else if (ctx == CTX_OWNER) {
                if (msg == "IM") {
                    show_exception_menu(id, CTX_OWNER_IM, EX_OWNER_IM_KEY, "Owner IM +", "Owner IM -", g_ex_owner_im);
                    return;
                }
                if (msg == "TP") {
                    show_exception_menu(id, CTX_OWNER_TP, EX_OWNER_TP_KEY, "Owner TP +", "Owner TP -", g_ex_owner_tp);
                    return;
                }
            }
            // Trustee submenu
            else if (ctx == CTX_TRUSTEE) {
                if (msg == "IM") {
                    show_exception_menu(id, CTX_TRUSTEE_IM, EX_TRUSTEE_IM_KEY, "Trust IM +", "Trust IM -", g_ex_trustee_im);
                    return;
                }
                if (msg == "TP") {
                    show_exception_menu(id, CTX_TRUSTEE_TP, EX_TRUSTEE_TP_KEY, "Trust TP +", "Trust TP -", g_ex_trustee_tp);
                    return;
                }
            }
            // Owner IM/TP and Trustee IM/TP submenus
            else if (ctx == CTX_OWNER_IM || ctx == CTX_OWNER_TP ||
                     ctx == CTX_TRUSTEE_IM || ctx == CTX_TRUSTEE_TP) {

                // For any exception +/- button, update value and show this menu again
                if (msg == "Owner IM +" && ctx == CTX_OWNER_IM) {
                    g_ex_owner_im = TRUE;
                    persist_exception(EX_OWNER_IM_KEY, g_ex_owner_im);
                    show_exception_menu(id, CTX_OWNER_IM, EX_OWNER_IM_KEY, "Owner IM +", "Owner IM -", g_ex_owner_im);
                    return;
                }
                if (msg == "Owner IM -" && ctx == CTX_OWNER_IM) {
                    g_ex_owner_im = FALSE;
                    persist_exception(EX_OWNER_IM_KEY, g_ex_owner_im);
                    show_exception_menu(id, CTX_OWNER_IM, EX_OWNER_IM_KEY, "Owner IM +", "Owner IM -", g_ex_owner_im);
                    return;
                }
                if (msg == "Owner TP +" && ctx == CTX_OWNER_TP) {
                    g_ex_owner_tp = TRUE;
                    persist_exception(EX_OWNER_TP_KEY, g_ex_owner_tp);
                    show_exception_menu(id, CTX_OWNER_TP, EX_OWNER_TP_KEY, "Owner TP +", "Owner TP -", g_ex_owner_tp);
                    return;
                }
                if (msg == "Owner TP -" && ctx == CTX_OWNER_TP) {
                    g_ex_owner_tp = FALSE;
                    persist_exception(EX_OWNER_TP_KEY, g_ex_owner_tp);
                    show_exception_menu(id, CTX_OWNER_TP, EX_OWNER_TP_KEY, "Owner TP +", "Owner TP -", g_ex_owner_tp);
                    return;
                }
                if (msg == "Trust IM +" && ctx == CTX_TRUSTEE_IM) {
                    g_ex_trustee_im = TRUE;
                    persist_exception(EX_TRUSTEE_IM_KEY, g_ex_trustee_im);
                    show_exception_menu(id, CTX_TRUSTEE_IM, EX_TRUSTEE_IM_KEY, "Trust IM +", "Trust IM -", g_ex_trustee_im);
                    return;
                }
                if (msg == "Trust IM -" && ctx == CTX_TRUSTEE_IM) {
                    g_ex_trustee_im = FALSE;
                    persist_exception(EX_TRUSTEE_IM_KEY, g_ex_trustee_im);
                    show_exception_menu(id, CTX_TRUSTEE_IM, EX_TRUSTEE_IM_KEY, "Trust IM +", "Trust IM -", g_ex_trustee_im);
                    return;
                }
                if (msg == "Trust TP +" && ctx == CTX_TRUSTEE_TP) {
                    g_ex_trustee_tp = TRUE;
                    persist_exception(EX_TRUSTEE_TP_KEY, g_ex_trustee_tp);
                    show_exception_menu(id, CTX_TRUSTEE_TP, EX_TRUSTEE_TP_KEY, "Trust TP +", "Trust TP -", g_ex_trustee_tp);
                    return;
                }
                if (msg == "Trust TP -" && ctx == CTX_TRUSTEE_TP) {
                    g_ex_trustee_tp = FALSE;
                    persist_exception(EX_TRUSTEE_TP_KEY, g_ex_trustee_tp);
                    show_exception_menu(id, CTX_TRUSTEE_TP, EX_TRUSTEE_TP_KEY, "Trust TP +", "Trust TP -", g_ex_trustee_tp);
                    return;
                }
            }
        }
    }

    timer()
    {
        integer now = llGetUnixTime();
        integer i = 0;
        while (i < llGetListLength(g_sessions)) {
            float exp = llList2Float(g_sessions, i+3);
            key av = llList2Key(g_sessions, i);
            if (now > exp) {
                s_clear(av);
            } else {
                i += 10;
            }
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[RLVEX] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
