// ============================================================
// MODULE: ds_collar_kmod_ui_backend.lsl  (API-compliant Backend)
// ARCH  : Everything via ds_collar_api.lsl
// LANES : IN  L_UI_BE_IN (-1600)  | OUT L_API (-1000)
// FRONT : FE listens on L_UI_FE_IN; API will deliver ui_render there
//
// CONTRACTS
//  FE → BE:  ui_touch (req), ui_click (req w/ index & label)
//  Plugin → BE: ui_draw (event)  -- strict buttons: {label,id,min_acl,...}
//  BE → Auth: auth_query (req)   -- reply auth_result (res) to ui_backend via API
//  BE → FE:   ui_render (event)  -- {title,prompt,buttons:[{label,id}],ctx{avatar,session}}
//
// SECURITY
//  • Drop any button missing label|id|min_acl (default-deny).
//  • ACL-filter using auth_result (level/is_wearer/policies).
//  • Store filtered route per session to resolve FE click index→choice_id.
// ============================================================

integer DEBUG = TRUE;

/* ----- ABI / Lanes ----- */
integer ABI_VERSION   = 1;
integer L_API         = -1000;
integer L_BROADCAST   = -1001; // used only for re-emitting ui_touch as event to "any"
integer L_SETTINGS_IN = -1300;
integer L_AUTH_IN     = -1400;
integer L_ACL_IN      = -1500;
integer L_UI_BE_IN    = -1600; // THIS module's input (API delivers here)
integer L_UI_FE_IN    = -1700; // FE input (API delivers ui_render here)

/* ----- Message types ----- */
string T_UI_TOUCH   = "ui_touch";
string T_UI_DRAW    = "ui_draw";
string T_UI_RENDER  = "ui_render";
string T_UI_CLICK   = "ui_click";
string T_AUTH_Q     = "auth_query";
string T_AUTH_RES   = "auth_result";

/* ----- JSON helpers ----- */
string jnew(){ return llList2Json(JSON_OBJECT, []); }
string jarr(){ return llList2Json(JSON_ARRAY, []); }
string jset(string j, list path, string v){ return llJsonSetValue(j, path, v); }
integer to_int(string s){ if (s == "" || s == JSON_INVALID) return 0; return (integer)s; }
string rid(){ return (string)llGetUnixTime() + "-" + (string)llRound(llFrand(9999.0)); }

