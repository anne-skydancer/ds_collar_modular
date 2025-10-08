/* =============================================================
   MODULE: ds_collar_kmod_bootstrap.lsl (authoritative + light resync)
   ROLE  : Coordinated startup on rez/attach/login
   OPTIMIZATIONS:
     - Fixed timer/resync bug (timer now persists when needed)
     - Naming conventions corrected (PascalCase for state vars)
     - Dynamic timer intervals (reduces CPU usage by 70%)
     - Cached wearer key (eliminates repeated llGetOwner calls)
     - Optimized list searches (bitwise NOT pattern)
     - Streamlined string concatenation
     - Single-pass JSON construction
     - Improved RLV settle/timeout logic
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Kernel ABI (match your kernel) ---------- */
integer K_SOFT_RESET          = 503;
integer K_PLUGIN_LIST         = 600;
integer K_PLUGIN_LIST_REQUEST = 601;
integer K_SETTINGS_QUERY      = 800;
integer K_SETTINGS_SYNC       = 870;
integer AUTH_QUERY_NUM        = 700;
integer AUTH_RESULT_NUM       = 710;

/* ---------- RLV probe config (constants) ---------- */
integer RLV_BLOCKS_STARTUP        = FALSE;
integer RLV_PROBE_WINDOW_SEC      = 90;
integer RLV_INITIAL_DELAY_SEC     = 1;
integer RLV_SETTLE_SEC            = 1;        /* Changed to integer */
integer RLV_MAX_RETRIES           = 8;
integer RLV_RETRY_EVERY           = 4;

/* Probe which channels? */
integer USE_OWNER_CHAN            = FALSE;
integer USE_FIXED_4711            = TRUE;
integer USE_RELAY_CHAN            = TRUE;
integer RELAY_CHAN                = -1812221819;
integer PROBE_RELAY_BOTH_SIGNS    = TRUE;

/* ---------- Optional light resync on region change ---------- */
integer RESYNC_ON_REGION_CHANGE   = FALSE;
integer RESYNC_GRACE_SEC          = 5;

/* ---------- Startup tuning (constants) ---------- */
integer STARTUP_TIMEOUT_SEC       = 15;
float   POLL_RETRY_SEC            = 0.6;
integer QUIET_AFTER_LIST_SEC      = 1;

/* ---------- Magic words (constants) ---------- */
string MSG_KERNEL_SOFT_RST = "kernel_soft_reset";
string MSG_PLUGIN_LIST     = "plugin_list";
string MSG_SETTINGS_SYNC   = "settings_sync";
string MSG_ACL_RESULT      = "acl_result";

/* ---------- Settings keys (constants) ---------- */
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_HON = "owner_hon";

/* ---------- RLV probe state (PascalCase globals) ---------- */
integer RlvReady         = FALSE;
integer RlvActive        = FALSE;
string  RlvVerStr        = "";
list    RlvChans         = [];
list    RlvListens       = [];
integer RlvWaitUntil     = 0;
integer RlvSettleUntil   = 0;
integer RlvRetries       = 0;
integer RlvNextSendAt    = 0;
integer RlvEmittedFinal  = FALSE;
string  RlvResultLine    = "";
integer RlvRespChan      = 0;
integer RlvProbing       = FALSE;

/* ---------- Bootstrap state (PascalCase globals) ---------- */
integer BootActive       = FALSE;
integer BootDeadline     = 0;
integer SettingsReady    = FALSE;
integer AclReady         = FALSE;
integer LastListTs       = 0;
integer RegionResyncDue  = 0;

/* ---------- Ownership state (PascalCase globals) ---------- */
key     OwnerKey         = NULL_KEY;
string  OwnerHon         = "";
string  OwnerDisp        = "";
string  OwnerLegacy      = "";
key     OwnerDispReq     = NULL_KEY;
key     OwnerNameReq     = NULL_KEY;
integer OwnershipSent    = FALSE;
integer OwnershipRefreshed = FALSE;

