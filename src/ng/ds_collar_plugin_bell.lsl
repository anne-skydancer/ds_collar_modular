/* =============================================================================
   DS Collar - Bell Plugin (v2.0 - Kanban Messaging Migration)

   FEATURES:
   - Independent visibility and sound controls
   - Volume adjustment (10% increments)
   - Movement-triggered jingle sound (continuous while moving)
   - Finds any prim named "bell" in linkset
   - Settings persist across relogs

   ACL: Public (1) and above

   KANBAN MIGRATION (v2.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "bell";

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

string PLUGIN_LABEL = "Bell";
integer PLUGIN_MIN_ACL = 1;  // Public can use

// Settings keys
string KEY_BELL_VISIBLE = "bell_visible";
string KEY_BELL_SOUND_ENABLED = "bell_sound_enabled";
string KEY_BELL_VOLUME = "bell_volume";
string KEY_BELL_SOUND = "bell_sound";

// State
integer BellVisible = FALSE;
integer BellSoundEnabled = FALSE;
float BellVolume = 0.3;
string BellSound = "16fcf579-82cb-b110-c1a4-5fa5e1385406";
integer IsMoving = FALSE;

// Jingle timing
float JINGLE_INTERVAL = 1.75;  // Play sound every 1.75 seconds while moving

// Session state
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";
string MenuContext = "";

// ===== HELPERS =====
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[BELL] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return CONTEXT + "_" + (string)llGetUnixTime();
}

set_bell_visibility(integer visible) {
    integer link_count = llGetNumberOfPrims();
    integer i;
    integer found = FALSE;

    float alpha;
    if (visible) {
        alpha = 1.0;
    } else {
        alpha = 0.0;
    }

    for (i = 1; i <= link_count; i++) {
        string prim_name = llGetLinkName(i);
        if (llToLower(prim_name) == "bell") {
            llSetLinkAlpha(i, alpha, ALL_SIDES);
            found = TRUE;
            logd("Found bell prim at link " + (string)i + ", setting alpha to " + (string)alpha);
        }
    }

    if (!found) {
        logd("WARNING: Bell prim not found!");
    }

    BellVisible = visible;
}

play_jingle() {
    if (BellSound == "" || BellSound == "00000000-0000-0000-0000-000000000000") {
        return;
    }

    if (!BellSoundEnabled) {
        return;
    }

    llTriggerSound(BellSound, BellVolume);
    logd("Jingle played at volume " + (string)BellVolume);
}

// ===== UNIFIED MENU DISPLAY =====
show_menu(string context, string title, string body, list buttons) {
    SessionId = generate_session_id();
    MenuContext = context;

    kSend(CONTEXT, "dialogs", DIALOG_BUS,
        kPayload([
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", title,
            "body", body,
            "buttons", llList2Json(JSON_ARRAY, buttons),
            "timeout", 60
        ]),
        NULL_KEY
    );
}

// ===== ACL QUERIES =====
request_acl(key user) {
    AclPending = TRUE;
    kSend(CONTEXT, "auth", AUTH_BUS,
        kPayload(["avatar", (string)user]),
        user
    );
    logd("ACL query sent for " + llKey2Name(user));
}

// ===== PLUGIN REGISTRATION =====
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

// ===== MENU SYSTEM =====
show_main_menu() {
    string visible_label;
    if (BellVisible) {
        visible_label = "Show: Y";
    } else {
        visible_label = "Show: N";
    }

    string sound_label;
    if (BellSoundEnabled) {
        sound_label = "Sound: On";
    } else {
        sound_label = "Sound: Off";
    }

    // Button order for layout:
    // [Volume +] [Volume -] [.]
    // [Back]     [Show: Y/N] [Sound: On/Off]
    list buttons = ["Back", visible_label, sound_label, "Volume +", "Volume -"];

    string body = "Bell Control\n\n";
    body += "Visibility: " + (string)BellVisible + "\n";
    body += "Sound: " + (string)BellSoundEnabled + "\n";
    body += "Volume: " + (string)((integer)(BellVolume * 100)) + "%";

    show_menu("main", "Bell", body, buttons);
}

// ===== SETTINGS MODIFICATION =====
persist_bell_setting(string setting_key, string value) {
    kSend(CONTEXT, "settings", SETTINGS_BUS,
        kDeltaSet(setting_key, value),
        NULL_KEY
    );
}

// ===== BUTTON HANDLER =====
handle_button_click(string button) {
    logd("Button: " + button + " in context: " + MenuContext);

    if (MenuContext == "main") {
        if (button == "Back") {
            return_to_root();
        }
        else if (button == "Volume +") {
            BellVolume = BellVolume + 0.1;
            if (BellVolume > 1.0) BellVolume = 1.0;
            persist_bell_setting(KEY_BELL_VOLUME, (string)BellVolume);
            llRegionSayTo(CurrentUser, 0, "Volume: " + (string)((integer)(BellVolume * 100)) + "%");
            show_main_menu();
        }
        else if (button == "Volume -") {
            BellVolume = BellVolume - 0.1;
            if (BellVolume < 0.0) BellVolume = 0.0;
            persist_bell_setting(KEY_BELL_VOLUME, (string)BellVolume);
            llRegionSayTo(CurrentUser, 0, "Volume: " + (string)((integer)(BellVolume * 100)) + "%");
            show_main_menu();
        }
        else if (button == "Show: Y" || button == "Show: N") {
            // Toggle state
            BellVisible = !BellVisible;

            // Apply immediately
            set_bell_visibility(BellVisible);

            // Persist change
            persist_bell_setting(KEY_BELL_VISIBLE, (string)BellVisible);

            // Notify user
            if (BellVisible) {
                llRegionSayTo(CurrentUser, 0, "Bell shown.");
            } else {
                llRegionSayTo(CurrentUser, 0, "Bell hidden.");
            }

            // Stay in menu
            show_main_menu();
        }
        else if (button == "Sound: On" || button == "Sound: Off") {
            // Toggle state
            BellSoundEnabled = !BellSoundEnabled;

            // Persist change
            persist_bell_setting(KEY_BELL_SOUND_ENABLED, (string)BellSoundEnabled);

            // Notify user
            if (BellSoundEnabled) {
                llRegionSayTo(CurrentUser, 0, "Bell sound enabled.");
            } else {
                llRegionSayTo(CurrentUser, 0, "Bell sound disabled.");
            }

            // Stay in menu
            show_main_menu();
        }
    }
}

// ===== NAVIGATION =====
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
    MenuContext = "";
    logd("Session cleaned up");
}

// ===== SETTINGS HANDLING =====
apply_settings_sync(string payload) {
    if (!json_has(payload, ["kv"])) return;
    string kv_json = llJsonGetValue(payload, ["kv"]);

    if (json_has(kv_json, [KEY_BELL_VISIBLE])) {
        integer new_visible = (integer)llJsonGetValue(kv_json, [KEY_BELL_VISIBLE]);
        set_bell_visibility(new_visible);
        logd("Loaded bell_visible=" + (string)new_visible);
    }

    if (json_has(kv_json, [KEY_BELL_SOUND_ENABLED])) {
        BellSoundEnabled = (integer)llJsonGetValue(kv_json, [KEY_BELL_SOUND_ENABLED]);
        logd("Loaded bell_sound_enabled=" + (string)BellSoundEnabled);
    }

    if (json_has(kv_json, [KEY_BELL_VOLUME])) {
        BellVolume = (float)llJsonGetValue(kv_json, [KEY_BELL_VOLUME]);
        logd("Loaded bell_volume=" + (string)BellVolume);
    }

    if (json_has(kv_json, [KEY_BELL_SOUND])) {
        BellSound = llJsonGetValue(kv_json, [KEY_BELL_SOUND]);
        logd("Loaded bell_sound=" + BellSound);
    }

    logd("Settings sync applied");
}

apply_settings_delta(string payload) {
    string op = llJsonGetValue(payload, ["op"]);

    if (op == "set") {
        string setting_key = llJsonGetValue(payload, ["key"]);
        string value = llJsonGetValue(payload, ["value"]);

        if (setting_key == KEY_BELL_VISIBLE) {
            set_bell_visibility((integer)value);
            logd("Delta: bell_visible=" + value);
        }
        else if (setting_key == KEY_BELL_SOUND_ENABLED) {
            BellSoundEnabled = (integer)value;
            logd("Delta: bell_sound_enabled=" + value);
        }
        else if (setting_key == KEY_BELL_VOLUME) {
            BellVolume = (float)value;
            logd("Delta: bell_volume=" + value);
        }
        else if (setting_key == KEY_BELL_SOUND) {
            BellSound = value;
            logd("Delta: bell_sound=" + value);
        }
    }
}

// ===== EVENT HANDLERS =====
default {
    state_entry() {
        cleanup_session();

        // Always start with safe defaults (bell hidden, sound off)
        // Settings sync will override these immediately if saved state exists
        BellVisible = FALSE;
        BellSoundEnabled = FALSE;
        set_bell_visibility(FALSE);

        register_self();

        // Request settings from settings module
        kSend(CONTEXT, "settings", SETTINGS_BUS,
            kPayload(["get", 1]),
            NULL_KEY
        );

        logd("Bell plugin initialized - requested settings");
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

    timer() {
        // Continuous jingling while moving
        if (IsMoving && BellVisible && BellSoundEnabled) {
            play_jingle();
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
                if (!AclPending) return;

                key avatar = (key)llJsonGetValue(payload, ["avatar"]);
                if (avatar != CurrentUser) return;

                UserAcl = (integer)llJsonGetValue(payload, ["level"]);
                AclPending = FALSE;

                if (UserAcl < PLUGIN_MIN_ACL) {
                    llRegionSayTo(CurrentUser, 0, "Access denied.");
                    cleanup_session();
                    return;
                }

                show_main_menu();
                logd("ACL received: " + (string)UserAcl);
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

    moving_start() {
        if (!IsMoving) {
            IsMoving = TRUE;
            logd("Movement started");

            // Play first jingle immediately
            if (BellVisible && BellSoundEnabled) {
                play_jingle();
            }

            // Start timer for continuous jingling
            llSetTimerEvent(JINGLE_INTERVAL);
        }
    }

    moving_end() {
        if (IsMoving) {
            IsMoving = FALSE;
            logd("Movement stopped");

            // Stop the timer
            llSetTimerEvent(0.0);
        }
    }
}
