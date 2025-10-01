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
integer PageIdx     = 0;

/* ---------- UI session ---------- */
key     User            = NULL_KEY;
integer Listen          = 0;
integer MenuChan       = 0;
integer AclPending     = FALSE;
integer LastAclLevel  = ACL_NOACCESS;
integer DialogExpires  = 0;
/* compact mapping for current dialog: [label,cmd,label,cmd,...] */
list    Pairs           = [];

/* ---------- Scan state (avatars only) ---------- */
list    ScanKeys      = [];
integer ScanExpires   = 0;

/* ---------- Leash state ---------- */
integer Leashed        = FALSE;
key     Leasher        = NULL_KEY;      /* avatar or worn-holder prim target */
integer LeashLength   = 2;
integer TurnTo        = FALSE;
integer ControlsOk    = FALSE;

/* ---------- Particles ---------- */
string  ChainTexture  = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";
integer PsysOn        = FALSE;
key     PsysTarget    = NULL_KEY;
vector  LastTarget    = ZERO_VECTOR;
float   LastDist      = -1.0;
float   MoveHyst      = 0.20;
float   MaxLenMargin = 0.98;

/* ---------- Holder handshake (JSON) ---------- */
integer LEASH_HOLDER_CHAN     = -192837465;
integer HOLDER_REPLY_WAIT_SEC = 2;
integer OC_LEASH_POST_CHAN    = -8888; //PATCH: OpenCollar leash posts listen on this fixed channel.
integer OC_LEASH_POST_OFFSET  = 1234;  //PATCH: Offset for computing OpenCollar leash post remote channels.

/* Worn holder (controller’s attachment) */
integer HolderListen       = 0;
integer HolderOcListen     = 0;
integer HolderOcPostListen = 0;
integer HolderOcChannel    = 0;
integer WornWaiting     = FALSE;
integer WornSession     = 0;
key     WornController  = NULL_KEY;  /* avatar key we asked */
integer WornDeadline    = 0;

/* ---------- Presence/persistence (auto-reclip) ---------- */
integer OffsimFlag        = FALSE;
integer OffsimStartEpoch  = 0;
float   OFFSIM_GRACE_SEC    = 6.0;

/* Remember last controller to auto-reclip */
key     LastController    = NULL_KEY;
integer ReclipNextEpoch  = 0;

/* ---------- Heartbeat ---------- */
integer HB_TICK_SEC     = 10;   /* base tick; we override to FOLLOW_TICK after init */
integer HB_SILENCE_SEC  = 60;   /* if no ping this long → re-register */
integer LastPingEpoch = 0;

/* ---------- Misc ---------- */
integer logd(string s){ if (DEBUG) llOwnerSay("[LEASH] " + s); return 0; }
integer now(){ return llGetUnixTime(); }
integer json_has(string j, list path){ if (llJsonGetValue(j, path) != JSON_INVALID) return TRUE; return FALSE; }
/* Compute the OpenCollar remote channel for a given controller key and offset. */
integer oc_remote_channel(key controller, integer offset){
    integer chan = -llAbs((integer)("0x" + llGetSubString((string)controller, -7, -1)) + offset);
    return chan;
}

