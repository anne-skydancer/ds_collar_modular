/*--------------------
MODULE: ds_collar_kmod_bootstrap.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Startup coordination, RLV detection, owner name resolution,
         UI policy initialization via Linkset Data (LSD)
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 0: Added LSD-based UI policy system. Default policies for all
  plugins are written to LSD on bootstrap. Plugins read their own policies
  at menu time via llLinksetDataRead. This replaces hardcoded min_acl
  filtering with data-driven, per-ACL-level button visibility.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- RLV DETECTION CONFIG -------------------- */
integer RLV_PROBE_TIMEOUT_SEC = 60;
integer RLV_RETRY_INTERVAL_SEC = 5;
integer RLV_MAX_RETRIES = 10;
integer RLV_INITIAL_DELAY_SEC = 5;

integer UseFixed4711;
integer UseRelayChan;
integer RELAY_CHAN = -1812221819;
integer ProbeRelayBothSigns;

/* -------------------- DISPLAY NAME REQUEST RATE LIMITING -------------------- */
float NAME_REQUEST_INTERVAL_SEC = 2.5;

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER = "owner";
string KEY_OWNERS = "owners";

/* -------------------- BOOTSTRAP CONFIG -------------------- */
integer BOOTSTRAP_TIMEOUT_SEC = 90;
integer SETTINGS_RETRY_INTERVAL_SEC = 5;
integer SETTINGS_MAX_RETRIES = 3;
integer SETTINGS_INITIAL_DELAY_SEC = 5;

/* -------------------- STATE -------------------- */
integer BootstrapComplete = FALSE;
integer BootstrapDeadline = 0;

key LastOwner = NULL_KEY;

// RLV detection
list RlvChannels = [];
list RlvListenHandles = [];
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
integer MultiOwnerMode = FALSE;
key OwnerKey = NULL_KEY;
list OwnerKeys = [];
string OwnerHonorific = "";
string OwnersJson = "{}";

// Name resolution
list OwnerNameQueries = [];
integer NAME_QUERY_STRIDE = 2;
list OwnerDisplayNames = [];
integer NameResolutionDeadline = 0;
integer NAME_RESOLUTION_TIMEOUT_SEC = 30;

// Name request queue (rate-limited)
list PendingNameRequests = [];
integer NextNameRequestTime = 0;

// Policy initialization
integer PoliciesWritten = FALSE;

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

/* -------------------- UI POLICY SYSTEM (v1.1) -------------------- */
// Writes default button visibility policies to Linkset Data.
// Each policy is a JSON object keyed by ACL level, value is CSV of
// allowed button labels.
//
// ACL levels:
//   0 = No Access (TPE-locked), 1 = Public, 2 = Owned Wearer,
//   3 = Trustee, 4 = Unowned Wearer, 5 = Primary Owner

write_policy(string ctx, string json) {
    llLinksetDataWrite("policy:" + ctx, json);
}

