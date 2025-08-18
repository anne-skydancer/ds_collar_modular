/* =============================================================
   PLUGIN: ds_collar_plugin_leash.lsl  (kernel-HB + full UI)
   PURPOSE: Leashing & Movement Restraint with particles, give/offer, anchor

   STRICT ENFORCEMENT (no TP) + MEMORY-SAFE + DEBUG
   - Exact boundary cap with gentle pull (no teleport)
   - Off-sim grace → auto-release
   - Dual JSON handshake (rezzed anchor & worn holder), optional legacy shims
   - Paged scan UI ≤12 buttons (no llDialog overflow)
   - Heap-safe JSON building and UI text assembly
   - Aggressive scan buffer clears
   - Debug helpers & memory tracing
   ============================================================= */

integer DEBUG = FALSE;   /* set TRUE to see memory trace */

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY     = 500;
integer K_PLUGIN_REG_REPLY     = 501;
integer K_PLUGIN_SOFT_RESET    = 504;
integer K_PLUGIN_PING          = 650;
integer K_PLUGIN_PONG          = 651;
integer AUTH_QUERY_NUM         = 700;
integer AUTH_RESULT_NUM        = 710;
integer K_PLUGIN_START         = 900;
integer K_PLUGIN_RETURN_NUM    = 901;

/* ---------- Shared strings ---------- */
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
string  PLUGIN_CONTEXT   = "core_leash";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Leashing";
integer PLUGIN_SN        = 0;
integer PLUGIN_MIN_ACL   = 1;

/* ---------- ACL ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

list ALLOWED_ACL_LEVELS = [ACL_PUBLIC, ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];
integer in_allowed_levels(integer lvl){ if (~llListFindList(ALLOWED_ACL_LEVELS,[lvl])) return TRUE; return FALSE; }

/* ---------- UI ---------- */
string  BTN_BACK          = "Back";
string  BTN_FILL          = "~";
integer DIALOG_TIMEOUT    = 180;
integer SCAN_TIMEOUT      = 30;

/* tighter tick → responsive boundary */
float   FOLLOW_TICK       = 0.20;

/* ---------- Commands ---------- */
string CMD_FILL      = "fill";
string CMD_BACK      = "back";
string CMD_LEASH     = "leash";
string CMD_UNCLIP    = "unclip";
string CMD_SETLEN    = "setlen";
string CMD_SETVAL    = "setval";
string CMD_TURN      = "turn";
string CMD_GIVE      = "give";
string CMD_ANCHOR    = "anchor";
string CMD_PREV      = "prev";
string CMD_NEXT      = "next";

/* numeric picks (store absolute index) */
string CMD_PICK_AV   = "pick_av";
string CMD_PICK_OBJ  = "pick_obj";

/* Give holder */
string CMD_GIVEH           = "giveholder";
string LEASH_HOLDER_ITEM   = "DS Collar leash holder";
list   ALLOWED_GIVEH_LEVELS= [ACL_PUBLIC, ACL_TRUSTEE, ACL_PRIMARY_OWNER];

/* who may set leash length (ACL 3 & 5) */
list   ALLOWED_SETLEN_LEVELS = [ACL_TRUSTEE, ACL_PRIMARY_OWNER];

/* ---------- Scan ---------- */
float   SCAN_RADIUS = 5.0;
float   SCAN_ARC    = TWO_PI;
integer MAX_PAGE_ITEMS = 9;  /* 9 numbers + [<<][Back][>>] = 12 total */
integer g_page_idx = 0;

/* ---------- Session/UI state ---------- */
key     g_user = NULL_KEY;
integer g_listen = 0;
integer g_menu_chan = 0;
integer g_acl_pending = FALSE;
integer g_last_acl_level = ACL_NOACCESS;
list    g_btn_labels = [];
list    g_btn_cmds = [];
integer g_dialog_expires = 0;

/* ---------- Scan state (keys only; names resolved on demand) ---------- */
string  g_scan_mode = "";      /* "", "give", "anchor" */
list    g_scan_keys = [];      /* keys of results */
integer g_scan_expires = 0;

/* ---------- Leash state ---------- */
integer g_leashed      = FALSE;
key     g_leasher      = NULL_KEY;   /* avatar OR object/prim key */
integer g_leash_length = 2;
integer g_turn_to      = FALSE;
integer g_controls_ok  = FALSE;

/* ---------- Particles ---------- */
string  g_chain_texture   = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";
integer g_psys_on         = FALSE;
key     g_psys_target     = NULL_KEY;
vector  g_last_target     = ZERO_VECTOR;
float   g_last_dist       = -1.0;
float   g_move_hyst       = 0.20;

/* exact cap epsilon (stay strictly inside) */
float   g_boundary_epsilon = 0.01;

/* ---------- Holder handshake (JSON) ---------- */
integer LEASH_HOLDER_CHAN     = -192837465; /* must match holder */
integer HOLDER_REPLY_WAIT_SEC = 2;

/* JSON for Anchor (rez object) */
integer g_holderListen      = 0;
integer g_anchor_waiting    = FALSE;
integer g_anchor_session    = 0;
key     g_anchor_obj        = NULL_KEY;
integer g_anchor_deadline   = 0;

