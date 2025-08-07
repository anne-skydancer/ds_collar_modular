// =============================================================
//  PLUGIN: ds_collar_plugin_public.lsl (Canonical protocol, Animate/Status-style UI)
//  PURPOSE: Public Access management, DS Collar Modular Core 1.4+
//  DATE:    2025-08-01 (Authoritative, canonical protocol roots)
// =============================================================

integer DEBUG = TRUE;

// ==== Canonical protocol constants (GLOBAL for all DS Collar scripts) ====
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";
string SETTINGS_SET_PREFIX     = "set_";

// ==== Plugin info (parametric) ====
integer PLUGIN_SN         = 0;
string  PLUGIN_LABEL      = "Public";
integer PLUGIN_MIN_ACL    = 1;
string  PLUGIN_CONTEXT    = "core_public";
string  ROOT_CONTEXT      = "core_root";
string  CTX_MAIN          = "main";

// ==== Settings sync protocol/channel ====
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;

// ==== Registration/UI menu channels ====
integer PLUGIN_REG_REPLY_NUM = 501;
integer UI_SHOW_MENU_NUM     = 601;

float   DIALOG_TIMEOUT = 180.0;

// ==== Session state ([av, page, csv, expiry, ctx, param, step, menucsv, chan, listen]) ====
list    g_sessions;

// ==== State ====
integer g_public_access = FALSE;
key g_owner = NULL_KEY;

// ==== Settings key ====
string KEY_PUBLIC_MODE = "public_mode";

// === Session Helpers ===
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

// === Persistence ===
persist_public(integer value)
{
    // Canonical dynamic settings protocol message
    string msg = SETTINGS_SET_PREFIX + KEY_PUBLIC_MODE + "|" + (string)value;
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, msg, NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);
    if (DEBUG) llOwnerSay("[PUBLIC] Persisted: " + KEY_PUBLIC_MODE + "=" + (string)value);
}

// === Menu Logic ===
show_public_menu(key user)
{
    // Animate/Status-style: always ["~", "Back", "~", ...]
    list btns = ["~", "Back", "~"];
    if (g_public_access)
        btns += [ "Disable" ];
    else
        btns += [ "Enable" ];
    while (llGetListLength(btns) % 3 != 0) btns += " ";

    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + DIALOG_TIMEOUT, CTX_MAIN, "", "", "", menu_chan);

    string msg = "Public access is currently ";
    if (g_public_access) msg += "ENABLED.\nDisable public access?";
    else                 msg += "DISABLED.\nEnable public access?";
    llDialog(user, msg, btns, menu_chan);

    if (DEBUG) llOwnerSay("[PUBLIC] Menu → " + (string)user + " chan=" + (string)menu_chan);
}

// === Settings/State Sync ===
update_state_from_settings(list p)
{
    integer k;
    for (k = 1; k < llGetListLength(p); ++k) {
        string kv = llList2String(p, k);
        integer eq = llSubStringIndex(kv, "=");
        if (eq != -1) {
            string pname = llGetSubString(kv, 0, eq-1);
            string pval  = llGetSubString(kv, eq+1, -1);
            if (pname == KEY_PUBLIC_MODE) {
                if (pval == "1") g_public_access = TRUE;
                else             g_public_access = FALSE;
                if (DEBUG) llOwnerSay("[PUBLIC] Sync: public=" + (string)g_public_access);
            }
        }
    }
}

// === MAIN EVENT LOOP ===
default
{
    state_entry()
    {
        PLUGIN_SN = (integer)(llFrand(1.0e5));
        string reg_msg = REGISTER_MSG_START + "|" + (string)PLUGIN_SN + "|" + PLUGIN_LABEL + "|"
                        + (string)PLUGIN_MIN_ACL + "|" + PLUGIN_CONTEXT + "|" + llGetScriptName();
        llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg_msg, NULL_KEY);

        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);

        if (DEBUG) llOwnerSay("[PUBLIC] Ready, SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        // Canonical registration protocol
        if ((num == 500) && llSubStringIndex(str, REGISTER_NOW_MSG_START + "|") == 0)
        {
            string script_req = llGetSubString(str, llStringLength(REGISTER_NOW_MSG_START) + 1, -1);
            if (script_req == llGetScriptName())
            {
                string reg_msg = REGISTER_MSG_START + "|" + (string)PLUGIN_SN + "|" + PLUGIN_LABEL + "|"
                                + (string)PLUGIN_MIN_ACL + "|" + PLUGIN_CONTEXT + "|" + llGetScriptName();
                llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg_msg, NULL_KEY);
                if (DEBUG) llOwnerSay("[PUBLIC] Registration reply sent.");
            }
            return;
        }

        // SETTINGS SYNC (authoritative)
        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG_START) {
                update_state_from_settings(parts);
            }
            return;
        }

        // Legacy core sync
        if (num == 520 && llSubStringIndex(str, "state_sync|") == 0) {
            list p = llParseString2List(str, ["|"], []);
            if (llGetListLength(p) >= 7) {
                string pub_str = llList2String(p, 6);
                if (pub_str == "1") g_public_access = TRUE;
                else                g_public_access = FALSE;
                if (DEBUG) llOwnerSay("[PUBLIC] Legacy sync: public=" + (string)g_public_access);
            }
            return;
        }

        // UI show menu
        if ((num == UI_SHOW_MENU_NUM)) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 3) {
                string ctx = llList2String(parts, 1);
                key user = (key)llList2String(parts, 2);
                if (ctx == PLUGIN_CONTEXT) {
                    show_public_menu(user);
                    return;
                }
            }
        }
    }

    listen(integer chan, string name, key id, string msg)
    {
        list sess = s_get(id);
        if (llGetListLength(sess) == 10 && chan == llList2Integer(sess, 8))
        {
            string ctx = llList2String(sess, 4);

            // Canonical: Back always routes to ROOT_CONTEXT and clears session
            if (msg == "Back") {
                string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)id + "|0";
                llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
                s_clear(id);
                return;
            }

            if (ctx == CTX_MAIN)
            {
                if (msg == "Enable") {
                    g_public_access = TRUE;
                    persist_public(g_public_access);
                    show_public_menu(id);
                    return;
                }
                if (msg == "Disable") {
                    g_public_access = FALSE;
                    persist_public(g_public_access);
                    show_public_menu(id);
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
            llOwnerSay("[PUBLIC] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
