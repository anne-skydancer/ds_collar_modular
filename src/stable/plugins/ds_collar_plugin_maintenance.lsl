/* =============================================================
   PLUGIN: ds_collar_plugin_maintenance.lsl
   Maintenance and utility functions
   ============================================================= */

integer DEBUG = FALSE;

/* Kernel link numbers */
integer K_PLUGIN_REG_QUERY     = 500;
integer K_PLUGIN_REG_REPLY     = 501;
integer K_PLUGIN_SOFT_RESET    = 504;
integer K_PLUGIN_PING          = 650;
integer K_PLUGIN_PONG          = 651;
integer AUTH_QUERY_NUM         = 700;
integer AUTH_RESULT_NUM        = 710;
integer K_SETTINGS_QUERY       = 800;
integer K_SETTINGS_SYNC        = 870;
integer K_PLUGIN_START         = 900;
integer K_PLUGIN_RETURN_NUM    = 901;
integer SOS_MSG_NUM            = 950;

/* Identity */
string  PLUGIN_CONTEXT   = "core_maintenance";
string  PLUGIN_LABEL     = "Maintenance";
integer PLUGIN_SN        = 0;
integer PLUGIN_MIN_ACL   = 1;

/* ACL levels */
list ALLOWED_ACL_VIEW    = [1,2,3,4,5];
list ALLOWED_ACL_FULL    = [2,3,4,5];

/* Message types */
string TYPE_SETTINGS_GET   = "settings_get";
string TYPE_SETTINGS_SYNC  = "settings_sync";
string TYPE_ACL_QUERY      = "acl_query";
string TYPE_ACL_RESULT     = "acl_result";

/* UI */
integer DIALOG_TIMEOUT    = 180;

/* UI session */
key     MenuUser         = NULL_KEY;
integer ListenHandle     = 0;
integer MenuChan         = 0;
integer AclLevel         = 0;
integer DialogExpires    = 0;
list    MenuPairs        = [];

/* Settings cache */
string  CachedSettings   = "";
integer SettingsReady    = FALSE;

/* Heartbeat */
integer LastPingEpoch    = 0;

/* Inventory items */
string  HUD_ITEM         = "Control HUD";
string  MANUAL_NOTECARD  = "DS Collar User Manual";

integer now(){ return llGetUnixTime(); }

integer json_has(string j, list p){ 
    return (llJsonGetValue(j, p) != JSON_INVALID);
}

/* ============ LISTENER MANAGEMENT ============ */
integer reset_listen(){
    integer old_listen = ListenHandle;
    ListenHandle = 0;
    MenuChan = 0;
    MenuPairs = [];
    
    if (old_listen != 0){
        llListenRemove(old_listen);
        if (DEBUG) llOwnerSay("[MAINT] Removed menu listener: " + (string)old_listen);
    }
    return 0;
}

integer is_session_valid(){
    return (MenuUser != NULL_KEY && ListenHandle != 0 && MenuChan != 0);
}

integer cleanup_all_sessions(){
    if (DEBUG) llOwnerSay("[MAINT] Cleaning up all sessions");
    
    reset_listen();
    MenuUser = NULL_KEY;
    DialogExpires = 0;
    AclLevel = 0;
    
    llSetTimerEvent(0.0);
    return 0;
}

/* Pairs helpers */
list pairs_to_labels(list p){
    list l = [];
    integer i = 0;
    integer len = llGetListLength(p);
    while (i < len){ 
        l += llList2String(p, i); 
        i += 2; 
    }
    return l;
}

string cmd_from_label(string lbl){
    integer i = 0;
    integer len = llGetListLength(MenuPairs);
    while (i + 1 < len){
        if (llList2String(MenuPairs, i) == lbl) return llList2String(MenuPairs, i+1);
        i += 2;
    }
    return "";
}

