/* =============================================================
   PLUGIN: ds_collar_owner.lsl (DS Collar Canonical, Strict LSL)
   PURPOSE: Owner Control and Management Plugin (Core 1.4+)
   AUTHOR:  [Your Project/Name]
   DATE:    2025-08-02
   ============================================================= */

/* -------- CANONICAL PROTOCOL CONSTANTS -------- */
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";

/* -------- PLUGIN PARAMETERS -------- */
string  PLUGIN_CONTEXT      = "core_owner";
string  ROOT_CONTEXT        = "core_root";
string  PLUGIN_LABEL        = "Owner";
integer PLUGIN_MIN_ACL      = 1;
integer PLUGIN_SN           = 0;

/* -------- CHANNELS -------- */
integer PLUGIN_REG_QUERY_NUM = 500;
integer PLUGIN_REG_REPLY_NUM = 501;
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;
integer UI_SHOW_MENU_NUM     = 601;

/* -------- UI CONSTANTS -------- */
string  BACK_BTN_LABEL   = "Back";
string  FILLER_BTN_LABEL = "~";
string  YES_LABEL        = "Yes";
string  NO_LABEL         = "No";
string  CANCEL_LABEL     = "Cancel";
string  OK_LABEL         = "OK";
integer DIALOG_TIMEOUT   = 180;

/* -------- SESSION STATE -------- */
key     sess_user        = NULL_KEY;
integer sess_chan        = 0;
integer sess_listen      = 0;
string  sess_context     = "";
string  sess_param1      = "";
string  sess_param2      = "";
string  sess_stepdata    = "";

/* -------- OWNER/STATE MIRROR -------- */
key     collar_owner = NULL_KEY;
string  collar_owner_honorific = "";
integer collar_locked = FALSE;
integer collar_public_access = FALSE;
list    collar_trustees = [];
list    collar_trustee_honorifics = [];

/* -------- HELPERS -------- */
list owner_honorifics() {
    return ["Master", "Mistress", "Daddy", "Mommy", "King", "Queen"];
}
list make_yes_no_cancel() { return [YES_LABEL, NO_LABEL, CANCEL_LABEL]; }
list make_ok_only() { return [OK_LABEL]; }
string wearer_display_name() {
    // Display name of the collar wearer (llGetDisplayName is not in LSL; use llKey2Name)
    return llKey2Name(llGetOwner());
}
string candidate_display_name(key candidate) {
    return llKey2Name(candidate);
}
string owner_display_name() {
    return candidate_display_name(collar_owner);
}

/* -------- STATE SYNC WITH CORE/SETTINGS -------- */
update_from_settings(list parts) {
    // settings_sync|owner|owner_hon|trustees_csv|trustees_hon_csv|unused|public_access|locked
    if (llGetListLength(parts) < 8) return;
    collar_owner = (key)llList2String(parts, 1);
    collar_owner_honorific = llList2String(parts, 2);
    string trustees_csv = llList2String(parts, 3);
    string trustees_hon_csv = llList2String(parts, 4);
    string pub_str = llList2String(parts, 6);
    string lock_str = llList2String(parts, 7);

    if (trustees_csv == " ") {
        collar_trustees = [];
    } else {
        collar_trustees = llParseString2List(trustees_csv, [","], []);
    }
    if (trustees_hon_csv == " ") {
        collar_trustee_honorifics = [];
    } else {
        collar_trustee_honorifics = llParseString2List(trustees_hon_csv, [","], []);
    }
    if (pub_str == "1") {
        collar_public_access = TRUE;
    } else {
        collar_public_access = FALSE;
    }
    if (lock_str == "1") {
        collar_locked = TRUE;
    } else {
        collar_locked = FALSE;
    }
}
sync_state_to_core() {
    string owner_hon = collar_owner_honorific;
    if (owner_hon == "") owner_hon = " ";
    string trust_csv = llDumpList2String(collar_trustees, ",");
    if (llGetListLength(collar_trustees) == 0) trust_csv = " ";
    string trust_hon_csv = llDumpList2String(collar_trustee_honorifics, ",");
    if (llGetListLength(collar_trustee_honorifics) == 0) trust_hon_csv = " ";
    string pub_str;
    if (collar_public_access == TRUE) {
        pub_str = "1";
    } else {
        pub_str = "0";
    }
    string lock_str;
    if (collar_locked == TRUE) {
        lock_str = "1";
    } else {
        lock_str = "0";
    }
    string msg = SETTINGS_SYNC_MSG_START + "|" +
        (string)collar_owner + "|" + owner_hon + "|" +
        trust_csv + "|" + trust_hon_csv + "|" +
        " " + "|" + pub_str + "|" + lock_str;
    llMessageLinked(LINK_SET, SETTINGS_SYNC_NUM, msg, NULL_KEY);
}

