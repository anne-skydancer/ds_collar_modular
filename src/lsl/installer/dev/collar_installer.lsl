/*--------------------
SCRIPT: collar_installer.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: DS Collar modular installer — transfers collar scripts to an unscripted
         target object using preset-based plugin selection. Uses a helper script
         handshake for secure PIN-based remote loading with script inhibition.
ARCHITECTURE: Sensor target selection, llRemoteLoadScriptPin transfer (running=FALSE),
              region say handshake with installer_helper.lsl
CHANGES:
- Initial implementation: preset dialogs (Minimal/Standard/Full), sensor-based
  targeting, sequential transfer with progress, helper-mediated activation
KNOWN ISSUES: llRemoteLoadScriptPin enforces a ~3s delay per call; large presets
              take proportional time to transfer
TODO: None
--------------------*/

/* -------------------- COMMUNICATION -------------------- */
integer CommChannel = 0;
integer CommHandle = 0;
integer DialogChannel = 0;
integer DialogHandle = 0;

/* -------------------- TRANSFER STATE -------------------- */
key TargetKey = NULL_KEY;
key InstallerUser = NULL_KEY;
integer TargetPin = 0;
list TransferQueue = [];
integer TransferIndex = 0;
integer TransferTotal = 0;

/* -------------------- INSTALL PHASES -------------------- */
integer PHASE_IDLE        = 0;
integer PHASE_PRESET      = 1;
integer PHASE_TARGET      = 2;
integer PHASE_CONFIRM     = 3;
integer PHASE_HELPER_WAIT = 4;
integer PHASE_TRANSFER    = 5;
integer PHASE_MANUAL      = 6;
integer Phase = 0;

string SelectedPreset = "";

/* -------------------- MANUAL MODE STATE -------------------- */
// Plugins offered one-by-one in manual mode (script name, display label stride-2)
list MANUAL_CATALOG = [
    "plugin_lock",      "Lock",
    "plugin_animate",   "Animate",
    "plugin_access",    "Access",
    "plugin_public",    "Public",
    "plugin_leash",     "Leash",
    "plugin_bell",      "Bell",
    "plugin_blacklist",  "Blacklist",
    "plugin_sos",       "SOS",
    "plugin_maint",     "Maintenance",
    "plugin_status",    "Status",
    "plugin_restrict",  "Restrict",
    "plugin_rlvex",     "RLV Exceptions",
    "plugin_relay",     "Relay",
    "plugin_tpe",       "TPE"
];
integer MANUAL_STRIDE = 2;
integer ManualIndex = 0;

/* -------------------- SENSOR STATE -------------------- */
list SensorKeys = [];
list SensorNames = [];

/* --------------------------------------------------------
   SCRIPT PRESETS

   Core modules are always installed (kernel, auth, bootstrap,
   dialogs, menu, settings, ui). The lists below define which
   ADDITIONAL scripts each preset adds.

   Script names match inventory items (with or without .lsl).
   -------------------------------------------------------- */

list CORE_SCRIPTS = [
    "collar_kernel",
    "kmod_auth",
    "kmod_bootstrap",
    "kmod_dialogs",
    "kmod_menu",
    "kmod_settings",
    "kmod_ui"
];

// Minimal: locking, animation, access, public, leash
list MINIMAL_PLUGINS = [
    "plugin_lock",
    "plugin_animate",
    "plugin_access",
    "plugin_public",
    "plugin_leash",
    "kmod_leash",
    "kmod_particles"
];

// Standard: Minimal + leash suite, bell, blacklist, safety, maintenance
list STANDARD_PLUGINS = [
    "plugin_lock",
    "plugin_animate",
    "plugin_access",
    "plugin_public",
    "plugin_leash",
    "plugin_bell",
    "plugin_blacklist",
    "plugin_sos",
    "plugin_maint",
    "plugin_status",
    "kmod_leash",
    "kmod_particles"
];

// Full: every plugin and module
list FULL_PLUGINS = [
    "plugin_lock",
    "plugin_animate",
    "plugin_access",
    "plugin_public",
    "plugin_leash",
    "plugin_bell",
    "plugin_blacklist",
    "plugin_sos",
    "plugin_maint",
    "plugin_status",
    "plugin_restrict",
    "plugin_rlvex",
    "plugin_relay",
    "plugin_tpe",
    "kmod_leash",
    "kmod_particles",
    "kmod_remote"
];

integer derive_channel(key avatar) {
    integer ch = (integer)("0x" + llGetSubString((string)avatar, 0, 7));
    if (ch > 0) ch = ch * -1;
    if (ch == 0) ch = -1;
    return ch;
}

/* -------------------- CLEANUP -------------------- */

