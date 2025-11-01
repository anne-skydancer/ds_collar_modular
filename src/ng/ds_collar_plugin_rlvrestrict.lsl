/* =============================================================================
   DS Collar - RLV Restrict Plugin (v2.0 - Kanban Messaging Migration)

   FEATURES:
   - RLV restriction management with category organization
   - Persistent restriction state across relogs
   - Emergency clear via SOS integration
   - Paged category menus for large restriction sets

   ACL: Trustee (3) and above

   KANBAN MIGRATION (v2.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "rlvrestrict";

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

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_LABEL = "Restrict";
integer PLUGIN_MIN_ACL = 3;  // Trustee+

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */

string KEY_RESTRICTIONS = "rlvrestrict_list";

/* ═══════════════════════════════════════════════════════════
   RESTRICTION STATE
   ═══════════════════════════════════════════════════════════ */

integer MAX_RESTRICTIONS = 32;
list Restrictions = [];  // List of active RLV commands (e.g., "@shownames")

/* ═══════════════════════════════════════════════════════════
   CATEGORIES
   ═══════════════════════════════════════════════════════════ */

string CAT_NAME_INVENTORY = "Inventory";
string CAT_NAME_SPEECH    = "Speech";
string CAT_NAME_TRAVEL    = "Travel";
string CAT_NAME_OTHER     = "Other";

list CAT_INV    = ["@detachall", "@addoutfit", "@remoutfit", "@remattach", "@addattach", "@attachall", "@showinv", "@viewnote", "@viewscript"];
list CAT_SPEECH = ["@sendchat", "@recvim", "@sendim", "@startim", "@chatshout", "@chatwhisper"];
list CAT_TRAVEL = ["@tptlm", "@tploc", "@tplure"];
list CAT_OTHER  = ["@edit", "@rez", "@touchall", "@touchworld", "@accepttp", "@shownames", "@sit", "@unsit", "@stand"];

list LABEL_INV    = ["Det. All:", "+ Outfit:", "- Outfit:", "- Attach:", "+ Attach:", "Att. All:", "Inv:", "Notes:", "Scripts:"];
list LABEL_SPEECH = ["Chat:", "Recv IM:", "Send IM:", "Start IM:", "Shout:", "Whisper:"];
list LABEL_TRAVEL = ["Map TP:", "Loc. TP:", "TP:"];
list LABEL_OTHER  = ["Edit:", "Rez:", "Touch:", "Touch Wld:", "OK TP:", "Names:", "Sit:", "Unsit:", "Stand:"];

/* ═══════════════════════════════════════════════════════════
   UI SESSION STATE
   ═══════════════════════════════════════════════════════════ */

// Session state
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";
string MenuContext = "";      // "main", "category"
string CurrentCategory = "";
integer CurrentPage = 0;

integer DIALOG_PAGE_SIZE = 9;  // 9 items + 3 nav buttons = 12 total

/* ═══════════════════════════════════════════════════════════
   HELPER FUNCTIONS
   ═══════════════════════════════════════════════════════════ */

integer json_has(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[RLVRESTRICT] " + msg);
    return FALSE;
}

string generate_session_id() {
    return CONTEXT + "_" + (string)llGetUnixTime();
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
}

send_pong() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload(["pong", 1]),
        NULL_KEY
    );
}

cleanup_session() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    AclPending = FALSE;
    SessionId = "";
    MenuContext = "";
    CurrentCategory = "";
    CurrentPage = 0;
    logd("Session cleaned up");
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS PERSISTENCE
   ═══════════════════════════════════════════════════════════ */

persist_restrictions() {
    string csv = llDumpList2String(Restrictions, ",");

    kSend(CONTEXT, "settings", SETTINGS_BUS,
        kDeltaSet(KEY_RESTRICTIONS, csv),
        NULL_KEY
    );
}

