/* =============================================================================
   PLUGIN: ds_collar_plugin_tpe.lsl (v3.0 - Kanban Messaging Migration)

   PURPOSE: Toggle Total Power Exchange (TPE) mode with wearer consent

   FEATURES:
   - Wearer confirmation dialog for TPE activation
   - Direct disable by owner (no confirmation needed)
   - Dynamic button label (TPE: Y / TPE: N)
   - Settings persistence (tpe_mode key)
   - Settings sync and delta consumption
   - Restricted ACL: Primary Owner (5) ONLY
   - When TPE is ON, wearer gets ACL 0 (no access to collar)

   BEHAVIOR:
   - TPE OFF → ON: Shows confirmation dialog to wearer
     - Wearer clicks "Yes" → TPE activates, wearer's UI closes, owner returns to root
     - Wearer clicks "No" → Activation cancelled, wearer's UI closes, owner returns to root
     - Dialog times out → Activation cancelled, wearer's UI closes, owner returns to root
   - TPE ON → OFF: Direct disable by owner, owner returns to root menu
   - TPE ON: Wearer cannot access collar at all (ACL 0)
   - TPE OFF: Wearer has normal access (ACL 2 when owned, 4 when unowned)
   - Only Primary Owner (ACL 5) can manage TPE mode

   UI BEHAVIOR:
   - Wearer's UI always closes after clicking Yes/No on confirmation dialog
   - Owner's UI always returns to root menu to see the updated button state
   - Owner never has their UI closed (they're in control)

   TIER: 1 (Simple toggle with confirmation dialog)

   KANBAN MIGRATION (v3.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "core_tpe";

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
string PLUGIN_LABEL_ON = "TPE: Y";
string PLUGIN_LABEL_OFF = "TPE: N";
integer PLUGIN_MIN_ACL = 5;  // Primary Owner ONLY

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access (wearer in TPE mode)
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner (ONLY ACL that can manage TPE)
*/

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
string KEY_TPE_MODE = "tpe_mode";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
integer TpeModeEnabled = FALSE;

// Session management for confirmation dialog
key CurrentUser = NULL_KEY;        // Who initiated the action
integer UserAcl = -999;
string SessionId = "";
key WearerKey = NULL_KEY;          // Owner of the collar (for confirmation)
integer AclPending = FALSE;        // Waiting for ACL result

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[TPE] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string j) {
    return (llGetSubString(j, 0, 0) == "[");
}

string gen_session() {
    return (string)llGetKey() + "_" + (string)llGetUnixTime();
}

cleanup_session() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    SessionId = "";
}

close_ui_for_user(key user) {
    string payload = kPayload([
        "close", 1,
        "user", (string)user
    ]);
    kSend(CONTEXT, "ui", UI_BUS, payload, user);
    logd("Closed UI for " + (string)user);
}

/* ═══════════════════════════════════════════════════════════
   KERNEL MESSAGES
   ═══════════════════════════════════════════════════════════ */

