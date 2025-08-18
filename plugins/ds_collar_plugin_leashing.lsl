/* =============================================================
   PLUGIN: ds_collar_plugin_leash.lsl  (kernel-HB + lean UI)
   PURPOSE: Leashing & Movement Restraint with particles, unified "Clip to…"

   CHANGES vs repo (authoritative base):
   - Unified UI: "Clip to…" → Person | Object (replaces separate Give/Anchor entries)
   - Removed legacy LG/LM shims to reduce size & heap
   - Dialogs show only effective buttons (no "~" fillers)
   - Scan pages: Prev / Back / Next only when applicable
   - Kept ACL rules from repo (SetLen only 3/5; Give holder 1/3/5)
   - Neutral command mapping preserved (labels are cosmetic)
   - Physics/particles & holder JSON handshakes preserved
   ============================================================= */

integer DEBUG = FALSE;

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

/* ---------- Protocol strings ---------- */
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

/* specific actions (unchanged from repo intent) */
list   ALLOWED_GIVEH_LEVELS   = [ACL_PUBLIC, ACL_TRUSTEE, ACL_PRIMARY_OWNER];
list   ALLOWED_SETLEN_LEVELS  = [ACL_TRUSTEE, ACL_PRIMARY_OWNER];

/* ---------- UI ---------- */
integer DIALOG_TIMEOUT    = 180;
integer SCAN_TIMEOUT      = 30;
float   FOLLOW_TICK       = 0.5;

/* ---------- Commands (neutral) ---------- */
string CMD_BACK   = "back";
string CMD_CLIP   = "clip";      /* opens Person/Object picker */
string CMD_TGT_AV = "tgt_av";
string CMD_TGT_OB = "tgt_ob";
string CMD_PICK   = "pick";      /* pick:<absIndex> from scan page */

string CMD_UNCLIP = "unclip";
string CMD_SETLEN = "setlen";
string CMD_SETVAL = "setval";
string CMD_TURN   = "turn";
string CMD_GIVEH  = "giveholder";

/* ---------- Scan ---------- */
float   SCAN_RADIUS = 5.0;
float   SCAN_ARC    = TWO_PI;
integer MAX_PAGE_ITEMS = 9;
integer g_page_idx = 0;

/* ---------- Session/UI state ---------- */
key     g_user = NULL_KEY;
integer g_listen = 0;
integer g_menu_chan = 0;
integer g_acl_pending = FALSE;
integer g_last_acl_level = ACL_NOACCESS;
integer g_dialog_expires = 0;

/* compact mapping for current dialog: [label,cmd,label,cmd,...] */
list    g_pairs = [];

/* ---------- Scan state ---------- */
string  g_scan_mode = "";      /* "", "av", "ob" */
list    g_scan_keys = [];
integer g_scan_expires = 0;

/* ---------- Leash state ---------- */
integer g_leashed      = FALSE;
key     g_leasher      = NULL_KEY;   /* avatar OR object/prim key */
integer g_leash_length = 2;
integer g_turn_to      = FALSE;
integer g_controls_ok  = FALSE;

/* ---------- Particles ---------- */
/* do NOT change this type/cast; compiler accepts as-is */
string  g_chain_texture   = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";
integer g_psys_on         = FALSE;
key     g_psys_target     = NULL_KEY;
vector  g_last_target     = ZERO_VECTOR;
float   g_last_dist       = -1.0;
float   g_move_hyst       = 0.20;
float   g_max_len_margin  = 0.98;

/* ---------- Holder handshake (JSON) ---------- */
integer LEASH_HOLDER_CHAN     = -192837465;
integer HOLDER_REPLY_WAIT_SEC = 2;

/* Anchor (rezzed object) */
integer g_holderListen    = 0;
integer g_anchor_waiting  = FALSE;
integer g_anchor_session  = 0;
key     g_anchor_obj      = NULL_KEY;
integer g_anchor_deadline = 0;

/* Worn holder (controller’s attachment) */
integer g_worn_waiting    = FALSE;
integer g_worn_session    = 0;
key     g_worn_controller = NULL_KEY;
integer g_worn_deadline   = 0;

