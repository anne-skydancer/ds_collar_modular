// =============================================================
//  PLUGIN: ds_collar_plugin_rlv_exceptions.lsl (Canonical, DS Collar 1.4+)
//  PURPOSE: RLV Owner/Trustee Exceptions, persistent, canonical protocol
//  DATE:    2025-08-01 (Flat "Back" routing as specified, full compliance)
// =============================================================

integer DEBUG = TRUE;

// --- Kernel / settings link numbers ---
integer K_PLUGIN_REG_QUERY   = 500;  // Kernel → Plugin : {"type":"register_now","script":...}
integer K_PLUGIN_REG_REPLY   = 501;  // Plugin  → Kernel: {"type":"register",...}
integer K_SETTINGS_QUERY     = 800;  // Plugin ↔ Settings
integer K_SETTINGS_SYNC      = 870;  // Settings → Plugin
integer K_PLUGIN_START       = 900;  // UI → Plugin : {"type":"plugin_start",...}
integer K_PLUGIN_RETURN      = 901;  // Plugin → UI   : {"type":"plugin_return",...}

// --- Canonical message tokens ---
string TYPE_REGISTER       = "register";
string TYPE_REGISTER_NOW   = "register_now";
string TYPE_PLUGIN_START   = "plugin_start";
string TYPE_PLUGIN_RETURN  = "plugin_return";
string TYPE_SETTINGS_GET   = "settings_get";
string TYPE_SETTINGS_SET   = "set";
string TYPE_SETTINGS_SYNC  = "settings_sync";

string PLUGIN_CONTEXT      = "core_rlv_exceptions";
string ROOT_CONTEXT        = "core_root";

integer PLUGIN_SN        = 0;
string  PLUGIN_LABEL     = "Exceptions";
integer PLUGIN_MIN_ACL   = 1;

// Submenu context labels
string CTX_MAIN         = "main";
string CTX_OWNER        = "owner";
string CTX_OWNER_IM     = "owner_im";
string CTX_OWNER_TP     = "owner_tp";
string CTX_TRUSTEE      = "trustee";
string CTX_TRUSTEE_IM   = "trustee_im";
string CTX_TRUSTEE_TP   = "trustee_tp";

// Exception state (persistent)
integer ExOwnerIm      = TRUE;   // Owner IM allowed
integer ExOwnerTp      = TRUE;   // Owner force TP allowed
integer ExTrusteeIm    = TRUE;   // Trustee IM allowed
integer ExTrusteeTp    = FALSE;  // Trustee TP allowed (default FALSE!)

// Settings keys
string EX_OWNER_IM_KEY      = "ex_owner_im";
string EX_OWNER_TP_KEY      = "ex_owner_tp";
string EX_TRUSTEE_IM_KEY    = "ex_trustee_im";
string EX_TRUSTEE_TP_KEY    = "ex_trustee_tp";

// Session helpers (Animate/Status)
list    Sessions;
integer s_idx(key av) { return llListFindList(Sessions, [av]); }
integer s_set(key av, integer page, string csv, float expiry, string ctx, string param, string step, string menucsv, integer chan)
{
    integer i = s_idx(av);
    if (~i) {
        integer old = llList2Integer(Sessions, i+9);
        if (old != -1) llListenRemove(old);
        Sessions = llDeleteSubList(Sessions, i, i+9);
    }
    integer lh = llListen(chan, "", av, "");
    Sessions += [av, page, csv, expiry, ctx, param, step, menucsv, chan, lh];
    return TRUE;
}
integer s_clear(key av)
{
    integer i = s_idx(av);
    if (~i) {
        integer old = llList2Integer(Sessions, i+9);
        if (old != -1) llListenRemove(old);
        Sessions = llDeleteSubList(Sessions, i, i+9);
    }
    return TRUE;
}
list s_get(key av)
{
    integer i = s_idx(av);
    if (~i) return llList2List(Sessions, i, i+9);
    return [];
}

integer json_has(string j, list path)
{
    if (llJsonGetValue(j, path) == JSON_INVALID) return FALSE;
    return TRUE;
}

