-- RLC_Specs.lua
-- Which class specs an item suits, and which spec the player is.
--
-- Suitability is three plain rules per spec, not stat weights. Weights
-- score hunters and rogues almost the same on agility leather, so they
-- cannot stop a hunter rolling on a rogue item; armor type can.
--   1. Armor: the spec only takes the heaviest armor its class wears
--      (mail for hunters and shamans, plate for warriors and paladins, from
--      level 40 items; the next lighter type below that). Cloaks, rings,
--      necks, trinkets and off-hands have no armor rule. Shields and relics
--      go only to the classes and specs that use them.
--   2. Weapons: the spec must use that weapon type.
--   3. Stats: if the item has any of the stats that tell specs apart
--      (strength, agility, intellect, spirit, attack power, spell damage,
--      healing, defense), the spec must want at least one of them. An item
--      with none of those (stamina only, say) passes this rule.
-- The item's own "Classes:" line, if any, limits it further. Officers see
-- the result as the item's spec list and can change it.
--
-- The player's spec comes from their talents: the tab with the most points.
-- They can pick it by hand instead (Feral cat or bear look the same in
-- talents). The host locks it once the raid starts.
--
-- The data and SuitedSpecs at the top are pure Lua (tests/test_specs.lua);
-- talent detection and the item reader are the client glue at the bottom.
local _, NS = ...
local Rules = NS.Rules

local Specs = {}
NS.Specs = Specs

-- Item weapon subclasses (Enum.ItemWeaponSubclass).
local AXE1, AXE2, BOW, GUN, MACE1, MACE2, POLE, SWORD1, SWORD2 = 0, 1, 2, 3, 4, 5, 6, 7, 8
local STAFF, FIST, DAGGER, THROWN, XBOW, WAND = 10, 13, 15, 16, 18, 19

local function set(...)
    local t = {}
    for i = 1, select("#", ...) do
        t[select(i, ...)] = true
    end
    return t
end

local RANGED = { BOW, GUN, XBOW, THROWN }
local function with(list, ...)
    local t = set(...)
    for _, v in ipairs(list) do
        t[v] = true
    end
    return t
end

-- Armor subclass each class prefers: { from level 40 items, below that }.
-- 1 cloth, 2 leather, 3 mail, 4 plate.
local ARMOR = {
    WARRIOR = { 4, 3 },
    PALADIN = { 4, 3 },
    HUNTER = { 3, 2 },
    SHAMAN = { 3, 2 },
    ROGUE = { 2, 2 },
    DRUID = { 2, 2 },
    PRIEST = { 1, 1 },
    MAGE = { 1, 1 },
    WARLOCK = { 1, 1 },
}

-- Relic subclasses (librams, idols, totems; 11 is the generic relic).
local RELIC = { [7] = "PALADIN", [8] = "DRUID", [9] = "SHAMAN" }

local MELEE = set("STR", "AGI", "AP")
local CASTER = set("INT", "SP")
local HEALER = set("INT", "SPI", "HEAL")
local HUNTER_STATS = set("AGI", "AP", "INT")
local HUNTER_WEAPONS = with(RANGED, AXE1, AXE2, SWORD1, SWORD2, POLE, STAFF) -- never daggers or fist weapons
local ROGUE_WEAPONS = with(RANGED, DAGGER, SWORD1, MACE1, FIST)
local CLOTH_WEAPONS = set(SWORD1, STAFF, DAGGER, WAND)
local PRIEST_WEAPONS = set(MACE1, STAFF, DAGGER, WAND)

