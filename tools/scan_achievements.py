"""Scan a UE cooked-script .Cache (or any binary) for readable strings matching
topics of interest. Pulls ASCII and UTF-16LE runs, dedupes, buckets by keyword.

Usage: python scan_achievements.py <file> [extra,keywords]
"""
import sys, re, mmap

path = sys.argv[1]
TOPICS = {
    "achievement": re.compile(rb"(?i)achiev"),
    "lockpick":    re.compile(rb"(?i)lockpick"),
    "unlock":      re.compile(rb"(?i)unlock"),
    "opened/count":re.compile(rb"(?i)(opened|picklock|locks_|numlock|lockcount|lockscount|stat_)"),
    "steam/stat":  re.compile(rb"(?i)(steam|writestat|writeachiev|onlinestat|presence)"),
}

ascii_run = re.compile(rb"[\x20-\x7e]{4,}")
utf16_run = re.compile(rb"(?:[\x20-\x7e]\x00){4,}")

found = {k: set() for k in TOPICS}

with open(path, "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    for m in ascii_run.finditer(mm):
        s = m.group()
        for k, pat in TOPICS.items():
            if pat.search(s):
                found[k].add(s.decode("ascii", "replace"))
    for m in utf16_run.finditer(mm):
        s = m.group().replace(b"\x00", b"")
        for k, pat in TOPICS.items():
            if pat.search(s):
                found[k].add(s.decode("ascii", "replace"))
    mm.close()

for k in TOPICS:
    vals = sorted(found[k], key=lambda x: (len(x), x))
    print(f"\n===== {k}  ({len(vals)} unique) =====")
    for v in vals[:200]:
        print("  " + v)
    if len(vals) > 200:
        print(f"  ... (+{len(vals)-200} more)")
