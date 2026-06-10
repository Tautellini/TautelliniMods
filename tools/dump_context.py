"""Dump ASCII strings near each occurrence of anchor substrings in a binary.
Reveals which property/object names a cooked-script object serializes next to a
known string (e.g. an achievement's required-memory reference).

Usage: python dump_context.py <file> <window_bytes> <anchor1> [anchor2 ...]
"""
import sys, re, mmap

path = sys.argv[1]
window = int(sys.argv[2])
anchors = [a.encode() for a in sys.argv[3:]]
ascii_run = re.compile(rb"[\x20-\x7e]{4,}")

with open(path, "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    for anchor in anchors:
        print(f"\n########## anchor: {anchor.decode()} ##########")
        start = 0
        hits = 0
        while True:
            i = mm.find(anchor, start)
            if i == -1:
                break
            hits += 1
            if hits <= 6:
                lo = max(0, i - window)
                hi = min(len(mm), i + window)
                strs = [m.group().decode("ascii", "replace") for m in ascii_run.finditer(mm[lo:hi])]
                print(f"--- occurrence {hits} @ 0x{i:X} ---")
                for s in strs:
                    print("   " + s)
            start = i + 1
        print(f"(total occurrences: {hits})")
    mm.close()
