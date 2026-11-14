# Raid Loot Controller: the full guide

The detail behind the [README](../README.md): every rule, who can roll, how specs are matched, the loot catalogue and all commands. In game, the **Help** tab answers the same questions with a search box.

## How a raid runs

1. The raid leader sets loot to **Master Looter**, opens `/rlc`, goes to **Raid** and clicks **New raid**.
2. Raiders reserve an item on the **Raid** tab: shift-click it into the box, or type its item ID. One reserve each.
3. The leader clicks **Start raid**, or the first boss pull starts it. Reserves are now closed.
4. A boss dies. The master looter opens the loot window and clicks **Add from loot** (or drops an item from their bags on the window). The items appear on the **Loot** tab for everyone.
5. An officer picks an item and clicks **Start**. Raiders who can use it click **I want this**.
6. The officer clicks **Call roll** (not during a boss fight). The addon works out who rolls: see [Who can roll](#who-can-roll).
7. Raiders click **Roll (1-100)**. Rolls show up live.
8. The officer clicks **Close roll**, after 15 seconds or more. The highest roll wins. A tie makes only the tied players roll again.
9. The master looter's addon gives the winner the item straight from the loot window. If the window is closed, the item goes on the giver's "still to trade" list, glows green in their bags, and is put in the trade window the next time they trade the winner. History then marks it delivered.

Notes:

- If loot is not on Master Looter and an added item is not in the adder's bags, the addon warns that whoever looted it must trade it.
- If a boss is pulled during a roll, the rolls are wiped after the fight and everyone rolls again.
- The addon gives items by master loot only when the raid host leads the group or is the master looter.

## The rules

**One item each.** Winning an item locks you for the rest of the raid. An officer can **Unlock** a player on the Raid tab.

**Free rolls don't count.** If nobody without an item wants an item, it opens to everyone. Winning it does not lock you and does not touch your reserve, if you already had an item or it was off-spec for you. If you could have asked for it normally, it counts: staying quiet on **I want this** does not buy a free first item.

**Regulars and attendance**

- A regular was at 75% of the last 8 raids in this instance (3 of every 4).
- When regulars want an item that suits them, only they roll first. If none do, everyone rolls.
- The raid host's addon checks the group every minute. You count as at a raid if you were in the group and online for 75% of the time it was live.
- Officers can mark a player **Bench**, which counts as present.
- A night counts only if 10 or more players were there in person (bench not counted). Raids within 12 hours of the night's first start count as one night.
- A reserve alone is not attendance.

**Reserves**

- One reserve each. It is checked against your class and loot spec when you make it, and again when the item comes up.
- Reserves close at the raid start, when the first item is put up, or when the first boss is pulled, whichever comes first.
- If you alone reserved an item, it is yours when it drops. If several players reserved it, only they roll, those without an item first.
- A reserve only pays out to someone still in the group.
- A regular who wins another item first keeps their reserve: it still pays out as their second item. Anyone else uses it up with that win. A free roll never touches it.

**Officers.** The raid leader (or an assistant) hosts the session and can make other players officers. Officers put items up, call and close rolls, open an item to everyone, change who may roll, give an item by hand, remove an item, undo a win, unlock players and mark bench. They can't:

- open an item while someone without an item wants it, or give items to players outside the group;
- unlock, change a spec or change **Who can roll** while a roll is open;
- close a roll in its first 15 seconds (a tie reroll or regulars-first pass may close once every player in it rolled);
- give an item by hand, or undo a win, while a roll is open;
- call a roll during a boss fight;
- change the spec of a player holding a reserve once reserves close.

**The officer log** on the History tab keeps the evidence: every item given by hand, win taken back, removed item, lock, unlock, bench, spec change, closed or wiped roll, delivery, master loot given to someone other than the winner, and the raid's start and end. Gives, take-backs, closes, removals and unlocks are never pushed out by a flood of other entries, and a resync from the host never shortens your log.

### Who can roll

| Item is | Who can want it and roll |
|---|---|
| For players without an item (default) | Everyone who has not won an item yet |
| Open to everyone | Everyone, including players who already won |
| Reserved | Only the players who reserved it and are still in the group, those without an item first. A reserver with an item only if they are a regular |
| Wanted by a regular | First pass: only the regulars who want it |
| Limited to specs | The above, limited to the specs it suits |

- Any eligible player's `/roll 1-100` counts while rolls are open, even without clicking **I want this**, so players without the addon can take part.
- Rolls from players who left the group don't count.
- A tie wipes all rolls and only the tied players roll again. In a tie or a first pass, a player who already has an item can't win a second.

## Specs: who an item is for

When an item is added, the addon works out which specs it suits:

- **Armor:** only the heaviest type a class wears. Hunters and shamans take mail and warriors and paladins take plate (from level 40 items). Cloaks, rings, necks, trinkets and off-hands have no armor rule.
- **Weapons:** only specs that use that weapon type. Daggers, for example, are not a hunter weapon.
- **Stats:** the spec must want the item's stats. A caster staff never goes to a hunter, and agility mail never goes to an elemental shaman. Healing gear goes to healers and spell damage gear to casters ("damage and healing" suits both). Ranged attack power is for hunters, feral attack power for cat and bear. Defense and block make tank gear; dodge or parry alone does not. `Equip:` and `Use:` lines are read, hit and crit included.

The Loot tab shows the result as "Best for". Only those specs can click **I want this** and roll. If none of them wants the item, it opens to everyone.

**Your loot spec** is the spec you want gear for, not the one you play tonight (an off-tank in dps spec still loots as a tank).

- The addon guesses it from your talents (the tree with the most points). **Confirm** it once on the Raid tab, or pick another with **Change loot spec**. Feral druids pick cat or bear. It is saved per character.
- You need a loot spec before you can say **I want this** on an item limited to some specs.
- You can change it until reserves close. After that only an officer can (not while a roll is open, and not for a player holding a reserve).
- A spec first picked after the raid started is judged by class only on items open to everyone.
- Players without the addon have no loot spec, so they can roll only on items that suit every spec of their class. An officer can set their spec with **Set spec**.

Officers can:

- change who may roll with **Who can roll** (Suggested, Any spec, or tick specs by hand);
- set a player's spec with **Set spec**;
- take a mistaken win back with **Undo win**. The item goes back up, the winner is unlocked (unless they hold a free win they could have asked for normally), and a reserve it used is given back. History keeps the old winner and rolls.

## Tools


- **Always a next step.** The button you need next glows, and the **Next:** line says it in words.
- **Delivery tracking.** Items still to trade are listed on the Raid tab, with the trade time left on bound items, and glow green in the giver's bags. A master loot give that fails (full bags, unique item, out of range) goes on that list too.
- **Upgrade info.** Hold Shift on an item to compare it with your own gear. When you click **I want this**, the addon sends what you wear in that slot, so officers can hover your name to see your item level and the stat change. No scores: officers judge.
- **Raid history.** Every raid is saved: who got what and how (roll, open roll, reserve, given), every roll, who wanted it, removed items and wins taken back. **Copy as text** pastes a raid's results into Discord. A raid not hosted by the group leader is marked (unverified).
- **Stats.** Every player from your saved raids: attendance, items won, free rolls and their last win.
- **Versions.** Every player known to have the addon, with their version and whether they are in your group. **Copy list** gives the group's as text, to take attendance.
- **Loot catalogue.** Every notable drop the addon has seen, by instance and boss.
- **Item tooltips** show who reserved an item, who you owe it to, which boss drops it and when you last won one.
- **Update notice.** When a guild or group member has a newer version, or the raid host's addon sends something yours does not know, you get one chat line with a link to the download. The Raid tab flags old versions.
- **DaylightUI look.** With DaylightUI installed, the windows take its look.

## The loot catalogue

The **Catalogue** tab is a loot browser built from real drops. Search it, shift-click to link an item, or reserve straight from it.

- Only items at or above rare quality are recorded, with how many kills each dropped in.
- Drops are filed under the boss when the loot window opens within 5 minutes of the kill, otherwise under Trash.
- Whoever opens a corpse shares its drops with the group, so the whole raid records them. A drop report only counts for the instance you are in.
- On login the addon asks your guild (and your group) for anything it is missing. One player who knows more answers; everyone listening merges it.
- Items heard from others are marked (heard), and drop chances use only your own kills. **Forget heard** clears what others sent.

## Slash commands

| Command | What it does |
|---|---|
| `/rlc` | Open or close the window |
| `/rlc add <item>` | Put an item up for rolls (officers) |
| `/rlc reserve <item or ID>` | Reserve an item before the raid starts |
| `!rlc reserve <item or ID>` | The same, whispered to the raid host, for players without the addon |
| `/rlc sync` | Fetch the session from the raid host (a full refresh at most every 2 minutes) |
| `/rlc announce` | Turn raid chat announcements on or off (host) |
| `/rlc owed` | Clear the list of items still to trade (host) |
| `/rlc tooltip` | Show or hide the RaidLoot lines on item tooltips (on by default) |
| `/rlc minimap` | Hide or show the minimap button |
| `/rlc daylight` | DaylightUI look on or off (only with DaylightUI installed) |
| `/rlc demo` | Fill the window with a made-up raid to look around (nothing is sent or saved) |
| `/rlc report` | Make a bug report to copy and paste |
| `/rlc debug` | Debug output in chat on or off |

`/rlc help` prints the commands you can use right now.

## The window

- **Commands** tab: the commands you can use right now, each with a **Run** button (commands that need an item have a **How** button that says what to type). It follows your role: raiders, officers and the raid host each see their own set.
- **Raid** tab: the host's announce toggle and the "still to trade" **Clear** button are here too.
- **Help** tab: answers to the common questions, with a search box.
- Click any column name to sort a list by it; click again to reverse.
- Drag the bottom right corner to resize the window. The size and place are saved.
- Bind a key to open it under Keybindings, AddOns.
- The minimap button opens the window (left-click) or the loot catalogue (right-click). Drag it to move it around the minimap.
