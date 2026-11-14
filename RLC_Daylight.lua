-- RLC_Daylight.lua: when DaylightUI is installed, the window, its flyout and the
-- copy window adopt its look (through its public API only). Turn it off with
-- /rlc daylight (saved as RaidLootControllerDB.daylightLook); that takes a
-- /reload to switch back. Without DaylightUI this file does nothing.
local DUI = _G.DaylightUI
local API = DUI and DUI.API
if not API or API.major ~= 1 then
    return
end

local _, NS = ...

-- The saved variables exist when this file loads; NS.DB may not yet.
local function enabled()
    local db = NS.DB or RaidLootControllerDB
    return not (db and db.daylightLook == false)
end

local kit -- Daylight's Kit, handed over when the skin runs
local pending = {}
local swept = {}

-- Our own boxes draw a backdrop of their own: clear it, then use the inset look.
local function sweep(root)
    for _, child in ipairs({ root:GetChildren() }) do
        if child.GetBackdrop and child:GetBackdrop() then
            child:SetBackdrop(nil)
            kit.Inset(child)
        end
        sweep(child)
    end
end

local function dress(frame)
    if not kit or not enabled() then
        return
    end
    if not swept[frame] then
        swept[frame] = true
        sweep(frame)
    end
    kit.Auto(frame, { shownOnly = true })
end

-- Rows and Help entries are made as pages fill, so dress again after each
-- redraw (one pass per frame at most).
local function schedule(frame)
    if not kit or not frame or pending[frame] then
        return
    end
    pending[frame] = true
    C_Timer.After(0, function()
        pending[frame] = nil
        dress(frame)
    end)
end

local function skinMain()
    local f = _G.RaidLootControllerFrame
    if not f then
        return false
    end
    kit.Window(f)
    f:HookScript("OnShow", function()
        schedule(f)
    end)
    dress(f)

    local fly = _G.RaidLootControllerFlyout
    if fly then
        fly:SetBackdrop(nil)
        kit.Panel(fly)
        fly:HookScript("OnShow", function()
            schedule(fly)
        end)
    end

    -- The copy window is made on first use by NS.Kit.ShowCopy.
    local showCopy = NS.Kit.ShowCopy
    NS.Kit.ShowCopy = function(...)
        local copy = showCopy(...)
        if copy and not copy.daylightSkinned and enabled() then
            copy.daylightSkinned = true
            kit.Window(copy)
        end
        schedule(copy)
        return copy
    end

    local refresh = NS.Refresh
    NS.Refresh = function(...)
        refresh(...)
        schedule(f)
    end
    API.On("StyleChanged", function()
        schedule(f)
    end, "RaidLootController")
end

API.For("RaidLootController").RegisterSkin("RaidLootController", function(Kit)
    if not enabled() or kit then
        return
    end
    kit = Kit
    if skinMain() == false then
        kit = nil
        return false
    end
end)

-- /rlc daylight: the option, listed on the Commands tab beside "minimap".
local at = #NS.Commands + 1
for i, c in ipairs(NS.Commands) do
    if c.cmd == "minimap" then
        at = i + 1
    end
end
table.insert(NS.Commands, at, {
    section = "Everyone",
    cmd = "daylight",
    text = "Use DaylightUI look. Needs DaylightUI. Takes a /reload to switch back.",
    state = enabled,
    fn = function()
        NS.DB.daylightLook = not enabled()
        if enabled() and not kit then
            NS.Print("DaylightUI look on after /reload.")
        elseif enabled() then
            NS.Print("DaylightUI look on.")
            schedule(_G.RaidLootControllerFrame)
        else
            NS.Print("DaylightUI look off after /reload.")
        end
    end,
})
