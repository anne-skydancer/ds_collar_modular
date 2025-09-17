/* =============================================================
   ds_collar_kmod_ui_core.lsl — UI Controller (no llDialog here)
   - ACL + registry filter, paging, plugin schema parsing
   - Sends compact render requests to the View
   - Receives clicks from the View and routes actions
   - No confirmation manager here (moved to View)
   - May not use ternary syntax (unsupported in LSL)
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-CORE] " + s); return 0; }

/* ---------- External ABI (unchanged for plugins) ---------- */
string TYPE_PLUGIN_LIST   = "plugin_list";
integer K_PLUGIN_LIST_NUM      = 600;
integer K_PLUGIN_LIST_REQUEST  = 601;

integer K_UI_QUERY             = 620;  /* core → plugin */
integer K_UI_SCHEMA            = 621;  /* plugin → core */
integer K_UI_ACTION            = 922;  /* core → plugin */

integer K_UI_CONFIRM           = 930;  /* plugin → core (forward to view) */
integer K_UI_CONFIRM_RESULT    = 931;  /* view → plugin (unchanged) */
integer K_UI_CANCEL            = 932;  /* plugin → core (forward to view) */

/* ACL bridge */
integer K_ACLF_QUERY           = 640;  /* core → ACLF */
integer K_ACLF_REPLY           = 641;  /* ACLF → core */

/* Legacy return for old kernels (optional) */
integer K_PLUGIN_RETURN_NUM    = 901;
string  ROOT_CONTEXT           = "core_root";

/* ---------- Internal Core↔View link ABI ---------- */
/* Core → View: show or close a dialog */
integer K_VIEW_SHOW            = 960;  /* {"t":"show","to":"<key>","title":"...","body":"...","btn":["a","b",...]} */
integer K_VIEW_CLOSE           = 961;  /* {"t":"close"} */
/* View → Core: button clicked */
integer K_VIEW_CLICK           = 962;  /* {"t":"click","label":"..."} ; id carries avatar key */
/* Core → View: confirmations (forwarded from plugins) */
integer K_VIEW_CONFIRM_OPEN    = 970;  /* {"t":"c_open","tok":"...","to":"<key>","prompt":"...","buttons":[[id,label],...],"ttl":20,"plug":"<key>"} */
integer K_VIEW_CONFIRM_CANCEL  = 971;  /* {"t":"c_cancel","tok":"..."} */

/* ---------- UI constants ---------- */
integer DIALOG_MAX_BTNS  = 12;
string BTN_NAV_LEFT  = "<<";
string BTN_NAV_RIGHT = ">>";
string BTN_BACK      = "Back";

integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

integer BTN_FLAG_PRIMARY = 1;

/* ---------- State (kept minimal) ---------- */
key     gUser      = NULL_KEY;

integer gAcl           = -1;
integer gAclReady      = FALSE;
integer gListReady     = FALSE;
integer gIsWearer      = FALSE;
integer gOwnerSet      = FALSE;

integer pol_tpe            = FALSE;
integer pol_public_only    = FALSE;
integer pol_owned_only     = FALSE;
integer pol_trustee_access = FALSE;
integer pol_wearer_unowned = FALSE;
integer pol_primary_owner  = FALSE;

/* Registry cache (flattened):
   [label,context,min_acl,has_tpe,label_tpe,tpe_min_acl,audience,...] */
list    g_all  = [];
/* Filtered view for the current user: [label,context,...] */
list    g_view = [];
/* Current root page and label→context map (current page only) */
integer gPage = 0;
list    g_pageMap = [];

/* Plugin page state */
integer g_inPlugin = FALSE;
string  g_curCtx   = "";
/* Button quads for plugin page: [Label,Id,Ord,Flags,...] */
list    g_btnMap   = [];
integer g_subPage  = 0;

/* Root layout capacity (labels only; Prev/Next are extra) */
integer ROOT_CONTENT_CAP = 9;

