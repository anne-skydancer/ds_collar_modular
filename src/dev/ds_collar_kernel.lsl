/* =============================================================
   MODULE: ds_collar_kernel.lsl (Development)
   PURPOSE: Kernel orchestrator for modular D/s collar builds.
            - Tracks plugin registration and heartbeat
            - Broadcasts plugin lists to UI controllers
            - Handles soft resets and stale plugin cleanup
   NOTES  : Written to comply with AGENTS.md guidance (no ternary,
            no break/continue, single timer, event-driven flow).
   ============================================================= */

integer DEBUG = FALSE;
string  LOG_PREFIX = "[DEV/KERNEL] ";

integer logd(string msg)
{
    if (DEBUG)
    {
        llOwnerSay(LOG_PREFIX + msg);
    }
    return FALSE;
}

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY    = -1500;  // Kernel → Plugins
integer K_PLUGIN_REG_REPLY    = -1501;  // Plugins → Kernel
integer K_PLUGIN_DEREG        = -1502;  // Any    → Kernel
integer K_SOFT_RESET          = -1503;  // Any    → Kernel
integer K_PLUGIN_SOFT_RESET   = -1504;  // Plugins → Kernel
integer K_PLUGIN_LIST         = -1600;  // Kernel → All
integer K_PLUGIN_LIST_REQUEST = -1601;  // Any    → Kernel
integer K_PLUGIN_PING         = -1650;  // Kernel → Plugins
integer K_PLUGIN_PONG         = -1651;  // Plugins → Kernel

/* ---------- Protocol strings ---------- */
string MSG_REGISTER             = "register";
string MSG_REGISTER_NOW         = "register_now";
string MSG_DEREGISTER           = "deregister";
string MSG_KERNEL_SOFT_RST      = "kernel_soft_reset";
string MSG_PLUGIN_SOFT_RST      = "plugin_soft_reset";
string MSG_PLUGIN_LIST          = "plugin_list";
string MSG_REGISTER_ACK         = "register_ack";
string MSG_PLUGIN_PING          = "plugin_ping";
string MSG_PLUGIN_PONG          = "plugin_pong";

/* ---------- Queue orchestration ---------- */
string OP_QUEUE_REGISTER        = "register";
string OP_QUEUE_DEREGISTER      = "deregister";

list    PendingOps;                  // stride 2: [op_type, json_payload]
integer QueueBusy;

/* ---------- Timing ---------- */
float   TIMER_INTERVAL_SEC      = 5.0;   // single timer driver
integer PING_INTERVAL_SEC       = 30;    // heartbeat cadence
integer PONG_TIMEOUT_SEC        = 90;    // mark stale after silence

/* ---------- Internal state ---------- */
integer PLUGIN_STRIDE = 5;
list    PluginMap;                   // stride 5: [ctx,label,min_acl,script,last_seen]
integer LastPingUnix;
key     LastOwner;

/* ---------- JSON helper ---------- */
integer json_has(string json, list path) {
    string value = llJsonGetValue(json, path);
    if (value == JSON_INVALID) return FALSE;
    return TRUE;
}

/* ---------- Time helper ---------- */
integer now() { return llGetUnixTime(); }

/* ---------- Map helpers ---------- */
integer map_stride()
{
    return PLUGIN_STRIDE;
}


integer map_index_from_context(string ctx)
{
    integer stride = map_stride();
    integer idx = 0;
    integer length = llGetListLength(PluginMap);
    while (idx < length)
    {
        string current = llList2String(PluginMap, idx);
        if (current == ctx) return idx;
        idx += stride;
    }
    return -1;
}

integer map_upsert(string ctx, string label, integer min_acl, string script, integer seen)
{
    if (ctx == "") return FALSE;
    if (label == "") label = ctx;
    if (script == "") script = ctx;

    integer idx = map_index_from_context(ctx);
    if (idx == -1)
    {
        PluginMap += [ctx, label, min_acl, script, seen];
        logd("Registered plugin: " + ctx);
        return TRUE;
    }

    PluginMap = llListReplaceList(
        PluginMap,
        [ctx, label, min_acl, script, seen],
        idx,
        idx + map_stride() - 1);
    logd("Refreshed plugin: " + ctx);
    return TRUE;
}

integer map_touch(string ctx, integer seen)
{
    integer idx = map_index_from_context(ctx);
    if (idx == -1) return FALSE;
    PluginMap = llListReplaceList(
        PluginMap,
        [
            llList2String(PluginMap, idx),
            llList2String(PluginMap, idx + 1),
            llList2Integer(PluginMap, idx + 2),
            llList2String(PluginMap, idx + 3),
            seen
        ],
        idx,
        idx + map_stride() - 1);
    return TRUE;
}

integer map_remove(string ctx)
{
    integer idx = map_index_from_context(ctx);
    if (idx == -1) return FALSE;
    PluginMap = llDeleteSubList(PluginMap, idx, idx + map_stride() - 1);
    logd("Removed plugin: " + ctx);
    return TRUE;
}

