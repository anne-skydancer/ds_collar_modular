/*--------------------
PLUGIN: plugin_bell.lsl
VERSION: 1.10
REVISION: 5
PURPOSE: Bell visibility and jingling control for the collar
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility,
  namespaced internal message protocol
CHANGES:
- v1.1 rev 5: Restrict bell policy to ACL 3+ (Trustee, Unowned wearer, Primary Owner).
  Public (ACL 1) and Owned wearer (ACL 2) no longer see the bell plugin in the menu,
  as bell settings are owner-imposed controls.
- v1.1 rev 4: Namespaced internal message types (kernel.register, ui.dialog.open, etc.).
- v1.1 rev 3: Honor soft_reset / soft_reset_all from KERNEL_LIFECYCLE so
  factory reset clears cached bell state.
- v1.1 rev 2: Migrate dialog buttons to button_data format with context-based routing.
- v1.1 rev 1: Migrate settings reads from JSON broadcast to direct LSD reads.
  Remove apply_settings_delta(); fold side effects into apply_settings_sync()
  via previous-state comparison. Both settings_sync and settings_delta call
  parameterless apply_settings_sync(). Remove settings_get request from
  state_entry; call apply_settings_sync() directly.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads.
  Button list built from get_policy_buttons() + btn_allowed().
--------------------*/

integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_CONTEXT = "ui.core.bell";
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

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

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
    string policy = llLinksetDataRead("acl.policycontext:" + ctx);
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
show_menu(string context, string title, string body, list button_data) {
    SessionId = generate_session_id();
    MenuContext = context;

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);
}

/* -------------------- PLUGIN REGISTRATION -------------------- */
register_self() {
    // Write button visibility policy to LSD.
    // ACL 1 (Public) and ACL 2 (Owned wearer) are excluded — bell settings
    // are owner-imposed controls and should not be changed by the public
    // or by a wearer who is owned.
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "3", "Show,Sound,Volume +,Volume -",
        "4", "Show,Sound,Volume +,Volume -",
        "5", "Show,Sound,Volume +,Volume -"
    ]));

    // Register with kernel
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
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
    list button_data = [btn("Back", "back")];
    if (btn_allowed("Show")) button_data += [btn(visible_label, "toggle_visible")];
    if (btn_allowed("Sound")) button_data += [btn(sound_label, "toggle_sound")];
    if (btn_allowed("Volume +")) button_data += [btn("Volume +", "vol_up")];
    if (btn_allowed("Volume -")) button_data += [btn("Volume -", "vol_down")];

    string body = "Bell Control\n\n";
    body += "Visibility: " + (string)BellVisible + "\n";
    body += "Sound: " + (string)BellSoundEnabled + "\n";
    body += "Volume: " + (string)((integer)(BellVolume * 100)) + "%";

    show_menu("main", "Bell", body, button_data);
}

/* -------------------- SETTINGS MODIFICATION -------------------- */
persist_bell_setting(string setting_key, string value) {
    // Write to LSD immediately so state survives relog
    llLinksetDataWrite(setting_key, value);

    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", setting_key,
        "value", value
    ]), NULL_KEY);
}

/* -------------------- BUTTON HANDLER -------------------- */
handle_button_click(string msg) {
    string cmd = llJsonGetValue(msg, ["context"]);
    if (cmd == JSON_INVALID) cmd = llJsonGetValue(msg, ["button"]);

    if (MenuContext == "main") {
        if (cmd == "back") {
            return_to_root();
        }
        else if (cmd == "vol_up") {
            BellVolume = BellVolume + 0.1;
            if (BellVolume > 1.0) BellVolume = 1.0;
            persist_bell_setting(KEY_BELL_VOLUME, (string)BellVolume);
            llRegionSayTo(CurrentUser, 0, "Volume: " + (string)((integer)(BellVolume * 100)) + "%");
            show_main_menu();
        }
        else if (cmd == "vol_down") {
            BellVolume = BellVolume - 0.1;
            if (BellVolume < 0.0) BellVolume = 0.0;
            persist_bell_setting(KEY_BELL_VOLUME, (string)BellVolume);
            llRegionSayTo(CurrentUser, 0, "Volume: " + (string)((integer)(BellVolume * 100)) + "%");
            show_main_menu();
        }
        else if (cmd == "toggle_visible") {
            BellVisible = !BellVisible;
            set_bell_visibility(BellVisible);
            persist_bell_setting(KEY_BELL_VISIBLE, (string)BellVisible);
            if (BellVisible) {
                llRegionSayTo(CurrentUser, 0, "Bell shown.");
            } else {
                llRegionSayTo(CurrentUser, 0, "Bell hidden.");
            }
            show_main_menu();
        }
        else if (cmd == "toggle_sound") {
            BellSoundEnabled = !BellSoundEnabled;
            persist_bell_setting(KEY_BELL_SOUND_ENABLED, (string)BellSoundEnabled);
            if (BellSoundEnabled) {
                llRegionSayTo(CurrentUser, 0, "Bell sound enabled.");
            } else {
                llRegionSayTo(CurrentUser, 0, "Bell sound disabled.");
            }
            show_main_menu();
        }
    }
}

/* -------------------- NAVIGATION -------------------- */
return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
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
apply_settings_sync() {
    // Read all settings directly from LSD; compare with previous state
    // and trigger side effects only when values actually change.

    integer prev_visible = BellVisible;

    BellVisible = lsd_int(KEY_BELL_VISIBLE, BellVisible);
    BellSoundEnabled = lsd_int(KEY_BELL_SOUND_ENABLED, BellSoundEnabled);
    BellVolume = lsd_float(KEY_BELL_VOLUME, BellVolume);

    string tmp = llLinksetDataRead(KEY_BELL_SOUND);
    if (tmp != "") BellSound = tmp;

    // Side effect: visibility changed — update prim alpha
    if (BellVisible != prev_visible) {
        set_bell_visibility(BellVisible);
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

        // Apply any LSD-persisted settings (e.g. BellSound from notecard seeding)
        apply_settings_sync();

        register_self();
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

            if (msg_type == "kernel.registernow") {
                register_self();
                return;
            }

            if (msg_type == "kernel.ping") {
                send_pong();
                return;
            }

            if (msg_type == "kernel.reset" || msg_type == "kernel.resetall") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                llResetScript();
            }

            return;
        }

        /* -------------------- SETTINGS SYNC/DELTA -------------------- */if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                apply_settings_sync();
                return;
            }

            return;
        }

        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
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

            if (msg_type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;
                string response_session = llJsonGetValue(msg, ["session_id"]);
                if (response_session != SessionId) return;

                handle_button_click(msg);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
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
