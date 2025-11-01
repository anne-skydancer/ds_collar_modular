/* =============================================================================
   MODULE: ds_collar_kmod_particles.lsl (v2.3 SECURITY HARDENING)
   
   ROLE: Visual connection renderer (chains, beams, ropes) + Lockmeister protocol
   
   SECURITY FIXES v2.3:
   - Added needs_timer() helper for proper timer cleanup
   - Fixed timer not stopping when both sources inactive
   - Added explicit cleanup before owner change reset
   - Added production debug guard (dual-gate logging)
   
   SECURITY FIXES v2.2:
   - Lockmeister now requires explicit authorization before accepting responses
   - Added explicit release command handling
   - Improved target validation in particles_update
   - Fixed timer cleanup logic
   - Enhanced handle validation (must match authorized controller)
   
   PURPOSE: Provides particle system rendering for any plugin that needs
            visual connections between wearer and target (avatar or object).
            Also handles Lockmeister protocol for compatibility with LM items.
   
   USED BY:
   - Leash plugin (chain to leasher)
   - Coffle plugin (chain between subs)
   - Parking plugin (chain to post/object)
   
   PROTOCOLS:
   - DS native (via UI_BUS messages) - draws from collar to avatar
   - Lockmeister v2 (channel -8888) - draws from leashpoint to responding prim
   
   CHANNELS:
   - 900 (UI_BUS): Particle control messages
   - -8888 (Lockmeister): LM protocol compatibility
   
   CHANGELOG v2.2:
   - SECURITY: Lockmeister now validates authorization before accepting
   - Added explicit release command handling
   - Fixed target validation in particles_update
   - Improved timer cleanup logic

   KANBAN MIGRATION (v3.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "particles";

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

string kDeltaSet(string key, string val) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", key,
        "value", val
    ]);
}

string kDeltaAdd(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_add",
        "key", key,
        "elem", elem
    ]);
}

string kDeltaDel(string key, string elem) {
    return llList2Json(JSON_OBJECT, [
        "op", "list_remove",
        "key", key,
        "elem", elem
    ]);
}

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development

/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   CONSOLIDATED ABI
   â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;

/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   CONSTANTS
   â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */
float PARTICLE_UPDATE_RATE = 0.5;  // Update every 0.5 seconds

// Default chain texture
string CHAIN_TEXTURE = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";

// Lockmeister protocol
integer LEASH_CHAN_LM = -8888;
integer LM_PING_INTERVAL = 8;  // Ping every 8 seconds

/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   STATE
   â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */
integer ParticlesActive = FALSE;
key TargetKey = NULL_KEY;
string SourcePlugin = "";
string ParticleStyle = "chain";
integer LeashpointLink = 0;

// Lockmeister state
integer LmListen = 0;
integer LmActive = FALSE;
key LmController = NULL_KEY;  // Who is authorized to control the leash
key LmTargetPrim = NULL_KEY;  // Which prim we're leashing to
integer LmLastPing = 0;
integer LmAuthorized = FALSE;  // NEW: Explicit authorization flag

/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   HELPERS
   â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[PARTICLES] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer now() {
    return llGetUnixTime();
}

// Helper to determine if timer should be running
integer needs_timer() {
    if (LmActive) return TRUE;  // Lockmeister needs pinging
    if (SourcePlugin != "" && ParticlesActive) return TRUE;  // DS rendering active
    return FALSE;
}

/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   LOCKMEISTER PROTOCOL (IMPROVED SECURITY)
   â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */

open_lm_listen() {
    if (LmListen == 0) {
        LmListen = llListen(LEASH_CHAN_LM, "", NULL_KEY, "");
        logd("Lockmeister listen opened");
    }
}

close_lm_listen() {
    if (LmListen != 0) {
        llListenRemove(LmListen);
        LmListen = 0;
        logd("Lockmeister listen closed");
    }
}

lm_ping() {
    if (!LmActive || LmController == NULL_KEY) return;
    
    integer t = now();
    if ((t - LmLastPing) < LM_PING_INTERVAL) return;
    LmLastPing = t;
    
    if (llGetAgentSize(LmController) != ZERO_VECTOR) {
        string wearer = (string)llGetOwner();
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "collar");
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "handle");
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "|LMV2|RequestPoint|handle");
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "|LMV2|RequestPoint|collar");
        logd("LM ping sent");
    }
}

