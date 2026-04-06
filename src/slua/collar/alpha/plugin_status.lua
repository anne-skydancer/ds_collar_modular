--[[--------------------
PLUGIN: plugin_status.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Read-only collar status display for owners and observers
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.10 rev 0: SLua alpha port from LSL 1.10
  Table-based settings and name caches replace stride lists.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

-- Plugin identity
local PLUGIN_CONTEXT = "core_status"
local PLUGIN_LABEL = "Status"

-- Settings keys
local KEY_MULTI_OWNER_MODE = "access.multiowner"
local KEY_OWNER = "access.owner"
local KEY_OWNERS = "access.owners"
local KEY_TRUSTEES = "access.trustees"
local KEY_BLACKLIST = "access.blacklist"
local KEY_PUBLIC_ACCESS = "public.mode"
local KEY_LOCKED = "lock.locked"
local KEY_TPE_MODE = "tpe.mode"

-- Settings cache
local multiOwnerMode = false
local ownerKey = NULL_KEY
local ownerKeys = {}
local ownerHonorific = ""
local ownersJson = "{}"
local trusteeKeys = {}
local trusteesJson = "{}"
local blacklistKeys = {}
local publicAccess = false
local locked = false
local tpeMode = false

-- Display name resolution
local ownerDisplay = ""
local ownerDisplayQuery = NULL_KEY
local ownerLegacyQuery = NULL_KEY

-- Multi-owner display names
local ownerDisplayNames = {}
local ownerNameQueries = {}

-- Trustee display names
local trusteeDisplayNames = {}
local trusteeNameQueries = {}

-- Session management
local currentUser = NULL_KEY
local policyButtons = {}
local sessionId = ""

-- Helpers

local function isJsonArr(s)
    return string.sub(s, 1, 1) == "["
end

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

-- Lifecycle management

local function requestSettingsSync()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "settings_get"
    }), NULL_KEY)
end

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["1"] = "",
        ["2"] = "",
        ["3"] = "",
        ["4"] = "",
        ["5"] = ""
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

-- Session cleanup

local function cleanupSession()
    if sessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
            type = "dialog_close",
            session_id = sessionId
        }), NULL_KEY)
    end
    currentUser = NULL_KEY
    policyButtons = {}
    sessionId = ""
end

-- Owner name resolution (forward declarations)
local requestOwnerNames
local requestTrusteeNames

