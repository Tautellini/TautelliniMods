#!/usr/bin/env python3
"""sigs.py - extract C-like native signatures (lines that look like
'ReturnType FuncName(args...)' or 'Type member') from Binds.Cache that match a
regex, anywhere in the file, with offsets. Used to find runtime lock methods.
usage: python sigs.py <regex> [minlen]
"""
import re, sys
BINDS = r"C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Script\Binds.Cache"
def main():
    pat = re.compile(sys.argv[1], re.I)
    minlen = int(sys.argv[2]) if len(sys.argv)>2 else 4
    data = open(BINDS,'rb').read()
    for m in re.finditer(rb'[ -~]{%d,300}'%minlen, data):
        s = m.group().decode('latin-1')
        if pat.search(s):
            print(f"{m.start():>10,}  {s}")
if __name__=='__main__': main()
