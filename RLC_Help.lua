-- RLC_Help.lua
-- The Help tab: plain-language questions and answers in collapsible
-- sections, with a search box. Same shape as the WoWClearance help panel:
-- an ordered list of section markers and entries, where an entry may carry
-- a `tab` that gets an "Open ... tab" button.
--
-- Keep answers short and new-player friendly: lead with what to do, no code
-- words, no em dashes.
local _, NS = ...

local GREEN = "|cffb6ffb6"
local YELLOW = "|cffffff00"
local R = "|r"

local ENTRIES = {
    { section = "start", title = "Getting started" },
    {
        q = "What does this addon do?",
        a = "It shares out raid loot fairly, without DKP. Everyone gets one item before anyone gets two. "
            .. "You can reserve an item before the raid, rolls use the game's own /roll so nobody can fake one, "
            .. "and every raid is saved in History. The Catalogue lists everything seen dropping, boss by boss.",
    },
    {
        q = "How does a raid night go?",
        a = "1) The raid leader opens the Raid tab and clicks New raid.\n"
            .. "2) Everyone reserves one item (optional) and checks their spec on the Raid tab.\n"
            .. "3) The raid leader clicks Start raid. Reserves and specs are now locked.\n"
            .. "4) A boss dies. The master looter adds the loot, and the item comes up on the Loot tab.\n"
            .. "5) Click I want this if you want it. When rolls are called, click Roll.\n"
            .. "6) The highest roll wins. The winner gets the item by master loot or trade.",
        tab = "raid",
    },
    {
        q = "Does everyone need the addon?",
        a = "It works best if they do. Players without it can still type /roll and their rolls count, "
            .. "and they can reserve by whispering the raid host: !rlc reserve, then shift-click the item "
            .. "(or type its item ID). They can't click I want this or report their spec.",
    },

    { section = "rolling", title = "Rolling for loot" },
    {
        q = "How do I roll for an item? Where is the Roll button?",
        a = "On the Loot tab, pick the item and click "
            .. GREEN
            .. "I want this"
            .. R
            .. ". The "
            .. GREEN
            .. "Roll (1-100)"
            .. R
            .. " button appears next to it once an officer clicks Call roll, and you can click it if you are "
            .. "allowed to roll for that item. Your roll shows up for everyone. Only your first roll counts.",
        tab = "loot",
    },
    {
        q = "Why is a button glowing?",
        a = "A glowing button is the next thing you can click for the item that is up now: "
            .. "I want this while officers ask who wants it, then Roll once rolls are called. "
            .. "The minimap button glows too, in case you closed the window. "
            .. "The glow stops once you click, or if you can't roll for that item.",
        tab = "loot",
    },
    {
        q = "Why can't I roll on this item?",
        a = "The line under the item says why. The usual reasons:\n"
            .. "- Rolls have not been called yet.\n"
            .. "- You already won an item this raid. You can roll again if nobody without an item wants it.\n"
            .. "- The item is not for your spec (see Best for).\n"
            .. "- Someone reserved it, so only the players who reserved it roll.\n"
            .. "- It was a tie, so only the tied players roll again.",
        tab = "loot",
    },
    {
        q = 'What does "Open to everyone" mean?',
        a = "Nobody it was meant for wants it, so anyone who can use it may roll, "
            .. "including players who already won an item. Officers can open an item by hand, "
            .. "but not while someone without an item still wants it.\n\n"
            .. "For players who already won something, or for whom it is off-spec, this is a free roll: "
            .. "winning it does not count as your item and does not touch your reserve.\n\n"
            .. "If it was an item you could have asked for normally, winning it counts as your item. "
            .. "Staying quiet on I want this does not get you a free first item.",
    },
    {
        q = "Can I see if an item is an upgrade?",
        a = "Hold Shift while you hover an item on the Loot tab to compare it with what you wear.\n\n"
            .. "When you click I want this, the addon also sends what you wear in that slot. "
            .. "Hover a name in the list to see their gear and the stat change the item would give them. "
            .. "It shows raw stats, not a score: officers judge how big the upgrade is.",
        tab = "loot",
    },
    {
        q = 'What does "no loot last raid" mean?',
        a = "You were in the last raid and won nothing there (free rolls aside). "
            .. "Tonight, when you want an item that suits you, only players with no loot last raid "
            .. "roll on it first. If none of them want it, everyone rolls as usual. "
            .. "It keeps loot moving when raid nights are few.",
        tab = "loot",
    },
    {
        q = "Does typing /roll in chat count?",
        a = "Yes, while rolls are open and only for 1-100. The Roll button does the same thing. "
            .. "A second roll from the same player is ignored.",
    },
    {
        q = "What happens on a tie?",
        a = "Only the tied players roll again. Everyone else's rolls are cleared, so a lower roll can't sneak in.",
    },

    { section = "reserves", title = "Reserves" },
    {
        q = "How do reserves work?",
        a = "While the raid shows "
            .. GREEN
            .. "Reserves open"
            .. R
            .. " (before Start raid), you can reserve one item on the Raid tab. "
            .. "Shift-click the item into the box, type its item ID, or pick it from the Catalogue.\n\n"
            .. "If nobody else reserves it, it's yours when it drops. If several players reserve it, "
            .. "only they roll. Winning another item first does not cost you your reserve: "
            .. "it still pays out when it drops, as your second item.\n\n"
            .. "Reserves close when the raid starts or when the first item is put up, whichever comes first. "
            .. "You must be in the group when it drops.\n\n"
            .. "No addon? Whisper the raid host: !rlc reserve, then shift-click the item (or type its ID). "
            .. "The host's addon whispers back.",
        tab = "raid",
    },
    {
        q = "Where do I find items to reserve?",
        a = "The Catalogue tab lists every item seen dropping, boss by boss, and how often. "
            .. "Pick one and click Reserve this.",
        tab = "catalog",
    },

    { section = "specs", title = "Specs" },
    {
        q = "What is my loot spec? I have dual spec.",
        a = "Your loot spec is the spec you want gear for, not the one you play tonight. "
            .. "An off-tank in dps spec still loots as a tank.\n\n"
            .. "The addon guesses it from your talents. Check it once on the Raid tab: click "
            .. GREEN
            .. "Confirm"
            .. R
            .. ", or pick another with "
            .. GREEN
            .. "Change loot spec"
            .. R
            .. ". It is saved for this character. You can change it until the raid starts. "
            .. "After that only an officer can.",
        tab = "raid",
    },
    {
        q = 'What does "Best for" on an item mean?',
        a = "The specs the item suits. The addon looks at the armor type (hunters and shamans wear mail, "
            .. "warriors and paladins plate, from level 40), the weapon type, and the stats. "
            .. "Only those specs can roll, unless none of them wants it. Officers can change the list.",
    },

    { section = "officers", title = "For the raid leader and officers" },
    {
        q = "How do I run the loot?",
        a = "Pick an item on the Loot tab, then:\n"
            .. "- Start: put it up so players can say they want it.\n"
            .. "- Call roll: open the rolls. If nobody it suits wants it, it opens to everyone instead.\n"
            .. "- Close roll: the highest roll wins.\n"
            .. "- Open to all: let anyone roll right away.\n"
            .. "- Who can roll: change the specs it is for.\n"
            .. "- Give to player: give it to the player you clicked in the list.\n"
            .. "- Undo win: take back a win given by mistake. The item goes back up and the winner is unlocked.",
        tab = "loot",
    },
    {
        q = "How do items get into the addon?",
        a = "Open the boss's loot window and click Add from loot. Or drop an item from your bags on the "
            .. "window, or type /rlc add and shift-click the item.",
        tab = "loot",
    },
    {
        q = "How does the winner get the item?",
        a = "Set loot to Master Looter, with the host or an officer as master looter. The master "
            .. "looter's addon gives the item straight from the loot window. If the window is closed, "
            .. "it's put in the trade window the next time they trade the winner. "
            .. "If the give fails (full bags, a unique item, out of range), it goes on that list too.\n\n"
            .. "The Raid tab lists what is still to trade, with the trade time left on bound items, "
            .. "and those items glow green in your bags. "
            .. "Trade the winner and the item comes off the list, even if you put it in the window "
            .. "yourself. /rlc owed clears that list.\n\n"
            .. "History marks an item delivered when the host or an officer trades it to the winner, "
            .. "or gives it by master loot.",
    },
    {
        q = "How do I make someone an officer, or unlock a player?",
        a = "On the Raid tab, click the player, then Make officer (raid leader only), Unlock or Set spec.",
        tab = "raid",
    },

    {
        q = "Do we need Master Looter?",
        a = "Yes, it's the way the addon is meant to run. Without it, the game's own Need and Greed "
            .. "rolls come first: the addon only gets an item if everyone passes, and then the host "
            .. "has to loot it and trade it on. Raid drops are bind on pickup, so that also needs the "
            .. "game to allow trading bound loot to the people at the kill.",
    },

    { section = "catalog", title = "Catalogue and history" },
    {
        q = "What is the Catalogue?",
        a = "A loot list built from real drops: every rare or better item the addon has seen, filed under "
            .. "the boss that dropped it, with how many kills it dropped in. Search it, shift-click to link, "
            .. "or reserve from it.",
        tab = "catalog",
    },
    {
        q = "I missed a raid. Do I get its drops in my Catalogue?",
        a = "Yes. When you log in, the addon asks your guild for anything you're missing, "
            .. "and someone who was there sends it. You can also click Ask guild for updates.",
        tab = "catalog",
    },
    {
        q = "What is in History?",
        a = "Every raid: who won what, how (roll, open roll, reserve or given), and everyone's rolls. "
            .. "Hover an item to see the rolls.\n\n"
            .. "Officer log: every item given by hand, win taken back, lock, unlock and spec change, "
            .. "with the officer who did it. Hover Officer log, or an item, to see it.",
        tab = "history",
    },
    {
        q = "Can I post a raid's loot in Discord?",
        a = "Yes. On the History tab, pick the raid and click Copy as text. Click the text, press "
            .. "Ctrl+C, then paste it anywhere.",
        tab = "history",
    },
    {
        q = "What is the Stats tab?",
        a = "Every player from your saved raids: how many raids the addon saw them in, how many items "
            .. "they won, and when they last won one. Free rolls are counted apart. Use it to check "
            .. "that loot is spread fairly. Hover a player to see what they won.",
        tab = "stats",
    },
    {
        q = "What are the RaidLoot lines on item tooltips?",
        a = "What the addon knows about that item: who reserved it tonight, who you still need to "
            .. "trade it to, which boss it drops from (from the Catalogue), and when you last won one. "
            .. "They are on by default; /rlc tooltip (or Run on the Commands tab) turns them off or on.",
        tab = "commands",
    },

    { section = "more", title = "Commands and problems" },
    {
        q = "Can I sort the lists?",
        a = "Yes. Click a column name to sort by it, and click it again to reverse. An arrow shows the "
            .. "column you sorted by.",
    },
    {
        q = "Can I bind a key to open the window?",
        a = "Yes. Open the game's Keybindings, then AddOns, and set Raid Loot Controller.",
    },
    {
        q = "How do I report a bug?",
        a = "Type /rlc report (or Run it on the Commands tab). It opens a short report about your "
            .. "addon, game and raid. Copy it and paste it into your bug report with what happened.",
        tab = "commands",
    },
    {
        q = "Will I know when there is a new version?",
        a = "Yes. When someone in your guild or group has a newer version, you get one line in chat. "
            .. "Click the green Click here in it: it shows the download link, ready to copy into your browser. "
            .. "You also get it if the raid host's addon sends something yours does not know. "
            .. "On the Raid tab, hover a player to see their version; old ones show as old addon.",
    },
    {
        q = "Can I make the window bigger?",
        a = "Yes. Drag the bottom right corner. Lists and text grow to fill it, and the addon remembers "
            .. "the size and where you put the window.",
    },
    {
        q = "Slash commands",
        a = "Open the Commands tab: it lists the /rlc commands you can use right now, each with a "
            .. "Run button. The list follows your role: officers and the raid host see more.\n\n"
            .. "Type /rlc help in chat for the same list. /rlc on its own opens or closes the window.",
        tab = "commands",
    },
    {
        q = "My window shows an old raid or no items.",
        a = "Click Resync on the Raid tab, or type /rlc sync. The raid leader's addon sends you the raid. "
            .. "It also happens by itself when you join the group or reload.",
        tab = "raid",
    },
    {
        q = "How do the addons talk to each other?",
        a = "Through hidden addon messages in raid chat. The raid leader's addon is in charge: your clicks go "
            .. "to it, it checks the rules, and it tells everyone what changed, within about a second. "
            .. "During a boss fight the game holds addon messages back, so they go out right after the fight.",
    },
    {
        q = "What is demo mode?",
        a = "Type /rlc demo to fill the window with a made-up raid, history and catalogue, to see how "
            .. "everything looks. Nothing is sent or saved. Type /rlc demo again to leave it.",
    },
}

