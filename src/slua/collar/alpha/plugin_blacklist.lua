--[[--------------------
PLUGIN: plugin_blacklist.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Blacklist management with sensor-based avatar selection
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based blacklist replaces stride lists.
  lljson.encode/decode replaces llList2Json/llJsonGetValue.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "core_blacklist"
local PLUGIN_LABEL = "Blacklist"

-- Constants
local MAX_NUMBERED_LIST_ITEMS = 11

-- Settings keys
local KEY_BLACKLIST = "access.blacklist"

-- UI constants
local BTN_BACK = "Back"
local BTN_ADD = "+Blacklist"
local BTN_REMOVE = "-Blacklist"
local BLACKLIST_RADIUS = 5.0

-- State
local blacklist = {}

local currentUser = NULL_KEY
local currentUserAcl = -999
local policyButtons = {}
local sessionId = ""
local menuContext = ""

local candidateKeys = {}

-- Helpers

local function generateSessionId()
    return "blacklist_" .. tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime())
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

local function blacklistNames()
    local out = {}
    for _, k in blacklist do
        local nm = ll.GetDisplayName(k)
        if nm == "" then nm = k end
        table.insert(out, nm)
    end
    return out
end

-- Lifecycle

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["2"] = "+Blacklist,-Blacklist",
        ["3"] = "+Blacklist,-Blacklist",
        ["4"] = "+Blacklist,-Blacklist",
        ["5"] = "+Blacklist,-Blacklist"
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

local function parseBlacklistValue(raw)
    if not raw or raw == "[]" or raw == "" or raw == " " then
        blacklist = {}
        return
    end

    if string.sub(raw, 1, 1) == "[" then
        local parsed = lljson.decode(raw)
        if not parsed then
            blacklist = {}
            return
        end
        local updated = {}
        for _, val in parsed do
            if val ~= "" and not table.find(updated, val) then
                table.insert(updated, val)
            end
        end
        blacklist = updated
        return
    end

    local csv = string.split(raw, ",")
    local updated = {}
    for _, entry in csv do
        entry = string.gsub(entry, "^%s+", "")
        entry = string.gsub(entry, "%s+$", "")
        if entry ~= "" and not table.find(updated, entry) then
            table.insert(updated, entry)
        end
    end
    blacklist = updated
end

local function applyBlacklistPayload(kvData)
    if not kvData[KEY_BLACKLIST] then
        blacklist = {}
        return
    end
    parseBlacklistValue(kvData[KEY_BLACKLIST])
end

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end
    local kvData
    if type(data.kv) == "string" then
        kvData = lljson.decode(data.kv)
    else
        kvData = data.kv
    end
    if not kvData then return end
    applyBlacklistPayload(kvData)
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.op then return end

    if data.op == "set" then
        if not data.changes then return end
        local changes
        if type(data.changes) == "string" then
            changes = lljson.decode(data.changes)
        else
            changes = data.changes
        end
        if not changes then return end
        if changes[KEY_BLACKLIST] then
            parseBlacklistValue(changes[KEY_BLACKLIST])
        end
    elseif data.op == "list_add" then
        if not data.key or not data.elem then return end
        if data.key == KEY_BLACKLIST then
            if not table.find(blacklist, data.elem) then
                table.insert(blacklist, data.elem)
            end
        end
    elseif data.op == "list_remove" then
        if not data.key or not data.elem then return end
        if data.key == KEY_BLACKLIST then
            local idx = table.find(blacklist, data.elem)
            if idx then
                table.remove(blacklist, idx)
            end
        end
    end
end

local function persistBlacklist()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = KEY_BLACKLIST,
        values = blacklist
    }), NULL_KEY)
end

-- Forward declarations
local showMainMenu
local cleanupSession

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
    menuContext = ""
    candidateKeys = {}
end

-- Menu display

showMainMenu = function()
    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, currentUserAcl)

    local count = #blacklist
    local body = "Blacklist Management\n\nCurrently blacklisted: " .. tostring(count)

    local buttons = { BTN_BACK }
    if btnAllowed("+Blacklist") then table.insert(buttons, BTN_ADD) end
    if btnAllowed("-Blacklist") then table.insert(buttons, BTN_REMOVE) end

    sessionId = generateSessionId()
    menuContext = "main"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Blacklist",
        body = body,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

