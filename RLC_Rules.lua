-- RLC_Rules.lua
-- The loot rules and the raid session model.
--
-- Pure Lua 5.1: no WoW API calls, so tests/test_rules.lua loads this file
-- under stock lua5.1 and drives it with fixtures.
--
-- Two layers:
--   * Apply(S, op)  - the primitive state changes ("ops"). The host applies
--     each op locally and broadcasts it; every other client applies the same
--     op, so all copies of the session stay identical. Ops arrive from the
--     wire as arrays of strings, so Apply converts and validates every field.
--   * Intent(S, who, req, ctx) - what a player or officer ASKED for. Only the
--     host runs this. It checks permissions and the loot rules, then returns
--     the ops that carry the request out (or nil plus a reason).
--
-- The rules this addon exists for:
--   * Everyone gets one item before anyone gets two. Winning an item LOCKS
--     the winner for the rest of the raid. A reserve win counts too.
--   * A locked player can roll again only when the item is opened to all,
--     which happens when no unlocked eligible player wants it, or when an
--     officer opens it by hand. Officers can also unlock a player.
--   * A soft reserve made before the raid starts wins the item outright. If
--     several players reserved it, only they roll. Winning ANY item first
--     cancels the winner's reserve.
--   * An officer can restrict an item to some classes.
local NS = select(2, ...)

local Rules = {}
NS.Rules = Rules

local STATES = { pending = true, interest = true, rolling = true, done = true, cancelled = true }
local MODES = { normal = true, open = true, reserve = true }
local HOWS = { roll = true, open = true, reserve = true, manual = true }
Rules.MAX_ITEMS = 500 -- per raid session; far above any real raid

-- ---- small helpers -------------------------------------------------------

-- Class restriction mask: bit (classID - 1) set means that class may take
-- part. 0 means every class. Arithmetic rather than bit.band so this file
-- needs nothing from the client.
function Rules.HasClass(mask, classID)
    if not mask or mask == 0 then
        return true
    end
    if not classID then
        return false
    end
    return math.floor(mask / 2 ^ (classID - 1)) % 2 == 1
end

function Rules.ClassBit(classID)
    return 2 ^ (classID - 1)
end

-- Full player names only ("Name-Realm"). Anything else from the wire is junk.
function Rules.ValidName(s)
    return type(s) == "string" and #s <= 64 and s:match("^[^%s%-]+%-[^%s]+$") ~= nil
end

-- "item:12345:..." (the itemString inside a link). Links themselves never go
-- on the wire: an itemString is shorter and carries no colour codes.
function Rules.ValidItemString(s)
    return type(s) == "string" and #s <= 200 and s:match("^item:%d+[%d:%-]*$") ~= nil
end

function Rules.ItemIDOf(itemString)
    return tonumber(itemString:match("^item:(%d+)"))
end

local function bool(v)
    return v == 1 or v == "1" or v == true
end

