--[[--------------------
MODULE: kmod_auth.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Authoritative ACL engine - OPTIMIZED
ARCHITECTURE: Dispatch table pattern with linkset data cache and JSON templates (SLua port)
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 1
  Tables replace stride lists. lljson replaces llList2Json/llJsonGetValue.
  LLTimers available but not needed (no timer in this module).
--------------------]]


-- -------------------- CONSOLIDATED ABI --------------------
local KERNEL_LIFECYCLE = 500
local AUTH_BUS = 700
local SETTINGS_BUS = 800

-- -------------------- ACL CONSTANTS --------------------
local ACL_BLACKLIST     = -1
local ACL_NOACCESS      = 0
local ACL_PUBLIC        = 1
local ACL_OWNED         = 2
local ACL_TRUSTEE       = 3
local ACL_UNOWNED       = 4
local ACL_PRIMARY_OWNER = 5

-- -------------------- SETTINGS KEYS --------------------
local KEY_MULTI_OWNER_MODE = "access.multiowner"
local KEY_OWNER            = "access.owner"
local KEY_OWNERS           = "access.owners"
local KEY_TRUSTEES         = "access.trustees"
local KEY_BLACKLIST        = "access.blacklist"
local KEY_PUBLIC_ACCESS    = "public.mode"
local KEY_TPE_MODE         = "tpe.mode"

-- -------------------- LINKSET DATA KEYS --------------------
local LSD_KEY_ACL_OWNERS    = "ACL.OWNERS"
local LSD_KEY_ACL_TRUSTEES  = "ACL.TRUSTEES"
local LSD_KEY_ACL_BLACKLIST = "ACL.BLACKLIST"
local LSD_KEY_ACL_PUBLIC    = "ACL.PUBLIC"
local LSD_KEY_ACL_TPE       = "ACL.TPE"
local LSD_KEY_ACL_TIMESTAMP = "ACL.TIMESTAMP"

-- Per-user ACL query cache prefix. Full key = LSD_ACL_CACHE_PREFIX .. avatar_uuid.
-- Value format: "<level>|<unix_timestamp>" -- e.g. "5|1712345678".
-- kmod_ui reads this prefix directly to skip the AUTH_BUS round-trip on touch.
-- CROSS-MODULE CONTRACT: this constant must match LSD_ACL_CACHE_PREFIX in kmod_ui.
local LSD_ACL_CACHE_PREFIX = "acl_cache_"

-- -------------------- CACHE CONSTANTS --------------------
local CACHE_TTL = 60
local CACHE_MAX_USERS = 800

-- -------------------- JSON RESPONSE TEMPLATES --------------------
-- Pre-built template tables for fast response construction
local JSON_TEMPLATE_BLACKLIST = nil
local JSON_TEMPLATE_UNAUTHORIZED = nil
local JSON_TEMPLATE_NOACCESS = nil
local JSON_TEMPLATE_PUBLIC = nil
local JSON_TEMPLATE_OWNED = nil
local JSON_TEMPLATE_TRUSTEE = nil
local JSON_TEMPLATE_UNOWNED = nil
local JSON_TEMPLATE_PRIMARY = nil

-- -------------------- STATE (CACHED SETTINGS) --------------------
local multiOwnerMode = false
local ownerKey = NULL_KEY
local ownerKeys = {}    -- array of uuid strings
local trusteeList = {}  -- array of uuid strings
local blacklist = {}    -- array of uuid strings
local publicMode = false
local tpeMode = false

local settingsReady = false
local pendingQueries = {}  -- array of {avatar=key, correlationId=string}
local MAX_PENDING_QUERIES = 50

-- -------------------- HELPER FUNCTIONS --------------------

local function isJsonArr(s)
    return (string.sub(s, 1, 1) == "[")
end

-- Check if a uuid string exists in an array of uuid strings
local function arrayHasKey(arr, k)
    local ks = tostring(k)
    for _, v in ipairs(arr) do
        if v == ks then
            return true
        end
    end
    return false
end

-- Remove a value from an array (all occurrences)
local function arrayRemoveAll(arr, val)
    local i = 1
    while i <= #arr do
        if arr[i] == val then
            table.remove(arr, i)
        else
            i = i + 1
        end
    end
end

