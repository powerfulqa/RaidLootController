# Agent entry point

Raid Loot Controller: a no-DKP raid loot addon for **WoW: Forever**
(interface 16001). Forever is the Mainline 12.1.x client wearing a Classic
version number: use the `C_*` API surface, never Classic globals.

**Status: v0.6.1, still mostly unmeasured in game.** Most of what sits below the
rules layer is unmeasured on the live client. Treat the in-game checklist at
the end as open until someone ticks it off in a real group.

## Code map

| File | Owns |
|---|---|
| `RLC_Kit.lua` | Serv's shared kit, byte-identical to WoWClearance's `WoWClearance_Kit.lua`: palette, chat printer, `CanRead`, Help `Highlight`, glow, resize grip, copy window, minimap button and tooltip. Edit it here only, then `tools/sync-kit.sh` copies it across (`--check` compares). Loads first. |
| `RLC_Rules.lua` | The loot rules and session model. Pure Lua, no WoW API. `Apply` (primitive ops), `Intent` (requests -> ops, host only), `Snapshot`, wire codec, roll-line parser. |
| `RLC_Core.lua` | Saved data, names, roster, `NS.ApplyOps` / `NS.HandleRequest` / `NS.Act`, events, slash commands. |
| `RLC_Net.lua` | Addon-message queue (prefix `RLC1`), throttle, chat lockdown wait, trust checks on receive. |
| `RLC_Loot.lua` | Roll lines from `CHAT_MSG_SYSTEM`, loot window, master loot, trade delivery, tooltip class line, the "RaidLoot:" tooltip lines and the green marks on owed items in bags. |
| `Bindings.xml` | The open/close key binding (labels and `RaidLootController_Toggle` in `RLC_Core.lua`). Shipped in the release zip. |
| `RLC_Catalog.lua` | Loot catalogue by instance and boss. Pure data functions on top (`Record`, `CountKill`, `Digest`, `InstanceOps`, `ApplyOp`), event glue and guild/group sync (prefix `RLCC`) below. |
| `RLC_Specs.lua` | Which specs an item suits (armor, weapon and stat-group rules; pure `SuitedSpecs`, tested) and the player's own spec from talents (`C_Traits`, tab with the most points) or picked by hand. Own rules, not stat weights: weights cannot tell a hunter from a rogue. |
| `RLC_Help.lua` | The Help tab: Q&A entries in collapsible sections with search (the WoWClearance help pattern). Update it with any player-facing change. |
| `RLC_Demo.lua` | `/rlc demo`: swaps `NS.DB` for an in-memory fake raid, history and catalogue; `RLC_Net` sends nothing while it is on. `tests/test_demo.lua` builds it. |
| `RLC_UI.lua` | The window (Loot, Raid, History, Stats, Catalogue, Commands, Help tabs; resizable, size saved in `RaidLootControllerDB.window`), the copy window (`NS.ShowCopy`), the spec menus and the minimap button. The Commands tab renders `NS.Commands` (in `RLC_Core.lua`, the single list behind `/rlc`, `/rlc help` and the Run buttons; `when(S)` filters by role). Add a slash command there, never as a new `if` in the handler. |

Data flow: a button calls `NS.Act(req)`. On the host that runs
`Rules.Intent`, applies the ops, and queues them to the group. On anyone
else it queues `?REQ` to the group, and the host runs it. Clients apply ops
only from the session host (and `NEW` only from a leader or assistant).

## Rules for working here

- Lazy senior dev: reuse what is here, then Lua 5.1 stdlib, then the client
  API. No libraries are embedded and none should be added.
- **New rule behaviour lands with a fixture in `tests/test_rules.lua`.**
  Mutate the source to prove a new check can fail.
- For WoW API, event, widget or template questions, audits and new features,
  use the `wow-addon-architect` agent (`.claude/agents/`). It checks Context7
  first (`/alejandrotrevi/warcraft-wiki-md`, `/gethe/wow-ui-source`).
- WoW tooling this project expects (see "Dev tooling" at the end). At the start
  of WoW work, check it is in place and offer to set up whatever is missing.
