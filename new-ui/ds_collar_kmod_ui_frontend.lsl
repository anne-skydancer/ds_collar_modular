/* =============================================================
   ds_collar_kmod_ui_frontend.lsl — UI Renderer (owns llDialog)
   - Shows dialogs for root & plugin pages
   - Sanitizes button labels ("" → " ")
   - Returns clicks to Core (K_VIEW_CLICK), id = avatar key
   - Manages confirmations (tickets, timeouts) and replies to plugins
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-VIEW] " + s); return 0; }

/* Core↔View ABI */
integer K_VIEW_SHOW            = 960;  /* core → view */
integer K_VIEW_CLOSE           = 961;  /* core → view */
integer K_VIEW_CLICK           = 962;  /* view → core */

/* Confirm ABI */
integer K_VIEW_CONFIRM_OPEN    = 970;  /* core → view (normalized) */
integer K_VIEW_CONFIRM_CANCEL  = 971;  /* core → view */
integer K_UI_CONFIRM_RESULT    = 931;  /* view → plugin (unchanged for plugins) */

/* Dialog channels */
integer gListen = 0;
integer gChan   = 0;
key     gUser   = NULL_KEY;

/* Confirm channel / tickets */
integer CH_CONFIRM = -777777;
integer gListenConfirm = 0;
/* rows: "tok|toKey|prompt|buttonsJSON|expEpoch|pluginKey" */
list    g_conf_rows = [];
/* index: "toKey|tok" */
list    g_conf_by_av = [];
integer UI_TICK_SEC = 2;

/* ---------- Helpers ---------- */
list sanitize_buttons(list b){
    list out = [];
    integer i = 0; integer n = llGetListLength(b);
    while (i < n){
        string lab = llList2String(b, i);
        if (lab == "") lab = " ";
        out += [lab];
        i = i + 1;
    }
    if (llGetListLength(out) == 0) out = ["OK"];
    if (llGetListLength(out) > 12) out = llDeleteSubList(out, 12, -1);
    return out;
}
integer json_has(string j, list p){
    if (llJsonGetValue(j,p) == JSON_INVALID) return FALSE;
    return TRUE;
}

/* ---------- Dialog ---------- */
integer reset_listen(){
    if (gListen) llListenRemove(gListen);
    gListen = 0; gChan = 0; gUser = NULL_KEY;
    return 0;
}
integer openDialog(key to, string title, string body, list buttons){
    reset_listen();
    gUser = to;
    gChan = -100000 - (integer)llFrand(1000000.0);
    gListen = llListen(gChan, "", to, "");
    buttons = sanitize_buttons(buttons);
    llDialog(to, title + "\n" + body, buttons, gChan);
    return 0;
}
integer closeDialog(){
    reset_listen();
    return 0;
}

/* ---------- Confirm manager ---------- */
integer conf_find_tok(string tok){
    integer i = 0; integer n = llGetListLength(g_conf_rows);
    while (i < n){
        list p = llParseStringKeepNulls(llList2String(g_conf_rows, i), ["|"], []);
        if (llList2String(p, 0) == tok) return i;
        i = i + 1;
    }
    return -1;
}
integer conf_find_by_av(key to){
    integer i = 0; integer n = llGetListLength(g_conf_by_av);
    while (i < n){
        list p = llParseStringKeepNulls(llList2String(g_conf_by_av, i), ["|"], []);
        if ((key)llList2String(p, 0) == to) return i;
        i = i + 1;
    }
    return -1;
}
string pack_conf(string tok, key to, string prompt, string buttonsJSON, integer exp, key plugin){
    return tok + "|" + (string)to + "|" + prompt + "|" + buttonsJSON + "|" + (string)exp + "|" + (string)plugin;
}
integer conf_add(string tok, key to, string prompt, string btn, integer ttl, key plugin){
    integer exp = llGetUnixTime() + ttl;
    integer j = conf_find_by_av(to);
    if (j != -1){
        string oldTok = llList2String(llParseStringKeepNulls(llList2String(g_conf_by_av, j), ["|"], []), 1);
        integer i = conf_find_tok(oldTok);
        if (i != -1) g_conf_rows = llDeleteSubList(g_conf_rows, i, i);
        g_conf_by_av = llDeleteSubList(g_conf_by_av, j, j);
    }
    g_conf_rows += pack_conf(tok, to, prompt, btn, exp, plugin);
    g_conf_by_av += ((string)to + "|" + tok);

    if (gListenConfirm == 0) gListenConfirm = llListen(CH_CONFIRM, "", "", "");
    return 1;
}
integer conf_show(key to, string prompt, string buttonsJSON){
    list labels = [];
    integer i = 0;
    while (llJsonValueType(buttonsJSON, [ i ]) != JSON_INVALID){
        string lab = "";
        if (llJsonValueType(buttonsJSON, [ i, 1 ]) != JSON_INVALID) lab = llJsonGetValue(buttonsJSON, [ i, 1 ]);
        if (lab == "") lab = " ";
        labels += lab;
        i = i + 1;
    }
    labels = sanitize_buttons(labels);
    llDialog(to, prompt, labels, CH_CONFIRM);
    return TRUE;
}
integer conf_remove(string tok){
    integer i = conf_find_tok(tok);
    if (i == -1) return 0;
    list row = llParseStringKeepNulls(llList2String(g_conf_rows, i), ["|"], []);
    key to = (key)llList2String(row, 1);
    g_conf_rows = llDeleteSubList(g_conf_rows, i, i);
    integer j = conf_find_by_av(to);
    if (j != -1) g_conf_by_av = llDeleteSubList(g_conf_by_av, j, j);
    if (llGetListLength(g_conf_rows) == 0){
        if (gListenConfirm != 0){ llListenRemove(gListenConfirm); gListenConfirm = 0; }
    }
    return 1;
}
integer conf_sweep_timeouts(){
    integer i = 0;
    while (i < llGetListLength(g_conf_rows)){
        list row = llParseStringKeepNulls(llList2String(g_conf_rows, i), ["|"], []);
        integer exp = (integer)llList2String(row, 4);
        if (llGetUnixTime() >= exp){
            string tok = llList2String(row, 0);
            key    to  = (key)llList2String(row, 1);
            string pr  = llList2String(row, 2);
            string btn = llList2String(row, 3);
            key plugin = (key)llList2String(row, 5);

            string r = llList2Json(JSON_OBJECT,[]);
            r = llJsonSetValue(r, ["t"], "uicr");
            r = llJsonSetValue(r, ["ctx"], "");
            r = llJsonSetValue(r, ["tok"], tok);
            r = llJsonSetValue(r, ["from"], (string)to);
            r = llJsonSetValue(r, ["id"],  "");
            r = llJsonSetValue(r, ["label"], "");
            r = llJsonSetValue(r, ["why"], "timeout");
            llMessageLinked(LINK_SET, K_UI_CONFIRM_RESULT, r, plugin);

            conf_remove(tok);
        } else {
            i = i + 1;
        }
    }
    return 1;
}

