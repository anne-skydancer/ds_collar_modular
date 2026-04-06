--[[--------------------
MODULE: kmod_leash.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Leashing engine providing leash services to plugins
ARCHITECTURE: Consolidated message bus lanes (SLua port)
CHANGES:
- v0.10 rev 0: Initial SLua alpha port from LSL 1.10 rev 1
  Table-based JSON replaces llList2Json/llJsonGetValue.
  LLTimers replaces single-timer multiplexing.
--------------------]]

local AUTH_BUS = 700
local SETTINGS_BUS = 800
local UI_BUS = 900

-- Protocol constants
local LEASH_CHAN_LM = -8888
local LEASH_CHAN_DS = -192837465

local PLUGIN_CONTEXT = "core_leash"

-- Policy button labels (must match plugin_leash policy CSV entries)
local POL_CLIP     = "Clip"
local POL_TAKE     = "Take"
local POL_UNCLIP   = "Unclip"
local POL_PASS     = "Pass"
local POL_OFFER    = "Offer"
local POL_COFFLE   = "Coffle"
local POL_POST     = "Post"
local POL_SETTINGS = "Settings"

-- Leash mode constants
local MODE_AVATAR = 0
local MODE_COFFLE = 1
local MODE_POST = 2

-- Settings keys
local KEY_LEASHED = "leashed"
local KEY_LEASHER = "leasher_key"
local KEY_LEASH_LENGTH = "leash_length"
local KEY_LEASH_TURNTO = "leash_turnto"

-- Leash state
local leashed = false
local leasher = NULL_KEY
local leashLength = 3
local turnToFace = false
local leashMode = MODE_AVATAR
local leashTarget = NULL_KEY
local coffleTargetAvatar = NULL_KEY

-- Follow mechanics
local followActive = false
local lastTargetPos = ZERO_VECTOR
local lastDistance = -1.0
local controlsOk = false
local tickCount = 0

-- Turn-to-face throttling
local lastTurnAngle = -999.0
local TURN_THRESHOLD = 0.1

-- Holder protocol state machine
local HOLDER_STATE_IDLE = 0
local HOLDER_STATE_DS_PHASE = 1
local HOLDER_STATE_OC_PHASE = 2
local HOLDER_STATE_COMPLETE = 4

local holderState = 0
local holderPhaseStart = 0
local holderListen = 0
local holderListenOC = 0
local holderTarget = NULL_KEY
local holderSession = 0
local DS_PHASE_DURATION = 2.0
local OC_PHASE_DURATION = 2.0

-- Offsim detection & auto-reclip
local offsimDetected = false
local offsimStartTime = 0
local OFFSIM_GRACE = 6.0
local reclipScheduled = 0
local lastLeasher = NULL_KEY
local reclipAttempts = 0
local MAX_RECLIP_ATTEMPTS = 3

-- ACL verification system
local pendingActionUser = NULL_KEY
local pendingAction = ""
local pendingPassTarget = NULL_KEY
local aclPending = false
local pendingPassOriginalUser = NULL_KEY
local pendingIsOffer = false

-- Lockmeister authorization
local authorizedLmController = NULL_KEY

-- Yank rate limiting
local lastYankTime = 0
local YANK_COOLDOWN = 5.0

-- Timers
local FOLLOW_TICK = 2.0
local tickTimer = nil

-- -------------------- HELPERS --------------------

local function now()
    return ll.GetUnixTime()
end

local function jsonGet(jsonStr, k, defaultVal)
    local data = lljson.decode(jsonStr)
    if data and data[k] ~= nil then return tostring(data[k]) end
    return defaultVal
end

local function policyAllows(btnLabel, aclLevel)
    local policy = ll.LinksetDataRead("policy:" .. PLUGIN_CONTEXT)
    if policy == "" then return false end
    local data = lljson.decode(policy)
    if not data then return false end
    local csv = data[tostring(aclLevel)]
    if not csv then return false end
    local items = ll.CSV2List(csv)
    return (ll.ListFindList(items, {btnLabel}) ~= -1)
end

local function denyAccess(user, reason)
    ll.RegionSayTo(user, 0, "Access denied: " .. reason)
end

-- Forward declarations
local broadcastState
local stopFollow
local startFollow
local releaseLeashInternal
local followTick

-- -------------------- PROTOCOL MESSAGE HELPERS --------------------

