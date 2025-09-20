/* =============================================================
   MODULE: ds_collar_kmod_bootstrap.lsl  (HEADLESS, API-BASED)
   ROLE  : Bootstrapper w/ RLV probe + owner IM summary
           • On boot: publish runtime info (NO periodic settings writes)
           • Subscribe to owner/trustees changes
           • Resolve owner display name (DisplayName → legacy fallback)
           • IM on boot (and one-time follow-up once owner name resolves)
           • RLV probe (@versionnew) on channels 4711 and ±1812221819
             → persist core.rlv.enabled + core.rlv.version
   CONSTRAINTS:
     • No ternary, no break/continue, no static
     • Globals: PascalCase; Constants: ALL_CAPS; locals: all-lowercase
     • All inter-script messages go via API (L_API)
   ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[BOOT] " + s); return 0; }

/* ---------- ABI ---------- */
integer ABI_VERSION = 1;

/* ---------- Lanes ---------- */
integer L_API       = -1000;
integer L_BROADCAST = -1001;

/* ---------- Message types ---------- */
string TYPE_SETTINGS_PUT        = "settings_put";
string TYPE_SETTINGS_BATCH      = "settings_batch";
string TYPE_SETTINGS_SUB        = "settings_sub";
string TYPE_SETTINGS_SNAPSHOT   = "settings_snapshot";
string TYPE_SETTINGS_SYNC       = "settings_sync";
string TYPE_DISPLAY_NAME_UPDATE = "display_name_update";

/* ---------- Runtime ---------- */
string  RuntimeVersion = "1.0.0";

/* ---------- Settings paths ---------- */
string PATH_OWNER_KEY = "core.owner.key";
string PATH_OWNER_HON = "core.owner.hon";

/* ---------- State ---------- */
string  BootId;

/* Owner state + name resolution */
key    OwnerKey;
string OwnerHon;
string OwnerDisp;
string OwnerLegacy;
integer OwnershipLineSent;
integer OwnershipFollowupSent;
key    OwnerDispReq;
key    OwnerNameReq;

/* Display-name requests queue */
list PendingNames;
integer PN_STRIDE = 2;

/* ---------- RLV probe config ---------- */
integer USE_FIXED_4711          = TRUE;
integer USE_RELAY_CHAN          = TRUE;
integer RELAY_CHAN              = -1812221819;
integer PROBE_RELAY_BOTH_SIGNS  = TRUE;

integer RLV_READY;
integer RLV_ACTIVE;
string  RLV_VERSTR;
list    RlvChans;
list    RlvListens;

integer RLV_PROBING;
integer RLV_WAIT_UNTIL;
integer RLV_SETTLE_UNTIL;
integer RLV_RETRY_EVERY    = 4;
integer RLV_RETRIES;
integer RLV_MAX_RETRIES    = 8;
integer RLV_NEXT_SEND_AT;
float   RLV_SETTLE_SEC     = 1.0;
integer RLV_INITIAL_DELAY_SEC = 1;
integer RLV_PROBE_WINDOW_SEC  = 90;

/* ---------- Helpers ---------- */
integer now(){ return llGetUnixTime(); }
integer is_attached(){ return (integer)llGetAttached() != 0; }

string mk_boot_id(){
    integer t = now();
    float r = llFrand(999999.0);
    string owner = (string)llGetOwner();
    string shortOwner = llGetSubString(owner, 0, 7);
    return (string)t + "-" + (string)llRound(r) + "-" + shortOwner;
}

/* JSON array push */
string json_array_push(string arr, string obj){
    integer i = 0;
    while (llJsonGetValue(arr, [(string)i]) != JSON_INVALID){
        i += 1;
    }
    return llJsonSetValue(arr, [(string)i], obj);
}

