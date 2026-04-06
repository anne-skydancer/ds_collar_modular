--[[--------------------
PLUGIN: plugin_access.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Owner, trustee, and honorific management workflows
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v0.1 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
  Table-based data replaces stride lists.
  LLEvents replaces state-based event handling.
--------------------]]

-- ABI channels
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

-- Identity
local PLUGIN_CONTEXT = "core_owner"
local PLUGIN_LABEL = "Access"

-- Constants
local MAX_NUMBERED_LIST_ITEMS = 11

-- Settings keys
local KEY_MULTI_OWNER_MODE = "access.multiowner"
local KEY_OWNER = "access.owner"
local KEY_OWNERS = "access.owners"
local KEY_TRUSTEES = "access.trustees"
local KEY_RUNAWAY_ENABLED = "access.enablerunaway"

-- State
local multiOwnerMode = false
local ownerKey = NULL_KEY
local ownerKeys = {}
local ownerHonorific = ""
local ownerJson = "{}"
local ownersJson = "{}"
local trusteeKeys = {}
local trusteesJson = "{}"
local runawayEnabled = true

local currentUser = NULL_KEY
local userAcl = -999
local policyButtons = {}
local sessionId = ""
local menuContext = ""

local pendingCandidate = NULL_KEY
local pendingHonorific = ""
local candidateKeys = {}

local nameCache = {}  -- keyed by uuid string -> name string
local activeNameQuery = NULL_KEY
local activeQueryTarget = NULL_KEY

local OWNER_HONORIFICS = {"Master", "Mistress", "Daddy", "Mommy", "King", "Queen"}
local TRUSTEE_HONORIFICS = {"Sir", "Madame", "Milord", "Milady"}

-- Helpers

local function lsdInt(lsdKey, fallback)
    local v = ll.LinksetDataRead(lsdKey)
    if v == "" then return fallback end
    return math.floor(tonumber(v) or fallback)
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
    for _, v in ipairs(policyButtons) do
        if v == label then return true end
    end
    return false
end

local function hasOwner()
    if multiOwnerMode then return #ownerKeys > 0 end
    return ownerKey ~= NULL_KEY
end

local function getPrimaryOwner()
    if multiOwnerMode and #ownerKeys > 0 then
        return ownerKeys[1]
    end
    return ownerKey
end

local function isOwner(k)
    local ks = tostring(k)
    if multiOwnerMode then
        for _, v in ipairs(ownerKeys) do
            if v == ks then return true end
        end
        return false
    end
    return k == ownerKey
end

-- Names

local function cacheName(k, n)
    if k == NULL_KEY or n == "" or n == "???" then return end
    nameCache[tostring(k)] = n
    -- Simple size cap
    local count = 0
    for _ in pairs(nameCache) do count = count + 1 end
    if count > 10 then
        -- Remove an arbitrary entry
        for ek, _ in pairs(nameCache) do
            if ek ~= tostring(k) then
                nameCache[ek] = nil
                return  -- removed one, done
            end
        end
    end
end

local function getName(k)
    if k == NULL_KEY then return "" end
    local ks = tostring(k)
    if nameCache[ks] then return nameCache[ks] end

    local n = ll.GetDisplayName(k)
    if n ~= "" and n ~= "???" then
        cacheName(k, n)
        return n
    end

    if activeNameQuery == NULL_KEY then
        activeNameQuery = ll.RequestDisplayName(k)
        activeQueryTarget = k
    end

    return ll.Key2Name(k)
end

-- Lifecycle

