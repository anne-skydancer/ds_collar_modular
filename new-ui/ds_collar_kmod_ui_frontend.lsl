/* =============================================================
   ds_collar_kmod_ui_frontend.lsl — UI Controller (no llDialog)
   - ACL + registry filter, paging, plugin schema parsing
   - Compact Core→View payload (array of strings)
   - Persistent multi-entry schema cache per (context, ACL)
   - Invalidate on plugin_soft_reset or schema rev change
   - Reserved indices: 0=Prev, 1=Next, 2=Back, 3=Primary
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-CORE] " + s); return 0; }

/* ---------- External ABI (plugins & kernel) ---------- */
string  TYPE_PLUGIN_LIST       = "plugin_list";
integer K_PLUGIN_LIST_NUM      = 600;
integer K_PLUGIN_LIST_REQUEST  = 601;

integer K_UI_QUERY             = 620;  /* core → plugin: {"t":"uiq","ctx":...} */
integer K_UI_SCHEMA            = 621;  /* plugin → core: {"t":"uis","ctx":...,"r":mask,"rev":"...", "buttons":[...] } */
integer K_UI_ACTION            = 922;  /* core → plugin: {"t":"uia","ctx":...,"id":...,"lvl":<acl>,"ts":...} */

integer K_UI_CONFIRM           = 930;  /* plugin → core: {"t":"uic",...} (forward to view) */
integer K_UI_CONFIRM_RESULT    = 931;  /* view → plugin (unchanged) */
integer K_UI_CANCEL            = 932;  /* plugin → core: {"t":"uix","tok":...} (forward to view) */

/* ACL bridge */
integer K_ACLF_QUERY           = 640;  /* core → ACLF: {"t":"aclq","av":<key>} */
integer K_ACLF_REPLY           = 641;  /* ACLF → core: {"t":"aclr","av":<key>,"lvl":...,...} */

/* Legacy/notify */
integer K_PLUGIN_RETURN_NUM    = 901;
string  ROOT_CONTEXT           = "core_root";

/* NEW: plugin soft-reset → invalidate caches */
integer K_PLUGIN_SOFT_RESET    = 504;
string  TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";

/* ---------- Core↔View ABI ---------- */
integer K_VIEW_SHOW            = 960;  /* core → view: {"t":"show","to":<key>,"title":...,"body":...,"btn":[ "A","B",... ]} */
integer K_VIEW_CLOSE           = 961;  /* core → view: {"t":"close"} */
integer K_VIEW_CLICK           = 962;  /* view → core: {"t":"click","label":"..."} (id carries avatar key) */

integer K_VIEW_CONFIRM_OPEN    = 970;  /* core → view: {"t":"c_open","tok":...,"to":<key>,"prompt":...,"buttons":[[id,label],...],"ttl":20,"plug":<key>} */
integer K_VIEW_CONFIRM_CANCEL  = 971;  /* core → view: {"t":"c_cancel","tok":...} */

/* ---------- UI constants ---------- */
integer DIALOG_MAX_BTNS  = 12;
string  BTN_NAV_LEFT     = "<<";   /* index 0 if present */
string  BTN_NAV_RIGHT    = ">>";   /* index 1 if present */
string  BTN_BACK         = "Back"; /* index 2 on plugin pages */

integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

integer BTN_FLAG_PRIMARY = 1;

/* Limits and behavior toggles */
integer ROOT_CONTENT_CAP          = 9;    /* root labels per page (Prev/Next are extra) */
integer BTN_CAP_PER_PLUGIN        = 36;   /* max accepted buttons from a plugin schema */
integer AUTO_REFRESH_AFTER_ACTION = FALSE;/* hub re-opens after action if TRUE */

