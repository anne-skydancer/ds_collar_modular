/*--------------------
PLUGIN: plugin_status.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Read-only collar status display for owners and observers
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads via
  get_policy_buttons() and btn_allowed(). Removed PLUGIN_MIN_ACL and
  min_acl from kernel registration message. View-only plugin with empty
  button lists — visible in root menu but no action buttons beyond Back.
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_status";
string PLUGIN_LABEL = "Status";

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER = "owner";
string KEY_OWNERS = "owners";
string KEY_TRUSTEES = "trustees";
string KEY_BLACKLIST = "blacklist";
string KEY_PUBLIC_ACCESS = "public_mode";
string KEY_LOCKED = "locked";
string KEY_TPE_MODE = "tpe_mode";

/* -------------------- STATE -------------------- */
// Settings cache
integer MultiOwnerMode = FALSE;
key OwnerKey = NULL_KEY;
list OwnerKeys = [];
string OwnerHonorific = "";
string OwnersJson = "{}";
list TrusteeKeys = [];
string TrusteesJson = "{}";
list BlacklistKeys = [];
integer PublicAccess = FALSE;
integer Locked = FALSE;
integer TpeMode = FALSE;

// Display name resolution
string OwnerDisplay = "";
key OwnerDisplayQuery = NULL_KEY;
key OwnerLegacyQuery = NULL_KEY;

// Multi-owner display names
list OwnerDisplayNames = [];
list OwnerNameQueries = [];

// Trustee display names
list TrusteeDisplayNames = [];
list TrusteeNameQueries = [];

// Session management
key CurrentUser = NULL_KEY;
list gPolicyButtons = [];
string SessionId = "";

/* -------------------- HELPERS -------------------- */



integer is_json_arr(string s) {
    return (llGetSubString(s, 0, 0) == "[");
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD POLICY HELPER -------------------- */
list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("policy:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

request_settings_sync() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings_get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

register_self() {
    // Write button visibility policy to LSD (view-only, empty button lists for all ACL levels)
    llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "",
        "2", "",
        "3", "",
        "4", "",
        "5", ""
    ]));

    // Register with kernel
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- SETTINGS CONSUMPTION -------------------- */

apply_settings_sync(string msg) {
    string kv_json = llJsonGetValue(msg, ["kv"]);
    if (kv_json == JSON_INVALID) return;

    integer previous_mode = MultiOwnerMode;
    key previous_owner = OwnerKey;
    list previous_owners = OwnerKeys;

    // Reset to defaults
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    OwnerHonorific = "";
    OwnersJson = "{}";
    TrusteeKeys = [];
    TrusteesJson = "{}";
    BlacklistKeys = [];
    PublicAccess = FALSE;
    Locked = FALSE;
    TpeMode = FALSE;

    // Load values
    string tmp = llJsonGetValue(kv_json, [KEY_MULTI_OWNER_MODE]);
    if (tmp != JSON_INVALID) {
        MultiOwnerMode = (integer)tmp;
    }

    // Single owner: JSON object {uuid:honorific}
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

    // Multi-owner: JSON object {uuid:honorific, ...}
    obj = llJsonGetValue(kv_json, [KEY_OWNERS]);
    if (obj != JSON_INVALID) {
        if (llJsonValueType(obj, []) == JSON_OBJECT) {
            OwnersJson = obj;
            list pairs = llJson2List(obj);
            integer oi = 0;
            integer olen = llGetListLength(pairs);
            while (oi < olen) {
                OwnerKeys += [llList2String(pairs, oi)];
                oi += 2;
            }
        }
    }

    string trustees_raw = llJsonGetValue(kv_json, [KEY_TRUSTEES]);
    if (trustees_raw != JSON_INVALID) {
        if (llJsonValueType(trustees_raw, []) == JSON_OBJECT) {
            TrusteesJson = trustees_raw;
            list pairs = llJson2List(trustees_raw);
            TrusteeKeys = [];
            integer pi = 0;
            integer plen = llGetListLength(pairs);
            while (pi < plen) {
                TrusteeKeys += [llList2String(pairs, pi)];
                pi += 2;
            }
        }
        else if (is_json_arr(trustees_raw)) {
            TrusteeKeys = llJson2List(trustees_raw);
        }
    }

    string blacklist_json = llJsonGetValue(kv_json, [KEY_BLACKLIST]);
    if (blacklist_json != JSON_INVALID) {
        if (is_json_arr(blacklist_json)) {
            BlacklistKeys = llJson2List(blacklist_json);
        }
    }

    tmp = llJsonGetValue(kv_json, [KEY_PUBLIC_ACCESS]);
    if (tmp != JSON_INVALID) {
        PublicAccess = (integer)tmp;
    }

    tmp = llJsonGetValue(kv_json, [KEY_LOCKED]);
    if (tmp != JSON_INVALID) {
        Locked = (integer)tmp;
    }

    tmp = llJsonGetValue(kv_json, [KEY_TPE_MODE]);
    if (tmp != JSON_INVALID) {
        TpeMode = (integer)tmp;
    }

    // Check if we need to refresh owner names
    integer needs_refresh = FALSE;

    if (MultiOwnerMode != previous_mode) {
        needs_refresh = TRUE;
    }
    else if (MultiOwnerMode) {
        if (OwnerKeys != previous_owners) {
            needs_refresh = TRUE;
        }
    }
    else {
        if (OwnerKey != previous_owner) {
            needs_refresh = TRUE;
        }
    }

    if (needs_refresh) {
        request_owner_names();
    }

    // Always refresh trustee names on full sync
    request_trustee_names();
}

