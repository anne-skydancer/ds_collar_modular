/* =============================================================
   TITLE: ds_collar_core.lsl
   PURPOSE: Orchestrator; UI + plugin registration for DS Collar
            (delegates ACL to ds_collar_auth.lsl and
             settings to ds_collar_settings.lsl)
   DATE:    2025-07-28
   ============================================================= */

integer DEBUG = TRUE;

//── Plugin registry state ───────────────────────────────────────
list    g_plugins       = [];  // [sn,label,min_acl,ctx, ...]
list    g_plugin_queue  = [];
integer g_registering   = FALSE;
integer g_first_boot    = TRUE;

//── Session state (menus + pending ACL) ─────────────────────────
list    g_sessions      = [];  
// each session: [av, page, csv, expire, ctx, param, step, menucsv, chan, listen_handle]

//── Dialog timeout ──────────────────────────────────────────────
float   dialog_timeout  = 180.0;

//── Cached settings (populated by ds_collar_settings) ────────────
integer S_locked             = FALSE;
key     S_owner_key          = NULL_KEY;
string  S_owner_hon          = "";
key     S_trustee1_key       = NULL_KEY;
string  S_trustee1_hon       = "";
key     S_trustee2_key       = NULL_KEY;
string  S_trustee2_hon       = "";
key     S_trustee3_key       = NULL_KEY;
string  S_trustee3_hon       = "";
key     S_trustee4_key       = NULL_KEY;
string  S_trustee4_hon       = "";
integer S_relay_mode         = FALSE;
integer S_public_mode        = FALSE;
list    S_rlv_restrictions   = [];
string  S_current_animation  = "";

//── Per-touch ACL result cache ──────────────────────────────────
// We only ever care about the most recent touch.
integer P_acl_level         = 5;

//── Link-message channels ────────────────────────────────────────
// Auth module
integer AUTH_QUERY_NUM      = 700; // "acl_query|<agent>"
integer AUTH_RESULT_NUM     = 710; // "acl_result|<agent>|<level>"
// Settings module
integer SETTINGS_QUERY_NUM  = 750; // "get_settings"
integer SETTINGS_SYNC_NUM   = 770; // "settings_sync|<lock>|<owner_key>|<owner_hon>|<t1_key>|<t1_hon>|<t2_key>|<t2_hon>|<t3_key>|<t3_hon>|<t4_key>|<t4_hon>|<relay>|<public>|<rlv_csv>|<anim>"

//── Helpers ──────────────────────────────────────────────────────
// Index of a session by avatar key
integer s_idx(key av) {
    return llListFindList(g_sessions, [av]);
}

// Create or replace a session
sess_set(key av, integer page, string csv, float exp,
         string ctx, string param, string step,
         string menucsv, integer chan) {
    integer i = s_idx(av);
    if (i != -1) {
        // remove old session (10 fields)
        llListenRemove(llList2Integer(g_sessions, i+9));
        g_sessions = llDeleteSubList(g_sessions, i, i+9);
    }
    integer lh = llListen(chan, "", av, "");
    g_sessions += [av, page, csv, exp, ctx, param, step, menucsv, chan, lh];
    return TRUE;
}

// Clear a session
sess_clear(key av) {
    integer i = s_idx(av);
    if (i != -1) {
        llListenRemove(llList2Integer(g_sessions, i+9));
        g_sessions = llDeleteSubList(g_sessions, i, i+9);
    }
    return TRUE;
}

// Get session fields
list sess_get(key av) {
    integer i = s_idx(av);
    if (i != -1) return llList2List(g_sessions, i, i+9);
    return [];
}

//── Random channel generator ────────────────────────────────────
integer new_chan() {
    // use a random negative channel
    return (integer)(-1000000.0 * llFrand(1.0) - 1.0);
}

//── Menu builders ────────────────────────────────────────────────
list core_btns()  { return ["Status","RLV","Apps","Access"]; }
list core_ctxs()  { return ["status","rlv","apps","access"]; }

// Show main menu (after ACL OK)
show_main_menu(key av, integer chan, integer acl) {
    list btns = core_btns();
    list ctxs = core_ctxs();

    // Lock/Unlock button from settings cache
    if (acl == 1) {
        if (S_locked) {
            btns += ["Unlock"];  ctxs += ["unlock"];
        } else {
            btns += ["Lock"];    ctxs += ["lock"];
        }
    }

    // Plugin buttons
    integer i;
    for (i = 0; i < llGetListLength(g_plugins); i += 4) {
        integer min_acl = llList2Integer(g_plugins, i+2);
        if (acl <= min_acl) {
            btns += [ llList2String(g_plugins, i+1) ];
            ctxs += [ llList2String(g_plugins, i+3) + "|" +
                      (string)llList2Integer(g_plugins, i) ];
        }
    }

    // pad to multiple of 3
    while (llGetListLength(btns) % 3 != 0) btns += " ";

    // set session and show   
    sess_set(av, 0, "", llGetUnixTime() + dialog_timeout,
             "main","", "", llDumpList2String(ctxs, ","), chan);

    if (DEBUG) llOwnerSay("[CORE] show_main_menu → " +
                         (string)av + " chan=" + (string)chan +
                         " btns=" + llDumpList2String(btns,","));

    llDialog(av, "Select an option:", btns, chan);
}

