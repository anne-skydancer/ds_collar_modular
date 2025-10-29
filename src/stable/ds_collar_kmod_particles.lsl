/* ===============================================================
   MODULE: ds_collar_kmod_particles.lsl (v1.0 SECURITY HARDENING)
   
   PURPOSE: Visual connection renderer (chains, beams, ropes) + Lockmeister protocol
   
   SECURITY FIXES v1.0:
   - Added needsTimer() helper for proper timer cleanup
   - Fixed timer not stopping when both sources inactive
   - Added explicit cleanup before owner change reset
   - Added production debug guard (dual-gate logging)
   
   SECURITY FIXES v1.0:
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
   
   CHANGELOG v1.0:
   - SECURITY: Lockmeister now validates authorization before accepting
   - Added explicit release command handling
   - Fixed target validation in particles_update
   - Improved timer cleanup logic
   
   =============================================================== */

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development

/* ===============================================================
   CONSOLIDATED ABI
   =============================================================== */
integer UI_BUS = 900;

/* ===============================================================
   CONSTANTS
   =============================================================== */
float PARTICLE_UPDATE_RATE = 0.5;  // Update every 0.5 seconds

// Default chain texture
string CHAIN_TEXTURE = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";

// Lockmeister protocol
integer LEASH_CHAN_LM = -8888;
integer LM_PING_INTERVAL = 8;  // Ping every 8 seconds

/* ===============================================================
   STATE
   =============================================================== */
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

/* ===============================================================
   HELPERS
   =============================================================== */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[PARTICLES] " + msg);
    return FALSE;
}

integer jsonHas(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer now() {
    return llGetUnixTime();
}

// Helper to determine if timer should be running
integer needsTimer() {
    if (LmActive) return TRUE;  // Lockmeister needs pinging
    if (SourcePlugin != "" && ParticlesActive) return TRUE;  // DS rendering active
    return FALSE;
}

/* ===============================================================
   LOCKMEISTER PROTOCOL (IMPROVED SECURITY)
   =============================================================== */

openLmListen() {
    if (LmListen == 0) {
        LmListen = llListen(LEASH_CHAN_LM, "", NULL_KEY, "");
        logd("Lockmeister listen opened");
    }
}

closeLmListen() {
    if (LmListen != 0) {
        llListenRemove(LmListen);
        LmListen = 0;
        logd("Lockmeister listen closed");
    }
}

lmPing() {
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

handleLmMessage(key id, string msg) {
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
            closeLmListen();
            
            // Clear particles
            renderChainParticles(NULL_KEY);
            
            // Notify leash plugin
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "lm_released"
            ]), NULL_KEY);
            
            // Stop timer if no other source active
            if (SourcePlugin == "lockmeister" || SourcePlugin == "") {
                SourcePlugin = "";
                TargetKey = NULL_KEY;
            }
            if (!needsTimer()) {
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
        
        renderChainParticles(id);
        
        // Notify leash plugin
        string notify_msg = llList2Json(JSON_OBJECT, [
            "type", "lm_grabbed",
            "controller", (string)owner_key,
            "prim", (string)id
        ]);
        llMessageLinked(LINK_SET, UI_BUS, notify_msg, NULL_KEY);
    }
}

/* ===============================================================
   LEASHPOINT DETECTION
   =============================================================== */