/* ---- Persistent schema cache (LRU) ----
   We store per (context|acl):
   - quadsJson:   '[[label,id,ord,flags], ...]' (trimmed, ACL-filtered)
   - rev:         plugin-provided rev or MD5 of buttons JSON
   - ts:          for LRU eviction
*/
list   gSC_keys     = [];  /* "ctx|acl" */
list   gSC_quadsJS  = [];  /* JSON string */
list   gSC_rev      = [];  /* string */
list   gSC_ts       = [];  /* integer timestamps */
integer SC_MAX      = 8;   /* max cached schemas */

/* ---------- Session/UI state ---------- */
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
/* Filtered view for current user: [label,context,...] */
list    g_view = [];
/* Current root page & map (for that page only) */
integer gPage = 0;
list    g_pageMap = [];

/* Plugin page state */
integer g_inPlugin = FALSE;
string  g_curCtx   = "";
/* Button quads for plugin page: [Label,Id,Ord,Flags,...] */
list    g_btnMap   = [];
integer g_subPage  = 0;

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
integer acl_mask_allows(integer mask, integer lvl){
    integer shifted = mask >> lvl;
    integer bit = shifted & 1;
    if (bit != 0) return TRUE;
    return FALSE;
}

/* ---------- Cache helpers ---------- */
string sc_key(string ctx, integer acl){ return ctx + "|" + (string)acl; }
integer sc_index(string kstr){
    return llListFindList(gSC_keys, [kstr]);
}
integer sc_put(string kstr, string quadsJS, string rev){
    integer idx = sc_index(kstr);
    integer now = llGetUnixTime();
    if (idx != -1){
        gSC_quadsJS = llListReplaceList(gSC_quadsJS, [quadsJS], idx, idx);
        gSC_rev     = llListReplaceList(gSC_rev,     [rev],     idx, idx);
        gSC_ts      = llListReplaceList(gSC_ts,      [now],     idx, idx);
        return 1;
    }
    /* LRU evict if needed */
    if (llGetListLength(gSC_keys) >= SC_MAX){
        /* find oldest ts */
        integer i = 0; integer n = llGetListLength(gSC_ts);
        integer minIdx = 0; integer minTs = llList2Integer(gSC_ts, 0);
        i = 1;
        while (i < n){
            integer t = llList2Integer(gSC_ts, i);
            if (t < minTs){ minTs = t; minIdx = i; }
            i = i + 1;
        }
        gSC_keys    = llDeleteSubList(gSC_keys,    minIdx, minIdx);
        gSC_quadsJS = llDeleteSubList(gSC_quadsJS, minIdx, minIdx);
        gSC_rev     = llDeleteSubList(gSC_rev,     minIdx, minIdx);
        gSC_ts      = llDeleteSubList(gSC_ts,      minIdx, minIdx);
    }
    gSC_keys    += kstr;
    gSC_quadsJS += quadsJS;
    gSC_rev     += rev;
    gSC_ts      += now;
    return 1;
}
integer sc_has(string kstr){ if (sc_index(kstr) != -1) return TRUE; return FALSE; }
string  sc_get_quadsJS(string kstr){ return llList2String(gSC_quadsJS, sc_index(kstr)); }
string  sc_get_rev(string kstr){     return llList2String(gSC_rev,     sc_index(kstr)); }
integer sc_touch(string kstr){
    integer idx = sc_index(kstr);
    if (idx == -1) return 0;
    gSC_ts = llListReplaceList(gSC_ts, [llGetUnixTime()], idx, idx);
    return 1;
}
integer sc_invalidate_ctx(string ctx){
    /* delete all entries where key starts with ctx + "|" */
    integer i = 0;
    while (i < llGetListLength(gSC_keys)){
        string k = llList2String(gSC_keys, i);
        if (llSubStringIndex(k, ctx + "|") == 0){
            gSC_keys    = llDeleteSubList(gSC_keys,    i, i);
            gSC_quadsJS = llDeleteSubList(gSC_quadsJS, i, i);
            gSC_rev     = llDeleteSubList(gSC_rev,     i, i);
            gSC_ts      = llDeleteSubList(gSC_ts,      i, i);
        } else {
            i = i + 1;
        }
    }
    return 1;
}

