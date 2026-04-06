/*--------------------
PLUGIN: plugin_rlvex.lsl
VERSION: 1.10
REVISION: 1
PURPOSE: Manage RLV teleport and IM exceptions for owners and trustees
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 1: Migrate settings reads from JSON broadcast to direct LSD reads.
  Remove apply_settings_delta(); both sync and delta call apply_settings_sync().
  Remove request_settings_sync(); call apply_settings_sync() from state_entry.
  Previous-state comparison triggers reconcile_all() on any relevant change.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads via get_policy_buttons()
  and btn_allowed(). Removed PLUGIN_MIN_ACL and min_acl from kernel
  registration message.
--------------------*/


/* -------------------- ABI CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- IDENTITY -------------------- */
string PLUGIN_CONTEXT = "core_rlv_exceptions";
string PLUGIN_LABEL = "Exceptions";

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_EX_OWNER_TP   = "rlvex.ownertp";
string KEY_EX_OWNER_IM   = "rlvex.ownerim";
string KEY_EX_TRUSTEE_TP = "rlvex.trusteetp";
string KEY_EX_TRUSTEE_IM = "rlvex.trusteeim";
string KEY_OWNER          = "access.owner";
string KEY_OWNERS         = "access.owners";
string KEY_TRUSTEES       = "access.trustees";
string KEY_MULTI_OWNER_MODE = "access.multiowner";

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
list gPolicyButtons = [];
string SessionId;
string MenuContext;

integer PendingReconcile = FALSE;

/* -------------------- HELPERS -------------------- */

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

