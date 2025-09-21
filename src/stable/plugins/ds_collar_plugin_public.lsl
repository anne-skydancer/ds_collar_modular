/* =============================================================
   PLUGIN: ds_collar_plugin_public.lsl
   PURPOSE: Manage Public Access (enable/disable) with strict ACL
            - New kernel JSON register + heartbeat + soft-reset
            - Settings JSON key "public_mode" (scalar "0"/"1")
            - Animate/Status-style UI (Back centered)
            - Private dialog channel + safe listens
   ACL: Allowed levels = TRUSTEE(3), UNOWNED(4), PRIMARY_OWNER(5)
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY   = 500; // Kernel → Plugins: {"type":"register_now","script":"<name>"}
integer K_PLUGIN_REG_REPLY   = 501; // Plugins → Kernel: {"type":"register",...}
integer K_PLUGIN_SOFT_RESET  = 504; // Plugins → Kernel: {"type":"plugin_soft_reset","context":...}

integer K_PLUGIN_PING        = 650; // Kernel → Plugins: {"type":"plugin_ping","context":...}
integer K_PLUGIN_PONG        = 651; // Plugins → Kernel: {"type":"plugin_pong","context":...}

integer AUTH_QUERY_NUM       = 700; // to Auth  : {"type":"acl_query","avatar":"<key>"}
integer AUTH_RESULT_NUM      = 710; // from Auth: {"type":"acl_result","avatar":"<key>","level":"<int>"}

integer K_SETTINGS_QUERY     = 800; // Plugin ↔ Settings (JSON)
integer K_SETTINGS_SYNC      = 870; // Settings → Plugin  (JSON)

integer K_PLUGIN_START       = 900; // UI → Plugin: {"type":"plugin_start","context":...}
integer K_PLUGIN_RETURN_NUM  = 901; // Plugin → UI : {"type":"plugin_return","context":"core_root"}

/* ---------- Shared magic words ---------- */
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

string CONS_MSG_ACL_QUERY          = "acl_query";
string CONS_MSG_ACL_RESULT         = "acl_result";

/* ---------- ACL levels (authoritative map) ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0; /* TPE: no wearer access */
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT   = "core_public";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Public";
integer PLUGIN_SN        = 0;
integer PLUGIN_MIN_ACL   = 3;   /* kernel-side filter: 3+ covers 3,4,5 */

/* ---------- Settings ---------- */
string KEY_PUBLIC_MODE   = "public_mode";

/* ---------- UI/session state ---------- */
integer DIALOG_TIMEOUT_SEC = 180;

key     g_user       = NULL_KEY;  /* current operator (active session) */
integer g_listen     = 0;
integer g_menu_chan  = 0;
string  g_ctx        = "";        /* "main" */

integer g_public_access = FALSE;  /* 0/1 state */

integer g_acl_pending = FALSE;

/* ========================== Helpers ========================== */
integer json_has(string j, list path) { return (llJsonGetValue(j, path) != JSON_INVALID); }

integer logd(string s) { if (DEBUG) llOwnerSay("[PUBLIC] " + s); return 0; }

/* ---------- Register / Soft reset ---------- */
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

/* ---------- Settings I/O ---------- */
integer request_settings_get() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], CONS_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    logd("Requested settings_get.");
    return 0;
}

integer persist_public(integer value01) {
    if (value01 != 0) value01 = 1;
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],  CONS_SETTINGS_SET);
    j = llJsonSetValue(j, ["key"],   KEY_PUBLIC_MODE);
    j = llJsonSetValue(j, ["value"], (string)value01);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    logd("Persisted public_mode=" + (string)value01);
    return 0;
}

/* ---------- ACL ---------- */
integer acl_is_allowed(integer level) {
    if (level == ACL_TRUSTEE)       return TRUE;  /* 3 */
    if (level == ACL_UNOWNED)       return TRUE;  /* 4 */
    if (level == ACL_PRIMARY_OWNER) return TRUE;  /* 5 */
    return FALSE; /* deny 0,1,2 */
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

/* ---------- UI plumbing ---------- */
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

/* ---------- UI content ---------- */
integer show_main_menu(key user) {
    list btns = ["~","Back","~"];
    if (g_public_access) btns += ["Disable"];
    else                 btns += ["Enable"];

    string msg = "Public access is currently ";
    if (g_public_access) msg += "ENABLED.\nDisable public access?";
    else                 msg += "DISABLED.\nEnable public access?";

    begin_dialog(user, "main", msg, btns);
    logd("Menu → " + (string)user + " chan=" + (string)g_menu_chan);
    return 0;
}

/* ---------- Settings intake ---------- */
integer apply_settings_sync(string payload) {
    if (!json_has(payload, ["type"])) return 0;
    if (llJsonGetValue(payload, ["type"]) != CONS_SETTINGS_SYNC) return 0;
    if (!json_has(payload, ["kv"])) return 0;

    string kv = llJsonGetValue(payload, ["kv"]);
    string v  = llJsonGetValue(kv, [ KEY_PUBLIC_MODE ]);
    if (v == JSON_INVALID) return 0;

    integer want = (integer)v;
    if (want != 0) want = 1;

    if (g_public_access != want) {
        g_public_access = want;
        logd("Settings sync applied: public=" + (string)g_public_access);
    }
    return 0;
}

/* =========================== Events ========================== */
default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));

        notify_soft_reset();
        register_plugin();
        request_settings_get();

        g_user = NULL_KEY;
        reset_listen();
        g_ctx = "";
        g_acl_pending = FALSE;
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

        /* Kernel: re-register request for this script */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        /* Settings sync */
        if (num == K_SETTINGS_SYNC) {
            apply_settings_sync(msg);
            return;
        }

        /* ACL result gate */
        if (num == AUTH_RESULT_NUM) {
            if (!g_acl_pending) return;
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != CONS_MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;
            if (!json_has(msg, ["level"])) return;

            key who = (key)llJsonGetValue(msg, ["avatar"]);
            integer lvl = (integer)llJsonGetValue(msg, ["level"]);

            if (who != g_user) return;

            g_acl_pending = FALSE;

            if (acl_is_allowed(lvl)) {
                show_main_menu(g_user);
            } else {
                llRegionSayTo(g_user, 0, "Access denied.");
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);

                reset_listen();
                g_user = NULL_KEY;
                g_ctx = "";
                llSetTimerEvent(0.0);
            }
            return;
        }

        /* UI start */
        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    g_user = id;
                    request_acl(g_user); /* defer UI until Auth says OK */
                }
            }
            return;
        }
    }

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

        if (g_ctx == "main") {
            if (message == "Enable") {
                g_public_access = TRUE;
                persist_public(g_public_access);
                show_main_menu(g_user);
                return;
            }
            if (message == "Disable") {
                g_public_access = FALSE;
                persist_public(g_public_access);
                show_main_menu(g_user);
                return;
            }
        }

        /* Fallback: redraw */
        show_main_menu(g_user);
    }

    timer() {
        /* No multi-user session table here; simply close on timeout */
        reset_listen();
        g_user = NULL_KEY;
        g_ctx = "";
        llSetTimerEvent(0.0);
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[PUBLIC] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
