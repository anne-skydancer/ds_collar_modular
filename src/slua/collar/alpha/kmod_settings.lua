--[[--------------------
MODULE: kmod_settings.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Persistent key-value store with notecard loading and delta updates
ARCHITECTURE: Consolidated message bus lanes (SLua port)
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Tables replace stride lists. lljson replaces llJson* calls.
  LLTimers/LLEvents replace LSL event block.
--------------------]]

-- Consolidated ABI
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800

-- Settings keys
local KEY_MULTI_OWNER_MODE = "access.multiowner"
local KEY_OWNER            = "access.owner"
local KEY_OWNERS           = "access.owners"
local KEY_TRUSTEES         = "access.trustees"
local KEY_BLACKLIST        = "access.blacklist"
local KEY_PUBLIC_ACCESS    = "public.mode"
local KEY_TPE_MODE         = "tpe.mode"
local KEY_LOCKED           = "lock.locked"

-- RLV exception keys
local KEY_EX_OWNER_TP   = "rlvex.ownertp"
local KEY_EX_OWNER_IM   = "rlvex.ownerim"
local KEY_EX_TRUSTEE_TP = "rlvex.trusteetp"
local KEY_EX_TRUSTEE_IM = "rlvex.trusteeim"

-- Access plugin keys
local KEY_RUNAWAY_ENABLED = "access.enablerunaway"

-- Notecard config
local NOTECARD_NAME = "settings"
local COMMENT_PREFIX = "#"
local SEPARATOR = "="

-- State
local lastOwner = NULL_KEY
local kvJson = {}

local notecardQuery = NULL_KEY
local notecardLine = 1
local isLoadingNotecard = false
local notecardKey = NULL_KEY
local forceReseed = false

local MAX_LIST_LEN = 64

-- Helpers

local function getMsgType(jsonStr)
    local data = lljson.decode(jsonStr)
    if data and data.type then return data.type end
    return ""
end

local function normalizeBool(s)
    local v = tonumber(s) or 0
    if v ~= 0 then v = 1 end
    return tostring(math.floor(v))
end

