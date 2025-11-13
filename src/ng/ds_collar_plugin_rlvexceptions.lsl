/*--------------------
PLUGIN: ds_collar_plugin_rlvexceptions.lsl
VERSION: 1.00
REVISION: 20
PURPOSE: Manage RLV teleport and IM exceptions for owners and trustees
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Provides toggleable owner and trustee TP/IM exception controls
- Mirrors multi-owner and trustee rosters from settings synchronizations
- Issues live @accepttp/@sendim updates when exceptions change
- Clears stale exceptions when users or roles are removed from collar
- Presents ACL-gated dialog workflow for managing exception sets
--------------------*/

integer DEBUG = TRUE;
integer PRODUCTION = FALSE;

string SCRIPT_ID = "plugin_rlvexceptions";

/* -------------------- ABI CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_rlv_exceptions";
string PLUGIN_LABEL = "Exceptions";
integer PLUGIN_MIN_ACL = 3;

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_EX_OWNER_TP = "ex_owner_tp";
string KEY_EX_OWNER_IM = "ex_owner_im";
string KEY_EX_TRUSTEE_TP = "ex_trustee_tp";
string KEY_EX_TRUSTEE_IM = "ex_trustee_im";
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_KEYS = "owner_keys";
string KEY_TRUSTEES = "trustees";
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";

/* -------------------- STATE -------------------- */
integer ExOwnerTp = TRUE;
integer ExOwnerIm = TRUE;
integer ExTrusteeTp = FALSE;
integer ExTrusteeIm = FALSE;

key OwnerKey;
list OwnerKeys;
list TrusteeKeys;
integer MultiOwnerMode;

key CurrentUser;
integer UserAcl = -999;
string SessionId;
string MenuContext;

/* -------------------- HELPERS -------------------- */

logd(string msg) {
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] " + msg);
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string gen_session() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- MESSAGE ROUTING -------------------- */

integer is_message_for_me(string msg) {
    if (!json_has(msg, ["to"])) return FALSE;  // STRICT: No "to" field = reject
    string to = llJsonGetValue(msg, ["to"]);
    if (to == SCRIPT_ID) return TRUE;  // STRICT: Accept ONLY exact SCRIPT_ID match
    return FALSE;  // STRICT: Reject everything else (broadcasts, wildcards, variants)
}

string create_routed_message(string to_id, list fields) {
    list routed = ["from", SCRIPT_ID, "to", to_id] + fields;
    return llList2Json(JSON_OBJECT, routed);
}

string create_broadcast(list fields) {
    return create_routed_message("*", fields);
}

/* -------------------- RLV COMMANDS -------------------- */

apply_tp_exception(key k, integer allow) {
    if (k == NULL_KEY) return;
    
    if (allow) {
        llOwnerSay("@accepttp:" + (string)k + "=add");
        llOwnerSay("@tplure:" + (string)k + "=add");
    }
    else {
        llOwnerSay("@accepttp:" + (string)k + "=rem");
        llOwnerSay("@tplure:" + (string)k + "=rem");
    }
}

apply_im_exception(key k, integer allow) {
    if (k == NULL_KEY) return;
    
    if (allow) {
        llOwnerSay("@sendim:" + (string)k + "=add");
        llOwnerSay("@recvim:" + (string)k + "=add");
    }
    else {
        llOwnerSay("@sendim:" + (string)k + "=rem");
        llOwnerSay("@recvim:" + (string)k + "=rem");
    }
}

reconcile_all() {
    logd("Reconciling RLV exceptions");
    
    // Owner exceptions
    if (MultiOwnerMode) {
        integer i;
        integer len = llGetListLength(OwnerKeys);
        while (i < len) {
            key k = (key)llList2String(OwnerKeys, i);
            apply_tp_exception(k, ExOwnerTp);
            apply_im_exception(k, ExOwnerIm);
            i++;
        }
    }
    else {
        apply_tp_exception(OwnerKey, ExOwnerTp);
        apply_im_exception(OwnerKey, ExOwnerIm);
    }
    
    // Trustee exceptions
    integer i;
    integer len = llGetListLength(TrusteeKeys);
    while (i < len) {
        key k = (key)llList2String(TrusteeKeys, i);
        apply_tp_exception(k, ExTrusteeTp);
        apply_im_exception(k, ExTrusteeIm);
        i++;
    }
}

/* -------------------- LIFECYCLE -------------------- */

register_self() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- SETTINGS -------------------- */

