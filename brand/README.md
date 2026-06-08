# brand/

The TautelliniMods house style: one look and feel shared across every mod, so the
suite reads as one author's work. Full rationale and rules in
[`DESIGN-SYSTEM.md`](DESIGN-SYSTEM.md).

## Files

```
DESIGN-SYSTEM.md   the system + the reusable generation prompt (read this)
house.css          fixed tokens: colors, type, geometry (same for every mod)
themes/g1r.css     the one per-game block: the accent ramp ("Aurum" gold)
templates/         component sources (SVG-in-HTML), import house.css + a theme
  hero.html        1920x1080 release header
  section.html     1920x300 section divider
  card.html        720x440 feature card (+ hotkey cap)
  badge.html       960x180 badge row
  footer.html      1920x140 footer (the only persistent brand tag)
render.ps1         rasterize templates to PNG (headless Chrome/Edge)
out/               rendered PNGs (created on first render)
```

## Render

```powershell
powershell -File brand\render.ps1                 # all templates
powershell -File brand\render.ps1 -Only hero.html # just one
```

Open any `templates/*.html` in a browser to preview live. Webfonts (JetBrains
Mono, Inter) load over the network; for offline determinism install them locally
or embed woff2 and swap the `@import` in `house.css`.

## Add a new game

1. Copy `themes/g1r.css`, rename it, pick one accent, derive `hi` / `lo` / `glow`.
2. Point a template's second `<link>` at the new theme. Change nothing else.

That one accent is the entire per-game surface. Everything else is the brand.

## The rules that matter

- Premium-dark mood, near-black base, one restrained glow, generous space.
- Mono for titles/labels/data, sans for body.
- Corner-bracket frame is the signature.
- Exactly one per-game accent; `--alert` and `--danger` are the only other hues.
- Voice: honest, technical, concrete numbers, label caveats. No "—", no fluff.
