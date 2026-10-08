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

function Net.Queue(op)
    LIVE.queue[#LIVE.queue + 1] = Rules.EncodeOp(op)
end

-- dest: "GROUP" or "GUILD".
function Net.QueueCatalog(op, dest)
    local lane = dest == "GUILD" and CAT_GUILD or CAT_GROUP
    if #lane.queue < 5000 then -- a full catalogue is about this size; never grow past it
        lane.queue[#lane.queue + 1] = Rules.EncodeOp(op)
    end
end

local SUCCESS = Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success or 0

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
    local msg = Rules.Pack(queue, LIMIT, 1)[1]
    if not msg then
        wipe(queue) -- nothing packable: every op was oversize
        return
    end
    local result = C_ChatInfo.SendAddonMessage(lane.prefix, msg, ch)
    if result ~= nil and result ~= SUCCESS then
        tokens[lane.prefix] = 0 -- throttled or blocked; back off and retry
        return
    end
    tokens[lane.prefix] = tokens[lane.prefix] - 1
    -- Drop the ops that went out: as many as the message holds, plus any
    -- oversize op Pack skipped on the way.
    local sent = select(2, msg:gsub("%^", "")) + 1
    while sent > 0 and queue[1] do
        if #queue[1] <= LIMIT then
            sent = sent - 1
        end
        table.remove(queue, 1)
    end
end

C_Timer.NewTicker(0.25, function()
    for prefix, n in pairs(tokens) do
        tokens[prefix] = math.min(BURST, n + REGEN * 0.25)
    end
    for _, lane in ipairs(lanes) do
        serve(lane)
    end
end)

-- The whole session, for a player who reloaded or joined late. It goes to
-- the whole group, so requests arriving close together (a raid logging in
-- at once) share one broadcast. The short window means a later requester is
-- never left unanswered; RequestSync also retries.
local lastSnapshot = 0
function Net.SendSnapshot()
    local now = GetTime()
    if now - lastSnapshot < 3 then
        return
    end
    lastSnapshot = now
    for _, op in ipairs(Rules.Snapshot(NS.S())) do
        Net.Queue(op)
    end
end

local GROUP_CHANNELS = { RAID = true, PARTY = true, INSTANCE_CHAT = true }

-- Whether a NEW from `sender` may replace our session.
local function acceptNew(S, op, sender)
    if op[3] ~= sender then
        return false -- a session can only be started in your own name
    end
    if S and S.id == op[2] and S.host == sender then
        return true -- the host resending its own session (a snapshot)
    end
    if S and S.phase ~= "ended" and S.host ~= sender then
        -- Taking over a running session wipes it for everyone, so only the
        -- group leader may do that, never an assistant.
        local r = NS.roster[sender]
        return r ~= nil and r.lead == true
    end
    return NS.IsLeadOrAssist(sender)
end

NS.On("CHAT_MSG_ADDON", function(prefix, msg, channel, sender)
    if prefix ~= PREFIX and prefix ~= CAT_PREFIX then
        return
    end
    if canaccessvalue and not canaccessvalue(msg, sender) then
        return
    end
    sender = NS.Full(sender)
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
            op[1] = kind:sub(2)
            NS.HandleRequest(sender, op)
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
        elseif S and sender == S.host then
            stateOps[#stateOps + 1] = op
        end
    end
    -- An op from the host that does not fit our copy means we missed
    -- something (a loading screen, a late join): fetch the whole session.
    if #stateOps > 0 and NS.ApplyOps(stateOps, false) > 0 then
        NS.RequestSync()
    end
end)
