/* ===============================================================
   PLUGIN: ds_collar_plugin_animate.lsl (v1.0 - Consolidated ABI)
   
   PURPOSE: Paginated animation menu with inventory-driven animation list
   
   FEATURES:
   - Automatic inventory scanning
   - Paginated menu (8 animations per page)
   - Wrap-around navigation (<< / >>)
   - [Stop] button to stop all animations
   - Permission handling for TRIGGER_ANIMATION
   
   TIER: 2 (Medium - list management, paging)
   =============================================================== */

integer DEBUG = FALSE;

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ===============================================================
   PLUGIN IDENTITY
   =============================================================== */
string PLUGIN_CONTEXT = "core_animate";
string PLUGIN_LABEL = "Animate";
integer PLUGIN_MIN_ACL = 1;  // Public can use
string ROOT_CONTEXT = "core_root";

/* ===============================================================
   STATE
   =============================================================== */
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

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[ANIMATE] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* ===============================================================
   ANIMATION INVENTORY MANAGEMENT
   =============================================================== */

void refreshAnimationList() {
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

/* ===============================================================
   ANIMATION CONTROL
   =============================================================== */

void ensurePermissions() {
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

void startAnimation(string anim_name) {
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

void stopAllAnimations() {
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

/* ===============================================================
   LIFECYCLE MANAGEMENT
   =============================================================== */

void registerSelf() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Registered with kernel");
}

sendPong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* ===============================================================
   ACL VALIDATION
   =============================================================== */

requestAcl(key user) {
    AclPending = TRUE;
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)user,
        "id", PLUGIN_CONTEXT + "_acl"
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

handleAclResult(string msg) {
    if (!jsonHas(msg, ["avatar"])) return;
    if (!jsonHas(msg, ["level"])) return;
    
    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != CurrentUser) return;
    
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    
    AclPending = FALSE;
    UserAcl = level;
    
    if (level < PLUGIN_MIN_ACL) {
        llRegionSayTo(CurrentUser, 0, "Access denied.");
        cleanupSession();
        return;
    }
    
    // User has access, show menu
    showAnimationMenu(0);
}

/* ===============================================================
   UI / MENU SYSTEM
   =============================================================== */

showAnimationMenu(integer page) {
    SessionId = generate_session_id();
    CurrentPage = page;
    
    integer total_anims = llGetListLength(AnimationList);
    
    // Handle empty animation list
    if (total_anims == 0) {
        list buttons = ["Back"];
        string buttons_json = llList2Json(JSON_ARRAY, buttons);
        
        string msg = llList2Json(JSON_OBJECT, [
            "type", "dialog_open",
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
    
    // Build message
    string message = "Select an animation to play.\n";
    message += "Page " + (string)(page + 1) + " of " + (string)(max_page + 1);
    if (LastPlayedAnim != "") {
        message += "\nPlaying: " + LastPlayedAnim;
    }
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);
    
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
    logd("Showing page " + (string)(page + 1) + " of " + (string)(max_page + 1));
}

/* ===============================================================
   BUTTON HANDLING
   =============================================================== */

handleButtonClick(string button) {
    // Back button - return to root menu
    if (button == "Back") {
        uiReturnRoot();
        cleanupSession();
        return;
    }
    
    // Stop button
    if (button == "[Stop]") {
        stopAllAnimations();
        showAnimationMenu(CurrentPage);
        return;
    }
    
    // Pagination - left (with wrap)
    if (button == "<<") {
        integer total_anims = llGetListLength(AnimationList);
        integer max_page = (total_anims - 1) / PAGE_SIZE;
        
        if (CurrentPage == 0) {
            // Wrap to last page
            showAnimationMenu(max_page);
        }
        else {
            showAnimationMenu(CurrentPage - 1);
        }
        return;
    }
    
    // Pagination - right (with wrap)
    if (button == ">>") {
        integer total_anims = llGetListLength(AnimationList);
        integer max_page = (total_anims - 1) / PAGE_SIZE;
        
        if (CurrentPage >= max_page) {
            // Wrap to first page
            showAnimationMenu(0);
        }
        else {
            showAnimationMenu(CurrentPage + 1);
        }
        return;
    }
    
    // Check if button is an animation name
    if (llListFindList(AnimationList, [button]) != -1) {
        startAnimation(button);
        showAnimationMenu(CurrentPage);
        return;
    }
    
    // Unknown button - redraw menu
    showAnimationMenu(CurrentPage);
}

/* ===============================================================
   UI NAVIGATION
   =============================================================== */

uiReturnRoot() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* ===============================================================
   SESSION CLEANUP
   =============================================================== */

cleanupSession() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    AclPending = FALSE;
    SessionId = "";
    CurrentPage = 0;
    logd("Session cleaned up");
}

/* ===============================================================
   EVENTS
   =============================================================== */

default {
    state_entry() {
        cleanupSession();
        refreshAnimationList();
        ensurePermissions();
        registerSelf();
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
            refreshAnimationList();
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
                
                showAnimationMenu(CurrentPage);
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
        // ===== KERNEL LIFECYCLE =====
        if (num == KERNEL_LIFECYCLE) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            // Registration request
            if (msg_type == "register_now") {
                registerSelf();
                return;
            }
            
            // Heartbeat ping
            if (msg_type == "ping") {
                sendPong();
                return;
            }
            
            return;
        }
        
        // ===== UI START =====
        if (num == UI_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "start") {
                if (!jsonHas(msg, ["context"])) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                
                if (id == NULL_KEY) return;
                
                CurrentUser = id;
                CurrentPage = 0;
                requestAcl(id);
                return;
            }
            
            return;
        }
        
        // ===== AUTH RESULT =====
        if (num == AUTH_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "acl_result") {
                if (!AclPending) return;
                handleAclResult(msg);
                return;
            }
            
            return;
        }
        
        // ===== DIALOG RESPONSE =====
        if (num == DIALOG_BUS) {
            if (!jsonHas(msg, ["type"])) return;
            string msg_type = llJsonGetValue(msg, ["type"]);
            
            if (msg_type == "dialog_response") {
                if (!jsonHas(msg, ["session_id"])) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
                
                if (!jsonHas(msg, ["button"])) return;
                string button = llJsonGetValue(msg, ["button"]);
                
                if (!jsonHas(msg, ["user"])) return;
                key user = (key)llJsonGetValue(msg, ["user"]);
                
                if (user != CurrentUser) return;
                
                // Re-validate ACL
                if (UserAcl < PLUGIN_MIN_ACL) {
                    llRegionSayTo(user, 0, "Access denied.");
                    cleanupSession();
                    return;
                }
                
                handleButtonClick(button);
                return;
            }
            
            if (msg_type == "dialog_timeout") {
                if (!jsonHas(msg, ["session_id"])) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
                
                cleanupSession();
                logd("Dialog timeout");
                return;
            }
            
            return;
        }
    }
}