string build_plugin_list_payload()
{
    string root = llList2Json(JSON_OBJECT, []);
    string arr = llList2Json(JSON_ARRAY, []);

    integer stride = map_stride();
    integer idx = 0;
    integer length = llGetListLength(PluginMap);
    integer slot = 0;

    while (idx < length)
    {
        string entry = llList2Json(JSON_OBJECT, []);
        entry = llJsonSetValue(entry, ["context"], llList2String(PluginMap, idx));
        entry = llJsonSetValue(entry, ["label"], llList2String(PluginMap, idx + 1));
        entry = llJsonSetValue(entry, ["min_acl"], (string)llList2Integer(PluginMap, idx + 2));
        entry = llJsonSetValue(entry, ["script"], llList2String(PluginMap, idx + 3));
        entry = llJsonSetValue(entry, ["last_seen"], (string)llList2Integer(PluginMap, idx + 4));
        arr = llJsonSetValue(arr, [slot], entry);
        slot += 1;
        idx += stride;
    }

    root = llJsonSetValue(root, ["type"], MSG_PLUGIN_LIST);
    root = llJsonSetValue(root, ["plugins"], arr);
    return root;
}

integer emit_plugin_list()
{
    string payload = build_plugin_list_payload();
    llMessageLinked(LINK_SET, K_PLUGIN_LIST, payload, NULL_KEY);
    return TRUE;
}

integer send_register_ack(string ctx, string script, integer ok, string message)
{
    string payload = llList2Json(JSON_OBJECT, []);
    payload = llJsonSetValue(payload, ["type"], MSG_REGISTER_ACK);
    payload = llJsonSetValue(payload, ["context"], ctx);
    payload = llJsonSetValue(payload, ["ok"], (string)ok);
    if (script != "") payload = llJsonSetValue(payload, ["script"], script);
    if (message != "") payload = llJsonSetValue(payload, ["message"], message);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_QUERY, payload, NULL_KEY);
    return TRUE;
}

integer broadcast_register_now(string reason, string script)
{
    string payload = llList2Json(JSON_OBJECT, []);
    payload = llJsonSetValue(payload, ["type"], MSG_REGISTER_NOW);
    if (reason != "") payload = llJsonSetValue(payload, ["reason"], reason);
    if (script != "") payload = llJsonSetValue(payload, ["script"], script);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_QUERY, payload, NULL_KEY);
    logd("Register prompt → " + reason + " target=" + script);
    return TRUE;
}

integer send_ping(integer stamp)
{
    string payload = llList2Json(JSON_OBJECT, []);
    payload = llJsonSetValue(payload, ["type"], MSG_PLUGIN_PING);
    payload = llJsonSetValue(payload, ["stamp"], (string)stamp);
    llMessageLinked(LINK_SET, K_PLUGIN_PING, payload, NULL_KEY);
    return TRUE;
}

integer prune_stale_plugins(integer stamp)
{
    list stale = [];
    integer stride = map_stride();
    integer idx = 0;
    integer length = llGetListLength(PluginMap);

    while (idx < length)
    {
        string ctx = llList2String(PluginMap, idx);
        integer last = llList2Integer(PluginMap, idx + 4);
        if (last != 0)
        {
            integer delta = stamp - last;
            if (delta >= PONG_TIMEOUT_SEC)
            {
                stale += [ctx];
            }
        }
        idx += stride;
    }

    integer removed = FALSE;
    integer count = llGetListLength(stale);
    integer i = 0;
    while (i < count)
    {
        string ctx = llList2String(stale, i);
        integer map_idx = map_index_from_context(ctx);
        string script = "";
        if (map_idx != -1)
        {
            script = llList2String(PluginMap, map_idx + 3);
            PluginMap = llDeleteSubList(PluginMap, map_idx, map_idx + stride - 1);
            removed = TRUE;
            logd("Pruned stale plugin: " + ctx);
        }
        broadcast_register_now("stale", script);
        i += 1;
    }

    if (removed) emit_plugin_list();
    return removed;
}

integer handle_register(string json)
{
    if (!json_has(json, ["type"])) return FALSE;
    if (llJsonGetValue(json, ["type"]) != MSG_REGISTER) return FALSE;
    if (!json_has(json, ["context"])) return FALSE;

    string ctx = llJsonGetValue(json, ["context"]);
    if (ctx == "") return FALSE;

    string label = "";
    if (json_has(json, ["label"])) label = llJsonGetValue(json, ["label"]);
    integer min_acl = 0;
    if (json_has(json, ["min_acl"])) min_acl = (integer)llJsonGetValue(json, ["min_acl"]);
    string script = "";
    if (json_has(json, ["script"])) script = llJsonGetValue(json, ["script"]);

    integer stamp = now();
    map_upsert(ctx, label, min_acl, script, stamp);
    emit_plugin_list();
    send_register_ack(ctx, script, TRUE, "registered");
    return TRUE;
}

integer handle_deregister(string json)
{
    if (!json_has(json, ["type"])) return FALSE;
    if (llJsonGetValue(json, ["type"]) != MSG_DEREGISTER) return FALSE;
    if (!json_has(json, ["context"])) return FALSE;
    string ctx = llJsonGetValue(json, ["context"]);
    if (ctx == "") return FALSE;

    integer map_idx = map_index_from_context(ctx);
    string script = "";
    if (map_idx != -1) script = llList2String(PluginMap, map_idx + 3);
    if (!map_remove(ctx)) return FALSE;
    emit_plugin_list();
    broadcast_register_now("deregister", script);
    return TRUE;
}