/* ---------- API helpers ---------- */
integer api_send(string toMod, string type, list kv){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], type);
    j = llJsonSetValue(j, ["from"], "bootstrap");
    j = llJsonSetValue(j, ["to"], toMod);
    j = llJsonSetValue(j, ["req_id"], (string)now());

    integer i = 0;
    integer n = llGetListLength(kv);
    while (i + 1 < n){
        string k = llList2String(kv, i);
        string v = llList2String(kv, i+1);
        j = llJsonSetValue(j, [k], v);
        i += 2;
    }
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}
integer settings_put(string path, string vtype, string valueJson){
    return api_send("settings", "settings_put", ["path", path, "vtype", vtype, "value", valueJson]);
}
integer settings_batch(list ops){
    string arr = llList2Json(JSON_ARRAY, []);
    integer i = 0;
    integer n = llGetListLength(ops);
    while (i + 3 < n){
        string one = llList2Json(JSON_OBJECT, []);
        one = llJsonSetValue(one, ["op"],    llList2String(ops, i));
        one = llJsonSetValue(one, ["path"],  llList2String(ops, i+1));
        one = llJsonSetValue(one, ["vtype"], llList2String(ops, i+2));
        one = llJsonSetValue(one, ["value"], llList2String(ops, i+3));
        arr = json_array_push(arr, one);
        i += 4;
    }
    return api_send("settings", "settings_batch", ["ops", arr]);
}
integer settings_sub_prefix(string prefix){
    return api_send("settings", "settings_sub", ["prefix", prefix]);
}

/* ---------- Display name handling ---------- */
integer request_display_name(key who){
    key rid = llRequestDisplayName(who);
    PendingNames += [(string)rid, (string)who];
    return TRUE;
}
integer pending_name_idx(string rid){
    integer i = 0;
    integer n = llGetListLength(PendingNames);
    while (i < n){
        if (llList2String(PendingNames, i) == rid) return i;
        i += PN_STRIDE;
    }
    return -1;
}
integer store_display_name(string uuid, string name){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_DISPLAY_NAME_UPDATE);
    j = llJsonSetValue(j, ["from"], "bootstrap");
    j = llJsonSetValue(j, ["to"], "settings");
    j = llJsonSetValue(j, ["req_id"], (string)now());
    j = llJsonSetValue(j, ["uuid"], llToLower(uuid));
    j = llJsonSetValue(j, ["name"], name);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* ---------- Boot publishing (one-shot; NO periodic writes) ---------- */
integer publish_boot_runtime(){
    key wearer = llGetOwner();
    list ops = [
        "put", "core.runtime.boot_id", "string", "\"" + BootId + "\"",
        "put", "core.runtime.version", "string", "\"" + RuntimeVersion + "\"",
        "put", "core.wearer.key",      "uuid",   "\"" + llToLower((string)wearer) + "\""
        /* intentionally NO heartbeat key here */
    ];
    settings_batch(ops);
    return TRUE;
}

/* ---------- IM helpers ---------- */
integer send_im(string msg){
    key w = llGetOwner();
    if (w != NULL_KEY){
        if (msg != ""){
            llInstantMessage(w, msg);
        }
    }
    return TRUE;
}
string owner_label(){
    string nm = "";
    if (OwnerDisp != "") nm = OwnerDisp;
    else {
        if (OwnerLegacy != "") nm = OwnerLegacy;
        else nm = "(fetching…)";
    }
    string hon = OwnerHon;
    string out = "";
    if (hon != "") out = hon + " " + nm;
    else out = nm;
    return out;
}
integer send_rlv_line(){
    string line = "RLV: ";
    if (RLV_READY){
        if (RLV_ACTIVE){
            line += "active";
            if (RLV_VERSTR != "") line += " (" + RLV_VERSTR + ")";
        } else {
            line += "inactive";
        }
    } else {
        if (is_attached()) line += "probing…";
        else line += "inactive (rezzed)";
    }
    send_im(line);
    return TRUE;
}
integer send_ownership_line(){
    string line = "Ownership: ";
    if (OwnerKey != NULL_KEY) line += "owned by " + owner_label();
    else line += "unowned";
    send_im(line);
    return TRUE;
}

