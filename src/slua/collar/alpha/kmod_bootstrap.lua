--[[--------------------
MODULE: kmod_bootstrap.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Startup coordination, RLV detection, owner name resolution
ARCHITECTURE: Consolidated message bus lanes (SLua alpha port from LSL 1.10)
CHANGES:
- v0.10 rev 0: Alpha port from LSL kmod_bootstrap.lsl v1.10.
  Bootstrap no longer manages UI policies — each plugin self-declares
  via ll.LinksetDataWrite.
--------------------]]


-- -------------------- CONSOLIDATED ABI --------------------
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800

-- -------------------- RLV DETECTION CONFIG --------------------
local RLV_PROBE_TIMEOUT_SEC = 60
local RLV_RETRY_INTERVAL_SEC = 5
local RLV_MAX_RETRIES = 10
local RLV_INITIAL_DELAY_SEC = 5

-- Probe multiple channels for better compatibility
local useFixed4711 = false
local useRelayChan = false
local RELAY_CHAN = -1812221819
local probeRelayBothSigns = false  -- Also try positive relay channel

-- -------------------- DISPLAY NAME REQUEST RATE LIMITING --------------------
local NAME_REQUEST_INTERVAL_SEC = 2.5  -- Space requests 2.5s apart to avoid throttling

-- -------------------- SETTINGS KEYS --------------------
local KEY_MULTI_OWNER_MODE = "access.multiowner"
local KEY_OWNER = "access.owner"
local KEY_OWNERS = "access.owners"

-- -------------------- BOOTSTRAP CONFIG --------------------
local BOOTSTRAP_TIMEOUT_SEC = 90
local SETTINGS_RETRY_INTERVAL_SEC = 5
local SETTINGS_MAX_RETRIES = 3
local SETTINGS_INITIAL_DELAY_SEC = 5  -- Wait for linkset data + notecard load

-- -------------------- STATE --------------------
local bootstrapComplete = false
local bootstrapDeadline = 0

-- Owner tracking
local lastOwner = NULL_KEY

-- RLV detection
local rlvChannels = {}           -- channel -> listen handle
local rlvChannelList = {}        -- array of channels (for iteration/query)
local rlvProbing = false
local rlvActive = false
local rlvVersion = ""
local rlvProbeDeadline = 0
local rlvNextRetry = 0
local rlvRetryCount = 0
local rlvReady = false

-- Settings
local settingsReceived = false
local settingsRetryCount = 0
local settingsNextRetry = 0
local multiOwnerMode = false
local ownerKey = NULL_KEY
local ownerKeys = {}             -- array of owner uuid strings
local ownerHonorific = ""
local ownersJson = {}            -- table: uuid -> honorific

-- Name resolution
local ownerNameQueries = {}      -- queryId -> ownerKey
local ownerDisplayNames = {}     -- array parallel to ownerKeys (or single entry)
local nameResolutionDeadline = 0
local NAME_RESOLUTION_TIMEOUT_SEC = 30

-- Name request queue (rate-limited)
local pendingNameRequests = {}   -- array of owner keys waiting for display name requests
local nextNameRequestTime = 0    -- Timestamp when next request can be sent

-- State machine
local currentState = "default"   -- "default", "starting", "running"

-- Timer handle
local timerHandle = nil

-- -------------------- HELPERS --------------------

local function getMsgType(msg)
    local data = lljson.decode(msg)
    if data == nil then return "" end
    if data.type == nil then return "" end
    return data.type
end

local function now()
    return ll.GetUnixTime()
end

local function sendIM(msg)
    local wearer = ll.GetOwner()
    if wearer:istruthy() and msg ~= "" then
        ll.InstantMessage(wearer, msg)
    end
end

local function isAttached()
    return ll.GetAttached() ~= 0
end

-- Forward declarations
local startBootstrap
local checkBootstrapComplete
local announceStatus
local startNameResolution
local enterStateStarting
local enterStateRunning

