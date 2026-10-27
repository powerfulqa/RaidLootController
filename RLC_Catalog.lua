-- RLC_Catalog.lua
-- The loot catalogue: every notable item the addon has seen drop, filed
-- under instance and boss, with how many kills it dropped in. Browsed on the
-- Catalogue tab and used to pick reserves.
--
-- Where drops come from:
--   * Your own loot windows inside a dungeon or raid. A loot window opened
--     within BOSS_WINDOW seconds of a boss kill in the same instance counts
--     for that boss; anything else is filed under Trash.
--   * ENCOUNTER_LOOT_RECEIVED, which names the encounter directly.
--   * Other raiders: whoever opens a corpse broadcasts each drop ("CD") to
--     the group, so raiders who never open the corpse still record it.
--
-- Counting: an item's `n` is the number of distinct kills it dropped in,
-- and a boss's `kills` is how many kills were seen. Each is keyed by a kill
-- id so the same kill seen twice (own window plus a broadcast) counts once.
-- Boss kills use "E<encounterID>:<10-minute bucket>", the same on every
-- client present; trash uses the corpse GUID.
--
-- Sharing with players who were not there: on login a client sends a digest
-- of its catalogue to its guild (and to its group when it joins one). A
-- peer that knows more about an instance waits a random moment, then sends
-- that instance; anyone else about to answer sees it and stays quiet.
-- Everyone listening merges what goes past. Merging keeps the larger count
-- and the later time, so it is safe to receive the same data many times.
--
-- Heard is not seen: besides the shown counts (kills, n, the larger of
-- seen and heard) each boss and item keeps the count we saw ourselves
-- (ok, on). Only those go into our digest and our answers, so a fake number
-- dies with whoever heard it. Saved data without ok/on is all our own.
-- Only wire data is held to the caps, so our own drops always fit; what we
-- serve is cut to the same caps, so a capped receiver can catch up.
--
-- The data functions at the top are pure Lua (tests/test_catalog.lua loads
-- them under stock lua5.1); the event glue is at the bottom.
local _, NS = ...
local Rules = NS.Rules

local Catalog = {}
NS.Catalog = Catalog

Catalog.MAX_INSTANCES = 300
Catalog.MAX_BOSSES = 80
Catalog.MAX_ITEMS = 150
Catalog.MAX_COUNT = 9999
Catalog.MAX_RECORDS = 20000 -- items across the whole catalogue
Catalog.KILL_MEMORY = 4 -- recent kill ids remembered per item and boss

-- ---- data (pure) -----------------------------------------------------------

