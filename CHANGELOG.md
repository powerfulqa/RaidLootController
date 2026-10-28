# Raid Loot Controller - Changelog

Per-release notes. For what the addon does, see the [README](README.md).

---

### v0.7.0

**Turning up counts.** A fairness review: regulars roll first, real attendance, tighter rules for officers, and a one-click installer.

New:

- **Regulars roll first.** Players who came to at least 3 of every 4 recent raids (75% of the last 8 in that instance) roll first on items they want. This replaces "no loot last raid rolls first".
- Attendance is real time in the raid: you count as there if you were in the group and online for 75% of it. Nights under 10 players in the group don't count (bench does not make up the 10), and raids within 12 hours of the night's first raid count as one night.
- Officers can mark a player **Bench** for the night. Bench counts as present. Players on v0.6.1 no longer reload the whole raid each time someone is benched.
- A one-click installer for Windows (Install-RaidLootController.bat) and Mac or Linux (install-raidlootcontroller.command). It finds WoW: Forever, installs or updates, and keeps your settings. Run it again to update. If the game folder needs permission, it offers to try again as administrator. A linked addon folder (a dev checkout) loses only the link, never the files.
- A glowing next-step button for every role, and a "Next:" line at the top of the window.
- History shows removed items and wins taken back. Stats shows attendance. The Raid tab lists tonight's regulars.
- Adding an item when loot is not on Master Looter, and it is not in your bags, warns that whoever looted it must trade it.

Fairer:

- A reserve pays out as a second item only for regulars. For anyone else, a normal win uses it up.
- Several players on one reserve: those without an item roll first.
- Reserves close when the first boss is pulled, even if nobody clicked Start raid.
- In a tie or a roll-first pass, a player who already has an item can no longer win a second.
- A spec first picked after the raid started is judged by class only on items open to everyone. It can be picked between items (not mid-roll, not for an item you already asked for), so a player without a spec is never stuck.
- A reserve used up by another win no longer pays out when its item comes up.
- Without the addon (no loot spec), you can roll only on items that suit every spec of your class. Skipping the addon no longer lets a fury warrior roll on tank plate. An officer can set your spec with Set spec.
- Undo win keeps the player locked if they hold a free win they could have asked for normally.
- A reserved item that falls back to normal rolls keeps its class limit.
- Best for: healing gear goes to healers and spell damage gear to casters. Ranged attack power is for hunters only, feral attack power for cat and bear. Use: lines, hit and crit now count. Dodge and parry no longer make an item tank-only. Protection paladins no longer roll on spell damage gear, and cat and bear are told apart.

Officers held to the rules:

- No unlock, spec change or Who can roll change while a roll is open, and no Give to player or Undo win on another item.
- No Close roll in the first 15 seconds, unless only some players may roll (reservers, regulars, a tie) and all of them rolled. The Close roll glow follows the same rule.
- No Call roll during a boss fight. A boss pull during a roll wipes it after the fight, and everyone rolls again.
- No spec change for a player holding a reserve once reserves close.
- The officer log never drops gives, take-backs, closes, removals or unlocks to make room: a flood of one kind only pushes out its own kind. Starting a raid twice is refused.
- Undo win keeps the old winner and rolls on the item, for History.
- A master looter giving a raid item to someone other than its winner is logged for everyone, once per item, and only for a player in the group.
- A resync from the raid host never shortens your officer log.

**Fairer and steadier.** A second security review, fixes for a crash and for raids that could lock players out.

Fixed:

- Clicking Who can roll, Change loot spec or Set spec could crash the game. Those lists are now the addon's own.
- A raid opened the day before for reserves no longer shuts players out the next evening.
- When rolls can't be read (usually during a boss fight), the raid host is now told so.
- The addon no longer breaks when the game hides a raider's class or leader status during a fight, and the trade window still fills.
- New raid, Delete raid, Clear list, Forget boss and Forget heard now ask before they act.
- A long "still to trade" list no longer covers the officer buttons.
- Clicking Officer log shows the whole log, ready to copy.
- The "not for your spec" line no longer gets cut off.

Safer:

- Reserves close as soon as the first drop is added, so nobody reserves an item after seeing it drop.
- You can only reserve gear your class and loot spec can use.
- A whispered reserve must really come from that raider, not someone sharing their first name.
- A master looter's addon only hands loot out by itself for a raid started by the raid leader (or by themselves). Otherwise it says who won, and you give it by hand. Raids started by an assistant also no longer decide who rolls first next week.
- A player who joins late with no spec must set it before asking for items.
- Players who roll first can no longer hold an item up by never rolling.
- An officer who closes a roll they won themselves shows in the officer log, and only the raid host can take back a delivered win. The log keeps the newest entries.
- Guild catalogue sharing ignores made-up drops and counts, and can no longer be silenced or flooded by one player.
- A party leader can no longer replace a raid you host while you are out of a raid group.
- Pick a loot spec before saying "I want this" on spec-limited items.
- /rlc sync can no longer be spammed to stall the raid, and a refresh sent for someone else no longer blanks your Loot tab.
- Item gifts and the officer log: gifts stay in the log, and spec changes and officer changes are logged too.
- Rolls must match a raider's full name.
- Catalogue data heard from others is marked "(heard)", percentages use your own kills, and Forget heard clears it. Raids not started by the raid leader show as "(unverified)" in History and are left out of Stats.
- Raiders no longer drop out of the addon's group list during boss fights.
- Raid announcements also show in the addon, in case the game blocks the chat line.
- An old raid can no longer be wiped from history by restarting it under its old name.
- A raider can no longer make the host resend the whole raid every 30 seconds.
- Items with impossible item numbers are refused.
- A master looter's addon no longer hands out items given by hand, or items typed in by ID: it says who should get them, and the master looter decides.
- The officer log also shows each roll an officer closed, each item marked delivered, and when the raid started and ended.
- Guild catalogue sharing: one kill can no longer report hundreds of items, and junk can no longer fill the catalogue for good.
- A made-up version number from one player no longer shows "a newer version is out". Two players must have it.
- A raid host can no longer grow everyone's saved data without end, or freeze their updates with a fake count.
- An officer can no longer call an item open to everyone the moment it goes up, before anyone could say they want it. Opening it that way is logged too.
- Loot specs lock as soon as the first drop is added, even before Start raid.
- If someone leaves during a boss fight, the addon no longer mixes up who is who in the trade window or for whispered reserves.
- A raider whose name has no surname is no longer silenced when someone with the same first name joins.
- Raid host messages from a host who no longer leads the group show as plain text.
- Raid names and guild catalogue names can no longer carry extra lines. Boss and raid names you saw yourself replace names heard from others.
- A heard drop no longer shows as "0%" in the item tooltip, and one guildmate can no longer keep your catalogue answer quiet by guessing your counts.
- Demo mode no longer answers real whispers or records real kills into the fake raid.
- An officer's Open to everyone also waits a few seconds after an item goes up, and an open item handed to someone who never rolled is the master looter's call, like any item given by hand.
- A flood of locks or spec changes can no longer push opens, closes and deliveries out of the officer log.
- Items given by hand count as delivered only once the master looter gives them to the right player.
- An officer can no longer open a reserved item to everyone while its reserver is in the raid.
- A master looter's addon hands an item out by itself only to the top roller, or to a lone reserver. Anything else, the master looter decides.

Lighter:

- Resizing the window, searching the catalogue and hovering Stats do far less work.
- Item data loading, catalogue searches and rolls redraw much less. History keeps the last 100 raids.

### v0.6.1

- The minimap button no longer has a black disc spilling past its gold ring.

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
