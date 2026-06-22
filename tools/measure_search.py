#!/usr/bin/env python3
"""Compare candidate solver algorithms on a realistic workload.

For every mined lock we build a workload of start states: the authored
scramble plus random-walk scrambles of growing depth (always reachable,
since we walk from the goal with valid moves). For each start we run:
  - BFS            : optimal route, explores all states within the radius
  - greedy (1 var) : the current per-variant greedy, single run
  - A*             : f = g + sum-of-distances heuristic, optimal

We report, per algorithm: the MAX states expanded (speed + memory proxy)
and the MAX route length vs BFS-optimal (quality). Deterministic walk
(seeded) so reruns match.
"""
from pathlib import Path
from collections import deque
import heapq
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sim_planner import parse_graphs, build, encode, successors, sum_abs, greedy

GRAPHS = Path(__file__).resolve().parent.parent / "G1R/reference/lock-graphs.lua"
EXP_CAP = 1_000_000


def bfs(start, goal, n, place, out):
    if start == goal:
        return 0, 0
    seen = {start}
    q = deque([start])
    dist = {start: 0}
    exp = 0
    while q:
        S = q.popleft()
        exp += 1
        d = dist[S]
        for _mv, T in successors(S, n, place, out):
            if T not in seen:
                seen.add(T)
                dist[T] = d + 1
                if T == goal:
                    return d + 1, exp
                q.append(T)
        if exp > EXP_CAP:
            return None, exp
    return None, exp


def astar(start, goal, n, place, out):
    if start == goal:
        return 0, 0
    openh = [(sum_abs(start, n, place), 0, start)]
    g = {start: 0}
    exp = 0
    while openh:
        f, gc, S = heapq.heappop(openh)
        if S == goal:
            return gc, exp
        if gc > g.get(S, 1 << 30):
            continue
        exp += 1
        for _mv, T in successors(S, n, place, out):
            ng = gc + 1
            if ng < g.get(T, 1 << 30):
                g[T] = ng
                heapq.heappush(openh, (ng + sum_abs(T, n, place), ng, T))
        if exp > EXP_CAP:
            return None, exp
    return None, exp


def greedy_len_exp(start, goal, n, place, out):
    route, exp = greedy(start, goal, n, place, out, variant=0)
    return (len(route) if route is not None else None), exp


def random_scramble(goal, n, place, out, steps, rng):
    S = goal
    for _ in range(steps):
        succ = [T for _mv, T in successors(S, n, place, out)]
        if not succ:
            break
        S = rng.choice(succ)
    return S


def main():
    locks = parse_graphs(GRAPHS)
    rng = random.Random(1234)
    stats = {k: {"maxexp": 0, "maxexp_lock": "", "maxinfl": 1.0,
                 "maxinfl_lock": "", "fail": 0} for k in ("bfs", "greedy", "astar")}
    total_cases = 0
    for name, (pieces, conns) in locks.items():
        n, place, out = build(pieces, conns)
        goal = encode([0] * n, place)
        starts = [encode([r for _i, r in pieces], place)]
        for depth in (5, 10, 20, 40, 80):
            for _ in range(3):
                starts.append(random_scramble(goal, n, place, out, depth, rng))
        for start in starts:
            if start == goal:
                continue
            total_cases += 1
            opt, bexp = bfs(start, goal, n, place, out)
            glen, gexp = greedy_len_exp(start, goal, n, place, out)
            alen, aexp = astar(start, goal, n, place, out)
            for key, ln, exp in (("bfs", opt, bexp), ("greedy", glen, gexp),
                                 ("astar", alen, aexp)):
                st = stats[key]
                if exp > st["maxexp"]:
                    st["maxexp"], st["maxexp_lock"] = exp, name
                if ln is None:
                    st["fail"] += 1
                elif opt and opt > 0:
                    infl = ln / opt
                    if infl > st["maxinfl"]:
                        st["maxinfl"], st["maxinfl_lock"] = infl, name
    print(f"cases: {total_cases}")
    for key in ("bfs", "greedy", "astar"):
        st = stats[key]
        print(f"{key:7s}: max expansions {st['maxexp']:>8d} ({st['maxexp_lock']}), "
              f"max route/opt {st['maxinfl']:.2f}x ({st['maxinfl_lock']}), "
              f"fails {st['fail']}")


if __name__ == "__main__":
    main()
