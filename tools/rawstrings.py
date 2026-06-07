#!/usr/bin/env python3
"""rawstrings.py - dump raw ASCII strings (>=minlen) containing any keyword,
with file offsets. Works regardless of length-prefix framing.

usage: python rawstrings.py <file> <minlen> [kwgroup]
  file: psc | binds | bindsh | <path>
"""
import re, sys

PSC   = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache"
BINDS = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\Binds.Cache"
BINDS_H = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\Binds.Cache.Headers"

GROUPS = {
  'lock': [b'Lock', b'Pick', b'lockpick', b'Tumbler', b'Cylinder'],
  'mini': [b'Piece', b'Section', b'Scramble', b'Shuffle', b'Precision',
           b'Connection', b'Rotation', b'Solve', b'Unlock', b'Open'],
  'all': [b'Lock', b'Pick', b'Piece', b'Section', b'Open', b'Unlock',
          b'Scramble', b'Shuffle', b'Random', b'Precision', b'Connection',
          b'Rotation', b'Rotate', b'Solve', b'Tumbler', b'Pin', b'Cylinder',
          b'Memorize', b'Press', b'Reset', b'Active', b'Win', b'Success',
          b'Fail', b'Complete', b'Goal', b'Target', b'Deactivate', b'Disable'],
}

def main():
    farg = sys.argv[1] if len(sys.argv) > 1 else 'binds'
    minlen = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    grp = sys.argv[3] if len(sys.argv) > 3 else 'lock'
    path = {'psc':PSC,'binds':BINDS,'bindsh':BINDS_H}.get(farg, farg)
    kws = GROUPS.get(grp, GROUPS['all'])
    data = open(path, 'rb').read()
    print(f"# {path} ({len(data):,} bytes)  minlen={minlen} group={grp}\n")
    run_re = re.compile(rb'[ -~]{%d,160}' % minlen)
    seen = {}
    for m in run_re.finditer(data):
        s = m.group()
        if any(k in s for k in kws):
            txt = s.decode('latin-1')
            if txt not in seen:
                seen[txt] = m.start()
    for txt, off in sorted(seen.items(), key=lambda x: x[0].lower()):
        print(f"{off:>12,}  {txt}")
    print(f"\n# {len(seen)} unique strings")

if __name__ == '__main__':
    main()