handle_lm_message(key id, string msg) {
    key owner_key = llGetOwnerKey(id);
    
    // Lockmeister protocol sends: "<holder_uuid>handle ok" or "<holder_uuid>collar ok"
    // Or release: "<holder_uuid>handle free" or "<holder_uuid>collar free"
    // Extract the UUID from the first 36 characters
    string msg_uuid = llGetSubString(msg, 0, 35);
    string protocol = llGetSubString(msg, 36, -1);
    
    // Validate UUID format (basic check)
    if (llStringLength(msg_uuid) != 36) return;
    
    // Verify the UUID in message matches the object owner
    if ((key)msg_uuid != owner_key) {
        logd("LM message UUID mismatch: " + msg_uuid + " vs " + (string)owner_key);
        return;
    }
    
    // Handle explicit release commands
    if (protocol == "collar free" || protocol == "handle free") {
        if (LmActive && id == LmTargetPrim) {
            logd("LM explicit release received from " + (string)id);
            
            LmActive = FALSE;
            LmController = NULL_KEY;
            LmTargetPrim = NULL_KEY;
            LmAuthorized = FALSE;
            close_lm_listen();
            
            // Clear particles
            render_chain_particles(NULL_KEY);

            // Notify leash plugin
            kSend(CONTEXT, "", UI_BUS, kPayload([]), NULL_KEY);
            
            // Stop timer if no other source active
            if (SourcePlugin == "lockmeister" || SourcePlugin == "") {
                SourcePlugin = "";
                TargetKey = NULL_KEY;
            }
            if (!needs_timer()) {
                llSetTimerEvent(0.0);
                logd("Timer stopped - no active sources");
            }
        }
        return;
    }
    
    // Lockmeister grab response: "collar ok" or "handle ok"
    if (protocol == "collar ok" || protocol == "handle ok") {
        // SECURITY: Only accept if Lockmeister mode was explicitly authorized
        if (!LmAuthorized) {
            logd("Rejected LM response - not authorized. Call lm_enable first.");
            return;
        }
        
        // CRITICAL: Only accept handles belonging to the authorized controller
        if (LmController != NULL_KEY && owner_key != LmController) {
            logd("Handle belongs to " + llKey2Name(owner_key) + 
                 ", but authorized controller is " + llKey2Name(LmController) + " - ignoring");
            return;
        }
        
        // If we're already locked onto a handle, ONLY accept responses from THAT handle
        if (LmActive && LmTargetPrim != NULL_KEY) {
            if (id != LmTargetPrim) {
                logd("Already locked to " + (string)LmTargetPrim + ", ignoring other handle " + (string)id);
                return;
            }
            // Same handle confirming - just update ping time
            LmLastPing = now();
            return;
        }
        
        logd("LM response received from object " + (string)id + " (owner: " + llKey2Name(owner_key) + ")");
        
        // Priority check: If DS native is already rendering to a holder prim, don't override
        if (SourcePlugin == "core_leash" && TargetKey != NULL_KEY) {
            // Check if current target is a prim (not avatar)
            if (llGetAgentSize(TargetKey) == ZERO_VECTOR) {
                logd("DS holder already active, ignoring Lockmeister response");
                return;
            }
        }
        
        // Start particles to the responding PRIM (not the owner avatar)
        LmActive = TRUE;
        LmController = owner_key;  // Track who controls it
        LmTargetPrim = id;         // Track the actual prim
        LmLastPing = now();
        
        TargetKey = id;  // Target the responding prim
        ParticlesActive = TRUE;
        SourcePlugin = "lockmeister";
        
        render_chain_particles(id);

        // Notify leash plugin
        kSend(CONTEXT, "", UI_BUS,
            kPayload([
                "controller", (string)owner_key,
                "prim", (string)id
            ]),
            NULL_KEY
        );
    }
}

/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   LEASHPOINT DETECTION
   â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */

integer find_leashpoint_link() {
    integer i = 2;
    integer prim_count = llGetNumberOfPrims();
    
    while (i <= prim_count) {
        list params = llGetLinkPrimitiveParams(i, [PRIM_NAME, PRIM_DESC]);
        string name = llToLower(llStringTrim(llList2String(params, 0), STRING_TRIM));
        string desc = llToLower(llStringTrim(llList2String(params, 1), STRING_TRIM));
        
        if (name == "leashpoint" && desc == "leashpoint") {
            logd("Found leashpoint at link " + (string)i);
            return i;
        }
        i = i + 1;
    }
    
    logd("No leashpoint found, using LINK_ROOT");
    return LINK_ROOT;
}

/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   PARTICLE RENDERING
   â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */

