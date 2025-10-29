/* ===============================================================
   PLUGIN: ds_collar_plugin_owner.lsl (v1.0 - Memory Optimized)
   
   PURPOSE: Owner and trustee management
   
   FEATURES:
   - Set owner with honorific selection
   - Transfer ownership
   - Release (dual confirmation)
   - Runaway (emergency self-release)
   - Trustee management
   
   TIER: 2 (Medium)
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
string PLUGIN_CONTEXT = "core_owner";
string PLUGIN_LABEL = "Access";
integer PLUGIN_MIN_ACL = 2;

/* ===============================================================
   SETTINGS KEYS
   =============================================================== */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_KEYS = "owner_keys";
string KEY_OWNER_HON = "owner_hon";
string KEY_OWNER_HONS = "owner_honorifics";
string KEY_TRUSTEES = "trustees";
string KEY_TRUSTEE_HONS = "trustee_honorifics";
string KEY_RUNAWAY_ENABLED = "runaway_enabled";

/* ===============================================================
   STATE
   =============================================================== */
integer MultiOwnerMode;
key OwnerKey;
list OwnerKeys;
string OwnerHonorific;
list OwnerHonorifics;
list TrusteeKeys;
integer RunawayEnabled = TRUE;
list TrusteeHonorifics;

key CurrentUser;
integer UserAcl = -999;
string SessionId;
string MenuContext;

key PendingCandidate;
string PendingHonorific;
list CandidateKeys;

list NameCache;
key ActiveNameQuery;
key ActiveQueryTarget;

list HONORIFICS = ["Master", "Mistress", "Daddy", "Mommy", "King", "Queen"];

/* ===============================================================
   HELPERS
   =============================================================== */

integer logd(string msg) {
    if (DEBUG) llOwnerSay("[" + PLUGIN_LABEL + "] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string genSession() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

integer hasOwner() {
    if (MultiOwnerMode) return (llGetListLength(OwnerKeys) > 0);
    return (OwnerKey != NULL_KEY);
}

key getPrimaryOwner() {
    if (MultiOwnerMode && llGetListLength(OwnerKeys) > 0) {
        return (key)llList2String(OwnerKeys, 0);
    }
    return OwnerKey;
}

integer isOwner(key k) {
    if (MultiOwnerMode) return (llListFindList(OwnerKeys, [(string)k]) != -1);
    return (k == OwnerKey);
}

/* ===============================================================
   NAMES
   =============================================================== */

cacheName(key k, string n) {
    if (k == NULL_KEY || n == "" || n == " ") return;
    integer idx = llListFindList(NameCache, [k]);
    if (idx != -1) {
        NameCache = llListReplaceList(NameCache, [n], idx + 1, idx + 1);
    }
    else {
        NameCache += [k, n];
        if (llGetListLength(NameCache) > 20) {
            NameCache = llDeleteSubList(NameCache, 0, 1);
        }
    }
}

string getName(key k) {
    if (k == NULL_KEY) return "";
    integer idx = llListFindList(NameCache, [k]);
    if (idx != -1) return llList2String(NameCache, idx + 1);
    
    string n = llGetDisplayName(k);
    if (n != "" && n != " ") {
        cacheName(k, n);
        return n;
    }
    
    if (ActiveNameQuery == NULL_KEY) {
        ActiveNameQuery = llRequestDisplayName(k);
        ActiveQueryTarget = k;
    }
    
    return llKey2Name(k);
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
    
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    OwnerHonorific = "";
    OwnerHonorifics = [];
    TrusteeKeys = [];
    TrusteeHonorifics = [];
    
    if (jsonHas(kv, [KEY_MULTI_OWNER_MODE])) {
        MultiOwnerMode = (integer)llJsonGetValue(kv, [KEY_MULTI_OWNER_MODE]);
    }
    
    if (MultiOwnerMode) {
        if (jsonHas(kv, [KEY_OWNER_KEYS])) {
            string arr = llJsonGetValue(kv, [KEY_OWNER_KEYS]);
            if (llGetSubString(arr, 0, 0) == "[") OwnerKeys = llJson2List(arr);
        }
        if (jsonHas(kv, [KEY_OWNER_HONS])) {
            string arr = llJsonGetValue(kv, [KEY_OWNER_HONS]);
            if (llGetSubString(arr, 0, 0) == "[") OwnerHonorifics = llJson2List(arr);
        }
    }
    else {
        if (jsonHas(kv, [KEY_OWNER_KEY])) {
            OwnerKey = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
        }
        if (jsonHas(kv, [KEY_OWNER_HON])) {
            OwnerHonorific = llJsonGetValue(kv, [KEY_OWNER_HON]);
        }
    }
    
    if (jsonHas(kv, [KEY_TRUSTEES])) {
        string arr = llJsonGetValue(kv, [KEY_TRUSTEES]);
        if (llGetSubString(arr, 0, 0) == "[") TrusteeKeys = llJson2List(arr);
    }
    
    if (jsonHas(kv, [KEY_TRUSTEE_HONS])) {
        string arr = llJsonGetValue(kv, [KEY_TRUSTEE_HONS]);
        if (llGetSubString(arr, 0, 0) == "[") TrusteeHonorifics = llJson2List(arr);
    }
    
    if (jsonHas(kv, [KEY_RUNAWAY_ENABLED])) {
        RunawayEnabled = (integer)llJsonGetValue(kv, [KEY_RUNAWAY_ENABLED]);
    }
    else {
        RunawayEnabled = TRUE;
    }
}

applySettingsDelta(string msg) {
    if (!jsonHas(msg, ["op"])) return;
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!jsonHas(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (jsonHas(changes, [KEY_RUNAWAY_ENABLED])) {
            RunawayEnabled = (integer)llJsonGetValue(changes, [KEY_RUNAWAY_ENABLED]);
            logd("Delta: runaway_enabled = " + (string)RunawayEnabled);
        }
    }
}


persistOwner(key owner, string hon) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_OWNER_KEY, "value", (string)owner
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_OWNER_HON, "value", hon
    ]), NULL_KEY);
}