local function setLockmeisterState(enabled, controller)
    local msg
    if enabled then
        msg = lljson.encode({
            type = "lm_enable",
            controller = tostring(controller)
        })
    else
        msg = lljson.encode({
            type = "lm_disable"
        })
    end
    ll.MessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY)
end

local function setParticlesState(active, target)
    local msg
    if active then
        msg = lljson.encode({
            type = "particles_start",
            source = PLUGIN_CONTEXT,
            target = tostring(target),
            style = "chain"
        })
    else
        msg = lljson.encode({
            type = "particles_stop",
            source = PLUGIN_CONTEXT
        })
    end
    ll.MessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY)
end

local function updateParticlesTarget(target)
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "particles_update",
        target = tostring(target)
    }), NULL_KEY)
end

local function sendOfferPending(target, originator)
    ll.MessageLinked(LINK_SET, UI_BUS, lljson.encode({
        type = "offer_pending",
        target = tostring(target),
        originator = tostring(originator)
    }), NULL_KEY)
end

-- -------------------- STATE MANAGEMENT HELPERS --------------------

local function persistSetting(settingKey, value)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "set",
        key = settingKey,
        value = value
    }), NULL_KEY)
end

local function persistLeashState(isLeashed, leasherKey)
    persistSetting(KEY_LEASHED, tostring(isLeashed and 1 or 0))
    persistSetting(KEY_LEASHER, tostring(leasherKey))
end

local function persistLength(length)
    persistSetting(KEY_LEASH_LENGTH, tostring(length))
end

local function persistTurnto(turnto)
    persistSetting(KEY_LEASH_TURNTO, tostring(turnto and 1 or 0))
end

broadcastState = function()
    local msg = lljson.encode({
        type = "leash_state",
        leashed = tostring(leashed and 1 or 0),
        leasher = tostring(leasher),
        length = tostring(leashLength),
        turnto = tostring(turnToFace and 1 or 0),
        mode = tostring(leashMode),
        target = tostring(leashTarget)
    })
    ll.MessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY)
end

local function setLeashState(user, mode, target, coffleTarget)
    leashed = true
    leasher = user
    lastLeasher = user
    leashMode = mode
    leashTarget = target
    coffleTargetAvatar = coffleTarget
    persistLeashState(true, user)
    broadcastState()
end

local function clampLeashLength(len)
    if len < 1 then return 1 end
    if len > 20 then return 20 end
    return len
end

local function closeAllHolderListens()
    if holderListen ~= 0 then
        ll.ListenRemove(holderListen)
        holderListen = 0
    end
    if holderListenOC ~= 0 then
        ll.ListenRemove(holderListenOC)
        holderListenOC = 0
    end
end

local function clearLeashState(clearReclip)
    leashed = false
    leasher = NULL_KEY
    leashMode = MODE_AVATAR
    leashTarget = NULL_KEY
    coffleTargetAvatar = NULL_KEY
    persistLeashState(false, NULL_KEY)
    holderTarget = NULL_KEY
    holderState = HOLDER_STATE_IDLE
    authorizedLmController = NULL_KEY
    closeAllHolderListens()

    if clearReclip then
        lastLeasher = NULL_KEY
        reclipScheduled = 0
        reclipAttempts = 0
    end

    setLockmeisterState(false, NULL_KEY)
    setParticlesState(false, NULL_KEY)
    stopFollow()
    broadcastState()
end

-- -------------------- NOTIFICATION HELPERS --------------------

local function notifyLeashAction(actor, actionMsg, ownerDetails)
    ll.RegionSayTo(actor, 0, actionMsg)

    if ownerDetails ~= "" then
        ll.OwnerSay(actionMsg .. " - " .. ownerDetails)
    else
        ll.OwnerSay(actionMsg)
    end
end

local function notifyLeashTransfer(fromUser, toUser, action)
    ll.RegionSayTo(fromUser, 0, "Leash " .. action .. " to " .. ll.Key2Name(toUser))
    ll.RegionSayTo(toUser, 0, "Leash received from " .. ll.Key2Name(fromUser))
    ll.OwnerSay("Leash " .. action .. " to " .. ll.Key2Name(toUser) .. " by " .. ll.Key2Name(fromUser))
end

-- -------------------- ACL VERIFICATION SYSTEM --------------------

local handleAclResult -- forward declaration
local requestAclForAction
local requestAclForPassTarget