string gen_session() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD POLICY HELPER -------------------- */
list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("policy:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

/* -------------------- RLV COMMANDS -------------------- */

apply_tp_exception(key k, integer allow) {
    if (k == NULL_KEY) return;
    string sk = (string)k;
    string op = "=add";
    if (!allow) op = "=rem";
    llOwnerSay("@accepttp:" + sk + op + ",tplure:" + sk + op);
}

apply_im_exception(key k, integer allow) {
    if (k == NULL_KEY) return;
    string sk = (string)k;
    string op = "=add";
    if (!allow) op = "=rem";
    llOwnerSay("@sendim:" + sk + op + ",recvim:" + sk + op);
}

reconcile_all() {
    // Check if there are any owners/trustees to apply exceptions for
    integer has_owners = (MultiOwnerMode && llGetListLength(OwnerKeys) > 0) || (!MultiOwnerMode && OwnerKey != NULL_KEY);
    integer has_trustees = llGetListLength(TrusteeKeys) > 0;

    if (!has_owners && !has_trustees) return;

    // Owner exceptions
    if (MultiOwnerMode) {
        integer i = 0;
        integer owner_count = llGetListLength(OwnerKeys);
        while (i < owner_count) {
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
    integer i = 0;
    integer trustee_count = llGetListLength(TrusteeKeys);
    while (i < trustee_count) {
        key k = (key)llList2String(TrusteeKeys, i);
        apply_tp_exception(k, ExTrusteeTp);
        apply_im_exception(k, ExTrusteeIm);
        i++;
    }
}

/* -------------------- LIFECYCLE -------------------- */

register_self() {
    // Write button visibility policy to LSD (default-deny per ACL level)
    llLinksetDataWrite("policy:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "3", "Owner,Trustee,TP,IM",
        "4", "Owner,Trustee,TP,IM",
        "5", "Owner,Trustee,TP,IM"
    ]));

    // Register with kernel
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
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

apply_settings_sync() {
    // Save previous state for change detection
    key prev_owner = OwnerKey;
    list prev_owners = OwnerKeys;
    list prev_trustees = TrusteeKeys;
    integer prev_ex_otp = ExOwnerTp;
    integer prev_ex_oim = ExOwnerIm;
    integer prev_ex_ttp = ExTrusteeTp;
    integer prev_ex_tim = ExTrusteeIm;
    integer prev_multi = MultiOwnerMode;

    // Reset state
    OwnerKey = NULL_KEY;
    OwnerKeys = [];
    TrusteeKeys = [];
    MultiOwnerMode = FALSE;

    // Read exception settings from LSD
    ExOwnerTp = lsd_int(KEY_EX_OWNER_TP, TRUE);
    ExOwnerIm = lsd_int(KEY_EX_OWNER_IM, TRUE);
    ExTrusteeTp = lsd_int(KEY_EX_TRUSTEE_TP, FALSE);
    ExTrusteeIm = lsd_int(KEY_EX_TRUSTEE_IM, FALSE);

    // Read multi-owner mode
    string tmp = llLinksetDataRead(KEY_MULTI_OWNER_MODE);
    if (tmp != "") {
        MultiOwnerMode = (integer)tmp;
    }

    // Read owner/trustee lists from LSD
    if (MultiOwnerMode) {
        string obj = llLinksetDataRead(KEY_OWNERS);
        if (obj != "") {
            if (llJsonValueType(obj, []) == JSON_OBJECT) {
                list pairs = llJson2List(obj);
                integer oi = 0;
                integer olen = llGetListLength(pairs);
                while (oi < olen) {
                    OwnerKeys += [llList2String(pairs, oi)];
                    oi += 2;
                }
            }
        }
    }
    else {
        string obj = llLinksetDataRead(KEY_OWNER);
        if (obj != "") {
            if (llJsonValueType(obj, []) == JSON_OBJECT) {
                list pairs = llJson2List(obj);
                if (llGetListLength(pairs) >= 2) {
                    OwnerKey = (key)llList2String(pairs, 0);
                }
            }
        }
    }

    string trustees_raw = llLinksetDataRead(KEY_TRUSTEES);
    if (trustees_raw != "") {
        if (llJsonValueType(trustees_raw, []) == JSON_OBJECT) {
            list pairs = llJson2List(trustees_raw);
            integer pi = 0;
            integer plen = llGetListLength(pairs);
            while (pi < plen) {
                TrusteeKeys += [llList2String(pairs, pi)];
                pi += 2;
            }
        }
    }

    // Auto-initialize exception settings if owners exist but LSD keys are absent
    integer owners_exist = (MultiOwnerMode && llGetListLength(OwnerKeys) > 0) || (!MultiOwnerMode && OwnerKey != NULL_KEY);
    if (owners_exist) {
        if (llLinksetDataRead(KEY_EX_OWNER_TP) == "") persist_setting(KEY_EX_OWNER_TP, TRUE);
        if (llLinksetDataRead(KEY_EX_OWNER_IM) == "") persist_setting(KEY_EX_OWNER_IM, TRUE);
    }

    // Detect changes: clear old exceptions for removed owners/trustees
    integer need_reconcile = FALSE;

    if (ExOwnerTp != prev_ex_otp || ExOwnerIm != prev_ex_oim
        || ExTrusteeTp != prev_ex_ttp || ExTrusteeIm != prev_ex_tim
        || MultiOwnerMode != prev_multi) {
        need_reconcile = TRUE;
    }

    // Single owner changed
    if (OwnerKey != prev_owner) {
        if (prev_owner != NULL_KEY) {
            apply_tp_exception(prev_owner, FALSE);
            apply_im_exception(prev_owner, FALSE);
        }
        need_reconcile = TRUE;
    }

    // Multi-owner list changed
    if (llList2CSV(OwnerKeys) != llList2CSV(prev_owners)) {
        integer ci = 0;
        integer old_count = llGetListLength(prev_owners);
        while (ci < old_count) {
            key old_k = (key)llList2String(prev_owners, ci);
            apply_tp_exception(old_k, FALSE);
            apply_im_exception(old_k, FALSE);
            ci++;
        }
        need_reconcile = TRUE;
    }

    // Trustee list changed
    if (llList2CSV(TrusteeKeys) != llList2CSV(prev_trustees)) {
        integer ci = 0;
        integer old_count = llGetListLength(prev_trustees);
        while (ci < old_count) {
            key old_k = (key)llList2String(prev_trustees, ci);
            apply_tp_exception(old_k, FALSE);
            apply_im_exception(old_k, FALSE);
            ci++;
        }
        need_reconcile = TRUE;
    }

    if (need_reconcile) {
        PendingReconcile = TRUE;
        llSetTimerEvent(1.0);
    }
}

persist_setting(string setting_key, integer value) {
    llLinksetDataWrite(setting_key, (string)value);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", setting_key,
        "value", (string)value
    ]), NULL_KEY);
}

/* -------------------- MENUS -------------------- */