/* -------- PLUGIN REGISTRATION -------- */
register_plugin() {
    string msg = REGISTER_MSG_START + "|" +
                 (string)PLUGIN_SN + "|" +
                 PLUGIN_LABEL + "|" +
                 (string)PLUGIN_MIN_ACL + "|" +
                 PLUGIN_CONTEXT + "|" +
                 llGetScriptName();
    llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, msg, NULL_KEY);
}

/* -------- SESSION CLEANUP -------- */
cleanup_session() {
    if (sess_listen != 0) {
        llListenRemove(sess_listen);
    }
    sess_listen = 0;
    sess_user = NULL_KEY;
    sess_chan = 0;
    sess_context = "";
    sess_param1 = "";
    sess_param2 = "";
    sess_stepdata = "";
    llSetTimerEvent(0.0);
}

/* -------- MAIN MENU DISPLAY -------- */
show_plugin_menu(key avatar) {
    list btns;
    integer show_add_owner = FALSE;
    integer show_transfer = FALSE;
    integer show_release = FALSE;
    integer show_runaway = FALSE;

    // Add Owner: ONLY for unowned wearer (no owner assigned, avatar is the wearer)
    if (collar_owner == NULL_KEY && avatar == llGetOwner()) {
        show_add_owner = TRUE;
    }

    // Transfer/Release: ONLY for primary owner
    if (collar_owner != NULL_KEY && avatar == collar_owner) {
        show_transfer = TRUE;
        show_release = TRUE;
    }

    // Runaway: ONLY for owned wearer (not for owner or unowned)
    if (collar_owner != NULL_KEY && avatar == llGetOwner()) {
        show_runaway = TRUE;
    }

    if (show_add_owner == TRUE) {
        btns += ["Add Owner"];
    }
    if (show_transfer == TRUE) {
        btns += ["Transfer Sub"];
    }
    if (show_release == TRUE) {
        btns += ["Release Sub"];
    }
    if (show_runaway == TRUE) {
        btns += ["Runaway"];
    }
    btns += [BACK_BTN_LABEL];
    while (llGetListLength(btns) % 3 != 0) {
        btns += FILLER_BTN_LABEL;
    }

    integer menu_chan = -(integer)llFrand(1000000.0) - 100000;
    if (sess_listen != 0) {
        llListenRemove(sess_listen);
    }
    sess_listen = llListen(menu_chan, "", avatar, "");
    sess_user = avatar;
    sess_chan = menu_chan;
    sess_context = PLUGIN_CONTEXT;
    sess_param1 = "";
    sess_param2 = "";
    sess_stepdata = "";
    llDialog(avatar, "Owner Management Menu:", btns, menu_chan);
    llSetTimerEvent((float)DIALOG_TIMEOUT);
}

/* -------- MAIN MENU RETURN -------- */
return_to_main_menu(key avatar) {
    string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)avatar + "|0";
    llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
}

