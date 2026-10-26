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
local NOW = 100000
local function apply(cat, op)
    return C.ApplyOp(cat, op, NOW)
end

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
        apply(cat, { "CB", tostring(i), "1", "B", "1", "1" })
        apply(cat, { "CE", tostring(i), "1", "item:" .. i, "1", "1" })
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
    check(C.Record(cat, 9, "Own", 1, "B", "item:9", "k", 1), "our own drop bypasses the full cap")
    local savedInst = C.MAX_INSTANCES
    C.MAX_INSTANCES = 1
    check(C.CountKill(cat, 10, "Own2", 2, "B2", "k", 1), "and so does our own kill in a new instance")
    check(not apply(cat, { "CI", "11", "Wire" }), "while a wire instance is refused")
    C.MAX_INSTANCES = savedInst
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

    -- Ship it over the real wire codec into an empty catalogue.
    local enc = {}
    for _, op in ipairs(C.InstanceOps(a, MC)) do
        enc[#enc + 1] = R.EncodeOp(op)
    end
    local b = {}
    for _, msg in ipairs(R.Pack(enc, 250)) do
        for _, op in ipairs(R.Decode(msg)) do
            apply(b, op)
        end
    end
    local ok, where = sameData(a, b)
    check(ok, "instance ops rebuild the catalogue (differs at " .. tostring(where) .. ")")
    check(sameData(b, a), "and add nothing extra")

    -- Merging again changes nothing; a smaller count never lowers ours.
    local changed = false
    for _, op in ipairs(C.InstanceOps(a, MC)) do
        changed = apply(b, op) or changed
    end
    check(not changed, "re-merging the same data is a no-op")
    apply(b, { "CE", tostring(MC), tostring(LUC), "item:16800", "1", "50" })
    check(b[MC].b[LUC].i[16800].n == 1 and b[MC].b[LUC].i[16800].t == 100, "merge keeps the larger count and time")
    apply(b, { "CE", tostring(MC), tostring(LUC), "item:16800", "7", "900" })
    check(b[MC].b[LUC].i[16800].n == 1, "a count above the boss's kills is refused")
    apply(b, { "CB", tostring(MC), tostring(LUC), "Lucifron", "7", "1" })
    apply(b, { "CE", tostring(MC), tostring(LUC), "item:16800", "7", "900" })
    check(b[MC].b[LUC].i[16800].n == 7 and b[MC].b[LUC].kills == 7, "a higher count after its kills raises both")

    -- Heard is not seen: what the wire raised is never re-served.
    check(b[MC].b[LUC].ok == 0 and b[MC].b[LUC].i[16800].on == 0, "heard counts are not our own")
    check(C.Digest(b, true)[MC] == nil, "the own digest leaves out everything heard")
    check(C.Digest(b)[MC].k == 8, "the full digest (what we ask with) still counts it")
    check(#C.InstanceOps(b, MC) == 1, "an answer carries only the instance header")
    check(C.Digest(a, true)[MC].k == 2, "own observations are served")
end

-- ---- poisoned times and huge ids --------------------------------------------
do
    local cat = {}
    apply(cat, { "CB", "1", "2", "B", "3", tostring(4e9) })
    apply(cat, { "CE", "1", "2", "item:5", "1", tostring(4e9) })
    check(cat[1].b[2].i[5].t == NOW + 3600, "a future time is clamped to now plus an hour")
    check(not apply(cat, { "CE", "1", "2", "item:99999999999", "1", "1" }), "rejects an item id above MAX_ID")
    check(
        not apply(cat, { "CD", "1", "I", "2", "B", "item:99999999999", "k", "1" }),
        "a CD with an item id above MAX_ID too"
    )
    check(cat[1].b[2].i[5].on == 0, "wire-created records are not our own")
    -- Our own boss and item, then a guildmate claims 9999 for both.
    for k = 1, 3 do
        C.CountKill(cat, 2, "I", 3, "B", "k" .. k, 1)
    end
    C.Record(cat, 2, "I", 3, "B", "item:6", "k1", 1)
    apply(cat, { "CB", "2", "3", "B", "9999", "1" })
    apply(cat, { "CE", "2", "3", "item:6", "9999", "1" })
    apply(cat, { "CE", "2", "3", "item:7", "5", "1" })
    local d = C.Digest(cat, true)[2]
    check(d.k == 3 and d.e == 1 and d.n == 1, "wire claims leave our own counts and records served")
    local ops = C.InstanceOps(cat, 2)
    check(ops[2][5] == 3 and ops[3][5] == 1, "and our answer sends our own counts")
    C.CountKill(cat, 2, "I", 3, "B", "k4", 1)
    check(cat[2].b[3].ok == 4 and cat[2].b[3].kills == 9999, "own kills keep counting under a heard total")
    -- Saved data from before own counts: all of it is ours.
    local old = {
        [7] = {
            name = "Old",
            b = {
                [1] = {
                    name = "B",
                    kills = 3,
                    f = 1,
                    i = {
                        [8] = { s = "item:8", n = 2, t = 1 },
                    },
                },
            },
        },
    }
    check(C.Digest(old, true)[7].k == 3 and C.Digest(old, true)[7].n == 2, "old saved data counts as own")
    apply(old, { "CB", "7", "1", "B", "50", "1" })
    check(C.Digest(old, true)[7].k == 3, "a wire raise of old data keeps its own kills")
end

-- ---- we store past the caps but serve within them --------------------------
do
    local saved = { C.MAX_ITEMS, C.MAX_BOSSES, C.MAX_INSTANCES }
    C.MAX_ITEMS, C.MAX_BOSSES, C.MAX_INSTANCES = 3, 2, 1
    local a = {}
    for i = 1, 5 do
        for k = 1, i do
            C.Record(a, 1, "I", 0, "Trash", "item:" .. i, "c" .. i .. ":" .. k, 1)
        end
    end
    C.CountKill(a, 1, "I", 5, "B5", "k", 1)
    C.CountKill(a, 1, "I", 6, "B6", "k", 1)
    C.CountKill(a, 2, "J", 1, "B", "k", 1)
    check(#a[1].b[0].i == 5 and a[1].b[0].i[1], "own trash is stored past MAX_ITEMS")
    local served = C.Served(a[1])
    check(#served == 2 and served[1].key == 0 and served[2].key == 5, "bosses served up to MAX_BOSSES")
    check(
        #served[1].recs == 3 and served[1].recs[1].s == "item:5" and served[1].recs[3].s == "item:3",
        "most-seen items up to MAX_ITEMS"
    )
    local own = C.Digest(a, true)
    check(own[1] and not own[2], "instances served up to MAX_INSTANCES")
    local b = {}
    for _, op in ipairs(C.InstanceOps(a, 1)) do
        apply(b, op)
    end
    check(not C.Covers(own[1], C.Digest(b)[1]), "a capped receiver catches up and stops asking")
    C.MAX_ITEMS, C.MAX_BOSSES, C.MAX_INSTANCES = saved[1], saved[2], saved[3]
end

-- ---- answer election: only a full answer silences us ------------------------
do
    local cat = {}
    C.CountKill(cat, MC, "Molten Core", LUC, "Lucifron", "k1", 1)
    C.CountKill(cat, MC, "Molten Core", LUC, "Lucifron", "k2", 2)
    C.Record(cat, MC, "Molten Core", LUC, "Lucifron", "item:16800", "k1", 1)
    C.Record(cat, MC, "Molten Core", LUC, "Lucifron", "item:16800", "k2", 2)
    local inst, heard = cat[MC], {}
    check(not C.Covered(inst, heard), "nothing heard: answer")
    C.NoteHeard(inst, heard, { "CI", tostring(MC), "Molten Core" })
    check(not C.Covered(inst, heard), "a bare CI does not silence us")
    C.NoteHeard(inst, heard, { "CB", tostring(MC), tostring(LUC), "Lucifron", "1", "1" })
    C.NoteHeard(inst, heard, { "CE", tostring(MC), tostring(LUC), "item:16800", "1", "1" })
    local short = { [inst.b[LUC].i[16800]] = 2, [inst.b[LUC]] = 1 }
    check(not C.Covered(inst, short), "fewer kills than ours: still answer")
    C.NoteHeard(inst, heard, { "CB", tostring(MC), tostring(LUC), "Lucifron", "2", "1" })
    check(not C.Covered(inst, heard), "an item count below ours: still answer")
    C.NoteHeard(inst, heard, { "CE", tostring(MC), tostring(LUC), "item:16800", "2", "1" })
    check(C.Covered(inst, heard), "all we know was sent: stay quiet")
    C.NoteHeard(inst, heard, { "CE", tostring(MC), "1", "item:1", "9", "1" })
    C.NoteHeard(inst, heard, { "CE", tostring(MC), tostring(LUC), "item:2", "9", "1" })
    local n = 0
    for _ in pairs(heard) do
        n = n + 1
    end
    check(n == 2, "heard notes only bosses and items we hold")
end

-- ---- live drop kill ids per raider ------------------------------------------
do
    local seen = {}
    local function cd(boss, id)
        return { "CD", "1", "I", boss, "B", "item:1", id, "1" }
    end
    check(C.KillAllowed(seen, "A", cd("663", "E663:1"), 0), "first kill id allowed")
    check(C.KillAllowed(seen, "A", cd("663", "E663:1"), 5), "the same kill id again (more items)")
    check(not C.KillAllowed(seen, "A", cd("663", "E663:2"), 10), "a fresh kill id within 10 minutes is refused")
    check(not C.KillAllowed(seen, "A", cd("0663", "E663:3"), 10), "a respelled boss key is the same boss")
    check(not C.KillAllowed(seen, "A", cd("663.0", "E663:4"), 10), "and so is 663.0")
    check(C.KillAllowed(seen, "B", cd("663", "E663:2"), 10), "another raider is separate")
    check(C.KillAllowed(seen, "A", cd("663", "E663:3"), 10 + C.KILL_GAP), "allowed again after the gap")
    local ok = 0
    for i = 1, 500 do
        ok = ok + (C.KillAllowed(seen, "A", cd("0", "Creature-" .. i), 20) and 1 or 0)
    end
    check(ok == C.TRASH_IDS, "trash kill ids are throttled too")
    check(C.KillAllowed(seen, "A", cd("0", "Creature-x"), 20 + C.TRASH_GAP), "trash opens again after its gap")
end

-- ---- live drop broadcast ---------------------------------------------------
do
    local cat = {}
    local op = { "CD", tostring(MC), "Molten Core", tostring(LUC), "Lucifron", "item:16800", "E663:9", "100" }
    check(apply(cat, op), "CD records a drop")
    check(not apply(cat, op), "the same CD from a second raider counts once")
    check(cat[MC].b[LUC].i[16800].on == 0 and cat[MC].b[LUC].ok == 0, "a heard live drop is not our own")
    check(C.HasDrop(cat, op), "a recorded drop silences our broadcast")
    check(
        not C.HasDrop(cat, { "CD", tostring(MC), "M", tostring(LUC), "L", "item:16800", "E663:8", "1" }),
        "a kill id we do not hold does not"
    )
    check(
        not C.HasDrop(cat, { "CD", tostring(MC), "M", tostring(LUC), "L", "item:16801", "E663:9", "1" }),
        "nor an item we do not hold"
    )
end

-- ---- untrusted input -------------------------------------------------------
do
    local cat = {}
    check(not apply(cat, { "CE", "x", "1", "item:1", "1", "1" }), "rejects a bad instance id")
    check(not apply(cat, { "CE", "1", "1", "item:1", "0", "1" }), "rejects a zero count")
    check(not apply(cat, { "CE", "1", "1", "item:1", "99999", "1" }), "rejects an absurd count")
    check(not apply(cat, { "CB", "1", "-1", "X", "1", "1" }), "rejects a negative boss key")
    apply(cat, { "CI", "5", "A\tB^C|D" })
    check(cat[5].name == "ABCD", "strips separators and escapes from names")
    apply(cat, { "CB", "5", "1", "B", "1", "1" })
    for i = 1, C.MAX_ITEMS + 10 do
        apply(cat, { "CE", "5", "1", "item:" .. i, "1", "1" })
    end
    local n = 0
    for _ in pairs(cat[5].b[1].i) do
        n = n + 1
    end
    check(n == C.MAX_ITEMS, "items per boss are capped")
    apply(cat, { "CI", "77", "Instance 77" })
    apply(cat, { "CI", "77", "Blackwing Lair" })
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
    local idx = C.Find(cat, 16800)
    C.Record(cat, 409, "Molten Core", 665, "Gehennas", "item:16800", "k4", 400)
    check(C.Find(cat, 16800) == idx and #idx == 3, "a new record is appended, not rebuilt")
    cat[409].b[663] = nil
    C.Forget(cat)
    check(#C.Find(cat, 16800) == 2, "a forgotten boss drops out of the lookup")
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
