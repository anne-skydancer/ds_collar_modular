/* =============================================================
   MODULE: ds_collar_kmod_bootstrap.lsl (authoritative + light resync)
   ROLE  : Coordinated startup on rez/attach/login
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
integer RLV_BLOCKS_STARTUP        = FALSE;  /* TRUE = wait for RLV before finishing summary */
integer RLV_PROBE_WINDOW_SEC      = 90;     /* total window (sec) */
integer RLV_INITIAL_DELAY_SEC     = 1;      /* wait before first probe (sec) */

/* Probe which channels? (owner disabled per your authoritative version) */
integer USE_OWNER_CHAN            = FALSE;
integer USE_FIXED_4711            = TRUE;
integer USE_RELAY_CHAN            = TRUE;
integer RELAY_CHAN                = -1812221819;   /* your relay channel */
integer PROBE_RELAY_BOTH_SIGNS    = TRUE;          /* also probe +1812221819 */

/* ---------- Optional light resync on region change ---------- */
integer RESYNC_ON_REGION_CHANGE   = FALSE; /* set TRUE to enable light resync */
integer RESYNC_GRACE_SEC          = 5;     /* wait this long after region hop */
integer REGION_RESYNC_DUE         = 0;     /* timestamp when resync should run */

/* ---------- RLV probe state/results ---------- */
integer RLV_READY         = FALSE;   /* resolved active/inactive */
integer RLV_ACTIVE        = FALSE;   /* viewer replied */
string  RLV_VERSTR        = "";      /* human-readable version from @versionnew */
list    RLV_CHANS         = [];      /* ints */
list    RLV_LISTENS       = [];      /* ints (listen handles) */
integer RLV_WAIT_UNTIL    = 0;
integer RLV_SETTLE_UNTIL  = 0;       /* brief keep-open after first hit */
float   RLV_SETTLE_SEC    = 1.0;
integer RLV_MAX_RETRIES   = 8;       /* retries within window */
integer RLV_RETRY_EVERY   = 4;       /* seconds between retries */
integer RLV_RETRIES       = 0;
integer RLV_NEXT_SEND_AT  = 0;
integer RLV_EMITTED_FINAL = FALSE;   /* final debug line already printed? */
string  RLV_RESULT_LINE   = "";      /* cached debug line */
integer RLV_RESP_CHAN     = 0;       /* which channel answered */
integer RLV_PROBING       = FALSE;   /* guard against duplicate start */

/* ---------- Magic words ---------- */
string MSG_KERNEL_SOFT_RST = "kernel_soft_reset";
string MSG_PLUGIN_LIST     = "plugin_list";
string MSG_SETTINGS_SYNC   = "settings_sync";
string MSG_ACL_RESULT      = "acl_result";

/* ---------- Settings keys ---------- */
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_HON = "owner_hon";

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

/* ---------- Ownership (patched to mirror Status plugin) ---------- */
/* Treat owner as key, not string */
key     OWNER_KEY        = NULL_KEY;
string  OWNER_HON        = "";

/* Name cache + requests (DisplayName preferred, legacy fallback) */
string  OWNER_DISP       = "";        /* preferred display name */
string  OWNER_LEGACY     = "";        /* legacy "First Last" */
key     OWNER_DISP_REQ   = NULL_KEY;  /* llRequestDisplayName query id */
key     OWNER_NAME_REQ   = NULL_KEY;  /* llRequestAgentData(DATA_NAME) query id */

/* One-time ownership line follow-up after resolution */
integer OWNERSHIP_SENT      = FALSE;  /* we already sent the summary line */
integer OWNERSHIP_REFRESHED = FALSE;  /* we sent the improved one after name resolution */

/* ===================== Helpers ===================== */
// Returns the current Unix time (seconds).
integer now()         { return llGetUnixTime(); }
// Indicates whether the collar is currently attached.
integer isAttached()  { return (integer)llGetAttached() != 0; }
// Returns the current wearer/owner key.
key     wearer()      { return llGetOwner(); }
// Trims whitespace from both ends of the provided string.
string  trim(string s){ return llStringTrim(s, STRING_TRIM); }

// Sends an IM to the wearer when available.
integer sendIM(string msg){
    key w = wearer();
    if (w != NULL_KEY){
        if (msg != "") llInstantMessage(w, msg);
    }
    return TRUE;
}