-- Talent tabs in the order the game shows them; `tree` is the tab index.
Specs.LIST = {
    { key = "WARRIOR.ARMS", name = "Arms", tree = 1, wants = MELEE, weapons = with(RANGED, AXE2, MACE2, SWORD2, POLE) },
    {
        key = "WARRIOR.FURY",
        name = "Fury",
        tree = 2,
        wants = MELEE,
        weapons = with(RANGED, AXE1, MACE1, SWORD1, FIST, AXE2, MACE2, SWORD2, POLE),
    },
    {
        key = "WARRIOR.PROT",
        name = "Protection",
        tree = 3,
        wants = set("DEF", "STR", "AGI"),
        weapons = with(RANGED, AXE1, MACE1, SWORD1, FIST),
        shield = true,
    },
    { key = "PALADIN.HOLY", name = "Holy", tree = 1, wants = HEALER, weapons = set(MACE1, SWORD1), shield = true },
    {
        key = "PALADIN.PROT",
        name = "Protection",
        tree = 2,
        wants = set("DEF", "STR", "SP"),
        weapons = set(AXE1, MACE1, SWORD1),
        shield = true,
    },
    { key = "PALADIN.RET", name = "Retribution", tree = 3, wants = MELEE, weapons = set(AXE2, MACE2, SWORD2, POLE) },
    { key = "HUNTER.BM", name = "Beast Mastery", tree = 1, wants = HUNTER_STATS, weapons = HUNTER_WEAPONS },
    { key = "HUNTER.MM", name = "Marksmanship", tree = 2, wants = HUNTER_STATS, weapons = HUNTER_WEAPONS },
    { key = "HUNTER.SV", name = "Survival", tree = 3, wants = HUNTER_STATS, weapons = HUNTER_WEAPONS },
    { key = "ROGUE.ASSA", name = "Assassination", tree = 1, wants = MELEE, weapons = ROGUE_WEAPONS },
    { key = "ROGUE.COMBAT", name = "Combat", tree = 2, wants = MELEE, weapons = ROGUE_WEAPONS },
    { key = "ROGUE.SUB", name = "Subtlety", tree = 3, wants = MELEE, weapons = ROGUE_WEAPONS },
    { key = "PRIEST.DISC", name = "Discipline", tree = 1, wants = HEALER, weapons = PRIEST_WEAPONS },
    { key = "PRIEST.HOLY", name = "Holy", tree = 2, wants = HEALER, weapons = PRIEST_WEAPONS },
    { key = "PRIEST.SHADOW", name = "Shadow", tree = 3, wants = set("INT", "SPI", "SP"), weapons = PRIEST_WEAPONS },
    {
        key = "SHAMAN.ELE",
        name = "Elemental",
        tree = 1,
        wants = CASTER,
        weapons = set(MACE1, AXE1, STAFF, DAGGER),
        shield = true,
    },
    {
        key = "SHAMAN.ENH",
        name = "Enhancement",
        tree = 2,
        wants = MELEE,
        weapons = set(AXE1, AXE2, MACE1, MACE2, FIST),
    },
    {
        key = "SHAMAN.RESTO",
        name = "Restoration",
        tree = 3,
        wants = HEALER,
        weapons = set(MACE1, AXE1, STAFF, DAGGER),
        shield = true,
    },
    { key = "MAGE.ARCANE", name = "Arcane", tree = 1, wants = CASTER, weapons = CLOTH_WEAPONS },
    { key = "MAGE.FIRE", name = "Fire", tree = 2, wants = CASTER, weapons = CLOTH_WEAPONS },
    { key = "MAGE.FROST", name = "Frost", tree = 3, wants = CASTER, weapons = CLOTH_WEAPONS },
    { key = "WARLOCK.AFFLI", name = "Affliction", tree = 1, wants = CASTER, weapons = CLOTH_WEAPONS },
    { key = "WARLOCK.DEMO", name = "Demonology", tree = 2, wants = CASTER, weapons = CLOTH_WEAPONS },
    { key = "WARLOCK.DESTRO", name = "Destruction", tree = 3, wants = CASTER, weapons = CLOTH_WEAPONS },
    -- The Feral tab is both cat and bear; detection picks cat (listed
    -- first), and a bear switches by hand.
    {
        key = "DRUID.BALANCE",
        name = "Balance",
        tree = 1,
        wants = set("INT", "SPI", "SP"),
        weapons = set(MACE1, STAFF, DAGGER),
    },
    { key = "DRUID.CAT", name = "Feral (cat)", tree = 2, wants = MELEE, weapons = set(MACE2, STAFF) },
    {
        key = "DRUID.BEAR",
        name = "Feral (bear)",
        tree = 2,
        wants = set("DEF", "AGI", "STR", "AP"),
        weapons = set(MACE2, STAFF),
    },
    { key = "DRUID.RESTO", name = "Restoration", tree = 3, wants = HEALER, weapons = set(MACE1, STAFF, DAGGER) },
}

Specs.BY_KEY = {}
for _, spec in ipairs(Specs.LIST) do
    spec.class = spec.key:match("^(%u+)%.")
    Specs.BY_KEY[spec.key] = spec
end

-- Stat kinds that tell specs apart. Stamina, hit, crit and the like don't.
Specs.TELLING = set("STR", "AGI", "INT", "SPI", "AP", "SP", "HEAL", "DEF")

-- Stat groups that mark what an item is for. Intellect and spirit are in
-- none: hunters use intellect, so it decides nothing on its own.
local GROUPS = { set("STR", "AGI", "AP"), set("SP", "HEAL"), set("DEF") }

local CLASS_ID = {}
for id, token in pairs(Rules.CLASS_TOKEN) do
    CLASS_ID[token] = id
end

