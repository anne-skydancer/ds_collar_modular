--[[--------------------
PLUGIN: plugin_tpe.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Manage TPE mode with wearer confirmation and owner oversight
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.10 rev 0: SLua alpha port from LSL 1.10
  Table-based policy replaces stride lists.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "core_tpe"
local PLUGIN_LABEL_ON = "TPE: Y"
local PLUGIN_LABEL_OFF = "TPE: N"

-- Settings keys
local KEY_TPE_MODE = "tpe.mode"

-- State
local tpeModeEnabled = false

-- Session management
local currentUser = NULL_KEY
local userAcl = -999
local policyButtons = {}
local sessionId = ""
local wearerKey = NULL_KEY

-- Helpers

local function lsdInt(lsdKey, fallback)
    local v = ll.LinksetDataRead(lsdKey)
    if v == "" then return fallback end
    return tonumber(v) or fallback
end

local function genSession()
    return tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime())
end

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
end

local function closeUiForUser(user)
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "close",
        context = PLUGIN_CONTEXT,
        user = tostring(user)
    }), user)
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

-- Kernel messages

local function registerWithKernel()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["5"] = "toggle"
    }))

    local initialLabel = PLUGIN_LABEL_OFF
    if tpeModeEnabled then
        initialLabel = PLUGIN_LABEL_ON
    end

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, lljson.encode({
        type = "register",
        context = PLUGIN_CONTEXT,
        label = initialLabel,
        script = ll.GetScriptName()
    }), NULL_KEY)
end

local function sendPong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, lljson.encode({
        type = "pong",
        context = PLUGIN_CONTEXT
    }), NULL_KEY)
end

-- Settings management

local function requestSettingsSync()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "settings_get"
    }), NULL_KEY)
end

local function persistTpeMode(newValue)
    if newValue ~= 0 then newValue = 1 end

    ll.LinksetDataWrite(KEY_TPE_MODE, tostring(newValue))

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = KEY_TPE_MODE,
        value = tostring(newValue)
    }), NULL_KEY)
end

-- UI label update

local function updateUiLabel()
    local newLabel = PLUGIN_LABEL_OFF
    if tpeModeEnabled then
        newLabel = PLUGIN_LABEL_ON
    end

    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "update_label",
        context = PLUGIN_CONTEXT,
        label = newLabel
    }), NULL_KEY)
end

-- Button handling

local function handleButtonClick(button)
    if button == "Yes" then
        tpeModeEnabled = true
        persistTpeMode(1)

        ll.RegionSayTo(wearerKey, 0, "TPE mode enabled. You have relinquished collar control.")
        if currentUser ~= wearerKey then
            ll.RegionSayTo(currentUser, 0, "TPE mode enabled with wearer consent.")
        end

        updateUiLabel()

        closeUiForUser(wearerKey)

        if currentUser ~= wearerKey then
            ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
                type = "return",
                user = tostring(currentUser)
            }), NULL_KEY)
        end

        cleanupSession()

    elseif button == "No" then
        ll.RegionSayTo(wearerKey, 0, "TPE activation cancelled.")
        if currentUser ~= wearerKey then
            ll.RegionSayTo(currentUser, 0, "Wearer declined TPE activation.")
        end

        closeUiForUser(wearerKey)

        if currentUser ~= wearerKey then
            ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
                type = "return",
                user = tostring(currentUser)
            }), NULL_KEY)
        end

        cleanupSession()
    end
end

-- TPE toggle logic

local function handleTpeClick(user, aclLevel)
    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, aclLevel)
    if not btnAllowed("toggle") then
        ll.RegionSayTo(user, 0, "Access denied. Only primary owner can manage TPE mode.")
        cleanupSession()
        return
    end

    currentUser = user
    userAcl = aclLevel
    wearerKey = ll.GetOwner()

    if tpeModeEnabled then
        -- TPE is ON - disable directly (no confirmation needed)
        tpeModeEnabled = false
        persistTpeMode(0)

        ll.RegionSayTo(user, 0, "TPE mode disabled. Wearer regains collar access.")
        if user ~= wearerKey then
            ll.RegionSayTo(wearerKey, 0, "Your collar access has been restored.")
        end

        updateUiLabel()

        ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
            type = "return",
            user = tostring(user)
        }), NULL_KEY)

        cleanupSession()
    else
        -- TPE is OFF - requires wearer consent
        local msgBody = "Your owner wants to enable TPE mode.\n\n"
            .. "By clicking Yes, you relinquish all control of this collar.\n\n"
            .. "You will not be able to access the collar menu while TPE is active.\n\n"
            .. "Do you consent?"

        sessionId = genSession()

        ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
            type = "dialog_open",
            session_id = sessionId,
            user = tostring(ll.GetOwner()),
            title = "TPE Confirmation",
            body = msgBody,
            buttons = {"Yes", "No"},
            timeout = 60
        }), NULL_KEY)
    end
