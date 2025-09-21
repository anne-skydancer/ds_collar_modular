/* =============================================================
 MODULE: ds_collar_kmod_ui_backend.lsl
 ROLE  : UI backend
         - Receives ui_touch from FE → rebroadcasts ui_touched to plugins
         - Receives ui_register_buttons → stores menus by context
         - Receives ui_draw → queries ACL, filters buttons, emits ui_render
         - Receives ui_show_message → renders simple message dialog
 LANES :  L_API (-1000), L_BROADCAST (-1001), L_UI_BE_IN (-1600)
 DEPENDS: api (router), acl, ui_frontend
 ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-BE] " + s); return 0; }

/* Lanes */
integer L_API        = -1000;
integer L_BROADCAST  = -1001;
integer L_UI_BE_IN   = -1600;

/* Types */
string T_HELLO        = "hello";
string T_UI_TOUCH     = "ui_touch";      // FE → BE
string T_UI_TOUCHED   = "ui_touched";    // BE → any (broadcast for plugins)
string T_UI_DRAW      = "ui_draw";       // plugin → BE
string T_UI_RENDER    = "ui_render";     // BE → FE (via API)
string T_UI_REGISTER  = "ui_register_buttons";
string T_UI_BUTTON    = "ui_button";     // FE → any (plugins handle)
string T_UI_CLOSE     = "ui_close";
string T_UI_MESSAGE   = "ui_show_message";

string T_ACL_FILTER   = "acl_filter";
string T_ACL_FRES     = "acl_filter_result";

/* Pending ACL requests: stride=7
   [req_id, avatar, session, context, title, body, buttons_json] */
list Pending; integer PS = 7;

/* Menus by context: stride=2 [context, buttons_json] */
list Menus;   integer MS = 2;

/* JSON helpers */
string J(){ return llList2Json(JSON_OBJECT, []); }
string JA(){ return llList2Json(JSON_ARRAY, []); }
string JSET(string j, list path, string v){ return llJsonSetValue(j, path, v); }
string JGET(string j, list path){ return llJsonGetValue(j, path); }

