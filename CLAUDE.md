# Agent entry point

Raid Loot Controller: a no-DKP raid loot addon for **WoW: Forever**
(interface 16001). Forever is the Mainline 12.1.x client wearing a Classic
version number: use the `C_*` API surface, never Classic globals.

**Status: v0.1.0, written but not yet run in game.** Everything below the
rules layer is unmeasured on the live client. Treat the in-game checklist at
the end as open until someone ticks it off in a real group.

## Code map

| File | Owns |
|---|---|
| `RLC_Rules.lua` | The loot rules and session model. Pure Lua, no WoW API. `Apply` (primitive ops), `Intent` (requests -> ops, host only), `Snapshot`, wire codec, roll-line parser. |
| `RLC_Core.lua` | Saved data, names, roster, `NS.ApplyOps` / `NS.HandleRequest` / `NS.Act`, events, slash commands. |
| `RLC_Net.lua` | Addon-message queue (prefix `RLC1`), throttle, chat lockdown wait, trust checks on receive. |
| `RLC_Loot.lua` | Roll lines from `CHAT_MSG_SYSTEM`, loot window, master loot, trade delivery, tooltip class line. |
| `RLC_Catalog.lua` | Loot catalogue by instance and boss. Pure data functions on top (`Record`, `CountKill`, `Digest`, `InstanceOps`, `ApplyOp`), event glue and guild/group sync (prefix `RLCC`) below. |
| `RLC_Specs.lua` | Which specs an item suits (armor, weapon and stat-group rules; pure `SuitedSpecs`, tested) and the player's own spec from talents (`C_Traits`, tab with the most points) or picked by hand. Own rules, not stat weights: weights cannot tell a hunter from a rogue. |
| `RLC_UI.lua` | The window (Loot, Raid, History, Catalogue tabs), the spec menus and the minimap button. |

Data flow: a button calls `NS.Act(req)`. On the host that runs
`Rules.Intent`, applies the ops, and queues them to the group. On anyone
else it queues `?REQ` to the group, and the host runs it. Clients apply ops
only from the session host (and `NEW` only from a leader or assistant).

## Rules for working here

- Lazy senior dev: reuse what is here, then Lua 5.1 stdlib, then the client
  API. No libraries are embedded and none should be added.
- **New rule behaviour lands with a fixture in `tests/test_rules.lua`.**
  Mutate the source to prove a new check can fail.
- Check every new API call, event name and template against Forever before
  using it (`wow` MCP, `flavor: "forever"`; the captured surface is
  `~/Projects/forever-addon-kit/data/forever_api.json`). luacheck cannot see
  event names, widget methods or template names, and on this client a bad
  event name throws and aborts the rest of the file.
- Read the porting lessons in `~/Projects/WoWClearance/docs/PORT_STATUS.md`
  before assuming anything about this client.
- Wire input is untrusted: validate in `Rules.Apply` / `Rules.Intent`, never
  in the UI.
- Player-facing text is short and plain. No em dashes (U+2014) anywhere.
- Before committing: `lua tests/test_rules.lua`, `lua tests/test_catalog.lua`, `lua tests/test_specs.lua`,
  `luacheck *.lua tests/*.lua` (0 warnings), `stylua --check *.lua tests/*.lua`.
- Two addon-message prefixes: `RLC1` (live session) and `RLCC` (catalogue),
  so a catalogue upload never takes the send budget live rolls need.

## Not measured yet (in-game checklist)

1. Addon messages reach the raid on `RAID` / `PARTY` / `INSTANCE_CHAT`, and
   `SendAddonMessage` result codes behave as handled in `RLC_Net.lua`.
2. `CHAT_MSG_SYSTEM` roll lines are readable (not secret) in a raid
   instance, and `RANDOM_ROLL_RESULT` parses on this client.
3. Master loot is offered by the server: `GetMasterLootCandidate` /
   `GiveMasterLoot` work. If not, the trade path is the only delivery.
4. Trade auto-fill: `UnitFullName("npc")` names the trade partner, and
   `ClickTradeButton` after `PickupContainerItem` places the item.
5. `ChatFrameUtil.InsertLink` fires on shift-click while the reserve box has
   focus.
6. `C_TooltipInfo.GetHyperlink` lines carry the "Classes:" line as
   `leftText`.
7. Saved data survives a cold restart (it did for WoWClearance on build
   1.60.1.70245).
8. `ENCOUNTER_END` name and `GetInstanceInfo()` instanceID (8th return) are
   readable after a kill, and boss loot is attributed within the 5-minute
   window. `ENCOUNTER_LOOT_RECEIVED` fires (or not) under master loot.
9. `GUILD` addon messages reach guildmates who were not in the raid, and the
   catalogue answer election keeps it to one responder per instance.
10. Spec detection: `C_SpecializationInfo.GetCombatConfigIDForSpecGroup` ->
    `C_Traits` group currency gives points per talent tab, and the tab order
    matches `Specs.LIST` `tree` indexes for every class.
11. `C_Item.GetItemStats` key names (`ITEM_MOD_*_SHORT`) and the English
    "Equip:" phrases cover spell damage, healing and defense on Forever's
    Classic-era items. `MenuUtil` menus open from the Who can roll and spec
    buttons.
