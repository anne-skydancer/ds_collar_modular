/* =========================================================================
   PLUGIN: ds_rlv_relay_plugin.lsl (Optimized)
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
            - Heartbeat + soft-reset safe
   NAMING: PascalCase globals, ALL_CAPS constants, snake_case locals
   ========================================================================= */

integer DEBUG = FALSE;

/* ---------- Kernel link numbers ---------- */
integer K_PLUGIN_REG_QUERY   = 500;
integer K_PLUGIN_REG_REPLY   = 501;
integer K_PLUGIN_SOFT_RESET  = 504;

integer K_PLUGIN_PING        = 650;
integer K_PLUGIN_PONG        = 651;

integer AUTH_QUERY_NUM       = 700;
integer AUTH_RESULT_NUM      = 710;

integer K_SETTINGS_QUERY     = 800;
integer K_SETTINGS_SYNC      = 870;

integer K_PLUGIN_START       = 900;
integer K_PLUGIN_RETURN_NUM  = 901;

integer SOS_MSG_NUM          = 999;  // SOS plugin link channel

/* ---------- Protocol strings ---------- */
string TYPE_REGISTER         = "register";
string TYPE_REGISTER_NOW     = "register_now";
string TYPE_PLUGIN_SOFT_RESET= "plugin_soft_reset";
string TYPE_PLUGIN_START     = "plugin_start";
string TYPE_PLUGIN_RETURN    = "plugin_return";
string TYPE_PLUGIN_PING      = "plugin_ping";
string TYPE_PLUGIN_PONG      = "plugin_pong";

string TYPE_SETTINGS_GET     = "settings_get";
string TYPE_SETTINGS_SYNC    = "settings_sync";

string MSG_ACL_QUERY         = "acl_query";
string MSG_ACL_RESULT        = "acl_result";

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT       = "core_relay";
string  ROOT_CONTEXT         = "core_root";
integer PLUGIN_SN            = 0;
string  PLUGIN_LABEL         = "RLV Relay";
integer PLUGIN_MIN_ACL       = 2;  /* wearer & above */

/* ---------- ACL levels ---------- */
integer ACL_BLACKLIST        = -1;
integer ACL_NOACCESS         = 0;
integer ACL_PUBLIC           = 1;
integer ACL_OWNED            = 2;  /* wearer (owned) */
integer ACL_TRUSTEE          = 3;
integer ACL_UNOWNED          = 4;  /* wearer (unowned) */
integer ACL_PRIMARY_OWNER    = 5;