/* ---------- Listener helpers ---------- */
integer reset_listen(){
    if (Listen) llListenRemove(Listen);
    Listen = 0; MenuChan = 0; Pairs = [];
    return 0;
}
integer close_holder_listen(){
    if (HolderListen){
        llListenRemove(HolderListen);
        HolderListen = 0;
    }
    if (HolderOcListen){
        llListenRemove(HolderOcListen);
        HolderOcListen = 0;
    }
    if (HolderOcPostListen){
        llListenRemove(HolderOcPostListen);
        HolderOcPostListen = 0;
    }
    HolderOcChannel = 0;
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
    integer i = 0; integer L = llGetListLength(Pairs);
    while (i + 1 < L){
        if (llList2String(Pairs,i) == label) return llList2String(Pairs,i+1);
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
    LastPingEpoch = now();
    llSetTimerEvent((float)HB_TICK_SEC);
    return 0;
}
integer hb_on_ping_ok(){ LastPingEpoch = now(); return 0; }
integer hb_tick(){
    if ((now() - LastPingEpoch) > HB_SILENCE_SEC){
        register_self();                 /* defensive re-register */
        LastPingEpoch = now();
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
    AclPending = TRUE;
    logd("ACL query → " + (string)av);
    return 0;
}
integer in_allowed_levels(integer lvl){
    if (~llListFindList(ALLOWED_ACL_LEVELS, [lvl])) return TRUE;
    return FALSE;
}
integer allow_open(){
    if (LastAclLevel < 0) return FALSE; /* blacklist */
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
        if (PsysOn){
            llParticleSystem([]);
            PsysOn = FALSE;
        }
        PsysTarget = NULL_KEY;
        return 0;
    }
    if (!PsysOn || PsysTarget != to){
        PsysTarget = to;
        llParticleSystem([
            PSYS_SRC_PATTERN, PSYS_SRC_PATTERN_DROP,
            PSYS_SRC_TEXTURE, ChainTexture,
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
        PsysOn = TRUE;
    }
    return 0;
}

/* *** PATCHED: stop across the entire linkset for reliable undraw *** */
integer stop_leash_particles(){
    /* Stop any emitters regardless of how they were started */
    llParticleSystem([]);
    llLinkParticleSystem(LINK_SET, []);   /* added: hard-stop on all child prims too */
    PsysOn = FALSE;
    PsysTarget = NULL_KEY;
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
    if (!Leashed) return 0;
    if (Leasher == NULL_KEY) return 0;

    vector leash_pt = leash_ring_world();
    if (Leasher != llGetOwner()){
        list det = llGetObjectDetails(Leasher,[OBJECT_POS]);
        if (llGetListLength(det) > 0) leash_pt = llList2Vector(det,0);
    }

    vector wearer = llGetRootPosition();
    vector offset = wearer - leash_pt;
    float dist = llVecMag(offset);

    if (ControlsOk){
        if (dist > (float)LeashLength){
            vector tgt = leash_pt + llVecNorm(offset) * (float)LeashLength * MaxLenMargin;
            if (llVecMag(tgt - LastTarget) > MoveHyst){
                llMoveToTarget(tgt,0.5);
                LastTarget = tgt;
            }
            if (TurnTo) turn_to_leasher(Leasher);
        } else {
            if (LastDist >= 0.0){
                if (LastDist > (float)LeashLength){
                    llStopMoveToTarget();
                    LastTarget = ZERO_VECTOR;
                }
            }
        }
    }

    LastDist = dist;
    draw_leash_particles(Leasher);
    return 0;
}

/* =============================================================
   UI builders
   ============================================================= */
integer begin_dialog_ctx(key user, string body, list pairs){
    reset_listen();
    User  = user;
    Pairs = pairs;
    list labels = pairs_to_labels(pairs);
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    Listen    = llListen(MenuChan,"",User,"");
    llDialog(User, body, labels, MenuChan);
    DialogExpires = now() + DIALOG_TIMEOUT;
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
    if (Leashed) menu += "Leashed to: " + llKey2Name(Leasher) + "\n";
    else           menu += "Not leashed\n";

    menu += "Length: " + (string)LeashLength + " m";
    if (TurnTo) menu += "\nTurn: ON";
    else           menu += "\nTurn: OFF";

    return begin_dialog_ctx(user, menu, make_menu_pairs(acl));
}

/* Set length picker */
integer do_set_len(integer m){
    if (m < 1)  m = 1;
    if (m > 30) m = 30;
    LeashLength = m;

    /* Immediate response to length change */
    LastTarget = ZERO_VECTOR;
    LastDist   = -1.0;
    if (Leashed){
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
    return begin_dialog_ctx(User,"Pick leash length (m)",pairs);
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
    Leasher = who;
    Leashed = TRUE;
    OffsimFlag = FALSE;
    OffsimStartEpoch = 0;
    draw_leash_particles(Leasher);
    return TRUE;
}
integer do_unclip(){
    Leashed = FALSE;
    Leasher = NULL_KEY;
    llStopMoveToTarget();
    LastTarget = ZERO_VECTOR;
    stop_leash_particles();          /* <-- patched stop (now linkset-wide) */
    OffsimFlag = FALSE;
    OffsimStartEpoch = 0;
    //PATCH: Manual unclip must cancel any pending holder handshake.
    WornWaiting = FALSE;
    WornDeadline = 0;
    WornSession = 0;
    close_holder_listen();
    return TRUE;
}

/* =============================================================
   Holder handshake (JSON + OpenCollar compatibility)
   -------------------------------------------------
   NOTE: Both the DS JSON exchange and the OpenCollar remote channels
         must stay in sync. Future updates should keep the dual-protocol
         flow intact — we send on the base (offset 0) remote channel and
         the leash-post broadcast (-8888) channel so holders that only
         understand one format still respond.
   ============================================================= */
integer begin_worn_holder_handshake(key controller){
    close_holder_listen();
    HolderListen = llListen(LEASH_HOLDER_CHAN,"",NULL_KEY,"");
    //PATCH: Derive the OpenCollar remote channel from the wearer (llGetOwner) so particles target the anchor, not the controller.
    HolderOcChannel = oc_remote_channel(llGetOwner(), 0);
    HolderOcListen = llListen(HolderOcChannel, "", NULL_KEY, "");
    HolderOcPostListen = llListen(OC_LEASH_POST_CHAN, "", NULL_KEY, "");

    WornSession   = (integer)llFrand(2147483000.0);
    WornController= controller;
    WornWaiting   = TRUE;
    WornDeadline  = now() + HOLDER_REPLY_WAIT_SEC;

    LastController = controller; /* remember for auto-reclip */

    string req = llList2Json(JSON_OBJECT,[]);
    req = llJsonSetValue(req,["type"],      "leash_req");
    req = llJsonSetValue(req,["wearer"],    (string)llGetOwner());
    req = llJsonSetValue(req,["collar"],    (string)llGetKey());
    req = llJsonSetValue(req,["controller"],(string)controller);
    req = llJsonSetValue(req,["session"],   (string)WornSession);
    llRegionSay(LEASH_HOLDER_CHAN,req);
    if (controller != NULL_KEY){
        integer wearer_chan = oc_remote_channel(controller, 0);
        integer post_chan = oc_remote_channel(controller, 1234);
        /* OpenCollar request: send our collar key on both wearer-based remote and post channels so the holder advertises via "anchor <primKey>". */
        llRegionSayTo(controller, wearer_chan, (string)llGetKey());
        //PATCH: Broadcast on the derived post channel and the legacy leash-post channel for compatibility.
        llRegionSay(post_chan, (string)llGetKey());
        llRegionSay(OC_LEASH_POST_CHAN, (string)llGetKey());
    }
    return TRUE;
}

integer finish_holder_handshake(key leash_target){
    if (leash_target == NULL_KEY) leash_target = WornController;
    if (leash_target != NULL_KEY) do_leash(leash_target);
    WornWaiting = FALSE;
    WornDeadline = 0;
    WornSession = 0;
    close_holder_listen();
    if (User != NULL_KEY) show_main_menu(User, LastAclLevel);
    return TRUE;
}
integer do_toggle_turn(){
    if (TurnTo) TurnTo = FALSE;
    else TurnTo = TRUE;
    if (!TurnTo) clear_turn();
    return TRUE;
}

/* =============================================================
   Scanning (avatars only)
   ============================================================= */
integer start_avatar_scan(){
    ScanKeys = [];
    PageIdx  = 0;
    ScanExpires = now() + SCAN_TIMEOUT;
    llSensor("",NULL_KEY,AGENT,SCAN_RADIUS,SCAN_ARC);
    return TRUE;
}
integer show_scan_page(){
    integer total = llGetListLength(ScanKeys);
    if (total <= 0){
        llRegionSayTo(User, 0, "No nearby avatars.");
        show_main_menu(User, LastAclLevel);
        return FALSE;
    }

    integer per = MAX_PAGE_ITEMS;
    integer start = PageIdx * per;
    integer end = start + per - 1;
    if (end >= total) end = total - 1;

    string head = "Select person (" + (string)(start+1) + "-" + (string)(end+1) + "/" + (string)total + "):\n";
    list pairs = [];
    if (PageIdx > 0) pairs += ["<<", "prev"];
    pairs += ["Back", CMD_BACK];
    if ((end + 1) < total) pairs += [">>", "next"];

    integer i = start;
    integer lineNo = 1;
    while (i <= end){
        key k = llList2Key(ScanKeys, i);
        string nm = llKey2Name(k); if (nm == "") nm = (string)k;
        head += (string)lineNo + ". " + nm + "\n";
        pairs += [(string)lineNo, CMD_PICK + ":" + (string)i];
        i = i + 1; lineNo = lineNo + 1;
    }
    return begin_dialog_ctx(User, head, pairs);
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        /* Hard unclip on any (re)start */
        do_unclip();

        /* reset UI + listeners */
        User = NULL_KEY;
        reset_listen();
        close_holder_listen();
        AclPending = FALSE;
        LastAclLevel = ACL_NOACCESS;

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
        if ((p & PERMISSION_TAKE_CONTROLS) != 0) ControlsOk = TRUE;
        else ControlsOk = FALSE;
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
                    User = id;
                    request_acl(User);
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
            if (av != User) return;

            if (!json_has(msg, ["level"])) return;
            LastAclLevel = (integer)llJsonGetValue(msg, ["level"]);
            AclPending = FALSE;

            if (!allow_open() || !in_allowed_levels(LastAclLevel)){
                llRegionSayTo(User, 0, "Access denied.");
                ui_return_root(User);
                User = NULL_KEY;
                reset_listen();
                return;
            }

            show_main_menu(User, LastAclLevel);
            return;
        }
    }

    /* Sensor results (avatar scan) */
    sensor(integer num){
        ScanKeys = [];
        integer i = 0;
        while (i < num){
            key k = llDetectedKey(i);
            if (k != llGetOwner()) ScanKeys += [k];
            i = i + 1;
        }
        show_scan_page();
    }
    no_sensor(){
        llRegionSayTo(User,0,"No nearby avatars.");
        show_main_menu(User, LastAclLevel);
    }

    /* Listens: holder handshake & dialog */
    listen(integer chan, string nm, key id, string text){
        /* OpenCollar remote channel reply */
        if (HolderOcChannel != 0 && chan == HolderOcChannel){
            if (!WornWaiting) return;
            string msg = llStringTrim(text, STRING_TRIM);
            integer sep = llSubStringIndex(msg, " ");
            if (sep == -1) return;
            if (llToLower(llGetSubString(msg, 0, sep - 1)) != "anchor") return;
            string prim_str = llStringTrim(llGetSubString(msg, sep + 1, -1), STRING_TRIM);
            key prim = (key)prim_str;
            if (prim == NULL_KEY) return;
            finish_holder_handshake(prim);
            return;
        }

        if (chan == OC_LEASH_POST_CHAN){
            if (!WornWaiting) return;
            string trimmed = llStringTrim(text, STRING_TRIM);
            string wearer_key = (string)llGetOwner();
            integer wearer_len = llStringLength(wearer_key);
            if (wearer_len <= 0) return;
            if (llStringLength(trimmed) <= wearer_len) return;
            if (llGetSubString(trimmed, 0, wearer_len - 1) != wearer_key) return;
            string suffix = llStringTrim(llGetSubString(trimmed, wearer_len, -1), STRING_TRIM);
            if (llToLower(suffix) != "handle ok") return;
            finish_holder_handshake(id);
            return;
        }

        /* Holder channel (worn holder only) */
        if (chan == LEASH_HOLDER_CHAN){
            if (!WornWaiting) return;
            if (!json_has(text,["type"])) return;
            if (llJsonGetValue(text,["type"]) != "leash_target") return;

            integer okSess2 = FALSE;
            if (json_has(text,["session"])){
                integer s2 = (integer)llJsonGetValue(text,["session"]);
                if (s2 == WornSession) okSess2 = TRUE;
            }
            if (!okSess2) return;

            //PATCH: Ignore stale holder replies after a manual unclip.
            if (!WornWaiting) return;

            integer ok2 = 0;
            if (json_has(text,["ok"])) ok2 = (integer)llJsonGetValue(text,["ok"]);

            if (ok2 == 1 && json_has(text,["holder"])){
                key prim2 = (key)llJsonGetValue(text,["holder"]);
                if (prim2 != NULL_KEY){
                    finish_holder_handshake(prim2);
                    return;
                }
            }

            /* Fallback: leash to avatar center if reply says not ok */
            finish_holder_handshake(NULL_KEY);
            return;
        }

        /* Dialog channel */
        if (chan != MenuChan) return;

        string cmd = cmd_from_label(text);
        if (cmd == ""){
            show_main_menu(User, LastAclLevel);
            return;
        }

        if (cmd == CMD_BACK){
            ui_return_root(User);          /* plugin root → main UI */
            User = NULL_KEY;
            reset_listen();
            return;
        }

        if (cmd == CMD_CLIP){
            start_avatar_scan();
            return;
        }

        if (cmd == CMD_UNCLIP){
            do_unclip();
            show_main_menu(User,LastAclLevel);
            return;
        }

        if (cmd == CMD_SETLEN){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[LastAclLevel]) == -1){
                llRegionSayTo(User,0,"You do not have permission to set leash length.");
                show_main_menu(User,LastAclLevel);
                return;
            }
            show_length_menu();
            return;
        }

        if (cmd == CMD_SETVAL){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[LastAclLevel]) == -1){
                llRegionSayTo(User,0,"You do not have permission to set leash length.");
                show_main_menu(User,LastAclLevel);
                return;
            }
            integer meters = (integer)text; /* label carries value */
            do_set_len(meters);
            show_main_menu(User,LastAclLevel);
            return;
        }

        if (cmd == CMD_TURN){
            do_toggle_turn();
            show_main_menu(User,LastAclLevel);
            return;
        }

        if (cmd == CMD_GIVEH){
            if (llListFindList(ALLOWED_GIVEH_LEVELS,[LastAclLevel]) == -1){
                llRegionSayTo(User,0,"You do not have permission to use that.");
                show_main_menu(User,LastAclLevel);
                return;
            }
            string ITEM = "DS Collar leash holder";
            integer t = llGetInventoryType(ITEM);
            if (t != INVENTORY_OBJECT){
                llRegionSayTo(User,0,"The ‘Leash Holder’ object is missing from the collar inventory.");
            } else {
                llGiveInventory(User, ITEM);
                llRegionSayTo(User,0,"Leash holder sent.\nWear or rez it to use as a leash target.");
            }
            show_main_menu(User,LastAclLevel);
            return;
        }

        if (llSubStringIndex(cmd,":") != -1){ /* pick: */
            integer p = llSubStringIndex(cmd,":");
            string head = llGetSubString(cmd,0,p-1);
            if (head == CMD_PICK){
                integer abs = (integer)llGetSubString(cmd,p+1,-1);
                if (abs >= 0 && abs < llGetListLength(ScanKeys)){
                    key target = llList2Key(ScanKeys,abs);
                    begin_worn_holder_handshake(target);
                    return;
                }
            }
        }

        if (cmd == "prev"){
            if (PageIdx > 0) PageIdx = PageIdx - 1;
            show_scan_page();
            return;
        }
        if (cmd == "next"){
            integer total = llGetListLength(ScanKeys);
            integer maxPage = 0;
            if (total > 0) maxPage = (total - 1) / MAX_PAGE_ITEMS;
            if (PageIdx < maxPage) PageIdx = PageIdx + 1;
            show_scan_page();
            return;
        }

        show_main_menu(User,LastAclLevel);
    }

    /* Timer (heartbeat + follow + timeouts) */
    timer(){
        /* Heartbeat maintenance */
        hb_tick();

        /* Dialog timeout */
        if (DialogExpires != 0){
            if (now() >= DialogExpires){
                reset_listen();
                DialogExpires = 0;
            }
        }

        /* Follow physics */
        leash_follow_logic();

        /* Scan timeout */
        if (ScanKeys != []){
            if (now() >= ScanExpires){
                ScanKeys=[]; PageIdx=0;
            }
        }

        /* Holder handshake timeout → fallback to avatar center */
        if (WornWaiting && now() >= WornDeadline){
            integer sessionActive = (WornSession != 0);
            WornDeadline = 0;
            WornSession = 0;
            if (sessionActive && WornController != NULL_KEY){
                finish_holder_handshake(WornController);
            } else {
                WornWaiting = FALSE;
                close_holder_listen();
            }
        }

        /* Presence / auto-release + auto-reclip */
        if (Leashed){
            integer present = FALSE;
            if (LastController != NULL_KEY){
                integer ai = llGetAgentInfo(LastController);
                if (ai != 0) present = TRUE;
            } else if (Leasher != NULL_KEY){
                list d2 = llGetObjectDetails(Leasher,[OBJECT_POS]);
                if (llGetListLength(d2) >= 1 && llList2Vector(d2,0) != ZERO_VECTOR) present = TRUE;
            }

            if (!present){
                if (!OffsimFlag){
                    OffsimFlag = TRUE;
                    OffsimStartEpoch = now();
                }
            } else {
                if (OffsimFlag){
                    OffsimFlag = FALSE;
                    OffsimStartEpoch = 0;
                }
            }

            if (OffsimFlag){
                integer elapsed = now() - OffsimStartEpoch;
                if ((float)elapsed >= OFFSIM_GRACE_SEC){
                    do_unclip();
                    ReclipNextEpoch = now() + 2;
                }
            }
        } else {
            /* Not currently leashed → attempt auto-reclip when back */
            if (ReclipNextEpoch != 0 && now() >= ReclipNextEpoch){
                ReclipNextEpoch = now() + 2; /* throttle */
                if (LastController != NULL_KEY){
                    integer ai2 = llGetAgentInfo(LastController);
                    if (ai2 != 0){
                        begin_worn_holder_handshake(LastController);
                    }
                }
            }
        }
    }
}
