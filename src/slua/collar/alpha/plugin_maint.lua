--[[--------------------
PLUGIN: plugin_maint.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Maintenance and utility functions for collar management
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  lljson.encode/decode replaces llList2Json/llJsonGetValue.
  Table-based settings cache replaces JSON string manipulation.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "core_maintenance"
local PLUGIN_LABEL = "Maintenance"

-- Inventory items
local HUD_ITEM = "D/s Collar control HUD"
local MANUAL_NOTECARD = "D/s Collar User Manual"

-- State
local cachedSettings = ""
local settingsReady = false

local currentUser = NULL_KEY
local currentUserAcl = -999
local policyButtons = {}
local sessionId = ""

-- Helpers

local function isJsonArr(s)
    return string.sub(s, 1, 1) == "["
end

local function generateSessionId()
    return "maint_" .. tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime())
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

-- Lifecycle

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["1"] = "Get HUD,User Manual",
        ["2"] = "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        ["3"] = "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        ["4"] = "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        ["5"] = "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual"
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

-- Settings management

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end
    if type(data.kv) == "string" then
        cachedSettings = data.kv
    else
        cachedSettings = lljson.encode(data.kv)
    end
    settingsReady = true
end

local function applySettingsDelta()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "settings_get"
    }), NULL_KEY)
end

-- Forward declarations
local cleanupSession

-- Actions

local function fmtBool(raw)
    if tonumber(raw) and tonumber(raw) ~= 0 then return "ON" end
    return "OFF"
end

local function fmtRelayMode(raw)
    local m = tonumber(raw) or 0
    if m == 1 then return "ON" end
    if m == 2 then return "ASK" end
    return "OFF"
end

local function jsonArrCount(raw)
    if not raw or raw == "" then return 0 end
    if type(raw) == "table" then return #raw end
    if type(raw) == "string" and isJsonArr(raw) then
        local arr = lljson.decode(raw)
        if arr then return #arr end
    end
    return 0
end

local function fmtPersonLines(jsonObj, fallbackStr)
    if not jsonObj then return fallbackStr end

    local pairs_data
    if type(jsonObj) == "string" then
        pairs_data = lljson.decode(jsonObj)
    else
        pairs_data = jsonObj
    end

    if type(pairs_data) ~= "table" then return fallbackStr end

    local block = ""
    local count = 0
    for uuid, honorific in pairs_data do
        block = block .. "  " .. tostring(honorific) .. " (" .. tostring(uuid) .. ")\n"
        count = count + 1
    end
    if count == 0 then return fallbackStr end
    return block
end

local function doViewSettings()
    if not settingsReady or cachedSettings == "" then
        ll.RegionSayTo(currentUser, 0, "Settings not loaded yet. Try again.")
        return
    end

    local s = lljson.decode(cachedSettings)
    if not s then
        ll.RegionSayTo(currentUser, 0, "Settings not loaded yet. Try again.")
        return
    end

    local multi = (tonumber(s["access.multiowner"]) or 0) ~= 0

    local lockStr
    if (tonumber(s["lock.locked"]) or 0) ~= 0 then
        lockStr = "LOCKED"
    else
        lockStr = "UNLOCKED"
    end

    local rcnt = jsonArrCount(s["restrict.list"])
    local restrStr
    if rcnt > 0 then
        restrStr = tostring(rcnt) .. " active"
    else
        restrStr = "none"
    end

    local output = "\n=== Collar Settings ===\n"

    if multi then
        local ownerBlock = fmtPersonLines(s["access.owners"], "")
        if ownerBlock == "" then
            output = output .. "Owners: Uncommitted\n"
        else
            output = output .. "Owners:\n" .. ownerBlock
        end
    else
        local ownerRaw = s["access.owner"]
        if ownerRaw and type(ownerRaw) == "table" then
            local foundUuid, foundName = nil, nil
            for uuid, name in ownerRaw do
                foundUuid = uuid
                foundName = name
                break -- Luau: break is supported
            end
            if foundUuid then
                output = output .. "Owner: " .. tostring(foundName) .. " (" .. tostring(foundUuid) .. ")\n"
            else
                output = output .. "Owner: Uncommitted\n"
            end
        elseif ownerRaw and type(ownerRaw) == "string" then
            local parsed = lljson.decode(ownerRaw)
            if parsed then
                local foundUuid, foundName = nil, nil
                for uuid, name in parsed do
                    foundUuid = uuid
                    foundName = name
                    break
                end
                if foundUuid then
                    output = output .. "Owner: " .. tostring(foundName) .. " (" .. tostring(foundUuid) .. ")\n"
                else
                    output = output .. "Owner: Uncommitted\n"
                end
            else
                output = output .. "Owner: Uncommitted\n"
            end
        else
            output = output .. "Owner: Uncommitted\n"
        end
    end

    local trusteeBlock = fmtPersonLines(s["access.trustees"], "")
    if trusteeBlock == "" then
        output = output .. "Trustees: none\n"
    else
        output = output .. "Trustees:\n" .. trusteeBlock
    end

    output = output .. "Access: multi-owner " .. fmtBool(s["access.multiowner"])
    output = output .. " | runaway " .. fmtBool(s["access.enablerunaway"]) .. "\n"
    output = output .. "Lock: " .. lockStr
    output = output .. " | public " .. fmtBool(s["public.mode"])
    output = output .. " | TPE " .. fmtBool(s["tpe.mode"]) .. "\n"
    output = output .. "Relay: " .. fmtRelayMode(s["relay.mode"])
    output = output .. " | hardcore " .. fmtBool(s["relay.hardcoremode"]) .. "\n"
    output = output .. "Owner TP/IM: " .. fmtBool(s["rlvex.ownertp"])
    output = output .. "/" .. fmtBool(s["rlvex.ownerim"]) .. "\n"
    output = output .. "Trustee TP/IM: " .. fmtBool(s["rlvex.trusteetp"])
    output = output .. "/" .. fmtBool(s["rlvex.trusteeim"]) .. "\n"
    output = output .. "Restrictions: " .. restrStr

    ll.RegionSayTo(currentUser, 0, output)
