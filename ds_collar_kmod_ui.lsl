/* =============================================================
   MODULE:  ds_collar_kmod_ui.lsl
   ROLE:    Root UI (context-based, paged, safe listeners)
   NOTES:   ACL-filtered plugin list, waits for both ACL and plugins
            + TPE gate by context (wearer-only):
              - Wearer + TPE OFF: exclude contexts starting with "core_sos"
              - Wearer + TPE ON : include only contexts starting with "core_sos"
              - Non-wearers    : always exclude "core_sos"
            + Proximity gate:
              - Only allow use within 5 meters of the wearer

   PATCH SUMMARY (showstopper fix):
   - Gate ACL results by avatar: only accept acl_result for the *current toucher* (gToucher).
   - Close any open dialog when a *new* person touches to avoid cross-session confusion.
   - Extra debug and safety guards; feature behavior unchanged otherwise.
   ============================================================= */

integer DEBUG = TRUE;

// === Global String Constants ===
string TYPE_REGISTER      = "register";
string TYPE_REGISTER_NOW  = "register_now";
string TYPE_PLUGIN_LIST   = "plugin_list";
string TYPE_PLUGIN_RETURN = "plugin_return";
string TYPE_START_UI      = "plugin_start";
string TYPE_ACL_QUERY     = "acl_query";

/* Settings protocol */
string MSG_SETTINGS_GET   = "settings_get";
string MSG_SETTINGS_SYNC  = "settings_sync";
string KEY_TPE_MODE       = "tpe_mode";

string MSG_ACL_RESULT     = "acl_result";

string BTN_NAV_LEFT  = "<<";
string BTN_NAV_GAP   = " ";
string BTN_NAV_RIGHT = ">>";

/* Link numbers (match kernel/auth/settings) */
integer AUTH_QUERY_NUM        = 700;
integer AUTH_RESULT_NUM       = 710;
integer K_PLUGIN_LIST_NUM     = 600;
integer K_PLUGIN_LIST_REQUEST = 601;
integer K_PLUGIN_START_NUM    = 900;
integer K_PLUGIN_RETURN_NUM   = 901;

integer SETTINGS_QUERY_NUM    = 800;
integer SETTINGS_SYNC_NUM     = 870;

string ROOT_CONTEXT = "core_root";

integer MAX_FUNC_BTNS = 9;

/* --- Proximity (meters) --- */
float   TOUCH_RANGE_M = 5.0;

// === State variables ===
list    g_pluginsAll = [];  // [label, context, min_acl, ...]
list    g_plugins    = [];  // Filtered [label, context, ...]
list    g_pageMap    = [];  // Current page [label, context, ...]
key     gToucher     = NULL_KEY;
integer gListen      = 0;
integer gPage        = 0;
integer gMenuChan    = 0;

integer gAclLevel    = -1;
integer gAclReady    = FALSE;
integer gListReady   = FALSE;
integer dialogOpen   = FALSE;

/* Settings cache */
integer gTpeMode     = FALSE;   // 0/1 from settings
integer gSettingsSeen= FALSE;

// === Helper Functions ===
logd(string message) { if (DEBUG) llOwnerSay("[DEBUG][UI] " + message); }

/* Context helper: true if context starts with "core_sos" */
integer isSosContext(string ctx) {
    if (llSubStringIndex(ctx, "core_sos") == 0) return TRUE;
    return FALSE;
}

/* Proximity helper: is avatar within TOUCH_RANGE_M of wearer? */
integer isWithinRange(key av) {
    if (av == NULL_KEY) return FALSE;

    /* Wearer position: for attachments llGetPos() is the wearer's position */
    vector wearerPos = llGetPos();

    /* Toucher (agent) position via llGetObjectDetails */
    list d = llGetObjectDetails(av, [OBJECT_POS]);
    vector avPos = llList2Vector(d, 0);

    /* If agent not in region, OBJECT_POS often returns ZERO_VECTOR; deny in that case */
    if (avPos == ZERO_VECTOR) {
        if (DEBUG) llOwnerSay("[DEBUG][UI] Proximity: avatar pos unknown → deny");
        return FALSE;
    }

    float dist = llVecDist(wearerPos, avPos);
    if (DEBUG) llOwnerSay("[DEBUG][UI] Proximity: dist=" + (string)dist);
    if (dist <= TOUCH_RANGE_M) return TRUE;
    return FALSE;
}

