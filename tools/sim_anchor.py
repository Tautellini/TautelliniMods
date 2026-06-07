"""Anchor self-correction simulation for the LockpickSettings solver.

Validates the runtime anchor correction added to main.lua against the
verified game model (see solve_lock.py: rails -3..+3, open = all 0,
atomic drag moves, whole-move rejection, auto-open at the true goal).

The mod measures rotations RELATIVE to each other; the absolute anchor
(which column is the rail center) is unique only when the scramble
spans the full rail, else the most-centered pick is a guess. A wrong
guess means believed = true + e for a constant error e, which is the
whole simulation state besides the true rotations: steps are measured
absolutely, so a believed move (x, d) is the physical move (x, d) and
a re-anchor by k just sets e += k.

Two runs over every mined lock graph (lockgraphs.lua):
  A baseline (no corrections): reproduces the reported failures
    (pins uniformly one beside the center / hint frozen on a refused
    move / no plan).
  B corrections active (the main.lua evidence channels):
    E2 believed goal held while the lock stays shut -> disprove anchor
    E3 refused model-valid press                    -> disprove anchor
    E4 no believed route                            -> disprove (soft)
    every attempt must OPEN, and the true anchor must never be
    hard-convicted.

Scrambles are random reverse walks from the solved state, so every
attempt is solvable by construction. Deterministic (fixed seed).
Usage: python sim_anchor.py
"""
import random
import re
from collections import deque

LUA_GRAPHS = r"C:\dev\TautelliniMods\G1R\LockpickSettings\Scripts\lockgraphs.lua"
SEED = 0x10C4
ATTEMPTS_PER_LOCK = 6
BFS_CAP = 400_000
ACTION_CAP = 500


def parse_graphs(path):
    graphs = {}
    body = open(path, encoding="utf-8").read()
    for m in re.finditer(
            r'\["([^"]+)"\]\s*=\s*\{\s*pieces\s*=\s*\{(.*?)\}\s*,\s*'
            r'connections\s*=\s*\{(.*?)\}\s*\}', body, re.S):
        name, ps, cs = m.groups()
        pieces = [(int(a), int(b)) for a, b in
                  re.findall(r'\{id=(-?\d+),\s*rot=(-?\d+)\}', ps)]
        conns = [(int(a), int(b), int(d)) for a, b, d in
                 re.findall(r'\{a=(-?\d+),\s*b=(-?\d+),\s*dir=(-?\d+)\}', cs)]
        n = len(pieces)
        if n >= 2 and set(i for i, _ in pieces) == set(range(n)):
            edges = {}
            for a, b, d in conns:
                edges.setdefault(a, []).append((b, d))
            graphs[name] = {"n": n, "edges": edges}
    return graphs


def apply_move(state, x, d, edges):
    """Atomic move per the verified model; None = whole move rejected."""
    new = list(state)
    new[x] += d
    if abs(new[x]) > 3:
        return None
    for b, ed in edges.get(x, ()):
        new[b] += d * ed
        if abs(new[b]) > 3:
            return None
    return tuple(new)


def scramble(n, edges, rng):
    """Random reverse walk from the solved state: always solvable."""
    st = tuple([0] * n)
    for _ in range(rng.randrange(8, 40)):
        x, d = rng.randrange(n), rng.choice((1, -1))
        nxt = apply_move(st, x, d, edges)
        if nxt:
            st = nxt
    return st


def bfs_route(start, edges, n):
    """Shortest believed-frame route to all-zero; None if unreachable."""
    goal = tuple([0] * n)
    if start == goal:
        return []
    seen = {start: None}
    q = deque([start])
    while q:
        st = q.popleft()
        if len(seen) > BFS_CAP:
            return None
        for x in range(n):
            for d in (1, -1):
                nxt = apply_move(st, x, d, edges)
                if nxt is not None and nxt not in seen:
                    seen[nxt] = (st, x, d)
                    if nxt == goal:
                        route = []
                        cur = nxt
                        while seen[cur] is not None:
                            pre, mx, md = seen[cur]
                            route.append((mx, md))
                            cur = pre
                        route.reverse()
                        return route
                    q.append(nxt)
    return None


def centered_guess(true_rots):
    """The main.lua anchor pick: minimal spread, strict < keeps first k."""
    rel = [t - true_rots[0] for t in true_rots]  # any representative shape
    lo, hi = min(rel), max(rel)
    best_k, best_spread = None, 99
    for k in range(-3 - lo, 3 - hi + 1):
        spread = max(abs(lo + k), abs(hi + k))
        if spread < best_spread:
            best_spread, best_k = spread, k
    return [r + best_k for r in rel]


