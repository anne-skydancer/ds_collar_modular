/* =============================================================
   PLUGIN: ds_collar_trustees.lsl (New Kernel ABI, JSON)
   PURPOSE: Manage Trustees (add/remove)
   BASED ON: ds_collar_plugin_boilerplate.lsl
   DATE: 2025-08-13
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY   = 500;  // {"type":"register_now","script":...}
integer K_PLUGIN_REG_REPLY   = 501;  // {"type":"register", ...}
integer K_PLUGIN_SOFT_RESET  = 504;  // {"type":"plugin_soft_reset",...}

integer K_PLUGIN_PING        = 650;  // {"type":"plugin_ping","context":...}
integer K_PLUGIN_PONG        = 651;  // {"type":"plugin_pong","context":...}

integer AUTH_QUERY_NUM       = 700;  // {"type":"acl_query","avatar":...}
integer AUTH_RESULT_NUM      = 710;  // {"type":"acl_result","avatar":...,"level":...}

integer K_SETTINGS_QUERY     = 800;  // (optional) settings get
integer K_SETTINGS_SYNC      = 870;  // settings sync (JSON)

integer K_PLUGIN_START       = 900;  // {"type":"plugin_start","context":...}
integer K_PLUGIN_RETURN_NUM  = 901;  // {"type":"plugin_return","context":"core_root"}

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

/* Settings protocol (JSON) */
string CONS_SETTINGS_SYNC          = "settings_sync";  // in/out
string CONS_SETTINGS_NS_OWNER      = "owner";          // same NS as Owner plugin

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT   = "core_trustees";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Trustees";
integer PLUGIN_SN        = 0;

/* ---------- ACL levels (authoritative mapping) ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2; // wearer (owned)
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4; // wearer (unowned)
integer ACL_PRIMARY_OWNER = 5;

/* Who can OPEN the plugin menu (mirror of canonical behavior: Owner or Unowned wearer) */
list ALLOWED_ACL_LEVELS = [ACL_UNOWNED, ACL_PRIMARY_OWNER];

/* ---------- UI / labels ---------- */
integer DIALOG_TIMEOUT_SEC = 180;
string  BTN_BACK           = "Back";
string  BTN_TRUSTEE_ADD    = "Trustee +";
string  BTN_TRUSTEE_REMOVE = "Trustee -";

/* ---------- Session plumbing ---------- */
key     g_user      = NULL_KEY;
integer g_listen    = 0;
integer g_menu_chan = 0;

/* Gate state */
integer g_acl_pending = FALSE;
integer g_acl_level   = ACL_NOACCESS;

/* ---------- Data mirror ---------- */
key   collar_owner = NULL_KEY;
list  collar_trustees = [];
list  collar_trustee_honorifics = [];
integer MAX_TRUSTEES = 4;

/* ---------- Flow/session state ---------- */
string  s_context = "";   // "menu","add_scan","add_pick","add_honor","remove_pick"
string  s_param1  = "";   // generic (e.g., selected key)
string  s_param2  = "";   // generic
string  s_data    = "";   // csv payload (e.g., candidate keys)

/* ========================== Helpers ========================== */
integer json_has(string j, list path) {
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return FALSE;
    return TRUE;
}
integer logd(string s) { if (DEBUG) llOwnerSay("[TRUSTEES] " + s); return 0; }

list trustee_honorifics() { return ["Sir","Miss","Milord","Milady"]; }

string name_or_key(key k) {
    string n = llKey2Name(k);
    if (n == "") n = (string)k;
    return n;
}

/* ---------- Kernel/Register/Soft reset ---------- */
integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],      (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],   PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"], "0");
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered.");
    return 0;
}
integer notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    return 0;
}

/* ---------- ACL ---------- */
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

/* ---------- Settings ---------- */
/* Pull values from inbound settings JSON (kernel → plugins) */
integer ingest_settings(string j) {
    if (json_has(j, ["ns"]) && llJsonGetValue(j, ["ns"]) != CONS_SETTINGS_NS_OWNER) return 0;

    if (json_has(j, ["owner"]))        collar_owner = (key)llJsonGetValue(j, ["owner"]);
    if (json_has(j, ["trustees"]))     collar_trustees = llJson2List(llJsonGetValue(j, ["trustees"]));
    if (json_has(j, ["trustees_hon"])) collar_trustee_honorifics = llJson2List(llJsonGetValue(j, ["trustees_hon"]));

    return 0;
}

/* Push trustees only (kernel should merge per-key within NS) */
integer push_trustees() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],          CONS_SETTINGS_SYNC);
    j = llJsonSetValue(j, ["ns"],            CONS_SETTINGS_NS_OWNER);
    j = llJsonSetValue(j, ["trustees"],      llList2Json(JSON_ARRAY, collar_trustees));
    j = llJsonSetValue(j, ["trustees_hon"],  llList2Json(JSON_ARRAY, collar_trustee_honorifics));
    llMessageLinked(LINK_SET, K_SETTINGS_SYNC, j, NULL_KEY);
    logd("Trustees saved (" + (string)llGetListLength(collar_trustees) + ").");
    return 0;
}