apply_settings_sync(string msg) {
    // PHASE 2: Read directly from linkset data
    // Reset defaults
    ExOwnerTp = TRUE;
    ExOwnerIm = TRUE;
    ExTrusteeTp = FALSE;
    ExTrusteeIm = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    TrusteeKeys = [];
    MultiOwnerMode = FALSE;
    
    // Load exception settings
    string val_owner_tp = llLinksetDataRead(KEY_EX_OWNER_TP);
    if (val_owner_tp != "") ExOwnerTp = (integer)val_owner_tp;
    
    string val_owner_im = llLinksetDataRead(KEY_EX_OWNER_IM);
    if (val_owner_im != "") ExOwnerIm = (integer)val_owner_im;
    
    string val_trustee_tp = llLinksetDataRead(KEY_EX_TRUSTEE_TP);
    if (val_trustee_tp != "") ExTrusteeTp = (integer)val_trustee_tp;
    
    string val_trustee_im = llLinksetDataRead(KEY_EX_TRUSTEE_IM);
    if (val_trustee_im != "") ExTrusteeIm = (integer)val_trustee_im;
    
    // Load owner/trustee lists
    string val_multi = llLinksetDataRead(KEY_MULTI_OWNER_MODE);
    if (val_multi != "") MultiOwnerMode = (integer)val_multi;
    
    if (MultiOwnerMode) {
        string val_owner_keys = llLinksetDataRead(KEY_OWNER_KEYS);
        if (val_owner_keys != "" && llGetSubString(val_owner_keys, 0, 0) == "[") {
            OwnerKeys = llJson2List(val_owner_keys);
        }
    }
    else {
        string val_owner_key = llLinksetDataRead(KEY_OWNER_KEY);
        if (val_owner_key != "") OwnerKey = (key)val_owner_key;
    }
    
    string val_trustees = llLinksetDataRead(KEY_TRUSTEES);
    if (val_trustees != "" && llGetSubString(val_trustees, 0, 0) == "[") {
        TrusteeKeys = llJson2List(val_trustees);
    }
    
    // Apply RLV commands
    reconcile_all();
    
    logd("Settings applied");
}

apply_settings_delta(string msg) {
    // PHASE 2: Simplified - just re-sync all settings (safe and correct)
    // This RLV plugin needs full state refresh anyway to reconcile exceptions
    apply_settings_sync(msg);
    logd("Delta applied via full sync");
}

persist_setting(string setting_key, integer value) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", setting_key,
        "value", (string)value
    ]), NULL_KEY);
}

/* -------------------- ACL -------------------- */

request_acl(key user) {
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_acl"
    ]), NULL_KEY);
}

handle_acl_result(string msg) {
    if (!json_has(msg, ["avatar"]) || !json_has(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    UserAcl = (integer)llJsonGetValue(msg, ["level"]);
    
    if (UserAcl < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanup();
        return;
    }
    
    show_main();
}

/* -------------------- MENUS -------------------- */

show_main() {
    SessionId = gen_session();
    MenuContext = "main";
    
    string body = "RLV Exceptions\n\nManage which restrictions can be bypassed by owners and trustees.";
    
    list buttons = ["Back", "Owner", "Trustee"];
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]), NULL_KEY);
}

show_owner_menu() {
    SessionId = gen_session();
    MenuContext = "owner";
    
    string body = "Owner Exceptions\n\nCurrent settings:\n";
    if (ExOwnerTp) body += "TP: Allowed\n";
    else body += "TP: Denied\n";
    if (ExOwnerIm) body += "IM: Allowed";
    else body += "IM: Denied";
    
    list buttons = ["Back", "TP", "IM"];
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Owner Exceptions",
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]), NULL_KEY);
}

show_trustee_menu() {
    SessionId = gen_session();
    MenuContext = "trustee";
    
    string body = "Trustee Exceptions\n\nCurrent settings:\n";
    if (ExTrusteeTp) body += "TP: Allowed\n";
    else body += "TP: Denied\n";
    if (ExTrusteeIm) body += "IM: Allowed";
    else body += "IM: Denied";
    
    list buttons = ["Back", "TP", "IM"];
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Trustee Exceptions",
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]), NULL_KEY);
}