local TAB_NAMES = {
    loot = "Loot",
    raid = "Raid",
    history = "History",
    stats = "Stats",
    catalog = "Catalogue",
    commands = "Commands",
}

-- ---- page ---------------------------------------------------------------------

local p = NS.helpPage
local collapsed = {} -- section -> true; every section but the first starts closed
for _, e in ipairs(ENTRIES) do
    if e.section and e.section ~= "start" then
        collapsed[e.section] = true
    end
end

local search = NS.InputBox(p, 230, "Search help", function()
    NS.RefreshHelp()
end)
search:SetPoint("TOPLEFT", 8, -2)

local sf = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
sf:SetPoint("TOPLEFT", 4, -30)
sf:SetPoint("BOTTOMRIGHT", -26, 4)
local child = CreateFrame("Frame", nil, sf)
child:SetSize(660, 1)
sf:SetScrollChild(child)

local WIDTH = 640

-- Text wraps to the page: a resized window re-wraps and re-lays the entries.
sf:SetScript("OnSizeChanged", function(_, width)
    child:SetWidth(width)
    WIDTH = width - 20
    for _, e in ipairs(ENTRIES) do
        if e.header then
            e.header:SetWidth(WIDTH)
        elseif e.qText then
            e.qText:SetWidth(WIDTH)
            e.aText:SetWidth(WIDTH - 12)
        end
    end
    if p:IsShown() then
        NS.RefreshHelp()
    end
end)

