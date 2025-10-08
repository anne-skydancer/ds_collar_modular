// =============================================================
// PLUGIN: ds_collar_plugin_locking.lsl  (with ACL gate)
// PURPOSE: Single, tidy menu with Back + Lock/Unlock toggle.
//          - Local UI update only (no re-register on toggle)
//          - Applies/clears RLV, persists to settings (JSON)
//          - Heartbeat + soft-reset safe
//          - AUTH ACL check (query/result) before UI
// LSL-SAFE: No ternaries used
// NAMING: PascalCase globals, ALL_CAPS constants, snake_case locals
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

/* ---------- Shared "magic words" ---------- */
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
integer Locked        = FALSE;   // 0=unlocked, 1=locked
key     MenuUser     = NULL_KEY;
integer ListenHandle = 0;
integer MenuChan     = 0;
integer MenuTimeout  = 180;

integer AclPending   = FALSE;
integer AclLevel     = -9999;
key     AclAvatar    = NULL_KEY;

/* ========================== Helpers ========================== */
integer json_has(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

integer logd(string msg_str) { 
    if (DEBUG) llOwnerSay("[LOCKING] " + msg_str); 
    return 0; 
}

integer list_has_int(list search_list, integer value) {
    integer i = 0;
    integer list_length = llGetListLength(search_list);
    while (i < list_length) {
        if (llList2Integer(search_list, i) == value) return TRUE;
        i += 1;
    }
    return FALSE;
}

register_once() {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"],     CONS_TYPE_REGISTER);
    json_msg = llJsonSetValue(json_msg, ["sn"],       (string)PLUGIN_SN);
    json_msg = llJsonSetValue(json_msg, ["label"],    PLUGIN_LABEL);
    json_msg = llJsonSetValue(json_msg, ["min_acl"],  (string)PLUGIN_MIN_ACL);
    json_msg = llJsonSetValue(json_msg, ["context"],  PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, json_msg, NULL_KEY);
    logd("Registered with kernel. Label=" + PLUGIN_LABEL);
}

notify_soft_reset() {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    json_msg = llJsonSetValue(json_msg, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, json_msg, NULL_KEY);
}

request_settings_get() {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"], CONS_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, json_msg, NULL_KEY);
}

persist_locked(integer lock_value) {
    if (lock_value != 0) lock_value = 1;
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"],  CONS_SETTINGS_SET);
    json_msg = llJsonSetValue(json_msg, ["key"],   KEY_LOCKED);
    json_msg = llJsonSetValue(json_msg, ["value"], (string)lock_value);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, json_msg, NULL_KEY);
    logd("Persisted locked=" + (string)lock_value);
}

/* ---------- AUTH ---------- */
request_acl(key avatar_key) {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"],   CONS_ACL_QUERY);
    json_msg = llJsonSetValue(json_msg, ["avatar"], (string)avatar_key);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, json_msg, NULL_KEY);

    AclPending = TRUE;
    AclAvatar  = avatar_key;
    AclLevel   = -9999;
    logd("ACL query → " + (string)avatar_key);
}

