# In-game probes (checklist items 22 and 24)

Paste each line into chat (or queue it through Mechanic's `lua-queue`, minus
the `/run`). All names are checked against Forever's API docs
(`Blizzard_APIDocumentationGenerated`, build 1.60.1). Write the result and the
date into the CLAUDE.md item it belongs to (22 or 24).

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

## 24 (a) UnitIsConnected for raid units

In a raid with one member logged out (and, if you can, during a boss fight):

```
/run for i=1,GetNumGroupMembers() do local u="raid"..i local c=UnitIsConnected(u) print(u, UnitName(u), canaccessvalue(c) and tostring(c) or "SECRET") end
```

- `true` for online members, `false` for the offline one: attendance works.
- `SECRET` (in or out of a fight): nobody earns attendance while it is
  secret. `markAttendance` must fall back to roster presence.

## 24 (b) Attendance ticker

As raid host, with the raid live, read it, wait 3 minutes, read again:

```
/run local S=RaidLootControllerDB and RaidLootControllerDB.session local n=0 for _ in pairs(S and S.att or {}) do n=n+1 end print("span", S and S.attSpan, "inst", S and S.inst, "names", n)
```

The live session is `RaidLootControllerDB.session`. After
the raid, the same fields are on its `RaidLootControllerDB.history` record.

- `attSpan` grows by about 60 a minute, each present raider's `att` the same,
  and `inst` is the raid's instance ID: the ticker works.
- `attSpan` stops after a loading screen of over 90 s, then grows again:
  expected (the gap counts as not seen).

## 24 (c) ENCOUNTER_START on raid bosses

Register before the pull, read the lines after the kill or wipe:

```
/run local f=CreateFrame("Frame") f:RegisterEvent("ENCOUNTER_START") f:RegisterEvent("ENCOUNTER_END") f:SetScript("OnEvent",function(_,e,...) print(e,...) end)
```

- `ENCOUNTER_START <id> <name> <difficulty> <size>` at the pull and
  `ENCOUNTER_END ... 1` (or 0) after it: auto start and roll void work.
  Also check the addon's own lines: "A boss was pulled, so the raid has
  started" (raid still in reserves) and "Everyone rolls again" (a roll open
  at the pull).
- Nothing printed: Forever raid bosses do not fire it. Reserves then close
  only at Start raid or the first Add.

## 24 (d) Loot slot data inside the GiveMasterLoot hook

As master looter, with a boss loot window open, then give slot 1 from
Blizzard's own menu:

```
/run hooksecurefunc("GiveMasterLoot",function(s,i) print("hook",s,i,GetLootSourceInfo(s),GetLootSlotLink(s),GetMasterLootCandidate(s,i)) end)
```

- `hook <slot> <index> <source guid> <link> <name>`: the hook sees the slot
  before it empties; a give to someone other than the winner is logged.
- The source or link is nil: the slot is already cleared. `sessionItemAt`
  must remember the slot's source and link at `LOOT_OPENED`.

## 24 (e) Same instance

In a raid, with one member outside the instance (in a city) and one inside:

```
/run for i=1,GetNumGroupMembers() do local u="raid"..i local r=UnitInRange(u) print(u, UnitName(u), canaccessvalue(r) and tostring(r) or "SECRET", C_Map.GetBestMapForUnit(u), UnitIsVisible(u), UnitPosition(u)) end
```

- One of the values differs between the two and is readable: attendance can
  require the host's instance. Note which.
- All nil, equal or `SECRET`: the instance cannot be checked; keep the
  `ponytail` note in `RLC_Core.lua` and the A2 gap open.

## 24 (f) Installers

Windows (a machine that never ran it, Windows PowerShell 5.1, not 7):

1. Download `Install-RaidLootController.bat` from the latest release in Edge.
2. Note the browser warning and the "Open File - Security Warning" (Run). Measured on a VM 2026-10-28; check a real browser download too.
3. It should print the Forever folder found (from the registry or the usual
   paths), the version, and "Installed". Run it again: "Updated", and
   `WTF` is unchanged.
4. Run it with the game closed and with the game open (then `/reload`).

macOS:

1. Download `install-raidlootcontroller.command` in Safari.
2. Double-click it: note the Gatekeeper message. Then run
   `bash ~/Downloads/install-raidlootcontroller.command` in Terminal.
3. It should find `/Applications/World of Warcraft/_forever_` and print
   "Installed".

## 24 (g) Use:, hit and crit on real tooltips

Hover or link an item with an `Equip:` hit or crit line, and a `Use:`
trinket, then:

```
/run for _,l in ipairs(C_TooltipInfo.GetHyperlink(select(2,C_Item.GetItemInfo(19406)) or "item:19406").lines) do print(l.leftText) end for k in pairs(C_Item.GetItemStats("item:19406") or {}) do print(k) end
```

(19406 is Drake Fang Talisman; swap in any id.) Then add the item with
`/rlc add` and read its Best for line.

- The lines start `Equip:` / `Use:` in English and the phrases ("chance to
  hit", "critical strike", "attack power") appear: the classifier reads them.
- Other wording, or stat keys such as `ITEM_MOD_HIT_RATING_SHORT` with no
  melee or spell part: add them to `LINE_PHRASES` / `STAT_KEYS` in
  `RLC_Specs.lua`.
