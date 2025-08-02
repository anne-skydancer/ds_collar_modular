/* =============================================================
   PLUGIN: ds_collar_plugin_TEMPLATE.lsl (DS Collar Canonical)
   PURPOSE: Template for DS Collar plugins (Core 1.4+)
   AUTHOR:  [Your Name or Project]
   DATE:    2025-08-01
   ============================================================= */

integer DEBUG = TRUE;

// ---- CANONICAL PROTOCOL CONSTANTS (USE ACROSS ALL SCRIPTS) ----
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";

// ---- PLUGIN PARAMETERS (CUSTOMIZE PER PLUGIN) ----
string  PLUGIN_CONTEXT      = "core_template";  // Must match in core and UI
string  ROOT_CONTEXT        = "core_root";      // Where "Back" always returns
string  PLUGIN_LABEL        = "Template";
integer PLUGIN_MIN_ACL      = 4;
integer PLUGIN_SN           = 0;

// ---- CHANNELS ----
integer PLUGIN_REG_QUERY_NUM = 500;
integer PLUGIN_REG_REPLY_NUM = 501;
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;
integer UI_SHOW_MENU_NUM     = 601;

// ---- UI CONSTANTS ----
string  BACK_BTN_LABEL   = "Back";
string  FILLER_BTN_LABEL = "~";
integer DIALOG_TIMEOUT   = 180;

// ---- SESSION STATE ----
key     last_user        = NULL_KEY;
integer last_chan        = 0;
integer g_listen_handle  = 0;

// ---- SETTINGS STATE (Example) ----
// Add plugin settings here as needed

// ---- SETTINGS HANDLER ----
update_from_settings(list parts) {
    // Parse and update plugin-specific settings here if needed
    // See compliance notes for standard format.
}

// ---- CANONICAL REGISTRATION ----
register_plugin() {
    string msg = REGISTER_MSG_START + "|" +
                 (string)PLUGIN_SN + "|" +
                 PLUGIN_LABEL + "|" +
                 (string)PLUGIN_MIN_ACL + "|" +
                 PLUGIN_CONTEXT + "|" +
                 llGetScriptName();
    llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, msg, NULL_KEY);
    if (DEBUG) llOwnerSay("[TEMPLATE] Registered: " + msg);
}

// ---- UI MENU LOGIC ----
show_plugin_menu(key avatar) {
    list buttons = [ FILLER_BTN_LABEL, BACK_BTN_LABEL, FILLER_BTN_LABEL ];
    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    if (g_listen_handle != 0) llListenRemove(g_listen_handle);
    g_listen_handle = llListen(menu_chan, "", avatar, "");
    last_user = avatar;
    last_chan = menu_chan;
    llDialog(avatar, "This is a template plugin menu.\n(Back returns to main menu.)", buttons, menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    if (DEBUG) llOwnerSay("[TEMPLATE] Menu to " + (string)avatar + " (chan=" + (string)menu_chan + ")");
}

// ---- RETURN TO MAIN MENU ----
return_to_main_menu(key avatar) {
    string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)avatar + "|0";
    llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
    if (DEBUG) llOwnerSay("[TEMPLATE] Sent Back to main menu for " + (string)avatar);
}

// ---- CLEANUP ----
cleanup_session() {
    if (g_listen_handle != 0) llListenRemove(g_listen_handle);
    g_listen_handle = 0;
    last_user = NULL_KEY;
    last_chan = 0;
    llSetTimerEvent(0.0);
}

// ---- MAIN EVENT LOOP ----
default
{
    state_entry()
    {
        PLUGIN_SN = (integer)(llFrand(1.0e5));
        if (DEBUG) llOwnerSay("[TEMPLATE] state_entry, registering plugin.");
        register_plugin();
        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        // Settings sync (optional for settings-aware plugins)
        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG_START) {
                update_from_settings(parts);
                if (DEBUG) llOwnerSay("[TEMPLATE] Updated settings from sync.");
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
                    show_plugin_menu(avatar);
                    return;
                }
            }
        }
        // Registration protocol (re-registration handshake)
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
                return_to_main_menu(id);
            }
            cleanup_session();
        }
    }

    timer() {
        cleanup_session();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[TEMPLATE] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
