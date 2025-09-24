/* =============================================================
 FILE: ds_collar_kmod_ui_frontend.lsl
 ROLE: UI Frontend with per-avatar sessions + listen-by-SID routing
       - On touch_start: send ui_touch (avatar)
       - On ui_render: track SID per avatar; render llDialog
       - On dialog reply: accept ONLY on the avatar's SID-derived channel,
         then send ui_click (command + label + context)
 LANES:
   L_API       (-1000)  (FE talks to API)
   L_UI_FE_IN  (-1700)  (ingress from API for ui_render/ui_close)
 ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-FE] " + s); return 0; }

/* Lanes */
integer L_API       = -1000;
integer L_UI_FE_IN  = -1700;

/* Message types */
string T_UI_TOUCH   = "ui_touch";    // FE → BE (via API)
string T_UI_RENDER  = "ui_render";   // BE → FE (via API routing to L_UI_FE_IN)
string T_UI_CLOSE   = "ui_close";    // BE → FE
string T_UI_CLICK   = "ui_click";    // FE → BE (via API)

string MOD_FE       = "ui_frontend";
string MOD_BE       = "ui_backend";

string fe_new_req_id(){
    return "fe-" + (string)llGetUnixTime() + "-" + llGetSubString((string)llGenerateKey(), 0, 3);
}

/* ---------------- Per-avatar state (all stride-2 lists) ---------------- */
/* SID per avatar: [ avatar_key, session ] */
list   AV2SID;   integer SS = 2;
/* Last render hash per avatar: [ avatar_key, hash ] */
list   AV2HASH;  integer HS = 2;
/* Dialog channel per avatar: [ avatar_key, channel ] */
list   AV2CHAN;  integer CS = 2;
/* Listen handle per avatar: [ avatar_key, listen_handle ] */
list   AV2LHN;   integer LS = 2;
/* Button maps per avatar: [ avatar_key, labels_json, ids_json, context ] */
list   AV2BTNS;  integer BS = 4;

/* ---------------- JSON helpers ---------------- */
string J(){ return llList2Json(JSON_OBJECT, []); }
string JA(){ return llList2Json(JSON_ARRAY, []); }
string JSET(string j, list path, string v){ return llJsonSetValue(j, path, v); }
string JGET(string j, list path){ return llJsonGetValue(j, path); }

/* ---------------- Small list helpers ---------------- */
integer idx(list L, integer stride, key av){
    integer i=0; integer n=llGetListLength(L);
    while (i<n){
        if ((key)llList2String(L, i) == av) return i;
        i += stride;
    }
    return -1;
}

/* SID get/set/del */
string sid_get(key av){
    integer i = idx(AV2SID, SS, av);
    if (i == -1) return "";
    return llList2String(AV2SID, i+1);
}
integer sid_set(key av, string sid){
    integer i = idx(AV2SID, SS, av);
    if (i == -1) AV2SID += [(string)av, sid];
    else AV2SID = llListReplaceList(AV2SID, [(string)av, sid], i, i+SS-1);
    return TRUE;
}
integer sid_del(key av){
    integer i = idx(AV2SID, SS, av);
    if (i != -1) AV2SID = llDeleteSubList(AV2SID, i, i+SS-1);
    return TRUE;
}

/* HASH get/set/del */
string hash_get(key av){
    integer i = idx(AV2HASH, HS, av);
    if (i == -1) return "";
    return llList2String(AV2HASH, i+1);
}
integer hash_set(key av, string h){
    integer i = idx(AV2HASH, HS, av);
    if (i == -1) AV2HASH += [(string)av, h];
    else AV2HASH = llListReplaceList(AV2HASH, [(string)av, h], i, i+HS-1);
    return TRUE;
}
integer hash_del(key av){
    integer i = idx(AV2HASH, HS, av);
    if (i != -1) AV2HASH = llDeleteSubList(AV2HASH, i, i+HS-1);
    return TRUE;
}

/* CHAN get/set/del */
integer chan_get(key av){
    integer i = idx(AV2CHAN, CS, av);
    if (i == -1) return 0;
    return llList2Integer(AV2CHAN, i+1);
}
integer chan_set(key av, integer ch){
    integer i = idx(AV2CHAN, CS, av);
    if (i == -1) AV2CHAN += [(string)av, ch];
    else AV2CHAN = llListReplaceList(AV2CHAN, [(string)av, ch], i, i+CS-1);
    return TRUE;
}
integer chan_del(key av){
    integer i = idx(AV2CHAN, CS, av);
    if (i != -1) AV2CHAN = llDeleteSubList(AV2CHAN, i, i+CS-1);
    return TRUE;
}

