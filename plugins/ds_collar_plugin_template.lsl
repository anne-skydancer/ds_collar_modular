/* =============================================================
   PLUGIN: ds_collar_plugin_template.lsl
   PURPOSE: Authoritative DS Collar boilerplate for new kernel
            - JSON register
            - Heartbeat (ping/pong)
            - Plugin soft-reset notify
            - ACL-gated entry (Auth module)
            - Animate/Status-style menu (Back centered)
            - Private dialog channel + safe listener
   NOTES:
     • Change the identity block (CONTEXT/LABEL/MIN_ACL).
     • If per-button ACL is needed, use allow_level() again at click-time.
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY     = 500; // Kernel → Plugins: {"type":"register_now","script":"<name>"}
integer K_PLUGIN_REG_REPLY     = 501; // Plugins → Kernel: {"type":"register",...}
integer K_PLUGIN_SOFT_RESET    = 504; // Plugins → Kernel: {"type":"plugin_soft_reset","context":...}

integer K_PLUGIN_PING          = 650; // Kernel → Plugins: {"type":"plugin_ping","context":...}
integer K_PLUGIN_PONG          = 651; // Plugins → Kernel: {"type":"plugin_pong","context":...}

integer AUTH_QUERY_NUM         = 700; // to Auth: {"type":"acl_query","avatar":"<key>"}
integer AUTH_RESULT_NUM        = 710; // from Auth: {"type":"acl_result","avatar":"<key>","level":"<int>"}

integer K_SETTINGS_QUERY       = 800; // Plugin ↔ Settings (JSON)
integer K_SETTINGS_SYNC        = 870; // Settings → Plugin  (JSON)

integer K_PLUGIN_START         = 900; // UI → Plugin : {"type":"plugin_start","context":...}
integer K_PLUGIN_RETURN_NUM    = 901; // Plugin → UI : {"type":"plugin_return","context":"core_root"}

/* ---------- Shared magic words (keep consistent) ---------- */
string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_REGISTER_NOW      = "register_now";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";

string CONS_SETTINGS_GET           = "settings_get";
string CONS_SETTINGS_SYNC          = "settings_sync";
string CONS_SETTINGS_SET           = "set";
string CONS_SETTINGS_LIST_ADD      = "list_add";
string CONS_SETTINGS_LIST_REMOVE   = "list_remove";

string CONS_MSG_ACL_QUERY          = "acl_query";
string CONS_MSG_ACL_RESULT         = "acl_result";

/* ---------- Identity (edit these per plugin) ---------- */
string  PLUGIN_CONTEXT   = "core_template";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Template";
integer PLUGIN_SN        = 0;
/* Minimum ACL required to open this plugin’s UI at all.
   Authoritative ACL levels:
     -1 BLACKLIST, 0 NOACCESS, 1 PUBLIC, 2 OWNED, 3 TRUSTEE, 4 UNOWNED, 5 PRIMARY_OWNER
   Example: allow 1..5 (public and up) by default. Change as needed. */
integer PLUGIN_MIN_ACL   = 1;

/* ---------- ACL allowlist for this plugin (optional refinement) ----------
   By default we accept anything >= PLUGIN_MIN_ACL. You can narrow it here. */
integer ALLOW_BLACKLIST     = FALSE; // -1
integer ALLOW_NOACCESS      = FALSE; // 0
integer ALLOW_PUBLIC        = TRUE;  // 1
integer ALLOW_OWNED         = TRUE;  // 2
integer ALLOW_TRUSTEE       = TRUE;  // 3
integer ALLOW_UNOWNED       = TRUE;  // 4
integer ALLOW_PRIMARY_OWNER = TRUE;  // 5

/* ---------- UI/session state ---------- */
integer DIALOG_TIMEOUT_SEC = 180;

key     g_user      = NULL_KEY; // current operator (this session)
integer g_listen    = 0;
integer g_menu_chan = 0;
string  g_ctx       = "";       // "main", or plugin-specific
integer g_acl_pending = FALSE;

/* ========================== Helpers ========================== */
integer json_has(string j, list path) { return (llJsonGetValue(j, path) != JSON_INVALID); }