// Show status dialog, using settings cache
show_status(key av, integer chan) {
    string t = "";

    // Owner
    if (S_owner_key != NULL_KEY) {
        t += "Owner: " + S_owner_hon + " " +
             llKey2Name(S_owner_key) + "\n";
    } else {
        t += "Collar is unowned.\n";
    }

    // Public
    t += "Public: ";
    if (S_public_mode) t += "ENABLED\n"; else t += "DISABLED\n";

    // Locked
    t += "Locked: ";
    if (S_locked) t += "YES\n"; else t += "NO\n";

    llDialog(av, t, [" ","OK"," "], chan);
}

// Show lock/unlock prompt
show_lock_dialog(key av, integer chan) {
    string txt;
    list buttons;
    if (S_locked) {
        txt = "The collar is LOCKED.\nUnlock it?";
        buttons = ["Unlock"," ","Cancel"];
    } else {
        txt = "The collar is UNLOCKED.\nLock it?";
        buttons = ["Lock"," ","Cancel"];
    }
    while (llGetListLength(buttons) % 3 != 0) buttons += " ";
    sess_set(av,0,"", llGetUnixTime()+dialog_timeout,
             "lock_toggle","","","", chan);
    llDialog(av, txt, buttons, chan);
}

// Apply plugin registration
add_plugin(integer sn, string label, integer min_acl, string ctx) {
    integer old = llGetListLength(g_plugins) / 4;
    integer i;
    for (i = 0; i < llGetListLength(g_plugins); i+=4) {
        if (llList2Integer(g_plugins,i) == sn) {
            g_plugins = llDeleteSubList(g_plugins,i,i+3);
        }
    }
    g_plugins += [sn,label, min_acl, ctx];
}

// Process plugin queue (unchanged)
process_next_plugin() {
    if (llGetListLength(g_plugin_queue) == 0) {
        g_registering = FALSE;
        llSetTimerEvent(0);
        return;
    }
    g_registering = TRUE;
    integer sn      = llList2Integer(g_plugin_queue,0);
    string label    = llList2String(g_plugin_queue,1);
    integer min_acl = llList2Integer(g_plugin_queue,2);
    string ctx      = llList2String(g_plugin_queue,3);

    add_plugin(sn,label,min_acl,ctx);
    if (DEBUG) llOwnerSay("[CORE] Registered plugin: " + label);

    g_plugin_queue = llDeleteSubList(g_plugin_queue,0,3);
    llSetTimerEvent(0.1);
}

