# Fairness audit (2026-10-28)

How players, officers and the host can game the loot rules for an unfair
share, measured against the goal: **loot rewards time given, not a grindable
currency.** Wire forging and taint are out of scope (covered by the
2026-10-27 exploit loop).

## Status (v0.7.0)

Checked against the v0.7.0 diff (2026-10-28). Still unmeasured in game:
CLAUDE.md checklist 24.

| ID | Status | What landed |
|---|---|---|
| F1 | Fixed | `Eligible`: in a tie or roll-first pass a lock still counts. Co-reservers without an item roll first. |
| F2 | Fixed | A reserve pays out as a second item only to a regular; for anyone else a normal win spends it (`awardOps`, undo gives it back). Review round: CALL and CLOSE count a reserver only while `S.reserves[name]` is still that item. |
| F3 | Fixed | Reserve START keeps `item.classMask`. |
| F4 | Fixed | No spec on record: the item must suit every spec of the class (`Rules.CLASS_SPECS`, filled by RLC_Specs.lua). |
| F5 | Partly fixed | Regulars merge raids within 12 h of the night's first start (no sliding chain) in one instance, filter by instance, and check MIN_ATTEND after the merge. End raid + New raid still wipes locks; no warning. |
| F6 | Fixed | `S.lateSpec`: a first spec after the start is judged by class only for open wins. Review round: a first spec is taken between items (not mid-roll, not on the item already wanted or rolled on), so no dead end. |
| F7 | Fixed | UNDO re-locks a winner who holds a free win they could have asked for. |
| F8 | Fixed | Host goes live on the first `ENCOUNTER_START` in a raid instance. |
| F9 | Fixed | CALL refused in an encounter; a roll open at the pull is voided at `ENCOUNTER_END`. |
| A1 | Fixed | `att` is seconds connected while live; present at 75% of `attSpan`. |
| A2 | Partly fixed | `UnitIsConnected` checked. Same-instance presence is not (no readable API found). |
| A3 | Fixed | Variant D: regulars, 75% of the last 8 counting raids. |
| A4 | Open | DRY ops still not logged; no source date or staleness check. The Raid tab Regulars list (UI) shows who. |
| A5 | Fixed | Bench rides in the `bench`/`unbench` LOG2 entry (no top-level op: v0.6.1 resynced on it), counts as present, but not toward MIN_ATTEND. |
| A6 | Partly fixed | Attendance on Stats (UI round). No minutes or join/leave times. |
| A7 | Open | No linked characters. |
| O1 | Fixed | Repeated PHASE refused; no-op LOCK/BENCH not logged; `award`, `undo`, `close`, `void`, `mlgive`, `cancel`, `unlock` evicted last; once only kept kinds remain, the oldest of the incoming kind goes (an incoming non-kept entry is dropped). |
| O2 | Fixed | LOCK, SETSPEC, SPECS refused while rolling, and AWARD/UNDO of any other item; `item.suggested` keeps ADD's specs for open wins; SETSPEC refused for a reserver after close. "Winner was not top roll" flag not added. |
| O3 | Fixed | UNDO keeps `item.undone` (winner, how, rolls); `cancel` is kept and names the item; History lists both (UI). |
| O4 | Fixed | CLOSE refused for 15 s after the roll opens unless the roll is limited to named players (`item.restrict`) and all of them rolled; the UI Close glow uses the same test. The CALL time is host-local, not logged. |
| O5 | Fixed | `unlock` is no longer cheap and is kept. |
| O6 | Partly fixed | `MLGAVE` logs a master loot give to a non-winner for everyone: a group member, not the winner, once per item. Receipt confirmation by the winner: open. |
| O7 | Fixed | A resync never shortens the local log. |
| O8 | Partly fixed | `lock`/`unlock` name the active item, `specs` the item. Spec values (old/new) are not logged. |
| S1 | Fixed | Prot paladin loses SP; cat (AP, FAP) and bear (DEF, FAP) differ. Spec changes between raids are not shown. |
| S2 | Fixed | SP and HEAL told apart within the group; "damage and healing" suits both. |
| S3 | Fixed | `Use:` lines read; spell hit/crit to SP, plain hit/crit to AP. |
| S4 | Fixed | RAP for hunters, FAP for cat and bear. |
| S5 | Fixed | Dodge and parry no longer count as DEF. |
| S6 | Declined | Armor rule stays for hybrid healers (design trade-off). |
| Need/Greed | Fixed | Add warns when loot is not Master Looter and the item is not in your bags. |
| Docs | Fixed | README reserve and officer log lines corrected. |