parsePluginList(string jsonStr) {
    g_pluginsAll = [];
    integer i = 0;
    while (llJsonValueType(jsonStr, ["plugins", i]) != JSON_INVALID) {
        string label   = llJsonGetValue(jsonStr, ["plugins", i, "label"]);
        string context = llJsonGetValue(jsonStr, ["plugins", i, "context"]);
        integer minAcl = (integer)llJsonGetValue(jsonStr, ["plugins", i, "min_acl"]);
        if (label != "" && context != "") {
            g_pluginsAll += [label, context, minAcl];
        }
        i = i + 1;
    }
}

/* ---------- ACL-based Filtering with wearer-only TPE gate ----------
   - Always enforce ACL: include only if (acl >= min_acl)
   - If toucher IS the wearer (llGetOwner()):
       * TPE ON  : include ONLY contexts starting with "core_sos"
       * TPE OFF : EXCLUDE contexts starting with "core_sos"
   - If toucher is NOT the wearer:
       * Always EXCLUDE "core_sos" (normal menu)
*/
list filterPluginsByAcl(integer acl) {
    list filtered = [];
    integer i = 0;
    integer n = llGetListLength(g_pluginsAll);

    key wearer = llGetOwner();
    integer isWearer = FALSE;
    if (gToucher == wearer) isWearer = TRUE;

    while (i < n) {
        string  label   = llList2String (g_pluginsAll, i);
        string  context = llList2String (g_pluginsAll, i + 1);
        integer minAcl  = llList2Integer(g_pluginsAll, i + 2);

        if (acl >= minAcl) {
            integer sos = isSosContext(context);

            if (isWearer) {
                if (gTpeMode) {
                    if (sos) filtered += [label, context];
                } else {
                    if (!sos) filtered += [label, context];
                }
            } else {
                if (!sos) filtered += [label, context];
            }
        }
        i = i + 3;
    }
    return filtered;
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

/* Pass the toucher key as the link_message id */
startPlugin(string context, key av) {
    string msg = llList2Json(JSON_OBJECT, []);
    msg = llJsonSetValue(msg, ["type"], TYPE_START_UI);
    msg = llJsonSetValue(msg, ["context"], context);
    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, msg, av);
    logd("Starting plugin context: " + context + " for " + (string)av);
}

queryAclAsync(key user) {
    string msg = llList2Json(JSON_OBJECT, []);
    msg = llJsonSetValue(msg, ["type"], TYPE_ACL_QUERY);
    msg = llJsonSetValue(msg, ["avatar"], (string)user);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, msg, NULL_KEY);
}

fetchPluginListAsync() { llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY); }

