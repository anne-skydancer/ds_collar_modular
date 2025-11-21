/*--------------------
MODULE: ds_collar_kmod_remote.lsl
VERSION: 1.00
REVISION: 23
PURPOSE: External HUD communication bridge for remote control workflows
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Added in-place update protocol handlers (update_discover, prepare_update, etc.)
- Update messages separate from HUD protocol, use same channels
- Support for multiple collar detection and selection
- Hot-swap coordination with updater object
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;

/* -------------------- EXTERNAL PROTOCOL CHANNELS -------------------- */
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;  // Listen for ACL queries/scans
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;  // Send ACL responses
integer EXTERNAL_MENU_CHAN      = -8675311;  // Listen for menu requests

float MAX_DETECTION_RANGE = 20.0;  // Maximum range in meters for HUD detection

/* -------------------- PROTOCOL MESSAGE TYPES -------------------- */
string ROOT_CONTEXT = "core_root";
string SOS_CONTEXT = "sos_root";

/* -------------------- UPDATE PROTOCOL -------------------- */
string CURRENT_COLLAR_VERSION = "2.0.23";  // Sync with revision

key CurrentUpdater = NULL_KEY;
string UpdateSession = "";
integer ExpectedScripts = 0;
integer ReceivedScripts = 0;
integer UpdateInProgress = FALSE;

/* -------------------- STATE -------------------- */
integer AclQueryListenHandle = 0;
integer MenuRequestListenHandle = 0;
key CollarOwner = NULL_KEY;

/* Pending external queries: [hud_wearer_key, hud_object_key, ...] */
list PendingQueries = [];
integer QUERY_STRIDE = 2;

/* Pending menu requests waiting for ACL verification: [hud_wearer_key, context, ...] */
list PendingMenuRequests = [];
integer MENU_REQUEST_STRIDE = 2;

/* Query timeout tracking: [hud_wearer_key, timestamp, ...] */
list QueryTimestamps = [];
integer MAX_PENDING_QUERIES = 20;
float QUERY_TIMEOUT = 30.0;  // 30 seconds

/* Per-request-type rate limiting: [avatar_key, request_type, timestamp, ...] */
list RateLimitTimestamps = [];
integer RATE_LIMIT_TIME = 2;
float REQUEST_COOLDOWN = 2.0;  // 2 seconds between requests per user per type

// Request type identifiers
integer REQUEST_TYPE_SCAN = 1;
integer REQUEST_TYPE_ACL_QUERY = 2;
integer REQUEST_TYPE_MENU = 3;

/* -------------------- HELPERS -------------------- */