apply_settings_sync(string payload) {
    if (!json_has(payload, ["kv"])) return;
    string kv_json = llJsonGetValue(payload, ["kv"]);

    if (json_has(kv_json, [KEY_RESTRICTIONS])) {
        string csv = llJsonGetValue(kv_json, [KEY_RESTRICTIONS]);

        if (csv != "") {
            Restrictions = llParseString2List(csv, [","], []);
            logd("Loaded " + (string)llGetListLength(Restrictions) + " restrictions from settings");

            // Reapply all restrictions
            integer i = 0;
            integer count = llGetListLength(Restrictions);
            while (i < count) {
                string restr_cmd = llList2String(Restrictions, i);
                llOwnerSay(restr_cmd + "=y");
                i = i + 1;
            }
        }
        else {
            Restrictions = [];
            logd("No restrictions loaded");
        }
    }

    logd("Settings sync applied");
}

apply_settings_delta(string payload) {
    string op = llJsonGetValue(payload, ["op"]);

    if (op == "set") {
        string setting_key = llJsonGetValue(payload, ["key"]);
        string value = llJsonGetValue(payload, ["value"]);

        if (setting_key == KEY_RESTRICTIONS) {
            // Clear all current restrictions
            integer i = 0;
            integer count = llGetListLength(Restrictions);
            while (i < count) {
                string restr_cmd = llList2String(Restrictions, i);
                llOwnerSay("@clear=" + llGetSubString(restr_cmd, 1, -1));
                i = i + 1;
            }

            // Load new list
            if (value != "") {
                Restrictions = llParseString2List(value, [","], []);
            }
            else {
                Restrictions = [];
            }

            // Apply new restrictions
            i = 0;
            count = llGetListLength(Restrictions);
            while (i < count) {
                string restr_cmd = llList2String(Restrictions, i);
                llOwnerSay(restr_cmd + "=y");
                i = i + 1;
            }

            logd("Delta: restrictions updated");
        }
    }
}

/* ═══════════════════════════════════════════════════════════
   ACL
   ═══════════════════════════════════════════════════════════ */

request_acl(key user) {
    AclPending = TRUE;
    kSend(CONTEXT, "auth", AUTH_BUS,
        kPayload(["avatar", (string)user]),
        user
    );
    logd("ACL query sent for " + llKey2Name(user));
}

handle_acl_result(string payload) {
    if (!AclPending) return;

    if (!json_has(payload, ["avatar"]) || !json_has(payload, ["level"])) return;

    key avatar = (key)llJsonGetValue(payload, ["avatar"]);
    if (avatar != CurrentUser) return;

    UserAcl = (integer)llJsonGetValue(payload, ["level"]);
    AclPending = FALSE;

    if (UserAcl < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanup_session();
        return;
    }

    show_main();
    logd("ACL received: " + (string)UserAcl);
}

/* ═══════════════════════════════════════════════════════════
   RESTRICTION LOGIC
   ═══════════════════════════════════════════════════════════ */

integer restriction_idx(string restr_cmd) {
    return llListFindList(Restrictions, [restr_cmd]);
}

toggle_restriction(string restr_cmd) {
    integer idx = restriction_idx(restr_cmd);
    
    if (idx != -1) {
        // Remove restriction
        Restrictions = llDeleteSubList(Restrictions, idx, idx);
        llOwnerSay("@clear=" + llGetSubString(restr_cmd, 1, -1));
        logd("Removed restriction: " + restr_cmd);
    }
    else {
        // Add restriction
        if (llGetListLength(Restrictions) >= MAX_RESTRICTIONS) {
            llRegionSayTo(CurrentUser, 0, "Cannot add restriction: limit reached.");
            return;
        }
        
        Restrictions += [restr_cmd];
        llOwnerSay(restr_cmd + "=y");
        logd("Added restriction: " + restr_cmd);
    }
    
    persist_restrictions();
}

remove_all_restrictions() {
    integer i = 0;
    integer count = llGetListLength(Restrictions);
    while (i < count) {
        string restr_cmd = llList2String(Restrictions, i);
        llOwnerSay("@clear=" + llGetSubString(restr_cmd, 1, -1));
        i = i + 1;
    }
    
    Restrictions = [];
    persist_restrictions();
    logd("All restrictions removed via safeword");
}

/* ═══════════════════════════════════════════════════════════
   CATEGORY HELPERS
   ═══════════════════════════════════════════════════════════ */

list get_category_list(string cat_name) {
    if (cat_name == CAT_NAME_INVENTORY) return CAT_INV;
    if (cat_name == CAT_NAME_SPEECH) return CAT_SPEECH;
    if (cat_name == CAT_NAME_TRAVEL) return CAT_TRAVEL;
    if (cat_name == CAT_NAME_OTHER) return CAT_OTHER;
    return [];
}