/* ----- API send helper (requests and events) ----- */
integer api_send(string type, string toMod, string reqId, list kv){
    string j = jnew();
    j = jset(j, ["type"], type);
    j = jset(j, ["from"], "ui_backend");
    j = jset(j, ["to"],   toMod);
    j = jset(j, ["abi"],  (string)ABI_VERSION);
    if (reqId != "") j = jset(j, ["req_id"], reqId);

    integer i = 0; integer n = llGetListLength(kv);
    while (i + 1 < n){
        string k = llList2String(kv, i);
        string v = llList2String(kv, i + 1);
        j = jset(j, [k], v);
        i += 2;
    }
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* ========== State ==========

Sessions[i]      = session string
Draws[i]         = JSON { avatar,title,body,ctx,script,buttons_raw }
Routes[i]        = JSON_ARRAY [{ "id":..., "label":... }, ...] (filtered order for FE)
AuthRIDs[k]      = auth req_id
AuthSess[k]      = session for that req_id

---------------------------------------------- */
list Sessions;
list Draws;
list Routes;
list AuthRIDs;
list AuthSess;

integer idx_session(string s){ return llListFindList(Sessions, [s]); }
integer idx_authrid(string r){ return llListFindList(AuthRIDs, [r]); }

integer put_draw(string session, string drawJ){
    integer i = idx_session(session);
    if (i == -1){
        Sessions += session;
        Draws    += drawJ;
        Routes   += jarr(); // init empty route
    } else {
        Draws  = llListReplaceList(Draws,  [drawJ], i, i);
        // keep existing Routes slot as-is
    }
    return TRUE;
}
string get_draw(string session){
    integer i = idx_session(session);
    if (i == -1) return "";
    return llList2String(Draws, i);
}
integer put_route(string session, string routeArr){
    integer i = idx_session(session);
    if (i == -1) return FALSE;
    Routes = llListReplaceList(Routes, [routeArr], i, i);
    return TRUE;
}
string get_route(string session){
    integer i = idx_session(session);
    if (i == -1) return "";
    return llList2String(Routes, i);
}
integer put_auth_map(string req, string session){
    AuthRIDs += req; AuthSess += session; return TRUE;
}
string take_auth_session(string req){
    integer i = idx_authrid(req);
    if (i == -1) return "";
    string s = llList2String(AuthSess, i);
    AuthRIDs = llDeleteSubList(AuthRIDs, i, i);
    AuthSess = llDeleteSubList(AuthSess, i, i);
    return s;
}

/* ========== Button validation & ACL ========== */
integer btn_valid(string b){
    string lbl = llJsonGetValue(b, ["label"]);
    string id  = llJsonGetValue(b, ["id"]);
    string ma  = llJsonGetValue(b, ["min_acl"]);
    if (lbl == JSON_INVALID || id == JSON_INVALID || ma == JSON_INVALID) return FALSE;
    if (lbl == "" || id == "") return FALSE;
    return TRUE;
}
integer btn_allowed(string b, integer level, integer is_wearer, integer p_tpe, integer p_pub_only, integer p_po){
    integer min_acl = to_int(llJsonGetValue(b, ["min_acl"]));
    if (level < min_acl) return FALSE;

    string audience = llJsonGetValue(b, ["audience"]); // "wearer" only
    if (audience == "wearer" && !is_wearer) return FALSE;

    if (to_int(llJsonGetValue(b, ["owner_only"]))   && level < 5) return FALSE;
    if (to_int(llJsonGetValue(b, ["trustee_only"])) && level < 3) return FALSE;
    if (to_int(llJsonGetValue(b, ["tpe_only"]))     && !p_tpe)     return FALSE;

    if (p_pub_only && min_acl > 1) return FALSE;

    // p_po hook available for primary-owner distinctions if needed
    return TRUE;
}

/* ========== Flows ========== */

/* ui_touch (REQ from FE) → re-emit as EVENT to "any" so harness/plugins can decide to draw */
integer handle_ui_touch(string msg){
    key av = (key)llJsonGetValue(msg, ["avatar"]);
    if (DEBUG) llOwnerSay("[UI-BE] ← ui_touch av=" + (string)av);

    // rebroadcast as event (no req_id) so harness/plugins listening to "any" can react
    api_send(T_UI_TOUCH, "any", "", ["avatar", (string)av]);
    return TRUE;
}

/* ui_draw (EVENT from plugin/harness) */
integer handle_ui_draw(string msg){
    key    avatar  = (key)llJsonGetValue(msg, ["avatar"]);
    string session = llJsonGetValue(msg, ["session"]);
    string script  = llJsonGetValue(msg, ["script"]);  // route-back for ui_click
    string title   = llJsonGetValue(msg, ["title"]);
    string body    = llJsonGetValue(msg, ["body"]);
    string ctx     = llJsonGetValue(msg, ["context"]);
    string buttons = llJsonGetValue(msg, ["buttons"]); // array of button objects

    if (DEBUG) llOwnerSay("[UI-BE] ← ui_draw session=" + session + " av=" + (string)avatar);

    if (avatar == NULL_KEY || session == "" || script == "" || buttons == JSON_INVALID){
        if (DEBUG) llOwnerSay("[UI-BE] drop ui_draw (missing fields)");
        return TRUE;
    }

    if (title == JSON_INVALID) title = "";
    if (body  == JSON_INVALID) body  = "";
    if (ctx   == JSON_INVALID){
        string c = jnew();
        c = jset(c, ["avatar"], (string)avatar);
        c = jset(c, ["session"], session);
        ctx = c;
    }

    string draw = jnew();
    draw = jset(draw, ["avatar"], (string)avatar);
    draw = jset(draw, ["title"],  title);
    draw = jset(draw, ["body"],   body);
    draw = jset(draw, ["ctx"],    ctx);
    draw = jset(draw, ["script"], script);
    draw = llJsonSetValue(draw, ["buttons_raw"], buttons);
    put_draw(session, draw);

    // Request AUTH via API; API will route auth_result back to our lane with to:"ui_backend"
    string r = rid();
    put_auth_map(r, session);
    api_send(T_AUTH_Q, "auth", r, ["avatar", (string)avatar]);

    if (DEBUG) llOwnerSay("[UI-BE] → auth_query rid=" + r + " av=" + (string)avatar);
    return TRUE;
}

/* auth_result (RES) → filter + render + store route map */
integer handle_auth_result(string msg){
    string req = llJsonGetValue(msg, ["req_id"]);
    string session = take_auth_session(req);
    if (session == "") return FALSE;

    string draw = get_draw(session);
    if (draw == ""){
        if (DEBUG) llOwnerSay("[UI-BE] auth_result: unknown session");
        return TRUE;
    }

    key    avatar = (key)llJsonGetValue(draw, ["avatar"]);
    string title  = llJsonGetValue(draw, ["title"]);
    string body   = llJsonGetValue(draw, ["body"]);
    string ctx    = llJsonGetValue(draw, ["ctx"]);
    string btnArr = llJsonGetValue(draw, ["buttons_raw"]);

    integer level = to_int(llJsonGetValue(msg, ["level"]));
    integer isw   = to_int(llJsonGetValue(msg, ["is_wearer"]));
    integer p_tpe = to_int(llJsonGetValue(msg, ["policy_tpe"]));
    integer p_pub = to_int(llJsonGetValue(msg, ["policy_public_only"]));
    integer p_po  = to_int(llJsonGetValue(msg, ["policy_primary_owner"]));

    // Validate + ACL-filter
    string filteredButtons = jarr(); // for FE
    string routeArr        = jarr(); // for BE click mapping
    integer outIdx = 0;

    integer i = 0; integer done = FALSE;
    while (!done){
        string b = llJsonGetValue(btnArr, [(string)i]);
        if (b == JSON_INVALID){
            done = TRUE;
        } else {
            integer keep = FALSE;
            if (btn_valid(b)){
                if (btn_allowed(b, level, isw, p_tpe, p_pub, p_po)) keep = TRUE;
            }
            if (keep){
                string lbl = llJsonGetValue(b, ["label"]);
                string cid = llJsonGetValue(b, ["id"]);

                string feItem = llList2Json(JSON_OBJECT, ["label", lbl, "id", cid]);
                filteredButtons = llJsonSetValue(filteredButtons, [(string)outIdx], feItem);

                string rItem = llList2Json(JSON_OBJECT, ["label", lbl, "id", cid]);
                routeArr = llJsonSetValue(routeArr, [(string)outIdx], rItem);

                outIdx++;
            } else if (DEBUG){
                string why = "invalid";
                if (btn_valid(b)) why = "acl";
                llOwnerSay("[UI-BE] drop button (" + why + "): " + llGetSubString(b, 0, 160));
            }
            i++;
        }
    }

    // Persist click route map for this session
    put_route(session, routeArr);

    // Build FE menu (prompt = body)
    string menu = jnew();
    menu = jset(menu, ["title"],  title);
    menu = jset(menu, ["prompt"], body);
    menu = llJsonSetValue(menu, ["buttons"], filteredButtons);
    menu = jset(menu, ["ctx"],    ctx); // must carry avatar/session

    // Send ui_render via API to ui_frontend
    api_send(T_UI_RENDER, "ui_frontend", "", [
        "avatar",  (string)avatar,
        "session", session,
        "menu",    menu
    ]);

    if (DEBUG) llOwnerSay("[UI-BE] → ui_render session=" + session);
    return TRUE;
}

/* ui_click (REQ from FE) → map index→id and forward to plugin (REQ, preserving req_id) */
integer handle_ui_click(string msg){
    string session  = llJsonGetValue(msg, ["session"]);
    string ridIn    = llJsonGetValue(msg, ["req_id"]);
    integer index   = to_int(llJsonGetValue(msg, ["index"]));
    string label    = llJsonGetValue(msg, ["label"]); // may be " " (padding)
    string ctx      = llJsonGetValue(msg, ["ctx"]);
    if (ctx == JSON_INVALID) ctx = jnew();

    // Ignore padded blanks or nonsense
    if (label == " "){
        if (DEBUG) llOwnerSay("[UI-BE] ui_click: ignoring padded blank");
        return TRUE;
    }

    string routeArr = get_route(session);
    if (routeArr == ""){
        if (DEBUG) llOwnerSay("[UI-BE] ui_click: no route for session=" + session);
        return TRUE;
    }

    string r = llJsonGetValue(routeArr, [(string)index]);
    if (r == JSON_INVALID){
        if (DEBUG) llOwnerSay("[UI-BE] ui_click: invalid index=" + (string)index);
        return TRUE;
    }

    string choiceId = llJsonGetValue(r, ["id"]);
    if (choiceId == JSON_INVALID || choiceId == ""){
        if (DEBUG) llOwnerSay("[UI-BE] ui_click: missing choice_id");
        return TRUE;
    }

    string draw = get_draw(session);
    if (draw == ""){
        if (DEBUG) llOwnerSay("[UI-BE] ui_click: unknown session");
        return TRUE;
    }
    string plugin = llJsonGetValue(draw, ["script"]);
    if (plugin == "" || plugin == JSON_INVALID){
        if (DEBUG) llOwnerSay("[UI-BE] ui_click: missing plugin route");
        return TRUE;
    }

    // Forward to the plugin; preserve FE's req_id so API can thread any plugin response to FE if needed
    api_send(T_UI_CLICK, plugin, ridIn, [
        "session",   session,
        "choice_id", choiceId,
        "label",     label,
        "ctx",       ctx
    ]);

    if (DEBUG) llOwnerSay("[UI-BE] → ui_click to " + plugin + " id=" + choiceId);
    return TRUE;
}

/* ========== Events ========== */
default{
    state_entry(){
        Sessions = []; Draws = []; Routes = []; AuthRIDs = []; AuthSess = [];
        if (DEBUG) llOwnerSay("[UI-BE] ready (API mode)");
    }
    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        // API routes messages for this module to L_UI_BE_IN only
        if (num != L_UI_BE_IN) return;

        string to = llJsonGetValue(msg, ["to"]);
        if (to != "ui_backend") return;

        string ty = llJsonGetValue(msg, ["type"]);

        if (ty == T_UI_TOUCH){ handle_ui_touch(msg);   return; }
        if (ty == T_UI_DRAW) { handle_ui_draw(msg);    return; }
        if (ty == T_AUTH_RES){ handle_auth_result(msg);return; }
        if (ty == T_UI_CLICK){ handle_ui_click(msg);   return; }
    }
}
