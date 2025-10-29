/* ===============================================================
   PLUGIN: ds_collar_plugin_rlvexceptions.lsl (v1.0 - Memory Optimized)
   
   PURPOSE: RLV exception management for owners and trustees
   
   FEATURES:
   - Owner TP exceptions (@accepttp, @tplure)
   - Owner IM exceptions (@sendim, @recvim)
   - Trustee TP exceptions
   - Trustee IM exceptions
   - Multi-owner mode support
   - Real-time RLV command application
   
   BUG FIX: Properly clears exceptions when owners/trustees are removed
   
   TIER: 2 (Medium - RLV command management)
   =============================================================== */

integer DEBUG = FALSE;

/* ===============================================================
   ABI CHANNELS
   =============================================================== */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ===============================================================
   IDENTITY
   =============================================================== */
string PLUGIN_CONTEXT = "core_rlv_exceptions";
string PLUGIN_LABEL = "Exceptions";
integer PLUGIN_MIN_ACL = 3;

/* ===============================================================
   SETTINGS KEYS
   =============================================================== */
string KEY_EX_OWNER_TP = "ex_owner_tp";
string KEY_EX_OWNER_IM = "ex_owner_im";
string KEY_EX_TRUSTEE_TP = "ex_trustee_tp";
string KEY_EX_TRUSTEE_IM = "ex_trustee_im";
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_KEYS = "owner_keys";
string KEY_TRUSTEES = "trustees";
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";

/* ===============================================================
   STATE
   =============================================================== */
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

/* ===============================================================
   HELPERS
   =============================================================== */

logd(string msg) {
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] " + msg);
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string genSession() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* ===============================================================
   RLV COMMANDS
   =============================================================== */