-- Owner change detection (prevents unnecessary resets on teleport)
local function checkOwnerChanged()
    local currentOwner = ll.GetOwner()
    if not currentOwner:istruthy() then return false end

    if lastOwner:istruthy() and currentOwner ~= lastOwner then
        lastOwner = currentOwner
        ll.ResetScript()
        return true
    end

    lastOwner = currentOwner
    return false
end

-- -------------------- RLV DETECTION - Multi-Channel Approach --------------------

local function addProbeChannel(ch)
    if ch == 0 then return end
    if rlvChannels[ch] ~= nil then return end  -- Already added

    local handle = ll.Listen(ch, "", NULL_KEY, "")  -- Accept from anyone (NULL_KEY important!)
    rlvChannels[ch] = handle
    table.insert(rlvChannelList, ch)
end

local function clearProbeChannels()
    for ch, handle in pairs(rlvChannels) do
        if handle ~= 0 then
            ll.ListenRemove(handle)
        end
    end
    rlvChannels = {}
    rlvChannelList = {}
end

local function sendRlvQueries()
    for _, ch in ipairs(rlvChannelList) do
        ll.OwnerSay("@versionnew=" .. tostring(ch))
    end
end

local function stopRlvProbe()
    clearProbeChannels()
    rlvProbing = false
    rlvReady = true
end

local function startRlvProbe()
    if rlvProbing then
        return
    end

    if not isAttached() then
        -- Not attached, can't detect RLV
        rlvReady = true
        rlvActive = false
        rlvVersion = ""
        return
    end

    rlvProbing = true
    rlvActive = false
    rlvVersion = ""
    rlvRetryCount = 0
    rlvReady = false

    clearProbeChannels()

    -- Set up multiple probe channels
    if useFixed4711 then addProbeChannel(4711) end
    if useRelayChan then
        addProbeChannel(RELAY_CHAN)
        if probeRelayBothSigns then
            addProbeChannel(-RELAY_CHAN)  -- Try opposite sign too
        end
    end

    rlvProbeDeadline = now() + RLV_PROBE_TIMEOUT_SEC
    rlvNextRetry = now() + RLV_INITIAL_DELAY_SEC  -- Initial delay before first probe

    sendIM("Detecting RLV...")
end

-- -------------------- SETTINGS LOADING --------------------

local function requestSettings()
    local msg = lljson.encode({
        type = "settings_get"
    })
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY)
end

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if data == nil then return end
    local kvData = data.kv
    if kvData == nil then return end

    -- If kv is a string (nested JSON), decode it
    if type(kvData) == "string" then
        kvData = lljson.decode(kvData)
        if kvData == nil then return end
    end

    -- Reset
    multiOwnerMode = false
    ownerKey = NULL_KEY
    ownerKeys = {}
    ownerHonorific = ""
    ownersJson = {}

    -- Load
    local tmp = kvData[KEY_MULTI_OWNER_MODE]
    if tmp ~= nil then
        multiOwnerMode = (tonumber(tmp) or 0) ~= 0
    end

    -- Single owner: JSON object {uuid:honorific}
    local obj = kvData[KEY_OWNER]
    if obj ~= nil and type(obj) == "table" then
        for uuid, hon in pairs(obj) do
            ownerKey = uuid
            ownerHonorific = hon
        end
    end

    -- Multi-owner: JSON object {uuid:honorific, ...}
    obj = kvData[KEY_OWNERS]
    if obj ~= nil and type(obj) == "table" then
        ownersJson = obj
        for uuid, _ in pairs(obj) do
            table.insert(ownerKeys, uuid)
        end
    end

    settingsReceived = true

    -- Start name resolution
    startNameResolution()
end

-- -------------------- NAME RESOLUTION --------------------

-- Forward declaration
local processNextNameRequest

