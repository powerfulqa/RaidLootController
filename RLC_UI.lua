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
    reserve = "|cff66ccffTaking reserves|r",
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
end

-- Scrolling list of clickable rows. `cols` is a list of column widths; an
-- optional icon goes before the first column.
local function List(parent, w, h, cols, withIcon, onClick)
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
    local list = { frame = sf }
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

for i, def in ipairs({ { "loot", "Loot" }, { "raid", "Raid" }, { "history", "History" }, { "catalog", "Catalogue" } }) do
    local b = Button(f, def[2], 100, function()
        showPage(def[1])
    end)
    b:SetPoint("TOPLEFT", 12 + (i - 1) * 104, -30)
    tabs[def[1]] = b
end

local sessionLine = Text(f, "GameFontNormalSmall", "RIGHT")
sessionLine:SetPoint("TOPRIGHT", -16, -36)
sessionLine:SetWidth(380)

-- ---- Loot page ----------------------------------------------------------------------

local lp = page("loot")
local selKey, selPlayer

local queueTitle = Text(lp, "GameFontNormal")
queueTitle:SetPoint("TOPLEFT", 0, 0)
queueTitle:SetText("Items")

local queue = List(lp, 280, 300, { 150, 90 }, true, function(item)
    selKey = item.key
    selPlayer = nil
    NS.Refresh()
end)
queue.frame:SetPoint("TOPLEFT", 4, -20)
queue.onEnter = function(row, item)
    ItemTooltip(row, item.itemString)
end

local dropHint = Text(lp, "GameFontDisableSmall")
dropHint:SetPoint("TOPLEFT", queue.frame, "BOTTOMLEFT", 0, -10)
dropHint:SetWidth(270)
dropHint:SetWordWrap(true)
dropHint:SetText("Officers: drop an item from your bags on this window, or open a loot window, to add it.")

local addLootBtn = Button(lp, "Add from loot", 130, function()
    Loot.AddFromWindow()
end)
addLootBtn:SetPoint("TOPLEFT", dropHint, "BOTTOMLEFT", 0, -6)

-- Right side: the selected item.
local rp = CreateFrame("Frame", nil, lp)
rp:SetPoint("TOPLEFT", 300, 0)
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
local myInfo = Text(rp, "GameFontNormalSmall")
myInfo:SetPoint("TOPLEFT", bigIcon, "BOTTOMLEFT", 0, -8)
myInfo:SetWidth(380)

local wantBtn = Button(rp, "I want this", 110, function()
    local S = NS.S()
    local item = S and selKey and S.items[selKey]
    if item then
        NS.Act("WANT", item.key, item.wants[NS.Me()] and 0 or 1)
    end
end)
wantBtn:SetPoint("TOPLEFT", myInfo, "BOTTOMLEFT", 0, -6)
local rollBtn = Button(rp, "Roll (1-100)", 110, Loot.Roll)
rollBtn:SetPoint("LEFT", wantBtn, "RIGHT", 6, 0)

local people = List(rp, 390, 190, { 130, 150, 50 }, false, function(name)
    selPlayer = name
    NS.Refresh()
end)
people.frame:SetPoint("TOPLEFT", wantBtn, "BOTTOMLEFT", 4, -10)

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
local startBtn = adminButton("Start", 74, 0, 26, onSel("START"))
local callBtn = adminButton("Call roll", 80, 78, 26, onSel("CALL"))
local closeBtn = adminButton("Close roll", 84, 162, 26, onSel("CLOSE"))
local openBtn = adminButton("Open to all", 92, 250, 26, onSel("OPEN"))
local classBtn = adminButton("Classes", 74, 0, 0, function()
    NS.ShowClassPicker()
end)
local awardBtn = adminButton("Give to selected", 120, 78, 0, function()
    if selKey and selPlayer then
        NS.Act("AWARD", selKey, selPlayer)
    end
end)
local cancelBtn = adminButton("Remove item", 96, 202, 0, onSel("CANCEL"))

