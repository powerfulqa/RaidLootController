-- RLC_Demo.lua
-- /rlc demo: fill the window with a made-up raid, to see what a full raid,
-- history and catalogue look like.
--
-- The raids and bosses are Forever's own (Barrow Deeps, Hyjal Summit), but
-- their loot is not known yet, so which boss drops which item here is made
-- up. Every item ID is one the Forever client has (checked against an item
-- table read from the client); Classic raid loot such as Molten Core's is
-- not in the client and would only show as "[item 12345]".
--
-- Safe by construction:
--   * The real saved data is swapped out, not touched: NS.DB points at an
--     in-memory demo table until demo mode ends (/rlc demo again or a
--     /reload). Nothing made in demo mode is saved.
--   * RLC_Net sends nothing and ignores incoming messages while demo mode
--     is on, and announcements stay out of raid chat, so nothing reaches
--     the group or the guild.
-- You are the host, so every officer button works on the fake raid.
local _, NS = ...
local Rules = NS.Rules

local Demo = { active = false }
NS.Demo = Demo

local REALM = "Demo"

-- name, spec
local RAIDERS = {
    { "Brakk", "WARRIOR.PROT" },
    { "Gorrum", "WARRIOR.FURY" },
    { "Lyssa", "PALADIN.HOLY" },
    { "Aldric", "PALADIN.RET" },
    { "Fenna", "HUNTER.MM" },
    { "Tavik", "HUNTER.BM" },
    { "Shade", "ROGUE.COMBAT" },
    { "Vex", "ROGUE.ASSA" },
    { "Miriel", "PRIEST.HOLY" },
    { "Noct", "PRIEST.SHADOW" },
    { "Ruka", "SHAMAN.RESTO" },
    { "Tor", "SHAMAN.ENH" },
    { "Ilyra", "MAGE.FROST" },
    { "Pyra", "MAGE.FIRE" },
    { "Morv", "WARLOCK.AFFLI" },
    { "Zev", "WARLOCK.DESTRO" },
    { "Oaken", "DRUID.RESTO" },
    { "Fang", "DRUID.CAT" },
    { "Ursa", "DRUID.BEAR" },
    { "Sel", "DRUID.BALANCE" },
}

local CLASS_ID = {}
for id, token in pairs(Rules.CLASS_TOKEN) do
    CLASS_ID[token] = id
end

local BARROW, HYJAL = 2001, 2002 -- made-up instance keys for the demo catalogue

local function full(short)
    return short .. "-" .. REALM
end

local function classOf(spec)
    return spec:match("^(%u+)%.")
end

-- Keeps the fake raiders in the roster (RefreshRoster calls this).
function Demo.AddRoster(roster)
    for _, r in ipairs(RAIDERS) do
        local token = classOf(r[2])
        roster[full(r[1])] = {
            classID = CLASS_ID[token],
            classFile = token,
            lead = false,
            assist = r[1] == "Lyssa",
        }
    end
end

local function apply(S, op)
    return assert(Rules.Apply(S, op))
end

-- A finished item: add, wants and rolls, then the award.
local function wonItem(S, key, itemID, specs, mode, winner, how, rolls, t)
    S = apply(S, { "ADD", key, "item:" .. itemID })
    S = apply(S, { "ITEM", key, "rolling", mode, 0, "", specs or "" })
    for name, n in pairs(rolls or {}) do
        S = apply(S, { "WANT", key, full(name), 1 })
        S = apply(S, { "ROLL", key, full(name), n })
    end
    return apply(S, { "AWARD", key, full(winner), how, t })
end