processNextNameRequest = function()
    local currentTime = ll.GetUnixTime()
    if currentTime == 0 then return end  -- Overflow protection

    -- Check if we have any pending requests
    if #pendingNameRequests == 0 then return end

    -- Check if we're allowed to make a request yet
    if nextNameRequestTime > 0 and currentTime < nextNameRequestTime then return end

    -- Get next owner key from queue
    local owner = table.remove(pendingNameRequests, 1)

    -- Make the request
    if owner ~= NULL_KEY then
        local queryId = ll.RequestDisplayName(owner)
        ownerNameQueries[queryId] = owner

        -- Find the index for this owner
        local ownerIdx = nil
        if multiOwnerMode then
            ownerIdx = table.find(ownerKeys, tostring(owner))
        else
            if owner == ownerKey then ownerIdx = 1 end
        end

        -- Initialize display name placeholder
        if ownerIdx ~= nil then
            if ownerIdx > #ownerDisplayNames then
                table.insert(ownerDisplayNames, "(loading...)")
            end
        end

        -- Schedule next request
        local nextTime = currentTime + math.floor(NAME_REQUEST_INTERVAL_SEC)
        if nextTime > currentTime then  -- Overflow protection
            nextNameRequestTime = nextTime
        else
            nextNameRequestTime = currentTime
        end
    end
end

startNameResolution = function()
    ownerNameQueries = {}
    ownerDisplayNames = {}
    pendingNameRequests = {}
    nextNameRequestTime = 0

    local currentTime = ll.GetUnixTime()
    if currentTime > 0 then
        local deadline = currentTime + NAME_RESOLUTION_TIMEOUT_SEC
        if deadline > currentTime then
            nameResolutionDeadline = deadline
        else
            nameResolutionDeadline = currentTime
        end
    end

    if multiOwnerMode then
        -- Multi-owner: queue all owner keys for rate-limited requests
        for i = 1, #ownerKeys do
            local ownerStr = ownerKeys[i]
            if ownerStr ~= NULL_KEY then
                table.insert(pendingNameRequests, ownerStr)
                table.insert(ownerDisplayNames, "(loading...)")
            end
        end
    else
        -- Single owner: queue one request
        if ownerKey ~= NULL_KEY then
            table.insert(pendingNameRequests, ownerKey)
            table.insert(ownerDisplayNames, "(loading...)")
        end
    end

    -- If no owners, we're done
    if #pendingNameRequests == 0 then
        checkBootstrapComplete()
    else
        -- Start processing the queue
        processNextNameRequest()
    end
end

local function handleDataserverName(queryId, name)
    -- Find this query
    local owner = ownerNameQueries[queryId]
    if owner ~= nil then
        -- Update display name
        local ownerIdx = nil
        if multiOwnerMode then
            ownerIdx = table.find(ownerKeys, tostring(owner))
        else
            if owner == ownerKey then ownerIdx = 1 end
        end

        if ownerIdx ~= nil and ownerIdx <= #ownerDisplayNames then
            ownerDisplayNames[ownerIdx] = name
        end

        -- Remove this query
        ownerNameQueries[queryId] = nil

        -- Check if all names resolved
        local queryCount = 0
        for _ in pairs(ownerNameQueries) do queryCount = queryCount + 1 end
        if queryCount == 0 then
            checkBootstrapComplete()
        end
    end
end

-- -------------------- HELPER: count table keys --------------------

local function countQueries()
    local n = 0
    for _ in pairs(ownerNameQueries) do n = n + 1 end
    return n
end

-- -------------------- BOOTSTRAP COMPLETION --------------------

checkBootstrapComplete = function()
    if bootstrapComplete then return end

    -- Check all conditions
    -- CRITICAL: Must check BOTH ownerNameQueries (sent requests) AND pendingNameRequests (queued requests)
    if rlvReady and settingsReceived and
        countQueries() == 0 and
        #pendingNameRequests == 0 then
        bootstrapComplete = true

        -- Announce final status
        announceStatus()
    end
end

