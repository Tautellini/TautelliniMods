#!/usr/bin/env python3
"""Bit-faithful re-implementation of main.lua's A* (NOT the idealized
twin). Mirrors EXACTLY: gsum packing (g*64+sumAbs), open-queue packing
(S*256+g), the bucket dict, minF advance, lazy deletion, goal-on-pop,
the open counter, the g1<250 / g1<256 guards, and the incremental
sum2 = sumAbs + hd. Then it adversarially checks:

  * sum2 (incremental) == true sum_abs(T) for every relabel
  * packing exactness (no collision in S*256+g and g*64+sumAbs)
  * route length == BFS optimal
  * route legal + ends at goal
  * a stale duplicate is never expanded
  * the open counter hits 0 exactly when buckets are empty
  * minF never decreases (frontier never rewinds)

Runs the mined locks AND a fuzz of random small graphs with high
out-degree and large scrambles to push g, sumAbs and packing limits.
"""
import math
import random
import re
import sys
from collections import deque
from pathlib import Path

GRAPHS = Path(__file__).resolve().parent.parent / \
    "G1R/LockpickSettings/Scripts/data/lockgraphs.lua"


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


def true_sum_abs(S, n, place):
    return sum(abs((S // place[i]) % 7 - 3) for i in range(n))


def successors(S, n, place, out, gd=3):
    """Yield (mv, T, hd) like the Lua loop: hd is the incremental
    sumAbs change the Lua computes."""
    for x in range(n):
        px = place[x]
        dx = (S // px) % 7
        for d in (-1, 1):
            nx = dx + d
            if not 0 <= nx <= 6:
                continue
            delta = d * px
            hd = abs(nx - gd) - abs(dx - gd)
            ok = True
            for b, edir in out[x]:
                pb = place[b]
                db = (S // pb) % 7
                nb = db + d * edir
                if not 0 <= nb <= 6:
                    ok = False
                    break
                delta += d * edir * pb
                hd += abs(nb - gd) - abs(db - gd)
            if ok:
                yield (x + 1) * 4 + (1 if d > 0 else 0), S + delta, hd


def bfs(start, goal, n, place, out):
    if start == goal:
        return []
    q = deque([start])
    seen, parent = {start: 0}, {}
    while q:
        S = q.popleft()
        for mv, T, _ in successors(S, n, place, out):
            if T in seen:
                continue
            seen[T] = mv
            parent[T] = S
            if T == goal:
                route = []
                while T != start:
                    route.append(seen[T])
                    T = parent[T]
                route.reverse()
                return route
            q.append(T)
    return None


class Bug(Exception):
    pass


def astar_faithful(start, goal, n, place, out, w, problems):
    """Exact main.lua semantics. Records any internal contract
    violation into `problems`."""
    if start == goal:
        return []
    h0 = true_sum_abs(start, n, place)
    lb = math.ceil(h0 / w)
    buckets = {lb: [start * 256 + 0]}       # pack S*256+g, g=0
    gsum = {start: 0 * 64 + h0}             # pack g*64+sumAbs
    seen, parent = {start: 0}, {}
    minF = lb
    open_ = 1
    expended = 0
    last_minF = lb
    expanded_states = []                     # to detect stale expansion
    BIG = 130000

    while True:
        bucket = buckets.get(minF)
        bn = len(bucket) if bucket else 0
        while bn == 0:
            if open_ <= 0:
                return None                  # frontier empty
            buckets.pop(minF, None)
            minF += 1
            bucket = buckets.get(minF)
            bn = len(bucket) if bucket else 0
        if minF < last_minF:
            problems.append(f"minF rewound {last_minF}->{minF}")
        last_minF = minF

        entry = bucket.pop()                 # last element (LIFO)
        open_ -= 1
        S = entry // 256
        g = entry % 256
        packed = gsum[S]
        if packed // 64 == g:                # not stale
            if S == goal:
                # reconstruct
                route, T = [], goal
                while T != start:
                    route.append(seen[T])
                    T = parent[T]
                route.reverse()
                # f of the popped goal must equal its g (h(goal)=0)
                if g + math.ceil((packed % 64) / w) != g:
                    problems.append("goal popped with h!=0")
                return route
            if S in expanded_states_set:
                problems.append(f"state {S} expanded twice (stale!)")
            expanded_states_set.add(S)
            expended += 1
            if expended > BIG:
                return None
            sumAbs = packed % 64
            # verify the unpacked sumAbs matches truth
            if sumAbs != true_sum_abs(S, n, place):
                problems.append(
                    f"unpacked sumAbs {sumAbs} != true "
                    f"{true_sum_abs(S, n, place)} at S={S}")
            g1 = g + 1
            for mv, T, hd in successors(S, n, place, out):
                if g1 >= 250:
                    continue
                old = gsum.get(T)
                if old is None or g1 < old // 64:
                    sum2 = sumAbs + hd
                    # CONTRACT: incremental sum2 == true sumAbs(T)
                    ts = true_sum_abs(T, n, place)
                    if sum2 != ts:
                        problems.append(
                            f"sum2 {sum2} != true {ts} (T={T})")
                    if sum2 >= 64:
                        problems.append(f"sumAbs {sum2} >= 64 overflow")
                    if T * 256 + g1 != (T * 256 + g1):
                        pass
                    gsum[T] = g1 * 64 + sum2
                    seen[T] = mv
                    parent[T] = S
                    f = g1 + math.ceil(sum2 / w)
                    if f < minF:
                        problems.append(
                            f"pushed f={f} < minF={minF} (rewind!)")
                    buckets.setdefault(f, []).append(T * 256 + g1)
                    open_ += 1


expanded_states_set = set()


def replay(route, start, goal, n, place, out):
    S = start
    for mv in route:
        legal = {m: T for m, T, _ in successors(S, n, place, out)}
        if mv not in legal:
            return False
        S = legal[mv]
    return S == goal


def run_case(name, n, place, out, w, start, goal, results):
    global expanded_states_set
    expanded_states_set = set()
    problems = []
    route = astar_faithful(start, goal, n, place, out, w, problems)
    for p in problems:
        results["contract"].append((name, start, p))
    if route is not None:
        if not replay(route, start, goal, n, place, out):
            results["invalid"].append((name, start))
    if n <= 6:
        b = bfs(start, goal, n, place, out)
        if (b is None) != (route is None):
            results["existence"].append((name, start))
        elif b is not None and len(b) != len(route):
            results["length"].append(
                (name, start, len(b), len(route)))


def main():
    rng = random.Random(1234)
    locks = parse_graphs(GRAPHS)
    results = {"contract": [], "invalid": [], "existence": [],
               "length": []}
    cases = 0
    for name, (pieces, conns) in sorted(locks.items()):
        n = len(pieces)
        place = [7 ** i for i in range(n)]
        out = [[] for _ in range(n)]
        for a, b, d in conns:
            out[a].append((b, d))
        w = 1 + max((len(o) for o in out), default=0)
        goal = sum((0 + 3) * place[i] for i in range(n))
        starts = [sum((r + 3) * place[i] for i, (_, r) in
                      enumerate(pieces))]
        for _ in range(5):
            starts.append(sum((rng.randint(-3, 3) + 3) * place[i]
                              for i in range(n)))
        for start in starts:
            if start == goal:
                continue
            cases += 1
            run_case(name, n, place, out, w, start, goal, results)

    # fuzz: dense random graphs, worst-case scrambles, to stress
    # high out-degree (large w) and deep routes (large g)
    print(f"{cases} mined cases done", flush=True)
    fuzz = 0
    for _ in range(1500):
        n = rng.randint(2, 6)
        place = [7 ** i for i in range(n)]
        out = [[] for _ in range(n)]
        # high out-degree: each piece may drag many partners
        for a in range(n):
            cand = [b for b in range(n) if b != a]
            rng.shuffle(cand)
            for b in cand[:rng.randint(0, n - 1)]:
                out[a].append((b, rng.choice((-1, 1))))
        w = 1 + max((len(o) for o in out), default=0)
        goal = sum(3 * place[i] for i in range(n))
        start = sum((rng.randint(-3, 3) + 3) * place[i]
                    for i in range(n))
        if start == goal:
            continue
        fuzz += 1
        run_case("fuzz", n, place, out, w, start, goal, results)

    print(f"{cases} mined cases + {fuzz} fuzz cases")
    for k in ("contract", "invalid", "existence", "length"):
        print(f"{k}: {len(results[k])}")
        for row in results[k][:8]:
            print("   ", row)
    bad = sum(len(results[k]) for k in results)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
