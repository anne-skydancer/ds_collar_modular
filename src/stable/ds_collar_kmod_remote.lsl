/* ===============================================================
   MODULE: ds_collar_kmod_remote.lsl (v1.0 SECURITY HARDENING)
   
   PURPOSE: External HUD communication bridge
   
   SECURITY FIXES v1.0:
   - Added ACL verification for menu requests
   - Implemented rate limiting (2s cooldown per user)
   - Added pending query timeout (30s) and max limit (20)
   - Added production debug guard
   - Added range checking to menu requests
   
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
   1. HUD broadcasts collar scan --> Collar responds with owner UUID
   2. HUD sends ACL query --> Collar queries AUTH --> Collar responds with level
   3. HUD sends menu request --> Collar triggers UI for HUD wearer
   =============================================================== */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */
integer AUTH_BUS = 700;
integer UI_BUS = 900;

/* ===============================================================
   EXTERNAL PROTOCOL CHANNELS

   TWO-PHASE DESIGN:
   1. Discovery Phase: Public channels for scanning (all collars listen)
   2. Session Phase: Per-session secure channels (negotiated after HUD selects collar)
   =============================================================== */

// Phase 1: Public discovery channels (fixed, not derived - all collars listen here)
integer PUBLIC_DISCOVERY_CHAN = -8675309;
integer PUBLIC_DISCOVERY_REPLY_CHAN = -8675310;

// Phase 2: Session channels (derived from HUD wearer + collar owner, negotiated per-session)
integer SESSION_BASE_CHAN = -8675320;  // Base channel for session derivation (must match HUD)
integer SESSION_QUERY_CHAN = 0;
integer SESSION_REPLY_CHAN = 0;
integer SESSION_MENU_CHAN = 0;

// Session state
key ActiveSessionHudWearer = NULL_KEY;  // Which HUD wearer has an active session

float MAX_DETECTION_RANGE = 20.0;  // Maximum range in meters for HUD detection

/* ===============================================================
   PROTOCOL MESSAGE TYPES
   =============================================================== */
string ROOT_CONTEXT = "core_root";

/* ===============================================================
   STATE
   =============================================================== */
integer DiscoveryListenHandle = 0;      // Listens on public discovery channel
integer SessionQueryListenHandle = 0;   // Listens on session query channel (after session established)
integer SessionMenuListenHandle = 0;    // Listens on session menu channel (after session established)
key CollarOwner = NULL_KEY;

/* Pending external queries: [hud_wearer_key, hud_object_key, ...] */
list PendingQueries = [];
integer QUERY_STRIDE = 2;

/* Pending menu requests waiting for ACL verification */
list PendingMenuRequests = [];

/* Query timeout tracking: [hud_wearer_key, timestamp, ...] */
list QueryTimestamps = [];
integer MAX_PENDING_QUERIES = 20;
float QUERY_TIMEOUT = 30.0;  // 30 seconds

/* Rate limiting: [avatar_key, timestamp, ...] */
list RequestTimestamps = [];
integer REQUEST_STRIDE = 2;
float REQUEST_COOLDOWN = 2.0;  // 2 seconds between requests per user

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[REMOTE] " + msg);
    return FALSE;
}

integer jsonHas(string json_str, list path) {
    return (llJsonGetValue(json_str, path) != JSON_INVALID);
}

integer now() {
    return llGetUnixTime();
}

/* Derive secure session channels from BOTH HUD wearer and collar owner
   This creates a unique channel per HUD-collar pair, preventing crosstalk
   Must match the HUD's deriveSessionChannel function exactly */
integer deriveSessionChannel(integer base_channel, key hud_wearer, key collar_owner) {
    // Combine both UUIDs to create unique session channel
    integer seed1 = (integer)("0x" + llGetSubString((string)hud_wearer, 0, 7));
    integer seed2 = (integer)("0x" + llGetSubString((string)collar_owner, 0, 7));
    integer combined = (seed1 ^ seed2);  // XOR for uniqueness
    return base_channel + (combined % 1000000);
}

/* ===============================================================
   RATE LIMITING
   =============================================================== */

integer checkRateLimit(key requester) {
    integer now_time = now();
    
    // Find this requester's last request
    integer idx = llListFindList(RequestTimestamps, [requester]);
    
    if (idx != -1) {
        integer last_request = llList2Integer(RequestTimestamps, idx + 1);
        
        if ((now_time - last_request) < REQUEST_COOLDOWN) {
            logd("Rate limit: " + llKey2Name(requester) + " requested too soon");
            return FALSE;  // Rate limited
        }
        
        // Update timestamp
        RequestTimestamps = llListReplaceList(RequestTimestamps, [now_time], idx + 1, idx + 1);
    } else {
        // First request from this user
        RequestTimestamps += [requester, now_time];
        
        // Prune old entries if list gets large
        if (llGetListLength(RequestTimestamps) > 40) {
            RequestTimestamps = llList2List(RequestTimestamps, -40, -1);
        }
    }
    
    return TRUE;  // Allowed
}