/* encode/decode QUADS to/from JSON for cache */
string quads_encode_json(list quads){
    string arr = "[]";
    integer i = 0; integer n = llGetListLength(quads);
    integer row = 0;
    while (i + 3 < n){
        string lab = llList2String(quads, i);
        string id  = llList2String(quads, i+1);
        string ord = llList2String(quads, i+2);
        string flg = llList2String(quads, i+3);
        arr = llJsonSetValue(arr, [row, 0], lab);
        arr = llJsonSetValue(arr, [row, 1], id);
        arr = llJsonSetValue(arr, [row, 2], ord);
        arr = llJsonSetValue(arr, [row, 3], flg);
        row = row + 1;
        i = i + 4;
    }
    return arr;
}
list quads_decode_json(string arr){
    list out = [];
    integer i = 0;
    while (llJsonValueType(arr, [i]) != JSON_INVALID){
        string lab = ""; string id = ""; string ord = "9999"; string flg = "0";
        if (llJsonValueType(arr, [i,0]) != JSON_INVALID) lab = llJsonGetValue(arr, [i,0]);
        if (llJsonValueType(arr, [i,1]) != JSON_INVALID) id  = llJsonGetValue(arr, [i,1]);
        if (llJsonValueType(arr, [i,2]) != JSON_INVALID) ord = llJsonGetValue(arr, [i,2]);
        if (llJsonValueType(arr, [i,3]) != JSON_INVALID) flg = llJsonGetValue(arr, [i,3]);
        if (lab != "" && id != "") out += [lab, id, ord, flg];
        i = i + 1;
    }
    return out;
}

/* ---------- Registry parsing ---------- */
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
            integer tpe_min = 999;   /* sentinel */
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