-- Widgets per entry, made once.
local built = false
local function build()
    built = true
    for _, e in ipairs(ENTRIES) do
        if e.section then
            local b = CreateFrame("Button", nil, child)
            b:SetSize(WIDTH, 20)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            b.text:SetPoint("LEFT", 2, 0)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            b:SetScript("OnClick", function()
                collapsed[e.section] = not collapsed[e.section] or nil
                NS.RefreshHelp()
            end)
            e.header = b
        else
            e.qText = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            e.qText:SetWidth(WIDTH)
            e.qText:SetJustifyH("LEFT")
            e.qText:SetText(e.q)
            e.aText = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            e.aText:SetWidth(WIDTH - 12)
            e.aText:SetJustifyH("LEFT")
            e.aText:SetSpacing(2)
            e.aText:SetText(e.a)
            e.aText:SetTextColor(0.85, 0.85, 0.85)
            e.search = (e.q .. " " .. e.a):lower()
            if e.tab then
                e.button = CreateFrame("Button", nil, child, "UIPanelButtonTemplate")
                e.button:SetSize(130, 20)
                e.button:SetText("Open " .. TAB_NAMES[e.tab] .. " tab")
                e.button:SetScript("OnClick", function()
                    NS.ShowPage(e.tab)
                end)
            end
        end
    end
