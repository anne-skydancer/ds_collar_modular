// ============================================================
// MODULE: ds_collar_test_harness.lsl  (Blank-Canvas + API-only)
// ROLE  : Minimal driver for Settings/Auth/ACL via API
//         + Sample plugin driving the new UI BE/FE.
//
// USAGE (owner chat /11):
//   /11 seed
//   /11 auth (wearer)            | /11 auth <uuid>
//   /11 owner <uuid>             | (use "none" to clear)
//   /11 trustees ["uuid1","uuid2",...]
//   /11 public 1|0               | /11 restricted 1|0
//   /11 reg <feature> <min>      | e.g. /11 reg plugin.leash.menu 2
//   /11 policy <feature> <min>   | e.g. /11 policy plugin.leash.menu 3
//   /11 q <feature> <uuid>
//   /11 f <uuid> <f1> <f2> ...
//
// NEW (blank-canvas UI):
//   /11 draw (wearer|<uuid>)     -> Send strict ui_draw to UI-BE
//   /11 redraw                   -> Redraw last test menu
//
// NOTES:
//  • All sends go to L_API (-1000). All receives come from L_BROADCAST (-1001).
//  • UI clicks (BE→plugin) are delivered with "to" == llGetScriptName().
//  • Buttons must include: label, id, min_acl (strict).
// ============================================================

integer L_API       = -1000; // send to API ingress
integer L_BROADCAST = -1001; // receive fanout (rebroadcast)

integer DEBUG = TRUE;

/* ---------- Utils ---------- */
string rid(){
    return (string)llGetUnixTime() + "-" + (string)llRound(llFrand(9999.0));
}
integer send_kv(string type, integer lane, list kv){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], type);
    j = llJsonSetValue(j, ["from"], llGetScriptName());
    integer i = 0; integer n = llGetListLength(kv);
    while (i + 1 < n){
        string k = llList2String(kv, i);
        string v = llList2String(kv, i + 1);
        j = llJsonSetValue(j, [k], v);
        i += 2;
    }
    llMessageLinked(LINK_SET, lane, j, NULL_KEY);
    return TRUE;
}
string jnew(){ return llList2Json(JSON_OBJECT, []); }
string jset(string j, list path, string v){ return llJsonSetValue(j, path, v); }
string jarr(){ return llList2Json(JSON_ARRAY, []); }

/* ---------- Session state (for /11 draw & /11 redraw) ---------- */
key     g_lastAvatar  = NULL_KEY;
string  g_lastSession = "";
string  g_lastTitle   = "Harness Menu";
string  g_lastPrompt  = "This is a test page rendered via UI-BE/FE.\nChoose an option:";
string  g_lastContext = "";   // JSON with {"avatar":..., "session":...}
string  g_lastButtons = "";   // JSON array of button objects

/* ---------- Button builders (STRICT) ---------- */
string mk_btn(string label, string id, integer min_acl){
    return llList2Json(JSON_OBJECT, ["label", label, "id", id, "min_acl", (string)min_acl]);
}
string mk_btn_owner_only(string label, string id){
    string j = mk_btn(label, id, 5);
    j = jset(j, ["owner_only"], "1");
    return j;
}
string mk_btn_trustee_only(string label, string id){
    string j = mk_btn(label, id, 3);
    j = jset(j, ["trustee_only"], "1");
    return j;
}
string mk_btn_wearer_only(string label, string id, integer min_acl){
    string j = mk_btn(label, id, min_acl);
    j = jset(j, ["audience"], "wearer");
    return j;
}
string mk_btn_tpe_only(string label, string id){
    string j = mk_btn(label, id, 0);
    j = jset(j, ["tpe_only"], "1");
    return j;
}

