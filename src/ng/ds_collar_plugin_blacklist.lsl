/* =============================================================================
   PLUGIN: ds_collar_plugin_blacklist.lsl (v2.0 - Kanban Messaging Migration)

   PURPOSE: Blacklist management with sensor-based avatar selection

   FEATURES:
   - Add nearby avatars to blacklist (via sensor scan)
   - Remove avatars from blacklist
   - Persistent storage in settings
   - Supports both JSON array and legacy CSV formats

   ACL REQUIREMENTS:
   - Minimum: Owned (2)
   - Allowed: Owned, Trustee, Unowned, Primary Owner (2,3,4,5)

   TIER: 2 (Medium - uses sensor, multiple menus)

   KANBAN MIGRATION (v2.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   - Includes kDeltaAdd() and kDeltaDel() for list operations
   ============================================================================= */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

string CONTEXT = "blacklist";

/* ═══════════════════════════════════════════════════════════
   KANBAN UNIVERSAL HELPER (~500-800 bytes)
   ═══════════════════════════════════════════════════════════ */

string kFrom = "";  // Sender context (populated by kRecv)
string kTo = "";    // Recipient context (populated by kRecv)

kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, [
            "from", from,
            "payload", payload,
            "to", to
        ]),
        k
    );
}

string kRecv(string msg, string my_context) {
    // Quick validation: must be JSON object
    if (llGetSubString(msg, 0, 0) != "{") return "";

    // Extract from
    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    // Extract to
    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast "" or direct to my_context)
    if (to != "" && to != my_context) return "";

    // Extract payload
    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    // Set globals for routing
    kFrom = from;
    kTo = to;

    return payload;
}

string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

string kDeltaSet(string setting_key, string val) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", setting_key,
        "value", val
    ]);
}

string kDeltaAdd(string setting_key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_add",
        "key", setting_key,
        "elem", elem
    ]);
}

string kDeltaDel(string setting_key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_remove",
        "key", setting_key,
        "elem", elem
    ]);
}

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ═══════════════════════════════════════════════════════════
   PLUGIN IDENTITY
   ═══════════════════════════════════════════════════════════ */
string PLUGIN_LABEL = "Blacklist";
integer PLUGIN_MIN_ACL = 2;  // Owned minimum

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* ═══════════════════════════════════════════════════════════
   ACL REQUIREMENTS
   ═══════════════════════════════════════════════════════════ */
list ALLOWED_ACL_LEVELS = [2, 3, 4, 5];  // Owned+

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
string KEY_BLACKLIST = "blacklist";

/* ═══════════════════════════════════════════════════════════
   UI CONSTANTS
   ═══════════════════════════════════════════════════════════ */
string BTN_BACK = "Back";
string BTN_ADD = "+Blacklist";
string BTN_REMOVE = "-Blacklist";
float BLACKLIST_RADIUS = 5.0;

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
// Settings cache
list Blacklist = [];

// Session management
key CurrentUser = NULL_KEY;
integer CurrentUserAcl = -999;
string SessionId = "";
string MenuContext = "";  // "main", "add_scan", "add_pick", "remove"

// Sensor results
list CandidateKeys = [];

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[BLACKLIST] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return "blacklist_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

integer in_allowed_levels(integer level) {
    return (llListFindList(ALLOWED_ACL_LEVELS, [level]) != -1);
}

list blacklist_names() {
    list out = [];
    integer i = 0;
    integer count = llGetListLength(Blacklist);
    while (i < count) {
        key k = (key)llList2String(Blacklist, i);
        string nm = llGetDisplayName(k);
        if (nm == "") nm = (string)k;
        out += [nm];
        i += 1;
    }
    return out;
}

/* ═══════════════════════════════════════════════════════════
   LIFECYCLE
   ═══════════════════════════════════════════════════════════ */

register_self() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload([
            "label", PLUGIN_LABEL,
            "min_acl", PLUGIN_MIN_ACL,
            "script", llGetScriptName()
        ]),
        NULL_KEY
    );
    logd("Registered");
}

send_pong() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload(["pong", 1]),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

apply_settings_sync(string payload) {
    if (!json_has(payload, ["kv"])) return;

    string kv_json = llJsonGetValue(payload, ["kv"]);
    apply_blacklist_payload(kv_json);
}

