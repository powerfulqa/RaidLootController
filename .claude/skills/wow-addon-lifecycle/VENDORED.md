# Vendored skill

Source: https://github.com/TheMizeGuy/wow-addon-dev (MIT, see `LICENSE`)
Commit: f928572a9428d29327a96c2549b0068101961c4e (2026-07-06), copied 2026-10-09.

It has no plugin manifest, so it lives here as a project skill and travels with the repo.

Local changes:
- `SKILL.md`: renamed `wow-addon-dev` -> `wow-addon-lifecycle` (the name clashes with two
  installed plugins) and added a note pointing at this repo's `CLAUDE.md`.
- `scripts/install-addon.ps1`, `scripts/list-installed-addons.ps1`: added the `forever`
  edition (`_classic_beta_`). Recheck the folder name at Forever's launch.

To update: clone the source again, copy `SKILL.md`, `references/`, `scripts/`, `examples/`,
then reapply the changes above.