applyTpException(key k, integer allow) {
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

applyImException(key k, integer allow) {
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

reconcileAll() {
    logd("Reconciling RLV exceptions");
    
    // Owner exceptions
    if (MultiOwnerMode) {
        integer i;
        integer len = llGetListLength(OwnerKeys);
        while (i < len) {
            key k = (key)llList2String(OwnerKeys, i);
            applyTpException(k, ExOwnerTp);
            applyImException(k, ExOwnerIm);
            i++;
        }
    }
    else {
        applyTpException(OwnerKey, ExOwnerTp);
        applyImException(OwnerKey, ExOwnerIm);
    }
    
    // Trustee exceptions
    integer i;
    integer len = llGetListLength(TrusteeKeys);
    while (i < len) {
        key k = (key)llList2String(TrusteeKeys, i);
        applyTpException(k, ExTrusteeTp);
        applyImException(k, ExTrusteeIm);
        i++;
    }
}

/* ===============================================================
   LIFECYCLE
   =============================================================== */

registerSelf() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

sendPong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* ===============================================================
   SETTINGS
   =============================================================== */

applySettingsSync(string msg) {
    if (!jsonHas(msg, ["kv"])) return;
    string kv = llJsonGetValue(msg, ["kv"]);
    
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
    if (jsonHas(kv, [KEY_EX_OWNER_TP])) {
        ExOwnerTp = (integer)llJsonGetValue(kv, [KEY_EX_OWNER_TP]);
    }
    if (jsonHas(kv, [KEY_EX_OWNER_IM])) {
        ExOwnerIm = (integer)llJsonGetValue(kv, [KEY_EX_OWNER_IM]);
    }
    if (jsonHas(kv, [KEY_EX_TRUSTEE_TP])) {
        ExTrusteeTp = (integer)llJsonGetValue(kv, [KEY_EX_TRUSTEE_TP]);
    }
    if (jsonHas(kv, [KEY_EX_TRUSTEE_IM])) {
        ExTrusteeIm = (integer)llJsonGetValue(kv, [KEY_EX_TRUSTEE_IM]);
    }
    
    // Load owner/trustee lists
    if (jsonHas(kv, [KEY_MULTI_OWNER_MODE])) {
        MultiOwnerMode = (integer)llJsonGetValue(kv, [KEY_MULTI_OWNER_MODE]);
    }
    
    if (MultiOwnerMode) {
        if (jsonHas(kv, [KEY_OWNER_KEYS])) {
            string arr = llJsonGetValue(kv, [KEY_OWNER_KEYS]);
            if (llGetSubString(arr, 0, 0) == "[") OwnerKeys = llJson2List(arr);
        }
    }
    else {
        if (jsonHas(kv, [KEY_OWNER_KEY])) {
            OwnerKey = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
        }
    }
    
    if (jsonHas(kv, [KEY_TRUSTEES])) {
        string arr = llJsonGetValue(kv, [KEY_TRUSTEES]);
        if (llGetSubString(arr, 0, 0) == "[") TrusteeKeys = llJson2List(arr);
    }
    
    // Apply RLV commands
    reconcileAll();
    
    logd("Settings applied");
}

applySettingsDelta(string msg) {
    if (!jsonHas(msg, ["op"])) return;
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!jsonHas(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (jsonHas(changes, [KEY_EX_OWNER_TP])) {
            ExOwnerTp = (integer)llJsonGetValue(changes, [KEY_EX_OWNER_TP]);
            reconcileAll();
        }
        if (jsonHas(changes, [KEY_EX_OWNER_IM])) {
            ExOwnerIm = (integer)llJsonGetValue(changes, [KEY_EX_OWNER_IM]);
            reconcileAll();
        }
        if (jsonHas(changes, [KEY_EX_TRUSTEE_TP])) {
            ExTrusteeTp = (integer)llJsonGetValue(changes, [KEY_EX_TRUSTEE_TP]);
            reconcileAll();
        }
        if (jsonHas(changes, [KEY_EX_TRUSTEE_IM])) {
            ExTrusteeIm = (integer)llJsonGetValue(changes, [KEY_EX_TRUSTEE_IM]);
            reconcileAll();
        }
        
        // Handle owner_key changes (single owner mode)
        if (jsonHas(changes, [KEY_OWNER_KEY])) {
            key old_owner = OwnerKey;
            OwnerKey = (key)llJsonGetValue(changes, [KEY_OWNER_KEY]);
            
            // Clear exceptions from old owner if it changed
            if (old_owner != NULL_KEY && old_owner != OwnerKey) {
                applyTpException(old_owner, FALSE);
                applyImException(old_owner, FALSE);
                logd("Cleared exceptions for removed owner: " + (string)old_owner);
            }
            
            // Apply to new owner
            reconcileAll();
        }
    }
    else if (op == "list_add") {
        if (!jsonHas(msg, ["key"])) return;
        if (!jsonHas(msg, ["elem"])) return;
        
        string key_name = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);
        
        if (key_name == KEY_OWNER_KEYS) {
            if (llListFindList(OwnerKeys, [elem]) == -1) {
                OwnerKeys += [elem];
                logd("Added owner: " + elem);
                
                // Apply exceptions to new owner
                key k = (key)elem;
                applyTpException(k, ExOwnerTp);
                applyImException(k, ExOwnerIm);
            }
        }
        else if (key_name == KEY_TRUSTEES) {
            if (llListFindList(TrusteeKeys, [elem]) == -1) {
                TrusteeKeys += [elem];
                logd("Added trustee: " + elem);
                
                // Apply exceptions to new trustee
                key k = (key)elem;
                applyTpException(k, ExTrusteeTp);
                applyImException(k, ExTrusteeIm);
            }
        }
    }
    else if (op == "list_remove") {
        if (!jsonHas(msg, ["key"])) return;
        if (!jsonHas(msg, ["elem"])) return;
        
        string key_name = llJsonGetValue(msg, ["key"]);
        string elem = llJsonGetValue(msg, ["elem"]);
        
        if (key_name == KEY_OWNER_KEYS) {
            integer idx = llListFindList(OwnerKeys, [elem]);
            if (idx != -1) {
                // CRITICAL: Clear exceptions BEFORE removing from list
                key k = (key)elem;
                applyTpException(k, FALSE);
                applyImException(k, FALSE);
                logd("Cleared exceptions for removed owner: " + elem);
                
                // Remove from list
                OwnerKeys = llDeleteSubList(OwnerKeys, idx, idx);
            }
        }
        else if (key_name == KEY_TRUSTEES) {
            integer idx = llListFindList(TrusteeKeys, [elem]);
            if (idx != -1) {
                // CRITICAL: Clear exceptions BEFORE removing from list
                key k = (key)elem;
                applyTpException(k, FALSE);
                applyImException(k, FALSE);
                logd("Cleared exceptions for removed trustee: " + elem);
                
                // Remove from list
                TrusteeKeys = llDeleteSubList(TrusteeKeys, idx, idx);
            }
        }
    }
}

persistSetting(string setting_key, integer value) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", setting_key,
        "value", (string)value
    ]), NULL_KEY);
}

/* ===============================================================
   ACL
   =============================================================== */

requestAcl(key user) {
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_acl"
    ]), NULL_KEY);
}