integer register_plugin()
{
    string payload = llList2Json(JSON_OBJECT, []);
    payload = llJsonSetValue(payload, ["type"],    TYPE_REGISTER);
    payload = llJsonSetValue(payload, ["sn"],      (string)PLUGIN_SN);
    payload = llJsonSetValue(payload, ["label"],   PLUGIN_LABEL);
    payload = llJsonSetValue(payload, ["min_acl"], (string)PLUGIN_MIN_ACL);
    payload = llJsonSetValue(payload, ["context"], PLUGIN_CONTEXT);
    payload = llJsonSetValue(payload, ["script"],  llGetScriptName());
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, payload, NULL_KEY);
    if (DEBUG) llOwnerSay("[RLVEX] Registered → kernel.");
    return TRUE;
}

integer request_settings_get()
{
    string payload = llList2Json(JSON_OBJECT, []);
    payload = llJsonSetValue(payload, ["type"], TYPE_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, payload, NULL_KEY);
    if (DEBUG) llOwnerSay("[RLVEX] Requested settings_get.");
    return TRUE;
}

integer persist_exception(string pname, integer value)
{
    if (value != 0) value = 1;
    string payload = llList2Json(JSON_OBJECT, []);
    payload = llJsonSetValue(payload, ["type"],  TYPE_SETTINGS_SET);
    payload = llJsonSetValue(payload, ["key"],   pname);
    payload = llJsonSetValue(payload, ["value"], (string)value);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, payload, NULL_KEY);
    if (DEBUG) llOwnerSay("[RLVEX] Persisted: " + pname + "=" + (string)value);
    return TRUE;
}

integer apply_settings_sync(string payload)
{
    if (!json_has(payload, ["type"])) return FALSE;
    if (llJsonGetValue(payload, ["type"]) != TYPE_SETTINGS_SYNC) return FALSE;
    if (!json_has(payload, ["kv"])) return FALSE;

    string kv = llJsonGetValue(payload, ["kv"]);

    string value;

    value = llJsonGetValue(kv, [EX_OWNER_IM_KEY]);
    if (value != JSON_INVALID) {
        if ((integer)value != 0) ExOwnerIm = TRUE; else ExOwnerIm = FALSE;
    }

    value = llJsonGetValue(kv, [EX_OWNER_TP_KEY]);
    if (value != JSON_INVALID) {
        if ((integer)value != 0) ExOwnerTp = TRUE; else ExOwnerTp = FALSE;
    }

    value = llJsonGetValue(kv, [EX_TRUSTEE_IM_KEY]);
    if (value != JSON_INVALID) {
        if ((integer)value != 0) ExTrusteeIm = TRUE; else ExTrusteeIm = FALSE;
    }

    value = llJsonGetValue(kv, [EX_TRUSTEE_TP_KEY]);
    if (value != JSON_INVALID) {
        if ((integer)value != 0) ExTrusteeTp = TRUE; else ExTrusteeTp = FALSE;
    }

    if (DEBUG) {
        llOwnerSay("[RLVEX] Settings sync: ownerIM=" + (string)ExOwnerIm +
                   " ownerTP=" + (string)ExOwnerTp +
                   " trusteeIM=" + (string)ExTrusteeIm +
                   " trusteeTP=" + (string)ExTrusteeTp);
    }
    return TRUE;
}

integer send_plugin_return(key user)
{
    string payload = llList2Json(JSON_OBJECT, []);
    payload = llJsonSetValue(payload, ["type"],    TYPE_PLUGIN_RETURN);
    payload = llJsonSetValue(payload, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN, payload, user);
    if (DEBUG) llOwnerSay("[RLVEX] Return → root for " + (string)user);
    return TRUE;
}

// === UI helpers for each menu level ===
show_main_menu(key user)
{
    list btns = ["~", "Back", "~", "Owner", "~", "Trustee"];
    while (llGetListLength(btns) % 3 != 0) btns += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, CTX_MAIN, "", "", "", menu_chan);

    string msg = "RLV Exceptions Menu\nChoose Owner or Trustee exceptions to manage.";
    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[RLVEX] Main menu → " + (string)user + " chan=" + (string)menu_chan);
}
show_owner_menu(key user)
{
    list btns = ["~", "Back", "~", "IM", "~", "TP"];
    while (llGetListLength(btns) % 3 != 0) btns += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, CTX_OWNER, "", "", "", menu_chan);

    string msg = "Owner Exceptions:\nChoose which exception to edit.";
    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[RLVEX] Owner menu → " + (string)user + " chan=" + (string)menu_chan);
}
show_trustee_menu(key user)
{
    list btns = ["~", "Back", "~", "IM", "~", "TP"];
    while (llGetListLength(btns) % 3 != 0) btns += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, CTX_TRUSTEE, "", "", "", menu_chan);

    string msg = "Trustee Exceptions:\nChoose which exception to edit.";
    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[RLVEX] Trustee menu → " + (string)user + " chan=" + (string)menu_chan);
}

