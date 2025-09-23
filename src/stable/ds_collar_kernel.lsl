/* =============================================================
   MODULE: ds_collar_kernel_serialized.lsl
   PURPOSE: Kernel with serialized reg/dereg, dual heartbeat,
            internal ISN tracking, and safe UI broadcasts
   NOTES:
     - Serialized register/deregister queues prevent races
     - Heartbeat = inventory presence OR recent pong
       (plugin only removed if BOTH are missing/expired)
     - Backward compatible: plugins may omit "script" in register;
       kernel then falls back to "context" as script name.
   ============================================================= */

integer DEBUG = FALSE;

/* ---------- Protocol constants (magic words) ---------- */
string MSG_PING            = "plugin_ping";
string MSG_PONG            = "plugin_pong";
string MSG_SOFT_RESET      = "plugin_soft_reset";
string MSG_KERNEL_SOFT_RST = "kernel_soft_reset";
string MSG_REGISTER_NOW    = "register_now";
string MSG_REGISTER        = "register";
string MSG_DEREGISTER      = "deregister";
string MSG_PLUGIN_LIST     = "plugin_list";
string MSG_PLUGIN_START    = "plugin_start";
string MSG_PLUGIN_RETURN   = "plugin_return";
string MSG_SETTINGS_GET    = "settings_get";
string MSG_SETTINGS_SYNC   = "settings_sync";
string MSG_ACL_QUERY       = "acl_query";
string MSG_ACL_RESULT      = "acl_result";

/* ---------- Fixed link numbers ---------- */
integer K_PLUGIN_REG_QUERY     = 500; // Kernel → Plugins
integer K_PLUGIN_REG_REPLY     = 501; // Plugins → Kernel
integer K_PLUGIN_DEREG         = 502; // Any    → Kernel
integer K_SOFT_RESET           = 503; // Any    → Kernel
integer K_PLUGIN_SOFT_RESET    = 504; // Plugins → Kernel plugin soft reset announce

integer K_PLUGIN_LIST          = 600; // Kernel → All
integer K_PLUGIN_LIST_REQUEST  = 601; // UI     → Kernel

/* Heartbeat link numbers */
integer K_PLUGIN_PING          = 650; // Kernel → Plugins
integer K_PLUGIN_PONG          = 651; // Plugins → Kernel

/* ---------- Settings (reserved) ---------- */
integer K_SETTINGS_QUERY       = 800;
integer K_SETTINGS_SYNC        = 870;

/* ---------- Heartbeat settings ---------- */
float   PING_INTERVAL        = 5.0;
integer PING_TIMEOUT         = 15;
float   INV_SWEEP_INTERVAL   = 3.0;

/* ---------- Internal State ---------- */
/* g_plugin_map layout per entry:
   [0]=context, [1]=isn, [2]=sn, [3]=label, [4]=min_acl, [5]=script, [6]=last_seen_unix
*/
list    g_plugin_map   = [];
integer g_next_isn     = 1;

list    g_add_queue    = [];
list    g_dereg_queue  = [];

integer g_registering   = FALSE;
integer g_deregistering = FALSE;

integer g_last_ping_unix      = 0;
integer g_last_inv_sweep_unix = 0;
key     g_last_owner          = NULL_KEY;

/* ---------- JSON helpers ---------- */
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* ---------- Debug helper ---------- */
integer logd(string s) { if (DEBUG) llOwnerSay("[KERNEL] " + s); return FALSE; }

/* ---------- Owner handling ---------- */
integer reset_if_owner_changed() {
    key owner = llGetOwner();
    if (owner == NULL_KEY) return FALSE;
    if (owner != g_last_owner) {
        g_last_owner = owner;
        llResetScript();
        return TRUE;
    }
    return FALSE;
}

