#!/usr/bin/env python3
"""Validate the shipped lock policies and emit reference hashes.

  1. every blob inflates to exactly 7^n bytes
  2. following the next-move policy from random reachable states reaches the
     goal (every move legal, terminates) -> the GENERATOR is correct
  3. write per-blob hashes to tools/_hashes_py.txt for the Lua inflate
     round-trip test (dump_hashes.lua must produce the identical file)
"""
import sys
import re
import zlib
import random
from pathlib import Path

sys.path.insert(0, "tools")
from sim_planner import parse_graphs

GRAPHS = Path("G1R/reference/lock-graphs.lua")
DATA = Path("G1R/LockpickSettings/Scripts/data/lockpolicies.lua")
IDX = Path("G1R/LockpickSettings/Scripts/data/lockpolicies_index.lua")


def load_blob(path):
    # the .lua is `return { <int per byte> }`; pull the integers and pack them
    txt = path.read_text(encoding="utf-8")
    body = txt[txt.index("{") + 1:txt.rindex("}")]
    return bytes(int(x) for x in body.split(",") if x.strip())


def load_index(path):
    idx = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.search(
            r'\["([^"]+)"\]\s*=\s*\{\s*n\s*=\s*(\d+),\s*v\s*=\s*\{(.+)\}\s*\}', line)
        if not m:
            continue
        vs = [(int(a), int(b)) for a, b in re.findall(r'\{(\d+),(\d+)\}', m.group(3))]
        idx[m.group(1)] = (int(m.group(2)), vs)
    return idx


def hashb(b):
    h = 0
    for x in b:
        h = (h * 131 + x) % 2147483647
    return h


def apply_move(S, x, d, place, out):
    px = place[x]
    dx = (S // px) % 7
    if not 0 <= dx + d <= 6:
        return None
    delta = d * px
    for (b, edir) in out[x]:
        pb = place[b]
        db = (S // pb) % 7
        if not 0 <= db + d * edir <= 6:
            return None
        delta += d * edir * pb
    return S + delta


def main():
    locks = parse_graphs(GRAPHS)
    idx = load_index(IDX)
    blob = load_blob(DATA)
    rng = random.Random(99)
    hashes, bad = [], 0
    for name in sorted(idx):
        n, vs = idx[name]
        pieces, conns = locks[name]
        place = [7 ** i for i in range(n)]
        goal = sum(3 * place[i] for i in range(n))
        for k, (off, length) in enumerate(vs):
            raw = zlib.decompressobj(-15).decompress(blob[off:off + length])
            if len(raw) != 7 ** n:
                bad += 1
                print(f"LEN {name} k{k}: {len(raw)} != {7**n}")
                continue
            hashes.append(f"{name} {k} {hashb(raw)}")
            out = [[] for _ in range(n)]
            for a, b, d in conns[k:]:
                out[a].append((b, d))
            for _ in range(20):
                S = goal
                for _ in range(rng.randint(0, 40)):
                    succ = [T for x in range(n) for d in (-1, 1)
                            if (T := apply_move(S, x, d, place, out)) is not None]
                    if succ:
                        S = rng.choice(succ)
                steps = 0
                while S != goal:
                    mv = raw[S]
                    if mv == 0:
                        bad += 1
                        print(f"DEAD-END {name} k{k} state {S}")
                        break
                    m = mv - 1
                    T = apply_move(S, m // 2, 1 if m % 2 == 1 else -1, place, out)
                    if T is None:
                        bad += 1
                        print(f"ILLEGAL {name} k{k} state {S}")
                        break
                    S = T
                    steps += 1
                    if steps > 1000:
                        bad += 1
                        print(f"NOCONVERGE {name} k{k}")
                        break
    Path("tools/_hashes_py.txt").write_text("\n".join(hashes) + "\n", encoding="utf-8")
    print(f"blobs: {len(hashes)}  semantic failures: {bad}")


main()
