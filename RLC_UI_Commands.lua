-- RLC_UI_Commands.lua
-- The Commands tab. Loads after RLC_UI.lua, which owns the window and
-- the shared widgets (NS.UI), and hands its redraw to UI.refresh.
local _, NS = ...
local UI = NS.UI
local Text, Button, page = UI.Text, UI.Button, UI.page
-- Every /rlc command with its own button, as WoWClearance does. Only the
-- commands that can do something for you right now are listed, so the page
-- follows your role in the raid. The list lives in NS.Commands (Core).

local cmdPage = page("commands")
-- This page sizes its rows when it draws (the lists re-lay themselves), so
-- it draws again when the window is resized.
cmdPage:SetScript("OnSizeChanged", function(self)
    if self:IsShown() then
        NS.Refresh()
    end
end)
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
        "You are: "
            .. NS.Kit.COLOR.section
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
            head.rule:SetColorTexture(unpack(NS.Kit.DIVIDER))
            head.rule:SetHeight(1)
            head.text:SetText(NS.Kit.COLOR.section .. section .. "|r")
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

UI.refresh.commands = refreshCommands