/* ===============================================================
   QUERY TIMEOUT & PRUNING
   =============================================================== */

prune_expired_queries(integer now_time) {
    integer idx = 0;
    
    while (idx < llGetListLength(QueryTimestamps)) {
        key hud_wearer = llList2Key(QueryTimestamps, idx);
        integer timestamp = llList2Integer(QueryTimestamps, idx + 1);
        
        if ((now_time - timestamp) > QUERY_TIMEOUT) {
            logd("Pruning expired query for " + llKey2Name(hud_wearer));
            
            // Remove from both lists
            integer query_idx = findPendingQuery(hud_wearer);
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

/* ===============================================================
   QUERY MANAGEMENT
   =============================================================== */

addPendingQuery(key hud_wearer, key hud_object) {
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
            
            logd("Updated pending query for " + llKey2Name(hud_wearer));
            return;
        }
        idx += QUERY_STRIDE;
    }
    
    // Prune expired queries before adding
    prune_expired_queries(now_time);
    
    // Check limit
    if (llGetListLength(PendingQueries) >= (MAX_PENDING_QUERIES * QUERY_STRIDE)) {
        logd("WARNING: Max pending queries reached, dropping oldest");
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
    logd("Added pending query for " + llKey2Name(hud_wearer));
}

integer findPendingQuery(key hud_wearer) {
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

removePendingQuery(key hud_wearer) {
    integer idx = findPendingQuery(hud_wearer);
    if (idx == -1) return;
    
    PendingQueries = llDeleteSubList(PendingQueries, idx, idx + QUERY_STRIDE - 1);
    logd("Removed pending query for " + llKey2Name(hud_wearer));
}

/* ===============================================================
   INTERNAL ACL COMMUNICATION
   =============================================================== */

requestInternalAcl(key avatar_key) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_query",
        "avatar", (string)avatar_key,
        "id", "remote_" + (string)avatar_key
    ]);
    
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
    logd("Requested internal ACL for " + llKey2Name(avatar_key));
}

sendExternalAclResponse(key hud_wearer, integer level) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "acl_result_external",
        "avatar", (string)hud_wearer,
        "level", (string)level,
        "collar_owner", (string)CollarOwner
    ]);

    // CRITICAL: Derive reply channel from hud_wearer parameter, not global SESSION_REPLY_CHAN
    // This prevents race conditions when multiple HUDs establish sessions concurrently
    integer hud_session_query = deriveSessionChannel(SESSION_BASE_CHAN, hud_wearer, CollarOwner);
    integer hud_session_reply = hud_session_query - 1;

    // Send response on THIS hud's session reply channel
    llRegionSay(hud_session_reply, msg);
    logd("Sent ACL response: hud_wearer=" + llKey2Name(hud_wearer) + ", level=" + (string)level + " on channel " + (string)hud_session_reply);
}

/* ===============================================================
   MENU TRIGGERING
   =============================================================== */

triggerMenuForExternalUser(key user_key) {
    // Send start message to UI module with external user
    string msg = llList2Json(JSON_OBJECT, [
        "type", "start",
        "context", ROOT_CONTEXT
    ]);
    
    // Pass the external user's key as the id parameter
    llMessageLinked(LINK_SET, UI_BUS, msg, user_key);
    
    logd("Triggered menu for external user: " + llKey2Name(user_key));
}

/* ===============================================================
   SESSION MANAGEMENT
   =============================================================== */

