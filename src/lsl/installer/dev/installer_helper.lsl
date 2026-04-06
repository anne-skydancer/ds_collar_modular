/*--------------------
SCRIPT: installer_helper.lsl
VERSION: 1.10
REVISION: 0
PURPOSE: Bootstrap helper for DS Collar installation — negotiates remote
         script access PIN with the installer, activates transferred scripts,
         then self-destructs. Transferred to the target object first via
         llGiveInventory; all subsequent scripts arrive via llRemoteLoadScriptPin.
ARCHITECTURE: Region say handshake with collar_installer.lsl on owner-derived channel
CHANGES:
- Initial implementation: PIN negotiation, script activation, self-removal
KNOWN ISSUES: None
TODO: None
--------------------*/

integer CommChannel = 0;
integer ListenHandle = 0;
integer Pin = 0;

integer derive_channel(key avatar) {
    integer ch = (integer)("0x" + llGetSubString((string)avatar, 0, 7));
    if (ch > 0) ch = ch * -1;
    if (ch == 0) ch = -1;
    return ch;
}

activate_all_scripts() {
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    string my_name = llGetScriptName();
    integer i;
    for (i = 0; i < count; i++) {
        string script_name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (script_name != my_name) {
            llSetScriptState(script_name, TRUE);
            llResetOtherScript(script_name);
        }
    }
}

default {
    state_entry() {
        CommChannel = derive_channel(llGetOwner());

        // Generate a random 6-digit PIN for remote script loading
        Pin = (integer)llFrand(899999.0) + 100001;
        llSetRemoteScriptAccessPin(Pin);

        // Listen for commands from installer
        ListenHandle = llListen(CommChannel, "", NULL_KEY, "");

        // Send ready handshake with PIN (point-to-point where possible)
        llRegionSay(CommChannel, llList2Json(JSON_OBJECT, [
            "type", "helper_ready",
            "pin", (string)Pin,
            "target", (string)llGetKey()
        ]));

        // Safety timeout — self-destruct if installation never completes
        llSetTimerEvent(180.0);
    }

    listen(integer channel, string name, key id, string message) {
        if (channel != CommChannel) return;

        // Only accept messages from objects owned by the same avatar
        list details = llGetObjectDetails(id, [OBJECT_OWNER]);
        if (llList2Key(details, 0) != llGetOwner()) return;

        string msg_type = llJsonGetValue(message, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (msg_type == "activate") {
            if (ListenHandle) {
                llListenRemove(ListenHandle);
                ListenHandle = 0;
            }
            llSetTimerEvent(0.0);

            // Activate every script except ourselves
            activate_all_scripts();

            // Clear the PIN so no further scripts can be injected
            llSetRemoteScriptAccessPin(0);

            // Notify installer of completion
            llRegionSay(CommChannel, llList2Json(JSON_OBJECT, [
                "type", "install_complete"
            ]));

            llOwnerSay("DS Collar installation complete. All scripts activated.");

            // Self-destruct
            llRemoveInventory(llGetScriptName());
            return;
        }

        if (msg_type == "abort") {
            llSetRemoteScriptAccessPin(0);
            llSetTimerEvent(0.0);
            if (ListenHandle) {
                llListenRemove(ListenHandle);
                ListenHandle = 0;
            }
            llOwnerSay("Installation aborted. Removing helper.");
            llRemoveInventory(llGetScriptName());
            return;
        }
    }

    timer() {
        // Safety timeout — clean up and self-destruct
        llSetTimerEvent(0.0);
        llSetRemoteScriptAccessPin(0);
        if (ListenHandle) {
            llListenRemove(ListenHandle);
            ListenHandle = 0;
        }
        llOwnerSay("Installer helper timed out. Removing self.");
        llRemoveInventory(llGetScriptName());
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llSetRemoteScriptAccessPin(0);
            if (ListenHandle) {
                llListenRemove(ListenHandle);
                ListenHandle = 0;
            }
            llRemoveInventory(llGetScriptName());
        }
    }
}
