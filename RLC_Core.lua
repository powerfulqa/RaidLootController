-- RLC_Core.lua
-- Raid Loot Controller by Serv - https://github.com/powerfulqa/RaidLootController
-- Source-available, see LICENSE.
--
-- Namespace, saved data, player names, the group roster, and the glue that
-- turns ops and requests into state changes. Loads after RLC_Rules.lua.
--
-- Who owns what:
--   * The HOST (the officer who started the raid session) holds the real
--     state. It runs every request through Rules.Intent, applies the
--     resulting ops, and broadcasts them.
--   * Everyone else applies the host's ops and sends requests ("?OP") to
--     the group. Only the host acts on a request.
local ADDON, NS = ...
local Rules = NS.Rules

NS.VERSION = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "dev"

local HISTORY_MAX = 200
local STALE = 12 * 3600 -- an unfinished raid this old ends at login

-- ---- chat output -----------------------------------------------------------

function NS.Print(fmt, ...)
    local text = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cffff8800RaidLoot|r " .. text)
end

-- ---- versions --------------------------------------------------------------
-- Other players' addon versions, heard on the catalogue "done asking"
-- message every client sends its guild at login and its group on joining.
-- One chat line per session when someone has a newer one.

NS.versions = {} -- name -> version, this session only
local toldNewer = false

-- The chat line carries a green [Click here] link that opens the download
-- address ready to copy (the game cannot open a browser). Registered with
-- LinkUtil, never by replacing SetItemRef: replacing it taints, measured by
-- the WoWClearance and BarWarden ports on Forever.
local DOWNLOAD_URL = "https://github.com/powerfulqa/RaidLootController/releases/latest/download/RaidLootController.zip"
local UPDATE_LINK = "|cff33ff33|Hrlcupdate:latest|h[Click here]|h|r"
if LinkUtil and LinkUtil.RegisterLinkHandler then
    -- Registering twice asserts, and a /reload keeps the old registration.
    if not (LinkUtil.IsLinkHandlerRegistered and LinkUtil.IsLinkHandlerRegistered("rlcupdate")) then
        LinkUtil.RegisterLinkHandler("rlcupdate", function()
            NS.ShowCopy("Download the latest version", DOWNLOAD_URL, 600, 130)
            return LinkProcessorResponse and LinkProcessorResponse.Handled or nil
        end)
    end
end

function NS.NoteVersion(name, v)
    if not Rules.ValidVersion(v) then
        return
    end
    NS.versions[name] = v
    if not toldNewer and Rules.VersionNewer(v, NS.VERSION) then
        toldNewer = true
        NS.Print("|cffffff00A newer version (%s) is out|r; you have %s. %s to get it.", v, NS.VERSION, UPDATE_LINK)
    end
end

