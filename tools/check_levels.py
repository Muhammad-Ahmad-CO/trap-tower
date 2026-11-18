#!/usr/bin/env python3
"""Trap Tower static level verifier (Lane B).

Implements LEVEL_SCHEMA.md v2 (FROZEN) exactly. Loads
godot/data/levels.json + godot/data/tuning.json and checks:

  (a) schema/tuning versions, required fields, unknown kind/type = hard error
  (b) geometry bounds (0..1280 / 0..580), platform w/h minima
  (c) spawn/door safe zones (40px) + standing on solid ground
  (d) platform-graph reachability from spawn to door using the FROZEN
      harness envelope from tuning.json (rise/gap/landing/run-up),
      with per-edge reasoning; conservative pre-filter only. PLUS
      connectivity: flood-fill of empty space (8px grid, 4-connected)
      from spawn to door with solid platforms as walls -- the graph
      alone cannot see solid walls sealing a route.
  (e) timed hazards on a viable path leave a safe window >= 0.7s
      (from declarative params; saw paths as swept volumes; falling
      floors must be crossable within stand_time)
  (f) DISTINCTNESS: canonical signature EXCLUDING palette; two levels
      are distinct only if signatures differ AND >= 2 of {layout
      geometry, trap set/params, solution path} differ; every
      duplicate cluster is reported.
  (g) GROUNDING (rule 7): no floating geometry -- solid fixpoint,
      shaft-flanked/resting specials, seated spikes, saw disc touch
      over the full sweep, swing pivots inside grounded beams.
      Rect hazards (spikes, spiked_column) must not area-overlap
      solid rects beyond the 4px seating tolerance (saws,
      hanging_pillar, dotted_line exempt).
  (h) HUD KEEP-OUT (rule 8): no drawn extent in y < 90; spawn feet
      y >= 134; door base y >= 174.
  (i) DENSITY FLOOR (rule 9): >= 2 solid rects in the middle band
      y 150..450 with combined width >= 160px, PLUS a core-middle
      floor: excluding edge-touching rects, >= 2 rects (solid
      platforms AND/OR decorations, counted together)
      intersecting y 260..420 with combined width >= 160px.
  (j) DECORATIONS (rule 10): the optional `decorations` array, if
      present, must satisfy the attachment chain, HUD keep-out,
      no-hazard/spawn/door-overlap, and bounds rules (error prefix
      `deco:`). Decorations are ignored by reachability,
      connectivity, and dedupe signatures.

Physics/envelope/viewport/door/palette numbers are ALWAYS loaded from
tuning.json -- never duplicated here by hand. The only numeric
constants in this file come from LEVEL_SCHEMA.md itself (safe zone
40px, ground tolerance 4px, platform h >= 16, saw radius 26..60,
timing minima), each cited where defined.

Exit codes: 0 = all levels pass; 1 = one or more levels fail;
2 = usage / unreadable input / top-level structural failure.

Usage:
  python3 tools/check_levels.py [--levels PATH] [--tuning PATH]
                                [--json-out PATH] [--quiet]
                                [--density-report]
  python3 tools/check_levels.py --selftest   # fixture expectations
"""

import argparse
import hashlib
import json
import math
import sys
from collections import Counter, deque
from pathlib import Path

# --- Constants from LEVEL_SCHEMA.md (not in tuning.json) -------------------
SCHEMA_VERSION = 2          # LEVEL_SCHEMA.md: top-level schema_version
SAFE_ZONE = 40.0            # LEVEL_SCHEMA.md: spawn/door safe zone, px
GROUND_TOL = 4.0            # LEVEL_SCHEMA.md: platform top within 4px
HUD_KEEPOUT_Y = 90.0        # LEVEL_SCHEMA.md rule 8: no drawn extent y < 90
SPAWN_MIN_Y = 134.0         # LEVEL_SCHEMA.md rule 8: spawn feet y >= 134
DOOR_MIN_Y = 174.0          # LEVEL_SCHEMA.md rule 8: door base y >= 174
MIN_PILLAR_W = 48.0         # LEVEL_SCHEMA.md rule 7: pillar w >= 48
SHAFT_FLANK_GAP = 8.0       # LEVEL_SCHEMA.md rule 7: shaft columns <= 8px
DENSITY_BAND_TOP = 150.0    # LEVEL_SCHEMA.md rule 9: middle band y 150..450
DENSITY_BAND_BOTTOM = 450.0
DENSITY_MIN_RECTS = 2       # LEVEL_SCHEMA.md rule 9: >= 2 solid rects
DENSITY_MIN_WIDTH = 160.0   # LEVEL_SCHEMA.md rule 9: combined width >= 160
CORE_BAND_TOP = 260.0       # LEVEL_SCHEMA.md rule 9: core-middle y 260..420
CORE_BAND_BOTTOM = 420.0
CORE_MIN_RECTS = 2          # LEVEL_SCHEMA.md rule 9: >= 2 non-edge rects
CORE_MIN_WIDTH = 160.0      # LEVEL_SCHEMA.md rule 9: combined width >= 160
OVERLAP_TOL = 4.0           # LEVEL_SCHEMA.md rule 7: seating tolerance
DECO_MIN_W = 48.0           # LEVEL_SCHEMA.md Decorations: w >= 48
DECO_MIN_H = 16.0           # LEVEL_SCHEMA.md Decorations: h >= 16
DECO_ATTACH_TOL = 4.0       # LEVEL_SCHEMA.md rule 10: edge-adjacent
                            # within 4px counts as attached
MIN_PLATFORM_H = 16.0       # LEVEL_SCHEMA.md: platform h >= 16
SAW_R_MIN, SAW_R_MAX = 26.0, 60.0   # LEVEL_SCHEMA.md: saw r 26..60
DASHED_MIN_ON = 0.9         # LEVEL_SCHEMA.md: dashed on_time >= 0.9
DASHED_MIN_OFF = 0.5        # LEVEL_SCHEMA.md: period - on_time >= 0.5
FALL_MIN_STAND = 0.45       # LEVEL_SCHEMA.md: falling/tilting stand_time
MOVING_MIN_PERIOD = 1.6     # LEVEL_SCHEMA.md: moving/saw period >= 1.6
MIN_DELAY = 0.25            # LEVEL_SCHEMA.md: trigger delay >= 0.25
PILLAR_RISE_TIME = 1.0      # LEVEL_SCHEMA.md: periodic pillar rises over 1.0s
DEFAULT_DROP_SPEED = 700.0  # LEVEL_SCHEMA.md: drop_speed default 700 px/s
CONNECTIVITY_CELL = 8.0     # LEVEL_SCHEMA.md rule 5: 8px flood-fill grid
HERO_RECT_W = 24.0          # LEVEL_SCHEMA.md rule 5: hero rect at spawn
HERO_RECT_H = 44.0          # LEVEL_SCHEMA.md rule 5: hero rect at spawn

PLATFORM_KINDS = {"solid", "dashed", "falling", "tilting", "moving"}
HAZARD_TYPES = {"spikes", "saw", "spiked_column", "hanging_pillar",
                "dotted_line"}
SPIKE_DIRS = {"up", "down", "left", "right"}
LEVEL_FIELDS = {"id", "palette", "spawn", "door", "platforms", "hazards",
                "template", "variation"}
STABLE_KINDS = {"solid", "moving"}  # kinds that count as stable ground


# --------------------------------------------------------------------------
# Small geometry helpers
# --------------------------------------------------------------------------

def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) \
        and math.isfinite(float(v))


def rects_overlap(a, b):
    """Strict (positive-area) overlap of (x, y, w, h) rects."""
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] \
        and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


def point_rect_dist(px, py, r):
    dx = max(r[0] - px, 0.0, px - (r[0] + r[2]))
    dy = max(r[1] - py, 0.0, py - (r[1] + r[3]))
    return math.hypot(dx, dy)


def circle_rect_overlap(cx, cy, r, rect):
    return point_rect_dist(cx, cy, rect) < r


def seg_point_dist(px, py, x1, y1, x2, y2):
    vx, vy = x2 - x1, y2 - y1
    wx, wy = px - x1, py - y1
    denom = vx * vx + vy * vy
    t = 0.0 if denom == 0 else max(0.0, min(1.0, (wx * vx + wy * vy) / denom))
    return math.hypot(px - (x1 + t * vx), py - (y1 + t * vy))


def qb(v, size):
    return int(math.floor(float(v) / size))


def _xy(point):
    if isinstance(point, dict):
        return float(point["x"]), float(point["y"])
    return float(point[0]), float(point[1])


