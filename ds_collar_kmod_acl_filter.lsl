/* =============================================================
   MODULE: ds_collar_kmod_acl_filter.lsl
   ROLE  : Central ACL gate + UI filtering + ticket/caps issuer
            - One source of truth for plugin visibility + actions
            - Caches AUTH results per avatar (short TTL)
            - Emits short-lived tickets to prevent TOCTOU races
            - Computes per-plugin "caps" from metadata (when present)
            - For now: safe to drop in; UI/plugins can adopt gradually
   ABI   : JSON-only, link_message-based (compatible with your kernel)
   ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[ACLF] " + s); return 0; }
integer now(){ return llGetUnixTime(); }

integer json_has(string j, list path){ if (llJsonGetValue(j, path) == JSON_INVALID) return FALSE; return TRUE; }
integer json_int(string j, list path, integer def){
    if (llJsonGetValue(j, path) == JSON_INVALID) return def;
    string v = llJsonGetValue(j, path);
    if (v == "" && (integer)("0"+v) == 0) return def;
    return (integer)v;
}
string json_str(string j, list path, string def){
    if (llJsonGetValue(j, path) == JSON_INVALID) return def;
    return llJsonGetValue(j, path);
}
/* LSL-safe JSON length helper (arrays/objects) */
integer json_len(string j){ return llGetListLength(llJson2List(j)); }

/* ---------- Kernel ABI link numbers (align with your system) ---------- */
integer K_PLUGIN_REG_QUERY     = 500;  /* {"type":"register_now","script":...}  */
integer K_PLUGIN_REG_REPLY     = 501;  /* {"type":"register", ...}              */
integer K_PLUGIN_SOFT_RESET    = 504;  /* {"type":"plugin_soft_reset",...}      */

integer K_PLUGIN_LIST_NUM      = 600;  /* {"type":"plugin_list", ...}           */
integer K_PLUGIN_LIST_REQUEST  = 601;  /* request plugin list                    */

integer AUTH_QUERY_NUM         = 700;  /* {"type":"acl_query","avatar":...}     */
integer AUTH_RESULT_NUM        = 710;  /* {"type":"acl_result",...}             */

integer K_SETTINGS_QUERY       = 800;  /* optional: if you later need settings  */
integer K_SETTINGS_SYNC        = 870;  /* {"type":"settings_sync",...}          */

integer K_PLUGIN_START_NUM     = 900;  /* Gate → Plugin: {"type":"plugin_start"...} */
integer K_PLUGIN_RETURN_NUM    = 901;  /* Plugin → UI: unchanged */

/* ---------- NEW: ACL Filter API (UI/HUD → Filter) --------------------- */
integer K_ACLF_QUERY_NUM       = 740;  /* UI/HUD → ACLF: ui_menu / plugin_start / plugin_action / caps_meta */
integer K_ACLF_REPLY_NUM       = 741;  /* ACLF → UI/HUD: replies (menus/denies/acks) */

/* ---------- Types (strings) ------------------------------------------- */
string TYPE_UI_MENU            = "ui_menu";        /* ask for filtered menu for {avatar} */
string TYPE_PLUGIN_START       = "plugin_start";   /* ask to open plugin {context} for {avatar} */
string TYPE_PLUGIN_ACTION      = "plugin_action";  /* ask to run {action,args} on {context} for {avatar} */
string TYPE_CAPS_META          = "caps_meta";      /* plugin reports per-button acl policy for its context */

string TYPE_REGISTER           = "register";       /* from plugins */
string TYPE_PLUGIN_LIST        = "plugin_list";    /* from kernel */

/* ---------- Policy / behavior knobs ----------------------------------- */
integer AUTH_TTL_SEC           = 8;   /* cache lifetime for AUTH results */
integer TICKET_TTL_SEC         = 20;  /* lifetime for start/action tickets */
integer ENFORCE_RANGE          = TRUE;/* enforce 5 m range (defensive) */
float   RANGE_MAX              = 5.0;

