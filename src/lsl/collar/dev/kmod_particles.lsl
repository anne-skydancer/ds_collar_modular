/*--------------------
MODULE: kmod_particles.lsl
VERSION: 1.10
REVISION: 14
PURPOSE: Visual connection renderer with Lockmeister compatibility
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 14: Fix LM handler overriding DS holder particles. The two
  DS/LM priority gates still hard-coded the pre-namespace source string
  "core_leash"; kmod_leash migrated to "ui.core.leash" in rev 5, so
  SourcePlugin never matched. Result: any LM-compatible attachment on
  the leasher won the race and re-anchored particles to its responder
  prim (typically near avatar center), regardless of whether the DS
  native handshake had already succeeded.
- v1.1 rev 13: Lift PSYS_SRC_MAX_AGE to LEASH_SRC_MAX_AGE global.
- v1.1 rev 12: PSYS_SRC_MAX_AGE now explicit (0.0 = forever).
- v1.1 rev 11: LEASH_MAX_AGE 2.5 -> 5.0 for softer target-motion response.
- v1.1 rev 10: LEASH_BURST_RATE 0.0 -> 0.05 (metered, decoupled from viewer FPS).
- v1.1 rev  9: LEASH_BURST_COUNT 10 -> 1. With FOLLOW_SRC disabling
  BURST_RADIUS, same-burst particles stack; inter-particle ribbon segments
  have zero length and don't render. Density must come from BURST_RATE.
- v1.1 rev  8: Remove PSYS_PART_FOLLOW_VELOCITY_MASK (wiki: no effect on
  ribbons). LEASH_SCALE.y 0.07 -> 1.0 (wiki: Y is max visibility distance).
- v1.1 rev  7: MAX_AGE 1.6 -> 2.5, ACCEL.z -1.8 -> -1.0 — softer TARGET_POS
  response to leasher motion.
- v1.1 rev  6: Lift ribbon tuning knobs into LEASH_* globals.
- v1.1 rev  5: MAX_AGE 1.0 -> 1.6, ACCEL.z -0.6 -> -1.8, BURST_COUNT 4 -> 10.
- v1.1 rev  4: Restore PSYS_PART_FOLLOW_SRC_MASK. Adopt typhartez-style recipe
  (short MAX_AGE, light ACCEL, denser bursts).
- v1.1 rev  3: MAX_AGE 2.6 -> 1.2, ACCEL.z -1.25 -> -4.0 against floaty trail.
- v1.1 rev  2: EXPERIMENTAL — remove PSYS_PART_FOLLOW_SRC_MASK (reverted in
  rev 4). Gate CHANGED_LINK particle restart on actual leashpoint link-number
  change.
- v1.1 rev  1: Namespace internal message type strings (particles.*, kernel.*).
- v1.1 rev  0: Version bump for LSD policy architecture. No functional changes.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;

/* -------------------- CONSTANTS -------------------- */
float PARTICLE_UPDATE_RATE = 0.5;  // Update every 0.5 seconds

// Default chain texture
string CHAIN_TEXTURE = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca";

/* -------------------- LEASH RIBBON TUNING --------------------
   Adjust these to tune the catenary look. See module changelog for the
   reasoning behind the current values.
   - MAX_AGE x |ACCEL.z| = sag potential in metres. Too small -> straight
     line; too large -> overbowed rope.
   - BURST_COUNT is density. Higher values hide the per-frame
     FOLLOW_SRC rigid translation but cost more client-side rendering.
   - BURST_RATE 0.0 emits every frame; nonzero meters emissions.
   - SCALE.x is ribbon thickness. Y/Z are stride hints.
*/
float   LEASH_MAX_AGE     = 5.0;
float   LEASH_SRC_MAX_AGE = 0.0;
float   LEASH_BURST_RATE  = 0.05;
integer LEASH_BURST_COUNT = 1;
vector  LEASH_ACCEL       = <0.0, 0.0, -1.0>;
vector  LEASH_SCALE       = <0.07, 1.0, 1.0>;

// Lockmeister protocol
integer LEASH_CHAN_LM = -8888;
integer LM_PING_INTERVAL = 8;  // Ping every 8 seconds

/* -------------------- STATE -------------------- */
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
integer LmAuthorized = FALSE;  // TRUE when leash module has activated LM mode

/* -------------------- HELPERS -------------------- */



integer now() {
    return llGetUnixTime();
}

// Helper to determine if timer should be running
integer needs_timer() {
    if (LmActive) return TRUE;  // Lockmeister needs pinging
    if (SourcePlugin != "" && ParticlesActive) return TRUE;  // DS rendering active
    return FALSE;
}

/* -------------------- LOCKMEISTER PROTOCOL -------------------- */

open_lm_listen() {
    if (LmListen == 0) {
        LmListen = llListen(LEASH_CHAN_LM, "", NULL_KEY, "");
    }
}

