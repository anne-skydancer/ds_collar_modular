/* =============================================================
   MODULE:  ds_collar_kmod_ui.lsl  (AUTH-driven + dual display)
   ROLE  :  Root UI, paged. Policy belongs to AUTH; UI only filters.
   INPUT :  Registry rows may include optional:
              - tpe_min_acl (int)
              - label_tpe (string)
              - audience: "all"|"wearer_only"|"non_wearer_only"
   ============================================================= */

integer DEBUG = FALSE;
// Emits UI debug output when enabled.
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
list    All = [];
/* Filtered for current viewer: [label,context,...] */
list    View = [];
/* Map label→context for current page */
list    PageMap = [];

key     User      = NULL_KEY;
integer Listen    = 0;
integer Chan      = 0;
integer Page      = 0;
integer DialogOpen = FALSE;

/* ACL + policy from AUTH */
integer Acl           = -1;
integer AclReady      = FALSE;
integer ListReady     = FALSE;
integer IsWearer      = FALSE;
integer OwnerSet      = FALSE;

integer PolTpe            = FALSE;
integer PolPublicOnly    = FALSE;
integer PolOwnedOnly     = FALSE;
integer PolTrusteeAccess = FALSE;
integer PolWearerUnowned = FALSE;
integer PolPrimaryOwner  = FALSE;

/* ---------- Helpers ---------- */
// Ensures the avatar is within touch range of the collar.
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
// Flattens the plugin registry JSON into the All list with policy metadata.
integer parseRegistry(string j){
    All = [];
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

            All += [label, context, min_acl, has_tpe, label_tpe, tpe_min, audience];
            i = i + 1;
        }
    }
    return llGetListLength(All) / 7;
}