/* ---------- Storage: plugin registry ---------------------------------- */
/* We store each plugin row as a JSON object in a flat list:
   {"label":..., "context":..., "min_acl":2, "tpe_min_acl":0, "label_tpe":"...", "audience":"all"}
*/
list g_plugins = [];
integer g_plugins_ready = FALSE;
integer g_plugins_last_sync = 0;

/* ---------- Storage: per-plugin action ACL meta ----------------------- */
/* map: context -> JSON array of {"label":"Set Length","min_acl":3} */
list g_caps_meta_ctx = [];
list g_caps_meta_arr = [];

/* ---------- Storage: AUTH cache per avatar ---------------------------- */
/* map: avatar -> {"acl":3,"is_wearer":0,"pol":{...},"ts":epoch} */
list g_auth_keys = [];
list g_auth_vals = [];

/* ---------- Storage: pending requests while AUTH or registry not ready */
list g_pending_ui_menu = [];     /* list of avatar keys (string) */
list g_pending_starts  = [];     /* list of JSON blobs of start requests */
list g_pending_actions = [];     /* list of JSON blobs of action requests */

/* ---------- Storage: tickets (short-lived) ---------------------------- */
/* list of JSON blobs: {"ticket":"abc|172...","avatar":k,"context":"core_x","ts":epoch} */
list g_tickets = [];

/* =============================================================
   Helpers: Registry handling
   ============================================================= */
integer reg_index_by_context(string ctx){
    integer i = 0;
    integer n = llGetListLength(g_plugins);
    while (i < n){
        string row = llList2String(g_plugins, i);
        if (json_has(row, ["context"])){
            if (llJsonGetValue(row, ["context"]) == ctx) return i;
        }
        i += 1;
    }
    return -1;
}
integer reg_upsert_obj(string obj){
    if (!json_has(obj, ["context"])) return FALSE;
    string ctx = llJsonGetValue(obj, ["context"]);
    integer at = reg_index_by_context(ctx);
    if (at >= 0){
        g_plugins = llListReplaceList(g_plugins, [obj], at, at);
    } else {
        g_plugins += obj;
    }
    g_plugins_ready = TRUE;
    g_plugins_last_sync = now();
    return TRUE;
}
integer reg_from_register(string msg){
    if (!json_has(msg, ["type"])) return FALSE;
    if (llJsonGetValue(msg, ["type"]) != TYPE_REGISTER) return FALSE;

    string obj = llList2Json(JSON_OBJECT, []);
    obj = llJsonSetValue(obj, ["label"],      json_str(msg, ["label"], "Plugin"));
    obj = llJsonSetValue(obj, ["context"],    json_str(msg, ["context"], ""));
    obj = llJsonSetValue(obj, ["min_acl"],    (string)json_int(msg, ["min_acl"], 2));
    if (json_has(msg, ["tpe_min_acl"])) obj = llJsonSetValue(obj, ["tpe_min_acl"], (string)json_int(msg, ["tpe_min_acl"], -1));
    if (json_has(msg, ["label_tpe"]))   obj = llJsonSetValue(obj, ["label_tpe"], json_str(msg, ["label_tpe"], ""));
    if (json_has(msg, ["audience"]))    obj = llJsonSetValue(obj, ["audience"],   json_str(msg, ["audience"], "all"));
    return reg_upsert_obj(obj);
}
integer reg_from_plugin_list(string msg){
    if (!json_has(msg, ["type"])) return FALSE;
    if (llJsonGetValue(msg, ["type"]) != TYPE_PLUGIN_LIST) return FALSE;

    /* Accept either "rows":[{...},{...}] or "list":[[...],[...]] */
    integer did = FALSE;
    if (json_has(msg, ["rows"])){
        string rows = llJsonGetValue(msg, ["rows"]);
        integer i = 0; integer n = json_len(rows);
        while (i < n){
            string r = llJsonGetValue(rows, [i]);
            /* Expect object with at least context/min_acl/label */
            if (json_has(r, ["context"])){
                did = reg_upsert_obj(r) || did;
            }
            i += 1;
        }
    } else if (json_has(msg, ["list"])){
        string arr = llJsonGetValue(msg, ["list"]);
        integer i = 0; integer n = json_len(arr);
        while (i < n){
            string tup = llJsonGetValue(arr, [i]); /* assume array: [label,context,min_acl,(tpe_min_acl),(label_tpe),(audience)] */
            string obj = llList2Json(JSON_OBJECT, []);
            string label   = json_str(tup, [0], "Plugin");
            string context = json_str(tup, [1], "");
            integer minAcl = json_int(tup, [2], 2);
            obj = llJsonSetValue(obj, ["label"], label);
            obj = llJsonSetValue(obj, ["context"], context);
            obj = llJsonSetValue(obj, ["min_acl"], (string)minAcl);
            if (llJsonGetValue(tup, [3]) != JSON_INVALID) obj = llJsonSetValue(obj, ["tpe_min_acl"], (string)json_int(tup, [3], -1));
            if (llJsonGetValue(tup, [4]) != JSON_INVALID) obj = llJsonSetValue(obj, ["label_tpe"], json_str(tup, [4], ""));
            if (llJsonGetValue(tup, [5]) != JSON_INVALID) obj = llJsonSetValue(obj, ["audience"], json_str(tup, [5], "all"));
            did = reg_upsert_obj(obj) || did;
            i += 1;
        }
    }
    if (did) logd("Registry updated from plugin_list.");
    return did;
}

