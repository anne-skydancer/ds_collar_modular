--[[--------------------
MODULE: collar_kernel.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Plugin registry, lifecycle management, heartbeat monitoring
ARCHITECTURE: Consolidated message bus lanes (SLua port)
CHANGES:
- v0.1 rev 0: Initial SLua alpha port from LSL 1.10 rev 1
  Table-based registry replaces stride lists.
  LLTimers replaces single-timer multiplexing.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500

-- Timing
local PING_INTERVAL_SEC = 10.0
local PING_TIMEOUT_SEC = 30
local INV_SWEEP_INTERVAL = 3.0
local BATCH_WINDOW_SEC = 0.1
local DISCOVERY_INTERVAL_SEC = 5.0

-- Registry: table keyed by context
-- Each entry: { label=str, script=str, scriptUuid=uuid, lastSeen=int }
local PluginRegistry = {}

-- Queue: table keyed by context (newest op wins, natural dedup)
-- Each entry: { opType=str, label=str, script=str, timestamp=int }
local RegistrationQueue = {}

local PendingBatchTimer = nil -- LLTimers handle or nil
local PendingPluginListRequest = false
local LastOwner = NULL_KEY
local LastScriptCount = 0
local LastRegionCrossUnix = 0
local KnownScriptUUIDs = {}

-- Timer handles
local HeartbeatTimer = nil
local InvSweepTimer = nil
local DiscoveryTimer = nil

-- helpers

local function now()
    return ll.GetUnixTime()
end

local function countScripts()
    return ll.GetInventoryNumber(INVENTORY_SCRIPT)
end

local function getMsgType(json_str)
    local data = lljson.decode(json_str)
    if data and data.type then return data.type end
    return ""
end

-- queue management

local function queueAdd(opType, context, label, script)
    RegistrationQueue[context] = {
        opType = opType,
        label = label,
        script = script,
        timestamp = now()
    }

    if not PendingBatchTimer then
        PendingBatchTimer = LLTimers:once(BATCH_WINDOW_SEC, function()
            PendingBatchTimer = nil
            -- deferred: fires processQueue via timer
        end)
    end
end

-- registry management

local function registryUpsert(context, label, script)
    local scriptUuid = ll.GetInventoryKey(script)
    local existing = PluginRegistry[context]

    if not existing then
        PluginRegistry[context] = {
            label = label,
            script = script,
            scriptUuid = scriptUuid,
            lastSeen = now()
        }
        return true
    end

    local uuidChanged = (existing.scriptUuid ~= scriptUuid)
    existing.label = label
    existing.script = script
    existing.scriptUuid = scriptUuid
    existing.lastSeen = now()
    return uuidChanged
end

local function registryRemove(context)
    if PluginRegistry[context] then
        PluginRegistry[context] = nil
        return true
    end
    return false
end

local function updateLastSeen(context)
    local entry = PluginRegistry[context]
    if entry then
        entry.lastSeen = now()
    end
end

local function pruneDeadPlugins()
    local nowUnix = ll.GetUnixTime()

    if LastRegionCrossUnix > 0 and (nowUnix - LastRegionCrossUnix) < PING_TIMEOUT_SEC then
        return 0
    end
    LastRegionCrossUnix = 0

    local cutoff = nowUnix - PING_TIMEOUT_SEC
    local pruned = 0

    for ctx, entry in PluginRegistry do
        if entry.lastSeen < cutoff then
            PluginRegistry[ctx] = nil
            pruned += 1
        end
    end

    return pruned
end

local function pruneMissingScripts()
    local pruned = 0

    for ctx, entry in PluginRegistry do
        if ll.GetInventoryType(entry.script) ~= INVENTORY_SCRIPT then
            PluginRegistry[ctx] = nil
            pruned += 1
        end
    end

    return pruned
end

-- broadcasting

local function broadcastRegisterNow()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE,
        lljson.encode({ type = "register_now" }), "")
end

local function broadcastPing()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE,
        lljson.encode({ type = "ping" }), "")
end

local function broadcastPluginList()
    local plugins = {}
    for ctx, entry in PluginRegistry do
        plugins[#plugins + 1] = { context = ctx, label = entry.label }
    end

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE,
        lljson.encode({ type = "plugin_list", plugins = plugins }), "")
end

-- queue processing

local function processQueue()
    local hasWork = false
    for _ in RegistrationQueue do
        hasWork = true
        break
    end

    if not hasWork then
        return false
    end

    local changesMade = false

    for context, op in RegistrationQueue do
        if op.opType == "REG" then
            if registryUpsert(context, op.label, op.script) then
                changesMade = true
            end
        elseif op.opType == "UNREG" then
            if registryRemove(context) then
                changesMade = true
            end
        end
    end

    RegistrationQueue = {}
    return changesMade
end

-- discovery