apply_settings_delta(string msg) {
    string op = llJsonGetValue(msg, ["op"]);
    if (op == JSON_INVALID) return;

    if (op == "set") {
        string changes = llJsonGetValue(msg, ["changes"]);
        if (changes == JSON_INVALID) return;

        integer needs_refresh = FALSE;

        if ((llJsonGetValue(changes, [KEY_MULTI_OWNER_MODE]) != JSON_INVALID)) {
            MultiOwnerMode = (integer)llJsonGetValue(changes, [KEY_MULTI_OWNER_MODE]);
            needs_refresh = TRUE;
        }

        // Single owner changed (full JSON object broadcast)
        string obj = llJsonGetValue(changes, [KEY_OWNER]);
        if (obj != JSON_INVALID) {
            OwnerKey = NULL_KEY;
            OwnerHonorific = "";
            if (llJsonValueType(obj, []) == JSON_OBJECT) {
                list pairs = llJson2List(obj);
                if (llGetListLength(pairs) >= 2) {
                    OwnerKey = (key)llList2String(pairs, 0);
                    OwnerHonorific = llList2String(pairs, 1);
                }
            }
            needs_refresh = TRUE;
        }

        // Multi-owner changed (full JSON object broadcast)
        obj = llJsonGetValue(changes, [KEY_OWNERS]);
        if (obj != JSON_INVALID) {
            OwnerKeys = [];
            OwnersJson = "{}";
            if (llJsonValueType(obj, []) == JSON_OBJECT) {
                OwnersJson = obj;
                list pairs = llJson2List(obj);
                integer oi = 0;
                integer olen = llGetListLength(pairs);
                while (oi < olen) {
                    OwnerKeys += [llList2String(pairs, oi)];
                    oi += 2;
                }
            }
            needs_refresh = TRUE;
        }

        string tmp = llJsonGetValue(changes, [KEY_PUBLIC_ACCESS]);
        if (tmp != JSON_INVALID) {
            PublicAccess = (integer)tmp;
        }

        tmp = llJsonGetValue(changes, [KEY_LOCKED]);
        if (tmp != JSON_INVALID) {
            Locked = (integer)tmp;
        }

        tmp = llJsonGetValue(changes, [KEY_TPE_MODE]);
        if (tmp != JSON_INVALID) {
            TpeMode = (integer)tmp;
        }

        if (needs_refresh) {
            request_owner_names();
        }

        // Trustees changed (full JSON object broadcast)
        string trustees_raw = llJsonGetValue(changes, [KEY_TRUSTEES]);
        if (trustees_raw != JSON_INVALID) {
            if (llJsonValueType(trustees_raw, []) == JSON_OBJECT) {
                TrusteesJson = trustees_raw;
                list pairs = llJson2List(trustees_raw);
                TrusteeKeys = [];
                integer ti = 0;
                integer tlen = llGetListLength(pairs);
                while (ti < tlen) {
                    TrusteeKeys += [llList2String(pairs, ti)];
                    ti += 2;
                }
                request_trustee_names();
            }
        }

    }
}

