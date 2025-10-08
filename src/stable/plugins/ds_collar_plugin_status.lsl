/* =============================================================
   PLUGIN: ds_collar_plugin_status.lsl  (Optimized & Consistent)
   PURPOSE: Show collar status; Back returns to main menu
   NOTES:
     - Authoritative kernel JSON (register/heartbeat/soft-reset)
     - Settings-driven status view (read-only)
     - Private dialog channel + safe listens
     - No AUTH gate (min_acl = 1; audience = all)
   ============================================================= */

integer DEBUG = FALSE;

/* ---------- Protocol strings (authoritative) ---------- */
string TYPE_REGISTER            = "register";
string TYPE_REGISTER_NOW        = "register_now";
string TYPE_PLUGIN_PING         = "plugin_ping";
string TYPE_PLUGIN_PONG         = "plugin_pong";
string TYPE_PLUGIN_SOFT_RESET   = "plugin_soft_reset";
string TYPE_SETTINGS_GET        = "settings_get";
string TYPE_SETTINGS_SYNC       = "settings_sync";
string TYPE_PLUGIN_RETURN       = "plugin_return";

/* ---------- Link message channels (authoritative) ---------- */
integer K_PLUGIN_REG_QUERY      = 500;  // Kernel → Plugins: register_now
integer K_PLUGIN_REG_REPLY      = 501;  // Plugins → Kernel: register
integer K_PLUGIN_SOFT_RESET     = 504;  // Plugins → Kernel: plugin_soft_reset

integer K_PLUGIN_PING           = 650;  // Kernel → Plugins: plugin_ping
integer K_PLUGIN_PONG           = 651;  // Plugins → Kernel: plugin_pong

integer K_SETTINGS_QUERY        = 800;  // Any ↔ Settings
integer K_SETTINGS_SYNC         = 870;  // Settings → Any

integer K_PLUGIN_START          = 900;  // UI → Plugin: start (context only)
integer K_PLUGIN_RETURN_NUM     = 901;  // Plugin → UI: plugin_return

/* ---------- Identity / registration ---------- */
integer PLUGIN_SN        = 0;
string  PLUGIN_LABEL     = "Status";
integer PLUGIN_MIN_ACL   = 1;            // Public
string  PLUGIN_CONTEXT   = "core_status";
string  ROOT_CONTEXT     = "core_root";

string  REG_AUDIENCE     = "all";        // explicit audience (all/touchers/wearer)

/* ---------- Menu constants ---------- */
string  BTN_BACK         = "Back";
string  BTN_FILL         = " ";          // real blank (not "~")
integer DIALOG_TIMEOUT   = 180;

/* ---------- Settings keys ---------- */
string KEY_OWNER_KEY       = "owner_key";
string KEY_OWNER_HON       = "owner_hon";
string KEY_TRUSTEES        = "trustees";
string KEY_TRUSTEE_HONS    = "trustee_honorifics";
string KEY_BLACKLIST       = "blacklist";
string KEY_PUBLIC_ACCESS   = "public_mode";
string KEY_LOCKED          = "locked";
string KEY_TPE_MODE        = "tpe_mode";

/* ---------- State mirrored from settings ---------- */
key     OwnerKey          = NULL_KEY;
string  OwnerHonorific    = "";
list    TrusteeKeys       = [];
list    TrusteeHonorifics = [];
list    BlacklistKeys     = [];
integer PublicAccess      = FALSE;
integer Locked            = FALSE;
integer TpeMode           = FALSE;

/* ---------- Owner name cache + requests ---------- */
string  OwnerDisplay      = "";       // preferred: Display Name (or legacy if needed)
key     OwnerDisplayQuery = NULL_KEY;  // query id for llRequestDisplayName
key     OwnerLegacyQuery  = NULL_KEY;  // query id for llRequestAgentData(DATA_NAME)
key     LastOwnerKey      = NULL_KEY;  // track changes to re-fetch names

