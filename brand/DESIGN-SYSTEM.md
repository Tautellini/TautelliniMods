# TautelliniMods Design System

The house style for every TautelliniMods release page, header, card, badge, and
README. The goal is recognition by feel: someone who saw one of your mods should
clock the next one as "same hand" without needing a logo on it.

This document is the source of truth. The reusable generation prompt lives at the
bottom (section 9). The token values in section 3 are the contract every asset
obeys.

---

## 1. Goal and principles

**Goal.** A distinct, game-agnostic look and feel shared by all current and
future mods, so the suite reads as one author's work. Recognition comes from a
consistent house style plus a small footer, not from a tag stamped on everything.

**The five fixed decisions** (settled, do not relitigate per mod):

1. **Fixed look, accent shifts.** Same layout skeleton, typography, finish, and
   near-black base on every mod. Exactly one accent color changes per game.
2. **Fresh signature, not the gothic look.** The premium-dark style below is the
   house style. The gold/Palatino/vignette art in `G1R/LockpickSettings/release/`
   is legacy LockpickSettings theming, not the brand (see Open Questions for its
   migration).
3. **Premium dark product mood.** Deep near-black, crisp type, one restrained
   accent glow, generous negative space. Reference energy: a modern dev tool
   brand (Linear, Raycast, Vercel), not a fantasy game box.
4. **Mono marks, sans body.** Monospace for titles, labels, versions, and data.
   Grotesk sans for prose.
5. **Corner-bracket frame is the signature motif.** Cut-corner, spec-sheet
   brackets around headers and cards. This is the element people subconsciously
   recognize.

**Reach of theming.** Themed everywhere it earns its place, not at 100%. Section
headers and any element worth visualizing become themed components; the rest
stays clean, readable body. A wall of decorated text is a failure, so is a wall
of undecorated text.

---

## 2. Scope

**In scope**
- Visual identity: color, type, motif, spacing, the named components.
- A shared token set the assets import, so one edit restyles everything.
- The asset inventory for Nexus Mods pages and GitHub READMEs.
- The brand voice for copy.
- A reusable prompt to generate any asset.

**Out of scope (for now)**
- A logo, mascot, or wordmark stamped on assets. Explicitly not wanted. The only
  persistent brand tag is the footer (section 6f).
- An author-profile avatar / monogram. Optional, deferred (Open Questions).
- Migrating existing LockpickSettings art (decision pending, Open Questions).
- A second game theme (defined when a second mod exists; section 5 shows how).

---

## 3. Tokens

Two layers: **house** tokens are identical for every mod; a **theme** supplies the
one accent ramp that changes per game. Swapping a game is swapping the theme block.

### 3a. House tokens (fixed, all mods)

```
/* surfaces */
--bg-0:          #0a0a0c   /* near-black: hero / gallery banners, feature-card panels */
--bg-1:          #121217   /* raised panel / strip */
--bg-2:          #191920   /* card (on a near-black page) */
--page:          #29292e   /* host page surface (Nexus description); see note below */
--hairline:      #2a2a33   /* 1px rules, default bracket color (on near-black) */
--hairline-2:    #3a3a46   /* stronger divider on near-black */
--hairline-page: #5e5e6a   /* brackets / rules on the --page surface; the near-black
                              hairlines vanish on that lighter grey */

/* ink */
--ink-0:         #ECECEF   /* primary text */
--ink-1:         #A6A6B0   /* secondary text */
--ink-2:         #6E6E7A   /* captions, muted labels, footer */

/* shared semantics (NOT per-game) */
--alert:         #E9A23B   /* warnings, honest caveats, "off by default" */
--danger:        #FF6B6B   /* incompatibility, destructive, "do not" */
```

**Banners vs. inline assets.** A full-bleed banner the host frames as one image
(hero, gallery, the Nexus header) keeps the near-black `--bg-0` base. An asset
embedded in the flowing description body (section-header strip, footer) bases on
`--page` instead, so it merges into the host page rather than reading as a dark
box on it; its brackets and rules use `--hairline-page`, since the near-black
hairlines vanish on that lighter grey. A section strip carries no full border,
only its corner brackets (in `--hairline-page`), kept bright enough to mark the
strip on the grey. `--page` mirrors the Nexus description background; if a host
differs, it is the one token to retune.

