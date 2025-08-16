/* =============================================================
   MODULE:  ds_collar_kmod_ui.lsl  (AUTH-DRIVEN, exact ACL flow)
   ROLE:    Root UI (context-based, paged, safe listeners)
   POLICY:  Defer to AUTH; UI filters by:
            - Deny only ACL -1
            - ACL 0 (wearer in TPE): only min_acl==0, SOS gated by policy_sos_only
            - ACL 1: non-wearers only min_acl==1; wearer uses ACL 2 bucket
            - ACL 2..5: normal bucket (≤ level)
            - For ACL ≥1, SOS is always hidden
   ============================================================= */

integer DEBUG = FALSE;

/* ---------- Strings ---------- */
string TYPE_PLUGIN_LIST   = "plugin_list";
string TYPE_PLUGIN_RETURN = "plugin_return";
string TYPE_START_UI      = "plugin_start";
string MSG_ACL_QUERY      = "acl_query";
string MSG_ACL_RESULT     = "acl_result";

string BTN_NAV_LEFT  = "<<";
string BTN_NAV_GAP   = " ";
string BTN_NAV_RIGHT = ">>";

/* ---------- Link numbers ---------- */
integer AUTH_QUERY_NUM        = 700;
integer AUTH_RESULT_NUM       = 710;
integer K_PLUGIN_LIST_NUM     = 600;
integer K_PLUGIN_LIST_REQUEST = 601;
integer K_PLUGIN_START_NUM    = 900;
integer K_PLUGIN_RETURN_NUM   = 901;

string ROOT_CONTEXT = "core_root";

/* ---------- UI layout ---------- */
integer MAX_FUNC_BTNS = 9;
float   TOUCH_RANGE_M = 5.0;

/* ---------- State ---------- */
list    g_pluginsAll = [];  // [label, context, min_acl, ...]
list    g_plugins    = [];  // filtered [label, context, ...]
list    g_pageMap    = [];

key     gToucher     = NULL_KEY;
integer gListen      = 0;
integer gPage        = 0;
integer gMenuChan    = 0;
integer dialogOpen   = FALSE;

/* ACL + policy from AUTH */
integer gAclLevel            = -1;
integer gAclReady            = FALSE;
integer gListReady           = FALSE;
integer gIsWearer            = FALSE;
integer gPolicySosOnly       = FALSE;
/* Kept for compatibility; not used in this exact policy */
integer gPolicyPublicOnly    = FALSE;

integer logd(string m) { if (DEBUG) llOwnerSay("[DEBUG][UI] " + m); return 0; }

/* ---------- Helpers ---------- */
integer isSosContext(string ctx) {
    if (llSubStringIndex(ctx, "core_sos") == 0) return TRUE;
    return FALSE;
}

integer isWithinRange(key av) {
    if (av == NULL_KEY) return FALSE;
    vector wearerPos = llGetPos();
    list d = llGetObjectDetails(av, [OBJECT_POS]);
    vector avPos = llList2Vector(d, 0);
    if (avPos == ZERO_VECTOR) return FALSE;
    float dist = llVecDist(wearerPos, avPos);
    if (DEBUG) llOwnerSay("[DEBUG][UI] Proximity: " + (string)dist);
    if (dist <= TOUCH_RANGE_M) return TRUE;
    return FALSE;
}

/* STRICT parsing: require min_acl 0..5 */
parsePluginList(string jsonStr) {
    g_pluginsAll = [];
    integer i = 0;
    while (llJsonValueType(jsonStr, ["plugins", i]) != JSON_INVALID) {
        string label   = llJsonGetValue(jsonStr, ["plugins", i, "label"]);
        string context = llJsonGetValue(jsonStr, ["plugins", i, "context"]);
        string mv      = llJsonGetValue(jsonStr, ["plugins", i, "min_acl"]);

        if (label == "" || context == "") {
            if (DEBUG) llOwnerSay("[DEBUG][UI] Skipping plugin row: empty label/context");
        } else if (mv == JSON_INVALID) {
            if (DEBUG) llOwnerSay("[DEBUG][UI] Skipping plugin row: missing min_acl");
        } else {
            integer minAcl = (integer)mv;
            if (minAcl < 0 || minAcl > 5) {
                if (DEBUG) llOwnerSay("[DEBUG][UI] Skipping plugin row: min_acl out of range (" + (string)minAcl + ")");
            } else {
                g_pluginsAll += [label, context, minAcl];
            }
        }
        i = i + 1;
    }
}

