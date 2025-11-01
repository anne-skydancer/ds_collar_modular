/* =============================================================================
   DS Collar - Animate Plugin (v2.0 - Kanban Messaging Migration)

   PURPOSE: Paginated animation menu with inventory-driven animation list

   FEATURES:
   - Automatic inventory scanning
   - Paginated menu (8 animations per page)
   - Wrap-around navigation (<< / >>)
   - [Stop] button to stop all animations
   - Permission handling for TRIGGER_ANIMATION

   ACL: Public (1) and above

   KANBAN MIGRATION (v2.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ═══════════════════════════════════════════════════════════
   PLUGIN IDENTITY
   ═══════════════════════════════════════════════════════════ */
string CONTEXT = "animate";

/* ═══════════════════════════════════════════════════════════
   KANBAN UNIVERSAL HELPER (~500-800 bytes)
   ═══════════════════════════════════════════════════════════ */

string kFrom = "";  // Sender context (populated by kRecv)
string kTo = "";    // Recipient context (populated by kRecv)

kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, [
            "from", from,
            "payload", payload,
            "to", to
        ]),
        k
    );
}

string kRecv(string msg, string my_context) {
    // Quick validation: must be JSON object
    if (llGetSubString(msg, 0, 0) != "{") return "";

    // Extract from
    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    // Extract to
    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast "" or direct to my_context)
    if (to != "" && to != my_context) return "";

    // Extract payload
    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    // Set globals for routing
    kFrom = from;
    kTo = to;

    return payload;
}

string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

string kDeltaSet(string setting_key, string val) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", setting_key,
        "value", val
    ]);
}

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

string PLUGIN_LABEL = "Animate";
integer PLUGIN_MIN_ACL = 1;  // Public can use

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
// Session management
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
integer AclPending = FALSE;
string SessionId = "";

// Pagination
integer CurrentPage = 0;
integer PAGE_SIZE = 8;  // 8 animations + 4 nav buttons = 12 total

// Animation inventory
list AnimationList = [];
string LastPlayedAnim = "";

// Permissions
integer HasPermission = FALSE;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[ANIMATE] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return CONTEXT + "_" + (string)llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   ANIMATION INVENTORY MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

refresh_animation_list() {
    AnimationList = [];
    integer count = llGetInventoryNumber(INVENTORY_ANIMATION);
    integer i;
    
    for (i = 0; i < count; i++) {
        string anim_name = llGetInventoryName(INVENTORY_ANIMATION, i);
        if (anim_name != "") {
            AnimationList += [anim_name];
        }
    }
    
    logd("Found " + (string)llGetListLength(AnimationList) + " animations");
}

/* ═══════════════════════════════════════════════════════════
   ANIMATION CONTROL
   ═══════════════════════════════════════════════════════════ */

ensure_permissions() {
    key owner = llGetOwner();
    if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION) {
        HasPermission = TRUE;
        logd("Already have animation permission");
    }
    else {
        llRequestPermissions(owner, PERMISSION_TRIGGER_ANIMATION);
        logd("Requesting animation permission");
    }
}

start_animation(string anim_name) {
    if (!HasPermission) {
        logd("No permission to trigger animations");
        llRegionSayTo(CurrentUser, 0, "No animation permission granted.");
        return;
    }
    
    // Stop last animation if there was one
    if (LastPlayedAnim != "") {
        llStopAnimation(LastPlayedAnim);
        logd("Stopped: " + LastPlayedAnim);
    }
    
    // Start new animation
    if (llGetInventoryType(anim_name) == INVENTORY_ANIMATION) {
        llStartAnimation(anim_name);
        LastPlayedAnim = anim_name;
        logd("Started: " + anim_name);
        llRegionSayTo(CurrentUser, 0, "Playing: " + anim_name);
    }
    else {
        logd("Animation not found: " + anim_name);
        llRegionSayTo(CurrentUser, 0, "Animation not found: " + anim_name);
    }
}

stop_all_animations() {
    if (LastPlayedAnim != "") {
        llStopAnimation(LastPlayedAnim);
        logd("Stopped: " + LastPlayedAnim);
        LastPlayedAnim = "";
        llRegionSayTo(CurrentUser, 0, "Animation stopped.");
    }
    else {
        llRegionSayTo(CurrentUser, 0, "No animation playing.");
    }
}

/* ═══════════════════════════════════════════════════════════
   LIFECYCLE MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

register_self() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload([
            "label", PLUGIN_LABEL,
            "min_acl", PLUGIN_MIN_ACL,
            "script", llGetScriptName()
        ]),
        NULL_KEY
    );
    logd("Registered with kernel");
}

send_pong() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload(["pong", 1]),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   ACL VALIDATION
   ═══════════════════════════════════════════════════════════ */

request_acl(key user) {
    AclPending = TRUE;
    kSend(CONTEXT, "auth", AUTH_BUS,
        kPayload(["avatar", (string)user]),
        user
    );
    logd("ACL query sent for " + llKey2Name(user));
}

/* ═══════════════════════════════════════════════════════════
   UI / MENU SYSTEM
   ═══════════════════════════════════════════════════════════ */

