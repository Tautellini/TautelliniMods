# PrecompiledScript_Shipping.Cache — format notes (lock-graph extraction)

Target file (read-only, never modified):
`C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache`
(122,528,538 bytes). Gothic 1 Remake, UE 5.4.3, Hazelight-style AngelScript plugin.

Goal achieved: extracted the `AddPiece` / `AddConnection` lock layout for every
`GothicLockConfig` subclass. Extractor: `tools/extract_locks.py`. Output:
`G1R/reference/lock-graphs.lua`. Date: 2026-06-06.

---

## 1. High-level file layout

The cache is a custom serialization of the *loaded* AngelScript module: it
embeds absolute 64-bit runtime pointers (it is a position-dependent dump, not
the portable `SaveByteCode` format). Rough section map (per 4 MB block, by
zero/ASCII density):

| Range (bytes)        | Content                                                            |
|----------------------|--------------------------------------------------------------------|
| 0 – 16               | 16-byte magic header                                               |
| 16 – ~37.7 M         | Type-system / class-descriptor table (reflected UE + script types) |
| **37.7 M – ~42 M**   | **Script class descriptors WITH bytecode** (lock configs live here)|
| ~42 M – ~84 M        | More descriptors, default property blobs                           |
| ~84 M – ~121 M       | String / name tables, import tables, asset-path metadata           |
| ~100.83 M            | Registered-native function descriptor table (incl. AddPiece/AddConn)|
| ~121 M – EOF         | String maps (e.g. `IO_BC_CHEST_01` -> `BC_Chest_01_Lock`), debug   |

Strings are length-prefixed: 4-byte little-endian length, ASCII bytes, then a
`0x00` terminator. Example at 37,865,895: `19 00 00 00` + `"Test_Lock_Difficulty_1_01"`.

---

## 2. Lock-config class descriptors

Each `GothicLockConfig` subclass appears as a descriptor in the 37.7–42 M region
with this rough shape:

```
<len><ClassName>\0           # e.g. "Test_Lock_Difficulty_1_01" or, for named
                             #   chest/door locks, the UE C++ name "UBC_Chest_01_Lock"
<padding / flags>
<len=14>"__InitDefaults"\0   # the function whose bytecode builds the lock
<padding>
0x52 00 00 00                # record tag preceding the function body
<header (24+ bytes)>
<lenword>                    # uint32: bytecode length in 32-bit DWORDs
<bytecode stream ...>        # ends with RET (opcode 0x0A)
... then references to "UGothicLockConfig" + "/Script/G1R.GothicLockConfig"
... and "__StaticType_<ClassName>" (Test locks only)
```

Counting anchors:
- `UGothicLockConfig` (length-prefixed) occurs **417** times = 416 lock classes
  + the base class.
- `__InitDefaults` markers are abundant (every reflected class has one); a lock
  descriptor is identified by an `__InitDefaults` marker whose **immediately
  preceding length-prefixed identifier** is the class name AND which has
  `UGothicLockConfig` within the next ~2.6 KB.
- Named chest/door locks (`BC_Chest_01_Lock`, …) store their class-name string
  with the UE `U` prefix (`UBC_Chest_01_Lock`); the extractor strips it. The
  `Test_Lock_Difficulty_*` classes store the plain name.

