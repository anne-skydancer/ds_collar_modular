/* =============================================================
   PLUGIN: ds_collar_plugin_blacklist.lsl (Kernel JSON ABI)
   PURPOSE: Manage blacklist entries with canonical settings flow
            - JSON register/register_now contract (§22.2)
            - plugin_start / plugin_return routing
            - Settings JSON persistence (channels 800/870)
            - Local submenus return to root; root Back → kernel
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Link numbers (stable kernel) ---------- */
integer K_PLUGIN_REG_QUERY   = 500; // {"type":"register_now","script":...}
integer K_PLUGIN_REG_REPLY   = 501; // {"type":"register",...}
integer K_PLUGIN_SOFT_RESET  = 504; // {"type":"plugin_soft_reset",...}

integer K_PLUGIN_PING        = 650; // {"type":"plugin_ping","context":...}
integer K_PLUGIN_PONG        = 651; // {"type":"plugin_pong","context":...}

integer K_SETTINGS_QUERY     = 800; // Plugin ↔ Settings JSON
integer K_SETTINGS_SYNC      = 870; // Settings → Plugin JSON

integer K_PLUGIN_START       = 900; // {"type":"plugin_start","context":...}
integer K_PLUGIN_RETURN_NUM  = 901; // {"type":"plugin_return","context":"core_root"}

/* ---------- Protocol strings ---------- */
string TYPE_REGISTER            = "register";
string TYPE_REGISTER_NOW        = "register_now";
string TYPE_PLUGIN_SOFT_RESET   = "plugin_soft_reset";
string TYPE_PLUGIN_PING         = "plugin_ping";
string TYPE_PLUGIN_PONG         = "plugin_pong";
string TYPE_PLUGIN_START        = "plugin_start";
string TYPE_PLUGIN_RETURN       = "plugin_return";
string TYPE_SETTINGS_GET        = "settings_get";
string TYPE_SETTINGS_SYNC       = "settings_sync";
string TYPE_SETTINGS_SET        = "set";

/* ---------- Identity ---------- */
integer PLUGIN_SN        = 0;
string  PLUGIN_LABEL     = "Blacklist";
integer PLUGIN_MIN_ACL   = 2; // ACL_OWNED - allow safety access for level 2 users
string  PLUGIN_CONTEXT   = "core_blacklist";
string  ROOT_CONTEXT     = "core_root";

/* ---------- Settings ---------- */
string KEY_BLACKLIST     = "blacklist";

/* ---------- UI constants ---------- */
string BTN_BACK          = "Back";
string BTN_ADD           = "Add";
string BTN_REMOVE        = "Remove";
integer DIALOG_TIMEOUT   = 180;
float   BLACKLIST_RADIUS = 5.0;

/* ---------- Session state ---------- */
key     ActiveUser    = NULL_KEY;
integer ListenHandle  = 0;
integer MenuChannel   = 0;
string  MenuContext   = ""; // "main", "remove", "add_scan", "add_pick", "info"

list    Blacklist     = [];
list    CandidateKeys = [];

/* ========================== Helpers ========================== */
integer json_has(string j, list path) {
    if (llJsonGetValue(j, path) == JSON_INVALID) return FALSE;
    return TRUE;
}

integer logd(string s) { if (DEBUG) llOwnerSay("[BLACKLIST] " + s); return 0; }

list blacklist_names() {
    list out = [];
    integer i;
    for (i = 0; i < llGetListLength(Blacklist); ++i) {
        key k = (key)llList2String(Blacklist, i);
        string nm = llKey2Name(k);
        if (nm == "") nm = (string)k;
        out += nm;
    }
    return out;
}

integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],      (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],   PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"], (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    j = llJsonSetValue(j, ["script"],  llGetScriptName());
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered with kernel.");
    return 0;
}

integer notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    return 0;
}

integer request_settings_get() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    logd("Requested settings_get.");
    return 0;
}

integer persist_blacklist() {
    string arr = llList2Json(JSON_ARRAY, Blacklist);
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   TYPE_SETTINGS_SET);
    j = llJsonSetValue(j, ["key"],    KEY_BLACKLIST);
    j = llJsonSetValue(j, ["values"], arr);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    logd("Persisted blacklist (" + (string)llGetListLength(Blacklist) + ")");
    return 0;
}

