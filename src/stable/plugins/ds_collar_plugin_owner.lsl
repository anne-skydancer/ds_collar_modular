/* =============================================================
   PLUGIN: ds_collar_plugin_owner.lsl  (Memory Optimized)
   ROLE  : Owner Control & Management
   DATE  : 2025-10-14 (Memory optimized for stack-heap collision)
   NOTES : Reduced memory footprint by:
           - Consolidating name cache systems
           - Reducing global variables
           - Simplifying UI state management
           - Optimizing list operations
   ============================================================= */

integer DEBUG = FALSE;

integer K_PLUGIN_REG_QUERY   = 500;
integer K_PLUGIN_REG_REPLY   = 501;
integer K_PLUGIN_SOFT_RESET  = 504;
integer K_PLUGIN_PING        = 650;
integer K_PLUGIN_PONG        = 651;
integer AUTH_QUERY_NUM       = 700;
integer AUTH_RESULT_NUM      = 710;
integer K_SETTINGS_QUERY     = 800;
integer K_SETTINGS_SYNC      = 870;
integer K_PLUGIN_START       = 900;
integer K_PLUGIN_RETURN_NUM  = 901;

string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_REGISTER_NOW      = "register_now";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";
string CONS_MSG_ACL_QUERY          = "acl_query";
string CONS_MSG_ACL_RESULT         = "acl_result";
string CONS_SETTINGS_SYNC          = "settings_sync";
string CONS_SETTINGS_SET           = "set";
string CONS_SETTINGS_NS_OWNER      = "owner";
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY        = "owner_key";
string KEY_OWNER_KEYS       = "owner_keys";
string KEY_OWNER_LEGACY     = "owner";
string KEY_OWNER_HON        = "owner_hon";
string KEY_TRUSTEES         = "trustees";
string KEY_TRUSTEE_HONS     = "trustee_honorifics";
string KEY_PUBLIC_MODE      = "public_mode";
string KEY_LOCKED_FLAG      = "locked";

string  PLUGIN_CONTEXT   = "core_owner";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Owner";
integer PluginSn         = 0;
integer PLUGIN_MIN_ACL   = 2;

integer ACL_BLACKLIST        = -1;
integer ACL_NOACCESS         = 0;
integer ACL_PUBLIC           = 1;
integer ACL_OWNED            = 2;
integer ACL_TRUSTEE          = 3;
integer ACL_UNOWNED          = 4;
integer ACL_PRIMARY_OWNER    = 5;

list ALLOWED_ACL_LEVELS = [ACL_OWNED, ACL_UNOWNED, ACL_PRIMARY_OWNER];

integer DIALOG_TIMEOUT_SEC = 180;

key     User             = NULL_KEY;
integer Listen           = 0;
integer MenuChan         = 0;
integer AclPending       = FALSE;
integer AclLevel         = ACL_NOACCESS;

/* ---------- Multi-owner support ---------- */
integer MultiOwnerMode         = FALSE;
key     CollarOwner            = NULL_KEY;
list    OwnerKeys              = [];
string  CollarOwnerHonorific   = "";
integer CollarLocked           = FALSE;
integer CollarPublicAccess     = FALSE;
list    CollarTrustees         = [];
list    CollarTrusteeHonorifics = [];

/* Simplified name cache - single system */
list    NameCache              = [];  // [key, name, key, name...]
key     ActiveNameQuery        = NULL_KEY;
key     ActiveQueryTarget      = NULL_KEY;

/* Compressed UI state - single string instead of multiple variables */
string UiState = "";  // Format: "context|param1|param2|data"

/* ========================== Helpers ========================== */
integer json_has(string j, list path) {
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return FALSE;
    return TRUE;
}

integer logd(string s) { 
    if (DEBUG) llOwnerSay("[OWNER] " + s); 
    return 0; 
}