The bytecode stream is **NOT consistently 4-byte aligned to the file** (e.g.
`Test_Lock_Difficulty_1_01`'s length word is at file offset 37,921,600 (%4==0),
`1_02`'s at 37,923,151 (%4==3)). Therefore the extractor locates calls by
byte-pattern within each class window rather than assuming alignment.

---

## 3. Bytecode encoding (loaded AngelScript form)

Instructions are 32-bit words; the **opcode is the low byte** of the first word.
Multi-word instructions follow. Opcode numbering matches stock AngelScript
`asEBCInstr`. Only a few opcodes matter for lock building:

| Opcode | Hex  | Name      | Encoding                                  |
|-------:|------|-----------|-------------------------------------------|
| 2      | 0x02 | PshC4     | `02 00 00 00` + int32 constant (8 bytes)  |
| 48     | 0x30 | PshVPtr   | `30 00 00 00` (push object `this`, 4 B)   |
| 61     | 0x3D | CALLSYS   | `3D 00 00 00` + **int64 fn pointer** (12 B)|
| 62     | 0x3E | CALLBND   | (same shape as CALLSYS)                   |
| 10     | 0x0A | RET       | terminates the function                   |

Key difference from portable bytecode: `CALLSYS` carries the **absolute 64-bit
`asCScriptFunction*`** of the native function, not a portable index. The two
relevant pointers (constant across the shipping build):

```
AddPiece        ptr = 0x000001E96D2D2FC0   bytes: C0 2F 2D 6D E9 01 00 00
AddConnection   ptr = 0x000001E96D2D3180   bytes: 80 31 2D 6D E9 01 00 00
```

These are confirmed by the native-function descriptor table at ~100.83 M and by
the signature strings in `Binds.Cache`:
- `void AddPiece(int id, int rotation)`            (`Binds.Cache` @ 5,033,619)
- `void AddConnection(const int id, const int connectedId, const int direction)` (@ 5,033,492)

### Calling convention

AngelScript pushes arguments **right-to-left**, then pushes `this` (PshVPtr),
then CALLSYS. So the **last `PshC4` before the call is the first parameter**:

```
... PshC4(rotation) PshC4(id) PshVPtr CALLSYS->AddPiece
        => AddPiece(id, rotation)

... PshC4(direction) PshC4(connectedId) PshC4(id) PshVPtr CALLSYS->AddConnection
        => AddConnection(id, connectedId, direction)
```

Worked example — `Test_Lock_Difficulty_1_01` `__InitDefaults` (file 37,921,604+):

```
PshC4 10575            ; SetUniqueName arg (FName id)
CALLSYS 0x..68300080   ; base setup (SetUniqueName / ctor)
PshRPtr / PshVPtr ...
CALLSYS 0x..68301580   ; another base call
PshC4 -2  PshC4 0  PshVPtr  CALLSYS->AddPiece   => AddPiece(0, -2)
PshC4  2  PshC4 1  PshVPtr  CALLSYS->AddPiece   => AddPiece(1,  2)
PshC4 -1  PshC4 2  PshVPtr  CALLSYS->AddPiece   => AddPiece(2, -1)
PshC4  2  PshC4 3  PshVPtr  CALLSYS->AddPiece   => AddPiece(3,  2)
PshC4 -1  PshC4 3  PshC4 0  PshVPtr  CALLSYS->AddConnection => AddConnection(0, 3, -1)
RET
```

---

## 4. Field semantics (empirical, across all 416 locks)

- `id` (AddPiece): per-lock piece index. Always the **contiguous set 0..N-1**
  in call order (verified for every lock). N pieces per lock ranges ~4–7.
- `rotation` (AddPiece): observed values **-3..+3** (7 discrete steps). Matches
  the rotational positions of the lock pieces in the minigame.
- `id`, `connectedId` (AddConnection): both reference existing piece ids
  (verified: no connection references a missing piece in any lock).
- `direction` (AddConnection): strictly **±1** (counts: -1 ×1759, +1 ×1507).
  Reads as the turn direction the connected piece follows, not a sentinel.

Tier trend (`Test_Lock_Difficulty_<tier>_<nn>`, 10 each) — connections grow
monotonically with tier as expected:

| tier | avg pieces | avg connections |
|-----:|-----------:|----------------:|
| 1    | 4.30       | 4.80            |
| 2    | 5.50       | 3.00            |
| 3    | 5.40       | 4.80            |
| 4    | 5.50       | 6.70            |
| 5    | 5.80       | 8.50            |
| 6    | 5.70       | 9.10            |
| 7    | 5.20       | 9.70            |

(Connections are the difficulty driver; piece count saturates around 5–6.)

---

## 5. Validation performed

1. **Internal consistency** (in `extract_locks.py`): every lock's piece ids form
   the contiguous set `0..N-1`, no duplicate ids, and every connection endpoint
   references an existing piece. Result: **0 problems across 416 locks.**
2. **Independent decode cross-check**: a second, separate decoder that walks the
   bytecode strictly opcode-by-opcode using the function length word and requires
   the stream to terminate exactly on a `RET` reproduced the byte-pattern result
   for **all 416 locks with 0 mismatches**.
3. **Lua round-trip**: `lock-graphs.lua` loads as a real Lua chunk (lupa/Lua 5.5),
   416 entries, values intact.

### Calibration note / caveat

The one user-supplied calibration fact ("`Test_Lock_Difficulty_1_01` has exactly
4 pieces and 0 connections") matches on pieces (4, ids 0–3) but the bytecode
contains **one** `AddConnection(0, 3, -1)` call. The data is unambiguous and
internally consistent, so the table records that connection. The discrepancy is
likely an in-game miscount or a runtime-filtered view; it is NOT a decode error
(confirmed by the independent cross-check).

### Coverage

- **416 / 416** non-empty lock classes decoded (70 `Test_Lock_Difficulty_*`,
  ~346 named chest/door locks).
- 69 `Test_Chest_Difficulty_*` companion classes have no AddPiece/AddConnection
  calls (they are the chests, not locks) and are correctly omitted.
- 1 name, `OC_Chest_Cutter_Lock`, has no `U`-prefixed `__InitDefaults` descriptor
  in the bytecode region (only a string-map reference at ~121 M); it is not among
  the 416 and produced no data. All other locks decoded.
