#!/usr/bin/env lua
-- Runtime suite for the data half of RLC_Catalog.lua. Run from the repo root:
--   lua tests/test_catalog.lua
-- Loads the real Rules and Catalog files with a bare namespace (no NS.On),
-- so the client glue at the bottom of RLC_Catalog.lua is skipped.

local NS = {}
assert(loadfile("RLC_Rules.lua"))("RaidLootController", NS)
assert(loadfile("RLC_Catalog.lua"))("RaidLootController", NS)
local C, R = NS.Catalog, NS.Rules

local passed, failed = 0, 0
local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. label)
    end
end

local MC, LUC, RAG = 409, 663, 672

-- ---- recording and kill dedupe ---------------------------------------------
do
    local cat = {}
    C.CountKill(cat, MC, "Molten Core", LUC, "Lucifron", "E663:1", 100)
    check(not C.CountKill(cat, MC, "Molten Core", LUC, "Lucifron", "E663:1", 100), "same kill counted once")
    check(C.Record(cat, MC, "Molten Core", LUC, "Lucifron", "item:16800", "E663:1", 100), "first drop recorded")
    check(
        not C.Record(cat, MC, "Molten Core", LUC, "Lucifron", "item:16800", "E663:1", 100),
        "same kill's drop ignored"
    )
    C.CountKill(cat, MC, "Molten Core", LUC, "Lucifron", "E663:2", 200)
    C.Record(cat, MC, "Molten Core", LUC, "Lucifron", "item:16800", "E663:2", 200)
    local boss = cat[MC].b[LUC]
    check(boss.i[16800].n == 2 and boss.kills == 2 and boss.i[16800].t == 200, "two kills, dropped in both")
    check(not C.Record(cat, MC, "MC", LUC, "Lucifron", "|cff|Hitem:1|h|r", "x", 1), "rejects a raw link")
    C.Record(cat, MC, "Molten Core", 0, "Trash", "item:17010", "Creature-0-1", 300)
    check(cat[MC].b[0].name == "Trash" and cat[MC].b[0].i[17010].n == 1, "trash filed under boss 0")
end

-- ---- re-opening an older corpse does not count again ----------------------
do
    local cat = {}
    C.Record(cat, MC, "Molten Core", 0, "Trash", "item:17010", "Creature-A", 1)
    C.Record(cat, MC, "Molten Core", 0, "Trash", "item:17010", "Creature-B", 2)
    check(not C.Record(cat, MC, "Molten Core", 0, "Trash", "item:17010", "Creature-A", 3), "older corpse not recounted")
    check(cat[MC].b[0].i[17010].n == 2, "two corpses, two drops")
    -- Saved data from before the list form still dedupes.
    cat[MC].b[0].i[17010].k = "Creature-Z"
    check(
        not C.Record(cat, MC, "Molten Core", 0, "Trash", "item:17010", "Creature-Z", 4),
        "old one-id form still dedupes"
    )
end

-- ---- the whole catalogue is capped ----------------------------------------
do
    local saved = C.MAX_RECORDS
    C.MAX_RECORDS = 5
    local cat = {}
    for i = 1, 8 do
        C.ApplyOp(cat, { "CE", tostring(i), "1", "item:" .. i, "1", "1" })
    end
    local n = 0
    for _, inst in pairs(cat) do
        for _, boss in pairs(inst.b) do
            for _ in pairs(boss.i) do
                n = n + 1
            end
        end
    end
    check(n == 5, "item records capped across all instances")
    C.MAX_RECORDS = saved
end

-- ---- sync: digest, covers, instance ops round trip ------------------------
local function sameData(a, b)
    for instID, inst in pairs(a) do
        local o = b[instID]
        if not o or o.name ~= inst.name then
            return false, "instance " .. instID
        end
        for key, boss in pairs(inst.b) do
            local ob = o.b[key]
            if not ob or ob.name ~= boss.name or ob.kills ~= boss.kills or ob.f ~= boss.f then
                return false, "boss " .. key
            end
            for id, rec in pairs(boss.i) do
                local orec = ob.i[id]
                if not orec or orec.n ~= rec.n or orec.t ~= rec.t or orec.s ~= rec.s then
                    return false, "item " .. id
                end
            end
        end
    end
    return true
end

do
    local a = {}
    C.CountKill(a, MC, "Molten Core", LUC, "Lucifron", "k1", 100)
    C.Record(a, MC, "Molten Core", LUC, "Lucifron", "item:16800", "k1", 100)
    C.CountKill(a, MC, "Molten Core", RAG, "Ragnaros", "k2", 500)
    C.Record(a, MC, "Molten Core", RAG, "Ragnaros", "item:17076::::::::60", "k2", 500)

    local da = C.Digest(a)
    check(da[MC].e == 2 and da[MC].n == 2 and da[MC].k == 2, "digest counts entries, drops, kills")
    check(C.Covers(da[MC], nil), "a peer with nothing is covered")
    check(not C.Covers(da[MC], da[MC]), "an equal peer is not covered")

    -- Ship it over the real wire codec into an empty catalogue, in reverse
    -- order so CE/CB arrive before the CI header.
    local enc = {}
    for _, op in ipairs(C.InstanceOps(a, MC)) do
        table.insert(enc, 1, R.EncodeOp(op))
    end
    local b = {}
    for _, msg in ipairs(R.Pack(enc, 250)) do
        for _, op in ipairs(R.Decode(msg)) do
            C.ApplyOp(b, op)
        end
    end
    local ok, where = sameData(a, b)
    check(ok, "instance ops rebuild the catalogue (differs at " .. tostring(where) .. ")")
    check(sameData(b, a), "and add nothing extra")

    -- Merging again changes nothing; a smaller count never lowers ours.
    local changed = false
    for _, op in ipairs(C.InstanceOps(a, MC)) do
        changed = C.ApplyOp(b, op) or changed
    end
    check(not changed, "re-merging the same data is a no-op")
    C.ApplyOp(b, { "CE", tostring(MC), tostring(LUC), "item:16800", "1", "50" })
    check(b[MC].b[LUC].i[16800].n == 1 and b[MC].b[LUC].i[16800].t == 100, "merge keeps the larger count and time")
    C.ApplyOp(b, { "CE", tostring(MC), tostring(LUC), "item:16800", "7", "900" })
    check(b[MC].b[LUC].i[16800].n == 7 and b[MC].b[LUC].kills == 7, "a higher count raises item and kills")
