/* =============================================================
   PLUGIN: ds_collar_plugin_boilerplate.lsl
   PURPOSE: Template for DS Collar plugins
            - Handles registration with kernel
            - Responds to heartbeat pings
            - Has placeholder menu with Back button
   VERSION: 2025-08-11
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Kernel ABI constants ---------- */
integer K_PLUGIN_REG_QUERY   = 500; // Kernel → Plugins: register_now
integer K_PLUGIN_REG_REPLY   = 501; // Plugins → Kernel: register
integer K_PLUGIN_START       = 900; // UI → Plugin: start UI
integer PLUGIN_RETURN_NUM    = 901; // Plugin → UI: return to root

// Heartbeat
integer K_PLUGIN_PING        = 650;
integer K_PLUGIN_PONG        = 651;

/* ---------- Plugin identity ---------- */
integer PLUGIN_SN      = 0; // Random unique serial per boot
string  PLUGIN_LABEL   = "Boilerplate Plugin";
integer PLUGIN_MIN_ACL = 1; // 1 = Public in ACL model
string  PLUGIN_CONTEXT = "core_boiler";
string  ROOT_CONTEXT   = "core_root";

/* ---------- Menu constants ---------- */
string BACK_BTN_LABEL   = "Back";
string FILLER_BTN_LABEL = "~";
integer DIALOG_TIMEOUT  = 180;

/* ---------- Session state ---------- */
key     last_user        = NULL_KEY;
integer last_chan        = 0;
integer g_listen_handle  = 0;

/* ========================== Helpers ========================== */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   "register");
    j = llJsonSetValue(j, ["sn"],     (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],  PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],(string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"],PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] Registered with kernel (JSON).");
}

show_placeholder_menu(key avatar) {
    string msg = "This is a placeholder menu for plugin: " + PLUGIN_LABEL;
    list buttons = [FILLER_BTN_LABEL, BACK_BTN_LABEL, FILLER_BTN_LABEL];
    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    if (g_listen_handle != 0) llListenRemove(g_listen_handle);
    g_listen_handle = llListen(menu_chan, "", avatar, "");
    last_user = avatar;
    last_chan = menu_chan;
    llDialog(avatar, msg, buttons, menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] Showed placeholder menu to " + (string)avatar);
}

cleanup_session() {
    if (g_listen_handle != 0) llListenRemove(g_listen_handle);
    g_listen_handle = 0;
    last_user = NULL_KEY;
    last_chan = 0;
    llSetTimerEvent(0.0);
}

/* =========================== Events ========================== */

default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] Booting, registering plugin.");
        register_plugin();
    }

    link_message(integer sender, integer num, string str, key id) {
        // Heartbeat support
        if (num == K_PLUGIN_PING) {
            if (json_has(str, ["type"]) &&
                llJsonGetValue(str, ["type"]) == "plugin_ping" &&
                llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT) {
                string pong = llList2Json(JSON_OBJECT, []);
                pong = llJsonSetValue(pong, ["type"], "plugin_pong");
                pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
            }
            return;
        }

        // Handle registration solicitation from kernel
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(str, ["type"]) &&
                llJsonGetValue(str, ["type"]) == "register_now" &&
                json_has(str, ["script"]) &&
                llJsonGetValue(str, ["script"]) == llGetScriptName()) {
                register_plugin();
            }
            return;
        }

        // Start menu from UI
        if (num == K_PLUGIN_START) {
            if (json_has(str, ["context"]) &&
                llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT) {
                show_placeholder_menu(id);
            }
            return;
        }
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel == last_chan && id == last_user) {
            if (msg == BACK_BTN_LABEL) {
                string j = llList2Json(JSON_OBJECT, []);
                j = llJsonSetValue(j, ["type"], "plugin_return");
                j = llJsonSetValue(j, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, PLUGIN_RETURN_NUM, j, id);
                cleanup_session();
                state default;
            }
            cleanup_session();
        }
    }

    timer() {
        cleanup_session();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }
}