integer queue_stride()
{
    return 2;
}

integer queue_flush()
{
    if (QueueBusy) return FALSE;
    QueueBusy = TRUE;

    integer stride = queue_stride();
    integer length = llGetListLength(PendingOps);

    while (length >= stride)
    {
        string op_type = llList2String(PendingOps, 0);
        string payload = llList2String(PendingOps, 1);
        PendingOps = llDeleteSubList(PendingOps, 0, stride - 1);

        if (op_type == OP_QUEUE_REGISTER)
        {
            handle_register(payload);
        }
        else
        {
            if (op_type == OP_QUEUE_DEREGISTER)
            {
                handle_deregister(payload);
            }
        }

        length = llGetListLength(PendingOps);
    }

    QueueBusy = FALSE;
    return TRUE;
}

integer queue_push(string op_type, string payload)
{
    if (op_type == "" || payload == "") return FALSE;
    PendingOps += [op_type, payload];
    if (!QueueBusy)
    {
        queue_flush();
    }
    return TRUE;
}

integer handle_pong(string json)
{
    if (!json_has(json, ["type"])) return FALSE;
    if (llJsonGetValue(json, ["type"]) != MSG_PLUGIN_PONG) return FALSE;
    if (!json_has(json, ["context"])) return FALSE;
    string ctx = llJsonGetValue(json, ["context"]);
    if (ctx == "") return FALSE;

    integer stamp = now();
    if (!map_touch(ctx, stamp)) return FALSE;
    return TRUE;
}

integer handle_plugin_soft_reset(string json)
{
    if (!json_has(json, ["type"])) return FALSE;
    if (llJsonGetValue(json, ["type"]) != MSG_PLUGIN_SOFT_RST) return FALSE;
    if (!json_has(json, ["context"])) return FALSE;
    string ctx = llJsonGetValue(json, ["context"]);
    if (ctx == "") return FALSE;

    integer map_idx = map_index_from_context(ctx);
    string script = "";
    if (map_idx != -1) script = llList2String(PluginMap, map_idx + 3);
    if (map_idx != -1) map_remove(ctx);
    emit_plugin_list();
    broadcast_register_now("plugin_soft_reset", script);
    return TRUE;
}

integer perform_kernel_soft_reset(string reason)
{
    PluginMap = [];
    PendingOps = [];
    QueueBusy = FALSE;
    LastPingUnix = now();
    llSetTimerEvent(TIMER_INTERVAL_SEC);
    emit_plugin_list();
    broadcast_register_now(reason, "");
    return TRUE;
}

integer ensure_owner()
{
    key current = llGetOwner();
    if (current == NULL_KEY) return FALSE;
    if (current != LastOwner)
    {
        LastOwner = current;
        llResetScript();
        return TRUE;
    }
    return FALSE;
}

integer initialize_kernel()
{
    PluginMap = [];
    PendingOps = [];
    QueueBusy = FALSE;
    LastOwner = llGetOwner();
    LastPingUnix = now();
    llSetTimerEvent(TIMER_INTERVAL_SEC);
    broadcast_register_now("startup", "");
    return TRUE;
}

/* ---------- Events ---------- */

default
{
    state_entry()
    {
        initialize_kernel();
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }

    changed(integer change)
    {
        if (change & (CHANGED_OWNER | CHANGED_REGION))
        {
            ensure_owner();
            if (change & CHANGED_REGION)
            {
                perform_kernel_soft_reset("region_change");
            }
        }
    }

    timer()
    {
        integer stamp = now();
        integer delta = stamp - LastPingUnix;
        if (delta >= PING_INTERVAL_SEC)
        {
            send_ping(stamp);
            LastPingUnix = stamp;
        }
        prune_stale_plugins(stamp);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        if (num == K_PLUGIN_REG_REPLY)
        {
            if (str != "") queue_push(OP_QUEUE_REGISTER, str);
            return;
        }
        if (num == K_PLUGIN_DEREG)
        {
            if (str != "") queue_push(OP_QUEUE_DEREGISTER, str);
            return;
        }
        if (num == K_PLUGIN_PONG)
        {
            handle_pong(str);
            return;
        }
        if (num == K_PLUGIN_SOFT_RESET)
        {
            handle_plugin_soft_reset(str);
            return;
        }
        if (num == K_PLUGIN_LIST_REQUEST)
        {
            emit_plugin_list();
            return;
        }
        if (num == K_SOFT_RESET)
        {
            if (json_has(str, ["type"]))
            {
                if (llJsonGetValue(str, ["type"]) == MSG_KERNEL_SOFT_RST)
                {
                    string reason = "manual";
                    if (json_has(str, ["reason"])) reason = llJsonGetValue(str, ["reason"]);
                    perform_kernel_soft_reset(reason);
                }
            }
            return;
        }
    }
}
