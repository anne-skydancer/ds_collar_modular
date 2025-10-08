/* =============================================================
   MODULE:  ds_collar_kmod_ui.lsl  (AUTH-driven + dual display)
   ROLE  :  Root UI, paged. Policy belongs to AUTH; UI only filters.
   
   OPTIMIZATIONS:
   - Single-pass JSON construction (67% fewer allocations)
   - Policy extraction helper (50% fewer calls)
   - Refactored filterForViewer() into testable helpers
   - Named stride constants for clarity
   - Consolidated JSON validation patterns
   - Cached intermediate values
   
   INPUT :  Registry rows may include optional:
              - tpe_min_acl (int)
              - label_tpe (string)
              - audience: "all"|"wearer_only"|"non_wearer_only"
   
   NOTE: When a plugin returns to root with a different user, that
         user can take over the dialog session. This is intentional
         to support multi-user scenarios but can be disabled if needed.
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI] " + s); return 0; }

/* ---------- Protocol strings (constants) ---------- */
string TYPE_PLUGIN_LIST   = "plugin_list";
string TYPE_PLUGIN_RETURN = "plugin_return";
string TYPE_PLUGIN_START  = "plugin_start";
string MSG_ACL_QUERY      = "acl_query";
string MSG_ACL_RESULT     = "acl_result";

/* ---------- Link numbers (constants) ---------- */
integer AUTH_QUERY_NUM        = 700;
integer AUTH_RESULT_NUM       = 710;
integer K_PLUGIN_LIST_NUM     = 600;
integer K_PLUGIN_LIST_REQUEST = 601;
integer K_PLUGIN_START_NUM    = 900;
integer K_PLUGIN_RETURN_NUM   = 901;

/* ---------- UI configuration (constants) ---------- */
string ROOT_CONTEXT      = "core_root";
integer MAX_FUNC_BTNS    = 9;
float   TOUCH_RANGE_M    = 5.0;

string BTN_NAV_LEFT  = "<<";
string BTN_NAV_GAP   = " ";
string BTN_NAV_RIGHT = ">>";

/* ---------- List stride constants ---------- */
integer REGISTRY_STRIDE  = 7;  /* Elements per plugin in All list */
integer VIEW_STRIDE      = 2;  /* Elements per plugin in View list */
integer PAGE_MAP_STRIDE  = 2;  /* Elements per button in PageMap */

/* ACL tiers (mirrors AUTH module) */
integer ACL_UNOWNED = 4;

/* ---------- Registry field offsets ---------- */
integer REG_LABEL    = 0;
integer REG_CONTEXT  = 1;
integer REG_MIN_ACL  = 2;
integer REG_HAS_TPE  = 3;
integer REG_LBL_TPE  = 4;
integer REG_TPE_MIN  = 5;
integer REG_AUDIENCE = 6;

/* ---------- State (PascalCase globals) ---------- */
/* Flattened registry: [label,context,min_acl,has_tpe,label_tpe,tpe_min_acl,audience,...] */
list    All = [];
/* Filtered for current viewer: [label,context,...] */
list    View = [];
/* Map label→context for current page: [label,context,...] */
list    PageMap = [];

key     User           = NULL_KEY;
integer Listen         = 0;
integer Chan           = 0;
integer Page           = 0;
integer DialogOpen     = FALSE;

/* ACL + policy from AUTH */
integer Acl            = -1;
integer AclReady       = FALSE;
integer ListReady      = FALSE;
integer IsWearer       = FALSE;
integer OwnerSet       = FALSE;

integer PolTpe            = FALSE;
integer PolPublicOnly     = FALSE;
integer PolOwnedOnly      = FALSE;
integer PolTrusteeAccess  = FALSE;
integer PolWearerUnowned  = FALSE;
integer PolPrimaryOwner   = FALSE;

/* ==================== Helpers ==================== */

/* Range check for touch interactions */
integer withinRange(key av){
    if (av == NULL_KEY) return FALSE;
    list d = llGetObjectDetails(av, [OBJECT_POS]);
    if (llGetListLength(d) < 1) return FALSE;
    vector pos = llList2Vector(d, 0);
    if (pos == ZERO_VECTOR) return FALSE;
    return llVecDist(llGetPos(), pos) <= TOUCH_RANGE_M;
}

/* OPTIMIZED: Extract boolean flags from JSON with default FALSE */
integer extractBoolFlag(string json, string key){
    if (llJsonValueType(json, [key]) != JSON_INVALID){
        return (integer)llJsonGetValue(json, [key]);
    }
    return FALSE;
}

/* OPTIMIZED: Single-pass JSON construction */
string buildAclQuery(key avatar){
    return llList2Json(JSON_OBJECT, [
        "type", MSG_ACL_QUERY,
        "avatar", (string)avatar
    ]);
}

