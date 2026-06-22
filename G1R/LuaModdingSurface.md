# G1R Lua Modding Surface

What is theoretically moddable from UE4SS Lua, mined from the full object
dump (`UE4SS_ObjectDump.txt`, 2026-06-06, ~59 MB). Raw class-to-property
inventories live in `reference/` (greppable, one line per class).

## Ground rules (from verified research)

- Reflected property = readable AND writable from Lua. This includes the
  AngelScript classes: they dump as `ASClass /Script/Angelscript.X` and
  their properties are normal reflected properties
- AS class reads, PRECISE mechanism (re-measured 2026-06-13, dev build): get the
  default object with `StaticFindObject("/Script/Angelscript.Default__X")` (the
  by-name lookup is safe), then read its fields BY NAME (`cdo.m_Field`, names from
  the object dump). Do NOT call `cls:GetCDO()` on an `ASClass`, that is a HARD
  native crash. `ForEachProperty` enumeration is BLIND to AS data fields (returns
  0 even when the class has them), so always read by known name, never enumerate.
  Only ~971 of ~34800 AS classes carry reflected data fields; most (incl. the whole
  `Bow_*` chain) carry none, so their config lives in non-`UPROPERTY` AS members
  (VM-only, needs offline decode / C++) or in a different class. Chest classes
  remain the exception below (StaticFindObject on THEM crashes; use NotifyOnNewObject
  + write the instance). Shipping caveat: AS-config reads are dev-confirmed only,
  the original blanket ban was a shipping decision after the 3.0.x live-decode
  crashed for too many players, so use this for DEV-SIDE extraction (read live, bake
  to data) until proven safe across player environments.
- Native UFunctions are callable from Lua but NOT interceptable:
  RegisterHook on G1R/AS-bound natives registers without error and never
  fires, because AngelScript calls them directly via its binding table,
  bypassing UFunction dispatch (engine natives like
  PlayerController:ClientRestart hook fine)
- Do NOT enumerate a live class's UFunctions. `UClass:ForEachFunction` (and
  walking the chain via `GetSuperStruct` to do so) NATIVE-CRASHES on a live
  `/Script/G1R` instance (measured 2026-06-19 on AbilityTask_LockPick: AV inside
  the iteration, pcall/try cannot catch it). Calling a known UFunction BY NAME is
  fine (that is how UpPressed / TryOpenLock are invoked); only the ENUMERATION is
  banned. Get function names OFFLINE from `UE4SS_ObjectDump.txt` (914 of 1680 G1R
  classes carry native functions), never by live ForEachFunction.
- Safe event sources: `NotifyOnNewObject` (works on AS classes too),
  `RegisterInitGameStatePostHook`, keybinds, polling (sparingly)
- Hot reload (CTRL+R) RE-REGISTERS keybinds/notifications without
  removing the old ones: handlers fire once per reload performed.
  Debounce handlers defensively, and prefer a full game restart after
  deploying mods that register keybinds or hooks
- All UE4SS Lua mods share ONE Lua state: another mod can clobber
  standard globals at any time (seen in the wild: ipairs replaced by a
  table mid-session, crashing our loops). Capture every standard
  library reference as a local at load time
- UE4SS TMap access returns a copy; TArray and structs work normally
- Two write targets: live instances (`FindAllOf`) and class defaults
  (`Default__X` objects, affect everything spawned afterwards)

## Scale

- 1680 native `/Script/G1R` classes (1601 with reflected properties,
  914 with native functions)
- ~34800 AngelScript classes, 971 with reflected properties
- ~1500 GameplayEffect / GameplayAbility blueprint assets

## 1. Stats: the GAS attribute sets (per character, live-writable)

