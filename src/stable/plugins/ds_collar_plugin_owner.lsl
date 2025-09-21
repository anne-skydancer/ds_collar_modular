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
string CONS_SETTINGS_NS_OWNER      = "owner";           // namespace/key for this module
string KEY_OWNER_KEY               = "owner_key";
string KEY_OWNER_LEGACY            = "owner";

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
key     g_user             = NULL_KEY;  // who opened plugin
integer g_listen           = 0;
integer g_menu_chan        = 0;

/* Gate state */
integer g_acl_pending = FALSE;
integer g_acl_level   = ACL_NOACCESS;

/* ---------- Owner/state mirror ---------- */
key     collar_owner            = NULL_KEY;
string  collar_owner_honorific  = "";
integer collar_locked           = FALSE;
integer collar_public_access    = FALSE;
list    collar_trustees         = [];
list    collar_trustee_honorifics = [];

/* ---------- RLVa auto-accept TP state ---------- */
key g_rlv_accepttp_owner = NULL_KEY;

/* ---------- Flow/session state ---------- */
string s_context = "";  // "", "menu", "add_owner_select", "add_owner_hon", "add_owner_cand_ok", "add_owner_wearer_ok", "transfer_select", "transfer_hon", "transfer_confirm", "release_owner_confirm", "release_wearer_confirm", "runaway_confirm"
string s_param1  = "";  // scratch (candidate key)
string s_param2  = "";  // scratch (chosen honorific)
string s_data    = "";  // csv payload (candidate keys)

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
string owner_display_name() { return candidate_display_name(collar_owner); }

