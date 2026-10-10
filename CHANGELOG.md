# Raid Loot Controller - Changelog

Per-release notes. For what the addon does, see the [README](README.md).

---

### v0.6.0

**Harder to cheat, lighter to run, and a family look.** A security and performance review, and the shared look with WoWClearance.

Safer:

- A raid can no longer be started with a faked start time, and a flood of new raids is cut off, so saved history and the "rolls first" list cannot be pushed out or rigged.
- Once a raid ends, its old host can no longer change it.
- If two players in the group share a name spelling, their rolls and messages are refused rather than credited to the wrong one.
- One raider can no longer hold up live rolls by asking for resyncs or toggling "I want this" over and over.
- The loot catalogue only takes drops from your own group, ignores items the game does not know, and limits how much one guildmate can add.

Faster:

- The Raid tab no longer scans your bags on every redraw to show trade time left.
- A catalogue search shows the first 200 matches and stops re-reading every item; the Stats tab no longer recounts all history on every roll.
- A large catalogue share is no longer cut short at 5000 entries.

Looks:

- Help looks like WoWClearance's: gold section headers, blue questions, more space between answers, a "no matches" line, and open or closed sections are remembered.
- The minimap button uses a background that exists on this client, and starts at a different spot from WoWClearance's so the two never overlap. Its tooltip has the same layout as WoWClearance's.
- Chat lines start with "RaidLoot:".

### v0.5.0

**Tighter and lighter.** An audit against the Forever API, a performance pass, and ideas from RCLootCouncil, Gargul and RollFor.

- **No addon? Reserve by whisper.** Players without the addon whisper the raid host `!rlc reserve <item or ID>`, and the host's addon whispers back. Same rules as the Reserve button.
- **Master loot is confirmed.** An item only counts as delivered once it leaves the loot window. If the give fails (full bags, a unique item, out of range), it goes on the "still to trade" list instead of being lost.
- **Trade time left.** The "still to trade" list on the Raid tab shows how long each bound item can still be traded.
- **Safer trade window.** Won items go into the trade window one at a time, and stop if the trade closes. If the game hides who you are trading with, you are told.
- **Out of date?** If the raid host's addon sends something yours does not know, you get one line with the download link.

Faster:

- A resync after a reload sends a third less, so live rolls wait less behind it.
- Less work on every message, bag update and tooltip: history is no longer copied on each change, bags are only repainted when the "still to trade" list changes, and your spec is read from talents once.
- The catalogue search waits until you stop typing, and only one raider shares each drop with the group. Catalogue sharing waits until a fight ends.
- Saved data is smaller: gear notes are dropped once an item is won, and old catalogue kill records are cleared.

Fixes:

- Boss names, item links and chat senders that the game hides during a fight are now checked properly before use.
- A resync no longer prints "X won Y" a second time.

### v0.4.1

**Master Looter is the way to run it.**

- **The master looter hands items over,** not only the raid host. Make the host or an officer master looter: their addon gives the winner the item straight from the loot window, and anything left goes on their "still to trade" list.
- A master looter who wins an item now gets it from the loot window too.
- The README and Help explain why Master Looter matters: without it the game's own Need/Greed rolls come first, and the addon only gets items everyone passed on.

### v0.4.0

**A bigger window, and the addon now follows the loot after the roll.** First round of fixes from running it in game.

- **Resize the window.** Drag the bottom right corner. Lists and text grow to fill it, and the size and place are saved.
- **Delivered.** Trade a winner their item and it comes off the "still to trade" list, even if you put it in the trade window yourself. History marks it delivered (trade by the host or an officer, or master loot). Items you still owe someone glow green in your bags.
- **Stats tab.** Every player from your saved raids: raids, items won, free rolls and their last win. A quick check that loot is spread fairly.
- **Copy as text.** On the History tab, copy a raid's results to paste into Discord.
- **Item tooltips** show who reserved an item, who you owe it to, which boss drops it and when you last won one. Turn them off with /rlc tooltip.
- **Update notice.** When a guild or group member has a newer version you get one chat line, with a link to the download. The Raid tab shows who is on an old version.
- **/rlc report** makes a bug report to copy and paste. A key binding opens the window (Keybindings, AddOns).
- **Help search** shows the words you searched for in yellow.

Fixes:

- A raid left open (for example a test session) ends by itself after 12 hours, so you no longer log in to "Raid in progress".
- Lists match WoWClearance's style, fill the space below them, and hide the scroll bar when everything fits.
- The Commands tab is easier to read: sections with headings, and text that wraps instead of being cut off.
- Search boxes no longer overlap the tab row.

### v0.3.0

**Fairer over few raid nights, and much harder to game.** After a full audit, a fuzz test and a simulated raid full of players trying to cheat.

- **No loot last raid? You roll first.** If you were in the last raid and won nothing there (free rolls aside), you roll first on items that suit you. If none of you want it, everyone rolls.
- **Staying quiet doesn't pay.** Skipping I want this so an item opens to everyone no longer gets you a free first item: if you could have asked for it normally, winning it counts.
- **Reserves close** at the raid start or when the first item is put up, so nobody reserves a drop after seeing it. A reserve only pays out to someone still in the group.
- **Officers are held to the rules.** They can't open an item someone without an item wants, or give items to players outside the group. The new **Officer log** on the History tab shows every item given by hand, win taken back, lock, unlock and spec change, and who did it.
- **Commands tab.** Every /rlc command you can use right now, with a Run button. It follows your role: raider, officer or raid host. The host's announce toggle and the "still to trade" Clear button are also on the Raid tab.

Fixes:

- Long reserver or "Who can roll" lists no longer get lost on the way to other players.
- A player who leaves mid-roll can't win; spammed /roll, resync and I want this clicks can't flood the raid.
- The same loot window drop can't be added twice after a reload.
- Taking back a win always returns the reserve it used; a reopened raid syncs correctly.
- Upgrade info: two-handers compare against both hands; no "stats loading" on statless items.

### v0.2.0

**First public test build.** Fair raid loot for WoW: Forever without DKP: soft reserves, server /roll, one item each before anyone gets two, and a full raid history. Not yet run through a full raid: please report anything odd.

From raider feedback:

- **Your reserve is safe.** Winning another item first no longer costs you your soft reserve. It still pays out when it drops, as your second item.
- **Free rolls don't count against you.** Winning an item opened to everyone (usually off-spec) does not lock you and does not touch your reserve.
- **Loot spec for dual spec.** The spec you want gear for, not the one you play tonight. Guessed from your talents, confirmed by you once on the Raid tab.
- **Upgrade info.** Hold Shift on an item to compare it with your gear. "I want this" also sends what you wear in that slot: officers see your item level and, on hover, the raw stat change. No scores; officers judge.
- **Glowing buttons** point at what to click when an item is up (I want this, Roll, and the minimap button).

Fixes and hardening:

- A /roll from someone outside the group never counts.
- A spec must match your class; bad numbers, names and item data from other clients are refused.
- One player spamming requests can no longer delay everyone's rolls.
- Taking a win back clears the old winner's owed trade.
- Master loot is skipped safely if unavailable; trade delivery is more careful with the cursor.