-- Sorted comma list <-> set. Sorted so two clients encode one set identically.
function Rules.SetToCSV(set)
    if not set then
        return ""
    end
    local t = {}
    for name in pairs(set) do
        t[#t + 1] = name
    end
    table.sort(t)
    return table.concat(t, ",")
end

function Rules.CSVToSet(csv)
    if type(csv) ~= "string" or csv == "" then
        return nil
    end
    local set, any = {}, false
    for name in csv:gmatch("[^,]+") do
        if Rules.ValidName(name) then
            set[name] = true
            any = true
        end
    end
    return any and set or nil
end

-- ---- wire codec ------------------------------------------------------------
-- An op is fields joined by TAB; one addon message carries several ops
-- joined by "^". Neither character can appear in a name, a number or an
-- itemString; the raid title is the only free text and loses both.
local FS, OS = "\t", "^"

function Rules.EncodeOp(op)
    local t = {}
    for i = 1, #op do
        t[i] = tostring(op[i]):gsub("[\t%^]", "")
    end
    return table.concat(t, FS)
end

-- Pack encoded ops into as few messages as fit `limit` bytes each. An op
-- longer than the limit is dropped rather than truncated. With maxMsgs, stop
-- once that many messages are full (the sender only needs the first one).
function Rules.Pack(encoded, limit, maxMsgs)
    local msgs, cur = {}, nil
    for _, s in ipairs(encoded) do
        if #s <= limit then
            if cur and #cur + 1 + #s <= limit then
                cur = cur .. OS .. s
            else
                if cur then
                    msgs[#msgs + 1] = cur
                    if maxMsgs and #msgs >= maxMsgs then
                        return msgs
                    end
                end
                cur = s
            end
        end
    end
    if cur then
        msgs[#msgs + 1] = cur
    end
    return msgs
end

function Rules.Decode(msg)
    local ops = {}
    for chunk in msg:gmatch("[^%^]+") do
        local op = {}
        for field in (chunk .. FS):gmatch("([^\t]*)\t") do
            op[#op + 1] = field
        end
        ops[#ops + 1] = op
    end
    return ops
end

-- ---- roll lines ------------------------------------------------------------
-- Turns the client's RANDOM_ROLL_RESULT ("%s rolls %d (%d-%d)") into a Lua
-- pattern. Positional forms ("%1$s") used by some languages are flattened;
-- the captures still come out name, roll, low, high in every shipped locale.
function Rules.FormatPattern(fmt)
    local p = fmt:gsub("%%%d+%$", "%%")
    p = p:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. p .. "$"
end

function Rules.ParseRoll(text, pattern)
    local name, roll, low, high = text:match(pattern)
    if not name then
        return nil
    end
    return name, tonumber(roll), tonumber(low), tonumber(high)
end

-- ---- session -------------------------------------------------------------

function Rules.NewSession(id, host, title, t)
    return {
        v = 1,
        id = id,
        host = host,
        title = title,
        phase = "reserve", -- reserve -> live -> ended
        created = t,
        started = nil,
        ended = nil,
        officers = {},
        locks = {}, -- name -> true: has won an item this raid
        reserves = {}, -- name -> itemID
        items = {}, -- key -> item
        order = {}, -- keys in the order they were added
        active = nil, -- key of the item being rolled for
        seq = 0,
    }
end

-- Whether `name` may take part in `item` at all, ignoring its state.
function Rules.Eligible(S, item, name, classID)
    if item.restrict then
        return item.restrict[name] == true
    end
    if not Rules.HasClass(item.classMask, classID) then
        return false
    end
    if item.mode == "open" then
        return true
    end
    return not S.locks[name]
end

function Rules.CanWant(S, item, name, classID)
    return (item.state == "interest" or item.state == "rolling") and Rules.Eligible(S, item, name, classID)
end

function Rules.CanRoll(S, item, name, classID)
    return item.state == "rolling" and item.rolls[name] == nil and Rules.Eligible(S, item, name, classID)
end

-- Set of players who reserved itemID, and how many.
function Rules.Reservers(S, itemID)
    local set, n = {}, 0
    for name, id in pairs(S.reserves) do
        if id == itemID then
            set[name] = true
            n = n + 1
        end
    end
    return set, n
end

-- Highest roll. Returns winner, nil, roll - or nil, tiedSet, roll on a tie -
-- or nil when nobody rolled.
function Rules.Top(item)
    local best, tied = -1, {}
    for name, n in pairs(item.rolls) do
        if n > best then
            best, tied = n, { [name] = true }
        elseif n == best then
            tied[name] = true
        end
    end
    local count, only = 0, nil
    for name in pairs(tied) do
        count = count + 1
        only = name
    end
    if count == 1 then
        return only, nil, best
    elseif count > 1 then
        return nil, tied, best
    end
    return nil
end

-- ---- primitive ops -------------------------------------------------------
--
--   NEW     id host title time      fresh session (replaces any other)
--   PHASE   phase time              reserve | live | ended
--   OFF     name 0|1                officer flag
--   LOCK    name 0|1                lockout flag
--   RES     name itemID             0 clears the reserve
--   ADD     key itemString          new pending item
--   ITEM    key state mode mask csv csv = restricted names ("" = none)
--   WANT    key name 0|1
--   ROLL    key name roll
--   REROLL  key csv                 tie: only these roll again
--   AWARD   key name how time       locks the winner
--   CANCEL  key
--
-- Returns the session (NEW returns a new table), or nil plus a reason when
-- the op is malformed. A rejected op changes nothing.
function Rules.Apply(S, op)
    local kind = op[1]
    if kind == "NEW" then
        if type(op[2]) ~= "string" or op[2] == "" or not Rules.ValidName(op[3]) then
            return nil, "bad NEW"
        end
        local title = tostring(op[4] or ""):gsub("[\t%^|]", ""):sub(1, 40)
        return Rules.NewSession(op[2], op[3], title, tonumber(op[5]) or 0)
    end
    if not S then
        return nil, "no session"
    end
    if kind == "PHASE" then
        local p, t = op[2], tonumber(op[3]) or 0
        if p == "live" then
            S.started = S.started or t
        elseif p == "ended" then
            S.ended = t
        elseif p ~= "reserve" then
            return nil, "bad phase"
        end
        S.phase = p
        return S
    end
    if kind == "OFF" or kind == "LOCK" or kind == "RES" then
        local name = op[2]
        if not Rules.ValidName(name) then
            return nil, "bad name"
        end
        if kind == "OFF" then
            S.officers[name] = bool(op[3]) or nil
        elseif kind == "LOCK" then
            S.locks[name] = bool(op[3]) or nil
        else
            local id = tonumber(op[3])
            if not id or id < 0 then
                return nil, "bad item"
            end
            S.reserves[name] = id > 0 and id or nil
        end
        return S
    end
    local key = op[2]
    if kind == "ADD" then
        local n = tonumber(key)
        if not n or S.items[key] or not Rules.ValidItemString(op[3]) or #S.order >= Rules.MAX_ITEMS then
            return nil, "bad ADD"
        end
        S.items[key] = {
            key = key,
            itemString = op[3],
            itemID = Rules.ItemIDOf(op[3]),
            state = "pending",
            mode = "normal",
            classMask = 0,
            wants = {},
            rolls = {},
        }
        S.order[#S.order + 1] = key
        if n > S.seq then
            S.seq = n
        end
        return S
    end
    local item = S.items[key]
    if not item then
        return nil, "no item"
    end
    if kind == "ITEM" then
        if not STATES[op[3]] or not MODES[op[4]] then
            return nil, "bad ITEM"
        end
        item.state, item.mode = op[3], op[4]
        item.classMask = tonumber(op[5]) or 0
        item.restrict = Rules.CSVToSet(op[6])
        if item.state == "interest" or item.state == "rolling" then
            S.active = key
        elseif S.active == key then
            S.active = nil
        end
    elseif kind == "WANT" or kind == "ROLL" then
        local name = op[3]
        if not Rules.ValidName(name) then
            return nil, "bad name"
        end
        if kind == "WANT" then
            item.wants[name] = bool(op[4]) or nil
        else
            local n = tonumber(op[4])
            if not n or n < 1 or n > 100 then
                return nil, "bad roll"
            end
            item.rolls[name] = n
        end
    elseif kind == "REROLL" then
        local set = Rules.CSVToSet(op[3])
        if not set then
            return nil, "bad REROLL"
        end
        -- Wipe EVERY roll, not just the tied ones: a lower roll left in
        -- place would win if the tied players rolled under it again.
        item.rolls = {}
        item.restrict = set
        item.state = "rolling"
        S.active = key
    elseif kind == "AWARD" then
        if not Rules.ValidName(op[3]) or not HOWS[op[4]] then
            return nil, "bad AWARD"
        end
        item.state, item.winner, item.how, item.awardedAt = "done", op[3], op[4], tonumber(op[5]) or 0
        S.locks[op[3]] = true
        -- Any win uses up the winner's reserve: one item each, and a reserve
        -- is a claim on that one item, not a second one.
        S.reserves[op[3]] = nil
        if S.active == key then
            S.active = nil
        end
    elseif kind == "CANCEL" then
        item.state = "cancelled"
        if S.active == key then
            S.active = nil
        end
    else
        return nil, "unknown op"
    end
    return S
end

-- ---- intents (host only) -------------------------------------------------
--
-- ctx = { classOf = fn(name) -> classID|nil, now = number }
-- Requests anyone may make:      WANT key 0|1, RES itemID
-- Officer requests:              ADD itemString, START key, CALL key,
--                                CLOSE key, OPEN key, CLASS key mask,
--                                AWARD key name, CANCEL key, LOCK name 0|1,
--                                PHASE live|ended
-- Host only:                     OFF name 0|1, ROLLSEEN name roll low high
--
-- Returns ops, note - or nil, reason. `note` is a short line worth showing
-- the raid (for example when an item is opened to everyone).

function Rules.IsOfficer(S, name)
    return name == S.host or S.officers[name] == true
end

local function itemOp(item, state, mode, mask, restrict)
    return { "ITEM", item.key, state, mode, mask or item.classMask or 0, Rules.SetToCSV(restrict) }
end

function Rules.Intent(S, who, req, ctx)
    if not S then
        return nil, "No raid session."
    end
    local kind = req[1]
    local classOf = ctx.classOf
    local now = ctx.now or 0

    -- Anyone, about themselves.
    if kind == "WANT" then
        local item = S.items[req[2]]
        if not item then
            return nil, "No such item."
        end
        local on = bool(req[3])
        if on and not Rules.CanWant(S, item, who, classOf(who)) then
            return nil, "You can't ask for this item."
        end
        return { { "WANT", item.key, who, on and 1 or 0 } }
    elseif kind == "RES" then
        if S.phase ~= "reserve" then
            return nil, "Reserves are closed once the raid starts."
        end
        local id = tonumber(req[2])
        if not id or id < 0 or id ~= math.floor(id) then
            return nil, "Not an item."
        end
        return { { "RES", who, id } }
    end

    -- Host only.
    if kind == "OFF" or kind == "ROLLSEEN" then
        if who ~= S.host then
            return nil, "Only the raid host can do that."
        end
        if kind == "OFF" then
            if not Rules.ValidName(req[2]) then
                return nil, "No such player."
            end
            return { { "OFF", req[2], bool(req[3]) and 1 or 0 } }
        end
        -- A roll seen in chat. Only 1-100 rolls count, only on the active
        -- item, and only the first roll from each player.
        local name, roll, low, high = req[2], tonumber(req[3]), tonumber(req[4]), tonumber(req[5])
        local item = S.active and S.items[S.active]
        if not item or low ~= 1 or high ~= 100 or not roll then
            return nil
        end
        if not Rules.CanRoll(S, item, name, classOf(name)) then
            return nil, item.rolls[name] and "already rolled" or "not eligible"
        end
        return { { "ROLL", item.key, name, roll } }
    end

    -- Officers.
    if not Rules.IsOfficer(S, who) then
        return nil, "Only the raid host or an officer can do that."
    end
    if kind == "ADD" then
        if not Rules.ValidItemString(req[2]) then
            return nil, "Not an item."
        end
        return { { "ADD", tostring(S.seq + 1), req[2] } }
    elseif kind == "LOCK" then
        if not Rules.ValidName(req[2]) then
            return nil, "No such player."
        end
        return { { "LOCK", req[2], bool(req[3]) and 1 or 0 } }
    elseif kind == "PHASE" then
        if req[2] ~= "live" and req[2] ~= "ended" then
            return nil, "Bad phase."
        end
        return { { "PHASE", req[2], now } }
    end

    local item = S.items[req[2]]
    if not item then
        return nil, "No such item."
    end
    local st = item.state
    if kind == "START" then
        if st ~= "pending" then
            return nil, "That item has already been started."
        end
        local cur = S.active and S.items[S.active]
        if cur and (cur.state == "interest" or cur.state == "rolling") then
            return nil, "Finish the current item first."
        end
        local reservers, n = Rules.Reservers(S, item.itemID)
        if n > 0 then
            local ops = { itemOp(item, "interest", "reserve", 0, reservers) }
            for name in pairs(reservers) do
                ops[#ops + 1] = { "WANT", item.key, name, 1 }
            end
            return ops, n == 1 and "Reserved item." or "Reserved by several players: they roll for it."
        end
        return { itemOp(item, "interest", "normal", item.classMask) }
    elseif kind == "CALL" then
        if st ~= "interest" then
            return nil, "Rolls can only be called on an item that is open for interest."
        end
        if item.mode == "reserve" then
            -- One reserver: nothing to roll for, it is theirs.
            local only, n = nil, 0
            for name in pairs(item.restrict or {}) do
                only, n = name, n + 1
            end
            if n == 1 then
                return { { "AWARD", item.key, only, "reserve", now } }
            end
        elseif item.mode == "normal" then
            local any = false
            for name in pairs(item.wants) do
                if Rules.Eligible(S, item, name, classOf(name)) then
                    any = true
                    break
                end
            end
            if not any then
                return { itemOp(item, "interest", "open", item.classMask) },
                    "Nobody without an item wants this. It is now open to everyone."
            end
        end
        return { itemOp(item, "rolling", item.mode, item.classMask, item.restrict) }, "Roll now!"
    elseif kind == "CLOSE" then
        if st ~= "rolling" then
            return nil, "Nobody is rolling for that item."
        end
        local winner, tied, best = Rules.Top(item)
        if winner then
            local how = item.mode == "normal" and "roll" or item.mode
            return { { "AWARD", item.key, winner, how, now } }
        elseif tied then
            return { { "REROLL", item.key, Rules.SetToCSV(tied) } },
                "Tie on " .. best .. ". The tied players roll again."
        end
        return nil, "Nobody has rolled yet."
    elseif kind == "OPEN" then
        if st ~= "interest" and st ~= "rolling" then
            return nil, "That item is not up for rolls."
        end
        return { itemOp(item, st, "open", item.classMask) }, "Open to everyone."
    elseif kind == "CLASS" then
        if st == "done" or st == "cancelled" then
            return nil, "That item is finished."
        end
        local mask = tonumber(req[3])
        if not mask or mask < 0 then
            return nil, "Bad class list."
        end
        return { itemOp(item, st, item.mode, mask, item.restrict) }
    elseif kind == "AWARD" then
        if st == "done" or st == "cancelled" then
            return nil, "That item is finished."
        end
        local name = req[3]
        if not Rules.ValidName(name) then
            return nil, "No such player."
        end
        local how = (item.mode == "reserve" and item.restrict and item.restrict[name]) and "reserve" or "manual"
        return { { "AWARD", item.key, name, how, now } }
    elseif kind == "CANCEL" then
        if st == "done" or st == "cancelled" then
            return nil, "That item is finished."
        end
        return { { "CANCEL", item.key } }
    end
    return nil, "Unknown request."
end

-- ---- snapshot -------------------------------------------------------------

-- Ops that rebuild S from nothing. Sent to a player who reloads or joins
-- late. Locks go LAST and are sent for every past winner too, because each
-- replayed AWARD re-locks its winner and an officer may have unlocked them
-- since.
function Rules.Snapshot(S)
    local ops = { { "NEW", S.id, S.host, S.title, S.created } }
    if S.started then
        ops[#ops + 1] = { "PHASE", "live", S.started }
    end
    if S.phase == "ended" then
        ops[#ops + 1] = { "PHASE", "ended", S.ended or 0 }
    end
    for name in pairs(S.officers) do
        ops[#ops + 1] = { "OFF", name, 1 }
    end
    for name, id in pairs(S.reserves) do
        ops[#ops + 1] = { "RES", name, id }
    end
    local lockNames = {}
    for name in pairs(S.locks) do
        lockNames[name] = true
    end
    for _, key in ipairs(S.order) do
        local item = S.items[key]
        ops[#ops + 1] = { "ADD", key, item.itemString }
        if item.state ~= "pending" or item.classMask ~= 0 or item.mode ~= "normal" then
            -- Finished items replay as their last live state, then AWARD or
            -- CANCEL closes them, exactly as they happened.
            local st = (item.state == "done" or item.state == "cancelled") and "rolling" or item.state
            ops[#ops + 1] = { "ITEM", key, st, item.mode, item.classMask, Rules.SetToCSV(item.restrict) }
        end
        for name in pairs(item.wants) do
            ops[#ops + 1] = { "WANT", key, name, 1 }
        end
        for name, n in pairs(item.rolls) do
            ops[#ops + 1] = { "ROLL", key, name, n }
        end
        if item.state == "done" then
            ops[#ops + 1] = { "AWARD", key, item.winner, item.how, item.awardedAt or 0 }
            lockNames[item.winner] = true
        elseif item.state == "cancelled" then
            ops[#ops + 1] = { "CANCEL", key }
        end
    end
    for name in pairs(lockNames) do
        ops[#ops + 1] = { "LOCK", name, S.locks[name] and 1 or 0 }
    end
    -- A finished item replayed after the active one would have cleared
    -- `active` on its AWARD, so name the active item again last.
    local cur = S.active and S.items[S.active]
    if cur then
        ops[#ops + 1] = { "ITEM", cur.key, cur.state, cur.mode, cur.classMask, Rules.SetToCSV(cur.restrict) }
    end
    return ops
end