integer apply_blacklist_payload(string payload) {
    if (llGetSubString(payload, 0, 0) != "{") return 0;
    if (!json_has(payload, [KEY_BLACKLIST])) return 0;

    string raw = llJsonGetValue(payload, [KEY_BLACKLIST]);
    list updated = [];

    if (raw == JSON_INVALID) {
        Blacklist = [];
        return 0;
    }

    if (llGetSubString(raw, 0, 0) == "[") {
        list arr = llJson2List(raw);
        integer i;
        for (i = 0; i < llGetListLength(arr); ++i) {
            string entry = llList2String(arr, i);
            if (entry != "" && entry != " ") {
                if (llListFindList(updated, [entry]) == -1) updated += entry;
            }
        }
        Blacklist = updated;
        logd("Settings applied: " + (string)llGetListLength(Blacklist) + " entries.");
        return 0;
    }

    if (raw == "" || raw == " ") {
        Blacklist = [];
        logd("Settings applied: blacklist cleared.");
        return 0;
    }

    list csv = llParseStringKeepNulls(raw, [","], []);
    integer j;
    for (j = 0; j < llGetListLength(csv); ++j) {
        string entry2 = llStringTrim(llList2String(csv, j), STRING_TRIM);
        if (entry2 != "" && llListFindList(updated, [entry2]) == -1) updated += entry2;
    }
    Blacklist = updated;
    logd("Settings applied (legacy csv): " + (string)llGetListLength(Blacklist) + " entries.");
    return 0;
}

integer ingest_settings_message(string msg) {
    if (!json_has(msg, ["type"])) return 0;
    string ty = llJsonGetValue(msg, ["type"]);
    if (ty != TYPE_SETTINGS_SYNC && ty != TYPE_SETTINGS_GET) return 0;

    if (json_has(msg, ["kv"])) {
        string kv = llJsonGetValue(msg, ["kv"]);
        apply_blacklist_payload(kv);
        return 0;
    }

    apply_blacklist_payload(msg);
    return 0;
}

integer reset_session() {
    if (ListenHandle) llListenRemove(ListenHandle);
    ListenHandle = 0;
    MenuChannel  = 0;
    ActiveUser   = NULL_KEY;
    MenuContext  = "";
    CandidateKeys = [];
    llSetTimerEvent(0.0);
    return 0;
}

integer send_plugin_return(key user) {
    string r = llList2Json(JSON_OBJECT, []);
    r = llJsonSetValue(r, ["type"],    TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, user);
    logd("Returned control to kernel.");
    return 0;
}

integer begin_dialog(key user, string ctx, string body, list buttons) {
    if (ListenHandle) llListenRemove(ListenHandle);
    ActiveUser  = user;
    MenuContext = ctx;
    MenuChannel = -100000 - (integer)llFrand(1000000.0);
    ListenHandle = llListen(MenuChannel, "", ActiveUser, "");

    list btns = buttons;
    while ((llGetListLength(btns) % 3) != 0) btns += " ";

    llDialog(ActiveUser, body, btns, MenuChannel);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    return 0;
}

integer show_main_menu(key user) {
    CandidateKeys = [];
    list names = blacklist_names();
    string msg = "Blacklisted users:\n";
    integer i;
    if (llGetListLength(names) == 0) {
        msg += "  (none)\n";
    } else {
        for (i = 0; i < llGetListLength(names); ++i) {
            msg += "  " + llList2String(names, i) + "\n";
        }
    }

    list btns = ["~", BTN_BACK, "~", BTN_ADD, BTN_REMOVE];
    begin_dialog(user, "main", msg, btns);
    logd("Main menu → " + (string)user + " chan=" + (string)MenuChannel);
    return 0;
}

integer show_remove_menu(key user) {
    if (llGetListLength(Blacklist) == 0) {
        //PATCH: Present info dialog when blacklist is empty to avoid blank remove menu.
        begin_dialog(user, "info", "Blacklist is empty.", [BTN_BACK]);
        logd("Remove menu empty.");
        return 0;
    }

    list names = blacklist_names();
    string msg = "Select avatar to remove:\n";
    list btns = ["~", BTN_BACK, "~"];
    integer i;
    for (i = 0; i < llGetListLength(names); ++i) {
        msg += (string)(i + 1) + ". " + llList2String(names, i) + "\n";
        btns += [(string)(i + 1)];
    }

    begin_dialog(user, "remove", msg, btns);
    logd("Remove menu → " + (string)user);
    return 0;
}