local function registerSelf()
    ll.LinksetDataWrite("policy:" .. PLUGIN_CONTEXT, lljson.encode({
        ["2"] = "Add Owner,Runaway",
        ["3"] = "Add Trustee,Rem Trustee,Release,Runaway: On,Runaway: Off",
        ["4"] = "Add Owner,Runaway,Add Trustee,Rem Trustee",
        ["5"] = "Transfer,Release,Runaway: On,Runaway: Off,Add Trustee,Rem Trustee"
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

-- Settings

local function extractKeysFromPairs(obj)
    -- obj is a JSON object decoded to table; extract keys (uuid strings)
    local keys = {}
    for k, _ in pairs(obj) do
        table.insert(keys, k)
    end
    return keys
end

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.kv then return end
    local kv = data.kv
    -- If kv is a string (nested JSON), decode it
    if type(kv) == "string" then
        kv = lljson.decode(kv)
        if not kv then return end
    end

    multiOwnerMode = false
    ownerKey = NULL_KEY
    ownerKeys = {}
    ownerHonorific = ""
    ownerJson = "{}"
    ownersJson = "{}"
    trusteeKeys = {}
    trusteesJson = "{}"

    local tmp = kv[KEY_MULTI_OWNER_MODE]
    if tmp ~= nil then
        multiOwnerMode = (tonumber(tmp) or 0) ~= 0
    end

    if multiOwnerMode then
        local obj = kv[KEY_OWNERS]
        if obj ~= nil then
            if type(obj) == "string" then obj = lljson.decode(obj) end
            if type(obj) == "table" then
                ownersJson = lljson.encode(obj)
                ownerKeys = extractKeysFromPairs(obj)
            end
        end
    else
        local obj = kv[KEY_OWNER]
        if obj ~= nil then
            if type(obj) == "string" then obj = lljson.decode(obj) end
            if type(obj) == "table" then
                ownerJson = lljson.encode(obj)
                -- First key-value pair is uuid:honorific
                for k, v in pairs(obj) do
                    ownerKey = k
                    ownerHonorific = v
                    break
                end
            end
        end
    end

    -- Trustees
    local tObj = kv[KEY_TRUSTEES]
    if tObj ~= nil then
        if type(tObj) == "string" then tObj = lljson.decode(tObj) end
        if type(tObj) == "table" then
            trusteesJson = lljson.encode(tObj)
            trusteeKeys = extractKeysFromPairs(tObj)
        end
    end

    local lsdRunaway = ll.LinksetDataRead(KEY_RUNAWAY_ENABLED)
    if lsdRunaway ~= "" then
        runawayEnabled = (tonumber(lsdRunaway) or 0) ~= 0
    else
        tmp = kv[KEY_RUNAWAY_ENABLED]
        if tmp ~= nil then
            runawayEnabled = (tonumber(tmp) or 0) ~= 0
        else
            runawayEnabled = true
        end
        ll.LinksetDataWrite(KEY_RUNAWAY_ENABLED, runawayEnabled and "1" or "0")
    end
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data or not data.op then return end

    if data.op == "set" then
        local changes = data.changes
        if not changes then return end
        if type(changes) == "string" then changes = lljson.decode(changes) end
        if not changes then return end

        local tmp = changes[KEY_RUNAWAY_ENABLED]
        if tmp ~= nil then
            runawayEnabled = (tonumber(tmp) or 0) ~= 0
            ll.LinksetDataWrite(KEY_RUNAWAY_ENABLED, tostring(tmp))
        end

        -- Trustees changed
        local obj = changes[KEY_TRUSTEES]
        if obj ~= nil then
            if type(obj) == "string" then obj = lljson.decode(obj) end
            if type(obj) == "table" then
                trusteesJson = lljson.encode(obj)
                trusteeKeys = extractKeysFromPairs(obj)
            end
        end

        -- Single owner changed
        obj = changes[KEY_OWNER]
        if obj ~= nil then
            ownerKey = NULL_KEY
            ownerHonorific = ""
            ownerJson = "{}"
            if type(obj) == "string" then obj = lljson.decode(obj) end
            if type(obj) == "table" then
                ownerJson = lljson.encode(obj)
                for k, v in pairs(obj) do
                    ownerKey = k
                    ownerHonorific = v
                    break
                end
            end
        end

        -- Multi-owner changed
        obj = changes[KEY_OWNERS]
        if obj ~= nil then
            ownerKeys = {}
            ownersJson = "{}"
            if type(obj) == "string" then obj = lljson.decode(obj) end
            if type(obj) == "table" then
                ownersJson = lljson.encode(obj)
                ownerKeys = extractKeysFromPairs(obj)
            end
        end
    end
end

local function persistOwner(owner, hon)
    local obj = lljson.encode({[tostring(owner)] = hon})
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = KEY_OWNER,
        value = obj
    }), NULL_KEY)
