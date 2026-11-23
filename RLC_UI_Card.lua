-- RLC_UI_Card.lua
-- The roll card: a small window that pops up when an item goes up for
-- interest or rolls, and stays until a few seconds after the win. It shows
-- the item, a timer bar for the host's minimum waits, where the roll
-- stands, and everyone in it, best roll first, with the winner lit, their
-- wins this raid, and those still to roll dimmed.
-- Loads after RLC_UI.lua, which calls UI.card(S) on every redraw, with the
-- main window open or not. /rlc card turns it off.
local _, NS = ...
local Rules = NS.Rules
local UI = NS.UI
local Text, Button, Tip = UI.Text, UI.Button, UI.Tip

local W = 320
local PAD = 10
local ICON = 36
local ROWS = 8 -- players listed; the rest show as "and N more"
local ROW_H = 18
local BAR_W = 60 -- a row's roll bar at 100
local LINGER = 8 -- seconds the card stays up after the win
local FADE = 0.18 -- seconds to fade in or out
local GOLD = { 1, 0.82, 0 }
local BAR_COLOR = {
    interest = { 1, 0.82, 0 },
    rolling = { 0.25, 0.85, 0.35 },
    done = { 1, 0.82, 0 },
}

local card = CreateFrame("Frame", "RaidLootControllerCard", UIParent, "BackdropTemplate")
card:SetSize(W, 160)
card:SetPoint("TOP", UIParent, "TOP", 0, -140)
card:SetFrameStrata("HIGH")
card:SetClampedToScreen(true)
card:SetMovable(true)
card:SetDontSavePosition(true) -- the layout cache must not fight the saved spot
card:EnableMouse(true)
card:RegisterForDrag("LeftButton")
card:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
card:SetBackdropColor(0.04, 0.04, 0.06, 0.94)
card:Hide()
UI.cardFrame = card -- for tests/test_load.lua

-- Where the player dragged it, kept in the real saved table (not the demo's).
-- Pinned by its top edge in the upper half of the screen and by its bottom
-- edge in the lower half, so it grows away from the screen edge.
card:SetScript("OnDragStart", card.StartMoving)
card:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local left, top, bottom = self:GetLeft(), self:GetTop(), self:GetBottom()
    local height = UIParent:GetHeight()
    if not (RaidLootControllerDB and left and top and bottom and height) then
        return
    end
    local low = (top + bottom) / 2 < height / 2
    local point = low and "BOTTOMLEFT" or "TOPLEFT"
    RaidLootControllerDB.card = { point = point, rel = "BOTTOMLEFT", x = left, y = low and bottom or top }
    self:ClearAllPoints()
    self:SetPoint(point, UIParent, "BOTTOMLEFT", left, low and bottom or top)
end)
local placed = false
local function place()
    placed = true
    local s = RaidLootControllerDB and RaidLootControllerDB.card
    if type(s) == "table" and type(s.point) == "string" and tonumber(s.x) and tonumber(s.y) then
        card:ClearAllPoints()
        card:SetPoint(s.point, UIParent, type(s.rel) == "string" and s.rel or s.point, s.x, s.y)
    end
end

-- ---- head: item, state ---------------------------------------------------------

local icon = CreateFrame("Button", nil, card)
icon:SetSize(ICON, ICON)
icon:SetPoint("TOPLEFT", PAD, -PAD)
icon.tex = icon:CreateTexture(nil, "ARTWORK")
icon.tex:SetAllPoints()
icon:SetScript("OnEnter", function(self)
    if self.itemString then
        UI.ItemTooltip(self, self.itemString)
    end
end)
icon:SetScript("OnLeave", GameTooltip_Hide)
icon:SetScript("OnClick", function(self)
    local link = self.itemString and NS.LinkOf(self.itemString)
    if IsModifiedClick() and NS.ItemStringOf(link) then
        HandleModifiedItemClick(link)
    end
end)

local name = Text(card, "GameFontNormal")
name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -2)
name:SetPoint("RIGHT", card, "RIGHT", -28, 0)
local stateLine = Text(card)
stateLine:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)
stateLine:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)

-- Close: hides the card for this item in this state. It comes back when
-- rolls are called, and for the next item.
local dismissed = {}
local shownFor -- the dismiss key of what the card shows
local close = CreateFrame("Button", nil, card, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)
close:SetScript("OnClick", function()
    if shownFor then
        dismissed[shownFor] = true
    end
    card:Hide()
end)

