/* =============================================================
   PLUGIN: ds_collar_plugin_skeleton.lsl  (ACL Filter edition)
   ROLE  : Template for UI plugins using kmod_acl_filter
   NOTES :
     - No AUTH calls here. All gating is done by the ACL filter.
     - Opens ONLY when started by the filter with {ticket, caps}.
     - Buttons are pre-filtered by 'caps' and rechecked on click.
     - Heartbeat remains (ping/pong) + proper Back handling.
     - Dual-display registration supported (tpe_min_acl/label_tpe/audience).
     - Optional: advertise per-button ACL via caps_meta → precise 'caps'.
   ============================================================= */

integer DEBUG = FALSE;

/* ---------- Kernel / System link numbers ---------- */
integer K_PLUGIN_REG_QUERY   = 500;
integer K_PLUGIN_REG_REPLY   = 501;
integer K_PLUGIN_SOFT_RESET  = 504;

integer K_PLUGIN_PING        = 650;
integer K_PLUGIN_PONG        = 651;

/* AUTH channels are NOT used here */

/* The filter will forward starts/actions on this channel: */
integer K_PLUGIN_START       = 900;   /* {"type":"plugin_start"...} or {"type":"plugin_action"...} */
integer K_PLUGIN_RETURN_NUM  = 901;

/* ---------- ACL Filter API (for caps_meta) ---------- */
integer K_ACLF_QUERY_NUM     = 740;   /* we *send* TYPE_CAPS_META here */

/* ---------- Protocol strings ---------- */
string TYPE_REGISTER         = "register";
string TYPE_REGISTER_NOW     = "register_now";
string TYPE_PLUGIN_SOFT_RESET= "plugin_soft_reset";
string TYPE_PLUGIN_START     = "plugin_start";
string TYPE_PLUGIN_ACTION    = "plugin_action";
string TYPE_PLUGIN_RETURN    = "plugin_return";
string TYPE_PLUGIN_PING      = "plugin_ping";
string TYPE_PLUGIN_PONG      = "plugin_pong";
string TYPE_CAPS_META        = "caps_meta";

/* ---------- Identity / registration ---------- */
string PLUGIN_CONTEXT        = "core_example";   // <— change per plugin
string ROOT_CONTEXT          = "core_root";
string PLUGIN_LABEL          = "Example";        // label shown in the root UI
integer PLUGIN_MIN_ACL       = 2;                // 0..5 (normal menu)

/* Dual-display registration (TPE bucket) */
integer REG_HAS_TPE          = TRUE;
integer REG_TPE_MIN_ACL      = 0;                // 0..5 (TPE menu bucket)
string  REG_LABEL_TPE        = "Example (TPE)";  // optional
string  REG_AUDIENCE         = "all";            // "all" | "wearer" | "others"

/* ---------- Optional: per-button ACL metadata for the filter ----------
   Format: flat list [label, min_acl, label, min_acl, ...]
   The filter uses this to compute 'caps' booleans per button.
   If empty, the filter falls back to "__default__": (acl >= PLUGIN_MIN_ACL).
*/
list CAP_META = [
    "Do Thing", 2,
    "Settings", 2
];

/* ---------- UI session ---------- */
key     User       = NULL_KEY;
integer Listen     = 0;
integer MenuChan  = 0;
string  s_context    = "";       // "", "menu", "settings", ...

/* ---------- ACL Filter: ticket + caps ---------- */
string  Ticket     = "";       // provided by filter on start/action
string  CapsJson  = "";       // {"__default__":1,"Do Thing":1,...}

/* ---------- Heartbeat ---------- */
integer HB_TICK_SEC      = 10;   // timer tick
integer HB_SILENCE_SEC   = 60;   // if no ping this long → re-register
integer LastPingEpoch  = 0;