/* ---------- Session state ---------- */
key     User           = NULL_KEY;
integer Chan           = 0;
integer Listen         = 0;

/* ========================== Helpers ========================== */
integer json_has(string json_str, list path) {
    if (llJsonGetValue(json_str, path) == JSON_INVALID) {
        return FALSE;
    }
    return TRUE;
}

integer logd(string log_msg) {
    if (DEBUG) llOwnerSay("[STATUS] " + log_msg);
    return 0;
}

/* ---------- Owner name resolution ---------- */
integer request_owner_names() {
    if (OwnerKey == NULL_KEY) return 0;
    // clear old cache and start fresh queries
    OwnerDisplay      = "";
    OwnerDisplayQuery = llRequestDisplayName(OwnerKey);
    OwnerLegacyQuery  = llRequestAgentData(OwnerKey, DATA_NAME);
    return 0;
}

string owner_label() {
    // Prefer cached display/legacy name; otherwise indicate fetching
    string owner_name = OwnerDisplay;
    if (owner_name == "") {
        owner_name = "(fetching…)";
    }

    // Apply honorific if present
    if (OwnerHonorific != "") {
        return OwnerHonorific + " " + owner_name;
    }
    return owner_name;
}

/* ---------- Registration / soft-reset ---------- */
integer register_self() {
    string json_obj = llList2Json(JSON_OBJECT, []);
    json_obj = llJsonSetValue(json_obj, ["type"],    TYPE_REGISTER);
    json_obj = llJsonSetValue(json_obj, ["sn"],      (string)PLUGIN_SN);
    json_obj = llJsonSetValue(json_obj, ["label"],   PLUGIN_LABEL);
    json_obj = llJsonSetValue(json_obj, ["min_acl"], (string)PLUGIN_MIN_ACL);
    json_obj = llJsonSetValue(json_obj, ["context"], PLUGIN_CONTEXT);
    json_obj = llJsonSetValue(json_obj, ["script"],  llGetScriptName());
    /* audience hint (omit if "all") */
    if (REG_AUDIENCE != "" && REG_AUDIENCE != "all") {
        json_obj = llJsonSetValue(json_obj, ["audience"], REG_AUDIENCE);
    }
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, json_obj, NULL_KEY);
    logd("Registered with kernel.");
    return 0;
}

integer notify_soft_reset() {
    string json_obj = llList2Json(JSON_OBJECT, []);
    json_obj = llJsonSetValue(json_obj, ["type"],    TYPE_PLUGIN_SOFT_RESET);
    json_obj = llJsonSetValue(json_obj, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, json_obj, NULL_KEY);
    return 0;
}

/* ---------- Settings I/O ---------- */
integer request_settings_sync_once() {
    string json_obj = llList2Json(JSON_OBJECT, []);
    json_obj = llJsonSetValue(json_obj, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, json_obj, NULL_KEY);
    return 0;
}