/* ---------- Map helpers ---------- */
integer map_stride() { return 7; }
integer map_index_from_context(string ctx) {
    integer stride = map_stride();
    integer i = 0;
    integer L = llGetListLength(g_plugin_map);
    while (i < L) {
        if (llList2String(g_plugin_map, i) == ctx) return i;
        i += stride;
    }
    return -1;
}
string map_get_script_at(integer idx) {
    return llList2String(g_plugin_map, idx + 5);
}
integer map_set_last_seen(string ctx, integer when) {
    integer idx = map_index_from_context(ctx);
    if (idx == -1) return FALSE;
    g_plugin_map = llListReplaceList(g_plugin_map, [
        llList2String(g_plugin_map, idx),
        llList2Integer(g_plugin_map, idx+1),
        llList2Integer(g_plugin_map, idx+2),
        llList2String (g_plugin_map, idx+3),
        llList2Integer(g_plugin_map, idx+4),
        llList2String (g_plugin_map, idx+5),
        when
    ], idx, idx+6);
    return TRUE;
}

/* ---------- Registry Functions (serialized) ---------- */
integer queue_register(string ctx, integer sn, string label, integer min_acl, string script) {
    if (map_index_from_context(ctx) != -1) return FALSE;
    if (llListFindList(g_add_queue, [ctx]) != -1) return FALSE;
    g_add_queue += [ ctx, sn, label, min_acl, script ];
    g_registering = TRUE;
    return TRUE;
}
integer queue_deregister(string ctx) {
    if (map_index_from_context(ctx) == -1) return FALSE;
    if (llListFindList(g_dereg_queue, [ctx]) != -1) return FALSE;
    g_dereg_queue += [ ctx ];
    g_deregistering = TRUE;
    return TRUE;
}

integer process_next_add() {
    if (llGetListLength(g_add_queue) == 0) {
        if (g_registering) {
            g_registering = FALSE;
            broadcast_plugin_list();
        }
        return FALSE;
    }
    string  ctx     = llList2String (g_add_queue, 0);
    integer sn      = llList2Integer(g_add_queue, 1);
    string  label   = llList2String (g_add_queue, 2);
    integer min_acl = llList2Integer(g_add_queue, 3);
    string  script  = llList2String (g_add_queue, 4);
    g_add_queue     = llDeleteSubList(g_add_queue, 0, 4);
    integer idx = map_index_from_context(ctx);
    integer now = llGetUnixTime();
    if (idx == -1) {
        integer isn = g_next_isn;
        g_next_isn += 1;
        if (script == "") script = ctx;
        g_plugin_map += [ ctx, isn, sn, label, min_acl, script, now ];
        logd("Registered: ctx=" + ctx + " isn=" + (string)isn + " label=" + label + " script=" + script);
    } else {
        integer old_isn = llList2Integer(g_plugin_map, idx+1);
        if (script == "") script = llList2String(g_plugin_map, idx+5);
        g_plugin_map = llListReplaceList(g_plugin_map, [ ctx, old_isn, sn, label, min_acl, script, now ], idx, idx+6);
        logd("Refreshed: ctx=" + ctx + " isn=" + (string)old_isn);
    }
    return TRUE;
}

integer process_next_dereg() {
    if (llGetListLength(g_dereg_queue) == 0) {
        if (g_deregistering) {
            g_deregistering = FALSE;
            broadcast_plugin_list();
        }
        return FALSE;
    }
    string ctx = llList2String(g_dereg_queue, 0);
    g_dereg_queue = llDeleteSubList(g_dereg_queue, 0, 0);
    integer idx = map_index_from_context(ctx);
    if (idx != -1) {
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"], MSG_DEREGISTER);
        j = llJsonSetValue(j, ["context"], ctx);
        llMessageLinked(LINK_SET, K_PLUGIN_DEREG, j, NULL_KEY);
        g_plugin_map = llDeleteSubList(g_plugin_map, idx, idx + 6);
        logd("Deregistered: " + ctx);
        return TRUE;
    }
    return FALSE;
}