/* ---------- Helpers ---------- */
integer withinRange(key av){
    if (av == NULL_KEY) return FALSE;
    list d = llGetObjectDetails(av,[OBJECT_POS]);
    if (llGetListLength(d) < 1) return FALSE;
    vector pos = llList2Vector(d,0);
    if (pos == ZERO_VECTOR) return FALSE;
    if (llVecDist(llGetPos(), pos) <= 5.0) return TRUE;
    return FALSE;
}
integer json_has(string j, list p){
    if (llJsonGetValue(j,p) == JSON_INVALID) return FALSE;
    return TRUE;
}

/* ---------- ACL + Registry parsing ---------- */
integer acl_mask_allows(integer mask, integer lvl){
    integer shifted = mask >> lvl;
    if ((shifted & 1) != 0) return TRUE;
    return FALSE;
}

integer parseRegistry(string j){
    g_all = [];
    integer i = 0;
    while (llJsonValueType(j, ["plugins", i]) != JSON_INVALID){
        string label   = llJsonGetValue(j, ["plugins", i, "label"]);
        string context = llJsonGetValue(j, ["plugins", i, "context"]);
        string mv      = llJsonGetValue(j, ["plugins", i, "min_acl"]);
        if (label == "" || context == ""){
            i = i + 1;
        } else if (mv == JSON_INVALID){
            i = i + 1;
        } else {
            integer min_acl = (integer)mv;
            if (min_acl < 0) min_acl = 0;
            if (min_acl > 5) min_acl = 5;

            integer has_tpe = FALSE;
            integer tpe_min = 999;
            string  label_tpe = "";
            string  audience  = "all";

            if (llJsonValueType(j, ["plugins", i, "tpe_min_acl"]) != JSON_INVALID){
                tpe_min = (integer)llJsonGetValue(j, ["plugins", i, "tpe_min_acl"]);
                has_tpe = TRUE;
            }
            if (llJsonValueType(j, ["plugins", i, "label_tpe"]) != JSON_INVALID){
                label_tpe = llJsonGetValue(j, ["plugins", i, "label_tpe"]);
            }
            if (llJsonValueType(j, ["plugins", i, "audience"]) != JSON_INVALID){
                string a = llJsonGetValue(j, ["plugins", i, "audience"]);
                if (a == "wearer_only" || a == "non_wearer_only" || a == "all") audience = a;
            }
            g_all += [label, context, min_acl, has_tpe, label_tpe, tpe_min, audience];
            i = i + 1;
        }
    }
    return 0;
}

integer canSeePlugin(integer minAcl, integer hasTpe, integer tpeMin, string audience){
    if (gAcl <= ACL_BLACKLIST) return FALSE;

    if (gIsWearer){
        if (audience == "non_wearer_only") return FALSE;
    } else {
        if (audience == "wearer_only") return FALSE;
    }

    if (gIsWearer && pol_tpe) {
        if (!hasTpe) return FALSE;
        if (tpeMin == 0) return TRUE; /* wearer TPE bucket (default 0) */
        return FALSE;
    }

    if (pol_primary_owner && gAcl == ACL_PRIMARY_OWNER) return TRUE;

    if (!gIsWearer && pol_public_only){
        if (minAcl == ACL_PUBLIC) return TRUE;
        return FALSE;
    }

    if (gAcl == ACL_PUBLIC){
        if (gIsWearer){
            if (minAcl <= ACL_OWNED) return TRUE;
            return FALSE;
        } else {
            if (minAcl == ACL_PUBLIC) return TRUE;
            return FALSE;
        }
    }
    if (gAcl == ACL_OWNED)         { if (minAcl <= ACL_OWNED)      return TRUE; else return FALSE; }
    if (gAcl == ACL_TRUSTEE)       { if (minAcl <= ACL_TRUSTEE)    return TRUE; else return FALSE; }
    if (gAcl == ACL_UNOWNED)       { if (minAcl <= ACL_UNOWNED)    return TRUE; else return FALSE; }
    if (gAcl == ACL_PRIMARY_OWNER) return TRUE;

    return FALSE;
}