/* ==================== Events ==================== */
default{
    state_entry(){ llSetTimerEvent((float)UI_TICK_SEC); }
    on_rez(integer sp){ llResetScript(); }

    link_message(integer s, integer n, string m, key id){
        if (n == K_VIEW_SHOW){
            if (!json_has(m,["t"])) return;
            if (llJsonGetValue(m,["t"]) != "show") return;
            key to = (key)llJsonGetValue(m,["to"]);
            string title = llJsonGetValue(m,["title"]);
            string body  = llJsonGetValue(m,["body"]);
            list btns = [];
            integer i = 0;
            while (llJsonValueType(m, ["btn", i]) != JSON_INVALID){
                string lab = "";
                if (llJsonValueType(m, ["btn", i, 0]) != JSON_INVALID) lab = llJsonGetValue(m, ["btn", i, 0]);
                if (lab == "") lab = " ";
                btns += lab;
                i = i + 1;
            }
            openDialog(to, title, body, btns);
            return;
        }
        if (n == K_VIEW_CLOSE){
            closeDialog();
            return;
        }

        if (n == K_VIEW_CONFIRM_OPEN){
            if (!json_has(m,["t"])) return;
            if (llJsonGetValue(m,["t"]) != "c_open") return;
            string tok = llJsonGetValue(m,["tok"]);
            key to     = (key)llJsonGetValue(m,["to"]);
            string prompt = llJsonGetValue(m,["prompt"]);
            string buttons = llJsonGetValue(m,["buttons"]);
            integer ttl = 20; if (json_has(m,["ttl"])) ttl = (integer)llJsonGetValue(m,["ttl"]);
            key plugin = (key)llJsonGetValue(m,["plug"]);

            conf_add(tok, to, prompt, buttons, ttl, plugin);
            conf_show(to, prompt, buttons);
            return;
        }
        if (n == K_VIEW_CONFIRM_CANCEL){
            if (!json_has(m,["t"])) return;
            if (llJsonGetValue(m,["t"]) != "c_cancel") return;
            conf_remove(llJsonGetValue(m,["tok"]));
            return;
        }
    }

    listen(integer chan, string name, key id, string b){
        if (chan == gChan){
            /* return click to Core; include avatar key in id param */
            string j = llList2Json(JSON_OBJECT,[]);
            j = llJsonSetValue(j, ["t"], "click");
            j = llJsonSetValue(j, ["label"], b);
            llMessageLinked(LINK_SET, K_VIEW_CLICK, j, id);
            return;
        }
        if (chan == CH_CONFIRM){
            /* find ticket for this avatar */
            integer jdx = conf_find_by_av(id);
            if (jdx == -1) return;
            string tok = llList2String(llParseStringKeepNulls(llList2String(g_conf_by_av, jdx), ["|"], []), 1);
            integer i = conf_find_tok(tok);
            if (i == -1) return;

            list row = llParseStringKeepNulls(llList2String(g_conf_rows, i), ["|"], []);
            string btnJS  = llList2String(row, 3);
            key    plugin = (key)llList2String(row, 5);

            string clickedId = "";
            integer k = 0;
            while (llJsonValueType(btnJS, [ k ]) != JSON_INVALID){
                string lab = "";
                string cid = "";
                if (llJsonValueType(btnJS, [ k, 1 ]) != JSON_INVALID) lab = llJsonGetValue(btnJS, [ k, 1 ]);
                if (llJsonValueType(btnJS, [ k, 0 ]) != JSON_INVALID) cid = llJsonGetValue(btnJS, [ k, 0 ]);
                if (lab == b) clickedId = cid;
                k = k + 1;
            }
            if (clickedId == "") return;

            string r = llList2Json(JSON_OBJECT,[]);
            r = llJsonSetValue(r, ["t"], "uicr");
            r = llJsonSetValue(r, ["ctx"], "");
            r = llJsonSetValue(r, ["tok"], tok);
            r = llJsonSetValue(r, ["from"], (string)id);
            r = llJsonSetValue(r, ["id"],  clickedId);
            r = llJsonSetValue(r, ["label"], b);
            r = llJsonSetValue(r, ["why"], "ok");
            llMessageLinked(LINK_SET, K_UI_CONFIRM_RESULT, r, plugin);

            conf_remove(tok);
            return;
        }
    }

    timer(){ conf_sweep_timeouts(); }
}
