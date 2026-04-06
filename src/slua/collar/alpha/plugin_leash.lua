--[[--------------------
PLUGIN: plugin_leash.lua
VERSION: 0.10
REVISION: 0
PURPOSE: User interface and configuration for the leashing system
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based sensor candidates replaces stride lists.
  LLTimers replaces single-timer state query delay.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "core_leash"
local PLUGIN_LABEL = "Leash"

-- Configuration
local STATE_QUERY_DELAY = 0.5

-- Leash state (synced from core)
local leashed = false
local leasher = NULL_KEY
local leashLength = 3
local turnToFace = false
local leashMode = 0
local leashTarget = NULL_KEY

-- Session/menu state
local currentUser = NULL_KEY
local userAcl = -999
local policyButtons = {}
local sessionId = ""
local menuContext = ""
local sensorMode = ""
local sensorCandidates = {}  -- array of {name=str, key=key}
local sensorPage = 0
local isOfferMode = false

-- Offer dialog state
local offerDialogSession = ""
local offerTarget = NULL_KEY
local offerOriginator = NULL_KEY

-- State query tracking
local pendingStateQuery = false
local pendingQueryContext = ""
local stateQueryTimer = nil

-- Registration state
local isRegistered = false

-- Helpers

local function generateSessionId()
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function getMsgType(jsonStr)
    local data = lljson.decode(jsonStr)
    if data and data.type then return data.type end
    return ""
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
    return table.find(policyButtons, label) ~= nil
end

-- Forward declarations
local showMainMenu, showSettingsMenu, showLengthMenu, cleanupSession

-- Unified menu display

local function showMenu(context, title, body, buttons)
    sessionId = generateSessionId()
    menuContext = context

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

-- Plugin registration

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["1"] = "Clip,Post,Get Holder,Settings",
        ["2"] = "Offer",
        ["3"] = "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings",
        ["4"] = "Clip,Unclip,Pass,Yank,Coffle,Post,Get Holder,Settings",
        ["5"] = "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings"
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

-- Session cleanup

cleanupSession = function()
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
    sensorMode = ""
    sensorCandidates = {}
    sensorPage = 0
    isOfferMode = false
end

-- Query state

local function queryState()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "leash_action",
        action = "query_state"
    }), NULL_KEY)
end

local function scheduleStateQuery(nextMenuContext)
    pendingStateQuery = true
    pendingQueryContext = nextMenuContext
    if stateQueryTimer then
        LLTimers:off(stateQueryTimer)
    end
    stateQueryTimer = LLTimers:once(STATE_QUERY_DELAY, function()
        stateQueryTimer = nil
        if pendingStateQuery then
            pendingStateQuery = false
            queryState()
        end
    end)
end

-- Actions

local function sendLeashAction(action)
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "leash_action",
        action = action
    }), currentUser)
end

local function sendLeashActionWithTarget(action, target)
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "leash_action",
        action = action,
        target = tostring(target)
    }), currentUser)
end

local function sendSetLength(length)
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "leash_action",
        action = "set_length",
        length = tostring(length)
    }), currentUser)
end

local function giveHolderObject()
    if not btnAllowed("Get Holder") then
        ll.RegionSayTo(currentUser, 0, "Access denied: Insufficient permissions to receive leash holder.")
        return
    end

    local holderName = "D/s Collar leash holder"
    if ll.GetInventoryType(holderName) ~= INVENTORY_OBJECT then
        ll.RegionSayTo(currentUser, 0, "Error: Holder object not found in collar inventory.")
        return
    end
    ll.GiveInventory(currentUser, holderName)
    ll.RegionSayTo(currentUser, 0, "Leash holder given.")
end

-- Menu system

showMainMenu = function()
    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, userAcl)

    local buttons = { "Back" }

    if not leashed then
        if btnAllowed("Clip") then table.insert(buttons, "Clip") end
        if btnAllowed("Offer") then table.insert(buttons, "Offer") end
        if btnAllowed("Coffle") then table.insert(buttons, "Coffle") end
        if btnAllowed("Post") then table.insert(buttons, "Post") end
    else
        if btnAllowed("Unclip") and (currentUser == leasher or userAcl >= 3) then
            table.insert(buttons, "Unclip")
        end
        if currentUser == leasher then
            if btnAllowed("Pass") then table.insert(buttons, "Pass") end
            if btnAllowed("Yank") then table.insert(buttons, "Yank") end
        end
        if btnAllowed("Take") and currentUser ~= leasher and userAcl >= 3 then
            table.insert(buttons, "Take")
        end
    end

    if btnAllowed("Get Holder") then table.insert(buttons, "Get Holder") end
    if btnAllowed("Settings") then table.insert(buttons, "Settings") end

    local body
    if leashed then
        local modeText = "Avatar"
        if leashMode == 1 then modeText = "Coffle"
        elseif leashMode == 2 then modeText = "Post"
        end

        body = "Mode: " .. modeText .. "\n"
        body = body .. "Leashed to: " .. ll.Key2Name(leasher) .. "\n"
        body = body .. "Length: " .. tostring(leashLength) .. "m"

        if leashTarget.istruthy then
            local details = ll.GetObjectDetails(leashTarget, { OBJECT_NAME })
            if #details > 0 then
                body = body .. "\nTarget: " .. details[1]
            end
        end
    else
        body = "Not leashed"
    end

    showMenu("main", "Leash", body, buttons)