/* LHN get/set/del (listen handles) */
integer lhn_get(key av){
    integer i = idx(AV2LHN, LS, av);
    if (i == -1) return 0;
    return llList2Integer(AV2LHN, i+1);
}
integer lhn_set(key av, integer h){
    integer i = idx(AV2LHN, LS, av);
    if (i == -1) AV2LHN += [(string)av, h];
    else AV2LHN = llListReplaceList(AV2LHN, [(string)av, h], i, i+LS-1);
    return TRUE;
}
integer lhn_del(key av){
    integer i = idx(AV2LHN, LS, av);
    if (i != -1) AV2LHN = llDeleteSubList(AV2LHN, i, i+LS-1);
    return TRUE;
}

/* Button maps get/set/del */
integer btn_idx(key av){ return idx(AV2BTNS, BS, av); }
integer btn_set(key av, string labels_json, string ids_json, string context){
    integer i = btn_idx(av);
    if (i == -1) AV2BTNS += [(string)av, labels_json, ids_json, context];
    else AV2BTNS = llListReplaceList(AV2BTNS, [(string)av, labels_json, ids_json, context], i, i+BS-1);
    return TRUE;
}
list btn_get(key av){
    integer i = btn_idx(av);
    if (i == -1) return [];
    return llList2List(AV2BTNS, i, i+BS-1);
}
integer btn_del(key av){
    integer i = btn_idx(av);
    if (i != -1) AV2BTNS = llDeleteSubList(AV2BTNS, i, i+BS-1);
    return TRUE;
}

/* ---------------- Utility helpers (built-ins only) ---------------- */
string fe_make_session_for(key av){
    return llGetSubString((string)av,0,7) + "-" + (string)llGetUnixTime() + "-" + llGetSubString((string)llGenerateKey(),0,3);
}
string fe_render_hash(string t, string b, string btns_json){
    // Stable string hash using LSL's MD5; just for equality checks
    return llMD5String(t + "|" + b + "|" + btns_json, 0);
}
integer fe_channel_from_sid(string sid){
    // Hash SID → int using base64→int; return safe negative chat channel
    integer h = llBase64ToInteger(llStringToBase64(sid));
    if (h == 0) h = (integer)llGetUnixTime();   // fallback if somehow zero
    if (h > 0)  h = -h;                         // negative channels are safer
    if (h > -1000) h -= 1000;                   // push away from small negatives
    return h;
}

/* ---------------- Button parsing ----------------
   Accept two shapes from backend:
   A) [{ "label":"...", "id":"..." }, ...]
   B) [[label, feature_id, next_ctx, payload, min_acl], ...]  (we use label + feature_id)
*/
list parse_buttons_to_label_id_pairs(string btns_json){
    list out = []; // stride-2 [label, id]
    if (btns_json == JSON_INVALID) return out;
    if (llJsonValueType(btns_json, []) != JSON_ARRAY) return out;

    integer n = llGetListLength(llJson2List(btns_json));
    integer i=0;
    while (i < n){
        string item = llJsonGetValue(btns_json, [i]);

        string lab = JGET(item, ["label"]);
        string idv = JGET(item, ["id"]);

        if (lab == JSON_INVALID || idv == JSON_INVALID){
            // try tuple shape (flat array)
            list t = llJson2List(item);
            if (llGetListLength(t) >= 2){
                lab = llList2String(t, 0);
                idv = llList2String(t, 1);
            }
        }
        if (lab != JSON_INVALID && idv != JSON_INVALID && lab != "" && idv != ""){
            out += [lab, idv];
        }
        i += 1;
    }
    return out;
}

/* ---------------- Dialog helpers ---------------- */
integer start_listen_for_avatar(key av, integer ch){
    // stop previous listen for this avatar, if any
    integer old = lhn_get(av);
    if (old) llListenRemove(old);
    integer h = llListen(ch, "", av, ""); // restrict to that avatar
    if (!h) h = llListen(ch, "", NULL_KEY, ""); // fallback if some viewers misreport
    lhn_set(av, h);
    return h;
}

integer show_dialog_for_avatar(key av, string title, string body, list labels, integer ch){
    if (llGetListLength(labels) == 0) labels = ["(no options)"];
    // llDialog shows up to 12 buttons; if more, backend should paginate.
    llDialog(av, title + "\n" + body, labels, ch);
    return TRUE;
}

