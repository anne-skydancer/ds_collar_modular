/* =============================================================================
   MODULE: ds_collar_kmod_remote.lsl (v2.0 - Consolidated ABI)
   
   ROLE: External HUD communication bridge
   
   PURPOSE: Handles ACL queries and menu requests from control HUDs worn by
            other avatars. Allows HUD wearers to remotely control collars
            they have permission to access.
   
   CHANNELS:
   - 700 (AUTH_BUS): ACL queries to internal AUTH module
   - 900 (UI_BUS): Menu triggering for external users
   
   EXTERNAL PROTOCOL:
   - -8675309: Listen for external ACL queries and collar scans
   - -8675310: Send ACL responses to HUDs
   - -8675311: Listen for menu request commands
   
   WORKFLOW:
   1. HUD broadcasts collar scan â†’ Collar responds with owner UUID
   2. HUD sends ACL query â†’ Collar queries AUTH â†’ Collar responds with level
   3. HUD sends menu request â†’ Collar triggers UI for HUD wearer
   ============================================================================= */

integer DEBUG = TRUE;

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer AUTH_BUS = 700;
integer UI_BUS = 900;

/* ═══════════════════════════════════════════════════════════
   EXTERNAL PROTOCOL CHANNELS
   ═══════════════════════════════════════════════════════════ */
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;  // Listen for ACL queries/scans
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;  // Send ACL responses
integer EXTERNAL_MENU_CHAN      = -8675311;  // Listen for menu requests

float MAX_DETECTION_RANGE = 20.0;  // Maximum range in meters for HUD detection

/* ═══════════════════════════════════════════════════════════
   PROTOCOL MESSAGE TYPES
   ═══════════════════════════════════════════════════════════ */
string ROOT_CONTEXT = "core_root";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
integer AclQueryListenHandle = 0;
integer MenuRequestListenHandle = 0;
key CollarOwner = NULL_KEY;

/* Pending external queries: [hud_wearer_key, hud_object_key, ...] */
list PendingQueries = [];
integer QUERY_STRIDE = 2;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[REMOTE] " + msg);
    return FALSE;
}

integer json_has(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

/* ═══════════════════════════════════════════════════════════
   QUERY MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

add_pending_query(key hud_wearer, key hud_object) {
    // Check if query already pending for this HUD wearer
    integer idx = 0;
    integer list_len = llGetListLength(PendingQueries);
    while (idx < list_len) {
        key pending_wearer = llList2Key(PendingQueries, idx);
        if (pending_wearer == hud_wearer) {
            // Update HUD object key for existing query
            PendingQueries = llListReplaceList(PendingQueries, [hud_object], idx + 1, idx + 1);
            logd("Updated pending query for " + llKey2Name(hud_wearer));
            return;
        }
        idx += QUERY_STRIDE;
    }
    
    // Add new query
    PendingQueries += [hud_wearer, hud_object];
    logd("Added pending query for " + llKey2Name(hud_wearer));
}

integer find_pending_query(key hud_wearer) {
    integer idx = 0;
    integer list_len = llGetListLength(PendingQueries);
    while (idx < list_len) {
        key pending_wearer = llList2Key(PendingQueries, idx);
        if (pending_wearer == hud_wearer) {
            return idx;
        }
        idx += QUERY_STRIDE;
    }
    return -1;
}

remove_pending_query(key hud_wearer) {
    integer idx = find_pending_query(hud_wearer);
    if (idx == -1) return;
    
    PendingQueries = llDeleteSubList(PendingQueries, idx, idx + QUERY_STRIDE - 1);
    logd("Removed pending query for " + llKey2Name(hud_wearer));
}

/* ═══════════════════════════════════════════════════════════
   INTERNAL ACL COMMUNICATION
   ═══════════════════════════════════════════════════════════ */

request_internal_acl(key avatar_key) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)avatar_key,
        "id", "remote_" + (string)avatar_key
    ]);
    
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
    logd("Requested internal ACL for " + llKey2Name(avatar_key));
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
    logd("Sent ACL response: hud_wearer=" + llKey2Name(hud_wearer) + ", level=" + (string)level);
}

/* ═══════════════════════════════════════════════════════════
   MENU TRIGGERING
   ═══════════════════════════════════════════════════════════ */

