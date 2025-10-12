/* =============================================================
   MODULE: ds_collar_kmod_bootstrap.lsl (authoritative + light resync)
   ROLE  : Coordinated startup on rez/attach/login
   NOW WITH: Multi-owner mode support
           - IM "DS Collar starting up.\nPlease wait"
           - Kernel soft reset → plugins re-register
           - Requests SETTINGS + ACL + PLUGIN LIST
           - RLV status via @versionnew on channels:
              * 4711
              * relay -1812221819 (and opposite sign)
             - 30s initial delay, 90s total probe window, retries every 4s
             - Accepts replies from wearer or NULL_KEY
             - Follow-up "RLV update: ..." is DEBUG-ONLY (not sent to wearer)
           - No full bootstrap on region/teleport; optional light resync available
   PATCH : Ownership line mirrors Status plugin:
           * Resolve PO name offline via dataserver:
               - llRequestDisplayName(owner)
               - Fallback: llRequestAgentData(owner, DATA_NAME)
           * Follow-up Ownership line after name resolves (one-time)
           * Multi-owner support: displays all owners with their names
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

/* ---------- RLV probe config ---------- */
integer RLV_BLOCKS_STARTUP        = FALSE;
integer RLV_PROBE_WINDOW_SEC      = 90;
integer RLV_INITIAL_DELAY_SEC     = 1;

integer USE_OWNER_CHAN            = FALSE;
integer USE_FIXED_4711            = TRUE;
integer USE_RELAY_CHAN            = TRUE;
integer RELAY_CHAN                = -1812221819;
integer PROBE_RELAY_BOTH_SIGNS    = TRUE;

/* ---------- Optional light resync on region change ---------- */
integer RESYNC_ON_REGION_CHANGE   = FALSE;
integer RESYNC_GRACE_SEC          = 5;
integer REGION_RESYNC_DUE         = 0;

/* ---------- RLV probe state/results ---------- */
integer RLV_READY         = FALSE;
integer RLV_ACTIVE        = FALSE;
string  RLV_VERSTR        = "";
list    RLV_CHANS         = [];
list    RLV_LISTENS       = [];
integer RLV_WAIT_UNTIL    = 0;
integer RLV_SETTLE_UNTIL  = 0;
float   RLV_SETTLE_SEC    = 1.0;
integer RLV_MAX_RETRIES   = 8;
integer RLV_RETRY_EVERY   = 4;
integer RLV_RETRIES       = 0;
integer RLV_NEXT_SEND_AT  = 0;
integer RLV_EMITTED_FINAL = FALSE;
string  RLV_RESULT_LINE   = "";
integer RLV_RESP_CHAN     = 0;
integer RLV_PROBING       = FALSE;

/* ---------- Magic words ---------- */
string MSG_KERNEL_SOFT_RST = "kernel_soft_reset";
string MSG_PLUGIN_LIST     = "plugin_list";
string MSG_SETTINGS_SYNC   = "settings_sync";
string MSG_ACL_RESULT      = "acl_result";

/* ---------- Settings keys ---------- */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY        = "owner_key";
string KEY_OWNER_KEYS       = "owner_keys";
string KEY_OWNER_HON        = "owner_hon";
string KEY_OWNER_HONS       = "owner_honorifics";

/* ---------- Startup tuning ---------- */
integer STARTUP_TIMEOUT_SEC  = 15;
float   POLL_RETRY_SEC       = 0.6;
integer QUIET_AFTER_LIST_SEC = 1;

/* ---------- State ---------- */
integer BOOT_ACTIVE    = FALSE;
integer BOOT_DEADLINE  = 0;
integer SETTINGS_READY = FALSE;
integer ACL_READY      = FALSE;
integer LAST_LIST_TS   = 0;

/* ---------- Ownership (patched to support multi-owner) ---------- */
integer MultiOwnerMode      = FALSE;
key     OWNER_KEY           = NULL_KEY;
list    OwnerKeys           = [];
string  OWNER_HON           = "";
list    OwnerHonorifics     = [];

