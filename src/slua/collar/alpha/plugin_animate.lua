--[[--------------------
PLUGIN: plugin_animate.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Paginated animation menu driven by inventory contents
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.1 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based animation list replaces stride lists.
  LLEvents replaces state-based event handling.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "core_animate"
local PLUGIN_LABEL = "Animate"

-- Constants
local MAX_ANIMATIONS = 128
local PAGE_SIZE = 8

-- Session state
local currentUser = NULL_KEY
local userAcl = -999
local policyButtons = {}
local sessionId = ""

-- Pagination
local currentPage = 0

-- Animation inventory
local animationList = {}
local lastPlayedAnim = ""

-- Permissions
local hasPermission = false

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
    for _, v in ipairs(policyButtons) do
        if v == label then return true end
    end
    return false
end

-- Animation inventory management

local function refreshAnimationList()
    animationList = {}
    local count = ll.GetInventoryNumber(INVENTORY_ANIMATION)

    if count > MAX_ANIMATIONS then
        ll.OwnerSay("WARNING: Too many animations (" .. tostring(count) .. "). Only loading first " .. tostring(MAX_ANIMATIONS) .. ".")
        count = MAX_ANIMATIONS
    end

    for i = 0, count - 1 do
        local animName = ll.GetInventoryName(INVENTORY_ANIMATION, i)
        if animName ~= "" then
            table.insert(animationList, animName)
        end
    end
end

-- Animation control

local function ensurePermissions()
    local owner = ll.GetOwner()
    if bit32.btest(ll.GetPermissions(), PERMISSION_TRIGGER_ANIMATION) then
        hasPermission = true
    else
        ll.RequestPermissions(owner, PERMISSION_TRIGGER_ANIMATION)
    end
end

local function startAnimation(animName)
    if not hasPermission then
        ll.RegionSayTo(currentUser, 0, "No animation permission granted.")
        return
    end

    if lastPlayedAnim ~= "" then
        ll.StopAnimation(lastPlayedAnim)
    end

    if ll.GetInventoryType(animName) == INVENTORY_ANIMATION then
        ll.StartAnimation(animName)
        lastPlayedAnim = animName
        ll.RegionSayTo(currentUser, 0, "Playing: " .. animName)
    else
        ll.RegionSayTo(currentUser, 0, "Animation not found: " .. animName)
    end
end

local function stopAllAnimations()
    if lastPlayedAnim ~= "" then
        ll.StopAnimation(lastPlayedAnim)
        lastPlayedAnim = ""
        ll.RegionSayTo(currentUser, 0, "Animation stopped.")
    else
        ll.RegionSayTo(currentUser, 0, "No animation playing.")
    end
end

-- Lifecycle management

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["1"] = "<<,>>,Stop",
        ["2"] = "<<,>>,Stop",
        ["3"] = "<<,>>,Stop",
        ["4"] = "<<,>>,Stop",
        ["5"] = "<<,>>,Stop"
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

-- Forward declarations
local showAnimationMenu
local cleanupSession

-- UI navigation

local function uiReturnRoot()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "return",
        user = tostring(currentUser)
    }), NULL_KEY)
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
    currentPage = 0
end

-- Button handling

local function handleButtonClick(button)
    if button == "Back" then
        uiReturnRoot()
        cleanupSession()
        return
    end

    if button == "[Stop]" then
        stopAllAnimations()
        showAnimationMenu(currentPage)
        return
    end

    if button == "<<" then
        local totalAnims = #animationList
        local maxPage = math.floor((totalAnims - 1) / PAGE_SIZE)

        if currentPage == 0 then
            showAnimationMenu(maxPage)
        else
            showAnimationMenu(currentPage - 1)
        end
        return
    end

    if button == ">>" then
        local totalAnims = #animationList
        local maxPage = math.floor((totalAnims - 1) / PAGE_SIZE)

        if currentPage >= maxPage then
            showAnimationMenu(0)
        else
            showAnimationMenu(currentPage + 1)
        end
        return
    end

    -- Check if button is an animation name
    for _, anim in ipairs(animationList) do
        if anim == button then
            startAnimation(button)
            showAnimationMenu(currentPage)
            return
        end
    end

    -- Unknown button - redraw menu
    showAnimationMenu(currentPage)
end

-- UI / menu system