/* A small test menu with varied ACL/policy flags */
string build_test_buttons(){
    string arr = jarr();
    integer idx = 0;

    arr = llJsonSetValue(arr, [(string)idx], mk_btn("Hello (min 1)", "hello", 1)); idx++;
    arr = llJsonSetValue(arr, [(string)idx], mk_btn_trustee_only("Trustee Tool", "trustee_tool")); idx++;
    arr = llJsonSetValue(arr, [(string)idx], mk_btn_owner_only("Owner Panel", "owner_panel")); idx++;
    arr = llJsonSetValue(arr, [(string)idx], mk_btn_wearer_only("Wearer Option", "wearer_opt", 1)); idx++;
    arr = llJsonSetValue(arr, [(string)idx], mk_btn_tpe_only("TPE-Only Button", "tpe_btn")); idx++;
    arr = llJsonSetValue(arr, [(string)idx], mk_btn("Close", "close", 1));

    return arr;
}

/* Emit ui_draw to UI-BE (STRICT) via API */
integer ui_draw_to_backend(key avatar, string session, string title, string prompt, string buttons_json){
    string ctx = jnew();
    ctx = jset(ctx, ["avatar"], (string)avatar);
    ctx = jset(ctx, ["session"], session);

    string j = jnew();
    j = jset(j, ["type"], "ui_draw");
    j = jset(j, ["from"], llGetScriptName());
    j = jset(j, ["to"], "ui_backend");
    j = jset(j, ["req_id"], rid());
    j = jset(j, ["script"], llGetScriptName());  // where BE should route clicks
    j = jset(j, ["avatar"], (string)avatar);
    j = jset(j, ["session"], session);
    j = jset(j, ["title"], title);
    j = jset(j, ["body"],  prompt);
    j = jset(j, ["context"], ctx);
    j = llJsonSetValue(j, ["buttons"], buttons_json);

    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    if (DEBUG) llOwnerSay("→ ui_draw (session=" + session + " avatar=" + (string)avatar + ")");
    return TRUE;
}

/* ---------- Original commands (unchanged semantics) ---------- */
integer cmd_seed(){
    string r = rid();
    string j = jnew();
    j = jset(j, ["type"], "settings_get");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"], "settings");
    j = jset(j, ["req_id"], r);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    llOwnerSay("→ get snapshot rid=" + r);
    return TRUE;
}
integer cmd_auth(string who){
    key av = llGetOwner();
    if (who != "" && who != "(wearer)"){
        key k = (key)who;
        if (k != NULL_KEY) av = k;
    }
    string r = rid();

    // Send as "tester" so auth_result routes back to the harness.
    string j = jnew();
    j = jset(j, ["type"], "auth_query");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"],   "auth");
    j = jset(j, ["req_id"], r);
    j = jset(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);

    llOwnerSay("→ auth_query rid=" + r + " avatar=" + (string)av + " (to tester)");
    return TRUE;
}
integer cmd_owner(string u){
    string val = JSON_NULL;
    if (u != "" && u != "none") val = "\"" + llToLower(u) + "\"";
    string r = rid();
    string j = jnew();
    j = jset(j, ["type"], "settings_put");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"], "settings");
    j = jset(j, ["req_id"], r);
    j = jset(j, ["path"], "core.owner.key");
    j = jset(j, ["vtype"], "uuid");
    j = jset(j, ["value"], val);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    llOwnerSay("→ set owner=" + u + " rid=" + r);
    return TRUE;
}
integer cmd_trustees(string raw){
    string r = rid();
    string j = jnew();
    j = jset(j, ["type"], "settings_put");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"], "settings");
    j = jset(j, ["req_id"], r);
    j = jset(j, ["path"], "core.trustees");
    j = jset(j, ["vtype"], "list_string");
    j = jset(j, ["value"], raw);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    llOwnerSay("→ set trustees=" + raw + " rid=" + r);
    return TRUE;
}
integer cmd_public(integer v){
    string r = rid();
    string j = jnew();
    j = jset(j, ["type"], "settings_put");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"], "settings");
    j = jset(j, ["req_id"], r);
    j = jset(j, ["path"], "core.public.mode");
    j = jset(j, ["vtype"], "int");
    j = jset(j, ["value"], (string)v);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    llOwnerSay("→ public=" + (string)v + " rid=" + r);
    return TRUE;
}
integer cmd_restricted(integer v){
    string r = rid();
    string j = jnew();
    j = jset(j, ["type"], "settings_put");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"], "settings");
    j = jset(j, ["req_id"], r);
    j = jset(j, ["path"], "core.restricted.mode");
    j = jset(j, ["vtype"], "int");
    j = jset(j, ["value"], (string)v);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    llOwnerSay("→ restricted=" + (string)v + " rid=" + r);
    return TRUE;
}
integer cmd_reg(string fid, integer minL){
    string r = rid();
    string j = jnew();
    j = jset(j, ["type"], "acl_register_feature");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"], "acl");
    j = jset(j, ["req_id"], r);
    j = jset(j, ["feature_id"], fid);
    j = jset(j, ["default_min_level"], (string)minL);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    llOwnerSay("→ register feature " + fid + " default=" + (string)minL + " rid=" + r);
    return TRUE;
}
integer cmd_policy(string fid, integer lvl){
    string r = rid();
    string j = jnew();
    j = jset(j, ["type"], "acl_set_policy");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"], "acl");
    j = jset(j, ["req_id"], r);
    j = jset(j, ["feature_id"], fid);
    j = jset(j, ["min_level"], (string)lvl);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    llOwnerSay("→ set policy " + fid + " -> " + (string)lvl + " rid=" + r);
    return TRUE;
}
integer cmd_q(string fid, key av){
    string r = rid();
    string j = jnew();
    j = jset(j, ["type"], "acl_query");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"], "acl");
    j = jset(j, ["req_id"], r);
    j = jset(j, ["avatar"], (string)av);
    j = jset(j, ["feature_id"], fid);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    llOwnerSay("→ acl_query " + fid + " by " + (string)av + " rid=" + r);
    return TRUE;
}
integer cmd_f(key av, list feats){
    string arr = llList2Json(JSON_ARRAY, feats);
    string r = rid();
    string j = jnew();
    j = jset(j, ["type"], "acl_filter");
    j = jset(j, ["from"], "tester");
    j = jset(j, ["to"], "acl");
    j = jset(j, ["req_id"], r);
    j = jset(j, ["avatar"], (string)av);
    j = jset(j, ["features"], arr);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    llOwnerSay("→ acl_filter rid=" + r);
    return TRUE;
}

