# LockpickSettings 3.0 release

Packaged builds for the 3.0 line. 3.0.0-alpha adds **auto-solve** (F6 plays the
next move, Shift+F6 runs full auto to open) on top of the 2.x extra tries,
next-move hint, and connection display.

## Contents

```
3.0/
  LockpickSettings-3.0.0-alpha.zip   the build (later 3.0.x builds land here too)
```

Builds are produced from the single source tree with `tools/build_release.ps1`,
which emits the `-manual`, `-complete`, and `-vortex` (FOMOD) variants into
`release/build/` (gitignored). The published archive is copied here.

## Live mod page

The Nexus mod page content (description, summary, preview, raw-linked images)
lives in its own folder, not here: see
[`../../nexus-page/`](../../nexus-page/). That folder mirrors the current live
page and keeps stable image URLs across builds.