/* =============================================================
   Helpers: AUTH cache
   ============================================================= */
integer auth_idx(key av){
    integer i = 0; integer n = llGetListLength(g_auth_keys);
    while (i < n){
        if ((key)llList2String(g_auth_keys, i) == av) return i;
        i += 1;
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
   Helpers: distance & audience
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
    if (audience == "" || audience == "all") return TRUE;
    if (audience == "wearer"){
        if (is_wearer) return TRUE;
        return FALSE;
    }
    if (audience == "others"){
        if (!is_wearer) return TRUE;
        return FALSE;
    }
    /* unknown audience → allow */
    return TRUE;
}

/* =============================================================
   Helpers: building the filtered menu
   ============================================================= */
list build_menu_for_avatar(key av, string acljson){
    /* returns a list of JSON items: {"idx":i,"label":...,"label_tpe":...,"context":...,"min_acl":...,"tpe_min_acl":...,"audience":...} */
    list out = [];
    integer acl = json_int(acljson, ["level"], json_int(acljson, ["acl"], -1));
    integer is_w = json_int(acljson, ["is_wearer"], 0);

    integer pol_tpe          = json_int(acljson, ["policy_tpe"], json_int(acljson, ["pol","tpe"], 0));
    integer pol_public_only  = json_int(acljson, ["policy_public_only"], json_int(acljson, ["pol","public_only"], 0));
    /* other flags available if you want to specialize later */

    integer i = 0; integer n = llGetListLength(g_plugins);
    while (i < n){
        string row = llList2String(g_plugins, i);
        string label    = json_str(row, ["label"], "Plugin");
        string ctx      = json_str(row, ["context"], "");
        integer minAcl  = json_int(row, ["min_acl"], 2);
        integer tpeMin  = json_int(row, ["tpe_min_acl"], -1);
        string labelTpe = json_str(row, ["label_tpe"], "");
        string audience = json_str(row, ["audience"], "all");

        integer include = FALSE;

        if (acl <= -1){
            include = FALSE;
        } else if (pol_tpe){
            /* wearer in TPE: only plugins explicitly declaring tpe_min_acl == 0 */
            if (is_w && tpeMin == 0) include = TRUE;
        } else if (pol_public_only){
            if (!is_w){
                if (minAcl == 1) include = TRUE;
            } else {
                /* wearer while public_only policy shouldn't happen; fall back to minAcl <= 2 */
                if (minAcl <= 2) include = TRUE;
            }
        } else {
            if (minAcl <= acl) include = TRUE;
        }

        if (include){
            if (!audience_allows(audience, is_w)) include = FALSE;
            if (include && ENFORCE_RANGE){
                if (!within_range(av)) include = FALSE;
            }
        }

        if (include){
            string item = llList2Json(JSON_OBJECT, []);
            item = llJsonSetValue(item, ["idx"],      (string)i);
            item = llJsonSetValue(item, ["label"],    label);
            if (labelTpe != "") item = llJsonSetValue(item, ["label_tpe"], labelTpe);
            item = llJsonSetValue(item, ["context"],  ctx);
            item = llJsonSetValue(item, ["min_acl"],  (string)minAcl);
            if (tpeMin >= 0) item = llJsonSetValue(item, ["tpe_min_acl"], (string)tpeMin);
            if (audience != "all") item = llJsonSetValue(item, ["audience"], audience);
            out += item;
        }

        i += 1;
    }
    return out;
}

/* =============================================================
   Helpers: per-plugin caps + tickets
   ============================================================= */
string caps_json_for(string context, integer acl, integer min_acl){
    /* If we have meta for this context, enforce per-button; else emit only a default */
    integer k = llListFindList(g_caps_meta_ctx, [context]);
    string caps = llList2Json(JSON_OBJECT, []);

    integer caps_default = (acl >= min_acl);
    caps = llJsonSetValue(caps, ["__default__"], (string)caps_default);

    if (k >= 0){
        string arr = llList2String(g_caps_meta_arr, k);
        integer i = 0; integer n = json_len(arr);
        while (i < n){
            string r = llJsonGetValue(arr, [i]);
            string label = json_str(r, ["label"], "");
            integer need = json_int(r, ["min_acl"], min_acl);
            integer ok = (acl >= need);
            if (label != "") caps = llJsonSetValue(caps, [label], (string)ok);
            i += 1;
        }
    }
    return caps;
}
string ticket_new(key av, string context){
    /* format: <nonce>|<epoch> */
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
        integer fresh = (now() - ts) <= TICKET_TTL_SEC;
        string rTok = json_str(rec, ["ticket"], "");
        string rCtx = json_str(rec, ["context"], "");
        key    rAv  = (key)json_str(rec, ["avatar"], NULL_KEY);

        if (fresh) keep += rec;

        if (!ok){
            if (fresh){
                if (rTok == tok && rCtx == context && rAv == av) ok = TRUE;
            }
        }
        i += 1;
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
    /* Ask kernel/UI for the plugin list */
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_PLUGIN_LIST);
    llMessageLinked(LINK_SET, K_PLUGIN_LIST_REQUEST, j, NULL_KEY);
    return FALSE;
}

