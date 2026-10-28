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
-- Each lane's queue is read from `head`: sent ops stay in place (no shift,
-- and no holes that would break #queue) until the queue empties.
for _, lane in ipairs(lanes) do
    lane.head = 1
end
local function pending(lane)
    return #lane.queue - lane.head + 1
end

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
    if pending(lane) < 25000 then
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
    if pending(lane) <= 0 then
        wipe(queue)
        lane.head = 1
        return
    end
    local ch = lane.channel()
    if not ch then
        wipe(queue) -- not in a group / guild: nobody to send to
        lane.head = 1
        return
    end
    if tokens[lane.prefix] < 1 or C_ChatInfo.InChatMessagingLockdown() then
        return
    end
    -- Catalogue sharing can wait out a fight; live rolls cannot.
    if lane.prefix == CAT_PREFIX and (InCombatLockdown() or C_InstanceEncounter.IsEncounterInProgress()) then
        return
    end
    local last = math.min(#queue, lane.head + 300) -- more than one message holds
    local msg = Rules.Pack({ unpack(queue, lane.head, last) }, LIMIT, 1)[1]
    if not msg then
        lane.head = last + 1 -- nothing packable here: every op was oversize
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
    while sent > 0 and queue[lane.head] do
        if #queue[lane.head] <= LIMIT then
            sent = sent - 1
        end
        lane.head = lane.head + 1
    end
    if lane.head > #queue then
        wipe(queue) -- empty: start over at 1
        lane.head = 1
    end
end

-- The whole session, for a player who reloaded or joined late. It goes to
-- the whole group, so every request made before it goes out (a raid logging
-- in at once, or one player spamming ?SYNC) shares one broadcast. It waits
-- for the live queue to empty, so snapshots never pile up behind each other.
-- At most one per 120 s for the whole raid; 30 s when an asker has no
-- session at all (`urgent`: joined late, or reloaded with nothing saved).
-- The asker sets that flag, so it counts once per 5 min per asker.
local snapshotWanted, snapshotUrgent, snapshotSending, lastSnapshot = false, false, false, -600
local lastUrgent = {} -- asker -> GetTime() of their last urgent ask
function Net.SendSnapshot(urgent, who)
    snapshotWanted = true
    local now = GetTime()
    if urgent == true and now - (lastUrgent[who or ""] or -600) >= 300 then
        snapshotUrgent, lastUrgent[who or ""] = true, now
    end
end

-- Catalogue ops still waiting to go to "GROUP" or "GUILD": an answer is
-- skipped while the last one is still on its way.
function Net.CatalogBacklog(dest)
    return pending(dest == "GUILD" and CAT_GUILD or CAT_GROUP)
end

-- For the bug report: ops waiting per lane, and the send budget left.
function Net.Status()
    return string.format(
        "queued live %d, catalogue group %d, guild %d; budget live %.1f, catalogue %.1f; channel %s",
        pending(LIVE),
        pending(CAT_GROUP),
        pending(CAT_GUILD),
        tokens[PREFIX],
        tokens[CAT_PREFIX],
        groupChannel() or "none"
    )
end

C_Timer.NewTicker(0.25, function()
    for prefix, n in pairs(tokens) do
        tokens[prefix] = math.min(BURST, n + REGEN * 0.25)
    end
    -- One snapshot for the whole group, at least 30 s after the last one
    -- FINISHED sending: it covers everyone who asked, and players taking
    -- turns asking cannot keep the live lane busy with snapshots.
    local idle = pending(LIVE) <= 0
    if snapshotSending and idle then
        snapshotSending, lastSnapshot = false, GetTime()
    end
    local gap = snapshotUrgent and 30 or 120
    if snapshotWanted and not snapshotSending and idle and GetTime() - lastSnapshot >= gap then
        snapshotWanted, snapshotUrgent, snapshotSending = false, false, true
        local S = NS.S()
        if S then
            -- The NEW carries how many ops of the snapshot will arrive (the
            -- ones that fit a message), so a client that did not ask can
            -- skip exactly those. The queue was empty, so they go out first
            -- and in one run.
            local ops = Rules.Snapshot(S)
            local n = 0
            for _, op in ipairs(ops) do
                if #Rules.EncodeOp(op) <= LIMIT then
                    n = n + 1
                end
            end
            ops[1][6] = n
            for _, op in ipairs(ops) do
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
    known = function(id)
        return NS.DB.history[id] ~= nil
    end,
    recent = {},
}
local refusedNew = {} -- sender -> true: we refused their last NEW
-- A snapshot of the session we already hold that we did not ask for (sent
-- for someone else): { host, left = ops still to skip, untilT }.
local skipSnap
local function acceptNew(S, op, sender)
    newCtx.now, newCtx.me, newCtx.inRaid = GetServerTime(), NS.Me(), IsInRaid()
    return Rules.AcceptNew(S, op, sender, newCtx)
end
-- A loading screen can drop part of a snapshot: stop skipping, or the
-- host's next live ops would be counted off as snapshot ops.
NS.On("PLAYER_ENTERING_WORLD", function()
    skipSnap = nil
end)

NS.On("CHAT_MSG_ADDON", function(prefix, msg, channel, sender)
    -- Before any comparison: comparing a secret value throws.
    if not NS.CanRead(prefix, msg, channel, sender) then
        return
    end
    if (prefix ~= PREFIX and prefix ~= CAT_PREFIX) or demo() then
        return
    end
    NS.FlushRoster()
    -- The full spelling first: a newcomer sharing a first name must not
    -- silence a raider whose name has no surname.
    sender = NS.Canon(sender, true) or NS.Canon(sender)
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
    local stateOps, wantSync = {}, false
    for _, op in ipairs(Rules.Decode(msg)) do
        local kind = op[1] or ""
        local snapN = kind == "NEW" and Rules.Int(op[6], 1, 100000)
        if skipSnap and (skipSnap.left <= 0 or GetTime() > skipSnap.untilT) then
            skipSnap = nil
        end
        if skipSnap and sender == skipSnap.host and kind:sub(1, 1) ~= "?" then
            skipSnap.left = skipSnap.left - 1 -- part of a snapshot we already hold
            skipSnap.untilT = GetTime() + 30 -- a snapshot can take minutes to arrive
        elseif
            snapN
            and S
            and S.id == op[2]
            and S.host == sender
            and S.phase ~= "ended"
            and not NS.SyncAskedRecently()
        then
            -- Our own session resent for someone else: replaying it would
            -- wipe local-only state (attendance) and rejected replays would
            -- make us ask for yet another snapshot.
            -- No more than our own copy's snapshot could hold (with room for
            -- what changed since): a made-up count would freeze our updates.
            local most = 2 * #Rules.Snapshot(S) + 50
            skipSnap = { host = sender, left = math.min(snapN, most) - 1, untilT = GetTime() + 30 }
        elseif kind:sub(1, 1) == "?" then
            if allowRequest(sender) then
                op[1] = kind:sub(2)
                NS.HandleRequest(sender, op)
            end
        elseif kind == "NOTE" or kind == "ERR" then
            if S and sender == S.host and (kind == "NOTE" or op[2] == me) then
                local text = (kind == "NOTE" and op[2] or op[3]) or ""
                -- A host who does not (or no longer) leads the group gets no
                -- links, colours or extra lines.
                if S.untrusted or not NS.TrustedHost(S) then
                    text = text:gsub("[%c|]", " ")
                end
                NS.Print(text)
            end
        elseif kind == "NEW" then
            -- Later ops in this message come from the new host.
            refusedNew[sender] = nil
            if not acceptNew(S, op, sender) then
                refusedNew[sender] = true -- its later ops are not a missed NEW
            else
                S = Rules.Apply(nil, op)
                -- Not started by the group leader: never trusted for the
                -- roll-first list (Rules.RegularsFrom). ApplyOps makes its own
                -- table from the op, so the mark goes on the op.
                -- Small groups are handled by Rules.MIN_ATTEND on attendance.
                op.untrusted = not newCtx.isLead(sender) or nil
                stateOps[#stateOps + 1] = op
            end
        elseif S and sender == S.host and S.phase ~= "ended" then
            -- An ended raid is saved history: its former host may not
            -- rewrite it. A snapshot still works: its NEW comes first.
            stateOps[#stateOps + 1] = op
        elseif
            NS.IsLeadOrAssist(sender)
            and not refusedNew[sender]
            and (not S or (S.host == sender and S.autoEnded))
        then
            -- Session ops while we have no session, or from the host of a
            -- raid we only ended for age: we likely missed their NEW (a lost
            -- snapshot). Never for a sender whose NEW we refused, or a
            -- second host could keep the whole raid resyncing.
            wantSync = true
        end
    end
    -- An op from the host that does not fit our copy means we missed
    -- something (a loading screen, a late join): fetch the whole session.
    if (#stateOps > 0 and NS.ApplyOps(stateOps, false) > 0) or wantSync then
        NS.RequestSync()
    end
end)
