/* =============================================================
   MODULE: ds_collar_kmod_acl_filter.lsl  (SLIM)
   ROLE  : Central ACL gate + UI filtering + tickets + caps
           - Compact plugin registry (flat list, strides)
           - No llJson2List() for lengths (prevents stack/heap)
           - Per-plugin allow_levels bitmask (visibility whitelist)
           - Range & audience checks
           - Short-lived tickets
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[ACLF] " + s); return 0; }
integer now(){ return llGetUnixTime(); }

integer json_has(string j, list path){ return (llJsonGetValue(j, path) != JSON_INVALID); }
integer json_int(string j, list path, integer def){
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return def;
    if (v == "") return def;
    return (integer)v;
}
string json_str(string j, list path, string def){
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return def;
    return v;
}
/* Length of a JSON array without llJson2List() */
integer json_arr_len(string j){
    integer i = 0;
    while (llJsonValueType(j, [i]) != JSON_INVALID) i = i + 1;
    return i;
}

/* ---------- Kernel ABI link numbers (align with your system) ---------- */
integer K_PLUGIN_REG_QUERY     = 500;
integer K_PLUGIN_REG_REPLY     = 501;
integer K_PLUGIN_SOFT_RESET    = 504;

integer K_PLUGIN_LIST_NUM      = 600;
integer K_PLUGIN_LIST_REQUEST  = 601;

integer AUTH_QUERY_NUM         = 700;
integer AUTH_RESULT_NUM        = 710;

integer K_SETTINGS_QUERY       = 800;
integer K_SETTINGS_SYNC        = 870;

integer K_PLUGIN_START_NUM     = 900;
integer K_PLUGIN_RETURN_NUM    = 901;

/* ---------- ACL Filter API (UI/HUD ↔ ACLF) ---------------------------- */
integer K_ACLF_QUERY_NUM       = 740;
integer K_ACLF_REPLY_NUM       = 741;

/* ---------- Types (strings) ------------------------------------------- */
string TYPE_UI_MENU            = "ui_menu";
string TYPE_PLUGIN_START       = "plugin_start";
string TYPE_PLUGIN_ACTION      = "plugin_action";
string TYPE_CAPS_META          = "caps_meta";

string TYPE_REGISTER           = "register";
string TYPE_PLUGIN_LIST        = "plugin_list";

/* ---------- Policy knobs ---------------------------------------------- */
integer AUTH_TTL_SEC           = 8;
integer TICKET_TTL_SEC         = 20;
integer ENFORCE_RANGE          = TRUE;
float   RANGE_MAX              = 5.0;

/* ---------- ACL constants (for allow_levels meaning) ------------------ */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Plugin registry (COMPACT) ---------------------------------
   Stride per plugin (8 items):
     [0] label          (string)
     [1] context        (string)
     [2] min_acl        (integer)
     [3] tpe_min_acl    (integer)  (-1 if not declared)
     [4] has_tpe        (integer)  (0/1)
     [5] label_tpe      (string)   ("" if none)
     [6] audience       (string)   ("all"|"wearer_only"|"non_wearer_only" or legacy "wearer"/"others")
     [7] allow_mask     (integer)  (-1 means “no whitelist”, allow all)
*/
list g_plugs = [];
integer PL_STRIDE = 8;

integer g_plugins_ready = FALSE;
integer g_plugins_last_sync = 0;

/* ---------- Per-plugin action ACL meta (store raw JSON) --------------- */
/* context[] ↔ actionsJson[] */
list g_caps_ctx = [];
list g_caps_arr = [];

/* ---------- AUTH cache per avatar ------------------------------------- */
list g_auth_keys = [];
list g_auth_vals = [];

/* ---------- Pending while waiting for AUTH/registry ------------------- */
list g_pending_ui_menu = []; /* strings of avatar keys */
list g_pending_starts  = []; /* JSON blobs */
list g_pending_actions = []; /* JSON blobs */

/* ---------- Tickets ---------------------------------------------------- */
list g_tickets = [];