/* Allowed ACL levels for opening UI */
list    ALLOWED_ACL_LEVELS   = [ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

/* ---------- Relay Constants ---------- */
integer RELAY_CHANNEL        = -1812221819;
integer RLV_RESP_CHANNEL     = 4711;
integer MAX_RELAYS           = 5;

integer MODE_OFF             = 0;
integer MODE_ON              = 1;
integer MODE_HARDCORE        = 2;

/* ---------- Settings keys ---------- */
string KEY_OWNER_KEY         = "owner_key";

/* ---------- Relay State ---------- */
integer Mode                 = MODE_ON;
integer Hardcore             = FALSE;

/* Relays: [obj_key, obj_name, session_chan, restrictions_csv] * N */
list    Relays               = [];

/* ---------- Session (UI) ---------- */
integer DIALOG_TIMEOUT_SEC   = 180;
key     MenuUser             = NULL_KEY;
integer MenuChan             = 0;
integer ListenHandle         = 0;
integer DialogExpires        = 0;

/* For building label→context mapping */
list    MenuLabels           = [];
list    MenuContexts         = [];

/* ---------- ACL session ---------- */
integer AclPending           = FALSE;
integer AclLevel             = ACL_NOACCESS;

/* ---------- Owner tracking ---------- */
key     OwnerKeyCached       = NULL_KEY;

/* ---------- Heartbeat ---------- */
integer HB_TICK_SEC          = 30;
integer HB_SILENCE_SEC       = 90;
integer LastPingEpoch        = 0;

/* ========================== Helpers ========================== */
integer json_has(string json_str, list path) { 
    return (llJsonGetValue(json_str, path) != JSON_INVALID); 
}

integer logd(string msg_str) { 
    if (DEBUG) llOwnerSay("[RELAY] " + msg_str); 
    return 0; 
}

integer now() { 
    return llGetUnixTime(); 
}

integer in_allowed_levels(integer level) {
    if (~llListFindList(ALLOWED_ACL_LEVELS, [level])) return TRUE;
    return FALSE;
}

integer allow_open() {
    if (AclLevel < 0) return FALSE;  // blacklist
    return TRUE;
}

integer cleanup_session() {
    if (ListenHandle) llListenRemove(ListenHandle);
    ListenHandle = 0;
    MenuUser = NULL_KEY;
    MenuChan = 0;
    MenuLabels = [];
    MenuContexts = [];
    DialogExpires = 0;
    return 0;
}

/* ========================== Context Dialog ========================== */
integer begin_context_dialog(key user, string body, list labels, list contexts) {
    MenuLabels   = labels;
    MenuContexts = contexts;
    while ((llGetListLength(MenuLabels) % 3) != 0) {
        MenuLabels   += " ";
        MenuContexts += " ";
    }
    if (ListenHandle) llListenRemove(ListenHandle);
    MenuUser = user;
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    ListenHandle = llListen(MenuChan, "", MenuUser, "");
    llDialog(MenuUser, body, MenuLabels, MenuChan);
    DialogExpires = now() + DIALOG_TIMEOUT_SEC;
    return TRUE;
}

string get_context_from_label(string label) {
    integer idx = llListFindList(MenuLabels, [label]);
    if (idx != -1) return llList2String(MenuContexts, idx);
    return "";
}

/* =============================================================
   Registration + Heartbeat
   ============================================================= */

integer register_plugin() {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"],    TYPE_REGISTER);
    json_msg = llJsonSetValue(json_msg, ["sn"],      (string)PLUGIN_SN);
    json_msg = llJsonSetValue(json_msg, ["label"],   PLUGIN_LABEL);
    json_msg = llJsonSetValue(json_msg, ["min_acl"], (string)PLUGIN_MIN_ACL);
    json_msg = llJsonSetValue(json_msg, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, json_msg, NULL_KEY);
    logd("Registered with kernel. Label=" + PLUGIN_LABEL);
    return TRUE;
}

integer notify_soft_reset() {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"],    TYPE_PLUGIN_SOFT_RESET);
    json_msg = llJsonSetValue(json_msg, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, json_msg, NULL_KEY);
    return 0;
}

integer request_settings_get() {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, json_msg, NULL_KEY);
    logd("Requested settings_get.");
    return TRUE;
}

integer hb_init() {
    LastPingEpoch = now();
    llSetTimerEvent((float)HB_TICK_SEC);
    return 0;
}

integer hb_on_ping_ok() { 
    LastPingEpoch = now(); 
    return 0; 
}

integer hb_tick() {
    if ((now() - LastPingEpoch) > HB_SILENCE_SEC) {
        register_plugin();
        LastPingEpoch = now();
    }
    return 0;
}

/* =============================================================
   AUTH Gate
   ============================================================= */

integer request_acl(key avatar_key) {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"],   MSG_ACL_QUERY);
    json_msg = llJsonSetValue(json_msg, ["avatar"], (string)avatar_key);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, json_msg, NULL_KEY);
    AclPending = TRUE;
    logd("ACL query → " + (string)avatar_key);
    return 0;
}

/* =============================================================
   Relay State Management
   ============================================================= */

integer relay_idx(key obj_key) {
    integer i = 0;
    integer list_length = llGetListLength(Relays);
    while (i < list_length) {
        if (llList2Key(Relays, i) == obj_key) return i;
        i = i + 4;
    }
    return -1;
}

integer add_relay(key obj_key, string obj_name, integer chan) {
    if (relay_idx(obj_key) != -1) return 0;
    if ((llGetListLength(Relays) / 4) >= MAX_RELAYS) return 0;
    Relays += [obj_key, obj_name, chan, ""];
    return 0;
}

integer remove_relay(key obj_key) {
    integer idx = relay_idx(obj_key);
    if (idx != -1) Relays = llDeleteSubList(Relays, idx, idx + 3);
    return 0;
}

integer store_restriction(key obj_key, string cmd) {
    integer idx = relay_idx(obj_key);
    if (idx == -1) return 0;
    string restrictions = llList2String(Relays, idx + 3);
    if (restrictions != "") restrictions = restrictions + "," + cmd;
    else restrictions = cmd;
    Relays = llListReplaceList(Relays, [restrictions], idx + 3, idx + 3);
    return 0;
}

