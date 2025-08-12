/* =============================================================
   PLUGIN: ds_collar_plugin_animate.lsl  (authoritative GUH logic)
   PURPOSE: Paginated animation menu with << / Back / >> / Relax,
            tested inventory-driven flow, heartbeat + soft reset,
            and ACL gate (allowed: 1,2,3,4,5).
   NOTES:
     - One private negative dialog channel per session.
     - Requests PERMISSION_TRIGGER_ANIMATION once per avatar.
     - No ternaries; constants match your global “magic words”.
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Authoritative ACL constants ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0; // No wearer access
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* Allowed ACLs for Animate: 1,2,3,4,5 */
list ALLOWED_ACLS = [ACL_PUBLIC, ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY   = 500; // Kernel → Plugins: {"type":"register_now","script":"<name>"}
integer K_PLUGIN_REG_REPLY   = 501; // Plugins → Kernel: {"type":"register",...}
integer K_PLUGIN_SOFT_RESET  = 504; // Plugins → Kernel: {"type":"plugin_soft_reset","context":...}

integer K_PLUGIN_PING        = 650; // Kernel → Plugins: {"type":"plugin_ping","context":...}
integer K_PLUGIN_PONG        = 651; // Plugins → Kernel: {"type":"plugin_pong","context":...}

integer AUTH_QUERY_NUM       = 700; // to Auth: {"type":"acl_query","avatar":"<key>"}
integer AUTH_RESULT_NUM      = 710; // from Auth: {"type":"acl_result","avatar":"<key>","level":"<int>"}

integer K_PLUGIN_START       = 900; // UI → Plugins   : {"type":"plugin_start","context":...}
integer K_PLUGIN_RETURN_NUM  = 901; // Plugins → UI   : {"type":"plugin_return","context":"core_root"}

/* ---------- Shared “magic words” ---------- */
string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_REGISTER_NOW      = "register_now";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";

string CONS_MSG_ACL_QUERY          = "acl_query";
string CONS_MSG_ACL_RESULT         = "acl_result";

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT = "core_animate";  // MUST match kernel/UI
string  ROOT_CONTEXT   = "core_root";
string  PLUGIN_LABEL   = "Animate";
integer PLUGIN_SN      = 0;
integer PLUGIN_MIN_ACL = 1;               // public-visible; runtime ACL enforces 1–5

/* ---------- Menu setup ---------- */
string BACK_BTN_LABEL = "Back";
integer MENU_TIMEOUT  = 180;
integer PAGE_SIZE     = 8; // anims per page (indices 4–11)

/* ---------- State ---------- */
integer g_has_perm     = FALSE;
key     g_perm_avatar  = NULL_KEY;

list    g_anims        = [];
integer g_page         = 0;

key     g_user         = NULL_KEY;
integer g_listen       = 0;
integer g_menu_chan    = 0;
integer g_no_anims     = FALSE;

integer g_acl_level    = -99;   // cache last ACL
integer g_acl_pending  = FALSE;

/* ========================== Helpers ========================== */
integer json_has(string j, list path) { return (llJsonGetValue(j, path) != JSON_INVALID); }

integer logd(string s) {
    if (DEBUG) llOwnerSay("[ANIMATE] " + s);
    return 0;
}

integer acl_allowed(integer lvl) {
    if (llListFindList(ALLOWED_ACLS, [lvl]) != -1) return TRUE;
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

integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
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
    j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    logd("Soft reset notified.");
    return 0;
}

/* ---------- Anim helpers ---------- */
integer get_anims() {
    g_anims = [];
    integer n = llGetInventoryNumber(INVENTORY_ANIMATION);
    integer i = 0;
    while (i < n) {
        g_anims += llGetInventoryName(INVENTORY_ANIMATION, i);
        i += 1;
    }
    g_anims = llListSort(g_anims, 1, TRUE);
    return 0;
}

integer start_anim(string anim) {
    if (!g_has_perm || g_perm_avatar != g_user) {
        if (g_user != NULL_KEY) {
            llRequestPermissions(g_user, PERMISSION_TRIGGER_ANIMATION);
            logd("Requesting anim permission from " + (string)g_user);
        }
        else {
            llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION);
            logd("Requesting anim permission from wearer (no user set).");
        }
        return 0;
    }
    llStartAnimation(anim);
    logd("Playing animation: " + anim);
    show_menu(g_user, g_page);
    return 0;
}

integer stop_all_anims() {
    if (!g_has_perm || g_perm_avatar != g_user) {
        if (g_user != NULL_KEY) {
            llRequestPermissions(g_user, PERMISSION_TRIGGER_ANIMATION);
            logd("Requesting anim permission (Relax).");
        }
        return 0;
    }
    integer i = 0;
    integer n = llGetInventoryNumber(INVENTORY_ANIMATION);
    while (i < n) {
        llStopAnimation(llGetInventoryName(INVENTORY_ANIMATION, i));
        i += 1;
    }
    logd("Stopped all animations.");
    show_menu(g_user, g_page);
    return 0;
}

/* ---------- UI ---------- */
integer reset_listen() {
    if (g_listen) llListenRemove(g_listen);
    g_listen    = 0;
    g_menu_chan = 0;
    return 0;
}

