# LockpickSettings 3.1 release

Notes for the 3.1 line. 3.1.0 reworks **auto-solve** on top of the 2.x extra
tries, next-move hint, and connection display. F6 now fast-solves the current
lock (press again to cancel), collapsing the move animation and clearing the
whole lock in a couple of seconds and stopping by itself the moment it opens.
Shift+F6 toggles **full-auto-every-lock**: every lock you engage then solves
itself automatically (Shift+F6 again turns it off and cancels any solve in
progress). The old slow full-auto and the single-step modes from the 3.0 line
were removed. Auto-solve still earns the lockpicking achievement and is off by
default.

## Builds

Artifacts are produced from the single source tree with
`tools/build_release.ps1` into `release/build/` (gitignored): the `-manual`,
`-complete`, and `-vortex` (FOMOD) variants. They are uploaded directly to the
mod host; no zip is archived in this folder.

## Live mod page

The Nexus mod page content (description, summary, preview, raw-linked images)
lives in its own folder, not here: see
[`../../nexus-page/`](../../nexus-page/). That folder mirrors the current live
page and keeps stable image URLs across builds.
