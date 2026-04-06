--[[--------------------
PLUGIN: plugin_rlvex.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Manage RLV teleport and IM exceptions for owners and trustees
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based owner/trustee tracking replaces parallel lists.
  LLTimers replaces single-timer for reconcile delay.
  lljson.decode replaces llJsonGetValue chains.
--------------------]]

-- ABI channels
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

-- Identity
local PLUGIN_CONTEXT = "core_rlv_exceptions"
local PLUGIN_LABEL = "Exceptions"

-- Settings keys
local KEY_EX_OWNER_TP = "rlvex.ownertp"
local KEY_EX_OWNER_IM = "rlvex.ownerim"
local KEY_EX_TRUSTEE_TP = "rlvex.trusteetp"
local KEY_EX_TRUSTEE_IM = "rlvex.trusteeim"
local KEY_OWNER = "access.owner"
local KEY_OWNERS = "access.owners"
local KEY_TRUSTEES = "access.trustees"
local KEY_MULTI_OWNER_MODE = "access.multiowner"

-- State
local exOwnerTp = true
local exOwnerIm = true
local exTrusteeTp = false
local exTrusteeIm = false

local ownerKey = NULL_KEY
local ownerKeys = {}
local trusteeKeys = {}
local multiOwnerMode = false

local currentUser = NULL_KEY
local userAcl = -999
local policyButtons = {}
local sessionId = ""
local menuContext = ""

local pendingReconcile = false
local reconcileTimer = nil

-- Helpers

local function lsdInt(lsdKey, fallback)
    local v = ll.LinksetDataRead(lsdKey)
    if v == "" then return fallback end
    return tonumber(v) or fallback
end

local function genSession()
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

-- RLV commands

local function applyTpException(k, allow)
    if k == NULL_KEY then return end
    local sk = tostring(k)
    local op = "=add"
    if not allow then op = "=rem" end
    ll.OwnerSay("@accepttp:" .. sk .. op .. ",tplure:" .. sk .. op)
end

local function applyImException(k, allow)
    if k == NULL_KEY then return end
    local sk = tostring(k)
    local op = "=add"
    if not allow then op = "=rem" end
    ll.OwnerSay("@sendim:" .. sk .. op .. ",recvim:" .. sk .. op)
end

local function reconcileAll()
    local hasOwners = (multiOwnerMode and #ownerKeys > 0) or (not multiOwnerMode and ownerKey ~= NULL_KEY)
    local hasTrustees = #trusteeKeys > 0

    if not hasOwners and not hasTrustees then return end

    -- Owner exceptions
    if multiOwnerMode then
        for _, k in ownerKeys do
            applyTpException(k, exOwnerTp)
            applyImException(k, exOwnerIm)
        end
    else
        applyTpException(ownerKey, exOwnerTp)
        applyImException(ownerKey, exOwnerIm)
    end

    -- Trustee exceptions
    for _, k in trusteeKeys do
        applyTpException(k, exTrusteeTp)
        applyImException(k, exTrusteeIm)
    end
end

-- Lifecycle

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["3"] = "Owner,Trustee,TP,IM",
        ["4"] = "Owner,Trustee,TP,IM",
        ["5"] = "Owner,Trustee,TP,IM"
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

local function persistSetting(settingKey, value)
    local strVal = value and "1" or "0"
    if type(value) == "number" then strVal = tostring(value) end
    ll.LinksetDataWrite(settingKey, strVal)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = settingKey,
        value = strVal
    }), NULL_KEY)
end

