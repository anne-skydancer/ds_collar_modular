/* =============================================================
   PLUGIN: ds_collar_plugin_status.lsl  (authoritative migration)
   PURPOSE: Show collar status; Back returns to main menu
   NOTES:
     - Authoritative kernel JSON (register/heartbeat/soft-reset)
     - Settings-driven status view (read-only)
     - Private dialog channel + safe listens
     - No AUTH gate (min_acl = 1; audience = all)
   ============================================================= */

integer DEBUG = FALSE;

/* ---------- Protocol strings (authoritative) ---------- */
string TYPE_REGISTER            = "register";
string TYPE_REGISTER_NOW        = "register_now";
string TYPE_PLUGIN_PING         = "plugin_ping";
string TYPE_PLUGIN_PONG         = "plugin_pong";
string TYPE_PLUGIN_SOFT_RESET   = "plugin_soft_reset";
string TYPE_SETTINGS_GET        = "settings_get";
string TYPE_SETTINGS_SYNC       = "settings_sync";
string TYPE_PLUGIN_RETURN       = "plugin_return";

/* ---------- Link message channels (authoritative) ---------- */
integer K_PLUGIN_REG_QUERY      = 500;  // Kernel → Plugins: register_now
integer K_PLUGIN_REG_REPLY      = 501;  // Plugins → Kernel: register
integer K_PLUGIN_SOFT_RESET     = 504;  // Plugins → Kernel: plugin_soft_reset

integer K_PLUGIN_PING           = 650;  // Kernel → Plugins: plugin_ping
integer K_PLUGIN_PONG           = 651;  // Plugins → Kernel: plugin_pong

integer K_SETTINGS_QUERY        = 800;  // Any ↔ Settings
integer K_SETTINGS_SYNC         = 870;  // Settings → Any

integer K_PLUGIN_START          = 900;  // UI → Plugin: start (context only)
integer K_PLUGIN_RETURN_NUM     = 901;  // Plugin → UI: plugin_return

/* ---------- Identity / registration ---------- */
integer PLUGIN_SN        = 0;
string  PLUGIN_LABEL     = "Status";
integer PLUGIN_MIN_ACL   = 1;            // Public
string  PLUGIN_CONTEXT   = "core_status";
string  ROOT_CONTEXT     = "core_root";

string  REG_AUDIENCE     = "all";        // explicit audience (all/touchers/wearer)

/* ---------- Menu constants ---------- */
string  BTN_BACK         = "Back";
string  BTN_FILL         = " ";          // real blank (not "~")
integer DIALOG_TIMEOUT   = 180;

/* ---------- Settings keys ---------- */
string KEY_OWNER_KEY       = "owner_key";
string KEY_OWNER_HON       = "owner_hon";
string KEY_TRUSTEES        = "trustees";
string KEY_TRUSTEE_HONS    = "trustee_honorifics";
string KEY_BLACKLIST       = "blacklist";
string KEY_PUBLIC_ACCESS   = "public_mode";
string KEY_LOCKED          = "locked";
string KEY_TPE_MODE        = "tpe_mode";

/* ---------- State mirrored from settings ---------- */
key     owner_key        = NULL_KEY;
string  owner_hon        = "";
list    trustee_keys     = [];
list    trustee_hons     = [];
list    blacklist_keys   = [];
integer public_access    = FALSE;
integer locked           = FALSE;
integer tpe_mode         = FALSE;

/* ---------- Owner name cache + requests ---------- */
string  owner_display    = "";        // preferred: Display Name (or legacy if needed)
key     q_owner_disp     = NULL_KEY;  // query id for llRequestDisplayName
key     q_owner_legacy   = NULL_KEY;  // query id for llRequestAgentData(DATA_NAME)
key     last_owner_key   = NULL_KEY;  // track changes to re-fetch names

/* ---------- Session state ---------- */
key     g_user           = NULL_KEY;
integer g_chan           = 0;
integer g_listen         = 0;

/* ========================== Helpers ========================== */
integer json_has(string j, list path){
    if (llJsonGetValue(j, path) == JSON_INVALID) return FALSE;
    return TRUE;
}
integer logd(string s){ if (DEBUG) llOwnerSay("[STATUS] " + s); return 0; }

