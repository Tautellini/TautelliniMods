# FastTravelAnywhere - Immersive Mode (spec)

Target: `G1R/FastTravelAnywhere`, next minor over 0.2.0. Status: spec, not built.
Date: 2026-06-26.

## Goal

Add an opt-in **Immersive Mode** that turns free fast travel into a paid one. In the user's
words: "show near the cursor when a map is open, how much distance that teleport travel is",
"bound it to costs of ore (the money in the game)", and "if he doesn't have enough ore, he
cannot fast travel and the distance would be shown red or something". On top of that,
optionally "estimate the travel time and advance the time", and "the ratio of the calculation
for the cost should also be adjustable".

## Decisions locked (from the grilling)

| Question | Decision |
|---|---|
| Default posture | **Opt-in, off by default.** Free teleport stays the default. |
| Cost scope | **Both** the on-map teleport and the Quick Travel buttons cost ore. |
| Readout placement | **Cursor-anchored only.** If a cursor-following label proves infeasible, drop the on-map readout rather than use a fixed corner. |
| Confirm flow | **Single press.** The readout is the preview; one press spends and teleports. |
| Cost curve | **Linear, clamped:** `cost = clamp(round(ratio * distance), minCost, maxCost)`. |
| Readout text | **Distance and ore cost,** e.g. `450 m / 68 ore`, red when unaffordable. |
| Travel time | **From distance, like a walk:** `time = distance * timeRatio`. Its own toggle, fires only on a paid teleport. |
| Too poor | **Red readout, press does nothing.** Silent block, no spend, no teleport. |

## Scope

**In (v1):**
- World map only (the on-map teleport already supports only the world map).
- Cursor-anchored live readout: distance plus ore cost, white when affordable, red when not.
- Ore cost on both the on-map teleport and the Quick Travel buttons.
- Affordability gate: too poor means the press is a no-op.
- Optional time advance scaled by distance, as a separate toggle.
- Adjustable cost ratio (config plus an in-menu slider), plus min and max cost in config.

**Out (v1, candidates for later):**
- City and area maps (not wired up in the mod at all yet).
- Controller-driven map cursor (the readout uses the mouse cursor, same limit as today).
- A red-colored Quick Travel button in the menu (the menu bridge sends static label strings;
  see Quick Travel below for the v1 behavior).
- Sound on a blocked press (no verified sound hook).

## User-facing behavior

1. **Enabling.** Immersive Mode is a menu toggle under FastTravelAnywhere, default off. With it
   off, the mod behaves exactly as 0.2.0 (free teleport).
2. **On-map readout.** With the world map open and Immersive Mode on, a small label follows the
   cursor showing the straight-line distance from where you stand to the cursor and the ore it
   would cost, for example `450 m / 68 ore`. The label is white when you can afford it and red
   when you cannot.
3. **Affordable press.** One press of the hotkey deducts the ore, advances time if that toggle
   is on, and teleports (with the existing safe-landing pipeline). No confirm step.
4. **Unaffordable press.** The label is already red. The press does nothing: no teleport, no
   spend, no message.
5. **Quick Travel.** Each curated button shows its current ore cost in the label, for example
   `New Camp (120 ore)`, computed from your position. Pressing it pays and travels if you can
   afford it; if not, the press is a no-op and logs one short line (`New Camp: not enough ore,
   need 120 have 30`). The cost in the label is refreshed on mod load and whenever the world map
   opens or closes (a cheap proxy for "recent"); the press itself always re-checks live.
6. **Time advance.** When on, a paid teleport jumps the game clock forward by an estimate of how
   long that walk would have taken. NPCs do not snap to their new routine, they drift into it
   (a known limitation of the clock set, acceptable here).

## Architecture

Everything stays inside FastTravelAnywhere; its Lua state is isolated, so the TautelliniConsole
code below is the **proven reference to port from**, not a dependency to call.