/* -------------------- OWNER NAME RESOLUTION -------------------- */

request_owner_names() {
    if (MultiOwnerMode) {
        OwnerDisplayNames = [];
        OwnerNameQueries = [];

        integer i;
        integer count = llGetListLength(OwnerKeys);
        for (i = 0; i < count; i++) {
            key owner_key = llList2Key(OwnerKeys, i);
            OwnerDisplayNames += [""];  // Placeholder aligned with OwnerKeys
            if (owner_key != NULL_KEY) {
                key query_id = llRequestDisplayName(owner_key);
                OwnerNameQueries += [query_id];
            }
            else {
                OwnerNameQueries += [NULL_KEY];
            }
        }

    }
    else {
        if (OwnerKey != NULL_KEY) {
            OwnerDisplay = "";
            OwnerDisplayQuery = llRequestDisplayName(OwnerKey);
            OwnerLegacyQuery = llRequestAgentData(OwnerKey, DATA_NAME);
        }
        else {
            OwnerDisplay = "";
            OwnerDisplayQuery = NULL_KEY;
            OwnerLegacyQuery = NULL_KEY;
        }
    }
}

request_trustee_names() {
    TrusteeDisplayNames = [];
    TrusteeNameQueries = [];

    integer i;
    integer count = llGetListLength(TrusteeKeys);
    for (i = 0; i < count; i++) {
        key trustee_key = llList2Key(TrusteeKeys, i);
        TrusteeDisplayNames += [""];  // Placeholder aligned with TrusteeKeys
        if (trustee_key != NULL_KEY) {
            key query_id = llRequestDisplayName(trustee_key);
            TrusteeNameQueries += [query_id];
        }
        else {
            TrusteeNameQueries += [NULL_KEY];
        }
    }
}

string get_owner_label() {
    if (OwnerDisplay != "") {
        return OwnerDisplay;
    }
    else if (OwnerKey != NULL_KEY) {
        return llKey2Name(OwnerKey);
    }
    else {
        return "(unowned)";
    }
}

/* -------------------- STATUS REPORT BUILDING -------------------- */

string build_status_report() {
    string status_text = "Collar Status:\n\n";

    // Owner information
    if (MultiOwnerMode) {
        integer owner_count = llGetListLength(OwnerKeys);
        if (owner_count > 0) {
            status_text += "Owners:\n";

            integer i;
            integer disp_count = llGetListLength(OwnerDisplayNames);
            for (i = 0; i < owner_count; i++) {
                key owner_key = llList2Key(OwnerKeys, i);
                string honorific = llJsonGetValue(OwnersJson, [(string)owner_key]);
                if (honorific == JSON_INVALID) honorific = "";

                string display_name = "";
                if (i < disp_count) {
                    display_name = llList2String(OwnerDisplayNames, i);
                }

                if (display_name == "") {
                    display_name = llKey2Name(owner_key);
                }

                if (honorific != "") {
                    status_text += "  " + honorific + " " + display_name + "\n";
                }
                else {
                    status_text += "  " + display_name + "\n";
                }
            }
        }
        else {
            status_text += "Owners: Uncommitted\n";
        }
    }
    else {
        if (OwnerKey != NULL_KEY) {
            string owner_label = get_owner_label();
            if (OwnerHonorific != "") {
                status_text += "Owner: " + OwnerHonorific + " " + owner_label + "\n";
            }
            else {
                status_text += "Owner: " + owner_label + "\n";
            }
        }
        else {
            status_text += "Owner: Uncommitted\n";
        }
    }

    // Trustee information
    integer trustee_count = llGetListLength(TrusteeKeys);
    if (trustee_count > 0) {
        status_text += "Trustees:\n";

        integer i;
        integer tdisp_count = llGetListLength(TrusteeDisplayNames);
        for (i = 0; i < trustee_count; i++) {
            key trustee_key = llList2Key(TrusteeKeys, i);
            string honorific = llJsonGetValue(TrusteesJson, [(string)trustee_key]);
            if (honorific == JSON_INVALID) honorific = "";

            string display_name = "";
            if (i < tdisp_count) {
                display_name = llList2String(TrusteeDisplayNames, i);
            }

            if (display_name == "") {
                display_name = llKey2Name(trustee_key);
            }

            if (honorific != "") {
                status_text += "  " + honorific + " " + display_name + "\n";
            }
            else {
                status_text += "  " + display_name + "\n";
            }
        }
    }
    else {
        status_text += "Trustees: none\n";
    }

    // Public access
    if (PublicAccess) {
        status_text += "Public Access: On\n";
    }
    else {
        status_text += "Public Access: Off\n";
    }

    // Lock status
    if (Locked) {
        status_text += "Collar locked: Yes\n";
    }
    else {
        status_text += "Collar locked: No\n";
    }

    // TPE mode
    if (TpeMode) {
        status_text += "TPE Mode: On\n";
    }
    else {
        status_text += "TPE Mode: Off\n";
    }

    return status_text;
}