/* ---------- Exact filtering policy ----------

Deny only ACL -1 (done in link_message).

ACL 0 (wearer in TPE):
  - include only min_acl == 0
  - SOS gating:
      * wearer + policy_sos_only==1 → ONLY core_sos
      * wearer + policy_sos_only==0 → EXCLUDE core_sos
      * non-wearers → EXCLUDE core_sos

ACL 1:
  - non-wearers → ONLY min_acl == 1
  - wearer      → ACL 2 bucket (min_acl <= 2)

ACL 2..5:
  - normal bucket (min_acl <= level)

For ACL >= 1: SOS always hidden (non-wearers never see SOS anyway).
*/
list filterPlugins() {
    list out = [];
    integer i = 0;
    integer n = llGetListLength(g_pluginsAll);

    while (i < n) {
        string  label   = llList2String (g_pluginsAll, i);
        string  context = llList2String (g_pluginsAll, i + 1);
        integer minAcl  = llList2Integer(g_pluginsAll, i + 2);

        integer include = FALSE;

        /* Base include by ACL level */
        if (gAclLevel <= -1) {
            include = FALSE; /* blacklist (already denied earlier) */
        } else if (gAclLevel == 0) {
            if (minAcl == 0) include = TRUE;
        } else if (gAclLevel == 1) {
            if (gIsWearer) {
                /* wearer at ACL 1 sees ACL 2 bucket */
                if (minAcl <= 2) include = TRUE;
            } else {
                if (minAcl == 1) include = TRUE;
            }
        } else {
            /* ACL 2..5 */
            if (minAcl <= gAclLevel) include = TRUE;
        }

        if (include) {
            /* SOS gating */
            integer sos = isSosContext(context);

            if (gAclLevel == 0) {
                /* ACL 0: only case where SOS may be shown */
                if (gIsWearer) {
                    if (gPolicySosOnly) {
                        if (!sos) include = FALSE;   /* ONLY core_sos */
                    } else {
                        if (sos) include = FALSE;    /* exclude SOS */
                    }
                } else {
                    if (sos) include = FALSE;        /* outsiders never see SOS */
                }
            } else {
                /* ACL >=1: SOS is always hidden */
                if (sos) include = FALSE;
            }
        }

        if (include) {
            out += [label, context];
        }

        i = i + 3;
    }

    return out;
}

integer totalLabelCount() { return llGetListLength(g_plugins) / 2; }

integer totalPagesForList() {
    integer totalLabels = totalLabelCount();
    integer pages = 0;
    if ((totalLabels % MAX_FUNC_BTNS) == 0) pages = totalLabels / MAX_FUNC_BTNS;
    else pages = (totalLabels / MAX_FUNC_BTNS) + 1;
    if (pages < 1) pages = 1;
    return pages;
}

list buildButtonsForPage(integer page) {
    g_pageMap = [];
    list buttons = [];
    integer totalLabels = totalLabelCount();
    integer totalPages = totalPagesForList();

    if (page < 0) page = 0;
    if (page >= totalPages) page = totalPages - 1;

    integer stride = 2;
    integer startPair = page * MAX_FUNC_BTNS;
    integer endPair = startPair + MAX_FUNC_BTNS - 1;
    if (endPair >= totalLabels) endPair = totalLabels - 1;

    integer startIdx = startPair * stride;
    integer endIdx = (endPair * stride) + 1;

    list pagePairs = [];
    if (startIdx <= endIdx && endIdx < llGetListLength(g_plugins)) {
        pagePairs = llList2List(g_plugins, startIdx, endIdx);
    }

    integer i = 0;
    integer len = llGetListLength(pagePairs);
    while (i < len) {
        string label = llList2String(pagePairs, i);
        string ctx   = llList2String(pagePairs, i + 1);
        buttons += [label];
        g_pageMap += [label, ctx];
        i = i + 2;
    }

    if (totalPages > 1) {
        string left  = BTN_NAV_GAP;
        string right = BTN_NAV_GAP;
        if (page > 0) left = BTN_NAV_LEFT;
        if (page < totalPages - 1) right = BTN_NAV_RIGHT;
        buttons = [left, BTN_NAV_GAP, right] + buttons;
    }
    return buttons;
}