integer json_has(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

integer now() {
    return llGetUnixTime();
}

/* -------------------- RATE LIMITING (per-request-type) -------------------- */

integer check_rate_limit(key requester, integer request_type) {
    integer now_time = now();

    // Find this requester's last request of this type
    integer idx = llListFindList(RateLimitTimestamps, [requester, request_type]);
    if (idx != -1) {
        integer last_request = llList2Integer(RateLimitTimestamps, idx + RATE_LIMIT_TIME);
        if ((now_time - last_request) < REQUEST_COOLDOWN) {
            return FALSE;
        }

        // Update timestamp
        RateLimitTimestamps = llListReplaceList(RateLimitTimestamps, [now_time], idx + RATE_LIMIT_TIME, idx + RATE_LIMIT_TIME);
        return TRUE;
    }

    // First request of this type from this user
    RateLimitTimestamps += [requester, request_type, now_time];

    // Prune old entries if list gets large
    if (llGetListLength(RateLimitTimestamps) > 120) {  // 40 entries * 3 stride
        RateLimitTimestamps = llList2List(RateLimitTimestamps, -120, -1);
    }

    return TRUE;
}

/* -------------------- QUERY TIMEOUT & PRUNING -------------------- */

prune_expired_queries(integer now_time) {
    integer idx = 0;
    
    while (idx < llGetListLength(QueryTimestamps)) {
        key hud_wearer = llList2Key(QueryTimestamps, idx);
        integer timestamp = llList2Integer(QueryTimestamps, idx + 1);
        
        if ((now_time - timestamp) > QUERY_TIMEOUT) {
            
            // Remove from both lists
            integer query_idx = find_pending_query(hud_wearer);
            if (query_idx != -1) {
                PendingQueries = llDeleteSubList(PendingQueries, query_idx, query_idx + QUERY_STRIDE - 1);
            }
            
            QueryTimestamps = llDeleteSubList(QueryTimestamps, idx, idx + 1);
            // Don't increment idx since we deleted current entry
        } else {
            idx += 2;
        }
    }
}

/* -------------------- QUERY MANAGEMENT -------------------- */

add_pending_query(key hud_wearer, key hud_object) {
    integer now_time = now();
    
    // Check if query already pending for this HUD wearer
    integer idx = 0;
    integer list_len = llGetListLength(PendingQueries);
    while (idx < list_len) {
        key pending_wearer = llList2Key(PendingQueries, idx);
        if (pending_wearer == hud_wearer) {
            // Update HUD object key for existing query
            PendingQueries = llListReplaceList(PendingQueries, [hud_object], idx + 1, idx + 1);
            
            // Update timestamp
            integer ts_idx = llListFindList(QueryTimestamps, [hud_wearer]);
            if (ts_idx != -1) {
                QueryTimestamps = llListReplaceList(QueryTimestamps, [now_time], ts_idx + 1, ts_idx + 1);
            }
            
            return;
        }
        idx += QUERY_STRIDE;
    }
    
    // Prune expired queries before adding
    prune_expired_queries(now_time);
    
    // Check limit
    if (llGetListLength(PendingQueries) >= (MAX_PENDING_QUERIES * QUERY_STRIDE)) {
        // Remove oldest (FIFO)
        key oldest = llList2Key(PendingQueries, 0);
        PendingQueries = llDeleteSubList(PendingQueries, 0, QUERY_STRIDE - 1);
        
        // Remove timestamp
        integer ts_idx = llListFindList(QueryTimestamps, [oldest]);
        if (ts_idx != -1) {
            QueryTimestamps = llDeleteSubList(QueryTimestamps, ts_idx, ts_idx + 1);
        }
    }
    
    // Add new query
    PendingQueries += [hud_wearer, hud_object];
    QueryTimestamps += [hud_wearer, now_time];
}

integer find_pending_query(key hud_wearer) {
    return llListFindList(PendingQueries, [hud_wearer]);
}

remove_pending_query(key hud_wearer) {
    integer idx = find_pending_query(hud_wearer);
    if (idx == -1) return;
    
    PendingQueries = llDeleteSubList(PendingQueries, idx, idx + QUERY_STRIDE - 1);
}

/* -------------------- INTERNAL ACL COMMUNICATION -------------------- */

request_internal_acl(key avatar_key) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)avatar_key,
        "id", "remote_" + (string)avatar_key
    ]);
    
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

send_external_acl_response(key hud_wearer, integer level) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_result_external",
        "avatar", (string)hud_wearer,
        "level", (string)level,
        "collar_owner", (string)CollarOwner
    ]);
    
    // Send response on region channel - HUD will filter by collar owner
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, msg);
}

/* -------------------- MENU TRIGGERING -------------------- */

trigger_menu_for_external_user(key user_key, string context) {
    // Send start message to UI module with external user
    string msg = llList2Json(JSON_OBJECT, [
        "type", "start",
        "context", context
    ]);

    // Pass the external user's key as the id parameter
    llMessageLinked(LINK_SET, UI_BUS, msg, user_key);

}

/* -------------------- EXTERNAL PROTOCOL HANDLERS -------------------- */

