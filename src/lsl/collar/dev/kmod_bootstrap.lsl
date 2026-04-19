/*--------------------
MODULE: kmod_bootstrap.lsl
VERSION: 1.10
REVISION: 5
PURPOSE: Startup coordination, RLV detection, status announcement
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 5: KERNEL_LIFECYCLE rename (Phase 1). kernel.reset→
  kernel.reset.soft, kernel.resetall→kernel.reset.factory,
  settings.notecardloaded→settings.notecard.loaded.
- v1.1 rev 4: Namespace internal message type strings (settings.sync,
  settings.delta, settings.notecardloaded, kernel.reset, kernel.resetall).
- v1.1 rev 3: Fix phantom owner count in startup announcement and stale
  names_ready check. llCSV2List("") returns [""] (a single empty entry),
  not []. Routed CSV reads through a csv_read() helper.
- v1.1 rev 2: Two-mode access model. Read primary owner from access.owner
  scalar (single mode) or access.owneruuids CSV (multi mode). Remove all
  display-name resolution code — kmod_settings now resolves names async
  and stores them in access.ownername / access.ownernames.
- v1.1 rev 1: Migrate settings reads from JSON broadcast payloads to direct
  llLinksetDataRead. Remove request_settings() helper and settings_get message.
- v1.1 rev 0: Version bump for LSD policy architecture. Bootstrap no longer
  manages UI policies — each plugin self-declares via llLinksetDataWrite.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- RLV DETECTION CONFIG -------------------- */
integer RLV_PROBE_TIMEOUT_SEC = 60;
integer RLV_RETRY_INTERVAL_SEC = 5;
integer RLV_MAX_RETRIES = 10;
integer RLV_INITIAL_DELAY_SEC = 5;

// Probe multiple channels for better compatibility
integer UseFixed4711;
integer UseRelayChan;
integer RELAY_CHAN = -1812221819;
integer ProbeRelayBothSigns;  // Also try positive relay channel

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE  = "access.multiowner";
string KEY_OWNER             = "access.owner";              // single-owner uuid
string KEY_OWNER_NAME        = "access.ownername";          // single-owner resolved name
string KEY_OWNER_HONORIFIC   = "access.ownerhonorific";
string KEY_OWNER_UUIDS       = "access.owneruuids";         // multi-owner csv
string KEY_OWNER_NAMES       = "access.ownernames";
string KEY_OWNER_HONORIFICS  = "access.ownerhonorifics";

string NAME_LOADING = "(loading...)";

/* -------------------- BOOTSTRAP CONFIG -------------------- */
integer BOOTSTRAP_TIMEOUT_SEC = 90;
integer SETTINGS_RETRY_INTERVAL_SEC = 5;
integer SETTINGS_MAX_RETRIES = 3;
integer SETTINGS_INITIAL_DELAY_SEC = 5; // Wait for linkset data + notecard load

/* -------------------- STATE -------------------- */
integer BootstrapComplete = FALSE;
integer BootstrapDeadline = 0;

// Owner tracking
key LastOwner = NULL_KEY;

// RLV detection
list RlvChannels = [];          // List of channels we're listening on
list RlvListenHandles = [];     // Corresponding listen handles
integer RlvProbing = FALSE;
integer RlvActive = FALSE;
string RlvVersion = "";
integer RlvProbeDeadline = 0;
integer RlvNextRetry = 0;
integer RlvRetryCount = 0;
integer RlvReady = FALSE;

// Settings
integer SettingsReceived = FALSE;
integer SettingsRetryCount = 0;
integer SettingsNextRetry = 0;

// Name resolution wait: kmod_settings resolves names async; we wait briefly
// after settings_received before announcing so the owner name is populated.
integer NamesReadyDeadline = 0;
integer NAMES_READY_TIMEOUT_SEC = 10;

/* -------------------- HELPERS -------------------- */


string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}


integer now() {
    return llGetUnixTime();
}

sendIM(string msg) {
    key wearer = llGetOwner();
    if (wearer != NULL_KEY && msg != "") {
        llInstantMessage(wearer, msg);
    }
}

integer isAttached() {
    return ((integer)llGetAttached() != 0);
}

// llCSV2List("") returns [""] (length 1), not []. This wrapper returns a
// truly empty list when the LSD key is unset/empty.
list csv_read(string lsd_key) {
    string raw = llLinksetDataRead(lsd_key);
    if (raw == "") return [];
    return llCSV2List(raw);
}

// Owner change detection (prevents unnecessary resets on teleport)
integer check_owner_changed() {
    key current_owner = llGetOwner();
    if (current_owner == NULL_KEY) return FALSE;

    if (LastOwner != NULL_KEY && current_owner != LastOwner) {
        LastOwner = current_owner;
        llResetScript();
        return TRUE;
    }

    LastOwner = current_owner;
    return FALSE;
}

