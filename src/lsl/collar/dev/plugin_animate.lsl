/*--------------------
PLUGIN: plugin_animate.lsl
VERSION: 1.10
REVISION: 3
PURPOSE: Paginated animation menu driven by inventory contents
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.1 rev 3: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.1 rev 2: Namespace internal message type strings (kernel.*, ui.*, settings.*).
- v1.1 rev 1: Honor soft_reset / soft_reset_all from KERNEL_LIFECYCLE so
  factory reset clears cached state.
- v1.1 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads.
  Button list built from get_policy_buttons() + btn_allowed().
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.animate";
string PLUGIN_LABEL = "Animate";

/* -------------------- OTHER CONSTANTS -------------------- */

integer MAX_ANIMATIONS = 128;

/* -------------------- STATE -------------------- */
// Session management
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";

// Pagination
integer CurrentPage = 0;
integer PAGE_SIZE = 8;  // 8 animations + 4 nav buttons = 12 total

// Animation inventory
list AnimationList = [];
string LastPlayedAnim = "";

// Permissions
integer HasPermission = FALSE;

/* -------------------- HELPERS -------------------- */



string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD POLICY HELPER -------------------- */
list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("acl.policycontext:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

/* -------------------- ANIMATION INVENTORY MANAGEMENT -------------------- */

refresh_animation_list() {
    AnimationList = [];
    integer count = llGetInventoryNumber(INVENTORY_ANIMATION);

    // Safety cap to prevent stack-heap collision
    if (count > MAX_ANIMATIONS) {
        llOwnerSay("WARNING: Too many animations (" + (string)count + "). Only loading first " + (string)MAX_ANIMATIONS + ".");
        count = MAX_ANIMATIONS;
    }

    integer i;
    for (i = 0; i < count; i++) {
        string anim_name = llGetInventoryName(INVENTORY_ANIMATION, i);
        if (anim_name != "") {
            AnimationList += [anim_name];
        }
    }

}

/* -------------------- ANIMATION CONTROL -------------------- */

ensure_permissions() {
    key owner = llGetOwner();
    if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION) {
        HasPermission = TRUE;
    }
    else {
        llRequestPermissions(owner, PERMISSION_TRIGGER_ANIMATION);
    }
}

start_animation(string anim_name) {
    if (!HasPermission) {
        llRegionSayTo(CurrentUser, 0, "No animation permission granted.");
        return;
    }

    // Stop last animation if there was one
    if (LastPlayedAnim != "") {
        llStopAnimation(LastPlayedAnim);
    }

    // Start new animation
    if (llGetInventoryType(anim_name) == INVENTORY_ANIMATION) {
        llStartAnimation(anim_name);
        LastPlayedAnim = anim_name;
        llRegionSayTo(CurrentUser, 0, "Playing: " + anim_name);
    }
    else {
        llRegionSayTo(CurrentUser, 0, "Animation not found: " + anim_name);
    }
}

stop_all_animations() {
    if (LastPlayedAnim != "") {
        llStopAnimation(LastPlayedAnim);
        LastPlayedAnim = "";
        llRegionSayTo(CurrentUser, 0, "Animation stopped.");
    }
    else {
        llRegionSayTo(CurrentUser, 0, "No animation playing.");
    }
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

register_self() {
    // Write button visibility policy to LSD (all ACL levels see same buttons)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "<<,>>,Stop",
        "2", "<<,>>,Stop",
        "3", "<<,>>,Stop",
        "4", "<<,>>,Stop",
        "5", "<<,>>,Stop"
    ]));

    // Register with kernel
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- UI / MENU SYSTEM -------------------- */