/* ---------- Heartbeat ---------- */
integer send_ping_all() {
    integer stride = map_stride();
    integer i = 0;
    integer L = llGetListLength(g_plugin_map);
    integer now = llGetUnixTime();
    integer sent = 0;
    while (i < L) {
        string ctx = llList2String(g_plugin_map, i);
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"], MSG_PING);
        j = llJsonSetValue(j, ["context"], ctx);
        j = llJsonSetValue(j, ["ts"], (string)now);
        llMessageLinked(LINK_SET, K_PLUGIN_PING, j, NULL_KEY);
        i += stride;
        sent += 1;
    }
    return sent;
}

integer inventory_sweep_and_prune_if_both_dead() {
    integer stride = map_stride();
    integer i = 0;
    integer L = llGetListLength(g_plugin_map);
    integer now = llGetUnixTime();
    integer any_removed = FALSE;
    while (i < L) {
        string  ctx     = llList2String (g_plugin_map, i);
        integer last    = llList2Integer(g_plugin_map, i+6);
        string  script  = llList2String (g_plugin_map, i+5);
        integer has_inv = FALSE;
        if (script == "") script = ctx;
        if (llGetInventoryType(script) == INVENTORY_SCRIPT) has_inv = TRUE;
        integer has_pong = ((now - last) <= PING_TIMEOUT);
        if (!has_inv && !has_pong) {
            logd("Heartbeat failed (inv+pong) → remove: " + ctx);
            g_plugin_map = llDeleteSubList(g_plugin_map, i, i+6);
            L -= stride;
            any_removed = TRUE;
        } else {
            i += stride;
        }
    }
    if (any_removed) broadcast_plugin_list();
    return any_removed;
}

/* ---------- Broadcast Plugin List ---------- */
integer broadcast_plugin_list() {
    integer stride = map_stride();
    integer L = llGetListLength(g_plugin_map);
    integer i = 0;
    list arr = [];
    while (i < L) {
        string  ctx     = llList2String (g_plugin_map, i);
        integer isn     = llList2Integer(g_plugin_map, i+1);
        integer sn      = llList2Integer(g_plugin_map, i+2);
        string  label   = llList2String (g_plugin_map, i+3);
        integer min_acl = llList2Integer(g_plugin_map, i+4);
        string o = llList2Json(JSON_OBJECT, []);
        o = llJsonSetValue(o, ["isn"],      (string)isn);
        o = llJsonSetValue(o, ["sn"],       (string)sn);
        o = llJsonSetValue(o, ["label"],    label);
        o = llJsonSetValue(o, ["min_acl"],  (string)min_acl);
        o = llJsonSetValue(o, ["context"],  ctx);
        arr += [ o ];
        i += stride;
    }
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], MSG_PLUGIN_LIST);
    j = llJsonSetValue(j, ["plugins"], llList2Json(JSON_ARRAY, arr));
    llMessageLinked(LINK_SET, K_PLUGIN_LIST, j, NULL_KEY);
    return (L / stride);
}

/* ---------- Registration Solicitation ---------- */
integer solicit_plugin_register() {
    integer n = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i;
    integer sent = 0;
    for (i = 0; i < n; ++i) {
        string script_name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (script_name != llGetScriptName()) {
            if (llSubStringIndex(script_name, "ds_collar_plugin_") == 0) {
                string j = llList2Json(JSON_OBJECT, []);
                j = llJsonSetValue(j, ["type"],   MSG_REGISTER_NOW);
                j = llJsonSetValue(j, ["script"], script_name);
                llMessageLinked(LINK_SET, K_PLUGIN_REG_QUERY, j, NULL_KEY);
                sent += 1;
            }
        }
    }
    return sent;
}

/* =============================================================
   MAIN
   ============================================================= */