// Joins a list of integers with the provided separator string.
string joinIntList(list xs, string sep){
    integer i = 0; integer n = llGetListLength(xs);
    string out = "";
    while (i < n){
        if (i != 0) out += sep;
        out += (string)llList2Integer(xs, i);
        i = i + 1;
    }
    return out;
}

/* OC-style owner channel kept here if you want to re-enable later */
// Computes the classic OpenCollar owner channel from the wearer key.
integer ocOwnerChannel(){
    key w = wearer();
    string s = (string)w;
    integer ch = (integer)("0x" + llGetSubString(s, -8, -1));
    ch = ch & 0x3FFFFFFF; /* 30 bits */
    if (ch == 0) ch = 0x100;
    ch = -ch;
    return ch;
}

/* add/open a probe channel (dedup safe) */
// Adds an RLV probe channel listener if it is not already tracked.
integer addProbeChannel(integer ch){
    if (ch == 0) return FALSE;
    if (llListFindList(RLV_CHANS, [ch]) != -1) return FALSE;
    integer h = llListen(ch, "", NULL_KEY, ""); /* accept any sender; filter in handler */
    RLV_CHANS   = RLV_CHANS + [ch];
    RLV_LISTENS = RLV_LISTENS + [h];
    if (DEBUG) llOwnerSay("[BOOT] RLV probe channel added: " + (string)ch + " (listen " + (string)h + ")");
    return TRUE;
}

/* clear all probe channels/listens */
// Removes all active RLV probe listens and clears the channel list.
integer clearProbeChannels(){
    integer i = 0; integer n = llGetListLength(RLV_LISTENS);
    while (i < n){
        integer h = llList2Integer(RLV_LISTENS, i);
        if (h) llListenRemove(h);
        i = i + 1;
    }
    RLV_CHANS = [];
    RLV_LISTENS = [];
    return TRUE;
}

// Returns TRUE while an RLV probe is still awaiting completion.
integer rlvPending(){
    if (RLV_READY) return FALSE;
    if (llGetListLength(RLV_CHANS) > 0) return TRUE;
    if (RLV_WAIT_UNTIL != 0) return TRUE;
    return FALSE;
}

// Stops the current RLV probe and clears scheduling state.
integer stopRlvProbe(){
    clearProbeChannels();
    RLV_WAIT_UNTIL = 0;
    RLV_SETTLE_UNTIL = 0;
    RLV_NEXT_SEND_AT = 0;
    RLV_PROBING = FALSE;
    return TRUE;
}

// Issues @versionnew queries on all registered probe channels.
integer sendRlvQueries(){
    integer i = 0; integer n = llGetListLength(RLV_CHANS);
    while (i < n){
        integer ch = llList2Integer(RLV_CHANS, i);
        llOwnerSay("@versionnew=" + (string)ch);
        i = i + 1;
    }
    if (DEBUG) llOwnerSay("[BOOT] RLV @versionnew sent (try " + (string)(RLV_RETRIES + 1) + ") on [" + joinIntList(RLV_CHANS, ", ") + "]");
    return TRUE;
}

/* DEBUG-only follow-up; wearer sees only the summary's "RLV: ..." line */
// Builds the debug RLV status line and caches it for optional output.
integer buildAndSendRlvLine(){
    if (RLV_ACTIVE){
        RLV_RESULT_LINE = "[BOOT] RLV update: active";
        if (RLV_VERSTR != "") RLV_RESULT_LINE += " (" + RLV_VERSTR + ")";
    } else {
        RLV_RESULT_LINE = "[BOOT] RLV update: inactive";
    }
    if (!RLV_EMITTED_FINAL){
        if (DEBUG) llOwnerSay(RLV_RESULT_LINE); /* debug-only */
        RLV_EMITTED_FINAL = TRUE;
    }
    return TRUE;
}

