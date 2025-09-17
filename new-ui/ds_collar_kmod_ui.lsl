/* =============================================================
   MODULE:  ds_collar_kmod_ui.lsl  (AUTH-driven + dual display)
   ROLE  :  Root UI Hub. Centralized dialogs, ACL filtering,
            plugin schema pages, and multi-user confirmations.
   INPUT :  Registry rows may include optional:
              - tpe_min_acl (int)
              - label_tpe (string)
              - audience: "all"|"wearer_only"|"non_wearer_only"
   LAYOUT:  No padding. Priority order within llDialog button list:
              0: Prev   1: Next   2: Back   3: Primary   4..: others
            (Back omitted on root page)
   NOTE  :  JSON-only messaging. No ternary syntax anywhere.
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI] " + s); return 0; }

/* ---------- Protocol strings ---------- */
string TYPE_PLUGIN_LIST   = "plugin_list";
string TYPE_PLUGIN_RETURN = "plugin_return";
string TYPE_PLUGIN_START  = "plugin_start"; /* kept for back-compat (unused here) */

/* ---------- Link numbers (align with your kernel) ---------- */
/* AUTH numbers may still exist elsewhere; UI talks to ACLF instead */
integer AUTH_QUERY_NUM        = 700;
integer AUTH_RESULT_NUM       = 710;

integer K_PLUGIN_LIST_NUM     = 600;
integer K_PLUGIN_LIST_REQUEST = 601;
integer K_PLUGIN_START_NUM    = 900; /* not used by hub in schema mode */
integer K_PLUGIN_RETURN_NUM   = 901;

/* ACL Filter bridge */
integer K_ACLF_QUERY          = 640;  /* UI → ACLF: {"t":"aclq","av":"<key>"} */
integer K_ACLF_REPLY          = 641;  /* ACLF → UI: {"t":"aclr","av":"<key>","lvl":...,...} */

/* Schema-driven UI + actions */
integer K_UI_QUERY            = 620;  /* hub → plugin: {"t":"uiq","ctx":"..."} */
integer K_UI_SCHEMA           = 621;  /* plugin → hub: {"t":"uis","v":1,"ctx":"...","r":126,"buttons":[[id,label,mask,ord,flags],...]} */
integer K_UI_ACTION           = 922;  /* hub → plugin: {"t":"uia","ctx":"...","id":"...","lvl":2,"ts":...} */

/* Multi-user confirmation (JSON-only) */
integer K_UI_CONFIRM          = 930;  /* plugin → hub: {"t":"uic","ctx":"...","tok":"abc","to":"<key>","prompt":"...","mode":"modal|confirm" OR "buttons":[[id,label],...],"ttl":20} */
integer K_UI_CONFIRM_RESULT   = 931;  /* hub → plugin: {"t":"uicr","ctx":"...","tok":"abc","from":"<key>","id":"idY","label":"Yes","why":"ok|timeout"} */
integer K_UI_CANCEL           = 932;  /* plugin → hub: {"t":"uix","tok":"abc"} */

/* ---------- UI / Dialog ---------- */
integer DIALOG_MAX_BTNS = 12; /* Second Life llDialog max buttons */
string  ROOT_CONTEXT     = "core_root";

/* Reserved labels in our priority order */
string BTN_NAV_LEFT  = "<<";   /* index 0 if present */
string BTN_NAV_RIGHT = ">>";   /* index 1 if present */
string BTN_BACK      = "Back"; /* index 2 on plugin pages */

/* ---------- ACL constants (must match AUTH) ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* Wearer TPE bucket (dual-display) — usually 0 */
integer gTpeMinAcl = 0;

/* ---------- Optional per-button flags (bitmask) ---------- */
integer BTN_FLAG_PRIMARY = 1; /* bit 0 = primary */

/* ---------- State: registry / filtering ---------- */
/* Flattened registry: [label,context,min_acl,has_tpe,label_tpe,tpe_min_acl,audience,...] */
list    g_all = [];
/* Filtered for current viewer: [label,context,...] */
list    g_view = [];
/* Map label→context for current page */
list    g_pageMap = [];

/* Current plugin subpage (schema) */
string  g_curCtx   = "";
/* For JSON buttons we store QUADS: [Label,Id,Ord,Flags, Label,Id,Ord,Flags, ...] */
list    g_btnMap   = [];
integer g_inPlugin = FALSE;
integer g_subPage  = 0;