-- ---- timer bar -------------------------------------------------------------------

local BAR_INNER = W - 2 * PAD
local bar = CreateFrame("StatusBar", nil, card)
bar:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -8)
bar:SetSize(BAR_INNER, 12)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
bar:SetMinMaxValues(0, 1)
local barBg = bar:CreateTexture(nil, "BACKGROUND")
barBg:SetAllPoints()
barBg:SetColorTexture(0, 0, 0, 0.6)
local barText = Text(bar, "GameFontHighlightSmall", "CENTER")
barText:SetPoint("CENTER", bar, "CENTER", 0, 0)

-- The bar drains over the host's minimum wait (Rules.INTEREST_MIN, then
-- Rules.ROLL_MIN). It is a floor, not a deadline: after it the host decides.
-- The value moves every frame; the text only when its second changes.
local timer = { total = 0, endAt = 0, during = "", after = "" }
local function drawTimer()
    local left = timer.endAt - GetTime()
    local text
    if timer.total > 0 and left > 0 then
        bar:SetValue(left / timer.total)
        text = timer.during:format(math.ceil(left))
    else
        bar:SetValue(timer.full and 1 or 0)
        text = timer.after
    end
    if text ~= timer.shown then
        timer.shown = text
        barText:SetText(text)
    end
end

-- Fades in when it shows and out when the win has lingered. alphaTo is
-- what OnUpdate moves the alpha towards; at 0 the card hides.
local alphaTo = 1
card:SetScript("OnUpdate", function(self, elapsed)
    drawTimer()
    local a = self:GetAlpha()
    if a ~= alphaTo then
        local step = elapsed / FADE
        a = alphaTo > a and math.min(alphaTo, a + step) or math.max(alphaTo, a - step)
        self:SetAlpha(a)
        if a <= 0 then
            self:Hide()
        end
    end
end)

-- ---- summary and the live list -----------------------------------------------

local summary = Text(card)
summary:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -8)
summary:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)

local rows = {}
for i = 1, ROWS do
    local r = CreateFrame("Frame", nil, card)
    r:SetSize(BAR_INNER, ROW_H)
    r:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -6 - (i - 1) * ROW_H)
    r.wash = r:CreateTexture(nil, "BACKGROUND")
    r.wash:SetAllPoints()
    r.wash:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.18)
    r.name = Text(r)
    r.name:SetPoint("LEFT", 4, 0)
    r.name:SetWidth(100)
    r.tag = Text(r, "GameFontDisableSmall")
    r.tag:SetPoint("LEFT", r.name, "RIGHT", 4, 0)
    r.tag:SetWidth(54)
    r.won = Text(r, "GameFontDisableSmall")
    r.won:SetPoint("LEFT", r.tag, "RIGHT", 4, 0)
    r.won:SetWidth(36)
    r.num = Text(r, "GameFontHighlightSmall", "RIGHT")
    r.num:SetPoint("RIGHT", -4, 0)
    r.num:SetWidth(28)
    r.barBg = r:CreateTexture(nil, "BORDER")
    r.barBg:SetPoint("RIGHT", r.num, "LEFT", -4, 0)
    r.barBg:SetSize(BAR_W, 6)
    r.barBg:SetColorTexture(1, 1, 1, 0.08)
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetPoint("LEFT", r.barBg, "LEFT")
    r.bar:SetHeight(6)
    rows[i] = r
end
local more = Text(card, "GameFontDisableSmall")

-- ---- buttons ---------------------------------------------------------------------

local function shownItem()
    local S = NS.S()
    local key = shownFor and shownFor:match("^[^\t]*\t([^\t]*)")
    return S and key and S.items[key]
end
local wantBtn = Button(card, "I want this", 110, function()
    local item = shownItem()
    if item then
        if item.wants[NS.Me()] then
            NS.Act("WANT", item.key, 0)
        else
            NS.Act("WANT", item.key, 1, NS.Loot.WornFor(item.itemString))
        end
    end
end)
local rollBtn = Button(card, "Roll (1-100)", 110, function()
    RandomRoll(1, 100)
end)
Tip(wantBtn, "Say you want this item. Click again to take it back.")
Tip(rollBtn, "Roll for this item. The same as typing /roll.")

-- ---- what to show --------------------------------------------------------------

