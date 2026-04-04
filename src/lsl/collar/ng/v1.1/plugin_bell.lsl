/*--------------------
PLUGIN: plugin_bell.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Bell visibility and jingling control for the collar
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads.
  Button list built from get_policy_buttons() + btn_allowed().
--------------------*/

integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_CONTEXT = "bell";
string PLUGIN_LABEL = "Bell";

// Settings keys
string KEY_BELL_VISIBLE = "bell.visible";
string KEY_BELL_SOUND_ENABLED = "bell.enablesound";
string KEY_BELL_VOLUME = "bell.volume";
string KEY_BELL_SOUND = "bell.sound";

// State
integer BellVisible = FALSE;
integer BellSoundEnabled = FALSE;
float BellVolume = 0.3;
string BellSound = "16fcf579-82cb-b110-c1a4-5fa5e1385406";
integer IsMoving = FALSE;
integer BellLink = 0;

// Jingle timing
float JINGLE_INTERVAL = 1.75;  // Play sound every 1.75 seconds while moving

// Session state
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
string MenuContext = "";

/* -------------------- HELPERS -------------------- */



string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD PERSISTENCE HELPERS -------------------- */
integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

float lsd_float(string lsd_key, float fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (float)v;
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

set_bell_visibility(integer visible) {
    if (BellLink == 0) {
        integer link_count = llGetNumberOfPrims();
        integer i;
        for (i = 1; i <= link_count; i++) {
            if (llToLower(llGetLinkName(i)) == "bell") {
                BellLink = i;
                jump found_bell;
            }
        }
        @found_bell;
    }

    if (BellLink != 0) {
        float alpha = 0.0;
        if (visible) alpha = 1.0;
        llSetLinkAlpha(BellLink, alpha, ALL_SIDES);
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
}

/* -------------------- UNIFIED MENU DISPLAY -------------------- */
show_menu(string context, string title, string body, list buttons) {
    SessionId = generate_session_id();
    MenuContext = context;

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]), NULL_KEY);
}

/* -------------------- PLUGIN REGISTRATION -------------------- */
register_self() {
    // Write button visibility policy to LSD (all ACL levels see same buttons)
    llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Show,Sound,Volume +,Volume -",
        "2", "Show,Sound,Volume +,Volume -",
        "3", "Show,Sound,Volume +,Volume -",
        "4", "Show,Sound,Volume +,Volume -",
        "5", "Show,Sound,Volume +,Volume -"
    ]));

    // Register with kernel
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- MENU SYSTEM -------------------- */
show_main_menu() {
    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

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
    list buttons = ["Back"];
    if (btn_allowed("Show")) buttons += [visible_label];
    if (btn_allowed("Sound")) buttons += [sound_label];
    if (btn_allowed("Volume +")) buttons += ["Volume +"];
    if (btn_allowed("Volume -")) buttons += ["Volume -"];

    string body = "Bell Control\n\n";
    body += "Visibility: " + (string)BellVisible + "\n";
    body += "Sound: " + (string)BellSoundEnabled + "\n";
    body += "Volume: " + (string)((integer)(BellVolume * 100)) + "%";

    show_menu("main", "Bell", body, buttons);
}

/* -------------------- SETTINGS MODIFICATION -------------------- */
persist_bell_setting(string setting_key, string value) {
    // Write to LSD immediately so state survives relog
    llLinksetDataWrite(setting_key, value);

    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", setting_key,
        "value", value
    ]), NULL_KEY);
}

/* -------------------- BUTTON HANDLER -------------------- */
handle_button_click(string button) {

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

/* -------------------- NAVIGATION -------------------- */
return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "dialog_close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    MenuContext = "";
}

