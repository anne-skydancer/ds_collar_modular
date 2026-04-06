--[[--------------------
MODULE: kmod_menu.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Menu rendering and visual presentation service
ARCHITECTURE: Consolidated message bus lanes (SLua port)
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
--------------------]]

-- Consolidated ABI
local UI_BUS = 900
local DIALOG_BUS = 950

-- Helpers

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

-- Button layout

local function reverseCompleteRows(buttonList, rowSize)
    local reordered = {}
    local count = #buttonList
    if count == 0 then return {} end

    local numRows = math.floor(count / rowSize)
    local row = numRows - 1
    while row >= 0 do
        local rowStart = row * rowSize + 1
        for i = rowStart, rowStart + rowSize - 1 do
            reordered[#reordered + 1] = buttonList[i]
        end
        row -= 1
    end
    return reordered
end

local function reorderButtonsForDisplay(buttons)
    local count = #buttons
    if count == 0 then return {} end

    local rowSize = 3
    local partialCount = count % rowSize

    if partialCount == 0 then
        return reverseCompleteRows(buttons, rowSize)
    else
        -- Extract partial row (first partialCount elements)
        local partialRow = {}
        for i = 1, partialCount do
            partialRow[i] = buttons[i]
        end

        -- Extract complete rows (remaining elements)
        local completeButtons = {}
        for i = partialCount + 1, count do
            completeButtons[#completeButtons + 1] = buttons[i]
        end

        local reorderedComplete = reverseCompleteRows(completeButtons, rowSize)

        -- Concatenate: reordered complete rows + partial row
        for _, btn in partialRow do
            reorderedComplete[#reorderedComplete + 1] = btn
        end
        return reorderedComplete
    end
end

-- Rendering

local function renderMenu(data)
    if not validateRequiredFields(data, { "user", "session_id", "menu_type", "buttons" }) then
        return
    end

    local user = key(data.user)
    local sessionId = data.session_id
    local menuType = data.menu_type
    local currentPage = tonumber(data.page) or 0
    local totalPages = tonumber(data.total_pages) or 0
    local buttonDataList = data.buttons
    local hasNav = tonumber(data.has_nav) or 0

    local reordered = reorderButtonsForDisplay(buttonDataList)

    local finalButtonData
    if hasNav ~= 0 then
        finalButtonData = { "<<", ">>", "Close" }
    else
        finalButtonData = { "Close" }
    end
    for _, btn in reordered do
        finalButtonData[#finalButtonData + 1] = btn
    end

    local title
    if menuType == "core_root" then
        title = "Main Menu"
    elseif menuType == "sos_root" then
        title = "Emergency Menu"
    else
        title = "Menu"
    end

    if totalPages > 1 then
        title = title .. " (" .. tostring(currentPage + 1) .. "/" .. tostring(totalPages) .. ")"
    end

    local bodyText
    if menuType == "core_root" then
        bodyText = "Select an option:"
    elseif menuType == "sos_root" then
        bodyText = "Emergency options:"
    else
        bodyText = "Choose:"
    end

    local dialogMsg = lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(user),
        title = title,
        body = bodyText,
        button_data = finalButtonData,
        timeout = 60
    })

    ll.MessageLinked(LINK_SET, DIALOG_BUS, dialogMsg, NULL_KEY)
end

local function showMessage(data)
    if not validateRequiredFields(data, { "user", "message" }) then
        return
    end

    local user = key(data.user)
    local messageText = data.message

    ll.RegionSayTo(user, 0, messageText)
end

-- Events

LLEvents:on("link_message", function(sender, num, msg, id)
    local msgType = getMsgType(msg)
    if msgType == "" then return end

    if num == UI_BUS then
        local data = lljson.decode(msg)
        if not data then return end

        if msgType == "render_menu" then
            renderMenu(data)
        elseif msgType == "show_message" then
            showMessage(data)
        end
    end
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)
