/* =============================================================
   TITLE: ds_collar_core.lsl (NO UI/SESSION)
   PURPOSE: Orchestrator & registry for DS Collar (no UI code)
            Delegates all user interaction, session, dialog,
            and touch handling to ds_collar_ui module.
            Fully parametric dynamic settings cache, no legacy vars.
   DATE:    2025-07-31 (UI-extracted, modular architecture, dynamic settings)
   ============================================================= */

integer DEBUG = TRUE;

//── Canonical Protocol Message Roots ───────────────────────────
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";

//── Plugin registry state ──────────────────────────────────────
list    g_plugins        = [];  // [sn,label,min_acl,ctx, ...]
list    g_plugin_queue   = [];
integer g_registering     = FALSE;
integer g_plugins_changed = FALSE;
integer g_first_boot      = TRUE;
list    g_pending_plugins = [];
integer g_loading_timer   = 0;
list g_deregister_queue   = [];
integer g_deregistering   = FALSE;
list g_reg_queue          = [];
list g_dereg_queue        = [];



//── Dynamic Settings Cache ─────────────────────────────────────
list g_setting_keys = [];
list g_setting_vals = [];

//── Link-message channels ──────────────────────────────────────
integer PLUGIN_REG_QUERY_NUM   = 500;
integer PLUGIN_REG_REPLY_NUM   = 501;
integer PLUGIN_DEREG_NUM       = 502;
integer PLUGIN_SOFT_RESET_NUM  = 503;
integer PLUGIN_ACTION_NUM      = 510;
integer AUTH_QUERY_NUM         = 700;
integer AUTH_RESULT_NUM        = 710;
integer SETTINGS_QUERY_NUM     = 800;
integer SETTINGS_SYNC_NUM      = 870;

//── Helpers for dynamic plugin adding/removing ─────────────────────────

register_plugins_begin() {
    g_reg_queue = [];
    integer n = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i;
    for (i = 0; i < n; ++i) {
        string script_name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (script_name != llGetScriptName()) {
            if (llSubStringIndex(script_name, "ds_collar_plugin_") == 0) {
                g_reg_queue += [script_name];
            }
        }
    }
    g_registering = TRUE;
    llSetTimerEvent(0.02);
}

deregister_plugins_begin() {
    g_dereg_queue = [];
    integer n = llGetListLength(g_plugins) / 4;
    integer i;
    for (i = 0; i < n; ++i) {
        // Here, we only know SN, label, acl, context -- script name is not tracked!
        // If you want to deregister by SN, you must define the message format plugins expect for deregistration.
        integer sn = llList2Integer(g_plugins, i*4 + 0);
        g_dereg_queue += [sn];
    }
    g_deregistering = TRUE;
    llSetTimerEvent(0.02);
}

remove_plugin(integer sn) {
    integer i;
    for(i=0; i<llGetListLength(g_plugins); i+=4){
        if(llList2Integer(g_plugins, i) == sn) {
            g_plugins = llDeleteSubList(g_plugins, i, i+3);
            // No break needed, continue in case of dups
        }
    }
    notify_ui_plugins();
}

process_next_registration() {
    if (llGetListLength(g_reg_queue) == 0) {
        g_registering = FALSE;
        llSetTimerEvent(0.0);
        notify_ui_plugins(); // signal UI that registry is updated
        if (DEBUG) llOwnerSay("[CORE] All plugins registered.");
        return;
    }
    string script_name = llList2String(g_reg_queue, 0);
    g_reg_queue = llDeleteSubList(g_reg_queue, 0, 0);
    llMessageLinked(LINK_THIS, PLUGIN_REG_QUERY_NUM,
        REGISTER_NOW_MSG_START + "|" + script_name, NULL_KEY);
    if (DEBUG) llOwnerSay("[CORE] Registering: " + script_name);
    llSetTimerEvent(0.02);
}

process_next_deregistration() {
    if (llGetListLength(g_dereg_queue) == 0) {
        g_deregistering = FALSE;
        llSetTimerEvent(0.0);
        if (DEBUG) llOwnerSay("[CORE] All plugins deregistered.");
        // Now trigger registration phase
        register_plugins_begin();
        return;
    }
    integer sn = llList2Integer(g_dereg_queue, 0);
    g_dereg_queue = llDeleteSubList(g_dereg_queue, 0, 0);
    // Canonical message for deregistration
    llMessageLinked(LINK_THIS, PLUGIN_DEREG_NUM, DEREGISTER_MSG_START + "|" + (string)sn, NULL_KEY);
    if (DEBUG) llOwnerSay("[CORE] Deregistering plugin SN: " + (string)sn);
    llSetTimerEvent(0.02);
}

notify_ui_plugins()
{
    // Send as: "plugin_list|sn|label|min_acl|context|sn|label|min_acl|context|..."
    list msg = [ "plugin_list" ] + g_plugins;
    llMessageLinked(LINK_SET, 600, llDumpList2String(msg, "|"), NULL_KEY);
    if (DEBUG) llOwnerSay("[CORE][DEBUG] Sent plugin_list to UI: " + llDumpList2String(msg, "|"));
}

