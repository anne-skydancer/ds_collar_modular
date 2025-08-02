/* =============================================================
   PLUGIN: ds_collar_plugin_leash.lsl (DS Collar Canonical)
   PURPOSE: Leashing & Movement Restraint Plugin
   DATE:    2025-08-01
   ============================================================= */

integer DEBUG = TRUE;

// ---- CANONICAL PROTOCOL CONSTANTS ----
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";

// ---- PLUGIN PARAMETERS ----
integer PLUGIN_SN         = 0;
string  PLUGIN_LABEL      = "Leashing";
integer PLUGIN_MIN_ACL    = 4;
string  PLUGIN_CONTEXT    = "core_leash";
string  ROOT_CONTEXT      = "core_root";

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

// ---- PLUGIN-SPECIFIC STATE ----
integer g_leashed       = FALSE;
key     g_leasher       = NULL_KEY;
integer g_leash_length  = 2;
integer g_follow_mode   = TRUE;
integer g_controls_ok   = FALSE;
integer g_turn_to       = FALSE;
vector  g_anchor        = ZERO_VECTOR;
string  g_chain_texture = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";

// ACL state
key     g_owner         = NULL_KEY;
list    g_trustees      = [];
list    g_blacklist     = [];
integer g_public_access = FALSE;

// ---- SETTINGS HANDLER ----
update_from_settings(list parts) {
    // Extend to sync leash-specific settings if needed in future
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
    if (DEBUG) llOwnerSay("[LEASH] Registered: " + msg);
}

// ---- ACL/ACCESS CONTROL ----
integer get_acl(key av)
{
    if (llListFindList(g_blacklist, [av]) != -1) return 5;
    if (av == g_owner) return 1;
    if (av == llGetOwner()) {
        if (g_owner == NULL_KEY) return 1;
        return 3;
    }
    if (llListFindList(g_trustees, [av]) != -1) return 2;
    if (g_public_access == TRUE) return 4;
    return 5;
}

// ---- UI MENU LOGIC ----
list leash_menu_btns(integer acl)
{
    list btns = [];
    if (acl == 1) {
        btns += ["Leash", "Unleash", "Set Length", "Turn", "Pass Leash", "Anchor Leash"];
    }
    else if (acl == 2) {
        btns += ["Leash", "Unleash", "Set Length", "Pass Leash", "Anchor Leash"];
    }
    else if (acl == 3) {
        btns += ["Unclip", "Give Leash"];
    }
    else if (acl == 4) {
        btns += ["Leash", "Unleash"];
    }
    while (llGetListLength(btns) % 3 != 0) btns += [" "];
    return btns;
}

show_leash_menu(key av)
{
    integer acl = get_acl(av);
    list btns = [FILLER_BTN_LABEL, BACK_BTN_LABEL, FILLER_BTN_LABEL] + leash_menu_btns(acl);
    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    if (g_listen_handle != 0) llListenRemove(g_listen_handle);
    g_listen_handle = llListen(menu_chan, "", av, "");
    last_user = av;
    last_chan = menu_chan;

    string st = "Leash state:\n";
    if (g_leashed) {
        st += "Leashed to: " + llKey2Name(g_leasher) + "\n";
    } else {
        st += "Not leashed\n";
    }
    st += "Length: " + (string)g_leash_length + " m";
    if (g_turn_to) {
        st += "\nTurn: ON";
    } else {
        st += "\nTurn: OFF";
    }
    llDialog(av, st, btns, menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    if (DEBUG) llOwnerSay("[LEASH] Menu → " + (string)av + " (chan=" + (string)menu_chan + ")");
}

// ---- RETURN TO MAIN MENU ----
return_to_main_menu(key avatar) {
    string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)avatar + "|0";
    llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
    if (DEBUG) llOwnerSay("[LEASH] Sent Back to main menu for " + (string)avatar);
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
        if (DEBUG) llOwnerSay("[LEASH] state_entry, registering plugin.");
        register_plugin();
        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        // Settings sync (optional)
        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG_START) {
                update_from_settings(parts);
                if (DEBUG) llOwnerSay("[LEASH] Updated settings from sync.");
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
                    show_leash_menu(avatar);
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
        // Call leash logic here if needed (for actual movement restraint/particles, etc.)
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[LEASH] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