/* ---------- Utils ---------- */
integer logd(string s){ if (DEBUG) llOwnerSay("[SKELETON] " + s); return 0; }
integer now(){ return llGetUnixTime(); }
integer json_has(string j, list path){ return (llJsonGetValue(j, path) != JSON_INVALID); }
integer json_int(string j, list path, integer def){
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return def;
    if (v == "" && (integer)("0"+v) == 0) return def;
    return (integer)v;
}
string json_str(string j, list path, string def){
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return def;
    return v;
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

/* Optional: tell the filter our per-button ACL requirements */
integer register_caps_meta(){
    if (llGetListLength(CAP_META) <= 0) return 0;

    string arr = llList2Json(JSON_ARRAY, []);
    integer i = 0; integer n = llGetListLength(CAP_META);
    while (i+1 < n){
        string label = llList2String(CAP_META, i);
        integer need = llList2Integer(CAP_META, i+1);
        string obj = llList2Json(JSON_OBJECT, []);
        obj = llJsonSetValue(obj, ["label"], label);
        obj = llJsonSetValue(obj, ["min_acl"], (string)need);
        arr = llJsonSetValue(arr, [JSON_APPEND], obj);
        i += 2;
    }

    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    TYPE_CAPS_META);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    j = llJsonSetValue(j, ["actions"], arr);
    llMessageLinked(LINK_SET, K_ACLF_QUERY_NUM, j, NULL_KEY);
    logd("Sent caps_meta.");
    return 0;
}

/* HB init: call after register_self() */
integer hb_init(){ LastPingEpoch = now(); llSetTimerEvent((float)HB_TICK_SEC); return 0; }
integer hb_on_ping_ok(){ LastPingEpoch = now(); return 0; }
integer hb_tick(){
    if ((now() - LastPingEpoch) > HB_SILENCE_SEC){
        register_self(); // defensive re-register
        LastPingEpoch = now();
    }
    return 0;
}

/* =============================================================
   ACL Filter: ticket + caps helpers
   ============================================================= */
integer caps_has(string label){
    if (CapsJson == "") return FALSE;
    if (json_has(CapsJson, [label])){
        return (json_int(CapsJson, [label], 0) != 0);
    }
    /* fall back to default if not explicitly listed */
    return (json_int(CapsJson, ["__default__"], 0) != 0);
}

list filter_buttons(list inBtns){
    list out = [];
    integer i = 0; integer n = llGetListLength(inBtns);
    while (i < n){
        string b = llList2String(inBtns, i);
        if (b == "Back" || caps_has(b)) out += b;
        i += 1;
    }
    /* Always ensure Back exists and pad to multiples of 3 for llDialog */
    if (llListFindList(out, ["Back"]) < 0) out += "Back";
    while ((llGetListLength(out) % 3) != 0) out += " ";
    return out;
}

/* =============================================================
   UI helpers
   ============================================================= */
integer reset_listen(){
    if (Listen) llListenRemove(Listen);
    Listen = 0;
    MenuChan = 0;
    return 0;
}
integer dialog_to(key who, string body, list buttons){
    reset_listen();
    MenuChan = -100000 - (integer)llFrand(1000000.0);
    Listen = llListen(MenuChan, "", who, "");
    llDialog(who, body, buttons, MenuChan);
    return 0;
}
integer ui_return_root(key toUser){
    string r = llList2Json(JSON_OBJECT,[]);
    r = llJsonSetValue(r, ["type"],    TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, toUser);
    return 0;
}

