// =============================================================
// PLUGIN: ds_collar_plugin_locking.lsl  (with ACL gate)
// PURPOSE: Single, tidy menu with Back + Lock/Unlock toggle.
//          - Local UI update only (no re-register on toggle)
//          - Applies/clears RLV, persists to settings (JSON)
//          - Heartbeat + soft-reset safe
//          - AUTH ACL check (query/result) before UI
// LSL-SAFE: No ternaries used
// =============================================================

integer DEBUG = TRUE;

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY   = 500; // Kernel → Plugins: {"type":"register_now","script":"<name>"}
integer K_PLUGIN_REG_REPLY   = 501; // Plugins → Kernel: {"type":"register",...}
integer K_PLUGIN_SOFT_RESET  = 504; // Plugins → Kernel: {"type":"plugin_soft_reset","context":...}

integer K_PLUGIN_PING        = 650; // Kernel → Plugins: {"type":"plugin_ping","context":...}
integer K_PLUGIN_PONG        = 651; // Plugins → Kernel: {"type":"plugin_pong","context":...}

integer K_SETTINGS_QUERY     = 800; // Plugin ↔ Settings (JSON)
integer K_SETTINGS_SYNC      = 870; // Settings → Plugin  (JSON)

integer AUTH_QUERY_NUM       = 700; // → Auth : {"type":"acl_query","avatar":"<key>"}
integer AUTH_RESULT_NUM      = 710; // ← Auth : {"type":"acl_result","avatar":"<key>","level":"<int>"}

integer K_PLUGIN_START       = 900; // UI → Plugins   : {"type":"plugin_start","context":...}
integer K_PLUGIN_RETURN_NUM  = 901; // Plugins → UI   : {"type":"plugin_return","context":"core_root"}

/* ---------- Shared “magic words” ---------- */
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

string CONS_ACL_QUERY              = "acl_query";
string CONS_ACL_RESULT             = "acl_result";

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT = "core_lock";  // keep legacy mapping
string  ROOT_CONTEXT   = "core_root";
string  PLUGIN_LABEL   = "Locking";    // static label in root UI
integer PLUGIN_SN      = 0;
integer PLUGIN_MIN_ACL = 1;            // legacy min (kept, but AUTH list rules access)

/* ---------- Authoritative ACL levels ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Which ACL levels can use this plugin ---------- */
/* Change this list if you want to include/exclude levels.
   Current: OWNED, TRUSTEE, UNOWNED, PRIMARY (exclude NOACCESS and PUBLIC). */
list ALLOWED_ACL = [3,4,5];

/* ---------- Settings keys ---------- */
string KEY_LOCKED = "locked";

/* ---------- Optional prim names for visuals ---------- */
string PRIM_LOCKED   = "locked";
string PRIM_UNLOCKED = "unlocked";

/* ---------- Session & ACL state ---------- */
integer g_locked        = FALSE;   // 0=unlocked, 1=locked
key     g_menu_user     = NULL_KEY;
integer g_listen_handle = 0;
integer g_menu_chan     = 0;
integer g_menu_timeout  = 180;

integer g_acl_pending   = FALSE;
integer g_acl_level     = -9999;
key     g_acl_avatar    = NULL_KEY;

/* ========================== Helpers ========================== */
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer logd(string s) { if (DEBUG) llOwnerSay("[LOCKING] " + s); return 0; }

integer list_has_int(list L, integer v) {
    integer i = 0;
    integer n = llGetListLength(L);
    while (i < n) {
        if (llList2Integer(L, i) == v) return TRUE;
        i += 1;
    }
    return FALSE;
}

register_once() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered with kernel. Label=" + PLUGIN_LABEL);
}

notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
}

request_settings_get() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], CONS_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
}

persist_locked(integer value01) {
    if (value01 != 0) value01 = 1;
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],  CONS_SETTINGS_SET);
    j = llJsonSetValue(j, ["key"],   KEY_LOCKED);
    j = llJsonSetValue(j, ["value"], (string)value01);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    logd("Persisted locked=" + (string)value01);
}

/* ---------- AUTH ---------- */
request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);

    g_acl_pending = TRUE;
    g_acl_avatar  = av;
    g_acl_level   = -9999;
    logd("ACL query → " + (string)av);
}

/* ---------- Visuals ---------- */
set_lock_visibility(integer lock_state) {
    integer total = llGetNumberOfPrims();
    integer i = 1;
    while (i <= total) {
        string pname = llGetLinkName(i);
        if (pname == PRIM_LOCKED) {
            if (lock_state) llSetLinkAlpha(i, 1.0, ALL_SIDES);
            else            llSetLinkAlpha(i, 0.0, ALL_SIDES);
        } else if (pname == PRIM_UNLOCKED) {
            if (lock_state) llSetLinkAlpha(i, 0.0, ALL_SIDES);
            else            llSetLinkAlpha(i, 1.0, ALL_SIDES);
        }
        i += 1;
    }
}

