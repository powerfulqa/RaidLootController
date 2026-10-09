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
| `RLC_Help.lua` | The Help tab: Q&A entries in collapsible sections with search (the WoWClearance help pattern). Update it with any player-facing change. |
| `RLC_Demo.lua` | `/rlc demo`: swaps `NS.DB` for an in-memory fake raid, history and catalogue; `RLC_Net` sends nothing while it is on. `tests/test_demo.lua` builds it. |
| `RLC_UI.lua` | The window (Loot, Raid, History, Catalogue, Commands, Help tabs), the spec menus and the minimap button. The Commands tab renders `NS.Commands` (in `RLC_Core.lua`, the single list behind `/rlc`, `/rlc help` and the Run buttons; `when(S)` filters by role). Add a slash command there, never as a new `if` in the handler. |

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
- Before committing: every `tests/test_*.lua` (`for t in tests/test_*.lua; do lua $t; done`; CI does the same),
  including `tests/test_raid_sim.lua` (a raid night with chaotic players, plus 8 weeks of fairness numbers),
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
16. Commands tab: Run buttons fire, Type opens chat prefilled
    (`ChatFrameUtil.OpenChat`), and the list changes as you become an
    officer or host. Announce toggle and owed Clear work on the Raid tab.

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
