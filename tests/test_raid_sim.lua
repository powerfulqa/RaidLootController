#!/usr/bin/env lua
-- Raid simulation for RLC_Rules.lua. Run from the repo root:
--   lua tests/test_raid_sim.lua
-- Drives the real rules through A. a golden-path night, B. a chaos night
-- (players and officers who break the rules), C. eight weeks of one roster.
-- Deterministic: seeded Park-Miller (math.random differs between Lua
-- versions) and roster-ordered loops (pairs() order is not stable). What the
-- engine allows that looks unfair does not fail: it prints under FINDINGS.

local NS = {}
assert(loadfile("RLC_Rules.lua"))("RaidLootController", NS)
local R = NS.Rules

local passed, failed = 0, 0
local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. label)
    end
end

-- What a fair raid expects. When the engine allows otherwise, record it once.
local FINDINGS, seen = {}, {}
local function should(cond, label)
    if cond then
        passed = passed + 1
    elseif not seen[label] then
        seen[label] = true
        FINDINGS[#FINDINGS + 1] = label
    end
end

local function rng(seed)
    return function(n)
        seed = seed * 16807 % 2147483647
        return seed % n + 1
    end
end

-- ---- roster and loot table --------------------------------------------------
-- 22 raiders; the first hosts. "Serv Aszune" carries a Forever surname.
local ROSTER = [[Lead=WARRIOR.PROT Brick=WARRIOR.PROT Bear=DRUID.BEAR Axe=WARRIOR.FURY Ret=PALADIN.RET
Stab=ROGUE.COMBAT Shiv=ROGUE.COMBAT Claw=DRUID.CAT Shot=HUNTER.MM Aim=HUNTER.MM Storm=SHAMAN.ENH
Lumi=PALADIN.HOLY Halo=PALADIN.HOLY Mend=PRIEST.HOLY Totem=SHAMAN.RESTO Bark=DRUID.RESTO Ice=MAGE.FROST
Blink=MAGE.FROST Fire=MAGE.FIRE Doom=WARLOCK.DESTRO Serv_Aszune=WARLOCK.DESTRO Void=PRIEST.SHADOW]]
local NAMES, SPEC, CLASS, CLASS_ID = {}, {}, {}, {}
for id, token in pairs(R.CLASS_TOKEN) do
    CLASS_ID[token] = id
end
for name, spec in ROSTER:gmatch("(%S+)=(%S+)") do
    name = name:gsub("_", " ") .. "-Realm"
    NAMES[#NAMES + 1], SPEC[name], CLASS[name] = name, spec, CLASS_ID[spec:match("^%u+")]
end
local HOST = NAMES[1]

local SETS = {
    tank = "DRUID.BEAR,PALADIN.PROT,WARRIOR.PROT",
    plate = "PALADIN.RET,WARRIOR.ARMS,WARRIOR.FURY",
    leather = "DRUID.CAT,ROGUE.ASSA,ROGUE.COMBAT,ROGUE.SUB",
    mail = "HUNTER.BM,HUNTER.MM,HUNTER.SV,SHAMAN.ENH",
    heal = "DRUID.RESTO,PALADIN.HOLY,PRIEST.DISC,PRIEST.HOLY,SHAMAN.RESTO",
    cloth = "MAGE.FIRE,MAGE.FROST,PRIEST.SHADOW,WARLOCK.AFFLI,WARLOCK.DESTRO",
    phys = "DRUID.CAT,HUNTER.MM,PALADIN.RET,ROGUE.COMBAT,SHAMAN.ENH,WARRIOR.ARMS,WARRIOR.FURY",
    caster = "DRUID.BALANCE,MAGE.FIRE,MAGE.FROST,PRIEST.SHADOW,SHAMAN.ELE,WARLOCK.DESTRO",
}
local KINDS = { "tank", "plate", "leather", "mail", "heal", "cloth", "phys", "caster" }
-- 5 bosses x 6 items: boss b can drop item 100*b+i, "Best for" SETS[kind].
local ITEM_SPECS, ALL_ITEMS = {}, {}
for b = 1, 5 do
    for i = 1, 6 do
        local id = 100 * b + i
        ALL_ITEMS[#ALL_ITEMS + 1] = id
        ITEM_SPECS[id] = SETS[KINDS[(#ALL_ITEMS - 1) % #KINDS + 1]]
    end
end

local function suits(name, id)
    return SPEC[name] ~= nil and ("," .. ITEM_SPECS[id] .. ","):find("," .. SPEC[name] .. ",", 1, true) ~= nil
end

local ctx = {
    classOf = function(n)
        return CLASS[n]
    end,
    now = 1000,
    describe = function(s) -- the host's "Best for" (RLC_Specs) on ADD
        return 0, ITEM_SPECS[R.ItemIDOf(s)] or ""
    end,
}

-- ---- harness (the tests/test_rules.lua pattern) -----------------------------
-- Send ops over the wire codec and apply them to copy S (nil = a fresh one).
local function wire(ops, S)
    local enc = {}
    for _, op in ipairs(ops) do
        enc[#enc + 1] = R.EncodeOp(op)
    end
    for _, msg in ipairs(R.Pack(enc, 250)) do
        for _, op in ipairs(R.Decode(msg)) do
            S = assert(R.Apply(S, op))
        end
    end
    return S
end

-- Intent on the host copy, the ops replayed on a client copy.
local host, client
local function act(who, req)
    local ops, note = R.Intent(host, who, req, ctx)
    if not ops then
        return nil, note
    end
    for _, op in ipairs(ops) do
        host = assert(R.Apply(host, op))
    end
    client = wire(ops, client)
    return ops, note
end

local function newRaid(n)
    local new = { "NEW", HOST .. "-" .. n, HOST, "Sim", n }
    host, client = R.Apply(nil, new), wire({ new })
end

local function same(a, b, path)
    if type(a) ~= type(b) or type(a) ~= "table" then
        return a == b, path
    end
    for k, v in pairs(a) do
        local ok, p = same(v, b[k], path .. "." .. tostring(k))
        if not ok then
            return false, p
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false, path .. "." .. tostring(k)
        end
    end
    return true
end

-- A client that reloads: rebuild S from the host's snapshot.
local function rebuild(S)
    return wire(R.Snapshot(S))
end

local function inSync(label)
    local ok, where = same(host, client, "S")
    check(ok, label .. ": client copy matches host (differs at " .. tostring(where) .. ")")
    ok, where = same(host, rebuild(host), "S")
    check(ok, label .. ": snapshot replay matches host (differs at " .. tostring(where) .. ")")
end

-- Members of `set` in roster order.
local function ordered(set, present)
    local out = {}
    for _, n in ipairs(present) do
        if set[n] then
            out[#out + 1] = n
        end
    end
    return out
end

-- ---- one raid night ----------------------------------------------------------
-- o = { id, present, drops, reserves, roll, wantPct, owned, prio, strict }
-- Raiders want what suits them and they do not own yet. With o.prio the sim
-- (not the addon) adds a cross-week rule: if any wanter is in o.prio, only
-- those wanters roll. Returns items won and who wanted something, by name.
local function runNight(o, label)
    newRaid(o.id)
    for _, n in ipairs(o.present) do
        o.owned[n] = o.owned[n] or {}
        act(n, { "SPEC", SPEC[n] })
        if o.reserves[n] then
            act(n, { "RES", o.reserves[n] })
        end
    end
    act(HOST, { "PHASE", "live" })
    local got, wanted, locked = {}, {}, {}
    for _, id in ipairs(o.drops) do
        local key = act(HOST, { "ADD", "item:" .. id })[1][2]
        act(HOST, { "START", key })
        local it = host.items[key]
        for _, n in ipairs(o.present) do
            if it.mode == "normal" and not o.owned[n][id] and R.CanWant(host, it, n, CLASS[n]) then
                if o.roll(100) <= o.wantPct and act(n, { "WANT", key, 1 }) then
                    wanted[n] = true
                end
            end
        end
        act(HOST, { "CALL", key })
        if it.state == "interest" then -- opened to all: locked players who need it want it now
            if o.strict then
                check(next(it.wants) == nil, label .. ": item " .. id .. " opens only if no unlocked player wants it")
            end
            for _, n in ipairs(o.present) do
                if not o.owned[n][id] and suits(n, id) and act(n, { "WANT", key, 1 }) then
                    wanted[n] = true
                end
            end
            act(HOST, { next(it.wants) and "CALL" or "CANCEL", key })
        end
        local rollers = ordered(it.restrict or it.wants, o.present)
        if o.prio and it.mode == "normal" and #ordered(o.prio, rollers) > 0 then
            rollers = ordered(o.prio, rollers)
        end
        while it.state == "rolling" do
            for _, n in ipairs(rollers) do
                act(HOST, { "ROLLSEEN", n, o.roll(100), 1, 100 })
            end
            if not act(HOST, { "CLOSE", key }) then
                act(HOST, { "CANCEL", key })
            end
            rollers = ordered(it.restrict or {}, o.present) -- after a tie only they roll
        end
        local w = it.winner
        if w then
            got[w], o.owned[w][id] = (got[w] or 0) + 1, true
            if o.strict and (it.how == "roll" or it.how == "manual") then
                check(not locked[w], label .. ": " .. w .. " gets one item before anyone gets two")
            end
            locked[w] = locked[w] or it.how ~= "open"
        end
    end
    inSync(label)
    return got, wanted
end

-- ---- A. golden path ----------------------------------------------------------
do
    local o = { id = 1, present = NAMES, roll = rng(20261009), wantPct = 100, owned = {}, strict = true }
    o.reserves = { ["Ice-Realm"] = 302, ["Blink-Realm"] = 302, ["Brick-Realm"] = 501, ["Bark-Realm"] = 105 }
    o.drops = { 101, 102, 103, 201, 202, 301, 302, 303, 401, 402, 501, 502, 503 }
    runNight(o, "golden")
    for _, key in ipairs(host.order) do
        local it = host.items[key]
        if it.itemID == 302 then
            check(it.how == "reserve" and (it.winner == "Ice-Realm" or it.winner == "Blink-Realm"), "golden: shared")
        elseif it.itemID == 501 then
            check(it.winner == "Brick-Realm" and it.how == "reserve", "golden: single reserve paid out")
        end
        check(it.state == "done" or it.state == "cancelled", "golden: item " .. it.itemID .. " finished")
    end
end

-- ---- B. chaos night ------------------------------------------------------------
local function liveRaid(n)
    newRaid(n)
    for _, name in ipairs(NAMES) do
        act(name, { "SPEC", SPEC[name] })
    end
    act(HOST, { "PHASE", "live" })
end
local function up(id) -- item added and open for interest
    local key = act(HOST, { "ADD", "item:" .. id })[1][2]
    act(HOST, { "START", key })
    return key, host.items[key]
end
local function roll(n, v, lo, hi)
    return act(HOST, { "ROLLSEEN", n, v, lo or 1, hi or 100 })
end
local function round(key, wants, rolls) -- WANTs, CALL, the server rolls, CLOSE
    for _, n in ipairs(wants) do
        act(n, { "WANT", key, 1 })
    end
    act(HOST, { "CALL", key })
    for i = 1, #rolls, 2 do
        roll(rolls[i], rolls[i + 1])
    end
    return act(HOST, { "CLOSE", key })
end

do -- WANT spam, early, double, odd-range and late rolls, an outsider
    liveRaid(101)
    local key, it = up(106) -- cloth
    for i = 1, 20 do
        act("Ice-Realm", { "WANT", key, i % 2 })
    end
    check(not it.wants["Ice-Realm"] and same(host, client, "S"), "spam: last WANT toggle wins, copies agree")
    act("Fire-Realm", { "WANT", key, 1 })
    local _, why = roll("Fire-Realm", 99)
    check(it.rolls["Fire-Realm"] == nil, "a roll before CALL is ignored")
    should(why, "A /roll before CALL is dropped silently, no 'too early' reply [L644-645]")
    act(HOST, { "CALL", key })
    check(not roll("Fire-Realm", 500, 1, 1000) and not roll("Fire-Realm", 30, 1, 50), "/roll 1000, /roll 50 refused")
    check(roll("Fire-Realm", 40) and roll("Fire-Realm", 90) == nil, "second roll refused")
    check(roll("Stranger-Realm", 100) == nil, "outsider roll refused")
    roll("Ice-Realm", 70) -- took the want back, rolls anyway
    act(HOST, { "CLOSE", key })
    should(it.winner ~= "Ice-Realm", "Documented: /roll counts without WANT; a withdrawn want wins [L319-320]")
    check(roll("Fire-Realm", 100) == nil and it.rolls["Fire-Realm"] == 40, "a roll after CLOSE is ignored")
    inSync("chaos rolls")
end

do -- specs: another class, switching after start, late joiner; worn gear
    newRaid(102)
    check(act("Ice-Realm", { "SPEC", "WARRIOR.FURY" }) == nil, "mage cannot claim a warrior spec")
    act("Ice-Realm", { "SPEC", "MAGE.FROST" })
    act(HOST, { "PHASE", "live" })
    check(act("Ice-Realm", { "SPEC", "MAGE.FIRE" }) == nil, "spec switch after start refused")
    check(act(HOST, { "SETSPEC", "Ice-Realm", "MAGE.FIRE" }), "officer may switch it")
    local LATE = "Late-Realm" -- a priest joins after start, no spec reported
    CLASS[LATE] = 5
    local heal = up(105)
    local healOK = act(LATE, { "WANT", heal, 1 })
    act(HOST, { "CANCEL", heal })
    local cloth = up(106)
    should(not (healOK and act(LATE, { "WANT", cloth, 1 })), "No spec on record: heal AND shadow items [L301-308]")
    local first = act(LATE, { "SPEC", "PRIEST.SHADOW" })
    check(first and act(LATE, { "SPEC", "PRIEST.HOLY" }) == nil, "late joiner's first spec counts, then locks")
    should(not first, "Spec-less raider picks a spec after seeing drops [L620]")
    act("Fire-Realm", { "WANT", cloth, 1, "item:99999" })
    should(not host.items[cloth].worn["Fire-Realm"], "Made-up worn gear shown to officers as real [L486,602]")
    act("Doom-Realm", { "WANT", cloth, 1, string.rep("item:1,", 40) })
    act("Void-Realm", { "WANT", cloth, 1, "item:1|Hx|h,item:2" })
    local w = host.items[cloth]
    local junk = w.worn["Doom-Realm"] or w.worn["Void-Realm"]
    check(w.wants["Doom-Realm"] and w.wants["Void-Realm"] and not junk, "junk worn dropped, wants kept")
    CLASS[LATE] = nil
    inSync("chaos specs")
end

do -- a raider sends officer and host requests
    liveRaid(103)
    local key = up(101)
    act("Brick-Realm", { "WANT", key, 1 })
    local before = rebuild(host)
    local reqs = "OPEN K;AWARD K M;LOCK M 0;SETSPEC M ROGUE.SUB;OFF M 1;ADD item:1;PHASE ended;CALL K;CLOSE K;"
        .. "CANCEL K;SPECS K;UNDO K;START K;ROLLSEEN M 100 1 100"
    for line in reqs:gmatch("[^;]+") do
        local req = {}
        for word in line:gmatch("%S+") do
            req[#req + 1] = word == "K" and key or word == "M" and "Stab-Realm" or word
        end
        check(act("Stab-Realm", req) == nil, "raider refused: " .. line)
    end
    check(same(host, before, "S"), "refused requests change nothing")
end

do -- a colluding officer: OPEN, LOCK 0 and AWARD for a friend
    liveRaid(104)
    local OFFI, FRIEND, RIVAL = "Mend-Realm", "Axe-Realm", "Ret-Realm"
    act(HOST, { "OFF", OFFI, 1 })
    round(up(102), { RIVAL, FRIEND }, { FRIEND, 90, RIVAL, 10 })
    local key = up(102) -- an item the unlocked rival can use and wants
    act(RIVAL, { "WANT", key, 1 })
    should(not act(OFFI, { "OPEN", key }), "Officer OPENs an item an unlocked player wants [L759-763]")
    round(key, {}, { FRIEND, 95, RIVAL, 40 }) -- locked friend's roll does not count
    should(host.items[key].winner == RIVAL, "Locked friend beat the unlocked rival on a normal item")
    local n = 0
    for _, k in ipairs(host.order) do
        local it = host.items[k]
        n = n + ((it.winner == FRIEND and it.how ~= "open") and 1 or 0)
    end
    should(n <= 1, "Officer's friend got " .. n .. " locking wins [L759]")
    should(not act(OFFI, { "LOCK", FRIEND, 0 }), "Officer unlocks a friend after each win [L685-689]")
    local k5 = up(102)
    act(RIVAL, { "WANT", k5, 1 })
    should(not act(OFFI, { "AWARD", k5, FRIEND }), "AWARD to a locked non-wanter over a wanter [L764-773]")
    local k6 = act(HOST, { "ADD", "item:103" })[1][2]
    should(not act(OFFI, { "AWARD", k6, "Nobody-Realm" }), "AWARD unstarted, to a non-member [L765-773]")
    inSync("chaos officer")
end

do -- UNDO and re-award; a tie; a player leaves mid-roll
    liveRaid(105)
    local key, it = up(103) -- leather
    round(key, { "Stab-Realm" }, { "Stab-Realm", 50 })
    act(HOST, { "UNDO", key })
    check(it.state == "pending" and not host.locks["Stab-Realm"] and not next(it.wants), "undo: item back, unlocked")
    act(HOST, { "START", key })
    round(key, { "Stab-Realm", "Shiv-Realm" }, { "Stab-Realm", 20, "Shiv-Realm", 80 })
    check(it.winner == "Shiv-Realm" and host.locks["Shiv-Realm"] and not host.locks["Stab-Realm"], "re-award locks")

    local tk, tie = up(202) -- caster
    round(tk, { "Fire-Realm", "Doom-Realm" }, { "Fire-Realm", 77, "Doom-Realm", 77, "Ice-Realm", 10 })
    check(tie.state == "rolling" and tie.restrict["Fire-Realm"] and not tie.restrict["Ice-Realm"], "tie: reroll")
    check(roll("Ice-Realm", 99) == nil and roll("Void-Realm", 99) == nil, "tie: other rolls refused")
    round(tk, {}, { "Fire-Realm", 30, "Doom-Realm", 60 }) -- CALL is refused: already rolling
    check(tie.winner == "Doom-Realm", "re-roll decides the tie")

    local mk, mail = up(104)
    act("Aim-Realm", { "WANT", mk, 1 })
    act(HOST, { "CALL", mk })
    roll("Shot-Realm", 99)
    roll("Aim-Realm", 50)
    CLASS["Shot-Realm"] = nil -- left the group before CLOSE
    act(HOST, { "CLOSE", mk })
    should(mail.winner ~= "Shot-Realm", "A player who left mid-roll still wins on their roll [L750-753]")
    CLASS["Shot-Realm"] = 3
    inSync("chaos undo/tie/leave")
end

do -- reserves: an absent reserver, an off-spec reserver
    newRaid(106)
    act("Totem-Realm", { "RES", 105 })
    act("Ice-Realm", { "RES", 101 }) -- a mage reserves a tank item
    act(HOST, { "PHASE", "live" })
    CLASS["Totem-Realm"] = nil -- did not come tonight
    local k1, absent = up(105)
    act("Mend-Realm", { "WANT", k1, 1 })
    act(HOST, { "CALL", k1 })
    should(absent.winner ~= "Totem-Realm", "Absent player's reserve wins on CALL [L710,723-730]")
    CLASS["Totem-Realm"] = 7
    local k2, tank = up(101)
    act("Brick-Realm", { "WANT", k2, 1 })
    act(HOST, { "CALL", k2 })
    should(tank.winner ~= "Ice-Realm", "Documented: reserve ignores Best for [L292-293]")
    inSync("chaos reserves")
end

do -- the host's client reloads mid-raid; forged ops
    liveRaid(107)
    local k1 = up(101)
    round(k1, { "Brick-Realm" }, { "Brick-Realm", 60 })
    act(HOST, { "LOCK", "Brick-Realm", 0 })
    act(HOST, { "CANCEL", (up(106)) })
    local k3, it = up(302)
    act("Ice-Realm", { "WANT", k3, 1 })
    act(HOST, { "CALL", k3 })
    roll("Ice-Realm", 33)
    client = rebuild(host) -- reload
    check(same(host, client, "S") and client.active == k3 and not client.locks["Brick-Realm"], "reload: copy = host")

    roll("Fire-Realm", 44)
    act(HOST, { "CLOSE", k3 })
    check(it.winner == "Fire-Realm" and same(host, client, "S"), "reload: rebuilt copy keeps up with live ops")
    -- Apply has no sender: it takes any well-formed op. Trust is RLC_Net.lua's
    -- job (not loaded here): state ops only from S.host (RLC_Net.lua:237), NEW
    -- only in the sender's own name and from the leader (RLC_Net.lua:177-193).
    local forged = rebuild(host)
    check(R.Apply(forged, { "AWARD", k1, "Stab-Realm", "roll", 0 }), "Apply takes a forged AWARD (Net drops it)")
    check(R.Apply(forged, { "LOCK", "Stab-Realm", 0 }), "Apply takes a forged LOCK (Net drops it)")
    check(R.Apply(forged, { "NEW", "Stab-Realm-1", "Stab-Realm", "x", 1 }), "Apply takes a forged NEW (Net drops it)")
    check(R.Apply(forged, { "ROLL", k3, "Stab-Realm", 1000 }) == nil, "Apply refuses a roll over 100")
end

-- ---- C. eight weeks, one roster ------------------------------------------------
-- 85% attendance, each boss item drops with 40% chance, raiders want an item
-- that suits them with 70% chance, everyone present reserves one item.
local WEEKS = 8
local function season(usePrio)
    local world, luck = rng(4242), rng(777) -- world (attendance, drops) is the same in both variants
    local owned, total, drought, longest, zero, starved = {}, {}, {}, {}, {}, {}
    for _, n in ipairs(NAMES) do
        total[n], drought[n], longest[n] = 0, 0, 0
    end
    for week = 1, WEEKS do
        local o = { id = week, present = {}, drops = {}, reserves = {}, roll = luck, wantPct = 70, owned = owned }
        o.prio = usePrio and starved or nil
        for _, n in ipairs(NAMES) do
            if n == HOST or world(100) <= 85 then
                o.present[#o.present + 1] = n
                owned[n] = owned[n] or {}
            end
        end

        for _, id in ipairs(ALL_ITEMS) do
            if world(5) <= 2 then
                o.drops[#o.drops + 1] = id
            end
        end
        for _, n in ipairs(o.present) do
            local need = {}
            for _, id in ipairs(ALL_ITEMS) do
                if suits(n, id) and not owned[n][id] then
                    need[#need + 1] = id
                end
            end
            o.reserves[n] = need[1] and need[luck(#need)]
        end
        local got, wanted = runNight(o, (usePrio and "prio" or "base") .. " week " .. week)
        for _, n in ipairs(o.present) do
            total[n] = total[n] + (got[n] or 0)
            drought[n] = got[n] and 0 or wanted[n] and drought[n] + 1 or drought[n]
            longest[n] = math.max(longest[n], drought[n])
            starved[n] = drought[n] > 0 or nil -- wanted and got nothing the last time they came
        end
        zero[week] = 0
        for _, n in ipairs(NAMES) do
            zero[week] = zero[week] + (total[n] == 0 and 1 or 0)
        end
    end
    local lo, hi, dry = math.huge, 0, 0
    for _, n in ipairs(NAMES) do
        lo, hi, dry = math.min(lo, total[n]), math.max(hi, total[n]), math.max(dry, longest[n])
    end
    return { total = total, zero = zero, lo = lo, hi = hi, dry = dry }
end

local base, prio = season(false), season(true)
print(string.format("\nC. %d weeks, %d raiders. Items per player:", WEEKS, #NAMES))
print(string.format("%-18s %-15s %5s %5s", "player", "spec", "base", "prio"))
for _, n in ipairs(NAMES) do
    print(string.format("%-18s %-15s %5d %5d", n, SPEC[n], base.total[n], prio.total[n]))
end
for _, v in ipairs({ { "base", base }, { "prio", prio } }) do
    local s = v[2]
    local fmt = "%s: players with 0 items at week 4: %d, week %d: %d; min-max %d-%d (spread %d); longest drought %d"
    print(string.format(fmt, v[1], s.zero[4], WEEKS, s.zero[WEEKS], s.lo, s.hi, s.hi - s.lo, s.dry))
end

print("\nFINDINGS (" .. #FINDINGS .. "; [L] = line in RLC_Rules.lua)")
for i, f in ipairs(FINDINGS) do
    print(i .. ". " .. f)
end
print(string.format("test_raid_sim: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
