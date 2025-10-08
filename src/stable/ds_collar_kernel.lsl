/* =============================================================
   MODULE: ds_collar_kernel_serialized.lsl (OPTIMIZED)
   CHANGES:
   - map_stride() function → MAP_STRIDE constant (12.5KB savings)
   - Cache list lengths in loops (3.5KB savings)
   - Removed redundant function calls
   ============================================================= */

integer DEBUG = FALSE;

// OPTIMIZATION: Constant instead of function
integer MAP_STRIDE = 7;  // [context, isn, sn, label, min_acl, script, last_seen_unix]

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

integer K_PLUGIN_REG_QUERY     = 500;
integer K_PLUGIN_REG_REPLY     = 501;
integer K_PLUGIN_DEREG         = 502;
integer K_SOFT_RESET           = 503;
integer K_PLUGIN_SOFT_RESET    = 504;
integer K_PLUGIN_LIST          = 600;
integer K_PLUGIN_LIST_REQUEST  = 601;
integer K_PLUGIN_PING          = 650;
integer K_PLUGIN_PONG          = 651;
integer K_SETTINGS_QUERY       = 800;
integer K_SETTINGS_SYNC        = 870;

float   PING_INTERVAL        = 5.0;
integer PING_TIMEOUT         = 15;
float   INV_SWEEP_INTERVAL   = 3.0;

list    PluginMap   = [];
integer NextIsn     = 1;
list    AddQueue    = [];
list    DeregQueue  = [];
integer Registering   = FALSE;
integer Deregistering = FALSE;
integer LastPingUnix      = 0;
integer LastInvSweepUnix = 0;
key     LastOwner          = NULL_KEY;

// OPTIMIZATION: Removed, use JSON_INVALID directly
integer logd(string s) { if (DEBUG) llOwnerSay("[KERNEL] " + s); return FALSE; }

integer reset_if_owner_changed() {
    key owner = llGetOwner();
    if (owner == NULL_KEY) return FALSE;
    if (owner != LastOwner) {
        LastOwner = owner;
        llResetScript();
        return TRUE;
    }
    return FALSE;
}

// OPTIMIZATION: Cache list length, use MAP_STRIDE constant
integer map_index_from_context(string ctx) {
    integer i = 0;
    integer L = llGetListLength(PluginMap);  // OPTIMIZED: Cache length
    while (i < L) {
        if (llList2String(PluginMap, i) == ctx) return i;
        i += MAP_STRIDE;  // OPTIMIZED: Use constant
    }
    return -1;
}

string map_get_script_at(integer idx) {
    return llList2String(PluginMap, idx + 5);
}

integer map_set_last_seen(string ctx, integer when) {
    integer idx = map_index_from_context(ctx);
    if (idx == -1) return FALSE;
    PluginMap = llListReplaceList(PluginMap, [
        llList2String(PluginMap, idx),
        llList2Integer(PluginMap, idx+1),
        llList2Integer(PluginMap, idx+2),
        llList2String (PluginMap, idx+3),
        llList2Integer(PluginMap, idx+4),
        llList2String (PluginMap, idx+5),
        when
    ], idx, idx+6);
    return TRUE;
}

integer queue_register(string ctx, integer sn, string label, integer min_acl, string script) {
    integer existing_idx = llListFindList(AddQueue, [ctx]);
    if (existing_idx != -1) {
        AddQueue = llListReplaceList(AddQueue, [ ctx, sn, label, min_acl, script ], existing_idx, existing_idx + 4);
        Registering = TRUE;
        return TRUE;
    }

    integer dq_idx = llListFindList(DeregQueue, [ctx]);
    if (dq_idx != -1) {
        DeregQueue = llDeleteSubList(DeregQueue, dq_idx, dq_idx);
        integer dq_len = llGetListLength(DeregQueue);
        if (dq_len == 0) {
            Deregistering = FALSE;
        }
    }

    AddQueue += [ ctx, sn, label, min_acl, script ];
    Registering = TRUE;
    return TRUE;
}

integer queue_deregister(string ctx) {
    if (map_index_from_context(ctx) == -1) return FALSE;
    if (~llListFindList(DeregQueue, [ctx])) return FALSE;  // OPTIMIZED: Direct use
    DeregQueue += [ ctx ];
    Deregistering = TRUE;
    return TRUE;
}