/* ---------- Settings updates parsing ---------- */
integer handle_settings_update(string t, string obj){
    string v = JSON_INVALID;

    /* owner key */
    if (t == TYPE_SETTINGS_SNAPSHOT) v = llJsonGetValue(obj, [PATH_OWNER_KEY, "value"]);
    else v = llJsonGetValue(obj, [PATH_OWNER_KEY]);
    if (v != JSON_INVALID){
        if (llGetSubString(v, 0, 0) == "\"" && llGetSubString(v, -1, -1) == "\""){
            v = llGetSubString(v, 1, llStringLength(v)-2);
        }
        key k = (key)v;
        if (k != OwnerKey){
            OwnerKey = k;
            OwnerDisp = "";
            OwnerLegacy = "";
            OwnerDispReq = NULL_KEY;
            OwnerNameReq = NULL_KEY;
            if (OwnerKey != NULL_KEY){
                OwnerDispReq = llRequestDisplayName(OwnerKey);
                OwnerNameReq = llRequestAgentData(OwnerKey, DATA_NAME);
            }
        }
    }

    /* honorific */
    v = JSON_INVALID;
    if (t == TYPE_SETTINGS_SNAPSHOT) v = llJsonGetValue(obj, [PATH_OWNER_HON, "value"]);
    else v = llJsonGetValue(obj, [PATH_OWNER_HON]);
    if (v != JSON_INVALID){
        if (llGetSubString(v, 0, 0) == "\"" && llGetSubString(v, -1, -1) == "\""){
            v = llGetSubString(v, 1, llStringLength(v)-2);
        }
        OwnerHon = v;
    }

    /* Follow-up line once names resolve */
    if (OwnershipLineSent && !OwnershipFollowupSent){
        if (OwnerKey != NULL_KEY){
            if (OwnerDisp != "" || OwnerLegacy != ""){
                send_ownership_line();
                OwnershipFollowupSent = TRUE;
            }
        }
    }
    return TRUE;
}