-- Remove first occurrence of a value from an array, returns true if found
local function arrayRemoveFirst(arr, val)
    for i, v in ipairs(arr) do
        if v == val then
            table.remove(arr, i)
            return true
        end
    end
    return false
end

-- Extract keys (every other element starting at index 1) from a flat key-value list
-- This mirrors llJson2List on a JSON object which returns [k1, v1, k2, v2, ...]
-- In SLua, lljson.decode of an object returns a table, so we use pairs().
local function extractObjectKeys(obj)
    local keys = {}
    if type(obj) == "table" then
        for k, _ in pairs(obj) do
            table.insert(keys, k)
        end
    end
    return keys
end

-- -------------------- OWNER CHECKING --------------------

local function hasOwner()
    if multiOwnerMode then
        return (#ownerKeys > 0)
    end
    return (ownerKey ~= NULL_KEY)
end

local function isOwner(av)
    if multiOwnerMode then
        return arrayHasKey(ownerKeys, av)
    end
    return (tostring(av) == tostring(ownerKey))
end

-- -------------------- JSON TEMPLATE INITIALIZATION --------------------

local function initJsonTemplates()
    JSON_TEMPLATE_BLACKLIST = {
        type = "acl_result",
        avatar = "AVATAR_PLACEHOLDER",
        level = ACL_BLACKLIST,
        is_wearer = 0,
        is_blacklisted = 1,
        owner_set = 0
    }

    JSON_TEMPLATE_UNAUTHORIZED = {
        type = "acl_result",
        avatar = "AVATAR_PLACEHOLDER",
        level = ACL_BLACKLIST,
        is_wearer = 0,
        is_blacklisted = 0,
        owner_set = "OWNER_SET_PLACEHOLDER"
    }

    JSON_TEMPLATE_NOACCESS = {
        type = "acl_result",
        avatar = "AVATAR_PLACEHOLDER",
        level = ACL_NOACCESS,
        is_wearer = 1,
        is_blacklisted = 0,
        owner_set = "OWNER_SET_PLACEHOLDER"
    }

    JSON_TEMPLATE_PUBLIC = {
        type = "acl_result",
        avatar = "AVATAR_PLACEHOLDER",
        level = ACL_PUBLIC,
        is_wearer = 0,
        is_blacklisted = 0,
        owner_set = "OWNER_SET_PLACEHOLDER"
    }

    JSON_TEMPLATE_OWNED = {
        type = "acl_result",
        avatar = "AVATAR_PLACEHOLDER",
        level = ACL_OWNED,
        is_wearer = 1,
        is_blacklisted = 0,
        owner_set = 1
    }

    JSON_TEMPLATE_TRUSTEE = {
        type = "acl_result",
        avatar = "AVATAR_PLACEHOLDER",
        level = ACL_TRUSTEE,
        is_wearer = 0,
        is_blacklisted = 0,
        owner_set = "OWNER_SET_PLACEHOLDER"
    }

    JSON_TEMPLATE_UNOWNED = {
        type = "acl_result",
        avatar = "AVATAR_PLACEHOLDER",
        level = ACL_UNOWNED,
        is_wearer = 1,
        is_blacklisted = 0,
        owner_set = 0
    }

    JSON_TEMPLATE_PRIMARY = {
        type = "acl_result",
        avatar = "AVATAR_PLACEHOLDER",
        level = ACL_PRIMARY_OWNER,
        is_wearer = 0,
        is_blacklisted = 0,
        owner_set = 1
    }
end

-- -------------------- LINKSET DATA CACHE MANAGEMENT --------------------

local function getCacheKey(avatar)
    return LSD_ACL_CACHE_PREFIX .. tostring(avatar)
end

-- Forward declarations for mutual recursion
local sendAclFromLevel
local routeAclQuery

-- Try to retrieve cached ACL result (returns true if cache hit)
-- Uses sliding window: TTL resets on each access for active sessions
local function getCachedAcl(avatar, correlationId)
    local cacheKey = getCacheKey(avatar)
    local cached = ll.LinksetDataRead(cacheKey)

    if cached == "" then return false end

    -- Parse cached data: "level|timestamp"
    local parts = ll.ParseString2List(cached, {"|"}, {})
    if #parts ~= 2 then
        ll.LinksetDataDelete(cacheKey)
        return false
    end

    local cachedTime = tonumber(parts[2]) or 0
    local now = ll.GetUnixTime()

    if (now - cachedTime) > CACHE_TTL then
        ll.LinksetDataDelete(cacheKey)
        return false
    end

    -- Cache hit - reset TTL (sliding window)
    local level = tonumber(parts[1]) or 0
    local updatedCache = tostring(level) .. "|" .. tostring(now)
    ll.LinksetDataWrite(cacheKey, updatedCache)

    sendAclFromLevel(avatar, level, correlationId)
    return true
end

-- Store ACL query result in cache
local function storeCachedAcl(avatar, level)
    local cacheCount = ll.LinksetDataCountKeys()
    if cacheCount > CACHE_MAX_USERS then
        return
    end

    local cacheKey = getCacheKey(avatar)
    local cacheValue = tostring(level) .. "|" .. tostring(ll.GetUnixTime())
    ll.LinksetDataWrite(cacheKey, cacheValue)
end

-- Clear all cached ACL query results
local function clearAclQueryCache()
    local keys = ll.LinksetDataFindKeys("^" .. LSD_ACL_CACHE_PREFIX, 0, 0)
    for _, k in ipairs(keys) do
        ll.LinksetDataDelete(k)
    end
end

-- Persist ACL role lists to linkset data
local function persistAclCache()
    local ownersPayload = {}
    if multiOwnerMode then
        ownersPayload = ownerKeys
    elseif ownerKey ~= NULL_KEY then
        ownersPayload = {tostring(ownerKey)}
    end

    local ownersJson = lljson.encode(ownersPayload)
    local trusteesJson = lljson.encode(trusteeList)
    local blacklistJson = lljson.encode(blacklist)

    ll.LinksetDataWrite(LSD_KEY_ACL_OWNERS, ownersJson)
    ll.LinksetDataWrite(LSD_KEY_ACL_TRUSTEES, trusteesJson)
    ll.LinksetDataWrite(LSD_KEY_ACL_BLACKLIST, blacklistJson)
    ll.LinksetDataWrite(LSD_KEY_ACL_PUBLIC, tostring(publicMode and 1 or 0))
    ll.LinksetDataWrite(LSD_KEY_ACL_TPE, tostring(tpeMode and 1 or 0))

    local timestamp = ll.GetUnixTime()
    ll.LinksetDataWrite(LSD_KEY_ACL_TIMESTAMP, tostring(timestamp))

    clearAclQueryCache()
end

-- -------------------- JSON TEMPLATE RESPONSE BUILDER --------------------

-- Fast response construction using pre-built templates
local function sendAclFromTemplate(template, avatar, ownerSetVal, correlationId)
    -- Shallow copy the template and fill in values
    local msg = {}
    for k, v in pairs(template) do
        msg[k] = v
    end

    msg.avatar = tostring(avatar)

    if msg.owner_set == "OWNER_SET_PLACEHOLDER" then
        msg.owner_set = ownerSetVal
    end

    if correlationId ~= "" then
        msg.id = correlationId
    end

    ll.MessageLinked(LINK_SET, AUTH_BUS, lljson.encode(msg), NULL_KEY)
end

-- -------------------- DISPATCH TABLE - PER-ACL HANDLERS --------------------

local function processBlacklistQuery(avatar, correlationId)
    sendAclFromTemplate(JSON_TEMPLATE_BLACKLIST, avatar, 0, correlationId)
    storeCachedAcl(avatar, ACL_BLACKLIST)
end

local function processUnauthorizedQuery(avatar, correlationId)
    local ownerSetVal = hasOwner() and 1 or 0
    sendAclFromTemplate(JSON_TEMPLATE_UNAUTHORIZED, avatar, ownerSetVal, correlationId)
    -- Do NOT cache unauthorized strangers
end

local function processNoaccessQuery(avatar, correlationId)
    local ownerSetVal = hasOwner() and 1 or 0
    sendAclFromTemplate(JSON_TEMPLATE_NOACCESS, avatar, ownerSetVal, correlationId)
    storeCachedAcl(avatar, ACL_NOACCESS)
end

local function processPublicQuery(avatar, correlationId)
    local ownerSetVal = hasOwner() and 1 or 0
    sendAclFromTemplate(JSON_TEMPLATE_PUBLIC, avatar, ownerSetVal, correlationId)
    storeCachedAcl(avatar, ACL_PUBLIC)
end

local function processOwnedQuery(avatar, correlationId)
    sendAclFromTemplate(JSON_TEMPLATE_OWNED, avatar, 1, correlationId)
    storeCachedAcl(avatar, ACL_OWNED)
end

local function processTrusteeQuery(avatar, correlationId)
    local ownerSetVal = hasOwner() and 1 or 0
    sendAclFromTemplate(JSON_TEMPLATE_TRUSTEE, avatar, ownerSetVal, correlationId)
    storeCachedAcl(avatar, ACL_TRUSTEE)
end

local function processUnownedQuery(avatar, correlationId)
    sendAclFromTemplate(JSON_TEMPLATE_UNOWNED, avatar, 0, correlationId)
    storeCachedAcl(avatar, ACL_UNOWNED)
end

local function processPrimaryOwnerQuery(avatar, correlationId)
    sendAclFromTemplate(JSON_TEMPLATE_PRIMARY, avatar, 1, correlationId)
    storeCachedAcl(avatar, ACL_PRIMARY_OWNER)
end

-- -------------------- ACL LEVEL COMPUTATION (DISPATCH ROUTER) --------------------

-- Determine ACL level and route to appropriate handler
routeAclQuery = function(avatar, correlationId)
    local wearer = ll.GetOwner()
    local isWearer = (tostring(avatar) == tostring(wearer))

    -- FAST PATH 1: Blacklist check (most restrictive, check first)
    if arrayHasKey(blacklist, avatar) then
        processBlacklistQuery(avatar, correlationId)
        return
    end

    -- FAST PATH 2: Owner check (highest privilege)
    if isOwner(avatar) then
        processPrimaryOwnerQuery(avatar, correlationId)
        return
    end

    -- FAST PATH 3: Wearer paths
    if isWearer then
        if tpeMode then
            processNoaccessQuery(avatar, correlationId)
            return
        end
        if hasOwner() then
            processOwnedQuery(avatar, correlationId)
            return
        end
        processUnownedQuery(avatar, correlationId)
        return
    end

    -- FAST PATH 4: Trustee check
    if arrayHasKey(trusteeList, avatar) then
        processTrusteeQuery(avatar, correlationId)
        return
    end

    -- FAST PATH 5: Public mode check
    if publicMode then
        processPublicQuery(avatar, correlationId)
        return
    end

    -- DEFAULT: Unauthorized stranger
    processUnauthorizedQuery(avatar, correlationId)
end

-- Helper for cache hits - reconstruct response from cached level
sendAclFromLevel = function(avatar, level, correlationId)
    local ownerSetVal = hasOwner() and 1 or 0

    if level == ACL_BLACKLIST then
        sendAclFromTemplate(JSON_TEMPLATE_BLACKLIST, avatar, 0, correlationId)
    elseif level == ACL_NOACCESS then
        sendAclFromTemplate(JSON_TEMPLATE_NOACCESS, avatar, ownerSetVal, correlationId)
    elseif level == ACL_PUBLIC then
        sendAclFromTemplate(JSON_TEMPLATE_PUBLIC, avatar, ownerSetVal, correlationId)
    elseif level == ACL_OWNED then
        sendAclFromTemplate(JSON_TEMPLATE_OWNED, avatar, 1, correlationId)
    elseif level == ACL_TRUSTEE then
        sendAclFromTemplate(JSON_TEMPLATE_TRUSTEE, avatar, ownerSetVal, correlationId)
    elseif level == ACL_UNOWNED then
        sendAclFromTemplate(JSON_TEMPLATE_UNOWNED, avatar, 0, correlationId)
    elseif level == ACL_PRIMARY_OWNER then
        sendAclFromTemplate(JSON_TEMPLATE_PRIMARY, avatar, 1, correlationId)
    end
end

-- Pre-populate acl_cache_<uuid> in LSD for all known actors
local function precomputeKnownAcl()
    routeAclQuery(ll.GetOwner(), "")
    if multiOwnerMode then
        for _, ok in ipairs(ownerKeys) do
            routeAclQuery(ok, "")
        end
    elseif ownerKey ~= NULL_KEY then
        routeAclQuery(ownerKey, "")
    end
    for _, tk in ipairs(trusteeList) do
        routeAclQuery(tk, "")
    end
end

-- -------------------- ACL CHANGE BROADCAST --------------------

local function broadcastAclChange(scope, avatar)
    local msg = lljson.encode({
        type = "acl_update",
        scope = scope,
        avatar = tostring(avatar)
    })
    ll.MessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY)
