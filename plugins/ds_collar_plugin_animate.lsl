// =============================================================
//  PLUGIN: ds_collar_plugin_animate.lsl (Canonical, strict, multi-user)
//  PURPOSE: Animate menu for DS Collar, GUH/session, permission for wearer
//  DATE:    2025-08-02 (Canonical protocol, root parametric)
// =============================================================

integer DEBUG = TRUE;

// Canonical protocol roots (global, as in core/settings)
string REGISTER_MSG_START      = "register";
string REGISTER_NOW_MSG_START  = "register_now";
string DEREGISTER_MSG_START    = "deregister";
string SOFT_RESET_MSG_START    = "core_soft_reset";
string SETTINGS_SYNC_MSG_START = "settings_sync";
string SHOW_MENU_MSG_START     = "show_menu";

// Plugin parametrics
string PLUGIN_CONTEXT = "core_animate";
string ROOT_CONTEXT   = "core_root";
string BACK_BTN_LABEL = "Back";
string FILLER_BTN     = "~";

integer PLUGIN_SN         = 0;
string  PLUGIN_LABEL      = "Animate";
integer PLUGIN_MIN_ACL    = 4;

// Protocol channels
integer PLUGIN_REG_QUERY_NUM = 500;
integer PLUGIN_REG_REPLY_NUM = 501;
integer SETTINGS_QUERY_NUM   = 800;
integer SETTINGS_SYNC_NUM    = 870;
integer UI_SHOW_MENU_NUM     = 601;

// Session state ([av, page, csv, expiry, ctx, param, step, menucsv, chan, listen])
list    g_sessions;

// Animate Plugin Local State
integer g_has_perm = FALSE;
list    g_anims;
integer g_page_size = 8; // anims at indices 4-11

// === Session Management ===
integer s_idx(key av) { return llListFindList(g_sessions, [av]); }
integer s_set(key av, integer page, string csv, float expiry, string ctx, string param, string step, string menucsv, integer chan)
{
    integer i = s_idx(av);
    if (~i) {
        integer old = llList2Integer(g_sessions, i+9);
        if (old != -1) llListenRemove(old);
        g_sessions = llDeleteSubList(g_sessions, i, i+9);
    }
    integer lh = llListen(chan, "", av, "");
    g_sessions += [av, page, csv, expiry, ctx, param, step, menucsv, chan, lh];
    return TRUE;
}
integer s_clear(key av)
{
    integer i = s_idx(av);
    if (~i) {
        integer old = llList2Integer(g_sessions, i+9);
        if (old != -1) llListenRemove(old);
        g_sessions = llDeleteSubList(g_sessions, i, i+9);
    }
    return TRUE;
}
list s_get(key av)
{
    integer i = s_idx(av);
    if (~i) return llList2List(g_sessions, i, i+9);
    return [];
}

// === Animate Logic ===
get_anims()
{
    g_anims = [];
    integer n = llGetInventoryNumber(INVENTORY_ANIMATION);
    integer i = 0;
    while (i < n)
    {
        g_anims += [llGetInventoryName(INVENTORY_ANIMATION, i)];
        i += 1;
    }
    g_anims = llListSort(g_anims, 1, TRUE); // Alphabetical order
}

show_anim_menu(key user, integer page)
{
    get_anims();
    integer total = llGetListLength(g_anims);
    if (total == 0)
    {
        integer dialog_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
        llDialog(user, "No animations in collar.", ["OK"], dialog_chan);
        s_clear(user);
        return;
    }

    // Permission logic: enforce strictly for wearer only
    if (!g_has_perm)
    {
        llOwnerSay("Collar needs permission to animate you. Please accept the permission dialog.");
        llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION);
        s_clear(user);
        return;
    }

    // Calculate anims for this page
    integer start = page * g_page_size;
    integer end = start + g_page_size - 1;
    if (end >= total) end = total - 1;

    list anim_btns = [];
    integer i = start;
    while (i <= end && i < total)
    {
        anim_btns += llList2String(g_anims, i);
        i += 1;
    }
    // Pad to 8 entries (so anims always fill 4-11)
    while (llGetListLength(anim_btns) < g_page_size) anim_btns += "~"; // CANONICAL

    // Build nav row (0–3)
    string nav_prev = "~";
    if (page > 0) nav_prev = "<<";
    string nav_next = "~";
    if (end < total - 1) nav_next = ">>";

    list btns = [nav_prev, "Back", nav_next, "Relax"] + anim_btns;

    // Ensure exactly 12 buttons (indices 0–11)
    while (llGetListLength(btns) < 12) btns += "~"; // CANONICAL

    integer menu_chan = (integer)(-1000000.0 * llFrand(1.0) - 1.0);
    s_set(user, page, "", llGetUnixTime() + 180.0, PLUGIN_CONTEXT, "", "", "", menu_chan);

    llDialog(user,
        "Animations (Page " + (string)(page + 1) + "):\n"
        + "Select an animation to play or Relax to stop all.\n"
        + "Navigation: << prev | Back | next >>",
        btns, menu_chan);

    if (DEBUG) llOwnerSay("[Animate] Menu → " + (string)user
        + " page=" + (string)page + " chan=" + (string)menu_chan
        + " btns=" + llDumpList2String(btns, ","));
}

