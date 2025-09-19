/* =============================================================
   MODULE: ds_collar_kernel.lsl
   ROLE  : Orchestrator (registration, heartbeat, soft-reset)
           - Accepts module registration and "ready"
           - 30s heartbeat ping (−1120) and pong (−1121) tracking
           - Broadcasts soft_reset (−1103) and system_ready (−1001)
           - Emits system_ready when MVP set is ready:
             { auth, acl, settings, ui_backend, ui_frontend }
   NOTES :
     • API comes later. For now, modules send directly on domain lanes.
     • When API is introduced, it will forward to the SAME lanes; kernel
       does not need to change.
   CONSTRAINTS:
     • No ternary, no break/continue
     • PascalCase globals; ALL_CAPS constants; locals lowercase
     • LSL reserved identifiers not used as variable names
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[KERNEL] " + s); return 0; }

/* ---------- ABI version ---------- */
integer ABI_VERSION = 1;

/* ---------- Link-message channels (negative 4-digit, frozen) ---------- */
integer L_API                   = -1000; /* (Ingress for future API) */
integer L_BROADCAST             = -1001; /* system announcements */

integer L_REG_REGISTER          = -1100; /* register */
integer L_REG_REGISTER_ACK      = -1101; /* register_ack */
integer L_REG_READY             = -1102; /* ready */
integer L_REG_SOFT_RESET        = -1103; /* soft_reset */

integer L_HEARTBEAT_PING        = -1120; /* ping (kernel→all) */
integer L_HEARTBEAT_PONG        = -1121; /* pong (modules→kernel) */

integer L_KERNEL_CTRL           = -1200; /* reserved internal ctrl */

integer L_SETTINGS_GET          = -1300;
integer L_SETTINGS_SNAPSHOT     = -1301;
integer L_SETTINGS_SET          = -1302;
integer L_SETTINGS_ACK          = -1303;
integer L_SETTINGS_LIST_ADD     = -1304;
integer L_SETTINGS_LIST_REMOVE  = -1305;
integer L_SETTINGS_SYNC         = -1306;

integer L_AUTH_QUERY            = -1400;
integer L_AUTH_RESULT           = -1401;

integer L_ACL_VIS_QUERY         = -1500;
integer L_ACL_VIS_RESULT        = -1501;

integer L_UI_BE_TOUCH           = -1600;
integer L_UI_BE_CLICK           = -1601;

integer L_UI_FE_RENDER          = -1700;
integer L_UI_FE_CLOSE           = -1701;

integer L_IDENTITY_UPDATE       = -1800;

integer L_LOG_LOG               = -1900;
integer L_LOG_ERROR             = -1901;

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
float   TIMER_TICK_SEC    = 1.0;  /* driver tick */

/* ---------- Internal State ---------- */
list    ModuleMap;        /* stride 5: [id, lastPong, isReady, abi, ver] */
integer LastPingUnix;

/* ---------- Helpers ---------- */
integer now(){ return llGetUnixTime(); }
integer stride(){ return 5; }

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
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_SOFT_RESET);
    j = llJsonSetValue(j, ["from"], "kernel");
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    j = llJsonSetValue(j, ["reason"], reason);
    llMessageLinked(LINK_SET, L_REG_SOFT_RESET, j, NULL_KEY);
    return 0;
}

integer emit_system_ready(){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_SYSTEM_READY);
    j = llJsonSetValue(j, ["from"], "kernel");
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    llMessageLinked(LINK_SET, L_BROADCAST, j, NULL_KEY);
    logd("Broadcast: system_ready");
    return 0;
}

integer send_ping(){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_PING);
    j = llJsonSetValue(j, ["from"], "kernel");
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    llMessageLinked(LINK_SET, L_HEARTBEAT_PING, j, NULL_KEY);
    return 0;
}

integer ack_register(string toMod, integer ok){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_REGISTER_ACK);
    j = llJsonSetValue(j, ["from"], "kernel");
    j = llJsonSetValue(j, ["to"], toMod);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    j = llJsonSetValue(j, ["ok"], (string)ok);
    llMessageLinked(LINK_SET, L_REG_REGISTER_ACK, j, NULL_KEY);
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
        if (num == L_REG_REGISTER){
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != TYPE_REGISTER) return;
            if (!json_has(msg, ["from"])) return;

            string mod = llJsonGetValue(msg, ["from"]);
            integer abi = ABI_VERSION;
            if (json_has(msg, ["abi"])) abi = (integer)llJsonGetValue(msg, ["abi"]);
            string ver = "";
            if (json_has(msg, ["module_ver"])) ver = llJsonGetValue(msg, ["module_ver"]);

            if (abi != ABI_VERSION){
                logd("ABI mismatch from " + mod + " (" + (string)abi + ")");
                ack_register(mod, FALSE);
                return;
            }
            module_upsert(mod, abi, ver);
            ack_register(mod, TRUE);
            return;
        }

        if (num == L_REG_READY){
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != TYPE_READY) return;
            if (!json_has(msg, ["from"])) return;

            string mod = llJsonGetValue(msg, ["from"]);
            if (module_mark_ready(mod)){
                if (all_mvp_ready()){
                    emit_system_ready();
                }
            }
            return;
        }

        if (num == L_REG_SOFT_RESET){
            integer ok = FALSE;
            if (json_has(msg, ["type"])){
                if (llJsonGetValue(msg, ["type"]) == TYPE_SOFT_RESET) ok = TRUE;
            }
            if (!ok) return;
            emit_soft_reset("requested");
            return;
        }

        if (num == L_HEARTBEAT_PONG){
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != TYPE_PONG) return;
            if (!json_has(msg, ["from"])) return;

            string mod = llJsonGetValue(msg, ["from"]);
            module_mark_pong(mod);
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