addTrustee(key trustee, string hon) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "list_add", "key", KEY_TRUSTEES, "elem", (string)trustee
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "list_add", "key", KEY_TRUSTEE_HONS, "elem", hon
    ]), NULL_KEY);
}

removeTrustee(key trustee) {
    integer idx = llListFindList(TrusteeKeys, [(string)trustee]);
    if (idx == -1) return;
    
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "list_remove", "key", KEY_TRUSTEES, "elem", (string)trustee
    ]), NULL_KEY);
    
    if (idx < llGetListLength(TrusteeHonorifics)) {
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "list_remove", "key", KEY_TRUSTEE_HONS, "elem", llList2String(TrusteeHonorifics, idx)
        ]), NULL_KEY);
    }
}

clearOwner() {
    persistOwner(NULL_KEY, "");
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
    
    string body = "Owner Management\n\n";
    
    if (hasOwner()) {
        if (MultiOwnerMode) {
            body += "Multi-owner: " + (string)llGetListLength(OwnerKeys) + "\n";
        }
        else {
            body += "Owner: " + getName(OwnerKey);
            if (OwnerHonorific != "") body += " (" + OwnerHonorific + ")";
        }
    }
    else {
        body += "Unowned";
    }
    
    body += "\nTrustees: " + (string)llGetListLength(TrusteeKeys);
    
    list buttons = ["Back"];
    
    
    if (CurrentUser == llGetOwner()) {
        if (!hasOwner()) buttons += ["Add Owner"];
        else if (RunawayEnabled && !MultiOwnerMode) buttons += ["Runaway"];
    }
    
    if (isOwner(CurrentUser)) {
        if (!MultiOwnerMode) buttons += ["Transfer"];
        buttons += ["Release"];
        
        // Runaway toggle (owner only)
        if (RunawayEnabled) {
            buttons += ["Runaway: On"];
        }
        else {
            buttons += ["Runaway: Off"];
        }
    }
    
    if (UserAcl == 5 || UserAcl == 4) {
        buttons += ["Add Trustee", "Rem Trustee"];
    }
    
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

showCandidates(string context, string title, string prompt) {
    if (llGetListLength(CandidateKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        showMain();
        return;
    }
    
    list names = [];
    integer i;
    integer len = llGetListLength(CandidateKeys);
    while (i < len && i < 11) {
        names += [getName((key)llList2String(CandidateKeys, i))];
        i++;
    }
    
    SessionId = genSession();
    MenuContext = context;
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "prompt", prompt,
        "items", llList2Json(JSON_ARRAY, names),
        "timeout", 60
    ]), NULL_KEY);
}

