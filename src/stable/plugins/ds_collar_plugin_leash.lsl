/* =============================================================
   PLUGIN: ds_collar_plugin_leash.lsl
   ROLE  : Leashing & Movement Restraint (AVATAR-ONLY)
   NOTES :
     - "Clip to…" opens avatar scan directly (no object anchors).
     - Handshake with worn holder; fallback to avatar center on timeout.
     - Immediate Set Length effect; pulls to boundary.
     - Off-sim/offline: grace → auto-unclip; auto-reclip when back.
     - AUTH gate; proper Back handling to main UI.
     - Heartbeat: replies to kernel PING; re-registers on silence.
     - Safe listeners; JSON-only link protocol.
   NAMING: PascalCase globals, ALL_CAPS constants, snake_case locals
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
integer PLUGIN_SN        = 0;
integer PLUGIN_MIN_ACL   = 1;              /* wearer+public and up */
integer REG_HAS_TPE      = FALSE;          /* no TPE dual display */
integer REG_TPE_MIN_ACL  = 0;
string  REG_LABEL_TPE    = "";
string  REG_AUDIENCE     = "all";

/* ---------- ACL levels ---------- */
integer ACL_BLACKLIST        = -1;
integer ACL_NOACCESS         = 0;
integer ACL_PUBLIC           = 1;
integer ACL_OWNED            = 2;
integer ACL_TRUSTEE          = 3;
integer ACL_UNOWNED          = 4;
integer ACL_PRIMARY_OWNER    = 5;

