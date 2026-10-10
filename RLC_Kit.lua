-- Serv's addon kit: the look and helpers shared by Serv's Forever addons,
-- so a player who knows one knows the other.
--
-- The SAME file ships as RLC_Kit.lua in RaidLootController and as
-- WoWClearance_Kit.lua in WoWClearance. Edit it in RaidLootController, then
-- run tools/sync-kit.sh there to copy it across. Each addon loads its own
-- copy into its own namespace (NS.Kit): no globals, no load order between
-- addons, and either addon works alone.
--
-- The pure functions (Highlight, CanRead) load under stock Lua 5.1 for the
-- tests; the frame helpers only run in game.
local _, NS = ...

local Kit = {}
NS.Kit = Kit
Kit.VERSION = 1

-- ---- look ------------------------------------------------------------------
-- Each addon keeps its own brand colour (chat label, .toc title). These
-- are shared.
Kit.COLOR = {
    section = "|cffffd870", -- section headers
    question = "|cff4db8ff", -- Help questions
    good = "|cffb6ffb6", -- done, on, yours
    warn = "|cffffb84d", -- needs attention
    command = "|cffffff00", -- slash commands, search matches
    hint = "|cff999999", -- secondary text
}
Kit.DIVIDER = { 0.4, 0.35, 0.25, 0.8 }
Kit.HELP = { spacing = 3, answerGap = 7, entryGap = 16 }

-- A chat printer: Kit.Printer("RaidLoot", "ff8800")("Rolled %d.", 42)
-- prints "RaidLoot: Rolled 42." with the label in the brand colour.
function Kit.Printer(label, hex)
    local prefix = "|cff" .. hex .. label .. ":|r "
    return function(fmt, ...)
        local text = select("#", ...) > 0 and fmt:format(...) or tostring(fmt)
        DEFAULT_CHAT_FRAME:AddMessage(prefix .. text)
    end
end

-- ---- secret values ---------------------------------------------------------
-- Whether every value given can be read. On this client some event payloads
-- (chat senders, boss names during an encounter) can be secret, and
-- comparing or sending one throws. canaccessvalue takes ONE value, so each
-- is checked on its own; nils are skipped.
function Kit.CanRead(...)
    if not canaccessvalue then
        return true
    end
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil and not canaccessvalue(v) then
            return false
        end
    end
    return true
end