/* JSON for Leash to controller’s worn holder (broadcast) */
integer g_worn_waiting    = FALSE;
integer g_worn_session    = 0;
key     g_worn_controller = NULL_KEY;
integer g_worn_deadline   = 0;

/* ---------- Legacy LG/LM shim (optional) ---------- */
integer LG_LM_ENABLED = TRUE;
integer LG_CHAN = -911911;      /* example */
integer LM_CHAN = -888777;      /* example */
integer g_legacyListenLG = 0;
integer g_legacyListenLM = 0;

/* ---------- Strict no-TP enforcement (controls) ---------- */
integer gHoldingCtrls = FALSE;
integer allowBackStep = FALSE;
float   backStepWindow = 0.35;
float   backStepTimer  = 0.0;

/* Build masks via functions (avoid global-scope parser quirks) */
integer MOVE_MASK(){ return CONTROL_FWD | CONTROL_BACK | CONTROL_LEFT | CONTROL_RIGHT | CONTROL_UP | CONTROL_DOWN; }
integer BACK_MASK(){ return CONTROL_BACK; }

/* ---------- Off-sim detection ---------- */
integer g_offsimFlag       = FALSE;
integer g_offsimStartEpoch = 0;
float   OFFSIM_GRACE_SEC   = 6.0;

/* ---------- Debug helpers ---------- */
integer dbg_on_throttle = 0;
integer dbg_throttle_ms = 1000;
integer _last_dbg_epoch = 0;
integer freemem(){ return llGetFreeMemory(); }
integer now(){ return llGetUnixTime(); }
integer json_has(string j, list path){ if (llJsonGetValue(j,path) != JSON_INVALID) return TRUE; return FALSE; }
integer logd(string s){ if (DEBUG) llOwnerSay("[LEASH] " + s); return 0; }
integer dbg(string s){
    if (!DEBUG) return 0;
    integer t = now();
    if (dbg_on_throttle){
        if (t == _last_dbg_epoch) return 0;
        _last_dbg_epoch = t;
    }
    llOwnerSay("[LEASH] " + s);
    return 0;
}
integer dbg_mem(string tag){
    if (!DEBUG) return 0;
    llOwnerSay("[LEASH][mem] " + tag + " : " + (string)freemem());
    return 0;
}

/* ================= Registration & Heartbeat ================= */
integer register_self(){
    string j = llList2Json(JSON_OBJECT, [
        "type",    CONS_TYPE_REGISTER,
        "sn",      (string)PLUGIN_SN,
        "label",   PLUGIN_LABEL,
        "min_acl", (string)PLUGIN_MIN_ACL,
        "context", PLUGIN_CONTEXT,
        "script",  llGetScriptName()
    ]);
    llMessageLinked(LINK_SET,K_PLUGIN_REG_REPLY,j,NULL_KEY);
    return 0;
}

/* ================= Particles & Follow ================= */
vector leash_ring_world(){
    integer n = llGetNumberOfPrims();
    integer i = 2;
    while (i <= n){
        string nm = llGetLinkName(i);
        string desc = llList2String(llGetLinkPrimitiveParams(i,[PRIM_DESC]),0);
        if (llToLower(nm) == "leashring" || llToLower(desc) == "leash:ring"){
            vector loc = llList2Vector(llGetLinkPrimitiveParams(i,[PRIM_POS_LOCAL]),0);
            return llGetRootPosition() + (loc * llGetRootRotation());
        }
        i = i + 1;
    }
    return llGetRootPosition();
}

integer draw_leash_particles(key to){
    if (to == NULL_KEY){
        if (g_psys_on){ llParticleSystem([]); g_psys_on = FALSE; }
        g_psys_target = NULL_KEY;
        return 0;
    }
    if (!g_psys_on || g_psys_target != to){
        g_psys_target = to;
        llParticleSystem([
            PSYS_SRC_PATTERN, PSYS_SRC_PATTERN_DROP,
            PSYS_SRC_TEXTURE, g_chain_texture,
            PSYS_SRC_BURST_RATE, 0.00,
            PSYS_SRC_BURST_PART_COUNT, 1,
            PSYS_PART_START_ALPHA, 1.0,
            PSYS_PART_END_ALPHA, 1.0,
            PSYS_PART_MAX_AGE, 2.6,
            PSYS_PART_START_SCALE, <0.07,0.07,0>,
            PSYS_PART_END_SCALE,   <0.07,0.07,0>,
            PSYS_PART_START_COLOR, <1,1,1>,
            PSYS_PART_END_COLOR,   <1,1,1>,
            PSYS_SRC_ACCEL, <0,0,-1.25>,
            PSYS_PART_FLAGS, PSYS_PART_INTERP_COLOR_MASK
                            |PSYS_PART_FOLLOW_SRC_MASK
                            |PSYS_PART_TARGET_POS_MASK
                            |PSYS_PART_FOLLOW_VELOCITY_MASK
                            |PSYS_PART_RIBBON_MASK,
            PSYS_SRC_TARGET_KEY, to
        ]);
        g_psys_on = TRUE;
    }
    return 0;
}
integer stop_leash_particles(){
    if (g_psys_on){ llParticleSystem([]); g_psys_on = FALSE; }
    g_psys_target = NULL_KEY;
    return 0;
}