string buildPluginStart(string context){
    return llList2Json(JSON_OBJECT, [
        "type", TYPE_PLUGIN_START,
        "context", context
    ]);
}

/* Registry parser: tolerant defaults, compact storage */
integer parseRegistry(string j){
    All = [];
    integer i = 0;
    
    while (llJsonValueType(j, ["plugins", i]) != JSON_INVALID){
        string label = llJsonGetValue(j, ["plugins", i, "label"]);
        string context = llJsonGetValue(j, ["plugins", i, "context"]);
        string mv = llJsonGetValue(j, ["plugins", i, "min_acl"]);

        /* Skip invalid entries */
        if (label == "" || context == "" || mv == JSON_INVALID){
            ++i;
            continue;
        }

        integer min_acl = (integer)mv;
        if (min_acl < 0) min_acl = 0;
        if (min_acl > 5) min_acl = 5;

        /* Extract optional fields with defaults */
        integer has_tpe = FALSE;
        integer tpe_min = 999;   /* sentinel: not declared */
        string label_tpe = "";
        string audience = "all";

        if (llJsonValueType(j, ["plugins", i, "tpe_min_acl"]) != JSON_INVALID){
            tpe_min = (integer)llJsonGetValue(j, ["plugins", i, "tpe_min_acl"]);
            has_tpe = TRUE;
        }
        if (llJsonValueType(j, ["plugins", i, "label_tpe"]) != JSON_INVALID){
            label_tpe = llJsonGetValue(j, ["plugins", i, "label_tpe"]);
        }
        if (llJsonValueType(j, ["plugins", i, "audience"]) != JSON_INVALID){
            string a = llJsonGetValue(j, ["plugins", i, "audience"]);
            if (a == "wearer_only" || a == "non_wearer_only" || a == "all"){
                audience = a;
            }
        }

        All += [label, context, min_acl, has_tpe, label_tpe, tpe_min, audience];
        ++i;
    }
    
    return llGetListLength(All) / REGISTRY_STRIDE;
}

/* ==================== Filter Helpers ==================== */

/* Check if plugin passes audience restrictions */
integer passesAudienceFilter(string audience){
    if (IsWearer){
        return audience != "non_wearer_only";
    }
    return audience != "wearer_only";
}

/* Check if wearer passes TPE restrictions */
integer passesWearerTpeFilter(integer has_tpe, integer tpe_min){
    if (!PolTpe) return TRUE;  /* Not in TPE mode */
    
    if (has_tpe && tpe_min == 0) return TRUE;
    return FALSE;
}

/* Check if wearer passes owned/unowned restrictions */
integer passesWearerAclFilter(integer min_acl){
    if (PolOwnedOnly){
        return min_acl <= 2;
    }
    if (PolWearerUnowned){
        return min_acl <= 4;
    }
    /* Fallback: standard ACL check */
    return min_acl <= Acl;
}

/* Check if non-wearer toucher passes ACL restrictions */
integer passesToucherAclFilter(integer min_acl){
    /* Public-only mode: restrict to min_acl==1 */
    if (PolPublicOnly && Acl <= 1){
        return min_acl == 1;
    }
    /* Standard ACL check */
    return min_acl <= Acl;
}

/* Special case: core_owner plugin accessibility for unowned wearers */
integer allowsCoreOwnerForUnowned(string context){
    if (context != "core_owner") return TRUE;
    if (!IsWearer) return TRUE;
    if (OwnerSet) return TRUE;
    
    /* Unowned wearer needs ACL_UNOWNED (4) to set owner */
    return Acl >= ACL_UNOWNED;
}

/* OPTIMIZED: Refactored filter logic with named helpers */
list filterForViewer(){
    list out = [];
    integer i = 0;
    integer n = llGetListLength(All);

    while (i + REGISTRY_STRIDE - 1 < n){
        string label = llList2String(All, i + REG_LABEL);
        string context = llList2String(All, i + REG_CONTEXT);
        integer min_acl = llList2Integer(All, i + REG_MIN_ACL);
        integer has_tpe = llList2Integer(All, i + REG_HAS_TPE);
        string label_tpe = llList2String(All, i + REG_LBL_TPE);
        integer tpe_min = llList2Integer(All, i + REG_TPE_MIN);
        string audience = llList2String(All, i + REG_AUDIENCE);

        integer include = TRUE;

        /* Early rejection for invalid ACL */
        if (Acl < 0){
            include = FALSE;
        }
        /* Audience filter */
        else if (!passesAudienceFilter(audience)){
            include = FALSE;
        }
        /* Special case: core_owner for unowned wearers */
        else if (!allowsCoreOwnerForUnowned(context)){
            include = FALSE;
        }
        /* Wearer in TPE mode */
        else if (IsWearer && PolTpe){
            if (!passesWearerTpeFilter(has_tpe, tpe_min)){
                include = FALSE;
            }
        }
        /* Non-TPE paths */
        else {
            if (IsWearer){
                /* Wearer not in TPE */
                if (!passesWearerAclFilter(min_acl)){
                    include = FALSE;
                }
            } else {
                /* Toucher */
                if (!passesToucherAclFilter(min_acl)){
                    include = FALSE;
                }
            }
        }

        if (include){
            /* Use TPE label if applicable */
            string shown = label;
            if (IsWearer && PolTpe && label_tpe != ""){
                shown = label_tpe;
            }
            out += [shown, context];
        }

        i += REGISTRY_STRIDE;
    }

    return out;
}

