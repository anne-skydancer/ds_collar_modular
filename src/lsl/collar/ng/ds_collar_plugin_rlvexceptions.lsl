/*--------------------
PLUGIN: ds_collar_plugin_rlvexceptions.lsl
VERSION: 1.00
REVISION: 21
PURPOSE: Manage RLV teleport and IM exceptions for owners and trustees
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- CRITICAL FIX: Re-request settings on register_now to reapply RLV exceptions after kernel/module resets
- Provides toggleable owner and trustee TP/IM exception controls
- Mirrors multi-owner and trustee rosters from settings synchronizations
- Issues live @accepttp/@sendim updates when exceptions change
- Clears stale exceptions when users or roles are removed from collar
- Presents ACL-gated dialog workflow for managing exception sets
--------------------*/


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


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string gen_session() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
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
    string kv = llJsonGetValue(msg, ["kv"]);
    if (kv == JSON_INVALID) return;

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
    string ex_owner_tp_val = llJsonGetValue(kv, [KEY_EX_OWNER_TP]);
    if (ex_owner_tp_val != JSON_INVALID) {
        ExOwnerTp = (integer)ex_owner_tp_val;
    }
    string ex_owner_im_val = llJsonGetValue(kv, [KEY_EX_OWNER_IM]);
    if (ex_owner_im_val != JSON_INVALID) {
        ExOwnerIm = (integer)ex_owner_im_val;
    }
    string ex_trustee_tp_val = llJsonGetValue(kv, [KEY_EX_TRUSTEE_TP]);
    if (ex_trustee_tp_val != JSON_INVALID) {
        ExTrusteeTp = (integer)ex_trustee_tp_val;
    }
    string ex_trustee_im_val = llJsonGetValue(kv, [KEY_EX_TRUSTEE_IM]);
    if (ex_trustee_im_val != JSON_INVALID) {
        ExTrusteeIm = (integer)ex_trustee_im_val;
    }

    // Load owner/trustee lists
    string multi_owner_val = llJsonGetValue(kv, [KEY_MULTI_OWNER_MODE]);
    if (multi_owner_val != JSON_INVALID) {
        MultiOwnerMode = (integer)multi_owner_val;
    }

    if (MultiOwnerMode) {
        string arr = llJsonGetValue(kv, [KEY_OWNER_KEYS]);
        if (arr != JSON_INVALID) {
            if (llGetSubString(arr, 0, 0) == "[") OwnerKeys = llJson2List(arr);
        }
    }
    else {
        string owner_key_val = llJsonGetValue(kv, [KEY_OWNER_KEY]);
        if (owner_key_val != JSON_INVALID) {
            OwnerKey = (key)owner_key_val;
        }
    }

    string trustees_arr = llJsonGetValue(kv, [KEY_TRUSTEES]);
    if (trustees_arr != JSON_INVALID) {
        if (llGetSubString(trustees_arr, 0, 0) == "[") TrusteeKeys = llJson2List(trustees_arr);
    }
    
    // Apply RLV commands
    reconcile_all();
}

