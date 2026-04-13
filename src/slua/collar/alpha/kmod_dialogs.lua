--[[--------------------
MODULE: kmod_dialogs.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Centralized dialog management for shared listener handling
ARCHITECTURE: Consolidated message bus lanes (SLua port)
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-keyed sessions replace parallel lists.
  LLTimers replaces single-timer multiplexing.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local DIALOG_BUS = 950

-- Constants
local CHANNEL_BASE = -8E07
local SESSION_MAX = 10

-- Sessions: table keyed by sessionId
-- Each entry: { user=key, channel=int, listenHandle=int, timeoutUnix=int, buttonMap=table }
local Sessions = {}

-- Reverse lookup: channel -> sessionId (for listen event)
local ChannelToSession = {}

local nextChannelOffset = 1

-- Button configs: table keyed by context
-- Each entry: { labelA=str, labelB=str }
local ButtonConfigs = {}

-- Timer handle for session cleanup
local PruneTimer = nil

-- Helpers

local function now()
    return ll.GetUnixTime()
end

local function getMsgType(jsonStr)
    local data = lljson.decode(jsonStr)
    if data and data.type then return data.type end
    return ""
end

local function validateRequiredFields(data, fieldNames)
    for _, field in fieldNames do
        if data[field] == nil then
            return false
        end
    end
    return true
end

-- Session management

local function closeSession(sessionId)
    local session = Sessions[sessionId]
    if not session then return end

    if session.listenHandle ~= 0 then
        ll.ListenRemove(session.listenHandle)
    end

    ChannelToSession[session.channel] = nil
    Sessions[sessionId] = nil
end

local function pruneExpiredSessions()
    local nowTime = now()

    for sessionId, session in Sessions do
        if session.timeoutUnix > 0 and nowTime >= session.timeoutUnix then
            local timeoutMsg = lljson.encode({
                type = "dialog_timeout",
                session_id = sessionId,
                user = tostring(session.user)
            })
            ll.MessageLinked(LINK_SET, DIALOG_BUS, timeoutMsg, NULL_KEY)
            closeSession(sessionId)
        end
    end
end

local function getNextChannel()
    local channel = math.floor(CHANNEL_BASE) - nextChannelOffset
    nextChannelOffset = nextChannelOffset + 1
    if nextChannelOffset > 1000000 then nextChannelOffset = 1 end
    return channel
end

-- Button config management

local function registerButtonConfig(context, buttonA, buttonB)
    ButtonConfigs[context] = { labelA = buttonA, labelB = buttonB }
end

local function getButtonLabel(context, buttonState)
    local config = ButtonConfigs[context]
    if not config then
        return context
    end

    if buttonState == 0 then
        return config.labelA
    else
        return config.labelB
    end
end

-- Enforce session limit by closing the oldest session
local function enforceSessionLimit()
    -- Count sessions
    local count = 0
    local oldestId = nil
    local oldestTimeout = math.huge

    for sessionId, session in Sessions do
        count = count + 1
        if session.timeoutUnix < oldestTimeout then
            oldestTimeout = session.timeoutUnix
            oldestId = sessionId
        end
    end

    if count >= SESSION_MAX and oldestId then
        closeSession(oldestId)
    end
end

-- Create a session and show the dialog
local function createSession(sessionId, user, buttons, buttonMap, title, body, timeout)
    -- Close existing session with same ID
    closeSession(sessionId)

    -- Enforce session limit
    enforceSessionLimit()

    -- Get channel and create listen
    local channel = getNextChannel()
    local listenHandle = ll.Listen(channel, "", user, "")

    -- Calculate timeout timestamp
    local timeoutUnix = 0
    if timeout > 0 then
        timeoutUnix = now() + timeout
    end

    -- Store session
    Sessions[sessionId] = {
        user = user,
        channel = channel,
        listenHandle = listenHandle,
        timeoutUnix = timeoutUnix,
        buttonMap = buttonMap
    }
    ChannelToSession[channel] = sessionId

    -- Show dialog
    ll.Dialog(user, title .. "\n\n" .. body, buttons, channel)
end

-- Dialog display

local function handleDialogOpen(msg, data)
    if not data.session_id or not data.user then return end

    local sessionId = data.session_id
    local user = key(data.user)

    -- Check for numbered list type
    if data.dialog_type and data.dialog_type == "numbered_list" then
        -- Handle numbered list dialog inline
        if not data.items then return end

        local title = data.title or "Select Item"
        local prompt = data.prompt or "Choose:"
        local timeout = data.timeout or 60
        if type(timeout) == "string" then timeout = tonumber(timeout) end

        local items = data.items
        local itemCount = #items
        if itemCount == 0 then return end

        local body = prompt .. "\n\n"
        local buttons = { "Back" }
        local buttonMap = { { b = "Back", c = "" } }

        local maxItems = 11
        if itemCount > maxItems then
            ll.OwnerSay("WARNING: Item list truncated to " .. tostring(maxItems) .. " items (had " .. tostring(itemCount) .. ")")
            itemCount = maxItems
        end

        for i = 1, itemCount do
            local item = items[i]
            body = body .. tostring(i) .. ". " .. item .. "\n"
            buttons[#buttons + 1] = tostring(i)
            buttonMap[#buttonMap + 1] = { b = tostring(i), c = "" }
        end

        createSession(sessionId, user, buttons, buttonMap, title, body, timeout)
        return
    end

    -- Standard dialog - check for button_data (new format) or buttons (old format)
    local buttons = {}
    local buttonMap = {}

    if data.button_data then
        local buttonDataList = data.button_data

        for _, item in buttonDataList do
            local buttonText = ""
            local buttonContext = ""

            if type(item) == "table" and item.context and item.label and item.state then
                -- Plugin buttons: objects with context+label+state
                local context = item.context
                local label = item.label
                local buttonState = tonumber(item.state) or 0

                -- Check if there's a button config for this context (toggle buttons)
                local config = ButtonConfigs[context]
                if config then
                    buttonText = getButtonLabel(context, buttonState)
                else
                    buttonText = label
                end

                buttonContext = context
            else
                -- Navigation buttons or other non-routable buttons
                if type(item) == "table" and item.label then
                    buttonText = item.label
                else
                    buttonText = tostring(item)
                end
                -- buttonContext remains empty
            end

            buttons[#buttons + 1] = buttonText
            buttonMap[#buttonMap + 1] = { b = buttonText, c = buttonContext }
        end
    elseif data.buttons then
        local buttonsList = data.buttons

        for _, btn in buttonsList do
            buttons[#buttons + 1] = btn
            buttonMap[#buttonMap + 1] = { b = btn, c = "" }
        end
    else
        return
    end

    local title = data.title or "Menu"
    local body = data.body or data.message or "Select an option:"
    local timeout = data.timeout or 60
    if type(timeout) == "string" then timeout = tonumber(timeout) end

    createSession(sessionId, user, buttons, buttonMap, title, body, timeout)
end

local function handleDialogClose(data)
    if not data.session_id then return end
    closeSession(data.session_id)
end

-- Startup

local function init()
    Sessions = {}
    ChannelToSession = {}
    nextChannelOffset = 1
    ButtonConfigs = {}

    -- Start timer for session cleanup
    PruneTimer = LLTimers:every(5.0, pruneExpiredSessions)
end

-- Events

LLEvents:on("listen", function(channel, name, id, message)
    local sessionId = ChannelToSession[channel]
    if not sessionId then return end

    local session = Sessions[sessionId]
    if not session then return end

    -- Verify speaker matches session user
    if id ~= session.user then return end

    -- Look up context for this button
    local clickedContext = ""
    for _, entry in session.buttonMap do
        if entry.b == message then
            clickedContext = entry.c
            break
        end
    end

    -- Send response message with context
    local response = lljson.encode({
        type = "dialog_response",
        session_id = sessionId,
        user = tostring(id),
        button = message,
        context = clickedContext
    })
    ll.MessageLinked(LINK_SET, DIALOG_BUS, response, NULL_KEY)

    -- Close session after response
    closeSession(sessionId)
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    local msgType = getMsgType(msg)
    if msgType == "" then return end

    -- Kernel lifecycle
    if num == KERNEL_LIFECYCLE then
        if msgType == "soft_reset" or msgType == "soft_reset_all" then
            ll.ResetScript()
        end
        return
    end

    -- Dialog bus
    if num ~= DIALOG_BUS then return end

    local data = lljson.decode(msg)
    if not data then return end

    if msgType == "dialog_open" then
        handleDialogOpen(msg, data)
    elseif msgType == "dialog_close" then
        handleDialogClose(data)
    elseif msgType == "register_button_config" then
        if data.context and data.button_a and data.button_b then
            registerButtonConfig(data.context, data.button_a, data.button_b)
        end
    end
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

init()