list filterForViewer(){
    list out = [];
    integer i = 0; integer n = llGetListLength(g_all);
    while (i + 6 < n){
        string  label    = llList2String (g_all, i    );
        string  context  = llList2String (g_all, i + 1);
        integer minAcl   = llList2Integer(g_all, i + 2);
        integer hasTpe   = llList2Integer(g_all, i + 3);
        string  labelTpe = llList2String (g_all, i + 4);
        integer tpeMin   = llList2Integer(g_all, i + 5);
        string  audience = llList2String (g_all, i + 6);

        if (canSeePlugin(minAcl, hasTpe, tpeMin, audience)){
            string shown = label;
            if (gIsWearer && pol_tpe && labelTpe != "") shown = labelTpe;
            out += [shown, context];
        }
        i = i + 7;
    }
    return out;
}

/* ---------- Root paging ---------- */
integer rootPageCount(){
    integer total = llGetListLength(g_view) / 2;
    integer pages = 1;
    if (total > 0){
        if ((total % ROOT_CONTENT_CAP) == 0) pages = total / ROOT_CONTENT_CAP;
        else pages = (total / ROOT_CONTENT_CAP) + 1;
        if (pages < 1) pages = 1;
    }
    return pages;
}

list buttonsForRootPage(integer page){
    g_pageMap = [];
    list btns = [];

    integer totalPairs = llGetListLength(g_view) / 2;
    integer pages = rootPageCount();
    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;
    gPage = page;

    integer hasPrev = FALSE; if (page > 0) hasPrev = TRUE;
    integer hasNext = FALSE; if (page < pages - 1) hasNext = TRUE;

    if (hasPrev) btns += BTN_NAV_LEFT;   /* index 0 */
    if (hasNext) btns += BTN_NAV_RIGHT;  /* index 1 */
    /* no Back on root */

    integer startPair = page * ROOT_CONTENT_CAP;
    integer endPair   = startPair + ROOT_CONTENT_CAP - 1;
    if (endPair >= totalPairs) endPair = totalPairs - 1;

    integer idx = startPair * 2;
    integer end = (endPair * 2) + 1;
    while (idx <= end){
        string label = llList2String(g_view, idx);
        if (label == "") label = " ";
        string ctx   = llList2String(g_view, idx + 1);
        btns += [label];
        g_pageMap += [label, ctx];
        idx = idx + 2;
    }
    return btns; /* ≤ 12, no padding */
}

/* ---------- Plugin schema parsing + layout ---------- */
/* Build QUADS [Label,Id,Ord,Flags,...] from JSON buttons; ACL-filtered */
list buildBtnQuadsFromJSON(string uisMsg, integer viewerAcl){
    list out = [];
    integer i = 0;
    /* Hard cap to avoid memory blow-ups */
    integer cap = 48; /* accept at most 48 items from a plugin */
    while (llJsonValueType(uisMsg, ["buttons", i]) != JSON_INVALID && i < cap){
        string  id    = "";
        string  lab   = "";
        integer mask  = 0;
        integer ord   = 9999;
        integer flags = 0;

        if (llJsonValueType(uisMsg, ["buttons", i, 0]) != JSON_INVALID) id   = llJsonGetValue(uisMsg, ["buttons", i, 0]);
        if (llJsonValueType(uisMsg, ["buttons", i, 1]) != JSON_INVALID) lab  = llJsonGetValue(uisMsg, ["buttons", i, 1]);
        if (llJsonValueType(uisMsg, ["buttons", i, 2]) != JSON_INVALID) mask = (integer)llJsonGetValue(uisMsg, ["buttons", i, 2]);
        if (llJsonValueType(uisMsg, ["buttons", i, 3]) != JSON_INVALID) ord  = (integer)llJsonGetValue(uisMsg, ["buttons", i, 3]);
        if (llJsonValueType(uisMsg, ["buttons", i, 4]) != JSON_INVALID) flags= (integer)llJsonGetValue(uisMsg, ["buttons", i, 4]);

        if (lab != "" && id != ""){
            if (acl_mask_allows(mask, viewerAcl)){
                out += [lab, id, (string)ord, (string)flags];
            }
        }
        i = i + 1;
    }
    return out;
}

