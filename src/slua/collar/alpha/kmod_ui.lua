--[[--------------------
MODULE: kmod_ui.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Session management, LSD policy filtering, and plugin list orchestration
ARCHITECTURE: Consolidated message bus lanes (SLua alpha port from LSL 1.10)
CHANGES:
- v0.10 rev 0: Alpha port from LSL kmod_ui.lsl v1.10. Converted parallel
  lists to table-based session/plugin management. Native SLua event model.
--------------------]]


-- ==================== CONSOLIDATED ABI ====================
local KERNEL_LIFECYCLE = 500
local AUTH_BUS = 700
local UI_BUS = 900
local DIALOG_BUS = 950

-- ==================== CONSTANTS ====================
local ROOT_CONTEXT = "core_root"
local SOS_CONTEXT = "sos_root"
local SOS_PREFIX = "sos_"
local MAX_FUNC_BTNS = 9
local TOUCH_RANGE_M = 5.0
local LONG_TOUCH_THRESHOLD = 1.5

local MAX_SESSIONS = 5
local SESSION_MAX_AGE = 60

-- Per-user ACL cache prefix written by kmod_auth.
-- Reading "acl_cache_<uuid>" skips the AUTH_BUS round-trip on touch.
-- Value format: "<level>|<unix_timestamp>"
-- CROSS-MODULE CONTRACT: must match LSD_ACL_CACHE_PREFIX in kmod_auth.
local LSD_ACL_CACHE_PREFIX = "acl_cache_"

-- ACL levels (mirrors auth module)
local ACL_BLACKLIST = -1
local ACL_NOACCESS = 0
local ACL_PUBLIC = 1
local ACL_OWNED = 2
local ACL_TRUSTEE = 3
local ACL_UNOWNED = 4
local ACL_PRIMARY_OWNER = 5


-- ==================== STATE ====================
-- Plugin registry: array of {context=string, label=string}
local plugins = {}

-- Sessions: keyed by user uuid string
-- Each session: {acl=int, blacklisted=bool, page=int, totalPages=int,
--                sessionId=string, filteredIndices={}, createdTime=int, context=string}
-- We also keep an ordered list of user keys for eviction
local sessions = {}
local sessionOrder = {}

-- Pending ACL requests: keyed by avatar uuid string -> context
local pendingAcl = {}

-- Touch tracking: keyed by toucher uuid string -> startTime
local touchData = {}

-- Plugin states: keyed by context -> state (integer)
local pluginStates = {}

-- Filtered plugin indices global pool removed; each session stores its own filtered list


-- ==================== HELPERS ====================

local function getMsgType(msg)
    local data = lljson.decode(msg)
    if data == nil then return "" end
    if data.type == nil then return "" end
    return data.type
end

local function validateRequiredFields(data, fieldNames)
    for _, field in ipairs(fieldNames) do
        if data[field] == nil then
            return false
        end
    end
    return true
end

local function generateSessionId(userKey)
    return "ui_" .. tostring(userKey) .. "_" .. tostring(ll.GetUnixTime())
end

-- ==================== PLUGIN STATE MANAGEMENT ====================

local function getPluginState(context)
    local st = pluginStates[context]
    if st == nil then
        return 0
    end
    return st
end

local function setPluginState(context, buttonState)
    pluginStates[context] = buttonState
end

-- ==================== FORWARD DECLARATIONS ====================
local sendRenderMenu
local cleanupSession
local createSession
local startRootSession
local startSosSession
local sendMessage

-- ==================== ACL CACHE MANAGEMENT ====================

local function tryCachedSession(userKey, contextFilter)
    local raw = ll.LinksetDataRead(LSD_ACL_CACHE_PREFIX .. tostring(userKey))
    if raw == "" then return false end
    local sep = string.find(raw, "|", 1, true)
    if sep == nil then return false end
    local level = tonumber(string.sub(raw, 1, sep - 1))
    if level == nil then return false end
    local isBlacklisted = (level == ACL_BLACKLIST)
    createSession(userKey, level, isBlacklisted, contextFilter)
    sendRenderMenu(userKey, contextFilter)
    return true
end

-- ==================== SESSION MANAGEMENT ====================