-- The item up now, else the one just won (for LINGER seconds), else nil.
local lastKey, doneAt
local function pick(S)
    if not S or (NS.DB and NS.DB.rollCard == false) then
        lastKey, doneAt = nil, nil
        return
    end
    local item = S.active and S.items[S.active]
    if item and (item.state == "interest" or item.state == "rolling") then
        lastKey, doneAt = S.id .. "\t" .. item.key, nil
        return item
    end
    local key = lastKey and lastKey:match("^[^\t]*\t(.*)$")
    local last = key and lastKey == S.id .. "\t" .. key and S.items[key]
    if last and last.state == "done" then
        if not doneAt then
            doneAt = GetTime()
            C_Timer.After(LINGER + 0.1, NS.Refresh)
        end
        if GetTime() - doneAt < LINGER then
            return last
        end
    end
    lastKey, doneAt = nil, nil
end

-- Everyone in the roll: who wants it, rolled, or is named to roll; best
-- roll first, then by name.
local function players(item)
    local names, seen = {}, {}
    for _, set in ipairs({ item.wants, item.rolls, item.restrict or {} }) do
        for n in pairs(set) do
            if not seen[n] then
                seen[n] = true
                names[#names + 1] = n
            end
        end
    end
    table.sort(names, function(a, b)
        local ra, rb = item.rolls[a] or -1, item.rolls[b] or -1
        if ra ~= rb then
            return ra > rb
        end
        return a < b
    end)
    return names
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do
        n = n + 1
    end
    return n
end

local function summaryText(S, item, me, canRoll)
    if item.state == "done" then
        local n = item.rolls[item.winner]
        if item.winner == me then
            return "|cff00ff00You won" .. (n and (" with " .. n) or "") .. "!|r"
        end
        return NS.ColorName(item.winner) .. " won" .. (n and (" with " .. n) or "") .. "."
    elseif item.state == "interest" then
        local n = count(item.wants)
        local text = n == 0 and "Nobody has asked for it yet."
            or (n == 1 and "1 player wants it." or n .. " players want it.")
        return text .. (item.wants[me] and " |cff00ff00You want it.|r" or "")
    end
    -- Rolling: who is expected to roll is the named players, else the wanters.
    local expected = next(item.restrict or {}) and item.restrict or item.wants
    local total, rolled = 0, 0
    for n in pairs(expected) do
        total = total + 1
        rolled = rolled + (item.rolls[n] and 1 or 0)
    end
    local text
    if total == 0 then
        local n = count(item.rolls)
        text = n == 0 and "Nobody has rolled yet." or (n == 1 and "1 roll." or n .. " rolls.")
    elseif rolled == total then
        text = "Everyone rolled."
    else
        text = rolled .. " of " .. total .. " rolled. Waiting on " .. (total - rolled) .. "."
    end
    if canRoll then
        return text .. " |cff00ff00You can roll now.|r"
    elseif item.rolls[me] then
        return text .. " You rolled " .. item.rolls[me] .. "."
    end
    return text
end

local STATE_LINE = {
    interest = "|cffffd100Who wants it?|r",
    rolling = "|cff40d860Rolling|r",
    done = "|cffffd100Won|r",
}
local MODE_LINE = { normal = "", open = " - open to everyone", reserve = " - reserved" }

function UI.card(S)
    local item = pick(S)
    local key = item and (S.id .. "\t" .. item.key .. "\t" .. item.state)
    if not item or dismissed[key] then
        -- A win that has lingered fades out; anything else (turned off,
        -- closed, the session gone) goes at once.
        local lingered = not item
            and shownFor
            and shownFor:find("\tdone$")
            and S
            and not (NS.DB and NS.DB.rollCard == false)
        shownFor = nil
        if lingered and card:IsShown() then
            alphaTo = 0
        else
            card:Hide()
        end
        return
    end
    if not placed then
        place()
    end
    shownFor = key
    local me = NS.Me()
    local myClass = NS.ClassOf(me)

    icon.itemString = item.itemString
    icon.tex:SetTexture(NS.IconOf(item.itemString))
    -- Edged in the item's quality colour, once the item has loaded.
    local q = C_Item.GetItemQualityByID(item.itemString)
    local qr, qg, qb = 0.6, 0.6, 0.6
    if type(q) == "number" then
        qr, qg, qb = C_Item.GetItemQualityColor(q)
    end
    card:SetBackdropBorderColor(qr or 0.6, qg or 0.6, qb or 0.6)
    name:SetText(NS.LinkOf(item.itemString))
    stateLine:SetText(STATE_LINE[item.state] .. (MODE_LINE[item.mode] or ""))

    -- Timer: from when this client saw the item go up or its roll open.
    local up, open = UI.upFor(S, item)
    timer.full = item.state == "done"
    if item.state == "interest" then
        timer.total = item.mode == "reserve" and 0 or Rules.INTEREST_MIN
        timer.endAt = GetTime() + (timer.total - up)
        timer.during, timer.after = "Rolls can be called in %ds", "Waiting for the host to call rolls"
    elseif item.state == "rolling" then
        timer.total = Rules.ROLL_MIN
        timer.endAt = GetTime() + (timer.total - open)
        timer.during, timer.after = "The roll can close in %ds", "Waiting for the host to close the roll"
    else
        timer.total, timer.after = 0, "Done"
    end
    local c = BAR_COLOR[item.state]
    bar:SetStatusBarColor(c[1], c[2], c[3], 0.85)
    drawTimer()

    local canRoll = item.state == "rolling" and Rules.CanRoll(S, item, me, myClass)
    summary:SetText(summaryText(S, item, me, canRoll))

    -- Wins this raid, and who is still to roll (named players, else wanters).
    local won = {}
    for _, it in pairs(S.items) do
        if it.state == "done" and it.winner then
            won[it.winner] = (won[it.winner] or 0) + 1
        end
    end
    local expected = next(item.restrict or {}) and item.restrict or item.wants
    local names = players(item)
    local shown = math.min(#names, ROWS)
    for i, r in ipairs(rows) do
        local n = names[i]
        r:SetShown(i <= shown)
        if i <= shown then
            local roll = item.rolls[n]
            r.name:SetText(NS.ColorName(n))
            r.tag:SetText(
                S.reserves[n] == item.itemID and "|cff66ccffreserved|r" or (item.wants[n] and "wants it" or "")
            )
            r.num:SetText(roll and tostring(roll) or "")
            r.bar:SetShown(roll ~= nil)
            if roll then
                r.bar:SetWidth(math.max(1, BAR_W * roll / 100))
                local win = item.state == "done" and item.winner == n
                r.bar:SetColorTexture(win and GOLD[1] or 0.6, win and GOLD[2] or 0.6, win and GOLD[3] or 0.6, 0.9)
            end
            r.wash:SetShown(item.state == "done" and item.winner == n)
            -- The win shown counts towards the total once it is done.
            local w = (won[n] or 0) - ((item.state == "done" and item.winner == n) and 1 or 0)
            r.won:SetText(w > 0 and ("won " .. w) or "")
            r:SetAlpha((item.state == "rolling" and expected[n] and not roll) and 0.5 or 1)
        end
    end
    local below = rows[math.max(shown, 1)]
    more:ClearAllPoints()
    more:SetPoint("TOPLEFT", shown > 0 and below or summary, "BOTTOMLEFT", shown > 0 and 4 or 0, -4)
    more:SetText(#names > ROWS and ("and " .. (#names - ROWS) .. " more") or "")

    -- Buttons: the same rules as the Loot tab's.
    local live = item.state == "interest" or item.state == "rolling"
    local wanted = item.wants[me] ~= nil
    local showWant = live and (wanted or Rules.CanWant(S, item, me, myClass)) and true or false
    local showRoll = item.state == "rolling"
    wantBtn:SetShown(showWant)
    wantBtn:SetText(wanted and "Not interested" or "I want this")
    wantBtn:SetEnabled(wanted or not UI.needSpec(S, item, me))
    rollBtn:SetShown(showRoll)
    rollBtn:SetEnabled(canRoll and true or false)
    local anyBtn = showWant or showRoll
    wantBtn:ClearAllPoints()
    wantBtn:SetPoint("BOTTOMLEFT", PAD, PAD)
    rollBtn:ClearAllPoints()
    if showWant then
        rollBtn:SetPoint("LEFT", wantBtn, "RIGHT", 6, 0)
    else
        rollBtn:SetPoint("BOTTOMLEFT", PAD, PAD)
    end

    -- Height: head, bar, summary, the rows, "more", the buttons.
    local h = PAD + ICON + 8 + 12 + 8 + 14 + 6 + shown * ROW_H
    h = h + (#names > ROWS and 16 or 0) + (anyBtn and 30 or 4) + PAD
    card:SetHeight(h)
    if not card:IsShown() then
        card:SetAlpha(0)
    end
    alphaTo = 1
    card:Show()
end
