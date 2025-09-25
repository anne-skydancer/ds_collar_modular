/* =============================================================
   PLUGIN: ds_collar_plugin_owner.lsl  (New Kernel ABI, JSON)
   ROLE  : Owner Control & Management + RLVa accepttp sync
   DATE  : 2025-09-16 (patched)
   NOTES :
     - Restores @accepttp:<ownerUUID>=add on set/transfer;
       removes on release/runaway; reconciles on settings sync.
     - AUTH-gated open; safe listeners; UI Back → main menu.
     - Heartbeat-friendly (kernel PING/PONG).
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Link numbers (kernel ABI) ---------- */
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

/* ---------- Magic words (protocol strings) ---------- */
string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_REGISTER_NOW      = "register_now";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";

string CONS_MSG_ACL_QUERY          = "acl_query";
string CONS_MSG_ACL_RESULT         = "acl_result";

/* Settings protocol (JSON) */
string CONS_SETTINGS_SYNC          = "settings_sync";   // inbound/outbound
string CONS_SETTINGS_SET           = "set";
string CONS_SETTINGS_NS_OWNER      = "owner";           // namespace/key for this module
string KEY_OWNER_KEY               = "owner_key";
string KEY_OWNER_LEGACY            = "owner";
string KEY_OWNER_HON               = "owner_hon";
string KEY_TRUSTEES                = "trustees";
string KEY_TRUSTEE_HONS            = "trustee_honorifics";
string KEY_PUBLIC_MODE             = "public_mode";
string KEY_LOCKED_FLAG             = "locked";

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT   = "core_owner";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Owner";
integer PLUGIN_SN        = 0;

/* ---------- ACL levels ---------- */
integer ACL_BLACKLIST        = -1;
integer ACL_NOACCESS         = 0;
integer ACL_PUBLIC           = 1;
integer ACL_OWNED            = 2;   // wearer while owned
integer ACL_TRUSTEE          = 3;
integer ACL_UNOWNED          = 4;   // wearer while unowned
integer ACL_PRIMARY_OWNER    = 5;

/* Who can OPEN the plugin menu */
list ALLOWED_ACL_LEVELS = [ACL_OWNED, ACL_UNOWNED, ACL_PRIMARY_OWNER];

/* ---------- UI/session ---------- */
integer DIALOG_TIMEOUT_SEC = 180;
key     User             = NULL_KEY;  // who opened plugin
integer Listen           = 0;
integer MenuChan        = 0;

/* Gate state */
integer AclPending = FALSE;
integer AclLevel   = ACL_NOACCESS;

/* ---------- Owner/state mirror ---------- */
key     CollarOwner            = NULL_KEY;
string  CollarOwnerHonorific  = "";
integer CollarLocked           = FALSE;
integer CollarPublicAccess    = FALSE;
list    CollarTrustees         = [];
list    CollarTrusteeHonorifics = [];

/* ---------- RLVa auto-accept TP state ---------- */
key RlvAccepttpOwner = NULL_KEY;

/* ---------- Flow/session state ---------- */
string UiContext = "";  // "", "menu", "add_owner_select", "add_owner_hon", "add_owner_cand_ok", "add_owner_wearer_ok", "transfer_select", "transfer_hon", "transfer_confirm", "release_owner_confirm", "release_wearer_confirm", "runaway_confirm"
string UiParam1  = "";  // scratch (candidate key)
string UiParam2  = "";  // scratch (chosen honorific)
string UiData    = "";  // csv payload (candidate keys)

/* ========================== Helpers ========================== */
integer json_has(string j, list path) {
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return FALSE;
    return TRUE;
}
integer logd(string s) { if (DEBUG) llOwnerSay("[OWNER] " + s); return 0; }

/* Honorific options */
list owner_honorifics() { return ["Master","Mistress","Daddy","Mommy","King","Queen"]; }

/* Names */
string wearer_display_name() { return llKey2Name(llGetOwner()); }
string candidate_display_name(key k) { string n = llKey2Name(k); if (n == "") n = (string)k; return n; }
string owner_display_name() { return candidate_display_name(CollarOwner); }

