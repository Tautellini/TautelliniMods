"""Offline lock solver for Gothic 1 Remake lock graphs.

Model (verified in-game, see G1R/LuaModdingSurface.md):
  * rails span rotations -3..+3, open = 0, pieces FREEZE at 0
  * moving piece x by d (+-1) drags its direct out-edge partners by
    d*dir; frozen or clamped partners stay put
  * the game may remove ~LockpickPrecision connections at runtime, so
    also report solvability with each single edge removed

Usage: python solve_lock.py  (lock data is inlined below)
"""
from collections import deque

PIECES = {0: -3, 1: 0, 2: -1, 3: -3, 4: 1}
EDGES = [
    (0, 2, 1), (0, 1, 1), (3, 1, 1), (4, 3, -1), (0, 3, 1),
    (2, 1, -1), (1, 3, 1), (1, 4, 1), (3, 0, 1), (3, 4, -1),
]


def solve(pieces, edges, max_states=3_000_000):
    ids = sorted(pieces)
    out = {}
    for a, b, d in edges:
        out.setdefault(a, []).append((b, d))
    start = tuple(pieces[i] for i in ids)
    goal = tuple(0 for _ in ids)
    if start == goal:
        return []
    seen = {start}
    q = deque([(start, [])])
    while q:
        st, path = q.popleft()
        if len(seen) > max_states:
            return None
        for xi, x in enumerate(ids):
            if st[xi] == 0:
                continue  # frozen at center
            for d in (1, -1):
                nx = st[xi] + d
                if abs(nx) > 3:
                    continue
                nst = list(st)
                nst[xi] = nx
                dragged = []
                for b, ed in out.get(x, ()):  # direct partners
                    bi = ids.index(b)
                    if nst[bi] == 0:
                        continue  # frozen partner stays
                    nb = nst[bi] + d * ed
                    if abs(nb) <= 3:
                        nst[bi] = nb
                        dragged.append(b)
                t = tuple(nst)
                if t in seen:
                    continue
                seen.add(t)
                npath = path + [(x, d, tuple(dragged), t)]
                if t == goal:
                    return npath
                q.append((nst, npath))
    return None


def describe(path):
    ids = sorted(PIECES)
    if path is None:
        return "  UNSOLVABLE under the model"
    if not path:
        return "  already solved"
    lines = []
    cur = {i: PIECES[i] for i in ids}
    for n, (x, d, dragged, t) in enumerate(path, 1):
        before = cur[x]
        after = before + d
        direction = "toward the middle" if abs(after) < abs(before) else "away from the middle"
        drag = ""
        if dragged:
            drag = "  (drags row " + ", ".join(str(b + 1) for b in dragged) + ")"
        lines.append(f"  {n:2d}. row {x + 1}: position {before + 4} -> {after + 4} ({direction}){drag}")
        for i, v in zip(ids, t):
            cur[i] = v
    return "\n".join(lines)


print("=== full mined graph ===")
sol = solve(PIECES, EDGES)
print(describe(sol))
print(f"  ({len(sol)} moves)" if sol else "")

print()
print("=== robustness: one edge removed (precision mechanic) ===")
for k in range(len(EDGES)):
    sub = EDGES[:k] + EDGES[k + 1:]
    s = solve(PIECES, sub)
    a, b, d = EDGES[k]
    status = f"solvable in {len(s)}" if s is not None else "UNSOLVABLE"
    print(f"  without {a}->{b} (dir {d:+d}): {status}")