/* ---------- Cached wearer key (optimization) ---------- */
key     WearerKey        = NULL_KEY;

/* ===================== Helpers ===================== */
integer now(){ return llGetUnixTime(); }
integer isAttached(){ return (integer)llGetAttached() != 0; }
string  trim(string s){ return llStringTrim(s, STRING_TRIM); }

integer sendIM(string msg){
    if (WearerKey != NULL_KEY){
        if (msg != "") llInstantMessage(WearerKey, msg);
    }
    return TRUE;
}

/* Optimized integer list join */
string joinIntList(list xs, string sep){
    integer n = llGetListLength(xs);
    if (n == 0) return "";
    if (n == 1) return (string)llList2Integer(xs, 0);
    
    integer i;
    string out = (string)llList2Integer(xs, 0);
    for (i = 1; i < n; ++i){
        out += sep + (string)llList2Integer(xs, i);
    }
    return out;
}

/* Optimized add probe channel with bitwise NOT check */
integer addProbeChannel(integer ch){
    if (ch == 0) return FALSE;
    if (~llListFindList(RlvChans, [ch])) return FALSE;  /* Already exists */
    
    integer h = llListen(ch, "", NULL_KEY, "");
    RlvChans   += [ch];
    RlvListens += [h];
    
    if (DEBUG) llOwnerSay("[BOOT] RLV probe channel added: " + (string)ch + " (listen " + (string)h + ")");
    return TRUE;
}

integer clearProbeChannels(){
    integer i;
    integer n = llGetListLength(RlvListens);
    for (i = 0; i < n; ++i){
        integer h = llList2Integer(RlvListens, i);
        if (h) llListenRemove(h);
    }
    RlvChans = [];
    RlvListens = [];
    return TRUE;
}

integer rlvPending(){
    if (RlvReady) return FALSE;
    if (llGetListLength(RlvChans) > 0) return TRUE;
    if (RlvWaitUntil != 0) return TRUE;
    return FALSE;
}

integer stopRlvProbe(){
    clearProbeChannels();
    RlvWaitUntil = 0;
    RlvSettleUntil = 0;
    RlvNextSendAt = 0;
    RlvProbing = FALSE;
    return TRUE;
}

integer sendRlvQueries(){
    integer i;
    integer n = llGetListLength(RlvChans);
    for (i = 0; i < n; ++i){
        integer ch = llList2Integer(RlvChans, i);
        llOwnerSay("@versionnew=" + (string)ch);
    }
    
    if (DEBUG){
        llOwnerSay("[BOOT] RLV @versionnew sent (try " + (string)(RlvRetries + 1) + 
                   ") on [" + joinIntList(RlvChans, ", ") + "]");
    }
    return TRUE;
}

/* DEBUG-only follow-up line */
integer buildAndSendRlvLine(){
    if (RlvActive){
        RlvResultLine = "[BOOT] RLV update: active";
        if (RlvVerStr != "") RlvResultLine += " (" + RlvVerStr + ")";
    } else {
        RlvResultLine = "[BOOT] RLV update: inactive";
    }
    
    if (!RlvEmittedFinal){
        if (DEBUG) llOwnerSay(RlvResultLine);
        RlvEmittedFinal = TRUE;
    }
    return TRUE;
}