apply_settings_delta(string payload) {
    if (!json_has(payload, ["op"])) return;

    string op = llJsonGetValue(payload, ["op"]);

    if (op == "set") {
        if (!json_has(payload, ["changes"])) return;
        string changes = llJsonGetValue(payload, ["changes"]);

        if (json_has(changes, [KEY_BLACKLIST])) {
            string new_value = llJsonGetValue(changes, [KEY_BLACKLIST]);
            parse_blacklist_value(new_value);
            logd("Delta set applied");
        }
    }
    else if (op == "list_add") {
        if (!json_has(payload, ["key"])) return;
        if (!json_has(payload, ["elem"])) return;

        string skey = llJsonGetValue(payload, ["key"]);
        if (skey == KEY_BLACKLIST) {
            string elem = llJsonGetValue(payload, ["elem"]);
            if (llListFindList(Blacklist, [elem]) == -1) {
                Blacklist += [elem];
                logd("Delta list_add: " + elem);
            }
        }
    }
    else if (op == "list_remove") {
        if (!json_has(payload, ["key"])) return;
        if (!json_has(payload, ["elem"])) return;

        string skey = llJsonGetValue(payload, ["key"]);
        if (skey == KEY_BLACKLIST) {
            string elem = llJsonGetValue(payload, ["elem"]);
            integer idx = llListFindList(Blacklist, [elem]);
            if (idx != -1) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
                logd("Delta list_remove: " + elem);
            }
        }
    }
}

apply_blacklist_payload(string kv_json) {
    if (!json_has(kv_json, [KEY_BLACKLIST])) {
        logd("No blacklist key in settings");
        Blacklist = [];
        return;
    }
    
    string raw = llJsonGetValue(kv_json, [KEY_BLACKLIST]);
    parse_blacklist_value(raw);
}

parse_blacklist_value(string raw) {
    if (raw == JSON_INVALID || raw == "[]" || raw == "" || raw == " ") {
        Blacklist = [];
        logd("Blacklist cleared");
        return;
    }
    
    // Try JSON array format first
    if (llGetSubString(raw, 0, 0) == "[") {
        list updated = [];
        integer i = 0;
        string val = llJsonGetValue(raw, [i]);
        while (val != JSON_INVALID) {
            if (val != "" && llListFindList(updated, [val]) == -1) {
                updated += [val];
            }
            i += 1;
            val = llJsonGetValue(raw, [i]);
        }
        Blacklist = updated;
        logd("Loaded blacklist (JSON): " + (string)llGetListLength(Blacklist) + " entries");
        return;
    }
    
    // Fall back to legacy CSV format
    list csv = llParseStringKeepNulls(raw, [","], []);
    list updated = [];
    integer j = 0;
    integer csv_len = llGetListLength(csv);
    while (j < csv_len) {
        string entry = llStringTrim(llList2String(csv, j), STRING_TRIM);
        if (entry != "" && llListFindList(updated, [entry]) == -1) {
            updated += [entry];
        }
        j += 1;
    }
    Blacklist = updated;
    logd("Loaded blacklist (CSV): " + (string)llGetListLength(Blacklist) + " entries");
}

persist_blacklist() {
    kSend(CONTEXT, "settings", SETTINGS_BUS,
        kDeltaSet(KEY_BLACKLIST, llList2Json(JSON_ARRAY, Blacklist)),
        NULL_KEY
    );
    logd("Persisted blacklist: " + (string)llGetListLength(Blacklist) + " entries");
}

/* ═══════════════════════════════════════════════════════════
   ACL MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

request_acl(key user_key) {
    kSend(CONTEXT, "auth", AUTH_BUS,
        kPayload(["avatar", (string)user_key]),
        user_key
    );
    logd("Requested ACL for " + llKey2Name(user_key));
}

handle_acl_result(string payload) {
    if (!json_has(payload, ["avatar"])) return;
    if (!json_has(payload, ["level"])) return;

    key avatar = (key)llJsonGetValue(payload, ["avatar"]);
    if (avatar != CurrentUser) return;

    integer level = (integer)llJsonGetValue(payload, ["level"]);
    CurrentUserAcl = level;

    // Check access
    if (!in_allowed_levels(level)) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        return_to_root();
        return;
    }

    logd("ACL result: " + (string)level + " for " + llKey2Name(avatar));
    show_main_menu();
}

/* ═══════════════════════════════════════════════════════════
   MENU DISPLAY
   ═══════════════════════════════════════════════════════════ */