/* ---------- RLVa helpers: auto-accept TP for the Primary Owner ---------- */
integer rlv_accepttp_add(key k){
    if (k == NULL_KEY) return FALSE;
    llOwnerSay("@accepttp:" + (string)k + "=add");
    RlvAccepttpOwner = k;
    logd("RLVa accepttp add → " + (string)k);
    return TRUE;
}
integer rlv_accepttp_rem(key k){
    if (k == NULL_KEY) return FALSE;
    llOwnerSay("@accepttp:" + (string)k + "=rem");
    if (RlvAccepttpOwner == k) RlvAccepttpOwner = NULL_KEY;
    logd("RLVa accepttp rem → " + (string)k);
    return TRUE;
}
integer rlv_accepttp_reconcile(key newOwner){
    /* remove stale rule if bound to different avatar */
    if (RlvAccepttpOwner != NULL_KEY){
        if (RlvAccepttpOwner != newOwner){
            rlv_accepttp_rem(RlvAccepttpOwner);
        }
    }
    /* ensure rule exists for current owner */
    if (newOwner != NULL_KEY){
        if (RlvAccepttpOwner != newOwner){
            rlv_accepttp_add(newOwner);
        }
    }
    return TRUE;
}

/* ---------- Kernel/Register/Soft reset ---------- */
integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  "2");                // matches your current file
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

/* ---------- ACL ---------- */
integer in_allowed_levels(integer lvl) {
    if (~llListFindList(ALLOWED_ACL_LEVELS, [lvl])) return TRUE;
    return FALSE;
}
integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    AclPending = TRUE;
    logd("ACL query → " + (string)av);
    return 0;
}

/* ---------- Settings sync ---------- */
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

/* Push our mirror to kernel */
integer push_settings() {
    string owner_str = (string)CollarOwner;
    settings_set_scalar(KEY_OWNER_KEY, owner_str);

    string hon = CollarOwnerHonorific;
    if (hon == "") hon = " ";
    settings_set_scalar(KEY_OWNER_HON, hon);

    settings_set_list(KEY_TRUSTEES, CollarTrustees);
    settings_set_list(KEY_TRUSTEE_HONS, CollarTrusteeHonorifics);

    string pub = "0"; if (CollarPublicAccess) pub = "1";
    string lck = "0"; if (CollarLocked)        lck = "1";
    settings_set_scalar(KEY_PUBLIC_MODE, pub);
    settings_set_scalar(KEY_LOCKED_FLAG, lck);

    logd("Settings pushed via kernel set operations.");
    return 0;
}

integer apply_owner_settings_payload(string payload) {
    key prev_owner = CollarOwner;

    if (json_has(payload, [KEY_OWNER_KEY]))  CollarOwner = (key)llJsonGetValue(payload, [KEY_OWNER_KEY]);
    else if (json_has(payload, [KEY_OWNER_LEGACY])) CollarOwner = (key)llJsonGetValue(payload, [KEY_OWNER_LEGACY]);

    if (json_has(payload, [KEY_OWNER_HON]))  CollarOwnerHonorific = llJsonGetValue(payload, [KEY_OWNER_HON]);
    else if (json_has(payload, ["owner_hon"])) CollarOwnerHonorific = llJsonGetValue(payload, ["owner_hon"]);

    if (json_has(payload, [KEY_TRUSTEES])) {
        string arr = llJsonGetValue(payload, [KEY_TRUSTEES]);
        if (llGetSubString(arr, 0, 0) == "[") CollarTrustees = llJson2List(arr);
    } else if (json_has(payload, ["trustees"])) {
        string arrLegacy = llJsonGetValue(payload, ["trustees"]);
        if (llGetSubString(arrLegacy, 0, 0) == "[") CollarTrustees = llJson2List(arrLegacy);
    }

    if (json_has(payload, [KEY_TRUSTEE_HONS])) {
        string arrh = llJsonGetValue(payload, [KEY_TRUSTEE_HONS]);
        if (llGetSubString(arrh, 0, 0) == "[") CollarTrusteeHonorifics = llJson2List(arrh);
    } else if (json_has(payload, ["trustees_hon"])) {
        string arrhLegacy = llJsonGetValue(payload, ["trustees_hon"]);
        if (llGetSubString(arrhLegacy, 0, 0) == "[") CollarTrusteeHonorifics = llJson2List(arrhLegacy);
    }

    if (json_has(payload, [KEY_PUBLIC_MODE])) CollarPublicAccess = ((integer)llJsonGetValue(payload, [KEY_PUBLIC_MODE])) != 0;
    else if (json_has(payload, ["public_access"])) CollarPublicAccess = ((integer)llJsonGetValue(payload, ["public_access"])) != 0;

    if (json_has(payload, [KEY_LOCKED_FLAG])) CollarLocked = ((integer)llJsonGetValue(payload, [KEY_LOCKED_FLAG])) != 0;
    else if (json_has(payload, ["locked"]))        CollarLocked = ((integer)llJsonGetValue(payload, ["locked"])) != 0;

    if (CollarOwner != prev_owner) {
        rlv_accepttp_reconcile(CollarOwner);
    } else {
        rlv_accepttp_reconcile(CollarOwner);
    }
    return 0;
}