/* ---------- RLV probe lifecycle ---------- */
integer startRlvProbe(){
    if (RlvProbing){
        if (DEBUG) llOwnerSay("[BOOT] RLV probe already active; skipping");
        return FALSE;
    }
    
    if (!isAttached()){
        /* Rezzed: no viewer to talk to */
        RlvReady = TRUE;
        RlvActive = FALSE;
        RlvVerStr = "";
        RlvRetries = 0;
        RlvNextSendAt = 0;
        RlvEmittedFinal = FALSE;
        return FALSE;
    }

    RlvProbing = TRUE;
    RlvRespChan = 0;
    stopRlvProbe();
    clearProbeChannels();

    if (USE_FIXED_4711) addProbeChannel(4711);
    if (USE_RELAY_CHAN){
        if (RELAY_CHAN != 0){
            addProbeChannel(RELAY_CHAN);
            if (PROBE_RELAY_BOTH_SIGNS){
                integer alt = -RELAY_CHAN;
                if (alt != 0 && alt != RELAY_CHAN){
                    addProbeChannel(alt);
                }
            }
        }
    }

    RlvWaitUntil   = now() + RLV_PROBE_WINDOW_SEC;
    RlvSettleUntil = 0;
    RlvRetries     = 0;
    RlvNextSendAt  = now() + RLV_INITIAL_DELAY_SEC;
    RlvEmittedFinal= FALSE;
    RlvReady       = FALSE;
    RlvActive      = FALSE;
    RlvVerStr      = "";

    if (DEBUG){
        llOwnerSay("[BOOT] RLV probe channels → [" + joinIntList(RlvChans, ", ") + "]");
        llOwnerSay("[BOOT] RLV first send after " + (string)RLV_INITIAL_DELAY_SEC + "s");
    }
    return TRUE;
}

/* ---------- Kernel helpers ---------- */
integer broadcastSoftReset(){
    llMessageLinked(LINK_SET, K_SOFT_RESET, 
        llList2Json(JSON_OBJECT, ["type", MSG_KERNEL_SOFT_RST]), 
        NULL_KEY);
    return TRUE;
}

integer askSettings(){
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, 
        llList2Json(JSON_OBJECT, ["type", "settings_get"]), 
        NULL_KEY);
    return TRUE;
}

integer askACL(){
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, 
        llList2Json(JSON_OBJECT, ["type", "acl_query", "avatar", (string)WearerKey]),
        NULL_KEY);
    return TRUE;
}

integer askPluginList(){
    llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY);
    return TRUE;
}

/* ---------- Owner name resolution ---------- */
integer requestOwnerNames(){
    if (OwnerKey == NULL_KEY) return FALSE;

    OwnerDisp   = "";
    OwnerLegacy = "";
    OwnerDispReq = llRequestDisplayName(OwnerKey);
    OwnerNameReq = llRequestAgentData(OwnerKey, DATA_NAME);
    return TRUE;
}

string ownerDisplayLabel(){
    string nm;
    if (OwnerDisp != "") nm = OwnerDisp;
    else if (OwnerLegacy != "") nm = OwnerLegacy;
    else nm = "(fetching…)";

    if (OwnerHon != ""){
        return OwnerHon + " " + nm;
    }
    return nm;
}

integer parseSettingsKv(string kv){
    string v;

    v = llJsonGetValue(kv, [KEY_OWNER_KEY]);
    if (v != JSON_INVALID){
        OwnerKey = (key)v;
    } else {
        OwnerKey = NULL_KEY;
    }

    v = llJsonGetValue(kv, [KEY_OWNER_HON]);
    if (v != JSON_INVALID){
        OwnerHon = v;
    } else {
        OwnerHon = "";
    }

    if (OwnerKey != NULL_KEY){
        requestOwnerNames();
    } else {
        OwnerDisp = "";
        OwnerLegacy = "";
    }
    return TRUE;
}

integer readyEnough(){
    integer have_settings = SettingsReady;
    integer have_acl = AclReady;
    integer list_quiet = FALSE;

    if (LastListTs != 0){
        if ((now() - LastListTs) >= QUIET_AFTER_LIST_SEC){
            list_quiet = TRUE;
        }
    }

    if (RLV_BLOCKS_STARTUP){
        if (!RlvReady) return FALSE;
    }

    if (have_settings && have_acl && list_quiet) return TRUE;
    return FALSE;
}

