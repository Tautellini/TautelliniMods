# LockpickSettings 2.7 release

Packaged builds for the 2.7 line and the Nexus / GitHub image kit. The images
are rendered copies from `brand/` at the repo root (edit and re-render there,
then re-copy here); never hand-edit these.

## Contents

```
2.7/
  LockpickSettings-2.7-alpha6.zip   the build (later 2.7.x builds land here too)
  images/
    nexus-header.png         1300 x 372   mod-page header banner
    hero.png                 1920 x 1080  top-of-description banner
    gallery-tries.png        1920 x 1080  gallery: more tries (durability)
    gallery-hint.png         1920 x 1080  gallery: next-move hint
    gallery-connections.png  1920 x 1080  gallery: connection display
    gallery-safe.png         1920 x 1080  gallery: safe to use
```

## Where each image goes on Nexus

- **nexus-header.png** is the mod's **Header image**, set through the Nexus UI on
  the mod edit page (the header slot under image management). It is NOT embedded
  via BBCode, and Nexus draws its own gradient over the bottom, which is why the
  banner keeps its text in the top-left.
- **gallery-*.png** are uploaded to the mod's **Images** tab (the gallery).
- **hero.png** is embedded at the top of the description (see hosting below).

## Hosting images for the description BBCode

Nexus BBCode embeds an image by URL: `[img]https://.../file.png[/img]`. The file
must be publicly reachable; you cannot point BBCode at a local file. Two reliable
options:

### 1. Host on Nexus itself (recommended for the description)

1. Upload the image to the mod's **Images** tab.
2. Open it at full size, right-click, **Copy image address**. The URL lives on
   `staticdelivery.nexusmods.com`.
3. Paste it into the description: `[img]<that URL>[/img]`.

Everything stays on Nexus's own CDN, so it always loads and is never stripped as
an untrusted off-site link. This is the safest path for description images.

### 2. Host on GitHub (also feeds the GitHub README)

These PNGs are committed to the repo, so each has a raw URL:

```
https://raw.githubusercontent.com/Tautellini/TautelliniMods/main/G1R/LockpickSettings/release/2.7/images/<name>.png
```

Use that inside `[img][/img]`, or directly in the GitHub README. It works, but an
external host can be slower and a future Nexus policy could block off-site images,
so prefer option 1 for the Nexus description and keep GitHub raw for the README.

> The 1300x372 header is always uploaded through the Nexus UI, not hotlinked.