end

local function addTrustee(trustee, hon)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "obj_set",
        key = KEY_TRUSTEES,
        field = tostring(trustee),
        value = hon
    }), NULL_KEY)
end

local function removeTrustee(trustee)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "obj_remove",
        key = KEY_TRUSTEES,
        field = tostring(trustee)
    }), NULL_KEY)
end

local function clearOwner()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = KEY_OWNER,
        value = "{}"
    }), NULL_KEY)
end

-- Forward declarations
local showMain
local cleanup
local handleButton
local showCandidates
local showRemoveTrustee

-- Cleanup

cleanup = function()
    if sessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
            type = "dialog_close",
            session_id = sessionId
        }), NULL_KEY)
    end
    currentUser = NULL_KEY
    userAcl = -999
    policyButtons = {}
    sessionId = ""
    menuContext = ""
    pendingCandidate = NULL_KEY
    pendingHonorific = ""
    candidateKeys = {}
end

-- Menus

showMain = function()
    sessionId = genSession()
    menuContext = "main"

    policyButtons = getPolicyButtons(PLUGIN_CONTEXT, userAcl)

    local body = "Owner Management\n\n"

    if hasOwner() then
        if multiOwnerMode then
            body = body .. "Multi-owner: " .. tostring(#ownerKeys) .. "\n"
        else
            body = body .. "Owner: " .. getName(ownerKey)
            if ownerHonorific ~= "" then body = body .. " (" .. ownerHonorific .. ")" end
        end
    else
        body = body .. "Unowned"
    end

    body = body .. "\nTrustees: " .. tostring(#trusteeKeys)

    local buttons = {"Back"}

    if btnAllowed("Add Owner") and currentUser == ll.GetOwner() and not hasOwner() then
        table.insert(buttons, "Add Owner")
    end

    if btnAllowed("Runaway") and currentUser == ll.GetOwner() and hasOwner() and runawayEnabled and not multiOwnerMode then
        table.insert(buttons, "Runaway")
    end

    if btnAllowed("Transfer") and isOwner(currentUser) and not multiOwnerMode then
        table.insert(buttons, "Transfer")
    end

    if btnAllowed("Release") and isOwner(currentUser) then
        table.insert(buttons, "Release")
    end

    if isOwner(currentUser) then
        if runawayEnabled and btnAllowed("Runaway: On") then
            table.insert(buttons, "Runaway: On")
        elseif not runawayEnabled and btnAllowed("Runaway: Off") then
            table.insert(buttons, "Runaway: Off")
        end
    end

    if btnAllowed("Add Trustee") then table.insert(buttons, "Add Trustee") end
    if btnAllowed("Rem Trustee") then table.insert(buttons, "Rem Trustee") end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = PLUGIN_LABEL,
        body = body,
        buttons = lljson.encode(buttons),
        timeout = 60
    }), NULL_KEY)
end

showCandidates = function(context, title, prompt)
    if #candidateKeys == 0 then
        ll.RegionSayTo(currentUser, 0, "No nearby avatars found.")
        showMain()
        return
    end

    local names = {}
    local i = 1
    while i <= #candidateKeys and i <= MAX_NUMBERED_LIST_ITEMS do
        table.insert(names, getName(candidateKeys[i]))
        i = i + 1
    end

    sessionId = genSession()
    menuContext = context

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        dialog_type = "numbered_list",
        session_id = sessionId,
        user = tostring(currentUser),
        title = title,
        prompt = prompt,
        items = lljson.encode(names),
        timeout = 60
    }), NULL_KEY)
