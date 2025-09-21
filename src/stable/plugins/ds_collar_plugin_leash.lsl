/* =============================================================
   PLUGIN: ds_collar_plugin_leash.lsl
   ROLE  : Leashing & Movement Restraint (AVATAR-ONLY)
   NOTES : - "Clip to…" opens avatar scan directly (no object anchors).
           - Handshake with worn holder; fallback to avatar center on timeout.
           - Immediate Set Length effect; pulls to boundary.
           - Off-sim/offline: grace → auto-unclip; auto-reclip when back.
           - AUTH gate; proper Back handling to main UI.
           - Heartbeat: replies to kernel PING; re-registers on silence.
           - Safe listeners; JSON-only link protocol.
   ============================================================= */

integer DEBUG = FALSE;

/* ---------- Kernel link numbers ---------- */
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
string  PLUGIN_CONTEXT   = "core_leash";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Leashing";
integer PLUGIN_MIN_ACL   = 1;        /* wearer+public and up */

integer REG_HAS_TPE      = FALSE;    /* no TPE dual display */
integer REG_TPE_MIN_ACL  = 0;
string  REG_LABEL_TPE    = "";
string  REG_AUDIENCE     = "all";

/* ---------- ACL levels ---------- */
integer ACL_BLACKLIST = -1;
integer ACL_NOACCESS  = 0;
integer ACL_PUBLIC    = 1;
integer ACL_OWNED     = 2;
integer ACL_TRUSTEE   = 3;
integer ACL_UNOWNED   = 4;
integer ACL_PRIMARY_OWNER = 5;