/* -------------------- RLV DETECTION - Multi-Channel Approach -------------------- */

addProbeChannel(integer ch) {
    if (ch == 0) return;
    if (llListFindList(RlvChannels, [ch]) != -1) return;  // Already added
    
    integer handle = llListen(ch, "", NULL_KEY, "");  // Accept from anyone (NULL_KEY important!)
    RlvChannels += [ch];
    RlvListenHandles += [handle];
}

clearProbeChannels() {
    integer i = 0;
    while (i < llGetListLength(RlvListenHandles)) {
        integer handle = llList2Integer(RlvListenHandles, i);
        if (handle) llListenRemove(handle);
        i += 1;
    }
    RlvChannels = [];
    RlvListenHandles = [];
}

sendRlvQueries() {
    integer i = 0;
    while (i < llGetListLength(RlvChannels)) {
        integer ch = llList2Integer(RlvChannels, i);
        llOwnerSay("@versionnew=" + (string)ch);
        i += 1;
    }
}

start_rlv_probe() {
    if (RlvProbing) {
        return;
    }
    
    if (!isAttached()) {
        // Not attached, can't detect RLV
        RlvReady = TRUE;
        RlvActive = FALSE;
        RlvVersion = "";
        return;
    }
    
    RlvProbing = TRUE;
    RlvActive = FALSE;
    RlvVersion = "";
    RlvRetryCount = 0;
    RlvReady = FALSE;
    
    clearProbeChannels();
    
    // Set up multiple probe channels
    if (UseFixed4711) addProbeChannel(4711);
    if (UseRelayChan) {
        addProbeChannel(RELAY_CHAN);
        if (ProbeRelayBothSigns) {
            addProbeChannel(-RELAY_CHAN);  // Try opposite sign too
        }
    }
    
    RlvProbeDeadline = now() + RLV_PROBE_TIMEOUT_SEC;
    RlvNextRetry = now() + RLV_INITIAL_DELAY_SEC;  // Initial delay before first probe
    
    sendIM("Detecting RLV...");
}

stop_rlv_probe() {
    clearProbeChannels();
    RlvProbing = FALSE;
    RlvReady = TRUE;
}

/* -------------------- SETTINGS LOADING -------------------- */

// Mark settings as received and start the names-ready countdown.
// Actual reading happens at announcement time directly from LSD.
apply_settings_sync() {
    SettingsReceived = TRUE;
    NamesReadyDeadline = now() + NAMES_READY_TIMEOUT_SEC;
}

// Returns TRUE if all owner names in LSD are resolved (no NAME_LOADING placeholders)
integer names_ready() {
    integer multi_mode = (integer)llLinksetDataRead(KEY_MULTI_OWNER_MODE);

    if (multi_mode) {
        list names = csv_read(KEY_OWNER_NAMES);
        integer i;
        integer len = llGetListLength(names);
        for (i = 0; i < len; i++) {
            if (llList2String(names, i) == NAME_LOADING) return FALSE;
        }
        return TRUE;
    }

    // Single owner: only check if there IS an owner
    if (llLinksetDataRead(KEY_OWNER) == "") return TRUE;
    return (llLinksetDataRead(KEY_OWNER_NAME) != NAME_LOADING);
}

/* -------------------- BOOTSTRAP INITIATION -------------------- */

start_bootstrap() {
    BootstrapComplete = FALSE;
    SettingsReceived = FALSE;
    SettingsRetryCount = 0;
    NamesReadyDeadline = 0;

    BootstrapDeadline = now() + BOOTSTRAP_TIMEOUT_SEC;

    sendIM("D/s Collar starting up. Please wait...");

    start_rlv_probe();

    // OPTIMIZATION: Delay initial settings check to allow notecard loading
    SettingsNextRetry = now() + SETTINGS_INITIAL_DELAY_SEC;

    llSetTimerEvent(1.0);
}

/* -------------------- BOOTSTRAP COMPLETION -------------------- */

check_bootstrap_complete() {
    if (BootstrapComplete) return;

    if (RlvReady && SettingsReceived && names_ready()) {
        BootstrapComplete = TRUE;
        announce_status();
    }
}