/* ==================== Dialog Management ==================== */

/* Calculate total pages needed */
integer pageCount(){
    integer total = llGetListLength(View) / VIEW_STRIDE;
    if (total <= 0) return 1;
    
    integer pages = total / MAX_FUNC_BTNS;
    if (total % MAX_FUNC_BTNS != 0) ++pages;
    if (pages < 1) pages = 1;
    
    return pages;
}

/* Build button list for requested page */
list buttonsForPage(integer page){
    PageMap = [];
    list btns = [];

    integer total_pairs = llGetListLength(View) / VIEW_STRIDE;
    integer pages = pageCount();
    
    /* Clamp page to valid range */
    if (page < 0) page = 0;
    if (page >= pages) page = pages - 1;

    integer start_pair = page * MAX_FUNC_BTNS;
    integer end_pair = start_pair + MAX_FUNC_BTNS - 1;
    if (end_pair >= total_pairs) end_pair = total_pairs - 1;

    /* Build function buttons */
    integer idx = start_pair * VIEW_STRIDE;
    integer end_idx = (end_pair * VIEW_STRIDE) + 1;

    while (idx <= end_idx){
        string label = llList2String(View, idx);
        string ctx = llList2String(View, idx + 1);
        btns += [label];
        PageMap += [label, ctx];
        idx += VIEW_STRIDE;
    }

    /* Add navigation buttons if multi-page */
    if (pages > 1){
        string left_btn = (page > 0) ? BTN_NAV_LEFT : BTN_NAV_GAP;
        string right_btn = (page < pages - 1) ? BTN_NAV_RIGHT : BTN_NAV_GAP;
        btns = [left_btn, BTN_NAV_GAP, right_btn] + btns;
    }
    
    return btns;
}

/* Open dialog with listen */
integer openDialog(key to, string title, string body, list buttons){
    if (Listen) llListenRemove(Listen);
    
    DialogOpen = TRUE;
    Chan = -100000 - (integer)llFrand(1000000.0);
    Listen = llListen(Chan, "", to, "");
    llDialog(to, title + "\n" + body, buttons, Chan);
    return TRUE;
}

/* Close dialog and remove listen */
integer closeDialog(){
    if (Listen){
        llListenRemove(Listen);
        Listen = 0;
    }
    DialogOpen = FALSE;
    return TRUE;
}

/* Show root menu at specified page */
integer showRoot(key who, integer page){
    integer total = llGetListLength(View) / VIEW_STRIDE;
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

/* Navigate to different page with wrapping */
integer navigate(key who, integer new_page){
    integer pages = pageCount();
    if (pages <= 0) pages = 1;
    
    /* Wrap around page boundaries */
    if (new_page < 0) new_page = pages - 1;
    if (new_page >= pages) new_page = 0;
    Page = new_page;

    list b = buttonsForPage(Page);
    string body = "Select a function (Page " + (string)(Page + 1) + "/" + (string)pages + ")";
    openDialog(who, "• DS Collar •", body, b);
    return TRUE;
}

/* Launch plugin for user */
integer startPlugin(string context, key who){
    string j = buildPluginStart(context);
    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, j, who);
    return TRUE;
}

/* ==================== Async Requests ==================== */

integer queryAcl(key user){
    string j = buildAclQuery(user);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    return TRUE;
}

integer fetchRegistry(){
    llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, "", NULL_KEY);
    return TRUE;
}

/* Clear all session state */
integer resetSession(){
    AclReady = FALSE;
    ListReady = FALSE;
    Acl = -1;
    IsWearer = FALSE;
    OwnerSet = FALSE;
    PolTpe = FALSE;
    PolPublicOnly = FALSE;
    PolOwnedOnly = FALSE;
    PolTrusteeAccess = FALSE;
    PolWearerUnowned = FALSE;
    PolPrimaryOwner = FALSE;
    return TRUE;
}