end

local function doDisplayAccessList()
    if not settingsReady or cachedSettings == "" then
        ll.RegionSayTo(currentUser, 0, "Settings not loaded yet. Try again.")
        return
    end

    local s = lljson.decode(cachedSettings)
    if not s then
        ll.RegionSayTo(currentUser, 0, "Settings not loaded yet. Try again.")
        return
    end

    local output = "=== Access Control List ===\n\n"

    local multiMode = (tonumber(s["access.multiowner"]) or 0) ~= 0

    if multiMode then
        output = output .. "OWNERS:\n"
        local ownersRaw = s["access.owners"]
        local owners
        if type(ownersRaw) == "string" then
            owners = lljson.decode(ownersRaw)
        else
            owners = ownersRaw
        end

        if owners and type(owners) == "table" then
            local count = 0
            for uuid, honor in owners do
                if honor == "" then honor = "Owner" end
                output = output .. "  " .. honor .. " - " .. tostring(uuid) .. "\n"
                count = count + 1
            end
            if count == 0 then
                output = output .. "  (none)\n"
            end
        else
            output = output .. "  (none)\n"
        end
    else
        output = output .. "OWNER:\n"
        local ownerRaw = s["access.owner"]
        local owner
        if type(ownerRaw) == "string" then
            owner = lljson.decode(ownerRaw)
        else
            owner = ownerRaw
        end

        if owner and type(owner) == "table" then
            local foundUuid, foundHonor = nil, nil
            for uuid, honor in owner do
                foundUuid = uuid
                foundHonor = honor
                break
            end
            if foundUuid then
                if foundHonor == "" then foundHonor = "Owner" end
                output = output .. "  " .. foundHonor .. " - " .. tostring(foundUuid) .. "\n"
            else
                output = output .. "  (none)\n"
            end
        else
            output = output .. "  (none)\n"
        end
    end

    output = output .. "\nTRUSTEES:\n"
    local trusteesRaw = s["access.trustees"]
    local trustees
    if type(trusteesRaw) == "string" then
        trustees = lljson.decode(trusteesRaw)
    else
        trustees = trusteesRaw
    end

    if trustees and type(trustees) == "table" then
        local count = 0
        for trusteeKey, honor in trustees do
            if honor == "" then honor = "Trustee" end
            output = output .. "  " .. honor .. " - " .. tostring(trusteeKey) .. "\n"
            count = count + 1
        end
        if count == 0 then
            output = output .. "  (none)\n"
        end
    else
        output = output .. "  (none)\n"
    end

    output = output .. "\nBLACKLISTED:\n"
    local blacklistRaw = s["access.blacklist"]
    local blacklistData
    if type(blacklistRaw) == "string" and isJsonArr(blacklistRaw) then
        blacklistData = lljson.decode(blacklistRaw)
    elseif type(blacklistRaw) == "table" then
        blacklistData = blacklistRaw
    end

    if blacklistData and #blacklistData > 0 then
        for _, entry in blacklistData do
            output = output .. "  " .. tostring(entry) .. "\n"
        end
    else
        output = output .. "  (none)\n"
    end

    ll.RegionSayTo(currentUser, 0, output)
end

local function doReloadSettings()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "settings_get"
    }), NULL_KEY)

    ll.RegionSayTo(currentUser, 0, "Settings reload requested.")
end

local function doClearLeash()
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "leash_action",
        action = "release"
    }), currentUser)

    ll.RegionSayTo(currentUser, 0, "Leash cleared.")
end

local function doReloadCollar()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, lljson.encode({
        type = "soft_reset",
        from = "maintenance"
    }), NULL_KEY)

    ll.RegionSayTo(currentUser, 0, "Collar reload initiated.")
end

