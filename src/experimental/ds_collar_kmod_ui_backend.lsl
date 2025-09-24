/* =============================================================
 MODULE: ds_collar_kmod_ui_backend.lsl
 ROLE  : UI backend
         - Receives ui_touch/ui_click from FE via API lanes
         - Receives ui_register_buttons → stores menus by context
         - Receives ui_draw → queries ACL, filters buttons, emits ui_render
         - Receives ui_show_message → renders simple message dialog
 LANES :  L_API (-1000), L_UI_BE_IN (-1600)
 DEPENDS: api (router), acl, ui_frontend
 ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-BE] " + s); return 0; }

/* Lanes */
integer L_API        = -1000;
integer L_UI_BE_IN   = -1600;

/* Types */
string T_HELLO        = "hello";
string T_UI_TOUCH     = "ui_touch";      // FE → BE
string T_UI_DRAW      = "ui_draw";       // plugin → BE
string T_UI_RENDER    = "ui_render";     // BE → FE (via API)
string T_UI_REGISTER  = "ui_register_buttons";
string T_UI_CLICK     = "ui_click";      // FE → BE
string T_UI_CLOSE     = "ui_close";
string T_UI_MESSAGE   = "ui_show_message";

string T_ACL_FILTER   = "acl_filter";
string T_ACL_FRES     = "acl_filter_result";

/* Pending ACL requests: stride=9
   [req_id, avatar, session, context, title, body, buttons_json, origin_req_id, ts] */
list Pending; integer PS = 9;

integer PENDING_TIMEOUT_SEC = 30;
integer PENDING_SWEEP_INTERVAL = 10;

/* Menus cache block: [context, buttons_json, count, label1, id1, min1, ...] */
list MenuCache;

/* JSON helpers */
string J(){ return llList2Json(JSON_OBJECT, []); }
string JA(){ return llList2Json(JSON_ARRAY, []); }
string JSET(string j, list path, string v){ return llJsonSetValue(j, path, v); }
string JGET(string j, list path){ return llJsonGetValue(j, path); }

string DEFAULT_CONTEXT = "home";

string be_make_session_for(key av){
    return "be" + llGetSubString((string)av, 0, 5) + "-" + (string)llGetUnixTime();
}

/* Pending helpers */
string new_req_id(){
    return "be-" + (string)llGetUnixTime() + "-" + llGetSubString((string)llGenerateKey(),0,7);
}
integer pend_add(string rid, key av, string sid, string ctx, string t, string b, string btns, string origin_req_id){
    Pending += [rid, (string)av, sid, ctx, t, b, btns, origin_req_id, llGetUnixTime()];
    return TRUE;
}
integer pend_idx(string rid){
    integer i=0; integer n=llGetListLength(Pending);
    while (i<n){
        if (llList2String(Pending,i) == rid) return i;
        i += PS;
    }
    return -1;
}
list pend_take(string rid){
    integer i = pend_idx(rid);
    if (i == -1) return [];
    list row = llList2List(Pending, i, i+PS-1);
    Pending = llDeleteSubList(Pending, i, i+PS-1);
    return row;
}

integer pend_sweep(){
    integer now = llGetUnixTime();
    integer i = 0; integer removed = 0; integer n = llGetListLength(Pending);
    while (i < n){
        integer ts = llList2Integer(Pending, i + 8);
        if (now - ts >= PENDING_TIMEOUT_SEC){
            string rid = llList2String(Pending, i);
            key av = (key)llList2String(Pending, i + 1);
            string sid = llList2String(Pending, i + 2);
            string ctx = llList2String(Pending, i + 3);
            string origin_req = llList2String(Pending, i + 7);
            if (DEBUG) logd("drop stale acl_filter rid=" + rid);
            Pending = llDeleteSubList(Pending, i, i + PS - 1);
            n -= PS;
            removed += 1;
            send_close_to_frontend(av, sid, ctx, "acl_timeout", origin_req);
            continue;
        }
        i += PS;
    }
    return removed;
}