## Method

Method: eight parallel auditors (lock and free rolls, soft reserves,
attendance, specs, officer abuse, game mechanics, external loot systems, a
16-week strategic-player Monte Carlo). Every code finding was reproduced with
a lua5.1 script against the real `RLC_Rules.lua`. Scripts live in the session
scratchpad (not in the repo). Three headline findings were re-read in code by
hand: `Eligible` restrict bypass (RLC_Rules.lua:436), reserve START mask 0
(:1046), PHASE with no phase change (:1007).

## Verdict

- **Honest, steady attendance is not beaten by any player-only strategy we
  found, except the reserve sniper (+3-5% value).** Sandbagging (48% of a
  loyal player's value) and dry-farming (75%) lose.
- **The weak spot is what "attended" means.** Ten minutes in the group counts
  as a full night, offline counts as present, and the memory is one raid
  long. A 25% attender who drops in for 10 minutes on off weeks gets *more*
  items per raid attended than a 100% attender.
- **Officers can still tilt a roll and then hide it.** Changing eligibility
  mid-roll, closing early, undo (which wipes the rolls) and a log flood that
  evicts every award are the gaps.
- **Skipping the addon widens your eligibility** from one spec to your whole
  class. The tool currently rewards not using it.

## Simulation (16 weeks, 40 raiders, 200 seeds, real rules engine)

Values: weapon/trinket 3, chest/legs/head/shoulder 2, rest 1.

| Archetype | Attend | Value/week | Value/raid attended | % of Loyal |
|---|---|---|---|---|
| Loyal | 100% | 1.28 | 1.28 | 100 |
| Casual | 50% | 0.77 | 1.53 | 60 |
| Tourist | 25% | 0.44 | **1.75** | 35 |
| Sandbagger (wants only value-3) | 100% | 0.62 | 0.62 | 48 |
| Dry-farmer (wins nothing every other week) | 100% | 0.96 | 0.96 | 75 |
| Reserve sniper | 100% | 1.33 | 1.33 | **104** |
| Late joiner / early leaver | 100% (half nights) | 0.65 | 0.65 | 51 |

Per raid attended, part-timers out-earn regulars (they still need almost
every drop). Today's "dry last raid" rule only trims that (1.92 with no
priority vs 1.75 now). About 1.1 reserve payouts a night go to an
already-locked player.

Rule variants tried in the sim:

| Variant | Loyal value/wk | Tourist % | Dry-farmer % | Loyal full set by wk 16 |
|---|---|---|---|---|
| Today | 1.28 | 35 | 75 | 39% |
| A: 6-week wins/raids ratio | 1.27 | 36 | 73 | 38% |
| B: SR+ (+10 per consecutive week on reserve rolls) | 1.30 | 32 | 75 | 40% |
| B2: same bonus on every roll | 1.31 | **29** | 75 | 43% |
| C: value-3 win bars value-3 next raid | 1.28 | 35 | 74 | 40% |
| **D: regulars (>=75% of last 8 raids) roll first** | **1.34** | 30 | **65** | **47%** |

D best matches "time given = reward". B2 is close. Neither lets the
sandbagger or dry-farmer profit. Neither closes the sniper edge on its own
(see F2).

## Fix first: rule bugs (code-enforceable, each needs a fixture)

