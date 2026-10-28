#!/usr/bin/env lua
-- Runtime suite for RLC_Rules.lua. Run from the repo root:
--   lua tests/test_rules.lua
-- Loads the real file under stock Lua (5.1 or later) with a bare namespace
-- table, so it exercises exactly the code the client runs.

local NS = {}
assert(loadfile("RLC_Kit.lua"))("RaidLootController", NS)
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

-- ---- a regular's win before the reserved item drops keeps the reserve ----
do
    fresh()
    host.dry, client.dry = { [A] = true }, { [A] = true } -- A is a regular
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
    check(note == "Regulars roll first.", "regulars first pass announced")
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
    local function ten(t) -- pad a legacy raid to MIN_ATTEND wanters
        for i = 1, R.MIN_ATTEND do
            t.items["p" .. i] = { wants = { ["P" .. i .. "-Realm"] = true }, rolls = {} }
        end
        return t
    end
    ten(history.last)
    local dry = table.concat(R.RegularsFrom(history, "now"), ",")
    local function has(n)
        return dry:find(n, 1, true) ~= nil
    end
    check(not has(C) and has(A) and has(B), "legacy raid: present = wanted or rolled, winners too")
    check(#R.RegularsFrom({}, nil) == 0, "no history: nobody is a regular")
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
    -- Worn gear is advice for a live roll: a finished item drops it, on
    -- every copy, so saved history and snapshots never carry it.
    act(A, { "WANT", "1", 1, "item:900" })
    act(HOST, { "AWARD", "1", A })
    check(host.items["1"].worn == nil and client.items["1"].worn == nil, "a won item drops the worn gear")
    act(HOST, { "ADD", "item:2" })
    act(HOST, { "START", "2" })
    act(B, { "WANT", "2", 1, "item:902" })
    act(HOST, { "CANCEL", "2" })
    check(client.items["2"].worn == nil, "a removed item drops the worn gear")
    check(client.items["2"].wants[B], "removing an item keeps who wanted it")
end

-- ---- comma lists -----------------------------------------------------------
do
    local set = R.CSVToSet("Ann-Realm,junk,Bob-Realm")
    check(set["Ann-Realm"] and set["Bob-Realm"] and not set.junk, "name list drops junk")
    local specs = R.CSVToSpecs("ROGUE.COMBAT,Ann-Realm")
    check(specs["ROGUE.COMBAT"] and not specs["Ann-Realm"], "spec list checks specs, not names")
    check(R.CSVToSet("junk") == nil and R.CSVToSpecs("") == nil, "nothing valid: nil")
    check(R.CLASS_ID.ROGUE == 4 and R.CLASS_ID.DRUID == 11, "class token -> classID")
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
    act(HOST, { "ADD", "item:19999" })
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

-- Who may start a session on our copy (Rules.AcceptNew).
do
    local LEAD, ASSIST = "Lead-Realm", "Asst-Realm"
    local nctx = {
        now = 100000,
        isLead = function(n)
            return n == LEAD
        end,
        isLeadOrAssist = function(n)
            return n == LEAD or n == ASSIST
        end,
        recent = {},
    }
    local function new(who, t)
        return { "NEW", who .. "-" .. t, who, "x", tostring(t) }
    end
    check(R.AcceptNew(nil, new(ASSIST, 100000), ASSIST, nctx), "an assistant may start a session")
    check(not R.AcceptNew(nil, new(B, 100000), B, nctx), "a plain raider may not")
    check(not R.AcceptNew(nil, new(ASSIST, 100000), LEAD, nctx), "only in your own name")
    check(not R.AcceptNew(nil, new(LEAD, 4000000000), LEAD, nctx), "a start time from the future is refused")
    nctx.now = 1000000
    check(R.AcceptNew(nil, new(LEAD, nctx.now - R.NEW_PAST + 60), LEAD, nctx), "a reserve session days old still syncs")
    check(not R.AcceptNew(nil, new(LEAD, nctx.now - R.NEW_PAST - 60), LEAD, nctx), "older than that is refused")
    nctx.now = 100000
    check(not R.AcceptNew(nil, new(LEAD, "1e9"), LEAD, nctx), "a non-integer time is refused")
    local running = R.Apply(nil, new(ASSIST, 99000))
    check(running.created == 99000, "NEW keeps its start time")
    check(not R.AcceptNew(running, new(B, 100000), B, nctx), "a raider cannot take over")
    check(R.AcceptNew(running, new(ASSIST, 99000), ASSIST, nctx), "the host may resend its session")
    running.phase = "ended"
    check(not R.AcceptNew(running, new(ASSIST, 99000), ASSIST, nctx), "an ended raid cannot be resent and wiped")
    local burst = { now = 100000, isLead = nctx.isLead, isLeadOrAssist = nctx.isLeadOrAssist, recent = {} }
    local ok = 0
    for i = 1, 10 do
        if R.AcceptNew(nil, new(LEAD, 100000 - i), LEAD, burst) then
            ok = ok + 1
        end
    end
    check(ok == R.NEW_BURST, "a flood of new sessions is cut off")
    burst.now = burst.now + R.NEW_WINDOW + 1
    check(R.AcceptNew(nil, new(LEAD, burst.now), LEAD, burst), "and allowed again later")
    check(R.Apply(nil, { "NEW", "X-R-9", "X-R", "", "1e999" }).created == 0, "NEW never stores an absurd time")
    nctx.known = function(id)
        return id == ASSIST .. "-99000"
    end
    check(not R.AcceptNew(nil, new(ASSIST, 99000), ASSIST, nctx), "an old raid's id cannot replace its history")
    running.phase = "live"
    check(R.AcceptNew(running, new(ASSIST, 99000), ASSIST, nctx), "the running raid's own resend still passes")
    nctx.known = nil
end

do -- item ids stay in range
    check(R.ValidItemString("item:19019"), "a real item id passes")
    check(not R.ValidItemString("item:99999999999999999999"), "a huge item id is refused")
    fresh()
    check(act(HOST, { "ADD", "item:99999999999999999999" }) == nil, "ADD refuses a huge item id")
end

do -- audit: the log shows phases, closes and deliveries (not to old copies)
    fresh()
    act(HOST, { "OFF", A, 1 })
    act(HOST, { "PHASE", "live" })
    check(client.log[#client.log].what == "live", "starting the raid is logged")
    act(HOST, { "ADD", "item:1" })
    act(A, { "START", "1" })
    act(B, { "WANT", "1", 1 })
    act(A, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", B, 50, 1, 100 })
    act(A, { "CLOSE", "1" })
    local e = client.log[#client.log]
    check(e.what == "close" and e.by == A and e.name == B, "an officer closing a roll is logged")
    act(A, { "DELIV", "1" })
    check(client.log[#client.log].what == "deliv", "marking a win delivered is logged")
    act(HOST, { "PHASE", "ended" })
    check(client.log[#client.log].what == "ended", "ending the raid is logged")
    -- v0.6.1 refuses these kinds as "bad LOG" and would resync for ever, so
    -- they travel as LOG2, an op it does not know (no resync).
    local kinds = {}
    for _, op in ipairs(R.Snapshot(host)) do
        if op[1] == "LOG" or op[1] == "LOG2" then
            kinds[op[4]] = op[1]
        end
    end
    check(kinds.close == "LOG2" and kinds.live == "LOG2" and kinds.officer == "LOG", "new log kinds go as LOG2")
    check(R.Apply(host, { "LOG", 1000, HOST, "close", "", "" }) == nil, "and only as LOG2")
    local _, why = R.Apply(host, { "LOG", 1000, HOST, "someday", "", "" })
    check(why == "unknown op", "an unknown log kind reads as a newer host, not a missed op")
    _, why = R.Apply(host, { "SOMEDAY", "Ann-R", 1 })
    check(why == "unknown op", "an unknown op kind reads as a newer host, not a missed op")
    _, why = R.Apply(host, { "WANT", "999", "Ann-R", 1 })
    check(why == "no item", "a known item op for a missing item still asks for a resync")
end

do -- name sets are capped
    fresh()
    for i = 1, R.MAX_NAMES do
        host = assert(R.Apply(host, { "SPEC", "P" .. i .. "-Realm", "WARRIOR.ARMS" }))
    end
    check(R.Apply(host, { "SPEC", "Extra-Realm", "WARRIOR.ARMS" }) == nil, "no new name past the cap")
    check(R.Apply(host, { "SPEC", "P1-Realm", "WARRIOR.FURY" }) ~= nil, "an existing name can still change")
end

do -- an item called the moment it goes up cannot jump to "open to everyone"
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    local upAt = ctx.now
    ctx.since = function()
        return upAt
    end
    check(act(HOST, { "CALL", "1" }) == nil, "no open before raiders could ask")
    ctx.now = ctx.now + R.INTEREST_MIN
    check(act(HOST, { "CALL", "1" }) and client.items["1"].mode == "open", "after a few seconds it opens")
    check(client.log[#client.log].what == "open", "and the opening is logged")
    act(HOST, { "CANCEL", "1" })
    act(HOST, { "ADD", "item:2" })
    upAt = ctx.now
    check(act(HOST, { "START", "2" }) and client.items["2"].state == "interest", "the next item goes up")
    check(act(HOST, { "OPEN", "2" }) == nil, "an officer's Open waits the same few seconds")
    ctx.since, ctx.now = nil, 1000
end

do -- specs lock once items are up
    local M1 = "Mag-Realm"
    CLASS[M1] = 8
    fresh()
    act(M1, { "SPEC", "MAGE.FROST" })
    act(HOST, { "ADD", "item:1" })
    check(act(M1, { "SPEC", "MAGE.FIRE" }) == nil, "no spec swap once drops are up, even before Start raid")
end

do -- an officer cannot open a reserved item while its reserver is here
    fresh()
    act(B, { "RES", 19019 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:19019" })
    act(HOST, { "START", "1" })
    check(client.items["1"].mode == "reserve", "reserve fixture: item is reserved")
    check(act(HOST, { "OPEN", "1" }) == nil, "no Open while the reserver is here")
    local upAt = ctx.now
    ctx.since = function()
        return upAt
    end
    local saved = CLASS[B]
    CLASS[B] = nil -- the reserver left
    check(act(HOST, { "OPEN", "1" }) == nil, "and none in the first seconds once they left")
    CLASS[B], ctx.since = saved, nil
end

-- ---- audit fixes (2026-10-26) ----------------------------------------------
do -- reserves close once a drop is on the list, unchanged reserves send nothing
    fresh()
    check(#act(A, { "RES", 19019 }) == 1 and #act(A, { "RES", 19019 }) == 0, "an unchanged reserve sends nothing")
    act(HOST, { "ADD", "item:18814" })
    check(act(B, { "RES", 18814 }) == nil, "no reserve after a drop is added")
end

do -- a reserve must suit the class and loot spec when the host knows the item
    fresh()
    ctx.describe = function(s)
        return s == "item:5" and R.ClassBit(8) or 0, s == "item:6" and "WARRIOR.PROTECTION" or ""
    end
    check(act(A, { "RES", 5 }) == nil, "warrior cannot reserve mage-only gear")
    check(act(C, { "RES", 5 }), "mage can")
    act(A, { "SPEC", "WARRIOR.FURY" })
    check(act(A, { "RES", 6 }) == nil, "fury warrior cannot reserve a tank-only item")
    check(act(B, { "RES", 7 }), "an unknown item fits anyone")
    ctx.describe = nil
end

do -- a late first spec counts only before asking for anything
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    check(act(A, { "SPEC", "WARRIOR.ARMS" }) == nil, "no first spec after a want")
    check(act(B, { "SPEC", "PALADIN.HOLY" }), "first spec without a want counts")
end

do -- roll-first players who never roll do not hold the item up; ties still wait
    fresh()
    host.dry, client.dry = { [A] = true }, { [A] = true }
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(B, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    check(client.items["1"].restrict[A] and not client.items["1"].restrict[B], "roll-first only")
    check(act(HOST, { "CLOSE", "1" }) and client.items["1"].restrict == nil, "silent roll-first opens to all")
    act(HOST, { "ROLLSEEN", B, 50, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].winner == B, "then the others' rolls count")
end

do -- officers: closing a roll you won is logged; delivered wins need the host to undo
    fresh()
    act(HOST, { "OFF", A, 1 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(A, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(A, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 3, 1, 100 })
    local n = #client.log
    act(A, { "CLOSE", "1" })
    check(#client.log == n + 1 and client.log[#client.log].name == A, "self-won close is logged")
    act(HOST, { "DELIV", "1" })
    check(act(A, { "UNDO", "1" }) == nil, "officer cannot undo a delivered win")
    check(act(HOST, { "UNDO", "1" }), "the host can")
end

do -- the log keeps the newest entries; absurd times are refused
    fresh()
    for i = 1, R.MAX_LOG + 5 do
        R.Apply(host, { "LOG", i, HOST, "lock", A, "" })
    end
    check(#host.log == R.MAX_LOG and host.log[#host.log].t == R.MAX_LOG + 5, "log drops the oldest")
    R.Apply(host, { "PHASE", "live", "1e999" })
    check(host.started == 0, "PHASE never stores an absurd time")
end

do -- an age-ended session is still taken from its host; stale needs idle time
    local S = R.NewSession("H-R-1", "H-R", "", 1)
    S.phase, S.autoEnded = "ended", true
    local nctx = {
        now = 100,
        recent = {},
        isLead = function()
            return false
        end,
        isLeadOrAssist = function()
            return false
        end,
    }
    check(R.AcceptNew(S, { "NEW", "H-R-1", "H-R", "", "1" }, "H-R", nctx), "auto-ended: host snapshot taken")
    S.autoEnded = nil
    check(not R.AcceptNew(S, { "NEW", "H-R-1", "H-R", "", "1" }, "H-R", nctx), "really ended: refused")
    local live = R.NewSession("H-R-2", "H-R", "", 0)
    check(not R.IsStale(live, 24 * 3600), "a day-old reserve session is not stale")
    live.phase, live.started = "live", 0
    live.log = { { t = R.STALE_LIVE } }
    check(not R.IsStale(live, R.STALE_LIVE + 10), "recent officer action keeps it open")
    check(R.IsStale(live, 2 * R.STALE_LIVE + 10), "idle long enough: stale")
end

do -- untrusted raids never decide who rolls first
    local H = {
        real = {
            started = 1,
            created = 1,
            items = { ["1"] = { wants = { [A] = true }, rolls = {} } },
            specs = { [C] = "x" },
        },
        fake = {
            started = 1,
            created = 9,
            untrusted = true,
            items = { ["1"] = { wants = { [B] = true }, rolls = {} } },
        },
    }
    for i = 1, R.MIN_ATTEND do
        H.real.items["p" .. i] = { wants = { ["P" .. i .. "-Realm"] = true }, rolls = {} }
        H.fake.items["p" .. i] = { wants = { ["F" .. i .. "-Realm"] = true }, rolls = {} }
    end
    local dry = "," .. table.concat(R.RegularsFrom(H), ",") .. ","
    local function has(n)
        return dry:find("," .. n .. ",", 1, true) ~= nil
    end
    check(has(A) and not has(B) and not has(C), "regulars skip an untrusted raid and spec-only names")
end

do -- a reserve pays out only if the item still suits the reserver's loot spec
    fresh()
    act(A, { "RES", 9 })
    act(A, { "SPEC", "WARRIOR.FURY" })
    act(HOST, { "ADD", "item:9" })
    act(HOST, { "SPECS", "1", "WARRIOR.PROTECTION" })
    act(HOST, { "START", "1" })
    check(client.items["1"].mode == "normal", "respecced reserver does not win outright")
end

do -- roll-first from attendance (rec.att, local only); small parties never count
    local att = {}
    for i = 1, R.MIN_ATTEND - 1 do
        att["P" .. i .. "-Realm"] = true
    end
    att[A] = true
    local H = {
        real = {
            started = 1,
            created = 1,
            att = att,
            reserves = { [C] = 5 }, -- reserved, then left before the raid: not in att
            items = { ["1"] = { state = "done", winner = A, how = "roll", wants = { [B] = true }, rolls = {} } },
        },
    }
    local dry = R.RegularsFrom(H)
    check(#dry == R.MIN_ATTEND and dry[1] == A, "att: everyone seen in the group, winners too")
    local inAtt = {}
    for _, n in ipairs(dry) do
        inAtt[n] = true
    end
    check(not inAtt[B] and not inAtt[C], "att: a want or reserve from someone not in the group counts for nothing")
    H.party = { started = R.NIGHT + 9, created = R.NIGHT + 9, att = { [B] = true, [C] = true }, items = {} }
    check(#R.RegularsFrom(H) == R.MIN_ATTEND, "att: a newer raid under MIN_ATTEND players is skipped")
    local S = R.Apply(nil, { "NEW", "Host-Realm-5", HOST, "x", 5 })
    S.att = att
    local found = false
    for _, op in ipairs(R.Snapshot(S)) do
        for _, v in ipairs(op) do
            found = found or v == A
        end
    end
    check(not found, "att is never sent in a snapshot")
end

do -- out of a raid group, a NEW from someone else never replaces a running raid we host
    local LEAD = "Lead-Realm"
    local mine = R.Apply(nil, { "NEW", HOST .. "-1", HOST, "x", 1 })
    local nctx = {
        now = 100,
        me = HOST,
        isLead = function(n)
            return n == LEAD
        end,
        isLeadOrAssist = function(n)
            return n == LEAD
        end,
        recent = {},
    }
    local op = { "NEW", LEAD .. "-100", LEAD, "x", "100" }
    check(not R.AcceptNew(mine, op, LEAD, nctx), "our running raid is not taken over from a party")
    nctx.inRaid = true
    check(R.AcceptNew(mine, op, LEAD, nctx), "in a raid group the leader takes over, as everyone else accepts it")
    nctx.inRaid = nil
    nctx.me = "Other-Realm"
    check(R.AcceptNew(mine, op, LEAD, nctx), "a leader may take over someone else's raid")
    nctx.me = HOST
    mine.phase = "ended"
    check(R.AcceptNew(mine, op, LEAD, nctx), "once ours ended, a new raid may start")
end

do -- no loot spec on record: no asking for spec gear
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "SPECS", "1", "WARRIOR.FURY" })
    act(HOST, { "START", "1" })
    local ok, why = act(A, { "WANT", "1", 1 })
    check(not ok and why == "Pick your loot spec first.", "want refused without a spec")
    act(A, { "SPEC", "WARRIOR.FURY" })
    check(act(A, { "WANT", "1", 1 }), "want allowed once the spec is set")
    local last = client.log and client.log[#client.log]
    check(last and last.what == "specs", "SPECS is logged")
    check(act(HOST, { "OFF", B, 1 }) and client.log[#client.log].what == "officer", "host OFF is logged")
end

do -- the log keeps awards and take-backs when trimmed, and stays bounded
    fresh()
    R.Apply(host, { "LOG", 1, HOST, "award", A, "1" })
    for i = 2, R.MAX_LOG + 5 do
        R.Apply(host, { "LOG", i, HOST, "lock", A, "" })
    end
    check(#host.log == R.MAX_LOG and host.log[1].what == "award", "log trim keeps the oldest award")
    fresh()
    R.Apply(host, { "LOG2", 1, HOST, "close", A, "1" })
    R.Apply(host, { "LOG", 2, HOST, "open", nil, "1" })
    for i = 3, R.MAX_LOG + 50 do
        R.Apply(host, { "LOG", i, HOST, i % 2 == 0 and "lock" or "unlock", A, "" })
    end
    check(host.log[1].what == "close" and host.log[2].what == "open", "a lock flood cannot push out opens and closes")
    for i = 1, R.MAX_LOG + 5 do
        R.Apply(host, { "LOG", 1000 + i, HOST, "undo", A, "1" })
    end
    check(#host.log == R.MAX_LOG and host.log[#host.log].t == 1000 + R.MAX_LOG + 5, "all awards: oldest goes")
end

do -- stats skip untrusted raids
    local st = R.PlayerStats({
        x = { started = 1, untrusted = true, items = { a = { state = "done", winner = A, how = "roll" } } },
    })
    check(st[A] == nil, "an untrusted raid counts for no stats")
end

do -- wire edge cases
    fresh()
    check(R.Apply(host, { "ADD", "01", "item:1" }) == nil, "ADD key must be canonical")
    local cap = R.MAX_ITEMS
    R.MAX_ITEMS = 1
    check(R.Apply(host, { "ADD", "1", "item:1" }), "ADD under the cap")
    check(R.Apply(host, { "ADD", "2", "item:2" }) == nil, "ADD over MAX_ITEMS refused")
    R.MAX_ITEMS = cap
    check(R.Apply(host, { "ITEM", "1", "done", "normal", 0, "", "" }) == nil, "ITEM cannot set done")
    check(R.Apply(host, { "ITEMADD", "1", "r", A }) == nil, "ITEMADD on a list not marked + refused")
    R.Apply(host, { "ITEM", "1", "interest", "normal", 0, "+", "" })
    check(R.Apply(host, { "ITEMADD", "1", "r", A }) and host.items["1"].restrict[A], "ITEMADD on a + list")
    R.Apply(host, { "AWARD", "1", A, "manual", 5 })
    check(R.Apply(host, { "CANCEL", "1" }) == nil, "CANCEL of a won item refused in Apply")
    local ok, why = R.Intent(host, HOST, { "CANCEL", "1" }, ctx)
    check(not ok and why == "That item is finished.", "CANCEL of a won item refused in Intent")
end

do -- reserve item, every reserver gone: CALL falls back to normal interest
    fresh()
    act(A, { "RES", 7 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:7" })
    act(HOST, { "START", "1" })
    check(host.items["1"].mode == "reserve", "a reserved item starts in reserve mode")
    CLASS[A] = nil
    act(HOST, { "CALL", "1" })
    CLASS[A] = 1
    check(client.items["1"].mode == "normal" and client.items["1"].state == "interest", "no reserver here: normal")
end

-- ---- fairness fixes (2026-10-28, docs/FAIRNESS_AUDIT.md) --------------------
-- Host copy rebuilt from its snapshot, compared field by field.
local function snapshotMatches()
    local function same(a, b)
        if type(a) ~= type(b) or type(a) ~= "table" then
            return a == b
        end
        for k, v in pairs(a) do
            if not same(v, b[k]) then
                return false
            end
        end
        for k in pairs(b) do
            if a[k] == nil then
                return false
            end
        end
        return true
    end
    local rebuilt
    for _, op in ipairs(R.Snapshot(host)) do
        rebuilt = assert(R.Apply(rebuilt, R.Decode(R.EncodeOp(op))[1]))
    end
    return same(host, rebuilt) and same(host, client)
end
local function wins(name)
    local n = 0
    for _, it in pairs(host.items) do
        n = n + ((it.state == "done" and it.winner == name and it.how ~= "open") and 1 or 0)
    end
    return n
end

do -- F1: a tie reroll does not let a player locked mid-roll win a second item
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "ADD", "item:2" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(B, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 77, 1, 100 })
    act(HOST, { "ROLLSEEN", B, 77, 1, 100 })
    act(HOST, { "CLOSE", "1" }) -- tie: A and B reroll
    check(act(HOST, { "AWARD", "2", A }) == nil, "F1: no hand award of another item mid-roll")
    for _, op in ipairs({ { "LOCK", A, 1 } }) do -- as an older host could still send
        host, client = assert(R.Apply(host, op)), assert(R.Apply(client, op))
    end
    check(act(HOST, { "ROLLSEEN", A, 90, 1, 100 }) == nil, "F1: a locked player cannot roll in a tie reroll")
    act(HOST, { "ROLLSEEN", B, 10, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].winner == B and wins(A) == 0, "F1: the unlocked tied player wins")
end

do -- F1: co-reservers without an item roll first
    fresh()
    host.dry, client.dry = { [A] = true }, { [A] = true } -- A is a regular: the reserve survives a win
    act(A, { "RES", 500 })
    act(B, { "RES", 500 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 50, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    act(HOST, { "ADD", "item:500" })
    act(HOST, { "START", "2" })
    check(client.items["2"].restrict[A] and client.items["2"].restrict[B], "F1: both reservers are listed")
    act(HOST, { "CALL", "2" })
    check(client.items["2"].winner == B and client.items["2"].how == "reserve", "F1: the unlocked reserver gets it")
    check(client.reserves[A] == 500, "F1: the locked regular keeps the reserve")
end

do -- F2: a reserve is a second item only for a regular
    fresh()
    act(A, { "RES", 500 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 20, 1, 100 })
    local ops = act(HOST, { "CLOSE", "1" })
    check(ops[2][1] == "RES" and client.reserves[A] == nil, "F2: a non-regular's win uses up the reserve")
    check(snapshotMatches(), "F2: snapshot carries the used-up reserve")
    act(HOST, { "UNDO", "1" })
    check(client.reserves[A] == 500 and not client.locks[A], "F2: undo of that win gives the reserve back")
    act(HOST, { "AWARD", "1", A })
    client.reserves[A], host.reserves[A] = 500, 500 -- as if an officer locked A with the reserve left
    act(HOST, { "ADD", "item:500" })
    act(HOST, { "START", "2" })
    check(client.items["2"].mode == "normal", "F2: a locked non-regular's reserve does not pay out")
end

do -- F3: a reserved item keeps its class limit
    fresh()
    act(C, { "RES", 5 })
    act(HOST, { "PHASE", "live" })
    ctx.describe = function()
        return R.ClassBit(8), ""
    end
    act(HOST, { "ADD", "item:5" })
    ctx.describe = nil
    act(HOST, { "START", "1" })
    check(client.items["1"].mode == "reserve" and client.items["1"].classMask == R.ClassBit(8), "F3: mask kept")
end

do -- regulars: 75% of the last 8 raids, 75% of each raid, one night per 12 h
    local function rec(created, inst, present, span)
        local att = {}
        for i = 1, R.MIN_ATTEND do
            att["Fill" .. i .. "-Realm"] = 3600
        end
        for n, t in pairs(present) do
            att[n] = t
        end
        return { started = created, created = created, inst = inst, att = att, attSpan = span or 3600, items = {} }
    end
    local H, day = {}, 86400
    for w = 1, 8 do
        -- A: every week. B: 6 of 8. C: 5 of 8. D: every week, 10 minutes.
        local p = { [A] = 3600, ["D-Realm"] = 600 }
        p[B] = w > 2 and 3600 or nil
        p[C] = w > 3 and 3600 or nil
        H["w" .. w] = rec(w * 7 * day, 409, p)
    end
    local function list(inst)
        return "," .. table.concat(R.RegularsFrom(H, "now", inst), ",") .. ","
    end
    local l = list(409)
    check(l:find("," .. A .. ",", 1, true) and l:find("," .. B .. ",", 1, true), "regulars: 8 and 6 of 8 count")
    check(not l:find("," .. C .. ",", 1, true), "regulars: 5 of 8 does not")
    check(not l:find("D-Realm", 1, true), "regulars: ten minutes a night is not attendance")
    H.alt = rec(8 * 7 * day + 3600, 309, { [C] = 3600 }) -- an alt run elsewhere, an hour later
    check(list(409) == l, "regulars: another instance does not count")
    H.split = rec(8 * 7 * day + 1800, 409, { [C] = 3600 }) -- End raid + New raid, same night
    check(list(409) == l, "regulars: a second session the same night is one night")
    H.split = nil
    H.alt.inst = nil -- no instance and attSpan: never in a raid instance
    check(list(409) == l, "regulars: a session outside any raid instance does not count")
    H.w8.bench = { [C] = true }
    H.w3.bench = { [C] = true }
    check(list(409):find("," .. C .. ",", 1, true), "regulars: bench counts as present")
    check(R.Present({ att = { [A] = 2700 }, attSpan = 3600 }, A), "present: 75% of the raid")
    check(not R.Present({ att = { [A] = 2699 }, attSpan = 3600 }, A), "present: under 75% is not")
end

do -- F6: a first spec set after the start cannot make a main-spec win free
    fresh()
    act(B, { "SPEC", "PALADIN.RET" })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "SPECS", "1", "WARRIOR.ARMS,WARRIOR.FURY" })
    act(HOST, { "START", "1" })
    act(HOST, { "CALL", "1" }) -- nobody asked: open
    check(act(A, { "SPEC", "WARRIOR.PROT" }), "F6: first spec after the start is taken")
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 90, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.items["1"].how == "roll" and client.locks[A], "F6: judged by class: the win locks")
    check(client.lateSpec[A] and not client.lateSpec[B], "F6: only the late spec is marked")
    check(snapshotMatches(), "F6: snapshot keeps the late mark")
end

do -- F7: undo keeps the lock when a free win was really their item
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "ADD", "item:2" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 60, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    act(HOST, { "START", "2" })
    act(HOST, { "CALL", "2" }) -- B stays quiet: open
    act(A, { "WANT", "2", 1 })
    act(HOST, { "CALL", "2" })
    act(HOST, { "ROLLSEEN", A, 80, 1, 100 })
    act(HOST, { "CLOSE", "2" })
    check(client.items["2"].how == "open", "F7 fixture: the second win was free")
    act(HOST, { "UNDO", "1" })
    check(client.locks[A], "F7: undo of the locking win keeps the free winner locked")
end

do -- O1: no repeated phase changes; the log keeps the evidence
    fresh()
    act(HOST, { "PHASE", "live" })
    local ok, why = act(HOST, { "PHASE", "live" })
    check(not ok and why == "The raid has already started.", "O1: PHASE live twice refused")
    act(HOST, { "PHASE", "ended" })
    check(act(HOST, { "PHASE", "ended" }) == nil, "O1: PHASE ended twice refused")
    fresh()
    R.Apply(host, { "LOG", 1, HOST, "unlock", A, "" })
    R.Apply(host, { "LOG", 2, HOST, "cancel", nil, "1" })
    R.Apply(host, { "LOG2", 3, HOST, "void", nil, "1" })
    for i = 4, R.MAX_LOG + 50 do
        R.Apply(host, { "LOG2", i, HOST, i % 2 == 0 and "live" or "ended", "", "" })
    end
    local w = host.log
    check(w[1].what == "unlock" and w[2].what == "cancel" and w[3].what == "void", "O1: a phase flood keeps the rest")
    for i = 1, R.MAX_LOG do
        R.Apply(host, { "LOG", 1000 + i, HOST, "award", A, "1" })
    end
    check(
        #host.log == R.MAX_LOG and host.log[1].what == "unlock" and host.log[4].t == 1004,
        "O1: all kept kinds: the oldest of the flood's own kind goes, still bounded"
    )
end

do -- O2: eligibility is frozen during a roll; suggested specs are kept
    fresh()
    act(A, { "SPEC", "WARRIOR.FURY" })
    act(C, { "RES", 9 })
    act(HOST, { "PHASE", "live" })
    ctx.describe = function()
        return 0, "WARRIOR.ARMS,WARRIOR.FURY"
    end
    act(HOST, { "ADD", "item:1" })
    ctx.describe = nil
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    local _, why = act(HOST, { "LOCK", A, 1 })
    check(why == "Wait until the roll is closed.", "O2: no lock during a roll")
    check(act(HOST, { "SETSPEC", A, "WARRIOR.PROT" }) == nil, "O2: no spec change during a roll")
    check(act(HOST, { "SPECS", "1", "MAGE.FIRE" }) == nil, "O2: no Who can roll change during a roll")
    act(HOST, { "CANCEL", "1" })
    act(HOST, { "ADD", "item:2" })
    act(HOST, { "SPECS", "2", "WARRIOR.ARMS,WARRIOR.FURY" }) -- the first list stays suggested
    act(HOST, { "START", "2" })
    act(A, { "WANT", "2", 1 })
    act(HOST, { "SPECS", "2", "MAGE.FIRE" }) -- emptied for A's spec while nobody rolls
    check(act(HOST, { "OPEN", "2" }) == nil, "O2: Open still sees the suggested specs")
    act(HOST, { "CALL", "2" }) -- nobody eligible now: it opens
    act(HOST, { "CALL", "2" })
    act(HOST, { "ROLLSEEN", A, 50, 1, 100 })
    act(HOST, { "CLOSE", "2" })
    check(client.items["2"].how == "roll" and client.locks[A], "O2: a main-spec win stays a locking win")
    check(snapshotMatches(), "O2: snapshot keeps the suggested specs")
    check(act(HOST, { "SETSPEC", C, "MAGE.FROST" }) == nil, "O2: a reserver's spec stays after the start")
    check(act(HOST, { "LOCK", B, 0 }) and #act(HOST, { "LOCK", B, 0 }) == 0, "O1: an unchanged lock logs nothing")
end

do -- O3: undo keeps the result; cancel names the item
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 40, 1, 100 })
    act(HOST, { "ROLLSEEN", B, 30, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    act(HOST, { "UNDO", "1" })
    local u = client.items["1"].undone
    check(u and u.winner == A and u.how == "roll" and u.rolls[B] == 30, "O3: the undone result stays on the item")
    check(snapshotMatches(), "O3: snapshot keeps the undone result")
    act(HOST, { "CANCEL", "1" })
    check(client.log[#client.log].what == "cancel" and client.log[#client.log].key == "1", "O3: cancel names the item")
end

do -- O4: a roll stays open a few seconds; only a named-players roll closes early
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(B, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    local at = ctx.now
    ctx.rollingSince = function()
        return at
    end
    act(HOST, { "ROLLSEEN", A, 40, 1, 100 })
    local _, why = act(HOST, { "CLOSE", "1" })
    check(why == "Give everyone a few seconds to roll.", "O4: no close the second a friend rolls")
    act(HOST, { "ROLLSEEN", B, 30, 1, 100 })
    -- Anyone in the group may roll on an open-to-wanters roll: it waits.
    check(act(HOST, { "CLOSE", "1" }) == nil, "O4: every wanter rolled: an unrestricted roll still waits")
    ctx.now = at + R.ROLL_MIN
    check(act(HOST, { "CLOSE", "1" }) and client.items["1"].winner == A, "O4: closes after ROLL_MIN")
    ctx.now = 1000
    ctx.rollingSince = nil
end

do -- F9, VOID, MLGAVE, BENCH
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    ctx.inEncounter = function()
        return true
    end
    local _, why = act(HOST, { "CALL", "1" })
    check(why == "Wait for the fight to end.", "F9: no call during a boss fight")
    ctx.inEncounter = nil
    host.dry, client.dry = { [A] = true }, { [A] = true }
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 3, 1, 100 })
    check(act(A, { "VOID", "1" }) == nil, "VOID: officers only")
    act(HOST, { "VOID", "1" })
    local it = client.items["1"]
    check(not next(it.rolls) and it.state == "rolling" and it.restrict[A] and not it.restrict[B], "VOID: rolls wiped")
    check(client.log[#client.log].what == "void", "VOID: logged")
    check(act(HOST, { "ROLLSEEN", A, 70, 1, 100 }), "VOID: the roll can be made again")
    check(act(B, { "MLGAVE", "1", C }) == nil, "MLGAVE: a raider cannot report")
    ctx.isMasterLooter = function(n)
        return n == B
    end
    check(act(B, { "MLGAVE", "1", C }) and client.log[#client.log].what == "mlgive", "MLGAVE: the master looter can")
    check(#act(B, { "MLGAVE", "1", C }) == 0, "MLGAVE: logged once")
    ctx.isMasterLooter = nil
    check(act(A, { "BENCH", C, 1 }) == nil, "BENCH: officers only")
    act(HOST, { "BENCH", C, 1 })
    check(client.bench[C] and client.log[#client.log].what == "bench", "BENCH: marked and logged")
    local kinds = {}
    for _, op in ipairs(R.Snapshot(host)) do
        kinds[op[1] .. (op[4] or "")] = true
    end
    check(kinds.LOG2void and kinds.LOG2mlgive and kinds.LOG2bench, "new log kinds go as LOG2")
    check(snapshotMatches(), "BENCH: snapshot keeps the bench")
    check(R.Present(host, C) and R.Present({ bench = { [C] = true }, att = {} }, C), "BENCH: counts as present")
end

do -- the lock log names the item being rolled
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(HOST, { "LOCK", A, 1 })
    check(client.log[#client.log].what == "lock" and client.log[#client.log].key == "1", "lock log names the item")
end

-- Help search highlight.
do
    local Y = "<"
    check(NS.Kit.Highlight("Roll for loot", "roll", Y) == "<Roll|r for loot", "highlight keeps the text's own case")
    check(NS.Kit.Highlight("a roll, a reroll", "roll", Y) == "a <roll|r, a re<roll|r", "highlight marks every match")
    check(NS.Kit.Highlight("|cffb6ffb6Keep|r it", "ff", Y) == "|cffb6ffb6Keep|r it", "never inside a colour code")
    check(
        NS.Kit.Highlight("|cffb6ffb6Keep|r it", "keep", Y) == "|cffb6ffb6<Keep|r|r it",
        "inside coloured text still marks"
    )
    check(NS.Kit.Highlight("a|nb", "|n", Y) == "a|nb", "escape codes themselves never match")
    check(NS.Kit.Highlight("text", "", Y) == "text", "empty search changes nothing")
end

-- ---- review round (2026-10-28) ----------------------------------------------
local function closeOne(key, winner) -- a finished roll on item `key`
    act(HOST, { "START", key })
    act(winner, { "WANT", key, 1 })
    act(HOST, { "CALL", key })
    act(HOST, { "ROLLSEEN", winner, 50, 1, 100 })
    act(HOST, { "CLOSE", key })
end
local function inLog(what)
    for _, e in ipairs(client.log or {}) do
        if e.what == what then
            return true
        end
    end
    return false
end

do -- V1: a flood of unlocks or master loot reports only pushes out itself
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    closeOne("1", A)
    act(HOST, { "OFF", B, 1 })
    check(inLog("close"), "V1 fixture: the win is logged")
    for i = 1, 2 * R.MAX_LOG do
        act(B, { "LOCK", C, i % 2 })
    end
    check(#client.log == R.MAX_LOG and inLog("close"), "V1: lock/unlock toggles keep the win in the log")
    check(snapshotMatches(), "V1: snapshot after the flood")
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    closeOne("1", A)
    ctx.isMasterLooter = function(n)
        return n == C
    end
    local _, why = act(C, { "MLGAVE", "1", "Fake-R" })
    check(why == "That player is not in the group.", "V1: MLGAVE names a group member")
    check(#act(C, { "MLGAVE", "1", A }) == 0, "V1: MLGAVE to the winner is no report")
    check(act(C, { "MLGAVE", "1", B }) and client.log[#client.log].what == "mlgive", "V1: MLGAVE to another")
    check(#act(C, { "MLGAVE", "1", HOST }) == 0, "V1: one MLGAVE per item, whatever the name")
    ctx.isMasterLooter = nil
end

do -- V2: no hand award or undo of another item while a roll is open
    fresh()
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "ADD", "item:2" })
    act(HOST, { "ADD", "item:3" })
    closeOne("3", B)
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    local _, why = act(HOST, { "AWARD", "2", A })
    check(why == "Wait until the roll is closed.", "V2: no AWARD of another item mid-roll")
    _, why = act(HOST, { "UNDO", "3" })
    check(why == "Wait until the roll is closed.", "V2: no UNDO mid-roll")
    check(act(HOST, { "AWARD", "1", A }), "V2: the rolled item itself can still be given")
end

do -- V3: the bench rides in LOG2 (v0.6.1 resyncs on an unknown op kind)
    local OLD_KINDS = {}
    for k in
        ("NEW PHASE SPEC DRY LOG LOG2 OFF LOCK RES ADD ITEM WANT ROLL REROLL AWARD UNDO CANCEL ITEMADD DELIV"):gmatch(
            "%u+%d?"
        )
    do
        OLD_KINDS[k] = true
    end
    fresh()
    act(HOST, { "PHASE", "live" })
    local ops = act(HOST, { "BENCH", C, 1 })
    check(#ops == 1 and ops[1][1] == "LOG2" and client.bench[C], "V3: BENCH is one LOG2 op and sets the bench")
    act(HOST, { "BENCH", C, 0 })
    act(HOST, { "BENCH", C, 1 })
    act(HOST, { "BENCH", B, 1 })
    act(HOST, { "BENCH", B, 0 })
    check(client.bench[C] and not client.bench[B], "V3: unbench clears it")
    local old = true
    for _, op in ipairs(R.Snapshot(host)) do
        old = old and OLD_KINDS[op[1]] == true
    end
    check(old, "V3: a snapshot has only op kinds v0.6.1 knows")
    check(R.Apply(host, { "BENCH", A, 1 }) == nil, "V3: no BENCH op any more")
    check(snapshotMatches(), "V3: a late joiner gets the same bench")
    for i = 1, R.MAX_LOG do -- kept kinds push the bench entries out of the log
        local op = { "LOG", 2000 + i, HOST, "award", A, "1" }
        host, client = assert(R.Apply(host, op)), assert(R.Apply(client, op))
    end
    check(not inLog("bench") and client.bench[C], "V3 fixture: bench entry gone, bench kept")
    check(snapshotMatches(), "V3: snapshot still carries a bench the log dropped")
    check(R.Apply(host, { "LOG2", 1, HOST, "bench", "", "" }) == nil, "V3: a bench entry needs a name")
end

do -- V4: a reserve used up by another win no longer pays out
    fresh()
    act(A, { "RES", 7 })
    act(B, { "RES", 9 })
    act(C, { "RES", 9 })
    act(HOST, { "ADD", "item:7" })
    act(HOST, { "ADD", "item:8" })
    act(HOST, { "ADD", "item:9" })
    act(HOST, { "START", "1" })
    act(HOST, { "AWARD", "2", A }) -- spends A's reserve while item 1 waits
    check(not client.reserves[A], "V4 fixture: reserve used up")
    act(HOST, { "CALL", "1" })
    check(
        client.items["1"].state == "interest" and client.items["1"].mode == "normal",
        "V4: CALL skips a spent reserve"
    )
    act(HOST, { "CANCEL", "1" })
    act(HOST, { "START", "3" })
    act(HOST, { "CALL", "3" })
    act(HOST, { "ROLLSEEN", B, 90, 1, 100 })
    act(HOST, { "ROLLSEEN", C, 10, 1, 100 })
    local op = { "RES", B, 0 } -- as an older host could still send mid-roll
    host, client = assert(R.Apply(host, op)), assert(R.Apply(client, op))
    act(HOST, { "CLOSE", "3" })
    check(client.items["3"].winner == C, "V4: CLOSE skips a roll on a spent reserve")
end

do -- V5: only a named-players roll closes before ROLL_MIN, once all rolled
    fresh()
    act(A, { "RES", 7 })
    act(B, { "RES", 7 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:7" })
    act(HOST, { "START", "1" })
    act(HOST, { "CALL", "1" })
    local at = ctx.now
    ctx.rollingSince = function()
        return at
    end
    act(HOST, { "ROLLSEEN", A, 40, 1, 100 })
    check(act(HOST, { "CLOSE", "1" }) == nil, "V5: a reserver has not rolled: wait")
    act(HOST, { "ROLLSEEN", B, 30, 1, 100 })
    check(act(HOST, { "CLOSE", "1" }) and client.items["1"].winner == A, "V5: every reserver rolled: close at once")
    act(HOST, { "ADD", "item:2" })
    act(HOST, { "START", "2" })
    act(B, { "WANT", "2", 1 })
    act(HOST, { "CALL", "2" })
    act(HOST, { "ROLLSEEN", B, 40, 1, 100 })
    check(client.items["2"].state == "rolling", "V5 fixture: a normal roll")
    check(act(HOST, { "CLOSE", "2" }) == nil, "V5: the only wanter rolled, but anyone may: wait")
    ctx.rollingSince = nil
end

do -- V6, V8: who makes a raid count, and what is one night
    local function raid(day, present, bench, start)
        local att, b = {}, {}
        for _, n in ipairs(present) do
            att[n] = 3600
        end
        for _, n in ipairs(bench or {}) do
            b[n] = true
        end
        local t = start or day * 86400
        return { created = t, started = t + 60, inst = 409, att = att, attSpan = 3600, bench = b, items = {} }
    end
    local ten, a, b = {}, {}, {}
    for i = 1, R.MIN_ATTEND do
        ten[i] = "T" .. i .. "-R"
    end
    for i = 1, 6 do
        a[i], b[i] = "A" .. i .. "-R", "B" .. i .. "-R"
    end
    local H = {}
    for d = 1, 4 do
        H["r" .. d] = raid(d, { A, B, C }, ten)
    end
    check(#R.RegularsFrom(H, nil, 409) == 0, "V6: a bench list does not make a small party count")
    for d = 1, 4 do
        H["r" .. d] = raid(d, ten, { C })
    end
    local l = "," .. table.concat(R.RegularsFrom(H, nil, 409), ",") .. ","
    check(l:find("," .. C .. ",", 1, true) ~= nil, "V6: the bench still counts as present")
    H = {}
    for d = 1, 3 do
        H["x" .. d] = raid(d, a)
        H["y" .. d] = raid(d, b, nil, d * 86400 + 3600)
    end
    check(#R.RegularsFrom(H, nil, 409) == 12, "V8: two half raids in one night make one counting night")
    H = {}
    for i = 1, 9 do -- 11 h apart: no chain of nights
        H["c" .. i] = raid(0, i == 1 and ten or { A, unpack(ten, 2) }, nil, i * 11 * 3600)
    end
    l = "," .. table.concat(R.RegularsFrom(H, nil, 409), ",") .. ","
    check(
        not l:find(",T1-R,", 1, true) and l:find("," .. A .. ",", 1, true),
        "V8: a night is 12 h from its first start"
    )
end

do -- V7: no spec on record: a first spec between items, never a dead end
    fresh()
    ctx.describe = function(s)
        return 0, s == "item:9" and "WARRIOR.PROT" or ""
    end
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "WANT", "1", 1 }) -- wants, never rolls: no item
    act(HOST, { "CALL", "1" })
    local _, why = act(B, { "SPEC", "PALADIN.HOLY" })
    check(why == "Wait until the roll is closed.", "V7: no first spec mid-roll")
    act(HOST, { "ROLLSEEN", A, 50, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    act(HOST, { "ADD", "item:9" })
    act(HOST, { "START", "2" })
    _, why = act(HOST, { "WANT", "2", 1 })
    check(why == "Pick your loot spec first.", "V7 fixture: the spec item asks for a spec")
    check(
        act(HOST, { "SPEC", "WARRIOR.PROT" }) and client.lateSpec[HOST],
        "V7: a first spec after an earlier want, marked late"
    )
    check(act(HOST, { "WANT", "2", 1 }), "V7: then the spec item can be asked for")
    check(act(HOST, { "SPEC", "WARRIOR.ARMS" }) == nil, "V7: and the spec is locked")
    ctx.describe = nil
end

-- No spec on record (no addon): the item must suit every spec of the class,
-- so skipping the addon never widens what you can roll on.
do
    local W = R.CLASS_ID.WARRIOR
    local S = { specs = { ["Tank-R"] = "WARRIOR.PROT" }, locks = {} }
    local tank = { mode = "normal", classMask = 0, specs = { ["WARRIOR.PROT"] = true } }
    local any = {
        mode = "normal",
        classMask = 0,
        specs = { ["WARRIOR.ARMS"] = true, ["WARRIOR.FURY"] = true, ["WARRIOR.PROT"] = true },
    }
    R.CLASS_SPECS.WARRIOR = { "WARRIOR.ARMS", "WARRIOR.FURY", "WARRIOR.PROT" }
    check(R.Suits(S, tank, "Tank-R", W), "a prot warrior suits tank plate")
    check(not R.Suits(S, tank, "Nox-R", W), "no addon: tank plate does not suit a warrior of unknown spec")
    check(R.Suits(S, any, "Nox-R", W), "no addon: an item for every warrior spec suits")
    check(R.Suits(S, { mode = "open", classMask = 0, specs = tank.specs }, "Nox-R", W), "and open items still do")
    R.CLASS_SPECS.WARRIOR = nil
end

print(string.format("test_rules: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
