/* =============================================================
   PLUGIN: ds_collar_plugin_leash.lsl  (kernel-HB + full UI)
   PURPOSE: Leashing & Movement Restraint with particles, give/offer, anchor

   CHANGES / FIXES
   - Registers with {"script": llGetScriptName()} so kernel finds script in inventory
   - Replies PING → PONG (heartbeat) and re-registers on "register_now"
   - Single-session dialog (0.2s delay to avoid overlap with root UI dialog)
   - Implements commands:
       Leash (to controller), Unclip, Set Length (picker), Turn ON/OFF
       Give Leash / Offer Leash (scan avatars → pick → leash)
       Anchor (scan nearby scripted/active/passive objects → pick → leash)
   - Paginated scan menus (Prev | Back | Next + up to 9 results)
   - Particles start/stop properly; follow logic tick
   - Guards for ACL via AUTH (plugin shows its own menu only if allowed)
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
string CMD_GIVE      = "give";        // Offer/Give Leash → scan avatars
string CMD_ANCHOR    = "anchor";      // Anchor → scan objects
string CMD_PREV      = "prev";
string CMD_NEXT      = "next";
string CMD_PICK_AV   = "pick_av";     // pick avatar by index (encoded "pick_av:<i>")
string CMD_PICK_OBJ  = "pick_obj";    // pick object by index (encoded "pick_obj:<i>")

/* ---------- Scan config ---------- */
float   SCAN_RADIUS = 5.0;
float   SCAN_ARC    = TWO_PI;

/* ---------- Pagination ---------- */
integer MAX_PAGE_ITEMS = 9;   // up to 9 results + 3 nav buttons = 12 total
integer g_page_idx     = 0;   // current scan page (0-based)

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

/* ---------- Performance flags/caches ---------- */
integer g_psys_on          = FALSE;
key     g_psys_target      = NULL_KEY;
vector  g_last_target      = ZERO_VECTOR;
float   g_last_dist        = -1.0;
float   g_move_hysteresis  = 0.20;
float   g_max_len_margin   = 0.98;

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

integer now() { return llGetUnixTime(); }

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
            if (g_last_dist >= 0.0) {
                if (g_last_dist > (float)g_leash_length) {
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
    g_dialog_expires = now() + DIALOG_TIMEOUT;
    return 0;
}

/* prevent overlap with root UI dialog */
integer begin_dialog_ctx_delayed(key user, string body, list pairs) {
    llSleep(0.2);
    return begin_dialog_ctx(user, body, pairs);
}

integer show_main_menu(key user, integer acl) {
    string menu_text = "Leash state:\n";
    if (g_leashed) menu_text += "Leashed to: " + name_of(g_leasher) + "\n";
    else menu_text += "Not leashed\n";
    menu_text += "Length: " + (string)g_leash_length + " m";
    if (g_turn_to) menu_text += "\nTurn: ON";
    else menu_text += "\nTurn: OFF";
    return begin_dialog_ctx_delayed(user, menu_text, make_menu_pairs(acl));
}

/* ---------- Length picker ---------- */
integer do_set_len(integer m) {
    if (m < 1) m = 1;
    if (m > 30) m = 30;
    g_leash_length = m;
    return TRUE;
}

integer show_length_menu() {
    list labels = ["1","2","3","5","8","10","12","15","20"];
    list pairs  = [ BTN_FILL, CMD_FILL, BTN_BACK, CMD_BACK, BTN_FILL, CMD_FILL ];
    integer i = 0;
    while (i < llGetListLength(labels)) {
        string lab = llList2String(labels, i);
        pairs += [ lab, CMD_SETVAL ];
        i = i + 1;
    }
    return begin_dialog_ctx_delayed(g_user, "Pick leash length (m)", pairs);
}

/* ---------- Return control to root UI ---------- */
integer do_back() {
    string r = llList2Json(JSON_OBJECT, []);
    r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, g_user);
    g_user = NULL_KEY;
    reset_listen();
    return TRUE;
}

/* ---------- Leash / Unclip ---------- */
integer do_leash(key who) {
    if (who == NULL_KEY) return FALSE;
    g_leasher  = who;
    g_leashed  = TRUE;
    draw_leash_particles(g_leasher);
    return TRUE;
}

integer do_unclip() {
    g_leashed = FALSE;
    g_leasher = NULL_KEY;
    llStopMoveToTarget();
    g_last_target = ZERO_VECTOR;
    stop_leash_particles();
    return TRUE;
}

