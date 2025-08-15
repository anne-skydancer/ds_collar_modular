/* =========================================================================
   PLUGIN: ds_rlv_relay_plugin.lsl
   PURPOSE: Self-contained RLV Relay for DS Collar
   VERSION: Hardened ACL (AUTH-driven) + dynamic Unbind/Safeword button
   ========================================================================= */

integer DEBUG = FALSE;

/* ---------------- ABI Link Numbers ---------------- */
integer K_PLUGIN_REG_QUERY   = 500;
integer K_PLUGIN_REG_REPLY   = 501;
integer K_PLUGIN_SOFT_RESET  = 504;
integer K_PLUGIN_PING        = 650;
integer K_PLUGIN_PONG        = 651;
integer K_PLUGIN_START       = 900;
integer K_PLUGIN_RETURN_NUM  = 901;
integer SOS_MSG_NUM          = 999; /* SOS plugin link channel */

/* ---- AUTH (authoritative ACL) ---- */
integer AUTH_QUERY_NUM       = 700;
integer AUTH_RESULT_NUM      = 710;

/* ---------------- Constants ---------------- */
string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";

string  PLUGIN_CONTEXT = "core_relay";
string  ROOT_CONTEXT   = "core_root";
string  PLUGIN_LABEL   = "RLV Relay";
integer PLUGIN_SN      = 0;

/* ---------- ACL levels (authoritative) ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Allowed ACL levels for this plugin ---------- */
/* Allow owned wearer (2) for Safeword, trustee (3) and owner (5) for Unbind.
   Keep unowned wearer (4) allowed as before. */
list ALLOWED_ACL_LEVELS = [ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

integer in_allowed_levels(integer lvl) {
    if (llListFindList(ALLOWED_ACL_LEVELS, [lvl]) != -1) return TRUE;
    return FALSE;
}

/* ---------------- Relay Constants ---------------- */
integer RELAY_CHANNEL    = -1812221819;
integer RLV_RESP_CHANNEL = 4711;
integer MAX_RELAYS       = 5;

integer MODE_OFF         = 0;
integer MODE_ON          = 1;
integer MODE_HARDCORE    = 2;

integer g_mode     = MODE_ON;
integer g_hardcore = FALSE;

/* ---------------- Relay State ---------------- */
/* g_relays: [obj, name, chan, restrictionsCSV] */
list    g_relays         = [];

/* ---------------- Session Menus ---------------- */
integer DIALOG_TIMEOUT_SEC = 180;
key     g_user = NULL_KEY;
integer g_menu_chan = 0;
integer g_listen = 0;

/* ACL from AUTH for the current user */
integer g_acl_level   = ACL_NOACCESS;
integer g_acl_pending = FALSE;

list    g_menu_labels = [];
list    g_menu_contexts = [];

/* =========================================================================
   HELPERS
   ========================================================================= */
integer json_has(string j, list path) { return (llJsonGetValue(j, path) != JSON_INVALID); }
integer logd(string m) { if (DEBUG) llOwnerSay("[RELAY] " + m); return 0; }

integer send_response(key obj, integer chan, string command, integer success) {
    string reply;
    if (success) reply = "ok";
    else reply = "ko";
    string msg = "RLV," + (string)llGetKey() + "," + command + "," + reply;
    llRegionSayTo(obj, chan, msg);
    return 0;
}

integer close_dialog() {
    if (g_listen) {
        llListenRemove(g_listen);
        g_listen = 0;
    }
    g_menu_chan = 0;
    llSetTimerEvent(0.0);
    return 0;
}

integer begin_context_dialog(key user, string body, list labels, list contexts) {
    g_menu_labels   = labels;
    g_menu_contexts = contexts;

    /* pad to multiple of 3 */
    while ((llGetListLength(g_menu_labels) % 3) != 0) {
        g_menu_labels   += " ";
        g_menu_contexts += " ";
    }

    close_dialog(); /* ensure previous dialog is closed */

    g_user      = user;
    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen    = llListen(g_menu_chan, "", g_user, "");
    llDialog(g_user, body, g_menu_labels, g_menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return TRUE;
}

string get_context_from_label(string label) {
    integer idx = llListFindList(g_menu_labels, [label]);
    if (idx != -1) return llList2String(g_menu_contexts, idx);
    return "";
}

/* =========================================================================
   RELAY + BIND STATE
   ========================================================================= */
integer relay_idx(key obj) {
    integer i;
    for (i = 0; i < llGetListLength(g_relays); i += 4) {
        if (llList2Key(g_relays, i) == obj) return i;
    }
    return -1;
}

integer add_relay(key obj, string name, integer chan) {
    if (relay_idx(obj) != -1) return 0;
    if ((llGetListLength(g_relays) / 4) >= MAX_RELAYS) return 0;
    g_relays += [obj, name, chan, ""];
    return 0;
}

integer remove_relay(key obj) {
    integer i = relay_idx(obj);
    if (i != -1) g_relays = llDeleteSubList(g_relays, i, i + 3);
    return 0;
}

integer store_restriction(key obj, string cmd) {
    integer i = relay_idx(obj);
    if (i == -1) return 0;
    string r = llList2String(g_relays, i + 3);
    if (r != "") r += "," + cmd;
    else r = cmd;
    g_relays = llListReplaceList(g_relays, [r], i + 3, i + 3);
    return 0;
}

integer clear_restrictions(key obj) {
    integer i = relay_idx(obj);
    if (i != -1) g_relays = llListReplaceList(g_relays, [""], i + 3, i + 3);
    return 0;
}

/* Bound if any relay has non-empty restrictions list */
integer is_bound() {
    integer i = 0;
    integer n = llGetListLength(g_relays);
    while (i < n) {
        string r = llList2String(g_relays, i + 3);
        if (r != "") return TRUE;
        i = i + 4;
    }
    return FALSE;
}

/* Ask AUTH for the current user's ACL */
integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   "acl_query");
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    g_acl_pending = TRUE;
    return 0;
}