handle_collar_scan(string message) {
    // Extract HUD wearer key
    if (!json_has(message, ["hud_wearer"])) {
        return;
    }

    key hud_wearer = (key)llJsonGetValue(message, ["hud_wearer"]);
    if (hud_wearer == NULL_KEY) return;

    // SECURITY: Rate limit check
    if (!check_rate_limit(hud_wearer, REQUEST_TYPE_SCAN)) return;
    
    // Check distance to HUD wearer
    list agent_data = llGetObjectDetails(hud_wearer, [OBJECT_POS]);
    if (llGetListLength(agent_data) == 0) {
        return;
    }
    
    vector hud_wearer_pos = llList2Vector(agent_data, 0);
    vector collar_owner_pos = llGetPos();
    float distance = llVecDist(hud_wearer_pos, collar_owner_pos);
    
    // Only respond if within range
    if (distance > MAX_DETECTION_RANGE) {
        return;
    }
    
    
    string response = llList2Json(JSON_OBJECT, [
        "type", "collar_scan_response",
        "collar_owner", (string)CollarOwner
    ]);
    
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, response);
}

handle_acl_query_external(string message) {
    // Extract query parameters
    if (!json_has(message, ["avatar"])) return;
    if (!json_has(message, ["hud"])) return;
    if (!json_has(message, ["target_avatar"])) return;

    key hud_wearer = (key)llJsonGetValue(message, ["avatar"]);
    key hud_object = (key)llJsonGetValue(message, ["hud"]);
    key target_avatar = (key)llJsonGetValue(message, ["target_avatar"]);

    if (hud_wearer == NULL_KEY) return;
    if (hud_object == NULL_KEY) return;
    if (target_avatar == NULL_KEY) return;

    // SECURITY: Rate limit check
    if (!check_rate_limit(hud_wearer, REQUEST_TYPE_ACL_QUERY)) return;
    
    // Check if this query is for OUR collar (target matches our owner)
    if (target_avatar != CollarOwner) {
        return;
    }
    
    
    // Store pending query
    add_pending_query(hud_wearer, hud_object);
    
    // Request ACL from internal AUTH module
    request_internal_acl(hud_wearer);
}

handle_menu_request_external(string message) {
    // Extract menu request parameters
    if (!json_has(message, ["avatar"])) return;

    key hud_wearer = (key)llJsonGetValue(message, ["avatar"]);
    if (hud_wearer == NULL_KEY) return;

    // Extract context (default to ROOT_CONTEXT if not specified)
    string context = ROOT_CONTEXT;
    if (json_has(message, ["context"])) {
        context = llJsonGetValue(message, ["context"]);
    }


    // SECURITY: Rate limit check
    if (!check_rate_limit(hud_wearer, REQUEST_TYPE_MENU)) return;

    // SECURITY: Check range
    list agent_data = llGetObjectDetails(hud_wearer, [OBJECT_POS]);
    if (llGetListLength(agent_data) == 0) {
        return;
    }

    vector hud_wearer_pos = llList2Vector(agent_data, 0);
    float distance = llVecDist(hud_wearer_pos, llGetPos());

    if (distance > MAX_DETECTION_RANGE) {
        return;
    }

    // Check if already pending for this user
    if (llListFindList(PendingMenuRequests, [hud_wearer]) != -1) {
        return;
    }

    // SECURITY: Verify ACL before triggering menu
    PendingMenuRequests += [hud_wearer, context];
    request_internal_acl(hud_wearer);
}

/* -------------------- UPDATE PROTOCOL HANDLERS -------------------- */

handle_update_discover(string message) {
    // Only respond if not already updating
    if (UpdateInProgress) return;
    
    if (!json_has(message, ["updater"])) return;
    if (!json_has(message, ["session"])) return;
    if (!json_has(message, ["version"])) return;
    
    key updater = (key)llJsonGetValue(message, ["updater"]);
    string session = llJsonGetValue(message, ["session"]);
    string new_version = llJsonGetValue(message, ["version"]);
    
    // Check range
    list details = llGetObjectDetails(updater, [OBJECT_POS]);
    if (llGetListLength(details) == 0) return;
    
    vector updater_pos = llList2Vector(details, 0);
    float distance = llVecDist(llGetPos(), updater_pos);
    
    if (distance > MAX_DETECTION_RANGE) return;
    
    // Respond with collar presence
    string response = llList2Json(JSON_OBJECT, [
        "type", "collar_present",
        "collar", (string)llGetKey(),
        "owner", (string)CollarOwner,
        "wearer", (string)llGetOwner(),
        "current_version", CURRENT_COLLAR_VERSION,
        "new_version", new_version,
        "session", session
    ]);
    
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, response);
}

