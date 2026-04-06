--[[--------------------
SCRIPT: control_hud.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Auto-detect nearby collars and connect automatically
ARCHITECTURE: RLV relay-style broadcast and listen workflow (SLua port)
CHANGES:
- v0.1 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based collar list replaces stride lists.
  LLTimers replaces single-timer multiplexing.
--------------------]]

-- External protocol channels
local COLLAR_ACL_QUERY_CHAN = -8675309
local COLLAR_ACL_REPLY_CHAN = -8675310
local COLLAR_MENU_CHAN      = -8675311

-- ACL constants
local ACL_NOACCESS      = 0
local ACL_PUBLIC        = 1
local ACL_OWNED         = 2
local ACL_TRUSTEE       = 3
local ACL_UNOWNED       = 4
local ACL_PRIMARY_OWNER = 5

-- Dialog settings
local QUERY_TIMEOUT_SEC     = 3.0
local COLLAR_SCAN_TIME      = 2.0
local LONG_TOUCH_THRESHOLD  = 1.5
local MAX_DIALOG_BUTTONS    = 12

-- Context constants
local ROOT_CONTEXT = "core_root"
local SOS_CONTEXT  = "sos_root"

-- Session state
local dialogChannel = 0
local hudWearer = NULL_KEY
local collarListenHandle = 0
local dialogListenHandle = 0

local scanningForCollars = false
local aclPending = false
local displayNamePending = false
local aclLevel = ACL_NOACCESS

local targetCollarKey = NULL_KEY
local targetAvatarKey = NULL_KEY
local targetAvatarName = ""

-- Detected collars: list of { avatarKey, collarKey, avatarName }
local detectedCollars = {}

-- Touch tracking
local touchStartTime = 0.0
local requestedContext = ""

-- Display name lookup
local displayNameQueryId = NULL_KEY

-- Timer handles
local scanTimer = nil
local queryTimer = nil
local dialogTimer = nil

-- -------------------- SESSION MANAGEMENT --------------------

local function cleanupSession()
    if collarListenHandle ~= 0 then
        ll.ListenRemove(collarListenHandle)
        collarListenHandle = 0
    end
    if dialogListenHandle ~= 0 then
        ll.ListenRemove(dialogListenHandle)
        dialogListenHandle = 0
    end

    scanningForCollars = false
    aclPending = false
    displayNamePending = false
    aclLevel = ACL_NOACCESS
    targetCollarKey = NULL_KEY
    targetAvatarKey = NULL_KEY
    targetAvatarName = ""
    detectedCollars = {}
    touchStartTime = 0.0
    requestedContext = ""
    displayNameQueryId = NULL_KEY

    if scanTimer then LLTimers:cancel(scanTimer); scanTimer = nil end
    if queryTimer then LLTimers:cancel(queryTimer); queryTimer = nil end
    if dialogTimer then LLTimers:cancel(dialogTimer); dialogTimer = nil end
end

-- -------------------- COLLAR DETECTION --------------------

local function addDetectedCollar(avatarKey, collarKey, avatarName)
    for _, entry in ipairs(detectedCollars) do
        if entry.avatarKey == avatarKey then
            return
        end
    end
    table.insert(detectedCollars, {
        avatarKey = avatarKey,
        collarKey = collarKey,
        avatarName = avatarName
    })
end

-- Forward declarations
local requestAclFromCollar
local showCollarSelectionDialog

local function processScanResults()
    scanningForCollars = false
    if scanTimer then LLTimers:cancel(scanTimer); scanTimer = nil end

    local numCollars = #detectedCollars

    if numCollars == 0 then
        ll.OwnerSay("No collars found nearby.")
        cleanupSession()
        return
    end

    if numCollars == 1 then
        requestAclFromCollar(detectedCollars[1].avatarKey)
        return
    end

    showCollarSelectionDialog()
end

