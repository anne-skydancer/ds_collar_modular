--[[--------------------
PLUGIN: plugin_relay.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Provide ORG-compliant RLV relay with hardcore mode and safeword hooks
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based relay tracking replaces stride lists.
  LLTimers replaces single-timer for ASK timeout.
  lljson.decode replaces llJsonGetValue chains.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "core_relay"
local PLUGIN_LABEL = "RLV Relay"

-- Relay constants
local RELAY_CHANNEL = -1812221819
local RLV_RESP_CHANNEL = 4711
local MAX_RELAYS = 5

local MODE_OFF = 0
local MODE_ON = 1
local MODE_ASK = 2

local ASK_TIMEOUT_SEC = 30
local SOS_MSG_NUM = 555

local WILDCARD_UUID = "ffffffff-ffff-ffff-ffff-ffffffffffff"

-- Settings keys
local KEY_RELAY_MODE = "relay.mode"
local KEY_RELAY_HARDCORE = "relay.hardcoremode"

-- State
local mode = MODE_ASK
local hardcore = false
local isAttached = false
local relayListenHandle = 0
local wearerKey = NULL_KEY

-- Relays: table keyed by obj_key -> { name=str, chan=int, restrictions=str }
local relays = {}
local relayCount = 0

-- ASK mode: session-trusted object keys
local sessionTrustedKeys = {}

-- ASK mode: pending prompt state
local pendingAskKey = NULL_KEY
local pendingAskName = ""
local pendingAskChan = 0
local pendingAskCommands = {}
local askListenHandle = 0
local askDialogChan = 0
local askTimeoutTimer = nil

-- Session management
local currentUser = NULL_KEY
local userAcl = -999
local policyButtons = {}
local sessionId = ""
local objectListPage = 0

-- Helpers

local function lsdInt(lsdKey, fallback)
    local v = ll.LinksetDataRead(lsdKey)
    if v == "" then return fallback end
    return tonumber(v) or fallback
end

local function generateSessionId()
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function truncateName(name, maxLen)
    if #name <= maxLen then return name end
    return string.sub(name, 1, maxLen - 3) .. "..."
end

-- LSD policy helper

local function getPolicyButtons(ctx, acl)
    local policy = ll.LinksetDataRead("policy:" .. ctx)
    if policy == "" then return {} end
    local data = lljson.decode(policy)
    if not data then return {} end
    local csv = data[tostring(acl)]
    if not csv then return {} end
    return string.split(csv, ",")
end

local function btnAllowed(label)
    for _, v in policyButtons do
        if v == label then return true end
    end
    return false
end

-- Lifecycle management

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["2"] = "Mode,Bound by...,Safeword",
        ["3"] = "Mode,Bound by...,Unbind,HC OFF,HC ON",
        ["4"] = "Mode,Bound by...,Safeword",
        ["5"] = "Mode,Bound by...,Unbind,HC OFF,HC ON"
    }))

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, lljson.encode({
        type = "register",
        context = PLUGIN_CONTEXT,
        label = PLUGIN_LABEL,
        script = ll.GetScriptName()
    }), NULL_KEY)
end

local function sendPong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, lljson.encode({
        type = "pong",
        context = PLUGIN_CONTEXT
    }), NULL_KEY)
end

-- Relay listen management

local function startRelayListen()
    if relayListenHandle ~= 0 then return end
    relayListenHandle = ll.Listen(RELAY_CHANNEL, "", NULL_KEY, "")
end

local function stopRelayListen()
    if relayListenHandle ~= 0 then
        ll.ListenRemove(relayListenHandle)
        relayListenHandle = 0
    end
end

local function updateRelayListenState()
    if mode ~= MODE_OFF and isAttached then
        startRelayListen()
    else
        stopRelayListen()
    end
end

-- Relay management

local function relayExists(objKey)
    return relays[tostring(objKey)] ~= nil
end

local function addRelay(objKey, objName, chan)
    local sk = tostring(objKey)
    if relays[sk] then
        relays[sk].name = objName
        relays[sk].chan = chan
        return true
    end

    if relayCount >= MAX_RELAYS then
        return false
    end

    relays[sk] = { name = objName, chan = chan, restrictions = "" }
    relayCount += 1
    return true
end

local function removeRelay(objKey)
    local sk = tostring(objKey)
    if relays[sk] then
        relays[sk] = nil
        relayCount -= 1
        return true
    end
    return false
end