A feature card (6c) is the exception that proves the rule: it bases on `--page`
too, but keeps a near-black (`--bg-0`) panel so the panel still reads as a
distinct card floating on the page. The LockpickSettings description writes its
features as body text under one FEATURES strip rather than as cards; the card
component stays available for feature grids that want the visual.

### 3b. Theme tokens (one block per game, only the accent changes)

```
/* THEME: g1r "Aurum" (Gothic 1 Remake) */
--accent:        #D4B06A   /* primary accent, carried from LockpickSettings gold */
--accent-hi:     #F0D89C   /* highlight stop */
--accent-lo:     #9A763C   /* shadow stop */
--accent-glow:   rgba(212,176,106,0.14)  /* the restrained glow, low alpha */
```

Future theme, illustrative only:

```
/* THEME: <game> "Coolant" (a sci-fi title) */
--accent:        #5BC8E6   /* steel cyan */
--accent-hi:     #A6E8F5
--accent-lo:     #2E8AA6
--accent-glow:   rgba(91,200,230,0.14)
```

**Rule:** never introduce a second per-game color. If art needs more range, use
the accent ramp (`hi` / `lo`) and the ink greys. `--alert` and `--danger` are the
only other hues, and they mean the same thing in every mod.

### 3c. Typography tokens

```
--font-mono:  "JetBrains Mono", ui-monospace, "Cascadia Code", Consolas, monospace
--font-sans:  "Inter", system-ui, "Segoe UI", Roboto, sans-serif
```

Both are open (OFL) and embeddable for HTML to PNG rendering. Install them locally
or `@font-face` them in the shared CSS so renders are deterministic across machines.

**Mono is for:** titles and wordmarks, version strings (`v2.7`), eyebrows /
kickers, section labels, the status-line band, key:value data, hotkey caps,
badge labels.
**Sans is for:** body prose, descriptions, list items, captions.

Type scale (hero reference, 1920 wide; scale down proportionally for smaller art):

```
eyebrow / kicker   mono   28-34px   letter-spacing 6-9px   --ink-2 or --accent
title              mono   96-128px  weight 700             --ink-0, accent on a keyword
subtitle           sans   40-48px   weight 400-500         --ink-1
body               sans   28-34px   weight 400             --ink-1 / --ink-2
status band        mono   28-32px   letter-spacing 1-2px   --ink-2, accent on values
```

### 3d. Geometry tokens

```
--radius:        0px      /* corners are sharp; "cut" via 45deg notch, not rounding */
--notch:         14px     /* size of the diagonal cut on cut-corner panels */
--bracket-len:   40px     /* arm length of a corner bracket at hero scale */
--bracket-w:     3px      /* bracket stroke at hero scale */
--rule-w:        1px      /* hairline thickness */
--pad:           48px     /* default inner padding at hero scale */
--gutter:        64px     /* generous negative space; premium feel depends on it */
```

---

## 4. The signature motif: corner brackets

The recurring object is an L-shaped bracket at the corners of a frame, like a
spec sheet or a camera reticle. It appears on the hero, every section header, and
every card.

- Four corners, each an L of length `--bracket-len`, stroke `--bracket-w`.
- Default color `--hairline`; promote to `--accent` for the primary frame on a
  hero or a highlighted card.
- For a stronger statement, cut the panel corner itself at 45 degrees by `--notch`
  (a clipped, chamfered rectangle) and let the bracket trace that cut.
- Pair brackets with tiny registration ticks or a mono coordinate label
  (`[ 01 ]`, `LOCKPICK.SET`) for the instrument feel. Use sparingly.

The glow is the second motif and must stay restrained: one soft radial of
`--accent-glow` behind the title or the key graphic, large blur, low alpha. It is
a hint of light, not the gothic vignette. If it reads as "fog," it is too strong.

---

## 5. Defining a new game theme

When a second mod lands:

1. Copy the theme block (3b), rename it (`game "CodeName"`).
2. Pick one accent. Either choose freely or sample the game's own UI so it
   harmonizes in-context; derive `hi` / `lo` / `glow` from it.
3. Change nothing else. House tokens, type, motif, spacing, components all carry
   over unchanged. That carryover is the brand.