-- Parse owner/trustee keys from a JSON object (key-value pairs where keys are UUIDs)
local function parseKeysFromObject(obj)
    local result = {}
    if type(obj) == "table" then
        for k, _ in obj do
            result[#result + 1] = k
        end
    end
    return result
end

-- Settings sync

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end
    local kv = data.kv

    ownerKey = NULL_KEY
    ownerKeys = {}
    trusteeKeys = {}
    multiOwnerMode = false

    -- Exception settings: restore from LSD if present, else seed from notecard
    local hasOwnerTp = false
    if ll.LinksetDataRead(KEY_EX_OWNER_TP) ~= "" then
        exOwnerTp = lsdInt(KEY_EX_OWNER_TP, 1) ~= 0
        hasOwnerTp = true
    elseif kv[KEY_EX_OWNER_TP] ~= nil then
        exOwnerTp = (tonumber(kv[KEY_EX_OWNER_TP]) or 0) ~= 0
        ll.LinksetDataWrite(KEY_EX_OWNER_TP, tostring(exOwnerTp and 1 or 0))
        hasOwnerTp = true
    else
        exOwnerTp = true
    end

    local hasOwnerIm = false
    if ll.LinksetDataRead(KEY_EX_OWNER_IM) ~= "" then
        exOwnerIm = lsdInt(KEY_EX_OWNER_IM, 1) ~= 0
        hasOwnerIm = true
    elseif kv[KEY_EX_OWNER_IM] ~= nil then
        exOwnerIm = (tonumber(kv[KEY_EX_OWNER_IM]) or 0) ~= 0
        ll.LinksetDataWrite(KEY_EX_OWNER_IM, tostring(exOwnerIm and 1 or 0))
        hasOwnerIm = true
    else
        exOwnerIm = true
    end

    if ll.LinksetDataRead(KEY_EX_TRUSTEE_TP) ~= "" then
        exTrusteeTp = lsdInt(KEY_EX_TRUSTEE_TP, 0) ~= 0
    else
        local tmp = kv[KEY_EX_TRUSTEE_TP]
        if tmp ~= nil then
            exTrusteeTp = (tonumber(tmp) or 0) ~= 0
            ll.LinksetDataWrite(KEY_EX_TRUSTEE_TP, tostring(exTrusteeTp and 1 or 0))
        else
            exTrusteeTp = false
        end
    end

    if ll.LinksetDataRead(KEY_EX_TRUSTEE_IM) ~= "" then
        exTrusteeIm = lsdInt(KEY_EX_TRUSTEE_IM, 0) ~= 0
    else
        local tmp = kv[KEY_EX_TRUSTEE_IM]
        if tmp ~= nil then
            exTrusteeIm = (tonumber(tmp) or 0) ~= 0
            ll.LinksetDataWrite(KEY_EX_TRUSTEE_IM, tostring(exTrusteeIm and 1 or 0))
        else
            exTrusteeIm = false
        end
    end

    -- Load owner/trustee lists
    local tmp = kv[KEY_MULTI_OWNER_MODE]
    if tmp ~= nil then
        multiOwnerMode = (tonumber(tmp) or 0) ~= 0
    end

    if multiOwnerMode then
        local obj = kv[KEY_OWNERS]
        if obj ~= nil and type(obj) == "table" then
            ownerKeys = parseKeysFromObject(obj)
        end
    else
        local obj = kv[KEY_OWNER]
        if obj ~= nil and type(obj) == "table" then
            for k, _ in obj do
                ownerKey = k
                break -- single owner: take first key
            end
        end
    end

    local trusteesRaw = kv[KEY_TRUSTEES]
    if trusteesRaw ~= nil then
        if type(trusteesRaw) == "table" then
            -- Could be object or array
            local isArray = (#trusteesRaw > 0)
            if isArray then
                trusteeKeys = trusteesRaw
            else
                trusteeKeys = parseKeysFromObject(trusteesRaw)
            end
        end
    end

    -- Auto-initialize settings if owners exist but settings don't
    local ownersExist = (multiOwnerMode and #ownerKeys > 0) or (not multiOwnerMode and ownerKey ~= NULL_KEY)

    if ownersExist then
        if not hasOwnerTp then persistSetting(KEY_EX_OWNER_TP, true) end
        if not hasOwnerIm then persistSetting(KEY_EX_OWNER_IM, true) end
    end

    -- Apply RLV commands after short delay to ensure RLV viewer is ready
    pendingReconcile = true
    if reconcileTimer then LLTimers:off(reconcileTimer) end
    reconcileTimer = LLTimers:once(1.0, function()
        reconcileTimer = nil
        if pendingReconcile then
            pendingReconcile = false
            reconcileAll()
        end
    end)
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.op then return end

    if data.op == "set" then
        local changes = data.changes
        if not changes then return end

        if changes[KEY_EX_OWNER_TP] ~= nil then
            local val = (tonumber(changes[KEY_EX_OWNER_TP]) or 0) ~= 0
            ll.LinksetDataWrite(KEY_EX_OWNER_TP, val and "1" or "0")
            if val ~= exOwnerTp then exOwnerTp = val; reconcileAll() end
        end
        if changes[KEY_EX_OWNER_IM] ~= nil then
            local val = (tonumber(changes[KEY_EX_OWNER_IM]) or 0) ~= 0
            ll.LinksetDataWrite(KEY_EX_OWNER_IM, val and "1" or "0")
            if val ~= exOwnerIm then exOwnerIm = val; reconcileAll() end
        end
        if changes[KEY_EX_TRUSTEE_TP] ~= nil then
            local val = (tonumber(changes[KEY_EX_TRUSTEE_TP]) or 0) ~= 0
            ll.LinksetDataWrite(KEY_EX_TRUSTEE_TP, val and "1" or "0")
            if val ~= exTrusteeTp then exTrusteeTp = val; reconcileAll() end
        end
        if changes[KEY_EX_TRUSTEE_IM] ~= nil then
            local val = (tonumber(changes[KEY_EX_TRUSTEE_IM]) or 0) ~= 0
            ll.LinksetDataWrite(KEY_EX_TRUSTEE_IM, val and "1" or "0")
            if val ~= exTrusteeIm then exTrusteeIm = val; reconcileAll() end
        end

        -- Handle multi_owner_mode changes
        if changes[KEY_MULTI_OWNER_MODE] ~= nil then
            multiOwnerMode = (tonumber(changes[KEY_MULTI_OWNER_MODE]) or 0) ~= 0
            reconcileAll()
        end

        -- Single owner changed
        if changes[KEY_OWNER] ~= nil then
            local oldOwner = ownerKey
            ownerKey = NULL_KEY
            local obj = changes[KEY_OWNER]
            if type(obj) == "table" then
                for k, _ in obj do
                    ownerKey = k
                    break
                end
            end

            if oldOwner ~= NULL_KEY and oldOwner ~= ownerKey then
                applyTpException(oldOwner, false)
                applyImException(oldOwner, false)
            end

            reconcileAll()
        end

        -- Multi-owner changed
        if changes[KEY_OWNERS] ~= nil then
            -- Clear exceptions for old owners
            for _, oldK in ownerKeys do
                applyTpException(oldK, false)
                applyImException(oldK, false)
            end

            ownerKeys = {}
            local obj = changes[KEY_OWNERS]
            if type(obj) == "table" then
                ownerKeys = parseKeysFromObject(obj)
            end

            reconcileAll()
        end

        -- Trustees changed
        if changes[KEY_TRUSTEES] ~= nil then
            -- Clear exceptions for old trustees
            for _, oldK in trusteeKeys do
                applyTpException(oldK, false)
                applyImException(oldK, false)
            end

            trusteeKeys = {}
            local trusteesRaw = changes[KEY_TRUSTEES]
            if type(trusteesRaw) == "table" then
                local isArray = (#trusteesRaw > 0)
                if isArray then
                    trusteeKeys = trusteesRaw
                else
                    trusteeKeys = parseKeysFromObject(trusteesRaw)
                end
            end

            reconcileAll()
        end
    end
end

-- Cleanup

local function cleanup()
    if sessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
            type = "dialog_close",
            session_id = sessionId
        }), NULL_KEY)
    end
    if reconcileTimer then
        LLTimers:off(reconcileTimer)
        reconcileTimer = nil
    end
    pendingReconcile = false
    currentUser = NULL_KEY
    userAcl = -999
    policyButtons = {}
    sessionId = ""
    menuContext = ""
end

-- Menus

local showMain, showOwnerMenu, showTrusteeMenu, showToggle, handleButton

showMain = function()
    sessionId = genSession()
    menuContext = "main"

    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, userAcl)

    local body = "RLV Exceptions\n\nManage which restrictions can be bypassed by owners and trustees."

    local buttons = {"Back"}
    if btnAllowed("Owner") then buttons[#buttons + 1] = "Owner" end
    if btnAllowed("Trustee") then buttons[#buttons + 1] = "Trustee" end

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

showOwnerMenu = function()
    sessionId = genSession()
    menuContext = "owner"

    local body = "Owner Exceptions\n\nCurrent settings:\n"
    if exOwnerTp then body = body .. "TP: Allowed\n"
    else body = body .. "TP: Denied\n" end
    if exOwnerIm then body = body .. "IM: Allowed"
    else body = body .. "IM: Denied" end

    local buttons = {"Back"}
    if btnAllowed("TP") then buttons[#buttons + 1] = "TP" end
    if btnAllowed("IM") then buttons[#buttons + 1] = "IM" end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Owner Exceptions",
        body = body,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

showTrusteeMenu = function()
    sessionId = genSession()
    menuContext = "trustee"

    local body = "Trustee Exceptions\n\nCurrent settings:\n"
    if exTrusteeTp then body = body .. "TP: Allowed\n"
    else body = body .. "TP: Denied\n" end
    if exTrusteeIm then body = body .. "IM: Allowed"
    else body = body .. "IM: Denied" end

    local buttons = {"Back"}
    if btnAllowed("TP") then buttons[#buttons + 1] = "TP" end
    if btnAllowed("IM") then buttons[#buttons + 1] = "IM" end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Trustee Exceptions",
        body = body,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

showToggle = function(role, exceptionType, current)
    sessionId = genSession()
    menuContext = role .. "_" .. exceptionType

    local body = role .. " " .. exceptionType .. " Exception\n\n"
    if current then body = body .. "Current: Allowed\n\n"
    else body = body .. "Current: Denied\n\n" end
    body = body .. "Allow = Owner/trustee can bypass restrictions\n"
    body = body .. "Deny = Normal restrictions apply"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = role .. " " .. exceptionType,
        body = body,
        buttons = {"Back", "Allow", "Deny"},
        timeout = 60
    }), NULL_KEY)
end

-- Button handling

handleButton = function(btn)
    if btn == "Back" then
        if menuContext == "main" then
            ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
                type = "return",
                user = tostring(currentUser)
            }), NULL_KEY)
            cleanup()
        elseif menuContext == "owner" or menuContext == "trustee" then
            showMain()
        else
            if string.find(menuContext, "^Owner") then showOwnerMenu()
            elseif string.find(menuContext, "^Trustee") then showTrusteeMenu()
            else showMain() end
        end
        return
    end

    if menuContext == "main" then
        if btn == "Owner" then showOwnerMenu()
        elseif btn == "Trustee" then showTrusteeMenu() end
    elseif menuContext == "owner" then
        if btn == "TP" then showToggle("Owner", "TP", exOwnerTp)
        elseif btn == "IM" then showToggle("Owner", "IM", exOwnerIm) end
    elseif menuContext == "trustee" then
        if btn == "TP" then showToggle("Trustee", "TP", exTrusteeTp)
        elseif btn == "IM" then showToggle("Trustee", "IM", exTrusteeIm) end
    elseif menuContext == "Owner_TP" then
        if btn == "Allow" then
            exOwnerTp = true
            persistSetting(KEY_EX_OWNER_TP, true)
            reconcileAll()
            ll.RegionSayTo(currentUser, 0, "Owner TP exception allowed.")
        elseif btn == "Deny" then
            exOwnerTp = false
            persistSetting(KEY_EX_OWNER_TP, false)
            reconcileAll()
            ll.RegionSayTo(currentUser, 0, "Owner TP exception denied.")
        end
        showOwnerMenu()
    elseif menuContext == "Owner_IM" then
        if btn == "Allow" then
            exOwnerIm = true
            persistSetting(KEY_EX_OWNER_IM, true)
            reconcileAll()
            ll.RegionSayTo(currentUser, 0, "Owner IM exception allowed.")
        elseif btn == "Deny" then
            exOwnerIm = false
            persistSetting(KEY_EX_OWNER_IM, false)
            reconcileAll()
            ll.RegionSayTo(currentUser, 0, "Owner IM exception denied.")
        end
        showOwnerMenu()
    elseif menuContext == "Trustee_TP" then
        if btn == "Allow" then
            exTrusteeTp = true
            persistSetting(KEY_EX_TRUSTEE_TP, true)
            reconcileAll()
            ll.RegionSayTo(currentUser, 0, "Trustee TP exception allowed.")
        elseif btn == "Deny" then
            exTrusteeTp = false
            persistSetting(KEY_EX_TRUSTEE_TP, false)
            reconcileAll()
            ll.RegionSayTo(currentUser, 0, "Trustee TP exception denied.")
        end
        showTrusteeMenu()
    elseif menuContext == "Trustee_IM" then
        if btn == "Allow" then
            exTrusteeIm = true
            persistSetting(KEY_EX_TRUSTEE_IM, true)
            reconcileAll()
            ll.RegionSayTo(currentUser, 0, "Trustee IM exception allowed.")
        elseif btn == "Deny" then
            exTrusteeIm = false
            persistSetting(KEY_EX_TRUSTEE_IM, false)
            reconcileAll()
            ll.RegionSayTo(currentUser, 0, "Trustee IM exception denied.")
        end
        showTrusteeMenu()
    end