showHonorific(key target, string context) {
    PendingCandidate = target;
    SessionId = genSession();
    MenuContext = context;
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)target,
        "title", "Honorific",
        "prompt", "What would you like to be called?",
        "items", llList2Json(JSON_ARRAY, HONORIFICS),
        "timeout", 60
    ]), NULL_KEY);
}

showConfirm(string title, string body, string context) {
    SessionId = genSession();
    MenuContext = context;
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "body", body,
        "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
        "timeout", 60
    ]), NULL_KEY);
}

showRemoveTrustee() {
    if (llGetListLength(TrusteeKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No trustees.");
        showMain();
        return;
    }
    
    list names = [];
    integer i;
    integer len = llGetListLength(TrusteeKeys);
    while (i < len && i < 11) {
        string name = getName((key)llList2String(TrusteeKeys, i));
        if (i < llGetListLength(TrusteeHonorifics)) {
            name += " (" + llList2String(TrusteeHonorifics, i) + ")";
        }
        names += [name];
        i++;
    }
    
    SessionId = genSession();
    MenuContext = "removeTrustee";
    
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Remove Trustee",
        "prompt", "Select to remove:",
        "items", llList2Json(JSON_ARRAY, names),
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
        else showMain();
        return;
    }
    
    if (MenuContext == "main") {
        if (btn == "Add Owner") {
            MenuContext = "set_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, 10.0, PI);
        }
        else if (btn == "Transfer") {
            MenuContext = "transfer_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, 10.0, PI);
        }
        else if (btn == "Release") {
            showConfirm("Confirm Release", "Release " + getName(llGetOwner()) + "?", "release_owner");
        }
        else if (btn == "Runaway") {
            showConfirm("Confirm Runaway", "Run away from " + getName(getPrimaryOwner()) + "?\n\nThis removes ownership without consent.", "runaway");
        }
        else if (btn == "Runaway: On" || btn == "Runaway: Off") {
            if (RunawayEnabled) {
                // Disabling requires wearer consent - send dialog to WEARER
                string hon = OwnerHonorific;
                if (hon == "") hon = "Owner";
                
                string msg_body = "Your " + hon + " wants to disable runaway for you.\n\nPlease confirm.";
                
                SessionId = genSession();
                MenuContext = "runaway_disable_confirm";
                
                llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                    "type", "dialog_open",
                    "session_id", SessionId,
                    "user", (string)llGetOwner(),  // Send to WEARER, not CurrentUser
                    "title", "Disable Runaway",
                    "body", msg_body,
                    "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                    "timeout", 60
                ]), NULL_KEY);
            }
            else {
                // Enabling is direct (no consent needed)
                RunawayEnabled = TRUE;
                
                llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
                    "type", "set",
                    "key", KEY_RUNAWAY_ENABLED,
                    "value", "1"
                ]), NULL_KEY);
                
                llRegionSayTo(CurrentUser, 0, "Runaway enabled.");
                showMain();
            }
            return;
        }
        else if (btn == "Add Trustee") {
            MenuContext = "trustee_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, 10.0, PI);
        }
        else if (btn == "Rem Trustee") {
            showRemoveTrustee();
        }
        return;
    }
    
    integer idx = (integer)btn - 1;
    
    if (MenuContext == "set_select") {
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            PendingCandidate = (key)llList2String(CandidateKeys, idx);
            SessionId = genSession();
            MenuContext = "set_accept";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)PendingCandidate,
                "title", "Accept Ownership",
                "body", getName(llGetOwner()) + " wishes to submit to you.\n\nAccept?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "set_accept") {
        if (btn == "Yes") showHonorific(PendingCandidate, "set_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            showMain();
        }
    }
    else if (MenuContext == "set_hon") {
        if (idx >= 0 && idx < 6) {
            PendingHonorific = llList2String(HONORIFICS, idx);
            SessionId = genSession();
            MenuContext = "set_confirm";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)llGetOwner(),
                "title", "Confirm",
                "body", "Submit to " + getName(PendingCandidate) + " as your " + PendingHonorific + "?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "set_confirm") {
        if (btn == "Yes") {
            persistOwner(PendingCandidate, PendingHonorific);
            llRegionSayTo(PendingCandidate, 0, getName(llGetOwner()) + " has submitted to you as their " + PendingHonorific + ".");
            llRegionSayTo(llGetOwner(), 0, "You are now property of " + PendingHonorific + " " + getName(PendingCandidate) + ".");
            cleanupSession();
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "return", "user", (string)CurrentUser
            ]), NULL_KEY);
        }
        else showMain();
    }
    else if (MenuContext == "transfer_select") {
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            PendingCandidate = (key)llList2String(CandidateKeys, idx);
            SessionId = genSession();
            MenuContext = "transfer_accept";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)PendingCandidate,
                "title", "Accept Transfer",
                "body", "Accept ownership of " + getName(llGetOwner()) + "?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "transfer_accept") {
        if (btn == "Yes") showHonorific(PendingCandidate, "transfer_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            showMain();
        }
    }
    else if (MenuContext == "transfer_hon") {
        if (idx >= 0 && idx < 6) {
            PendingHonorific = llList2String(HONORIFICS, idx);
            key old = OwnerKey;
            persistOwner(PendingCandidate, PendingHonorific);
            llRegionSayTo(old, 0, "You have transferred " + getName(llGetOwner()) + " to " + getName(PendingCandidate) + ".");
            llRegionSayTo(PendingCandidate, 0, getName(llGetOwner()) + " is now your property as " + PendingHonorific + ".");
            llRegionSayTo(llGetOwner(), 0, "You are now property of " + PendingHonorific + " " + getName(PendingCandidate) + ".");
            cleanupSession();
        }
    }
    else if (MenuContext == "release_owner") {
        if (btn == "Yes") {
            SessionId = genSession();
            MenuContext = "release_wearer";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)llGetOwner(),
                "title", "Confirm Release",
                "body", "Released by " + getName(CurrentUser) + ".\n\nConfirm freedom?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
        else showMain();
    }
    else if (MenuContext == "release_wearer") {
        if (btn == "Yes") {
            clearOwner();
            llRegionSayTo(llGetOwner(), 0, "Released. You are free.");
            cleanupSession();
        }
        else {
            llRegionSayTo(CurrentUser, 0, "Release cancelled.");
            cleanupSession();
        }
    }
    else if (MenuContext == "runaway") {
        if (btn == "Yes") {
            key old = getPrimaryOwner();
            string old_hon = OwnerHonorific;
            clearOwner();
            
            // Notify wearer with honorific and owner name
            if (old != NULL_KEY) {
                string msg = "You have run away from ";
                if (old_hon != "") msg += old_hon + " ";
                msg += getName(old) + ".";
                llRegionSayTo(llGetOwner(), 0, msg);
                llRegionSayTo(old, 0, getName(llGetOwner()) + " ran away.");
            }
            else {
                llRegionSayTo(llGetOwner(), 0, "You have run away.");
            }
            
            // Trigger soft_reset to reinitialize all plugins
            llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
                "type", "soft_reset"
            ]), NULL_KEY);
            
            cleanupSession();
        }
        else showMain();
    }
    else if (MenuContext == "runaway_disable_confirm") {
        if (btn == "Yes") {
            // Wearer consented - disable runaway
            RunawayEnabled = FALSE;
            
            llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
                "type", "set",
                "key", KEY_RUNAWAY_ENABLED,
                "value", "0"
            ]), NULL_KEY);
            
            llRegionSayTo(llGetOwner(), 0, "Runaway disabled.");
            llRegionSayTo(CurrentUser, 0, "Runaway disabled.");
            showMain();
        }
        else {
            // Wearer declined
            llRegionSayTo(llGetOwner(), 0, "You declined to disable runaway.");
            llRegionSayTo(CurrentUser, 0, getName(llGetOwner()) + " declined to disable runaway.");
            showMain();
        }
    }
    else if (MenuContext == "trustee_select") {
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            PendingCandidate = (key)llList2String(CandidateKeys, idx);
            
            if (llListFindList(TrusteeKeys, [(string)PendingCandidate]) != -1) {
                llRegionSayTo(CurrentUser, 0, "Already trustee.");
                showMain();
                return;
            }
            
            SessionId = genSession();
            MenuContext = "trustee_accept";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)PendingCandidate,
                "title", "Accept Trustee",
                "body", getName(llGetOwner()) + " wants you as trustee.\n\nAccept?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "trustee_accept") {
        if (btn == "Yes") showHonorific(PendingCandidate, "trustee_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            showMain();
        }
    }
    else if (MenuContext == "trustee_hon") {
        if (idx >= 0 && idx < 6) {
            PendingHonorific = llList2String(HONORIFICS, idx);
            addTrustee(PendingCandidate, PendingHonorific);
            llRegionSayTo(PendingCandidate, 0, "You are trustee of " + getName(llGetOwner()) + " as " + PendingHonorific + ".");
            llRegionSayTo(CurrentUser, 0, getName(PendingCandidate) + " is trustee.");
            showMain();
        }
    }
    else if (MenuContext == "removeTrustee") {
        if (idx >= 0 && idx < llGetListLength(TrusteeKeys)) {
            key trustee = (key)llList2String(TrusteeKeys, idx);
            removeTrustee(trustee);
            llRegionSayTo(CurrentUser, 0, "Removed.");
            llRegionSayTo(trustee, 0, "Removed as trustee.");
            showMain();
        }
    }
    else showMain();
}

