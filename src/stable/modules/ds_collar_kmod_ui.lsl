/* =============================================================
   MODULE:  ds_collar_kmod_ui.lsl  (AUTH-driven + dual display)
   ROLE  :  Root UI, paged. Policy belongs to AUTH; UI only filters.
   INPUT :  Registry rows may include optional:
              - tpe_min_acl (int)
              - label_tpe (string)
              - audience: "all"|"wearer_only"|"non_wearer_only"
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI] " + s); return 0; }

/* ---------- Protocol strings ---------- */
string TYPE_PLUGIN_LIST   = "plugin_list";
string TYPE_PLUGIN_RETURN = "plugin_return";
string TYPE_PLUGIN_START  = "plugin_start";
string MSG_ACL_QUERY      = "acl_query";
string MSG_ACL_RESULT     = "acl_result";

/* ---------- Link numbers ---------- */
integer AUTH_QUERY_NUM        = 700;
integer AUTH_RESULT_NUM       = 710;
integer K_PLUGIN_LIST_NUM     = 600;
integer K_PLUGIN_LIST_REQUEST = 601;
integer K_PLUGIN_START_NUM    = 900;
integer K_PLUGIN_RETURN_NUM   = 901;

/* ---------- UI ---------- */
string ROOT_CONTEXT      = "core_root";
integer MAX_FUNC_BTNS    = 9;
float   TOUCH_RANGE_M    = 5.0;

string BTN_NAV_LEFT  = "<<";
string BTN_NAV_GAP   = " ";
string BTN_NAV_RIGHT = ">>";

/* ---------- State ---------- */
/* Flattened registry: [label,context,min_acl,has_tpe,label_tpe,tpe_min_acl,audience,...] */
list    g_all = [];
/* Filtered for current viewer: [label,context,...] */
list    g_view = [];
/* Map label→context for current page */
list    g_pageMap = [];

key     gUser      = NULL_KEY;
integer gListen    = 0;
integer gChan      = 0;
integer gPage      = 0;
integer dialogOpen = FALSE;

/* ACL + policy from AUTH */
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

/* ---------- Helpers ---------- */
integer withinRange(key av){
    if (av == NULL_KEY) return FALSE;
    list d = llGetObjectDetails(av,[OBJECT_POS]);
    if (llGetListLength(d) < 1) return FALSE;
    vector pos = llList2Vector(d,0);
    if (pos == ZERO_VECTOR) return FALSE;
    float dist = llVecDist(llGetPos(), pos);
    if (dist <= TOUCH_RANGE_M) return TRUE;
    return FALSE;
}

/* Registry parser: tolerant defaults, compact storage */
parseRegistry(string j){
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
}

