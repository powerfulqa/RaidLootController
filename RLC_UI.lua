-- RLC_UI.lua
-- The window, its shared widgets, the Loot and Raid pages, the next-step
-- glow that ties them together, and the minimap button. The other tabs are
-- in RLC_UI_*.lua. Plain frames from stock templates, redrawn from state on every
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

-- What a button does, shown when the mouse is over it: its label as the
-- title, then `text`. Shown on a greyed-out button too, which is when a
-- player most wants to know.
local function Tip(button, text)
    button:SetMotionScriptsWhileDisabled(true)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(self:GetText())
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
end

local AddGlow, ResizeGrip = NS.Kit.AddGlow, NS.Kit.ResizeGrip

-- ---- what the host would allow ----------------------------------------------------
-- The buttons and the breadcrumb glow follow the host's own rules (Rules.Intent),
-- so a greyed button would be refused and a glowing one is not.

-- When this client saw each item go up (interest or rolling), in server
-- time: the host times the same waits from its own copy, which is never
-- later than ours, so our waits are a little longer, never shorter.
-- up: since it went up in this mode; at: since its roll last opened.
local upSeen = {} -- session id .. "\t" .. key -> { mode, up, sig, at, n }
local function trackUp(S)
    if not S then
        return
    end
    local now = GetServerTime()
    for key, item in pairs(S.items) do
        local k = S.id .. "\t" .. key
        if item.state == "interest" or item.state == "rolling" then
            local e = upSeen[k]
            if not e or e.mode ~= item.mode then
                e = { mode = item.mode, up = now }
                upSeen[k] = e
            end
            local n = 0
            for _ in pairs(item.rolls) do
                n = n + 1
            end
            -- A call, a tie or wiped rolls (a boss pull) opens the roll again.
            local sig = item.state .. "/" .. Rules.SetToCSV(item.restrict)
            if e.sig ~= sig or n < (e.n or 0) then
                e.sig, e.at = sig, now
            end
            e.n = n
        else
            upSeen[k] = nil
        end
    end
end
-- Seconds since the item went up, and since its roll last opened.
local function upFor(S, item)
    local e = upSeen[S.id .. "\t" .. item.key]
    local now = GetServerTime()
    return e and now - e.up or 0, e and now - e.at or 0
end

-- Redraw once a wait runs out, so a greyed button lights up on time.
local laterTimer, laterAt
local function later(wait)
    if not wait or wait <= 0 then
        return
    end
    local at = GetTime() + wait
    if laterTimer and laterAt > GetTime() and laterAt <= at then
        return -- an earlier redraw is already due
    end
    if laterTimer then
        laterTimer:Cancel()
    end
    laterAt = at
    laterTimer = C_Timer.NewTimer(wait, function()
        laterTimer = nil
        NS.Refresh()
    end)
end

local function inFight()
    return C_InstanceEncounter.IsEncounterInProgress() == true
end

-- Whether a player still here and allowed asked for the item.
local function anyWanter(S, item)
    for name in pairs(item.wants) do
        local c = NS.ClassOf(name)
        if c and Rules.Eligible(S, item, name, c) then
            return true
        end
    end
    return false
end

-- Call roll: whether the host takes it now, and seconds until it is worth
-- a glow (everyone has had the interest wait to ask).
local function callState(S, item)
    if item.state ~= "interest" or inFight() then
        return false
    end
    if item.mode == "reserve" then
        return true, 0
    end
    local wait = math.max(0, Rules.INTEREST_MIN + 1 - upFor(S, item))
    return wait == 0 or item.mode ~= "normal" or anyWanter(S, item), wait
end

-- Close roll: whether the host takes it now, and seconds until it is worth
-- a glow. The same test as the host's CLOSE: the minimum roll time passed,
-- or the roll is limited to named players and all of them rolled.
local function closeState(S, item)
    if item.state ~= "rolling" then
        return false
    end
    local all, rolled = item.restrict ~= nil and next(item.restrict) ~= nil, false
    for name in pairs(item.restrict or {}) do
        local c = NS.ClassOf(name)
        if c and Rules.Eligible(S, item, name, c) and not item.rolls[name] then
            all = false
        end
    end
    for name in pairs(item.rolls) do
        local c = NS.ClassOf(name)
        rolled = rolled
            or (
                c ~= nil
                and Rules.Eligible(S, item, name, c)
                and (item.mode ~= "reserve" or S.reserves[name] == item.itemID)
            )
    end
    local _, open = upFor(S, item)
    local wait = math.max(0, Rules.ROLL_MIN + 1 - open)
    -- Nobody rolled: only a regulars-first roll closes (it opens to everyone).
    local dryOnly = item.mode == "normal" and item.restrict ~= nil and next(item.restrict) ~= nil
    for name in pairs(item.restrict or {}) do
        dryOnly = dryOnly and S.dry ~= nil and S.dry[name] == true
    end
    local ok = (rolled or dryOnly) and (all or wait == 0)
    return ok, all and 0 or wait
end