def connectivity_error(platforms, spawn, door, width, bar_y,
                       door_w, door_h):
    """Rule 5 connectivity (LEVEL_SCHEMA.md v2): flood-fill of empty
    space on an 8px grid over width x bar_y, 4-connected, from the
    hero rect at spawn to the door rect. A cell is blocked iff it
    intersects a `solid` platform rect; dashed/falling/tilting/moving
    platforms and all hazards are OPEN. Returns an error string
    (prefix `connectivity:`) or None. Necessary for traversability,
    so it cannot fail a genuinely-passable level. Harness-only: the
    runtime does not implement it. The generator reuses this exact
    predicate (imported, never copied) when deciding gantry beams.
    Returns None for malformed coords: other rules report those."""
    try:
        sx, sy = _xy(spawn)
        dx, dy = _xy(door)
    except (TypeError, ValueError, KeyError, IndexError):
        return None
    cell = CONNECTIVITY_CELL
    cols = max(1, int(math.ceil(float(width) / cell)))
    rows = max(1, int(math.ceil(float(bar_y) / cell)))
    blocked = bytearray(cols * rows)

    def _span(lo, size, limit):
        c0 = max(0, int(lo // cell))
        c1 = min(limit - 1, int((lo + size - 1e-9) // cell))
        return c0, c1

    for p in platforms:
        if not isinstance(p, dict) or p.get("kind") != "solid":
            continue
        if not all(is_num(p.get(k)) for k in ("x", "y", "w", "h")):
            continue
        x, y = float(p["x"]), float(p["y"])
        cx0, cx1 = _span(x, float(p["w"]), cols)
        cy0, cy1 = _span(y, float(p["h"]), rows)
        for cy in range(cy0, cy1 + 1):
            base = cy * cols
            for cx in range(cx0, cx1 + 1):
                blocked[base + cx] = 1

    def _open_cells(rx, ry, rw, rh):
        out = []
        cx0, cx1 = _span(rx, rw, cols)
        cy0, cy1 = _span(ry, rh, rows)
        for cy in range(cy0, cy1 + 1):
            for cx in range(cx0, cx1 + 1):
                if not blocked[cy * cols + cx]:
                    out.append((cx, cy))
        return out

    seeds = _open_cells(sx - HERO_RECT_W / 2.0, sy - HERO_RECT_H,
                        HERO_RECT_W, HERO_RECT_H)
    if not seeds:
        return ("connectivity: no open cell at spawn (hero rect "
                "fully blocked by solid)")
    targets = set(_open_cells(dx - float(door_w) / 2.0,
                              dy - float(door_h),
                              float(door_w), float(door_h)))
    if not targets:
        return ("connectivity: no open cell at door (door rect "
                "fully blocked by solid)")
    seen = set(seeds)
    queue = deque(seeds)
    while queue:
        cx, cy = queue.popleft()
        if (cx, cy) in targets:
            return None
        for nb in ((cx + 1, cy), (cx - 1, cy),
                   (cx, cy + 1), (cx, cy - 1)):
            if 0 <= nb[0] < cols and 0 <= nb[1] < rows \
                    and nb not in seen \
                    and not blocked[nb[1] * cols + nb[0]]:
                seen.add(nb)
                queue.append(nb)
    return ("connectivity: no path from spawn to door through open "
            "space (sealed pocket)")


# --------------------------------------------------------------------------
# Tuning (single source of truth -- loaded, never hand-copied)
# --------------------------------------------------------------------------

class Tuning:
    def __init__(self, data):
        self.raw = data
        self.version = data["tuning_version"]
        vp = data["viewport"]
        self.width = float(vp["width"])
        self.height = float(vp["height"])
        self.bar_y = float(data["control_bar"]["y"])
        self.bar_h = float(data["control_bar"]["height"])
        env = data["harness_envelope"]
        self.max_rise = float(env["max_rise"])
        self.max_gap = float(env["max_gap"])
        self.min_landing = float(env["min_landing_width"])
        self.min_runup = float(env["min_runup"])
        self.min_window = float(env["min_safe_window"])
        pl = data["player"]
        self.gravity = float(pl["gravity"])
        self.jump_v = float(pl["jump_velocity"])
        self.run_speed = float(pl["run_speed"])
        self.player_w = float(pl["width"])
        self.player_h = float(pl["height"])
        door = data["door"]
        self.door_w = float(door["width"])
        self.door_h = float(door["height"])
        self.n_palettes = len(data["palettes"])
        # Theoretical jump apex from frozen physics (for arc reasoning).
        self.apex = (self.jump_v ** 2) / (2.0 * self.gravity)
        # Theoretical max full-speed jump distance (for jump-over checks).
        self.max_jump_dist = (2.0 * abs(self.jump_v) / self.gravity) \
            * self.run_speed


# --------------------------------------------------------------------------
# Hazard time-varying state (declarative params -> lethal geometry at time t)
# --------------------------------------------------------------------------

def hazard_period(h):
    """Round-trip / cycle period of a timed hazard, or None if static."""
    if "period" in h:
        return float(h["period"])
    if h["type"] == "saw" and "swing" in h:
        return float(h["swing"]["period"])
    return None


def saw_centre_at(h, t):
    """Saw centre at absolute time t (sine ease, round trip)."""
    x, y = float(h["x"]), float(h["y"])
    if "path" in h:
        p = h["path"]
        period = float(h["period"])
        f = 0.5 - 0.5 * math.cos(2.0 * math.pi * (t / period))
        return (x + (float(p["x2"]) - x) * f, y + (float(p["y2"]) - y) * f)
    if "swing" in h:
        s = h["swing"]
        period = float(s["period"])
        ang = math.radians(float(s["arc_deg"])) * 0.5 \
            * math.sin(2.0 * math.pi * (t / period))
        ox, oy = x - float(s["pivot_x"]), y - float(s["pivot_y"])
        ca, sa = math.cos(ang), math.sin(ang)
        return (float(s["pivot_x"]) + ox * ca - oy * sa,
                float(s["pivot_y"]) + ox * sa + oy * ca)
    return (x, y)


def saw_swept_bbox(h):
    """Conservative swept bounding box of a saw (rest + path/swing)."""
    x, y, r = float(h["x"]), float(h["y"]), float(h["r"])
    pts = [(x, y)]
    if "path" in h:
        pts.append((float(h["path"]["x2"]), float(h["path"]["y2"])))
    if "swing" in h:
        s = h["swing"]
        for frac in (-1.0, -0.5, 0.0, 0.5, 1.0):
            ang = math.radians(float(s["arc_deg"])) * 0.5 * frac
            ox, oy = x - float(s["pivot_x"]), y - float(s["pivot_y"])
            ca, sa = math.cos(ang), math.sin(ang)
            pts.append((float(s["pivot_x"]) + ox * ca - oy * sa,
                        float(s["pivot_y"]) + ox * sa + oy * ca))
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs) - r, min(ys) - r, max(xs) - min(xs) + 2 * r,
            max(ys) - min(ys) + 2 * r)


def saw_sweep_centres(h):
    """Swept saw centres per LEVEL_SCHEMA.md rules 7/8: rest centre,
    path endpoint, and the 13-sample swing arc (frac -1..1 in 1/6
    steps). Used ONLY by the grounding / keep-out checks; the older
    5-sample saw_swept_bbox keeps its existing callers unchanged."""
    x, y = float(h["x"]), float(h["y"])
    pts = [(x, y)]
    if "path" in h and isinstance(h["path"], dict):
        p = h["path"]
        if is_num(p.get("x2")) and is_num(p.get("y2")):
            pts.append((float(p["x2"]), float(p["y2"])))
    if "swing" in h and isinstance(h["swing"], dict):
        s = h["swing"]
        if all(is_num(s.get(k)) for k in ("pivot_x", "pivot_y", "arc_deg")):
            px, py = float(s["pivot_x"]), float(s["pivot_y"])
            ox, oy = x - px, y - py
            for k in range(13):
                frac = -1.0 + k / 6.0
                ang = math.radians(float(s["arc_deg"])) * 0.5 * frac
                ca, sa = math.cos(ang), math.sin(ang)
                pts.append((px + ox * ca - oy * sa,
                            py + ox * sa + oy * ca))
    return pts


def popup_up_at(h, t):
    """True if a pop-up (period/phase/on_time) hazard is lethal at time t."""
    period = float(h["period"])
    phase = float(h.get("phase", 0.0))
    return ((t - phase) % period) < float(h["on_time"])


def pillar_state_at(h, t, tun, floor_y):
    """Periodic hanging pillar: (rect, lethal) at absolute time t.

    Cycle: hang (solid, not lethal) -> drop at drop_speed -> rise over
    1.0s (lethal while falling/rising). Triggered pillars are handled
    by the crossing simulation, not here.
    """
    x, y, w, hh = (float(h[k]) for k in ("x", "y", "w", "h"))
    period = float(h["period"])
    phase = float(h.get("phase", 0.0))
    speed = float(h.get("drop_speed", DEFAULT_DROP_SPEED))
    drop_dist = max(0.0, floor_y - (y + hh))
    drop_time = drop_dist / speed if speed > 0 else 0.0
    cyc = (t - phase) % period
    hang_time = max(0.0, period - drop_time - PILLAR_RISE_TIME)
    if cyc < hang_time:
        return (x, y, w, hh), False
    if cyc < hang_time + drop_time:
        dy = speed * (cyc - hang_time)
        return (x, y + dy, w, hh), True
    frac = (cyc - hang_time - drop_time) / PILLAR_RISE_TIME \
        if PILLAR_RISE_TIME > 0 else 1.0
    dy = drop_dist * (1.0 - min(1.0, frac))
    return (x, y + dy, w, hh), True


# --------------------------------------------------------------------------
# Per-level verification
# --------------------------------------------------------------------------

class LevelCheck:
    def __init__(self, level, index, tun):
        self.lv = level
        self.index = index
        self.tun = tun
        self.errors = []   # hard failures
        self.notes = []    # informative, non-failing
        self.edges = {}    # (a, b) -> edge info dict
        self.solution = None  # chosen path: list of platform indices
        self.solution_edges = []
        self.structural_ok = True
        self.density = None  # rule 9 stats, set by check_density_floor
        self.grounded_solids = set()  # rule 7 fixpoint, set by check_grounding

    # -- (a) fields / params ----------------------------------------------
    def check_fields(self):
        lv, tun = self.lv, self.tun
        if not isinstance(lv, dict):
            self.errors.append("level is not an object")
            self.structural_ok = False
            return
        for f in LEVEL_FIELDS:
            if f not in lv:
                self.errors.append("missing required field '%s'" % f)
                self.structural_ok = False
        if not self.structural_ok:
            return
        if not isinstance(lv["id"], str) or not lv["id"]:
            self.errors.append("id must be a non-empty string")
        if not isinstance(lv["palette"], int) or isinstance(lv["palette"], bool) \
                or not (0 <= lv["palette"] < tun.n_palettes):
            self.errors.append("palette %r out of range 0..%d"
                               % (lv["palette"], tun.n_palettes - 1))
        for key in ("template", "variation"):
            if not isinstance(lv[key], str) or not lv[key]:
                self.errors.append("%s must be a non-empty string" % key)
        for key in ("spawn", "door"):
            pt = lv[key]
            if not isinstance(pt, dict) or not is_num(pt.get("x")) \
                    or not is_num(pt.get("y")):
                self.errors.append("%s must be {x, y} numbers" % key)
                self.structural_ok = False
        if not isinstance(lv["platforms"], list) or not lv["platforms"]:
            self.errors.append("platforms must be a non-empty array")
            self.structural_ok = False
        if not isinstance(lv["hazards"], list):
            self.errors.append("hazards must be an array")
            self.structural_ok = False
        if not self.structural_ok:
            return
        if not lv["hazards"] and self.index >= 3:
            self.errors.append(
                "hazards may be empty only for the first 3 teaching levels")
        for i, p in enumerate(lv["platforms"]):
            self._check_platform(i, p)
        for i, h in enumerate(lv["hazards"]):
            self._check_hazard(i, h)

    def _num_field(self, obj, field, where, minimum=None):
        v = obj.get(field)
        if not is_num(v):
            self.errors.append("%s: '%s' must be a number" % (where, field))
            return None
        if minimum is not None and float(v) < minimum:
            self.errors.append("%s: '%s'=%s below minimum %s"
                               % (where, field, v, minimum))
        return float(v)

    def _check_platform(self, i, p):
        where = "platforms[%d]" % i
        if not isinstance(p, dict):
            self.errors.append("%s is not an object" % where)
            return
        for f in ("x", "y", "w", "h", "kind"):
            if f not in p:
                self.errors.append("%s: missing '%s'" % (where, f))
        kind = p.get("kind")
        if kind not in PLATFORM_KINDS:
            self.errors.append("%s: unknown kind %r (hard error)"
                               % (where, kind))
        for f in ("x", "y", "w", "h"):
            self._num_field(p, f, where)
        if kind == "dashed":
            for f in ("period", "phase", "on_time"):
                self._num_field(p, f, where, minimum=0.0)
            if is_num(p.get("period")) and is_num(p.get("on_time")):
                if float(p["on_time"]) < DASHED_MIN_ON:
                    self.errors.append(
                        "%s: on_time %s < %.2f" % (where, p["on_time"],
                                                   DASHED_MIN_ON))
                if float(p["period"]) - float(p["on_time"]) < DASHED_MIN_OFF:
                    self.errors.append(
                        "%s: off-time %.2f < %.2f"
                        % (where, float(p["period"]) - float(p["on_time"]),
                           DASHED_MIN_OFF))
        elif kind in ("falling", "tilting"):
            self._num_field(p, "stand_time", where, minimum=FALL_MIN_STAND)
        elif kind == "moving":
            self._num_field(p, "dx", where)
            self._num_field(p, "dy", where)
            self._num_field(p, "period", where, minimum=MOVING_MIN_PERIOD)

    def _check_hazard(self, i, h):
        where = "hazards[%d]" % i
        if not isinstance(h, dict):
            self.errors.append("%s is not an object" % where)
            return
        for f in ("type", "x", "y", "w", "h"):
            if f not in h:
                self.errors.append("%s: missing '%s'" % (where, f))
        htype = h.get("type")
        if htype not in HAZARD_TYPES:
            self.errors.append("%s: unknown type %r (hard error)"
                               % (where, htype))
        for f in ("x", "y", "w", "h"):
            self._num_field(h, f, where)
        if "delay" in h:
            self._num_field(h, "delay", where, minimum=MIN_DELAY)
        if "trigger_x" in h:
            self._num_field(h, "trigger_x", where)
        if htype == "spikes":
            d = h.get("dir", "up")
            if d not in SPIKE_DIRS:
                self.errors.append("%s: unknown dir %r" % (where, d))
            if "period" in h:
                self._num_field(h, "period", where, minimum=0.0)
                self._num_field(h, "phase", where, minimum=0.0)
                self._num_field(h, "on_time", where, minimum=0.0)
                if is_num(h.get("period")) and is_num(h.get("on_time")):
                    if float(h["on_time"]) < DASHED_MIN_ON:
                        self.errors.append(
                            "%s: on_time %s < %.2f" % (where, h["on_time"],
                                                       DASHED_MIN_ON))
                    if float(h["period"]) - float(h["on_time"]) < DASHED_MIN_OFF:
                        self.errors.append(
                            "%s: off-time %.2f < %.2f"
                            % (where, float(h["period"]) - float(h["on_time"]),
                               DASHED_MIN_OFF))
        elif htype == "saw":
            r = self._num_field(h, "r", where)
            if r is not None and not (SAW_R_MIN <= r <= SAW_R_MAX):
                self.errors.append("%s: r %s outside %s..%s"
                                   % (where, r, SAW_R_MIN, SAW_R_MAX))
            if "path" in h and "swing" in h:
                self.errors.append("%s: saw has both path and swing" % where)
            if "path" in h:
                p = h["path"]
                if not isinstance(p, dict):
                    self.errors.append("%s: path must be an object" % where)
                else:
                    self._num_field(p, "x2", where + ".path")
                    self._num_field(p, "y2", where + ".path")
                self._num_field(h, "period", where,
                                minimum=MOVING_MIN_PERIOD)
            if "swing" in h:
                s = h["swing"]
                if not isinstance(s, dict):
                    self.errors.append("%s: swing must be an object" % where)
                else:
                    for f in ("pivot_x", "pivot_y", "arc_deg"):
                        self._num_field(s, f, where + ".swing")
                    self._num_field(s, "period", where + ".swing",
                                    minimum=MOVING_MIN_PERIOD)
        elif htype == "hanging_pillar":
            has_trig = "drop_trigger_x" in h
            has_period = "period" in h
            if has_trig == has_period:
                self.errors.append(
                    "%s: hanging_pillar needs exactly one of "
                    "drop_trigger_x / period" % where)
            if has_trig:
                self._num_field(h, "drop_trigger_x", where)
            if has_period:
                self._num_field(h, "period", where, minimum=0.0)
                self._num_field(h, "phase", where, minimum=0.0)
            if "drop_speed" in h:
                self._num_field(h, "drop_speed", where, minimum=1.0)
        elif htype == "dotted_line":
            linked = h.get("linked")
            if not isinstance(linked, int) or isinstance(linked, bool) \
                    or not (0 <= linked < len(self.lv["hazards"])):
                self.errors.append("%s: linked %r is not a valid hazard index"
                                   % (where, linked))
            elif linked == i:
                self.errors.append("%s: linked to itself" % where)

    # -- (b) geometry bounds ----------------------------------------------
    def check_bounds(self):
        tun = self.tun
        W, H = tun.width, tun.bar_y
        for i, p in enumerate(self.lv["platforms"]):
            if not all(is_num(p.get(k)) for k in ("x", "y", "w", "h")):
                continue
            x, y, w, h = (float(p[k]) for k in ("x", "y", "w", "h"))
            if x < 0 or y < 0 or x + w > W or y + h > H:
                self.errors.append(
                    "platforms[%d] outside bounds 0..%g / 0..%g "
                    "(rect %g,%g %gx%g)" % (i, W, H, x, y, w, h))
            if w < tun.min_landing:
                self.errors.append(
                    "platforms[%d] w=%g < landing minimum %g"
                    % (i, w, tun.min_landing))
            if h < MIN_PLATFORM_H:
                self.errors.append("platforms[%d] h=%g < %g" % (i, h,
                                                                MIN_PLATFORM_H))
        for i, h in enumerate(self.lv["hazards"]):
            if not all(is_num(h.get(k)) for k in ("x", "y", "w", "h")):
                continue
            x, y, w, hh = (float(h[k]) for k in ("x", "y", "w", "h"))
            if h["type"] == "saw":
                if not (0 <= x <= W and 0 <= y <= H):
                    self.errors.append(
                        "hazards[%d] saw centre outside bounds" % i)
                if "path" in h and isinstance(h["path"], dict) \
                        and is_num(h["path"].get("x2")) \
                        and is_num(h["path"].get("y2")):
                    if not (0 <= float(h["path"]["x2"]) <= W
                            and 0 <= float(h["path"]["y2"]) <= H):
                        self.errors.append(
                            "hazards[%d] saw path end outside bounds" % i)
                if "swing" in h and isinstance(h["swing"], dict) \
                        and is_num(h["swing"].get("pivot_x")) \
                        and is_num(h["swing"].get("pivot_y")):
                    if not (0 <= float(h["swing"]["pivot_x"]) <= W
                            and 0 <= float(h["swing"]["pivot_y"]) <= H):
                        self.errors.append(
                            "hazards[%d] saw pivot outside bounds" % i)
            elif x < 0 or y < 0 or x + w > W or y + hh > H:
                self.errors.append(
                    "hazards[%d] outside bounds 0..%g / 0..%g" % (i, W, H))
        sp, dr = self.lv["spawn"], self.lv["door"]
        if not (0 <= float(sp["x"]) <= W and 0 <= float(sp["y"]) <= H):
            self.errors.append("spawn outside bounds")
        drect = self.door_rect()
        if drect[0] < 0 or drect[1] < 0 or drect[0] + drect[2] > W \
                or drect[1] + drect[3] > H:
            self.errors.append("door rect outside bounds")

    # -- (b2) HUD keep-out (rule 8) ---------------------------------------
    def check_hud_keepout(self):
        lv = self.lv
        for i, p in enumerate(lv["platforms"]):
            if not all(is_num(p.get(k)) for k in ("x", "y", "w", "h")):
                continue
            rects = [(float(p["x"]), float(p["y"]), float(p["w"]),
                      float(p["h"]))]
            if p.get("kind") == "moving" and is_num(p.get("dx")) \
                    and is_num(p.get("dy")):
                rects.append((rects[0][0] + float(p["dx"]),
                              rects[0][1] + float(p["dy"]),
                              rects[0][2], rects[0][3]))
            for (_rx, ry, _rw, _rh) in rects:
                if ry < HUD_KEEPOUT_Y:
                    self.errors.append(
                        "keep-out: platforms[%d] drawn extent reaches "
                        "y=%g < %g" % (i, ry, HUD_KEEPOUT_Y))
                    break
        for i, h in enumerate(lv["hazards"]):
            t = h.get("type")
            if t == "saw":
                if not (is_num(h.get("x")) and is_num(h.get("y"))
                        and is_num(h.get("r"))):
                    continue
                r = float(h["r"])
                for (_cx, cy) in saw_sweep_centres(h):
                    if cy - r < HUD_KEEPOUT_Y:
                        self.errors.append(
                            "keep-out: hazards[%d] saw sweep reaches "
                            "y=%g < %g" % (i, cy - r, HUD_KEEPOUT_Y))
                        break
            elif is_num(h.get("y")) and float(h["y"]) < HUD_KEEPOUT_Y:
                self.errors.append(
                    "keep-out: hazards[%d] %s rect top y=%g < %g"
                    % (i, t, float(h["y"]), HUD_KEEPOUT_Y))
        sp, dr = lv["spawn"], lv["door"]
        if is_num(sp.get("y")) and float(sp["y"]) < SPAWN_MIN_Y:
            self.errors.append("keep-out: spawn feet y=%g < %g"
                               % (float(sp["y"]), SPAWN_MIN_Y))
        if is_num(dr.get("y")) and float(dr["y"]) < DOOR_MIN_Y:
            self.errors.append("keep-out: door base y=%g < %g"
                               % (float(dr["y"]), DOOR_MIN_Y))

    # -- (b3) grounding (rule 7) ------------------------------------------
    def _rects(self):
        """Numeric (x, y, w, h) per platform, None if malformed."""
        out = []
        for p in self.lv["platforms"]:
            if all(is_num(p.get(k)) for k in ("x", "y", "w", "h")):
                out.append((float(p["x"]), float(p["y"]), float(p["w"]),
                            float(p["h"])))
            else:
                out.append(None)
        return out

    @staticmethod
    def _x_overlap(a, b):
        return min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])

    @staticmethod
    def _y_overlap(a, b):
        return min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])

    def _resting_on(self, r, rects, grounded):
        """True if rect r rests on grounded solid tops: one support with
        x-overlap >= 48, or both end regions on supports (combined
        overlap >= 48). Gap <= GROUND_TOL in all cases."""
        bottom = r[1] + r[3]
        total = 0.0
        left_ok = right_ok = False
        third = max(8.0, r[2] / 3.0)
        for j in grounded:
            s = rects[j]
            if abs(bottom - s[1]) > GROUND_TOL:
                continue
            ov = self._x_overlap(r, s)
            if ov >= MIN_PILLAR_W:
                return True
            total += max(0.0, ov)
            if self._x_overlap((r[0], r[1], third, r[3]), s) >= 8.0:
                left_ok = True
            if self._x_overlap((r[0] + r[2] - third, r[1], third, r[3]),
                               s) >= 8.0:
                right_ok = True
        return left_ok and right_ok and total >= MIN_PILLAR_W

    def _grounded_solids(self, rects):
        """Fixpoint set of grounded solid indices: floor, resting,
        pillar-connected, or both-ends-touching. A support must itself
        be grounded, so floating stacks never ground each other."""
        plats = self.lv["platforms"]
        bar_y = self.tun.bar_y
        grounded = set()
        changed = True
        while changed:
            changed = False
            for i, r in enumerate(rects):
                if r is None or i in grounded \
                        or plats[i].get("kind") != "solid":
                    continue
                bottom = r[1] + r[3]
                ok = abs(bottom - bar_y) <= GROUND_TOL
                if not ok:
                    ok = self._resting_on(r, rects, grounded)
                if not ok:
                    # Pillar-connected: a grounded pillar (w >= 48)
                    # whose top touches this bottom and whose x-span
                    # lies within this platform's x-span.
                    for j in grounded:
                        q = rects[j]
                        if q[2] < MIN_PILLAR_W:
                            continue
                        if abs(q[1] - bottom) <= GROUND_TOL \
                                and q[0] >= r[0] \
                                and q[0] + q[2] <= r[0] + r[2]:
                            ok = True
                            break
                if not ok:
                    left = right = False
                    for j in grounded:
                        s = rects[j]
                        if self._y_overlap(r, s) >= 8.0:
                            if abs((s[0] + s[2]) - r[0]) <= GROUND_TOL:
                                left = True
                            if abs(s[0] - (r[0] + r[2])) <= GROUND_TOL:
                                right = True
                    ok = left and right
                if ok:
                    grounded.add(i)
                    changed = True
        return grounded

    def _shaft_flanked(self, idx, rects, grounded):
        """True if grounded solid columns flank BOTH ends within 8px and
        span the platform's full y-range (full sweep range if moving).
        For moving platforms the flank gaps are measured from the
        swept x-extent, so a sliding platform never sinks into its
        shaft walls at full travel."""
        p = self.lv["platforms"][idx]
        r = rects[idx]
        y0, y1 = r[1], r[1] + r[3]
        x0, x1 = r[0], r[0] + r[2]
        if p.get("kind") == "moving":
            if is_num(p.get("dy")):
                dy = float(p["dy"])
                y0, y1 = min(y0, y0 + dy), max(y1, y1 + dy)
            if is_num(p.get("dx")):
                dx = float(p["dx"])
                x0, x1 = min(x0, x0 + dx), max(x1, x1 + dx)
        left = right = False
        for j in grounded:
            s = rects[j]
            if s[1] > y0 + GROUND_TOL or s[1] + s[3] < y1 - GROUND_TOL:
                continue
            if -GROUND_TOL <= x0 - (s[0] + s[2]) <= SHAFT_FLANK_GAP:
                left = True
            if -GROUND_TOL <= s[0] - x1 <= SHAFT_FLANK_GAP:
                right = True
        return left and right

    def _spikes_seated(self, h, rects, grounded):
        r = (float(h["x"]), float(h["y"]), float(h["w"]), float(h["h"]))
        d = h.get("dir", "up")
        plats = self.lv["platforms"]
        solids = [(j, rects[j]) for j in range(len(rects))
                  if rects[j] is not None
                  and plats[j].get("kind") == "solid"]
        if d == "up":
            bottom = r[1] + r[3]
            return any(abs(bottom - s[1]) <= GROUND_TOL
                       and self._x_overlap(r, s) >= 8.0
                       for _j, s in solids)
        if d == "down":
            return any(j in grounded
                       and abs(r[1] - (s[1] + s[3])) <= GROUND_TOL
                       and self._x_overlap(r, s) >= 8.0
                       for j, s in solids)
        # left/right: a side face within 4px of a solid side.
        for _j, s in solids:
            if self._y_overlap(r, s) >= 8.0:
                if abs((r[0] + r[2]) - s[0]) <= GROUND_TOL \
                        or abs(r[0] - (s[0] + s[2])) <= GROUND_TOL:
                    return True
        return False

    def check_grounding(self):
        plats = self.lv["platforms"]
        rects = self._rects()
        grounded = self._grounded_solids(rects)
        self.grounded_solids = grounded
        for i, p in enumerate(plats):
            if rects[i] is None:
                continue
            kind = p.get("kind")
            if kind == "solid":
                if i not in grounded:
                    self.errors.append(
                        "grounding: platforms[%d] solid is unsupported "
                        "(floating)" % i)
            elif kind in ("dashed", "falling", "tilting", "moving"):
                if not (self._resting_on(rects[i], rects, grounded)
                        or self._shaft_flanked(i, rects, grounded)):
                    self.errors.append(
                        "grounding: platforms[%d] %s is unsupported "
                        "(needs shaft-flank or resting ends)"
                        % (i, kind))
        solid_rects = [rects[j] for j in range(len(rects))
                       if rects[j] is not None
                       and plats[j].get("kind") == "solid"]
        for i, h in enumerate(self.lv["hazards"]):
            t = h.get("type")
            if t in ("hanging_pillar", "dotted_line"):
                continue  # exempt from grounding by the schema
            if not all(is_num(h.get(k)) for k in ("x", "y", "w", "h")):
                continue
            if t == "spikes":
                if not self._spikes_seated(h, rects, grounded):
                    self.errors.append(
                        "grounding: hazards[%d] spikes not seated "
                        "(dir=%s)" % (i, h.get("dir", "up")))
            elif t == "saw":
                if not is_num(h.get("r")):
                    continue
                r = float(h["r"])
                for (cx, cy) in saw_sweep_centres(h):
                    if not any(point_rect_dist(cx, cy, s) <= r + GROUND_TOL
                               for s in solid_rects):
                        self.errors.append(
                            "grounding: hazards[%d] saw disc does not "
                            "touch solid at swept centre (%g,%g)"
                            % (i, cx, cy))
                        break
                if "swing" in h and isinstance(h["swing"], dict):
                    s = h["swing"]
                    if all(is_num(s.get(k))
                           for k in ("pivot_x", "pivot_y")):
                        px, py = float(s["pivot_x"]), float(s["pivot_y"])
                        inside = any(
                            j in grounded and rects[j][0] <= px
                            <= rects[j][0] + rects[j][2]
                            and rects[j][1] <= py
                            <= rects[j][1] + rects[j][3]
                            for j in range(len(rects))
                            if rects[j] is not None)
                        if not inside:
                            self.errors.append(
                                "grounding: hazards[%d] swing pivot not "
                                "inside a grounded solid beam" % i)
            elif t == "spiked_column":
                r = (float(h["x"]), float(h["y"]), float(h["w"]),
                     float(h["h"]))
                bottom, top = r[1] + r[3], r[1]
                on_top = abs(bottom - self.tun.bar_y) <= GROUND_TOL \
                    or any(abs(bottom - s[1]) <= GROUND_TOL
                           and self._x_overlap(r, s) >= 8.0
                           for s in solid_rects)
                hung = any(j in grounded
                           and abs(top - (rects[j][1] + rects[j][3]))
                           <= GROUND_TOL
                           and self._x_overlap(r, rects[j]) >= 8.0
                           for j in range(len(rects))
                           if rects[j] is not None)
                if not (on_top or hung):
                    self.errors.append(
                        "grounding: hazards[%d] spiked_column unsupported "
                        "(needs solid top/floor or grounded beam)" % i)

    # -- (b3b) hazard/solid area-overlap (rule 7) ------------------------
    def check_hazard_solid_overlap(self):
        """Rect hazards must not area-overlap solid rects beyond the
        4px seating tolerance: an intersection with width > 4 AND
        height > 4 fails. Saws (disc geometry), hanging_pillar (beam
        mounts) and dotted_line (indicators) are exempt. Harness
        only; the runtime does not check this."""
        rects = self._rects()
        plats = self.lv["platforms"]
        solids = [(j, rects[j]) for j in range(len(rects))
                  if rects[j] is not None
                  and plats[j].get("kind") == "solid"]
        for i, h in enumerate(self.lv["hazards"]):
            t = h.get("type")
            if t not in ("spikes", "spiked_column"):
                continue
            if not all(is_num(h.get(k)) for k in ("x", "y", "w", "h")):
                continue
            r = (float(h["x"]), float(h["y"]), float(h["w"]),
                 float(h["h"]))
            for j, s in solids:
                iw = self._x_overlap(r, s)
                ih = self._y_overlap(r, s)
                if iw > OVERLAP_TOL and ih > OVERLAP_TOL:
                    self.errors.append(
                        "overlap: hazards[%d] %s overlaps platforms[%d] "
                        "solid by %gx%g (seating tolerance is 4px)"
                        % (i, t, j, iw, ih))
                    break

    # -- (b4) density floor (rule 9) --------------------------------------
    def check_density_floor(self):
        rects = self._rects()
        count = 0
        width = 0.0
        core_count = 0
        core_width = 0.0
        for i, r in enumerate(rects):
            if r is None or self.lv["platforms"][i].get("kind") != "solid":
                continue
            if r[1] < DENSITY_BAND_BOTTOM \
                    and r[1] + r[3] > DENSITY_BAND_TOP:
                count += 1
                width += r[2]
            # Core-middle floor: edge-touching rects (the edge walls)
            # do not count; only interior structure fills the middle.
            if r[0] != 0.0 and r[0] + r[2] != self.tun.width \
                    and r[1] < CORE_BAND_BOTTOM \
                    and r[1] + r[3] > CORE_BAND_TOP:
                core_count += 1
                core_width += r[2]
        # Core-middle floor, decorations half (rules 9 + 10):
        # decoration rects count TOGETHER with solid rects. The
        # y150..450 floor above stays solid-only. Malformed deco
        # entries are reported by check_decorations and skipped
        # here, never counted.
        for d in self._deco_rects():
            if d is None:
                continue
            if d[0] != 0.0 and d[0] + d[2] != self.tun.width \
                    and d[1] < CORE_BAND_BOTTOM \
                    and d[1] + d[3] > CORE_BAND_TOP:
                core_count += 1
                core_width += d[2]
        hz = len(self.lv["hazards"])
        ok = count >= DENSITY_MIN_RECTS and width >= DENSITY_MIN_WIDTH
        core_ok = core_count >= CORE_MIN_RECTS \
            and core_width >= CORE_MIN_WIDTH
        self.density = {"rect_count": count, "combined_width": width,
                        "hazard_count": hz, "pass": ok and core_ok,
                        "core_rect_count": core_count,
                        "core_combined_width": core_width,
                        "core_pass": core_ok}
        if not ok:
            self.errors.append(
                "density: only %d solid rect(s) in middle band "
                "y150..450, combined width %g (need >= %d rects "
                "and width >= %g)"
                % (count, width, DENSITY_MIN_RECTS, DENSITY_MIN_WIDTH))
        if not core_ok:
            self.errors.append(
                "core-middle: only %d non-edge solid/decoration "
                "rect(s) intersecting y260..420, combined width %g "
                "(need >= %d rects and width >= %g)"
                % (core_count, core_width, CORE_MIN_RECTS,
                   CORE_MIN_WIDTH))

    def _deco_rects(self):
        """Numeric (x, y, w, h) per decoration, None if malformed.
        A missing `decorations` array means [] (valid, no entries)."""
        decos = self.lv.get("decorations") \
            if isinstance(self.lv, dict) else None
        if not isinstance(decos, list):
            return []
        out = []
        for d in decos:
            if isinstance(d, dict) \
                    and all(is_num(d.get(k)) for k in ("x", "y", "w", "h")):
                out.append((float(d["x"]), float(d["y"]), float(d["w"]),
                            float(d["h"])))
            else:
                out.append(None)
        return out

    def _hazard_block_rect(self, h):
        """Blocking rect for decoration overlap (rule 10): the hazard
        rect for rect hazards; the swept disc bbox for saws (a saw's
        x/y is its centre, so its (x, y, w, h) is not a rect). None
        if the hazard is malformed (other checks report it)."""
        if h.get("type") == "saw":
            if not all(is_num(h.get(k)) for k in ("x", "y", "r")):
                return None
            try:
                return saw_swept_bbox(h)
            except Exception:
                return None
        if all(is_num(h.get(k)) for k in ("x", "y", "w", "h")):
            return (float(h["x"]), float(h["y"]), float(h["w"]),
                    float(h["h"]))
        return None

    @staticmethod
    def _deco_touches(a, b):
        """Edge-adjacency within 4px (rule 10 attachment): area
        overlap, or a <= 4px gap on one axis with positive overlap
        on the other. Corner-only proximity does not count."""
        xov = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
        yov = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
        if xov > 0 and yov > 0:
            return True
        if xov > 0 and -DECO_ATTACH_TOL <= yov <= 0:
            return True
        if yov > 0 and -DECO_ATTACH_TOL <= xov <= 0:
            return True
        return False

    # -- (b5) decorations (rule 10) -------------------------------------
    def check_decorations(self):
        """Rule 10 (harness only): attachment chain to a solid,
        HUD keep-out, no overlap with any hazard rect / the spawn
        hero rect / the door rect, bounds + minima. A missing array
        means [] (valid). Error prefix `deco:`."""
        if not isinstance(self.lv, dict) or "decorations" not in self.lv:
            return
        decos = self.lv["decorations"]
        if not isinstance(decos, list):
            self.errors.append("deco: decorations must be an array")
            return
        tun = self.tun
        W, H = tun.width, tun.bar_y
        rects = self._deco_rects()
        for i, r in enumerate(rects):
            if r is None:
                self.errors.append(
                    "deco: decorations[%d] must be {x, y, w, h} numbers"
                    % i)
                continue
            x, y, w, h = r
            if x < 0 or x + w > W or y + h > H:
                self.errors.append(
                    "deco: decorations[%d] outside bounds 0..%g / "
                    "90..%g (rect %g,%g %gx%g)" % (i, W, H, x, y, w, h))
            if w < DECO_MIN_W:
                self.errors.append(
                    "deco: decorations[%d] w=%g < %g" % (i, w, DECO_MIN_W))
            if h < DECO_MIN_H:
                self.errors.append(
                    "deco: decorations[%d] h=%g < %g" % (i, h, DECO_MIN_H))
            if y < HUD_KEEPOUT_Y:
                self.errors.append(
                    "deco: decorations[%d] keep-out: top y=%g < %g"
                    % (i, y, HUD_KEEPOUT_Y))
        # No overlap with hazards / spawn hero / door (area > 0).
        blockers = []
        for h in self.lv.get("hazards", []):
            blockers.append(self._hazard_block_rect(h)
                            if isinstance(h, dict) else None)
        sp = self.lv.get("spawn")
        hero = None
        if isinstance(sp, dict) and is_num(sp.get("x")) \
                and is_num(sp.get("y")):
            hero = (float(sp["x"]) - HERO_RECT_W / 2.0,
                    float(sp["y"]) - HERO_RECT_H,
                    HERO_RECT_W, HERO_RECT_H)
        try:
            door = self.door_rect()
        except Exception:
            door = None
        for i, r in enumerate(rects):
            if r is None:
                continue
            for j, b in enumerate(blockers):
                if b is not None and rects_overlap(r, b):
                    self.errors.append(
                        "deco: decorations[%d] overlaps hazards[%d] "
                        "hazard rect" % (i, j))
                    break
            if hero is not None and rects_overlap(r, hero):
                self.errors.append(
                    "deco: decorations[%d] overlaps the spawn hero rect"
                    % i)
            if door is not None and rects_overlap(r, door):
                self.errors.append(
                    "deco: decorations[%d] overlaps the door rect" % i)
        # Attachment chain: every deco must touch a solid platform
        # rect, or another deco that does (fixpoint over the set).
        solids = []
        for r, p in zip(self._rects(), self.lv.get("platforms", [])):
            if r is not None and isinstance(p, dict) \
                    and p.get("kind") == "solid":
                solids.append(r)
        attached = set()
        for i, r in enumerate(rects):
            if r is not None \
                    and any(self._deco_touches(r, s) for s in solids):
                attached.add(i)
        changed = True
        while changed:
            changed = False
            for i, r in enumerate(rects):
                if r is None or i in attached:
                    continue
                if any(j in attached and rects[j] is not None
                       and self._deco_touches(r, rects[j])
                       for j in range(len(rects))):
                    attached.add(i)
                    changed = True
        for i, r in enumerate(rects):
            if r is not None and i not in attached:
                self.errors.append(
                    "deco: decorations[%d] is not attached to any "
                    "solid platform (no attachment chain)" % i)

    def door_rect(self):
        tun = self.tun
        d = self.lv["door"]
        return (float(d["x"]) - tun.door_w / 2.0, float(d["y"]) - tun.door_h,
                tun.door_w, tun.door_h)

    def lethal_hazards(self):
        """All hazards except dotted_line (visual warning only)."""
        return [h for h in self.lv["hazards"] if h.get("type") != "dotted_line"]

    # -- (c) safe zones + ground ------------------------------------------
    def hazard_near_point(self, px, py):
        """True if any lethal hazard comes within SAFE_ZONE of (px, py)."""
        for h in self.lethal_hazards():
            if h["type"] == "saw":
                r = float(h["r"])
                pts = [(float(h["x"]), float(h["y"]))]
                if "path" in h:
                    pts.append((float(h["path"]["x2"]),
                                float(h["path"]["y2"])))
                    if seg_point_dist(px, py, pts[0][0], pts[0][1],
                                      pts[1][0], pts[1][1]) - r < SAFE_ZONE:
                        return h
                if "swing" in h:
                    for frac in (-1.0, 0.0, 1.0):
                        s = h["swing"]
                        ang = math.radians(float(s["arc_deg"])) * 0.5 * frac
                        ox = float(h["x"]) - float(s["pivot_x"])
                        oy = float(h["y"]) - float(s["pivot_y"])
                        cx = float(s["pivot_x"]) + ox * math.cos(ang) \
                            - oy * math.sin(ang)
                        cy = float(s["pivot_y"]) + ox * math.sin(ang) \
                            + oy * math.cos(ang)
                        pts.append((cx, cy))
                for (cx, cy) in pts:
                    if math.hypot(px - cx, py - cy) - r < SAFE_ZONE:
                        return h
            else:
                r = (float(h["x"]), float(h["y"]), float(h["w"]),
                     float(h["h"]))
                if point_rect_dist(px, py, r) < SAFE_ZONE:
                    return h
        return None

    def hazard_near_door(self):
        d = self.door_rect()
        exp = (d[0] - SAFE_ZONE, d[1] - SAFE_ZONE, d[2] + 2 * SAFE_ZONE,
               d[3] + 2 * SAFE_ZONE)
        for h in self.lethal_hazards():
            if h["type"] == "saw":
                bb = saw_swept_bbox(h)
                if rects_overlap(bb, exp):
                    # Refine: sample the swept path, circle vs expanded rect.
                    cx, cy = saw_centre_at(h, 0.0)
                    if circle_rect_overlap(cx, cy, float(h["r"]), exp):
                        return h
                    period = hazard_period(h)
                    if period:
                        for k in range(1, 13):
                            cx, cy = saw_centre_at(h, period * k / 12.0)
                            if circle_rect_overlap(cx, cy, float(h["r"]), exp):
                                return h
            else:
                r = (float(h["x"]), float(h["y"]), float(h["w"]),
                     float(h["h"]))
                if rects_overlap(r, exp):
                    return h
        return None

    def ground_platforms(self, px, py):
        """Indices of platforms whose top is within GROUND_TOL of py and
        whose span covers px."""
        out = []
        for i, p in enumerate(self.lv["platforms"]):
            if abs(float(p["y"]) - py) <= GROUND_TOL \
                    and float(p["x"]) <= px <= float(p["x"]) + float(p["w"]):
                out.append(i)
        return out

    def check_safe_zones_and_ground(self):
        sp, dr = self.lv["spawn"], self.lv["door"]
        sx, sy = float(sp["x"]), float(sp["y"])
        h = self.hazard_near_point(sx, sy)
        if h is not None:
            self.errors.append("spawn safe zone violated: %s hazard within "
                               "%gpx of spawn" % (h["type"], SAFE_ZONE))
        h = self.hazard_near_door()
        if h is not None:
            self.errors.append("door safe zone violated: %s hazard within "
                               "%gpx of door rect" % (h["type"], SAFE_ZONE))
        for i, p in enumerate(self.lv["platforms"]):
            x, y, w, hh = (float(p[k]) for k in ("x", "y", "w", "h"))
            if x < sx < x + w and y < sy < y + hh:
                self.errors.append("spawn is inside platforms[%d]" % i)
        drect = self.door_rect()
        for i, p in enumerate(self.lv["platforms"]):
            r = (float(p["x"]), float(p["y"]), float(p["w"]), float(p["h"]))
            if rects_overlap(r, drect):
                self.errors.append("door rect blocked by platforms[%d]" % i)
        self.spawn_nodes = self.ground_platforms(sx, sy)
        self.door_nodes = self.ground_platforms(float(dr["x"]),
                                                float(dr["y"]))
        if not self.spawn_nodes:
            self.errors.append("spawn does not stand on solid ground "
                               "(no platform top within %gpx)" % GROUND_TOL)
        elif not any(self.lv["platforms"][i]["kind"] in STABLE_KINDS
                     for i in self.spawn_nodes):
            self.errors.append("spawn stands only on timed/falling ground "
                               "(no solid/moving platform under spawn)")
        if not self.door_nodes:
            self.errors.append("door does not stand on solid ground "
                               "(no platform top within %gpx)" % GROUND_TOL)
        elif not any(self.lv["platforms"][i]["kind"] in STABLE_KINDS
                     for i in self.door_nodes):
            self.errors.append("door stands only on timed/falling ground "
                               "(no solid/moving platform under door)")

    # -- (d) reachability graph -------------------------------------------
    def platform_positions(self, i):
        """Rest rect + (for moving) offset rect, as (x, y, w, h)."""
        p = self.lv["platforms"][i]
        r = (float(p["x"]), float(p["y"]), float(p["w"]), float(p["h"]))
        if p["kind"] == "moving":
            return [r, (r[0] + float(p["dx"]), r[1] + float(p["dy"]),
                        r[2], r[3])]
        return [r]

    def _ground_sitting_spikes(self, h):
        """True if a dir-up spikes strip sits on a platform top."""
        if h.get("dir", "up") != "up":
            return False
        bottom = float(h["y"]) + float(h["h"])
        cx = float(h["x"]) + float(h["w"]) / 2.0
        for p in self.lv["platforms"]:
            if abs(float(p["y"]) - bottom) <= GROUND_TOL \
                    and float(p["x"]) <= cx <= float(p["x"]) + float(p["w"]):
                return True
        return False

    def _arc_samples(self, tx, ty, lx, ly, n=11):
        """Parabolic feet trajectory; peak ~apex above takeoff (conservative
        when landing higher). Yields (x, feet_y)."""
        rise = ty - ly
        h = max(20.0, self.tun.apex - max(0.0, rise) / 2.0)
        for k in range(n):
            t = k / float(n - 1)
            x = tx + (lx - tx) * t
            y = ty + (ly - ty) * t - 4.0 * h * t * (1.0 - t)
            yield x, y

    def _timed_on_corridor(self, band, zone_rects):
        """Timed hazards whose swept volume touches the corridor band or
        any landing/takeoff zone rect. Returns list of hazard indices."""
        out = []
        for i, h in enumerate(self.lv["hazards"]):
            t = h.get("type")
            if t == "dotted_line":
                continue
            touch = False
            if t == "saw" and ("path" in h or "swing" in h):
                bb = saw_swept_bbox(h)
                touch = rects_overlap(bb, band) or any(
                    rects_overlap(bb, z) for z in zone_rects)
            elif t == "spikes" and "period" in h:
                r = (float(h["x"]), float(h["y"]), float(h["w"]),
                     float(h["h"]))
                touch = rects_overlap(r, band) or any(
                    rects_overlap(r, z) for z in zone_rects)
            elif t == "hanging_pillar":
                r = (float(h["x"]), float(h["y"]), float(h["w"]),
                     float(h["h"]))
                fall_col = (r[0], r[1], r[2], self.tun.bar_y - r[1])
                touch = rects_overlap(fall_col, band) or any(
                    rects_overlap(fall_col, z) for z in zone_rects)
            elif "trigger_x" in h or "delay" in h:
                r = (float(h["x"]), float(h["y"]), float(h["w"]),
                     float(h["h"]))
                touch = rects_overlap(r, band) or any(
                    rects_overlap(r, z) for z in zone_rects)
            if touch:
                out.append(i)
        return out

    def edge_info(self, a, b):
        """Edge a->b or None. Tries all moving-platform position combos."""
        tun = self.tun
        pa, pb = self.lv["platforms"][a], self.lv["platforms"][b]
        best = None
        for ra in self.platform_positions(a):
            for rb in self.platform_positions(b):
                info = self._edge_for_rects(a, b, ra, rb)
                if info is not None and (best is None
                                         or len(info["timed"])
                                         < len(best["timed"])):
                    best = info
        return best

    def _edge_for_rects(self, a, b, ra, rb):
        tun = self.tun
        ax1, ay, aw, ah = ra
        bx1, by, bw, bh = rb
        ax2, bx2 = ax1 + aw, bx1 + bw
        overlap = max(0.0, min(ax2, bx2) - max(ax1, bx1))
        gap = 0.0 if overlap > 0 else min(abs(ax2 - bx1), abs(bx2 - ax1))
        rise = ay - by
        why = []
        if rise > tun.max_rise:
            return None
        if gap > tun.max_gap:
            return None
        if gap > 0 and aw < tun.min_runup:
            return None
        if bw < tun.min_landing:
            return None
        # Direction / takeoff / landing points.
        acx, bcx = ax1 + aw / 2.0, bx1 + bw / 2.0
        if bcx >= acx:
            tx, lx = ax2, bx1
            direction = 1
        else:
            tx, lx = ax1, bx2
            direction = -1
        if overlap > 0:
            tx = lx = max(ax1, bx1) + overlap / 2.0
        # Blocker: a tall platform spanning the corridor and reaching
        # into the jump-arc band blocks the arc.
        lo_x, hi_x = min(tx, lx), max(tx, lx)
        top_min = min(ay, by)
        for c, p in enumerate(self.lv["platforms"]):
            if c in (a, b):
                continue
            for rc in self.platform_positions(c):
                cx1, cy, cw, ch = rc
                if cx1 < hi_x and cx1 + cw > lo_x \
                        and cy <= top_min - 20 \
                        and cy + ch >= top_min - tun.apex:
                    return None
        # Landing zone: first landing-width segment of b on arrival side.
        seg = min(tun.min_landing, bw)
        if overlap > 0:
            zx1 = max(ax1, bx1)
            zx2 = min(ax2, bx2)
        elif direction > 0:
            zx1, zx2 = bx1, bx1 + seg
        else:
            zx1, zx2 = bx2 - seg, bx2
        zone = (zx1, by - tun.player_h, zx2 - zx1, tun.player_h)
        # Static lethal hazards in the landing zone reject the edge.
        for h in self.lethal_hazards():
            t = h.get("type")
            if t == "saw" and "path" not in h and "swing" not in h:
                if circle_rect_overlap(float(h["x"]), float(h["y"]),
                                       float(h["r"]), zone):
                    return None
            elif t in ("spikes", "spiked_column") and "period" not in h \
                    and "trigger_x" not in h:
                r = (float(h["x"]), float(h["y"]), float(h["w"]),
                     float(h["h"]))
                if rects_overlap(r, zone):
                    return None
        # Spikes protruding into the jump-arc band (except ground-sitting
        # up-spikes, which a jump clears) reject the edge.
        band = (lo_x - tun.player_w / 2.0, top_min - tun.apex,
                (hi_x - lo_x) + tun.player_w, tun.apex + 4.0)
        for h in self.lethal_hazards():
            if h.get("type") != "spikes":
                continue
            r = (float(h["x"]), float(h["y"]), float(h["w"]), float(h["h"]))
            if not rects_overlap(r, band):
                continue
            if h.get("dir", "up") == "up" and self._ground_sitting_spikes(h):
                continue
            return None
        # Hanging pillars are solid at rest: one in the arc band blocks.
        for h in self.lethal_hazards():
            if h.get("type") != "hanging_pillar":
                continue
            r = (float(h["x"]), float(h["y"]), float(h["w"]), float(h["h"]))
            if rects_overlap(r, band):
                return None
        # Static saw in the corridor: the jump arc must clear its circle.
        for h in self.lethal_hazards():
            if h.get("type") != "saw" or "path" in h or "swing" in h:
                continue
            cx, cy, r = float(h["x"]), float(h["y"]), float(h["r"])
            for (sx, sy) in self._arc_samples(tx, ay, lx, by):
                prect = (sx - tun.player_w / 2.0, sy - tun.player_h,
                         tun.player_w, tun.player_h)
                if circle_rect_overlap(cx, cy, r, prect):
                    return None
        timed = self._timed_on_corridor(band, [zone])
        if pa_kind(self.lv["platforms"][a]) != "solid":
            timed.append("platform:%d" % a)
        if pa_kind(self.lv["platforms"][b]) != "solid":
            timed.append("platform:%d" % b)
        why.append("rise=%.0f<=%.0f gap=%.0f<=%.0f landing=%.0f runup=%.0f"
                   % (rise, tun.max_rise, gap, tun.max_gap, bw, aw))
        return {"a": a, "b": b, "rise": rise, "gap": gap, "dir": direction,
                "takeoff": (tx, ay), "land": (lx, by), "zone": zone,
                "band": band, "timed": timed, "reason": "; ".join(why)}

    def build_graph(self):
        n = len(self.lv["platforms"])
        self.edges = {}
        for a in range(n):
            for b in range(n):
                if a == b:
                    continue
                info = self.edge_info(a, b)
                if info is not None:
                    self.edges[(a, b)] = info
        return self.edges

    def enumerate_paths(self, cap=300):
        """Simple paths from any spawn node to any door node, cheapest
        first (cost 1 + 0.5 per timed element per edge)."""
        adj = {}
        for (a, b), info in self.edges.items():
            adj.setdefault(a, []).append(b)
        for k in adj:
            adj[k].sort(key=lambda b: len(self.edges[(k, b)]["timed"]))
        paths = []

        def cost(path):
            c = 0.0
            for i in range(len(path) - 1):
                c += 1.0 + 0.5 * len(self.edges[(path[i], path[i + 1])]["timed"])
            return c

        def dfs(node, path, seen):
            if len(paths) >= cap:
                return
            if node in self.door_nodes:
                paths.append(list(path))
                return
            for nb in adj.get(node, []):
                if nb in seen:
                    continue
                seen.add(nb)
                path.append(nb)
                dfs(nb, path, seen)
                path.pop()
                seen.discard(nb)

        for s in self.spawn_nodes:
            dfs(s, [s], {s})
            if len(paths) >= cap:
                break
        paths.sort(key=cost)
        return paths

    # -- (e) timed windows -----------------------------------------------
    def _hazard_lethal_at(self, h, prect, t, trig_time):
        """True if hazard h kills a player rect at absolute time t.

        trig_time: absolute time the player's x first passed the hazard's
        trigger (None if never / no trigger)."""
        typ = h.get("type")
        if typ == "dotted_line":
            return False
        if "trigger_x" in h:
            if trig_time is None or t < trig_time + float(h.get("delay", 0.0)):
                return False
        if typ == "spikes":
            if "period" in h and not popup_up_at(h, t):
                return False
            r = (float(h["x"]), float(h["y"]), float(h["w"]), float(h["h"]))
            return rects_overlap(r, prect)
        if typ == "saw":
            cx, cy = saw_centre_at(h, t)
            return circle_rect_overlap(cx, cy, float(h["r"]), prect)
        if typ == "spiked_column":
            r = (float(h["x"]), float(h["y"]), float(h["w"]), float(h["h"]))
            return rects_overlap(r, prect)
        if typ == "hanging_pillar":
            if "period" in h:
                rect, lethal = pillar_state_at(h, t, self.tun,
                                               self.tun.bar_y)
                # Hanging (solid) rect overlapping the player blocks too.
                return rects_overlap(rect, prect)
            # Triggered: drops once the player passes drop_trigger_x.
            if trig_time is None:
                return False
            speed = float(h.get("drop_speed", DEFAULT_DROP_SPEED))
            x, y, w, hh = (float(h[k]) for k in ("x", "y", "w", "h"))
            drop_dist = max(0.0, self.tun.bar_y - (y + hh))
            dy = min(drop_dist, speed * max(0.0, t - trig_time))
            return rects_overlap((x, y + dy, w, hh), prect)
        return False

    def _crossing_simulation(self, h, xs, ys, duration, period):
        """Simulate crossing a hazard zone.

        xs, ys: functions mapping progress fraction [0,1] -> player feet
        (x, y). duration: crossing time in seconds. period: hazard cycle
        (None for triggered-only hazards). Returns (clean_exists,
        entry_clear_window, detail). Entry-clear window = longest
        continuous interval in one period during which standing at the
        entry point is safe.
        """
        tun = self.tun

        def prect_at(frac):
            fx, fy = xs(frac), ys(frac)
            return (fx - tun.player_w / 2.0, fy - tun.player_h,
                    tun.player_w, tun.player_h)

        trig_x = h.get("trigger_x", h.get("drop_trigger_x"))
        entry_clear = 0.0
        if period:
            # Longest clear run at the entry point over one period.
            step = 0.05
            n = max(1, int(period / step))
            run, best = 0.0, 0.0
            for k in range(n + 1):
                t = k * step
                trig = 0.0 if trig_x is not None else None
                if not self._hazard_lethal_at(h, prect_at(0.0), t, trig):
                    run += step
                    best = max(best, run)
                else:
                    run = 0.0
            entry_clear = best
        # Try start offsets across one period (or t=0 for triggered).
        starts = [i * 0.1 for i in range(int((period or 0.1) / 0.1) + 1)] \
            if period else [0.0]
        for t0 in starts:
            clean = True
            steps = max(1, int(duration / 0.05))
            trig_time = None
            prev_x = None
            for k in range(steps + 1):
                t = t0 + k * 0.05
                frac = min(1.0, k * 0.05 / duration) if duration > 0 else 1.0
                fx = xs(frac)
                if trig_x is not None and trig_time is None and prev_x is not None:
                    if (prev_x - float(trig_x)) * (fx - float(trig_x)) <= 0 \
                            and fx != prev_x:
                        trig_time = t
                prev_x = fx
                if self._hazard_lethal_at(h, prect_at(frac), t, trig_time):
                    clean = False
                    break
            if clean:
                if period:
                    return True, entry_clear, \
                        "clean crossing from t0=%.1fs; entry clear %.2fs" \
                        % (t0, entry_clear)
                return True, entry_clear, "clean crossing (triggered hazard)"
        return False, entry_clear, \
            "no clean crossing in one period; entry clear %.2fs" % entry_clear

    def _check_timed_hazard_crossing(self, h, seg, top, is_edge, edge):
        """Check one timed hazard on one walking segment / edge corridor.

        seg: (x1, x2) crossed at feet level `top` (walking) or along the
        jump arc (edge). Returns (ok, reason)."""
        tun = self.tun
        period = hazard_period(h)
        if h["type"] == "saw":
            bb = saw_swept_bbox(h)
            zx1 = max(min(seg), bb[0] - tun.player_w / 2.0)
            zx2 = min(max(seg), bb[0] + bb[2] + tun.player_w / 2.0)
        elif h["type"] == "hanging_pillar":
            zx1 = float(h["x"]) - tun.player_w / 2.0
            zx2 = float(h["x"]) + float(h["w"]) + tun.player_w / 2.0
        else:
            zx1 = float(h["x"]) - tun.player_w / 2.0
            zx2 = float(h["x"]) + float(h["w"]) + tun.player_w / 2.0
        x1, x2 = min(seg), max(seg)
        zx1, zx2 = max(zx1, x1), min(zx2, x2)
        if zx2 <= zx1:
            return True, "hazard does not intersect segment"
        direction = 1 if seg[1] >= seg[0] else -1
        if is_edge:
            (tx, ty), (lx, ly) = edge["takeoff"], edge["land"]
            dist = abs(lx - tx) or 1.0
            duration = dist / tun.run_speed
            arc = list(self._arc_samples(tx, ty, lx, ly, n=21))

            def xs(f, arc=arc):
                i = min(len(arc) - 1, int(f * (len(arc) - 1)))
                return arc[i][0]

            def ys(f, arc=arc):
                i = min(len(arc) - 1, int(f * (len(arc) - 1)))
                return arc[i][1]
        else:
            start = zx1 if direction > 0 else zx2
            end = zx2 if direction > 0 else zx1
            duration = abs(end - start) / tun.run_speed

            def xs(f, s=start, e=end):
                return s + (e - s) * f

            def ys(f, top=top):
                return top
        clean, window, detail = self._crossing_simulation(
            h, xs, ys, max(duration, 0.05), period)
        if is_edge:
            if not clean:
                return False, "timed %s: %s" % (h["type"], detail)
            if period and window < tun.min_window:
                return False, ("timed %s: safe window %.2fs < %.2fs "
                               "(%s)" % (h["type"], window, tun.min_window,
                                         detail))
            return True, "timed %s ok: %s" % (h["type"], detail)
        # Walking segment: try walking through, then jumping over the
        # zone (the real move for head-height saws / floor spike strips).
        walk_ok = clean and (not period or window >= tun.min_window)
        if walk_ok:
            return True, "timed %s ok: %s" % (h["type"], detail)
        jump_detail = "jump-over not attempted"
        jump_ok = False
        jump_window = 0.0
        tx0 = max(x1, zx1 - 30.0)
        lx0 = min(x2, zx2 + 30.0)
        span = lx0 - tx0
        if 40.0 <= span <= tun.max_jump_dist:
            arc = list(self._arc_samples(tx0, top, lx0, top, n=21))
            jdur = span / tun.run_speed

            def jxs(f, arc=arc):
                return arc[min(len(arc) - 1, int(f * (len(arc) - 1)))][0]

            def jys(f, arc=arc):
                return arc[min(len(arc) - 1, int(f * (len(arc) - 1)))][1]

            jclean, jump_window, jump_detail = self._crossing_simulation(
                h, jxs, jys, max(jdur, 0.05), period)
            jump_ok = jclean and (not period
                                  or jump_window >= tun.min_window)
            if jump_ok:
                return True, "timed %s ok via jump-over: %s" \
                    % (h["type"], jump_detail)
        elif span > tun.max_jump_dist:
            jump_detail = ("jump-over impossible: span %.0f > max jump "
                           "distance %.0f" % (span, tun.max_jump_dist))
        if (clean or jump_ok or "clean crossing" in jump_detail) \
                and period and max(window, jump_window) < tun.min_window:
            return False, ("timed %s: safe window %.2fs < %.2fs "
                           "(walk: %s; jump-over: %s)"
                           % (h["type"], max(window, jump_window),
                              tun.min_window, detail, jump_detail))
        return False, "timed %s: no clean crossing (walk: %s; jump-over: %s)" \
            % (h["type"], detail, jump_detail)

    def _check_node_timing(self, node, seg_len):
        """Dashed / falling / tilting / moving platform timing on a path."""
        p = self.lv["platforms"][node]
        kind = p["kind"]
        tun = self.tun
        cross = max(seg_len, tun.min_landing) / tun.run_speed
        if kind == "dashed":
            on = float(p["on_time"])
            if on < tun.min_window:
                return False, ("dashed platforms[%d]: solid window %.2fs < "
                               "%.2fs" % (node, on, tun.min_window))
            if on < cross:
                return False, ("dashed platforms[%d]: on_time %.2fs < "
                               "cross time %.2fs" % (node, on, cross))
            return True, "dashed ok"
        if kind in ("falling", "tilting"):
            st = float(p["stand_time"])
            if st < cross:
                return False, ("%s platforms[%d]: stand_time %.2fs < "
                               "cross time %.2fs -- cannot cross within "
                               "stand_time" % (kind, node, st, cross))
            return True, "%s ok (stand %.2fs >= cross %.2fs)" % (kind, st,
                                                                 cross)
        if kind == "moving":
            if float(p["period"]) / 2.0 < tun.min_window:
                return False, ("moving platforms[%d]: half-period %.2fs < "
                               "%.2fs" % (node, float(p["period"]) / 2.0,
                                          tun.min_window))
            return True, "moving ok (autopilot decides exact timing)"
        return True, "solid"

    def check_path_windows(self, path):
        """Window checks for one candidate path. Returns list of failures
        (empty = path is viable) and notes."""
        tun = self.tun
        failures, notes = [], []
        lv = self.lv
        # Walking segments + edge crossings.
        for si, node in enumerate(path):
            p = self.lv["platforms"][node]
            top = float(p["y"])
            # Entry / exit x on this platform.
            if si == 0:
                entry_x = float(lv["spawn"]["x"])
            else:
                entry_x = self.edges[(path[si - 1], node)]["land"][0]
            if si == len(path) - 1:
                exit_x = float(lv["door"]["x"])
            else:
                exit_x = self.edges[(node, path[si + 1])]["takeoff"][0]
            seg = (entry_x, exit_x)
            seg_len = abs(exit_x - entry_x)
            ok, msg = self._check_node_timing(node, seg_len)
            if not ok:
                failures.append(msg)
            band = (min(seg), top - tun.player_h, max(seg_len, 1.0),
                    tun.player_h)
            for hi, h in enumerate(lv["hazards"]):
                t = h.get("type")
                if t == "dotted_line":
                    continue
                # Static hazards on the walking band.
                if t == "spikes" and "period" not in h \
                        and "trigger_x" not in h:
                    r = (float(h["x"]), float(h["y"]), float(h["w"]),
                         float(h["h"]))
                    if rects_overlap(r, band):
                        if h.get("dir", "up") == "up" \
                                and self._ground_sitting_spikes(h):
                            notes.append("jumpable floor spikes on walk")
                        else:
                            failures.append(
                                "walking path on platforms[%d] blocked by "
                                "static spikes hazards[%d]" % (node, hi))
                elif t == "spiked_column":
                    r = (float(h["x"]), float(h["y"]), float(h["w"]),
                         float(h["h"]))
                    if rects_overlap(r, band):
                        clearable = r[1] >= top - tun.max_rise \
                            and r[2] <= tun.max_gap
                        if clearable:
                            notes.append("jumpable spiked column on walk")
                        else:
                            failures.append(
                                "walking path on platforms[%d] blocked by "
                                "spiked_column hazards[%d]" % (node, hi))
                elif t == "saw" and "path" not in h and "swing" not in h:
                    if circle_rect_overlap(float(h["x"]), float(h["y"]),
                                           float(h["r"]), band):
                        # Jump-over test across the saw on this platform.
                        cx, r = float(h["x"]), float(h["r"])
                        tx, lx = cx - r - 30, cx + r + 30
                        if tx < float(p["x"]) or lx > float(p["x"]) \
                                + float(p["w"]):
                            failures.append(
                                "walking path on platforms[%d] blocked by "
                                "static saw hazards[%d]" % (node, hi))
                        else:
                            blocked = False
                            for (sx, sy) in self._arc_samples(tx, top, lx,
                                                              top):
                                prect = (sx - tun.player_w / 2.0,
                                         sy - tun.player_h, tun.player_w,
                                         tun.player_h)
                                if circle_rect_overlap(
                                        cx, float(h["y"]), r, prect):
                                    blocked = True
                                    break
                            if blocked:
                                failures.append(
                                    "walking path on platforms[%d] blocked "
                                    "by static saw hazards[%d] (jump arc "
                                    "does not clear it)" % (node, hi))
                elif t == "hanging_pillar":
                    r = (float(h["x"]), float(h["y"]), float(h["w"]),
                         float(h["h"]))
                    if rects_overlap(r, band):
                        failures.append(
                            "walking path on platforms[%d] blocked by "
                            "hanging pillar hazards[%d] at rest" % (node, hi))
                # Timed hazards intersecting the walking band.
                timed_here = False
                if t == "saw" and ("path" in h or "swing" in h):
                    timed_here = rects_overlap(saw_swept_bbox(h), band)
                elif t == "spikes" and ("period" in h or "trigger_x" in h):
                    r = (float(h["x"]), float(h["y"]), float(h["w"]),
                         float(h["h"]))
                    timed_here = rects_overlap(r, band)
                elif t == "hanging_pillar":
                    r = (float(h["x"]), float(h["y"]), float(h["w"]),
                         float(h["h"]))
                    fall_col = (r[0], r[1], r[2], tun.bar_y - r[1])
                    timed_here = rects_overlap(fall_col, band)
                elif "trigger_x" in h:
                    r = (float(h["x"]), float(h["y"]), float(h["w"]),
                         float(h["h"]))
                    timed_here = rects_overlap(r, band)
                if timed_here:
                    ok, msg = self._check_timed_hazard_crossing(
                        h, seg, top, False, None)
                    if not ok:
                        failures.append(msg)
                    else:
                        notes.append(msg)
        # Edge-corridor timed crossings.
        for si in range(len(path) - 1):
            edge = self.edges[(path[si], path[si + 1])]
            for item in edge["timed"]:
                if isinstance(item, str):
                    continue  # platform timing handled above
                h = lv["hazards"][item]
                seg = (edge["takeoff"][0], edge["land"][0])
                ok, msg = self._check_timed_hazard_crossing(
                    h, seg, edge["takeoff"][1], True, edge)
                if not ok:
                    failures.append("edge %d->%d: %s"
                                    % (path[si], path[si + 1], msg))
                else:
                    notes.append("edge %d->%d: %s"
                                 % (path[si], path[si + 1], msg))
        return failures, notes

    def check_connectivity(self):
        err = connectivity_error(
            self.lv.get("platforms", []), self.lv.get("spawn", {}),
            self.lv.get("door", {}), self.tun.width, self.tun.bar_y,
            self.tun.door_w, self.tun.door_h)
        if err is not None:
            self.errors.append(err)

    def check_reachability(self, max_paths=300, with_connectivity=True):
        if with_connectivity:
            self.check_connectivity()
        if not getattr(self, "spawn_nodes", None) \
                or not getattr(self, "door_nodes", None):
            self.errors.append("reachability not evaluated: spawn/door "
                               "ground check failed")
            return
        self.build_graph()
        paths = self.enumerate_paths(cap=max_paths)
        if not paths:
            # Explain: list which door-ward edges were missing is
            # expensive; report the graph summary instead.
            self.errors.append(
                "UNREACHABLE: no platform-graph path from spawn platform(s) "
                "%s to door platform(s) %s under the frozen envelope "
                "(rise<=%.0f gap<=%.0f landing>=%.0f run-up>=%.0f); "
                "%d edges found" % (self.spawn_nodes, self.door_nodes,
                                    self.tun.max_rise, self.tun.max_gap,
                                    self.tun.min_landing, self.tun.min_runup,
                                    len(self.edges)))
            return
        best_failures = None
        for path in paths:
            failures, notes = self.check_path_windows(path)
            if not failures:
                self.solution = path
                self.solution_edges = [
                    self.edges[(path[i], path[i + 1])]
                    for i in range(len(path) - 1)]
                self.notes.extend(notes)
                self.notes.append("solution path: %s"
                                  % "->".join(map(str, path)))
                return
            if best_failures is None:
                best_failures = failures
        self.solution = paths[0]  # for signature purposes only
        self.solution_edges = [self.edges[(paths[0][i], paths[0][i + 1])]
                               for i in range(len(paths[0]) - 1)]
        for f in (best_failures or ["no viable path"]):
            self.errors.append("no viable path: %s" % f)

    # -- (f) signatures ----------------------------------------------------
    def signature_parts(self):
        """(layout, traps, solution) -- palette excluded, mirror-normalised.
        Layout: canonical platform nodes + graph edges. Traps: hazard
        multiset with normalised position buckets + trap params.
        Solution: jump sequence + spawn/door anchors. Decorations
        are EXCLUDED (rule 10): only platforms/hazards/spawn/door
        feed the signature, so two levels differing only in
        decorations are duplicates."""
        tun = self.tun
        W = tun.width
        plats = self.lv["platforms"]

        def layout_sig(mirror):
            nodes = []
            for p in plats:
                x = W - float(p["x"]) - float(p["w"]) if mirror \
                    else float(p["x"])
                nodes.append((qb(x, 16), qb(p["y"], 16), qb(p["w"], 16),
                              qb(p["h"], 16), p["kind"]))
            order = sorted(range(len(nodes)), key=lambda i: nodes[i])
            remap = {old: new for new, old in enumerate(order)}
            nodes = tuple(nodes[i] for i in order)
            edges = set()
            for (a, b) in self.edges:
                edges.add((remap[a], remap[b]))
            return (nodes, tuple(sorted(edges)))

        def trap_sig(mirror):
            items = []
            for p in plats:
                if p["kind"] == "dashed":
                    items.append(("platform", "dashed",
                                  round(float(p["period"]), 1),
                                  round(float(p["phase"]), 1),
                                  round(float(p["on_time"]), 1)))
                elif p["kind"] in ("falling", "tilting"):
                    items.append(("platform", p["kind"],
                                  round(float(p["stand_time"]), 1)))
                elif p["kind"] == "moving":
                    items.append(("platform", "moving", qb(p["dx"], 16),
                                  qb(p["dy"], 16),
                                  round(float(p["period"]), 1)))
            for h in self.lv["hazards"]:
                if h.get("type") == "dotted_line":
                    continue  # warning only; derived from linked hazard
                x = W - float(h["x"]) - float(h["w"]) if mirror \
                    else float(h["x"])
                base = [h["type"], qb(x, 32), qb(h["y"], 32),
                        qb(h["w"], 32), qb(h["h"], 32)]
                t = h["type"]
                if t == "spikes":
                    base.append(h.get("dir", "up"))
                    if "period" in h:
                        base += [round(float(h["period"]), 1),
                                 round(float(h.get("phase", 0.0)), 1),
                                 round(float(h["on_time"]), 1)]
                elif t == "saw":
                    base.append(qb(h["r"], 8))
                    if "path" in h:
                        x2 = W - float(h["path"]["x2"]) if mirror \
                            else float(h["path"]["x2"])
                        base += [qb(x2, 32), qb(h["path"]["y2"], 32),
                                 round(float(h["period"]), 1)]
                    elif "swing" in h:
                        s = h["swing"]
                        pvx = W - float(s["pivot_x"]) if mirror \
                            else float(s["pivot_x"])
                        base += [qb(pvx, 32), qb(s["pivot_y"], 32),
                                 round(float(s["arc_deg"]), 1),
                                 round(float(s["period"]), 1)]
                elif t == "hanging_pillar":
                    if "drop_trigger_x" in h:
                        tx = W - float(h["drop_trigger_x"]) if mirror \
                            else float(h["drop_trigger_x"])
                        base.append(("trigger", qb(tx, 32)))
                    else:
                        base.append(("periodic", round(float(h["period"]), 1),
                                     round(float(h.get("phase", 0.0)), 1)))
                    base.append(round(float(h.get("drop_speed",
                                                  DEFAULT_DROP_SPEED)), 0))
                if "trigger_x" in h:
                    tx = W - float(h["trigger_x"]) if mirror \
                        else float(h["trigger_x"])
                    base.append(("trigger_x", qb(tx, 32),
                                 round(float(h.get("delay", 0.0)), 2)))
                items.append(tuple(base))
            return tuple(sorted(Counter(items).items()))

        def solution_sig(mirror):
            sp, dr = self.lv["spawn"], self.lv["door"]
            sx = W - float(sp["x"]) if mirror else float(sp["x"])
            dx = W - float(dr["x"]) if mirror else float(dr["x"])
            anchors = (qb(sx, 32), qb(sp["y"], 32), qb(dx, 32),
                       qb(dr["y"], 32))
            if not self.solution_edges and not self.solution:
                return (anchors, ("UNREACHABLE",))
            jumps = []
            for e in self.solution_edges:
                ddx = e["land"][0] - e["takeoff"][0]
                if mirror:
                    ddx = -ddx
                jumps.append((qb(ddx, 32), qb(e["rise"], 16),
                              self.lv["platforms"][e["a"]]["kind"],
                              self.lv["platforms"][e["b"]]["kind"]))
            return (anchors, tuple(jumps))

        layout = min(layout_sig(False), layout_sig(True))
        traps = min(trap_sig(False), trap_sig(True))
        solution = min(solution_sig(False), solution_sig(True))
        return layout, traps, solution

    def run(self, max_paths=300, with_connectivity=True):
        self.check_fields()
        if self.structural_ok:
            # Deeper checks must never crash on malformed data: a check
            # that aborts is recorded as a failure with its reason.
            for fn in (self.check_bounds,
                       self.check_hud_keepout,
                       self.check_grounding,
                       self.check_hazard_solid_overlap,
                       self.check_density_floor,
                       self.check_decorations,
                       self.check_safe_zones_and_ground):
                try:
                    fn()
                except Exception as exc:
                    self.errors.append("%s aborted: %s" % (fn.__name__, exc))
            try:
                self.check_reachability(max_paths=max_paths,
                                        with_connectivity=with_connectivity)
            except Exception as exc:
                self.errors.append("check_reachability aborted: %s" % exc)
        return self