/* ========================== Helpers ========================== */
integer json_has(string j, list path){ if (llJsonGetValue(j,path) != JSON_INVALID) return TRUE; return FALSE; }
integer logd(string s){ if (DEBUG) llOwnerSay("[LEASH] " + s); return 0; }
integer now(){ return llGetUnixTime(); }

integer reset_listen(){
    if (g_listen) llListenRemove(g_listen);
    g_listen = 0; g_menu_chan = 0; g_pairs = [];
    return 0;
}
integer close_holder_listen(){
    if (g_holderListen){ llListenRemove(g_holderListen); g_holderListen = 0; }
    return TRUE;
}

/* dialog helpers */
list pairs_to_labels(list pairs){
    list labels = [];
    integer i = 0; integer L = llGetListLength(pairs);
    while (i < L){
        labels += llList2String(pairs, i);
        i = i + 2;
    }
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
integer begin_dialog_ctx(key user, string body, list pairs){
    reset_listen();
    g_user = user;
    g_pairs = pairs;
    list labels = pairs_to_labels(pairs);
    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen = llListen(g_menu_chan,"",g_user,"");
    llDialog(g_user, body, labels, g_menu_chan);
    g_dialog_expires = now() + DIALOG_TIMEOUT;
    return TRUE;
}

/* ================= Registration & Heartbeat ================= */
integer register_self(){
    string j = llList2Json(JSON_OBJECT,[]);
    j = llJsonSetValue(j,["type"],CONS_TYPE_REGISTER);
    j = llJsonSetValue(j,["sn"],(string)PLUGIN_SN);
    j = llJsonSetValue(j,["label"],PLUGIN_LABEL);
    j = llJsonSetValue(j,["min_acl"],(string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j,["context"],PLUGIN_CONTEXT);
    j = llJsonSetValue(j,["script"],llGetScriptName());
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

/* ================= Holder JSON ================= */
integer begin_anchor_handshake(key obj){
    close_holder_listen();
    g_holderListen = llListen(LEASH_HOLDER_CHAN,"",NULL_KEY,"");

    g_anchor_session  = (integer)llFrand(2147483000.0);
    g_anchor_obj      = obj;
    g_anchor_waiting  = TRUE;
    g_anchor_deadline = now() + HOLDER_REPLY_WAIT_SEC;

    string req = llList2Json(JSON_OBJECT,[]);
    req = llJsonSetValue(req,["type"],"leash_req");
    req = llJsonSetValue(req,["wearer"],(string)llGetOwner());
    req = llJsonSetValue(req,["collar"],(string)llGetKey());
    req = llJsonSetValue(req,["session"],(string)g_anchor_session);

    llRegionSayTo(obj,LEASH_HOLDER_CHAN,req);
    return TRUE;
}
integer begin_worn_holder_handshake(key controller){
    close_holder_listen();
    g_holderListen = llListen(LEASH_HOLDER_CHAN,"",NULL_KEY,"");

    g_worn_session    = (integer)llFrand(2147483000.0);
    g_worn_controller = controller;
    g_worn_waiting    = TRUE;
    g_worn_deadline   = now() + HOLDER_REPLY_WAIT_SEC;

    string req = llList2Json(JSON_OBJECT,[]);
    req = llJsonSetValue(req,["type"],"leash_req");
    req = llJsonSetValue(req,["wearer"],(string)llGetOwner());
    req = llJsonSetValue(req,["collar"],(string)llGetKey());
    req = llJsonSetValue(req,["controller"],(string)controller);
    req = llJsonSetValue(req,["session"],(string)g_worn_session);

    llRegionSay(LEASH_HOLDER_CHAN,req);
    return TRUE;
}

/* ================= UI Builders ================= */
list make_menu_pairs(integer acl){
    list pairs = [];

    /* Unified entry point */
    /* Replace old "Leash / Offer Leash / Anchor" with one "Clip to…" */
    if (acl == ACL_PUBLIC){
        pairs += ["Clip to…", CMD_CLIP, "Unclip", CMD_UNCLIP, "Give holder", CMD_GIVEH];
    } else if (acl == ACL_OWNED){
        /* wearer while owned: previously only "Offer Leash"; unified to "Clip to…" */
        pairs += ["Clip to…", CMD_CLIP];
    } else if (acl == ACL_TRUSTEE){
        pairs += ["Clip to…", CMD_CLIP, "Unclip", CMD_UNCLIP, "Set Length", CMD_SETLEN, "Turn", CMD_TURN, "Give holder", CMD_GIVEH];
    } else if (acl == ACL_UNOWNED){
        pairs += ["Clip to…", CMD_CLIP, "Unclip", CMD_UNCLIP];
    } else {
        /* primary owner/admin */
        pairs += ["Clip to…", CMD_CLIP, "Unclip", CMD_UNCLIP, "Set Length", CMD_SETLEN, "Turn", CMD_TURN, "Give holder", CMD_GIVEH];
    }

    pairs += ["Back", CMD_BACK];
    return pairs;
}

integer show_main_menu(key user, integer acl){
    string menu = "Leash:\n";
    if (g_leashed) menu += "Leashed to: " + llKey2Name(g_leasher) + "\n";
    else menu += "Not leashed\n";
    menu += "Length: " + (string)g_leash_length + " m";
    if (g_turn_to) menu += "\nTurn: ON"; else menu += "\nTurn: OFF";
    return begin_dialog_ctx(user, menu, make_menu_pairs(acl));
}

integer show_target_menu(){
    list pairs = [];
    /* Person always; Object hidden for ACL_OWNED (mirrors repo where owned wearer didn’t anchor) */
    pairs += ["Person", CMD_TGT_AV];
    if (g_last_acl_level != ACL_OWNED) pairs += ["Object", CMD_TGT_OB];
    pairs += ["Back", CMD_BACK];
    return begin_dialog_ctx(g_user, "Clip to…", pairs);
}

/* Set length picker (unchanged choices, no filler) */
integer do_set_len(integer m){ if (m<1) m=1; if (m>30) m=30; g_leash_length=m; return TRUE; }
integer show_length_menu(){
    list labels = ["1","2","3","5","8","10","12","15","20"];
    list pairs = [];
    integer i = 0; integer L = llGetListLength(labels);
    while (i < L){ string lab = llList2String(labels,i); pairs += [lab, CMD_SETVAL]; i = i + 1; }
    pairs += ["Back", CMD_BACK];
    return begin_dialog_ctx(g_user,"Pick leash length (m)",pairs);
}

/* Root return */
integer do_back(){
    string r = llList2Json(JSON_OBJECT,[]);
    r = llJsonSetValue(r,["type"],CONS_TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r,["context"],ROOT_CONTEXT);
    llMessageLinked(LINK_SET,K_PLUGIN_RETURN_NUM,r,g_user);
    g_user = NULL_KEY;
    reset_listen();
    return TRUE;
}

/* Core actions */
integer do_leash(key who){
    if (who == NULL_KEY) return FALSE;
    g_leasher = who; g_leashed = TRUE; draw_leash_particles(g_leasher);
    return TRUE;
}
integer do_unclip(){
    g_leashed = FALSE; g_leasher = NULL_KEY;
    llStopMoveToTarget(); g_last_target = ZERO_VECTOR; stop_leash_particles();
    return TRUE;
}
integer do_toggle_turn(){ if (g_turn_to) g_turn_to=FALSE; else g_turn_to=TRUE; if (!g_turn_to) clear_turn(); return TRUE; }

/* ================= Scanning ================= */
integer start_scan(string mode){
    g_scan_mode = mode; g_scan_keys = []; g_page_idx = 0;
    g_scan_expires = now() + SCAN_TIMEOUT;
    if (mode == "av"){ llSensor("",NULL_KEY,AGENT,SCAN_RADIUS,SCAN_ARC); }
    else {
        integer mask = ACTIVE | PASSIVE | SCRIPTED;
        llSensor("",NULL_KEY,mask,SCAN_RADIUS,SCAN_ARC);
    }
    return TRUE;
}

integer show_scan_page(){
    integer total = llGetListLength(g_scan_keys);
    if (total <= 0){
        if (g_scan_mode == "av") llRegionSayTo(g_user, 0, "No nearby avatars.");
        else llRegionSayTo(g_user, 0, "No nearby objects.");
        show_main_menu(g_user, g_last_acl_level);
        return FALSE;
    }

    integer per   = MAX_PAGE_ITEMS;
    integer start = g_page_idx * per;
    integer end   = start + per - 1;
    if (end >= total) end = total - 1;

    string head = "Select ";
    if (g_scan_mode == "av") head += "person"; else head += "object";
    head += " (" + (string)(start+1) + "-" + (string)(end+1) + "/" + (string)total + "):\n";

    list pairs = [];
    if (g_page_idx > 0) pairs += ["<<", "prev"];
    pairs += ["Back", CMD_BACK];
    if ((end + 1) < total) pairs += [">>", "next"];

    integer i = start; integer lineNo = 1;
    while (i <= end){
        key k = llList2Key(g_scan_keys, i);
        string nm = llKey2Name(k); if (nm == "") nm = (string)k;
        head += (string)lineNo + ". " + nm + "\n";
        pairs += [(string)lineNo, CMD_PICK + ":" + (string)i];
        i = i + 1; lineNo = lineNo + 1;
    }

    return begin_dialog_ctx(g_user, head, pairs);
}

/* ================================ Events =============================== */
default {
    state_entry(){
        PLUGIN_SN = (integer)(llFrand(1.0e9));

        /* clear visuals on start/reset */
        do_unclip();

        g_user = NULL_KEY;
        reset_listen();
        close_holder_listen();

        g_acl_pending = FALSE;
        g_last_acl_level = ACL_NOACCESS;

        g_anchor_waiting = FALSE; g_anchor_obj = NULL_KEY; g_anchor_session = 0; g_anchor_deadline = 0;
        g_worn_waiting   = FALSE; g_worn_controller = NULL_KEY; g_worn_session = 0; g_worn_deadline   = 0;

        string j = llList2Json(JSON_OBJECT,[]);
        j = llJsonSetValue(j,["type"],CONS_TYPE_PLUGIN_SOFT_RESET);
        j = llJsonSetValue(j,["context"],PLUGIN_CONTEXT);
        llMessageLinked(LINK_SET,K_PLUGIN_SOFT_RESET,j,NULL_KEY);

        register_self();

        llRequestPermissions(llGetOwner(),PERMISSION_TAKE_CONTROLS);
        llSetTimerEvent(FOLLOW_TICK);
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    run_time_permissions(integer p){ if (p & PERMISSION_TAKE_CONTROLS) g_controls_ok=TRUE; else g_controls_ok=FALSE; }

    link_message(integer sender, integer num, string msg, key id){
        /* ACL result */
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
                string r = llList2Json(JSON_OBJECT,[]);
                r = llJsonSetValue(r,["type"],CONS_TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r,["context"],ROOT_CONTEXT);
                llMessageLinked(LINK_SET,K_PLUGIN_RETURN_NUM,r,g_user);
                g_user = NULL_KEY; reset_listen();
            }
            return;
        }

        /* re-register */
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

        /* heartbeat */
        if (num == K_PLUGIN_PING){
            if (json_has(msg,["type"])){
                if (llJsonGetValue(msg,["type"]) == CONS_TYPE_PLUGIN_PING){
                    if (json_has(msg,["context"])){
                        string c = llJsonGetValue(msg,["context"]);
                        if (c != PLUGIN_CONTEXT) return;
                    }
                    string r = llList2Json(JSON_OBJECT,[]);
                    r = llJsonSetValue(r,["type"],CONS_TYPE_PLUGIN_PONG);
                    r = llJsonSetValue(r,["context"],PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET,K_PLUGIN_PONG,r,NULL_KEY);
                }
            }
            return;
        }

        /* secure open */
        if (num == K_PLUGIN_START){
            if (json_has(msg,["type"])){
                if (llJsonGetValue(msg,["type"]) == CONS_TYPE_PLUGIN_START){
                    if (json_has(msg,["context"])){
                        if (llJsonGetValue(msg,["context"]) == PLUGIN_CONTEXT){
                            g_user = id;
                            string j2 = llList2Json(JSON_OBJECT,[]);
                            j2 = llJsonSetValue(j2,["type"],CONS_MSG_ACL_QUERY);
                            j2 = llJsonSetValue(j2,["avatar"],(string)g_user);
                            llMessageLinked(LINK_SET,AUTH_QUERY_NUM,j2,NULL_KEY);
                            g_acl_pending = TRUE;
                        }
                    }
                }
            }
            return;
        }
    }

    /* SCAN */
    sensor(integer num){
        if (g_scan_mode == "") return;
        g_scan_keys = [];
        integer i = 0;
        while (i < num){
            key k = llDetectedKey(i);
            integer include = TRUE;
            if (g_scan_mode == "av"){
                if (k == llGetOwner()) include = FALSE;
            }
            if (include) g_scan_keys += [k];
            i = i + 1;
        }
        show_scan_page();
    }
    no_sensor(){
        if (g_scan_mode == "av") llRegionSayTo(g_user,0,"No nearby avatars.");
        else if (g_scan_mode == "ob") llRegionSayTo(g_user,0,"No nearby objects.");
        show_main_menu(g_user,g_last_acl_level);
    }

    /* Holder JSON replies (both flows) */
    listen(integer chan, string nm, key id, string text){
        if (chan == LEASH_HOLDER_CHAN){
            /* Anchor (rez object) */
            if (g_anchor_waiting){
                if (!json_has(text,["type"])) return;
                if (llJsonGetValue(text,["type"]) != "leash_target") return;

                integer okSess = FALSE;
                if (json_has(text,["session"])){
                    integer s = (integer)llJsonGetValue(text,["session"]);
                    if (s == g_anchor_session) okSess = TRUE;
                }
                if (!okSess) return;

                integer ok = 0;
                if (json_has(text,["ok"])) ok = (integer)llJsonGetValue(text,["ok"]);
                if (ok == 1 && json_has(text,["holder"])){
                    key prim = (key)llJsonGetValue(text,["holder"]);
                    if (prim != NULL_KEY){ g_leasher = prim; g_leashed = TRUE; draw_leash_particles(g_leasher); }
                }
                g_anchor_waiting = FALSE; g_anchor_deadline=0; g_anchor_session=0; g_anchor_obj=NULL_KEY;
                close_holder_listen();
                if (g_user) show_main_menu(g_user,g_last_acl_level);
                return;
            }

            /* Worn holder (controller) */
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
                    if (prim2 != NULL_KEY){ g_leasher = prim2; g_leashed = TRUE; draw_leash_particles(g_leasher); }
                }
                g_worn_waiting = FALSE; g_worn_deadline=0; g_worn_session=0; g_worn_controller=NULL_KEY;
                close_holder_listen();
                if (g_user) show_main_menu(g_user,g_last_acl_level);
                return;
            }
        }

        /* ----- Dialog ----- */
        if (chan != g_menu_chan) return;

        string cmd = cmd_from_label(text);
        if (cmd == ""){
            show_main_menu(g_user,g_last_acl_level);
            return;
        }

        if (cmd == CMD_BACK){ do_back(); return; }

        if (cmd == CMD_CLIP){ show_target_menu(); return; }
        if (cmd == CMD_TGT_AV){ start_scan("av"); return; }
        if (cmd == CMD_TGT_OB){ start_scan("ob"); return; }

        if (cmd == CMD_UNCLIP){ do_unclip(); show_main_menu(g_user,g_last_acl_level); return; }

        if (cmd == CMD_SETLEN){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[g_last_acl_level]) == -1){
                llRegionSayTo(g_user,0,"You do not have permission to set leash length.");
                show_main_menu(g_user,g_last_acl_level); return;
            }
            show_length_menu(); return;
        }
        if (cmd == CMD_SETVAL){
            if (llListFindList(ALLOWED_SETLEN_LEVELS,[g_last_acl_level]) == -1){
                llRegionSayTo(g_user,0,"You do not have permission to set leash length.");
                show_main_menu(g_user,g_last_acl_level); return;
            }
            integer meters = (integer)text; /* numeric label carries the value */
            do_set_len(meters);
            show_main_menu(g_user,g_last_acl_level);
            return;
        }

        if (cmd == CMD_TURN){ do_toggle_turn(); show_main_menu(g_user,g_last_acl_level); return; }

        if (cmd == CMD_GIVEH){
            if (llListFindList(ALLOWED_GIVEH_LEVELS,[g_last_acl_level]) == -1){
                llRegionSayTo(g_user,0,"You do not have permission to use that.");
                show_main_menu(g_user,g_last_acl_level);
                return;
            }
            /* inventory presence check + give */
            integer t = llGetInventoryType("DS Collar leash holder");
            if (t != INVENTORY_OBJECT){
                llRegionSayTo(g_user,0,"The ‘Leash Holder’ object is missing from the collar inventory.");
            } else {
                llGiveInventory(g_user,"DS Collar leash holder");
                llRegionSayTo(g_user,0,"Leash holder sent. Wear or rez it to use as a leash target.");
            }
            show_main_menu(g_user,g_last_acl_level);
            return;
        }

        if (cmd == "prev"){
            if (g_page_idx > 0) g_page_idx = g_page_idx - 1;
            show_scan_page(); return;
        }
        if (cmd == "next"){
            integer total = llGetListLength(g_scan_keys);
            integer maxPage = 0; if (total > 0) maxPage = (total - 1) / MAX_PAGE_ITEMS;
            if (g_page_idx < maxPage) g_page_idx = g_page_idx + 1;
            show_scan_page(); return;
        }

        /* pick:<absIndex> */
        integer p = llSubStringIndex(cmd,":");
        if (p != -1){
            string head = llGetSubString(cmd,0,p-1);
            if (head == CMD_PICK){
                integer abs = (integer)llGetSubString(cmd,p+1,-1);
                if (abs >= 0){
                    if (abs < llGetListLength(g_scan_keys)){
                        key target = llList2Key(g_scan_keys,abs);
                        if (g_scan_mode == "av"){
                            /* worn holder prim preferred; fallback to avatar center */
                            begin_worn_holder_handshake(target);
                        } else {
                            /* anchor to object’s leash prim preferred; fallback to object center */
                            begin_anchor_handshake(target);
                        }
                        return;
                    }
                }
            }
        }

        /* default → redraw */
        show_main_menu(g_user,g_last_acl_level);
    }

    timer(){
        /* dialog timeout */
        if (g_dialog_expires != 0){
            if (now() >= g_dialog_expires){ reset_listen(); g_dialog_expires = 0; }
        }

        /* follow */
        leash_follow_logic();

        /* scan timeout */
        if (g_scan_mode != ""){
            if (now() >= g_scan_expires){ g_scan_mode=""; g_scan_keys=[]; g_page_idx=0; }
        }

        /* JSON Anchor fallback to object center */
        if (g_anchor_waiting){
            if (now() >= g_anchor_deadline){
                if (g_anchor_obj != NULL_KEY){ do_leash(g_anchor_obj); }
                g_anchor_waiting = FALSE; g_anchor_deadline=0; g_anchor_session=0; g_anchor_obj=NULL_KEY;
                close_holder_listen();
                if (g_user) show_main_menu(g_user,g_last_acl_level);
            }
        }

        /* JSON Worn fallback to avatar center */
        if (g_worn_waiting){
            if (now() >= g_worn_deadline){
                if (g_worn_controller != NULL_KEY){ do_leash(g_worn_controller); }
                g_worn_waiting = FALSE; g_worn_deadline=0; g_worn_session=0; g_worn_controller=NULL_KEY;
                close_holder_listen();
                if (g_user) show_main_menu(g_user,g_last_acl_level);
            }
        }
    }
}