-- The live raid: a mix of every item state, one item being rolled for now.
local function buildSession(now)
    local me = NS.Me()
    local S = apply(nil, { "NEW", me .. "-demo", me, "Barrow Deeps (demo)", now - 5400 })
    for _, r in ipairs(RAIDERS) do
        S = apply(S, { "SPEC", full(r[1]), r[2] })
    end
    local mine = NS.Specs.Mine()
    if mine then
        S = apply(S, { "SPEC", me, mine })
    end
    -- Reserves made before the start: two hunters want the same bow.
    S = apply(S, { "RES", full("Fenna"), 16677 })
    S = apply(S, { "RES", full("Tavik"), 16677 })
    S = apply(S, { "RES", full("Tor"), 16466 })
    S = apply(S, { "RES", full("Gorrum"), 16730 })
    S = apply(S, { "PHASE", "live", now - 4800 })
    S = apply(S, { "OFF", full("Lyssa"), 1 })

    local mageSpecs = "MAGE.ARCANE,MAGE.FIRE,MAGE.FROST"
    local rogueDruid = "DRUID.BEAR,DRUID.CAT,ROGUE.ASSA,ROGUE.COMBAT,ROGUE.SUB"
    S = wonItem(S, "1", 16688, mageSpecs, "normal", "Ilyra", "roll", { Ilyra = 88, Pyra = 41 }, now - 4500)
    S = wonItem(S, "2", 16730, "", "reserve", "Gorrum", "reserve", nil, now - 3600)
    S = wonItem(S, "3", 16453, rogueDruid, "normal", "Shade", "roll", { Shade = 92, Fang = 67, Vex = 15 }, now - 3000)
    S = wonItem(S, "4", 18879, "WARRIOR.PROT", "normal", "Brakk", "manual", nil, now - 2400)
    S = wonItem(S, "5", 18814, "", "open", "Pyra", "open", { Pyra = 77, Ilyra = 54, Noct = 23 }, now - 1800)

    -- Up now: a rogue dagger. Shade already has an item, so only Vex can
    -- roll unless nobody else wants it.
    S = apply(S, { "ADD", "6", "item:21404" })
    S = apply(S, { "ITEM", "6", "rolling", "normal", 0, "", "ROGUE.ASSA,ROGUE.COMBAT,ROGUE.SUB" })
    S = apply(S, { "WANT", "6", full("Vex"), 1 })
    S = apply(S, { "WANT", "6", full("Shade"), 1 })
    S = apply(S, { "ROLL", "6", full("Vex"), 74 })

    -- Waiting their turn.
    S = apply(S, { "ADD", "7", "item:16677" }) -- reserved by two hunters
    S = apply(S, { "ADD", "8", "item:16466" })
    S = apply(S, { "ITEM", "8", "pending", "normal", 0, "", "HUNTER.BM,HUNTER.MM,HUNTER.SV,SHAMAN.ENH" })
    S = apply(S, { "ADD", "9", "item:16455" })
    S = apply(S, { "ITEM", "9", "pending", "normal", 0, "", "ROGUE.ASSA,ROGUE.COMBAT,ROGUE.SUB" })
    S = apply(S, { "ADD", "10", "item:21405" })
    S = apply(S, { "CANCEL", "10" })
    S = apply(S, { "ADD", "11", "item:18821" })
    return S
end

-- A past raid for the History tab.
local function pastRaid(title, daysAgo, wins, now)
    local t = now - daysAgo * 86400
    local S = apply(nil, { "NEW", "demo-" .. daysAgo, NS.Me(), title, t })
    S = apply(S, { "PHASE", "live", t + 600 })
    for i, w in ipairs(wins) do
        local mode = w[3] == "open" and "open" or "normal"
        S = wonItem(S, tostring(i), w[1], "", mode, w[2], w[3], w[4], t + 600 + i * 300)
    end
    return apply(S, { "PHASE", "ended", t + 10800 })
end