local function findSessionOrderIdx(userStr)
    for i, v in ipairs(sessionOrder) do
        if v == userStr then
            return i
        end
    end
    return nil
end

cleanupSession = function(userKey)
    local userStr = tostring(userKey)
    local session = sessions[userStr]
    if session == nil then return end

    -- Close dialog before cleaning up session
    local closeMsg = lljson.encode({
        type = "dialog_close",
        session_id = session.sessionId
    })
    ll.MessageLinked(LINK_SET, DIALOG_BUS, closeMsg, NULL_KEY)

    -- Remove session
    sessions[userStr] = nil
    local orderIdx = findSessionOrderIdx(userStr)
    if orderIdx ~= nil then
        table.remove(sessionOrder, orderIdx)
    end
end

createSession = function(userKey, acl, isBlacklisted, contextFilter)
    local userStr = tostring(userKey)

    -- Clean up existing session
    if sessions[userStr] ~= nil then
        cleanupSession(userKey)
    end

    -- Evict oldest if at capacity
    if #sessionOrder >= MAX_SESSIONS then
        local oldestStr = sessionOrder[1]
        cleanupSession(oldestStr)
    end

    -- Build filtered list based on LSD policy and context (SOS vs root)
    local filteredIndices = {}

    for i, plugin in ipairs(plugins) do
        local context = plugin.context
        local shouldInclude = false
        local isSosPlugin = (string.sub(context, 1, #SOS_PREFIX) == SOS_PREFIX)

        -- Check LSD policy for this plugin at the user's ACL level
        local policy = ll.LinksetDataRead("policy:" .. context)
        if policy ~= "" then
            local policyData = lljson.decode(policy)
            if policyData ~= nil then
                local csv = policyData[tostring(acl)]
                if csv ~= nil then
                    -- Policy exists for this ACL level -- apply context filter
                    if contextFilter == SOS_CONTEXT then
                        shouldInclude = isSosPlugin
                    else
                        shouldInclude = not isSosPlugin
                    end
                end
            end
        end

        if shouldInclude then
            table.insert(filteredIndices, i)
        end
    end

    local sessionId = generateSessionId(userKey)
    local createdTime = ll.GetUnixTime()

    sessions[userStr] = {
        acl = acl,
        blacklisted = isBlacklisted,
        page = 0,
        totalPages = 0,
        sessionId = sessionId,
        filteredIndices = filteredIndices,
        createdTime = createdTime,
        context = contextFilter
    }
    table.insert(sessionOrder, userStr)
end

-- ==================== PLUGIN LIST MANAGEMENT ====================

local function applyPluginList(pluginsJson)
    plugins = {}

    local pluginArray = lljson.decode(pluginsJson)
    if type(pluginArray) ~= "table" then
        return
    end

    -- Collect valid plugins
    local tempPlugins = {}
    for _, pluginObj in ipairs(pluginArray) do
        if type(pluginObj) == "table" and pluginObj.context ~= nil and pluginObj.label ~= nil then
            table.insert(tempPlugins, {
                context = pluginObj.context,
                label = pluginObj.label
            })
        end
    end

    -- Sort by label
    if #tempPlugins > 1 then
        table.sort(tempPlugins, function(a, b)
            return a.label < b.label
        end)
    end

    plugins = tempPlugins
end

-- ==================== MENU RENDERING ====================

sendMessage = function(userKey, messageText)
    local msg = lljson.encode({
        type = "show_message",
        user = tostring(userKey),
        message = messageText
    })
    ll.MessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY)
end

sendRenderMenu = function(userKey, menuType)
    local userStr = tostring(userKey)
    local session = sessions[userStr]
    if session == nil then return end

    local filteredIndices = session.filteredIndices
    local pluginCount = #filteredIndices

    if pluginCount == 0 then
        local userAcl = session.acl
        local isBlacklisted = session.blacklisted

        if menuType == SOS_CONTEXT then
            sendMessage(userKey, "No emergency options are currently available.")
        else
            if userAcl == -1 then
                if isBlacklisted then
                    sendMessage(userKey, "You have been barred from using this collar.")
                else
                    sendMessage(userKey, "This collar is not available for public use.")
                end
            elseif userAcl == 0 then
                sendMessage(userKey, "You have relinquished control of the collar.")
            else
                sendMessage(userKey, "No plugins are currently installed.")
            end
        end

        cleanupSession(userKey)
        return
    end

    local currentPage = session.page

    local totalPages = math.ceil(pluginCount / MAX_FUNC_BTNS)
    if currentPage >= totalPages then currentPage = 0 end
    if currentPage < 0 then currentPage = totalPages - 1 end

    -- Update session state
    session.page = currentPage
    session.totalPages = totalPages

    -- Build button data with context and state
    local buttonData = {}
    local startIdx = currentPage * MAX_FUNC_BTNS + 1
    local endIdx = startIdx + MAX_FUNC_BTNS - 1
    if endIdx > pluginCount then
        endIdx = pluginCount
    end

    for i = startIdx, endIdx do
        local pluginIdx = filteredIndices[i]
        local plugin = plugins[pluginIdx]

        local context = plugin.context
        local label = plugin.label
        local buttonState = getPluginState(context)

        local btnObj = {
            context = context,
            label = label,
            state = buttonState
        }
        table.insert(buttonData, btnObj)
    end

    local buttonsJson = lljson.encode(buttonData)
    local sessionId = session.sessionId

    -- DESIGN DECISION: Navigation row is ALWAYS present (DO NOT CHANGE)
    local hasNav = 1

    local msg = lljson.encode({
        type = "render_menu",
        user = tostring(userKey),
        session_id = sessionId,
        menu_type = menuType,
        page = currentPage,
        total_pages = totalPages,
        buttons = buttonsJson,
        has_nav = hasNav
    })

    ll.MessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY)