/* ---------- Owner name resolution ---------- */
request_owner_names(){
    if (owner_key == NULL_KEY) return;
    // clear old cache and start fresh queries
    owner_display  = "";
    q_owner_disp   = llRequestDisplayName(owner_key);
    q_owner_legacy = llRequestAgentData(owner_key, DATA_NAME);
}
string owner_label(){
    // Prefer cached display/legacy name; otherwise indicate fetching
    string nm = owner_display;
    if (nm == "") nm = "(fetching…)";

    // Apply honorific if present
    if (owner_hon != ""){
        return owner_hon + " " + nm;
    }
    return nm;
}

/* ---------- Registration / soft-reset ---------- */
register_self(){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],      (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],   PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"], (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    j = llJsonSetValue(j, ["script"],  llGetScriptName());
    /* audience hint (omit if "all") */
    if (REG_AUDIENCE != "" && REG_AUDIENCE != "all"){
        j = llJsonSetValue(j, ["audience"], REG_AUDIENCE);
    }
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered with kernel.");
}
notify_soft_reset(){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
}

/* ---------- Settings I/O ---------- */
request_settings_sync_once(){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
}
update_from_settings(string kv_json){
    /* defensive: expect an object */
    if (llGetSubString(kv_json, 0, 0) != "{") return;

    key prev_owner = owner_key;

    /* reset local mirror first */
    owner_key      = NULL_KEY;
    owner_hon      = "";
    trustee_keys   = [];
    trustee_hons   = [];
    blacklist_keys = [];
    public_access  = FALSE;
    locked         = FALSE;
    tpe_mode       = FALSE;

    if (json_has(kv_json, [KEY_OWNER_KEY]))      owner_key = (key)llJsonGetValue(kv_json, [KEY_OWNER_KEY]);
    if (json_has(kv_json, [KEY_OWNER_HON]))      owner_hon = llJsonGetValue(kv_json, [KEY_OWNER_HON]);

    if (json_has(kv_json, [KEY_TRUSTEES])){
        string v = llJsonGetValue(kv_json, [KEY_TRUSTEES]);
        if (llGetSubString(v, 0, 0) == "[") trustee_keys = llJson2List(v);
    }
    if (json_has(kv_json, [KEY_TRUSTEE_HONS])){
        string v2 = llJsonGetValue(kv_json, [KEY_TRUSTEE_HONS]);
        if (llGetSubString(v2, 0, 0) == "[") trustee_hons = llJson2List(v2);
    }
    if (json_has(kv_json, [KEY_BLACKLIST])){
        string v3 = llJsonGetValue(kv_json, [KEY_BLACKLIST]);
        if (llGetSubString(v3, 0, 0) == "[") blacklist_keys = llJson2List(v3);
    }

    if (json_has(kv_json, [KEY_PUBLIC_ACCESS])) public_access = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_ACCESS]);
    if (json_has(kv_json, [KEY_LOCKED]))        locked        = (integer)llJsonGetValue(kv_json, [KEY_LOCKED]);
    if (json_has(kv_json, [KEY_TPE_MODE]))      tpe_mode      = (integer)llJsonGetValue(kv_json, [KEY_TPE_MODE]);

    // If the owner changed, clear cached name and re-request
    if (owner_key != prev_owner){
        last_owner_key = owner_key;
        owner_display  = "";
        if (owner_key != NULL_KEY){
            request_owner_names();
        }
    }

    logd("Settings mirror updated.");
}

