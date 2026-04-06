--[[--------------------
PLUGIN: plugin_lock.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Toggle collar lock and RLV detach control labels
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
local PLUGIN_CONTEXT = "core_lock"
local PLUGIN_LABEL_LOCKED = "Locked: Y"
local PLUGIN_LABEL_UNLOCKED = "Locked: N"

-- Settings keys
local KEY_LOCKED = "lock.locked"

-- Sound
local SOUND_TOGGLE = "3aacf116-f060-b4c8-bb58-07aefc0af33a"
local SOUND_VOLUME = 1.0

-- Visual prim names (optional)
local PRIM_LOCKED = "locked"
local PRIM_UNLOCKED = "unlocked"

-- State
local locked = false
local policyButtons = {}

-- Helpers

local function lsdInt(lsdKey, fallback)
    local v = ll.LinksetDataRead(lsdKey)
    if v == "" then return fallback end
    return tonumber(v) or fallback
end

local function playToggleSound()
    ll.TriggerSound(SOUND_TOGGLE, SOUND_VOLUME)
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

-- Visual feedback (optional prims)

local function showLockedPrim()
    local linkCount = ll.GetNumberOfPrims()
    for i = 1, linkCount do
        local name = ll.GetLinkName(i)
        if name == PRIM_LOCKED then
            ll.SetLinkAlpha(i, 1.0, ALL_SIDES)
        elseif name == PRIM_UNLOCKED then
            ll.SetLinkAlpha(i, 0.0, ALL_SIDES)
        end
    end
end

local function showUnlockedPrim()
    local linkCount = ll.GetNumberOfPrims()
    for i = 1, linkCount do
        local name = ll.GetLinkName(i)
        if name == PRIM_LOCKED then
            ll.SetLinkAlpha(i, 0.0, ALL_SIDES)
        elseif name == PRIM_UNLOCKED then
            ll.SetLinkAlpha(i, 1.0, ALL_SIDES)
        end
    end
end

-- Lock state application

local function applyLockState()
    if locked then
        ll.OwnerSay("@detach=n")
        showLockedPrim()
    else
        ll.OwnerSay("@detach=y")
        showUnlockedPrim()
    end
end

-- Lifecycle management

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["4"] = "toggle",
        ["5"] = "toggle"
    }))

    local currentLabel = PLUGIN_LABEL_UNLOCKED
    if locked then
        currentLabel = PLUGIN_LABEL_LOCKED
    end

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, lljson.encode({
        type = "register",
        context = PLUGIN_CONTEXT,
        label = currentLabel,
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

local function persistLocked(newValue)
    ll.LinksetDataWrite(KEY_LOCKED, tostring(newValue))

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = KEY_LOCKED,
        value = tostring(newValue)
    }), NULL_KEY)
end

-- UI label update

local function updateUiLabelAndReturn(user)
    local newLabel = PLUGIN_LABEL_UNLOCKED
    if locked then
        newLabel = PLUGIN_LABEL_LOCKED
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

    local lsdVal = ll.LinksetDataRead(KEY_LOCKED)
    if lsdVal ~= "" then
        locked = (tonumber(lsdVal) or 0) ~= 0
        applyLockState()
    else
        locked = false
        if kvData[KEY_LOCKED] ~= nil then
            locked = (tonumber(kvData[KEY_LOCKED]) or 0) ~= 0
        end
        applyLockState()
        ll.LinksetDataWrite(KEY_LOCKED, locked and "1" or "0")
    end
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.op then return end

    if data.op == "set" then
        local changes = data.changes
        if not changes then return end

        if changes[KEY_LOCKED] ~= nil then
            local oldLocked = locked
            locked = (tonumber(changes[KEY_LOCKED]) or 0) ~= 0
            ll.LinksetDataWrite(KEY_LOCKED, locked and "1" or "0")

            if oldLocked ~= locked then
                applyLockState()
                local newLabel = PLUGIN_LABEL_UNLOCKED
                if locked then
                    newLabel = PLUGIN_LABEL_LOCKED
                end
                ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
                    type = "update_label",
                    context = PLUGIN_CONTEXT,
                    label = newLabel
                }), NULL_KEY)
            end
        end
    elseif data.op == "delete" then
        local deletedKey = data.key
        if not deletedKey then return end

        if deletedKey == KEY_LOCKED then
            if locked then
                locked = false
                ll.LinksetDataWrite(KEY_LOCKED, "0")
                applyLockState()
                ll.OwnerSay("Lock setting deleted - reverting to unlocked state")

                ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
                    type = "update_label",
                    context = PLUGIN_CONTEXT,
                    label = PLUGIN_LABEL_UNLOCKED
                }), NULL_KEY)
            end
        end
    end
end

-- Direct toggle action

local function toggleLock(user, aclLevel)
    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, aclLevel)
    if not btnAllowed("toggle") then
        ll.RegionSayTo(user, 0, "Access denied.")
        policyButtons = {}
        return
    end
    policyButtons = {}

    locked = not locked

    playToggleSound()
    applyLockState()
    persistLocked(locked and 1 or 0)

    if locked then
        ll.RegionSayTo(user, 0, "Collar locked.")
    else
        ll.RegionSayTo(user, 0, "Collar unlocked.")
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
            ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
                type = "settings_get"
            }), NULL_KEY)
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
            registerSelf()
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
            toggleLock(id, acl)
            return
        end

        return
    end
end)

-- Init (replaces state_entry)
policyButtons = {}
local lsdVal = ll.LinksetDataRead(KEY_LOCKED)
if lsdVal ~= "" then
    locked = (tonumber(lsdVal) or 0) ~= 0
    applyLockState()
end

ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
    type = "settings_get"
}), NULL_KEY)