show_main_menu() {
    integer count = llGetListLength(Blacklist);
    string body = "Blacklist Management\n\n";
    body += "Currently blacklisted: " + (string)count;

    list buttons = [
        BTN_BACK,
        BTN_ADD,
        BTN_REMOVE
    ];

    SessionId = generate_session_id();
    MenuContext = "main";

    kSend(CONTEXT, "dialogs", DIALOG_BUS,
        kPayload([
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", "Blacklist",
            "body", body,
            "buttons", llList2Json(JSON_ARRAY, buttons),
            "timeout", 60
        ]),
        NULL_KEY
    );
    logd("Showing main menu");
}

show_remove_menu() {
    if (llGetListLength(Blacklist) == 0) {
        llRegionSayTo(CurrentUser, 0, "Blacklist is empty.");
        show_main_menu();
        return;
    }

    list names = blacklist_names();

    SessionId = generate_session_id();
    MenuContext = "remove";

    kSend(CONTEXT, "dialogs", DIALOG_BUS,
        kPayload([
            "dialog_type", "numbered_list",
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", "Remove from Blacklist",
            "prompt", "Select avatar to remove:",
            "items", llList2Json(JSON_ARRAY, names),
            "timeout", 60
        ]),
        NULL_KEY
    );
    logd("Showing remove menu");
}

show_add_candidates() {
    if (llGetListLength(CandidateKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        show_main_menu();
        return;
    }

    // Build list of names
    list names = [];
    integer i = 0;
    integer len = llGetListLength(CandidateKeys);
    while (i < len && i < 11) {
        key k = (key)llList2String(CandidateKeys, i);
        string name = llGetDisplayName(k);
        if (name == "") name = (string)k;
        names += [name];
        i += 1;
    }

    SessionId = generate_session_id();
    MenuContext = "add_pick";

    kSend(CONTEXT, "dialogs", DIALOG_BUS,
        kPayload([
            "dialog_type", "numbered_list",
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", "Add to Blacklist",
            "prompt", "Select avatar to blacklist:",
            "items", llList2Json(JSON_ARRAY, names),
            "timeout", 60
        ]),
        NULL_KEY
    );
    logd("Showing add candidates menu");
}

/* ═══════════════════════════════════════════════════════════
   NAVIGATION
   ═══════════════════════════════════════════════════════════ */

return_to_root() {
    kSend(CONTEXT, "ui", UI_BUS,
        kPayload(["user", (string)CurrentUser]),
        NULL_KEY
    );
    cleanup_session();
}

/* ═══════════════════════════════════════════════════════════
   SESSION CLEANUP
   ═══════════════════════════════════════════════════════════ */

cleanup_session() {
    CurrentUser = NULL_KEY;
    CurrentUserAcl = -999;
    SessionId = "";
    MenuContext = "";
    CandidateKeys = [];
    logd("Session cleaned up");
}

/* ═══════════════════════════════════════════════════════════
   DIALOG HANDLERS
   ═══════════════════════════════════════════════════════════ */

handle_dialog_response(string payload) {
    if (!json_has(payload, ["session_id"])) return;
    if (!json_has(payload, ["button"])) return;

    string session = llJsonGetValue(payload, ["session_id"]);
    if (session != SessionId) return;

    string button = llJsonGetValue(payload, ["button"]);
    logd("Button pressed: " + button + " in context: " + MenuContext);

    // Re-validate ACL
    if (!in_allowed_levels(CurrentUserAcl)) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        return_to_root();
        return;
    }

    // Handle Back button
    if (button == BTN_BACK) {
        if (MenuContext == "main") {
            return_to_root();
            return;
        }
        show_main_menu();
        return;
    }

    // Main menu actions
    if (MenuContext == "main") {
        if (button == BTN_ADD) {
            MenuContext = "add_scan";
            CandidateKeys = [];
            logd("Starting sensor scan");
            llSensor("", NULL_KEY, AGENT, BLACKLIST_RADIUS, PI);
            return;
        }
        if (button == BTN_REMOVE) {
            show_remove_menu();
            return;
        }
    }

    // Remove menu - numbered selection
    if (MenuContext == "remove") {
        integer idx = (integer)button - 1;
        if (idx >= 0 && idx < llGetListLength(Blacklist)) {
            string removed = llList2String(Blacklist, idx);
            Blacklist = llDeleteSubList(Blacklist, idx, idx);
            persist_blacklist();
            llRegionSayTo(CurrentUser, 0, "Removed from blacklist.");
        }
        show_main_menu();
        return;
    }

    // Add pick menu - numbered selection
    if (MenuContext == "add_pick") {
        integer idx = (integer)button - 1;
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            string entry = llList2String(CandidateKeys, idx);
            if (entry != "" && llListFindList(Blacklist, [entry]) == -1) {
                Blacklist += [entry];
                persist_blacklist();
                llRegionSayTo(CurrentUser, 0, "Added to blacklist.");
            }
        }
        show_main_menu();
        return;
    }

    // Unknown context - return to main
    logd("Unknown menu context: " + MenuContext);
    show_main_menu();
}