/* Single-owner name cache */
string  OWNER_DISP          = "";
string  OWNER_LEGACY        = "";
key     OWNER_DISP_REQ      = NULL_KEY;
key     OWNER_NAME_REQ      = NULL_KEY;

/* Multi-owner name cache */
list    OwnerDisplayNames   = [];
list    OwnerNameQueries    = [];

/* One-time ownership line follow-up after resolution */
integer OWNERSHIP_SENT      = FALSE;
integer OWNERSHIP_REFRESHED = FALSE;

/* ===================== Helpers ===================== */
integer now()         { return llGetUnixTime(); }
integer isAttached()  { return (integer)llGetAttached() != 0; }
key     wearer()      { return llGetOwner(); }
string  trim(string s){ return llStringTrim(s, STRING_TRIM); }

integer sendIM(string msg){
    key w = wearer();
    if (w != NULL_KEY){
        if (msg != "") llInstantMessage(w, msg);
    }
    return TRUE;
}

string joinIntList(list xs, string sep){
    integer i = 0; integer n = llGetListLength(xs);
    string out = "";
    while (i < n){
        if (i != 0) out += sep;
        out += (string)llList2Integer(xs, i);
        i += 1;
    }
    return out;
}

integer ocOwnerChannel(){
    key w = wearer();
    string s = (string)w;
    integer ch = (integer)("0x" + llGetSubString(s, -8, -1));
    ch = ch & 0x3FFFFFFF;
    if (ch == 0) ch = 0x100;
    ch = -ch;
    return ch;
}

integer addProbeChannel(integer ch){
    if (ch == 0) return FALSE;
    if (llListFindList(RLV_CHANS, [ch]) != -1) return FALSE;
    integer h = llListen(ch, "", NULL_KEY, "");
    RLV_CHANS   = RLV_CHANS + [ch];
    RLV_LISTENS = RLV_LISTENS + [h];
    if (DEBUG) llOwnerSay("[BOOT] RLV probe channel added: " + (string)ch + " (listen " + (string)h + ")");
    return TRUE;
}

integer clearProbeChannels(){
    integer i = 0; integer n = llGetListLength(RLV_LISTENS);
    while (i < n){
        integer h = llList2Integer(RLV_LISTENS, i);
        if (h) llListenRemove(h);
        i += 1;
    }
    RLV_CHANS = [];
    RLV_LISTENS = [];
    return TRUE;
}

integer rlvPending(){
    if (RLV_READY) return FALSE;
    if (llGetListLength(RLV_CHANS) > 0) return TRUE;
    if (RLV_WAIT_UNTIL != 0) return TRUE;
    return FALSE;
}

integer stopRlvProbe(){
    clearProbeChannels();
    RLV_WAIT_UNTIL = 0;
    RLV_SETTLE_UNTIL = 0;
    RLV_NEXT_SEND_AT = 0;
    RLV_PROBING = FALSE;
    return TRUE;
}

integer sendRlvQueries(){
    integer i = 0; integer n = llGetListLength(RLV_CHANS);
    while (i < n){
        integer ch = llList2Integer(RLV_CHANS, i);
        llOwnerSay("@versionnew=" + (string)ch);
        i += 1;
    }
    if (DEBUG) llOwnerSay("[BOOT] RLV @versionnew sent (try " + (string)(RLV_RETRIES + 1) + ") on [" + joinIntList(RLV_CHANS, ", ") + "]");
    return TRUE;
}

integer buildAndSendRlvLine(){
    if (RLV_ACTIVE){
        RLV_RESULT_LINE = "[BOOT] RLV update: active";
        if (RLV_VERSTR != "") RLV_RESULT_LINE += " (" + RLV_VERSTR + ")";
    } else {
        RLV_RESULT_LINE = "[BOOT] RLV update: inactive";
    }
    if (!RLV_EMITTED_FINAL){
        if (DEBUG) llOwnerSay(RLV_RESULT_LINE);
        RLV_EMITTED_FINAL = TRUE;
    }
    return TRUE;
}