apply_settings_delta(string msg) {
    string op = llJsonGetValue(msg, ["op"]);
    if (op == JSON_INVALID) return;

    if (op == "set") {
        string changes = llJsonGetValue(msg, ["changes"]);
        if (changes == JSON_INVALID) return;

        string ex_owner_tp_val = llJsonGetValue(changes, [KEY_EX_OWNER_TP]);
        if (ex_owner_tp_val != JSON_INVALID) {
            ExOwnerTp = (integer)ex_owner_tp_val;
            reconcile_all();
        }
        string ex_owner_im_val = llJsonGetValue(changes, [KEY_EX_OWNER_IM]);
        if (ex_owner_im_val != JSON_INVALID) {
            ExOwnerIm = (integer)ex_owner_im_val;
            reconcile_all();
        }
        string ex_trustee_tp_val = llJsonGetValue(changes, [KEY_EX_TRUSTEE_TP]);
        if (ex_trustee_tp_val != JSON_INVALID) {
            ExTrusteeTp = (integer)ex_trustee_tp_val;
            reconcile_all();
        }
        string ex_trustee_im_val = llJsonGetValue(changes, [KEY_EX_TRUSTEE_IM]);
        if (ex_trustee_im_val != JSON_INVALID) {
            ExTrusteeIm = (integer)ex_trustee_im_val;
            reconcile_all();
        }

        // Handle owner_key changes (single owner mode)
        string owner_key_val = llJsonGetValue(changes, [KEY_OWNER_KEY]);
        if (owner_key_val != JSON_INVALID) {
            key old_owner = OwnerKey;
            OwnerKey = (key)owner_key_val;
            
            // Clear exceptions from old owner if it changed
            if (old_owner != NULL_KEY && old_owner != OwnerKey) {
                apply_tp_exception(old_owner, FALSE);
                apply_im_exception(old_owner, FALSE);
            }
            
            // Apply to new owner
            reconcile_all();
        }
    }
    else if (op == "list_add") {
        string key_name = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);
        if (key_name == JSON_INVALID || elem == JSON_INVALID) return;
        
        if (key_name == KEY_OWNER_KEYS) {
            if (llListFindList(OwnerKeys, [elem]) == -1) {
                OwnerKeys += [elem];
                
                // Apply exceptions to new owner
                key k = (key)elem;
                apply_tp_exception(k, ExOwnerTp);
                apply_im_exception(k, ExOwnerIm);
            }
        }
        else if (key_name == KEY_TRUSTEES) {
            if (llListFindList(TrusteeKeys, [elem]) == -1) {
                TrusteeKeys += [elem];
                
                // Apply exceptions to new trustee
                key k = (key)elem;
                apply_tp_exception(k, ExTrusteeTp);
                apply_im_exception(k, ExTrusteeIm);
            }
        }
    }
    else if (op == "list_remove") {
        string key_name = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);
        if (key_name == JSON_INVALID || elem == JSON_INVALID) return;
        
        if (key_name == KEY_OWNER_KEYS) {
            integer idx = llListFindList(OwnerKeys, [elem]);
            if (idx != -1) {
                // CRITICAL: Clear exceptions BEFORE removing from list
                key k = (key)elem;
                apply_tp_exception(k, FALSE);
                apply_im_exception(k, FALSE);
                
                // Remove from list
                OwnerKeys = llDeleteSubList(OwnerKeys, idx, idx);
            }
        }
        else if (key_name == KEY_TRUSTEES) {
            integer idx = llListFindList(TrusteeKeys, [elem]);
            if (idx != -1) {
                // CRITICAL: Clear exceptions BEFORE removing from list
                key k = (key)elem;
                apply_tp_exception(k, FALSE);
                apply_im_exception(k, FALSE);
                
                // Remove from list
                TrusteeKeys = llDeleteSubList(TrusteeKeys, idx, idx);
            }
        }
    }
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
    string avatar_str = llJsonGetValue(msg, ["avatar"]);
    string level_str = llJsonGetValue(msg, ["level"]);
    if (avatar_str == JSON_INVALID || level_str == JSON_INVALID) return;

    key avatar = (key)avatar_str;
    if (avatar != CurrentUser) return;

    UserAcl = (integer)level_str;
    
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
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
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
        string type = llJsonGetValue(msg, ["type"]);
        if (type == JSON_INVALID) return;
        
        if (num == KERNEL_LIFECYCLE) {
            if (type == "register_now") {
                register_self();
                // CRITICAL FIX: Re-request settings after kernel reset to reapply RLV exceptions
                llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
                    "type", "settings_get"
                ]), NULL_KEY);
            }
            else if (type == "ping") send_pong();
        }
        else if (num == SETTINGS_BUS) {
            if (type == "settings_sync") apply_settings_sync(msg);
            else if (type == "settings_delta") apply_settings_delta(msg);
        }
        else if (num == UI_BUS) {
            if (type == "start") {
                string context_val = llJsonGetValue(msg, ["context"]);
                if (context_val != JSON_INVALID && context_val == PLUGIN_CONTEXT) {
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
                string session_val = llJsonGetValue(msg, ["session_id"]);
                string button_val = llJsonGetValue(msg, ["button"]);
                if (session_val != JSON_INVALID && button_val != JSON_INVALID) {
                    if (session_val == SessionId) {
                        handle_button(button_val);
                    }
                }
            }
            else if (type == "dialog_timeout") {
                string session_val = llJsonGetValue(msg, ["session_id"]);
                if (session_val != JSON_INVALID) {
                    if (session_val == SessionId) cleanup();
                }
            }
        }
    }
}
