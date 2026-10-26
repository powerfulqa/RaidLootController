# In-game probes (checklist item 22)

Paste each line into chat (or queue it through Mechanic's `lua-queue`, minus
the `/run`). All names are checked against Forever's API docs
(`Blizzard_APIDocumentationGenerated`, build 1.60.1). Write the result and the
date into CLAUDE.md item 22.

## (a) Cross-realm identity

In a raid with someone from another underlying realm:

```
/run for i=1,GetNumGroupMembers() do local u="raid"..i print(u, UnitName(u), UnitFullName(u), UnitIsSameServer(u)) end print("me", UnitFullName("player"), GetNormalizedRealmName(), RegionalUniqueNamesEnabled())
```

- Every `UnitFullName` realm is nil or equals yours: one spelling, nothing to do.
- Some realms differ (or `UnitIsSameServer` is false): host and raider can
  spell that player differently. If `RegionalUniqueNamesEnabled()` is true,
  drop the realm from `NS.Canon`.

## (b) SendChatMessage outside a click

In a party or raid, from a timer (no hardware event):

```
/run local f=CreateFrame("Frame") f:RegisterEvent("ADDON_ACTION_BLOCKED") f:RegisterEvent("ADDON_ACTION_FORBIDDEN") f:SetScript("OnEvent",function(_,e,...) print(e,...) end) C_Timer.After(1,function() C_ChatInfo.SendChatMessage("rlc probe", IsInRaid() and "RAID" or "PARTY") C_ChatInfo.SendChatMessage("rlc probe","WHISPER",nil,UnitName("player")) end)
```

- Both lines show in chat, no event printed: announces and `!rlc` replies work.
- An `ADDON_ACTION_BLOCKED` / `_FORBIDDEN` line (or nothing in chat): the
  channel needs a click. Announces must stay in the addon's own chat lines.

## (c) GiveMasterLoot from a timer

As master looter, with a boss loot window open (slot 1 holds an item):

```
/run C_Timer.After(1,function() local ok,err=pcall(GiveMasterLoot,1,1) print("give",ok,err,GetMasterLootCandidate(1,1)) end)
```

- `give true` and the item goes to candidate 1: timed gives are fine.
- `give false` or `ADDON_ACTION_BLOCKED` (run the (b) frame first): the give
  must come from a click.

## (d) Addon messages across realms

Both players register and listen; then one sends:

```
/run C_ChatInfo.RegisterAddonMessagePrefix("RLCP") local f=CreateFrame("Frame") f:RegisterEvent("CHAT_MSG_ADDON") f:SetScript("OnEvent",function(_,_,p,m,c,s) if p=="RLCP" then print(p,m,c,s) end end)
/run print(C_ChatInfo.SendAddonMessage("RLCP","hello",IsInRaid() and "RAID" or "PARTY"))
```

- The other-realm player prints `RLCP hello RAID <sender>`: messages cross.
  Note how `<sender>` is spelled (with or without a realm); it answers (a) too.
- The sender prints `0` (Success) but nothing arrives: RAID does not cross
  realms; the session cannot reach that player.
