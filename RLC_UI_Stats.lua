-- RLC_UI_Stats.lua
-- The Stats tab. Loads after RLC_UI.lua, which owns the window and
-- the shared widgets (NS.UI), and hands its redraw to UI.refresh.
local _, NS = ...
local Rules = NS.Rules
local UI = NS.UI
local Text, List, page = UI.Text, UI.List, UI.page
-- Who has had what, over every saved raid: the check that loot is spread
-- fairly. Free rolls are counted apart, as leftovers nobody needed.

local sp = page("stats")
local statsHelp = Text(sp, "GameFontDisableSmall")
statsHelp:SetPoint("BOTTOMLEFT", 0, 4)
statsHelp:SetPoint("BOTTOMRIGHT", 0, 4)
statsHelp:SetWordWrap(true)
statsHelp:SetText(
    "Raids: raids a player was there for (most of the raid, or on the bench), out of raids with "
        .. Rules.MIN_ATTEND
        .. " or more players. Regulars came to most recent raids and roll first. "
        .. "Items leaves out free rolls. Hover a player to see what they won."
)
local statsList = List(sp, 696, 360, { 140, 45, 45, 60, 45, 60, 55, 90 }, false, nil, {
    "Player",
    "Raids",
    "Att %",
    "Regular",
    "Items",
    "Free rolls",
    "Per raid",
    "Last item",
})

-- Attendance over saved raids: name -> raids present (Rules.Present, bench
-- counts), and how many raids count at all (started, trusted, MIN_ATTEND
-- present in person). The live raid counts once it has started.
local function attendance(history)
    local att, counting = {}, 0
    for _, rec in pairs(history or {}) do
        if rec.started and not rec.untrusted then
            local cand = Rules.SeenIn(rec)
            for _, set in ipairs({ rec.att or {}, rec.bench or {} }) do
                for name in pairs(set) do
                    cand[name] = true
                end
            end
            local here, n = {}, 0
            for name in pairs(cand) do
                if Rules.Present(rec, name) then
                    -- The bench counts as present, but not toward MIN_ATTEND.
                    here[#here + 1] = name
                    n = n + ((rec.bench and rec.bench[name]) and 0 or 1)
                end
            end
            if n >= Rules.MIN_ATTEND then
                counting = counting + 1
                for _, name in ipairs(here) do
                    att[name] = (att[name] or 0) + 1
                end
            end
        end
    end
    return att, counting
end
statsList.frame:SetPoint("TOPLEFT", 4, -20)
statsList.frame:SetPoint("BOTTOMRIGHT", -26, 30)
statsList.onEnter = function(row, name)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(NS.ColorName(name))
    local wins = NS.Wins().byPlayer[name] or {}
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

-- Worked out again only when history changes, not on every redraw (any op
-- or roster change redraws the open tab).
-- Wants and rolls in the live raid count too, but those arrive many times a
-- second during a roll: they redo the stats at most every 3 s.
local statsCache, statsGen, statsOp, statsAt, statsLater
local attCache, attRaids, regulars = {}, 0, {}
local function refreshStats()
    local stale = statsOp ~= NS.opGen
    if statsGen ~= NS.historyGen or (stale and GetTime() - statsAt >= 3) then
        statsCache, statsGen, statsOp, statsAt = Rules.PlayerStats(NS.DB.history), NS.historyGen, NS.opGen, GetTime()
        attCache, attRaids = attendance(NS.DB.history)
        regulars = {}
        for _, name in ipairs(NS.DryLastRaid()) do
            regulars[name] = true
        end
        for name in pairs(attCache) do
            statsCache[name] = statsCache[name] or { raids = 0, won = 0, free = 0, last = 0 }
        end
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
    -- Items per raid: over raids attended, or raids seen in when that is
    -- more (wins in small raids that do not count for attendance).
    local function raids(name)
        return attCache[name] or 0
    end
    local function perRaid(name)
        local n = math.max(raids(name), stats[name].raids)
        return n > 0 and stats[name].won / n or 0
    end
    local function attPct(name)
        return attRaids > 0 and math.floor(raids(name) / attRaids * 100 + 0.5) or 0
    end
    statsList:Sort(names, {
        NS.Short,
        raids,
        attPct,
        function(name)
            return regulars[name] and 1 or 0
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
        r.cols[2]:SetText(raids(name))
        r.cols[3]:SetText(attRaids > 0 and (attPct(name) .. "%") or "")
        r.cols[4]:SetText(regulars[name] and "|cff66ff66yes|r" or "")
        r.cols[5]:SetText(e.won)
        r.cols[6]:SetText(e.free > 0 and e.free or "")
        r.cols[7]:SetText(string.format("%.2f", perRaid(name)))
        r.cols[8]:SetText(e.last > 0 and date("%d %b %Y", e.last) or "|cff999999never|r")
    end)
end

UI.refresh.stats = refreshStats
