/* =============================================================
   MODULE:  ds_collar_kmod_ui.lsl
   ROLE:    Root UI (context-based, paged, safe listeners)
   NOTES:   Uses shared protocol "magic words" constants
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Global String Constants (Magic Words) ---------- */
string TYPE_REGISTER           = "register";
string TYPE_REGISTER_NOW       = "register_now";
string TYPE_PLUGIN_LIST        = "plugin_list";
string TYPE_PLUGIN_RETURN      = "plugin_return";
string TYPE_START_UI           = "plugin_start";   // what plugins expect from UI
string TYPE_ACL_QUERY          = "acl_query";

string BTN_NAV_LEFT            = "<<";
string BTN_NAV_GAP             = " ";
string BTN_NAV_RIGHT           = ">>";

/* ---------- Link message channels ---------- */
integer AUTH_QUERY_NUM         = 700;   // UI  → ACL   : {"type":"acl_query","avatar":"<key>"}
integer AUTH_RESULT_NUM        = 710;   // ACL → UI    : {"type":"acl_result","avatar":"<key>","level":<int>}

integer K_PLUGIN_LIST_NUM      = 600;   // Kernel → UI : {"type":"plugin_list","plugins":[{...}]}
integer K_PLUGIN_LIST_REQUEST  = 601;   // UI → Kernel : (empty) ask snapshot

integer K_PLUGIN_START_NUM     = 900;   // UI → Plugin : {"type":"plugin_start","context":"core_x"}
integer K_PLUGIN_RETURN_NUM    = 901;   // Plugin → UI : {"type":"plugin_return","context":"core_root"}

string ROOT_CONTEXT            = "core_root";

/* ---------- UI constants ---------- */
integer MAX_FUNC_BTNS          = 9;     // buttons per page for functions (rest is used by nav row)

/* ---------- State ---------- */
list    g_plugins = [];                 // [label, context, label, context, ...]
key     gToucher  = NULL_KEY;
integer gListen   = 0;
integer gPage     = 0;
integer gAuthPending = FALSE;
integer gMenuChan = 0;

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

    logd("Root menu to " + (string)av + " page " + (string)(page+1) + "/" + (string)pages + " chan=" + (string)gMenuChan);
}

handoffToPluginByContext(string context, key av) {
    if (context == "") return;
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_START_UI);
    j = llJsonSetValue(j, ["context"], context);
    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, j, av);
    logd("Start plugin context: " + context + " for " + (string)av);
}

/* ---------- STATES ---------- */
default {
    state_entry() {
        gPage = 0;
        g_plugins = [];
        // Prime with a fresh list
        llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY);
    }

    /* ---- Touch kicks off ACL check + list snapshot ---- */
    touch_start(integer total_number) {
        gToucher = llDetectedKey(0);
        gAuthPending = TRUE;

        // Ask ACL
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"], TYPE_ACL_QUERY);
        j = llJsonSetValue(j, ["avatar"], (string)gToucher);
        llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);

        // Ask kernel for latest plugin list snapshot
        llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY);
    }

    link_message(integer src, integer num, string msg, key id) {
        // ACL result
        if (num == AUTH_RESULT_NUM && gAuthPending) {
            gAuthPending = FALSE;
            if (json_has(msg, ["level"])) {
                integer level = (integer)llJsonGetValue(msg, ["level"]);
                if (level >= 0) {
                    showRootMenu(gToucher, 0);
                } else {
                    llRegionSayTo(gToucher, 0, "Access denied.");
                }
            }
            return;
        }

        // Kernel → UI: plugin list snapshot
        if (num == K_PLUGIN_LIST_NUM) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_LIST) {
                g_plugins = [];
                string arr = llJsonGetValue(msg, ["plugins"]);
                list objs = llJson2List(arr);
                integer i = 0;
                integer n = llGetListLength(objs);
                while (i < n) {
                    string o = llList2String(objs, i);
                    string label = llJsonGetValue(o, ["label"]);
                    string ctx   = llJsonGetValue(o, ["context"]);
                    if (label != JSON_INVALID && ctx != JSON_INVALID) {
                        g_plugins += [ label, ctx ];
                    }
                    i += 1;
                }
                logd("Plugin list updated (" + (string)(llGetListLength(g_plugins)/2) + ")");
            }
            return;
        }

        // Plugin → UI: return to root
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
