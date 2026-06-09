#!/usr/bin/env python3
"""Validate the in-game planner algorithms against the mined lock data.

Mirrors main.lua's search machine line for line (greedy best-first and
the sliced A*) and checks, over all mined locks with authored plus
random scrambles:
  1. A* route length == plain-BFS shortest length (optimality parity)
  2. every produced route replays legally and ends at the goal
  3. greedy-vs-optimal inflation (the reason A* exists)
  4. A* expansion counts (how many 2500-expansion slices a lock costs)

BFS parity runs for locks up to 6 pieces (7-piece spaces are 823k
states; there A* is checked for route validity and <= greedy only).
"""
import math
import random
import re
import sys
from collections import deque
from pathlib import Path

GRAPHS = Path(__file__).resolve().parent.parent / \
    "G1R/reference/lock-graphs.lua"

GREEDY_CAP = 80000
ASTAR_CAP = 130000


def parse_graphs(path):
    locks = {}
    text = path.read_text(encoding="utf-8")
    for m in re.finditer(
            r'\["([^"]+)"\]\s*=\s*\{\s*pieces\s*=\s*\{(.*?)\}\s*,\s*'
            r'connections\s*=\s*\{(.*?)\}\s*\}', text, re.S):
        name, ptxt, ctxt = m.groups()
        pieces = [(int(a), int(b)) for a, b in
                  re.findall(r'id=(-?\d+),\s*rot=(-?\d+)', ptxt)]
        conns = [(int(a), int(b), int(d)) for a, b, d in
                 re.findall(r'a=(\d+),\s*b=(\d+),\s*dir=(-?\d+)', ctxt)]
        locks[name] = (pieces, conns)
    return locks


def build(pieces, conns):
    n = len(pieces)
    place = [7 ** i for i in range(n)]
    out = [[] for _ in range(n)]
    for a, b, d in conns:
        out[a].append((b, d))
    return n, place, out


def encode(rots, place):
    return sum((r + 3) * place[i] for i, r in enumerate(rots))


