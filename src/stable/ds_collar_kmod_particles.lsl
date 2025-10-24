/* =============================================================================
   MODULE: ds_collar_kmod_particles.lsl (v2.0 - Consolidated ABI)
   
   ROLE: Visual connection renderer (chains, beams, ropes) + Lockmeister protocol
   
   PURPOSE: Provides particle system rendering for any plugin that needs
            visual connections between wearer and target (avatar or object).
            Also handles Lockmeister protocol for compatibility with LM items.
   
   USED BY:
   - Leash plugin (chain to leasher)
   - Coffle plugin (chain between subs)
   - Parking plugin (chain to post/object)
   
   PROTOCOLS:
   - DS native (via UI_BUS messages)
   - Lockmeister v2 (channel -8888)
   
   CHANNELS:
   - 900 (UI_BUS): Particle control messages
   - -8888 (Lockmeister): LM protocol compatibility
   
   ============================================================================= */

integer DEBUG = TRUE;

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer UI_BUS = 900;

/* ═══════════════════════════════════════════════════════════
   CONSTANTS
   ═══════════════════════════════════════════════════════════ */
float PARTICLE_UPDATE_RATE = 0.5;  // Update every 0.5 seconds

// Default chain texture
string CHAIN_TEXTURE = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";

// Lockmeister protocol
integer LEASH_CHAN_LM = -8888;
integer LM_PING_INTERVAL = 8;  // Ping every 8 seconds

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
integer ParticlesActive = FALSE;
key TargetKey = NULL_KEY;
string SourcePlugin = "";
string ParticleStyle = "chain";
integer LeashpointLink = 0;

// Lockmeister state
integer LmListen = 0;
integer LmActive = FALSE;
key LmController = NULL_KEY;
integer LmLastPing = 0;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[PARTICLES] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer now() {
    return llGetUnixTime();
}

/* ═══════════════════════════════════════════════════════════
   LOCKMEISTER PROTOCOL
   ═══════════════════════════════════════════════════════════ */

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
    string wearer = (string)llGetOwner();
    
    // Check if message starts with wearer UUID
    if (llGetSubString(msg, 0, 35) != wearer) return;
    
    string protocol = llGetSubString(msg, 36, -1);
    
    // Lockmeister response: "collar ok" or "handle ok"
    if (protocol == "collar ok" || protocol == "handle ok") {
        logd("LM response received from " + llKey2Name(owner_key));
        
        // Start particles to controller avatar
        LmActive = TRUE;
        LmController = owner_key;
        LmLastPing = now();
        
        TargetKey = owner_key;
        ParticlesActive = TRUE;
        SourcePlugin = "lockmeister";
        
        render_chain_particles(owner_key);
        
        // Notify leash plugin
        string notify_msg = llList2Json(JSON_OBJECT, [
            "type", "lm_grabbed",
            "controller", (string)owner_key
        ]);
        llMessageLinked(LINK_SET, UI_BUS, notify_msg, NULL_KEY);
    }
}

/* ═══════════════════════════════════════════════════════════
   LEASHPOINT DETECTION
   ═══════════════════════════════════════════════════════════ */

// Find the leashpoint prim (name="leashpoint", desc="leashpoint")
// Falls back to LINK_ROOT if not found
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

/* ═══════════════════════════════════════════════════════════
   PARTICLE RENDERING
   ═══════════════════════════════════════════════════════════ */

render_chain_particles(key target) {
    if (LeashpointLink == 0) {
        LeashpointLink = find_leashpoint_link();
    }
    
    if (target == NULL_KEY) {
        // Clear particles
        if (ParticlesActive) {
            llLinkParticleSystem(LeashpointLink, []);
            ParticlesActive = FALSE;
            logd("Particles cleared");
        }
        return;
    }
    
    // Set up particle system
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
    logd("Particles started to target: " + (string)target);
}

/* ═══════════════════════════════════════════════════════════
   MESSAGE HANDLING
   ═══════════════════════════════════════════════════════════ */