### Cost and distance (pure)
- New pure module `travel/cost.lua` (loads under bare Lua 5.4, no engine), unit-tested like
  `travel/pipeline.lua`:
  - `cost(distanceUnits, cfg) -> oreCost` implementing `clamp(round(ratio * distance), min, max)`.
  - `format(distanceUnits) -> "450 m"` / `"1.2 km"` (1 uu = 1 cm; meters with km rollover).
  - `travelMinutes(distanceUnits, timeRatio) -> gameMinutes`.
- Distance is straight-line 2D between the player root position and the target world XY (Z is
  ignored; it is noisy and the player pos is read via the root component already).

### Ore read and deduct (engine adapter, ported)
Port these proven seams from `TautelliniConsole/Scripts/core/engine.lua` into FTA's
`core/engine_travel.lua` (or a sibling `core/engine_economy.lua`):
- **Find inventory:** `engine.findInventory(pawn, state)` via `state.InventoryComponent` or
  `owner:GetComponentByClass(InventoryComponent)`.
- **Deduct:** `Module_GAS_GASCharacterStateMixinsStatics:RemoveItemFromInventory(state, cls,
  count, pawn)`. The currency item class is an `It*` name; the console example uses `ItMi_Gold`.
  The trader payload (`GothicTraderPayload.m_Player_Ore`, `m_TotalOreCostPlayer`) confirms ore is
  the currency, but the exact item class id must be confirmed (probe 1).
- **Read current count:** NOT yet proven anywhere in the repo. This is the gate-critical unknown
  (probe 1). We can add ore, deduct ore, and reach the inventory component, but reading how much
  the player holds is unverified. TMap iteration over the inventory is banned, so the read must
  go through a count accessor on the inventory component (something like a get-count-of-class
  function) or another reflected source.

### Time advance (engine adapter, ported)
- Port `engine.skipTime(seconds)` = `GameTimeSubsystem:SkipTime({ TotalSeconds = n })`, plus
  `readClock` for any clock display. Proven by the console `time`/`skiptime` commands.

### Readout rendering (new, UMG)
- Reuse the `render.lua` recipe: build one UMG `UserWidget` with a `CanvasPanel` and one
  `TextBlock`, text via `KismetTextLibrary:Conv_StringToText`, color via `SetColorAndOpacity`
  (white `FLinearColor` or red), positioned with `slot:SetPosition({X, Y})`, shown with
  `AddToViewport(Z)` at a high Z so it draws over the map.
- The widget is built once and reused; only its position, text, and color change.