/* Build filtered view for the current user under AUTH flags */
list filterForViewer(){
    list out = [];
    integer i = 0;
    integer n = llGetListLength(g_all);

    while (i + 6 < n){
        string  label    = llList2String (g_all, i);
        string  context  = llList2String (g_all, i + 1);
        integer minAcl   = llList2Integer(g_all, i + 2);
        integer hasTpe   = llList2Integer(g_all, i + 3);
        string  labelTpe = llList2String (g_all, i + 4);
        integer tpeMin   = llList2Integer(g_all, i + 5);
        string  audience = llList2String (g_all, i + 6);

        integer include = TRUE;

        /* audience gate */
        if (gIsWearer){
            if (audience == "non_wearer_only") include = FALSE;
        } else {
            if (audience == "wearer_only") include = FALSE;
        }

        /* ACL -1 is handled by caller; still guard */
        if (gAcl < 0) include = FALSE;

        if (include){
            /* Wearer under TPE: only items that explicitly opt in with tpe_min_acl==0 */
            if (gIsWearer && pol_tpe){
                if (hasTpe){
                    if (tpeMin == 0){
                        /* ok */
                    } else {
                        include = FALSE;
                    }
                } else {
                    include = FALSE;
                }
            } else {
                /* Non-TPE paths */
                if (!gIsWearer){
                    /* Touchers */
                    if (pol_public_only && gAcl <= 1){
                        if (minAcl == 1){
                            /* ok */
                        } else {
                            include = FALSE;
                        }
                    } else {
                        /* Trustee / owner levels retain full <= ACL visibility */
                        if (minAcl <= gAcl){
                            /* ok */
                        } else {
                            include = FALSE;
                        }
                    }
                } else {
                    /* Wearer, not TPE */
                    if (pol_owned_only){
                        if (minAcl <= 2){
                            /* ok */
                        } else {
                            include = FALSE;
                        }
                    } else if (pol_wearer_unowned){
                        if (minAcl <= 4){
                            /* ok */
                        } else {
                            include = FALSE;
                        }
                    } else {
                        /* safety fallback for wearer when no policy flags set */
                        if (minAcl <= gAcl){
                            /* ok */
                        } else {
                            include = FALSE;
                        }
                    }
                }
            }
        }

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

integer pageCount(){
    integer total = llGetListLength(g_view) / 2;
    integer pages = 0;
    if (total <= 0) pages = 1;
    else {
        if ((total % MAX_FUNC_BTNS) == 0) pages = total / MAX_FUNC_BTNS;
        else pages = (total / MAX_FUNC_BTNS) + 1;
        if (pages < 1) pages = 1;
    }
    return pages;
}

list buttonsForPage(integer page){
    g_pageMap = [];
    list btns = [];

    integer totalPairs = llGetListLength(g_view) / 2;
    integer pages = pageCount();
    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;

    integer startPair = page * MAX_FUNC_BTNS;
    integer endPair   = startPair + MAX_FUNC_BTNS - 1;
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

    if (pages > 1){
        string L = BTN_NAV_GAP;
        string R = BTN_NAV_GAP;
        if (page > 0) L = BTN_NAV_LEFT;
        if (page < pages - 1) R = BTN_NAV_RIGHT;
        btns = [L, BTN_NAV_GAP, R] + btns;
    }
    return btns;
}

openDialog(key to, string title, string body, list buttons){
    if (gListen) llListenRemove(gListen);
    dialogOpen = TRUE;
    gChan   = -100000 - (integer)llFrand(1000000.0);
    gListen = llListen(gChan, "", to, "");
    llDialog(to, title + "\n" + body, buttons, gChan);
}

closeDialog(){
    if (gListen){
        llListenRemove(gListen);
        gListen = 0;
    }
    dialogOpen = FALSE;
}

showRoot(key who, integer page){
    integer total = llGetListLength(g_view) / 2;
    if (total <= 0){
        llRegionSayTo(who, 0, "No plugins available.");
        return;
    }
    integer pages = pageCount();
    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;
    gPage = page;

    list b = buttonsForPage(gPage);
    string body = "Select a function (Page " + (string)(gPage + 1) + "/" + (string)pages + ")";
    openDialog(who, "• DS Collar •", body, b);
}

navigate(key who, integer newPage){
    integer pages = pageCount();
    if (pages <= 0) pages = 1;
    if (newPage < 0) newPage = pages - 1;
    if (newPage >= pages) newPage = 0;
    gPage = newPage;

    list b = buttonsForPage(gPage);
    string body = "Select a function (Page " + (string)(gPage + 1) + "/" + (string)pages + ")";
    openDialog(who, "• DS Collar •", body, b);
}

startPlugin(string context, key who){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j,["type"], TYPE_PLUGIN_START);
    j = llJsonSetValue(j,["context"], context);
    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, j, who);
}

/* ---------- Async calls ---------- */
queryAcl(key user){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j,["type"], MSG_ACL_QUERY);
    j = llJsonSetValue(j,["avatar"], (string)user);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
}
fetchRegistry(){ llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY); }

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

        gAcl = -1; gAclReady = FALSE; gListReady = FALSE;
        gIsWearer = FALSE; gOwnerSet = FALSE;

        pol_tpe = FALSE; pol_public_only = FALSE; pol_owned_only = FALSE;
        pol_trustee_access = FALSE; pol_wearer_unowned = FALSE; pol_primary_owner = FALSE;
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
        if (num == AUTH_RESULT_NUM){
            if (llJsonValueType(msg,["type"]) == JSON_INVALID) return;
            if (llJsonGetValue(msg,["type"]) != MSG_ACL_RESULT) return;

            key av = (key)llJsonGetValue(msg,["avatar"]);
            if (av == NULL_KEY) return;
            if (av != gUser) return;

            gAcl = (integer)llJsonGetValue(msg,["level"]);
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

        if (num == K_PLUGIN_RETURN_NUM){
            if (llJsonValueType(msg,["context"]) != JSON_INVALID){
                string ctx = llJsonGetValue(msg,["context"]);
                if (ctx == ROOT_CONTEXT) showRoot(gUser, gPage);
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string b){
        if (chan != gChan) return;

        if (!withinRange(id)){
            closeDialog();
            llRegionSayTo(id, 0, "You moved too far from the wearer (max 5 m).");
            return;
        }

        /* close first to avoid double dialogs */
        closeDialog();

        if (b == BTN_NAV_LEFT){  navigate(id, gPage - 1); return; }
        if (b == BTN_NAV_RIGHT){ navigate(id, gPage + 1); return; }
        if (b == BTN_NAV_GAP){   showRoot(id, gPage);     return; }

        integer idx = llListFindList(g_pageMap, [b]);
        if (idx != -1){
            string ctx = llList2String(g_pageMap, idx + 1);
            startPlugin(ctx, id);
            return;
        }

        showRoot(id, gPage);
    }
}