-- ---- text ------------------------------------------------------------------
-- Colour every case-insensitive match of `query` in `text` (Help search).
-- Matches that touch an escape code (|cAARRGGBB, |r, |n, a link) are left
-- alone, so the colour codes already in the text never break. `color`
-- defaults to the command yellow; `resume` is the colour to restore after
-- each match (|r drops to the default colour).
function Kit.Highlight(text, query, color, resume)
    if query == "" then
        return text
    end
    color = color or Kit.COLOR.command
    local code = {} -- byte positions inside an escape code
    local i = 1
    while true do
        local s, e = text:find("|c%x%x%x%x%x%x%x%x", i)
        local s2, e2 = text:find("|[rnHh]", i)
        if s2 and (not s or s2 < s) then
            s, e = s2, e2
        end
        if not s then
            break
        end
        for k = s, e do
            code[k] = true
        end
        i = e + 1
    end
    local lower, out, pos, from = text:lower(), {}, 1, 1
    while true do
        local s, e = lower:find(query, from, true)
        if not s then
            break
        end
        local clean = true
        for k = s, e do
            clean = clean and not code[k]
        end
        if clean then
            out[#out + 1] = text:sub(pos, s - 1) .. color .. text:sub(s, e) .. "|r" .. (resume or "")
            pos = e + 1
        end
        from = e + 1
    end
    out[#out + 1] = text:sub(pos)
    return table.concat(out)
end

-- ---- frames ----------------------------------------------------------------

-- A soft gold pulse over a frame, to point a player at the one thing to
-- click next. frame.SetGlow(on) turns it on or off.
function Kit.AddGlow(frame, texture)
    local t = frame:CreateTexture(nil, "OVERLAY")
    t:SetTexture(texture or "Interface\\Buttons\\ButtonHilight-Square")
    t:SetBlendMode("ADD")
    t:SetVertexColor(1, 0.8, 0.2)
    t:SetAllPoints()
    t:Hide()
    local ag = t:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(0.15)
    a:SetToAlpha(1)
    a:SetDuration(0.6)
    function frame.SetGlow(on)
        t:SetShown(on)
        if on and not ag:IsPlaying() then
            ag:Play()
        elseif not on then
            ag:Stop()
        end
    end
end

-- Drag the corner to resize. onDone runs on release.
function Kit.ResizeGrip(frame, onDone)
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        frame:StartSizing("BOTTOMRIGHT", true) -- true: grow from the mouse, no jump
    end)
    grip:SetScript("OnMouseUp", onDone or function()
        frame:StopMovingOrSizing()
    end)
    return grip
end

-- A window of text to copy (a link, a report). It opens without keyboard
-- focus so it can stay up while you play; clicking the text selects all of
-- it for one Ctrl+C, and typing puts the text back. `name` is the global
-- frame name (Escape closes it). w, h: optional size.
local copies = {}
function Kit.ShowCopy(name, title, text, w, h)
    local copy = copies[name]
    if not copy then
        copy = CreateFrame("Frame", name, UIParent, "ButtonFrameTemplate")
        copies[name] = copy
        copy:SetPoint("CENTER", 40, -40)
        copy:SetFrameStrata("DIALOG")
        copy:SetToplevel(true)
        copy:SetMovable(true)
        copy:SetResizable(true)
        copy:SetResizeBounds(320, 120)
        copy:EnableMouse(true)
        copy:RegisterForDrag("LeftButton")
        copy:SetScript("OnDragStart", copy.StartMoving)
        copy:SetScript("OnDragStop", copy.StopMovingOrSizing)
        copy:SetClampedToScreen(true)
        ButtonFrameTemplate_HidePortrait(copy)
        tinsert(UISpecialFrames, name)
        local hint = copy:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("TOPLEFT", 14, -34)
        hint:SetText("Click the text, then Ctrl+C to copy.")
        local sf = CreateFrame("ScrollFrame", nil, copy, "UIPanelScrollFrameTemplate")
        sf.scrollBarHideable = true
        sf:SetPoint("TOPLEFT", 12, -64)
        sf:SetPoint("BOTTOMRIGHT", -32, 30)
        local box = CreateFrame("EditBox", nil, sf)
        box:SetMultiLine(true)
        box:SetAutoFocus(false)
        box:SetFontObject("GameFontHighlightSmall")
        box:SetWidth(460)
        box:SetScript("OnEscapePressed", box.ClearFocus)
        box:SetScript("OnEditFocusGained", function(self)
            self:HighlightText()
        end)
        box:SetScript("OnTextChanged", function(self, user)
            if user then
                self:SetText(copy.text)
                self:HighlightText()
            end
        end)
        sf:SetScrollChild(box)
        sf:SetScript("OnSizeChanged", function(_, width)
            box:SetWidth(width)
        end)
        Kit.ResizeGrip(copy)
        copy.box, copy.sf = box, sf
    end
    -- An asked-for size always applies (a link needs far less room than a
    -- report); otherwise the size the player last dragged it to stays.
    if w or h or not copy.sized then
        copy:SetSize(w or 520, h or 360)
        copy.sized = true
    end
    copy:SetTitle(title)
    copy.text = text
    copy.box:SetText(text)
    copy.box:ClearFocus()
    copy:Show()
    -- Text that fits needs no scroll bar (the template only checks when the
    -- range changes). The box has its height a frame after SetText.
    C_Timer.After(0, function()
        copy.sf.ScrollBar:SetShown(copy.box:GetHeight() > copy.sf:GetHeight())
    end)
    copy:Raise()
    return copy
end

-- ---- minimap button --------------------------------------------------------
-- The round button both addons use, measured working on this client. Give
-- each addon its own default angle so the two never sit on top of each
-- other. opts:
--   name     global frame name
--   icon     texture path or file id
--   db, key  saved table and field holding the angle in degrees
--   angle    default angle
--   onClick(btn, mouseButton), onEnter(btn): optional
-- Returns the button; btn.Place() moves it to the saved angle.
local EDGE = 5 -- how far outside the minimap edge the button sits

function Kit.MinimapButton(opts)
    local btn = CreateFrame("Button", opts.name, Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    btn:RegisterForDrag("LeftButton")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background") -- the zoom-button one is not in the Forever files
    bg:SetSize(53, 53)
    bg:SetPoint("CENTER", -1, 1)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(opts.icon)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    btn.icon = icon
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("CENTER", 10, -10)
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    function btn.Place()
        local angle = math.rad(opts.db[opts.key] or opts.angle)
        local mw, mh = Minimap:GetWidth() or 0, Minimap:GetHeight() or 0
        local rx = mw > 0 and mw / 2 + EDGE or 80
        local ry = mh > 0 and mh / 2 + EDGE or 80
        local x, y = math.cos(angle) * rx, math.sin(angle) * ry
        -- A square minimap needs the button clamped to its edges, not a circle.
        if ((GetMinimapShape and GetMinimapShape()) or "ROUND") ~= "ROUND" then
            x = math.max(-rx, math.min(x * math.sqrt(2), rx))
            y = math.max(-ry, math.min(y * math.sqrt(2), ry))
        end
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    -- OnUpdate exists only while dragging.
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            opts.db[opts.key] = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            btn.Place()
        end)
    end)
    local function stopDrag(self)
        self:SetScript("OnUpdate", nil)
    end
    btn:SetScript("OnDragStop", stopDrag)
    btn:SetScript("OnHide", stopDrag) -- hidden mid-drag: no OnDragStop comes
    if opts.onClick then
        btn:SetScript("OnClick", opts.onClick)
    end
    if opts.onEnter then
        btn:SetScript("OnEnter", opts.onEnter)
        btn:SetScript("OnLeave", GameTooltip_Hide)
    end
    btn.Place()
    return btn
end

-- The minimap tooltip, the same shape in both addons: title in the brand
-- colour, then the addon's own lines, then a grey hint line of what the
-- clicks do ("Left-click: open  |  Drag: move").
function Kit.MinimapTooltip(owner, title, hex, lines, hint)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cff" .. hex .. title .. "|r")
    for _, line in ipairs(lines or {}) do
        GameTooltip:AddLine(line, 1, 1, 1, true)
    end
    if hint then
        GameTooltip:AddLine(hint, 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end