end

-- -------------------- ROLE EXCLUSIVITY VALIDATION --------------------

local function enforceRoleExclusivity()
    if multiOwnerMode then
        for _, owner in ipairs(ownerKeys) do
            arrayRemoveAll(trusteeList, owner)
            arrayRemoveAll(blacklist, owner)
        end
    else
        if ownerKey ~= NULL_KEY then
            local owner = tostring(ownerKey)
            arrayRemoveAll(trusteeList, owner)
            arrayRemoveAll(blacklist, owner)
        end
    end

    for _, trustee in ipairs(trusteeList) do
        arrayRemoveAll(blacklist, trustee)
    end
end

-- -------------------- SETTINGS CONSUMPTION --------------------

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data then return end
    local kv = data.kv
    if not kv then return end

    -- If kv is a string (JSON-encoded), decode it
    if type(kv) == "string" then
        kv = lljson.decode(kv)
        if not kv then return end
    end

    multiOwnerMode = false
    ownerKey = NULL_KEY
    ownerKeys = {}
    trusteeList = {}
    blacklist = {}
    publicMode = false
    tpeMode = false

    if kv[KEY_MULTI_OWNER_MODE] ~= nil then
        multiOwnerMode = (tonumber(kv[KEY_MULTI_OWNER_MODE]) or 0) ~= 0
    end

    -- Single owner: JSON object {uuid:honorific} -- extract UUID
    local ownerObj = kv[KEY_OWNER]
    if ownerObj ~= nil then
        if type(ownerObj) == "table" then
            for k, _ in pairs(ownerObj) do
                ownerKey = k
                break -- only need first key
            end
        end
    end

    -- Multi-owner: JSON object {uuid:honorific, ...} -- extract UUID list
    local ownersObj = kv[KEY_OWNERS]
    if ownersObj ~= nil then
        if type(ownersObj) == "table" then
            ownerKeys = extractObjectKeys(ownersObj)
        end
    end

    local trusteesRaw = kv[KEY_TRUSTEES]
    if trusteesRaw ~= nil then
        if type(trusteesRaw) == "table" then
            -- Could be an object {uuid:honorific} or an array [uuid, ...]
            -- Check if it's an array (sequential numeric keys)
            if #trusteesRaw > 0 then
                -- Array form
                for _, v in ipairs(trusteesRaw) do
                    table.insert(trusteeList, v)
                end
            else
                -- Object form - extract keys
                trusteeList = extractObjectKeys(trusteesRaw)
            end
        elseif type(trusteesRaw) == "string" and isJsonArr(trusteesRaw) then
            local decoded = lljson.decode(trusteesRaw)
            if decoded then
                trusteeList = decoded
            end
        end
    end

    local blacklistRaw = kv[KEY_BLACKLIST]
    if blacklistRaw ~= nil then
        if type(blacklistRaw) == "table" then
            blacklist = blacklistRaw
        elseif type(blacklistRaw) == "string" and isJsonArr(blacklistRaw) then
            local decoded = lljson.decode(blacklistRaw)
            if decoded then
                blacklist = decoded
            end
        end
    end

    if kv[KEY_PUBLIC_ACCESS] ~= nil then
        publicMode = (tonumber(kv[KEY_PUBLIC_ACCESS]) or 0) ~= 0
    end

    if kv[KEY_TPE_MODE] ~= nil then
        tpeMode = (tonumber(kv[KEY_TPE_MODE]) or 0) ~= 0
    end

    enforceRoleExclusivity()
    persistAclCache()

    settingsReady = true

    broadcastAclChange("global", NULL_KEY)

    for _, entry in ipairs(pendingQueries) do
        routeAclQuery(entry.avatar, entry.correlationId)
    end
    pendingQueries = {}
    precomputeKnownAcl()
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data then return end
    local op = data.op
    if not op then return end
    local cacheDirty = false

    if op == "set" then
        local changes = data.changes
        if not changes then return end

        -- If changes is a string (JSON-encoded), decode it
        if type(changes) == "string" then
            changes = lljson.decode(changes)
            if not changes then return end
        end

        if changes[KEY_PUBLIC_ACCESS] ~= nil then
            publicMode = (tonumber(changes[KEY_PUBLIC_ACCESS]) or 0) ~= 0
            broadcastAclChange("global", NULL_KEY)
            cacheDirty = true
        end

        if changes[KEY_TPE_MODE] ~= nil then
            tpeMode = (tonumber(changes[KEY_TPE_MODE]) or 0) ~= 0
            broadcastAclChange("global", NULL_KEY)
            cacheDirty = true
        end

        -- Single owner changed
        local ownerObj = changes[KEY_OWNER]
        if ownerObj ~= nil then
            ownerKey = NULL_KEY
            if type(ownerObj) == "table" then
                for k, _ in pairs(ownerObj) do
                    ownerKey = k
                    break
                end
            end
            enforceRoleExclusivity()
            broadcastAclChange("global", NULL_KEY)
            cacheDirty = true
        end

        -- Multi-owner changed
        local ownersObj = changes[KEY_OWNERS]
        if ownersObj ~= nil then
            ownerKeys = {}
            if type(ownersObj) == "table" then
                ownerKeys = extractObjectKeys(ownersObj)
            end
            enforceRoleExclusivity()
            broadcastAclChange("global", NULL_KEY)
            cacheDirty = true
        end

        -- Trustees changed
        local trusteesRaw = changes[KEY_TRUSTEES]
        if trusteesRaw ~= nil then
            trusteeList = {}
            if type(trusteesRaw) == "table" then
                if #trusteesRaw > 0 then
                    for _, v in ipairs(trusteesRaw) do
                        table.insert(trusteeList, v)
                    end
                else
                    trusteeList = extractObjectKeys(trusteesRaw)
                end
            end
            enforceRoleExclusivity()
            broadcastAclChange("global", NULL_KEY)
            cacheDirty = true
        end
    elseif op == "list_add" then
        local keyName = data.key
        if not keyName then return end
        local elem = data.elem
        if not elem then return end

        if keyName == KEY_BLACKLIST then
            if not arrayHasKey(blacklist, elem) then
                table.insert(blacklist, elem)
                broadcastAclChange("avatar", elem)
                cacheDirty = true
            end
        end
    elseif op == "list_remove" then
        local keyName = data.key
        if not keyName then return end
        local elem = data.elem
        if not elem then return end

        if keyName == KEY_BLACKLIST then
            arrayRemoveAll(blacklist, elem)
            broadcastAclChange("avatar", elem)
            cacheDirty = true
        end
    end

    if cacheDirty then
        persistAclCache()
        precomputeKnownAcl()
    end