| ID | Finding | Where | Smallest fix |
|---|---|---|---|
| F1 | **Restricted rolls ignore locks.** In a tie reroll, the dry-first pass or a co-reserve roll, a locked player still rolls and wins a second locking item. Two co-reservers roll as equals even when one already has an item. | `Rules.Eligible` RLC_Rules.lua:436 | In the restrict branch also require `not S.locks[name]`, except a sole reserver. For co-reserves, roll among unlocked reservers first. |
| F2 | **Reserve as a guaranteed second item.** Reserve a last-boss item, win normally early, get both. Cause of the sniper edge. | reserve rules, README "Your reserve is safe" | Pay a reserve to a locked player only if they have an attendance streak (e.g. in the last 2 trusted raids); otherwise a normal win uses it up. |
| F3 | **Reserve START wipes the class limit.** If the reserver is gone or an officer undoes the win, the item falls back with mask 0: a warrior can win a priest token. | RLC_Rules.lua:1046 | Pass `item.classMask` instead of `0`. |
| F4 | **No addon = whole-class eligibility.** No spec on record falls back to `classInSpecs` (union); `ROLLSEEN` skips the spec gate. A no-addon fury warrior beat the tank on tank plate. Also hits addon users whose spec detection returned nil. | `Rules.Suits` :426-431, ROLLSEEN :965 | With no spec, require the item to suit **every** spec of the class (intersection). Flag "no loot spec" on the Raid tab. |
| F5 | **Two sessions in one night split the record.** End raid + New raid wipes every lock. A 10-player alt run (ZG, UBRS) becomes "last raid" and decides who rolls first next week. | NEW :406, `DryFrom` :1331 | DryFrom: same instance (or title) as tonight's raid, and count a win in any session within ~12 h of the newest. Warn on New raid when locks exist. |
| F6 | **First spec set late turns a main-spec win free.** A player who never confirmed a spec reports an off-spec when the item opens, wins it unlocked. | SPEC intent :917-924 | `normallyEligible` judges a spec first set after the start by class only. |
| F7 | **Undo leaves a free win free.** Win Y (locked), win X free, officer undoes Y: unlocked again with X uncounted. | UNDO :747-770 | On undo, keep the player locked if they hold a free win they were normally eligible for. |
| F8 | **Reserves stay open while drops are visible** if the leader never clicks Start raid (reserves close only at the first Add). | PHASE / ADD | Host sends PHASE live on the first `ENCOUNTER_START` in an instance, or refuse ADD while the phase is reserve. |
| F9 | **Rolls during a boss pull vanish** (chat secret), so the roller can see a low number and roll again after. | RLC_Loot.lua:80-86, first-roll rule :956 | Refuse CALL during `C_InstanceEncounter.IsEncounterInProgress()`; void an open roll if a pull starts. |

## Attendance: make "time given" mean time given

| ID | Finding | Fix |
|---|---|---|
| A1 | **10-minute drop-in = full attendance** (`att` is a bool; two sightings 600 s apart). Lifts a tourist above a loyal raider per raid. | Store seconds present per raid; count only if present for e.g. 75% of start-to-end. |
| A2 | **Offline or out-of-instance counts as present** (no `UnitIsConnected` check). Also pads the 10-player minimum with parked alts. | Count time only while `UnitIsConnected` and in the host's instance (probe first). |
| A3 | **Memory is one raid long.** A dry regular who misses one week loses priority; a full attender who won last week ranks with someone absent three weeks. | Variant D: regulars (>= 75% of last 8 trusted raids) roll first. Or a rolling wins-per-attended-raid ratio. |
| A4 | **The host's own saved history is the source of truth.** A host who missed last week computes from two weeks ago (37 past winners listed dry in the test). | Show the dry list and its source raid date at raid start, log it (DRY ops are not logged today), refuse when the source is older than ~8 days. |
| A5 | **Bench earns nothing** and loses dry status. | Officer "bench" op that marks attendance for the night, logged. |
| A6 | **Stats is not attendance.** "Raids" counts raids where you wanted, rolled or won, not where you were present. A raider who wants nothing shows 0 raids. No attendance %, join/leave times or bench. | Count Raids from `att`; add Att % over trusted raids; later minutes present. |
| A7 | **Alts / multiboxing** double rolls; locks and dry are per character. | Officer "linked characters" list: a win locks all linked names. Or a stated one-character rule in Help. |

## Officers and host: prevent where possible, show the rest

