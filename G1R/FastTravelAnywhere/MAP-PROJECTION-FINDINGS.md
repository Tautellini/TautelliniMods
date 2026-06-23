# Map Projection and Teleport API Findings

Investigation date: 2026-06-23. Game build: 8336_CL168089. UE4SS: 3.0.1 Beta (bundled).

This documents what we learned while exploring whether FastTravelAnywhere could drop
its baked calibration and get a clean cursor-to-world conversion straight from the game,
and whether city/area maps could be supported without a separate calibration per map.

## Verdict

There is no clean, calibration-free cursor-to-world conversion available on this build.
The world map keeps the baked affine in `Scripts/data/mapcalib.lua`. Any city map would
still need its own one-time set of sample points. The game's own map API does not remove
that need.

The reasons are three independent walls, all measured, listed below.

## The clean API we found

A grouped UFunction reference built from the live game
(`G1R/reference/Gothic 1 Remake Hook Candidate Collection/`) lists the game's own map
projection on `/Script/G1R.MapData`:

- `GetInstance` - static accessor for the singleton MapData.
- `TeleportActorToNormalized2DPosition(actor, FVector2D)` - the game's fast-travel: move an
  actor to a 0..1 position on the map, placed on valid ground.
- `GetNormalized2DPositionAndRotationFromActor(actor, outPos, outRot)` - the inverse,
  world to normalized.
- `MapMain:OpenAreaMap` / `IsAreaUnlocked` - city map open and ownership gate.

On paper this is exactly what we wanted. In practice only part of it is usable.

## What works and what does not

| Call | Result |
|---|---|
| `MapData:GetInstance` (on the CDO) | Works. Returns the live singleton. |
| `TeleportActorToNormalized2DPosition(actor, {X,Y})` | Works. Moves the player, places on ground. Input `FVector2D` as a Lua table marshals fine. |
| `GetNormalized2DPositionAndRotationFromActor(actor, ...)` | Dead from Lua. Struct out-params cannot be marshaled on this build. |

## Why the struct out-params cannot be marshaled

Calling a UFunction from Lua means UE4SS must build the native parameter block by hand:
allocate the function's param struct, copy each Lua value into the exact offset and type UE
expects, run the call, then convert results back to Lua. That layer is marshaling.

It works for simple inputs and for input structs like `FVector`, because you are handing UE
the values and it writes them into the buffer. It fails for struct out-params. This UE4SS
build cannot bind a struct at an out-param slot. `GetNormalized2DPositionAndRotationFromActor`
has one input and two struct outputs (`FVector2D` position, rotation), and the call is
rejected at the binding layer (`UFunction expected 3 parameters` whether we pass 1 or 3).

This is the same failure family as:

- `K2_SetWorldLocation` choking on its `FHitResult` out-param (the reason the mover uses
  `AngelscriptActorLibrary:AddActorWorldOffset` instead).
- Gamepad `FKey` parameters failing on `IsInputKeyDown` and friends.

It is a limitation of this UE4SS build's reflection bridge, not a Lua-side bug, and not
something we can work around from Lua. A newer UE4SS might handle it, but the shipped game
controls which build is present.

## The teleport function is global and linear

Cycle-teleporting to known normalized points and reading the resulting world position
(`gcal`, world map open) gave a perfectly linear, axis-aligned map:

```
(0.25,0.25) -> (89179,-119558)   (0.75,0.25) -> (33785,-119558)
(0.25,0.75) -> (89179,-149252)   (0.75,0.75) -> (33785,-149252)
(0.50,0.50) -> (61471,-134406)

worldX = 116876 - 110788 * normX
worldY = -104711 - 59388 * normY
```

So `worldX` depends only on `normX`, `worldY` only on `normY`. The function's 0..1 range
covers world X `[6088..116876]`, Y `[-104711..-164099]`, which is the bottom-right quarter of
the displayed world map (on the world map, `funcNorm` is roughly `2 * displayNorm - 1`). That
is why feeding the cursor's display-normalized position teleports you to the wrong place.

