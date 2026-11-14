# Raid Loot Controller

[![Download Latest](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FRaidLootController%2Fbadge-data%2Fversion.json&style=for-the-badge&color=orange)](https://github.com/powerfulqa/RaidLootController/releases/latest/download/RaidLootController.zip)
[![Downloads (this release)](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FRaidLootController%2Fbadge-data%2Flatest.json&style=for-the-badge&color=blue)](https://github.com/powerfulqa/RaidLootController/releases/latest)
[![Downloads (lifetime)](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FRaidLootController%2Fbadge-data%2Fdownloads.json&style=for-the-badge&color=blue)](https://github.com/powerfulqa/RaidLootController/releases)
[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)

Fair raid loot for **WoW: Forever** (interface 16001), without DKP.

Loot rewards the time you give, not points you save up. Everyone gets one item before anyone gets two, and the players who turn up week after week roll first.

## Install

- **Windows:** download **[Install-RaidLootController.bat](https://github.com/powerfulqa/RaidLootController/releases/latest/download/Install-RaidLootController.bat)** and double-click it. If Windows asks, click **Run**.
- **Mac or Linux:** download **[install-raidlootcontroller.command](https://github.com/powerfulqa/RaidLootController/releases/latest/download/install-raidlootcontroller.command)** and run `bash ~/Downloads/install-raidlootcontroller.command`.
- **By hand:** unzip **[RaidLootController.zip](https://github.com/powerfulqa/RaidLootController/releases/latest/download/RaidLootController.zip)** into `World of Warcraft\_forever_\Interface\AddOns`.

The installer finds WoW: Forever and keeps your settings and loot history. To update, run it again, then `/reload`. If it can't find the game, paste the game folder when it asks (Battle.net, WoW: Forever, gear menu, **Show in Explorer**).

## The rules in short

- **One item each before anyone gets two.** Winning an item locks you for the rest of the raid.
- **Regulars roll first.** Come to 3 of every 4 raids and you roll before everyone else.
- **One soft reserve each**, made before the raid starts.
- **Rolls are the game's own `/roll`**, so nobody can fake a number.
- **Items go to specs that can use them.** A hunter can't roll on a rogue's leather.
- **Officers follow the same rules**, and everything they do by hand is logged.

## For raiders

1. Type `/rlc` or click the minimap button.
2. Read the **Next:** line at the top and click the glowing button.

That is all. Before the raid you can reserve one item on the **Raid** tab. When an item you can use comes up, click **I want this**, then **Roll**.

No addon? You can still roll with `/roll`, and reserve by whispering the host `!rlc reserve <item or ID>`.

## For the raid leader

1. Set loot to **Master Looter** (yourself or an officer, with the addon).
2. `/rlc`, **Raid** tab, **New raid**. Raiders make their reserves.
3. **Start raid**, or pull the first boss.
4. After a kill, open the loot window and click **Add from loot**.
5. Pick an item: **Start**, then **Call roll**, then **Close roll**. The addon works out who may roll and who won.
6. The master looter's addon hands the item to the winner. Anything it can't hand over goes on a "still to trade" list.

The **Versions** tab shows who has the addon; **Copy list** gives that as text to take attendance.

> Without Master Looter the game's own Need/Greed rolls come first, and the addon only gets an item if everyone passes.

## Also in the box

- **History** of every raid, with an officer log, and **Copy as text** for Discord.
- **Stats:** attendance and items won per player, to check loot is spread fairly.
- **Catalogue:** every drop the addon has seen, by instance and boss.
- **Item tooltips:** who reserved an item, which boss drops it, when you last won one.
- **Help** tab with search, and a **Commands** tab with a Run button for each command.
- Takes the **DaylightUI** look when DaylightUI is installed.

## More

- **[The full guide](docs/GUIDE.md):** every rule, who can roll, specs, the catalogue and all commands.
- **[Why the rules are fair](docs/FAIRNESS_AUDIT.md):** how they were tested against players trying to game them.
- **[Changelog](CHANGELOG.md)**
- Try it without a raid: `/rlc demo` fills the window with a made-up one.

## Development

Run the tests with Lua 5.1, as the game and CI do (Lua 5.5 refuses a loop in the raid sim):

```
lua5.1 tests/test_rules.lua       # rules suite
lua5.1 tests/test_raid_sim.lua    # a raid night with cheaters, plus 8 weeks of fairness numbers
lua5.1 tests/test_catalog.lua     # catalogue data and sync merge
lua5.1 tests/test_specs.lua       # which specs an item suits
lua5.1 tests/test_demo.lua        # demo mode builds cleanly
luacheck *.lua tests/*.lua        # 0 warnings
stylua --check *.lua tests/*.lua
```

CI runs all of these on every push. Releases: see [CHANGELOG.md](CHANGELOG.md) and the release steps in CLAUDE.md.

- The installers live in [tools/install/](tools/install/); the release build joins the `.bat` and `.ps1` into one file.
- What is still unmeasured in the game, and the `/dump` probes to check it: the checklist at the end of CLAUDE.md and [docs/probes.md](docs/probes.md).
- The fairness audit, its simulation numbers and what each finding became: [docs/FAIRNESS_AUDIT.md](docs/FAIRNESS_AUDIT.md).

See [CLAUDE.md](CLAUDE.md) for the code map and the rules for working here.
