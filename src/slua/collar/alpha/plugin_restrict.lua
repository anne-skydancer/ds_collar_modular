--[[--------------------
PLUGIN: plugin_restrict.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Manage RLV restriction toggles grouped by functional category
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based restriction tracking replaces stride lists.
  lljson.decode replaces llJsonGetValue chains.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "core_rlvrestrict"
local PLUGIN_LABEL = "Restrict"

-- Settings keys
local KEY_RESTRICTIONS = "restrict.list"

-- Restriction state
local MAX_RESTRICTIONS = 32
local restrictions = {}

-- Categories
local CAT_NAME_INVENTORY = "Inventory"
local CAT_NAME_SPEECH = "Speech"
local CAT_NAME_TRAVEL = "Travel"
local CAT_NAME_OTHER = "Other"

local CAT_INV = {"@detachall", "@addoutfit", "@remoutfit", "@remattach", "@addattach", "@attachall", "@showinv", "@viewnote", "@viewscript"}
local CAT_SPEECH = {"@sendchat", "@recvim", "@sendim", "@startim", "@chatshout", "@chatwhisper"}
local CAT_TRAVEL = {"@tptlm", "@tploc", "@tplure"}
local CAT_OTHER = {"@edit", "@rez", "@touchall", "@touchworld", "@accepttp", "@shownames", "@sit", "@unsit", "@stand"}

local LABEL_INV = {"Det. All:", "+ Outfit:", "- Outfit:", "- Attach:", "+ Attach:", "Att. All:", "Inv:", "Notes:", "Scripts:"}
local LABEL_SPEECH = {"Chat:", "Recv IM:", "Send IM:", "Start IM:", "Shout:", "Whisper:"}
local LABEL_TRAVEL = {"Map TP:", "Loc. TP:", "TP:"}
local LABEL_OTHER = {"Edit:", "Rez:", "Touch:", "Touch Wld:", "OK TP:", "Names:", "Sit:", "Unsit:", "Stand:"}

-- UI session state
local sessionId = ""
local currentUser = NULL_KEY
local userAcl = 0
local policyButtons = {}

local menuContext = ""
local currentCategory = ""
local currentPage = 0

local DIALOG_PAGE_SIZE = 9

-- Force sit state
local sitCandidates = {}
local sitPage = 0
local SIT_SCAN_RANGE = 10.0
local scanInitiator = NULL_KEY

-- Helpers

local function generateSessionId()
    return ll.GetScriptName() .. "_" .. tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime())
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

-- Lifecycle

local function cleanupSession()
    if sessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
            type = "dialog_close",
            session_id = sessionId
        }), NULL_KEY)
    end

    sessionId = ""
    currentUser = NULL_KEY
    userAcl = 0
    policyButtons = {}
    menuContext = ""
    currentCategory = ""
    currentPage = 0
end

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["1"] = "Force Sit,Force Unsit",
        ["2"] = "Force Sit,Force Unsit",
        ["3"] = "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        ["4"] = "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        ["5"] = "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit"
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

-- Settings persistence

local function persistRestrictions()
    local csv = table.concat(restrictions, ",")

    ll.LinksetDataWrite(KEY_RESTRICTIONS, csv)

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = KEY_RESTRICTIONS,
        value = csv
    }), NULL_KEY)
end

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end

    if ll.LinksetDataRead(KEY_RESTRICTIONS) == "" then
        local csv = data.kv[KEY_RESTRICTIONS]
        if csv ~= nil then
            if csv ~= "" then
                restrictions = string.split(csv, ",")
                for _, r in ipairs(restrictions) do
                    ll.OwnerSay(r .. "=y")
                end
            else
                restrictions = {}
            end
            ll.LinksetDataWrite(KEY_RESTRICTIONS, csv)
        end
    end
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.op then return end

    if data.op == "set" then
        local changes = data.changes
        if not changes then return end

        local csv = changes[KEY_RESTRICTIONS]
        if csv ~= nil then
            -- Clear all current restrictions
            for _, restrCmd in ipairs(restrictions) do
                ll.OwnerSay("@clear=" .. string.sub(restrCmd, 2))
            end

            -- Load new list
            if csv ~= "" then
                restrictions = string.split(csv, ",")
            else
                restrictions = {}
            end

            -- Apply new restrictions and persist to LSD
            for _, restrCmd in ipairs(restrictions) do
                ll.OwnerSay(restrCmd .. "=y")
            end
            ll.LinksetDataWrite(KEY_RESTRICTIONS, csv)
        end
    end
end