/* ---------- UI plumbing ---------- */
integer reset_listen() {
    if (g_listen) llListenRemove(g_listen);
    g_listen = 0;
    g_menu_chan = 0;
    return 0;
}
integer dialog_to(key who, string body, list buttons) {
    reset_listen();
    while ((llGetListLength(buttons) % 3) != 0) buttons += " ";
    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen    = llListen(g_menu_chan, "", who, "");
    llDialog(who, body, buttons, g_menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}
integer ui_return_root(key toUser) {
    string r = llList2Json(JSON_OBJECT, []);
    r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, toUser);
    return 0;
}

/* ---------- UI content ---------- */
list base_menu_buttons() {
    list btns = [];
    if (llGetListLength(collar_trustees) < MAX_TRUSTEES) btns += BTN_TRUSTEE_ADD; else btns += "~";
    if (llGetListLength(collar_trustees) > 0)            btns += BTN_TRUSTEE_REMOVE; else btns += "~";
    btns += BTN_BACK;
    return btns;
}

string trustee_list_text() {
    string out = "";
    integer i;
    for (i=0; i<llGetListLength(collar_trustees); ++i) {
        string nm = name_or_key((key)llList2String(collar_trustees, i));
        string hon = "";
        if (i < llGetListLength(collar_trustee_honorifics)) hon = llList2String(collar_trustee_honorifics, i);
        out += (string)(i+1) + ". " + nm;
        if (hon != "") out += " (" + hon + ")";
        out += "\n";
    }
    if (out == "") out = "(none)\n";
    return out;
}

integer show_menu(key user) {
    s_context = "menu";
    g_user = user;

    string owner_line = "(none)";
    if (collar_owner != NULL_KEY) owner_line = name_or_key(collar_owner);

    string body = "Trustee Management\n"
                  + "Owner  : " + owner_line + "\n"
                  + "Max    : " + (string)MAX_TRUSTEES + "\n"
                  + "Current:\n" + trustee_list_text();

    list btns = base_menu_buttons();
    dialog_to(user, body, btns);
    logd("Menu → " + (string)user);
    return 0;
}

/* ---------- Builders ---------- */
list build_number_buttons(integer count) {
    list out = [];
    integer i;
    for (i=0; i<count; ++i) out += (string)(i+1);
    return out;
}