cleanup() {
    if (CommHandle) {
        llListenRemove(CommHandle);
        CommHandle = 0;
    }
    if (DialogHandle) {
        llListenRemove(DialogHandle);
        DialogHandle = 0;
    }
    llSetTimerEvent(0.0);
    TargetKey = NULL_KEY;
    TargetPin = 0;
    TransferQueue = [];
    TransferIndex = 0;
    TransferTotal = 0;
    SensorKeys = [];
    SensorNames = [];
    Phase = PHASE_IDLE;
    SelectedPreset = "";
    ManualIndex = 0;
}

/* -------------------- DIALOG -------------------- */

open_dialog(key user, string body, list buttons) {
    if (DialogHandle) llListenRemove(DialogHandle);
    DialogChannel = (integer)llFrand(-999999.0) - 1000;
    DialogHandle = llListen(DialogChannel, "", user, "");

    // Pad to multiples of 3 for clean grid layout
    integer n = llGetListLength(buttons);
    while ((n % 3) != 0) {
        buttons += " ";
        n += 1;
    }

    llDialog(user, body, buttons, DialogChannel);
}

/* -------------------- MANUAL MODE -------------------- */

// Prompt for the next plugin, or send activate if all offered
prompt_next_plugin() {
    integer catalog_len = llGetListLength(MANUAL_CATALOG) / MANUAL_STRIDE;

    if (ManualIndex >= catalog_len) {
        // All plugins offered — send activate to helper
        llRegionSayTo(InstallerUser, 0,
            "All plugins offered. Activating collar...");
        llRegionSay(CommChannel, llList2Json(JSON_OBJECT, [
            "type", "activate"
        ]));
        llSetTimerEvent(30.0);
        return;
    }

    Phase = PHASE_MANUAL;
    string label = llList2String(MANUAL_CATALOG, ManualIndex * MANUAL_STRIDE + 1);
    open_dialog(InstallerUser,
        "Install plugin: " + label + "?",
        ["Yes", "No"]);
}

// Transfer a single plugin and its deps immediately, then prompt the next one
transfer_manual_plugin(string script_name) {
    // Build a small batch: the plugin + any deps not already transferred
    list batch = [script_name];

    if (script_name == "plugin_leash") {
        if (llListFindList(TransferQueue, ["kmod_leash"]) == -1) {
            batch += ["kmod_leash", "kmod_particles"];
        }
    }
    else if (script_name == "plugin_restrict" || script_name == "plugin_rlvex"
             || script_name == "plugin_relay" || script_name == "plugin_tpe") {
        if (llListFindList(TransferQueue, ["kmod_remote"]) == -1) {
            batch += ["kmod_remote"];
        }
    }

    // Append to queue and begin transferring
    TransferQueue += batch;
    TransferTotal = llGetListLength(TransferQueue);
    Phase = PHASE_TRANSFER;
    transfer_next();
}

/* -------------------- QUEUE BUILDER -------------------- */

build_queue(string preset) {
    list plugins = [];

    if (preset == "Minimal") {
        plugins = MINIMAL_PLUGINS;
    }
    else if (preset == "Standard") {
        plugins = STANDARD_PLUGINS;
    }
    else {
        plugins = FULL_PLUGINS;
    }

    // Core first, then selected plugins
    TransferQueue = CORE_SCRIPTS + plugins;
    TransferIndex = 0;
    TransferTotal = llGetListLength(TransferQueue);
}

/* -------------------- INVENTORY RESOLUTION -------------------- */

// Scripts may be stored with or without .lsl extension
string resolve_name(string base_name) {
    if (llGetInventoryType(base_name) != INVENTORY_NONE) return base_name;
    string with_ext = base_name + ".lsl";
    if (llGetInventoryType(with_ext) != INVENTORY_NONE) return with_ext;
    return "";
}

// Verify every script in the queue exists in installer inventory
integer verify_inventory() {
    integer i;
    integer count = llGetListLength(TransferQueue);

    for (i = 0; i < count; i++) {
        string base_name = llList2String(TransferQueue, i);
        if (resolve_name(base_name) == "") {
            llRegionSayTo(InstallerUser, 0,
                "ERROR: Missing script '" + base_name + "' in installer inventory.");
            return FALSE;
        }
    }
    return TRUE;
}

/* -------------------- TRANSFER ENGINE -------------------- */