/* ---------- Multi-owner helpers ---------- */
integer has_owner() {
    if (MultiOwnerMode) {
        if (llGetListLength(OwnerKeys) > 0) return TRUE;
    } else {
        if (CollarOwner != NULL_KEY) return TRUE;
    }
    return FALSE;
}

key get_primary_owner() {
    if (MultiOwnerMode) {
        if (llGetListLength(OwnerKeys) > 0) {
            return (key)llList2String(OwnerKeys, 0);
        }
        return NULL_KEY;
    }
    return CollarOwner;
}

/* ---------- Simplified Name Resolution ---------- */
cache_name(key avatar_key, string display_name) {
    if (avatar_key == NULL_KEY) return;
    if (display_name == "" || display_name == "???") return;
    
    integer idx = llListFindList(NameCache, [avatar_key]);
    if (idx != -1) {
        NameCache = llListReplaceList(NameCache, [display_name], idx + 1, idx + 1);
    } else {
        NameCache += [avatar_key, display_name];
        
        if (llGetListLength(NameCache) > 20) {
            NameCache = llDeleteSubList(NameCache, 0, 1);
        }
    }
}

string get_cached_name(key avatar_key) {
    if (avatar_key == NULL_KEY) return "";
    
    integer idx = llListFindList(NameCache, [avatar_key]);
    if (idx != -1) {
        return llList2String(NameCache, idx + 1);
    }
    return "";
}

request_name(key avatar_key) {
    if (avatar_key == NULL_KEY) return;
    
    string cached = get_cached_name(avatar_key);
    if (cached != "") return;
    
    if (ActiveNameQuery != NULL_KEY) return;
    
    ActiveNameQuery = llRequestDisplayName(avatar_key);
    ActiveQueryTarget = avatar_key;
}

string get_display_name(key k) {
    if (k == NULL_KEY) return "";
    
    string cached = get_cached_name(k);
    if (cached != "") return cached;
    
    string n = llKey2Name(k);
    if (n != "" && n != "???") {
        cache_name(k, n);
        return n;
    }
    
    request_name(k);
    return (string)k;
}

/* ---------- UI State Management ---------- */
list get_ui_parts() {
    return llParseString2List(UiState, ["|"], []);
}

string get_ui_context() {
    list parts = get_ui_parts();
    if (llGetListLength(parts) > 0) return llList2String(parts, 0);
    return "";
}

string get_ui_param(integer n) {
    list parts = get_ui_parts();
    if (llGetListLength(parts) > n) return llList2String(parts, n);
    return "";
}

set_ui_state(string context, string p1, string p2, string data) {
    UiState = context + "|" + p1 + "|" + p2 + "|" + data;
}

clear_ui_state() {
    UiState = "";
}

/* ========================== Core Functions ========================== */
integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PluginSn);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
    j = llJsonSetValue(j, ["script"],   llGetScriptName());
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered.");
    return 0;
}

integer notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    return 0;
}

integer in_allowed_levels(integer lvl) {
    if (llListFindList(ALLOWED_ACL_LEVELS, [lvl]) != -1) return TRUE;
    return FALSE;
}

integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    AclPending = TRUE;
    return 0;
}

integer settings_set_scalar(string key_str, string val) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],  CONS_SETTINGS_SET);
    j = llJsonSetValue(j, ["key"],   key_str);
    j = llJsonSetValue(j, ["value"], val);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    return 0;
}

integer settings_set_list(string key_str, list values) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_SETTINGS_SET);
    j = llJsonSetValue(j, ["key"],    key_str);
    j = llJsonSetValue(j, ["values"], llList2Json(JSON_ARRAY, values));
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    return 0;
}