/* =============================================================
   Helpers: allow_levels bitmask
   ============================================================= */
integer bit_for_level(integer lvl){
    if (lvl < 0) return 0;
    if (lvl > 31) return 0;
    integer one = 1;
    return (one << lvl);
}
integer mask_from_allow_json(string arr){
    if (arr == "" || arr == JSON_INVALID) return -1; /* no whitelist */
    integer n = json_arr_len(arr);
    if (n <= 0) return -1;
    integer mask = 0;
    integer i = 0;
    while (i < n){
        integer lvl = (integer)llJsonGetValue(arr, [i]);
        mask = mask | bit_for_level(lvl);
        i = i + 1;
    }
    return mask;
}
integer mask_allows(integer mask, integer lvl){
    if (mask == -1) return TRUE; /* no whitelist */
    integer bit = bit_for_level(lvl);
    if ((mask & bit) != 0) return TRUE;
    return FALSE;
}

/* =============================================================
   Helpers: Registry handling (COMPACT)
   ============================================================= */
integer reg_find_by_context(string ctx){
    integer n = llGetListLength(g_plugs);
    integer i = 0;
    while (i < n){
        string c = llList2String(g_plugs, i + 1);
        if (c == ctx) return i;
        i = i + PL_STRIDE;
    }
    return -1;
}
integer reg_upsert_flat(string label, string context, integer minAcl, integer tpeMin, integer hasTpe, string labelTpe, string audience, integer allowMask){
    if (context == "") return FALSE;
    integer at = reg_find_by_context(context);
    list row = [label, context, minAcl, tpeMin, hasTpe, labelTpe, audience, allowMask];
    if (at >= 0){
        g_plugs = llListReplaceList(g_plugs, row, at, at + PL_STRIDE - 1);
    } else {
        g_plugs += row;
    }
    g_plugins_ready = TRUE;
    g_plugins_last_sync = now();
    return TRUE;
}
integer reg_from_register(string msg){
    if (!json_has(msg, ["type"])) return FALSE;
    if (llJsonGetValue(msg, ["type"]) != TYPE_REGISTER) return FALSE;

    string label   = json_str(msg, ["label"],   "Plugin");
    string context = json_str(msg, ["context"], "");
    integer minAcl = json_int(msg, ["min_acl"], 2);

    integer hasTpe = 0;
    integer tpeMin = -1;
    string  labelT = "";
    if (json_has(msg, ["tpe_min_acl"])) { tpeMin = json_int(msg, ["tpe_min_acl"], -1); hasTpe = 1; }
    if (json_has(msg, ["label_tpe"]))   labelT = json_str(msg, ["label_tpe"], "");
    string audience = json_str(msg, ["audience"], "all");

    integer allowMask = -1;
    if (json_has(msg, ["allow_levels"])){
        allowMask = mask_from_allow_json(llJsonGetValue(msg, ["allow_levels"]));
    }

    return reg_upsert_flat(label, context, minAcl, tpeMin, hasTpe, labelT, audience, allowMask);
}
integer reg_from_plugin_list(string msg){
    if (!json_has(msg, ["type"])) return FALSE;
    if (llJsonGetValue(msg, ["type"]) != TYPE_PLUGIN_LIST) return FALSE;

    integer did = FALSE;

    if (json_has(msg, ["rows"])){
        string rows = llJsonGetValue(msg, ["rows"]);
        integer n = json_arr_len(rows);
        integer i = 0;
        while (i < n){
            string r = llJsonGetValue(rows, [i]);

            string label   = json_str(r, ["label"],   "Plugin");
            string context = json_str(r, ["context"], "");
            integer minAcl = json_int(r, ["min_acl"], 2);

            integer hasTpe = 0;
            integer tpeMin = -1;
            string  labelT = "";
            if (json_has(r, ["tpe_min_acl"])) { tpeMin = json_int(r, ["tpe_min_acl"], -1); hasTpe = 1; }
            if (json_has(r, ["label_tpe"]))   labelT = json_str(r, ["label_tpe"], "");
            string audience = json_str(r, ["audience"], "all");

            integer allowMask = -1;
            if (json_has(r, ["allow_levels"])){
                allowMask = mask_from_allow_json(llJsonGetValue(r, ["allow_levels"]));
            }

            if (context != ""){
                did = reg_upsert_flat(label, context, minAcl, tpeMin, hasTpe, labelT, audience, allowMask) || did;
            }
            i = i + 1;
        }
    } else if (json_has(msg, ["list"])){
        /* "list":[ [label,context,min_acl,(tpe_min),(label_tpe),(audience),(allow_levels_json)] ] */
        string arr = llJsonGetValue(msg, ["list"]);
        integer n2 = json_arr_len(arr);
        integer j = 0;
        while (j < n2){
            string tup = llJsonGetValue(arr, [j]);

            string label   = json_str(tup, [0], "Plugin");
            string context = json_str(tup, [1], "");
            integer minAcl = json_int(tup, [2], 2);

            integer hasTpe = 0;
            integer tpeMin = -1;
            string  labelT = "";
            if (llJsonValueType(tup, [3]) != JSON_INVALID){ tpeMin = json_int(tup, [3], -1); if (tpeMin >= 0) hasTpe = 1; }
            if (llJsonValueType(tup, [4]) != JSON_INVALID)  labelT = json_str(tup, [4], "");
            string audience = "all";
            if (llJsonValueType(tup, [5]) != JSON_INVALID)  audience = json_str(tup, [5], "all");

            integer allowMask = -1;
            if (llJsonValueType(tup, [6]) != JSON_INVALID){
                allowMask = mask_from_allow_json(llJsonGetValue(tup, [6]));
            }

            if (context != ""){
                did = reg_upsert_flat(label, context, minAcl, tpeMin, hasTpe, labelT, audience, allowMask) || did;
            }
            j = j + 1;
        }
    }

    if (did) logd("Registry updated (compact).");
    return did;
}