/* Registration */
integer register_self(){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["type"], "register");
    j = llJsonSetValue(j, ["sn"], (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"], PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"], (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    return 0;
}

integer hb_tick(){
    if ((now() - LastPingEpoch) > 60){ 
        register_self(); 
        LastPingEpoch = now(); 
    }
    return 0;
}

/* AUTH */
integer request_acl(key av){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["type"], TYPE_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    return 0;
}

/* Settings */
integer request_settings(){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    return 0;
}

/* Dialog */
integer begin_dialog(key u, string b, list p){
    if (u == NULL_KEY) return 0;
    
    reset_listen();
    MenuUser = u;
    MenuPairs = p;
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    ListenHandle = llListen(MenuChan,"",MenuUser,"");
    llDialog(MenuUser, b, pairs_to_labels(p), MenuChan);
    DialogExpires = now() + DIALOG_TIMEOUT;
    
    return 0;
}

list make_menu_pairs(integer acl){
    list p = ["Back","back"];
    
    if (llListFindList(ALLOWED_ACL_FULL, [acl]) != -1){
        p += ["View Settings","view"];
        p += ["Reload Settings","reload"];
        p += ["Clear Leash","clearlsh"];
    }
    
    p += ["Get HUD","gethud"];
    p += ["User Manual","manual"];
    
    return p;
}

integer show_main_menu(key u, integer acl){
    string t = "Maintenance:\n\n";
    
    if (llListFindList(ALLOWED_ACL_FULL, [acl]) != -1){
        t += "System utilities and documentation.";
    } else {
        t += "Get HUD or user manual.";
    }
    
    begin_dialog(u, t, make_menu_pairs(acl));
    return 0;
}

integer ui_return_root(key u){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["type"], "plugin_return");
    j = llJsonSetValue(j, ["context"], "core_root");
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, j, u);
    return 0;
}

/* Actions */
integer do_view_settings(){
    if (!SettingsReady || CachedSettings == ""){
        llRegionSayTo(MenuUser, 0, "Settings not loaded yet. Try again.");
        return 0;
    }
    
    string kv = llJsonGetValue(CachedSettings, ["kv"]);
    if (!json_has(CachedSettings, ["kv"])){
        kv = CachedSettings;
    }
    
    llRegionSayTo(MenuUser, 0, "=== COLLAR SETTINGS ===");
    
    /* Multi-owner mode */
    string multi_owner_mode_val = "0";
    if (json_has(kv, ["multi_owner_mode"])){
        multi_owner_mode_val = llJsonGetValue(kv, ["multi_owner_mode"]);
        llRegionSayTo(MenuUser, 0, "multi_owner_mode=" + multi_owner_mode_val);
    }
    
    /* Owner settings - mode aware */
    if (multi_owner_mode_val == "1"){
        if (json_has(kv, ["owner_keys"])){
            string val = llJsonGetValue(kv, ["owner_keys"]);
            if (val != "[]" && val != JSON_INVALID){
                llRegionSayTo(MenuUser, 0, "owner_keys=" + val);
            }
        }
        
        if (json_has(kv, ["owner_honorifics"])){
            string val = llJsonGetValue(kv, ["owner_honorifics"]);
            if (val != "[]" && val != JSON_INVALID){
                llRegionSayTo(MenuUser, 0, "owner_honorifics=" + val);
            }
        }
    }
    else {
        if (json_has(kv, ["owner_key"])){
            string val = llJsonGetValue(kv, ["owner_key"]);
            if (val != "" && val != (string)NULL_KEY){
                llRegionSayTo(MenuUser, 0, "owner_key=" + val);
            }
        }
        
        if (json_has(kv, ["owner_hon"])){
            string val = llJsonGetValue(kv, ["owner_hon"]);
            if (val != "" && val != " "){
                llRegionSayTo(MenuUser, 0, "owner_hon=" + val);
            }
        }
    }
    
    /* Trustees */
    if (json_has(kv, ["trustees"])){
        string val = llJsonGetValue(kv, ["trustees"]);
        if (val != "[]" && val != JSON_INVALID){
            llRegionSayTo(MenuUser, 0, "trustees=" + val);
        }
    }
    
    if (json_has(kv, ["trustee_honorifics"])){
        string val = llJsonGetValue(kv, ["trustee_honorifics"]);
        if (val != "[]" && val != JSON_INVALID){
            llRegionSayTo(MenuUser, 0, "trustee_honorifics=" + val);
        }
    }
    
    /* Blacklist */
    if (json_has(kv, ["blacklist"])){
        string val = llJsonGetValue(kv, ["blacklist"]);
        if (val != "[]" && val != JSON_INVALID){
            llRegionSayTo(MenuUser, 0, "blacklist=" + val);
        }
    }
    
    /* Boolean settings */
    if (json_has(kv, ["public_mode"])){
        string val = llJsonGetValue(kv, ["public_mode"]);
        llRegionSayTo(MenuUser, 0, "public_mode=" + val);
    }
    
    if (json_has(kv, ["tpe_mode"])){
        string val = llJsonGetValue(kv, ["tpe_mode"]);
        llRegionSayTo(MenuUser, 0, "tpe_mode=" + val);
    }
    
    if (json_has(kv, ["locked"])){
        string val = llJsonGetValue(kv, ["locked"]);
        llRegionSayTo(MenuUser, 0, "locked=" + val);
    }
    
    llRegionSayTo(MenuUser, 0, "======================");
    return 0;
}

