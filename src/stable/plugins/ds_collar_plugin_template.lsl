/* =============================================================
   PLUGIN BOILERPLATE: ds_collar_plugin_boilerplate.lsl
   PURPOSE: Hardened base for DS Collar plugins
     - JSON register + soft reset notify
     - Standard heartbeat (plugin_ping/pong)
     - Standard ACL handshake (query on start, gate UI)
     - Private dialog channel + Back to root
     - Optional per-button ACL re-check example
   NOTE: Replace identity fields, labels, and show_menu() body.
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY   = 500;  // Kernel → Plugins: {"type":"register_now","script":"<name>"}
integer K_PLUGIN_REG_REPLY   = 501;  // Plugins → Kernel : {"type":"register",...}
integer K_PLUGIN_SOFT_RESET  = 504;  // Plugins → Kernel : {"type":"plugin_soft_reset","context":...}

integer K_PLUGIN_PING        = 650;  // Kernel → Plugins: {"type":"plugin_ping","context":...}
integer K_PLUGIN_PONG        = 651;  // Plugins → Kernel : {"type":"plugin_pong","context":...}

integer AUTH_QUERY_NUM       = 700;  // Plugin → Auth    : {"type":"acl_query","avatar":"<key>"}
integer AUTH_RESULT_NUM      = 710;  // Auth   → Plugin  : {"type":"acl_result","avatar":"<key>","level":"<int>"}

integer K_SETTINGS_QUERY     = 800;  // (optional) settings
integer K_SETTINGS_SYNC      = 870;  // (optional) settings

integer K_PLUGIN_START       = 900;  // UI     → Plugin  : {"type":"plugin_start","context":...}
integer K_PLUGIN_RETURN_NUM  = 901;  // Plugin → UI      : {"type":"plugin_return","context":"core_root"}

/* ---------- Magic words (protocol strings) ---------- */
string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_REGISTER_NOW      = "register_now";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";

string CONS_MSG_ACL_QUERY          = "acl_query";
string CONS_MSG_ACL_RESULT         = "acl_result";

/* ---------- Identity (CHANGE THESE) ---------- */
string  PLUGIN_CONTEXT   = "core_template";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Template";
integer PLUGIN_SN        = 0;

/* ACL levels (authoritative mapping) */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0; // no wearer access
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Access policy for THIS plugin ----------
   Populate with the levels that may open this plugin.
   Example: allow Public, Owned, Trustee, Unowned, Primary
   list ALLOWED_ACL_LEVELS = [1,2,3,4,5];
*/
list ALLOWED_ACL_LEVELS = [1,2,3,4,5];

/* ---------- UI/session ---------- */
integer DIALOG_TIMEOUT_SEC = 180;
key     g_user      = NULL_KEY;
integer g_listen    = 0;
integer g_menu_chan = 0;

/* Gate state */
integer g_acl_pending = FALSE;
integer g_acl_level   = ACL_NOACCESS;

/* ========================== Helpers ========================== */

integer json_has(string j, list path) {
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return FALSE;
    return TRUE;
}

integer logd(string s) {
    if (DEBUG) llOwnerSay("[PLUGIN " + PLUGIN_CONTEXT + "] " + s);
    return 0;
}

/* ----- Kernel/Register/Soft reset ----- */
integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  "0");               // informational only; UI may ignore
    j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered with kernel.");
    return 0;
}

integer notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    logd("Soft reset notified.");
    return 0;
}

/* ----- ACL ----- */
integer in_allowed_levels(integer lvl) {
    if (llListFindList(ALLOWED_ACL_LEVELS, [lvl]) != -1) return TRUE;
    return FALSE;
}

integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    g_acl_pending = TRUE;
    logd("ACL query → " + (string)av);
    return 0;
}

/* ----- UI plumbing ----- */
integer reset_listen() {
    if (g_listen) llListenRemove(g_listen);
    g_listen = 0;
    g_menu_chan = 0;
    return 0;
}

integer begin_dialog(key user, string body, list buttons) {
    reset_listen();
    g_user = user;

    /* pad buttons to multiple of 3 */
    while ((llGetListLength(buttons) % 3) != 0) buttons += " ";

    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen    = llListen(g_menu_chan, "", g_user, "");
    llDialog(g_user, body, buttons, g_menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}

/* ----- UI content (REPLACE for real plugin) ----- */
integer show_menu(key user) {
    list btns = ["~", "Back", "~", "Example"];
    begin_dialog(user, "Template menu.\nReplace this with your content.", btns);
    logd("Menu → " + (string)user + " chan=" + (string)g_menu_chan);
    return 0;
}

/* Example per-button ACL re-check (call before action) */
integer enforce_button_acl(integer lvl, list allowed_for_button) {
    if (llListFindList(allowed_for_button, [lvl]) != -1) return TRUE;
    llRegionSayTo(g_user, 0, "You do not have permission for that action.");
    return FALSE;
}

/* =========================== Events ========================== */
default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        g_user = NULL_KEY;
        g_acl_pending = FALSE;
        g_acl_level = ACL_NOACCESS;
        reset_listen();
        llSetTimerEvent(0.0);

        notify_soft_reset();
        register_plugin();

        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* Heartbeat */
        if (num == K_PLUGIN_PING) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_PING) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    string pong = llList2Json(JSON_OBJECT, []);
                    pong = llJsonSetValue(pong, ["type"],    CONS_TYPE_PLUGIN_PONG);
                    pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                }
            }
            return;
        }

        /* Kernel asks this specific script to re-register */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        /* UI start → secure: request ACL, defer menu until result */
        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    g_user = id;
                    request_acl(g_user);
                }
            }
            return;
        }

        /* ACL result */
        if (num == AUTH_RESULT_NUM) {
            if (!g_acl_pending) return;
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != CONS_MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;

            key who = (key)llJsonGetValue(msg, ["avatar"]);
            if (who != g_user) return;

            if (!json_has(msg, ["level"])) return;
            g_acl_level = (integer)llJsonGetValue(msg, ["level"]);
            g_acl_pending = FALSE;

            if (in_allowed_levels(g_acl_level)) {
                show_menu(g_user);
            } else {
                llRegionSayTo(g_user, 0, "Access denied.");
                /* return to root */
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);
                g_user = NULL_KEY;
                reset_listen();
                llSetTimerEvent(0.0);
            }
            return;
        }

        /* (Optional) settings sync hook if your plugin needs it
        if (num == K_SETTINGS_SYNC) {
            // read settings JSON here
            return;
        }
        */
    }

    listen(integer chan, string name, key id, string message) {
        if (chan != g_menu_chan) return;
        if (id != g_user) return;

        if (message == "Back") {
            /* Return to root UI */
            string r = llList2Json(JSON_OBJECT, []);
            r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
            r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);

            reset_listen();
            g_user = NULL_KEY;
            llSetTimerEvent(0.0);
            return;
        }

        if (message == "Example") {
            /* Example per-button ACL: only Trustees+ (3,5) allowed */
            list allow_btn = [ACL_TRUSTEE, ACL_PRIMARY_OWNER];
            if (!enforce_button_acl(g_acl_level, allow_btn)) return;

            llRegionSayTo(g_user, 0, "Example action executed.");
            show_menu(g_user);
            return;
        }

        /* Unknown → redraw */
        show_menu(g_user);
    }

    timer() {
        reset_listen();
        g_user = NULL_KEY;
        llSetTimerEvent(0.0);
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("Owner changed. Resetting plugin: " + PLUGIN_CONTEXT);
            llResetScript();
        }
    }
}