/* ===============================================================
   CLEANUP
   =============================================================== */

cleanupSession() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    SessionId = "";
    MenuContext = "";
    PendingCandidate = NULL_KEY;
    PendingHonorific = "";
    CandidateKeys = [];
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
    
    sensor(integer count) {
        if (CurrentUser == NULL_KEY) return;
        
        list candidates = [];
        key wearer = llGetOwner();
        integer i;
        
        while (i < count) {
            key k = llDetectedKey(i);
            if (k != wearer) candidates += [(string)k];
            i++;
        }
        
        CandidateKeys = candidates;
        
        if (MenuContext == "set_scan") {
            showCandidates("set_select", "Set Owner", "Choose owner:");
        }
        else if (MenuContext == "transfer_scan") {
            showCandidates("transfer_select", "Transfer", "Choose new owner:");
        }
        else if (MenuContext == "trustee_scan") {
            showCandidates("trustee_select", "Add Trustee", "Choose trustee:");
        }
    }
    
    no_sensor() {
        if (CurrentUser == NULL_KEY) return;
        CandidateKeys = [];
        
        if (MenuContext == "set_scan") {
            showCandidates("set_select", "Set Owner", "Choose owner:");
        }
        else if (MenuContext == "transfer_scan") {
            showCandidates("transfer_select", "Transfer", "Choose new owner:");
        }
        else if (MenuContext == "trustee_scan") {
            showCandidates("trustee_select", "Add Trustee", "Choose trustee:");
        }
    }
    
    dataserver(key qid, string data) {
        if (qid != ActiveNameQuery) return;
        if (data != "" && data != " ") cacheName(ActiveQueryTarget, data);
        ActiveNameQuery = NULL_KEY;
        ActiveQueryTarget = NULL_KEY;
    }
}
