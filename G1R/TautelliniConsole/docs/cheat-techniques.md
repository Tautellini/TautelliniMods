# Driving G1R from Lua: call the game's own functions

The reliable way to change anything in this game from UE4SS Lua is **not** to write
the underlying data, but to call the game's own `UFUNCTION` that changes it. A raw
write (`set.Health.BaseValue = x`) updates the value but skips the notifications the
HUD and game systems subscribe to, so the health bar goes stale and some systems
ignore the change. The game's own function does the write **and** fires those
notifications, so everything stays in sync.

## The one rule that makes it work

Pass only **simple arguments**: object, class, number, bool, `FName`, string. Never
pass an engine/GAS struct handle (`FGameplayAttribute`, `FGameplayEffectSpecHandle`,
`FKey`, `FHitResult`) — those do not marshal from UE4SS Lua (they fail or crash).
When an operation seems to need a struct, find the game UFUNCTION that wraps it and
takes simple args instead.

## The toolbox (all in `core/engine.lua`, the adapter)

- **`resolveClass(name)`** — find any class by short name, probing the script
  packages `/Script/Angelscript.`, `/Script/AngelscriptCode.`, `/Script/G1R.`,
  `/Script/Engine.` with `StaticFindObject` (cached; misses remembered). Direct
  paths, `_C`, `Default__`, item `It*` and `GE_*` ids are looked up as-is.
- **`libraryObject(name)`** — the **class-default-object** of a static library, via
  `StaticFindObject("<pkg>Default__<name>")`. Calling a UFUNCTION on a CDO is how you
  call a Blueprint/AngelScript function library. This is the master key.
- **GAS mixins** (call on the CDO above):
  - `Module_GAS_GASCharacterMixinsStatics:Heal(pawn, amount, instigator)` — proper
    heal; bar repaints. Huge amount caps at MaxHealth.
  - `Module_GAS_GASCharacterStateMixinsStatics` — `GetStrengthAttribute(state, def,
    pawn)` / `IncreaseStrengthAttributeBy(state, delta, pawn)` and the same pair for
    Dexterity / MaxMana; `LearnSkillForFree(state, skillClass, pawn)`;
    `RemoveItemFromInventory` / `RemoveAllItemsFromInventory`;
    `SetRelationshipTowards(...)` (relationship as an int enum). Set an absolute stat
    by reading the getter and applying `value - current` with the `Increase…By`.
- **CombatConfig flags** — `StaticFindObject("/Script/G1R.Default__CombatConfig")`
  plus any live `FindAllOf("CombatConfig")`; write the bool on all of them.
  `m_GodMode` = real invulnerability, `m_ParryCheatMode` = auto-parry. (A bare
  `FindAllOf` is empty when none is live — the CDO is what makes this work.)
- **Inventory** — `inventoryComponent:AddItemOfClass(itemClass, count)` (resolve the
  item class by its `It*` id).
- **World/NPC sweeps** — `GameplayStatics:GetAllActorsOfClass(world, class, out)` is
  inheritance-aware (unlike `FindAllOf`, which is exact-class), the basis for
  kill/teleport/relationship over all `GothicCharacter`s.
- **Player handles** — controller -> `Pawn` -> `PlayerState` (or `m_CharacterState`),
  which carries the inventory and ability system.

## What this unlocks (roadmap for TautelliniConsole)

Already proven by our probes / the dumps, in rough order of effort:

- **Fixes what we have:** god via `m_GodMode` (+ `Heal` mixin), heal/refills via the
  Heal mixin so the bar updates, stats (STR/DEX/mana/level/LP) via the state mixins.
- **New, low effort:** items (`additem`/`removeitem`), skills (`addskill`), parry
  cheat, one-hit (huge STR/DEX), weather (`controller:SetCurrentWeatherImmediate`),
  timescale (`SetGlobalTimeDilation`), freeze/skip time, clear crimes.
- **New, medium effort:** spawn NPCs/creatures (`SpawnAIAgentDefinition_*`), teleport
  to an NPC, set NPC relationship, kill-all / kill-enemies sweeps, unlock-nearby
  chests/doors, quest-state flags, the Barrier dome toggle.

Each new feature is one `Commands`-style entry calling a resolved class + a library
UFUNCTION through the engine adapter; the menu picks it up by adding a `menu()` row.

## House fit

All UFUNCTION/`StaticFindObject`/`FindAllOf` access stays in `core/engine.lua` (the
only file allowed to name engine globals); the pure cheat modules call through it.
Everything is `pcall`-guarded with a fallback, because `pcall` does not catch native
access violations — we only ever call confirmed-safe, simple-arg functions.
