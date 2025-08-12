/* =============================================================
   MODULE:  ds_collar_kmod_ui.lsl
   ROLE:    Root UI (context-based, paged, safe listeners)
   NOTES:   ACL-filtered plugin list, waits for both ACL and plugins
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Global String Constants (Magic Words) ---------- */
string TYPE_REGISTER           = "register";
string TYPE_REGISTER_NOW       = "register_now";
string TYPE_PLUGIN_LIST        = "plugin_list";
string TYPE_PLUGIN_RETURN      = "plugin_return";
string TYPE_START_UI           = "plugin_start";
string TYPE_ACL_QUERY          = "acl_query";

string BTN_NAV_LEFT            = "<<";
string BTN_NAV_GAP             = " ";
string BTN_NAV_RIGHT           = ">>";

/* ---------- Link message channels ---------- */
integer AUTH_QUERY_NUM         = 700;
integer AUTH_RESULT_NUM        = 710;

integer K_PLUGIN_LIST_NUM      = 600;
integer K_PLUGIN_LIST_REQUEST  = 601;

integer K_PLUGIN_START_NUM     = 900;
integer K_PLUGIN_RETURN_NUM    = 901;

string ROOT_CONTEXT            = "core_root";

/* ---------- UI constants ---------- */
integer MAX_FUNC_BTNS          = 9;

/* --- Strict LV0 allowlist --- */
list LV0_ALLOWED_CONTEXTS = [ "core_sos" ]; // only these show at level 0

/* ---------- State ---------- */
list    g_pluginsAll = [];  // [label, context, min_acl, label, context, min_acl, ...]
list    g_plugins    = [];  // Filtered for current toucher
key     gToucher     = NULL_KEY;
integer gListen      = 0;
integer gPage        = 0;
integer gAuthPending = FALSE;
integer gMenuChan    = 0;

integer gAclLevel    = -1; // Last known ACL for toucher
integer gAclReady    = FALSE;
integer gListReady   = FALSE;

/* ---------- Helpers ---------- */
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

logd(string s) { if (DEBUG) llOwnerSay("[UI] " + s); }

list getPluginLabels() {
    list names = [];
    integer i = 0;
    integer n = llGetListLength(g_plugins);
    while (i < n) {
        names += llList2String(g_plugins, i);
        i += 2;
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
        string left  = BTN_NAV_GAP;
        string right = BTN_NAV_GAP;
        if (page > 0) left = BTN_NAV_LEFT;
        if (page < pages - 1) right = BTN_NAV_RIGHT;
        buttons += [ left, BTN_NAV_GAP, right ];
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

    logd("Root menu to " + (string)av + " page " + (string)(page+1) + "/" + (string)pages);
}

handoffToPluginByContext(string context, key av) {
    if (context == "") return;
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_START_UI);
    j = llJsonSetValue(j, ["context"], context);
    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, j, av);
    logd("Start plugin context: " + context + " for " + (string)av);
}

/* ---------- ACL-based Filtering ---------- */
list filterPluginsByAcl(integer acl) {
    list filtered = [];
    integer i = 0;
    integer n = llGetListLength(g_pluginsAll);
    while (i < n) {
        string label   = llList2String(g_pluginsAll, i);
        string context = llList2String(g_pluginsAll, i + 1);
        integer minAcl = (integer)llList2String(g_pluginsAll, i + 2);

        if (acl == -1) {
            // blacklisted: no entries, ever
        }
        else if (acl == 0) {
            // LV0: only explicit allowlist
            if (llListFindList(LV0_ALLOWED_CONTEXTS, [context]) != -1) {
                filtered += [label, context];
            }
        }
        else if (acl == 1) {
            // LV1: only exact level-1 plugins
            if (minAcl == 1) {
                filtered += [label, context];
            }
        }
        else if (acl >= 2) {
            // LV2+: cumulative up to their level
            if (minAcl <= acl) {
                filtered += [label, context];
            }
        }
        i += 3;
    }
    return filtered;
}

/* ---------- Show menu only when ready ---------- */
tryShowMenu() {
    if (gAclReady && gListReady) {
        g_plugins = filterPluginsByAcl(gAclLevel);
        
        if (llGetListLength(g_plugins) == 0) {
            llRegionSayTo(gToucher, 0, "Access Denied.");
            gAclReady = FALSE;
            gListReady = FALSE;
            return;
        }
                    
        showRootMenu(gToucher, 0);
        gAclReady = FALSE;
        gListReady = FALSE;
    }
}

/* ---------- STATES ---------- */
default {
    state_entry() {
        gPage = 0;
        g_pluginsAll = [];
    }

    touch_start(integer total_number) {
        gToucher = llDetectedKey(0);
        gAclReady = FALSE;
        gListReady = FALSE;

        // Ask ACL
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"], TYPE_ACL_QUERY);
        j = llJsonSetValue(j, ["avatar"], (string)gToucher);
        llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);

        // Ask plugin list
        llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY);
    }

    link_message(integer src, integer num, string msg, key id) {
        if (num == AUTH_RESULT_NUM) {
            if (json_has(msg, ["level"])) {
                gAclLevel = (integer)llJsonGetValue(msg, ["level"]);
                if (gAclLevel < -1 || gAclLevel > 5 || gAclLevel == -1) {
                    llRegionSayTo(gToucher, 0, "Access denied.");
                    return;
                }
                gAclReady = TRUE;
                tryShowMenu();
            }
            return;
        }

        if (num == K_PLUGIN_LIST_NUM) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_LIST) {
                g_pluginsAll = [];
                string arr = llJsonGetValue(msg, ["plugins"]);
                list objs = llJson2List(arr);
                integer i = 0;
                integer n = llGetListLength(objs);
                while (i < n) {
                    string o = llList2String(objs, i);
                    string label  = llJsonGetValue(o, ["label"]);
                    string ctx    = llJsonGetValue(o, ["context"]);
                    string minAcl = llJsonGetValue(o, ["min_acl"]);
                    if (label != JSON_INVALID && ctx != JSON_INVALID && minAcl != JSON_INVALID) {
                        g_pluginsAll += [label, ctx, minAcl];
                    }
                    i += 1;
                }
                gListReady = TRUE;
                tryShowMenu();
            }
            return;
        }

        if (num == K_PLUGIN_RETURN_NUM) {
            if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == ROOT_CONTEXT) {
                showRootMenu(id, gPage);
            }
            return;
        }
    }

    listen(integer channel, string name, key id, string message) {
        if (message == BTN_NAV_LEFT) {
            showRootMenu(id, gPage - 1);
            return;
        }
        if (message == BTN_NAV_RIGHT) {
            showRootMenu(id, gPage + 1);
            return;
        }
        if (message == BTN_NAV_GAP) {
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
