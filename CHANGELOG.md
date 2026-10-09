# Raid Loot Controller - Changelog

Per-release notes. For what the addon does, see the [README](README.md).

---

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