integer clear_restrictions(key obj_key) {
    integer idx = relay_idx(obj_key);
    if (idx != -1) Relays = llListReplaceList(Relays, [""], idx + 3, idx + 3);
    return 0;
}

/* Bound if any relay has a non-empty restriction list */
integer is_bound() {
    integer i = 0;
    integer list_length = llGetListLength(Relays);
    while (i < list_length) {
        string restrictions = llList2String(Relays, i + 3);
        if (restrictions != "") return TRUE;
        i = i + 4;
    }
    return FALSE;
}

/* Viewer safeword + local cleanup */
integer safeword_clear_all() {
    llOwnerSay("@clear");
    llOwnerSay("@unsit=force");
    Relays = [];
    if (DEBUG) llOwnerSay("[RELAY] Safeword issued: @clear (+ @unsit=force).");
    return 0;
}

/* Force Hardcore OFF (used on owner change/removal) */
integer force_hardcore_off(string reason) {
    if (Hardcore) {
        Hardcore = FALSE;
        Mode = MODE_ON;
        if (reason != "") llOwnerSay("[RELAY] Hardcore disabled: " + reason);
        else llOwnerSay("[RELAY] Hardcore disabled.");
    }
    return 0;
}

/* =============================================================
   Settings Management
   ============================================================= */

integer apply_settings_sync(string msg) {
    if (!json_has(msg, ["type"])) return FALSE;
    if (llJsonGetValue(msg, ["type"]) != TYPE_SETTINGS_SYNC) return FALSE;
    if (!json_has(msg, ["kv"])) return FALSE;

    string key_values = llJsonGetValue(msg, ["kv"]);
    
    if (json_has(key_values, [KEY_OWNER_KEY])) {
        key new_owner = (key)llJsonGetValue(key_values, [KEY_OWNER_KEY]);
        if (new_owner != OwnerKeyCached) {
            string reason = "owner changed";
            if (new_owner == NULL_KEY) reason = "owner removed";
            force_hardcore_off(reason);
            OwnerKeyCached = new_owner;
        }
    } else {
        /* key missing → treat as removal */
        if (OwnerKeyCached != NULL_KEY) {
            force_hardcore_off("owner removed");
            OwnerKeyCached = NULL_KEY;
        }
    }
    
    return TRUE;
}

/* =============================================================
   UI Menus
   ============================================================= */

integer send_plugin_return(key user) {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"],    TYPE_PLUGIN_RETURN);
    json_msg = llJsonSetValue(json_msg, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, json_msg, user);
    logd("Return → root for " + (string)user);
    return TRUE;
}