end

local function showHonorific(target, context)
    pendingCandidate = target
    sessionId = genSession()
    menuContext = context

    local choices = OWNER_HONORIFICS
    if context == "trustee_hon" then choices = TRUSTEE_HONORIFICS end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        dialog_type = "numbered_list",
        session_id = sessionId,
        user = tostring(target),
        title = "Honorific",
        prompt = "What would you like to be called?",
        items = lljson.encode(choices),
        timeout = 60
    }), NULL_KEY)
end

local function showConfirm(title, body, context)
    sessionId = genSession()
    menuContext = context

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        session_id = sessionId,
        user = tostring(currentUser),
        title = title,
        body = body,
        buttons = lljson.encode({"Yes", "No"}),
        timeout = 60
    }), NULL_KEY)
end

showRemoveTrustee = function()
    if #trusteeKeys == 0 then
        ll.RegionSayTo(currentUser, 0, "No trustees.")
        showMain()
        return
    end

    local names = {}
    local i = 1
    while i <= #trusteeKeys and i <= MAX_NUMBERED_LIST_ITEMS do
        local trusteeUuid = trusteeKeys[i]
        local name = getName(trusteeUuid)
        local trusteesData = lljson.decode(trusteesJson)
        if trusteesData then
            local hon = trusteesData[trusteeUuid]
            if hon and hon ~= "" then
                name = name .. " (" .. hon .. ")"
            end
        end
        table.insert(names, name)
        i = i + 1
    end

    sessionId = genSession()
    menuContext = "remove_trustee"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
        type = "dialog_open",
        dialog_type = "numbered_list",
        session_id = sessionId,
        user = tostring(currentUser),
        title = "Remove Trustee",
        prompt = "Select to remove:",
        items = lljson.encode(names),
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
        else
            showMain()
        end
        return
    end

    if menuContext == "main" then
        if btn == "Add Owner" then
            menuContext = "set_scan"
            candidateKeys = {}
            ll.Sensor("", NULL_KEY, AGENT, 10.0, PI)
        elseif btn == "Transfer" then
            menuContext = "transfer_scan"
            candidateKeys = {}
            ll.Sensor("", NULL_KEY, AGENT, 10.0, PI)
        elseif btn == "Release" then
            showConfirm("Confirm Release", "Release " .. getName(ll.GetOwner()) .. "?", "release_owner")
        elseif btn == "Runaway" then
            showConfirm("Confirm Runaway", "Run away from " .. getName(getPrimaryOwner()) .. "?\n\nThis removes ownership without consent.", "runaway")
        elseif btn == "Runaway: On" or btn == "Runaway: Off" then
            if runawayEnabled then
                local hon = ownerHonorific
                if hon == "" then hon = "Owner" end

                local msgBody = "Your " .. hon .. " wants to disable runaway for you.\n\nPlease confirm."

                sessionId = genSession()
                menuContext = "runaway_disable_confirm"

                ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
                    type = "dialog_open",
                    session_id = sessionId,
                    user = tostring(ll.GetOwner()),
                    title = "Disable Runaway",
                    body = msgBody,
                    buttons = lljson.encode({"Yes", "No"}),
                    timeout = 60
                }), NULL_KEY)
            else
                runawayEnabled = true
                ll.LinksetDataWrite(KEY_RUNAWAY_ENABLED, "1")

                ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
                    type = "set",
                    key = KEY_RUNAWAY_ENABLED,
                    value = "1"
                }), NULL_KEY)

                ll.RegionSayTo(currentUser, 0, "Runaway enabled.")
                showMain()
            end
            return
        elseif btn == "Add Trustee" then
            menuContext = "trustee_scan"
            candidateKeys = {}
            ll.Sensor("", NULL_KEY, AGENT, 10.0, PI)
        elseif btn == "Rem Trustee" then
            showRemoveTrustee()
        end
        return
    end

    local idx = tonumber(btn)
    if idx then idx = idx end  -- already a number

    if menuContext == "set_select" then
        if idx and idx >= 1 and idx <= #candidateKeys then
            pendingCandidate = candidateKeys[idx]
            sessionId = genSession()
            menuContext = "set_accept"

            ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
                type = "dialog_open",
                session_id = sessionId,
                user = tostring(pendingCandidate),
                title = "Accept Ownership",
                body = getName(ll.GetOwner()) .. " wishes to submit to you.\n\nAccept?",
                buttons = lljson.encode({"Yes", "No"}),
                timeout = 60
            }), NULL_KEY)
        end
    elseif menuContext == "set_accept" then
        if btn == "Yes" then
            showHonorific(pendingCandidate, "set_hon")
        else
            ll.RegionSayTo(currentUser, 0, "Declined.")
            showMain()
        end
    elseif menuContext == "set_hon" then
        if idx and idx >= 1 and idx <= #OWNER_HONORIFICS then
            pendingHonorific = OWNER_HONORIFICS[idx]
            sessionId = genSession()
            menuContext = "set_confirm"

            ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
                type = "dialog_open",
                session_id = sessionId,
                user = tostring(ll.GetOwner()),
                title = "Confirm",
                body = "Submit to " .. getName(pendingCandidate) .. " as your " .. pendingHonorific .. "?",
                buttons = lljson.encode({"Yes", "No"}),
                timeout = 60
            }), NULL_KEY)
        end
    elseif menuContext == "set_confirm" then
        if btn == "Yes" then
            persistOwner(pendingCandidate, pendingHonorific)
            ll.RegionSayTo(pendingCandidate, 0, getName(ll.GetOwner()) .. " has submitted to you as their " .. pendingHonorific .. ".")
            ll.RegionSayTo(ll.GetOwner(), 0, "You are now property of " .. pendingHonorific .. " " .. getName(pendingCandidate) .. ".")
            cleanup()
            ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
                type = "return",
                user = tostring(currentUser)
            }), NULL_KEY)
        else
            showMain()
        end
    elseif menuContext == "transfer_select" then
        if idx and idx >= 1 and idx <= #candidateKeys then
            pendingCandidate = candidateKeys[idx]
            sessionId = genSession()
            menuContext = "transfer_accept"

            ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
                type = "dialog_open",
                session_id = sessionId,
                user = tostring(pendingCandidate),
                title = "Accept Transfer",
                body = "Accept ownership of " .. getName(ll.GetOwner()) .. "?",
                buttons = lljson.encode({"Yes", "No"}),
                timeout = 60
            }), NULL_KEY)
        end
    elseif menuContext == "transfer_accept" then
        if btn == "Yes" then
            showHonorific(pendingCandidate, "transfer_hon")
        else
            ll.RegionSayTo(currentUser, 0, "Declined.")
            showMain()
        end
    elseif menuContext == "transfer_hon" then
        if idx and idx >= 1 and idx <= #OWNER_HONORIFICS then
            pendingHonorific = OWNER_HONORIFICS[idx]
            local old = ownerKey
            persistOwner(pendingCandidate, pendingHonorific)
            ll.RegionSayTo(old, 0, "You have transferred " .. getName(ll.GetOwner()) .. " to " .. getName(pendingCandidate) .. ".")
            ll.RegionSayTo(pendingCandidate, 0, getName(ll.GetOwner()) .. " is now your property as " .. pendingHonorific .. ".")
            ll.RegionSayTo(ll.GetOwner(), 0, "You are now property of " .. pendingHonorific .. " " .. getName(pendingCandidate) .. ".")
            cleanup()
        end
    elseif menuContext == "release_owner" then
        if btn == "Yes" then
            sessionId = genSession()
            menuContext = "release_wearer"

            ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
                type = "dialog_open",
                session_id = sessionId,
                user = tostring(ll.GetOwner()),
                title = "Confirm Release",
                body = "Released by " .. getName(currentUser) .. ".\n\nConfirm freedom?",
                buttons = lljson.encode({"Yes", "No"}),
                timeout = 60
            }), NULL_KEY)
        else
            showMain()
        end
    elseif menuContext == "release_wearer" then
        if btn == "Yes" then
            clearOwner()
            ll.RegionSayTo(ll.GetOwner(), 0, "Released. You are free.")
            cleanup()
        else
            ll.RegionSayTo(currentUser, 0, "Release cancelled.")
            cleanup()
        end
    elseif menuContext == "runaway" then
        if btn == "Yes" then
            local old = getPrimaryOwner()
            local oldHon = ownerHonorific
            clearOwner()

            -- Clear ownership-scoped settings: trustees, lock, TPE
            ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
                type = "set", key = KEY_TRUSTEES, value = "{}"
            }), NULL_KEY)
            ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
                type = "set", key = "lock.locked", value = "0"
            }), NULL_KEY)
            ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
                type = "set", key = "tpe.mode", value = "0"
            }), NULL_KEY)

            if old ~= NULL_KEY then
                local notifyMsg = "You have run away from "
                if oldHon ~= "" then notifyMsg = notifyMsg .. oldHon .. " " end
                notifyMsg = notifyMsg .. getName(old) .. "."
                ll.RegionSayTo(ll.GetOwner(), 0, notifyMsg)
                ll.RegionSayTo(old, 0, getName(ll.GetOwner()) .. " ran away.")
            else
                ll.RegionSayTo(ll.GetOwner(), 0, "You have run away.")
            end

            ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, lljson.encode({
                type = "soft_reset"
            }), NULL_KEY)

            cleanup()
        else
            showMain()
        end
    elseif menuContext == "runaway_disable_confirm" then
        if btn == "Yes" then
            runawayEnabled = false
            ll.LinksetDataWrite(KEY_RUNAWAY_ENABLED, "0")

            ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
                type = "set",
                key = KEY_RUNAWAY_ENABLED,
                value = "0"
            }), NULL_KEY)

            ll.RegionSayTo(ll.GetOwner(), 0, "Runaway disabled.")
            ll.RegionSayTo(currentUser, 0, "Runaway disabled.")
            showMain()
        else
            ll.RegionSayTo(ll.GetOwner(), 0, "You declined to disable runaway.")
            ll.RegionSayTo(currentUser, 0, getName(ll.GetOwner()) .. " declined to disable runaway.")
            showMain()
        end
    elseif menuContext == "trustee_select" then
        if idx and idx >= 1 and idx <= #candidateKeys then
            pendingCandidate = candidateKeys[idx]

            -- Check if already a trustee
            local alreadyTrustee = false
            for _, v in ipairs(trusteeKeys) do
                if v == tostring(pendingCandidate) then
                    alreadyTrustee = true
                    break
                end
            end

            if alreadyTrustee then
                ll.RegionSayTo(currentUser, 0, "Already trustee.")
                showMain()
                return
            end

            sessionId = genSession()
            menuContext = "trustee_accept"

            ll.MessageLinked(LINK_SET, DIALOG_BUS, lljson.encode({
                type = "dialog_open",
                session_id = sessionId,
                user = tostring(pendingCandidate),
                title = "Accept Trustee",
                body = getName(ll.GetOwner()) .. " wants you as trustee.\n\nAccept?",
                buttons = lljson.encode({"Yes", "No"}),
                timeout = 60
            }), NULL_KEY)
        end
    elseif menuContext == "trustee_accept" then
        if btn == "Yes" then
            showHonorific(pendingCandidate, "trustee_hon")
        else
            ll.RegionSayTo(currentUser, 0, "Declined.")
            showMain()
        end
    elseif menuContext == "trustee_hon" then
        if idx and idx >= 1 and idx <= #TRUSTEE_HONORIFICS then
            pendingHonorific = TRUSTEE_HONORIFICS[idx]
            addTrustee(pendingCandidate, pendingHonorific)
            ll.RegionSayTo(pendingCandidate, 0, "You are trustee of " .. getName(ll.GetOwner()) .. " as " .. pendingHonorific .. ".")
            ll.RegionSayTo(currentUser, 0, getName(pendingCandidate) .. " is trustee.")
            showMain()
        end
    elseif menuContext == "remove_trustee" then
        if idx and idx >= 1 and idx <= #trusteeKeys then
            local trustee = trusteeKeys[idx]
            removeTrustee(trustee)
            ll.RegionSayTo(currentUser, 0, "Removed.")
            ll.RegionSayTo(trustee, 0, "Removed as trustee.")
            showMain()
        end
    else
        showMain()
    end