def pa_kind(p):
    return p.get("kind")


# --------------------------------------------------------------------------
# Whole-file verification + dedupe
# --------------------------------------------------------------------------

def verify_levels(data, tun, max_paths=300):
    """Returns (results, clusters, top_errors). results: list of dicts."""
    top_errors = []
    if not isinstance(data, dict):
        return [], [], ["top level is not an object"]
    if data.get("schema_version") != SCHEMA_VERSION:
        top_errors.append("schema_version %r != frozen %d"
                          % (data.get("schema_version"), SCHEMA_VERSION))
    if data.get("tuning_version") != tun.version:
        top_errors.append("tuning_version %r != tuning.json version %r"
                          % (data.get("tuning_version"), tun.version))
    levels = data.get("levels")
    if not isinstance(levels, list) or not levels:
        top_errors.append("levels must be a non-empty array")
        return [], [], top_errors
    seen_ids = set()
    results = []
    for idx, lv in enumerate(levels):
        chk = LevelCheck(lv, idx, tun).run(max_paths=max_paths)
        lid = lv.get("id") if isinstance(lv, dict) else None
        if lid in seen_ids:
            chk.errors.append("duplicate level id %r" % lid)
        if isinstance(lid, str):
            seen_ids.add(lid)
        try:
            layout, traps, solution = chk.signature_parts()
        except Exception as exc:  # never let signatures mask real errors
            layout, traps, solution = (), (), ()
            chk.errors.append("signature computation failed: %s" % exc)
        results.append({"index": idx, "id": lid, "errors": chk.errors,
                        "notes": chk.notes, "layout": layout,
                        "traps": traps, "solution": solution,
                        "density": chk.density,
                        "duplicate_of": None})
    # Dedupe: distinct iff signatures differ AND >= 2 dims differ.
    n = len(results)
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    for i in range(n):
        for j in range(i + 1, n):
            dims = sum([results[i]["layout"] != results[j]["layout"],
                        results[i]["traps"] != results[j]["traps"],
                        results[i]["solution"] != results[j]["solution"]])
            sig_diff = dims > 0
            if not (sig_diff and dims >= 2):
                union(i, j)
    clusters = {}
    for i in range(n):
        clusters.setdefault(find(i), []).append(i)
    dup_clusters = [sorted(v) for v in clusters.values() if len(v) > 1]
    for cl in dup_clusters:
        keeper = cl[0]
        for other in cl[1:]:
            dims_diff = sum(
                [results[other]["layout"] != results[keeper]["layout"],
                 results[other]["traps"] != results[keeper]["traps"],
                 results[other]["solution"] != results[keeper]["solution"]])
            results[other]["duplicate_of"] = results[keeper]["id"]
            results[other]["errors"].append(
                "DUPLICATE of %s: signatures %s and only %d/3 dimensions "
                "differ (needs >= 2); cluster: %s"
                % (results[keeper]["id"],
                   "differ" if dims_diff > 0 else "are identical",
                   dims_diff,
                   ", ".join(str(results[k]["id"]) for k in cl)))
    for r in results:
        r["pass"] = not r["errors"]
    return results, dup_clusters, top_errors


