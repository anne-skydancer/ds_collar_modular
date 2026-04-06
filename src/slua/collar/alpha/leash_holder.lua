--[[--------------------
SCRIPT: leash_holder.lua
VERSION: 0.10
REVISION: 0
PURPOSE: Minimal leash-holder target responder for external objects
ARCHITECTURE: Direct channel listener with prim discovery fallback (SLua port)
CHANGES:
- v0.1 rev 0: Initial SLua alpha port from LSL 1.10 rev 0
--------------------]]

-- Constants
local LEASH_HOLDER_CHAN = -192837465

-- State
local gListenHandle = 0

-- Helpers

local function primByName(wantLower)
    local n = ll.GetNumberOfPrims()
    local i = 2
    while i <= n do
        local nm = ll.ToLower(ll.GetLinkName(i))
        if nm == wantLower then return ll.GetLinkKey(i) end
        i = i + 1
    end
    return NULL_KEY
end

local function primByDesc(wantLower)
    local n = ll.GetNumberOfPrims()
    local i = 2
    while i <= n do
        local params = ll.GetLinkPrimitiveParams(i, {PRIM_DESC})
        local d = ll.ToLower(params[1])
        if d == wantLower then return ll.GetLinkKey(i) end
        i = i + 1
    end
    return NULL_KEY
end

-- Choose a leash point prim:
-- 1) child named "LeashPoint" (case-insensitive)
-- 2) child with description "leash:point" (case-insensitive)
-- 3) the prim this script is in (child or root)
local function leashPrimKey()
    local k = primByName("leashpoint")
    if k ~= NULL_KEY then return k end

    k = primByDesc("leash:point")
    if k ~= NULL_KEY then return k end

    local ln = ll.GetLinkNumber()
    if ln <= 0 then ln = 1 end -- attachments can report 0; root is 1
    return ll.GetLinkKey(ln)
end

local function openListen()
    if gListenHandle ~= 0 then ll.ListenRemove(gListenHandle) end
    gListenHandle = ll.Listen(LEASH_HOLDER_CHAN, "", NULL_KEY, "")
end

-- Events

local function init()
    openListen()
end

LLEvents:on("on_rez", function(startParam)
    ll.ResetScript()
end)

LLEvents:on("changed", function(changeMask)
    if bit32.btest(changeMask, bit32.bor(CHANGED_OWNER, CHANGED_REGION, CHANGED_REGION_START, CHANGED_TELEPORT)) then
        openListen()
    end
end)

LLEvents:on("listen", function(channel, name, id, message)
    if channel ~= LEASH_HOLDER_CHAN then return end

    local data = lljson.decode(message)
    if not data then return end
    if data.type ~= "leash_req" then return end

    local collar = tokey(data.collar)
    local session = tostring(data.session)

    local targetPrim = leashPrimKey()

    local reply = lljson.encode({
        type = "leash_target",
        ok = "1",
        holder = tostring(targetPrim),
        name = ll.GetObjectName(),
        session = session
    })

    ll.RegionSayTo(collar, LEASH_HOLDER_CHAN, reply)
end)

-- Initialize
init()