close_lm_listen() {
    if (LmListen != 0) {
        llListenRemove(LmListen);
        LmListen = 0;
    }
}

lm_ping() {
    if (!LmActive || LmController == NULL_KEY) return;
    
    integer t = llGetUnixTime();
    if ((t - LmLastPing) < LM_PING_INTERVAL) return;
    LmLastPing = t;
    
    if (llGetAgentSize(LmController) != ZERO_VECTOR) {
        string wearer = (string)llGetOwner();
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "collar");
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "handle");
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "|LMV2|RequestPoint|handle");
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "|LMV2|RequestPoint|collar");
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
        return;
    }
    
    // Handle explicit release commands
    if (protocol == "collar free" || protocol == "handle free") {
        if (LmActive && id == LmTargetPrim) {
            
            LmActive = FALSE;
            LmController = NULL_KEY;
            LmTargetPrim = NULL_KEY;
            LmAuthorized = FALSE;
            close_lm_listen();
            
            // Clear particles
            render_chain_particles(NULL_KEY);
            
            // Notify leash plugin
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "particles.lmreleased"
            ]), NULL_KEY);

            // Stop timer if no other source active
            if (SourcePlugin == "lockmeister" || SourcePlugin == "") {
                SourcePlugin = "";
                TargetKey = NULL_KEY;
            }
            if (!needs_timer()) {
                llSetTimerEvent(0.0);
            }
        }
        return;
    }
    
    // Lockmeister grab response: "collar ok" or "handle ok"
    if (protocol == "collar ok" || protocol == "handle ok") {
        // Only accept if LM mode was activated by the leash module
        if (!LmAuthorized) {
            return;
        }
        
        // Only accept handles belonging to the expected controller
        if (LmController != NULL_KEY && owner_key != LmController) {
            return;
        }
        
        // If we're already locked onto a handle, ONLY accept responses from THAT handle
        if (LmActive && LmTargetPrim != NULL_KEY) {
            if (id != LmTargetPrim) {
                return;
            }
            // Same handle confirming - just update ping time
            LmLastPing = now();
            return;
        }
        
        
        // Priority check: If DS native is already rendering to a holder prim, don't override
        if (SourcePlugin == "ui.core.leash" && TargetKey != NULL_KEY) {
            // Check if current target is a prim (not avatar)
            if (llGetAgentSize(TargetKey) == ZERO_VECTOR) {
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
        string notify_msg = llList2Json(JSON_OBJECT, [
            "type", "particles.lmgrabbed",
            "controller", (string)owner_key,
            "prim", (string)id
        ]);
        llMessageLinked(LINK_SET, UI_BUS, notify_msg, NULL_KEY);
    }
}

/* -------------------- LEASHPOINT DETECTION -------------------- */

integer find_leashpoint_link() {
    integer i = 2;
    integer prim_count = llGetNumberOfPrims();
    
    while (i <= prim_count) {
        list params = llGetLinkPrimitiveParams(i, [PRIM_NAME, PRIM_DESC]);
        string name = llToLower(llStringTrim(llList2String(params, 0), STRING_TRIM));
        string desc = llToLower(llStringTrim(llList2String(params, 1), STRING_TRIM));
        
        if (name == "leashpoint" && desc == "leashpoint") {
            return i;
        }
        i = i + 1;
    }
    return LINK_ROOT;
}

/* -------------------- PARTICLE RENDERING -------------------- */

render_chain_particles(key target) {
    if (LeashpointLink == 0) {
        LeashpointLink = find_leashpoint_link();
    }
    
    if (target == NULL_KEY) {
        // Clear particles
        llLinkParticleSystem(LeashpointLink, []);
        ParticlesActive = FALSE;
        return;
    }
    
    // Render chain to target
    llLinkParticleSystem(LeashpointLink, [
        PSYS_SRC_PATTERN, PSYS_SRC_PATTERN_DROP,
        PSYS_SRC_TEXTURE, CHAIN_TEXTURE,
        PSYS_SRC_MAX_AGE, LEASH_SRC_MAX_AGE,
        PSYS_SRC_BURST_RATE, LEASH_BURST_RATE,
        PSYS_SRC_BURST_PART_COUNT, LEASH_BURST_COUNT,
        PSYS_PART_START_ALPHA, 1.0,
        PSYS_PART_END_ALPHA, 1.0,
        PSYS_PART_MAX_AGE, LEASH_MAX_AGE,
        PSYS_PART_START_SCALE, LEASH_SCALE,
        PSYS_PART_END_SCALE, LEASH_SCALE,
        PSYS_PART_START_COLOR, <1, 1, 1>,
        PSYS_PART_END_COLOR, <1, 1, 1>,
        PSYS_SRC_ACCEL, LEASH_ACCEL,
        PSYS_PART_FLAGS,
            PSYS_PART_INTERP_COLOR_MASK |
            PSYS_PART_TARGET_POS_MASK |
            PSYS_PART_FOLLOW_SRC_MASK |
            PSYS_PART_RIBBON_MASK,
        PSYS_SRC_TARGET_KEY, target
    ]);
    
    ParticlesActive = TRUE;
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_particles_start(string msg) {
    if (llJsonGetValue(msg, ["source"]) == JSON_INVALID || llJsonGetValue(msg, ["target"]) == JSON_INVALID) {
        return;
    }
    
    string source = llJsonGetValue(msg, ["source"]);
    key target = (key)llJsonGetValue(msg, ["target"]);
    
    // Validate target exists in-world
    list details = llGetObjectDetails(target, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        return;
    }
    
    // Priority: Lockmeister < DS leash
    if (SourcePlugin == "lockmeister" && source == "ui.core.leash") {
        if (LmActive) {
            LmActive = FALSE;
            LmController = NULL_KEY;
            LmTargetPrim = NULL_KEY;
            LmAuthorized = FALSE;
            close_lm_listen();
        }
    }
    else if (SourcePlugin != "" && SourcePlugin != source) {
        return;
    }
    
    SourcePlugin = source;
    TargetKey = target;
    
    string tmp = llJsonGetValue(msg, ["style"]);
    if (tmp != JSON_INVALID) {
        ParticleStyle = tmp;
    }
    else {
        ParticleStyle = "chain";
    }
    
    
    render_chain_particles(TargetKey);
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
}

handle_particles_stop(string msg) {
    if (llJsonGetValue(msg, ["source"]) == JSON_INVALID) {
        return;
    }
    
    string source = llJsonGetValue(msg, ["source"]);
    
    // Only stop if request is from the same plugin that started it
    if (source != SourcePlugin) {
        return;
    }
    
    render_chain_particles(NULL_KEY);
    
    // Always clear source state when stopping
    SourcePlugin = "";
    TargetKey = NULL_KEY;
    
    // Stop timer if nothing needs it
    if (!needs_timer()) {
        llSetTimerEvent(0.0);
    }
}

handle_particles_update(string msg) {
    if (llJsonGetValue(msg, ["target"]) == JSON_INVALID) {
        return;
    }
    
    key new_target = (key)llJsonGetValue(msg, ["target"]);
    
    // Verify target is present in-world before rendering
    list details = llGetObjectDetails(new_target, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        return;
    }
    
    if (new_target != TargetKey) {
        TargetKey = new_target;
        render_chain_particles(TargetKey);
    }
}

handle_lm_enable(string msg) {
    // Enable Lockmeister listening
    if (llJsonGetValue(msg, ["controller"]) == JSON_INVALID) {
        return;
    }
    
    LmController = (key)llJsonGetValue(msg, ["controller"]);
    LmAuthorized = TRUE;  // Mark as authorized
    open_lm_listen();
    
    // Start pinging
    LmLastPing = now();
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
    
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
    }
}

/* -------------------- EVENTS -------------------- */

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

        // Clear any leftover particles from before the reset
        render_chain_particles(NULL_KEY);
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
        
        // If linkset changed, re-detect leashpoint but only restart particles
        // if the link number actually changed — spurious CHANGED_LINK events
        // (e.g. other attachments on the wearer) must not redraw the ribbon.
        if (change & CHANGED_LINK) {
            integer prev_link = LeashpointLink;
            LeashpointLink = find_leashpoint_link();
            if (ParticlesActive && LeashpointLink != prev_link) {
                render_chain_particles(TargetKey);
            }
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset" || msg_type == "kernel.resetall") {
                llResetScript();
            }
            return;
        }

        // Only listen on UI_BUS
        if (num != UI_BUS) return;

        if (msg_type == "particles.start") {
            handle_particles_start(msg);
        }
        else if (msg_type == "particles.stop") {
            handle_particles_stop(msg);
        }
        else if (msg_type == "particles.update") {
            handle_particles_update(msg);
        }
        else if (msg_type == "particles.lmenable") {
            handle_lm_enable(msg);
        }
        else if (msg_type == "particles.lmdisable") {
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
                render_chain_particles(NULL_KEY);
                
                // If Lockmeister was active, stop it
                if (LmActive) {
                    LmActive = FALSE;
                    LmController = NULL_KEY;
                    LmTargetPrim = NULL_KEY;
                    LmAuthorized = FALSE;
                    close_lm_listen();
                    
                    // Notify leash plugin
                    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                        "type", "particles.lmreleased"
                    ]), NULL_KEY);
                }
                
                // Always cleanup when target is lost
                SourcePlugin = "";
                TargetKey = NULL_KEY;
                
                // Only stop timer if nothing needs it
                if (!needs_timer()) {
                    llSetTimerEvent(0.0);
                }
            }
        }
    }
}