/* =============================================================
   AUTH cache
   ============================================================= */
integer auth_idx(key av){
    integer i = 0; integer n = llGetListLength(g_auth_keys);
    while (i < n){
        if ((key)llList2String(g_auth_keys, i) == av) return i;
        i = i + 1;
    }
    return -1;
}
integer auth_is_fresh(string val){
    integer ts = json_int(val, ["ts"], 0);
    if ((now() - ts) <= AUTH_TTL_SEC) return TRUE;
    return FALSE;
}
string auth_get(key av){
    integer ix = auth_idx(av);
    if (ix < 0) return "";
    string val = llList2String(g_auth_vals, ix);
    if (!auth_is_fresh(val)) return "";
    return val;
}
integer auth_set(key av, string acljson){
    integer ix = auth_idx(av);
    string val = llJsonSetValue(acljson, ["ts"], (string)now());
    if (ix < 0){
        g_auth_keys += (string)av;
        g_auth_vals += val;
    } else {
        g_auth_vals = llListReplaceList(g_auth_vals, [val], ix, ix);
    }
    return TRUE;
}
integer auth_request(key av){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], "acl_query");
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    return TRUE;
}

/* =============================================================
   Distance & audience
   ============================================================= */
integer within_range(key av){
    if (!ENFORCE_RANGE) return TRUE;
    list d = llGetObjectDetails(av, [OBJECT_POS]);
    if (llGetListLength(d) == 0) return FALSE;
    vector p = llList2Vector(d, 0);
    if (p == ZERO_VECTOR) return FALSE;
    float dist = llVecDist(p, llGetPos());
    if (dist <= RANGE_MAX) return TRUE;
    return FALSE;
}
integer audience_allows(string audience, integer is_wearer){
    string a = audience;
    if (a == "wearer") a = "wearer_only";
    if (a == "others") a = "non_wearer_only";
    if (a == "" || a == "all") return TRUE;
    if (a == "wearer_only"){
        if (is_wearer) return TRUE;
        return FALSE;
    }
    if (a == "non_wearer_only"){
        if (!is_wearer) return TRUE;
        return FALSE;
    }
    return TRUE;
}