/* =============================================================
   EVENTS
   ============================================================= */
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

        /* Request current settings */
        string q = llList2Json(JSON_OBJECT, []);
        q = llJsonSetValue(q, ["type"],   CONS_SETTINGS_SYNC);
        q = llJsonSetValue(q, ["ns"],     CONS_SETTINGS_NS_OWNER);
        q = llJsonSetValue(q, ["action"], "get");
        llMessageLinked(LINK_SET, K_SETTINGS_QUERY, q, NULL_KEY);

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

        /* Re-register request */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        /* UI start → ACL check, then open */
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
                ui_return_root(g_user);
                g_user = NULL_KEY;
                reset_listen();
                llSetTimerEvent(0.0);
            }
            return;
        }

        /* Settings sync */
        if (num == K_SETTINGS_SYNC) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_SETTINGS_SYNC) {
                ingest_settings(msg);
            }
            return;
        }
    }

    /* ---------- Dialog / UI ---------- */
    listen(integer chan, string name, key id, string message) {
        if (chan != g_menu_chan) return;
        if (id != g_user) return;

        /* Root nav */
        if (message == BTN_BACK) {
            ui_return_root(id);
            reset_listen();
            g_user = NULL_KEY;
            s_context = "";
            s_param1 = s_param2 = s_data = "";
            llSetTimerEvent(0.0);
            return;
        }

        /* MENU */
        if (s_context == "menu") {
            if (message == BTN_TRUSTEE_ADD) {
                if (llGetListLength(collar_trustees) >= MAX_TRUSTEES) { show_menu(g_user); return; }
                s_context = "add_scan";
                s_param1 = s_param2 = s_data = "";
                llSensor("", NULL_KEY, AGENT, 20.0, PI * 2.0);
                return;
            }
            if (message == BTN_TRUSTEE_REMOVE) {
                if (llGetListLength(collar_trustees) == 0) {
                    dialog_to(g_user, "There are no trustees to remove.", ["OK"]);
                    return;
                }
                /* Build numbered remove list */
                list names = [];
                integer i;
                for (i=0; i<llGetListLength(collar_trustees); ++i) {
                    names += name_or_key((key)llList2String(collar_trustees, i));
                }
                list btns = build_number_buttons(llGetListLength(names));
                while (llGetListLength(btns) % 3) btns += " ";
                s_context = "remove_pick";
                s_data = llDumpList2String(collar_trustees, ","); // keys snapshot
                dialog_to(g_user, "Select trustee to remove:\n" , btns);
                /* Show the numbered list as chat for clarity */
                integer ii;
                string lines = "";
                for (ii=0; ii<llGetListLength(names); ++ii) {
                    lines += (string)(ii+1) + ". " + llList2String(names, ii) + "\n";
                }
                llRegionSayTo(g_user, 0, lines);
                return;
            }
            /* default → redraw */
            show_menu(g_user);
            return;
        }

        /* ADD: pick candidate from numbers */
        if (s_context == "add_pick") {
            list keys = llParseString2List(s_data, [","], []);
            integer idx = (integer)message - 1;
            if (idx >= 0 && idx < llGetListLength(keys)) {
                key cand = (key)llList2String(keys, idx);
                s_param1 = (string)cand;

                /* Choose honorific (numbered) */
                list honors = trustee_honorifics();
                list btns = build_number_buttons(llGetListLength(honors));
                while (llGetListLength(btns) % 3) btns += " ";
                s_context = "add_honor";
                dialog_to(g_user, "Select an honorific for " + name_or_key(cand) + ":\n"
                                  + "1. Sir\n2. Miss\n3. Milord\n4. Milady\n", btns);
                return;
            }
            show_menu(g_user);
            return;
        }

        /* ADD: honorific chosen */
        if (s_context == "add_honor") {
            list honors = trustee_honorifics();
            integer hidx = (integer)message - 1;
            if (hidx >= 0 && hidx < llGetListLength(honors)) {
                key    k   = (key)s_param1;
                string hon = llList2String(honors, hidx);

                /* Guard: capacity & duplicates */
                if (llGetListLength(collar_trustees) >= MAX_TRUSTEES) {
                    dialog_to(g_user, "Trustee list is full.", ["OK"]);
                    s_context = "menu";
                    show_menu(g_user);
                    return;
                }
                if (llListFindList(collar_trustees, [(string)k]) != -1) {
                    dialog_to(g_user, "That avatar is already a trustee.", ["OK"]);
                    s_context = "menu";
                    show_menu(g_user);
                    return;
                }

                collar_trustees += (string)k;
                collar_trustee_honorifics += hon;

                push_trustees();
                dialog_to(g_user, name_or_key(k) + " has been added as trustee (" + hon + ").", ["OK"]);
                s_context = "menu";
                show_menu(g_user);
                return;
            }
            /* bad input → redraw */
            show_menu(g_user);
            return;
        }

        /* REMOVE: pick index */
        if (s_context == "remove_pick") {
            list keys = llParseString2List(s_data, [","], []);
            integer idx = (integer)message - 1;
            if (idx >= 0 && idx < llGetListLength(keys)) {
                collar_trustees = llDeleteSubList(collar_trustees, idx, idx);
                collar_trustee_honorifics = llDeleteSubList(collar_trustee_honorifics, idx, idx);
                push_trustees();
                dialog_to(g_user, "Trustee removed.", ["OK"]);
                s_context = "menu";
                show_menu(g_user);
                return;
            }
            show_menu(g_user);
            return;
        }

        /* fallback */
        show_menu(g_user);
    }

    /* ---------- Proximity scan for candidate selection ---------- */
    sensor(integer n) {
        if (s_context != "add_scan") return;

        list candidates = [];
        integer i;
        for (i=0; i<n; ++i) {
            key k = llDetectedKey(i);
            if (k == g_user)       jump continue;
            if (k == collar_owner) jump continue;
            if (llListFindList(collar_trustees, [(string)k]) != -1) jump continue;
            candidates += (string)k;
            @continue;
        }

        if (llGetListLength(candidates) == 0) {
            dialog_to(g_user, "No valid candidates nearby.", ["OK"]);
            s_context = "menu";
            show_menu(g_user);
            return;
        }

        /* Build numbered chooser */
        list names = [];
        for (i=0; i<llGetListLength(candidates); ++i) names += name_or_key((key)llList2String(candidates, i));
        list btns = build_number_buttons(llGetListLength(names));
        while (llGetListLength(btns) % 3) btns += " ";

        s_context = "add_pick";
        s_data = llDumpList2String(candidates, ",");
        dialog_to(g_user, "Select avatar to add as trustee:\n", btns);

        /* show numbered list in chat for clarity */
        integer ii; string lines = "";
        for (ii=0; ii<llGetListLength(names); ++ii) lines += (string)(ii+1) + ". " + llList2String(names, ii) + "\n";
        llRegionSayTo(g_user, 0, lines);
    }

    no_sensor() {
        if (s_context == "add_scan") {
            dialog_to(g_user, "No one found nearby.", ["OK"]);
            s_context = "menu";
            show_menu(g_user);
        }
    }

    /* ---------- Housekeeping ---------- */
    timer() {
        reset_listen();
        g_user = NULL_KEY;
        s_context = "";
        s_param1 = s_param2 = s_data = "";
        llSetTimerEvent(0.0);
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("Owner changed. Resetting plugin: " + PLUGIN_CONTEXT);
            llResetScript();
        }
    }
}