integer push_settings() {
    settings_set_scalar(KEY_OWNER_KEY, (string)CollarOwner);
    
    string hon = CollarOwnerHonorific;
    if (hon == "") hon = " ";
    settings_set_scalar(KEY_OWNER_HON, hon);
    
    settings_set_list(KEY_TRUSTEES, CollarTrustees);
    settings_set_list(KEY_TRUSTEE_HONS, CollarTrusteeHonorifics);
    
    if (CollarPublicAccess) {
        settings_set_scalar(KEY_PUBLIC_MODE, "1");
    } else {
        settings_set_scalar(KEY_PUBLIC_MODE, "0");
    }
    
    if (CollarLocked) {
        settings_set_scalar(KEY_LOCKED_FLAG, "1");
    } else {
        settings_set_scalar(KEY_LOCKED_FLAG, "0");
    }
    
    logd("Settings pushed.");
    return 0;
}

integer apply_owner_settings_payload(string payload) {
    if (json_has(payload, [KEY_MULTI_OWNER_MODE])) {
        MultiOwnerMode = ((integer)llJsonGetValue(payload, [KEY_MULTI_OWNER_MODE])) != 0;
    } else {
        MultiOwnerMode = FALSE;
    }
    
    if (MultiOwnerMode) {
        if (json_has(payload, [KEY_OWNER_KEYS])) {
            string arr = llJsonGetValue(payload, [KEY_OWNER_KEYS]);
            if (llGetSubString(arr, 0, 0) == "[") {
                OwnerKeys = llJson2List(arr);
            } else {
                OwnerKeys = [];
            }
        } else {
            OwnerKeys = [];
        }
        CollarOwner = NULL_KEY;
    } else {
        if (json_has(payload, [KEY_OWNER_KEY])) {
            CollarOwner = (key)llJsonGetValue(payload, [KEY_OWNER_KEY]);
        } else if (json_has(payload, [KEY_OWNER_LEGACY])) {
            CollarOwner = (key)llJsonGetValue(payload, [KEY_OWNER_LEGACY]);
        } else {
            CollarOwner = NULL_KEY;
        }
        OwnerKeys = [];
    }
    
    if (json_has(payload, [KEY_OWNER_HON])) {
        CollarOwnerHonorific = llJsonGetValue(payload, [KEY_OWNER_HON]);
    } else {
        CollarOwnerHonorific = "";
    }
    
    if (json_has(payload, [KEY_TRUSTEES])) {
        string arr = llJsonGetValue(payload, [KEY_TRUSTEES]);
        if (llGetSubString(arr, 0, 0) == "[") CollarTrustees = llJson2List(arr);
    }
    
    if (json_has(payload, [KEY_TRUSTEE_HONS])) {
        string arrh = llJsonGetValue(payload, [KEY_TRUSTEE_HONS]);
        if (llGetSubString(arrh, 0, 0) == "[") CollarTrusteeHonorifics = llJson2List(arrh);
    }
    
    if (json_has(payload, [KEY_PUBLIC_MODE])) {
        CollarPublicAccess = ((integer)llJsonGetValue(payload, [KEY_PUBLIC_MODE])) != 0;
    }
    
    if (json_has(payload, [KEY_LOCKED_FLAG])) {
        CollarLocked = ((integer)llJsonGetValue(payload, [KEY_LOCKED_FLAG])) != 0;
    }
    
    if (CollarOwner != NULL_KEY) request_name(CollarOwner);
    
    logd("Settings applied.");
    return 0;
}

integer ingest_settings(string j) {
    string payload = "";
    integer have_payload = FALSE;
    if (json_has(j, ["kv"])) {
        string kv = llJsonGetValue(j, ["kv"]);
        if (llGetSubString(kv, 0, 0) == "{") {
            payload = kv;
            have_payload = TRUE;
        }
    }
    if (!have_payload) {
        if (json_has(j, ["ns"])) {
            if (llJsonGetValue(j, ["ns"]) != CONS_SETTINGS_NS_OWNER) return 0;
        }
        payload = j;
        have_payload = TRUE;
    }
    if (!have_payload) return 0;
    return apply_owner_settings_payload(payload);
}

integer is_session_valid(key user) {
    return (user != NULL_KEY && user == User && Listen != 0);
}