end

-- ==================== BUTTON HANDLING ====================

local function handleButtonClick(userKey, button, context)
    local userStr = tostring(userKey)
    local session = sessions[userStr]
    if session == nil then return end

    -- Blacklist gate
    if session.blacklisted then
        sendMessage(userKey, "You have been barred from using this collar.")
        cleanupSession(userKey)
        return
    end

    local currentPage = session.page
    local totalPages = session.totalPages
    local sessionContext = session.context

    -- Handle navigation buttons (no context)
    if button == "<<" then
        currentPage = currentPage - 1
        if currentPage < 0 then currentPage = totalPages - 1 end
        session.page = currentPage
        sendRenderMenu(userKey, sessionContext)
        return
    end

    if button == "Close" then
        cleanupSession(userKey)
        return
    end

    if button == ">>" then
        currentPage = currentPage + 1
        if currentPage >= totalPages then currentPage = 0 end
        session.page = currentPage
        sendRenderMenu(userKey, sessionContext)
        return
    end

    -- Plugin button clicked - use context directly for fast lookup
    if context ~= "" then
        -- Find plugin by context
        local foundIdx = nil
        for i, plugin in ipairs(plugins) do
            if plugin.context == context then
                foundIdx = i
            end
        end

        if foundIdx ~= nil then
            local userAcl = session.acl

            -- LSD policy filter -- verify user still has access
            local policy = ll.LinksetDataRead("policy:" .. context)
            if policy == "" then
                sendMessage(userKey, "Access denied.")
                return
            end
            local policyData = lljson.decode(policy)
            if policyData == nil then
                sendMessage(userKey, "Access denied.")
                return
            end
            local csv = policyData[tostring(userAcl)]
            if csv == nil then
                sendMessage(userKey, "Access denied.")
                return
            end

            local msg = lljson.encode({
                type = "start",
                context = context,
                user = tostring(userKey),
                acl = userAcl
            })

            ll.MessageLinked(LINK_SET, UI_BUS, msg, userKey)
            return
        end
        return
    end
end

-- ==================== PLUGIN LABEL UPDATE ====================

local function updatePluginLabel(context, newLabel)
    for _, plugin in ipairs(plugins) do
        if plugin.context == context then
            plugin.label = newLabel
            return
        end
    end
end

-- ==================== MESSAGE HANDLERS ====================