/* Allowed ACLs for opening UI (1..5) */
list ALLOWED_ACL_LEVELS  = [ACL_PUBLIC, ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

/* Specific action gating (preserved) */
list ALLOWED_GIVEH_LEVELS = [ACL_PUBLIC, ACL_TRUSTEE, ACL_PRIMARY_OWNER];
list ALLOWED_SETLEN_LEVELS= [ACL_PUBLIC, ACL_TRUSTEE, ACL_PRIMARY_OWNER];

/* ---------- UI (dialog + scanning) ---------- */
integer DIALOG_TIMEOUT = 180;
integer SCAN_TIMEOUT   = 30;
float   FOLLOW_TICK    = 0.5;   /* physics tick */

/* Commands (neutral labels→cmd mapping) */
string CMD_BACK   = "back";
string CMD_CLIP   = "clip";     /* now goes straight to avatar scan */
string CMD_PICK   = "pick";     /* pick: */
string CMD_UNCLIP = "unclip";
string CMD_SETLEN = "setlen";
string CMD_SETVAL = "setval";
string CMD_TURN   = "turn";
string CMD_GIVEH  = "giveholder";

/* ---------- Scan (avatars only) ---------- */
float  SCAN_RADIUS = 5.0;
float  SCAN_ARC    = TWO_PI;

integer MAX_PAGE_ITEMS = 9;
integer g_page_idx     = 0;

/* ---------- UI session ---------- */
key     g_user            = NULL_KEY;
integer g_listen          = 0;
integer g_menu_chan       = 0;
integer g_acl_pending     = FALSE;
integer g_last_acl_level  = ACL_NOACCESS;
integer g_dialog_expires  = 0;
/* compact mapping for current dialog: [label,cmd,label,cmd,...] */
list    g_pairs           = [];

/* ---------- Scan state (avatars only) ---------- */
list    g_scan_keys      = [];
integer g_scan_expires   = 0;

/* ---------- Leash state ---------- */
integer g_leashed        = FALSE;
key     g_leasher        = NULL_KEY;      /* avatar or worn-holder prim target */
integer g_leash_length   = 2;
integer g_turn_to        = FALSE;
integer g_controls_ok    = FALSE;

/* ---------- Particles ---------- */
string  g_chain_texture  = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";
integer g_psys_on        = FALSE;
key     g_psys_target    = NULL_KEY;
vector  g_last_target    = ZERO_VECTOR;
float   g_last_dist      = -1.0;
float   g_move_hyst      = 0.20;
float   g_max_len_margin = 0.98;

/* ---------- Holder handshake (JSON) ---------- */
integer LEASH_HOLDER_CHAN     = -192837465;
integer HOLDER_REPLY_WAIT_SEC = 2;

/* Worn holder (controller’s attachment) */
integer g_holderListen     = 0;
integer g_worn_waiting     = FALSE;
integer g_worn_session     = 0;
key     g_worn_controller  = NULL_KEY;  /* avatar key we asked */
integer g_worn_deadline    = 0;

/* ---------- Presence/persistence (auto-reclip) ---------- */
integer g_offsimFlag        = FALSE;
integer g_offsimStartEpoch  = 0;
float   OFFSIM_GRACE_SEC    = 6.0;

/* Remember last controller to auto-reclip */
key     g_last_controller    = NULL_KEY;
integer g_reclip_next_epoch  = 0;

/* ---------- Heartbeat ---------- */
integer HB_TICK_SEC     = 10;   /* base tick; we override to FOLLOW_TICK after init */
integer HB_SILENCE_SEC  = 60;   /* if no ping this long → re-register */
integer g_lastPingEpoch = 0;

/* ---------- Misc ---------- */
integer logd(string s){ if (DEBUG) llOwnerSay("[LEASH] " + s); return 0; }
integer now(){ return llGetUnixTime(); }
integer json_has(string j, list path){ if (llJsonGetValue(j, path) != JSON_INVALID) return TRUE; return FALSE; }

/* ---------- Listener helpers ---------- */
integer reset_listen(){
    if (g_listen) llListenRemove(g_listen);
    g_listen = 0; g_menu_chan = 0; g_pairs = [];
    return 0;
}
integer close_holder_listen(){
    if (g_holderListen){
        llListenRemove(g_holderListen);
        g_holderListen = 0;
    }
    return TRUE;
}

/* ---------- Pairs helpers ---------- */
list pairs_to_labels(list pairs){
    list labels = [];
    integer i = 0; integer L = llGetListLength(pairs);
    while (i < L){ labels += llList2String(pairs, i); i = i + 2; }
    return labels;
}
string cmd_from_label(string label){
    integer i = 0; integer L = llGetListLength(g_pairs);
    while (i + 1 < L){
        if (llList2String(g_pairs,i) == label) return llList2String(g_pairs,i+1);
        i = i + 2;
    }
    return "";
}

/* =============================================================
   Registration + Heartbeat
   ============================================================= */
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
    if (REG_AUDIENCE != "all") j = llJsonSetValue(j, ["audience"], REG_AUDIENCE);
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

/* HB init: call after register_self(); we then tighten timer to FOLLOW_TICK */
integer hb_init(){
    g_lastPingEpoch = now();
    llSetTimerEvent((float)HB_TICK_SEC);
    return 0;
}
integer hb_on_ping_ok(){ g_lastPingEpoch = now(); return 0; }
integer hb_tick(){
    if ((now() - g_lastPingEpoch) > HB_SILENCE_SEC){
        register_self();                 /* defensive re-register */
        g_lastPingEpoch = now();
    }
    return 0;
}

/* =============================================================
   AUTH gate (minimal + allowed list)
   ============================================================= */
integer request_acl(key av){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j, ["type"],   MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    g_acl_pending = TRUE;
    logd("ACL query → " + (string)av);
    return 0;
}
integer in_allowed_levels(integer lvl){
    if (~llListFindList(ALLOWED_ACL_LEVELS, [lvl])) return TRUE;
    return FALSE;
}
integer allow_open(){
    if (g_last_acl_level < 0) return FALSE; /* blacklist */
    return TRUE;
}

/* =============================================================
   Particles & Follow
   ============================================================= */
vector leash_ring_world(){
    integer n = llGetNumberOfPrims(); integer i = 2;
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
        if (g_psys_on){
            llParticleSystem([]);
            g_psys_on = FALSE;
        }
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
            PSYS_PART_END_ALPHA,   1.0,
            PSYS_PART_MAX_AGE,     2.6,
            PSYS_PART_START_SCALE, <0.07,0.07,0>,
            PSYS_PART_END_SCALE,   <0.07,0.07,0>,
            PSYS_PART_START_COLOR, <1,1,1>,
            PSYS_PART_END_COLOR,   <1,1,1>,
            PSYS_SRC_ACCEL,        <0,0,-1.25>,
            PSYS_PART_FLAGS, PSYS_PART_INTERP_COLOR_MASK
                              | PSYS_PART_FOLLOW_SRC_MASK
                              | PSYS_PART_TARGET_POS_MASK
                              | PSYS_PART_FOLLOW_VELOCITY_MASK
                              | PSYS_PART_RIBBON_MASK,
            PSYS_SRC_TARGET_KEY, to
        ]);
        g_psys_on = TRUE;
    }
    return 0;
}