-- item = { classID, subclassID, equipLoc, reqLevel, stats = {KIND = true},
--          classMask }. Returns the set of suited spec keys (possibly empty).
function Specs.SuitedSpecs(item)
    local out = {}
    local telling = {}
    for kind in pairs(item.stats or {}) do
        if Specs.TELLING[kind] then
            telling[kind] = true
        end
    end
    local hasTelling = next(telling) ~= nil
    for _, spec in ipairs(Specs.LIST) do
        local ok = Rules.HasClass(item.classMask or 0, CLASS_ID[spec.class])
        if ok and item.classID == 4 then -- armor
            local sub = item.subclassID
            if sub >= 1 and sub <= 4 and item.equipLoc ~= "INVTYPE_CLOAK" then
                local pref = ARMOR[spec.class]
                ok = sub == ((item.reqLevel or 60) >= 40 and pref[1] or pref[2])
            elseif sub == 6 then
                ok = spec.shield == true
            elseif RELIC[sub] then
                ok = RELIC[sub] == spec.class
            elseif sub == 11 then
                ok = spec.class == "PALADIN" or spec.class == "DRUID" or spec.class == "SHAMAN"
            end
        elseif ok and item.classID == 2 then -- weapon
            ok = spec.weapons[item.subclassID] == true
        end
        if ok and hasTelling then
            -- Wants at least one of the item's telling stats...
            ok = false
            for kind in pairs(telling) do
                if spec.wants[kind] then
                    ok = true
                    break
                end
            end
            -- ...and something from every stat group the item carries, so
            -- intellect alone cannot pull a hunter onto a spell staff.
            for _, group in ipairs(GROUPS) do
                if ok then
                    local present, wanted = false, false
                    for kind in pairs(group) do
                        present = present or telling[kind] == true
                        wanted = wanted or spec.wants[kind] == true
                    end
                    ok = not present or wanted
                end
            end
        end
        if ok then
            out[spec.key] = true
        end
    end
    return out
end

