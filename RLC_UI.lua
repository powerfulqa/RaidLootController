-- RLC_UI.lua
-- The window: Loot (the live item), Raid (session, reserves, players) and
-- History. Plain frames from stock templates, redrawn from state on every
-- NS.Refresh(); nothing here changes state except through NS.Act.
local _, NS = ...
local Rules = NS.Rules
local Loot = NS.Loot

local W, H = 720, 500
local ROW = 22

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

local AddGlow, ResizeGrip = NS.Kit.AddGlow, NS.Kit.ResizeGrip

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

-- A one-line input box with a grey hint while it is empty. onChange(box)
-- runs after every change. Escape empties it.
function NS.InputBox(parent, w, hintText, onChange)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(w, 20)
    box:SetAutoFocus(false)
    box.hint = Text(box, "GameFontDisableSmall")
    box.hint:SetPoint("LEFT", 2, 0)
    box.hint:SetText(hintText)
    box:SetScript("OnTextChanged", function(self)
        self.hint:SetShown(self:GetText() == "")
        if onChange then
            onChange(self)
        end
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    return box
end

local function ItemTooltip(owner, itemString)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(itemString)
    GameTooltip:Show()
    -- Shift (or "always compare") shows the game's own side by side: the
    -- tooltip does it itself, and calling it from here would only taint it.
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
        if not (newLink and link) then
            GameTooltip:AddLine("Stats loading, hover again.", 0.6, 0.6, 0.6)
        else
            local delta = C_Item.GetItemStatDelta(newLink, link) or {}
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
    sf.scrollBarHideable = true -- the template hides the bar while the rows fit
    sf:SetSize(w - 24, h)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(w - 24, 1)
    sf:SetScrollChild(child)
    -- WoWClearance's list box: dark tooltip fill, bronze edge, column
    -- labels inside the top of the box, room for the scroll bar on the right.
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetPoint("TOPLEFT", sf, "TOPLEFT", -6, headers and 18 or 6)
    box:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 26, -6)
    box:SetFrameLevel(math.max(0, sf:GetFrameLevel() - 1))
    box:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0, 0, 0, 0.6)
    box:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)

    local rows = {}
    local list = { frame = sf, headers = {} }

    -- Column widths are minimums. A list stretched by its anchors (a
    -- resized window) shares the extra width out in proportion.
    local widths, base = { unpack(cols) }, 0
    for _, cw in ipairs(cols) do
        base = base + cw
    end
    local function layout(r) -- a row, or nil for the header row
        local x = withIcon and (ROW + 4) or 2
        for c, cw in ipairs(widths) do
            local cell = r and r.cols[c] or not r and list.headers[c]
            if cell then
                cell:SetWidth(cw)
                if r then
                    cell:SetPoint("LEFT", x, 0)
                else
                    cell:SetPoint("BOTTOMLEFT", sf, "TOPLEFT", x, 2)
                end
            end
            x = x + cw + 4
        end
    end
    sf:SetScript("OnSizeChanged", function(_, width)
        child:SetWidth(width)
        local k = math.max(1, (base + width - (w - 24)) / base)
        for c, cw in ipairs(cols) do
            widths[c] = math.floor(cw * k)
        end
        layout()
        for _, r in ipairs(rows) do
            layout(r)
        end
    end)

    -- Column labels. They become sort buttons once the caller sorts with
    -- list:Sort; click once to sort, again to reverse.
    if headers then
        for c in ipairs(cols) do
            if headers[c] and headers[c] ~= "" then
                local hdr = CreateFrame("Button", nil, sf)
                hdr:SetHeight(14)
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
        end
        layout()
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
        if withIcon then
            r.icon = r:CreateTexture(nil, "ARTWORK")
            r.icon:SetSize(ROW - 2, ROW - 2)
            r.icon:SetPoint("LEFT", 2, 0)
        end
        r.cols = {}
        for c in ipairs(cols) do
            r.cols[c] = Text(r)
        end
        layout(r)
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
        -- The template only hides its bar when the scroll range CHANGES, so a
        -- list that always fits would keep showing it. Decide here too.
        sf.ScrollBar:SetShown(n * ROW > sf:GetHeight())
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
f:SetResizable(true)
f:SetResizeBounds(W, H) -- every page is laid out for this size or bigger
f:SetDontSavePosition(true) -- the layout cache must not fight saveWindow
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetClampedToScreen(true)