/* ---------- RLV probe lifecycle ---------- */
integer startRlvProbe(){
    if (RLV_PROBING){
        if (DEBUG) llOwnerSay("[BOOT] RLV probe already active; skipping");
        return FALSE;
    }
    if (!isAttached()){
        RLV_READY = TRUE; RLV_ACTIVE = FALSE; RLV_VERSTR = "";
        RLV_RETRIES = 0; RLV_NEXT_SEND_AT = 0; RLV_EMITTED_FINAL = FALSE;
        return FALSE;
    }

    RLV_PROBING = TRUE; RLV_RESP_CHAN = 0;
    stopRlvProbe();
    clearProbeChannels();

    if (USE_OWNER_CHAN) addProbeChannel(ocOwnerChannel());
    if (USE_FIXED_4711) addProbeChannel(4711);
    if (USE_RELAY_CHAN){
        if (RELAY_CHAN != 0){
            addProbeChannel(RELAY_CHAN);
            if (PROBE_RELAY_BOTH_SIGNS){
                integer alt = -RELAY_CHAN;
                if (alt != 0){
                    if (alt != RELAY_CHAN) addProbeChannel(alt);
                }
            }
        }
    }

    RLV_WAIT_UNTIL   = now() + RLV_PROBE_WINDOW_SEC;
    RLV_SETTLE_UNTIL = 0;
    RLV_RETRIES      = 0;
    RLV_NEXT_SEND_AT = now() + RLV_INITIAL_DELAY_SEC;
    RLV_EMITTED_FINAL= FALSE;
    RLV_READY        = FALSE;
    RLV_ACTIVE       = FALSE;
    RLV_VERSTR       = "";

    if (DEBUG){
        llOwnerSay("[BOOT] RLV probe channels → [" + joinIntList(RLV_CHANS, ", ") + "]");
        llOwnerSay("[BOOT] RLV first send after " + (string)RLV_INITIAL_DELAY_SEC + "s");
    }
    return TRUE;
}

/* ---------- Kernel helpers ---------- */
integer broadcastSoftReset(){
    llMessageLinked(LINK_SET, K_SOFT_RESET, "{\"type\":\"kernel_soft_reset\"}", NULL_KEY);
    return TRUE;
}
integer askSettings(){
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, "{\"type\":\"settings_get\"}", NULL_KEY);
    return TRUE;
}
integer askACL(){
    string j = llList2Json(JSON_OBJECT, ["type","acl_query","avatar",(string)wearer()]);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    return TRUE;
}
integer askPluginList(){
    llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY);
    return TRUE;
}

/* ---------- Owner name resolution (patched for multi-owner) ---------- */
integer requestOwnerNames(){
    if (MultiOwnerMode){
        OwnerDisplayNames = [];
        OwnerNameQueries = [];
        integer i = 0;
        while (i < llGetListLength(OwnerKeys)){
            key owner = (key)llList2String(OwnerKeys, i);
            key query = llRequestDisplayName(owner);
            OwnerNameQueries += [query];
            OwnerDisplayNames += ["(fetching…)"];
            i += 1;
        }
    }
    else {
        if (OWNER_KEY == NULL_KEY) return FALSE;
        OWNER_DISP   = "";
        OWNER_LEGACY = "";
        OWNER_DISP_REQ = llRequestDisplayName(OWNER_KEY);
        OWNER_NAME_REQ = llRequestAgentData(OWNER_KEY, DATA_NAME);
    }
    return TRUE;
}

