-- RLC_Net.lua
-- Addon-message transport over the group channel.
--
-- Every outgoing op goes into one queue. A ticker packs as many queued ops as
-- fit into one message and sends it when:
--   * we are in a group (solo, ops only ever apply locally),
--   * chat messaging is not locked down (on this client addon messages are
--     blocked during encounters; the queue simply waits it out), and
--   * the local send budget allows it. The client throttles addon messages
--     per prefix; a refused send stays queued and is retried.
--
-- Trust: ops are accepted only from the session host (NEW only from the
-- group leader or an assistant). Requests ("?OP") are acted on only by the
-- host, which re-checks everything in Rules.Intent.
local _, NS = ...
local Rules = NS.Rules

local Net = {}
NS.Net = Net

-- Two prefixes, so a large catalogue upload never eats the send budget that
-- live rolls need (the client throttles per prefix).
local PREFIX = "RLC1" -- live session; trailing 1 = protocol version
local CAT_PREFIX = "RLCC" -- loot catalogue sharing
local LIMIT = 250 -- bytes per message; the client hard limit is 255
local BURST, REGEN = 6, 1 -- messages in a burst, messages per second after

-- MANDATORY on this client: without it CHAT_MSG_ADDON is never delivered
-- for a prefix, and the symptom is silence, not an error.
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
C_ChatInfo.RegisterAddonMessagePrefix(CAT_PREFIX)

local function groupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
end

local function guildChannel()
    return IsInGuild() and "GUILD" or nil
end

local tokens = { [PREFIX] = BURST, [CAT_PREFIX] = BURST }
-- Served in this order every tick, so live traffic always goes first.
local lanes = {
    { prefix = PREFIX, channel = groupChannel, queue = {} },
    { prefix = CAT_PREFIX, channel = groupChannel, queue = {} },
    { prefix = CAT_PREFIX, channel = guildChannel, queue = {} },
}
local LIVE, CAT_GROUP, CAT_GUILD = lanes[1], lanes[2], lanes[3]

-- Demo mode sends nothing: its session, history and catalogue are fake.
local function demo()
    return NS.Demo ~= nil and NS.Demo.active == true
end

