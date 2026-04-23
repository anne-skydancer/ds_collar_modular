/*--------------------
SCRIPT: updater_driver.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Installer-side orchestrator. Wearer touches the installer prim;
  driver broadcasts remote.updatediscover on kmod_remote's well-known
  external channel, receives the collar's PIN + session via remote.collarready,
  deposits update_shim via llRemoteLoadScriptPin, then dispatches each
  bundle notecard to updater_bundler (child prim) until all are applied.
ARCHITECTURE: Lives in the installer linkset root. Sibling updater_bundler
  runs in a child prim and holds the staged collar scripts. Chat protocol
  with collar uses kmod_remote's EXTERNAL_ACL_QUERY_CHAN / REPLY_CHAN; chat
  protocol with shim uses a random per-session secure channel passed as
  llRemoteLoadScriptPin's start_param.
CHANGES:
- v1.1 rev 0: Initial implementation. Single-bundle dispatch for now; the
  bundler-side loop supports multiple bundle notecards via link_message
  iteration but this v1 driver only enumerates one REQUIRED bundle.
--------------------*/


/* -------------------- EXTERNAL PROTOCOL CHANNELS -------------------- */
// Must match kmod_remote's EXTERNAL_ACL_QUERY_CHAN / EXTERNAL_ACL_REPLY_CHAN.
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;


/* -------------------- LINK-MESSAGE NUMBERS -------------------- */
// Driver → bundler: begin processing a bundle notecard.
integer LM_BUNDLE_BEGIN = 91001;
// Bundler → driver: bundle complete (success or exhausted).
integer LM_BUNDLE_DONE  = 91002;


/* -------------------- CONSTANTS -------------------- */
// Object description marker. Every collar script's dormancy guard checks
// for this and parks itself if found — that's how dragged-in scripts stay
// off in the installer's inventory until they're shipped to the collar.
string UPDATER_MARKER = "COLLAR_UPDATER";

// Version this installer ships. Shown to the wearer at completion; may be
// displayed on floating text in a future revision.
string BUILD_VERSION = "1.1";

// Name of the payload script to deposit into the collar. Must exist in
// THIS prim's inventory so llRemoteLoadScriptPin can find it.
string SHIM_SCRIPT = "update_shim";

// Bundle notecards we iterate through. Naming mirrors OpenCollar's
// BUNDLE_##_MODE pattern; ## gives ordering, MODE is REQUIRED / DEPRECATED.
// Order in this list is the execution order.
list Bundles = [
    "BUNDLE_01_REQUIRED",
    "BUNDLE_99_DEPRECATED"
];

// Timeouts.
float DISCOVERY_TIMEOUT = 10.0;   // wait for remote.collarready
float SHIM_READY_TIMEOUT = 15.0;  // wait for READY from shim after load
float BUNDLE_TIMEOUT = 180.0;     // wait for each bundle to complete


/* -------------------- STATE -------------------- */
// Phase names reflect what we're currently waiting on.
string Phase = "idle";   // idle | discovering | shim_loading | bundling | done

key CollarKey = NULL_KEY;
integer CollarPin = 0;
string  Session = "";
integer SecureChannel = 0;

integer ReplyListen = 0;   // listen on EXTERNAL_ACL_REPLY_CHAN
integer SecureListen = 0;  // listen on SecureChannel

integer BundleIdx = 0;

key Wearer = NULL_KEY;   // who rezzed / touched


/* -------------------- HELPERS -------------------- */

string new_session() {
    return "upd_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

integer random_channel() {
    // Random negative non-zero 31-bit int. Passed to shim via start_param
    // so both ends know where to talk.
    integer n = -((integer)llFrand(2147483600.0) + 1);
    return n;
}

cleanup_listens() {
    if (ReplyListen) llListenRemove(ReplyListen);
    if (SecureListen) llListenRemove(SecureListen);
    ReplyListen = 0;
    SecureListen = 0;
}

cleanup_all() {
    cleanup_listens();
    llSetTimerEvent(0.0);
    Phase = "idle";
    CollarKey = NULL_KEY;
    CollarPin = 0;
    Session = "";
    SecureChannel = 0;
    BundleIdx = 0;
    Wearer = NULL_KEY;
}

notice(string s) {
    if (Wearer != NULL_KEY) llRegionSayTo(Wearer, 0, s);
    else llOwnerSay(s);
}


/* -------------------- DISCOVERY -------------------- */

begin_discovery(key toucher) {
    if (Phase != "idle") {
        notice("An update is already in progress.");
        return;
    }

    Wearer = toucher;
    Phase = "discovering";
    Session = new_session();
    BundleIdx = 0;

    cleanup_listens();
    ReplyListen = llListen(EXTERNAL_ACL_REPLY_CHAN, "", "", "");

    string msg = llList2Json(JSON_OBJECT, [
        "type",    "remote.updatediscover",
        "updater", (string)llGetKey(),
        "session", Session
    ]);
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);

    llSetTimerEvent(DISCOVERY_TIMEOUT);
    notice("Searching for collar...");
}