-- Open to all: refused while a reserver is here, a player without an item
-- it suits wants it, or before the interest wait.
local function openOK(S, item)
    if (item.state ~= "interest" and item.state ~= "rolling") or item.mode == "open" then
        return false
    end
    if item.mode == "reserve" then
        for name in pairs(item.restrict or {}) do
            if NS.ClassOf(name) then
                return false
            end
        end
    elseif item.mode == "normal" then
        local view = { classMask = item.classMask, mode = "normal", specs = item.specs }
        for name in pairs(item.wants) do
            local c = NS.ClassOf(name)
            if c and not S.locks[name] and Rules.Suits(S, view, name, c) then
                return false
            end
        end
    end
    return upFor(S, item) >= Rules.INTEREST_MIN + 1
end

-- Whether a roll is open: locks, specs and Who can roll wait until it closes.
local function rollOpen(S)
    local cur = S and S.active and S.items[S.active]
    return cur ~= nil and cur.state == "rolling"
end

-- I want this needs a loot spec on record for spec-limited items.
local function needSpec(S, item, me)
    return item.specs ~= nil and not item.restrict and item.mode ~= "open" and not S.specs[me]
end

local function Text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- A one-line input box with a grey hint while it is empty. onChange(box)
-- runs after every change. Escape empties it.
local function InputBox(parent, w, hintText, onChange)
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

-- Bumped whenever the game loads an item: lists that skip a rebuild must
-- still redraw once names and links arrive.
local itemInfoGen = 0

-- The dark list-box and flyout backdrop.
local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Lowest item level among a worn value ("item:1,item:2"), or nil. Kept per
-- worn value once every item in it is known: the people list redraws on
-- every roll.
local wornLevels = {}
local function wornLevel(worn)
    if not worn then
        return nil
    end
    if wornLevels[worn] then
        return wornLevels[worn]
    end
    local low, known = nil, true
    for s in worn:gmatch("[^,]+") do
        local lvl = C_Item.GetDetailedItemLevelInfo(s)
        if not lvl then
            known = false
        elseif not low or lvl < low then
            low = lvl
        end
    end
    if known then
        wornLevels[worn] = low
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
    box:SetBackdrop(BACKDROP)
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

local pages, tabs = {}, {}
local current = "loot"
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

-- Yes/No before anything that cannot be taken back. fn runs on Yes.
StaticPopupDialogs.RAIDLOOTCONTROLLER_CONFIRM = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, fn)
        fn()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}
function NS.Confirm(text, fn)
    StaticPopup_Show("RAIDLOOTCONTROLLER_CONFIRM", text, nil, fn)
end

local function page(key)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 12, -72) -- under the Next line; input boxes draw a few px above their frame
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
        b.mark:SetShown(k == key)
    end
    NS.Refresh()
end

local TABS = {
    { "loot", "Loot" },
    { "raid", "Raid" },
    { "history", "History" },
    { "stats", "Stats" },
    { "catalog", "Catalogue" },
    { "versions", "Versions" },
    { "commands", "Commands" },
    { "help", "Help" },
}
for i, def in ipairs(TABS) do
    local b = Button(f, def[2], 84, function()
        showPage(def[1])
    end)
    b:SetPoint("TOPLEFT", 12 + (i - 1) * 87, -30) -- 8 tabs across the minimum width
    AddGlow(b)
    -- A gold bar under the open tab: the locked highlight alone is too
    -- faint to tell, and a skin (DaylightUI) can flatten it away.
    b.mark = b:CreateTexture(nil, "OVERLAY")
    b.mark:SetColorTexture(1, 0.82, 0, 1)
    b.mark:SetHeight(3)
    b.mark:SetPoint("BOTTOMLEFT", 3, 0)
    b.mark:SetPoint("BOTTOMRIGHT", -3, 0)
    b.mark:Hide()
    tabs[def[1]] = b
end

-- The one next step for this player, in plain words, under the tabs.
local nextText = Text(f, "GameFontNormalSmall")
nextText:SetPoint("TOPLEFT", 16, -55)
nextText:SetPoint("TOPRIGHT", -16, -55)
NS.ShowPage = function(key)
    current = key
    NS.Show()
end

-- Sort key for an item: its name once the client has it, else its ID.
local function itemKey(itemString)
    return C_Item.GetItemInfo(itemString) or itemString
end

-- What every page builds with, in this file or its own (RLC_UI_*.lua,
-- RLC_Help.lua). Each page sets UI.refresh[its tab key] to its redraw,
-- which gets the session (or nil).
local UI = {
    Text = Text,
    Button = Button,
    Tip = Tip,
    List = List,
    InputBox = InputBox,
    ItemTooltip = ItemTooltip,
    page = page,
    itemKey = itemKey,
    HOW_TEXT = HOW_TEXT,
    refresh = {},
}
NS.UI = UI

-- Called on GET_ITEM_INFO_RECEIVED. True when a page was waiting for that
-- item (UI.itemArrived, set by the Catalogue for its search). Lists that skip
-- a rebuild redraw only for items shown or asked for (asked: NS.LinkOf),
-- not for every item load in the game.
function NS.ItemInfoArrived(itemID, asked)
    local cared = UI.itemArrived ~= nil and UI.itemArrived(itemID) or false
    if cared or asked then
        itemInfoGen = itemInfoGen + 1
    end
    return cared