openDialog(key av, string title, string body, list buttons) {
    if (gListen != 0) llListenRemove(gListen);
    dialogOpen = TRUE;
    gMenuChan = -100000 - (integer)llFrand(1000000.0);
    gListen = llListen(gMenuChan, "", av, "");
    llDialog(av, title + "\n" + body, buttons, gMenuChan);
}

closeDialog() {
    if (gListen != 0) {
        llListenRemove(gListen);
        gListen = 0;
    }
    dialogOpen = FALSE;
}

showRootMenu(key av, integer page) {
    if (totalLabelCount() <= 0) {
        llRegionSayTo(av, 0, "No plugins available.");
        return;
    }
    integer pages = totalPagesForList();
    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;
    gPage = page;

    list buttons = buildButtonsForPage(gPage);
    string body = "Select a function (Page " + (string)(gPage + 1) + "/" + (string)pages + ")";
    openDialog(av, "• DS Collar •", body, buttons);
}

navigatePage(key av, integer newPage) {
    integer pages = totalPagesForList();
    if (pages <= 0) pages = 1;
    if (newPage < 0) newPage = pages - 1;
    if (newPage >= pages) newPage = 0;
    gPage = newPage;

    list buttons = buildButtonsForPage(gPage);
    string body = "Select a function (Page " + (string)(gPage + 1) + "/" + (string)pages + ")";
    openDialog(av, "• DS Collar •", body, buttons);
}

startPlugin(string context, key av) {
    string msg = llList2Json(JSON_OBJECT, []);
    msg = llJsonSetValue(msg, ["type"], TYPE_START_UI);
    msg = llJsonSetValue(msg, ["context"], context);
    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, msg, av);
    logd("Starting plugin context: " + context + " for " + (string)av);
}

queryAclAsync(key user) {
    string msg = llList2Json(JSON_OBJECT, []);
    msg = llJsonSetValue(msg, ["type"], MSG_ACL_QUERY);
    msg = llJsonSetValue(msg, ["avatar"], (string)user);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, msg, NULL_KEY);
}

fetchPluginListAsync() { llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY); }