/* -------------------- SETTINGS HANDLING -------------------- */
apply_settings_sync(string msg) {
    string kv_json = llJsonGetValue(msg, ["kv"]);
    if (kv_json == JSON_INVALID) return;

    // Plugin-owned keys: only seed from notecard when LSD is empty (first wear).
    // After that, LSD is the authority — runtime changes survive relog.
    if (llLinksetDataRead(KEY_BELL_VISIBLE) == "") {
        string tmp = llJsonGetValue(kv_json, [KEY_BELL_VISIBLE]);
        if (tmp != JSON_INVALID) {
            integer new_visible = (integer)tmp;
            set_bell_visibility(new_visible);
            llLinksetDataWrite(KEY_BELL_VISIBLE, tmp);
        }
    }

    if (llLinksetDataRead(KEY_BELL_SOUND_ENABLED) == "") {
        string tmp = llJsonGetValue(kv_json, [KEY_BELL_SOUND_ENABLED]);
        if (tmp != JSON_INVALID) {
            BellSoundEnabled = (integer)tmp;
            llLinksetDataWrite(KEY_BELL_SOUND_ENABLED, tmp);
        }
    }

    if (llLinksetDataRead(KEY_BELL_VOLUME) == "") {
        string tmp = llJsonGetValue(kv_json, [KEY_BELL_VOLUME]);
        if (tmp != JSON_INVALID) {
            BellVolume = (float)tmp;
            llLinksetDataWrite(KEY_BELL_VOLUME, tmp);
        }
    }

    // BellSound is set-once from notecard (not user-changeable); always apply
    string tmp = llJsonGetValue(kv_json, [KEY_BELL_SOUND]);
    if (tmp != JSON_INVALID) {
        BellSound = tmp;
    }
}

apply_settings_delta(string msg) {
    string changes = llJsonGetValue(msg, ["changes"]);
    if (changes == JSON_INVALID) return;

    // Deltas represent intentional runtime changes: apply AND write to LSD
    if ((llJsonGetValue(changes, [KEY_BELL_VISIBLE]) != JSON_INVALID)) {
        string tmp = llJsonGetValue(changes, [KEY_BELL_VISIBLE]);
        set_bell_visibility((integer)tmp);
        llLinksetDataWrite(KEY_BELL_VISIBLE, tmp);
    }

    string tmp = llJsonGetValue(changes, [KEY_BELL_SOUND_ENABLED]);
    if (tmp != JSON_INVALID) {
        BellSoundEnabled = (integer)tmp;
        llLinksetDataWrite(KEY_BELL_SOUND_ENABLED, tmp);
    }

    tmp = llJsonGetValue(changes, [KEY_BELL_VOLUME]);
    if (tmp != JSON_INVALID) {
        BellVolume = (float)tmp;
        llLinksetDataWrite(KEY_BELL_VOLUME, tmp);
    }

    tmp = llJsonGetValue(changes, [KEY_BELL_SOUND]);
    if (tmp != JSON_INVALID) {
        BellSound = tmp;
    }
}

/* -------------------- EVENT HANDLERS -------------------- */
default {
    state_entry() {
        cleanup_session();

        // Restore from LSD (persists through relog); fall back to safe defaults on first wear
        BellVisible = lsd_int(KEY_BELL_VISIBLE, FALSE);
        BellSoundEnabled = lsd_int(KEY_BELL_SOUND_ENABLED, FALSE);
        BellVolume = lsd_float(KEY_BELL_VOLUME, 0.3);
        set_bell_visibility(BellVisible);

        register_self();

        // Request settings for BellSound UUID (notecard-only, not LSD-persisted)
        // and to trigger absent-guard seeding on first wear
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]), NULL_KEY);
    }

    on_rez(integer start_param) {
        // Don't reset script on attach/detach
        // This preserves state, but settings sync will restore saved state anyway
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
        if (change & CHANGED_LINK) {
            BellLink = 0;
        }
    }

    timer() {
        // Continuous jingling while moving
        if (IsMoving && BellVisible && BellSoundEnabled) {
            play_jingle();
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

                CurrentUser = id;
                UserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                show_main_menu();
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSE -------------------- */if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "dialog_response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;
                string response_session = llJsonGetValue(msg, ["session_id"]);
                if (response_session != SessionId) return;

                string button = llJsonGetValue(msg, ["button"]);
                handle_button_click(button);
                return;
            }

            if (msg_type == "dialog_timeout") {
                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                if (timeout_session == JSON_INVALID) return;
                if (timeout_session != SessionId) return;
                cleanup_session();
                return;
            }

            return;
        }
    }

    moving_start() {
        if (!IsMoving) {
            IsMoving = TRUE;

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

            // Stop the timer
            llSetTimerEvent(0.0);
        }
    }
}