end

-- ---- Loot page ----------------------------------------------------------------------

local lp = page("loot")
local selKey, selPlayer
local rowGlowKey -- the queue row that glows: the next step is on an item not selected

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
AddGlow(addLootBtn)

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
myInfo:SetWordWrap(true)

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
AddGlow(startBtn)
AddGlow(callBtn)
AddGlow(closeBtn)
Tip(addLootBtn, "Put the items in the open loot window up for rolls.")
Tip(wantBtn, "Say you want this item. Click again to take it back.")
Tip(rollBtn, "Roll for the item being rolled for. The same as typing /roll.")
Tip(startBtn, "Put this item up, so players can say they want it.")
Tip(callBtn, "Ask the players who want it to roll.")
Tip(closeBtn, "End the roll. The highest roll wins.")
Tip(openBtn, "Open this item to everyone, players who already won an item included.")
Tip(specBtn, "Choose which specs may roll for this item.")
Tip(awardBtn, "Give this item to the player picked in the list, without a roll.")
Tip(cancelBtn, "Take this item off the list. Nobody wins it.")
Tip(undoBtn, "Take the win back, so the item can be given again.")

-- Class-coloured, localized class name for a class token.
local function classLabel(token)
    local name = GetClassInfo(Rules.CLASS_ID[token] or 0) or token
    local color = C_ClassColor.GetClassColor(token)
    return color and color:WrapTextInColorCode(name) or name
end

local function specName(key)
    local spec = key and NS.Specs.BY_KEY[key]
    return spec and spec.name or "?"
end

