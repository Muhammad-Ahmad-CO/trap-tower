#!/usr/bin/env python3
"""Trap Tower static level verifier (Lane B).

Implements LEVEL_SCHEMA.md v3 (FROZEN) exactly. Loads
godot/data/levels.json + godot/data/tuning.json and checks:

  (a) schema/tuning versions, required fields, unknown kind/type = hard error
      (`dotted_line` is an unknown type in v3 and hard-errors)
  (b) geometry bounds (0..1280 / 90..720), platform w/h minima;
      floor = bottom at y=720 (FLOOR_Y = viewport.height)
  (c) spawn/door safe zones (40px) + standing on solid ground
  (d) platform-graph reachability from spawn to door using the FROZEN
      schema envelope (rise <= 45, gap <= 80, landing >= 48,
      run-up >= 24), with per-edge reasoning; conservative
      pre-filter only. PLUS
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
  (g) GROUNDING (rule 7): no floating geometry -- solid fixpoint
      (floor = bottom at y=720), shaft-flanked/resting specials,
      seated spikes, saw disc touch at at least one swept centre
      (moving) / at its centre (static), swing pivots inside
      grounded beams. Rect hazards (spikes,
      spiked_column) must not area-overlap solid rects beyond the
      4px seating tolerance (saws and hanging_pillar exempt).
  (h) HUD KEEP-OUT (rule 8): no drawn extent in y < 90; spawn feet
      y >= 134; door base y >= 174.
  (i) DENSITY FLOOR (rule 9): >= 2 solid rects in the middle band
      y 170..550 with combined width >= 160px, PLUS a core-middle
      floor: >= 2 rects (solid platforms AND/OR decorations,
      counted together) intersecting y 310..510 with combined
      width >= 160px. Floor slabs (rects touching y=720 and
      spanning >= 50% of the width) and edge walls (x == 0 or
      x + w == 1280) are EXCLUDED from both counts. The checker
      ALSO reports a report-only mass metric (solid area fraction
      + per-column solid coverage) for every level; there is NO
      hard mass threshold.
  (k) HAZARD-FAMILY PURITY (rule 11): saw hazards appear ONLY in
      saw-family archetypes (D03, D08, D09, D10, D33, D37, D41)
      and mix/final archetypes (D26, D42, D43, D44). Spike-family
      archetypes carry spikes, pits, and pillars only -- no saws.
      Archetype is read from the `variation` field (D{nn}S{V}V{v});
      levels without that provenance pattern are not family-checked.

  Archetype -> family table (rule 11; the generator publishes the
  same table -- the checker enforces it):
    saw-family (saws allowed): D03 saw-runs, D08 swing-saws,
      D09 patrol-saws, D10 gap-saws, D33 saw-fields,
      D37 saw-corridors, D41 final-tower-saws.
    mix/final (saws allowed): D26 grand-mixes, D42 final-skyline,
      D43 final-reversed, D44 final-mega.
    spike-family (NO saws; spikes/pits/pillars only): D01 pitfall,
      D02 spike-hops, D04 popup-spikes, D05 triggered-spikes,
      D06 triggered-pillars, D07 periodic-pillars,
      D11 spiked-columns, D12 dashed-chains, D13 falling-floors,
      D14 tilting-blocks, D15 moving-bridges, D16 mover-chains,
      D17 ceiling-spikes, D18 wall-spikes, D19 step-climbs,
      D20 double-gaps, D21 pit-bridges, D22 gauntlets,
      D23 timed-mixes, D24 pillar-alleys, D25 pillar-forests,
      D27 mover-lifts, D28 tower-descents, D29 reversed-runs,
      D30 skyline-city, D31 drop-shafts, D32 zigzag-descents,
      D34 trigger-pits, D35 spike-forests, D36 ceiling-gauntlets,
      D38 timed-corridors, D39 dashed-towers, D40 column-forests.
  (j) DECORATIONS (rule 10): the optional `decorations` array, if
      present, must satisfy the attachment chain, HUD keep-out,
      no-hazard/spawn/door-overlap, and bounds rules (error prefix
      `deco:`). Decorations are ignored by reachability,
      connectivity, and dedupe signatures.
  (l) Round 4, Rule 12 (chained-pair window floor, harness only) +
      column span test: a spiked column is passable only if the
      span test passes (w + 15 <= max_jump_dist *
      sqrt(1 - h/apex), using the checker's THEORETICAL tuning
      values) AND a takeoff exists whose flight lands past the
      column, with the takeoff ground extending under the takeoff
      point. Chained dir-up strip pairs (same platform, gap <
      97.2px game-true air distance) fail unless W_chain >= 15px
      (D14 clean floor); decoupled pairs (g + w2 > 97.2) are
      judged as single strips.

Physics/viewport/palette numbers are loaded from tuning.json. The
door size (36x54), the harness envelope (rise 45 / gap 80 /
landing 48 / run-up 24 / window 0.7s), and FLOOR_Y (720 =
viewport.height) are SCHEMA CONSTANTS from LEVEL_SCHEMA.md v3 and
are defined here -- the tuning.json `control_bar` and `door`
entries are DEPRECATED and MUST NOT be read (grep tripwire proves
zero reads). The tuning.json `harness_envelope` entry is likewise
NOT read: the frozen v3 envelope lives in this file. Other numeric
constants come from LEVEL_SCHEMA.md itself (safe zone 40px, ground
tolerance 4px, platform h >= 16, saw radius 18..40, timing minima),
each cited where defined.

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
SCHEMA_VERSION = 3          # LEVEL_SCHEMA.md v3: top-level schema_version
SAFE_ZONE = 40.0            # LEVEL_SCHEMA.md: spawn/door safe zone, px
GROUND_TOL = 4.0            # LEVEL_SCHEMA.md: platform top within 4px
HUD_KEEPOUT_Y = 90.0        # LEVEL_SCHEMA.md rule 8: no drawn extent y < 90
SPAWN_MIN_Y = 134.0         # LEVEL_SCHEMA.md rule 8: spawn feet y >= 134
DOOR_MIN_Y = 174.0          # LEVEL_SCHEMA.md rule 8: door base y >= 174
MIN_PILLAR_W = 48.0         # LEVEL_SCHEMA.md rule 7: pillar w >= 48
SHAFT_FLANK_GAP = 8.0       # LEVEL_SCHEMA.md rule 7: shaft columns <= 8px
DENSITY_BAND_TOP = 170.0    # LEVEL_SCHEMA.md v3 rule 9: middle band y 170..550
DENSITY_BAND_BOTTOM = 550.0
DENSITY_MIN_RECTS = 2       # LEVEL_SCHEMA.md rule 9: >= 2 solid rects
DENSITY_MIN_WIDTH = 160.0   # LEVEL_SCHEMA.md rule 9: combined width >= 160
CORE_BAND_TOP = 310.0       # LEVEL_SCHEMA.md v3 rule 9: core-middle y 310..510
CORE_BAND_BOTTOM = 510.0
CORE_MIN_RECTS = 2          # LEVEL_SCHEMA.md rule 9: >= 2 non-edge rects
CORE_MIN_WIDTH = 160.0      # LEVEL_SCHEMA.md rule 9: combined width >= 160
OVERLAP_TOL = 4.0           # LEVEL_SCHEMA.md rule 7: seating tolerance
DECO_MIN_W = 48.0           # LEVEL_SCHEMA.md Decorations: w >= 48
DECO_MIN_H = 16.0           # LEVEL_SCHEMA.md Decorations: h >= 16
DECO_ATTACH_TOL = 4.0       # LEVEL_SCHEMA.md rule 10: edge-adjacent
                            # within 4px counts as attached
MIN_PLATFORM_H = 16.0       # LEVEL_SCHEMA.md: platform h >= 16
SAW_R_MIN, SAW_R_MAX = 18.0, 40.0   # LEVEL_SCHEMA.md v3: saw r 18..40
DASHED_MIN_ON = 0.9         # LEVEL_SCHEMA.md: dashed on_time >= 0.9
DASHED_MIN_OFF = 0.5        # LEVEL_SCHEMA.md: period - on_time >= 0.5
FALL_MIN_STAND = 0.45       # LEVEL_SCHEMA.md: falling/tilting stand_time
MOVING_MIN_PERIOD = 1.6     # LEVEL_SCHEMA.md: moving/saw period >= 1.6
MIN_DELAY = 0.25            # LEVEL_SCHEMA.md: trigger delay >= 0.25
PILLAR_RISE_TIME = 1.0      # LEVEL_SCHEMA.md: periodic pillar rises over 1.0s
DEFAULT_DROP_SPEED = 700.0  # LEVEL_SCHEMA.md: drop_speed default 700 px/s
CONNECTIVITY_CELL = 8.0     # LEVEL_SCHEMA.md rule 5: 8px flood-fill grid
HERO_RECT_W = 15.0          # LEVEL_SCHEMA.md v3: hero collision ~15x39
HERO_RECT_H = 39.0          # (defaults; connectivity uses tuning player size)
DOOR_W = 36.0               # LEVEL_SCHEMA.md v3 Door: SCHEMA CONSTANT 36x54
DOOR_H = 54.0               # (tuning.json `door` entry is DEPRECATED)
# Frozen v3 harness envelope (LEVEL_SCHEMA.md rule 5): measured probe
# values x 0.85, Lead-frozen. NOT read from tuning.json.
ENVELOPE_MAX_RISE = 45.0
ENVELOPE_MAX_GAP = 80.0
ENVELOPE_MIN_LANDING = 48.0
ENVELOPE_MIN_RUNUP = 24.0
ENVELOPE_MIN_WINDOW = 0.7
# Max clearable up-spike strip width (Round 3, pilot-gate-r2 §8A):
# engine-measured clearance window 84.7px minus hero half-width 7.5px
# (x2) gives max clearable flat-ground strip ~69.7px; the cap is set
# at 60px so a strip is jumpable with margin. Any wider up-strip is
# physically unjumpable however it is timed or seated.
MAX_UP_SPIKE_W = 60.0
# Stage 2 (Redesign Pass 2, Path C) — joint floor for the mixed moving-saw
# move (parent ruling C4, verification/pass2/C4-RULING.md; spec
# verification/pass2/stage2-checker-adaptation.md §7). The 0.7 s
# ENVELOPE_MIN_WINDOW does NOT apply to departure windows; the joint
# floor below is the operative departure floor. F1 takeoff width Wx >=
# 8.1 px (2 lattice frames), F2 departure-phase width Wt >= 0.10 s
# (6 frames), F3 centre clearance >= 4.05 px (1 lattice frame) — on
# BOTH grids (1 px and the 4.05 px lattice), jump-over subset only,
# centre combo. No threshold change without a physics proof.
MIXED_FLOOR_WX = 8.1
MIXED_FLOOR_WT = 0.10
MIXED_FLOOR_CLEAR = 4.05
# Stage 2 §1(iv)/S4: joint period (LCM over all timed hazards in the
# segment, in frames) above this cap makes the mixed move INAPPLICABLE
# (3600 frames = 60 s; without the cap the frozen-file LCM worst case
# is 5,250,960 frames per check). All timed periods on a mixed-move
# segment must be integer frames (period * 60 in Z); rounding is NOT
# permitted.
MIXED_JOINT_PERIOD_CAP_FRAMES = 3600
# Stage 2 §1(i)/probe: takeoff scan range around the saw swept zone
# (swept zone +/- 60 px, exactly as probe_mixed_trajectory.py).
MIXED_TAKEOFF_SCAN_PAD = 60.0
# Round 4, Rule 12 (new harness-only rule; LEVEL_SCHEMA.md v3 Rule 12
# is additive documentation -- no version bump): chained-pair window
# floor. Game-true air distance D = 97.2px (reconciled in
# verification/air-distance-reconciliation-r4.json: forced takeoff
# 154.8 -> landing 252.00; the planner's 93.15px hand-derivation is
# retired). Single-strip takeoff window width = 69.7 - w (engine
# probe; the discrete trajectory gives 69.55 - w, a 0.15px difference
# that flips no clean/marginal call). For two dir-up strips on the
# SAME platform with gap g < D, the chained window is
#   W_chain = min(69.7-w1, 69.7-w2, g-27.5, 166.9-w1-w2-g)
# (the four binding cases of W = W1 n ((L n W2) - D); the gap table
# is recorded in verification/pilot-census-r4.json). A pair is
# CHAINED only when the earliest landing after clearing the first
# strip is already at/past the second strip's takeoff window
# (g + w2 <= D): otherwise the hero lands before the window opens
# and runs in, and the pair is decoupled (each strip judged singly
# -- e.g. D02S3 50+50/g70, g+w2 = 120 > 97.2). A chained pair FAILS
# unless W_chain >= 15 (the D14 clean floor, not the 4.05px lattice
# floor). A 60+60 pair can never pass: W_chain <= 69.7-60 = 9.7.
CHAIN_MIN_WINDOW = 15.0
CHAIN_DECOUPLE_GAP = 97.2   # game-true air distance D (see above)
CHAIN_WINDOW_CONST = 69.7   # single-strip window constant (probe)
FLOOR_SLAB_MIN_WIDTH_FRAC = 0.5  # rule 9: slab spans >= 50% of width
MASS_GRID_CELL = 8.0        # mass-metric grid (report-only, rule 9)

PLATFORM_KINDS = {"solid", "dashed", "falling", "tilting", "moving"}
# v3: `dotted_line` REMOVED -- any occurrence is an unknown type.
HAZARD_TYPES = {"spikes", "saw", "spiked_column", "hanging_pillar"}
# Rule 11: archetype numbers allowed to carry saws (saw-family +
# mix/final). All other archetypes are spike-family (no saws).
SAW_FAMILY = frozenset({3, 8, 9, 10, 26, 33, 37, 41, 42, 43, 44})
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


def chain_window(w1, w2, g):
    """Chained-pair takeoff window width (px) for two dir-up strips
    of widths w1, w2 with edge-to-edge gap g on flat ground, D=97.2.
    The four terms are the binding cases of W = W1 n ((L n W2) - D):
    W1 width, W2 width, landing-zone width (g-27.5), and the reach
    term (D + 69.7 - w1 - w2 - g). Only meaningful for a CHAINED
    pair (g + w2 <= D); decoupled pairs are not chain-tested."""
    return min(CHAIN_WINDOW_CONST - w1, CHAIN_WINDOW_CONST - w2,
               g - 27.5, 166.9 - w1 - w2 - g)


def column_span_clearable(w, h, tun):
    """Round 4 column span test (Implementation Gate §7a): a spiked
    column of width w protruding h px above the walking surface is
    crossable only if the hero's rect (w + 15) fits inside the
    at-height span: tun.max_jump_dist * sqrt(1 - h/tun.apex).
    Uses the checker's THEORETICAL tuning values (conservative vs
    the engine: max_jump_dist 89.07, apex 52.24 -- NOT the measured
    97.2/57). Reference values: 56x40 -> 71 > 43.1 FAIL; 26x36 ->
    41 <= 49.6 PASS; 36x40 -> 51 > 43.1 FAIL."""
    if h > ENVELOPE_MAX_RISE:
        return False
    if h < 0.0:
        return True
    return (w + HERO_RECT_W
            <= tun.max_jump_dist
            * math.sqrt(max(0.0, 1.0 - h / tun.apex)))


def trajectory_offsets(tun):
    """Discrete jump-trajectory vertical offsets (px, feet-relative),
    replicating _plan_trajectory/_plan_flight with the checker's
    theoretical tuning values (jump_v, gravity, max_fall_speed).
    Frame f advances run_speed/60 px horizontally (4.05px/frame)."""
    dt = 1.0 / 60.0
    max_fall = float(tun.raw.get("player", {}).get("max_fall_speed", 600.0))
    offs = []
    off = 0.0
    v = float(tun.jump_v)
    for f in range(90):
        if f > 0:
            v = min(v + float(tun.gravity) * dt, max_fall)
        off += v * dt
        offs.append(off)
        if off > 220.0:
            break
    return offs


def discrete_air_frames(tun):
    """Stage 2 §3 (R5 frame convention, pinned): (land_frame, air_dx).

    Frames f=0..22 are the AIRBORNE frames through first contact
    (verified from trajectory_offsets with frozen tuning: offs[21] =
    -9.44 still airborne, offs[22] = +0.064 at x = takeoff + 89.10,
    the first frame at/below floor). Frame f=23 (x = takeoff + 93.15)
    is the LANDING frame, simulated as a grounded stance — NOT an arc
    frame. land_frame is the first frame > 10 with off >= 0 (22);
    air_dx = (land_frame + 1) * run_speed/60 = 93.15 px. The
    design-lane "23 frames x 4.05" wording was a fencepost error and
    is withdrawn: frames f=0..22 span 22 intervals = 89.1 px; the
    takeoff-to-landing distance is 23 intervals = 93.15 px."""
    offs = trajectory_offsets(tun)
    land_f = next(i for i, o in enumerate(offs) if i > 10 and o >= 0.0)
    return land_f, (land_f + 1) * (float(tun.run_speed) / 60.0)


def span_at_height(h, tun):
    """(x_lo, x_hi, width): takeoff-relative x-range (px) where the
    discrete trajectory's rise is >= h. Reference values (frozen
    tuning): span(0) = (4.05, 93.12, 89.07), span(10) =
    (4.28, 88.84, 84.55), span(36) = (18.33, 74.79, 56.46),
    span(40) = (21.14, 71.98, 50.84)."""
    step = float(tun.run_speed) / 60.0
    offs = trajectory_offsets(tun)
    idx = [i for i, o in enumerate(offs) if -o >= h]
    if not idx:
        return (0.0, 0.0, 0.0)
    first, last = idx[0], idx[-1]
    if first == 0:
        x_lo = step
    else:
        r0 = -offs[first - 1]
        r1 = -offs[first]
        x_lo = first * step + ((h - r0) / max(0.001, r1 - r0)) * step
    if last >= len(offs) - 1:
        x_hi = (last + 1) * step
    else:
        ra = -offs[last]
        rb = -offs[last + 1]
        x_hi = (last + 1) * step + ((ra - h) / max(0.001, ra - rb)) * step
    return (x_lo, x_hi, x_hi - x_lo)


def column_takeoff_window(col_x, col_w, h, direction, tun):
    """Feet-x takeoff interval for jumping OVER a column whose near
    edge is col_x, width col_w, protruding h px above the takeoff
    ground. direction +1: hero travels right (takeoff left of the
    column); -1: travels left (takeoff right of it). The interval
    guarantees the hero's rect is above the column top while
    overlapping it AND lands past the column. Returns (lo, hi);
    empty when lo > hi."""
    x_lo, x_hi, _w = span_at_height(h, tun)
    hw = HERO_RECT_W / 2.0
    if direction >= 0:
        return (col_x + col_w + hw - x_hi, col_x - hw - x_lo)
    return (col_x + col_w + hw + x_lo, col_x - hw + x_hi)


def _xy(point):
    if isinstance(point, dict):
        return float(point["x"]), float(point["y"])
    return float(point[0]), float(point[1])


def connectivity_error(platforms, spawn, door, width, floor_y,
                       door_w, door_h, hero_w=HERO_RECT_W,
                       hero_h=HERO_RECT_H):
    """Rule 5 connectivity (LEVEL_SCHEMA.md v3): flood-fill of empty
    space on an 8px grid over width x floor_y (720), 4-connected,
    from the hero rect at spawn to the door rect. A cell is blocked iff it
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
    rows = max(1, int(math.ceil(float(floor_y) / cell)))
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

    seeds = _open_cells(sx - float(hero_w) / 2.0, sy - float(hero_h),
                        float(hero_w), float(hero_h))
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
        # FLOOR_Y = viewport.height (720). The tuning.json
        # `control_bar` entry is DEPRECATED and never read here.
        self.floor_y = float(vp["height"])
        # Frozen v3 envelope: schema constants, NOT tuning.json
        # `harness_envelope` (which still holds stale v2 values).
        self.max_rise = ENVELOPE_MAX_RISE
        self.max_gap = ENVELOPE_MAX_GAP
        self.min_landing = ENVELOPE_MIN_LANDING
        self.min_runup = ENVELOPE_MIN_RUNUP
        self.min_window = ENVELOPE_MIN_WINDOW
        pl = data["player"]
        self.gravity = float(pl["gravity"])
        self.jump_v = float(pl["jump_velocity"])
        self.run_speed = float(pl["run_speed"])
        self.player_w = float(pl["width"])
        self.player_h = float(pl["height"])
        # Door size: SCHEMA CONSTANT 36x54. The tuning.json `door`
        # entry (54x84) is DEPRECATED and never read here.
        self.door_w = DOOR_W
        self.door_h = DOOR_H
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
    Drop distance is to FLOOR_Y (720): drop_dist = max(0, floor_y -
    (y + h)); drop_time = drop_dist / drop_speed; hang_time =
    period - drop_time - 1.0s rise. SAME arithmetic as
    hazard_node.gd / autopilot.gd (verified by code-reading).

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
        # Stage 2: per-segment mixed-move cache (keyed by segment +
        # trig_map signature) and the last edge check's chosen t0
        # (read by check_path_windows for the §4.3 walk-out followup).
        self._mixed_cache = {}
        self._edge_choice = None

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

    # -- (b) geometry bounds ----------------------------------------------
    def check_bounds(self):
        tun = self.tun
        W, H = tun.width, tun.floor_y
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
        floor_y = self.tun.floor_y
        grounded = set()
        changed = True
        while changed:
            changed = False
            for i, r in enumerate(rects):
                if r is None or i in grounded \
                        or plats[i].get("kind") != "solid":
                    continue
                bottom = r[1] + r[3]
                ok = abs(bottom - floor_y) <= GROUND_TOL
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
            if t == "hanging_pillar":
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
                # Stage 2 §4.3 (R1): a MOVING saw (path/swing) passes
                # rule-7 grounding iff AT LEAST ONE swept centre
                # touches solid (existential, not universal). A
                # gap-patrol disc inherently cannot touch solid over
                # the gap, so the old universal rule made every
                # gap-patrol geometry fail grounding by construction
                # (d10: rest centre dist 29.73 > 26 fails forall;
                # path-end centre dist 22.00 <= 26 passes exists).
                # Static saws have a single swept centre, so
                # forall == exists for them — unchanged.
                moving = "path" in h or "swing" in h
                centres = saw_sweep_centres(h)
                touches = [any(point_rect_dist(cx, cy, s) <= r + GROUND_TOL
                               for s in solid_rects)
                           for (cx, cy) in centres]
                if moving:
                    if not any(touches):
                        cx, cy = centres[0]
                        self.errors.append(
                            "grounding: hazards[%d] saw disc does not "
                            "touch solid at any swept centre "
                            "(first (%g,%g))" % (i, cx, cy))
                else:
                    for (cx, cy), ok in zip(centres, touches):
                        if not ok:
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
                on_top = abs(bottom - self.tun.floor_y) <= GROUND_TOL \
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

    def check_spike_strip_cap(self):
        """Round 3 cap (pilot-gate-r2 §8A): no dir-up spikes strip may
        be wider than MAX_UP_SPIKE_W. Minimal predicate -- no seating
        or path test: timing (trigger/period) does not exempt a strip,
        and down/left/right spikes are excluded (they are not jumped
        over on flat ground). Boundary: w <= 60 passes, w >= 61 fails.
        """
        for i, h in enumerate(self.lv.get("hazards", [])):
            if not isinstance(h, dict):
                continue
            if h.get("type") != "spikes":
                continue
            if h.get("dir", "up") != "up":
                continue
            if not is_num(h.get("w")):
                continue
            w = float(h["w"])
            if w > MAX_UP_SPIKE_W:
                self.errors.append(
                    "spike-strip: hazards[%d] up-spikes w=%g > 60 "
                    "(max clearable ~69.7px; pilot-gate-r2 §8)" % (i, w))

    def check_chained_pairs(self):
        """Rule 12 (Round 4, harness only): chained-pair window floor.
        For any two dir-up spikes strips on the SAME platform with
        edge-to-edge gap g < 97.2 (game-true air distance D), if the
        pair is CHAINED (the earliest landing after clearing the
        first strip is already at/past the second strip's takeoff
        window: g + w2 <= D), the chained window W_chain must be
        >= 15px (D14 clean floor). Decoupled pairs (g + w2 > D:
        the hero lands before the second window opens and runs in)
        are judged as single strips. A 60+60 pair can never pass:
        W_chain <= 69.7-60 = 9.7 < 15 at any gap."""
        ups = []
        for i, h in enumerate(self.lv.get("hazards", [])):
            if not isinstance(h, dict):
                continue
            if h.get("type") != "spikes" or h.get("dir", "up") != "up":
                continue
            if not all(is_num(h.get(k)) for k in ("x", "y", "w", "h")):
                continue
            ups.append((float(h["y"]) + float(h["h"]), float(h["x"]),
                        float(h["w"]), i))
        if len(ups) < 2:
            return
        # Seat each strip on its platform (same platform index =
        # same ground). Unseated strips fall back to grouping by
        # bottom y (grounding reports them separately).
        plats = self.lv.get("platforms", [])

        def seat_key(u):
            bottom, x, w, _i = u
            cx = x + w / 2.0
            for j, p in enumerate(plats):
                if not isinstance(p, dict):
                    continue
                if abs(float(p["y"]) - bottom) <= GROUND_TOL \
                        and float(p["x"]) <= cx \
                        <= float(p["x"]) + float(p["w"]):
                    return ("plat", j)
            return ("bottom", round(bottom, 1))

        groups = {}
        for u in ups:
            groups.setdefault(seat_key(u), []).append(u)
        for key in sorted(groups, key=str):
            row = sorted(groups[key], key=lambda t: t[1])
            for a, b in zip(row, row[1:]):
                _ba, x1, w1, i1 = a
                _bb, x2, w2, i2 = b
                g = x2 - (x1 + w1)
                if g >= CHAIN_DECOUPLE_GAP:
                    continue
                if g + w2 > CHAIN_DECOUPLE_GAP:
                    continue  # decoupled: lands before W2, runs in
                w_chain = chain_window(w1, w2, g)
                if w_chain < CHAIN_MIN_WINDOW:
                    self.errors.append(
                        "chained-pair: hazards[%d]+hazards[%d] up-strips "
                        "w=%g+%g gap=%g -> W_chain=%.2f < 15 "
                        "(clean floor; chained: g+w2=%g <= 97.2)"
                        % (i1, i2, w1, w2, g, w_chain, g + w2))

    # -- (b3b) hazard/solid area-overlap (rule 7) ------------------------
    def check_hazard_solid_overlap(self):
        """Rect hazards must not area-overlap solid rects beyond the
        4px seating tolerance: an intersection with width > 4 AND
        height > 4 fails. Saws (disc geometry) and hanging_pillar
        (beam mounts) are exempt. Harness only; the runtime does
        not check this."""
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
    def _is_floor_slab(self, r):
        """Rule 9 exclusion: rect touches y=720 and spans >= 50% of
        the width. Such slabs must not satisfy the bands by
        themselves."""
        return abs(r[1] + r[3] - self.tun.floor_y) <= GROUND_TOL \
            and r[2] >= FLOOR_SLAB_MIN_WIDTH_FRAC * self.tun.width

    def _is_edge_wall(self, r):
        """Rule 9 exclusion: rect touches the left or right edge."""
        return r[0] == 0.0 or r[0] + r[2] == self.tun.width

    def _counts_for_bands(self, r):
        return not self._is_floor_slab(r) and not self._is_edge_wall(r)

    def _mass_metric(self, rects):
        """Report-only mass metric (rule 9): solid area fraction +
        per-column solid coverage over the play area (0..1280 /
        90..720) on an 8px grid. NO hard threshold -- silhouette is
        judged eyes-on against the reference frames."""
        cell = MASS_GRID_CELL
        cols = max(1, int(math.ceil(self.tun.width / cell)))
        top = HUD_KEEPOUT_Y
        rows = max(1, int(math.ceil((self.tun.floor_y - top) / cell)))
        covered = bytearray(cols * rows)
        for i, r in enumerate(rects):
            if r is None \
                    or self.lv["platforms"][i].get("kind") != "solid":
                continue
            cx0 = max(0, int(r[0] // cell))
            cx1 = min(cols - 1, int((r[0] + r[2] - 1e-9) // cell))
            cy0 = max(0, int((r[1] - top) // cell))
            cy1 = min(rows - 1, int((r[1] + r[3] - top - 1e-9) // cell))
            for cy in range(cy0, cy1 + 1):
                base = cy * cols
                for cx in range(cx0, cx1 + 1):
                    covered[base + cx] = 1
        total = cols * rows
        solid_cells = sum(covered)
        col_fracs = []
        for cx in range(cols):
            col_fracs.append(sum(covered[cy * cols + cx]
                                 for cy in range(rows)) / float(rows))
        return {"solid_area_fraction": solid_cells / float(total),
                "mean_column_coverage": sum(col_fracs) / float(cols),
                "columns_with_solid_frac": sum(
                    1 for f in col_fracs if f > 0) / float(cols),
                "columns_half_covered_frac": sum(
                    1 for f in col_fracs if f >= 0.5) / float(cols)}

    def check_density_floor(self):
        rects = self._rects()
        count = 0
        width = 0.0
        core_count = 0
        core_width = 0.0
        for i, r in enumerate(rects):
            if r is None or self.lv["platforms"][i].get("kind") != "solid":
                continue
            if not self._counts_for_bands(r):
                continue
            if r[1] < DENSITY_BAND_BOTTOM \
                    and r[1] + r[3] > DENSITY_BAND_TOP:
                count += 1
                width += r[2]
            if r[1] < CORE_BAND_BOTTOM \
                    and r[1] + r[3] > CORE_BAND_TOP:
                core_count += 1
                core_width += r[2]
        # Core-middle floor, decorations half (rules 9 + 10):
        # decoration rects count TOGETHER with solid rects, under
        # the SAME floor-slab / edge-wall exclusions. The middle
        # floor above stays solid-only. Malformed deco entries are
        # reported by check_decorations and skipped here, never
        # counted.
        for d in self._deco_rects():
            if d is None or not self._counts_for_bands(d):
                continue
            if d[1] < CORE_BAND_BOTTOM \
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
                        "core_pass": core_ok,
                        "mass": self._mass_metric(rects)}
        if not ok:
            self.errors.append(
                "density: only %d solid rect(s) in middle band "
                "y170..550, combined width %g (need >= %d rects "
                "and width >= %g; floor slabs and edge walls excluded)"
                % (count, width, DENSITY_MIN_RECTS, DENSITY_MIN_WIDTH))
        if not core_ok:
            self.errors.append(
                "core-middle: only %d non-edge, non-slab solid/"
                "decoration rect(s) intersecting y310..510, combined "
                "width %g (need >= %d rects and width >= %g)"
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
        W, H = tun.width, tun.floor_y
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
        """All hazards are lethal in v3 (no warning-only types)."""
        return list(self.lv["hazards"])

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
        when landing higher). Yields (x, feet_y).

        Stage 2 §3: DEAD CODE for hazard decisions — the 11-point
        parabola is replaced at all four sites (L1720 edge_info, L1911
        edge timed, L1952 walk jump-over, L2113 walk static saw) by the
        discrete-arc prefix (_discrete_arc_clear). Retained only so
        filed read-only analysis scripts that import it keep running;
        NO checker verdict may depend on it."""
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
                fall_col = (r[0], r[1], r[2], self.tun.floor_y - r[1])
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
            if h.get("dir", "up") == "up" and self._ground_sitting_spikes(h) \
                    and float(h["w"]) <= MAX_UP_SPIKE_W:
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
        # Stage 2 §3.4: the parabola is replaced by the discrete-arc
        # prefix from the edge takeoff to its LANDING (the graph's
        # lx) — the airborne frames are truncated to those with x
        # inside [tx, lx] and the landing stance is at lx (feet on
        # by). The flight past lx belongs to the landing platform's
        # segment and is judged there (L2113); a full-prefix arc
        # here newly fails L035/L038/L039, which the autopilot
        # passes in game mode (§3.5 false negatives: the saw past
        # lx sits on the next platform, not in the gap).
        for h in self.lethal_hazards():
            if h.get("type") != "saw" or "path" in h or "swing" in h:
                continue
            cx, cy, r = float(h["x"]), float(h["y"]), float(h["r"])
            if abs(lx - tx) < 1e-9:
                prect = (tx - tun.player_w / 2.0, ay - tun.player_h,
                         tun.player_w, tun.player_h)
                if circle_rect_overlap(cx, cy, r, prect):
                    return None
                continue
            _offs, _lf, air_dx = self._traj()
            max_frame = int(abs(lx - tx)
                            / (float(tun.run_speed) / 60.0))
            ok, _clear, _detail = self._discrete_arc_clear(
                tx, lx, ay, [h], t0=None, landing_top=by,
                landing_platform=(rb[0], rb[2]), stance_hazards=[h],
                max_frame=max_frame)
            if not ok:
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
                                               self.tun.floor_y)
                # Hanging (solid) rect overlapping the player blocks too.
                return rects_overlap(rect, prect)
            # Triggered: drops once the player passes drop_trigger_x.
            if trig_time is None:
                return False
            speed = float(h.get("drop_speed", DEFAULT_DROP_SPEED))
            x, y, w, hh = (float(h[k]) for k in ("x", "y", "w", "h"))
            drop_dist = max(0.0, self.tun.floor_y - (y + hh))
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

    # -- Stage 2 (Redesign Pass 2) discrete-arc helpers ------------------
    def _traj(self):
        """Cached (offs, land_frame, air_dx) for the discrete arc."""
        if not hasattr(self, "_traj_cache"):
            offs = trajectory_offsets(self.tun)
            land_f, air_dx = discrete_air_frames(self.tun)
            self._traj_cache = (offs, land_f, air_dx)
        return self._traj_cache

    def _discrete_arc_clear(self, tx, lx, top, hazards, t0=None,
                            landing_top=None, landing_platform=None,
                            trig_map=None, stance_hazards=None,
                            max_frame=None):
        """Stage 2 §3 shared fix — discrete-arc prefix clearance.

        Frames f=0..22 (R5 frame convention, pinned): hero rect at
        x = tx + direction*f*4.05, feet = top + offs[f] (offs from
        trajectory_offsets; first-contact frame 22 at x = takeoff +
        89.1, apex offset -56.99 px). Frame f=23 (x = takeoff + 93.15)
        is the LANDING frame and is simulated as a grounded stance
        (feet on landing_top, default top) at t0 + 23/60 — NOT as an
        arc frame. `lx` is the landing feet-x: for the full prefix
        (walk sites, edge timed check) it is the discrete landing
        tx + direction*93.15 (§4.2 pins this for the gap edge); for
        the graph site (§3.4) it is the edge's own landing and
        max_frame truncates the airborne frames to those with x
        inside [tx, lx] (the graph's edge model is a jump from tx
        that lands at lx; the flight past lx belongs to the landing
        platform's segment, judged there — a full-prefix arc at the
        graph site newly fails L035/L038/L039, which the autopilot
        passes in game mode, i.e. §3.5 false negatives).
        The fixed span cx +/- (r+30) is DELETED everywhere this
        helper is used.
        Landing rule (§3.5 re-scope, feet-point): the landing
        feet-x must lie on solid ground of landing_platform
        (platform_x <= landing_x <= platform_x + w). The literal
        +/- 7.5 margin (the whole hero rect inside the platform)
        is WITHDRAWN: it newly fails shipped L049 (best discrete
        clearance +4.29 px at tk606.35, landing 699.5 on platform
        [578, 702], rejected only because 699.5 > 694.5 = 702-7.5)
        while the autopilot passes L049 in game mode — a §3.5 false
        negative. Physics: Godot grounds the hero on ANY positive
        overlap of his 15 px rect with the platform (landing at
        699.5 overlaps [578, 702] by 10 px); the +/- 7.5 margin
        exceeds game physics and is the sole cause of L049's
        failure. The feet-point rule does not rescue D26S5 (its
        failure is the arc clearance, -0.22 px, not the landing)
        and does not change L129 (it passes under either rule).
        Takeoff stance: if stance_hazards is given, the standing hero
        rect at tx (feet on top) must also be lethal-free vs those
        hazards at t0 — the hero must be able to STAND at the
        takeoff (mirrors the probe's run-in; a takeoff inside a
        disc's ground footprint is unreachable even if the arc
        frames, which start one frame into the jump at feet -9.5,
        clear it).
        Returns (clear, min_saw_clearance, detail): min_saw_clearance
        is the min over arc frames + landing stance of
        (point_rect_dist - r) over SAW hazards in `hazards` (None if
        there is no saw hazard). Clearance is strict: clear requires
        every frame's clearance > 0 (no knife-edge)."""
        tun = self.tun
        offs, land_f, air_dx = self._traj()
        step = float(tun.run_speed) / 60.0
        direction = 1 if lx >= tx else -1
        if landing_top is None:
            landing_top = top
        if landing_platform is not None:
            if isinstance(landing_platform, dict):
                px, pw = (float(landing_platform["x"]),
                          float(landing_platform["w"]))
            else:
                px, pw = (float(landing_platform[0]),
                          float(landing_platform[1]))
            # §3.5 feet-point landing rule (see the docstring): the
            # landing FEET-x must lie on solid ground; the +/- 7.5
            # margin is withdrawn (it newly fails shipped L049).
            if not (px - 1e-9 <= lx <= px + pw + 1e-9):
                return False, None, \
                    "landing %.2f off platform [%.2f, %.2f]" \
                    % (lx, px, px + pw)
        trig_map = trig_map or {}
        min_clear = None
        last_frame = land_f if max_frame is None \
            else min(land_f, max_frame)

        def frame_rect(f):
            x = tx + direction * f * step
            fy = top + offs[f]
            return (x - tun.player_w / 2.0, fy - tun.player_h,
                    tun.player_w, tun.player_h)

        def lethal_at(prect, t):
            for h in hazards:
                trig = trig_map.get(id(h))
                if trig is None and t0 is not None:
                    # Trigger crossed DURING the jump arms the hazard
                    # at the crossing instant (clock-independent).
                    trig = self._trigger_time_for_jump(h, tx, lx, t0,
                                                       direction)
                if self._hazard_lethal_at(h, prect, t, trig):
                    return h
            return None

        if stance_hazards:
            prect = (tx - tun.player_w / 2.0, top - tun.player_h,
                     tun.player_w, tun.player_h)
            for h in stance_hazards:
                if self._hazard_lethal_at(h, prect, t0,
                                          trig_map.get(id(h))):
                    return False, None, \
                        "takeoff stance at %.2f inside %s" \
                        % (tx, h.get("type"))
        for f in range(last_frame + 1):
            prect = frame_rect(f)
            t = None if t0 is None else t0 + f / 60.0
            # Track the clearance BEFORE the lethal test, so a lethal
            # arc still reports its (negative) best clearance as
            # evidence instead of None.
            for h in hazards:
                if h.get("type") == "saw":
                    cx, cy = saw_centre_at(h, t) if t is not None \
                        else (float(h["x"]), float(h["y"]))
                    d = point_rect_dist(cx, cy, prect) - float(h["r"])
                    min_clear = d if min_clear is None \
                        else min(min_clear, d)
            bad = lethal_at(prect, t)
            if bad is not None:
                return False, min_clear, \
                    "arc frame %d x=%.2f lethal vs %s (min clear %s)" \
                    % (f, tx + direction * f * step, bad.get("type"),
                       ("%.2f" % min_clear)
                       if min_clear is not None else "n/a")
        if max_frame is not None:
            # Truncated (graph) arc: the landing at lx is reached
            # after |lx - tx| / 243 s, not after the full 23-frame
            # flight.
            t_land = None if t0 is None else t0 + abs(lx - tx) \
                / float(tun.run_speed)
        else:
            t_land = None if t0 is None else t0 + (land_f + 1) / 60.0
        land_rect = (lx - tun.player_w / 2.0, landing_top - tun.player_h,
                     tun.player_w, tun.player_h)
        for h in hazards:
            if h.get("type") == "saw":
                cx, cy = saw_centre_at(h, t_land) if t_land is not None \
                    else (float(h["x"]), float(h["y"]))
                d = point_rect_dist(cx, cy, land_rect) - float(h["r"])
                min_clear = d if min_clear is None else min(min_clear, d)
        bad = lethal_at(land_rect, t_land)
        if bad is not None:
            return False, min_clear, \
                "landing stance at %.2f lethal vs %s (min clear %s)" \
                % (lx, bad.get("type"),
                   ("%.2f" % min_clear)
                   if min_clear is not None else "n/a")
        if min_clear is not None and min_clear <= 0.0:
            return False, min_clear, \
                "arc clearance %.2f <= 0 (knife-edge)" % min_clear
        return True, min_clear, "discrete arc clear (min clear %s)" \
            % ("%.2f" % min_clear if min_clear is not None else "n/a")

    def _entry_clear_window(self, h, entry_prect, period):
        """Longest continuous interval in one period during which
        standing at the entry point is safe — the same arithmetic as
        _crossing_simulation's entry-clear (0.05 s steps, trig = 0.0
        for triggered hazards, i.e. assumed already fired). Used ONLY
        by the Stage 2 discrete-arc edge / jump-over branches; the
        walk branch keeps its own byte-identical copy inside
        _crossing_simulation. The 0.7 s bound on this window is
        UNCHANGED (C4 ruling: it governs standing at an entry)."""
        if not period:
            return 0.0
        trig_x = h.get("trigger_x", h.get("drop_trigger_x"))
        step = 0.05
        n = max(1, int(period / step))
        run, best = 0.0, 0.0
        for k in range(n + 1):
            t = k * step
            trig = 0.0 if trig_x is not None else None
            if not self._hazard_lethal_at(h, entry_prect, t, trig):
                run += step
                best = max(best, run)
            else:
                run = 0.0
        return best

    def _trigger_time_for_jump(self, h, tx, lx, t0, direction):
        """trig_time for a triggered hazard crossed DURING a jump from
        tx (takeoff time t0) to lx: the crossing instant
        t0 + |trigger_x - tx| / 243 (the hero's x(t) is linear at
        243 px/s through the jump). Returns None for hazards with no
        trigger, or whose trigger line is not crossed during the jump.
        Approach arming is NOT computed here: it is clock-dependent
        (the f.py rule t0 - |tx - trigger_x| / 243 holds only on the
        mixed move's arrival clock, t=0 at the departure point; the
        walk jump-over's clock is t=0 at the segment entry and the
        edge's approach spans several intervals), so the caller
        passes approach-armed triggers via trig_map (absolute times
        on the same clock as t0) and this helper only covers the
        in-jump crossing, which is clock-independent."""
        trig_x = h.get("trigger_x", h.get("drop_trigger_x"))
        if trig_x is None:
            return None
        trig_x = float(trig_x)
        lo, hi = (tx, lx) if direction > 0 else (lx, tx)
        if lo - 1e-9 <= trig_x <= hi + 1e-9:
            return t0 + abs(trig_x - tx) / float(self.tun.run_speed)
        return None

    def _departure_point_safe(self, dep_x, top, level, period, trig_map):
        """Stage 2 §1(ii) — departure-point safety (a SEPARATE named
        check, full joint period).

        dep_x is the departure point (the segment-entry stance, where
        the hero stands before the run-in). trig_map maps id(hazard)
        -> trig_time for triggered hazards, computed from the hero's
        path TO dep_x exactly as in stage2-design-analysis-f.py
        (armed iff the trigger line was crossed on the approach, with
        trig_time = t_arrival - |dep_x - trigger_x| / 243; unarmed
        hazards are absent, trig_time None). The local clock sets
        t_arrival = 0. The standing hero rect (dep_x - 7.5, top - 39,
        15, 39) is tested against ALL hazards via _hazard_lethal_at
        at 1/60 s steps over one full joint period, in ABSOLUTE time
        (periodic hazards at their absolute phase; triggered hazards
        with their trig_time). Returns True iff lethal-free at every
        step. This is a DEPARTURE window (a cued action — wait, watch
        whole cycles, depart on a phase cue), NOT an entry-clear
        window: per the parent C4 ruling it is NOT subject to
        ENVELOPE_MIN_WINDOW 0.7 s; its operative floor is the joint
        floor (F1/F2/F3). If False, the mixed move FAILS for the
        segment (the hero cannot wait at the departure point; there is
        no backwards walking to a safer stance)."""
        tun = self.tun
        dt = 1.0 / 60.0
        frames = int(round(period * 60.0))
        prect = (dep_x - tun.player_w / 2.0, top - tun.player_h,
                 tun.player_w, tun.player_h)
        hazards = level.get("hazards", [])
        for k in range(frames):
            t = k * dt
            for h in hazards:
                if self._hazard_lethal_at(h, prect, t,
                                          trig_map.get(id(h))):
                    return False
        return True

    def _largest_floor_rectangle(self, tks, t0s, masks, tk_step):
        """Largest contained axis-aligned takeoff x t0 rectangle in
        the clean set, requiring takeoff width >= MIXED_FLOOR_WX
        (8.1 px) and t0 width >= MIXED_FLOOR_WT (0.10 s) — the mirror
        of probe_mixed_trajectory.py's largest_rectangle (bitmask
        intersection over the takeoff grid, longest set-bit run for
        the t0 width, area = (Wx + tk_step) * (Wt + 1/60), first
        max-area rectangle wins). Returns the rect dict (with
        centre_takeoff / centre_t0) or None. A 7-consecutive-bit
        pre-check (Wt >= 0.10 s needs 7 phase values) skips pairs
        with no qualifying run without the full run scan."""
        if not tks or not t0s:
            return None
        n_t0 = len(t0s)
        dt = t0s[1] - t0s[0] if n_t0 > 1 else (1.0 / 60.0)
        seven = 0
        for b in range(7):
            seven |= (1 << b)
        best = None
        best_area = 0.0
        for i in range(len(tks)):
            m = masks[i]
            for j in range(i, len(tks)):
                m &= masks[j]
                if m == 0:
                    break
                w_tk = tks[j] - tks[i]
                if w_tk < MIXED_FLOOR_WX - 1e-9:
                    continue
                # Upper bound: Wt can never exceed the full period.
                if (w_tk + tk_step) * (t0s[-1] - t0s[0] + dt) \
                        <= best_area:
                    continue
                # Fast check: any run of >= 7 consecutive set bits?
                has7 = False
                mm = m
                for _s in range(6):
                    mm &= (mm >> 1)
                    if mm == 0:
                        break
                else:
                    has7 = mm != 0
                if not has7:
                    continue
                rs = rl = 0
                cs = cl = 0
                for b in range(n_t0):
                    if m & (1 << b):
                        if cl == 0:
                            cs = b
                        cl += 1
                        if cl > rl:
                            rl, rs = cl, cs
                    else:
                        cl = 0
                if rl == 0:
                    continue
                w_t0 = t0s[rs + rl - 1] - t0s[rs]
                if w_t0 < MIXED_FLOOR_WT - 1e-9:
                    continue
                area = (w_tk + tk_step) * (w_t0 + dt)
                if area > best_area:
                    best_area = area
                    best = {"area": area, "takeoff_lo": tks[i],
                            "takeoff_hi": tks[j], "takeoff_width": w_tk,
                            "t0_lo": t0s[rs], "t0_hi": t0s[rs + rl - 1],
                            "t0_width": w_t0,
                            "centre_takeoff": 0.5 * (tks[i] + tks[j]),
                            "centre_t0": 0.5 * (t0s[rs]
                                               + t0s[rs + rl - 1]),
                            "n_takeoff_values": j - i + 1,
                            "n_t0_values": rl}
        return best

    def _walkout_followup(self, saw, landing_x, landing_phase, top,
                          platform, direction):
        """Stage 2 §4.3 walk-out followup (R1, S1-pinned).

        When an edge jump's landing lies inside the crossed saw's
        swept zone, the following segment's timed check for THAT saw
        is replaced by this: a 1/60 s simulation from the landing
        x/phase, walking at 243 px/s in `direction` to clear of the
        swept zone + hero half-width, testing the hero rect against
        the disc via saw_centre_at + circle_rect_overlap. Scope:
        centre landing ONLY (the autopilot executes the
        floor-rectangle centre); only that saw, only the immediately
        following segment, only when the landing is inside the swept
        zone. This is not a weakening of the 0.7 s gate: the 0.7 s
        standing test must not judge a landing-side walk-out, because
        the hero never stands at the platform entry — he LANDS (a
        planned air arrival, C4's own distinction) and walks clear.
        Returns (ok, reason)."""
        tun = self.tun
        r = float(saw["r"])
        centres = saw_sweep_centres(saw)
        xs = [c[0] for c in centres]
        px, pw = float(platform["x"]), float(platform["w"])
        if direction > 0:
            clear_x = max(xs) + r + tun.player_w / 2.0
        else:
            clear_x = min(xs) - r - tun.player_w / 2.0
        period = hazard_period(saw)
        dt = 1.0 / 60.0
        step = float(tun.run_speed) / 60.0
        t = landing_phase
        x = landing_x
        steps = 0
        while True:
            if direction > 0 and x >= clear_x - 1e-9:
                break
            if direction < 0 and x <= clear_x + 1e-9:
                break
            if not (px - 1e-9 <= x <= px + pw + 1e-9):
                return False, ("walk-out followup: walked off platform "
                               "at x=%.2f before clear x=%.2f"
                               % (x, clear_x))
            cx, cy = saw_centre_at(saw, t)
            prect = (x - tun.player_w / 2.0, top - tun.player_h,
                     tun.player_w, tun.player_h)
            if circle_rect_overlap(cx, cy, r, prect):
                return False, ("walk-out followup: disc overlap at "
                               "x=%.2f t=%.4f" % (x, t % period))
            x += direction * step
            t += dt
            steps += 1
            if steps > 600:
                return False, "walk-out followup: did not clear in 600 steps"
        return True, ("walk-out followup: CLEAN in %d steps to clear "
                      "x=%.2f" % (steps, clear_x))

    def _check_mixed_saw_crossing(self, entry_x, exit_x, top, platform,
                                  path_intervals, exclude_saws=frozenset()):
        """Stage 2 §1–§2 — the mixed moving-saw move (NEW, separate
        code path; it NEVER calls _crossing_simulation).

        For a flat, rightward walking segment containing moving saw(s):
        a unified 1/60 s all-hazard simulation (wait at the departure
        point + run-in + ONE discrete jump arc + walk-out), with the
        segment-entry-anchored takeoff lattice, full-period
        _departure_point_safe, the joint period (LCM over all timed
        hazards in the segment, in frames, capped at 3600), and the
        joint floor (F1/F2/F3 on BOTH grids, jump-over subset only,
        centre combo). Floor up-spike strips inside the run-in /
        walk-out are jumped at the centre of their span_at_height
        window, lattice-snapped (§1(vi)); a strip jump does NOT
        re-anchor the takeoff lattice.
        Scope (out of scope = inapplicable, falls through to the walk
        branch): non-flat / non-solid platform, leftward travel, more
        than two moving saws, two moving saws with different periods,
        any OTHER timed hazard in the segment (saw+pillar/popup mixes
        are UNFILED until a mixed probe is filed — §1(iv)/§8), a
        non-integer-frame period, a joint period over the 3600-frame
        cap, a departure point unsafe for a full period, or a strip
        jump that cannot be placed on the segment.
        Returns a dict: ok (the segment is admitted for the moving
        saw(s)), reason, centre_takeoff / centre_phase / Wx / Wt /
        centre_clearance (the floor rectangle's centre, per grid),
        grids (per-grid floor detail), period, joint_frames,
        spike_jumps. `path_intervals` is the list of x-intervals the
        hero traversed from spawn to entry_x (for the trig_map
        approach test). `exclude_saws` are hazard indices covered by
        the §4.3 walk-out followup (their crossing is judged there,
        not here)."""
        tun = self.tun
        lv = self.lv
        result = {"ok": False, "reason": "not attempted",
                  "centre_takeoff": None, "centre_phase": None,
                  "Wx": None, "Wt": None, "centre_clearance": None,
                  "grids": {}, "period": None, "joint_frames": None,
                  "spike_jumps": []}
        step = float(tun.run_speed) / 60.0
        dt = 1.0 / 60.0
        offs, land_f, air_dx = self._traj()
        # -- scope: flat, rightward, solid -------------------------------
        if exit_x < entry_x - 1e-9:
            result["reason"] = "mixed move inapplicable: leftward segment"
            return result
        if platform.get("kind") != "solid":
            result["reason"] = ("mixed move inapplicable: platform kind %s "
                                "(flat solid only)"
                                % platform.get("kind"))
            return result
        px, pw = float(platform["x"]), float(platform["w"])
        band = (min(entry_x, exit_x), top - tun.player_h,
                max(abs(exit_x - entry_x), 1.0), tun.player_h)
        hazards = lv.get("hazards", [])
        seg_saws = []
        for hi, h in enumerate(hazards):
            if hi in exclude_saws:
                continue
            if h.get("type") == "saw" and ("path" in h or "swing" in h):
                if rects_overlap(saw_swept_bbox(h), band):
                    seg_saws.append((hi, h))
        if not seg_saws:
            result["reason"] = "mixed move inapplicable: no moving saw"
            return result
        if len(seg_saws) > 2:
            result["reason"] = ("mixed move inapplicable: %d moving saws "
                                "in one segment" % len(seg_saws))
            return result
        periods = [hazard_period(h) for _hi, h in seg_saws]
        if len(set(periods)) > 1:
            result["reason"] = ("mixed move inapplicable: two moving saws "
                                "with different periods")
            return result
        # -- scope: no OTHER timed hazard in the segment ------------------
        for hi, h in enumerate(hazards):
            if hi in [s[0] for s in seg_saws] or hi in exclude_saws:
                continue
            timed = ("period" in h) or ("trigger_x" in h) \
                or ("drop_trigger_x" in h)
            if not timed:
                continue
            t = h.get("type")
            if t == "saw":
                touch = rects_overlap(saw_swept_bbox(h), band)
            elif t == "hanging_pillar":
                r = (float(h["x"]), float(h["y"]), float(h["w"]),
                     float(h["h"]))
                fall_col = (r[0], r[1], r[2], tun.floor_y - r[1])
                touch = rects_overlap(fall_col, band)
            else:
                r = (float(h["x"]), float(h["y"]), float(h["w"]),
                     float(h["h"]))
                touch = rects_overlap(r, band)
            if touch:
                result["reason"] = ("mixed move inapplicable: other timed "
                                    "hazard %s in segment (unfiled mix)"
                                    % t)
                return result
        # -- joint period: LCM over all timed hazards, in frames ---------
        frames = []
        for p in periods:
            f = float(p) * 60.0
            if abs(f - round(f)) > 1e-9:
                result["reason"] = ("mixed move inapplicable: non-integer-"
                                    "frame period %.4f s" % float(p))
                return result
            frames.append(int(round(f)))
        joint = frames[0]
        for f in frames[1:]:
            joint = joint * f // math.gcd(joint, f)
        if joint > MIXED_JOINT_PERIOD_CAP_FRAMES:
            result["reason"] = ("mixed move inapplicable: joint period %d "
                                "frames > %d cap"
                                % (joint, MIXED_JOINT_PERIOD_CAP_FRAMES))
            return result
        period = joint / 60.0
        result["period"] = period
        result["joint_frames"] = joint
        # -- trig_map from the approach (f.py rule, §1(ii)) ---------------
        trig_map = {}
        for h in hazards:
            trig_x = h.get("trigger_x", h.get("drop_trigger_x"))
            if trig_x is None:
                continue
            trig_x = float(trig_x)
            crossed = any(lo - 1e-9 <= trig_x <= hi + 1e-9
                          for (lo, hi) in path_intervals)
            if crossed:
                trig_map[id(h)] = -abs(entry_x - trig_x) \
                    / float(tun.run_speed)
        # -- departure-point safety (full joint period) -------------------
        if not self._departure_point_safe(entry_x, top, lv, period,
                                          trig_map):
            result["reason"] = ("mixed move fails: departure point unsafe "
                                "for a full period")
            return result
        # -- strip jumps inside the segment (probe rule, §1(vi)) ---------
        strip_jumps = []
        for h in hazards:
            if h.get("type") != "spikes" or h.get("dir", "up") != "up":
                continue
            sx, sw, sh = float(h["x"]), float(h["w"]), float(h["h"])
            if sx + sw <= entry_x + 1e-9 or sx >= exit_x - 1e-9:
                continue  # strip behind the entry or past the exit
            if abs(float(h["y"]) + sh - top) > 1.0:
                continue  # not a floor strip on this platform
            x_lo, x_hi, _w = span_at_height(sh, tun)
            w_lo = sx + sw + tun.player_w / 2.0 - x_hi
            w_hi = sx - tun.player_w / 2.0 - x_lo
            centre = 0.5 * (w_lo + w_hi)
            k = round((centre - entry_x) / step)
            tk = entry_x + k * step
            if not (w_lo <= tk <= w_hi):
                tk = centre
            if tk < entry_x - 1e-9 or tk + air_dx > px + pw + 1e-9:
                result["reason"] = ("mixed move inapplicable: strip jump "
                                    "at x=%.2f cannot be placed" % sx)
                return result
            strip_jumps.append((tk, tk + air_dx, sx))
        strip_jumps.sort()
        result["spike_jumps"] = strip_jumps
        # -- takeoff scan range (probe: swept zone +/- 60) ---------------
        swept_lo, swept_hi = 1e9, -1e9
        for _hi, h in seg_saws:
            bb = saw_swept_bbox(h)
            swept_lo = min(swept_lo, bb[0])
            swept_hi = max(swept_hi, bb[0] + bb[2])
        tk_lo = math.floor(swept_lo - MIXED_TAKEOFF_SCAN_PAD)
        tk_hi = math.ceil(swept_hi + MIXED_TAKEOFF_SCAN_PAD)
        saws = [h for _hi, h in seg_saws]
        cache_key = (entry_x, exit_x, id(platform),
                     tuple(sorted((hi, round(trig_map.get(id(h), 0.0), 6))
                                 for hi, h in enumerate(hazards)
                                 if id(h) in trig_map)),
                     tuple(sorted(exclude_saws)))
        if cache_key in self._mixed_cache:
            cached = dict(self._mixed_cache[cache_key])
            result.update(cached)
            return result

        def prect(fx, fy):
            return (fx - tun.player_w / 2.0, fy - tun.player_h,
                    tun.player_w, tun.player_h)

        def jump_feet(fx, jump_tk):
            """(feet_y, in_jump) for a jump from jump_tk at position
            fx (§3 frame convention: frame f at x = tk + f*4.05,
            feet = top + offs[f] for f = 0..22; f = 23 is the landing
            frame, simulated as a grounded stance)."""
            if jump_tk - 1e-9 <= fx <= jump_tk + air_dx + 1e-9:
                f = int(round((fx - jump_tk) / step))
                if f >= land_f + 1:
                    return top, True
                f = max(0, min(land_f, f))
                return top + offs[f], True
            return top, False

        def sim(tk, phi):
            """Unified 1/60 s all-hazard sim for (takeoff, phase).
            Returns (clean, min_saw_clearance, ground_pass) or
            (None, None, None) if the departure is infeasible.
            Arc phase first (most selective), then run-in, then
            walk-out; the verdict is order-independent (every phase
            must be clean). Trig arming: approach-armed triggers
            from trig_map, plus any trigger line in [entry_x, exit_x]
            crossed at t_dep + (trigger_x - entry_x)/243 (the hero's
            x(t) is linear throughout the segment, jumps included)."""
            arrival = (tk - entry_x) / float(tun.run_speed)
            n = 0
            if phi < arrival - 1e-9:
                n = math.ceil((arrival - phi) / period)
            t_take = phi + n * period
            t_dep = t_take - arrival
            if t_dep < -1e-9:
                return None, None, None
            trig = dict(trig_map)
            for h in hazards:
                trig_x = h.get("trigger_x", h.get("drop_trigger_x"))
                if trig_x is None or id(h) in trig:
                    continue
                trig_x = float(trig_x)
                if entry_x - 1e-9 <= trig_x <= exit_x + 1e-9:
                    trig[id(h)] = t_dep + (trig_x - entry_x) \
                        / float(tun.run_speed)
            jumps = list(strip_jumps)
            jumps.append((tk, tk + air_dx, None))
            # Sort by (takeoff, landing) only: a lattice takeoff can
            # coincide with a strip jump's takeoff (same range), and
            # the third elements (strip x vs None) are not comparable.
            jumps.sort(key=lambda j: (j[0], j[1]))
            min_clear = 1e9

            def lethal(fx, fy, t):
                pr = prect(fx, fy)
                for h in hazards:
                    if self._hazard_lethal_at(h, pr, t, trig.get(id(h))):
                        return True
                return False

            def track_clear(fx, fy, t):
                nonlocal min_clear
                pr = prect(fx, fy)
                for h in saws:
                    cx, cy = saw_centre_at(h, t)
                    min_clear = min(min_clear,
                                    point_rect_dist(cx, cy, pr)
                                    - float(h["r"]))

            # (a) arc phase: t_take .. t_take + 23/60 (frames 0..23).
            for kf in range(land_f + 2):
                t = t_take + kf * dt
                fx = tk + kf * step
                fy = top if kf >= land_f + 1 else top + offs[kf]
                if lethal(fx, fy, t):
                    return False, 0.0, False
                track_clear(fx, fy, t)
            # landing must be on this platform (§3.5 feet-point
            # landing rule: the landing feet-x on solid ground).
            if not (px - 1e-9 <= tk + air_dx <= px + pw + 1e-9):
                return False, 0.0, False
            # (b) run-in: t_dep .. t_take (walking + strip jumps).
            gp = False
            prev_sign = {}
            n_run = int(round((t_take - t_dep) / dt))
            for k in range(n_run + 1):
                t = t_dep + k * dt
                fx = entry_x + float(tun.run_speed) * (t - t_dep)
                fy = top
                in_jump = False
                for (a, lx, _s) in jumps:
                    if a <= fx <= lx and not (a == tk and fx >= tk):
                        fy, in_jump = jump_feet(fx, a)
                        break
                if not in_jump:
                    if not (px - 1e-9 <= fx <= px + pw + 1e-9):
                        return False, 0.0, False
                if lethal(fx, fy, t):
                    return False, 0.0, False
                if not in_jump and fx < tk - 1e-9:
                    for si, h in enumerate(saws):
                        cx, _cy = saw_centre_at(h, t)
                        d = fx - cx
                        s = 1 if d > 0 else (-1 if d < 0 else 0)
                        if s != 0:
                            if prev_sign.get(si, 0) not in (0, s):
                                gp = True
                            prev_sign[si] = s
                track_clear(fx, fy, t)
            # (c) walk-out: t_take + 23/60 .. t_end (walking + strips).
            t_end = t_dep + (exit_x - entry_x) / float(tun.run_speed)
            t = t_take + (land_f + 1) * dt
            while t <= t_end + 1e-9:
                fx = entry_x + float(tun.run_speed) * (t - t_dep)
                fy = top
                in_jump = False
                for (a, lx, _s) in jumps:
                    if a <= fx <= lx:
                        fy, in_jump = jump_feet(fx, a)
                        break
                if not in_jump:
                    if not (px - 1e-9 <= fx <= px + pw + 1e-9):
                        return False, 0.0, False
                if lethal(fx, fy, t):
                    return False, 0.0, False
                track_clear(fx, fy, t)
                t += dt
            return True, min_clear, gp

        def scan_grid(tk_list):
            """Clean jump-over combos -> (masks, tks)."""
            tks = []
            masks = []
            t0s = [j * dt for j in range(joint)]
            for tk in tk_list:
                tks.append(tk)
                mask = 0
                for j in range(joint):
                    ok, _clear, gp = sim(round(tk, 4), round(j * dt, 6))
                    if ok and not gp:
                        mask |= (1 << j)
                masks.append(mask)
            return tks, t0s, masks

        lattice_tks = []
        k = 0
        while True:
            tk = entry_x + k * step
            if tk > tk_hi + 1e-9:
                break
            if tk >= max(tk_lo, entry_x) - 1e-9 and tk <= exit_x + 1e-9:
                lattice_tks.append(round(tk, 4))
            k += 1
        grids = {}
        lat_tks, t0s, lat_masks = scan_grid(lattice_tks)
        lat_rect = self._largest_floor_rectangle(lat_tks, t0s, lat_masks,
                                                 step)
        lat_centre = None
        lat_pass = False
        if lat_rect is not None:
            ok, cc, _gp = sim(lat_rect["centre_takeoff"],
                              lat_rect["centre_t0"])
            lat_centre = cc if ok else None
            lat_pass = ok and (lat_centre or 0.0) >= MIXED_FLOOR_CLEAR
        grids["lattice"] = {"clean_jump_over": sum(bin(m).count("1")
                                                   for m in lat_masks),
                            "floor_rect": lat_rect,
                            "centre_clearance": lat_centre,
                            "floor_pass": lat_pass}
        prim_pass = False
        prim_rect = None
        prim_centre = None
        if lat_pass:
            # Primary (1 px) grid is only needed when the lattice
            # passes — both grids must pass, so a lattice failure
            # settles the move without the 4x scan.
            prim_tks = [float(x) for x in range(
                int(math.ceil(max(tk_lo, entry_x))),
                int(math.floor(min(tk_hi, exit_x))) + 1)]
            pr_tks, _t0s, pr_masks = scan_grid(prim_tks)
            prim_rect = self._largest_floor_rectangle(pr_tks, t0s,
                                                      pr_masks, 1.0)
            if prim_rect is not None:
                ok, cc, _gp = sim(prim_rect["centre_takeoff"],
                                  prim_rect["centre_t0"])
                prim_centre = cc if ok else None
                prim_pass = ok and (prim_centre or 0.0) \
                    >= MIXED_FLOOR_CLEAR
            grids["primary"] = {"clean_jump_over": sum(
                bin(m).count("1") for m in pr_masks),
                "floor_rect": prim_rect,
                "centre_clearance": prim_centre,
                "floor_pass": prim_pass}
        else:
            grids["primary"] = {"clean_jump_over": None,
                                "floor_rect": None,
                                "centre_clearance": None,
                                "floor_pass": False,
                                "skipped": "lattice floor failed"}
        ok = lat_pass and prim_pass
        result["grids"] = grids
        if ok:
            result["ok"] = True
            result["centre_takeoff"] = lat_rect["centre_takeoff"]
            result["centre_phase"] = lat_rect["centre_t0"]
            result["Wx"] = lat_rect["takeoff_width"]
            result["Wt"] = lat_rect["t0_width"]
            result["centre_clearance"] = lat_centre
            result["reason"] = ("mixed move PASS: lattice centre "
                                "(%.2f, %.4f) clear %.2f; primary centre "
                                "(%.2f, %.4f) clear %.2f"
                                % (lat_rect["centre_takeoff"],
                                   lat_rect["centre_t0"], lat_centre,
                                   prim_rect["centre_takeoff"],
                                   prim_rect["centre_t0"], prim_centre))
        else:
            result["reason"] = ("mixed move fails: lattice floor %s, "
                                "primary floor %s"
                                % (lat_pass, prim_pass))
        self._mixed_cache[cache_key] = {
            "ok": result["ok"], "reason": result["reason"],
            "centre_takeoff": result["centre_takeoff"],
            "centre_phase": result["centre_phase"],
            "Wx": result["Wx"], "Wt": result["Wt"],
            "centre_clearance": result["centre_clearance"],
            "grids": grids, "period": period,
            "joint_frames": joint, "spike_jumps": strip_jumps}
        return result

    def _check_timed_hazard_crossing(self, h, seg, top, is_edge, edge,
                                     trig_map=None, platform=None):
        """Check one timed hazard on one walking segment / edge corridor.

        seg: (x1, x2) crossed at feet level `top` (walking) or along
        the jump arc (edge). Returns (ok, reason).
        trig_map (optional): approach-armed triggered hazards, as
        {id(hazard): trig_time} on the same clock as the departure
        time t0 (the caller computes it from the path intervals
        before this check; the in-jump crossing is handled inside
        _discrete_arc_clear). platform (optional): the platform rect
        (dict with x/w, or (x, w)) the landing must lie on.
        Stage 2 §2.1 guard: the walk jump-over branch is DISABLED for
        moving saws (mixed-move path only). Stage 2 §3.3: the edge
        branch uses the discrete arc (the parabola is gone); the 0.7 s
        edge entry-clear test is unchanged (standing-at-entry, C4)."""
        tun = self.tun
        offs, land_f, air_dx = self._traj()
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
            # -- Stage 2 §3.3: fixed discrete edge arc ------------------
            # The edge IS a jump: the hero takes off at tx and the
            # discrete arc lands at tx + direction*93.15 (frame 23,
            # grounded stance) on the landing platform — §4.2 pins
            # this landing (the edge's own lx is the corridor end
            # and is used only by the jumpability gate, not as the
            # landing x: the graph's lx is the platform edge, which
            # the §3 landing margin would reject). If |lx - tx| >
            # 93.15 the edge is unjumpable by the discrete arc
            # (defence-in-depth; schema-legal edges have
            # |lx - tx| <= max_jump_dist 89.07 < 93.15).
            self._edge_choice = None
            (tx, ty), (lx, ly) = edge["takeoff"], edge["land"]
            span = abs(lx - tx)
            if span > air_dx + 1e-9:
                return False, ("timed %s: edge span %.2f > discrete "
                               "jump 93.15" % (h["type"], span))
            entry_prect = (tx - tun.player_w / 2.0, ty - tun.player_h,
                           tun.player_w, tun.player_h)
            window = self._entry_clear_window(h, entry_prect, period)
            land_x = tx + direction * air_dx
            land_platform = platform
            if land_platform is None and edge is not None:
                # Reconstruct the landing platform's position rect
                # from the edge's land point + the base width
                # (moving platforms keep their size, only the
                # position moves): rightward land = left edge,
                # leftward land = right edge.
                pb = self.lv["platforms"][edge["b"]]
                bw = float(pb["w"])
                if direction > 0:
                    land_platform = (lx, bw)
                else:
                    land_platform = (lx - bw, bw)
            if span < 1e-9:
                # Overlap edge (tx == lx): no jump — the hero walks
                # across the overlap. The check is a stance check at
                # the crossing point (the original parabola was a
                # degenerate point here): a clean stance at some
                # phase, plus the unchanged 0.7 s entry-clear test.
                best_t0, best_clear = None, None
                starts = [i * 0.05 for i in
                          range(int((period or 0.05) / 0.05) + 1)] \
                    if period else [0.0]
                for t0 in starts:
                    if not self._hazard_lethal_at(
                            h, entry_prect, t0,
                            (trig_map or {}).get(id(h))):
                        if h.get("type") == "saw":
                            cx, cy = saw_centre_at(h, t0)
                            d = point_rect_dist(cx, cy, entry_prect) \
                                - float(h["r"])
                        else:
                            d = 1e9
                        if best_clear is None or d > best_clear:
                            best_t0, best_clear = t0, d
                if best_t0 is None:
                    return False, ("timed %s: no clean stance at the "
                                   "overlap crossing (entry clear %.2fs)"
                                   % (h["type"], window))
                if period and window < tun.min_window:
                    return False, ("timed %s: safe window %.2fs < %.2fs "
                                   "(overlap crossing)"
                                   % (h["type"], window, tun.min_window))
                self._edge_choice = {"t0": best_t0, "takeoff": tx,
                                     "landing_x": tx,
                                     "landing_phase": (best_t0 % period)
                                     if period else 0.0,
                                     "saw": h, "clearance": best_clear}
                return True, ("timed %s ok: clean stance at overlap "
                              "crossing from t0=%.2fs; entry clear %.2fs"
                              % (h["type"], best_t0, window))
            # t0 scan (0.05 s steps over one period, mirroring the
            # entry-clear sampling): the best-clearance departure.
            best_t0, best_clear, best_detail = None, None, None
            starts = [i * 0.05 for i in
                      range(int((period or 0.05) / 0.05) + 1)] \
                if period else [0.0]
            for t0 in starts:
                ok, clear, detail = self._discrete_arc_clear(
                    tx, land_x, ty, [h], t0=t0, landing_top=ly,
                    landing_platform=land_platform, trig_map=trig_map,
                    stance_hazards=[h])
                if ok and (best_clear is None or
                           (clear or 0.0) > best_clear):
                    best_t0, best_clear, best_detail = t0, clear, detail
            if best_t0 is None:
                return False, ("timed %s: no clean discrete arc "
                               "(entry clear %.2fs)"
                               % (h["type"], window))
            if period and window < tun.min_window:
                return False, ("timed %s: safe window %.2fs < %.2fs "
                               "(discrete arc: %s)"
                               % (h["type"], window, tun.min_window,
                                  best_detail))
            self._edge_choice = {"t0": best_t0, "takeoff": tx,
                                 "landing_x": land_x,
                                 "landing_phase": ((best_t0 + 23.0 / 60.0)
                                                  % period)
                                 if period else 0.0,
                                 "saw": h, "clearance": best_clear}
            return True, ("timed %s ok: clean discrete arc from "
                          "t0=%.2fs (clear %s); entry clear %.2fs"
                          % (h["type"], best_t0,
                             ("%.2f" % best_clear)
                             if best_clear is not None else "n/a",
                             window))
        # -- Walking segment ----------------------------------------------
        start = zx1 if direction > 0 else zx2
        end = zx2 if direction > 0 else zx1
        duration = abs(end - start) / tun.run_speed

        def xs(f, s=start, e=end):
            return s + (e - s) * f

        def ys(f, top=top):
            return top
        clean, window, detail = self._crossing_simulation(
            h, xs, ys, max(duration, 0.05), period)
        # Walking segment: try walking through, then jumping over the
        # zone (the real move for head-height saws / floor spike strips).
        walk_ok = clean and (not period or window >= tun.min_window)
        if walk_ok:
            return True, "timed %s ok: %s" % (h["type"], detail)
        jump_detail = "jump-over not attempted"
        jump_ok = False
        jump_window = 0.0
        is_moving_saw = h.get("type") == "saw" and ("path" in h
                                                    or "swing" in h)
        if is_moving_saw:
            # Stage 2 §2.1 guard: the parabola jump-over branch is
            # DISABLED for moving saws — the mixed move is the only
            # jump-over path for them (defence-in-depth; §2.2 proves
            # the branch is dead for schema-legal saws on unclamped
            # segments anyway).
            jump_detail = "moving saw: mixed-move path only"
        else:
            # Stage 2 §3.2: for non-saw timed hazards the parabola is
            # replaced by the discrete arc over the takeoff lattice
            # anchored at the segment entry (step 4.05 px). Span gate
            # moves 89.07 -> 93.15 (S2: attempt-gate only; the
            # per-frame clearance scan + landing rule remain the
            # judge). The takeoff must be before the zone (arc starts
            # before it) and the landing past the zone, both inside
            # the segment.
            tx0 = max(x1, zx1 - 30.0)
            lx0 = min(x2, zx2 + 30.0)
            span = lx0 - tx0
            if 40.0 <= span <= air_dx:
                entry_x = seg[0]
                if direction > 0:
                    tk_lo = max(x1, zx2 - air_dx)
                    tk_hi = min(zx1, x2 - air_dx)
                else:
                    tk_lo = max(zx2, x1 + air_dx)
                    tk_hi = min(x2, zx1 + air_dx)
                best_tk, best_t0, best_clear = None, None, None
                best_window = 0.0
                k = 0
                while True:
                    tk = entry_x + direction * k * (
                        float(tun.run_speed) / 60.0)
                    if (direction > 0 and tk > tk_hi + 1e-9) or \
                            (direction < 0 and tk < tk_lo - 1e-9):
                        break
                    if tk_lo - 1e-9 <= tk <= tk_hi + 1e-9:
                        tk_prect = (tk - tun.player_w / 2.0,
                                    top - tun.player_h,
                                    tun.player_w, tun.player_h)
                        tk_window = self._entry_clear_window(
                            h, tk_prect, period)
                        if not period or tk_window >= tun.min_window:
                            # Approach trig_map on the segment-entry
                            # clock (t=0 at the entry): a trigger
                            # crossed while walking to the takeoff
                            # fires at |trigger_x - entry_x| / 243.
                            wtrig = {}
                            for h2 in self.lv.get("hazards", []):
                                tx2 = h2.get(
                                    "trigger_x",
                                    h2.get("drop_trigger_x"))
                                if tx2 is None:
                                    continue
                                tx2 = float(tx2)
                                lo = min(entry_x, tk)
                                hi = max(entry_x, tk)
                                if lo - 1e-9 <= tx2 <= hi + 1e-9:
                                    wtrig[id(h2)] = abs(tx2 - entry_x) \
                                        / float(tun.run_speed)
                            starts = [i * 0.05 for i in range(
                                int((period or 0.05) / 0.05) + 1)] \
                                if period else [0.0]
                            for t0 in starts:
                                ok, clear, _d = \
                                    self._discrete_arc_clear(
                                        tk, tk + direction * air_dx,
                                        top, [h], t0=t0,
                                        landing_top=top,
                                        landing_platform=platform,
                                        trig_map=wtrig,
                                        stance_hazards=[h])
                                if ok and (best_clear is None or
                                           (clear or 0.0) > best_clear):
                                    best_tk, best_t0 = tk, t0
                                    best_clear = clear
                                    best_window = tk_window
                    k += 1
                if best_tk is not None:
                    jump_ok = True
                    jump_window = best_window
                    jump_detail = ("discrete arc clear from takeoff "
                                   "%.2f t0=%.2fs (clear %s)"
                                   % (best_tk, best_t0,
                                      ("%.2f" % best_clear)
                                      if best_clear is not None else "n/a"))
                else:
                    jump_detail = ("discrete arc: no clean takeoff "
                                   "on the lattice (span %.0f)"
                                   % span)
            elif span > air_dx:
                jump_detail = ("jump-over impossible: span %.0f > "
                               "discrete jump 93.15" % span)
        if jump_ok:
            return True, "timed %s ok via jump-over: %s" \
                % (h["type"], jump_detail)
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
        (empty = path is viable) and notes.

        Stage 2 restructure (the segment loop and the edge loop keep
        their original order of failures/notes; the edge timed checks
        are computed in a PRE-PASS because the §4.3 walk-out followup
        needs the edge check's chosen t0 + landing before the segment
        loop runs):
        - Pass 0: segment/edge metadata + the ordered x-intervals the
          hero traverses (for the trig_map approach test).
        - Pre-pass: edge timed checks (trig_map from the prefix
          intervals); records the §4.3 followup for any edge whose
          landing lies inside a crossed moving saw's swept zone.
        - Loop 1 (segments): node timing, static hazards, the mixed
          move FIRST for a segment containing a moving saw, then the
          timed checks (skipping saws admitted by the mixed move and
          saws covered by the followup — the followup replaces their
          timed check).
        - Loop 2 (edges): replay the pre-pass results in order.
        """
        tun = self.tun
        failures, notes = [], []
        lv = self.lv
        # -- Pass 0: segment metadata + ordered traversal intervals ----
        segments = []
        for si, node in enumerate(path):
            p = lv["platforms"][node]
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
            segments.append((node, p, top, entry_x, exit_x))
        # Intervals in traversal order: seg0, edge0, seg1, edge1, ...
        intervals = []
        for si, (_n, _p, _t, entry_x, exit_x) in enumerate(segments):
            intervals.append((min(entry_x, exit_x),
                              max(entry_x, exit_x)))
            if si < len(path) - 1:
                edge = self.edges[(path[si], path[si + 1])]
                tx, lx = edge["takeoff"][0], edge["land"][0]
                intervals.append((min(tx, lx), max(tx, lx)))

        def trig_map_for(prefix, dep_x):
            """Approach-armed triggered hazards (f.py rule): armed
            iff the trigger line was crossed in `prefix`, with
            trig_time = -|dep_x - trigger_x| / 243 (the arrival
            clock: t=0 at dep_x)."""
            m = {}
            for h in lv.get("hazards", []):
                trig_x = h.get("trigger_x", h.get("drop_trigger_x"))
                if trig_x is None:
                    continue
                trig_x = float(trig_x)
                if any(lo - 1e-9 <= trig_x <= hi + 1e-9
                       for (lo, hi) in prefix):
                    m[id(h)] = -abs(dep_x - trig_x) \
                        / float(tun.run_speed)
            return m

        # -- Pre-pass: edge timed checks + §4.3 followup info ----------
        edge_results = {}
        followup = {}
        for si in range(len(path) - 1):
            edge = self.edges[(path[si], path[si + 1])]
            prefix = intervals[:2 * si + 1]
            etrig = trig_map_for(prefix, edge["takeoff"][0])
            results = []
            for item in edge["timed"]:
                if isinstance(item, str):
                    continue  # platform timing handled above
                h = lv["hazards"][item]
                seg = (edge["takeoff"][0], edge["land"][0])
                self._edge_choice = None
                ok, msg = self._check_timed_hazard_crossing(
                    h, seg, edge["takeoff"][1], True, edge,
                    trig_map=etrig, platform=None)
                results.append((ok, msg))
                # §4.3 followup (S1): if this edge crossed a moving
                # saw and the landing lies inside that saw's swept
                # zone, the following segment's timed check for THAT
                # saw is replaced by the walk-out followup from the
                # landing x/phase (centre landing only; t0 = the edge
                # check's chosen t0).
                choice = self._edge_choice
                if ok and choice is not None \
                        and h.get("type") == "saw" \
                        and ("path" in h or "swing" in h):
                    land_x = choice["landing_x"]
                    r = float(h["r"])
                    xs = [c[0] for c in saw_sweep_centres(h)]
                    lo = min(xs) - r
                    hi = max(xs) + r
                    if land_x - tun.player_w / 2.0 <= hi and \
                            land_x + tun.player_w / 2.0 >= lo:
                        followup.setdefault(si + 1, {})[item] = (
                            land_x, choice["landing_phase"], h)
            edge_results[si] = results
        # -- Loop 1: walking segments -----------------------------------
        for si, (node, p, top, entry_x, exit_x) in enumerate(segments):
            seg = (entry_x, exit_x)
            seg_len = abs(exit_x - entry_x)
            ok, msg = self._check_node_timing(node, seg_len)
            if not ok:
                failures.append(msg)
            band = (min(seg), top - tun.player_h, max(seg_len, 1.0),
                    tun.player_h)
            # Stage 2 §2: the mixed move FIRST for a segment
            # containing a moving saw; the walk branch is the
            # fall-through. Saws covered by the §4.3 followup are
            # excluded (their crossing is judged there).
            followup_saws = followup.get(si, {})
            mixed = None
            seg_has_moving_saw = any(
                h.get("type") == "saw"
                and ("path" in h or "swing" in h)
                and hi not in followup_saws
                and rects_overlap(saw_swept_bbox(h), band)
                for hi, h in enumerate(lv["hazards"]))
            if seg_has_moving_saw:
                mixed = self._check_mixed_saw_crossing(
                    entry_x, exit_x, top, p, intervals[:2 * si],
                    exclude_saws=frozenset(followup_saws))
                if mixed["ok"]:
                    notes.append("mixed saw crossing: %s"
                                 % mixed["reason"])
            for hi, h in enumerate(lv["hazards"]):
                t = h.get("type")
                # Static hazards on the walking band.
                if t == "spikes" and "period" not in h \
                        and "trigger_x" not in h:
                    r = (float(h["x"]), float(h["y"]), float(h["w"]),
                         float(h["h"]))
                    if rects_overlap(r, band):
                        if h.get("dir", "up") == "up" \
                                and self._ground_sitting_spikes(h) \
                                and float(h["w"]) <= MAX_UP_SPIKE_W:
                            notes.append("jumpable floor spikes on walk")
                        elif h.get("dir", "up") == "up" \
                                and self._ground_sitting_spikes(h):
                            failures.append(
                                "walking path on platforms[%d] blocked by "
                                "static spikes hazards[%d] (strip w=%g > 60 "
                                "unjumpable)" % (node, hi, float(h["w"])))
                        else:
                            failures.append(
                                "walking path on platforms[%d] blocked by "
                                "static spikes hazards[%d]" % (node, hi))
                elif t == "spiked_column":
                    r = (float(h["x"]), float(h["y"]), float(h["w"]),
                         float(h["h"]))
                    if rects_overlap(r, band):
                        # Round 4 span test (Gate §7a) + takeoff-ground
                        # test: the column is passable only if the
                        # span test passes AND a takeoff exists whose
                        # flight lands past the column, with the
                        # takeoff ground (this platform) extending
                        # under the takeoff point.
                        h_above = top - r[1]
                        direction = 1 if exit_x >= entry_x else -1
                        win_lo, win_hi = column_takeoff_window(
                            r[0], r[2], h_above, direction, tun)
                        feet_lo = float(p["x"]) + HERO_RECT_W / 2.0
                        feet_hi = (float(p["x"]) + float(p["w"])
                                   - HERO_RECT_W / 2.0)
                        ground_ok = win_lo <= feet_hi \
                            and win_hi >= feet_lo
                        if h_above <= 0.0:
                            notes.append("spiked column below walking "
                                         "band on walk")
                        elif not column_span_clearable(r[2], h_above, tun):
                            failures.append(
                                "walking path on platforms[%d] blocked by "
                                "spiked_column hazards[%d] (span test: "
                                "w+15=%g > %.2f at h=%g)"
                                % (node, hi, r[2] + HERO_RECT_W,
                                   tun.max_jump_dist * math.sqrt(max(
                                       0.0, 1.0 - h_above / tun.apex)),
                                   h_above))
                        elif not ground_ok:
                            failures.append(
                                "walking path on platforms[%d] blocked by "
                                "spiked_column hazards[%d] (takeoff window "
                                "[%.2f, %.2f] lies past platforms[%d] edge "
                                "[%.2f, %.2f])"
                                % (node, hi, win_lo, win_hi, node,
                                   feet_lo, feet_hi))
                        else:
                            notes.append("jumpable spiked column on walk")
                elif t == "saw" and "path" not in h and "swing" not in h:
                    if circle_rect_overlap(float(h["x"]), float(h["y"]),
                                           float(h["r"]), band):
                        # Jump-over test across the saw on this platform.
                        # Stage 2 §3.1: the 11-point parabola is replaced
                        # by the discrete-arc prefix over the takeoff
                        # lattice anchored at the segment entry (step
                        # 4.05 px). The fixed span cx +/- (r+30) is
                        # DELETED: the scan finds any takeoff whose
                        # discrete arc clears the disc and lands on
                        # the same platform (landing rule §3.5
                        # feet-point: landing feet-x on solid ground).
                        cx, r = float(h["x"]), float(h["r"])
                        _offs, _lf, air_dx = self._traj()
                        direction = 1 if exit_x >= entry_x else -1
                        if direction > 0:
                            tk_lo = max(cx + r - air_dx, entry_x)
                            tk_hi = min(cx - r, exit_x)
                        else:
                            tk_lo = max(cx + r, exit_x)
                            tk_hi = min(cx - r + air_dx, entry_x)
                        cleared = False
                        best_clear = None
                        k = 0
                        while True:
                            tk = entry_x + direction * k * (
                                float(tun.run_speed) / 60.0)
                            if (direction > 0 and tk > tk_hi + 1e-9) \
                                    or (direction < 0
                                        and tk < tk_lo - 1e-9):
                                break
                            if tk_lo - 1e-9 <= tk <= tk_hi + 1e-9:
                                ok, clear, _d = \
                                    self._discrete_arc_clear(
                                        tk, tk + direction * air_dx,
                                        top, [h], t0=None,
                                        landing_top=top,
                                        landing_platform=p,
                                        stance_hazards=[h])
                                if ok:
                                    cleared = True
                                    best_clear = clear
                                    break
                                if clear is not None and (
                                        best_clear is None
                                        or clear > best_clear):
                                    best_clear = clear
                            k += 1
                        if not cleared:
                            failures.append(
                                "walking path on platforms[%d] blocked "
                                "by static saw hazards[%d] (discrete "
                                "jump arc does not clear it; best "
                                "clearance %s)"
                                % (node, hi,
                                   ("%.2f" % best_clear)
                                   if best_clear is not None else "n/a"))
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
                    fall_col = (r[0], r[1], r[2], tun.floor_y - r[1])
                    timed_here = rects_overlap(fall_col, band)
                elif "trigger_x" in h:
                    r = (float(h["x"]), float(h["y"]), float(h["w"]),
                         float(h["h"]))
                    timed_here = rects_overlap(r, band)
                if timed_here:
                    if hi in followup_saws:
                        # §4.3: the walk-out followup REPLACES the
                        # timed check for this saw on this segment.
                        land_x, land_phase, saw = followup_saws[hi]
                        direction = 1 if exit_x >= entry_x else -1
                        ok, fmsg = self._walkout_followup(
                            saw, land_x, land_phase, top, p, direction)
                        if not ok:
                            failures.append(
                                "edge %d->%d walk-out followup: %s"
                                % (path[si - 1], node, fmsg))
                        else:
                            notes.append(
                                "edge %d->%d walk-out followup: %s"
                                % (path[si - 1], node, fmsg))
                        continue
                    if mixed is not None and mixed["ok"] \
                            and h.get("type") == "saw" \
                            and ("path" in h or "swing" in h):
                        # Admitted by the mixed move (the segment's
                        # moving saw(s)); the walk timed check is the
                        # fall-through for a failed mixed move only.
                        continue
                    ok, msg = self._check_timed_hazard_crossing(
                        h, seg, top, False, None, platform=p)
                    if not ok:
                        failures.append(msg)
                    else:
                        notes.append(msg)
        # -- Loop 2: edge-corridor timed crossings (replay pre-pass) ---
        for si in range(len(path) - 1):
            for (ok, msg) in edge_results[si]:
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
            self.lv.get("door", {}), self.tun.width, self.tun.floor_y,
            self.tun.door_w, self.tun.door_h,
            self.tun.player_w, self.tun.player_h)
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

    # -- (k) hazard-family purity (rule 11) ---------------------------
    def check_family_purity(self):
        """Rule 11 (harness only): saws only in saw-family + mix/final
        archetypes. Archetype comes from `variation` (D{nn}S{V}V{v});
        levels without that provenance pattern are skipped."""
        import re as _re
        variation = self.lv.get("variation")
        if not isinstance(variation, str):
            return
        m = _re.match(r"^D(\d{2})S[1-5]V\d+$", variation)
        if not m:
            return
        archetype = int(m.group(1))
        if archetype in SAW_FAMILY:
            return
        for i, h in enumerate(self.lv.get("hazards", [])):
            if isinstance(h, dict) and h.get("type") == "saw":
                self.errors.append(
                    "family: hazards[%d] saw in spike-family archetype "
                    "D%02d (rule 11: saws only in D03/D08/D09/D10/"
                    "D33/D37/D41 + D26/D42/D43/D44)" % (i, archetype))

    def run(self, max_paths=300, with_connectivity=True):
        self.check_fields()
        if self.structural_ok:
            # Deeper checks must never crash on malformed data: a check
            # that aborts is recorded as a failure with its reason.
            for fn in (self.check_bounds,
                       self.check_hud_keepout,
                       self.check_grounding,
                       self.check_spike_strip_cap,
                       self.check_chained_pairs,
                       self.check_hazard_solid_overlap,
                       self.check_density_floor,
                       self.check_decorations,
                       self.check_family_purity,
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
        # Exact error string required by LEVEL_SCHEMA.md v3: a v2
        # file MUST be rejected with `schema_version must be 3`.
        top_errors.append("schema_version must be 3")
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
    ("positive_floor_720.json", True, None),
    ("negative_floor_580.json", False, "grounding"),
    ("positive_door_size.json", True, None),
    ("negative_envelope.json", False, "unreachable"),
    ("positive_envelope.json", True, None),
    ("negative_family_purity.json", False, "family"),
    ("positive_family_purity.json", True, None),
    ("negative_dotted_line.json", False, "unknown type"),
    ("negative_floor_slab.json", False, "density"),
    ("negative_schema_v2.json", False, "schema_version must be 3"),
    ("positive_up_spike_60.json", True, None),
    ("negative_up_spike_61.json", False, "spike-strip"),
    ("negative_up_spike_70_triggered.json", False, "spike-strip"),
    ("negative_up_spike_120.json", False, "spike-strip"),
    ("negative_up_spike_overhang.json", False, "unreachable"),
    ("positive_column_26x36.json", True, None),
    ("negative_column_56x40.json", False, "spiked_column"),
    ("positive_chained_pair_48.json", True, None),
    ("negative_chained_pair_30.json", False, "chained-pair"),
    ("negative_column_past_ground_edge.json", False, "spiked_column"),
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
        reasons = " ".join(top_errors + [e for r in results
                                         for e in r["errors"]]).lower()
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
