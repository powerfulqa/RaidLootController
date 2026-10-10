# Raid Loot Controller

[![Download Latest](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FRaidLootController%2Fbadge-data%2Fversion.json&style=for-the-badge&color=orange)](https://github.com/powerfulqa/RaidLootController/releases/latest/download/RaidLootController.zip)
[![Downloads (this release)](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FRaidLootController%2Fbadge-data%2Flatest.json&style=for-the-badge&color=blue)](https://github.com/powerfulqa/RaidLootController/releases/latest)
[![Downloads (lifetime)](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpowerfulqa%2FRaidLootController%2Fbadge-data%2Fdownloads.json&style=for-the-badge&color=blue)](https://github.com/powerfulqa/RaidLootController/releases)
[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)

Fair raid loot for **WoW: Forever** (interface 16001), without DKP.

## Install

1. Download **[RaidLootController.zip](https://github.com/powerfulqa/RaidLootController/releases/latest/download/RaidLootController.zip)** (latest release).
2. Unzip it into your WoW: Forever `Interface\AddOns` folder, so you get `Interface\AddOns\RaidLootController\RaidLootController.toc`. During the beta that folder is `World of Warcraft\_classic_beta_\Interface\AddOns`.
3. Restart the game (or `/reload`) and type `/rlc`.

Everyone in the raid should install it. Players without it can still roll with `/roll`, and reserve by whispering the raid host `!rlc reserve <item or ID>`, but can't click I want this.

> **Set loot to Master Looter.** The addon decides who gets each item, and the master looter's addon hands it over straight from the loot window. Make the master looter the raid host or an officer, with the addon installed.
>
> Without Master Looter the game's own Need/Greed rolls come first: the addon only gets an item if **everyone passes**, and then the host loots it and trades it on. Raid drops are bind on pickup, so that only works if Forever lets you trade bound loot to the people at the kill (retail allows it for 2 hours; not yet tested on Forever).

## What it does

- **Everyone gets one item before anyone gets two.** Winning an item locks you for the rest of the raid (free rolls aside, see below).
- **Soft reserves.** Before the raid starts, reserve one item. If nobody else reserves it, it is yours when it drops. If several players reserve it, only they roll.
- **Server-verified rolls.** The Roll button uses the game's own `/roll`, so nobody can fake a number. Everyone with the addon sees the rolls live.
- **Best-for specs.** Each item is matched to the specs it suits (armor type, weapon type and stats), so a hunter can't roll on a rogue's leather. Your loot spec is guessed from your talents and confirmed by you once. Officers can change who may roll, and undo a win given by mistake.
- **Officer controls.** The raid leader (or an assistant) hosts the session and can make other players officers. Officers put items up, call and close rolls, open an item to everyone, restrict an item to some classes, give an item by hand, and lock or unlock players.
- **Fair over few raid nights.** Players who won nothing in their last raid roll first.
- **Upgrade info.** Officers see what each player wears in that slot and the stat change the item would give them.
- **Raid history.** Every raid is saved: who got what, how (roll, open roll, reserve, given), who rolled what, who wanted it, and an officer log of every manual action.
- **Loot catalogue.** Every notable item the addon sees drop, filed by instance and boss, with how many kills it dropped in. Search it, shift-click to link, or reserve straight from it. Raiders who missed a raid get the drops from guildmates and groupmates who were there, the next time they log in.
- **Delivery tracking.** Items still to trade are listed on the Raid tab, with the trade time left on bound items, and glow green in the giver's bags. A master loot give that fails (full bags, unique item, out of range) goes on that list too. Trading the winner takes the item off the list, and History marks it delivered.
- **Stats.** Every player from your saved raids: raids, items won, free rolls and their last win, to check that loot is spread fairly.
- **Copy as text.** Copy a raid's results from the History tab to paste into Discord.
- **Item tooltips** show who reserved an item, who you owe it to, which boss drops it and when you last won one (`/rlc tooltip` turns them off).
- **Update notice.** When a guild or group member has a newer version, or the raid host's addon sends something yours does not know, you get one chat line with a link to the download. The Raid tab flags old versions.

## How a raid runs

1. The raid leader sets loot to **Master Looter** (the host or an officer as master looter), opens `/rlc`, goes to **Raid**, and clicks **New raid**.
2. Raiders reserve an item on the **Raid** tab: shift-click it into the box, or type its item ID. One reserve each.
3. The leader clicks **Start raid**. Reserves are now closed (they also close when the first item is put up).
4. A boss dies. The master looter opens the loot window and clicks **Add N from loot** (or drops an item from their bags on the window). The items appear on the **Loot** tab for everyone.
5. An officer picks an item and clicks **Start**. Raiders who can use it click **I want this**.
6. The officer clicks **Call roll**:
   - If nobody without an item wants it, it opens to everyone instead. Call roll again to start the rolls.
   - If one player reserved it, they get it straight away.
   - If anyone who won nothing last raid wants it, only they roll first.
7. Raiders click **Roll (1-100)**. Rolls show up live. The button you need to click next glows, as does the minimap button.
8. The officer clicks **Close roll**. The highest roll wins; a tie makes only the tied players roll again.
9. The master looter's addon gives the winner the item straight from the loot window. If the window is closed (or loot is not on Master Looter, where the host hands items over), it goes on that player's "still to trade" list and glows green in their bags, and the addon puts it in the trade window the next time they trade the winner. Once it is given or traded, History marks it delivered.

An officer can **Unlock** a player on the Raid tab so they can roll normally again.

- **Free rolls don't count.** Winning an item that was opened to everyone does not lock you and does not touch your reserve, if you already had an item or it was off-spec for you. If you could have asked for it normally, it counts: staying quiet on **I want this** does not buy a free first item.
- **Your reserve is safe.** Winning another item first does not cost you your reserve: it still pays out when it drops, as your second item.
- **No loot last raid? You roll first.** Players who were in the last raid and won nothing there (free rolls aside) roll first on items that suit them. If none of them want it, everyone rolls.
- **Reserves close** at the raid start or when the first item is put up, whichever comes first. A reserve only pays out to someone still in the group.
- **Officers are held to the rules.** They can't open an item while someone without an item wants it, or give items to players outside the group. Every item given by hand, win taken back, lock, unlock and spec change is in the **Officer log** on the History tab.
- **Upgrade size.** Hold Shift on an item to compare it with your own gear. When you click **I want this**, the addon sends what you wear in that slot, so officers can hover your name to see your item level and the raw stat change. No scores, officers judge.

## The loot catalogue

The **Catalogue** tab works like a loot browser built from real drops:

- Drops are filed under the boss when the loot window opens within 5 minutes of the kill, otherwise under Trash.
- Whoever opens a corpse shares its drops with the group, so the whole raid records them.
- On login the addon asks your guild (and your group) for anything it is missing. One player who knows more answers; everyone listening merges it.
- Only items at or above rare quality are recorded.

## Specs: who an item is for

When an item is added, the addon works out which specs it suits:

- **Armor:** only the heaviest type a class wears. Hunters and shamans take mail and warriors and paladins take plate (from level 40 items). Cloaks, rings, necks, trinkets and off-hands have no armor rule.
- **Weapons:** only specs that use that weapon type. Daggers, for example, are not a hunter weapon.
- **Stats:** the spec must want the item's stats. A caster staff never goes to a hunter, and agility mail never goes to an elemental shaman.

The Loot tab shows the result as "Best for". Only those specs can click I want this and roll. If none of them wants the item, it opens to everyone, as with the one-item rule.

Your **loot spec** is the spec you want gear for, not the one you play tonight (dual spec: an off-tank in dps spec still loots as a tank). The addon guesses it from your talents (the tree with the most points) and asks you to **Confirm** it once on the Raid tab, or pick another with **Change loot spec**. It is saved per character. Feral druids pick cat or bear. You can change it until the raid starts; after that it is locked, and only an officer can change it. Players without the addon are checked by class only.

Officers can:

- change who may roll with **Who can roll** (Suggested, Any spec, or tick specs by hand)
- set a player's spec with **Set spec**
- take a mistaken win back with **Undo win**. The item goes back up, the winner is unlocked, and a reserve it used is given back.

## Who can roll

| Item is | Who can want it and roll |
|---|---|
| For players without an item (default) | Everyone who has not won an item yet |
| Open to everyone | Everyone, including players who already won |
| Reserved | Only the players who reserved it and are still in the group |
| Wanted by someone with no loot last raid | First pass: only those players |
| Limited to specs | The above, limited to the specs it suits |

A reserve ignores class limits: reserves are made before anyone knows how the item will be restricted. Any eligible player's `/roll 1-100` counts while rolls are open, even without clicking I want this, so players without the addon can still take part. Rolls from players who left the group don't count. A tie wipes all rolls and only the tied players roll again.

## Slash commands

| Command | What it does |
|---|---|
| `/rlc` | Open or close the window |
| `/rlc add <item>` | Put an item up for rolls (officers) |
| `/rlc reserve <item or ID>` | Reserve an item before the raid starts |
| `!rlc reserve <item or ID>` | The same, whispered to the raid host, for players without the addon |
| `/rlc sync` | Fetch the session from the raid host |
| `/rlc announce` | Turn raid chat announcements on or off (host) |
| `/rlc owed` | Clear the list of items still to trade (host) |
| `/rlc tooltip` | Show or hide the RaidLoot lines on item tooltips (on by default) |
| `/rlc minimap` | Hide or show the minimap button |
| `/rlc demo` | Fill the window with a made-up raid to look around (nothing is sent or saved) |
| `/rlc report` | Make a bug report to copy and paste |
| `/rlc debug` | Debug output in chat on or off |

The **Commands** tab lists the commands you can use right now, each with a **Run** button (commands that need an item have a **How** button that says what to type). It follows your role: raiders, officers and the raid host each see their own set. `/rlc help` prints the same list in chat. The host's announce toggle and the "still to trade" Clear button are also on the Raid tab.

The **Help** tab answers the common questions, with a search box that shows your search words in yellow. Click any column name to sort a list by it; click again to reverse.

Drag the window's bottom right corner to resize it; the size and place are saved. You can bind a key to open it under Keybindings, AddOns. `/rlc report` makes a bug report to copy into an issue.

The minimap button opens the window (left-click) or the loot catalogue (right-click). Drag it to move it around the minimap.

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

See [CLAUDE.md](CLAUDE.md) for the code map and the rules for working here.