### The driver (new, the main addition)
- FTA has no continuous loop today, by design (avoids the #1180 deferred-queue crash). The live
  cursor-following readout needs one. Add a **single persistent game-thread driver**, the proven
  pattern from LockpickSettings 3.1.5 (`[[lockpick-single-driver-315]]`) and the kit async helper
  (`[[ue4ss-delayed-action-system]]`): registered once behind a global flag, runs on the game
  thread, does cheap work, and only while `openWorldMap()` is non-nil.
  - Each tick (target ~10 to 15 Hz): read cursor, compute map then world XY (existing pipeline),
    compute distance and cost, set the label text, color, and position. Skip entirely when the
    map is closed; hide or remove the label on the open-to-closed transition, and on that
    transition refresh the Quick Travel cost labels.
  - The ore count is cached and re-read at a slower cadence (for example every 500 ms, and on map
    open) so the per-tick work stays light.
- The teleport itself still goes through the existing `run()` gate (single in-flight plus
  `teleportCooldown`), so the new driver never dispatches a teleport; it only drives the label.
  The hotkey path stays as today, with the affordability check and the deduct added before the
  move.

### Data flow (on-map press)
cursor -> `pipeline.cursorToMap` -> `pipeline.mapToWorld` -> target XY; `engine.playerPos` ->
current XY; `cost.cost(distance, cfg)`; read ore count; if count >= cost then deduct, optional
`skipTime`, then `engine.teleport` (unchanged safe-landing); else no-op.

## Configuration

`Scripts/config.lua`, following the existing pattern (bool toggles also in the menu, numeric
tuning mostly config-only):

| Key | Default | Menu? | Meaning |
|---|---|---|---|
| `immersiveMode` | `false` | bool | Master toggle for the whole feature. |
| `oreCostPer100m` | `15` | num slider | The adjustable ratio: ore per 100 m of straight-line distance. |
| `oreCostMin` | `5` | config only | Floor, so short hops are not near-free. |
| `oreCostMax` | `250` | config only | Cap, so cross-map jumps stay payable. |
| `currencyItem` | `"ItMi_Gold"` | config only | The ore item class id (confirm in probe 1). |
| `advanceTime` | `true` | bool | Advance the clock on a paid teleport. Only matters when `immersiveMode` is on. |
| `timeMinutesPer100m` | `20` | config only | In-game minutes added per 100 m of distance. |

Existing keys (`onMapTeleport`, `safeLanding`, `expandSearch`, `cancelIfUnsafe`,
`maxSearchRange`, `minFlatness`, `maxElevationDelta`, `teleportCooldown`, `hotkey`, `debug`,
`captureCoords`) stay unchanged. Saved-settings persistence extends to `immersiveMode` and
`advanceTime`.

Default tuning is a starting point and must be play-tuned. Rough anchors: the map is about
1.2 km corner to corner, so a cross-map jump at the defaults costs about `min(250, 15 * 12) =
180` ore and advances about `12 * 20 = 240` in-game minutes (4 hours).

## Performance notes

- The driver runs only while the world map is open, which is a small fraction of play. Per tick
  it does one cursor read, a few pure math calls, one cached count compare, and a couple of
  widget setters. Cheap.
- The ore count read is the only potentially heavier engine call; it is cached and refreshed at
  ~500 ms, not per tick.
- No teleport ever dispatches from the driver. The single-in-flight `run()` gate and
  `teleportCooldown` are unchanged, so the #1180 mitigation holds.

## Technical risks and probes (do these first, in TautelliniDevProbe)

1. **Read the player's ore count (gate-critical) and confirm the currency class.** Without a safe
   count read, the affordability gate and the red state cannot be precise. Probe: find the
   inventory component (proven), then find a count accessor for an item class that does not
   iterate the TMap. Resolve the exact ore item id at the same time (read it back after a known
   `additem`, or from the object dump). Two-strike rule before trusting any read.
2. **Cursor-anchored readout over the open map.** Confirm a UMG label drawn with `AddToViewport`
   at a high Z renders on top of the world map UI, and that a ~10 to 15 Hz game-thread driver
   updating its position and text is smooth and crash-free across CTRL+R. The drawing seam is
   proven (SharedModMenu); the open items are Z-order over the map and the map-open-gated poll.

## Open questions

- **Ore-count fallback.** If probe 1 finds no safe count read, what should Immersive Mode do?
  Candidate: refuse to enable with a one-line log, rather than deduct blindly. To decide after
  the probe.
- **Quick Travel live cost.** v1 refreshes the button cost on mod load and on map open/close, and
  re-checks on press. A truly live per-frame menu cost (and a red unaffordable button) needs more
  from the menu bridge and is a v2 item.
- **Default tuning** of `oreCostPer100m`, the min/max, and `timeMinutesPer100m`. Numbers above
  are guesses; confirm in play.
- **Distance unit display.** Meters with km rollover is assumed. Switch to a flat unit if it
  reads better in-game.

## Done criteria

**v1 is done when:**
- Immersive Mode is an opt-in toggle, off by default, with 0.2.0 behavior unchanged when off.
- With it on and the world map open, a cursor-following label shows `distance / ore cost`, white
  when affordable and red when not.
- A single affordable press deducts the correct ore, optionally advances the clock, and
  teleports through the existing safe-landing path.
- An unaffordable press does nothing.
- Quick Travel buttons show and charge the ore cost, and no-op when too poor.
- The cost ratio is adjustable in config and via the menu slider; min, max, and the time ratio
  are adjustable in config.
- `travel/cost.lua` is pure and unit-tested; the run/cooldown gate and #1180 mitigation are
  intact.

**v2 candidates:** city and area maps, live per-frame menu cost with a red unaffordable button,
controller cursor, a blocked-press sound.
