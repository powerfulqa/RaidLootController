# Raid Loot Controller

Fair raid loot for **WoW: Forever** (interface 16001), without DKP.

- **Everyone gets one item before anyone gets two.** Winning an item locks you for the rest of the raid.
- **Soft reserves.** Before the raid starts, reserve one item. If nobody else reserves it, it is yours when it drops. If several players reserve it, only they roll.
- **Server-verified rolls.** The Roll button uses the game's own `/roll`, so nobody can fake a number. Everyone with the addon sees the rolls live.
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

An officer can **Unlock** a player on the Raid tab so they can roll normally again. Winning any item uses up your reserve: if you win something else first, your reserved item goes to the other reservers, or to a normal roll.

## The loot catalogue

The **Catalogue** tab works like a loot browser built from real drops:

- Drops are filed under the boss when the loot window opens within 5 minutes of the kill, otherwise under Trash.
- Whoever opens a corpse shares its drops with the group, so the whole raid records them.
- On login the addon asks your guild (and your group) for anything it is missing. One player who knows more answers; everyone listening merges it.
- Only items at or above rare quality are recorded.

## Who can roll

| Item is | Who can want it and roll |
|---|---|
| For players without an item (default) | Everyone who has not won an item yet |
| Open to everyone | Everyone, including players who already won |
| Reserved | Only the players who reserved it |
| Restricted to classes | The above, limited to those classes |

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

The minimap button opens the window (left-click) or the loot catalogue (right-click). Drag it to move it around the minimap.

## Install

Copy the `RaidLootController` folder into `Interface/AddOns`. Everyone in the raid should install it; players without it can still `/roll` and are counted, but they cannot reserve or click I want this.

## Development

```
lua tests/test_rules.lua          # rules suite (stock lua5.1)
lua tests/test_catalog.lua        # catalogue data and sync merge
luacheck *.lua tests/*.lua        # 0 warnings
stylua --check *.lua tests/*.lua
```

See [CLAUDE.md](CLAUDE.md) for the code map and the rules for working here.