# --------------------------------------------------------------------------
# Self-test on fixtures
# --------------------------------------------------------------------------

SELFTESTS = [
    # (fixture file, expect_all_pass, required reason substring or None)
    ("positive.json", True, None),
    ("negative_impossible.json", False, "unreachable"),
    ("negative_spawn_spikes.json", False, "safe zone"),
    ("negative_duplicate.json", False, "duplicate"),
    ("negative_mirror.json", False, "duplicate"),
    ("negative_unknown_kind.json", False, "unknown kind"),
    ("negative_timed.json", False, "window"),
    ("negative_oob.json", False, "bounds"),
    ("negative_floating.json", False, "grounding"),
    ("negative_keepout.json", False, "keep-out"),
    ("negative_unseated_spikes.json", False, "seated"),
    ("negative_empty_middle.json", False, "density"),
    ("positive_grounded.json", True, None),
    ("negative_sealed_pocket.json", False, "connectivity"),
    ("positive_connectivity.json", True, None),
    ("negative_core_middle_empty.json", False, "core-middle"),
    ("positive_core_middle.json", True, None),
    ("negative_overlap.json", False, "overlap"),
    ("positive_seated_contact.json", True, None),
    ("negative_deco_floating.json", False, "deco:"),
    ("negative_deco_hazard_overlap.json", False, "deco:"),
    ("negative_deco_keepout.json", False, "deco:"),
    ("positive_deco.json", True, None),
    ("positive_deco_connectivity.json", True, None),
    ("positive_no_decorations.json", True, None),
]