local function handlePluginList(msg)
    local data = lljson.decode(msg)
    if data == nil or data.plugins == nil then return end

    -- plugins field may be a string (JSON array) or already decoded table
    local pluginsJson
    if type(data.plugins) == "string" then
        pluginsJson = data.plugins
    else
        pluginsJson = lljson.encode(data.plugins)
    end
    applyPluginList(pluginsJson)

    -- Invalidate all sessions when plugin list changes
    if #sessionOrder > 0 then
        -- Close all dialogs before clearing sessions
        for _, userStr in ipairs(sessionOrder) do
            local session = sessions[userStr]
            if session ~= nil then
                local closeMsg = lljson.encode({
                    type = "dialog_close",
                    session_id = session.sessionId
                })
                ll.MessageLinked(LINK_SET, DIALOG_BUS, closeMsg, NULL_KEY)
            end
        end

        sessions = {}
        sessionOrder = {}
        pendingAcl = {}
    end
end

local function handleAclResult(msg)
    local data = lljson.decode(msg)
    if data == nil then return end
    if not validateRequiredFields(data, {"avatar", "level", "is_blacklisted"}) then return end

    local avatarStr = data.avatar
    local level = tonumber(data.level) or 0
    local isBlacklisted = (tonumber(data.is_blacklisted) or 0) ~= 0

    local requestedContext = pendingAcl[avatarStr]
    if requestedContext == nil then return end

    pendingAcl[avatarStr] = nil

    createSession(avatarStr, level, isBlacklisted, requestedContext)
    sendRenderMenu(avatarStr, requestedContext)
end

local function handleStart(msg, userKey)
    local data = lljson.decode(msg)
    if data == nil then
        startRootSession(userKey)
        return
    end

    if data.context == nil then
        startRootSession(userKey)
        return
    end

    local context = data.context

    if context == ROOT_CONTEXT then
        startRootSession(userKey)
        return
    end

    if context == SOS_CONTEXT then
        startSosSession(userKey)
        return
    end
end

startRootSession = function(userKey)
    local userStr = tostring(userKey)
    if pendingAcl[userStr] ~= nil then return end

    if tryCachedSession(userKey, ROOT_CONTEXT) then
        return
    end

    pendingAcl[userStr] = ROOT_CONTEXT

    local aclQuery = lljson.encode({
        type = "acl_query",
        avatar = tostring(userKey)
    })
    ll.MessageLinked(LINK_SET, AUTH_BUS, aclQuery, NULL_KEY)
end

startSosSession = function(userKey)
    local userStr = tostring(userKey)
    if pendingAcl[userStr] ~= nil then return end

    if tryCachedSession(userKey, SOS_CONTEXT) then
        return
    end

    pendingAcl[userStr] = SOS_CONTEXT

    local aclQuery = lljson.encode({
        type = "acl_query",
        avatar = tostring(userKey)
    })
    ll.MessageLinked(LINK_SET, AUTH_BUS, aclQuery, NULL_KEY)
end

local function handleReturn(msg)
    local data = lljson.decode(msg)
    if data == nil then return end
    if data.user == nil then return end
    local userKey = data.user
    local userStr = tostring(userKey)

    -- Re-validate stale sessions
    local session = sessions[userStr]
    if session ~= nil then
        local createdTime = session.createdTime
        local age = ll.GetUnixTime() - createdTime

        if age > SESSION_MAX_AGE then
            local sessionContext = session.context
            cleanupSession(userKey)

            if sessionContext == SOS_CONTEXT then
                startSosSession(userKey)
            else
                startRootSession(userKey)
            end
        else
            local sessionContext = session.context
            sendRenderMenu(userKey, sessionContext)
        end
    else
        startRootSession(userKey)
    end
end

local function handleUpdateLabel(msg)
    local data = lljson.decode(msg)
    if data == nil then return end
    if not validateRequiredFields(data, {"context", "label"}) then return end

    updatePluginLabel(data.context, data.label)
end

local function handleUpdateState(msg)
    local data = lljson.decode(msg)
    if data == nil then return end
    if not validateRequiredFields(data, {"context", "state"}) then return end

    local pluginState = tonumber(data.state) or 0
    setPluginState(data.context, pluginState)
end

