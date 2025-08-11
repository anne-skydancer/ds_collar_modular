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

integer DEBUG = TRUE;

/* ---------- Fixed link numbers ---------- */
integer K_PLUGIN_REG_QUERY     = 500; // Kernel → Plugins: {"type":"register_now","script":"name"}
integer K_PLUGIN_REG_REPLY     = 501; // Plugins → Kernel : {"type":"register","sn","label","min_acl","context","script"?}
integer K_PLUGIN_DEREG         = 502; // Any    → Kernel : {"type":"deregister","context"}
integer K_SOFT_RESET           = 503; // Any    → Kernel : "kernel_soft_reset" or {"type":"kernel_soft_reset"}

integer K_PLUGIN_LIST          = 600; // Kernel → All     : {"type":"plugin_list","plugins":[{...}]}
integer K_PLUGIN_LIST_REQUEST  = 601; // UI     → Kernel  : (empty) snapshot request

/* Heartbeat link numbers */
integer K_PLUGIN_PING          = 650; // Kernel → Plugins : {"type":"ping","context","ts"}
integer K_PLUGIN_PONG          = 651; // Plugins → Kernel : {"type":"pong","context","ts"}

/* ---------- Settings (reserved, pass-through if you later need) ---------- */
integer K_SETTINGS_QUERY       = 800;
integer K_SETTINGS_SYNC        = 870;

/* ---------- Heartbeat settings ---------- */
float   PING_INTERVAL        = 5.0;   // seconds between pings
integer PING_TIMEOUT         = 15;    // seconds since last pong to consider stale
float   INV_SWEEP_INTERVAL   = 3.0;   // seconds between inventory sweeps

/* ---------- Internal State ---------- */
/* g_plugin_map layout per entry:
   [0]=context, [1]=isn, [2]=sn, [3]=label, [4]=min_acl, [5]=script, [6]=last_seen_unix
*/
list    g_plugin_map   = [];
integer g_next_isn     = 1;

/* Queues are serialized; only one of them runs at a time */
list    g_add_queue    = []; // [context, sn, label, min_acl, script]
list    g_dereg_queue  = []; // [context]

integer g_registering   = FALSE;
integer g_deregistering = FALSE;

/* Heartbeat timers */
integer g_last_ping_unix      = 0;
integer g_last_inv_sweep_unix = 0;

/* ---------- JSON helpers ---------- */
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* ---------- Debug helper ---------- */
logd(string s) { if (DEBUG) llOwnerSay("[KERNEL] " + s); }

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
    /* field 5 */
    return llList2String(g_plugin_map, idx + 5);
}

integer map_set_last_seen(string ctx, integer when) {
    integer idx = map_index_from_context(ctx);
    if (idx == -1) return FALSE;
    g_plugin_map = llListReplaceList(g_plugin_map, [ llList2String(g_plugin_map, idx),         // ctx
                                                     llList2Integer(g_plugin_map, idx+1),      // isn
                                                     llList2Integer(g_plugin_map, idx+2),      // sn
                                                     llList2String (g_plugin_map, idx+3),      // label
                                                     llList2Integer(g_plugin_map, idx+4),      // min_acl
                                                     llList2String (g_plugin_map, idx+5),      // script
                                                     when ], idx, idx+6);
    return TRUE;
}

/* ---------- Registry Functions (serialized) ---------- */
integer queue_register(string ctx, integer sn, string label, integer min_acl, string script) {
    if (map_index_from_context(ctx) != -1) return FALSE;             // already present
    if (llListFindList(g_add_queue, [ctx]) != -1) return FALSE;      // already queued
    g_add_queue += [ ctx, sn, label, min_acl, script ];
    g_registering = TRUE;
    return TRUE;
}

integer queue_deregister(string ctx) {
    if (map_index_from_context(ctx) == -1) return FALSE;             // not present
    if (llListFindList(g_dereg_queue, [ctx]) != -1) return FALSE;    // already queued
    g_dereg_queue += [ ctx ];
    g_deregistering = TRUE;
    return TRUE;
}

process_next_add() {
    if (llGetListLength(g_add_queue) == 0) {
        if (g_registering) {
            g_registering = FALSE;
            broadcast_plugin_list();
        }
        return;
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
        /* refresh label/min_acl/sn/script while preserving isn; update last_seen */
        integer old_isn = llList2Integer(g_plugin_map, idx+1);
        if (script == "") script = llList2String(g_plugin_map, idx+5);

        g_plugin_map = llListReplaceList(g_plugin_map, [ ctx, old_isn, sn, label, min_acl, script, now ], idx, idx+6);
        logd("Refreshed: ctx=" + ctx + " isn=" + (string)old_isn);
    }
}

