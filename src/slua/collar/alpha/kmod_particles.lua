--[[--------------------
MODULE: kmod_particles.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Visual connection renderer with Lockmeister compatibility
ARCHITECTURE: Consolidated message bus lanes (SLua port)
CHANGES:
- v0.1 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  LLTimers replaces single-timer multiplexing.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900

-- Constants
local PARTICLE_UPDATE_RATE = 0.5
local CHAIN_TEXTURE = "4d3b6c6f-52e2-da9d-f7be-cccb1e535aca"
local LEASH_CHAN_LM = -8888
local LM_PING_INTERVAL = 8

-- State
local particlesActive = false
local targetKey = NULL_KEY
local sourcePlugin = ""
local particleStyle = "chain"
local leashpointLink = 0

-- Lockmeister state
local lmListen = 0
local lmActive = false
local lmController = NULL_KEY
local lmTargetPrim = NULL_KEY
local lmLastPing = 0
local lmAuthorized = false

-- Timer handle
local updateTimer = nil

-- Forward declarations
local onTimerTick
local findLeashpointLink
local renderChainParticles

-- Helpers

local function now()
    return ll.GetUnixTime()
end

local function needsTimer()
    if lmActive then return true end
    if sourcePlugin ~= "" and particlesActive then return true end
    return false
end

local function openLmListen()
    if lmListen == 0 then
        lmListen = ll.Listen(LEASH_CHAN_LM, "", NULL_KEY, "")
    end
end

local function closeLmListen()
    if lmListen ~= 0 then
        ll.ListenRemove(lmListen)
        lmListen = 0
    end
end

local function stopTimerIfUnneeded()
    if not needsTimer() then
        if updateTimer then
            LLTimers:off(updateTimer)
            updateTimer = nil
        end
    end
end

local function ensureTimer()
    if not updateTimer then
        updateTimer = LLTimers:every(PARTICLE_UPDATE_RATE, function()
            onTimerTick()
        end)
    end
end

-- Leashpoint detection

findLeashpointLink = function()
    local primCount = ll.GetNumberOfPrims()
    for i = 2, primCount do
        local params = ll.GetLinkPrimitiveParams(i, {PRIM_NAME, PRIM_DESC})
        local name = ll.ToLower(ll.StringTrim(params[1], STRING_TRIM))
        local desc = ll.ToLower(ll.StringTrim(params[2], STRING_TRIM))
        if name == "leashpoint" and desc == "leashpoint" then
            return i
        end
    end
    return LINK_ROOT
end

-- Particle rendering

renderChainParticles = function(target)
    if leashpointLink == 0 then
        leashpointLink = findLeashpointLink()
    end

    if target == NULL_KEY then
        ll.LinkParticleSystem(leashpointLink, {})
        particlesActive = false
        return
    end

    ll.LinkParticleSystem(leashpointLink, {
        PSYS_SRC_PATTERN, PSYS_SRC_PATTERN_DROP,
        PSYS_SRC_TEXTURE, CHAIN_TEXTURE,
        PSYS_SRC_BURST_RATE, 0.0,
        PSYS_SRC_BURST_PART_COUNT, 1,
        PSYS_PART_START_ALPHA, 1.0,
        PSYS_PART_END_ALPHA, 1.0,
        PSYS_PART_MAX_AGE, 2.6,
        PSYS_PART_START_SCALE, vector(0.07, 0.07, 0.07),
        PSYS_PART_END_SCALE, vector(0.07, 0.07, 0.07),
        PSYS_PART_START_COLOR, vector(1, 1, 1),
        PSYS_PART_END_COLOR, vector(1, 1, 1),
        PSYS_SRC_ACCEL, vector(0, 0, -1.25),
        PSYS_PART_FLAGS,
            bit32.bor(
                PSYS_PART_INTERP_COLOR_MASK,
                PSYS_PART_FOLLOW_SRC_MASK,
                PSYS_PART_TARGET_POS_MASK,
                PSYS_PART_FOLLOW_VELOCITY_MASK,
                PSYS_PART_RIBBON_MASK
            ),
        PSYS_SRC_TARGET_KEY, target
    })

    particlesActive = true
end

-- Lockmeister ping

local function lmPing()
    if not lmActive or lmController == NULL_KEY then return end

    local t = ll.GetUnixTime()
    if (t - lmLastPing) < LM_PING_INTERVAL then return end
    lmLastPing = t

    if ll.GetAgentSize(lmController) ~= ZERO_VECTOR then
        local wearer = tostring(ll.GetOwner())
        ll.RegionSayTo(lmController, LEASH_CHAN_LM, wearer .. "collar")
        ll.RegionSayTo(lmController, LEASH_CHAN_LM, wearer .. "handle")
        ll.RegionSayTo(lmController, LEASH_CHAN_LM, wearer .. "|LMV2|RequestPoint|handle")
        ll.RegionSayTo(lmController, LEASH_CHAN_LM, wearer .. "|LMV2|RequestPoint|collar")
    end
end

-- Lockmeister message handler

local function handleLmMessage(id, msg)
    local ownerKey = ll.GetOwnerKey(id)

    local msgUuid = ll.GetSubString(msg, 0, 35)
    local protocol = ll.GetSubString(msg, 36, -1)

    if ll.StringLength(msgUuid) ~= 36 then return end

    if key(msgUuid) ~= ownerKey then
        return
    end

    -- Handle explicit release commands
    if protocol == "collar free" or protocol == "handle free" then
        if lmActive and id == lmTargetPrim then
            lmActive = false
            lmController = NULL_KEY
            lmTargetPrim = NULL_KEY
            lmAuthorized = false
            closeLmListen()

            renderChainParticles(NULL_KEY)

            ll.MessageLinked(LINK_SET, UI_BUS,
                lljson.encode({ type = "lm_released" }), NULL_KEY)

            if sourcePlugin == "lockmeister" or sourcePlugin == "" then
                sourcePlugin = ""
                targetKey = NULL_KEY
            end
            stopTimerIfUnneeded()
        end
        return
    end

    -- Lockmeister grab response
    if protocol == "collar ok" or protocol == "handle ok" then
        if not lmAuthorized then
            return
        end

        if lmController ~= NULL_KEY and ownerKey ~= lmController then
            return
        end

        if lmActive and lmTargetPrim ~= NULL_KEY then
            if id ~= lmTargetPrim then
                return
            end
            lmLastPing = now()
            return
        end

        -- Priority check: DS native already rendering to a holder prim
        if sourcePlugin == "core_leash" and targetKey ~= NULL_KEY then
            if ll.GetAgentSize(targetKey) == ZERO_VECTOR then
                return
            end
        end

        lmActive = true
        lmController = ownerKey
        lmTargetPrim = id
        lmLastPing = now()

        targetKey = id
        particlesActive = true
        sourcePlugin = "lockmeister"

        renderChainParticles(id)

        ll.MessageLinked(LINK_SET, UI_BUS,
            lljson.encode({
                type = "lm_grabbed",
                controller = tostring(ownerKey),
                prim = tostring(id)
            }), NULL_KEY)
    end
end

-- Message handlers

local function handleParticlesStart(msg)
    local data = lljson.decode(msg)
    if not data or not data.source or not data.target then
        return
    end

    local source = data.source
    local target = key(data.target)

    local details = ll.GetObjectDetails(target, {OBJECT_POS})
    if #details == 0 then
        return
    end

    -- Priority: Lockmeister < DS leash
    if sourcePlugin == "lockmeister" and source == "core_leash" then
        if lmActive then
            lmActive = false
            lmController = NULL_KEY
            lmTargetPrim = NULL_KEY
            lmAuthorized = false
            closeLmListen()
        end
    elseif sourcePlugin ~= "" and sourcePlugin ~= source then
        return
    end

    sourcePlugin = source
    targetKey = target

    if data.style then
        particleStyle = data.style
    else
        particleStyle = "chain"
    end

    renderChainParticles(targetKey)
    ensureTimer()
end

local function handleParticlesStop(msg)
    local data = lljson.decode(msg)
    if not data or not data.source then
        return
    end

    if data.source ~= sourcePlugin then
        return
    end

    renderChainParticles(NULL_KEY)

    sourcePlugin = ""
    targetKey = NULL_KEY

    stopTimerIfUnneeded()
end

local function handleParticlesUpdate(msg)
    local data = lljson.decode(msg)
    if not data or not data.target then
        return
    end

    local newTarget = key(data.target)

    local details = ll.GetObjectDetails(newTarget, {OBJECT_POS})
    if #details == 0 then
        return
    end

    if newTarget ~= targetKey then
        targetKey = newTarget
        renderChainParticles(targetKey)
    end
end

local function handleLmEnable(msg)
    local data = lljson.decode(msg)
    if not data or not data.controller then
        return
    end

    lmController = key(data.controller)
    lmAuthorized = true
    openLmListen()

    lmLastPing = now()
    ensureTimer()
end

local function handleLmDisable()
    closeLmListen()

    if lmActive then
        lmActive = false
        lmController = NULL_KEY
        lmTargetPrim = NULL_KEY
        lmAuthorized = false

        if sourcePlugin == "lockmeister" then
            renderChainParticles(NULL_KEY)
            sourcePlugin = ""
            targetKey = NULL_KEY
        end
    end

    lmAuthorized = false

    stopTimerIfUnneeded()
end

-- Timer tick (handles both LM ping and target validation)

onTimerTick = function()
    if lmActive then
        lmPing()
    end

    if particlesActive and targetKey ~= NULL_KEY then
        local details = ll.GetObjectDetails(targetKey, {OBJECT_POS})
        if #details == 0 then
            renderChainParticles(NULL_KEY)

            if lmActive then
                lmActive = false
                lmController = NULL_KEY
                lmTargetPrim = NULL_KEY
                lmAuthorized = false
                closeLmListen()

                ll.MessageLinked(LINK_SET, UI_BUS,
                    lljson.encode({ type = "lm_released" }), NULL_KEY)
            end

            sourcePlugin = ""
            targetKey = NULL_KEY

            stopTimerIfUnneeded()
        end
    end
end

-- Init (replaces state_entry)

local function init()
    particlesActive = false
    targetKey = NULL_KEY
    sourcePlugin = ""
    leashpointLink = 0

    lmActive = false
    lmController = NULL_KEY
    lmTargetPrim = NULL_KEY
    lmAuthorized = false
    closeLmListen()

    renderChainParticles(NULL_KEY)
end

-- Events

LLEvents:on("on_rez", function(startParam)
    ll.ResetScript()
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        lmAuthorized = false
        lmController = NULL_KEY
        closeLmListen()
        ll.ResetScript()
    end

    if bit32.btest(change, CHANGED_LINK) then
        leashpointLink = 0
        if particlesActive then
            leashpointLink = findLeashpointLink()
            renderChainParticles(targetKey)
        end
    end
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    local data = lljson.decode(msg)
    if not data or not data.type then return end
    local msgType = data.type

    if num == KERNEL_LIFECYCLE then
        if msgType == "soft_reset" or msgType == "soft_reset_all" then
            ll.ResetScript()
        end
        return
    end

    if num ~= UI_BUS then return end

    if msgType == "particles_start" then
        handleParticlesStart(msg)
    elseif msgType == "particles_stop" then
        handleParticlesStop(msg)
    elseif msgType == "particles_update" then
        handleParticlesUpdate(msg)
    elseif msgType == "lm_enable" then
        handleLmEnable(msg)
    elseif msgType == "lm_disable" then
        handleLmDisable()
    end
end)

LLEvents:on("listen", function(channel, name, id, msg)
    if channel == LEASH_CHAN_LM then
        handleLmMessage(id, msg)
    end
end)

init()
