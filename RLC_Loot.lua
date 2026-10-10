-- RLC_Loot.lua
-- Where items come from and how they reach the winner.
--
--   * Rolls: the Roll button calls the game's own /roll. The server picks
--     the number and prints it to the group, so nobody can fake one. The
--     HOST reads those lines here and turns each into a ROLLSEEN request;
--     Rules decides whether it counts.
--   * In: an officer adds items from an open loot window (master loot), by
--     dropping an item from their bags on the window, or with /rlc add.
--   * Out: on an award the host gives the item by master loot when the
--     loot window holds it; otherwise the winner is owed the item and it is
--     put into the trade window the next time the host trades them.
local _, NS = ...
local Rules = NS.Rules

local Loot = {}
NS.Loot = Loot

-- ---- rolls -----------------------------------------------------------------

-- Inventory slots an item would replace, by equip location. Two slots for
-- rings, trinkets and one-hand weapons: both are sent.
-- ponytail: ranged/relic assume slot 18 (Classic layout); Forever unmeasured.
local SLOTS = {
    INVTYPE_HEAD = { 1 },
    INVTYPE_NECK = { 2 },
    INVTYPE_SHOULDER = { 3 },
    INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 },
    INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 },
    INVTYPE_WRIST = { 9 },
    INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_2HWEAPON = { 16, 17 }, -- replaces the off hand too
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_SHIELD = { 17 },
    INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 },
    INVTYPE_RANGEDRIGHT = { 18 },
    INVTYPE_THROWN = { 18 },
    INVTYPE_RELIC = { 18 },
}