transfer_next() {
    if (TransferIndex >= TransferTotal) {
        // In manual mode, prompt for the next plugin instead of activating
        if (SelectedPreset == "Manual") {
            ManualIndex += 1;
            prompt_next_plugin();
            return;
        }

        // All scripts transferred — tell helper to activate
        llRegionSayTo(InstallerUser, 0,
            "All scripts transferred. Activating collar...");

        llRegionSay(CommChannel, llList2Json(JSON_OBJECT, [
            "type", "activate"
        ]));

        // Wait up to 30s for install_complete from helper
        llSetTimerEvent(30.0);
        return;
    }

    string base_name = llList2String(TransferQueue, TransferIndex);
    string actual_name = resolve_name(base_name);

    if (actual_name == "") {
        llRegionSayTo(InstallerUser, 0,
            "WARNING: Skipping missing script '" + base_name + "'");
        TransferIndex += 1;
        llSetTimerEvent(0.1);
        return;
    }

    // Progress every 5 scripts
    if ((TransferIndex % 5) == 0) {
        llRegionSayTo(InstallerUser, 0,
            "Installing [" + (string)(TransferIndex + 1) + "/"
            + (string)TransferTotal + "]: " + actual_name + "...");
    }

    // Load into target with running=FALSE (script stays dormant)
    llRemoteLoadScriptPin(TargetKey, actual_name, TargetPin, FALSE, 0);

    TransferIndex += 1;

    // Brief yield after the ~3s built-in delay so events can process
    llSetTimerEvent(0.1);
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        CommChannel = derive_channel(llGetOwner());
        Phase = PHASE_IDLE;
        llOwnerSay("DS Collar Installer ready. Touch to begin.");
    }

    touch_start(integer total) {
        key toucher = llDetectedKey(0);

        if (toucher != llGetOwner()) {
            llRegionSayTo(toucher, 0, "Only the owner can use this installer.");
            return;
        }

        if (Phase != PHASE_IDLE) {
            llRegionSayTo(toucher, 0,
                "Installation in progress. Please wait or reset the installer.");
            return;
        }

        InstallerUser = toucher;
        Phase = PHASE_PRESET;

        open_dialog(toucher,
            "DS Collar Installer\n\n"
            + "Select installation preset:\n\n"
            + "Minimal  - Lock, Animate, Access, Public, Leash\n"
            + "Standard - + Bell, Blacklist, SOS, Maint, Status\n"
            + "Full     - All plugins and modules\n"
            + "Manual   - Choose each plugin individually\n",
            ["Minimal", "Standard", "Full", "Manual", "Cancel"]);
    }

    /* -------------------- DIALOG / COMM LISTENER -------------------- */

    listen(integer channel, string name, key id, string message) {

        /* ---------- Dialog responses ---------- */
        if (channel == DialogChannel) {
            if (message == " ") return;  // padding button

            if (message == "Cancel") {
                llRegionSayTo(InstallerUser, 0, "Installation cancelled.");
                cleanup();
                return;
            }

            /* -- Preset selection -- */
            if (Phase == PHASE_PRESET) {
                if (message != "Minimal" && message != "Standard"
                    && message != "Full" && message != "Manual") return;

                if (message == "Manual") {
                    // Core scripts first, plugins prompted after transfer
                    SelectedPreset = "Manual";
                    TransferQueue = CORE_SCRIPTS;
                    TransferIndex = 0;
                    TransferTotal = llGetListLength(CORE_SCRIPTS);
                    ManualIndex = -1;
                }
                else {
                    SelectedPreset = message;
                    build_queue(SelectedPreset);
                }

                if (!verify_inventory()) {
                    cleanup();
                    return;
                }

                Phase = PHASE_TARGET;
                llRegionSayTo(InstallerUser, 0,
                    SelectedPreset + " preset (" + (string)TransferTotal
                    + " scripts). Scanning for nearby objects...");

                // 10 m range, all non-avatar objects
                llSensor("", NULL_KEY, PASSIVE | ACTIVE, 10.0, PI);
                return;
            }

            /* -- Manual per-plugin prompt -- */
            if (Phase == PHASE_MANUAL) {
                if (message == "Yes") {
                    string script_name = llList2String(MANUAL_CATALOG,
                        ManualIndex * MANUAL_STRIDE);
                    transfer_manual_plugin(script_name);
                    return;
                }
                // "No" — skip this plugin, prompt the next one
                ManualIndex += 1;
                prompt_next_plugin();
                return;
            }

            /* -- Target selection -- */
            if (Phase == PHASE_TARGET) {
                integer idx = llListFindList(SensorNames, [message]);
                if (idx == -1) {
                    llRegionSayTo(InstallerUser, 0, "Object not found. Restarting.");
                    cleanup();
                    return;
                }

                TargetKey = llList2Key(SensorKeys, idx);
                Phase = PHASE_CONFIRM;

                open_dialog(InstallerUser,
                    "Install " + SelectedPreset + " (" + (string)TransferTotal
                    + " scripts) into:\n\n" + message + "\n\nProceed?",
                    ["Install", "Cancel"]);
                return;
            }

            /* -- Confirmation -- */
            if (Phase == PHASE_CONFIRM) {
                if (message != "Install") {
                    llRegionSayTo(InstallerUser, 0, "Installation cancelled.");
                    cleanup();
                    return;
                }

                Phase = PHASE_HELPER_WAIT;

                // Listen on comm channel for helper handshake
                CommHandle = llListen(CommChannel, "", NULL_KEY, "");

                llRegionSayTo(InstallerUser, 0,
                    "Waiting for installer helper in target object...\n"
                    + "Drop 'installer_helper' into the collar now if you haven't already.");

                // Timeout if helper does not respond
                llSetTimerEvent(30.0);
                return;
            }

            return;
        }

        /* ---------- Comm channel (helper handshake) ---------- */
        if (channel == CommChannel) {
            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type == JSON_INVALID) return;

            /* -- Helper ready with PIN -- */
            if (msg_type == "helper_ready" && Phase == PHASE_HELPER_WAIT) {
                // Verify the message came from our chosen target
                string sender_target = llJsonGetValue(message, ["target"]);
                if ((key)sender_target != TargetKey) return;

                TargetPin = (integer)llJsonGetValue(message, ["pin"]);
                if (TargetPin == 0) {
                    llRegionSayTo(InstallerUser, 0,
                        "ERROR: Invalid PIN from helper. Aborting.");
                    llRegionSay(CommChannel, llList2Json(JSON_OBJECT, [
                        "type", "abort"
                    ]));
                    cleanup();
                    return;
                }

                Phase = PHASE_TRANSFER;

                llRegionSayTo(InstallerUser, 0,
                    "Helper connected. Beginning script transfer ("
                    + (string)TransferTotal + " scripts)...");

                transfer_next();
                return;
            }

            /* -- Installation complete -- */
            if (msg_type == "install_complete") {
                llSetTimerEvent(0.0);

                llRegionSayTo(InstallerUser, 0,
                    "\n========================================\n"
                    + "  DS Collar Installation Complete\n"
                    + "========================================\n"
                    + "Preset:  " + SelectedPreset + "\n"
                    + "Scripts: " + (string)TransferTotal + "\n"
                    + "Target:  " + llKey2Name(TargetKey) + "\n"
                    + "========================================\n"
                    + "You may now wear the collar.\n");

                cleanup();
                return;
            }

            return;
        }
    }

    /* -------------------- SENSOR RESULTS -------------------- */

    sensor(integer num_detected) {
        if (Phase != PHASE_TARGET) return;

        SensorKeys = [];
        SensorNames = [];

        integer i;
        for (i = 0; i < num_detected; i++) {
            key obj_key = llDetectedKey(i);

            // Skip self
            if (obj_key == llGetKey()) {
                // skip self
            }
            else {
                // Only list objects owned by the person running the installer
                list details = llGetObjectDetails(obj_key, [OBJECT_OWNER]);
                if (llList2Key(details, 0) == InstallerUser) {
                    string obj_name = llDetectedName(i);

                    // Dialog buttons max 24 characters
                    if (llStringLength(obj_name) > 24) {
                        obj_name = llGetSubString(obj_name, 0, 23);
                    }

                    // Avoid duplicate button labels
                    if (llListFindList(SensorNames, [obj_name]) == -1) {
                        SensorKeys += [obj_key];
                        SensorNames += [obj_name];
                    }
                }
            }
        }

        if (llGetListLength(SensorNames) == 0) {
            llRegionSayTo(InstallerUser, 0,
                "No suitable objects found within 10 m. "
                + "Rez the collar nearby and try again.");
            cleanup();
            return;
        }

        // Cap at 11 objects (12 buttons minus Cancel)
        list buttons = SensorNames;
        if (llGetListLength(buttons) > 11) {
            buttons = llList2List(buttons, 0, 10);
        }
        buttons += ["Cancel"];

        open_dialog(InstallerUser,
            "Select target object for " + SelectedPreset + " installation:",
            buttons);
    }

    no_sensor() {
        if (Phase != PHASE_TARGET) return;
        llRegionSayTo(InstallerUser, 0,
            "No objects detected within 10 m. "
            + "Rez the collar nearby and try again.");
        cleanup();
    }

    /* -------------------- TIMER -------------------- */

    timer() {
        // Helper handshake timeout
        if (Phase == PHASE_HELPER_WAIT) {
            llSetTimerEvent(0.0);
            llRegionSayTo(InstallerUser, 0,
                "ERROR: Helper did not respond. Make sure the target is modifiable.");
            cleanup();
            return;
        }

        // Transfer phase — send next script or handle activation timeout
        if (Phase == PHASE_TRANSFER) {
            if (TransferIndex < TransferTotal) {
                transfer_next();
            }
            else {
                // Activation confirmation timed out
                llSetTimerEvent(0.0);
                llRegionSayTo(InstallerUser, 0,
                    "WARNING: Activation not confirmed, but scripts may have been "
                    + "installed. Check the collar.");
                cleanup();
            }
            return;
        }
    }

    /* -------------------- LIFECYCLE -------------------- */

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            cleanup();
            llResetScript();
        }
    }
}
