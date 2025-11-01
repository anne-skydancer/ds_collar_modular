/* =============================================================================
   DS Collar - SOS Emergency Plugin

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
   ============================================================================= */

integer DEBUG = FALSE;

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
string PLUGIN_CONTEXT = "sos_911";
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
    if (DEBUG) llOwnerSay("[SOS] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   PLUGIN REGISTRATION
   ═══════════════════════════════════════════════════════════ */
register_self() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]), NULL_KEY);

    logd("SOS plugin registered");
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* ═══════════════════════════════════════════════════════════
   ACL QUERIES
   ═══════════════════════════════════════════════════════════ */
request_acl(key user) {
    AclPending = TRUE;
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user
    ]), user);

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

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "SOS Emergency",
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]), NULL_KEY);

    logd("Showing SOS menu to " + llKey2Name(CurrentUser));
}

/* ═══════════════════════════════════════════════════════════
   EMERGENCY ACTIONS
   ═══════════════════════════════════════════════════════════ */
action_unleash() {
    // Send emergency leash release on UI_BUS (bypasses ACL)
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "emergency_leash_release"
    ]), CurrentUser);

    llRegionSayTo(CurrentUser, 0, "[SOS] Leash released.");
    logd("Emergency leash release triggered by " + llKey2Name(CurrentUser));
}

action_clear_rlv() {
    // Send emergency restrict clear on UI_BUS (bypasses ACL)
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "emergency_restrict_clear"
    ]), CurrentUser);

    // Also send @clear directly to viewer as fallback
    llOwnerSay("@clear");

    llRegionSayTo(CurrentUser, 0, "[SOS] All RLV restrictions cleared.");
    logd("Emergency RLV clear triggered by " + llKey2Name(CurrentUser));
}

action_clear_relay() {
    // Send emergency relay clear on UI_BUS (bypasses ACL)
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "emergency_relay_clear"
    ]), CurrentUser);

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
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]), NULL_KEY);

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
        if (!json_has(msg, ["type"])) return;

        string msg_type = llJsonGetValue(msg, ["type"]);

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "register_now") {
                register_self();
                return;
            }

            if (msg_type == "ping") {
                send_pong();
                return;
            }

            if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                // Check if this is a targeted reset
                if (json_has(msg, ["context"])) {
                    string target_context = llJsonGetValue(msg, ["context"]);
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) {
                        return;  // Not for us, ignore
                    }
                }
                // Either no context (broadcast) or matches our context
                llResetScript();
            }

            return;
        }

        /* ===== UI START ===== */
        if (num == UI_BUS) {
            if (msg_type == "start") {
                if (!json_has(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                CurrentUser = id;
                request_acl(id);
                return;
            }

            return;
        }

        /* ===== AUTH RESULT ===== */
        if (num == AUTH_BUS) {
            if (msg_type == "acl_result") {
                if (!AclPending) return;
                if (!json_has(msg, ["avatar"])) return;

                key avatar = (key)llJsonGetValue(msg, ["avatar"]);
                if (avatar != CurrentUser) return;

                if (json_has(msg, ["level"])) {
                    UserAcl = (integer)llJsonGetValue(msg, ["level"]);
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
                return;
            }

            return;
        }

        /* ===== DIALOG RESPONSE ===== */
        if (num == DIALOG_BUS) {
            if (msg_type == "dialog_response") {
                if (!json_has(msg, ["session_id"]) || !json_has(msg, ["button"])) return;

                string response_session = llJsonGetValue(msg, ["session_id"]);
                if (response_session != SessionId) return;

                string button = llJsonGetValue(msg, ["button"]);
                handle_button_click(button);
                return;
            }

            if (msg_type == "dialog_timeout") {
                if (!json_has(msg, ["session_id"])) return;

                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                if (timeout_session != SessionId) return;

                logd("Dialog timeout");
                cleanup_session();
                return;
            }

            return;
        }
    }
}