/* ---------------- Senders to backend (through API) ---------------- */
integer send_ui_touch(key av){
    string j = J();
    j = JSET(j, ["type"], T_UI_TOUCH);
    j = JSET(j, ["from"], MOD_FE);
    j = JSET(j, ["to"],   MOD_BE);
    j = JSET(j, ["abi"],  "1");
    j = JSET(j, ["req_id"], fe_new_req_id());
    j = JSET(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

integer send_ui_click(key av, string sid, string context, string command, string label){
    string j = J();
    j = JSET(j, ["type"], T_UI_CLICK);
    j = JSET(j, ["from"], MOD_FE);
    j = JSET(j, ["to"],   MOD_BE);
    j = JSET(j, ["abi"],  "1");
    j = JSET(j, ["req_id"], fe_new_req_id());
    j = JSET(j, ["avatar"],    (string)av);
    if (sid != "") j = JSET(j, ["session"],  sid);
    if (context != "") j = JSET(j, ["context"],    context);
    j = JSET(j, ["command"],   command);
    j = JSET(j, ["feature_id"], command);
    j = JSET(j, ["label"],     label);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* =========================
   EVENTS
   ========================= */
default{
    state_entry(){
        AV2SID = []; AV2HASH = []; AV2CHAN = []; AV2LHN = []; AV2BTNS = [];
        logd("UI-FE up");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    /* TOUCH → tell backend who touched */
    touch_start(integer n){
        integer i=0;
        while (i<n){
            key av = llDetectedKey(i);
            send_ui_touch(av);
            i += 1;
        }
    }

    /* INGRESS from API: ui_render / ui_close (on L_UI_FE_IN) */
    link_message(integer s, integer num, string msg, key id){
        if (num != L_UI_FE_IN) return;

        string ty = JGET(msg, ["type"]);

        if (ty == T_UI_RENDER){
            key    av   = (key)JGET(msg, ["avatar"]);
            string sid  = JGET(msg, ["session"]);   // may be empty/missing
            string ttl  = JGET(msg, ["title"]);     if (ttl  == JSON_INVALID) ttl  = "Menu";
            string body = JGET(msg, ["body"]);      if (body == JSON_INVALID) body = "";
            string btns = JGET(msg, ["buttons"]);   if (btns == JSON_INVALID) btns = "[]";
            string ctx  = JGET(msg, ["context"]);   if (ctx  == JSON_INVALID) ctx  = "";

            // Ensure per-avatar SID
            if (sid == "" || sid == JSON_INVALID){
                string prev = sid_get(av);
                if (prev == ""){
                    sid = fe_make_session_for(av);
                    sid_set(av, sid);
                } else {
                    sid = prev;
                }
            } else {
                sid_set(av, sid);
            }

            // Duplicate suppression per-avatar (content-based)
            string h = fe_render_hash(ttl, body, btns);
            string prevh = hash_get(av);
            if (prevh == h){
                if (DEBUG) logd("suppress duplicate render (avatar="+(string)av+", sid="+sid+")");
                return;
            }
            hash_set(av, h);

            // Parse buttons → [label,id,label,id,...]
            list pairs = parse_buttons_to_label_id_pairs(btns);
            list labels = [];
            list ids    = [];
            integer m=0; integer M = llGetListLength(pairs);
            while (m < M){
                labels += llList2String(pairs, m);
                ids    += llList2String(pairs, m+1);
                m += 2;
            }

            // Remember label/id mapping for this avatar
            string labels_json = llList2Json(JSON_ARRAY, labels);
            string ids_json    = llList2Json(JSON_ARRAY, ids);
            btn_set(av, labels_json, ids_json, ctx);

            // Make per-avatar channel from SID, start listen for that avatar only
            integer ch = fe_channel_from_sid(sid);
            chan_set(av, ch);
            start_listen_for_avatar(av, ch);

            // Render dialog
            show_dialog_for_avatar(av, ttl, body, labels, ch);
            return;
        }

        if (ty == T_UI_CLOSE){
            key avc = (key)JGET(msg, ["avatar"]);
            // Clear all per-avatar state; dialog is user-closed
            integer h = lhn_get(avc);
            if (h) llListenRemove(h);
            lhn_del(avc);
            chan_del(avc);
            sid_del(avc);
            hash_del(avc);
            btn_del(avc);
            if (DEBUG) logd("ui_close for avatar "+(string)avc);
            return;
        }
    }

    /* Dialog replies — only accept on the avatar's SID-derived channel */
    listen(integer ch, string name, key av, string txt){
        string sid = sid_get(av);
        if (sid == "") return; // no active session for this avatar

        integer expected = fe_channel_from_sid(sid);
        if (ch != expected) return; // wrong channel (not this avatar's session)

        // Lookup buttons for this avatar
        list row = btn_get(av);
        if (llGetListLength(row) == 0) return;

        string labels_json = llList2String(row, 1);
        string ids_json    = llList2String(row, 2);
        string context     = llList2String(row, 3);

        list labs = llJson2List(labels_json);
        integer i = llListFindList(labs, [txt]);
        if (i == -1) return;

        string fid = llList2String(llJson2List(ids_json), i);
        if (fid == "") return;

        // Send click → backend (explicit FE → BE request)
        send_ui_click(av, sid, context, fid, txt);
    }
}
