#!/usr/bin/env python3
"""Lane F1: verify godot/data/stars.json against godot/data/levels.json.

Independent proof per star (re-derives everything from the level data):
1. One star per level, L001..L215, in bounds, y >= 110 (HUD clear).
2. Star is not inside any solid platform and not overlapping the door.
3. Reachability, by method:
   - detour: the platform under the star is reachable from spawn in
     the platform graph (all standable kinds, moving = swept range,
     rise <= 50, gap <= 95) AND is not on any shortest spawn->door path.
   - spike_apex / column_apex / gap_jump / spawn_jump: a discrete
     60 Hz jump simulation (run 243 px/s, gravity 3110, jump vel -570,
     semi-implicit Euler exactly as the runtime integrates) from a
     legal takeoff proves the hero rect overlaps the star circle
     (r=14) at some frame, while the takeoff platform is itself
     reachable in the graph.
4. Safety: >= 25px clearance from every hazard except the one the
   star belongs to (spike_apex/column_apex), >= 40px from the door.
Exit 0 only if all 215 stars prove reachable + safe.
"""
import json, math, sys
from collections import deque
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
LEVELS = REPO / "godot" / "data" / "levels.json"
STARS = REPO / "godot" / "data" / "stars.json"

RISE, GAP = 50.0, 95.0
GRAV, JVEL, SPEED, DT = 3110.0, -570.0, 243.0, 1.0 / 60.0
HERO_W, HERO_H, STAR_R = 15.0, 39.0, 14.0


def eff_rect(p):
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
    return hgap(a, b) <= GAP and eff_rect(a)["y"] - eff_rect(b)["y"] <= RISE


def platform_at(lv, x, y):
    for p in lv["platforms"]:
        if abs(p["y"] - y) <= 4 and p["x"] <= x <= p["x"] + p["w"]:
            return p
    return None


def bfs(start, plats):
    dist, prev = {id(start): 0}, {}
    q = deque([start])
    while q:
        cur = q.popleft()
        for p in plats:
            if id(p) not in dist and can_jump(cur, p):
                dist[id(p)] = dist[id(cur)] + 1
                prev[id(p)] = cur
                q.append(p)
    return dist, prev


def on_shortest_path(lv, plats, spawn_p, door_p):
    d_from, _ = bfs(spawn_p, plats)
    rev = {id(p): [] for p in plats}
    for a in plats:
        for b in plats:
            if a is not b and can_jump(a, b):
                rev[id(b)].append(a)
    d_door, q = {id(door_p): 0}, deque([door_p])
    while q:
        cur = q.popleft()
        for a in rev[id(cur)]:
            if id(a) not in d_door:
                d_door[id(a)] = d_door[id(cur)] + 1
                q.append(a)
    total = d_from.get(id(door_p))
    if total is None:
        return set(), d_from, total
    return {id(p) for p in plats if id(p) in d_from and id(p) in d_door
            and d_from[id(p)] + d_door[id(p)] == total}, d_from, total


def circle_rect(cx, cy, r, rx, ry, rw, rh):
    dx = max(rx - cx, 0.0, cx - (rx + rw))
    dy = max(ry - cy, 0.0, cy - (ry + rh))
    return math.hypot(dx, dy) <= r


def jump_collects(x0, feet_y0, direction, star, frames=40):
    """Simulate a run + one jump from (x0, feet_y0); True if the hero
    rect ever overlaps the star circle. Takeoff is immediate (frame 0)
    — the most conservative apex (no extra run-up height)."""
    x, feet, vy = float(x0), float(feet_y0), JVEL
    for _ in range(frames):
        vy = min(vy + GRAV * DT, 600.0)
        feet += vy * DT
        x += direction * SPEED * DT
        if feet > feet_y0:  # landed back on the takeoff level
            break
        if circle_rect(star["x"], star["y"], STAR_R,
                       x - HERO_W / 2, feet - HERO_H, HERO_W, HERO_H):
            return True
    return False


def hazard_dist(lv, x, y, skip=None):
    worst = 1e9
    for i, h in enumerate(lv["hazards"]):
        if skip is not None and i == skip:
            continue
        if h["type"] == "saw":
            centres = [(h["x"], h["y"])]
            if "path" in h:
                centres.append((h["path"]["x2"], h["path"]["y2"]))
            for cx, cy in centres:
                worst = min(worst, math.hypot(x - cx, y - cy) - h["r"])
        else:
            dx = max(h["x"] - x, 0.0, x - (h["x"] + h["w"]))
            dy = max(h["y"] - y, 0.0, y - (h["y"] + h["h"]))
            worst = min(worst, math.hypot(dx, dy))
    return worst