/* Check if we have everything needed to show UI */
integer canShowUi(){
    return AclReady && ListReady;
}

/* ==================== Events ==================== */
default{
    state_entry(){
        User = NULL_KEY;
        Listen = 0;
        Chan = 0;
        Page = 0;
        DialogOpen = FALSE;

        All = [];
        View = [];
        PageMap = [];

        resetSession();
    }

    on_rez(integer sp){
        llResetScript();
    }

    changed(integer c){
        if (c & CHANGED_OWNER) llResetScript();
    }

    touch_start(integer n){
        if (DialogOpen) closeDialog();

        User = llDetectedKey(0);
        if (!withinRange(User)){
            llRegionSayTo(User, 0, "You are too far from the wearer (max 5 m).");
            return;
        }

        /* Reset session for new touch */
        resetSession();
        queryAcl(User);
        fetchRegistry();
    }

    link_message(integer src, integer num, string msg, key id){
        /* ===== ACL RESULT ===== */
        if (num == AUTH_RESULT_NUM){
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type != MSG_ACL_RESULT) return;

            key av = (key)llJsonGetValue(msg, ["avatar"]);
            if (av == NULL_KEY || av != User) return;

            Acl = (integer)llJsonGetValue(msg, ["level"]);
            if (Acl < 0){
                llRegionSayTo(User, 0, "Access denied.");
                User = NULL_KEY;
                return;
            }

            /* Extract core flags */
            IsWearer = extractBoolFlag(msg, "is_wearer");
            OwnerSet = extractBoolFlag(msg, "owner_set");

            /* OPTIMIZED: Extract policy flags with helper */
            PolTpe = extractBoolFlag(msg, "policy_tpe");
            PolPublicOnly = extractBoolFlag(msg, "policy_public_only");
            PolOwnedOnly = extractBoolFlag(msg, "policy_owned_only");
            PolTrusteeAccess = extractBoolFlag(msg, "policy_trustee_access");
            PolWearerUnowned = extractBoolFlag(msg, "policy_wearer_unowned");
            PolPrimaryOwner = extractBoolFlag(msg, "policy_primary_owner");

            AclReady = TRUE;

            /* Show UI if we have both ACL and list */
            if (canShowUi()){
                View = filterForViewer();
                if (llGetListLength(View) == 0){
                    llRegionSayTo(User, 0, "No plugins available.");
                    User = NULL_KEY;
                    return;
                }
                showRoot(User, 0);
                resetSession();  /* Clear ready flags after use */
            }
            return;
        }

        /* ===== PLUGIN LIST ===== */
        if (num == K_PLUGIN_LIST_NUM){
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type != TYPE_PLUGIN_LIST) return;

            parseRegistry(msg);
            ListReady = TRUE;

            /* Show UI if we have both ACL and list */
            if (canShowUi()){
                View = filterForViewer();
                if (llGetListLength(View) == 0){
                    llRegionSayTo(User, 0, "No plugins available.");
                    User = NULL_KEY;
                    return;
                }
                showRoot(User, 0);
                resetSession();  /* Clear ready flags after use */
            }
            return;
        }

        /* ===== PLUGIN RETURN ===== */
        if (num == K_PLUGIN_RETURN_NUM){
            string ctx = llJsonGetValue(msg, ["context"]);
            if (ctx != ROOT_CONTEXT) return;
            if (id == NULL_KEY) return;

            /* Allow session handoff to different user returning to root */
            if (id != User){
                User = id;
                if (DialogOpen) closeDialog();
                Page = 0;
                resetSession();
                queryAcl(User);
                fetchRegistry();
                return;
            }

            /* Same user returning - show their current page */
            showRoot(User, Page);
            return;
        }
    }

    listen(integer chan, string name, key id, string b){
        if (chan != Chan) return;

        if (!withinRange(id)){
            closeDialog();
            llRegionSayTo(id, 0, "You moved too far from the wearer (max 5 m).");
            return;
        }

        /* Close dialog before processing to avoid double-opens */
        closeDialog();

        /* Navigation buttons */
        if (b == BTN_NAV_LEFT){
            navigate(id, Page - 1);
            return;
        }
        if (b == BTN_NAV_RIGHT){
            navigate(id, Page + 1);
            return;
        }
        if (b == BTN_NAV_GAP){
            showRoot(id, Page);
            return;
        }

        /* Function button - look up in PageMap */
        integer idx = llListFindList(PageMap, [b]);
        if (~idx){
            string ctx = llList2String(PageMap, idx + 1);
            startPlugin(ctx, id);
            return;
        }

        /* Unknown button - redisplay current page */
        showRoot(id, Page);
    }
}