write_default_policies() {
    if (PoliciesWritten) return;

    // Root menu: which plugin contexts are visible per ACL level
    write_policy("root", llList2Json(JSON_OBJECT, [
        "0", "sos_911",
        "1", "core_animate,bell,core_leash,core_maintenance,core_rlvrestrict,core_status",
        "2", "core_access,core_animate,bell,core_blacklist,core_leash,core_maintenance,core_relay,core_rlvrestrict,core_status",
        "3", "core_access,core_animate,bell,core_blacklist,core_leash,core_lock,core_maintenance,core_public,core_relay,core_rlvrestrict,core_rlv_exceptions,core_status",
        "4", "core_access,core_animate,bell,core_blacklist,core_leash,core_lock,core_maintenance,core_relay,core_rlvrestrict,core_rlv_exceptions,core_status",
        "5", "core_access,core_animate,bell,core_blacklist,core_leash,core_lock,core_maintenance,core_public,core_relay,core_rlvrestrict,core_rlv_exceptions,core_status,core_tpe"
    ]));

    // Per-plugin button policies
    // core_access
    write_policy("core_access", llList2Json(JSON_OBJECT, [
        "2", "Add Owner,Runaway",
        "3", "Add Trustee,Rem Trustee,Release,Runaway: On,Runaway: Off",
        "4", "Add Owner,Runaway,Add Trustee,Rem Trustee",
        "5", "Transfer,Release,Runaway: On,Runaway: Off,Add Trustee,Rem Trustee"
    ]));

    // core_animate
    write_policy("core_animate", llList2Json(JSON_OBJECT, [
        "1", "<<,>>,Stop",
        "2", "<<,>>,Stop",
        "3", "<<,>>,Stop",
        "4", "<<,>>,Stop",
        "5", "<<,>>,Stop"
    ]));

    // bell
    write_policy("bell", llList2Json(JSON_OBJECT, [
        "1", "Show,Sound,Volume +,Volume -",
        "2", "Show,Sound,Volume +,Volume -",
        "3", "Show,Sound,Volume +,Volume -",
        "4", "Show,Sound,Volume +,Volume -",
        "5", "Show,Sound,Volume +,Volume -"
    ]));

    // core_blacklist
    write_policy("core_blacklist", llList2Json(JSON_OBJECT, [
        "2", "+Blacklist,-Blacklist",
        "3", "+Blacklist,-Blacklist",
        "4", "+Blacklist,-Blacklist",
        "5", "+Blacklist,-Blacklist"
    ]));

    // core_leash
    write_policy("core_leash", llList2Json(JSON_OBJECT, [
        "1", "Clip,Post,Get Holder,Settings",
        "2", "Offer",
        "3", "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings",
        "4", "Clip,Unclip,Pass,Yank,Coffle,Post,Get Holder,Settings",
        "5", "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings"
    ]));

    // core_lock (direct toggle, no submenu buttons)
    write_policy("core_lock", llList2Json(JSON_OBJECT, [
        "4", "toggle",
        "5", "toggle"
    ]));

    // core_maintenance
    write_policy("core_maintenance", llList2Json(JSON_OBJECT, [
        "1", "Get HUD,User Manual",
        "2", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        "3", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        "4", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        "5", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual"
    ]));

    // core_public (direct toggle, no submenu buttons)
    write_policy("core_public", llList2Json(JSON_OBJECT, [
        "3", "toggle",
        "4", "toggle",
        "5", "toggle"
    ]));

    // core_relay
    write_policy("core_relay", llList2Json(JSON_OBJECT, [
        "2", "Mode,Bound by...,Safeword",
        "3", "Mode,Bound by...,Unbind,HC OFF,HC ON",
        "4", "Mode,Bound by...,Safeword",
        "5", "Mode,Bound by...,Unbind,HC OFF,HC ON"
    ]));

    // core_rlvrestrict
    write_policy("core_rlvrestrict", llList2Json(JSON_OBJECT, [
        "1", "Force Sit,Force Unsit",
        "2", "Force Sit,Force Unsit",
        "3", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "4", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "5", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit"
    ]));

    // core_rlv_exceptions
    write_policy("core_rlv_exceptions", llList2Json(JSON_OBJECT, [
        "3", "Owner,Trustee,TP,IM",
        "4", "Owner,Trustee,TP,IM",
        "5", "Owner,Trustee,TP,IM"
    ]));

    // sos_911
    write_policy("sos_911", llList2Json(JSON_OBJECT, [
        "0", "Unleash,Clear RLV,Clear Relay"
    ]));

    // core_status (view-only, no action buttons beyond Back)
    write_policy("core_status", llList2Json(JSON_OBJECT, [
        "1", "",
        "2", "",
        "3", "",
        "4", "",
        "5", ""
    ]));

    // core_tpe (direct toggle, confirmation only)
    write_policy("core_tpe", llList2Json(JSON_OBJECT, [
        "5", "toggle"
    ]));

    PoliciesWritten = TRUE;
}

/* -------------------- RLV DETECTION -------------------- */

addProbeChannel(integer ch) {
    if (ch == 0) return;
    if (llListFindList(RlvChannels, [ch]) != -1) return;

    integer handle = llListen(ch, "", NULL_KEY, "");
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
    if (RlvProbing) return;

    if (!isAttached()) {
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

    if (UseFixed4711) addProbeChannel(4711);
    if (UseRelayChan) {
        addProbeChannel(RELAY_CHAN);
        if (ProbeRelayBothSigns) {
            addProbeChannel(-RELAY_CHAN);
        }
    }

    RlvProbeDeadline = now() + RLV_PROBE_TIMEOUT_SEC;
    RlvNextRetry = now() + RLV_INITIAL_DELAY_SEC;

    sendIM("Detecting RLV...");
}

stop_rlv_probe() {
    clearProbeChannels();
    RlvProbing = FALSE;
    RlvReady = TRUE;
}

/* -------------------- SETTINGS LOADING -------------------- */

request_settings() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]), NULL_KEY);
}

