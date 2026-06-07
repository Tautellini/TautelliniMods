#!/usr/bin/env python3
"""dump_binds.py - dump native function/property signatures from Binds.Cache that
mention lockpick keywords, OR that appear in the byte window around a class name.

Binds.Cache stores readable C-like signatures as raw ASCII (no length prefix
needed). We print every printable-ASCII run >= minlen that contains a keyword,
preserving file order (so members cluster under their declaring class).
"""
import re, sys

BINDS = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\Binds.Cache"
BINDS_H = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\Binds.Cache.Headers"

def runs(data, minlen=4):
    for m in re.finditer(rb'[ -~]{%d,200}' % minlen, data):
        yield m.start(), m.group().decode('latin-1')

def main():
    path = BINDS_H if (len(sys.argv) > 1 and sys.argv[1] == 'h') else BINDS
    lo = int(sys.argv[2]) if len(sys.argv) > 2 else 5_030_000
    hi = int(sys.argv[3]) if len(sys.argv) > 3 else 5_205_000
    data = open(path, 'rb').read()
    print(f"# {path}  window [{lo:,} .. {hi:,}]  (file order)\n")
    for off, s in runs(data, 4):
        if off < lo: continue
        if off > hi: break
        print(f"{off:>12,}  {s}")

if __name__ == '__main__':
    main()