| ID | Finding | Prevent / detect | Fix |
|---|---|---|---|
| O1 | **Log flood erases evidence.** PHASE live is accepted while already live, each adds a non-cheap `live` entry; 200 evict every award, undo and close. Award-then-undo loops do the same. | Preventable | Refuse a PHASE that does not change the phase. Never evict `award`, `undo`, `close`; cap other kinds separately. |
| O2 | **Change eligibility mid-roll.** After the rolls are in: LOCK the top roller, SETSPEC them off-spec, or SPECS the item to the friend's spec, then CLOSE. Also SPECS to an empty spec to force OPEN and make a main-spec win free. A spec change after start also silently drops a reserver at START. | Preventable | Refuse LOCK, SETSPEC, SPECS touching a rolling item; or freeze eligibility at CALL. Keep the suggested specs from ADD for `normallyEligible` and OPEN. Flag "winner was not top roll" in History. |
| O3 | **UNDO wipes the rolls; CANCEL hides the item** (History lists only done items; `cancel` is cheap and does not name the item). | Detectable | Keep the undone result on the item. List cancelled items. Make `cancel` non-cheap with the item key. |
| O4 | **Close timing.** CALL, friend rolls, CLOSE the same second. Later rolls are never recorded. | Preventable | Refuse CLOSE before ~15 s after CALL unless every eligible wanter has rolled. Log the CALL time. |
| O5 | **Repeated unlock of a friend**; `unlock` is cheap and can be evicted. | Detectable | Make `unlock` non-cheap. |
| O6 | **Master looter gives from Blizzard's own menu** to someone else. The hook ignores non-winner gives; the award sits on the looter's local owed list, which they can clear. Delivery itself is self-asserted. | Detectable | In the `GiveMasterLoot` hook, log a give of a session item to a non-winner for everyone. Later: winner's client confirms receipt. |
| O7 | **Host owns the live record.** A resync can overwrite raiders' live log. Ended raids are frozen. | Detectable | On resync never shrink the local log, only append. Tell raiders their own History is the evidence. |
| O8 | **Log lines lack values.** `spec`, `specs`, `lock`, `unlock` do not say what changed or which item. | Detectable | Record old and new value and the active item key. |

## Spec classifier (who an item suits)

| ID | Finding | Fix |
|---|---|---|
| S1 | **Free supersets.** Bear covers every Cat item (+64), Fury covers Arms (+92), Prot paladin (wants DEF, STR and SP) can roll on 408 grid items vs Ret 138 and Holy 70. Players will declare the superset. | Drop SP from `PALADIN.PROT`. Make Cat and Bear differ, or one Feral spec. Show spec changes between raids. |
| S2 | **Spell damage and healing are one group.** Mages and warlocks roll on priest healing cloth; Elemental on Resto mail. With "one before two", a mage with no item beats a priest on the priest's own robe. | Split `{SP}` and `{HEAL}` groups (dual-stat items keep both). |
| S3 | **Use-only trinkets and hit/crit-only items go to every class** (only `Equip:` lines are read). | Scan `Use:` lines too; spell hit/crit to SP, plain to AP. |
| S4 | **Ranged and feral AP read as melee AP.** Bows go to rogues and warriors ahead of hunters. | Separate RAP (hunters) and FAP (cat, bear). |
| S5 | **Dodge or parry on dps gear makes it tank-only.** | Only "defense" (and block on shields) counts as DEF. |
| S6 | Hybrid healers capped by armor type (holy paladin, resto druid). Design trade-off. | For healer specs, skip the armor rule when the item has HEAL. |

## Design trade-offs (not bugs; decide on purpose)

- **Every item is one lock.** A weak ring locks as hard as the best weapon.
  Waiting for the big drop is the intended pass and the sim shows it does
  not pay. An officer "free item" flag on Add (patterns, quest items, BoE),
  logged, covers the cases where it hurts.
- **Pickiness keeps you dry.** Dry ends only on a win. Fine as long as dry is
  earned by attendance (A1-A3).
- **Reserves are public and changeable until close.** Showing counts, not
  names, until close removes last-second sniping.
- **A locked friend wins a free roll and trades it on.** Cannot be stopped;
  Stats could flag a free win traded to someone else (`RLC_Loot` sees the
  trade partner).
- **Need/Greed beats the addon** without Master Looter. Already warned in the
  README; also warn on Add when loot is not Master Looter.