local function listRemoveAll(sourceList, s)
    local result = {}
    for i = 1, #sourceList do
        if sourceList[i] ~= s then
            result[#result + 1] = sourceList[i]
        end
    end
    return result
end

local function listUnique(sourceList)
    if #sourceList < 2 then return sourceList end
    local seen = {}
    local result = {}
    for i = 1, #sourceList do
        local v = sourceList[i]
        if not seen[v] then
            seen[v] = true
            result[#result + 1] = v
        end
    end
    return result
end

-- KV operations
-- kvJson is a Lua table (not a JSON string)

local function kvGet(keyName)
    local val = kvJson[keyName]
    if val == nil then return "" end
    return val
end

local function kvSetScalar(keyName, value)
    local oldVal = kvGet(keyName)
    if oldVal == value then return false end
    kvJson[keyName] = value
    return true
end

local function kvSetList(keyName, values)
    local newArr = lljson.encode(values)
    local oldArr = kvGet(keyName)
    if oldArr == newArr then return false end
    kvJson[keyName] = newArr
    return true
end

local function kvListAddUnique(keyName, elem)
    local arr = kvGet(keyName)
    local currentList = {}
    if arr ~= "" then
        local decoded = lljson.decode(arr)
        if type(decoded) == "table" and #decoded >= 0 then
            currentList = decoded
        end
    end

    for i = 1, #currentList do
        if currentList[i] == elem then return false end
    end
    if #currentList >= MAX_LIST_LEN then return false end

    currentList[#currentList + 1] = elem
    return kvSetList(keyName, currentList)
end

-- JSON object KV operations

local function kvObjSetField(keyName, field, value)
    local objStr = kvGet(keyName)
    local obj = {}
    if objStr ~= "" then
        local decoded = lljson.decode(objStr)
        if type(decoded) == "table" then
            obj = decoded
        end
    end
    obj[field] = value
    return kvSetScalar(keyName, lljson.encode(obj))
end

local function kvObjRemoveField(keyName, field)
    local objStr = kvGet(keyName)
    if objStr == "" then return false end
    local obj = lljson.decode(objStr)
    if type(obj) ~= "table" then return false end
    if obj[field] == nil then return false end
    obj[field] = nil
    return kvSetScalar(keyName, lljson.encode(obj))
end

local function kvListRemoveAll(keyName, elem)
    local arr = kvGet(keyName)
    if arr == "" then return false end
    local decoded = lljson.decode(arr)
    if type(decoded) ~= "table" then return false end

    local currentList = decoded
    local newList = listRemoveAll(currentList, elem)

    if #newList == #currentList then return false end

    return kvSetList(keyName, newList)
end

-- Validation helpers

local function isJsonObjectStr(s)
    if s == "" then return false end
    local decoded = lljson.decode(s)
    return type(decoded) == "table" and #decoded == 0 and next(decoded) ~= nil
end

-- Check if a decoded table is an object (has string keys, not array)
local function isTableObject(t)
    if type(t) ~= "table" then return false end
    for k, _ in pairs(t) do
        if type(k) == "string" then return true end
    end
    return false
end

local function hasExternalOwner()
    local wearer = ll.GetOwner()

    local objKey = KEY_OWNER
    if kvGet(KEY_MULTI_OWNER_MODE) == "1" then
        objKey = KEY_OWNERS
    end

    local objStr = kvGet(objKey)
    if objStr ~= "" then
        local obj = lljson.decode(objStr)
        if isTableObject(obj) then
            for ownerUuid, _ in pairs(obj) do
                if ownerUuid ~= wearer and ownerUuid ~= NULL_KEY then
                    return true
                end
            end
        end
    end

    return false
end

local function isOwner(who)
    -- Check single owner object
    local ownerObjStr = kvGet(KEY_OWNER)
    if ownerObjStr ~= "" then
        local ownerObj = lljson.decode(ownerObjStr)
        if isTableObject(ownerObj) and ownerObj[who] ~= nil then
            return true
        end
    end

    -- Check multi-owner object
    local ownersObjStr = kvGet(KEY_OWNERS)
    if ownersObjStr ~= "" then
        local ownersObj = lljson.decode(ownersObjStr)
        if isTableObject(ownersObj) and ownersObj[who] ~= nil then
            return true
        end
    end

    return false
end

-- Broadcasting (forward declarations)
local broadcastFullSync
local broadcastDeltaScalar
local broadcastDeltaListAdd
local broadcastDeltaListRemove

-- Role exclusivity guards

local function applyOwnerSetGuard(who)
    local wearer = ll.GetOwner()

    -- Prevent self-ownership
    if who == wearer then
        ll.OwnerSay("ERROR: Cannot add wearer as owner (role separation required)")
        return false
    end

    -- Remove owner from trustees object and broadcast the change
    if kvObjRemoveField(KEY_TRUSTEES, who) then
        broadcastDeltaScalar(KEY_TRUSTEES, kvGet(KEY_TRUSTEES))
    end

    -- Remove owner from blacklist and broadcast the change
    local blacklistArr = kvGet(KEY_BLACKLIST)
    if blacklistArr ~= "" then
        local blacklist = lljson.decode(blacklistArr)
        if type(blacklist) == "table" then
            local found = false
            for i = 1, #blacklist do
                if blacklist[i] == who then found = true end
            end
            if found then
                blacklist = listRemoveAll(blacklist, who)
                if kvSetList(KEY_BLACKLIST, blacklist) then
                    broadcastDeltaListRemove(KEY_BLACKLIST, who)
                end
            end
        end
    end

    return true
end

local function applyTrusteeAddGuard(who)
    if isOwner(who) then
        return false
    end

    -- Remove from blacklist and broadcast the change
    local blacklistArr = kvGet(KEY_BLACKLIST)
    if blacklistArr ~= "" then
        local blacklist = lljson.decode(blacklistArr)
        if type(blacklist) == "table" then
            local found = false
            for i = 1, #blacklist do
                if blacklist[i] == who then found = true end
            end
            if found then
                blacklist = listRemoveAll(blacklist, who)
                if kvSetList(KEY_BLACKLIST, blacklist) then
                    broadcastDeltaListRemove(KEY_BLACKLIST, who)
                end
            end
        end
    end

    return true
end

local function applyBlacklistAddGuard(who)
    -- Remove from trustees object and broadcast the change
    if kvObjRemoveField(KEY_TRUSTEES, who) then
        broadcastDeltaScalar(KEY_TRUSTEES, kvGet(KEY_TRUSTEES))
    end

    -- Remove from single owner object and broadcast
    if kvObjRemoveField(KEY_OWNER, who) then
        broadcastDeltaScalar(KEY_OWNER, kvGet(KEY_OWNER))
    end

    -- Remove from multi-owner object and broadcast
    if kvObjRemoveField(KEY_OWNERS, who) then
        broadcastDeltaScalar(KEY_OWNERS, kvGet(KEY_OWNERS))
    end

    return true
end

-- Guard a trustees JSON object: remove any owner or wearer UUIDs
local function guardTrusteesObject(objStr)
    local obj = lljson.decode(objStr)
    if not isTableObject(obj) then return objStr end

    local wearer = ll.GetOwner()
    obj[wearer] = nil

    -- Remove owners from single-owner and multi-owner objects
    local ownerSources = { kvGet(KEY_OWNER), kvGet(KEY_OWNERS) }
    for si = 1, 2 do
        local src = ownerSources[si]
        if src ~= "" then
            local srcObj = lljson.decode(src)
            if isTableObject(srcObj) then
                for ownerKey, _ in pairs(srcObj) do
                    obj[ownerKey] = nil
                end
            end
        end
    end
    return lljson.encode(obj)
end

-- Guard an owner JSON object: validate each UUID (no self-ownership)
local function guardOwnerObject(objStr)
    local obj = lljson.decode(objStr)
    if not isTableObject(obj) then return "{}" end

    local result = {}
    for uuid, hon in pairs(obj) do
        if applyOwnerSetGuard(uuid) then
            result[uuid] = hon
        end
    end
    return lljson.encode(result)
end

-- Broadcasting implementation

broadcastFullSync = function()
    local msg = lljson.encode({
        type = "settings_sync",
        kv = lljson.encode(kvJson)
    })
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY)
end

broadcastDeltaScalar = function(keyName, newValue)
    local changes = lljson.encode({ [keyName] = newValue })
    local msg = lljson.encode({
        type = "settings_delta",
        op = "set",
        changes = changes
    })
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY)
end

broadcastDeltaListAdd = function(keyName, elem)
    local msg = lljson.encode({
        type = "settings_delta",
        op = "list_add",
        key = keyName,
        elem = elem
    })
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY)
end