end

-- ---- live drop broadcast ---------------------------------------------------
do
    local cat = {}
    local op = { "CD", tostring(MC), "Molten Core", tostring(LUC), "Lucifron", "item:16800", "E663:9", "100" }
    check(C.ApplyOp(cat, op), "CD records a drop")
    check(not C.ApplyOp(cat, op), "the same CD from a second raider counts once")
end

-- ---- untrusted input -------------------------------------------------------
do
    local cat = {}
    check(not C.ApplyOp(cat, { "CE", "x", "1", "item:1", "1", "1" }), "rejects a bad instance id")
    check(not C.ApplyOp(cat, { "CE", "1", "1", "item:1", "0", "1" }), "rejects a zero count")
    check(not C.ApplyOp(cat, { "CE", "1", "1", "item:1", "99999", "1" }), "rejects an absurd count")
    check(not C.ApplyOp(cat, { "CB", "1", "-1", "X", "1", "1" }), "rejects a negative boss key")
    C.ApplyOp(cat, { "CI", "5", "A\tB^C|D" })
    check(cat[5].name == "ABCD", "strips separators and escapes from names")
    for i = 1, C.MAX_ITEMS + 10 do
        C.ApplyOp(cat, { "CE", "5", "1", "item:" .. i, "1", "1" })
    end
    local n = 0
    for _ in pairs(cat[5].b[1].i) do
        n = n + 1
    end
    check(n == C.MAX_ITEMS, "items per boss are capped")
    C.ApplyOp(cat, { "CI", "77", "Instance 77" })
    C.ApplyOp(cat, { "CI", "77", "Blackwing Lair" })
    check(cat[77].name == "Blackwing Lair", "a real name replaces a placeholder")
end

-- ---- lookup by item ----------------------------------------------------------
do
    local cat = {}
    C.Record(cat, 409, "Molten Core", 663, "Lucifron", "item:16800", "k1", 100)
    check(C.Find(cat, 16800)[1].boss.name == "Lucifron", "finds the boss an item drops from")
    check(C.Find(cat, 16801) == nil, "unknown item: nil")
    -- A new drop after the first lookup must show up (the index is rebuilt).
    C.Record(cat, 409, "Molten Core", 664, "Magmadar", "item:16800", "k2", 200)
    check(#C.Find(cat, 16800) == 2, "a second boss for the same item shows after a new record")
    C.Record(cat, 409, "Molten Core", 664, "Magmadar", "item:16800", "k3", 300)
    local hits = C.Find(cat, 16800)
    check(hits[1].rec.n + hits[2].rec.n == 3, "counts stay live without a rebuild")
    cat[409].b[663] = nil
    C.Forget(cat)
    check(#C.Find(cat, 16800) == 1, "a forgotten boss drops out of the lookup")
end

-- ---- old kill ids are dropped -----------------------------------------------
do
    local cat = {}
    C.Record(cat, MC, "Molten Core", 0, "Trash", "item:17010", "Creature-0-1", 100)
    C.Record(cat, MC, "Molten Core", 0, "Trash", "item:17011", "Creature-0-2", 900)
    C.TrimKills(cat, 500)
    local items = cat[MC].b[0].i
    check(items[17010].k == nil and items[17011].k ~= nil, "kill ids go only from items last seen before the cutoff")
    check(items[17010].n == 1, "trimming keeps the count")
    check(
        C.Record(cat, MC, "Molten Core", 0, "Trash", "item:17010", "Creature-0-3", 1000),
        "a trimmed item records again"
    )
end

-- What counts as a new entry for the per-sender limit.
do
    local cat = {}
    C.Record(cat, MC, "Molten Core", LUC, "Lucifron", "item:16800", "E663:1", 100)
    check(not C.IsNew(cat, { "CI", tostring(MC), "Molten Core" }), "a known instance is not new")
    check(C.IsNew(cat, { "CI", "1", "Elsewhere" }), "an unknown instance is new")
    check(not C.IsNew(cat, { "CB", tostring(MC), tostring(LUC), "Lucifron", "1", "1" }), "a known boss is not new")
    check(C.IsNew(cat, { "CB", tostring(MC), "1", "Other", "1", "1" }), "an unknown boss is new")
    check(not C.IsNew(cat, { "CE", tostring(MC), tostring(LUC), "item:16800", "2", "1" }), "a known item is not new")
    check(C.IsNew(cat, { "CE", tostring(MC), tostring(LUC), "item:16801", "1", "1" }), "an unknown item is new")
    check(
        C.IsNew(cat, { "CD", tostring(MC), "MC", tostring(LUC), "L", "item:1", "k", "1" }),
        "a CD of a new item is new"
    )
    check(C.IsNew(cat, { "CE", tostring(MC), tostring(LUC), {}, "1", "1" }), "junk fields do not throw")
end

print(string.format("test_catalog: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