/* Allowed ACLs for opening UI (1..5) */
list    ALLOWED_ACL_LEVELS   = [ACL_PUBLIC, ACL_OWNED, ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

/* Specific action gating (preserved) */
list    ALLOWED_GIVEH_LEVELS = [ACL_PUBLIC, ACL_TRUSTEE, ACL_PRIMARY_OWNER];
list    ALLOWED_SETLEN_LEVELS= [ACL_PUBLIC, ACL_TRUSTEE, ACL_PRIMARY_OWNER];

/* ---------- UI (dialog + scanning) ---------- */
integer DIALOG_TIMEOUT    = 180;
integer SCAN_TIMEOUT      = 30;
float   FOLLOW_TICK       = 0.5;    /* physics tick */

/* Commands (neutral labels→cmd mapping) */
string CMD_BACK   = "back";
string CMD_CLIP   = "clip";      /* now goes straight to avatar scan */
string CMD_PICK   = "pick";      /* pick:<absIndex> */

string CMD_UNCLIP = "unclip";
string CMD_SETLEN = "setlen";
string CMD_SETVAL = "setval";
string CMD_TURN   = "turn";
string CMD_GIVEH  = "giveholder";

/* ---------- Scan (avatars only) ---------- */
float   SCAN_RADIUS      = 5.0;
float   SCAN_ARC         = TWO_PI;
integer MAX_PAGE_ITEMS   = 9;
integer PageIdx          = 0;

/* ---------- UI session ---------- */
key     MenuUser         = NULL_KEY;
integer ListenHandle     = 0;
integer MenuChan         = 0;
integer AclPending       = FALSE;
integer AclLevel         = ACL_NOACCESS;
integer DialogExpires    = 0;

/* compact mapping for current dialog: [label,cmd,label,cmd,...] */
list    MenuPairs        = [];

/* ---------- Scan state (avatars only) ---------- */
list    ScanKeys         = [];
integer ScanExpires      = 0;

/* ---------- Leash state ---------- */
integer Leashed          = FALSE;
key     Leasher          = NULL_KEY;   /* avatar or worn-holder prim target */
integer LeashLength      = 2;
integer TurnTo           = FALSE;
integer ControlsOk       = FALSE;

/* ---------- Particles ---------- */
string  ChainTexture     = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";
integer PsysOn           = FALSE;
key     PsysTarget       = NULL_KEY;
vector  LastTarget       = ZERO_VECTOR;
float   LastDist         = -1.0;
float   MoveHyst         = 0.20;
float   MaxLenMargin     = 0.98;
integer LeashpointLink   = 0;

integer LEASH_MODE_NONE   = 0;
integer LEASH_MODE_NATIVE = 1;
integer LEASH_MODE_OC     = 2;
integer LEASH_MODE_AVATAR = 3;
integer LeashRenderMode   = LEASH_MODE_NONE;
integer NextLeashMode     = LEASH_MODE_NATIVE;

/* ---------- Holder handshake (JSON) ---------- */
integer LEASH_HOLDER_CHAN     = -192837465;
integer HOLDER_REPLY_WAIT_SEC = 2;

/* Worn holder (controller's attachment) */
integer HolderListenHandle = 0;
integer WornWaiting        = FALSE;
integer WornSession        = 0;
key     WornController     = NULL_KEY;  /* avatar key we asked */
integer WornDeadline       = 0;
integer WornProtocol       = 0;         /* 0=native,1=oc */

/* ---------- Presence/persistence (auto-reclip) ---------- */
integer OffsimFlag         = FALSE;
integer OffsimStartEpoch   = 0;
float   OFFSIM_GRACE_SEC   = 6.0;

/* Remember last controller to auto-reclip */
key     LastController     = NULL_KEY;
integer ReclipNextEpoch    = 0;

/* ---------- Heartbeat ---------- */
integer HB_TICK_SEC        = 10;   /* base tick; we override to FOLLOW_TICK after init */
integer HB_SILENCE_SEC     = 60;   /* if no ping this long → re-register */
integer LastPingEpoch      = 0;

/* ---------- Misc ---------- */
integer logd(string msg_str){ 
    if (DEBUG) llOwnerSay("[LEASH] " + msg_str); 
    return 0; 
}

integer now(){ 
    return llGetUnixTime(); 
}

integer json_has(string json_str, list path){ 
    if (llJsonGetValue(json_str, path) != JSON_INVALID) return TRUE; 
    return FALSE; 
}

/* ---------- Listener helpers ---------- */
integer reset_listen(){
    if (ListenHandle) llListenRemove(ListenHandle);
    ListenHandle = 0; 
    MenuChan = 0; 
    MenuPairs = [];
    return 0;
}

integer close_holder_listen(){
    if (HolderListenHandle){ 
        llListenRemove(HolderListenHandle); 
        HolderListenHandle = 0; 
    }
    return TRUE;
}

/* ---------- Pairs helpers ---------- */
list pairs_to_labels(list pairs){
    list labels = [];
    integer i = 0; 
    integer list_length = llGetListLength(pairs);
    while (i < list_length){ 
        labels += llList2String(pairs, i); 
        i = i + 2; 
    }
    return labels;
}

string cmd_from_label(string label){
    integer i = 0; 
    integer list_length = llGetListLength(MenuPairs);
    while (i + 1 < list_length){
        if (llList2String(MenuPairs, i) == label) return llList2String(MenuPairs, i+1);
        i = i + 2;
    }
    return "";
}

/* =============================================================
   Registration + Heartbeat
   ============================================================= */
integer register_self(){
    string json_msg = llList2Json(JSON_OBJECT,[]);
    json_msg = llJsonSetValue(json_msg, ["type"],    TYPE_REGISTER);
    json_msg = llJsonSetValue(json_msg, ["sn"],      (string)PLUGIN_SN);
    json_msg = llJsonSetValue(json_msg, ["label"],   PLUGIN_LABEL);
    json_msg = llJsonSetValue(json_msg, ["min_acl"], (string)PLUGIN_MIN_ACL);
    json_msg = llJsonSetValue(json_msg, ["context"], PLUGIN_CONTEXT);
    if (REG_HAS_TPE){
        json_msg = llJsonSetValue(json_msg, ["tpe_min_acl"], (string)REG_TPE_MIN_ACL);
        if (REG_LABEL_TPE != "") json_msg = llJsonSetValue(json_msg, ["label_tpe"], REG_LABEL_TPE);
    }
    if (REG_AUDIENCE != "all") json_msg = llJsonSetValue(json_msg, ["audience"], REG_AUDIENCE);
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, json_msg, NULL_KEY);
    logd("Registered with kernel. Label=" + PLUGIN_LABEL);
    return 0;
}