-- Over several weeks: instance, name, encounter key, boss, kills, items with drops.
local CATALOG = {
    { BARROW, "Barrow Deeps", 900001, "Chillhowl", 8, { { 16688, 5 }, { 16698, 4 }, { 18543, 2 }, { 21406, 1 } } },
    {
        BARROW,
        "Barrow Deeps",
        900002,
        "Elder Tangleclaw",
        8,
        { { 16453, 4 }, { 16455, 3 }, { 21404, 1 }, { 16677, 2 } },
    },
    { BARROW, "Barrow Deeps", 900003, "Khalith the Dreadspinner", 7, { { 16693, 4 }, { 16690, 3 }, { 19140, 2 } } },
    { BARROW, "Barrow Deeps", 900004, "Well of Sorrow", 7, { { 18879, 1 }, { 16730, 3 }, { 16733, 2 }, { 16731, 2 } } },
    { BARROW, "Barrow Deeps", 900005, "Amethrax", 6, { { 16674, 4 }, { 16466, 1 }, { 16669, 3 }, { 16666, 2 } } },
    { BARROW, "Barrow Deeps", 900006, "Del'lynar Songwood", 6, { { 21405, 2 }, { 18821, 3 }, { 21403, 2 } } },
    { BARROW, "Barrow Deeps", 900007, "Ravus and Darlissa", 5, { { 18814, 2 }, { 19147, 2 }, { 16700, 3 } } },
    { BARROW, "Barrow Deeps", 900008, "Sonya Darkhallow", 5, { { 21596, 1 }, { 21583, 2 }, { 21710, 1 } } },
    { BARROW, "Barrow Deeps", 0, "Trash", 0, { { 19083, 4 }, { 20068, 3 } } },
    { HYJAL, "Hyjal Summit", 900101, "Bandalar", 4, { { 21664, 2 }, { 21677, 1 } } },
    { HYJAL, "Hyjal Summit", 900102, "Ancient of Decay", 3, { { 22939, 1 }, { 22943, 2 } } },
}

local function buildCatalog(now)
    local cat = {}
    local C = NS.Catalog
    for order, b in ipairs(CATALOG) do
        local inst, instName, key, name, kills, items = b[1], b[2], b[3], b[4], b[5], b[6]
        local first = now - 40 * 86400 + order * 300
        for k = 1, kills do
            C.CountKill(cat, inst, instName, key, name, "demo" .. key .. ":" .. k, first)
        end
        for _, it in ipairs(items) do
            for k = 1, it[2] do
                local killId = "demo" .. key .. ":" .. k .. ":" .. it[1]
                C.Record(cat, inst, instName, key, name, "item:" .. it[1], killId, now - k * 7 * 86400)
            end
        end
    end
    return cat
end

function Demo.Toggle()
    if not NS.DB then
        return
    end
    if Demo.active then
        Demo.active = false
        NS.DB = RaidLootControllerDB
        NS.RefreshRoster()
        NS.Refresh()
        NS.Print("Demo mode off. Your real raid data is back.")
        return
    end
    local real = NS.DB
    local now = GetServerTime()
    local db = {
        history = {},
        classes = {},
        owed = { [full("Shade")] = { "item:16453" } },
        catalog = {},
        mySpec = real.mySpec, -- your own spec choice, unchanged
        announce = false,
        minQuality = real.minQuality,
        minimapButton = real.minimapButton,
        minimapAngle = real.minimapAngle,
    }
    for _, r in ipairs(RAIDERS) do
        db.classes[full(r[1])] = classOf(r[2])
    end
    Demo.active = true
    NS.DB = db
    db.session = buildSession(now)
    local past = {
        pastRaid("Barrow Deeps", 7, {
            { 16698, "Morv", "roll", { Morv = 61, Zev = 33 } },
            { 21406, "Shade", "roll", { Shade = 95, Vex = 12, Fang = 50 } },
            { 16690, "Miriel", "roll", { Miriel = 70 } },
            { 16733, "Brakk", "manual" },
        }, now),
        pastRaid("Barrow Deeps", 14, {
            { 16693, "Noct", "roll", { Noct = 44, Miriel = 39 } },
            { 16669, "Tor", "open", { Tor = 81, Brakk = 20 } },
            { 19140, "Lyssa", "roll", { Lyssa = 99, Ruka = 2 } },
        }, now),
        pastRaid("Hyjal Summit", 21, {
            { 18543, "Pyra", "roll", { Pyra = 58, Ilyra = 57 } },
            { 21403, "Fenna", "roll", { Fenna = 66 } },
        }, now),
    }
    for _, S in ipairs(past) do
        db.history[S.id] = S
    end
    db.history[db.session.id] = CopyTable(db.session)
    db.catalog = buildCatalog(now)
    NS.RefreshRoster()
    NS.Show()
    NS.Print("Demo mode on: a made-up raid to look around. Nothing is sent or saved. /rlc demo again to leave.")
    NS.Print("Real Forever raids and bosses, but which boss drops which item is made up.")
end
