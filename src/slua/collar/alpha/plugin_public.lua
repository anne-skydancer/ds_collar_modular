--[[--------------------
PLUGIN: plugin_public.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Toggle public access mode directly from main menu
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.1 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based policy lookup replaces stride lists.
  LLEvents replaces state/event blocks.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900

-- Plugin identity
local PLUGIN_CONTEXT = "core_public"
local PLUGIN_LABEL_ON = "Public: Y"
local PLUGIN_LABEL_OFF = "Public: N"

-- Settings keys
local KEY_PUBLIC_MODE = "public.mode"

-- State
local publicModeEnabled = false
local policyButtons = {}

-- Helpers

local function lsdInt(lsdKey, fallback)
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

-- Lifecycle management

local function registerSelf()
    local label = PLUGIN_LABEL_OFF
    if publicModeEnabled then
        label = PLUGIN_LABEL_ON
    end

    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["3"] = "toggle",
        ["4"] = "toggle",
        ["5"] = "toggle"
    }))

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, lljson.encode({
        type = "register",
        context = PLUGIN_CONTEXT,
        label = label,
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

local function persistPublicMode(newValue)
    if newValue ~= 0 then newValue = 1 end

    ll.LinksetDataWrite(KEY_PUBLIC_MODE, tostring(newValue))

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = KEY_PUBLIC_MODE,
        value = tostring(newValue)
    }), NULL_KEY)
end

-- UI label update

local function updateUiLabelAndReturn(user)
    local newLabel = PLUGIN_LABEL_OFF
    if publicModeEnabled then
        newLabel = PLUGIN_LABEL_ON
    end

    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "update_label",
        context = PLUGIN_CONTEXT,
        label = newLabel
    }), NULL_KEY)

    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "return",
        user = tostring(user)
    }), NULL_KEY)
end

-- Settings consumption

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end
    local kvData = data.kv

    local lsdVal = ll.LinksetDataRead(KEY_PUBLIC_MODE)
    if lsdVal ~= "" then
        local oldState = publicModeEnabled
        publicModeEnabled = (tonumber(lsdVal) or 0) ~= 0
        if oldState ~= publicModeEnabled then
            registerSelf()
        end
    else
        local oldState = publicModeEnabled
        if kvData[KEY_PUBLIC_MODE] ~= nil then
            publicModeEnabled = (tonumber(kvData[KEY_PUBLIC_MODE]) or 0) ~= 0
        end
        ll.LinksetDataWrite(KEY_PUBLIC_MODE, publicModeEnabled and "1" or "0")
        if oldState ~= publicModeEnabled then
            registerSelf()
        end
    end
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.op then return end

    if data.op == "set" then
        local changes = data.changes
        if not changes then return end

        if changes[KEY_PUBLIC_MODE] ~= nil then
            local oldState = publicModeEnabled
            publicModeEnabled = (tonumber(changes[KEY_PUBLIC_MODE]) or 0) ~= 0
            ll.LinksetDataWrite(KEY_PUBLIC_MODE, tostring(changes[KEY_PUBLIC_MODE]))

            if oldState ~= publicModeEnabled then
                registerSelf()
            end
        end
    end
end

-- Direct toggle action

local function togglePublicAccess(user, aclLevel)
    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, aclLevel)
    if not btnAllowed("toggle") then
        ll.RegionSayTo(user, 0, "Access denied.")
        policyButtons = {}
        return
    end
    policyButtons = {}

    publicModeEnabled = not publicModeEnabled

    persistPublicMode(publicModeEnabled and 1 or 0)

    if publicModeEnabled then
        ll.RegionSayTo(user, 0, "Public access enabled.")
    else
        ll.RegionSayTo(user, 0, "Public access disabled.")
    end

    updateUiLabelAndReturn(user)
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
            if not id.istruthy then return end

            local acl = tonumber(data.acl) or 0
            togglePublicAccess(id, acl)
            return
        end

        return
    end
end)

-- Init (replaces state_entry)
publicModeEnabled = lsdInt(KEY_PUBLIC_MODE, 0) ~= 0
policyButtons = {}

registerSelf()

ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
    type = "settings_get"
}), NULL_KEY)