A theme is one accent ramp. That is the entire per-game surface.

---

## 6. Components

Each component is a reusable template that pulls the tokens. Build them once under
`brand/` (section 8), then fill content per asset.

### 6a. Hero header (Nexus + GitHub banner)

1920x1080 default (Nexus inline image friendly; crops fine for a GitHub banner).

```
+----------------------------------------------------------+
| [game]                                          [ v2.7 ] |   eyebrow (mono) + version cap
|                                                          |
|  M O D   N A M E                                         |   title, mono, accent on one word
|  ----------                                              |   short accent rule
|  One honest line of what it does.                        |   subtitle, sans
|                                                          |
|                              (accent glow behind a       |
|                               large borderless icon, or  |   graphic / image, right
|                               a framed screenshot)       |
|  [ loaded 2.7 . 416 graphs . F7 hint . save-safe ]       |   status band, mono (signature)
+----------------------------------------------------------+
```

Corner brackets frame the whole canvas in `--accent`. The status band echoes your
UE4SS `Loaded ...` log line and should carry real facts, not slogans.

**Framing rule.** The bracketed rectangular mat is for actual images (screenshots)
only. A standalone brand graphic (the lock, the shield) is presented borderless
and larger, carried by its glow alone, never boxed.

### 6b. Section header strip (Nexus sections, GitHub section dividers)

Wide and short (1920x300 or 1200x220). Corner brackets in `--hairline`, a mono
section label, an optional small accent glyph, one hairline rule. This is what
makes GitHub "themed everywhere" without decorating the body text.

```
+----------------------------------------------------------+
| [ 02 ]  NEXT-MOVE HINT                      optional, off |
|         ----------------------------------------         |
+----------------------------------------------------------+
```

### 6c. Feature card

Cut-corner panel on `--bg-2`, bracket corners, mono title, sans body, optional
hotkey cap. Used for feature grids on both surfaces.

### 6d. Badge

Small bracketed chip, mono label, e.g. `[ SAVE-SAFE ]`, `[ NO FILE PATCHES ]`,
`[ KEYBOARD + CONTROLLER ]`. Accent border for a positive claim, `--ink-2` for
neutral facts.

### 6e. Hotkey cap

A mono key on a `--bg-1` cap with a hairline border and a thin top highlight, for
keys like `F7`. The premium-dark replacement for the gold keycap in the legacy art.

### 6f. Footer (the only persistent brand tag)

One quiet mono line, `--ink-2`, above a hairline rule, with a single accent
bracket. The agreed minimum brand mark:

```
------------------------------------------------------------
[ a Tautellini mod ]   .   source & issues -> github.com/Tautellini/TautelliniMods
```

Goes on every description page and README. Nothing louder than this.

---

## 7. Brand voice (copy is part of the identity)

The writing is as recognizable as the visuals. It is already strong in the
existing pages; codify it.

**Do**
- Second person, direct: "your call when to cheat", "press F7 and the piece lights up".
- Honest and technical. State caveats plainly and label them ("Honest caveat:").
- Safety-first and measurement-first. Prefer "the mod fails toward hint-off rather
  than a wrong hint" over hype.
- Concrete numbers, not adjectives: "2/4/6 to 12/14/16", "all 416 locks".
- Dry confidence. Respect the reader's intelligence and agency.

**Do not**
- No marketing fluff, no superlatives, no exclamation spam.
- No "—" (em dash) anywhere. No AI-typical phrasing or hedging.
- Do not oversell. If something is alpha or has a known issue, say so.

---

## 8. Build and pipeline

Code-generated, token-driven, reproducible. Author SVG (inside HTML for fonts and
CSS), render to PNG.

Proposed layout:

```
brand/
  DESIGN-SYSTEM.md        this file
  house.css               3a + 3c + 3d as CSS custom properties, @font-face
  defs.svg                shared SVG <defs>: accent gradient, glow filter,
                          bracket <symbol>, cut-corner clip
  themes/
    g1r.css               3b for "Aurum"
  templates/
    hero.html             6a, includes house.css + a theme + defs.svg
    section.html          6b
    card.html             6c
    badge.html            6d
    footer.html           6f
  render.ps1              rasterize *.html -> *.png (headless Chrome screenshot)
```