end

-- Events

LLEvents:on("link_message", function(event)
    local num = event:getNum()
    local msg = event:getStr()
    local id = event:getID()

    local data = lljson.decode(msg)
    if not data or not data.type then return end
    local msgType = data.type

    if num == KERNEL_LIFECYCLE then
        if msgType == "register_now" then registerSelf()
        elseif msgType == "ping" then sendPong()
        end
    elseif num == SETTINGS_BUS then
        if msgType == "settings_sync" then applySettingsSync(msg)
        elseif msgType == "settings_delta" then applySettingsDelta(msg)
        end
    elseif num == UI_BUS then
        if msgType == "start" and data.context then
            if data.context == PLUGIN_CONTEXT then
                currentUser = id
                userAcl = tonumber(data.acl) or -999
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

LLEvents:on("sensor", function(events)
    if currentUser == NULL_KEY then return end

    local candidates = {}
    local wearer = ll.GetOwner()

    for _, evt in ipairs(events) do
        local k = evt:getKey()
        if k ~= wearer then
            table.insert(candidates, tostring(k))
        end
    end

    candidateKeys = candidates

    if menuContext == "set_scan" then
        showCandidates("set_select", "Set Owner", "Choose owner:")
    elseif menuContext == "transfer_scan" then
        showCandidates("transfer_select", "Transfer", "Choose new owner:")
    elseif menuContext == "trustee_scan" then
        showCandidates("trustee_select", "Add Trustee", "Choose trustee:")
    end
end)

LLEvents:on("no_sensor", function(event)
    if currentUser == NULL_KEY then return end
    candidateKeys = {}

    if menuContext == "set_scan" then
        showCandidates("set_select", "Set Owner", "Choose owner:")
    elseif menuContext == "transfer_scan" then
        showCandidates("transfer_select", "Transfer", "Choose new owner:")
    elseif menuContext == "trustee_scan" then
        showCandidates("trustee_select", "Add Trustee", "Choose trustee:")
    end
end)

LLEvents:on("dataserver", function(event)
    local qid = event:getKey()
    local eventData = event:getData()
    if qid ~= activeNameQuery then return end
    if eventData ~= "" and eventData ~= "???" then cacheName(activeQueryTarget, eventData) end
    activeNameQuery = NULL_KEY
    activeQueryTarget = NULL_KEY
end)

LLEvents:on("on_rez", function(event)
    ll.ResetScript()
end)

LLEvents:on("changed", function(event)
    local change = event:getChange()
    if bit32.btest(change, CHANGED_OWNER) then ll.ResetScript() end
end)

-- Initialization (state_entry equivalent)
runawayEnabled = lsdInt(KEY_RUNAWAY_ENABLED, 1) ~= 0
cleanup()
registerSelf()
ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
    type = "settings_get"
}), NULL_KEY)