//── Helpers for dynamic settings cache ─────────────────────────

integer idx_of_key(string key_str) {
    return llListFindList(g_setting_keys, [key_str]);
}

string get_setting_val(string key_str) {
    integer idx = idx_of_key(key_str);
    if (idx == -1) return "";
    return llList2String(g_setting_vals, idx);
}

integer get_setting_int(string key_str, integer default_val) {
    string val = get_setting_val(key_str);
    if (val == "") return default_val;
    return (integer)val;
}

key get_setting_key(string key_str) {
    string val = get_setting_val(key_str);
    if (val == "") return NULL_KEY;
    return (key)val;
}

list get_setting_list_csv(string key_str) {
    string csv = get_setting_val(key_str);
    if (csv == "") return [];
    return llParseString2List(csv, [","], []);
}

//── Plugin registry logic ──────────────────────────────────────

add_plugin(integer sn, string label, integer min_acl, string ctx) {
    g_plugin_queue += [sn, label, min_acl, ctx];
    if (!g_registering) {
        g_registering = TRUE;
        process_next_plugin();
    }
}

process_next_plugin() {
    if (llGetListLength(g_plugin_queue) == 0) {
        g_registering = FALSE;
        notify_ui_plugins();
        if(DEBUG) llOwnerSay("[CORE] All plugins registered.");
        llSetTimerEvent(0);
    } else {
        g_registering = TRUE;
        integer sn      = llList2Integer(g_plugin_queue,0);
        string label    = llList2String(g_plugin_queue,1);
        integer min_acl = llList2Integer(g_plugin_queue,2);
        string ctx      = llList2String(g_plugin_queue,3);
        integer i;
        for(i=0; i<llGetListLength(g_plugins); i+=4){
            if(llList2Integer(g_plugins, i) == sn) {
                g_plugins = llDeleteSubList(g_plugins, i, i+3);
            }
        }
        g_plugins += [sn, label, min_acl, ctx];
        g_plugin_queue = llDeleteSubList(g_plugin_queue,0,3);
        llSetTimerEvent(0.1); // controls registration pacing
    }
}

//── Default state ──────────────────────────────────────────────