| Set | Attributes |
|---|---|
| Health | Health, MaxHealth, DamageMultiplier, RecoveryRatePerHourOfSleep |
| Mana | Mana, MaxMana, MagicianLevel, RecoveryRatePerHourOfSleep |
| Strength | Strength, Critical_Fists, Critical_OneHand, Critical_TwoHand, Critical_Orc |
| Dexterity | Dexterity |
| LevelProgression | Level, Experience, SkillPoints, XPExecutedBounty, XPKillOrDefeatBounty, Toughness, ToughnessA/B/C |
| Armor | SuperArmor, MaxSuperArmor, Resistance_Blunt/Edge/Point/Fire/Energy/Ice/Wind/Falling |
| Movement | SpeedModifier |
| Lockpicking | LockpickDurability, LockpickPrecision |
| Pickpocketing | PickPocketing |
| Oxygen | Oxygen, MaxOxygen, OxygenDepletionRate, OxygenRecoveryRate, CriticalLevelPercent |
| Alcohol | Alcohol, MaxAlcohol, AlcoholDepletionRate |
| Swampweed | Swampweed, MaxSwampweed, SwampweedDepletionRate |
| Fatigue | Fatigue, MaxFatigue, FillRatio, FillRatioPeriod, RecoveryRatePerHourOfSleep |
| Sleep | SleepTime, MaxSleepTime, SleepTimeRecoveryAmount/Period, MaxRestTime |

## 2. Skills, talents, guilds, spells (blueprint GE/GA assets)

- `GE_Skill_*` (79): Picklock, Pickpocket, Melee (Fists/1H/2H/Orc) and
  Ranged (Bow/Crossbow) per tier, Mage_Circle_1..6, Crafting (Alchemy,
  Blacksmith, Inscription), Hunting trophy skills, Acrobatics, Sneak,
  Diving, Mining, Orcish, Riding, Wallclimbing, Scavenging,
  BuyAttribute_(Strength/Dexterity/MaxMana)_(1/5)
- `GE_Guild_*` (76), `GE_Damage_*` (27), `GE_EquipAbilitiesWhen*` (97)
- `GA_Spell_*` (86) and `GA_CastSpell_*` (104): every spell incl.
  GA_FreezeTime, GA_Spell_Telekinesis, transforms, summons
- Theoretically tunable via their class default objects; also usable as
  tier detection (which GE is active on the ASC)

## 3. Locks, chests, interactive objects

Verified in-game 2026-06-06 (LockProbe sessions, see
`reference/lockprobe-session.txt` + `reference/lock-tiers.txt`):

- Every lock is its own AS class (416 in MainMap), all pre-instanced by
  name at world load: `LockPickSubsystem.m_InstancedLocks` (name ->
  GothicLockConfig instance), mirrored in `G1RGameState.m_LockMapClasses`
- Lock SELECTION is by FName and is the moddable seam: the player's
  `GameplayAbilityOpen`/`GameplayAbilityDoor` instance (under
  G1RPlayerState, e.g. GA_Human_OpenContainer) gets `m_Lock` set at
  interaction start; the minigame scene is built from it AFTER
  `AbilityTask_LockPick` spawns. Rewriting `m_Lock` in a
  NotifyOnNewObject callback on the task redirects the minigame, and the
  unlock is still credited to the right object (verified end to end)
- Generic layouts `Test_Lock_Difficulty_<1..7>_<01..10>` ship in the
  game: ideal substitution targets per tier
- `RandomLockSubsystem` (AS): bRandomLocksEnabled is false everywhere
  (system dormant), but m_LockPoolEntries maps all 307 chest locks to
  tiers 1..7: our tier table. Door locks are absent from the pool
- `InteractiveObjectDefinition` (native, 31 props): m_Lock (FName),
  m_Keys, m_PuzzleKeys, m_ConsumeKeys. Carries locks for DOORS only
  (61 in Old Camp session); chest locks ride only on the ability
- `IoChestDefault` (AS): m_LockDifficulty, m_bNoRandomLock,
  m_OriginalLock. Per-chest values sit on per-chest AS CLASSES
  (`m_RegisteredChests` holds classes like IO_OC_CHEST_DIGGER502, one per
  placed chest); FindAllOf("IoChestDefault") finds no instances