-- Size and place, kept in the real saved table so /rlc demo keeps them too.
local POINTS = { TOPLEFT = 1, TOP = 1, TOPRIGHT = 1, LEFT = 1, CENTER = 1, RIGHT = 1 }
POINTS.BOTTOMLEFT, POINTS.BOTTOM, POINTS.BOTTOMRIGHT = 1, 1, 1
local function saveWindow()
    f:StopMovingOrSizing()
    local point, _, rel, x, y = f:GetPoint()
    if RaidLootControllerDB then
        RaidLootControllerDB.window = { w = f:GetWidth(), h = f:GetHeight(), point = point, rel = rel, x = x, y = y }
    end
end
local function restoreWindow()
    local s = RaidLootControllerDB and RaidLootControllerDB.window
    if type(s) ~= "table" then
        return
    end
    local w, h = tonumber(s.w), tonumber(s.h)
    if w and h then
        f:SetSize(math.max(W, w), math.max(H, h))
    end
    if POINTS[s.point] and POINTS[s.rel] and tonumber(s.x) and tonumber(s.y) then
        f:ClearAllPoints()
        f:SetPoint(s.point, UIParent, s.rel, s.x, s.y)
    end
end
f:SetScript("OnSizeChanged", function()
    if NS.Refresh then -- not yet while this file loads
        NS.Refresh() -- the Commands page sizes its rows when it draws
    end
end)
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", saveWindow)

ResizeGrip(f, saveWindow)
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

-- ---- copy window ------------------------------------------------------------------
-- Text to copy out of the game (a raid's results, a bug report). Opens
-- without keyboard focus so it can stay up while you play; clicking the
-- text selects all of it for one Ctrl+C. As in WoWClearance.

-- w, h: optional size; a single link needs far less than a report.
function NS.ShowCopy(title, text, w, h)
    NS.Kit.ShowCopy("RaidLootControllerCopy", title, text, w, h)
end

local pages, tabs = {}, {}
local current = "loot"

local function page(key)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 12, -66) -- input boxes draw a few px above their frame
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
    { "stats", "Stats" },
    { "catalog", "Catalogue" },
    { "commands", "Commands" },
    { "help", "Help" },
}
for i, def in ipairs(TABS) do
    local b = Button(f, def[2], 92, function()
        showPage(def[1])
    end)
    b:SetPoint("TOPLEFT", 12 + (i - 1) * 96, -30)
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
emptyText:SetPoint("TOPRIGHT", -10, -30)
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
itemName:SetPoint("TOPRIGHT", rp, "TOPRIGHT", 0, 0)
local itemInfo = Text(rp)
itemInfo:SetPoint("TOPLEFT", itemName, "BOTTOMLEFT", 0, -4)
itemInfo:SetPoint("TOPRIGHT", itemName, "BOTTOMRIGHT", 0, -4)
local specInfo = Text(rp)
specInfo:SetPoint("TOPLEFT", itemInfo, "BOTTOMLEFT", 0, -3)
specInfo:SetPoint("TOPRIGHT", itemInfo, "BOTTOMRIGHT", 0, -3)
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
local rollBtn = Button(rp, "Roll (1-100)", 110, function()
    RandomRoll(1, 100)
end)
rollBtn:SetPoint("LEFT", wantBtn, "RIGHT", 6, 0)
AddGlow(wantBtn)
AddGlow(rollBtn)

