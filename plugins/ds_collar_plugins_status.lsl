/* =============================================================
   PLUGIN: ds_collar_plugin_status.lsl
   PURPOSE: Display collar status, Back returns to main menu
   VERSION: 2025-08-01 (Canonical protocol, Animate-compliant)
   ============================================================= */

integer DEBUG = TRUE;

// Canonical protocol constants (global for all DS Collar scripts)
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";

// Plugin info (parametric)
string PLUGIN_CONTEXT      = "core_status";
string ROOT_CONTEXT        = "core_root";
string BACK_BTN_LABEL      = "Back";
string FILLER_BTN_LABEL    = "~";

integer PLUGIN_SN          = 0;
string  PLUGIN_LABEL       = "Status";
integer PLUGIN_MIN_ACL     = 4;

// Protocol channels
integer PLUGIN_REG_QUERY_NUM = 500;
integer PLUGIN_REG_REPLY_NUM = 501;
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;
integer UI_SHOW_MENU_NUM     = 601;

// Session/listen state
key     last_user        = NULL_KEY;
integer last_chan        = 0;
integer g_listen_handle  = 0;

integer DIALOG_TIMEOUT = 180;

// State synced from settings
key     owner_key        = NULL_KEY;
string  owner_hon        = "";
list    trustee_keys     = [];
list    trustee_hons     = [];
list    blacklist_keys   = [];
integer public_access    = FALSE;
integer locked           = FALSE;

// Settings keys (parametric)
string KEY_OWNER_KEY         = "owner_key";
string KEY_OWNER_HON         = "owner_hon";
string KEY_TRUSTEES          = "trustees";
string KEY_TRUSTEE_HONS      = "trustee_honorifics";
string KEY_BLACKLIST         = "blacklist";
string KEY_PUBLIC_ACCESS     = "public_mode";
string KEY_LOCKED            = "locked";

// Settings sync handler
update_from_settings(list parts) {
    integer len = llGetListLength(parts);
    owner_key      = NULL_KEY;
    owner_hon      = "";
    trustee_keys   = [];
    trustee_hons   = [];
    blacklist_keys = [];
    public_access  = FALSE;
    locked         = FALSE;

    integer i;
    for (i = 1; i < len; i++) {
        string kv = llList2String(parts, i);
        integer sep_idx = llSubStringIndex(kv, "=");
        if (sep_idx != -1) {
            string k = llGetSubString(kv, 0, sep_idx - 1);
            string v = llGetSubString(kv, sep_idx + 1, -1);
            if (k == KEY_OWNER_KEY) owner_key = (key)v;
            else if (k == KEY_OWNER_HON) owner_hon = v;
            else if (k == KEY_TRUSTEES) trustee_keys = llParseString2List(v, [","], []);
            else if (k == KEY_TRUSTEE_HONS) trustee_hons = llParseString2List(v, [","], []);
            else if (k == KEY_BLACKLIST) blacklist_keys = llParseString2List(v, [","], []);
            else if (k == KEY_PUBLIC_ACCESS) public_access = (v == "1");
            else if (k == KEY_LOCKED) locked = (integer)v;
        }
    }
}

// Build status string for dialog
string build_status_report() {
    string status = "";
    status += "Collar status:\n";
    if (locked) status += "🔒 Locked\n";
    else        status += "🔓 Unlocked\n";

    if (owner_key != NULL_KEY)
        status += "Owner: " + owner_hon + "\n";
    else
        status += "Owner: (unowned)\n";

    integer tlen = llGetListLength(trustee_keys);
    if (tlen > 0) {
        status += "Trustees: ";
        integer i;
        for (i = 0; i < tlen; ++i) {
            if (i != 0) status += ", ";
            status += llList2String(trustee_hons, i);
        }
        status += "\n";
    } else {
        status += "Trustees: (none)\n";
    }

    if (public_access) status += "Public Access: ON\n";
    else               status += "Public Access: OFF\n";

    return status;
}

// Register plugin with script name (canonical)
register_plugin() {
    string msg = REGISTER_MSG_START + "|" +
                 (string)PLUGIN_SN + "|" +
                 PLUGIN_LABEL + "|" +
                 (string)PLUGIN_MIN_ACL + "|" +
                 PLUGIN_CONTEXT + "|" +
                 llGetScriptName();
    llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, msg, NULL_KEY);
    if (DEBUG) llOwnerSay("[STATUS] Registered: " + msg);
}

// Show status menu (indices 0/1/2 always "~", "Back", "~")
show_status_menu(key avatar) {
    string report = build_status_report();
    list buttons = [ FILLER_BTN_LABEL, BACK_BTN_LABEL, FILLER_BTN_LABEL ];
    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    if (g_listen_handle != 0) llListenRemove(g_listen_handle);
    g_listen_handle = llListen(menu_chan, "", avatar, "");
    last_user = avatar;
    last_chan = menu_chan;
    llDialog(avatar, report, buttons, menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    if (DEBUG) llOwnerSay("[STATUS] Showed status to " + (string)avatar + " (chan=" + (string)menu_chan + ")");
}

// Return to main/root menu (always core_root)
return_to_main_menu(key avatar) {
    string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)avatar + "|0";
    llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
    if (DEBUG) llOwnerSay("[STATUS] Sent Back to main menu for " + (string)avatar);
}

// Clean up listen/session/timer
cleanup_session() {
    if (g_listen_handle != 0) llListenRemove(g_listen_handle);
    g_listen_handle = 0;
    last_user = NULL_KEY;
    last_chan = 0;
    llSetTimerEvent(0.0);
}

default
{
    state_entry()
    {
        PLUGIN_SN = (integer)(llFrand(1.0e5));
        if (DEBUG) llOwnerSay("[STATUS] state_entry, registering plugin.");
        register_plugin();
        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        // Settings sync from core/settings
        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG_START) {
                update_from_settings(parts);
                if (DEBUG) llOwnerSay("[STATUS] Updated settings from sync.");
            }
            return;
        }
        // Menu request from UI
        if (num == UI_SHOW_MENU_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 3) {
                string ctx = llList2String(parts, 1);
                key avatar = (key)llList2String(parts, 2);
                if (ctx == PLUGIN_CONTEXT) {
                    show_status_menu(avatar);
                    return;
                }
            }
        }
        // Registration protocol (optional, for plugin re-reg)
        if ((num == PLUGIN_REG_QUERY_NUM) && llSubStringIndex(str, REGISTER_NOW_MSG_START + "|") == 0)
        {
            string script_req = llGetSubString(str, llStringLength(REGISTER_NOW_MSG_START) + 1, -1);
            if (script_req == llGetScriptName()) {
                register_plugin();
            }
        }
    }

    listen(integer channel, string name, key id, string msg) {
        // Only react to current dialog channel and user
        if (channel == last_chan && id == last_user) {
            if (msg == BACK_BTN_LABEL) {
                // Canonical: Send menu change, cleanup, return
                return_to_main_menu(id);
                cleanup_session();
                return;
            }
            // All button presses clean up dialog/listen
            cleanup_session();
        }
    }

    timer() {
        cleanup_session();
    }
}
