# Raid Loot Controller

Fair raid loot for **WoW: Forever** (interface 16001), without DKP.

- **Everyone gets one item before anyone gets two.** Winning an item locks you for the rest of the raid.
- **Soft reserves.** Before the raid starts, reserve one item. If nobody else reserves it, it is yours when it drops. If several players reserve it, only they roll.
- **Server-verified rolls.** The Roll button uses the game's own `/roll`, so nobody can fake a number. Everyone with the addon sees the rolls live.
- **Best-for specs.** Each item is matched to the specs it suits (armor type, weapon type and stats), so a hunter can't roll on a rogue's leather. Your loot spec is guessed from your talents and confirmed by you once. Officers can change who may roll, and undo a win given by mistake.
- **Officer controls.** The raid leader (or an assistant) hosts the session and can make other players officers. Officers put items up, call and close rolls, open an item to everyone, restrict an item to some classes, give an item by hand, and lock or unlock players.
- **Raid history.** Every raid is saved: who got what, how (roll, open roll, reserve, given), who rolled what, and who wanted it.
- **Loot catalogue.** Every notable item the addon sees drop, filed by instance and boss, with how many kills it dropped in. Search it, shift-click to link, or reserve straight from it. Raiders who missed a raid get the drops from guildmates and groupmates who were there, the next time they log in.

## How a raid runs

1. The raid leader opens `/rlc`, goes to **Raid**, and clicks **New raid**.
2. Raiders reserve an item on the **Raid** tab: shift-click it into the box, or type its item ID. One reserve each.
3. The leader clicks **Start raid**. Reserves are now closed.
4. A boss dies. The master looter opens the loot window and clicks **Add N from loot** (or drops an item from their bags on the window). The items appear on the **Loot** tab for everyone.
5. An officer picks an item and clicks **Start**. Raiders who can use it click **I want this**.
6. The officer clicks **Call roll**:
   - If nobody without an item wants it, it opens to everyone instead. Call roll again to start the rolls.
   - If one player reserved it, they get it straight away.
7. Raiders click **Roll (1-100)**. Rolls show up live.
8. The officer clicks **Close roll**. The highest roll wins; a tie makes only the tied players roll again.
9. The winner gets the item by master loot if the loot window is still open. Otherwise it goes into the trade window the next time the host trades them.

An officer can **Unlock** a player on the Raid tab so they can roll normally again.

- **Free rolls don't count.** Winning an item that was opened to everyone (usually off-spec) does not lock you and does not touch your reserve.
- **Your reserve is safe.** Winning another item first does not cost you your reserve: it still pays out when it drops, as your second item.
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
- take a mistaken win back with **Undo win**. The item goes back up, and the winner is unlocked.

## Who can roll

| Item is | Who can want it and roll |
|---|---|
| For players without an item (default) | Everyone who has not won an item yet |
| Open to everyone | Everyone, including players who already won |
| Reserved | Only the players who reserved it |
| Limited to specs | The above, limited to the specs it suits |

A reserve ignores class limits: reserves are made before anyone knows how the item will be restricted. Any eligible player's `/roll 1-100` counts while rolls are open, even without clicking I want this, so players without the addon can still take part. A tie wipes all rolls and only the tied players roll again.

## Slash commands

| Command | What it does |
|---|---|
| `/rlc` | Open or close the window |
| `/rlc add <item>` | Put an item up for rolls (officers) |
| `/rlc reserve <item or ID>` | Reserve an item before the raid starts |
| `/rlc sync` | Fetch the session from the raid host |
| `/rlc announce` | Turn raid chat announcements on or off (host) |
| `/rlc owed` | Clear the list of items still to trade (host) |
| `/rlc minimap` | Hide or show the minimap button |
| `/rlc demo` | Fill the window with a made-up raid to look around (nothing is sent or saved) |

The **Help** tab answers the common questions, with a search box. Click any column name to sort a list by it; click again to reverse.

The minimap button opens the window (left-click) or the loot catalogue (right-click). Drag it to move it around the minimap.

## Install

Copy the `RaidLootController` folder into `Interface/AddOns`. Everyone in the raid should install it; players without it can still `/roll` and are counted, but they cannot reserve or click I want this.

## Development

```
lua tests/test_rules.lua          # rules suite (stock lua5.1)
lua tests/test_catalog.lua        # catalogue data and sync merge
lua tests/test_specs.lua          # which specs an item suits
lua tests/test_demo.lua           # demo mode builds cleanly
luacheck *.lua tests/*.lua        # 0 warnings
stylua --check *.lua tests/*.lua
```

See [CLAUDE.md](CLAUDE.md) for the code map and the rules for working here.
