/* =============================================================
   MODULE: ds_collar_kmod_ui_backend.lsl (BLANK-CANVAS, STRICT)
   ROLE  : Single source of truth for UI:
           - Accepts ui_draw from plugins (strict button metadata)
           - Auth-aware filtering (hard-hide)
           - Session + index→id mapping; routes clicks back to plugin
   POLICY: Default-deny (every button MUST have label,id,min_acl)
   NOTE   : No built-in harness or core menu here.
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-BE] " + s); return 0; }

/* === Canonical lanes (as in your new-ui baselines) === */
integer ABI_VERSION   = 1;
integer L_API         = -1000;
integer L_BROADCAST   = -1001;
integer L_SETTINGS_IN = -1300;
integer L_AUTH_IN     = -1400;
integer L_ACL_IN      = -1500;
integer L_UI_BE_IN    = -1600;  /* messages addressed to Backend */
integer L_UI_FE_IN    = -1700;  /* messages addressed to Frontend */
integer L_IDENTITY_IN = -1800;

/* === Message types === */
string T_UI_TOUCH   = "ui_touch";   /* FE → BE : someone touched; BE ignores (harness handles) */
string T_UI_DRAW    = "ui_draw";    /* Plugin → BE : request to draw a page */
string T_UI_RENDER  = "ui_render";  /* BE  → FE : render this page */
string T_UI_CLICK   = "ui_click";   /* FE  → BE : a button was clicked */
string T_UI_EVENT   = "ui_click";   /* BE  → Plugin : routed click event */

string T_AUTH_QUERY  = "auth_query";   /* BE  → AUTH */
string T_AUTH_RESULT = "auth_result";  /* AUTH → BE  */

/* === Strict policy === */
integer STRICT_BTN_METADATA = TRUE;   /* MUST have label,id,min_acl */

/* === AUTH cache ===
   Map per avatar: [avatar, level, is_wearer, policy_tpe, policy_public_only, policy_primary_owner]
   stride = 6
*/
list AuthCache; integer AC_STRIDE = 6;

/* === Sessions ===
   sessions: [session, avatar, plugin_script, ctx_json, labels_json, ids_json] (stride 6)
   labels_json/ids_json are JSON arrays aligned by index for the CURRENT page
*/
list Sessions; integer S_STRIDE = 6;

/* === Pending AUTH for ui_draw ===
   pending: [authRid, session, avatar, plugin_script, draw_payload_json] (stride 5)
*/
list Pending; integer P_STRIDE = 5;

/* === Helpers === */
integer now(){ return llGetUnixTime(); }
string rid(){ return (string)now() + "-" + (string)llRound(llFrand(99999.0)); }
string jobj(){ return llList2Json(JSON_OBJECT, []); }
string jarr(){ return llList2Json(JSON_ARRAY, []); }
string jset(string j, list p, string v){ return llJsonSetValue(j, p, v); }

integer json_has(string j, list path){
    if (llJsonGetValue(j, path) == JSON_INVALID) return FALSE;
    return TRUE;
}
string json_str(string j, list path, string def){
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return def;
    return v;
}
integer json_int(string j, list path, integer def){
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return def;
    if (v == "") return def;
    return (integer)v;
}

/* --- AUTH cache ops --- */
integer ac_find_idx(key av){
    integer n = llGetListLength(AuthCache);
    integer i = 0;
    while (i < n){
        if ((key)llList2String(AuthCache, i) == av) return i;
        i = i + AC_STRIDE;
    }
    return -1;
}
integer ac_get_level(key av){
    integer i = ac_find_idx(av);
    if (i == -1) return -1;
    return (integer)llList2String(AuthCache, i + 1);
}
integer ac_get_is_wearer(key av){
    integer i = ac_find_idx(av);
    if (i == -1) return 0;
    return (integer)llList2String(AuthCache, i + 2);
}
integer ac_get_policy_tpe(key av){
    integer i = ac_find_idx(av);
    if (i == -1) return 0;
    return (integer)llList2String(AuthCache, i + 3);
}
integer ac_get_policy_public_only(key av){
    integer i = ac_find_idx(av);
    if (i == -1) return 0;
    return (integer)llList2String(AuthCache, i + 4);
}
integer ac_get_policy_primary_owner(key av){
    integer i = ac_find_idx(av);
    if (i == -1) return 0;
    return (integer)llList2String(AuthCache, i + 5);
}
integer ac_put(key av, integer level, integer is_wearer, integer p_tpe, integer p_pub, integer p_po){
    integer i = ac_find_idx(av);
    if (i != -1){
        AuthCache = llListReplaceList(AuthCache, [ (string)av, (string)level, (string)is_wearer, (string)p_tpe, (string)p_pub, (string)p_po ], i, i + AC_STRIDE - 1);
        return TRUE;
    }
    AuthCache += [ (string)av, (string)level, (string)is_wearer, (string)p_tpe, (string)p_pub, (string)p_po ];
    return TRUE;
}

