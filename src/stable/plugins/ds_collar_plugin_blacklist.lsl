// =============================================================
//  PLUGIN: ds_collar_plugin_blacklist.lsl (Canonical protocol, Animate-style UI)
//  PURPOSE: Blacklist menu for DS Collar, strict UI conformity
//  DATE:    2025-08-01
// =============================================================

integer DEBUG = TRUE;

integer PLUGIN_SN         = 0;
string  PLUGIN_LABEL      = "Blacklist";
integer PLUGIN_MIN_ACL    = 3;
string  PLUGIN_CONTEXT    = "core_blacklist";
string  ROOT_CONTEXT      = "core_root";

// --- Canonical Protocol Constants ---
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";

// --- Protocol channels ---
integer PLUGIN_REG_QUERY_NUM = 500;
integer PLUGIN_REG_REPLY_NUM = 501;
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;
integer UI_SHOW_MENU_NUM     = 601;

// --- Session Management (Animate-style) ---
list    Sessions;
float   BlacklistRadius   = 5.0; // meters, parametric

// Blacklist state
list    Blacklist;         // [key, key, ...]
list    CandidateKeys;    // For add menu context

// --- Session helpers ---
// Returns the index of the avatar's session block or -1 if none exists.
integer s_idx(key av) { return llListFindList(Sessions, [av]); }
// Stores session metadata for the avatar, replacing any existing session and wiring the listen.
integer s_set(key av, integer page, string csv, float expiry, string ctx, string param, string step, string menucsv, integer chan)
{ 
    integer i = s_idx(av);
    if (~i) {
        integer old = llList2Integer(Sessions, i+9);
        if (old != -1) llListenRemove(old);
        Sessions = llDeleteSubList(Sessions, i, i+9);
    }
    integer lh = llListen(chan, "", av, "");
    Sessions += [av, page, csv, expiry, ctx, param, step, menucsv, chan, lh];
    return TRUE;
}
// Removes a tracked session for the avatar and closes its listen handle.
integer s_clear(key av)
{ 
    integer i = s_idx(av);
    if (~i) {
        integer old = llList2Integer(Sessions, i+9);
        if (old != -1) llListenRemove(old);
        Sessions = llDeleteSubList(Sessions, i, i+9);
    }
    return TRUE;
}
// Retrieves the stored session tuple for the avatar.
list s_get(key av)
{ 
    integer i = s_idx(av);
    if (~i) return llList2List(Sessions, i, i+9);
    return [];
}

// --- Helper: Update and sort name list for display ---
// Resolves blacklist keys to display names for menu output.
list get_blacklist_names() {
    list out = [];
    integer i;
    for (i = 0; i < llGetListLength(Blacklist); ++i)
        out += [llKey2Name(llList2Key(Blacklist, i))];
    return out;
}

// --- Main Menus ---

// Presents the root blacklist menu to the user with add/remove options.
show_blacklist_menu(key user)
{ 
    list names = get_blacklist_names();
    string msg = "Blacklisted users:\n";
    integer i;
    if (llGetListLength(names) == 0)
        msg += "  (none)\n";
    else
        for (i = 0; i < llGetListLength(names); ++i)
            msg += "  " + llList2String(names, i) + "\n";

    // Animate-style: always ["~", "Back", "~", ...]
    list btns = ["~", "Back", "~", "Add", "Remove"];
    while (llGetListLength(btns) % 3 != 0) btns += " ";

    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, "main", "", "", "", menu_chan);

    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[BLACKLIST] Main menu → " + (string)user + " chan=" + (string)menu_chan);
}

// Builds a numbered dialog for removing an avatar from the blacklist.
show_remove_menu(key user)
{ 
    list names = get_blacklist_names();
    if (llGetListLength(Blacklist) == 0) {
        show_blacklist_menu(user);
        return;
    }
    string msg = "Select avatar to remove:\n";
    list btns = ["~", "Back", "~"];
    integer i;
    for (i = 0; i < llGetListLength(names); ++i) {
        msg += (string)(i+1) + ". " + llList2String(names, i) + "\n";
        btns += [(string)(i+1)];
    }
    while (llGetListLength(btns) % 3 != 0) btns += " ";

    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, 0, "", llGetUnixTime() + 180.0, "remove", "", "", "", menu_chan);

    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[BLACKLIST] Remove menu → " + (string)user + " chan=" + (string)menu_chan);
}