integer reset_listen() {
    integer old_handle = Listen;
    Listen = 0; 
    MenuChan = 0;
    User = NULL_KEY;
    if (old_handle != 0) llListenRemove(old_handle);
    llSetTimerEvent(0.0);
    return 0;
}

integer dialog_to(key who, string body, list buttons) {
    reset_listen();
    while ((llGetListLength(buttons) % 3) != 0) {
        buttons += " ";
    }
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    Listen = llListen(MenuChan, "", who, "");
    User = who;
    llDialog(who, body, buttons, MenuChan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}

integer ui_return_root(key to_user) {
    string r = llList2Json(JSON_OBJECT, []);
    r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, to_user);
    return 0;
}

list base_menu_buttons() {
    list btns = [];
    
    if (!has_owner() && AclLevel == ACL_UNOWNED) btns += ["Add Owner"];
    if (has_owner() && AclLevel == ACL_PRIMARY_OWNER) {
        btns += ["Transfer Sub", "Release Sub"];
    }
    if (has_owner() && AclLevel == ACL_OWNED) btns += ["Runaway"];
    
    btns += ["Back"];
    return btns;
}

integer show_menu(key user) {
    set_ui_state("menu", "", "", "");
    
    string owner_line = "(none)";
    if (has_owner()) {
        if (MultiOwnerMode) {
            integer count = llGetListLength(OwnerKeys);
            if (count == 1) {
                owner_line = get_display_name((key)llList2String(OwnerKeys, 0));
            } else {
                owner_line = (string)count + " owners";
            }
        } else {
            owner_line = get_display_name(CollarOwner);
        }
    }
    
    string hon_suffix = "";
    if (CollarOwnerHonorific != "") hon_suffix = " (" + CollarOwnerHonorific + ")";
    
    string body = "Owner Management\nWearer: " + get_display_name(llGetOwner()) + "\nOwner : " + owner_line + hon_suffix;
    dialog_to(user, body, base_menu_buttons());
    return 0;
}

integer begin_pick_candidate(string next_context) {
    set_ui_state(next_context, "", "", "");
    llSensor("", NULL_KEY, AGENT, 20.0, PI * 2.0);
    return 0;
}

integer show_candidate_dialog(list candidates) {
    if (llGetListLength(candidates) == 0) {
        dialog_to(User, "No valid candidates found within 20m.", ["Back"]);
        return FALSE;
    }
    
    list keys = [];
    integer i = 0;
    while (i < llGetListLength(candidates)) {
        key k = (key)llList2String(candidates, i);
        if (k != llGetOwner()) keys += (string)k;
        i += 1;
    }
    
    if (llGetListLength(keys) == 0) {
        dialog_to(User, "No valid candidates found within 20m.", ["Back"]);
        return FALSE;
    }
    
    list lines = [];
    i = 0;
    while (i < llGetListLength(keys)) {
        key k = (key)llList2String(keys, i);
        lines += [(string)(i + 1) + ". " + get_display_name(k)];
        i += 1;
    }
    
    string body = "Choose a person:\n" + llDumpList2String(lines, "\n");
    
    list buttons = [];
    integer b = 1;
    while (b <= llGetListLength(keys)) {
        buttons += (string)b;
        b += 1;
    }
    buttons += ["Back"];
    
    list parts = get_ui_parts();
    set_ui_state(llList2String(parts, 0), "", "", llDumpList2String(keys, ","));
    
    dialog_to(User, body, buttons);
    return TRUE;
}