/* =========================================================================
   UI MENUS
   ========================================================================= */
integer show_main_menu(key user) {
    if (!in_allowed_levels(g_acl_level)) return 0;

    string btn3 = " ";
    string ctx3 = " ";

    /* Only show an action button if effectively bound */
    if (is_bound()) {
        if (g_acl_level == ACL_OWNED) {
            /* Owned wearer → Safeword */
            btn3 = "Safeword";
            ctx3 = "safeword";
        } else if (g_acl_level == ACL_TRUSTEE || g_acl_level == ACL_PRIMARY_OWNER) {
            /* Trustee / Primary owner → Unbind */
            btn3 = "Unbind";
            ctx3 = "unbind";
        }
        /* For other ACL levels (e.g., 4) we leave it hidden unless you want it visible too */
    }

    list labels   = [ " ", "Back", " ", "Mode", "Active", btn3 ];
    list contexts = [ " ", "back", " ", "mode", "objects", ctx3 ];

    string mode_str = "OFF";
    if (g_mode == MODE_ON) mode_str = "ON";
    else if (g_mode == MODE_HARDCORE) mode_str = "HARDCORE";

    string hc_str = "OFF";
    if (g_hardcore) hc_str = "ON";

    begin_context_dialog(user, "RLV Relay:\nMode: " + mode_str +
                               "\nHardcore: " + hc_str, labels, contexts);
    return 0;
}

integer show_mode_menu(key user) {
    string hc     = "Hardcore ON";
    string hc_ctx = "hardcore_on";
    if (g_hardcore) {
        hc     = "Hardcore OFF";
        hc_ctx = "hardcore_off";
    }

    list labels   = [ " ", "Back", " ", "Set Off", "Set On", hc ];
    list contexts = [ " ", "cancel", " ", "set_off", "set_on", hc_ctx ];

    string mode_str = "OFF";
    if (g_mode == MODE_ON) mode_str = "ON";
    else if (g_mode == MODE_HARDCORE) mode_str = "HARDCORE";

    string hc_str = "DISABLED";
    if (g_hardcore) hc_str = "ENABLED";

    begin_context_dialog(user, "Change relay mode:\n(Current: " + mode_str +
                               ")\nHardcore: " + hc_str, labels, contexts);
    return 0;
}