integer update_from_settings(string kv_json) {
    /* defensive: expect an object */
    if (llGetSubString(kv_json, 0, 0) != "{") return 0;

    key previous_owner = OwnerKey;

    /* reset local mirror first */
    OwnerKey          = NULL_KEY;
    OwnerHonorific    = "";
    TrusteeKeys       = [];
    TrusteeHonorifics = [];
    BlacklistKeys     = [];
    PublicAccess      = FALSE;
    Locked            = FALSE;
    TpeMode           = FALSE;

    if (json_has(kv_json, [KEY_OWNER_KEY])) {
        OwnerKey = (key)llJsonGetValue(kv_json, [KEY_OWNER_KEY]);
    }
    if (json_has(kv_json, [KEY_OWNER_HON])) {
        OwnerHonorific = llJsonGetValue(kv_json, [KEY_OWNER_HON]);
    }

    if (json_has(kv_json, [KEY_TRUSTEES])) {
        string trustees_json = llJsonGetValue(kv_json, [KEY_TRUSTEES]);
        if (llGetSubString(trustees_json, 0, 0) == "[") {
            TrusteeKeys = llJson2List(trustees_json);
        }
    }
    if (json_has(kv_json, [KEY_TRUSTEE_HONS])) {
        string honorifics_json = llJsonGetValue(kv_json, [KEY_TRUSTEE_HONS]);
        if (llGetSubString(honorifics_json, 0, 0) == "[") {
            TrusteeHonorifics = llJson2List(honorifics_json);
        }
    }
    if (json_has(kv_json, [KEY_BLACKLIST])) {
        string blacklist_json = llJsonGetValue(kv_json, [KEY_BLACKLIST]);
        if (llGetSubString(blacklist_json, 0, 0) == "[") {
            BlacklistKeys = llJson2List(blacklist_json);
        }
    }

    if (json_has(kv_json, [KEY_PUBLIC_ACCESS])) {
        PublicAccess = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_ACCESS]);
    }
    if (json_has(kv_json, [KEY_LOCKED])) {
        Locked = (integer)llJsonGetValue(kv_json, [KEY_LOCKED]);
    }
    if (json_has(kv_json, [KEY_TPE_MODE])) {
        TpeMode = (integer)llJsonGetValue(kv_json, [KEY_TPE_MODE]);
    }

    // If the owner changed, clear cached name and re-request
    if (OwnerKey != previous_owner) {
        LastOwnerKey = OwnerKey;
        OwnerDisplay = "";
        if (OwnerKey != NULL_KEY) {
            request_owner_names();
        }
    }

    logd("Settings mirror updated.");
    return 0;
}

/* ---------- UI plumbing ---------- */
integer cleanup_session() {
    if (Listen != 0) llListenRemove(Listen);
    Listen = 0;
    User   = NULL_KEY;
    Chan   = 0;
    llSetTimerEvent(0.0);
    return 0;
}