default {
    state_entry() {
        g_last_owner = llGetOwner();
        g_plugin_map   = [];
        g_add_queue    = [];
        g_dereg_queue  = [];
        g_next_isn     = 1;
        g_last_ping_unix      = llGetUnixTime();
        g_last_inv_sweep_unix = g_last_ping_unix;
        llSetTimerEvent(0.2);
        solicit_plugin_register();
    }

    on_rez(integer param) {
        reset_if_owner_changed();
    }

    attach(key id) {
        if (id == NULL_KEY) return;
        reset_if_owner_changed();
    }

    link_message(integer sender, integer num, string str, key id) {
        if (num == K_PLUGIN_LIST_REQUEST) {
            broadcast_plugin_list();
            return;
        }
        if (num == K_SOFT_RESET) {
            integer accepted = FALSE;
            if (str == MSG_KERNEL_SOFT_RST) accepted = TRUE;
            else if (json_has(str, ["type"])) {
                if (llJsonGetValue(str, ["type"]) == MSG_KERNEL_SOFT_RST) accepted = TRUE;
            }
            if (!accepted) return;
            g_plugin_map   = [];
            g_add_queue    = [];
            g_dereg_queue  = [];
            g_next_isn     = 1;
            g_last_ping_unix      = llGetUnixTime();
            g_last_inv_sweep_unix = g_last_ping_unix;
            solicit_plugin_register();
            broadcast_plugin_list();
            return;
        }
        if (num == K_PLUGIN_SOFT_RESET) {
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == MSG_SOFT_RESET) {
                if (json_has(str, ["context"])) {
                    string ctx = llJsonGetValue(str, ["context"]);
                    integer now = llGetUnixTime();
                    if (!map_set_last_seen(ctx, now)) {
                        string j = llList2Json(JSON_OBJECT, []);
                        j = llJsonSetValue(j, ["type"], MSG_REGISTER_NOW);
                        j = llJsonSetValue(j, ["script"], ctx);
                        llMessageLinked(LINK_SET, K_PLUGIN_REG_QUERY, j, NULL_KEY);
                    }
                }
            }
            return;
        }
        if (num == K_PLUGIN_REG_REPLY) {
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == MSG_REGISTER) {
                string  ctx     = llJsonGetValue(str, ["context"]);
                integer sn      = (integer)llJsonGetValue(str, ["sn"]);
                string  label   = llJsonGetValue(str, ["label"]);
                integer min_acl = (integer)llJsonGetValue(str, ["min_acl"]);
                string  script  = "";
                if (json_has(str, ["script"])) script = llJsonGetValue(str, ["script"]);
                queue_register(ctx, sn, label, min_acl, script);
            }
            return;
        }
        if (num == K_PLUGIN_DEREG) {
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == MSG_DEREGISTER) {
                if (json_has(str, ["context"])) {
                    string ctx = llJsonGetValue(str, ["context"]);
                    queue_deregister(ctx);
                }
            }
            return;
        }
        if (num == K_PLUGIN_PONG) {
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == MSG_PONG) {
                if (json_has(str, ["context"])) {
                    string ctx = llJsonGetValue(str, ["context"]);
                    integer now = llGetUnixTime();
                    map_set_last_seen(ctx, now);
                }
            }
            return;
        }
    }

    timer() {
        if (g_registering) {
            process_next_add();
            return;
        }
        if (g_deregistering) {
            process_next_dereg();
            return;
        }
        integer now = llGetUnixTime();
        if (now - g_last_ping_unix >= (integer)PING_INTERVAL) {
            send_ping_all();
            g_last_ping_unix = now;
        }
        if (now - g_last_inv_sweep_unix >= (integer)INV_SWEEP_INTERVAL) {
            inventory_sweep_and_prune_if_both_dead();
            g_last_inv_sweep_unix = now;
        }
    }

    changed(integer change) {
        if (change & CHANGED_INVENTORY) {
            inventory_sweep_and_prune_if_both_dead();
            solicit_plugin_register();
        }
        if (change & CHANGED_OWNER) {
            reset_if_owner_changed();
        }
    }
}
