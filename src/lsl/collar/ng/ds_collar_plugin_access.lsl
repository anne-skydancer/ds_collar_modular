/*--------------------
PLUGIN: ds_collar_plugin_access.lsl
VERSION: 1.00
REVISION: 22
PURPOSE: Owner, trustee, and honorific management workflows
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Adds multi-owner mode with ordered lists and honorific metadata
- Guides owner transfer and release with dual confirmation dialogs
- Supports runaway self-release and trustee roster maintenance
- Synchronizes owner/trustee settings stores through settings bus
- Integrates ACL validation, name caching, and dialog-driven UI flows
--------------------*/


/* -------------------- ABI CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_owner";
string PLUGIN_LABEL = "Access";
integer PLUGIN_MIN_ACL = 2;

/* -------------------- CONSTANTS -------------------- */
integer MAX_NUMBERED_LIST_ITEMS = 11;  // 12 dialog buttons - 1 Back button

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE = "multi_owner_mode";
string KEY_OWNER_KEY = "owner_key";
string KEY_OWNER_KEYS = "owner_keys";
string KEY_OWNER_HON = "owner_hon";
string KEY_OWNER_HONS = "owner_honorifics";
string KEY_TRUSTEES = "trustees";
string KEY_TRUSTEE_HONS = "trustee_honorifics";
string KEY_RUNAWAY_ENABLED = "runaway_enabled";

/* -------------------- STATE -------------------- */
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

/* -------------------- HELPERS -------------------- */


integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string gen_session() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

integer has_owner() {
    if (MultiOwnerMode) return (llGetListLength(OwnerKeys) > 0);
    return (OwnerKey != NULL_KEY);
}

key get_primary_owner() {
    if (MultiOwnerMode && llGetListLength(OwnerKeys) > 0) {
        return (key)llList2String(OwnerKeys, 0);
    }
    return OwnerKey;
}

integer is_owner(key k) {
    if (MultiOwnerMode) return (llListFindList(OwnerKeys, [(string)k]) != -1);
    return (k == OwnerKey);
}

/* -------------------- NAMES -------------------- */

cache_name(key k, string n) {
    if (k == NULL_KEY || n == "" || n == "???") return;
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

string get_name(key k) {
    if (k == NULL_KEY) return "";
    integer idx = llListFindList(NameCache, [k]);
    if (idx != -1) return llList2String(NameCache, idx + 1);
    
    string n = llGetDisplayName(k);
    if (n != "" && n != "???") {
        cache_name(k, n);
        return n;
    }
    
    if (ActiveNameQuery == NULL_KEY) {
        ActiveNameQuery = llRequestDisplayName(k);
        ActiveQueryTarget = k;
    }
    
    return llKey2Name(k);
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
    if (!json_has(msg, ["kv"])) return;
    string kv = llJsonGetValue(msg, ["kv"]);
    
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    OwnerHonorific = "";
    OwnerHonorifics = [];
    TrusteeKeys = [];
    TrusteeHonorifics = [];
    
    if (json_has(kv, [KEY_MULTI_OWNER_MODE])) {
        MultiOwnerMode = (integer)llJsonGetValue(kv, [KEY_MULTI_OWNER_MODE]);
    }
    
    if (MultiOwnerMode) {
        if (json_has(kv, [KEY_OWNER_KEYS])) {
            string arr = llJsonGetValue(kv, [KEY_OWNER_KEYS]);
            if (llGetSubString(arr, 0, 0) == "[") OwnerKeys = llJson2List(arr);
        }
        if (json_has(kv, [KEY_OWNER_HONS])) {
            string arr = llJsonGetValue(kv, [KEY_OWNER_HONS]);
            if (llGetSubString(arr, 0, 0) == "[") OwnerHonorifics = llJson2List(arr);
        }
    }
    else {
        if (json_has(kv, [KEY_OWNER_KEY])) {
            OwnerKey = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
        }
        if (json_has(kv, [KEY_OWNER_HON])) {
            OwnerHonorific = llJsonGetValue(kv, [KEY_OWNER_HON]);
        }
    }
    
    if (json_has(kv, [KEY_TRUSTEES])) {
        string arr = llJsonGetValue(kv, [KEY_TRUSTEES]);
        if (llGetSubString(arr, 0, 0) == "[") TrusteeKeys = llJson2List(arr);
    }
    
    if (json_has(kv, [KEY_TRUSTEE_HONS])) {
        string arr = llJsonGetValue(kv, [KEY_TRUSTEE_HONS]);
        if (llGetSubString(arr, 0, 0) == "[") TrusteeHonorifics = llJson2List(arr);
    }
    
    if (json_has(kv, [KEY_RUNAWAY_ENABLED])) {
        RunawayEnabled = (integer)llJsonGetValue(kv, [KEY_RUNAWAY_ENABLED]);
    }
    else {
        RunawayEnabled = TRUE;
    }
}

apply_settings_delta(string msg) {
    if (!json_has(msg, ["op"])) return;
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (json_has(changes, [KEY_RUNAWAY_ENABLED])) {
            RunawayEnabled = (integer)llJsonGetValue(changes, [KEY_RUNAWAY_ENABLED]);
        }
    }
}


