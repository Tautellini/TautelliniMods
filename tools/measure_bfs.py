#!/usr/bin/env python3
"""Measure whether plain BFS is viable as the lockpick solver.

For each mined lock, BFS the ENTIRE reachable component from the goal
(all-centered) state. Moves are undirected (x,+d undone by x,-d), so this
component is exactly the set of solvable states, and its size is the
worst-case number of states any solve from any scramble could explore.
The BFS depth is the longest optimal route.
"""
from pathlib import Path
from collections import deque
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sim_planner import parse_graphs, build, encode, successors

GRAPHS = Path(__file__).resolve().parent.parent / "G1R/reference/lock-graphs.lua"


def component(goal, n, place, out):
    seen = {goal}
    q = deque([(goal, 0)])
    maxdepth = 0
    while q:
        S, d = q.popleft()
        if d > maxdepth:
            maxdepth = d
        for _mv, T in successors(S, n, place, out):
            if T not in seen:
                seen.add(T)
                q.append((T, d + 1))
    return len(seen), maxdepth


def main():
    locks = parse_graphs(GRAPHS)
    worst_states = (0, "")
    worst_depth = (0, "")
    by_pieces = {}
    for name, (pieces, conns) in locks.items():
        n, place, out = build(pieces, conns)
        goal = encode([0] * n, place)
        size, depth = component(goal, n, place, out)
        if size > worst_states[0]:
            worst_states = (size, name)
        if depth > worst_depth[0]:
            worst_depth = (depth, name)
        rec = by_pieces.setdefault(n, [0, 0, 0])
        rec[0] += 1
        rec[1] = max(rec[1], size)
        rec[2] = max(rec[2], depth)
    print(f"locks: {len(locks)}")
    print(f"worst component (states explored): {worst_states[0]} ({worst_states[1]})")
    print(f"worst optimal route (BFS depth):  {worst_depth[0]} ({worst_depth[1]})")
    print("per piece-count: n -> (#locks, max states, max depth)")
    for n in sorted(by_pieces):
        c, s, d = by_pieces[n]
        print(f"  n={n}: {c} locks, max {s} states, max {d} moves")


if __name__ == "__main__":
    main()