/* =============================================================
   Visibility logic (shared by menu/start/action)
   ============================================================= */
integer can_see_row(integer acl, integer is_w, integer pol_tpe, integer pol_public_only,
                    integer minAcl, integer hasTpe, integer tpeMin, string audience, integer allowMask)
{
    if (acl <= ACL_BLACKLIST) return FALSE;

    if (!audience_allows(audience, is_w)) return FALSE;

    /* Whitelist mask first: if set, it must allow this level */
    if (!mask_allows(allowMask, acl)) return FALSE;

    if (is_w && pol_tpe){
        if (hasTpe){
            if (tpeMin == 0) return TRUE;
        }
        return FALSE;
    }

    if (!is_w && pol_public_only){
        if (minAcl == ACL_PUBLIC) return TRUE;
        return FALSE;
    }

    if (minAcl <= acl) return TRUE;
    return FALSE;
}

/* =============================================================
   Build filtered menu items
   ============================================================= */
list build_menu_for_avatar(key av, string acljson){
    list out = [];

    integer acl   = json_int(acljson, ["level"], json_int(acljson, ["acl"], -1));
    integer is_w  = json_int(acljson, ["is_wearer"], 0);
    integer pol_t = json_int(acljson, ["policy_tpe"], json_int(acljson, ["pol","tpe"], 0));
    integer pol_p = json_int(acljson, ["policy_public_only"], json_int(acljson, ["pol","public_only"], 0));

    integer n = llGetListLength(g_plugs);
    integer i = 0;
    while (i < n){
        string  label    = llList2String (g_plugs, i + 0);
        string  context  = llList2String (g_plugs, i + 1);
        integer minAcl   = llList2Integer(g_plugs, i + 2);
        integer tpeMin   = llList2Integer(g_plugs, i + 3);
        integer hasTpe   = llList2Integer(g_plugs, i + 4);
        string  labelTpe = llList2String (g_plugs, i + 5);
        string  audience = llList2String (g_plugs, i + 6);
        integer allowM   = llList2Integer(g_plugs, i + 7);

        integer include = can_see_row(acl, is_w, pol_t, pol_p, minAcl, hasTpe, tpeMin, audience, allowM);

        if (include){
            if (ENFORCE_RANGE){
                if (!within_range(av)) include = FALSE;
            }
        }

        if (include){
            string item = llList2Json(JSON_OBJECT, []);
            item = llJsonSetValue(item, ["idx"],      (string)(i / PL_STRIDE));
            item = llJsonSetValue(item, ["label"],    label);
            if (labelTpe != "") item = llJsonSetValue(item, ["label_tpe"], labelTpe);
            item = llJsonSetValue(item, ["context"],  context);
            item = llJsonSetValue(item, ["min_acl"],  (string)minAcl);
            if (hasTpe) item = llJsonSetValue(item, ["tpe_min_acl"], (string)tpeMin);
            if (audience != "all") item = llJsonSetValue(item, ["audience"], audience);
            out += item;
        }

        i = i + PL_STRIDE;
    }
    return out;
}

/* =============================================================
   Caps + tickets
   ============================================================= */