-- Restriction logic

local function restrictionIdx(restrCmd)
    for i, v in ipairs(restrictions) do
        if v == restrCmd then return i end
    end
    return nil
end

local function toggleRestriction(restrCmd)
    local idx = restrictionIdx(restrCmd)

    if idx then
        table.remove(restrictions, idx)
        ll.OwnerSay("@clear=" .. string.sub(restrCmd, 2))
    else
        if #restrictions >= MAX_RESTRICTIONS then
            ll.RegionSayTo(currentUser, 0, "Cannot add restriction: limit reached.")
            return
        end

        restrictions[#restrictions + 1] = restrCmd
        ll.OwnerSay(restrCmd .. "=y")
    end

    persistRestrictions()
end

local function removeAllRestrictions()
    for _, restrCmd in ipairs(restrictions) do
        ll.OwnerSay("@clear=" .. string.sub(restrCmd, 2))
    end

    restrictions = {}
    persistRestrictions()
end

-- Category helpers

local function getCategoryList(catName)
    if catName == CAT_NAME_INVENTORY then return CAT_INV end
    if catName == CAT_NAME_SPEECH then return CAT_SPEECH end
    if catName == CAT_NAME_TRAVEL then return CAT_TRAVEL end
    if catName == CAT_NAME_OTHER then return CAT_OTHER end
    return {}
end

local function getCategoryLabels(catName)
    if catName == CAT_NAME_INVENTORY then return LABEL_INV end
    if catName == CAT_NAME_SPEECH then return LABEL_SPEECH end
    if catName == CAT_NAME_TRAVEL then return LABEL_TRAVEL end
    if catName == CAT_NAME_OTHER then return LABEL_OTHER end
    return {}
end

local function labelToCommand(btnLabel, catCmds, catLabels)
    local cleanLabel = btnLabel
    if string.sub(btnLabel, 1, 4) == "[X] " or string.sub(btnLabel, 1, 4) == "[ ] " then
        cleanLabel = string.sub(btnLabel, 5)
    end

    for i, lbl in ipairs(catLabels) do
        if lbl == cleanLabel then
            return catCmds[i]
        end
    end
    return ""
end

-- Force sit/unsit

local function forceSitOn(target)
    if target == NULL_KEY then return end
    ll.OwnerSay("@sit:" .. tostring(target) .. "=force")
    ll.RegionSayTo(currentUser, 0, "Forcing sit...")
end

local function forceUnsit()
    ll.OwnerSay("@unsit=force")
    ll.RegionSayTo(currentUser, 0, "Forcing unsit...")
end

-- Navigation

local function returnToRoot()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "return",
        context = PLUGIN_CONTEXT,
        user = tostring(currentUser)
    }), NULL_KEY)

    cleanupSession()
end

-- Forward declarations
local showMain, showCategoryMenu, displaySitTargets, startSitScan

-- Menus

