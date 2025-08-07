// =============================================================
//  PLUGIN: ds_collar_plugin_lock.lsl (Canonical, LSL-cookbook-compliant)
//  PURPOSE: Lock management, visibility, RLV enforcement, DS Collar Modular Core
// =============================================================

integer DEBUG = TRUE;

// ==== Canonical protocol constants (as in your system) ====
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";
string SETTINGS_SET_PREFIX     = "set_";

// ==== Plugin info ====
integer PLUGIN_SN         = 0;
string  PLUGIN_LABEL      = "Lock";
integer PLUGIN_MIN_ACL    = 1;
string  PLUGIN_CONTEXT    = "core_lock";
string  ROOT_CONTEXT      = "core_root";
string  CTX_MAIN          = "main";

// ==== Settings sync protocol/channel ====
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;

// ==== Registration/UI menu channels ====
integer PLUGIN_REG_REPLY_NUM = 501;
integer UI_SHOW_MENU_NUM     = 601;

float   DIALOG_TIMEOUT = 180.0;

// ==== Session state ====
list    g_sessions;

// ==== State ====
integer g_locked = FALSE;

// ==== Settings key ====
string KEY_LOCKED = "locked";

// ==== Prim names ====
string PRIM_LOCKED   = "locked";
string PRIM_UNLOCKED = "unlocked";

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

// === Prim visibility logic ===
set_lock_visibility(integer lock_state)
{
    integer total = llGetNumberOfPrims();
    integer i;
    for (i = 1; i <= total; ++i)
    {
        string pname = llGetLinkName(i);
        if (pname == PRIM_LOCKED)
        {
            if (lock_state) {
                llSetLinkAlpha(i, 1.0, ALL_SIDES);
            } else {
                llSetLinkAlpha(i, 0.0, ALL_SIDES);
            }
        }
        else if (pname == PRIM_UNLOCKED)
        {
            if (lock_state) {
                llSetLinkAlpha(i, 0.0, ALL_SIDES);
            } else {
                llSetLinkAlpha(i, 1.0, ALL_SIDES);
            }
        }
    }
    if (DEBUG) llOwnerSay("[LOCK] set_lock_visibility: locked=" + (string)lock_state);
}

// === RLV enforcement logic ===
enforce_rlv_detach(integer lock_state)
{
    if (lock_state) {
        llOwnerSay("@detach=n");
        if (DEBUG) llOwnerSay("[LOCK] RLV sent: @detach=n");
    } else {
        llOwnerSay("@detach=y");
        if (DEBUG) llOwnerSay("[LOCK] RLV sent: @detach=y");
    }
}

// === Persistence ===
persist_locked(integer value)
{
    string msg = SETTINGS_SET_PREFIX + KEY_LOCKED + "|" + (string)value;
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, msg, NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);
    if (DEBUG) llOwnerSay("[LOCK] Persisted: " + KEY_LOCKED + "=" + (string)value);
}

// === Menu Logic ===
show_lock_menu(key user)
{
    list btns = ["~", "Back", "~"];
    if (g_locked) {
        btns += [ "Unlock" ];
    } else {
        btns += [ "Lock" ];
    }
    while ((llGetListLength(btns) % 3) != 0) {
        btns += " ";
    }

    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + DIALOG_TIMEOUT, CTX_MAIN, "", "", "", menu_chan);

    string msg = "The collar is currently ";
    if (g_locked) {
        msg += "LOCKED.\nUnlock the collar?";
    } else {
        msg += "UNLOCKED.\nLock the collar?";
    }
    llDialog(user, msg, btns, menu_chan);

    if (DEBUG) llOwnerSay("[LOCK] Menu → " + (string)user + " chan=" + (string)menu_chan);
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
            if (pname == KEY_LOCKED) {
                if (pval == "1") {
                    g_locked = TRUE;
                } else {
                    g_locked = FALSE;
                }
                set_lock_visibility(g_locked);
                enforce_rlv_detach(g_locked);
                if (DEBUG) llOwnerSay("[LOCK] Sync: locked=" + (string)g_locked);
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

        set_lock_visibility(g_locked);
        enforce_rlv_detach(g_locked);

        if (DEBUG) llOwnerSay("[LOCK] Ready, SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        if ((num == 500) && llSubStringIndex(str, REGISTER_NOW_MSG_START + "|") == 0)
        {
            string script_req = llGetSubString(str, llStringLength(REGISTER_NOW_MSG_START) + 1, -1);
            if (script_req == llGetScriptName())
            {
                string reg_msg = REGISTER_MSG_START + "|" + (string)PLUGIN_SN + "|" + PLUGIN_LABEL + "|"
                                + (string)PLUGIN_MIN_ACL + "|" + PLUGIN_CONTEXT + "|" + llGetScriptName();
                llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg_msg, NULL_KEY);
                if (DEBUG) llOwnerSay("[LOCK] Registration reply sent.");
            }
            return;
        }

        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG_START) {
                update_state_from_settings(parts);
            }
            return;
        }

        if (num == 520 && llSubStringIndex(str, "state_sync|") == 0) {
            list p = llParseString2List(str, ["|"], []);
            if (llGetListLength(p) >= 7) {
                string lock_str = llList2String(p, 6);
                if (lock_str == "1") {
                    g_locked = TRUE;
                } else {
                    g_locked = FALSE;
                }
                set_lock_visibility(g_locked);
                enforce_rlv_detach(g_locked);
                if (DEBUG) llOwnerSay("[LOCK] Legacy sync: locked=" + (string)g_locked);
            }
            return;
        }

        if ((num == UI_SHOW_MENU_NUM)) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 3) {
                string ctx = llList2String(parts, 1);
                key user = (key)llList2String(parts, 2);
                if (ctx == PLUGIN_CONTEXT) {
                    show_lock_menu(user);
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

            if (msg == "Back") {
                string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)id + "|0";
                llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
                s_clear(id);
                return;
            }

            if (ctx == CTX_MAIN)
            {
                if ((msg == "Lock") && (!g_locked)) {
                    g_locked = TRUE;
                    persist_locked(g_locked);
                    set_lock_visibility(g_locked);
                    enforce_rlv_detach(g_locked);
                    show_lock_menu(id);
                    return;
                }
                if ((msg == "Unlock") && (g_locked)) {
                    g_locked = FALSE;
                    persist_locked(g_locked);
                    set_lock_visibility(g_locked);
                    enforce_rlv_detach(g_locked);
                    show_lock_menu(id);
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
            llOwnerSay("[LOCK] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