## Bad gear vs effort

External research (DKP, EPGP, Loot Council, Suicide Kings, softres SR+,
TMB, Gargul) agrees on one point. No-points guilds rarely weight loot by
gear or performance numbers. That becomes Loot Council politics, and it
starves the players who most need gear, which is what fixes "contributes
less". They gate *effort* with yes/no minimums instead:

- **Attendance:** 75-90% to count as a regular, or present at the first pull.
- **Prep:** stated consumables and resists. Failing it costs priority for
  that night only.
- **Trial period:** 2 weeks or N raids, with trials rolling after members on
  contested items but keeping free rolls.

That fits "time given = reward": turning up *prepared* is the time given, and
a low item level is not a penalty. As addon features:

1. Regulars roll first (variant D), replacing "dry last raid". Biggest win.
2. Officer "not ready" mark for the night (typed reason, shown in History):
   that player rolls in the open tier only.
3. Trial status for the first N raids.
4. Bench credit (A5).

All officer marks must be logged and visible, because favouritism is the
known failure of every judgement-based system.

Sources: [SK FAQ](https://www.wowace.com/projects/skg/pages/faq),
[Gargul](https://www.curseforge.com/wow/addons/gargul),
[TMB FAQ](https://thatsmybis.com/faq),
[Method softres guide](https://www.method.gg/wow-classic/how-to-use-softres-it-for-your-raids-in-wow-classic-soft-reserve-hard-reserve-explained),
[Guild Order Forever loot systems](https://guildorder.com/hi/games/wow_forever/wiki/loot-systems-for-a-10-and-a-20),
[Wowpedia EPGP](https://wowpedia.fandom.com/wiki/EPGP),
[Blizzard forum: trial got 0 loot](https://eu.forums.blizzard.com/en/wow/t/wasnt-given-even-1-loot-for-the-entire-raid-cause-i-was-trial-raider-is-this-normal/413174?page=2),
[Blizzard forum: loot council](https://eu.forums.blizzard.com/en/wow/t/loot-council-doesnt-feel-rewarding/187082).

## What held up

- Rolls: only server roll lines, 1-100 only, first roll only, group members
  only, no rolls before CALL, leavers dropped at CLOSE, ties wipe and reroll.
- Holding back on I want this and then winning the open roll in spec counts
  as a locking win. A /roll without I want this counts and locks.
- OPEN is refused while an eligible wanter or a reserver is present, and in
  the first 15 s after an item goes up.
- AWARD only to group members, logged, locks. Only the host makes officers.
  Undo of a delivered item needs the host. Non-leader raids are marked
  unverified and excluded from Stats and the dry list.
- Locks survive leaving and rejoining. Players cannot change spec after the
  start. A reserve made under one spec is dropped if the spec changes.
- Reserves close at the first Add; one per character; whisper reserves are
  checked by GUID.

## Docs out of date

- README "A reserve ignores class limits" is wrong: the reserve is checked
  against class and spec when made and again at START.
- README "every ... spec change ... in the Officer log" holds only until a
  log flood (O1), and cancel is not covered (O3).

## New in-game probes (for docs/probes.md)

1. `/dump UnitIsConnected("raidN"), UnitInRange("raidN")` for an offline
   member and one outside the instance (A2).
2. Boss pulled during an open roll: does the roller see their own roll line?
   `/dump canaccessvalue(text)` on the roller (F9).
3. Master looter gives a slot to a non-winner from Blizzard's menu: does the
   `GiveMasterLoot` hook fire, with which (slot, index)? (O6)
4. Group loot, BoP drop: does the Need winner get `BIND_TRADE_TIME_REMAINING`
   and can they trade it to another raider at the kill? (A7, checklist 18)

## Suggested order

1. F1, F3, O1, O2 (small diffs, the clearest unfairness).
2. F4, F5, A1, A2 (attendance and no-addon gaps).
3. Variant D (regulars roll first) plus F2 tied to it, A4-A6 for admin.
4. O3-O8 transparency, S1-S5 classifier.
5. Optional officer tools: not-ready mark, trial status, linked characters,
   free-item flag.