handle_prepare_update(string message) {
    if (!json_has(message, ["updater"])) return;
    if (!json_has(message, ["session"])) return;
    if (!json_has(message, ["manifest"])) return;
    if (!json_has(message, ["total"])) return;
    
    key updater = (key)llJsonGetValue(message, ["updater"]);
    string session = llJsonGetValue(message, ["session"]);
    
    // Validate this is for us (same updater, same session)
    if (UpdateInProgress && updater != CurrentUpdater) return;
    
    CurrentUpdater = updater;
    UpdateSession = session;
    ExpectedScripts = (integer)llJsonGetValue(message, ["total"]);
    ReceivedScripts = 0;
    UpdateInProgress = TRUE;
    
    llOwnerSay("Preparing for update: " + (string)ExpectedScripts + " scripts");
    
    // Acknowledge ready
    string response = llList2Json(JSON_OBJECT, [
        "type", "ready_for_transfer",
        "session", session
    ]);
    
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, response);
}

handle_transfer_script(string message) {
    if (!UpdateInProgress) return;
    if (!json_has(message, ["session"])) return;
    if (llJsonGetValue(message, ["session"]) != UpdateSession) return;
    
    // Script notification received - actual transfer happens via llGiveInventory
    // We'll track via changed(CHANGED_INVENTORY) event
}