// Offers a numbered dialog of nearby avatars to add to the blacklist.
show_add_candidates(key user, list candidates)
{ 
    if (llGetListLength(candidates) == 0) {
        list btns = ["~", "Back", "~"];
        integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
        s_set(user, 0, "", llGetUnixTime() + 180.0, "error", "", "", "", menu_chan);
        llDialog(user, "No avatars nearby to blacklist.", btns, menu_chan);
        if (DEBUG) llOwnerSay("[BLACKLIST] Error dialog → " + (string)user + " (no avatars, chan=" + (string)menu_chan + ")");
        return;
    }
    string msg = "Select avatar to blacklist:\n";
    list btns = ["~", "Back", "~"];
    integer i;
    for (i = 0; i < llGetListLength(candidates); ++i) {
        msg += (string)(i+1) + ". " + llKey2Name(llList2Key(candidates, i)) + "\n";
        btns += [(string)(i+1)];
    }
    while (llGetListLength(btns) % 3 != 0) btns += " ";

    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    CandidateKeys = candidates;
    s_set(user, 0, "", llGetUnixTime() + 180.0, "add_pick", "", "", "", menu_chan);

    llDialog(user, msg, btns, menu_chan);
    if (DEBUG) llOwnerSay("[BLACKLIST] Add menu → " + (string)user + " chan=" + (string)menu_chan);
}

// --- State Sync ---
// Broadcasts the legacy state_sync payload for downstream consumers.
send_state_sync()
{ 
    string bl_csv = llDumpList2String(Blacklist, ",");
    // Send only via legacy channel 520 for now (settings module will soon replace this)
    llMessageLinked(LINK_SET, 520, "state_sync|||||" + bl_csv + "||", NULL_KEY);
    if (DEBUG) llOwnerSay("[BLACKLIST] Sent state_sync: " + bl_csv);
}