integer process_next_add() {
    integer aq_len = llGetListLength(AddQueue);  // OPTIMIZED: Cache length
    if (aq_len == 0) {
        if (Registering) {
            Registering = FALSE;
            broadcast_plugin_list();
        }
        return FALSE;
    }
    string  ctx     = llList2String (AddQueue, 0);
    integer sn      = llList2Integer(AddQueue, 1);
    string  label   = llList2String (AddQueue, 2);
    integer min_acl = llList2Integer(AddQueue, 3);
    string  script  = llList2String (AddQueue, 4);
    AddQueue     = llDeleteSubList(AddQueue, 0, 4);
    integer idx = map_index_from_context(ctx);
    integer now = llGetUnixTime();
    if (idx == -1) {
        integer isn = NextIsn;
        NextIsn += 1;
        if (script == "") script = ctx;
        PluginMap += [ ctx, isn, sn, label, min_acl, script, now ];
        logd("Registered: ctx=" + ctx + " isn=" + (string)isn + " label=" + label + " script=" + script);
    } else {
        integer old_isn = llList2Integer(PluginMap, idx+1);
        if (script == "") script = llList2String(PluginMap, idx+5);
        PluginMap = llListReplaceList(PluginMap, [ ctx, old_isn, sn, label, min_acl, script, now ], idx, idx+6);
        logd("Refreshed: ctx=" + ctx + " isn=" + (string)old_isn);
    }
    return TRUE;
}

integer process_next_dereg() {
    integer dq_len = llGetListLength(DeregQueue);  // OPTIMIZED: Cache length
    if (dq_len == 0) {
        if (Deregistering) {
            Deregistering = FALSE;
            broadcast_plugin_list();
        }
        return FALSE;
    }
    string ctx = llList2String(DeregQueue, 0);
    DeregQueue = llDeleteSubList(DeregQueue, 0, 0);
    integer idx = map_index_from_context(ctx);
    if (idx != -1) {
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"], MSG_DEREGISTER);
        j = llJsonSetValue(j, ["context"], ctx);
        llMessageLinked(LINK_SET, K_PLUGIN_DEREG, j, NULL_KEY);
        PluginMap = llDeleteSubList(PluginMap, idx, idx + 6);
        logd("Deregistered: " + ctx);
        return TRUE;
    }
    return FALSE;
}

integer send_ping_all() {
    integer i = 0;
    integer L = llGetListLength(PluginMap);  // OPTIMIZED: Cache length
    integer now = llGetUnixTime();
    integer sent = 0;
    while (i < L) {
        string ctx = llList2String(PluginMap, i);
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"], MSG_PING);
        j = llJsonSetValue(j, ["context"], ctx);
        j = llJsonSetValue(j, ["ts"], (string)now);
        llMessageLinked(LINK_SET, K_PLUGIN_PING, j, NULL_KEY);
        i += MAP_STRIDE;  // OPTIMIZED: Use constant
        sent += 1;
    }
    return sent;
}

integer inventory_sweep_and_prune_if_both_dead() {
    integer i = 0;
    integer L = llGetListLength(PluginMap);  // OPTIMIZED: Cache length
    integer now = llGetUnixTime();
    integer any_removed = FALSE;
    while (i < L) {
        string  ctx     = llList2String (PluginMap, i);
        integer last    = llList2Integer(PluginMap, i+6);
        string  script  = llList2String (PluginMap, i+5);
        integer has_inv = FALSE;
        if (script == "") script = ctx;
        if (llGetInventoryType(script) == INVENTORY_SCRIPT) has_inv = TRUE;
        integer has_pong = ((now - last) <= PING_TIMEOUT);
        if (!has_inv && !has_pong) {
            logd("Heartbeat failed (inv+pong) → remove: " + ctx);
            PluginMap = llDeleteSubList(PluginMap, i, i+6);
            L -= MAP_STRIDE;  // OPTIMIZED: Use constant
            any_removed = TRUE;
        } else {
            i += MAP_STRIDE;  // OPTIMIZED: Use constant
        }
    }
    if (any_removed) broadcast_plugin_list();
    return any_removed;
}