showMain = function()
    sessionId = generateSessionId()
    menuContext = "main"

    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, userAcl)

    local body
    local buttons = {"Back"}

    if btnAllowed("Inventory") then buttons[#buttons + 1] = CAT_NAME_INVENTORY end
    if btnAllowed("Speech") then buttons[#buttons + 1] = CAT_NAME_SPEECH end
    if btnAllowed("Travel") then buttons[#buttons + 1] = CAT_NAME_TRAVEL end
    if btnAllowed("Other") then buttons[#buttons + 1] = CAT_NAME_OTHER end
    if btnAllowed("Clear all") then buttons[#buttons + 1] = "Clear all" end
    if btnAllowed("Force Sit") then buttons[#buttons + 1] = "Force Sit" end
    if btnAllowed("Force Unsit") then buttons[#buttons + 1] = "Force Unsit" end

    if btnAllowed("Inventory") then
        body = "RLV Restrictions\n\nActive: " .. tostring(#restrictions) .. "/" .. tostring(MAX_RESTRICTIONS)
    else
        body = "RLV Actions\n\nForce sit or unsit the wearer."
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = PLUGIN_LABEL,
        body = body,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

showCategoryMenu = function(catName, pageNum)
    sessionId = generateSessionId()
    menuContext = "category"
    currentCategory = catName
    currentPage = pageNum

    local catCmds = getCategoryList(catName)
    local catLabels = getCategoryLabels(catName)
    local totalItems = #catCmds

    if totalItems == 0 then
        ll.RegionSayTo(currentUser, 0, "Empty category.")
        showMain()
        return
    end

    -- Calculate page bounds (1-based)
    local startIdx = pageNum * DIALOG_PAGE_SIZE + 1
    local endIdx = startIdx + DIALOG_PAGE_SIZE - 1
    if endIdx > totalItems then
        endIdx = totalItems
    end

    -- Build button list with checkbox prefixes
    local pageButtons = {}
    for i = startIdx, endIdx do
        local cmd = catCmds[i]
        local label = catLabels[i]

        local isActive = (restrictionIdx(cmd) ~= nil)
        if isActive then
            label = "[X] " .. label
        else
            label = "[ ] " .. label
        end

        pageButtons[#pageButtons + 1] = label
    end

    -- Calculate max page
    local maxPage = math.floor((totalItems - 1) / DIALOG_PAGE_SIZE)

    -- Reverse the order so items fill bottom-right to top-left
    local reversed = {}
    for i = #pageButtons, 1, -1 do
        reversed[#reversed + 1] = pageButtons[i]
    end

    -- Add nav buttons in bottom-left corner
    local finalButtons = {"Back", "<<", ">>"}
    for _, btn in ipairs(reversed) do
        finalButtons[#finalButtons + 1] = btn
    end

    local body = catName .. " (" .. tostring(pageNum + 1) .. "/" .. tostring(maxPage + 1) .. ")\n\nActive: " .. tostring(#restrictions)

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = catName,
        body = body,
        buttons = finalButtons,
        timeout = 60
    }), NULL_KEY)
end

startSitScan = function()
    sitCandidates = {}
    sitPage = 0
    menuContext = "sit_scan"
    scanInitiator = currentUser

    ll.RegionSayTo(currentUser, 0, "Scanning for nearby objects...")
    ll.Sensor("", NULL_KEY, bit32.bor(PASSIVE, ACTIVE, SCRIPTED), SIT_SCAN_RANGE, PI)
end

displaySitTargets = function()
    local totalItems = #sitCandidates

    if totalItems == 0 then
        ll.RegionSayTo(currentUser, 0, "No objects found nearby.")
        showMain()
        return
    end

    sessionId = generateSessionId()
    menuContext = "sit_select"

    local itemsPerPage = 9
    local totalPages = math.ceil(totalItems / itemsPerPage)
    local startIdx = sitPage * itemsPerPage + 1
    local endIdx = startIdx + itemsPerPage - 1
    if endIdx > totalItems then endIdx = totalItems end

    local body = "Select object to sit on:\n\n"
    local displayNum = 1
    for i = startIdx, endIdx do
        local objName = sitCandidates[i].name
        if #objName > 20 then
            objName = string.sub(objName, 1, 18) .. "..."
        end
        body = body .. tostring(displayNum) .. ". " .. objName .. "\n"
        displayNum = displayNum + 1
    end

    if totalPages > 1 then
        body = body .. "\nPage " .. tostring(sitPage + 1) .. "/" .. tostring(totalPages)
    end

    local buttons = {"Back", "<<", ">>"}
    for i = 1, (endIdx - startIdx + 1) do
        buttons[#buttons + 1] = tostring(i)
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Force Sit",
        body = body,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

-- Dialog handlers

local function handleDialogResponse(msg)
    local data = lljson.decode(msg)
    if not data or not data.session_id or not data.button or not data.user then return end
    if data.session_id ~= sessionId then return end
    if data.user ~= tostring(currentUser) then return end

    local button = data.button

    -- Main menu
    if menuContext == "main" then
        if button == "Back" then
            returnToRoot()
        elseif button == CAT_NAME_INVENTORY or button == CAT_NAME_SPEECH or
               button == CAT_NAME_TRAVEL or button == CAT_NAME_OTHER then
            if not btnAllowed(button) then
                ll.RegionSayTo(currentUser, 0, "Access denied.")
                showMain()
                return
            end
            showCategoryMenu(button, 0)
        elseif button == "Clear all" then
            if not btnAllowed("Clear all") then
                ll.RegionSayTo(currentUser, 0, "Access denied.")
                showMain()
                return
            end
            removeAllRestrictions()
            ll.RegionSayTo(currentUser, 0, "All restrictions removed.")
            showMain()
        elseif button == "Force Sit" then
            startSitScan()
        elseif button == "Force Unsit" then
            forceUnsit()
            showMain()
        end

    -- Sit selection menu
    elseif menuContext == "sit_select" then
        if button == "Back" then
            showMain()
        elseif button == "<<" then
            local totalItems = #sitCandidates
            local itemsPerPage = 9
            local maxPage = math.floor((totalItems - 1) / itemsPerPage)

            if sitPage == 0 then
                sitPage = maxPage
            else
                sitPage = sitPage - 1
            end
            displaySitTargets()
        elseif button == ">>" then
            local totalItems = #sitCandidates
            local itemsPerPage = 9
            local maxPage = math.floor((totalItems - 1) / itemsPerPage)

            if sitPage >= maxPage then
                sitPage = 0
            else
                sitPage = sitPage + 1
            end
            displaySitTargets()
        else
            local buttonNum = tonumber(button) or 0
            if buttonNum >= 1 and buttonNum <= 9 then
                local itemsPerPage = 9
                local actualIdx = sitPage * itemsPerPage + buttonNum

                if actualIdx <= #sitCandidates then
                    local target = sitCandidates[actualIdx].id
                    forceSitOn(target)
                    showMain()
                end
            end
        end

    -- Category menu
    elseif menuContext == "category" then
        if button == "Back" then
            showMain()
        elseif button == "<<" then
            local catCmds = getCategoryList(currentCategory)
            local totalItems = #catCmds
            local maxPage = math.floor((totalItems - 1) / DIALOG_PAGE_SIZE)

            if currentPage == 0 then
                showCategoryMenu(currentCategory, maxPage)
            else
                showCategoryMenu(currentCategory, currentPage - 1)
            end
        elseif button == ">>" then
            local catCmds = getCategoryList(currentCategory)
            local totalItems = #catCmds
            local maxPage = math.floor((totalItems - 1) / DIALOG_PAGE_SIZE)

            if currentPage >= maxPage then
                showCategoryMenu(currentCategory, 0)
            else
                showCategoryMenu(currentCategory, currentPage + 1)
            end
        else
            local catCmds = getCategoryList(currentCategory)
            local catLabels = getCategoryLabels(currentCategory)

            local restrCmd = labelToCommand(button, catCmds, catLabels)

            if restrCmd ~= "" then
                toggleRestriction(restrCmd)
                showCategoryMenu(currentCategory, currentPage)
            end
        end
    end
end

local function handleDialogTimeout(msg)
    local data = lljson.decode(msg)
    if not data or not data.session_id then return end
    if data.session_id ~= sessionId then return end
    cleanupSession()
end

-- Events

LLEvents:on("on_rez", function(param)
    ll.ResetScript()
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

LLEvents:on("sensor", function(numDetected)
    if menuContext ~= "sit_scan" then return end
    if currentUser == NULL_KEY then return end
    if tostring(currentUser) ~= tostring(scanInitiator) then return end

    local wearer = ll.GetOwner()
    local myKey = ll.GetKey()
    sitCandidates = {}

    for i = 1, numDetected do
        local detectedKey = ll.DetectedKey(i)
        if detectedKey ~= myKey and detectedKey ~= wearer then
            sitCandidates[#sitCandidates + 1] = {
                name = ll.DetectedName(i),
                id = detectedKey
            }
        end
    end

    displaySitTargets()
end)

LLEvents:on("no_sensor", function()
    if menuContext ~= "sit_scan" then return end
    if currentUser == NULL_KEY then return end
    if tostring(currentUser) ~= tostring(scanInitiator) then return end

    ll.RegionSayTo(currentUser, 0, "No objects found within " .. tostring(math.floor(SIT_SCAN_RANGE)) .. "m.")
    showMain()
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    local data = lljson.decode(msg)
    if not data or not data.type then return end
    local msgType = data.type

    if num == KERNEL_LIFECYCLE then
        if msgType == "register_now" then
            registerSelf()
            ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
                type = "settings_get"
            }), NULL_KEY)
        elseif msgType == "ping" then
            sendPong()
        elseif msgType == "soft_reset" then
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
            local context = data.context
            if not context then return end
            if context == PLUGIN_CONTEXT then
                currentUser = id
                userAcl = tonumber(data.acl) or 0
                showMain()
            end
        end
    elseif num == DIALOG_BUS then
        if msgType == "dialog_response" then
            handleDialogResponse(msg)
        elseif msgType == "dialog_timeout" then
            handleDialogTimeout(msg)
        end
    end
end)

-- Init

local function init()
    cleanupSession()

    -- Restore restrictions from LSD
    local lsdCsv = ll.LinksetDataRead(KEY_RESTRICTIONS)
    if lsdCsv ~= "" then
        restrictions = string.split(lsdCsv, ",")
        for _, r in ipairs(restrictions) do
            ll.OwnerSay(r .. "=y")
        end
    end

    registerSelf()

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "settings_get"
    }), NULL_KEY)
end

init()
