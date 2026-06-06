#!/usr/bin/env python3
"""
extract_locks.py - Extract AddPiece/AddConnection lock layouts from the
Gothic 1 Remake precompiled AngelScript cache (read-only).

See G1R/reference/blob-format-notes.md for the full format write-up.

Approach
--------
Each GothicLockConfig subclass has an __InitDefaults function whose loaded
AngelScript bytecode contains the AddPiece/AddConnection calls. Bytecode is the
in-memory form: 32-bit instruction words, opcode in the low byte; CALLSYS(0x3d)
is followed by the absolute 64-bit asCScriptFunction* of the native function.
The stream is NOT reliably 4-byte aligned to the file, so we locate calls by
byte-pattern (alignment-free) within each class's bytecode window:

  PshC4 push :  02 00 00 00  <int32 const>
  CALLSYS    :  3d 00 00 00  <ptr64>
  AddPiece   ptr = 0x1E96D2D2FC0   void AddPiece(int id, int rotation)
  AddConn    ptr = 0x1E96D2D3180   void AddConnection(int id,int connectedId,int direction)

AngelScript pushes parameters right-to-left, so the LAST PshC4 before the call
is the first parameter:
  AddPiece      consts [rotation, id]            -> id, rotation
  AddConnection consts [direction, connId, id]   -> id, connId, direction
"""
import struct, re, datetime

CACHE   = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache"
OUT_LUA = r"C:\dev\TautelliniMods\G1R\reference\lock-graphs.lua"

ADDPIECE_PTR = bytes.fromhex('c02f2d6de9010000')   # 0x1E96D2D2FC0
ADDCONN_PTR  = bytes.fromhex('80312d6de9010000')   # 0x1E96D2D3180
CALLSYS = b'\x3d\x00\x00\x00'
PSHC4   = b'\x02\x00\x00\x00'
PSHVPTR = b'\x30\x00\x00\x00'
REGION_A, REGION_B = 37_700_000, 42_200_000


def collect_consts_before(data, call_off, lo):
    """Walk backwards from a CALLSYS opcode collecting contiguous PshC4 consts.
    Returns consts in push order (first pushed first)."""
    consts = []
    p = call_off
    # skip an optional PshVPtr that pushes 'this' just before CALLSYS
    if p - 4 >= lo and data[p-4:p] == PSHVPTR:
        p -= 4
    # each PshC4 is 8 bytes: '02 00 00 00' + const, sitting immediately before p
    while p - 8 >= lo and data[p-8:p-4] == PSHC4:
        consts.insert(0, struct.unpack_from('<i', data, p-4)[0])
        p -= 8
    return consts


def extract():
    data = open(CACHE, 'rb').read()
    u32 = lambda o: struct.unpack_from('<I', data, o)[0]
    INITDEF = struct.pack('<I', 14) + b'__InitDefaults\x00'
    ULC = b'UGothicLockConfig\x00'
    name_re = re.compile(rb'[A-Za-z_][A-Za-z0-9_]{2,70}\x00')

    # 1. Enumerate lock-config descriptors: __InitDefaults marker preceded by a
    #    length-prefixed class name, with UGothicLockConfig referenced nearby.
    markers = []  # (name, initdef_off)
    i = REGION_A
    while True:
        d = data.find(INITDEF, i, REGION_B)
        if d < 0:
            break
        i = d + 1
        a = max(REGION_A, d - 90)
        best = None
        for m in name_re.finditer(data[a:d]):
            s = m.group()[:-1]
            pos = a + m.start()
            if pos >= 4 and u32(pos-4) == len(s):
                best = (s.decode('latin-1'), pos)
        if not best:
            continue
        if data.find(ULC, d, d + 2600) < 0:
            continue
        nm = best[0]
        if nm.startswith('U') and (nm.endswith('_Lock') or '_Lock_' in nm):
            nm = nm[1:]
        markers.append((nm, d))

    # 2. Per descriptor, bytecode window = this marker .. next marker (cap 4000B).
    marker_offs = sorted(set(d for _, d in markers))
    def window_end(d):
        for mo in marker_offs:
            if mo > d:
                return min(mo, d + 4000)
        return d + 4000

    results = {}
    for nm, d in markers:
        if nm in results:
            continue
        lo, hi = d, window_end(d)
        pieces, conns = [], []
        o = data.find(CALLSYS, lo, hi)
        while o >= 0 and o < hi:
            ptr = data[o+4:o+12]
            if ptr == ADDPIECE_PTR:
                c = collect_consts_before(data, o, lo)
                if len(c) >= 2:
                    pieces.append((c[-1], c[-2]))           # id, rotation
            elif ptr == ADDCONN_PTR:
                c = collect_consts_before(data, o, lo)
                if len(c) >= 3:
                    conns.append((c[-1], c[-2], c[-3]))      # id, connId, direction
            o = data.find(CALLSYS, o + 4, hi)
        results[nm] = {'pieces': pieces, 'connections': conns}
    return data, results