end

-- Settings consumption

local function applySettingsSync(kvJson)
    local lsdVal = ll.LinksetDataRead(KEY_TPE_MODE)
    if lsdVal ~= "" then
        tpeModeEnabled = tonumber(lsdVal) ~= 0
    else
        local kv = kvJson
        if type(kv) == "string" then
            kv = lljson.decode(kv)
        end
        if kv and kv[KEY_TPE_MODE] ~= nil then
            tpeModeEnabled = tonumber(kv[KEY_TPE_MODE]) ~= 0
        end
        ll.LinksetDataWrite(KEY_TPE_MODE, tostring(tpeModeEnabled and 1 or 0))
    end
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.op then return end

    if data.op == "set" then
        local changes = data.changes
        if not changes then return end
        if type(changes) == "string" then
            changes = lljson.decode(changes)
            if not changes then return end
        end

        if changes[KEY_TPE_MODE] ~= nil then
            tpeModeEnabled = tonumber(changes[KEY_TPE_MODE]) ~= 0
            ll.LinksetDataWrite(KEY_TPE_MODE, tostring(changes[KEY_TPE_MODE]))
        end
    end
end

-- Event handlers

LLEvents:on("link_message", function(senderNum, num, str, id)
    if num == KERNEL_LIFECYCLE then
        local data = lljson.decode(str)
        if not data or not data.type then return end

        if data.type == "register_now" then
            registerWithKernel()
        elseif data.type == "ping" then
            sendPong()
        elseif data.type == "soft_reset" or data.type == "soft_reset_all" then
            local targetContext = data.context
            if targetContext then
                if targetContext ~= "" and targetContext ~= PLUGIN_CONTEXT then
                    return
                end
            end
            ll.ResetScript()
        end

    elseif num == SETTINGS_BUS then
        local data = lljson.decode(str)
        if not data or not data.type then return end

        if data.type == "settings_sync" then
            local kvJson = data.kv
            if kvJson then
                applySettingsSync(kvJson)
            end
        elseif data.type == "settings_delta" then
            applySettingsDelta(str)
        end

    elseif num == UI_BUS then
        local data = lljson.decode(str)
        if not data or not data.type then return end

        if data.type == "start" then
            local context = data.context
            if context ~= PLUGIN_CONTEXT then return end

            currentUser = id
            userAcl = tonumber(data.acl) or -999

            handleTpeClick(currentUser, userAcl)
        end

    elseif num == DIALOG_BUS then
        local data = lljson.decode(str)
        if not data or not data.type then return end

        if data.type == "dialog_response" then
            local respSessionId = data.session_id
            if respSessionId ~= sessionId then return end

            handleButtonClick(data.button)

        elseif data.type == "dialog_timeout" then
            local respSessionId = data.session_id
            if respSessionId ~= sessionId then return end

            ll.RegionSayTo(wearerKey, 0, "TPE confirmation timed out.")
            if currentUser ~= wearerKey then
                ll.RegionSayTo(currentUser, 0, "TPE confirmation timed out.")
            end

            closeUiForUser(wearerKey)

            if currentUser ~= wearerKey then
                ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
                    type = "return",
                    user = tostring(currentUser)
                }), NULL_KEY)
            end

            cleanupSession()
        end
    end
end)

LLEvents:on("on_rez", function(startParam)
    ll.ResetScript()
end)

LLEvents:on("changed", function(changeMask)
    if bit32.btest(changeMask, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

-- Init
tpeModeEnabled = lsdInt(KEY_TPE_MODE, 0) ~= 0
wearerKey = ll.GetOwner()
cleanupSession()
registerWithKernel()
requestSettingsSync()
