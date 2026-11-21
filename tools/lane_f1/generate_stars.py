#!/usr/bin/env python3
"""Lane F1: generate godot/data/stars.json — one hidden star per level.

Placement rules (proof in tools/lane_f1/verify_stars.py):
- Star sits on a SOLID platform reachable from spawn through the
  platform graph built from ALL standable platforms (solid, falling,
  dashed, moving — a falling floor holds >= 0.45s, a dashed floor
  >= 0.9s per cycle, long enough to jump off) under the REAL jump
  envelope: rise <= 50px (discrete-sim apex ~54px), horizontal gap
  <= 95px (air distance ~97px).
- Preferred: the platform is NOT on any shortest spawn->door path —
  the star is a detour, never a freebie on the main route.
- Star centre = platform top - 24px, inset >= 20px from the edges,
  y >= 110 (clear of the HUD band), >= 40px from any hazard and
  >= 40px from the door rect and the spawn point.
- Fallback 1 (no off-path platform): spike-apex star — above a spike
  strip on the main route at jump-apex height (floor top - 71px), so
  collecting it means jumping OVER the spikes and grabbing it at the
  apex. The risk is the jump itself.
- Fallback 2: mid-gap air star over a jump on the shortest path
  (gap midpoint, lower takeoff top - 45px), collected at jump apex.
- Fallback 3 (last resort): jump star above the spawn platform
  (top - 71px, away from spawn x) — still a jump, but the weakest
  hiding spot; reported as such, never silently upgraded.
- NEVER touches levels.json / generate_levels.py / tuning.json.
"""
import json, math, sys
from collections import deque
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
LEVELS = REPO / "godot" / "data" / "levels.json"
OUT = REPO / "godot" / "data" / "stars.json"

RISE = 50.0    # real jump apex ~54px (discrete sim); 50 is conservative
GAP = 95.0     # real air distance ~97px; 95 is conservative
STAR_R = 14.0
HAZARD_CLEAR = 40.0
EDGE_INSET = 20.0


def eff_rect(p):
    """Effective standing rect: for moving platforms the swept union of
    home and end positions (the hero can wait for it to arrive)."""
    if p.get("kind") == "moving":
        x1 = min(p["x"], p["x"] + p.get("dx", 0))
        x2 = max(p["x"] + p["w"], p["x"] + p.get("dx", 0) + p["w"])
        y1 = min(p["y"], p["y"] + p.get("dy", 0))
        y2 = max(p["y"] + p["h"], p["y"] + p.get("dy", 0) + p["h"])
        return {"x": x1, "y": y1, "w": x2 - x1, "h": y2 - y1}
    return p


def hgap(a, b):
    a, b = eff_rect(a), eff_rect(b)
    return max(0.0, max(a["x"], b["x"]) - min(a["x"] + a["w"], b["x"] + b["w"]))


def can_jump(a, b):
    if hgap(a, b) > GAP:
        return False
    if eff_rect(a)["y"] - eff_rect(b)["y"] > RISE:  # B higher than A
        return False
    return True


def platform_at(lv, x, y):
    for p in lv["platforms"]:
        if abs(p["y"] - y) <= 4 and p["x"] <= x <= p["x"] + p["w"]:
            return p
    return None


def bfs(start, plats):
    dist = {id(start): 0}
    prev = {}
    q = deque([start])
    while q:
        cur = q.popleft()
        for p in plats:
            if id(p) in dist:
                continue
            if can_jump(cur, p):
                dist[id(p)] = dist[id(cur)] + 1
                prev[id(p)] = cur
                q.append(p)
    return dist, prev


def shortest_path_nodes(lv, plats, spawn_p, door_p):
    """Platforms lying on SOME shortest spawn->door path (reverse BFS)."""
    d_from, prev = bfs(spawn_p, plats)
    rev = {id(p): [] for p in plats}
    for a in plats:
        for b in plats:
            if a is not b and can_jump(a, b):
                rev[id(b)].append(a)
    d_door = {id(door_p): 0}
    q = deque([door_p])
    while q:
        cur = q.popleft()
        for a in rev[id(cur)]:
            if id(a) not in d_door:
                d_door[id(a)] = d_door[id(cur)] + 1
                q.append(a)
    total = d_from.get(id(door_p))
    if total is None:
        return set(), d_from, prev, total
    on_path = {id(p) for p in plats
               if id(p) in d_from and id(p) in d_door
               and d_from[id(p)] + d_door[id(p)] == total}
    return on_path, d_from, prev, total