persist_owner(key owner, string hon) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_OWNER_KEY, "value", (string)owner
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set", "key", KEY_OWNER_HON, "value", hon
    ]), NULL_KEY);
}

add_trustee(key trustee, string hon) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "list_add", "key", KEY_TRUSTEES, "elem", (string)trustee
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "list_add", "key", KEY_TRUSTEE_HONS, "elem", hon
    ]), NULL_KEY);
}

remove_trustee(key trustee) {
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

clear_owner() {
    persist_owner(NULL_KEY, "");
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
    
    string body = "Owner Management\n\n";
    
    if (has_owner()) {
        if (MultiOwnerMode) {
            body += "Multi-owner: " + (string)llGetListLength(OwnerKeys) + "\n";
        }
        else {
            body += "Owner: " + get_name(OwnerKey);
            if (OwnerHonorific != "") body += " (" + OwnerHonorific + ")";
        }
    }
    else {
        body += "Unowned";
    }
    
    body += "\nTrustees: " + (string)llGetListLength(TrusteeKeys);
    
    list buttons = ["Back"];
    
    
    if (CurrentUser == llGetOwner()) {
        if (!has_owner()) buttons += ["Add Owner"];
        else if (RunawayEnabled && !MultiOwnerMode) buttons += ["Runaway"];
    }
    
    if (is_owner(CurrentUser)) {
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

show_candidates(string context, string title, string prompt) {
    if (llGetListLength(CandidateKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        show_main();
        return;
    }
    
    list names = [];
    integer i = 0;
    while (i < llGetListLength(CandidateKeys) && i < MAX_NUMBERED_LIST_ITEMS) {
        names += [get_name((key)llList2String(CandidateKeys, i))];
        i++;
    }
    
    SessionId = gen_session();
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

show_honorific(key target, string context) {
    PendingCandidate = target;
    SessionId = gen_session();
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

show_confirm(string title, string body, string context) {
    SessionId = gen_session();
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

show_remove_trustee() {
    if (llGetListLength(TrusteeKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No trustees.");
        show_main();
        return;
    }
    
    list names = [];
    integer i = 0;
    integer hon_len = llGetListLength(TrusteeHonorifics);
    while (i < llGetListLength(TrusteeKeys) && i < MAX_NUMBERED_LIST_ITEMS) {
        string name = get_name((key)llList2String(TrusteeKeys, i));
        if (i < hon_len) {
            name += " (" + llList2String(TrusteeHonorifics, i) + ")";
        }
        names += [name];
        i++;
    }
    
    SessionId = gen_session();
    MenuContext = "remove_trustee";
    
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

/* -------------------- BUTTON HANDLING -------------------- */

handle_button(string btn) {
    if (btn == "Back") {
        if (MenuContext == "main") {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "return", "user", (string)CurrentUser
            ]), NULL_KEY);
            cleanup();
        }
        else show_main();
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
            show_confirm("Confirm Release", "Release " + get_name(llGetOwner()) + "?", "release_owner");
        }
        else if (btn == "Runaway") {
            show_confirm("Confirm Runaway", "Run away from " + get_name(get_primary_owner()) + "?\n\nThis removes ownership without consent.", "runaway");
        }
        else if (btn == "Runaway: On" || btn == "Runaway: Off") {
            if (RunawayEnabled) {
                // Disabling requires wearer consent - send dialog to WEARER
                string hon = OwnerHonorific;
                if (hon == "") hon = "Owner";
                
                string msg_body = "Your " + hon + " wants to disable runaway for you.\n\nPlease confirm.";
                
                SessionId = gen_session();
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
                show_main();
            }
            return;
        }
        else if (btn == "Add Trustee") {
            MenuContext = "trustee_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, 10.0, PI);
        }
        else if (btn == "Rem Trustee") {
            show_remove_trustee();
        }
        return;
    }
    
    integer idx = (integer)btn - 1;
    
    if (MenuContext == "set_select") {
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            PendingCandidate = (key)llList2String(CandidateKeys, idx);
            SessionId = gen_session();
            MenuContext = "set_accept";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)PendingCandidate,
                "title", "Accept Ownership",
                "body", get_name(llGetOwner()) + " wishes to submit to you.\n\nAccept?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "set_accept") {
        if (btn == "Yes") show_honorific(PendingCandidate, "set_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            show_main();
        }
    }
    else if (MenuContext == "set_hon") {
        if (idx >= 0 && idx < 6) {
            PendingHonorific = llList2String(HONORIFICS, idx);
            SessionId = gen_session();
            MenuContext = "set_confirm";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)llGetOwner(),
                "title", "Confirm",
                "body", "Submit to " + get_name(PendingCandidate) + " as your " + PendingHonorific + "?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "set_confirm") {
        if (btn == "Yes") {
            persist_owner(PendingCandidate, PendingHonorific);
            llRegionSayTo(PendingCandidate, 0, get_name(llGetOwner()) + " has submitted to you as their " + PendingHonorific + ".");
            llRegionSayTo(llGetOwner(), 0, "You are now property of " + PendingHonorific + " " + get_name(PendingCandidate) + ".");
            cleanup();
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "return", "user", (string)CurrentUser
            ]), NULL_KEY);
        }
        else show_main();
    }
    else if (MenuContext == "transfer_select") {
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            PendingCandidate = (key)llList2String(CandidateKeys, idx);
            SessionId = gen_session();
            MenuContext = "transfer_accept";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)PendingCandidate,
                "title", "Accept Transfer",
                "body", "Accept ownership of " + get_name(llGetOwner()) + "?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "transfer_accept") {
        if (btn == "Yes") show_honorific(PendingCandidate, "transfer_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            show_main();
        }
    }
    else if (MenuContext == "transfer_hon") {
        if (idx >= 0 && idx < 6) {
            PendingHonorific = llList2String(HONORIFICS, idx);
            key old = OwnerKey;
            persist_owner(PendingCandidate, PendingHonorific);
            llRegionSayTo(old, 0, "You have transferred " + get_name(llGetOwner()) + " to " + get_name(PendingCandidate) + ".");
            llRegionSayTo(PendingCandidate, 0, get_name(llGetOwner()) + " is now your property as " + PendingHonorific + ".");
            llRegionSayTo(llGetOwner(), 0, "You are now property of " + PendingHonorific + " " + get_name(PendingCandidate) + ".");
            cleanup();
        }
    }
    else if (MenuContext == "release_owner") {
        if (btn == "Yes") {
            SessionId = gen_session();
            MenuContext = "release_wearer";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)llGetOwner(),
                "title", "Confirm Release",
                "body", "Released by " + get_name(CurrentUser) + ".\n\nConfirm freedom?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
        else show_main();
    }
    else if (MenuContext == "release_wearer") {
        if (btn == "Yes") {
            clear_owner();
            llRegionSayTo(llGetOwner(), 0, "Released. You are free.");
            cleanup();
        }
        else {
            llRegionSayTo(CurrentUser, 0, "Release cancelled.");
            cleanup();
        }
    }
    else if (MenuContext == "runaway") {
        if (btn == "Yes") {
            key old = get_primary_owner();
            string old_hon = OwnerHonorific;
            clear_owner();
            
            // Notify wearer with honorific and owner name
            if (old != NULL_KEY) {
                string msg = "You have run away from ";
                if (old_hon != "") msg += old_hon + " ";
                msg += get_name(old) + ".";
                llRegionSayTo(llGetOwner(), 0, msg);
                llRegionSayTo(old, 0, get_name(llGetOwner()) + " ran away.");
            }
            else {
                llRegionSayTo(llGetOwner(), 0, "You have run away.");
            }
            
            // Trigger soft_reset to reinitialize all plugins
            llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
                "type", "soft_reset"
            ]), NULL_KEY);
            
            cleanup();
        }
        else show_main();
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
            show_main();
        }
        else {
            // Wearer declined
            llRegionSayTo(llGetOwner(), 0, "You declined to disable runaway.");
            llRegionSayTo(CurrentUser, 0, get_name(llGetOwner()) + " declined to disable runaway.");
            show_main();
        }
    }
    else if (MenuContext == "trustee_select") {
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            PendingCandidate = (key)llList2String(CandidateKeys, idx);
            
            if (llListFindList(TrusteeKeys, [(string)PendingCandidate]) != -1) {
                llRegionSayTo(CurrentUser, 0, "Already trustee.");
                show_main();
                return;
            }
            
            SessionId = gen_session();
            MenuContext = "trustee_accept";
            
            llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                "type", "dialog_open",
                "session_id", SessionId,
                "user", (string)PendingCandidate,
                "title", "Accept Trustee",
                "body", get_name(llGetOwner()) + " wants you as trustee.\n\nAccept?",
                "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
                "timeout", 60
            ]), NULL_KEY);
        }
    }
    else if (MenuContext == "trustee_accept") {
        if (btn == "Yes") show_honorific(PendingCandidate, "trustee_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            show_main();
        }
    }
    else if (MenuContext == "trustee_hon") {
        if (idx >= 0 && idx < 6) {
            PendingHonorific = llList2String(HONORIFICS, idx);
            add_trustee(PendingCandidate, PendingHonorific);
            llRegionSayTo(PendingCandidate, 0, "You are trustee of " + get_name(llGetOwner()) + " as " + PendingHonorific + ".");
            llRegionSayTo(CurrentUser, 0, get_name(PendingCandidate) + " is trustee.");
            show_main();
        }
    }
    else if (MenuContext == "remove_trustee") {
        if (idx >= 0 && idx < llGetListLength(TrusteeKeys)) {
            key trustee = (key)llList2String(TrusteeKeys, idx);
            remove_trustee(trustee);
            llRegionSayTo(CurrentUser, 0, "Removed.");
            llRegionSayTo(trustee, 0, "Removed as trustee.");
            show_main();
        }
    }
    else show_main();
}

