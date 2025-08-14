/* =============================================================
   MODULE:  ds_collar_kmod_bootstrap.lsl  (authoritative + light resync)
   ROLE:    Coordinated startup on rez/attach/login
            - IM "DS Collar starting up. Please wait"
            - Kernel soft reset → plugins re-register
            - Requests SETTINGS + ACL + PLUGIN LIST
            - RLV status via @versionnew on channels:
              * 4711
              * relay -1812221819 (and opposite sign)
            - 30s initial delay, 90s total probe window, retries every 4s
            - Accepts replies from wearer or NULL_KEY
            - Follow-up "RLV update: ..." is DEBUG-ONLY (not sent to wearer)
            - No full bootstrap on region/teleport; optional light resync available
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Kernel ABI (match your kernel) ---------- */
integer K_SOFT_RESET           = 503;
integer K_PLUGIN_LIST          = 600;
integer K_PLUGIN_LIST_REQUEST  = 601;
integer K_SETTINGS_QUERY       = 800;
integer K_SETTINGS_SYNC        = 870;
integer AUTH_QUERY_NUM         = 700;
integer AUTH_RESULT_NUM        = 710;

/* ---------- RLV probe config ---------- */
integer RLV_BLOCKS_STARTUP      = FALSE; /* TRUE = wait for RLV before finishing summary */
integer RLV_PROBE_WINDOW_SEC    = 90;    /* total window (sec) */
integer RLV_INITIAL_DELAY_SEC   = 1;    /* wait before first probe (sec) */

/* Probe which channels? (owner disabled per your authoritative version) */
integer USE_OWNER_CHAN          = FALSE;
integer USE_FIXED_4711          = TRUE;
integer USE_RELAY_CHAN          = TRUE;
integer RELAY_CHAN              = -1812221819; /* your relay channel */
integer PROBE_RELAY_BOTH_SIGNS  = TRUE;        /* also probe +1812221819 */

/* ---------- Optional light resync on region change ---------- */
integer RESYNC_ON_REGION_CHANGE = FALSE; /* set TRUE to enable light resync */
integer RESYNC_GRACE_SEC        = 5;     /* wait this long after region hop */
integer REGION_RESYNC_DUE       = 0;     /* timestamp when resync should run */

/* ---------- RLV probe state/results ---------- */
integer RLV_READY        = FALSE;  /* resolved active/inactive */
integer RLV_ACTIVE       = FALSE;  /* viewer replied */
string  RLV_VERSTR       = "";     /* human-readable version from @versionnew */

list    RLV_CHANS        = [];     /* ints */
list    RLV_LISTENS      = [];     /* ints (listen handles) */

integer RLV_WAIT_UNTIL   = 0;
integer RLV_SETTLE_UNTIL = 0;      /* brief keep-open after first hit */
float   RLV_SETTLE_SEC   = 1.0;

integer RLV_MAX_RETRIES  = 8;      /* retries within window */
integer RLV_RETRY_EVERY  = 4;      /* seconds between retries */
integer RLV_RETRIES      = 0;
integer RLV_NEXT_SEND_AT = 0;
integer RLV_EMITTED_FINAL= FALSE;   /* final debug line already printed? */
string  RLV_RESULT_LINE  = "";      /* cached debug line */
integer RLV_RESP_CHAN    = 0;       /* which channel answered */
integer RLV_PROBING      = FALSE;   /* guard against duplicate start */

/* ---------- Magic words ---------- */
string  MSG_KERNEL_SOFT_RST    = "kernel_soft_reset";
string  MSG_PLUGIN_LIST        = "plugin_list";
string  MSG_SETTINGS_SYNC      = "settings_sync";
string  MSG_ACL_RESULT         = "acl_result";

/* ---------- Settings keys ---------- */
string KEY_OWNER_KEY           = "owner_key";
string KEY_OWNER_HON           = "owner_hon";

/* ---------- Startup tuning ---------- */
integer STARTUP_TIMEOUT_SEC    = 15;
float   POLL_RETRY_SEC         = 0.6;
integer QUIET_AFTER_LIST_SEC   = 1;

/* ---------- State ---------- */
integer BOOT_ACTIVE            = FALSE;
integer BOOT_DEADLINE          = 0;