/* ---------- RLV probe lifecycle ---------- */
// Begins the RLV capability probe, opening channels and scheduling retries.
integer startRlvProbe(){
    if (RLV_PROBING){
        if (DEBUG) llOwnerSay("[BOOT] RLV probe already active; skipping");
        return FALSE;
    }
    if (!isAttached()){
        /* rezzed: no viewer to talk to */
        RLV_READY = TRUE; RLV_ACTIVE = FALSE; RLV_VERSTR = "";
        RLV_RETRIES = 0; RLV_NEXT_SEND_AT = 0; RLV_EMITTED_FINAL = FALSE;
        return FALSE;
    }

    RLV_PROBING = TRUE; RLV_RESP_CHAN = 0;
    stopRlvProbe(); /* safety */
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

    RLV_WAIT_UNTIL   = now() + RLV_PROBE_WINDOW_SEC; /* total window */
    RLV_SETTLE_UNTIL = 0;
    RLV_RETRIES      = 0;
    RLV_NEXT_SEND_AT = now() + RLV_INITIAL_DELAY_SEC; /* first send after delay */
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
// Broadcasts a kernel_soft_reset to prompt plugin re-registration.
integer broadcastSoftReset(){
    llMessageLinked(LINK_SET, K_SOFT_RESET, "{\"type\":\"kernel_soft_reset\"}", NULL_KEY);
    return TRUE;
}
// Requests the latest settings snapshot from the settings module.
integer askSettings(){
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, "{\"type\":\"settings_get\"}", NULL_KEY);
    return TRUE;
}
// Queries the auth module for the wearer's ACL level.
integer askACL(){
    string j = llList2Json(JSON_OBJECT, ["type","acl_query","avatar",(string)wearer()]);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    return TRUE;
}
// Requests the current plugin list from the kernel.
integer askPluginList(){
    llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY);
    return TRUE;
}

/* ---------- Owner name resolution (patched) ---------- */
// Issues display name and legacy name lookups for the cached owner key.
integer requestOwnerNames(){
    if (OWNER_KEY == NULL_KEY) return FALSE;

    /* clear old cache */
    OWNER_DISP   = "";
    OWNER_LEGACY = "";

    /* Start both requests (Display Name preferred) */
    OWNER_DISP_REQ = llRequestDisplayName(OWNER_KEY);
    OWNER_NAME_REQ = llRequestAgentData(OWNER_KEY, DATA_NAME);
    return TRUE;
}