local function broadcastCollarScan(context)
    requestedContext = context

    local jsonMsg = lljson.encode({
        type = "collar_scan",
        hud_wearer = tostring(hudWearer)
    })

    if collarListenHandle ~= 0 then
        ll.ListenRemove(collarListenHandle)
    end
    collarListenHandle = ll.Listen(COLLAR_ACL_REPLY_CHAN, "", NULL_KEY, "")

    ll.RegionSay(COLLAR_ACL_QUERY_CHAN, jsonMsg)

    scanningForCollars = true
    detectedCollars = {}

    if scanTimer then LLTimers:cancel(scanTimer) end
    scanTimer = LLTimers:once(COLLAR_SCAN_TIME, function()
        scanTimer = nil
        processScanResults()
    end)

    ll.OwnerSay("Scanning for nearby collars...")
end

-- -------------------- COLLAR SELECTION DIALOG --------------------

showCollarSelectionDialog = function()
    local numCollars = #detectedCollars
    if numCollars == 0 then return end

    if dialogListenHandle ~= 0 then
        ll.ListenRemove(dialogListenHandle)
    end
    dialogListenHandle = ll.Listen(dialogChannel, "", hudWearer, "")

    local text = "Multiple collars found. Select one:\n\n"
    local buttons = {}

    for i = 1, numCollars do
        if #buttons >= MAX_DIALOG_BUTTONS then
            break -- SLua supports break
        end
        table.insert(buttons, detectedCollars[i].avatarName)
    end

    if #buttons < MAX_DIALOG_BUTTONS then
        table.insert(buttons, "Cancel")
    end

    ll.Dialog(hudWearer, text, buttons, dialogChannel)

    if dialogTimer then LLTimers:cancel(dialogTimer) end
    dialogTimer = LLTimers:once(30.0, function()
        dialogTimer = nil
        ll.OwnerSay("Selection dialog timed out.")
        cleanupSession()
    end)
end

-- -------------------- ACL QUERY --------------------

requestAclFromCollar = function(avatarKey)
    local jsonMsg = lljson.encode({
        type = "acl_query_external",
        avatar = tostring(hudWearer),
        hud = tostring(ll.GetKey()),
        target_avatar = tostring(avatarKey)
    })

    if collarListenHandle ~= 0 then
        ll.ListenRemove(collarListenHandle)
    end
    collarListenHandle = ll.Listen(COLLAR_ACL_REPLY_CHAN, "", NULL_KEY, "")

    ll.RegionSay(COLLAR_ACL_QUERY_CHAN, jsonMsg)

    aclPending = true
    targetAvatarKey = avatarKey
    targetAvatarName = ll.Key2Name(avatarKey)

    if queryTimer then LLTimers:cancel(queryTimer) end
    queryTimer = LLTimers:once(QUERY_TIMEOUT_SEC, function()
        queryTimer = nil
        if aclPending then
            ll.OwnerSay("Connection failed: No response from collar.")
            cleanupSession()
        elseif displayNamePending then
            ll.OwnerSay("Connection failed: Unable to retrieve name.")
            cleanupSession()
        end
    end)
end

-- -------------------- MENU TRIGGERING --------------------

local function triggerCollarMenu()
    if targetCollarKey == NULL_KEY then
        ll.OwnerSay("Error: No collar connection established.")
        return
    end

    displayNameQueryId = ll.RequestAgentData(targetAvatarKey, DATA_NAME)
    displayNamePending = true

    if queryTimer then LLTimers:cancel(queryTimer) end
    queryTimer = LLTimers:once(QUERY_TIMEOUT_SEC, function()
        queryTimer = nil
        if displayNamePending then
            ll.OwnerSay("Connection failed: Unable to retrieve name.")
            cleanupSession()
        end
    end)
end

-- -------------------- ACL LEVEL PROCESSING --------------------

local function processAclResult(level)
    local hasAccess = (
        level == ACL_PRIMARY_OWNER or
        level == ACL_TRUSTEE or
        level == ACL_OWNED or
        level == ACL_UNOWNED or
        level == ACL_PUBLIC
    )

    -- EMERGENCY ACCESS: Allow wearer to access SOS menu even with ACL 0
    if level == ACL_NOACCESS and requestedContext == SOS_CONTEXT and hudWearer == targetAvatarKey then
        hasAccess = true
    end

    if hasAccess then
        triggerCollarMenu()
    else
        ll.OwnerSay("Access denied.")
        cleanupSession()
    end
end

-- -------------------- EVENTS --------------------