handleAclResult(string msg) {
    if (!jsonHas(msg, ["avatar"]) || !jsonHas(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    UserAcl = (integer)llJsonGetValue(msg, ["level"]);
    
    if (UserAcl < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanupSession();
        return;
    }
    
    showMain();
}

/* ===============================================================
   MENUS
   =============================================================== */

showMain() {
    SessionId = genSession();
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

showOwnerMenu() {
    SessionId = genSession();
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

showTrusteeMenu() {
    SessionId = genSession();
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

showToggle(string role, string exception_type, string setting_key, integer current) {
    SessionId = genSession();
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

/* ===============================================================
   BUTTON HANDLING
   =============================================================== */

handleButton(string btn) {
    if (btn == "Back") {
        if (MenuContext == "main") {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "return", "user", (string)CurrentUser
            ]), NULL_KEY);
            cleanupSession();
        }
        else if (MenuContext == "owner" || MenuContext == "trustee") {
            showMain();
        }
        else {
            if (llSubStringIndex(MenuContext, "owner") == 0) showOwnerMenu();
            else if (llSubStringIndex(MenuContext, "trustee") == 0) showTrusteeMenu();
            else showMain();
        }
        return;
    }
    
    if (MenuContext == "main") {
        if (btn == "Owner") showOwnerMenu();
        else if (btn == "Trustee") showTrusteeMenu();
    }
    else if (MenuContext == "owner") {
        if (btn == "TP") showToggle("Owner", "TP", KEY_EX_OWNER_TP, ExOwnerTp);
        else if (btn == "IM") showToggle("Owner", "IM", KEY_EX_OWNER_IM, ExOwnerIm);
    }
    else if (MenuContext == "trustee") {
        if (btn == "TP") showToggle("Trustee", "TP", KEY_EX_TRUSTEE_TP, ExTrusteeTp);
        else if (btn == "IM") showToggle("Trustee", "IM", KEY_EX_TRUSTEE_IM, ExTrusteeIm);
    }
    else if (MenuContext == "owner_TP") {
        if (btn == "Allow") {
            persistSetting(KEY_EX_OWNER_TP, TRUE);
            llRegionSayTo(CurrentUser, 0, "Owner TP exception allowed.");
        }
        else if (btn == "Deny") {
            persistSetting(KEY_EX_OWNER_TP, FALSE);
            llRegionSayTo(CurrentUser, 0, "Owner TP exception denied.");
        }
        showOwnerMenu();
    }
    else if (MenuContext == "owner_IM") {
        if (btn == "Allow") {
            persistSetting(KEY_EX_OWNER_IM, TRUE);
            llRegionSayTo(CurrentUser, 0, "Owner IM exception allowed.");
        }
        else if (btn == "Deny") {
            persistSetting(KEY_EX_OWNER_IM, FALSE);
            llRegionSayTo(CurrentUser, 0, "Owner IM exception denied.");
        }
        showOwnerMenu();
    }
    else if (MenuContext == "trustee_TP") {
        if (btn == "Allow") {
            persistSetting(KEY_EX_TRUSTEE_TP, TRUE);
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception allowed.");
        }
        else if (btn == "Deny") {
            persistSetting(KEY_EX_TRUSTEE_TP, FALSE);
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception denied.");
        }
        showTrusteeMenu();
    }
    else if (MenuContext == "trustee_IM") {
        if (btn == "Allow") {
            persistSetting(KEY_EX_TRUSTEE_IM, TRUE);
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception allowed.");
        }
        else if (btn == "Deny") {
            persistSetting(KEY_EX_TRUSTEE_IM, FALSE);
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception denied.");
        }
        showTrusteeMenu();
    }
}

/* ===============================================================
   CLEANUP
   =============================================================== */

cleanupSessionSession() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    SessionId = "";
    MenuContext = "";
}

/* ===============================================================
   EVENTS
   =============================================================== */

default {
    state_entry() {
        cleanupSession();
        registerSelf();
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
        if (!jsonHas(msg, ["type"])) return;
        string type = llJsonGetValue(msg, ["type"]);
        
        if (num == KERNEL_LIFECYCLE) {
            if (type == "register_now") registerSelf();
            else if (type == "ping") sendPong();
        }
        else if (num == SETTINGS_BUS) {
            if (type == "settings_sync") applySettingsSync(msg);
            else if (type == "settings_delta") applySettingsDelta(msg);
        }
        else if (num == UI_BUS) {
            if (type == "start" && jsonHas(msg, ["context"])) {
                if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    CurrentUser = id;
                    requestAcl(id);
                }
            }
        }
        else if (num == AUTH_BUS) {
            if (type == "acl_result") handleAclResult(msg);
        }
        else if (num == DIALOG_BUS) {
            if (type == "dialog_response") {
                if (jsonHas(msg, ["session_id"]) && jsonHas(msg, ["button"])) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) {
                        handleButton(llJsonGetValue(msg, ["button"]));
                    }
                }
            }
            else if (type == "dialog_timeout") {
                if (jsonHas(msg, ["session_id"])) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) cleanupSession();
                }
            }
        }
    }
}