showAnimationMenu = function(page)
    sessionId = generateSessionId()
    currentPage = page

    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, userAcl)

    local totalAnims = #animationList

    -- Handle empty animation list
    if totalAnims == 0 then
        local buttonsJson = lljson.encode({"Back"})

        ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
            type = "dialog_open",
            session_id = sessionId,
            user = tostring(currentUser),
            title = PLUGIN_LABEL,
            message = "No animations found in inventory.",
            buttons = buttonsJson,
            timeout = 60
        }), NULL_KEY)
        return
    end

    -- Calculate page bounds
    local maxPage = math.floor((totalAnims - 1) / PAGE_SIZE)

    if page < 0 then page = 0 end
    if page > maxPage then page = maxPage end
    currentPage = page

    local startIdx = page * PAGE_SIZE + 1  -- 1-based
    local endIdx = startIdx + PAGE_SIZE - 1
    if endIdx > totalAnims then endIdx = totalAnims end

    -- Extract animations for this page
    local pageAnims = {}
    for i = startIdx, endIdx do
        table.insert(pageAnims, animationList[i])
    end

    local count = #pageAnims
    local totalButtons = 4 + count

    -- Initialize button list with nav + placeholders
    local finalButtons = {"<<", ">>", "Back", "[Stop]"}
    for p = 1, count do
        table.insert(finalButtons, "")
    end

    -- Define visual rows (Top to Bottom)
    -- Row 4: 10, 11, 12 (1-based)
    -- Row 3: 7, 8, 9
    -- Row 2: 5, 6 (index 4 is Stop)
    local targetSlots = {}

    if totalButtons > 9 then table.insert(targetSlots, 10) end
    if totalButtons > 10 then table.insert(targetSlots, 11) end
    if totalButtons > 11 then table.insert(targetSlots, 12) end

    if totalButtons > 6 then table.insert(targetSlots, 7) end
    if totalButtons > 7 then table.insert(targetSlots, 8) end
    if totalButtons > 8 then table.insert(targetSlots, 9) end

    if totalButtons > 4 then table.insert(targetSlots, 5) end
    if totalButtons > 5 then table.insert(targetSlots, 6) end

    -- Map animations to slots
    for i = 1, count do
        local slot = targetSlots[i]
        finalButtons[slot] = pageAnims[i]
    end

    local buttonsJson = lljson.encode(finalButtons)

    -- Build message
    local message = "Select an animation to play.\n"
    message = message .. "Page " .. tostring(page + 1) .. " of " .. tostring(maxPage + 1)
    if lastPlayedAnim ~= "" then
        message = message .. "\nPlaying: " .. lastPlayedAnim
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = PLUGIN_LABEL,
        message = message,
        buttons = buttonsJson,
        timeout = 60
    }), NULL_KEY)
end

-- Events

LLEvents:on("link_message", function(event)
    local num = event:getNum()
    local msg = event:getStr()
    local id = event:getID()

    -- Kernel lifecycle
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

    -- UI start
    if num == UI_BUS then
        local data = lljson.decode(msg)
        if not data or not data.type then return end

        if data.type == "start" then
            if not data.context then return end
            if data.context ~= PLUGIN_CONTEXT then return end
            if not id.istruthy then return end

            currentUser = id
            currentPage = 0
            userAcl = tonumber(data.acl) or -999

            showAnimationMenu(0)
            return
        end

        return
    end

    -- Dialog response
    if num == DIALOG_BUS then
        local data = lljson.decode(msg)
        if not data or not data.type then return end

        if data.type == "dialog_response" then
            if not data.session_id then return end
            if data.session_id ~= sessionId then return end
            if not data.button then return end
            if not data.user then return end

            if data.user ~= tostring(currentUser) then return end

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

LLEvents:on("run_time_permissions", function(event)
    local perm = event:getPermissions()
    if bit32.btest(perm, PERMISSION_TRIGGER_ANIMATION) then
        hasPermission = true
    end
end)

LLEvents:on("on_rez", function(event)
    ll.ResetScript()
end)

LLEvents:on("changed", function(event)
    local change = event:getChange()

    if bit32.btest(change, CHANGED_OWNER) then
        ll.ResetScript()
    end

    if bit32.btest(change, CHANGED_INVENTORY) then
        local oldCount = #animationList
        refreshAnimationList()
        local newCount = #animationList

        if oldCount ~= newCount and currentUser ~= NULL_KEY then
            local totalAnims = newCount
            local maxPage = 0
            if totalAnims > 0 then
                maxPage = math.floor((totalAnims - 1) / PAGE_SIZE)
            end
            if currentPage > maxPage then
                currentPage = maxPage
            end

            showAnimationMenu(currentPage)
        end
    end
end)

-- Initialization (state_entry equivalent)
cleanupSession()
refreshAnimationList()
ensurePermissions()
registerSelf()