/* --- Strict button validator --- */
integer is_valid_btn(string j){
    if (!STRICT_BTN_METADATA) return TRUE;
    if (llGetSubString(j, 0, 0) != "{") return FALSE;
    if (!json_has(j, ["label"])) return FALSE;
    if (!json_has(j, ["id"])) return FALSE;
    if (!json_has(j, ["min_acl"])) return FALSE;
    string lbl = json_str(j, ["label"], "");
    string id  = json_str(j, ["id"], "");
    integer ma = json_int(j, ["min_acl"], -1);
    if (lbl == "") return FALSE;
    if (id  == "") return FALSE;
    if (ma < 0) return FALSE;
    if (ma > 5) return FALSE;
    return TRUE;
}

/* --- ACL/policy filter (hard-hide) ---
   Allows if: acl_level >= min_acl AND (audience/policy flags match if provided)
*/
integer allow_button(string btn, integer level, integer is_wearer, integer p_tpe, integer p_pub, integer p_po){
    /* Required already validated */
    integer min_acl = json_int(btn, ["min_acl"], 99);
    if (level < min_acl) return FALSE;

    /* Optional masks/flags */
    if (json_has(btn, ["allow_levels"])){
        integer mask = json_int(btn, ["allow_levels"], 0);
        integer bit = 1;
        bit = bit << level;
        if ((mask & bit) == 0) return FALSE;
    }

    string audience = "all";
    if (json_has(btn, ["audience"])) audience = json_str(btn, ["audience"], "all");
    if (audience == "wearer" && !is_wearer) return FALSE;
    if (audience == "others" && is_wearer) return FALSE;

    integer tpe_only     = 0; if (json_has(btn, ["tpe_only"])) tpe_only = json_int(btn, ["tpe_only"], 0);
    integer public_only  = 0; if (json_has(btn, ["public_only"])) public_only = json_int(btn, ["public_only"], 0);
    integer owner_only   = 0; if (json_has(btn, ["owner_only"])) owner_only = json_int(btn, ["owner_only"], 0);
    integer trustee_only = 0; if (json_has(btn, ["trustee_only"])) trustee_only = json_int(btn, ["trustee_only"], 0);

    if (p_pub){ if (!(public_only || min_acl == 1)) return FALSE; }
    if (p_tpe && is_wearer){ if (!(tpe_only || min_acl == 0)) return FALSE; }
    if (owner_only){ if (!(level == 5 || p_po)) return FALSE; }
    if (trustee_only){ if (level != 3) return FALSE; }

    return TRUE;
}

