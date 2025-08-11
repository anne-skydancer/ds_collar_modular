/* =============================================================
   PLUGIN: ds_collar_plugin_template.lsl
   PURPOSE: Base boilerplate for DS Collar plugins
   VERSION: 2025-08-11
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Kernel ABI constants ---------- */
integer K_PLUGIN_REG_QUERY     = 500; // Kernel → Plugins: register_now
integer K_PLUGIN_REG_REPLY     = 501; // Plugins → Kernel: register
integer K_PLUGIN_SOFT_RESET    = 504; // Plugins → Kernel: notify of self-reset
integer K_SETTINGS_QUERY       = 800; // Plugin ↔ Settings
integer K_SETTINGS_SYNC        = 870; // Settings → Plugins
integer K_PLUGIN_START         = 900; // UI → Plugin: start menu
integer K_PLUGIN_RETURN_NUM    = 901; // Plugin → UI: return to root

/* ---------- Heartbeat ---------- */
integer K_PLUGIN_PING          = 650; // Kernel → Plugins
integer K_PLUGIN_PONG          = 651; // Plugins → Kernel

/* ---------- Plugin identity (change these for each plugin) ---------- */
integer PLUGIN_SN              = 0; // Random unique serial per boot
string  PLUGIN_LABEL           = "Template"; // Shown in main menu
integer PLUGIN_MIN_ACL         = 1; // 1 = Public
string  PLUGIN_CONTEXT         = "core_template"; // Unique plugin context
string  ROOT_CONTEXT           = "core_root";

/* ---------- Menu constants ---------- */
string BACK_BTN_LABEL          = "Back";
string FILLER_BTN_LABEL        = "~";
integer DIALOG_TIMEOUT         = 180;

/* ---------- Session state ---------- */
key     g_last_user            = NULL_KEY;
integer g_last_chan            = 0;
integer g_listen_handle        = 0;

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
    if (DEBUG) llOwnerSay("[TEMPLATE] Registered with kernel.");
}

notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   "plugin_soft_reset");
    j = llJsonSetValue(j, ["context"],PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    if (DEBUG) llOwnerSay("[TEMPLATE] Notified kernel of soft reset.");
}

show_menu(key avatar) {
    list buttons = [FILLER_BTN_LABEL, BACK_BTN_LABEL, FILLER_BTN_LABEL];
    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    if (g_listen_handle != 0) llListenRemove(g_listen_handle);
    g_listen_handle = llListen(menu_chan, "", avatar, "");
    g_last_user = avatar;
    g_last_chan = menu_chan;
    llDialog(avatar, "This is a placeholder menu for " + PLUGIN_LABEL, buttons, menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
}

cleanup_session() {
    if (g_listen_handle != 0) llListenRemove(g_listen_handle);
    g_listen_handle = 0;
    g_last_user = NULL_KEY;
    g_last_chan = 0;
    llSetTimerEvent(0.0);
}

/* =========================== Events ========================== */
default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_plugin();
    }

    link_message(integer sender, integer num, string str, key id) {
        // Heartbeat support
        if (num == K_PLUGIN_PING) {
            if (json_has(str, ["type"]) &&
                llJsonGetValue(str, ["type"]) == "ping" &&
                llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT) {
                string pong = llList2Json(JSON_OBJECT, []);
                pong = llJsonSetValue(pong, ["type"], "pong");
                pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
            }
            return;
        }

        // Register now request
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(str, ["type"]) &&
                llJsonGetValue(str, ["type"]) == "register_now" &&
                llJsonGetValue(str, ["script"]) == llGetScriptName()) {
                register_plugin();
            }
            return;
        }

        // Start menu
        if (num == K_PLUGIN_START) {
            if (json_has(str, ["context"]) &&
                llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT) {
                show_menu(id);
            }
            return;
        }
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel == g_last_chan && id == g_last_user) {
            if (msg == BACK_BTN_LABEL) {
                string j = llList2Json(JSON_OBJECT, []);
                j = llJsonSetValue(j, ["type"], "plugin_return");
                j = llJsonSetValue(j, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, j, id);
                cleanup_session();
                return;
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