start_anim(key user, string anim, integer page)
{
    if (g_has_perm)
    {
        llStartAnimation(anim);
        if (DEBUG) llOwnerSay("[DEBUG] Playing animation: " + anim);
        show_anim_menu(user, page);
    }
    else
    {
        llOwnerSay("Collar needs permission to animate you. Touch again after accepting.");
        llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION);
        s_clear(user);
    }
}

stop_all_anims(key user, integer page)
{
    if (g_has_perm)
    {
        integer i;
        integer n = llGetInventoryNumber(INVENTORY_ANIMATION);
        for (i = 0; i < n; ++i)
        {
            llStopAnimation(llGetInventoryName(INVENTORY_ANIMATION, i));
        }
        if (DEBUG) llOwnerSay("[DEBUG] Stopped all animations.");
        show_anim_menu(user, page);
    }
    else
    {
        llOwnerSay("Collar needs permission to animate you. Touch again after accepting.");
        llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION);
        s_clear(user);
    }
}

return_to_main_menu(key user)
{
    string menu_req = SHOW_MENU_MSG_START + "|" + ROOT_CONTEXT + "|" + (string)user + "|0";
    llMessageLinked(LINK_SET, UI_SHOW_MENU_NUM, menu_req, NULL_KEY);
    if (DEBUG) llOwnerSay("[ANIMATE] Sent Back to main menu for " + (string)user);
    s_clear(user);
}

/* ----------------- MAIN EVENT LOOP ----------------- */
default
{
    state_entry()
    {
        if (PLUGIN_SN == 0)
            PLUGIN_SN = 100000 + (integer)(llFrand(899999));

        llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION);
        if (DEBUG) llOwnerSay("[PLUGIN] (" + PLUGIN_LABEL + ") Ready. Serial: " + (string)PLUGIN_SN);
    }

    run_time_permissions(integer perm)
    {
        if (perm & PERMISSION_TRIGGER_ANIMATION) g_has_perm = TRUE;
        else g_has_perm = FALSE;
    }

    link_message(integer sender, integer num, string str, key id)
    {
        // Registration protocol: respond to poll (500, canonical)
        if ((num == PLUGIN_REG_QUERY_NUM) && llSubStringIndex(str, REGISTER_NOW_MSG_START + "|") == 0)
        {
            string script_req = llGetSubString(str, llStringLength(REGISTER_NOW_MSG_START) + 1, -1);
            if (script_req == llGetScriptName())
            {
                string reg_msg = REGISTER_MSG_START + "|" +
                                 (string)PLUGIN_SN + "|" +
                                 PLUGIN_LABEL + "|" +
                                 (string)PLUGIN_MIN_ACL + "|" +
                                 PLUGIN_CONTEXT + "|" +
                                 llGetScriptName();
                llMessageLinked(LINK_SET, PLUGIN_REG_REPLY_NUM, reg_msg, NULL_KEY);
                if (DEBUG) llOwnerSay("[PLUGIN] (" + PLUGIN_LABEL + ") Registration reply sent to core (501).");
            }
            return;
        }

        // Plugin context activation
        list p = llParseString2List(str, ["|"], []);
        if ((num == UI_SHOW_MENU_NUM) && llGetListLength(p) >= 3)
        {
            string ctx = llList2String(p, 1);
            key user = (key)llList2String(p, 2);
            if (ctx == PLUGIN_CONTEXT)
            {
                show_anim_menu(user, 0);
                return;
            }
        }
    }

    listen(integer chan, string name, key id, string msg)
    {
        list sess = s_get(id);
        if (llGetListLength(sess) == 10 && chan == llList2Integer(sess, 8))
        {
            integer page = llList2Integer(sess, 1);

            if (msg == "<<") { show_anim_menu(id, page - 1); return; }
            if (msg == ">>") { show_anim_menu(id, page + 1); return; }
            if (msg == BACK_BTN_LABEL)
            {
                return_to_main_menu(id);
                return;
            }
            if (msg == "Relax")
            {
                stop_all_anims(id, page);
                return;
            }
            integer idx = llListFindList(g_anims, [msg]);
            if (idx != -1)
            {
                start_anim(id, msg, page);
                return;
            }
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_OWNER)
        {
            llOwnerSay("[ANIMATE] Owner changed. Resetting animate plugin.");
            llResetScript();
        }
    }
}
