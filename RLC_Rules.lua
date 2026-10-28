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
--   * A win on an item opened to all (a free roll, usually off-spec) does
--     not lock the winner and does not touch their reserve.
--   * A soft reserve made before the raid starts wins the item outright. If
--     several players reserved it, only they roll (unlocked ones first). A
--     regular who wins another item first keeps the reserve: it pays out when
--     it drops, as a second item. Anyone else uses it up with that win.
--   * Regulars (present for most of the last 8 raids) roll first on an item
--     they want.
--   * An officer can restrict an item to some classes.
local NS = select(2, ...)

local Rules = {}
NS.Rules = Rules

local STATES = { pending = true, interest = true, rolling = true, done = true, cancelled = true }
local MODES = { normal = true, open = true, reserve = true }
local HOWS = { roll = true, open = true, reserve = true, manual = true }
-- Officer actions recorded in the session log (History shows them).
local LOGS = {
    award = true,
    undo = true,
    lock = true,
    unlock = true,
    spec = true,
    open = true,
    cancel = true,
    specs = true, -- an item's loot specs changed
    officer = true,
    unofficer = true,
    close = true, -- closed a roll
    deliv = true, -- marked a win delivered
    live = true, -- started the raid
    ended = true, -- ended the raid
    void = true, -- wiped the rolls of an item (a boss pull during the roll)
    mlgive = true, -- the master looter gave a session item to someone else
    bench = true, -- marked a player bench for the night (counts as present)
    unbench = true,
}
-- Kinds v0.6.1 does not know. They travel as LOG2: v0.6.1 answers a LOG2
-- of an unknown kind with "newer version" once and never resyncs. A new
-- TOP-LEVEL op kind would be worse: v0.6.1 looks for an item named by its
-- second field, refuses it, and asks for the whole raid again. So new state
-- rides inside LOG2 (bench / unbench set S.bench), never a new op kind.
Rules.NEW_LOGS = {
    close = true,
    deliv = true,
    live = true,
    ended = true,
    void = true,
    mlgive = true,
    bench = true,
    unbench = true,
}
Rules.MAX_LOG = 200
-- Dropped first when the log is full: an officer can make these by the
-- hundred, and they must not push out who opened, closed or gave what.
local CHEAP_LOGS = { lock = true, spec = true, specs = true, officer = true, unofficer = true }
-- Op kinds that act on an item: any other kind with no item is unknown.
local ITEM_KINDS = {
    ITEM = true,
    WANT = true,
    ROLL = true,
    REROLL = true,
    AWARD = true,
    UNDO = true,
    CANCEL = true,
    DELIV = true,
}
-- Never dropped while any other entry can go: the evidence of who gave,
-- took back, closed, wiped, removed or unlocked what.
local KEEP_LOGS = { award = true, undo = true, close = true, void = true, mlgive = true, cancel = true, unlock = true }
-- Players per name set (reserves, specs, wants, rolls...): a raid has 40,
-- so a host cannot grow every client's saved data without end.
Rules.MAX_NAMES = 200
Rules.INTEREST_MIN = 15 -- seconds an item is up before a call can open it to everyone
Rules.ROLL_MIN = 15 -- seconds a roll stays open before a close, unless every wanter rolled
Rules.MAX_ITEMS = 500 -- per raid session; far above any real raid
Rules.MAX_ID = 2147483647 -- item ids and session keys: rejects "1e999" (inf) and NaN

-- Whether name may be added to set t (Rules.MAX_NAMES). Removing and
-- changing an entry is always allowed.
local function roomFor(t, name)
    if t[name] ~= nil then
        return true
    end
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n < Rules.MAX_NAMES
end

