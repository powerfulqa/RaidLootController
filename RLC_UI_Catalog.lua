-- RLC_UI_Catalog.lua
-- The Catalogue tab. Loads after RLC_UI.lua, which owns the window and
-- the shared widgets (NS.UI), and hands its redraw to UI.refresh.
local _, NS = ...
local Rules = NS.Rules
local UI = NS.UI
local Text, Button, Tip, List, page = UI.Text, UI.Button, UI.Tip, UI.List, UI.page
local ItemTooltip, itemKey = UI.ItemTooltip, UI.itemKey
-- Every item seen drop, by instance and boss. Pick an item and Reserve it
-- while the raid is taking reserves, or shift-click it to link it in chat.

local cp = page("catalog")
local Catalog = NS.Catalog
local catBoss -- { instID, bossKey } of the selected boss
local catItem -- itemString of the selected item
local expanded = {} -- instID -> true when its bosses are listed
local expandRev = 0 -- counts expand and collapse clicks (refreshCatalog's skip)
-- Size sections (5-man, 10-man...) closed by a click, saved per account:
-- NS.DB.catSizesClosed[size] = true. All open until clicked.
local function sizesClosed()
    if type(NS.DB.catSizesClosed) ~= "table" then
        NS.DB.catSizesClosed = {}
    end
    return NS.DB.catSizesClosed
end
local catSpec, catWish = false, false -- filters: only items for my spec, only my wishlist
local wishRev = 0 -- counts wishlist changes, for the cached scan below

-- A search scans the whole catalogue, so it waits until typing pauses.
local searchTimer
local search = UI.InputBox(cp, 230, "Search all items", function()
    if searchTimer then
        searchTimer:Cancel()
    end
    searchTimer = C_Timer.NewTimer(0.25, NS.Refresh)
end)
search:SetPoint("TOPLEFT", 8, -2)
local CAT_SHOWN_MAX = 200
local specBtn = Button(cp, "My spec: off", 92, function()
    if not catSpec and not NS.Specs.Mine() then
        NS.Print("Your spec is not known yet. Pick it on the Raid tab.")
        return
    end
    catSpec = not catSpec
    NS.Refresh()
end)
specBtn:SetPoint("LEFT", search, "RIGHT", 10, 0)
local wishOnlyBtn = Button(cp, "Wishlist: off", 96, function()
    catWish = not catWish
    NS.Refresh()
end)
wishOnlyBtn:SetPoint("LEFT", specBtn, "RIGHT", 4, 0)
-- Wished items are saved per character (NS.Wish, by item ID), named in
-- chat when they drop (RLC_Catalog.lua) and marked on item tooltips.
local wishBtn = Button(cp, "Wish", 70, function()
    local id = catItem and Rules.ItemIDOf(catItem)
    if id then
        NS.Wish()[id] = not NS.Wish()[id] or nil
        wishRev = wishRev + 1
        NS.Refresh()
    end
end)
wishBtn:SetPoint("LEFT", wishOnlyBtn, "RIGHT", 4, 0)

-- itemID -> lower-case name, kept once the game knows it: a search reads
-- every record, so it should not ask the item API for each again. A miss is
-- kept as false until the game loads that item (NS.ItemInfoArrived).
local lowerNames = {}
local function lowerName(s)
    local id = Rules.ItemIDOf(s)
    if not id then
        return false
    end
    local name = lowerNames[id]
    if name == nil then
        name = C_Item.GetItemInfo(s)
        name = name and name:lower() or false
        lowerNames[id] = name
    end
    return name
end

-- The last search or wishlist scan: its matches stay until the query, the
-- wishlist, the catalogue or a missing name changes. catRev counts catalogue writes.
local catRev, catSearchKey, catSearchHits = 0, nil, nil
for _, fn in ipairs({ "Record", "ApplyOp", "Forget", "ForgetHeard" }) do
    local orig = Catalog[fn]
    if orig then
        Catalog[fn] = function(...)
            catRev = catRev + 1
            return orig(...)
        end
    end
end

-- The game loaded an item. True when the search was waiting for its name
-- (it may now find it).
function UI.itemArrived(itemID)
    if lowerNames[itemID] == false then
        lowerNames[itemID] = nil
        catRev = catRev + 1
        return true
    end
    return false
end

local tree = List(cp, 260, 330, { 220 }, false, function(row)
    if row.size then
        local closed = sizesClosed()
        closed[row.size] = not closed[row.size] or nil
        expandRev = expandRev + 1
    elseif row.bossKey == nil then
        expanded[row.instID] = not expanded[row.instID] or nil
        expandRev = expandRev + 1
    else
        catBoss, catItem = row, nil
        search:SetText("")
    end
    NS.Refresh()
end, { "Instance and boss" })
tree.frame:SetPoint("TOPLEFT", 4, -46)
tree.frame:SetPoint("BOTTOMLEFT", cp, "BOTTOMLEFT", 4, 4)

local catItems = List(cp, 420, 330, { 135, 118, 52, 49 }, true, function(rec)
    if IsModifiedClick() then
        -- Only a real link: an uncached item is a "[item 123]" placeholder.
        local link = NS.LinkOf(rec.s) -- also asks the game for it
        if NS.ItemStringOf(link) then
            HandleModifiedItemClick(link)
        end
        return
    end
    catItem = rec.s
    NS.Refresh()
end, { "Item", "Dropped", "Last seen", "Seen by" })
catItems.frame:SetPoint("TOPLEFT", 270, -46)
catItems.frame:SetPoint("BOTTOMLEFT", cp, "BOTTOMLEFT", 270, 58)
catItems.frame:SetPoint("BOTTOMRIGHT", cp, "BOTTOMRIGHT", -26, 58)
-- Who saw an item drop: "You" when we did, then the players heard from.
-- `first`: first names only, for the narrow column.
local function seenBy(rec, first)
    local names = {}
    if Catalog.OwnN(rec) > 0 then
        names[1] = "You"
    end
    for _, name in ipairs(rec.by or {}) do
        names[#names + 1] = NS.ColorName(name, first)
    end
    return names
end
local CAT_NAMES_MAX = 3 -- more than this shows as a count; the tooltip lists them
local WON_MAX = 5 -- "Won by" tooltip lines
catItems.onEnter = function(row, rec)
    ItemTooltip(row, rec.s)
    local names = seenBy(rec)
    if #names > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Seen dropping by:")
        for _, name in ipairs(names) do
            GameTooltip:AddLine(name, 1, 1, 1)
        end
        if #(rec.by or {}) >= Catalog.MAX_BY then
            GameTooltip:AddLine("and maybe more", 0.6, 0.6, 0.6)
        end
    end
    local wins = NS.Wins().byItem[Rules.ItemIDOf(rec.s)] or {}
    if #wins > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Won by:")
        for i = 1, math.min(#wins, WON_MAX) do
            GameTooltip:AddDoubleLine(NS.ColorName(wins[i].winner), date("%d %b %y", wins[i].t), 1, 1, 1, 0.6, 0.6, 0.6)
        end
        if #wins > WON_MAX then
            GameTooltip:AddLine("and " .. (#wins - WON_MAX) .. " more", 0.6, 0.6, 0.6)
        end
    end
    GameTooltip:Show()
end

local catReserve = Button(cp, "Reserve this", 110, function()
    local id = catItem and Rules.ItemIDOf(catItem)
    if id then
        NS.Act("RES", id)
    end
end)
catReserve:SetPoint("BOTTOMLEFT", 266, 22)
local catAsk = Button(cp, "Ask guild for updates", 150, function()
    Catalog.Ask("GUILD", true)
    if IsInGroup() then
        Catalog.Ask("GROUP", true)
    end
    NS.AskVersions(true) -- so everyone with the addon shows on the Versions tab
    NS.Print("Asked your guild and group for loot they have seen.")
end)
catAsk:SetPoint("LEFT", catReserve, "RIGHT", 6, 0)
local catForget = Button(cp, "Forget boss", 100, function()
    local boss = catBoss
    local inst = boss and NS.DB.catalog[boss.instID]
    if inst then
        NS.Confirm("Forget every drop seen for this boss?", function()
            inst.b[boss.bossKey] = nil
            if not next(inst.b) then
                NS.DB.catalog[boss.instID] = nil
            end
            Catalog.Forget(NS.DB.catalog)
            catBoss, catItem = nil, nil
            NS.Refresh()
        end)
    end
end)
catForget:SetPoint("LEFT", catAsk, "RIGHT", 6, 0)
-- Heard counts come from other players' addons; this keeps only what you saw.
local catForgetHeard = Button(cp, "Forget heard", 100, function()
    if Catalog.ForgetHeard then
        NS.Confirm("Forget all loot heard from other players?", function()
            local dropped = Catalog.ForgetHeard(NS.DB.catalog) or 0
            catBoss, catItem = nil, nil
            NS.Print("Kept only loot you saw yourself. Dropped " .. dropped .. " heard items.")
            NS.Refresh()
        end)
    end
end)
catForgetHeard:SetPoint("TOPRIGHT", -26, -2)
catForgetHeard:SetShown(Catalog.ForgetHeard ~= nil)
Tip(specBtn, "Show only items that suit your loot spec.")
Tip(wishOnlyBtn, "Show only your starred items, from every boss.")
Tip(wishBtn, "Star the picked item. You are told when it drops.")
Tip(catReserve, "Reserve the picked item for this raid.")
Tip(catAsk, "Ask your guild and group for drops you have not seen, and who has the addon.")
Tip(catForget, "Delete this boss and its drops from your Catalogue.")
Tip(catForgetHeard, "Delete everything other players' addons sent you. What you saw drop yourself stays.")
local catHelp = Text(cp, "GameFontDisableSmall")
catHelp:SetPoint("BOTTOMLEFT", 270, 4)
catHelp:SetPoint("BOTTOMRIGHT", 0, 4)
catHelp:SetWordWrap(true)
local CAT_HELP = "Filled in by everyone's addon as bosses die. Grey (heard): another player's addon saw it, "
    .. "not yours. Hover an item for who saw it drop and who won it. Shift-click to link it."
local CAT_MORE = "Showing the first " .. CAT_SHOWN_MAX .. " matches. Type more to narrow it."

local function sortedBosses(inst)
    local keys = {}
    for key in pairs(inst.b) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        if (a == 0) ~= (b == 0) then
            return b == 0 -- trash last
        end
        return (inst.b[a].f or 0) < (inst.b[b].f or 0)
    end)
    return keys
end

local function drawLists()
    local cat = NS.DB.catalog
    local insts = {}
    for instID in pairs(cat) do
        insts[#insts + 1] = instID
    end
    table.sort(insts, function(a, b)
        return cat[a].name < cat[b].name
    end)
    -- One section per group size (0: not known), each in name order.
    local bySize = {}
    for _, instID in ipairs(insts) do
        local size = Catalog.SizeOf(cat[instID], instID) or 0
        bySize[size] = bySize[size] or {}
        table.insert(bySize[size], instID)
    end
    local rows = {}
    local sizes = { unpack(Catalog.SIZES) }
    sizes[#sizes + 1] = 0
    for _, size in ipairs(sizes) do
        if bySize[size] then
            rows[#rows + 1] = { size = size }
        end
        for _, instID in ipairs(not sizesClosed()[size] and bySize[size] or {}) do
            rows[#rows + 1] = { instID = instID }
            if expanded[instID] then
                for _, key in ipairs(sortedBosses(cat[instID])) do
                    rows[#rows + 1] = { instID = instID, bossKey = key }
                end
            end
        end
    end
    tree:Set(#rows, function(r, i)
        local row = rows[i]
        r.data = row
        if row.size then
            r.cols[1]:SetText(
                (sizesClosed()[row.size] and "+ " or "- ")
                    .. "|cff66ccff"
                    .. (row.size > 0 and row.size .. "-man" or "Size not known")
                    .. "|r"
            )
            return false
        end
        local inst = cat[row.instID]
        if row.bossKey == nil then
            r.cols[1]:SetText("  " .. (expanded[row.instID] and "- " or "+ ") .. "|cffffd100" .. inst.name .. "|r")
            return false
        end
        local boss = inst.b[row.bossKey]
        r.cols[1]:SetText("       " .. boss.name .. " |cff999999(" .. boss.kills .. " kills)|r")
        return catBoss ~= nil and catBoss.instID == row.instID and catBoss.bossKey == row.bossKey
    end)

    -- Right side: the selected boss's items, or every match for the search
    -- (within the wishlist when that filter is on).
    local query = (search:GetText() or ""):lower()
    local wish = NS.Wish()
    local shown = {}
    if query ~= "" or catWish then
        local key = table.concat({ query, tostring(cat), catRev, tostring(catWish), wishRev, tostring(wish) }, "\0")
        if key ~= catSearchKey then
            catSearchKey, catSearchHits = key, {}
            for _, inst in pairs(cat) do
                for _, boss in pairs(inst.b) do
                    for _, rec in pairs(boss.i) do
                        local name = query ~= "" and lowerName(rec.s)
                        if
                            (not catWish or wish[Rules.ItemIDOf(rec.s)])
                            and (query == "" or (name and name:find(query, 1, true)))
                        then
                            catSearchHits[#catSearchHits + 1] = { rec = rec, label = boss.name }
                        end
                    end
                end
            end
        end
        for i, e in ipairs(catSearchHits) do
            shown[i] = e
        end
    elseif catBoss then
        local boss = cat[catBoss.instID] and cat[catBoss.instID].b[catBoss.bossKey]
        if boss then
            -- Our own counts when we have them; numbers only heard from
            -- others are shown dimmed and marked.
            local ok = Catalog.OwnKills(boss)
            for _, rec in pairs(boss.i) do
                local on = Catalog.OwnN(rec)
                local label
                if on == 0 then
                    label = catBoss.bossKey == 0 and ("seen " .. rec.n .. "x")
                        or string.format("%d of %d kills", rec.n, boss.kills)
                    label = "|cff808080" .. label .. " (heard)|r"
                elseif catBoss.bossKey == 0 then
                    label = "seen " .. on .. "x"
                else
                    label = string.format(
                        "%d of %d kills (%d%%)",
                        on,
                        math.max(ok, on),
                        math.floor(on / math.max(ok, on, 1) * 100 + 0.5)
                    )
                end
                shown[#shown + 1] = { rec = rec, label = label }
            end
        end
    end
    if catSpec then
        local suited = {}
        for _, e in ipairs(shown) do
            if NS.Specs.SuitsMe(e.rec.s) then
                suited[#suited + 1] = e
            end
        end
        shown = suited
    end
    -- One row frame per match: keep it bounded. After the filter, so the
    -- rows shown are the first matches that pass it.
    local more = #shown > CAT_SHOWN_MAX
    for i = #shown, CAT_SHOWN_MAX + 1, -1 do
        shown[i] = nil
    end
    catHelp:SetText(more and CAT_MORE or CAT_HELP)
    table.sort(shown, function(a, b)
        if a.rec.n ~= b.rec.n then
            return a.rec.n > b.rec.n
        end
        return a.rec.s < b.rec.s
    end)
    catItems:Sort(shown, {
        function(e)
            return itemKey(e.rec.s)
        end,
        function(e)
            return e.rec.n
        end,
        function(e)
            return e.rec.t
        end,
        function(e)
            return #seenBy(e.rec)
        end,
    })
    catItems:Set(#shown, function(r, i)
        local e = shown[i]
        r.data = e.rec
        r.icon:SetTexture(NS.IconOf(e.rec.s))
        r.cols[1]:SetText((wish[Rules.ItemIDOf(e.rec.s)] and "|cffffd100*|r " or "") .. NS.LinkOf(e.rec.s))
        r.cols[2]:SetText(e.label)
        r.cols[3]:SetText(e.rec.t > 0 and date("%d %b %y", e.rec.t) or "")
        local names = seenBy(e.rec, true)
        if #names > CAT_NAMES_MAX then
            r.cols[4]:SetText(#names .. (#(e.rec.by or {}) >= Catalog.MAX_BY and "+" or "") .. " players")
        else
            r.cols[4]:SetText(table.concat(names, ", "))
        end
        return e.rec.s == catItem
    end)
end

-- Both lists refill up to 200 rows, and the window redraws on every op and
-- roster change. So they redraw at once for anything clicked or typed here,
-- and for anything else (drops, kills, names, item loads) at most once a
-- second, with a redraw queued for the last change.
local catSig, catDrawn, catQueued = nil, 0, false
local function refreshCatalog()
    catSpec = catSpec and NS.Specs.Mine() ~= nil -- off again if the spec is lost: never "on" and filtering nothing
    local sig = table.concat({
        tostring(NS.DB.catalog),
        catRev,
        expandRev,
        tostring(catBoss and catBoss.instID),
        tostring(catBoss and catBoss.bossKey),
        tostring(catItem),
        (search:GetText() or ""):lower(),
        tostring(catSpec),
        tostring(NS.Specs.Mine()),
        tostring(catWish),
        wishRev,
        tostring(NS.Wish()),
        tostring(catItems.sortCol),
        tostring(catItems.desc),
    }, "\0")
    local wait = 1 - (GetTime() - catDrawn)
    if sig ~= catSig or wait <= 0 then
        catSig, catDrawn = sig, GetTime()
        drawLists()
    elseif not catQueued then
        catQueued = true
        C_Timer.After(wait, function()
            catQueued = false
            NS.Refresh()
        end)
    end

    local wish = NS.Wish()
    local S = NS.S()
    catReserve:SetShown(S ~= nil and S.phase == "reserve")
    catReserve:SetEnabled(catItem ~= nil and S ~= nil and next(S.items) == nil) -- closed at the first item
    catForget:SetEnabled(catBoss ~= nil)
    specBtn:SetText(catSpec and "My spec: on" or "My spec: off")
    wishOnlyBtn:SetText(catWish and "Wishlist: on" or "Wishlist: off")
    wishBtn:SetEnabled(catItem ~= nil)
    wishBtn:SetText(catItem and wish[Rules.ItemIDOf(catItem)] and "Unwish" or "Wish")
end

UI.refresh.catalog = refreshCatalog
