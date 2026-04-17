/*--------------------
MODULE: kmod_particles.lsl
VERSION: 1.10
REVISION: 6
PURPOSE: Visual connection renderer with Lockmeister compatibility
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 6: Lift leash ribbon tuning knobs (MAX_AGE, BURST_RATE, BURST_COUNT,
  ACCEL, SCALE) into top-of-script LEASH_PARTICLE_* globals so future tuning
  touches one block instead of hunting inside render_chain_particles. No
  behavioral change from rev 5.
- v1.1 rev 5: Rev 4 was undertuned on both axes — ribbon drew as a near-
  straight line with visible FOLLOW_SRC snap artifacts. Raise
  PSYS_PART_MAX_AGE 1.0 -> 1.6 and PSYS_SRC_ACCEL Z -0.6 -> -1.8 so the
  gravity x lifetime product (sag potential) goes from ~0.3 m to ~2.3 m —
  enough for a visible catenary at typical leash distances. Raise
  PSYS_SRC_BURST_PART_COUNT 4 -> 10 to match typhartez's density, which hides
  the per-frame FOLLOW_SRC rigid translation across enough live particles
  that the ribbon reads as a single coherent shape.
- v1.1 rev 4: Adopt the typhartez/Marine-style recipe. Restore
  PSYS_PART_FOLLOW_SRC_MASK so the collar end of the ribbon is pinned to the
  wearer instead of trailing through stale world-space positions. Raise
  PSYS_SRC_BURST_PART_COUNT 1 -> 4 so the per-frame rigid translation caused by
  FOLLOW_SRC is averaged across ~4x as many live particles and reads as a
  coherent ribbon rather than a visible snap. Drop PSYS_PART_MAX_AGE 1.2 -> 1.0
  for the same reason (fewer stale particles alive at any instant). Soften
  PSYS_SRC_ACCEL Z -4.0 -> -0.6 — with FOLLOW_SRC restored and a shorter
  lifetime, heavy gravity overbows the ribbon; light gravity produces a cleaner
  catenary. Change START/END_SCALE Z 0.07 -> 1.0 to match reference ribbon
  configs (ribbon stride uses the Z component when PATTERN_DROP is active).
- v1.1 rev 3: Tune ribbon to look like a hanging chain instead of a weightless
  string. Shorten PSYS_PART_MAX_AGE 2.6 -> 1.2 so the trail no longer floats
  through 2.6s of stale positions when the wearer moves. Strengthen
  PSYS_SRC_ACCEL Z from -1.25 -> -4.0 to preserve a natural catenary sag over
  the shorter lifetime.
- v1.1 rev 2: EXPERIMENTAL - Remove PSYS_PART_FOLLOW_SRC_MASK so wearer movement no
  longer snaps the ribbon. In-flight particles continue on their ballistic arc; only
  new emissions originate from the updated collar position. Fix CHANGED_LINK to only
  restart the particle system when the leashpoint link number actually changes,
  preventing spurious redraws from unrelated linkset events. Pending in-world testing.
- v1.1 rev 1: Namespace internal message type strings (particles.*, kernel.*).
- v1.1 rev 0: Version bump for LSD policy architecture. No functional changes to this module.
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
float   LEASH_MAX_AGE     = 1.6;
float   LEASH_BURST_RATE  = 0.0;
integer LEASH_BURST_COUNT = 10;
vector  LEASH_ACCEL       = <0.0, 0.0, -1.8>;
vector  LEASH_SCALE       = <0.07, 0.07, 1.0>;

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
        if (SourcePlugin == "core_leash" && TargetKey != NULL_KEY) {
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
            PSYS_PART_FOLLOW_VELOCITY_MASK |
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
    if (SourcePlugin == "lockmeister" && source == "core_leash") {
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