broadcastDeltaListRemove = function(keyName, elem)
    local msg = lljson.encode({
        type = "settings_delta",
        op = "list_remove",
        key = keyName,
        elem = elem
    })
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY)
end

-- Key naming convention
-- No whitelist is enforced. LSL link_message is sandboxed to the same linkset,
-- so any script that can write to SETTINGS_BUS is already trusted by the owner.

local function isJsonObjectKey(k)
    return k == KEY_OWNER or k == KEY_OWNERS or k == KEY_TRUSTEES
end

local function isNotecardOnlyKey(k)
    return k == KEY_MULTI_OWNER_MODE or k == KEY_OWNERS
end

-- Notecard parsing

local function parseNotecardLine(line)
    line = string.gsub(line, "^%s+", "")
    line = string.gsub(line, "%s+$", "")

    if line == "" then return end
    if string.sub(line, 1, 1) == COMMENT_PREFIX then return end

    local sepPos = string.find(line, SEPARATOR, 1, true)
    if not sepPos then return end

    local keyName = string.gsub(string.sub(line, 1, sepPos - 1), "^%s+", "")
    keyName = string.gsub(keyName, "%s+$", "")
    local value = string.gsub(string.sub(line, sepPos + 1), "^%s+", "")
    value = string.gsub(value, "%s+$", "")

    -- Dotted keys: write to LSD on forced reseed or first wear
    if string.find(keyName, ".", 1, true) then
        if forceReseed or ll.LinksetDataRead(keyName) == "" then
            ll.LinksetDataWrite(keyName, value)
        end
        -- Fall through: still add to kvJson so session delta broadcasting works
    end

    -- Check for JSON object (owner, owners, trustees)
    if isJsonObjectKey(keyName) and string.sub(value, 1, 1) == "{" then
        local decoded = lljson.decode(value)
        if isTableObject(decoded) then
            -- Guard trustees: remove owners from trustee object
            if keyName == KEY_TRUSTEES then
                value = guardTrusteesObject(value)
            end
            -- Guard owner objects: validate UUIDs (no self-ownership)
            if keyName == KEY_OWNER or keyName == KEY_OWNERS then
                value = guardOwnerObject(value)
            end
            kvSetScalar(keyName, value)
        end
    elseif string.sub(value, 1, 1) == "[" then
        -- Reject array syntax for keys that must be JSON objects
        if isJsonObjectKey(keyName) then
            ll.OwnerSay("WARNING: " .. keyName .. " requires JSON object format, not array")
            return
        end
        -- Parse as CSV list
        local listContents = string.sub(value, 2, -2)
        local parsedList = string.split(listContents, ", ")
        parsedList = listUnique(parsedList)

        -- Enforce MAX_LIST_LEN for notecard
        if #parsedList > MAX_LIST_LEN then
            local truncated = {}
            for i = 1, MAX_LIST_LEN do
                truncated[i] = parsedList[i]
            end
            parsedList = truncated
            ll.OwnerSay("WARNING: " .. keyName .. " list truncated to " .. tostring(MAX_LIST_LEN) .. " entries")
        end

        -- Apply blacklist guards for notecard
        if keyName == KEY_BLACKLIST then
            for i = 1, #parsedList do
                applyBlacklistAddGuard(parsedList[i])
            end
        end

        kvSetList(keyName, parsedList)
    else
        -- Scalar value
        if keyName == KEY_MULTI_OWNER_MODE then value = normalizeBool(value) end
        if keyName == KEY_PUBLIC_ACCESS then value = normalizeBool(value) end
        if keyName == KEY_LOCKED then value = normalizeBool(value) end
        if keyName == KEY_RUNAWAY_ENABLED then value = normalizeBool(value) end

        -- Validate TPE mode in notecard
        if keyName == KEY_TPE_MODE then
            value = normalizeBool(value)
            if tonumber(value) == 1 then
                if not hasExternalOwner() then
                    ll.OwnerSay("ERROR: Cannot enable TPE via notecard - requires external owner")
                    ll.OwnerSay("HINT: Set owner or owners BEFORE tpe_mode in notecard")
                    return
                end
            end
        end

        kvSetScalar(keyName, value)
    end
