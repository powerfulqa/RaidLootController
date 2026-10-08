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
            .. "but they can't reserve, click I want this, or report their spec.",
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
            .. "including players who already won an item. Officers can also open an item by hand.",
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
            .. "only they roll. Winning any other item first uses up your reserve.",
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
        q = "How does the addon know my spec?",
        a = "From your talents: the tree with the most points. The Raid tab shows it. "
            .. "Feral druids pick cat or bear with "
            .. GREEN
            .. "Change spec"
            .. R
            .. ". You can change it until the raid starts. After that only an officer can.",
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
        a = "If the loot window is still open, the addon gives it by master loot. "
            .. "Otherwise it's put in the trade window the next time you trade the winner. "
            .. "The Raid tab lists what is still to trade. /rlc owed clears that list.",
    },
    {
        q = "How do I make someone an officer, or unlock a player?",
        a = "On the Raid tab, click the player, then Make officer (raid leader only), Unlock or Set spec.",
        tab = "raid",
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
            .. "Hover an item to see the rolls.",
        tab = "history",
    },

    { section = "more", title = "Commands and problems" },
    {
        q = "Can I sort the lists?",
        a = "Yes. Click a column name to sort by it, and click it again to reverse. An arrow shows the "
            .. "column you sorted by.",
    },
    {
        q = "Slash commands",
        a = "/rlc - open or close the window\n"
            .. "/rlc reserve <item or ID> - reserve an item\n"
            .. "/rlc add <item> - put an item up (officers)\n"
            .. "/rlc sync - fetch the raid from the raid leader\n"
            .. "/rlc announce - raid chat announcements on or off\n"
            .. "/rlc owed - clear the list of items still to trade\n"
            .. "/rlc minimap - hide or show the minimap button\n"
            .. "/rlc demo - look around a made-up raid",
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

local TAB_NAMES = { loot = "Loot", raid = "Raid", history = "History", catalog = "Catalogue" }

-- ---- page ---------------------------------------------------------------------

local p = NS.helpPage
local collapsed = {} -- section -> true; every section but the first starts closed
for _, e in ipairs(ENTRIES) do
    if e.section and e.section ~= "start" then
        collapsed[e.section] = true
    end
end

local search = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
search:SetSize(230, 20)
search:SetPoint("TOPLEFT", 8, -2)
search:SetAutoFocus(false)
local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("LEFT", 2, 0)
hint:SetText("Search help")
search:SetScript("OnTextChanged", function(self)
    hint:SetShown(self:GetText() == "")
    NS.RefreshHelp()
end)
search:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
end)

local sf = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
sf:SetPoint("TOPLEFT", 4, -30)
sf:SetPoint("BOTTOMRIGHT", -26, 4)
local child = CreateFrame("Frame", nil, sf)
child:SetSize(660, 1)
sf:SetScrollChild(child)

local WIDTH = 640

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
