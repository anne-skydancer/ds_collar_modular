/* =============================================================
   PLUGIN: ds_collar_plugin_tpemode.lsl
   PURPOSE: Manage Total Power Exchange Mode (TPE Mode)
            - Enable: Owner confirms → Wearer confirms → persist.
              Then ONLY the WEARER receives an informational OK dialog
              “You are now the totally power-exchanged servant of <hon> <owner>.”
              After OK, the session ENDS (no TPE menu shown).
            - Disable: Owner confirms → persist. Owner gets a final OK, then END.
            - Persistent to settings; integrates with Public plugin.
   ============================================================= */

integer DEBUG = FALSE;

/* ---------- Link message channels ---------- */
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
integer K_TPE_PUBLIC_CTRL    = 950;

/* ---------- Message constants ---------- */
string TYPE_REGISTER          = "register";
string TYPE_REGISTER_NOW      = "register_now";
string TYPE_PLUGIN_PING       = "plugin_ping";
string TYPE_PLUGIN_PONG       = "plugin_pong";
string TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string TYPE_SETTINGS_GET      = "settings_get";
string TYPE_SETTINGS_SYNC     = "settings_sync";
string TYPE_SETTINGS_SET      = "set";
string TYPE_PLUGIN_RETURN     = "plugin_return";
string TYPE_PLUGIN_START      = "plugin_start";
string CONS_MSG_ACL_QUERY     = "acl_query";
string CONS_MSG_ACL_RESULT    = "acl_result";

/* ---------- TPE/Public plugin commands ---------- */
string TPE_PUBLIC_ENABLE  = "enable";
string TPE_PUBLIC_DISABLE = "disable";

/* ---------- ACL levels ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* Only allow primary owner for this plugin */
list ALLOWED_ACL_LEVELS = [ACL_PRIMARY_OWNER];

/* ---------- Plugin identity ---------- */
string  PLUGIN_CONTEXT   = "core_tpemode";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "TPE Mode";
integer PLUGIN_SN        = 0;
integer PLUGIN_MIN_ACL   = 5; // ACL 5 only

/* ---------- Settings ---------- */
string KEY_TPE_MODE   = "tpe_mode";
string KEY_OWNER_KEY  = "owner_key";
string KEY_OWNER_HON  = "owner_hon";

integer TpeMode      = FALSE;
key     OwnerKey   = NULL_KEY;
string  OwnerHon   = "";

/* ---------- UI/session state ---------- */
integer DIALOG_TIMEOUT_SEC = 180;
key     User        = NULL_KEY; // current active dialog recipient
key     Initiator   = NULL_KEY; // who opened the plugin (primary owner)
integer Listen      = 0;
integer MenuChan   = 0;
/* Ctx:
   "main"             owner main menu
   "confirm_owner"    owner enable confirm
   "confirm_wearer"   wearer enable confirm
   "confirm_disable"  owner disable confirm
   "final_ack"        terminal OK (wearer on enable; owner on disable)
*/
string  Ctx         = "";

integer AclPending = FALSE;
integer AclLevel   = ACL_NOACCESS;

/* ========================== Helpers ========================== */
integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
integer logd(string s) { if (DEBUG) llOwnerSay("[TPE] " + s); return 0; }

integer in_allowed_levels(integer lvl) {
    if (llListFindList(ALLOWED_ACL_LEVELS, [lvl]) != -1) return TRUE;
    return FALSE;
}

string owner_display_name() {
    string nm = llKey2Name(OwnerKey);
    if (nm == "") nm = (string)OwnerKey;
    return nm;
}

integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered with kernel.");
    return 0;
}

integer notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    return 0;
}

integer request_settings_get() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    return 0;
}

integer persist_tpe(integer value01) {
    if (value01 != 0) value01 = 1;
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],  TYPE_SETTINGS_SET);
    j = llJsonSetValue(j, ["key"],   KEY_TPE_MODE);
    j = llJsonSetValue(j, ["value"], (string)value01);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    TpeMode = value01;
    logd("Persisted TpeMode=" + (string)value01);
    return 0;
}

integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    AclPending = TRUE;
    return 0;
}

integer reset_listen() {
    if (Listen) llListenRemove(Listen);
    Listen = 0;
    MenuChan = 0;
    return 0;
}

