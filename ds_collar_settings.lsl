/* =============================================================
   MODULE: ds_collar_settings.lsl (Dynamic key-value settings)
   PURPOSE: Fully dynamic, extensible persistent settings storage
            for DS Collar, with key-value sync and update.
   DATE:    2025-07-31 (No legacy fixed keys, full dynamic KV, parametric protocol)
   ============================================================= */

integer DEBUG = TRUE;

//── Protocol message constants ───────────────────────────────
string SETTINGS_GET_MSG         = "get_settings";
string SETTINGS_SYNC_MSG_START  = "settings_sync";
string SETTINGS_SET_PREFIX      = "set_";

//── Dynamic storage: parallel lists for keys and values ──────
list g_keys   = [];  // setting keys as strings
list g_values = [];  // corresponding setting values as strings

//── Message numbers (only these are fixed) ───────────────────
integer SETTINGS_QUERY_NUM = 800;  // "get_settings", "set_*"
integer SETTINGS_SYNC_NUM  = 870;  // "settings_sync|key=val|key=val|..."

//── Helper: get index of setting_key, or -1 if not found ─────
integer idx_of_key(string setting_key) {
    return llListFindList(g_keys, [setting_key]);
}

//── Helper: set or update a setting_key-value pair ───────────
set_key_val(string setting_key, string setting_val) {
    integer idx = idx_of_key(setting_key);
    if (idx == -1) {
        g_keys   += [setting_key];
        g_values += [setting_val];
    } else {
        g_values = llListReplaceList(g_values, [setting_val], idx, idx);
    }
}

//── Helper: get value for a setting_key, or empty string if not found ─
string get_val(string setting_key) {
    integer idx = idx_of_key(setting_key);
    if (idx == -1) return "";
    return llList2String(g_values, idx);
}

//── Compose full sync message: "settings_sync|key=val|key=val|..." ────
string build_sync_msg() {
    integer count = llGetListLength(g_keys);
    string msg = SETTINGS_SYNC_MSG_START;
    integer i;
    for (i = 0; i < count; i++) {
        string setting_key = llList2String(g_keys, i);
        string setting_val = llList2String(g_values, i);
        msg += "|" + setting_key + "=" + setting_val;
    }
    return msg;
}

//── Broadcast full sync message ───────────────────────────────
broadcast_settings_sync() {
    string msg = build_sync_msg();
    llMessageLinked(LINK_SET, SETTINGS_SYNC_NUM, msg, NULL_KEY);
    if (DEBUG) llOwnerSay("[SETTINGS] [DEBUG] sync: " + msg);
}

default {
    state_entry() {
        if (DEBUG) llOwnerSay("[SETTINGS] [DEBUG] module ready.");
        broadcast_settings_sync();
    }

    link_message(integer sender, integer num, string str, key id) {
        // Only handle our intended channels
        if (num == SETTINGS_QUERY_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            string cmd = llList2String(parts, 0);

            if (cmd == SETTINGS_GET_MSG) {
                broadcast_settings_sync();
                return;
            }

            // Dynamic set command: format "set_<key>|<value>"
            if (llSubStringIndex(cmd, SETTINGS_SET_PREFIX) == 0 && llGetListLength(parts) >= 2) {
                string setting_key = llGetSubString(cmd, llStringLength(SETTINGS_SET_PREFIX), -1); // strip "set_"
                string setting_val = llList2String(parts, 1);
                set_key_val(setting_key, setting_val);
                if (DEBUG) llOwnerSay("[SETTINGS] [DEBUG] set key: " + setting_key + " = " + setting_val);
                // Broadcast after each set
                broadcast_settings_sync();
                return;
            }
            // Only log unknown commands on our own channel
            if (DEBUG) llOwnerSay("[SETTINGS] [DEBUG] Unknown cmd: " + cmd);
        }
    }
}
