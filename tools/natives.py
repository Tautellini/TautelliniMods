#!/usr/bin/env python3
"""natives.py - enumerate registered native-function descriptors in the
PrecompiledScript blob. Each descriptor (seen at the ~100.83M table) looks like:

   <ptr64 asCScriptFunction*>  <u32 namelen> <name ascii> <pad...>
   01 00 00 00 00 <ptr64 int-type-desc> <u32 paramcount> ...

We detect: a 0x000001E9........ qword immediately followed by a plausible
u32 length (1..64) and that many printable name bytes. Print ptr,name,off.
Then filter for lock-relevant names and print their absolute pointers so we can
match them against CALLSYS targets in bytecode.
"""
import sys, struct, re
PSC = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache"

def main():
    data = open(PSC,'rb').read()
    lo = int(sys.argv[1]) if len(sys.argv)>1 else 100_700_000
    hi = int(sys.argv[2]) if len(sys.argv)>2 else 101_200_000
    filt = sys.argv[3].lower() if len(sys.argv)>3 else None
    out = []
    o = lo
    while o < hi-12:
        v = struct.unpack_from('<Q', data, o)[0]
        if 0x000001E900000000 <= v <= 0x000001EA00000000:
            ln = struct.unpack_from('<I', data, o+8)[0]
            if 1 <= ln <= 64:
                name = data[o+12:o+12+ln]
                if re.fullmatch(rb'[A-Za-z_][A-Za-z0-9_]*', name):
                    out.append((o, v, name.decode()))
                    o += 12+ln
                    continue
        o += 1
    for off, v, name in out:
        if filt and filt not in name.lower():
            continue
        print(f"{off:>12,}  0x{v:016X}  {name}")
    print(f"\n# {len(out)} native descriptors in [{lo:,}..{hi:,}]"
          + (f", filter={filt!r}" if filt else ""))

if __name__=='__main__': main()