string caps_json_for(string context, integer acl, integer min_acl){
    integer k = llListFindList(g_caps_ctx, [context]);
    string caps = llList2Json(JSON_OBJECT, []);
    integer caps_default = FALSE;
    if (acl >= min_acl) caps_default = TRUE;
    caps = llJsonSetValue(caps, ["__default__"], (string)caps_default);

    if (k >= 0){
        string arr = llList2String(g_caps_arr, k);
        integer n = json_arr_len(arr);
        integer i = 0;
        while (i < n){
            string r = llJsonGetValue(arr, [i]);
            string label = json_str(r, ["label"], "");
            integer need = json_int(r, ["min_acl"], min_acl);
            integer ok = FALSE;
            if (acl >= need) ok = TRUE;
            if (label != "") caps = llJsonSetValue(caps, [label], (string)ok);
            i = i + 1;
        }
    }
    return caps;
}
string ticket_new(key av, string context){
    integer nonce = (integer)llFrand(2147480000.0) + (integer)llFrand(9999.0);
    integer t = now();
    string tok = (string)nonce + "|" + (string)t;

    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["ticket"],  tok);
    j = llJsonSetValue(j, ["avatar"],  (string)av);
    j = llJsonSetValue(j, ["context"], context);
    j = llJsonSetValue(j, ["ts"],      (string)t);

    g_tickets += j;
    return tok;
}
integer ticket_ok(string tok, key av, string context){
    integer i = 0; integer n = llGetListLength(g_tickets);
    integer ok = FALSE;
    list keep = [];
    while (i < n){
        string rec = llList2String(g_tickets, i);
        integer ts = json_int(rec, ["ts"], 0);
        integer fresh = FALSE;
        if ((now() - ts) <= TICKET_TTL_SEC) fresh = TRUE;

        string rTok = json_str(rec, ["ticket"], "");
        string rCtx = json_str(rec, ["context"], "");
        key    rAv  = (key)json_str(rec, ["avatar"], NULL_KEY);

        if (fresh) keep += rec;
        if (!ok){
            if (fresh){
                if (rTok == tok && rCtx == context && rAv == av) ok = TRUE;
            }
        }
        i = i + 1;
    }
    g_tickets = keep;
    return ok;
}

/* =============================================================
   Pending queues
   ============================================================= */
integer pend_has(list L, string keystr){
    integer i = llListFindList(L, [keystr]);
    if (i >= 0) return TRUE;
    return FALSE;
}

/* =============================================================
   Core operations
   ============================================================= */
integer ensure_registry(){
    if (g_plugins_ready) return TRUE;
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_PLUGIN_LIST);
    llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, j, NULL_KEY);
    return FALSE;
}

integer handle_ui_menu(key av){
    string acljson = auth_get(av);
    if (acljson == ""){
        if (!pend_has(g_pending_ui_menu, (string)av)) g_pending_ui_menu += (string)av;
        auth_request(av);
        return FALSE;
    }
    if (!ensure_registry()){
        if (!pend_has(g_pending_ui_menu, (string)av)) g_pending_ui_menu += (string)av;
        return FALSE;
    }

    list items = build_menu_for_avatar(av, acljson);

    string reply = llList2Json(JSON_OBJECT, []);
    reply = llJsonSetValue(reply, ["type"], TYPE_UI_MENU);
    reply = llJsonSetValue(reply, ["avatar"], (string)av);

    string arr = llList2Json(JSON_ARRAY, []);
    integer i = 0; integer n = llGetListLength(items);
    while (i < n){
        arr = llJsonSetValue(arr, [JSON_APPEND], llList2String(items, i));
        i = i + 1;
    }
    reply = llJsonSetValue(reply, ["items"], arr);

    llMessageLinked(LINK_SET, K_ACLF_REPLY_NUM, reply, NULL_KEY);
    return TRUE;
}