integer findLeashpointLink() {
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

/* ===============================================================
   PARTICLE RENDERING
   =============================================================== */

renderChainParticles(key target) {
    if (LeashpointLink == 0) {
        LeashpointLink = findLeashpointLink();
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

/* ===============================================================
   MESSAGE HANDLERS
   =============================================================== */

handleParticlesStart(string msg) {
    if (!jsonHas(msg, ["source"]) || !jsonHas(msg, ["target"])) {
        logd("ERROR: particles_start missing source or target");
        return;
    }
    
    string source = llJsonGetValue(msg, ["source"]);
    key target = (key)llJsonGetValue(msg, ["target"]);
    
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
            closeLmListen();
        }
    }
    else if (SourcePlugin != "" && SourcePlugin != source) {
        logd("Ignoring start request from " + source + " (active source: " + SourcePlugin + ")");
        return;
    }
    
    SourcePlugin = source;
    TargetKey = target;
    
    if (jsonHas(msg, ["style"])) {
        ParticleStyle = llJsonGetValue(msg, ["style"]);
    }
    else {
        ParticleStyle = "chain";
    }
    
    logd("Start request from " + SourcePlugin + " to target " + (string)TargetKey);
    
    renderChainParticles(TargetKey);
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
}

handleParticlesStop(string msg) {
    if (!jsonHas(msg, ["source"])) {
        logd("ERROR: particles_stop missing source");
        return;
    }
    
    string source = llJsonGetValue(msg, ["source"]);
    
    // Only stop if request is from the same plugin that started it
    if (source != SourcePlugin) {
        logd("Ignoring stop request from " + source + " (active source: " + SourcePlugin + ")");
        return;
    }
    
    logd("Stop request from " + source);
    
    renderChainParticles(NULL_KEY);
    
    // Always clear source state when stopping
    SourcePlugin = "";
    TargetKey = NULL_KEY;
    
    // Stop timer if nothing needs it
    if (!needsTimer()) {
        llSetTimerEvent(0.0);
        logd("Timer stopped - no active sources");
    }
}

handleParticlesUpdate(string msg) {
    if (!jsonHas(msg, ["target"])) {
        logd("ERROR: particles_update missing target");
        return;
    }
    
    key new_target = (key)llJsonGetValue(msg, ["target"]);
    
    // SECURITY: Validate target exists in-world
    list details = llGetObjectDetails(new_target, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        logd("ERROR: Update target " + (string)new_target + " not found in-world");
        return;
    }
    
    if (new_target != TargetKey) {
        logd("Updating target to: " + (string)new_target);
        TargetKey = new_target;
        renderChainParticles(TargetKey);
    }
}

handleLmEnable(string msg) {
    // Enable Lockmeister listening
    if (!jsonHas(msg, ["controller"])) {
        logd("ERROR: lm_enable missing controller");
        return;
    }
    
    LmController = (key)llJsonGetValue(msg, ["controller"]);
    LmAuthorized = TRUE;  // Mark as authorized
    openLmListen();
    
    // Start pinging
    LmLastPing = now();
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
    
    logd("Lockmeister AUTHORIZED for " + llKey2Name(LmController));
}

handleLmDisable() {
    closeLmListen();
    
    // If Lockmeister was active, clear the particles
    if (LmActive) {
        LmActive = FALSE;
        LmController = NULL_KEY;
        LmTargetPrim = NULL_KEY;
        LmAuthorized = FALSE;
        
        // Clear particles if we were the active source
        if (SourcePlugin == "lockmeister") {
            renderChainParticles(NULL_KEY);
            SourcePlugin = "";
            TargetKey = NULL_KEY;
        }
    }
    
    LmAuthorized = FALSE;  // Clear authorization
    
    // Check if timer should stop
    if (!needsTimer()) {
        llSetTimerEvent(0.0);
        logd("Timer stopped - no active sources");
    }
    
    logd("Lockmeister disabled and deauthorized");
}

/* ===============================================================
   EVENTS
   =============================================================== */

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
        closeLmListen();
        
        logd("Particles module ready (v1.0 SECURITY PATCH)");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            // Clear authorization before reset (defensive coding)
            LmAuthorized = FALSE;
            LmController = NULL_KEY;
            closeLmListen();
            llResetScript();
        }
        
        // If linkset changed, re-detect leashpoint
        if (change & CHANGED_LINK) {
            LeashpointLink = 0;
            if (ParticlesActive) {
                LeashpointLink = findLeashpointLink();
                renderChainParticles(TargetKey);
            }
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        // Only listen on UI_BUS
        if (num != UI_BUS) return;
        
        if (!jsonHas(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type == "particles_start") {
            handleParticlesStart(msg);
        }
        else if (msg_type == "particles_stop") {
            handleParticlesStop(msg);
        }
        else if (msg_type == "particles_update") {
            handleParticlesUpdate(msg);
        }
        else if (msg_type == "lm_enable") {
            handleLmEnable(msg);
        }
        else if (msg_type == "lm_disable") {
            handleLmDisable();
        }
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (channel == LEASH_CHAN_LM) {
            handleLmMessage(id, msg);
        }
    }
    
    timer() {
        // Lockmeister ping
        if (LmActive) {
            lmPing();
        }
        
        // Periodic validation - verify target still exists
        if (ParticlesActive && TargetKey != NULL_KEY) {
            list details = llGetObjectDetails(TargetKey, [OBJECT_POS]);
            if (llGetListLength(details) == 0) {
                // Target disappeared (offsim or logged out)
                logd("Target lost, clearing particles");
                renderChainParticles(NULL_KEY);
                
                // If Lockmeister was active, stop it
                if (LmActive) {
                    LmActive = FALSE;
                    LmController = NULL_KEY;
                    LmTargetPrim = NULL_KEY;
                    LmAuthorized = FALSE;
                    closeLmListen();
                    
                    // Notify leash plugin
                    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                        "type", "lm_released"
                    ]), NULL_KEY);
                }
                
                // Always cleanup when target is lost
                SourcePlugin = "";
                TargetKey = NULL_KEY;
                
                // Only stop timer if nothing needs it
                if (!needsTimer()) {
                    llSetTimerEvent(0.0);
                    logd("Timer stopped - no active sources");
                }
            }
        }
    }
}