integer do_reload_settings(){
    request_settings();
    llRegionSayTo(MenuUser, 0, "Settings reload requested.");
    return 0;
}

integer do_clear_leash(){
    llOwnerSay("@clear");
    llOwnerSay("@unsit=force");
    llRegionSayTo(MenuUser, 0, "Sent RLV @clear and @unsit=force");
    return 0;
}

integer do_give_hud(){
    if (llGetInventoryType(HUD_ITEM) != INVENTORY_OBJECT){
        llRegionSayTo(MenuUser, 0, "HUD not found in inventory.");
        return 0;
    }
    
    llGiveInventory(MenuUser, HUD_ITEM);
    llRegionSayTo(MenuUser, 0, "HUD sent.");
    return 0;
}

integer do_give_manual(){
    if (llGetInventoryType(MANUAL_NOTECARD) != INVENTORY_NOTECARD){
        llRegionSayTo(MenuUser, 0, "Manual notecard not found.");
        return 0;
    }
    
    llGiveInventory(MenuUser, MANUAL_NOTECARD);
    llRegionSayTo(MenuUser, 0, "User manual sent.");
    return 0;
}

default{
    state_entry(){
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        LastPingEpoch = now();
        
        string j = llList2Json(JSON_OBJECT,[]);
        j = llJsonSetValue(j, ["type"], "plugin_soft_reset");
        j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
        llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
        register_self();
        
        request_settings();
        
        cleanup_all_sessions();
        AclLevel = 0;
    }

    on_rez(integer p){ llResetScript(); }
    
    changed(integer c){ 
        if (c & CHANGED_OWNER) llResetScript(); 
    }

    link_message(integer s, integer n, string m, key id){
        if (n == K_PLUGIN_SOFT_RESET){
            if (json_has(m, ["type"]) && llJsonGetValue(m, ["type"]) == "plugin_soft_reset"){
                integer clr = TRUE;
                if (json_has(m, ["context"])){
                    string ctx = llJsonGetValue(m, ["context"]);
                    if (ctx == "all" || ctx == "*" || ctx == PLUGIN_CONTEXT) clr = FALSE;
                }
                if (clr){
                    cleanup_all_sessions();
                }
            }
            return;
        }
        
        if (n == K_PLUGIN_PING){
            if (json_has(m, ["type"]) && llJsonGetValue(m, ["type"]) == "plugin_ping"){
                if (json_has(m, ["context"]) && llJsonGetValue(m, ["context"]) == PLUGIN_CONTEXT){
                    LastPingEpoch = now();
                    string j = llList2Json(JSON_OBJECT,[]);
                    j = llJsonSetValue(j, ["type"], "plugin_pong");
                    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, j, NULL_KEY);
                }
            }
            return;
        }
        
        if (n == K_PLUGIN_REG_QUERY){
            if (json_has(m, ["type"]) && llJsonGetValue(m, ["type"]) == "register_now"){
                if (json_has(m, ["script"]) && llJsonGetValue(m, ["script"]) == llGetScriptName()){
                    register_self();
                    LastPingEpoch = now();
                }
            }
            return;
        }
        
        if (n == K_PLUGIN_START){
            if (json_has(m, ["type"]) && llJsonGetValue(m, ["type"]) == "plugin_start"){
                if (json_has(m, ["context"]) && llJsonGetValue(m, ["context"]) == PLUGIN_CONTEXT){
                    MenuUser = id;
                    request_acl(id);
                }
            }
            return;
        }
        
        if (n == K_SETTINGS_SYNC){
            if (json_has(m, ["type"]) && llJsonGetValue(m, ["type"]) == TYPE_SETTINGS_SYNC){
                CachedSettings = m;
                SettingsReady = TRUE;
                if (DEBUG) llOwnerSay("[MAINT] Settings cached");
            }
            return;
        }
        
        if (n == AUTH_RESULT_NUM){
            if (!json_has(m, ["type"])) return;
            if (llJsonGetValue(m, ["type"]) != TYPE_ACL_RESULT) return;
            if (!json_has(m, ["avatar"]) || !json_has(m, ["level"])) return;
            
            key av = (key)llJsonGetValue(m, ["avatar"]);
            if (av != MenuUser) return;
            
            AclLevel = (integer)llJsonGetValue(m, ["level"]);
            if (AclLevel < 0 || llListFindList(ALLOWED_ACL_VIEW, [AclLevel]) == -1){
                llRegionSayTo(MenuUser, 0, "Access denied.");
                ui_return_root(MenuUser);
                cleanup_all_sessions();
                return;
            }
            show_main_menu(MenuUser, AclLevel);
        }
    }

    listen(integer ch, string nm, key id, string txt){
        if (ch == MenuChan){
            if (!is_session_valid()) return;
            if (id != MenuUser) return;
            
            string cmd = cmd_from_label(txt);
            
            if (cmd == "back"){
                ui_return_root(MenuUser);
                cleanup_all_sessions();
                return;
            }
            
            if (cmd == "view"){
                if (llListFindList(ALLOWED_ACL_FULL, [AclLevel]) != -1){
                    do_view_settings();
                } else {
                    llRegionSayTo(MenuUser, 0, "Not allowed.");
                }
                cleanup_all_sessions();
                return;
            }
            
            if (cmd == "reload"){
                if (llListFindList(ALLOWED_ACL_FULL, [AclLevel]) != -1){
                    do_reload_settings();
                } else {
                    llRegionSayTo(MenuUser, 0, "Not allowed.");
                }
                cleanup_all_sessions();
                return;
            }
            
            if (cmd == "clearlsh"){
                if (llListFindList(ALLOWED_ACL_FULL, [AclLevel]) != -1){
                    do_clear_leash();
                } else {
                    llRegionSayTo(MenuUser, 0, "Not allowed.");
                }
                cleanup_all_sessions();
                return;
            }
            
            if (cmd == "gethud"){
                do_give_hud();
                cleanup_all_sessions();
                return;
            }
            
            if (cmd == "manual"){
                do_give_manual();
                cleanup_all_sessions();
                return;
            }
            
            show_main_menu(MenuUser, AclLevel);
        }
    }

    timer(){
        hb_tick();
        
        if (DialogExpires != 0 && now() >= DialogExpires){
            cleanup_all_sessions();
            return;
        }
    }
}