list get_category_labels(string cat_name) {
    if (cat_name == CAT_NAME_INVENTORY) return LABEL_INV;
    if (cat_name == CAT_NAME_SPEECH) return LABEL_SPEECH;
    if (cat_name == CAT_NAME_TRAVEL) return LABEL_TRAVEL;
    if (cat_name == CAT_NAME_OTHER) return LABEL_OTHER;
    return [];
}

string label_to_command(string btn_label, list cat_cmds, list cat_labels) {
    // Remove checkbox prefix
    string clean_label = btn_label;
    if (llGetSubString(btn_label, 0, 3) == "[X] " || llGetSubString(btn_label, 0, 3) == "[ ] ") {
        clean_label = llGetSubString(btn_label, 4, -1);
    }
    
    integer label_idx = llListFindList(cat_labels, [clean_label]);
    if (label_idx != -1) {
        return llList2String(cat_cmds, label_idx);
    }
    return "";
}

/* ═══════════════════════════════════════════════════════════
   UI NAVIGATION
   ═══════════════════════════════════════════════════════════ */

return_to_root() {
    kSend(CONTEXT, "ui", UI_BUS,
        kPayload(["user", (string)CurrentUser]),
        NULL_KEY
    );
    cleanup_session();
}

/* ═══════════════════════════════════════════════════════════
   MENUS
   ═══════════════════════════════════════════════════════════ */

show_main() {
    SessionId = generate_session_id();
    MenuContext = "main";

    string body = "RLV Restrictions\n\nActive: " + (string)llGetListLength(Restrictions) + "/" + (string)MAX_RESTRICTIONS;

    list buttons = [
        "Back",
        CAT_NAME_INVENTORY,
        CAT_NAME_SPEECH,
        CAT_NAME_TRAVEL,
        CAT_NAME_OTHER,
        "Clear all"
    ];

    kSend(CONTEXT, "dialogs", DIALOG_BUS,
        kPayload([
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", PLUGIN_LABEL,
            "body", body,
            "buttons", llList2Json(JSON_ARRAY, buttons),
            "timeout", 60
        ]),
        NULL_KEY
    );
}