list normalize_buttons(string btns_json){
    list norm = [];
    if (btns_json == JSON_INVALID) return norm;
    if (llJsonValueType(btns_json, []) != JSON_ARRAY) return norm;

    list raw = llJson2List(btns_json);
    integer n = llGetListLength(raw);
    integer i = 0;
    while (i < n){
        string item = llList2String(raw, i);
        string label = "";
        string idv = "";
        integer min_acl = 0;

        if (llJsonValueType(item, []) == JSON_OBJECT){
            label = llJsonGetValue(item, ["label"]);
            idv   = llJsonGetValue(item, ["id"]);
            string mv = llJsonGetValue(item, ["min_acl"]);
            if (mv != JSON_INVALID && mv != "") min_acl = (integer)mv;
        } else if (llJsonValueType(item, []) == JSON_ARRAY){
            list tup = llJson2List(item);
            integer tn = llGetListLength(tup);
            if (tn >= 2){
                label = llList2String(tup, 0);
                idv   = llList2String(tup, 1);
                if (tn >= 5){
                    string mv2 = llList2String(tup, 4);
                    if (mv2 != "") min_acl = (integer)mv2;
                }
            }
        }

        if (label != JSON_INVALID && idv != JSON_INVALID && label != "" && idv != ""){
            norm += [label, idv, min_acl];
        }
        i += 1;
    }
    return norm;
}

integer normalized_count(list norm){
    return llGetListLength(norm) / 3;
}

integer menu_index(string ctx){
    integer i = 0; integer n = llGetListLength(MenuCache);
    while (i < n){
        if (llList2String(MenuCache, i) == ctx) return i;
        integer count = llList2Integer(MenuCache, i + 2);
        i += 3 + (count * 3);
    }
    return -1;
}

integer menu_exists(string ctx){
    return (menu_index(ctx) != -1);
}

string menu_get_buttons_json(string ctx){
    integer idx = menu_index(ctx);
    if (idx == -1) return JSON_INVALID;
    return llList2String(MenuCache, idx + 1);
}

list menu_get_norm_list(string ctx){
    integer idx = menu_index(ctx);
    if (idx == -1) return [];
    integer count = llList2Integer(MenuCache, idx + 2);
    if (count <= 0) return [];
    integer start = idx + 3;
    integer end = start + (count * 3) - 1;
    return llList2List(MenuCache, start, end);
}

integer menu_set(string ctx, string btns){
    list norm = normalize_buttons(btns);
    integer count = normalized_count(norm);
    list block = [ctx, btns, count];
    block += norm;

    integer idx = menu_index(ctx);
    if (idx == -1){
        MenuCache += block;
    } else {
        integer oldCount = llList2Integer(MenuCache, idx + 2);
        integer span = 3 + (oldCount * 3);
        MenuCache = llDeleteSubList(MenuCache, idx, idx + span - 1);
        MenuCache = llListInsertList(MenuCache, block, idx);
    }
    return TRUE;
}

/* ---------- Button normalization & filtering ---------- */
string filter_from_normalized(list norm, integer level){
    list out = [];
    integer count = normalized_count(norm);
    integer i = 0; integer idx = 0;
    while (i < count){
        string label = llList2String(norm, idx);
        string idv   = llList2String(norm, idx + 1);
        integer need = llList2Integer(norm, idx + 2);
        if (level >= need){
            string o = J();
            o = JSET(o, ["label"], label);
            o = JSET(o, ["id"],    idv);
            out += [o];
        }
        i += 1;
        idx += 3;
    }
    return llList2Json(JSON_ARRAY, out);
}

string filter_buttons_raw(string btns_json, integer level){
    list norm = normalize_buttons(btns_json);
    if (llGetListLength(norm) == 0) return "[]";
    return filter_from_normalized(norm, level);
}

string filter_buttons_for_context(string ctx, string btns_json, integer level){
    list norm = [];
    if (ctx != JSON_INVALID && ctx != "") norm = menu_get_norm_list(ctx);
    if (llGetListLength(norm) == 0) norm = normalize_buttons(btns_json);
    if (llGetListLength(norm) == 0) return "[]";
    return filter_from_normalized(norm, level);
}

/* ---------- ACL query ---------- */
integer request_level_for(key av, string sid, string ctx, string title, string body, string btns, string origin_req_id){
    string rid = new_req_id();

    string features = JA(); // empty: just want "level"
    string j = J();
    j = JSET(j, ["type"],    T_ACL_FILTER);
    j = JSET(j, ["from"],    "ui_backend");
    j = JSET(j, ["to"],      "acl");
    j = JSET(j, ["abi"],     "1");
    j = JSET(j, ["req_id"],  rid);
    j = JSET(j, ["avatar"],  (string)av);
    j = JSET(j, ["features"], features);

    pend_add(rid, av, sid, ctx, title, body, btns, origin_req_id);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    if (DEBUG) logd("REQ acl_filter rid="+rid+" for "+(string)av);
    return TRUE;
}