// --- MAIN EVENT LOOP ---
default
{
    // Registers with the kernel and requests initial settings on load.
    state_entry()
    {
        PLUGIN_SN = (integer)(llFrand(1.0e5));
        string reg_msg = REGISTER_MSG_START + "|" + (string)PLUGIN_SN + "|" + PLUGIN_LABEL + "|"
                        + (string)PLUGIN_MIN_ACL + "|" + PLUGIN_CONTEXT + "|" + llGetScriptName();
        llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg_msg, NULL_KEY);

        llMessageLinked(LINK_SET, SETTINGS_QUERY_NUM, "get_settings", NULL_KEY);

        if (DEBUG) llOwnerSay("[BLACKLIST] Ready, SN=" + (string)PLUGIN_SN);
    }

    // Handles registration pings, settings/state sync, and menu open requests.
    link_message(integer sender, integer num, string str, key id)
    {
        if ((num == PLUGIN_REG_QUERY_NUM) && llSubStringIndex(str, REGISTER_NOW_MSG_START + "|") == 0)
        {
            string script_req = llGetSubString(str, llStringLength(REGISTER_NOW_MSG_START) + 1, -1);
            if (script_req == llGetScriptName())
            {
                string reg_msg = REGISTER_MSG_START + "|" + (string)PLUGIN_SN + "|" + PLUGIN_LABEL + "|"
                                + (string)PLUGIN_MIN_ACL + "|" + PLUGIN_CONTEXT + "|" + llGetScriptName();
                llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg_msg, NULL_KEY);
                if (DEBUG) llOwnerSay("[BLACKLIST] Registration reply sent.");
            }
            return;
        }

        // State sync from core/settings module (legacy channel 520)
        if (num == 520 && llSubStringIndex(str, "state_sync|") == 0) {
            list parts = llParseString2List(str, ["|"], []);
            if (llGetListLength(parts) >= 6) {
                string bl_csv = llList2String(parts, 5);
                if (bl_csv == "" || bl_csv == " ")
                    Blacklist = [];
                else
                    Blacklist = llParseString2List(bl_csv, [","], []);
                if (DEBUG) llOwnerSay("[BLACKLIST] State sync updated: " + bl_csv);
            }
            return;
        }

        // Settings sync from settings module (CHANNEL 870)
        if (num == SETTINGS_SYNC_NUM) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llList2String(parts, 0) == SETTINGS_SYNC_MSG_START) {
                // Look for blacklist= in the key-value pairs
                integer k;
                for (k = 1; k < llGetListLength(parts); ++k) {
                    string kv = llList2String(parts, k);
                    integer eq = llSubStringIndex(kv, "=");
                    if (eq != -1) {
                        string av_key = llGetSubString(kv, 0, eq-1);
                        string val = llGetSubString(kv, eq+1, -1);
                        if (av_key == "blacklist") {
                            if (val == "" || val == " ")
                                Blacklist = [];
                            else
                                Blacklist = llParseString2List(val, [","], []);
                            if (DEBUG) llOwnerSay("[BLACKLIST] Blacklist sync from settings: " + val);
                        }
                    }
                }
            }
            return;
        }

        // Show menu request from UI
        if ((num == UI_SHOW_MENU_NUM)) {
            list parts = llParseStringKeepNulls(str, ["|"], []);
            if (llGetListLength(parts) >= 3) {
                string ctx = llList2String(parts, 1);
                key user = (key)llList2String(parts, 2);
                if (ctx == PLUGIN_CONTEXT) {
                    show_blacklist_menu(user);
                    return;
                }
            }
        }
    }

    // Routes dialog responses according to the caller's active session context.
    listen(integer chan, string name, key id, string msg)
    {
        list sess = s_get(id);
        if (llGetListLength(sess) == 10 && chan == llList2Integer(sess, 8))
        {
            string ctx = llList2String(sess, 4);

            // Animate-style: Back always routes to ROOT
            if (msg == "Back") {
                string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)id + "|0";
                llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
                s_clear(id);
                return;
            }

            // Add or Remove buttons (main menu)
            if (ctx == "main") {
                if (msg == "Add") {
                    llSensor("", NULL_KEY, AGENT, BlacklistRadius, PI);
                    return;
                }
                if (msg == "Remove") {
                    show_remove_menu(id);
                    return;
                }
            }
            // Remove numbered button (ctx "remove")
            else if (ctx == "remove") {
                integer idx = (integer)msg - 1; // Buttons are labeled "1", "2", ...
                if (idx >= 0 && idx < llGetListLength(Blacklist)) {
                    Blacklist = llDeleteSubList(Blacklist, idx, idx);
                    send_state_sync();
                }
                show_blacklist_menu(id);
                s_clear(id);
                return;
            }
            // Add_pick numbered button
            else if (ctx == "add_pick") {
                integer idx = (integer)msg - 1;
                if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
                    key k = llList2Key(CandidateKeys, idx);
                    if (llListFindList(Blacklist, [k]) == -1) {
                        Blacklist += [k];
                        send_state_sync();
                    }
                }
                show_blacklist_menu(id);
                s_clear(id);
                return;
            }
        }
    }

    // Collects sensor hits to build the add-blacklist candidate list.
    sensor(integer num_detected)
    {
        // Build candidate list for adding
        list candidates = [];
        integer i;
        key owner = llGetOwner();
        for (i = 0; i < num_detected; ++i) {
            key k = llDetectedKey(i);
            if (k != owner && llListFindList(Blacklist, [k]) == -1)
                candidates += [k];
        }
        if (Sessions != []) {
            integer j = 0;
            integer found = FALSE;
            while (j < llGetListLength(Sessions) && !found) {
                key av = llList2Key(Sessions, j);
                string ctx = llList2String(Sessions, j+4);
                if (ctx == "main") {
                    show_add_candidates(av, candidates);
                    found = TRUE;
                }
                j += 10;
            }
        }
    }

    // Notifies the user when no avatars were found during the add flow.
    no_sensor()
    {
        if (Sessions != []) {
            integer j = 0;
            integer found = FALSE;
            while (j < llGetListLength(Sessions) && !found) {
                key av = llList2Key(Sessions, j);
                string ctx = llList2String(Sessions, j+4);
                if (ctx == "main") {
                    list btns = ["~", "Back", "~"];
                    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
                    s_set(av, 0, "", llGetUnixTime() + 180.0, "error", "", "", "", menu_chan);
                    llDialog(av, "No avatars found within " + (string)BlacklistRadius + " meters.", btns, menu_chan);
                    if (DEBUG) llOwnerSay("[BLACKLIST] Error dialog (no sensor) → " + (string)av + " chan=" + (string)menu_chan);
                    found = TRUE;
                }
                j += 10;
            }
        }
    }

    // Resets the plugin if collar ownership changes hands.
    changed(integer change)
    {
        if (change & CHANGED_OWNER)
        {
            llOwnerSay("[BLACKLIST] Owner changed. Resetting blacklist plugin.");
            llResetScript();
        }
    }
}