integer show_object_list(key user) {
    string summary = "";
    integer count = llGetListLength(g_relays);
    if (count == 0) summary = "No active objects.";
    else {
        integer i;
        for (i = 0; i < count; i += 4) {
            integer idx = (i / 4) + 1;
            summary += (string)idx + ". " + llList2String(g_relays, i + 1) + "\n";
        }
    }
    list labels   = [ " ", "OK", " " ];
    list contexts = [ " ", "back", " " ];
    begin_context_dialog(user, "Active relay objects:\n" + summary, labels, contexts);
    return 0;
}

integer unbind_all() {
    integer i;
    for (i = 0; i < llGetListLength(g_relays); i += 4) {
        key obj   = llList2Key(g_relays, i);
        integer chan = llList2Integer(g_relays, i+2);
        string msg = "RLV," + (string)llGetKey() + ",!release,ok";
        llRegionSay(RELAY_CHANNEL, msg);
        llRegionSayTo(obj, chan, msg);
    }
    g_relays = [];
    llOwnerSay("@clear");
    return 0;
}

/* =========================================================================
   MAIN EVENT HANDLING
   ========================================================================= */
default {
    state_entry() {
        PLUGIN_SN = (integer)llFrand(1.0e9);
        g_user = NULL_KEY;
        g_acl_pending = FALSE;
        g_acl_level = ACL_NOACCESS;

        close_dialog();
        llListen(RELAY_CHANNEL, "", NULL_KEY, "");

        /* Soft reset + register with kernel */
        string msg = llList2Json(JSON_OBJECT, []);
        msg = llJsonSetValue(msg, ["type"], CONS_TYPE_PLUGIN_SOFT_RESET);
        msg = llJsonSetValue(msg, ["context"], PLUGIN_CONTEXT);
        llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, msg, NULL_KEY);

        msg = llList2Json(JSON_OBJECT, []);
        msg = llJsonSetValue(msg, ["type"],    CONS_TYPE_REGISTER);
        msg = llJsonSetValue(msg, ["sn"],      (string)PLUGIN_SN);
        msg = llJsonSetValue(msg, ["label"],   PLUGIN_LABEL);
        /* Keep min_acl "0" as in your version; change to "1" if you want it visible in public menus. */
        msg = llJsonSetValue(msg, ["min_acl"], "0");
        msg = llJsonSetValue(msg, ["context"], PLUGIN_CONTEXT);
        llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, msg, NULL_KEY);
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* Heartbeat reply */
        if (num == K_PLUGIN_PING && json_has(msg, ["type"]) &&
            llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_PING &&
            llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
            string pong = llList2Json(JSON_OBJECT, []);
            pong = llJsonSetValue(pong, ["type"], CONS_TYPE_PLUGIN_PONG);
            pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
            return;
        }

        /* Kernel re-register request for this script */
        if (num == K_PLUGIN_REG_QUERY && json_has(msg, ["script"]) &&
            llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
            string reply = llList2Json(JSON_OBJECT, []);
            reply = llJsonSetValue(reply, ["type"],    CONS_TYPE_REGISTER);
            reply = llJsonSetValue(reply, ["sn"],      (string)PLUGIN_SN);
            reply = llJsonSetValue(reply, ["label"],   PLUGIN_LABEL);
            reply = llJsonSetValue(reply, ["min_acl"], "0");
            reply = llJsonSetValue(reply, ["context"], PLUGIN_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, reply, NULL_KEY);
            return;
        }

        /* UI started this plugin; ask AUTH for 'id' */
        if (num == K_PLUGIN_START && json_has(msg, ["type"]) &&
            llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START &&
            llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
            g_user = id;
            g_acl_level = ACL_NOACCESS;
            g_acl_pending = FALSE;
            request_acl(g_user);
            return;
        }

        /* AUTH ACL result */
        if (num == AUTH_RESULT_NUM && json_has(msg, ["type"]) &&
            llJsonGetValue(msg, ["type"]) == "acl_result") {
            if (!json_has(msg, ["avatar"])) return;
            key who = (key)llJsonGetValue(msg, ["avatar"]);
            if (who != g_user) return;
            if (!json_has(msg, ["level"])) return;

            g_acl_level = (integer)llJsonGetValue(msg, ["level"]);
            g_acl_pending = FALSE;

            if (in_allowed_levels(g_acl_level)) {
                show_main_menu(g_user);
            } else {
                llRegionSayTo(g_user, 0, "Access denied.");
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);
                g_user = NULL_KEY;
                close_dialog();
            }
            return;
        }

        /* SOS (panic) */
        if (num == SOS_MSG_NUM && json_has(msg, ["type"])) {
            string t = llJsonGetValue(msg, ["type"]);
            if (t == "sos_release") {
                unbind_all();
                llOwnerSay("[SOS] All RLV restrictions cleared.");
                return;
            }
        }
    }

    listen(integer chan, string name, key id, string msg) {
        /* RLV relay channel */
        if (chan == RELAY_CHANNEL) {
            list p = llParseString2List(msg, ["|"], []);
            string rlv  = llList2String(p, 0);
            integer sess = RLV_RESP_CHANNEL;
            if (llGetListLength(p) > 1) sess = (integer)llList2String(p, 1);

            string command = rlv;
            if (llSubStringIndex(rlv, "RLV,") == 0) {
                list parts = llParseString2List(rlv, [","], []);
                if (llGetListLength(parts) >= 3) command = llList2String(parts, 2);
            }

            if (command == "@version" || command == "@versionnew") {
                add_relay(id, name, sess);
                send_response(id, sess, command, 1);
            } else if (command == "!release" || command == "!release_fail") {
                clear_restrictions(id);
                remove_relay(id);
                send_response(id, sess, command, 1);
            } else if (llSubStringIndex(command, "@") == 0) {
                if (g_mode == MODE_OFF) {
                    send_response(id, sess, command, 0);
                } else {
                    add_relay(id, name, sess);
                    store_restriction(id, command);
                    llOwnerSay(command);
                    send_response(id, sess, command, 1);
                }
            } else {
                send_response(id, sess, command, 0);
            }
            return;
        }

        /* Plugin UI clicks */
        if (chan != g_menu_chan || id != g_user) return;

        string ctx = get_context_from_label(msg);

        if (ctx == "back" || ctx == "cancel") {
            string r = llList2Json(JSON_OBJECT, []);
            r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
            r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);
            g_user = NULL_KEY;
            close_dialog();
            return;
        }

        if (ctx == "mode") { show_mode_menu(id); return; }
        if (ctx == "objects") { show_object_list(id); return; }

        if (ctx == "unbind") {
            /* Only Trustee (3) or Primary Owner (5) can Unbind */
            if (g_acl_level == ACL_TRUSTEE || g_acl_level == ACL_PRIMARY_OWNER) {
                unbind_all();
                show_main_menu(id);
            } else {
                llRegionSayTo(g_user, 0, "You do not have permission to use that.");
            }
            return;
        }

        if (ctx == "safeword") {
            /* Owned wearer’s panic; disabled in Hardcore */
            if (g_hardcore) {
                llRegionSayTo(g_user, 0, "Safeword is disabled in Hardcore mode.");
            } else {
                unbind_all();
            }
            show_main_menu(id);
            return;
        }

        if (ctx == "set_off") { g_mode = MODE_OFF; g_hardcore = FALSE; show_main_menu(id); return; }
        if (ctx == "set_on")  { g_mode = MODE_ON;  g_hardcore = FALSE; show_main_menu(id); return; }
        if (ctx == "hardcore_on")  { g_hardcore = TRUE;  g_mode = MODE_HARDCORE; show_main_menu(id); return; }
        if (ctx == "hardcore_off") { g_hardcore = FALSE; g_mode = MODE_ON;       show_main_menu(id); return; }
    }

    timer() {
        /* dialog timeout */
        close_dialog();
        g_user = NULL_KEY;
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }
}