local function showRemoveMenu()
    if #blacklist == 0 then
        ll.RegionSayTo(currentUser, 0, "Blacklist is empty.")
        showMainMenu()
        return
    end

    local names = blacklistNames()

    sessionId = generateSessionId()
    menuContext = "remove"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        dialog_type = "numbered_list",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Remove from Blacklist",
        prompt = "Select avatar to remove:",
        items = names,
        timeout = 60
    }), NULL_KEY)
end

local function showAddCandidates()
    if #candidateKeys == 0 then
        ll.RegionSayTo(currentUser, 0, "No nearby avatars found.")
        showMainMenu()
        return
    end

    local names = {}
    local i = 1
    while i <= #candidateKeys and i <= MAX_NUMBERED_LIST_ITEMS do
        local k = candidateKeys[i]
        local name = ll.GetDisplayName(k)
        if name == "" then name = k end
        table.insert(names, name)
        i = i + 1
    end

    sessionId = generateSessionId()
    menuContext = "add_pick"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        dialog_type = "numbered_list",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Add to Blacklist",
        prompt = "Select avatar to blacklist:",
        items = names,
        timeout = 60
    }), NULL_KEY)
end

-- Dialog handlers

local function handleDialogResponse(msg)
    local data = lljson.decode(msg)
    if not data or not data.session_id or not data.button then return end
    if data.session_id ~= sessionId then return end

    local button = data.button

    if button == BTN_BACK then
        if menuContext == "main" then
            returnToRoot()
            return
        end
        showMainMenu()
        return
    end

    if menuContext == "main" then
        if button == BTN_ADD then
            menuContext = "add_scan"
            candidateKeys = {}
            ll.Sensor("", NULL_KEY, AGENT, BLACKLIST_RADIUS, PI)
            return
        end
        if button == BTN_REMOVE then
            showRemoveMenu()
            return
        end
    end

    if menuContext == "remove" then
        local idx = tonumber(button)
        if idx and idx >= 1 and idx <= #blacklist then
            table.remove(blacklist, idx)
            persistBlacklist()
            ll.RegionSayTo(currentUser, 0, "Removed from blacklist.")
        end
        showMainMenu()
        return
    end

    if menuContext == "add_pick" then
        local idx = tonumber(button)
        if idx and idx >= 1 and idx <= #candidateKeys then
            local entry = candidateKeys[idx]
            if entry ~= "" and not table.find(blacklist, entry) then
                table.insert(blacklist, entry)
                persistBlacklist()
                ll.RegionSayTo(currentUser, 0, "Added to blacklist.")
            end
        end
        showMainMenu()
        return
    end

    showMainMenu()
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
    local msgType = getMsgType(msg)
    if msgType == "" then return end

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
        return
    end

    -- Settings bus
    if num == SETTINGS_BUS then
        if msgType == "settings_sync" then
            applySettingsSync(msg)
            return
        end
        if msgType == "settings_delta" then
            applySettingsDelta(msg)
            return
        end
        return
    end

    -- UI bus
    if num == UI_BUS then
        if msgType == "start" then
            local data = lljson.decode(msg)
            if not data or not data.context then return end
            if data.context ~= PLUGIN_CONTEXT then return end
            currentUser = id
            currentUserAcl = tonumber(data.acl) or -999
            showMainMenu()
            return
        end
        return
    end

    -- Dialog bus
    if num == DIALOG_BUS then
        if msgType == "dialog_response" then
            handleDialogResponse(msg)
            return
        end
        if msgType == "dialog_timeout" then
            handleDialogTimeout(msg)
            return
        end
        return
    end
end)

LLEvents:on("sensor", function(events)
    if not currentUser.istruthy then return end
    if menuContext ~= "add_scan" then return end

    local candidates = {}
    local owner = ll.GetOwner()

    for _, det in events do
        local k = det.Key
        local entry = tostring(k)
        if k ~= owner and not table.find(blacklist, entry) then
            table.insert(candidates, entry)
        end
    end

    candidateKeys = candidates
    showAddCandidates()
end)

LLEvents:on("no_sensor", function()
    if not currentUser.istruthy then return end
    if menuContext ~= "add_scan" then return end

    candidateKeys = {}
    showAddCandidates()
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