/* ---------- Visibility logic ---------- */
integer canSeePlugin(integer minAcl, integer hasTpe, integer tpeMin, string audience){
    if (gAcl <= ACL_BLACKLIST) return FALSE;

    if (gIsWearer){
        if (audience == "non_wearer_only") return FALSE;
    } else {
        if (audience == "wearer_only") return FALSE;
    }

    if (gIsWearer && pol_tpe){
        if (!hasTpe) return FALSE;
        if (tpeMin == 0) return TRUE; /* wearer TPE bucket */
        return FALSE;
    }

    if (pol_primary_owner){
        if (gAcl == ACL_PRIMARY_OWNER) return TRUE;
    }

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
    if (gAcl == ACL_OWNED){      if (minAcl <= ACL_OWNED)   return TRUE; else return FALSE; }
    if (gAcl == ACL_TRUSTEE){    if (minAcl <= ACL_TRUSTEE) return TRUE; else return FALSE; }
    if (gAcl == ACL_UNOWNED){    if (minAcl <= ACL_UNOWNED) return TRUE; else return FALSE; }
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
            if (gIsWearer && pol_tpe){
                if (labelTpe != "") shown = labelTpe;
            }
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
/* Build QUADS [Label,Id,Ord,Flags,...] from JSON "buttons" (id,label,mask,ord?,flags?) */
list buildBtnQuadsFromJSON(string uisMsg, integer viewerAcl){
    list out = [];
    integer i = 0;
    while (llJsonValueType(uisMsg, ["buttons", i]) != JSON_INVALID && i < BTN_CAP_PER_PLUGIN){
        string  id    = "";
        string  lab   = "";
        integer mask  = 0;
        integer ord   = 9999; /* optional */
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

/* Pull the first PRIMARY, keep others in plugin-declared order */
list splitPrimary(list quads){
    string primaryLabel = "";
    string primaryId    = "";
    list others = [];

    integer i = 0; integer n = llGetListLength(quads);
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

    /* reserved buttons: Back + maybe Prev/Next + maybe Primary */
    integer reservedAssume = 1; /* Back */
    reservedAssume = reservedAssume + 1; /* Prev? assume space */
    reservedAssume = reservedAssume + 1; /* Next? assume space */
    if (hasPrimary) reservedAssume = reservedAssume + 1;

    integer capacity = DIALOG_MAX_BTNS - reservedAssume;
    if (capacity < 0) capacity = 0;

    integer pages = 1;
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
    while (taken < capacity && (i + 1) < llGetListLength(others)){
        pagePairs += [ llList2String(others, i), llList2String(others, i + 1) ];
        taken = taken + 1; i = i + 2;
    }

    integer remaining = totalOthers - (start + taken);
    integer hasNext = FALSE; if (remaining > 0) hasNext = TRUE;

    /* If no Next, try to backfill additional slots (≤12 total) */
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
    if (hasPrimary){
        string safePrim = primaryLabel;
        if (safePrim == "") safePrim = " ";
        btns += safePrim;                /* index 3 */
    }

    i = 0;
    while (i + 1 < llGetListLength(pagePairs)){
        string lab = llList2String(pagePairs, i);
        if (lab == "") lab = " ";
        btns += lab;
        i = i + 2;
    }
    return btns; /* ≤ 12 */
}

/* ---------- Core→View helpers ---------- */
integer view_show(key to, string title, string body, list buttons){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["t"], "show");
    j = llJsonSetValue(j, ["to"], (string)to);
    j = llJsonSetValue(j, ["title"], title);
    j = llJsonSetValue(j, ["body"], body);

    /* array-of-strings (cheap) */
    string arr = "[]";
    integer i = 0; integer n = llGetListLength(buttons);
    while (i < n){
        arr = llJsonSetValue(arr, [i], llList2String(buttons, i));
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

/* Use cache if available; otherwise query plugin */
integer requestPluginSchema(string context, key opener){
    g_curCtx   = context;
    g_inPlugin = TRUE;
    g_subPage  = 0;

    string keySC = sc_key(context, gAcl);
    if (sc_has(keySC)){
        /* fast path: decode cached quads into g_btnMap */
        g_btnMap = quads_decode_json(sc_get_quadsJS(keySC));
        sc_touch(keySC);
        showPluginPage(opener);
        return 0;
    }

    g_btnMap = [];
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
        view_close();
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

        /* Plugin schema arrives */
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

            /* compute/normalize rev */
            string rev = "";
            if (json_has(msg, ["rev"])) rev = llJsonGetValue(msg, ["rev"]);
            else if (json_has(msg, ["buttons"])) rev = llMD5String(llJsonGetValue(msg, ["buttons"]), 0);

            /* build filtered quads */
            g_btnMap = buildBtnQuadsFromJSON(msg, gAcl);

            /* cache under (ctx|acl); if unchanged rev, just touch */
            string kstr = sc_key(g_curCtx, gAcl);
            if (sc_has(kstr)){
                string haveRev = sc_get_rev(kstr);
                if (rev != "" && haveRev != "" && haveRev == rev){
                    sc_touch(kstr);
                } else {
                    sc_put(kstr, quads_encode_json(g_btnMap), rev);
                }
            } else {
                sc_put(kstr, quads_encode_json(g_btnMap), rev);
            }

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
                if (AUTO_REFRESH_AFTER_ACTION){
                    showPluginPage(id);
                }
                return;
            }
        }

        /* Confirm open/cancel from plugins → forward to View */
        if (num == K_UI_CONFIRM){
            if (!json_has(msg,["t"])) return;
            if (llJsonGetValue(msg,["t"]) != "uic") return;

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
            v = llJsonSetValue(v, ["plug"], (string)id);
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

        /* Invalidate caches on soft-reset from plugin */
        if (num == K_PLUGIN_SOFT_RESET){
            if (json_has(msg, ["type"])){
                if (llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_SOFT_RESET){
                    if (json_has(msg, ["context"])){
                        string ctx = llJsonGetValue(msg, ["context"]);
                        sc_invalidate_ctx(ctx);
                        logd("Cache invalidated for context: " + ctx);
                    }
                }
            }
            return;
        }
    }
}
