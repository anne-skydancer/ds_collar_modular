// =============================================================
// FILE: ds_collar_api.lsl
// ROLE: Central router for module messages.
//       - UI enforcement (FE/BE lanes + session guard)
//       - Module registry from "hello" (module → lane)
//       - Safe pass-through for non-UI traffic (re-emits on L_API)
// LANES:
//   L_API       (-1000) inbound/outbound API bus
//   L_BROADCAST (-1001) broadcast to "any"
//   L_UI_BE_IN  (-1600) UI Backend ingress
//   L_UI_FE_IN  (-1700) UI Frontend ingress
// NOTES:
//   - LSL: if/else only (no switch).
//   - Pass-through messages are re-emitted once on L_API with "_api_p":"1"
//     so downstream modules receive them and we don't loop.
// =============================================================

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[API] " + s); return TRUE; }

/* Lanes */
integer L_API        = -1000;
integer L_BROADCAST  = -1001;
integer L_UI_BE_IN   = -1600;
integer L_UI_FE_IN   = -1700;

/* Module registry: stride=2 [module_name, lane_int] */
list MODS; integer MS = 2;

integer reg_set(string name, integer lane){
    integer i=0; integer n=llGetListLength(MODS);
    while (i<n){
        if (llList2String(MODS,i) == name){
            MODS = llListReplaceList(MODS, [name, lane], i, i+MS-1);
            return TRUE;
        }
        i += MS;
    }
    MODS += [name, lane];
    return TRUE;
}
integer reg_lane(string name){
    integer i=0; integer n=llGetListLength(MODS);
    while (i<n){
        if (llList2String(MODS,i) == name){
            return llList2Integer(MODS,i+1);
        }
        i += MS;
    }
    return 0; // 0 = not found (valid lanes are negative)
}

/* Helpers */
integer route_to(integer lane, string j, key id){
    llMessageLinked(LINK_SET, lane, j, id);
    return TRUE;
}
string api_make_session(){
    return (string)llGetUnixTime() + "-" + llGetSubString((string)llGenerateKey(),0,7);
}
string api_ensure_session(string s){
    if (s == "" || s == JSON_INVALID) return api_make_session();
    return s;
}
string jset(string j, list path, string v){ return llJsonSetValue(j, path, v); }
string jget(string j, list path){ return llJsonGetValue(j, path); }

default{
    state_entry(){
        MODS = [];
        logd("API up");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        // Only act on messages posted to the API bus
        if (num != L_API){
            return;
        }

        // Prevent infinite loops on our own pass-through
        string passthru = jget(msg, ["_api_p"]);
        if (passthru == "1"){
            // One bounce already done; deliver to listeners and stop.
            return;
        }

        string ty   = jget(msg, ["type"]);
        string to   = jget(msg, ["to"]);
        string from = jget(msg, ["from"]);

        // ---------- Module hello → register their ingress lane ----------
        if (ty == "hello"){
            string lane_s = jget(msg, ["lane"]);
            if (lane_s != JSON_INVALID && from != JSON_INVALID && from != ""){
                integer lane_i = (integer)lane_s;
                reg_set(from, lane_i);
                if (DEBUG) logd("HELLO from " + from + " lane=" + lane_s);
            }
            // Do not forward 'hello'.
            return;
        }

        // ---------- UI → BACKEND enforced ----------
        if (ty == "ui_register_buttons" || ty == "ui_show_message" || ty == "ui_draw" || ty == "ui_touch"){
            string fixed = jset(msg, ["to"], "ui_backend");
            if (DEBUG) logd("EVT " + ty + " " + from + "→ui_backend");
            route_to(L_UI_BE_IN, fixed, id);
            return;
        }

        // ---------- BACKEND → FRONTEND enforced ----------
        if (ty == "ui_render"){
            string sess = jget(msg, ["session"]);
            string sess_ok = api_ensure_session(sess);
            string fixed = msg;
            if (sess_ok != sess){
                fixed = jset(fixed, ["session"], sess_ok);
            }
            fixed = jset(fixed, ["to"], "ui_frontend");
            if (DEBUG) logd("EVT ui_render ui_backend→ui_frontend (sid="+sess_ok+")");
            route_to(L_UI_FE_IN, fixed, id);
            return;
        }

        if (ty == "ui_close"){
            string fixed = jset(msg, ["to"], "ui_frontend");
            if (DEBUG) logd("EVT ui_close → ui_frontend");
            route_to(L_UI_FE_IN, fixed, id);
            return;
        }

        // ---------- Broadcast helpers ----------
        if (ty == "ui_touched" || ty == "ui_button"){
            string b = jset(msg, ["to"], "any");
            if (DEBUG) logd("EVT " + ty + " → any");
            route_to(L_BROADCAST, b, id);
            return;
        }

        // ---------- Targeted delivery by 'to' (module registry) ----------
        if (to != JSON_INVALID && to != "" && to != "any" && to != "ui_backend" && to != "ui_frontend"){
            integer lane = reg_lane(to);
            if (lane != 0){
                if (DEBUG) logd("ROUTE " + ty + " " + from + "→" + to + " (lane "+(string)lane+")");
                route_to(lane, msg, id);
                return;
            }
            // Unknown module: fall through to pass-through on L_API
            if (DEBUG) logd("PASS " + ty + " to="+to+" (no lane; re-emit on L_API)");
            string pass = jset(msg, ["_api_p"], "1"); // mark as passed once
            route_to(L_API, pass, id);
            return;
        }

        // ---------- Untargeted / empty 'to' ----------
        // Re-emit on L_API so generic listeners can pick it up.
        if (DEBUG) logd("PASS " + ty + " (no/empty 'to'; re-emit on L_API)");
        string pass2 = jset(msg, ["_api_p"], "1");
        route_to(L_API, pass2, id);
        return;
    }
}