def verify_level(lv, star):
    errs, notes = [], []
    lid = lv["id"]
    sx, sy = star["x"], star["y"]
    if not (0 <= sx <= 1280 and 110 <= sy <= 720):
        errs.append("star out of bounds / HUD band")
    for p in lv["platforms"]:
        if p["x"] <= sx <= p["x"] + p["w"] and p["y"] <= sy <= p["y"] + p["h"]:
            errs.append("star inside a platform rect")
    dx = max(lv["door"]["x"] - 18 - sx, 0.0, sx - (lv["door"]["x"] + 18))
    dy = max(lv["door"]["y"] - 54 - sy, 0.0, sy - lv["door"]["y"])
    if math.hypot(dx, dy) < 40:
        errs.append("star within 40px of the door")
    plats = lv["platforms"]
    spawn_p = platform_at(lv, lv["spawn"]["x"], lv["spawn"]["y"])
    door_p = platform_at(lv, lv["door"]["x"], lv["door"]["y"])
    if spawn_p is None or door_p is None:
        return ["no spawn/door platform"], notes
    on_path, d_from, total = on_shortest_path(lv, plats, spawn_p, door_p)
    if total is None:
        return ["door unreachable in graph"], notes
    method = star.get("method", "?")
    if method == "detour":
        # Platform directly under the star: the one whose top is
        # exactly 24px below the star (generator places top-24).
        under = None
        best_gap = 1e9
        for p in plats:
            if p["kind"] == "solid" and p["x"] <= sx <= p["x"] + p["w"]:
                gap = abs((p["y"] - sy) - 24)
                if gap < best_gap:
                    best_gap, under = gap, p
        if under is None or best_gap > 2:
            errs.append("detour: no solid platform exactly under the star")
            under = None
        if under is None:
            errs.append("detour: no solid platform under the star")
        else:
            if id(under) not in d_from:
                errs.append("detour: star platform unreachable from spawn")
            if id(under) in on_path:
                errs.append("detour: star platform is ON the shortest path")
            # Standing collect: hero rect on the platform overlaps star.
            if not circle_rect(sx, sy, STAR_R, sx - HERO_W / 2,
                               under["y"] - HERO_H, HERO_W, HERO_H):
                errs.append("detour: star not collectible standing on platform")
        if hazard_dist(lv, sx, sy) < 40:
            errs.append("detour: star < 40px from a hazard")
    elif method in ("spike_apex", "column_apex"):
        # Find the hazard the star belongs to; prove the jump from the
        # floor on either side overlaps the star; other hazards >= 25px.
        hit = None
        for i, h in enumerate(lv["hazards"]):
            want = "spikes" if method == "spike_apex" else "spiked_column"
            if h["type"] != want:
                continue
            if abs((h["x"] + h["w"] / 2) - sx) <= 2 and h["y"] - sy in range(40, 75):
                hit = (i, h)
                break
        if hit is None:
            errs.append("%s: no matching hazard under the star" % method)
        else:
            i, h = hit
            floor_top = h["y"] + h["h"]
            seat = platform_at(lv, sx, floor_top)
            if seat is None or id(seat) not in d_from:
                errs.append("%s: seat platform unreachable" % method)
            else:
                ok = False
                for direction, tx in ((1, h["x"] - 8), (-1, h["x"] + h["w"] + 8)):
                    if jump_collects(tx, floor_top, direction, star):
                        ok = True
                if not ok:
                    errs.append("%s: jump sim never overlaps the star" % method)
            if hazard_dist(lv, sx, sy, skip=i) < 25:
                errs.append("%s: star < 25px from another hazard" % method)
    elif method == "gap_jump":
        # Takeoff from either side of the gap at the lower top.
        ok = False
        for p in plats:
            if id(p) in d_from and abs(p["y"] - (sy + 45)) <= 4:
                for direction, tx in ((1, p["x"] + p["w"] - 4), (-1, p["x"] + 4)):
                    if jump_collects(tx, p["y"], direction, star):
                        ok = True
        if not ok:
            errs.append("gap_jump: jump sim never overlaps the star")
        if hazard_dist(lv, sx, sy) < 25:
            errs.append("gap_jump: star < 25px from a hazard")
    elif method == "spawn_jump":
        if not jump_collects(lv["spawn"]["x"] + 30, spawn_p["y"], 1, star) \
                and not jump_collects(lv["spawn"]["x"] - 30, spawn_p["y"], -1, star):
            errs.append("spawn_jump: jump sim never overlaps the star")
        if hazard_dist(lv, sx, sy) < 40:
            errs.append("spawn_jump: star < 40px from a hazard")
        notes.append("weakest hiding spot (flat level, no jumpable hazard)")
    else:
        errs.append("unknown method %r" % method)
    return errs, notes


def main():
    levels = {l["id"]: l for l in json.loads(LEVELS.read_text())["levels"]}
    stars = json.loads(STARS.read_text())
    bad, weak, methods = [], [], {}
    for lid in sorted(levels):
        if lid not in stars:
            bad.append((lid, ["missing star"]))
            continue
        errs, notes = verify_level(levels[lid], stars[lid])
        methods[stars[lid].get("method")] = methods.get(stars[lid].get("method"), 0) + 1
        if errs:
            bad.append((lid, errs))
        if notes:
            weak.append(lid)
    print("stars verified: %d/%d reachable+safe  methods=%s" %
          (len(levels) - len(bad), len(levels), methods))
    print("weakest (spawn_jump, honest): %s" % weak)
    for lid, errs in bad:
        print("  FAIL %s: %s" % (lid, "; ".join(errs)))
    # Bonus levels (separate file) use the same proof, reported apart.
    bonus_path = REPO / "godot" / "data" / "bonus_levels.json"
    if bonus_path.exists():
        blevels = {l["id"]: l for l in json.loads(bonus_path.read_text())["levels"]}
        bbad = []
        for lid in sorted(blevels):
            if lid not in stars:
                bbad.append((lid, ["missing star"]))
                continue
            errs, _notes = verify_level(blevels[lid], stars[lid])
            if errs:
                bbad.append((lid, errs))
        print("bonus stars verified: %d/%d reachable+safe" %
              (len(blevels) - len(bbad), len(blevels)))
        for lid, errs in bbad:
            print("  BONUS FAIL %s: %s" % (lid, "; ".join(errs)))
            bad.append((lid, errs))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