integer handle_ui_menu(key av){
    string acljson = auth_get(av);
    if (acljson == ""){
        /* request AUTH and pend the menu */
        if (!pend_has(g_pending_ui_menu, (string)av)){
            g_pending_ui_menu += (string)av;
        }
        auth_request(av);
        return FALSE;
    }
    if (!ensure_registry()){
        /* will reply once registry arrives */
        if (!pend_has(g_pending_ui_menu, (string)av)){
            g_pending_ui_menu += (string)av;
        }
        return FALSE;
    }

    list items = build_menu_for_avatar(av, acljson);

    string reply = llList2Json(JSON_OBJECT, []);
    reply = llJsonSetValue(reply, ["type"], TYPE_UI_MENU);
    reply = llJsonSetValue(reply, ["avatar"], (string)av);

    /* build JSON array of items */
    string arr = llList2Json(JSON_ARRAY, []);
    integer i = 0; integer n = llGetListLength(items);
    while (i < n){
        arr = llJsonSetValue(arr, [JSON_APPEND], llList2String(items, i));
        i += 1;
    }
    reply = llJsonSetValue(reply, ["items"], arr);

    llMessageLinked(LINK_SET, K_ACLF_REPLY_NUM, reply, NULL_KEY);
    return TRUE;
}

integer handle_plugin_start(key av, string context){
    string acljson = auth_get(av);
    if (acljson == ""){
        /* queue the start request until AUTH arrives */
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

    /* Find plugin row */
    integer at = reg_index_by_context(context);
    if (at < 0){
        /* deny: unknown context */
        string deny = llList2Json(JSON_OBJECT, []);
        deny = llJsonSetValue(deny, ["type"], "deny");
        deny = llJsonSetValue(deny, ["reason"], "unknown_context");
        deny = llJsonSetValue(deny, ["avatar"], (string)av);
        deny = llJsonSetValue(deny, ["context"], context);
        llMessageLinked(LINK_SET, K_ACLF_REPLY_NUM, deny, NULL_KEY);
        return FALSE;
    }

    string row = llList2String(g_plugins, at);
    string audience = json_str(row, ["audience"], "all");
    integer min_acl = json_int(row, ["min_acl"], 2);
    integer tpe_min = json_int(row, ["tpe_min_acl"], -1);

    integer acl = json_int(acljson, ["level"], json_int(acljson, ["acl"], -1));
    integer is_w = json_int(acljson, ["is_wearer"], 0);
    integer pol_tpe = json_int(acljson, ["policy_tpe"], json_int(acljson, ["pol","tpe"], 0));
    integer pol_public_only = json_int(acljson, ["policy_public_only"], json_int(acljson, ["pol","public_only"], 0));

    /* Visibility check (same rules used for menu) */
    integer allowed = FALSE;
    if (acl <= -1){
        allowed = FALSE;
    } else if (pol_tpe){
        if (is_w && tpe_min == 0) allowed = TRUE;
    } else if (pol_public_only){
        if (!is_w && min_acl == 1) allowed = TRUE;
        if (is_w && min_acl <= 2) allowed = TRUE;
    } else {
        if (min_acl <= acl) allowed = TRUE;
    }
    if (allowed){
        if (!audience_allows(audience, is_w)) allowed = FALSE;
        if (allowed && ENFORCE_RANGE){
            if (!within_range(av)) allowed = FALSE;
        }
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

    /* Build caps + ticket and forward START to plugin */
    string caps = caps_json_for(context, acl, min_acl);
    string t = ticket_new(av, context);

    string start = llList2Json(JSON_OBJECT, []);
    start = llJsonSetValue(start, ["type"],    TYPE_PLUGIN_START);
    start = llJsonSetValue(start, ["context"], context);
    start = llJsonSetValue(start, ["avatar"],  (string)av);
    start = llJsonSetValue(start, ["ticket"],  t);
    start = llJsonSetValue(start, ["acl"],     (string)acl);
    start = llJsonSetValue(start, ["is_wearer"], (string)is_w);

    /* attach policy flags (flat) */
    start = llJsonSetValue(start, ["policy_tpe"],          (string)pol_tpe);
    start = llJsonSetValue(start, ["policy_public_only"],  (string)pol_public_only);
    /* you can add more flags as needed (owned_only, trustee, primary_owner...) */

    start = llJsonSetValue(start, ["caps"], caps);

    llMessageLinked(LINK_SET, K_PLUGIN_START_NUM, start, (key)av);

    /* Friendly reply to UI (optional) */
    string ack = llList2Json(JSON_OBJECT, []);
    ack = llJsonSetValue(ack, ["type"], "plugin_opened");
    ack = llJsonSetValue(ack, ["avatar"], (string)av);
    ack = llJsonSetValue(ack, ["context"], context);
    ack = llJsonSetValue(ack, ["caps_default"], llJsonGetValue(caps, ["__default__"]));
    llMessageLinked(LINK_SET, K_ACLF_REPLY_NUM, ack, NULL_KEY);
    return TRUE;
}

integer handle_plugin_action(key av, string context, string action, string argsArr){
    /* Validate current auth + visibility + caps, then relay to plugin with a fresh ticket */
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

    integer acl   = json_int(acljson, ["level"], json_int(acljson, ["acl"], -1));
    integer is_w  = json_int(acljson, ["is_wearer"], 0);
    integer pol_tpe = json_int(acljson, ["policy_tpe"], json_int(acljson, ["pol","tpe"], 0));
    integer pol_public_only = json_int(acljson, ["policy_public_only"], json_int(acljson, ["pol","public_only"], 0));

    integer at = reg_index_by_context(context);
    if (at < 0) return FALSE;
    string row = llList2String(g_plugins, at);
    integer min_acl = json_int(row, ["min_acl"], 2);
    integer tpe_min = json_int(row, ["tpe_min_acl"], -1);
    string  audience = json_str(row, ["audience"], "all");

    integer allowed = FALSE;
    if (acl <= -1){
        allowed = FALSE;
    } else if (pol_tpe){
        if (is_w && tpe_min == 0) allowed = TRUE;
    } else if (pol_public_only){
        if (!is_w && min_acl == 1) allowed = TRUE;
        if (is_w && min_acl <= 2) allowed = TRUE;
    } else {
        if (min_acl <= acl) allowed = TRUE;
    }
    if (allowed){
        if (!audience_allows(audience, is_w)) allowed = FALSE;
        if (allowed && ENFORCE_RANGE) if (!within_range(av)) allowed = FALSE;
    }
    if (!allowed) return FALSE;

    /* Enforce per-action ACL if meta provided */
    integer ok = (acl >= min_acl); /* default */
    integer k = llListFindList(g_caps_meta_ctx, [context]);
    if (k >= 0){
        string arr = llList2String(g_caps_meta_arr, k);
        integer i = 0; integer n = json_len(arr);
        while (i < n){
            string r = llJsonGetValue(arr, [i]);
            string lbl = json_str(r, ["label"], "");
            if (lbl == action){
                integer need = json_int(r, ["min_acl"], min_acl);
                ok = (acl >= need);
            }
            i += 1;
        }
    }
    if (!ok) return FALSE;

    /* Relay with a fresh ticket */
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
   Event handlers
   ============================================================= */
default{
    state_entry(){
        g_plugins = [];
        g_plugins_ready = FALSE;
        g_caps_meta_ctx = [];
        g_caps_meta_arr = [];
        g_auth_keys = [];
        g_auth_vals = [];
        g_pending_ui_menu = [];
        g_pending_starts = [];
        g_pending_actions = [];
        g_tickets = [];
        llSetTimerEvent(5.0);
        logd("ACL Filter ready.");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer sender, integer num, string msg, key id){
        /* 1) Capture plugin registry (from kernel or directly from plugins) */
        if (num == K_PLUGIN_LIST_NUM){
            if (reg_from_plugin_list(msg)) return;
        }
        if (num == K_PLUGIN_REG_REPLY){
            if (reg_from_register(msg)) return;
        }

        /* 2) AUTH results → cache + service any pending asks */
        if (num == AUTH_RESULT_NUM){
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != "acl_result") return;
            if (!json_has(msg, ["avatar"])) return;

            key av = (key)llJsonGetValue(msg, ["avatar"]);
            /* Cache normalized record */
            string rec = llList2Json(JSON_OBJECT, []);
            integer level = json_int(msg, ["level"], -1);
            rec = llJsonSetValue(rec, ["level"], (string)level);
            rec = llJsonSetValue(rec, ["is_wearer"], (string)json_int(msg, ["is_wearer"], 0));
            /* flatten some policy flags (keep both styles for robustness) */
            rec = llJsonSetValue(rec, ["policy_tpe"], (string)json_int(msg, ["policy_tpe"], 0));
            rec = llJsonSetValue(rec, ["policy_public_only"], (string)json_int(msg, ["policy_public_only"], 0));
            auth_set(av, rec);

            /* service pending MENUs for this avatar */
            integer i = 0; integer n = llGetListLength(g_pending_ui_menu);
            list keep = [];
            while (i < n){
                key qav = (key)llList2String(g_pending_ui_menu, i);
                if (qav == av){
                    handle_ui_menu(qav);
                } else {
                    keep += llList2String(g_pending_ui_menu, i);
                }
                i += 1;
            }
            g_pending_ui_menu = keep;

            /* service pending STARTs for this avatar */
            i = 0; n = llGetListLength(g_pending_starts);
            list keep2 = [];
            while (i < n){
                string p = llList2String(g_pending_starts, i);
                key pav = (key)json_str(p, ["avatar"], NULL_KEY);
                if (pav == av){
                    string ctx = json_str(p, ["context"], "");
                    if (ctx != "") handle_plugin_start(pav, ctx);
                } else {
                    keep2 += p;
                }
                i += 1;
            }
            g_pending_starts = keep2;

            /* service pending ACTIONs for this avatar */
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
                } else {
                    keep3 += a;
                }
                i += 1;
            }
            g_pending_actions = keep3;

            return;
        }

        /* 3) Our public API (UI/HUD → ACL Filter) */
        if (num == K_ACLF_QUERY_NUM){
            if (!json_has(msg, ["type"])) return;
            string t = llJsonGetValue(msg, ["type"]);

            if (t == TYPE_UI_MENU){
                key av = (key)json_str(msg, ["avatar"], NULL_KEY);
                if (av != NULL_KEY){
                    handle_ui_menu(av);
                }
                return;
            }

            if (t == TYPE_PLUGIN_START){
                key av2 = (key)json_str(msg, ["avatar"], NULL_KEY);
                string ctx = json_str(msg, ["context"], "");
                if (av2 != NULL_KEY && ctx != ""){
                    handle_plugin_start(av2, ctx);
                }
                return;
            }

            if (t == TYPE_PLUGIN_ACTION){
                key av3 = (key)json_str(msg, ["avatar"], NULL_KEY);
                string ctx3 = json_str(msg, ["context"], "");
                string act  = json_str(msg, ["action"], "");
                string args = json_str(msg, ["args"], llList2Json(JSON_ARRAY, []));
                if (av3 != NULL_KEY && ctx3 != "" && act != ""){
                    handle_plugin_action(av3, ctx3, act, args);
                }
                return;
            }

            if (t == TYPE_CAPS_META){
                /* Plugin self-reports per-button ACL requirements for its context */
                string ctxm = json_str(msg, ["context"], "");
                string arrm = llList2Json(JSON_ARRAY, []);
                if (json_has(msg, ["actions"])) arrm = llJsonGetValue(msg, ["actions"]);
                if (ctxm != ""){
                    integer idx = llListFindList(g_caps_meta_ctx, [ctxm]);
                    if (idx >= 0){
                        g_caps_meta_arr = llListReplaceList(g_caps_meta_arr, [arrm], idx, idx);
                    } else {
                        g_caps_meta_ctx += ctxm;
                        g_caps_meta_arr += arrm;
                    }
                    logd("CAPS meta registered for " + ctxm);
                }
                return;
            }

            /* unknown type → ignore */
            return;
        }
    }

    timer(){
        /* Periodic cleanup: tickets naturally roll; we also keep registry "fresh-ish" */
        /* purge stale tickets */
        list keep = [];
        integer i = 0; integer n = llGetListLength(g_tickets);
        while (i < n){
            string rec = llList2String(g_tickets, i);
            integer ts = json_int(rec, ["ts"], 0);
            if ((now() - ts) <= TICKET_TTL_SEC) keep += rec;
            i += 1;
        }
        g_tickets = keep;

        /* Optional: request registry if never received */
        if (!g_plugins_ready){
            ensure_registry();
        }
    }
}