/* ---------- Commands: DRAW / REDRAW ---------- */
integer cmd_draw(string who){
    key av = llGetOwner();

    // normalize aliases for wearer
    if (who != ""){
        string w = llToLower(who);
        if (w == "wearer" || w == "(wearer)"){
            av = llGetOwner();
        } else {
            key k = (key)who;
            if (k != NULL_KEY) av = k; // only accept if it's a real key
        }
    }

    if (av == NULL_KEY){
        llOwnerSay("draw: no valid avatar key; aborting.");
        return FALSE;
    }

    string session = rid();
    g_lastAvatar  = av;
    g_lastSession = session;
    g_lastButtons = build_test_buttons();

    string ctx = jnew();
    ctx = jset(ctx, ["avatar"], (string)av);
    ctx = jset(ctx, ["session"], session);
    g_lastContext = ctx;

    ui_draw_to_backend(av, session, g_lastTitle, g_lastPrompt, g_lastButtons);
    return TRUE;
}
integer cmd_redraw(){
    if (g_lastAvatar == NULL_KEY || g_lastSession == ""){
        llOwnerSay("no previous session to redraw.");
        return FALSE;
    }
    ui_draw_to_backend(g_lastAvatar, g_lastSession, g_lastTitle, g_lastPrompt, g_lastButtons);
    return TRUE;
}