/* Root pagination */
integer gPage = 0;
/* Root page content capacity (labels only, excluding Prev/Next). Keep 9 to mimic classic pages.
   With Prev+Next this yields up to 11 buttons, under 12 limit. */
integer ROOT_CONTENT_CAP = 9;

/* Session */
key     gUser      = NULL_KEY;
integer gListen    = 0;      /* root/plugin dialog channel */
integer gChan      = 0;
integer dialogOpen = FALSE;

/* ACL + policy from ACLF */
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

/* ---------- Confirm manager (multi-user) ---------- */
integer CH_CONFIRM = -777777;      /* shared confirm channel */
integer gListenConfirm = 0;
/* rows: "tok|toKey|ctx|buttonsJSON|prompt|expEpoch|pluginKey" */
list    g_conf_rows = [];
/* index by avatar: "toKey|tok" */
list    g_conf_by_av = [];
integer UI_TICK_SEC = 2;

/* ---------- Helpers ---------- */
integer withinRange(key av){
    if (av == NULL_KEY) return FALSE;
    list d = llGetObjectDetails(av,[OBJECT_POS]);
    if (llGetListLength(d) < 1) return FALSE;
    vector pos = llList2Vector(d,0);
    if (pos == ZERO_VECTOR) return FALSE;
    float dist = llVecDist(llGetPos(), pos);
    if (dist <= 5.0) return TRUE;
    return FALSE;
}
integer json_has(string j, list p){
    if (llJsonGetValue(j,p) == JSON_INVALID) return FALSE;
    return TRUE;
}
list split(string s, string sep){ return llParseStringKeepNulls(s, [sep], []); }

/* ---------- Registry parser (JSON) ---------- */
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

            /* optional */
            integer has_tpe = FALSE;
            integer tpe_min = 999;   /* sentinel: not declared */
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

/* ---------- ACL helpers ---------- */
integer acl_mask_allows(integer mask, integer lvl){
    integer shifted = mask >> lvl;
    integer bit = shifted & 1;
    if (bit != 0) return TRUE;
    return FALSE;
}

/* ---------- Visibility logic ---------- */
integer canSeePlugin(integer minAcl, integer hasTpe, integer tpeMin, string audience)
{
    /* 0) ACL hard deny */
    if (gAcl <= ACL_BLACKLIST) return FALSE;

    /* 1) Audience gates */
    if (gIsWearer){
        if (audience == "non_wearer_only") return FALSE;
    } else {
        if (audience == "wearer_only") return FALSE;
    }

    /* 2) Wearer in TPE → only dual-display entries that match gTpeMinAcl */
    if (gIsWearer && pol_tpe) {
        if (!hasTpe) return FALSE;
        if (tpeMin == gTpeMinAcl) return TRUE;
        return FALSE;
    }

    /* 3) Primary Owner bypass (ignore public clamp) */
    if (pol_primary_owner){
        if (gAcl == ACL_PRIMARY_OWNER) return TRUE;
    }

    /* 4) Public-mode clamp for true outsiders only */
    if (!gIsWearer && pol_public_only) {
        if (minAcl == ACL_PUBLIC) return TRUE;
        return FALSE;
    }

    /* 5) Normal visibility mapping per ACL (non-clamped, non-TPE) */
    if (gAcl == ACL_PUBLIC) {
        if (gIsWearer){
            if (minAcl <= ACL_OWNED) return TRUE;
            return FALSE;
        } else {
            if (minAcl == ACL_PUBLIC) return TRUE;
            return FALSE;
        }
    }

    if (gAcl == ACL_OWNED){
        if (minAcl <= ACL_OWNED) return TRUE;
        return FALSE;
    }

    if (gAcl == ACL_TRUSTEE){
        if (minAcl <= ACL_TRUSTEE) return TRUE;
        return FALSE;
    }

    if (gAcl == ACL_UNOWNED){
        if (minAcl <= ACL_UNOWNED) return TRUE;
        return FALSE;
    }

    if (gAcl == ACL_PRIMARY_OWNER){
        return TRUE;
    }

    return FALSE;
}

