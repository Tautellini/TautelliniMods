#!/usr/bin/env python3
"""decode_bc.py - alignment-free scan of a byte window for AngelScript call
patterns and constants, the same robust approach as extract_locks.py. We do NOT
try a full linear disassembly (the loaded form is position-dependent); instead we
report every CALLSYS/CALLBND target pointer and the PshC4 consts that precede it,
plus any 0x1E9-family pointers (likely native fn or type refs).

usage: python decode_bc.py <off> <length_bytes> [--names <natives_off_lo> <hi>]
"""
import sys, struct, re
PSC=r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache"
CALLSYS=b'\x3d\x00\x00\x00'; CALLBND=b'\x3e\x00\x00\x00'
PSHC4=b'\x02\x00\x00\x00'; PSHVPTR=b'\x30\x00\x00\x00'

def consts_before(data, off, lo):
    out=[]; p=off
    if p-4>=lo and data[p-4:p]==PSHVPTR: p-=4
    while p-8>=lo and data[p-8:p-4]==PSHC4:
        out.insert(0, struct.unpack_from('<i',data,p-4)[0]); p-=8
    return out

def main():
    off=int(sys.argv[1]); ln=int(sys.argv[2])
    data=open(PSC,'rb').read()
    lo,hi=off,off+ln
    print(f"# scan [{lo:,}..{hi:,}]")
    for tag,name in ((CALLSYS,'CALLSYS'),(CALLBND,'CALLBND')):
        o=data.find(tag,lo,hi)
        while o>=0 and o<hi:
            ptr=struct.unpack_from('<Q',data,o+4)[0]
            c=consts_before(data,o,lo)
            print(f"{o:>12,}  {name} -> 0x{ptr:016X}   consts_before={c}")
            o=data.find(tag,o+4,hi)
    # also: standalone 0x1E9 ptrs in window (type/native refs)
    print("# 0x1E9-family qwords in window:")
    seen={}
    for p in range(lo,hi-7):
        v=struct.unpack_from('<Q',data,p)[0]
        if 0x000001E900000000<=v<=0x000001EA00000000:
            seen.setdefault(v,[]).append(p)
    for v in sorted(seen):
        print(f"   0x{v:016X}  x{len(seen[v])}  @{seen[v][0]:,}")

if __name__=='__main__': main()