integer turn_to_leasher(key leasher){
    if (leasher == NULL_KEY) return 0;
    list det = llGetObjectDetails(leasher,[OBJECT_POS]);
    if (llGetListLength(det) < 1) return 0;
    vector fwd = llVecNorm(llList2Vector(det,0) - llGetRootPosition());
    rotation rot = llRotBetween(<1,0,0>, fwd);
    llOwnerSay("@setrot:"+(string)rot+"=force");
    return 0;
}
integer clear_turn(){ llOwnerSay("@setrot=clear"); return 0; }

/* STRICT boundary logic (no TP) */
integer holdControlsEnable(){
    if (!g_controls_ok) return FALSE;
    if (gHoldingCtrls) return FALSE;
    llTakeControls(MOVE_MASK(), TRUE, FALSE);
    gHoldingCtrls = TRUE;
    return TRUE;
}
integer holdControlsDisable(){
    if (!gHoldingCtrls) return FALSE;
    llReleaseControls();
    gHoldingCtrls = FALSE;
    allowBackStep = FALSE;
    return TRUE;
}
integer beginAllowBack(){
    if (!gHoldingCtrls) return FALSE;
    if (allowBackStep) return FALSE;
    llTakeControls(BACK_MASK(), TRUE, TRUE);
    allowBackStep = TRUE;
    backStepTimer = llGetTime();
    return TRUE;
}
integer maybeEndAllowBack(){
    if (!allowBackStep) return FALSE;
    if (llGetTime() - backStepTimer >= backStepWindow){
        llTakeControls(MOVE_MASK(), TRUE, FALSE);
        allowBackStep = FALSE;
        return TRUE;
    }
    return FALSE;
}

integer leash_follow_logic(){
    if (!g_leashed) return 0;
    if (g_leasher == NULL_KEY) return 0;

    vector leash_pt = leash_ring_world();

    if (g_leasher != llGetOwner()){
        list det = llGetObjectDetails(g_leasher,[OBJECT_POS]);
        if (llGetListLength(det) > 0) leash_pt = llList2Vector(det,0);
    }

    vector wearer = llGetRootPosition();
    vector offset = wearer - leash_pt;
    float  dist   = llVecMag(offset);

    if (dist > (float)g_leash_length){
        holdControlsEnable();

        if (dist > 0.0){
            vector unit = offset / dist;
            float  back = (float)g_leash_length - g_boundary_epsilon;
            if (back < 0.0) back = 0.0;
            vector tgt = leash_pt + (unit * back);

            if (llVecMag(tgt - g_last_target) > g_move_hyst){
                llMoveToTarget(tgt, 0.25);
                g_last_target = tgt;
            }
        }

        if (g_turn_to) turn_to_leasher(g_leasher);
    } else {
        holdControlsDisable();
        if (g_last_dist >= 0.0){
            if (g_last_dist > (float)g_leash_length){
                llStopMoveToTarget();
                g_last_target = ZERO_VECTOR;
            }
        }
    }

    g_last_dist = dist;
    draw_leash_particles(g_leasher);
    return 0;
}

/* ================= Holder helpers ================= */
integer has_holder_item(){
    integer t = llGetInventoryType(LEASH_HOLDER_ITEM);
    if (t == INVENTORY_OBJECT) return TRUE;
    return FALSE;
}
integer give_holder_to(key who){
    if (who == NULL_KEY) return FALSE;
    if (!has_holder_item()){
        llRegionSayTo(who,0,"The ‘Leash Holder’ object is missing from the collar inventory.");
        return FALSE;
    }
    llGiveInventory(who,LEASH_HOLDER_ITEM);
    llRegionSayTo(who,0,"Leash holder sent. Wear or rez it to use as a leash target.");
    return TRUE;
}

/* JSON: request a leash prim from a rezzed object (direct) */
integer begin_anchor_handshake(key obj){
    if (g_holderListen) llListenRemove(g_holderListen);
    g_holderListen = llListen(LEASH_HOLDER_CHAN,"",NULL_KEY,"");

    g_anchor_session  = (integer)llFrand(2147483000.0);
    g_anchor_obj      = obj;
    g_anchor_waiting  = TRUE;
    g_anchor_deadline = now() + HOLDER_REPLY_WAIT_SEC;

    string req = llList2Json(JSON_OBJECT, [
        "type","leash_req",
        "wearer",(string)llGetOwner(),
        "collar",(string)llGetKey(),
        "session",(string)g_anchor_session
    ]);
    llRegionSayTo(obj,LEASH_HOLDER_CHAN,req);

    if (LG_LM_ENABLED){
        if (!g_legacyListenLG) g_legacyListenLG = llListen(LG_CHAN,"",NULL_KEY,"");
        if (!g_legacyListenLM) g_legacyListenLM = llListen(LM_CHAN,"",NULL_KEY,"");
        string lg = "LG_LEASH_REQ|" + (string)llGetKey() + "|" + (string)g_user + "|" + (string)g_anchor_session;
        llRegionSay(LG_CHAN,lg);

        string lm = "LM_LEASH_REQ|" + (string)llGetKey() + "|" + (string)g_user + "|" + (string)g_anchor_session;
        llRegionSay(LM_CHAN,lm);
    }
    dbg_mem("begin_anchor_handshake");
    return TRUE;
}