show_animation_menu(integer page) {
    SessionId = generate_session_id();
    CurrentPage = page;
    
    integer total_anims = llGetListLength(AnimationList);
    
    // Handle empty animation list
    if (total_anims == 0) {
        list buttons = ["Back"];
        string buttons_json = llList2Json(JSON_ARRAY, buttons);
        
        kSend(CONTEXT, "dialogs", DIALOG_BUS,
            kPayload([
                "session_id", SessionId,
                "user", (string)CurrentUser,
                "title", PLUGIN_LABEL,
                "body", "No animations found in inventory.",
                "buttons", buttons_json,
                "timeout", 60
            ]),
            NULL_KEY
        );
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
    
    // Build animation buttons for this page (up to 8 animations)
    list buttons = [];
    integer i;
    for (i = start_idx; i <= end_idx; i++) {
        buttons += [llList2String(AnimationList, i)];
    }
    
    // llDialog builds 3x4 grid bottom-right to top-left
    // We want visual layout:
    // [Anim 1] [Anim 2] [Anim 3]    
    // [Anim 4] [Anim 5] [Anim 6] 
    // [Anim 7] [Anim 8] [Stop]
    // [Back]   [>>]     [<<]
    //
    // Button array indices:
    // 0=<<, 1=>>, 2=Back, 3=[Stop], 4-11=animations (reversed)
    
    // Reverse the animations so they display top-left to bottom-right
    list reversed_anims = [];
    i = llGetListLength(buttons) - 1;
    while (i >= 0) {
        reversed_anims += [llList2String(buttons, i)];
        i = i - 1;
    }
    
    // Build final array
    list final_buttons = ["<<", ">>", "Back", "[Stop]"] + reversed_anims;
    
    string buttons_json = llList2Json(JSON_ARRAY, final_buttons);

    // Build body text
    string body = "Select an animation to play.\n";
    body += "Page " + (string)(page + 1) + " of " + (string)(max_page + 1);
    if (LastPlayedAnim != "") {
        body += "\nPlaying: " + LastPlayedAnim;
    }

    kSend(CONTEXT, "dialogs", DIALOG_BUS,
        kPayload([
            "session_id", SessionId,
            "user", (string)CurrentUser,
            "title", PLUGIN_LABEL,
            "body", body,
            "buttons", buttons_json,
            "timeout", 60
        ]),
        NULL_KEY
    );
    logd("Showing page " + (string)(page + 1) + " of " + (string)(max_page + 1));
}

/* ═══════════════════════════════════════════════════════════
   BUTTON HANDLING
   ═══════════════════════════════════════════════════════════ */

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

/* ═══════════════════════════════════════════════════════════
   UI NAVIGATION
   ═══════════════════════════════════════════════════════════ */

ui_return_root() {
    kSend(CONTEXT, "ui", UI_BUS,
        kPayload(["user", (string)CurrentUser]),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   SESSION CLEANUP
   ═══════════════════════════════════════════════════════════ */

cleanup_session() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    AclPending = FALSE;
    SessionId = "";
    CurrentPage = 0;
    logd("Session cleaned up");
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default {
    state_entry() {
        cleanup_session();
        refresh_animation_list();
        ensure_permissions();
        register_self();
        logd("Ready with " + (string)llGetListLength(AnimationList) + " animations");
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
            logd("Animation permission granted");
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        // Route by channel + kFrom + payload structure

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE && kFrom == "kernel") {
            // Targeted soft_reset: has "context" field
            if (json_has(payload, ["context"])) {
                string target_context = llJsonGetValue(payload, ["context"]);
                if (target_context != "" && target_context != CONTEXT) {
                    return; // Not for us
                }
                llResetScript();
            }
            // Soft reset with "reset" marker
            else if (json_has(payload, ["reset"])) {
                llResetScript();
            }
            // Register now: has "register_now" marker
            else if (json_has(payload, ["register_now"])) {
                register_self();
            }
            // Ping: has "ping" marker
            else if (json_has(payload, ["ping"])) {
                send_pong();
            }
        }

        /* ===== UI START ===== */
        else if (num == UI_BUS) {
            // UI start: for our context
            if (kTo == CONTEXT && json_has(payload, ["user"])) {
                CurrentUser = id;
                CurrentPage = 0;
                request_acl(id);
            }
        }

        /* ===== AUTH RESULT ===== */
        else if (num == AUTH_BUS && kFrom == "auth") {
            // ACL result: has "avatar" and "level" fields
            if (json_has(payload, ["avatar"]) && json_has(payload, ["level"])) {
                if (!AclPending) return;

                key avatar = (key)llJsonGetValue(payload, ["avatar"]);
                if (avatar != CurrentUser) return;

                UserAcl = (integer)llJsonGetValue(payload, ["level"]);
                AclPending = FALSE;

                if (UserAcl < PLUGIN_MIN_ACL) {
                    llRegionSayTo(CurrentUser, 0, "Access denied.");
                    cleanup_session();
                    return;
                }

                // User has access, show menu
                show_animation_menu(0);
                logd("ACL received: " + (string)UserAcl);
            }
        }

        /* ===== DIALOG RESPONSE ===== */
        else if (num == DIALOG_BUS && kFrom == "dialogs") {
            // Dialog response: has "session_id" and "button" fields
            if (json_has(payload, ["session_id"]) && json_has(payload, ["button"])) {
                string response_session = llJsonGetValue(payload, ["session_id"]);
                if (response_session != SessionId) return;

                string button = llJsonGetValue(payload, ["button"]);

                // Re-validate ACL
                if (UserAcl < PLUGIN_MIN_ACL) {
                    llRegionSayTo(CurrentUser, 0, "Access denied.");
                    cleanup_session();
                    return;
                }

                handle_button_click(button);
            }
            // Dialog timeout: has "session_id" but no "button"
            else if (json_has(payload, ["session_id"]) && !json_has(payload, ["button"])) {
                string timeout_session = llJsonGetValue(payload, ["session_id"]);
                if (timeout_session != SessionId) return;

                logd("Dialog timeout");
                cleanup_session();
            }
        }
    }
}
