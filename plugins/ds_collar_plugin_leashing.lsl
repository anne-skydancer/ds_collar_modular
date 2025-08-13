/* =============================================================
   PLUGIN: ds_collar_plugin_leash.lsl (New Kernel + Full Features)
   PURPOSE: Leashing & Movement Restraint with particles, give/offer, anchor
   NOTES:
     - Buttons mapped by command context (not labels)
     - ACL-based menu filtering per final rules
       ACL 1: Leash, Unclip, Anchor
       ACL 2: Offer Leash, Set Length
       ACL 3: Leash, Unclip, Set Length, Turn, Give Leash, Anchor
       ACL 4: Offer Leash, Anchor, Unclip
       ACL 5: Full set (Give Leash only; no Pass separate)
     - "Pass Leash" merged into "Give Leash"
     - No ternary operators; explicit if/else only
     - Paginated scan pickers: Prev | Back | Next + up to 9 items (max 12 buttons)
     - Scan radius: 5m, TWO_PI
   ============================================================= */

integer DEBUG = TRUE;

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

/* ---------- ACL levels ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;
list    ALLOWED_LEVELS    = [1,2,3,4,5];

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

// Performance flags/caches
integer g_psys_on          = FALSE;
vector  g_last_target      = ZERO_VECTOR;
float   g_last_dist        = -1.0;
float   g_move_hysteresis  = 0.20;   // meters before we recompute + move
float   g_max_len_margin   = 0.98;   // same as before, keep
float   g_fast_tick        = 0.25;   // when actively following
float   g_slow_tick        = 1.00;   // when menu open / idle
integer g_menu_open        = FALSE;  // track when dialog is up
string  g_last_menu_text   = "";     // avoid re-opening identical dialogs

/* ========================== Helpers ========================== */
integer json_has(string j, list path) { return (llJsonGetValue(j, path) != JSON_INVALID); }
integer logd(string s) { if (DEBUG) llOwnerSay("[LEASH] " + s); return 0; }
integer is_level_allowed(integer lvl) { return (llListFindList(ALLOWED_LEVELS, [lvl]) != -1); }

integer reset_listen() {
    if (g_listen) llListenRemove(g_listen);
    g_listen = 0; g_menu_chan = 0;
    g_btn_labels = []; g_btn_cmds = [];
    return 0;
}

/* ---------- Private IM helpers ---------- */
integer im_to(key who, string msg) { if (who) llInstantMessage(who, msg); return 0; }
string wearer_name() { return llKey2Name(llGetOwner()); }
string name_of(key k) { return llKey2Name(k); }