default{
    state_entry(){
        reset_listen();
        clear_ui_state();
        AclPending = FALSE;
        AclLevel = ACL_NOACCESS;
        PluginSn = (integer)llFrand(2147480000.0);
        
        request_name(llGetOwner());
        
        notify_soft_reset();
        register_plugin();
        string q = llList2Json(JSON_OBJECT, []);
        q = llJsonSetValue(q, ["type"], CONS_SETTINGS_SYNC);
        q = llJsonSetValue(q, ["ns"],   CONS_SETTINGS_NS_OWNER);
        llMessageLinked(LINK_SET, K_SETTINGS_SYNC, q, NULL_KEY);
        logd("Ready. SN=" + (string)PluginSn);
    }

    on_rez(integer sp){ 
        llResetScript(); 
    }
    
    changed(integer c){ 
        if (c & CHANGED_OWNER) llResetScript(); 
    }

    link_message(integer sender, integer num, string str, key id){
        if (num == K_PLUGIN_PING){
            if (json_has(str, ["type"])){
                if (llJsonGetValue(str, ["type"]) == CONS_TYPE_PLUGIN_PING){
                    if (json_has(str, ["context"])){
                        if (llJsonGetValue(str, ["context"]) != PLUGIN_CONTEXT) return;
                    }
                    string pong = llList2Json(JSON_OBJECT, []);
                    pong = llJsonSetValue(pong, ["type"],    CONS_TYPE_PLUGIN_PONG);
                    pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                }
            }
            return;
        }

        if (num == K_PLUGIN_REG_QUERY){
            if (json_has(str, ["type"])){
                if (llJsonGetValue(str, ["type"]) == CONS_TYPE_REGISTER_NOW){
                    if (json_has(str, ["script"])){
                        if (llJsonGetValue(str, ["script"]) != llGetScriptName()) return;
                    }
                    register_plugin();
                }
            }
            return;
        }

        if (num == K_SETTINGS_SYNC){
            if (json_has(str, ["type"])){
                if (llJsonGetValue(str, ["type"]) == CONS_SETTINGS_SYNC){
                    ingest_settings(str);
                }
            }
            return;
        }

        if (num == K_PLUGIN_START){
            if (json_has(str, ["type"])){
                if (llJsonGetValue(str, ["type"]) == CONS_TYPE_PLUGIN_START){
                    if (json_has(str, ["context"])){
                        if (llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT){
                            User = id;
                            request_acl(User);
                            return;
                        }
                    }
                }
            }
            return;
        }

        if (num == AUTH_RESULT_NUM){
            if (!json_has(str, ["type"])) return;
            if (llJsonGetValue(str, ["type"]) != CONS_MSG_ACL_RESULT) return;
            if (!json_has(str, ["avatar"])) return;
            key av = (key)llJsonGetValue(str, ["avatar"]);
            if (av != User) return;
            if (!json_has(str, ["level"])) return;
            AclLevel = (integer)llJsonGetValue(str, ["level"]);
            AclPending = FALSE;
            if (!in_allowed_levels(AclLevel)){
                llRegionSayTo(User, 0, "Access denied.");
                ui_return_root(User);
                User = NULL_KEY;
                reset_listen();
                return;
            }
            show_menu(User);
            return;
        }
    }

    dataserver(key query_id, string data){
        if (query_id == ActiveNameQuery) {
            ActiveNameQuery = NULL_KEY;
            if (ActiveQueryTarget != NULL_KEY && data != "" && data != "???") {
                cache_name(ActiveQueryTarget, data);
                ActiveQueryTarget = NULL_KEY;
            }
        }
    }

    sensor(integer n) {
        string context = get_ui_context();
        if (context != "add_owner_select" && context != "transfer_select") return;
        
        list candidates = [];
        integer i = 0;
        while (i < n){
            key k = llDetectedKey(i);
            if (k != llGetOwner()){
                if (context == "transfer_select"){
                    if (k != CollarOwner) candidates += (string)k;
                } else {
                    candidates += (string)k;
                }
            }
            i += 1;
        }
        show_candidate_dialog(candidates);
    }
    
    no_sensor(){
        string context = get_ui_context();
        if (context == "add_owner_select" || context == "transfer_select"){
            show_candidate_dialog([]);
        }
    }

    listen(integer chan, string name, key id, string message){
        if (chan != MenuChan) return;
        if (!is_session_valid(id)) return;
        
        if (!in_allowed_levels(AclLevel)){
            llRegionSayTo(id, 0, "Access denied - permission revoked.");
            ui_return_root(id);
            User = NULL_KEY;
            reset_listen();
            return;
        }
        
        if (message == "Back"){
            string context = get_ui_context();
            if (context == "menu"){
                ui_return_root(id);
                User = NULL_KEY;
                reset_listen();
                return;
            }
            show_menu(User);
            return;
        }

        string context = get_ui_context();
        
        if (context == "menu"){
            if (id != User) return;
            
            if (message == "Add Owner"){
                begin_pick_candidate("add_owner_select");
                return;
            }
            if (message == "Transfer Sub"){
                begin_pick_candidate("transfer_select");
                return;
            }
            if (message == "Release Sub"){
                if (!has_owner()){
                    llRegionSayTo(User, 0, "No owner to release.");
                    show_menu(User);
                    return;
                }
                set_ui_state("release_owner_confirm", "", "", "");
                key release_target = get_primary_owner();
                dialog_to(release_target, "Release your submissive " + get_display_name(llGetOwner()) + "?", ["Yes", "No", "Cancel"]);
                return;
            }
            if (message == "Runaway"){
                set_ui_state("runaway_confirm", "", "", "");
                dialog_to(llGetOwner(), "Run away and become unowned?", ["Yes", "No", "Cancel"]);
                return;
            }
            show_menu(User);
            return;
        }

        if (context == "add_owner_select"){
            if (id != User) return;
            
            string data = get_ui_param(3);
            list keys = llParseString2List(data, [","], []);
            integer idx = (integer)message - 1;
            if (idx >= 0 && idx < llGetListLength(keys)) {
                key cand = (key)llList2String(keys, idx);
                set_ui_state("add_owner_cand_accept", (string)cand, "", "");
                string body = get_display_name(llGetOwner()) + " wishes to submit to you as their owner.\nDo you accept?";
                dialog_to(cand, body, ["Yes", "No", "Cancel"]);
                return;
            }
            show_menu(User);
            return;
        }
        
        if (context == "add_owner_cand_accept"){
            key expected_candidate = (key)get_ui_param(1);
            if (id != expected_candidate) return;
            
            if (message == "Yes"){
                list honors = ["Master", "Mistress", "Daddy", "Mommy", "King", "Queen"];
                set_ui_state("add_owner_hon", (string)expected_candidate, "", "");
                dialog_to(id, "Choose the honorific you wish to be called:", honors);
                return;
            }
            show_menu(User);
            return;
        }
        
        if (context == "add_owner_hon"){
            key expected_candidate = (key)get_ui_param(1);
            if (id != expected_candidate) return;
            
            list honors = ["Master", "Mistress", "Daddy", "Mommy", "King", "Queen"];
            integer sel = llListFindList(honors, [message]);
            if (sel != -1){
                string honorific = llList2String(honors, sel);
                set_ui_state("add_owner_wearer_ok", (string)expected_candidate, honorific, "");
                string body = "You have submitted to " + get_display_name(expected_candidate) + " as your " + honorific + ".\nConfirm?";
                dialog_to(llGetOwner(), body, ["Yes", "No", "Cancel"]);
                return;
            }
            dialog_to(id, "Please choose an honorific.", honors);
            return;
        }
        
        if (context == "add_owner_wearer_ok"){
            if (id != llGetOwner()) return;
            
            if (message == "Yes"){
                key new_owner = (key)get_ui_param(1);
                string honorific = get_ui_param(2);
                CollarOwner = new_owner;
                CollarOwnerHonorific = honorific;
                push_settings();
                dialog_to(new_owner, get_display_name(llGetOwner()) + " has submitted to you as their \"" + honorific + "\".", ["OK"]);
                dialog_to(llGetOwner(), "You have submitted to " + get_display_name(new_owner) + " as your " + honorific + ".", ["OK"]);
                clear_ui_state();
                key prior_user = User;
                User = NULL_KEY;
                reset_listen();
                if (prior_user != NULL_KEY){
                    ui_return_root(prior_user);
                }
                return;
            }
            show_menu(User);
            return;
        }

        if (context == "transfer_select"){
            if (id != User) return;
            
            string data = get_ui_param(3);
            list keys = llParseString2List(data, [","], []);
            integer idx = (integer)message - 1;
            if (idx >= 0 && idx < llGetListLength(keys)){
                key new_owner = (key)llList2String(keys, idx);
                set_ui_state("transfer_cand_accept", (string)new_owner, "", "");
                string body = "You have been offered ownership of " + get_display_name(llGetOwner()) + ".\nDo you accept?";
                dialog_to(new_owner, body, ["Yes", "No", "Cancel"]);
                return;
            }
            show_menu(User);
            return;
        }
        
        if (context == "transfer_cand_accept"){
            key expected_candidate = (key)get_ui_param(1);
            if (id != expected_candidate) return;
            
            if (message == "Yes"){
                list honors = ["Master", "Mistress", "Daddy", "Mommy", "King", "Queen"];
                set_ui_state("transfer_hon", (string)expected_candidate, "", "");
                dialog_to(id, "Choose the honorific you wish to be called:", honors);
                return;
            }
            show_menu(User);
            return;
        }
        
        if (context == "transfer_hon"){
            key expected_candidate = (key)get_ui_param(1);
            if (id != expected_candidate) return;
            
            list honors = ["Master", "Mistress", "Daddy", "Mommy", "King", "Queen"];
            integer sel = llListFindList(honors, [message]);
            if (sel != -1){
                string honorific = llList2String(honors, sel);
                key old_owner = CollarOwner;
                CollarOwner = expected_candidate;
                CollarOwnerHonorific = honorific;
                push_settings();
                dialog_to(old_owner, "You have transferred your sub " + get_display_name(llGetOwner()) + " to " + get_display_name(expected_candidate) + " as their " + honorific + ".", ["OK"]);
                dialog_to(expected_candidate, "You are now the owner of " + get_display_name(llGetOwner()) + " as their " + honorific + ".", ["OK"]);
                show_menu(User);
                return;
            }
            dialog_to(id, "Please choose an honorific.", honors);
            return;
        }

        if (context == "release_owner_confirm"){
            integer is_owner = FALSE;
            if (MultiOwnerMode) {
                integer i = 0;
                while (i < llGetListLength(OwnerKeys)) {
                    if ((key)llList2String(OwnerKeys, i) == id) {
                        is_owner = TRUE;
                    }
                    i += 1;
                }
            } else {
                if (id == CollarOwner) is_owner = TRUE;
            }
            
            if (!is_owner) return;
            
            if (message == "Yes"){
                set_ui_state("release_wearer_confirm", "", "", "");
                string owner_desc = get_display_name(CollarOwner);
                string body = "You have been released by " + owner_desc + ".\nConfirm freedom?";
                dialog_to(llGetOwner(), body, ["Yes", "No", "Cancel"]);
                return;
            }
            show_menu(User);
            return;
        }
        
        if (context == "release_wearer_confirm"){
            if (id != llGetOwner()) return;
            
            if (message == "Yes"){
                CollarOwner = NULL_KEY;
                OwnerKeys = [];
                CollarOwnerHonorific = "";
                push_settings();
                dialog_to(llGetOwner(), "You have been released.\nYou are now free.", ["OK"]);
                show_menu(User);
                return;
            }
            show_menu(User);
            return;
        }

        if (context == "runaway_confirm"){
            if (id != llGetOwner()) return;
            
            if (message == "Yes"){
                CollarOwner = NULL_KEY;
                OwnerKeys = [];
                CollarOwnerHonorific = "";
                push_settings();
                dialog_to(id, "You have run away and are now unowned.", ["OK"]);
                show_menu(User);
                return;
            }
            show_menu(User);
            return;
        }

        show_menu(User);
    }

    timer(){
        reset_listen();
    }
}