Mechanics:
- Flat colors come through CSS variables on SVG presentation (`fill` via CSS).
- Gradients, the glow filter, and the bracket shape live in `defs.svg` and are
  referenced by id, so they stay identical across assets.
- Swapping a game is swapping which `themes/*.css` the template links.
- There is currently no renderer in `tools/`; PNGs were made by hand. Standardize
  on headless Chrome (`chrome --headless --screenshot --window-size=W,H`) in
  `render.ps1` so any template renders deterministically. Confirm before building.

This keeps the "change one token, everything updates" property you picked.

---

## 9. The reusable generation prompt

Paste this to Claude (or run it in this repo where the files are readable). Fill the
ALL-CAPS slots. It encodes the whole system so each asset comes out on-brand.

```
Generate a [ASSET TYPE: hero header | section header | feature card | badge | footer
| full Nexus BBCode description | GitHub README block] for a TautelliniMods release.

Follow brand/DESIGN-SYSTEM.md exactly. Output [an SVG-in-HTML file ready to render
to PNG | Nexus BBCode | GitHub Markdown].

CONTEXT
- Mod: [MOD NAME]
- Game: [GAME] -> use theme [THEME NAME / accent hex if no theme yet]
- Version: [vX.Y]
- One-line purpose: [HONEST ONE-LINER]
- Key facts / numbers: [e.g. 2/4/6 -> 12/14/16; 416 locks; F7 hint; save-safe]
- Status-band content (real facts, not slogans): [e.g. loaded 2.7 . 416 graphs . F7 . safe]
- For images: dimensions [e.g. 1920x1080]; right-side graphic [describe or "none"].

NON-NEGOTIABLES
- Premium-dark mood: base #0a0a0c, generous negative space, ONE restrained accent
  glow (low alpha), never a heavy vignette.
- Mono (JetBrains Mono) for titles/labels/versions/data; sans (Inter) for body.
- Corner-bracket frame is the signature; cut corners with a 45deg notch, sharp
  (0 radius) otherwise.
- Exactly one per-game accent (from the theme). Only other hues: --alert amber for
  caveats, --danger red for incompatibility. No second accent color.
- Pull values from the tokens in section 3. Do not invent off-palette colors.
- Voice (section 7): honest, technical, second person, concrete numbers, label
  caveats. No "—", no marketing fluff, no AI-typical phrasing.
- Theming is pragmatic: themed section headers and visual components where they
  earn it, clean readable body otherwise. Not decorated wall to wall.
- End description pages and READMEs with the footer (6f).

Return the file content only, plus a one-line note on what to fill or render next.
```

---

## 10. Open questions

1. **Legacy LockpickSettings art.** Re-skin its existing gold/serif/vignette assets
   into premium-dark + Aurum now, or let the legacy art ride until the mod's next
   release? Re-skin gives instant consistency; deferring saves a render pass.
2. **Font delivery.** JetBrains Mono + Inter as proposed, installed locally vs
   `@font-face` embedded? Confirm, or name preferred faces.
3. **Render tool.** Standardize on headless Chrome in `render.ps1`? Confirm what
   currently produces the PNGs so we match output size and DPI.
4. **Accent sourcing per game.** Choose accents freely, or sample each game's UI so
   it harmonizes? (You picked the simple one-accent engine; this is just how the
   one accent gets chosen.)
5. **Footer wording.** `[ a Tautellini mod ]` exactly, or different phrasing?
6. **Author avatar / monogram.** In or out for v1? You did not want marks on
   assets; a profile avatar is a separate, optional surface.

---

## 11. Done criteria

**v1 (the system is real and proven once):**
- `brand/` exists with `house.css`, `defs.svg`, `themes/g1r.css`, the five
  component templates, and `render.ps1`.
- One reference asset rendered end to end: a LockpickSettings hero in premium-dark
  + Aurum, validating tokens, type, brackets, glow, and the status band.
- The reusable prompt (section 9) produces an on-brand asset without hand-tuning.

**v2 (rollout):**
- Full LockpickSettings asset set re-rendered in the house style.
- GitHub README restyled with themed section headers + clean body + footer.
- Second game theme added when the second mod arrives, by section 5.
- Optional: author avatar / monogram, if section 10 item 6 lands "in".