def run_selftest(repo_root):
    tun_path = repo_root / "godot" / "data" / "tuning.json"
    tun = Tuning(json.loads(tun_path.read_text(encoding="utf-8")))
    fix_dir = Path(__file__).resolve().parent / "fixtures"
    rows = []
    ok_all = True
    for fname, expect_pass, needle in SELFTESTS:
        data = json.loads((fix_dir / fname).read_text(encoding="utf-8"))
        results, clusters, top_errors = verify_levels(data, tun)
        all_pass = not top_errors and all(r["pass"] for r in results)
        reasons = " ".join(e for r in results for e in r["errors"]).lower()
        if needle:
            good = (all_pass == expect_pass) and (needle in reasons)
        else:
            good = all_pass == expect_pass
        ok_all = ok_all and good
        rows.append((fname, expect_pass, all_pass, needle,
                     "OK" if good else "MISMATCH",
                     ("%d/%d pass" % (
                         sum(1 for r in results if r["pass"]),
                         len(results))) if results else "top-level error",
                     "; ".join(e for r in results for e in r["errors"])[:160]))
    print("check_levels.py --selftest")
    for fname, exp, got, needle, status, counts, reasons in rows:
        print("  %-32s expect_pass=%-5s got_pass=%-5s needle=%-12s %s [%s]"
              % (fname, exp, got, needle, status, counts))
        if reasons:
            print("      reasons: %s" % reasons)
    print("SELFTEST %s (%d/%d expectations met)"
          % ("PASS" if ok_all else "FAIL",
             sum(1 for r in rows if r[4] == "OK"), len(rows)))
    return 0 if ok_all else 1


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="Trap Tower static verifier")
    ap.add_argument("--levels", default=None,
                    help="levels.json (default: repo godot/data/levels.json)")
    ap.add_argument("--tuning", default=None,
                    help="tuning.json (default: repo godot/data/tuning.json)")
    ap.add_argument("--json-out", default=None,
                    help="write full JSON report to this path")
    ap.add_argument("--quiet", action="store_true",
                    help="only print totals")
    ap.add_argument("--density-report", action="store_true",
                    help="print per-level middle-band density stats")
    ap.add_argument("--max-paths", type=int, default=300)
    ap.add_argument("--selftest", action="store_true",
                    help="run fixture expectations and exit")
    args = ap.parse_args(argv)

    repo_root = Path(__file__).resolve().parent.parent
    if args.selftest:
        return run_selftest(repo_root)

    levels_path = Path(args.levels) if args.levels \
        else repo_root / "godot" / "data" / "levels.json"
    tuning_path = Path(args.tuning) if args.tuning \
        else repo_root / "godot" / "data" / "tuning.json"
    try:
        tun = Tuning(json.loads(tuning_path.read_text(encoding="utf-8")))
    except Exception as exc:
        print("ERROR: cannot load tuning.json %s: %s" % (tuning_path, exc),
              file=sys.stderr)
        return 2
    try:
        raw = levels_path.read_bytes()
        data = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        print("ERROR: cannot load levels.json %s: %s" % (levels_path, exc),
              file=sys.stderr)
        return 2
    sha = hashlib.sha256(raw).hexdigest()
    results, clusters, top_errors = verify_levels(data, tun,
                                                  max_paths=args.max_paths)
    n_pass = sum(1 for r in results if r["pass"])
    if not args.quiet:
        for r in results:
            if r["pass"]:
                print("%s: PASS" % r["id"])
            else:
                print("%s: FAIL" % r["id"])
                for e in r["errors"]:
                    print("    - %s" % e)
    if top_errors:
        for e in top_errors:
            print("TOP-LEVEL ERROR: %s" % e)
    if clusters:
        for cl in clusters:
            print("DUPLICATE CLUSTER: %s"
                  % ", ".join(str(results[k]["id"]) for k in cl))
    print("TOTAL: %d/%d levels passed (levels.json sha256 %s)"
          % (n_pass, len(results), sha))
    if args.density_report:
        for r in results:
            d = r.get("density") or {}
            print("DENSITY %s: rects=%s width=%s hazards=%s %s"
                  % (r["id"], d.get("rect_count"), d.get("combined_width"),
                     d.get("hazard_count"),
                     "PASS" if d.get("pass") else "FAIL"))
    if args.json_out:
        out = {"levels_path": str(levels_path), "levels_sha256": sha,
               "tuning_path": str(tuning_path),
               "top_errors": top_errors,
               "duplicate_clusters": [[results[k]["id"] for k in cl]
                                      for cl in clusters],
               "total": len(results), "passed": n_pass,
               "levels": [{"id": r["id"], "pass": r["pass"],
                           "errors": r["errors"], "notes": r["notes"],
                           "density": r.get("density"),
                           "duplicate_of": r["duplicate_of"]}
                          for r in results]}
        Path(args.json_out).write_text(json.dumps(out, indent=2),
                                       encoding="utf-8")
        print("JSON report: %s" % args.json_out)
    if top_errors:
        return 2
    return 0 if n_pass == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