render_chain_particles(key target) {
    if (LeashpointLink == 0) {
        LeashpointLink = find_leashpoint_link();
    }
    
    if (target == NULL_KEY) {
        // Clear particles
        llLinkParticleSystem(LeashpointLink, []);
        ParticlesActive = FALSE;
        logd("Particles cleared");
        return;
    }
    
    // Render chain to target
    llLinkParticleSystem(LeashpointLink, [
        PSYS_SRC_PATTERN, PSYS_SRC_PATTERN_DROP,
        PSYS_SRC_TEXTURE, CHAIN_TEXTURE,
        PSYS_SRC_BURST_RATE, 0.0,
        PSYS_SRC_BURST_PART_COUNT, 1,
        PSYS_PART_START_ALPHA, 1.0,
        PSYS_PART_END_ALPHA, 1.0,
        PSYS_PART_MAX_AGE, 2.6,
        PSYS_PART_START_SCALE, <0.07, 0.07, 0.07>,
        PSYS_PART_END_SCALE, <0.07, 0.07, 0.07>,
        PSYS_PART_START_COLOR, <1, 1, 1>,
        PSYS_PART_END_COLOR, <1, 1, 1>,
        PSYS_SRC_ACCEL, <0, 0, -1.25>,
        PSYS_PART_FLAGS, 
            PSYS_PART_INTERP_COLOR_MASK |
            PSYS_PART_FOLLOW_SRC_MASK |
            PSYS_PART_TARGET_POS_MASK |
            PSYS_PART_FOLLOW_VELOCITY_MASK |
            PSYS_PART_RIBBON_MASK,
        PSYS_SRC_TARGET_KEY, target
    ]);
    
    ParticlesActive = TRUE;
    logd("Particles rendered to " + (string)target);
}

/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   MESSAGE HANDLERS
   â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */

handle_particles_start(string payload) {
    if (!json_has(payload, ["source"]) || !json_has(payload, ["target"])) {
        logd("ERROR: particles_start missing source or target");
        return;
    }

    string source = llJsonGetValue(payload, ["source"]);
    key target = (key)llJsonGetValue(payload, ["target"]);
    
    // Validate target exists in-world
    list details = llGetObjectDetails(target, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        logd("ERROR: Target " + (string)target + " not found in-world");
        return;
    }
    
    // Priority: Lockmeister < DS leash
    if (SourcePlugin == "lockmeister" && source == "core_leash") {
        logd("Overriding Lockmeister with DS leash");
        if (LmActive) {
            LmActive = FALSE;
            LmController = NULL_KEY;
            LmTargetPrim = NULL_KEY;
            LmAuthorized = FALSE;
            close_lm_listen();
        }
    }
    else if (SourcePlugin != "" && SourcePlugin != source) {
        logd("Ignoring start request from " + source + " (active source: " + SourcePlugin + ")");
        return;
    }
    
    SourcePlugin = source;
    TargetKey = target;

    if (json_has(payload, ["style"])) {
        ParticleStyle = llJsonGetValue(payload, ["style"]);
    }
    else {
        ParticleStyle = "chain";
    }
    
    logd("Start request from " + SourcePlugin + " to target " + (string)TargetKey);
    
    render_chain_particles(TargetKey);
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
}

handle_particles_stop(string payload) {
    if (!json_has(payload, ["source"])) {
        logd("ERROR: particles_stop missing source");
        return;
    }

    string source = llJsonGetValue(payload, ["source"]);
    
    // Only stop if request is from the same plugin that started it
    if (source != SourcePlugin) {
        logd("Ignoring stop request from " + source + " (active source: " + SourcePlugin + ")");
        return;
    }
    
    logd("Stop request from " + source);
    
    render_chain_particles(NULL_KEY);
    
    // Always clear source state when stopping
    SourcePlugin = "";
    TargetKey = NULL_KEY;
    
    // Stop timer if nothing needs it
    if (!needs_timer()) {
        llSetTimerEvent(0.0);
        logd("Timer stopped - no active sources");
    }
}

handle_particles_update(string payload) {
    if (!json_has(payload, ["target"])) {
        logd("ERROR: particles_update missing target");
        return;
    }

    key new_target = (key)llJsonGetValue(payload, ["target"]);
    
    // SECURITY: Validate target exists in-world
    list details = llGetObjectDetails(new_target, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        logd("ERROR: Update target " + (string)new_target + " not found in-world");
        return;
    }
    
    if (new_target != TargetKey) {
        logd("Updating target to: " + (string)new_target);
        TargetKey = new_target;
        render_chain_particles(TargetKey);
    }
}