/* -------------------- UI / MENU SYSTEM -------------------- */

show_status_menu() {
    SessionId = generate_session_id();

    string status_report = build_status_report();

    list buttons = ["Back"];
    string buttons_json = llList2Json(JSON_ARRAY, buttons);

    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "message", status_report,
        "buttons", buttons_json,
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string button) {
    if (button == "Back") {
        ui_return_root();
        cleanup_session();
        return;
    }

    // Unknown button - shouldn't happen
}

/* -------------------- UI NAVIGATION -------------------- */

ui_return_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- SESSION CLEANUP -------------------- */

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "dialog_close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    gPolicyButtons = [];
    SessionId = "";
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        cleanup_session();

        // Reset display name cache
        OwnerDisplay = "";
        OwnerDisplayQuery = NULL_KEY;
        OwnerLegacyQuery = NULL_KEY;
        OwnerDisplayNames = [];
        OwnerNameQueries = [];
        TrusteeDisplayNames = [];
        TrusteeNameQueries = [];

        register_self();
        request_settings_sync();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* -------------------- KERNEL LIFECYCLE -------------------- */if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "register_now") {
                register_self();
                return;
            }

            if (msg_type == "ping") {
                send_pong();
                return;
            }

            return;
        }

        /* -------------------- SETTINGS SYNC/DELTA -------------------- */if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "settings_sync") {
                apply_settings_sync(msg);
                return;
            }

            if (msg_type == "settings_delta") {
                apply_settings_delta(msg);
                return;
            }

            return;
        }

        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "start") {
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                CurrentUser = id;

                // Load policy buttons (will be empty for view-only plugin)
                integer user_acl = (integer)llJsonGetValue(msg, ["acl"]);
                gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, user_acl);

                show_status_menu();
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSE -------------------- */if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "dialog_response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

                string button = llJsonGetValue(msg, ["button"]);
                if (button == JSON_INVALID) return;

                string user_str = llJsonGetValue(msg, ["user"]);
                if (user_str == JSON_INVALID) return;
                key user = (key)user_str;

                if (user != CurrentUser) return;

                handle_button_click(button);
                return;
            }

            if (msg_type == "dialog_timeout") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

                cleanup_session();
                return;
            }

            return;
        }
    }

    dataserver(key query_id, string data) {
        // Check trustee name queries first
        integer tidx = llListFindList(TrusteeNameQueries, [query_id]);
        if (tidx != -1) {
            if (tidx < llGetListLength(TrusteeDisplayNames)) {
                TrusteeDisplayNames = llListReplaceList(TrusteeDisplayNames, [data], tidx, tidx);
            }
            return;
        }

        // Multi-owner mode
        if (MultiOwnerMode) {
            integer idx = llListFindList(OwnerNameQueries, [query_id]);
            if (idx != -1) {
                if (idx < llGetListLength(OwnerDisplayNames)) {
                    OwnerDisplayNames = llListReplaceList(OwnerDisplayNames, [data], idx, idx);
                }
            }
        }
        // Single owner mode
        else {
            if (query_id == OwnerDisplayQuery) {
                OwnerDisplay = data;
            }
            else if (query_id == OwnerLegacyQuery) {
                if (OwnerDisplay == "") {
                    OwnerDisplay = data;
                }
            }
        }
    }
}
