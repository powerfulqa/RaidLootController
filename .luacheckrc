-- luacheck config for RaidLootController (WoW: Forever, Lua 5.1).
-- Globals the client provides are listed explicitly so a typo still warns.
-- luacheck cannot see event names, widget methods or template names: those
-- are strings resolved at runtime. Lint the addon with the wow MCP
-- wow_lua_lint (flavor "forever") as well; it checks event names.
std = "lua51"
max_line_length = false
ignore = {
    "212", -- unused argument (event handler signatures)
}
globals = {
    "RaidLootControllerDB",
    "SLASH_RAIDLOOTCONTROLLER1",
    "SLASH_RAIDLOOTCONTROLLER2",
    "SlashCmdList",
    "RaidLootController_OnAddonCompartmentClick",
    "UISpecialFrames",
}
read_globals = {
    "C_AddOns", "C_ChatInfo", "C_ClassColor", "C_Container", "C_Item", "C_Timer", "C_TooltipInfo",
    "CANCEL", "ChatEdit_InsertLink", "ChatFrameUtil", "ClearCursor", "ClickTradeButton", "CopyTable",
    "CreateFrame", "DEFAULT_CHAT_FRAME", "Enum", "ERR_TRADE_COMPLETE", "GameTooltip", "GameTooltip_Hide",
    "GetClassInfo", "GetCursorInfo", "GetInstanceInfo", "GetInventoryItemLink", "ChatFrame_OpenChat", "PlaySound", "SOUNDKIT", "GameTooltip_ShowCompareItem", "TooltipUtil", "GetLootSlotInfo", "GetLootSlotLink",
    "GetLootSourceInfo", "GetMasterLootCandidate", "GetNormalizedRealmName", "GetNumClasses",
    "GetNumGroupMembers", "GetNumLootItems", "GetNumSubgroupMembers", "GetServerTime", "GetCursorPosition", "GetMinimapShape", "GetTime", "GetTradePlayerItemLink",
    "GiveMasterLoot", "Constants", "RegionalUniqueNamesEnabled", "MenuUtil", "C_SpecializationInfo", "C_Traits", "HandleModifiedItemClick", "hooksecurefunc", "IsInGroup", "IsInGuild", "IsModifiedClick", "IsInRaid", "ITEM_CLASSES_ALLOWED",
    "LE_PARTY_CATEGORY_INSTANCE", "NUM_BAG_SLOTS", "RANDOM_ROLL_RESULT", "RandomRoll",
    "ButtonFrameTemplate_HidePortrait", "Minimap", "UIParent", "UnitClass", "UnitFullName", "UnitIsGroupAssistant",
    "UnitIsGroupLeader", "UnitName", "canaccessvalue", "date", "strtrim", "tinsert", "wipe",
}
files["tests/*.lua"] = { std = "lua51", globals = { "GetServerTime", "CopyTable" } } -- client stubs