string ownerDisplayLabel(){
    if (MultiOwnerMode){
        return "(see below)";
    }
    
    string nm = "";
    if (OWNER_DISP != "") nm = OWNER_DISP;
    else if (OWNER_LEGACY != "") nm = OWNER_LEGACY;
    else nm = "(fetching…)";

    string hon = OWNER_HON;
    string out = "";
    if (hon != ""){
        out = hon + " " + nm;
    } else {
        out = nm;
    }
    return out;
}

integer parseSettingsKv(string kv){
    string v;

    /* Read multi-owner mode */
    v = llJsonGetValue(kv, [KEY_MULTI_OWNER_MODE]);
    if (v != JSON_INVALID) MultiOwnerMode = ((integer)v != 0);
    else MultiOwnerMode = FALSE;

    /* Read owner data based on mode */
    if (MultiOwnerMode){
        v = llJsonGetValue(kv, [KEY_OWNER_KEYS]);
        if (v != JSON_INVALID && llGetSubString(v, 0, 0) == "["){
            OwnerKeys = llJson2List(v);
        } else {
            OwnerKeys = [];
        }
        OWNER_KEY = NULL_KEY;
        
        v = llJsonGetValue(kv, [KEY_OWNER_HONS]);
        if (v != JSON_INVALID && llGetSubString(v, 0, 0) == "["){
            OwnerHonorifics = llJson2List(v);
        } else {
            OwnerHonorifics = [];
        }
    }
    else {
        v = llJsonGetValue(kv, [KEY_OWNER_KEY]);
        if (v != JSON_INVALID) OWNER_KEY = (key)v;
        else OWNER_KEY = NULL_KEY;
        
        OwnerKeys = [];
        OwnerHonorifics = [];
    }

    v = llJsonGetValue(kv, [KEY_OWNER_HON]);
    if (v != JSON_INVALID) OWNER_HON = v;
    else OWNER_HON = "";

    /* Request names based on mode */
    if (MultiOwnerMode){
        if (llGetListLength(OwnerKeys) > 0){
            requestOwnerNames();
        }
    }
    else {
        if (OWNER_KEY != NULL_KEY){
            requestOwnerNames();
        }
    }
    
    return TRUE;
}

integer readyEnough(){
    integer haveSettings = SETTINGS_READY;
    integer haveACL      = ACL_READY;
    integer listQuiet    = FALSE;

    if (LAST_LIST_TS != 0){
        if ((now() - LAST_LIST_TS) >= QUIET_AFTER_LIST_SEC) listQuiet = TRUE;
    }

    if (RLV_BLOCKS_STARTUP){
        if (!RLV_READY) return FALSE;
    }

    if (haveSettings && haveACL && listQuiet) return TRUE;
    return FALSE;
}

integer emitRlvLine(){
    string line2 = "RLV: ";
    if (RLV_READY){
        if (RLV_ACTIVE){
            line2 += "active";
            if (RLV_VERSTR != "") line2 += " (" + RLV_VERSTR + ")";
        } else {
            line2 += "inactive";
        }
    } else {
        line2 += "probing…";
    }
    sendIM(line2);
    return TRUE;
}

integer sendOwnershipLine(){
    string line3 = "Ownership: ";
    
    if (MultiOwnerMode){
        integer owner_count = llGetListLength(OwnerKeys);
        if (owner_count > 0){
            if (owner_count == 1){
                line3 += "owned by ";
            }
            else {
                line3 += "owned by ";
            }
            
            integer i = 0;
            while (i < owner_count){
                if (i != 0){
                    line3 += ", ";
                }
                
                string display_name = "(fetching…)";
                if (i < llGetListLength(OwnerDisplayNames)){
                    display_name = llList2String(OwnerDisplayNames, i);
                }
                
                /* Check for individual honorific first, then fall back to shared */
                string honorific = "";
                if (i < llGetListLength(OwnerHonorifics)){
                    honorific = llList2String(OwnerHonorifics, i);
                }
                
                if (honorific != ""){
                    line3 += honorific + " " + display_name;
                }
                else if (OWNER_HON != ""){
                    line3 += OWNER_HON + " " + display_name;
                }
                else {
                    line3 += display_name;
                }
                
                i += 1;
            }
        }
        else {
            line3 += "unowned";
        }
    }
    else {
        if (OWNER_KEY != NULL_KEY){
            string disp = ownerDisplayLabel();
            line3 += "owned by " + disp;
        } else {
            line3 += "unowned";
        }
    }
    
    sendIM(line3);
    return TRUE;
}