integer notify_soft_reset(){
    string json_msg = llList2Json(JSON_OBJECT,[]);
    json_msg = llJsonSetValue(json_msg, ["type"],    TYPE_PLUGIN_SOFT_RESET);
    json_msg = llJsonSetValue(json_msg, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, json_msg, NULL_KEY);
    return 0;
}

/* HB init: call after register_self(); we then tighten timer to FOLLOW_TICK */
integer hb_init(){
    LastPingEpoch = now();
    llSetTimerEvent((float)HB_TICK_SEC);
    return 0;
}

integer hb_on_ping_ok(){ 
    LastPingEpoch = now(); 
    return 0; 
}

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
integer request_acl(key avatar_key){
    string json_msg = llList2Json(JSON_OBJECT,[]);
    json_msg = llJsonSetValue(json_msg, ["type"],   MSG_ACL_QUERY);
    json_msg = llJsonSetValue(json_msg, ["avatar"], (string)avatar_key);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, json_msg, NULL_KEY);
    AclPending = TRUE;
    logd("ACL query → " + (string)avatar_key);
    return 0;
}

integer in_allowed_levels(integer level){
    if (~llListFindList(ALLOWED_ACL_LEVELS, [level])) return TRUE;
    return FALSE;
}

integer allow_open(){
    if (AclLevel < 0) return FALSE;          /* blacklist */
    return TRUE;
}

/* =============================================================
   Particles & Follow
   ============================================================= */
vector leash_ring_world(){
    integer prim_count = llGetNumberOfPrims();
    integer i = 2;
    while (i <= prim_count){
        string prim_name = llGetLinkName(i);
        string prim_desc = llList2String(llGetLinkPrimitiveParams(i,[PRIM_DESC]),0);
        if (llToLower(prim_name) == "leashring" || llToLower(prim_desc) == "leash:ring"){
            vector local_pos = llList2Vector(llGetLinkPrimitiveParams(i,[PRIM_POS_LOCAL]),0);
            return llGetRootPosition() + (local_pos * llGetRootRotation());
        }
        i = i + 1;
    }
    return llGetRootPosition();
}

integer find_leashpoint_link(){
    integer prim_count = llGetNumberOfPrims();
    integer i = 2;
    while (i <= prim_count){
        list params = llGetLinkPrimitiveParams(i,[PRIM_NAME, PRIM_DESC]);
        string prim_name = llToLower(llStringTrim(llList2String(params,0), STRING_TRIM));
        string prim_desc = llToLower(llStringTrim(llList2String(params,1), STRING_TRIM));
        if (prim_name == "leashpoint" && prim_desc == "leashpoint") return i;
        i = i + 1;
    }
    return LINK_ROOT;
}

integer apply_ribbon_particles(integer link, key target){
    list flags = [
        PSYS_PART_INTERP_COLOR_MASK,
        PSYS_PART_FOLLOW_SRC_MASK,
        PSYS_PART_TARGET_POS_MASK,
        PSYS_PART_FOLLOW_VELOCITY_MASK,
        PSYS_PART_RIBBON_MASK
    ];
    integer i = 0;
    integer list_length = llGetListLength(flags);
    integer mask = 0;
    while (i < list_length){ 
        mask = mask | llList2Integer(flags, i); 
        i = i + 1; 
    }

    list settings = [
        PSYS_SRC_PATTERN, PSYS_SRC_PATTERN_DROP,
        PSYS_SRC_TEXTURE, ChainTexture,
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
        PSYS_PART_FLAGS, mask,
        PSYS_SRC_TARGET_KEY, target
    ];
    llLinkParticleSystem(link, settings);
    return TRUE;
}

integer draw_leash_particles(key target_key){
    if (LeashpointLink == 0){ 
        LeashpointLink = find_leashpoint_link(); 
    }
    if (target_key == NULL_KEY){
        if (PsysOn){ 
            llLinkParticleSystem(LeashpointLink, []); 
            PsysOn = FALSE; 
        }
        PsysTarget = NULL_KEY;
        return 0;
    }
    if (!PsysOn || PsysTarget != target_key){
        PsysTarget = target_key;
        apply_ribbon_particles(LeashpointLink, target_key);
        PsysOn = TRUE;
    }
    return 0;
}