integer handle_plugin_start(key av, string context){
    string acljson = auth_get(av);
    if (acljson == ""){
        string pend = llList2Json(JSON_OBJECT, []);
        pend = llJsonSetValue(pend, ["type"], TYPE_PLUGIN_START);
        pend = llJsonSetValue(pend, ["avatar"], (string)av);
        pend = llJsonSetValue(pend, ["context"], context);
        g_pending_starts += pend;
        auth_request(av);
        return FALSE;
    }
    if (!ensure_registry()){
        string pend2 = llList2Json(JSON_OBJECT, []);
        pend2 = llJsonSetValue(pend2, ["type"], TYPE_PLUGIN_START);
        pend2 = llJsonSetValue(pend2, ["avatar"], (string)av);
        pend2 = llJsonSetValue(pend2, ["context"], context);
        g_pending_starts += pend2;
        return FALSE;
    }

    integer at = reg_find_by_context(context);
    if (at < 0){
        string deny = llList2Json(JSON_OBJECT, []);
        deny = llJsonSetValue(deny, ["type"], "deny");
        deny = llJsonSetValue(deny, ["reason"], "unknown_context");
        deny = llJsonSetValue(deny, ["avatar"], (string)av);
        deny = llJsonSetValue(deny, ["context"], context);
        llMessageLinked(LINK_SET, K_ACLF_REPLY_NUM, deny, NULL_KEY);
        return FALSE;
    }

    string  audience = llList2String (g_plugs, at + 6);
    integer min_acl  = llList2Integer(g_plugs, at + 2);
    integer tpe_min  = llList2Integer(g_plugs, at + 3);
    integer has_tpe  = llList2Integer(g_plugs, at + 4);
    integer allowM   = llList2Integer(g_plugs, at + 7);

    integer acl   = json_int(acljson, ["level"], json_int(acljson, ["acl"], -1));
    integer is_w  = json_int(acljson, ["is_wearer"], 0);
    integer pol_t = json_int(acljson, ["policy_tpe"], json_int(acljson, ["pol","tpe"], 0));
    integer pol_p = json_int(acljson, ["policy_public_only"], json_int(acljson, ["pol","public_only"], 0));

    integer allowed = can_see_row(acl, is_w, pol_t, pol_p, min_acl, has_tpe, tpe_min, audience, allowM);
    if (allowed && ENFORCE_RANGE){
        if (!within_range(av)) allowed = FALSE;
    }

    if (!allowed){
        string deny2 = llList2Json(JSON_OBJECT, []);
        deny2 = llJsonSetValue(deny2, ["type"], "deny");
        deny2 = llJsonSetValue(deny2, ["reason"], "acl");
        deny2 = llJsonSetValue(deny2, ["avatar"], (string)av);
        deny2 = llJsonSetValue(deny2, ["context"], context);
        llMessageLinked(LINK_SET, K_ACLF_REPLY_NUM, deny2, NULL_KEY);
        return FALSE;
    }

    string caps = caps_json_for(context, acl, min_acl);
    string t = ticket_new(av, context);

    string start = llList2Json(JSON_OBJECT, []);
    start = llJsonSetValue(start, ["type"],    TYPE_PLUGIN_START);
    start = llJsonSetValue(start, ["context"], context);
    start = llJsonSetValue(start, ["avatar"],  (string)av);
    start = llJsonSetValue(start, ["ticket"],  t);
    start = llJsonSetValue(start, ["level"],   (string)acl);
    start = llJsonSetValue(start, ["is_wearer"], (string)is_w);
    start = llJsonSetValue(start, ["policy_tpe"],         (string)pol_t);
    start = llJsonSetValue(start, ["policy_public_only"], (string)pol_p);
    start = llJsonSetValue(start, ["caps"], caps);

    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, start, (key)av);

    string ack = llList2Json(JSON_OBJECT, []);
    ack = llJsonSetValue(ack, ["type"], "plugin_opened");
    ack = llJsonSetValue(ack, ["avatar"], (string)av);
    ack = llJsonSetValue(ack, ["context"], context);
    ack = llJsonSetValue(ack, ["caps_default"], llJsonGetValue(caps, ["__default__"]));
    llMessageLinked(LINK_SET, K_ACLF_REPLY_NUM, ack, NULL_KEY);
    return TRUE;
}

