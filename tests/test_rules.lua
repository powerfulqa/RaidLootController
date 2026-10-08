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

-- ---- a win before the reserved item drops cancels the reserve ------------
do
    fresh()
    act(A, { "RES", 500 })
    act(B, { "RES", 500 })
    act(HOST, { "PHASE", "live" })
    act(HOST, { "ADD", "item:1" })
    act(HOST, { "START", "1" })
    act(A, { "WANT", "1", 1 })
    act(HOST, { "CALL", "1" })
    act(HOST, { "ROLLSEEN", A, 20, 1, 100 })
    act(HOST, { "CLOSE", "1" })
    check(client.reserves[A] == nil, "a normal win cancels the winner's reserve")
    act(HOST, { "ADD", "item:500" })
    act(HOST, { "START", "2" })
    act(HOST, { "CALL", "2" })
    local it = client.items["2"]
    check(it.winner == B and it.how == "reserve", "the remaining reserver gets it alone")
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

print(string.format("test_rules: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