apply_settings_sync(string msg) {
    string kv_json = llJsonGetValue(msg, ["kv"]);
    if (kv_json == JSON_INVALID) return;

    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    OwnerHonorific = "";
    OwnersJson = "{}";

    string tmp = llJsonGetValue(kv_json, [KEY_MULTI_OWNER_MODE]);
    if (tmp != JSON_INVALID) {
        MultiOwnerMode = (integer)tmp;
    }

    string obj = llJsonGetValue(kv_json, [KEY_OWNER]);
    if (obj != JSON_INVALID) {
        if (llJsonValueType(obj, []) == JSON_OBJECT) {
            list pairs = llJson2List(obj);
            if (llGetListLength(pairs) >= 2) {
                OwnerKey = (key)llList2String(pairs, 0);
                OwnerHonorific = llList2String(pairs, 1);
            }
        }
    }

    obj = llJsonGetValue(kv_json, [KEY_OWNERS]);
    if (obj != JSON_INVALID) {
        if (llJsonValueType(obj, []) == JSON_OBJECT) {
            OwnersJson = obj;
            list pairs = llJson2List(obj);
            integer pi = 0;
            integer plen = llGetListLength(pairs);
            while (pi < plen) {
                OwnerKeys += [llList2String(pairs, pi)];
                pi += 2;
            }
        }
    }

    SettingsReceived = TRUE;
    start_name_resolution();
}

/* -------------------- NAME RESOLUTION -------------------- */

process_next_name_request() {
    integer current_time = llGetUnixTime();
    if (current_time == 0) return;

    if (llGetListLength(PendingNameRequests) == 0) return;
    if (NextNameRequestTime > 0 && current_time < NextNameRequestTime) return;

    key owner = llList2Key(PendingNameRequests, 0);
    PendingNameRequests = llDeleteSubList(PendingNameRequests, 0, 0);

    if (owner != NULL_KEY) {
        key query_id = llRequestDisplayName(owner);
        OwnerNameQueries += [query_id, owner];

        integer owner_idx = -1;
        if (MultiOwnerMode) {
            owner_idx = llListFindList(OwnerKeys, [(string)owner]);
        }
        else {
            if (owner == OwnerKey) owner_idx = 0;
        }

        if (owner_idx != -1) {
            if (owner_idx >= llGetListLength(OwnerDisplayNames)) {
                OwnerDisplayNames += ["(loading...)"];
            }
        }

        integer next_time = current_time + (integer)NAME_REQUEST_INTERVAL_SEC;
        if (next_time > current_time) {
            NextNameRequestTime = next_time;
        }
        else {
            NextNameRequestTime = current_time;
        }
    }
}

start_name_resolution() {
    OwnerNameQueries = [];
    OwnerDisplayNames = [];
    PendingNameRequests = [];
    NextNameRequestTime = 0;

    integer current_time = llGetUnixTime();
    if (current_time > 0) {
        integer deadline = current_time + NAME_RESOLUTION_TIMEOUT_SEC;
        if (deadline > current_time) {
            NameResolutionDeadline = deadline;
        }
        else {
            NameResolutionDeadline = current_time;
        }
    }

    if (MultiOwnerMode) {
        integer i = 0;
        while (i < llGetListLength(OwnerKeys)) {
            string owner_str = llList2String(OwnerKeys, i);
            key owner = (key)owner_str;
            if (owner != NULL_KEY) {
                PendingNameRequests += [owner];
                OwnerDisplayNames += ["(loading...)"];
            }
            i += 1;
        }
    }
    else {
        if (OwnerKey != NULL_KEY) {
            PendingNameRequests += [OwnerKey];
            OwnerDisplayNames += ["(loading...)"];
        }
    }

    if (llGetListLength(PendingNameRequests) == 0) {
        check_bootstrap_complete();
    }
    else {
        process_next_name_request();
    }
}

handle_dataserver_name(key query_id, string name) {
    integer idx = llListFindList(OwnerNameQueries, [query_id]);
    if (idx != -1) {
        key owner = llList2Key(OwnerNameQueries, idx + 1);

        integer owner_idx = -1;
        if (MultiOwnerMode) {
            owner_idx = llListFindList(OwnerKeys, [(string)owner]);
        }
        else {
            if (owner == OwnerKey) owner_idx = 0;
        }

        if (owner_idx != -1 && owner_idx < llGetListLength(OwnerDisplayNames)) {
            OwnerDisplayNames = llListReplaceList(OwnerDisplayNames, [name], owner_idx, owner_idx);
        }

        OwnerNameQueries = llDeleteSubList(OwnerNameQueries, idx, idx + NAME_QUERY_STRIDE - 1);

        if (llGetListLength(OwnerNameQueries) == 0) {
            check_bootstrap_complete();
        }
    }
}

/* -------------------- BOOTSTRAP -------------------- */