/* ---------- RLV ---------- */
apply_rlv(integer lock_state) {
    if (lock_state) {
        llOwnerSay("@detach=n");
        logd("RLV: @detach=n");
    } else {
        llOwnerSay("@detach=y");
        logd("RLV: @detach=y");
    }
}

/* ---------- Core state change (no re-register) ---------- */
set_lock_state(integer new_state, integer do_persist, integer refresh_local_menu) {
    if (new_state != 0) new_state = 1;
    g_locked = new_state;

    set_lock_visibility(g_locked);
    apply_rlv(g_locked);

    if (do_persist) {
        persist_locked(g_locked);
    }

    if (refresh_local_menu && g_menu_user != NULL_KEY) {
        show_locking_menu(g_menu_user);
    }

    logd("State → locked=" + (string)g_locked);
}

/* ---------- Settings intake ---------- */
apply_settings_sync(string msg) {
    if (!json_has(msg, ["type"])) return;
    if (llJsonGetValue(msg, ["type"]) != CONS_SETTINGS_SYNC) return;
    if (!json_has(msg, ["kv"])) return;

    string kv = llJsonGetValue(msg, ["kv"]);
    string v  = llJsonGetValue(kv, [ KEY_LOCKED ]);
    if (v == JSON_INVALID) return;

    integer want = (integer)v;
    if (want != 0) want = 1;

    if (g_locked != want) {
        set_lock_state(want, FALSE, TRUE);
        logd("Settings sync applied: locked=" + (string)want);
    }
}

/* ---------- Menu ---------- */
show_locking_menu(key user) {
    list buttons;
    string action = "Lock";
    if (g_locked) action = "Unlock";

    buttons = [ "Back", action, "~" ];

    if (g_listen_handle) llListenRemove(g_listen_handle);
    g_menu_chan     = -100000 - (integer)llFrand(1000000.0);
    g_menu_user     = user;
    g_listen_handle = llListen(g_menu_chan, "", user, "");

    string msg = "Collar is currently ";
    if (g_locked) msg += "LOCKED.\nTap Unlock to allow detach.";
    else          msg += "UNLOCKED.\nTap Lock to prevent detach.";

    llDialog(user, msg, buttons, g_menu_chan);
    llSetTimerEvent((float)g_menu_timeout);

    logd("Menu → " + (string)user + " action=" + action + " chan=" + (string)g_menu_chan);
}

cleanup_session() {
    if (g_listen_handle) llListenRemove(g_listen_handle);
    g_listen_handle = 0;
    g_menu_user     = NULL_KEY;
    g_menu_chan     = 0;
    llSetTimerEvent(0.0);
}

/* =========================== Events ========================== */
default
{
    state_entry() {
        cleanup_session();
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_once();
        request_settings_get();

        set_lock_visibility(g_locked);
        apply_rlv(g_locked);

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
                    register_once();
                }
            }
            return;
        }

        /* Settings sync */
        if (num == K_SETTINGS_SYNC) {
            apply_settings_sync(msg);
            return;
        }

        /* AUTH result */
        if (num == AUTH_RESULT_NUM) {
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != CONS_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;
            key who = (key)llJsonGetValue(msg, ["avatar"]);
            if (who != g_acl_avatar) return;
            if (!json_has(msg, ["level"])) return;

            g_acl_pending = FALSE;
            g_acl_level   = (integer)llJsonGetValue(msg, ["level"]);

            if (list_has_int(ALLOWED_ACL, g_acl_level)) {
                /* Authorized → open menu */
                show_locking_menu(g_acl_avatar);
            } else {
                llRegionSayTo(g_acl_avatar, 0, "Access denied.");
                /* Bounce back to root */
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_acl_avatar);
                cleanup_session();
            }
            return;
        }

        /* UI: start → request ACL first */
        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    request_acl(id);
                }
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string pressed) {
        if (chan != g_menu_chan) return;
        if (id != g_menu_user)   return;

        /* Per-button ACL recheck (defense-in-depth) */
        if (!list_has_int(ALLOWED_ACL, g_acl_level)) {
            llRegionSayTo(id, 0, "Access denied.");
            cleanup_session();
            return;
        }

        if (pressed == "Back") {
            string r = llList2Json(JSON_OBJECT, []);
            r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
            r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_menu_user);
            cleanup_session();
            return;
        }

        if (pressed == "Lock") {
            set_lock_state(TRUE, TRUE, TRUE);
            return;
        }

        if (pressed == "Unlock") {
            set_lock_state(FALSE, TRUE, TRUE);
            return;
        }
    }

    timer() {
        cleanup_session();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[LOCKING] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