/* -------- FLOW HANDLERS -------- */
// --- Add Owner (Edge Case a)
begin_add_owner(key avatar, integer chan) {
    // Sensor to find candidate
    llSensor("", NULL_KEY, AGENT, 20.0, PI * 2);
    sess_user = avatar;
    sess_chan = chan;
    sess_context = "add_owner_select";
    sess_param1 = "";
    sess_param2 = "";
    sess_stepdata = "";
}
// --- Transfer Sub (Edge Case b)
begin_transfer_sub(key avatar, integer chan) {
    llSensor("", NULL_KEY, AGENT, 20.0, PI * 2);
    sess_user = avatar;
    sess_chan = chan;
    sess_context = "transfer_select";
    sess_param1 = "";
    sess_param2 = "";
    sess_stepdata = "";
}
// --- Release Sub (Edge Case c)
begin_release_sub(key avatar, integer chan) {
    sess_user = avatar;
    sess_chan = chan;
    sess_context = "release_owner_confirm";
    sess_param1 = "";
    sess_param2 = "";
    sess_stepdata = "";
    llDialog(avatar, "Are you sure you want to relinquish your claim as " + wearer_display_name() + "'s " + collar_owner_honorific + "? They will be free if you confirm.", make_yes_no_cancel(), chan);
}
// --- Runaway (Edge Case d)
begin_runaway(key avatar, integer chan) {
    sess_user = avatar;
    sess_chan = chan;
    sess_context = "runaway_confirm";
    sess_param1 = "";
    sess_param2 = "";
    sess_stepdata = "";
    llDialog(avatar, "You are about to run away from your " + collar_owner_honorific + ", " + owner_display_name() + ". Please confirm your decision.", make_yes_no_cancel(), chan);
}

/* =============================================================
   MAIN EVENT LOOP
   ============================================================= */
