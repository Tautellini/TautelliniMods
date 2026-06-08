# nexus-page/ (LockpickSettings live mod page)

The content of the **live Nexus mod page**. This is prod: the description here is
what gets pasted into the page, and `images/` is raw-linked from that description,
so changing a file here (once committed and pushed to `main`) changes what readers
see on Nexus. Treat it accordingly.

It is not versioned per build on purpose: it mirrors the *current* live page, so the
raw image URLs stay stable as the mod updates. The downloadable build zips live
separately under `release/<version>/`.

## Contents

```
nexus-page/
  nexus-description.bbcode        the page body, pasted into the Nexus description editor
  nexus-description.preview.html  local preview of that BBCode (open in a browser)
  nexus-summary.txt               the short summary shown under the title
  images/
    nexus-header.png   1300 x 372   mod-page Header image
    hero.png           1920 x 1080  top-of-description banner
    gallery-tries.png        1920 x 1080  gallery: more tries (durability)
    gallery-hint.png         1920 x 1080  gallery: next-move hint
    gallery-connections.png  1920 x 1080  gallery: connection display
    gallery-safe.png         1920 x 1080  gallery: safe to use
    section-*.png      1920 x 300   six description section-header strips
```

The images are rendered copies from `brand/` at the repo root: edit and re-render
there, then re-copy here. Never hand-edit these PNGs. The `section-*.png` strips
carry the Nexus page surface (`--page`, ~#29292e) as their base so they merge into
the description; their corner brackets use `--hairline-page` to stay visible on that
grey. The hero, galleries and header stay near-black; they are contained banners.
The footer is plain text (name, repo link, thanks), not an image.

## Where each image goes on Nexus

- **nexus-header.png** is the mod's **Header image**, set through the Nexus UI on the
  mod edit page (the header slot under image management). It is NOT embedded via
  BBCode, and Nexus draws its own gradient over the bottom, which is why the banner
  keeps its text in the top-left.
- **gallery-*.png** are uploaded to the mod's **Images** tab (the gallery).
- **hero.png** and the six **section-*.png** strips are embedded in the description
  body, in the order `nexus-description.bbcode` lists them. The features and the
  footer are plain text, not images.

## Hosting the description images

Nexus BBCode embeds an image by URL: `[img]https://.../file.png[/img]`. The file must
be publicly reachable; you cannot point BBCode at a local file. Two reliable options:

### 1. Host on GitHub raw (the default this page uses)

These PNGs are committed to the repo, so each has a raw URL:

```
https://raw.githubusercontent.com/Tautellini/TautelliniMods/main/G1R/LockpickSettings/nexus-page/images/<name>.png
```

`nexus-description.bbcode` already points its `[img]` tags at these. They resolve
once the images are committed and pushed to `main`. The same URLs feed a GitHub
README.

### 2. Host on Nexus itself

1. Upload the image to the mod's **Images** tab.
2. Open it at full size, right-click, **Copy image address** (the URL lives on
   `staticdelivery.nexusmods.com`).
3. Swap it into the description: `[img]<that URL>[/img]`.

Everything then stays on Nexus's own CDN. Use this if a future Nexus policy ever
blocks off-site images; otherwise the GitHub raw URLs are simpler to maintain.

> The 1300x372 header is always uploaded through the Nexus UI, not hotlinked.