// === Events ===
default {
    state_entry() {
        gPage = 0;
        g_pluginsAll = [];
        g_plugins = [];
        g_pageMap = [];
        gAclLevel = -1;
        gAclReady = FALSE;
        gListReady = FALSE;
        dialogOpen = FALSE;
        if (gListen != 0) {
            llListenRemove(gListen);
            gListen = 0;
        }

        /* Ask settings at boot so we learn TPE state */
        string j0 = llList2Json(JSON_OBJECT, []);
        j0 = llJsonSetValue(j0, ["type"], MSG_SETTINGS_GET);
        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, j0, NULL_KEY);
    }

    on_rez(integer sp) { llResetScript(); }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    touch_start(integer tn) {
        /* Close any prior dialog: new touch starts a new session */
        if (dialogOpen) closeDialog();

        gToucher = llDetectedKey(0);
        if (DEBUG) {
            key wearer = llGetOwner();
            string who = "non-wearer";
            if (gToucher == wearer) who = "wearer";
            llOwnerSay("[DEBUG][UI] Touch by " + (string)gToucher + " (" + who + ")");
        }

        /* Proximity gate: require toucher within 5m of wearer */
        if (!isWithinRange(gToucher)) {
            llRegionSayTo(gToucher, 0, "You are too far from the wearer to use the collar (max 5 m).");
            return;
        }

        gAclReady = FALSE;
        gListReady = FALSE;
        queryAclAsync(gToucher);
        fetchPluginListAsync();

        /* If settings not yet seen, request again (non-blocking) */
        if (!gSettingsSeen) {
            string js = llList2Json(JSON_OBJECT, []);
            js = llJsonSetValue(js, ["type"], MSG_SETTINGS_GET);
            llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, js, NULL_KEY);
        }
    }

    link_message(integer src, integer num, string msg, key id) {
        if (num == SETTINGS_SYNC_NUM) {
            if (llJsonValueType(msg, ["type"]) != JSON_INVALID) {
                if (llJsonGetValue(msg, ["type"]) == MSG_SETTINGS_SYNC) {
                    if (llJsonValueType(msg, ["kv"]) != JSON_INVALID) {
                        string kv = llJsonGetValue(msg, ["kv"]);
                        if (llJsonValueType(kv, [KEY_TPE_MODE]) != JSON_INVALID) {
                            gTpeMode = (integer)llJsonGetValue(kv, [KEY_TPE_MODE]);
                            gSettingsSeen = TRUE;
                            logd("Settings sync: tpe_mode=" + (string)gTpeMode);

                            if (gAclReady && gListReady) {
                                g_plugins = filterPluginsByAcl(gAclLevel);
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
                        }
                    }
                }
            }
            return;
        }

        /* --- SHOWSTOPPER FIX: accept only ACL for the *current toucher* --- */
        if (num == AUTH_RESULT_NUM) {
            /* Must be a proper acl_result */
            if (llJsonValueType(msg, ["type"]) == JSON_INVALID) {
                logd("Ignored ACL result: missing 'type'");
                return;
            }
            if (llJsonGetValue(msg, ["type"]) != MSG_ACL_RESULT) {
                logd("Ignored ACL result: wrong 'type'");
                return;
            }

            /* Must target our current toucher */
            if (llJsonValueType(msg, ["avatar"]) == JSON_INVALID) {
                logd("Ignored ACL result: missing 'avatar'");
                return;
            }
            key av = (key)llJsonGetValue(msg, ["avatar"]);
            if (av == NULL_KEY) {
                logd("Ignored ACL result: NULL_KEY avatar");
                return;
            }
            if (av != gToucher) {
                if (DEBUG) llOwnerSay("[DEBUG][UI] Ignored ACL for " + (string)av + " (current toucher is " + (string)gToucher + ")");
                return;
            }

            /* Level must be present and valid */
            if (llJsonValueType(msg, ["level"]) == JSON_INVALID) {
                logd("Error: 'level' key not found.");
                return;
            }
            integer level = (integer)llJsonGetValue(msg, ["level"]);
            if (level < -1 || level > 5 || level == -1) {
                llRegionSayTo(gToucher, 0, "Access denied.");
                gAclReady = FALSE;
                gListReady = FALSE;
                return;
            }

            gAclLevel = level;
            gAclReady = TRUE;

            if (gAclReady && gListReady) {
                g_plugins = filterPluginsByAcl(gAclLevel);
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
            if (llJsonValueType(msg, ["type"]) != JSON_INVALID) {
                string type = llJsonGetValue(msg, ["type"]);
                if (type == TYPE_PLUGIN_LIST) {
                    parsePluginList(msg);
                    gListReady = TRUE;

                    if (gAclReady && gListReady) {
                        g_plugins = filterPluginsByAcl(gAclLevel);
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
                } else {
                    logd("Error: Plugin list type mismatch.");
                }
            } else {
                logd("Error: 'type' key not found in plugin list.");
            }
            return;
        }

        if (num == K_PLUGIN_RETURN_NUM) {
            if (llJsonValueType(msg, ["context"]) != JSON_INVALID) {
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx == ROOT_CONTEXT) {
                    /* Return to root menu for the *current toucher* */
                    showRootMenu(gToucher, gPage);
                }
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string msg) {
        if (chan != gMenuChan) return;

        /* Proximity re-check on every click */
        if (!isWithinRange(id)) {
            closeDialog();
            llRegionSayTo(id, 0, "You moved too far from the wearer to use the collar (max 5 m).");
            return;
        }

        /* Close listen for current dialog before action */
        closeDialog();

        if (msg == BTN_NAV_LEFT) {
            navigatePage(id, gPage - 1);
            return;
        }
        if (msg == BTN_NAV_RIGHT) {
            navigatePage(id, gPage + 1);
            return;
        }
        if (msg == BTN_NAV_GAP) {
            showRootMenu(id, gPage);
            return;
        }

        /* Map label to context */
        integer idx = llListFindList(g_pageMap, [msg]);
        if (idx != -1) {
            string context = llList2String(g_pageMap, idx + 1);
            startPlugin(context, id); /* pass the toucher key */
            return;
        }

        /* If unknown, just re-show current menu */
        showRootMenu(id, gPage);
    }
}