end

-- Events

LLEvents:on("on_rez", function(p)
    ll.ResetScript()
end)

LLEvents:on("changed", function(c)
    if bit32.btest(c, CHANGED_OWNER) then
        ll.ResetScript()
    end
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
        elseif msgType == "soft_reset" or msgType == "soft_reset_all" then
            pendingReconcile = true
            if reconcileTimer then LLTimers:off(reconcileTimer) end
            reconcileTimer = LLTimers:once(1.0, function()
                reconcileTimer = nil
                if pendingReconcile then
                    pendingReconcile = false
                    reconcileAll()
                end
            end)
        end
    elseif num == SETTINGS_BUS then
        if msgType == "settings_sync" then
            applySettingsSync(msg)
        elseif msgType == "settings_delta" then
            applySettingsDelta(msg)
        end
    elseif num == UI_BUS then
        if msgType == "start" and data.context then
            if data.context == PLUGIN_CONTEXT then
                currentUser = id
                userAcl = tonumber(data.acl) or 0
                showMain()
            end
        end
    elseif num == DIALOG_BUS then
        if msgType == "dialog_response" then
            if data.session_id and data.button then
                if data.session_id == sessionId then
                    handleButton(data.button)
                end
            end
        elseif msgType == "dialog_timeout" then
            if data.session_id then
                if data.session_id == sessionId then cleanup() end
            end
        end
    end
end)

-- Init

local function init()
    cleanup()
    registerSelf()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "settings_get"
    }), NULL_KEY)
end

init()