-- A whole number in [lo, hi] from a wire field, or nil.
function Rules.Int(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= math.floor(v) or v < lo or v > hi then
        return nil
    end
    return v
end

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

-- Full player names only: "Name-Realm", or "First Surname-Realm" on a
-- client with surnames (one space inside the name part). Anything else from
-- the wire is junk. No "|" (UI escape codes), "," (the CSV codec) or "^"
-- (the op separator, which the encoder strips).
function Rules.ValidName(s)
    return type(s) == "string"
        and #s <= 64
        and (
            s:match("^[^%s%-|,%^]+%-[^%s%-|,%^]+$") ~= nil
            or s:match("^[^%s%-|,%^]+ [^%s%-|,%^]+%-[^%s%-|,%^]+$") ~= nil
        )
end

-- "item:12345:..." (the itemString inside a link). Links themselves never go
-- on the wire: an itemString is shorter and carries no colour codes.
function Rules.ValidItemString(s)
    return type(s) == "string"
        and #s <= 200
        and s:match("^item:%d+[%d:%-]*$") ~= nil
        and tonumber(s:match("^item:(%d+)")) <= Rules.MAX_ID
end

-- Worn gear sent with a want: one or two itemStrings (rings, trinkets and
-- one-hand weapons fill two slots), comma separated. Capped so the WANT op
-- always fits one addon message.
Rules.MAX_WORN = 120
function Rules.ValidWorn(s)
    if type(s) ~= "string" or s == "" or #s > Rules.MAX_WORN then
        return false
    end
    local n = 0
    for part in s:gmatch("[^,]+") do
        n = n + 1
        if n > 2 or not Rules.ValidItemString(part) then
            return false
        end
    end
    return n > 0 and not s:find(",,", 1, true) and s:sub(-1) ~= "," and s:sub(1, 1) ~= ","
end

function Rules.ItemIDOf(itemString)
    return tonumber(itemString:match("^item:(%d+)"))
end

local function bool(v)
    return v == 1 or v == "1" or v == true
end

-- Where a drop came from (loot source + slot), or nil.
local function cleanSrc(s)
    return type(s) == "string" and #s <= 80 and s:match("^[%w:%-]+$") and s or nil
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

-- `valid` checks each entry: player names by default, Rules.ValidSpec for
-- spec lists. Entries that fail are dropped; nil when none is left.
function Rules.CSVToSet(csv, valid)
    if type(csv) ~= "string" or csv == "" then
        return nil
    end
    valid = valid or Rules.ValidName
    local set, any = {}, false
    for entry in csv:gmatch("[^,]+") do
        if valid(entry) then
            set[entry] = true
            any = true
        end
    end
    return any and set or nil
end

-- ---- specs -----------------------------------------------------------------
-- A spec key is "<CLASS TOKEN>.<TREE>", e.g. "ROGUE.COMBAT". The full list
-- and the item suitability rules live in RLC_Specs.lua; here a key only has
-- to be well formed, and its class is the part before the dot.

-- classID -> class token, for the classes Forever has.
Rules.CLASS_TOKEN = {
    [1] = "WARRIOR",
    [2] = "PALADIN",
    [3] = "HUNTER",
    [4] = "ROGUE",
    [5] = "PRIEST",
    [7] = "SHAMAN",
    [8] = "MAGE",
    [9] = "WARLOCK",
    [11] = "DRUID",
}
-- Class token -> classID.
Rules.CLASS_ID = {}
for id, token in pairs(Rules.CLASS_TOKEN) do
    Rules.CLASS_ID[token] = id
end

function Rules.ValidSpec(s)
    return type(s) == "string" and #s <= 32 and s:match("^[A-Z]+%.[A-Z]+$") ~= nil
end

-- A spec key of this player's own class (classID nil = unknown = no).
function Rules.SpecFits(s, classID)
    local token = classID and Rules.CLASS_TOKEN[classID]
    return token ~= nil and Rules.ValidSpec(s) and s:sub(1, #token + 1) == token .. "."
end

function Rules.CSVToSpecs(csv)
    return Rules.CSVToSet(csv, Rules.ValidSpec)
end

-- Every loot spec key of a class (token -> list), filled by RLC_Specs.lua.
Rules.CLASS_SPECS = {}

-- Whether the set suits this class without knowing the spec: every spec of
-- the class must be in it, so a player without the addon (no spec on
-- record) never rolls on more than one who has it. Without the class's
-- list (a bare test), any spec of the class will do.
-- any: one spec of the class is enough (a spec chosen late, see
-- suitsNormally).
local function classInSpecs(specs, classID, any)
    local token = classID and Rules.CLASS_TOKEN[classID]
    if not token then
        return false
    end
    local all = not any and Rules.CLASS_SPECS[token]
    if all then
        for _, key in ipairs(all) do
            if not specs[key] then
                return false
            end
        end
        return true
    end
    local prefix = token .. "."
    for key in pairs(specs) do
        if key:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
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

-- Turns a client format string such as RANDOM_ROLL_RESULT ("%s rolls %d
-- (%d-%d)") into a Lua pattern. Positional forms ("%1$s") used by some
-- languages are flattened; the captures still come out name, roll, low,
-- high in every shipped locale.
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

-- How far a NEW's start time may sit from our clock: a host's server time
-- is ours, so a NEW from the future is forged. The past bound lets a
-- snapshot of a long raid through.
-- NEW_PAST matches Rules.STALE_RESERVE: a reserve session opened days
-- ahead must still reach a player who joins late.
Rules.NEW_FUTURE, Rules.NEW_PAST = 300, 72 * 3600
Rules.NEW_BURST, Rules.NEW_WINDOW = 3, 1800

-- Whether a NEW from `sender` may replace our session S. ctx: now (server
-- time), isLead(name), isLeadOrAssist(name), recent (sender -> list of
-- times they started a session we took; this function updates it).
function Rules.AcceptNew(S, op, sender, ctx)
    local t = Rules.Int(op[5], 0, Rules.MAX_ID)
    if op[3] ~= sender or not t or op[2] ~= sender .. "-" .. op[5] then
        -- A session can only be started in your own name, with the id
        -- NS.NewSession makes, so a reused id cannot overwrite saved history.
        return false
    end
    if S and S.id == op[2] and S.host == sender then
        -- The host resending its own session (a snapshot). Never once it
        -- ended: a former host could wipe the saved raid by resending. A raid
        -- this client only ended for age at login is still the host's.
        return S.phase ~= "ended" or S.autoEnded == true
    end
    if ctx.known and ctx.known(op[2]) then
        return false -- an old raid's id: a blank copy would replace its saved history
    end
    if S and S.phase ~= "ended" and ctx.me and S.host == ctx.me and sender ~= ctx.me and not ctx.inRaid then
        -- Our own running raid, while we are out of a raid group: a 2-man
        -- party is enough to lead. In a raid the leader may still take over,
        -- as every other client there accepts it too.
        return false
    end
    if t > ctx.now + Rules.NEW_FUTURE or t < ctx.now - Rules.NEW_PAST then
        return false -- a forged time would sort first in history and dry lists
    end
    if S and S.phase ~= "ended" and S.host ~= sender then
        -- Taking over a running session wipes it for everyone, so only the
        -- group leader may do that, never an assistant.
        if not ctx.isLead(sender) then
            return false
        end
    elseif not ctx.isLeadOrAssist(sender) then
        return false
    end
    -- A few new sessions per sender per half hour: a flood of them would
    -- push every real raid out of saved history.
    local list, kept = ctx.recent[sender] or {}, {}
    for _, at in ipairs(list) do
        if at > ctx.now - Rules.NEW_WINDOW then
            kept[#kept + 1] = at
        end
    end
    if #kept >= Rules.NEW_BURST then
        ctx.recent[sender] = kept
        return false
    end
    kept[#kept + 1] = ctx.now
    ctx.recent[sender] = kept
    return true
end

-- When a session was last used: its start, last win or last officer
-- action, else its creation. A raid idle this long ends at login.
Rules.STALE_LIVE, Rules.STALE_RESERVE = 12 * 3600, 72 * 3600
function Rules.IsStale(S, now)
    local last = tonumber(S.started) or tonumber(S.created) or 0
    for _, it in pairs(S.items or {}) do
        last = math.max(last, tonumber(it.awardedAt) or 0)
    end
    for _, e in ipairs(S.log or {}) do
        last = math.max(last, tonumber(e.t) or 0)
    end
    -- Reserves often open the day before: give that phase longer.
    return now - last > (S.phase == "reserve" and Rules.STALE_RESERVE or Rules.STALE_LIVE)
end

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
        specs = {}, -- name -> spec key, locked once the raid starts
        reserves = {}, -- name -> itemID
        items = {}, -- key -> item
        order = {}, -- keys in the order they were added
        active = nil, -- key of the item being rolled for
        seq = 0,
        dry = {}, -- name -> true: a regular (Rules.RegularsFrom), rolls first
        bench = {}, -- name -> true: bench for the night, counts as present
        lateSpec = {}, -- name -> true: first spec came after the start
        log = {}, -- officer actions, for History: { t, by, what, name, key }
    }
end

-- Whether `item` suits `name`'s class and loot spec, ignoring locks.
function Rules.Suits(S, item, name, classID)
    if not Rules.HasClass(item.classMask, classID) then
        return false
    end
    if item.mode == "open" or not item.specs then
        return true -- open to everyone who can use it: specs no longer matter
    end
    local spec = S.specs[name]
    if spec then
        return item.specs[spec] == true
    end
    -- No spec on record (no addon): it must suit every spec of the class.
    return classInSpecs(item.specs, classID)
end

-- Whether `name` may take part in `item` at all, ignoring its state.
function Rules.Eligible(S, item, name, classID)
    if item.restrict then
        -- A tie or a roll-first pass: only these players. In a normal roll a
        -- lock still counts, so a win elsewhere mid-roll drops them out.
        return item.restrict[name] == true and (item.mode ~= "normal" or not S.locks[name])
    end
    return Rules.Suits(S, item, name, classID) and (item.mode == "open" or not S.locks[name])
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
--   AWARD   key name how time [r] [res]  locks the winner; res = a reserve
--                                   the win used up (an undo gives it back)
--   CANCEL  key
--   SPEC    name specKey            "" clears it
--   UNDO    key                     reverses an award
--   ITEMADD key r|s csv             appends names (r) or specs (s) to a
--                                   list an ITEM op marked "+" (too long
--                                   for one addon message)
--   DRY     name                    a regular: rolls first
--   LOG     time by what name key   an officer action, shown in History
--   LOG2    the same, for kinds v0.6.1 does not know. A bench / unbench
--           entry also sets S.bench (bench for the night, counts as present)
--   DELIV   key time                a won item reached its winner (trade,
--                                   master loot, or the host won it)
-- ITEM has a seventh field: the specs that may roll ("" = any).
-- ADD has an optional third field: where the drop came from, so the same
-- loot window slot is never added twice.
--
-- Returns the session (NEW returns a new table), or nil plus a reason when
-- the op is malformed. A rejected op changes nothing.
function Rules.Apply(S, op)
    local kind = op[1]
    if kind == "NEW" then
        if type(op[2]) ~= "string" or op[2] == "" or not Rules.ValidName(op[3]) then
            return nil, "bad NEW"
        end
        local title = tostring(op[4] or ""):gsub("[%c%^|]", ""):sub(1, 40)
        return Rules.NewSession(op[2], op[3], title, Rules.Int(op[5], 0, Rules.MAX_ID) or 0)
    end
    if not S then
        return nil, "no session"
    end
    if kind == "PHASE" then
        local p, t = op[2], Rules.Int(op[3], 0, Rules.MAX_ID * 2) or 0
        if p == "live" then
            S.started = S.started or t
            S.ended = nil
        elseif p == "ended" then
            S.ended = t
        elseif p ~= "reserve" then
            return nil, "bad phase"
        end
        S.phase = p
        return S
    end
    if kind == "SPEC" then
        if
            not Rules.ValidName(op[2])
            or (op[3] ~= "" and not Rules.ValidSpec(op[3]))
            or not roomFor(S.specs, op[2])
        then
            return nil, "bad SPEC"
        end
        -- A first spec once the raid started (or a drop was up) is marked:
        -- an open win is then judged by class alone, so a late off-spec
        -- report cannot make a main-spec win free.
        S.lateSpec = S.lateSpec or {}
        if op[3] == "" then
            S.lateSpec[op[2]] = nil
        elseif not S.specs[op[2]] and (S.started or next(S.items)) then
            if not roomFor(S.lateSpec, op[2]) then
                return nil, "bad SPEC"
            end
            S.lateSpec[op[2]] = true
        end
        S.specs[op[2]] = op[3] ~= "" and op[3] or nil
        return S
    end
    if kind == "DRY" then
        S.dry = S.dry or {}
        if not Rules.ValidName(op[2]) or not roomFor(S.dry, op[2]) then
            return nil, "bad DRY"
        end
        S.dry[op[2]] = true
        return S
    end
    if kind == "LOG" or kind == "LOG2" then
        if (kind == "LOG2") ~= (Rules.NEW_LOGS[op[4]] == true) and LOGS[op[4]] then
            return nil, "bad LOG" -- each kind travels on its own op
        end
        local t = Rules.Int(op[2], 0, Rules.MAX_ID * 2)
        if type(op[4]) == "string" and op[4]:match("^%l+$") and not LOGS[op[4]] then
            return nil, "unknown op" -- a newer host's kind: tell, never resync
        end
        if not t or not Rules.ValidName(op[3]) or not LOGS[op[4]] then
            return nil, "bad LOG"
        end
        local name = Rules.ValidName(op[5]) and op[5] or nil
        local key = Rules.Int(op[6], 1, Rules.MAX_ID) and op[6] or nil
        if op[4] == "bench" or op[4] == "unbench" then
            -- The bench lives here, not in an op of its own: v0.6.1 asks for
            -- the whole raid again on an op kind it does not know.
            S.bench = S.bench or {}
            if not name or not roomFor(S.bench, name) then
                return nil, "bad LOG"
            end
            S.bench[name] = op[4] == "bench" or nil
        end
        S.log = S.log or {}
        -- Full: the oldest entry goes, so the latest officer actions always
        -- show. Cheap kinds go first, then anything but KEEP_LOGS. When only
        -- kept kinds are left, the oldest of the incoming kind (or, for a
        -- kind that is not kept, the incoming entry itself): a flood of
        -- unlocks or master loot reports only pushes out itself, never who
        -- gave what.
        if #S.log >= Rules.MAX_LOG then
            local cheap, other, same
            for i, e in ipairs(S.log) do
                if CHEAP_LOGS[e.what] then
                    cheap = i
                    break
                end
                other = other or (not KEEP_LOGS[e.what] and i) or nil
                same = same or (e.what == op[4] and i) or nil
            end
            local drop = cheap or other or same or (KEEP_LOGS[op[4]] and 1)
            if not drop then
                return S
            end
            table.remove(S.log, drop)
        end
        S.log[#S.log + 1] = { t = t, by = op[3], what = op[4], name = name, key = key }
        return S
    end
    if kind == "OFF" or kind == "LOCK" or kind == "RES" then
        local name = op[2]
        local set = kind == "OFF" and S.officers or kind == "LOCK" and S.locks or S.reserves
        if not Rules.ValidName(name) or not roomFor(set, name) then
            return nil, "bad name"
        end
        if kind == "OFF" then
            S.officers[name] = bool(op[3]) or nil
        elseif kind == "LOCK" then
            S.locks[name] = bool(op[3]) or nil
        else
            local id = Rules.Int(op[3], 0, Rules.MAX_ID)
            if not id then
                return nil, "bad item"
            end
            S.reserves[name] = id > 0 and id or nil
        end
        return S
    end
    local key = op[2]
    if kind == "ADD" then
        local n = Rules.Int(key, 1, Rules.MAX_ID)
        if
            not n
            or tostring(n) ~= key
            or S.items[key]
            or not Rules.ValidItemString(op[3])
            or #S.order >= Rules.MAX_ITEMS
        then
            return nil, "bad ADD"
        end
        local src = cleanSrc(op[4])
        S.items[key] = {
            key = key,
            itemString = op[3],
            itemID = Rules.ItemIDOf(op[3]),
            state = "pending",
            mode = "normal",
            classMask = 0,
            wants = {},
            rolls = {},
            worn = {}, -- name -> what they wear in that slot (WANT)
            src = src, -- loot window source + slot, when added from a corpse
        }
        S.order[#S.order + 1] = key
        if n > S.seq then
            S.seq = n
        end
        return S
    end
    local item = S.items[key]
    if not item then
        -- A kind this copy does not know is a newer host's: tell, never
        -- resync (v0.6.1 asked for the raid again on every one).
        return nil, ITEM_KINDS[kind] and "no item" or "unknown op"
    end
    if kind == "ITEM" then
        -- "done" only comes with a winner, through AWARD.
        local mask = Rules.Int(op[5] or 0, 0, 4095)
        if not STATES[op[3]] or op[3] == "done" or not MODES[op[4]] or not mask then
            return nil, "bad ITEM"
        end
        item.state, item.mode = op[3], op[4]
        item.classMask = mask
        -- "+": the list is long and follows in ITEMADD ops.
        item.restrict = op[6] == "+" and {} or Rules.CSVToSet(op[6])
        item.specs = op[7] == "+" and {} or Rules.CSVToSpecs(op[7])
        -- The first list is the host's "Best for" from ADD (false = any).
        -- Kept so emptying Who can roll cannot make a main-spec win free.
        -- The same table: a "+" list fills both.
        if item.suggested == nil then
            item.suggested = item.specs or false
        end
        if item.state == "interest" or item.state == "rolling" then
            S.active = key
        elseif S.active == key then
            S.active = nil
        end
    elseif kind == "ITEMADD" then
        local list = op[3] == "r" and item.restrict or op[3] == "s" and item.specs
        local set = list and (op[3] == "r" and Rules.CSVToSet(op[4]) or Rules.CSVToSpecs(op[4]))
        if not set then
            return nil, "bad ITEMADD"
        end
        local n = 0
        for k in pairs(list) do
            n = n + (set[k] and 0 or 1)
        end
        for _ in pairs(set) do
            n = n + 1
        end
        if n > Rules.MAX_NAMES then
            return nil, "bad ITEMADD"
        end
        for k in pairs(set) do
            list[k] = true
        end
    elseif kind == "WANT" or kind == "ROLL" then
        local name = op[3]
        if not Rules.ValidName(name) or not roomFor(kind == "WANT" and item.wants or item.rolls, name) then
            return nil, "bad name"
        end
        if kind == "WANT" then
            item.wants[name] = bool(op[4]) or nil
            -- What they wear in that slot, for officers to compare. Advice
            -- only and self-reported: a bad value is dropped, not refused.
            item.worn = item.worn or {}
            item.worn[name] = item.wants[name] and Rules.ValidWorn(op[5]) and op[5] or nil
        else
            local n = Rules.Int(op[4], 1, 100)
            if not n then
                return nil, "bad roll"
            end
            item.rolls[name] = n
        end
    elseif kind == "REROLL" then
        local set = Rules.CSVToSet(op[3])
        if not set or item.state ~= "rolling" then
            return nil, "bad REROLL" -- only a live roll can be re-rolled
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
        item.state, item.winner, item.how, item.awardedAt =
            "done", op[3], op[4], Rules.Int(op[5], 0, Rules.MAX_ID * 2) or 0
        -- Worn gear only helps officers judge a live roll. Dropping it here
        -- keeps it out of saved history and out of every snapshot.
        item.worn = nil
        -- A free roll (item open to all) never locks. Only winning the
        -- reserved item itself uses up a reserve.
        if op[4] ~= "open" then
            S.locks[op[3]] = true
        end
        -- Winning the reserved item uses the reserve. A snapshot marks it
        -- "r" because it replays reserves after the items.
        item.usedReserve = nil
        item.spentRes = Rules.Int(op[7], 1, Rules.MAX_ID)
        if S.reserves[op[3]] == item.itemID or op[6] == "r" then
            if S.reserves[op[3]] == item.itemID then
                S.reserves[op[3]] = nil
            end
            item.usedReserve = true
        end
        if S.active == key then
            S.active = nil
        end
    elseif kind == "CANCEL" then
        if item.state == "done" then
            return nil, "bad CANCEL" -- a won item is taken back with UNDO
        end
        item.state, item.worn = "cancelled", nil
        if S.active == key then
            S.active = nil
        end
    elseif kind == "DELIV" then
        local t = Rules.Int(op[3], 0, 4e9)
        if item.state ~= "done" or not t then
            return nil, "bad DELIV"
        end
        item.delivered = t
    elseif kind == "UNDO" then
        -- A win given by mistake: the item goes back to waiting, and the
        -- winner is unlocked unless another locking win holds them. A taken
        -- back reserve win gives the reserve back.
        local winner = item.winner
        if item.state ~= "done" or not winner then
            return nil, "bad UNDO"
        end
        if item.usedReserve and not S.reserves[winner] then
            S.reserves[winner] = item.itemID
        end
        -- What was taken back stays on the item, for History.
        local rolls = {}
        for name, n in pairs(item.rolls) do
            rolls[name] = n
        end
        item.undone = { winner = winner, how = item.how, rolls = rolls }
        item.state, item.winner, item.how, item.awardedAt, item.usedReserve = "pending", nil, nil, nil, nil
        item.spentRes = nil
        item.delivered = nil
        item.mode, item.restrict, item.wants, item.rolls, item.worn = "normal", nil, {}, {}, {}
        local other = false
        for _, it in pairs(S.items) do
            if it.state == "done" and it.winner == winner and it.how ~= "open" then
                other = true
            end
        end
        if not other then
            S.locks[winner] = nil
        end
    else
        return nil, "unknown op"
    end
    return S
end

-- ---- intents (host only) -------------------------------------------------
--
-- ctx = { classOf = fn(name) -> classID|nil, now = number }, and optional
-- since(key), rollingSince(key), inEncounter(), isMasterLooter(name),
-- describe(itemString), dry().
-- Requests anyone may make:      WANT key 0|1, RES itemID, SPEC specKey
-- Master looter or officer:      MLGAVE key name
-- Officer requests:              ADD itemString, START key, CALL key, DELIV key,
--                                CLOSE key, OPEN key, SPECS key csv,
--                                UNDO key, SETSPEC name spec, VOID key,
--                                AWARD key name, CANCEL key, LOCK name 0|1,
--                                BENCH name 0|1, PHASE live|ended
-- Host only:                     OFF name 0|1, ROLLSEEN name roll low high
--
-- Returns ops, note - or nil, reason. `note` is a short line worth showing
-- the raid (for example when an item is opened to everyone).

function Rules.IsOfficer(S, name)
    return name == S.host or S.officers[name] == true
end

-- Longest encoded op the rules emit; RLC_Net sends up to 250 bytes.
Rules.OP_LIMIT = 220
local CHUNK = 180

-- Append the ITEM op for this state to `ops`. A restrict or spec list too
-- long for one addon message goes as "+" and follows in ITEMADD chunks:
-- an oversize op would be dropped by Pack and the clients never told.
local function addItemOps(ops, item, state, mode, mask, restrict, specs)
    local r, sp = Rules.SetToCSV(restrict), Rules.SetToCSV(specs or item.specs)
    local op = { "ITEM", item.key, state, mode, mask or item.classMask or 0, r, sp }
    ops[#ops + 1] = op
    if #Rules.EncodeOp(op) <= Rules.OP_LIMIT then
        return ops
    end
    local lists = { { 6, "r", r }, { 7, "s", sp } }
    for _, l in ipairs(lists) do
        local field, tag, csv = l[1], l[2], l[3]
        if #csv > CHUNK then
            op[field] = "+"
            local chunk = ""
            for part in csv:gmatch("[^,]+") do
                if chunk ~= "" and #chunk + #part + 1 > CHUNK then
                    ops[#ops + 1] = { "ITEMADD", item.key, tag, chunk }
                    chunk = ""
                end
                chunk = chunk == "" and part or (chunk .. "," .. part)
            end
            if chunk ~= "" then
                ops[#ops + 1] = { "ITEMADD", item.key, tag, chunk }
            end
        end
    end
    return ops
end

-- Would this item suit `name` in normal mode, locks aside? Judged on the
-- specs from ADD and the current ones together, so an officer emptying Who
-- can roll cannot turn a main-spec win free. A spec first set after the
-- start is judged by class alone.
local function suitsNormally(S, item, name, classID)
    local specs = item.specs
    if specs and item.suggested == false then
        specs = nil -- ADD said any spec
    elseif specs and item.suggested then
        specs = {}
        for k in pairs(item.suggested) do
            specs[k] = true
        end
        for k in pairs(item.specs) do
            specs[k] = true
        end
    end
    if specs and S.lateSpec and S.lateSpec[name] and classInSpecs(specs, classID, true) then
        specs = nil
    end
    return Rules.Suits(S, { classMask = item.classMask, mode = "normal", specs = specs }, name, classID)
end

-- Would `name` take part in this item in normal mode, unlocked? A win on
-- an open item by such a player counts as their item: no free first win
-- for staying quiet on I want this.
local function normallyEligible(S, item, name, classID)
    return not S.locks[name] and suitsNormally(S, item, name, classID)
end

-- Whether a roll is open. Eligibility (locks, specs, Who can roll) is
-- frozen until it closes: nobody can be dropped from a roll once it is in.
local function rolling(S)
    local cur = S.active and S.items[S.active]
    return cur ~= nil and cur.state == "rolling"
end

-- The AWARD op, and a RES op when the win uses up a reserve: a reserve pays
-- out as a second item only to a regular. AWARD carries that reserve so an
-- undo can give it back.
local function awardOps(S, item, name, how, now)
    local res = S.reserves[name]
    if how ~= "open" and res and res ~= item.itemID and not (S.dry and S.dry[name]) then
        return { "AWARD", item.key, name, how, now, "", res }, { "RES", name, 0 }
    end
    return { "AWARD", item.key, name, how, now }
end

-- Whether any item is on the list: reserves close at the first one, so
-- nobody reserves a drop after seeing it (an added item is seen at once).
local function anyAdded(S)
    return next(S.items) ~= nil
end

local function logOp(now, by, what, name, key)
    return { Rules.NEW_LOGS[what] and "LOG2" or "LOG", now, by, what, name or "", key or "" }
end

local function audit(ops, now, by, what, name, key)
    ops[#ops + 1] = logOp(now, by, what, name, key)
    return ops
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
        if on and item.specs and not item.restrict and item.mode ~= "open" and not S.specs[who] then
            -- No spec on record would let you ask for every spec's gear.
            return nil, "Pick your loot spec first."
        end
        local worn = on and Rules.ValidWorn(req[4]) and req[4] or nil
        if (item.wants[who] == true) == on then
            -- Nothing changed, or only the worn item: send nothing. A worn
            -- item alone is advice, not worth a broadcast that one player
            -- could repeat to fill the host's send budget.
            return {}
        end
        return { { "WANT", item.key, who, on and 1 or 0, worn } }
    elseif kind == "RES" then
        if S.phase ~= "reserve" or anyAdded(S) then
            return nil, "Reserves are closed once the raid starts or the first item is up."
        end
        local id = Rules.Int(req[2], 0, Rules.MAX_ID)
        if not id then
            return nil, "Not an item."
        end
        if (S.reserves[who] or 0) == id then
            return {} -- nothing changed: send nothing
        end
        if id > 0 and ctx.describe then
            -- Only gear your class and loot spec can use (when the host
            -- knows the item; an unknown one reads as fitting everyone).
            local mask, specs = ctx.describe("item:" .. id)
            local view = { classMask = mask or 0, mode = "normal", specs = Rules.CSVToSpecs(specs) }
            if not Rules.Suits(S, view, who, classOf(who)) then
                return nil, "That item doesn't suit your class or loot spec."
            end
        end
        return { { "RES", who, id } }
    elseif kind == "SPEC" then
        -- Your own spec: free to change until the raid starts, then locked
        -- (a first report from a late joiner still counts).
        local spec = req[2]
        if not Rules.SpecFits(spec, classOf(who)) then
            return nil, "Not a spec."
        end
        if (S.phase ~= "reserve" or anyAdded(S)) and S.specs[who] ~= spec then
            -- A late first report counts between items: not mid-roll, nor on
            -- the item you already asked for or rolled on. It is marked late
            -- (S.lateSpec), so it cannot make an earlier win free.
            local cur = S.active and S.items[S.active]
            if S.specs[who] or (cur and (cur.wants[who] or cur.rolls[who])) then
                return nil, "Specs are locked once the raid starts. Ask an officer to change yours."
            elseif rolling(S) then
                return nil, "Wait until the roll is closed."
            end
        end
        if S.specs[who] == spec then
            return {}
        end
        return { { "SPEC", who, spec } }
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
            local on = bool(req[3])
            return { { "OFF", req[2], on and 1 or 0 }, logOp(now, who, on and "officer" or "unofficer", req[2]) }
        end
        -- A roll seen in chat. Only 1-100 rolls count, only on the active
        -- item, and only the first roll from each player.
        local name, roll, low, high = req[2], Rules.Int(req[3], 1, 100), tonumber(req[4]), tonumber(req[5])
        local item = S.active and S.items[S.active]
        if not item or item.state ~= "rolling" or not roll then
            return nil -- not rolling for anything: a /roll for some other reason
        end
        if not classOf(name) then
            return nil -- not in the group: a bystander's /roll seen nearby
        end
        -- The reasons go back to the player who rolled.
        if low ~= 1 or high ~= 100 then
            return nil, "Only a roll of 1-100 counts. Use the Roll button."
        elseif item.rolls[name] then
            return nil, "You already rolled for this item. Only your first roll counts."
        elseif not Rules.CanRoll(S, item, name, classOf(name)) then
            return nil, "Your roll didn't count: you can't roll for this item. The Loot tab says why."
        end
        -- No spec on record is NOT refused here, unlike WANT: a raider
        -- without the addon cannot report one and rolls on class alone. A
        -- modded copy that hides its spec looks the same, so it gets no more.
        return { { "ROLL", item.key, name, roll } }
    end

    -- The master looter (or an officer) saw a session item given from the
    -- game's own loot menu to someone other than its winner. Logged once.
    if kind == "MLGAVE" then
        if not Rules.IsOfficer(S, who) and not (ctx.isMasterLooter and ctx.isMasterLooter(who)) then
            return nil, "Only the master looter can report that."
        end
        local item, name = S.items[req[2]], req[3]
        if not item then
            return nil, "No such item."
        elseif not Rules.ValidName(name) or not classOf(name) then
            return nil, "That player is not in the group."
        elseif name == item.winner then
            return {}
        end
        -- One report per item: a drop is given once, and a flood of names
        -- must not fill the log.
        for _, e in ipairs(S.log or {}) do
            if e.what == "mlgive" and e.key == item.key then
                return {}
            end
        end
        return { logOp(now, who, "mlgive", name, item.key) }
    end

    -- Officers.
    if not Rules.IsOfficer(S, who) then
        return nil, "Only the raid host or an officer can do that."
    end
    if kind == "ADD" then
        if not Rules.ValidItemString(req[2]) then
            return nil, "Not an item."
        end
        -- req[3]: where it came from (corpse + loot slot). The same slot
        -- added twice, after a reload or by a second officer, is refused.
        local src = cleanSrc(req[3])
        if src then
            for _, it in pairs(S.items) do
                if it.src == src then
                    return nil, "That drop is already on the list."
                end
            end
        end
        local key = tostring(S.seq + 1)
        local ops = { { "ADD", key, req[2], src } }
        -- The host works out which classes and specs suit it.
        -- Always sent when known, even "any spec": its first ITEM op is what
        -- the item stays suggested for (item.suggested).
        if ctx.describe then
            local mask, specs = ctx.describe(req[2])
            addItemOps(ops, { key = key }, "pending", "normal", mask or 0, nil, Rules.CSVToSpecs(specs) or {})
        end
        return ops
    elseif kind == "SETSPEC" then
        if not Rules.ValidName(req[2]) or (req[3] ~= "" and not Rules.SpecFits(req[3], classOf(req[2]))) then
            return nil, "Bad spec."
        end
        if rolling(S) then
            return nil, "Wait until the roll is closed."
        end
        if S.reserves[req[2]] and (S.phase ~= "reserve" or anyAdded(S)) and S.specs[req[2]] ~= req[3] then
            -- START checks a reserve against the spec: a change now would
            -- drop it without a word.
            return nil, "That player has a reserve. Their spec stays until it pays out."
        end
        return { { "SPEC", req[2], req[3] }, logOp(now, who, "spec", req[2]) }
    elseif kind == "LOCK" then
        if not Rules.ValidName(req[2]) then
            return nil, "No such player."
        end
        if rolling(S) then
            return nil, "Wait until the roll is closed."
        end
        local on = bool(req[3])
        if (S.locks[req[2]] == true) == on then
            return {} -- nothing changed: no log line to flood with
        end
        return { { "LOCK", req[2], on and 1 or 0 }, logOp(now, who, on and "lock" or "unlock", req[2], S.active) }
    elseif kind == "BENCH" then
        if not Rules.ValidName(req[2]) then
            return nil, "No such player."
        elseif S.phase == "ended" then
            return nil, "The raid has ended."
        end
        local on = bool(req[3])
        if (S.bench and S.bench[req[2]] == true) == on then
            return {}
        end
        return { logOp(now, who, on and "bench" or "unbench", req[2]) }
    elseif kind == "PHASE" then
        if req[2] ~= "live" and req[2] ~= "ended" then
            return nil, "Bad phase."
        elseif req[2] == S.phase then
            -- Each start or end is a log line: repeats would flood the log.
            return nil, req[2] == "live" and "The raid has already started." or "The raid has already ended."
        end
        local ops = audit({ { "PHASE", req[2], now } }, now, who, req[2])
        -- Raid start: regulars roll first tonight (ctx.dry comes from the
        -- host's saved history, Rules.RegularsFrom).
        if req[2] == "live" and not S.started and ctx.dry then
            for _, name in ipairs(ctx.dry()) do
                if Rules.ValidName(name) then
                    ops[#ops + 1] = { "DRY", name }
                end
            end
        end
        return ops
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
        -- Only reservers who are here: a reserve does not pay out to
        -- someone who left the group, or whose loot spec changed since. Nor
        -- as a second item to someone who is not a regular.
        local reservers, n = {}, 0
        for name in pairs((Rules.Reservers(S, item.itemID))) do
            if
                classOf(name)
                and Rules.Suits(S, item, name, classOf(name))
                and (not S.locks[name] or (S.dry and S.dry[name]))
            then
                reservers[name], n = true, n + 1
            end
        end
        if n > 0 then
            local ops = addItemOps({}, item, "interest", "reserve", item.classMask, reservers)
            for name in pairs(reservers) do
                ops[#ops + 1] = { "WANT", item.key, name, 1 }
            end
            return ops, n == 1 and "Reserved item." or "Reserved by several players: they roll for it."
        end
        return addItemOps({}, item, "interest", "normal", item.classMask)
    elseif kind == "CALL" then
        if st ~= "interest" then
            return nil, "Rolls can only be called on an item that is open for interest."
        end
        if ctx.inEncounter and ctx.inEncounter() then
            -- Roll lines can't be read during a boss fight.
            return nil, "Wait for the fight to end."
        end
        if item.mode == "reserve" then
            -- Reservers still here, the ones without an item first (a
            -- regular's reserve can pay out as a second item, but not ahead
            -- of a reserver with none). One: nothing to roll for, it is
            -- theirs. None (all left): the item goes to normal interest.
            local here, free = {}, {}
            for name in pairs(item.restrict or {}) do
                -- Still theirs: a win since may have used the reserve up.
                if classOf(name) and S.reserves[name] == item.itemID then
                    here[name] = true
                    free[name] = not S.locks[name] or nil
                end
            end
            here = next(free) and free or here
            local only, n = nil, 0
            for name in pairs(here) do
                only, n = name, n + 1
            end
            if n == 1 then
                return { { "AWARD", item.key, only, "reserve", now } }
            elseif n == 0 then
                return addItemOps({}, item, "interest", "normal", item.classMask),
                    "The reserver is not here. Anyone it suits can ask for it."
            end
            return addItemOps({}, item, "rolling", "reserve", item.classMask, here), "Roll now!"
        elseif item.mode == "normal" then
            local wanting, dry = false, {}
            for name in pairs(item.wants) do
                if classOf(name) and Rules.Eligible(S, item, name, classOf(name)) then
                    wanting = true
                    if S.dry and S.dry[name] then
                        dry[name] = true
                    end
                end
            end
            if not wanting then
                -- Called the moment it went up, nobody has had time to ask:
                -- that would hand it to everyone, locked players too.
                local since = ctx.since and ctx.since(item.key)
                if since and now - since < Rules.INTEREST_MIN then
                    return nil, "Give the raid a few seconds to say they want it."
                end
                local ops = addItemOps({}, item, "interest", "open", item.classMask)
                ops[#ops + 1] = logOp(now, who, "open", nil, item.key)
                return ops, "Nobody without an item wants this. It is now open to everyone."
            end
            -- Time given counts: regulars roll first when they want it.
            if next(dry) then
                return addItemOps({}, item, "rolling", "normal", item.classMask, dry), "Regulars roll first."
            end
        end
        return addItemOps({}, item, "rolling", item.mode, item.classMask, item.restrict), "Roll now!"
    elseif kind == "CLOSE" then
        if st ~= "rolling" then
            return nil, "Nobody is rolling for that item."
        end
        -- Give everyone time to roll: closing the second a friend rolls high
        -- would shut out the rest. Only a roll limited to named players
        -- (reservers, regulars, a tie) may close early, once all of them
        -- rolled: anyone in the group may roll on any other.
        local since = ctx.rollingSince and ctx.rollingSince(item.key)
        if since and now - since < Rules.ROLL_MIN then
            local early = item.restrict ~= nil and next(item.restrict) ~= nil
            for name in pairs(item.restrict or {}) do
                if not item.rolls[name] and classOf(name) and Rules.Eligible(S, item, name, classOf(name)) then
                    early = false
                end
            end
            if not early then
                return nil, "Give everyone a few seconds to roll."
            end
        end
        -- Only rolls from players still here and still allowed count: one
        -- who left, or (in a normal roll) won another item mid-roll, drops out.
        local valid = {}
        for name, n in pairs(item.rolls) do
            if
                classOf(name)
                and Rules.Eligible(S, item, name, classOf(name))
                and (item.mode ~= "reserve" or S.reserves[name] == item.itemID)
            then
                valid[name] = n
            end
        end
        local winner, tied, best = Rules.Top({ rolls = valid })
        if winner then
            local how = item.mode == "normal" and "roll" or item.mode
            if how == "open" and normallyEligible(S, item, winner, classOf(winner)) then
                how = "roll" -- could have asked normally: it counts as their item
            end
            local ops = { awardOps(S, item, winner, how, now) }
            -- Who closed it, and when: an officer closing the moment a friend
            -- rolls high shows in History. Their own win shows as an award.
            if winner == who then
                return audit(ops, now, who, "award", winner, item.key)
            end
            return audit(ops, now, who, "close", winner, item.key)
        elseif tied then
            return { { "REROLL", item.key, Rules.SetToCSV(tied) } },
                "Tie on " .. best .. ". The tied players roll again."
        end
        -- Only regulars may roll and none has: one of them could otherwise
        -- hold the item up by asking and never rolling.
        local dryOnly = item.mode == "normal" and item.restrict and next(item.restrict) ~= nil
        for name in pairs(item.restrict or {}) do
            dryOnly = dryOnly and S.dry and S.dry[name]
        end
        if dryOnly then
            return addItemOps({}, item, "rolling", "normal", item.classMask),
                "Nobody who rolls first has rolled. Everyone who wants it can roll now."
        end
        return nil, "Nobody has rolled yet."
    elseif kind == "OPEN" then
        if st ~= "interest" and st ~= "rolling" then
            return nil, "That item is not up for rolls."
        end
        if item.mode == "reserve" then
            -- A reserver who is here keeps it; Call opens it if all have left.
            for name in pairs(item.restrict or {}) do
                if classOf(name) then
                    return nil, "A reserver is here. Roll it for them, or give it by hand."
                end
            end
        end
        if item.mode == "normal" then
            for name in pairs(item.wants) do
                if classOf(name) and normallyEligible(S, item, name, classOf(name)) then
                    return nil, "Someone without an item wants this. Roll it normally, or give it by hand."
                end
            end
        end
        local since = ctx.since and ctx.since(item.key)
        if since and now - since < Rules.INTEREST_MIN then
            return nil, "Give the raid a few seconds to say they want it."
        end
        local ops = addItemOps({}, item, st, "open", item.classMask)
        ops[#ops + 1] = logOp(now, who, "open", nil, item.key)
        return ops, "Open to everyone."
    elseif kind == "AWARD" then
        if st == "done" or st == "cancelled" then
            return nil, "That item is finished."
        elseif rolling(S) and item.key ~= S.active then
            -- A win locks its winner: not while another roll is frozen.
            return nil, "Wait until the roll is closed."
        end
        local name = req[3]
        if not Rules.ValidName(name) or not classOf(name) then
            return nil, "That player is not in the group."
        end
        local how = (item.mode == "reserve" and item.restrict and item.restrict[name]) and "reserve" or "manual"
        if item.mode == "open" and not normallyEligible(S, item, name, classOf(name)) then
            how = "open" -- an open item given to a locked or off-spec player stays free
        end
        return audit({ awardOps(S, item, name, how, now) }, now, who, "award", name, item.key)
    elseif kind == "CANCEL" then
        if st == "done" or st == "cancelled" then
            return nil, "That item is finished."
        end
        return { { "CANCEL", item.key }, logOp(now, who, "cancel", nil, item.key) }
    elseif kind == "SPECS" then
        if st == "done" or st == "cancelled" then
            return nil, "That item is finished."
        elseif rolling(S) then
            return nil, "Wait until the roll is closed."
        end
        local specs = Rules.CSVToSpecs(req[3]) -- nil = any spec
        local ops = addItemOps({}, item, st, item.mode, item.classMask, item.restrict, specs or {})
        ops[#ops + 1] = logOp(now, who, "specs", nil, item.key)
        return ops
    elseif kind == "UNDO" then
        if st ~= "done" then
            return nil, "Only a won item can be taken back."
        elseif item.delivered and who ~= S.host then
            return nil, "That item was delivered. Only the raid host can take it back."
        elseif rolling(S) then
            -- An undo unlocks its winner (or locks one): not mid-roll.
            return nil, "Wait until the roll is closed."
        end
        local winner = item.winner
        local ops = { { "UNDO", item.key } }
        if item.spentRes and not S.reserves[winner] then
            ops[#ops + 1] = { "RES", winner, item.spentRes } -- the reserve this win used up
        end
        -- A free win they could have asked for normally becomes their item:
        -- taking back the win that locked them must not leave them with an
        -- item and no lock.
        for _, it in pairs(S.items) do
            if
                it ~= item
                and it.state == "done"
                and it.winner == winner
                and it.how == "open"
                and suitsNormally(S, it, winner, classOf(winner))
            then
                ops[#ops + 1] = { "LOCK", winner, 1 }
                break
            end
        end
        return audit(ops, now, who, "undo", winner, item.key), "Win taken back. This item is up again."
    elseif kind == "VOID" then
        -- Wipe every roll: everyone rolls again. REROLL wipes, ITEM puts Who
        -- may roll back, so older copies follow it too.
        if st ~= "rolling" then
            return nil, "Nobody is rolling for that item."
        end
        local first = next(item.rolls)
        if not first then
            return {}
        end
        local ops =
            addItemOps({ { "REROLL", item.key, first } }, item, "rolling", item.mode, item.classMask, item.restrict)
        return audit(ops, now, who, "void", nil, item.key), "Rolls wiped. Everyone rolls again."
    elseif kind == "DELIV" then
        if st ~= "done" then
            return nil, "Only a won item can be delivered."
        elseif item.delivered then
            return nil, "Already delivered."
        end
        return audit({ { "DELIV", item.key, now } }, now, who, "deliv", item.winner, item.key)
    end
    return nil, "Unknown request."
end

-- Everyone the addon saw in a saved raid (a spec, reserve, want, roll or
-- win), as a set of names.
function Rules.SeenIn(rec)
    local seen = {}
    for name in pairs(rec.specs or {}) do
        seen[name] = true
    end
    for name in pairs(rec.reserves or {}) do
        seen[name] = true
    end
    for _, it in pairs(rec.items or {}) do
        for name in pairs(it.wants or {}) do
            seen[name] = true
        end
        for name in pairs(it.rolls or {}) do
            seen[name] = true
        end
        if it.winner then
            seen[it.winner] = true
        end
    end
    return seen
end

-- Per player across saved raids: raids seen in, items won (free rolls
-- counted apart, they are leftovers), and the time of their last win.
-- Only raids that started count. Returns name -> { raids, won, free, last }.
function Rules.PlayerStats(history)
    local out = {}
    local function entry(name)
        out[name] = out[name] or { raids = 0, won = 0, free = 0, last = 0 }
        return out[name]
    end
    for _, rec in pairs(history or {}) do
        if rec.started and not rec.untrusted then
            for name in pairs(Rules.SeenIn(rec)) do
                entry(name).raids = entry(name).raids + 1
            end
            for _, it in pairs(rec.items or {}) do
                if it.state == "done" and it.winner then
                    local e = entry(it.winner)
                    if it.how == "open" then
                        e.free = e.free + 1
                    else
                        e.won = e.won + 1
                    end
                    e.last = math.max(e.last, rec.created or 0)
                end
            end
        end
    end
    return out
end

-- A saved raid as plain text, one line per item given, for pasting into
-- Discord or a forum. itemName(itemString) and short(name) come from the
-- caller (the client knows item names); when is the raid's date as text.
local HOW_WORDS = { roll = "roll", open = "free roll", reserve = "reserve", manual = "given" }
function Rules.HistoryText(rec, when, itemName, short)
    local lines = { (rec.title and rec.title ~= "" and rec.title or "Raid") .. " - " .. when }
    for _, key in ipairs(rec.order or {}) do
        local it = rec.items[key]
        if it and it.state == "done" and it.winner then
            local roll = it.rolls and it.rolls[it.winner]
            local how = HOW_WORDS[it.how] or "given"
            if roll and (it.how == "roll" or it.how == "open") then
                how = how .. " " .. roll
            end
            if it.delivered then
                how = how .. ", delivered"
            end
            lines[#lines + 1] = string.format("[%s] - %s (%s)", itemName(it.itemString), short(it.winner), how)
        end
    end
    if #lines == 1 then
        lines[2] = "No items given."
    end
    return table.concat(lines, "\n")
end

-- Whether version a ("v1.2.3") is newer than b. Anything that is not
-- three numbers (a dev copy, junk from the wire) is never newer.
local function versionParts(v)
    local x, y, z = tostring(v or ""):match("^v?(%d+)%.(%d+)%.(%d+)$")
    return x and { tonumber(x), tonumber(y), tonumber(z) }
end
function Rules.VersionNewer(a, b)
    local pa, pb = versionParts(a), versionParts(b)
    if not pa or not pb then
        return false
    end
    for i = 1, 3 do
        if pa[i] ~= pb[i] then
            return pa[i] > pb[i]
        end
    end
    return false
end
Rules.ValidVersion = function(v)
    return type(v) == "string" and #v <= 16 and versionParts(v) ~= nil
end

-- ---- attendance and regulars ----------------------------------------------
-- A saved raid's attendance is kept locally, never sent: rec.att[name] =
-- seconds this client saw name in the group while the raid was live (true
-- in older records: all of it), rec.attSpan = seconds the raid was live,
-- rec.inst = the raid instance, rec.bench = players benched that night.
Rules.MIN_ATTEND = 10 -- players present for a raid to count at all
Rules.ATTEND_SHARE = 0.75 -- share of the raid you must be there for
Rules.REGULAR_WINDOW, Rules.REGULAR_SHARE = 8, 0.75 -- in 75% of the last 8 raids
Rules.NIGHT = 12 * 3600 -- raids this close together in one instance are one night

local function count(set)
    local n = 0
    for _ in pairs(set) do
        n = n + 1
    end
    return n
end

-- Whether `name` was there for raid `rec`. Older raids without att fall
-- back to who wanted or rolled: a spec or a reserve alone does not count,
-- both can be made before the raid.
function Rules.Present(rec, name)
    if rec.bench and rec.bench[name] then
        return true
    elseif not rec.att then
        for _, it in pairs(rec.items or {}) do
            if (it.wants and it.wants[name]) or (it.rolls and it.rolls[name]) then
                return true
            end
        end
        return false
    end
    local t = rec.att[name]
    return t == true or (type(t) == "number" and rec.attSpan ~= nil and t >= Rules.ATTEND_SHARE * rec.attSpan)
end

-- Who was there for `rec`, bench included, and apart from it who was there
-- in person: only they count toward MIN_ATTEND (a host could bench a list
-- of alts to make a small party count).
local function presentSet(rec)
    local real, plain = {}, { att = rec.att, attSpan = rec.attSpan, items = rec.items }
    local names = { rec.att or {} }
    for _, it in pairs(rec.att and {} or rec.items or {}) do
        names[#names + 1] = it.wants or {}
        names[#names + 1] = it.rolls or {}
    end
    for _, set in ipairs(names) do
        for name in pairs(set) do
            real[name] = real[name] or Rules.Present(plain, name) or nil
        end
    end
    local out = {}
    for _, set in ipairs({ real, rec.bench or {} }) do
        for name in pairs(set) do
            out[name] = true
        end
    end
    return out, real
end

-- Regulars: present in at least REGULAR_SHARE of the last REGULAR_WINDOW
-- raids in `history` (saved sessions by id), other than currentID. They
-- roll first tonight. With `inst`, only raids in that instance count (or
-- older ones that never recorded it). Sorted names.
function Rules.RegularsFrom(history, currentID, inst)
    local raids = {}
    for id, rec in pairs(history or {}) do
        -- An untrusted raid (hosted by someone who was not the group leader,
        -- seen from another client) could be made up to put friends first.
        if
            id ~= currentID
            and rec.started
            and not rec.untrusted
            and (not inst or rec.inst == inst or (rec.inst == nil and rec.attSpan == nil))
        then
            local seen, real = presentSet(rec)
            raids[#raids + 1] = { rec = rec, seen = seen, real = real }
        end
    end
    table.sort(raids, function(x, y)
        return (x.rec.created or 0) < (y.rec.created or 0)
    end)
    -- End raid + New raid in one evening is one night, not two: raids within
    -- NIGHT of the night's first start, in one instance.
    local all = {}
    for _, r in ipairs(raids) do
        local last, started = all[#all], tonumber(r.rec.started) or 0
        if not (last and r.rec.inst == last.inst and started - last.started <= Rules.NIGHT) then
            last = { inst = r.rec.inst, started = started, seen = {}, real = {} }
            all[#all + 1] = last
        end
        for _, f in ipairs({ "seen", "real" }) do
            for name in pairs(r[f]) do
                last[f][name] = true
            end
        end
    end
    -- A small party does not count: a night needs MIN_ATTEND players there
    -- in person. The newest REGULAR_WINDOW nights that count.
    local nights = {}
    for i = #all, 1, -1 do
        if #nights >= Rules.REGULAR_WINDOW then
            break
        elseif count(all[i].real) >= Rules.MIN_ATTEND then
            nights[#nights + 1] = all[i]
        end
    end
    local times, need = {}, math.ceil(Rules.REGULAR_SHARE * #nights)
    for _, night in ipairs(nights) do
        for name in pairs(night.seen) do
            times[name] = (times[name] or 0) + 1
        end
    end
    local out = {}
    for name, n in pairs(times) do
        if n >= need then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end
Rules.DryFrom = Rules.RegularsFrom -- the old name, for one release

-- ---- snapshot -------------------------------------------------------------

local function sameSet(a, b)
    if not a or not b then
        return not a and not b
    end
    for k in pairs(a) do
        if not b[k] then
            return false
        end
    end
    for k in pairs(b) do
        if not a[k] then
            return false
        end
    end
    return true
end

-- Ops that rebuild S from nothing. Sent to a player who reloads or joins
-- late. Locks go LAST and are sent for every past winner too, because each
-- replayed AWARD re-locks its winner and an officer may have unlocked them
-- since.
function Rules.Snapshot(S)
    local ops = { { "NEW", S.id, S.host, S.title, S.created } }
    -- Specs before the start, except those first set later (S.lateSpec):
    -- they follow the items, so the replay marks them late again.
    local late = S.lateSpec or {}
    for name, spec in pairs(S.specs) do
        if not late[name] then
            ops[#ops + 1] = { "SPEC", name, spec }
        end
    end
    if S.started then
        ops[#ops + 1] = { "PHASE", "live", S.started }
    end
    if S.phase == "ended" then
        ops[#ops + 1] = { "PHASE", "ended", S.ended or 0 }
    end
    for name in pairs(S.officers) do
        ops[#ops + 1] = { "OFF", name, 1 }
    end
    local lockNames = {}
    for name in pairs(S.locks) do
        lockNames[name] = true
    end
    for _, key in ipairs(S.order) do
        local item = S.items[key]
        ops[#ops + 1] = { "ADD", key, item.itemString, item.src }
        if item.suggested ~= nil and not sameSet(item.suggested, item.specs) then
            addItemOps(ops, item, "pending", "normal", item.classMask, nil, item.suggested or {})
        end
        local u = item.undone
        if u then -- the win taken back, replayed and taken back again
            for name, n in pairs(u.rolls) do
                ops[#ops + 1] = { "ROLL", key, name, n }
            end
            ops[#ops + 1] = { "AWARD", key, u.winner, u.how, 0 }
            ops[#ops + 1] = { "UNDO", key }
            lockNames[u.winner] = true
        end
        if
            item.state ~= "pending"
            or item.classMask ~= 0
            or item.mode ~= "normal"
            or item.specs
            or item.suggested ~= nil
        then
            -- Finished items replay as their last live state, then AWARD or
            -- CANCEL closes them, exactly as they happened.
            local st = (item.state == "done" or item.state == "cancelled") and "rolling" or item.state
            addItemOps(ops, item, st, item.mode, item.classMask, item.restrict)
        end
        for name in pairs(item.wants) do
            ops[#ops + 1] = { "WANT", key, name, 1, item.worn and item.worn[name] }
        end
        for name, n in pairs(item.rolls) do
            ops[#ops + 1] = { "ROLL", key, name, n }
        end
        if item.state == "done" then
            ops[#ops + 1] = {
                "AWARD",
                key,
                item.winner,
                item.how,
                item.awardedAt or 0,
                item.usedReserve and "r" or "",
                item.spentRes,
            }
            if item.delivered then
                ops[#ops + 1] = { "DELIV", key, item.delivered }
            end
            lockNames[item.winner] = true
        elseif item.state == "cancelled" then
            ops[#ops + 1] = { "CANCEL", key }
        end
    end
    for name in pairs(late) do
        ops[#ops + 1] = { "SPEC", name, S.specs[name] }
    end
    for name in pairs(lockNames) do
        ops[#ops + 1] = { "LOCK", name, S.locks[name] and 1 or 0 }
    end
    -- Reserves after the items: a replayed AWARD of a reserved item would
    -- clear a reserve the winner made again later.
    for name, id in pairs(S.reserves) do
        ops[#ops + 1] = { "RES", name, id }
    end
    for name in pairs(S.dry or {}) do
        ops[#ops + 1] = { "DRY", name }
    end
    -- The log replays the bench. One whose entry a full log dropped is
    -- told again after it.
    local benched = {}
    for _, e in ipairs(S.log or {}) do
        ops[#ops + 1] = logOp(e.t, e.by, e.what, e.name, e.key)
        if e.what == "bench" or e.what == "unbench" then
            benched[e.name] = e.what == "bench"
        end
    end
    for name, on in pairs(benched) do
        if on and not (S.bench and S.bench[name]) then
            ops[#ops + 1] = logOp(S.created, S.host, "unbench", name)
        end
    end
    for name in pairs(S.bench or {}) do
        if not benched[name] then
            ops[#ops + 1] = logOp(S.created, S.host, "bench", name)
        end
    end
    -- A finished item replayed after the active one would have cleared
    -- `active` on its AWARD, so name the active item again last.
    local cur = S.active and S.items[S.active]
    if cur then
        addItemOps(ops, cur, cur.state, cur.mode, cur.classMask, cur.restrict)
    end
    return ops
end
