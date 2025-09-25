/* =============================================================
   PLUGIN: ds_collar_plugin_animate.lsl  (authoritative, patched)
   PURPOSE: Paginated animation menu with << / Back / >> / Relax
            - Inventory-driven (animations in this prim's contents)
            - Targets the WEARER (llGetOwner())
            - Requests PERMISSION_TRIGGER_ANIMATION in state_entry
            - AUTH-gated open; safe listeners; heartbeat; soft-reset
            - Dual-display registration for TPE (tpe_min_acl = 0)
            - Proper Back handling → returns to main UI
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[ANIMATE] " + s); return 0; }

/* ---------- Kernel ABI link numbers ---------- */
integer K_PLUGIN_REG_QUERY     = 500;
integer K_PLUGIN_REG_REPLY     = 501;
integer K_PLUGIN_SOFT_RESET    = 504;

integer K_PLUGIN_PING          = 650;
integer K_PLUGIN_PONG          = 651;

integer AUTH_QUERY_NUM         = 700;
integer AUTH_RESULT_NUM        = 710;

integer K_PLUGIN_START         = 900;
integer K_PLUGIN_RETURN_NUM    = 901;

/* ---------- Protocol strings ---------- */
string TYPE_REGISTER           = "register";
string TYPE_REGISTER_NOW       = "register_now";
string TYPE_PLUGIN_SOFT_RESET  = "plugin_soft_reset";
string TYPE_PLUGIN_START       = "plugin_start";
string TYPE_PLUGIN_RETURN      = "plugin_return";
string TYPE_PLUGIN_PING        = "plugin_ping";
string TYPE_PLUGIN_PONG        = "plugin_pong";

string MSG_ACL_QUERY           = "acl_query";
string MSG_ACL_RESULT          = "acl_result";

/* ---------- Identity / registration ---------- */
string  PLUGIN_CONTEXT   = "core_animate";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Animate";

/* Visible even under public clamp; UI still clamps per-ACL and PO bypass */
integer PLUGIN_MIN_ACL   = 1;

/* Dual-display for wearer-in-TPE */
integer REG_HAS_TPE      = TRUE;
integer REG_TPE_MIN_ACL  = 0;
string  REG_LABEL_TPE    = "Animate (TPE)";

/* Audience hint */
string  REG_AUDIENCE     = "all";

/* ---------- ACL policy ---------- */
integer ACL_BLACKLIST        = -1;
integer ACL_NOACCESS         = 0;
integer ACL_PUBLIC           = 1;
integer ACL_OWNED            = 2;
integer ACL_TRUSTEE          = 3;
integer ACL_UNOWNED          = 4;
integer ACL_PRIMARY_OWNER    = 5;

/* Allowed to OPEN this plugin (public+ to PO) */
list ALLOWED_ACL_LEVELS = [ACL_PUBLIC, ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

/* ---------- UI/session ---------- */
integer DIALOG_TIMEOUT_SEC = 180;
key     User             = NULL_KEY;
integer Listen           = 0;
integer MenuChan        = 0;

integer Page             = 0;
/* One slot is reserved for Relax → use 8 anims per page */
integer PAGE_SIZE          = 8;

string BTN_LEFT            = "<<";
string BTN_BACK            = "Back";
string BTN_RIGHT           = ">>";
string BTN_RELAX           = "Relax";
string BTN_FILL            = " ";   /* single-space blank button */

/* ---------- AUTH gate session ---------- */
integer AclPending      = FALSE;
integer AclLevel        = ACL_NOACCESS;
key     AclAvatar       = NULL_KEY;

/* ---------- Inventory-driven animations ---------- */
list    Anims            = [];     // list of animation names (strings)
string  LastAnim         = "";     // last started (for Relax)
integer PermOk          = FALSE;  // PERMISSION_TRIGGER_ANIMATION granted?

/* ---------- Helpers ---------- */
integer json_has(string j, list path){
    if (llJsonGetValue(j, path) == JSON_INVALID) return FALSE;
    return TRUE;
}
integer in_allowed_levels(integer lvl){
    if (llListFindList(ALLOWED_ACL_LEVELS, [lvl]) != -1) return TRUE;
    return FALSE;
}
integer anim_count(){ return llGetInventoryNumber(INVENTORY_ANIMATION); }
string anim_name_at(integer idx){ return llGetInventoryName(INVENTORY_ANIMATION, idx); }
integer refresh_anim_list(){
    Anims = [];
    integer n = anim_count();
    integer i = 0;
    while (i < n){
        string nm = anim_name_at(i);
        if (nm != "") Anims += nm;
        i += 1;
    }
    logd("Found animations: " + (string)llGetListLength(Anims));
    return 0;
}

/* ---------- Registration / soft reset ---------- */
integer register_self(){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["type"],    TYPE_REGISTER);
    j = llJsonSetValue(j, ["label"],   PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"], (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    j = llJsonSetValue(j, ["script"],  llGetScriptName());

    if (REG_HAS_TPE){
        j = llJsonSetValue(j, ["tpe_min_acl"], (string)REG_TPE_MIN_ACL);
        if (REG_LABEL_TPE != "") j = llJsonSetValue(j, ["label_tpe"], REG_LABEL_TPE);
    }
    if (REG_AUDIENCE != "all"){
        string a = REG_AUDIENCE;
        if (a == "touchers") a = "non_wearer_only";  /* explicit normalization */
        if (a == "wearer_only" || a == "non_wearer_only"){
            j = llJsonSetValue(j, ["audience"], a);
        }
    }

    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered.");
    return 0;
}
integer notify_soft_reset(){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["type"],    TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    return 0;
}

/* ---------- AUTH ---------- */
integer request_acl(key av){
    if (av == NULL_KEY) return 0;
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["type"],   MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);

    AclPending = TRUE;
    AclAvatar  = av;
    AclLevel   = ACL_NOACCESS;
    return 0;
}