integer show_add_candidates(key user) {
    if (llGetListLength(CandidateKeys) == 0) {
        begin_dialog(user, "info", "No avatars nearby to blacklist.", [BTN_BACK]);
        logd("Add candidates empty.");
        return 0;
    }

    string msg = "Select avatar to blacklist:\n";
    list btns = ["~", BTN_BACK, "~"];
    integer i;
    for (i = 0; i < llGetListLength(CandidateKeys); ++i) {
        key k = (key)llList2String(CandidateKeys, i);
        string nm = llKey2Name(k);
        if (nm == "") nm = (string)k;
        msg += (string)(i + 1) + ". " + nm + "\n";
        btns += [(string)(i + 1)];
    }

    begin_dialog(user, "add_pick", msg, btns);
    logd("Add menu → " + (string)user);
    return 0;
}

/* =========================== Events ========================== */
default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        reset_session();

        notify_soft_reset();
        register_plugin();
        request_settings_get();

        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == K_PLUGIN_PING) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_PING) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    string pong = llList2Json(JSON_OBJECT, []);
                    pong = llJsonSetValue(pong, ["type"],    TYPE_PLUGIN_PONG);
                    pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                }
            }
            return;
        }

        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_REGISTER_NOW) {
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        if (num == K_SETTINGS_SYNC) {
            ingest_settings_message(msg);
            return;
        }

        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_START) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    reset_session();
                    show_main_menu(id);
                }
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string message) {
        if (chan != MenuChannel) return;
        if (id != ActiveUser) return;

        if (message == BTN_BACK) {
            if (MenuContext == "main") {
                send_plugin_return(id);
                reset_session();
                return;
            }
            show_main_menu(id);
            return;
        }

        if (MenuContext == "main") {
            if (message == BTN_ADD) {
                MenuContext = "add_scan";
                CandidateKeys = [];
                llSensor("", NULL_KEY, AGENT, BLACKLIST_RADIUS, PI);
                logd("Scanning for blacklist candidates.");
                return;
            }
            if (message == BTN_REMOVE) {
                show_remove_menu(id);
                return;
            }
        }
        else if (MenuContext == "remove") {
            integer idx = (integer)message - 1;
            if (idx >= 0 && idx < llGetListLength(Blacklist)) {
                Blacklist = llDeleteSubList(Blacklist, idx, idx);
                persist_blacklist();
            }
            show_main_menu(id);
            return;
        }
        else if (MenuContext == "add_pick") {
            integer idx2 = (integer)message - 1;
            if (idx2 >= 0 && idx2 < llGetListLength(CandidateKeys)) {
                string entry = llList2String(CandidateKeys, idx2);
                if (entry != "" && llListFindList(Blacklist, [entry]) == -1) {
                    Blacklist += entry;
                    persist_blacklist();
                }
            }
            show_main_menu(id);
            return;
        }
        else if (MenuContext == "info") {
            show_main_menu(id);
            return;
        }

        show_main_menu(id);
    }

    sensor(integer count) {
        if (ActiveUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;

        list candidates = [];
        key owner = llGetOwner();
        integer i;
        for (i = 0; i < count; ++i) {
            key k = llDetectedKey(i);
            if (k == owner) jump continue;
            if (k == ActiveUser) jump continue;
            string entry = (string)k;
            if (~llListFindList(Blacklist, [entry])) jump continue;
            if (~llListFindList(candidates, [entry])) jump continue;
            candidates += entry;
            @continue;
        }

        CandidateKeys = candidates;
        show_add_candidates(ActiveUser);
    }

    no_sensor() {
        if (ActiveUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;
        CandidateKeys = [];
        show_add_candidates(ActiveUser);
    }

    timer() {
        key last = ActiveUser;
        reset_session();
        if (last != NULL_KEY) {
            send_plugin_return(last);
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[BLACKLIST] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