## There is only one MapData

Enumerating live instances with a city map open (`genum`, Old Camp open) showed:

```
FindAllOf('MapData'): 1
GetInstance         -> MapData_... [/Script/G1R.MapData]
Map_World.m_MapData -> the same MapData_...
Map_Area .m_MapData -> the same MapData_...
Map_World.m_ActiveMapData -> UIMapConfigWorldHuman  (AngelScript config)
Map_Area .m_ActiveMapData -> UIMapConfigOldCamp     (AngelScript config)
```

There is exactly one `MapData`, shared by the world map and every city map. The only
per-map object is the AngelScript `UIMapConfig*`, which does not carry the teleport function
and is on the read-only AngelScript wall. Teleporting with a city map open confirmed it: the
call ran against the single global MapData and the cursor resolved through the world formula,
not anything Old-Camp-local.

So `TeleportActorToNormalized2DPosition` is global-only. It normalizes over the whole world
no matter which sub-map is displayed. A city cursor (0..1 over Old Camp) fed to it would fling
the player across the world.

## The three walls

1. On-screen Slate geometry is unreadable here, so a screen pixel cannot be mapped to the
   map image directly.
2. The clean inverse function (`GetNormalized...`, world to normalized) is dead because the
   build cannot marshal its struct out-params.
3. The teleport function is global-only, so a sub-map cursor cannot drive it without that
   map's world rectangle, which lives in the unreadable bounding box and the read-only
   AngelScript config.

## What this means for the mod

- World map: keep the baked affine in `Scripts/data/mapcalib.lua`. It already works and the
  game API does not beat it.
- City maps: each would need its own set of sample points, baked and shipped. This is dev-side
  work per city, not per player.

## The one usable win

`TeleportActorToNormalized2DPosition` does clean, game-side ground placement for known world
coordinates. Using the global rectangle above, the inverse is:

```
normX = (116876 - worldX) / 110788
normY = (-104711 - worldY) / 59388
```

So the curated quick-travel list could teleport through the game function and let the engine
place the player on valid ground, instead of `AddActorWorldOffset` plus our own ground trace
and safe-landing search. This is a marginal upgrade, since the curated list already works with
captured Z, but it is the one genuine improvement the API offers. Not implemented.

## A path not taken: passive auto-calibration

The game already projects the player's world position onto the map every time the map is
shown and stores it as `MapWidget.m_PlayerPosMapCorrected` (the player dot), which is
readable. That is the game's own world-to-map projection, for one point (the player) at a
time. Recovering the full transform needs several points, which is what calibration is.

Those points could be gathered passively: read `(player world pos, dot)` each time the map is
opened during normal play, bucket the samples by the active map (the config name like
`UIMapConfigOldCamp` is readable), and fit the affine once enough spread accumulates. The
world map ships its baked affine for instant use; city maps would self-calibrate as the player
opens them at a few spread-out spots. This would make calibration invisible and extend to city
maps without manual work. Not built or verified. One open question: confirm
`Map_Area.m_PlayerPosMapCorrected` reads in city space when a city map is open (only the world
map dot was read during this investigation).

## Probe reference

The investigation lives in `G1R/TautelliniDevProbe/Scripts/probes/map.lua`. The relevant
actions and their default keys (bound in that mod's `config.lua`):

| Action | Key | What it does |
|---|---|---|
| `gread` | SHIFT+END | Read the MapData instance and attempt the inverse function (the marshaling test). Safe. |
| `gtele` | CONTROL+END | Teleport to the cursor via the active map's MapData. Moves the player. |
| `gcal` | ALT+END | Cycle-teleport known normalized points and log the resulting world. Moves the player. |
| `genum` | SHIFT+HOME | List live MapData instances and the open widgets' data objects. Safe. |