integer SETTINGS_READY         = FALSE;
integer ACL_READY              = FALSE;

integer LAST_LIST_TS           = 0;

string  OWNER_KEY              = "";
string  OWNER_HON              = "";
key     OWNER_NAME_REQ         = NULL_KEY;
string  OWNER_NAME             = "";

/* ===================== Helpers ===================== */
integer now() { return llGetUnixTime(); }
integer isAttached() { return (integer)llGetAttached() != 0; }
key wearer() { return llGetOwner(); }
string trim(string s) { return llStringTrim(s, STRING_TRIM); }

integer sendIM(string msg) {
    key w = wearer();
    if (w != NULL_KEY) {
        if (msg != "") llInstantMessage(w, msg);
    }
    return TRUE;
}

string joinIntList(list xs, string sep) {
    integer i = 0; integer n = llGetListLength(xs);
    string out = "";
    while (i < n) {
        if (i != 0) out += sep;
        out += (string)llList2Integer(xs, i);
        i = i + 1;
    }
    return out;
}

/* OC-style owner channel kept here if you want to re-enable later */
integer ocOwnerChannel()
{
    key w = wearer();
    string s = (string)w;
    integer ch = (integer)("0x" + llGetSubString(s, -8, -1));
    ch = ch & 0x3FFFFFFF;    /* 30 bits */
    if (ch == 0) ch = 0x100;
    ch = -ch;
    return ch;
}

/* add/open a probe channel (dedup safe) */
integer addProbeChannel(integer ch)
{
    if (ch == 0) return FALSE;
    if (llListFindList(RLV_CHANS, [ch]) != -1) return FALSE;

    integer h = llListen(ch, "", NULL_KEY, ""); /* accept any sender; filter in handler */
    RLV_CHANS   = RLV_CHANS + [ch];
    RLV_LISTENS = RLV_LISTENS + [h];
    if (DEBUG) llOwnerSay("[BOOT] RLV probe channel added: " + (string)ch + " (listen " + (string)h + ")");
    return TRUE;
}

/* clear all probe channels/listens */
integer clearProbeChannels()
{
    integer i = 0;
    integer n = llGetListLength(RLV_LISTENS);
    while (i < n) {
        integer h = llList2Integer(RLV_LISTENS, i);
        if (h) llListenRemove(h);
        i = i + 1;
    }
    RLV_CHANS   = [];
    RLV_LISTENS = [];
    return TRUE;
}

integer rlvPending() {
    if (RLV_READY) return FALSE;
    if (llGetListLength(RLV_CHANS) > 0) return TRUE;
    if (RLV_WAIT_UNTIL != 0) return TRUE;
    return FALSE;
}

integer stopRlvProbe() {
    clearProbeChannels();
    RLV_WAIT_UNTIL   = 0;
    RLV_SETTLE_UNTIL = 0;
    RLV_NEXT_SEND_AT = 0;
    RLV_PROBING      = FALSE;
    return TRUE;
}

integer sendRlvQueries()
{
    integer i = 0;
    integer n = llGetListLength(RLV_CHANS);
    while (i < n) {
        integer ch = llList2Integer(RLV_CHANS, i);
        llOwnerSay("@versionnew=" + (string)ch);
        i = i + 1;
    }
    if (DEBUG) llOwnerSay("[BOOT] RLV @versionnew sent (try " + (string)(RLV_RETRIES + 1) + ") on [" + joinIntList(RLV_CHANS, ", ") + "]");
    return TRUE;
}

/* DEBUG-only follow-up; wearer sees only the summary's "RLV: ..." line */
integer buildAndSendRlvLine() {
    if (RLV_ACTIVE) {
        RLV_RESULT_LINE = "[BOOT] RLV update: active";
        if (RLV_VERSTR != "") RLV_RESULT_LINE += " (" + RLV_VERSTR + ")";
        /* include channel if wanted:
        RLV_RESULT_LINE += " [ch " + (string)RLV_RESP_CHAN + "]";
        */
    } else {
        RLV_RESULT_LINE = "[BOOT] RLV update: inactive";
    }
    if (!RLV_EMITTED_FINAL) {
        if (DEBUG) llOwnerSay(RLV_RESULT_LINE); /* debug-only */
        RLV_EMITTED_FINAL = TRUE;
    }
    return TRUE;
}