integer emitSummary(integer completed, integer timedOut){
    string line1 = "Restart: ";
    if (completed) line1 += "completed";
    else if (timedOut) line1 += "timed out (some modules may still be loading)";
    else line1 += "in progress";

    sendIM(line1);
    emitRlvLine();
    sendOwnershipLine();
    OWNERSHIP_SENT = TRUE;

    sendIM("Collar startup complete.");
    return TRUE;
}

/* ---------- Bootstrap lifecycle ---------- */
integer startBootstrap(){
    if (BOOT_ACTIVE) return FALSE;

    SETTINGS_READY = FALSE;
    ACL_READY      = FALSE;
    LAST_LIST_TS   = 0;

    RLV_READY = FALSE; RLV_ACTIVE = FALSE; RLV_VERSTR = "";
    RLV_RETRIES = 0; RLV_NEXT_SEND_AT = 0; RLV_EMITTED_FINAL = FALSE;
    RLV_SETTLE_UNTIL = 0; RLV_WAIT_UNTIL = 0; RLV_RESP_CHAN = 0; RLV_PROBING = FALSE;

    MultiOwnerMode = FALSE;
    OWNER_KEY = NULL_KEY;
    OwnerKeys = [];
    OWNER_HON = "";
    OwnerHonorifics = [];
    OWNER_DISP = "";
    OWNER_LEGACY = "";
    OWNER_DISP_REQ = NULL_KEY;
    OWNER_NAME_REQ = NULL_KEY;
    OwnerDisplayNames = [];
    OwnerNameQueries = [];
    OWNERSHIP_SENT = FALSE;
    OWNERSHIP_REFRESHED = FALSE;

    BOOT_ACTIVE  = TRUE;
    BOOT_DEADLINE= now() + STARTUP_TIMEOUT_SEC;

    sendIM("DS Collar starting up.\nPlease wait");

    broadcastSoftReset();
    askSettings();
    askACL();
    askPluginList();

    startRlvProbe();

    llSetTimerEvent(POLL_RETRY_SEC);
    return TRUE;
}