announceStatus = function()
    -- RLV Status
    if rlvActive then
        sendIM("RLV: " .. rlvVersion)
    else
        sendIM("RLV: Not detected")
    end

    -- Mode notification
    if not settingsReceived then
        sendIM("WARNING: Settings timed out. Using defaults.")
    end

    if multiOwnerMode then
        local ownerCount = #ownerKeys
        sendIM("Mode: Multi-Owner (" .. tostring(ownerCount) .. ")")
    else
        sendIM("Mode: Single-Owner")
    end

    -- Ownership status
    if multiOwnerMode then
        local ownerCount = #ownerKeys
        if ownerCount > 0 then
            local ownerParts = {}
            for i = 1, ownerCount do
                local ownerUuid = ownerKeys[i]
                local hon = ownersJson[ownerUuid] or ""

                local displayName = ""
                if i <= #ownerDisplayNames then
                    displayName = ownerDisplayNames[i]
                end

                if hon ~= "" then
                    table.insert(ownerParts, hon .. " " .. displayName)
                else
                    table.insert(ownerParts, displayName)
                end
            end
            sendIM("Owned by " .. table.concat(ownerParts, ", "))
        else
            sendIM("Uncommitted")
        end
    else
        if ownerKey ~= NULL_KEY then
            local ownerLine = "Owned by "
            if ownerHonorific ~= "" then
                ownerLine = ownerLine .. ownerHonorific .. " "
            end
            ownerLine = ownerLine .. (ownerDisplayNames[1] or "")
            sendIM(ownerLine)
        else
            sendIM("Uncommitted")
        end
    end

    sendIM("Collar startup complete.")
end

-- -------------------- BOOTSTRAP INITIATION --------------------

startBootstrap = function()
    bootstrapComplete = false
    settingsReceived = false
    settingsRetryCount = 0
    nameResolutionDeadline = 0
    pendingNameRequests = {}
    nextNameRequestTime = 0

    bootstrapDeadline = now() + BOOTSTRAP_TIMEOUT_SEC

    sendIM("D/s Collar starting up. Please wait...")

    startRlvProbe()

    -- OPTIMIZATION: Delay initial settings request to allow notecard loading
    -- This prevents "double bootstrap" where we get defaults then reset on notecard_loaded
    settingsNextRetry = now() + SETTINGS_INITIAL_DELAY_SEC

    -- Start 1-second tick timer
    if timerHandle ~= nil then
        LLTimers:off(timerHandle)
    end
    timerHandle = LLTimers:every(1.0, function()
        if currentState == "starting" then
            onStartingTimer()
        end
    end)
end

-- -------------------- STATE: starting - timer handler --------------------