/* ---------- Turn toggle ---------- */
integer do_toggle_turn() {
    if (g_turn_to) g_turn_to = FALSE;
    else g_turn_to = TRUE;
    if (!g_turn_to) clear_turn();
    return TRUE;
}

/* ===================== Scanning & pickers ===================== */
integer start_scan_avatars() {
    g_scan_mode = "give";
    g_scan_keys = [];
    g_scan_labels = [];
    g_page_idx = 0;
    g_scan_expires = now() + SCAN_TIMEOUT;
    llSensor("", NULL_KEY, AGENT, SCAN_RADIUS, SCAN_ARC);
    return TRUE;
}

integer start_scan_objects() {
    g_scan_mode = "anchor";
    g_scan_keys = [];
    g_scan_labels = [];
    g_page_idx = 0;
    g_scan_expires = now() + SCAN_TIMEOUT;
    integer mask = ACTIVE | PASSIVE | SCRIPTED;
    llSensor("", NULL_KEY, mask, SCAN_RADIUS, SCAN_ARC);
    return TRUE;
}

string label_with_index(string base, integer idx) {
    /* ensure uniqueness in dialog; append small index marker */
    return base + " [" + (string)idx + "]";
}

integer show_scan_page() {
    integer total = llGetListLength(g_scan_keys);
    if (total <= 0) {
        if (g_scan_mode == "give") {
            llRegionSayTo(g_user, 0, "No nearby avatars.");
        } else {
            llRegionSayTo(g_user, 0, "No nearby objects.");
        }
        show_main_menu(g_user, g_last_acl_level);
        return FALSE;
    }

    /* compute page bounds */
    integer start = g_page_idx * MAX_PAGE_ITEMS;
    integer end   = start + MAX_PAGE_ITEMS - 1;
    if (end >= total) end = total - 1;

    list pairs = [ BTN_FILL, CMD_FILL, BTN_BACK, CMD_BACK, BTN_FILL, CMD_FILL ];

    integer i = start;
    while (i <= end) {
        string lab = llList2String(g_scan_labels, i);
        string shown = label_with_index(lab, i);
        if (g_scan_mode == "give") {
            pairs += [ shown, CMD_PICK_AV + ":" + (string)i ];
        } else {
            pairs += [ shown, CMD_PICK_OBJ + ":" + (string)i ];
        }
        i = i + 1;
    }

    /* nav buttons */
    string title = "Select target";
    if (g_scan_mode == "give") title = "Select avatar to leash";
    else title = "Select object to anchor";
    string body = "Results " + (string)(start+1) + "-" + (string)(end+1) + " of " + (string)total;

    /* add Prev/Next if applicable by prepending */
    integer havePrev = FALSE;
    integer haveNext = FALSE;
    if (g_page_idx > 0) havePrev = TRUE;
    if ((end + 1) < total) haveNext = TRUE;

    list nav = [];
    string left = BTN_FILL;
    string right = BTN_FILL;
    if (havePrev) left = "<<";
    if (haveNext) right = ">>";
    /* prepend to keep them in first row */
    nav = [ left, CMD_PREV, BTN_FILL, CMD_FILL, right, CMD_NEXT ];
    pairs = nav + pairs;

    return begin_dialog_ctx_delayed(g_user, title + "\n" + body, pairs);
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

    /* AUTH replies with ACL level for the current user */
    link_message(integer sender, integer num, string msg, key id) {
        /* ACL RESULT */
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

            if (in_allowed_levels(lvl)) {
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

        /* Kernel asks us to (re)register now */
        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"])) {
                if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
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
                            /* ask AUTH to evaluate this user */
                            string j = llList2Json(JSON_OBJECT, []);
                            j = llJsonSetValue(j, ["type"],   CONS_MSG_ACL_QUERY);
                            j = llJsonSetValue(j, ["avatar"], (string)g_user);
                            llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
                            g_acl_pending = TRUE;
                        }
                    }
                }
            }
            return;
        }
    }

    /* Sensor returns lists for scans */
    sensor(integer num) {
        if (g_scan_mode == "") return;

        g_scan_keys = [];
        g_scan_labels = [];

        integer i = 0;
        while (i < num) {
            key k = llDetectedKey(i);
            string nm = llDetectedName(i);
            if (nm == "") nm = (string)k;

            /* Filter out the wearer on avatar scans where it makes no sense to leash to self */
            integer include = TRUE;
            if (g_scan_mode == "give") {
                if (k == llGetOwner()) include = FALSE;
            }

            if (include) {
                g_scan_keys += [ k ];
                g_scan_labels += [ nm ];
            }
            i = i + 1;
        }

        if (g_scan_mode == "give") {
            show_scan_page();
        } else {
            show_scan_page();
        }
    }

    no_sensor() {
        if (g_scan_mode == "give") {
            llRegionSayTo(g_user, 0, "No nearby avatars.");
        } else if (g_scan_mode == "anchor") {
            llRegionSayTo(g_user, 0, "No nearby objects.");
        }
        show_main_menu(g_user, g_last_acl_level);
    }

    /* Handle all dialog clicks */
    listen(integer chan, string nm, key id, string msg) {
        if (chan != g_menu_chan) return;

        /* map clicked label to command string we stored */
        integer idx = llListFindList(g_btn_labels, [msg]);
        if (idx == -1) {
            show_main_menu(g_user, g_last_acl_level);
            return;
        }
        string cmd = llList2String(g_btn_cmds, idx);

        if (cmd == CMD_BACK) {
            do_back();
            return;
        }

        if (cmd == CMD_LEASH) {
            do_leash(g_user);
            show_main_menu(g_user, g_last_acl_level);
            return;
        }

        if (cmd == CMD_UNCLIP) {
            do_unclip();
            show_main_menu(g_user, g_last_acl_level);
            return;
        }

        if (cmd == CMD_TURN) {
            do_toggle_turn();
            show_main_menu(g_user, g_last_acl_level);
            return;
        }

        if (cmd == CMD_SETLEN) {
            show_length_menu();
            return;
        }

        if (cmd == CMD_SETVAL) {
            integer L = (integer)msg; /* since labels are numeric in that menu */
            do_set_len(L);
            show_main_menu(g_user, g_last_acl_level);
            return;
        }

        if (cmd == CMD_GIVE) {
            start_scan_avatars();
            return;
        }

        if (cmd == CMD_ANCHOR) {
            start_scan_objects();
            return;
        }

        if (cmd == CMD_PREV) {
            if (g_page_idx > 0) g_page_idx = g_page_idx - 1;
            show_scan_page();
            return;
        }

        if (cmd == CMD_NEXT) {
            integer total = llGetListLength(g_scan_keys);
            integer maxPage = 0;
            if (total > 0) {
                maxPage = (total - 1) / MAX_PAGE_ITEMS; /* integer division */
            }
            if (g_page_idx < maxPage) g_page_idx = g_page_idx + 1;
            show_scan_page();
            return;
        }

        /* dynamic picks: "pick_av:<i>" or "pick_obj:<i>" */
        integer p = llSubStringIndex(cmd, ":");
        if (p != -1) {
            string head = llGetSubString(cmd, 0, p - 1);
            string tail = llGetSubString(cmd, p + 1, -1);
            integer sel = (integer)tail;
            if (head == CMD_PICK_AV) {
                if (sel >= 0) {
                    if (sel < llGetListLength(g_scan_keys)) {
                        key target = llList2Key(g_scan_keys, sel);
                        do_leash(target);
                        show_main_menu(g_user, g_last_acl_level);
                        return;
                    }
                }
            }
            if (head == CMD_PICK_OBJ) {
                if (sel >= 0) {
                    if (sel < llGetListLength(g_scan_keys)) {
                        key target2 = llList2Key(g_scan_keys, sel);
                        do_leash(target2);
                        show_main_menu(g_user, g_last_acl_level);
                        return;
                    }
                }
            }
        }

        /* no-op and defaults */
        if (cmd == CMD_FILL) {
            show_main_menu(g_user, g_last_acl_level);
            return;
        }

        show_main_menu(g_user, g_last_acl_level);
    }

    timer() {
        /* close dialog on timeout */
        if (g_dialog_expires != 0) {
            if (now() >= g_dialog_expires) {
                reset_listen();
                g_dialog_expires = 0;
            }
        }

        /* leash follow visuals */
        leash_follow_logic();

        /* scan timeout guard */
        if (g_scan_mode != "") {
            if (now() >= g_scan_expires) {
                g_scan_mode = "";
                g_scan_keys = [];
                g_scan_labels = [];
                g_page_idx = 0;
            }
        }
    }
}