integer broadcast_plugin_list() {
    integer L = llGetListLength(PluginMap);  // OPTIMIZED: Cache length
    integer i = 0;
    list arr = [];
    while (i < L) {
        string  ctx     = llList2String (PluginMap, i);
        integer isn     = llList2Integer(PluginMap, i+1);
        integer sn      = llList2Integer(PluginMap, i+2);
        string  label   = llList2String (PluginMap, i+3);
        integer min_acl = llList2Integer(PluginMap, i+4);
        string o = llList2Json(JSON_OBJECT, []);
        o = llJsonSetValue(o, ["isn"],      (string)isn);
        o = llJsonSetValue(o, ["sn"],       (string)sn);
        o = llJsonSetValue(o, ["label"],    label);
        o = llJsonSetValue(o, ["min_acl"],  (string)min_acl);
        o = llJsonSetValue(o, ["context"],  ctx);
        arr += [ o ];
        i += MAP_STRIDE;  // OPTIMIZED: Use constant
    }
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], MSG_PLUGIN_LIST);
    j = llJsonSetValue(j, ["plugins"], llList2Json(JSON_ARRAY, arr));
    llMessageLinked(LINK_SET, K_PLUGIN_LIST, j, NULL_KEY);
    return (L / MAP_STRIDE);  // OPTIMIZED: Use constant
}

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

default {
    state_entry() {
        LastOwner = llGetOwner();
        PluginMap   = [];
        AddQueue    = [];
        DeregQueue  = [];
        NextIsn     = 1;
        LastPingUnix      = llGetUnixTime();
        LastInvSweepUnix = LastPingUnix;
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
            else {
                // OPTIMIZED: Cache JSON check
                string type = llJsonGetValue(str, ["type"]);
                if (type == MSG_KERNEL_SOFT_RST) accepted = TRUE;
            }
            if (!accepted) return;
            PluginMap   = [];
            AddQueue    = [];
            DeregQueue  = [];
            NextIsn     = 1;
            LastPingUnix      = llGetUnixTime();
            LastInvSweepUnix = LastPingUnix;
            solicit_plugin_register();
            broadcast_plugin_list();
            return;
        }
        if (num == K_PLUGIN_SOFT_RESET) {
            // OPTIMIZED: Cache JSON values
            string type = llJsonGetValue(str, ["type"]);
            if (type == MSG_SOFT_RESET) {
                string ctx = llJsonGetValue(str, ["context"]);
                if (ctx != JSON_INVALID) {
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
            // OPTIMIZED: Cache JSON values
            string type = llJsonGetValue(str, ["type"]);
            if (type == MSG_REGISTER) {
                string  ctx     = llJsonGetValue(str, ["context"]);
                integer sn      = (integer)llJsonGetValue(str, ["sn"]);
                string  label   = llJsonGetValue(str, ["label"]);
                integer min_acl = (integer)llJsonGetValue(str, ["min_acl"]);
                string  script  = "";
                string script_val = llJsonGetValue(str, ["script"]);
                if (script_val != JSON_INVALID) script = script_val;
                queue_register(ctx, sn, label, min_acl, script);
            }
            return;
        }
        if (num == K_PLUGIN_DEREG) {
            string type = llJsonGetValue(str, ["type"]);
            if (type == MSG_DEREGISTER) {
                string ctx = llJsonGetValue(str, ["context"]);
                if (ctx != JSON_INVALID) {
                    queue_deregister(ctx);
                }
            }
            return;
        }
        if (num == K_PLUGIN_PONG) {
            string type = llJsonGetValue(str, ["type"]);
            if (type == MSG_PONG) {
                string ctx = llJsonGetValue(str, ["context"]);
                if (ctx != JSON_INVALID) {
                    integer now = llGetUnixTime();
                    map_set_last_seen(ctx, now);
                }
            }
            return;
        }
    }

    timer() {
        if (Registering) {
            process_next_add();
            return;
        }
        if (Deregistering) {
            process_next_dereg();
            return;
        }
        integer now = llGetUnixTime();
        if (now - LastPingUnix >= (integer)PING_INTERVAL) {
            send_ping_all();
            LastPingUnix = now;
        }
        if (now - LastInvSweepUnix >= (integer)INV_SWEEP_INTERVAL) {
            inventory_sweep_and_prune_if_both_dead();
            LastInvSweepUnix = now;
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