/* Primary + others in plugin-declared order (no global sort to save memory) */
list splitPrimary(list quads){
    string primaryLabel = "";
    string primaryId    = "";
    integer i = 0; integer n = llGetListLength(quads);
    list others = [];
    while (i + 3 < n){
        string lab = llList2String(quads, i);
        string id  = llList2String(quads, i + 1);
        integer fl = (integer)llList2String(quads, i + 3);
        if (primaryLabel == "" && (fl & BTN_FLAG_PRIMARY)){
            primaryLabel = lab;
            primaryId    = id;
        } else {
            others += [lab, id];
        }
        i = i + 4;
    }
    return [primaryLabel, primaryId] + others;
}

list pluginButtonsForPage(integer page){
    list split = splitPrimary(g_btnMap);
    string primaryLabel = llList2String(split, 0);
    list   others = llList2List(split, 2, -1);
    integer totalOthers = llGetListLength(others) / 2;

    integer hasPrimary = FALSE;
    if (primaryLabel != "") hasPrimary = TRUE;

    /* reserved: Back + maybe Prev/Next + maybe Primary */
    integer reserved = 1; /* Back */
    integer capacity; integer pages;

    /* compute max capacity for page without knowing if Next exists yet:
       we assume Next and adjust on last page */
    integer reservedAssume = reserved + 1 /* Prev? */ + 1 /* Next? */ ;
    if (hasPrimary) reservedAssume = reservedAssume + 1;
    capacity = DIALOG_MAX_BTNS - reservedAssume;
    if (capacity < 0) capacity = 0;

    pages = 1;
    if (capacity > 0){
        if ((totalOthers % capacity) == 0) pages = totalOthers / capacity;
        else pages = (totalOthers / capacity) + 1;
        if (pages < 1) pages = 1;
    }

    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;
    g_subPage = page;

    integer hasPrev = FALSE; if (page > 0) hasPrev = TRUE;

    integer start = page * capacity;
    list pagePairs = [];
    integer taken = 0;
    integer i = start * 2;
    integer maxPairs = capacity;
    while (taken < maxPairs && (i + 1) < llGetListLength(others)){
        pagePairs += [ llList2String(others, i), llList2String(others, i + 1) ];
        taken = taken + 1; i = i + 2;
    }

    integer remaining = totalOthers - (start + taken);
    integer hasNext = FALSE; if (remaining > 0) hasNext = TRUE;

    /* if no Next, we can add a couple more items if space allows */
    if (!hasNext){
        integer reservedNoNext = 1; /* Back */
        if (hasPrev) reservedNoNext = reservedNoNext + 1;
        if (hasPrimary) reservedNoNext = reservedNoNext + 1;
        integer cap2 = DIALOG_MAX_BTNS - reservedNoNext;
        if (cap2 < 0) cap2 = 0;
        integer canAdd = cap2 - taken;
        while (canAdd > 0 && (i + 1) < llGetListLength(others)){
            pagePairs += [ llList2String(others, i), llList2String(others, i + 1) ];
            taken = taken + 1; i = i + 2; canAdd = canAdd - 1;
        }
    }

    list btns = [];
    if (hasPrev) btns += BTN_NAV_LEFT;   /* index 0 */
    if (hasNext) btns += BTN_NAV_RIGHT;  /* index 1 */
    btns += BTN_BACK;                    /* index 2 */
    if (hasPrimary) btns += primaryLabel;/* index 3 */
    i = 0;
    while (i + 1 < llGetListLength(pagePairs)){
        string lab = llList2String(pagePairs, i);
        if (lab == "") lab = " ";
        btns += lab;
        i = i + 2;
    }
    return btns;
}