//── Default state ────────────────────────────────────────────────
default {
    state_entry() {
        if (DEBUG) llOwnerSay("[CORE] state_entry");
        // Ask auth and settings modules for their state
        llMessageLinked(LINK_SET, AUTH_QUERY_NUM,
                        "acl_query" + "|" + (string)llGetOwner(), NULL_KEY);
        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM,
                        "get_settings", NULL_KEY);

        // Begin plugin registration
        integer n = llGetInventoryNumber(INVENTORY_SCRIPT);
        integer i;
        for (i = 0; i < n; ++i) {
            string script = llGetInventoryName(INVENTORY_SCRIPT,i);
            if (script != llGetScriptName()) {
                llMessageLinked(LINK_SET, 500,
                    "register_now" + "|" + script, NULL_KEY);
                if (DEBUG) llOwnerSay("[CORE] register_now|" + script);
            }
        }
        llSetTimerEvent(1.0);
    }

    touch_start(integer total_number) {
        key toucher = llDetectedKey(0);
        // request ACL for toucher
        integer chan = new_chan();
        sess_set(toucher,0,"", llGetUnixTime()+dialog_timeout,
                 "pending_acl","","","", chan);
        llMessageLinked(LINK_SET, AUTH_QUERY_NUM,
                        "acl_query" + "|" + (string)toucher, NULL_KEY);
    }

    link_message(integer sn, integer num, string str, key id) {
        // 1) Auth result?
        if (num == AUTH_RESULT_NUM && llSubStringIndex(str,"acl_result|")==0) {
            list p = llParseStringKeepNulls(str, ["|"], []);
            key av   = (key)llList2String(p,1);
            integer lvl = (integer)llAtoi(llList2String(p,2));
            // find pending session
            integer i = s_idx(av);
            if (i != -1 && llList2String(g_sessions,i+4) == "pending_acl") {
                integer chan = llList2Integer(g_sessions,i+8);
                sess_clear(av);
                // if denied or public-denied
                if (lvl == 5 ||
                    (lvl == 4 && S_public_mode == FALSE)) {
                    llDialog(av, "This collar is restricted.",
                             [" ","OK"," "], chan);
                }
                else {
                    show_main_menu(av, chan, lvl);
                }
            }
            return;
        }

        // 2) Settings sync?
        if (num == SETTINGS_SYNC_NUM && llSubStringIndex(str,"settings_sync|")==0) {
            list p = llParseStringKeepNulls(str, ["|"], []);
            S_locked              = (integer)llAtoi(llList2String(p,1));
            S_owner_key           = (key)llList2String(p,2);
            S_owner_hon           = llList2String(p,3);
            S_trustee1_key        = (key)llList2String(p,4);
            S_trustee1_hon        = llList2String(p,5);
            S_trustee2_key        = (key)llList2String(p,6);
            S_trustee2_hon        = llList2String(p,7);
            S_trustee3_key        = (key)llList2String(p,8);
            S_trustee3_hon        = llList2String(p,9);
            S_trustee4_key        = (key)llList2String(p,10);
            S_trustee4_hon        = llList2String(p,11);
            S_relay_mode          = (integer)llAtoi(llList2String(p,12));
            S_public_mode         = (integer)llAtoi(llList2String(p,13));
            // parse RLV restrictions
            string csv            = llList2String(p,14);
            if (csv == "") {
                S_rlv_restrictions = [];
            } else {
                S_rlv_restrictions = llParseString2List(csv,[","],[]);
            }
            S_current_animation   = llList2String(p,15);
            if (DEBUG) llOwnerSay("[CORE] settings synced.");
            return;
        }

        // 3) Plugin registration and relay handling (unchanged)
        if (num == 501) {
            // plugin->core register
            list p = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(p)>=5 && llList2String(p,0)=="register") {
                add_plugin(
                    (integer)llList2String(p,1),
                    llList2String(p,2),
                    (integer)llList2String(p,3),
                    llList2String(p,4)
                );
            }
            return;
        }
        else if (num == 502) {
            list p = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(p)>=2 && llList2String(p,0)=="unregister") {
                integer rsn = (integer)llList2String(p,1);
                // remove plugin
                integer i;
                for (i = 0; i < llGetListLength(g_plugins); i += 4) {
                    if (llList2Integer(g_plugins,i) == rsn) {
                        g_plugins = llDeleteSubList(g_plugins,i,i+3);
                        break;
                    }
                }
            }
            return;
        }
        else if (num == 530 && str == "relay_load") {
            // ignore relay for now
        }
    }

    listen(integer chan, string name, key id, string msg) {
        // handle UI button clicks just like before
        list s = sess_get(id);
        if (llGetListLength(s) == 0) return;
        integer ctx_page = llList2Integer(s,1);
        string ctx      = llList2String(s,4);
        string menucsv  = llList2String(s,7);
        integer listen_chan = llList2Integer(s,8);

        if (chan != listen_chan) return;

        // MAIN menu
        if (ctx == "main") {
            list opts = llParseString2List(menucsv, [","], []);
            integer sel = llListFindList(opts, [msg]);
            if (sel == -1) return;
            string act = llList2String(opts, sel);

            if (act == "status") {
                show_status(id, chan);
                sess_clear(id);
                return;
            }
            if (act == "rlv") {
                // call plugin via link_message 510
                llMessageLinked(LINK_THIS, 510, "rlv|" + (string)id + "|" + (string)chan, NULL_KEY);
                sess_clear(id);
                return;
            }
            if (act == "apps") {
                llMessageLinked(LINK_THIS, 510, "apps|" + (string)id + "|" + (string)chan, NULL_KEY);
                sess_clear(id);
                return;
            }
            if (act == "access") {
                llMessageLinked(LINK_THIS, 510, "access|" + (string)id + "|" + (string)chan, NULL_KEY);
                sess_clear(id);
                return;
            }
            if (act == "lock" || act == "unlock") {
                show_lock_dialog(id, chan);
                sess_clear(id);
                return;
            }
            // plugin action
            llMessageLinked(LINK_THIS, 510, act + "|" + (string)id + "|" + (string)chan, NULL_KEY);
            sess_clear(id);
        }
        // LOCK TOGGLE confirm
        else if (ctx == "lock_toggle") {
            if (msg == "Lock") {
                // ask settings to persist lock
                llMessageLinked(LINK_SET, 751, "set_lock" + "|" + "1", NULL_KEY);
            }
            else if (msg == "Unlock") {
                llMessageLinked(LINK_SET, 751, "set_lock" + "|" + "0", NULL_KEY);
            }
            sess_clear(id);
        }
    }

    timer() {
        // Process plugin reg queue
        if (g_registering) {
            process_next_plugin();
        }
        // drop expired sessions
        integer now = llGetUnixTime();
        integer i = 0;
        while (i < llGetListLength(g_sessions)) {
            if (now > llList2Float(g_sessions, i+3)) {
                sess_clear(llList2Key(g_sessions, i));
            } else {
                i += 10;
            }
        }
        // end first boot
        if (g_first_boot && llGetTime() > 5.0) {
            g_first_boot = FALSE;
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[CORE] Owner changed; resetting script.");
            llResetScript();
        }
    }
}