register_with_kernel() {
    string initial_label = PLUGIN_LABEL_OFF;
    if (TpeModeEnabled) {
        initial_label = PLUGIN_LABEL_ON;
    }

    string payload = kPayload([
        "register", 1,
        "label", initial_label,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    kSend(CONTEXT, "", KERNEL_LIFECYCLE, payload, NULL_KEY);
    logd("Registered with kernel as: " + initial_label);
}

send_pong() {
    string payload = kPayload(["pong", 1]);
    kSend(CONTEXT, "", KERNEL_LIFECYCLE, payload, NULL_KEY);
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

request_settings_sync() {
    string payload = kPayload(["sync_request", 1]);
    kSend(CONTEXT, "settings", SETTINGS_BUS, payload, NULL_KEY);
    logd("Requesting settings sync");
}

persist_tpe_mode(integer new_value) {
    if (new_value != 0) new_value = 1;

    string payload = kDeltaSet(KEY_TPE_MODE, (string)new_value);
    kSend(CONTEXT, "settings", SETTINGS_BUS, payload, NULL_KEY);
    logd("Persisting tpe_mode=" + (string)new_value);
}

/* ═══════════════════════════════════════════════════════════
   BUTTON HANDLING
   ═══════════════════════════════════════════════════════════ */

handle_button_click(string button) {
    if (button == "Yes") {
        // Wearer confirmed - enable TPE
        TpeModeEnabled = TRUE;
        persist_tpe_mode(TRUE);

        llRegionSayTo(WearerKey, 0, "TPE mode enabled. You have relinquished collar control.");
        if (CurrentUser != WearerKey) {
            llRegionSayTo(CurrentUser, 0, "TPE mode enabled with wearer consent.");
        }

        // Update UI label
        string new_label = PLUGIN_LABEL_ON;
        string payload = kPayload([
            "update_label", 1,
            "label", new_label
        ]);
        kSend(CONTEXT, "ui", UI_BUS, payload, NULL_KEY);
        logd("Updated UI label to: " + new_label);

        // Close UI for wearer (who clicked the dialog)
        close_ui_for_user(WearerKey);

        // Return owner to root menu to see updated button (if different from wearer)
        if (CurrentUser != WearerKey) {
            payload = kPayload([
                "return", 1,
                "user", (string)CurrentUser
            ]);
            kSend(CONTEXT, "ui", UI_BUS, payload, NULL_KEY);
            logd("Returning owner to root menu");
        }

        cleanup_session();
    }
    else if (button == "No") {
        // Wearer declined - cancel TPE activation
        llRegionSayTo(WearerKey, 0, "TPE activation cancelled.");
        if (CurrentUser != WearerKey) {
            llRegionSayTo(CurrentUser, 0, "Wearer declined TPE activation.");
        }

        // Close UI for wearer (who clicked the dialog)
        close_ui_for_user(WearerKey);

        // Return owner to root menu (if different from wearer)
        if (CurrentUser != WearerKey) {
            string payload = kPayload([
                "return", 1,
                "user", (string)CurrentUser
            ]);
            kSend(CONTEXT, "ui", UI_BUS, payload, NULL_KEY);
            logd("Returning owner to root menu");
        }

        cleanup_session();
    }
}

/* ═══════════════════════════════════════════════════════════
   TPE TOGGLE LOGIC
   ═══════════════════════════════════════════════════════════ */

handle_tpe_click(key user, integer acl_level) {
    // Verify ACL (only 5=Primary Owner)
    if (acl_level != 5) {
        llRegionSayTo(user, 0, "Access denied. Only primary owner can manage TPE mode.");
        logd("Access denied for user with ACL " + (string)acl_level);
        return;
    }

    CurrentUser = user;
    UserAcl = acl_level;
    WearerKey = llGetOwner();

    if (TpeModeEnabled) {
        // TPE is currently ON - disable it directly (no confirmation needed)
        // This allows owner to release TPE without wearer consent
        TpeModeEnabled = FALSE;
        persist_tpe_mode(FALSE);

        llRegionSayTo(user, 0, "TPE mode disabled. Wearer regains collar access.");
        // Notify wearer their access has been restored
        if (user != WearerKey) {
            llRegionSayTo(WearerKey, 0, "Your collar access has been restored.");
        }

        // Update UI label
        string new_label = PLUGIN_LABEL_OFF;
        string payload = kPayload([
            "update_label", 1,
            "label", new_label
        ]);
        kSend(CONTEXT, "ui", UI_BUS, payload, NULL_KEY);
        logd("Updated UI label to: " + new_label);

        // Return owner to root menu (so they see the updated button)
        payload = kPayload([
            "return", 1,
            "user", (string)user
        ]);
        kSend(CONTEXT, "ui", UI_BUS, payload, NULL_KEY);
        logd("Returning owner to root menu");

        cleanup_session();
    }
    else {
        // TPE is currently OFF - requires wearer consent
        // Send dialog to WEARER, not CurrentUser
        logd("TPE activation requested by " + (string)user);

        string msg_body = "Your owner wants to enable TPE mode.\n\n";
        msg_body += "By clicking Yes, you relinquish all control of this collar.\n\n";
        msg_body += "You will not be able to access the collar menu while TPE is active.\n\n";
        msg_body += "Do you consent?";

        SessionId = gen_session();

        string payload = kPayload([
            "session_id", SessionId,
            "user", (string)llGetOwner(),  // Send to WEARER, not CurrentUser
            "title", "TPE Confirmation",
            "body", msg_body,
            "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
            "timeout", 60
        ]);
        kSend(CONTEXT, "dialogs", DIALOG_BUS, payload, NULL_KEY);

        logd("Sent TPE confirmation dialog to wearer: " + (string)llGetOwner());
    }
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS CONSUMPTION
   ═══════════════════════════════════════════════════════════ */

apply_settings_sync(string kv_json) {
    if (json_has(kv_json, [KEY_TPE_MODE])) {
        TpeModeEnabled = (integer)llJsonGetValue(kv_json, [KEY_TPE_MODE]);
        logd("TPE mode from sync: " + (string)TpeModeEnabled);
    }
}

apply_settings_delta(string payload) {
    if (!json_has(payload, ["op"])) return;

    string op = llJsonGetValue(payload, ["op"]);

    if (op == "set") {
        if (!json_has(payload, ["key"])) return;
        string setting_key = llJsonGetValue(payload, ["key"]);

        if (setting_key == KEY_TPE_MODE) {
            if (!json_has(payload, ["value"])) return;
            TpeModeEnabled = (integer)llJsonGetValue(payload, ["value"]);
            logd("TPE mode from delta: " + (string)TpeModeEnabled);
        }
    }
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default
{
    state_entry() {
        logd("=== TPE PLUGIN STATE_ENTRY ===");
        TpeModeEnabled = FALSE;
        WearerKey = llGetOwner();
        AclPending = FALSE;
        logd("WearerKey initialized to: " + (string)WearerKey);
        cleanup_session();
        logd("About to register with kernel...");
        register_with_kernel();
        logd("About to request settings sync...");
        request_settings_sync();
        logd("=== TPE PLUGIN INITIALIZATION COMPLETE ===");
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    link_message(integer sender_num, integer num, string msg, key id) {
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE) {
            // Register now: has "register" marker
            if (json_has(payload, ["register_now"])) {
                register_with_kernel();
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
                string kv_json = llJsonGetValue(payload, ["kv"]);
                apply_settings_sync(kv_json);
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
            logd("UI_BUS message received from: " + kFrom);

            // UI start: has "start" marker
            if (json_has(payload, ["start"])) {
                CurrentUser = id;
                logd("TPE button activated by " + (string)CurrentUser);

                // Request ACL for this user
                AclPending = TRUE;
                string acl_payload = kPayload([
                    "acl_query", 1,
                    "avatar", (string)CurrentUser
                ]);
                kSend(CONTEXT, "auth", AUTH_BUS, acl_payload, CurrentUser);
                logd("Requested ACL for user: " + (string)CurrentUser);
                return;
            }
            return;
        }

        /* ===== AUTH BUS ===== */
        if (num == AUTH_BUS) {
            logd("AUTH_BUS message received from: " + kFrom);

            // ACL result: has "level" field
            if (json_has(payload, ["level"])) {
                if (!AclPending) {
                    logd("Ignoring ACL result - not pending");
                    return;
                }
                if (!json_has(payload, ["avatar"])) return;

                key avatar = (key)llJsonGetValue(payload, ["avatar"]);
                logd("ACL result: avatar=" + (string)avatar + " CurrentUser=" + (string)CurrentUser);

                if (avatar != CurrentUser) {
                    logd("Skipping ACL result - not for current user");
                    return;
                }

                integer acl_level = (integer)llJsonGetValue(payload, ["level"]);

                AclPending = FALSE;

                logd("TPE button clicked by " + (string)avatar + " (ACL " + (string)acl_level + ")");
                logd("WearerKey=" + (string)WearerKey + " TpeModeEnabled=" + (string)TpeModeEnabled);

                // Handle click - may show confirmation dialog or toggle directly
                handle_tpe_click(avatar, acl_level);
                return;
            }
            return;
        }

        /* ===== DIALOG BUS ===== */
        if (num == DIALOG_BUS) {
            // Dialog button response: has "button" field
            if (json_has(payload, ["button"])) {
                if (!json_has(payload, ["session_id"])) return;
                string session_id = llJsonGetValue(payload, ["session_id"]);
                if (session_id != SessionId) return;

                string button = llJsonGetValue(payload, ["button"]);
                logd("Dialog button: " + button);

                handle_button_click(button);
                return;
            }

            // Dialog timeout: has "timeout" field
            if (json_has(payload, ["timeout"])) {
                if (!json_has(payload, ["session_id"])) return;
                string session_id = llJsonGetValue(payload, ["session_id"]);
                if (session_id != SessionId) return;

                logd("Dialog timeout - TPE activation cancelled");
                llRegionSayTo(WearerKey, 0, "TPE confirmation timed out.");
                if (CurrentUser != WearerKey) {
                    llRegionSayTo(CurrentUser, 0, "TPE confirmation timed out.");
                }

                // Close UI for wearer
                close_ui_for_user(WearerKey);

                // Return owner to root menu (if different from wearer)
                if (CurrentUser != WearerKey) {
                    string return_payload = kPayload([
                        "return", 1,
                        "user", (string)CurrentUser
                    ]);
                    kSend(CONTEXT, "ui", UI_BUS, return_payload, NULL_KEY);
                    logd("Returning owner to root menu");
                }

                cleanup_session();
                return;
            }
            return;
        }
    }
}
