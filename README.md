# TautelliniMods

Personal modding suite. Source of truth for all mod development; the game
folders only ever receive deployed builds, never hand edits.

## Layout

```
TautelliniMods/
├── G1R/                       Gothic 1 Remake mods
│   ├── README.md              Game-specific modding guidance (read first!)
│   ├── LuaModdingSurface.md   What is moddable from UE4SS Lua (verified)
│   ├── reference/             Mined data: class props, lock graphs,
│   │                          blob format notes, probe session dumps
│   ├── LockpickSettings/      Lockpicking toolbox: tries boost +
│   │   ├── Scripts/           next-move solver hint (UE4SS Lua)
│   │   └── release/           Nexus kit: zips, headers, descriptions
│   └── LockProbe/             Dev-only probing harness, never deployed
│                              to players (template for engine research)
└── tools/
    ├── deploy.ps1             Copies a mod build into the live game folder
    └── extract_locks.py       Decodes all lock layouts from the game's
                               compiled AngelScript blob
```

## Workflow

1. Edit mod sources here, commit as you go
2. Deploy into the game: `powershell -File tools\deploy.ps1 -Mod LockpickSettings`
3. In a running game, CTRL+R hot-reloads deployed Lua changes
4. Never edit files under `G1R\Binaries\Win64\ue4ss\Mods\` directly

## Conventions

- One folder per mod under the game's short name (G1R, ...)
- Each mod gets a SPEC.md (what and why) before non-trivial work starts;
  once shipped, the mod README is the source of truth and the spec is
  retired (git history keeps it)
- Research findings that outlive a mod go into the per-game README
  (safety rules) and LuaModdingSurface.md (what is reachable); raw mined
  data lands in the per-game reference/ folder with its extraction tool
  under tools/