-- What this player wears where itemString would go, as the WANT request's
-- worn field ("item:1,item:2"), or nil. Officers see it to judge how big
-- an upgrade is; it is advice, never a rule.
function Loot.WornFor(itemString)
    local equipLoc = select(4, C_Item.GetItemInfoInstant(itemString))
    local parts = {}
    for _, slot in ipairs(SLOTS[equipLoc] or {}) do
        parts[#parts + 1] = NS.ItemStringOf(GetInventoryItemLink("player", slot))
    end
    local worn = table.concat(parts, ",")
    if #worn > NS.Rules.MAX_WORN then
        worn = parts[1] or "" -- two long itemStrings: the first slot is enough
    end
    return worn ~= "" and worn or nil
end

local rollPattern
NS.On("CHAT_MSG_SYSTEM", function(text)
    if not NS.IsHost() and not NS.debug then
        return
    end
    -- System lines can be secret on this client; reading one would throw.
    if not NS.CanRead(text) then
        if NS.debug then
            NS.Print("debug: a system chat line is hidden from addons, so rolls can't be read")
        end
        return
    end
    rollPattern = rollPattern or Rules.FormatPattern(RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)")
    local name, roll, low, high = Rules.ParseRoll(text, rollPattern)
    if NS.debug and (name or text:find("%(%d+%-%d+%)")) then
        NS.Print("debug: %q -> %s", text, name and (name .. " rolled " .. roll) or ("no match for " .. rollPattern))
    end
    if name and NS.IsHost() then
        NS.HandleRequest(NS.Me(), { "ROLLSEEN", NS.Canon(name), roll, low, high })
    end
end)

-- ---- items in ----------------------------------------------------------------

-- Loot-window items at or above the quality setting that this window has
-- not already sent to the session. Keyed by loot source + slot, so a
-- second copy of the same item on the same boss still counts.
local added = {}

-- The open loot window's items at or above the quality setting:
-- { slot, itemString, source (corpse GUID), key }. The catalogue reads it too.
function Loot.LootSlots()
    local out = {}
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local _, _, _, _, quality = GetLootSlotInfo(slot)
        local s = NS.ItemStringOf(link)
        if s and quality and quality >= NS.DB.minQuality then
            local source = GetLootSourceInfo(slot)
            out[#out + 1] = { slot = slot, itemString = s, source = source, key = tostring(source) .. ":" .. slot }
        end
    end
    return out
end

function Loot.PendingFromWindow()
    local n = 0
    for _, e in ipairs(Loot.LootSlots()) do
        if not added[e.key] then
            n = n + 1
        end
    end
    return n
end

function Loot.AddFromWindow()
    for _, e in ipairs(Loot.LootSlots()) do
        if not added[e.key] then
            added[e.key] = true
            NS.Act("ADD", e.itemString, e.key)
        end
    end
end

-- An item picked up from the bags and dropped on the window.
function Loot.AddFromCursor()
    local kind, _, link = GetCursorInfo()
    if kind == "item" then
        local s = NS.ItemStringOf(link)
        ClearCursor()
        if s then
            NS.Act("ADD", s)
        end
    end
end

-- ---- items out ---------------------------------------------------------------

local function sameItem(a, b)
    return a and b and Rules.ItemIDOf(a) == Rules.ItemIDOf(b)
end

-- Two passes: the exact itemString first (right item level and bonuses),
-- then the same item ID, for when the client re-encodes the string.
-- `get(i)` returns the itemString at position i of 1..n.
local function bestMatch(n, get, itemString, skip)
    for pass = 1, 2 do
        for i = 1, n do
            if not (skip and skip[i]) then
                local s = get(i)
                if s and (s == itemString or (pass == 2 and sameItem(s, itemString))) then
                    return i
                end
            end
        end
    end
end

-- Whether this client hands won items over: the master looter when loot
-- is on Master Looter (only they can give from the loot window, and the
-- drops are in their bags otherwise), else the raid host.
function Loot.IAmGiver()
    local method, partyID, raidID = C_PartyInfo.GetLootMethod()
    if method == Enum.LootMethod.Masterlooter then
        local unit = raidID and ("raid" .. raidID) or partyID == 0 and "player" or partyID and ("party" .. partyID)
        return unit ~= nil and UnitIsUnit(unit, "player")
    end
    return NS.IsHost()
end

-- Put a win on the owed list: it goes in the trade window next time.
local function owe(winner, itemString)
    local owed = NS.DB.owed
    owed[winner] = owed[winner] or {}
    table.insert(owed[winner], itemString)
    Loot.OwedChanged()
    NS.Print(
        "Trade %s to %s. It goes in the trade window when you trade them.",
        NS.LinkOf(itemString),
        NS.ColorName(winner)
    )
end

-- Master loot given and not yet confirmed: loot slot -> { winner, itemString }.
-- A give can fail (full bags, unique item, out of range), so the win only
-- counts as delivered once the slot empties. A failure, or the window
-- closing first, puts it on the owed list instead.
local giving, lastGive = {}, nil

function Loot.Deliver(item)
    local winner = item.winner
    -- ponytail: master loot is unmeasured on Forever (checklist 3); without
    -- the API the item falls through to the owed list and a trade.
    if Loot.lootOpen and GetMasterLootCandidate and GiveMasterLoot then
        local slot = bestMatch(GetNumLootItems(), function(i)
            return NS.ItemStringOf(GetLootSlotLink(i))
        end, item.itemString)
        if slot then
            for i = 1, 40 do
                local name = GetMasterLootCandidate(slot, i)
                if name and NS.Canon(name) == winner then
                    giving[slot], lastGive = { winner = winner, itemString = item.itemString }, slot
                    GiveMasterLoot(slot, i)
                    return
                end
            end
            NS.Print(
                "%s can't receive master loot (out of range?). Loot the item yourself and trade it.",
                NS.ColorName(winner)
            )
        end
    end
    if winner == NS.Me() then
        Loot.MarkDelivered(winner, item.itemString)
        return -- the giver won it: it is theirs to loot or already in their bags
    end
    owe(winner, item.itemString)
end

NS.On("LOOT_SLOT_CLEARED", function(slot)
    local g = giving[slot]
    if g then
        giving[slot] = nil
        Loot.MarkDelivered(g.winner, g.itemString)
    end
end)

-- The master loot refusals. They do not name the slot: the last give failed.
NS.On("UI_ERROR_MESSAGE", function(_, message)
    local g = lastGive and giving[lastGive]
    if not g or not NS.CanRead(message) then
        return
    end
    if
        message == ERR_LOOT_MASTER_INV_FULL
        or message == ERR_LOOT_MASTER_UNIQUE_ITEM
        or message == ERR_LOOT_MASTER_OTHER
    then
        giving[lastGive] = nil
        NS.Print("Master loot to %s failed: %s", NS.ColorName(g.winner), message)
        owe(g.winner, g.itemString)
    end
end)

Loot.lootOpen = false
NS.On("LOOT_OPENED", function()
    Loot.lootOpen = true
    if NS.IsOfficer() and Loot.PendingFromWindow() > 0 then
        NS.Show()
    end
    if NS.Refresh then
        NS.Refresh()
    end
end)
NS.On("LOOT_CLOSED", function()
    Loot.lootOpen = false
    for slot, g in pairs(giving) do
        giving[slot] = nil
        owe(g.winner, g.itemString)
    end
    lastGive = nil
    if NS.Refresh then
        NS.Refresh()
    end
end)

-- Mark the win of `itemString` by `winner` delivered, if this raid has one
-- not marked yet. Only the host and officers can (the host checks it).
-- Deferred a frame: it is called from inside NS.ApplyOps.
function Loot.MarkDelivered(winner, itemString)
    C_Timer.After(0, function()
        local S = NS.S()
        if not (S and NS.IsOfficer()) then
            return
        end
        for _, key in ipairs(S.order) do
            local it = S.items[key]
            if
                it.state == "done"
                and it.winner == winner
                and not it.delivered
                and sameItem(it.itemString, itemString)
            then
                NS.Act("DELIV", key)
                return
            end
        end
    end)
end

-- The trade in progress: who with, and what was in our slots when either
-- side last accepted. Whatever we hand over in a completed trade comes off
-- the owed list, however it got into the window.
local tradeWho, given = nil, {}

NS.On("TRADE_SHOW", function()
    wipe(given)
    local who = NS.UnitIdentity("npc") -- the trade partner
    tradeWho = who
    if not who then
        if next(NS.DB.owed) then
            NS.Print("Can't read who you are trading with, so won items were not put in. Add them by hand.")
        end
        return
    end
    local list = NS.DB.owed[who]
    if not list or #list == 0 then
        return
    end
    -- Flatten the bags once so bestMatch can scan them by index.
    local bagSlots = {}
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            bagSlots[#bagSlots + 1] = { bag = bag, slot = slot }
        end
    end
    local function bagItem(i)
        local b = bagSlots[i]
        return NS.ItemStringOf(C_Container.GetContainerItemLink(b.bag, b.slot))
    end
    local picks, used = {}, {}
    for _, itemString in ipairs(list) do
        local at = #picks < 6 and bestMatch(#bagSlots, bagItem, itemString, used)
        if at then
            used[at] = true
            picks[#picks + 1] = bagSlots[at]
        end
    end
    -- One item per 0.1 s, as RCLootCouncil and Gargul do: placing them all
    -- at once can fail. Stop if the trade closed or changed partner.
    for k, b in ipairs(picks) do
        C_Timer.After(0.1 * k, function()
            if tradeWho ~= who or not TradeFrame:IsShown() then
                return
            end
            C_Container.PickupContainerItem(b.bag, b.slot)
            ClickTradeButton(k)
            ClearCursor() -- a failed placement must not ride into the next pickup
        end)
    end
    if #picks > 0 then
        NS.Print(
            "Putting %d won item(s) for %s in the trade window. Check them, then trade.",
            #picks,
            NS.ColorName(who)
        )
    end
end)

-- Accepting locks the window (any change un-accepts), so what is in our
-- slots now is what the trade gives.
NS.On("TRADE_ACCEPT_UPDATE", function()
    wipe(given)
    for slot = 1, 6 do
        given[#given + 1] = NS.ItemStringOf(GetTradePlayerItemLink(slot))
    end
end)

NS.On("UI_INFO_MESSAGE", function(_, message)
    if not tradeWho or #given == 0 or not NS.CanRead(message) or message ~= ERR_TRADE_COMPLETE then
        return
    end
    local list = NS.DB.owed[tradeWho] -- nil if nothing owed, or "/rlc owed" cleared it
    for _, s in ipairs(given) do
        for i = #(list or {}), 1, -1 do
            if sameItem(list[i], s) then
                table.remove(list, i)
                break
            end
        end
        Loot.MarkDelivered(tradeWho, s)
    end
    if list and #list == 0 then
        NS.DB.owed[tradeWho] = nil
    end
    tradeWho = nil
    wipe(given)
    Loot.OwedChanged()
end)

-- How long a bag copy of itemString can still be traded, as the game
-- words it ("1 hour 47 min"), or nil (not in the bags, or no time limit).
-- Each answer is kept 30 s or until the bags change: the Raid tab asks on
-- every redraw, and finding it means scanning every bag slot and building
-- a tooltip. The game shows only minutes anyway.
local tradeTimePattern
local tradeLeft, tradeLeftAt = {}, -100 -- itemID -> text or false
NS.On("BAG_UPDATE_DELAYED", function()
    tradeLeftAt = -100
end)
function Loot.TradeTimeLeft(itemString)
    if not BIND_TRADE_TIME_REMAINING then
        return nil
    end
    tradeTimePattern = tradeTimePattern or Rules.FormatPattern(BIND_TRADE_TIME_REMAINING)
    if GetTime() - tradeLeftAt > 30 then
        wipe(tradeLeft)
        tradeLeftAt = GetTime()
    end
    local id = Rules.ItemIDOf(itemString)
    if not id or tradeLeft[id] ~= nil then
        return id and tradeLeft[id] or nil
    end
    tradeLeft[id] = false
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            if C_Container.GetContainerItemID(bag, slot) == id then
                local data = C_TooltipInfo.GetBagItem(bag, slot)
                for _, line in ipairs(data and data.lines or {}) do
                    local left = type(line.leftText) == "string" and line.leftText:match(tradeTimePattern)
                    if left then
                        tradeLeft[id] = left
                        return left
                    end
                end
            end
        end
    end
end

-- ---- class restriction from the tooltip -------------------------------------

local classPattern, classByName

-- Mask of the classes named on the item's "Classes:" line, or 0. `data` is
-- the item's tooltip data when the caller already has it.
function Loot.TooltipClassMask(itemString, data)
    data = data or C_TooltipInfo.GetHyperlink(itemString)
    if not data or not data.lines then
        return 0
    end
    if not classByName then
        classPattern, classByName = Rules.FormatPattern(ITEM_CLASSES_ALLOWED), {}
        for id = 1, GetNumClasses() do
            local className = GetClassInfo(id)
            if className then
                classByName[className] = id
            end
        end
    end
    for _, line in ipairs(data.lines) do
        local text = line.leftText
        local list = type(text) == "string" and text:match(classPattern)
        if list then
            local mask = 0
            for className in list:gmatch("[^,]+") do
                local id = classByName[strtrim(className)]
                if id then
                    mask = mask + Rules.ClassBit(id)
                end
            end
            return mask
        end
    end
    return 0
end

-- ---- tooltip lines and bag marks --------------------------------------------
-- Any item tooltip (bags, chat links, the Loot tab) says what the addon
-- knows about the item: who reserved it tonight, who the host still owes
-- it to, where it drops, and when you last won one. Items the host owes
-- someone are also marked in the bags, ready for the trade.

-- itemID -> list of short names the host still owes it to. Built on first
-- use after Loot.OwedChanged, not on every tooltip update or bag repaint.
local owedCache
local function owedMap()
    if not owedCache then
        owedCache = {}
        for name, list in pairs(NS.DB.owed) do
            for _, s in ipairs(list) do
                local id = Rules.ItemIDOf(s)
                if id then
                    owedCache[id] = owedCache[id] or {}
                    table.insert(owedCache[id], NS.Short(name))
                end
            end
        end
    end
    return owedCache
end

-- itemID -> when I last won one, from saved history; rebuilt when the
-- history changes (NS.historyGen).
local myWins, myWinsGen
local function lastWon(id)
    if myWinsGen ~= NS.historyGen then
        myWins, myWinsGen = {}, NS.historyGen
        local me = NS.Me()
        for _, rec in pairs(NS.DB.history) do
            for _, it in pairs(rec.items or {}) do
                local iid = it.winner == me and it.state == "done" and Rules.ItemIDOf(it.itemString or "")
                if iid then
                    myWins[iid] = math.max(myWins[iid] or 0, rec.created or 0)
                end
            end
        end
    end
    return myWins[id]
end

local function annotate(tooltip)
    if not NS.DB or NS.DB.tooltip == false or (tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip) then
        return
    end
    local _, link = tooltip:GetItem()
    if not NS.CanRead(link) then
        return
    end
    local id = link and Rules.ItemIDOf(NS.ItemStringOf(link) or "")
    if not id then
        return
    end
    local lines = {}
    local S = NS.S()
    if S then
        local set, n = Rules.Reservers(S, id)
        if n > 0 then
            local names = {}
            for name in pairs(set) do
                names[#names + 1] = NS.Short(name)
            end
            table.sort(names)
            lines[#lines + 1] = "Reserved by " .. table.concat(names, ", ")
        end
    end
    local owed = owedMap()[id]
    if owed then
        lines[#lines + 1] = "|cff00ff00Trade to " .. table.concat(owed, ", ") .. "|r"
    end
    local hits = NS.Catalog.Find(NS.DB.catalog, id)
    if hits then
        local h = hits[1]
        for i = 2, #hits do
            if hits[i].rec.n > h.rec.n then
                h = hits[i]
            end
        end
        lines[#lines + 1] = string.format(
            "Drops from %s (%d of %d kills)%s",
            h.boss.name,
            h.rec.n,
            math.max(h.boss.kills, h.rec.n),
            #hits > 1 and string.format(" and %d more", #hits - 1) or ""
        )
    end
    local last = lastWon(id)
    if last then
        lines[#lines + 1] = "You won this on " .. date("%d %b %Y", last)
    end
    for i, text in ipairs(lines) do
        tooltip:AddLine((i == 1 and "|cffff8800RaidLoot:|r " or "    ") .. text, 1, 1, 1)
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, annotate)
end

-- Bag marks. Forever's bags are Mainline container frames: hook each
-- frame's UpdateItems (ContainerFrame_Update does not exist here; measured
-- by WoWClearance 2026-09-19). GetSlotAndBagID returns slot first.
local function paintFrame(frame)
    if not (NS.DB and frame and frame.EnumerateItems) then
        return
    end
    local owed = owedMap()
    if not next(owed) and not frame.rlcMarked then
        return -- nothing owed and nothing to clear: the usual case
    end
    local any = false
    for _, button in frame:EnumerateItems() do
        local slot, bag -- not "x and f()": that keeps only f's first return
        if button.GetSlotAndBagID then
            slot, bag = button:GetSlotAndBagID()
        end
        local id = bag and slot and C_Container.GetContainerItemID(bag, slot)
        local on = id ~= nil and owed[id] ~= nil
        if on and not button.rlcOwed then
            local t = button:CreateTexture(nil, "OVERLAY")
            t:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            t:SetBlendMode("ADD")
            t:SetVertexColor(0.2, 1, 0.2)
            t:SetAllPoints()
            button.rlcOwed = t
        end
        if button.rlcOwed then
            button.rlcOwed:SetShown(on)
        end
        any = any or on
    end
    frame.rlcMarked = any
end

local function containerFrames()
    local frames = { _G.ContainerFrameCombinedBags }
    for i = 1, _G.NUM_CONTAINER_FRAMES or 13 do
        frames[#frames + 1] = _G["ContainerFrame" .. i]
    end
    return frames
end

NS.On("PLAYER_LOGIN", function()
    for _, frame in ipairs(containerFrames()) do
        if frame.UpdateItems then
            hooksecurefunc(frame, "UpdateItems", paintFrame)
        end
    end
end)

-- Call after any change to NS.DB.owed: rebuilds the lookup, repaints open
-- bags and redraws the window.
function Loot.OwedChanged()
    owedCache = nil
    for _, frame in ipairs(containerFrames()) do
        if frame:IsShown() then
            paintFrame(frame)
        end
    end
    if NS.Refresh then
        NS.Refresh()
    end
end