integer logd(string s) {
    if (DEBUG) llOwnerSay("[TEMPLATE] " + s);
    return 0;
}

/* ----- Registration & soft reset ----- */
integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  (string)PLUGIN_MIN_ACL);
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

/* ----- Settings (optional; template ready) ----- */
integer request_settings_get() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], CONS_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    return 0;
}

/* ----- ACL ----- */
integer allow_level(integer lvl) {
    if (lvl == -1 && ALLOW_BLACKLIST) return TRUE;
    if (lvl ==  0 && ALLOW_NOACCESS) return TRUE;
    if (lvl ==  1 && ALLOW_PUBLIC) return TRUE;
    if (lvl ==  2 && ALLOW_OWNED) return TRUE;
    if (lvl ==  3 && ALLOW_TRUSTEE) return TRUE;
    if (lvl ==  4 && ALLOW_UNOWNED) return TRUE;
    if (lvl ==  5 && ALLOW_PRIMARY_OWNER) return TRUE;
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

integer begin_dialog(key user, string ctx, string body, list buttons) {
    reset_listen();
    g_user = user;
    g_ctx  = ctx;

    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen    = llListen(g_menu_chan, "", g_user, "");

    while ((llGetListLength(buttons) % 3) != 0) buttons += " ";

    llDialog(g_user, body, buttons, g_menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}

/* ----- UI content (customize per plugin) ----- */
integer show_main_menu(key user) {
    // Placeholder menu: Back centered, two example buttons
    string msg = "Template plugin.\nReplace this message and buttons with your UI.";
    list btns = ["~", "Back", "~", "Do A", "Do B"];
    begin_dialog(user, "main", msg, btns);
    logd("Main menu → " + (string)user + " chan=" + (string)g_menu_chan);
    return 0;
}

/* =========================== Events ========================== */
default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_plugin();
        // If you need settings for initial state, uncomment:
        // request_settings_get();

        g_user = NULL_KEY;
        reset_listen();
        g_ctx = "";
        llSetTimerEvent(0.0);

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

        /* Kernel: “register_now” for THIS script */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        /* (Optional) Settings sync intake */
        if (num == K_SETTINGS_SYNC) {
            // string kv = llJsonGetValue(msg, ["kv"]);
            // apply your settings if needed
            return;
        }

        /* ACL result */
        if (num == AUTH_RESULT_NUM) {
            if (!g_acl_pending) return;
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != CONS_MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;
            if (!json_has(msg, ["level"])) return;

            key av = (key)llJsonGetValue(msg, ["avatar"]);
            if (av != g_user) return;

            integer level = (integer)llJsonGetValue(msg, ["level"]);
            g_acl_pending = FALSE;

            if (level >= PLUGIN_MIN_ACL && allow_level(level)) {
                show_main_menu(g_user);
            } else {
                llRegionSayTo(g_user, 0, "Access denied.");
                // Return to root UI
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

        /* UI: start this plugin */
        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    g_user = id;
                    request_acl(g_user);
                }
            }
            return;
        }
    }

    /* Dialog handler */
    listen(integer chan, string name, key id, string message) {
        if (chan != g_menu_chan) return;
        if (id != g_user) return;

        if (message == "Back") {
            string r = llList2Json(JSON_OBJECT, []);
            r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
            r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);

            reset_listen();
            g_user = NULL_KEY;
            g_ctx = "";
            llSetTimerEvent(0.0);
            return;
        }

        /* Example button actions (add real logic): */
        if (g_ctx == "main") {
            if (message == "Do A") {
                // (Optional) per-button ACL re-check via request_acl(g_user)
                llRegionSayTo(g_user, 0, "You pressed Do A.");
                show_main_menu(g_user);
                return;
            }
            if (message == "Do B") {
                llRegionSayTo(g_user, 0, "You pressed Do B.");
                show_main_menu(g_user);
                return;
            }
        }

        // Fallback
        show_main_menu(g_user);
    }

    /* Timeout closes dialog + session */
    timer() {
        reset_listen();
        g_user = NULL_KEY;
        g_ctx = "";
        llSetTimerEvent(0.0);
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[TEMPLATE] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
