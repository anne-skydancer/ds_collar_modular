/* =============================================================
   MODULE: ds_collar_ui.lsl (Canonical, Multi-User, Session-Aware)
   PURPOSE: Robust UI handler for DS Collar Core 1.4+
   AUTHOR:  [Your Name or Project]
   DATE:    2025-08-01
   ============================================================= */

integer DEBUG = TRUE;

// --- Protocol/Channel constants ---
string PLUGIN_LIST_MSG = "plugin_list";
string SHOW_MENU_MSG   = "show_menu";
string ROOT_LABEL      = "Main";
string ROOT_CONTEXT    = "core_root";

// Channels
integer UI_ACL_QUERY_NUM  = 700;
integer UI_ACL_RESULT_NUM = 710;
integer PLUGIN_LIST_NUM   = 600;
integer UI_SHOW_MENU_NUM  = 601;
integer UI_DIALOG_NUM     = 602;

// --- Menu/Session constants ---
integer DIALOG_TIMEOUT = 180;
integer PAGE_SIZE = 6; // plugin entries per page

// --- State ---
list g_plugin_data     = []; // [sn, label, min_acl, context, ...]
list g_plugin_labels   = [];
list g_plugin_contexts = [];

// --- Multi-user session table ---
// Each entry: [avatar, page, menu_chan, listen_handle, timestamp]
list g_sessions;

// --- Helpers ---
rebuild_plugin_menus() {
    g_plugin_labels = [ ROOT_LABEL ];
    g_plugin_contexts = [ ROOT_CONTEXT ];
    integer n = llGetListLength(g_plugin_data) / 4;
    integer i;
    for (i = 0; i < n; ++i) {
        string label   = llList2String(g_plugin_data, i*4 + 1);
        string context = llList2String(g_plugin_data, i*4 + 3);
        g_plugin_labels   += [label];
        g_plugin_contexts += [context];
    }
    if (DEBUG) llOwnerSay("[UI] Rebuilt plugin menus: " +
        llDumpList2String(g_plugin_labels, ",") + " (contexts: " +
        llDumpList2String(g_plugin_contexts, ",") + ")");
}

list get_page_buttons(integer page) {
    list result = [];
    integer total_plugins = llGetListLength(g_plugin_labels) - 1;
    integer total_pages = (total_plugins + PAGE_SIZE - 1) / PAGE_SIZE;
    if (total_plugins < 1) total_pages = 1;

    // Navigation row: ["<<", "~", ">>"]
    if (page > 0) result += ["<<"]; else result += ["~"];
    result += ["~"];
    if ((page + 1) < total_pages) result += [">>"]; else result += ["~"];

    // Add plugin labels (PAGE_SIZE per page)
    integer start = page * PAGE_SIZE + 1;
    integer i;
    for (i = 0; i < PAGE_SIZE; ++i) {
        integer plugin_idx = start + i;
        if (plugin_idx <= total_plugins)
            result += [llList2String(g_plugin_labels, plugin_idx)];
    }
    return result;
}

// --- Session Management ---
integer session_idx(key av) {
    integer n = llGetListLength(g_sessions);
    integer i = 0;
    while (i < n) {
        if (llList2Key(g_sessions, i) == av)
            return i;
        i += 5;
    }
    return -1;
}

session_set(key av, integer page, integer chan, integer listen_handle) {
    integer now = llGetUnixTime();
    integer i = session_idx(av);
    if (i != -1) {
        integer old_listen = llList2Integer(g_sessions, i+3);
        if (old_listen != 0) llListenRemove(old_listen);
        g_sessions = llDeleteSubList(g_sessions, i, i+4);
    }
    g_sessions += [av, page, chan, listen_handle, now + DIALOG_TIMEOUT];
}

session_clear(key av) {
    integer i = session_idx(av);
    if (i != -1) {
        integer old_listen = llList2Integer(g_sessions, i+3);
        if (old_listen != 0) llListenRemove(old_listen);
        g_sessions = llDeleteSubList(g_sessions, i, i+4);
    }
}

list session_get(key av) {
    integer i = session_idx(av);
    if (i != -1) return llList2List(g_sessions, i, i+4);
    return [];
}

// --- Main Menu Handler ---
show_main_menu(key av, integer page) {
    list btns = get_page_buttons(page);
    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    integer lh = llListen(menu_chan, "", av, "");
    session_set(av, page, menu_chan, lh);
    llDialog(av, "Select function:", btns, menu_chan);
    if (DEBUG) llOwnerSay("[UI] Main menu to " + (string)av + " page=" + (string)page + " chan=" + (string)menu_chan);
}