end

showSettingsMenu = function()
    local buttons = { "Back", "Length" }
    if turnToFace then
        table.insert(buttons, "Turn: On")
    else
        table.insert(buttons, "Turn: Off")
    end

    local body = "Leash Settings\nLength: " .. tostring(leashLength) .. "m\nTurn to face: " .. tostring(turnToFace)
    showMenu("settings", "Settings", body, buttons)
end

showLengthMenu = function()
    showMenu("length", "Length",
        "Select leash length\nCurrent: " .. tostring(leashLength) .. "m",
        { "<<", ">>", "Back", "1m", "3m", "5m", "10m", "15m", "20m" })
end

local function buildAvatarMenu()
    local nearby = ll.GetAgentList(AGENT_LIST_PARCEL, {})

    local wearer = ll.GetOwner()
    sensorCandidates = {}
    local count = 0

    for _, detected in nearby do
        if count >= 9 then
            break -- Luau: break is supported
        end
        if detected ~= wearer and detected ~= leasher then
            local name = ll.Key2Name(detected)
            table.insert(sensorCandidates, { name = name, key = detected })
            count = count + 1
        end
    end

    if #sensorCandidates == 0 then
        ll.RegionSayTo(currentUser, 0, "No nearby avatars found.")
        showMainMenu()
        sensorMode = ""
        return
    end

    local names = {}
    for _, c in sensorCandidates do
        table.insert(names, c.name)
    end

    local menuButtons = { "<<", ">>", "Back" }
    for _, n in names do
        table.insert(menuButtons, n)
    end

    local title
    if isOfferMode then
        title = "Offer Leash"
    else
        title = "Pass Leash"
    end

    showMenu("pass", title, "Select avatar:", menuButtons)
end

local function showPassMenu()
    sensorMode = "pass"
    menuContext = "pass"
    buildAvatarMenu()
end

local function displayObjectMenu()
    if #sensorCandidates == 0 then return end

    local totalItems = #sensorCandidates
    local totalPages = math.ceil(totalItems / 9)
    local startIndex = sensorPage * 9 + 1
    local endIndex = math.min(startIndex + 8, totalItems)

    local body = ""
    local displayNum = 1
    for i = startIndex, endIndex do
        body = body .. tostring(displayNum) .. ". " .. sensorCandidates[i].name .. "\n"
        displayNum = displayNum + 1
    end

    local menuButtons = { "<<", ">>", "Back" }
    for i = 1, (endIndex - startIndex + 1) do
        table.insert(menuButtons, tostring(i))
    end

    if totalPages > 1 then
        body = body .. "\nPage " .. tostring(sensorPage + 1) .. "/" .. tostring(totalPages)
    end

    local title = ""
    if sensorMode == "coffle" then
        title = "Coffle"
    elseif sensorMode == "post" then
        title = "Post"
    end

    showMenu(sensorMode, title, body, menuButtons)
end

local function showCoffleMenu()
    sensorMode = "coffle"
    menuContext = "coffle"
    sensorPage = 0
    sensorCandidates = {}
    ll.Sensor("", NULL_KEY, SCRIPTED, 96.0, PI)
end

local function showPostMenu()
    sensorMode = "post"
    menuContext = "post"
    sensorPage = 0
    sensorCandidates = {}
    ll.Sensor("", NULL_KEY, bit32.bor(PASSIVE, ACTIVE, SCRIPTED), 96.0, PI)
end

-- Offer dialog

local function showOfferDialog(target, originator)
    offerDialogSession = generateSessionId()
    offerTarget = target
    offerOriginator = originator

    local offererName = ll.Key2Name(originator)
    local wearerName = ll.Key2Name(ll.GetOwner())

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = offerDialogSession,
        user = tostring(target),
        title = "Leash Offer",
        body = offererName .. " (" .. wearerName .. ") is offering you their leash.",
        buttons = { "Accept", "Decline" },
        timeout = 60
    }), NULL_KEY)
end