/* ---------- RLV probe ---------- */
integer rlv_add_channel(integer ch){
    if (ch == 0) return FALSE;
    if (llListFindList(RlvChans, [ch]) != -1) return FALSE;
    integer h = llListen(ch, "", NULL_KEY, "");
    RlvChans += [ch];
    RlvListens += [h];
    if (DEBUG) llOwnerSay("[BOOT] RLV probe channel added: " + (string)ch + " (listen " + (string)h + ")");
    return TRUE;
}
integer rlv_clear_channels(){
    integer i = 0;
    integer n = llGetListLength(RlvListens);
    while (i < n){
        integer h = llList2Integer(RlvListens, i);
        if (h) llListenRemove(h);
        i += 1;
    }
    RlvChans = [];
    RlvListens = [];
    return TRUE;
}
integer rlv_send_queries(){
    integer i = 0;
    integer n = llGetListLength(RlvChans);
    while (i < n){
        integer ch = llList2Integer(RlvChans, i);
        llOwnerSay("@versionnew=" + (string)ch);
        i += 1;
    }
    if (DEBUG) llOwnerSay("[BOOT] RLV @versionnew sent (try " + (string)(RLV_RETRIES + 1) + ")");
    return TRUE;
}
integer rlv_start(){
    if (RLV_PROBING) return FALSE;
    if (!is_attached()){
        RLV_READY = TRUE;
        RLV_ACTIVE = FALSE;
        RLV_VERSTR = "";
        RLV_RETRIES = 0;
        RLV_NEXT_SEND_AT = 0;
        return FALSE;
    }
    RLV_PROBING = TRUE;
    RLV_READY = FALSE;
    RLV_ACTIVE = FALSE;
    RLV_VERSTR = "";
    RLV_RETRIES = 0;
    RLV_NEXT_SEND_AT = now() + RLV_INITIAL_DELAY_SEC;
    rlv_clear_channels();

    if (USE_FIXED_4711) rlv_add_channel(4711);
    if (USE_RELAY_CHAN){
        if (RELAY_CHAN != 0){
            rlv_add_channel(RELAY_CHAN);
            if (PROBE_RELAY_BOTH_SIGNS){
                integer alt = -RELAY_CHAN;
                if (alt != 0 && alt != RELAY_CHAN) rlv_add_channel(alt);
            }
        }
    }
    RLV_WAIT_UNTIL = now() + RLV_PROBE_WINDOW_SEC;
    RLV_SETTLE_UNTIL = 0;
    if (DEBUG){
        llOwnerSay("[BOOT] RLV probe channels → " + (string)RlvChans);
        llOwnerSay("[BOOT] RLV first send after " + (string)RLV_INITIAL_DELAY_SEC + "s");
    }
    return TRUE;
}
integer rlv_finish_and_persist(){
    string enabledVal = "0";
    if (RLV_ACTIVE) enabledVal = "1";
    settings_put("core.rlv.enabled", "int", enabledVal);

    if (RLV_VERSTR != ""){
        string q = llList2Json(JSON_OBJECT, []);
        q = llJsonSetValue(q, ["v"], RLV_VERSTR);
        string quoted = llJsonGetValue(q, ["v"]);
        settings_put("core.rlv.version", "string", quoted);
    }
    send_rlv_line();
    return TRUE;
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        PendingNames = [];
        BootId = mk_boot_id();

        publish_boot_runtime();

        settings_sub_prefix("core.owner.");
        settings_sub_prefix("core.trustees.");

        send_im("Restart: completed");
        send_rlv_line();
        send_ownership_line();
        OwnershipLineSent = TRUE;

        rlv_start();
        llSetTimerEvent(1.0); /* timer ONLY for RLV probe settle/retry logic */
        logd("Bootstrap online (no periodic settings writes).");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_BROADCAST) return;
        string to = llJsonGetValue(msg, ["to"]);
        if (to != "bootstrap") return;

        string t = llJsonGetValue(msg, ["type"]);
        if (t == TYPE_SETTINGS_SNAPSHOT){
            string values = llJsonGetValue(msg, ["values"]);
            if (values != JSON_INVALID) handle_settings_update(t, values);
            return;
        }
        if (t == TYPE_SETTINGS_SYNC){
            string changedObj = llJsonGetValue(msg, ["changed"]);
            if (changedObj != JSON_INVALID) handle_settings_update(t, changedObj);
            return;
        }
    }

    listen(integer chan, string name, key id, string text){
        integer ok = FALSE;
        if (id == llGetOwner()) ok = TRUE;
        else if (id == NULL_KEY) ok = TRUE;
        if (!ok) return;

        if (!RLV_PROBING) return;

        RLV_ACTIVE = TRUE;
        RLV_READY  = TRUE;
        if (text != "") RLV_VERSTR = llStringTrim(text, STRING_TRIM);
        RLV_SETTLE_UNTIL = now() + (integer)RLV_SETTLE_SEC;
        if (DEBUG) llOwnerSay("[BOOT] RLV hit on chan " + (string)chan + ": " + RLV_VERSTR);
    }

    dataserver(key qid, string data){
        integer changedName = FALSE;
        if (qid == OwnerDispReq){
            OwnerDispReq = NULL_KEY;
            if (data != "" && data != "???"){
                OwnerDisp = data;
                changedName = TRUE;
                store_display_name((string)OwnerKey, data);
            }
        }
        else if (qid == OwnerNameReq){
            OwnerNameReq = NULL_KEY;
            if (OwnerDisp == "" && data != ""){
                OwnerLegacy = data;
                changedName = TRUE;
                store_display_name((string)OwnerKey, data);
            }
        }
        else {
            integer idx = pending_name_idx((string)qid);
            if (idx != -1){
                string u = llList2String(PendingNames, idx+1);
                PendingNames = llDeleteSubList(PendingNames, idx, idx + (PN_STRIDE - 1));
                if (data != "") store_display_name(u, data);
            }
            return;
        }

        if (changedName){
            if (OwnershipLineSent && !OwnershipFollowupSent && OwnerKey != NULL_KEY){
                send_ownership_line();
                OwnershipFollowupSent = TRUE;
            }
        }
    }

    timer(){
        /* No heartbeat writes here. Timer only drives RLV probing/settle. */
        integer tnow = now();

        if (RLV_PROBING){
            if (RLV_READY){
                if (RLV_SETTLE_UNTIL != 0){
                    if (tnow >= RLV_SETTLE_UNTIL){
                        rlv_clear_channels();
                        RLV_PROBING = FALSE;
                        RLV_SETTLE_UNTIL = 0;
                        rlv_finish_and_persist();
                    }
                }
            } else {
                if (tnow >= RLV_WAIT_UNTIL){
                    RLV_READY = TRUE;
                    RLV_ACTIVE = FALSE;
                    rlv_clear_channels();
                    RLV_PROBING = FALSE;
                    rlv_finish_and_persist();
                } else {
                    if (RLV_NEXT_SEND_AT != 0){
                        if (tnow >= RLV_NEXT_SEND_AT){
                            rlv_send_queries();
                            RLV_RETRIES += 1;
                            if (RLV_RETRIES >= RLV_MAX_RETRIES){
                                RLV_NEXT_SEND_AT = 0;
                            } else {
                                RLV_NEXT_SEND_AT = tnow + RLV_RETRY_EVERY;
                            }
                        }
                    }
                }
            }
        }
    }
}