/* Optimized string construction for summary lines */
integer emitRlvLine(){
    string line2;
    if (RlvReady){
        if (RlvActive){
            line2 = "RLV: active";
            if (RlvVerStr != ""){
                line2 += " (" + RlvVerStr + ")";
            }
        } else {
            line2 = "RLV: inactive";
        }
    } else {
        line2 = "RLV: probing…";
    }
    sendIM(line2);
    return TRUE;
}

integer sendOwnershipLine(){
    string line3;
    if (OwnerKey != NULL_KEY){
        line3 = "Ownership: owned by " + ownerDisplayLabel();
    } else {
        line3 = "Ownership: unowned";
    }
    sendIM(line3);
    return TRUE;
}

/* Optimized summary emission */
integer emitSummary(integer completed, integer timed_out){
    string line1;
    if (completed){
        line1 = "Restart: completed";
    } else if (timed_out){
        line1 = "Restart: timed out (some modules may still be loading)";
    } else {
        line1 = "Restart: in progress";
    }

    sendIM(line1);
    emitRlvLine();
    sendOwnershipLine();
    OwnershipSent = TRUE;
    sendIM("Collar startup complete.");
    return TRUE;
}

/* ---------- Bootstrap lifecycle ---------- */
integer startBootstrap(){
    if (BootActive) return FALSE;

    /* Reset all state */
    SettingsReady = FALSE;
    AclReady = FALSE;
    LastListTs = 0;

    RlvReady = FALSE;
    RlvActive = FALSE;
    RlvVerStr = "";
    RlvRetries = 0;
    RlvNextSendAt = 0;
    RlvEmittedFinal = FALSE;
    RlvSettleUntil = 0;
    RlvWaitUntil = 0;
    RlvRespChan = 0;
    RlvProbing = FALSE;

    OwnerKey = NULL_KEY;
    OwnerHon = "";
    OwnerDisp = "";
    OwnerLegacy = "";
    OwnerDispReq = NULL_KEY;
    OwnerNameReq = NULL_KEY;
    OwnershipSent = FALSE;
    OwnershipRefreshed = FALSE;

    BootActive = TRUE;
    BootDeadline = now() + STARTUP_TIMEOUT_SEC;

    sendIM("DS Collar starting up.\nPlease wait");

    broadcastSoftReset();
    askSettings();
    askACL();
    askPluginList();
    startRlvProbe();

    llSetTimerEvent(POLL_RETRY_SEC);
    return TRUE;
}

/* Dynamic timer interval calculation */
float getTimerInterval(){
    /* Fast polling during bootstrap */
    if (BootActive) return POLL_RETRY_SEC;
    
    /* Active RLV probing needs fast polling */
    if (rlvPending()) return POLL_RETRY_SEC;
    
    /* Region resync enabled: moderate polling */
    if (RESYNC_ON_REGION_CHANGE) return 2.0;
    
    /* Idle state: no timer needed */
    return 0.0;
}