local function handleDialogResponse(msg)
    local data = lljson.decode(msg)
    if data == nil then return end
    if not validateRequiredFields(data, {"session_id", "button", "user"}) then return end

    local sessionId = data.session_id
    local button = data.button
    local userKey = data.user

    -- Extract context (may be nil for navigation buttons)
    local context = data.context or ""

    -- Verify session exists by matching session_id
    local userStr = tostring(userKey)
    local session = sessions[userStr]
    if session ~= nil and session.sessionId == sessionId then
        handleButtonClick(userKey, button, context)
        return
    end

    -- Also check all sessions in case user key doesn't match directly
    for uStr, sess in pairs(sessions) do
        if sess.sessionId == sessionId then
            handleButtonClick(userKey, button, context)
            return
        end
    end
end

local function handleDialogTimeout(msg)
    local data = lljson.decode(msg)
    if data == nil then return end
    if not validateRequiredFields(data, {"session_id", "user"}) then return end

    local sessionId = data.session_id
    local userKey = data.user

    -- Find session with matching session_id
    local userStr = tostring(userKey)
    local session = sessions[userStr]
    if session ~= nil and session.sessionId == sessionId then
        cleanupSession(userKey)
        return
    end

    for uStr, sess in pairs(sessions) do
        if sess.sessionId == sessionId then
            cleanupSession(uStr)
            return
        end
    end
end

-- ==================== INITIALIZATION ====================

local function init()
    plugins = {}
    sessions = {}
    sessionOrder = {}
    pendingAcl = {}
    touchData = {}
    pluginStates = {}

    -- Request plugin list (kernel defers response during active registration)
    local request = lljson.encode({
        type = "plugin_list_request"
    })
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, request, NULL_KEY)
end

-- ==================== EVENTS ====================

LLEvents:on("touch_start", function(events)
    for _, event in ipairs(events) do
        local toucher = event:getKey()
        local touchPos = event:getTouchPos()

        -- Skip invalid touches
        if touchPos ~= ZERO_VECTOR then
            -- Validate touch distance
            local distance = ll.VecDist(touchPos, ll.GetPos())
            if distance <= TOUCH_RANGE_M then
                -- Record touch start time
                touchData[tostring(toucher)] = ll.GetTime()
            end
        end
    end
end)

LLEvents:on("touch_end", function(events)
    local wearer = ll.GetOwner()

    for _, event in ipairs(events) do
        local toucher = event:getKey()
        local toucherStr = tostring(toucher)

        local startTime = touchData[toucherStr]
        if startTime ~= nil then
            local duration = ll.GetTime() - startTime
            touchData[toucherStr] = nil

            if duration >= LONG_TOUCH_THRESHOLD and toucher == wearer then
                startSosSession(toucher)
            else
                -- Provide feedback if non-wearer attempted long-touch (SOS is wearer-only)
                if duration >= LONG_TOUCH_THRESHOLD and toucher ~= wearer then
                    sendMessage(toucher, "Long-touch SOS is only available to the wearer.")
                end
                startRootSession(toucher)
            end
        end
    end
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    local msgType = getMsgType(msg)
    if msgType == "" then return end

    -- KERNEL LIFECYCLE
    if num == KERNEL_LIFECYCLE then
        if msgType == "plugin_list" then
            handlePluginList(msg)
        elseif msgType == "soft_reset" or msgType == "soft_reset_all" then
            ll.ResetScript()
        end
        return
    end

    -- AUTH BUS
    if num == AUTH_BUS then
        if msgType == "acl_result" then
            handleAclResult(msg)
        elseif msgType == "acl_update" then
            -- ACL roles changed -- invalidate all active sessions
            local usersToClean = {}
            for _, userStr in ipairs(sessionOrder) do
                table.insert(usersToClean, userStr)
            end
            for i = #usersToClean, 1, -1 do
                cleanupSession(usersToClean[i])
            end
        end
        return
    end

    -- UI BUS
    if num == UI_BUS then
        if msgType == "start" then
            handleStart(msg, id)
        elseif msgType == "return" then
            handleReturn(msg)
        elseif msgType == "update_label" then
            handleUpdateLabel(msg)
        elseif msgType == "update_state" then
            handleUpdateState(msg)
        end
        return
    end

    -- DIALOG BUS
    if num == DIALOG_BUS then
        if msgType == "dialog_response" then
            handleDialogResponse(msg)
        elseif msgType == "dialog_timeout" then
            handleDialogTimeout(msg)
        end
        return
    end
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then
        ll.ResetScript()
    end
end)

-- Run initialization
init()