/* -------------------- CLEANUP -------------------- */

cleanup() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    SessionId = "";
    MenuContext = "";
    PendingCandidate = NULL_KEY;
    PendingHonorific = "";
    CandidateKeys = [];
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
            show_candidates("set_select", "Set Owner", "Choose owner:");
        }
        else if (MenuContext == "transfer_scan") {
            show_candidates("transfer_select", "Transfer", "Choose new owner:");
        }
        else if (MenuContext == "trustee_scan") {
            show_candidates("trustee_select", "Add Trustee", "Choose trustee:");
        }
    }
    
    no_sensor() {
        if (CurrentUser == NULL_KEY) return;
        CandidateKeys = [];
        
        if (MenuContext == "set_scan") {
            show_candidates("set_select", "Set Owner", "Choose owner:");
        }
        else if (MenuContext == "transfer_scan") {
            show_candidates("transfer_select", "Transfer", "Choose new owner:");
        }
        else if (MenuContext == "trustee_scan") {
            show_candidates("trustee_select", "Add Trustee", "Choose trustee:");
        }
    }
    
    dataserver(key qid, string data) {
        if (qid != ActiveNameQuery) return;
        if (data != "" && data != "???") cache_name(ActiveQueryTarget, data);
        ActiveNameQuery = NULL_KEY;
        ActiveQueryTarget = NULL_KEY;
    }
}