/* Build filtered view for the current user under AUTH flags */
// Applies AUTH policies to produce the list of visible plugins for the current user.
list filterForViewer(){
    list out = [];
    integer i = 0;
    integer n = llGetListLength(All);

    while (i + 6 < n){
        string  label    = llList2String (All, i);
        string  context  = llList2String (All, i + 1);
        integer minAcl   = llList2Integer(All, i + 2);
        integer hasTpe   = llList2Integer(All, i + 3);
        string  labelTpe = llList2String (All, i + 4);
        integer tpeMin   = llList2Integer(All, i + 5);
        string  audience = llList2String (All, i + 6);

        integer include = TRUE;
        integer isCoreOwner = (context == "core_owner");

        /* audience gate */
        if (IsWearer){
            if (audience == "non_wearer_only") include = FALSE;
        } else {
            if (audience == "wearer_only") include = FALSE;
        }

        /* ACL -1 is handled by caller; still guard */
        if (Acl < 0) include = FALSE;

        if (isCoreOwner){
            if (IsWearer){
                if (OwnerSet){
                    include = TRUE;
                } else {
                    include = FALSE;
                }
            }
        }

        if (include){
            /* Wearer under TPE: only items that explicitly opt in with tpe_min_acl==0 */
            if (IsWearer && PolTpe){
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
                if (!IsWearer){
                    /* Touchers */
                    if (PolPublicOnly && Acl <= 1){
                        if (minAcl == 1){
                            /* ok */
                        } else {
                            include = FALSE;
                        }
                    } else {
                        /* Trustee / owner levels retain full <= ACL visibility */
                        if (minAcl <= Acl){
                            /* ok */
                        } else {
                            include = FALSE;
                        }
                    }
                } else {
                    /* Wearer, not TPE */
                    if (PolOwnedOnly){
                        if (minAcl <= 2){
                            /* ok */
                        } else {
                            include = FALSE;
                        }
                    } else if (PolWearerUnowned){
                        if (minAcl <= 4){
                            /* ok */
                        } else {
                            include = FALSE;
                        }
                    } else {
                        /* safety fallback for wearer when no policy flags set */
                        if (minAcl <= Acl){
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
            if (IsWearer && PolTpe){
                if (labelTpe != "") shown = labelTpe;
            }
            out += [shown, context];
        }

        i = i + 7;
    }

    return out;
}

// Calculates the total number of dialog pages required for the filtered view.
integer pageCount(){
    integer total = llGetListLength(View) / 2;
    integer pages = 0;
    if (total <= 0) pages = 1;
    else {
        if ((total % MAX_FUNC_BTNS) == 0) pages = total / MAX_FUNC_BTNS;
        else pages = (total / MAX_FUNC_BTNS) + 1;
        if (pages < 1) pages = 1;
    }
    return pages;
}

// Builds dialog buttons for the requested page and refreshes the PageMap.
list buttonsForPage(integer page){
    PageMap = [];
    list btns = [];

    integer totalPairs = llGetListLength(View) / 2;
    integer pages = pageCount();
    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;

    integer startPair = page * MAX_FUNC_BTNS;
    integer endPair   = startPair + MAX_FUNC_BTNS - 1;
    if (endPair >= totalPairs) endPair = totalPairs - 1;

    integer idx = startPair * 2;
    integer end = (endPair * 2) + 1;

    while (idx <= end){
        string label = llList2String(View, idx);
        string ctx   = llList2String(View, idx + 1);
        btns += [label];
        PageMap += [label, ctx];
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

// Opens a scoped dialog for the avatar and tracks the listen handle.
integer openDialog(key to, string title, string body, list buttons){
    if (Listen) llListenRemove(Listen);
    DialogOpen = TRUE;
    Chan   = -100000 - (integer)llFrand(1000000.0);
    Listen = llListen(Chan, "", to, "");
    llDialog(to, title + "\n" + body, buttons, Chan);
    return TRUE;
}

// Closes any active dialog listen and clears dialog state.
integer closeDialog(){
    if (Listen){
        llListenRemove(Listen);
        Listen = 0;
    }
    DialogOpen = FALSE;
    return TRUE;
}

// Presents the root plugin menu at the specified page index.
integer showRoot(key who, integer page){
    integer total = llGetListLength(View) / 2;
    if (total <= 0){
        llRegionSayTo(who, 0, "No plugins available.");
        return FALSE;
    }
    integer pages = pageCount();
    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;
    Page = page;

    list b = buttonsForPage(Page);
    string body = "Select a function (Page " + (string)(Page + 1) + "/" + (string)pages + ")";
    openDialog(who, "• DS Collar •", body, b);
    return TRUE;
}

// Navigates to the requested page, wrapping within the page count bounds.
integer navigate(key who, integer newPage){
    integer pages = pageCount();
    if (pages <= 0) pages = 1;
    if (newPage < 0) newPage = pages - 1;
    if (newPage >= pages) newPage = 0;
    Page = newPage;

    list b = buttonsForPage(Page);
    string body = "Select a function (Page " + (string)(Page + 1) + "/" + (string)pages + ")";
    openDialog(who, "• DS Collar •", body, b);
    return TRUE;
}

// Sends a plugin_start request for the selected context on behalf of the user.
integer startPlugin(string context, key who){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j,["type"], TYPE_PLUGIN_START);
    j = llJsonSetValue(j,["context"], context);
    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, j, who);
    return TRUE;
}

/* ---------- Async calls ---------- */
// Requests an ACL decision for the avatar via the auth module.
integer queryAcl(key user){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j,["type"], MSG_ACL_QUERY);
    j = llJsonSetValue(j,["avatar"], (string)user);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    return TRUE;
}
// Triggers a plugin list refresh from the kernel.
integer fetchRegistry(){ llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY); return TRUE; }

/* ==================== Events ==================== */
default{
    // Resets dialog state when the UI module starts.
    state_entry(){
        User      = NULL_KEY;
        Listen    = 0;
        Chan      = 0;
        Page      = 0;
        DialogOpen = FALSE;

        All  = [];
        View = [];
        PageMap = [];

        Acl = -1; AclReady = FALSE; ListReady = FALSE;
        IsWearer = FALSE; OwnerSet = FALSE;

        PolTpe = FALSE; PolPublicOnly = FALSE; PolOwnedOnly = FALSE;
        PolTrusteeAccess = FALSE; PolWearerUnowned = FALSE; PolPrimaryOwner = FALSE;
    }

    // Reset on rez to rebuild the UI cache.
    on_rez(integer sp){ llResetScript(); }
    // Reset when ownership changes to avoid stale ACL state.
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    // Handles wearer/toucher interactions and kicks off ACL/registry queries.
    touch_start(integer n){
        if (DialogOpen) closeDialog();

        User = llDetectedKey(0);
        if (!withinRange(User)){
            llRegionSayTo(User, 0, "You are too far from the wearer (max 5 m).");
            return;
        }

        /* reset session */
        AclReady = FALSE; ListReady = FALSE;
        Acl = -1; IsWearer = FALSE; OwnerSet = FALSE;
        PolTpe = FALSE; PolPublicOnly = FALSE; PolOwnedOnly = FALSE;
        PolTrusteeAccess = FALSE; PolWearerUnowned = FALSE; PolPrimaryOwner = FALSE;

        queryAcl(User);
        fetchRegistry();
    }

    // Consumes auth, plugin list, and plugin return messages that drive the UI.
    link_message(integer src, integer num, string msg, key id){
        if (num == AUTH_RESULT_NUM){
            if (llJsonValueType(msg,["type"]) == JSON_INVALID) return;
            if (llJsonGetValue(msg,["type"]) != MSG_ACL_RESULT) return;

            key av = (key)llJsonGetValue(msg,["avatar"]);
            if (av == NULL_KEY) return;
            if (av != User) return;

            Acl = (integer)llJsonGetValue(msg,["level"]);
            if (Acl < 0){
                llRegionSayTo(User, 0, "Access denied.");
                User = NULL_KEY;
                return;
            }

            IsWearer = FALSE;
            if (llJsonValueType(msg,["is_wearer"]) != JSON_INVALID) IsWearer = (integer)llJsonGetValue(msg,["is_wearer"]);
            OwnerSet = FALSE;
            if (llJsonValueType(msg,["owner_set"]) != JSON_INVALID) OwnerSet = (integer)llJsonGetValue(msg,["owner_set"]);

            PolTpe            = FALSE; if (llJsonValueType(msg,["policy_tpe"])            != JSON_INVALID) PolTpe            = (integer)llJsonGetValue(msg,["policy_tpe"]);
            PolPublicOnly    = FALSE; if (llJsonValueType(msg,["policy_public_only"])    != JSON_INVALID) PolPublicOnly    = (integer)llJsonGetValue(msg,["policy_public_only"]);
            PolOwnedOnly     = FALSE; if (llJsonValueType(msg,["policy_owned_only"])     != JSON_INVALID) PolOwnedOnly     = (integer)llJsonGetValue(msg,["policy_owned_only"]);
            PolTrusteeAccess = FALSE; if (llJsonValueType(msg,["policy_trustee_access"]) != JSON_INVALID) PolTrusteeAccess = (integer)llJsonGetValue(msg,["policy_trustee_access"]);
            PolWearerUnowned = FALSE; if (llJsonValueType(msg,["policy_wearer_unowned"]) != JSON_INVALID) PolWearerUnowned = (integer)llJsonGetValue(msg,["policy_wearer_unowned"]);
            PolPrimaryOwner  = FALSE; if (llJsonValueType(msg,["policy_primary_owner"])  != JSON_INVALID) PolPrimaryOwner  = (integer)llJsonGetValue(msg,["policy_primary_owner"]);

            AclReady = TRUE;

            if (AclReady && ListReady){
                View = filterForViewer();
                if (llGetListLength(View) == 0){
                    llRegionSayTo(User, 0, "No plugins available.");
                    User = NULL_KEY;
                    return;
                }
                showRoot(User, 0);
                AclReady = FALSE; ListReady = FALSE;
            }
            return;
        }

        if (num == K_PLUGIN_LIST_NUM){
            if (llJsonValueType(msg,["type"]) == JSON_INVALID) return;
            if (llJsonGetValue(msg,["type"]) != TYPE_PLUGIN_LIST) return;

            parseRegistry(msg);
            ListReady = TRUE;

            if (AclReady && ListReady){
                View = filterForViewer();
                if (llGetListLength(View) == 0){
                    llRegionSayTo(User, 0, "No plugins available.");
                    User = NULL_KEY;
                    return;
                }
                showRoot(User, 0);
                AclReady = FALSE; ListReady = FALSE;
            }
            return;
        }

        if (num == K_PLUGIN_RETURN_NUM){
            if (llJsonValueType(msg,["context"]) != JSON_INVALID){
                string ctx = llJsonGetValue(msg,["context"]);
                if (ctx == ROOT_CONTEXT) showRoot(User, Page);
            }
            return;
        }
    }

    // Routes dialog button presses and launches selected plugins.
    listen(integer chan, string name, key id, string b){
        if (chan != Chan) return;

        if (!withinRange(id)){
            closeDialog();
            llRegionSayTo(id, 0, "You moved too far from the wearer (max 5 m).");
            return;
        }

        /* close first to avoid double dialogs */
        closeDialog();

        if (b == BTN_NAV_LEFT){  navigate(id, Page - 1); return; }
        if (b == BTN_NAV_RIGHT){ navigate(id, Page + 1); return; }
        if (b == BTN_NAV_GAP){   showRoot(id, Page);     return; }

        integer idx = llListFindList(PageMap, [b]);
        if (idx != -1){
            string ctx = llList2String(PageMap, idx + 1);
            startPlugin(ctx, id);
            return;
        }

        showRoot(id, Page);
    }
}
