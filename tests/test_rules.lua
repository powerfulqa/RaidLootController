#!/usr/bin/env lua
-- Runtime suite for RLC_Rules.lua. Run from the repo root:
--   lua tests/test_rules.lua
-- Loads the real file under stock Lua (5.1 or later) with a bare namespace
-- table, so it exercises exactly the code the client runs.

local NS = {}
local chunk = assert(loadfile("RLC_Rules.lua"))
chunk("RaidLootController", NS)
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

-- Fixture raid: classIDs 1 warrior, 2 paladin, 8 mage.
local HOST, A, B, C = "Host-Realm", "Ann-Realm", "Bob-Realm", "Cat-Other"
local CLASS = { [HOST] = 1, [A] = 1, [B] = 2, [C] = 8 }
local ctx = {
    classOf = function(n)
        return CLASS[n]
    end,
    now = 1000,
}

-- Run an intent on the host copy and replay its ops on a client copy
-- through the wire codec, the way the addon does.
local host, client
local function act(who, req)
    local ops, note = R.Intent(host, who, req, ctx)
    if not ops then
        return nil, note
    end
    local enc = {}
    for _, op in ipairs(ops) do
        host = assert(R.Apply(host, op))
        enc[#enc + 1] = R.EncodeOp(op)
    end
    for _, msg in ipairs(R.Pack(enc, 250)) do
        for _, op in ipairs(R.Decode(msg)) do
            client = assert(R.Apply(client, op))
        end
    end
    return ops, note
end

local function fresh()
    local new = { "NEW", "Host-Realm-1", HOST, "Test^\tRaid", 1 }
    host = R.Apply(nil, new)
    client = R.Apply(nil, R.Decode(R.EncodeOp(new))[1])
end

-- ---- codec ---------------------------------------------------------------
do
    fresh()
    check(client.title == "TestRaid", "codec strips separators from the title")
    local op = R.Decode(R.EncodeOp({ "ITEM", "1", "interest", "normal", 0, "" }))[1]
    check(#op == 6 and op[6] == "", "codec keeps a trailing empty field")
    local msgs = R.Pack({ string.rep("a", 100), string.rep("b", 100), string.rep("c", 100) }, 250)
    check(#msgs == 2, "pack fits two ops per 250-byte message")
    local first = R.Pack({ string.rep("a", 100), string.rep("b", 100), string.rep("c", 100) }, 250, 1)
    check(#first == 1 and first[1] == msgs[1], "pack with maxMsgs returns just the first message")
    check(#R.Pack({ string.rep("x", 300) }, 250) == 0, "pack drops an oversize op")
end

-- ---- roll lines ----------------------------------------------------------
do
    local pat = R.FormatPattern("%s rolls %d (%d-%d)")
    local n, roll, lo, hi = R.ParseRoll("Ann rolls 57 (1-100)", pat)
    local sn = R.ParseRoll("Serv Aszune rolls 2 (1-100)", pat)
    check(sn == "Serv Aszune", "roll line keeps the surname (Forever)")
    check(n == "Ann" and roll == 57 and lo == 1 and hi == 100, "parses an English roll line")
    check(R.ParseRoll("Ann says hi", pat) == nil, "ignores other system lines")
    local de = R.FormatPattern("%1$s w\195\188rfelt. Ergebnis: %2$d (%3$d-%4$d)")
    n, roll = R.ParseRoll("Ann w\195\188rfelt. Ergebnis: 12 (1-100)", de)
    check(n == "Ann" and roll == 12, "parses a positional (deDE) roll line")
end

-- ---- validation at the trust boundary ------------------------------------
do
    fresh()
    check(R.Apply(host, { "LOCK", "NoRealm", 1 }) == nil, "rejects a name without realm")
    check(R.ValidName("Serv Aszune-ClassicBetaPvE"), "accepts a Forever name with a surname")
    check(not R.ValidName("A B C-Realm") and not R.ValidName(" Serv-Realm"), "rejects odd spacing")
    check(R.Apply(host, { "ADD", "1", "|cff|Hitem:1|h[x]|h|r" }) == nil, "rejects a raw link on the wire")
    check(R.Apply(host, { "ROLL", "1", A, 50 }) == nil, "rejects an op on an unknown item")
    check(R.Intent(host, A, { "ADD", "item:19019" }, ctx) == nil, "non-officer cannot add items")
    check(R.Intent(host, A, { "OFF", A, 1 }, ctx) == nil, "non-host cannot make officers")
end

-- ---- reserves ------------------------------------------------------------
do
    fresh()
    check(act(A, { "RES", 19019 }), "reserve accepted before start")
    act(B, { "RES", 19019 })
    act(HOST, { "PHASE", "live" })
    check(act(C, { "RES", 17076 }) == nil, "reserve refused after start")
    act(HOST, { "ADD", "item:19019::::::::60" })
    local _, note = act(HOST, { "START", "1" })
    local it = client.items["1"]
    check(
        it.mode == "reserve" and it.restrict[A] and it.restrict[B] and not it.restrict[C],
        "two reservers: only they may roll"
    )
    check(note:find("several"), "two reservers announced")
    check(it.wants[A] and it.wants[B], "reservers are marked as wanting it")
    act(HOST, { "CALL", "1" })
    check(act(HOST, { "ROLLSEEN", C, 99, 1, 100 }) == nil, "non-reserver roll ignored")
    act(HOST, { "ROLLSEEN", A, 40, 1, 100 })
    act(HOST, { "ROLLSEEN", B, 80, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].winner == B and client.items["1"].how == "reserve", "highest reserver wins")
    check(client.locks[B], "a reserve win locks the winner")

    act(HOST, { "ADD", "item:17076" })
    client.reserves[C], host.reserves[C] = 17076, 17076 -- as if reserved before start
    local _, one = act(HOST, { "START", "2" })
    check(one == "Reserved item.", "single reserver announced")
    act(HOST, { "CALL", "2" })
    local it2 = client.items["2"]
    check(it2.winner == C and it2.how == "reserve" and client.locks[C], "single reserver gets it on call, no roll")
end

-- ---- a win before the reserved item drops keeps the reserve --------------
do
    fresh()
    act(A, { "RES", 500 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 20, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.locks[A] and client.reserves[A] == 500, "a normal win locks but keeps the reserve")
    act(HOST, { "ADD", "item:500" })
    act(HOST, { "START", "2" })
    act(HOST, { "CALL", "2" })
    local it = client.items["2"]
    check(it.winner == A and it.how == "reserve", "the reserve still pays out after another win")
    check(client.reserves[A] == nil, "winning the reserved item uses the reserve")
    act(HOST, { "UNDO", "2" })
    check(client.reserves[A] == 500 and client.locks[A], "undo of a reserve win gives the reserve back")
end

-- ---- a free roll (open item) does not lock an off-spec winner -------------
do
    fresh()
    act(A, { "RES", 500 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "SPECS", "1", "MAGE.FIRE,MAGE.FROST" }) -- a mage item; A is a warrior
    act(HOST, { "START", "1" })
    act(HOST, { "CALL", "1" }) -- no mage wants it: opens to everyone
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 20, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].how == "open", "off-spec free roll recorded as open")
    check(not client.locks[A], "an off-spec free-roll win does not lock")
    check(client.reserves[A] == 500, "a free-roll win keeps the reserve")
    act(HOST, { "ADD", "item:2" })
    act(HOST, { "START", "2" })
    check(act(A, { "WANT", "2", 1 }), "after a free roll the player can still want a normal item")
end

-- ---- staying quiet on I want this does not buy a free first item ---------
do
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(HOST, { "CALL", "1" }) -- B could want it but stays quiet: it opens
    check(client.items["1"].mode == "open", "nobody asked: open to everyone")
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", B, 70, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].how == "roll" and client.locks[B], "a quiet eligible player's open win counts and locks")
end

-- ---- officer limits and the officer log ----------------------------------
do
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    check(act(HOST, { "OPEN", "1" }) == nil, "cannot open an item an unlocked player wants")
    check(act(HOST, { "AWARD", "1", "Gone-Realm" }) == nil, "cannot give an item to someone not in the group")
    check(act(HOST, { "AWARD", "1", B }), "can give an item by hand to a group member")
    local e = client.log[#client.log]
    check(e and e.by == HOST and e.what == "award" and e.name == B and e.key == "1", "manual award is logged")
    act(HOST, { "LOCK", B, 0 })
    check(client.log[#client.log].what == "unlock", "unlock is logged")
end

-- ---- reserves close at the first item; absent players never win -----------
do
    fresh()
    act(A, { "RES", 500 })
    act(HOST, { "ADD", "item:7" })
    act(HOST, { "START", "1" }) -- first item up, still in the reserve phase
    check(act(B, { "RES", 500 }) == nil, "reserves close once the first item is up")
    check(act(A, { "RES", 0 }) == nil, "a reserve cannot be dropped once items are up")
    act(HOST, { "CANCEL", "1" })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:500" })
    local saved = CLASS[A]
    CLASS[A] = nil -- A left the group
    act(HOST, { "START", "2" })
    check(client.items["2"].mode == "normal", "a reserver who left does not get reserve mode")
    act(HOST, { "CANCEL", "2" })
    CLASS[A] = saved
    act(HOST, { "ADD", "item:3" })
    act(HOST, { "START", "3" })
    act(A, { "WANT", "3", 1 })
    act(B, { "WANT", "3", 1 })
    act(HOST, { "CALL", "3" })
    act(HOST, { "ROLLSEEN", A, 99, 1, 100 })
    act(HOST, { "ROLLSEEN", B, 10, 1, 100 })
    CLASS[A] = nil -- A leaves mid-roll
    act(HOST, { "CLOSE", "3" })
    check(client.items["3"].winner == B, "a roller who left does not win")
    CLASS[A] = saved
    check(act(HOST, { "ROLLSEEN", B, -1, 1, 100 }) == nil, "a roll outside 1-100 is never recorded")
end

-- ---- players dry last raid roll first ------------------------------------
do
    fresh()
    ctx.dry = function()
        return { B }
    end
    act(HOST, { "PHASE", "live" })
    ctx.dry = nil
    check(client.dry[B], "dry list reaches clients at raid start")
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(B, { "WANT", "1", 1 })
    local _, note = act(HOST, { "CALL", "1" })
    check(note and note:find("no loot last raid"), "dry first pass announced")
    check(act(HOST, { "ROLLSEEN", A, 99, 1, 100 }) == nil, "a non-dry player waits for the dry first pass")
    act(HOST, { "ROLLSEEN", B, 5, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].winner == B and client.locks[B], "the dry player wins and is locked as normal")
end

-- ---- dry list from history; a loot slot is added once -------------------
do
    local history = {
        old = { started = 1, created = 1, specs = { [A] = "WARRIOR.ARMS" }, items = {} },
        last = {
            started = 2,
            created = 2,
            specs = { [A] = "WARRIOR.ARMS", [B] = "PALADIN.HOLY" },
            reserves = { [C] = 5 },
            items = {
                ["1"] = { state = "done", winner = A, how = "roll", wants = { [A] = true }, rolls = {} },
                ["2"] = { state = "done", winner = B, how = "open", wants = {}, rolls = { [B] = 3 } },
            },
        },
        now = { started = 3, created = 3, specs = {}, items = {} },
    }
    local dry = table.concat(R.DryFrom(history, "now"), ",")
    check(dry == table.concat({ B, C }, ","), "dry: seen last raid, no non-free win (got " .. dry .. ")")
    check(#R.DryFrom({}, nil) == 0, "no history: nobody is dry")

    fresh()
    act(HOST, { "PHASE", "live" })
    check(act(HOST, { "ADD", "item:1", "Creature-0-1-2-3-4-5:1" }), "a loot slot is added")
    check(act(HOST, { "ADD", "item:1", "Creature-0-1-2-3-4-5:1" }) == nil, "the same loot slot is not added twice")
    check(act(HOST, { "ADD", "item:1" }), "a hand-added copy still works")
end

-- ---- long lists split so every op fits one addon message -----------------
do
    fresh()
    local names = {}
    for i = 1, 9 do
        local n = "Reservername" .. string.char(64 + i) .. " Longsurnameabcd-Realmname"
        names[#names + 1] = n
        CLASS[n] = 1
        act(n, { "RES", 19019 })
    end
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:19019" })
    local ops = R.Intent(host, HOST, { "START", "1" }, ctx)
    local fits = true
    for _, op in ipairs(ops) do
        fits = fits and #R.EncodeOp(op) <= 250
    end
    check(fits and #ops > 10, "a long reserver list is split into ops that fit")
    act(HOST, { "START", "1" })
    local all = true
    for _, n in ipairs(names) do
        all = all and client.items["1"].restrict[n] == true
        CLASS[n] = nil
    end
    check(all, "every reserver reaches the client")
    check(not R.ValidName("A^B-Realm"), "a name with the op separator is refused")
end

-- ---- undo of a reserved item won by hand gives the reserve back ----------
do
    fresh()
    act(A, { "RES", 777 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:777" })
    act(HOST, { "AWARD", "1", A }) -- given by hand, not via reserve mode
    check(client.reserves[A] == nil, "winning the reserved item uses the reserve")
    act(HOST, { "UNDO", "1" })
    check(client.reserves[A] == 777, "undo gives the reserve back whatever way it was won")
    act(HOST, { "PHASE", "ended" })
    act(HOST, { "PHASE", "live" })
    check(client.ended == nil, "a reopened raid is not marked ended")
end

-- ---- worn gear rides along with a want -----------------------------------
do
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1, "item:900,item:901" })
    check(client.items["1"].worn[A] == "item:900,item:901", "worn gear reaches clients")
    act(B, { "WANT", "1", 1, "item:1|Hbad,item:2" })
    check(client.items["1"].wants[B] and not client.items["1"].worn[B], "bad worn value dropped, want kept")
    act(A, { "WANT", "1", 0 })
    check(not client.items["1"].worn[A], "taking a want back clears the worn gear")
    check(not R.ValidWorn("item:1,item:2,item:3"), "at most two worn items")
    check(not R.ValidWorn(string.rep("item:1", 30)), "worn value is length capped")
end

-- ---- lockout, open-to-all, unlock -----------------------------------------
do
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "ADD", "item:2" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    check(client.items["1"].state == "rolling", "call with a want starts rolling")
    check(act(HOST, { "ROLLSEEN", A, 30, 1, 50 }) == nil, "a /roll 50 does not count")
    act(HOST, { "ROLLSEEN", A, 30, 1, 100 })
    check(act(HOST, { "ROLLSEEN", A, 90, 1, 100 }) == nil, "second roll from the same player ignored")
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].winner == A and client.locks[A], "winner locked")

    act(HOST, { "START", "2" })
    check(act(A, { "WANT", "2", 1 }) == nil, "locked player cannot want a normal item")
    local _, note = act(HOST, { "CALL", "2" })
    local it = client.items["2"]
    check(it.state == "interest" and it.mode == "open", "no unlocked wants: item opens to all")
    check(note:find("open to everyone"), "opening is announced")
    check(act(A, { "WANT", "2", 1 }), "locked player can want an open item")
    act(HOST, { "CALL", "2" })
    act(HOST, { "ROLLSEEN", A, 10, 1, 100 })
    act(HOST, { "CLOSE", "2" })
    check(client.items["2"].how == "open", "open win recorded as open")

    act(HOST, { "LOCK", A, 0 })
    check(not client.locks[A], "officer unlock clears the lock")
    act(HOST, { "OFF", B, 1 })
    check(act(B, { "ADD", "item:3" }), "officer can add items")
end

-- ---- class restriction and ties --------------------------------------------
do
    fresh()
    -- The item's "Classes:" line, read by the host on ADD.
    ctx.describe = function()
        return R.ClassBit(8), ""
    end
    act(HOST, { "ADD", "item:5" })
    ctx.describe = nil
    act(HOST, { "START", "1" })
    check(client.items["1"].classMask == R.ClassBit(8), "class mask survives START")
    check(act(A, { "WANT", "1", 1 }) == nil, "wrong class cannot want")
    check(act(C, { "WANT", "1", 1 }), "right class can want")
    act(HOST, { "CALL", "1" })
    check(act(HOST, { "ROLLSEEN", B, 70, 1, 100 }) == nil, "wrong class roll ignored")
    act(HOST, { "OPEN", "1" })
    act(HOST, { "ROLLSEEN", C, 70, 1, 100 })
    check(act(HOST, { "ROLLSEEN", B, 70, 1, 100 }) == nil, "open keeps the class restriction")
    CLASS[A] = 8
    act(HOST, { "ROLLSEEN", A, 70, 1, 100 })
    local _, note = act(HOST, { "CLOSE", "1" })
    local it = client.items["1"]
    check(it.state == "rolling" and it.restrict[A] and it.restrict[C] and not it.rolls[A], "tie: tied players reroll")
    check(note:find("Tie"), "tie announced")
    act(HOST, { "ROLLSEEN", A, 5, 1, 100 })
    act(HOST, { "ROLLSEEN", C, 6, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].winner == C, "reroll decides the tie")
    CLASS[A] = 1
end

-- ---- a lower roll never wins a tie re-roll ---------------------------------
do
    fresh()
    act(HOST, { "ADD", "item:5" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 90, 1, 100 })
    act(HOST, { "ROLLSEEN", B, 90, 1, 100 })
    act(HOST, { "ROLLSEEN", C, 50, 1, 100 })
    act(HOST, { "CLOSE", "1" }) -- tie A/B
    check(act(HOST, { "CLOSE", "1" }) == nil, "closing straight after a tie awards nobody")
    act(HOST, { "ROLLSEEN", A, 20, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].winner == A, "tied player beats the earlier lower roll")
end

-- ---- specs: only suited specs roll, locked at raid start, undo a win ------
do
    fresh()
    local H, R2 = "Hunt-Realm", "Rog-Realm"
    CLASS[H], CLASS[R2] = 3, 4
    check(act(H, { "SPEC", "HUNTER.MM" }), "spec reported before start")
    act(R2, { "SPEC", "ROGUE.COMBAT" })
    act(HOST, { "PHASE", "live" })
    check(act(H, { "SPEC", "HUNTER.SV" }) == nil, "spec locked once the raid starts")
    check(act(HOST, { "SETSPEC", H, "HUNTER.SV" }), "officer can change a locked spec")
    check(client.specs[H] == "HUNTER.SV", "officer change reaches clients")
    -- A rogue leather item: the host's describe() says rogues and cats.
    ctx.describe = function()
        return 0, "DRUID.CAT,ROGUE.COMBAT,ROGUE.SUB"
    end
    act(HOST, { "ADD", "item:7000" })
    ctx.describe = nil
    check(client.items["1"].specs["ROGUE.COMBAT"], "suited specs travel with ADD")
    act(HOST, { "START", "1" })
    check(client.items["1"].specs and client.items["1"].specs["DRUID.CAT"], "specs survive START")
    check(act(H, { "WANT", "1", 1 }) == nil, "hunter cannot want a rogue item")
    check(act(R2, { "WANT", "1", 1 }), "rogue can")
    local NoAddon = "Plain-Realm"
    CLASS[NoAddon] = 4
    act(HOST, { "CALL", "1" })
    check(act(HOST, { "ROLLSEEN", H, 99, 1, 100 }) == nil, "hunter roll ignored")
    check(act(HOST, { "ROLLSEEN", NoAddon, 10, 1, 100 }), "rogue without the addon: class check only")
    act(HOST, { "ROLLSEEN", R2, 50, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].winner == R2, "suited spec wins")
    -- Given by mistake: take it back.
    local _, note = act(HOST, { "UNDO", "1" })
    local it = client.items["1"]
    check(it.state == "pending" and not it.winner and not client.locks[R2], "undo: item waits again, winner unlocked")
    check(note:find("taken back"), "undo announced")
    check(it.specs and it.specs["ROGUE.COMBAT"], "undo keeps the suited specs")
    -- Nobody suited wants it: it opens to everyone, hunter included.
    act(HOST, { "START", "1" })
    act(HOST, { "CALL", "1" })
    check(client.items["1"].mode == "open", "no suited wants: open to everyone")
    check(act(H, { "WANT", "1", 1 }), "hunter can want it once open")
    -- Officer clears the spec limit on another item.
    act(HOST, { "ADD", "item:7001" })
    act(HOST, { "SPECS", "2", "ROGUE.COMBAT" })
    check(client.items["2"].specs["ROGUE.COMBAT"] and not client.items["2"].specs["DRUID.CAT"], "officer sets specs")
    act(HOST, { "SPECS", "2", "" })
    check(client.items["2"].specs == nil, "officer clears specs")
    check(act(H, { "UNDO", "2" }) == nil, "only officers undo")
end

-- ---- one active item at a time ---------------------------------------------
do
    fresh()
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "ADD", "item:2" })
    act(HOST, { "START", "1" })
    check(act(HOST, { "START", "2" }) == nil, "cannot start a second item while one is open")
    act(HOST, { "CANCEL", "1" })
    check(client.active == nil, "cancel clears the active item")
    check(act(HOST, { "START", "2" }), "next item starts after cancel")
end

-- ---- snapshot replay rebuilds the same state ------------------------------
do
    local function same(a, b, path)
        if type(a) ~= type(b) then
            return false, path
        end
        if type(a) ~= "table" then
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

    fresh()
    act(A, { "RES", 9 })
    act(A, { "SPEC", "WARRIOR.ARMS" })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "OFF", B, 1 })
    for i = 1, 4 do
        act(HOST, { "ADD", "item:" .. i })
    end
    act(HOST, { "SPECS", "3", "WARRIOR.ARMS,ROGUE.COMBAT" })
    act(HOST, { "START", "4" }) -- active item sits BEFORE finished ones in replay order? No: after.
    act(C, { "WANT", "4", 1 })
    act(HOST, { "CALL", "4" })
    act(HOST, { "ROLLSEEN", C, 33, 1, 100 })
    act(HOST, { "CLOSE", "4" })
    act(HOST, { "DELIV", "4" }) -- the snapshot must carry delivered too
    act(HOST, { "START", "1" })
    act(B, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", B, 50, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    act(HOST, { "LOCK", B, 0 }) -- unlocked after winning
    act(HOST, { "START", "3" })
    act(HOST, { "CANCEL", "3" })
    -- Item 2 goes live last but sits before finished items 3 and 4 in
    -- replay order, so their AWARD/CANCEL would clear `active` without
    -- the re-assert at the end of Snapshot.
    act(HOST, { "START", "2" })
    act(A, { "WANT", "2", 1 })
    act(HOST, { "CALL", "2" })
    act(HOST, { "ROLLSEEN", A, 12, 1, 100 })

    local rebuilt
    local enc = {}
    for _, op in ipairs(R.Snapshot(host)) do
        enc[#enc + 1] = R.EncodeOp(op)
    end
    for _, msg in ipairs(R.Pack(enc, 250)) do
        for _, op in ipairs(R.Decode(msg)) do
            rebuilt = assert(R.Apply(rebuilt, op))
        end
    end
    local ok, where = same(host, rebuilt, "S")
    check(ok, "snapshot replay matches the host (differs at " .. tostring(where) .. ")")
    check(not rebuilt.locks[B], "snapshot keeps an unlock made after a win")
    check(rebuilt.active == "2", "snapshot keeps the active item")
    ok, where = same(host, client, "S")
    check(ok, "client copy matches the host after live ops (differs at " .. tostring(where) .. ")")
end

-- ---- hostile wire input --------------------------------------------------
do
    fresh()
    -- A spec key must be the sender's own class.
    check(act(C, { "SPEC", "WARRIOR.PROT" }) == nil, "mage cannot report a warrior spec")
    check(act(C, { "SPEC", "MAGE.FIRE" }), "mage can report a mage spec")
    check(act(HOST, { "SETSPEC", C, "WARRIOR.PROT" }) == nil, "officer cannot set a spec of another class")
    -- Numbers: no inf, NaN, fractions or out-of-range ids.
    check(act(A, { "RES", "1e999" }) == nil, "reserve id inf refused")
    check(act(A, { "RES", "1.5" }) == nil, "reserve id fraction refused")
    check(act(A, { "RES", 19019 }), "reserve id accepted")
    local S = R.Apply(nil, { "NEW", "Host-Realm-2", HOST, "Raid", 1 })
    check(R.Apply(S, { "ADD", "1e999", "item:19019" }) == nil, "ADD key inf refused")
    check(R.Apply(S, { "ADD", "07", "item:19019" }) == nil, "ADD key must be canonical")
    check(R.Apply(S, { "ADD", "77", "item:19019" }), "ADD key accepted")
    check(R.Apply(S, { "ROLL", "77", A, "0/0" }) == nil, "roll NaN refused")
    check(R.Apply(S, { "ROLL", "77", A, "50.5" }) == nil, "roll fraction refused")
    check(R.Apply(S, { "ITEM", "77", "done", "normal", "0", "", "" }) == nil, "ITEM done without winner refused")
    check(R.Apply(S, { "ITEM", "77", "rolling", "normal", "1e999", "", "" }) == nil, "class mask inf refused")
    -- A /roll from someone outside the group never counts, even on an open item.
    act(HOST, { "ADD", "item:19019" })
    local key = host.order[#host.order]
    act(HOST, { "START", key })
    act(HOST, { "OPEN", key })
    act(HOST, { "CALL", key })
    check(host.items[key].state == "rolling", "outsider fixture: item is rolling")
    check(act(HOST, { "ROLLSEEN", "Stranger-Realm", 99, 1, 100 }) == nil, "outsider roll refused")
    check(act(HOST, { "ROLLSEEN", A, 50, 1, 100 }), "group member roll counts")
    -- Names: no UI escapes or CSV commas.
    check(not R.ValidName("|Hx|h-Realm"), "name with | refused")
    check(not R.ValidName("A,B-Realm"), "name with , refused")
    check(R.ValidName("Serv Aszune-Realm"), "surname name still valid")
end

-- Versions, player stats and the history text.
do
    check(R.VersionNewer("v0.4.0", "v0.3.9"), "minor beats patch")
    check(R.VersionNewer("v1.0.0", "v0.9.9"), "major beats minor")
    check(R.VersionNewer("v0.3.10", "v0.3.9"), "versions compare as numbers, not text")
    check(not R.VersionNewer("v0.3.0", "v0.3.0"), "same version is not newer")
    check(not R.VersionNewer("dev", "v0.3.0"), "a dev copy is never newer")
    check(not R.VersionNewer("v9.9.9|r", "v0.3.0"), "junk version is never newer")
    check(R.ValidVersion("v0.3.0") and not R.ValidVersion(("1."):rep(20)), "version validation")

    local function raid(created, started, items, specs)
        local order = {}
        for k in pairs(items) do
            order[#order + 1] = k
        end
        table.sort(order)
        return { created = created, started = started, items = items, order = order, specs = specs or {}, title = "MC" }
    end
    local history = {
        r1 = raid(100, 101, {
            a = {
                itemString = "item:1",
                state = "done",
                winner = A,
                how = "roll",
                rolls = { [A] = 87, [B] = 12 },
                delivered = 150,
            },
            b = { itemString = "item:2", state = "done", winner = B, how = "open", rolls = { [B] = 50 } },
            c = { itemString = "item:3", state = "cancelled", winner = B },
        }, { [C] = "MAGE.FIRE" }),
        r2 = raid(200, 201, {
            a = { itemString = "item:4", state = "done", winner = A, how = "manual" },
        }),
        r3 = raid(300, nil, { a = { itemString = "item:5", state = "done", winner = C, how = "roll" } }),
    }
    local st = R.PlayerStats(history)
    check(st[A].raids == 2 and st[A].won == 2 and st[A].last == 200, "stats: wins and raids for a winner")
    check(st[B].won == 0 and st[B].free == 1, "stats: free roll counted apart")
    check(st[C].raids == 1 and st[C].won == 0, "stats: a raid that never started does not count")

    local text = R.HistoryText(history.r1, "9 Oct", function(s)
        return "Item " .. s:match("%d+")
    end, function(n)
        return (n:gsub("%-.*", ""))
    end)
    check(text:find("^MC %- 9 Oct\n"), "history text: title and date first")
    check(text:find("%[Item 1%] %- Ann %(roll 87, delivered%)"), "history text: roll winner with roll, delivered")
    check(
        text:find("%[Item 2%] %- Bob %(free roll 50%)\n") or text:find("%[Item 2%] %- Bob %(free roll 50%)$"),
        "history text: not delivered says nothing"
    )
    check(text:find("%[Item 2%] %- Bob %(free roll 50%)"), "history text: free roll")
    check(not text:find("Item 3"), "history text: removed items left out")
    check(R.HistoryText(raid(1, 1, {}), "x", tostring, tostring):find("No items given"), "history text: empty raid")
end

-- Delivered: a won item reached its winner.
do
    fresh()
    act(HOST, { "OFF", B, 1 })
    act(HOST, { "ADD", "item:19019" })
    local key = host.order[#host.order]
    check(act(HOST, { "DELIV", key }) == nil, "an item nobody won can't be delivered")
    act(HOST, { "AWARD", key, A })
    check(host.items[key].state == "done", "delivered fixture: item won")
    check(act(A, { "DELIV", key }) == nil, "a raider can't mark delivered")
    check(act(B, { "DELIV", key }), "an officer marks a won item delivered")
    check(host.items[key].delivered == ctx.now and client.items[key].delivered == ctx.now, "delivered reaches clients")
    check(act(HOST, { "DELIV", key }) == nil, "delivered only once")
    check(R.Apply(host, { "DELIV", key, "x" }) == nil, "DELIV with a bad time refused")
    act(HOST, { "UNDO", key })
    check(host.items[key].delivered == nil, "undo clears delivered")
    check(R.Apply(host, { "DELIV", key, 5 }) == nil, "a DELIV op for an item not won is refused")
end

-- Help search highlight.
do
    local Y = "<"
    check(R.Highlight("Roll for loot", "roll", Y) == "<Roll|r for loot", "highlight keeps the text's own case")
    check(R.Highlight("a roll, a reroll", "roll", Y) == "a <roll|r, a re<roll|r", "highlight marks every match")
    check(R.Highlight("|cffb6ffb6Keep|r it", "ff", Y) == "|cffb6ffb6Keep|r it", "never inside a colour code")
    check(R.Highlight("|cffb6ffb6Keep|r it", "keep", Y) == "|cffb6ffb6<Keep|r|r it", "inside coloured text still marks")
    check(R.Highlight("a|nb", "|n", Y) == "a|nb", "escape codes themselves never match")
    check(R.Highlight("text", "", Y) == "text", "empty search changes nothing")
end

print(string.format("test_rules: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