/* Build labels/ids arrays for current page (no normalization/padding here) */
string build_render_payload(string title, string body, list btns, key av, string session, string ctx, string plugin_script){
    /* Save session mapping */
    string labels = jarr();
    string ids    = jarr();

    integer out_i = 0;
    integer n = llGetListLength(btns);
    integer i = 0;
    while (i < n){
        string b = llList2String(btns, i);
        string lab = json_str(b, ["label"], "");
        string id  = json_str(b, ["id"], "");
        labels = llJsonSetValue(labels, [ (string)out_i ], lab);
        ids    = llJsonSetValue(ids,    [ (string)out_i ], id);
        out_i = out_i + 1;
        i = i + 1;
    }

    /* Store/replace session */
    integer sidx = -1;
    integer sn = llGetListLength(Sessions);
    integer si = 0;
    while (si < sn){
        if (llList2String(Sessions, si) == session){ sidx = si; si = sn; }
        else si = si + S_STRIDE;
    }
    if (sidx != -1){
        Sessions = llListReplaceList(Sessions, [ session, (string)av, plugin_script, ctx, labels, ids ], sidx, sidx + S_STRIDE - 1);
    } else {
        Sessions += [ session, (string)av, plugin_script, ctx, labels, ids ];
    }

    string menu = jobj();
    menu = jset(menu, ["title"], title);
    menu = jset(menu, ["prompt"], body);
    menu = jset(menu, ["ctx"], ctx);
    /* FE expects "buttons" to be objects {label,id} */
    string btnArr = jarr();
    integer k = 0;
    while (k < out_i){
        string item = jobj();
        item = jset(item, ["label"], llJsonGetValue(labels, [ (string)k ]));
        item = jset(item, ["id"],    llJsonGetValue(ids,    [ (string)k ]));
        btnArr = llJsonSetValue(btnArr, [ (string)k ], item);
        k = k + 1;
    }
    menu = jset(menu, ["buttons"], btnArr);
    return menu;
}

