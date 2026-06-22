#!/usr/bin/env python3
"""Storage feasibility for a SHIPPED next-move policy.

Per lock, BFS the whole solvable component from the goal and count states
(each needs one next-move byte). Sum across all 416 locks = the full policy
size. Also report connection structure (the dead-edge question: a lock with
no connections has no drag, so the shipped model can't diverge from live)."""
from pathlib import Path
from collections import deque
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sim_planner import parse_graphs, build, encode, successors

GRAPHS = Path(__file__).resolve().parent.parent / "G1R/reference/lock-graphs.lua"


def comp_size(goal, n, place, out):
    seen = {goal}
    q = deque([goal])
    while q:
        S = q.popleft()
        for _mv, T in successors(S, n, place, out):
            if T not in seen:
                seen.add(T)
                q.append(T)
    return len(seen)


def main():
    locks = parse_graphs(GRAPHS)
    total = 0
    biggest = []
    no_conn = 0
    max_deg = 0
    conn_hist = {}
    for name, (pieces, conns) in locks.items():
        n, place, out = build(pieces, conns)
        goal = encode([0] * n, place)
        sz = comp_size(goal, n, place, out)
        total += sz
        biggest.append((sz, name))
        if not conns:
            no_conn += 1
        deg = max((len(o) for o in out), default=0)
        max_deg = max(max_deg, deg)
        conn_hist[len(conns)] = conn_hist.get(len(conns), 0) + 1
    biggest.sort(reverse=True)
    print(f"locks: {len(locks)}")
    print(f"TOTAL solvable states (= policy entries): {total:,}")
    print(f"  as 1 byte/state: {total/1e6:.1f} MB raw")
    print(f"locks with NO connections: {no_conn}/{len(locks)} (shipped model == live)")
    print(f"max out-degree (drag partners): {max_deg}")
    print("biggest 8 locks by component:")
    for sz, name in biggest[:8]:
        print(f"  {sz:>8,}  {name}")
    print("connection-count histogram (count -> #locks):")
    for c in sorted(conn_hist):
        print(f"  {c:>3} conns: {conn_hist[c]} locks")


if __name__ == "__main__":
    main()
