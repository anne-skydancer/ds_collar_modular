/* =============================================================
   MODULE: ds_collar_kernel.lsl
   ROLE  : Orchestrator (registration, heartbeat, soft-reset)
           - Accepts module registration and "ready" on the API lane
           - 30s heartbeat ping/pong tracking via API broadcast
           - Broadcasts soft_reset and system_ready via API routing
           - Emits system_ready when MVP set is ready:
             { auth, acl, settings, ui_backend, ui_frontend }
   NOTES :
     • Modules are expected to communicate via the API router (-1000).
   CONSTRAINTS:
     • No ternary, no break/continue
     • PascalCase globals; ALL_CAPS constants; locals lowercase
     • LSL reserved identifiers not used as variable names
   ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[KERNEL] " + s); return 0; }

/* ---------- ABI version ---------- */
integer ABI_VERSION = 1;

/* ---------- Link-message channels (negative 4-digit, frozen) ---------- */
integer L_API                   = -1000; /* API ingress lane */

/* ---------- Message "type" strings (canonical) ---------- */
string TYPE_REGISTER            = "register";
string TYPE_REGISTER_ACK        = "register_ack";
string TYPE_READY               = "ready";
string TYPE_SOFT_RESET          = "soft_reset";

string TYPE_PING                = "ping";
string TYPE_PONG                = "pong";

string TYPE_SETTINGS_GET        = "settings_get";
string TYPE_SETTINGS_SNAPSHOT   = "settings_snapshot";
string TYPE_SETTINGS_SET        = "settings_set";
string TYPE_SETTINGS_ACK        = "settings_ack";
string TYPE_SETTINGS_SYNC       = "settings_sync";
string TYPE_LIST_ADD            = "list_add";
string TYPE_LIST_REMOVE         = "list_remove";

string TYPE_ACL_QUERY           = "acl_query";
string TYPE_ACL_RESULT          = "acl_result";
string TYPE_ACL_VIS_QUERY       = "acl_visibility_query";
string TYPE_ACL_VIS_RESULT      = "acl_visibility_result";

string TYPE_UI_TOUCH            = "ui_touch";
string TYPE_UI_CLICK            = "ui_click";
string TYPE_UI_RENDER           = "ui_render";
string TYPE_UI_CLOSE            = "ui_close";

string TYPE_DISPLAY_NAME_UPDATE = "display_name_update";

string TYPE_LOG                 = "log";
string TYPE_ERROR               = "error";

string TYPE_SYSTEM_READY        = "system_ready";

/* ---------- MVP module identifiers (who must be "ready") ---------- */
string MOD_AUTH       = "auth";
string MOD_ACL        = "acl";
string MOD_SETTINGS   = "settings";
string MOD_UI_BE      = "ui_backend";
string MOD_UI_FE      = "ui_frontend";
string MOD_BOOTSTRAP  = "bootstrap";
string MOD_API        = "api";

/* ---------- Timing ---------- */
integer HB_INTERVAL_SEC   = 30;   /* heartbeat ping cadence */
integer HB_PONG_TIMEOUT_S = 60;   /* stale module timeout */
float   TIMER_TICK_SEC    = 5.0;  /* driver tick */

/* ---------- Internal State ---------- */
list    ModuleMap;        /* stride 5: [id, lastPong, isReady, abi, ver] */
integer LastPingUnix;

/* ---------- Helpers ---------- */
integer now(){ return llGetUnixTime(); }
integer stride(){ return 5; }

integer send_kernel_message(string type, string to, list kv){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], type);
    j = llJsonSetValue(j, ["from"], "kernel");
    if (to != "") j = llJsonSetValue(j, ["to"], to);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    integer i = 0;
    integer n = llGetListLength(kv);
    while (i + 1 < n){
        string k = llList2String(kv, i);
        string v = llList2String(kv, i + 1);
        j = llJsonSetValue(j, [k], v);
        i += 2;
    }
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

integer json_has(string j, list path){
    if (llJsonGetValue(j, path) == JSON_INVALID) return FALSE;
    return TRUE;
}

integer idx_of_module(string modId){
    integer s = stride();
    integer i = 0;
    integer n = llGetListLength(ModuleMap);
    while (i < n){
        string id = llList2String(ModuleMap, i);
        if (id == modId) return i;
        i += s;
    }
    return -1;
}

integer module_upsert(string modId, integer abi, string ver){
    integer i = idx_of_module(modId);
    integer t = now();
    if (i == -1){
        ModuleMap += [modId, t, 0, abi, ver];
        logd("Registered: " + modId + " abi=" + (string)abi + " ver=" + ver);
        return TRUE;
    }
    else {
        integer ready = llList2Integer(ModuleMap, i+2);
        ModuleMap = llListReplaceList(ModuleMap, [modId, t, ready, abi, ver], i, i+4);
        logd("Refreshed: " + modId);
        return TRUE;
    }
}