integer show_main_menu(key user) {
    if (!in_allowed_levels(AclLevel)) return 0;

    /* Dynamic release button (only if currently bound) */
    string btn3 = " ";
    string ctx3 = " ";
    integer bound = is_bound();

    if (bound) {
        if (Hardcore) {
            /* Hardcore ON + bound:
                 - ACL 3/5 → Unbind
                 - ACL 2   → no release
                 - ACL 4   → Safeword
            */
            if (AclLevel == ACL_TRUSTEE || AclLevel == ACL_PRIMARY_OWNER) {
                btn3 = "Unbind";
                ctx3 = "unbind";
            } else {
                if (AclLevel == ACL_UNOWNED) {
                    btn3 = "Safeword";
                    ctx3 = "safeword";
                }
            }
        } else {
            /* Hardcore OFF + bound:
                 - ACL 2/4 → Safeword
                 - ACL 3/5 → Unbind
            */
            if (AclLevel == ACL_OWNED || AclLevel == ACL_UNOWNED) {
                btn3 = "Safeword";
                ctx3 = "safeword";
            } else {
                if (AclLevel == ACL_TRUSTEE || AclLevel == ACL_PRIMARY_OWNER) {
                    btn3 = "Unbind";
                    ctx3 = "unbind";
                }
            }
        }
    }

    list labels   = [ " ", "Back", " ", "Mode", "Active", btn3 ];
    list contexts = [ " ", "back", " ", "mode", "objects", ctx3 ];

    string mode_str = "OFF";
    if (Mode == MODE_ON) mode_str = "ON";
    else if (Mode == MODE_HARDCORE) mode_str = "HARDCORE";

    string hc_str = "DISABLED";
    if (Hardcore) hc_str = "ENABLED";

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
    if (AclLevel == ACL_TRUSTEE || AclLevel == ACL_PRIMARY_OWNER) allow_hc = TRUE;

    string hc_label = " ";
    string hc_ctx   = " ";
    if (allow_hc) {
        if (Hardcore) {
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
    if (Mode == MODE_ON) mode_str = "ON";
    else if (Mode == MODE_HARDCORE) mode_str = "HARDCORE";

    string hc_str = "DISABLED";
    if (Hardcore) hc_str = "ENABLED";

    return begin_context_dialog(user,
        "Change relay mode\n"
        + "Current: " + mode_str + "\n"
        + "Hardcore: " + hc_str,
        labels, contexts);
}

integer show_object_list(key user) {
    string summary = "";
    integer list_length = llGetListLength(Relays);
    if (list_length == 0) summary = "No active objects.";
    else {
        integer i = 0;
        while (i < list_length) {
            integer display_idx = (i / 4) + 1;
            summary += (string)display_idx + ". " + llList2String(Relays, i + 1) + "\n";
            i = i + 4;
        }
    }
    list labels   = [ " ", "OK", " " ];
    list contexts = [ " ", "back", " " ];
    return begin_context_dialog(user, "Active relay objects:\n" + summary, labels, contexts);
}

/* =============================================================
   EVENTS
   ============================================================= */

default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        cleanup_session();
        AclLevel = ACL_NOACCESS;

        /* Listen to incoming relay messages from devices */
        llListen(RELAY_CHANNEL, "", NULL_KEY, "");

        notify_soft_reset();
        register_plugin();
        request_settings_get();
        hb_init();

        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[RELAY] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* Heartbeat */
        if (num == K_PLUGIN_PING) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_PING) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    hb_on_ping_ok();
                    string json_pong = llList2Json(JSON_OBJECT, []);
                    json_pong = llJsonSetValue(json_pong, ["type"],    TYPE_PLUGIN_PONG);
                    json_pong = llJsonSetValue(json_pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, json_pong, NULL_KEY);
                }
            }
            return;
        }

        /* Kernel: "register_now" for THIS script */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_REGISTER_NOW) {
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                    register_plugin();
                    hb_on_ping_ok();
                }
            }
            return;
        }

        /* Settings sync */
        if (num == K_SETTINGS_SYNC) {
            apply_settings_sync(msg);
            return;
        }

        /* UI: start → request ACL first */
        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_START) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    MenuUser = id;
                    request_acl(id);
                }
            }
            return;
        }

        /* AUTH result */
        if (num == AUTH_RESULT_NUM) {
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;
            key avatar_key = (key)llJsonGetValue(msg, ["avatar"]);
            if (avatar_key != MenuUser) return;
            if (!json_has(msg, ["level"])) return;

            AclPending = FALSE;
            AclLevel = (integer)llJsonGetValue(msg, ["level"]);

            if (!allow_open() || !in_allowed_levels(AclLevel)) {
                llRegionSayTo(MenuUser, 0, "Access denied.");
                send_plugin_return(MenuUser);
                cleanup_session();
                return;
            }

            show_main_menu(MenuUser);
            return;
        }

        /* SOS integration: force release everything */
        if (num == SOS_MSG_NUM) {
            if (json_has(msg, ["type"])) {
                string msg_type = llJsonGetValue(msg, ["type"]);
                if (msg_type == "sos_release") {
                    safeword_clear_all();
                    llOwnerSay("[SOS] All RLV restrictions cleared.");
                }
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string msg) {
        /* Relay channel (device chatter) */
        if (chan == RELAY_CHANNEL) {
            list parsed_list = llParseString2List(msg, ["|"], []);
            string raw_cmd = llList2String(parsed_list, 0);
            integer session_chan = RLV_RESP_CHANNEL;
            if (llGetListLength(parsed_list) > 1) session_chan = (integer)llList2String(parsed_list, 1);

            string command = raw_cmd;
            if (llSubStringIndex(raw_cmd, "RLV,") == 0) {
                list parts = llParseString2List(raw_cmd, [","], []);
                if (llGetListLength(parts) >= 3) command = llList2String(parts, 2);
            }

            if (command == "@version" || command == "@versionnew") {
                add_relay(id, name, session_chan);
                string reply = "RLV," + (string)llGetKey() + "," + command + ",ok";
                llRegionSayTo(id, session_chan, reply);
                return;
            }

            if (command == "!release" || command == "!release_fail") {
                clear_restrictions(id);
                remove_relay(id);
                string reply = "RLV," + (string)llGetKey() + "," + command + ",ok";
                llRegionSayTo(id, session_chan, reply);
                return;
            }

            if (llSubStringIndex(command, "@") == 0) {
                if (Mode == MODE_OFF) {
                    string reply_ko = "RLV," + (string)llGetKey() + "," + command + ",ko";
                    llRegionSayTo(id, session_chan, reply_ko);
                    return;
                }
                add_relay(id, name, session_chan);
                store_restriction(id, command);
                llOwnerSay(command); /* forward to viewer */
                string reply_ok = "RLV," + (string)llGetKey() + "," + command + ",ok";
                llRegionSayTo(id, session_chan, reply_ok);
                return;
            }

            /* unknown command */
            string reply_unknown = "RLV," + (string)llGetKey() + "," + command + ",ko";
            llRegionSayTo(id, session_chan, reply_unknown);
            return;
        }

        /* Plugin UI */
        if (chan != MenuChan || id != MenuUser) return;

        string ctx = get_context_from_label(msg);

        if (ctx == "back" || ctx == "cancel") {
            send_plugin_return(MenuUser);
            cleanup_session();
            return;
        }

        if (ctx == "mode") { 
            show_mode_menu(id); 
            return; 
        }
        
        if (ctx == "objects") { 
            show_object_list(id); 
            return; 
        }

        if (ctx == "unbind") {
            /* Only ACL 3/5 may unbind in any mode */
            if (AclLevel == ACL_TRUSTEE || AclLevel == ACL_PRIMARY_OWNER) {
                safeword_clear_all();
                show_main_menu(id);
            } else {
                llRegionSayTo(MenuUser, 0, "You do not have permission to use that.");
            }
            return;
        }

        if (ctx == "safeword") {
            /* In Hardcore, only ACL 4 gets Safeword; ACL 2 is blocked. In normal, 2/4 allowed. */
            integer allow = FALSE;
            if (Hardcore) {
                if (AclLevel == ACL_UNOWNED) allow = TRUE; /* ACL 4 */
            } else {
                if (AclLevel == ACL_OWNED || AclLevel == ACL_UNOWNED) allow = TRUE;
            }
            if (allow) {
                safeword_clear_all();
            } else {
                llRegionSayTo(MenuUser, 0, "Safeword is not available.");
            }
            show_main_menu(id);
            return;
        }

        /* Mode changes (always allowed) */
        if (ctx == "set_off") {
            Mode = MODE_OFF;
            Hardcore = FALSE; /* turning mode OFF also clears Hardcore flag */
            show_main_menu(id);
            return;
        }
        
        if (ctx == "set_on") {
            Mode = MODE_ON;
            /* leave Hardcore as-is (it only has effect when MODE_HARDCORE) */
            show_main_menu(id);
            return;
        }

        /* Hardcore toggles — ONLY ACL 3/5 allowed; ACL 2/4 blocked even if they click an old dialog */
        if (ctx == "hardcore_on") {
            if (AclLevel == ACL_TRUSTEE || AclLevel == ACL_PRIMARY_OWNER) {
                Hardcore = TRUE;
                Mode = MODE_HARDCORE;
                show_main_menu(id);
            } else {
                llRegionSayTo(MenuUser, 0, "You do not have permission to change Hardcore.");
                show_mode_menu(id);
            }
            return;
        }
        
        if (ctx == "hardcore_off") {
            if (AclLevel == ACL_TRUSTEE || AclLevel == ACL_PRIMARY_OWNER) {
                Hardcore = FALSE;
                Mode = MODE_ON;
                show_main_menu(id);
            } else {
                llRegionSayTo(MenuUser, 0, "You do not have permission to change Hardcore.");
                show_mode_menu(id);
            }
            return;
        }
    }

    timer() {
        /* Heartbeat maintenance */
        hb_tick();

        /* Dialog timeout */
        if (DialogExpires != 0) {
            if (now() >= DialogExpires) {
                cleanup_session();
            }
        }
    }
}