default
{
    state_entry() {
        if (DEBUG) llOwnerSay("[CORE] state_entry");
        // Query ACL and settings on startup
        llMessageLinked(LINK_SET, AUTH_QUERY_NUM,
            "acl_query" + "|" + (string)llGetOwner(), NULL_KEY);
        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM,
            "get_settings", NULL_KEY);

        // Begin plugin registration
        integer n = llGetInventoryNumber(INVENTORY_SCRIPT);
        integer i;
        for (i = 0; i < n; ++i) {
            string script_name = llGetInventoryName(INVENTORY_SCRIPT,i);
            if (script_name != llGetScriptName()) {
                if (llSubStringIndex(script_name, "ds_collar_plugin_") == 0) {
                    llMessageLinked(LINK_THIS, PLUGIN_REG_QUERY_NUM, REGISTER_NOW_MSG_START + "|" + script_name, NULL_KEY);
                    if (DEBUG) llOwnerSay("[CORE] " + REGISTER_NOW_MSG_START + "|" + script_name);
                }
            }
        }
        llSetTimerEvent(1.0);
    }

    link_message(integer sn, integer num, string msg_str, key sender_id) {
        if (DEBUG) llOwnerSay("[CORE][DEBUG] link_message: sn=" + (string)sn + " num=" + (string)num + " str=" + msg_str + " id=" + (string)sender_id);

        // ───── SOFT RESET HANDLER: custom channel ─────
        if (num == PLUGIN_SOFT_RESET_NUM && msg_str == SOFT_RESET_MSG_START) {
            if (DEBUG) llOwnerSay("[CORE][DEBUG] Received core_soft_reset (503). Performing soft reset logic.");

            // 1. Clear plugin registry and queue
            g_plugins = [];
            g_plugin_queue = [];
            g_registering = FALSE;

            // 2. Re-fetch dynamic settings from settings module
            llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);

            // 3. Re-query plugin registrations (resend register_now to all plugins)
            integer n = llGetInventoryNumber(INVENTORY_SCRIPT);
            integer i;
            for (i = 0; i < n; ++i) {
                string script_name = llGetInventoryName(INVENTORY_SCRIPT,i);
                if (script_name != llGetScriptName()) {
                    if (llSubStringIndex(script_name, "ds_collar_plugin_") == 0) {
                        llMessageLinked(LINK_THIS, PLUGIN_REG_QUERY_NUM, REGISTER_NOW_MSG_START + "|" + script_name, NULL_KEY);
                        if (DEBUG) llOwnerSay("[CORE][SOFT_RESET] " + REGISTER_NOW_MSG_START + "|" + script_name);
                    }
                }
            }

            // 4. Optionally, reset other runtime state if any (g_first_boot, etc.)
            g_first_boot = FALSE;
            // 5. End handler
            return;
        }
        // ──────────────────────────────────────────────

        // Handle SETTINGS_SYNC_NUM (usually 870)
        if (num == SETTINGS_SYNC_NUM) {
            if (llSubStringIndex(msg_str, SETTINGS_SYNC_MSG_START + "|") == 0) {
                list p = llParseStringKeepNulls(msg_str, ["|"], []);
                g_setting_keys = [];
                g_setting_vals = [];
                integer len = llGetListLength(p);
                integer i;
                for (i = 1; i < len; i++) {
                    string kv = llList2String(p, i);
                    integer sep_idx = llSubStringIndex(kv, "=");
                    if (sep_idx != -1) {
                        string key_str = llGetSubString(kv, 0, sep_idx - 1);
                        string val_str = llGetSubString(kv, sep_idx + 1, -1);
                        g_setting_keys += [key_str];
                        g_setting_vals += [val_str];
                    } else {
                        if (DEBUG) llOwnerSay("[CORE][DEBUG] Malformed key=val skipped: " + kv);
                    }
                }
                if (DEBUG) llOwnerSay("[CORE][DEBUG] Settings synced dynamically: keys=" + llDumpList2String(g_setting_keys, ","));
            }
            return;
        }

        // --- PLUGIN REGISTRATION HANDSHAKE ---
        if (num == PLUGIN_REG_QUERY_NUM) {
            list parts = llParseStringKeepNulls(msg_str, ["|"], []);
            if (llGetListLength(parts) >= 2 && llList2String(parts, 0) == REGISTER_NOW_MSG_START) {
                if (DEBUG) llOwnerSay("[CORE][DEBUG] Received register_now for " + llList2String(parts, 1));
            } else {
                if (DEBUG) llOwnerSay("[CORE][DEBUG] Unexpected msg on PLUGIN_REG_QUERY_NUM: " + msg_str);
            }
            return;
        }

        // Handle PLUGIN_REG_REPLY_NUM (501): register|sn|label|min_acl|context
        if (num == PLUGIN_REG_REPLY_NUM) {
            list p = llParseStringKeepNulls(msg_str, ["|"], []);
            if (llGetListLength(p) >= 5 && llList2String(p, 0) == REGISTER_MSG_START) {
                add_plugin(
                    (integer)llList2String(p, 1),
                    llList2String(p, 2),
                    (integer)llList2String(p, 3),
                    llList2String(p, 4)
                );
                if (DEBUG) llOwnerSay("[CORE][DEBUG] Registered plugin: sn=" + llList2String(p, 1) + " label=" + llList2String(p, 2));
            } else {
                if (DEBUG) llOwnerSay("[CORE][DEBUG] Unexpected msg on PLUGIN_REG_REPLY_NUM: " + msg_str);
            }
            return;
        }

        // Plugin deregistration
        if (num == PLUGIN_DEREG_NUM) {
            list p = llParseStringKeepNulls(msg_str, ["|"], []);
            if (llGetListLength(p) >= 2 && llList2String(p, 0) == DEREGISTER_MSG_START) {
                integer rsn = (integer)llList2String(p, 1);
                remove_plugin(rsn);
                if (DEBUG) llOwnerSay("[CORE][DEBUG] Deregistered plugin sn=" + llList2String(p, 1));
            }
            return;
        }

        // Only log for core-specific plugin channels
        if (DEBUG && (num == PLUGIN_REG_QUERY_NUM || num == PLUGIN_REG_REPLY_NUM || num == PLUGIN_DEREG_NUM || num == PLUGIN_SOFT_RESET_NUM)) {
            llOwnerSay("[CORE][DEBUG] Unknown or unhandled msg: num=" + (string)num + " str=" + msg_str);
        }
        // (Relay menu requests/dispatch from UI to plugin could be added here.)
    }

    timer() {
        if (g_registering) {
            process_next_plugin();
        }
        if (g_plugins_changed) {
            g_plugins_changed = FALSE;
            llMessageLinked(LINK_SET, PLUGIN_SOFT_RESET_NUM,
                SOFT_RESET_MSG_START, NULL_KEY);
            if (DEBUG) llOwnerSay("[CORE] Plugins changed, soft reset: requesting plugin re-registration.");
            deregister_plugins_begin();
            register_plugins_begin();
        }
        if (g_first_boot && llGetTime() > 5.0) {
            g_first_boot = FALSE;
        }
    }

    changed(integer change) {
        if (change & CHANGED_INVENTORY) {
            if (DEBUG) llOwnerSay ("[CORE][DEBUG] Inventory changed. Refreshing plugins.");
            deregister_plugins_begin();
            g_plugins = [];
            register_plugins_begin();
            return;
        }
            
        if (change & CHANGED_OWNER) {
            llOwnerSay("[CORE] Owner changed; resetting script.");
            llResetScript();
        }
    }
}