-- Readable list for the UI, e.g. "Rogue, Druid (Feral (cat))". A class with
-- all its specs suited shows as just the class. `label(token)` names a class.
function Specs.Describe(specs, label)
    if not specs then
        return "any spec"
    end
    local byClass, order = {}, {}
    for _, spec in ipairs(Specs.LIST) do
        local c = spec.class
        if not byClass[c] then
            byClass[c] = { all = 0, on = {} }
            order[#order + 1] = c
        end
        byClass[c].all = byClass[c].all + 1
        if specs[spec.key] then
            table.insert(byClass[c].on, spec.name)
        end
    end
    local parts = {}
    for _, c in ipairs(order) do
        local b = byClass[c]
        local name = label and label(c) or c
        if #b.on == b.all then
            parts[#parts + 1] = name
        elseif #b.on > 0 then
            parts[#parts + 1] = name .. " (" .. table.concat(b.on, ", ") .. ")"
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "nobody"
end

-- ---- glue ------------------------------------------------------------------

if not NS.On then
    return -- loaded by the test suite without the client
end

-- Stat kinds from the client's stat table keys and the item's "Equip:"
-- lines. The tooltip phrases are English; other clients still get the
-- primary stats from GetItemStats.
local STAT_KEYS = {
    ITEM_MOD_STRENGTH_SHORT = "STR",
    ITEM_MOD_AGILITY_SHORT = "AGI",
    ITEM_MOD_INTELLECT_SHORT = "INT",
    ITEM_MOD_SPIRIT_SHORT = "SPI",
    ITEM_MOD_ATTACK_POWER_SHORT = "AP",
    ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "AP",
    ITEM_MOD_SPELL_POWER_SHORT = "SP",
    ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "SP",
    ITEM_MOD_SPELL_HEALING_DONE_SHORT = "HEAL",
    ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "DEF",
    ITEM_MOD_DODGE_RATING_SHORT = "DEF",
    ITEM_MOD_PARRY_RATING_SHORT = "DEF",
    ITEM_MOD_BLOCK_RATING_SHORT = "DEF",
}
local EQUIP_PHRASES = {
    { "damage and healing", "SP" },
    { "damage and healing", "HEAL" },
    { "healing done", "HEAL" },
    { "healing spells", "HEAL" },
    { "spell damage", "SP" },
    { "damage done by", "SP" }, -- "Increases damage done by Fire spells..."
    { "attack power", "AP" },
    { "defense", "DEF" },
    { "dodge", "DEF" },
    { "parry", "DEF" },
    { "block", "DEF" },
}

local function readStats(itemString)
    local kinds = {}
    local _, link = C_Item.GetItemInfo(itemString)
    for key in pairs(C_Item.GetItemStats(link or itemString) or {}) do
        if STAT_KEYS[key] then
            kinds[STAT_KEYS[key]] = true
        end
    end
    local data = C_TooltipInfo.GetHyperlink(itemString)
    for _, line in ipairs(data and data.lines or {}) do
        local text = type(line.leftText) == "string" and line.leftText:lower()
        if text and text:find("^equip:") then
            for _, p in ipairs(EQUIP_PHRASES) do
                if text:find(p[1], 1, true) then
                    kinds[p[2]] = true
                end
            end
        end
    end
    return kinds
end

-- The host's describe() for Rules.Intent ADD: class mask from the item's
-- "Classes:" line, and the suited specs as a list. Items that are not
-- gear get no spec limit; an officer can always change it.
function Specs.DescribeItem(itemString)
    local mask = NS.Loot.TooltipClassMask(itemString)
    local _, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(itemString)
    if classID ~= 2 and classID ~= 4 then
        return mask, ""
    end
    local reqLevel = select(5, C_Item.GetItemInfo(itemString))
    local suited = Specs.SuitedSpecs({
        classID = classID,
        subclassID = subclassID,
        equipLoc = equipLoc,
        reqLevel = reqLevel,
        stats = readStats(itemString),
        classMask = mask,
    })
    return mask, Rules.SpecsToCSV(suited)
end

-- ---- the player's own spec -------------------------------------------------

-- The talent tab with the most points, read the way the talent window reads
-- it: active spec group -> trait config -> tree -> one group per tab, with
-- the points spent in each. Returns the tab index, or nil when nothing is
-- spent or the data cannot be read.
local function topTalentTab()
    local SI = C_SpecializationInfo
    local configID = SI.GetCombatConfigIDForSpecGroup(SI.GetActiveSpecGroup())
    local config = configID and C_Traits.GetConfigInfo(configID)
    local treeID = config and config.treeIDs and config.treeIDs[1]
    local groups = treeID and C_Traits.GetGroupDisplayInfoByTreeID(treeID)
    if not groups or #groups == 0 then
        return nil
    end
    local ids = {}
    for i, g in ipairs(groups) do
        ids[i] = g.groupID
    end
    local spent = {}
    for _, info in ipairs(C_Traits.GetGroupCurrencyInfo(configID, ids) or {}) do
        local c = info.currencyInfos and info.currencyInfos[1]
        local n = c and c.spent
        if canaccessvalue and not canaccessvalue(n) then
            return nil
        end
        spent[info.traitNodeGroupID] = n
    end
    local best, most = nil, 0
    for i, g in ipairs(groups) do
        local n = spent[g.groupID] or 0
        if n > most then
            best, most = i, n
        end
    end
    return best
end

local function myClassToken()
    local _, token = UnitClass("player")
    return token
end

-- Spec key from talents, or nil. pcall: an unmeasured call chain must never
-- break the addon; failing just means the player picks by hand.
function Specs.Detect()
    local ok, tab = pcall(topTalentTab)
    local class = myClassToken()
    if not ok or not tab or not class then
        return nil
    end
    for _, spec in ipairs(Specs.LIST) do
        if spec.class == class and spec.tree == tab then
            return spec.key -- the first match: cat for the Feral tab
        end
    end
end

-- The player's spec and whether they picked it by hand.
function Specs.Mine()
    local chosen = NS.DB.mySpec[NS.Me()]
    local spec = chosen and Specs.BY_KEY[chosen]
    if spec and spec.class == myClassToken() then
        return chosen, true
    end
    return Specs.Detect(), false
end

-- nil goes back to detecting from talents.
function Specs.Choose(key)
    NS.DB.mySpec[NS.Me()] = key
    Specs.Report(true)
    NS.Refresh()
end

-- Tell the host our spec when the session's copy differs. Only while the
-- raid takes reserves, or as a first report from a late joiner: after the
-- start the host would refuse a change anyway (an officer can make it).
local lastReport, nudged = 0, nil
function Specs.Report(force)
    local S = NS.S()
    if not S or S.phase == "ended" then
        return
    end
    local mine, picked = Specs.Mine()
    -- Once per session: a spec only guessed from talents may be tonight's
    -- role (an off-tank in dps spec), not the one the player loots for.
    if mine and not picked and nudged ~= S.id and S.phase == "reserve" then
        nudged = S.id
        NS.Print(
            "Confirm your loot spec (the spec you want gear for) on the Raid tab. From your talents: %s.",
            Specs.BY_KEY[mine] and Specs.BY_KEY[mine].name or mine
        )
    end
    local onRecord = S.specs[NS.Me()]
    if not mine or onRecord == mine or (S.phase ~= "reserve" and onRecord) then
        return
    end
    if not force and GetTime() - lastReport < 15 then
        return
    end
    lastReport = GetTime()
    NS.Act("SPEC", mine)
end

NS.On("TRAIT_CONFIG_UPDATED", function()
    Specs.Report(true)
end)
NS.On("PLAYER_ENTERING_WORLD", function()
    C_Timer.After(5, Specs.Report)
end)