/* ---------- UI plumbing ---------- */
cleanup_session(){
    if (g_listen != 0) llListenRemove(g_listen);
    g_listen = 0;
    g_user   = NULL_KEY;
    g_chan   = 0;
    llSetTimerEvent(0.0);
}
integer open_dialog(key avatar, string body, list buttons){
    /* pad to multiples of 3 for llDialog */
    while ((llGetListLength(buttons) % 3) != 0) buttons += " ";
    if (g_listen != 0) llListenRemove(g_listen);
    g_chan   = -100000 - (integer)llFrand(1000000.0);
    g_listen = llListen(g_chan, "", avatar, "");
    g_user   = avatar;
    llDialog(avatar, body, buttons, g_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    return TRUE;
}

/* ---------- Status text ---------- */
string build_status_report(){
    string s = "Collar status:\n";

    if (locked) s += "🔒 Locked\n";
    else s += "🔓 Unlocked\n";

    if (tpe_mode) s += "💥 TPE Mode: ON\n";
    else s += "💥 TPE Mode: OFF\n";

    if (owner_key != NULL_KEY){
        s += "Owner: " + owner_label() + "\n";
    } else {
        s += "Owner: (unowned)\n";
    }

    integer tlen = llGetListLength(trustee_keys);
    if (tlen > 0){
        s += "Trustees: ";
        integer i = 0;
        while (i < tlen){
            if (i != 0) s += ", ";
            /* prefer honorific label if present, else placeholder */
            string h = "";
            if (i < llGetListLength(trustee_hons)) h = llList2String(trustee_hons, i);
            if (h == "") h = "(trustee)";
            s += h;
            i += 1;
        }
        s += "\n";
    } else {
        s += "Trustees: (none)\n";
    }

    if (public_access) s += "Public Access: ON\n";
    else s += "Public Access: OFF\n";

    return s;
}
show_menu(key avatar){
    string report = build_status_report();
    list buttons = [BTN_FILL, BTN_BACK, BTN_FILL];
    open_dialog(avatar, report, buttons);
    logd("Menu → " + (string)avatar + " chan=" + (string)g_chan);
}

/* =========================== EVENTS =========================== */
default{
    state_entry(){
        cleanup_session();
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_self();
        request_settings_sync_once();
        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender, integer num, string str, key id){
        /* Heartbeat */
        if (num == K_PLUGIN_PING){
            if (json_has(str, ["type"])){
                if (llJsonGetValue(str, ["type"]) == TYPE_PLUGIN_PING){
                    if (json_has(str, ["context"])){
                        if (llJsonGetValue(str, ["context"]) != PLUGIN_CONTEXT) return;
                    }
                    string pong = llList2Json(JSON_OBJECT, []);
                    pong = llJsonSetValue(pong, ["type"],    TYPE_PLUGIN_PONG);
                    pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                }
            }
            return;
        }

        /* Settings sync */
        if (num == K_SETTINGS_SYNC){
            if (json_has(str, ["type"])){
                if (llJsonGetValue(str, ["type"]) == TYPE_SETTINGS_SYNC){
                    if (json_has(str, ["kv"])){
                        update_from_settings(llJsonGetValue(str, ["kv"]));
                    }
                }
            }
            return;
        }

        /* Kernel asks this script to re-register */
        if (num == K_PLUGIN_REG_QUERY){
            if (json_has(str, ["type"])){
                if (llJsonGetValue(str, ["type"]) == TYPE_REGISTER_NOW){
                    if (json_has(str, ["script"])){
                        if (llJsonGetValue(str, ["script"]) != llGetScriptName()) return;
                    }
                    register_self();
                }
            }
            return;
        }

        /* UI start: open the status menu (no AUTH gate) */
        if (num == K_PLUGIN_START){
            if (json_has(str, ["context"])){
                if (llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT){
                    // If we don't have a cached owner display yet, (re)request it
                    if (owner_key != NULL_KEY && owner_display == ""){
                        request_owner_names();
                    }
                    show_menu(id);
                }
            }
            return;
        }
    }

    dataserver(key query_id, string data){
        // Display Name arrives here; legacy name too
        if (query_id == q_owner_disp){
            q_owner_disp = NULL_KEY;
            if (data != "" && data != "???" && owner_key != NULL_KEY){
                owner_display = data;
            }
        } else if (query_id == q_owner_legacy){
            q_owner_legacy = NULL_KEY;
            // Only take legacy if display name didn't resolve
            if (owner_display == "" && data != "" && owner_key != NULL_KEY){
                owner_display = data;
            }
        } else {
            return;
        }

        // If a user has the menu open, refresh it with the resolved name
        if (g_user != NULL_KEY && g_listen != 0){
            show_menu(g_user);
        }
    }

    listen(integer channel, string name, key id, string msg){
        if (channel != g_chan) return;
        if (id != g_user) return;

        if (msg == BTN_BACK){
            string j = llList2Json(JSON_OBJECT, []);
            j = llJsonSetValue(j, ["type"],    TYPE_PLUGIN_RETURN);
            j = llJsonSetValue(j, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, j, id);
            cleanup_session();
            return;
        }

        /* Unknown → close quietly */
        cleanup_session();
    }

    timer(){ cleanup_session(); }

    changed(integer change){
        if (change & CHANGED_OWNER) llResetScript();
    }
}
