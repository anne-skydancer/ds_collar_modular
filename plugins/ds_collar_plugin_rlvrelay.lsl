/* =========================================================================
   PLUGIN: ds_rlv_relay_plugin.lsl  (ACL-hardened + Hardcore owner auto-off)
   PURPOSE: Self-contained RLV Relay for DS Collar
            - Registers with min_acl = 2 (wearer and above)
            - AUTH-driven ACL per-touch (no local guesswork)
            - Hardcore:
                * Only ACL 3 (Trustee) / ACL 5 (Primary Owner) can toggle.
                * If Hardcore ON and bound:
                    - ACL 3/5 see "Unbind"
                    - ACL 2 (owned wearer) sees NO release
                    - ACL 4 (unowned wearer) sees "Safeword"
              Non-Hardcore and bound:
                    - ACL 2/4 see "Safeword"
                    - ACL 3/5 see "Unbind"
            - Owner key change/removal → Hardcore forced OFF immediately
            - @clear + @unsit=force for release; clears internal state
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
integer SOS_MSG_NUM          = 999; // SOS plugin link channel

/* AUTH (authoritative) */
integer AUTH_QUERY_NUM       = 700;
integer AUTH_RESULT_NUM      = 710;

/* SETTINGS (to watch owner changes) */
integer SETTINGS_SYNC_NUM    = 870;
string  KEY_OWNER_KEY        = "owner_key";

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
integer PLUGIN_MIN_ACL = 2; /* wearer & above */

/* ---------- ACL levels (authoritative) ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2; /* wearer (owned) */
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4; /* wearer (unowned) */
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Allowed ACL levels for this plugin ---------- */
list ALLOWED_ACL_LEVELS = [ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

integer in_allowed_levels(integer lvl) {
    if (~llListFindList(ALLOWED_ACL_LEVELS, [lvl])) return TRUE;
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
/* g_relays: [obj_key, obj_name, session_chan, restrictions_csv] * N */
list    g_relays         = [];

/* ---------------- Session Menus ---------------- */
integer DIALOG_TIMEOUT_SEC = 180;
key     g_user = NULL_KEY;
integer g_menu_chan = 0;
integer g_listen = 0;

integer g_acl_level   = ACL_NOACCESS;

/* For building label→context mapping */
list    g_menu_labels = [];
list    g_menu_contexts = [];

/* Owner tracking from SETTINGS to force Hardcore OFF on owner change/removal */
key     g_owner_key_cached = NULL_KEY;

/* =========================================================================
   HELPERS
   ========================================================================= */
integer json_has(string j, list path) { return (llJsonGetValue(j, path) != JSON_INVALID); }
integer logd(string m) { if (DEBUG) llOwnerSay("[RELAY] " + m); return 0; }

integer begin_context_dialog(key user, string body, list labels, list contexts) {
    g_menu_labels   = labels;
    g_menu_contexts = contexts;
    while ((llGetListLength(g_menu_labels) % 3) != 0) {
        g_menu_labels   += " ";
        g_menu_contexts += " ";
    }
    if (g_listen) llListenRemove(g_listen);
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

/* ---------- ACL via AUTH ---------- */
integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], "acl_query");
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    return TRUE;
}

/* =========================================================================
   RELAY STATE
   ========================================================================= */