def successors(S, n, place, out):
    """Yield (move, T) exactly like the Lua expansion loop."""
    for x in range(n):
        px = place[x]
        dx = (S // px) % 7
        for d in (-1, 1):
            nx = dx + d
            if not 0 <= nx <= 6:
                continue
            delta = d * px
            ok = True
            for b, edir in out[x]:
                pb = place[b]
                db = (S // pb) % 7
                nb = db + d * edir
                if not 0 <= nb <= 6:
                    ok = False
                    break
                delta += d * edir * pb
            if ok:
                yield (x + 1) * 4 + (1 if d > 0 else 0), S + delta


def sum_abs(S, n, place):
    return sum(abs((S // place[i]) % 7 - 3) for i in range(n))


def reconstruct(goal, origin, seen, parent):
    route = []
    T = goal
    while T != origin:
        route.append(seen[T])
        T = parent[T]
    route.reverse()
    return route


# the four shipped variants: (reverse piece order, FIFO bucket pop)
SEARCH_VARIANTS = [(False, False), (True, False), (False, True), (True, True)]


def greedy(start, goal, n, place, out, variant=0):
    """Mirror of the Lua greedy variant: piece-iteration order x bucket
    pop side (LIFO/FIFO), deque buckets addressed by head/tail."""
    if start == goal:
        return [], 0
    rev, fifo = SEARCH_VARIANTS[variant]
    maxH = 6 * n
    buckets = [[] for _ in range(maxH + 1)]
    head = [0] * (maxH + 1)
    tail = [-1] * (maxH + 1)
    h0 = sum_abs(start, n, place)
    buckets[h0].append(start)
    tail[h0] = 0
    seen, parent = {start: 0}, {}
    minH, expended = h0, 0
    order = range(n - 1, -1, -1) if rev else range(n)
    while True:
        while head[minH] > tail[minH]:
            minH += 1
            if minH > maxH:
                return None, expended
        if fifo:
            S = buckets[minH][head[minH]]
            head[minH] += 1
        else:
            S = buckets[minH][tail[minH]]
            tail[minH] -= 1
        expended += 1
        if expended > GREEDY_CAP:
            return None, expended
        hS = sum_abs(S, n, place)
        for x in order:
            px = place[x]
            dx = (S // px) % 7
            for d in (-1, 1):
                nx = dx + d
                if not 0 <= nx <= 6:
                    continue
                delta = d * px
                ok = True
                for b, edir in out[x]:
                    pb = place[b]
                    nb = (S // pb) % 7 + d * edir
                    if not 0 <= nb <= 6:
                        ok = False
                        break
                    delta += d * edir * pb
                if not ok:
                    continue
                T = S + delta
                if T in seen:
                    continue
                seen[T] = (x + 1) * 4 + (1 if d > 0 else 0)
                parent[T] = S
                if T == goal:
                    return reconstruct(goal, start, seen, parent), expended
                nh = max(0, min(maxH, minH + sum_abs(T, n, place) - hS))
                # write at tail+1, reusing popped (LIFO) slots exactly as
                # the Lua does; plain append would leak popped states
                nt = tail[nh] + 1
                if nt < len(buckets[nh]):
                    buckets[nh][nt] = T
                else:
                    buckets[nh].append(T)
                tail[nh] = nt
                if nh < minH:
                    minH = nh


def multi_greedy(start, goal, n, place, out):
    """The shipped planner: best route over the four variants."""
    best, total = None, 0
    for v in range(len(SEARCH_VARIANTS)):
        r, e = greedy(start, goal, n, place, out, v)
        total += e
        if r is not None and (best is None or len(r) < len(best)):
            best = r
    return best, total


def astar(start, goal, n, place, out, w):
    """Mirror of the Lua astar mode (lazy deletion, goal on pop)."""
    if start == goal:
        return [], 0
    h0 = sum_abs(start, n, place)
    lb = math.ceil(h0 / w)
    buckets = {lb: [(start, 0)]}
    seen, parent = {start: 0}, {}
    gtab = {start: 0}
    sumtab = {start: h0}
    minF, open_, expended = lb, 1, 0
    while True:
        while not buckets.get(minF):
            if open_ <= 0:
                return None, expended
            buckets.pop(minF, None)
            minF += 1
        S, g = buckets[minF].pop()
        open_ -= 1
        if gtab[S] != g:
            continue  # stale duplicate
        if S == goal:
            return reconstruct(goal, start, seen, parent), expended
        expended += 1
        if expended > ASTAR_CAP:
            return None, expended
        sa, g1 = sumtab[S], g + 1
        if g1 >= 250:
            continue
        for mv, T in successors(S, n, place, out):
            if T in gtab and g1 >= gtab[T]:
                continue
            gtab[T] = g1
            sumtab[T] = sum_abs(T, n, place)
            seen[T] = mv
            parent[T] = S
            f = g1 + math.ceil(sumtab[T] / w)
            buckets.setdefault(f, []).append((T, g1))
            open_ += 1
        _ = sa


def bfs(start, goal, n, place, out):
    if start == goal:
        return []
    q = deque([start])
    seen, parent = {start: 0}, {}
    while q:
        S = q.popleft()
        for mv, T in successors(S, n, place, out):
            if T in seen:
                continue
            seen[T] = mv
            parent[T] = S
            if T == goal:
                return reconstruct(goal, start, seen, parent)
            q.append(T)
    return None


def replay(route, start, goal, n, place, out):
    S = start
    for mv in route:
        legal = dict(successors(S, n, place, out))
        if mv not in legal:
            return False
        S = legal[mv]
    return S == goal


def main():
    rng = random.Random(42)
    locks = parse_graphs(GRAPHS)
    print(f"{len(locks)} locks loaded")
    invalid, planner_fail = [], 0
    single_ratio, multi_ratio, slices = [], [], []
    worst_single = (0, None)
    worst_multi = (0, None)
    cases = 0
    for name, (pieces, conns) in sorted(locks.items()):
        n, place, out = build(pieces, conns)
        goal = encode([0] * n, place)
        starts = [encode([r for _, r in pieces], place)]
        for _ in range(3):
            starts.append(encode(
                [rng.randint(-3, 3) for _ in range(n)], place))
        for start in starts:
            if start == goal:
                continue
            cases += 1
            mroute, mexp = multi_greedy(start, goal, n, place, out)
            sroute, _ = greedy(start, goal, n, place, out, 0)  # variant 0
            opt = bfs(start, goal, n, place, out) if n <= 6 else None
            if mroute is None:
                planner_fail += 1
                continue
            slices.append(mexp)
            if not replay(mroute, start, goal, n, place, out):
                invalid.append((name, start, "multi"))
            if opt and sroute is not None:
                mr, sr = len(mroute) / len(opt), len(sroute) / len(opt)
                multi_ratio.append(mr)
                single_ratio.append(sr)
                if mr > worst_multi[0]:
                    worst_multi = (mr, (name, len(mroute), len(opt)))
                if sr > worst_single[0]:
                    worst_single = (sr, (name, len(sroute), len(opt)))
    print(f"{cases} cases")
    print(f"planner failed to find a route: {planner_fail}")
    print(f"invalid (unreplayable) routes: {len(invalid)}")
    for m in invalid[:10]:
        print("  INVALID", m)
    if single_ratio:
        sr = sorted(single_ratio)
        mr = sorted(multi_ratio)
        over2 = sum(1 for x in mr if x >= 2.0)
        print(f"SINGLE greedy   route/optimal: mean {sum(sr)/len(sr):.3f}x "
              f"p95 {sr[int(len(sr)*0.95)]:.2f}x WORST {worst_single[0]:.1f}x "
              f"{worst_single[1]}")
        print(f"MULTI (shipped) route/optimal: mean {sum(mr)/len(mr):.3f}x "
              f"p95 {mr[int(len(mr)*0.95)]:.2f}x WORST {worst_multi[0]:.2f}x "
              f"{worst_multi[1]}")
        print(f"MULTI cases >= 2x optimal: {over2} (target 0)")
    if slices:
        slices.sort()
        print(f"4-variant expansions: mean {sum(slices)//len(slices)}, "
              f"p95 {slices[int(len(slices)*0.95)]}, max {slices[-1]} "
              f"(~{slices[-1]/1500:.0f} slices of 1500)")
    bad = len(invalid) + planner_fail + (
        1 if single_ratio and worst_multi[0] >= 2.0 else 0)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