/* ---------- Core→View: show helpers ---------- */
integer view_show(key to, string title, string body, list buttons){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["t"], "show");
    j = llJsonSetValue(j, ["to"], (string)to);
    j = llJsonSetValue(j, ["title"], title);
    j = llJsonSetValue(j, ["body"], body);
    /* pack buttons JSON array */
    string arr = "[]";
    integer i = 0; integer n = llGetListLength(buttons);
    while (i < n){
        arr = llJsonSetValue(arr, [i], llList2Json(JSON_ARRAY, [ llList2String(buttons,i) ]));
        i = i + 1;
    }
    j = llJsonSetValue(j, ["btn"], arr);
    llMessageLinked(LINK_SET, K_VIEW_SHOW, j, NULL_KEY);
    return 0;
}
integer view_close(){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["t"], "close");
    llMessageLinked(LINK_SET, K_VIEW_CLOSE, j, NULL_KEY);
    return 0;
}

/* ---------- High-level flows ---------- */
integer showRoot(key who, integer page){
    g_inPlugin = FALSE;
    g_curCtx   = "";
    g_btnMap   = [];
    g_subPage  = 0;

    integer total = llGetListLength(g_view) / 2;
    if (total <= 0){
        llRegionSayTo(who, 0, "No plugins available.");
        return 0;
    }
    integer pages = rootPageCount();
    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;
    gPage = page;

    list b = buttonsForRootPage(gPage);
    string body = "Select a function (Page " + (string)(gPage + 1) + "/" + (string)pages + ")";
    view_show(who, "• DS Collar •", body, b);
    return 0;
}
integer navigateRoot(key who, integer newPage){
    integer pages = rootPageCount();
    if (pages <= 0) pages = 1;
    if (newPage < 0) newPage = pages - 1;
    if (newPage >= pages) newPage = 0;
    gPage = newPage;

    list b = buttonsForRootPage(gPage);
    string body = "Select a function (Page " + (string)(gPage + 1) + "/" + (string)pages + ")";
    view_show(who, "• DS Collar •", body, b);
    return 0;
}
integer requestPluginSchema(string context, key opener){
    g_curCtx   = context;
    g_btnMap   = [];
    g_inPlugin = TRUE;
    g_subPage  = 0;

    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["t"], "uiq");
    j = llJsonSetValue(j, ["ctx"], context);
    llMessageLinked(LINK_SET, K_UI_QUERY, j, opener);
    return 0;
}
integer showPluginPage(key who){
    list b = pluginButtonsForPage(g_subPage);
    string body = "Plugin: " + g_curCtx;
    view_show(who, "• DS Collar •", body, b);
    return 0;
}
integer sendPluginAction(string label, key opener){
    integer idx = llListFindList(g_btnMap, [label]);
    if (idx == -1) return FALSE;
    string id = llList2String(g_btnMap, idx + 1);

    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["t"],   "uia");
    j = llJsonSetValue(j, ["ctx"], g_curCtx);
    j = llJsonSetValue(j, ["id"],  id);
    j = llJsonSetValue(j, ["lvl"], (string)gAcl);
    j = llJsonSetValue(j, ["ts"],  (string)llGetUnixTime());
    llMessageLinked(LINK_SET, K_UI_ACTION, j, opener);
    return TRUE;
}

/* ---------- Async ---------- */
integer fetchRegistry(){ llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY); return 0; }
integer queryAcl(key user){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["t"], "aclq");
    j = llJsonSetValue(j, ["av"], (string)user);
    llMessageLinked(LINK_SET, K_ACLF_QUERY, j, user);
    return 0;
}