/* *** PATCHED: stop across the entire linkset for reliable undraw *** */
integer stop_leash_particles(){
    /* Stop any emitters regardless of how they were started */
    llParticleSystem([]);
    llLinkParticleSystem(LINK_SET, []);   /* added: hard-stop on all child prims too */
    g_psys_on = FALSE;
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
    float dist = llVecMag(offset);

    if (g_controls_ok){
        if (dist > (float)g_leash_length){
            vector tgt = leash_pt + llVecNorm(offset) * (float)g_leash_length * g_max_len_margin;
            if (llVecMag(tgt - g_last_target) > g_move_hyst){
                llMoveToTarget(tgt,0.5);
                g_last_target = tgt;
            }
            if (g_turn_to) turn_to_leasher(g_leasher);
        } else {
            if (g_last_dist >= 0.0){
                if (g_last_dist > (float)g_leash_length){
                    llStopMoveToTarget();
                    g_last_target = ZERO_VECTOR;
                }
            }
        }
    }

    g_last_dist = dist;
    draw_leash_particles(g_leasher);
    return 0;
}

/* =============================================================
   Holder JSON handshake (avatars only)
   ============================================================= */
integer begin_worn_holder_handshake(key controller){
    close_holder_listen();
    g_holderListen = llListen(LEASH_HOLDER_CHAN,"",NULL_KEY,"");

    g_worn_session   = (integer)llFrand(2147483000.0);
    g_worn_controller= controller;
    g_worn_waiting   = TRUE;
    g_worn_deadline  = now() + HOLDER_REPLY_WAIT_SEC;

    g_last_controller = controller; /* remember for auto-reclip */

    string req = llList2Json(JSON_OBJECT,[]);
    req = llJsonSetValue(req,["type"],      "leash_req");
    req = llJsonSetValue(req,["wearer"],    (string)llGetOwner());
    req = llJsonSetValue(req,["collar"],    (string)llGetKey());
    req = llJsonSetValue(req,["controller"],(string)controller);
    req = llJsonSetValue(req,["session"],   (string)g_worn_session);
    llRegionSay(LEASH_HOLDER_CHAN,req);
    return TRUE;
}

/* =============================================================
   UI builders
   ============================================================= */
integer begin_dialog_ctx(key user, string body, list pairs){
    reset_listen();
    g_user  = user;
    g_pairs = pairs;
    list labels = pairs_to_labels(pairs);
    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen    = llListen(g_menu_chan,"",g_user,"");
    llDialog(g_user, body, labels, g_menu_chan);
    g_dialog_expires = now() + DIALOG_TIMEOUT;
    return TRUE;
}

list make_menu_pairs(integer acl){
    list pairs = [];
    if (acl == ACL_PUBLIC){
        pairs += ["Clip to…", CMD_CLIP,
                  "Unclip",  CMD_UNCLIP,
                  "Give holder", CMD_GIVEH];
    } else if (acl == ACL_OWNED){
        pairs += ["Clip to…", CMD_CLIP];
    } else if (acl == ACL_TRUSTEE){
        pairs += ["Clip to…", CMD_CLIP,
                  "Unclip",  CMD_UNCLIP,
                  "Set Length", CMD_SETLEN,
                  "Turn", CMD_TURN,
                  "Give holder", CMD_GIVEH];
    } else if (acl == ACL_UNOWNED){
        pairs += ["Clip to…", CMD_CLIP,
                  "Unclip",  CMD_UNCLIP];
    } else { /* primary owner */
        pairs += ["Clip to…", CMD_CLIP,
                  "Unclip",  CMD_UNCLIP,
                  "Set Length", CMD_SETLEN,
                  "Turn", CMD_TURN,
                  "Give holder", CMD_GIVEH];
    }
    pairs += ["Back", CMD_BACK];
    return pairs;
}

integer show_main_menu(key user, integer acl){
    string menu = "Leash:\n";
    if (g_leashed) menu += "Leashed to: " + llKey2Name(g_leasher) + "\n";
    else           menu += "Not leashed\n";

    menu += "Length: " + (string)g_leash_length + " m";
    if (g_turn_to) menu += "\nTurn: ON";
    else           menu += "\nTurn: OFF";

    return begin_dialog_ctx(user, menu, make_menu_pairs(acl));
}

/* Set length picker */
integer do_set_len(integer m){
    if (m < 1)  m = 1;
    if (m > 30) m = 30;
    g_leash_length = m;

    /* Immediate response to length change */
    g_last_target = ZERO_VECTOR;
    g_last_dist   = -1.0;
    if (g_leashed){
        leash_follow_logic();
    }
    return TRUE;
}

