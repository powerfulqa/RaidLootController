-- RLC_UI_Versions.lua
-- The Versions tab. Loads after RLC_UI.lua, which owns the window and
-- the shared widgets (NS.UI), and hands its redraw to UI.refresh.
local _, NS = ...
local Rules = NS.Rules
local UI = NS.UI
local Text, Button, Tip, List, page = UI.Text, UI.Button, UI.Tip, UI.List, UI.page
-- Everyone known to have the addon, with their version: NS.versions (filled
-- by any addon message a player sends, group or guild, and by the "CV"
-- answers in RLC_Catalog.lua) plus yourself. Players without it are not
-- listed. Copy list gives the ones in your group as text, for attendance.

local vp = page("versions")
local verSummary = Text(vp, "GameFontHighlight")
verSummary:SetPoint("TOPLEFT", 0, -2)
verSummary:SetPoint("TOPRIGHT", 0, -2)
local verHelp = Text(vp, "GameFontDisableSmall")
verHelp:SetPoint("BOTTOMLEFT", 0, 4)
verHelp:SetPoint("BOTTOMRIGHT", -318, 4)
verHelp:SetWordWrap(true)
verHelp:SetText(
    "Players with the addon answer when you join the group. Check again asks your group and "
        .. "guild. A v0.8.0 or older copy in the guild shows only after it sends something."
)
local verCheck = Button(vp, "Check again", 100, function()
    if NS.AskVersions(true) then
        NS.Print("Asked your group and guild who has the addon. Answers can take up to a minute.")
    else
        NS.Print("Asked a moment ago. Try again in a few seconds.")
    end
end)
verCheck:SetPoint("BOTTOMRIGHT", 0, 2)
local verList = List(vp, 696, 340, { 200, 200, 130 }, false, nil, { "Player", "Version", "In your group" })
verList.frame:SetPoint("TOPLEFT", 4, -42)
verList.frame:SetPoint("BOTTOMRIGHT", -26, 34)

local VER_TEXT = {
    same = "%s",
    unknown = "%s",
    older = "|cffff8800%s (older than yours)|r",
    newer = "|cff66ccff%s (newer than yours)|r",
}
-- names (sorted), version by name, and where each is: "here", "offline"
-- (in the group, disconnected) or nil (not in the group).
local function versionRows()
    local me = NS.Me()
    local names, ver, where = {}, {}, {}
    for name, v in pairs(NS.versions) do
        ver[name] = v
    end
    if me then
        ver[me] = NS.VERSION
    end
    for name in pairs(ver) do
        names[#names + 1] = name
        if NS.roster[name] then
            -- Only when the game says so: not known (a fight) is not offline.
            where[name] = NS.IsOnline(name) == false and "offline" or "here"
        end
    end
    table.sort(names)
    return names, ver, where
end
local function verPlain(v)
    return v == "?" and "version not heard" or v
end
local verCopy = Button(vp, "Copy list", 100, function()
    local names, ver, where = versionRows()
    local grouped, lines = IsInGroup(), {}
    for _, name in ipairs(names) do
        if where[name] or not grouped then
            lines[#lines + 1] = NS.Short(name)
                .. "  "
                .. verPlain(ver[name])
                .. (where[name] == "offline" and "  (offline)" or "")
        end
    end
    table.insert(
        lines,
        1,
        ("Raid Loot Controller installed, %s: %d %s"):format(
            date("%Y-%m-%d %H:%M"),
            #lines,
            grouped and "in the group" or "players"
        )
    )
    NS.ShowCopy("Players with the addon", table.concat(lines, "\n"))
end)
verCopy:SetPoint("RIGHT", verCheck, "LEFT", -4, 0)

-- Whisper the download link to group members never heard from. Sent from
-- the Yes click, a few per click (a burst limit is not measured), and to
-- each player once a day (NS.DB.whispered, saved so a /reload does not
-- start over). Never in demo mode: its raiders are made up, and a whisper
-- to one could reach a real player of that name.
local WHISPER_MAX = 5
local function withoutAddon()
    local names = {}
    if NS.Demo and NS.Demo.active then
        return names
    end
    for name, r in pairs(NS.roster) do
        -- Offline: the whisper "succeeds", then errors two minutes later.
        if
            name ~= NS.Me()
            and not NS.versions[name]
            and not r.stale
            and not NS.DB.whispered[name]
            and NS.IsOnline(name) ~= false
        then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end
local verWhisper = Button(vp, "Whisper link", 100, function()
    local n = math.min(#withoutAddon(), WHISPER_MAX)
    if n == 0 then
        NS.Print("Nobody left to whisper: everyone online in your group has the addon or was already whispered.")
        return
    end
    local text = ("Whisper the download link to %d players in your group without the addon?"):format(n)
    NS.Confirm(text, function()
        -- Read again at the Yes click: a pull or an answer may have come since.
        if C_ChatInfo.InChatMessagingLockdown() then
            NS.Print("Chat is locked right now. Try again after the fight.")
            return
        end
        local names = withoutAddon()
        local sent = math.min(#names, WHISPER_MAX)
        for i = 1, sent do
            -- The full name ("First Surname") reaches the right character.
            C_ChatInfo.SendChatMessage(
                "This group uses the Raid Loot Controller addon for loot. Download: " .. NS.DOWNLOAD_URL,
                "WHISPER",
                nil,
                NS.Short(names[i])
            )
            NS.DB.whispered[names[i]] = GetServerTime() -- after the send: an error above leaves the rest to try again
        end
        NS.Print("Sent the link to %d players.%s", sent, #names > sent and " Click again for the rest." or "")
        NS.Refresh()
    end)
end)
verWhisper:SetPoint("RIGHT", verCopy, "LEFT", -4, 0)
Tip(verCheck, "Ask your group and guild who has the addon.")
Tip(verCopy, "Open the list of group members with the addon as text you can copy.")
Tip(verWhisper, "Whisper the download link to group members without the addon. For the leader and assistants.")

local WHERE_TEXT = { here = "|cff66ff66yes|r", offline = "|cff999999offline|r" }
local function refreshVersions()
    local names, ver, where = versionRows()
    local here, older = 0, 0
    for _, name in ipairs(names) do
        here = here + (where[name] and 1 or 0)
        older = older + (Rules.VersionState(ver[name], NS.VERSION) == "older" and 1 or 0)
    end
    verList:Sort(names, {
        NS.Short,
        function(name)
            return ver[name]
        end,
        function(name)
            return where[name] or ""
        end,
    })
    verList:Set(#names, function(r, i)
        local name = names[i]
        local v = ver[name]
        r.data = name
        r.cols[1]:SetText(NS.ColorName(name))
        r.cols[2]:SetText(
            v == "?" and "|cff999999not heard yet|r" or VER_TEXT[Rules.VersionState(v, NS.VERSION)]:format(v)
        )
        r.cols[3]:SetText(WHERE_TEXT[where[name]] or "")
    end)
    verCheck:SetEnabled(IsInGroup() or IsInGuild())
    -- Leader and assistants only, so a raid member is not whispered by everyone.
    verWhisper:SetEnabled(NS.IsLeadOrAssist(NS.Me()) and #withoutAddon() > 0)
    local total = 0
    for _ in pairs(NS.roster) do
        total = total + 1
    end
    verSummary:SetText(
        ("%d players with the addon.%s%s"):format(
            #names,
            IsInGroup() and ("  %d of the %d in your group."):format(here, total) or "",
            older > 0 and ("  |cffff8800%d on an older version than you.|r"):format(older) or ""
        )
    )
end

UI.refresh.versions = refreshVersions