end

-- Recover runtime-set values from LSD that the notecard doesn't contain
local function recoverLsdSettings()
    local keys = {
        KEY_MULTI_OWNER_MODE, KEY_OWNER, KEY_OWNERS, KEY_TRUSTEES,
        KEY_BLACKLIST, KEY_PUBLIC_ACCESS, KEY_TPE_MODE, KEY_LOCKED,
        KEY_EX_OWNER_TP, KEY_EX_OWNER_IM, KEY_EX_TRUSTEE_TP, KEY_EX_TRUSTEE_IM,
        KEY_RUNAWAY_ENABLED
    }
    for i = 1, #keys do
        local k = keys[i]
        if kvJson[k] == nil then
            local lsdVal = ll.LinksetDataRead(k)
            if lsdVal ~= "" then
                kvJson[k] = lsdVal
            end
        end
    end
end

local function startNotecardReading()
    if ll.GetInventoryType(NOTECARD_NAME) ~= INVENTORY_NOTECARD then
        return false
    end
    isLoadingNotecard = true
    notecardLine = 1
    notecardQuery = ll.GetNotecardLine(NOTECARD_NAME, notecardLine)
    return true
end

-- Message handlers

local function handleSettingsGet()
    broadcastFullSync()
end

local function handleSet(msg)
    local data = lljson.decode(msg)
    if not data or not data.key then return end

    local keyName = data.key

    if isNotecardOnlyKey(keyName) then return end

    local didChange = false

    -- Bulk list set
    if data.values then
        local valuesArr = data.values
        if type(valuesArr) == "string" then
            valuesArr = lljson.decode(valuesArr)
        end
        if type(valuesArr) == "table" then
            local newList = listUnique(valuesArr)

            if keyName == KEY_BLACKLIST then
                for i = 1, #newList do
                    applyBlacklistAddGuard(newList[i])
                end
            end

            didChange = kvSetList(keyName, newList)

            if didChange then
                ll.LinksetDataWrite(keyName, kvGet(keyName))
                broadcastFullSync()
            end
        end
        return
    end

    -- Scalar set
    if data.value ~= nil then
        local value = data.value

        if keyName == KEY_PUBLIC_ACCESS then value = normalizeBool(value) end
        if keyName == KEY_LOCKED then value = normalizeBool(value) end
        if keyName == KEY_RUNAWAY_ENABLED then value = normalizeBool(value) end

        -- Validate TPE mode
        if keyName == KEY_TPE_MODE then
            value = normalizeBool(value)
            if tonumber(value) == 1 then
                if not hasExternalOwner() then
                    ll.OwnerSay("ERROR: Cannot enable TPE - requires external owner")
                    return
                end
            end
        end

        -- Guard owner objects on scalar set
        if (keyName == KEY_OWNER or keyName == KEY_OWNERS) then
            local decoded = lljson.decode(value)
            if isTableObject(decoded) then
                value = guardOwnerObject(value)
            end
        end

        -- Guard trustees object on scalar set
        if keyName == KEY_TRUSTEES then
            local decoded = lljson.decode(value)
            if isTableObject(decoded) then
                value = guardTrusteesObject(value)
            end
        end

        didChange = kvSetScalar(keyName, value)

        if didChange then
            ll.LinksetDataWrite(keyName, value)
            broadcastDeltaScalar(keyName, value)
        end
    end
