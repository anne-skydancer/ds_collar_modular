/* ===============================================================
   LEASH HOLDER: ds_collar_leash_holder.lsl (v1.0 - Lockmeister)

   PURPOSE: Minimal leash-holder target responder
            Works with ds_collar_plugin_leash.lsl (LEASH_HOLDER_CHAN must match)
   =============================================================== */

integer DEBUG = FALSE;
integer LEASH_HOLDER_CHAN = -192837465;

integer GListen = 0;

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
    if (GListen) llListenRemove(GListen);
    GListen = llListen(LEASH_HOLDER_CHAN, "", NULL_KEY, "");
    return TRUE;
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

    // Optional: quick debug  --  touch to print chosen prim key
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
        logd("sent target " + (string)targetPrim + " to " + (string)collar + " (sess " + (string)session + ")");
    }
}