/* JSON: request a leash prim from controller’s worn holder (broadcast) */
integer begin_worn_holder_handshake(key controller){
    if (g_holderListen) llListenRemove(g_holderListen);
    g_holderListen = llListen(LEASH_HOLDER_CHAN,"",NULL_KEY,"");

    g_worn_session    = (integer)llFrand(2147483000.0);
    g_worn_controller = controller;
    g_worn_waiting    = TRUE;
    g_worn_deadline   = now() + HOLDER_REPLY_WAIT_SEC;

    string req = llList2Json(JSON_OBJECT, [
        "type","leash_req",
        "wearer",(string)llGetOwner(),
        "collar",(string)llGetKey(),
        "controller",(string)controller,
        "session",(string)g_worn_session
    ]);
    llRegionSay(LEASH_HOLDER_CHAN,req);

    if (LG_LM_ENABLED){
        if (!g_legacyListenLG) g_legacyListenLG = llListen(LG_CHAN,"",NULL_KEY,"");
        if (!g_legacyListenLM) g_legacyListenLM = llListen(LM_CHAN,"",NULL_KEY,"");
        string lg = "LG_LEASH_REQ|" + (string)llGetKey() + "|" + (string)controller + "|" + (string)g_worn_session;
        string lm = "LM_LEASH_REQ|" + (string)llGetKey() + "|" + (string)controller + "|" + (string)g_worn_session;
        llRegionSay(LG_CHAN,lg);
        llRegionSay(LM_CHAN,lm);
    }
    dbg_mem("begin_worn_holder_handshake");
    return TRUE;
}

/* notify holders that leash was released (best-effort) */
integer notify_release(){
    list kv = ["type","leash_release","wearer",(string)llGetOwner(),"collar",(string)llGetKey()];
    if (g_leasher != NULL_KEY) kv += ["holder",(string)g_leasher];
    llRegionSay(LEASH_HOLDER_CHAN, llList2Json(JSON_OBJECT, kv));
    return TRUE;
}

/* ================= UI Builders ================= */
list make_menu_pairs(integer acl){
    list pairs = [BTN_FILL,CMD_FILL, BTN_BACK,CMD_BACK, BTN_FILL,CMD_FILL];

    if (acl == 1){
        pairs += ["Leash",CMD_LEASH, "Unclip",CMD_UNCLIP, "Anchor",CMD_ANCHOR, "Give holder",CMD_GIVEH];
    } else if (acl == 2){
        pairs += ["Offer Leash",CMD_GIVE];
    } else if (acl == 3){
        pairs += ["Leash",CMD_LEASH, "Unclip",CMD_UNCLIP, "Set Length",CMD_SETLEN,
                  "Turn",CMD_TURN, "Give Leash",CMD_GIVE, "Anchor",CMD_ANCHOR, "Give holder",CMD_GIVEH];
    } else if (acl == 4){
        pairs += ["Offer Leash",CMD_GIVE, "Anchor",CMD_ANCHOR, "Unclip",CMD_UNCLIP];
    } else {
        pairs += ["Leash",CMD_LEASH, "Unclip",CMD_UNCLIP, "Set Length",CMD_SETLEN,
                  "Turn",CMD_TURN, "Give Leash",CMD_GIVE, "Anchor",CMD_ANCHOR, "Give holder",CMD_GIVEH];
    }
    return pairs;
}

integer begin_dialog_ctx(key user, string body, list pairs){
    /* reset old */
    if (g_listen) llListenRemove(g_listen);
    g_btn_labels = [];
    g_btn_cmds = [];

    g_user = user;

    integer i = 0;
    integer L = llGetListLength(pairs);
    while (i < L){
        g_btn_labels += llList2String(pairs,i);
        g_btn_cmds   += llList2String(pairs,i+1);
        i = i + 2;
    }

    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen = llListen(g_menu_chan,"",g_user,"");
    llDialog(g_user, body, g_btn_labels, g_menu_chan);
    g_dialog_expires = now() + DIALOG_TIMEOUT;

    dbg_mem("begin_dialog_ctx");
    return 0;
}
integer begin_dialog_ctx_delayed(key user, string body, list pairs){ llSleep(0.2); return begin_dialog_ctx(user,body,pairs); }

integer show_main_menu(key user, integer acl){
    list lines = [];
    if (g_leashed) lines += ["Leashed to: " + llKey2Name(g_leasher)];
    else lines += ["Not leashed"];
    lines += ["Length: " + (string)g_leash_length + " m"];
    if (g_turn_to) lines += ["Turn: ON"]; else lines += ["Turn: OFF"];

    string menu = llDumpList2String(lines, "\n");
    return begin_dialog_ctx_delayed(user, menu, make_menu_pairs(acl));
}