end

local function handleListAdd(msg)
    local data = lljson.decode(msg)
    if not data or not data.key or not data.elem then return end

    local keyName = data.key
    local elem = data.elem

    if isNotecardOnlyKey(keyName) then return end

    local didChange = false

    if keyName == KEY_BLACKLIST then
        applyBlacklistAddGuard(elem)
    end
    didChange = kvListAddUnique(keyName, elem)

    if didChange then
        ll.LinksetDataWrite(keyName, kvGet(keyName))
        broadcastDeltaListAdd(keyName, elem)
    end
end

local function handleObjSet(msg)
    local data = lljson.decode(msg)
    if not data or not data.key or not data.field or not data.value then return end

    local keyName = data.key
    local field = data.field
    local value = data.value

    if not isJsonObjectKey(keyName) then return end

    -- Guard: trustee can't be an owner
    if keyName == KEY_TRUSTEES then
        if not applyTrusteeAddGuard(field) then return end
    end

    -- Guard: owner can't be wearer, removes from trustees/blacklist
    if keyName == KEY_OWNER or keyName == KEY_OWNERS then
        if not applyOwnerSetGuard(field) then return end
    end

    -- Enforce MAX_LIST_LEN on JSON object fields
    local currentObjStr = kvGet(keyName)
    if currentObjStr ~= "" then
        local currentObj = lljson.decode(currentObjStr)
        if isTableObject(currentObj) then
            -- Only count if field is new (not updating existing)
            if currentObj[field] == nil then
                local fieldCount = 0
                for _ in pairs(currentObj) do fieldCount = fieldCount + 1 end
                if fieldCount >= MAX_LIST_LEN then return end
            end
        end
    end

    local didChange = kvObjSetField(keyName, field, value)
    if didChange then
        local updated = kvGet(keyName)
        ll.LinksetDataWrite(keyName, updated)
        broadcastDeltaScalar(keyName, updated)
    end