def hazard_clearance(lv, x, y):
    worst = 1e9
    for h in lv["hazards"]:
        t = h["type"]
        if t == "saw":
            centres = [(h["x"], h["y"])]
            if "path" in h:
                centres.append((h["path"]["x2"], h["path"]["y2"]))
            if "swing" in h:
                sw = h["swing"]
                px, py = sw["pivot_x"], sw["pivot_y"]
                base = math.atan2(h["y"] - py, h["x"] - px)
                half = math.radians(sw["arc_deg"]) / 2
                rad = math.hypot(h["x"] - px, h["y"] - py)
                for k in range(7):
                    ang = base - half + 2 * half * k / 6
                    centres.append((px + rad * math.cos(ang), py + rad * math.sin(ang)))
            for cx, cy in centres:
                worst = min(worst, math.hypot(x - cx, y - cy) - h["r"])
        else:
            dx = max(h["x"] - x, 0.0, x - (h["x"] + h["w"]))
            dy = max(h["y"] - y, 0.0, y - (h["y"] + h["h"]))
            worst = min(worst, math.hypot(dx, dy))
    return worst


def _door_clear(lv, x, y, dist=40):
    dx = max(lv["door"]["x"] - 18 - x, 0.0, x - (lv["door"]["x"] + 18))
    dy = max(lv["door"]["y"] - 54 - y, 0.0, y - lv["door"]["y"])
    return math.hypot(dx, dy) >= dist


