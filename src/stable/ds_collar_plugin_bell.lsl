/*--------------------
PLUGIN: ds_collar_plugin_bell.lsl
VERSION: 1.00
REVISION: 10
PURPOSE: Bell visibility and jingling control for the collar
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Added independent toggles for bell visibility and sound playback
- Enabled jingle loop while wearer moves with adjustable volume levels
- Searches linkset for bell prim to update transparency dynamically
- Persists bell settings via settings bus sync and delta updates
- Prevented premature resets by deferring defaults until settings load
--------------------*/

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_CONTEXT = "bell";
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

/* -------------------- HELPERS -------------------- */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[BELL] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
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

/* -------------------- ACL QUERIES -------------------- */
request_acl(key user) {
    AclPending = TRUE;
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user
    ]), user);
    logd("ACL query sent for " + llKey2Name(user));
}

/* -------------------- PLUGIN REGISTRATION -------------------- */
register_self() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
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

/* -------------------- SETTINGS MODIFICATION -------------------- */
persist_bell_setting(string setting_key, string value) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", setting_key,
        "value", value
    ]);
    
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLER -------------------- */
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

/* -------------------- NAVIGATION -------------------- */
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
    MenuContext = "";
    logd("Session cleaned up");
}

/* -------------------- SETTINGS HANDLING -------------------- */
apply_settings_sync(string msg) {
    if (!json_has(msg, ["kv"])) return;
    string kv_json = llJsonGetValue(msg, ["kv"]);
    
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

apply_settings_delta(string msg) {
    if (!json_has(msg, ["changes"])) return;
    string changes = llJsonGetValue(msg, ["changes"]);
    
    if (json_has(changes, [KEY_BELL_VISIBLE])) {
        integer new_visible = (integer)llJsonGetValue(changes, [KEY_BELL_VISIBLE]);
        set_bell_visibility(new_visible);
        logd("Delta: bell_visible=" + (string)new_visible);
    }
    
    if (json_has(changes, [KEY_BELL_SOUND_ENABLED])) {
        BellSoundEnabled = (integer)llJsonGetValue(changes, [KEY_BELL_SOUND_ENABLED]);
        logd("Delta: bell_sound_enabled=" + (string)BellSoundEnabled);
    }
    
    if (json_has(changes, [KEY_BELL_VOLUME])) {
        BellVolume = (float)llJsonGetValue(changes, [KEY_BELL_VOLUME]);
        logd("Delta: bell_volume=" + (string)BellVolume);
    }
    
    if (json_has(changes, [KEY_BELL_SOUND])) {
        BellSound = llJsonGetValue(changes, [KEY_BELL_SOUND]);
        logd("Delta: bell_sound=" + BellSound);
    }
}

/* -------------------- EVENT HANDLERS -------------------- */
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
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]), NULL_KEY);
        
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
        /* -------------------- KERNEL LIFECYCLE -------------------- */if (num == KERNEL_LIFECYCLE) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
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
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
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
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "start") {
                if (!json_has(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                
                CurrentUser = id;
                request_acl(id);
                return;
            }
            
            return;
        }
        
        /* -------------------- AUTH RESULT -------------------- */if (num == AUTH_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "acl_result") {
                if (!AclPending) return;
                if (!json_has(msg, ["avatar"])) return;
                
                key avatar = (key)llJsonGetValue(msg, ["avatar"]);
                if (avatar != CurrentUser) return;
                
                if (json_has(msg, ["level"])) {
                    UserAcl = (integer)llJsonGetValue(msg, ["level"]);
                    AclPending = FALSE;
                    
                    if (UserAcl < PLUGIN_MIN_ACL) {
                        llRegionSayTo(CurrentUser, 0, "Access denied.");
                        cleanup_session();
                        return;
                    }
                    
                    show_main_menu();
                    logd("ACL received: " + (string)UserAcl);
                }
                return;
            }
            
            return;
        }
        
        /* -------------------- DIALOG RESPONSE -------------------- */if (num == DIALOG_BUS) {
            if (!json_has(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
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