integer show_menu(key user, integer page) {
    get_anims();
    integer total = llGetListLength(g_anims);

    if (total == 0) {
        g_no_anims = TRUE;
        reset_listen();
        integer ch = -100000 - (integer)llFrand(1000000.0);
        g_listen = llListen(ch, "", user, "");
        llDialog(user, "No animations in collar.", ["OK"], ch);
        g_user = user;
        g_page = 0;
        llSetTimerEvent((float)MENU_TIMEOUT);
        return 0;
    }

    g_no_anims = FALSE;

    if (page < 0) page = 0;
    g_page = page;

    integer start = page * PAGE_SIZE;
    integer end   = start + PAGE_SIZE - 1;
    if (end >= total) end = total - 1;

    list anim_btns = [];
    integer i = start;
    while (i <= end && i < total) {
        anim_btns += llList2String(g_anims, i);
        i += 1;
    }
    while (llGetListLength(anim_btns) < PAGE_SIZE) anim_btns += " ";

    string nav_prev = " ";
    if (page > 0) nav_prev = "<<";
    string nav_next = " ";
    if (end < total - 1) nav_next = ">>";

    list btns = [nav_prev, BACK_BTN_LABEL, nav_next, "Relax"] + anim_btns;
    while (llGetListLength(btns) < 12) btns += " ";

    reset_listen();
    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen    = llListen(g_menu_chan, "", user, "");

    llDialog(user,
        "Animations (Page " + (string)(page + 1) + "):\n"
        + "Select an animation, or Relax to stop all.",
        btns, g_menu_chan);

    g_user = user;
    llSetTimerEvent((float)MENU_TIMEOUT);

    logd("Menu → " + (string)user + " page=" + (string)page + " chan=" + (string)g_menu_chan);
    return 0;
}

/* =========================== Events ========================== */
default
{
    state_entry() {
        /* reset session */
        reset_listen();
        g_user        = NULL_KEY;
        g_page        = 0;
        g_has_perm    = FALSE;
        g_perm_avatar = NULL_KEY;
        g_acl_level   = -99;
        g_acl_pending = FALSE;

        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_plugin();

        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    run_time_permissions(integer perm) {
        if ((perm & PERMISSION_TRIGGER_ANIMATION) != 0) {
            g_has_perm    = TRUE;
            g_perm_avatar = g_user;
            logd("Animation permission granted by " + (string)g_perm_avatar);
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* Heartbeat */
        if (num == K_PLUGIN_PING) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_PING) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    string pong = llList2Json(JSON_OBJECT, []);
                    pong = llJsonSetValue(pong, ["type"],    CONS_TYPE_PLUGIN_PONG);
                    pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                }
            }
            return;
        }

        /* Kernel: “register_now” for THIS script */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        /* ACL result */
        if (num == AUTH_RESULT_NUM) {
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != CONS_MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;

            key who = (key)llJsonGetValue(msg, ["avatar"]);
            if (who != g_user) return;
            if (!json_has(msg, ["level"])) return;

            g_acl_level  = (integer)llJsonGetValue(msg, ["level"]);
            g_acl_pending = FALSE;

            if (acl_allowed(g_acl_level)) {
                /* optional: pre-request anim perm once per session */
                if (!g_has_perm || g_perm_avatar != g_user) {
                    llRequestPermissions(g_user, PERMISSION_TRIGGER_ANIMATION);
                }
                show_menu(g_user, 0);
            } else {
                llRegionSayTo(g_user, 0, "Access denied.");
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);
                reset_listen();
                g_user = NULL_KEY;
                llSetTimerEvent(0.0);
            }
            return;
        }

        /* UI start → gate by ACL first */
        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    g_user = id;
                    g_acl_level  = -99;
                    g_acl_pending = TRUE;
                    request_acl(g_user);
                }
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string msg) {
        if (chan != g_menu_chan) return;
        if (id != g_user) return;

        /* Per-button ACL guard */
        if (!acl_allowed(g_acl_level)) {
            llRegionSayTo(g_user, 0, "Access denied.");
            return;
        }

        if (g_no_anims && msg == "OK") {
            /* return to root */
            string r = llList2Json(JSON_OBJECT, []);
            r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
            r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);

            reset_listen();
            g_user = NULL_KEY;
            g_no_anims = FALSE;
            llSetTimerEvent(0.0);
            return;
        }

        if (msg == BACK_BTN_LABEL) {
            string r2 = llList2Json(JSON_OBJECT, []);
            r2 = llJsonSetValue(r2, ["type"],    CONS_TYPE_PLUGIN_RETURN);
            r2 = llJsonSetValue(r2, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r2, g_user);

            reset_listen();
            g_user = NULL_KEY;
            llSetTimerEvent(0.0);
            return;
        }

        if (msg == "<<") { 
            integer np = g_page - 1;
            if (np < 0) np = 0;
            show_menu(g_user, np);
            return;
        }
        if (msg == ">>") { 
            show_menu(g_user, g_page + 1);
            return;
        }
        if (msg == "Relax") { 
            stop_all_anims();
            return;
        }

        /* Try to play chosen animation */
        integer idx = llListFindList(g_anims, [msg]);
        if (idx != -1) {
            start_anim(msg);
            return;
        }
    }

    timer() {
        reset_listen();
        g_user = NULL_KEY;
        g_no_anims = FALSE;
        llSetTimerEvent(0.0);
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