/* Send render to FE */
integer fe_render(string coreRid, string menuJson){
    string j = jobj();
    j = jset(j, ["type"], T_UI_RENDER);
    j = jset(j, ["from"], "ui_backend");
    j = jset(j, ["to"], "ui_frontend");
    j = jset(j, ["req_id"], coreRid);  /* FE can ignore or use */
    j = jset(j, ["menu"], menuJson);
    j = jset(j, ["abi"], (string)ABI_VERSION);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* Route click back to plugin */
integer route_click_to_plugin(string plugin_script, string session, string choice_id, string label, string ctx){
    string j = jobj();
    j = jset(j, ["type"], T_UI_EVENT);
    j = jset(j, ["from"], "ui_backend");
    j = jset(j, ["to"], plugin_script);
    j = jset(j, ["session"], session);
    j = jset(j, ["choice_id"], choice_id);
    j = jset(j, ["label"], label);
    j = jset(j, ["ctx"], ctx);
    j = jset(j, ["abi"], (string)ABI_VERSION);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* Start/ensure AUTH for avatar; if cached, return 1 immediately */
integer ensure_auth_for(key av, string reqRid, string session, string plugin_script, string draw_payload_json){
    /* Cached? */
    integer lvl = ac_get_level(av);
    if (lvl != -1) return TRUE;

    /* Not cached: request AUTH */
    string authRid = rid();
    Pending += [ authRid, session, (string)av, plugin_script, draw_payload_json ];

    string j = jobj();
    j = jset(j, ["type"], T_AUTH_QUERY);
    j = jset(j, ["from"], "ui_backend");
    j = jset(j, ["to"], "auth");
    j = jset(j, ["req_id"], authRid);
    j = jset(j, ["avatar"], (string)av);
    j = jset(j, ["abi"], (string)ABI_VERSION);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return FALSE;
}

/* Handle a ui_draw (validate, filter, render or wait for AUTH) */
integer handle_ui_draw(string msg){
    key av            = (key)json_str(msg, ["avatar"], (string)NULL_KEY);
    string session    = json_str(msg, ["session"], "");
    string plugin     = json_str(msg, ["script"], "");        /* plugin script name */
    string title      = json_str(msg, ["title"], "");
    string body       = json_str(msg, ["body"], "");
    string ctx        = json_str(msg, ["context"], jobj());
    string btnArrRaw  = llJsonGetValue(msg, ["buttons"]);

    if (av == NULL_KEY) return FALSE;
    if (session == "") session = rid();
    if (plugin == "") return FALSE;

    /* If no AUTH cached, queue this draw and request AUTH */
    integer haveAuth = ensure_auth_for(av, "", session, plugin, msg);
    if (!haveAuth) return TRUE;

    /* We have AUTH now (cached) → process immediately */
    integer level = ac_get_level(av);
    integer isw   = ac_get_is_wearer(av);
    integer p_tpe = ac_get_policy_tpe(av);
    integer p_pub = ac_get_policy_public_only(av);
    integer p_po  = ac_get_policy_primary_owner(av);

    /* Validate + filter */
    list valid = [];
    integer i = 0; integer done = FALSE;
    while (!done){
        string b = llJsonGetValue(btnArrRaw, [ (string)i ]);
        if (b == JSON_INVALID) done = TRUE;
        else{
            if (is_valid_btn(b)){
                if (allow_button(b, level, isw, p_tpe, p_pub, p_po)) valid += b;
            } else {
                if (DEBUG) llOwnerSay("[UI-BE] Dropped invalid button from " + plugin);
            }
            i = i + 1;
        }
    }

    /* Build render payload (labels+ids) and send to FE */
    string menu = build_render_payload(title, body, valid, av, session, ctx, plugin);
    fe_render(rid(), menu);
    return TRUE;
}

/* After AUTH result, replay any pending ui_draw for that avatar */
integer drain_pending_for_auth(string authRid, integer level, integer isw, integer p_tpe, integer p_pub, integer p_po){
    integer idx = llListFindList(Pending, [authRid]);
    if (idx == -1) return FALSE;

    string session        = llList2String(Pending, idx + 1);
    key av                = (key)llList2String(Pending, idx + 2);
    string plugin_script  = llList2String(Pending, idx + 3);
    string draw_payload   = llList2String(Pending, idx + 4);

    Pending = llDeleteSubList(Pending, idx, idx + P_STRIDE - 1);

    ac_put(av, level, isw, p_tpe, p_pub, p_po);

    /* Process the original ui_draw now */
    handle_ui_draw(draw_payload);
    return TRUE;
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        AuthCache = [];
        Sessions  = [];
        Pending   = [];
        logd("UI backend ready (blank-canvas; strict buttons)");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_UI_BE_IN) return;

        string t = llJsonGetValue(msg, ["type"]);

        /* FE touch is ignored here (the separate harness/plugin may use it) */
        if (t == T_UI_TOUCH){
            /* no-op */
            return;
        }

        /* Plugins ask to draw a menu/page */
        if (t == T_UI_DRAW){
            handle_ui_draw(msg);
            return;
        }

        /* FE reports a click */
        if (t == T_UI_CLICK){
            string session = json_str(msg, ["session"], "");
            string label   = json_str(msg, ["label"], "");
            integer index  = json_int(msg, ["index"], -1);

            if (session == "") return;

            /* Find session */
            integer n = llGetListLength(Sessions);
            integer i = 0; integer base = -1;
            while (i < n){
                if (llList2String(Sessions, i) == session){ base = i; i = n; }
                else i = i + S_STRIDE;
            }
            if (base == -1) return;

            key av = (key)llList2String(Sessions, base + 1);
            string plugin_script = llList2String(Sessions, base + 2);
            string ctx = llList2String(Sessions, base + 3);
            string labels = llList2String(Sessions, base + 4);
            string ids    = llList2String(Sessions, base + 5);

            string choice_id = "";
            if (index >= 0){
                choice_id = llJsonGetValue(ids, [ (string)index ]);
            }
            if (choice_id == "" && label != ""){
                /* fallback: search by label */
                integer k = 0; integer found = FALSE;
                while (!found){
                    string L = llJsonGetValue(labels, [ (string)k ]);
                    if (L == JSON_INVALID) found = TRUE;
                    else{
                        if (L == label){
                            choice_id = llJsonGetValue(ids, [ (string)k ]);
                            found = TRUE;
                        } else {
                            k = k + 1;
                        }
                    }
                }
            }
            if (choice_id == "") return;

            route_click_to_plugin(plugin_script, session, choice_id, label, ctx);
            return;
        }

        /* AUTH replies */
        if (t == T_AUTH_RESULT){
            string authRid = json_str(msg, ["req_id"], "");
            integer level  = json_int(msg, ["level"], -1);
            integer isw    = json_int(msg, ["is_wearer"], 0);
            integer p_tpe  = json_int(msg, ["policy_tpe"], 0);
            integer p_pub  = json_int(msg, ["policy_public_only"], 0);
            integer p_po   = json_int(msg, ["policy_primary_owner"], 0);
            drain_pending_for_auth(authRid, level, isw, p_tpe, p_pub, p_po);
            return;
        }
    }
}
