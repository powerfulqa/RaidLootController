#!/usr/bin/env lua
-- Runtime suite for the item suitability rules in RLC_Specs.lua. Run from
-- the repo root:  lua tests/test_specs.lua
-- Loads the real Rules and Specs files with a bare namespace (no NS.On), so
-- the client glue at the bottom of RLC_Specs.lua is skipped.

local NS = {}
assert(loadfile("RLC_Rules.lua"))("RaidLootController", NS)
assert(loadfile("RLC_Specs.lua"))("RaidLootController", NS)
local Sp = NS.Specs

local passed, failed = 0, 0
local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. label)
    end
end

local function suits(item)
    local stats = {}
    for _, k in ipairs(item.stats or {}) do
        stats[k] = true
    end
    item.stats = stats
    item.reqLevel = item.reqLevel or 60
    return Sp.SuitedSpecs(item)
end

local function classes(set)
    local out = {}
    for key in pairs(set) do
        out[key:match("^(%u+)")] = true
    end
    return out
end

-- The case that started this: an agility leather item at 60.
do
    local s = suits({ classID = 4, subclassID = 2, equipLoc = "INVTYPE_CHEST", stats = { "AGI", "STA" } })
    check(s["ROGUE.COMBAT"] and s["ROGUE.ASSA"] and s["ROGUE.SUB"], "agility leather: all rogues")
    check(s["DRUID.CAT"] and s["DRUID.BEAR"], "agility leather: feral druids")
    check(
        not s["HUNTER.BM"] and not s["HUNTER.MM"] and not s["HUNTER.SV"],
        "agility leather: NOT hunters (they take mail)"
    )
    check(not s["DRUID.RESTO"] and not s["DRUID.BALANCE"], "agility leather: not caster druids")
    check(not s["SHAMAN.ENH"], "agility leather: not shamans")
end

do
    local s = suits({ classID = 4, subclassID = 3, equipLoc = "INVTYPE_LEGS", stats = { "AGI", "INT" } })
    check(s["HUNTER.MM"] and s["SHAMAN.ENH"], "agility+intellect mail: hunters and enhancement shamans")
    check(not s["SHAMAN.ELE"] and not s["SHAMAN.RESTO"], "agility+intellect mail: not caster shamans")
    check(not s["ROGUE.COMBAT"] and not s["WARRIOR.FURY"], "agility+intellect mail: not rogues or warriors")
end

do
    local s = suits({ classID = 4, subclassID = 2, equipLoc = "INVTYPE_CHEST", reqLevel = 30, stats = { "AGI" } })
    check(s["HUNTER.MM"] and s["ROGUE.COMBAT"], "below level 40 hunters still take leather")
end

do
    local s = suits({ classID = 4, subclassID = 1, equipLoc = "INVTYPE_ROBE", stats = { "INT", "SP" } })
    local c = classes(s)
    check(c.MAGE and c.WARLOCK and s["PRIEST.SHADOW"], "spell damage cloth: casters")
    check(not c.DRUID, "spell damage cloth: not druids (leather)")
    s = suits({ classID = 4, subclassID = 1, equipLoc = "INVTYPE_ROBE", stats = { "INT", "SPI", "SP", "HEAL" } })
    check(s["PRIEST.HOLY"] and s["MAGE.FROST"], "damage and healing cloth: healers and casters")
end

do
    local s = suits({ classID = 4, subclassID = 1, equipLoc = "INVTYPE_CLOAK", stats = { "AGI" } })
    check(s["HUNTER.SV"] and s["ROGUE.SUB"] and s["WARRIOR.FURY"], "agility cloak: no armor rule, melee and hunters")
    check(not s["MAGE.FIRE"], "agility cloak: not mages")
end

do
    local s = suits({ classID = 2, subclassID = 15, equipLoc = "INVTYPE_WEAPON", stats = { "AGI" } })
    check(s["ROGUE.ASSA"], "agility dagger: rogues")
    check(not s["HUNTER.BM"] and not s["WARRIOR.FURY"], "agility dagger: not hunters or warriors")
    s = suits({ classID = 2, subclassID = 2, equipLoc = "INVTYPE_RANGED", stats = { "AGI" } })
    check(s["HUNTER.MM"] and s["ROGUE.COMBAT"] and s["WARRIOR.ARMS"], "agility bow: hunters, rogues, warriors")
    s = suits({ classID = 2, subclassID = 10, equipLoc = "INVTYPE_2HWEAPON", stats = { "INT", "SP" } })
    check(s["MAGE.ARCANE"] and s["DRUID.BALANCE"] and not s["HUNTER.BM"], "spell staff: casters, not hunters")
end

do
    local s = suits({ classID = 4, subclassID = 6, equipLoc = "INVTYPE_SHIELD", stats = { "DEF" } })
    check(s["WARRIOR.PROT"] and s["PALADIN.PROT"], "defense shield: tanks")
    check(not s["SHAMAN.RESTO"] and not s["WARRIOR.ARMS"], "defense shield: not healers or dps")
    s = suits({ classID = 4, subclassID = 8, equipLoc = "INVTYPE_RELIC", stats = {} })
    local c = classes(s)
    check(c.DRUID and not c.PALADIN and not c.SHAMAN, "idol: druids only")
end

do
    local s = suits({ classID = 4, subclassID = 0, equipLoc = "INVTYPE_FINGER", stats = { "STA" } })
    local n = 0
    for _ in pairs(s) do
        n = n + 1
    end
    check(n == #Sp.LIST, "stamina-only ring: every spec")
    s = suits({
        classID = 4,
        subclassID = 2,
        equipLoc = "INVTYPE_CHEST",
        stats = { "AGI" },
        classMask = NS.Rules.ClassBit(11),
    })
    check(s["DRUID.CAT"] and not s["ROGUE.COMBAT"], "a Classes: line limits the specs further")
end

do
    local text = Sp.Describe(
        suits({ classID = 4, subclassID = 2, equipLoc = "INVTYPE_CHEST", stats = { "AGI" } }),
        function(c)
            return c:sub(1, 1) .. c:sub(2):lower()
        end
    )
    check(text == "Rogue, Druid (Feral (cat), Feral (bear))", "readable spec list: " .. text)
    check(Sp.Describe(nil) == "any spec", "no limit reads as any spec")
end

-- Every spec key is well formed for the wire and names a real class.
do
    local ok = true
    for _, spec in ipairs(Sp.LIST) do
        ok = ok and NS.Rules.ValidSpec(spec.key) and spec.class ~= nil
    end
    check(ok and #Sp.LIST == 28, "spec list is complete and wire-safe")
end

print(string.format("test_specs: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