/* ==================== Events ==================== */
default {
    state_entry() {
        gToucher = NULL_KEY;
        gPage = 0;
        g_pluginsAll = [];
        g_plugins = [];
        g_pageMap = [];
        gAclLevel = -1;
        gAclReady = FALSE;
        gListReady = FALSE;
        dialogOpen = FALSE;

        if (gListen != 0) { llListenRemove(gListen); gListen = 0; }
    }

    on_rez(integer sp) { llResetScript(); }

    changed(integer change) { if (change & CHANGED_OWNER) llResetScript(); }

    touch_start(integer tn) {
        if (dialogOpen) closeDialog();

        gToucher = llDetectedKey(0);

        if (!isWithinRange(gToucher)) {
            llRegionSayTo(gToucher, 0, "You are too far from the wearer to use the collar (max 5 m).");
            return;
        }

        gAclReady = FALSE;
        gListReady = FALSE;
        gAclLevel = -1;
        gIsWearer = FALSE;
        gPolicySosOnly = FALSE;
        gPolicyPublicOnly = FALSE;

        queryAclAsync(gToucher);
        fetchPluginListAsync();
    }

    link_message(integer src, integer num, string msg, key id) {
        if (num == AUTH_RESULT_NUM) {
            if (llJsonValueType(msg, ["type"]) == JSON_INVALID) return;
            if (llJsonGetValue(msg, ["type"]) != MSG_ACL_RESULT) return;

            key av = (key)llJsonGetValue(msg, ["avatar"]);
            if (av == NULL_KEY) return;
            if (av != gToucher) {
                if (DEBUG) llOwnerSay("[DEBUG][UI] Ignored ACL for " + (string)av + " (current toucher " + (string)gToucher + ")");
                return;
            }

            if (llJsonValueType(msg, ["level"]) == JSON_INVALID) return;
            gAclLevel = (integer)llJsonGetValue(msg, ["level"]);

            /* optional policy flags from AUTH */
            gIsWearer = FALSE;
            if (llJsonValueType(msg, ["is_wearer"]) != JSON_INVALID) gIsWearer = (integer)llJsonGetValue(msg, ["is_wearer"]);
            gPolicySosOnly = FALSE;
            if (llJsonValueType(msg, ["policy_sos_only"]) != JSON_INVALID) gPolicySosOnly = (integer)llJsonGetValue(msg, ["policy_sos_only"]);
            gPolicyPublicOnly = FALSE; /* kept for compatibility; not used here */
            if (llJsonValueType(msg, ["policy_public_only"]) != JSON_INVALID) gPolicyPublicOnly = (integer)llJsonGetValue(msg, ["policy_public_only"]);

            /* Hard deny ONLY for blacklist (-1). ACL 0 is allowed (gated in filter) */
            if (gAclLevel < 0) {
                closeDialog();
                llRegionSayTo(gToucher, 0, "Access denied.");
                gToucher = NULL_KEY;
                gAclReady = FALSE;
                gListReady = FALSE;
                return;
            }

            gAclReady = TRUE;

            if (gAclReady && gListReady) {
                g_plugins = filterPlugins();
                if (llGetListLength(g_plugins) == 0) {
                    llRegionSayTo(gToucher, 0, "No plugins available.");
                    gAclReady = FALSE;
                    gListReady = FALSE;
                    return;
                }
                showRootMenu(gToucher, 0);
                gAclReady = FALSE;
                gListReady = FALSE;
            }
            return;
        }

        if (num == K_PLUGIN_LIST_NUM) {
            if (llJsonValueType(msg, ["type"]) == JSON_INVALID) return;
            if (llJsonGetValue(msg, ["type"]) != TYPE_PLUGIN_LIST) return;

            parsePluginList(msg);
            gListReady = TRUE;

            if (gAclReady && gListReady) {
                g_plugins = filterPlugins();
                if (llGetListLength(g_plugins) == 0) {
                    llRegionSayTo(gToucher, 0, "No plugins available.");
                    gAclReady = FALSE;
                    gListReady = FALSE;
                    return;
                }
                showRootMenu(gToucher, 0);
                gAclReady = FALSE;
                gListReady = FALSE;
            }
            return;
        }

        if (num == K_PLUGIN_RETURN_NUM) {
            if (llJsonValueType(msg, ["context"]) != JSON_INVALID) {
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx == ROOT_CONTEXT) showRootMenu(gToucher, gPage);
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string b) {
        if (chan != gMenuChan) return;

        if (!isWithinRange(id)) {
            closeDialog();
            llRegionSayTo(id, 0, "You moved too far from the wearer to use the collar (max 5 m).");
            return;
        }

        /* close the root dialog before acting so it doesn’t re-open */
        closeDialog();

        if (b == BTN_NAV_LEFT)  { navigatePage(id, gPage - 1); return; }
        if (b == BTN_NAV_RIGHT) { navigatePage(id, gPage + 1); return; }
        if (b == BTN_NAV_GAP)   { showRootMenu(id, gPage);     return; }

        integer idx = llListFindList(g_pageMap, [b]);
        if (idx != -1) {
            string context = llList2String(g_pageMap, idx + 1);
            startPlugin(context, id);
            return;
        }

        showRootMenu(id, gPage);
    }
}