local function cleanName(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("[%c%^|]", ""):sub(1, 60)
    return s ~= "" and s or nil
end

local int = Rules.Int

local function count(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

-- Item records in the whole catalogue, counted once and then kept up to
-- date as records are added. Catalog.Forget resets it after a deletion.
local totals = setmetatable({}, { __mode = "k" })
local function total(cat)
    if not totals[cat] then
        local n = 0
        for _, inst in pairs(cat) do
            for _, boss in pairs(inst.b) do
                n = n + count(boss.i)
            end
        end
        totals[cat] = n
    end
    return totals[cat]
end

-- itemID -> { { boss, rec }, ... }, built on first lookup, extended as records
-- are added and dropped on deletion. Entries are the live tables, so counts
-- that rise later show without a rebuild.
local index = setmetatable({}, { __mode = "k" })

local full = setmetatable({}, { __mode = "k" }) -- cat -> true: nothing heard-only to evict

function Catalog.Forget(cat)
    totals[cat], index[cat], full[cat] = nil, nil, nil
end

local function addHit(idx, id, boss, rec)
    idx[id] = idx[id] or {}
    table.insert(idx[id], { boss = boss, rec = rec })
end

-- Where an item drops: a list of { boss, rec }, or nil.
function Catalog.Find(cat, itemID)
    if not index[cat] then
        local idx = {}
        for _, inst in pairs(cat) do
            for _, boss in pairs(inst.b) do
                for id, rec in pairs(boss.i) do
                    addHit(idx, id, boss, rec)
                end
            end
        end
        index[cat] = idx
    end
    return index[cat][itemID]
end

-- An itemString whose id fits the wire's integer range.
local function validItem(s)
    return Rules.ValidItemString(s) and (Rules.ItemIDOf(s) or 0) <= Rules.MAX_ID
end

-- Kills and drop count we saw ourselves (old saved data: all of it).
local function ownKills(boss)
    return boss.ok or (boss.w and 0 or boss.kills)
end
local function ownN(rec)
    return rec.on or (rec.w and 0 or rec.n)
end

-- Whether an instance, boss or item record holds only heard data.
local function heardOnly(e)
    if e.b then
        for _, boss in pairs(e.b) do
            if not heardOnly(boss) then
                return false
            end
        end
        return true
    elseif e.i then
        if ownKills(e) > 0 then
            return false
        end
        for _, rec in pairs(e.i) do
            if ownN(rec) > 0 then
                return false
            end
        end
        return true
    end
    return ownN(e) == 0
end

-- Make room under a cap: drop one entry of t that holds only heard data,
-- so junk from the wire cannot fill a cap for good. False if none.
local function evict(cat, t)
    for k, e in pairs(t) do
        if heardOnly(e) then
            t[k] = nil
            if e.s and totals[cat] then
                -- One item record: count it off, so a flood at the cap does
                -- not recount the whole catalogue per message. The search
                -- index rebuilds on its next use.
                totals[cat], index[cat] = totals[cat] - 1, nil
            else
                Catalog.Forget(cat)
            end
            return true
        end
    end
    return false
end

-- evict, anywhere in the catalogue (the whole-catalogue cap). A failed
-- search is remembered until the catalogue changes, so a flood at the cap
-- costs one scan, not one per message.
local function evictAny(cat)
    if full[cat] then
        return false
    end
    for _, inst in pairs(cat) do
        for _, boss in pairs(inst.b) do
            if evict(cat, boss.i) then
                return true
            end
        end
    end
    full[cat] = true
    return false
end

-- A new item record, or nil when a cap says no (wire data only).
local function newRecord(cat, boss, itemString, wire)
    if
        wire
        and (
            (count(boss.i) >= Catalog.MAX_ITEMS and not evict(cat, boss.i))
            or (total(cat) >= Catalog.MAX_RECORDS and not evictAny(cat))
        )
    then
        return nil
    end
    totals[cat] = total(cat) + 1
    local rec, id = { s = itemString, n = 0, on = 0, t = 0 }, Rules.ItemIDOf(itemString)
    boss.i[id] = rec
    if index[cat] then
        addHit(index[cat], id, boss, rec)
    end
    return rec
end

-- Remember a kill id in a short list. Returns false if it was already
-- there. Several ids, not one: re-opening an older corpse after a newer one
-- must not count it again. A plain string is the old one-id form.
local function remember(holder, field, killId)
    local list = holder[field]
    if type(list) ~= "table" then
        list = { list }
        holder[field] = list
    end
    for _, id in ipairs(list) do
        if id == killId then
            return false
        end
    end
    table.insert(list, 1, killId)
    list[Catalog.KILL_MEMORY + 1] = nil
    return true
end

-- Names from bare CI ops: a CI alone never makes an instance (300 of them
-- would fill the cap), it only names one a later CB or CE makes.
local heardNames, heardNameCount = {}, 0

-- Find or create an instance, respecting the cap for wire data.
function Catalog.Instance(cat, instID, instName, wire)
    local inst = cat[instID]
    if not inst then
        if wire and count(cat) >= Catalog.MAX_INSTANCES and not evict(cat, cat) then
            return nil
        end
        inst = { name = instName or heardNames[instID] or ("Instance " .. instID), b = {} }
        cat[instID] = inst
    elseif instName and not wire then
        inst.name = instName -- what we saw ourselves beats a heard name
    end
    return inst
end

-- Find or create a boss. Returns nil when a cap stops a NEW entry from
-- the wire.
function Catalog.Boss(cat, instID, instName, bossKey, bossName, t, wire)
    local inst = Catalog.Instance(cat, instID, instName, wire)
    if not inst then
        return nil
    end
    local boss = inst.b[bossKey]
    if not boss then
        if wire and count(inst.b) >= Catalog.MAX_BOSSES and not evict(cat, inst.b) then
            return nil
        end
        boss = {
            name = bossName or (bossKey == 0 and "Trash" or ("Boss " .. bossKey)),
            kills = 0,
            ok = 0,
            f = t or 0,
            i = {},
        }
        inst.b[bossKey] = boss
    elseif bossName and (not wire or boss.name:find("^Boss %d")) then
        boss.name = bossName -- ours, or a real name for a placeholder
    end
    if t and t > 0 and (boss.f == 0 or t < boss.f) then
        boss.f = t
    end
    return boss
end

-- Drop everything we only heard: shown counts fall back to our own, and
-- items, bosses and instances with nothing of our own go. Undoes a
-- poisoned merge. Returns how many item records were dropped.
function Catalog.ForgetHeard(cat)
    local dropped = 0
    for instID, inst in pairs(cat) do
        for key, boss in pairs(inst.b) do
            boss.ok = ownKills(boss)
            boss.kills = boss.ok
            for id, rec in pairs(boss.i) do
                rec.on = ownN(rec)
                rec.n = rec.on
                if rec.n == 0 then
                    boss.i[id], dropped = nil, dropped + 1
                end
            end
            if boss.kills == 0 and next(boss.i) == nil then
                inst.b[key] = nil
            end
        end
        if next(inst.b) == nil then
            cat[instID] = nil
        end
    end
    Catalog.Forget(cat)
    return dropped
end

-- Drop instances with no bosses (left by older versions' bare CI ops).
function Catalog.Prune(cat)
    for instID, inst in pairs(cat) do
        if next(inst.b) == nil then
            cat[instID] = nil
        end
    end
    Catalog.Forget(cat)
end

-- One kill of a boss, counted once per kill id.
function Catalog.CountKill(cat, instID, instName, bossKey, bossName, killId, t)
    local boss = Catalog.Boss(cat, instID, instName, bossKey, bossName, t)
    if boss and remember(boss, "lk", killId) then
        boss.ok = math.min(Catalog.MAX_COUNT, ownKills(boss) + 1)
        boss.kills = math.min(Catalog.MAX_COUNT, boss.kills + 1)
        return true
    end
    return false
end

-- One drop, counted once per kill id. Returns true when it was new.
-- `wire`: heard from a raider (CD), so capped and not counted as ours.
function Catalog.Record(cat, instID, instName, bossKey, bossName, itemString, killId, t, wire)
    if not validItem(itemString) then
        return false
    end
    local boss = Catalog.Boss(cat, instID, instName, bossKey, bossName, t, wire)
    if not boss then
        return false
    end
    local rec = boss.i[Rules.ItemIDOf(itemString)] or newRecord(cat, boss, itemString, wire)
    if not rec or not remember(rec, "k", killId) then
        return false
    end
    local bo, ro = ownKills(boss), ownN(rec)
    rec.on = wire and ro or math.min(Catalog.MAX_COUNT, ro + 1)
    rec.n = math.min(Catalog.MAX_COUNT, rec.n + 1)
    rec.t = math.max(rec.t, t or 0)
    -- A drop is proof of at least that many kills.
    boss.ok = math.max(bo, rec.on)
    boss.kills = math.max(boss.kills, rec.n)
    return true
end

-- Kill ids only stop one kill counting twice, which matters for minutes.
-- Drop them from items last seen before `cutoff`: trash ids are corpse
-- GUIDs, and 20000 records of them would bloat saved data.
function Catalog.TrimKills(cat, cutoff)
    for _, inst in pairs(cat) do
        for _, boss in pairs(inst.b) do
            for _, rec in pairs(boss.i) do
                if rec.t < cutoff then
                    rec.k = nil
                end
            end
        end
    end
end

-- What we serve of an instance: our own counts only, cut to the caps a
-- receiver applies (most-seen items, lowest boss keys first).
-- { { key, boss, kills, recs }, ... }
function Catalog.Served(inst)
    local out = {}
    for key, boss in pairs(inst.b) do
        local recs = {}
        for _, rec in pairs(boss.i) do
            if ownN(rec) > 0 then
                recs[#recs + 1] = rec
            end
        end
        table.sort(recs, function(a, b)
            return ownN(a) > ownN(b) or ownN(a) == ownN(b) and a.s < b.s
        end)
        for i = #recs, Catalog.MAX_ITEMS + 1, -1 do
            recs[i] = nil
        end
        -- The kills sent must cover each count sent, or the receiver refuses it.
        local kills = math.max(ownKills(boss), recs[1] and ownN(recs[1]) or 0)
        if kills > 0 then
            out[#out + 1] = { key = key, boss = boss, kills = kills, recs = recs }
        end
    end
    table.sort(out, function(a, b)
        return a.key < b.key
    end)
    for i = #out, Catalog.MAX_BOSSES + 1, -1 do
        out[i] = nil
    end
    return out
end

-- Per instance: entries, sum of drop counts, sum of kills. `own`: only what
-- we would serve (Served), for at most MAX_INSTANCES instances.
function Catalog.Digest(cat, own)
    local out, ids = {}, {}
    for instID in pairs(cat) do
        ids[#ids + 1] = instID
    end
    table.sort(ids)
    local kept = 0
    for _, instID in ipairs(ids) do
        local e, n, k = 0, 0, 0
        if own then
            for _, b in ipairs(Catalog.Served(cat[instID])) do
                k = k + b.kills
                for _, rec in ipairs(b.recs) do
                    e, n = e + 1, n + ownN(rec)
                end
            end
        else
            for _, boss in pairs(cat[instID].b) do
                k = k + boss.kills
                for _, rec in pairs(boss.i) do
                    e, n = e + 1, n + rec.n
                end
            end
        end
        if not own or (k > 0 and kept < Catalog.MAX_INSTANCES) then
            kept = kept + 1
            out[instID] = { e = e, n = n, k = k }
        end
    end
    return out
end

-- Whether `mine` knows something `theirs` (nil = they have nothing) does not.
function Catalog.Covers(mine, theirs)
    if not mine then
        return false
    end
    if not theirs then
        return mine.e > 0 or mine.k > 0
    end
    return mine.e > theirs.e or mine.n > theirs.n or mine.k > theirs.k
end

-- Ops that carry one instance's data.
-- New entries (instances, bosses, items) one sender may add per session.
-- A full honest answer fits; a guildmate sending junk fills only this much,
-- not the whole catalogue, so real drops still find room.
Catalog.SENDER_NEW = 5000

-- Whether merging op would add an entry the catalogue does not have yet.
function Catalog.IsNew(cat, op)
    if op[1] == "CI" then
        return false -- a bare CI adds nothing
    end
    local inst = cat[tonumber(op[2])]
    if not inst then
        return true
    end
    local boss = inst.b[tonumber(op[op[1] == "CD" and 4 or 3])]
    if not boss then
        return true
    end
    local s = op[1] == "CD" and op[6] or op[4]
    return op[1] ~= "CB" and boss.i[Rules.ItemIDOf(type(s) == "string" and s or "") or 0] == nil
end

-- Only our own observations (Served): never re-serve what we only heard.
function Catalog.InstanceOps(cat, instID)
    local inst = cat[instID]
    local ops = { { "CI", instID, inst.name } }
    for _, b in ipairs(Catalog.Served(inst)) do
        ops[#ops + 1] = { "CB", instID, b.key, b.boss.name, b.kills, b.boss.f }
        for _, rec in ipairs(b.recs) do
            ops[#ops + 1] = { "CE", instID, b.key, rec.s, ownN(rec), rec.t }
        end
    end
    return ops
end

-- Note one heard answer op against our own instance: heard[boss or rec] =
-- the highest kills or count anyone sent for it, up to our own. A claim
-- above our own count is one we cannot check, so it never silences us:
-- a guildmate sending 9999 would otherwise stop every honest answer.
-- An honest peer who knows more costs one extra answer, nothing else.
-- Only a sender's first claim per entry counts: sweeping 1, 2, 3... to hit
-- our count would otherwise keep us quiet.
function Catalog.NoteHeard(inst, heard, op, sender)
    local key = inst and inst.b[int(op[3], 0, 1e9) or false]
    local own = key and ownKills(key)
    if key and op[1] == "CE" then
        key = validItem(op[4]) and key.i[Rules.ItemIDOf(op[4])]
        own = key and ownN(key)
    elseif op[1] ~= "CB" then
        key = nil
    end
    local v = int(op[5], 0, Catalog.MAX_COUNT)
    if key and sender then
        heard.by = heard.by or {}
        local claimed = heard.by[sender] or {}
        heard.by[sender] = claimed
        if claimed[key] then
            return
        end
        claimed[key] = true
    end
    if key and v and v <= own then
        heard[key] = math.max(heard[key] or 0, v)
    end
end

-- Whether the heard answers carry everything we would send for inst.
function Catalog.Covered(inst, heard)
    for _, b in ipairs(Catalog.Served(inst)) do
        if (heard[b.boss] or 0) < b.kills then
            return false
        end
        for _, rec in ipairs(b.recs) do
            if (heard[rec] or 0) < ownN(rec) then
                return false
            end
        end
    end
    return true
end

-- A raider may send one new boss kill id per boss per KILL_GAP seconds,
-- and TRASH_IDS new trash kill ids (corpse GUIDs) per TRASH_GAP, so fresh
-- ids cannot pump our counts. seen: sender -> bossKey -> { at, ids, n },
-- at most KILL_KEYS boss keys per raider, so junk keys cannot grow it.
Catalog.KILL_GAP = 600
Catalog.TRASH_IDS, Catalog.TRASH_GAP = 10, 60
Catalog.KILL_KEYS = 20
Catalog.KILL_ITEMS = 12 -- different items one kill id may report
function Catalog.KillAllowed(seen, sender, op, now)
    local bossKey = int(op[4], 0, 1e9)
    if not bossKey then
        return false
    end
    local mine, killId = seen[sender] or {}, tostring(op[7])
    seen[sender] = mine
    local max, gap = 1, Catalog.KILL_GAP
    if bossKey == 0 then
        max, gap = Catalog.TRASH_IDS, Catalog.TRASH_GAP
    end
    local s = mine[bossKey]
    if not s and count(mine) >= Catalog.KILL_KEYS then
        for k, old in pairs(mine) do
            if now - old.at >= Catalog.KILL_GAP then
                mine[k] = nil
            end
        end
        if count(mine) >= Catalog.KILL_KEYS then
            return false
        end
    end
    if not s or now - s.at >= gap then
        s = { at = now, ids = {}, n = 0 }
        mine[bossKey] = s
    end
    local items = s.ids[killId]
    if not items then
        if s.n >= max then
            return false
        end
        items, s.n = { n = 0 }, s.n + 1
        s.ids[killId] = items
    end
    -- A kill drops a handful of items: one kill id cannot carry hundreds.
    local item = tostring(op[6])
    if not items[item] then
        if items.n >= Catalog.KILL_ITEMS then
            return false
        end
        items[item], items.n = true, items.n + 1
    end
    return true
end

-- Whether a CD's drop is in the catalogue under its kill id (it was valid
-- and is recorded), so our own broadcast of it can stay quiet.
function Catalog.HasDrop(cat, op)
    local inst = cat[int(op[2], 1, 1e9) or false]
    local boss = inst and inst.b[int(op[4], 0, 1e9) or false]
    local rec = boss and validItem(op[6]) and boss.i[Rules.ItemIDOf(op[6])]
    if rec and rec.k == op[7] then
        return true -- the old one-id form
    end
    for _, id in ipairs(rec and type(rec.k) == "table" and rec.k or {}) do
        if id == op[7] then
            return true
        end
    end
    return false
end

-- Merge one received data op. Untrusted: every field is checked, counts are
-- capped, times end at now + 1 hour, and a merge only ever raises the shown
-- counts, never our own (ok, on). Returns true if anything changed.
function Catalog.ApplyOp(cat, op, now)
    local kind = op[1]
    local instID = int(op[2], 1, 1e9)
    if not instID then
        return false
    end
    local function time(v)
        v = int(v, 0, 4e9)
        return v and math.min(v, now + 3600)
    end
    if kind == "CI" then
        local name = cleanName(op[3])
        if not name then
            return false
        end
        local inst = cat[instID]
        if not inst then
            -- Only remembered: the instance is made by a CB or CE for it.
            if heardNameCount >= Catalog.MAX_INSTANCES then
                heardNames, heardNameCount = {}, 0
            end
            heardNameCount = heardNameCount + (heardNames[instID] and 0 or 1)
            heardNames[instID] = name
            return false
        end
        -- A placeholder name (made by a CB/CE that arrived first) gives way.
        if inst.name ~= name and inst.name:find("^Instance %d") then
            inst.name = name
            return true
        end
        return false
    elseif kind == "CD" then
        -- A live drop broadcast by a raider who opened the corpse:
        -- CD instID instName bossKey bossName itemString killId time
        local bossKey, t = int(op[4], 0, 1e9), time(op[8])
        local killId = type(op[7]) == "string" and #op[7] <= 80 and op[7] or nil
        if not bossKey or not killId or not t then
            return false
        end
        return Catalog.Record(cat, instID, cleanName(op[3]), bossKey, cleanName(op[5]), op[6], killId, t, true)
    end
    local bossKey = int(op[3], 0, 1e9)
    if not bossKey then
        return false
    end
    if kind == "CB" then
        local kills = int(op[5], 0, Catalog.MAX_COUNT)
        if not kills then
            return false
        end
        local boss = Catalog.Boss(cat, instID, nil, bossKey, cleanName(op[4]), time(op[6]), true)
        if boss and kills > boss.kills then
            boss.ok, boss.kills = ownKills(boss), kills
            return true
        end
        return false
    elseif kind == "CE" then
        local s, n, t = op[4], int(op[5], 1, Catalog.MAX_COUNT), time(op[6])
        if not validItem(s) or not n or not t then
            return false
        end
        -- An item cannot drop in more kills than its boss has (CB comes first).
        local boss = cat[instID] and cat[instID].b[bossKey]
        if not boss or n > boss.kills then
            return false
        end
        local rec = boss.i[Rules.ItemIDOf(s)] or newRecord(cat, boss, s, true)
        if not rec then
            return false
        end
        local changed = n > rec.n or t > rec.t
        rec.on, rec.n, rec.t = ownN(rec), math.max(rec.n, n), math.max(rec.t, t)
        return changed
    end
    return false
end

-- ---- glue ------------------------------------------------------------------

if not NS.On then
    return -- loaded by the test suite without the client
end

local BOSS_WINDOW = 300 -- seconds after a kill that a loot window counts for the boss
local ASK_EVERY = 600 -- seconds between catalogue requests per destination

local function cat()
    return NS.DB.catalog
end

local function where()
    local name, instanceType, _, _, _, _, _, instID = GetInstanceInfo()
    if (instanceType == "raid" or instanceType == "party") and instID then
        return instID, name
    end
end

local lastKill -- { instID, encID, name, key, at }

-- Drops heard from other raiders, "instID bossKey itemString killId" ->
-- true, so only one looter broadcasts each drop. Wiped at each kill. The
-- instance and boss are in the key: a CD filed under another boss must not
-- silence the real looter's broadcast.
local heardDrop = {}
local function dropKey(op)
    return (int(op[2], 1, 1e9) or "?") .. " " .. (int(op[4], 0, 1e9) or "?") .. " " .. op[6] .. " " .. op[7]
end
-- Boss kill ids heard per raider and boss, for Catalog.KillAllowed.
local killSeen = {}

local function killKey(encID)
    return "E" .. encID .. ":" .. math.floor(GetServerTime() / 600)
end

NS.On("ENCOUNTER_END", function(encID, encName, _, _, success)
    if NS.Demo and NS.Demo.active then
        return -- NS.DB is the fake raid's: a real kill would be lost with it
    end
    -- Checked before any comparison: comparing a secret value throws.
    if not NS.CanRead(encID, encName, success) or success ~= 1 then
        return
    end
    local instID, instName = where()
    if not instID then
        return
    end
    lastKill = { instID = instID, encID = encID, name = encName, key = killKey(encID), at = GetTime() }
    wipe(heardDrop)
    for sender, mine in pairs(killSeen) do
        for key, seen in pairs(mine) do
            if GetTime() - seen.at >= Catalog.KILL_GAP then
                mine[key] = nil
            end
        end
        if next(mine) == nil then
            killSeen[sender] = nil
        end
    end
    Catalog.CountKill(cat(), instID, instName, encID, encName, lastKill.key, GetServerTime())
    NS.Refresh()
end)

-- Boss key, boss name and kill id that loot opened now belongs to.
local function attribution(instID, sourceGUID)
    if lastKill and lastKill.instID == instID and GetTime() - lastKill.at < BOSS_WINDOW then
        return lastKill.encID, lastKill.name, lastKill.key
    end
    return 0, "Trash", sourceGUID or ("T" .. GetServerTime())
end

NS.On("LOOT_OPENED", function()
    if NS.Demo and NS.Demo.active then
        return
    end
    local instID, instName = where()
    if not instID then
        return
    end
    local now = GetServerTime()
    local news = {}
    for _, e in ipairs(NS.Loot.LootSlots()) do
        local bossKey, bossName, killId = attribution(instID, e.source)
        if Catalog.Record(cat(), instID, instName, bossKey, bossName, e.itemString, killId, now) then
            news[#news + 1] = { "CD", instID, instName, bossKey, bossName, e.itemString, killId, now }
        end
    end
    -- Under group loot the whole raid opens the corpse. Each waits a random
    -- moment and stays quiet if someone else already sent the drop.
    if #news > 0 then
        C_Timer.After(math.random() * 3, function()
            for _, op in ipairs(news) do
                if not heardDrop[dropKey(op)] then
                    NS.Net.QueueCatalog(op, "GROUP")
                end
            end
        end)
    end
    NS.Refresh()
end)

NS.On("ENCOUNTER_LOOT_RECEIVED", function(encID, _, itemLink)
    if not NS.CanRead(encID, itemLink) then
        return
    end
    local instID, instName = where()
    local s = NS.ItemStringOf(itemLink)
    if not instID or not s then
        return
    end
    local quality = C_Item.GetItemQualityByID(s)
    if quality and quality < NS.DB.minQuality then
        return
    end
    -- Same kill id as the loot window path, so one kill never counts twice.
    local same = lastKill and lastKill.encID == encID
    local name, key = same and lastKill.name or nil, same and lastKill.key or killKey(encID)
    Catalog.Record(cat(), instID, instName, encID, name, s, key, GetServerTime())
    NS.Refresh()
end)

-- ---- sharing ---------------------------------------------------------------

local lastAsk = {}

-- Send our digest to "GUILD" or "GROUP"; peers who know more answer.
function Catalog.Ask(dest, force)
    local now = GetTime()
    if not force and lastAsk[dest] and now - lastAsk[dest] < ASK_EVERY then
        return
    end
    lastAsk[dest] = now
    -- Everything we hold, heard or seen, so nobody re-sends it.
    for instID, d in pairs(Catalog.Digest(cat())) do
        NS.Net.QueueCatalog({ "CQ", instID, d.e, d.n, d.k }, dest)
    end
    NS.Net.QueueCatalog({ "CQE", NS.VERSION }, dest) -- older clients ignore the version
end

local asking = {} -- dest .. sender -> { dest, digest, n } while their request arrives
local pending = {} -- dest .. instID -> heard answers (Catalog.NoteHeard) while we wait
local servedSender = {} -- dest .. sender -> GetTime() we last answered them
local servedDest = {} -- dest -> GetTime() we last answered anyone there
local SENDER_COOLDOWN = 600 -- one answer per asker per 10 minutes
local DEST_COOLDOWN = 60 -- and one per channel per minute: our answer reaches everyone there
local ANSWER_OPS = 300 -- ops in one answer; whole instances only

local addedBy = {} -- sender -> new entries they added this session

local function answer(who, req)
    local now = GetTime()
    if
        (servedSender[who] and now - servedSender[who] < SENDER_COOLDOWN)
        or (servedDest[req.dest] and now - servedDest[req.dest] < DEST_COOLDOWN)
    then
        return
    end
    -- Before the plan: an empty plan still costs a Digest, so it is rate-limited too.
    servedSender[who] = now
    -- Instances the asker listed first; the rest only fill what the cap leaves.
    local plan = {}
    for instID, d in pairs(Catalog.Digest(cat(), true)) do
        if Catalog.Covers(d, req.digest[instID]) then
            table.insert(plan, req.digest[instID] and 1 or #plan + 1, instID)
            pending[req.dest .. instID] = {}
        end
    end
    if #plan == 0 then
        return
    end
    servedDest[req.dest] = now
    C_Timer.After(2 + math.random() * 6, function()
        local busy = NS.Net.CatalogBacklog and NS.Net.CatalogBacklog(req.dest) > 0
        local sent = 0
        for _, instID in ipairs(plan) do
            local heard, inst = pending[req.dest .. instID], cat()[instID]
            pending[req.dest .. instID] = nil
            -- Quiet if our queue is still busy or someone already sent all we know.
            if not busy and inst and not Catalog.Covered(inst, heard or {}) then
                local ops = Catalog.InstanceOps(cat(), instID)
                if sent == 0 or sent + #ops <= ANSWER_OPS then
                    sent = sent + #ops
                    for _, op in ipairs(ops) do
                        NS.Net.QueueCatalog(op, req.dest)
                    end
                end
            end
        end
    end)
end

function Catalog.OnMessage(ops, dest, sender)
    if not NS.DB then
        return
    end
    local changed = false
    for _, op in ipairs(ops) do
        local kind = op[1]
        if kind == "CQ" then
            local instID = int(op[2], 1, 1e9)
            local e, n, k = int(op[3], 0, 1e7), int(op[4], 0, 1e9), int(op[5], 0, 1e9)
            local req = asking[dest .. sender] or { dest = dest, digest = {}, n = 0 }
            asking[dest .. sender] = req
            if instID and e and n and k and req.n < Catalog.MAX_INSTANCES and not req.digest[instID] then
                req.digest[instID] = { e = e, n = n, k = k }
                req.n = req.n + 1
            end
        elseif kind == "CQE" then
            NS.NoteVersion(sender, op[2])
            answer(dest .. sender, asking[dest .. sender] or { dest = dest, digest = {} })
            asking[dest .. sender] = nil
        else
            local instID = int(op[2], 1, 1e9)
            if instID and pending[dest .. instID] then
                Catalog.NoteHeard(cat()[instID], pending[dest .. instID], op, sender)
            end
            if kind == "CD" then
                -- A live drop only counts from someone in our group: from
                -- the guild channel it would be a kill nobody here saw. And
                -- only for the instance we are in: we were at that kill.
                if
                    dest ~= "GROUP"
                    or not NS.roster[sender]
                    or int(op[2], 1, 1e9) ~= where()
                    or not Catalog.KillAllowed(killSeen, sender, op, GetTime())
                then
                    op = nil
                end
            end
            local s = op and (op[1] == "CD" and op[6] or op[4])
            if op and op[1] ~= "CI" and op[1] ~= "CB" and not C_Item.GetItemInfoInstant(tostring(s)) then
                op = nil -- an item id the game does not know is junk
            end
            if op and Catalog.IsNew(cat(), op) then
                if (addedBy[sender] or 0) >= Catalog.SENDER_NEW then
                    op = nil
                else
                    addedBy[sender] = (addedBy[sender] or 0) + 1
                end
            end
            changed = op ~= nil and Catalog.ApplyOp(cat(), op, GetServerTime()) or changed
            -- Only a valid, recorded drop silences our own broadcast of it.
            if op and kind == "CD" and Catalog.HasDrop(cat(), op) then
                heardDrop[dropKey(op)] = true
            end
        end
    end
    if changed then
        NS.Refresh()
    end
end

NS.On("PLAYER_ENTERING_WORLD", function(isInitialLogin, isReload)
    if isInitialLogin or isReload then
        if NS.DB then
            Catalog.Prune(cat())
        end
        C_Timer.After(30, function()
            Catalog.Ask("GUILD")
            if IsInGroup() then
                Catalog.Ask("GROUP")
            end
        end)
    end
end)

local wasGrouped = false
NS.On("GROUP_ROSTER_UPDATE", function()
    local grouped = IsInGroup()
    if grouped and not wasGrouped then
        C_Timer.After(10, function()
            Catalog.Ask("GROUP")
        end)
    end
    wasGrouped = grouped
end)
