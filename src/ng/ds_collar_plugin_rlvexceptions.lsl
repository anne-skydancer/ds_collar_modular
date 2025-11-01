/* =============================================================================
   PLUGIN: ds_collar_plugin_rlvexceptions.lsl (v3.0 - Kanban Messaging Migration)

   PURPOSE: RLV exception management for owners and trustees

   FEATURES:
   - Owner TP exceptions (@accepttp, @tplure)
   - Owner IM exceptions (@sendim, @recvim)
   - Trustee TP exceptions
   - Trustee IM exceptions
   - Multi-owner mode support
   - Real-time RLV command application

   BUG FIX: Properly clears exceptions when owners/trustees are removed

   TIER: 2 (Medium - RLV command management)

   KANBAN MIGRATION (v3.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "core_rlv_exceptions";

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

/* ═══════════════════════════════════════════════════════════
   ABI CHANNELS
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ═══════════════════════════════════════════════════════════
   IDENTITY
   ═══════════════════════════════════════════════════════════ */
string PLUGIN_LABEL = "Exceptions";
integer PLUGIN_MIN_ACL = 3;

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
string KEY_EX_OWNER_TP = "ex_owner_tp";
string KEY_EX_OWNER_IM = "ex_owner_im";
string KEY_EX_TRUSTEE_TP = "ex_trustee_tp";
string KEY_EX_TRUSTEE_IM = "ex_trustee_im";
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_KEYS = "owner_keys";
string KEY_TRUSTEES = "trustees";
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
integer ExOwnerTp = TRUE;
integer ExOwnerIm = TRUE;
integer ExTrusteeTp = FALSE;
integer ExTrusteeIm = FALSE;

key OwnerKey;
list OwnerKeys;
list TrusteeKeys;
integer MultiOwnerMode;

key CurrentUser;
integer UserAcl = -999;
string SessionId;
string MenuContext;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */

logd(string msg) {
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] " + msg);
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string gen_session() {
    return CONTEXT + "_" + (string)llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   RLV COMMANDS
   ═══════════════════════════════════════════════════════════ */

apply_tp_exception(key k, integer allow) {
    if (k == NULL_KEY) return;

    if (allow) {
        llOwnerSay("@accepttp:" + (string)k + "=add");
        llOwnerSay("@tplure:" + (string)k + "=add");
    }
    else {
        llOwnerSay("@accepttp:" + (string)k + "=rem");
        llOwnerSay("@tplure:" + (string)k + "=rem");
    }
}

apply_im_exception(key k, integer allow) {
    if (k == NULL_KEY) return;

    if (allow) {
        llOwnerSay("@sendim:" + (string)k + "=add");
        llOwnerSay("@recvim:" + (string)k + "=add");
    }
    else {
        llOwnerSay("@sendim:" + (string)k + "=rem");
        llOwnerSay("@recvim:" + (string)k + "=rem");
    }
}

reconcile_all() {
    logd("Reconciling RLV exceptions");

    // Owner exceptions
    if (MultiOwnerMode) {
        integer i;
        integer len = llGetListLength(OwnerKeys);
        while (i < len) {
            key k = (key)llList2String(OwnerKeys, i);
            apply_tp_exception(k, ExOwnerTp);
            apply_im_exception(k, ExOwnerIm);
            i++;
        }
    }
    else {
        apply_tp_exception(OwnerKey, ExOwnerTp);
        apply_im_exception(OwnerKey, ExOwnerIm);
    }

    // Trustee exceptions
    integer i;
    integer len = llGetListLength(TrusteeKeys);
    while (i < len) {
        key k = (key)llList2String(TrusteeKeys, i);
        apply_tp_exception(k, ExTrusteeTp);
        apply_im_exception(k, ExTrusteeIm);
        i++;
    }
}

/* ═══════════════════════════════════════════════════════════
   LIFECYCLE
   ═══════════════════════════════════════════════════════════ */

register_self() {
    string payload = kPayload([
        "register", 1,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    kSend(CONTEXT, "", KERNEL_LIFECYCLE, payload, NULL_KEY);
}

send_pong() {
    string payload = kPayload(["pong", 1]);
    kSend(CONTEXT, "", KERNEL_LIFECYCLE, payload, NULL_KEY);
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS
   ═══════════════════════════════════════════════════════════ */

apply_settings_sync(string payload) {
    if (!json_has(payload, ["kv"])) return;
    string kv = llJsonGetValue(payload, ["kv"]);

    // Reset defaults
    ExOwnerTp = TRUE;
    ExOwnerIm = TRUE;
    ExTrusteeTp = FALSE;
    ExTrusteeIm = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    TrusteeKeys = [];
    MultiOwnerMode = FALSE;

    // Load exception settings
    if (json_has(kv, [KEY_EX_OWNER_TP])) {
        ExOwnerTp = (integer)llJsonGetValue(kv, [KEY_EX_OWNER_TP]);
    }
    if (json_has(kv, [KEY_EX_OWNER_IM])) {
        ExOwnerIm = (integer)llJsonGetValue(kv, [KEY_EX_OWNER_IM]);
    }
    if (json_has(kv, [KEY_EX_TRUSTEE_TP])) {
        ExTrusteeTp = (integer)llJsonGetValue(kv, [KEY_EX_TRUSTEE_TP]);
    }
    if (json_has(kv, [KEY_EX_TRUSTEE_IM])) {
        ExTrusteeIm = (integer)llJsonGetValue(kv, [KEY_EX_TRUSTEE_IM]);
    }

    // Load owner/trustee lists
    if (json_has(kv, [KEY_MULTI_OWNER_MODE])) {
        MultiOwnerMode = (integer)llJsonGetValue(kv, [KEY_MULTI_OWNER_MODE]);
    }

    if (MultiOwnerMode) {
        if (json_has(kv, [KEY_OWNER_KEYS])) {
            string arr = llJsonGetValue(kv, [KEY_OWNER_KEYS]);
            if (llGetSubString(arr, 0, 0) == "[") OwnerKeys = llJson2List(arr);
        }
    }
    else {
        if (json_has(kv, [KEY_OWNER_KEY])) {
            OwnerKey = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
        }
    }

    if (json_has(kv, [KEY_TRUSTEES])) {
        string arr = llJsonGetValue(kv, [KEY_TRUSTEES]);
        if (llGetSubString(arr, 0, 0) == "[") TrusteeKeys = llJson2List(arr);
    }

    // Apply RLV commands
    reconcile_all();

    logd("Settings applied");
}

apply_settings_delta(string payload) {
    if (!json_has(payload, ["op"])) return;
    string op = llJsonGetValue(payload, ["op"]);

    if (op == "set") {
        if (!json_has(payload, ["key"])) return;
        string setting_key = llJsonGetValue(payload, ["key"]);

        if (setting_key == KEY_EX_OWNER_TP) {
            if (!json_has(payload, ["value"])) return;
            ExOwnerTp = (integer)llJsonGetValue(payload, ["value"]);
            reconcile_all();
        }
        else if (setting_key == KEY_EX_OWNER_IM) {
            if (!json_has(payload, ["value"])) return;
            ExOwnerIm = (integer)llJsonGetValue(payload, ["value"]);
            reconcile_all();
        }
        else if (setting_key == KEY_EX_TRUSTEE_TP) {
            if (!json_has(payload, ["value"])) return;
            ExTrusteeTp = (integer)llJsonGetValue(payload, ["value"]);
            reconcile_all();
        }
        else if (setting_key == KEY_EX_TRUSTEE_IM) {
            if (!json_has(payload, ["value"])) return;
            ExTrusteeIm = (integer)llJsonGetValue(payload, ["value"]);
            reconcile_all();
        }
        else if (setting_key == KEY_OWNER_KEY) {
            // Handle owner_key changes (single owner mode)
            if (!json_has(payload, ["value"])) return;
            key old_owner = OwnerKey;
            OwnerKey = (key)llJsonGetValue(payload, ["value"]);

            // Clear exceptions from old owner if it changed
            if (old_owner != NULL_KEY && old_owner != OwnerKey) {
                apply_tp_exception(old_owner, FALSE);
                apply_im_exception(old_owner, FALSE);
                logd("Cleared exceptions for removed owner: " + (string)old_owner);
            }

            // Apply to new owner
            reconcile_all();
        }
    }
    else if (op == "list_add") {
        if (!json_has(payload, ["key"])) return;
        if (!json_has(payload, ["elem"])) return;

        string key_name = llJsonGetValue(payload, ["key"]);
        string elem = llJsonGetValue(payload, ["elem"]);

        if (key_name == KEY_OWNER_KEYS) {
            if (llListFindList(OwnerKeys, [elem]) == -1) {
                OwnerKeys += [elem];
                logd("Added owner: " + elem);

                // Apply exceptions to new owner
                key k = (key)elem;
                apply_tp_exception(k, ExOwnerTp);
                apply_im_exception(k, ExOwnerIm);
            }
        }
        else if (key_name == KEY_TRUSTEES) {
            if (llListFindList(TrusteeKeys, [elem]) == -1) {
                TrusteeKeys += [elem];
                logd("Added trustee: " + elem);

                // Apply exceptions to new trustee
                key k = (key)elem;
                apply_tp_exception(k, ExTrusteeTp);
                apply_im_exception(k, ExTrusteeIm);
            }
        }
    }
    else if (op == "list_remove") {
        if (!json_has(payload, ["key"])) return;
        if (!json_has(payload, ["elem"])) return;

        string key_name = llJsonGetValue(payload, ["key"]);
        string elem = llJsonGetValue(payload, ["elem"]);

        if (key_name == KEY_OWNER_KEYS) {
            integer idx = llListFindList(OwnerKeys, [elem]);
            if (idx != -1) {
                // CRITICAL: Clear exceptions BEFORE removing from list
                key k = (key)elem;
                apply_tp_exception(k, FALSE);
                apply_im_exception(k, FALSE);
                logd("Cleared exceptions for removed owner: " + elem);

                // Remove from list
                OwnerKeys = llDeleteSubList(OwnerKeys, idx, idx);
            }
        }
        else if (key_name == KEY_TRUSTEES) {
            integer idx = llListFindList(TrusteeKeys, [elem]);
            if (idx != -1) {
                // CRITICAL: Clear exceptions BEFORE removing from list
                key k = (key)elem;
                apply_tp_exception(k, FALSE);
                apply_im_exception(k, FALSE);
                logd("Cleared exceptions for removed trustee: " + elem);

                // Remove from list
                TrusteeKeys = llDeleteSubList(TrusteeKeys, idx, idx);
            }
        }
    }
}

persist_setting(string setting_key, integer value) {
    string payload = kDeltaSet(setting_key, (string)value);
    kSend(CONTEXT, "settings", SETTINGS_BUS, payload, NULL_KEY);
}

/* ═══════════════════════════════════════════════════════════
   ACL
   ═══════════════════════════════════════════════════════════ */

request_acl(key user) {
    string payload = kPayload([
        "acl_query", 1,
        "avatar", (string)user,
        "id", CONTEXT + "_acl"
    ]);
    kSend(CONTEXT, "auth", AUTH_BUS, payload, NULL_KEY);
}

handle_acl_result(string payload) {
    if (!json_has(payload, ["avatar"]) || !json_has(payload, ["level"])) return;

    key avatar = (key)llJsonGetValue(payload, ["avatar"]);
    if (avatar != CurrentUser) return;

    UserAcl = (integer)llJsonGetValue(payload, ["level"]);

    if (UserAcl < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanup();
        return;
    }

    show_main();
}

/* ═══════════════════════════════════════════════════════════
   MENUS
   ═══════════════════════════════════════════════════════════ */

show_main() {
    SessionId = gen_session();
    MenuContext = "main";

    string body = "RLV Exceptions\n\nManage which restrictions can be bypassed by owners and trustees.";

    list buttons = ["Back", "Owner", "Trustee"];

    string payload = kPayload([
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);
    kSend(CONTEXT, "dialogs", DIALOG_BUS, payload, NULL_KEY);
}

show_owner_menu() {
    SessionId = gen_session();
    MenuContext = "owner";

    string body = "Owner Exceptions\n\nCurrent settings:\n";
    if (ExOwnerTp) body += "TP: Allowed\n";
    else body += "TP: Denied\n";
    if (ExOwnerIm) body += "IM: Allowed";
    else body += "IM: Denied";

    list buttons = ["Back", "TP", "IM"];

    string payload = kPayload([
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Owner Exceptions",
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);
    kSend(CONTEXT, "dialogs", DIALOG_BUS, payload, NULL_KEY);
}

show_trustee_menu() {
    SessionId = gen_session();
    MenuContext = "trustee";

    string body = "Trustee Exceptions\n\nCurrent settings:\n";
    if (ExTrusteeTp) body += "TP: Allowed\n";
    else body += "TP: Denied\n";
    if (ExTrusteeIm) body += "IM: Allowed";
    else body += "IM: Denied";

    list buttons = ["Back", "TP", "IM"];

    string payload = kPayload([
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Trustee Exceptions",
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);
    kSend(CONTEXT, "dialogs", DIALOG_BUS, payload, NULL_KEY);
}

show_toggle(string role, string exception_type, string setting_key, integer current) {
    SessionId = gen_session();
    MenuContext = role + "_" + exception_type;

    string body = role + " " + exception_type + " Exception\n\n";
    if (current) body += "Current: Allowed\n\n";
    else body += "Current: Denied\n\n";
    body += "Allow = Owner/trustee can bypass restrictions\n";
    body += "Deny = Normal restrictions apply";

    list buttons = ["Back", "Allow", "Deny"];

    string payload = kPayload([
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", role + " " + exception_type,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]);
    kSend(CONTEXT, "dialogs", DIALOG_BUS, payload, NULL_KEY);
}

/* ═══════════════════════════════════════════════════════════
   BUTTON HANDLING
   ═══════════════════════════════════════════════════════════ */

handle_button(string btn) {
    if (btn == "Back") {
        if (MenuContext == "main") {
            string payload = kPayload([
                "return", 1,
                "user", (string)CurrentUser
            ]);
            kSend(CONTEXT, "ui", UI_BUS, payload, NULL_KEY);
            cleanup();
        }
        else if (MenuContext == "owner" || MenuContext == "trustee") {
            show_main();
        }
        else {
            if (llSubStringIndex(MenuContext, "owner") == 0) show_owner_menu();
            else if (llSubStringIndex(MenuContext, "trustee") == 0) show_trustee_menu();
            else show_main();
        }
        return;
    }

    if (MenuContext == "main") {
        if (btn == "Owner") show_owner_menu();
        else if (btn == "Trustee") show_trustee_menu();
    }
    else if (MenuContext == "owner") {
        if (btn == "TP") show_toggle("Owner", "TP", KEY_EX_OWNER_TP, ExOwnerTp);
        else if (btn == "IM") show_toggle("Owner", "IM", KEY_EX_OWNER_IM, ExOwnerIm);
    }
    else if (MenuContext == "trustee") {
        if (btn == "TP") show_toggle("Trustee", "TP", KEY_EX_TRUSTEE_TP, ExTrusteeTp);
        else if (btn == "IM") show_toggle("Trustee", "IM", KEY_EX_TRUSTEE_IM, ExTrusteeIm);
    }
    else if (MenuContext == "owner_TP") {
        if (btn == "Allow") {
            persist_setting(KEY_EX_OWNER_TP, TRUE);
            llRegionSayTo(CurrentUser, 0, "Owner TP exception allowed.");
        }
        else if (btn == "Deny") {
            persist_setting(KEY_EX_OWNER_TP, FALSE);
            llRegionSayTo(CurrentUser, 0, "Owner TP exception denied.");
        }
        show_owner_menu();
    }
    else if (MenuContext == "owner_IM") {
        if (btn == "Allow") {
            persist_setting(KEY_EX_OWNER_IM, TRUE);
            llRegionSayTo(CurrentUser, 0, "Owner IM exception allowed.");
        }
        else if (btn == "Deny") {
            persist_setting(KEY_EX_OWNER_IM, FALSE);
            llRegionSayTo(CurrentUser, 0, "Owner IM exception denied.");
        }
        show_owner_menu();
    }
    else if (MenuContext == "trustee_TP") {
        if (btn == "Allow") {
            persist_setting(KEY_EX_TRUSTEE_TP, TRUE);
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception allowed.");
        }
        else if (btn == "Deny") {
            persist_setting(KEY_EX_TRUSTEE_TP, FALSE);
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception denied.");
        }
        show_trustee_menu();
    }
    else if (MenuContext == "trustee_IM") {
        if (btn == "Allow") {
            persist_setting(KEY_EX_TRUSTEE_IM, TRUE);
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception allowed.");
        }
        else if (btn == "Deny") {
            persist_setting(KEY_EX_TRUSTEE_IM, FALSE);
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception denied.");
        }
        show_trustee_menu();
    }
}

/* ═══════════════════════════════════════════════════════════
   CLEANUP
   ═══════════════════════════════════════════════════════════ */

cleanup() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    SessionId = "";
    MenuContext = "";
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default {
    state_entry() {
        cleanup();
        register_self();
        string payload = kPayload(["settings_get", 1]);
        kSend(CONTEXT, "settings", SETTINGS_BUS, payload, NULL_KEY);
    }

    on_rez(integer p) {
        llResetScript();
    }

    changed(integer c) {
        if (c & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE) {
            // Register now: has "register_now" marker
            if (json_has(payload, ["register_now"])) {
                register_self();
                return;
            }

            // Ping: has "ping" marker
            if (json_has(payload, ["ping"])) {
                send_pong();
                return;
            }

            // Soft reset: has "reset" marker
            if (json_has(payload, ["reset"])) {
                llResetScript();
                return;
            }
            return;
        }

        /* ===== SETTINGS BUS ===== */
        if (num == SETTINGS_BUS) {
            // Settings sync: has "kv" field
            if (json_has(payload, ["kv"])) {
                apply_settings_sync(payload);
                return;
            }

            // Settings delta: has "op" field
            if (json_has(payload, ["op"])) {
                apply_settings_delta(payload);
                return;
            }
            return;
        }

        /* ===== UI BUS ===== */
        if (num == UI_BUS) {
            // UI start: has "start" marker
            if (json_has(payload, ["start"])) {
                CurrentUser = id;
                request_acl(id);
                return;
            }
            return;
        }

        /* ===== AUTH BUS ===== */
        if (num == AUTH_BUS) {
            // ACL result: has "level" field
            if (json_has(payload, ["level"])) {
                handle_acl_result(payload);
                return;
            }
            return;
        }

        /* ===== DIALOG BUS ===== */
        if (num == DIALOG_BUS) {
            // Dialog button response: has "button" field
            if (json_has(payload, ["button"])) {
                if (json_has(payload, ["session_id"])) {
                    if (llJsonGetValue(payload, ["session_id"]) == SessionId) {
                        handle_button(llJsonGetValue(payload, ["button"]));
                    }
                }
                return;
            }

            // Dialog timeout: has "timeout" field
            if (json_has(payload, ["timeout"])) {
                if (json_has(payload, ["session_id"])) {
                    if (llJsonGetValue(payload, ["session_id"]) == SessionId) cleanup();
                }
                return;
            }
            return;
        }
    }
}
