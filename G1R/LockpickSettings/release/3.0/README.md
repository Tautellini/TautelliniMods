# LockpickSettings 3.0 release

Notes for the 3.0 line. 3.0 adds **auto-solve** (F6 plays the next move, Shift+F6
runs full auto to open) on top of the 2.x extra tries, next-move hint, and
connection display. 3.0.1 drops the `-alpha` suffix and fixes auto-solve giving
up on hard locks (it now waits through long solver searches instead of timing
out and nudging).

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
