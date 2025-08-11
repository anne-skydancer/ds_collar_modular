/* =============================================================
   MODULE:  ds_collar_kmod_ui.lsl
   ROLE:    Root UI (context-based, paged, safe listeners)
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Kernel ABI constants ---------- */
integer AUTH_QUERY_NUM        = 700;
integer AUTH_RESULT_NUM       = 710;
integer PLUGIN_START_NUM      = 900;
integer PLUGIN_RETURN_NUM     = 901;
integer K_PLUGIN_LIST_NUM     = 600;
integer K_PLUGIN_LIST_REQUEST = 601;

string ROOT_CONTEXT = "core_root";

integer MAX_FUNC_BTNS = 9;
string NAV_LEFT   = "<<";
string NAV_SPACER = " ";
string NAV_RIGHT  = ">>";

list g_plugins = []; // [label, context, label, context...]

key     gToucher      = NULL_KEY;
integer gListen       = 0;
integer gPage         = 0;
integer gAuthPending  = FALSE;
integer gMenuChan     = 0;

/* ---------- Helpers ---------- */
logd(string s) { if (DEBUG) llOwnerSay("[UI] " + s); }

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

list getPluginLabels() {
    list names;
    integer i;
    integer n = llGetListLength(g_plugins);
    for (i = 0; i < n; i += 2) {
        names += llList2String(g_plugins, i);
    }
    return names;
}

string contextFromLabel(string label) {
    integer idx = llListFindList(g_plugins, [label]);
    if (idx == -1) return "";
    return llList2String(g_plugins, idx + 1);
}

list buildButtonsForPage(integer page, list labels) {
    integer total = llGetListLength(labels);
    integer pages = (total + (MAX_FUNC_BTNS - 1)) / MAX_FUNC_BTNS;
    if (pages < 1) pages = 1;

    integer start = page * MAX_FUNC_BTNS;
    integer end   = start + MAX_FUNC_BTNS;
    if (end > total) end = total;

    list slice = llList2List(labels, start, end - 1);

    list buttons = [];
    if (pages > 1) {
        string left  = NAV_SPACER;
        string right = NAV_SPACER;
        if (page > 0) left = NAV_LEFT;
        if (page < pages - 1) right = NAV_RIGHT;
        buttons += [ left, NAV_SPACER, right ];
    }
    buttons += slice;
    return buttons;
}

startMenuListen(key av) {
    if (gListen) llListenRemove(gListen);
    gMenuChan = -100000 - (integer)llFrand(1000000.0);
    gListen = llListen(gMenuChan, "", av, "");
}

showRootMenu(key av, integer page) {
    list labels = getPluginLabels();
    integer total = llGetListLength(labels);
    if (total == 0) {
        llRegionSayTo(av, 0, "No plugins available.");
        return;
    }

    integer pages = (total + (MAX_FUNC_BTNS - 1)) / MAX_FUNC_BTNS;
    if (pages < 1) pages = 1;
    if (page < 0) page = pages - 1;
    if (page >= pages) page = 0;
    gPage = page;

    startMenuListen(av);
    list buttons = buildButtonsForPage(page, labels);

    string title = "• DS Collar •";
    string body  = "Select a function (Page " + (string)(page+1) + "/" + (string)pages + ")";
    llDialog(av, title + "\n" + body, buttons, gMenuChan);

    logd("Root menu to " + (string)av + " page " + (string)(page+1) + "/" + (string)pages + " chan=" + (string)gMenuChan);
}

handoffToPluginByContext(string context, key av) {
    if (context == "") return;
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], "plugin_start");
    j = llJsonSetValue(j, ["context"], context);
    llMessageLinked(LINK_SET, PLUGIN_START_NUM, j, av);
    logd("Start plugin context: " + context + " for " + (string)av);
}

/* ---------- STATES ---------- */
default {
    state_entry() {
        gPage = 0;
        g_plugins = [];
        llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY);
    }

    touch_start(integer total_number) {
        gToucher = llDetectedKey(0);
        gAuthPending = TRUE;

        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"], "acl_query");
        j = llJsonSetValue(j, ["avatar"], (string)gToucher);
        llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);

        llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY);
    }

    link_message(integer src, integer num, string msg, key id) {
        if (num == AUTH_RESULT_NUM && gAuthPending) {
            gAuthPending = FALSE;
            if (json_has(msg, ["level"])) {
                integer level = (integer)llJsonGetValue(msg, ["level"]);
                if (level >= 1) {
                    showRootMenu(gToucher, 0);
                } else {
                    llRegionSayTo(gToucher, 0, "Access denied.");
                }
            }
            return;
        }

        if (num == K_PLUGIN_LIST_NUM) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == "plugin_list") {
                g_plugins = [];
                string arr = llJsonGetValue(msg, ["plugins"]);
                list objs = llJson2List(arr);
                integer i;
                integer n = llGetListLength(objs);
                for (i = 0; i < n; i++) {
                    string o = llList2String(objs, i);
                    string label = llJsonGetValue(o, ["label"]);
                    string ctx   = llJsonGetValue(o, ["context"]);
                    if (label != JSON_INVALID && ctx != JSON_INVALID) {
                        g_plugins += [ label, ctx ];
                    }
                }
                logd("Plugin list updated (" + (string)(llGetListLength(g_plugins)/2) + ")");
            }
            return;
        }

        if (num == PLUGIN_RETURN_NUM) {
            if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == ROOT_CONTEXT) {
                showRootMenu(id, gPage);
            }
            return;
        }
    }

    listen(integer channel, string name, key id, string message) {
        if (message == NAV_LEFT) {
            showRootMenu(id, gPage - 1);
            return;
        }
        if (message == NAV_RIGHT) {
            showRootMenu(id, gPage + 1);
            return;
        }
        if (message == NAV_SPACER) {
            return;
        }
        string ctx = contextFromLabel(message);
        if (ctx != "") {
            if (gListen) llListenRemove(gListen);
            handoffToPluginByContext(ctx, id);
        }
    }

    on_rez(integer start_param) { llResetScript(); }
    changed(integer change) { if (change & CHANGED_OWNER) llResetScript(); }
}
