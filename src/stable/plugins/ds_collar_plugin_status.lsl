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
key     OwnerKey          = NULL_KEY;
string  OwnerHonorific    = "";
list    TrusteeKeys       = [];
list    TrusteeHonorifics = [];
list    BlacklistKeys     = [];
integer PublicAccess      = FALSE;
integer Locked            = FALSE;
integer TpeMode           = FALSE;

/* ---------- Owner name cache + requests ---------- */
string  OwnerDisplay      = "";       // preferred: Display Name (or legacy if needed)
key     OwnerDisplayQuery = NULL_KEY;  // query id for llRequestDisplayName
key     OwnerLegacyQuery  = NULL_KEY;  // query id for llRequestAgentData(DATA_NAME)
key     LastOwnerKey      = NULL_KEY;  // track changes to re-fetch names

/* ---------- Session state ---------- */
key     User           = NULL_KEY;
integer Chan           = 0;
integer Listen         = 0;

/* ========================== Helpers ========================== */
integer json_has(string j, list path){
    if (llJsonGetValue(j, path) == JSON_INVALID) return FALSE;
    return TRUE;
}
integer logd(string s){ if (DEBUG) llOwnerSay("[STATUS] " + s); return 0; }

/* ---------- Owner name resolution ---------- */
integer request_owner_names(){
    if (OwnerKey == NULL_KEY) return 0;
    // clear old cache and start fresh queries
    OwnerDisplay  = "";
    OwnerDisplayQuery   = llRequestDisplayName(OwnerKey);
    OwnerLegacyQuery = llRequestAgentData(OwnerKey, DATA_NAME);
    return 0;
}
string owner_label(){
    // Prefer cached display/legacy name; otherwise indicate fetching
    string nm = OwnerDisplay;
    if (nm == "") nm = "(fetching…)";

    // Apply honorific if present
    if (OwnerHonorific != ""){
        return OwnerHonorific + " " + nm;
    }
    return nm;
}

/* ---------- Registration / soft-reset ---------- */
integer register_self(){
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
    return 0;
}
integer notify_soft_reset(){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    return 0;
}

/* ---------- Settings I/O ---------- */
integer request_settings_sync_once(){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    return 0;
}
integer update_from_settings(string kv_json){
    /* defensive: expect an object */
    if (llGetSubString(kv_json, 0, 0) != "{") return 0;

    key prev_owner = OwnerKey;

    /* reset local mirror first */
    OwnerKey      = NULL_KEY;
    OwnerHonorific      = "";
    TrusteeKeys   = [];
    TrusteeHonorifics   = [];
    BlacklistKeys = [];
    PublicAccess  = FALSE;
    Locked         = FALSE;
    TpeMode       = FALSE;

    if (json_has(kv_json, [KEY_OWNER_KEY]))      OwnerKey = (key)llJsonGetValue(kv_json, [KEY_OWNER_KEY]);
    if (json_has(kv_json, [KEY_OWNER_HON]))      OwnerHonorific = llJsonGetValue(kv_json, [KEY_OWNER_HON]);

    if (json_has(kv_json, [KEY_TRUSTEES])){
        string v = llJsonGetValue(kv_json, [KEY_TRUSTEES]);
        if (llGetSubString(v, 0, 0) == "[") TrusteeKeys = llJson2List(v);
    }
    if (json_has(kv_json, [KEY_TRUSTEE_HONS])){
        string v2 = llJsonGetValue(kv_json, [KEY_TRUSTEE_HONS]);
        if (llGetSubString(v2, 0, 0) == "[") TrusteeHonorifics = llJson2List(v2);
    }
    if (json_has(kv_json, [KEY_BLACKLIST])){
        string v3 = llJsonGetValue(kv_json, [KEY_BLACKLIST]);
        if (llGetSubString(v3, 0, 0) == "[") BlacklistKeys = llJson2List(v3);
    }

    if (json_has(kv_json, [KEY_PUBLIC_ACCESS])) PublicAccess = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_ACCESS]);
    if (json_has(kv_json, [KEY_LOCKED]))        Locked        = (integer)llJsonGetValue(kv_json, [KEY_LOCKED]);
    if (json_has(kv_json, [KEY_TPE_MODE]))      TpeMode      = (integer)llJsonGetValue(kv_json, [KEY_TPE_MODE]);

    // If the owner changed, clear cached name and re-request
    if (OwnerKey != prev_owner){
        LastOwnerKey = OwnerKey;
        OwnerDisplay  = "";
        if (OwnerKey != NULL_KEY){
            request_owner_names();
        }
    }

    logd("Settings mirror updated.");
    return 0;
}

/* ---------- UI plumbing ---------- */
integer cleanup_session(){
    if (Listen != 0) llListenRemove(Listen);
    Listen = 0;
    User   = NULL_KEY;
    Chan   = 0;
    llSetTimerEvent(0.0);
    return 0;
}
integer open_dialog(key avatar, string body, list buttons){
    /* pad to multiples of 3 for llDialog */
    while ((llGetListLength(buttons) % 3) != 0) buttons += " ";
    if (Listen != 0) llListenRemove(Listen);
    Chan   = -100000 - (integer)llFrand(1000000.0);
    Listen = llListen(Chan, "", avatar, "");
    User   = avatar;
    llDialog(avatar, body, buttons, Chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
    return TRUE;
}

/* ---------- Status text ---------- */
string build_status_report(){
    string s = "Collar status:\n";

    if (Locked) s += "🔒 Locked\n";
    else s += "🔓 Unlocked\n";

    if (TpeMode) s += "💥 TPE Mode: ON\n";
    else s += "💥 TPE Mode: OFF\n";

    if (OwnerKey != NULL_KEY){
        s += "Owner: " + owner_label() + "\n";
    } else {
        s += "Owner: (unowned)\n";
    }

    integer tlen = llGetListLength(TrusteeKeys);
    if (tlen > 0){
        s += "Trustees: ";
        integer i = 0;
        while (i < tlen){
            if (i != 0) s += ", ";
            /* prefer honorific label if present, else placeholder */
            string h = "";
            if (i < llGetListLength(TrusteeHonorifics)) h = llList2String(TrusteeHonorifics, i);
            if (h == "") h = "(trustee)";
            s += h;
            i += 1;
        }
        s += "\n";
    } else {
        s += "Trustees: (none)\n";
    }

    if (PublicAccess) s += "Public Access: ON\n";
    else s += "Public Access: OFF\n";

    return s;
}
integer show_menu(key avatar){
    string report = build_status_report();
    list buttons = [BTN_FILL, BTN_BACK, BTN_FILL];
    integer opened = open_dialog(avatar, report, buttons);
    logd("Menu → " + (string)avatar + " chan=" + (string)Chan);
    return opened;
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
                    if (OwnerKey != NULL_KEY && OwnerDisplay == ""){
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
        if (query_id == OwnerDisplayQuery){
            OwnerDisplayQuery = NULL_KEY;
            if (data != "" && data != "???" && OwnerKey != NULL_KEY){
                OwnerDisplay = data;
            }
        } else if (query_id == OwnerLegacyQuery){
            OwnerLegacyQuery = NULL_KEY;
            // Only take legacy if display name didn't resolve
            if (OwnerDisplay == "" && data != "" && OwnerKey != NULL_KEY){
                OwnerDisplay = data;
            }
        } else {
            return;
        }

        // If a user has the menu open, refresh it with the resolved name
        if (User != NULL_KEY && Listen != 0){
            show_menu(User);
        }
    }

    listen(integer channel, string name, key id, string msg){
        if (channel != Chan) return;
        if (id != User) return;

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