/* ---------- Length picker ---------- */
integer do_set_len(integer m){ if (m<1) m=1; if (m>30) m=30; g_leash_length=m; return TRUE; }
integer show_length_menu(){
    list labels = ["1","2","3","5","8","10","12","15","20"];
    list pairs  = [BTN_FILL,CMD_FILL, BTN_BACK,CMD_BACK, BTN_FILL,CMD_FILL];
    integer i = 0;
    integer L = llGetListLength(labels);
    while (i < L){
        string lab = llList2String(labels,i);
        pairs += [lab, CMD_SETVAL];
        i = i + 1;
    }
    return begin_dialog_ctx_delayed(g_user,"Pick leash length (m)",pairs);
}

/* ---------- Root return ---------- */
integer do_back(){
    /* clear scan buffers aggressively to free heap */
    g_scan_mode = "";
    g_scan_keys = [];
    g_page_idx  = 0;

    string r = llList2Json(JSON_OBJECT,["type",CONS_TYPE_PLUGIN_RETURN,"context",ROOT_CONTEXT]);
    llMessageLinked(LINK_SET,K_PLUGIN_RETURN_NUM,r,g_user);
    g_user = NULL_KEY;

    /* close menu listen */
    if (g_listen) llListenRemove(g_listen);
    g_listen = 0; g_menu_chan = 0; g_btn_labels = []; g_btn_cmds = [];
    return TRUE;
}

/* ---------- Leash / Unclip / Turn ---------- */
integer do_leash(key who){
    if (who == NULL_KEY) return FALSE;
    g_leasher = who; g_leashed = TRUE;
    draw_leash_particles(g_leasher);
    dbg_mem("do_leash");
    return TRUE;
}
integer do_unclip(){
    g_leashed = FALSE;
    g_leasher = NULL_KEY;
    llStopMoveToTarget();
    g_last_target = ZERO_VECTOR;
    stop_leash_particles();
    holdControlsDisable();
    if (g_offsimFlag){ g_offsimFlag = FALSE; g_offsimStartEpoch = 0; }
    notify_release();
    dbg_mem("do_unclip");
    return TRUE;
}
integer do_toggle_turn(){ if (g_turn_to) g_turn_to=FALSE; else g_turn_to=TRUE; if (!g_turn_to) clear_turn(); return TRUE; }

/* ================= Scanning & Pages ================= */
integer start_scan_avatars(){
    g_scan_mode="give"; g_scan_keys=[]; g_page_idx=0;
    g_scan_expires = now() + SCAN_TIMEOUT;
    llSensor("",NULL_KEY,AGENT,SCAN_RADIUS,SCAN_ARC);
    dbg_mem("start_scan_avatars");
    return TRUE;
}
integer start_scan_objects(){
    g_scan_mode="anchor"; g_scan_keys=[]; g_page_idx=0;
    g_scan_expires = now() + SCAN_TIMEOUT;
    integer mask = ACTIVE | PASSIVE | SCRIPTED;
    llSensor("",NULL_KEY,mask,SCAN_RADIUS,SCAN_ARC);
    dbg_mem("start_scan_objects");
    return TRUE;
}

/* Paginated scan dialog (≤12 buttons: <<, Back, >> + up to 9 numbers) */
integer show_scan_page(){
    integer total = llGetListLength(g_scan_keys);
    if (total <= 0){
        if (g_scan_mode=="give") llRegionSayTo(g_user,0,"No nearby avatars.");
        else llRegionSayTo(g_user,0,"No nearby objects.");
        show_main_menu(g_user,g_last_acl_level);
        return FALSE;
    }

    integer perPage = MAX_PAGE_ITEMS;
    integer start = g_page_idx * perPage;
    integer end   = start + perPage - 1;
    if (end >= total) end = total - 1;

    /* Build header & rows via list → single join (heap-friendly) */
    list body = [];
    if (g_scan_mode=="give") body += ["Select avatar"];
    else body += ["Select object"];
    body += ["(" + (string)(start+1) + "-" + (string)(end+1) + "/" + (string)total + "):"];

    list pairs = [];
    integer hasPrev = (g_page_idx > 0);
    integer hasNext = ((end + 1) < total);
    if (hasPrev) pairs += ["<<", CMD_PREV];
    pairs += ["Back", CMD_BACK];
    if (hasNext) pairs += [">>", CMD_NEXT];

    integer i = start;
    integer lineNo = 1;
    while (i <= end){
        key k = llList2Key(g_scan_keys,i);
        string nm = llKey2Name(k);
        if (nm == "") nm = (string)k;

        body += [(string)lineNo + ". " + nm];
        string lab = (string)lineNo;
        if (g_scan_mode=="give") pairs += [lab, CMD_PICK_AV + ":" + (string)i];
        else pairs += [lab, CMD_PICK_OBJ + ":" + (string)i];
        i = i + 1; lineNo = lineNo + 1;
    }

    string head = llDumpList2String(body, "\n");
    dbg_mem("show_scan_page");
    return begin_dialog_ctx_delayed(g_user, head, pairs);
}