/* ---------- Visuals ---------- */
set_lock_visibility(integer lock_state) {
    integer prim_count = llGetNumberOfPrims();
    integer i = 1;
    while (i <= prim_count) {
        string prim_name = llGetLinkName(i);
        if (prim_name == PRIM_LOCKED) {
            if (lock_state) llSetLinkAlpha(i, 1.0, ALL_SIDES);
            else            llSetLinkAlpha(i, 0.0, ALL_SIDES);
        } else if (prim_name == PRIM_UNLOCKED) {
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
    Locked = new_state;

    set_lock_visibility(Locked);
    apply_rlv(Locked);

    if (do_persist) {
        persist_locked(Locked);
    }

    if (refresh_local_menu && MenuUser != NULL_KEY) {
        show_locking_menu(MenuUser);
    }

    logd("State → locked=" + (string)Locked);
}

/* ---------- Settings intake ---------- */
apply_settings_sync(string msg) {
    if (!json_has(msg, ["type"])) return;
    if (llJsonGetValue(msg, ["type"]) != CONS_SETTINGS_SYNC) return;
    if (!json_has(msg, ["kv"])) return;

    string key_values = llJsonGetValue(msg, ["kv"]);
    string value_str  = llJsonGetValue(key_values, [ KEY_LOCKED ]);
    if (value_str == JSON_INVALID) return;

    integer desired_state = (integer)value_str;
    if (desired_state != 0) desired_state = 1;

    if (Locked != desired_state) {
        set_lock_state(desired_state, FALSE, TRUE);
        logd("Settings sync applied: locked=" + (string)desired_state);
    }
}

/* ---------- Menu ---------- */
show_locking_menu(key user) {
    list buttons;
    string action = "Lock";
    if (Locked) action = "Unlock";

    buttons = [ "Back", action, "~" ];

    if (ListenHandle) llListenRemove(ListenHandle);
    MenuChan     = -100000 - (integer)llFrand(1000000.0);
    MenuUser     = user;
    ListenHandle = llListen(MenuChan, "", user, "");

    string msg = "Collar is currently ";
    if (Locked) msg += "LOCKED.\nTap Unlock to allow detach.";
    else          msg += "UNLOCKED.\nTap Lock to prevent detach.";

    llDialog(user, msg, buttons, MenuChan);
    llSetTimerEvent((float)MenuTimeout);

    logd("Menu → " + (string)user + " action=" + action + " chan=" + (string)MenuChan);
}

cleanup_session() {
    if (ListenHandle) llListenRemove(ListenHandle);
    ListenHandle = 0;
    MenuUser     = NULL_KEY;
    MenuChan     = 0;
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

        set_lock_visibility(Locked);
        apply_rlv(Locked);

        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* Heartbeat */
        if (num == K_PLUGIN_PING) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_PING) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    string json_pong = llList2Json(JSON_OBJECT, []);
                    json_pong = llJsonSetValue(json_pong, ["type"],    CONS_TYPE_PLUGIN_PONG);
                    json_pong = llJsonSetValue(json_pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, json_pong, NULL_KEY);
                }
            }
            return;
        }

        /* Kernel: "register_now" for THIS script */
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
            key avatar_key = (key)llJsonGetValue(msg, ["avatar"]);
            if (avatar_key != AclAvatar) return;
            if (!json_has(msg, ["level"])) return;

            AclPending = FALSE;
            AclLevel   = (integer)llJsonGetValue(msg, ["level"]);

            if (list_has_int(ALLOWED_ACL, AclLevel)) {
                /* Authorized → open menu */
                show_locking_menu(AclAvatar);
            } else {
                llRegionSayTo(AclAvatar, 0, "Access denied.");
                /* Bounce back to root */
                string json_return = llList2Json(JSON_OBJECT, []);
                json_return = llJsonSetValue(json_return, ["type"],    CONS_TYPE_PLUGIN_RETURN);
                json_return = llJsonSetValue(json_return, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, json_return, AclAvatar);
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
        if (chan != MenuChan) return;
        if (id != MenuUser)   return;

        /* Per-button ACL recheck (defense-in-depth) */
        if (!list_has_int(ALLOWED_ACL, AclLevel)) {
            llRegionSayTo(id, 0, "Access denied.");
            cleanup_session();
            return;
        }

        if (pressed == "Back") {
            string json_return = llList2Json(JSON_OBJECT, []);
            json_return = llJsonSetValue(json_return, ["type"],    CONS_TYPE_PLUGIN_RETURN);
            json_return = llJsonSetValue(json_return, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, json_return, MenuUser);
            cleanup_session();
            return;
        }

        if (pressed == "Lock") {
            set_lock_state(TRUE, TRUE, TRUE);
            llRegionSayTo(id, 0, "Collar locked. Detachment prevented.");
            return;
        }

        if (pressed == "Unlock") {
            set_lock_state(FALSE, TRUE, TRUE);
            llRegionSayTo(id, 0, "Collar unlocked. Detachment allowed.");
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