integer show_length_menu(){
    list labels = ["1","2","3","5","8","10","12","15","20"];
    list pairs = [];
    integer i = 0; integer L = llGetListLength(labels);
    while (i < L){
        string lab = llList2String(labels,i);
        pairs += [lab, CMD_SETVAL];
        i = i + 1;
    }
    pairs += ["Back", CMD_BACK];
    return begin_dialog_ctx(g_user,"Pick leash length (m)",pairs);
}

/* Root return */
integer ui_return_root(key toUser){
    string r = llList2Json(JSON_OBJECT,[]);
    r = llJsonSetValue(r, ["type"],    TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, toUser);
    return 0;
}

/* Core actions */
integer do_leash(key who){
    if (who == NULL_KEY) return FALSE;
    g_leasher = who;
    g_leashed = TRUE;
    g_offsimFlag = FALSE;
    g_offsimStartEpoch = 0;
    draw_leash_particles(g_leasher);
    return TRUE;
}
integer do_unclip(){
    g_leashed = FALSE;
    g_leasher = NULL_KEY;
    llStopMoveToTarget();
    g_last_target = ZERO_VECTOR;
    stop_leash_particles();          /* <-- patched stop (now linkset-wide) */
    g_offsimFlag = FALSE;
    g_offsimStartEpoch = 0;
    return TRUE;
}
integer do_toggle_turn(){
    if (g_turn_to) g_turn_to = FALSE;
    else g_turn_to = TRUE;
    if (!g_turn_to) clear_turn();
    return TRUE;
}

/* =============================================================
   Scanning (avatars only)
   ============================================================= */