show_toggle(string role, string exception_type, string setting_key, integer current) {
    SessionId = gen_session();
    MenuContext = role + "_" + exception_type;
    
    string body = role + " " + exception_type + " Exception\n\n";
    if (current) body += "Current: Allowed\n\n";
    else body += "Current: Denied\n\n";
    body += "Allow = Owner/trustee can bypass restrictions\n";
    body += "Deny = Normal restrictions apply";
    
    list buttons = ["Back", "Allow", "Deny"];
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", role + " " + exception_type,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, buttons),
        "timeout", 60
    ]), NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button(string btn) {
    if (btn == "Back") {
        if (MenuContext == "main") {
            llMessageLinked(LINK_SET, UI_BUS, create_routed_message("kmod_ui", [
                "type", "return", "user", (string)CurrentUser
            ]), NULL_KEY);
            cleanup();
        }
        else if (MenuContext == "owner" || MenuContext == "trustee") {
            show_main();
        }
        else {
            if (llSubStringIndex(MenuContext, "owner") == 0) show_owner_menu();
            else if (llSubStringIndex(MenuContext, "trustee") == 0) show_trustee_menu();
            else show_main();
        }
        return;
    }
    
    if (MenuContext == "main") {
        if (btn == "Owner") show_owner_menu();
        else if (btn == "Trustee") show_trustee_menu();
    }
    else if (MenuContext == "owner") {
        if (btn == "TP") show_toggle("Owner", "TP", KEY_EX_OWNER_TP, ExOwnerTp);
        else if (btn == "IM") show_toggle("Owner", "IM", KEY_EX_OWNER_IM, ExOwnerIm);
    }
    else if (MenuContext == "trustee") {
        if (btn == "TP") show_toggle("Trustee", "TP", KEY_EX_TRUSTEE_TP, ExTrusteeTp);
        else if (btn == "IM") show_toggle("Trustee", "IM", KEY_EX_TRUSTEE_IM, ExTrusteeIm);
    }
    else if (MenuContext == "owner_TP") {
        if (btn == "Allow") {
            persist_setting(KEY_EX_OWNER_TP, TRUE);
            llRegionSayTo(CurrentUser, 0, "Owner TP exception allowed.");
        }
        else if (btn == "Deny") {
            persist_setting(KEY_EX_OWNER_TP, FALSE);
            llRegionSayTo(CurrentUser, 0, "Owner TP exception denied.");
        }
        show_owner_menu();
    }
    else if (MenuContext == "owner_IM") {
        if (btn == "Allow") {
            persist_setting(KEY_EX_OWNER_IM, TRUE);
            llRegionSayTo(CurrentUser, 0, "Owner IM exception allowed.");
        }
        else if (btn == "Deny") {
            persist_setting(KEY_EX_OWNER_IM, FALSE);
            llRegionSayTo(CurrentUser, 0, "Owner IM exception denied.");
        }
        show_owner_menu();
    }
    else if (MenuContext == "trustee_TP") {
        if (btn == "Allow") {
            persist_setting(KEY_EX_TRUSTEE_TP, TRUE);
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception allowed.");
        }
        else if (btn == "Deny") {
            persist_setting(KEY_EX_TRUSTEE_TP, FALSE);
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception denied.");
        }
        show_trustee_menu();
    }
    else if (MenuContext == "trustee_IM") {
        if (btn == "Allow") {
            persist_setting(KEY_EX_TRUSTEE_IM, TRUE);
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception allowed.");
        }
        else if (btn == "Deny") {
            persist_setting(KEY_EX_TRUSTEE_IM, FALSE);
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception denied.");
        }
        show_trustee_menu();
    }
}

/* -------------------- CLEANUP -------------------- */

cleanup() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    SessionId = "";
    MenuContext = "";
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        cleanup();
        register_self();
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings_get"
        ]), NULL_KEY);
    }
    
    on_rez(integer p) {
        llResetScript();
    }
    
    changed(integer c) {
        if (c & CHANGED_OWNER) llResetScript();
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        if (!is_message_for_me(msg)) return;
        
        if (!json_has(msg, ["type"])) return;
        string type = llJsonGetValue(msg, ["type"]);
        
        if (num == KERNEL_LIFECYCLE) {
            if (type == "register_now") register_self();
            else if (type == "ping") send_pong();
        }
        else if (num == SETTINGS_BUS) {
            if (type == "settings_sync") apply_settings_sync(msg);
            else if (type == "settings_delta") apply_settings_delta(msg);
        }
        else if (num == UI_BUS) {
            if (type == "start" && json_has(msg, ["context"])) {
                if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    CurrentUser = id;
                    request_acl(id);
                }
            }
        }
        else if (num == AUTH_BUS) {
            if (type == "acl_result") handle_acl_result(msg);
        }
        else if (num == DIALOG_BUS) {
            if (type == "dialog_response") {
                if (json_has(msg, ["session_id"]) && json_has(msg, ["button"])) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) {
                        handle_button(llJsonGetValue(msg, ["button"]));
                    }
                }
            }
            else if (type == "dialog_timeout") {
                if (json_has(msg, ["session_id"])) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) cleanup();
                }
            }
        }
    }
}