integer module_mark_ready(string modId){
    integer i = idx_of_module(modId);
    if (i == -1) return FALSE;
    ModuleMap = llListReplaceList(ModuleMap, [
        llList2String(ModuleMap, i),
        llList2Integer(ModuleMap, i+1),
        1,
        llList2Integer(ModuleMap, i+3),
        llList2String(ModuleMap, i+4)
    ], i, i+4);
    logd("Ready: " + modId);
    return TRUE;
}

integer module_mark_pong(string modId){
    integer i = idx_of_module(modId);
    if (i == -1) return FALSE;
    ModuleMap = llListReplaceList(ModuleMap, [
        llList2String(ModuleMap, i),
        now(),
        llList2Integer(ModuleMap, i+2),
        llList2Integer(ModuleMap, i+3),
        llList2String(ModuleMap, i+4)
    ], i, i+4);
    return TRUE;
}

integer module_is_ready(string modId){
    integer i = idx_of_module(modId);
    if (i == -1) return FALSE;
    return llList2Integer(ModuleMap, i+2);
}

integer all_mvp_ready(){
    if (!module_is_ready(MOD_AUTH)) return FALSE;
    if (!module_is_ready(MOD_ACL)) return FALSE;
    if (!module_is_ready(MOD_SETTINGS)) return FALSE;
    if (!module_is_ready(MOD_UI_BE)) return FALSE;
    if (!module_is_ready(MOD_UI_FE)) return FALSE;
    return TRUE;
}

integer prune_dead_modules(){
    integer removed = FALSE;
    integer s = stride();
    integer i = 0;
    integer n = llGetListLength(ModuleMap);
    integer t = now();
    while (i < n){
        string id = llList2String(ModuleMap, i);
        integer last = llList2Integer(ModuleMap, i+1);
        integer stale = FALSE;
        if ((t - last) > HB_PONG_TIMEOUT_S) stale = TRUE;
        if (stale){
            logd("Prune stale module: " + id);
            ModuleMap = llDeleteSubList(ModuleMap, i, i+4);
            n -= s;
            removed = TRUE;
        }
        else {
            i += s;
        }
    }
    return removed;
}

/* ---------- Outbound helpers ---------- */
integer emit_soft_reset(string reason){
    send_kernel_message(TYPE_SOFT_RESET, "any", ["reason", reason]);
    return 0;
}

integer emit_system_ready(){
    send_kernel_message(TYPE_SYSTEM_READY, "any", []);
    logd("Broadcast: system_ready");
    return 0;
}

integer send_ping(){
    send_kernel_message(TYPE_PING, "any", []);
    return 0;
}

integer ack_register(string toMod, integer ok){
    send_kernel_message(TYPE_REGISTER_ACK, toMod, ["ok", (string)ok]);
    return 0;
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        ModuleMap = [];
        LastPingUnix = now();
        llSetTimerEvent(TIMER_TICK_SEC);

        /* emit_soft_reset("kernel_start"); optional */
        logd("Kernel up. ABI=" + (string)ABI_VERSION + " HB=" + (string)HB_INTERVAL_SEC + "s");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer sender, integer num, string msg, key id){
        if (num != L_API) return;
        if (!json_has(msg, ["type"])) return;

        string type = llJsonGetValue(msg, ["type"]);
        string from = "";
        if (json_has(msg, ["from"])) from = llJsonGetValue(msg, ["from"]);
        string to = "";
        if (json_has(msg, ["to"])) to = llJsonGetValue(msg, ["to"]);

        if (from == "kernel") return; /* ignore our own broadcasts */
        if (to != "kernel") return;

        if (type == TYPE_REGISTER){
            if (from == "") return;
            integer abi = ABI_VERSION;
            if (json_has(msg, ["abi"])) abi = (integer)llJsonGetValue(msg, ["abi"]);
            string ver = "";
            if (json_has(msg, ["module_ver"])) ver = llJsonGetValue(msg, ["module_ver"]);

            if (abi != ABI_VERSION){
                logd("ABI mismatch from " + from + " (" + (string)abi + ")");
                ack_register(from, FALSE);
                return;
            }
            module_upsert(from, abi, ver);
            ack_register(from, TRUE);
            return;
        }

        if (type == TYPE_READY){
            if (from == "") return;
            if (module_mark_ready(from)){
                if (all_mvp_ready()){
                    emit_system_ready();
                }
            }
            return;
        }

        if (type == TYPE_SOFT_RESET){
            emit_soft_reset("requested");
            return;
        }

        if (type == TYPE_PONG){
            if (from == "") return;
            module_mark_pong(from);
            return;
        }
    }

    timer(){
        integer t = now();
        if ((t - LastPingUnix) >= HB_INTERVAL_SEC){
            send_ping();
            LastPingUnix = t;
        }
        if (prune_dead_modules()){
            /* lost module → no auto system_ready re-broadcast */
        }
    }
}