local queueSig -- what the queue list was last built from
local function refreshLoot(S)
    local order = S and S.order or {}
    -- The queue only changes with items, states, winners, the selection, the
    -- sort or item data arriving; a want or a roll alone leaves it as it is.
    local sig = { tostring(selKey), tostring(rowGlowKey), tostring(queue.sortCol), tostring(queue.desc), itemInfoGen }
    for _, key in ipairs(order) do
        local item = S.items[key]
        sig[#sig + 1] = tostring(item) .. "=" .. item.state .. "=" .. tostring(item.winner)
    end
    sig = table.concat(sig, ";")
    if sig ~= queueSig then
        queueSig = sig
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
            if not r.SetGlow then
                AddGlow(r)
            end
            r.SetGlow(item.key == rowGlowKey)
            return item.key == selKey
        end)
    end

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
    elseif canWant and not wanted and needSpec(S, item, me) then
        myInfo:SetText("|cffff8800Pick your loot spec on the Raid tab first. Then you can ask for this item.|r")
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
    wantBtn:SetEnabled(wanted or not needSpec(S, item, me))
    rollBtn:SetShown(item.state == "rolling")
    rollBtn:SetEnabled(canRoll)

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
        if S.dry and S.dry[name] then
            tags[#tags + 1] = "|cff66ff66regular|r"
        end
        if S.locks[name] and item.winner ~= name then
            tags[#tags + 1] = "|cffff8800has an item|r"
        end
        r.cols[2]:SetText(table.concat(tags, ", "))
        r.cols[3]:SetText(item.rolls[name] and ("|cffffffff" .. item.rolls[name] .. "|r") or "")
        return name == selPlayer
    end)

    -- Greyed when the host would refuse it (Rules.Intent).
    local finished = item.state == "done" or item.state == "cancelled"
    local cur = S.active and S.items[S.active]
    local busy = cur ~= nil and cur ~= item and (cur.state == "interest" or cur.state == "rolling")
    local callOK, callWait = callState(S, item)
    local closeOK, closeWait = closeState(S, item)
    later(callWait)
    later(closeWait)
    if live then
        later(Rules.INTEREST_MIN + 1 - upFor(S, item))
    end
    startBtn:SetEnabled(item.state == "pending" and not busy)
    callBtn:SetEnabled(callOK)
    closeBtn:SetEnabled(closeOK)
    openBtn:SetEnabled(openOK(S, item))
    specBtn:SetEnabled(not finished and not rollOpen(S))
    awardBtn:SetEnabled(selPlayer ~= nil and NS.ClassOf(selPlayer) ~= nil and not finished)
    cancelBtn:SetEnabled(not finished)
    undoBtn:SetEnabled(item.state == "done" and (not item.delivered or NS.IsHost()))
end

-- ---- spec menus ------------------------------------------------------------------------
-- A home-made pop-up list. On Forever a Menu (MenuUtil) opened from addon
-- code crashes the client, and UIDropDownMenu taints; this is the
-- WoWClearance selector look. entries: { text = "...", onClick = fn,
-- checked = fn, col = true starts a new column }; an entry without onClick
-- is a heading. radio: one choice, closes after the pick. Otherwise ticks
-- stay open, and buttons without `checked` close it.

local FLY_W, FLY_H = 140, 18
local flyout = CreateFrame("Frame", "RaidLootControllerFlyout", UIParent, "BackdropTemplate")
flyout:SetFrameStrata("DIALOG") -- above the window (HIGH)
flyout:SetToplevel(true)
flyout:SetClampedToScreen(true)
flyout:EnableMouse(true)
flyout:SetBackdrop(BACKDROP)
flyout:SetBackdropColor(0, 0, 0, 0.92)
flyout.rows = {}
flyout:Hide()
-- A click anywhere outside the list and its button closes it. Not in
-- UISpecialFrames: Escape would close the main window with it.
flyout:SetScript("OnUpdate", function(self)
    if IsMouseButtonDown() and not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then
        self:Hide()
    end
end)
flyout:SetScript("OnHide", function(self)
    self.owner = nil
end)
f:HookScript("OnHide", function()
    flyout:Hide()
end)

-- Redraw the ticks (after a click, and on NS.Refresh: the host's answer).
local function flyoutSync()
    if not flyout:IsShown() then
        return
    end
    for _, r in ipairs(flyout.rows) do
        if r:IsShown() and r.entry.checked then
            local on = r.entry.checked() == true
            if flyout.radio then
                r.box:SetTexCoord(on and 0.25 or 0, on and 0.5 or 0.25, 0, 1)
            else
                r.check:SetShown(on)
            end
        end
    end
end

local function showFlyout(owner, entries, radio)
    if flyout:IsShown() and flyout.owner == owner then
        flyout:Hide()
        return
    end
    flyout.owner, flyout.radio = owner, radio
    local col, y, tall = 0, 0, 0
    for i, e in ipairs(entries) do
        local r = flyout.rows[i]
        if not r then
            r = CreateFrame("Button", nil, flyout)
            r:SetSize(FLY_W, FLY_H)
            r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            r.box = r:CreateTexture(nil, "ARTWORK")
            r.box:SetSize(16, 16)
            r.box:SetPoint("LEFT", 2, 0)
            r.check = r:CreateTexture(nil, "OVERLAY")
            r.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            r.check:SetAllPoints(r.box)
            r.text = Text(r)
            r.text:SetPoint("RIGHT", -2, 0)
            r:SetScript("OnClick", function(self)
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                if flyout.radio or not self.entry.checked then
                    flyout:Hide()
                end
                self.entry.onClick()
                flyoutSync()
            end)
            flyout.rows[i] = r
        end
        if e.col and y > 0 then
            col, y = col + 1, 0
        end
        r:SetPoint("TOPLEFT", 8 + col * FLY_W, -8 - y * FLY_H)
        y = y + 1
        tall = math.max(tall, y)
        r.entry = e
        r:EnableMouse(e.onClick ~= nil)
        r.text:SetFontObject(e.onClick and "GameFontHighlightSmall" or "GameFontNormalSmall")
        r.text:SetPoint("LEFT", e.checked and 20 or 4, 0)
        r.text:SetText(e.text)
        r.box:SetShown(e.checked ~= nil)
        r.check:Hide()
        if e.checked then
            r.box:SetTexture(radio and "Interface\\Buttons\\UI-RadioButton" or "Interface\\Buttons\\UI-CheckBox-Up")
            r.box:SetTexCoord(0, radio and 0.25 or 1, 0, 1)
        end
        r:Show()
    end
    for i = #entries + 1, #flyout.rows do
        flyout.rows[i]:Hide()
    end
    flyout:SetSize((col + 1) * FLY_W + 16, tall * FLY_H + 16)
    flyout:ClearAllPoints()
    -- Upward when it does not fit below (clamping would cover the button).
    local below = (owner:GetBottom() or 0) * owner:GetEffectiveScale()
    if below < flyout:GetHeight() * flyout:GetEffectiveScale() + 2 then
        flyout:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 0, 2)
    else
        flyout:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    end
    flyout:Show()
    flyout:Raise()
    flyoutSync()
end

-- Officers: which specs may roll for the selected item. Each tick takes
-- effect at once. "Suggested" re-runs the item rules; "Any spec" lifts the
-- limit. Ticks go to a local set while the list is open: a non-host
-- officer's item.specs changes only when the host's answer comes back, so
-- quick ticks built from it would drop each other.
function NS.ShowSpecMenu(owner)
    local S = NS.S()
    local item = S and selKey and S.items[selKey]
    if not item then
        return
    end
    local key, chosen = item.key, {}
    for k in pairs(item.specs or {}) do
        chosen[k] = true
    end
    -- A snapshot rebuilds S, so look the item up each time; gone closes the list.
    local function live()
        local now = NS.S()
        item = now and now.items[key]
        if not item then
            flyout:Hide()
        end
        return item
    end
    local function send(set)
        NS.Act("SPECS", key, Rules.SetToCSV(set))
    end
    local entries = {
        { text = "Who can roll" },
        {
            text = "Suggested for this item",
            onClick = function()
                if live() then
                    local _, csv = NS.Specs.DescribeItem(item.itemString)
                    send(Rules.CSVToSpecs(csv) or {})
                end
            end,
        },
        {
            text = "Any spec",
            onClick = function()
                if live() then
                    send({})
                end
            end,
        },
    }
    -- Specs.LIST keeps each class together; three classes to a column.
    local class, n = nil, 0
    for _, spec in ipairs(NS.Specs.LIST) do
        if spec.class ~= class then
            class, n = spec.class, n + 1
            entries[#entries + 1] = { text = classLabel(class), col = n > 1 and n % 3 == 1 }
        end
        entries[#entries + 1] = {
            text = spec.name,
            checked = function()
                return live() ~= nil and chosen[spec.key] == true
            end,
            onClick = function()
                if live() then
                    chosen[spec.key] = not chosen[spec.key] or nil
                    send(chosen)
                end
            end,
        }
    end
    showFlyout(owner, entries)
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
    local entries = { { text = NS.Short(name) .. " - spec" } }
    if name == me then
        entries[2] = {
            text = "From my talents",
            checked = function()
                return NS.DB.mySpec[me] == nil
            end,
            onClick = function()
                NS.Specs.Choose(nil)
            end,
        }
    end
    for _, spec in ipairs(NS.Specs.LIST) do
        if spec.class == token then
            entries[#entries + 1] = {
                text = spec.name,
                checked = function()
                    local S = NS.S()
                    if name == me then
                        return NS.DB.mySpec[me] == spec.key
                    end
                    return S ~= nil and S.specs[name] == spec.key
                end,
                onClick = function()
                    if name == me then
                        NS.Specs.Choose(spec.key)
                    else
                        NS.Act("SETSPEC", name, spec.key)
                    end
                end,
            }
        end
    end
    showFlyout(owner, entries, true)
end

-- ---- Raid page ----------------------------------------------------------------------

local rpg = page("raid")
local raidSel

local titleBox = InputBox(rpg, 180, "Raid name (optional)")
titleBox:SetPoint("TOPLEFT", 8, -2)
titleBox:SetMaxLetters(40)
local newBtn = Button(rpg, "New raid", 90, function()
    local function start()
        NS.NewSession(titleBox:GetText() or "")
        titleBox:ClearFocus()
    end
    local S = NS.S()
    if S and S.phase ~= "ended" then
        NS.Confirm("Start a new raid? The raid running now ends for everyone.", start)
    else
        start()
    end
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
AddGlow(newBtn)
AddGlow(beginBtn)
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
local resBox = InputBox(rpg, 220, "Shift-click an item, or type its ID")
resBox:SetPoint("TOPLEFT", 8, -84)
local function doReserve()
    local text = resBox:GetText() or ""
    local id = NS.ItemIDFrom(text)
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
-- A soft glow on the reserve box: reserving is a choice, not a must.
local resGlow = CreateFrame("Frame", nil, rpg)
resGlow:SetPoint("TOPLEFT", resBox, "TOPLEFT", -6, 2)
resGlow:SetPoint("BOTTOMRIGHT", resBtn, "BOTTOMRIGHT", 2, -2)
resGlow:SetAlpha(0.5)
AddGlow(resGlow)

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
mySpecLabel:SetWordWrap(true)
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

-- Who rolls first tonight, and who is on the bench.
local firstText = Text(rpg)
firstText:SetPoint("TOPLEFT", 0, -112)
firstText:SetPoint("TOPRIGHT", 0, -112)

local players = List(rpg, 690, 205, { 110, 90, 150, 50, 120, 70 }, false, function(name)
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

-- Officers: mark players from recent raids who are not in the group as
-- bench (standby) tonight. Bench counts as being there for attendance.
local BENCH_RAIDS, BENCH_MAX = 8, 45
local function showBenchMenu(owner)
    local S = NS.S()
    if not S then
        return
    end
    local ids = {}
    for id, rec in pairs(NS.DB.history) do
        if id ~= S.id and rec.started then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids, function(a, b)
        return (NS.DB.history[a].created or 0) > (NS.DB.history[b].created or 0)
    end)
    local cand = {}
    for name in pairs(S.bench or {}) do
        cand[name] = true
    end
    for i = 1, math.min(#ids, BENCH_RAIDS) do
        local rec = NS.DB.history[ids[i]]
        for name in pairs(Rules.SeenIn(rec)) do
            cand[name] = true
        end
        for name in pairs(rec.att or {}) do
            cand[name] = true
        end
    end
    local names = {}
    for name in pairs(cand) do
        if not NS.roster[name] or (S.bench and S.bench[name]) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local entries = { { text = "Bench tonight" } }
    if #names == 0 then
        entries[2] = { text = "|cff999999Nobody from recent raids is missing.|r" }
    end
    for i = 1, math.min(#names, BENCH_MAX) do
        local name = names[i]
        entries[#entries + 1] = {
            text = NS.ColorName(name),
            col = i > 1 and (i - 1) % 15 == 0,
            checked = function()
                local now = NS.S()
                return now ~= nil and now.bench ~= nil and now.bench[name] == true
            end,
            onClick = function()
                local now = NS.S()
                NS.Act("BENCH", name, (now and now.bench and now.bench[name]) and 0 or 1)
            end,
        }
    end
    showFlyout(owner, entries)
end
local benchBtn = Button(rpg, "Bench...", 90, function(self)
    showBenchMenu(self)
end)
benchBtn:SetPoint("LEFT", setSpecBtn, "RIGHT", 6, 0)
local owedText = Text(rpg)
owedText:SetPoint("BOTTOMLEFT", 0, 4)
owedText:SetWidth(600)
local owedClearBtn = Button(rpg, "Clear list", 80, function()
    NS.Confirm("Clear the whole still-to-trade list?", function()
        SlashCmdList.RAIDLOOTCONTROLLER("owed")
    end)
end)
owedClearBtn:SetPoint("BOTTOMRIGHT", 0, 0)
owedText:SetWordWrap(true)
owedText:SetMaxLines(2)
Tip(newBtn, "Start a new raid and open it for reserves. For the group leader and assistants.")
Tip(beginBtn, "Close reserves and start handing out loot.")
Tip(endBtn, "End the raid. It stays in History.")
Tip(syncBtn, "Ask the host for the raid again, if your window looks out of date.")
Tip(announceBtn, "Announce items, rolls and winners in raid chat.")
Tip(resBtn, "Reserve the item in the box.")
Tip(unresBtn, "Take your reserve back.")
Tip(mySpecBtn, "Pick the spec you want loot for.")
Tip(confirmSpecBtn, "Confirm the spec read from your talents as your loot spec.")
Tip(lockBtn, "A player who won an item is locked out of normal rolls. This sets or lifts that for the picked player.")
Tip(offBtn, "Let the picked player run loot with you, or take that back.")
Tip(setSpecBtn, "Set the picked player's loot spec for them.")
Tip(benchBtn, "Mark players as on the bench. They count as there for attendance.")
Tip(owedClearBtn, "Empty the list of items still to trade.")
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
    -- Reserves close at the first item on the list.
    local resOpen = reserving and next(S.items) == nil
    resBox:SetShown(reserving)
    resBtn:SetShown(reserving)
    resBtn:SetEnabled(resOpen)
    unresBtn:SetShown(reserving and mine ~= nil)
    unresBtn:SetEnabled(resOpen)

    local function colored(set)
        local out = {}
        for name in pairs(set or {}) do
            out[#out + 1] = name
        end
        table.sort(out)
        for i, name in ipairs(out) do
            out[i] = NS.ColorName(name)
        end
        return out
    end
    local first, bench = colored(S and S.dry), colored(S and S.bench)
    local firstLine = ""
    if S and S.phase ~= "reserve" then
        firstLine = "Regulars roll first tonight: "
            .. (#first > 0 and table.concat(first, ", ") or "|cff999999nobody yet (not enough past raids)|r")
    end
    if #bench > 0 then
        firstLine = "Bench: " .. table.concat(bench, ", ") .. (firstLine ~= "" and ".  " or "") .. firstLine
    end
    firstText:SetText(firstLine)

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
        for name in pairs(S.bench or {}) do
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
        local away = (S and S.bench and S.bench[name]) and " |cff66ccff(bench)|r" or " |cff999999(left)|r"
        r.cols[1]:SetText(NS.ColorName(name) .. (NS.roster[name] and "" or away))
        local res = S and S.reserves[name]
        local spec = S and S.specs[name]
        r.cols[2]:SetText(spec and specName(spec) or "|cff999999-|r")
        r.cols[3]:SetText(res and NS.LinkOf("item:" .. res) or "")
        r.cols[4]:SetText(won[name] and (won[name] .. " won") or "")
        local status = ""
        if S then
            status = S.locks[name] and "|cffff8800Has an item|r" or "|cff00ff00Can roll|r"
            if S.dry and S.dry[name] then
                status = status .. ", |cff66ff66regular|r"
            end
        end
        if Rules.VersionNewer(NS.VERSION, NS.versions[name]) then
            status = status .. " |cffff3333old addon|r"
        end
        r.cols[5]:SetText(status)
        r.cols[6]:SetText(S and (S.host == name and "Host" or (S.officers[name] and "Officer")) or "")
        return name == raidSel
    end)

    -- Locks and specs wait until an open roll is closed (the host refuses).
    local rolling = rollOpen(S)
    lockBtn:SetShown(officer)
    lockBtn:SetEnabled(raidSel ~= nil and not rolling)
    benchBtn:SetShown(officer and S.phase ~= "ended")
    lockBtn:SetText((S and raidSel and S.locks[raidSel]) and "Unlock" or "Lock")
    offBtn:SetShown(NS.IsHost())
    offBtn:SetEnabled(raidSel ~= nil and raidSel ~= me)
    offBtn:SetText((S and raidSel and S.officers[raidSel]) and "Remove officer" or "Make officer")
    setSpecBtn:SetShown(officer)
    setSpecBtn:SetEnabled(raidSel ~= nil and not rolling)

    -- Own spec: what we would report, and what the raid has on record.
    local mySpec, picked = NS.Specs.Mine()
    local onRecord = S and S.specs[me]
    local line = "Your loot spec: "
        .. (mySpec and specName(mySpec) or "|cffff8800unknown, pick one|r")
        .. (mySpec and (picked and " (confirmed)" or " |cffff8800(from talents: confirm it)|r") or "")
    confirmSpecBtn:SetShown(mySpec ~= nil and not picked)
    if onRecord and onRecord ~= mySpec then
        line = line .. "\n|cffff8800Raid has you as " .. specName(onRecord) .. " (locked).|r"
    end
    mySpecLabel:SetText(line)

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
    local btnY = owed and 40 or 0
    lockBtn:SetPoint("BOTTOMLEFT", 0, btnY)
    local top = officer and (btnY + 22) or owed and 22 or nil
    local listY = top and (top + 12) or 6
    players.frame:SetPoint("BOTTOMLEFT", rpg, "BOTTOMLEFT", 4, listY)
    players.frame:SetPoint("BOTTOMRIGHT", rpg, "BOTTOMRIGHT", -26, listY)
end

-- ---- refresh -------------------------------------------------------------------------

local pendingRefresh = false
local lastActive

-- ---- next step (breadcrumbs) ------------------------------------------------------------
-- Exactly one thing glows per player: the click the raid is waiting on from
-- them. On another tab, that tab's button glows; with the window shut, the
-- minimap button. Same rules as the host's (Rules.Intent), so it never
-- leads to a refusal. Returns { id, tab, text, key, soft } or nil.

local START_AFTER = 1800 -- seconds after New raid before Start raid glows outside an instance

local function inRaidInstance()
    local _, kind = GetInstanceInfo()
    return NS.CanRead(kind) and kind == "raid"
end

local function myStep(S)
    local me = NS.Me()
    local live = S ~= nil and S.phase ~= "ended"
    local item = live and S.active and S.items[S.active] or nil
    local myClass = NS.ClassOf(me)

    -- An item waiting on this player.
    if item and item.state == "rolling" and Rules.CanRoll(S, item, me, myClass) then
        return { id = "roll", tab = "loot", key = item.key, text = "Next: click Roll (1-100)." }
    end
    if item and item.state == "interest" and not item.wants[me] and Rules.CanWant(S, item, me, myClass) then
        if needSpec(S, item, me) then
            return {
                id = "spec",
                tab = "raid",
                text = "Next: pick your loot spec on the Raid tab, then ask for the item.",
            }
        end
        return { id = "want", tab = "loot", key = item.key, text = "Next: click I want this if you can use the item." }
    end

    -- Officers run the loot.
    if live and NS.IsOfficer() then
        if item and item.state == "rolling" then
            local ok, wait = closeState(S, item)
            if ok and wait == 0 then
                return { id = "close", tab = "loot", key = item.key, text = "Next: click Close roll." }
            end
            later(wait)
        elseif item and item.state == "interest" then
            local ok, wait = callState(S, item)
            if ok and wait == 0 then
                return { id = "call", tab = "loot", key = item.key, text = "Next: click Call roll." }
            end
            later(wait)
        end
        local n = Loot.lootOpen and Loot.PendingFromWindow() or 0
        if n > 0 then
            return { id = "add", tab = "loot", text = "Next: click Add " .. n .. " from loot." }
        end
        if not (item and (item.state == "interest" or item.state == "rolling")) then
            local sel = selKey and S.items[selKey]
            local key = sel and sel.state == "pending" and selKey or nil
            for _, k in ipairs(S.order) do
                key = key or (S.items[k].state == "pending" and k or nil)
            end
            if key then
                return { id = "start", tab = "loot", key = key, text = "Next: pick a waiting item and click Start." }
            end
        end
    end

    -- The host starts the raid in the instance (or after a while).
    if live and NS.IsHost() and S.phase == "reserve" then
        local wait = START_AFTER - (GetServerTime() - (S.created or 0))
        if inRaidInstance() or wait <= 0 then
            return {
                id = "begin",
                tab = "raid",
                text = "Next: click Start raid when the raid begins. Reserves close then.",
            }
        end
        later(wait)
    end
    if not live and IsInRaid() and UnitIsGroupLeader("player") then
        return { id = "new", tab = "raid", text = "Next: click New raid to start a loot session." }
    end

    -- Your loot spec: confirmed before the start, or at least known.
    if live then
        local mine, picked = NS.Specs.Mine()
        if S.phase == "reserve" and mine and not picked then
            return {
                id = "confirm",
                tab = "raid",
                text = "Next: click Confirm if that is the spec you want gear for, or Change loot spec.",
            }
        elseif
            not mine
            and (
                S.phase == "reserve" and next(S.items) == nil
                or not S.specs[me] and not rollOpen(S) and not (item and (item.wants[me] or item.rolls[me]))
            )
        then
            return {
                id = "spec",
                tab = "raid",
                text = "Next: click Change loot spec and pick the spec you want gear for.",
            }
        end
        -- Reserving is optional: a soft glow, and not on the minimap.
        if S.phase == "reserve" and next(S.items) == nil and not S.reserves[me] and picked then
            return {
                id = "reserve",
                tab = "raid",
                soft = true,
                text = "Next: reserve the one item you want most, if you like (optional).",
            }
        end
    end
end

-- Steps -> the button that glows when its tab is shown.
local STEP_BUTTON = {
    want = wantBtn,
    roll = rollBtn,
    close = closeBtn,
    call = callBtn,
    add = addLootBtn,
    start = startBtn,
    begin = beginBtn,
    new = newBtn,
    spec = mySpecBtn,
    confirm = confirmSpecBtn,
    reserve = resGlow,
}
local glowing -- the frame glowing now
local function glowOnly(target)
    if glowing ~= target then
        if glowing then
            glowing.SetGlow(false)
        end
        if target then
            target.SetGlow(true)
        end
        glowing = target
    end
end

local mmButton
UI.refresh.loot, UI.refresh.raid = refreshLoot, refreshRaid

local function refreshNow()
    pendingRefresh = false
    if not NS.DB then
        return
    end
    local S = NS.S()
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
    if S and (not selKey or not S.items[selKey]) then
        selKey = S.active or S.order[#S.order]
    end
    trackUp(S)
    local step = myStep(S)
    if mmButton then
        mmButton.SetGlow(step ~= nil and not step.soft)
    end
    if not f:IsShown() then
        glowOnly(nil)
        return
    end
    -- The step's button, or its item's row when another item is selected,
    -- or its tab when another tab is shown.
    local target
    rowGlowKey = nil
    if step and step.tab ~= current then
        target = tabs[step.tab]
    elseif step and step.key and step.key ~= selKey then
        rowGlowKey = step.key
    elseif step then
        target = STEP_BUTTON[step.id]
    end
    glowOnly(target)
    nextText:SetText(step and step.text or "")
    -- The session's status lives in the title, so the tab row has room.
    if S then
        f:SetTitle("Raid Loot Controller - " .. (S.title or "") .. " - " .. (PHASE_TEXT[S.phase] or ""))
    else
        f:SetTitle("Raid Loot Controller")
    end
    local draw = UI.refresh[current]
    if draw then -- nil only if that page's file failed to load, which has thrown its own error
        draw(S)
    end
    flyoutSync()
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

-- The standard minimap-button library, when another addon (Leatrix Plus,
-- a button bag) has loaded it. RLC ships no libraries, but such collectors
-- wrap any other button with a "custom button" notice in place of our
-- tooltip. So with the library present the button is registered through
-- it (the WoWClearance pattern), and the kit button is the fallback.
local function dbIcon()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local lib = LibStub and LibStub("LibDBIcon-1.0", true)
    return LDB and lib, LDB
end

-- The library reads and writes position and hidden state in this table.
-- It stays empty, so both map onto RLC's own saved fields (and follow the
-- demo's swapped NS.DB).
local iconDB = setmetatable({}, {
    __index = function(_, k)
        if k == "minimapPos" then
            return NS.DB.minimapAngle or 145
        elseif k == "hide" then
            return NS.DB.minimapButton == false
        end
    end,
    __newindex = function(_, k, v)
        if k == "minimapPos" and type(v) == "number" then
            NS.DB.minimapAngle = v
        elseif k == "hide" then
            NS.DB.minimapButton = not v
        end
    end,
})

local function onMinimapClick(_, button)
    if button == "RightButton" then
        current = "catalog"
        NS.Show()
    else
        NS.Toggle()
    end
end

local function onMinimapEnter(self)
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
end

local function createMinimapButton()
    -- Not created at all when hidden: parenting a frame to the minimap is
    -- itself what some minimap replacements react badly to.
    if mmButton or NS.DB.minimapButton == false then
        return
    end
    local lib, LDB = dbIcon()
    if lib then
        local obj = LDB:GetDataObjectByName("RaidLootController")
            or LDB:NewDataObject("RaidLootController", {
                type = "launcher",
                label = "Raid Loot Controller",
                icon = 133639,
                OnClick = onMinimapClick,
                OnEnter = onMinimapEnter,
                OnLeave = GameTooltip_Hide,
            })
        lib:Register("RaidLootController", obj, iconDB)
        mmButton = lib:GetMinimapButton("RaidLootController")
    end
    if not mmButton then
        mmButton = NS.Kit.MinimapButton({
            name = "RaidLootControllerMinimapButton",
            icon = 133639, -- inv_misc_bag_10, same as the .toc icon
            db = NS.DB,
            key = "minimapAngle",
            angle = 145, -- WoWClearance's sits at 190: keep them apart
            onClick = onMinimapClick,
            onEnter = onMinimapEnter,
        })
    end
    AddGlow(mmButton, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    NS.Refresh() -- sets its glow
end

function NS.SetMinimapButton(show)
    NS.DB.minimapButton = show
    if show then
        createMinimapButton()
    end
    local lib = dbIcon()
    if lib and lib:GetMinimapButton("RaidLootController") then
        if show then
            lib:Show("RaidLootController")
        else
            lib:Hide("RaidLootController")
        end
    elseif mmButton then
        mmButton:SetShown(show)
    end
end

NS.On("PLAYER_LOGIN", createMinimapButton)
-- The minimap button pulses while this player has a next step (refreshNow),
-- so a player who closed the window still sees it. A boss fight greys
-- Call roll, and the leader gets New raid on joining a raid.
NS.On("ENCOUNTER_START", NS.Refresh)
NS.On("ENCOUNTER_END", NS.Refresh)
NS.On("PARTY_LEADER_CHANGED", NS.Refresh)