integer start_avatar_scan(){
    g_scan_keys = [];
    g_page_idx  = 0;
    g_scan_expires = now() + SCAN_TIMEOUT;
    llSensor("",NULL_KEY,AGENT,SCAN_RADIUS,SCAN_ARC);
    return TRUE;
}
integer show_scan_page(){
    integer total = llGetListLength(g_scan_keys);
    if (total <= 0){
        llRegionSayTo(g_user, 0, "No nearby avatars.");
        show_main_menu(g_user, g_last_acl_level);
        return FALSE;
    }

    integer per = MAX_PAGE_ITEMS;
    integer start = g_page_idx * per;
    integer end = start + per - 1;
    if (end >= total) end = total - 1;

    string head = "Select person (" + (string)(start+1) + "-" + (string)(end+1) + "/" + (string)total + "):\n";
    list pairs = [];
    if (g_page_idx > 0) pairs += ["<<", "prev"];
    pairs += ["Back", CMD_BACK];
    if ((end + 1) < total) pairs += [">>", "next"];

    integer i = start;
    integer lineNo = 1;
    while (i <= end){
        key k = llList2Key(g_scan_keys, i);
        string nm = llKey2Name(k); if (nm == "") nm = (string)k;
        head += (string)lineNo + ". " + nm + "\n";
        pairs += [(string)lineNo, CMD_PICK + ":" + (string)i];
        i = i + 1; lineNo = lineNo + 1;
    }
    return begin_dialog_ctx(g_user, head, pairs);
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        /* Hard unclip on any (re)start */
        do_unclip();

        /* reset UI + listeners */
        g_user = NULL_KEY;
        reset_listen();
        close_holder_listen();
        g_acl_pending = FALSE;
        g_last_acl_level = ACL_NOACCESS;

        notify_soft_reset();
        register_self();
        hb_init();                          /* enable heartbeat */
        llSetTimerEvent(FOLLOW_TICK);       /* tighten timer for follow physics */

        /* Controls (for move-to-target restraint) */
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    run_time_permissions(integer p){
        if ((p & PERMISSION_TAKE_CONTROLS) != 0) g_controls_ok = TRUE;
        else g_controls_ok = FALSE;
    }

    /* Kernel lifecycle / heartbeat */
    link_message(integer sender, integer num, string msg, key id){
        /* Kernel soft reset → hard unclip */
        if (num == K_PLUGIN_SOFT_RESET){
            if (json_has(msg,["type"]) && llJsonGetValue(msg,["type"]) == TYPE_PLUGIN_SOFT_RESET){
                integer doClear = TRUE;
                if (json_has(msg,["context"])){
                    string c = llJsonGetValue(msg,["context"]);
                    if (!(c == "all" || c == "*" || c == PLUGIN_CONTEXT)) doClear = FALSE;
                }
                if (doClear){
                    do_unclip();
                }
            }
            return;
        }

        if (num == K_PLUGIN_PING){
            if (json_has(msg, ["type"])){
                if (llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_PING){
                    if (json_has(msg, ["context"])){
                        if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                    }
                    hb_on_ping_ok();
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
                    register_self();        /* re-register on demand */
                    hb_on_ping_ok();
                }
            }
            return;
        }

        /* Secure open: request ACL; show menu after result */
        if (num == K_PLUGIN_START){
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_START){
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT){
                    g_user = id;
                    request_acl(g_user);
                    return;
                }
            }
            return;
        }

        /* AUTH result → decide to open or deny */
        if (num == AUTH_RESULT_NUM){
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;

            key av = (key)llJsonGetValue(msg, ["avatar"]);
            if (av != g_user) return;

            if (!json_has(msg, ["level"])) return;
            g_last_acl_level = (integer)llJsonGetValue(msg, ["level"]);
            g_acl_pending = FALSE;

            if (!allow_open() || !in_allowed_levels(g_last_acl_level)){
                llRegionSayTo(g_user, 0, "Access denied.");
                ui_return_root(g_user);
                g_user = NULL_KEY;
                reset_listen();
                return;
            }

            show_main_menu(g_user, g_last_acl_level);
            return;
        }
    }

    /* Sensor results (avatar scan) */
    sensor(integer num){
        g_scan_keys = [];
        integer i = 0;
        while (i < num){
            key k = llDetectedKey(i);
            if (k != llGetOwner()) g_scan_keys += [k];
            i = i + 1;
        }
        show_scan_page();
    }
    no_sensor(){
        llRegionSayTo(g_user,0,"No nearby avatars.");
        show_main_menu(g_user, g_last_acl_level);
    }

    /* Listens: holder handshake & dialog */
    listen(integer chan, string nm, key id, string text){
        /* Holder channel (worn holder only) */
        if (chan == LEASH_HOLDER_CHAN){
            if (g_worn_waiting){
                if (!json_has(text,["type"])) return;
                if (llJsonGetValue(text,["type"]) != "leash_target") return;

                integer okSess2 = FALSE;
                if (json_has(text,["session"])){
                    integer s2 = (integer)llJsonGetValue(text,["session"]);
                    if (s2 == g_worn_session) okSess2 = TRUE;
                }
                if (!okSess2) return;

                integer ok2 = 0;
                if (json_has(text,["ok"])) ok2 = (integer)llJsonGetValue(text,["ok"]);

                if (ok2 == 1 && json_has(text,["holder"])){
                    key prim2 = (key)llJsonGetValue(text,["holder"]);
                    if (prim2 != NULL_KEY){
                        do_leash(prim2);
                    }
                } else {
                    /* Fallback: leash to avatar center if reply says not ok */
                    do_leash(g_worn_controller);
                }

                g_worn_waiting = FALSE;
                g_worn_deadline= 0;
                g_worn_session = 0;
                close_holder_listen();

                if (g_user != NULL_KEY) show_main_menu(g_user,g_last_acl_level);
                return;
            }
        }

        /* Dialog channel */
        if (chan != g_menu_chan) return;

        string cmd = cmd_from_label(text);
        if (cmd == ""){
            show_main_menu(g_user, g_last_acl_level);
            return;
        }

        if (cmd == CMD_BACK){
            ui_return_root(g_user);          /* plugin root → main UI */
            g_user = NULL_KEY;
            reset_listen();
            return;
        }

        if (cmd == CMD_CLIP){
            start_avatar_scan();
            return;
        }

        if (cmd == CMD_UNCLIP){
            do_unclip();
            show_main_menu(g_user,g_last_acl_level);
            return;
        }

        if (cmd == CMD_SETLEN){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[g_last_acl_level]) == -1){
                llRegionSayTo(g_user,0,"You do not have permission to set leash length.");
                show_main_menu(g_user,g_last_acl_level);
                return;
            }
            show_length_menu();
            return;
        }

        if (cmd == CMD_SETVAL){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[g_last_acl_level]) == -1){
                llRegionSayTo(g_user,0,"You do not have permission to set leash length.");
                show_main_menu(g_user,g_last_acl_level);
                return;
            }
            integer meters = (integer)text; /* label carries value */
            do_set_len(meters);
            show_main_menu(g_user,g_last_acl_level);
            return;
        }

        if (cmd == CMD_TURN){
            do_toggle_turn();
            show_main_menu(g_user,g_last_acl_level);
            return;
        }

        if (cmd == CMD_GIVEH){
            if (llListFindList(ALLOWED_GIVEH_LEVELS,[g_last_acl_level]) == -1){
                llRegionSayTo(g_user,0,"You do not have permission to use that.");
                show_main_menu(g_user,g_last_acl_level);
                return;
            }
            string ITEM = "DS Collar leash holder";
            integer t = llGetInventoryType(ITEM);
            if (t != INVENTORY_OBJECT){
                llRegionSayTo(g_user,0,"The ‘Leash Holder’ object is missing from the collar inventory.");
            } else {
                llGiveInventory(g_user, ITEM);
                llRegionSayTo(g_user,0,"Leash holder sent.\nWear or rez it to use as a leash target.");
            }
            show_main_menu(g_user,g_last_acl_level);
            return;
        }

        if (llSubStringIndex(cmd,":") != -1){ /* pick: */
            integer p = llSubStringIndex(cmd,":");
            string head = llGetSubString(cmd,0,p-1);
            if (head == CMD_PICK){
                integer abs = (integer)llGetSubString(cmd,p+1,-1);
                if (abs >= 0 && abs < llGetListLength(g_scan_keys)){
                    key target = llList2Key(g_scan_keys,abs);
                    begin_worn_holder_handshake(target);
                    return;
                }
            }
        }

        if (cmd == "prev"){
            if (g_page_idx > 0) g_page_idx = g_page_idx - 1;
            show_scan_page();
            return;
        }
        if (cmd == "next"){
            integer total = llGetListLength(g_scan_keys);
            integer maxPage = 0;
            if (total > 0) maxPage = (total - 1) / MAX_PAGE_ITEMS;
            if (g_page_idx < maxPage) g_page_idx = g_page_idx + 1;
            show_scan_page();
            return;
        }

        show_main_menu(g_user,g_last_acl_level);
    }

    /* Timer (heartbeat + follow + timeouts) */
    timer(){
        /* Heartbeat maintenance */
        hb_tick();

        /* Dialog timeout */
        if (g_dialog_expires != 0){
            if (now() >= g_dialog_expires){
                reset_listen();
                g_dialog_expires = 0;
            }
        }

        /* Follow physics */
        leash_follow_logic();

        /* Scan timeout */
        if (g_scan_keys != []){
            if (now() >= g_scan_expires){
                g_scan_keys=[]; g_page_idx=0;
            }
        }

        /* Holder handshake timeout → fallback to avatar center */
        if (g_worn_waiting && now() >= g_worn_deadline){
            g_worn_waiting = FALSE;
            close_holder_listen();
            if (g_worn_controller != NULL_KEY){
                do_leash(g_worn_controller);
                if (g_user != NULL_KEY) show_main_menu(g_user,g_last_acl_level);
            }
        }

        /* Presence / auto-release + auto-reclip */
        if (g_leashed){
            integer present = FALSE;
            if (g_last_controller != NULL_KEY){
                integer ai = llGetAgentInfo(g_last_controller);
                if (ai != 0) present = TRUE;
            } else if (g_leasher != NULL_KEY){
                list d2 = llGetObjectDetails(g_leasher,[OBJECT_POS]);
                if (llGetListLength(d2) >= 1 && llList2Vector(d2,0) != ZERO_VECTOR) present = TRUE;
            }

            if (!present){
                if (!g_offsimFlag){
                    g_offsimFlag = TRUE;
                    g_offsimStartEpoch = now();
                }
            } else {
                if (g_offsimFlag){
                    g_offsimFlag = FALSE;
                    g_offsimStartEpoch = 0;
                }
            }

            if (g_offsimFlag){
                integer elapsed = now() - g_offsimStartEpoch;
                if ((float)elapsed >= OFFSIM_GRACE_SEC){
                    do_unclip();
                    g_reclip_next_epoch = now() + 2;
                }
            }
        } else {
            /* Not currently leashed → attempt auto-reclip when back */
            if (g_reclip_next_epoch != 0 && now() >= g_reclip_next_epoch){
                g_reclip_next_epoch = now() + 2; /* throttle */
                if (g_last_controller != NULL_KEY){
                    integer ai2 = llGetAgentInfo(g_last_controller);
                    if (ai2 != 0){
                        begin_worn_holder_handshake(g_last_controller);
                    }
                }
            }
        }
    }
}