integer stop_leash_particles(){
    if (LeashpointLink == 0){ 
        LeashpointLink = find_leashpoint_link(); 
    }
    if (PsysOn){ 
        llLinkParticleSystem(LeashpointLink, []); 
        PsysOn = FALSE; 
    }
    PsysTarget = NULL_KEY;
    return 0;
}

integer turn_to_leasher(key leasher_key){
    if (leasher_key == NULL_KEY) return 0;
    list det = llGetObjectDetails(leasher_key,[OBJECT_POS]);
    if (llGetListLength(det) < 1) return 0;
    vector fwd = llVecNorm(llList2Vector(det,0) - llGetRootPosition());
    rotation rot = llRotBetween(<1,0,0>, fwd);
    llOwnerSay("@setrot:"+(string)rot+"=force");
    return 0;
}

integer clear_turn(){ 
    llOwnerSay("@setrot=clear"); 
    return 0; 
}

integer leash_follow_logic(){
    if (!Leashed) return 0;
    if (Leasher == NULL_KEY) return 0;

    vector leash_pt = leash_ring_world();
    if (Leasher != llGetOwner()){
        list det = llGetObjectDetails(Leasher,[OBJECT_POS]);
        if (llGetListLength(det) > 0) leash_pt = llList2Vector(det,0);
    }

    vector wearer_pos = llGetRootPosition();
    vector offset = wearer_pos - leash_pt;
    float  dist   = llVecMag(offset);

    if (ControlsOk){
        if (dist > (float)LeashLength){
            vector target_pos = leash_pt + llVecNorm(offset) * (float)LeashLength * MaxLenMargin;
            if (llVecMag(target_pos - LastTarget) > MoveHyst){
                llMoveToTarget(target_pos, 0.5);
                LastTarget = target_pos;
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
   Holder JSON handshake (avatars only)
   ============================================================= */
integer begin_worn_holder_handshake(key controller_key){
    close_holder_listen();
    HolderListenHandle = llListen(LEASH_HOLDER_CHAN,"",NULL_KEY,"");

    WornSession    = (integer)llFrand(2147483000.0);
    WornController = controller_key;
    WornWaiting    = TRUE;
    WornDeadline   = now() + HOLDER_REPLY_WAIT_SEC;
    WornProtocol   = 0;

    LastController = controller_key;   /* remember for auto-reclip */

    string json_req = llList2Json(JSON_OBJECT,[]);
    json_req = llJsonSetValue(json_req,["type"],"leash_req");
    json_req = llJsonSetValue(json_req,["wearer"],(string)llGetOwner());
    json_req = llJsonSetValue(json_req,["collar"],(string)llGetKey());
    json_req = llJsonSetValue(json_req,["controller"],(string)controller_key);
    json_req = llJsonSetValue(json_req,["session"],(string)WornSession);
    json_req = llJsonSetValue(json_req,["origin"],"leashpoint");
    json_req = llJsonSetValue(json_req,["holder_name"],"Leash Holder Origin Prim");

    llRegionSay(LEASH_HOLDER_CHAN, json_req);
    NextLeashMode = LEASH_MODE_NATIVE;
    return TRUE;
}

integer begin_oc_holder_handshake(key controller_key){
    close_holder_listen();
    HolderListenHandle = llListen(LEASH_HOLDER_CHAN,"",NULL_KEY,"");

    WornSession    = (integer)llFrand(2147483000.0);
    WornController = controller_key;
    WornWaiting    = TRUE;
    WornDeadline   = now() + HOLDER_REPLY_WAIT_SEC;
    WornProtocol   = 1;

    LastController = controller_key;

    string json_req = llList2Json(JSON_OBJECT,[]);
    json_req = llJsonSetValue(json_req,["type"],"oc_leash_req");
    json_req = llJsonSetValue(json_req,["wearer"],(string)llGetOwner());
    json_req = llJsonSetValue(json_req,["collar"],(string)llGetKey());
    json_req = llJsonSetValue(json_req,["controller"],(string)controller_key);
    json_req = llJsonSetValue(json_req,["session"],(string)WornSession);
    json_req = llJsonSetValue(json_req,["origin"],"leashpoint");
    json_req = llJsonSetValue(json_req,["holder_name"],"Leash Holder Origin Prim");

    llRegionSay(LEASH_HOLDER_CHAN, json_req);
    NextLeashMode = LEASH_MODE_OC;
    return TRUE;
}

/* =============================================================
   UI builders
   ============================================================= */
integer begin_dialog_ctx(key user, string body, list pairs){
    reset_listen();
    MenuUser = user;
    MenuPairs = pairs;

    list labels = pairs_to_labels(pairs);
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    ListenHandle = llListen(MenuChan,"",MenuUser,"");
    llDialog(MenuUser, body, labels, MenuChan);
    DialogExpires = now() + DIALOG_TIMEOUT;
    return TRUE;
}

list make_menu_pairs(integer acl){
    list pairs = [];
    if (acl == ACL_PUBLIC){
        pairs += ["Clip to…", CMD_CLIP, "Unclip", CMD_UNCLIP, "Give holder", CMD_GIVEH];
    } else if (acl == ACL_OWNED){
        pairs += ["Clip to…", CMD_CLIP];
    } else if (acl == ACL_TRUSTEE){
        pairs += ["Clip to…", CMD_CLIP, "Unclip", CMD_UNCLIP, "Set Length", CMD_SETLEN, "Turn", CMD_TURN, "Give holder", CMD_GIVEH];
    } else if (acl == ACL_UNOWNED){
        pairs += ["Clip to…", CMD_CLIP, "Unclip", CMD_UNCLIP];
    } else { /* primary owner */
        pairs += ["Clip to…", CMD_CLIP, "Unclip", CMD_UNCLIP, "Set Length", CMD_SETLEN, "Turn", CMD_TURN, "Give holder", CMD_GIVEH];
    }
    pairs += ["Back", CMD_BACK];
    return pairs;
}

integer show_main_menu(key user, integer acl){
    string menu_text = "Leash:\n";
    if (Leashed) menu_text += "Leashed to: " + llKey2Name(Leasher) + "\n";
    else menu_text += "Not leashed\n";
    menu_text += "Length: " + (string)LeashLength + " m";
    if (TurnTo) menu_text += "\nTurn: ON"; 
    else menu_text += "\nTurn: OFF";
    return begin_dialog_ctx(user, menu_text, make_menu_pairs(acl));
}

/* Set length picker */
integer do_set_len(integer meters){
    if (meters < 1) meters = 1;
    if (meters > 30) meters = 30;
    LeashLength = meters;

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
    integer i = 0; 
    integer list_length = llGetListLength(labels);
    while (i < list_length){ 
        string label = llList2String(labels, i); 
        pairs += [label, CMD_SETVAL]; 
        i = i + 1; 
    }
    pairs += ["Back", CMD_BACK];
    return begin_dialog_ctx(MenuUser,"Pick leash length (m)",pairs);
}

/* Root return */
integer ui_return_root(key to_user){
    string json_return = llList2Json(JSON_OBJECT,[]);
    json_return = llJsonSetValue(json_return, ["type"],    TYPE_PLUGIN_RETURN);
    json_return = llJsonSetValue(json_return, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, json_return, to_user);
    return 0;
}

/* Core actions */
integer do_leash(key target_key){
    if (target_key == NULL_KEY) return FALSE;
    Leasher = target_key; 
    Leashed = TRUE; 
    OffsimFlag = FALSE; 
    OffsimStartEpoch = 0;
    LeashRenderMode = NextLeashMode;
    draw_leash_particles(Leasher);
    return TRUE;
}

integer do_unclip(){
    Leashed = FALSE; 
    Leasher = NULL_KEY;
    LeashRenderMode = LEASH_MODE_NONE;
    NextLeashMode   = LEASH_MODE_NATIVE;
    llStopMoveToTarget(); 
    LastTarget = ZERO_VECTOR; 
    stop_leash_particles();
    OffsimFlag = FALSE; 
    OffsimStartEpoch = 0;
    WornWaiting = FALSE; 
    WornDeadline = 0; 
    WornSession = 0; 
    WornProtocol = 0;
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
    PageIdx = 0;
    ScanExpires = now() + SCAN_TIMEOUT;
    llSensor("",NULL_KEY,AGENT,SCAN_RADIUS,SCAN_ARC);
    return TRUE;
}

integer show_scan_page(){
    integer total = llGetListLength(ScanKeys);
    if (total <= 0){
        llRegionSayTo(MenuUser, 0, "No nearby avatars.");
        show_main_menu(MenuUser, AclLevel);
        return FALSE;
    }

    integer per   = MAX_PAGE_ITEMS;
    integer start = PageIdx * per;
    integer end   = start + per - 1;
    if (end >= total) end = total - 1;

    string header = "Select person (" + (string)(start+1) + "-" + (string)(end+1) + "/" + (string)total + "):\n";

    list pairs = [];
    if (PageIdx > 0) pairs += ["<<", "prev"];
    pairs += ["Back", CMD_BACK];
    if ((end + 1) < total) pairs += [">>", "next"];

    integer i = start; 
    integer line_no = 1;
    while (i <= end){
        key avatar_key = llList2Key(ScanKeys, i);
        string avatar_name = llKey2Name(avatar_key); 
        if (avatar_name == "") avatar_name = (string)avatar_key;
        header += (string)line_no + ". " + avatar_name + "\n";
        pairs += [(string)line_no, CMD_PICK + ":" + (string)i];
        i = i + 1; 
        line_no = line_no + 1;
    }

    return begin_dialog_ctx(MenuUser, header, pairs);
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        /* Hard unclip on any (re)start */
        do_unclip();

        LeashpointLink = find_leashpoint_link();

        /* reset UI + listeners */
        MenuUser = NULL_KEY;
        reset_listen();
        close_holder_listen();

        AclPending = FALSE;
        AclLevel = ACL_NOACCESS;

        PLUGIN_SN = (integer)(llFrand(1.0e9));
        notify_soft_reset();
        register_self();
        hb_init();                       /* enable heartbeat */
        llSetTimerEvent(FOLLOW_TICK);    /* tighten timer for follow physics */

        /* Controls (for move-to-target restraint) */
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
        
        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    on_rez(integer start_param){ 
        llResetScript(); 
    }
    
    changed(integer change){ 
        if (change & CHANGED_OWNER) llResetScript(); 
    }

    run_time_permissions(integer perm){
        if ((perm & PERMISSION_TAKE_CONTROLS) != 0) ControlsOk = TRUE;
        else ControlsOk = FALSE;
    }

    /* Kernel lifecycle / heartbeat */
    link_message(integer sender, integer num, string msg, key id){
        /* Kernel soft reset → hard unclip */
        if (num == K_PLUGIN_SOFT_RESET){
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_SOFT_RESET){
                integer do_clear = TRUE;
                if (json_has(msg, ["context"])){
                    string context = llJsonGetValue(msg, ["context"]);
                    if (!(context == "all" || context == "*" || context == PLUGIN_CONTEXT)) do_clear = FALSE;
                }
                if (do_clear){ 
                    do_unclip(); 
                }
            }
            return;
        }

        /* Heartbeat */
        if (num == K_PLUGIN_PING){
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_PING){
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT){
                    hb_on_ping_ok();
                    string json_pong = llList2Json(JSON_OBJECT,[]);
                    json_pong = llJsonSetValue(json_pong, ["type"],    TYPE_PLUGIN_PONG);
                    json_pong = llJsonSetValue(json_pong, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, json_pong, NULL_KEY);
                }
            }
            return;
        }

        /* Kernel: "register_now" for THIS script */
        if (num == K_PLUGIN_REG_QUERY){
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_REGISTER_NOW){
                if (json_has(msg, ["script"]) && llJsonGetValue(msg, ["script"]) == llGetScriptName()){
                    register_self();
                    hb_on_ping_ok();
                }
            }
            return;
        }

        /* UI: start → request ACL first */
        if (num == K_PLUGIN_START){
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_START){
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT){
                    MenuUser = id;
                    request_acl(id);
                }
            }
            return;
        }

        /* AUTH result */
        if (num == AUTH_RESULT_NUM){
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;
            key avatar_key = (key)llJsonGetValue(msg, ["avatar"]);
            if (avatar_key != MenuUser) return;
            if (!json_has(msg, ["level"])) return;

            AclPending = FALSE;
            AclLevel = (integer)llJsonGetValue(msg, ["level"]);

            if (!allow_open() || !in_allowed_levels(AclLevel)){
                llRegionSayTo(MenuUser, 0, "Access denied.");
                ui_return_root(MenuUser);
                MenuUser = NULL_KEY;
                reset_listen();
                return;
            }

            show_main_menu(MenuUser, AclLevel);
            return;
        }
    }

    /* Sensor results (avatar scan) */
    sensor(integer num){
        ScanKeys = [];
        integer i = 0;
        while (i < num){
            key detected_key = llDetectedKey(i);
            if (detected_key != llGetOwner()) ScanKeys += [detected_key];
            i = i + 1;
        }
        show_scan_page();
    }
    
    no_sensor(){
        llRegionSayTo(MenuUser,0,"No nearby avatars.");
        show_main_menu(MenuUser, AclLevel);
    }

    /* Listens: holder handshake & dialog */
    listen(integer chan, string name, key id, string text){
        /* Holder channel (worn holder only) */
        if (chan == LEASH_HOLDER_CHAN){
            if (!WornWaiting) return;
            if (!json_has(text,["type"])) return;

            string msg_type = llJsonGetValue(text,["type"]);
            if (msg_type == "leash_target"){
                integer session_ok = FALSE;
                if (json_has(text,["session"])){
                    integer session_id = (integer)llJsonGetValue(text,["session"]);
                    if (session_id == WornSession) session_ok = TRUE;
                }
                if (!session_ok) return;

                integer reply_ok = 0;
                if (json_has(text,["ok"])) reply_ok = (integer)llJsonGetValue(text,["ok"]);
                if (reply_ok == 1 && json_has(text,["holder"])){
                    key holder_prim = (key)llJsonGetValue(text,["holder"]);
                    if (holder_prim != NULL_KEY){
                        NextLeashMode = LEASH_MODE_NATIVE;
                        do_leash(holder_prim);
                        WornWaiting = FALSE; 
                        WornDeadline = 0; 
                        WornSession = 0; 
                        WornProtocol = 0;
                        close_holder_listen();
                        if (MenuUser != NULL_KEY) show_main_menu(MenuUser, AclLevel);
                    }
                    return;
                }

                WornWaiting = FALSE; 
                WornDeadline = 0; 
                WornSession = 0;
                close_holder_listen();
                if (WornController != NULL_KEY){
                    begin_oc_holder_handshake(WornController);
                }
                return;
            }

            if (msg_type == "oc_leash_target"){
                integer session_ok = FALSE;
                if (json_has(text,["session"])){
                    integer session_id = (integer)llJsonGetValue(text,["session"]);
                    if (session_id == WornSession) session_ok = TRUE;
                }
                if (!session_ok) return;

                integer reply_ok = 0;
                if (json_has(text,["ok"])) reply_ok = (integer)llJsonGetValue(text,["ok"]);

                key holder_prim = NULL_KEY;
                if (json_has(text,["holder"])) holder_prim = (key)llJsonGetValue(text,["holder"]);

                WornWaiting = FALSE; 
                WornDeadline = 0; 
                WornSession = 0; 
                WornProtocol = 0;
                close_holder_listen();

                if (reply_ok == 1 && holder_prim != NULL_KEY){
                    NextLeashMode = LEASH_MODE_OC;
                    do_leash(holder_prim);
                } else if (WornController != NULL_KEY){
                    NextLeashMode = LEASH_MODE_AVATAR;
                    do_leash(WornController);
                }

                if (MenuUser != NULL_KEY) show_main_menu(MenuUser, AclLevel);
                return;
            }
            return;
        }

        /* Dialog channel */
        if (chan != MenuChan) return;

        string cmd = cmd_from_label(text);
        if (cmd == ""){
            show_main_menu(MenuUser, AclLevel);
            return;
        }

        if (cmd == CMD_BACK){
            ui_return_root(MenuUser);   /* plugin root → main UI */
            MenuUser = NULL_KEY;
            reset_listen();
            return;
        }

        if (cmd == CMD_CLIP){ 
            start_avatar_scan(); 
            return; 
        }

        if (cmd == CMD_UNCLIP){ 
            do_unclip(); 
            show_main_menu(MenuUser, AclLevel); 
            return; 
        }

        if (cmd == CMD_SETLEN){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[AclLevel]) == -1){
                llRegionSayTo(MenuUser,0,"You do not have permission to set leash length.");
                show_main_menu(MenuUser, AclLevel); 
                return;
            }
            show_length_menu(); 
            return;
        }
        
        if (cmd == CMD_SETVAL){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[AclLevel]) == -1){
                llRegionSayTo(MenuUser,0,"You do not have permission to set leash length.");
                show_main_menu(MenuUser, AclLevel); 
                return;
            }
            integer meters = (integer)text; /* label carries value */
            do_set_len(meters);
            show_main_menu(MenuUser, AclLevel);
            return;
        }

        if (cmd == CMD_TURN){ 
            do_toggle_turn(); 
            show_main_menu(MenuUser, AclLevel); 
            return; 
        }

        if (cmd == CMD_GIVEH){
            if (llListFindList(ALLOWED_GIVEH_LEVELS,[AclLevel]) == -1){
                llRegionSayTo(MenuUser,0,"You do not have permission to use that.");
                show_main_menu(MenuUser, AclLevel); 
                return;
            }
            string item_name = "DS Collar leash holder";
            integer inv_type = llGetInventoryType(item_name);
            if (inv_type != INVENTORY_OBJECT){
                llRegionSayTo(MenuUser,0,"The 'Leash Holder' object is missing from the collar inventory.");
            } else {
                llGiveInventory(MenuUser, item_name);
                llRegionSayTo(MenuUser,0,"Leash holder sent. Wear or rez it to use as a leash target.");
            }
            show_main_menu(MenuUser, AclLevel); 
            return;
        }

        if (llSubStringIndex(cmd,":") != -1){
            /* pick:<absIndex> */
            integer colon_pos = llSubStringIndex(cmd,":");
            string cmd_head = llGetSubString(cmd,0,colon_pos-1);
            if (cmd_head == CMD_PICK){
                integer abs_idx = (integer)llGetSubString(cmd,colon_pos+1,-1);
                if (abs_idx >= 0 && abs_idx < llGetListLength(ScanKeys)){
                    key target_avatar = llList2Key(ScanKeys, abs_idx);
                    begin_worn_holder_handshake(target_avatar);
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
            integer max_page = 0; 
            if (total > 0) max_page = (total - 1) / MAX_PAGE_ITEMS;
            if (PageIdx < max_page) PageIdx = PageIdx + 1;
            show_scan_page(); 
            return;
        }

        show_main_menu(MenuUser, AclLevel);
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
                ScanKeys=[]; 
                PageIdx=0; 
            }
        }

        /* Holder handshake timeout → try OC fallback, then avatar */
        if (WornWaiting && now() >= WornDeadline){
            WornWaiting = FALSE;
            close_holder_listen();
            if (WornController != NULL_KEY){
                if (WornProtocol == 0){
                    begin_oc_holder_handshake(WornController);
                } else {
                    WornProtocol = 0;
                    NextLeashMode = LEASH_MODE_AVATAR;
                    do_leash(WornController);
                    if (MenuUser != NULL_KEY) show_main_menu(MenuUser, AclLevel);
                }
            }
        }

        /* Presence / auto-release + auto-reclip */
        if (Leashed){
            integer present = FALSE;

            if (LastController != NULL_KEY){
                integer agent_info = llGetAgentInfo(LastController);
                if (agent_info != 0) present = TRUE;
            } else if (Leasher != NULL_KEY){
                list obj_details = llGetObjectDetails(Leasher,[OBJECT_POS]);
                if (llGetListLength(obj_details) >= 1 && llList2Vector(obj_details,0) != ZERO_VECTOR) present = TRUE;
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
                    integer agent_info = llGetAgentInfo(LastController);
                    if (agent_info != 0){ 
                        begin_worn_holder_handshake(LastController); 
                    }
                }
            }
        }
    }
}