/* =========================== EVENTS =========================== */
default{
    state_entry(){
        startBootstrap();
    }

    on_rez(integer sp){ llResetScript(); }
    attach(key id){ if (id) llResetScript(); }

    changed(integer c){
        if (c & CHANGED_OWNER) llResetScript();
        if ((c & CHANGED_REGION) && RESYNC_ON_REGION_CHANGE){
            REGION_RESYNC_DUE = now() + RESYNC_GRACE_SEC;
        }
    }

    listen(integer chan, string name, key id, string text){
        integer ok = FALSE;
        if (id == wearer()) ok = TRUE;
        else if (id == NULL_KEY) ok = TRUE;

        if (!ok) return;
        if (!rlvPending()) return;

        RLV_ACTIVE = TRUE;
        RLV_READY  = TRUE;
        RLV_RESP_CHAN = chan;

        if (text != "") RLV_VERSTR = trim(text);

        RLV_SETTLE_UNTIL = now() + (integer)RLV_SETTLE_SEC;

        buildAndSendRlvLine();
    }

    link_message(integer sender, integer num, string str, key id){
        if (num == K_PLUGIN_LIST){
            LAST_LIST_TS = now();
            return;
        }

        if (num == K_SETTINGS_SYNC){
            string t = llJsonGetValue(str, ["type"]);
            if (t != JSON_INVALID){
                if (t == MSG_SETTINGS_SYNC){
                    string kv = llJsonGetValue(str, ["kv"]);
                    if (kv != JSON_INVALID){
                        parseSettingsKv(kv);
                        SETTINGS_READY = TRUE;
                    }
                }
            }
            return;
        }

        if (num == AUTH_RESULT_NUM){
            string t2 = llJsonGetValue(str, ["type"]);
            if (t2 != JSON_INVALID){
                if (t2 == MSG_ACL_RESULT){
                    ACL_READY = TRUE;
                }
            }
            return;
        }

        if (num == K_SOFT_RESET){
            return;
        }
    }

    dataserver(key query_id, string data){
        integer changedName = FALSE;

        /* Single-owner mode name resolution */
        if (query_id == OWNER_DISP_REQ){
            OWNER_DISP_REQ = NULL_KEY;
            if (data != "" && data != "???"){
                OWNER_DISP = data;
                changedName = TRUE;
            }
        } else if (query_id == OWNER_NAME_REQ){
            OWNER_NAME_REQ = NULL_KEY;
            if (OWNER_DISP == ""){
                if (data != ""){
                    OWNER_LEGACY = data;
                    changedName = TRUE;
                }
            }
        } else {
            /* Multi-owner mode name resolution */
            integer query_idx = llListFindList(OwnerNameQueries, [query_id]);
            if (query_idx != -1){
                if (data != "" && data != "???"){
                    OwnerDisplayNames = llListReplaceList(OwnerDisplayNames, [data], query_idx, query_idx);
                    changedName = TRUE;
                }
                /* Mark as processed but DON'T delete to preserve index mapping */
                OwnerNameQueries = llListReplaceList(OwnerNameQueries, [NULL_KEY], query_idx, query_idx);
            } else {
                return;
            }
        }

        /* If we've already printed the ownership line and haven't refreshed it yet,
           send a one-time improved line with the resolved name. */
        if (changedName){
            if (OWNERSHIP_SENT){
                if (!OWNERSHIP_REFRESHED){
                    if (MultiOwnerMode){
                        if (llGetListLength(OwnerKeys) > 0){
                            sendOwnershipLine();
                            OWNERSHIP_REFRESHED = TRUE;
                        }
                    }
                    else {
                        if (OWNER_KEY != NULL_KEY){
                            sendOwnershipLine();
                            OWNERSHIP_REFRESHED = TRUE;
                        }
                    }
                }
            }
        }
    }

    timer(){
        if (RESYNC_ON_REGION_CHANGE){
            if (REGION_RESYNC_DUE != 0){
                if (now() >= REGION_RESYNC_DUE){
                    REGION_RESYNC_DUE = 0;
                    askSettings();
                    askPluginList();
                }
            }
        }

        if (rlvPending()){
            if (now() >= RLV_NEXT_SEND_AT){
                if (RLV_RETRIES < RLV_MAX_RETRIES){
                    sendRlvQueries();
                    RLV_RETRIES = RLV_RETRIES + 1;
                    RLV_NEXT_SEND_AT = now() + RLV_RETRY_EVERY;
                }
            }
            if (RLV_SETTLE_UNTIL != 0){
                if (now() >= RLV_SETTLE_UNTIL){
                    stopRlvProbe();
                    RLV_READY = TRUE;
                }
            }
            if (RLV_WAIT_UNTIL != 0){
                if (now() >= RLV_WAIT_UNTIL){
                    stopRlvProbe();
                    RLV_READY = TRUE;
                }
            }
        }

        if (BOOT_ACTIVE){
            integer timedOut = FALSE;
            integer completed = FALSE;

            if (readyEnough()){
                completed = TRUE;
            } else {
                if (now() >= BOOT_DEADLINE){
                    timedOut = TRUE;
                }
            }

            if (completed || timedOut){
                BOOT_ACTIVE = FALSE;
                emitSummary(completed, timedOut);
                llSetTimerEvent(0.0);
                return;
            }
        }
    }
}