class Session:
    """The mod's anchor bookkeeping, distilled. believed = true + e."""

    def __init__(self, believed_start, true_start, n, edges):
        self.e = believed_start[0] - true_start[0]
        self.n, self.edges = n, edges
        self.obs_min = min(believed_start)
        self.obs_max = max(believed_start)
        self.anchor_shift = 0
        self.tried = {}
        self.exhausted = False
        self.true_anchor_hard_convicted = False

    def believed(self, true_state):
        return tuple(t + self.e for t in true_state)

    def merge(self, true_state):
        b = self.believed(true_state)
        self.obs_min = min(self.obs_min, min(b))
        self.obs_max = max(self.obs_max, max(b))

    def next_shift(self, accept=None):
        lo, hi = -3 - self.obs_min, 3 - self.obs_max
        for m in range(1, 7):
            for k in (m, -m):
                if lo <= k <= hi and (self.anchor_shift + k) not in self.tried \
                        and (accept is None or accept(k)):
                    return k
        return None

    def disprove(self, true_state, accept=None, soft=False):
        if self.e == 0 and not soft:
            self.true_anchor_hard_convicted = True  # invariant breach
        self.tried[self.anchor_shift] = "soft" if soft else True
        k = self.next_shift(accept)
        if k is None and accept is not None:
            k = self.next_shift(None)
        if k is None:
            self.exhausted = True
            return False
        self.e += k
        self.anchor_shift += k
        self.obs_min += k
        self.obs_max += k
        return True

    def shift_explains_refusal(self, true_state, x, d):
        """acceptFn: in the shifted frame the move leaves the rail."""
        b = self.believed(true_state)

        def accept(k):
            if abs(b[x] + k + d) > 3:
                return True
            for p, ed in self.edges.get(x, ()):
                if abs(b[p] + k + d * ed) > 3:
                    return True
            return False
        return accept


def run_attempt(n, edges, rng, corrections):
    true = scramble(n, edges, rng)
    goal = tuple([0] * n)
    if true == goal:
        return {"outcome": "open", "rounds": 0, "actions": 0, "breach": False}
    sess = Session(centered_guess(true), true, n, edges)
    route, rounds, actions = None, 0, 0
    while actions < ACTION_CAP:
        if true == goal:
            return {"outcome": "open", "rounds": rounds, "actions": actions,
                    "breach": sess.true_anchor_hard_convicted}
        b = sess.believed(true)
        assert max(abs(v) for v in b) <= 3, "base-7 digit invariant breached"
        if b == goal:
            # believed goal, lock shut: E2 after the grace
            if not corrections:
                return {"outcome": "uniform-off", "rounds": rounds,
                        "actions": actions, "breach": False}
            actions += 1  # the ~2s grace
            if not sess.disprove(true):
                return {"outcome": "exhausted", "rounds": rounds,
                        "actions": actions,
                        "breach": sess.true_anchor_hard_convicted}
            rounds += 1
            route = None
            continue
        if not route:
            route = bfs_route(b, edges, n)
            if route is None:
                if not corrections:
                    return {"outcome": "no-plan", "rounds": rounds,
                            "actions": actions, "breach": False}
                if not sess.disprove(true, soft=True):
                    return {"outcome": "exhausted", "rounds": rounds,
                            "actions": actions,
                            "breach": sess.true_anchor_hard_convicted}
                rounds += 1
                continue
        x, d = route[0]
        nxt = apply_move(true, x, d, edges)
        actions += 1
        if nxt is None:
            # refused model-valid press: E3 (the route made it model-valid)
            if not corrections:
                return {"outcome": "frozen-hint", "rounds": rounds,
                        "actions": actions, "breach": False}
            if not sess.disprove(true, accept=sess.shift_explains_refusal(
                    true, x, d)):
                return {"outcome": "exhausted", "rounds": rounds,
                        "actions": actions,
                        "breach": sess.true_anchor_hard_convicted}
            rounds += 1
            route = None
            continue
        true = nxt
        route = route[1:]
        sess.merge(true)
    return {"outcome": "action-cap", "rounds": rounds, "actions": actions,
            "breach": sess.true_anchor_hard_convicted}


def run(graphs, corrections, label):
    rng = random.Random(SEED)
    stats, rounds_hist, breaches, max_actions = {}, {}, 0, 0
    total = 0
    for name in sorted(graphs):
        g = graphs[name]
        for _ in range(ATTEMPTS_PER_LOCK):
            r = run_attempt(g["n"], g["edges"], rng, corrections)
            total += 1
            stats[r["outcome"]] = stats.get(r["outcome"], 0) + 1
            if r["outcome"] == "open":
                rounds_hist[r["rounds"]] = rounds_hist.get(r["rounds"], 0) + 1
                max_actions = max(max_actions, r["actions"])
            if r["breach"]:
                breaches += 1
    print("=" * 64)
    print(label)
    print("-" * 64)
    print(f"  attempts: {total}")
    for k in sorted(stats):
        print(f"  {k:<14}: {stats[k]:5d} ({100.0 * stats[k] / total:.1f}%)")
    print(f"  true anchor hard-convicted (must be 0): {breaches}")
    if corrections:
        print(f"  max player actions of any opened attempt: {max_actions}")
        print("  correction rounds among opened attempts:")
        opened = max(1, stats.get("open", 0))
        for k in sorted(rounds_hist):
            print(f"    {k}: {rounds_hist[k]} "
                  f"({100.0 * rounds_hist[k] / opened:.1f}%)")
    print()


def main():
    graphs = parse_graphs(LUA_GRAPHS)
    print(f"locks: {len(graphs)}, attempts per lock: {ATTEMPTS_PER_LOCK}\n")
    run(graphs, corrections=False,
        label="A: BASELINE (2.5 behavior, centered guess only)")
    run(graphs, corrections=True,
        label="B: CORRECTIONS ACTIVE (2.6 anchor evidence loop)")


if __name__ == "__main__":
    main()