process_next_dereg() {
    if (llGetListLength(g_dereg_queue) == 0) {
        if (g_deregistering) {
            g_deregistering = FALSE;
            broadcast_plugin_list();
        }
        return;
    }

    string ctx = llList2String(g_dereg_queue, 0);
    g_dereg_queue = llDeleteSubList(g_dereg_queue, 0, 0);

    integer idx = map_index_from_context(ctx);
    if (idx != -1) {
        /* Inform others (optional – keep for symmetry) */
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"], "deregister");
        j = llJsonSetValue(j, ["context"], ctx);
        llMessageLinked(LINK_SET, K_PLUGIN_DEREG, j, NULL_KEY);

        g_plugin_map = llDeleteSubList(g_plugin_map, idx, idx + 6);
        logd("Deregistered: " + ctx);
    }
}

/* ---------- Heartbeat ---------- */
send_ping_all() {
    integer stride = map_stride();
    integer i = 0;
    integer L = llGetListLength(g_plugin_map);
    integer now = llGetUnixTime();

    while (i < L) {
        string ctx = llList2String(g_plugin_map, i);
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"], "plugin_ping");
        j = llJsonSetValue(j, ["context"], ctx);
        j = llJsonSetValue(j, ["ts"], (string)now);
        llMessageLinked(LINK_SET, K_PLUGIN_PING, j, NULL_KEY);
        i += stride;
    }
}

inventory_sweep_and_prune_if_both_dead() {
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

        integer has_pong = FALSE;
        if ((now - last) <= PING_TIMEOUT) has_pong = TRUE;

        if (!has_inv && !has_pong) {
            /* both dead -> drop it */
            logd("Heartbeat failed (inv+pong) → remove: " + ctx);
            g_plugin_map = llDeleteSubList(g_plugin_map, i, i+6);
            L -= stride;
            any_removed = TRUE;
            /* do not advance i here; list has shifted */
        } else {
            i += stride;
        }
    }

    if (any_removed) broadcast_plugin_list();
}

/* ---------- Broadcast Plugin List ---------- */
broadcast_plugin_list() {
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
    j = llJsonSetValue(j, ["type"], "plugin_list");
    j = llJsonSetValue(j, ["plugins"], llList2Json(JSON_ARRAY, arr));
    llMessageLinked(LINK_SET, K_PLUGIN_LIST, j, NULL_KEY);
}

/* ---------- Registration Solicitation ---------- */
solicit_plugin_register() {
    integer n = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i;
    for (i = 0; i < n; ++i) {
        string script_name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (script_name != llGetScriptName()) {
            if (llSubStringIndex(script_name, "ds_collar_plugin_") == 0) {
                string j = llList2Json(JSON_OBJECT, []);
                j = llJsonSetValue(j, ["type"],   "register_now");
                j = llJsonSetValue(j, ["script"], script_name);
                llMessageLinked(LINK_SET, K_PLUGIN_REG_QUERY, j, NULL_KEY);
            }
        }
    }
}

/* =============================================================
   MAIN
   ============================================================= */
default
{
    state_entry() {
        g_plugin_map   = [];
        g_add_queue    = [];
        g_dereg_queue  = [];
        g_next_isn     = 1;

        g_last_ping_unix      = llGetUnixTime();
        g_last_inv_sweep_unix = g_last_ping_unix;

        solicit_plugin_register();
        llSetTimerEvent(0.2);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        /* UI snapshot */
        if (num == K_PLUGIN_LIST_REQUEST) {
            broadcast_plugin_list();
            return;
        }

        /* Soft reset */
        if (num == K_SOFT_RESET) {
            integer accepted = FALSE;
            if (str == "kernel_soft_reset") accepted = TRUE;
            else if (json_has(str, ["type"])) {
                if (llJsonGetValue(str, ["type"]) == "kernel_soft_reset") accepted = TRUE;
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

        /* Register reply from plugin */
        if (num == K_PLUGIN_REG_REPLY) {
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == "register") {
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

        /* Dereg requests */
        if (num == K_PLUGIN_DEREG) {
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == "deregister") {
                if (json_has(str, ["context"])) {
                    string ctx = llJsonGetValue(str, ["context"]);
                    queue_deregister(ctx);
                }
            }
            return;
        }

        /* Plugin pong heartbeat */
        if (num == K_PLUGIN_PONG) {
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == "plugin_pong") {
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
        /* Serialize queues first */
        if (g_registering) {
            process_next_add();
            return;
        }
        if (g_deregistering) {
            process_next_dereg();
            return;
        }

        /* Heartbeats only when not mutating registry */
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
            /* Opportunistic resync */
            inventory_sweep_and_prune_if_both_dead();
            solicit_plugin_register();
        }
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
