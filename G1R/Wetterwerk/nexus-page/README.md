# nexus-page/ (Wetterwerk live mod page)

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
    hero-cards.png     1920 x 1080  browse-thumbnail variant (feature cards)
    gallery-control.png  1920 x 1080  gallery: weather control (F9 / Shift+F9 / F10)
    gallery-presets.png  1920 x 1080  gallery: presets (calm to stormy)
    gallery-values.png   1920 x 1080  gallery: every exposed value
    gallery-safe.png     1920 x 1080  gallery: safe to use
    section-*.png      1920 x 300   six description section-header strips
```

The images are rendered from `brand/` at the repo root. The whole set is the
Wetterwerk template group plus the "Azur" (light-blue) theme:

```
brand/themes/wetterwerk.css         the one per-mod accent block (light sky blue)
brand/templates/wetterwerk/*.html   hero, hero-cards, nexus-header, galleries,
                                     section, card, footer, badge
brand/render-wetterwerk.ps1         rasterize the above to brand/out/wetterwerk/
```

Edit and re-render there, then re-copy the PNGs here. Never hand-edit these PNGs.
The `section-*.png` strips and the hero/galleries stay near-black; they are
contained banners (Nexus draws its own gradient over the bottom of the header).
The footer is plain text (name, repo link, thanks), not an image.

To re-render and re-copy in one go:

```powershell
powershell -File brand\render-wetterwerk.ps1
# then copy the page images:
$src = "brand\out\wetterwerk"; $dst = "G1R\Wetterwerk\nexus-page\images"
"nexus-header hero hero-cards gallery-control gallery-presets gallery-values gallery-safe section-features section-install section-config section-safety section-compatibility section-troubleshooting" -split ' ' |
  ForEach-Object { Copy-Item "$src\$_.png" "$dst\$_.png" -Force }
```

## Where each image goes on Nexus

- **nexus-header.png** is the mod's **Header image**, set through the Nexus UI on the
  mod edit page (the header slot under image management). It is NOT embedded via
  BBCode, and Nexus draws its own gradient over the bottom, which is why the banner
  keeps its text in the top-left.
- **gallery-*.png** are uploaded to the mod's **Images** tab (the gallery). The
  `-bare` / `-bare-inv` variants in `images/` drop the eyebrow for optional inline
  embedding in the description body.
- **hero.png** and the six **section-*.png** strips are embedded in the description
  body, in the order `nexus-description.bbcode` lists them. The features and the
  footer are plain text, not images.

## Hosting the description images

Nexus BBCode embeds an image by URL: `[img]https://.../file.png[/img]`. The file must
be publicly reachable; you cannot point BBCode at a local file. The default this page
uses is GitHub raw:

```
https://raw.githubusercontent.com/Tautellini/TautelliniMods/main/G1R/Wetterwerk/nexus-page/images/<name>.png
```

`nexus-description.bbcode` already points its `[img]` tags at these. They resolve once
the images are committed and pushed to `main`. The same URLs feed a GitHub README.

> The 1300x372 header is always uploaded through the Nexus UI, not hotlinked.