function onStartingTimer()
    local currentTime = ll.GetUnixTime()
    if currentTime == 0 then return end  -- Overflow protection

    -- GLOBAL TIMEOUT CHECK
    if not bootstrapComplete and bootstrapDeadline > 0 and currentTime >= bootstrapDeadline then
        sendIM("WARNING: Bootstrap timed out. Forcing completion.")

        -- Force completion of pending tasks
        if not rlvReady then stopRlvProbe() end
        if not settingsReceived then
            settingsReceived = true  -- Assume defaults
            -- Start name resolution with defaults (likely just wearer if unowned)
            startNameResolution()
        end

        -- Clear pending name queries
        ownerNameQueries = {}
        pendingNameRequests = {}

        bootstrapComplete = true
        announceStatus()
        enterStateRunning()
        return
    end

    -- Handle Settings Retries
    if not settingsReceived and currentTime >= settingsNextRetry then
        if settingsRetryCount < SETTINGS_MAX_RETRIES then
            requestSettings()
            settingsRetryCount = settingsRetryCount + 1
            settingsNextRetry = currentTime + SETTINGS_RETRY_INTERVAL_SEC
        end
    end

    -- Handle RLV probe retries
    if rlvProbing and not rlvReady then
        -- Check if we should send another query
        if rlvNextRetry > 0 and currentTime >= rlvNextRetry then
            if rlvRetryCount < RLV_MAX_RETRIES then
                sendRlvQueries()
                rlvRetryCount = rlvRetryCount + 1
                local nextRetryTime = currentTime + RLV_RETRY_INTERVAL_SEC
                if nextRetryTime < currentTime then nextRetryTime = currentTime end  -- Overflow protection
                rlvNextRetry = nextRetryTime
            end
        end

        -- Check for timeout
        if rlvProbeDeadline > 0 and currentTime >= rlvProbeDeadline then
            stopRlvProbe()
            checkBootstrapComplete()
        end
    end

    -- Process queued display name requests (rate-limited)
    if #pendingNameRequests > 0 then
        processNextNameRequest()
    end

    -- Check name resolution timeout
    if (countQueries() > 0 or #pendingNameRequests > 0) and
        nameResolutionDeadline > 0 and currentTime >= nameResolutionDeadline then
        ownerNameQueries = {}      -- Clear pending queries
        pendingNameRequests = {}    -- Clear pending requests
        checkBootstrapComplete()
    end

    -- Transition to running if bootstrap complete
    if bootstrapComplete and not rlvProbing and
        countQueries() == 0 and
        #pendingNameRequests == 0 then
        enterStateRunning()
    end
end

-- -------------------- STATE TRANSITIONS --------------------

enterStateRunning = function()
    currentState = "running"
    if timerHandle ~= nil then
        LLTimers:off(timerHandle)
        timerHandle = nil
    end
end

enterStateStarting = function()
    currentState = "starting"
    startBootstrap()
end

local function enterStateDefault()
    currentState = "default"

    useFixed4711 = true
    useRelayChan = true
    probeRelayBothSigns = true

    lastOwner = ll.GetOwner()

    enterStateStarting()
end

-- -------------------- EVENT HANDLERS --------------------

LLEvents:on("on_rez", function(startParam)
    if currentState == "starting" or currentState == "running" then
        -- Only reset if owner changed - prevents bootstrap on every teleport
        checkOwnerChanged()
    end
end)

LLEvents:on("attach", function(id)
    if not id:istruthy() then return end
    if currentState == "starting" or currentState == "running" then
        -- Bootstrap on attach (covers logon and initial attach)
        ll.ResetScript()
    end
end)

LLEvents:on("listen", function(channel, name, id, message)
    if currentState ~= "starting" then return end

    -- Check if this is one of our probe channels
    if rlvChannels[channel] == nil then return end

    -- Accept replies from wearer OR NULL_KEY (some viewers use NULL_KEY for RLV)
    local wearer = ll.GetOwner()
    if id ~= wearer and id ~= NULL_KEY then return end

    -- Any reply means RLV is active
    rlvActive = true
    rlvVersion = ll.StringTrim(message, STRING_TRIM)

    -- Stop probing immediately
    stopRlvProbe()
    checkBootstrapComplete()
end)

LLEvents:on("dataserver", function(queryId, data)
    if currentState ~= "starting" then return end
    -- Handle display name responses
    handleDataserverName(queryId, data)
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    local msgType = getMsgType(msg)
    if msgType == "" then return end

    if currentState == "starting" then
        -- -------------------- SETTINGS BUS --------------------
        if num == SETTINGS_BUS then
            if msgType == "settings_sync" then
                applySettingsSync(msg)
            end

        -- -------------------- KERNEL LIFECYCLE --------------------
        elseif num == KERNEL_LIFECYCLE then
            if msgType == "notecard_loaded" then
                -- Settings notecard was loaded/reloaded - re-run bootstrap
                startBootstrap()
            elseif msgType == "soft_reset" or msgType == "soft_reset_all" then
                ll.ResetScript()
            end
        end

    elseif currentState == "running" then
        if num == KERNEL_LIFECYCLE then
            if msgType == "notecard_loaded" then
                ll.ResetScript()
            elseif msgType == "soft_reset" or msgType == "soft_reset_all" then
                ll.ResetScript()
            end
        end
    end
end)

LLEvents:on("changed", function(change)
    if currentState == "starting" or currentState == "running" then
        if bit32.btest(change, CHANGED_OWNER) then
            checkOwnerChanged()
        end
    end
end)

-- -------------------- ENTRY POINT --------------------
enterStateDefault()