-- Settings consumption

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end
    local kv = data.kv
    if type(kv) == "string" then
        kv = lljson.decode(kv)
        if not kv then return end
    end

    local previousMode = multiOwnerMode
    local previousOwner = ownerKey
    local previousOwners = ownerKeys

    -- Reset to defaults
    multiOwnerMode = false
    ownerKey = NULL_KEY
    ownerKeys = {}
    ownerHonorific = ""
    ownersJson = "{}"
    trusteeKeys = {}
    trusteesJson = "{}"
    blacklistKeys = {}
    publicAccess = false
    locked = false
    tpeMode = false

    -- Load values
    if kv[KEY_MULTI_OWNER_MODE] ~= nil then
        multiOwnerMode = tonumber(kv[KEY_MULTI_OWNER_MODE]) ~= 0
    end

    -- Single owner: JSON object {uuid:honorific}
    local ownerObj = kv[KEY_OWNER]
    if ownerObj ~= nil then
        if type(ownerObj) == "table" then
            for k, v in pairs(ownerObj) do
                ownerKey = k
                ownerHonorific = v
            end
        elseif type(ownerObj) == "string" then
            local parsed = lljson.decode(ownerObj)
            if parsed and type(parsed) == "table" then
                for k, v in pairs(parsed) do
                    ownerKey = k
                    ownerHonorific = v
                end
            end
        end
    end

    -- Multi-owner: JSON object {uuid:honorific, ...}
    local ownersObj = kv[KEY_OWNERS]
    if ownersObj ~= nil then
        local parsed = ownersObj
        if type(parsed) == "string" then
            parsed = lljson.decode(parsed)
        end
        if parsed and type(parsed) == "table" then
            ownersJson = type(ownersObj) == "string" and ownersObj or lljson.encode(ownersObj)
            ownerKeys = {}
            for k, _ in pairs(parsed) do
                table.insert(ownerKeys, k)
            end
        end
    end

    -- Trustees
    local trusteesRaw = kv[KEY_TRUSTEES]
    if trusteesRaw ~= nil then
        local parsed = trusteesRaw
        if type(parsed) == "string" then
            parsed = lljson.decode(parsed)
        end
        if parsed and type(parsed) == "table" then
            trusteeKeys = {}
            -- Check if it is an array or object
            if #parsed > 0 then
                -- Array form
                trusteeKeys = parsed
            else
                -- Object form {uuid:honorific}
                trusteesJson = type(trusteesRaw) == "string" and trusteesRaw or lljson.encode(trusteesRaw)
                for k, _ in pairs(parsed) do
                    table.insert(trusteeKeys, k)
                end
            end
        end
    end

    -- Blacklist
    local blacklistRaw = kv[KEY_BLACKLIST]
    if blacklistRaw ~= nil then
        local parsed = blacklistRaw
        if type(parsed) == "string" then
            parsed = lljson.decode(parsed)
        end
        if parsed and type(parsed) == "table" and #parsed > 0 then
            blacklistKeys = parsed
        end
    end

    -- Read lock/tpe/public from LSD (authoritative), fall back to kv
    local lsdLocked = ll.LinksetDataRead(KEY_LOCKED)
    if lsdLocked ~= "" then
        locked = tonumber(lsdLocked) ~= 0
    elseif kv[KEY_LOCKED] ~= nil then
        locked = tonumber(kv[KEY_LOCKED]) ~= 0
    end

    local lsdTpe = ll.LinksetDataRead(KEY_TPE_MODE)
    if lsdTpe ~= "" then
        tpeMode = tonumber(lsdTpe) ~= 0
    elseif kv[KEY_TPE_MODE] ~= nil then
        tpeMode = tonumber(kv[KEY_TPE_MODE]) ~= 0
    end

    local lsdPublic = ll.LinksetDataRead(KEY_PUBLIC_ACCESS)
    if lsdPublic ~= "" then
        publicAccess = tonumber(lsdPublic) ~= 0
    elseif kv[KEY_PUBLIC_ACCESS] ~= nil then
        publicAccess = tonumber(kv[KEY_PUBLIC_ACCESS]) ~= 0
    end

    -- Check if we need to refresh owner names
    local needsRefresh = false

    if multiOwnerMode ~= previousMode then
        needsRefresh = true
    elseif multiOwnerMode then
        -- Compare owner key lists
        if #ownerKeys ~= #previousOwners then
            needsRefresh = true
        else
            for i, k in ownerKeys do
                if k ~= previousOwners[i] then
                    needsRefresh = true
                end
            end
        end
    else
        if ownerKey ~= previousOwner then
            needsRefresh = true
        end
    end

    if needsRefresh then
        requestOwnerNames()
    end

    requestTrusteeNames()
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.op then return end

    if data.op == "set" then
        local changes = data.changes
        if not changes then return end
        if type(changes) == "string" then
            changes = lljson.decode(changes)
            if not changes then return end
        end

        local needsRefresh = false

        if changes[KEY_MULTI_OWNER_MODE] ~= nil then
            multiOwnerMode = tonumber(changes[KEY_MULTI_OWNER_MODE]) ~= 0
            needsRefresh = true
        end

        -- Single owner changed
        local ownerObj = changes[KEY_OWNER]
        if ownerObj ~= nil then
            ownerKey = NULL_KEY
            ownerHonorific = ""
            local parsed = ownerObj
            if type(parsed) == "string" then
                parsed = lljson.decode(parsed)
            end
            if parsed and type(parsed) == "table" then
                for k, v in pairs(parsed) do
                    ownerKey = k
                    ownerHonorific = v
                end
            end
            needsRefresh = true
        end

        -- Multi-owner changed
        local ownersObj = changes[KEY_OWNERS]
        if ownersObj ~= nil then
            ownerKeys = {}
            ownersJson = "{}"
            local parsed = ownersObj
            if type(parsed) == "string" then
                parsed = lljson.decode(parsed)
            end
            if parsed and type(parsed) == "table" then
                ownersJson = type(ownersObj) == "string" and ownersObj or lljson.encode(ownersObj)
                for k, _ in pairs(parsed) do
                    table.insert(ownerKeys, k)
                end
            end
            needsRefresh = true
        end

        if changes[KEY_PUBLIC_ACCESS] ~= nil then
            publicAccess = tonumber(changes[KEY_PUBLIC_ACCESS]) ~= 0
        end

        if changes[KEY_LOCKED] ~= nil then
            locked = tonumber(changes[KEY_LOCKED]) ~= 0
        end

        if changes[KEY_TPE_MODE] ~= nil then
            tpeMode = tonumber(changes[KEY_TPE_MODE]) ~= 0
        end

        if needsRefresh then
            requestOwnerNames()
        end

        -- Trustees changed
        local trusteesRaw = changes[KEY_TRUSTEES]
        if trusteesRaw ~= nil then
            local parsed = trusteesRaw
            if type(parsed) == "string" then
                parsed = lljson.decode(parsed)
            end
            if parsed and type(parsed) == "table" and #parsed == 0 then
                -- Object form
                trusteesJson = type(trusteesRaw) == "string" and trusteesRaw or lljson.encode(trusteesRaw)
                trusteeKeys = {}
                for k, _ in pairs(parsed) do
                    table.insert(trusteeKeys, k)
                end
                requestTrusteeNames()
            end
        end
    end