requestAclForAction = function(user, action, passTarget)
    aclPending = true
    pendingActionUser = user
    pendingAction = action
    pendingPassTarget = passTarget

    ll.MessageLinked(LINK_SET, AUTH_BUS, lljson.encode({
        type = "acl_query",
        avatar = tostring(user)
    }), user)
end

requestAclForPassTarget = function(target)
    pendingPassOriginalUser = pendingActionUser
    pendingActionUser = target
    pendingAction = "pass_target_check"
    aclPending = true

    ll.MessageLinked(LINK_SET, AUTH_BUS, lljson.encode({
        type = "acl_query",
        avatar = tostring(target)
    }), target)
end

-- Forward declarations for leash action internals
local grabLeashInternal
local passLeashInternal
local coffleLeashInternal
local postLeashInternal
local setLengthInternal
local toggleTurnInternal

handleAclResult = function(msg)
    if not aclPending then return end
    local data = lljson.decode(msg)
    if not data or not data.avatar or not data.level then return end

    local avatar = tokey(data.avatar)
    if avatar ~= pendingActionUser then return end

    local aclLevel = tonumber(data.level)
    aclPending = false

    -- Execute pending action with ACL verification

    -- Release: current leasher can always release (safety); otherwise policy-gated
    if pendingAction == "release" then
        if pendingActionUser == leasher or policyAllows(POL_UNCLIP, aclLevel) then
            releaseLeashInternal(pendingActionUser)
        else
            denyAccess(pendingActionUser, "only leasher or authorized users can release")
        end

    -- Special case: pass
    elseif pendingAction == "pass" then
        if pendingActionUser == leasher or policyAllows(POL_PASS, aclLevel) then
            requestAclForPassTarget(pendingPassTarget)
            return
        else
            denyAccess(pendingActionUser, "insufficient permissions to pass leash")
        end

    -- Special case: offer
    elseif pendingAction == "offer" then
        if policyAllows(POL_OFFER, aclLevel) and not leashed then
            pendingIsOffer = true
            requestAclForPassTarget(pendingPassTarget)
            return
        elseif leashed then
            ll.RegionSayTo(pendingActionUser, 0, "Cannot offer leash: already leashed.")
        else
            denyAccess(pendingActionUser, "insufficient permissions to offer leash")
        end

    -- Special case: pass_target_check
    elseif pendingAction == "pass_target_check" then
        if aclLevel >= 1 then
            if pendingIsOffer then
                sendOfferPending(pendingPassTarget, pendingPassOriginalUser)
            else
                passLeashInternal(pendingPassTarget)
            end
        else
            local actionName
            if pendingIsOffer then
                actionName = "offer"
            else
                actionName = "pass"
            end
            ll.RegionSayTo(pendingPassOriginalUser, 0, "Cannot " .. actionName .. " leash: target has insufficient permissions.")
        end

        pendingPassOriginalUser = NULL_KEY
        pendingIsOffer = false

    -- Standard ACL pattern for simple actions
    else
        local btnLabel = ""

        if pendingAction == "grab" then
            if leashed then btnLabel = POL_TAKE
            else btnLabel = POL_CLIP end
        elseif pendingAction == "coffle" then btnLabel = POL_COFFLE
        elseif pendingAction == "post" then btnLabel = POL_POST
        elseif pendingAction == "set_length" or pendingAction == "toggle_turn" then btnLabel = POL_SETTINGS
        end

        if btnLabel ~= "" and policyAllows(btnLabel, aclLevel) then
            if pendingAction == "grab" then grabLeashInternal(pendingActionUser, aclLevel)
            elseif pendingAction == "coffle" then coffleLeashInternal(pendingActionUser, pendingPassTarget)
            elseif pendingAction == "post" then postLeashInternal(pendingActionUser, pendingPassTarget)
            elseif pendingAction == "set_length" then setLengthInternal(tonumber(tostring(pendingPassTarget)) or 0)
            elseif pendingAction == "toggle_turn" then toggleTurnInternal()
            end
        else
            denyAccess(pendingActionUser, "insufficient permissions")
        end
    end

    -- Clear pending state
    pendingActionUser = NULL_KEY
    pendingAction = ""
    pendingPassTarget = NULL_KEY
    pendingIsOffer = false
end

-- -------------------- DS HOLDER PROTOCOL --------------------

