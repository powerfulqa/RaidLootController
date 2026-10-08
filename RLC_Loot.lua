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

function Loot.Roll()
    RandomRoll(1, 100)
end

local rollPattern
NS.On("CHAT_MSG_SYSTEM", function(text)
    if not NS.IsHost() and not NS.debug then
        return
    end
    -- System lines can be secret on this client; reading one would throw.
    if canaccessvalue and not canaccessvalue(text) then
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

local function lootSlots()
    local out = {}
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local _, _, _, _, quality = GetLootSlotInfo(slot)
        local s = NS.ItemStringOf(link)
        if s and quality and quality >= NS.DB.minQuality then
            local source = GetLootSourceInfo(slot)
            out[#out + 1] = { slot = slot, itemString = s, key = tostring(source) .. ":" .. slot }
        end
    end
    return out
end

function Loot.PendingFromWindow()
    local n = 0
    for _, e in ipairs(lootSlots()) do
        if not added[e.key] then
            n = n + 1
        end
    end
    return n
end

function Loot.AddFromWindow()
    for _, e in ipairs(lootSlots()) do
        if not added[e.key] then
            added[e.key] = true
            NS.Act("ADD", e.itemString)
        end
    end
end

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
    if NS.Refresh then
        NS.Refresh()
    end
end)

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

-- Host only, from NS.ApplyOps on AWARD.
function Loot.Deliver(item)
    local winner = item.winner
    if winner == NS.Me() then
        return -- the host won it and already has it
    end
    if Loot.lootOpen then
        local slot = bestMatch(GetNumLootItems(), function(i)
            return NS.ItemStringOf(GetLootSlotLink(i))
        end, item.itemString)
        if slot then
            for i = 1, 40 do
                local name = GetMasterLootCandidate(slot, i)
                if name and NS.Canon(name) == winner then
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
    local owed = NS.DB.owed
    owed[winner] = owed[winner] or {}
    table.insert(owed[winner], item.itemString)
    NS.Print(
        "Trade %s to %s. It goes in the trade window when you trade them.",
        NS.LinkOf(item.itemString),
        NS.ColorName(winner)
    )
end

-- Owed items placed in the current trade window. They leave `owed` only
-- when the trade completes; a cancelled trade leaves them owed, and the
-- next TRADE_SHOW starts a fresh list.
local placed = {}

NS.On("TRADE_SHOW", function()
    wipe(placed)
    local who = NS.UnitIdentity("npc") -- the trade partner
    local list = who and NS.DB.owed[who]
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
    local tradeSlot = 1
    local used = {}
    for i, itemString in ipairs(list) do
        if tradeSlot > 6 then
            break
        end
        local at = bestMatch(#bagSlots, bagItem, itemString, used)
        if at then
            used[at] = true
            C_Container.PickupContainerItem(bagSlots[at].bag, bagSlots[at].slot)
            ClickTradeButton(tradeSlot)
            placed[#placed + 1] = { who = who, index = i, slot = tradeSlot, itemString = itemString }
            tradeSlot = tradeSlot + 1
        end
    end
    ClearCursor() -- never leave an item on the cursor if a placement failed
    if #placed > 0 then
        NS.Print("Put %d won item(s) for %s in the trade window. Check them, then trade.", #placed, NS.ColorName(who))
    end
end)

-- When either side accepts, check what is really in our trade slots. Only
-- items confirmed there leave the owed list when the trade completes.
NS.On("TRADE_ACCEPT_UPDATE", function()
    for _, p in ipairs(placed) do
        p.ok = sameItem(NS.ItemStringOf(GetTradePlayerItemLink(p.slot)), p.itemString) or false
    end
end)

NS.On("UI_INFO_MESSAGE", function(_, message)
    if message ~= ERR_TRADE_COMPLETE or #placed == 0 then
        return
    end
    for i = #placed, 1, -1 do
        if not placed[i].ok then
            table.remove(placed, i)
        end
    end
    -- Remove from the back so earlier indexes stay valid.
    table.sort(placed, function(a, b)
        return a.index > b.index
    end)
    for _, p in ipairs(placed) do
        table.remove(NS.DB.owed[p.who], p.index)
    end
    wipe(placed)
    if NS.Refresh then
        NS.Refresh()
    end
end)

-- ---- class restriction from the tooltip -------------------------------------

-- Mask of the classes named on the item's "Classes:" line, or 0.
function Loot.TooltipClassMask(itemString)
    local data = C_TooltipInfo.GetHyperlink(itemString)
    if not data or not data.lines then
        return 0
    end
    local pattern = Rules.FormatPattern(ITEM_CLASSES_ALLOWED)
    local byName = {}
    for id = 1, GetNumClasses() do
        local className = GetClassInfo(id)
        if className then
            byName[className] = id
        end
    end
    for _, line in ipairs(data.lines) do
        local text = line.leftText
        local list = type(text) == "string" and text:match(pattern)
        if list then
            local mask = 0
            for className in list:gmatch("[^,]+") do
                local id = byName[strtrim(className)]
                if id then
                    mask = mask + Rules.ClassBit(id)
                end
            end
            return mask
        end
    end
    return 0
end