integer relay_idx(key obj) {
    integer i = 0;
    integer n = llGetListLength(g_relays);
    while (i < n) {
        if (llList2Key(g_relays, i) == obj) return i;
        i = i + 4;
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
    if (r != "") r = r + "," + cmd;
    else r = cmd;
    g_relays = llListReplaceList(g_relays, [r], i + 3, i + 3);
    return 0;
}

integer clear_restrictions(key obj) {
    integer i = relay_idx(obj);
    if (i != -1) g_relays = llListReplaceList(g_relays, [""], i + 3, i + 3);
    return 0;
}

/* Bound if any relay has a non-empty restriction list */
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

/* Viewer safeword + local cleanup */
integer safeword_clear_all()
{
    llOwnerSay("@clear");
    llOwnerSay("@unsit=force");
    g_relays = [];
    if (DEBUG) llOwnerSay("[RELAY] Safeword issued: @clear (+ @unsit=force).");
    return 0;
}

/* Force Hardcore OFF (used on owner change/removal) */
integer force_hardcore_off(string reason) {
    if (g_hardcore) {
        g_hardcore = FALSE;
        g_mode = MODE_ON;
        if (reason != "") llOwnerSay("[RELAY] Hardcore disabled: " + reason);
        else llOwnerSay("[RELAY] Hardcore disabled.");
    }
    return 0;
}

/* =========================================================================
   UI MENUS
   ========================================================================= */
integer show_main_menu(key user) {
    if (!in_allowed_levels(g_acl_level)) return 0;

    /* Dynamic release button (only if currently bound) */
    string btn3 = " ";
    string ctx3 = " ";
    integer bound = is_bound();

    if (bound) {
        if (g_hardcore) {
            /* Hardcore ON + bound:
                 - ACL 3/5 → Unbind
                 - ACL 2   → no release
                 - ACL 4   → Safeword
            */
            if (g_acl_level == ACL_TRUSTEE || g_acl_level == ACL_PRIMARY_OWNER) {
                btn3 = "Unbind";
                ctx3 = "unbind";
            } else {
                if (g_acl_level == ACL_UNOWNED) {
                    btn3 = "Safeword";
                    ctx3 = "safeword";
                }
            }
        } else {
            /* Hardcore OFF + bound:
                 - ACL 2/4 → Safeword
                 - ACL 3/5 → Unbind
            */
            if (g_acl_level == ACL_OWNED || g_acl_level == ACL_UNOWNED) {
                btn3 = "Safeword";
                ctx3 = "safeword";
            } else {
                if (g_acl_level == ACL_TRUSTEE || g_acl_level == ACL_PRIMARY_OWNER) {
                    btn3 = "Unbind";
                    ctx3 = "unbind";
                }
            }
        }
    }

    list labels   = [ " ", "Back", " ", "Mode", "Active", btn3 ];
    list contexts = [ " ", "back", " ", "mode", "objects", ctx3 ];

    string mode_str = "OFF";
    if (g_mode == MODE_ON) mode_str = "ON";
    else if (g_mode == MODE_HARDCORE) mode_str = "HARDCORE";

    string hc_str = "DISABLED";
    if (g_hardcore) hc_str = "ENABLED";

    string bound_str = "Not bound";
    if (bound) bound_str = "Bound";

    return begin_context_dialog(user,
        "RLV Relay\n"
        + "Mode: " + mode_str + "\n"
        + "Hardcore: " + hc_str + "\n"
        + "State: " + bound_str,
        labels, contexts);
}

integer show_mode_menu(key user) {
    /* ACL 3/5 may toggle Hardcore; ACL 2/4 cannot (hidden) */
    integer allow_hc = FALSE;
    if (g_acl_level == ACL_TRUSTEE || g_acl_level == ACL_PRIMARY_OWNER) allow_hc = TRUE;

    string hc_label = " ";
    string hc_ctx   = " ";
    if (allow_hc) {
        if (g_hardcore) {
            hc_label = "Hardcore OFF";
            hc_ctx   = "hardcore_off";
        } else {
            hc_label = "Hardcore ON";
            hc_ctx   = "hardcore_on";
        }
    }

    list labels   = [ " ", "Back", " ", "Set Off", "Set On", hc_label ];
    list contexts = [ " ", "cancel", " ", "set_off", "set_on", hc_ctx ];

    string mode_str = "OFF";
    if (g_mode == MODE_ON) mode_str = "ON";
    else if (g_mode == MODE_HARDCORE) mode_str = "HARDCORE";

    string hc_str = "DISABLED";
    if (g_hardcore) hc_str = "ENABLED";

    return begin_context_dialog(user,
        "Change relay mode\n"
        + "Current: " + mode_str + "\n"
        + "Hardcore: " + hc_str,
        labels, contexts);
}

integer show_object_list(key user) {
    string summary = "";
    integer n = llGetListLength(g_relays);
    if (n == 0) summary = "No active objects.";
    else {
        integer i = 0;
        while (i < n) {
            integer idx = (i / 4) + 1;
            summary += (string)idx + ". " + llList2String(g_relays, i + 1) + "\n";
            i = i + 4;
        }
    }
    list labels   = [ " ", "OK", " " ];
    list contexts = [ " ", "back", " " ];
    return begin_context_dialog(user, "Active relay objects:\n" + summary, labels, contexts);
}

/* =========================================================================
   MAIN EVENT HANDLING
   ========================================================================= */
default {
    state_entry() {
        PLUGIN_SN = (integer)llFrand(1.0e9);
        g_user = NULL_KEY;
        g_acl_level = ACL_NOACCESS;

        if (g_listen) llListenRemove(g_listen);
        g_listen = 0;
        g_menu_chan = 0;

        /* Listen to incoming relay messages from devices */
        llListen(RELAY_CHANNEL, "", NULL_KEY, "");

        /* Announce soft reset then register with kernel */
        string msg = llList2Json(JSON_OBJECT, []);
        msg = llJsonSetValue(msg, ["type"], CONS_TYPE_PLUGIN_SOFT_RESET);
        msg = llJsonSetValue(msg, ["context"], PLUGIN_CONTEXT);
        llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, msg, NULL_KEY);

        msg = llList2Json(JSON_OBJECT, []);
        msg = llJsonSetValue(msg, ["type"], CONS_TYPE_REGISTER);
        msg = llJsonSetValue(msg, ["sn"], (string)PLUGIN_SN);
        msg = llJsonSetValue(msg, ["label"], PLUGIN_LABEL);
        msg = llJsonSetValue(msg, ["min_acl"], (string)PLUGIN_MIN_ACL);
        msg = llJsonSetValue(msg, ["context"], PLUGIN_CONTEXT);
        llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, msg, NULL_KEY);

        llSetTimerEvent(0.0);
        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* Kernel heartbeat */
        if (num == K_PLUGIN_PING && json_has(msg, ["type"])) {
            if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_PING &&
                llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                string pong = llList2Json(JSON_OBJECT, []);
                pong = llJsonSetValue(pong, ["type"], CONS_TYPE_PLUGIN_PONG);
                pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
            }
            return;
        }

        /* Kernel asks this exact script to re-register */
        if (num == K_PLUGIN_REG_QUERY && json_has(msg, ["script"])) {
            if (llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                string reply = llList2Json(JSON_OBJECT, []);
                reply = llJsonSetValue(reply, ["type"], CONS_TYPE_REGISTER);
                reply = llJsonSetValue(reply, ["sn"], (string)PLUGIN_SN);
                reply = llJsonSetValue(reply, ["label"], PLUGIN_LABEL);
                reply = llJsonSetValue(reply, ["min_acl"], (string)PLUGIN_MIN_ACL);
                reply = llJsonSetValue(reply, ["context"], PLUGIN_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, reply, NULL_KEY);
            }
            return;
        }

        /* UI: start this plugin → ask AUTH for ACL */
        if (num == K_PLUGIN_START && json_has(msg, ["type"])) {
            if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START &&
                llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                g_user = id;
                g_acl_level = ACL_NOACCESS;
                request_acl(g_user);
            }
            return;
        }

        /* AUTH result arrives (gate all actions by toucher) */
        if (num == AUTH_RESULT_NUM && json_has(msg, ["type"])) {
            if (llJsonGetValue(msg, ["type"]) == "acl_result") {
                if (!json_has(msg, ["avatar"])) return;
                key av = (key)llJsonGetValue(msg, ["avatar"]);
                if (av != g_user) return;

                if (!json_has(msg, ["level"])) return;
                g_acl_level = (integer)llJsonGetValue(msg, ["level"]);

                if (g_acl_level <= 0 || !in_allowed_levels(g_acl_level)) {
                    llRegionSayTo(g_user, 0, "Access denied.");
                    string r = llList2Json(JSON_OBJECT, []);
                    r = llJsonSetValue(r, ["type"], CONS_TYPE_PLUGIN_RETURN);
                    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);
                    g_user = NULL_KEY;
                    if (g_listen) { llListenRemove(g_listen); g_listen = 0; }
                    return;
                }

                show_main_menu(g_user);
            }
            return;
        }

        /* SETTINGS sync: watch owner changes → force Hardcore OFF */
        if (num == SETTINGS_SYNC_NUM && json_has(msg, ["type"])) {
            if (llJsonGetValue(msg, ["type"]) == "settings_sync") {
                if (json_has(msg, ["kv"])) {
                    string kv = llJsonGetValue(msg, ["kv"]);
                    if (json_has(kv, [KEY_OWNER_KEY])) {
                        key newOwner = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
                        if (newOwner != g_owner_key_cached) {
                            string reason = "owner changed";
                            if (newOwner == NULL_KEY) reason = "owner removed";
                            force_hardcore_off(reason);
                            g_owner_key_cached = newOwner;
                        }
                    } else {
                        /* key missing → treat as removal */
                        if (g_owner_key_cached != NULL_KEY) {
                            force_hardcore_off("owner removed");
                            g_owner_key_cached = NULL_KEY;
                        }
                    }
                }
            }
            return;
        }

        /* SOS integration: force release everything */
        if (num == SOS_MSG_NUM && json_has(msg, ["type"])) {
            string t = llJsonGetValue(msg, ["type"]);
            if (t == "sos_release") {
                safeword_clear_all();
                llOwnerSay("[SOS] All RLV restrictions cleared.");
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string msg) {
        /* Relay channel (device chatter) */
        if (chan == RELAY_CHANNEL) {
            list p = llParseString2List(msg, ["|"], []);
            string raw = llList2String(p, 0);
            integer sess = RLV_RESP_CHANNEL;
            if (llGetListLength(p) > 1) sess = (integer)llList2String(p, 1);

            string command = raw;
            if (llSubStringIndex(raw, "RLV,") == 0) {
                list parts = llParseString2List(raw, [","], []);
                if (llGetListLength(parts) >= 3) command = llList2String(parts, 2);
            }

            if (command == "@version" || command == "@versionnew") {
                add_relay(id, name, sess);
                string reply = "RLV," + (string)llGetKey() + "," + command + ",ok";
                llRegionSayTo(id, sess, reply);
                return;
            }

            if (command == "!release" || command == "!release_fail") {
                clear_restrictions(id);
                remove_relay(id);
                string reply2 = "RLV," + (string)llGetKey() + "," + command + ",ok";
                llRegionSayTo(id, sess, reply2);
                return;
            }

            if (llSubStringIndex(command, "@") == 0) {
                if (g_mode == MODE_OFF) {
                    string ko = "RLV," + (string)llGetKey() + "," + command + ",ko";
                    llRegionSayTo(id, sess, ko);
                    return;
                }
                add_relay(id, name, sess);
                store_restriction(id, command);
                llOwnerSay(command); /* forward to viewer */
                string ok = "RLV," + (string)llGetKey() + "," + command + ",ok";
                llRegionSayTo(id, sess, ok);
                return;
            }

            /* unknown */
            string ko2 = "RLV," + (string)llGetKey() + "," + command + ",ko";
            llRegionSayTo(id, sess, ko2);
            return;
        }

        /* Plugin UI */
        if (chan != g_menu_chan || id != g_user) return;

        string ctx = get_context_from_label(msg);

        if (ctx == "back" || ctx == "cancel") {
            string r = llList2Json(JSON_OBJECT, []);
            r = llJsonSetValue(r, ["type"], CONS_TYPE_PLUGIN_RETURN);
            r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);
            g_user = NULL_KEY;
            if (g_listen) { llListenRemove(g_listen); g_listen = 0; }
            llSetTimerEvent(0.0);
            return;
        }

        if (ctx == "mode") { show_mode_menu(id); return; }
        if (ctx == "objects") { show_object_list(id); return; }

        if (ctx == "unbind") {
            /* Only ACL 3/5 may unbind in any mode */
            if (g_acl_level == ACL_TRUSTEE || g_acl_level == ACL_PRIMARY_OWNER) {
                safeword_clear_all();
                show_main_menu(id);
            } else {
                llRegionSayTo(g_user, 0, "You do not have permission to use that.");
            }
            return;
        }

        if (ctx == "safeword") {
            /* In Hardcore, only ACL 4 gets Safeword; ACL 2 is blocked. In normal, 2/4 allowed. */
            integer allow = FALSE;
            if (g_hardcore) {
                if (g_acl_level == ACL_UNOWNED) allow = TRUE; /* ACL 4 */
            } else {
                if (g_acl_level == ACL_OWNED || g_acl_level == ACL_UNOWNED) allow = TRUE;
            }
            if (allow) {
                safeword_clear_all();
            } else {
                llRegionSayTo(g_user, 0, "Safeword is not available.");
            }
            show_main_menu(id);
            return;
        }

        /* Mode changes (always allowed) */
        if (ctx == "set_off") {
            g_mode = MODE_OFF;
            g_hardcore = FALSE; /* turning mode OFF also clears Hardcore flag */
            show_main_menu(id);
            return;
        }
        if (ctx == "set_on") {
            g_mode = MODE_ON;
            /* leave g_hardcore as-is (it only has effect when MODE_HARDCORE) */
            show_main_menu(id);
            return;
        }

        /* Hardcore toggles — ONLY ACL 3/5 allowed; ACL 2/4 blocked even if they click an old dialog */
        if (ctx == "hardcore_on") {
            if (g_acl_level == ACL_TRUSTEE || g_acl_level == ACL_PRIMARY_OWNER) {
                g_hardcore = TRUE;
                g_mode = MODE_HARDCORE;
                show_main_menu(id);
            } else {
                llRegionSayTo(g_user, 0, "You do not have permission to change Hardcore.");
                show_mode_menu(id);
            }
            return;
        }
        if (ctx == "hardcore_off") {
            if (g_acl_level == ACL_TRUSTEE || g_acl_level == ACL_PRIMARY_OWNER) {
                g_hardcore = FALSE;
                g_mode = MODE_ON;
                show_main_menu(id);
            } else {
                llRegionSayTo(g_user, 0, "You do not have permission to change Hardcore.");
                show_mode_menu(id);
            }
            return;
        }
    }

    timer() {
        if (g_listen) {
            llListenRemove(g_listen);
            g_listen = 0;
        }
        g_user = NULL_KEY;
        g_menu_chan = 0;
        llSetTimerEvent(0.0);
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }
}