- Check every new API call, event name and template against Forever before
  using it (`wow` MCP, `flavor: "forever"`; the captured surface is
  `~/Projects/forever-addon-kit/data/forever_api.json`). luacheck cannot see
  event names, widget methods or template names, and on this client a bad
  event name throws and aborts the rest of the file.
- Read the porting lessons in WoWClearance's `docs/PORT_STATUS.md` (sister Forever
  addon, private repo `powerfulqa/WoWClearance`; `gh api` reads it) before
  assuming anything about this client. Its UI patterns (Help panel, Commands
  Run buttons) are the house style here.
- **Forever has character surnames.** The game spells a player as "Serv"
  (UnitName, with the surname as its SECOND return where retail puts the
  realm) and as "Serv Aszune" (roll lines, likely other chat). Never
  compare raw names: run every name read from the game through
  `NS.Canon`, and name units with `NS.UnitIdentity`. Measured 2026-10-09.
- Wire input is untrusted: validate in `Rules.Apply` / `Rules.Intent`, never
  in the UI.
- Player-facing text is short and plain. No em dashes (U+2014) anywhere.
- Before committing: every `tests/test_*.lua` (`for t in tests/test_*.lua; do lua5.1 $t; done`; CI does the same; plain `lua` may be 5.5, which refuses the raid sim),
  including `tests/test_raid_sim.lua` (a raid night with chaotic players, plus 8 weeks of fairness numbers),
  `luacheck *.lua tests/*.lua` (0 warnings), `stylua --check *.lua tests/*.lua`.
- Two addon-message prefixes: `RLC1` (live session) and `RLCC` (catalogue),
  so a catalogue upload never takes the send budget live rolls need.

## Not measured yet (in-game checklist)

1. Addon messages reach the raid on `RAID` / `PARTY` / `INSTANCE_CHAT`, and
   `SendAddonMessage` result codes behave as handled in `RLC_Net.lua`.
2. `CHAT_MSG_SYSTEM` roll lines are readable (not secret) in a raid
   instance, and `RANDOM_ROLL_RESULT` parses on this client.
   *Measured 2026-10-09 (Mechanic probe, solo):* `RANDOM_ROLL_RESULT` is
   `%s rolls %d (%d-%d)`. Readability inside a raid instance is still open.
3. Master loot is offered by the server: `GetMasterLootCandidate` /
   `GiveMasterLoot` work. If not, the trade path is the only delivery.
4. Trade auto-fill: `UnitFullName("npc")` names the trade partner, and
   `ClickTradeButton` after `PickupContainerItem` places the item.
5. `ChatFrameUtil.InsertLink` fires on shift-click while the reserve box has
   focus.
   *Read from source 2026-10-26:* a bag shift-click runs
   `ContainerFrameItemButtonMixin:OnModifiedClick` -> `HandleModifiedItemClick`
   -> `ChatFrameUtil.InsertLink`, looked up at call time, so the hook sees it.
   `ChatEdit_InsertLink` is a separate copy, so hooking both is right. In game
   still open.
6. `C_TooltipInfo.GetHyperlink` lines carry the "Classes:" line as
   `leftText`.
   *Measured 2026-10-09:* tooltip lines come back as `leftText`, and
   `ITEM_CLASSES_ALLOWED` is `Classes: %s`. No class-restricted item was cached
   (T1/T2 ids "exist" but the server sent no data), so the line itself is still open.
7. Saved data survives a cold restart (it did for WoWClearance on build
   1.60.1.70245).
   **Measured 2026-10-09:** a session saved at 00:52 was intact after a game
   restart the next evening.
8. `ENCOUNTER_END` name and `GetInstanceInfo()` instanceID (8th return) are
   readable after a kill, and boss loot is attributed within the 5-minute
   window. `ENCOUNTER_LOOT_RECEIVED` fires (or not) under master loot.
   *Read from source 2026-10-26:* `ENCOUNTER_END` success is a number (not a
   bool), `ENCOUNTER_LOOT_RECEIVED` carries itemLink 3rd, and instanceID is
   `GetInstanceInfo()`'s 8th return. Readability after a kill is still open.