local function handleOfferResponse(button)
    if button == "Accept" then
        ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
            type = "leash_action",
            action = "grab"
        }), offerTarget)

        ll.RegionSayTo(offerOriginator, 0, ll.Key2Name(offerTarget) .. " accepted your leash offer.")
    else
        ll.RegionSayTo(offerOriginator, 0, ll.Key2Name(offerTarget) .. " declined your leash offer.")
        ll.RegionSayTo(offerTarget, 0, "You declined the leash offer.")
    end

    offerDialogSession = ""
    offerTarget = NULL_KEY
    offerOriginator = NULL_KEY
end

local function cleanupOfferDialog()
    if offerOriginator.istruthy then
        ll.RegionSayTo(offerOriginator, 0, "Leash offer to " .. ll.Key2Name(offerTarget) .. " timed out.")
    end
    offerDialogSession = ""
    offerTarget = NULL_KEY
    offerOriginator = NULL_KEY
end

-- Button handlers

local function handleButtonClick(button)
    if menuContext == "main" then
        if button == "Clip" or button == "Take" then
            if btnAllowed(button) then
                sendLeashAction("grab")
                cleanupSession()
            end
        elseif button == "Unclip" then
            sendLeashAction("release")
            cleanupSession()
        elseif button == "Pass" then
            isOfferMode = false
            showPassMenu()
        elseif button == "Offer" then
            isOfferMode = true
            showPassMenu()
        elseif button == "Coffle" then
            showCoffleMenu()
        elseif button == "Post" then
            showPostMenu()
        elseif button == "Yank" then
            sendLeashAction("yank")
            showMainMenu()
        elseif button == "Get Holder" then
            giveHolderObject()
            showMainMenu()
        elseif button == "Settings" then
            showSettingsMenu()
        elseif button == "Back" then
            returnToRoot()
        end
    elseif menuContext == "settings" then
        if button == "Length" then
            showLengthMenu()
        elseif button == "Turn: On" or button == "Turn: Off" then
            sendLeashAction("toggle_turn")
            scheduleStateQuery("settings")
        elseif button == "Back" then
            showMainMenu()
        end
    elseif menuContext == "length" then
        if button == "Back" then
            showSettingsMenu()
        elseif button == "<<" then
            sendSetLength(leashLength - 1)
            scheduleStateQuery("length")
        elseif button == ">>" then
            sendSetLength(leashLength + 1)
            scheduleStateQuery("length")
        else
            local length = tonumber(button)
            if length and length >= 1 and length <= 20 then
                sendSetLength(length)
                scheduleStateQuery("settings")
            end
        end
    elseif menuContext == "pass" then
        if button == "Back" then
            showMainMenu()
        elseif button == "<<" or button == ">>" then
            showPassMenu()
        else
            local selected = NULL_KEY
            for _, c in sensorCandidates do
                if c.name == button then
                    selected = c.key
                    break -- Luau: break is supported
                end
            end

            if selected.istruthy then
                local action
                if isOfferMode then
                    action = "offer"
                else
                    action = "pass"
                end
                sendLeashActionWithTarget(action, selected)
                cleanupSession()
            else
                ll.RegionSayTo(currentUser, 0, "Avatar not found.")
                showMainMenu()
            end
        end
    elseif menuContext == "coffle" then
        if button == "Back" then
            showMainMenu()
        elseif button == "<<" then
            if sensorPage > 0 then
                sensorPage = sensorPage - 1
            end
            displayObjectMenu()
        elseif button == ">>" then
            local totalItems = #sensorCandidates
            local totalPages = math.ceil(totalItems / 9)
            if sensorPage < (totalPages - 1) then
                sensorPage = sensorPage + 1
            end
            displayObjectMenu()
        else
            local buttonNum = tonumber(button)
            if buttonNum and buttonNum >= 1 and buttonNum <= 9 then
                local actualIndex = sensorPage * 9 + buttonNum
                if actualIndex <= #sensorCandidates then
                    local selected = sensorCandidates[actualIndex].key
                    sendLeashActionWithTarget("coffle", selected)
                    cleanupSession()
                else
                    ll.RegionSayTo(currentUser, 0, "Invalid selection.")
                    showMainMenu()
                end
            else
                ll.RegionSayTo(currentUser, 0, "Invalid selection.")
                showMainMenu()
            end
        end
    elseif menuContext == "post" then
        if button == "Back" then
            showMainMenu()
        elseif button == "<<" then
            if sensorPage > 0 then
                sensorPage = sensorPage - 1
            end
            displayObjectMenu()
        elseif button == ">>" then
            local totalItems = #sensorCandidates
            local totalPages = math.ceil(totalItems / 9)
            if sensorPage < (totalPages - 1) then
                sensorPage = sensorPage + 1
            end
            displayObjectMenu()
        else
            local buttonNum = tonumber(button)
            if buttonNum and buttonNum >= 1 and buttonNum <= 9 then
                local actualIndex = sensorPage * 9 + buttonNum
                if actualIndex <= #sensorCandidates then
                    local selected = sensorCandidates[actualIndex].key
                    sendLeashActionWithTarget("post", selected)
                    cleanupSession()
                else
                    ll.RegionSayTo(currentUser, 0, "Invalid selection.")
                    showMainMenu()
                end
            else
                ll.RegionSayTo(currentUser, 0, "Invalid selection.")
                showMainMenu()
            end
        end
    end
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

