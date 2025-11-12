/*--------------------
SCRIPT: ds_collar_leash_holder.lsl
VERSION: 1.00
REVISION: 1
PURPOSE: Minimal leash-holder target responder for external objects
ARCHITECTURE: Direct channel listener with prim discovery fallback
CHANGES:
- Auto-detect leash point prim by name "LeashPoint" or description "leash:point"
- Fall back to script's own prim if no dedicated leash point found
- Compatible with ds_collar_plugin_leash.lsl leash targeting system
KNOWN ISSUES: None known
TODO: None pending
--------------------*/

/* -------------------- CONSTANTS -------------------- */
integer DEBUG = TRUE;
string SCRIPT_ID = "leash_holder";
integer LEASH_HOLDER_CHAN = -192837465;

/* -------------------- STATE -------------------- */
integer gListen = 0;

/* -------------------- HELPERS -------------------- */
integer logd(string s) { if (DEBUG) llOwnerSay("[HOLDER] " + s); return TRUE; }

key primByName(string wantLower) {
    integer n = llGetNumberOfPrims();
    integer i = 2;
    while (i <= n) {
        string nm = llToLower(llGetLinkName(i));
        if (nm == wantLower) return llGetLinkKey(i);
        i = i + 1;
    }
    return NULL_KEY;
}

key primByDesc(string wantLower) {
    integer n = llGetNumberOfPrims();
    integer i = 2;
    while (i <= n) {
        string d = llToLower(llList2String(llGetLinkPrimitiveParams(i, [PRIM_DESC]), 0));
        if (d == wantLower) return llGetLinkKey(i);
        i = i + 1;
    }
    return NULL_KEY;
}

// Choose a leash point prim:
// 1) child named "LeashPoint" (case-insensitive)
// 2) child with description "leash:point" (case-insensitive)
// 3) the prim this script is in (child or root)
key leashPrimKey() {
    key k = primByName("leashpoint");
    if (k != NULL_KEY) return k;

    k = primByDesc("leash:point");
    if (k != NULL_KEY) return k;

    integer ln = llGetLinkNumber();
    if (ln <= 0) ln = 1; // attachments can report 0; root is 1
    return llGetLinkKey(ln);
}

integer openListen() {
    if (gListen) llListenRemove(gListen);
    gListen = llListen(LEASH_HOLDER_CHAN, "", NULL_KEY, "");
    return TRUE;
}

/* -------------------- MESSAGE ROUTING -------------------- */

integer is_message_for_me(string msg) {
    if (llGetSubString(msg, 0, 0) != "{") return FALSE;
    integer to_pos = llSubStringIndex(msg, "\"to\"");
    if (to_pos == -1) return TRUE;
    string header = llGetSubString(msg, 0, to_pos + 100);
    if (llSubStringIndex(header, "\"*\"") != -1) return TRUE;
    if (llSubStringIndex(header, SCRIPT_ID) != -1) return TRUE;
    return FALSE;
}

string create_routed_message(string to_id, list fields) {
    list routed = ["from", SCRIPT_ID, "to", to_id] + fields;
    return llList2Json(JSON_OBJECT, routed);
}

string create_broadcast(list fields) {
    return create_routed_message("*", fields);
}

default {
    state_entry() {
        openListen();
        logd("listening on " + (string)LEASH_HOLDER_CHAN);
    }

    on_rez(integer p) {
        llResetScript();
    }

    changed(integer c) {
        if (c & (CHANGED_OWNER | CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
            openListen();
        }
    }

    // Optional: quick debug — touch to print chosen prim key
    touch_start(integer n) {
        if (!DEBUG) return;
        key k = leashPrimKey();
        llOwnerSay("LeashPoint = " + (string)k);
    }

    listen(integer ch, string name, key src, string msg) {
        if (ch != LEASH_HOLDER_CHAN) return;

        // Expect JSON: {"type":"leash_req","wearer":"...","collar":"...","session":"..."}
        if (llJsonGetValue(msg, ["type"]) != "leash_req") return;

        key collar = (key)llJsonGetValue(msg, ["collar"]);
        integer session = (integer)llJsonGetValue(msg, ["session"]);

        key targetPrim = leashPrimKey();

        string reply = llList2Json(JSON_OBJECT, []);
        reply = llJsonSetValue(reply, ["type"],    "leash_target");
        reply = llJsonSetValue(reply, ["ok"],      "1");
        reply = llJsonSetValue(reply, ["holder"],  (string)targetPrim);
        reply = llJsonSetValue(reply, ["name"],    llGetObjectName());
        reply = llJsonSetValue(reply, ["session"], (string)session);

        llRegionSayTo(collar, LEASH_HOLDER_CHAN, reply);
        logd("sent target " + (string)targetPrim + " → " + (string)collar + " (sess " + (string)session + ")");
    }
}