integer open_dialog(key avatar_id, string dialog_body, list dialog_buttons) {
    /* pad to multiples of 3 for llDialog */
    while ((llGetListLength(dialog_buttons) % 3) != 0) {
        dialog_buttons += " ";
    }
    if (Listen != 0) llListenRemove(Listen);
    Chan   = -100000 - (integer)llFrand(1000000.0);
    Listen = llListen(Chan, "", avatar_id, "");
    User   = avatar_id;
    llDialog(avatar_id, dialog_body, dialog_buttons, Chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    return TRUE;
}

/* ---------- Status text ---------- */
string build_status_report() {
    string status_text = "Collar status:\n";

    if (Locked) {
        status_text += "🔒 Locked\n";
    } else {
        status_text += "🔓 Unlocked\n";
    }

    if (TpeMode) {
        status_text += "💥 TPE Mode: ON\n";
    } else {
        status_text += "💥 TPE Mode: OFF\n";
    }

    if (OwnerKey != NULL_KEY) {
        status_text += "Owner: " + owner_label() + "\n";
    } else {
        status_text += "Owner: (unowned)\n";
    }

    integer trustee_count = llGetListLength(TrusteeKeys);
    if (trustee_count > 0) {
        status_text += "Trustees: ";
        integer trustee_idx;
        for (trustee_idx = 0; trustee_idx < trustee_count; trustee_idx++) {
            if (trustee_idx != 0) {
                status_text += ", ";
            }
            /* prefer honorific label if present, else placeholder */
            string honorific = "";
            if (trustee_idx < llGetListLength(TrusteeHonorifics)) {
                honorific = llList2String(TrusteeHonorifics, trustee_idx);
            }
            if (honorific == "") {
                honorific = "(trustee)";
            }
            status_text += honorific;
        }
        status_text += "\n";
    } else {
        status_text += "Trustees: (none)\n";
    }

    if (PublicAccess) {
        status_text += "Public Access: ON\n";
    } else {
        status_text += "Public Access: OFF\n";
    }

    return status_text;
}

integer show_menu(key avatar_id) {
    string status_report = build_status_report();
    list menu_buttons = [BTN_FILL, BTN_BACK, BTN_FILL];
    integer dialog_opened = open_dialog(avatar_id, status_report, menu_buttons);
    logd("Menu → " + (string)avatar_id + " chan=" + (string)Chan);
    return dialog_opened;
}

/* =========================== EVENTS =========================== */
default {
    state_entry() {
        cleanup_session();
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_self();
        request_settings_sync_once();
        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender_num, integer msg_num, string msg_str, key msg_id) {
        /* Heartbeat */
        if (msg_num == K_PLUGIN_PING) {
            if (json_has(msg_str, ["type"])) {
                if (llJsonGetValue(msg_str, ["type"]) == TYPE_PLUGIN_PING) {
                    if (json_has(msg_str, ["context"])) {
                        if (llJsonGetValue(msg_str, ["context"]) != PLUGIN_CONTEXT) return;
                    }
                    string pong_json = llList2Json(JSON_OBJECT, []);
                    pong_json = llJsonSetValue(pong_json, ["type"],    TYPE_PLUGIN_PONG);
                    pong_json = llJsonSetValue(pong_json, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong_json, NULL_KEY);
                }
            }
            return;
        }

        /* Settings sync */
        if (msg_num == K_SETTINGS_SYNC) {
            if (json_has(msg_str, ["type"])) {
                if (llJsonGetValue(msg_str, ["type"]) == TYPE_SETTINGS_SYNC) {
                    if (json_has(msg_str, ["kv"])) {
                        update_from_settings(llJsonGetValue(msg_str, ["kv"]));
                    }
                }
            }
            return;
        }

        /* Kernel asks this script to re-register */
        if (msg_num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg_str, ["type"])) {
                if (llJsonGetValue(msg_str, ["type"]) == TYPE_REGISTER_NOW) {
                    if (json_has(msg_str, ["script"])) {
                        if (llJsonGetValue(msg_str, ["script"]) != llGetScriptName()) return;
                    }
                    register_self();
                }
            }
            return;
        }

        /* UI start: open the status menu (no AUTH gate) */
        if (msg_num == K_PLUGIN_START) {
            if (json_has(msg_str, ["context"])) {
                if (llJsonGetValue(msg_str, ["context"]) == PLUGIN_CONTEXT) {
                    // If we don't have a cached owner display yet, (re)request it
                    if (OwnerKey != NULL_KEY && OwnerDisplay == "") {
                        request_owner_names();
                    }
                    show_menu(msg_id);
                }
            }
            return;
        }
    }

    dataserver(key query_id, string data) {
        // Display Name arrives here; legacy name too
        if (query_id == OwnerDisplayQuery) {
            OwnerDisplayQuery = NULL_KEY;
            if (data != "" && data != "???" && OwnerKey != NULL_KEY) {
                OwnerDisplay = data;
            }
        } else if (query_id == OwnerLegacyQuery) {
            OwnerLegacyQuery = NULL_KEY;
            // Only take legacy if display name didn't resolve
            if (OwnerDisplay == "" && data != "" && OwnerKey != NULL_KEY) {
                OwnerDisplay = data;
            }
        } else {
            return;
        }

        // If a user has the menu open, refresh it with the resolved name
        if (User != NULL_KEY && Listen != 0) {
            show_menu(User);
        }
    }

    listen(integer listen_chan, string speaker_name, key speaker_id, string button_msg) {
        if (listen_chan != Chan) return;
        if (speaker_id != User) return;

        if (button_msg == BTN_BACK) {
            string return_json = llList2Json(JSON_OBJECT, []);
            return_json = llJsonSetValue(return_json, ["type"],    TYPE_PLUGIN_RETURN);
            return_json = llJsonSetValue(return_json, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, return_json, speaker_id);
            cleanup_session();
            return;
        }

        /* Unknown → close quietly */
        cleanup_session();
    }

    timer() {
        cleanup_session();
    }

    changed(integer change_flags) {
        if (change_flags & CHANGED_OWNER) llResetScript();
    }
}
