#!/usr/bin/env python3
"""ctx.py - print all printable ASCII runs within [off-before, off+after],
in file order, with offsets. For inspecting the neighborhood of a hit.
usage: python ctx.py <file> <off> [before=400] [after=1200] [minlen=4]
"""
import re, sys
PSC   = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\PrecompiledScript_Shipping.Cache"
BINDS = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\Binds.Cache"
def main():
    f = sys.argv[1]; off = int(sys.argv[2])
    before = int(sys.argv[3]) if len(sys.argv)>3 else 400
    after  = int(sys.argv[4]) if len(sys.argv)>4 else 1200
    minlen = int(sys.argv[5]) if len(sys.argv)>5 else 4
    path = {'psc':PSC,'binds':BINDS}.get(f,f)
    data = open(path,'rb').read()
    lo=max(0,off-before); hi=min(len(data),off+after)
    print(f"# {path}  ctx [{lo:,} .. {hi:,}] anchor {off:,}")
    for m in re.finditer(rb'[ -~]{%d,200}'%minlen, data[lo:hi]):
        a=lo+m.start()
        mark = " <==" if a<=off<=a+len(m.group()) else ""
        print(f"{a:>12,}  {m.group().decode('latin-1')}{mark}")
if __name__=='__main__': main()