show_category_menu(string cat_name, integer page_num) {
    SessionId = generate_session_id();
    MenuContext = "category";
    CurrentCategory = cat_name;
    CurrentPage = page_num;
    
    list cat_cmds = get_category_list(cat_name);
    list cat_labels = get_category_labels(cat_name);
    integer total_items = llGetListLength(cat_cmds);
    
    if (total_items == 0) {
        llRegionSayTo(CurrentUser, 0, "Empty category.");
        show_main();
        return;
    }
    
    // Calculate page bounds
    integer start_idx = page_num * DIALOG_PAGE_SIZE;
    integer end_idx = start_idx + DIALOG_PAGE_SIZE - 1;
    if (end_idx >= total_items) {
        end_idx = total_items - 1;
    }
    
    // Build button list with checkbox prefixes
    list page_buttons = [];
    integer i = start_idx;
    while (i <= end_idx) {
        string cmd = llList2String(cat_cmds, i);
        string label = llList2String(cat_labels, i);
        
        integer is_active = (restriction_idx(cmd) != -1);
        if (is_active) {
            label = "[X] " + label;
        }
        else {
            label = "[ ] " + label;
        }
        
        page_buttons += [label];
        i = i + 1;
    }
    
    // Calculate max page
    integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;
    
    // Layout: Nav buttons in bottom-left, content fills from bottom-right upward
    // [item 8] [item 9] [item 10]
    // [item 5] [item 6] [item 7]
    // [item 2] [item 3] [item 4]
    // [Back]   [<<]     [>>] [item 1]
    
    // Reverse the order so items fill bottom-right to top-left
    list reversed = [];
    i = llGetListLength(page_buttons) - 1;
    while (i >= 0) {
        reversed += [llList2String(page_buttons, i)];
        i = i - 1;
    }
    
    // Add nav buttons in bottom-left corner (positions 0, 1, 2)
    reversed = ["Back", "<<", ">>"] + reversed;
    
    string body = cat_name + " (" + (string)(page_num + 1) + "/" + (string)(max_page + 1) + ")\n\nActive: " + (string)llGetListLength(Restrictions);

    kSend(CONTEXT, "dialogs", DIALOG_BUS,
        kPayload([
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", cat_name,
            "body", body,
            "buttons", llList2Json(JSON_ARRAY, reversed),
            "timeout", 60
        ]),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   DIALOG HANDLERS
   ═══════════════════════════════════════════════════════════ */

handle_dialog_response(string payload) {
    if (!json_has(payload, ["session_id"]) || !json_has(payload, ["button"])) return;

    string recv_session = llJsonGetValue(payload, ["session_id"]);
    if (recv_session != SessionId) return;

    string button = llJsonGetValue(payload, ["button"]);
    
    // Main menu
    if (MenuContext == "main") {
        if (button == "Back") {
            return_to_root();
        }
        else if (button == CAT_NAME_INVENTORY || button == CAT_NAME_SPEECH || 
                 button == CAT_NAME_TRAVEL || button == CAT_NAME_OTHER) {
            show_category_menu(button, 0);
        }
        else if (button == "Clear all") {
            remove_all_restrictions();
            llRegionSayTo(CurrentUser, 0, "All restrictions removed.");
            show_main();
        }
    }
    // Category menu
    else if (MenuContext == "category") {
        if (button == "Back") {
            show_main();
        }
        else if (button == "<<") {
            list cat_cmds = get_category_list(CurrentCategory);
            integer total_items = llGetListLength(cat_cmds);
            integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;
            
            if (CurrentPage == 0) {
                // Wrap to last page
                show_category_menu(CurrentCategory, max_page);
            }
            else {
                show_category_menu(CurrentCategory, CurrentPage - 1);
            }
        }
        else if (button == ">>") {
            list cat_cmds = get_category_list(CurrentCategory);
            integer total_items = llGetListLength(cat_cmds);
            integer max_page = (total_items - 1) / DIALOG_PAGE_SIZE;
            
            if (CurrentPage >= max_page) {
                // Wrap to first page
                show_category_menu(CurrentCategory, 0);
            }
            else {
                show_category_menu(CurrentCategory, CurrentPage + 1);
            }
        }
        else {
            // Toggle restriction
            list cat_cmds = get_category_list(CurrentCategory);
            list cat_labels = get_category_labels(CurrentCategory);
            
            string restr_cmd = label_to_command(button, cat_cmds, cat_labels);
            
            if (restr_cmd != "") {
                toggle_restriction(restr_cmd);
                show_category_menu(CurrentCategory, CurrentPage);
            }
        }
    }
}

handle_dialog_timeout(string payload) {
    if (!json_has(payload, ["session_id"])) return;

    string recv_session = llJsonGetValue(payload, ["session_id"]);
    if (recv_session != SessionId) return;

    logd("Dialog timeout");
    cleanup_session();
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default
{
    state_entry() {
        cleanup_session();
        register_self();

        // Request settings from settings module
        kSend(CONTEXT, "settings", SETTINGS_BUS,
            kPayload(["get", 1]),
            NULL_KEY
        );

        logd("RLV Restrict plugin initialized - requested settings");
    }

    on_rez(integer start_param) {
        // Don't reset script on attach/detach
        // This preserves state, but settings sync will restore saved state anyway
        logd("Attached - state preserved");
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
            // Emergency SOS clear: has "emergency_restrict_clear" marker
            else if (json_has(payload, ["emergency_restrict_clear"])) {
                // Only allow if sender is the collar wearer
                // NOTE: User feedback is sent by SOS plugin, not here (avoid duplicate messages)
                if (id == llGetOwner()) {
                    remove_all_restrictions();
                    logd("Emergency restrict clear executed");
                } else {
                    logd("Emergency restrict clear denied: sender " + llKey2Name(id) + " is not wearer.");
                }
            }
        }

        /* ===== AUTH RESULT ===== */
        else if (num == AUTH_BUS && kFrom == "auth") {
            // ACL result: has "avatar" and "level" fields
            if (json_has(payload, ["avatar"]) && json_has(payload, ["level"])) {
                handle_acl_result(payload);
            }
        }

        /* ===== DIALOG RESPONSE ===== */
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
}
