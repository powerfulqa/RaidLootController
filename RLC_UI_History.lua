-- RLC_UI_History.lua
-- The History tab. Loads after RLC_UI.lua, which owns the window and
-- the shared widgets (NS.UI), and hands its redraw to UI.refresh.
local _, NS = ...
local Rules = NS.Rules
local UI = NS.UI
local Button, Tip, List, page = UI.Button, UI.Tip, UI.List, UI.page
local itemKey, HOW_TEXT = UI.itemKey, UI.HOW_TEXT

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
    specs = "changed an item's specs",
    officer = "made %s an officer",
    unofficer = "removed %s as officer",
    close = "closed a roll, won by %s",
    deliv = "marked %s's item delivered",
    live = "started the raid",
    ended = "ended the raid",
    bench = "put %s on the bench",
    unbench = "took %s off the bench",
}
-- rec: the raid the entry belongs to, for the item it names.
local function logLine(e, rec)
    local item = e.key and rec and rec.items and rec.items[e.key]
    local link = item and NS.LinkOf(item.itemString) or "an item"
    local who = e.name and NS.ColorName(e.name) or "?"
    local text
    if e.what == "mlgive" then
        text = "gave " .. link .. " to " .. who .. " from the loot window"
    elseif e.what == "void" then
        text = "wiped the rolls on " .. link .. " (a boss was pulled): everyone rolls again"
    else
        text = (LOG_TEXT[e.what] or "%s"):format(e.name and NS.Short(e.name) or "")
    end
    return date("%H:%M", e.t)
        .. "  "
        .. NS.ColorName(e.by)
        .. " "
        .. text
        .. (e.kept and " |cff999999(only on your copy)|r" or "")
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
-- Rolls (name -> number) as a list, highest first.
local function byRoll(rolls)
    local out = {}
    for name, n in pairs(rolls or {}) do
        out[#out + 1] = { name = name, n = n }
    end
    table.sort(out, function(a, b)
        return a.n > b.n
    end)
    return out
end

histItems.onEnter = function(row, item)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(item.itemString)
    local lines = byRoll(item.rolls)
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
    -- A win taken back: who had it, how, and the rolls then.
    local u = item.undone
    if u then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "Taken back from " .. NS.ColorName(u.winner) .. " (" .. (HOW_TEXT[u.how] or "given") .. ")",
            1,
            0.5,
            0.25,
            true
        )
        for _, l in ipairs(byRoll(u.rolls)) do
            GameTooltip:AddDoubleLine(NS.ColorName(l.name), l.n, 1, 1, 1, 0.6, 0.6, 0.6)
        end
    end
    local rec = histSel and NS.DB.history[histSel]
    for _, e in ipairs(rec and rec.log or {}) do
        if e.key == item.key then
            GameTooltip:AddLine(logLine(e, rec), 1, 0.8, 0.2, true)
        end
    end
    GameTooltip:Show()
end

local logBtn = Button(hp, "Officer log", 100, function()
    local rec = histSel and NS.DB.history[histSel]
    local lines = {}
    for _, e in ipairs(rec and rec.log or {}) do
        lines[#lines + 1] = logLine(e, rec)
    end
    NS.ShowCopy("Officer log", #lines > 0 and table.concat(lines, "\n") or "None in this raid.")
end)
logBtn:SetScript("OnEnter", function(self)
    local rec = histSel and NS.DB.history[histSel]
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Officer actions")
    local log = rec and rec.log or {}
    if #log == 0 then
        GameTooltip:AddLine("None in this raid.", 0.6, 0.6, 0.6)
    end
    for i = math.max(1, #log - 29), #log do
        GameTooltip:AddLine(logLine(log[i], rec), 1, 1, 1)
    end
    GameTooltip:Show()
end)
logBtn:SetScript("OnLeave", GameTooltip_Hide)

local delBtn = Button(hp, "Delete raid", 100, function()
    local id = histSel
    if id then
        NS.Confirm("Delete this raid from history? Stats change too.", function()
            NS.DB.history[id] = nil
            histSel = nil
            NS.historyGen = NS.historyGen + 1
            NS.Refresh()
        end)
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
Tip(delBtn, "Delete the picked raid from History. Stats change too.")
Tip(copyBtn, "Open the picked raid's results as text you can copy.")

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
        -- Hosted by someone who was not the group leader: not proof of who won.
        r.cols[2]:SetText((rec.title or "?") .. (rec.untrusted and " |cff808080(unverified)|r" or ""))
        return ids[i] == histSel
    end)
    local rec = histSel and hist[histSel]
    local shown = {}
    if rec then
        for _, key in ipairs(rec.order) do
            local item = rec.items[key]
            -- Won, removed, or a win taken back (and not given again).
            if item.state == "done" or item.state == "cancelled" or item.undone then
                shown[#shown + 1] = item
            end
        end
    end
    -- What the How column says: removed and taken-back items too.
    local function howText(item)
        if item.state == "cancelled" then
            return "|cff999999removed|r"
        elseif item.state ~= "done" then
            return "|cffff8800taken back|r"
        end
        return (HOW_TEXT[item.how] or "")
            .. (item.undone and " |cffff8800(re-given)|r" or "")
            .. (item.delivered and " |cff00ff00delivered|r" or "")
    end
    histItems:Sort(shown, {
        function(item)
            return itemKey(item.itemString)
        end,
        function(item)
            return item.winner and NS.Short(item.winner) or ""
        end,
        function(item)
            return item.state == "done" and HOW_TEXT[item.how] or item.state
        end,
    })
    histItems:Set(#shown, function(r, i)
        local item = shown[i]
        r.data = item
        r.icon:SetTexture(NS.IconOf(item.itemString))
        r.cols[1]:SetText(NS.LinkOf(item.itemString))
        r.cols[2]:SetText(item.winner and NS.ColorName(item.winner) or "|cff999999-|r")
        r.cols[3]:SetText(howText(item))
    end)
    delBtn:SetEnabled(rec ~= nil)
    logBtn:SetEnabled(rec ~= nil)
    copyBtn:SetEnabled(rec ~= nil)
end

UI.refresh.history = refreshHistory