/* Pull values from inbound settings JSON (kernel → plugins) */
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

/* ---------- UI plumbing ---------- */
integer reset_listen() {
    if (Listen) llListenRemove(Listen);
    Listen = 0; MenuChan = 0;
    llSetTimerEvent(0.0);
    return 0;
}

/* open a dialog for a specific avatar and listen only to them */
integer dialog_to(key who, string body, list buttons) {
    reset_listen();
    while ((llGetListLength(buttons) % 3) != 0) buttons += " ";
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    Listen = llListen(MenuChan, "", who, "");
    llDialog(who, body, buttons, MenuChan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}

/* back to root */
integer ui_return_root(key toUser) {
    string r = llList2Json(JSON_OBJECT, []);
    r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, toUser);
    return 0;
}

/* ---------- Menu ---------- */
list base_menu_buttons() {
    list btns = [];
    integer show_add_owner = FALSE;
    integer show_transfer  = FALSE;
    integer show_release   = FALSE;
    integer show_runaway   = FALSE;

    if (CollarOwner == NULL_KEY && AclLevel == ACL_UNOWNED) show_add_owner = TRUE;
    if (CollarOwner != NULL_KEY && AclLevel == ACL_PRIMARY_OWNER) {
        show_transfer = TRUE;
        show_release  = TRUE;
    }
    if (CollarOwner != NULL_KEY && AclLevel == ACL_OWNED) show_runaway = TRUE;

    if (show_add_owner) btns += ["Add Owner"];
    if (show_transfer)  btns += ["Transfer Sub"];
    if (show_release)   btns += ["Release Sub"];
    if (show_runaway)   btns += ["Runaway"];

    btns += ["Back"];
    return btns;
}

integer show_menu(key user) {
    UiContext = "menu";
    User = user;

    string owner_line = "(none)";
    if (CollarOwner != NULL_KEY) {
        owner_line = owner_display_name();
        if (owner_line == "") owner_line = (string)CollarOwner;
    }
    string hon_suffix = "";
    if (CollarOwnerHonorific != "") hon_suffix = " (" + CollarOwnerHonorific + ")";

    string body = "Owner Management\n"
                + "Wearer: " + wearer_display_name() + "\n"
                + "Owner : " + owner_line + hon_suffix;

    list btns = base_menu_buttons();
    dialog_to(user, body, btns);
    logd("Menu → " + (string)user);
    return 0;
}

/* ---------- Candidate selection helpers ---------- */
integer begin_pick_candidate(string next_context) {
    UiContext = next_context; // "add_owner_select" or "transfer_select"
    UiParam1  = "";
    UiParam2  = "";
    UiData    = "";
    llSensor("", NULL_KEY, AGENT, 20.0, PI * 2.0);
    return 0;
}

integer dialog_candidates_select(list candidates) {
    if (llGetListLength(candidates) == 0) {
        dialog_to(User, "No valid candidates found within 20m.", ["Back"]);
        UiContext = "menu";
        return FALSE;
    }

    list keys = [];
    list lines = [];
    integer i = 0; integer n = llGetListLength(candidates);
    while (i < n){
        key k = (key)llList2String(candidates, i);
        if (k != llGetOwner()) {
            keys += (string)k;
            string nm = candidate_display_name(k);
            lines += [(string)(llGetListLength(keys)) + ". " + nm];
        }
        i = i + 1;
    }

    if (llGetListLength(keys) == 0){
        dialog_to(User, "No valid candidates found within 20m.", ["Back"]);
        UiContext = "menu";
        return FALSE;
    }

    /* persist CSV of keys in UiData */
    UiData = llDumpList2String(keys, ",");

    /* build a numbered picker */
    string body = "Choose a person:\n" + llDumpList2String(lines, "\n");
    list buttons = [];
    integer b = 1; integer m = llGetListLength(keys);
    while (b <= m){
        buttons += (string)b;
        b = b + 1;
    }
    buttons += ["Back"];
    dialog_to(User, body, buttons);
    return TRUE;
}