/* ---------- Permissions ---------- */
integer ensure_permissions(){
    key wearer = llGetOwner();
    if (wearer == NULL_KEY) return 0;
    if (!PermOk){
        llRequestPermissions(wearer, PERMISSION_TRIGGER_ANIMATION);
    }
    return 0;
}
integer start_anim(string name){
    ensure_permissions();
    if (PermOk){
        llStartAnimation(name);
        LastAnim = name;
        logd("Start anim: " + name);
    } else {
        llRegionSayTo(User, 0, "Missing permission to trigger animations (requesting). Try again in a moment.");
    }
    return 0;
}
integer stop_anim(string name){
    if (name != ""){
        llStopAnimation(name);
        logd("Stop anim: " + name);
    }
    return 0;
}
integer relax_all(){
    if (LastAnim != ""){
        stop_anim(LastAnim);
        LastAnim = "";
    }
    integer i = 0;
    integer n = llGetListLength(Anims);
    while (i < n){
        string nm = llList2String(Anims, i);
        if (nm != "") llStopAnimation(nm);
        i += 1;
    }
    llRegionSayTo(User, 0, "Relaxed.");
    return 0;
}

/* ---------- Dialog helpers ---------- */
integer reset_listen(){
    if (Listen) llListenRemove(Listen);
    Listen = 0; MenuChan = 0;
    return 0;
}
integer dialog_to(key who, string body, list buttons){
    reset_listen();
    /* Ensure 3-column layout — buttons_for_page already targets 12 */
    while ((llGetListLength(buttons) % 3) != 0) buttons += BTN_FILL;

    MenuChan = -100000 - (integer)llFrand(1000000.0);
    Listen    = llListen(MenuChan, "", who, "");
    llDialog(who, body, buttons, MenuChan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}
integer ui_return_root(key toUser){
    string r = llList2Json(JSON_OBJECT,[]);
    r = llJsonSetValue(r, ["type"],    TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, toUser);
    return 0;
}

/* ---------- Menu ---------- */
list buttons_for_page(integer page){
    list btns = [];

    integer total = llGetListLength(Anims);
    integer maxPage = 0;
    if (total > 0){
        maxPage = (total - 1) / PAGE_SIZE;
    }

    string L = BTN_FILL;
    string R = BTN_FILL;
    if (page > 0) L = BTN_LEFT;
    if (page < maxPage) R = BTN_RIGHT;

    /* Row 1: reserved nav, occupying bottom row due to llDialog ordering */
    btns += [L, BTN_BACK, R];

    /* Index 3 (row 2, col 1): Relax */
    btns += [BTN_RELAX];

    /* Fill remaining slots with up to 8 animations */
    integer start = page * PAGE_SIZE;
    integer end   = start + PAGE_SIZE - 1;
    if (end >= total) end = total - 1;

    integer i = start;
    while (i <= end){
        if (i < total){
            string nm = llList2String(Anims, i);
            if (nm != "") btns += [nm];
        }
        i += 1;
    }

    /* Pad to exactly 12 buttons (3x4 grid) */
    while (llGetListLength(btns) < 12) btns += [BTN_FILL];
    if (llGetListLength(btns) > 12){
        btns = llDeleteSubList(btns, 12, -1);
    }
    return btns;
}
integer show_menu(key user, integer page){
    Page = page;
    integer total = llGetListLength(Anims);
    integer maxPage = 0;
    if (total > 0){
        maxPage = (total - 1) / PAGE_SIZE;
    }
    if (Page < 0) Page = 0;
    if (Page > maxPage) Page = maxPage;

    string body = "Choose an animation to play on the wearer.\n";
    body += "Page " + (string)(Page + 1) + " of " + (string)(maxPage + 1) + ".";

    list btns = buttons_for_page(Page);
    dialog_to(user, body, btns);
    return 0;
}

/* ---------- Session cleanup ---------- */
integer cleanup_session(){
    reset_listen();
    User = NULL_KEY;
    llSetTimerEvent(0.0);
    AclPending = FALSE;
    AclAvatar  = NULL_KEY;
    AclLevel   = ACL_NOACCESS;
    return 0;
}

/* ============================ EVENTS ============================ */
default{
    state_entry(){
        cleanup_session();

        notify_soft_reset();
        register_self();

        refresh_anim_list();
        ensure_permissions();

        logd("Ready.");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){
        if (c & CHANGED_OWNER){ llResetScript(); }
        if (c & CHANGED_INVENTORY){
            refresh_anim_list();
            /* clamp page & redraw if user has menu open */
            if (User != NULL_KEY && Listen != 0){
                show_menu(User, Page);
            }
        }
    }

    run_time_permissions(integer perm){
        if (perm & PERMISSION_TRIGGER_ANIMATION){
            PermOk = TRUE;
            logd("Permission granted: TRIGGER_ANIMATION");
        }
    }

    link_message(integer sender, integer num, string msg, key id){
        if (num == K_PLUGIN_PING){
            if (json_has(msg, ["type"])){
                if (llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_PING){
                    if (json_has(msg, ["context"])){
                        if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                    }
                    string pong = llList2Json(JSON_OBJECT,[]);
                    pong = llJsonSetValue(pong, ["type"],    TYPE_PLUGIN_PONG);
                    pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                }
            }
            return;
        }

        if (num == K_PLUGIN_REG_QUERY){
            if (json_has(msg, ["type"])){
                if (llJsonGetValue(msg, ["type"]) == TYPE_REGISTER_NOW){
                    if (json_has(msg, ["script"])){
                        string want = llJsonGetValue(msg, ["script"]);
                        if (want != llGetScriptName()) return;
                    }
                    register_self();
                }
            }
            return;
        }

        if (num == K_PLUGIN_START){
            if (json_has(msg, ["type"])){
                if (llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_START){
                    if (json_has(msg, ["context"])){
                        if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT){
                            User = id;
                            request_acl(User);
                        }
                    }
                }
            }
            return;
        }

        if (num == AUTH_RESULT_NUM){
            if (!AclPending) return;
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;
            if (!json_has(msg, ["level"])) return;

            key who = (key)llJsonGetValue(msg, ["avatar"]);
            if (who != User) return;

            AclPending = FALSE;
            AclLevel   = (integer)llJsonGetValue(msg, ["level"]);

            if (in_allowed_levels(AclLevel)){
                ensure_permissions();
                refresh_anim_list();
                show_menu(User, 0);
            } else {
                llRegionSayTo(User, 0, "Access denied.");
                ui_return_root(User);
                cleanup_session();
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string b){
        if (chan != MenuChan) return;
        if (id != User) return;

        if (!in_allowed_levels(AclLevel)){
            llRegionSayTo(id, 0, "Access denied.");
            cleanup_session();
            return;
        }

        if (b == BTN_BACK){
            ui_return_root(User);
            cleanup_session();
            return;
        }
        if (b == BTN_LEFT){
            show_menu(User, Page - 1);
            return;
        }
        if (b == BTN_RIGHT){
            show_menu(User, Page + 1);
            return;
        }
        if (b == BTN_RELAX){
            relax_all();
            show_menu(User, Page);
            return;
        }
        if (b == BTN_FILL){
            show_menu(User, Page);
            return;
        }

        integer idx = llListFindList(Anims, [b]);
        if (idx != -1){
            start_anim(b);
            show_menu(User, Page);
            return;
        }

        show_menu(User, Page);
    }

    timer(){
        cleanup_session();
    }
}