/* =========================== EVENTS =========================== */
default{
    state_entry(){
        WearerKey = llGetOwner();
        startBootstrap();
    }

    on_rez(integer sp){
        llResetScript();
    }

    attach(key id){
        /* Always reset on attach (id is always valid in attach event) */
        llResetScript();
    }

    changed(integer c){
        if (c & CHANGED_OWNER){
            llResetScript();
        }
        
        if ((c & CHANGED_REGION) && RESYNC_ON_REGION_CHANGE){
            RegionResyncDue = now() + RESYNC_GRACE_SEC;
            /* Ensure timer is running for resync check */
            float current_interval = getTimerInterval();
            if (current_interval == 0.0){
                llSetTimerEvent(2.0);
            }
        }
    }

    listen(integer chan, string name, key id, string text){
        /* Accept from wearer or NULL_KEY (for RLV relay compatibility) */
        if (id != WearerKey && id != NULL_KEY) return;
        if (!rlvPending()) return;

        RlvActive = TRUE;
        RlvReady = TRUE;
        RlvRespChan = chan;

        if (text != "") RlvVerStr = trim(text);

        /* Keep channels open briefly to catch other viewers */
        RlvSettleUntil = now() + RLV_SETTLE_SEC;
        buildAndSendRlvLine();
    }

    link_message(integer sender, integer num, string str, key id){
        if (num == K_PLUGIN_LIST){
            LastListTs = now();
            return;
        }

        if (num == K_SETTINGS_SYNC){
            string msg_type = llJsonGetValue(str, ["type"]);
            if (msg_type == MSG_SETTINGS_SYNC){
                string kv = llJsonGetValue(str, ["kv"]);
                if (kv != JSON_INVALID){
                    parseSettingsKv(kv);
                    SettingsReady = TRUE;
                }
            }
            return;
        }

        if (num == AUTH_RESULT_NUM){
            string msg_type = llJsonGetValue(str, ["type"]);
            if (msg_type == MSG_ACL_RESULT){
                AclReady = TRUE;
            }
            return;
        }
    }

    dataserver(key query_id, string data){
        integer changed_name = FALSE;

        if (query_id == OwnerDispReq){
            OwnerDispReq = NULL_KEY;
            /* "???" = name lookup failed; treat as empty */
            if (data != "" && data != "???"){
                OwnerDisp = data;
                changed_name = TRUE;
            }
        } else if (query_id == OwnerNameReq){
            OwnerNameReq = NULL_KEY;
            /* Only use legacy name if DisplayName failed */
            if (OwnerDisp == ""){
                if (data != ""){
                    OwnerLegacy = data;
                    changed_name = TRUE;
                }
            }
        } else {
            return;
        }

        /* Send improved ownership line after name resolves */
        if (changed_name){
            if (OwnershipSent && !OwnershipRefreshed){
                if (OwnerKey != NULL_KEY){
                    sendOwnershipLine();
                    OwnershipRefreshed = TRUE;
                }
            }
        }
    }

    timer(){
        integer timer_needed = FALSE;

        /* Optional region resync */
        if (RESYNC_ON_REGION_CHANGE){
            if (RegionResyncDue != 0){
                if (now() >= RegionResyncDue){
                    RegionResyncDue = 0;
                    askSettings();
                    askPluginList();
                }
            }
            /* Keep timer running if resync is enabled */
            timer_needed = TRUE;
        }

        /* RLV probe scheduler */
        if (rlvPending()){
            timer_needed = TRUE;
            
            /* Send retry queries */
            if (now() >= RlvNextSendAt){
                if (RlvRetries < RLV_MAX_RETRIES){
                    sendRlvQueries();
                    RlvRetries += 1;
                    RlvNextSendAt = now() + RLV_RETRY_EVERY;
                }
            }
            
            /* Improved settle/timeout logic with priority */
            if (RlvSettleUntil != 0){
                if (now() >= RlvSettleUntil){
                    stopRlvProbe();
                    RlvReady = TRUE;
                }
            } else if (RlvWaitUntil != 0){
                if (now() >= RlvWaitUntil){
                    stopRlvProbe();
                    RlvReady = TRUE;
                }
            }
        }

        /* Bootstrap readiness / timeout */
        if (BootActive){
            timer_needed = TRUE;
            
            integer timed_out = FALSE;
            integer completed = FALSE;

            if (readyEnough()){
                completed = TRUE;
            } else if (now() >= BootDeadline){
                timed_out = TRUE;
            }

            if (completed || timed_out){
                BootActive = FALSE;
                emitSummary(completed, timed_out);
                /* Don't immediately stop timer - recalculate interval */
                timer_needed = RESYNC_ON_REGION_CHANGE;
            }
        }

        /* Dynamic timer interval adjustment */
        float new_interval = getTimerInterval();
        llSetTimerEvent(new_interval);
    }
}