handle_lm_enable(string payload) {
    // Enable Lockmeister listening
    if (!json_has(payload, ["controller"])) {
        logd("ERROR: lm_enable missing controller");
        return;
    }

    LmController = (key)llJsonGetValue(payload, ["controller"]);
    LmAuthorized = TRUE;  // Mark as authorized
    open_lm_listen();
    
    // Start pinging
    LmLastPing = now();
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
    
    logd("Lockmeister AUTHORIZED for " + llKey2Name(LmController));
}

handle_lm_disable() {
    close_lm_listen();
    
    // If Lockmeister was active, clear the particles
    if (LmActive) {
        LmActive = FALSE;
        LmController = NULL_KEY;
        LmTargetPrim = NULL_KEY;
        LmAuthorized = FALSE;
        
        // Clear particles if we were the active source
        if (SourcePlugin == "lockmeister") {
            render_chain_particles(NULL_KEY);
            SourcePlugin = "";
            TargetKey = NULL_KEY;
        }
    }
    
    LmAuthorized = FALSE;  // Clear authorization
    
    // Check if timer should stop
    if (!needs_timer()) {
        llSetTimerEvent(0.0);
        logd("Timer stopped - no active sources");
    }
    
    logd("Lockmeister disabled and deauthorized");
}

/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
   EVENTS
   â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */

default
{
    state_entry() {
        ParticlesActive = FALSE;
        TargetKey = NULL_KEY;
        SourcePlugin = "";
        LeashpointLink = 0;
        
        LmActive = FALSE;
        LmController = NULL_KEY;
        LmTargetPrim = NULL_KEY;
        LmAuthorized = FALSE;
        close_lm_listen();
        
        logd("Particles module ready (v2.2 SECURITY PATCH)");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            // Clear authorization before reset (defensive coding)
            LmAuthorized = FALSE;
            LmController = NULL_KEY;
            close_lm_listen();
            llResetScript();
        }
        
        // If linkset changed, re-detect leashpoint
        if (change & CHANGED_LINK) {
            LeashpointLink = 0;
            if (ParticlesActive) {
                LeashpointLink = find_leashpoint_link();
                render_chain_particles(TargetKey);
            }
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        // Route by channel + payload structure

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE) {
            // Soft reset: has "reset" marker
            if (json_has(payload, ["reset"])) {
                llResetScript();
            }
            return;
        }

        // Only listen on UI_BUS
        if (num != UI_BUS) return;

        // Route by payload structure (check for specific fields)
        if (json_has(payload, ["source"]) && json_has(payload, ["target"])) {
            // particles_start: has "source" and "target" fields
            handle_particles_start(payload);
        }
        else if (json_has(payload, ["source"]) && !json_has(payload, ["target"])) {
            // particles_stop: has "source" but no "target"
            handle_particles_stop(payload);
        }
        else if (json_has(payload, ["target"]) && !json_has(payload, ["source"])) {
            // particles_update: has "target" but no "source"
            handle_particles_update(payload);
        }
        else if (json_has(payload, ["controller"])) {
            // lm_enable: has "controller" field
            handle_lm_enable(payload);
        }
        else if (payload == "{}") {
            // lm_disable: empty payload
            handle_lm_disable();
        }
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (channel == LEASH_CHAN_LM) {
            handle_lm_message(id, msg);
        }
    }
    
    timer() {
        // Lockmeister ping
        if (LmActive) {
            lm_ping();
        }
        
        // Periodic validation - verify target still exists
        if (ParticlesActive && TargetKey != NULL_KEY) {
            list details = llGetObjectDetails(TargetKey, [OBJECT_POS]);
            if (llGetListLength(details) == 0) {
                // Target disappeared (offsim or logged out)
                logd("Target lost, clearing particles");
                render_chain_particles(NULL_KEY);
                
                // If Lockmeister was active, stop it
                if (LmActive) {
                    LmActive = FALSE;
                    LmController = NULL_KEY;
                    LmTargetPrim = NULL_KEY;
                    LmAuthorized = FALSE;
                    close_lm_listen();

                    // Notify leash plugin
                    kSend(CONTEXT, "", UI_BUS, kPayload([]), NULL_KEY);
                }
                
                // Always cleanup when target is lost
                SourcePlugin = "";
                TargetKey = NULL_KEY;
                
                // Only stop timer if nothing needs it
                if (!needs_timer()) {
                    llSetTimerEvent(0.0);
                    logd("Timer stopped - no active sources");
                }
            }
        }
    }
}