handle_particles_start(string msg) {
    if (!json_has(msg, ["source"])) {
        logd("ERROR: particles_start missing source");
        return;
    }
    
    if (!json_has(msg, ["target"])) {
        logd("ERROR: particles_start missing target");
        return;
    }
    
    string source = llJsonGetValue(msg, ["source"]);
    
    // If Lockmeister is active, DS protocol takes precedence
    if (LmActive && source != "lockmeister") {
        logd("Stopping Lockmeister to switch to DS native");
        LmActive = FALSE;
        LmController = NULL_KEY;
    }
    
    SourcePlugin = source;
    TargetKey = (key)llJsonGetValue(msg, ["target"]);
    
    if (json_has(msg, ["style"])) {
        ParticleStyle = llJsonGetValue(msg, ["style"]);
    }
    else {
        ParticleStyle = "chain";
    }
    
    logd("Start request from " + SourcePlugin + " to target " + (string)TargetKey);
    
    // Start rendering
    render_chain_particles(TargetKey);
    
    // Start timer for updates
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
}

handle_particles_stop(string msg) {
    if (!json_has(msg, ["source"])) {
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
    
    // Clear particles
    render_chain_particles(NULL_KEY);
    
    // Stop timer if no Lockmeister active
    if (!LmActive) {
        llSetTimerEvent(0.0);
    }
    
    // Reset state
    if (!LmActive) {
        SourcePlugin = "";
        TargetKey = NULL_KEY;
    }
}

handle_particles_update(string msg) {
    if (!json_has(msg, ["target"])) {
        logd("ERROR: particles_update missing target");
        return;
    }
    
    key new_target = (key)llJsonGetValue(msg, ["target"]);
    
    if (new_target != TargetKey) {
        logd("Updating target to: " + (string)new_target);
        TargetKey = new_target;
        render_chain_particles(TargetKey);
    }
}

handle_lm_enable(string msg) {
    // Enable Lockmeister listening
    if (!json_has(msg, ["controller"])) {
        logd("ERROR: lm_enable missing controller");
        return;
    }
    
    LmController = (key)llJsonGetValue(msg, ["controller"]);
    open_lm_listen();
    
    // Start pinging
    LmLastPing = now();
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
    
    logd("Lockmeister enabled for " + llKey2Name(LmController));
}

handle_lm_disable() {
    close_lm_listen();
    LmActive = FALSE;
    LmController = NULL_KEY;
    
    logd("Lockmeister disabled");
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default
{
    state_entry() {
        ParticlesActive = FALSE;
        TargetKey = NULL_KEY;
        SourcePlugin = "";
        LeashpointLink = 0;
        
        LmActive = FALSE;
        LmController = NULL_KEY;
        close_lm_listen();
        
        logd("Particles module ready");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
        
        // If inventory changed, re-detect leashpoint
        if (change & CHANGED_LINK) {
            LeashpointLink = 0;
            if (ParticlesActive) {
                LeashpointLink = find_leashpoint_link();
                render_chain_particles(TargetKey);
            }
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        // Only listen on UI_BUS
        if (num != UI_BUS) return;
        
        if (!json_has(msg, ["type"])) return;
        
        string msg_type = llJsonGetValue(msg, ["type"]);
        
        if (msg_type == "particles_start") {
            handle_particles_start(msg);
        }
        else if (msg_type == "particles_stop") {
            handle_particles_stop(msg);
        }
        else if (msg_type == "particles_update") {
            handle_particles_update(msg);
        }
        else if (msg_type == "lm_enable") {
            handle_lm_enable(msg);
        }
        else if (msg_type == "lm_disable") {
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
        
        // Periodic update - refresh particle system to target
        // This helps keep the chain stable if target is moving
        if (ParticlesActive && TargetKey != NULL_KEY) {
            // Just verify target is still valid
            list details = llGetObjectDetails(TargetKey, [OBJECT_POS]);
            if (llGetListLength(details) == 0) {
                // Target disappeared (offsim or logged out)
                logd("Target lost, clearing particles");
                render_chain_particles(NULL_KEY);
                
                // If Lockmeister was active, stop it
                if (LmActive) {
                    LmActive = FALSE;
                    LmController = NULL_KEY;
                    close_lm_listen();
                    
                    // Notify leash plugin
                    string notify_msg = llList2Json(JSON_OBJECT, [
                        "type", "lm_released"
                    ]);
                    llMessageLinked(LINK_SET, UI_BUS, notify_msg, NULL_KEY);
                }
                
                if (!LmActive) {
                    llSetTimerEvent(0.0);
                    SourcePlugin = "";
                    TargetKey = NULL_KEY;
                }
            }
        }
    }
}