show_main() {
    SessionId = gen_session();
    MenuContext = "main";

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string body = "RLV Exceptions\n\nManage which restrictions can be bypassed by owners and trustees.";

    list buttons = ["Back"];
    if (btn_allowed("Owner"))   buttons += ["Owner"];
    if (btn_allowed("Trustee")) buttons += ["Trustee"];

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

    list buttons = ["Back"];
    if (btn_allowed("TP")) buttons += ["TP"];
    if (btn_allowed("IM")) buttons += ["IM"];

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

    list buttons = ["Back"];
    if (btn_allowed("TP")) buttons += ["TP"];
    if (btn_allowed("IM")) buttons += ["IM"];

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

show_toggle(string role, string exception_type, integer current) {
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
            if (llSubStringIndex(MenuContext, "Owner") == 0) show_owner_menu();
            else if (llSubStringIndex(MenuContext, "Trustee") == 0) show_trustee_menu();
            else show_main();
        }
        return;
    }

    if (MenuContext == "main") {
        if (btn == "Owner") show_owner_menu();
        else if (btn == "Trustee") show_trustee_menu();
    }
    else if (MenuContext == "owner") {
        if (btn == "TP") show_toggle("Owner", "TP", ExOwnerTp);
        else if (btn == "IM") show_toggle("Owner", "IM", ExOwnerIm);
    }
    else if (MenuContext == "trustee") {
        if (btn == "TP") show_toggle("Trustee", "TP", ExTrusteeTp);
        else if (btn == "IM") show_toggle("Trustee", "IM", ExTrusteeIm);
    }
    else if (MenuContext == "Owner_TP") {
        if (btn == "Allow") {
            ExOwnerTp = TRUE;
            persist_setting(KEY_EX_OWNER_TP, TRUE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Owner TP exception allowed.");
        }
        else if (btn == "Deny") {
            ExOwnerTp = FALSE;
            persist_setting(KEY_EX_OWNER_TP, FALSE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Owner TP exception denied.");
        }
        show_owner_menu();
    }
    else if (MenuContext == "Owner_IM") {
        if (btn == "Allow") {
            ExOwnerIm = TRUE;
            persist_setting(KEY_EX_OWNER_IM, TRUE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Owner IM exception allowed.");
        }
        else if (btn == "Deny") {
            ExOwnerIm = FALSE;
            persist_setting(KEY_EX_OWNER_IM, FALSE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Owner IM exception denied.");
        }
        show_owner_menu();
    }
    else if (MenuContext == "Trustee_TP") {
        if (btn == "Allow") {
            ExTrusteeTp = TRUE;
            persist_setting(KEY_EX_TRUSTEE_TP, TRUE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception allowed.");
        }
        else if (btn == "Deny") {
            ExTrusteeTp = FALSE;
            persist_setting(KEY_EX_TRUSTEE_TP, FALSE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception denied.");
        }
        show_trustee_menu();
    }
    else if (MenuContext == "Trustee_IM") {
        if (btn == "Allow") {
            ExTrusteeIm = TRUE;
            persist_setting(KEY_EX_TRUSTEE_IM, TRUE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception allowed.");
        }
        else if (btn == "Deny") {
            ExTrusteeIm = FALSE;
            persist_setting(KEY_EX_TRUSTEE_IM, FALSE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception denied.");
        }
        show_trustee_menu();
    }
}

/* -------------------- CLEANUP -------------------- */

cleanup() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "dialog_close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    llSetTimerEvent(0.0);
    PendingReconcile = FALSE;
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    MenuContext = "";
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        cleanup();
        register_self();
        apply_settings_sync();
    }

    on_rez(integer p) {
        llResetScript();
    }

    changed(integer c) {
        if (c & CHANGED_OWNER) llResetScript();
    }

    timer() {
        llSetTimerEvent(0.0);
        if (PendingReconcile) {
            PendingReconcile = FALSE;
            reconcile_all();
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string type = llJsonGetValue(msg, ["type"]);
        if (type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (type == "register_now") {
                register_self();
                apply_settings_sync();
            }
            else if (type == "ping") send_pong();
            else if (type == "soft_reset" || type == "soft_reset_all") {
                // On soft reset, reapply RLV exceptions with same delay as settings_sync
                PendingReconcile = TRUE;
                llSetTimerEvent(1.0);
            }
        }
        else if (num == SETTINGS_BUS) {
            if (type == "settings_sync" || type == "settings_delta") apply_settings_sync();
        }
        else if (num == UI_BUS) {
            if (type == "start" && (llJsonGetValue(msg, ["context"]) != JSON_INVALID)) {
                if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    CurrentUser = id;
                    UserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                    show_main();
                }
            }
        }
        else if (num == DIALOG_BUS) {
            if (type == "dialog_response") {
                if ((llJsonGetValue(msg, ["session_id"]) != JSON_INVALID) && (llJsonGetValue(msg, ["button"]) != JSON_INVALID)) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) {
                        handle_button(llJsonGetValue(msg, ["button"]));
                    }
                }
            }
            else if (type == "dialog_timeout") {
                if ((llJsonGetValue(msg, ["session_id"]) != JSON_INVALID)) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) cleanup();
                }
            }
        }
    }
}
