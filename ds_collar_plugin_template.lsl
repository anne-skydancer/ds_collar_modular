/* =============================================================
   PLUGIN TEMPLATE: DS Collar Plugin (2025-07-31)
   Protocol-safe, Back-to-root ready, serial auto-assigned
   ============================================================= */

integer DEBUG = TRUE;

// Protocol constants
string REGISTER_MSG      = "register";
string SETTINGS_SYNC_MSG = "settings_sync";
string SHOW_DIALOG_MSG   = "show_dialog";
string GET_SETTINGS_MSG  = "get_settings";
string SHOW_MENU_MSG     = "show_menu";
string ROOT_CONTEXT      = "core_root";
string BACK_BTN_LABEL    = "Back";
string FILLER_BTN_LABEL  = "~";

// Plugin identity (serial auto-assigned)
integer PLUGIN_SN        = 0; // assigned at state_entry
string  PLUGIN_LABEL     = "MyPlugin";
integer PLUGIN_MIN_ACL   = 4;
string  PLUGIN_CONTEXT   = "myplugin_context";

// Channels
integer PLUGIN_REG_QUERY_NUM = 500;
integer PLUGIN_REG_REPLY_NUM = 501;
integer PLUGIN_UNREG_NUM     = 502;
integer UI_SHOW_MENU_NUM     = 601;
integer UI_DIALOG_NUM        = 602;
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;

// Persistent state (example)
key     owner_key        = NULL_KEY;
string  owner_hon        = "";

// Settings keys (example)
string KEY_OWNER_KEY     = "owner_key";
string KEY_OWNER_HON     = "owner_hon";

// Helpers
update_from_settings(list parts) {
    integer len = llGetListLength(parts);
    integer i;
    owner_key = NULL_KEY;
    owner_hon = "";
    for (i = 1; i < len; ++i) {
        string kv = llList2String(parts, i);
        integer sep_idx = llSubStringIndex(kv, "=");
        if (sep_idx != -1) {
            string k = llGetSubString(kv, 0, sep_idx - 1);
            string v = llGetSubString(kv, sep_idx + 1, -1);
            if (k == KEY_OWNER_KEY) owner_key = (key)v;
            else if (k == KEY_OWNER_HON) owner_hon = v;
        }
    }
}

// Dialog builder (example: just shows owner info)
string build_status() {
    string s = "Owner: ";
    if (owner_key != NULL_KEY)
        s += owner_hon;
    else
        s += "(unowned)";
    s += "\n";
    return s;
}

// Show plugin's main dialog
show_plugin_menu(key avatar) {
    // Filler, Back, Filler (main menu on Back)
    list buttons = [FILLER_BTN_LABEL, BACK_BTN_LABEL, FILLER_BTN_LABEL];
    string msg = SHOW_DIALOG_MSG + "|" + (string)avatar + "|" +
                 llEscapeURL(build_status()) + "|" +
                 llDumpList2String(buttons, ",") + "|" +
                 PLUGIN_CONTEXT;
    llMessageLinked(LINK_SET, UI_DIALOG_NUM, msg, NULL_KEY);
    if (DEBUG) llOwnerSay("[PLUGIN] Showed dialog to " + (string)avatar);
}

// MAIN EVENT HANDLERS
default
{
    state_entry()
    {
        // Assign a random serial for portable uniqueness
        PLUGIN_SN = (integer)(llFrand(1.0e5));
        if (DEBUG) llOwnerSay("[PLUGIN] state_entry, registering plugin: SN=" + (string)PLUGIN_SN);
        string reg = REGISTER_MSG + "|" + (string)PLUGIN_SN + "|" +
                     PLUGIN_LABEL + "|" + (string)PLUGIN_MIN_ACL + "|" + PLUGIN_CONTEXT;
        llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg, NULL_KEY);
        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, GET_SETTINGS_MSG, NULL_KEY);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        // Handle settings sync
        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG) {
                update_from_settings(parts);
                if (DEBUG) llOwnerSay("[PLUGIN] Updated settings from sync.");
            }
            return;
        }

        // Respond to UI show_menu call
        if (num == UI_SHOW_MENU_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 3) {
                string ctx = llList2String(parts, 1);
                key avatar = (key)llList2String(parts, 2);
                // If user pressed *this* plugin's button, show plugin menu
                if (ctx == PLUGIN_CONTEXT) {
                    show_plugin_menu(avatar);
                    return;
                }
                // If user pressed Back in a plugin, and context is root, go back to main menu
                if (ctx == ROOT_CONTEXT) {
                    // No-op here, UI will handle redrawing main menu
                    // Optionally, log this event for debugging
                    if (DEBUG) llOwnerSay("[PLUGIN] Back to main menu requested by " + (string)avatar);
                    return;
                }
            }
        }
    }

    listen(integer channel, string name, key id, string msg) {
        // Not used in simple plugins
    }
}
