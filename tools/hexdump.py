#!/usr/bin/env python3
"""hexdump.py - hex+ascii dump of a byte range. Also can scan for 64-bit values
that look like the AddPiece/AddConnection pointer family (0x1E9xxxxxxxx).
usage:
  python hexdump.py <file> <off> [length=256]
  python hexdump.py <file> ptrscan <lo> <hi>   # find 0x000001E9........ ptrs
"""
import sys, struct
PSC   = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache"
BINDS = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\Binds.Cache"
def main():
    f = sys.argv[1]
    path = {'psc':PSC,'binds':BINDS}.get(f,f)
    data = open(path,'rb').read()
    if sys.argv[2]=='ptrscan':
        lo=int(sys.argv[3]); hi=int(sys.argv[4])
        seen={}
        for o in range(lo, hi-7):
            v = struct.unpack_from('<Q', data, o)[0]
            # heap pointers in this dump are ~0x000001E9_xxxxxxxx
            if 0x000001E900000000 <= v <= 0x000001EA00000000:
                seen.setdefault(v, []).append(o)
        for v in sorted(seen):
            print(f"0x{v:016X}  x{len(seen[v]):<3d}  first@{seen[v][0]:,}")
        return
    off=int(sys.argv[2]); ln=int(sys.argv[3]) if len(sys.argv)>3 else 256
    for base in range(off, off+ln, 16):
        chunk = data[base:base+16]
        hx = ' '.join(f'{b:02x}' for b in chunk)
        asc = ''.join(chr(b) if 32<=b<127 else '.' for b in chunk)
        print(f"{base:>12,}  {hx:<48}  {asc}")
if __name__=='__main__': main()