9. `GUILD` addon messages reach guildmates who were not in the raid, and the
   catalogue answer election keeps it to one responder per instance.
10. Spec detection: `C_SpecializationInfo.GetCombatConfigIDForSpecGroup` ->
    `C_Traits` group currency gives points per talent tab, and the tab order
    matches `Specs.LIST` `tree` indexes for every class.
    *Measured 2026-10-09, rogue only:* the chain works. `GetGroupCurrencyInfo`
    lists only tabs with points spent (empty with 0 spent); 1 point in Combat
    came back on the 2nd display group, matching `tree = 2`. The trait data is
    not ready at addon load; read it later. Other classes still open.
11. `C_Item.GetItemStats` key names (`ITEM_MOD_*_SHORT`) and the English
    "Equip:" phrases cover spell damage, healing and defense on Forever's
    Classic-era items.
    *Measured 2026-10-09:* keys are `ITEM_MOD_STRENGTH/AGILITY/STAMINA/SPIRIT_SHORT`,
    `ITEM_MOD_DAMAGE_PER_SECOND_SHORT`, armor as `RESISTANCE0_NAME`. Spell
    damage, healing and defense are still open.
12. ~~Master loot API present~~ **Measured 2026-10-09:** `/dump GetMasterLootCandidate,
    GiveMasterLoot, C_PartyInfo.GetLootMethod` returned three functions. Item 3
    (the server actually offering master loot in a raid) is still open.
13. A /roll by a player outside the group, standing near the host, does or
    does not reach the host's `CHAT_MSG_SYSTEM` (the host ignores it either way).
14. The glow (`AddGlow` in `RLC_UI.lua`) shows and pulses on the I want this,
    Roll and minimap buttons, and stops after the click.
15. Upgrade info: `Loot.WornFor` finds the worn item for each slot (ranged,
    wand, relic assume slot 18), `C_Item.GetItemStatDelta` returns readable
    deltas for Classic-era items, and Shift on a Loot tab item shows the
    game's compare tooltip.
    *Read from source 2026-10-26:* `INVSLOT_RANGED` is 18. The rest is open.
16. Commands tab: Run buttons fire, How prints what to type (opening chat
    from addon code would taint it), and the list changes as you become an
    officer or host. Announce toggle and owed Clear work on the Raid tab.
17. New in this round: the window resize grip and saved size; tooltip lines
    via `TooltipDataProcessor` (GameTooltip and ItemRefTooltip); bag marks via
    each container frame's `UpdateItems` and `GetSlotAndBagID`; the key binding
    shows under Keybindings > AddOns; versions arrive on `CQE`.
    *Read from source 2026-10-26:* `GetSlotAndBagID` returns the slot first,
    and Camelot's `ContainerFrame` overrides only the portrait and the jump
    hint, so the Mainline item buttons apply. In game still open.