/* ---------- Render to FE ---------- */
integer render_to_frontend(key av, string sid, string ctx, string title, string body, string btns_filtered, string origin_req_id){
    string r = J();
    r = JSET(r, ["type"],    T_UI_RENDER);
    r = JSET(r, ["from"],    "ui_backend");
    r = JSET(r, ["to"],      "ui_frontend");
    r = JSET(r, ["abi"],     "1");
    r = JSET(r, ["avatar"],  (string)av);
    r = JSET(r, ["session"], sid);
    r = JSET(r, ["context"], ctx);
    r = JSET(r, ["title"],   title);
    r = JSET(r, ["body"],    body);
    r = llJsonSetValue(r, ["buttons"], btns_filtered);
    if (origin_req_id != "") r = JSET(r, ["req_id"], origin_req_id);

    llMessageLinked(LINK_SET, L_API, r, NULL_KEY);
    if (DEBUG) logd("EVT ui_render → FE (avatar="+(string)av+", sid="+sid+", ctx="+ctx+")");
    return TRUE;
}

integer send_close_to_frontend(key av, string sid, string ctx, string reason, string origin_req_id){
    string c = J();
    c = JSET(c, ["type"],   T_UI_CLOSE);
    c = JSET(c, ["from"],   "ui_backend");
    c = JSET(c, ["to"],     "ui_frontend");
    c = JSET(c, ["abi"],    "1");
    if (origin_req_id != "") c = JSET(c, ["req_id"], origin_req_id);
    if (av != NULL_KEY) c = JSET(c, ["avatar"], (string)av);
    if (sid != "") c = JSET(c, ["session"], sid);
    if (ctx != "") c = JSET(c, ["context"], ctx);
    if (reason != "") c = JSET(c, ["reason"], reason);
    llMessageLinked(LINK_SET, L_API, c, NULL_KEY);
    if (DEBUG) logd("EVT ui_close → FE (ctx="+ctx+", reason="+reason+")");
    return TRUE;
}

/* ---------- Open a stored context ---------- */
integer handle_open_context(key av, string sid, string ctx, string origin_req_id){
    string use_sid = sid;
    if (use_sid == "") use_sid = be_make_session_for(av);

    string use_ctx = ctx;
    if (use_ctx == JSON_INVALID || use_ctx == "") use_ctx = DEFAULT_CONTEXT;

    string btns = menu_get_buttons_json(use_ctx);
    if (btns == JSON_INVALID){
        if (DEBUG) logd("no menu for context '"+use_ctx+"'");
        render_to_frontend(av, use_sid, use_ctx, "Oops", "No UI registered for '"+use_ctx+"'.", "[]", origin_req_id);
        return FALSE;
    }
    return request_level_for(av, use_sid, use_ctx, "Menu", "", btns, origin_req_id);
}