end

-- Owner name resolution

requestOwnerNames = function()
    if multiOwnerMode then
        ownerDisplayNames = {}
        ownerNameQueries = {}

        for i, k in ownerKeys do
            ownerDisplayNames[i] = ""
            if k ~= NULL_KEY then
                local queryId = ll.RequestDisplayName(k)
                ownerNameQueries[i] = queryId
            else
                ownerNameQueries[i] = NULL_KEY
            end
        end
    else
        if ownerKey ~= NULL_KEY then
            ownerDisplay = ""
            ownerDisplayQuery = ll.RequestDisplayName(ownerKey)
            ownerLegacyQuery = ll.RequestAgentData(ownerKey, DATA_NAME)
        else
            ownerDisplay = ""
            ownerDisplayQuery = NULL_KEY
            ownerLegacyQuery = NULL_KEY
        end
    end
end

requestTrusteeNames = function()
    trusteeDisplayNames = {}
    trusteeNameQueries = {}

    for i, k in trusteeKeys do
        trusteeDisplayNames[i] = ""
        if k ~= NULL_KEY then
            local queryId = ll.RequestDisplayName(k)
            trusteeNameQueries[i] = queryId
        else
            trusteeNameQueries[i] = NULL_KEY
        end
    end
end

local function getOwnerLabel()
    if ownerDisplay ~= "" then
        return ownerDisplay
    elseif ownerKey ~= NULL_KEY then
        return ll.Key2Name(ownerKey)
    else
        return "(unowned)"
    end
end

-- Status report building