- CRASH WARNING: reading instance properties off those class objects
  returns reflection garbage and access-violates; `GetCDO()` /
  `StaticFindObject` on them crash natively too (pcall cannot catch
  native AVs). Do not touch chest classes from Lua
- `AbilityTask_LockPick`: minigame lifecycle delegates (our mods' trigger)
- Lock internals (GothicLockConfig piece/connection data): NOT reflected,
  Lua can only call AddPiece/AddConnection, not read or hook them.
  Live `GothicLockPieceActor` instances expose m_PieceId/m_LockPieceType
  during the minigame (3 actors per piece: plate/bar/latch)
- Piece visuals are tintable: each piece's m_MaterialInstanceDynamic
  accepts SetVectorParameterValue("HighlightColor", {R=,G=,B=,A=})
  (verified; Lua tables pass as structs). Only 1 of the 3 actors per
  piece carries a MID. The game's hover highlight writes the same
  parameter, so persistent tints must be re-applied per tick
- `LockpickPrecision` (AttributeSet_Lockpicking) = connections removed
  per broken pick (the master perk's mechanic; baseline 1.0 at Trained).
  Writable, but boosting it trivializes the master skill
- Per-piece m_CanEverBeHighlighted/m_CanEverShake are permission flags
  only; the native hover logic decides what gets highlighted, so
  flipping them has no visible effect
- Piece MOVEMENT lives on m_RuntimeRootComponent.RelativeLocation
  (~6.3 units per step); the piece ACTOR's root transform never changes.
  Only the type-1 actor of each piece moves on a section move
- The scene/pick actors are BP subclasses (BP_LockPick_C): FindAllOf
  by native class name finds nothing; resolve them via
  LockPickSubsystem.m_LockSceneActor / .m_LockPickActor instead
- AbilityTask_LockPick input natives (UpPressed/DownPressed/
  LeftPressed/RightPressed/ResetPressed) are callable and cost no
  durability; BackPressed CANCELS the minigame. Programmatic presses
  moved pieces in one session and did nothing in another: input-state
  dependent, unresolved. Continuous FindAllOf polling (5x/sec) causes
  periodic hitches: cache references, poll lean, only while needed
- The same input natives ARE hookable and FIRE: they are dispatched by
  the engine input layer (keyboard AND controller), not by AS-internal
  calls. This is the verified seam for reacting to minigame input
  (LockpickSettings' selection tracker uses it). Up/Down = move
  selection between rows, Left/Right = move the selected piece
- Minigame mechanics: pieces are horizontal sliders stacked in rows
  (MPC_Lockpicking Slot_0..6 = live per-piece world positions, ~6.3
  units per step, 10 units row spacing; slot index = piece id). The
  selection indicator itself is rendered GPU-side: no reflected
  property anywhere holds the selected row (exhaustively searched)
- Minigame mechanics (hard-won; each item below replaced a plausible
  but WRONG model, see the graveyard): rails span 7 positions
  (rotations -3..+3), the OPEN position is ALWAYS the center (rot 0)
  for EVERY lock, and the lock opens BY ITSELF the instant the last
  correct move lands (player-canon 2026-06-07; a full day was lost to
  drifting measurements that made pins-at-center look like a non-win,
  never relitigate the goal on measurement evidence alone). Controls
  are INVERTED: pressing LEFT moves a pin RIGHT. Pieces NEVER freeze,
  not even at the center. Moves are ATOMIC: the mover and every
  dragged partner must stay within the rail or the game rejects the
  whole move (visible as a shake); this is the only blocking mechanism
  and the sole reason a piece can appear "unmovable". A REFUSED move
  counts as a FAIL and costs pick durability. Drags are direct-only
  (no cascading) and directed per the mined dir (+1 same direction,
  -1 opposite)
- STARTING POSITIONS: not reliably re-scrambled per attempt after all.
  At least one chest (OC_Chest_Mordrag) starts at the AUTHORED layout
  on every fresh entry (verified repeatedly 2026-06-07); a mid-session
  pick BREAK does randomize. Still never trust mined rots blindly for
  live state, measure them. NOTE the scene actor is an AInfo with NO
  transform (the "scene location is the rail center" formula here was
  never actually verified and cannot work); the live read that works
  is the MPC slot positions plus the fixed bar/latch part columns.
  Mined data is name-stable for the connection graph and piece count
- RANDOM LOCKS PER SAVE-STATE (verified 2026-06-07): the SAME physical
  chest carries DIFFERENT lock configs across save reloads
  (RandomLockSubsystem tier pools; observed live as three lock names
  learned at one world position). A reload can therefore change a
  chest's name, graph, piece count and layout. Identify the active
  lock through the CURRENT AbilityTask_LockPick's owning Ability
  (m_Lock), never by scanning ability instances (they linger and get
  reused); key any per-lock persistence by name PLUS world location
- The current minigame's verdicts are observable via UFunction hooks:
  GameplayAbilityDoor/Open Server_SuccessLockEvent and
  NetMulticast_OnSetLockUnlocked fire on success (proven in-game),
  Server_FailedLockEvent on a pick break. Opened locks' actors LINGER
  for minutes (the die-within-a-tick rule holds only for aborted
  minigames), so sessions must close themselves on the success signal
- The slot cloud ALONE fixes rotations only RELATIVE to each other:
  the absolute center is ambiguous unless the scramble spans the full
  rail, and a most-centered fit guesses wrong on roughly 4 of 10
  non-spanning attempts (simulated over the mined graphs,
  tools/sim_anchor.py; the "all pins end one beside the center"
  community reports). The scene location anchors it absolutely where
  readable (K2_GetActorLocation is a UFunction CALL and does not hit
  the degrading struct-FIELD reads; validate the projection against
  the fitted grid before trusting it). Any guessed anchor must be
  treated as a hypothesis and corrected from evidence: rail bounds,
  refused model-valid moves, planning dead ends, an unopened believed
  goal (LockpickSettings 2.6 does all four)
- The game removes roughly LockpickPrecision connections per lock at
  runtime, so mined graphs are upper bounds. Learn dead edges from
  observed moved-sets: exact covers confirm a mover's edges as active,
  and a contradiction-free unique superset candidate prunes its
  missing edges
- Bars visually track each piece's rotation continuously
  (m_RotationToBarOffset); they are NOT lock-in latches and carry no
  state worth reading. The slot grid is slightly nonuniform (~6.1-6.3
  units per step): measure state as ABSOLUTE displacement from a
  reference position, never by accumulating per-event deltas
- Model graveyard (tried, disproved in-game, do not revisit):
  lock-in freeze at the center; partners clamping independently while
  the mover proceeds; bar transitions as an openness signal (false
  positives poisoned the step calibration); m_RotationToBarOffset as
  the goal-rotation source (gave -1, truth is 0); camera-projection
  row ordering (scrambled; the visual row IS the piece id);
  input-event mirroring for selection tracking (drifts, fails on
  controller); mined rots as the live start state (re-scrambled per
  attempt)

## 4. Crime, theft, reputation (AS tuning configs)

- `CrimeSystemConfig`: ContainerTheftLootValueCapByGuild/Fallback
- `CrimeTuningConfig_Theft`: value clamps, warning compliance seconds,
  bribe multipliers, flee/LoS thresholds, MaxWrongDropsBeforeCombat
- `CrimeTuningConfig_Pickpocket`: NumWarningsBeforeCombat,
  MaxFailedAttemptsBeforeCombat, FailCountDecayWindowSeconds, distances
- `CrimeTuningConfig_Creeping`, CrimeAgeDecayParams, crime memory filters
- `CrimeEntry` (live records): bIsForgiven, bIsSuppressed, BaseSeverity,
  CrimeType, witness/guild data. `CrimeProcessingSubsystem` (17 props)

## 5. Economy and items

- `ItemDefinition` defaults (28 props): m_Value, m_Weight, m_MaxStack,
  m_OnConsumeEffects, m_OnEquipEffect, m_RequiredStats, m_Ownership,
  m_LearnRecipes, m_ReplaceBy
- `WorldDefinition` (48): trader types/regions, regional and liquidity
  price multiplier ranges, spawn/unspawn distances, m_SpawnAllAiFromStart
- `ArmorDefinition` (39): per-slot upgrade tiers

## 6. Combat tuning

- Native `CombatConfig` (22): m_GodMode, m_ParryCheatMode, m_ParryMode,
  m_Pity_Critical_Increase, root motion modifiers, m_AdditiveHits
- AS `CombatConfig` (41): AI cooldown multipliers per skill tier
  (CooldownMultiplier_Untrained/Trained/Master), taunt tuning,
  PreferredDistance, FriendlyFireSafetyDistance, bUseWeaponSkillLevels
- AttackInfo, SuperArmor params (CharacterDefinition), AI target scoring
  (AICombatTargetScoringEntry*), GothicBloodComponent (33)

## 7. Movement and traversal

- `GothicMovementComponent` (28): water friction, step smoothing, speed
  curve plumbing, m_ClimbingConfig / m_JumpConfig / m_SwimConfig refs
- `GroundConfig` (23), `DataModule_Locomotion` (31), TurnOnSpotConfig
- Plus AttributeSet_Movement.SpeedModifier for the blunt instrument

## 8. Quests and story state

- `Quest` objects (28 props): State, bIsOptional, InChapter, QuestKind,
  involved characters, external triggers
- `StoryG1R` (AS, 464 props): the global story blackboard. Timers and
  flags like Diego_Welcome, Bloodwyn_PayDay, Lukor_Open_Door,
  Convoy_RaidStartTime, chapter cinematics state. Read/write
- Questlog widgets, QuestlogDocumentClass

## 9. World, time, weather, AI

- `ModifiedWeather` (AS): Probability, Mod, TotalProbability, WeatherType;
  WeatherListContainer
- `BarrierManager` (35 props), RegionTrait_* (damage zones, sleep areas)
- `AIState_*` family (DailyRoutine 33 props, Warning_Crime, TheftPursuit,
  Fear, PerceptionResponse, Teleport, OpenDoorOrGate ...)
- `PerceptionHandler` (73), PerceptionSightSettings (28): sight/hearing
- `CharacterDefinition` (33): m_InitialAttributes, m_Skills, m_Mood,
  m_Personality, m_PerceptionSettings, m_InventoryPreset

## 10. Meta: saves, settings, UI

- `PersistentDataSubsystem` (27): m_IsPermaDeath, bAllowSaveLoad,
  m_IsAutosaveAllowedInCurrentMap, autosave timer, save screenshots
- `GothicGameUserSettings` (71), `GothicAudioSettings` (40),
  CameraDefinition (30), photo mode config
- Full UMG widget tree: PlayerWidget (30), MapWidget (21), InventoryMain
  (33), StatEntryWidget (29), tooltips. All reachable and writable

## Practical patterns

- Tune-on-load: write class defaults (Default__X) once at mod load
- Tune-on-spawn: NotifyOnNewObject on the class, write the instance
  (works for AS classes, e.g. /Script/Angelscript.IoChestDefault)
- Stat mods: FindAllOf the AttributeSet, write BaseValue/CurrentValue
  (idempotently, see LockpickSettings)
- Console commands: RegisterConsoleCommandHandler for cheat-style tools
- Off limits: hooking G1R/AS natives, unreflected data (lock connections),
  TMap mutation, anything needing the disabled ProcessEvent-family hooks
