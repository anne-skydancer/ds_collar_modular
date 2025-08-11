/* =============================================================
   PLUGIN: ds_collar_plugin_status.lsl
   PURPOSE: Show collar status; Back returns to main menu
   NOTES:
     - Uses named constants for all JSON "type" strings
     - Heartbeat (ping/pong) + plugin_soft_reset on boot
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Global String Constants (Magic Words) ---------- */
string TYPE_REGISTER         = "register";
string TYPE_REGISTER_NOW     = "register_now";
string TYPE_PLUGIN_PING      = "plugin_ping";
string TYPE_PLUGIN_PONG      = "plugin_pong";
string TYPE_PLUGIN_SOFT_RESET= "plugin_soft_reset";
string TYPE_SETTINGS_GET     = "settings_get";
string TYPE_SETTINGS_SYNC    = "settings_sync";
string TYPE_PLUGIN_RETURN    = "plugin_return";

/* ---------- Link message channels ---------- */
integer K_PLUGIN_REG_QUERY   = 500; // Kernel → Plugins: register_now
integer K_PLUGIN_REG_REPLY   = 501; // Plugins → Kernel: register
integer K_PLUGIN_SOFT_RESET  = 504; // Plugins → Kernel: notify self-reset
integer K_PLUGIN_PING        = 650; // Kernel → Plugins: plugin_ping
integer K_PLUGIN_PONG        = 651; // Plugins → Kernel: plugin_pong
integer K_SETTINGS_QUERY     = 800; // Any ↔ Settings
integer K_SETTINGS_SYNC      = 870; // Settings → Any
integer K_PLUGIN_START       = 900; // UI → Plugin: start (context only)
integer K_PLUGIN_RETURN_NUM  = 901; // Plugin → UI: plugin_return

/* ---------- Plugin identity ---------- */
integer PLUGIN_SN      = 0;
string  PLUGIN_LABEL   = "Status";
integer PLUGIN_MIN_ACL = 1;             // Public
string  PLUGIN_CONTEXT = "core_status";
string  ROOT_CONTEXT   = "core_root";

/* ---------- Menu constants ---------- */
string BTN_BACK        = "Back";
string BTN_FILL        = "~";
integer DIALOG_TIMEOUT = 180;

/* ---------- Settings keys ---------- */
string KEY_OWNER_KEY      = "owner_key";
string KEY_OWNER_HON      = "owner_hon";
string KEY_TRUSTEES       = "trustees";
string KEY_TRUSTEE_HONS   = "trustee_honorifics";
string KEY_BLACKLIST      = "blacklist";
string KEY_PUBLIC_ACCESS  = "public_mode";
string KEY_LOCKED         = "locked";

/* ---------- State from settings ---------- */
key     owner_key      = NULL_KEY;
string  owner_hon      = "";
list    trustee_keys   = [];
list    trustee_hons   = [];
list    blacklist_keys = [];
integer public_access  = FALSE;
integer locked         = FALSE;

/* ---------- Session state ---------- */
key     g_user         = NULL_KEY;
integer g_chan         = 0;
integer g_listen       = 0;

/* ========================== Helpers ========================== */
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer logd(string s) { if (DEBUG) llOwnerSay("[STATUS] " + s); return 0; }

register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],      (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],   PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"], (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered with kernel.");
}

notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    logd("Soft reset notified.");
}

request_settings_sync_once() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
}