handle_transfer_coordinator(string message) {
    if (!UpdateInProgress) return;
    if (!json_has(message, ["session"])) return;
    if (llJsonGetValue(message, ["session"]) != UpdateSession) return;
    
    llOwnerSay("Coordinator received. Hot-swap will begin automatically.");
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Clean up any existing listens
        if (AclQueryListenHandle != 0) {
            llListenRemove(AclQueryListenHandle);
        }
        if (MenuRequestListenHandle != 0) {
            llListenRemove(MenuRequestListenHandle);
        }

        // Initialize state
        PendingQueries = [];
        PendingMenuRequests = [];
        QueryTimestamps = [];
        RateLimitTimestamps = [];
        CollarOwner = llGetOwner();
        
        // Listen for external ACL queries and menu requests
        AclQueryListenHandle = llListen(EXTERNAL_ACL_QUERY_CHAN, "", NULL_KEY, "");
        MenuRequestListenHandle = llListen(EXTERNAL_MENU_CHAN, "", NULL_KEY, "");
        
        // Start timer for periodic query pruning
        llSetTimerEvent(60.0);  // Check every 60 seconds
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change_mask) {
        if (change_mask & CHANGED_OWNER) {
            llResetScript();
        }
        
        if (change_mask & CHANGED_INVENTORY) {
            if (UpdateInProgress) {
                // Check for new scripts with .new suffix
                integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
                integer new_scripts = 0;
                integer has_coordinator = FALSE;
                integer i = 0;
                
                while (i < count) {
                    string name = llGetInventoryName(INVENTORY_SCRIPT, i);
                    if (llSubStringIndex(name, ".new") != -1) {
                        new_scripts += 1;
                    }
                    if (name == "ds_collar_updater_coordinator") {
                        has_coordinator = TRUE;
                    }
                    i += 1;
                }
                
                // Check if update complete (all scripts + coordinator present)
                if (new_scripts >= ExpectedScripts && has_coordinator) {
                    llOwnerSay("All update files received. Hot-swap starting...");
                    UpdateInProgress = FALSE;
                    CurrentUpdater = NULL_KEY;
                    UpdateSession = "";
                }
            }
        }
    }
    
    timer() {
        // Periodic query pruning
        prune_expired_queries(now());
    }
    
    listen(integer channel, string name, key speaker_id, string message) {
        // Handle collar scan broadcasts and ACL queries
        if (channel == EXTERNAL_ACL_QUERY_CHAN) {
            if (!json_has(message, ["type"])) return;
            string msg_type = llJsonGetValue(message, ["type"]);
            
            // Respond to collar scan
            if (msg_type == "collar_scan") {
                handle_collar_scan(message);
                return;
            }
            
            // Handle ACL queries
            if (msg_type == "acl_query_external") {
                handle_acl_query_external(message);
                return;
            }
            
            // Handle update discovery
            if (msg_type == "update_discover") {
                handle_update_discover(message);
                return;
            }
            
            return;
        }
        
        // Handle menu requests (only from HUDs we've authorized)
        if (channel == EXTERNAL_MENU_CHAN) {
            if (!json_has(message, ["type"])) return;
            
            string msg_type = llJsonGetValue(message, ["type"]);
            
            if (msg_type == "menu_request_external") {
                handle_menu_request_external(message);
                return;
            }
            
            // Handle update protocol messages
            if (msg_type == "prepare_update") {
                handle_prepare_update(message);
                return;
            }
            
            if (msg_type == "transfer_script") {
                handle_transfer_script(message);
                return;
            }
            
            if (msg_type == "transfer_coordinator") {
                handle_transfer_coordinator(message);
                return;
            }
            
            return;
        }
    }
    
    link_message(integer sender_num, integer num, string str, key id) {
        if (!json_has(str, ["type"])) return;

        string msg_type = llJsonGetValue(str, ["type"]);

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "soft_reset" || msg_type == "soft_reset_all") {
                llResetScript();
            }
            return;
        }

        // Handle ACL result from AUTH module
        if (num == AUTH_BUS) {
            if (msg_type != "acl_result") return;
            
            // Extract ACL information
            if (!json_has(str, ["avatar"])) return;
            
            key avatar_key = (key)llJsonGetValue(str, ["avatar"]);
            
            // Extract ACL level
            integer level = 0;
            if (json_has(str, ["level"])) {
                level = (integer)llJsonGetValue(str, ["level"]);
            }
            
            // Check if this is a menu request ACL verification
            string requested_context = "";
            integer menu_idx = llListFindList(PendingMenuRequests, [avatar_key]);

            if (menu_idx != -1) {
                requested_context = llList2String(PendingMenuRequests, menu_idx + 1);
                PendingMenuRequests = llDeleteSubList(PendingMenuRequests, menu_idx, menu_idx + MENU_REQUEST_STRIDE - 1);
                jump found_menu_request;
            }
            jump not_menu_request;

            @found_menu_request;
            // This is a menu request ACL check


            // TPE MODE EMERGENCY ACCESS: Allow wearer to access SOS menu even with ACL 0
            integer is_wearer = (avatar_key == llGetOwner());
            integer emergency_access = (level == 0 && requested_context == SOS_CONTEXT && is_wearer);

            // Only trigger menu if ACL >= 1 (public or higher) OR emergency access (TPE mode)
            if (level >= 1 || emergency_access) {
                // SECURITY: Only allow SOS context for collar wearer
                // Non-wearers requesting SOS get downgraded to root menu
                string final_context = requested_context;
                if (requested_context == SOS_CONTEXT && !is_wearer) {
                    final_context = ROOT_CONTEXT;
                    llRegionSayTo(avatar_key, 0, "Only the collar wearer can access the SOS menu. Showing main menu instead.");
                }

                trigger_menu_for_external_user(avatar_key, final_context);
            }
            return;

            @not_menu_request;
            
            // Check if this is a response to a pending external query
            integer query_idx = find_pending_query(avatar_key);
            if (query_idx == -1) return;  // Not an external query
            
            // Send response to HUD wearer
            send_external_acl_response(avatar_key, level);
            
            // Clean up pending query
            remove_pending_query(avatar_key);
            return;
        }
    }
}