LLEvents:on("link_message", function(sender, num, msg, id)
    if num == KERNEL_LIFECYCLE then
        local msgType = getMsgType(msg)
        if msgType == "" then return end

        if msgType == "register_now" then
            registerSelf()
            isRegistered = true
            return
        end
        if msgType == "ping" then
            sendPong()
            return
        end
        return
    end

    if num == UI_BUS then
        local msgType = getMsgType(msg)
        if msgType == "" then return end

        if msgType == "start" then
            local data = lljson.decode(msg)
            if not data or not data.context then return end
            if data.context ~= PLUGIN_CONTEXT then return end
            currentUser = id
            userAcl = tonumber(data.acl) or -999
            scheduleStateQuery("main")
            return
        end

        if msgType == "leash_state" then
            local data = lljson.decode(msg)
            if not data then return end

            if data.leashed ~= nil then leashed = (tonumber(data.leashed) or 0) ~= 0 end
            if data.leasher ~= nil then leasher = data.leasher end
            if data.length ~= nil then leashLength = tonumber(data.length) or 3 end
            if data.turnto ~= nil then turnToFace = (tonumber(data.turnto) or 0) ~= 0 end
            if data.mode ~= nil then leashMode = tonumber(data.mode) or 0 end
            if data.target ~= nil then leashTarget = data.target end

            if pendingQueryContext ~= "" then
                local menuToShow = pendingQueryContext
                pendingQueryContext = ""

                if menuToShow == "settings" then
                    showSettingsMenu()
                elseif menuToShow == "length" then
                    showLengthMenu()
                elseif menuToShow == "main" then
                    showMainMenu()
                end
            end
            return
        end

        if msgType == "offer_pending" then
            local data = lljson.decode(msg)
            if not data or not data.target or not data.originator then return end
            showOfferDialog(data.target, data.originator)
            return
        end
    end

    if num == DIALOG_BUS then
        local msgType = getMsgType(msg)
        if msgType == "" then return end

        if msgType == "dialog_response" then
            local data = lljson.decode(msg)
            if not data or not data.session_id or not data.button then return end

            if data.session_id == offerDialogSession then
                handleOfferResponse(data.button)
                return
            end

            if data.session_id ~= sessionId then return end
            handleButtonClick(data.button)
            return
        end

        if msgType == "dialog_timeout" then
            local data = lljson.decode(msg)
            if not data or not data.session_id then return end

            if data.session_id == offerDialogSession then
                cleanupOfferDialog()
                return
            end

            if data.session_id ~= sessionId then return end
            cleanupSession()
            return
        end
        return
    end
end)

LLEvents:on("sensor", function(events)
    if sensorMode == "" then return end
    if not currentUser.istruthy then return end
    if sensorMode ~= "coffle" and sensorMode ~= "post" then return end

    local wearer = ll.GetOwner()
    local myKey = ll.GetKey()
    sensorCandidates = {}

    for _, det in events do
        local detected = det.Key
        if detected ~= myKey and detected ~= wearer then
            table.insert(sensorCandidates, { name = det.Name, key = detected })
        end
    end

    if #sensorCandidates == 0 then
        if sensorMode == "coffle" then
            ll.RegionSayTo(currentUser, 0, "No nearby objects found for coffle.")
        elseif sensorMode == "post" then
            ll.RegionSayTo(currentUser, 0, "No nearby objects found to post to.")
        end
        showMainMenu()
        sensorMode = ""
        return
    end

    displayObjectMenu()
end)

LLEvents:on("no_sensor", function()
    if sensorMode == "" then return end
    if not currentUser.istruthy then return end
    if sensorMode ~= "coffle" and sensorMode ~= "post" then return end

    if sensorMode == "coffle" then
        ll.RegionSayTo(currentUser, 0, "No nearby objects found for coffle.")
    elseif sensorMode == "post" then
        ll.RegionSayTo(currentUser, 0, "No nearby objects found to post to.")
    end
    showMainMenu()
    sensorMode = ""
end)

-- Init
local function init()
    cleanupSession()
    registerSelf()
    queryState()
end

init()