show_animation_menu(integer page) {
    SessionId = generate_session_id();
    CurrentPage = page;

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    integer total_anims = llGetListLength(AnimationList);

    // Handle empty animation list
    if (total_anims == 0) {
        list buttons = ["Back"];
        string buttons_json = llList2Json(JSON_ARRAY, buttons);

        string msg = llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.open",
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", PLUGIN_LABEL,
            "message", "No animations found in inventory.",
            "buttons", buttons_json,
            "timeout", 60
        ]);

        llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
        return;
    }

    // Calculate page bounds
    integer max_page = (total_anims - 1) / PAGE_SIZE;

    // Clamp page
    if (page < 0) page = 0;
    if (page > max_page) page = max_page;
    CurrentPage = page;

    integer start_idx = page * PAGE_SIZE;
    integer end_idx = start_idx + PAGE_SIZE - 1;
    if (end_idx >= total_anims) end_idx = total_anims - 1;

    // Fixed layout:
    // Indices 0-2: Navigation (<<, >>, Back)
    // Index 3: [Stop]
    // Indices 4+: Animations (Sorted Top-to-Bottom, Left-to-Right)

    // 1. Extract animations for this page
    list page_anims = [];
    integer i;
    for (i = start_idx; i <= end_idx; i++) {
        page_anims += [llList2String(AnimationList, i)];
    }

    integer count = llGetListLength(page_anims);
    integer total_buttons = 4 + count;

    // 2. Initialize button list with placeholders
    list final_buttons = ["<<", ">>", "Back", "[Stop]"];
    integer p;
    for (p = 0; p < count; p++) {
        final_buttons += [""];
    }

    // 3. Define visual rows (Top to Bottom)
    // Row 4: 9, 10, 11
    // Row 3: 6, 7, 8
    // Row 2: 4, 5 (Index 3 is Stop)

    list target_slots = [];

    // Row 4
    if (total_buttons > 9) target_slots += [9];
    if (total_buttons > 10) target_slots += [10];
    if (total_buttons > 11) target_slots += [11];

    // Row 3
    if (total_buttons > 6) target_slots += [6];
    if (total_buttons > 7) target_slots += [7];
    if (total_buttons > 8) target_slots += [8];

    // Row 2
    if (total_buttons > 4) target_slots += [4];
    if (total_buttons > 5) target_slots += [5];

    // 4. Map animations to slots
    for (i = 0; i < count; i++) {
        integer slot = llList2Integer(target_slots, i);
        string anim = llList2String(page_anims, i);
        final_buttons = llListReplaceList(final_buttons, [anim], slot, slot);
    }

    string buttons_json = llList2Json(JSON_ARRAY, final_buttons);

    // Build message
    string message = "Select an animation to play.\n";
    message += "Page " + (string)(page + 1) + " of " + (string)(max_page + 1);
    if (LastPlayedAnim != "") {
        message += "\nPlaying: " + LastPlayedAnim;
    }

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string button) {
    // Back button - return to root menu
    if (button == "Back") {
        ui_return_root();
        cleanup_session();
        return;
    }

    // Stop button
    if (button == "[Stop]") {
        stop_all_animations();
        show_animation_menu(CurrentPage);
        return;
    }

    // Pagination - left (with wrap)
    if (button == "<<") {
        integer total_anims = llGetListLength(AnimationList);
        integer max_page = (total_anims - 1) / PAGE_SIZE;

        if (CurrentPage == 0) {
            // Wrap to last page
            show_animation_menu(max_page);
        }
        else {
            show_animation_menu(CurrentPage - 1);
        }
        return;
    }

    // Pagination - right (with wrap)
    if (button == ">>") {
        integer total_anims = llGetListLength(AnimationList);
        integer max_page = (total_anims - 1) / PAGE_SIZE;

        if (CurrentPage >= max_page) {
            // Wrap to first page
            show_animation_menu(0);
        }
        else {
            show_animation_menu(CurrentPage + 1);
        }
        return;
    }

    // Check if button is an animation name
    if (llListFindList(AnimationList, [button]) != -1) {
        start_animation(button);
        show_animation_menu(CurrentPage);
        return;
    }

    // Unknown button - redraw menu
    show_animation_menu(CurrentPage);
}

/* -------------------- UI NAVIGATION -------------------- */

ui_return_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- SESSION CLEANUP -------------------- */

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    CurrentPage = 0;
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        cleanup_session();
        refresh_animation_list();
        ensure_permissions();
        register_self();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }

        if (change & CHANGED_INVENTORY) {
            integer old_count = llGetListLength(AnimationList);
            refresh_animation_list();
            integer new_count = llGetListLength(AnimationList);

            // Only redraw if count changed AND user has menu open
            if (old_count != new_count && CurrentUser != NULL_KEY) {
                // Clamp page if needed
                integer total_anims = new_count;
                integer max_page = 0;
                if (total_anims > 0) {
                    max_page = (total_anims - 1) / PAGE_SIZE;
                }
                if (CurrentPage > max_page) {
                    CurrentPage = max_page;
                }

                show_animation_menu(CurrentPage);
            }
        }
    }

    run_time_permissions(integer perm) {
        if (perm & PERMISSION_TRIGGER_ANIMATION) {
            HasPermission = TRUE;
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* -------------------- KERNEL LIFECYCLE -------------------- */if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            // Registration request
            if (msg_type == "kernel.registernow") {
                register_self();
                return;
            }

            // Heartbeat ping
            if (msg_type == "kernel.ping") {
                send_pong();
                return;
            }

            if (msg_type == "kernel.reset" || msg_type == "kernel.resetall") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                llResetScript();
            }

            return;
        }

        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                CurrentUser = id;
                CurrentPage = 0;
                UserAcl = (integer)llJsonGetValue(msg, ["acl"]);

                show_animation_menu(0);
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSE -------------------- */if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

                string button = llJsonGetValue(msg, ["button"]);
                if (button == JSON_INVALID) return;

                string user_str = llJsonGetValue(msg, ["user"]);
                if (user_str == JSON_INVALID) return;
                key user = (key)user_str;

                if (user != CurrentUser) return;

                handle_button_click(button);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

                cleanup_session();
                return;
            }

            return;
        }
    }
}
