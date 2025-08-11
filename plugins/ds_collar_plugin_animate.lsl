// =============================================================
// PLUGIN: ds_collar_plugin_animate.lsl
// PURPOSE: Animate menu with tested GUH logic, ported to new kernel
//          (registration, heartbeat, soft-reset, UI return)
// LSL-SAFE: No ternary operators, dialog on a private negative channel
// =============================================================

integer DEBUG = TRUE;

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY   = 500; // Kernel → Plugins: {"type":"register_now","script":"<name>"}
integer K_PLUGIN_REG_REPLY   = 501; // Plugins → Kernel: {"type":"register",...}
integer K_PLUGIN_SOFT_RESET  = 504; // Plugins → Kernel: {"type":"plugin_soft_reset","context":...}
integer K_PLUGIN_PING        = 650; // Kernel → Plugins: {"type":"plugin_ping","context":...}
integer K_PLUGIN_PONG        = 651; // Plugins → Kernel: {"type":"plugin_pong","context":...}
integer K_PLUGIN_START       = 900; // UI → Plugins   : {"type":"plugin_start","context":...}
integer K_PLUGIN_RETURN_NUM  = 901; // Plugins → UI   : {"type":"plugin_return","context":"core_root"}

/* ---------- Shared “magic words” (CONS) ---------- */
string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_REGISTER_NOW      = "register_now";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_SETTINGS_GET      = "settings_get";
string CONS_TYPE_SETTINGS_SYNC     = "settings_sync";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT = "core_animate";  // MUST match kernel/UI
string  ROOT_CONTEXT   = "core_root";
string  PLUGIN_LABEL   = "Animate";
integer PLUGIN_SN      = 0;               // randomized on boot
integer PLUGIN_MIN_ACL = 4;               // keep legacy requirement

/* ---------- Animate state ---------- */
integer g_has_perm   = FALSE;  // Track if animation permission granted
integer g_perm_pending = FALSE; // Track if a request is already in progress
integer g_menu_chan  = 0;
key     g_menu_user  = NULL_KEY;
integer g_anim_page  = 0;
integer g_page_size  = 8; // Animations per page (indices 4–11)
list    g_anims      = [];
integer g_listen     = 0;

/* ========================== Helpers ========================== */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    if (DEBUG) llOwnerSay("[Animate] Registered with kernel.");
}

notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    if (DEBUG) llOwnerSay("[Animate] Notified kernel of soft reset.");
}

get_anims() {
    g_anims = [];
    integer n = llGetInventoryNumber(INVENTORY_ANIMATION);
    integer i = 0;
    while (i < n) {
        g_anims += llGetInventoryName(INVENTORY_ANIMATION, i);
        i += 1;
    }
    g_anims = llListSort(g_anims, 1, TRUE);
}

show_anim_menu(key user, integer page) {
    get_anims();
    integer total = llGetListLength(g_anims);

    if (total == 0) {
        integer tmpChan = -100000 - (integer)llFrand(1000000.0);
        llDialog(user, "No animations in collar.", ["OK"], tmpChan);
        return;
    }

    g_anim_page = page;
    if (g_anim_page < 0) g_anim_page = 0;

    integer start = g_anim_page * g_page_size;
    integer end   = start + g_page_size - 1;
    if (end >= total) end = total - 1;

    list anim_btns = [];
    integer i = start;
    while (i <= end && i < total) {
        anim_btns += llList2String(g_anims, i);
        i += 1;
    }
    while (llGetListLength(anim_btns) < g_page_size) anim_btns += " ";

    string nav_back = " ";
    if (g_anim_page > 0) nav_back = "<<";
    string nav_next = " ";
    if (end < (total - 1)) nav_next = ">>";

    list btns = [nav_back, "Main", nav_next, "Relax"] + anim_btns;
    while (llGetListLength(btns) < 12) btns += " ";

    if (g_listen) llListenRemove(g_listen);
    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_menu_user = user;
    g_listen    = llListen(g_menu_chan, "", user, "");

    llDialog(user,
        "Animations (Page " + (string)(g_anim_page + 1) + "):\n"
        + "Select an animation to play or Relax to stop all.\n"
        + "Navigation: << prev | Main | next >>",
        btns, g_menu_chan);

    if (DEBUG) {
        llOwnerSay(
            "[Animate] Menu → " + (string)user +
            " page=" + (string)g_anim_page +
            " chan=" + (string)g_menu_chan
        );
    }
}

start_anim(string anim) {
    if (!g_has_perm && !g_perm_pending) {
        g_perm_pending = TRUE;
        if (g_menu_user != NULL_KEY) {
            llRequestPermissions(g_menu_user, PERMISSION_TRIGGER_ANIMATION);
        } else {
            llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION);
        }
        return;
    }
    if (g_has_perm) {
        llStartAnimation(anim);
        if (DEBUG) llOwnerSay("[Animate] Playing animation: " + anim);
        show_anim_menu(g_menu_user, g_anim_page);
    } else {
        llOwnerSay("Collar needs permission to animate you. Accept the dialog and try again.");
    }
}

stop_all_anims() {
    integer i = 0;
    integer n = llGetInventoryNumber(INVENTORY_ANIMATION);
    while (i < n) {
        llStopAnimation(llGetInventoryName(INVENTORY_ANIMATION, i));
        i += 1;
    }
    if (DEBUG) llOwnerSay("[Animate] Stopped all animations.");
}

cleanup_session() {
    if (g_listen) llListenRemove(g_listen);
    g_listen    = 0;
    g_menu_user = NULL_KEY;
    g_menu_chan = 0;
}

/* =========================== Events ========================== */

default {
    state_entry() {
        cleanup_session();
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_plugin();
    }

    run_time_permissions(integer perm) {
        if (perm & PERMISSION_TRIGGER_ANIMATION) {
            g_has_perm = TRUE;
            g_perm_pending = FALSE;
            if (g_menu_user != NULL_KEY) {
                show_anim_menu(g_menu_user, g_anim_page);
            }
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
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

        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                    register_plugin();
                }
            }
            return;
        }

        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START) {
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    g_menu_user = id;
                    if (!g_has_perm && !g_perm_pending) {
                        g_perm_pending = TRUE;
                        if (g_menu_user != NULL_KEY) {
                            llRequestPermissions(g_menu_user, PERMISSION_TRIGGER_ANIMATION);
                        } else {
                            llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION);
                        }
                    } else {
                        show_anim_menu(g_menu_user, 0);
                    }
                }
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string msg) {
        if (chan == g_menu_chan && id == g_menu_user) {
            if (msg == "<<") {
                integer nextPage = g_anim_page - 1;
                if (nextPage < 0) nextPage = 0;
                show_anim_menu(g_menu_user, nextPage);
                return;
            }
            if (msg == ">>") {
                show_anim_menu(g_menu_user, g_anim_page + 1);
                return;
            }
            if (msg == "Main") {
                string j = llList2Json(JSON_OBJECT, []);
                j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_RETURN);
                j = llJsonSetValue(j, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, j, g_menu_user);
                cleanup_session();
                return;
            }
            if (msg == "Relax") {
                stop_all_anims();
                show_anim_menu(g_menu_user, g_anim_page);
                return;
            }

            integer idx = llListFindList(g_anims, [msg]);
            if (idx != -1) {
                start_anim(msg);
                return;
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