def validate(results):
    bad = []
    for nm, r in results.items():
        ids = [pid for pid, _ in r['pieces']]
        idset = set(ids)
        n = len(ids)
        if len(idset) != n:
            bad.append((nm, 'dup_piece_ids', ids))
        if n and idset != set(range(n)):
            bad.append((nm, 'noncontiguous_ids', sorted(idset)))
        for (a, b, dr) in r['connections']:
            if n and (a not in idset or b not in idset):
                bad.append((nm, 'conn_references_missing_piece', (a, b, dr)))
                break
    return bad


def write_lua(results):
    today = datetime.date.today().isoformat()
    L = []
    L.append("-- lock-graphs.lua")
    L.append("-- Gothic 1 Remake lock layouts, extracted from:")
    L.append("--   G1R/Script/PrecompiledScript_Shipping.Cache")
    L.append("-- Tool: tools/extract_locks.py    Generated: " + today)
    L.append("-- pieces      = { {id=, rot=}, ... }   from AddPiece(id, rotation)")
    L.append("-- connections = { {a=, b=, dir=}, ... } from AddConnection(id, connectedId, direction)")
    L.append("-- Validation: piece ids are contiguous 0..N-1; connection endpoints reference existing pieces.")
    L.append("return {")
    for nm in sorted(results):
        r = results[nm]
        if not r['pieces'] and not r['connections']:
            continue
        ps = ", ".join("{id=%d, rot=%d}" % (i, rot) for i, rot in r['pieces'])
        cs = ", ".join("{a=%d, b=%d, dir=%d}" % (a, b, dr) for a, b, dr in r['connections'])
        L.append('  ["%s"] = { pieces = { %s }, connections = { %s } },' % (nm, ps, cs))
    L.append("}")
    open(OUT_LUA, 'w', encoding='utf-8').write("\n".join(L) + "\n")


def main():
    data, results = extract()
    bad = validate(results)
    nonempty = {k: v for k, v in results.items() if v['pieces'] or v['connections']}
    empty = [k for k, v in results.items() if not v['pieces'] and not v['connections']]

    print("=== extraction summary ===")
    print("lock-config descriptors found:", len(results))
    print("non-empty (>=1 AddPiece/AddConn):", len(nonempty))
    print("empty descriptors:", len(empty))
    print("validation problems:", len(bad))
    for b in bad[:30]:
        print("  BAD", b)

    print("\n=== Test lock tier monotonicity ===")
    print("tier  count  avgPieces  avgConns")
    for t in range(1, 8):
        ps = cs = cnt = 0
        for idx in range(1, 11):
            k = "Test_Lock_Difficulty_%d_%02d" % (t, idx)
            if k in results:
                ps += len(results[k]['pieces'])
                cs += len(results[k]['connections'])
                cnt += 1
        if cnt:
            print("  %d     %2d     %.2f       %.2f" % (t, cnt, ps/cnt, cs/cnt))

    print("\n1_01:", results.get("Test_Lock_Difficulty_1_01"))
    write_lua(results)
    print("\nwrote", OUT_LUA)
    return results


if __name__ == '__main__':
    main()
