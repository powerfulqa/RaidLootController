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

-- Tooltip lines through the real reader, then the rules. `primary` stands
-- for GetItemStats keys (strength, intellect and so on).
local function fromLines(item, primary, lines)
    local t = {}
    for i, text in ipairs(lines) do
        t[i] = { leftText = text }
    end
    item.stats = Sp.ItemKinds(primary, t)
    item.reqLevel = 60
    return Sp.SuitedSpecs(item), item.stats
end
local INT = { ITEM_MOD_INTELLECT_SHORT = 5 }
local AGI = { ITEM_MOD_AGILITY_SHORT = 5 }

-- S1: no free supersets inside a class.
do
    local s = suits({ classID = 4, subclassID = 0, equipLoc = "INVTYPE_FINGER", stats = { "INT", "SP" } })
    check(not s["PALADIN.PROT"], "spell damage ring: not protection paladins")
    s = suits({ classID = 4, subclassID = 4, equipLoc = "INVTYPE_CHEST", stats = { "STR", "DEF" } })
    check(s["PALADIN.PROT"] and s["WARRIOR.PROT"], "defense plate: tanks still")
    s = suits({ classID = 4, subclassID = 2, equipLoc = "INVTYPE_CHEST", stats = { "DEF" } })
    check(s["DRUID.BEAR"] and not s["DRUID.CAT"], "defense leather: bear, not cat")
    s = suits({ classID = 4, subclassID = 2, equipLoc = "INVTYPE_CHEST", stats = { "AP" } })
    check(s["DRUID.CAT"] and not s["DRUID.BEAR"], "attack power leather: cat, not bear")
end

-- S2: spell damage and healing apart, "damage and healing" to both.
do
    local robe = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_ROBE" }
    local s, k = fromLines(robe, INT, { "Equip: Increases healing done by spells and effects by up to 44." })
    check(k.HEAL and not k.SP, "healing line reads as healing only")
    check(s["PRIEST.HOLY"] and s["PRIEST.DISC"], "healing cloth: holy and discipline priests")
    check(not s["MAGE.FIRE"] and not s["WARLOCK.AFFLI"] and not s["PRIEST.SHADOW"], "healing cloth: no dps casters")
    s = fromLines(robe, INT, { "Equip: Increases damage done by Shadow spells and effects by up to 20." })
    check(s["WARLOCK.AFFLI"] and s["PRIEST.SHADOW"], "shadow damage cloth: warlocks and shadow priests")
    check(not s["PRIEST.HOLY"], "shadow damage cloth: not holy priests")
    -- Mana Igniting Cord (Molten Core).
    s, k = fromLines({ classID = 4, subclassID = 1, equipLoc = "INVTYPE_WAIST" }, INT, {
        "Equip: Improves your chance to get a critical strike with spells by 1%.",
        "Equip: Increases damage and healing done by magical spells and effects by up to 25.",
    })
    check(k.SP and k.HEAL and not k.AP, "Mana Igniting Cord reads as spell damage and healing")
    check(s["MAGE.FIRE"] and s["PRIEST.HOLY"] and s["PRIEST.SHADOW"], "Mana Igniting Cord: casters and healers")
    s, k = fromLines(robe, INT, { "Equip: Improves your chance to get a critical strike with Holy spells by 1%." })
    check(k.HEAL and not k.SP and not k.AP, "holy spell crit reads as healing")
    check(s["PRIEST.HOLY"] and not s["MAGE.FIRE"], "holy spell crit cloth: priests, not mages")
    k = Sp.ItemKinds({ ITEM_MOD_SPELL_POWER_SHORT = 30 }, nil)
    check(k.SP and k.HEAL, "modern spell power key counts as both")
end

-- S3: "Use:" lines and hit or crit lines tell too.
do
    local trinket = { classID = 4, subclassID = 0, equipLoc = "INVTYPE_TRINKET" }
    -- Talisman of Ephemeral Power.
    local s = fromLines(trinket, nil, {
        "Use: Increases damage and healing done by magical spells and effects by up to 175 for 15 sec.",
    })
    check(s["MAGE.ARCANE"] and s["SHAMAN.RESTO"], "Talisman of Ephemeral Power: casters and healers")
    check(not s["ROGUE.COMBAT"] and not s["WARRIOR.FURY"], "Talisman of Ephemeral Power: not melee")
    -- Blackhand's Breadth.
    s = fromLines(trinket, { ITEM_MOD_STAMINA_SHORT = 8 }, {
        "Equip: Improves your chance to get a critical strike by 2%.",
    })
    check(s["ROGUE.COMBAT"] and s["HUNTER.MM"] and s["WARRIOR.ARMS"], "Blackhand's Breadth: melee and hunters")
    check(not s["MAGE.FROST"] and not s["PRIEST.HOLY"], "Blackhand's Breadth: not casters or healers")
    s = fromLines({ classID = 4, subclassID = 0, equipLoc = "INVTYPE_NECK" }, nil, {
        "Equip: Improves your chance to hit with spells by 1%.",
    })
    check(s["WARLOCK.DESTRO"] and not s["ROGUE.SUB"] and not s["PRIEST.HOLY"], "spell hit neck: dps casters only")
    s = fromLines(trinket, nil, { "Use: Restores 375 to 625 mana." })
    local n = 0
    for _ in pairs(s) do
        n = n + 1
    end
    check(n == #Sp.LIST, "a use line with no telling phrase leaves every spec")
end

-- S4: ranged and feral attack power have their own kinds.
do
    -- Striker's Mark.
    local s, k = fromLines({ classID = 2, subclassID = 2, equipLoc = "INVTYPE_RANGED" }, nil, {
        "Equip: +22 ranged Attack Power.",
        "Equip: Improves your chance to hit by 1%.",
    })
    check(k.RAP and k.AP, "Striker's Mark reads as ranged attack power and hit")
    check(s["HUNTER.MM"] and not s["ROGUE.COMBAT"] and not s["WARRIOR.ARMS"], "Striker's Mark: hunters only")
    s, k = fromLines({ classID = 2, subclassID = 10, equipLoc = "INVTYPE_2HWEAPON" }, nil, {
        "Equip: Increases attack power by 420 in Cat, Bear, and Dire Bear forms only.",
    })
    check(k.FAP and not k.AP, "feral attack power is not plain attack power")
    check(s["DRUID.CAT"] and s["DRUID.BEAR"], "feral staff: cat and bear")
    check(not s["HUNTER.SV"] and not s["DRUID.BALANCE"], "feral staff: not hunters or caster druids")
end

-- S5: dodge and parry are not defense.
do
    local s, k = fromLines({ classID = 4, subclassID = 2, equipLoc = "INVTYPE_CHEST" }, AGI, {
        "Equip: Increases your chance to dodge an attack by 1%.",
    })
    check(not k.DEF, "dodge does not read as defense")
    check(s["ROGUE.COMBAT"] and s["DRUID.CAT"] and s["DRUID.BEAR"], "agility dodge leather: rogues and ferals")
    k = Sp.ItemKinds({ ITEM_MOD_PARRY_RATING_SHORT = 1 }, { { leftText = "Equip: Increased Defense +7." } })
    check(k.DEF, "the defense line still reads as defense")
    k = Sp.ItemKinds({ ITEM_MOD_PARRY_RATING_SHORT = 1 }, nil)
    check(not k.DEF, "parry rating is not defense")
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
