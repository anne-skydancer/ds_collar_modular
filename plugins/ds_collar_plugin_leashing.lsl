/* =============================================================
   PLUGIN: ds_collar_plugin_leash.lsl  (patched for kernel HB)
   PURPOSE: Leashing & Movement Restraint with particles, give/offer, anchor

   KEY FIXES:
     - Include "script": llGetScriptName() in REGISTER
     - Reply to K_PLUGIN_PING with K_PLUGIN_PONG
     - Re-register on K_PLUGIN_REG_QUERY "register_now"

   Other behavior unchanged.
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
integer SOS_MSG_NUM            = 999; //SOS plugin link channel

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
string  PLUGIN_CONTEXT   = "core_leash";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Leashing";
integer PLUGIN_SN        = 0;
integer PLUGIN_MIN_ACL   = 1;

/* ---------- ACL levels (authoritative) ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* ---------- Allowed ACL levels for this plugin ---------- */
list ALLOWED_ACL_LEVELS = [
    ACL_PUBLIC,
    ACL_OWNED,
    ACL_TRUSTEE,
    ACL_UNOWNED,
    ACL_PRIMARY_OWNER
];

integer in_allowed_levels(integer lvl) {
    if (~llListFindList(ALLOWED_ACL_LEVELS, [lvl])) return TRUE;
    return FALSE;
}

/* ---------- UI constants ---------- */
string  BTN_BACK          = "Back";
string  BTN_FILL          = "~";
integer DIALOG_TIMEOUT    = 180;   // seconds
integer SCAN_TIMEOUT      = 30;    // seconds
float   FOLLOW_TICK       = 0.5;   // seconds

/* ---------- Command keys (context) ---------- */
string CMD_FILL      = "fill";
string CMD_BACK      = "back";
string CMD_LEASH     = "leash";
string CMD_UNCLIP    = "unclip";
string CMD_SETLEN    = "setlen";
string CMD_SETVAL    = "setval";      // setlen:<value>
string CMD_TURN      = "turn";
string CMD_GIVE      = "give";        // used for Offer Leash and Give Leash
string CMD_ANCHOR    = "anchor";
string CMD_PICK_AV   = "pick_av";     // pick avatar index (absolute)
string CMD_PICK_OBJ  = "pick_obj";    // pick object index (absolute)
string CMD_OK        = "ok";
string CMD_PREV      = "prev";
string CMD_NEXT      = "next";
key g_psys_target = NULL_KEY; // current particle target

/* ---------- Pagination ---------- */
integer MAX_PAGE_ITEMS = 9;   // 3 nav + 9 result buttons = 12 total
integer g_page_idx     = 0;   // current page for scan pick

/* ---------- Session/UI state ---------- */
key     g_user            = NULL_KEY;
integer g_listen          = 0;
integer g_menu_chan       = 0;
integer g_acl_pending     = FALSE;
integer g_last_acl_level  = ACL_NOACCESS;
list    g_btn_labels      = [];
list    g_btn_cmds        = [];
integer g_dialog_expires  = 0;

/* ---------- Scan state ---------- */
string  g_scan_mode       = "";    // "", "give", "anchor"
list    g_scan_keys       = [];    // keys of scan results (avatars/objects)
list    g_scan_labels     = [];    // display names for results
integer g_scan_expires    = 0;

/* ---------- Leash state ---------- */
integer g_leashed         = FALSE;
key     g_leasher         = NULL_KEY;   // avatar OR object key
integer g_leash_length    = 2;
integer g_turn_to         = FALSE;
integer g_controls_ok     = FALSE;

/* ---------- Particle constants ---------- */
string  g_chain_texture   = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";

/* Performance flags/caches */
integer g_psys_on          = FALSE;
vector  g_last_target      = ZERO_VECTOR;
float   g_last_dist        = -1.0;
float   g_move_hysteresis  = 0.20;
float   g_max_len_margin   = 0.98;
float   g_fast_tick        = 0.25;
float   g_slow_tick        = 1.00;
integer g_menu_open        = FALSE;
string  g_last_menu_text   = "";

/* ========================== Helpers ========================== */
integer json_has(string j, list path) { return (llJsonGetValue(j, path) != JSON_INVALID); }
integer logd(string s) { if (DEBUG) llOwnerSay("[LEASH] " + s); return 0; }

integer reset_listen() {
    if (g_listen) llListenRemove(g_listen);
    g_listen = 0;
    g_menu_chan = 0;
    g_btn_labels = [];
    g_btn_cmds = [];
    return 0;
}

integer im_to(key who, string msg) { if (who) llInstantMessage(who, msg); return 0; }
string wearer_name() { return llKey2Name(llGetOwner()); }
string name_of(key k) { return llKey2Name(k); }

