-- RLC_Core.lua
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

-- ---- chat output -----------------------------------------------------------

function NS.Print(fmt, ...)
    local text = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cffff8800RaidLoot|r " .. text)
end

-- ---- names -----------------------------------------------------------------
-- Everything inside the addon uses "Name-Realm". Chat shows same-realm
-- players without a realm, so a bare name gets ours.

local myRealm
function NS.Full(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if name:find("-", 1, true) then
        return name
    end
    myRealm = myRealm or GetNormalizedRealmName()
    return myRealm and (name .. "-" .. myRealm) or nil
end

function NS.Me()
    return NS.Full(UnitName("player"))
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
        local name, realm = UnitFullName(unit)
        if name then
            local full = (realm and realm ~= "") and (name .. "-" .. realm) or NS.Full(name)
            local _, classFile, classID = UnitClass(unit)
            if full then
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
function NS.ApplyOps(ops, broadcast)
    local S = NS.S()
    local changedHistory = false
    local rejected = 0
    for _, op in ipairs(ops) do
        local newS = Rules.Apply(S, op)
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
                if (item.awardedAt or 0) >= GetServerTime() - 120 then
                    NS.Print("%s won %s.", NS.ColorName(op[3]), NS.LinkOf(item.itemString))
                end
                if broadcast and NS.Loot then
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
    if NS.DB.announce and IsInGroup() and not C_ChatInfo.InChatMessagingLockdown() then
        C_ChatInfo.SendChatMessage(line, IsInRaid() and "RAID" or "PARTY")
    else
        NS.Print(line)
        NS.Net.Queue({ "NOTE", line })
    end
end

-- The host runs a request. `who` is the requester's full name.
function NS.HandleRequest(who, req)
    local S = NS.S()
    if not NS.IsHost() then
        return
    end
    if req[1] == "SYNC" then
        NS.Net.SendSnapshot()
        return
    end
    local ops, note = Rules.Intent(S, who, req, { classOf = NS.ClassOf, now = GetServerTime() })
    if not ops then
        if note and req[1] ~= "ROLLSEEN" then
            if who == NS.Me() then
                NS.Print(note)
            else
                NS.Net.Queue({ "ERR", who, note })
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
    if DB.announce == nil then
        DB.announce = true
    end
    DB.minQuality = tonumber(DB.minQuality) or 3
    if type(DB.session) ~= "table" or DB.session.v ~= 1 then
        DB.session = nil
    end
    NS.DB = DB
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
SlashCmdList.RAIDLOOTCONTROLLER = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then
        NS.Toggle()
    elseif cmd == "add" then
        local s = NS.ItemStringOf(rest)
        if s then
            NS.Act("ADD", s)
        else
            NS.Print("Usage: /rlc add <shift-click an item>")
        end
    elseif cmd == "reserve" then
        local id = tonumber(rest) or Rules.ItemIDOf(NS.ItemStringOf(rest) or "")
        if id then
            NS.Act("RES", id)
        else
            NS.Print("Usage: /rlc reserve <shift-click an item, or its item ID>")
        end
    elseif cmd == "sync" then
        NS.RequestSync(0)
        NS.Print("Asked the raid host for the current session.")
    elseif cmd == "owed" then
        wipe(NS.DB.owed)
        NS.Print("Cleared the list of items still to trade.")
        NS.Refresh()
    elseif cmd == "announce" then
        NS.DB.announce = not NS.DB.announce
        NS.Print("Raid chat announcements %s.", NS.DB.announce and "on" or "off")
    else
        NS.Print("/rlc - open the window")
        NS.Print("/rlc add <item> - put an item up for rolls (officers)")
        NS.Print("/rlc reserve <item or ID> - reserve an item before the raid starts")
        NS.Print("/rlc sync - fetch the session from the raid host")
        NS.Print("/rlc announce - turn raid chat announcements on or off (host)")
        NS.Print("/rlc owed - clear the list of items still to trade (host)")
    end
end

function RaidLootController_OnAddonCompartmentClick()
    NS.Toggle()
end