/* ---------- Menus ---------- */
list menu_root_buttons(){
    /* Add your real actions here; they’ll be filtered by caps. */
    list btns = ["Do Thing", "Settings", "Back"];
    return filter_buttons(btns);
}
integer show_menu_root(key user){
    s_context = "menu";
    string body = "Example plugin menu.\nChoose an action:";
    dialog_to(user, body, menu_root_buttons());
    return 0;
}
integer show_menu_settings(key user){
    s_context = "settings";
    string body = "Settings:\n(placeholder options)";
    list btns = filter_buttons(["Option A", "Option B", "Back"]);
    dialog_to(user, body, btns);
    return 0;
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        /* baseline init */
        User = NULL_KEY;
        s_context = "";
        Ticket = "";
        CapsJson = "";
        reset_listen();

        notify_soft_reset();
        register_self();
        register_caps_meta();   // optional but recommended
        hb_init();              // enable heartbeat

        logd("Ready (ACL Filter edition).");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    /* Kernel lifecycle / heartbeat */
    link_message(integer sender, integer num, string msg, key id){
        /* Heartbeat ping/pong */
        if (num == K_PLUGIN_PING){
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_PLUGIN_PING){
                if (json_has(msg, ["context"]) && llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                hb_on_ping_ok();
                string pong = llList2Json(JSON_OBJECT,[]);
                pong = llJsonSetValue(pong, ["type"],    TYPE_PLUGIN_PONG);
                pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
            }
            return;
        }

        /* Re-register on demand (optional) */
        if (num == K_PLUGIN_REG_QUERY){
            if (json_has(msg, ["type"]) && llJsonGetValue(msg, ["type"]) == TYPE_REGISTER_NOW){
                if (json_has(msg, ["script"])){
                    string want = llJsonGetValue(msg, ["script"]);
                    if (want != llGetScriptName()) return;
                }
                register_self();
                register_caps_meta();
                hb_on_ping_ok();
            }
            return;
        }

        /* Filter → Plugin: open or perform action */
        if (num == K_PLUGIN_START){
            if (!json_has(msg, ["type"])) return;
            string t = llJsonGetValue(msg, ["type"]);

            /* ---- Open request from filter ---- */
            if (t == TYPE_PLUGIN_START){
                if (!json_has(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                /* MUST have a ticket and caps from the filter */
                if (!json_has(msg, ["ticket"]) || !json_has(msg, ["caps"])){
                    /* Deny + bounce to root for safety */
                    key who = id;
                    if (who != NULL_KEY) llRegionSayTo(who, 0, "Access denied (no ticket).");
                    if (who != NULL_KEY) ui_return_root(who);
                    return;
                }

                User = id;                   /* filter forwards with id = avatar */
                Ticket = llJsonGetValue(msg, ["ticket"]);
                CapsJson = llJsonGetValue(msg, ["caps"]);

                /* Open root menu immediately (no AUTH roundtrip). */
                show_menu_root(User);
                return;
            }

            /* ---- Remote action from filter (optional) ---- */
            if (t == TYPE_PLUGIN_ACTION){
                if (!json_has(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                if (!json_has(msg, ["ticket"])) return;  /* require fresh ticket */
                string action = json_str(msg, ["action"], "");
                if (action == "") return;

                /* Enforce caps defensively */
                if (!caps_has(action)) return;

                /* Perform the action; keep it idempotent and safe */
                key who = id; /* avatar the filter evaluated */
                if (action == "Do Thing"){
                    llRegionSayTo(who, 0, "You did the thing. (remote)");
                }
                /* add more remote-safe actions here */

                return;
            }

            return;
        }
    }

    /* Dialog replies */
    listen(integer chan, string name, key id, string b){
        if (chan != MenuChan) return;

        /* Back nav */
        if (b == "Back"){
            if (s_context == "menu"){
                ui_return_root(id);    // from plugin root → back to main UI
                reset_listen();
                User = NULL_KEY;
                s_context = "";
                return;
            }
            /* from any sub-menu → go back to plugin root */
            show_menu_root(id);
            return;
        }

        /* Root actions */
        if (s_context == "menu"){
            if (b == "Do Thing"){
                if (!caps_has("Do Thing")){ llRegionSayTo(id, 0, "Not allowed."); show_menu_root(id); return; }
                /* Do the actual work here */
                llRegionSayTo(id, 0, "You did the thing. (demo)");
                show_menu_root(id);
                return;
            }
            if (b == "Settings"){
                if (!caps_has("Settings")){ llRegionSayTo(id, 0, "Not allowed."); show_menu_root(id); return; }
                show_menu_settings(id);
                return;
            }
            /* unknown → redraw */
            show_menu_root(id);
            return;
        }

        /* Settings actions */
        if (s_context == "settings"){
            if (b == "Option A"){
                if (!caps_has("Option A")){ llRegionSayTo(id, 0, "Not allowed."); show_menu_settings(id); return; }
                llRegionSayTo(id, 0, "Toggled Option A. (demo)");
                show_menu_settings(id);
                return;
            }
            if (b == "Option B"){
                if (!caps_has("Option B")){ llRegionSayTo(id, 0, "Not allowed."); show_menu_settings(id); return; }
                llRegionSayTo(id, 0, "Toggled Option B. (demo)");
                show_menu_settings(id);
                return;
            }
            /* unknown → back to root */
            show_menu_root(id);
            return;
        }

        /* Fallback → root */
        show_menu_root(id);
    }

    /* Timer (heartbeat only) */
    timer(){ hb_tick(); }
}