/* ================================ Events =============================== */
default {
    state_entry(){
        PLUGIN_SN = (integer)(llFrand(1.0e9));

        do_unclip(); /* clear any previous leash */

        g_user = NULL_KEY;

        if (g_listen) llListenRemove(g_listen);
        g_listen = 0; g_menu_chan = 0; g_btn_labels = []; g_btn_cmds = [];

        if (g_holderListen) llListenRemove(g_holderListen); g_holderListen = 0;
        if (g_legacyListenLG) llListenRemove(g_legacyListenLG); g_legacyListenLG = 0;
        if (g_legacyListenLM) llListenRemove(g_legacyListenLM); g_legacyListenLM = 0;

        g_acl_pending = FALSE;
        g_last_acl_level = ACL_NOACCESS;

        g_anchor_waiting = FALSE; g_anchor_obj = NULL_KEY; g_anchor_session = 0; g_anchor_deadline = 0;
        g_worn_waiting = FALSE; g_worn_controller = NULL_KEY; g_worn_session = 0; g_worn_deadline = 0;

        string j = llList2Json(JSON_OBJECT,["type",CONS_TYPE_PLUGIN_SOFT_RESET,"context",PLUGIN_CONTEXT]);
        llMessageLinked(LINK_SET,K_PLUGIN_SOFT_RESET,j,NULL_KEY);

        register_self();

        llRequestPermissions(llGetOwner(),PERMISSION_TAKE_CONTROLS);
        llSetTimerEvent(FOLLOW_TICK);

        dbg_mem("state_entry_end");
    }

    attach(key id){
        if (id) llRequestPermissions(id, PERMISSION_TAKE_CONTROLS);
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    run_time_permissions(integer p){ if (p & PERMISSION_TAKE_CONTROLS) g_controls_ok=TRUE; else g_controls_ok=FALSE; }

    /* Allow BACK step while holding */
    control(key id, integer held, integer change){
        if (!gHoldingCtrls) return;
        if (held & CONTROL_BACK){
            beginAllowBack();
        }
    }

    link_message(integer sender, integer num, string msg, key id){
        if (num == AUTH_RESULT_NUM){
            if (!g_acl_pending) return;
            if (!json_has(msg,["type"])) return;
            if (llJsonGetValue(msg,["type"]) != CONS_MSG_ACL_RESULT) return;
            if (!json_has(msg,["avatar"])) return;
            if (!json_has(msg,["level"])) return;

            key who = (key)llJsonGetValue(msg,["avatar"]);
            integer lvl = (integer)llJsonGetValue(msg,["level"]);
            if (who != g_user) return;

            g_acl_pending = FALSE;
            g_last_acl_level = lvl;

            if (in_allowed_levels(lvl)) show_main_menu(g_user,lvl);
            else {
                llRegionSayTo(g_user,0,"Access denied.");
                string r = llList2Json(JSON_OBJECT,["type",CONS_TYPE_PLUGIN_RETURN,"context",ROOT_CONTEXT]);
                llMessageLinked(LINK_SET,K_PLUGIN_RETURN_NUM,r,g_user);
                g_user = NULL_KEY;
                if (g_listen) llListenRemove(g_listen);
                g_listen = 0; g_menu_chan = 0; g_btn_labels = []; g_btn_cmds = [];
            }
            return;
        }

        if (num == K_PLUGIN_REG_QUERY){
            if (json_has(msg,["type"])){
                if (llJsonGetValue(msg,["type"]) == CONS_TYPE_REGISTER_NOW){
                    if (json_has(msg,["script"])){
                        string want = llJsonGetValue(msg,["script"]);
                        if (want != llGetScriptName()) return;
                    }
                    register_self();
                }
            }
            return;
        }

        if (num == K_PLUGIN_PING){
            if (json_has(msg,["type"])){
                if (llJsonGetValue(msg,["type"]) == CONS_TYPE_PLUGIN_PING){
                    if (json_has(msg,["context"])){
                        string c = llJsonGetValue(msg,["context"]);
                        if (c != PLUGIN_CONTEXT) return;
                    }
                    string r = llList2Json(JSON_OBJECT,["type",CONS_TYPE_PLUGIN_PONG,"context",PLUGIN_CONTEXT]);
                    llMessageLinked(LINK_SET,K_PLUGIN_PONG,r,NULL_KEY);
                }
            }
            return;
        }

        if (num == K_PLUGIN_START){
            if (json_has(msg,["type"])){
                if (llJsonGetValue(msg,["type"]) == CONS_TYPE_PLUGIN_START){
                    if (json_has(msg,["context"])){
                        if (llJsonGetValue(msg,["context"]) == PLUGIN_CONTEXT){
                            g_user = id;
                            string j2 = llList2Json(JSON_OBJECT,["type",CONS_MSG_ACL_QUERY,"avatar",(string)g_user]);
                            llMessageLinked(LINK_SET,AUTH_QUERY_NUM,j2,NULL_KEY);
                            g_acl_pending = TRUE;
                        }
                    }
                }
            }
            return;
        }
    }

    sensor(integer num){
        if (g_scan_mode == "") return;

        g_scan_keys = [];
        integer i = 0;
        while (i < num){
            key k = llDetectedKey(i);
            integer include = TRUE;
            if (g_scan_mode == "give"){
                if (k == llGetOwner()) include = FALSE;
            }
            if (include){
                g_scan_keys += [k];
            }
            i = i + 1;
        }
        dbg_mem("sensor_collected");
        show_scan_page();
    }
    no_sensor(){
        if (g_scan_mode == "give") llRegionSayTo(g_user,0,"No nearby avatars.");
        else if (g_scan_mode == "anchor") llRegionSayTo(g_user,0,"No nearby objects.");
        show_main_menu(g_user,g_last_acl_level);
    }

    listen(integer chan, string nm, key id, string msg){
        /* ----- Holder JSON replies (both modes) ----- */
        if (chan == LEASH_HOLDER_CHAN){
            if (g_anchor_waiting){
                if (!json_has(msg,["type"])) return;
                if (llJsonGetValue(msg,["type"]) != "leash_target") return;

                integer sess_ok = FALSE;
                if (json_has(msg,["session"])){
                    integer s = (integer)llJsonGetValue(msg,["session"]);
                    if (s == g_anchor_session) sess_ok = TRUE;
                }
                if (!sess_ok) return;

                integer ok = 0;
                if (json_has(msg,["ok"])) ok = (integer)llJsonGetValue(msg,["ok"]);
                if (ok == 1 && json_has(msg,["holder"])){
                    key prim = (key)llJsonGetValue(msg,["holder"]);
                    if (prim != NULL_KEY){
                        g_leasher = prim; g_leashed = TRUE; draw_leash_particles(g_leasher);
                    }
                }
                g_anchor_waiting = FALSE; g_anchor_deadline=0; g_anchor_session=0; g_anchor_obj=NULL_KEY;
                if (g_holderListen){ llListenRemove(g_holderListen); g_holderListen=0; }
                if (g_user) show_main_menu(g_user,g_last_acl_level);
                return;
            }

            if (g_worn_waiting){
                if (!json_has(msg,["type"])) return;
                if (llJsonGetValue(msg,["type"]) != "leash_target") return;

                integer sess_ok2 = FALSE;
                if (json_has(msg,["session"])){
                    integer s2 = (integer)llJsonGetValue(msg,["session"]);
                    if (s2 == g_worn_session) sess_ok2 = TRUE;
                }
                if (!sess_ok2) return;

                integer ok2 = 0;
                if (json_has(msg,["ok"])) ok2 = (integer)llJsonGetValue(msg,["ok"]);
                if (ok2 == 1 && json_has(msg,["holder"])){
                    key prim2 = (key)llJsonGetValue(msg,["holder"]);
                    if (prim2 != NULL_KEY){
                        g_leasher = prim2; g_leashed = TRUE; draw_leash_particles(g_leasher);
                    }
                }
                g_worn_waiting = FALSE; g_worn_deadline=0; g_worn_session=0; g_worn_controller=NULL_KEY;
                if (g_holderListen){ llListenRemove(g_holderListen); g_holderListen=0; }
                if (g_user) show_main_menu(g_user,g_last_acl_level);
                return;
            }
        }

        /* OPTIONAL: legacy replies parsing */
        if ((chan == LG_CHAN || chan == LM_CHAN) && LG_LM_ENABLED){
            list p = llParseString2List(msg,["|"],[]);
            if (llGetListLength(p) >= 3){
                string primStr = llList2String(p,1);
                integer sess = (integer)llList2String(p,2);
                key primKey = (key)primStr;

                integer match = FALSE;
                if (g_anchor_waiting && (sess == g_anchor_session)) match = TRUE;
                else if (g_worn_waiting && (sess == g_worn_session)) match = TRUE;

                if (match && primKey != NULL_KEY){
                    g_leasher = primKey; g_leashed = TRUE; draw_leash_particles(g_leasher);

                    g_anchor_waiting = FALSE; g_anchor_deadline=0; g_anchor_session=0; g_anchor_obj=NULL_KEY;
                    g_worn_waiting = FALSE; g_worn_deadline=0; g_worn_session=0; g_worn_controller=NULL_KEY;
                    if (g_holderListen){ llListenRemove(g_holderListen); g_holderListen=0; }
                    if (g_user) show_main_menu(g_user,g_last_acl_level);
                    return;
                }
            }
        }

        /* ----- Dialog ----- */
        if (chan != g_menu_chan) return;

        integer idx = llListFindList(g_btn_labels,[msg]);
        if (idx == -1){ show_main_menu(g_user,g_last_acl_level); return; }
        string cmd = llList2String(g_btn_cmds,idx);

        if (cmd == CMD_BACK){ do_back(); return; }

        if (cmd == CMD_LEASH){
            begin_worn_holder_handshake(g_user);
            return;
        }

        if (cmd == CMD_UNCLIP){ do_unclip(); show_main_menu(g_user,g_last_acl_level); return; }

        if (cmd == CMD_TURN){ do_toggle_turn(); show_main_menu(g_user,g_last_acl_level); return; }

        if (cmd == CMD_SETLEN){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[g_last_acl_level]) == -1){
                llRegionSayTo(g_user,0,"You do not have permission to set leash length.");
                show_main_menu(g_user,g_last_acl_level);
                return;
            }
            show_length_menu(); return;
        }

        if (cmd == CMD_SETVAL){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[g_last_acl_level]) == -1){
                llRegionSayTo(g_user,0,"You do not have permission to set leash length.");
                show_main_menu(g_user,g_last_acl_level);
                return;
            }
            integer Lv = (integer)msg; do_set_len(Lv); show_main_menu(g_user,g_last_acl_level); return;
        }

        if (cmd == CMD_GIVE){ start_scan_avatars(); return; }

        if (cmd == CMD_ANCHOR){ start_scan_objects(); return; }

        if (cmd == CMD_GIVEH){
            if (llListFindList(ALLOWED_GIVEH_LEVELS,[g_last_acl_level]) == -1){
                llRegionSayTo(g_user,0,"You do not have permission to use that.");
                show_main_menu(g_user,g_last_acl_level);
                return;
            }
            give_holder_to(g_user); show_main_menu(g_user,g_last_acl_level); return;
        }

        if (cmd == CMD_PREV){
            if (g_page_idx > 0) g_page_idx = g_page_idx - 1;
            show_scan_page(); return;
        }

        if (cmd == CMD_NEXT){
            integer total = llGetListLength(g_scan_keys);
            integer maxPage = 0;
            if (total > 0) maxPage = (total - 1) / MAX_PAGE_ITEMS;
            if (g_page_idx < maxPage) g_page_idx = g_page_idx + 1;
            show_scan_page(); return;
        }

        integer ppos = llSubStringIndex(cmd,":");
        if (ppos != -1){
            string head = llGetSubString(cmd,0,ppos-1);
            string tail = llGetSubString(cmd,ppos+1,-1);
            integer abs = (integer)tail;
            if (head == CMD_PICK_AV){
                if (abs >= 0){
                    if (abs < llGetListLength(g_scan_keys)){
                        key target = llList2Key(g_scan_keys,abs);
                        begin_worn_holder_handshake(target);
                        return;
                    }
                }
            }
            if (head == CMD_PICK_OBJ){
                if (abs >= 0){
                    if (abs < llGetListLength(g_scan_keys)){
                        key obj = llList2Key(g_scan_keys,abs);
                        begin_anchor_handshake(obj);
                        return;
                    }
                }
            }
        }

        if (cmd == CMD_FILL){ show_main_menu(g_user,g_last_acl_level); return; }
        show_main_menu(g_user,g_last_acl_level);
    }

    timer(){
        /* dialog timeout */
        if (g_dialog_expires != 0){
            if (now() >= g_dialog_expires){
                if (g_listen) llListenRemove(g_listen);
                g_listen = 0; g_menu_chan = 0; g_btn_labels = []; g_btn_cmds = [];
                g_dialog_expires = 0;
            }
        }

        /* back-step window tick */
        maybeEndAllowBack();

        /* off-sim grace & auto-release */
        if (g_leashed){
            integer present = FALSE;
            if (g_leasher != NULL_KEY){
                integer ai = llGetAgentInfo(g_leasher);
                if (ai != 0) present = TRUE;
                else {
                    list d = llGetObjectDetails(g_leasher, [OBJECT_POS]);
                    if (llGetListLength(d) >= 1){
                        vector p = llList2Vector(d,0);
                        if (p != ZERO_VECTOR) present = TRUE;
                    }
                }
            }
            if (!present){
                if (!g_offsimFlag){ g_offsimFlag=TRUE; g_offsimStartEpoch=now(); }
            } else {
                if (g_offsimFlag){ g_offsimFlag=FALSE; g_offsimStartEpoch=0; }
            }
            if (g_offsimFlag){
                integer elapsed = now() - g_offsimStartEpoch;
                if ((float)elapsed >= OFFSIM_GRACE_SEC){
                    do_unclip();
                    llRegionSayTo(llGetOwner(),0,"Leash released: holder/anchor left region.");
                }
            }
        }

        /* follow (strict boundary) */
        leash_follow_logic();

        /* scan timeout (aggressive clear) */
        if (g_scan_mode != ""){
            if (now() >= g_scan_expires){
                g_scan_mode=""; g_scan_keys=[]; g_page_idx=0;
                dbg_mem("scan_timeout_cleared");
            }
        }

        /* JSON Anchor fallback to object center */
        if (g_anchor_waiting){
            if (now() >= g_anchor_deadline){
                if (g_anchor_obj != NULL_KEY){ do_leash(g_anchor_obj); }
                g_anchor_waiting = FALSE; g_anchor_deadline=0; g_anchor_session=0; g_anchor_obj=NULL_KEY;
                if (g_holderListen){ llListenRemove(g_holderListen); g_holderListen=0; }
                if (g_user) show_main_menu(g_user,g_last_acl_level);
            }
        }

        /* JSON Worn fallback to avatar center */
        if (g_worn_waiting){
            if (now() >= g_worn_deadline){
                if (g_worn_controller != NULL_KEY){ do_leash(g_worn_controller); }
                g_worn_waiting = FALSE; g_worn_deadline=0; g_worn_session=0; g_worn_controller=NULL_KEY;
                if (g_holderListen){ llListenRemove(g_holderListen); g_holderListen=0; }
                if (g_user) show_main_menu(g_user,g_last_acl_level);
            }
        }

        if (DEBUG) {
            /* once per second memory heartbeat */
            integer t = now();
            if (t != _last_dbg_epoch){
                _last_dbg_epoch = t;
                llOwnerSay("[LEASH][mem] tick : " + (string)freemem());
            }
        }
    }
}