integer handle_plugin_action(key av, string context, string action, string argsArr){
    string acljson = auth_get(av);
    if (acljson == ""){
        string pend = llList2Json(JSON_OBJECT, []);
        pend = llJsonSetValue(pend, ["type"], TYPE_PLUGIN_ACTION);
        pend = llJsonSetValue(pend, ["avatar"], (string)av);
        pend = llJsonSetValue(pend, ["context"], context);
        pend = llJsonSetValue(pend, ["action"],  action);
        pend = llJsonSetValue(pend, ["args"],    argsArr);
        g_pending_actions += pend;
        auth_request(av);
        return FALSE;
    }

    integer at = reg_find_by_context(context);
    if (at < 0) return FALSE;

    integer min_acl  = llList2Integer(g_plugs, at + 2);
    integer tpe_min  = llList2Integer(g_plugs, at + 3);
    integer has_tpe  = llList2Integer(g_plugs, at + 4);
    string  audience = llList2String (g_plugs, at + 6);
    integer allowM   = llList2Integer(g_plugs, at + 7);

    integer acl   = json_int(acljson, ["level"], json_int(acljson, ["acl"], -1));
    integer is_w  = json_int(acljson, ["is_wearer"], 0);
    integer pol_t = json_int(acljson, ["policy_tpe"], json_int(acljson, ["pol","tpe"], 0));
    integer pol_p = json_int(acljson, ["policy_public_only"], json_int(acljson, ["pol","public_only"], 0));

    integer allowed = can_see_row(acl, is_w, pol_t, pol_p, min_acl, has_tpe, tpe_min, audience, allowM);
    if (allowed && ENFORCE_RANGE) if (!within_range(av)) allowed = FALSE;
    if (!allowed) return FALSE;

    /* enforce per-action ACL if meta exists */
    integer ok = FALSE;
    if (acl >= min_acl) ok = TRUE;
    integer k = llListFindList(g_caps_ctx, [context]);
    if (k >= 0){
        string arr = llList2String(g_caps_arr, k);
        integer n = json_arr_len(arr);
        integer i = 0;
        while (i < n){
            string r = llJsonGetValue(arr, [i]);
            string lbl = json_str(r, ["label"], "");
            if (lbl == action){
                integer need = json_int(r, ["min_acl"], min_acl);
                ok = FALSE;
                if (acl >= need) ok = TRUE;
            }
            i = i + 1;
        }
    }
    if (!ok) return FALSE;

    string t = ticket_new(av, context);

    string relay = llList2Json(JSON_OBJECT, []);
    relay = llJsonSetValue(relay, ["type"],    TYPE_PLUGIN_ACTION);
    relay = llJsonSetValue(relay, ["context"], context);
    relay = llJsonSetValue(relay, ["action"],  action);
    relay = llJsonSetValue(relay, ["args"],    argsArr);
    relay = llJsonSetValue(relay, ["ticket"],  t);
    relay = llJsonSetValue(relay, ["avatar"],  (string)av);

    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, relay, (key)av);
    return TRUE;
}

/* =============================================================
   Events
   ============================================================= */
