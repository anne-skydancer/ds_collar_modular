// =============================================================
//  PLUGIN: ds_collar_plugin_rlvexceptions.lsl (Optimized)
//  PURPOSE: RLV Owner/Trustee Exceptions, persistent, with actual RLV command enforcement
//  NOTES:  - AUTH ACL gate before opening menu
//          - Heartbeat + soft-reset safe
//          - Applies real RLV commands (@accepttp, @tplure, @sendim, @recvim)
//          - Multi-level menu system with session tracking
//  NAMING: PascalCase globals, ALL_CAPS constants, snake_case locals
// =============================================================

integer DEBUG = TRUE;

/* ---------- Kernel link numbers ---------- */
integer K_PLUGIN_REG_QUERY   = 500;  // Kernel → Plugin : {"type":"register_now","script":...}
integer K_PLUGIN_REG_REPLY   = 501;  // Plugin → Kernel : {"type":"register",...}
integer K_PLUGIN_SOFT_RESET  = 504;  // Plugin → Kernel : {"type":"plugin_soft_reset",...}

integer K_PLUGIN_PING        = 650;  // Kernel → Plugin : {"type":"plugin_ping",...}
integer K_PLUGIN_PONG        = 651;  // Plugin → Kernel : {"type":"plugin_pong",...}

integer AUTH_QUERY_NUM       = 700;  // → Auth : {"type":"acl_query","avatar":"<key>"}
integer AUTH_RESULT_NUM      = 710;  // ← Auth : {"type":"acl_result","avatar":"<key>","level":"<int>"}

integer K_SETTINGS_QUERY     = 800;  // Plugin ↔ Settings
integer K_SETTINGS_SYNC      = 870;  // Settings → Plugin

integer K_PLUGIN_START       = 900;  // UI → Plugin : {"type":"plugin_start",...}
integer K_PLUGIN_RETURN_NUM  = 901;  // Plugin → UI : {"type":"plugin_return",...}

/* ---------- Protocol strings ---------- */
string TYPE_REGISTER         = "register";
string TYPE_REGISTER_NOW     = "register_now";
string TYPE_PLUGIN_SOFT_RESET= "plugin_soft_reset";
string TYPE_PLUGIN_START     = "plugin_start";
string TYPE_PLUGIN_RETURN    = "plugin_return";
string TYPE_PLUGIN_PING      = "plugin_ping";
string TYPE_PLUGIN_PONG      = "plugin_pong";

string TYPE_SETTINGS_GET     = "settings_get";
string TYPE_SETTINGS_SET     = "set";
string TYPE_SETTINGS_SYNC    = "settings_sync";

string MSG_ACL_QUERY         = "acl_query";
string MSG_ACL_RESULT        = "acl_result";

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT       = "core_rlv_exceptions";
string  ROOT_CONTEXT         = "core_root";
integer PLUGIN_SN            = 0;
string  PLUGIN_LABEL         = "Exceptions";
integer PLUGIN_MIN_ACL       = 1;

/* ---------- ACL levels ---------- */
integer ACL_BLACKLIST        = -1;
integer ACL_NOACCESS         = 0;
integer ACL_PUBLIC           = 1;
integer ACL_OWNED            = 2;
integer ACL_TRUSTEE          = 3;
integer ACL_UNOWNED          = 4;
integer ACL_PRIMARY_OWNER    = 5;