/* =============================================================
 EVENTS
============================================================= */
default{
    state_entry(){
        Pending = [];
        MenuCache = [];

        // optional hello (lets the router know our lane)
        string hello = J();
        hello = JSET(hello, ["type"], T_HELLO);
        hello = JSET(hello, ["from"], "ui_backend");
        hello = JSET(hello, ["to"],   "api");
        hello = JSET(hello, ["abi"],  "1");
        hello = JSET(hello, ["lane"], (string)L_UI_BE_IN);
        llMessageLinked(LINK_SET, L_API, hello, NULL_KEY);

        llSetTimerEvent(PENDING_SWEEP_INTERVAL);
        logd("UI-BE up");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        /* --------- From API router to backend lane --------- */
        if (num == L_UI_BE_IN){
            string ty = JGET(msg, ["type"]);

            if (ty == T_UI_TOUCH){
                key av = (key)JGET(msg, ["avatar"]);
                string req = JGET(msg, ["req_id"]);
                string sid = JGET(msg, ["session"]);
                string ctx = JGET(msg, ["context"]);
                if (ctx == JSON_INVALID) ctx = DEFAULT_CONTEXT;

                string rid = req;
                if (rid == JSON_INVALID) rid = "";

                if (av == NULL_KEY){
                    if (DEBUG) logd("ui_touch missing avatar");
                    if (rid != "") send_close_to_frontend(NULL_KEY, "", DEFAULT_CONTEXT, "Missing avatar", rid);
                    return;
                }

                handle_open_context(av, sid, ctx, rid);
                return;
            }

            if (ty == T_UI_CLICK){
                key avc = (key)JGET(msg, ["avatar"]);
                string reqc = JGET(msg, ["req_id"]);
                string sidc = JGET(msg, ["session"]);
                string ctxc = JGET(msg, ["context"]);
                string command = JGET(msg, ["command"]);
                if (command == JSON_INVALID || command == "") command = JGET(msg, ["feature_id"]);

                string ridc = reqc;
                if (ridc == JSON_INVALID) ridc = "";

                if (avc == NULL_KEY){
                    if (DEBUG) logd("ui_click missing avatar");
                    if (ridc != "") send_close_to_frontend(NULL_KEY, "", DEFAULT_CONTEXT, "Missing avatar", ridc);
                    return;
                }

                string use_ctx = ctxc;
                if (use_ctx == JSON_INVALID || use_ctx == "") use_ctx = DEFAULT_CONTEXT;

                if (command == JSON_INVALID || command == ""){
                    render_to_frontend(avc, sidc, use_ctx, "Unhandled", "No command provided.", "[]", ridc);
                    return;
                }

                if (menu_exists(command)){
                    handle_open_context(avc, sidc, command, ridc);
                    return;
                }

                render_to_frontend(avc, sidc, use_ctx, "Unhandled", "No handler for '"+command+"'.", "[]", ridc);
                return;
            }

            if (ty == T_UI_REGISTER){
                string ctx  = JGET(msg, ["context"]);
                string btns = JGET(msg, ["buttons"]);
                if (ctx != JSON_INVALID && btns != JSON_INVALID){
                    menu_set(ctx, btns);
                    if (DEBUG) logd("registered menu for ctx="+ctx);
                }
                return;
            }

            if (ty == T_UI_DRAW){
                string payload = JGET(msg, ["payload"]);
                if (payload == JSON_INVALID){
                    if (DEBUG) logd("ui_draw missing payload"); 
                    return;
                }
                // Ask ACL, then render
                key    av  = (key)JGET(payload, ["avatar"]);
                string sid =      JGET(payload, ["session"]);
                string ctx =      JGET(payload, ["context"]); if (ctx == JSON_INVALID) ctx = DEFAULT_CONTEXT;
                string t   =      JGET(payload, ["title"]);   if (t   == JSON_INVALID) t   = "Menu";
                string bdy =      JGET(payload, ["body"]);    if (bdy == JSON_INVALID) bdy = "";
                string btns =     JGET(payload, ["buttons"]); if (btns== JSON_INVALID) btns= "[]";

                if (av == NULL_KEY){ if (DEBUG) logd("ui_draw missing avatar"); return; }
                request_level_for(av, sid, ctx, t, bdy, btns, "");
                return;
            }

            if (ty == T_UI_MESSAGE){
                key    av = (key)JGET(msg, ["avatar"]);
                string sid= JGET(msg, ["session"]); // optional
                string ctx= JGET(msg, ["context"]); if (ctx == JSON_INVALID) ctx = "message";
                string t  = JGET(msg, ["title"]);   if (t   == JSON_INVALID) t   = "Info";
                string m  = JGET(msg, ["message"]); if (m   == JSON_INVALID) m   = "";
                string ridm = JGET(msg, ["req_id"]);
                string okButton = JSET(JSET(J(), ["label"], "OK"), ["id"], "ok");
                string buttons = llList2Json(JSON_ARRAY, [okButton]);
                if (ridm == JSON_INVALID) ridm = "";
                render_to_frontend(av, sid, ctx, t, m, buttons, ridm);
                return;
            }

            if (ty == T_ACL_FRES){
                string rid = JGET(msg, ["req_id"]);
                list row = pend_take(rid);
                if (llGetListLength(row) == 0) return; // not ours

                key    av  = (key)llList2String(row, 1);
                string sid =       llList2String(row, 2);
                string ctx =       llList2String(row, 3);
                string t   =       llList2String(row, 4);
                string bdy =       llList2String(row, 5);
                string btns=       llList2String(row, 6);
                string origin_req = llList2String(row, 7);

                integer level = (integer)JGET(msg, ["level"]);
                string filtered = filter_buttons_for_context(ctx, btns, level);
                render_to_frontend(av, sid, ctx, t, bdy, filtered, origin_req);
                return;
            }

            return;
        }

    }

    timer(){
        pend_sweep();
    }
}