/* ---------- RLV probe lifecycle ---------- */
integer startRlvProbe()
{
    if (RLV_PROBING) {
        if (DEBUG) llOwnerSay("[BOOT] RLV probe already active; skipping");
        return FALSE;
    }

    if (!isAttached()) {
        /* rezzed: no viewer to talk to */
        RLV_READY = TRUE;
        RLV_ACTIVE = FALSE;
        RLV_VERSTR = "";
        RLV_RETRIES = 0;
        RLV_NEXT_SEND_AT = 0;
        RLV_EMITTED_FINAL = FALSE;
        return FALSE;
    }

    RLV_PROBING   = TRUE;
    RLV_RESP_CHAN = 0;

    stopRlvProbe(); /* safety */
    clearProbeChannels();

    if (USE_OWNER_CHAN) addProbeChannel(ocOwnerChannel());
    if (USE_FIXED_4711) addProbeChannel(4711);
    if (USE_RELAY_CHAN) {
        if (RELAY_CHAN != 0) {
            addProbeChannel(RELAY_CHAN);
            if (PROBE_RELAY_BOTH_SIGNS) {
                integer alt = -RELAY_CHAN;
                if (alt != 0) {
                    if (alt != RELAY_CHAN) addProbeChannel(alt);
                }
            }
        }
    }

    RLV_WAIT_UNTIL   = now() + RLV_PROBE_WINDOW_SEC;   /* total window */
    RLV_SETTLE_UNTIL = 0;
    RLV_RETRIES      = 0;
    RLV_NEXT_SEND_AT = now() + RLV_INITIAL_DELAY_SEC;  /* first send after 30s */

    RLV_EMITTED_FINAL = FALSE;
    RLV_READY  = FALSE;
    RLV_ACTIVE = FALSE;
    RLV_VERSTR = "";

    if (DEBUG) {
        llOwnerSay("[BOOT] RLV probe channels → [" + joinIntList(RLV_CHANS, ", ") + "]");
        llOwnerSay("[BOOT] RLV first send after " + (string)RLV_INITIAL_DELAY_SEC + "s");
    }
    return TRUE;
}

/* ---------- Kernel helpers ---------- */
integer broadcastSoftReset() {
    llMessageLinked(LINK_SET, K_SOFT_RESET, "{\"type\":\"kernel_soft_reset\"}", NULL_KEY);
    return TRUE;
}
integer askSettings()   { llMessageLinked(LINK_SET, K_SETTINGS_QUERY, "{\"type\":\"settings_get\"}", NULL_KEY); return TRUE; }
integer askACL()        { string j = llList2Json(JSON_OBJECT, ["type","acl_query","avatar",(string)wearer()]); llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY); return TRUE; }
integer askPluginList() { llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY); return TRUE; }

integer parseSettingsKv(string kv)
{
    string v;

    v = llJsonGetValue(kv, [KEY_OWNER_KEY]);
    if (v != JSON_INVALID) OWNER_KEY = v; else OWNER_KEY = "";

    v = llJsonGetValue(kv, [KEY_OWNER_HON]);
    if (v != JSON_INVALID) OWNER_HON = v; else OWNER_HON = "";

    if (OWNER_KEY != "") OWNER_NAME_REQ = llRequestAgentData((key)OWNER_KEY, DATA_NAME);
    return TRUE;
}

integer readyEnough()
{
    integer haveSettings = SETTINGS_READY;
    integer haveACL      = ACL_READY;
    integer listQuiet    = FALSE;

    if (LAST_LIST_TS != 0) {
        if ((now() - LAST_LIST_TS) >= QUIET_AFTER_LIST_SEC) listQuiet = TRUE;
    }

    if (RLV_BLOCKS_STARTUP) {
        if (!RLV_READY) return FALSE;
    }

    if (haveSettings && haveACL && listQuiet) return TRUE;
    return FALSE;
}