/* Compose the PO label like Status plugin does */
// Builds the display label for the primary owner using honorifics when present.
string ownerDisplayLabel(){
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

/* Parse settings kv → mirror state + kick name lookups */
// Applies settings_sync data to local owner state and triggers name lookups.
integer parseSettingsKv(string kv){
    string v;

    v = llJsonGetValue(kv, [KEY_OWNER_KEY]);
    if (v != JSON_INVALID) OWNER_KEY = (key)v;
    else OWNER_KEY = NULL_KEY;

    v = llJsonGetValue(kv, [KEY_OWNER_HON]);
    if (v != JSON_INVALID) OWNER_HON = v;
    else OWNER_HON = "";

    if (OWNER_KEY != NULL_KEY){
        requestOwnerNames();
    } else {
        OWNER_DISP = "";
        OWNER_LEGACY = "";
    }
    return TRUE;
}

// Determines whether all required bootstrap inputs have arrived.
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

// Sends the RLV status summary line to the wearer.
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

/* Build and send the Ownership line (mirrors Status plugin language) */
// Emits the ownership status line in the startup summary.
integer sendOwnershipLine(){
    string line3 = "Ownership: ";
    if (OWNER_KEY != NULL_KEY){
        string disp = ownerDisplayLabel();
        line3 += "owned by " + disp;
    } else {
        line3 += "unowned";
    }
    sendIM(line3);
    return TRUE;
}

/* Startup summary; remember if we already emitted ownership once */
// Sends the three-line startup summary along with completion status flags.
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
// Resets bootstrap state and kicks off the startup handshake sequence.
integer startBootstrap(){
    if (BOOT_ACTIVE) return FALSE; /* debounce */

    /* reset local state */
    SETTINGS_READY = FALSE;
    ACL_READY      = FALSE;
    LAST_LIST_TS   = 0;

    RLV_READY = FALSE; RLV_ACTIVE = FALSE; RLV_VERSTR = "";
    RLV_RETRIES = 0; RLV_NEXT_SEND_AT = 0; RLV_EMITTED_FINAL = FALSE;
    RLV_SETTLE_UNTIL = 0; RLV_WAIT_UNTIL = 0; RLV_RESP_CHAN = 0; RLV_PROBING = FALSE;

    OWNER_KEY = NULL_KEY;
    OWNER_HON = "";
    OWNER_DISP = "";
    OWNER_LEGACY = "";
    OWNER_DISP_REQ = NULL_KEY;
    OWNER_NAME_REQ = NULL_KEY;
    OWNERSHIP_SENT = FALSE;
    OWNERSHIP_REFRESHED = FALSE;

    BOOT_ACTIVE  = TRUE;
    BOOT_DEADLINE= now() + STARTUP_TIMEOUT_SEC;

    /* announce + kick sequence */
    sendIM("DS Collar starting up.\nPlease wait");

    broadcastSoftReset(); /* plugins re-register */
    askSettings();
    askACL();
    askPluginList();

    /* kick off RLV probe (non-blocking unless RLV_BLOCKS_STARTUP) */
    startRlvProbe();

    /* schedule poll */
    llSetTimerEvent(POLL_RETRY_SEC);
    return TRUE;
}

/* =========================== EVENTS =========================== */
default{
    // Kick off the bootstrap sequence when the module starts.
    state_entry(){
        startBootstrap();
    }

    // Reset on rez to re-run the bootstrap from a clean state.
    on_rez(integer sp){ llResetScript(); }
    // Reset on attach so wearer changes retrigger initialization.
    attach(key id){ if (id) llResetScript(); }

    /* Region change → optional light resync */
    // Handles ownership changes and schedules optional region resyncs.
    changed(integer c){
        if (c & CHANGED_OWNER) llResetScript();
        if ((c & CHANGED_REGION) && RESYNC_ON_REGION_CHANGE){
            REGION_RESYNC_DUE = now() + RESYNC_GRACE_SEC;
        }
    }

    /* RLV replies + guard channels */
    // Consumes RLV @versionnew replies from the wearer or controller.
    listen(integer chan, string name, key id, string text){
        /* accept from wearer or NULL_KEY (per design) */
        integer ok = FALSE;
        if (id == wearer()) ok = TRUE;
        else if (id == NULL_KEY) ok = TRUE;

        if (!ok) return;
        if (!rlvPending()) return;

        RLV_ACTIVE = TRUE;
        RLV_READY  = TRUE;
        RLV_RESP_CHAN = chan;

        if (text != "") RLV_VERSTR = trim(text);

        /* keep channels open briefly to catch other viewers then close */
        RLV_SETTLE_UNTIL = now() + (integer)RLV_SETTLE_SEC;

        buildAndSendRlvLine();
    }

    /* LINK: settings, acl, plugin list, soft reset query */
    // Handles inbound settings, ACL, and plugin list updates during bootstrap.
    link_message(integer sender, integer num, string str, key id){
        /* plugin list “quiet” marker */
        if (num == K_PLUGIN_LIST){
            LAST_LIST_TS = now();
            return;
        }

        /* inbound settings sync */
        if (num == K_SETTINGS_SYNC){
            /* Expect {"type":"settings_sync","kv":{...}} or the kernel variant that carries kv */
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

        /* inbound ACL result */
        if (num == AUTH_RESULT_NUM){
            string t2 = llJsonGetValue(str, ["type"]);
            if (t2 != JSON_INVALID){
                if (t2 == MSG_ACL_RESULT){
                    ACL_READY = TRUE;
                }
            }
            return;
        }

        /* soft re-register request (kernel asks) */
        if (num == K_SOFT_RESET){
            /* No action here; we already broadcast soft reset on startBootstrap */
            return;
        }
    }

    /* dataserver: owner name resolution (DisplayName -> Legacy fallback) */
    // Reconciles owner name lookups and refreshes the ownership line once resolved.
    dataserver(key query_id, string data){
        integer changedName = FALSE;

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
            return;
        }

        /* If we've already printed the ownership line and haven’t refreshed it yet,
           send a one-time improved line with the resolved name. */
        if (changedName){
            if (OWNERSHIP_SENT){
                if (!OWNERSHIP_REFRESHED){
                    if (OWNER_KEY != NULL_KEY){
                        sendOwnershipLine();
                        OWNERSHIP_REFRESHED = TRUE;
                    }
                }
            }
        }
    }

    /* Timer: poll bootstrap readiness + RLV probe scheduling + optional resync */
    // Drives optional resyncs, RLV probing, and bootstrap completion polling.
    timer(){
        /* Optional region resync */
        if (RESYNC_ON_REGION_CHANGE){
            if (REGION_RESYNC_DUE != 0){
                if (now() >= REGION_RESYNC_DUE){
                    REGION_RESYNC_DUE = 0;
                    /* light resync: ask settings + list again */
                    askSettings();
                    askPluginList();
                }
            }
        }

        /* RLV probe scheduler */
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
                    RLV_READY = TRUE; /* finalize as inactive if nothing replied */
                }
            }
        }

        /* Bootstrap readiness / timeout */
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
