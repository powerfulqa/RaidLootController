#!/usr/bin/env lua
-- Smoke test for RLC_Demo.lua: builds the whole demo raid, history and
-- catalogue under stock Lua with the client stubbed out, so a bad op in the
-- demo data fails here instead of throwing in game. Run from the repo root:
--   lua tests/test_demo.lua

local NS = {}
assert(loadfile("RLC_Rules.lua"))("RaidLootController", NS)
assert(loadfile("RLC_Catalog.lua"))("RaidLootController", NS)
assert(loadfile("RLC_Specs.lua"))("RaidLootController", NS)
local Rules = NS.Rules

-- Client stubs.
GetServerTime = function()
    return 1800000000
end
local function copy(t)
    if type(t) ~= "table" then
        return t
    end
    local c = {}
    for k, v in pairs(t) do
        c[k] = copy(v)
    end
    return c
end
CopyTable = copy
local real = { mySpec = {}, minQuality = 3, history = {}, catalog = {} }
RaidLootControllerDB = real
NS.DB = real
NS.Me = function()
    return "Tester-Realm"
end
NS.Specs.Mine = function()
    return "ROGUE.COMBAT"
end
local shown = false
NS.RefreshRoster, NS.Refresh, NS.Print = function() end, function() end, function() end
NS.Show = function()
    shown = true
end
NS.historyGen = 0
NS.Loot = { OwedChanged = function() end }

assert(loadfile("RLC_Demo.lua"))("RaidLootController", NS)

local passed, failed = 0, 0
local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. label)
    end
end

NS.Demo.Toggle()
local db = NS.DB
check(NS.Demo.active and db ~= real and shown, "demo on: swapped in a separate data table")
local S = db.session
check(S.host == "Tester-Realm" and S.phase == "live", "you host a live raid")
check(S.active == "6" and S.items["6"].state == "rolling", "one item is being rolled for")
local states = {}
for _, item in pairs(S.items) do
    states[item.state] = true
end
check(states.done and states.pending and states.cancelled and states.rolling, "items in every state")
local n = 0
for _ in pairs(db.history) do
    n = n + 1
end
check(n == 4, "history: three past raids plus this one")
check(
    db.catalog[2001] and db.catalog[2001].b[900008].kills == 5 and db.catalog[2002],
    "catalogue: two raids with boss kills"
)
check(next(real.history) == nil and next(real.catalog) == nil, "real saved data untouched")
check(S.locks["Shade-Demo"] and not S.reserves["Gorrum-Demo"], "winners locked, a won reserve is used up")

-- Every new view has something to show.
local u = S.items["12"].undone
check(u and u.winner == "Tor-Demo" and S.items["12"].winner == "Ruka-Demo", "a win taken back and given again")
check(not S.locks["Tor-Demo"], "the taken-back winner is unlocked")
check(S.bench["Kaelen-Demo"] and Rules.Present(S, "Kaelen-Demo"), "a bench name counts as present")
check(Rules.Present(S, "Brakk-Demo") and not Rules.Present(S, "Pyra-Demo"), "attendance: late joiner not present")
local kinds, kept = {}, false
for _, e in ipairs(S.log) do
    kinds[e.what] = true
    kept = kept or e.kept == true
end
check(
    kinds.void and kinds.mlgive and kinds.bench and kinds.undo and kept,
    "log: void, mlgive, bench, undo, a kept entry"
)
local regs = {}
for _, name in ipairs(Rules.RegularsFrom(db.history, S.id, 2001)) do
    regs[name] = true
end
check(regs["Brakk-Demo"] and not regs["Zev-Demo"] and not regs["Fang-Demo"], "regulars: came to both Barrow raids")
check(S.dry["Brakk-Demo"] and not S.dry["Zev-Demo"], "regulars roll first tonight")

NS.Demo.Toggle()
check(not NS.Demo.active and NS.DB == real, "demo off: real data back")

print(string.format("test_demo: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