end

-- -------------------- MESSAGE HANDLERS --------------------

local function handleAclQuery(msg)
    local data = lljson.decode(msg)
    if not data then return end
    local avStr = data.avatar
    if not avStr then return end
    if avStr == NULL_KEY then return end

    local correlationId = data.id or ""

    if not settingsReady then
        if #pendingQueries >= MAX_PENDING_QUERIES then
            table.remove(pendingQueries, 1)
        end
        table.insert(pendingQueries, {avatar = avStr, correlationId = correlationId})
        return
    end

    -- Try cache first
    if getCachedAcl(avStr, correlationId) then
        return
    end

    -- Cache miss - compute and cache result
    routeAclQuery(avStr, correlationId)
end

-- -------------------- EVENTS --------------------

local function init()
    settingsReady = false
    pendingQueries = {}

    initJsonTemplates()

    local request = lljson.encode({
        type = "settings_get"
    })
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, request, NULL_KEY)
end

LLEvents:on("link_message", function(sender, num, msg, id)
    local data = lljson.decode(msg)
    if not data then return end
    local msgType = data.type
    if not msgType then return end

    if num == KERNEL_LIFECYCLE then
        if msgType == "soft_reset" or msgType == "soft_reset_all" then
            ll.ResetScript()
        end
    elseif num == AUTH_BUS then
        if msgType == "acl_query" then
            handleAclQuery(msg)
        end
    elseif num == SETTINGS_BUS then
        if msgType == "settings_sync" then
            applySettingsSync(msg)
        elseif msgType == "settings_delta" then
            applySettingsDelta(msg)
        end
    end
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

-- Run initialization
init()