local function buildStatusReport()
    local statusText = "Collar Status:\n\n"

    -- Owner information
    if multiOwnerMode then
        local ownerCount = #ownerKeys
        if ownerCount > 0 then
            statusText = statusText .. "Owners:\n"

            for i, k in ownerKeys do
                local ownersData = lljson.decode(ownersJson)
                local honorific = ""
                if ownersData and ownersData[k] then
                    honorific = ownersData[k]
                end

                local displayName = ownerDisplayNames[i] or ""

                if displayName == "" then
                    displayName = ll.Key2Name(k)
                end

                if honorific ~= "" then
                    statusText = statusText .. "  " .. honorific .. " " .. displayName .. "\n"
                else
                    statusText = statusText .. "  " .. displayName .. "\n"
                end
            end
        else
            statusText = statusText .. "Owners: Uncommitted\n"
        end
    else
        if ownerKey ~= NULL_KEY then
            local ownerLabel = getOwnerLabel()
            if ownerHonorific ~= "" then
                statusText = statusText .. "Owner: " .. ownerHonorific .. " " .. ownerLabel .. "\n"
            else
                statusText = statusText .. "Owner: " .. ownerLabel .. "\n"
            end
        else
            statusText = statusText .. "Owner: Uncommitted\n"
        end
    end

    -- Trustee information
    local trusteeCount = #trusteeKeys
    if trusteeCount > 0 then
        statusText = statusText .. "Trustees:\n"

        for i, k in trusteeKeys do
            local trusteesData = lljson.decode(trusteesJson)
            local honorific = ""
            if trusteesData and trusteesData[k] then
                honorific = trusteesData[k]
            end

            local displayName = trusteeDisplayNames[i] or ""

            if displayName == "" then
                displayName = ll.Key2Name(k)
            end

            if honorific ~= "" then
                statusText = statusText .. "  " .. honorific .. " " .. displayName .. "\n"
            else
                statusText = statusText .. "  " .. displayName .. "\n"
            end
        end
    else
        statusText = statusText .. "Trustees: none\n"
    end

    -- Public access
    if publicAccess then
        statusText = statusText .. "Public Access: On\n"
    else
        statusText = statusText .. "Public Access: Off\n"
    end

    -- Lock status
    if locked then
        statusText = statusText .. "Collar locked: Yes\n"
    else
        statusText = statusText .. "Collar locked: No\n"
    end

    -- TPE mode
    if tpeMode then
        statusText = statusText .. "TPE Mode: On\n"
    else
        statusText = statusText .. "TPE Mode: Off\n"
    end

    return statusText
end

-- UI / Menu system

local function showStatusMenu()
    sessionId = generateSessionId()

    local statusReport = buildStatusReport()

    local buttons = {"Back"}

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = PLUGIN_LABEL,
        message = statusReport,
        buttons = buttons,
        timeout = 60
    }), NULL_KEY)
end

-- Button handling

local function handleButtonClick(button)
    if button == "Back" then
        ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
            type = "return",
            user = tostring(currentUser)
        }), NULL_KEY)
        cleanupSession()
        return
    end
end

-- Event handlers

LLEvents:on("link_message", function(sender, num, msg, id)
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

    -- Settings sync/delta
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

    -- UI start
    if num == UI_BUS then
        local data = lljson.decode(msg)
        if not data or not data.type then return end

        if data.type == "start" then
            if not data.context then return end
            if data.context ~= PLUGIN_CONTEXT then return end

            if not id.istruthy then return end

            currentUser = id

            local userAcl = tonumber(data.acl) or 0
            policyButtons = getPolicyButtons(PLUGIN_CONTEXT, userAcl)

            showStatusMenu()
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

            local user = data.user
            if not user then return end

            if user ~= tostring(currentUser) then return end

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

LLEvents:on("dataserver", function(queryId, data)
    -- Check trustee name queries first
    for i, qid in trusteeNameQueries do
        if qid == queryId then
            trusteeDisplayNames[i] = data
            return
        end
    end

    -- Multi-owner mode
    if multiOwnerMode then
        for i, qid in ownerNameQueries do
            if qid == queryId then
                ownerDisplayNames[i] = data
                return
            end
        end
    else
        -- Single owner mode
        if queryId == ownerDisplayQuery then
            ownerDisplay = data
        elseif queryId == ownerLegacyQuery then
            if ownerDisplay == "" then
                ownerDisplay = data
            end
        end
    end
end)

LLEvents:on("on_rez", function(startParam)
    ll.ResetScript()
end)

LLEvents:on("changed", function(changeMask)
    if bit32.btest(changeMask, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

-- Init
cleanupSession()

ownerDisplay = ""
ownerDisplayQuery = NULL_KEY
ownerLegacyQuery = NULL_KEY
ownerDisplayNames = {}
ownerNameQueries = {}
trusteeDisplayNames = {}
trusteeNameQueries = {}

registerSelf()
requestSettingsSync()