end

local function handleObjRemove(msg)
    local data = lljson.decode(msg)
    if not data or not data.key or not data.field then return end

    local keyName = data.key
    local field = data.field

    if not isJsonObjectKey(keyName) then return end

    local didChange = kvObjRemoveField(keyName, field)
    if didChange then
        local updated = kvGet(keyName)
        ll.LinksetDataWrite(keyName, updated)
        broadcastDeltaScalar(keyName, updated)
    end
end

local function handleListRemove(msg)
    local data = lljson.decode(msg)
    if not data or not data.key or not data.elem then return end

    local keyName = data.key
    local elem = data.elem

    local didChange = kvListRemoveAll(keyName, elem)

    if didChange then
        ll.LinksetDataWrite(keyName, kvGet(keyName))
        broadcastDeltaListRemove(keyName, elem)
    end
end

local function handleSettingsRestore(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end

    kvJson = lljson.decode(data.kv)
    if type(kvJson) ~= "table" then kvJson = {} end

    broadcastFullSync()
end

-- Init

local function init()
    lastOwner = ll.GetOwner()
    notecardKey = ll.GetInventoryKey(NOTECARD_NAME)
    forceReseed = false

    local notecardFound = startNotecardReading()

    if not notecardFound then
        recoverLsdSettings()
        broadcastFullSync()
    end
end

-- Events

LLEvents:on("on_rez", function(startParam)
    local currentOwner = ll.GetOwner()
    if currentOwner ~= lastOwner then
        lastOwner = currentOwner
        ll.ResetScript()
    end
end)

LLEvents:on("attach", function(id)
    if not id:istruthy() then return end

    local currentOwner = ll.GetOwner()
    if currentOwner ~= lastOwner then
        lastOwner = currentOwner
        ll.ResetScript()
    end
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        local currentOwner = ll.GetOwner()
        if currentOwner ~= lastOwner then
            lastOwner = currentOwner
            ll.ResetScript()
        end
    end

    if bit32.btest(change, CHANGED_INVENTORY) then
        local currentNotecardKey = ll.GetInventoryKey(NOTECARD_NAME)
        if currentNotecardKey ~= notecardKey then
            if not currentNotecardKey:istruthy() then
                ll.ResetScript()
            else
                notecardKey = currentNotecardKey
                forceReseed = true
                startNotecardReading()
            end
        end
    end
end)

LLEvents:on("dataserver", function(queryId, data)
    if queryId ~= notecardQuery then return end

    if data ~= EOF then
        parseNotecardLine(data)
        notecardLine = notecardLine + 1
        notecardQuery = ll.GetNotecardLine(NOTECARD_NAME, notecardLine)
    else
        isLoadingNotecard = false
        forceReseed = false
        recoverLsdSettings()
        broadcastFullSync()

        -- Trigger bootstrap after notecard load completes
        local bootstrapMsg = lljson.encode({ type = "notecard_loaded" })
        ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, bootstrapMsg, NULL_KEY)
    end
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    if num ~= SETTINGS_BUS then return end
    local msgType = getMsgType(msg)
    if msgType == "" then return end

    if msgType == "settings_get" then
        handleSettingsGet()
    elseif msgType == "set" then
        handleSet(msg)
    elseif msgType == "list_add" then
        handleListAdd(msg)
    elseif msgType == "list_remove" then
        handleListRemove(msg)
    elseif msgType == "obj_set" then
        handleObjSet(msg)
    elseif msgType == "obj_remove" then
        handleObjRemove(msg)
    elseif msgType == "settings_restore" then
        handleSettingsRestore(msg)
    end
end)

-- Run init
init()
