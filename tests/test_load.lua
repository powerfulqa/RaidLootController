#!/usr/bin/env lua
-- Loads every file the .toc lists, in order, with the game stubbed out, then
-- logs in, turns the demo raid on and draws every tab. No test read the
-- window files before this: a nil upvalue or a missing function after a
-- refactor fails here instead of in game. Run from the repo root:
--   lua tests/test_load.lua
--
-- The game is one self-returning mock: any field is the mock, any call
-- returns it. Calls whose result the addon does arithmetic or comparisons
-- on are given real values below.

local mock = {}
local mt = {}
mt.__index = function()
    return mock
end
mt.__call = function()
    return mock
end
mt.__newindex = function() end
mt.__concat = function(a, b)
    return (a == mock and "mock" or a) .. (b == mock and "mock" or b)
end
mt.__len = function()
    return 0
end
setmetatable(mock, mt)

local now = 1000
local timers, tickers, sent, tooltipCalls = {}, {}, {}, {}
-- The group and place the stubs report; the tests change these.
local group = {} -- raid units in order: { first, surname }
local guilded, instance = true, nil -- instance: { name, type, maxPlayers, id }

-- A frame: methods the addon reads numbers, strings or booleans from get
-- real ones; scripts are kept so the test can fire events.
local frameMT = {}
local frames = {}
local function newFrame()
    local f = setmetatable({ scripts = {}, events = {}, shown = false, text = "" }, frameMT)
    frames[#frames + 1] = f
    return f
end
local methods = {
    SetScript = function(self, name, fn)
        self.scripts[name] = fn
    end,
    GetScript = function(self, name)
        return self.scripts[name]
    end,
    HookScript = function() end,
    RegisterEvent = function(self, event)
        self.events[event] = true
    end,
    Show = function(self)
        self.shown = true
    end,
    Hide = function(self)
        self.shown = false
    end,
    SetShown = function(self, on)
        self.shown = on and true or false
    end,
    IsShown = function(self)
        return self.shown
    end,
    IsVisible = function(self)
        return self.shown
    end,
    SetText = function(self, text)
        self.text = text or ""
    end,
    GetText = function(self)
        return self.text
    end,
    GetWidth = function()
        return 700
    end,
    GetHeight = function()
        return 400
    end,
    GetStringWidth = function()
        return 50
    end,
    GetStringHeight = function()
        return 12
    end,
    GetFrameLevel = function()
        return 1
    end,
    GetNumPoints = function()
        return 0
    end,
    GetPoint = function()
        return "CENTER", nil, "CENTER", 0, 0
    end,
    GetName = function()
        return nil
    end,
    GetID = function()
        return 0
    end,
    GetEffectiveScale = function()
        return 1
    end,
    GetScale = function()
        return 1
    end,
    GetCenter = function()
        return 0, 0
    end,
    GetLeft = function()
        return 0
    end,
    GetRight = function()
        return 700
    end,
    GetTop = function()
        return 400
    end,
    GetBottom = function()
        return 0
    end,
    GetVerticalScroll = function()
        return 0
    end,
    GetVerticalScrollRange = function()
        return 0
    end,
    IsMouseOver = function()
        return false
    end,
    IsEnabled = function()
        return true
    end,
    HasFocus = function()
        return false
    end,
    GetChildren = function() end,
    GetRegions = function() end,
    GetObjectType = function()
        return "Frame"
    end,
    NumLines = function()
        return 0
    end,
}
for _, make in ipairs({ "CreateFontString", "CreateTexture", "CreateAnimationGroup", "CreateAnimation" }) do
    methods[make] = newFrame
end
frameMT.__index = function(self, key)
    local m = methods[key]
    if m then
        return m
    end
    -- Sub-frames a template provides (ScrollBar, Text, Inset...) and plain
    -- setters: a sub-frame is made on first read, a setter is a no-op.
    if type(key) == "string" and key:find("^%u") and not key:find("^Set") and not key:find("^Clear") then
        if key:find("^Get") or key:find("^Is") or key:find("^Has") or key:find("^Can") then
            return function() end
        end
        if
            key:find("^Enable")
            or key:find("^Disable")
            or key:find("^Register")
            or key:find("^Unregister")
            or key:find("^Lock")
            or key:find("^Unlock")
            or key:find("^Start")
            or key:find("^Stop")
            or key:find("^Add")
            or key:find("^Raise")
            or key:find("^Lower")
            or key:find("^Play")
            or key:find("^Click")
            or key:find("^Highlight")
            or key:find("^Insert")
        then
            return function() end
        end
        local sub = newFrame()
        rawset(self, key, sub)
        return sub
    end
    return function() end
end

-- Globals: unknown ones are nil unless given here; the C_ namespaces and a
-- few tables are the mock.
local G = {
    CreateFrame = newFrame,
    UIParent = newFrame(),
    Minimap = newFrame(),
    GameTooltip = newFrame(),
    ItemRefTooltip = newFrame(),
    TradeFrame = newFrame(),
    DEFAULT_CHAT_FRAME = newFrame(),
    UISpecialFrames = {},
    StaticPopupDialogs = {},
    SlashCmdList = {},
    SOUNDKIT = {},
    Enum = { LootMethod = { Masterlooter = 2, Group = 3 }, ItemQuality = {}, TooltipDataType = { Item = 0 } },
    Constants = {},
    YES = "Yes",
    NO = "No",
    NUM_BAG_SLOTS = 4,
    RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)",
    ITEM_CLASSES_ALLOWED = "Classes: %s",
    ERR_TRADE_COMPLETE = "Trade complete.",
    LE_PARTY_CATEGORY_INSTANCE = 2,
    GetTime = function()
        return now
    end,
    GetServerTime = function()
        return 1800000000
    end,
    date = os.date,
    strtrim = function(s)
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end,
    tinsert = table.insert,
    wipe = function(t)
        for k in pairs(t) do
            t[k] = nil
        end
        return t
    end,
    CopyTable = function(t)
        local function copy(v)
            if type(v) ~= "table" then
                return v
            end
            local c = {}
            for k, x in pairs(v) do
                c[k] = copy(x)
            end
            return c
        end
        return copy(t)
    end,
    GetBuildInfo = function()
        return "1.60.1", "70888", "Nov 1 2026", 16001
    end,
    GetLocale = function()
        return "enUS"
    end,
    -- Empty, as on the live client since 2026-11-20: the realm comes from
    -- the save below (this character's own mySpec key).
    GetNormalizedRealmName = function()
        return ""
    end,
    RegionalUniqueNamesEnabled = function()
        return true
    end,
    UnitName = function(unit)
        local who = unit == "player" and { "Tester", "Stub" } or group[tonumber(unit:match("^raid(%d+)$") or 0)]
        if who then
            return who[1], who[2]
        end
    end,
    UnitFullName = function(unit)
        local who = unit == "player" and { "Tester", "Stub" } or group[tonumber(unit:match("^raid(%d+)$") or 0)]
        if who then
            return who[1] .. " " .. who[2], nil
        end
    end,
    UnitClass = function()
        return "Rogue", "ROGUE", 4
    end,
    UnitGUID = function() end,
    UnitIsUnit = function()
        return false
    end,
    UnitIsConnected = function()
        return true
    end,
    UnitIsGroupLeader = function()
        return false
    end,
    UnitIsGroupAssistant = function()
        return false
    end,
    GetNumClasses = function()
        return 0
    end,
    GetClassInfo = function() end,
    GetNumGroupMembers = function()
        return #group
    end,
    GetNumSubgroupMembers = function()
        return 0
    end,
    GetNumLootItems = function()
        return 0
    end,
    GetInstanceInfo = function()
        if instance then
            return instance.name, instance.type, 0, "", instance.maxPlayers, 0, false, instance.id
        end
        return "Elwynn", "none", 0, "", 0, 0, false, 0
    end,
    IsInInstance = function()
        return instance ~= nil, instance and instance.type or "none"
    end,
    IsInGroup = function(category)
        return #group > 0 and category == nil -- a home group, not an instance one
    end,
    IsInRaid = function()
        return #group > 0
    end,
    IsInGuild = function()
        return guilded
    end,
    IsModifiedClick = function()
        return false
    end,
    IsMouseButtonDown = function()
        return false
    end,
    InCombatLockdown = function()
        return false
    end,
    GetCursorInfo = function() end,
    GetCursorPosition = function()
        return 0, 0
    end,
    GetMinimapShape = function()
        return "ROUND"
    end,
    GetInventoryItemLink = function() end,
    GetLootSlotInfo = function() end,
    GetLootSlotLink = function() end,
    GetLootSourceInfo = function() end,
    GetMasterLootCandidate = function() end,
    GiveMasterLoot = function() end,
    GetTradePlayerItemLink = function() end,
    RandomRoll = function() end,
    PlaySound = function() end,
    ClearCursor = function() end,
    ClickTradeButton = function() end,
    StaticPopup_Show = function() end,
    GameTooltip_Hide = function() end,
    ButtonFrameTemplate_HidePortrait = function() end,
    HandleModifiedItemClick = function() end,
    hooksecurefunc = function() end,
    geterrorhandler = function()
        return error
    end,
    canaccessvalue = function()
        return true
    end,
    TooltipDataProcessor = {
        AddTooltipPostCall = function(_, fn)
            tooltipCalls[#tooltipCalls + 1] = fn
        end,
    },
    C_Timer = {
        After = function(_, fn)
            timers[#timers + 1] = fn
        end,
        NewTimer = function(_, fn)
            timers[#timers + 1] = fn
            return { Cancel = function() end }
        end,
        NewTicker = function(_, fn)
            tickers[#tickers + 1] = fn
            return { Cancel = function() end }
        end,
    },
    C_AddOns = {
        GetAddOnMetadata = function()
            return "v9.9.9"
        end,
        IsAddOnLoaded = function()
            return false
        end,
    },
    C_ChatInfo = {
        RegisterAddonMessagePrefix = function()
            return true
        end,
        SendAddonMessage = function(prefix, msg, channel)
            sent[#sent + 1] = { prefix = prefix, msg = msg, channel = channel }
            return 0
        end,
        SendChatMessage = function() end,
        InChatMessagingLockdown = function()
            return false
        end,
    },
    C_Item = {
        GetItemInfo = function(s)
            return "Item " .. tostring(s), "|cff0070dd|H" .. tostring(s) .. "|h[Item]|h|r", 3, 60, 55
        end,
        GetItemInfoInstant = function()
            return 1, "Armor", "Cloth", "INVTYPE_CHEST", 134400, 4, 1
        end,
        GetItemIconByID = function()
            return 134400
        end,
        GetItemQualityByID = function()
            return 3
        end,
        GetItemStats = function()
            return {}
        end,
        GetItemStatDelta = function()
            return {}
        end,
        GetDetailedItemLevelInfo = function()
            return 60
        end,
        RequestLoadItemDataByID = function() end,
    },
    C_TooltipInfo = {
        GetHyperlink = function()
            return { lines = {} }
        end,
        GetBagItem = function() end,
    },
    C_Container = {
        GetContainerNumSlots = function()
            return 0
        end,
        GetContainerItemLink = function() end,
        GetContainerItemInfo = function() end,
    },
    C_ClassColor = {
        GetClassColor = function() end,
    },
    C_PartyInfo = {
        GetLootMethod = function()
            return 3
        end,
    },
    C_InstanceEncounter = {
        IsEncounterInProgress = function()
            return false
        end,
    },
    C_SpecializationInfo = {
        GetActiveSpecGroup = function()
            return 1
        end,
        GetCombatConfigIDForSpecGroup = function() end,
    },
    C_Traits = {},
}
setmetatable(_G, {
    __index = function(_, key)
        return G[key]
    end,
})

-- Every event handler goes through one frame's OnEvent in the addon; find
-- how files register (NS.On) once Core has loaded.
local NS = {}
-- A save from before the client stopped giving the realm name.
RaidLootControllerDB = { mySpec = { ["Tester Stub-Realm"] = "ROGUE.COMBAT" } }
local files = {}
for line in io.lines("RaidLootController.toc") do
    if line:find("%.lua%s*$") then
        files[#files + 1] = line:gsub("%s+$", "")
    end
end

local passed, failed = 0, 0
local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. label)
    end
end
local function try(label, fn, ...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    check(ok, label .. (ok and "" or ("\n" .. tostring(err))))
    return ok
end
local function runTimers()
    for _ = 1, 20 do -- timers may start timers
        local due = timers
        timers = {}
        if #due == 0 then
            break
        end
        for _, fn in ipairs(due) do
            fn()
        end
    end
    for _, fn in ipairs(tickers) do -- the send queues empty on a ticker
        fn()
    end
end

-- Fire a game event at every frame that registered it.
local function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] and f.scripts.OnEvent then
            f.scripts.OnEvent(f, event, ...)
        end
    end
end
-- Hover every row and button on screen: tooltips are code too.
local function hoverAll()
    for i = 1, #frames do
        local f = frames[i]
        if f.shown and f.scripts.OnEnter then
            f.scripts.OnEnter(f)
        end
    end
end

for _, file in ipairs(files) do
    try("loads: " .. file, function()
        assert(loadfile(file))("RaidLootController", NS)
    end)
end

try("logs in", function()
    fire("ADDON_LOADED", "RaidLootController")
    fire("PLAYER_LOGIN")
    fire("PLAYER_ENTERING_WORLD", true, false)
    runTimers()
end)
check(NS.DB ~= nil and NS.Me() == "Tester Stub-Realm", "saved data is set up and we know who we are")
check(NS.DB.realm == "Realm", "with no realm from the game, the saved one is used and kept")

local TABS = { "loot", "raid", "history", "stats", "catalog", "versions", "commands", "help" }
for _, tab in ipairs(TABS) do
    check(NS.UI.refresh[tab] ~= nil, "the " .. tab .. " tab has a redraw")
end
-- Click every list row on screen (rows carry a .sel highlight): selecting
-- is what fills the detail lists and their tooltips.
local function clickRows()
    for i = 1, #frames do
        local f = frames[i]
        if f.shown and rawget(f, "sel") and f.scripts.OnClick then
            f.scripts.OnClick(f)
        end
    end
end
local function drawAll(when)
    for _, tab in ipairs(TABS) do
        try("draws " .. tab .. " (" .. when .. ")", function()
            NS.ShowPage(tab)
            runTimers()
            clickRows()
            runTimers()
            hoverAll()
        end)
    end
end
drawAll("no raid")
-- The open tab, and only that one, carries the gold bar.
local marked = {}
for _, f in ipairs(frames) do
    local mark = rawget(f, "mark")
    if mark and mark.shown then
        marked[#marked + 1] = f.text
    end
end
check(#marked == 1 and marked[1] == "Help", "only the open tab is marked")
try("demo on", function()
    NS.Demo.Toggle()
    runTimers()
end)
check(NS.Demo.active, "the demo raid is on")
try("ADD and CANCEL keep the wins cache", function()
    local S, gen = NS.S(), NS.historyGen
    local key = tostring(S.seq + 1)
    NS.ApplyOps({ { "ADD", key, "item:16800", "" } })
    check(S.items[key] ~= nil and NS.historyGen == gen, "an ADD leaves the wins and stats caches alone")
    NS.ApplyOps({ { "CANCEL", key } })
    check(S.items[key].state == "cancelled" and NS.historyGen == gen, "a CANCEL leaves them alone too")
    NS.ApplyOps({ { "PHASE", S.phase == "live" and "ended" or "live" } })
    check(NS.historyGen == gen + 1, "a PHASE still renews them")
end)
drawAll("demo raid")
try("bug report", function()
    assert(#NS.BugReport() > 100)
end)
try("demo off", function()
    NS.Demo.Toggle()
    runTimers()
end)

-- ---- messages through the real receive path ----------------------------------
local Rules = NS.Rules
local printed = {}
NS.Print = function(fmt, ...)
    printed[#printed + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end
-- An addon message arriving on a chat channel from a player ("First Surname").
local function hear(op, channel, sender)
    fire("CHAT_MSG_ADDON", "RLCC", Rules.EncodeOp(op), channel, sender)
end
-- What we sent on a channel since the last call, as "KIND third-field" strings.
local function sentOn(channel)
    local out = {}
    for _, m in ipairs(sent) do
        if m.channel == channel then
            for _, op in ipairs(Rules.Decode(m.msg)) do
                out[#out + 1] = op[1] .. (op[3] and op[3] ~= "" and " " .. op[3] or "")
            end
        end
    end
    return table.concat(out, ",")
end
local function reset()
    runTimers()
    sent, printed = {}, {}
    now = now + 1000 -- past every answer and question gap
end

-- In a raid of two (us and Ann) in Molten Core.
group = { { "Tester", "Stub" }, { "Ann", "Stub" } }
instance = { name = "Molten Core", type = "raid", maxPlayers = 40, id = 409 }
try("joins a raid", function()
    fire("GROUP_ROSTER_UPDATE")
    runTimers()
end)
check(NS.roster["Ann Stub-Realm"] ~= nil, "the roster knows Ann")

-- Who has the addon: the version ping.
reset()
try("version ping", function()
    hear({ "CV", "v1.0.0", "?", "MAGE" }, "GUILD", "Guildie Stub")
    check(NS.versions["Guildie Stub-Realm"] == "v1.0.0", "a ping tells us the asker's version")
    check(NS.classHeard["Guildie Stub-Realm"] == "MAGE", "and their class, to colour their name")
    hear({ "CV", "v1.0.0", "", "WIZARD" }, "GUILD", "Guildie Stub")
    check(NS.classHeard["Guildie Stub-Realm"] == "MAGE", "a class that does not exist is ignored")
    hear({ "CQE", "v1.0.0", "PRIEST" }, "GUILD", "Other Stub")
    check(NS.classHeard["Other Stub-Realm"] == "PRIEST", "the login message carries the class too")
    check(sentOn("GUILD") == "", "the answer waits a moment")
    runTimers()
    check(sentOn("GUILD") == "CV" and sentOn("RAID") == "", "a guild ping is answered in the guild")
    check(Rules.Decode(sent[#sent].msg)[1][4] == "ROGUE", "our answer carries our class")
    reset()
    hear({ "CV", "v1.0.0", "?" }, "RAID", "Stranger Stub")
    runTimers()
    check(#sent == 0, "a group ping from outside the roster gets no answer")
    hear({ "CV", "v1.0.0", "?" }, "RAID", "Ann Stub")
    hear({ "CV", "v1.0.0", "?" }, "RAID", "Ann Stub")
    runTimers()
    check(sentOn("RAID") == "CV", "two pings from a raider get one answer")
    reset()
    hear({ "CV", "v1.0.0" }, "GUILD", "Guildie Stub")
    runTimers()
    check(#sent == 0, "a plain version is not answered")
    reset()
    check(NS.AskVersions(), "the timed ask goes out")
    runTimers()
    check(sentOn("RAID") == "CV ?" and sentOn("GUILD") == "", "and is group only")
    check(not NS.AskVersions(true), "asking again at once is refused")
    reset()
    check(NS.AskVersions(true), "a click asks")
    runTimers()
    check(sentOn("GUILD") == "CV ?" and sentOn("RAID") == "CV ?", "the guild as well as the group")
end)

-- Whisper link: only to raiders never heard from, never twice, never in the demo.
reset()
try("whisper link", function()
    group[3] = { "Bob", "Stub" }
    fire("GROUP_ROSTER_UPDATE")
    runTimers()
    local whispers = {}
    G.C_ChatInfo.SendChatMessage = function(_, kind, _, target)
        whispers[#whispers + 1] = kind .. " " .. tostring(target)
    end
    G.UnitIsGroupLeader = function(unit)
        return unit == "raid1"
    end
    G.StaticPopup_Show = function(which, _, _, fn)
        StaticPopupDialogs[which].OnAccept(nil, fn) -- the player clicks Yes
    end
    fire("GROUP_ROSTER_UPDATE")
    NS.ShowPage("versions")
    runTimers()
    local button
    for _, f in ipairs(frames) do
        if f.text == "Whisper link" then
            button = f
        end
    end
    button.scripts.OnClick(button)
    -- Ann answered the ping above, so only Bob has no addon.
    check(#whispers == 1 and whispers[1] == "WHISPER Bob Stub", "the link goes to the raider without the addon")
    button.scripts.OnClick(button)
    check(#whispers == 1 and NS.DB.whispered["Bob Stub-Realm"], "and not a second time")
    NS.DB.whispered["Bob Stub-Realm"] = nil
    NS.Demo.Toggle()
    button.scripts.OnClick(button)
    NS.Demo.Toggle()
    runTimers()
    check(#whispers == 1, "nobody is whispered from the demo raid")
    group[3] = nil
    fire("GROUP_ROSTER_UPDATE")
    runTimers()
end)

-- The catalogue: a kill, drop reports, who gets named, the wishlist line.
reset()
try("catalogue messages", function()
    fire("ENCOUNTER_END", 663, "Lucifron", 1, 40, 1)
    local inst = NS.DB.catalog[409]
    check(inst and inst.b[663].kills == 1 and inst.size == 40, "a kill is counted and the instance gets its size")
    NS.Wish()[16800] = true
    local cd = { "CD", 409, "Molten Core", 663, "Lucifron", "item:16800", "E663:1", 100 }
    hear(cd, "GUILD", "Ann Stub")
    hear(cd, "RAID", "Stranger Stub")
    check(inst.b[663].i[16800] == nil, "a drop report from the guild channel or a stranger is ignored")
    hear(cd, "RAID", "Ann Stub")
    local rec = inst.b[663].i[16800]
    check(
        rec and rec.n == 1 and rec.on == 0 and rec.by[1] == "Ann Stub-Realm",
        "a raider's report counts and names them"
    )
    check(#printed == 1 and printed[1]:find("wishlist", 1, true), "a wished item dropping prints one line")
    hear(cd, "RAID", "Ann Stub")
    check(#printed == 1, "the same kill does not print again")
    hear({ "CD", 409, "Molten Core", 663, "Lucifron", "item:16801", "E663:1", 100 }, "RAID", "Ann Stub")
    check(#printed == 1, "an item not wished for prints nothing")
    hear({ "CE", 409, 663, "item:16800", 1, 100 }, "GUILD", "Guildie Stub")
    check(rec.by[2] == "Guildie Stub-Realm", "a guild answer names its sender")
    -- Open the instance, pick the boss, then hover its items: the Seen by
    -- and Won by tooltip lines.
    NS.ShowPage("catalog")
    runTimers()
    clickRows()
    runTimers()
    for i = 1, #frames do
        local f = frames[i]
        local row = f.shown and rawget(f, "sel") and rawget(f, "data")
        if type(row) == "table" and row.bossKey then
            f.scripts.OnClick(f)
        end
    end
    runTimers()
    local items = 0
    for _, f in ipairs(frames) do
        local shownRec = f.shown and rawget(f, "sel") and rawget(f, "data")
        if type(shownRec) == "table" and shownRec.s then
            items = items + 1
            f.scripts.OnEnter(f)
        end
    end
    check(items == 2, "the boss's two items are listed and their tooltips draw")
    -- The game's own item tooltip gets the RaidLoot lines.
    local lines = {}
    G.GameTooltip.GetItem = function()
        return "Item", "|cff0070dd|Hitem:16800::::::::60|h[Item]|h|r"
    end
    G.GameTooltip.AddLine = function(_, text)
        lines[#lines + 1] = text
    end
    check(#tooltipCalls == 1, "the item tooltip hook is registered")
    tooltipCalls[1](G.GameTooltip)
    local all = table.concat(lines, "\n")
    check(
        all:find("On your wishlist", 1, true) and all:find("Drops from Lucifron", 1, true),
        "wishlist and drop lines on the item tooltip"
    )
end)
print(string.format("test_load: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