integer emitRlvLine()
{
    string line2 = "RLV: ";
    if (RLV_READY) {
        if (RLV_ACTIVE) {
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

integer emitSummary(integer completed, integer timedOut)
{
    string line1 = "Restart: ";
    if (completed) line1 += "completed";
    else if (timedOut) line1 += "timed out (some modules may still be loading)";
    else line1 += "in progress";

    string line3 = "Ownership: ";
    if (OWNER_KEY != "") {
        if (OWNER_NAME != "") line3 += "owned by " + OWNER_NAME;
        else if (OWNER_HON != "") line3 += "owned (" + OWNER_HON + ")";
        else line3 += "owned";
    } else {
        line3 += "unowned";
    }

    sendIM(line1);
    emitRlvLine();  /* wearer sees: "RLV: active (...)" or "RLV: inactive" */
    sendIM(line3);
    sendIM("Collar startup complete.");
    return TRUE;
}

integer startBootstrap()
{
    if (BOOT_ACTIVE) return FALSE; /* debounce */

    /* reset local state */
    SETTINGS_READY = FALSE;
    ACL_READY = FALSE;
    LAST_LIST_TS = 0;

    RLV_READY = FALSE;
    RLV_ACTIVE = FALSE;
    RLV_VERSTR = "";
    RLV_RETRIES = 0; RLV_NEXT_SEND_AT = 0; RLV_EMITTED_FINAL = FALSE;
    RLV_SETTLE_UNTIL = 0; RLV_WAIT_UNTIL = 0;
    RLV_RESP_CHAN = 0; RLV_PROBING = FALSE;

    OWNER_KEY = ""; OWNER_HON = ""; OWNER_NAME = ""; OWNER_NAME_REQ = NULL_KEY;

    BOOT_ACTIVE = TRUE;
    BOOT_DEADLINE = now() + STARTUP_TIMEOUT_SEC;

    /* announce + kick sequence */
    sendIM("DS Collar starting up. Please wait");
    broadcastSoftReset();
    askSettings();
    askACL();
    askPluginList();

    /* RLV probe (multi-channel) */
    startRlvProbe();

    llSetTimerEvent(POLL_RETRY_SEC);
    if (DEBUG) llOwnerSay("[BOOT] sequence started");
    return TRUE;
}

/* ======================= LSL events ======================= */
default
{
    state_entry()      { startBootstrap(); }
    on_rez(integer p)  { startBootstrap(); }
    attach(key id)     { if (id) startBootstrap(); }

    changed(integer c)
    {
        if (c & CHANGED_OWNER) llResetScript();

        /* Optional: lightweight resync after region/teleport (no soft reset, no RLV) */
        if (RESYNC_ON_REGION_CHANGE) {
            if (c & (CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
                REGION_RESYNC_DUE = now() + RESYNC_GRACE_SEC;
                if (DEBUG) llOwnerSay("[BOOT] region change detected → scheduling light resync");
                /* ensure timer is ticking even if bootstrap finished */
                llSetTimerEvent(POLL_RETRY_SEC);
            }
        }
    }

    link_message(integer sender, integer num, string str, key id)
    {
        /* Settings snapshot */
        if (num == K_SETTINGS_SYNC) {
            if (llJsonGetValue(str, ["type"]) == MSG_SETTINGS_SYNC) {
                string kv = llJsonGetValue(str, ["kv"]);
                if (kv != JSON_INVALID) parseSettingsKv(kv);
                SETTINGS_READY = TRUE;
                if (DEBUG) llOwnerSay("[BOOT] SETTINGS_READY");
            }
            return;
        }

        /* ACL result (for wearer) */
        if (num == AUTH_RESULT_NUM) {
            if (llJsonGetValue(str, ["type"]) == MSG_ACL_RESULT) {
                key av = (key)llJsonGetValue(str, ["avatar"]);
                if (av == wearer()) {
                    ACL_READY = TRUE;
                    if (DEBUG) {
                        integer lvl = (integer)llJsonGetValue(str, ["level"]);
                        llOwnerSay("[BOOT] ACL_READY (level " + (string)lvl + ")");
                    }
                }
            }
            return;
        }

        /* Kernel plugin list broadcasts */
        if (num == K_PLUGIN_LIST) {
            if (llJsonGetValue(str, ["type"]) == MSG_PLUGIN_LIST) {
                LAST_LIST_TS = now();
                if (DEBUG) llOwnerSay("[BOOT] plugin_list received");
            }
            return;
        }
    }

    /* RLV reply from the viewer (@versionnew) */
    listen(integer channel, string name, key id, string message)
    {
        /* Only our probe channels */
        if (llListFindList(RLV_CHANS, [channel]) == -1) return;

        /* Accept wearer or system/NULL replies (some viewers use NULL_KEY) */
        if (id != wearer()) {
            if (id != NULL_KEY) return;
        }

        /* Any reply on our channel(s) => RLV active */
        RLV_ACTIVE    = TRUE;
        RLV_READY     = TRUE;
        RLV_RESP_CHAN = channel;

        RLV_VERSTR = trim(message);
        if (DEBUG) llOwnerSay("[BOOT] RLV reply on " + (string)channel + " from " + (string)id + " → " + RLV_VERSTR);

        /* keep the listen a tad longer; close in timer() */
        RLV_SETTLE_UNTIL = now() + (integer)RLV_SETTLE_SEC;
    }

    dataserver(key rq, string data)
    {
        if (rq == OWNER_NAME_REQ) {
            OWNER_NAME = data;
            OWNER_NAME_REQ = NULL_KEY;
        }
    }

    timer()
    {
        /* Light resync after region change (no soft reset, no RLV) */
        if (REGION_RESYNC_DUE != 0) {
            if (now() >= REGION_RESYNC_DUE) {
                REGION_RESYNC_DUE = 0;
                askSettings();
                askPluginList();
                /* If you ever want to refresh ACL too, uncomment the next line */
                // askACL();
                if (DEBUG) llOwnerSay("[BOOT] light resync complete");
            }
        }

        /* Handle delayed first send + retries while probing */
        if (llGetListLength(RLV_CHANS) > 0 && !RLV_READY) {
            if (RLV_NEXT_SEND_AT != 0) {
                if (now() >= RLV_NEXT_SEND_AT) {
                    sendRlvQueries();
                    RLV_RETRIES = RLV_RETRIES + 1;
                    if (RLV_RETRIES < RLV_MAX_RETRIES) {
                        RLV_NEXT_SEND_AT = now() + RLV_RETRY_EVERY;
                    } else {
                        RLV_NEXT_SEND_AT = 0; /* no more retries; wait for timeout */
                    }
                }
            }
        }

        /* Close listeners after settle window if reply received */
        if (RLV_READY) {
            if (RLV_SETTLE_UNTIL != 0) {
                if (now() >= RLV_SETTLE_UNTIL) {
                    stopRlvProbe();
                    buildAndSendRlvLine(); /* DEBUG-only follow-up */
                    if (DEBUG) llOwnerSay("[BOOT] RLV settle complete");
                }
            }
        }

        /* Timeout: treat as inactive but READY, then DEBUG-only follow-up */
        if (!RLV_READY) {
            if (RLV_WAIT_UNTIL != 0) {
                if (now() >= RLV_WAIT_UNTIL) {
                    RLV_ACTIVE = FALSE;
                    RLV_READY  = TRUE;
                    RLV_VERSTR = "";
                    stopRlvProbe();
                    buildAndSendRlvLine(); /* DEBUG-only follow-up */
                    if (DEBUG) llOwnerSay("[BOOT] RLV probe timed out → treating as inactive");
                }
            }
        }

        /* Main startup coordinator */
        if (!BOOT_ACTIVE) {
            /* keep ticking if RLV still probing OR a region resync is pending */
            if (!rlvPending() && REGION_RESYNC_DUE == 0) llSetTimerEvent(0.0);
            return;
        }

        if (readyEnough()) {
            BOOT_ACTIVE = FALSE;
            emitSummary(TRUE, FALSE);     /* wearer sees the single "RLV: ..." line */
            if (!rlvPending() && REGION_RESYNC_DUE == 0) llSetTimerEvent(0.0);
            if (DEBUG) llOwnerSay("[BOOT] completed");
            return;
        }

        if (now() >= BOOT_DEADLINE) {
            BOOT_ACTIVE = FALSE;
            emitSummary(FALSE, TRUE);
            if (!rlvPending() && REGION_RESYNC_DUE == 0) llSetTimerEvent(0.0);
            if (DEBUG) llOwnerSay("[BOOT] timeout");
            return;
        }

        /* gentle retries while waiting */
        if (!SETTINGS_READY) askSettings();
        if (!ACL_READY)      askACL();
        if (LAST_LIST_TS == 0) askPluginList();
    }
}
