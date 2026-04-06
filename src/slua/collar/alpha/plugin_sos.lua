--[[--------------------
PLUGIN: plugin_sos.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Emergency wearer-accessible actions when ACL is locked out
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.10 rev 0: SLua alpha port from LSL 1.10
  Table-based policy replaces stride lists.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "sos_911"
local PLUGIN_LABEL = "SOS"

-- State
local currentUser = NULL_KEY
local userAcl = -999
local policyButtons = {}
local sessionId = ""

-- Helpers

local function generateSessionId()
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
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
end

-- Plugin registration

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["0"] = "Unleash,Clear RLV,Clear Relay"
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

-- Navigation

local function returnToRoot()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "return",
        user = tostring(currentUser)
    }), NULL_KEY)

    cleanupSession()
end

-- Emergency actions

local function actionUnleash()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "emergency_leash_release"
    }), currentUser)

    ll.RegionSayTo(currentUser, 0, "[SOS] Leash released.")
end

local function actionClearRlv()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "emergency_restrict_clear"
    }), currentUser)

    ll.OwnerSay("@clear")

    ll.RegionSayTo(currentUser, 0, "[SOS] All RLV restrictions cleared.")
end

local function actionClearRelay()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "emergency_relay_clear"
    }), currentUser)

    ll.RegionSayTo(currentUser, 0, "[SOS] All relay restrictions cleared.")
end

-- Menu display

local function showSosMenu()
    sessionId = generateSessionId()

    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, userAcl)

    local buttons = {"Back"}
    if btnAllowed("Unleash") then table.insert(buttons, "Unleash") end
    if btnAllowed("Clear RLV") then table.insert(buttons, "Clear RLV") end
    if btnAllowed("Clear Relay") then table.insert(buttons, "Clear Relay") end

    local body = "EMERGENCY ACCESS\n\n"
        .. "Choose an action:\n"
        .. "- Unleash - Release leash\n"
        .. "- Clear RLV - Clear RLV restrictions\n"
        .. "- Clear Relay - Clear relay restrictions"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "SOS Emergency",
        body = body,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

-- Button handler

local function handleButtonClick(button)
    if button == "Back" then
        returnToRoot()
        return
    end

    if button == "Unleash" then
        actionUnleash()
        showSosMenu()
        return
    end

    if button == "Clear RLV" then
        actionClearRlv()
        showSosMenu()
        return
    end

    if button == "Clear Relay" then
        actionClearRelay()
        showSosMenu()
        return
    end
end

-- Event handlers

LLEvents:on("link_message", function(sender, num, msg, id)
    local data = lljson.decode(msg)
    if not data or not data.type then return end
    local msgType = data.type

    -- Kernel lifecycle
    if num == KERNEL_LIFECYCLE then
        if msgType == "register_now" then
            registerSelf()
            return
        end

        if msgType == "ping" then
            sendPong()
            return
        end

        if msgType == "soft_reset" or msgType == "soft_reset_all" then
            local targetContext = data.context
            if targetContext then
                if targetContext ~= "" and targetContext ~= PLUGIN_CONTEXT then
                    return
                end
            end
            ll.ResetScript()
        end

        return
    end

    -- UI start
    if num == UI_BUS then
        if msgType == "start" then
            if not data.context then return end
            if data.context ~= PLUGIN_CONTEXT then return end

            currentUser = id
            userAcl = tonumber(data.acl) or -999

            showSosMenu()
            return
        end

        return
    end

    -- Dialog response
    if num == DIALOG_BUS then
        if msgType == "dialog_response" then
            if not data.session_id or not data.button then return end
            if data.session_id ~= sessionId then return end

            handleButtonClick(data.button)
            return
        end

        if msgType == "dialog_timeout" then
            if not data.session_id then return end
            if data.session_id ~= sessionId then return end
            cleanupSession()
            return
        end

        return
    end
end)

LLEvents:on("on_rez", function(startParam)
    -- Preserve state on attach/detach
end)

LLEvents:on("changed", function(changeMask)
    if bit32.btest(changeMask, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

-- Init
cleanupSession()
registerSelf()