/* Allowed ACLs for opening UI */
list    ALLOWED_ACL_LEVELS   = [ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

/* ---------- Submenu context labels ---------- */
string CTX_MAIN              = "main";
string CTX_OWNER             = "owner";
string CTX_OWNER_IM          = "owner_im";
string CTX_OWNER_TP          = "owner_tp";
string CTX_TRUSTEE           = "trustee";
string CTX_TRUSTEE_IM        = "trustee_im";
string CTX_TRUSTEE_TP        = "trustee_tp";

/* ---------- Settings keys ---------- */
string EX_OWNER_IM_KEY       = "ex_owner_im";
string EX_OWNER_TP_KEY       = "ex_owner_tp";
string EX_TRUSTEE_IM_KEY     = "ex_trustee_im";
string EX_TRUSTEE_TP_KEY     = "ex_trustee_tp";
string KEY_OWNER_KEY         = "owner_key";
string KEY_TRUSTEES          = "trustees";

/* ---------- Exception state (persistent) ---------- */
integer ExOwnerIm            = TRUE;   // Owner IM allowed
integer ExOwnerTp            = TRUE;   // Owner force TP allowed
integer ExTrusteeIm          = TRUE;   // Trustee IM allowed
integer ExTrusteeTp          = FALSE;  // Trustee TP allowed (default FALSE!)

/* ---------- Cached owner/trustee data ---------- */
key     OwnerKey             = NULL_KEY;
list    TrusteeList          = [];

/* ---------- Session management ---------- */
integer SESSION_TIMEOUT      = 180;
list    Sessions             = [];     // [avatar, page, csv, expiry, ctx, param, step, menucsv, chan, handle]

/* ---------- ACL session ---------- */
integer AclPending           = FALSE;
key     AclUser              = NULL_KEY;
integer AclLevel             = ACL_NOACCESS;

/* ---------- Heartbeat ---------- */
integer HB_TICK_SEC          = 30;
integer HB_SILENCE_SEC       = 90;
integer LastPingEpoch        = 0;

/* ========================== Helpers ========================== */
integer json_has(string json_str, list path) {
    if (llJsonGetValue(json_str, path) == JSON_INVALID) return FALSE;
    return TRUE;
}

integer logd(string msg_str) { 
    if (DEBUG) llOwnerSay("[RLVEX] " + msg_str); 
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

/* ---------- Session helpers ---------- */
integer session_idx(key avatar_key) { 
    return llListFindList(Sessions, [avatar_key]); 
}

integer session_set(key avatar_key, integer page, string csv, float expiry, string ctx, 
                    string param, string step, string menucsv, integer chan) {
    integer idx = session_idx(avatar_key);
    if (~idx) {
        integer old_handle = llList2Integer(Sessions, idx + 9);
        if (old_handle != -1) llListenRemove(old_handle);
        Sessions = llDeleteSubList(Sessions, idx, idx + 9);
    }
    integer listen_handle = llListen(chan, "", avatar_key, "");
    Sessions += [avatar_key, page, csv, expiry, ctx, param, step, menucsv, chan, listen_handle];
    return TRUE;
}

integer session_clear(key avatar_key) {
    integer idx = session_idx(avatar_key);
    if (~idx) {
        integer old_handle = llList2Integer(Sessions, idx + 9);
        if (old_handle != -1) llListenRemove(old_handle);
        Sessions = llDeleteSubList(Sessions, idx, idx + 9);
    }
    return TRUE;
}

list session_get(key avatar_key) {
    integer idx = session_idx(avatar_key);
    if (~idx) return llList2List(Sessions, idx, idx + 9);
    return [];
}

/* =============================================================
   RLV COMMAND ENFORCEMENT
   ============================================================= */

/* Apply @accepttp and @tplure for a specific avatar based on exception settings */
integer apply_tp_exceptions(key avatar_key, integer allow) {
    if (avatar_key == NULL_KEY) return FALSE;
    
    if (allow) {
        llOwnerSay("@accepttp:" + (string)avatar_key + "=add");
        llOwnerSay("@tplure:" + (string)avatar_key + "=add");
        logd("Applied TP exceptions for " + (string)avatar_key);
    } else {
        llOwnerSay("@accepttp:" + (string)avatar_key + "=rem");
        llOwnerSay("@tplure:" + (string)avatar_key + "=rem");
        logd("Removed TP exceptions for " + (string)avatar_key);
    }
    return TRUE;
}

/* Apply @sendim and @recvim for a specific avatar based on exception settings */
integer apply_im_exceptions(key avatar_key, integer allow) {
    if (avatar_key == NULL_KEY) return FALSE;
    
    if (allow) {
        llOwnerSay("@sendim:" + (string)avatar_key + "=add");
        llOwnerSay("@recvim:" + (string)avatar_key + "=add");
        logd("Applied IM exceptions for " + (string)avatar_key);
    } else {
        llOwnerSay("@sendim:" + (string)avatar_key + "=rem");
        llOwnerSay("@recvim:" + (string)avatar_key + "=rem");
        logd("Removed IM exceptions for " + (string)avatar_key);
    }
    return TRUE;
}

/* Reconcile ALL RLV exceptions based on current settings */
integer reconcile_all_exceptions() {
    logd("Reconciling all RLV exceptions...");
    
    /* Owner exceptions */
    if (OwnerKey != NULL_KEY) {
        apply_tp_exceptions(OwnerKey, ExOwnerTp);
        apply_im_exceptions(OwnerKey, ExOwnerIm);
    }
    
    /* Trustee exceptions */
    integer i = 0;
    integer list_length = llGetListLength(TrusteeList);
    while (i < list_length) {
        key trustee_key = (key)llList2String(TrusteeList, i);
        if (trustee_key != NULL_KEY) {
            apply_tp_exceptions(trustee_key, ExTrusteeTp);
            apply_im_exceptions(trustee_key, ExTrusteeIm);
        }
        i = i + 1;
    }
    
    logd("Reconciliation complete.");
    return TRUE;
}

/* Clear all exceptions for a specific person (when they're removed from owner/trustee) */
integer clear_all_exceptions_for(key avatar_key) {
    if (avatar_key == NULL_KEY) return FALSE;
    
    llOwnerSay("@accepttp:" + (string)avatar_key + "=rem");
    llOwnerSay("@tplure:" + (string)avatar_key + "=rem");
    llOwnerSay("@sendim:" + (string)avatar_key + "=rem");
    llOwnerSay("@recvim:" + (string)avatar_key + "=rem");
    
    logd("Cleared all exceptions for " + (string)avatar_key);
    return TRUE;
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
   Settings Management
   ============================================================= */

integer request_settings_get() {
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, json_msg, NULL_KEY);
    logd("Requested settings_get.");
    return TRUE;
}

integer persist_exception(string param_name, integer value) {
    if (value != 0) value = 1;
    string json_msg = llList2Json(JSON_OBJECT, []);
    json_msg = llJsonSetValue(json_msg, ["type"],  TYPE_SETTINGS_SET);
    json_msg = llJsonSetValue(json_msg, ["key"],   param_name);
    json_msg = llJsonSetValue(json_msg, ["value"], (string)value);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, json_msg, NULL_KEY);
    logd("Persisted: " + param_name + "=" + (string)value);
    return TRUE;
}

integer apply_settings_sync(string payload) {
    if (!json_has(payload, ["type"])) return FALSE;
    if (llJsonGetValue(payload, ["type"]) != TYPE_SETTINGS_SYNC) return FALSE;
    if (!json_has(payload, ["kv"])) return FALSE;

    string key_values = llJsonGetValue(payload, ["kv"]);
    string value_str;
    
    /* Store previous owner/trustees to detect changes */
    key prev_owner = OwnerKey;
    list prev_trustees = TrusteeList;

    /* Load owner/trustees */
    value_str = llJsonGetValue(key_values, [KEY_OWNER_KEY]);
    if (value_str != JSON_INVALID) {
        OwnerKey = (key)value_str;
    } else {
        OwnerKey = NULL_KEY;
    }
    
    value_str = llJsonGetValue(key_values, [KEY_TRUSTEES]);
    if (value_str != JSON_INVALID && llGetSubString(value_str, 0, 0) == "[") {
        TrusteeList = llJson2List(value_str);
    } else {
        TrusteeList = [];
    }

    /* Load exception settings */
    value_str = llJsonGetValue(key_values, [EX_OWNER_IM_KEY]);
    if (value_str != JSON_INVALID) {
        ExOwnerIm = ((integer)value_str != 0);
    }

    value_str = llJsonGetValue(key_values, [EX_OWNER_TP_KEY]);
    if (value_str != JSON_INVALID) {
        ExOwnerTp = ((integer)value_str != 0);
    }

    value_str = llJsonGetValue(key_values, [EX_TRUSTEE_IM_KEY]);
    if (value_str != JSON_INVALID) {
        ExTrusteeIm = ((integer)value_str != 0);
    }

    value_str = llJsonGetValue(key_values, [EX_TRUSTEE_TP_KEY]);
    if (value_str != JSON_INVALID) {
        ExTrusteeTp = ((integer)value_str != 0);
    }

    logd("Settings sync: owner=" + (string)OwnerKey + 
         " trustees=" + (string)llGetListLength(TrusteeList) +
         " ownerIM=" + (string)ExOwnerIm +
         " ownerTP=" + (string)ExOwnerTp +
         " trusteeIM=" + (string)ExTrusteeIm +
         " trusteeTP=" + (string)ExTrusteeTp);

    /* Handle owner change */
    if (prev_owner != OwnerKey) {
        if (prev_owner != NULL_KEY) {
            clear_all_exceptions_for(prev_owner);
        }
        if (OwnerKey != NULL_KEY) {
            apply_tp_exceptions(OwnerKey, ExOwnerTp);
            apply_im_exceptions(OwnerKey, ExOwnerIm);
        }
    } else if (OwnerKey != NULL_KEY) {
        /* Owner unchanged but settings might have changed */
        apply_tp_exceptions(OwnerKey, ExOwnerTp);
        apply_im_exceptions(OwnerKey, ExOwnerIm);
    }
    
    /* Handle trustee changes - reconcile all trustees */
    integer i = 0;
    integer list_length = llGetListLength(TrusteeList);
    while (i < list_length) {
        key trustee_key = (key)llList2String(TrusteeList, i);
        if (trustee_key != NULL_KEY) {
            apply_tp_exceptions(trustee_key, ExTrusteeTp);
            apply_im_exceptions(trustee_key, ExTrusteeIm);
        }
        i = i + 1;
    }
    
    return TRUE;
}

/* =============================================================
   UI Helpers
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
    list buttons = ["~", "Back", "~", "Owner", "~", "Trustee"];
    while (llGetListLength(buttons) % 3 != 0) buttons += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    session_set(user, 0, "", now() + SESSION_TIMEOUT, CTX_MAIN, "", "", "", menu_chan);

    string msg = "RLV Exceptions Menu\nChoose Owner or Trustee exceptions to manage.";
    llDialog(user, msg, buttons, menu_chan);
    logd("Main menu → " + (string)user + " chan=" + (string)menu_chan);
    return TRUE;
}

integer show_owner_menu(key user) {
    list buttons = ["~", "Back", "~", "IM", "~", "TP"];
    while (llGetListLength(buttons) % 3 != 0) buttons += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    session_set(user, 0, "", now() + SESSION_TIMEOUT, CTX_OWNER, "", "", "", menu_chan);

    string msg = "Owner Exceptions:\nChoose which exception to edit.";
    llDialog(user, msg, buttons, menu_chan);
    logd("Owner menu → " + (string)user + " chan=" + (string)menu_chan);
    return TRUE;
}

integer show_trustee_menu(key user) {
    list buttons = ["~", "Back", "~", "IM", "~", "TP"];
    while (llGetListLength(buttons) % 3 != 0) buttons += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    session_set(user, 0, "", now() + SESSION_TIMEOUT, CTX_TRUSTEE, "", "", "", menu_chan);

    string msg = "Trustee Exceptions:\nChoose which exception to edit.";
    llDialog(user, msg, buttons, menu_chan);
    logd("Trustee menu → " + (string)user + " chan=" + (string)menu_chan);
    return TRUE;
}

integer show_exception_menu(key user, string ctx, string persist_key, string plus_label, 
                            string minus_label, integer current_val) {
    list buttons = ["~", "Back", "~", plus_label, "~", minus_label];
    while (llGetListLength(buttons) % 3 != 0) buttons += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    session_set(user, 0, "", now() + SESSION_TIMEOUT, ctx, persist_key, "", "", menu_chan);

    string msg = "";
    if (persist_key == EX_OWNER_IM_KEY)
        msg = "Owner IM Exception:\n";
    else if (persist_key == EX_OWNER_TP_KEY)
        msg = "Owner TP Exception:\n";
    else if (persist_key == EX_TRUSTEE_IM_KEY)
        msg = "Trustee IM Exception:\n";
    else if (persist_key == EX_TRUSTEE_TP_KEY)
        msg = "Trustee TP Exception:\n";
    
    if (current_val)
        msg += "Current: ALLOWED\n";
    else
        msg += "Current: DENIED\n";
    msg += "\nChoose to allow (+) or deny (-).";
    
    llDialog(user, msg, buttons, menu_chan);
    logd("Exception menu ("+ctx+") → " + (string)user + " chan=" + (string)menu_chan);
    return TRUE;
}

/* =============================================================
   EVENTS
   ============================================================= */

default
{
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
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
            llOwnerSay("[RLVEX] Owner changed. Resetting plugin.");
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
                    AclUser = id;
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
            if (avatar_key != AclUser) return;
            if (!json_has(msg, ["level"])) return;

            AclPending = FALSE;
            AclLevel = (integer)llJsonGetValue(msg, ["level"]);

            if (!allow_open() || !in_allowed_levels(AclLevel)) {
                llRegionSayTo(AclUser, 0, "Access denied.");
                send_plugin_return(AclUser);
                AclUser = NULL_KEY;
                return;
            }

            show_main_menu(AclUser);
            return;
        }
    }

    listen(integer chan, string name, key id, string pressed) {
        list session = session_get(id);
        if (llGetListLength(session) == 10 && chan == llList2Integer(session, 8)) {
            string ctx = llList2String(session, 4);
            string persist_key = llList2String(session, 5);

            /* Back button logic */
            if (pressed == "Back") {
                if (ctx == CTX_MAIN) {
                    /* From plugin main menu: Back → root via plugin_return */
                    session_clear(id);
                    send_plugin_return(id);
                    return;
                } else {
                    /* From any other submenu, Back → plugin main menu */
                    show_main_menu(id);
                    return;
                }
            }

            /* Main menu navigation */
            if (ctx == CTX_MAIN) {
                if (pressed == "Owner") {
                    show_owner_menu(id);
                    return;
                }
                if (pressed == "Trustee") {
                    show_trustee_menu(id);
                    return;
                }
            }
            /* Owner submenu */
            else if (ctx == CTX_OWNER) {
                if (pressed == "IM") {
                    show_exception_menu(id, CTX_OWNER_IM, EX_OWNER_IM_KEY, "Owner IM +", "Owner IM -", ExOwnerIm);
                    return;
                }
                if (pressed == "TP") {
                    show_exception_menu(id, CTX_OWNER_TP, EX_OWNER_TP_KEY, "Owner TP +", "Owner TP -", ExOwnerTp);
                    return;
                }
            }
            /* Trustee submenu */
            else if (ctx == CTX_TRUSTEE) {
                if (pressed == "IM") {
                    show_exception_menu(id, CTX_TRUSTEE_IM, EX_TRUSTEE_IM_KEY, "Trust IM +", "Trust IM -", ExTrusteeIm);
                    return;
                }
                if (pressed == "TP") {
                    show_exception_menu(id, CTX_TRUSTEE_TP, EX_TRUSTEE_TP_KEY, "Trust TP +", "Trust TP -", ExTrusteeTp);
                    return;
                }
            }
            /* Owner IM/TP and Trustee IM/TP submenus */
            else if (ctx == CTX_OWNER_IM || ctx == CTX_OWNER_TP ||
                     ctx == CTX_TRUSTEE_IM || ctx == CTX_TRUSTEE_TP) {

                /* Owner IM */
                if (pressed == "Owner IM +" && ctx == CTX_OWNER_IM) {
                    ExOwnerIm = TRUE;
                    persist_exception(EX_OWNER_IM_KEY, ExOwnerIm);
                    if (OwnerKey != NULL_KEY) apply_im_exceptions(OwnerKey, ExOwnerIm);
                    show_exception_menu(id, CTX_OWNER_IM, EX_OWNER_IM_KEY, "Owner IM +", "Owner IM -", ExOwnerIm);
                    return;
                }
                if (pressed == "Owner IM -" && ctx == CTX_OWNER_IM) {
                    ExOwnerIm = FALSE;
                    persist_exception(EX_OWNER_IM_KEY, ExOwnerIm);
                    if (OwnerKey != NULL_KEY) apply_im_exceptions(OwnerKey, ExOwnerIm);
                    show_exception_menu(id, CTX_OWNER_IM, EX_OWNER_IM_KEY, "Owner IM +", "Owner IM -", ExOwnerIm);
                    return;
                }
                /* Owner TP */
                if (pressed == "Owner TP +" && ctx == CTX_OWNER_TP) {
                    ExOwnerTp = TRUE;
                    persist_exception(EX_OWNER_TP_KEY, ExOwnerTp);
                    if (OwnerKey != NULL_KEY) apply_tp_exceptions(OwnerKey, ExOwnerTp);
                    show_exception_menu(id, CTX_OWNER_TP, EX_OWNER_TP_KEY, "Owner TP +", "Owner TP -", ExOwnerTp);
                    return;
                }
                if (pressed == "Owner TP -" && ctx == CTX_OWNER_TP) {
                    ExOwnerTp = FALSE;
                    persist_exception(EX_OWNER_TP_KEY, ExOwnerTp);
                    if (OwnerKey != NULL_KEY) apply_tp_exceptions(OwnerKey, ExOwnerTp);
                    show_exception_menu(id, CTX_OWNER_TP, EX_OWNER_TP_KEY, "Owner TP +", "Owner TP -", ExOwnerTp);
                    return;
                }
                /* Trustee IM */
                if (pressed == "Trust IM +" && ctx == CTX_TRUSTEE_IM) {
                    ExTrusteeIm = TRUE;
                    persist_exception(EX_TRUSTEE_IM_KEY, ExTrusteeIm);
                    integer i = 0;
                    integer list_length = llGetListLength(TrusteeList);
                    while (i < list_length) {
                        key trustee_key = (key)llList2String(TrusteeList, i);
                        if (trustee_key != NULL_KEY) apply_im_exceptions(trustee_key, ExTrusteeIm);
                        i = i + 1;
                    }
                    show_exception_menu(id, CTX_TRUSTEE_IM, EX_TRUSTEE_IM_KEY, "Trust IM +", "Trust IM -", ExTrusteeIm);
                    return;
                }
                if (pressed == "Trust IM -" && ctx == CTX_TRUSTEE_IM) {
                    ExTrusteeIm = FALSE;
                    persist_exception(EX_TRUSTEE_IM_KEY, ExTrusteeIm);
                    integer i = 0;
                    integer list_length = llGetListLength(TrusteeList);
                    while (i < list_length) {
                        key trustee_key = (key)llList2String(TrusteeList, i);
                        if (trustee_key != NULL_KEY) apply_im_exceptions(trustee_key, ExTrusteeIm);
                        i = i + 1;
                    }
                    show_exception_menu(id, CTX_TRUSTEE_IM, EX_TRUSTEE_IM_KEY, "Trust IM +", "Trust IM -", ExTrusteeIm);
                    return;
                }
                /* Trustee TP */
                if (pressed == "Trust TP +" && ctx == CTX_TRUSTEE_TP) {
                    ExTrusteeTp = TRUE;
                    persist_exception(EX_TRUSTEE_TP_KEY, ExTrusteeTp);
                    integer i = 0;
                    integer list_length = llGetListLength(TrusteeList);
                    while (i < list_length) {
                        key trustee_key = (key)llList2String(TrusteeList, i);
                        if (trustee_key != NULL_KEY) apply_tp_exceptions(trustee_key, ExTrusteeTp);
                        i = i + 1;
                    }
                    show_exception_menu(id, CTX_TRUSTEE_TP, EX_TRUSTEE_TP_KEY, "Trust TP +", "Trust TP -", ExTrusteeTp);
                    return;
                }
                if (pressed == "Trust TP -" && ctx == CTX_TRUSTEE_TP) {
                    ExTrusteeTp = FALSE;
                    persist_exception(EX_TRUSTEE_TP_KEY, ExTrusteeTp);
                    integer i = 0;
                    integer list_length = llGetListLength(TrusteeList);
                    while (i < list_length) {
                        key trustee_key = (key)llList2String(TrusteeList, i);
                        if (trustee_key != NULL_KEY) apply_tp_exceptions(trustee_key, ExTrusteeTp);
                        i = i + 1;
                    }
                    show_exception_menu(id, CTX_TRUSTEE_TP, EX_TRUSTEE_TP_KEY, "Trust TP +", "Trust TP -", ExTrusteeTp);
                    return;
                }
            }
        }
    }

    timer() {
        /* Heartbeat maintenance */
        hb_tick();

        /* Session timeout cleanup */
        integer current_time = now();
        integer i = 0;
        while (i < llGetListLength(Sessions)) {
            float expiry = llList2Float(Sessions, i + 3);
            key avatar_key = llList2Key(Sessions, i);
            if (current_time > expiry) {
                session_clear(avatar_key);
            } else {
                i = i + 10;
            }
        }
    }
}