trigger_menu_for_external_user(key user_key) {
    // Send start message to UI module with external user
    string msg = llList2Json(JSON_OBJECT, [
        "type", "start",
        "context", ROOT_CONTEXT
    ]);
    
    // Pass the external user's key as the id parameter
    llMessageLinked(LINK_SET, UI_BUS, msg, user_key);
    
    logd("Triggered menu for external user: " + llKey2Name(user_key));
}

/* ═══════════════════════════════════════════════════════════
   EXTERNAL PROTOCOL HANDLERS
   ═══════════════════════════════════════════════════════════ */

handle_collar_scan(string message) {
    // Extract HUD wearer key
    if (!json_has(message, ["hud_wearer"])) {
        logd("collar_scan missing hud_wearer field");
        return;
    }
    
    key hud_wearer = (key)llJsonGetValue(message, ["hud_wearer"]);
    if (hud_wearer == NULL_KEY) return;
    
    // Check distance to HUD wearer
    list agent_data = llGetObjectDetails(hud_wearer, [OBJECT_POS]);
    if (llGetListLength(agent_data) == 0) {
        logd("Could not get position for HUD wearer");
        return;
    }
    
    vector hud_wearer_pos = llList2Vector(agent_data, 0);
    vector collar_owner_pos = llGetPos();
    float distance = llVecDist(hud_wearer_pos, collar_owner_pos);
    
    // Only respond if within range
    if (distance > MAX_DETECTION_RANGE) {
        logd("HUD wearer " + llKey2Name(hud_wearer) + " is " + (string)((integer)distance) + "m away (max: " + (string)((integer)MAX_DETECTION_RANGE) + "m) - ignoring");
        return;
    }
    
    logd("HUD wearer " + llKey2Name(hud_wearer) + " is " + (string)((integer)distance) + "m away - responding to scan");
    
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
    
    // Check if this query is for OUR collar (target matches our owner)
    if (target_avatar != CollarOwner) {
        logd("Ignoring query - target " + llKey2Name(target_avatar) + " != our owner " + llKey2Name(CollarOwner));
        return;
    }
    
    logd("Received ACL query from " + llKey2Name(hud_wearer) + " for our collar");
    
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
    
    logd("Received menu request from " + llKey2Name(hud_wearer));
    
    // Trigger the collar's UI to show menu to external user
    trigger_menu_for_external_user(hud_wearer);
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default {
    state_entry() {
        // Clean up any existing listens
        if (AclQueryListenHandle != 0) {
            llListenRemove(AclQueryListenHandle);
        }
        if (MenuRequestListenHandle != 0) {
            llListenRemove(MenuRequestListenHandle);
        }
        
        PendingQueries = [];
        CollarOwner = llGetOwner();
        
        // Listen for external ACL queries and menu requests
        AclQueryListenHandle = llListen(EXTERNAL_ACL_QUERY_CHAN, "", NULL_KEY, "");
        MenuRequestListenHandle = llListen(EXTERNAL_MENU_CHAN, "", NULL_KEY, "");
        
        logd("Remote module initialized");
        logd("Listening on channel " + (string)EXTERNAL_ACL_QUERY_CHAN + " for ACL queries");
        logd("Listening on channel " + (string)EXTERNAL_MENU_CHAN + " for menu requests");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change_mask) {
        if (change_mask & CHANGED_OWNER) {
            llResetScript();
        }
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
            
            return;
        }
        
        // Handle menu requests (only from HUDs we've authorized)
        if (channel == EXTERNAL_MENU_CHAN) {
            if (!json_has(message, ["type"])) return;
            
            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type != "menu_request_external") return;
            
            handle_menu_request_external(message);
            return;
        }
    }
    
    link_message(integer sender_num, integer num, string str, key id) {
        // Handle ACL result from AUTH module
        if (num == AUTH_BUS) {
            if (!json_has(str, ["type"])) return;
            
            string msg_type = llJsonGetValue(str, ["type"]);
            if (msg_type != "acl_result") return;
            
            // Extract ACL information
            if (!json_has(str, ["avatar"])) return;
            
            key avatar_key = (key)llJsonGetValue(str, ["avatar"]);
            
            // Check if this is a response to a pending external query
            integer query_idx = find_pending_query(avatar_key);
            if (query_idx == -1) return;  // Not an external query
            
            // Extract ACL level
            integer level = 0;
            if (json_has(str, ["level"])) {
                level = (integer)llJsonGetValue(str, ["level"]);
            }
            
            // Send response to HUD wearer
            send_external_acl_response(avatar_key, level);
            
            // Clean up pending query
            remove_pending_query(avatar_key);
            return;
        }
    }
}