handleSessionEstablish(string message) {
    // Extract session parameters
    if (!jsonHas(message, ["hud_wearer"])) return;
    if (!jsonHas(message, ["collar_owner"])) return;

    key hud_wearer = (key)llJsonGetValue(message, ["hud_wearer"]);
    key collar_owner = (key)llJsonGetValue(message, ["collar_owner"]);

    // Verify this session is for OUR collar
    if (collar_owner != CollarOwner) {
        logd("Ignoring session - collar_owner mismatch");
        return;
    }

    // SECURITY: Rate limit check
    if (!checkRateLimit(hud_wearer)) return;

    logd("Establishing session with HUD wearer: " + llKey2Name(hud_wearer));

    // Derive session channels (must match HUD's calculation exactly)
    SESSION_QUERY_CHAN = deriveSessionChannel(SESSION_BASE_CHAN, hud_wearer, CollarOwner);
    SESSION_REPLY_CHAN = SESSION_QUERY_CHAN - 1;
    SESSION_MENU_CHAN = SESSION_QUERY_CHAN - 2;

    // Clean up old session listeners
    if (SessionQueryListenHandle != 0) {
        llListenRemove(SessionQueryListenHandle);
    }
    if (SessionMenuListenHandle != 0) {
        llListenRemove(SessionMenuListenHandle);
    }

    // Set up new session listeners
    SessionQueryListenHandle = llListen(SESSION_QUERY_CHAN, "", NULL_KEY, "");
    SessionMenuListenHandle = llListen(SESSION_MENU_CHAN, "", NULL_KEY, "");

    ActiveSessionHudWearer = hud_wearer;

    logd("Session established - Query=" + (string)SESSION_QUERY_CHAN +
         " Reply=" + (string)SESSION_REPLY_CHAN +
         " Menu=" + (string)SESSION_MENU_CHAN);

    // Send acknowledgment to HUD on public reply channel
    string ack_msg = llList2Json(JSON_OBJECT, [
        "type", "session_established_ack",
        "collar_owner", (string)CollarOwner,
        "hud_wearer", (string)hud_wearer
    ]);

    llRegionSay(PUBLIC_DISCOVERY_REPLY_CHAN, ack_msg);
    logd("Sent session acknowledgment to " + llKey2Name(hud_wearer));
}

/* ===============================================================
   EXTERNAL PROTOCOL HANDLERS
   =============================================================== */

handleCollarScan(string message) {
    // Extract HUD wearer key
    if (!jsonHas(message, ["hud_wearer"])) {
        logd("collar_scan missing hud_wearer field");
        return;
    }
    
    key hud_wearer = (key)llJsonGetValue(message, ["hud_wearer"]);
    if (hud_wearer == NULL_KEY) return;
    
    // SECURITY: Rate limit check
    if (!checkRateLimit(hud_wearer)) return;
    
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

    llRegionSay(PUBLIC_DISCOVERY_REPLY_CHAN, response);
}

handleAclQueryExternal(string message) {
    // Extract query parameters
    if (!jsonHas(message, ["avatar"])) return;
    if (!jsonHas(message, ["hud"])) return;
    if (!jsonHas(message, ["target_avatar"])) return;
    
    key hud_wearer = (key)llJsonGetValue(message, ["avatar"]);
    key hud_object = (key)llJsonGetValue(message, ["hud"]);
    key target_avatar = (key)llJsonGetValue(message, ["target_avatar"]);
    
    if (hud_wearer == NULL_KEY) return;
    if (hud_object == NULL_KEY) return;
    if (target_avatar == NULL_KEY) return;
    
    // SECURITY: Rate limit check
    if (!checkRateLimit(hud_wearer)) return;
    
    // Check if this query is for OUR collar (target matches our owner)
    if (target_avatar != CollarOwner) {
        logd("Ignoring query - target " + llKey2Name(target_avatar) + " != our owner " + llKey2Name(CollarOwner));
        return;
    }
    
    logd("Received ACL query from " + llKey2Name(hud_wearer) + " for our collar");
    
    // Store pending query
    addPendingQuery(hud_wearer, hud_object);
    
    // Request ACL from internal AUTH module
    requestInternalAcl(hud_wearer);
}

handleMenuRequestExternal(string message) {
    // Extract menu request parameters
    if (!jsonHas(message, ["avatar"])) return;
    
    key hud_wearer = (key)llJsonGetValue(message, ["avatar"]);
    if (hud_wearer == NULL_KEY) return;
    
    // SECURITY: Rate limit check
    if (!checkRateLimit(hud_wearer)) return;
    
    // SECURITY: Check range first
    list agent_data = llGetObjectDetails(hud_wearer, [OBJECT_POS]);
    if (llGetListLength(agent_data) == 0) {
        logd("Cannot verify HUD wearer position for menu request");
        return;
    }
    
    vector hud_wearer_pos = llList2Vector(agent_data, 0);
    float distance = llVecDist(hud_wearer_pos, llGetPos());
    
    if (distance > MAX_DETECTION_RANGE) {
        logd("Menu request from " + llKey2Name(hud_wearer) + 
             " ignored - " + (string)((integer)distance) + "m away (max: " + 
             (string)((integer)MAX_DETECTION_RANGE) + "m)");
        return;
    }
    
    logd("Received menu request from " + llKey2Name(hud_wearer) + 
         " at " + (string)((integer)distance) + "m");
    
    // SECURITY: Verify ACL before triggering menu
    if (llListFindList(PendingMenuRequests, [hud_wearer]) == -1) {
        PendingMenuRequests += [hud_wearer];
        requestInternalAcl(hud_wearer);
    }
}