local function beginHolderHandshake(user)
    holderSession = math.floor(ll.Frand(9.0e06))
    holderState = HOLDER_STATE_DS_PHASE
    holderPhaseStart = now()

    if holderListen == 0 then
        holderListen = ll.Listen(LEASH_CHAN_DS, "", NULL_KEY, "")
    end

    local msg = lljson.encode({
        type = "leash_req",
        wearer = tostring(ll.GetOwner()),
        collar = tostring(ll.GetKey()),
        controller = tostring(user),
        session = tostring(holderSession),
        origin = "leashpoint"
    })
    ll.RegionSay(LEASH_CHAN_DS, msg)
end

local function handleHolderResponseDs(msg)
    if holderState ~= HOLDER_STATE_DS_PHASE and holderState ~= HOLDER_STATE_OC_PHASE then return end
    local data = lljson.decode(msg)
    if not data then return end
    if data.type ~= "leash_target" then return end
    if data.ok ~= "1" then return end
    local session = tonumber(data.session)
    if session ~= holderSession then return end

    holderTarget = tokey(data.holder)

    holderState = HOLDER_STATE_COMPLETE
    closeAllHolderListens()

    setParticlesState(true, holderTarget)
end

local function handleHolderResponseOc(holderPrim, msg)
    if holderState ~= HOLDER_STATE_OC_PHASE then return end
    local expected = tostring(leasher) .. "handle ok"
    if msg ~= expected then return end

    holderTarget = holderPrim

    holderState = HOLDER_STATE_COMPLETE
    closeAllHolderListens()

    setParticlesState(true, holderTarget)
end

local function advanceHolderStateMachine()
    if holderState == HOLDER_STATE_IDLE or holderState == HOLDER_STATE_COMPLETE then return end

    local elapsed = now() - holderPhaseStart

    if holderState == HOLDER_STATE_DS_PHASE then
        if elapsed >= DS_PHASE_DURATION then
            holderState = HOLDER_STATE_OC_PHASE
            holderPhaseStart = now()
            if holderListen ~= 0 then
                ll.ListenRemove(holderListen)
                holderListen = 0
            end
            if holderListenOC == 0 then
                holderListenOC = ll.Listen(LEASH_CHAN_LM, "", NULL_KEY, "")
            end

            ll.RegionSayTo(leasher, LEASH_CHAN_LM, tostring(leasher) .. "collar")
            ll.RegionSayTo(leasher, LEASH_CHAN_LM, tostring(leasher) .. "handle")
        end
    elseif holderState == HOLDER_STATE_OC_PHASE then
        if elapsed >= OC_PHASE_DURATION then
            holderState = HOLDER_STATE_COMPLETE
            closeAllHolderListens()

            if leasher.istruthy then
                setParticlesState(true, leasher)
            end
        end
    end
end

-- -------------------- OFFSIM DETECTION & AUTO-RECLIP --------------------

local function autoReleaseOffsim()
    clearLeashState(false)
    ll.OwnerSay("Auto-released (offsim)")
end