show_exception_menu(key user, string ctx, string persist_key, string plus_label, string minus_label, integer current_val)
{
    list btns = ["~", "Back", "~", plus_label, "~", minus_label];
    while (llGetListLength(btns) % 3 != 0) btns += " ";
    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, ctx, persist_key, "", "", menu_chan);

    string msg = "";
    if (persist_key == EX_OWNER_IM_KEY)
        msg = "Owner IM Exception:\n";
    else if (persist_key == EX_OWNER_TP_KEY)
        msg = "Owner TP Exception:\n";
    else if (persist_key == EX_TRUSTEE_IM_KEY)
        msg = "Trustee IM Exception:\n";
    else if (persist_key == EX_TRUSTEE_TP_KEY)
        msg = "Trustee TP Exception:\n";
    if (current_val)
        msg += "Current: ALLOWED\n";
    else
        msg += "Current: DENIED\n";
    msg += "\nChoose to allow (+) or deny (-).";
    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[RLVEX] Exception menu ("+ctx+") → " + (string)user + " chan=" + (string)menu_chan);
}

// --- MAIN EVENT LOOP ---
default
{
    state_entry()
    {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        register_plugin();
        request_settings_get();

        if (DEBUG) llOwnerSay("[RLVEX] Ready, SN=" + (string)PLUGIN_SN);
    }

    link_message(integer sender, integer num, string str, key id)
    {
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == TYPE_REGISTER_NOW) {
                if (json_has(str, ["script"]) && llJsonGetValue(str, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        if (num == K_SETTINGS_SYNC) {
            apply_settings_sync(str);
            return;
        }

        if (num == K_PLUGIN_START) {
            if (json_has(str, ["type"]) && llJsonGetValue(str, ["type"]) == TYPE_PLUGIN_START) {
                if (json_has(str, ["context"]) && llJsonGetValue(str, ["context"]) == PLUGIN_CONTEXT) {
                    key user = id;
                    if (json_has(str, ["avatar"])) {
                        user = (key)llJsonGetValue(str, ["avatar"]);
                    }
                    if (user != NULL_KEY) {
                        show_main_menu(user);
                    }
                }
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string msg)
    {
        list sess = s_get(id);
        if (llGetListLength(sess) == 10 && chan == llList2Integer(sess, 8)) {
            string ctx = llList2String(sess, 4);
            string persist_key = llList2String(sess, 5);

            // --- Back button logic (flat, as specified) ---
            if (msg == "Back") {
                if (ctx == CTX_MAIN) {
                    // From plugin main menu: Back → root via plugin_return
                    s_clear(id);
                    send_plugin_return(id);
                    return;
                } else {
                    // From any other submenu, Back → plugin main menu
                    show_main_menu(id);
                    return;
                }
            }

            // --- Main menu navigation
            if (ctx == CTX_MAIN) {
                if (msg == "Owner") {
                    show_owner_menu(id);
                    return;
                }
                if (msg == "Trustee") {
                    show_trustee_menu(id);
                    return;
                }
            }
            // Owner submenu
            else if (ctx == CTX_OWNER) {
                if (msg == "IM") {
                    show_exception_menu(id, CTX_OWNER_IM, EX_OWNER_IM_KEY, "Owner IM +", "Owner IM -", ExOwnerIm);
                    return;
                }
                if (msg == "TP") {
                    show_exception_menu(id, CTX_OWNER_TP, EX_OWNER_TP_KEY, "Owner TP +", "Owner TP -", ExOwnerTp);
                    return;
                }
            }
            // Trustee submenu
            else if (ctx == CTX_TRUSTEE) {
                if (msg == "IM") {
                    show_exception_menu(id, CTX_TRUSTEE_IM, EX_TRUSTEE_IM_KEY, "Trust IM +", "Trust IM -", ExTrusteeIm);
                    return;
                }
                if (msg == "TP") {
                    show_exception_menu(id, CTX_TRUSTEE_TP, EX_TRUSTEE_TP_KEY, "Trust TP +", "Trust TP -", ExTrusteeTp);
                    return;
                }
            }
            // Owner IM/TP and Trustee IM/TP submenus
            else if (ctx == CTX_OWNER_IM || ctx == CTX_OWNER_TP ||
                     ctx == CTX_TRUSTEE_IM || ctx == CTX_TRUSTEE_TP) {

                // For any exception +/- button, update value and show this menu again
                if (msg == "Owner IM +" && ctx == CTX_OWNER_IM) {
                    ExOwnerIm = TRUE;
                    persist_exception(EX_OWNER_IM_KEY, ExOwnerIm);
                    show_exception_menu(id, CTX_OWNER_IM, EX_OWNER_IM_KEY, "Owner IM +", "Owner IM -", ExOwnerIm);
                    return;
                }
                if (msg == "Owner IM -" && ctx == CTX_OWNER_IM) {
                    ExOwnerIm = FALSE;
                    persist_exception(EX_OWNER_IM_KEY, ExOwnerIm);
                    show_exception_menu(id, CTX_OWNER_IM, EX_OWNER_IM_KEY, "Owner IM +", "Owner IM -", ExOwnerIm);
                    return;
                }
                if (msg == "Owner TP +" && ctx == CTX_OWNER_TP) {
                    ExOwnerTp = TRUE;
                    persist_exception(EX_OWNER_TP_KEY, ExOwnerTp);
                    show_exception_menu(id, CTX_OWNER_TP, EX_OWNER_TP_KEY, "Owner TP +", "Owner TP -", ExOwnerTp);
                    return;
                }
                if (msg == "Owner TP -" && ctx == CTX_OWNER_TP) {
                    ExOwnerTp = FALSE;
                    persist_exception(EX_OWNER_TP_KEY, ExOwnerTp);
                    show_exception_menu(id, CTX_OWNER_TP, EX_OWNER_TP_KEY, "Owner TP +", "Owner TP -", ExOwnerTp);
                    return;
                }
                if (msg == "Trust IM +" && ctx == CTX_TRUSTEE_IM) {
                    ExTrusteeIm = TRUE;
                    persist_exception(EX_TRUSTEE_IM_KEY, ExTrusteeIm);
                    show_exception_menu(id, CTX_TRUSTEE_IM, EX_TRUSTEE_IM_KEY, "Trust IM +", "Trust IM -", ExTrusteeIm);
                    return;
                }
                if (msg == "Trust IM -" && ctx == CTX_TRUSTEE_IM) {
                    ExTrusteeIm = FALSE;
                    persist_exception(EX_TRUSTEE_IM_KEY, ExTrusteeIm);
                    show_exception_menu(id, CTX_TRUSTEE_IM, EX_TRUSTEE_IM_KEY, "Trust IM +", "Trust IM -", ExTrusteeIm);
                    return;
                }
                if (msg == "Trust TP +" && ctx == CTX_TRUSTEE_TP) {
                    ExTrusteeTp = TRUE;
                    persist_exception(EX_TRUSTEE_TP_KEY, ExTrusteeTp);
                    show_exception_menu(id, CTX_TRUSTEE_TP, EX_TRUSTEE_TP_KEY, "Trust TP +", "Trust TP -", ExTrusteeTp);
                    return;
                }
                if (msg == "Trust TP -" && ctx == CTX_TRUSTEE_TP) {
                    ExTrusteeTp = FALSE;
                    persist_exception(EX_TRUSTEE_TP_KEY, ExTrusteeTp);
                    show_exception_menu(id, CTX_TRUSTEE_TP, EX_TRUSTEE_TP_KEY, "Trust TP +", "Trust TP -", ExTrusteeTp);
                    return;
                }
            }
        }
    }

    timer()
    {
        integer now = llGetUnixTime();
        integer i = 0;
        while (i < llGetListLength(Sessions)) {
            float exp = llList2Float(Sessions, i+3);
            key av = llList2Key(Sessions, i);
            if (now > exp) {
                s_clear(av);
            } else {
                i += 10;
            }
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[RLVEX] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }
}