handle_dialog_timeout(string payload) {
    if (!json_has(payload, ["session_id"])) return;

    string session = llJsonGetValue(payload, ["session_id"]);
    if (session != SessionId) return;

    logd("Dialog timeout");
    cleanup_session();
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default {
    state_entry() {
        cleanup_session();
        register_self();

        // Request initial settings
        kSend(CONTEXT, "settings", SETTINGS_BUS,
            kPayload(["get", 1]),
            NULL_KEY
        );

        logd("Ready");
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
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        // Route by channel + kFrom + payload structure

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE && kFrom == "kernel") {
            // Targeted soft_reset: has "context" field
            if (json_has(payload, ["context"])) {
                string target_context = llJsonGetValue(payload, ["context"]);
                if (target_context != "" && target_context != CONTEXT) {
                    return; // Not for us
                }
                llResetScript();
            }
            // Soft reset with "reset" marker
            else if (json_has(payload, ["reset"])) {
                llResetScript();
            }
            // Register now: has "register_now" marker
            else if (json_has(payload, ["register_now"])) {
                register_self();
            }
            // Ping: has "ping" marker
            else if (json_has(payload, ["ping"])) {
                send_pong();
            }
        }

        /* ===== SETTINGS BUS ===== */
        else if (num == SETTINGS_BUS && kFrom == "settings") {
            // Full sync: has "kv" field
            if (json_has(payload, ["kv"])) {
                apply_settings_sync(payload);
            }
            // Delta update: has "op" field
            else if (json_has(payload, ["op"])) {
                apply_settings_delta(payload);
            }
        }

        /* ===== UI START ===== */
        else if (num == UI_BUS) {
            // UI start: for our context
            if (kTo == CONTEXT && json_has(payload, ["user"])) {
                CurrentUser = id;
                request_acl(id);
            }
        }

        /* ===== AUTH RESULT ===== */
        else if (num == AUTH_BUS && kFrom == "auth") {
            // ACL result: has "avatar" and "level" fields
            if (json_has(payload, ["avatar"]) && json_has(payload, ["level"])) {
                handle_acl_result(payload);
            }
        }

        /* ===== DIALOG RESPONSES ===== */
        else if (num == DIALOG_BUS && kFrom == "dialogs") {
            // Dialog response: has "session_id" and "button" fields
            if (json_has(payload, ["session_id"]) && json_has(payload, ["button"])) {
                handle_dialog_response(payload);
            }
            // Dialog timeout: has "session_id" but no "button"
            else if (json_has(payload, ["session_id"]) && !json_has(payload, ["button"])) {
                handle_dialog_timeout(payload);
            }
        }
    }
    
    sensor(integer count) {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;
        
        list candidates = [];
        key owner = llGetOwner();
        integer i = 0;
        
        while (i < count) {
            key k = llDetectedKey(i);
            string entry = (string)k;
            
            if (k != owner && llListFindList(Blacklist, [entry]) == -1) {
                candidates += [entry];
            }
            i += 1;
        }
        
        CandidateKeys = candidates;
        show_add_candidates();
    }
    
    no_sensor() {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;
        
        CandidateKeys = [];
        show_add_candidates();
    }
}
