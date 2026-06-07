#!/usr/bin/env python3
"""mine_strings.py - find length-prefixed (and raw) name strings related to the
lockpick minigame in the AngelScript caches, with file offsets.

Two cache files:
  PrecompiledScript_Shipping.Cache (122MB) - loaded module dump
  Binds.Cache (5.8MB)                       - native binding signatures

Length-prefixed string = <uint32 len LE> <ascii bytes> <0x00>.
We also catch raw ASCII runs as a fallback.
"""
import struct, re, sys

PSC   = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache"
BINDS = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\Binds.Cache"
BINDS_H = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\Binds.Cache.Headers"

KEYWORDS = [b'Lock', b'lock', b'Pick', b'pick', b'Piece', b'Section', b'Open',
            b'Unlock', b'Scramble', b'Shuffle', b'Random', b'Rand', b'Precision',
            b'Connection', b'Connect', b'Rotation', b'Rotate', b'Solve', b'Solved',
            b'Tumbler', b'Pin', b'Cylinder', b'Memorize', b'Press', b'Reset',
            b'Section', b'Active', b'Remove', b'Deactivate', b'Disable', b'Win',
            b'Success', b'Fail', b'Complete', b'Check', b'Try', b'Goal', b'Target']

def find_lenpref_strings(data, lo=0, hi=None):
    """Yield (off, text) for length-prefixed ascii strings."""
    if hi is None: hi = len(data)
    # scan for printable runs, then check the 4 bytes before for length match
    run_re = re.compile(rb'[ -~]{3,80}\x00')
    for m in run_re.finditer(data, lo, hi):
        s = m.group()[:-1]
        pos = m.start()
        if pos >= 4:
            ln = struct.unpack_from('<I', data, pos-4)[0]
            if ln == len(s):
                yield (pos, s.decode('latin-1'))

def main():
    target = sys.argv[1] if len(sys.argv) > 1 else 'binds'
    if target == 'binds':
        path = BINDS
    elif target == 'bindsh':
        path = BINDS_H
    else:
        path = PSC
    data = open(path, 'rb').read()
    print(f"# {path}  ({len(data):,} bytes)\n")

    seen = set()
    out = []
    for off, s in find_lenpref_strings(data):
        if any(k in s.encode('latin-1') for k in KEYWORDS):
            if s not in seen:
                seen.add(s)
                out.append((off, s))
    # sort by name for readability, but keep offset
    out.sort(key=lambda x: x[1].lower())
    for off, s in out:
        print(f"{off:>12,}  {s}")
    print(f"\n# {len(out)} unique length-prefixed strings matched keywords")

if __name__ == '__main__':
    main()