local function doGiveHud()
    if ll.GetInventoryType(HUD_ITEM) ~= INVENTORY_OBJECT then
        ll.RegionSayTo(currentUser, 0, "HUD not found in inventory.")
    else
        ll.GiveInventory(currentUser, HUD_ITEM)
        ll.RegionSayTo(currentUser, 0, "HUD sent.")
    end
end

local function doGiveManual()
    if ll.GetInventoryType(MANUAL_NOTECARD) ~= INVENTORY_NOTECARD then
        ll.RegionSayTo(currentUser, 0, "Manual not found in inventory.")
    else
        ll.GiveInventory(currentUser, MANUAL_NOTECARD)
        ll.RegionSayTo(currentUser, 0, "Manual sent.")
    end
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
    currentUserAcl = -999
    policyButtons = {}
    sessionId = ""
end

-- Menu display

local function showMainMenu()
    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, currentUserAcl)

    local body = "Maintenance:\n\n"
    local buttons = { "Back" }

    if btnAllowed("View Settings") then table.insert(buttons, "View Settings") end
    if btnAllowed("Reload Settings") then table.insert(buttons, "Reload Settings") end
    if btnAllowed("Access List") then table.insert(buttons, "Access List") end
    if btnAllowed("Reload Collar") then table.insert(buttons, "Reload Collar") end
    if btnAllowed("Clear Leash") then table.insert(buttons, "Clear Leash") end
    if btnAllowed("Get HUD") then table.insert(buttons, "Get HUD") end
    if btnAllowed("User Manual") then table.insert(buttons, "User Manual") end

    if btnAllowed("View Settings") then
        body = body .. "System utilities and documentation."
    else
        body = body .. "Get HUD or user manual."
    end

    sessionId = generateSessionId()

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Maintenance",
        body = body,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

-- Dialog handlers

local function handleDialogResponse(msg)
    local data = lljson.decode(msg)
    if not data or not data.session_id or not data.button then return end
    if data.session_id ~= sessionId then return end

    local button = data.button

    if button == "Back" then
        returnToRoot()
        return
    end

    if button == "View Settings" then
        doViewSettings()
        showMainMenu()
        return
    end

    if button == "Access List" then
        doDisplayAccessList()
        showMainMenu()
        return
    end

    if button == "Reload Settings" then
        doReloadSettings()
        showMainMenu()
        return
    end

    if button == "Clear Leash" then
        doClearLeash()
        showMainMenu()
        return
    end

    if button == "Reload Collar" then
        doReloadCollar()
        showMainMenu()
        return
    end

    if button == "Get HUD" then
        doGiveHud()
        showMainMenu()
        return
    end

    if button == "User Manual" then
        doGiveManual()
        showMainMenu()
        return
    end
end

local function handleDialogTimeout(msg)
    local data = lljson.decode(msg)
    if not data or not data.session_id then return end
    if data.session_id ~= sessionId then return end
    cleanupSession()
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
    -- Kernel lifecycle
    if num == KERNEL_LIFECYCLE then
        local msgType = getMsgType(msg)
        if msgType == "" then return end

        if msgType == "register_now" then
            registerSelf()
            return
        end

        if msgType == "ping" then
            sendPong()
            return
        end

        if msgType == "soft_reset" or msgType == "soft_reset_all" then
            local data = lljson.decode(msg)
            if data and data.context then
                if data.context ~= "" and data.context ~= PLUGIN_CONTEXT then
                    return
                end
            end
            ll.ResetScript()
        end
        return
    end

    -- Settings bus
    if num == SETTINGS_BUS then
        local msgType = getMsgType(msg)
        if msgType == "" then return end

        if msgType == "settings_sync" then
            applySettingsSync(msg)
            return
        end

        if msgType == "settings_delta" then
            applySettingsDelta()
            return
        end
        return
    end

    -- UI bus
    if num == UI_BUS then
        local msgType = getMsgType(msg)
        if msgType == "" then return end

        if msgType == "start" then
            local data = lljson.decode(msg)
            if not data or not data.context then return end
            if data.context ~= PLUGIN_CONTEXT then return end
            if not id.istruthy then return end

            currentUser = id
            currentUserAcl = tonumber(data.acl) or -999
            showMainMenu()
            return
        end
        return
    end

    -- Dialog bus
    if num == DIALOG_BUS then
        local msgType = getMsgType(msg)
        if msgType == "" then return end

        if msgType == "dialog_response" then
            handleDialogResponse(msg)
            return
        end

        if msgType == "dialog_timeout" then
            handleDialogTimeout(msg)
            return
        end

        if msgType == "dialog_close" then
            local data = lljson.decode(msg)
            if data and data.session_id then
                if data.session_id == sessionId then
                    currentUser = NULL_KEY
                    currentUserAcl = -999
                    policyButtons = {}
                    sessionId = ""
                end
            end
            return
        end
        return
    end
end)

-- Init
local function init()
    cleanupSession()
    registerSelf()

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "settings_get"
    }), NULL_KEY)
end

init()
