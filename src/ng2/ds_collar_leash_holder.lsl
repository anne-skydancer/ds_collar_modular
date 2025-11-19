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
integer LEASH_HOLDER_CHAN = -192837465;

/* -------------------- STATE -------------------- */
integer gListen = 0;

/* -------------------- HELPERS -------------------- */

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

default {
    state_entry() {
        openListen();
    }

    on_rez(integer p) {
        llResetScript();
    }

    changed(integer c) {
        if (c & (CHANGED_OWNER | CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
            openListen();
        }
    }

    listen(integer ch, string name, key src, string msg) {
        if (ch != LEASH_HOLDER_CHAN) return;

        // Expect JSON: {"type":"leash_req","wearer":"...","collar":"...","session":"..."}
        if (llJsonGetValue(msg, ["type"]) != "leash_req") return;

        key collar = (key)llJsonGetValue(msg, ["collar"]);
        integer session = (integer)llJsonGetValue(msg, ["session"]);

        key targetPrim = leashPrimKey();

        string reply = llList2Json(JSON_OBJECT, [
            "type", "leash_target",
            "ok", "1",
            "holder", (string)targetPrim,
            "name", llGetObjectName(),
            "session", (string)session
        ]);

        llRegionSayTo(collar, LEASH_HOLDER_CHAN, reply);
    }
}