local people = List(rp, 390, 190, { 130, 150, 50 }, false, function(name)
    selPlayer = name
    NS.Refresh()
end, { "Player", "Interest", "Roll" })
people.frame:SetPoint("TOPLEFT", wantBtn, "BOTTOMLEFT", 4, -24)
people.frame:SetPoint("BOTTOMLEFT", rp, "BOTTOMLEFT", 4, 58)
people.frame:SetPoint("BOTTOMRIGHT", rp, "BOTTOMRIGHT", -26, 58)
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
admin:SetPoint("BOTTOMRIGHT", 0, 0)
admin:SetHeight(50)
local adminButtons = {}
local function adminButton(text, w, x, y, fn)
    local b = Button(admin, text, w, fn)
    b.col, b.y = x / 100, y
    adminButtons[#adminButtons + 1] = b
    return b
end
-- Four equal columns across whatever width the panel has.
admin:SetScript("OnSizeChanged", function(_, width)
    local bw = math.floor((width - 12) / 4)
    for _, b in ipairs(adminButtons) do
        b:SetWidth(bw)
        b:SetPoint("BOTTOMLEFT", b.col * (bw + 4), b.y)
    end
end)
rp:SetScript("OnSizeChanged", function(_, width)
    myInfo:SetWidth(width)
end)
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
local function classLabel(token)
    local name = GetClassInfo(Rules.CLASS_ID[token] or 0) or token
    local color = C_ClassColor.GetClassColor(token)
    return color and color:WrapTextInColorCode(name) or name
end

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
    -- Lists run down to the officer controls, or to the bottom without them.
    local qy = officer and 62 or 6
    queue.frame:SetPoint("BOTTOMLEFT", lp, "BOTTOMLEFT", 4, qy)
    local py = officer and 64 or 6
    people.frame:SetPoint("BOTTOMLEFT", rp, "BOTTOMLEFT", 4, py)
    people.frame:SetPoint("BOTTOMRIGHT", rp, "BOTTOMRIGHT", -26, py)

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
        if S.dry and S.dry[name] and not S.locks[name] then
            tags[#tags + 1] = "|cff66ff66no loot last raid|r"
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
        NS.Act("SPECS", item.key, Rules.SetToCSV(set))
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

local titleBox = NS.InputBox(rpg, 180, "Raid name (optional)")
titleBox:SetPoint("TOPLEFT", 8, -2)
titleBox:SetMaxLetters(40)
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
-- Host settings live where the host runs the raid (also on the Commands tab).
local announceBtn = Button(rpg, "Announce: off", 110, function()
    SlashCmdList.RAIDLOOTCONTROLLER("announce")
end)
announceBtn:SetPoint("RIGHT", syncBtn, "LEFT", -6, 0)

local raidHelp = Text(rpg)
raidHelp:SetPoint("TOPLEFT", 0, -30)
raidHelp:SetPoint("TOPRIGHT", 0, -30)
raidHelp:SetWordWrap(true)

-- Reserve controls.
local resLabel = Text(rpg, "GameFontNormal")
resLabel:SetPoint("TOPLEFT", 0, -62)
resLabel:SetWidth(400)
local resBox = NS.InputBox(rpg, 220, "Shift-click an item, or type its ID")
resBox:SetPoint("TOPLEFT", 8, -84)
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
players.frame:SetPoint("BOTTOMRIGHT", rpg, "BOTTOMRIGHT", -26, 62)
players.onEnter = function(row, name)
    local S = NS.S()
    local id = S and S.reserves[name]
    if id then
        ItemTooltip(row, "item:" .. id)
    else
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(NS.ColorName(name))
    end
    local v = name == NS.Me() and NS.VERSION or NS.versions[name]
    GameTooltip:AddLine("Addon: " .. (v or "not heard from yet"), 0.6, 0.6, 0.6)
    GameTooltip:Show()
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
owedText:SetWidth(600)
local owedClearBtn = Button(rpg, "Clear", 60, function()
    SlashCmdList.RAIDLOOTCONTROLLER("owed")
end)
owedClearBtn:SetPoint("BOTTOMRIGHT", 0, 0)
owedText:SetWordWrap(true)
rpg:SetScript("OnSizeChanged", function(_, width)
    owedText:SetWidth(width - 70)
end)

local function refreshRaid(S)
    local me = NS.Me()
    local canStart = not IsInGroup() or UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    titleBox:SetShown(canStart)
    newBtn:SetShown(canStart)
    local officer = NS.IsOfficer()
    beginBtn:SetShown(officer and S and S.phase == "reserve")
    endBtn:SetShown(officer and S and S.phase == "live")

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
        if Rules.VersionNewer(NS.VERSION, NS.versions[name]) then
            status = status .. " |cffff3333old addon|r"
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

    local parts, owedNames = {}, {}
    for name in pairs(NS.DB.owed) do
        owedNames[#owedNames + 1] = name
    end
    table.sort(owedNames) -- the same order on every redraw
    for _, name in ipairs(owedNames) do
        for _, s in ipairs(NS.DB.owed[name]) do
            local left = Loot.TradeTimeLeft(s)
            parts[#parts + 1] = NS.ColorName(name)
                .. ": "
                .. NS.LinkOf(s)
                .. (left and (" |cffffd100(" .. left .. " left)|r") or "")
        end
    end
    owedText:SetShown(#parts > 0)
    owedClearBtn:SetShown(#parts > 0)
    announceBtn:SetShown(NS.IsHost())
    announceBtn:SetText(NS.DB.announce and "Announce: on" or "Announce: off")
    owedText:SetText("Still to trade: " .. table.concat(parts, ", "))

    -- The list runs down to whatever is shown under it, so a raider with no
    -- officer buttons and nothing owed gets the whole height.
    local owed = #parts > 0
    local btnY = owed and 28 or 0
    lockBtn:SetPoint("BOTTOMLEFT", 0, btnY)
    local top = officer and (btnY + 22) or owed and 22 or nil
    local listY = top and (top + 12) or 6
    players.frame:SetPoint("BOTTOMLEFT", rpg, "BOTTOMLEFT", 4, listY)
    players.frame:SetPoint("BOTTOMRIGHT", rpg, "BOTTOMRIGHT", -26, listY)
end

-- ---- History page ---------------------------------------------------------------------

local hp = page("history")
local histSel

-- Officer actions (manual awards, take-backs, locks, spec changes) so the
-- raid can see who did what.
local LOG_TEXT = {
    award = "gave an item to %s",
    undo = "took back %s's win",
    lock = "locked %s",
    unlock = "unlocked %s",
    spec = "set %s's spec",
    open = "opened an item to everyone",
    cancel = "cancelled an item",
}
local function logLine(e)
    return date("%H:%M", e.t)
        .. "  "
        .. NS.ColorName(e.by)
        .. " "
        .. LOG_TEXT[e.what]:format(e.name and NS.Short(e.name) or "")
end

local raidsList = List(hp, 230, 380, { 70, 130 }, false, function(id)
    histSel = id
    NS.Refresh()
end, { "Date", "Raid" })
raidsList.frame:SetPoint("TOPLEFT", 4, -20)
raidsList.frame:SetPoint("BOTTOMLEFT", hp, "BOTTOMLEFT", 4, 4)

local histItems = List(hp, 436, 350, { 160, 100, 130 }, true, nil, { "Item", "Winner", "How" })
histItems.frame:SetPoint("TOPLEFT", 250, -20)
histItems.frame:SetPoint("BOTTOMLEFT", hp, "BOTTOMLEFT", 250, 34)
histItems.frame:SetPoint("BOTTOMRIGHT", hp, "BOTTOMRIGHT", -26, 34)
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
    local rec = histSel and NS.DB.history[histSel]
    for _, e in ipairs(rec and rec.log or {}) do
        if e.key == item.key then
            GameTooltip:AddLine(logLine(e), 1, 0.8, 0.2, true)
        end
    end
    GameTooltip:Show()
end

local logBtn = Button(hp, "Officer log", 100, nil)
logBtn:SetScript("OnEnter", function(self)
    local rec = histSel and NS.DB.history[histSel]
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Officer actions")
    local log = rec and rec.log or {}
    if #log == 0 then
        GameTooltip:AddLine("None in this raid.", 0.6, 0.6, 0.6)
    end
    for i = math.max(1, #log - 29), #log do
        GameTooltip:AddLine(logLine(log[i]), 1, 1, 1)
    end
    GameTooltip:Show()
end)
logBtn:SetScript("OnLeave", GameTooltip_Hide)

local delBtn = Button(hp, "Delete raid", 100, function()
    if histSel then
        NS.DB.history[histSel] = nil
        histSel = nil
        NS.historyGen = NS.historyGen + 1
        NS.Refresh()
    end
end)
delBtn:SetPoint("BOTTOMLEFT", 246, 0)
logBtn:SetPoint("LEFT", delBtn, "RIGHT", 6, 0)
local copyBtn = Button(hp, "Copy as text", 110, function()
    local rec = histSel and NS.DB.history[histSel]
    if rec then
        local text = Rules.HistoryText(rec, date("%d %b %Y", rec.created or 0), function(s)
            return C_Item.GetItemInfo(s) or ("item " .. (Rules.ItemIDOf(s) or "?"))
        end, NS.Short)
        NS.ShowCopy("Raid results", text)
    end
end)
copyBtn:SetPoint("LEFT", logBtn, "RIGHT", 6, 0)

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
        r.cols[3]:SetText((HOW_TEXT[item.how] or "") .. (item.delivered and " |cff00ff00delivered|r" or ""))
    end)
    delBtn:SetEnabled(rec ~= nil)
    logBtn:SetEnabled(rec ~= nil)
    copyBtn:SetEnabled(rec ~= nil)
end

-- ---- Catalogue page ---------------------------------------------------------------------
-- Every item seen drop, by instance and boss. Pick an item and Reserve it
-- while the raid is taking reserves, or shift-click it to link it in chat.

local cp = page("catalog")
local Catalog = NS.Catalog
local catBoss -- { instID, bossKey } of the selected boss
local catItem -- itemString of the selected item
local expanded = {} -- instID -> true when its bosses are listed

-- A search scans the whole catalogue, so it waits until typing pauses.
local searchTimer
local search = NS.InputBox(cp, 230, "Search all items", function()
    if searchTimer then
        searchTimer:Cancel()
    end
    searchTimer = C_Timer.NewTimer(0.25, NS.Refresh)
end)
search:SetPoint("TOPLEFT", 8, -2)
local CAT_SHOWN_MAX = 200
local catMore = Text(cp, "GameFontDisableSmall")
catMore:SetPoint("LEFT", search, "RIGHT", 10, 0)
catMore:SetText("Showing the first " .. CAT_SHOWN_MAX .. " matches. Type more to narrow it.")
catMore:Hide()

-- itemString -> lower-case name, kept once the game knows it: a search
-- reads every record, so it should not ask the item API for each again.
local lowerNames = {}
local function lowerName(s)
    local name = lowerNames[s]
    if not name then
        name = C_Item.GetItemInfo(s)
        name = name and name:lower()
        lowerNames[s] = name
    end
    return name
end

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
catItems.frame:SetPoint("BOTTOMRIGHT", cp, "BOTTOMRIGHT", -26, 58)
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
catHelp:SetPoint("BOTTOMRIGHT", 0, 4)
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
    catMore:Hide()
    if query ~= "" then
        for _, inst in pairs(cat) do
            for _, boss in pairs(inst.b) do
                for _, rec in pairs(boss.i) do
                    local name = lowerName(rec.s)
                    if name and name:find(query, 1, true) then
                        if #shown >= CAT_SHOWN_MAX then
                            catMore:Show() -- one row frame per match: keep it bounded
                        else
                            shown[#shown + 1] = { rec = rec, label = boss.name }
                        end
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

-- ---- Stats page ----------------------------------------------------------------------
-- Who has had what, over every saved raid: the check that loot is spread
-- fairly. Free rolls are counted apart, as leftovers nobody needed.

local sp = page("stats")
local statsHelp = Text(sp, "GameFontDisableSmall")
statsHelp:SetPoint("BOTTOMLEFT", 0, 4)
statsHelp:SetPoint("BOTTOMRIGHT", 0, 4)
statsHelp:SetWordWrap(true)
statsHelp:SetText(
    "From every raid in History. Raids counts the raids the addon saw a player in. "
        .. "Items leaves out free rolls. Hover a player to see what they won."
)
local statsList = List(sp, 696, 360, { 150, 60, 60, 70, 70, 110 }, false, nil, {
    "Player",
    "Raids",
    "Items",
    "Free rolls",
    "Per raid",
    "Last item",
})
statsList.frame:SetPoint("TOPLEFT", 4, -20)
statsList.frame:SetPoint("BOTTOMRIGHT", -26, 30)
statsList.onEnter = function(row, name)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(NS.ColorName(name))
    local wins = {}
    for _, rec in pairs(NS.DB.history) do
        for _, it in pairs(rec.items or {}) do
            if it.state == "done" and it.winner == name then
                wins[#wins + 1] = { t = rec.created or 0, s = it.itemString, how = it.how }
            end
        end
    end
    table.sort(wins, function(a, b)
        return a.t > b.t
    end)
    for i = 1, math.min(#wins, 20) do
        local w = wins[i]
        GameTooltip:AddDoubleLine(
            NS.LinkOf(w.s) .. (w.how == "open" and " |cff999999(free)|r" or ""),
            date("%d %b", w.t),
            1,
            1,
            1,
            0.6,
            0.6,
            0.6
        )
    end
    if #wins == 0 then
        GameTooltip:AddLine("Nothing won yet.", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

-- Worked out again only when history changes, not on every redraw (a
-- window resize redraws every frame).
-- Wants and rolls in the live raid count too, but those arrive many times a
-- second during a roll: they redo the stats at most every 3 s.
local statsCache, statsGen, statsOp, statsAt, statsLater
local function refreshStats()
    local stale = statsOp ~= NS.opGen
    if statsGen ~= NS.historyGen or (stale and GetTime() - statsAt >= 3) then
        statsCache, statsGen, statsOp, statsAt = Rules.PlayerStats(NS.DB.history), NS.historyGen, NS.opGen, GetTime()
    elseif stale and not statsLater then
        statsLater = true
        C_Timer.After(3, function()
            statsLater = false
            NS.Refresh()
        end)
    end
    local stats = statsCache
    local names = {}
    for name in pairs(stats) do
        names[#names + 1] = name
    end
    table.sort(names)
    local function perRaid(name)
        local e = stats[name]
        return e.raids > 0 and e.won / e.raids or 0
    end
    statsList:Sort(names, {
        NS.Short,
        function(name)
            return stats[name].raids
        end,
        function(name)
            return stats[name].won
        end,
        function(name)
            return stats[name].free
        end,
        perRaid,
        function(name)
            return stats[name].last
        end,
    })
    statsList:Set(#names, function(r, i)
        local name, e = names[i], stats[names[i]]
        r.data = name
        r.cols[1]:SetText(NS.ColorName(name))
        r.cols[2]:SetText(e.raids)
        r.cols[3]:SetText(e.won)
        r.cols[4]:SetText(e.free > 0 and e.free or "")
        r.cols[5]:SetText(string.format("%.2f", perRaid(name)))
        r.cols[6]:SetText(e.last > 0 and date("%d %b %Y", e.last) or "|cff999999never|r")
    end)
end

-- ---- refresh -------------------------------------------------------------------------

local pendingRefresh = false
local lastActive

-- ---- Commands page --------------------------------------------------------------------
-- Every /rlc command with its own button, as WoWClearance does. Only the
-- commands that can do something for you right now are listed, so the page
-- follows your role in the raid. The list lives in NS.Commands (Core).

local cmdPage = page("commands")
local cmdScroll = CreateFrame("ScrollFrame", nil, cmdPage, "UIPanelScrollFrameTemplate")
cmdScroll:SetPoint("TOPLEFT", 0, 0)
cmdScroll:SetPoint("BOTTOMRIGHT", -26, 0)
local cmdChild = CreateFrame("Frame", nil, cmdScroll)
cmdChild:SetSize(600, 1)
cmdScroll:SetScrollChild(cmdChild)

local cmdHeader = Text(cmdChild, "GameFontNormal")
cmdHeader:SetPoint("TOPLEFT", 0, -4)
cmdHeader:SetWordWrap(true)

-- WoWClearance's layout: a gold rule and heading per section, then rows
-- with the Run button in a column on the left and the text wrapping to
-- the right of it.
local SECTIONS = { "Everyone", "Officers", "Raid host", "Troubleshooting" }
local LABEL_X = 72
local cmdRows, cmdHeads = {}, {}

local function runCommand(c)
    if c.args then
        -- Needs an item. Opening chat from addon code would taint the chat
        -- box (and secure commands typed in it later), so just say how.
        NS.Print("Type /rlc %s in chat, then shift-click an item (or type its item ID) and press Enter.", c.cmd)
    else
        c.fn("")
        NS.Refresh()
    end
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
end

local function refreshCommands()
    local width = cmdScroll:GetWidth()
    cmdChild:SetWidth(width)
    cmdHeader:SetWidth(width)
    cmdHeader:SetText(
        "You are: |cffffd870"
            .. NS.RoleName()
            .. "|r. These are the commands you can use right now. "
            .. "Run does it; How tells you what to type for commands that need an item."
    )
    local y = -4 - cmdHeader:GetStringHeight() - 6
    for _, section in ipairs(SECTIONS) do
        local head = cmdHeads[section]
        if not head then
            head = {
                rule = cmdChild:CreateTexture(nil, "ARTWORK"),
                text = Text(cmdChild, "GameFontNormal"),
            }
            head.rule:SetColorTexture(0.4, 0.35, 0.25, 0.8)
            head.rule:SetHeight(1)
            head.text:SetText("|cffffd870" .. section .. "|r")
            cmdHeads[section] = head
        end
        local any = false
        for i, c in ipairs(NS.Commands) do
            local row = cmdRows[i]
            if not row then
                row = {
                    btn = Button(cmdChild, "Run", 64, function()
                        runCommand(c)
                    end),
                    label = Text(cmdChild),
                }
                row.btn:SetHeight(20)
                row.label:SetWordWrap(true)
                row.label:SetSpacing(2)
                cmdRows[i] = row
            end
            local show = c.section == section and NS.CommandAvailable(c)
            if show then
                if not any then
                    y = y - 12
                    head.rule:SetPoint("TOPLEFT", 0, y)
                    head.rule:SetWidth(width - 16)
                    head.text:SetPoint("TOPLEFT", LABEL_X, y - 6)
                    y = y - 6 - head.text:GetStringHeight() - 8
                    any = true
                end
                local state = c.state and (c.state() and " |cff00ff00(on)|r" or " |cff999999(off)|r") or ""
                row.label:SetWidth(width - LABEL_X - 16)
                row.label:SetText(
                    "|cffffff00/rlc " .. c.cmd .. (c.args and (" " .. c.args) or "") .. "|r  " .. c.text .. state
                )
                row.label:SetPoint("TOPLEFT", LABEL_X, y - 4)
                row.btn:SetText(c.args and "How" or "Run")
                row.btn:SetPoint("TOPLEFT", 0, y)
                y = y - math.max(20, row.label:GetStringHeight() + 4) - 8
            end
            if c.section == section then
                row.btn:SetShown(show)
                row.label:SetShown(show)
            end
        end
        head.rule:SetShown(any)
        head.text:SetShown(any)
    end
    cmdChild:SetHeight(-y + 8)
end

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
    elseif current == "commands" then
        refreshCommands()
    elseif current == "stats" then
        refreshStats()
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

local restored = false
function NS.Show()
    if not restored then
        restored = true
        restoreWindow()
    end
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

local mmButton
local function createMinimapButton()
    -- Not created at all when hidden: parenting a frame to the minimap is
    -- itself what some minimap replacements react badly to.
    if mmButton or NS.DB.minimapButton == false then
        return
    end
    mmButton = NS.Kit.MinimapButton({
        name = "RaidLootControllerMinimapButton",
        icon = 133639, -- inv_misc_bag_10, same as the .toc icon
        db = NS.DB,
        key = "minimapAngle",
        angle = 145, -- WoWClearance's sits at 190: keep them apart
        onClick = function(_, button)
            if button == "RightButton" then
                current = "catalog"
                NS.Show()
            else
                NS.Toggle()
            end
        end,
        onEnter = function(self)
            local lines, S = {}, NS.S()
            if S then
                lines[1] = (S.title or "") .. " - " .. (PHASE_TEXT[S.phase] or "")
                local item = S.active and S.items[S.active]
                if item then
                    lines[2] = "Up now: " .. NS.LinkOf(item.itemString)
                end
            end
            NS.Kit.MinimapTooltip(
                self,
                "Raid Loot Controller",
                "ff8800",
                lines,
                "Left-click: open  |  Right-click: catalogue  |  Drag: move"
            )
        end,
    })
    AddGlow(mmButton, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    mmButton.SetGlow(myTurn(NS.S()) ~= nil)
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