/* ===============================================================
   EVENTS
   =============================================================== */

default {
    state_entry() {
        // Clean up any existing listens
        if (DiscoveryListenHandle != 0) {
            llListenRemove(DiscoveryListenHandle);
        }
        if (SessionQueryListenHandle != 0) {
            llListenRemove(SessionQueryListenHandle);
        }
        if (SessionMenuListenHandle != 0) {
            llListenRemove(SessionMenuListenHandle);
        }

        // Initialize state
        PendingQueries = [];
        PendingMenuRequests = [];
        QueryTimestamps = [];
        RequestTimestamps = [];
        CollarOwner = llGetOwner();

        // Reset session state
        SESSION_QUERY_CHAN = 0;
        SESSION_REPLY_CHAN = 0;
        SESSION_MENU_CHAN = 0;
        ActiveSessionHudWearer = NULL_KEY;

        // Phase 1: Listen on PUBLIC discovery channel (all collars listen here)
        DiscoveryListenHandle = llListen(PUBLIC_DISCOVERY_CHAN, "", NULL_KEY, "");

        // Start timer for periodic query pruning
        llSetTimerEvent(60.0);  // Check every 60 seconds

        logd("Remote module initialized");
        logd("Listening on public discovery channel: " + (string)PUBLIC_DISCOVERY_CHAN);
        logd("Session channels will be negotiated when HUD connects");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change_mask) {
        if (change_mask & CHANGED_OWNER) {
            llResetScript();
        }
    }
    
    timer() {
        // Periodic query pruning
        prune_expired_queries(now());
    }
    
    listen(integer channel, string name, key speaker_id, string message) {
        // Phase 1: Handle public discovery channel messages
        if (channel == PUBLIC_DISCOVERY_CHAN) {
            if (!jsonHas(message, ["type"])) return;
            string msg_type = llJsonGetValue(message, ["type"]);

            // Respond to collar scan
            if (msg_type == "collar_scan") {
                handleCollarScan(message);
                return;
            }

            // Handle session establishment
            if (msg_type == "session_establish") {
                handleSessionEstablish(message);
                return;
            }

            return;
        }

        // Phase 2: Handle session channel messages (after session established)
        if (channel == SESSION_QUERY_CHAN) {
            if (!jsonHas(message, ["type"])) return;
            string msg_type = llJsonGetValue(message, ["type"]);

            // Handle ACL queries
            if (msg_type == "acl_query_external") {
                handleAclQueryExternal(message);
                return;
            }

            return;
        }

        // Handle menu requests on session menu channel
        if (channel == SESSION_MENU_CHAN) {
            if (!jsonHas(message, ["type"])) return;

            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type != "menu_request_external") return;

            handleMenuRequestExternal(message);
            return;
        }
    }
    
    link_message(integer sender_num, integer num, string str, key id) {
        // Handle ACL result from AUTH module
        if (num == AUTH_BUS) {
            if (!jsonHas(str, ["type"])) return;
            
            string msg_type = llJsonGetValue(str, ["type"]);
            if (msg_type != "acl_result") return;
            
            // Extract ACL information
            if (!jsonHas(str, ["avatar"])) return;
            
            key avatar_key = (key)llJsonGetValue(str, ["avatar"]);
            
            // Extract ACL level
            integer level = 0;
            if (jsonHas(str, ["level"])) {
                level = (integer)llJsonGetValue(str, ["level"]);
            }
            
            // Check if this is a menu request ACL verification
            integer menu_idx = llListFindList(PendingMenuRequests, [avatar_key]);
            if (menu_idx != -1) {
                // This is a menu request ACL check
                PendingMenuRequests = llDeleteSubList(PendingMenuRequests, menu_idx, menu_idx);
                
                // Only trigger menu if ACL >= 1 (public or higher)
                if (level >= 1) {
                    triggerMenuForExternalUser(avatar_key);
                    logd("Menu request approved for " + llKey2Name(avatar_key) + " (ACL " + (string)level + ")");
                } else {
                    logd("Menu request denied for " + llKey2Name(avatar_key) + " (ACL " + (string)level + ")");
                }
                return;
            }
            
            // Check if this is a response to a pending external query
            integer query_idx = findPendingQuery(avatar_key);
            if (query_idx == -1) return;  // Not an external query
            
            // Send response to HUD wearer
            sendExternalAclResponse(avatar_key, level);
            
            // Clean up pending query
            removePendingQuery(avatar_key);
            return;
        }
    }
}