end

-- Lay the entries out top to bottom. While searching, only matching
-- entries show, and their sections open.
function NS.RefreshHelp()
    if not built then
        build()
    end
    local query = (search:GetText() or ""):lower()
    local searching = query ~= ""
    local hasMatch, section = {}, nil
    for _, e in ipairs(ENTRIES) do
        if e.section then
            section = e.section
        elseif not searching or e.search:find(query, 1, true) then
            e.match = true
            hasMatch[section] = true
        else
            e.match = false
        end
    end

    local y, open = 0, false
    for _, e in ipairs(ENTRIES) do
        if e.section then
            local show = not searching or hasMatch[e.section]
            open = show and (searching or not collapsed[e.section])
            e.header:SetShown(show)
            if show then
                e.header.text:SetText((open and "- " or "+ ") .. e.title)
                e.header:SetPoint("TOPLEFT", 0, y)
                y = y - 24
            end
        else
            local show = open and e.match
            e.qText:SetShown(show)
            e.aText:SetShown(show)
            if e.button then
                e.button:SetShown(show)
            end
            if show then
                -- While searching, the matched words show in yellow.
                e.qText:SetText(searching and NS.Rules.Highlight(e.q, query, YELLOW) or e.q)
                e.aText:SetText(searching and NS.Rules.Highlight(e.a, query, YELLOW) or e.a)
                e.qText:SetPoint("TOPLEFT", 10, y)
                y = y - e.qText:GetStringHeight() - 4
                e.aText:SetPoint("TOPLEFT", 22, y)
                y = y - e.aText:GetStringHeight() - 6
                if e.button then
                    e.button:SetPoint("TOPLEFT", 20, y)
                    y = y - 24
                end
                y = y - 8
            end
        end
    end
    child:SetHeight(math.max(1, -y))
end