/* ---------- RLVa helpers: auto-accept TP for the Primary Owner ---------- */
integer rlv_accepttp_add(key k){
    if (k == NULL_KEY) return FALSE;
    llOwnerSay("@accepttp:" + (string)k + "=add");
    g_rlv_accepttp_owner = k;
    logd("RLVa accepttp add → " + (string)k);
    return TRUE;
}
integer rlv_accepttp_rem(key k){
    if (k == NULL_KEY) return FALSE;
    llOwnerSay("@accepttp:" + (string)k + "=rem");
    if (g_rlv_accepttp_owner == k) g_rlv_accepttp_owner = NULL_KEY;
    logd("RLVa accepttp rem → " + (string)k);
    return TRUE;
}
integer rlv_accepttp_reconcile(key newOwner){
    /* remove stale rule if bound to different avatar */
    if (g_rlv_accepttp_owner != NULL_KEY){
        if (g_rlv_accepttp_owner != newOwner){
            rlv_accepttp_rem(g_rlv_accepttp_owner);
        }
    }
    /* ensure rule exists for current owner */
    if (newOwner != NULL_KEY){
        if (g_rlv_accepttp_owner != newOwner){
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
    j = llJsonSetValue(j, ["min_acl"],  "0");                // matches your current file
    j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
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
    g_acl_pending = TRUE;
    logd("ACL query → " + (string)av);
    return 0;
}

/* ---------- Settings sync ---------- */
/* Push our mirror to kernel */
integer push_settings() {
    string j = llList2Json(JSON_OBJECT, []);
    string owner_str = (string)collar_owner;

    j = llJsonSetValue(j, ["type"],   CONS_SETTINGS_SYNC);
    j = llJsonSetValue(j, ["ns"],     CONS_SETTINGS_NS_OWNER);
    j = llJsonSetValue(j, [KEY_OWNER_KEY], owner_str);
    /* Legacy mirror for older cores/plugins */
    j = llJsonSetValue(j, [KEY_OWNER_LEGACY], owner_str);

    string hon = collar_owner_honorific;
    if (hon == "") hon = " ";
    j = llJsonSetValue(j, ["owner_hon"], hon);

    j = llJsonSetValue(j, ["trustees"],     llList2Json(JSON_ARRAY, collar_trustees));
    j = llJsonSetValue(j, ["trustees_hon"], llList2Json(JSON_ARRAY, collar_trustee_honorifics));

    string pub = "0"; if (collar_public_access) pub = "1";
    string lck = "0"; if (collar_locked)        lck = "1";
    j = llJsonSetValue(j, ["public_access"], pub);
    j = llJsonSetValue(j, ["locked"],        lck);

    llMessageLinked(LINK_SET, K_SETTINGS_SYNC, j, NULL_KEY);
    logd("Settings pushed.");
    return 0;
}

/* Pull values from inbound settings JSON (kernel → plugins) */
integer ingest_settings(string j) {
    if (json_has(j, ["ns"])) {
        if (llJsonGetValue(j, ["ns"]) != CONS_SETTINGS_NS_OWNER) return 0;
    }

    key prev_owner = collar_owner;

    if (json_has(j, [KEY_OWNER_KEY]))  collar_owner           = (key)llJsonGetValue(j, [KEY_OWNER_KEY]);
    else if (json_has(j, [KEY_OWNER_LEGACY])) collar_owner     = (key)llJsonGetValue(j, [KEY_OWNER_LEGACY]);
    if (json_has(j, ["owner_hon"]))   collar_owner_honorific = llJsonGetValue(j, ["owner_hon"]);
    if (json_has(j, ["trustees"])) {
        list arr = llJson2List(llJsonGetValue(j, ["trustees"]));
        collar_trustees = arr;
    }
    if (json_has(j, ["trustees_hon"])) {
        list arrh = llJson2List(llJsonGetValue(j, ["trustees_hon"]));
        collar_trustee_honorifics = arrh;
    }
    if (json_has(j, ["public_access"])) collar_public_access = ((integer)llJsonGetValue(j, ["public_access"])) != 0;
    if (json_has(j, ["locked"]))        collar_locked        = ((integer)llJsonGetValue(j, ["locked"])) != 0;

    /* Keep RLVa in sync with whatever the settings say the owner is */
    if (collar_owner != prev_owner) {
        rlv_accepttp_reconcile(collar_owner);
    } else {
        /* Even if not changed, ensure rule exists (heals after relog) */
        rlv_accepttp_reconcile(collar_owner);
    }
    return 0;
}

/* ---------- UI plumbing ---------- */
integer reset_listen() {
    if (g_listen) llListenRemove(g_listen);
    g_listen = 0; g_menu_chan = 0;
    llSetTimerEvent(0.0);
    return 0;
}

/* open a dialog for a specific avatar and listen only to them */
integer dialog_to(key who, string body, list buttons) {
    reset_listen();
    while ((llGetListLength(buttons) % 3) != 0) buttons += " ";
    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen = llListen(g_menu_chan, "", who, "");
    llDialog(who, body, buttons, g_menu_chan);
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

    if (collar_owner == NULL_KEY && g_acl_level == ACL_UNOWNED) show_add_owner = TRUE;
    if (collar_owner != NULL_KEY && g_acl_level == ACL_PRIMARY_OWNER) {
        show_transfer = TRUE;
        show_release  = TRUE;
    }
    if (collar_owner != NULL_KEY && g_acl_level == ACL_OWNED) show_runaway = TRUE;

    if (show_add_owner) btns += ["Add Owner"];
    if (show_transfer)  btns += ["Transfer Sub"];
    if (show_release)   btns += ["Release Sub"];
    if (show_runaway)   btns += ["Runaway"];

    btns += ["Back"];
    return btns;
}

integer show_menu(key user) {
    s_context = "menu";
    g_user = user;

    string owner_line = "(none)";
    if (collar_owner != NULL_KEY) {
        owner_line = owner_display_name();
        if (owner_line == "") owner_line = (string)collar_owner;
    }
    string hon_suffix = "";
    if (collar_owner_honorific != "") hon_suffix = " (" + collar_owner_honorific + ")";

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
    s_context = next_context; // "add_owner_select" or "transfer_select"
    s_param1  = "";
    s_param2  = "";
    s_data    = "";
    llSensor("", NULL_KEY, AGENT, 20.0, PI * 2.0);
    return 0;
}

integer dialog_candidates_select(list candidates) {
    if (llGetListLength(candidates) == 0) {
        dialog_to(g_user, "No valid candidates found within 20m.", ["Back"]);
        s_context = "menu";
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
        dialog_to(g_user, "No valid candidates found within 20m.", ["Back"]);
        s_context = "menu";
        return FALSE;
    }

    /* persist CSV of keys in s_data */
    s_data = llDumpList2String(keys, ",");

    /* build a numbered picker */
    string body = "Choose a person:\n" + llDumpList2String(lines, "\n");
    list buttons = [];
    integer b = 1; integer m = llGetListLength(keys);
    while (b <= m){
        buttons += (string)b;
        b = b + 1;
    }
    buttons += ["Back"];
    dialog_to(g_user, body, buttons);
    return TRUE;
}

/* =========================== EVENTS =========================== */
default{
    state_entry(){
        reset_listen();
        s_context = "";
        g_acl_pending = FALSE;
        g_acl_level = ACL_NOACCESS;

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
                    g_user = id;
                    request_acl(g_user);
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
            if (av != g_user) return;

            if (!json_has(str, ["level"])) return;
            g_acl_level = (integer)llJsonGetValue(str, ["level"]);
            g_acl_pending = FALSE;

            if (!in_allowed_levels(g_acl_level)){
                llRegionSayTo(g_user, 0, "Access denied.");
                ui_return_root(g_user);
                g_user = NULL_KEY;
                reset_listen();
                return;
            }

            show_menu(g_user);
            return;
        }
    }

    /* Proximity scan for candidate selection */
    sensor(integer n) {
        if (s_context != "add_owner_select" && s_context != "transfer_select") return;

        list candidates = [];
        integer i = 0;
        while (i < n){
            key k = llDetectedKey(i);
            if (k != llGetOwner()){
                /* in transfer flow, exclude current owner */
                if (s_context == "transfer_select"){
                    if (k != collar_owner) candidates += (string)k;
                } else {
                    candidates += (string)k;
                }
            }
            i = i + 1;
        }
        dialog_candidates_select(candidates);
    }
    no_sensor(){
        if (s_context == "add_owner_select" || s_context == "transfer_select"){
            dialog_candidates_select([]);
        }
    }

    listen(integer chan, string name, key id, string message){
        if (chan != g_menu_chan) return;

        /* root navigation */
        if (message == "Back"){
            if (s_context == "menu"){
                ui_return_root(id);
                g_user = NULL_KEY;
                reset_listen();
                return;
            }
            /* From any sub-context back to main menu */
            show_menu(g_user);
            return;
        }

        /* ----- MENU ROOT ----- */
        if (s_context == "menu"){
            if (message == "Add Owner"){
                begin_pick_candidate("add_owner_select");
                return;
            }
            if (message == "Transfer Sub"){
                begin_pick_candidate("transfer_select");
                return;
            }
            if (message == "Release Sub"){
                s_context = "release_owner_confirm";
                dialog_to(collar_owner, "Release your submissive " + wearer_display_name() + "?", ["Yes","No","Cancel"]);
                return;
            }
            if (message == "Runaway"){
                s_context = "runaway_confirm";
                dialog_to(llGetOwner(), "Run away and become unowned?", ["Yes","No","Cancel"]);
                return;
            }
            /* unknown → redraw */
            show_menu(g_user);
            return;
        }

        /* ------- ADD OWNER FLOW ------- */
        if (s_context == "add_owner_select"){
            list keys = llParseString2List(s_data, [","], []);
            integer idx = (integer)message - 1;
            if (idx >= 0 && idx < llGetListLength(keys)) {
                key cand = (key)llList2String(keys, idx);
                s_param1 = (string)cand;

                list honors = owner_honorifics();
                string body = wearer_display_name() + " wishes to submit to you as their owner.\nChoose the honorific you wish to be called.";
                s_context = "add_owner_hon";
                dialog_to(cand, body, honors);
                return;
            }
            show_menu(g_user);
            return;
        }
        if (s_context == "add_owner_hon"){
            list honors = owner_honorifics();
            integer sel = llListFindList(honors, [message]);
            if (sel != -1){
                s_param2 = llList2String(honors, sel);
                s_context = "add_owner_cand_ok";
                string body = wearer_display_name() + " has submitted to you as their " + s_param2 + ".\nAccept?";
                dialog_to(id, body, ["Yes","No","Cancel"]);
                return;
            }
            dialog_to(id, "Please choose an honorific.", honors);
            return;
        }
        if (s_context == "add_owner_cand_ok"){
            if (message == "Yes"){
                s_context = "add_owner_wearer_ok";
                string body = "You have submitted to " + candidate_display_name((key)s_param1) + " as your " + s_param2 + ".\nConfirm?";
                dialog_to(llGetOwner(), body, ["Yes","No","Cancel"]);
                return;
            }
            show_menu(g_user);
            return;
        }
        if (s_context == "add_owner_wearer_ok"){
            if (message == "Yes"){
                key newOwner = (key)s_param1;
                string hon = s_param2;
                collar_owner = newOwner;
                collar_owner_honorific = hon;

                /* RLVa: ensure PO can TP the wearer */
                rlv_accepttp_reconcile(newOwner);

                push_settings();
                dialog_to(newOwner, wearer_display_name() + " has submitted to you as their \"" + hon + "\".", ["OK"]);
                dialog_to(llGetOwner(), "You have submitted to " + candidate_display_name(newOwner) + " as your " + hon + ".", ["OK"]);
                s_context = "menu";
                show_menu(g_user);
                return;
            }
            show_menu(g_user);
            return;
        }

        /* ------- TRANSFER FLOW ------- */
        if (s_context == "transfer_select"){
            list keys = llParseString2List(s_data, [","], []);
            integer idx = (integer)message - 1;
            if (idx >= 0 && idx < llGetListLength(keys)){
                key newOwner = (key)llList2String(keys, idx);
                s_param1 = (string)newOwner;

                list honors = owner_honorifics();
                string body = "You have been offered ownership of " + wearer_display_name() + ".\nChoose the honorific you wish to be called.";
                s_context = "transfer_hon";
                dialog_to(newOwner, body, honors);
                return;
            }
            show_menu(g_user);
            return;
        }
        if (s_context == "transfer_hon"){
            list honors = owner_honorifics();
            integer sel = llListFindList(honors, [message]);
            if (sel != -1){
                s_param2 = llList2String(honors, sel);
                s_context = "transfer_confirm";
                string body = "You are about to take ownership of " + wearer_display_name() + " as their " + s_param2 + ".\nAccept?";
                dialog_to(id, body, ["Yes","No","Cancel"]);
                return;
            }
            dialog_to(id, "Please choose an honorific.", honors);
            return;
        }
        if (s_context == "transfer_confirm"){
            if (message == "Yes"){
                key newOwner = (key)s_param1;
                string hon  = s_param2;
                key oldOwner = collar_owner;

                collar_owner = newOwner;
                collar_owner_honorific = hon;

                /* RLVa: swap rule old → new */
                rlv_accepttp_reconcile(newOwner);

                push_settings();
                dialog_to(oldOwner, "You have transferred your sub " + wearer_display_name() + " to " + candidate_display_name(newOwner) + " as their " + hon + ".", ["OK"]);
                dialog_to(newOwner, "You are now the owner of " + wearer_display_name() + " as their " + hon + ".", ["OK"]);
                s_context = "menu";
                show_menu(g_user);
                return;
            }
            show_menu(g_user);
            return;
        }

        /* ------- RELEASE FLOW ------- */
        if (s_context == "release_owner_confirm"){
            if (message == "Yes"){
                s_context = "release_wearer_confirm";
                string body = "You have been released as " + collar_owner_honorific + " " + owner_display_name() + "'s submissive.\nConfirm freedom?";
                dialog_to(llGetOwner(), body, ["Yes","No","Cancel"]);
                return;
            }
            show_menu(g_user);
            return;
        }
        if (s_context == "release_wearer_confirm"){
            if (message == "Yes"){
                key old = collar_owner;
                string oldHon = collar_owner_honorific;

                /* RLVa: remove PO auto-accept */
                rlv_accepttp_rem(old);

                collar_owner = NULL_KEY;
                collar_owner_honorific = "";

                push_settings();
                dialog_to(old, wearer_display_name() + " is now free.", ["OK"]);
                dialog_to(llGetOwner(), "You have been released as " + oldHon + " " + candidate_display_name(old) + "'s submissive.\nYou are now free.", ["OK"]);
                s_context = "menu";
                show_menu(g_user);
                return;
            }
            show_menu(g_user);
            return;
        }

        /* ------- RUNAWAY FLOW ------- */
        if (s_context == "runaway_confirm"){
            if (message == "Yes"){
                /* RLVa: remove current PO rule */
                rlv_accepttp_rem(collar_owner);

                collar_owner = NULL_KEY;
                collar_owner_honorific = "";
                push_settings();
                dialog_to(id, "You have run away and are now unowned.", ["OK"]);
                s_context = "menu";
                show_menu(g_user);
                return;
            }
            show_menu(g_user);
            return;
        }

        /* Fallback → redraw */
        show_menu(g_user);
    }

    /* Timer: dialog timeout */
    timer(){
        reset_listen();
        if (g_user != NULL_KEY && s_context != ""){
            /* optional: quietly return to menu for g_user */
        }
    }
}