handle_collar_ready(string msg) {
    // Session must match — ignore any stray collarready from another update
    // attempt in the same sim.
    string sess = llJsonGetValue(msg, ["session"]);
    if (sess == JSON_INVALID) return;
    if (sess != Session) return;

    if (llJsonGetValue(msg, ["collar"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["pin"]) == JSON_INVALID) return;

    CollarKey = (key)llJsonGetValue(msg, ["collar"]);
    CollarPin = (integer)llJsonGetValue(msg, ["pin"]);

    // Reject if the collar isn't owned by the same avatar as this installer.
    // llRemoteLoadScriptPin enforces this too, but catching it here gives a
    // cleaner error message than a silent platform-level failure.
    if (llGetOwnerKey(CollarKey) != llGetOwner()) {
        notice("Collar is owned by a different avatar. Aborting.");
        cleanup_all();
        return;
    }

    load_shim();
}

load_shim() {
    if (llGetInventoryType(SHIM_SCRIPT) != INVENTORY_SCRIPT) {
        notice("Installer is missing " + SHIM_SCRIPT + "; cannot proceed.");
        cleanup_all();
        return;
    }

    Phase = "shim_loading";
    SecureChannel = random_channel();

    // Start listening on the secure channel BEFORE we send the shim so we
    // don't miss its READY whisper.
    SecureListen = llListen(SecureChannel, "", CollarKey, "");

    // This call sleeps 3s. The shim arrives in the collar, starts running
    // (running=TRUE), reads start_param, and whispers READY on SecureChannel.
    llRemoteLoadScriptPin(CollarKey, SHIM_SCRIPT, CollarPin, TRUE, SecureChannel);

    llSetTimerEvent(SHIM_READY_TIMEOUT);
    notice("Installing update shim...");
}


/* -------------------- BUNDLE DISPATCH -------------------- */

dispatch_next_bundle() {
    if (BundleIdx >= llGetListLength(Bundles)) {
        // All bundles applied. Tell the shim we're done.
        llWhisper(SecureChannel, "DONE");
        Phase = "done";
        llSetTimerEvent(0.0);
        notice("Update complete. Collar is now at version " + BUILD_VERSION + ".");
        // Give the shim a moment to self-delete and the collar to stabilise.
        llSleep(2.0);
        cleanup_all();
        return;
    }

    string bundle_name = llList2String(Bundles, BundleIdx);
    // Skip missing bundles (DEPRECATED card might not exist on first release).
    if (llGetInventoryType(bundle_name) != INVENTORY_NOTECARD) {
        BundleIdx += 1;
        dispatch_next_bundle();
        return;
    }

    Phase = "bundling";
    llSetTimerEvent(BUNDLE_TIMEOUT);

    string payload = llList2Json(JSON_OBJECT, [
        "bundle",     bundle_name,
        "collar",     (string)CollarKey,
        "pin",        (string)CollarPin,
        "channel",    (string)SecureChannel
    ]);
    llMessageLinked(LINK_SET, LM_BUNDLE_BEGIN, payload, NULL_KEY);
    notice("Applying " + bundle_name + "...");
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Stamp the prim description so every dragged-in collar script's
        // dormancy guard parks it. Every prim in the installer linkset that
        // holds stagable scripts should carry this marker.
        llSetObjectDesc(UPDATER_MARKER);
        cleanup_all();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    touch_start(integer num) {
        key toucher = llDetectedKey(0);
        if (toucher != llGetOwner()) {
            llRegionSayTo(toucher, 0, "Only the owner can run this installer.");
            return;
        }
        begin_discovery(toucher);
    }

    listen(integer channel, string name, key id, string message) {
        if (channel == EXTERNAL_ACL_REPLY_CHAN) {
            // Same-owner filter — kmod_remote is the only legitimate sender.
            if (llGetOwnerKey(id) != llGetOwner()) return;
            if (Phase != "discovering") return;

            string mtype = llJsonGetValue(message, ["type"]);
            if (mtype != "remote.collarready") return;
            handle_collar_ready(message);
            return;
        }

        if (channel == SecureChannel) {
            if (id != CollarKey) return;
            if (message == "READY") {
                if (Phase != "shim_loading") return;
                // Shim is listening. Start the first bundle.
                BundleIdx = 0;
                dispatch_next_bundle();
            }
            return;
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num != LM_BUNDLE_DONE) return;
        if (Phase != "bundling") return;
        BundleIdx += 1;
        dispatch_next_bundle();
    }

    timer() {
        llSetTimerEvent(0.0);
        if (Phase == "discovering") {
            notice("No collar responded. Make sure your collar is worn and you are within 20 meters.");
            cleanup_all();
            return;
        }
        if (Phase == "shim_loading") {
            notice("Shim did not start. The collar may be busy or blocked.");
            cleanup_all();
            return;
        }
        if (Phase == "bundling") {
            notice("Update stalled during bundle dispatch. Collar is in an indeterminate state; reattach the installer to retry.");
            cleanup_all();
            return;
        }
    }
}