function Net.Queue(op)
    if demo() then
        return
    end
    LIVE.queue[#LIVE.queue + 1] = Rules.EncodeOp(op)
end

-- dest: "GROUP" or "GUILD".
function Net.QueueCatalog(op, dest)
    if demo() then
        return
    end
    local lane = dest == "GUILD" and CAT_GUILD or CAT_GROUP
    -- A full catalogue (records plus its instance and boss lines) fits;
    -- the cap only stops a runaway. Dropping part of an answer would leave
    -- the asker with a hole nobody fills, since others saw it answered.
    if #lane.queue < 25000 then
        lane.queue[#lane.queue + 1] = Rules.EncodeOp(op)
    end
end

local RESULT = Enum.SendAddonMessageResult or {}
local SUCCESS = RESULT.Success or 0
-- Errors a retry can never fix: drop the message instead of blocking the lane.
local PERMANENT = {
    [RESULT.InvalidPrefix or 1] = true,
    [RESULT.InvalidMessage or 2] = true,
    [RESULT.InvalidChatType or 4] = true,
    [RESULT.TargetRequired or 6] = true,
    [RESULT.InvalidChannel or 7] = true,
    -- The server disagrees with IsInGroup / IsInGuild (mid group change):
    -- retrying the same message would only stall the lane.
    [RESULT.NotInGroup or 5] = true,
    [RESULT.NotInGuild or 10] = true,
}

-- Send one message from a lane if it can go now. Returns nothing.
local function serve(lane)
    local queue = lane.queue
    if #queue == 0 then
        return
    end
    local ch = lane.channel()
    if not ch then
        wipe(queue) -- not in a group / guild: nobody to send to
        return
    end
    if tokens[lane.prefix] < 1 or C_ChatInfo.InChatMessagingLockdown() then
        return
    end
    -- Catalogue sharing can wait out a fight; live rolls cannot.
    if lane.prefix == CAT_PREFIX and (InCombatLockdown() or C_InstanceEncounter.IsEncounterInProgress()) then
        return
    end
    local msg = Rules.Pack(queue, LIMIT, 1)[1]
    if not msg then
        wipe(queue) -- nothing packable: every op was oversize
        return
    end
    local result = C_ChatInfo.SendAddonMessage(lane.prefix, msg, ch)
    if result ~= nil and result ~= SUCCESS and not PERMANENT[result] then
        tokens[lane.prefix] = 0 -- throttled or blocked; back off and retry
        return
    end
    tokens[lane.prefix] = tokens[lane.prefix] - 1
    -- Drop the ops that went out: as many as the message holds, plus any
    -- oversize op Pack skipped on the way.
    local sent = select(2, msg:gsub("%^", "")) + 1
    local done = 0
    while sent > 0 and queue[done + 1] do
        done = done + 1
        if #queue[done] <= LIMIT then
            sent = sent - 1
        end
    end
    -- One shift for the whole message, not one per op: a catalogue queue
    -- holds thousands.
    local n = #queue
    for i = 1, n do
        queue[i] = queue[i + done]
    end
end

-- The whole session, for a player who reloaded or joined late. It goes to
-- the whole group, so every request made before it goes out (a raid logging
-- in at once, or one player spamming ?SYNC) shares one broadcast. It waits
-- for the live queue to empty, so snapshots never pile up behind each other.
local snapshotWanted, lastSnapshot = false, 0
function Net.SendSnapshot()
    snapshotWanted = true
end

-- For the bug report: ops waiting per lane, and the send budget left.
function Net.Status()
    return string.format(
        "queued live %d, catalogue group %d, guild %d; budget live %.1f, catalogue %.1f; channel %s",
        #LIVE.queue,
        #CAT_GROUP.queue,
        #CAT_GUILD.queue,
        tokens[PREFIX],
        tokens[CAT_PREFIX],
        groupChannel() or "none"
    )
end

C_Timer.NewTicker(0.25, function()
    for prefix, n in pairs(tokens) do
        tokens[prefix] = math.min(BURST, n + REGEN * 0.25)
    end
    -- One snapshot per 30 s for the whole group: it covers everyone who
    -- asked, and players taking turns asking cannot keep the queue full.
    if snapshotWanted and #LIVE.queue == 0 and GetTime() - lastSnapshot >= 30 then
        snapshotWanted, lastSnapshot = false, GetTime()
        local S = NS.S()
        if S then
            for _, op in ipairs(Rules.Snapshot(S)) do
                Net.Queue(op)
            end
        end
    end
    for _, lane in ipairs(lanes) do
        serve(lane)
    end
end)

local GROUP_CHANNELS = { RAID = true, PARTY = true, INSTANCE_CHAT = true }

-- Requests per sender: REQ_BURST at once, then one per REQ_EVERY seconds.
-- Each request can make the host broadcast an op, so one spamming raider
-- would otherwise eat the send budget live rolls need.
local REQ_BURST, REQ_EVERY = 8, 2
local reqBudget = {} -- sender -> { tokens, lastTime }
local function allowRequest(sender)
    local now = GetTime()
    local b = reqBudget[sender]
    if not b then
        b = { REQ_BURST, now }
        reqBudget[sender] = b
    end
    b[1] = math.min(REQ_BURST, b[1] + (now - b[2]) / REQ_EVERY)
    b[2] = now
    if b[1] < 1 then
        return false
    end
    b[1] = b[1] - 1
    return true
end

-- Whether a NEW from `sender` may replace our session (Rules.AcceptNew).
local newCtx = {
    isLead = function(name)
        local r = NS.roster[name]
        return r ~= nil and r.lead == true
    end,
    isLeadOrAssist = function(name)
        return NS.IsLeadOrAssist(name)
    end,
    recent = {},
}
local function acceptNew(S, op, sender)
    newCtx.now = GetServerTime()
    return Rules.AcceptNew(S, op, sender, newCtx)
end

NS.On("CHAT_MSG_ADDON", function(prefix, msg, channel, sender)
    if (prefix ~= PREFIX and prefix ~= CAT_PREFIX) or demo() then
        return
    end
    if not NS.CanRead(msg, sender) then
        return
    end
    NS.FlushRoster()
    sender = NS.Canon(sender)
    local me = NS.Me()
    if not sender or sender == me then
        return -- our own broadcast, echoed back
    end
    if prefix == CAT_PREFIX then
        if channel == "GUILD" or GROUP_CHANNELS[channel] then
            NS.Catalog.OnMessage(Rules.Decode(msg), channel == "GUILD" and "GUILD" or "GROUP", sender)
        end
        return
    end
    -- Live session traffic only counts from someone in our group, on a
    -- group channel. A whisper from outside could otherwise reserve items.
    if not GROUP_CHANNELS[channel] or not NS.roster[sender] then
        return
    end
    local S = NS.S()
    local stateOps = {}
    for _, op in ipairs(Rules.Decode(msg)) do
        local kind = op[1] or ""
        if kind:sub(1, 1) == "?" then
            if allowRequest(sender) then
                op[1] = kind:sub(2)
                NS.HandleRequest(sender, op)
            end
        elseif kind == "NOTE" or kind == "ERR" then
            if S and sender == S.host and (kind == "NOTE" or op[2] == me) then
                NS.Print(kind == "NOTE" and op[2] or op[3] or "")
            end
        elseif kind == "NEW" then
            -- Later ops in this message come from the new host.
            if acceptNew(S, op, sender) then
                S = Rules.Apply(nil, op)
                stateOps[#stateOps + 1] = op
            end
        elseif S and sender == S.host and S.phase ~= "ended" then
            -- An ended raid is saved history: its former host may not
            -- rewrite it. A snapshot still works: its NEW comes first.
            stateOps[#stateOps + 1] = op
        end
    end
    -- An op from the host that does not fit our copy means we missed
    -- something (a loading screen, a late join): fetch the whole session.
    if #stateOps > 0 and NS.ApplyOps(stateOps, false) > 0 then
        NS.RequestSync()
    end
end)