// --- Plugin Dialog Forwarder ---
show_plugin_dialog(key av, string msg, list btns) {
    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    integer lh = llListen(menu_chan, "", av, "");
    session_set(av, 0, menu_chan, lh);
    llDialog(av, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[UI] Plugin dialog to " + (string)av + " chan=" + (string)menu_chan);
}

// --- Timer for session expiry ---
expire_sessions() {
    integer now = llGetUnixTime();
    integer i = 0;
    while (i < llGetListLength(g_sessions)) {
        key av = llList2Key(g_sessions, i);
        integer expiry = llList2Integer(g_sessions, i+4);
        if (now > expiry) {
            session_clear(av);
        } else {
            i += 5;
        }
    }
}

// --- Main Event Loop ---
default
{
    state_entry() {
        g_sessions = [];
        if (DEBUG) llOwnerSay("[UI] Canonical UI module ready.");
        llMessageLinked(LINK_SET, PLUGIN_LIST_NUM, PLUGIN_LIST_MSG, NULL_KEY);
        }

    touch_start(integer total_number) {
        key toucher = llDetectedKey(0);
        llMessageLinked(LINK_SET, UI_ACL_QUERY_NUM,
            "acl_query|" + (string)toucher, NULL_KEY);
        // The ACL_RESULT will open menu for this user
    }

    link_message(integer sender, integer num, string str, key id)
    {
        // Update plugin list from core
        if (num == PLUGIN_LIST_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == PLUGIN_LIST_MSG) {
                g_plugin_data = llDeleteSubList(parts, 0, 0);
                rebuild_plugin_menus();
                if (DEBUG) llOwnerSay("[UI] Updated plugin menu: " + llDumpList2String(g_plugin_data, "|"));
            }
            return;
        }
        // Handle ACL result for touch
        if (num == UI_ACL_RESULT_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            string cmd = llList2String(parts, 0);
            key av = (key)llList2String(parts, 1);
            integer acl = (integer)llList2String(parts, 2);

            if (cmd == "acl_result") {
                if (acl >= 1 && acl <= 4) {
                    show_main_menu(av, 0);
                } else {
                    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
                    integer lh = llListen(menu_chan, "", av, "");
                    session_set(av, 0, menu_chan, lh);
                    llDialog(av, "You do not have access.", ["OK"], menu_chan);
                }
            }
            return;
        }
        // Handle plugin dialog requests (forwards to user)
        if (num == UI_DIALOG_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 5) {
                key avatar = (key)llList2String(parts, 1);
                string dialog_msg = llUnescapeURL(llList2String(parts, 2));
                list btns = llParseString2List(llList2String(parts, 3), [","], []);
                show_plugin_dialog(avatar, dialog_msg, btns);
            }
            return;
        }
        // Handle main/root menu requests (plugin or self)
        if (num == UI_SHOW_MENU_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 3) {
                string ctx = llList2String(parts, 1);
                key avatar = (key)llList2String(parts, 2);
                if (ctx == ROOT_CONTEXT) {
                    list s = session_get(avatar);
                    integer page = 0;
                    if (llGetListLength(s) == 5) page = llList2Integer(s, 1);
                    show_main_menu(avatar, page);
                    return;
                }
            }
        }
    }

    listen(integer channel, string name, key id, string msg) {
        list sess = session_get(id); // session_get returns [user, page, chan, listen, expiry]
        if (llGetListLength(sess) < 3) return;
        integer page = llList2Integer(sess, 1);
        integer total_plugins = llGetListLength(g_plugin_labels) - 1;
        integer total_pages = (total_plugins + PAGE_SIZE - 1) / PAGE_SIZE;
        if (total_plugins < 1) total_pages = 1;

        // Navigation
        if (msg == "<<") {
            if (page > 0) page--;
            show_main_menu(id, page); // Start new session, update listen
            return;
        }
        if (msg == ">>") {
            if ((page + 1) < total_pages) page++;
            show_main_menu(id, page); // Start new session, update listen
            return;
        }
        if (msg == "~") {
            session_clear(id); // End menu for this user
            return;
        }

        // Plugin label clicked: map to context for this page
        integer start = page * PAGE_SIZE + 1;
        integer i;
        integer idx = -1;
        for (i = 0; i < PAGE_SIZE; ++i) {
            integer plugin_idx = start + i;
            if (plugin_idx <= total_plugins) {
                if (llList2String(g_plugin_labels, plugin_idx) == msg && idx == -1) {
                    idx = plugin_idx;
                    i = PAGE_SIZE; // forcibly exit loop (LSL workaround for break)
                }
            }
        }
        if (idx != -1) {
            string ctx = llList2String(g_plugin_contexts, idx);
            string menu_req = SHOW_MENU_MSG + "|" + ctx + "|" + (string)id + "|0";
            llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
        }
        session_clear(id); // Only after plugin selection
    }

    timer() {
        expire_sessions();
    }
    
    changed(integer change) {
        // If scripts, notecards, etc. change, or object is rezzed
        if (change & CHANGED_INVENTORY) {
            if (DEBUG) llOwnerSay("[UI] Inventory or rez changed. Requesting plugin list refresh.");
            // Option 1: If core always broadcasts plugin_list on inventory change,
            // this may be enough; otherwise, send explicit request if you support it.
            // Option 2: Reset internal plugin menu, will be rebuilt on next event.
            g_plugin_data = [];
            g_plugin_labels = [];
            g_plugin_contexts = [];
            // Optionally trigger a UI refresh (core should broadcast plugin_list again)
        }
    }
}