local function init()
    dialogChannel = math.floor(ll.Frand(-1000000.0) - 1000000)
    cleanupSession()
    hudWearer = ll.GetOwner()
    touchStartTime = 0.0
    requestedContext = ""
    ll.OwnerSay("Control HUD ready. Touch to scan for collars, long-touch for emergency access.")
end

LLEvents:on("on_rez", function(startParam)
    ll.ResetScript()
end)

LLEvents:on("attach", function(id)
    if id.istruthy then
        ll.ResetScript()
    else
        cleanupSession()
    end
end)

LLEvents:on("changed", function(changeMask)
    if bit32.btest(changeMask, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

LLEvents:on("touch_start", function(events)
    if scanningForCollars then
        ll.OwnerSay("Scan already in progress...")
        return
    end

    if aclPending then
        ll.OwnerSay("Still waiting for collar response...")
        return
    end

    touchStartTime = ll.GetTime()
end)

LLEvents:on("touch_end", function(events)
    if scanningForCollars or aclPending then
        touchStartTime = 0.0
        return
    end

    local duration = ll.GetTime() - touchStartTime
    touchStartTime = 0.0

    cleanupSession()

    local context = ROOT_CONTEXT
    if duration >= LONG_TOUCH_THRESHOLD then
        context = SOS_CONTEXT
    end

    broadcastCollarScan(context)
end)

LLEvents:on("listen", function(channel, name, id, message)
    -- Handle collar scan responses
    if channel == COLLAR_ACL_REPLY_CHAN and scanningForCollars then
        local data = lljson.decode(message)
        if not data then return end
        if data.type ~= "collar_scan_response" then return end

        if not data.collar_owner then return end
        local collarOwner = tokey(data.collar_owner)
        local ownerName = ll.Key2Name(collarOwner)

        addDetectedCollar(collarOwner, id, ownerName)
        return
    end

    -- Handle collar selection dialog
    if channel == dialogChannel then
        ll.ListenRemove(dialogListenHandle)
        dialogListenHandle = 0
        if dialogTimer then LLTimers:cancel(dialogTimer); dialogTimer = nil end

        if message == "Cancel" then
            ll.OwnerSay("Selection cancelled.")
            cleanupSession()
            return
        end

        local selectedAvatar = NULL_KEY
        for _, entry in ipairs(detectedCollars) do
            if entry.avatarName == message then
                selectedAvatar = entry.avatarKey
                break
            end
        end

        if selectedAvatar ~= NULL_KEY then
            requestAclFromCollar(selectedAvatar)
        else
            ll.OwnerSay("Error: Selection not found.")
            cleanupSession()
        end
        return
    end

    -- Handle ACL responses
    if channel == COLLAR_ACL_REPLY_CHAN and aclPending then
        local data = lljson.decode(message)
        if not data then return end
        if data.type ~= "acl_result_external" then return end

        if not data.avatar then return end
        local responseAvatar = tokey(data.avatar)

        if responseAvatar ~= hudWearer then return end

        if not data.collar_owner then return end
        local collarOwner = tokey(data.collar_owner)

        if collarOwner ~= targetAvatarKey then return end

        if queryTimer then LLTimers:cancel(queryTimer); queryTimer = nil end
        aclPending = false

        targetCollarKey = id

        if data.level then
            aclLevel = tonumber(data.level) or ACL_NOACCESS
        end

        processAclResult(aclLevel)

        if collarListenHandle ~= 0 then
            ll.ListenRemove(collarListenHandle)
            collarListenHandle = 0
        end
    end
end)

LLEvents:on("dataserver", function(queryId, data)
    if queryId == displayNameQueryId then
        displayNameQueryId = NULL_KEY
        displayNamePending = false
        if queryTimer then LLTimers:cancel(queryTimer); queryTimer = nil end

        if targetCollarKey == NULL_KEY then
            return
        end

        ll.OwnerSay("Connected to " .. data .. "'s collar.")

        local jsonMsg = lljson.encode({
            type = "menu_request_external",
            avatar = tostring(hudWearer),
            context = requestedContext
        })
        ll.RegionSayTo(targetCollarKey, COLLAR_MENU_CHAN, jsonMsg)

        cleanupSession()
    end
end)

-- Initialize
init()