/* Pending helpers */
string new_req_id(){
    return "be-" + (string)llGetUnixTime() + "-" + llGetSubString((string)llGenerateKey(),0,7);
}
integer pend_add(string rid, key av, string sid, string ctx, string t, string b, string btns){
    Pending += [rid, (string)av, sid, ctx, t, b, btns];
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

/* Menus */
integer menu_set(string ctx, string btns){
    integer i=0; integer n=llGetListLength(Menus);
    while (i<n){
        if (llList2String(Menus,i) == ctx){
            Menus = llListReplaceList(Menus, [ctx, btns], i, i+MS-1);
            return TRUE;
        }
        i += MS;
    }
    Menus += [ctx, btns];
    return TRUE;
}
string menu_get(string ctx){
    integer i=0; integer n=llGetListLength(Menus);
    while (i<n){
        if (llList2String(Menus,i) == ctx) return llList2String(Menus,i+1);
        i += MS;
    }
    return JSON_INVALID;
}

/* ---------- Button normalization & filtering ---------- */
integer btn_ok(string item){
    // Accept shapes:
    // A) {"label":"..","id":"..","min_acl":"N"}
    // B) ["Label","feature_id","next_ctx","payload","min_acl"]
    string label = JGET(item, ["label"]);
    string idv   = JGET(item, ["id"]);
    if (label != JSON_INVALID && idv != JSON_INVALID) return TRUE;

    if (llJsonValueType(item, []) == JSON_ARRAY){
        list tup = llJson2List(item);
        if (llGetListLength(tup) >= 2){
            string lab = llList2String(tup, 0);
            string fid = llList2String(tup, 1);
            if (lab != "" && fid != "") return TRUE;
        }
    }
    return FALSE;
}
integer btn_min_acl(string item){
    string mv = JGET(item, ["min_acl"]);
    if (mv != JSON_INVALID && mv != "") return (integer)mv;
    if (llJsonValueType(item, []) == JSON_ARRAY){
        list tup = llJson2List(item);
        if (llGetListLength(tup) >= 5){
            string s = llList2String(tup, 4);
            if (s != "") return (integer)s;
        }
    }
    return 0;
}
string btn_label(string item){
    string lab = JGET(item, ["label"]);
    if (lab != JSON_INVALID) return lab;
    if (llJsonValueType(item, []) == JSON_ARRAY) return llList2String(llJson2List(item), 0);
    return "";
}
string btn_id(string item){
    string idv = JGET(item, ["id"]);
    if (idv != JSON_INVALID) return idv;
    if (llJsonValueType(item, []) == JSON_ARRAY) return llList2String(llJson2List(item), 1);
    return "";
}

string filter_buttons_by_level(string btns_json, integer level){
    if (btns_json == JSON_INVALID) return "[]";
    if (llJsonValueType(btns_json, []) != JSON_ARRAY) return "[]";

    list out = [];
    integer n = llGetListLength(llJson2List(btns_json));
    integer i=0;
    while (i<n){
        string item = llJsonGetValue(btns_json, [i]);
        if (btn_ok(item)){
            integer need = btn_min_acl(item);
            if (level >= need){
                // Normalize to object form for FE
                string o = J();
                o = JSET(o, ["label"], btn_label(item));
                o = JSET(o, ["id"],    btn_id(item));
                out += [o];
            }
        }
        i += 1;
    }
    return llList2Json(JSON_ARRAY, out);
}

/* ---------- ACL query ---------- */
integer request_level_for(key av, string sid, string ctx, string title, string body, string btns){
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

    pend_add(rid, av, sid, ctx, title, body, btns);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    if (DEBUG) logd("REQ acl_filter rid="+rid+" for "+(string)av);
    return TRUE;
}

/* ---------- Render to FE ---------- */
integer render_to_frontend(key av, string sid, string ctx, string title, string body, string btns_filtered){
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

    llMessageLinked(LINK_SET, L_API, r, NULL_KEY);
    if (DEBUG) logd("EVT ui_render → FE (avatar="+(string)av+", sid="+sid+", ctx="+ctx+")");
    return TRUE;
}

/* ---------- Open a stored context ---------- */
integer handle_open_context(key av, string sid, string ctx){
    string btns = menu_get(ctx);
    if (btns == JSON_INVALID){
        if (DEBUG) logd("no menu for context '"+ctx+"'");
        render_to_frontend(av, sid, ctx, "Oops", "No UI registered for '"+ctx+"'.", "[]");
        return FALSE;
    }
    return request_level_for(av, sid, ctx, "Menu", "", btns);
}

/* =============================================================
 EVENTS
============================================================= */
default{
    state_entry(){
        Pending = [];
        Menus   = [];

        // optional hello (lets the router know our lane)
        string hello = J();
        hello = JSET(hello, ["type"], T_HELLO);
        hello = JSET(hello, ["from"], "ui_backend");
        hello = JSET(hello, ["to"],   "api");
        hello = JSET(hello, ["abi"],  "1");
        hello = JSET(hello, ["lane"], (string)L_UI_BE_IN);
        llMessageLinked(LINK_SET, L_API, hello, NULL_KEY);

        logd("UI-BE up");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        /* --------- From API router to backend lane --------- */
        if (num == L_UI_BE_IN){
            string ty = JGET(msg, ["type"]);

            if (ty == T_UI_TOUCH){
                // Re-broadcast as ui_touched so plugins (CanvasDraw) can react
                key av = (key)JGET(msg, ["avatar"]);
                string b = J();
                b = JSET(b, ["type"],    T_UI_TOUCHED);
                b = JSET(b, ["from"],    "ui_backend");
                b = JSET(b, ["to"],      "any");
                b = JSET(b, ["abi"],     "1");
                b = JSET(b, ["avatar"],  (string)av);
                llMessageLinked(LINK_SET, L_BROADCAST, b, NULL_KEY);
                if (DEBUG) logd("EVT ui_touched broadcast for "+(string)av);
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
                string ctx =      JGET(payload, ["context"]); if (ctx == JSON_INVALID) ctx = "home";
                string t   =      JGET(payload, ["title"]);   if (t   == JSON_INVALID) t   = "Menu";
                string bdy =      JGET(payload, ["body"]);    if (bdy == JSON_INVALID) bdy = "";
                string btns =     JGET(payload, ["buttons"]); if (btns== JSON_INVALID) btns= "[]";

                if (av == NULL_KEY){ if (DEBUG) logd("ui_draw missing avatar"); return; }
                request_level_for(av, sid, ctx, t, bdy, btns);
                return;
            }

            if (ty == T_UI_MESSAGE){
                key    av = (key)JGET(msg, ["avatar"]);
                string sid= JGET(msg, ["session"]); // optional
                string ctx= JGET(msg, ["context"]); if (ctx == JSON_INVALID) ctx = "message";
                string t  = JGET(msg, ["title"]);   if (t   == JSON_INVALID) t   = "Info";
                string m  = JGET(msg, ["message"]); if (m   == JSON_INVALID) m   = "";
                string ok = llList2Json(JSON_ARRAY, [ JSET(J(), ["label"], "OK"), JSET(J(), ["id"], "ok") ]);
                render_to_frontend(av, sid, ctx, t, m, llList2Json(JSON_ARRAY, [ JSET(J(), ["label"], "OK"), JSET(J(), ["id"], "ok") ]));
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

                integer level = (integer)JGET(msg, ["level"]);
                string filtered = filter_buttons_by_level(btns, level);
                render_to_frontend(av, sid, ctx, t, bdy, filtered);
                return;
            }

            return;
        }

        /* --------- Broadcasts (optional context open) --------- */
        if (num == L_BROADCAST){
            string ty = JGET(msg, ["type"]);
            if (ty == T_UI_BUTTON){
                key    av  = (key)JGET(msg, ["avatar"]);
                string fid =       JGET(msg, ["feature_id"]);
                // If a button id equals a known context, open it here
                if (menu_get(fid) != JSON_INVALID){
                    // No session provided here; FE/API will maintain per-avatar session
                    handle_open_context(av, "", fid);
                    return;
                }
            }
            return;
        }
    }
}