local function checkLeasherPresence()
    if not leashed or not leasher.istruthy then return end

    local nowTime = ll.GetUnixTime()

    local avatarPresent = (ll.GetAgentInfo(leasher) ~= 0)
    local holderPresent = false

    if holderTarget.istruthy then
        holderPresent = (#ll.GetObjectDetails(holderTarget, {OBJECT_POS}) > 0)
    end

    local present = avatarPresent or holderPresent

    if not avatarPresent and holderPresent and not offsimDetected then
        ll.OwnerSay("Leasher offline, leash held by object")
    end

    if not present then
        if not offsimDetected then
            offsimDetected = true
            offsimStartTime = nowTime
        elseif (nowTime - offsimStartTime) >= OFFSIM_GRACE then
            lastLeasher = leasher
            autoReleaseOffsim()
            reclipScheduled = nowTime + 2
            reclipAttempts = 0
        end
    elseif offsimDetected then
        offsimDetected = false
        offsimStartTime = 0
    end
end

local function checkAutoReclip()
    if reclipScheduled == 0 or now() < reclipScheduled then return end

    if reclipAttempts >= MAX_RECLIP_ATTEMPTS then
        reclipScheduled = 0
        lastLeasher = NULL_KEY
        reclipAttempts = 0
        return
    end

    if lastLeasher.istruthy and ll.GetAgentInfo(lastLeasher) ~= 0 then
        requestAclForAction(lastLeasher, "grab", NULL_KEY)
        reclipAttempts = reclipAttempts + 1
        reclipScheduled = now() + 2
    end
end

-- -------------------- SETTINGS PERSISTENCE --------------------

local function applySettingsSync(msg)
    local data = lljson.decode(msg)
    if not data or not data.settings then return end
    local s = data.settings
    if type(s) == "string" then s = lljson.decode(s) end
    if not s then return end

    if s[KEY_LEASHED] ~= nil then
        leashed = (tonumber(s[KEY_LEASHED]) or 0) ~= 0
    end
    if s[KEY_LEASHER] ~= nil then
        leasher = tokey(s[KEY_LEASHER])
    end
    if s[KEY_LEASH_LENGTH] ~= nil then
        leashLength = clampLeashLength(tonumber(s[KEY_LEASH_LENGTH]) or 3)
    end
    if s[KEY_LEASH_TURNTO] ~= nil then
        turnToFace = (tonumber(s[KEY_LEASH_TURNTO]) or 0) ~= 0
    end
end

local function applySettingsDelta(msg)
    local data = lljson.decode(msg)
    if not data then return end
    local settingKey = data.key or ""
    local value = data.value or ""
    if settingKey ~= "" and value ~= "" then
        if settingKey == KEY_LEASHED then leashed = (tonumber(value) or 0) ~= 0
        elseif settingKey == KEY_LEASHER then leasher = tokey(value)
        elseif settingKey == KEY_LEASH_LENGTH then leashLength = clampLeashLength(tonumber(value) or 3)
        elseif settingKey == KEY_LEASH_TURNTO then turnToFace = (tonumber(value) or 0) ~= 0
        end
    end
end

-- -------------------- LEASH ACTIONS (INTERNAL - CALLED AFTER ACL VERIFICATION) --------------------

grabLeashInternal = function(user, aclLevel)
    if leashed then
        if aclLevel >= 3 then
            ll.RegionSayTo(leasher, 0, "Leash taken by " .. ll.Key2Name(user))
        else
            ll.RegionSayTo(user, 0, "Already leashed to " .. ll.Key2Name(leasher))
            return
        end
    end

    setLeashState(user, MODE_AVATAR, NULL_KEY, NULL_KEY)
    beginHolderHandshake(user)

    authorizedLmController = user
    setLockmeisterState(true, user)

    startFollow()
    notifyLeashAction(user, "Leash grabbed", "by " .. ll.Key2Name(user))
end

releaseLeashInternal = function(user)
    if not leashed then
        ll.RegionSayTo(user, 0, "Not currently leashed.")
        return
    end

    clearLeashState(true)
    notifyLeashAction(user, "Leash released", "by " .. ll.Key2Name(user))
end

passLeashInternal = function(newLeasher)
    if not leashed then return end

    local oldLeasher = leasher

    setLeashState(newLeasher, MODE_AVATAR, NULL_KEY, NULL_KEY)

    beginHolderHandshake(newLeasher)

    authorizedLmController = newLeasher
    setLockmeisterState(true, newLeasher)

    notifyLeashTransfer(oldLeasher, newLeasher, "passed")
end

coffleLeashInternal = function(user, targetCollar)
    if leashed then
        ll.RegionSayTo(user, 0, "Already leashed. Unclip first.")
        return
    end

    local details = ll.GetObjectDetails(targetCollar, {OBJECT_POS, OBJECT_NAME, OBJECT_OWNER})
    if #details == 0 then
        ll.RegionSayTo(user, 0, "Target collar not found or out of range.")
        return
    end

    local collarOwner = ll.List2Key(details, 3)
    if not collarOwner.istruthy then
        ll.RegionSayTo(user, 0, "Cannot coffle: target collar has no owner.")
        return
    end
    if collarOwner == ll.GetOwner() then
        ll.RegionSayTo(user, 0, "Cannot coffle to yourself.")
        return
    end

    setLeashState(user, MODE_COFFLE, targetCollar, collarOwner)

    setParticlesState(true, targetCollar)

    startFollow()

    local targetName = ll.List2String(details, 2)
    notifyLeashAction(user, "Coffled to " .. ll.Key2Name(collarOwner), targetName)
end

postLeashInternal = function(user, postObject)
    if leashed then
        ll.RegionSayTo(user, 0, "Already leashed. Unclip first.")
        return
    end

    local details = ll.GetObjectDetails(postObject, {OBJECT_POS, OBJECT_NAME})
    if #details == 0 then
        ll.RegionSayTo(user, 0, "Post object not found or out of range.")
        return
    end

    setLeashState(user, MODE_POST, postObject, NULL_KEY)

    setParticlesState(true, postObject)

    startFollow()

    local objectName = ll.List2String(details, 2)
    notifyLeashAction(user, "Posted to " .. objectName, "by " .. ll.Key2Name(user))
end

local function yankToLeasher()
    if not leashed or not leasher.istruthy then return end

    local details = ll.GetObjectDetails(leasher, {OBJECT_POS})
    if #details == 0 then
        ll.OwnerSay("Cannot yank: leasher not in range.")
        return
    end

    local leasherPos = ll.List2Vector(details, 1)

    if controlsOk then
        ll.MoveToTarget(leasherPos, 0.1)
        ll.OwnerSay("Yanked to " .. ll.Key2Name(leasher))
        ll.RegionSayTo(leasher, 0, ll.Key2Name(ll.GetOwner()) .. " yanked to you.")
    else
        ll.OwnerSay("Cannot yank: controls not active.")
    end
end

setLengthInternal = function(length)
    if length < 1 then length = 1 end
    if length > 20 then length = 20 end
    leashLength = length
    persistLength(leashLength)
    broadcastState()
end

toggleTurnInternal = function()
    turnToFace = not turnToFace
    if not turnToFace then
        ll.OwnerSay("@setrot=clear")
        lastTurnAngle = -999.0
    end
    persistTurnto(turnToFace)
    broadcastState()
end

-- -------------------- FOLLOW MECHANICS --------------------

startFollow = function()
    if not leashed then return end

    followActive = true

    if leashMode == MODE_AVATAR and leasher.istruthy then
        ll.OwnerSay("@follow:" .. tostring(leasher) .. "=force")
    elseif leashMode == MODE_COFFLE and coffleTargetAvatar.istruthy then
        ll.OwnerSay("@follow:" .. tostring(coffleTargetAvatar) .. "=force")
    end

    ll.RequestPermissions(ll.GetOwner(), PERMISSION_TAKE_CONTROLS)
end

stopFollow = function()
    followActive = false
    ll.OwnerSay("@follow=clear")
    ll.StopMoveToTarget()
    lastTargetPos = ZERO_VECTOR
    lastDistance = -1.0
    lastTurnAngle = -999.0
end

local function turnToTarget(targetPos)
    if not turnToFace or not leashed then return end

    local wearerPos = ll.GetRootPosition()
    local direction = ll.VecNorm(targetPos - wearerPos)
    local angle = ll.Atan2(direction.y, direction.x)

    if math.abs(angle - lastTurnAngle) > TURN_THRESHOLD then
        ll.OwnerSay("@setrot:" .. tostring(angle) .. "=force")
        lastTurnAngle = angle
    end
end

followTick = function()
    if not followActive or not leashed then return end

    local targetPos
    local followTarget = NULL_KEY
    local targetKey = NULL_KEY

    if leashMode == MODE_AVATAR then
        followTarget = leasher
        if holderTarget.istruthy then
            targetKey = holderTarget
        else
            targetKey = leasher
        end
    elseif leashMode == MODE_COFFLE then
        followTarget = coffleTargetAvatar
        targetKey = coffleTargetAvatar
    elseif leashMode == MODE_POST then
        followTarget = leashTarget
        targetKey = leashTarget
    end

    if not targetKey.istruthy then return end

    local details = ll.GetObjectDetails(targetKey, {OBJECT_POS})

    -- Handle HolderTarget disappearing (special case for Avatar mode)
    if #details == 0 then
        if leashMode == MODE_AVATAR and targetKey == holderTarget then
            holderTarget = NULL_KEY
            updateParticlesTarget(leasher)
            targetKey = leasher
            details = ll.GetObjectDetails(targetKey, {OBJECT_POS})
        end
    end

    if #details == 0 then return end
    targetPos = ll.List2Vector(details, 1)

    local wearerPos = ll.GetRootPosition()
    local distance = ll.VecDist(wearerPos, targetPos)

    if controlsOk and distance > leashLength then
        local pullPos = targetPos + ll.VecNorm(wearerPos - targetPos) * leashLength * 0.98
        if ll.VecMag(pullPos - lastTargetPos) > 0.2 then
            ll.MoveToTarget(pullPos, 0.5)
            lastTargetPos = pullPos
        end
        if turnToFace and followTarget.istruthy then
            turnToTarget(targetPos)
        end
    elseif lastDistance >= 0.0 and lastDistance > leashLength then
        ll.StopMoveToTarget()
        lastTargetPos = ZERO_VECTOR
    end

    lastDistance = distance
end

-- -------------------- EVENT HANDLERS --------------------

local function init()
    closeAllHolderListens()
    holderTarget = NULL_KEY
    holderState = HOLDER_STATE_IDLE
    aclPending = false
    pendingActionUser = NULL_KEY
    pendingAction = ""
    pendingPassTarget = NULL_KEY
    authorizedLmController = NULL_KEY

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, lljson.encode({
        type = "settings_get"
    }), NULL_KEY)

    ll.RequestPermissions(ll.GetOwner(), PERMISSION_TAKE_CONTROLS)

    tickTimer = LLTimers:every(FOLLOW_TICK, function()
        advanceHolderStateMachine()

        tickCount = tickCount + 1
        if tickCount % 2 == 0 then
            if leashed then checkLeasherPresence() end
            if not leashed and reclipScheduled ~= 0 then checkAutoReclip() end
        end

        if followActive and leashed then followTick() end
    end)