/* ================= Registration & Heartbeat ================= */
integer register_self() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
    j = llJsonSetValue(j, ["script"],   llGetScriptName());   /* IMPORTANT */
    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered: ctx=" + PLUGIN_CONTEXT + " script=" + llGetScriptName() + " sn=" + (string)PLUGIN_SN);
    return 0;
}

/* =================== Particles & Movement =================== */
vector leash_anchor_point() {
    integer nprims = llGetNumberOfPrims();
    integer i = 2;
    while (i <= nprims) {
        string nm = llGetLinkName(i);
        string desc = llList2String(llGetLinkPrimitiveParams(i, [PRIM_DESC]), 0);
        if (llToLower(nm) == "leashring" || llToLower(desc) == "leash:ring") {
            vector child_local = llList2Vector(llGetLinkPrimitiveParams(i, [PRIM_POS_LOCAL]), 0);
            return llGetRootPosition() + (child_local * llGetRootRotation());
        }
        i = i + 1;
    }
    return llGetRootPosition();
}

integer draw_leash_particles(key to) {
    if (to == NULL_KEY) {
        if (g_psys_on) {
            llParticleSystem([]);
            g_psys_on = FALSE;
        }
        g_psys_target = NULL_KEY;
        return 0;
    }
    if (!g_psys_on || g_psys_target != to) {
        g_psys_target = to;
        llParticleSystem([
            PSYS_SRC_PATTERN, PSYS_SRC_PATTERN_DROP,
            PSYS_SRC_TEXTURE, g_chain_texture,
            PSYS_SRC_BURST_RATE, 0.00,
            PSYS_SRC_BURST_PART_COUNT, 1,
            PSYS_PART_START_ALPHA, 1.0,
            PSYS_PART_END_ALPHA, 1.0,
            PSYS_PART_MAX_AGE, 2.6,
            PSYS_PART_START_SCALE, <0.07, 0.07, 0>,
            PSYS_PART_END_SCALE, <0.07, 0.07, 0>,
            PSYS_PART_START_COLOR, <1.0, 1.0, 1.0>,
            PSYS_PART_END_COLOR, <1.0, 1.0, 1.0>,
            PSYS_SRC_ACCEL, <0,0,-1.25>,
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

integer stop_leash_particles() {
    if (g_psys_on) {
        llParticleSystem([]);
        g_psys_on = FALSE;
    }
    g_psys_target = NULL_KEY;
    return 0;
}

integer turn_to_leasher(key leasher) {
    if (leasher == NULL_KEY) return 0;
    list det = llGetObjectDetails(leasher, [OBJECT_POS]);
    if (llGetListLength(det) < 1) return 0;
    vector fwd = llVecNorm(llList2Vector(det, 0) - llGetRootPosition());
    rotation rot = llRotBetween(<1,0,0>, fwd);
    llOwnerSay("@setrot:" + (string)rot + "=force");
    return 0;
}

integer clear_turn() { llOwnerSay("@setrot=clear"); return 0; }

integer leash_follow_logic() {
    if (!g_leashed) return 0;
    if (g_leasher == NULL_KEY) return 0;
    vector leash_point = leash_anchor_point();
    if (g_leasher != llGetOwner()) {
        list det = llGetObjectDetails(g_leasher, [OBJECT_POS]);
        if (llGetListLength(det) > 0) leash_point = llList2Vector(det, 0);
    }
    vector wearer_pos = llGetRootPosition();
    vector offset = wearer_pos - leash_point;
    float dist = llVecMag(offset);
    if (g_controls_ok) {
        if (dist > (float)g_leash_length) {
            vector tgt = leash_point + llVecNorm(offset) * (float)g_leash_length * g_max_len_margin;
            if (llVecMag(tgt - g_last_target) > g_move_hysteresis) {
                llMoveToTarget(tgt, 0.5);
                g_last_target = tgt;
            }
            if (g_turn_to) turn_to_leasher(g_leasher);
        } else {
            if (g_last_dist >= 0.0 && g_last_dist > (float)g_leash_length) {
                llStopMoveToTarget();
                g_last_target = ZERO_VECTOR;
            }
        }
    }
    g_last_dist = dist;
    draw_leash_particles(g_leasher);
    return 0;
}

/* ===================== Menu Builders (context) ===================== */
list make_menu_pairs(integer acl) {
    list pairs = [ BTN_FILL, CMD_FILL, BTN_BACK, CMD_BACK, BTN_FILL, CMD_FILL ];
    if (acl == 1) {
        pairs += ["Leash", CMD_LEASH, "Unclip", CMD_UNCLIP, "Anchor", CMD_ANCHOR];
    } else if (acl == 2) {
        pairs += ["Offer Leash", CMD_GIVE, "Set Length", CMD_SETLEN];
    } else if (acl == 3) {
        pairs += ["Leash", CMD_LEASH, "Unclip", CMD_UNCLIP, "Set Length", CMD_SETLEN,
                  "Turn", CMD_TURN, "Give Leash", CMD_GIVE, "Anchor", CMD_ANCHOR];
    } else if (acl == 4) {
        pairs += ["Offer Leash", CMD_GIVE, "Anchor", CMD_ANCHOR, "Unclip", CMD_UNCLIP];
    } else {
        pairs += ["Leash", CMD_LEASH, "Unclip", CMD_UNCLIP, "Set Length", CMD_SETLEN,
                  "Turn", CMD_TURN, "Give Leash", CMD_GIVE, "Anchor", CMD_ANCHOR];
    }
    return pairs;
}

integer begin_dialog_ctx(key user, string body, list pairs) {
    reset_listen();
    g_user = user;
    g_btn_labels = [];
    g_btn_cmds = [];
    integer i = 0;
    while (i < llGetListLength(pairs)) {
        g_btn_labels += llList2String(pairs, i);
        g_btn_cmds   += llList2String(pairs, i+1);
        i = i + 2;
    }
    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen    = llListen(g_menu_chan, "", g_user, "");
    llDialog(g_user, body, g_btn_labels, g_menu_chan);
    g_dialog_expires = llGetUnixTime() + DIALOG_TIMEOUT;
    return 0;
}

integer show_main_menu(key user, integer acl) {
    string menu_text = "Leash state:\n";
    if (g_leashed) menu_text += "Leashed to: " + name_of(g_leasher) + "\n";
    else menu_text += "Not leashed\n";
    menu_text += "Length: " + (string)g_leash_length + " m";
    if (g_turn_to) menu_text += "\nTurn: ON";
    else menu_text += "\nTurn: OFF";
    return begin_dialog_ctx(user, menu_text, make_menu_pairs(acl));
}

/* ---------- Kernel Helpers ---------- */
integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    g_acl_pending = TRUE;
    return 0;
}

/* ================================ Events =============================== */
default {
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        g_user = NULL_KEY;
        reset_listen();
        g_acl_pending = FALSE;
        g_last_acl_level = ACL_NOACCESS;

        /* announce plugin soft reset to kernel */
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
        j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
        llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);

        /* register (with script name) */
        register_self();

        /* request controls (optional for leash follow) */
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);

        /* run loop for follow visuals */
        llSetTimerEvent(FOLLOW_TICK);

        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    run_time_permissions(integer perm) {
        if (perm & PERMISSION_TAKE_CONTROLS) g_controls_ok = TRUE;
        else g_controls_ok = FALSE;
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* ACL result back from AUTH */
        if (num == AUTH_RESULT_NUM) {
            if (!g_acl_pending) return;
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != CONS_MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;
            if (!json_has(msg, ["level"])) return;
            key who  = (key)llJsonGetValue(msg, ["avatar"]);
            integer lvl = (integer)llJsonGetValue(msg, ["level"]);
            if (who != g_user) return;
            g_acl_pending = FALSE;
            g_last_acl_level = lvl;
            if (in_allowed_levels(lvl)) show_main_menu(g_user, lvl);
            else {
                llRegionSayTo(g_user, 0, "Access denied.");
                string r = llList2Json(JSON_OBJECT, []);
                r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
                r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);
                g_user = NULL_KEY;
                reset_listen();
            }
            return;
        }

        /* Kernel asks us to (re)register now */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"])) {
                if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
                    /* If a script filter is present, ensure it's us */
                    if (json_has(msg, ["script"])) {
                        string want = llJsonGetValue(msg, ["script"]);
                        if (want != llGetScriptName()) return;
                    }
                    register_self();
                }
            }
            return;
        }

        /* Kernel heartbeat ping → pong */
        if (num == K_PLUGIN_PING) {
            if (json_has(msg, ["type"])) {
                if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_PING) {
                    /* Optionally check context; kernel sends ours */
                    if (json_has(msg, ["context"])) {
                        string c = llJsonGetValue(msg, ["context"]);
                        if (c != PLUGIN_CONTEXT) return;
                    }
                    string r = llList2Json(JSON_OBJECT, []);
                    r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_PONG);
                    r = llJsonSetValue(r, ["context"], PLUGIN_CONTEXT);
                    llMessageLinked(LINK_SET, K_PLUGIN_PONG, r, NULL_KEY);
                }
            }
            return;
        }

        /* UI starting our plugin */
        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"])) {
                if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START) {
                    if (json_has(msg, ["context"])) {
                        if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                            g_user = id;
                            request_acl(g_user);
                        }
                    }
                }
            }
            return;
        }
    }

    timer() {
        /* your follow logic tick */
        leash_follow_logic();
    }
}
