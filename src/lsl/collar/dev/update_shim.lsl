/*--------------------
SCRIPT: update_shim.lsl
VERSION: 1.10
REVISION: 1
PURPOSE: Transient payload deposited into the collar by updater_driver via
  llRemoteLoadScriptPin. Runs inside the collar, negotiates per-script
  install/skip/delete with updater_bundler over the start_param channel,
  then self-deletes on DONE or inactivity timeout.
ARCHITECTURE: No link_message interaction with the rest of the collar.
  Orphaned plugin.reg.<ctx> / acl.policycontext:<ctx> entries left by
  removed scripts are swept by collar_kernel's prune_missing_scripts on
  its next inventory tick — the shim does not clean up LSD itself.
  "Kamikaze" pattern from OpenCollar's oc_update_shim.
CHANGES:
- v1.1 rev 1: Hold @detach=n while the shim is resident if the collar was
  locked at update start. Keyed to the shim's script UUID so it drops
  automatically on self-delete; bridges the ~3s window during plugin_lock
  replacement when the old plugin_lock's @detach=n is already gone and the
  new one hasn't arrived yet. Wearer can't yank a locked collar mid-update.
- v1.1 rev 0: Initial implementation.
--------------------*/


/* -------------------- CONSTANTS -------------------- */
// Dormancy marker set on the installer's bundler prim. Any collar script
// that auto-starts there reads the description and parks itself.
string UPDATER_MARKER = "COLLAR_UPDATER";

// Inactivity window. If no message arrives from the bundler for this many
// seconds, assume the update died and clean up. 120s comfortably covers
// the 3s per-script throttle of llRemoteLoadScriptPin across a ~30 script
// package, with slack.
float INACTIVITY_TIMEOUT = 120.0;


/* -------------------- STATE -------------------- */
integer SecureChannel = 0;
integer ListenHandle = 0;


/* -------------------- PROTOCOL -------------------- */
// Installer → shim: "QUERY|SCRIPT|<name>|<uuid>|<mode>"   mode: REQUIRED|DEPRECATED
// Installer → shim: "DONE"
// Shim → installer: "READY"                               (shim is listening)
// Shim → installer: "REPLY|<name>|<verdict>"              verdict: GIVE|SKIP|OK


/* -------------------- HELPERS -------------------- */

reply(string target_name, string verdict) {
    llWhisper(SecureChannel, "REPLY|" + target_name + "|" + verdict);
}

// Handle a single QUERY line from the bundler. Mutates local inventory
// when a stale script needs to be removed or a deprecated item is present.
handle_query(string target_name, key target_uuid, string mode) {
    if (mode == "DEPRECATED") {
        if (llGetInventoryType(target_name) != INVENTORY_NONE) {
            llRemoveInventory(target_name);
        }
        reply(target_name, "OK");
        return;
    }

    // REQUIRED mode. Script-only for v1.
    if (llGetInventoryType(target_name) == INVENTORY_NONE) {
        reply(target_name, "GIVE");
        return;
    }

    // Present — compare asset UUID. A mismatched UUID means a stale version
    // that must be deleted before llRemoteLoadScriptPin can deposit the new
    // one. (Platform does silently-replace on same-name, but deleting first
    // keeps the UUID comparison honest on the next update pass.)
    key local_uuid = llGetInventoryKey(target_name);
    if (local_uuid == target_uuid && target_uuid != NULL_KEY) {
        reply(target_name, "SKIP");
        return;
    }

    llRemoveInventory(target_name);
    reply(target_name, "GIVE");
}

cleanup_and_die() {
    if (ListenHandle) llListenRemove(ListenHandle);
    ListenHandle = 0;
    llSetTimerEvent(0.0);
    // Disarm the PIN so the collar stops accepting remote loads once the
    // update session is closed.
    llSetRemoteScriptAccessPin(0);
    llRemoveInventory(llGetScriptName());
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Dormancy guard — if this script got dragged into the updater
        // prim's inventory during packaging, state_entry parks it so it
        // doesn't try to run update logic in the wrong context.
        if (llGetObjectDesc() == UPDATER_MARKER) {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        SecureChannel = llGetStartParameter();
        if (SecureChannel == 0) {
            // No session channel passed — this script was placed without
            // going through the proper llRemoteLoadScriptPin path. Remove
            // ourselves to avoid leaving a dormant payload in inventory.
            llRemoveInventory(llGetScriptName());
            return;
        }

        // If the collar was locked when the update started, hold @detach=n
        // ourselves for the duration. When plugin_lock is replaced later in
        // the bundle, the old script's @detach=n drops the moment it's
        // removed from inventory; the new plugin_lock's @detach=n doesn't
        // land until its state_entry runs. Our independent hold (keyed to
        // the shim's script UUID) keeps the collar worn across that gap.
        // Auto-drops when the shim self-deletes, by which time the new
        // plugin_lock has re-issued its own @detach=n if appropriate.
        if (llLinksetDataRead("lock.locked") == "1") {
            llOwnerSay("@detach=n");
        }

        // Open a listen scoped to the secure channel. Same-owner filtering
        // happens in the listen handler (the bundler's key is not known in
        // advance — we only know it must share the wearer's owner UUID,
        // which is the llRemoteLoadScriptPin precondition anyway).
        ListenHandle = llListen(SecureChannel, "", "", "");

        // Arm the inactivity watchdog.
        llSetTimerEvent(INACTIVITY_TIMEOUT);

        // Signal to the bundler that we are listening and ready to answer
        // queries.
        llWhisper(SecureChannel, "READY");
    }

    listen(integer channel, string name, key id, string message) {
        if (channel != SecureChannel) return;
        if (llGetOwnerKey(id) != llGetOwner()) return;

        // Any activity resets the inactivity watchdog.
        llSetTimerEvent(INACTIVITY_TIMEOUT);

        list parts = llParseString2List(message, ["|"], []);
        string verb = llList2String(parts, 0);

        if (verb == "DONE") {
            cleanup_and_die();
            return;
        }

        if (verb == "QUERY") {
            // QUERY|SCRIPT|<name>|<uuid>|<mode>
            if (llGetListLength(parts) < 5) return;
            string target_type = llList2String(parts, 1);
            if (target_type != "SCRIPT") return;  // v1: scripts only
            string target_name = llList2String(parts, 2);
            key target_uuid = (key)llList2String(parts, 3);
            string mode = llList2String(parts, 4);
            handle_query(target_name, target_uuid, mode);
            return;
        }
    }

    timer() {
        // Inactivity watchdog: bundler has gone silent. Disarm, self-delete,
        // leave the collar in whatever half-state the update reached — the
        // wearer can reattach the installer to retry.
        cleanup_and_die();
    }

    changed(integer change) {
        // If the collar changes ownership or is unlinked mid-update, abort
        // cleanly rather than continuing against a shifted target.
        if (change & (CHANGED_OWNER | CHANGED_LINK)) {
            cleanup_and_die();
        }
    }
}