local function discoverPlugins()
    local invCount = ll.GetInventoryNumber(INVENTORY_SCRIPT)
    local myName = ll.GetScriptName()
    local discoveries = 0

    for i = 1, invCount do
        local scriptName = ll.GetInventoryName(INVENTORY_SCRIPT, i)
        if scriptName ~= myName then
            local scriptUuid = ll.GetInventoryKey(scriptName)
            if not KnownScriptUUIDs[tostring(scriptUuid)] then
                discoveries += 1
            end
        end
    end

    if discoveries > 0 then
        KnownScriptUUIDs = {}
        for i = 1, invCount do
            local sn = ll.GetInventoryName(INVENTORY_SCRIPT, i)
            if sn ~= myName then
                KnownScriptUUIDs[tostring(ll.GetInventoryKey(sn))] = true
            end
        end
        broadcastRegisterNow()
    end

    return discoveries
end

-- owner change detection

local function checkOwnerChanged()
    local currentOwner = ll.GetOwner()
    if not currentOwner.istruthy then return false end

    if LastOwner.istruthy and currentOwner ~= LastOwner then
        LastOwner = currentOwner
        ll.ResetScript()
        return true
    end

    LastOwner = currentOwner
    return false
end

-- message handlers

local function handleRegister(msg)
    local data = lljson.decode(msg)
    if not data then return end
    if not data.context or not data.label or not data.script then return end
    queueAdd("REG", data.context, data.label, data.script)
end

local function handlePong(msg)
    local data = lljson.decode(msg)
    if not data or not data.context then return end
    updateLastSeen(data.context)
end

local function handlePluginListRequest()
    if PendingBatchTimer then
        PendingPluginListRequest = true
        return
    end
    processQueue()
    broadcastPluginList()
end

local function handleSoftReset()
    PluginRegistry = {}
    RegistrationQueue = {}
    KnownScriptUUIDs = {}
    PendingPluginListRequest = false

    if PendingBatchTimer then
        LLTimers:off(PendingBatchTimer)
        PendingBatchTimer = nil
    end

    broadcastRegisterNow()
end

-- timer callbacks

local function onBatchComplete()
    PendingBatchTimer = nil
    local changes = processQueue()
    if changes or PendingPluginListRequest then
        broadcastPluginList()
        PendingPluginListRequest = false
    end
end

local function onHeartbeat()
    local t = ll.GetUnixTime()
    if t == 0 then return end

    broadcastPing()

    local pruned = pruneDeadPlugins()
    if pruned > 0 then
        broadcastPluginList()
    end
end

local function onInvSweep()
    local pruned = pruneMissingScripts()
    if pruned > 0 then
        broadcastPluginList()
    end
end

local function onDiscovery()
    discoverPlugins()
end

-- startup (replaces state_entry)

local function init()
    LastOwner = ll.GetOwner()
    PluginRegistry = {}
    RegistrationQueue = {}
    KnownScriptUUIDs = {}
    PendingBatchTimer = nil
    PendingPluginListRequest = false
    LastScriptCount = countScripts()
    LastRegionCrossUnix = 0

    broadcastRegisterNow()

    HeartbeatTimer = LLTimers:every(PING_INTERVAL_SEC, onHeartbeat)
    InvSweepTimer = LLTimers:every(INV_SWEEP_INTERVAL, onInvSweep)
    DiscoveryTimer = LLTimers:every(DISCOVERY_INTERVAL_SEC, onDiscovery)
end

-- events

LLEvents:on("on_rez", function(startParam)
    checkOwnerChanged()
end)

LLEvents:on("attach", function(avatarId)
    if not avatarId.istruthy then return end
    checkOwnerChanged()
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    if num ~= KERNEL_LIFECYCLE then return end

    local msgType = getMsgType(msg)
    if msgType == "" then return end

    if msgType == "register" then
        handleRegister(msg)
    elseif msgType == "pong" then
        handlePong(msg)
    elseif msgType == "plugin_list_request" then
        handlePluginListRequest()
    elseif msgType == "soft_reset" or msgType == "soft_reset_all" then
        handleSoftReset()
    end
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        checkOwnerChanged()
    end

    if bit32.btest(change, CHANGED_REGION) then
        LastRegionCrossUnix = ll.GetUnixTime()
        broadcastRegisterNow()
    end

    if bit32.btest(change, CHANGED_INVENTORY) then
        local currentCount = countScripts()
        if currentCount ~= LastScriptCount then
            LastScriptCount = currentCount
            PluginRegistry = {}
            RegistrationQueue = {}
            KnownScriptUUIDs = {}

            if PendingBatchTimer then
                LLTimers:off(PendingBatchTimer)
                PendingBatchTimer = nil
            end

            broadcastRegisterNow()
        end
    end
end)

-- The batch timer callback needs to be wired into queueAdd
-- Override the batch timer creation to use onBatchComplete
local origQueueAdd = queueAdd
queueAdd = function(opType, context, label, script)
    RegistrationQueue[context] = {
        opType = opType,
        label = label,
        script = script,
        timestamp = now()
    }

    if not PendingBatchTimer then
        PendingBatchTimer = LLTimers:once(BATCH_WINDOW_SEC, onBatchComplete)
    end
end

init()