-- What a bug report needs: version, client, where you are, the session and
-- the message queues. Names stay in (it is your own raid), nothing else
-- personal.
function NS.BugReport()
    local lines = {}
    local function add(fmt, ...)
        lines[#lines + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
    end
    local build, buildNum = GetBuildInfo()
    local S = NS.S()
    add("Raid Loot Controller bug report")
    add("Version %s, client %s (%s), %s, %s", NS.VERSION, build, buildNum, GetLocale(), date("%Y-%m-%d %H:%M"))
    add("Me: %s, %s, role: %s", tostring(NS.Me()), select(2, UnitClass("player")) or "?", NS.RoleName())
    local inInst, instType = IsInInstance()
    local method = C_PartyInfo.GetLootMethod and C_PartyInfo.GetLootMethod()
    for name, v in pairs(Enum.LootMethod or {}) do
        if v == method then
            method = name .. " (" .. v .. ")" -- the game's own name, e.g. Group (3)
        end
    end
    add(
        "Group: %s, %d players, instance: %s, loot method: %s",
        IsInRaid() and "raid" or IsInGroup() and "party" or "none",
        GetNumGroupMembers(),
        inInst and instType or "no",
        tostring(method)
    )
    add("Demo: %s, debug: %s", tostring(NS.Demo and NS.Demo.active or false), tostring(NS.debug or false))
    add("Net: %s", NS.Net.Status())
    add("Chat lockdown: %s", tostring(C_ChatInfo.InChatMessagingLockdown()))
    if S then
        local n, officers = 0, 0
        for _ in pairs(S.items) do
            n = n + 1
        end
        for _ in pairs(S.officers) do
            officers = officers + 1
        end
        add(
            "Session: %s, host %s, %s, %d items, active %s, %d officers, seq %d",
            S.id,
            S.host,
            S.phase,
            n,
            tostring(S.active),
            officers,
            S.seq
        )
    else
        add("Session: none")
    end
    local owed, hist = 0, 0
    for _, list in pairs(NS.DB.owed) do
        owed = owed + #list
    end
    for _ in pairs(NS.DB.history) do
        hist = hist + 1
    end
    add("Owed items: %d, raids in history: %d", owed, hist)
    local seen = {}
    for name, v in pairs(NS.versions) do
        seen[#seen + 1] = NS.Short(name) .. " " .. v
    end
    table.sort(seen)
    add("Versions heard: %s", #seen > 0 and table.concat(seen, ", ") or "none")
    add("")
    add("What happened, and what did you expect?")
    return table.concat(lines, "\n")
end

-- ---- names -----------------------------------------------------------------
-- Everything inside the addon names a player one way: "Display-Realm",
-- where Display is "First Surname" on a client with surnames.
--
-- Forever has character surnames, and the game does not spell a name the
-- same way everywhere: roll lines say "Serv Aszune", while UnitName returns
-- "Serv" plus the surname as its SECOND value (where retail returns the
-- realm). So every name read from the game goes through NS.Canon, which
-- maps any spelling of a group member (first name, first + surname, with
-- or without realm) to their one canonical name. Measured 2026-10-09: a
-- roll line "Serv Aszune rolls 2 (1-100)" did not match "Serv-Realm".

local myRealm
local function realm()
    if not myRealm then
        local r = (GetNormalizedRealmName() or ""):gsub("[%s%-]", "")
        myRealm = r ~= "" and r or nil -- empty before login: ask again later
    end
    return myRealm or ""
end

function NS.Full(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if name:find("-", 1, true) then
        return name
    end
    return realm() ~= "" and (name .. "-" .. realm()) or nil
end

local SEP = Constants
        and Constants.CharacterNameSeparatorConsts
        and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR
    or " "

-- Canonical name and first name of a unit, or nil.
local function unitIdentity(unit)
    local first, second = UnitName(unit)
    -- Unit names can be secret on this client: comparing one throws.
    if canaccessvalue and not (canaccessvalue(first) and canaccessvalue(second)) then
        return nil
    end
    if type(first) ~= "string" or first == "" then
        return nil
    end
    local _, unitRealm = UnitFullName(unit)
    if canaccessvalue and not canaccessvalue(unitRealm) then
        unitRealm = nil
    end
    local surnames = RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()
    local display = first
    if surnames and type(second) == "string" and second ~= "" and not first:find(SEP, 1, true) then
        display = first .. SEP .. second
    end
    unitRealm = (type(unitRealm) == "string" and unitRealm ~= "" and unitRealm ~= second) and unitRealm or realm()
    unitRealm = unitRealm:gsub("[%s%-]", "")
    return display .. "-" .. unitRealm, (display:match("^([^" .. SEP:gsub("%p", "%%%0") .. "]+)") or display)
end
NS.UnitIdentity = unitIdentity

-- lower-case spelling -> canonical name, for everyone in the group. A bare
-- first name maps only when no one else in the group shares it.
local aliases = {}

local function addAliases(canon, first)
    local display = canon:match("^(.+)%-[^%-]+$") or canon
    local r = canon:match("%-([^%-]+)$") or ""
    for _, a in ipairs({ canon, display, first, first .. "-" .. r }) do
        local k = a:lower()
        if aliases[k] == nil or aliases[k] == canon then
            aliases[k] = canon
        else
            aliases[k] = false -- two players share this spelling
        end
    end
end

-- Any spelling of a player's name -> the canonical name.
function NS.Canon(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local hit = aliases[name:lower()]
    if hit then
        return hit
    end
    -- "First Surname-Realm" where the realm part differs in spacing.
    local bare = name:match("^(.-)%-") or name
    hit = aliases[bare:lower()]
    if hit then
        return hit
    end
    return NS.Full(name)
end

local myName
function NS.Me()
    myName = myName or unitIdentity("player")
    return myName
end

function NS.Short(name)
    return name and (name:gsub("%-.*", "")) or "?"
end

-- ---- roster ------------------------------------------------------------------
-- name -> { unit, classID, classFile, lead, assist }. Rebuilt on
-- GROUP_ROSTER_UPDATE. Class files are also remembered in saved data so
-- history can colour names of players who have left.

local roster = {}
NS.roster = roster

function NS.RefreshRoster()
    wipe(roster)
    wipe(aliases)
    myName = nil
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            units[#units + 1] = "raid" .. i
        end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do
            units[#units + 1] = "party" .. i
        end
    end
    for _, unit in ipairs(units) do
        local full, first = unitIdentity(unit)
        if full then
            addAliases(full, first)
            local _, classFile, classID = UnitClass(unit)
            roster[full] = {
                unit = unit,
                classID = classID,
                classFile = classFile,
                lead = UnitIsGroupLeader(unit),
                assist = UnitIsGroupAssistant(unit),
            }
            if classFile and NS.DB then
                NS.DB.classes[full] = classFile
            end
        end
    end
    if NS.Demo and NS.Demo.active then
        NS.Demo.AddRoster(roster) -- fake raiders stay listed in demo mode
    end
end

function NS.ClassOf(name)
    local r = roster[name]
    return r and r.classID
end

-- Coloured short name.
function NS.ColorName(name)
    local file = (roster[name] and roster[name].classFile) or (NS.DB and NS.DB.classes[name])
    local color = file and C_ClassColor.GetClassColor(file)
    local short = NS.Short(name)
    return color and color:WrapTextInColorCode(short) or short
end

function NS.IsLeadOrAssist(name)
    local r = roster[name]
    return r and (r.lead or r.assist) or false
end

-- ---- items -----------------------------------------------------------------

function NS.ItemStringOf(link)
    return type(link) == "string" and link:match("|H(item:[%d:%-]+)|h") or nil
end

-- A display link for an itemString, or a placeholder while the client
-- fetches the item; GET_ITEM_INFO_RECEIVED refreshes the window.
function NS.LinkOf(itemString)
    local _, link = C_Item.GetItemInfo(itemString)
    if link then
        return link
    end
    local id = Rules.ItemIDOf(itemString)
    if id then
        C_Item.RequestLoadItemDataByID(id)
    end
    return "[item " .. tostring(id) .. "]"
end

function NS.IconOf(itemString)
    return C_Item.GetItemIconByID(Rules.ItemIDOf(itemString) or 0) or 134400
end

-- ---- state -------------------------------------------------------------------

function NS.S()
    return NS.DB and NS.DB.session
end

function NS.IsHost()
    local S = NS.S()
    return S ~= nil and S.host == NS.Me() and S.phase ~= "ended"
end

function NS.IsOfficer()
    local S = NS.S()
    return S ~= nil and Rules.IsOfficer(S, NS.Me())
end

local function saveHistory(S)
    local H = NS.DB.history
    H[S.id] = CopyTable(S)
    local ids = {}
    for id, rec in pairs(H) do
        ids[#ids + 1] = { id = id, t = rec.created or 0 }
    end
    if #ids > HISTORY_MAX then
        table.sort(ids, function(a, b)
            return a.t < b.t
        end)
        for i = 1, #ids - HISTORY_MAX do
            H[ids[i].id] = nil
        end
    end
end

-- Apply ops to our copy. The host also broadcasts them. Returns how many
-- ops did not fit our copy (a sign we missed some).
local handedOver = {} -- session id .. item key -> true, this session only
function NS.ApplyOps(ops, broadcast)
    local S = NS.S()
    local changedHistory = false
    local rejected = 0
    for _, op in ipairs(ops) do
        -- An UNDO takes the win back, so the old winner is no longer owed it.
        local undone = op[1] == "UNDO" and S and S.items[op[2]]
        undone = undone and undone.winner and { who = undone.winner, s = undone.itemString }
        local newS = Rules.Apply(S, op)
        local owedList = undone and newS and NS.DB.owed[undone.who]
        if owedList then
            for i, s in ipairs(owedList) do
                if s == undone.s then
                    table.remove(owedList, i)
                    break
                end
            end
        end
        if not newS then
            rejected = rejected + 1
        else
            S = newS
            NS.DB.session = S
            if broadcast then
                NS.Net.Queue(op)
            end
            local k = op[1]
            if k == "NEW" or k == "PHASE" or k == "AWARD" or k == "CANCEL" or k == "ADD" then
                changedHistory = true
            end
            if k == "AWARD" then
                local item = S.items[op[2]]
                -- Only fresh wins are news; a snapshot replays old ones.
                local fresh = (item.awardedAt or 0) >= GetServerTime() - 120
                if fresh then
                    NS.Print("%s won %s.", NS.ColorName(op[3]), NS.LinkOf(item.itemString))
                end
                -- The master looter's addon hands the item over (the host's
                -- when loot is not on Master Looter). Once per win: a
                -- resync replays recent wins.
                if fresh and NS.Loot and NS.Loot.IAmGiver() and not handedOver[S.id .. op[2]] then
                    handedOver[S.id .. op[2]] = true
                    NS.Loot.Deliver(item)
                end
            end
        end
    end
    if changedHistory and S then
        saveHistory(S)
    end
    if NS.Refresh then
        NS.Refresh()
    end
    -- A new or replayed session may not have our spec yet.
    if S and NS.Specs and not broadcast then
        NS.Specs.Report()
    end
    return rejected
end

-- Ask the host for the whole session. Throttled, and retried a few times
-- while we still have nothing, since the first ask can land in a loading
-- screen or before the host's roster knows us.
local lastSyncAsk = 0
function NS.RequestSync(tries)
    if not IsInGroup() or NS.IsHost() then
        return
    end
    local now = GetTime()
    if not tries and now - lastSyncAsk < 30 then
        return
    end
    lastSyncAsk = now
    NS.Net.Queue({ "?SYNC" })
    tries = (tries or 0) + 1
    if tries < 3 then
        C_Timer.After(15, function()
            if not NS.S() then
                NS.RequestSync(tries)
            end
        end)
    end
end

-- Show a line to the whole raid: in raid chat when the host has announcing
-- on (so players without the addon see it too), otherwise as a NOTE op that
-- only addon users print. Never both, or addon users read it twice.
function NS.Announce(text, itemString)
    local line = itemString and (NS.LinkOf(itemString) .. " - " .. text) or text
    local demo = NS.Demo and NS.Demo.active
    if NS.DB.announce and not demo and IsInGroup() and not C_ChatInfo.InChatMessagingLockdown() then
        C_ChatInfo.SendChatMessage(line, IsInRaid() and "RAID" or "PARTY")
    else
        NS.Print(line)
        NS.Net.Queue({ "NOTE", line })
    end
end

-- Players to roll first tonight (see Rules.DryFrom), from saved history.
function NS.DryLastRaid()
    local S = NS.S()
    return Rules.DryFrom(NS.DB.history, S and S.id)
end

local lastSyncFrom, lastErrTo = {}, {}

-- The host runs a request. `who` is the requester's full name.
function NS.HandleRequest(who, req)
    local S = NS.S()
    if not NS.IsHost() then
        return
    end
    if req[1] == "SYNC" then
        -- One resend per player per 30 s: a spammed sync would keep the
        -- host resending the whole raid ahead of live traffic.
        local now = GetTime()
        if who ~= NS.Me() and now - (lastSyncFrom[who] or -60) < 30 then
            return
        end
        lastSyncFrom[who] = now
        NS.Net.SendSnapshot()
        return
    end
    local ops, note = Rules.Intent(S, who, req, {
        classOf = NS.ClassOf,
        now = GetServerTime(),
        describe = NS.Specs.DescribeItem,
        dry = NS.DryLastRaid,
    })
    if not ops then
        -- A refused roll is told to the player who rolled, not the host. Only
        -- the host's own ROLLSEEN names someone else; from anyone else the
        -- reply goes back to the sender, so nobody can aim error spam.
        local to = (req[1] == "ROLLSEEN" and who == S.host) and req[2] or who
        if NS.debug and req[1] == "ROLLSEEN" then
            NS.Print("debug: roll from %s refused: %s", tostring(req[2]), tostring(note))
        end
        if note and to then
            if to == NS.Me() then
                NS.Print(note)
            elseif GetTime() - (lastErrTo[to] or -60) >= 5 then
                -- At most one error line per player per 5 s: a spammed
                -- /roll must not flood the raid's addon channel.
                lastErrTo[to] = GetTime()
                NS.Net.Queue({ "ERR", to, note })
            end
        end
        return
    end
    NS.ApplyOps(ops, true)
    if note then
        local item = req[2] and S.items[req[2]]
        NS.Announce(note, item and item.itemString)
    end
end

-- Every button and slash command goes through here.
function NS.Act(...)
    local req = { ... }
    if not NS.S() then
        NS.Print("No raid session. An officer starts one from the Raid tab.")
        return
    end
    if NS.IsHost() then
        NS.HandleRequest(NS.Me(), req)
    else
        req[1] = "?" .. req[1]
        NS.Net.Queue(req)
    end
end

-- Start a new raid session with us as host.
function NS.NewSession(title)
    if IsInGroup() and not UnitIsGroupLeader("player") and not UnitIsGroupAssistant("player") then
        NS.Print("Only the raid leader or an assistant can start a raid session.")
        return
    end
    local me = NS.Me()
    local t = GetServerTime()
    NS.ApplyOps({ { "NEW", me .. "-" .. t, me, title ~= "" and title or (GetInstanceInfo() or "Raid"), t } }, true)
    NS.Announce("New raid session. Open /rlc to reserve an item before the raid starts.")
    NS.Specs.Report(true)
end

-- ---- events ------------------------------------------------------------------

local frame = CreateFrame("Frame")
local handlers = {}

function NS.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    frame:RegisterEvent(event)
end

frame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event]) do
        fn(...)
    end
end)

NS.On("ADDON_LOADED", function(name)
    if name ~= ADDON then
        return
    end
    RaidLootControllerDB = type(RaidLootControllerDB) == "table" and RaidLootControllerDB or {}
    local DB = RaidLootControllerDB
    DB.history = type(DB.history) == "table" and DB.history or {}
    DB.classes = type(DB.classes) == "table" and DB.classes or {}
    DB.owed = type(DB.owed) == "table" and DB.owed or {}
    DB.catalog = type(DB.catalog) == "table" and DB.catalog or {}
    DB.mySpec = type(DB.mySpec) == "table" and DB.mySpec or {} -- "Name-Realm" -> spec picked by hand
    if DB.announce == nil then
        DB.announce = true
    end
    DB.minQuality = tonumber(DB.minQuality) or 3
    if type(DB.session) ~= "table" or DB.session.v ~= 1 then
        DB.session = nil
    elseif type(DB.session.specs) ~= "table" then
        DB.session.specs = {} -- saved before specs existed
    end
    NS.DB = DB
    -- A raid left open (the host logged off, or a test session) ends on its
    -- own once it is STALE seconds old, so the next day never opens "in
    -- progress". It stays in History like any ended raid.
    local S = DB.session
    if S and S.phase ~= "ended" and GetServerTime() - (tonumber(S.created) or 0) > STALE then
        S.phase, S.ended, S.active = "ended", GetServerTime(), nil
        saveHistory(S)
    end
end)

local wasInGroup = false
local function onRoster()
    NS.RefreshRoster()
    local inGroup = IsInGroup()
    -- Joined a group (or logged in inside one): ask whoever hosts to send
    -- the session. The host answers; nobody else does.
    if inGroup and not wasInGroup and not NS.IsHost() then
        C_Timer.After(3, function()
            NS.RequestSync(0)
        end)
    end
    wasInGroup = inGroup
    if NS.Refresh then
        NS.Refresh()
    end
end
NS.On("PLAYER_ENTERING_WORLD", onRoster)
NS.On("GROUP_ROSTER_UPDATE", onRoster)
NS.On("GET_ITEM_INFO_RECEIVED", function()
    if NS.Refresh then
        NS.Refresh()
    end
end)

-- ---- slash -------------------------------------------------------------------

SLASH_RAIDLOOTCONTROLLER1 = "/rlc"
SLASH_RAIDLOOTCONTROLLER2 = "/raidloot"
-- Your role in the current raid, for the Commands tab and /rlc help.
function NS.RoleName()
    if NS.IsHost() then
        return "Raid host"
    elseif NS.IsOfficer() then
        return "Officer"
    end
    return "Raider"
end

-- Every /rlc command, in the order the Commands tab lists them. One table
-- drives the slash handler, /rlc help and the tab's Run buttons.
--   args: the command needs more typed (the tab opens chat prefilled)
--   state(): true/false for a toggle, shown as on/off
--   when(S): shown only when it can do something for you right now. The
--   host still re-checks every request, so this only tidies the list.
NS.Commands = {
    {
        section = "Everyone",
        cmd = "reserve",
        args = "<item or ID>",
        text = "Reserve an item before the raid starts",
        when = function(S)
            return S ~= nil and S.phase == "reserve"
        end,
        fn = function(rest)
            local id = tonumber(rest) or Rules.ItemIDOf(NS.ItemStringOf(rest) or "")
            if id then
                NS.Act("RES", id)
            else
                NS.Print("Usage: /rlc reserve <shift-click an item, or its item ID>")
            end
        end,
    },
    {
        section = "Everyone",
        cmd = "sync",
        text = "Fetch the raid from the raid host",
        when = function()
            return IsInGroup() and not NS.IsHost()
        end,
        fn = function()
            NS.RequestSync(0)
            NS.Print("Asked the raid host for the current session.")
        end,
    },
    {
        section = "Everyone",
        cmd = "tooltip",
        text = "Show or hide the RaidLoot lines on item tooltips",
        state = function()
            return NS.DB.tooltip ~= false
        end,
        fn = function()
            NS.DB.tooltip = NS.DB.tooltip == false
            NS.Print("RaidLoot lines on item tooltips %s.", NS.DB.tooltip and "on" or "off")
        end,
    },
    {
        section = "Everyone",
        cmd = "minimap",
        text = "Hide or show the minimap button",
        state = function()
            return NS.DB.minimapButton ~= false
        end,
        fn = function()
            NS.SetMinimapButton(NS.DB.minimapButton == false)
            NS.Print("Minimap button %s.", NS.DB.minimapButton == false and "hidden" or "shown")
        end,
    },
    {
        section = "Everyone",
        cmd = "demo",
        text = "Look around a made-up raid (nothing is sent or saved)",
        state = function()
            return NS.Demo ~= nil and NS.Demo.active == true
        end,
        fn = function()
            NS.Demo.Toggle()
        end,
    },
    {
        section = "Officers",
        cmd = "add",
        args = "<item>",
        text = "Put an item up for rolls",
        when = function(S)
            return S ~= nil and S.phase ~= "ended" and NS.IsOfficer()
        end,
        fn = function(rest)
            local s = NS.ItemStringOf(rest)
            if s then
                NS.Act("ADD", s)
            else
                NS.Print("Usage: /rlc add <shift-click an item>")
            end
        end,
    },
    {
        section = "Raid host",
        cmd = "announce",
        text = "Raid chat announcements on or off",
        state = function()
            return NS.DB.announce == true
        end,
        when = function()
            return NS.IsHost()
        end,
        fn = function()
            NS.DB.announce = not NS.DB.announce
            NS.Print("Raid chat announcements %s.", NS.DB.announce and "on" or "off")
            NS.Refresh()
        end,
    },
    {
        section = "Raid host",
        cmd = "owed",
        text = "Clear the list of items still to trade",
        when = function()
            return next(NS.DB.owed) ~= nil
        end,
        fn = function()
            wipe(NS.DB.owed)
            NS.Print("Cleared the list of items still to trade.")
            NS.Refresh()
        end,
    },
    {
        section = "Troubleshooting",
        cmd = "report",
        text = "Make a bug report to copy and paste",
        fn = function()
            NS.ShowCopy("Bug report", NS.BugReport())
        end,
    },
    {
        section = "Troubleshooting",
        cmd = "debug",
        text = "Debug output in chat on or off",
        state = function()
            return NS.debug == true
        end,
        fn = function()
            NS.debug = not NS.debug or nil
            NS.Print("Debug output %s.", NS.debug and "on" or "off")
        end,
    },
}

function NS.CommandAvailable(c)
    return c.when == nil or c.when(NS.S()) == true
end

SlashCmdList.RAIDLOOTCONTROLLER = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then
        NS.Toggle()
        return
    end
    -- Typed commands always run: the host decides what a request may do.
    for _, c in ipairs(NS.Commands) do
        if c.cmd == cmd then
            c.fn(rest)
            return
        end
    end
    NS.Print("/rlc - open the window (you are: %s)", NS.RoleName())
    for _, c in ipairs(NS.Commands) do
        if NS.CommandAvailable(c) then
            NS.Print("/rlc %s%s - %s", c.cmd, c.args and (" " .. c.args) or "", c.text)
        end
    end
    NS.Print("The Commands tab has a Run button for each.")
end

function RaidLootController_OnAddonCompartmentClick()
    NS.Toggle()
end

-- Key binding (Bindings.xml): Options > Keybindings > AddOns.
BINDING_HEADER_RAIDLOOTCONTROLLER = "Raid Loot Controller"
BINDING_NAME_RAIDLOOTCONTROLLER_TOGGLE = "Open or close the window"
function RaidLootController_Toggle()
    NS.Toggle()
end