/* ---------- Events ---------- */
default{
    state_entry(){
        llListen(11, "", llGetOwner(), "");
        if (DEBUG) llOwnerSay("tester: listening on /11");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    listen(integer ch, string name, key id, string msg){
        list t = llParseStringKeepNulls(msg, [" "], []);
        string cmd = llList2String(t, 0);

        if (cmd == "seed"){ cmd_seed(); return; }
        if (cmd == "auth"){ cmd_auth(llList2String(t, 1)); return; }
        if (cmd == "owner"){ cmd_owner(llList2String(t, 1)); return; }
        if (cmd == "trustees"){
            integer sp = llSubStringIndex(msg, " ");
            if (sp == -1){ llOwnerSay("usage: /11 trustees [\"uuid1\",\"uuid2\",...]"); return; }
            string raw = llGetSubString(msg, sp + 1, -1);
            cmd_trustees(raw); return;
        }
        if (cmd == "public"){ cmd_public((integer)llList2String(t, 1)); return; }
        if (cmd == "restricted"){ cmd_restricted((integer)llList2String(t, 1)); return; }
        if (cmd == "reg"){ cmd_reg(llList2String(t, 1), (integer)llList2String(t, 2)); return; }
        if (cmd == "policy"){ cmd_policy(llList2String(t, 1), (integer)llList2String(t, 2)); return; }

        if (cmd == "q"){
            key av = llGetOwner();
            string who = llList2String(t, 2);
            if (who != "" && ((key)who != NULL_KEY)) av = (key)who;
            cmd_q(llList2String(t, 1), av);
            return;
        }
        if (cmd == "f"){
            key av2 = (key)llList2String(t, 1);
            list fl = llList2List(t, 2, -1);
            cmd_f(av2, fl); return;
        }

        if (cmd == "draw"){
            string who = llList2String(t, 1);  // "(wearer)" or <uuid> or empty
            cmd_draw(who); return;
        }
        if (cmd == "redraw"){
            cmd_redraw(); return;
        }
    }

    link_message(integer s, integer num, string msg, key id){
        // API fanout only
        if (num != L_BROADCAST) return;

        string ty = llJsonGetValue(msg, ["type"]);
        string to = llJsonGetValue(msg, ["to"]);

        /* Auto-open menu on FE touch (rebroadcast by API) */
        if (ty == "ui_touch"){
            key av = (key)llJsonGetValue(msg, ["avatar"]);
            if (av != NULL_KEY){
                string session = rid();

                g_lastAvatar  = av;
                g_lastSession = session;
                g_lastButtons = build_test_buttons();

                string ctx = jnew();
                ctx = jset(ctx, ["avatar"], (string)av);
                ctx = jset(ctx, ["session"], session);
                g_lastContext = ctx;

                // 1) draw strictly via backend
                ui_draw_to_backend(av, session, g_lastTitle, g_lastPrompt, g_lastButtons);

                // 2) kick AUTH on behalf of the UI backend so auth_result routes to it
                string ar = rid();
                string aj = jnew();
                aj = jset(aj, ["type"],   "auth_query");
                aj = jset(aj, ["from"],   "ui_backend");  // IMPORTANT: matches your BE module name
                aj = jset(aj, ["to"],     "auth");
                aj = jset(aj, ["req_id"], ar);
                aj = jset(aj, ["avatar"], (string)av);
                llMessageLinked(LINK_SET, L_API, aj, NULL_KEY);

                if (DEBUG) llOwnerSay("← ui_touch " + (string)av
                    + " → ui_draw(session=" + session + "), auth_query rid=" + ar + " (to ui_backend)");
            }
            return;
        }

        /* Handle BE→plugin routed clicks (addressed to this script by name) */
        if (to == llGetScriptName()){
            if (ty == "ui_click"){
                string session  = llJsonGetValue(msg, ["session"]);
                string choiceId = llJsonGetValue(msg, ["choice_id"]);
                string label    = llJsonGetValue(msg, ["label"]);
                string ctx      = llJsonGetValue(msg, ["ctx"]);

                llOwnerSay("← ui_click session=" + session + " id=" + choiceId + " label=" + label);

                if (choiceId == "close"){
                    return; // exit silently
                }
                if (choiceId == "hello"){
                    g_lastPrompt = "You pressed \"" + label + "\".\nPick another:";
                    cmd_redraw();
                    return;
                }

                // default: just redraw same menu
                cmd_redraw();
                return;
            }
        }

        /* Tester control replies (addressed to "tester") */
        string to2 = llJsonGetValue(msg, ["to"]);
        if (to2 == "tester"){
            if (ty == "settings_snapshot"
             || ty == "settings_ack"
             || ty == "error"
             || ty == "acl_register_ack"
             || ty == "acl_set_policy_ack"
             || ty == "acl_result"
             || ty == "acl_filter_result"
             || ty == "auth_result")
            {
                llOwnerSay("← " + ty + ": " + llGetSubString(msg, 0, 800));
                return;
            }
        }
    }
}