end

LLEvents:on("on_rez", function(startParam)
    ll.ResetScript()
end)

LLEvents:on("changed", function(change)
    if bit32.btest(change, CHANGED_OWNER) then ll.ResetScript() end
end)

LLEvents:on("run_time_permissions", function(perm)
    if bit32.btest(perm, PERMISSION_TAKE_CONTROLS) then
        controlsOk = true
    end
end)

LLEvents:on("link_message", function(sender, num, msg, id)
    local data = lljson.decode(msg)
    if not data or not data.type then return end
    local msgType = data.type

    if num == UI_BUS then

        if msgType == "leash_action" then
            local action = data.action or ""
            if action == "" then return end
            local user = id

            if action == "query_state" then
                broadcastState()
                return
            end

            if action == "yank" then
                if user == leasher then
                    local nowTime = ll.GetUnixTime()
                    if (nowTime - lastYankTime) < YANK_COOLDOWN then
                        local waitTime = math.floor(YANK_COOLDOWN - (nowTime - lastYankTime))
                        ll.RegionSayTo(user, 0, "Yank on cooldown. Wait " .. tostring(waitTime) .. "s.")
                        return
                    end
                    lastYankTime = nowTime
                    yankToLeasher()
                else
                    ll.RegionSayTo(user, 0, "Only the current leasher can yank.")
                end
                return
            end

            local target = tokey(data.target or tostring(NULL_KEY))

            if action == "set_length" then
                target = tokey(data.length or "0")
            end

            requestAclForAction(user, action, target)
            return
        end

        if msgType == "emergency_leash_release" then
            if id == ll.GetOwner() then
                releaseLeashInternal(id)
            end
            return
        end

        if msgType == "lm_grabbed" then
            local controller = tokey(data.controller or tostring(NULL_KEY))
            if not controller.istruthy then return end

            if controller ~= authorizedLmController then
                return
            end

            if not leashed then
                leashed = true
                leasher = controller
                lastLeasher = controller
                persistLeashState(true, controller)
                startFollow()
                ll.OwnerSay("Leashed by " .. ll.Key2Name(controller) .. " (Lockmeister)")
                broadcastState()
            end
            return
        end

        if msgType == "lm_released" then
            if leashed then
                local oldLeasher = leasher
                leashed = false
                leasher = NULL_KEY
                persistLeashState(false, NULL_KEY)
                authorizedLmController = NULL_KEY
                stopFollow()
                ll.OwnerSay("Released by " .. ll.Key2Name(oldLeasher) .. " (Lockmeister)")
                broadcastState()
            end
            return
        end
        return
    end

    if num == AUTH_BUS then
        if msgType == "acl_result" then
            handleAclResult(msg)
        end
        return
    end

    if num == SETTINGS_BUS then
        if msgType == "settings_sync" then applySettingsSync(msg)
        elseif msgType == "settings_delta" then applySettingsDelta(msg) end
        return
    end
end)

LLEvents:on("listen", function(channel, name, id, msg)
    if channel == LEASH_CHAN_DS then
        handleHolderResponseDs(msg)
    elseif channel == LEASH_CHAN_LM then
        handleHolderResponseOc(id, msg)
    end
end)

-- Initialize
init()