18. Delivery without the host as master looter: with loot on Master
    Looter and an officer as master looter, `Loot.IAmGiver` picks them (from
    `C_PartyInfo.GetLootMethod`'s party/raid ID) and their addon gives the
    item. Also: whether Forever lets a player trade bound (BoP) raid loot to
    others at the kill, which the non-Master-Looter path depends on.
19. New in v0.5.0, all unmeasured:
    - `canaccessvalue(nil)`: `NS.CanRead` skips nils, so it does not matter
      unless a nil is ever secret.
    - Master loot confirmation: `LOOT_SLOT_CLEARED` fires after a
      successful `GiveMasterLoot` (if not, every give lands on the owed list
      at `LOOT_CLOSED`), and a failed give raises `UI_ERROR_MESSAGE` with
      `ERR_LOOT_MASTER_INV_FULL` / `_UNIQUE_ITEM` / `_OTHER`.
    - `ERR_TRADE_COMPLETE` arrives through `UI_INFO_MESSAGE` (if not, owed
      items never clear after a trade).
    - `BIND_TRADE_TIME_REMAINING` exists and its line is on
      `C_TooltipInfo.GetBagItem` for a fresh BoP drop (also answers 18).
    - Staggered trade fill (`C_Timer` per item) still places items.
    - Whisper reserve: `CHAT_MSG_WHISPER` sender canonicalises to a roster
      name, and a `WHISPER` reply to that raw sender spelling arrives.
    - Catalogue lanes pause during encounters
      (`C_InstanceEncounter.IsEncounterInProgress`).

20. New in v0.6.0, all unmeasured:
    - The minimap button background `UI-Minimap-Background` (the zoom-button
      one is not in the Forever file index) and the shared kit's frames.
    - `GET_ITEM_INFO_RECEIVED` passes `success` (Forever doc: `itemID, success`);
      a failed load no longer redraws.
      *Read from source 2026-10-26:* payload is `itemID` and a `success` bool.
    - `BAG_UPDATE_DELAYED` clears the trade-time cache.
    - Name collisions: whether two group members can share a spelling (if
      so, `NS.Canon` now refuses it).
    - `C_Item.GetItemInfoInstant` knows every real raid item uncached
      (catalogue merges drop items it does not know):
      `/dump C_Item.GetItemInfoInstant(16800)` on a fresh login.

21. New after the 2026-10-26 audit, all unmeasured:
    - The home-made spec flyout (`showFlyout` in `RLC_UI.lua`, replacing
      `MenuUtil`, which crashes Forever) opens, ticks stick for a non-host
      officer, it opens upward near the screen bottom, and an outside click
      closes it (`IsMouseButtonDown()` with no argument means any button).
    - `CHAT_MSG_WHISPER` fills `guid` (12th arg) and it equals
      `UnitGUID(unit)` of the raider, or `!rlc reserve` stops working.
    - Master loot gives only on `Enum.LootMethod.Masterlooter`, and only
      for a session hosted by the leader or the master looter itself.
    - The "rolls can't be read" line shows once per fight when roll lines
      are secret.
    - Catalogue: addon messages arrive in send order (a CE before its CB is
      refused), and `Net.CatalogBacklog` returns to 0 so answers resume.
    - Name collisions on the addon sender ("First-Realm" shared by two
      group members) silence both; measure how Forever spells the sender.
      *Read 2026-10-26 (wow-forever-api skill, measured 2026-10-05):*
      `CHAT_MSG_ADDON` sender is "First Surname" with no realm. Full names
      are unique, so the "First-Realm" collision does not arise.

22. After the 2026-10-26 second audit, all unmeasured. Probes to paste:
    [docs/probes.md](docs/probes.md).
    - (a) Cross-realm identity: Forever groups span hidden underlying realms.
      The canonical name is "First Surname-Realm", with the local realm when
      `UnitFullName` gives none, so host and raider may spell one player
      differently. Measure `UnitFullName("raidN")` for a groupmate from
      another realm; if realms differ, consider dropping the realm when
      `RegionalUniqueNamesEnabled()`.
    - (b) `SendChatMessage` on `RAID` / `PARTY` / `WHISPER` from an event
      handler (not a click) is or is not blocked (`ADDON_ACTION_BLOCKED`).
    - (c) `GiveMasterLoot` from a `C_Timer` callback is or is not protected.
    - (d) `RAID` addon messages reach groupmates on another underlying realm.
    - (e) The roster is kept through encounters where unit names are secret.

23. After the 2026-10-27 exploit loop, all unmeasured:
    - `hooksecurefunc("GiveMasterLoot", ...)` fires when the master looter
      gives from Blizzard's own loot menu, with (slot, candidate index), so a
      win given by hand is confirmed only when it reaches its winner.
    - A v0.6.1 client handed a `LOG2` op says "newer version" once and does
      not resync (read from v0.6.1 source; not seen in game).
    - Roster entries carried through an encounter are marked `stale` and
      skipped for trade, whisper and attendance until names read again.

## Dev tooling

Declared in `.claude/settings.json` (committed). On a new machine Claude Code
asks to trust the project and install both plugins; say yes. If it does not,
run `/plugin` and install them from the marketplaces listed there.

| Tool | Where | Use it for |
|---|---|---|
| `wow-addon-dev@wow-addon-workspace` (Wafhi3n) | plugin | `wow-forever-api` skill: facts measured on the Forever client, dated. Load before trusting any API on Forever. `api-gotcha-reviewer` agent on a diff before release. `/wow-addon-dev:patch-diff` after a client update. Skip its `/check` and `init` (they expect a multi-addon workspace). |
| `wow-addon-dev@wow-addon-dev` (miyanko) | plugin | `wow-source.sh ui forever` keeps a local, daily-refreshed clone of Blizzard's Forever UI source (`~/.cache/wow-addon-dev/ui/forever`). Grep `Blizzard_APIDocumentationGenerated` for signatures and secret tags; `Camelot/` overrides `Mainline/`. Its skill also lists the CVars that force a restriction (e.g. chat/encounter) for testing. Ignore the WeakAura parts. |
| `wow-addon-lifecycle` (TheMizeGuy, vendored) | `.claude/skills/wow-addon-lifecycle/` | PowerShell: `install-addon.ps1 . -Edition forever` copies this addon into the game, `package-addon.ps1`, `validate-toc.ps1`, `read-bugsack.ps1` (in-game Lua errors). References on taint, Midnight secrets, SavedVariables. Its Ace3 advice does not apply here. |
| `wow-addon-architect` | `.claude/agents/` | API research and audits, Context7 first. |
| Mechanic (Falkicon, GPL-3) | not in repo; set up on the machine that runs the game | In-game dev hub plus `mech` CLI and MCP server. Queue a Lua probe, `/reload`, read the result: the fastest way to tick off the in-game checklist below. Supports `16001`. |

Mechanic setup, only where WoW is installed (ask before doing it):
1. Clone https://github.com/Falkicon/Mechanic outside this repo.
2. Copy its `!Mechanic/` and `Mechanic/` folders into the Forever `Interface/AddOns/`.
3. `cd desktop && python -m pip install -e ".[mcp]"`, then `mech setup`.
4. `claude mcp add mechanic --scope local -- mech mcp` (local scope: machines
   without the game would only see a failing server).

Verified 2026-10-09 against the Forever source (build 1.60.1.70291):
`GetMasterLootCandidate` / `GiveMasterLoot` are called by Blizzard's own
`GroupLootFrame.lua`, which loads on Forever; `C_SpecializationInfo.GetActiveSpecGroup`,
`GetCombatConfigIDForSpecGroup`, `C_Traits.GetGroupDisplayInfoByTreeID` and
`GetGroupCurrencyInfo`, `RandomRoll`, `RegionalUniqueNamesEnabled` and
`InChatMessagingLockdown` are documented there. Whether the server offers master
loot is still checklist item 3.

## Release process

Same flow as EbonClearance, driven by `.github/workflows/release.yml`.

1. Run the checks above (tests, luacheck 0, stylua) on a green `main`.
2. Add a `### vX.Y.Z` section to `CHANGELOG.md` (player-facing, short).
   Update `README.md` and the Help tab for any player-facing change.
3. Commit and push, then tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. The workflow writes the version into the `.toc`, re-runs syntax checks
   and tests, zips `RaidLootController/` (every `RLC_*.lua`, the `.toc`,
   `LICENSE`; it fails if a file the `.toc` loads is missing), commits
   `Update version to vX.Y.Z [skip ci]` to `main`, and publishes the
   release with that changelog section. Never bump `## Version:` by hand.
5. **Then `git pull --rebase`**: the bot commit leaves local one behind.

Download link for players (always the newest):
https://github.com/powerfulqa/RaidLootController/releases/latest/download/RaidLootController.zip
`test.yml` runs syntax, luacheck and tests on every push to `main`.
`update-download-badge.yml` refreshes the README badges (JSON on the `badge-data`
branch) on every release and every 6 hours.