local function storeRestriction(objKey, rlvCmd)
    local sk = tostring(objKey)
    local entry = relays[sk]
    if not entry then return false end

    if entry.restrictions == "" then
        entry.restrictions = rlvCmd
    else
        entry.restrictions = entry.restrictions .. "," .. rlvCmd
    end
    return true
end

local function clearRestrictions(objKey)
    local sk = tostring(objKey)
    local entry = relays[sk]
    if entry then
        ll.OwnerSay("@clear")
        entry.restrictions = ""
    end
end

-- Forward declarations
local clearPendingAsk

local function safewordClearAll()
    clearPendingAsk()
    sessionTrustedKeys = {}

    for sk, _ in relays do
        clearRestrictions(sk)
    end
    relays = {}
    relayCount = 0
end

-- ASK mode helpers

local function isRemovalCommand(cmd)
    if string.sub(cmd, -2) == "=y" then return true end
    if string.find(cmd, "^@clear") then return true end
    return false
end

local function showAskDialog()
    askDialogChan = -1000000 - math.floor(ll.Frand(1000000000.0))
    if askListenHandle ~= 0 then ll.ListenRemove(askListenHandle) end
    askListenHandle = ll.Listen(askDialogChan, "", wearerKey, "")

    local cmdCount = #pendingAskCommands
    local body = "[RELAY] " .. pendingAskName ..
                 "\nwants to apply " .. tostring(cmdCount) ..
                 " restriction(s).\n\nAllow or deny?"

    ll.Dialog(wearerKey, body, {"Deny", " ", "Allow"}, askDialogChan)

    if askTimeoutTimer then
        LLTimers:off(askTimeoutTimer)
    end
    askTimeoutTimer = LLTimers:once(ASK_TIMEOUT_SEC, function()
        askTimeoutTimer = nil
        if pendingAskKey ~= NULL_KEY then
            ll.RegionSayTo(wearerKey, 0, "[RELAY] Request timed out: " .. pendingAskName)
            -- decline_ask inline
            for _, cmd in pendingAskCommands do
                ll.RegionSayTo(pendingAskKey, pendingAskChan,
                    "RLV," .. tostring(ll.GetKey()) .. "," .. cmd .. ",ko")
            end
            ll.RegionSayTo(wearerKey, 0, "[RELAY] Denied: " .. pendingAskName)
            clearPendingAsk()
        end
    end)
end

local function acceptAsk()
    local sk = tostring(pendingAskKey)
    local found = false
    for _, v in sessionTrustedKeys do
        if v == sk then found = true end
    end
    if not found then
        sessionTrustedKeys[#sessionTrustedKeys + 1] = sk
    end

    addRelay(pendingAskKey, pendingAskName, pendingAskChan)

    for _, cmd in pendingAskCommands do
        storeRestriction(pendingAskKey, cmd)
        ll.OwnerSay(cmd)
        ll.RegionSayTo(pendingAskKey, pendingAskChan,
            "RLV," .. tostring(ll.GetKey()) .. "," .. cmd .. ",ok")
    end

    ll.RegionSayTo(wearerKey, 0, "[RELAY] Allowed: " .. pendingAskName)
    clearPendingAsk()
end

local function declineAsk()
    for _, cmd in pendingAskCommands do
        ll.RegionSayTo(pendingAskKey, pendingAskChan,
            "RLV," .. tostring(ll.GetKey()) .. "," .. cmd .. ",ko")
    end

    ll.RegionSayTo(wearerKey, 0, "[RELAY] Denied: " .. pendingAskName)
    clearPendingAsk()
end

clearPendingAsk = function()
    if askListenHandle ~= 0 then
        ll.ListenRemove(askListenHandle)
        askListenHandle = 0
    end
    if askTimeoutTimer then
        LLTimers:off(askTimeoutTimer)
        askTimeoutTimer = nil
    end
    pendingAskKey = NULL_KEY
    pendingAskName = ""
    pendingAskChan = 0
    pendingAskCommands = {}
    askDialogChan = 0
end

-- Settings consumption

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end

    local lsdMode = ll.LinksetDataRead(KEY_RELAY_MODE)
    local lsdHardcore = ll.LinksetDataRead(KEY_RELAY_HARDCORE)

    if lsdMode ~= "" then
        mode = tonumber(lsdMode) or MODE_ASK
        hardcore = (tonumber(lsdHardcore) or 0) ~= 0
    else
        mode = MODE_ASK
        hardcore = false
        local tmp = data.kv[KEY_RELAY_MODE]
        if tmp ~= nil then mode = tonumber(tmp) or MODE_ASK end
        tmp = data.kv[KEY_RELAY_HARDCORE]
        if tmp ~= nil then hardcore = (tonumber(tmp) or 0) ~= 0 end
        ll.LinksetDataWrite(KEY_RELAY_MODE, tostring(mode))
        ll.LinksetDataWrite(KEY_RELAY_HARDCORE, hardcore and "1" or "0")
    end

    updateRelayListenState()
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.op then return end

    if data.op == "set" then
        local changes = data.changes
        if not changes then return end

        local tmp = changes[KEY_RELAY_MODE]
        if tmp ~= nil then
            mode = tonumber(tmp) or mode
            ll.LinksetDataWrite(KEY_RELAY_MODE, tostring(tmp))
            updateRelayListenState()
        end

        tmp = changes[KEY_RELAY_HARDCORE]
        if tmp ~= nil then
            hardcore = (tonumber(tmp) or 0) ~= 0
            ll.LinksetDataWrite(KEY_RELAY_HARDCORE, tostring(tmp))
        end
    end
end

-- Settings modification

local function persistMode(newMode)
    ll.LinksetDataWrite(KEY_RELAY_MODE, tostring(newMode))
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = KEY_RELAY_MODE,
        value = tostring(newMode)
    }), NULL_KEY)