default
{
    state_entry() {
        PLUGIN_SN = 100000 + (integer)(llFrand(899999));
        register_plugin();
        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);
    }
    link_message(integer sender, integer num, string str, key id)
    {
        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG_START) {
                update_from_settings(parts);
            }
            return;
        }
        if (num == UI_SHOW_MENU_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 3) {
                string ctx = llList2String(parts, 1);
                key avatar = (key)llList2String(parts, 2);
                if (ctx == PLUGIN_CONTEXT) {
                    show_plugin_menu(avatar);
                    return;
                }
            }
        }
        if ((num == PLUGIN_REG_QUERY_NUM) && llSubStringIndex(str, REGISTER_NOW_MSG_START + "|") == 0) {
            string script_req = llGetSubString(str, llStringLength(REGISTER_NOW_MSG_START) + 1, -1);
            if (script_req == llGetScriptName()) {
                register_plugin();
            }
        }
    }
    listen(integer channel, string name, key id, string msg)
    {
        if (channel != sess_chan || id != sess_user) return;

        // MAIN MENU
        if (sess_context == PLUGIN_CONTEXT) {
            if (msg == "Add Owner") {
                begin_add_owner(id, channel);
                return;
            }
            if (msg == "Transfer Sub") {
                begin_transfer_sub(id, channel);
                return;
            }
            if (msg == "Release Sub") {
                begin_release_sub(id, channel);
                return;
            }
            if (msg == "Runaway") {
                begin_runaway(id, channel);
                return;
            }
            if (msg == BACK_BTN_LABEL) {
                return_to_main_menu(id);
                cleanup_session();
                return;
            }
        }

        // ADD OWNER FLOW
        if (sess_context == "add_owner_select") {
            // Candidate selection (from sensor)
            list keys = llParseString2List(sess_stepdata, [","], []);
            integer picked_index = (integer)msg - 1;
            if (picked_index >= 0 && picked_index < llGetListLength(keys)) {
                key candidate_key = llList2Key(keys, picked_index);
                // Ask candidate for approval, honorific selection
                list honors = owner_honorifics();
                string dialog_body = wearer_display_name() + " wishes to submit to you as their owner. Choose the honorific you wish to be called.";
                list buttons = [];
                integer i = 0;
                while (i < llGetListLength(honors)) {
                    buttons += llList2String(honors, i);
                    i = i + 1;
                }
                while (llGetListLength(buttons) % 3 != 0) {
                    buttons += FILLER_BTN_LABEL;
                }
                sess_context = "add_owner_honorific";
                sess_param1 = (string)candidate_key;
                sess_param2 = "";
                sess_stepdata = llDumpList2String(honors, ",");
                llDialog(candidate_key, dialog_body, buttons, channel);
                return;
            }
        }
        if (sess_context == "add_owner_honorific") {
            list honors = llParseString2List(sess_stepdata, [","], []);
            integer sel_index = llListFindList(honors, [msg]);
            if (sel_index != -1) {
                key candidate_key = (key)sess_param1;
                string chosen_honorific = llList2String(honors, sel_index);
                // Candidate owner confirms
                sess_context = "add_owner_candidate_confirm";
                sess_param2 = chosen_honorific;
                llDialog(candidate_key, wearer_display_name() + " has submitted to you as their " + chosen_honorific + ". Accept?", make_yes_no_cancel(), channel);
                return;
            }
        }
        if (sess_context == "add_owner_candidate_confirm") {
            if (msg == YES_LABEL) {
                // Ask wearer for confirmation
                key candidate_key = (key)sess_param1;
                string chosen_honorific = sess_param2;
                sess_context = "add_owner_wearer_confirm";
                llDialog(llGetOwner(), "You have submitted to " + candidate_display_name(candidate_key) + " as your " + chosen_honorific + ". Confirm?", make_yes_no_cancel(), channel);
                return;
            }
            if (msg == NO_LABEL || msg == CANCEL_LABEL) {
                cleanup_session();
                return;
            }
        }
        if (sess_context == "add_owner_wearer_confirm") {
            if (msg == YES_LABEL) {
                key candidate_key = (key)sess_param1;
                string chosen_honorific = sess_param2;
                // Complete: assign owner, update state, notify both
                collar_owner = candidate_key;
                collar_owner_honorific = chosen_honorific;
                sync_state_to_core();
                llDialog(candidate_key, wearer_display_name() + " has submitted to you as their \"" + chosen_honorific + "\".", make_ok_only(), channel);
                llDialog(llGetOwner(), "You have submitted to " + candidate_display_name(candidate_key) + " as your " + chosen_honorific + ".", make_ok_only(), channel);
                cleanup_session();
                return;
            }
            if (msg == NO_LABEL || msg == CANCEL_LABEL) {
                cleanup_session();
                return;
            }
        }

        // TRANSFER SUB FLOW
        if (sess_context == "transfer_select") {
            // Candidate selection (from sensor)
            list keys = llParseString2List(sess_stepdata, [","], []);
            integer picked_index = (integer)msg - 1;
            if (picked_index >= 0 && picked_index < llGetListLength(keys)) {
                key new_owner_key = llList2Key(keys, picked_index);
                // Ask new owner for approval, honorific selection
                list honors = owner_honorifics();
                string dialog_body = "You have been offered ownership of " + wearer_display_name() + ". Choose the honorific you wish to be called.";
                list buttons = [];
                integer i = 0;
                while (i < llGetListLength(honors)) {
                    buttons += llList2String(honors, i);
                    i = i + 1;
                }
                while (llGetListLength(buttons) % 3 != 0) {
                    buttons += FILLER_BTN_LABEL;
                }
                sess_context = "transfer_honorific";
                sess_param1 = (string)new_owner_key;
                sess_param2 = "";
                sess_stepdata = llDumpList2String(honors, ",");
                llDialog(new_owner_key, dialog_body, buttons, channel);
                return;
            }
        }
        if (sess_context == "transfer_honorific") {
            list honors = llParseString2List(sess_stepdata, [","], []);
            integer sel_index = llListFindList(honors, [msg]);
            if (sel_index != -1) {
                key new_owner_key = (key)sess_param1;
                string chosen_honorific = llList2String(honors, sel_index);
                sess_context = "transfer_confirm_new_owner";
                sess_param2 = chosen_honorific;
                llDialog(new_owner_key, "You are about to take ownership of " + wearer_display_name() + " as their " + chosen_honorific + ". Accept?", make_yes_no_cancel(), channel);
                return;
            }
        }
        if (sess_context == "transfer_confirm_new_owner") {
            if (msg == YES_LABEL) {
                key new_owner_key = (key)sess_param1;
                string chosen_honorific = sess_param2;
                key old_owner_key = collar_owner;
                // Complete: assign new owner, update state, notify both
                collar_owner = new_owner_key;
                collar_owner_honorific = chosen_honorific;
                sync_state_to_core();
                llDialog(old_owner_key, "You have transferred your sub " + wearer_display_name() + " to the hands of " + candidate_display_name(new_owner_key) + " as their " + chosen_honorific + ".", make_ok_only(), channel);
                llDialog(new_owner_key, "You are now the owner of " + wearer_display_name() + " as their " + chosen_honorific + ".", make_ok_only(), channel);
                cleanup_session();
                return;
            }
            if (msg == NO_LABEL || msg == CANCEL_LABEL) {
                cleanup_session();
                return;
            }
        }

        // RELEASE SUB FLOW
        if (sess_context == "release_owner_confirm") {
            if (msg == YES_LABEL) {
                // Ask wearer for confirmation
                sess_context = "release_wearer_confirm";
                llDialog(llGetOwner(), "You have been released as " + collar_owner_honorific + " " + owner_display_name() + "'s submissive. You are now free.", make_yes_no_cancel(), channel);
                return;
            }
            if (msg == NO_LABEL || msg == CANCEL_LABEL) {
                cleanup_session();
                return;
            }
        }
        if (sess_context == "release_wearer_confirm") {
            if (msg == YES_LABEL) {
                // Complete: remove owner, update state, notify both
                key old_owner = collar_owner;
                string old_honorific = collar_owner_honorific;
                collar_owner = NULL_KEY;
                collar_owner_honorific = "";
                sync_state_to_core();
                llDialog(old_owner, "You have relinquished your claim as " + wearer_display_name() + "'s " + old_honorific + ". They are now free.", make_ok_only(), channel);
                llDialog(llGetOwner(), "You have been released as " + old_honorific + " " + candidate_display_name(old_owner) + "'s submissive. You are now free.", make_ok_only(), channel);
                cleanup_session();
                return;
            }
            if (msg == NO_LABEL || msg == CANCEL_LABEL) {
                cleanup_session();
                return;
            }
        }

        // RUNAWAY FLOW
        if (sess_context == "runaway_confirm") {
            if (msg == YES_LABEL) {
                // Complete: remove owner, update state, notify wearer
                collar_owner = NULL_KEY;
                collar_owner_honorific = "";
                sync_state_to_core();
                llDialog(id, "You have run away and are now unowned.", make_ok_only(), channel);
                cleanup_session();
                return;
            }
            if (msg == NO_LABEL || msg == CANCEL_LABEL) {
                cleanup_session();
                return;
            }
        }
    }
    sensor(integer n)
    {
        // Only for add_owner_select or transfer_select
        if (sess_context == "add_owner_select" || sess_context == "transfer_select") {
            list candidates = [];
            integer i = 0;
            while (i < n) {
                key candidate_key = llDetectedKey(i);
                if (candidate_key != sess_user && candidate_key != collar_owner) {
                    candidates += candidate_key;
                }
                i = i + 1;
            }
            if (llGetListLength(candidates) == 0) {
                llDialog(sess_user, "No valid candidates found within 20m.", make_ok_only(), sess_chan);
                cleanup_session();
                return;
            }
            list names = [];
            i = 0;
            while (i < llGetListLength(candidates)) {
                names += llKey2Name(llList2Key(candidates, i));
                i = i + 1;
            }
            string dialog_body = "Select candidate:\n";
            i = 0;
            while (i < llGetListLength(names)) {
                dialog_body += (string)(i + 1) + ". " + llList2String(names, i) + "\n";
                i = i + 1;
            }
            list buttons = [];
            i = 0;
            while (i < llGetListLength(names)) {
                buttons += (string)(i + 1);
                i = i + 1;
            }
            while (llGetListLength(buttons) % 3 != 0) {
                buttons += FILLER_BTN_LABEL;
            }
            sess_stepdata = llDumpList2String(candidates, ",");
            llDialog(sess_user, dialog_body, buttons, sess_chan);
        }
    }
    no_sensor() {
        if (sess_context == "add_owner_select" || sess_context == "transfer_select") {
            llDialog(sess_user, "No avatars found nearby.", make_ok_only(), sess_chan);
            cleanup_session();
        }
    }
    timer() {
        cleanup_session();
    }
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
/* ============================================================= */