default{
    state_entry(){
        g_plugs = [];
        g_plugins_ready = FALSE;
        g_caps_ctx = [];
        g_caps_arr = [];
        g_auth_keys = [];
        g_auth_vals = [];
        g_pending_ui_menu = [];
        g_pending_starts  = [];
        g_pending_actions = [];
        g_tickets = [];
        llSetTimerEvent(5.0);
        logd("ACLF slim ready.");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer sender, integer num, string msg, key id){
        /* 1) Registry sources */
        if (num == K_PLUGIN_LIST_NUM){ if (reg_from_plugin_list(msg)) return; }
        if (num == K_PLUGIN_REG_REPLY){ if (reg_from_register(msg)) return; }

        /* 2) AUTH results */
        if (num == AUTH_RESULT_NUM){
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != "acl_result") return;
            if (!json_has(msg, ["avatar"])) return;

            key av = (key)llJsonGetValue(msg, ["avatar"]);

            string rec = llList2Json(JSON_OBJECT, []);
            integer level = json_int(msg, ["level"], -1);
            rec = llJsonSetValue(rec, ["level"], (string)level);
            rec = llJsonSetValue(rec, ["is_wearer"], (string)json_int(msg, ["is_wearer"], 0));
            rec = llJsonSetValue(rec, ["policy_tpe"], (string)json_int(msg, ["policy_tpe"], 0));
            rec = llJsonSetValue(rec, ["policy_public_only"], (string)json_int(msg, ["policy_public_only"], 0));
            auth_set(av, rec);

            /* service pending menus for this avatar */
            integer i = 0; integer n = llGetListLength(g_pending_ui_menu);
            list keep = [];
            while (i < n){
                key qav = (key)llList2String(g_pending_ui_menu, i);
                if (qav == av) handle_ui_menu(qav);
                else keep += llList2String(g_pending_ui_menu, i);
                i = i + 1;
            }
            g_pending_ui_menu = keep;

            /* service pending starts */
            i = 0; n = llGetListLength(g_pending_starts);
            list keep2 = [];
            while (i < n){
                string p = llList2String(g_pending_starts, i);
                key pav = (key)json_str(p, ["avatar"], NULL_KEY);
                if (pav == av){
                    string ctx = json_str(p, ["context"], "");
                    if (ctx != "") handle_plugin_start(pav, ctx);
                } else keep2 += p;
                i = i + 1;
            }
            g_pending_starts = keep2;

            /* service pending actions */
            i = 0; n = llGetListLength(g_pending_actions);
            list keep3 = [];
            while (i < n){
                string a = llList2String(g_pending_actions, i);
                key aav = (key)json_str(a, ["avatar"], NULL_KEY);
                if (aav == av){
                    string ctx2 = json_str(a, ["context"], "");
                    string act  = json_str(a, ["action"], "");
                    string args = json_str(a, ["args"], llList2Json(JSON_ARRAY, []));
                    if (ctx2 != "" && act != "") handle_plugin_action(aav, ctx2, act, args);
                } else keep3 += a;
                i = i + 1;
            }
            g_pending_actions = keep3;
            return;
        }

        /* 3) Public API from UI/HUD */
        if (num == K_ACLF_QUERY_NUM){
            if (!json_has(msg, ["type"])) return;
            string t = llJsonGetValue(msg, ["type"]);

            if (t == TYPE_UI_MENU){
                key av = (key)json_str(msg, ["avatar"], NULL_KEY);
                if (av != NULL_KEY) handle_ui_menu(av);
                return;
            }

            if (t == TYPE_PLUGIN_START){
                key av2 = (key)json_str(msg, ["avatar"], NULL_KEY);
                string ctx = json_str(msg, ["context"], "");
                if (av2 != NULL_KEY && ctx != "") handle_plugin_start(av2, ctx);
                return;
            }

            if (t == TYPE_PLUGIN_ACTION){
                key av3 = (key)json_str(msg, ["avatar"], NULL_KEY);
                string ctx3 = json_str(msg, ["context"], "");
                string act  = json_str(msg, ["action"], "");
                string args = json_str(msg, ["args"], llList2Json(JSON_ARRAY, []));
                if (av3 != NULL_KEY && ctx3 != "" && act != "") handle_plugin_action(av3, ctx3, act, args);
                return;
            }

            if (t == TYPE_CAPS_META){
                string ctxm = json_str(msg, ["context"], "");
                string arrm = llList2Json(JSON_ARRAY, []);
                if (json_has(msg, ["actions"])) arrm = llJsonGetValue(msg, ["actions"]);
                if (ctxm != ""){
                    integer idx = llListFindList(g_caps_ctx, [ctxm]);
                    if (idx >= 0) g_caps_arr = llListReplaceList(g_caps_arr, [arrm], idx, idx);
                    else{
                        g_caps_ctx += ctxm;
                        g_caps_arr += arrm;
                    }
                    logd("CAPS meta registered for " + ctxm);
                }
                return;
            }
            return;
        }
    }

    timer(){
        /* purge stale tickets */
        list keep = [];
        integer i = 0; integer n = llGetListLength(g_tickets);
        while (i < n){
            string rec = llList2String(g_tickets, i);
            integer ts = json_int(rec, ["ts"], 0);
            if ((now() - ts) <= TICKET_TTL_SEC) keep += rec;
            i = i + 1;
        }
        g_tickets = keep;

        if (!g_plugins_ready) ensure_registry();
    }
}
