--[[--------------------
MODULE: kmod_remote.lua
VERSION: 0.10
REVISION: 0
PURPOSE: External HUD communication bridge for remote control workflows
ARCHITECTURE: Consolidated message bus lanes (SLua port)
CHANGES:
- v0.1 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based pending queries replace stride lists.
  LLTimers replaces single-timer multiplexing.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local AUTH_BUS = 700
local UI_BUS = 900

-- External protocol channels
local EXTERNAL_ACL_QUERY_CHAN = -8675309
local EXTERNAL_ACL_REPLY_CHAN = -8675310
local EXTERNAL_MENU_CHAN = -8675311

local MAX_DETECTION_RANGE = 20.0

-- Protocol message types
local ROOT_CONTEXT = "core_root"
local SOS_CONTEXT = "sos_root"

-- State
local aclQueryListenHandle = 0
local menuRequestListenHandle = 0
local collarOwner = NULL_KEY

-- Pending external queries: table keyed by hud_wearer tostring
-- Each entry: { hudObject = key }
local pendingQueries = {}

-- Pending menu requests: table keyed by hud_wearer tostring
-- Each entry: { context = string }
local pendingMenuRequests = {}

-- Query timeout tracking: table keyed by hud_wearer tostring
-- Each entry: timestamp (integer)
local queryTimestamps = {}
local MAX_PENDING_QUERIES = 20
local QUERY_TIMEOUT = 30.0

-- Kernel presence
local kernelAlive = false

-- Rate limiting: table keyed by "avatar_key:request_type"
-- Each entry: timestamp (integer)
local rateLimitTimestamps = {}
local REQUEST_COOLDOWN = 2.0

local REQUEST_TYPE_SCAN = 1
local REQUEST_TYPE_ACL_QUERY = 2
local REQUEST_TYPE_MENU = 3

-- Timer handle
local pruneTimer = nil

-- Helpers

local function now()
    return ll.GetUnixTime()
end

local function rateLimitKey(requester, requestType)
    return tostring(requester) .. ":" .. tostring(requestType)
end

-- Rate limiting

local function checkRateLimit(requester, requestType)
    local nowTime = ll.GetUnixTime()
    local rlKey = rateLimitKey(requester, requestType)

    local lastRequest = rateLimitTimestamps[rlKey]
    if lastRequest then
        if (nowTime - lastRequest) < REQUEST_COOLDOWN then
            return false
        end
    end

    rateLimitTimestamps[rlKey] = nowTime

    -- Prune old entries if table gets large
    local count = 0
    for _ in rateLimitTimestamps do
        count = count + 1
    end
    if count > 40 then
        local cutoff = nowTime - 60
        for k, ts in rateLimitTimestamps do
            if ts < cutoff then
                rateLimitTimestamps[k] = nil
            end
        end
    end

    return true
end

-- Query timeout and pruning

local function pruneExpiredQueries(nowTime)
    for wearerStr, ts in queryTimestamps do
        if (nowTime - ts) > QUERY_TIMEOUT then
            pendingQueries[wearerStr] = nil
            queryTimestamps[wearerStr] = nil
        end
    end
end

-- Query management

local function addPendingQuery(hudWearer, hudObject)
    local nowTime = ll.GetUnixTime()
    local wearerStr = tostring(hudWearer)

    -- Update existing or add new
    if pendingQueries[wearerStr] then
        pendingQueries[wearerStr] = { hudObject = hudObject }
        queryTimestamps[wearerStr] = nowTime
        return
    end

    -- Prune expired before adding
    pruneExpiredQueries(nowTime)

    -- Check limit
    local count = 0
    local oldestKey = nil
    local oldestTime = nowTime + 1
    for k, ts in queryTimestamps do
        count = count + 1
        if ts < oldestTime then
            oldestTime = ts
            oldestKey = k
        end
    end

    if count >= MAX_PENDING_QUERIES and oldestKey then
        pendingQueries[oldestKey] = nil
        queryTimestamps[oldestKey] = nil
    end

    pendingQueries[wearerStr] = { hudObject = hudObject }
    queryTimestamps[wearerStr] = nowTime
end

local function findPendingQuery(hudWearer)
    return pendingQueries[tostring(hudWearer)]
end

local function removePendingQuery(hudWearer)
    local wearerStr = tostring(hudWearer)
    pendingQueries[wearerStr] = nil
    queryTimestamps[wearerStr] = nil
end

-- Internal ACL communication

local function requestInternalAcl(avatarKey)
    ll.MessageLinked(LINK_SET, AUTH_BUS,
        lljson.encode({
            type = "acl_query",
            avatar = tostring(avatarKey),
            id = "remote_" .. tostring(avatarKey)
        }), NULL_KEY)
end

local function sendExternalAclResponse(hudWearer, level)
    ll.RegionSay(EXTERNAL_ACL_REPLY_CHAN,
        lljson.encode({
            type = "acl_result_external",
            avatar = tostring(hudWearer),
            level = tostring(level),
            collar_owner = tostring(collarOwner)
        }))
end

-- Menu triggering

local function triggerMenuForExternalUser(userKey, context)
    ll.MessageLinked(LINK_SET, UI_BUS,
        lljson.encode({
            type = "start",
            context = context
        }), userKey)
end

-- External protocol handlers

local function handleCollarScan(message)
    local data = lljson.decode(message)
    if not data or not data.hud_wearer then return end

    local hudWearer = key(data.hud_wearer)
    if hudWearer == NULL_KEY then return end

    if not checkRateLimit(hudWearer, REQUEST_TYPE_SCAN) then return end

    local agentData = ll.GetObjectDetails(hudWearer, {OBJECT_POS})
    if #agentData == 0 then return end

    local hudWearerPos = agentData[1]
    local collarOwnerPos = ll.GetPos()
    local distance = ll.VecDist(hudWearerPos, collarOwnerPos)

    if distance > MAX_DETECTION_RANGE then return end

    ll.RegionSay(EXTERNAL_ACL_REPLY_CHAN,
        lljson.encode({
            type = "collar_scan_response",
            collar_owner = tostring(collarOwner)
        }))
end

local function handleAclQueryExternal(message)
    local data = lljson.decode(message)
    if not data or not data.avatar or not data.hud or not data.target_avatar then return end

    local hudWearer = key(data.avatar)
    local hudObject = key(data.hud)
    local targetAvatar = key(data.target_avatar)

    if hudWearer == NULL_KEY then return end
    if hudObject == NULL_KEY then return end
    if targetAvatar == NULL_KEY then return end

    if not checkRateLimit(hudWearer, REQUEST_TYPE_ACL_QUERY) then return end

    if targetAvatar ~= collarOwner then return end

    addPendingQuery(hudWearer, hudObject)
    requestInternalAcl(hudWearer)
end

local function handleMenuRequestExternal(message)
    local data = lljson.decode(message)
    if not data or not data.avatar then return end

    local hudWearer = key(data.avatar)
    if hudWearer == NULL_KEY then return end

    local context = ROOT_CONTEXT
    if data.context then
        context = data.context
    end

    if not checkRateLimit(hudWearer, REQUEST_TYPE_MENU) then return end

    -- Range check
    local agentData = ll.GetObjectDetails(hudWearer, {OBJECT_POS})
    if #agentData == 0 then return end

    local hudWearerPos = agentData[1]
    local distance = ll.VecDist(hudWearerPos, ll.GetPos())

    if distance > MAX_DETECTION_RANGE then return end

    -- Check if already pending
    local wearerStr = tostring(hudWearer)
    if pendingMenuRequests[wearerStr] then return end

    pendingMenuRequests[wearerStr] = { context = context }
    requestInternalAcl(hudWearer)
end

-- Update protocol handler

local function handleUpdateDiscover(message)
    local data = lljson.decode(message)
    if not data or not data.updater or not data.session then return end

    local updater = key(data.updater)
    local session = data.session

    local details = ll.GetObjectDetails(updater, {OBJECT_POS})
    if #details == 0 then return end

    local updaterPos = details[1]
    local distance = ll.VecDist(ll.GetPos(), updaterPos)

    if distance > MAX_DETECTION_RANGE then return end

    local hasKernel = kernelAlive
    local hasReceiver = (ll.GetInventoryType("ds_collar_receiver") == INVENTORY_SCRIPT)

    local scriptPin = math.floor(ll.Frand(1e08))
    ll.SetRemoteScriptAccessPin(scriptPin)

    ll.RegionSayTo(updater, EXTERNAL_ACL_REPLY_CHAN,
        lljson.encode({
            type = "collar_ready",
            collar = tostring(ll.GetKey()),
            owner = tostring(collarOwner),
            wearer = tostring(ll.GetOwner()),
            session = session,
            pin = tostring(scriptPin),
            has_kernel = tostring(hasKernel),
            has_receiver = tostring(hasReceiver)
        }))

    ll.OwnerSay("Update ready. PIN generated for secure transfer.")
end

-- ACL result handler (from link_message on AUTH_BUS)

local function handleAclResult(msg)
    local data = lljson.decode(msg)
    if not data or not data.avatar then return end

    local avatarKey = key(data.avatar)

    local level = 0
    if data.level then
        level = tonumber(data.level) or 0
    end

    -- Check if this is a menu request ACL verification
    local wearerStr = tostring(avatarKey)
    local menuEntry = pendingMenuRequests[wearerStr]

    if menuEntry then
        local requestedContext = menuEntry.context
        pendingMenuRequests[wearerStr] = nil

        -- TPE MODE EMERGENCY ACCESS: Allow wearer to access SOS menu even with ACL 0
        local isWearer = (avatarKey == ll.GetOwner())
        local emergencyAccess = (level == 0 and requestedContext == SOS_CONTEXT and isWearer)

        if level >= 1 or emergencyAccess then
            local finalContext = requestedContext
            if requestedContext == SOS_CONTEXT and not isWearer then
                finalContext = ROOT_CONTEXT
                ll.RegionSayTo(avatarKey, 0,
                    "Only the collar wearer can access the SOS menu. Showing main menu instead.")
            end

            triggerMenuForExternalUser(avatarKey, finalContext)
        end
        return
    end

    -- Check if this is a response to a pending external query
    local queryEntry = findPendingQuery(avatarKey)
    if not queryEntry then return end

    sendExternalAclResponse(avatarKey, level)
    removePendingQuery(avatarKey)
end

-- Init (replaces state_entry)

local function init()
    if aclQueryListenHandle ~= 0 then
        ll.ListenRemove(aclQueryListenHandle)
    end
    if menuRequestListenHandle ~= 0 then
        ll.ListenRemove(menuRequestListenHandle)
    end

    pendingQueries = {}
    pendingMenuRequests = {}
    queryTimestamps = {}
    rateLimitTimestamps = {}
    collarOwner = ll.GetOwner()

    aclQueryListenHandle = ll.Listen(EXTERNAL_ACL_QUERY_CHAN, "", NULL_KEY, "")
    menuRequestListenHandle = ll.Listen(EXTERNAL_MENU_CHAN, "", NULL_KEY, "")

    pruneTimer = LLTimers:every(60.0, function()
        pruneExpiredQueries(now())
    end)
end

-- Events

LLEvents:on("on_rez", function(startParam)
    ll.ResetScript()
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

LLEvents:on("listen", function(channel, name, speakerId, message)
    if channel == EXTERNAL_ACL_QUERY_CHAN then
        local data = lljson.decode(message)
        if not data or not data.type then return end

        if data.type == "collar_scan" then
            handleCollarScan(message)
        elseif data.type == "acl_query_external" then
            handleAclQueryExternal(message)
        elseif data.type == "update_discover" then
            handleUpdateDiscover(message)
        end
        return
    end

    if channel == EXTERNAL_MENU_CHAN then
        local data = lljson.decode(message)
        if not data or not data.type then return end

        if data.type == "menu_request_external" then
            handleMenuRequestExternal(message)
        end
        return
    end
end)

LLEvents:on("link_message", function(senderNum, num, str, id)
    local data = lljson.decode(str)
    if not data or not data.type then return end
    local msgType = data.type

    if num == KERNEL_LIFECYCLE then
        kernelAlive = true
        if msgType == "soft_reset" or msgType == "soft_reset_all" then
            ll.ResetScript()
        end
        return
    end

    if num == AUTH_BUS then
        if msgType == "acl_result" then
            handleAclResult(str)
        end
        return
    end
end)

init()