end

local function persistHardcore(newHardcore)
    ll.LinksetDataWrite(KEY_RELAY_HARDCORE, newHardcore and "1" or "0")
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = KEY_RELAY_HARDCORE,
        value = newHardcore and "1" or "0"
    }), NULL_KEY)
end

-- Session management

local function cleanupSession()
    if sessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
            type = "dialog_close",
            session_id = sessionId
        }), NULL_KEY)
    end
    currentUser = NULL_KEY
    userAcl = -999
    policyButtons = {}
    sessionId = ""
    objectListPage = 0
end

-- Navigation

local function returnToRoot()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "return",
        context = PLUGIN_CONTEXT,
        user = tostring(currentUser)
    }), currentUser)
    cleanupSession()
end

-- Forward declarations for menus
local showMainMenu, showModeMenu, showObjectList, handleButtonClick

-- UI / Menu system

showMainMenu = function()
    sessionId = generateSessionId()
    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, userAcl)

    local modeStr
    if not isAttached then
        modeStr = "OFF (not worn)"
    elseif mode == MODE_OFF then
        modeStr = "OFF"
    elseif mode == MODE_ASK then
        modeStr = "ASK"
    elseif hardcore then
        modeStr = "HARDCORE"
    else
        modeStr = "ON"
    end

    local message = "RLV Relay Menu\nMode: " .. modeStr .. "\nActive Relays: " .. tostring(relayCount)

    local buttons = {"Back"}

    if btnAllowed("Mode") then buttons[#buttons + 1] = "Mode" end
    if btnAllowed("Bound by...") then buttons[#buttons + 1] = "Bound by..." end
    if btnAllowed("Safeword") and not hardcore then
        buttons[#buttons + 1] = "Safeword"
    end
    if btnAllowed("Unbind") then buttons[#buttons + 1] = "Unbind" end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = PLUGIN_LABEL .. " Menu",
        message = message,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

showModeMenu = function()
    sessionId = generateSessionId()

    local modeStr
    if not isAttached then
        modeStr = "OFF (not worn)"
    elseif mode == MODE_OFF then
        modeStr = "OFF"
    elseif mode == MODE_ASK then
        modeStr = "ASK"
    elseif hardcore then
        modeStr = "HARDCORE"
    else
        modeStr = "ON"
    end

    local message = "RLV Relay Mode: " .. modeStr

    local buttons = {"Back", "OFF", "ASK", "ON"}

    if mode == MODE_ON then
        if hardcore then
            if btnAllowed("HC OFF") then buttons[#buttons + 1] = "HC OFF" end
        else
            if btnAllowed("HC ON") then buttons[#buttons + 1] = "HC ON" end
        end
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Relay Mode",
        message = message,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

showObjectList = function()
    sessionId = generateSessionId()

    local message
    if relayCount == 0 then
        message = "No active relays."
    else
        message = "Active Relays:\n"
        local idx = 1
        for sk, entry in relays do
            message = message .. tostring(idx) .. ". " .. truncateName(entry.name, 20) .. "\n"
            idx += 1
        end
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Active Relays",
        message = message,
        buttons = {"Back"},
        timeout = 60
    }), NULL_KEY)
end

-- Button handling

handleButtonClick = function(button)
    if button == "Mode" then
        showModeMenu()
    elseif button == "Bound by..." then
        showObjectList()
    elseif button == "Safeword" then
        if btnAllowed("Safeword") and not hardcore then
            safewordClearAll()
            ll.RegionSayTo(currentUser, 0, "[RELAY] Safeword used - all restrictions cleared")
            showMainMenu()
        end
    elseif button == "Unbind" then
        if btnAllowed("Unbind") then
            safewordClearAll()
            ll.RegionSayTo(currentUser, 0, "[RELAY] Unbound - all restrictions cleared")
            showMainMenu()
        end
    elseif button == "OFF" then
        clearPendingAsk()
        sessionTrustedKeys = {}
        mode = MODE_OFF
        hardcore = false
        persistMode(MODE_OFF)
        persistHardcore(false)
        updateRelayListenState()
        ll.RegionSayTo(currentUser, 0, "[RELAY] Mode set to OFF")
        showModeMenu()
    elseif button == "ASK" then
        clearPendingAsk()
        mode = MODE_ASK
        hardcore = false
        persistMode(MODE_ASK)
        persistHardcore(false)
        updateRelayListenState()
        ll.RegionSayTo(currentUser, 0, "[RELAY] Mode set to ASK")
        showModeMenu()
    elseif button == "ON" then
        clearPendingAsk()
        mode = MODE_ON
        persistMode(MODE_ON)
        updateRelayListenState()
        if not hardcore then
            ll.RegionSayTo(currentUser, 0, "[RELAY] Mode set to ON")
        end
        showModeMenu()
    elseif button == "HC ON" then
        if btnAllowed("HC ON") then
            hardcore = true
            mode = MODE_ON
            persistHardcore(true)
            persistMode(MODE_ON)
            ll.RegionSayTo(currentUser, 0, "[RELAY] Hardcore mode ENABLED")
            showModeMenu()
        end
    elseif button == "HC OFF" then
        if btnAllowed("HC OFF") then
            hardcore = false
            mode = MODE_ON
            persistHardcore(false)
            persistMode(MODE_ON)
            ll.RegionSayTo(currentUser, 0, "[RELAY] Hardcore mode DISABLED")
            showModeMenu()
        end
    elseif button == "Back" then
        returnToRoot()
    else
        showMainMenu()
    end
end

-- Ground rez handler

local function handleGroundRez()
    clearPendingAsk()
    sessionTrustedKeys = {}

    mode = MODE_OFF
    hardcore = false
    persistMode(MODE_OFF)
    persistHardcore(false)

    if relayCount > 0 then
        safewordClearAll()
    end

    updateRelayListenState()
    ll.OwnerSay("[RELAY] Collar rezzed on ground - Relay turned OFF")
end

-- Message handlers

local function handleStart(msg)
    local data = lljson.decode(msg)
    if not data or not data.context or not data.user then return end
    if data.context ~= PLUGIN_CONTEXT then return end

    currentUser = data.user
    userAcl = tonumber(data.acl) or 0
    showMainMenu()
end

local function handleDialogResponse(msg)
    local data = lljson.decode(msg)
    if not data or not data.session_id or not data.button then return end
    if data.session_id ~= sessionId then return end

    handleButtonClick(data.button)
end

local function handleDialogTimeout(msg)
    local data = lljson.decode(msg)
    if not data or not data.session_id then return end
    if data.session_id ~= sessionId then return end
    cleanupSession()
end

-- Relay protocol handler

local function handleRelayMessage(senderId, senderName, rawMsg)
    if not isAttached then return end

    local parsed = string.split(rawMsg, "|")
    local rawCmd = parsed[1] or ""
    local sessionChan = RLV_RESP_CHANNEL
    if #parsed > 1 then
        sessionChan = tonumber(parsed[2]) or RLV_RESP_CHANNEL
    end

    local parts = string.split(rawCmd, ",")
    local command = rawCmd

    if #parts >= 3 then
        local potentialUuid = parts[2]
        local uuidLen = #potentialUuid

        if uuidLen == 36 and
           string.sub(potentialUuid, 9, 9) == "-" and
           string.sub(potentialUuid, 14, 14) == "-" and
           string.sub(potentialUuid, 19, 19) == "-" and
           string.sub(potentialUuid, 24, 24) == "-" then

            local targetUuid = potentialUuid

            if targetUuid ~= tostring(wearerKey) and targetUuid ~= WILDCARD_UUID then
                return
            end

            command = parts[3]
        end
    end

    -- Handle version queries
    if command == "@version" or command == "@versionnew" then
        addRelay(senderId, senderName, sessionChan)
        ll.RegionSayTo(senderId, sessionChan,
            "RLV," .. tostring(ll.GetKey()) .. "," .. command .. ",ok")
        return
    end

    -- Handle release commands
    if command == "!release" or command == "!release_fail" then
        clearRestrictions(senderId)
        removeRelay(senderId)
        ll.RegionSayTo(senderId, sessionChan,
            "RLV," .. tostring(ll.GetKey()) .. "," .. command .. ",ok")
        return
    end

    -- Handle RLV commands
    if string.sub(command, 1, 1) == "@" then
        if mode == MODE_OFF then
            ll.RegionSayTo(senderId, sessionChan,
                "RLV," .. tostring(ll.GetKey()) .. "," .. command .. ",ko")
            return
        end

        if mode == MODE_ASK and not isRemovalCommand(command) then
            local sk = tostring(senderId)
            local alreadyTrusted = false
            for _, v in sessionTrustedKeys do
                if v == sk then alreadyTrusted = true end
            end

            if not alreadyTrusted then
                if pendingAskKey == NULL_KEY then
                    pendingAskKey = senderId
                    pendingAskName = senderName
                    pendingAskChan = sessionChan
                    pendingAskCommands = {command}
                    showAskDialog()
                elseif tostring(pendingAskKey) == sk then
                    pendingAskCommands[#pendingAskCommands + 1] = command
                else
                    ll.RegionSayTo(senderId, sessionChan,
                        "RLV," .. tostring(ll.GetKey()) .. "," .. command .. ",ko")
                end
                return
            end
        end

        addRelay(senderId, senderName, sessionChan)
        storeRestriction(senderId, command)
        ll.OwnerSay(command)

        ll.RegionSayTo(senderId, sessionChan,
            "RLV," .. tostring(ll.GetKey()) .. "," .. command .. ",ok")
        return
    end
end

-- Events

LLEvents:on("on_rez", function(startParam)
    ll.ResetScript()
end)

LLEvents:on("attach", function(avatarId)
    if not avatarId.istruthy then
        clearPendingAsk()
        sessionTrustedKeys = {}
        isAttached = false
        handleGroundRez()
    else
        isAttached = true
        wearerKey = avatarId
        updateRelayListenState()
        ll.OwnerSay("[RELAY] Collar attached - Relay state restored")
    end
end)

LLEvents:on("listen", function(chan, name, id, msg)
    if chan == RELAY_CHANNEL then
        handleRelayMessage(id, name, msg)
    elseif chan == askDialogChan and tostring(id) == tostring(wearerKey) then
        if msg == "Allow" then
            acceptAsk()
        elseif msg == "Deny" then
            declineAsk()
        end
    end
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    local data = lljson.decode(msg)
    if not data or not data.type then return end
    local msgType = data.type

    if num == KERNEL_LIFECYCLE then
        if msgType == "register_now" then
            registerSelf()
        elseif msgType == "ping" then
            sendPong()
        elseif msgType == "soft_reset" or msgType == "soft_reset_all" then
            ll.ResetScript()
        end
    elseif num == SETTINGS_BUS then
        if msgType == "settings_sync" then
            applySettingsSync(msg)
        elseif msgType == "settings_delta" then
            applySettingsDelta(msg)
        end
    elseif num == UI_BUS then
        if msgType == "start" then
            handleStart(msg)
        end
    elseif num == DIALOG_BUS then
        if msgType == "dialog_response" then
            handleDialogResponse(msg)
        elseif msgType == "dialog_timeout" then
            handleDialogTimeout(msg)
        end
    elseif num == SOS_MSG_NUM then
        if msgType == "sos_release" then
            safewordClearAll()
            ll.OwnerSay("[SOS] All RLV restrictions cleared.")
        end
    end
end)

-- Init

local function init()
    cleanupSession()
    clearPendingAsk()
    sessionTrustedKeys = {}

    isAttached = (ll.GetAttached() ~= 0)
    wearerKey = ll.GetOwner()

    if not isAttached then
        handleGroundRez()
    else
        mode = lsdInt(KEY_RELAY_MODE, MODE_ASK)
        hardcore = lsdInt(KEY_RELAY_HARDCORE, 0) ~= 0
        updateRelayListenState()
    end

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "settings_get"
    }), NULL_KEY)
end

init()