/* ==================== Events ==================== */
default{
    state_entry(){
        gUser = NULL_KEY;
        gAclReady = FALSE; gListReady = FALSE;
        gAcl = -1; gIsWearer = FALSE; gOwnerSet = FALSE;
        g_all = []; g_view = [];

        pol_tpe = FALSE; pol_public_only = FALSE; pol_owned_only = FALSE;
        pol_trustee_access = FALSE; pol_wearer_unowned = FALSE; pol_primary_owner = FALSE;
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    touch_start(integer n){
        view_close(); /* close any open dialog */
        gUser = llDetectedKey(0);
        if (!withinRange(gUser)){
            llRegionSayTo(gUser, 0, "You are too far from the wearer (max 5 m).");
            return;
        }
        gAclReady = FALSE; gListReady = FALSE;
        gAcl = -1; gIsWearer = FALSE; gOwnerSet = FALSE;

        pol_tpe = FALSE; pol_public_only = FALSE; pol_owned_only = FALSE;
        pol_trustee_access = FALSE; pol_wearer_unowned = FALSE; pol_primary_owner = FALSE;

        queryAcl(gUser);
        fetchRegistry();
    }

    link_message(integer src, integer num, string msg, key id){
        /* ACL reply */
        if (num == K_ACLF_REPLY){
            if (!json_has(msg, ["t"])) return;
            if (llJsonGetValue(msg, ["t"]) != "aclr") return;
            key av = (key)llJsonGetValue(msg, ["av"]);
            if (av != gUser) return;

            gAcl = (integer)llJsonGetValue(msg, ["lvl"]);
            if (gAcl < 0){
                llRegionSayTo(gUser, 0, "Access denied.");
                gUser = NULL_KEY;
                return;
            }
            if (json_has(msg,["is_wearer"])) gIsWearer = (integer)llJsonGetValue(msg,["is_wearer"]);
            if (json_has(msg,["owner_set"])) gOwnerSet = (integer)llJsonGetValue(msg,["owner_set"]);

            if (json_has(msg,["policy_tpe"]))            pol_tpe            = (integer)llJsonGetValue(msg,["policy_tpe"]);
            if (json_has(msg,["policy_public_only"]))    pol_public_only    = (integer)llJsonGetValue(msg,["policy_public_only"]);
            if (json_has(msg,["policy_owned_only"]))     pol_owned_only     = (integer)llJsonGetValue(msg,["policy_owned_only"]);
            if (json_has(msg,["policy_trustee_access"])) pol_trustee_access = (integer)llJsonGetValue(msg,["policy_trustee_access"]);
            if (json_has(msg,["policy_wearer_unowned"])) pol_wearer_unowned = (integer)llJsonGetValue(msg,["policy_wearer_unowned"]);
            if (json_has(msg,["policy_primary_owner"]))  pol_primary_owner  = (integer)llJsonGetValue(msg,["policy_primary_owner"]);

            gAclReady = TRUE;
            if (gAclReady && gListReady){
                g_view = filterForViewer();
                if (llGetListLength(g_view) == 0){
                    llRegionSayTo(gUser, 0, "No plugins available.");
                    gUser = NULL_KEY;
                    return;
                }
                showRoot(gUser, 0);
                gAclReady = FALSE; gListReady = FALSE;
            }
            return;
        }

        /* Registry list */
        if (num == K_PLUGIN_LIST_NUM){
            if (!json_has(msg,["type"])) return;
            if (llJsonGetValue(msg,["type"]) != TYPE_PLUGIN_LIST) return;

            parseRegistry(msg);
            gListReady = TRUE;

            if (gAclReady && gListReady){
                g_view = filterForViewer();
                if (llGetListLength(g_view) == 0){
                    llRegionSayTo(gUser, 0, "No plugins available.");
                    gUser = NULL_KEY;
                    return;
                }
                showRoot(gUser, 0);
                gAclReady = FALSE; gListReady = FALSE;
            }
            return;
        }

        /* Plugin schema */
        if (num == K_UI_SCHEMA){
            if (!json_has(msg, ["t"])) return;
            if (llJsonGetValue(msg, ["t"]) != "uis") return;
            if (!json_has(msg, ["ctx"])) return;
            if (llJsonGetValue(msg, ["ctx"]) != g_curCtx) return;

            integer rootMask = 127;
            if (json_has(msg,["r"])) rootMask = (integer)llJsonGetValue(msg,["r"]);
            else if (json_has(msg,["root"])) rootMask = (integer)llJsonGetValue(msg,["root"]);
            if (!acl_mask_allows(rootMask, gAcl)){
                llRegionSayTo(gUser, 0, "You are not allowed to access this function.");
                showRoot(gUser, gPage);
                return;
            }

            g_btnMap = buildBtnQuadsFromJSON(msg, gAcl);
            showPluginPage(gUser);
            return;
        }

        /* View reports a click */
        if (num == K_VIEW_CLICK){
            if (!withinRange(id)){
                view_close();
                llRegionSayTo(id, 0, "You moved too far from the wearer (max 5 m).");
                return;
            }
            string lab = "";
            if (json_has(msg,["label"])) lab = llJsonGetValue(msg,["label"]);

            if (!g_inPlugin){
                if (lab == BTN_NAV_LEFT){  navigateRoot(id, gPage - 1); return; }
                if (lab == BTN_NAV_RIGHT){ navigateRoot(id, gPage + 1); return; }

                integer idx = llListFindList(g_pageMap, [lab]);
                if (idx != -1){
                    string ctx = llList2String(g_pageMap, idx + 1);
                    requestPluginSchema(ctx, id);
                    return;
                }
                showRoot(id, gPage);
                return;
            } else {
                if (lab == BTN_BACK){ showRoot(id, gPage); return; }
                if (lab == BTN_NAV_LEFT){  g_subPage = g_subPage - 1; showPluginPage(id); return; }
                if (lab == BTN_NAV_RIGHT){ g_subPage = g_subPage + 1; showPluginPage(id); return; }

                integer ok = sendPluginAction(lab, id);
                if (!ok){ showPluginPage(id); return; }
                showPluginPage(id);
                return;
            }
        }

        /* Confirm open/cancel from plugins → forward to view */
        if (num == K_UI_CONFIRM){
            if (!json_has(msg,["t"])) return;
            if (llJsonGetValue(msg,["t"]) != "uic") return;

            /* normalize buttons: allow "mode":"modal"/"confirm" or explicit "buttons" */
            string btn = "[]";
            if (json_has(msg,["mode"])){
                string mode = llJsonGetValue(msg,["mode"]);
                if (mode == "modal"){
                    btn = llJsonSetValue(btn, ["0"], llList2Json(JSON_ARRAY, ["ok","OK"]));
                } else if (mode == "confirm"){
                    btn = llJsonSetValue(btn, ["0"], llList2Json(JSON_ARRAY, ["ok","OK"]));
                    btn = llJsonSetValue(btn, ["1"], llList2Json(JSON_ARRAY, ["cancel","Cancel"]));
                }
            } else if (json_has(msg,["buttons"])){
                btn = llJsonGetValue(msg,["buttons"]);
            }

            string v = llList2Json(JSON_OBJECT,[]);
            v = llJsonSetValue(v, ["t"], "c_open");
            v = llJsonSetValue(v, ["tok"], llJsonGetValue(msg,["tok"]));
            v = llJsonSetValue(v, ["to"],  llJsonGetValue(msg,["to"]));
            v = llJsonSetValue(v, ["prompt"], llJsonGetValue(msg,["prompt"]));
            v = llJsonSetValue(v, ["buttons"], btn);
            if (json_has(msg,["ttl"])) v = llJsonSetValue(v, ["ttl"], llJsonGetValue(msg,["ttl"]));
            v = llJsonSetValue(v, ["plug"], (string)id); /* plugin key to reply to */
            llMessageLinked(LINK_SET, K_VIEW_CONFIRM_OPEN, v, NULL_KEY);
            return;
        }
        if (num == K_UI_CANCEL){
            if (!json_has(msg,["t"])) return;
            if (llJsonGetValue(msg,["t"]) != "uix") return;
            string v2 = llList2Json(JSON_OBJECT,[]);
            v2 = llJsonSetValue(v2, ["t"], "c_cancel");
            v2 = llJsonSetValue(v2, ["tok"], llJsonGetValue(msg,["tok"]));
            llMessageLinked(LINK_SET, K_VIEW_CONFIRM_CANCEL, v2, NULL_KEY);
            return;
        }
    }
}