announce_status() {
    // RLV Status
    if (RlvActive) {
        sendIM("RLV: " + RlvVersion);
    }
    else {
        sendIM("RLV: Not detected");
    }

    if (!SettingsReceived) {
        sendIM("WARNING: Settings timed out. Using defaults.");
    }

    integer multi_mode = (integer)llLinksetDataRead(KEY_MULTI_OWNER_MODE);

    if (multi_mode) {
        list uuids = csv_read(KEY_OWNER_UUIDS);
        list names = csv_read(KEY_OWNER_NAMES);
        list hons  = csv_read(KEY_OWNER_HONORIFICS);
        integer owner_count = llGetListLength(uuids);

        sendIM("Mode: Multi-Owner (" + (string)owner_count + ")");

        if (owner_count > 0) {
            list owner_parts = [];
            integer i = 0;
            while (i < owner_count) {
                string nm = "";
                if (i < llGetListLength(names)) nm = llList2String(names, i);
                string hn = "";
                if (i < llGetListLength(hons)) hn = llList2String(hons, i);

                if (hn != "") {
                    owner_parts += [hn + " " + nm];
                }
                else {
                    owner_parts += [nm];
                }
                i += 1;
            }
            sendIM("Owned by " + llDumpList2String(owner_parts, ", "));
        }
        else {
            sendIM("Uncommitted");
        }
    }
    else {
        sendIM("Mode: Single-Owner");

        string owner_uuid = llLinksetDataRead(KEY_OWNER);
        if (owner_uuid != "") {
            string nm = llLinksetDataRead(KEY_OWNER_NAME);
            string hn = llLinksetDataRead(KEY_OWNER_HONORIFIC);
            string owner_line = "Owned by ";
            if (hn != "") owner_line += hn + " ";
            owner_line += nm;
            sendIM(owner_line);
        }
        else {
            sendIM("Uncommitted");
        }
    }

    sendIM("Collar startup complete.");
}

/* -------------------- EVENTS -------------------- */
default
{
    state_entry() {
        UseFixed4711 = TRUE;
        UseRelayChan = TRUE;
        ProbeRelayBothSigns = TRUE;

        LastOwner = llGetOwner();
        
        state starting;
    }
}

state starting
{
    state_entry() {
        start_bootstrap();
    }

    on_rez(integer start_param) {
        // Only reset if owner changed - prevents bootstrap on every teleport
        check_owner_changed();
    }

    attach(key id) {
        if (id == NULL_KEY) return;
        // Bootstrap on attach (covers logon and initial attach)
        llResetScript();
    }
    
    timer() {
        integer current_time = llGetUnixTime();
        if (current_time == 0) return; // Overflow protection

        // GLOBAL TIMEOUT CHECK
        if (!BootstrapComplete && BootstrapDeadline > 0 && current_time >= BootstrapDeadline) {
            sendIM("WARNING: Bootstrap timed out. Forcing completion.");

            if (!RlvReady) stop_rlv_probe();
            if (!SettingsReceived) SettingsReceived = TRUE;

            BootstrapComplete = TRUE;
            announce_status();
            state running;
            return;
        }

        // Handle Settings Retries (read directly from LSD)
        if (!SettingsReceived && current_time >= SettingsNextRetry) {
            if (SettingsRetryCount < SETTINGS_MAX_RETRIES) {
                apply_settings_sync();
                SettingsRetryCount++;
                SettingsNextRetry = current_time + SETTINGS_RETRY_INTERVAL_SEC;
            }
        }

        // Handle RLV probe retries
        if (RlvProbing && !RlvReady) {
            if (RlvNextRetry > 0 && current_time >= RlvNextRetry) {
                if (RlvRetryCount < RLV_MAX_RETRIES) {
                    sendRlvQueries();
                    RlvRetryCount += 1;
                    integer next_retry_time = current_time + RLV_RETRY_INTERVAL_SEC;
                    if (next_retry_time < current_time) next_retry_time = current_time;
                    RlvNextRetry = next_retry_time;
                }
            }

            if (RlvProbeDeadline > 0 && current_time >= RlvProbeDeadline) {
                stop_rlv_probe();
                check_bootstrap_complete();
            }
        }

        // Names ready check (kmod_settings resolves them async)
        if (SettingsReceived && RlvReady && !BootstrapComplete) {
            if (names_ready() ||
                (NamesReadyDeadline > 0 && current_time >= NamesReadyDeadline)) {
                check_bootstrap_complete();
            }
        }

        // Stop timer if bootstrap complete
        if (BootstrapComplete && !RlvProbing) {
            state running;
        }
    }

    listen(integer channel, string name, key id, string message) {
        if (llListFindList(RlvChannels, [channel]) == -1) return;

        key wearer = llGetOwner();
        if (id != wearer && id != NULL_KEY) return;

        RlvActive = TRUE;
        RlvVersion = llStringTrim(message, STRING_TRIM);

        stop_rlv_probe();
        check_bootstrap_complete();
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;
        
        /* -------------------- SETTINGS BUS -------------------- */
        if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                apply_settings_sync();
            }
        }

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        else if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "settings.notecard.loaded") {
                // Settings notecard was loaded/reloaded - re-run bootstrap
                start_bootstrap();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            check_owner_changed();
        }
    }
}

state running
{
    state_entry() {
        llSetTimerEvent(0.0);
    }

    on_rez(integer start_param) {
        check_owner_changed();
    }

    attach(key id) {
        if (id == NULL_KEY) return;
        llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "settings.notecard.loaded") {
                llResetScript();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            check_owner_changed();
        }
    }
}
