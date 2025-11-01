/* =============================================================================
   DS Collar - SOS Emergency Plugin (v2.0 - Kanban Messaging Migration)

   ROLE: Emergency access menu for ACL 0 users (no access)

   FEATURES:
   - Accessible via long-touch (SOS context)
   - Available to ACL 0 users who normally have no collar access
   - Three emergency actions:
     * Unleash avatar (release leash)
     * Clear RLV restrictions (all RLV restrictions)
     * Clear relay restrictions (all relay device restrictions)

   CONTEXT: "sos" - appears only in SOS emergency menu
   MIN_ACL: 0 - accessible even to users with no collar access

   SECURITY: Only available to collar wearer (enforced by UI module)

   KANBAN MIGRATION (v2.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "sos";

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
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ═══════════════════════════════════════════════════════════
   PLUGIN IDENTITY
   ═══════════════════════════════════════════════════════════ */
string PLUGIN_LABEL = "SOS";
integer PLUGIN_MIN_ACL = 0;  // ACL 0 - accessible to all (including no access)

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[SOS] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return CONTEXT + "_" + (string)llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   PLUGIN REGISTRATION
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

    logd("SOS plugin registered");
}

send_pong() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload(["pong", 1]),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   ACL QUERIES
   ═══════════════════════════════════════════════════════════ */
request_acl(key user) {
    AclPending = TRUE;
    kSend(CONTEXT, "auth", AUTH_BUS,
        kPayload(["avatar", (string)user]),
        user
    );

    logd("ACL query sent for " + llKey2Name(user));
}

/* ═══════════════════════════════════════════════════════════
   MENU DISPLAY
   ═══════════════════════════════════════════════════════════ */
show_sos_menu() {
    SessionId = generate_session_id();

    // llDialog displays buttons in rows of 3, bottom-left to top-right
    // Row 1 (bottom): [Back] [Unleash] [Clear RLV]
    // Row 2 (top):    [Clear Relay]
    list buttons = ["Back", "Unleash", "Clear RLV", "Clear Relay"];

    string body = "EMERGENCY ACCESS\n\n";
    body += "Choose an action:\n";
    body += "• Unleash - Release leash\n";
    body += "• Clear RLV - Clear RLV restrictions\n";
    body += "• Clear Relay - Clear relay restrictions";

    kSend(CONTEXT, "dialogs", DIALOG_BUS,
        kPayload([
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", "SOS Emergency",
            "body", body,
            "buttons", llList2Json(JSON_ARRAY, buttons),
            "timeout", 60
        ]),
        NULL_KEY
    );

    logd("Showing SOS menu to " + llKey2Name(CurrentUser));
}

/* ═══════════════════════════════════════════════════════════
   EMERGENCY ACTIONS
   ═══════════════════════════════════════════════════════════ */
action_unleash() {
    // Send emergency leash release on UI_BUS (bypasses ACL)
    kSend(CONTEXT, "ui", UI_BUS,
        kPayload(["emergency_leash_release", 1]),
        CurrentUser
    );

    llRegionSayTo(CurrentUser, 0, "[SOS] Leash released.");
    logd("Emergency leash release triggered by " + llKey2Name(CurrentUser));
}

action_clear_rlv() {
    // Send emergency restrict clear on UI_BUS (bypasses ACL)
    kSend(CONTEXT, "ui", UI_BUS,
        kPayload(["emergency_restrict_clear", 1]),
        CurrentUser
    );

    // Also send @clear directly to viewer as fallback
    llOwnerSay("@clear");

    llRegionSayTo(CurrentUser, 0, "[SOS] All RLV restrictions cleared.");
    logd("Emergency RLV clear triggered by " + llKey2Name(CurrentUser));
}

action_clear_relay() {
    // Send emergency relay clear on UI_BUS (bypasses ACL)
    kSend(CONTEXT, "ui", UI_BUS,
        kPayload(["emergency_relay_clear", 1]),
        CurrentUser
    );

    llRegionSayTo(CurrentUser, 0, "[SOS] All relay restrictions cleared.");
    logd("Emergency relay clear triggered by " + llKey2Name(CurrentUser));
}

/* ═══════════════════════════════════════════════════════════
   BUTTON HANDLER
   ═══════════════════════════════════════════════════════════ */
handle_button_click(string button) {
    logd("Button clicked: " + button);

    if (button == "Back") {
        return_to_root();
        return;
    }

    if (button == "Unleash") {
        action_unleash();
        show_sos_menu();
        return;
    }

    if (button == "Clear RLV") {
        action_clear_rlv();
        show_sos_menu();
        return;
    }

    if (button == "Clear Relay") {
        action_clear_relay();
        show_sos_menu();
        return;
    }
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

cleanup_session() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    AclPending = FALSE;
    SessionId = "";

    logd("Session cleaned up");
}

/* ═══════════════════════════════════════════════════════════
   EVENT HANDLERS
   ═══════════════════════════════════════════════════════════ */
default {
    state_entry() {
        cleanup_session();
        register_self();

        logd("SOS Emergency plugin initialized");
    }

    on_rez(integer start_param) {
        // Preserve state on attach/detach
        logd("Rezzed - state preserved");
    }

    changed(integer change_mask) {
        if (change_mask & CHANGED_OWNER) {
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
                if (!AclPending) return;

                key avatar = (key)llJsonGetValue(payload, ["avatar"]);
                if (avatar != CurrentUser) return;

                UserAcl = (integer)llJsonGetValue(payload, ["level"]);
                AclPending = FALSE;

                // SOS is accessible to ACL 0 and above (everyone)
                if (UserAcl < PLUGIN_MIN_ACL) {
                    llRegionSayTo(CurrentUser, 0, "[SOS] Access denied.");
                    cleanup_session();
                    return;
                }

                show_sos_menu();
                logd("SOS menu shown - ACL: " + (string)UserAcl);
            }
        }

        /* ===== DIALOG RESPONSE ===== */
        else if (num == DIALOG_BUS && kFrom == "dialogs") {
            // Dialog response: has "session_id" and "button" fields
            if (json_has(payload, ["session_id"]) && json_has(payload, ["button"])) {
                string response_session = llJsonGetValue(payload, ["session_id"]);
                if (response_session != SessionId) return;

                string button = llJsonGetValue(payload, ["button"]);
                handle_button_click(button);
            }
            // Dialog timeout: has "session_id" but no "button"
            else if (json_has(payload, ["session_id"]) && !json_has(payload, ["button"])) {
                string timeout_session = llJsonGetValue(payload, ["session_id"]);
                if (timeout_session != SessionId) return;

                logd("Dialog timeout");
                cleanup_session();
            }
        }
    }
}