start_bootstrap() {
    BootstrapComplete = FALSE;
    SettingsReceived = FALSE;
    SettingsRetryCount = 0;
    NameResolutionDeadline = 0;
    PendingNameRequests = [];
    NextNameRequestTime = 0;
    PoliciesWritten = FALSE;

    BootstrapDeadline = now() + BOOTSTRAP_TIMEOUT_SEC;

    sendIM("D/s Collar starting up. Please wait...");

    // Write UI policies to LSD early so plugins can read them immediately
    write_default_policies();

    start_rlv_probe();

    SettingsNextRetry = now() + SETTINGS_INITIAL_DELAY_SEC;

    llSetTimerEvent(1.0);
}

check_bootstrap_complete() {
    if (BootstrapComplete) return;

    if (RlvReady && SettingsReceived &&
        llGetListLength(OwnerNameQueries) == 0 &&
        llGetListLength(PendingNameRequests) == 0) {
        BootstrapComplete = TRUE;
        announce_status();
    }
}

announce_status() {
    if (RlvActive) {
        sendIM("RLV: " + RlvVersion);
    }
    else {
        sendIM("RLV: Not detected");
    }

    if (!SettingsReceived) {
        sendIM("WARNING: Settings timed out. Using defaults.");
    }

    if (MultiOwnerMode) {
        integer owner_count = llGetListLength(OwnerKeys);
        sendIM("Mode: Multi-Owner (" + (string)owner_count + ")");
    }
    else {
        sendIM("Mode: Single-Owner");
    }

    if (MultiOwnerMode) {
        integer owner_count = llGetListLength(OwnerKeys);
        if (owner_count > 0) {
            list owner_parts = [];
            integer i = 0;
            while (i < owner_count) {
                string owner_uuid = llList2String(OwnerKeys, i);
                string hon = llJsonGetValue(OwnersJson, [owner_uuid]);
                if (hon == JSON_INVALID) hon = "";

                string display_name = "";
                if (i < llGetListLength(OwnerDisplayNames)) {
                    display_name = llList2String(OwnerDisplayNames, i);
                }

                if (hon != "") {
                    owner_parts += [hon + " " + display_name];
                }
                else {
                    owner_parts += [display_name];
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
        if (OwnerKey != NULL_KEY) {
            string owner_line = "Owned by ";
            if (OwnerHonorific != "") {
                owner_line += OwnerHonorific + " ";
            }
            owner_line += llList2String(OwnerDisplayNames, 0);
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
        check_owner_changed();
    }

    attach(key id) {
        if (id == NULL_KEY) return;
        llResetScript();
    }

    timer() {
        integer current_time = llGetUnixTime();
        if (current_time == 0) return;

        // Global timeout
        if (!BootstrapComplete && BootstrapDeadline > 0 && current_time >= BootstrapDeadline) {
            sendIM("WARNING: Bootstrap timed out. Forcing completion.");

            if (!RlvReady) stop_rlv_probe();
            if (!SettingsReceived) {
                SettingsReceived = TRUE;
                start_name_resolution();
            }

            OwnerNameQueries = [];
            PendingNameRequests = [];

            BootstrapComplete = TRUE;
            announce_status();
            state running;
            return;
        }

        // Settings retries
        if (!SettingsReceived && current_time >= SettingsNextRetry) {
            if (SettingsRetryCount < SETTINGS_MAX_RETRIES) {
                request_settings();
                SettingsRetryCount++;
                SettingsNextRetry = current_time + SETTINGS_RETRY_INTERVAL_SEC;
            }
        }

        // RLV probe retries
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

        // Rate-limited name requests
        if (llGetListLength(PendingNameRequests) > 0) {
            process_next_name_request();
        }

        // Name resolution timeout
        if ((llGetListLength(OwnerNameQueries) > 0 || llGetListLength(PendingNameRequests) > 0) &&
            NameResolutionDeadline > 0 && current_time >= NameResolutionDeadline) {
            OwnerNameQueries = [];
            PendingNameRequests = [];
            check_bootstrap_complete();
        }

        // Transition to running
        if (BootstrapComplete && !RlvProbing &&
            llGetListLength(OwnerNameQueries) == 0 &&
            llGetListLength(PendingNameRequests) == 0) {
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

    dataserver(key query_id, string data) {
        handle_dataserver_name(query_id, data);
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == SETTINGS_BUS) {
            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
            }
        }
        else if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "notecard_loaded") {
                start_bootstrap();
            }
            else if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
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
            if (msg_type == "notecard_loaded") {
                llResetScript();
            }
            else if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
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