/* =================== Particles & Movement =================== */
vector leash_anchor_point() {
    integer nprims = llGetNumberOfPrims();
    integer i;
    for (i = 2; i <= nprims; ++i) {
        string nm = llGetLinkName(i);
        string desc = llList2String(llGetLinkPrimitiveParams(i, [PRIM_DESC]), 0);
        if (llToLower(nm) == "leashring" || llToLower(desc) == "leash:ring") {
            vector child_local = llList2Vector(llGetLinkPrimitiveParams(i, [PRIM_POS_LOCAL]), 0);
            return llGetRootPosition() + (child_local * llGetRootRotation());
        }
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

    // Only (re)emit when the system is off or the target changed
    if (!g_psys_on || g_psys_target != to) {
        g_psys_target = to;
        llParticleSystem([
            PSYS_SRC_PATTERN,         PSYS_SRC_PATTERN_DROP,
            PSYS_SRC_TEXTURE,         g_chain_texture,
            PSYS_SRC_BURST_RATE,      0.00,
            PSYS_SRC_BURST_PART_COUNT,1,

            // keep alpha explicit (some viewers differ on defaults)
            PSYS_PART_START_ALPHA,    1.0,
            PSYS_PART_END_ALPHA,      1.0,

            PSYS_PART_MAX_AGE,        2.6,
            PSYS_PART_START_SCALE,    <0.07, 0.07, 0>,
            PSYS_PART_END_SCALE,      <0.07, 0.07, 0>,
            PSYS_PART_START_COLOR,    <1.0, 1.0, 1.0>,
            PSYS_PART_END_COLOR,      <1.0, 1.0, 1.0>,

            PSYS_SRC_ACCEL,           <0,0,-1.25>,
            PSYS_PART_FLAGS,          PSYS_PART_INTERP_COLOR_MASK
                                     | PSYS_PART_FOLLOW_SRC_MASK
                                     | PSYS_PART_TARGET_POS_MASK
                                     | PSYS_PART_FOLLOW_VELOCITY_MASK
                                     | PSYS_PART_RIBBON_MASK,

            PSYS_SRC_TARGET_KEY,      to
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

    // Only act when over length or distance changed notably
    if (g_controls_ok) {
        if (dist > (float)g_leash_length) {
            vector tgt = leash_point + llVecNorm(offset) * (float)g_leash_length * g_max_len_margin;

            // Only issue a new MoveToTarget if target changed meaningfully
            if (llVecMag(tgt - g_last_target) > g_move_hysteresis) {
                llMoveToTarget(tgt, 0.5);
                g_last_target = tgt;
            }

            if (g_turn_to) turn_to_leasher(g_leasher);
        } else {
            // if inside length, stop moving if we had an active target
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
    }
    else if (acl == 2) {
        pairs += ["Offer Leash", CMD_GIVE, "Set Length", CMD_SETLEN];
    }
    else if (acl == 3) {
        pairs += ["Leash", CMD_LEASH, "Unclip", CMD_UNCLIP, "Set Length", CMD_SETLEN,
                  "Turn", CMD_TURN, "Give Leash", CMD_GIVE, "Anchor", CMD_ANCHOR];
    }
    else if (acl == 4) {
        pairs += ["Offer Leash", CMD_GIVE, "Anchor", CMD_ANCHOR, "Unclip", CMD_UNCLIP];
    }
    else { // ACL 5
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

    integer i;
    for (i = 0; i < llGetListLength(pairs); i += 2) {
        g_btn_labels += llList2String(pairs, i);
        g_btn_cmds   += llList2String(pairs, i+1);
    }

    g_menu_chan = -100000 - (integer)llFrand(1000000.0);
    g_listen    = llListen(g_menu_chan, "", g_user, "");

    /* no padding: only display available buttons */
    llDialog(g_user, body, g_btn_labels, g_menu_chan);

    g_dialog_expires = llGetUnixTime() + DIALOG_TIMEOUT;
    return 0;
}

integer show_main_menu(key user, integer acl) {
    string menu_text = "Leash state:\n";
    if (g_leashed) {
        menu_text += "Leashed to: " + name_of(g_leasher) + "\n";
    } else {
        menu_text += "Not leashed\n";
    }
    menu_text += "Length: " + (string)g_leash_length + " m";
    if (g_turn_to) {
        menu_text += "\nTurn: ON";
    } else {
        menu_text += "\nTurn: OFF";
    }

    return begin_dialog_ctx(user, menu_text, make_menu_pairs(acl));
}

/* ---------- Length menu ---------- */
integer show_length_menu() {
    list pairs = [ BTN_FILL, CMD_FILL, BTN_BACK, CMD_BACK, BTN_FILL, CMD_FILL ];
    list opts = [1,2,5,10,15,20];
    integer i = 0;
    while (i < llGetListLength(opts)) {
        string lab = (string)llList2Integer(opts, i);
        string cmd = CMD_SETVAL + ":" + lab;
        pairs += [lab, cmd];
        i++;
    }
    string body = "Select leash length (meters):\nCurrent: " + (string)g_leash_length + " m";
    return begin_dialog_ctx(g_user, body, pairs);
}

/* ===================== Scan flows (give/anchor) + Pagination ===================== */
integer start_avatar_scan(string mode) {
    g_scan_mode = mode;          // "give"
    g_scan_keys = []; g_scan_labels = [];
    g_page_idx = 0;
    g_scan_expires = llGetUnixTime() + SCAN_TIMEOUT;
    llSensor("", NULL_KEY, AGENT, 5.0, TWO_PI);  // 5m radius
    return 0;
}
integer start_object_scan() {
    g_scan_mode = "anchor";
    g_scan_keys = []; g_scan_labels = [];
    g_page_idx = 0;
    g_scan_expires = llGetUnixTime() + SCAN_TIMEOUT;
    llSensor("", NULL_KEY, ACTIVE | PASSIVE, 5.0, TWO_PI); // 5m radius
    return 0;
}

integer show_scan_pick_menu(string title) {
    // Nav row: Prev | Back | Next
    list pairs = [ "Prev", CMD_PREV, BTN_BACK, CMD_BACK, "Next", CMD_NEXT ];

    integer total = llGetListLength(g_scan_keys);
    if (total == 0) {
        // No results; OK-only message
        pairs = [ BTN_FILL, CMD_FILL, BTN_BACK, CMD_BACK, BTN_FILL, CMD_FILL, "OK", CMD_OK ];
        return begin_dialog_ctx(g_user, "Nothing found within 5m.", pairs);
    }

    // Clamp page if out of range
    integer start = g_page_idx * MAX_PAGE_ITEMS;
    if (start >= total) {
        g_page_idx = 0;
        start = 0;
    }
    integer end = start + MAX_PAGE_ITEMS - 1;
    if (end > (total - 1)) end = total - 1;

    // Add page rows (numbered)
    list lines = [];
    integer i = start;
    integer local_ix = 1;
    while (i <= end) {
        key k = llList2Key(g_scan_keys, i);
        string label = llList2String(g_scan_labels, i);

        lines += ( (string)local_ix + ") " + label );

        // Button + command maps to ABSOLUTE index i
        string btn = (string)local_ix;
        string cmd;
        if (g_scan_mode == "anchor") {
            cmd = CMD_PICK_OBJ + ":" + (string)i;
        } else {
            cmd = CMD_PICK_AV + ":" + (string)i;
        }
        pairs += [ btn, cmd ];

        i += 1;
        local_ix += 1;
    }

    // Page footer (Page X of Y)
    integer pages = total / MAX_PAGE_ITEMS;
    if ((total % MAX_PAGE_ITEMS) != 0) pages += 1;
    if (pages < 1) pages = 1;
    integer human_page = g_page_idx + 1;

    string info = title + "\n(Page " + (string)human_page + " of " + (string)pages + ")\n"
                + llDumpList2String(lines, "\n");

    return begin_dialog_ctx(g_user, info, pairs);
}

/* =========================== Kernel Helpers =========================== */
integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    g_acl_pending = TRUE;
    return 0;
}

/* ================================ Events =============================== */
default
{
    state_entry() {
        PLUGIN_SN = (integer)(llFrand(1.0e9));
        g_user = NULL_KEY;
        reset_listen();
        g_acl_pending = FALSE;
        g_last_acl_level = ACL_NOACCESS;

        /* Start with a small timer; we multiplex UI timeout + follow */
        llSetTimerEvent(FOLLOW_TICK);

        /* New-kernel announcements */
        string j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
        j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
        llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);

        j = llList2Json(JSON_OBJECT, []);
        j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
        j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
        j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
        j = llJsonSetValue(j, ["min_acl"],  (string)PLUGIN_MIN_ACL);
        j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
        llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);

        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
        logd("Ready. SN=" + (string)PLUGIN_SN);
    }

    run_time_permissions(integer perm) {
        if (perm & PERMISSION_TAKE_CONTROLS) g_controls_ok = TRUE;
        else g_controls_ok = FALSE;
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        /* Heartbeat */
        if (num == K_PLUGIN_PING) {
            if (json_has(msg, ["type"])) {
                if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_PING) {
                    if (json_has(msg, ["context"])) {
                        if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                            string pong = llList2Json(JSON_OBJECT, []);
                            pong = llJsonSetValue(pong, ["type"],    CONS_TYPE_PLUGIN_PONG);
                            pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                            llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                        }
                    }
                }
            }
            return;
        }

        /* Kernel: register_now for this script */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"])) {
                if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
                    if (json_has(msg, ["script"])) {
                        if (llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                            string j = llList2Json(JSON_OBJECT, []);
                            j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
                            j = llJsonSetValue(j, ["sn"],       (string)PLUGIN_SN);
                            j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
                            j = llJsonSetValue(j, ["min_acl"],  (string)PLUGIN_MIN_ACL);
                            j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
                            llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
                        }
                    }
                }
            }
            return;
        }

        /* AUTH result (gate UI) */
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

            if (is_level_allowed(lvl)) {
                show_main_menu(g_user, lvl);
            } else {
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

        /* UI: start → request ACL first */
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
        
        if (num == SOS_MSG_NUM && json_has(msg, [ "type" ])) {
            string t = llJsonGetValue(msg, ["type"]);
            if ( t == "sos_unleash") {
                stop_leash_particles(); llStopMoveToTarget(); clear_turn();
                llOwnerSay("[SOS] Leash released.");
                return;
            }
        }
    }

    /* ---------- Scan results ---------- */
    sensor(integer n) {
        g_scan_keys = [];
        g_scan_labels = [];
        integer i;
        for (i = 0; i < n; ++i) {
            key found = llDetectedKey(i);
            if (found == llGetOwner()) jump skip_av; // skip wearer
            g_scan_keys   += found;
            g_scan_labels += llDetectedName(i);
            @skip_av;
        }

        if (g_scan_mode == "anchor") {
            show_scan_pick_menu("Anchor leash to object:");
        } else {
            show_scan_pick_menu("Give leash to:");
        }
    }

    no_sensor() {
        if (g_scan_mode != "") {
            list pairs = [ BTN_FILL, CMD_FILL, BTN_BACK, CMD_BACK, BTN_FILL, CMD_FILL, "OK", CMD_OK ];
            begin_dialog_ctx(g_user, "Nothing found within 5m.", pairs);
            g_scan_mode = "";
            g_scan_keys = []; g_scan_labels = [];
            g_scan_expires = 0;
            g_page_idx = 0;
        }
    }

    /* ---------- UI clicks (context driven) ---------- */
    listen(integer chan, string name, key id, string pressed)
    {
        if (chan != g_menu_chan) return;
        if (id != g_user) return;

        integer idx = llListFindList(g_btn_labels, [pressed]);
        if (idx == -1) return;
        string cmd = llList2String(g_btn_cmds, idx);

        if (cmd == CMD_FILL) return;

        /* Pagination: Prev / Next */
        if (cmd == CMD_PREV) {
            if (g_page_idx > 0) g_page_idx -= 1;
            if (g_scan_mode == "anchor") show_scan_pick_menu("Anchor leash to object:");
            else show_scan_pick_menu("Give leash to:");
            return;
        }
        if (cmd == CMD_NEXT) {
            integer total = llGetListLength(g_scan_keys);
            integer pages = total / MAX_PAGE_ITEMS;
            if ((total % MAX_PAGE_ITEMS) != 0) pages += 1;
            if (pages < 1) pages = 1;
            if (g_page_idx < (pages - 1)) g_page_idx += 1;
            if (g_scan_mode == "anchor") show_scan_pick_menu("Anchor leash to object:");
            else show_scan_pick_menu("Give leash to:");
            return;
        }

        if (cmd == CMD_BACK) {
            g_scan_mode = ""; g_scan_keys = []; g_scan_labels = []; g_scan_expires = 0; g_page_idx = 0;
            string r = llList2Json(JSON_OBJECT, []);
            r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
            r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
            llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);
            reset_listen();
            g_user = NULL_KEY;
            return;
        }

        if (cmd == CMD_OK) {
            show_main_menu(id, g_last_acl_level);
            return;
        }

        if (cmd == CMD_LEASH) {
            g_leashed = TRUE; g_leasher = id;
            im_to(id, "You have grabbed " + wearer_name() + "'s leash.");
            im_to(llGetOwner(), "Your leash has been grabbed by " + name_of(id) + ".");
            draw_leash_particles(g_leasher);
            show_main_menu(id, g_last_acl_level);
            return;
        }

        if (cmd == CMD_UNCLIP) {
            g_leashed = FALSE; g_leasher = NULL_KEY;
            stop_leash_particles(); llStopMoveToTarget(); clear_turn();
            im_to(id, "You have unclipped " + wearer_name() + "'s leash.");
            im_to(llGetOwner(), name_of(id) + " has unclipped your leash.");
            show_main_menu(id, g_last_acl_level);
            return;
        }

        if (cmd == CMD_TURN) {
            if (g_turn_to) g_turn_to = FALSE; else g_turn_to = TRUE;
            show_main_menu(id, g_last_acl_level);
            return;
        }

        if (cmd == CMD_SETLEN) {
            show_length_menu();
            return;
        }

        if (llSubStringIndex(cmd, CMD_SETVAL + ":") == 0) {
            string v = llGetSubString(cmd, llStringLength(CMD_SETVAL) + 1, -1);
            integer newlen = (integer)v;
            if (newlen > 0) g_leash_length = newlen;
            im_to(llGetOwner(), "Leash length set to " + (string)g_leash_length + " meters.");
            show_main_menu(id, g_last_acl_level);
            return;
        }

        if (cmd == CMD_GIVE) {
            start_avatar_scan("give"); // used by "Offer Leash" and "Give Leash"
            return;
        }

        if (cmd == CMD_ANCHOR) {
            start_object_scan();
            return;
        }

        if (llSubStringIndex(cmd, CMD_PICK_AV + ":") == 0) {
            integer sel = (integer)llGetSubString(cmd, llStringLength(CMD_PICK_AV) + 1, -1);
            if (sel >= 0 && sel < llGetListLength(g_scan_keys)) {
                key picked = llList2Key(g_scan_keys, sel);
                g_leashed = TRUE; g_leasher = picked;
                im_to(g_user, "You have given " + wearer_name() + "'s leash to " + name_of(picked) + ".");
                im_to(picked, "You have been given " + wearer_name() + "'s leash.");
                im_to(llGetOwner(), "Your leash has been given to " + name_of(picked) + " by " + name_of(g_user) + ".");
                draw_leash_particles(g_leasher);
            }
            g_scan_mode = ""; g_scan_keys = []; g_scan_labels = []; g_scan_expires = 0; g_page_idx = 0;
            show_main_menu(id, g_last_acl_level);
            return;
        }

        if (llSubStringIndex(cmd, CMD_PICK_OBJ + ":") == 0) {
            integer sel2 = (integer)llGetSubString(cmd, llStringLength(CMD_PICK_OBJ) + 1, -1);
            if (sel2 >= 0 && sel2 < llGetListLength(g_scan_keys)) {
                key picked_obj = llList2Key(g_scan_keys, sel2);
                string obj_name = llList2String(g_scan_labels, sel2);
                g_leashed = TRUE; g_leasher = picked_obj;
                im_to(g_user, "You have anchored " + wearer_name() + "'s leash to " + obj_name + ".");
                im_to(llGetOwner(), "Your leash has been anchored to " + obj_name + " by " + name_of(g_user) + ".");
                draw_leash_particles(g_leasher);
            }
            g_scan_mode = ""; g_scan_keys = []; g_scan_labels = []; g_scan_expires = 0; g_page_idx = 0;
            show_main_menu(id, g_last_acl_level);
            return;
        }
    }

    timer() {
        // Follow tick work
        if (g_leashed) {
            leash_follow_logic();
        } 
        else {
            stop_leash_particles(); // runs once due to g_psys_on guard
            g_last_target = ZERO_VECTOR;
            g_last_dist = -1.0;
        }

        // UI timeout
        if (g_listen && g_dialog_expires > 0) {
            if (llGetUnixTime() > g_dialog_expires) {
                reset_listen();
                g_user = NULL_KEY;
                g_dialog_expires = 0;
                g_menu_open = FALSE;
            } 
            else {
                g_menu_open = TRUE;
            }
        } 
        else {
            g_menu_open = FALSE;
        }

        // Scan timeout
        if (g_scan_mode != "" && g_scan_expires > 0) {
            if (llGetUnixTime() > g_scan_expires) {
                g_scan_mode = "";
                g_scan_keys = []; g_scan_labels = [];
                g_scan_expires = 0; g_page_idx = 0;
                list pairs = [ BTN_FILL, CMD_FILL, BTN_BACK, CMD_BACK, BTN_FILL, CMD_FILL, "OK", CMD_OK ];
                begin_dialog_ctx(g_user, "Scan timed out.", pairs);
            }
        }

        // Adaptive tick: faster only when actually following; slower when menu open/idle
        if (g_leashed && g_controls_ok && !g_menu_open) {
            llSetTimerEvent(g_fast_tick);
        } 
        else {
            llSetTimerEvent(g_slow_tick);
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