def pick_star(lv):
    plats = lv["platforms"]
    spawn_p = platform_at(lv, lv["spawn"]["x"], lv["spawn"]["y"])
    door_p = platform_at(lv, lv["door"]["x"], lv["door"]["y"])
    if spawn_p is None or door_p is None:
        return None, "no spawn/door platform"
    on_path, d_from, prev, total = shortest_path_nodes(lv, plats, spawn_p, door_p)
    if total is None:
        return None, "door unreachable in platform graph"

    # --- Preferred: detour onto a solid platform off the shortest path.
    best = None
    for p in plats:
        if p["kind"] != "solid":
            continue
        if id(p) not in d_from or id(p) in on_path:
            continue
        top = p["y"]
        if top < 134 or p["w"] < 2 * EDGE_INSET + 16:
            continue
        for sx in (p["x"] + EDGE_INSET + 8, p["x"] + p["w"] - EDGE_INSET - 8,
                   p["x"] + p["w"] / 2):
            sy = top - 24
            # The point must be in open air: not inside ANY platform rect
            # (a tall wall/beam elsewhere can overlap this spot).
            if any(q["x"] <= sx <= q["x"] + q["w"] and q["y"] <= sy <= q["y"] + q["h"]
                   for q in plats):
                continue
            # Unique standing platform: exactly one solid platform may
            # have its top 24px below the star at this x — otherwise
            # the spot is ambiguous (two surfaces share the top).
            tops = [q for q in plats if q["kind"] == "solid"
                    and q["x"] <= sx <= q["x"] + q["w"]
                    and abs(q["y"] - (sy + 24)) <= 2]
            if len(tops) != 1 or tops[0] is not p:
                continue
            if hazard_clearance(lv, sx, sy) < HAZARD_CLEAR:
                continue
            if math.hypot(sx - lv["spawn"]["x"], sy - lv["spawn"]["y"]) < 40:
                continue
            if not _door_clear(lv, sx, sy):
                continue
            detour = d_from[id(p)] + 1
            risk = hazard_clearance(lv, p["x"] + p["w"] / 2, top - 10)
            score = detour * 1000 + (720 - top) - risk
            if best is None or score > best[0]:
                best = (score, sx, sy)
    if best is not None:
        return {"x": round(best[1]), "y": round(best[2]), "method": "detour"}, None

    # --- Fallback 1: spike-apex star over a spike strip on the route.
    # Star at apex height above the floor the spikes sit on: the hero
    # jumps the spikes anyway; the star is grabbed at the apex.
    for h in lv["hazards"]:
        if h["type"] != "spikes" or h.get("dir", "up") != "up":
            continue
        # Floor top under the spikes: hazard y + h is the seat.
        floor_top = h["y"] + h["h"]
        sx = h["x"] + h["w"] / 2
        sy = floor_top - 71
        if sy < 110:
            continue
        if hazard_clearance(lv, sx, sy) < 30:  # star itself must be safe
            continue
        if not _door_clear(lv, sx, sy):
            continue
        # The spike strip must sit on a platform the hero actually
        # crosses (on-path platform top == floor_top).
        seat = [p for p in plats if abs(p["y"] - floor_top) <= 4
                and p["x"] <= sx <= p["x"] + p["w"]]
        if not seat:
            continue
        return {"x": round(sx), "y": round(sy), "method": "spike_apex"}, None

    # --- Fallback 1b: column-apex star over a spiked column on the route.
    # The hero must jump the column anyway; the star is grabbed at the
    # apex of that jump, 44px above the column top (safe clearance).
    for h in lv["hazards"]:
        if h["type"] != "spiked_column":
            continue
        sx = h["x"] + h["w"] / 2
        sy = h["y"] - 44
        if sy < 110:
            continue
        if hazard_clearance(lv, sx, sy) < 30:
            continue
        if not _door_clear(lv, sx, sy):
            continue
        seat = [p for p in plats if abs(p["y"] - (h["y"] + h["h"])) <= 4
                and p["x"] <= sx <= p["x"] + p["w"]]
        if not seat:
            continue
        return {"x": round(sx), "y": round(sy), "method": "column_apex"}, None

    # --- Fallback 2: mid-gap air star over a jump on the shortest path.
    path = []
    cur, guard = door_p, 0
    while cur is not None and guard < 500:
        path.append(cur)
        guard += 1
        cur = prev.get(id(cur))
    path.reverse()
    for a, b in zip(path, path[1:]):
        g = hgap(a, b)
        if g < 25 or g > GAP:
            continue
        if a["x"] + a["w"] <= b["x"]:
            mx = (a["x"] + a["w"] + b["x"]) / 2
        elif b["x"] + b["w"] <= a["x"]:
            mx = (b["x"] + b["w"] + a["x"]) / 2
        else:
            continue
        my = min(a["y"], b["y"]) - 45
        if my < 110 or hazard_clearance(lv, mx, my) < HAZARD_CLEAR:
            continue
        if not _door_clear(lv, mx, my):
            continue
        return {"x": round(mx), "y": round(my), "method": "gap_jump"}, None

    # --- Fallback 3 (weakest, reported): jump star above spawn platform.
    top = spawn_p["y"]
    for sx in (spawn_p["x"] + 120, spawn_p["x"] - 120,
               spawn_p["x"] + spawn_p["w"] / 2):
        if not (spawn_p["x"] + 16 <= sx <= spawn_p["x"] + spawn_p["w"] - 16):
            continue
        sy = top - 71
        if sy < 110:
            continue
        if hazard_clearance(lv, sx, sy) < HAZARD_CLEAR:
            continue
        if math.hypot(sx - lv["spawn"]["x"], sy - lv["spawn"]["y"]) < 40:
            continue
        return {"x": round(sx), "y": round(sy), "method": "spawn_jump"}, None
    return None, "no detour / spike-apex / gap / spawn-jump spot"


def main():
    data = json.loads(LEVELS.read_text())
    out, problems, methods = {}, [], {}
    for lv in data["levels"]:
        star, err = pick_star(lv)
        if star is None:
            problems.append((lv["id"], err))
        else:
            out[lv["id"]] = star
            methods[star["method"]] = methods.get(star["method"], 0) + 1
    OUT.write_text(json.dumps(out, indent=1, sort_keys=True) + "\n")
    print("stars: %d  methods=%s  problems=%d" % (len(out), methods, len(problems)))
    for lid, err in problems:
        print("  PROBLEM %s: %s" % (lid, err))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
