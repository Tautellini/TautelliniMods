#!/usr/bin/env python3
"""Cost of solving from the AUTHORED start only (the common case: a lock
just opened, or re-scrambled after a pick break). BFS and A* expansions
plus route length, max and 95th percentile across all locks."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sim_planner import parse_graphs, build, encode
from measure_search import bfs, astar

GRAPHS = Path(__file__).resolve().parent.parent / "G1R/reference/lock-graphs.lua"


def pct(vals, p):
    if not vals:
        return 0
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(len(vals) * p / 100))]


def main():
    locks = parse_graphs(GRAPHS)
    bexp, aexp, blen, fails = [], [], [], 0
    worst_b = (0, "")
    for name, (pieces, conns) in locks.items():
        n, place, out = build(pieces, conns)
        goal = encode([0] * n, place)
        start = encode([r for _i, r in pieces], place)
        if start == goal:
            continue
        opt, be = bfs(start, goal, n, place, out)
        _al, ae = astar(start, goal, n, place, out)
        if opt is None:
            fails += 1
            continue
        bexp.append(be)
        aexp.append(ae)
        blen.append(opt)
        if be > worst_b[0]:
            worst_b = (be, name)
    print(f"locks solved from authored start: {len(bexp)} (fails {fails})")
    print(f"BFS expansions : max {max(bexp)}, p95 {pct(bexp,95)}, median {pct(bexp,50)}")
    print(f"A*  expansions : max {max(aexp)}, p95 {pct(aexp,95)}, median {pct(aexp,50)}")
    print(f"optimal route  : max {max(blen)}, p95 {pct(blen,95)}, median {pct(blen,50)}")
    print(f"worst BFS lock : {worst_b[1]} ({worst_b[0]} states)")


if __name__ == "__main__":
    main()