update_from_settings(string kv_json) {
    if (llGetSubString(kv_json, 0, 0) != "{") return;

    owner_key      = NULL_KEY;
    owner_hon      = "";
    trustee_keys   = [];
    trustee_hons   = [];
    blacklist_keys = [];
    public_access  = FALSE;
    locked         = FALSE;

    if (json_has(kv_json, [KEY_OWNER_KEY]))      owner_key = (key)llJsonGetValue(kv_json, [KEY_OWNER_KEY]);
    if (json_has(kv_json, [KEY_OWNER_HON]))      owner_hon = llJsonGetValue(kv_json, [KEY_OWNER_HON]);
    if (json_has(kv_json, [KEY_TRUSTEES]))       trustee_keys = llJson2List(llJsonGetValue(kv_json, [KEY_TRUSTEES]));
    if (json_has(kv_json, [KEY_TRUSTEE_HONS]))   trustee_hons = llJson2List(llJsonGetValue(kv_json, [KEY_TRUSTEE_HONS]));
    if (json_has(kv_json, [KEY_BLACKLIST]))      blacklist_keys = llJson2List(llJsonGetValue(kv_json, [KEY_BLACKLIST]));
    if (json_has(kv_json, [KEY_PUBLIC_ACCESS]))  public_access = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_ACCESS]);
    if (json_has(kv_json, [KEY_LOCKED]))         locked = (integer)llJsonGetValue(kv_json, [KEY_LOCKED]);

    logd("Settings updated from sync.");
}

string build_status_report() {
    string s = "Collar status:\n";
    if (locked) s += "🔒 Locked\n";
    else s += "🔓 Unlocked\n";

    if (owner_key != NULL_KEY) s += "Owner: " + owner_hon + "\n";
    else s += "Owner: (unowned)\n";

    integer tlen = llGetListLength(trustee_keys);
    if (tlen > 0) {
        s += "Trustees: ";
        integer i = 0;
        while (i < tlen) {
            if (i != 0) s += ", ";
            s += llList2String(trustee_hons, i);
            i += 1;
        }
        s += "\n";
    } else {
        s += "Trustees: (none)\n";
    }

    if (public_access) s += "Public Access: ON\n";
    else s += "Public Access: OFF\n";

    return s;
}

show_menu(key avatar) {
    string report = build_status_report();
    list buttons = [BTN_FILL, BTN_BACK, BTN_FILL];

    if (g_listen != 0) llListenRemove(g_listen);
    g_chan = -(integer)llFrand(1000000.0) - 100000;
    g_listen = llListen(g_chan, "", avatar, "");

    g_user = avatar;
    llDialog(avatar, report, buttons, g_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    logd("Menu shown to " + (string)avatar);
}

cleanup_session() {
    if (g_listen != 0) llListenRemove(g_listen);
    g_listen = 0;
    g_user = NULL_KEY;
    g_chan = 0;
    llSetTimerEvent(0.0);
}

/* =========================== Events ========================== */
default {
    state_entry() {
        cleanup_session();
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_plugin();
        request_settings_sync_once();
    }

    link_message(integer sender, integer num, string str, key id) {
        /* Heartbeat */
        if (num == K_PLUGIN_PING) {
            if (json_has(str, ["type"])) {
                if (llJsonGetValue(str, ["type"]) == TYPE_PLUGIN_PING &&
                    json_has(str, ["context"]) &&
                    llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT) {

                    string pong = llList2Json(JSON_OBJECT, []);
                    pong = llJsonSetValue(pong, ["type"],    TYPE_PLUGIN_PONG);
                    pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                }
            }
            return;
        }

        /* Settings sync */
        if (num == K_SETTINGS_SYNC) {
            if (json_has(str, ["type"])) {
                if (llJsonGetValue(str, ["type"]) == TYPE_SETTINGS_SYNC && json_has(str, ["kv"])) {
                    update_from_settings(llJsonGetValue(str, ["kv"]));
                }
            }
            return;
        }

        /* Kernel asks to register now */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(str, ["type"])) {
                if (llJsonGetValue(str, ["type"]) == TYPE_REGISTER_NOW &&
                    json_has(str, ["script"]) &&
                    llJsonGetValue(str, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        /* UI → start our menu (context-only payload) */
        if (num == K_PLUGIN_START) {
            if (json_has(str, ["context"])) {
                if (llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT) {
                    show_menu(id);
                }
            }
            return;
        }
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel == g_chan && id == g_user) {
            if (msg == BTN_BACK) {
                string j = llList2Json(JSON_OBJECT, []);
                j = llJsonSetValue(j, ["type"],    TYPE_PLUGIN_RETURN);
                j = llJsonSetValue(j, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, j, id);
                cleanup_session();
                return;
            }
            cleanup_session();
        }
    }

    timer() { cleanup_session(); }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }
}
