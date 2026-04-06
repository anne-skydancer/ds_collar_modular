--[[--------------------
PLUGIN: plugin_bell.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Bell visibility and jingling control for the collar
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.1 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based policy lookup replaces stride lists.
  LLEvents/LLTimers replaces state/event blocks.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "bell"
local PLUGIN_LABEL = "Bell"

-- Settings keys
local KEY_BELL_VISIBLE = "bell.visible"
local KEY_BELL_SOUND_ENABLED = "bell.enablesound"
local KEY_BELL_VOLUME = "bell.volume"
local KEY_BELL_SOUND = "bell.sound"

-- State
local bellVisible = false
local bellSoundEnabled = false
local bellVolume = 0.3
local bellSound = "16fcf579-82cb-b110-c1a4-5fa5e1385406"
local isMoving = false
local bellLink = 0

-- Jingle timing
local JINGLE_INTERVAL = 1.75
local jingleTimer = nil

-- Session state
local currentUser = NULL_KEY
local userAcl = -999
local policyButtons = {}
local sessionId = ""
local menuContext = ""

-- Helpers

local function generateSessionId()
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

-- LSD persistence helpers

local function lsdInt(lsdKey, fallback)
    local v = ll.LinksetDataRead(lsdKey)
    if v == "" then return fallback end
    return tonumber(v) or fallback
end

local function lsdFloat(lsdKey, fallback)
    local v = ll.LinksetDataRead(lsdKey)
    if v == "" then return fallback end
    return tonumber(v) or fallback
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

-- Bell visibility

local function setBellVisibility(visible)
    if bellLink == 0 then
        local linkCount = ll.GetNumberOfPrims()
        for i = 1, linkCount do
            if ll.ToLower(ll.GetLinkName(i)) == "bell" then
                bellLink = i
                break
            end
        end
    end

    if bellLink ~= 0 then
        local alpha = 0.0
        if visible then alpha = 1.0 end
        ll.SetLinkAlpha(bellLink, alpha, ALL_SIDES)
    end

    bellVisible = visible
end

-- Sound

local function playJingle()
    if bellSound == "" or bellSound == "00000000-0000-0000-0000-000000000000" then
        return
    end

    if not bellSoundEnabled then
        return
    end

    ll.TriggerSound(bellSound, bellVolume)
end

-- Unified menu display

local function showMenu(ctx, title, body, buttons)
    sessionId = generateSessionId()
    menuContext = ctx

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = title,
        body = body,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

-- Session cleanup

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
    menuContext = ""
end

-- Navigation

local function returnToRoot()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "return",
        user = tostring(currentUser)
    }), NULL_KEY)
    cleanupSession()
end

-- Plugin registration

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["1"] = "Show,Sound,Volume +,Volume -",
        ["2"] = "Show,Sound,Volume +,Volume -",
        ["3"] = "Show,Sound,Volume +,Volume -",
        ["4"] = "Show,Sound,Volume +,Volume -",
        ["5"] = "Show,Sound,Volume +,Volume -"
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

-- Settings modification

local function persistBellSetting(settingKey, value)
    ll.LinksetDataWrite(settingKey, value)

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = settingKey,
        value = value
    }), NULL_KEY)
end

-- Menu system (forward-declared for mutual reference)
local showMainMenu