/* Build filtered view for the current user under AUTH flags */
list filterForViewer(){
    list out = [];
    integer i = 0;
    integer n = llGetListLength(g_all);

    while (i + 6 < n){
        string  label    = llList2String (g_all, i    );
        string  context  = llList2String (g_all, i + 1);
        integer minAcl   = llList2Integer(g_all, i + 2);
        integer hasTpe   = llList2Integer(g_all, i + 3);
        string  labelTpe = llList2String (g_all, i + 4);
        integer tpeMin   = llList2Integer(g_all, i + 5);
        string  audience = llList2String (g_all, i + 6);

        integer include = canSeePlugin(minAcl, hasTpe, tpeMin, audience);

        if (include){
            string shown = label;
            if (gIsWearer && pol_tpe){
                if (labelTpe != "") shown = labelTpe;
            }
            out += [shown, context];
        }

        i = i + 7;
    }

    return out;
}

/* ---------- Root page (no padding; no Back) ---------- */
integer rootPageCount(){
    integer total = llGetListLength(g_view) / 2;
    integer pages = 0;
    if (total <= 0) pages = 1;
    else{
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
    /* no Back on root (index 2 reserved only on plugin pages) */

    /* slice root content */
    integer startPair = page * ROOT_CONTENT_CAP;
    integer endPair   = startPair + ROOT_CONTENT_CAP - 1;
    if (endPair >= totalPairs) endPair = totalPairs - 1;

    integer idx = startPair * 2;
    integer end = (endPair * 2) + 1;

    while (idx <= end){
        string label = llList2String(g_view, idx);
        string ctx   = llList2String(g_view, idx + 1);
        btns += [label];
        g_pageMap += [label, ctx];
        idx = idx + 2;
    }

    return btns; /* no padding */
}

/* ---------- Dialog helpers ---------- */
integer openDialog(key to, string title, string body, list buttons){
    if (gListen) llListenRemove(gListen);
    dialogOpen = TRUE;
    gChan   = -100000 - (integer)llFrand(1000000.0);
    gListen = llListen(gChan, "", to, "");
    llDialog(to, title + "\n" + body, buttons, gChan);
    return 0;
}
integer closeDialog(){
    if (gListen){
        llListenRemove(gListen);
        gListen = 0;
    }
    dialogOpen = FALSE;
    return 0;
}

/* ---------- Root page ---------- */
integer showRoot(key who, integer page){
    g_inPlugin = FALSE;
    g_curCtx = "";
    g_btnMap = [];
    g_subPage = 0;

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
    openDialog(who, "• DS Collar •", body, b);
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
    openDialog(who, "• DS Collar •", body, b);
    return 0;
}

/* ---------- JSON schema parsing (plugin page) ---------- */
/* Build QUADS [Label,Id,Ord,Flags,...] from JSON "buttons" (id,label,mask,ord?,flags?) */
list buildBtnQuadsFromJSON(string uisMsg, integer viewerAcl){
    list out = [];
    integer i = 0;
    while (llJsonValueType(uisMsg, ["buttons", i]) != JSON_INVALID){
        string  id    = "";
        string  lab   = "";
        integer mask  = 0;
        integer ord   = 9999; /* default at end */
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

/* split quads into primary + others (sorted by ord asc, then label)
   INPUT quads: [Label,Id,Ord,Flags, Label,Id,Ord,Flags, ...]
   RETURNS: [ primaryLabel, primaryId, otherLabel, otherId, ... ]
*/
list splitPrimaryAndSort(list quads){
    string primaryLabel = "";
    string primaryId    = "";
    integer primaryTaken = FALSE;

    /* Build sortable strides as [sortKey, label, id, flags, ...]
       sortKey = zero-padded ord + '|' + lowercase(label)
    */
    list tmp = [];
    integer i = 0; integer n = llGetListLength(quads);
    while (i + 3 < n){
        string  lab  = llList2String(quads, i);
        string  id   = llList2String(quads, i + 1);
        integer ord  = (integer)llList2String(quads, i + 2);
        integer flg  = (integer)llList2String(quads, i + 3);

        if (ord < 0) ord = 0;
        string ordStr = (string)ord;
        while (llStringLength(ordStr) < 6) ordStr = "0" + ordStr;

        string sortKey = ordStr + "|" + llToLower(lab);
        tmp += [ sortKey, lab, id, (string)flg ];
        i = i + 4;
    }

    /* Sort by sortKey (stride 4, ascending) */
    tmp = llListSort(tmp, 4, TRUE);

    /* Walk sorted list, pick first PRIMARY, append the rest */
    list pairs = [];
    i = 0; n = llGetListLength(tmp);
    while (i + 3 < n){
        integer flg = (integer)llList2String(tmp, i + 3);
        string  lab = llList2String(tmp, i + 1);
        string  id2 = llList2String(tmp, i + 2);

        if (!primaryTaken && (flg & BTN_FLAG_PRIMARY)){
            primaryLabel = lab;
            primaryId    = id2;
            primaryTaken = TRUE;
        } else {
            pairs += [lab, id2];
        }
        i = i + 4;
    }

    return [primaryLabel, primaryId] + pairs;
}

/* Build the plugin page with your index priorities, no padding */
list pluginButtonsForPage(integer page){
    /* split current quads */
    list split = splitPrimaryAndSort(g_btnMap);

    string primaryLabel = llList2String(split, 0);
    string primaryId    = llList2String(split, 1);

    /* Remaining actions (pairs) */
    list others = llList2List(split, 2, -1); /* [lab,id,lab,id,...] */
    integer totalOthers = llGetListLength(others) / 2;

    integer hasPrimary = FALSE; if (primaryLabel != "") hasPrimary = TRUE;

    /* Provisional: assume both Prev and Next exist for capacity */
    integer hasPrev = FALSE; if (page > 0) hasPrev = TRUE;
    integer assumeNext = TRUE;

    /* reserved count: Prev? + Next(assumed) + Back(always) + Primary? */
    integer reserved = 1; /* Back always present on plugin pages */
    if (hasPrev) reserved = reserved + 1;
    reserved = reserved + 1; /* assume Next */
    if (hasPrimary) reserved = reserved + 1;

    integer capacity = DIALOG_MAX_BTNS - reserved;
    if (capacity < 0) capacity = 0;

    /* Clamp page using provisional capacity */
    integer pages = 1;
    if (capacity > 0){
        if ((totalOthers % capacity) == 0) pages = totalOthers / capacity;
        else pages = (totalOthers / capacity) + 1;
        if (pages < 1) pages = 1;
    }

    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;
    g_subPage = page;

    /* Slice */
    integer start = page * capacity;
    integer taken = 0;
    list pagePairs = [];
    integer i = start * 2;
    integer stop = i + (capacity * 2) - 1;
    integer maxIdx = (totalOthers * 2) - 1;
    if (stop > maxIdx) stop = maxIdx;
    while (i <= stop && i >= 0){
        pagePairs += [ llList2String(others, i), llList2String(others, i + 1) ];
        taken = taken + 1;
        i = i + 2;
    }

    /* Determine if Next is actually needed */
    integer remaining = totalOthers - (start + taken);
    integer hasNext = FALSE;
    if (remaining > 0) hasNext = TRUE;

    /* If Next not needed, we may have spare room: add more if capacity increased by 1 */
    if (!hasNext){
        integer reservedNoNext = 1; /* Back */
        if (hasPrev) reservedNoNext = reservedNoNext + 1;
        /* no Next */
        if (hasPrimary) reservedNoNext = reservedNoNext + 1;
        integer cap2 = DIALOG_MAX_BTNS - reservedNoNext;
        if (cap2 < 0) cap2 = 0;
        integer canAdd = cap2 - taken;
        while (canAdd > 0 && (start + taken) < totalOthers){
            integer k = (start + taken) * 2;
            pagePairs += [ llList2String(others, k), llList2String(others, k + 1) ];
            taken = taken + 1;
            canAdd = canAdd - 1;
        }
    }

    /* Compose final list: Prev, Next, Back, Primary, others... (no padding) */
    list btns = [];
    if (hasPrev) btns += BTN_NAV_LEFT;   /* index 0 if present */
    if (hasNext) btns += BTN_NAV_RIGHT;  /* index 1 if present */
    btns += BTN_BACK;                    /* index 2 always on plugin pages */
    if (hasPrimary) btns += primaryLabel;/* index 3 if present */

    /* append remaining actions (labels only) */
    i = 0; integer m = llGetListLength(pagePairs);
    while (i + 1 < m){
        btns += llList2String(pagePairs, i);
        i = i + 2;
    }

    return btns; /* no padding; length ≤ 12 */
}
integer showPluginPage(key who){
    list b = pluginButtonsForPage(g_subPage);
    string body = "Plugin: " + g_curCtx;
    openDialog(who, "• DS Collar •", body, b);
    return 0;
}

/* Request a plugin's schema */
integer requestPluginSchema(string context, key opener){
    g_curCtx = context;
    g_btnMap = [];
    g_inPlugin = TRUE;
    g_subPage = 0;

    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["t"], "uiq");
    j = llJsonSetValue(j, ["ctx"], context);
    llMessageLinked(LINK_SET, K_UI_QUERY, j, opener);
    return 0;
}

/* Dispatch a button press to plugin (by label lookup) */
integer sendPluginAction(string label, key opener){
    integer idx = llListFindList(g_btnMap, [label]);
    if (idx == -1) return FALSE;

    /* idx is label; id is next cell in QUADS */
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

/* ---------- Async calls ---------- */
integer queryAcl(key user){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["t"], "aclq");
    j = llJsonSetValue(j, ["av"], (string)user);
    llMessageLinked(LINK_SET, K_ACLF_QUERY, j, user);
    return 0;
}
integer fetchRegistry(){ llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY); return 0; }

/* ---------- Confirm manager (JSON-only) ---------- */
integer conf_find_tok(string tok){
    integer i = 0; integer n = llGetListLength(g_conf_rows);
    while (i < n){
        string r = llList2String(g_conf_rows, i);
        if (llList2String(split(r,"|"), 0) == tok) return i;
        i = i + 1;
    }
    return -1;
}
integer conf_find_by_av(key to){
    integer i = 0; integer n = llGetListLength(g_conf_by_av);
    while (i < n){
        list p = split(llList2String(g_conf_by_av, i),"|");
        if ((key)llList2String(p,0) == to) return i;
        i = i + 1;
    }
    return -1;
}
string pack_conf(string tok, key to, string ctx, string buttonsJSON, string prompt, integer exp, key plugin){
    return tok + "|" + (string)to + "|" + ctx + "|" + buttonsJSON + "|" + prompt + "|" + (string)exp + "|" + (string)plugin;
}
integer conf_add(string tok, key to, string ctx, string buttonsJSON, string prompt, integer ttl, key plugin){
    integer exp = llGetUnixTime() + ttl;
    /* evict any existing ticket for this avatar */
    integer j = conf_find_by_av(to);
    if (j != -1){
        string oldTok = llList2String(split(llList2String(g_conf_by_av, j),"|"), 1);
        integer i = conf_find_tok(oldTok);
        if (i != -1) g_conf_rows = llDeleteSubList(g_conf_rows, i, i);
        g_conf_by_av = llDeleteSubList(g_conf_by_av, j, j);
    }
    g_conf_rows += pack_conf(tok,to,ctx,buttonsJSON,prompt,exp,plugin);
    g_conf_by_av += ((string)to + "|" + tok);

    if (gListenConfirm == 0){
        gListenConfirm = llListen(CH_CONFIRM, "", "", "");
    }
    return 1;
}
integer conf_show(key to, string prompt, string buttonsJSON){
    list labels = [];
    integer i = 0;
    while (llJsonValueType(buttonsJSON, [ i ]) != JSON_INVALID){
        string lab = "";
        if (llJsonValueType(buttonsJSON, [ i, 1 ]) != JSON_INVALID) lab = llJsonGetValue(buttonsJSON, [ i, 1 ]);
        if (lab != "") labels += lab;
        i = i + 1;
    }
    llDialog(to, prompt, labels, CH_CONFIRM);
    return TRUE;
}
integer conf_sweep_timeouts(){
    integer i = 0;
    while (i < llGetListLength(g_conf_rows)){
        list row = split(llList2String(g_conf_rows, i),"|");
        integer exp = (integer)llList2String(row,5);
        if (llGetUnixTime() >= exp){
            string tok = llList2String(row,0);
            string ctx = llList2String(row,2);
            key plugin = (key)llList2String(row,6);

            string r = llList2Json(JSON_OBJECT,[]);
            r = llJsonSetValue(r, ["t"], "uicr");
            r = llJsonSetValue(r, ["ctx"], ctx);
            r = llJsonSetValue(r, ["tok"], tok);
            r = llJsonSetValue(r, ["from"], (string)llList2String(row,1));
            r = llJsonSetValue(r, ["id"],  "");
            r = llJsonSetValue(r, ["label"], "");
            r = llJsonSetValue(r, ["why"], "timeout");
            llMessageLinked(LINK_SET, K_UI_CONFIRM_RESULT, r, plugin);

            g_conf_rows = llDeleteSubList(g_conf_rows, i, i);
            key to = (key)llList2String(row,1);
            integer j = conf_find_by_av(to);
            if (j != -1) g_conf_by_av = llDeleteSubList(g_conf_by_av, j, j);
        } else {
            i = i + 1;
        }
    }
    if (llGetListLength(g_conf_rows) == 0){
        if (gListenConfirm != 0){ llListenRemove(gListenConfirm); gListenConfirm = 0; }
    }
    return 1;
}

/* ==================== Events ==================== */
default{
    state_entry(){
        gUser      = NULL_KEY;
        gListen    = 0;
        gChan      = 0;
        gPage      = 0;
        dialogOpen = FALSE;

        g_all  = [];
        g_view = [];
        g_pageMap = [];

        g_curCtx = ""; g_btnMap = [];
        g_inPlugin = FALSE; g_subPage = 0;

        gAcl = -1; gAclReady = FALSE; gListReady = FALSE;
        gIsWearer = FALSE; gOwnerSet = FALSE;

        pol_tpe = FALSE; pol_public_only = FALSE; pol_owned_only = FALSE;
        pol_trustee_access = FALSE; pol_wearer_unowned = FALSE; pol_primary_owner = FALSE;

        /* timer for confirm timeouts */
        llSetTimerEvent((float)UI_TICK_SEC);
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    touch_start(integer n){
        if (dialogOpen) closeDialog();

        gUser = llDetectedKey(0);
        if (!withinRange(gUser)){
            llRegionSayTo(gUser, 0, "You are too far from the wearer (max 5 m).");
            return;
        }

        /* reset session */
        gAclReady = FALSE; gListReady = FALSE;
        gAcl = -1; gIsWearer = FALSE; gOwnerSet = FALSE;
        pol_tpe = FALSE; pol_public_only = FALSE; pol_owned_only = FALSE;
        pol_trustee_access = FALSE; pol_wearer_unowned = FALSE; pol_primary_owner = FALSE;

        queryAcl(gUser);
        fetchRegistry();
    }

    link_message(integer src, integer num, string msg, key id){
        /* ACLF result */
        if (num == K_ACLF_REPLY){
            if (llJsonValueType(msg, ["t"]) == JSON_INVALID) return;
            if (llJsonGetValue(msg, ["t"]) != "aclr") return;

            key av = (key)llJsonGetValue(msg, ["av"]);
            if (av == NULL_KEY) return;
            if (av != gUser) return;

            gAcl = (integer)llJsonGetValue(msg, ["lvl"]);
            if (gAcl < 0){
                llRegionSayTo(gUser, 0, "Access denied.");
                gUser = NULL_KEY;
                return;
            }

            gIsWearer = FALSE;
            if (llJsonValueType(msg,["is_wearer"]) != JSON_INVALID) gIsWearer = (integer)llJsonGetValue(msg,["is_wearer"]);
            gOwnerSet = FALSE;
            if (llJsonValueType(msg,["owner_set"]) != JSON_INVALID) gOwnerSet = (integer)llJsonGetValue(msg,["owner_set"]);

            pol_tpe            = FALSE; if (llJsonValueType(msg,["policy_tpe"])            != JSON_INVALID) pol_tpe            = (integer)llJsonGetValue(msg,["policy_tpe"]);
            pol_public_only    = FALSE; if (llJsonValueType(msg,["policy_public_only"])    != JSON_INVALID) pol_public_only    = (integer)llJsonGetValue(msg,["policy_public_only"]);
            pol_owned_only     = FALSE; if (llJsonValueType(msg,["policy_owned_only"])     != JSON_INVALID) pol_owned_only     = (integer)llJsonGetValue(msg,["policy_owned_only"]);
            pol_trustee_access = FALSE; if (llJsonValueType(msg,["policy_trustee_access"]) != JSON_INVALID) pol_trustee_access = (integer)llJsonGetValue(msg,["policy_trustee_access"]);
            pol_wearer_unowned = FALSE; if (llJsonValueType(msg,["policy_wearer_unowned"]) != JSON_INVALID) pol_wearer_unowned = (integer)llJsonGetValue(msg,["policy_wearer_unowned"]);
            pol_primary_owner  = FALSE; if (llJsonValueType(msg,["policy_primary_owner"])  != JSON_INVALID) pol_primary_owner  = (integer)llJsonGetValue(msg,["policy_primary_owner"]);

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
            if (llJsonValueType(msg,["type"]) == JSON_INVALID) return;
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

        /* Plugin indicates return to root (legacy) */
        if (num == K_PLUGIN_RETURN_NUM){
            if (llJsonValueType(msg,["context"]) != JSON_INVALID){
                string ctx = llJsonGetValue(msg,["context"]);
                if (ctx == ROOT_CONTEXT) showRoot(gUser, gPage);
            }
            return;
        }

        /* Plugin sent its JSON schema */
        if (num == K_UI_SCHEMA){
            if (!json_has(msg, ["t"])) return;
            if (llJsonGetValue(msg, ["t"]) != "uis") return;
            if (!json_has(msg, ["ctx"])) return;
            if (llJsonGetValue(msg, ["ctx"]) != g_curCtx) return;

            /* root mask (accept "r" or legacy "root") */
            integer rootMask = 127;
            if (json_has(msg, ["r"])) rootMask = (integer)llJsonGetValue(msg, ["r"]);
            else if (json_has(msg, ["root"])) rootMask = (integer)llJsonGetValue(msg, ["root"]);

            if (!acl_mask_allows(rootMask, gAcl)){
                llRegionSayTo(gUser, 0, "You are not allowed to access this function.");
                showRoot(gUser, gPage);
                return;
            }

            /* Parse JSON buttons → QUADS [Label,Id,Ord,Flags,...] filtered by viewer ACL */
            g_btnMap = buildBtnQuadsFromJSON(msg, gAcl);

            /* Render subpage (no padding; Prev, Next, Back, Primary, others...) */
            showPluginPage(gUser);
            return;
        }

        /* Plugin asks for a multi-user confirmation (JSON-only) */
        if (num == K_UI_CONFIRM){
            if (!json_has(msg, ["t"])) return;
            if (llJsonGetValue(msg, ["t"]) != "uic") return;

            string tok = llJsonGetValue(msg, ["tok"]);
            key to     = (key)llJsonGetValue(msg, ["to"]);
            string ctx = llJsonGetValue(msg, ["ctx"]);
            string pr  = llJsonGetValue(msg, ["prompt"]);

            /* Allow shorthand via "mode": "modal" or "confirm" */
            string btn = "[]";
            if (json_has(msg, ["mode"])){
                string mode = llJsonGetValue(msg, ["mode"]);
                if (mode == "modal"){
                    btn = llJsonSetValue(btn, ["0"], llList2Json(JSON_ARRAY, ["ok", "OK"]));
                } else if (mode == "confirm"){
                    btn = llJsonSetValue(btn, ["0"], llList2Json(JSON_ARRAY, ["ok",     "OK"]));
                    btn = llJsonSetValue(btn, ["1"], llList2Json(JSON_ARRAY, ["cancel", "Cancel"]));
                }
            } else if (json_has(msg, ["buttons"])) {
                btn = llJsonGetValue(msg, ["buttons"]);
            }

            if (btn == "") btn = "[]";

            integer ttl= 20;
            if (json_has(msg, ["ttl"])) ttl = (integer)llJsonGetValue(msg, ["ttl"]);

            conf_add(tok, to, ctx, btn, pr, ttl, id);
            conf_show(to, pr, btn);
            return;
        }

        /* Plugin cancels a pending confirmation */
        if (num == K_UI_CANCEL){
            if (!json_has(msg, ["t"])) return;
            if (llJsonGetValue(msg, ["t"]) != "uix") return;
            string tok = llJsonGetValue(msg, ["tok"]);
            integer i = conf_find_tok(tok);
            if (i != -1){
                list row = split(llList2String(g_conf_rows, i),"|");
                key to = (key)llList2String(row,1);
                g_conf_rows = llDeleteSubList(g_conf_rows, i, i);
                integer j = conf_find_by_av(to);
                if (j != -1) g_conf_by_av = llDeleteSubList(g_conf_by_av, j, j);
            }
            if (llGetListLength(g_conf_rows) == 0){
                if (gListenConfirm != 0){ llListenRemove(gListenConfirm); gListenConfirm = 0; }
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string b){
        /* Confirm channel (multi-user) */
        if (chan == CH_CONFIRM){
            /* Must match a pending ticket for this avatar */
            integer j = conf_find_by_av(id);
            if (j == -1) return;

            string tok = llList2String(split(llList2String(g_conf_by_av, j),"|"), 1);
            integer i = conf_find_tok(tok);
            if (i == -1) return;

            list row = split(llList2String(g_conf_rows, i),"|");
            string ctx    = llList2String(row,2);
            string btnJS  = llList2String(row,3);
            key    plugin = (key)llList2String(row,6);

            /* label → id from buttons JSON */
            string clickedId = "";
            integer k = 0;
            while (llJsonValueType(btnJS, [ k ]) != JSON_INVALID){
                string lab = "";
                string cid = "";
                if (llJsonValueType(btnJS, [ k, 1 ]) != JSON_INVALID) lab = llJsonGetValue(btnJS, [ k, 1 ]);
                if (llJsonValueType(btnJS, [ k, 0 ]) != JSON_INVALID) cid = llJsonGetValue(btnJS, [ k, 0 ]);
                if (lab == b) clickedId = cid;
                k = k + 1;
            }
            if (clickedId == "") return;

            string r = llList2Json(JSON_OBJECT,[]);
            r = llJsonSetValue(r, ["t"], "uicr");
            r = llJsonSetValue(r, ["ctx"], ctx);
            r = llJsonSetValue(r, ["tok"], tok);
            r = llJsonSetValue(r, ["from"], (string)id);
            r = llJsonSetValue(r, ["id"],  clickedId);
            r = llJsonSetValue(r, ["label"], b);
            r = llJsonSetValue(r, ["why"], "ok");
            llMessageLinked(LINK_SET, K_UI_CONFIRM_RESULT, r, plugin);

            /* remove */
            g_conf_rows = llDeleteSubList(g_conf_rows, i, i);
            integer jj = conf_find_by_av(id);
            if (jj != -1) g_conf_by_av = llDeleteSubList(g_conf_by_av, jj, jj);
            if (llGetListLength(g_conf_rows) == 0){
                if (gListenConfirm != 0){ llListenRemove(gListenConfirm); gListenConfirm = 0; }
            }
            return;
        }

        /* Regular hub dialogs (root/plugin pages) */
        if (chan != gChan) return;

        if (!withinRange(id)){
            closeDialog();
            llRegionSayTo(id, 0, "You moved too far from the wearer (max 5 m).");
            return;
        }

        /* close first to avoid double dialogs */
        closeDialog();

        /* Root page navigation */
        if (!g_inPlugin){
            if (b == BTN_NAV_LEFT){  navigateRoot(id, gPage - 1); return; }
            if (b == BTN_NAV_RIGHT){ navigateRoot(id, gPage + 1); return; }

            integer idx = llListFindList(g_pageMap, [b]);
            if (idx != -1){
                string ctx = llList2String(g_pageMap, idx + 1);
                requestPluginSchema(ctx, id);
                return;
            }

            showRoot(id, gPage);
            return;
        }

        /* Plugin subpage navigation / actions */
        if (g_inPlugin){
            /* Back to root */
            if (b == BTN_BACK){ showRoot(id, gPage); return; }

            /* Prev / Next paging for plugin */
            if (b == BTN_NAV_LEFT){  g_subPage = g_subPage - 1; showPluginPage(id); return; }
            if (b == BTN_NAV_RIGHT){ g_subPage = g_subPage + 1; showPluginPage(id); return; }

            /* Dispatch action (if label allowed) */
            integer ok = sendPluginAction(b, id);
            if (!ok){
                /* unknown or not allowed; re-open */
                showPluginPage(id);
                return;
            }
            /* after action, re-open the same page (plugin may also drive follow-ups) */
            showPluginPage(id);
            return;
        }
    }

    timer(){
        /* sweep confirm timeouts */
        conf_sweep_timeouts();
    }
}