local function classList(mask)
    local names = {}
    for id = 1, GetNumClasses() do
        if Rules.HasClass(mask, id) then
            local className, file = GetClassInfo(id)
            local color = file and C_ClassColor.GetClassColor(file)
            names[#names + 1] = color and color:WrapTextInColorCode(className) or className
        end
    end
    return table.concat(names, ", ")
end

local function refreshLoot(S)
    local order = S and S.order or {}
    if S and (not selKey or not S.items[selKey]) then
        selKey = S.active or order[#order]
    end
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
    local classes = (item.classMask and item.classMask ~= 0) and (" - " .. classList(item.classMask)) or ""
    itemInfo:SetText(stateText .. " - " .. MODE_TEXT[item.mode] .. classes)

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
    people:Set(#names, function(r, i)
        local name = names[i]
        r.data = name
        r.cols[1]:SetText(NS.ColorName(name))
        local tags = {}
        if item.wants[name] then
            tags[#tags + 1] = "wants it"
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
    classBtn:SetEnabled(not finished)
    awardBtn:SetEnabled(selPlayer ~= nil and not finished)
    cancelBtn:SetEnabled(not finished)
end

-- ---- class picker ---------------------------------------------------------------------

local picker = CreateFrame("Frame", nil, f, "BackdropTemplate")
picker:SetSize(220, 300)
picker:SetPoint("TOPLEFT", f, "TOPRIGHT", 4, -40)
picker:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
picker:Hide()
local pickerTitle = Text(picker, "GameFontNormal")
pickerTitle:SetPoint("TOP", 0, -10)
pickerTitle:SetText("Who can roll?")
local checks = {}

local function pickerMask()
    local mask = 0
    for id, cb in pairs(checks) do
        if cb:GetChecked() then
            mask = mask + Rules.ClassBit(id)
        end
    end
    return mask
end

local function setPicker(mask)
    for id, cb in pairs(checks) do
        cb:SetChecked(mask ~= 0 and Rules.HasClass(mask, id))
    end
end

local function buildPicker()
    local y = -30
    for id = 1, GetNumClasses() do
        local className, file = GetClassInfo(id)
        if className then
            local cb = CreateFrame("CheckButton", nil, picker, "UICheckButtonTemplate")
            cb:SetSize(22, 22)
            cb:SetPoint("TOPLEFT", 14, y)
            local label = Text(cb)
            label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            local color = file and C_ClassColor.GetClassColor(file)
            label:SetText(color and color:WrapTextInColorCode(className) or className)
            checks[id] = cb
            y = y - 20
        end
    end
    picker:SetHeight(-y + 74)
    local fromTip = Button(picker, "From tooltip", 96, function()
        setPicker(Loot.TooltipClassMask(picker.itemString))
    end)
    fromTip:SetPoint("BOTTOMLEFT", 10, 36)
    local any = Button(picker, "Any class", 96, function()
        setPicker(0)
    end)
    any:SetPoint("LEFT", fromTip, "RIGHT", 4, 0)
    local ok = Button(picker, "Apply", 96, function()
        if picker.key then
            NS.Act("CLASS", picker.key, pickerMask())
        end
        picker:Hide()
    end)
    ok:SetPoint("BOTTOMLEFT", 10, 10)
    local cancel = Button(picker, CANCEL, 96, function()
        picker:Hide()
    end)
    cancel:SetPoint("LEFT", ok, "RIGHT", 4, 0)
end

function NS.ShowClassPicker()
    local S = NS.S()
    local item = S and selKey and S.items[selKey]
    if not item then
        return
    end
    if not next(checks) then
        buildPicker()
    end
    picker.key, picker.itemString = item.key, item.itemString
    setPicker(item.classMask or 0)
    picker:Show()
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

local players = List(rpg, 690, 220, { 120, 230, 60, 110, 70 }, false, function(name)
    raidSel = name
    NS.Refresh()
end)
players.frame:SetPoint("TOPLEFT", 4, -116)
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
lockBtn:SetPoint("TOPLEFT", players.frame, "BOTTOMLEFT", -4, -10)
local offBtn = Button(rpg, "Make officer", 110, function()
    local S = NS.S()
    if raidSel and S then
        NS.Act("OFF", raidSel, S.officers[raidSel] and 0 or 1)
    end
end)
offBtn:SetPoint("LEFT", lockBtn, "RIGHT", 6, 0)
local owedText = Text(rpg)
owedText:SetPoint("TOPLEFT", lockBtn, "BOTTOMLEFT", 0, -8)
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
    players:Set(#names, function(r, i)
        local name = names[i]
        r.data = name
        r.cols[1]:SetText(NS.ColorName(name) .. (NS.roster[name] and "" or " |cff999999(left)|r"))
        local res = S and S.reserves[name]
        r.cols[2]:SetText(res and NS.LinkOf("item:" .. res) or "")
        r.cols[3]:SetText(won[name] and (won[name] .. " won") or "")
        local status = ""
        if S then
            status = S.locks[name] and "|cffff8800Has an item|r" or "|cff00ff00Can roll|r"
        end
        r.cols[4]:SetText(status)
        r.cols[5]:SetText(S and (S.host == name and "Host" or (S.officers[name] and "Officer")) or "")
        return name == raidSel
    end)

    lockBtn:SetShown(officer)
    lockBtn:SetEnabled(raidSel ~= nil)
    lockBtn:SetText((S and raidSel and S.locks[raidSel]) and "Unlock" or "Lock")
    offBtn:SetShown(NS.IsHost())
    offBtn:SetEnabled(raidSel ~= nil and raidSel ~= me)
    offBtn:SetText((S and raidSel and S.officers[raidSel]) and "Remove officer" or "Make officer")

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
end)
raidsList.frame:SetPoint("TOPLEFT", 4, -4)

local histItems = List(hp, 450, 350, { 190, 110, 90 }, true, nil)
histItems.frame:SetPoint("TOPLEFT", 250, -4)
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
delBtn:SetPoint("TOPLEFT", histItems.frame, "BOTTOMLEFT", -4, -10)

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
end)
tree.frame:SetPoint("TOPLEFT", 4, -30)

local catItems = List(cp, 440, 330, { 200, 130, 70 }, true, function(rec)
    if IsModifiedClick() then
        HandleModifiedItemClick(NS.LinkOf(rec.s))
        return
    end
    catItem = rec.s
    NS.Refresh()
end)
catItems.frame:SetPoint("TOPLEFT", 270, -30)
catItems.onEnter = function(row, rec)
    ItemTooltip(row, rec.s)
end

local catReserve = Button(cp, "Reserve this", 110, function()
    local id = catItem and Rules.ItemIDOf(catItem)
    if id then
        NS.Act("RES", id)
    end
end)
catReserve:SetPoint("TOPLEFT", catItems.frame, "BOTTOMLEFT", -4, -10)
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
catHelp:SetPoint("TOPLEFT", catReserve, "BOTTOMLEFT", 0, -8)
catHelp:SetWidth(440)
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
                    or ("in " .. rec.n .. " of " .. boss.kills .. " kills")
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
    if S then
        sessionLine:SetText(
            (S.title or "") .. " - host " .. NS.ColorName(S.host) .. " - " .. (PHASE_TEXT[S.phase] or "")
        )
    else
        sessionLine:SetText("|cff999999No raid session|r")
    end
    if current == "loot" then
        refreshLoot(S)
    elseif current == "raid" then
        refreshRaid(S)
    elseif current == "catalog" then
        refreshCatalog()
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