showMainMenu = function()
    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, userAcl)

    local visibleLabel
    if bellVisible then
        visibleLabel = "Show: Y"
    else
        visibleLabel = "Show: N"
    end

    local soundLabel
    if bellSoundEnabled then
        soundLabel = "Sound: On"
    else
        soundLabel = "Sound: Off"
    end

    local buttons = { "Back" }
    if btnAllowed("Show") then buttons[#buttons + 1] = visibleLabel end
    if btnAllowed("Sound") then buttons[#buttons + 1] = soundLabel end
    if btnAllowed("Volume +") then buttons[#buttons + 1] = "Volume +" end
    if btnAllowed("Volume -") then buttons[#buttons + 1] = "Volume -" end

    local body = "Bell Control\n\n"
    body = body .. "Visibility: " .. tostring(bellVisible and 1 or 0) .. "\n"
    body = body .. "Sound: " .. tostring(bellSoundEnabled and 1 or 0) .. "\n"
    body = body .. "Volume: " .. tostring(math.floor(bellVolume * 100)) .. "%"

    showMenu("main", "Bell", body, buttons)
end

-- Button handler

local function handleButtonClick(button)
    if menuContext == "main" then
        if button == "Back" then
            returnToRoot()
        elseif button == "Volume +" then
            bellVolume = bellVolume + 0.1
            if bellVolume > 1.0 then bellVolume = 1.0 end
            persistBellSetting(KEY_BELL_VOLUME, tostring(bellVolume))
            ll.RegionSayTo(currentUser, 0, "Volume: " .. tostring(math.floor(bellVolume * 100)) .. "%")
            showMainMenu()
        elseif button == "Volume -" then
            bellVolume = bellVolume - 0.1
            if bellVolume < 0.0 then bellVolume = 0.0 end
            persistBellSetting(KEY_BELL_VOLUME, tostring(bellVolume))
            ll.RegionSayTo(currentUser, 0, "Volume: " .. tostring(math.floor(bellVolume * 100)) .. "%")
            showMainMenu()
        elseif button == "Show: Y" or button == "Show: N" then
            bellVisible = not bellVisible
            setBellVisibility(bellVisible)
            persistBellSetting(KEY_BELL_VISIBLE, bellVisible and "1" or "0")

            if bellVisible then
                ll.RegionSayTo(currentUser, 0, "Bell shown.")
            else
                ll.RegionSayTo(currentUser, 0, "Bell hidden.")
            end

            showMainMenu()
        elseif button == "Sound: On" or button == "Sound: Off" then
            bellSoundEnabled = not bellSoundEnabled
            persistBellSetting(KEY_BELL_SOUND_ENABLED, bellSoundEnabled and "1" or "0")

            if bellSoundEnabled then
                ll.RegionSayTo(currentUser, 0, "Bell sound enabled.")
            else
                ll.RegionSayTo(currentUser, 0, "Bell sound disabled.")
            end

            showMainMenu()
        end
    end
end

-- Settings handling

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end
    local kvData = data.kv

    if ll.LinksetDataRead(KEY_BELL_VISIBLE) == "" then
        if kvData[KEY_BELL_VISIBLE] ~= nil then
            local newVisible = (tonumber(kvData[KEY_BELL_VISIBLE]) or 0) ~= 0
            setBellVisibility(newVisible)
            ll.LinksetDataWrite(KEY_BELL_VISIBLE, tostring(kvData[KEY_BELL_VISIBLE]))
        end
    end

    if ll.LinksetDataRead(KEY_BELL_SOUND_ENABLED) == "" then
        if kvData[KEY_BELL_SOUND_ENABLED] ~= nil then
            bellSoundEnabled = (tonumber(kvData[KEY_BELL_SOUND_ENABLED]) or 0) ~= 0
            ll.LinksetDataWrite(KEY_BELL_SOUND_ENABLED, tostring(kvData[KEY_BELL_SOUND_ENABLED]))
        end
    end

    if ll.LinksetDataRead(KEY_BELL_VOLUME) == "" then
        if kvData[KEY_BELL_VOLUME] ~= nil then
            bellVolume = tonumber(kvData[KEY_BELL_VOLUME]) or 0.3
            ll.LinksetDataWrite(KEY_BELL_VOLUME, tostring(kvData[KEY_BELL_VOLUME]))
        end
    end

    if kvData[KEY_BELL_SOUND] ~= nil then
        bellSound = kvData[KEY_BELL_SOUND]
    end
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.changes then return end
    local changes = data.changes

    if changes[KEY_BELL_VISIBLE] ~= nil then
        setBellVisibility((tonumber(changes[KEY_BELL_VISIBLE]) or 0) ~= 0)
        ll.LinksetDataWrite(KEY_BELL_VISIBLE, tostring(changes[KEY_BELL_VISIBLE]))
    end

    if changes[KEY_BELL_SOUND_ENABLED] ~= nil then
        bellSoundEnabled = (tonumber(changes[KEY_BELL_SOUND_ENABLED]) or 0) ~= 0
        ll.LinksetDataWrite(KEY_BELL_SOUND_ENABLED, tostring(changes[KEY_BELL_SOUND_ENABLED]))
    end

    if changes[KEY_BELL_VOLUME] ~= nil then
        bellVolume = tonumber(changes[KEY_BELL_VOLUME]) or 0.3
        ll.LinksetDataWrite(KEY_BELL_VOLUME, tostring(changes[KEY_BELL_VOLUME]))
    end

    if changes[KEY_BELL_SOUND] ~= nil then
        bellSound = changes[KEY_BELL_SOUND]
    end
end

-- Events

LLEvents:on("on_rez", function(startParam)
    -- Preserve state through attach/detach; settings sync restores saved state
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        ll.ResetScript()
    end
    if bit32.btest(change, CHANGED_LINK) then
        bellLink = 0
    end
end)

LLEvents:on("moving_start", function()
    if not isMoving then
        isMoving = true

        if bellVisible and bellSoundEnabled then
            playJingle()
        end

        jingleTimer = LLTimers:every(JINGLE_INTERVAL, function()
            if isMoving and bellVisible and bellSoundEnabled then
                playJingle()
            end
        end)
    end
end)

LLEvents:on("moving_end", function()
    if isMoving then
        isMoving = false

        if jingleTimer then
            LLTimers:off(jingleTimer)
            jingleTimer = nil
        end
    end
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    if num == KERNEL_LIFECYCLE then
        local data = lljson.decode(msg)
        if not data or not data.type then return end

        if data.type == "register_now" then
            registerSelf()
            return
        end

        if data.type == "ping" then
            sendPong()
            return
        end

        return
    end

    if num == SETTINGS_BUS then
        local data = lljson.decode(msg)
        if not data or not data.type then return end

        if data.type == "settings_sync" then
            applySettingsSync(msg)
            return
        end

        if data.type == "settings_delta" then
            applySettingsDelta(msg)
            return
        end

        return
    end

    if num == UI_BUS then
        local data = lljson.decode(msg)
        if not data or not data.type then return end

        if data.type == "start" then
            if not data.context then return end
            if data.context ~= PLUGIN_CONTEXT then return end

            currentUser = id
            userAcl = tonumber(data.acl) or -999
            showMainMenu()
            return
        end

        return
    end

    if num == DIALOG_BUS then
        local data = lljson.decode(msg)
        if not data or not data.type then return end

        if data.type == "dialog_response" then
            if not data.session_id or not data.button then return end
            if data.session_id ~= sessionId then return end

            handleButtonClick(data.button)
            return
        end

        if data.type == "dialog_timeout" then
            if not data.session_id then return end
            if data.session_id ~= sessionId then return end
            cleanupSession()
            return
        end

        return
    end
end)

-- Init (replaces state_entry)
cleanupSession()

bellVisible = lsdInt(KEY_BELL_VISIBLE, 0) ~= 0
bellSoundEnabled = lsdInt(KEY_BELL_SOUND_ENABLED, 0) ~= 0
bellVolume = lsdFloat(KEY_BELL_VOLUME, 0.3)
setBellVisibility(bellVisible)

registerSelf()

ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
    type = "settings_get"
}), NULL_KEY)