integer begin_dialog(key user, string ctx, string body, list buttons) {
    reset_listen();
    User = user;
    Ctx  = ctx;
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    Listen    = llListen(MenuChan, "", User, "");
    while ((llGetListLength(buttons) % 3) != 0) buttons += " ";
    llDialog(User, body, buttons, MenuChan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}

integer end_session() {
    reset_listen();
    User = NULL_KEY;
    Initiator = NULL_KEY;
    Ctx = "";
    llSetTimerEvent(0.0);
    return 0;
}

/* ---------- UI content ---------- */
integer show_main_menu(key user) {
    list btns;
    if (TpeMode) btns = ["~", "Back", "~", "Disable"];
    else         btns = ["~", "Back", "~", "Enable"];
    string msg = "TPE Mode is currently ";
    if (TpeMode) msg += "ENABLED.\nDisable TPE Mode?";
    else         msg += "DISABLED.\nEnable TPE Mode?";
    begin_dialog(user, "main", msg, btns);
    return 0;
}

integer show_owner_confirm(key user) {
    list btns = ["Yes", "No"];
    string msg = "WARNING: Enabling TPE Mode will grant the wearer NO local control.\nConfirm to proceed.";
    begin_dialog(user, "confirm_owner", msg, btns);
    return 0;
}

integer show_wearer_confirm() {
    list btns = ["Yes", "No"];
    string msg = "Your owner wants to enable Total Power Exchange Mode.\nDo you consent?";
    key wearer = llGetOwner();
    begin_dialog(wearer, "confirm_wearer", msg, btns);
    return 0;
}

integer show_owner_disable_confirm(key user) {
    list btns = ["Yes", "No"];
    string msg = "Disable TPE Mode?";
    begin_dialog(user, "confirm_disable", msg, btns);
    return 0;
}

/* =========================== Events ========================== */
default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_plugin();
        request_settings_get();

        TpeMode = FALSE;
        User = NULL_KEY;
        Initiator = NULL_KEY;
        reset_listen();
        Ctx = "";
        AclPending = FALSE;
        llSetTimerEvent(0.0);
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* Heartbeat */
        if (num == K_PLUGIN_PING) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_PING) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    string pong = llList2Json(JSON_OBJECT, []);
                    pong = llJsonSetValue(pong, ["type"],    TYPE_PLUGIN_PONG);
                    pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                }
            }
            return;
        }

        /* Re-register if kernel asks */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_REGISTER_NOW) {
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        /* Settings sync (read tpe, owner key/hon) */
        if (num == K_SETTINGS_SYNC) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_SETTINGS_SYNC) {
                if (json_has(msg, ["kv"])) {
                    string kv = llJsonGetValue(msg, ["kv"]);
                    if (json_has(kv, [KEY_TPE_MODE]))  TpeMode  = (integer)llJsonGetValue(kv, [KEY_TPE_MODE]);
                    if (json_has(kv, [KEY_OWNER_KEY])) OwnerKey = (key)llJsonGetValue(kv, [KEY_OWNER_KEY]);
                    if (json_has(kv, [KEY_OWNER_HON])) OwnerHon = llJsonGetValue(kv, [KEY_OWNER_HON]);
                }
            }
            return;
        }

        /* UI start → only PO can open */
        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_START) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    Initiator = id;
                    request_acl(Initiator);
                }
            }
            return;
        }

        /* ACL result for initiator */
        if (num == AUTH_RESULT_NUM) {
            if (!AclPending) return;
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != CONS_MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;
            key who = (key)llJsonGetValue(msg, ["avatar"]);
            if (who != Initiator) return;
            if (!json_has(msg, ["level"])) return;

            AclLevel = (integer)llJsonGetValue(msg, ["level"]);
            AclPending = FALSE;

            if (in_allowed_levels(AclLevel)) {
                show_main_menu(Initiator);
            } else {
                llRegionSayTo(Initiator, 0, "Access denied.");
                /* Return to root (owner) */
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"], TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, Initiator);
                end_session();
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string message) {
        if (chan != MenuChan) return;

        /* MAIN (owner) */
        if (Ctx == "main") {
            if (message == "Back") {
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"], TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, Initiator);
                end_session();
                return;
            }
            if (message == "Enable") {
                show_owner_confirm(Initiator);
                return;
            }
            if (message == "Disable") {
                show_owner_disable_confirm(Initiator);
                return;
            }
        }

        /* OWNER CONFIRM (enable) */
        else if (Ctx == "confirm_owner") {
            if (message == "Yes") {
                show_wearer_confirm();
                return;
            } else {
                show_main_menu(Initiator);
                return;
            }
        }

        /* WEARER CONFIRM (enable) */
        else if (Ctx == "confirm_wearer") {
            if (message == "Yes") {
                /* Persist and notify Public plugin */
                persist_tpe(TRUE);
                llMessageLinked(LINK_SET, K_TPE_PUBLIC_CTRL, TPE_PUBLIC_ENABLE, NULL_KEY);

                /* Only the WEARER gets the informational dialog, then end */
                string hon = OwnerHon;
                string nm  = owner_display_name();
                string line = "You are now the totally power-exchanged servant of ";
                if (hon != "") line += hon + " ";
                line += nm + ".";
                begin_dialog(llGetOwner(), "final_ack", line, ["OK"]);
                return;
            } else {
                /* Wearer declined → simply return owner to main */
                show_main_menu(Initiator);
                return;
            }
        }

        /* OWNER CONFIRM (disable) */
        else if (Ctx == "confirm_disable") {
            if (message == "Yes") {
                persist_tpe(FALSE);
                llMessageLinked(LINK_SET, K_TPE_PUBLIC_CTRL, TPE_PUBLIC_DISABLE, NULL_KEY);
                /* Owner gets a single OK, then end */
                begin_dialog(Initiator, "final_ack", "TPE Mode has been disabled.", ["OK"]);
                return;
            } else {
                show_main_menu(Initiator);
                return;
            }
        }

        /* TERMINAL ACK (wearer after enable OR owner after disable) */
        else if (Ctx == "final_ack") {
            if (message == "OK") {
                end_session(); /* Do NOT reopen any menu */
                return;
            }
            end_session();
            return;
        }
    }

    timer() { end_session(); }

    changed(integer change) { if (change & CHANGED_OWNER) llResetScript(); }
}