/* =========================== EVENTS =========================== */
default{
    state_entry(){
        reset_listen();
        UiContext = "";
        AclPending = FALSE;
        AclLevel = ACL_NOACCESS;

        PLUGIN_SN = (integer)llFrand(2147480000.0);
        notify_soft_reset();
        register_plugin();

        /* ask kernel to broadcast settings (some cores do this automatically) */
        string q = llList2Json(JSON_OBJECT, []);
        q = llJsonSetValue(q, ["type"], CONS_SETTINGS_SYNC);
        q = llJsonSetValue(q, ["ns"],   CONS_SETTINGS_NS_OWNER);
        llMessageLinked(LINK_SET, K_SETTINGS_SYNC, q, NULL_KEY);

        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    /* Heartbeat */
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

        /* Kernel asks this script to re-register */
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

        /* Settings sync (kernel → plugins) */
        if (num == K_SETTINGS_SYNC){
            if (json_has(str, ["type"])){
                if (llJsonGetValue(str, ["type"]) == CONS_SETTINGS_SYNC){
                    ingest_settings(str);
                }
            }
            return;
        }

        /* UI start: secure open (AUTH) */
        if (num == K_PLUGIN_START){
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == CONS_TYPE_PLUGIN_START){
                if (json_has(str, ["context"]) && llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT){
                    User = id;
                    request_acl(User);
                    return;
                }
            }
            return;
        }

        /* AUTH result → open or deny */
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

    /* Proximity scan for candidate selection */
    sensor(integer n) {
        if (UiContext != "add_owner_select" && UiContext != "transfer_select") return;

        list candidates = [];
        integer i = 0;
        while (i < n){
            key k = llDetectedKey(i);
            if (k != llGetOwner()){
                /* in transfer flow, exclude current owner */
                if (UiContext == "transfer_select"){
                    if (k != CollarOwner) candidates += (string)k;
                } else {
                    candidates += (string)k;
                }
            }
            i = i + 1;
        }
        dialog_candidates_select(candidates);
    }
    no_sensor(){
        if (UiContext == "add_owner_select" || UiContext == "transfer_select"){
            dialog_candidates_select([]);
        }
    }

    listen(integer chan, string name, key id, string message){
        if (chan != MenuChan) return;

        /* root navigation */
        if (message == "Back"){
            if (UiContext == "menu"){
                ui_return_root(id);
                User = NULL_KEY;
                reset_listen();
                return;
            }
            /* From any sub-context back to main menu */
            show_menu(User);
            return;
        }

        /* ----- MENU ROOT ----- */
        if (UiContext == "menu"){
            if (message == "Add Owner"){
                begin_pick_candidate("add_owner_select");
                return;
            }
            if (message == "Transfer Sub"){
                begin_pick_candidate("transfer_select");
                return;
            }
            if (message == "Release Sub"){
                UiContext = "release_owner_confirm";
                dialog_to(CollarOwner, "Release your submissive " + wearer_display_name() + "?", ["Yes","No","Cancel"]);
                return;
            }
            if (message == "Runaway"){
                UiContext = "runaway_confirm";
                dialog_to(llGetOwner(), "Run away and become unowned?", ["Yes","No","Cancel"]);
                return;
            }
            /* unknown → redraw */
            show_menu(User);
            return;
        }

        /* ------- ADD OWNER FLOW ------- */
        if (UiContext == "add_owner_select"){
            list keys = llParseString2List(UiData, [","], []);
            integer idx = (integer)message - 1;
            if (idx >= 0 && idx < llGetListLength(keys)) {
                key cand = (key)llList2String(keys, idx);
                UiParam1 = (string)cand;

                list honors = owner_honorifics();
                string body = wearer_display_name() + " wishes to submit to you as their owner.\nChoose the honorific you wish to be called.";
                UiContext = "add_owner_hon";
                dialog_to(cand, body, honors);
                return;
            }
            show_menu(User);
            return;
        }
        if (UiContext == "add_owner_hon"){
            list honors = owner_honorifics();
            integer sel = llListFindList(honors, [message]);
            if (sel != -1){
                UiParam2 = llList2String(honors, sel);
                UiContext = "add_owner_cand_ok";
                string body = wearer_display_name() + " has submitted to you as their " + UiParam2 + ".\nAccept?";
                dialog_to(id, body, ["Yes","No","Cancel"]);
                return;
            }
            dialog_to(id, "Please choose an honorific.", honors);
            return;
        }
        if (UiContext == "add_owner_cand_ok"){
            if (message == "Yes"){
                UiContext = "add_owner_wearer_ok";
                string body = "You have submitted to " + candidate_display_name((key)UiParam1) + " as your " + UiParam2 + ".\nConfirm?";
                dialog_to(llGetOwner(), body, ["Yes","No","Cancel"]);
                return;
            }
            show_menu(User);
            return;
        }
        if (UiContext == "add_owner_wearer_ok"){
            if (message == "Yes"){
                key newOwner = (key)UiParam1;
                string hon = UiParam2;
                CollarOwner = newOwner;
                CollarOwnerHonorific = hon;

                /* RLVa: ensure PO can TP the wearer */
                rlv_accepttp_reconcile(newOwner);

                push_settings();
                dialog_to(newOwner, wearer_display_name() + " has submitted to you as their \"" + hon + "\".", ["OK"]);
                dialog_to(llGetOwner(), "You have submitted to " + candidate_display_name(newOwner) + " as your " + hon + ".", ["OK"]);
                UiContext = "menu";
                show_menu(User);
                return;
            }
            show_menu(User);
            return;
        }

        /* ------- TRANSFER FLOW ------- */
        if (UiContext == "transfer_select"){
            list keys = llParseString2List(UiData, [","], []);
            integer idx = (integer)message - 1;
            if (idx >= 0 && idx < llGetListLength(keys)){
                key newOwner = (key)llList2String(keys, idx);
                UiParam1 = (string)newOwner;

                list honors = owner_honorifics();
                string body = "You have been offered ownership of " + wearer_display_name() + ".\nChoose the honorific you wish to be called.";
                UiContext = "transfer_hon";
                dialog_to(newOwner, body, honors);
                return;
            }
            show_menu(User);
            return;
        }
        if (UiContext == "transfer_hon"){
            list honors = owner_honorifics();
            integer sel = llListFindList(honors, [message]);
            if (sel != -1){
                UiParam2 = llList2String(honors, sel);
                UiContext = "transfer_confirm";
                string body = "You are about to take ownership of " + wearer_display_name() + " as their " + UiParam2 + ".\nAccept?";
                dialog_to(id, body, ["Yes","No","Cancel"]);
                return;
            }
            dialog_to(id, "Please choose an honorific.", honors);
            return;
        }
        if (UiContext == "transfer_confirm"){
            if (message == "Yes"){
                key newOwner = (key)UiParam1;
                string hon  = UiParam2;
                key oldOwner = CollarOwner;

                CollarOwner = newOwner;
                CollarOwnerHonorific = hon;

                /* RLVa: swap rule old → new */
                rlv_accepttp_reconcile(newOwner);

                push_settings();
                dialog_to(oldOwner, "You have transferred your sub " + wearer_display_name() + " to " + candidate_display_name(newOwner) + " as their " + hon + ".", ["OK"]);
                dialog_to(newOwner, "You are now the owner of " + wearer_display_name() + " as their " + hon + ".", ["OK"]);
                UiContext = "menu";
                show_menu(User);
                return;
            }
            show_menu(User);
            return;
        }

        /* ------- RELEASE FLOW ------- */
        if (UiContext == "release_owner_confirm"){
            if (message == "Yes"){
                UiContext = "release_wearer_confirm";
                string body = "You have been released as " + CollarOwnerHonorific + " " + owner_display_name() + "'s submissive.\nConfirm freedom?";
                dialog_to(llGetOwner(), body, ["Yes","No","Cancel"]);
                return;
            }
            show_menu(User);
            return;
        }
        if (UiContext == "release_wearer_confirm"){
            if (message == "Yes"){
                key old = CollarOwner;
                string oldHon = CollarOwnerHonorific;

                /* RLVa: remove PO auto-accept */
                rlv_accepttp_rem(old);

                CollarOwner = NULL_KEY;
                CollarOwnerHonorific = "";

                push_settings();
                dialog_to(old, wearer_display_name() + " is now free.", ["OK"]);
                dialog_to(llGetOwner(), "You have been released as " + oldHon + " " + candidate_display_name(old) + "'s submissive.\nYou are now free.", ["OK"]);
                UiContext = "menu";
                show_menu(User);
                return;
            }
            show_menu(User);
            return;
        }

        /* ------- RUNAWAY FLOW ------- */
        if (UiContext == "runaway_confirm"){
            if (message == "Yes"){
                /* RLVa: remove current PO rule */
                rlv_accepttp_rem(CollarOwner);

                CollarOwner = NULL_KEY;
                CollarOwnerHonorific = "";
                push_settings();
                dialog_to(id, "You have run away and are now unowned.", ["OK"]);
                UiContext = "menu";
                show_menu(User);
                return;
            }
            show_menu(User);
            return;
        }

        /* Fallback → redraw */
        show_menu(User);
    }

    /* Timer: dialog timeout */
    timer(){
        reset_listen();
        if (User != NULL_KEY && UiContext != ""){
            /* optional: quietly return to menu for User */
        }
    }
}

