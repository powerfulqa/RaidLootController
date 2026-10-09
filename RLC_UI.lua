-- RLC_UI.lua
-- The window: Loot (the live item), Raid (session, reserves, players) and
-- History. Plain frames from stock templates, redrawn from state on every
-- NS.Refresh(); nothing here changes state except through NS.Act.
local _, NS = ...
local Rules = NS.Rules
local Loot = NS.Loot

local W, H = 720, 500
local ROW = 18

local STATE_TEXT = {
    pending = "|cff999999Waiting|r",
    interest = "|cffffd100Open for interest|r",
    rolling = "|cff00ff00Rolling|r",
    done = "Won",
    cancelled = "|cff999999Removed|r",
}
local MODE_TEXT = {
    normal = "for players without an item",
    open = "open to everyone",
    reserve = "reserved",
}
local HOW_TEXT = { roll = "roll", open = "open roll", reserve = "reserve", manual = "given" }
local PHASE_TEXT = {
    reserve = "|cff66ccffReserves open|r",
    live = "|cff00ff00Raid in progress|r",
    ended = "|cff999999Ended|r",
}

-- ---- widgets -------------------------------------------------------------------

local function Button(parent, text, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- A soft gold pulse over a frame, to point a player at the one thing to
-- click next. Display only: it never clicks or rolls for anyone.
-- frame.SetGlow(on) turns it on or off.
local function AddGlow(frame, texture)
    local t = frame:CreateTexture(nil, "OVERLAY")
    t:SetTexture(texture or "Interface\\Buttons\\ButtonHilight-Square")
    t:SetBlendMode("ADD")
    t:SetVertexColor(1, 0.8, 0.2)
    t:SetAllPoints()
    t:Hide()
    local ag = t:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(0.15)
    a:SetToAlpha(1)
    a:SetDuration(0.6)
    function frame.SetGlow(on)
        t:SetShown(on)
        if on and not ag:IsPlaying() then
            ag:Play()
        elseif not on then
            ag:Stop()
        end
    end
end

-- What the active item is waiting on from this player: "want", "roll" or nil.
local function myTurn(S)
    local item = S and S.active and S.items[S.active]
    if not item then
        return nil
    end
    local me = NS.Me()
    local myClass = NS.ClassOf(me)
    if item.state == "rolling" and Rules.CanRoll(S, item, me, myClass) then
        return "roll"
    elseif item.state == "interest" and not item.wants[me] and Rules.CanWant(S, item, me, myClass) then
        return "want"
    end
end

local function Text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function ItemTooltip(owner, itemString)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(itemString)
    GameTooltip:Show()
    -- Shift (or the "always compare" setting): the game's own side by side
    -- with what you wear, like a bag item.
    if TooltipUtil and TooltipUtil.ShouldDoItemComparison(GameTooltip) and GameTooltip_ShowCompareItem then
        GameTooltip_ShowCompareItem(GameTooltip)
    end
end

-- Lowest item level among a worn value ("item:1,item:2"), or nil.
local function wornLevel(worn)
    local low
    for s in (worn or ""):gmatch("[^,]+") do
        local lvl = C_Item.GetDetailedItemLevelInfo(s)
        if lvl and (not low or lvl < low) then
            low = lvl
        end
    end
    return low
end

-- Tooltip for a player who wants an item: what they wear in that slot and
-- the raw stat change the new item would bring. No weights: officers judge.
local function WornTooltip(owner, name, item)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(NS.ColorName(name))
    local worn = item.worn and item.worn[name]
    if not worn then
        GameTooltip:AddLine("No gear info: no addon, nothing in that slot, or not asked yet.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
        return
    end
    local _, newLink = C_Item.GetItemInfo(item.itemString)
    for s in worn:gmatch("[^,]+") do
        local _, link = C_Item.GetItemInfo(s)
        local lvl = C_Item.GetDetailedItemLevelInfo(s)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Wears " .. (link or NS.LinkOf(s)) .. (lvl and (" (ilvl " .. lvl .. ")") or ""))
        local delta = newLink and link and C_Item.GetItemStatDelta(newLink, link)
        if not delta then
            GameTooltip:AddLine("Stats loading, hover again.", 0.6, 0.6, 0.6)
        else
            local keys = {}
            for k, v in pairs(delta) do
                if v ~= 0 then
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local v = delta[k]
                local text = (v == math.floor(v) and string.format("%+d", v) or string.format("%+.1f", v))
                    .. " "
                    .. (_G[k] or k)
                GameTooltip:AddLine(text, v > 0 and 0.1 or 1, v > 0 and 1 or 0.3, v > 0 and 0.1 or 0.3)
            end
            if #keys == 0 then
                GameTooltip:AddLine("No stat change.", 0.6, 0.6, 0.6)
            end
        end
    end
    GameTooltip:Show()
end

-- Scrolling list of clickable rows. `cols` is a list of column widths; an
-- optional icon goes before the first column.
-- `headers` (optional) labels the columns, in a row just above the list.
local function List(parent, w, h, cols, withIcon, onClick, headers)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetSize(w - 24, h)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(w - 24, 1)
    sf:SetScrollChild(child)
    local bg = sf:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", -4, 4)
    bg:SetPoint("BOTTOMRIGHT", 22, -4)
    bg:SetColorTexture(0, 0, 0, 0.35)

    local rows = {}
    local list = { frame = sf, headers = {} }

    -- Column labels. They become sort buttons once the caller sorts with
    -- list:Sort; click once to sort, again to reverse.
    if headers then
        local x = withIcon and (ROW + 4) or 2
        for c, cw in ipairs(cols) do
            if headers[c] and headers[c] ~= "" then
                local hdr = CreateFrame("Button", nil, sf)
                hdr:SetSize(cw, 14)
                hdr:SetPoint("BOTTOMLEFT", sf, "TOPLEFT", x, 4)
                hdr:EnableMouse(false)
                hdr.text = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                hdr.text:SetPoint("LEFT")
                hdr.text:SetText(headers[c])
                hdr.arrow = hdr:CreateTexture(nil, "OVERLAY")
                hdr.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
                hdr.arrow:SetSize(9, 8)
                hdr.arrow:SetPoint("LEFT", hdr.text, "RIGHT", 3, 0)
                hdr.arrow:Hide()
                hdr:SetScript("OnClick", function()
                    if list.sortCol == c then
                        list.desc = not list.effDesc
                    else
                        list.sortCol, list.desc = c, nil
                    end
                    NS.Refresh()
                end)
                list.headers[c] = hdr
            end
            x = x + cw + 4
        end
    end

    -- Reorder `arr` in place by the clicked column. keys[c](entry) gives a
    -- number or a string for column c; columns without a key don't sort.
    -- First click: numbers high to low, text A to Z. Ties keep the order the
    -- caller built, so the default order is the tie-breaker.
    function list:Sort(arr, keys)
        for c, hdr in pairs(self.headers) do
            hdr:EnableMouse(keys[c] ~= nil)
            hdr.arrow:SetShown(c == self.sortCol and keys[c] ~= nil)
        end
        local key = self.sortCol and keys[self.sortCol]
        if not key then
            return
        end
        local vals, pos = {}, {}
        for i, e in ipairs(arr) do
            local v = key(e)
            if type(v) == "string" then
                v = v:lower()
            end
            vals[e], pos[e] = v, i
        end
        local sample = vals[arr[1]]
        local desc = self.desc
        if desc == nil then
            desc = type(sample) == "number"
        end
        self.effDesc = desc
        table.sort(arr, function(a, b)
            local va, vb = vals[a], vals[b]
            if va == vb or type(va) ~= type(vb) then
                return pos[a] < pos[b]
            end
            if desc then
                return va > vb
            end
            return va < vb
        end)
        -- Blizzard's sort arrow points up; flipped for high to low.
        if desc then
            self.headers[self.sortCol].arrow:SetTexCoord(0, 0.5625, 1, 0)
        else
            self.headers[self.sortCol].arrow:SetTexCoord(0, 0.5625, 0, 1)
        end
    end
    local function build(i)
        local r = CreateFrame("Button", nil, child)
        r:SetHeight(ROW)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
        r:SetPoint("RIGHT", child, "RIGHT")
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r.sel = r:CreateTexture(nil, "BACKGROUND")
        r.sel:SetAllPoints()
        r.sel:SetColorTexture(1, 0.82, 0, 0.18)
        local x = 2
        if withIcon then
            r.icon = r:CreateTexture(nil, "ARTWORK")
            r.icon:SetSize(ROW - 2, ROW - 2)
            r.icon:SetPoint("LEFT", x, 0)
            x = x + ROW + 2
        end
        r.cols = {}
        for c, cw in ipairs(cols) do
            local fs = Text(r)
            fs:SetPoint("LEFT", x, 0)
            fs:SetWidth(cw)
            r.cols[c] = fs
            x = x + cw + 4
        end
        r:SetScript("OnClick", function(self)
            if onClick then
                onClick(self.data)
            end
        end)
        r:SetScript("OnEnter", function(self)
            if list.onEnter then
                list.onEnter(self, self.data)
            end
        end)
        r:SetScript("OnLeave", GameTooltip_Hide)
        return r
    end
    -- fill(row, i) sets row.data, row.icon and row.cols, and returns true
    -- when the row is the selected one.
    function list:Set(n, fill)
        for i = 1, n do
            local r = rows[i] or build(i)
            rows[i] = r
            r.sel:SetShown(fill(r, i) == true)
            r:Show()
        end
        for i = n + 1, #rows do
            rows[i]:Hide()
        end
        child:SetHeight(math.max(1, n * ROW))
    end
    return list
end

-- ---- window ----------------------------------------------------------------------

local f = CreateFrame("Frame", "RaidLootControllerFrame", UIParent, "ButtonFrameTemplate")
f:SetSize(W, H)
f:SetPoint("CENTER")
f:SetFrameStrata("HIGH")
f:SetToplevel(true)
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", f.StopMovingOrSizing)
f:SetClampedToScreen(true)
ButtonFrameTemplate_HidePortrait(f)
f:SetTitle("Raid Loot Controller")
f:Hide()
tinsert(UISpecialFrames, "RaidLootControllerFrame") -- Escape closes it

-- An item dropped anywhere on the window is added (officers).
f:SetScript("OnReceiveDrag", Loot.AddFromCursor)
f:SetScript("OnMouseUp", function()
    if GetCursorInfo() == "item" then
        Loot.AddFromCursor()
    end
end)

local pages, tabs = {}, {}
local current = "loot"

local function page(key)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 12, -60)
    p:SetPoint("BOTTOMRIGHT", -12, 30)
    p:Hide()
    pages[key] = p
    return p
end

local function showPage(key)
    current = key
    for k, p in pairs(pages) do
        p:SetShown(k == key)
    end
    for k, b in pairs(tabs) do
        if k == key then
            b:LockHighlight()
        else
            b:UnlockHighlight()
        end
    end
    NS.Refresh()
end

local TABS = {
    { "loot", "Loot" },
    { "raid", "Raid" },
    { "history", "History" },
    { "catalog", "Catalogue" },
    { "help", "Help" },
}
for i, def in ipairs(TABS) do
    local b = Button(f, def[2], 100, function()
        showPage(def[1])
    end)
    b:SetPoint("TOPLEFT", 12 + (i - 1) * 104, -30)
    tabs[def[1]] = b
end
NS.ShowPage = function(key)
    current = key
    NS.Show()
end

-- RLC_Help.lua fills this page.
NS.helpPage = page("help")

-- ---- Loot page ----------------------------------------------------------------------

local lp = page("loot")
local selKey, selPlayer

local queue = List(lp, 280, 300, { 150, 90 }, true, function(item)
    selKey = item.key
    selPlayer = nil
    NS.Refresh()
end, { "Item", "Status" })
queue.frame:SetPoint("TOPLEFT", 4, -20)
queue.frame:SetPoint("BOTTOMLEFT", lp, "BOTTOMLEFT", 4, 62)
queue.onEnter = function(row, item)
    ItemTooltip(row, item.itemString)
end

local dropHint = Text(lp, "GameFontDisableSmall")
dropHint:SetPoint("BOTTOMLEFT", 0, 28)
dropHint:SetWidth(270)
dropHint:SetWordWrap(true)
dropHint:SetText("Officers: drop an item from your bags on this window, or open a loot window, to add it.")

local addLootBtn = Button(lp, "Add from loot", 130, function()
    Loot.AddFromWindow()
end)
addLootBtn:SetPoint("BOTTOMLEFT", 0, 0)

-- Right side: the selected item.
-- Shown on the right while there is no item to show.
local emptyText = Text(lp, "GameFontHighlight")
emptyText:SetPoint("TOPLEFT", 310, -30)
emptyText:SetWidth(370)
emptyText:SetWordWrap(true)
emptyText:SetSpacing(4)

local rp = CreateFrame("Frame", nil, lp)
rp:SetPoint("TOPLEFT", 300, -8)
rp:SetPoint("BOTTOMRIGHT")

local bigIcon = CreateFrame("Button", nil, rp)
bigIcon:SetSize(36, 36)
bigIcon:SetPoint("TOPLEFT", 0, 0)
bigIcon.tex = bigIcon:CreateTexture(nil, "ARTWORK")
bigIcon.tex:SetAllPoints()
bigIcon:SetScript("OnEnter", function(self)
    if self.itemString then
        ItemTooltip(self, self.itemString)
    end
end)
bigIcon:SetScript("OnLeave", GameTooltip_Hide)

local itemName = Text(rp, "GameFontNormalLarge")
itemName:SetPoint("TOPLEFT", bigIcon, "TOPRIGHT", 8, 0)
itemName:SetWidth(340)
local itemInfo = Text(rp)
itemInfo:SetPoint("TOPLEFT", itemName, "BOTTOMLEFT", 0, -4)
itemInfo:SetWidth(340)
local specInfo = Text(rp)
specInfo:SetPoint("TOPLEFT", itemInfo, "BOTTOMLEFT", 0, -3)
specInfo:SetWidth(340)
local myInfo = Text(rp, "GameFontNormalSmall")
myInfo:SetPoint("TOPLEFT", bigIcon, "BOTTOMLEFT", 0, -14)
myInfo:SetWidth(380)

local wantBtn = Button(rp, "I want this", 110, function()
    local S = NS.S()
    local item = S and selKey and S.items[selKey]
    if item then
        if item.wants[NS.Me()] then
            NS.Act("WANT", item.key, 0)
        else
            NS.Act("WANT", item.key, 1, Loot.WornFor(item.itemString))
        end
    end
end)
wantBtn:SetPoint("TOPLEFT", myInfo, "BOTTOMLEFT", 0, -6)
local rollBtn = Button(rp, "Roll (1-100)", 110, Loot.Roll)
rollBtn:SetPoint("LEFT", wantBtn, "RIGHT", 6, 0)
AddGlow(wantBtn)
AddGlow(rollBtn)

local people = List(rp, 390, 190, { 130, 150, 50 }, false, function(name)
    selPlayer = name
    NS.Refresh()
end, { "Player", "Interest", "Roll" })
people.frame:SetPoint("TOPLEFT", wantBtn, "BOTTOMLEFT", 4, -24)
people.frame:SetPoint("BOTTOMLEFT", rp, "BOTTOMLEFT", 4, 58)
people.onEnter = function(row, name)
    local S = NS.S()
    local item = S and selKey and S.items[selKey]
    if item and name then
        WornTooltip(row, name, item)
    end
end

-- Officer controls.
local admin = CreateFrame("Frame", nil, rp)
admin:SetPoint("BOTTOMLEFT", 0, 0)
admin:SetSize(400, 50)
local function adminButton(text, w, x, y, fn)
    local b = Button(admin, text, w, fn)
    b:SetPoint("BOTTOMLEFT", x, y)
    return b
end
local function onSel(kind)
    return function()
        if selKey then
            NS.Act(kind, selKey)
        end
    end
end
-- Two rows of four equal buttons that fill the panel width.
local BW, BX = 96, 100
local startBtn = adminButton("Start", BW, 0, 26, onSel("START"))
local callBtn = adminButton("Call roll", BW, BX, 26, onSel("CALL"))
local closeBtn = adminButton("Close roll", BW, BX * 2, 26, onSel("CLOSE"))
local openBtn = adminButton("Open to all", BW, BX * 3, 26, onSel("OPEN"))
local specBtn = adminButton("Who can roll", BW, 0, 0, function(self)
    NS.ShowSpecMenu(self)
end)
local awardBtn = adminButton("Give to player", BW, BX, 0, function()
    if selKey and selPlayer then
        NS.Act("AWARD", selKey, selPlayer)
    end
end)
local cancelBtn = adminButton("Remove item", BW, BX * 2, 0, onSel("CANCEL"))
local undoBtn = adminButton("Undo win", BW, BX * 3, 0, onSel("UNDO"))

-- Class-coloured, localized class name for a class token.
local CLASS_ID = {}
for id, token in pairs(Rules.CLASS_TOKEN) do
    CLASS_ID[token] = id
end
local function classLabel(token)
    local name = GetClassInfo(CLASS_ID[token] or 0) or token
    local color = C_ClassColor.GetClassColor(token)
    return color and color:WrapTextInColorCode(name) or name
end
NS.ClassLabel = classLabel

-- Sort key for an item: its name once the client has it, else its ID.
local function itemKey(itemString)
    return C_Item.GetItemInfo(itemString) or itemString
end

local function specName(key)
    local spec = key and NS.Specs.BY_KEY[key]
    return spec and spec.name or "?"
end

local function refreshLoot(S)
    local order = S and S.order or {}
    if S and (not selKey or not S.items[selKey]) then
        selKey = S.active or order[#order]
    end
    order = { unpack(order) } -- a copy: sorting must never touch S.order
    queue:Sort(order, {
        function(key)
            return itemKey(S.items[key].itemString)
        end,
        function(key)
            local item = S.items[key]
            return item.state == "done" and ("won " .. NS.Short(item.winner)) or item.state
        end,
    })
    queue:Set(#order, function(r, i)
        local item = S.items[order[i]]
        r.data = item
        r.icon:SetTexture(NS.IconOf(item.itemString))
        r.cols[1]:SetText(NS.LinkOf(item.itemString))
        r.cols[2]:SetText(item.state == "done" and NS.ColorName(item.winner) or STATE_TEXT[item.state])
        return item.key == selKey
    end)

    local officer = NS.IsOfficer()
    local pending = (Loot.lootOpen and officer) and Loot.PendingFromWindow() or 0
    addLootBtn:SetShown(officer)
    addLootBtn:SetEnabled(pending > 0)
    addLootBtn:SetText(pending > 0 and ("Add " .. pending .. " from loot") or "Add from loot")
    dropHint:SetShown(officer)
    admin:SetShown(officer)

    local item = S and selKey and S.items[selKey]
    rp:SetShown(item ~= nil)
    emptyText:SetShown(item == nil)
    if not S then
        emptyText:SetText(
            "No raid session yet.\n\nThe raid leader starts one on the Raid tab with New raid. "
                .. "Then everyone can reserve an item there before the raid starts."
        )
    elseif not item then
        emptyText:SetText(
            "No items yet.\n\nWhen a boss dies, the master looter adds the loot here. "
                .. "Then click I want this, and Roll when rolls are called."
        )
    end
    if not item then
        return
    end
    local me = NS.Me()
    local myClass = NS.ClassOf(me)
    bigIcon.itemString = item.itemString
    bigIcon.tex:SetTexture(NS.IconOf(item.itemString))
    itemName:SetText(NS.LinkOf(item.itemString))

    local stateText = item.state == "done"
            and ("Won by " .. NS.ColorName(item.winner) .. " (" .. (HOW_TEXT[item.how] or "") .. ")")
        or STATE_TEXT[item.state]
    itemInfo:SetText(stateText .. " - " .. MODE_TEXT[item.mode])
    specInfo:SetText("Best for: " .. NS.Specs.Describe(item.specs, classLabel))

    local canWant = Rules.CanWant(S, item, me, myClass)
    local wanted = item.wants[me]
    local canRoll = Rules.CanRoll(S, item, me, myClass)
    if item.state == "done" or item.state == "cancelled" or item.state == "pending" then
        myInfo:SetText("")
    elseif canRoll then
        myInfo:SetText("|cff00ff00You can roll now.|r")
    elseif item.rolls[me] then
        myInfo:SetText("You rolled " .. item.rolls[me] .. ".")
    elseif canWant then
        myInfo:SetText(wanted and "You want this item." or "You can ask for this item.")
    elseif item.mode == "normal" and item.specs and S.specs[me] and not item.specs[S.specs[me]] then
        myInfo:SetText(
            "|cffff8800This item is not for "
                .. specName(S.specs[me])
                .. ". You can roll if nobody it suits wants it.|r"
        )
    elseif item.mode == "normal" and S.locks[me] then
        myInfo:SetText("|cffff8800You already won an item. You can roll if nobody else wants this.|r")
    else
        myInfo:SetText("|cff999999You can't roll for this item.|r")
    end
    local live = item.state == "interest" or item.state == "rolling"
    wantBtn:SetShown(live and (canWant or wanted))
    wantBtn:SetText(wanted and "Not interested" or "I want this")
    rollBtn:SetShown(item.state == "rolling")
    rollBtn:SetEnabled(canRoll)
    -- Glow only on the item that is up now, for the click it is waiting on.
    local turn = item.key == S.active and myTurn(S)
    wantBtn.SetGlow(turn == "want")
    rollBtn.SetGlow(turn == "roll")

    -- Everyone who wants it, rolled, or may roll (reserve or tie), highest
    -- roll first.
    local names, seen = {}, {}
    local function add(name)
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    for name in pairs(item.wants) do
        add(name)
    end
    for name in pairs(item.rolls) do
        add(name)
    end
    for name in pairs(item.restrict or {}) do
        add(name)
    end
    table.sort(names, function(a, b)
        local ra, rb = item.rolls[a] or -1, item.rolls[b] or -1
        if ra ~= rb then
            return ra > rb
        end
        return a < b
    end)
    people:Sort(names, {
        NS.Short,
        function(name)
            return (item.wants[name] and 2 or 0) + (S.reserves[name] == item.itemID and 1 or 0)
        end,
        function(name)
            return item.rolls[name] or -1
        end,
    })
    people:Set(#names, function(r, i)
        local name = names[i]
        r.data = name
        r.cols[1]:SetText(NS.ColorName(name))
        local tags = {}
        if item.wants[name] then
            local lvl = wornLevel(item.worn and item.worn[name])
            tags[#tags + 1] = "wants it" .. (lvl and ("|cff999999 (wears ilvl " .. lvl .. ")|r") or "")
        end
        if S.reserves[name] == item.itemID then
            tags[#tags + 1] = "|cff66ccffreserved|r"
        end
        if S.locks[name] and item.winner ~= name then
            tags[#tags + 1] = "|cffff8800has an item|r"
        end
        r.cols[2]:SetText(table.concat(tags, ", "))
        r.cols[3]:SetText(item.rolls[name] and ("|cffffffff" .. item.rolls[name] .. "|r") or "")
        return name == selPlayer
    end)

    local finished = item.state == "done" or item.state == "cancelled"
    startBtn:SetEnabled(item.state == "pending")
    callBtn:SetEnabled(item.state == "interest")
    closeBtn:SetEnabled(item.state == "rolling")
    openBtn:SetEnabled(live and item.mode ~= "open")
    specBtn:SetEnabled(not finished)
    awardBtn:SetEnabled(selPlayer ~= nil and not finished)
    cancelBtn:SetEnabled(not finished)
    undoBtn:SetEnabled(item.state == "done")
end

-- ---- spec menus ------------------------------------------------------------------------

-- Officers: which specs may roll for the selected item. Each tick takes
-- effect at once. "Suggested" re-runs the item rules; "Any spec" lifts the
-- limit.
function NS.ShowSpecMenu(owner)
    local S = NS.S()
    local item = S and selKey and S.items[selKey]
    if not item then
        return
    end
    local function send(set)
        NS.Act("SPECS", item.key, Rules.SpecsToCSV(set))
    end
    local function currentSpecs()
        local now = {}
        for k in pairs(item.specs or {}) do
            now[k] = true
        end
        return now
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Who can roll")
        root:CreateButton("Suggested for this item", function()
            local _, csv = NS.Specs.DescribeItem(item.itemString)
            send(Rules.CSVToSpecs(csv) or {})
        end)
        root:CreateButton("Any spec", function()
            send({})
        end)
        local byClass, order = {}, {}
        for _, spec in ipairs(NS.Specs.LIST) do
            if not byClass[spec.class] then
                byClass[spec.class] = {}
                order[#order + 1] = spec.class
            end
            table.insert(byClass[spec.class], spec)
        end
        for _, token in ipairs(order) do
            local sub = root:CreateButton(classLabel(token))
            for _, spec in ipairs(byClass[token]) do
                sub:CreateCheckbox(spec.name, function()
                    return item.specs ~= nil and item.specs[spec.key] == true
                end, function()
                    local now = currentSpecs()
                    now[spec.key] = not now[spec.key] or nil
                    send(now)
                end)
            end
        end
    end)
end

-- Pick a spec for one player: yourself (stored on this character and sent
-- to the host), or, for officers, anyone in the raid.
local function showPlayerSpecMenu(owner, name)
    local me = NS.Me()
    local token = name == me and select(2, UnitClass("player")) or Rules.CLASS_TOKEN[NS.ClassOf(name) or 0]
    if not token then
        NS.Print("Can't tell that player's class.")
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(NS.Short(name) .. " - spec")
        if name == me then
            root:CreateRadio("From my talents", function()
                return NS.DB.mySpec[me] == nil
            end, function()
                NS.Specs.Choose(nil)
            end)
        end
        for _, spec in ipairs(NS.Specs.LIST) do
            if spec.class == token then
                root:CreateRadio(spec.name, function()
                    local S = NS.S()
                    if name == me then
                        return NS.DB.mySpec[me] == spec.key
                    end
                    return S ~= nil and S.specs[name] == spec.key
                end, function()
                    if name == me then
                        NS.Specs.Choose(spec.key)
                    else
                        NS.Act("SETSPEC", name, spec.key)
                    end
                end)
            end
        end
    end)
end

-- ---- Raid page ----------------------------------------------------------------------

local rpg = page("raid")
local raidSel

local titleBox = CreateFrame("EditBox", nil, rpg, "InputBoxTemplate")
titleBox:SetSize(180, 20)
titleBox:SetPoint("TOPLEFT", 8, -2)
titleBox:SetAutoFocus(false)
titleBox:SetMaxLetters(40)
titleBox.hint = Text(titleBox, "GameFontDisableSmall")
titleBox.hint:SetPoint("LEFT", 2, 0)
titleBox.hint:SetText("Raid name (optional)")
titleBox:SetScript("OnTextChanged", function(self)
    self.hint:SetShown(self:GetText() == "")
end)
local newBtn = Button(rpg, "New raid", 90, function()
    NS.NewSession(titleBox:GetText() or "")
    titleBox:ClearFocus()
end)
newBtn:SetPoint("LEFT", titleBox, "RIGHT", 6, 0)
local beginBtn = Button(rpg, "Start raid", 90, function()
    NS.Act("PHASE", "live")
end)
beginBtn:SetPoint("LEFT", newBtn, "RIGHT", 6, 0)
local endBtn = Button(rpg, "End raid", 90, function()
    NS.Act("PHASE", "ended")
end)
endBtn:SetPoint("LEFT", beginBtn, "RIGHT", 6, 0)
local syncBtn = Button(rpg, "Resync", 80, function()
    NS.RequestSync(0)
end)
syncBtn:SetPoint("TOPRIGHT", 0, 0)

local raidHelp = Text(rpg)
raidHelp:SetPoint("TOPLEFT", 0, -30)
raidHelp:SetWidth(680)
raidHelp:SetWordWrap(true)

-- Reserve controls.
local resLabel = Text(rpg, "GameFontNormal")
resLabel:SetPoint("TOPLEFT", 0, -62)
resLabel:SetWidth(400)
local resBox = CreateFrame("EditBox", nil, rpg, "InputBoxTemplate")
resBox:SetSize(220, 20)
resBox:SetPoint("TOPLEFT", 8, -84)
resBox:SetAutoFocus(false)
resBox.hint = Text(resBox, "GameFontDisableSmall")
resBox.hint:SetPoint("LEFT", 2, 0)
resBox.hint:SetText("Shift-click an item, or type its ID")
resBox:SetScript("OnTextChanged", function(self)
    self.hint:SetShown(self:GetText() == "")
end)
local function doReserve()
    local text = resBox:GetText() or ""
    local id = tonumber(text) or Rules.ItemIDOf(NS.ItemStringOf(text) or "")
    if id then
        NS.Act("RES", id)
        resBox:SetText("")
        resBox:ClearFocus()
    else
        NS.Print("Shift-click an item into the box, or type its item ID.")
    end
end
resBox:SetScript("OnEnterPressed", doReserve)
local resBtn = Button(rpg, "Reserve", 80, doReserve)
resBtn:SetPoint("LEFT", resBox, "RIGHT", 6, 0)
local unresBtn = Button(rpg, "Clear", 60, function()
    NS.Act("RES", 0)
end)
unresBtn:SetPoint("LEFT", resBtn, "RIGHT", 4, 0)

-- Shift-clicking an item while the reserve box has focus fills it in.
local function onInsertLink(text)
    if resBox:HasFocus() and type(text) == "string" then
        resBox:SetText(text)
    end
end
if ChatFrameUtil and ChatFrameUtil.InsertLink then
    hooksecurefunc(ChatFrameUtil, "InsertLink", onInsertLink)
end
-- The deprecated global is a separate reference to the same function, so
-- callers that still use it would miss the hook above.
if ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", onInsertLink)
end

-- Your spec, from talents or picked by hand.
local mySpecLabel = Text(rpg, "GameFontNormal")
mySpecLabel:SetPoint("TOPLEFT", 420, -62)
mySpecLabel:SetWidth(270)
local mySpecBtn = Button(rpg, "Change loot spec", 120, function(self)
    showPlayerSpecMenu(self, NS.Me())
end)
mySpecBtn:SetPoint("TOPLEFT", mySpecLabel, "BOTTOMLEFT", 0, -4)
-- Dual spec: talents say what you play tonight, not what you loot for. A
-- detected spec stays a guess until the player confirms it once.
local confirmSpecBtn = Button(rpg, "Confirm", 70, function()
    local spec = NS.Specs.Mine()
    if spec then
        NS.Specs.Choose(spec)
    end
end)
confirmSpecBtn:SetPoint("LEFT", mySpecBtn, "RIGHT", 6, 0)
AddGlow(mySpecBtn)
AddGlow(confirmSpecBtn)

local players = List(rpg, 690, 205, { 110, 90, 170, 50, 100, 70 }, false, function(name)
    raidSel = name
    NS.Refresh()
end, { "Player", "Spec", "Reserve", "Won", "Status", "Role" })
players.frame:SetPoint("TOPLEFT", 4, -142)
players.frame:SetPoint("BOTTOMLEFT", rpg, "BOTTOMLEFT", 4, 62)
players.onEnter = function(row, name)
    local S = NS.S()
    local id = S and S.reserves[name]
    if id then
        ItemTooltip(row, "item:" .. id)
    end
end

local lockBtn = Button(rpg, "Unlock", 100, function()
    local S = NS.S()
    if raidSel and S then
        NS.Act("LOCK", raidSel, S.locks[raidSel] and 0 or 1)
    end
end)
lockBtn:SetPoint("BOTTOMLEFT", 0, 28)
local offBtn = Button(rpg, "Make officer", 110, function()
    local S = NS.S()
    if raidSel and S then
        NS.Act("OFF", raidSel, S.officers[raidSel] and 0 or 1)
    end
end)
offBtn:SetPoint("LEFT", lockBtn, "RIGHT", 6, 0)
local setSpecBtn = Button(rpg, "Set spec", 90, function(self)
    if raidSel then
        showPlayerSpecMenu(self, raidSel)
    end
end)
setSpecBtn:SetPoint("LEFT", offBtn, "RIGHT", 6, 0)
local owedText = Text(rpg)
owedText:SetPoint("BOTTOMLEFT", 0, 4)
owedText:SetWidth(680)
owedText:SetWordWrap(true)

local function refreshRaid(S)
    local me = NS.Me()
    local canStart = not IsInGroup() or UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    titleBox:SetShown(canStart)
    newBtn:SetShown(canStart)
    local officer = NS.IsOfficer()
    beginBtn:SetShown(officer and S.phase == "reserve")
    endBtn:SetShown(officer and S.phase == "live")

    if not S then
        raidHelp:SetText("No raid session. The raid leader or an assistant starts one with New raid.")
    elseif S.phase == "reserve" then
        raidHelp:SetText(
            "Reserve one item before the raid starts. If nobody else reserves it, it is yours when it drops. "
                .. "If several players reserve it, only they roll."
        )
    else
        raidHelp:SetText(
            "Everyone gets one item before anyone gets two. After you win an item you can only roll "
                .. "when nobody without an item wants it, or an officer unlocks you."
        )
    end

    local reserving = S ~= nil and S.phase == "reserve"
    local mine = S and S.reserves[me]
    resLabel:SetText("Your reserve: " .. (mine and NS.LinkOf("item:" .. mine) or "none"))
    resLabel:SetShown(S ~= nil)
    resBox:SetShown(reserving)
    resBtn:SetShown(reserving)
    unresBtn:SetShown(reserving and mine ~= nil)

    -- Everyone in the group plus anyone the session knows about.
    local names, seen = {}, {}
    local function add(name)
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    for name in pairs(NS.roster) do
        add(name)
    end
    local won = {}
    if S then
        for name in pairs(S.reserves) do
            add(name)
        end
        for name in pairs(S.locks) do
            add(name)
        end
        for _, item in pairs(S.items) do
            if item.state == "done" then
                won[item.winner] = (won[item.winner] or 0) + 1
            end
        end
    end
    table.sort(names)
    players:Sort(names, {
        NS.Short,
        function(name)
            local spec = S and S.specs[name]
            return spec and specName(spec) or ""
        end,
        function(name)
            local res = S and S.reserves[name]
            return res and itemKey("item:" .. res) or ""
        end,
        function(name)
            return won[name] or 0
        end,
        function(name)
            return S and S.locks[name] and 1 or 0
        end,
        function(name)
            return S and (S.host == name and 2 or (S.officers[name] and 1)) or 0
        end,
    })
    players:Set(#names, function(r, i)
        local name = names[i]
        r.data = name
        r.cols[1]:SetText(NS.ColorName(name) .. (NS.roster[name] and "" or " |cff999999(left)|r"))
        local res = S and S.reserves[name]
        local spec = S and S.specs[name]
        r.cols[2]:SetText(spec and specName(spec) or "|cff999999-|r")
        r.cols[3]:SetText(res and NS.LinkOf("item:" .. res) or "")
        r.cols[4]:SetText(won[name] and (won[name] .. " won") or "")
        local status = ""
        if S then
            status = S.locks[name] and "|cffff8800Has an item|r" or "|cff00ff00Can roll|r"
        end
        r.cols[5]:SetText(status)
        r.cols[6]:SetText(S and (S.host == name and "Host" or (S.officers[name] and "Officer")) or "")
        return name == raidSel
    end)

    lockBtn:SetShown(officer)
    lockBtn:SetEnabled(raidSel ~= nil)
    lockBtn:SetText((S and raidSel and S.locks[raidSel]) and "Unlock" or "Lock")
    offBtn:SetShown(NS.IsHost())
    offBtn:SetEnabled(raidSel ~= nil and raidSel ~= me)
    offBtn:SetText((S and raidSel and S.officers[raidSel]) and "Remove officer" or "Make officer")
    setSpecBtn:SetShown(officer)
    setSpecBtn:SetEnabled(raidSel ~= nil)

    -- Own spec: what we would report, and what the raid has on record.
    local mySpec, picked = NS.Specs.Mine()
    local onRecord = S and S.specs[me]
    local line = "Your loot spec: "
        .. (mySpec and specName(mySpec) or "|cffff8800unknown, pick one|r")
        .. (mySpec and (picked and " (confirmed)" or " |cffff8800(from talents: confirm it)|r") or "")
    confirmSpecBtn:SetShown(mySpec ~= nil and not picked)
    confirmSpecBtn.SetGlow(mySpec ~= nil and not picked)
    mySpecBtn.SetGlow(mySpec == nil)
    if onRecord and onRecord ~= mySpec then
        line = line .. "\n|cffff8800Raid has you as " .. specName(onRecord) .. " (locked).|r"
    end
    mySpecLabel:SetText(line)
    mySpecLabel:SetWordWrap(true)

    local parts = {}
    for name, list in pairs(NS.DB.owed) do
        for _, s in ipairs(list) do
            parts[#parts + 1] = NS.ColorName(name) .. ": " .. NS.LinkOf(s)
        end
    end
    owedText:SetShown(#parts > 0)
    owedText:SetText("Still to trade: " .. table.concat(parts, ", "))
end

-- ---- History page ---------------------------------------------------------------------

local hp = page("history")
local histSel

local raidsList = List(hp, 230, 380, { 70, 130 }, false, function(id)
    histSel = id
    NS.Refresh()
end, { "Date", "Raid" })
raidsList.frame:SetPoint("TOPLEFT", 4, -20)
raidsList.frame:SetPoint("BOTTOMLEFT", hp, "BOTTOMLEFT", 4, 4)

local histItems = List(hp, 436, 350, { 180, 110, 80 }, true, nil, { "Item", "Winner", "How" })
histItems.frame:SetPoint("TOPLEFT", 250, -20)
histItems.frame:SetPoint("BOTTOMLEFT", hp, "BOTTOMLEFT", 250, 34)
histItems.onEnter = function(row, item)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(item.itemString)
    local lines = {}
    for name, n in pairs(item.rolls) do
        lines[#lines + 1] = { name = name, n = n }
    end
    table.sort(lines, function(a, b)
        return a.n > b.n
    end)
    if #lines > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Rolls")
        for _, l in ipairs(lines) do
            GameTooltip:AddDoubleLine(NS.ColorName(l.name), l.n, 1, 1, 1, 1, 1, 1)
        end
    end
    local wants = {}
    for name in pairs(item.wants) do
        wants[#wants + 1] = NS.ColorName(name)
    end
    if #wants > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Wanted by: " .. table.concat(wants, ", "), 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local delBtn = Button(hp, "Delete raid", 100, function()
    if histSel then
        NS.DB.history[histSel] = nil
        histSel = nil
        NS.Refresh()
    end
end)
delBtn:SetPoint("BOTTOMLEFT", 246, 0)

local function refreshHistory()
    local hist = NS.DB.history
    local ids = {}
    for id in pairs(hist) do
        ids[#ids + 1] = id
    end
    table.sort(ids, function(a, b)
        return (hist[a].created or 0) > (hist[b].created or 0)
    end)
    if not histSel or not hist[histSel] then
        histSel = ids[1]
    end
    raidsList:Sort(ids, {
        function(id)
            return hist[id].created or 0
        end,
        function(id)
            return hist[id].title or ""
        end,
    })
    raidsList:Set(#ids, function(r, i)
        local rec = hist[ids[i]]
        r.data = ids[i]
        r.cols[1]:SetText(date("%d %b %y", rec.created or 0))
        r.cols[2]:SetText(rec.title or "?")
        return ids[i] == histSel
    end)
    local rec = histSel and hist[histSel]
    local shown = {}
    if rec then
        for _, key in ipairs(rec.order) do
            local item = rec.items[key]
            if item.state == "done" then
                shown[#shown + 1] = item
            end
        end
    end
    histItems:Sort(shown, {
        function(item)
            return itemKey(item.itemString)
        end,
        function(item)
            return NS.Short(item.winner)
        end,
        function(item)
            return HOW_TEXT[item.how] or ""
        end,
    })
    histItems:Set(#shown, function(r, i)
        local item = shown[i]
        r.data = item
        r.icon:SetTexture(NS.IconOf(item.itemString))
        r.cols[1]:SetText(NS.LinkOf(item.itemString))
        r.cols[2]:SetText(NS.ColorName(item.winner))
        r.cols[3]:SetText(HOW_TEXT[item.how] or "")
    end)
    delBtn:SetEnabled(rec ~= nil)
end

-- ---- Catalogue page ---------------------------------------------------------------------
-- Every item seen drop, by instance and boss. Pick an item and Reserve it
-- while the raid is taking reserves, or shift-click it to link it in chat.

local cp = page("catalog")
local Catalog = NS.Catalog
local catBoss -- { instID, bossKey } of the selected boss
local catItem -- itemString of the selected item
local expanded = {} -- instID -> true when its bosses are listed

local search = CreateFrame("EditBox", nil, cp, "InputBoxTemplate")
search:SetSize(230, 20)
search:SetPoint("TOPLEFT", 8, -2)
search:SetAutoFocus(false)
search.hint = Text(search, "GameFontDisableSmall")
search.hint:SetPoint("LEFT", 2, 0)
search.hint:SetText("Search all items")
search:SetScript("OnTextChanged", function(self)
    self.hint:SetShown(self:GetText() == "")
    NS.Refresh()
end)
search:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
end)

local tree = List(cp, 260, 330, { 220 }, false, function(row)
    if row.bossKey == nil then
        expanded[row.instID] = not expanded[row.instID] or nil
    else
        catBoss, catItem = row, nil
        search:SetText("")
    end
    NS.Refresh()
end, { "Instance and boss" })
tree.frame:SetPoint("TOPLEFT", 4, -46)
tree.frame:SetPoint("BOTTOMLEFT", cp, "BOTTOMLEFT", 4, 4)

local catItems = List(cp, 420, 330, { 165, 135, 58 }, true, function(rec)
    if IsModifiedClick() then
        HandleModifiedItemClick(NS.LinkOf(rec.s))
        return
    end
    catItem = rec.s
    NS.Refresh()
end, { "Item", "Dropped", "Last seen" })
catItems.frame:SetPoint("TOPLEFT", 270, -46)
catItems.frame:SetPoint("BOTTOMLEFT", cp, "BOTTOMLEFT", 270, 58)
catItems.onEnter = function(row, rec)
    ItemTooltip(row, rec.s)
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
    NS.Print("Asked your guild and group for loot they have seen.")
end)
catAsk:SetPoint("LEFT", catReserve, "RIGHT", 6, 0)
local catForget = Button(cp, "Forget boss", 100, function()
    local inst = catBoss and NS.DB.catalog[catBoss.instID]
    if inst then
        inst.b[catBoss.bossKey] = nil
        if not next(inst.b) then
            NS.DB.catalog[catBoss.instID] = nil
        end
        Catalog.Forget(NS.DB.catalog)
        catBoss, catItem = nil, nil
        NS.Refresh()
    end
end)
catForget:SetPoint("LEFT", catAsk, "RIGHT", 6, 0)
local catHelp = Text(cp, "GameFontDisableSmall")
catHelp:SetPoint("BOTTOMLEFT", 270, 4)
catHelp:SetWidth(410)
catHelp:SetWordWrap(true)
catHelp:SetText("Filled in by everyone's addon as bosses die. Shift-click an item to link it.")

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

local function refreshCatalog()
    local cat = NS.DB.catalog
    local insts = {}
    for instID in pairs(cat) do
        insts[#insts + 1] = instID
    end
    table.sort(insts, function(a, b)
        return cat[a].name < cat[b].name
    end)
    local rows = {}
    for _, instID in ipairs(insts) do
        rows[#rows + 1] = { instID = instID }
        if expanded[instID] then
            for _, key in ipairs(sortedBosses(cat[instID])) do
                rows[#rows + 1] = { instID = instID, bossKey = key }
            end
        end
    end
    tree:Set(#rows, function(r, i)
        local row = rows[i]
        r.data = row
        local inst = cat[row.instID]
        if row.bossKey == nil then
            r.cols[1]:SetText((expanded[row.instID] and "- " or "+ ") .. "|cffffd100" .. inst.name .. "|r")
            return false
        end
        local boss = inst.b[row.bossKey]
        r.cols[1]:SetText("     " .. boss.name .. " |cff999999(" .. boss.kills .. " kills)|r")
        return catBoss ~= nil and catBoss.instID == row.instID and catBoss.bossKey == row.bossKey
    end)

    -- Right side: the selected boss's items, or every match for the search.
    local query = (search:GetText() or ""):lower()
    local shown = {}
    if query ~= "" then
        for _, inst in pairs(cat) do
            for _, boss in pairs(inst.b) do
                for _, rec in pairs(boss.i) do
                    local name = C_Item.GetItemInfo(rec.s)
                    if name and name:lower():find(query, 1, true) then
                        shown[#shown + 1] = { rec = rec, label = boss.name }
                    end
                end
            end
        end
    elseif catBoss then
        local boss = cat[catBoss.instID] and cat[catBoss.instID].b[catBoss.bossKey]
        if boss then
            for _, rec in pairs(boss.i) do
                local label = catBoss.bossKey == 0 and ("seen " .. rec.n .. "x")
                    or string.format(
                        "in %d of %d kills (%d%%)",
                        rec.n,
                        boss.kills,
                        math.floor(rec.n / math.max(boss.kills, 1) * 100 + 0.5)
                    )
                shown[#shown + 1] = { rec = rec, label = label }
            end
        end
    end
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
    })
    catItems:Set(#shown, function(r, i)
        local e = shown[i]
        r.data = e.rec
        r.icon:SetTexture(NS.IconOf(e.rec.s))
        r.cols[1]:SetText(NS.LinkOf(e.rec.s))
        r.cols[2]:SetText(e.label)
        r.cols[3]:SetText(e.rec.t > 0 and date("%d %b %y", e.rec.t) or "")
        return e.rec.s == catItem
    end)

    local S = NS.S()
    catReserve:SetShown(S ~= nil and S.phase == "reserve")
    catReserve:SetEnabled(catItem ~= nil)
    catForget:SetEnabled(catBoss ~= nil)
end

-- ---- refresh -------------------------------------------------------------------------

local pendingRefresh = false
local lastActive

local function refreshNow()
    pendingRefresh = false
    if not NS.DB then
        return
    end
    local S = NS.S()
    if NS.UpdateMinimapGlow then
        NS.UpdateMinimapGlow()
    end
    -- A new item up for rolls pops the window open on the Loot page.
    local active = S and S.active
    if active and active ~= lastActive then
        selKey, selPlayer = active, nil
        if not f:IsShown() then
            current = "loot"
            NS.Show()
        end
    end
    lastActive = active
    if not f:IsShown() then
        return
    end
    -- The session's status lives in the title, so the tab row has room.
    if S then
        f:SetTitle("Raid Loot Controller - " .. (S.title or "") .. " - " .. (PHASE_TEXT[S.phase] or ""))
    else
        f:SetTitle("Raid Loot Controller")
    end
    if current == "loot" then
        refreshLoot(S)
    elseif current == "raid" then
        refreshRaid(S)
    elseif current == "catalog" then
        refreshCatalog()
    elseif current == "help" then
        NS.RefreshHelp()
    else
        refreshHistory()
    end
end

-- Coalesced to once per frame: a snapshot applies dozens of ops at once.
function NS.Refresh()
    if not pendingRefresh then
        pendingRefresh = true
        C_Timer.After(0, refreshNow)
    end
end

function NS.Show()
    f:Show()
    showPage(current)
end

function NS.Toggle()
    if f:IsShown() then
        f:Hide()
    else
        NS.Show()
    end
end

-- ---- minimap button ------------------------------------------------------------------
-- Left-click opens the window, right-click opens the Catalogue, drag to move
-- it round the minimap edge. /rlc minimap hides or shows it. Same shape as
-- the WoWClearance button, which is measured working on this client.

local EDGE = 10 -- how far outside the minimap edge the button sits

local function placeButton(btn)
    local angle = math.rad(NS.DB.minimapAngle or 200)
    local rx = (Minimap:GetWidth() or 0) > 0 and Minimap:GetWidth() / 2 + EDGE or 80
    local ry = (Minimap:GetHeight() or 0) > 0 and Minimap:GetHeight() / 2 + EDGE or 80
    local x, y = math.cos(angle) * rx, math.sin(angle) * ry
    -- A square minimap needs the button clamped to its edges, not a circle.
    if ((GetMinimapShape and GetMinimapShape()) or "ROUND") ~= "ROUND" then
        x = math.max(-rx, math.min(x * math.sqrt(2), rx))
        y = math.max(-ry, math.min(y * math.sqrt(2), ry))
    end
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local mmButton
local function createMinimapButton()
    -- Not created at all when hidden: parenting a frame to the minimap is
    -- itself what some minimap replacements react badly to.
    if mmButton or NS.DB.minimapButton == false then
        return
    end
    local btn = CreateFrame("Button", "RaidLootControllerMinimapButton", Minimap)
    mmButton = btn
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Background")
    bg:SetSize(53, 53)
    bg:SetPoint("CENTER", -1, 1)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(133639) -- inv_misc_bag_10, same as the .toc icon
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("CENTER", 10, -10)
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    AddGlow(btn, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    btn.SetGlow(myTurn(NS.S()) ~= nil)

    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            NS.DB.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            placeButton(self)
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            current = "catalog"
            NS.Show()
        else
            NS.Toggle()
        end
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Raid Loot Controller")
        local S = NS.S()
        if S then
            GameTooltip:AddLine((S.title or "") .. " - " .. (PHASE_TEXT[S.phase] or ""), 1, 1, 1)
            local item = S.active and S.items[S.active]
            if item then
                GameTooltip:AddLine("Up now: " .. NS.LinkOf(item.itemString), 1, 1, 1)
            end
        end
        GameTooltip:AddLine("Left-click: open  |  Right-click: catalogue  |  Drag: move", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
    placeButton(btn)
end

function NS.SetMinimapButton(show)
    NS.DB.minimapButton = show
    if show then
        createMinimapButton()
        if mmButton then
            mmButton:Show()
        end
    elseif mmButton then
        mmButton:Hide()
    end
end

NS.On("PLAYER_LOGIN", createMinimapButton)

-- The minimap button pulses while an item is waiting on you, so a player
-- who closed the window still sees it.
function NS.UpdateMinimapGlow()
    if mmButton then
        mmButton.SetGlow(myTurn(NS.S()) ~= nil)
    end
end
