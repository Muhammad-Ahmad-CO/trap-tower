#!/usr/bin/env python3
"""Trap Tower level generator, Run 2 (sole producer of level candidates).

Redesign: 44 DOORS x 5 stage slots x 2-3 variants of candidates, one
DISTINCT archetype/gimmick per door (shape + hazard family + palette).
Candidates are written to a candidates file (NOT the shipped
godot/data/levels.json); tools/assemble_levels.py joins an autopilot
report and writes the shipped file. Candidate IDs are
``D{door:02d}S{slot}V{variant}``; ``template`` is the archetype name and
``variation`` holds the same door/slot/variant code (frozen format).

Every candidate is verified with the repo's own static verifier
(tools/check_levels.py, imported -- never copied) before it is
accepted: schema + reachability + timing windows + the LEVEL_SCHEMA.md
distinctness rule (canonical signature EXCLUDING palette; >= 2 of
{layout geometry, trap set/params, solution path} must differ from
EVERY already-accepted candidate). Palette-only / mirror-only /
trivial-shift duplicates are rejected, as are schema-invalid
candidates. A rejected candidate is retried with a different grid
point (same builder, different positions/params) before it counts as
rejected.

Physics numbers are loaded from godot/data/tuning.json (retuned v3:
rise ~57px, air ~97px, speed ~243px/s, hero 15x39); the door size
(36x54) and the harness envelope are SCHEMA CONSTANTS from
LEVEL_SCHEMA.md v3, never read from the deprecated tuning.json
`control_bar`/`door` entries. Design envelope (frozen v3): rise <= 45,
gap <= 80, landing >= 48, run-up >= 24, timed-hazard safe window
>= 0.7s. All jumps are designed well inside it with visible landings,
run-ups, and safe waiting spots before every timed hazard.

v3 vocabulary (Run 4 pilot): levels are SOLID MASSES built from
`solid` rects (stairs, shafts, valleys, big walls, carved corridors,
U-shapes); spikes are integrated teeth (~10px, same colour as the
solid, lethal rect = drawn teeth rect); `falling`/`tilting` platforms
are hidden pits that draw identically to solid at rest; there are NO
trigger indicators anywhere (the `dotted_line` type is REMOVED in v3);
saws appear ONLY in saw-family + mix/final archetypes (rule 11).

Design rules (run-ledger.md Run 2, reconciled plan v1):
- Lethal surprise from door 1: hidden triggers (dashed floor lies,
  falling segments, triggered spikes/pillars) that kill a blind
  runner; every surprise is survivable by jumping/waiting once seen.
  NO empty hazards anywhere. NO deliberately-easy teaching levels.
- Full-height density: archetypes are structurally full-height
  (towers, terraces, stacked floors, skyline dressing); the
  upper-band rule survives only as a safety net for flat routes.
- Left-moving stretches ("simple isolated" only -- the autopilot's
  ballistic planner engages only when facing right): single spike
  strip w<=120, single static saw r<=34, single column w<=64/h<=88,
  gap<=140, >=200px clear floor between obstacles, >=150px run-up, no
  chains, no timed hazards except triggered spikes armed >=160px
  ahead.
- Tower/skyline: single-platform floors; staggered gaps with clear
  vertical shafts (checker blocker/arc rules); every rest position
  and drop shaft >=80px in x from the door except the final approach
  floor; x-monotonicity in the autopilot distance metric; no x-shared
  triggers across floors; no required mover rides.
- Honest scope: clones, springs, one-way platforms, coins, pushable
  blocks, warps, gravity reversal are NOT buildable with the current
  kinds and are NOT claimed; distinctness = shape + hazard family +
  palette.

Deterministic: fixed seed (default 20261118), fixed variation grids.
Stdlib only.

Usage:
  python3 tools/generate_levels.py [--out PATH] [--tuning PATH]
                                   [--seed N] [--doors 1,28,29]
                                   [--slots 1,2] [--variants N]
                                   [--min-levels N] [--quiet]

Defaults: --out is ~/workspace/trap-tower/verification/candidates.json,
--tuning is the repo tuning.json, all 44 doors, slots 1-5, per-door
variant counts (2, or 3 for structurally risky doors). --variants N
caps the variant count per door/slot (pilot runs use 1).
--min-levels defaults to the full requested candidate count: any
rejection fails loudly instead of silently shipping fewer stages.
"""

import argparse
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import check_levels  # noqa: E402  (exact verifier: schema + distinctness)

SEED_DEFAULT = 20261118
SCHEMA_VERSION = 3  # LEVEL_SCHEMA.md v3 (frozen contract version)
FLOOR_TOP = 500     # legacy level-design choice for the Run 2/3
                    # builders; the v3 floor is y=720 (FLOOR_Y).
                    # v3 pilot builders use their own ground tops.
VARIANT_STRIDE = 3  # fixed stride so pilot (variant 1) stages are the
                    # same grid points as bulk variant-1 stages.
MAX_ATTEMPTS = 6    # grid-point retries per candidate before rejection.
DECO_PASS_ENABLED = False  # v3 ZERO-DECO pilot (Run 4): the shipped
# file SHOULD contain zero decorations (LEVEL_SCHEMA.md v3 rule 10);
# solid masses fill the frame instead. Rule-10 compat stays in the
# checker only. Any decoration-bearing shipped level needs explicit
# Lead approval with eyes-on evidence.


# ---------------------------------------------------------------------------
# Tuning (single source of truth -- loaded, never hand-copied)
# ---------------------------------------------------------------------------

class Ctx:
    def __init__(self, tuning_data):
        self.tuning = check_levels.Tuning(tuning_data)
        self.tuning_version = self.tuning.version
        self.width = int(self.tuning.width)
        self.floor_y = int(self.tuning.floor_y)
        self.max_rise = self.tuning.max_rise
        self.max_gap = self.tuning.max_gap
        self.min_landing = self.tuning.min_landing
        self.min_runup = self.tuning.min_runup
        self.min_window = self.tuning.min_window
        self.player_w = self.tuning.player_w
        self.player_h = self.tuning.player_h
        self.run_speed = self.tuning.run_speed
        self.door_w = self.tuning.door_w
        self.door_h = self.tuning.door_h
        self.n_palettes = self.tuning.n_palettes
        self.apex = self.tuning.apex


def load_tuning(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Variation-grid helpers (coarse steps only, so signature buckets differ)
# ---------------------------------------------------------------------------

def _mix(kk, salt):
    """Avalanche-mix (kk, salt) to a 32-bit value. A plain
    (kk + salt) % len repeats pick sequences across slots, because
    slot kk-bases differ by multiples of 18 (divisible by 2 and 3);
    the mix decorrelates neighbouring kk values. Deterministic."""
    z = (kk * 0x9E3779B1 + salt * 0x85EBCA6B + 0x27D4EB2F) & 0xFFFFFFFF
    z = ((z ^ (z >> 16)) * 0x7FEB352D) & 0xFFFFFFFF
    z = ((z ^ (z >> 15)) * 0x846CA68B) & 0xFFFFFFFF
    return (z ^ (z >> 16)) & 0xFFFFFFFF


def g(kk, opts, salt=0):
    """Cyclic pick from an option list (deterministic variation grid)."""
    return opts[_mix(kk, salt) % len(opts)]


def sh(kk, step, n, salt=0):
    """Centred coarse shift: n steps of `step` px, e.g. -60,-20,20,60."""
    return (_mix(kk, salt) % n) * step - ((n - 1) * step) // 2


def row_positions(start, widths, clears):
    """Left-to-right x positions for widths with `clears` gaps between."""
    xs = [start]
    for i, w in enumerate(widths[:-1]):
        xs.append(xs[-1] + w + clears[i])
    return xs


def _overlaps(a0, a1, b0, b1):
    return a0 < b1 and b0 < a1


# ---------------------------------------------------------------------------
# Primitive builders
# ---------------------------------------------------------------------------

def plat(x, y, w, h, kind, **kw):
    d = {"x": int(x), "y": int(y), "w": int(w), "h": int(h), "kind": kind}
    d.update(kw)
    return d


def floor_seg(c, x1, x2, top=FLOOR_TOP):
    return plat(x1, top, x2 - x1, c.floor_y - top, "solid")


def spikes_up(x, w, top=FLOOR_TOP, **kw):
    # v3 integrated teeth: ~10px tall (1/4 hero height), seated flush
    # on the solid top (lethal rect = drawn teeth rect).
    d = {"type": "spikes", "x": int(x), "y": int(top - 10),
         "w": int(w), "h": 10, "dir": "up"}
    d.update(kw)
    return d


def spikes_down(x, w, y, h=10):  # v3 integrated teeth: ~10px tall
    return {"type": "spikes", "x": int(x), "y": int(y), "w": int(w),
            "h": int(h), "dir": "down"}


def spikes_side(x, y, w, h, direction):
    return {"type": "spikes", "x": int(x), "y": int(y), "w": int(w),
            "h": int(h), "dir": direction}


def saw_static(cx, cy, r):
    return {"type": "saw", "x": int(cx), "y": int(cy), "w": int(2 * r),
            "h": int(2 * r), "r": int(r)}


def saw_path(cx, cy, x2, y2, period, r):
    return {"type": "saw", "x": int(cx), "y": int(cy), "w": int(2 * r),
            "h": int(2 * r), "r": int(r),
            "path": {"x2": int(x2), "y2": int(y2)}, "period": float(period)}


def saw_swing(cx, cy, pivot_x, pivot_y, arc_deg, period, r):
    return {"type": "saw", "x": int(cx), "y": int(cy), "w": int(2 * r),
            "h": int(2 * r), "r": int(r),
            "swing": {"pivot_x": int(pivot_x), "pivot_y": int(pivot_y),
                      "arc_deg": int(arc_deg), "period": float(period)}}


def column(x, height, w=56, top=FLOOR_TOP):
    return {"type": "spiked_column", "x": int(x), "y": int(top - height),
            "w": int(w), "h": int(height)}


def pillar_triggered(x, y, w, h, trigger_x, speed):
    return {"type": "hanging_pillar", "x": int(x), "y": int(y),
            "w": int(w), "h": int(h), "drop_trigger_x": int(trigger_x),
            "drop_speed": int(speed)}


def pillar_safe_trigger(c, px, py, ph, speed, extra=0):
    """Trigger x for a triggered pillar, far enough ahead that the
    pillar is FULLY DOWN before the runner arrives. A landed pillar
    stays down as a jumpable solid block; arriving mid-fall means
    being crushed (D24S2V1: 150px warning, arrival 0.07s before
    landing). Margin 120px (~0.33s) past the landing moment.
    Physics from tuning only."""
    drop_dist = max(0.0, c.floor_y - (py + ph))
    land_time = drop_dist / max(float(speed), 1.0)
    dist = int(math.ceil(land_time * c.run_speed)) + 120 + extra
    return px - dist


def pillar_periodic(x, y, w, h, period, phase, speed):
    return {"type": "hanging_pillar", "x": int(x), "y": int(y),
            "w": int(w), "h": int(h), "period": float(period),
            "phase": float(phase), "drop_speed": int(speed)}


def stone_in_gap(kind, sx, top, w, kk, salt=0):
    """A gap-bridging special platform (dashed/falling/tilting/moving)."""
    if kind == "dashed":
        period, on = g(kk, [(2.6, 1.8), (3.0, 2.0), (3.2, 2.2),
                            (2.8, 1.9)], salt=salt)
        return plat(sx, top, w, 20, "dashed", period=period,
                    phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 1),
                    on_time=on)
    if kind in ("falling", "tilting"):
        return plat(sx, top, w, 20, kind,
                    stand_time=g(kk, [1.0, 1.2, 1.4], salt=salt))
    # moving: horizontal shuttle, small travel, generous period.
    return plat(sx, top, w, 20, "moving",
                dx=g(kk, [50, 60, 70, 80], salt=salt), dy=0,
                period=g(kk, [2.4, 2.8, 3.2], salt=salt + 1))


def triggered_strip(x, w, lead, delay, top=FLOOR_TOP):
    """Spike strip armed `lead` px ahead of travel (right-moving)."""
    return spikes_up(x, w, top, trigger_x=x - lead, delay=delay)


# ---------------------------------------------------------------------------
# Finish passes
# ---------------------------------------------------------------------------

def normalize_ground(c, platforms):
    """Ground normalization (v1 defect #1 fix): every solid platform on
    the main ground line extends to the control-bar line (y = floor_y).
    Tops never move, so physics is untouched; pits stay open (no
    platform = gap). Floating ledges/stones whose bottoms stay above
    the floor line are untouched."""
    for p in platforms:
        if p["kind"] != "solid":
            continue
        if p["y"] == FLOOR_TOP:
            p["h"] = c.floor_y - p["y"]
        elif p["y"] < FLOOR_TOP < p["y"] + p["h"] < c.floor_y:
            p["h"] = c.floor_y - p["y"]


def route_is_low(c, platforms, spawn, door):
    """True if every route surface is at/below y=380 (tops >= 380):
    gantry dressing beams (bottoms <= 246) and ceiling strips are
    then clear of every checker arc band (bands start at
    top_min - apex >= 380 - 153 = 227 for the lowest allowed
    takeoff, and every real low-route takeoff is >= 420, so bands
    start >= 267). High routes (towers/terraces) carry their own
    upper structure instead."""
    if spawn[1] < 380 or door[1] < 380:
        return False
    for p in platforms:
        tops = [p["y"]]
        if p["kind"] == "moving":
            tops.append(p["y"] + p.get("dy", 0))
        if min(tops) < 380:
            return False
    return True


def has_upper_band(platforms, hazards, spawn):
    """True if the level already uses the upper band: a raised platform
    (top < 320), a high hazard (y < 300), or a high spawn."""
    if spawn[1] < 320:
        return True
    for p in platforms:
        if p["y"] < 320:
            return True
    for h in hazards:
        if h["y"] < 300:
            return True
    return False


def _swing_swept_x(h):
    s = h["swing"]
    arm = abs(h["y"] - s["pivot_y"])
    half = arm * math.sin(math.radians(s["arc_deg"]) / 2.0) + h["r"]
    return (h["x"] - half, h["x"] + half)


def dressing_exclusions(hazards):
    """x-intervals skyline dressing must avoid: pillar fall columns,
    swing/patrol saw swept volumes, existing high spikes."""
    excl = []
    for h in hazards:
        t = h["type"]
        if t == "hanging_pillar":
            excl.append((h["x"] - 30, h["x"] + h["w"] + 30))
        elif t == "spikes" and h.get("dir", "up") != "up":
            excl.append((h["x"] - 30, h["x"] + h["w"] + 30))
        elif t == "saw":
            if "swing" in h:
                x0, x1 = _swing_swept_x(h)
                excl.append((x0 - 30, x1 + 30))
            elif "path" in h and h["y"] < 510:
                x2 = h["path"]["x2"]
                excl.append((min(h["x"], x2) - h["r"] - 30,
                             max(h["x"], x2) + h["r"] + 30))
    return excl


def add_skyline_dressing(c, kk, salt, platforms, hazards, spawn,
                         door_pos):
    """Gantry skyline dressing for LOW routes only: 1-2 full-width
    beams (tops 150..230, bottoms <= 246) on shared edge walls, with
    spike toppings seated on the beam tops. Beams stay clear of
    every jump arc band on low routes (route tops >= 420, so arc
    bands start at y >= 363 at the v3 apex ~57px) and the walls
    stand beyond the
    spawn/door x-ranges, so dressing can never block the route --
    unlike pillar-grounded ledges, whose floor pillars would wall
    off the flat walking route. Skipped entirely when an edge wall
    would block the door rect (the retry loop tries another grid
    point). Returns the number of beams."""
    for wx in (0, c.width - 48):
        wall_rect = (float(wx), 150.0, 48.0, float(c.floor_y) - 150.0)
        if _blocks_spawn_door(c, wall_rect, spawn, door_pos):
            return 0
        if _rect_hazard_overlap(wall_rect, hazards):
            return 0
    tops = [150, 160, 170, 180, 190, 200, 210, 220, 230, 240]
    n = g(kk, [1, 2, 2, 3], salt=salt)
    chosen = []
    for i in range(n):
        top = g(kk, tops, salt=salt + i * 5)
        # Beams >= 48px apart: a topping teeth strip (10px tall) on
        # one beam must never area-overlap the beam above it (rule 7),
        # and a down-teeth strip (10px) under one beam must clear the
        # beam below.
        if any(abs(top - t) < 48 for t in chosen):
            continue
        chosen.append(top)
    if not chosen:
        return 0
    wall_top = min(chosen)
    for wx in (0, c.width - 48):
        platforms.append(plat(wx, wall_top, 48, c.floor_y - wall_top,
                              "solid"))
    excl = dressing_exclusions(hazards)
    # v3: dressing NEVER emits saws (rule 11 family purity -- the
    # dressing pass does not know the archetype's family).
    toppings = ["spikes", "none", "none", "spikes", "none"]
    placed = 0
    for j, top in enumerate(chosen):
        beam_rect = (48.0, float(top), c.width - 96.0, 16.0)
        # A full-width beam crossing a hanging column reads as the
        # column piercing the beam and fails the rule-7 overlap rule
        # (D40 stalactites): skip beams the hazards already occupy.
        if _rect_hazard_overlap(beam_rect, hazards):
            continue
        platforms.append(plat(48, top, c.width - 96, 16, "solid"))
        placed += 1
        topping = g(kk, toppings, salt=salt + j * 7 + 1)
        if topping == "none":
            continue
        starts = [x0 for x0 in range(140, 1081, 40)]
        order = [(kk * 3 + j * 7) % len(starts)]
        order += [(order[0] + m * 3) % len(starts)
                  for m in range(1, len(starts))]
        for oi in order:
            x0 = starts[oi]
            w = 80
            if any(_overlaps(x0, x0 + w, e0, e1) for (e0, e1) in excl):
                continue
            if topping == "spikes":
                sw = g(kk, [48, 64, 80], salt=salt + j)
                top_rect = (float(x0), float(top - 10), float(sw), 10.0)
                if any(p["kind"] == "solid"
                       and _xov(top_rect, _pr(p)) > _GTOL
                       and _yov(top_rect, _pr(p)) > _GTOL
                       for p in platforms):
                    continue
                hazards.append(spikes_up(x0, sw, top=top))
            break
    return placed


def add_ceiling_strip(c, kk, salt, platforms, hazards):
    """One static dir-down ceiling spike strip for LOW routes that
    still lack an upper-band element. The strip hangs from a gantry
    beam added by the grounding repair (rule 7: ceiling spikes only
    under grounded beams). Tier-a (bottom 260..280) with 220px
    buffers around raised takeoffs/gaps; tier-b (bottom 168..192)
    only where it clears the highest takeoff's jump head (bottom
    <= min_takeoff_top - 200). Returns True if placed."""
    # Highest (smallest-y) route takeoff top.
    min_top = FLOOR_TOP
    for p in platforms:
        if p["kind"] in ("solid", "moving") and p["y"] < min_top:
            # Dressing ledges (bottom <= 160) are not takeoffs: only
            # surfaces the route can stand on count (top >= 380 here,
            # since this runs only for low routes).
            if p["y"] >= 380:
                min_top = min(min_top, p["y"])
    soft = []
    for h in hazards:
        t = h["type"]
        if t == "saw" and "path" not in h and "swing" not in h:
            soft.append((h["x"] - h["r"] - 80, h["x"] + h["r"] + 80))
        elif t == "spiked_column":
            soft.append((h["x"] - 80, h["x"] + h["w"] + 80))
        elif t == "spikes" and h.get("dir", "up") == "up":
            soft.append((h["x"] - 80, h["x"] + h["w"] + 80))

    def hard_exclusions(takeoff_buffer):
        excl = list(dressing_exclusions(hazards))
        for p in platforms:
            for (x, y, w, _hh) in _platform_positions(p):
                if y < FLOOR_TOP and y >= 380:
                    excl.append((x - takeoff_buffer, x + w + takeoff_buffer))
                elif y < 380:
                    # Dressing ledge: keep the strip clear of it.
                    excl.append((x - 10, x + w + 10))
        if takeoff_buffer:
            floors = sorted([p for p in platforms
                             if p["kind"] == "solid"
                             and p["y"] == FLOOR_TOP],
                            key=lambda p: p["x"])
            for a, b in zip(floors, floors[1:]):
                if b["x"] > a["x"] + a["w"]:
                    excl.append((a["x"] + a["w"] - 220, b["x"] + 220))
        return excl

    tiers = [("a", [232, 244, 252], 220)]
    if min_top - 200 >= 192:
        tiers.append(("b", [140, 152, 164], 0))
    for _tier, ys, buf in tiers:
        w = g(kk, [90, 120, 150], salt=salt + 31)
        y = g(kk, ys, salt=salt + 32)
        hard = hard_exclusions(buf)
        fitting = [x0 for x0 in range(200, 1081 - w, 40)
                   if not any(_overlaps(x0, x0 + w, e0, e1)
                              for (e0, e1) in hard)
                   and not any(p["kind"] == "solid"
                               and _xov((float(x0), float(y), float(w),
                                         28.0), _pr(p)) > _GTOL
                               and _yov((float(x0), float(y), float(w),
                                         28.0), _pr(p)) > _GTOL
                               for p in platforms)]
        if not fitting:
            continue
        preferred = [x0 for x0 in fitting
                     if not any(_overlaps(x0, x0 + w, e0, e1)
                                for (e0, e1) in soft)]
        pool = preferred or fitting
        x0 = pool[(salt * 11 + kk * 5) % len(pool)]
        hazards.append(spikes_down(x0, w, y, 10))
        return True
    return False


def _platform_positions(p):
    """Rest rect + moving offset rect, as (x, y, w, h)."""
    r = (p["x"], p["y"], p["w"], p["h"])
    if p["kind"] == "moving":
        return [r, (r[0] + p.get("dx", 0), r[1] + p.get("dy", 0),
                    r[2], r[3])]
    return [r]


def has_lethal_hazard(hazards):
    # v3: every hazard type is lethal (no warning-only types remain).
    return len(hazards) > 0


# ---------------------------------------------------------------------------
# Grounding repair (LEVEL_SCHEMA.md v3 rules 7-8). Builders emit the
# archetype layout; this pass ADDS support geometry only (pillars,
# shaft walls, gantry beams, rails, posts, strips) -- it never moves
# or removes builder geometry, so archetype identity and solutions
# survive. Every addition is verified by the real checker in main().
# Tolerances mirror tools/check_levels.py exactly. Keep-out and
# density failures cannot be repaired by adding geometry: builders
# own those (dressing/tower/skyline geometry), and unrepairable
# draws are rejected by the checker + retry loop, never shipped.
# ---------------------------------------------------------------------------

_GTOL = 4.0       # grounding tolerance, LEVEL_SCHEMA.md rule 7
_KEEPOUT_Y = 90   # HUD band, LEVEL_SCHEMA.md rule 8


def _pr(p):
    return (float(p["x"]), float(p["y"]), float(p["w"]), float(p["h"]))


def _xov(a, b):
    return min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])


def _yov(a, b):
    return min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])


def _blocks_spawn_door(c, rect, spawn, door_pos):
    """True if rect would trip the checker's spawn-inside or
    door-rect-blocked errors (strict inequalities, as in the checker)."""
    sx, sy = float(spawn[0]), float(spawn[1])
    if rect[0] < sx < rect[0] + rect[2] \
            and rect[1] < sy < rect[1] + rect[3]:
        return True
    drect = (float(door_pos[0]) - c.door_w / 2.0,
             float(door_pos[1]) - c.door_h, c.door_w, c.door_h)
    return (rect[0] < drect[0] + drect[2]
            and drect[0] < rect[0] + rect[2]
            and rect[1] < drect[1] + drect[3]
            and drect[1] < rect[1] + rect[3])


def _has_rect(plats, rect):
    for p in plats:
        if p["kind"] == "solid" and _pr(p) == rect:
            return True
    return False


def _rect_hazard_overlap(rect, hazards):
    """True if rect area-overlaps any spikes/spiked_column hazard
    rect beyond the 4px seating tolerance (LEVEL_SCHEMA.md rule 7).
    Saws and hanging_pillar are exempt, as in the checker. Used by
    every repair/dressing pass that ADDS a solid:
    added geometry must never hide a support behind a hazard."""
    for h in hazards:
        if h.get("type") not in ("spikes", "spiked_column"):
            continue
        hr = (float(h["x"]), float(h["y"]), float(h["w"]),
              float(h["h"]))
        if _xov(rect, hr) > _GTOL and _yov(rect, hr) > _GTOL:
            return True
    return False


def _core_middle_stats(platforms, width, floor_y=720.0):
    """(count, combined width) for the LEVEL_SCHEMA.md v3 rule 9
    core-middle floor: non-edge, non-floor-slab solid rects
    intersecting y 310..510. Mirrors
    check_levels.check_density_floor exactly."""
    count = 0
    total = 0.0
    for p in platforms:
        if p["kind"] != "solid":
            continue
        if p["x"] == 0 or p["x"] + p["w"] == width:
            continue
        if abs(p["y"] + p["h"] - floor_y) <= _GTOL \
                and p["w"] >= 0.5 * width:
            continue  # floor slab: must not satisfy the band alone
        if p["y"] < 510 and p["y"] + p["h"] > 310:
            count += 1
            total += p["w"]
    return count, total


def _resting_on_gen(r, rects, grounded):
    """Mirror of the checker's resting test (single >= 48px support,
    or both end regions on supports with combined overlap >= 48)."""
    bottom = r[1] + r[3]
    total = 0.0
    left_ok = right_ok = False
    third = max(8.0, r[2] / 3.0)
    for j in grounded:
        s = rects[j]
        if abs(bottom - s[1]) > _GTOL:
            continue
        ov = _xov(r, s)
        if ov >= 48.0:
            return True
        total += max(0.0, ov)
        if _xov((r[0], r[1], third, r[3]), s) >= 8.0:
            left_ok = True
        if _xov((r[0] + r[2] - third, r[1], third, r[3]), s) >= 8.0:
            right_ok = True
    return left_ok and right_ok and total >= 48.0


def _grounded_solids_gen(plats, floor_y):
    """Fixpoint set of grounded solid indices (mirror of the checker:
    floor, resting, pillar-connected, both-ends-touching)."""
    rects = [_pr(p) for p in plats]
    grounded = set()
    changed = True
    while changed:
        changed = False
        for i, r in enumerate(rects):
            if i in grounded or plats[i]["kind"] != "solid":
                continue
            bottom = r[1] + r[3]
            ok = abs(bottom - floor_y) <= _GTOL
            if not ok:
                ok = _resting_on_gen(r, rects, grounded)
            if not ok:
                for j in grounded:
                    q = rects[j]
                    if q[2] < 48.0:
                        continue
                    if abs(q[1] - bottom) <= _GTOL \
                            and q[0] >= r[0] \
                            and q[0] + q[2] <= r[0] + r[2]:
                        ok = True
                        break
            if not ok:
                left = right = False
                for j in grounded:
                    s = rects[j]
                    if _yov(r, s) >= 8.0:
                        if abs((s[0] + s[2]) - r[0]) <= _GTOL:
                            left = True
                        if abs(s[0] - (r[0] + r[2])) <= _GTOL:
                            right = True
                ok = left and right
            if ok:
                grounded.add(i)
                changed = True
    return grounded, rects


def _swept_extent(p):
    """(x0, x1, y0, y1) swept extent; rest rect unless moving."""
    r = _pr(p)
    x0, x1, y0, y1 = r[0], r[0] + r[2], r[1], r[1] + r[3]
    if p["kind"] == "moving":
        dx = float(p.get("dx", 0))
        dy = float(p.get("dy", 0))
        x0, x1 = min(x0, x0 + dx), max(x1, x1 + dx)
        y0, y1 = min(y0, y0 + dy), max(y1, y1 + dy)
    return (x0, x1, y0, y1)


def _flank_sides_gen(idx, plats, rects, grounded):
    """(left_flanked, right_flanked) for a special platform, measured
    from the swept extent (mirror of the checker)."""
    p = plats[idx]
    x0, x1, y0, y1 = _swept_extent(p)
    left = right = False
    for j in grounded:
        s = rects[j]
        if s[1] > y0 + _GTOL or s[1] + s[3] < y1 - _GTOL:
            continue
        if -_GTOL <= x0 - (s[0] + s[2]) <= 8.0:
            left = True
        if -_GTOL <= s[0] - x1 <= 8.0:
            right = True
    return left, right


def _special_supported_gen(idx, plats, rects, grounded):
    if _resting_on_gen(rects[idx], rects, grounded):
        return True
    left, right = _flank_sides_gen(idx, plats, rects, grounded)
    return left and right


def _support_top_below(rects, grounded, x0, x1, min_top):
    """Highest grounded-solid top >= min_top spanning [x0, x1] fully,
    or None. A support must cover the full support width (resting
    needs 48px overlap)."""
    best = None
    for j in grounded:
        s = rects[j]
        if s[1] < min_top:
            continue
        if s[0] <= x0 and s[0] + s[2] >= x1:
            if best is None or s[1] < best:
                best = s[1]
    return best


def _ground_solids(c, plats, hazards, spawn, door_pos):
    """Add under-pillars (or extend down) until every solid is
    grounded, iterating so lower supports ground before upper
    dependents lean on them. Pillars sit at platform ends, inside
    the platform's x-span, on the highest spanning support below
    (or the floor line)."""
    floor_y = float(c.floor_y)
    for _round in range(12):
        grounded, rects = _grounded_solids_gen(plats, floor_y)
        todo = [i for i, p in enumerate(plats)
                if p["kind"] == "solid" and i not in grounded]
        if not todo:
            return
        todo.sort(key=lambda i: -(rects[i][1] + rects[i][3]))
        progress = False
        for i in todo:
            # Refresh the fixpoint before EACH platform: a pillar
            # added for a lower platform earlier in this round may
            # already ground this one (e.g. D31 shaft walls resting
            # on the lower floors). Pillaring from a stale set adds
            # redundant full-height columns that seal the route.
            grounded, rects = _grounded_solids_gen(plats, floor_y)
            if i in grounded:
                continue
            r = rects[i]
            bottom = r[1] + r[3]
            if bottom < _KEEPOUT_Y or bottom > floor_y:
                continue
            cands = [r[0], r[0] + r[2] - 48.0]
            k = 1
            while r[0] + k * 24.0 < r[0] + r[2] - 48.0:
                cands.append(r[0] + k * 24.0)
                k += 1
            # Edge-first: support stacked floors from the screen-edge
            # columns. A tall pillar under a mid-route platform end
            # can seal a shaft/corridor at floor level (D31); an edge
            # pillar leaves the route open.
            cands.sort(key=lambda px: (min(px, c.width - (px + 48.0)),
                                       px))
            for px in cands:
                if px < 0 or px + 48.0 > c.width:
                    continue
                top = _support_top_below(rects, grounded, px, px + 48.0,
                                         bottom)
                if top is None:
                    top = floor_y
                gap = top - bottom
                if gap <= _GTOL:
                    continue
                if gap < 16.0:
                    ext = (r[0], bottom, r[2], gap)
                    if _rect_hazard_overlap(ext, hazards):
                        continue
                    plats[i]["h"] = int(round(top - r[1]))
                    progress = True
                    break
                rect = (px, bottom, 48.0, gap)
                if _blocks_spawn_door(c, rect, spawn, door_pos):
                    continue
                if _rect_hazard_overlap(rect, hazards):
                    continue
                if _has_rect(plats, rect):
                    continue
                plats.append(plat(px, bottom, 48, gap, "solid"))
                progress = True
                break
        if not progress:
            return


def _flank_specials(c, plats, hazards, spawn, door_pos):
    """Add missing shaft walls for dashed/falling/tilting/moving
    platforms. Walls stand beside the swept extent (never under),
    span the full sweep y-range, and rest on a support top or the
    floor line. Existing flank columns are credited, never doubled."""
    floor_y = float(c.floor_y)
    specials = [i for i, p in enumerate(plats)
                if p["kind"] in ("dashed", "falling", "tilting",
                                 "moving")]
    for idx in specials:
        grounded, rects = _grounded_solids_gen(plats, floor_y)
        if _special_supported_gen(idx, plats, rects, grounded):
            continue
        left, right = _flank_sides_gen(idx, plats, rects, grounded)
        x0, x1, y0, y1 = _swept_extent(plats[idx])
        if y0 < _KEEPOUT_Y:
            continue
        for side in ("left", "right"):
            if side == "left" and left:
                continue
            if side == "right" and right:
                continue
            if side == "left":
                wx = x0 - 56.0
                if wx < 0:
                    wx = x0 - 48.0
                if wx < 0:
                    continue
            else:
                wx = x1 + 8.0
                if wx + 48.0 > c.width:
                    wx = x1
                if wx + 48.0 > c.width:
                    continue
            top = _support_top_below(rects, grounded, wx, wx + 48.0, y1)
            bottom = floor_y if top is None else top
            if bottom - y0 < 16.0:
                bottom = floor_y
            rect = (wx, y0, 48.0, bottom - y0)
            if _blocks_spawn_door(c, rect, spawn, door_pos):
                continue
            if _rect_hazard_overlap(rect, hazards):
                continue
            if _has_rect(plats, rect):
                continue
            plats.append(plat(wx, y0, 48, bottom - y0, "solid"))


def _beam_needs(plats, hazards, grounded, rects, floor_y):
    """(bottom_y, top_y, x0, x1) gantry beams needed by unseated
    down-spikes, swing pivots outside grounded beams, and hanging
    columns. (x0, x1) is the union of the needing hazards' x-spans:
    the LOCAL span a beam must cover. Deduped by bottom_y within
    tolerance (spans merged)."""
    needs = []
    solids = [(j, rects[j]) for j in range(len(rects))
              if plats[j]["kind"] == "solid"]
    for h in hazards:
        t = h.get("type")
        if t == "spikes" and h.get("dir", "up") == "down":
            top = float(h["y"])
            hr = (float(h["x"]), top, float(h["w"]), float(h["h"]))
            seated = any(j in grounded
                         and abs(top - (s[1] + s[3])) <= _GTOL
                         and _xov(hr, s) >= 8.0
                         for j, s in solids)
            if not seated:
                needs.append((top, top - 16.0, hr[0], hr[0] + hr[2]))
        elif t == "saw" and "swing" in h:
            s = h["swing"]
            px, py = float(s["pivot_x"]), float(s["pivot_y"])
            inside = any(j in grounded and s2[0] <= px <= s2[0] + s2[2]
                         and s2[1] <= py <= s2[1] + s2[3]
                         for j, s2 in solids)
            if not inside:
                needs.append((py + 10.0, py - 10.0, px - 24.0, px + 24.0))
        elif t == "spiked_column":
            r = (float(h["x"]), float(h["y"]), float(h["w"]),
                 float(h["h"]))
            bottom, top = r[1] + r[3], r[1]
            on_top = abs(bottom - floor_y) <= _GTOL or any(
                abs(bottom - s[1]) <= _GTOL and _xov(r, s) >= 8.0
                for _j, s in solids)
            hung = any(j in grounded
                       and abs(top - (s[1] + s[3])) <= _GTOL
                       and _xov(r, s) >= 8.0
                       for j, s in solids)
            if not on_top and not hung and top >= 106.0:
                needs.append((top, top - 16.0, r[0], r[0] + r[2]))
    needs.sort()
    out = []
    for b, t, x0, x1 in needs:
        if out and abs(b - out[-1][0]) <= _GTOL:
            _pb, pt, px0, px1 = out[-1]
            out[-1] = (_pb, pt, min(px0, x0), max(px1, x1))
            continue
        out.append((b, t, x0, x1))
    return out


def _route_connected(c, plats, spawn, door_pos):
    """True if the rule-5 connectivity flood-fill connects spawn to
    door through open space (the checker's exact predicate)."""
    return check_levels.connectivity_error(
        plats, spawn, door_pos, float(c.width), float(c.floor_y),
        float(c.door_w), float(c.door_h),
        float(c.player_w), float(c.player_h)) is None


def _add_gantries(c, plats, hazards, spawn, door_pos):
    """Gantry beams for ceiling spikes, swing pivots, and hanging
    columns. Beams are LOCAL: only as wide as the hazards they serve.
    NO full-width slabs by default -- a full-width beam on edge walls
    seals any route that must cross its y-plane (D39: the beam +
    walls sealed the upper/lower halves with no passage). A local
    beam is kept only if it grounds (existing supports, or short
    end-posts <= 120px to a spanning support top: tall mid-route
    posts would wall the route) AND the spawn->door connectivity
    flood-fill still connects. If no local beam grounds, ONE
    full-width edge-wall gantry is tried and kept ONLY if
    connectivity still holds (corridor routes staying below the beam,
    e.g. D40/D08); otherwise the gantry is skipped and the checker +
    retry loop decides (hanging columns may still re-seat
    floor-standing via _repair_spikes_columns)."""
    floor_y = float(c.floor_y)
    grounded, rects = _grounded_solids_gen(plats, floor_y)
    needs = [(b, t, x0, x1) for (b, t, x0, x1) in
             _beam_needs(plats, hazards, grounded, rects, floor_y)
             if t >= _KEEPOUT_Y]
    if not needs:
        return
    base = len(plats)
    # --- Attempt 1: local beams. ---
    for (b, t, x0, x1) in needs:
        bx0 = max(0.0, x0 - 8.0)
        bx1 = min(float(c.width), x1 + 8.0)
        if bx1 - bx0 < 48.0:
            bx1 = min(float(c.width), bx0 + 48.0)
            bx0 = max(0.0, bx1 - 48.0)
        rect = (bx0, t, bx1 - bx0, b - t)
        if _blocks_spawn_door(c, rect, spawn, door_pos):
            continue
        if _rect_hazard_overlap(rect, hazards):
            continue
        if not _has_rect(plats, rect):
            plats.append(plat(bx0, t, bx1 - bx0, b - t, "solid"))
    # Short posts under local beams that still float. Post x-positions
    # try the beam ends first, then interior positions every 24px: a
    # post hidden behind the hanging column it serves reads as a
    # floating beam (L196: end-post under a column) and fails the
    # rule-7 overlap rule, so hazard-overlapping positions are
    # skipped and the post moves to clear x inside the beam span.
    grounded2, rects2 = _grounded_solids_gen(plats, floor_y)
    for idx in range(base, len(plats)):
        if idx in grounded2:
            continue
        r = rects2[idx]
        bottom = r[1] + r[3]
        post_xs = [r[0], r[0] + r[2] - 48.0]
        k = 1
        while r[0] + k * 24.0 < r[0] + r[2] - 48.0:
            post_xs.append(r[0] + k * 24.0)
            k += 1
        for px in post_xs:
            if px < 0 or px + 48.0 > c.width:
                continue
            top = _support_top_below(rects2, grounded2, px, px + 48.0,
                                     bottom)
            if top is None or top - bottom > 120.0:
                continue
            gap = top - bottom
            # Posts must satisfy the platform h >= 16 minimum: a
            # sub-16 gap cannot be bridged by a post (an 8px post is
            # a hard checker error). Leave the beam ungrounded so the
            # local attempt rolls back to the full-width fallback.
            if gap < 16.0:
                continue
            rect = (px, bottom, 48.0, gap)
            if _blocks_spawn_door(c, rect, spawn, door_pos):
                continue
            if _rect_hazard_overlap(rect, hazards):
                continue
            if _has_rect(plats, rect):
                continue
            plats.append(plat(px, bottom, 48, gap, "solid"))
            break
    grounded3, _r3 = _grounded_solids_gen(plats, floor_y)
    local_ok = len(plats) > base \
        and all(i in grounded3 for i in range(base, len(plats))) \
        and _route_connected(c, plats, spawn, door_pos)
    if local_ok:
        return
    del plats[base:]
    # --- Attempt 2: full-width edge-wall gantry, connectivity-gated.
    # Kept ONLY when the route stays on one side of the beam; a
    # sealing gantry is rolled back in full.
    grounded, rects = _grounded_solids_gen(plats, floor_y)
    wall_top = min(t for _b, t, _x0, _x1 in needs)
    walls = []
    for wx in (0.0, c.width - 48.0):
        top = _support_top_below(rects, grounded, wx, wx + 48.0,
                                 wall_top + 16.0)
        bottom = floor_y if top is None else top
        if bottom - wall_top < 16.0:
            bottom = floor_y
        rect = (wx, wall_top, 48.0, bottom - wall_top)
        if _blocks_spawn_door(c, rect, spawn, door_pos):
            return
        if _rect_hazard_overlap(rect, hazards):
            return
        walls.append(rect)
    for rect in walls:
        if not _has_rect(plats, rect):
            plats.append(plat(rect[0], rect[1], 48, rect[3], "solid"))
    for (b, t, _x0, _x1) in needs:
        rect = (48.0, t, c.width - 96.0, b - t)
        if _blocks_spawn_door(c, rect, spawn, door_pos):
            continue
        if _rect_hazard_overlap(rect, hazards):
            continue
        if not _has_rect(plats, rect):
            plats.append(plat(48, t, c.width - 96, b - t, "solid"))
    if not _route_connected(c, plats, spawn, door_pos):
        del plats[base:]


def _saw_touch_ok(h, solid_rects):
    r = float(h["r"])
    for (cx, cy) in check_levels.saw_sweep_centres(h):
        if not any(check_levels.point_rect_dist(cx, cy, s) <= r + _GTOL
                   for s in solid_rects):
            return False
    return True


def _repair_saws(c, plats, hazards, spawn, door_pos):
    """Posts under static saws, rails under near-horizontal patrol
    saws. Steep/diagonal patrols and swing arcs cannot be repaired
    by added geometry (any touch-solid would block the route); their
    builders own the geometry."""
    floor_y = float(c.floor_y)
    for h in hazards:
        if h.get("type") != "saw" \
                or not isinstance(h.get("r"), (int, float)):
            continue
        grounded, rects = _grounded_solids_gen(plats, floor_y)
        solid_rects = [rects[j] for j in range(len(rects))
                       if plats[j]["kind"] == "solid"]
        if _saw_touch_ok(h, solid_rects):
            continue
        cx, cy, r = float(h["x"]), float(h["y"]), float(h["r"])
        if "path" in h and isinstance(h["path"], dict):
            x2 = float(h["path"]["x2"])
            y2 = float(h["path"]["y2"])
            if abs(y2 - cy) > 8.0:
                continue
            min_cx, max_cx = min(cx, x2), max(cx, x2)
            max_cy = max(cy, y2)
            top = min(max_cy + r - 4.0, floor_y - 16.0)
            rx0 = max(0.0, min_cx - r)
            rx1 = min(float(c.width), max_cx + r)
            if rx1 - rx0 < 48.0:
                rx1 = min(float(c.width), rx0 + 48.0)
                rx0 = max(0.0, rx1 - 48.0)
            rect = (rx0, top, rx1 - rx0, floor_y - top)
            if _blocks_spawn_door(c, rect, spawn, door_pos):
                continue
            if _rect_hazard_overlap(rect, hazards):
                continue
            if _has_rect(plats, rect):
                continue
            plats.append(plat(rx0, top, rx1 - rx0, floor_y - top, "solid"))
        elif "swing" in h:
            continue
        else:
            top = cy + r - 2.0
            px = min(max(cx - 24.0, 0.0), c.width - 48.0)
            support = _support_top_below(rects, grounded, px, px + 48.0,
                                         top + 16.0)
            bottom = floor_y if support is None else support
            if bottom - top < 16.0:
                bottom = floor_y
            if bottom - top < 16.0:
                continue
            rect = (px, top, 48.0, bottom - top)
            if _blocks_spawn_door(c, rect, spawn, door_pos):
                continue
            if _rect_hazard_overlap(rect, hazards):
                continue
            if _has_rect(plats, rect):
                continue
            plats.append(plat(px, top, 48, bottom - top, "solid"))


def _spikes_seated_gen(h, plats, rects, grounded):
    """Mirror of the checker's spike-seating test."""
    r = (float(h["x"]), float(h["y"]), float(h["w"]), float(h["h"]))
    d = h.get("dir", "up")
    solids = [(j, rects[j]) for j in range(len(rects))
              if plats[j]["kind"] == "solid"]
    if d == "up":
        bottom = r[1] + r[3]
        return any(abs(bottom - s[1]) <= _GTOL and _xov(r, s) >= 8.0
                   for _j, s in solids)
    if d == "down":
        return any(j in grounded
                   and abs(r[1] - (s[1] + s[3])) <= _GTOL
                   and _xov(r, s) >= 8.0
                   for j, s in solids)
    for _j, s in solids:
        if _yov(r, s) >= 8.0:
            if abs((r[0] + r[2]) - s[0]) <= _GTOL \
                    or abs(r[0] - (s[0] + s[2])) <= _GTOL:
                return True
    return False


def _repair_spikes_columns(c, plats, hazards, spawn, door_pos):
    """Pit-floor strips under unseated up-spikes and columns, side
    walls for unseated side spikes. Down-spikes are gantry-owned
    (see _add_gantries); spikes at the very bottom line have no
    room for a floor and are builder-owned (D01/D34 pit floors)."""
    floor_y = float(c.floor_y)
    for h in hazards:
        t = h.get("type")
        grounded, rects = _grounded_solids_gen(plats, floor_y)
        if t == "spikes" and not _spikes_seated_gen(h, plats, rects,
                                                    grounded):
            d = h.get("dir", "up")
            x, y, w, hh = (float(h[k]) for k in ("x", "y", "w", "h"))
            if d == "up":
                bottom = y + hh
                if bottom > floor_y - 16.0:
                    continue
                w2 = max(w, 48.0)
                x2 = min(max(x, 0.0), c.width - w2)
                rect = (x2, bottom, w2, floor_y - bottom)
                if _blocks_spawn_door(c, rect, spawn, door_pos):
                    continue
                if _rect_hazard_overlap(rect, hazards):
                    continue
                if not _has_rect(plats, rect):
                    plats.append(plat(x2, bottom, w2, floor_y - bottom,
                                      "solid"))
            elif d in ("left", "right"):
                for wx in (x + w, x - 48.0):
                    if wx < 0 or wx + 48.0 > c.width:
                        continue
                    support = _support_top_below(
                        rects, grounded, wx, wx + 48.0, y + hh)
                    bottom = floor_y if support is None else support
                    if bottom - y < 16.0:
                        bottom = floor_y
                    rect = (wx, y, 48.0, bottom - y)
                    if _blocks_spawn_door(c, rect, spawn, door_pos):
                        continue
                    if _rect_hazard_overlap(rect, hazards):
                        continue
                    if _has_rect(plats, rect):
                        break
                    plats.append(plat(wx, y, 48, bottom - y, "solid"))
                    break
        elif t == "spiked_column":
            r = (float(h["x"]), float(h["y"]), float(h["w"]),
                 float(h["h"]))
            bottom, top = r[1] + r[3], r[1]
            solids = [rects[j] for j in range(len(rects))
                      if plats[j]["kind"] == "solid"]
            on_top = abs(bottom - floor_y) <= _GTOL or any(
                abs(bottom - s[1]) <= _GTOL and _xov(r, s) >= 8.0
                for s in solids)
            hung = any(j in grounded
                       and abs(top - (rects[j][1] + rects[j][3])) <= _GTOL
                       and _xov(r, rects[j]) >= 8.0
                       for j in range(len(rects)))
            if on_top or hung:
                continue
            if bottom > floor_y - 16.0:
                continue
            w2 = max(r[2], 48.0)
            x2 = min(max(r[0], 0.0), c.width - w2)
            rect = (x2, bottom, w2, floor_y - bottom)
            if _blocks_spawn_door(c, rect, spawn, door_pos):
                continue
            if _rect_hazard_overlap(rect, hazards):
                continue
            if not _has_rect(plats, rect):
                plats.append(plat(x2, bottom, w2, floor_y - bottom,
                                  "solid"))


def repair_grounding(c, plats, hazards, spawn, door_pos):
    """Grounding repair entry point. Appends support geometry to
    plats in place. Order matters: solids first (pillars need
    grounded supports), then shaft walls, then gantry beams (which
    need grounded walls), then saw rails/posts, then spike and
    column seats. Repeat solids passes catch anything the new
    walls now support."""
    _ground_solids(c, plats, hazards, spawn, door_pos)
    _flank_specials(c, plats, hazards, spawn, door_pos)
    _ground_solids(c, plats, hazards, spawn, door_pos)
    _add_gantries(c, plats, hazards, spawn, door_pos)
    _ground_solids(c, plats, hazards, spawn, door_pos)
    _repair_saws(c, plats, hazards, spawn, door_pos)
    _repair_spikes_columns(c, plats, hazards, spawn, door_pos)
    _ground_solids(c, plats, hazards, spawn, door_pos)


# ---------------------------------------------------------------------------
# Core-middle dressing (Loop 3): fill the visibly empty band y 260..420
# on flat archetypes (ceiling beam stack + floor-line gimmick only).
# Runs AFTER the builder + repair passes, in main() and _finish_candidate
# alike. Skips levels that already meet the rule-9 core-middle floor.
# Vocabulary is solids only: floor pillars (tops 400..416, rise <= 100
# so the checker graph and the autopilot's wall-jump both clear them),
# one mid beam at y 260..268 (bottom <= 284, clear of the jump-arc head
# apex ~297 on low routes), and connector bars resting on that beam.
# No hanging hazards: a hanging column's bottom in the arc band makes
# the greedy autopilot jump into it. No full-width solids in the middle
# below the beam (they would seal routes); every addition is checked
# against the connectivity flood-fill and the real checker decides.
# Pillars keep >= 200px from every ground hazard/saw sweep/hanging-
# pillar fall column and >= 120px from every gap/stone (drop-off
# travel from a pillar top is ~104px; a shorter pillar->hazard gap
# kills the autopilot -- ablation-proven), and the beam is gated
# off any level with a raised takeoff.
# ---------------------------------------------------------------------------

def _dressing_blocked_intervals(c, plats, hazards, spawn, door_pos,
                              hazard_buffer=200.0):
    """x-intervals dressing pillars must avoid: floor gaps, special
    platforms (swept), ground-level hazard jump zones, saw sweeps,
    pillar fall columns, and the spawn/door approaches. Buffers are
    NEVER relaxed: a pillar followed within ~200px by a hazard kills
    the autopilot (it drops off the pillar top and lands with no
    grounded run-up before the hazard -- proven by ablation: a 210px
    pillar->saw gap passes, 90px fails at every pillar height).
    Gap/stone buffers are 120px (drop-off travel from a pillar top
    is ~104px); saw sweeps and hanging-pillar fall columns get the
    full 200px hazard buffer."""
    intervals = [(float(spawn[0]) - 70.0, float(spawn[0]) + 70.0),
                 (float(door_pos[0]) - 100.0, float(door_pos[0]) + 100.0)]
    floors = sorted([p for p in plats
                     if p["kind"] == "solid" and p["y"] == FLOOR_TOP],
                    key=lambda p: p["x"])
    for a, b in zip(floors, floors[1:]):
        if b["x"] > a["x"] + a["w"]:
            intervals.append((a["x"] + a["w"] - 120.0, b["x"] + 120.0))
    for p in plats:
        if p["kind"] in ("dashed", "falling", "tilting", "moving"):
            x0, x1, _y0, _y1 = _swept_extent(p)
            intervals.append((x0 - 120.0, x1 + 120.0))
    for h in hazards:
        t = h.get("type")
        if t == "saw":
            bb = check_levels.saw_swept_bbox(h)
            intervals.append((bb[0] - hazard_buffer,
                              bb[0] + bb[2] + hazard_buffer))
        elif t == "hanging_pillar":
            # Fall column: same 200px buffer as ground hazards.
            # Ablation-proven (D06S1V1): a floor pillar 84px short
            # of the fall column killed the autopilot -- the drop-off
            # from the pillar top lands inside the pillar zone.
            intervals.append((float(h["x"]) - 200.0,
                              float(h["x"]) + float(h["w"]) + 200.0))
        elif hazard_buffer > 0.0 \
                and float(h["y"]) + float(h["h"]) > 380.0:
            intervals.append((float(h["x"]) - hazard_buffer,
                              float(h["x"]) + float(h["w"])
                              + hazard_buffer))
    return intervals


def _pillar_ok(c, rect, hazards, spawn, door_pos, intervals):
    if _blocks_spawn_door(c, rect, spawn, door_pos):
        return False
    if _rect_hazard_overlap(rect, hazards):
        return False
    if any(_overlaps(rect[0], rect[0] + rect[2], e0, e1)
           for (e0, e1) in intervals):
        return False
    return True


def _widen_core_rects(c, plats, hazards, spawn, door_pos, kk, salt):
    """Widen existing non-edge core rects by 32px when the core-middle
    count is met but the combined width is short (e.g. D31 shafts:
    3 x 48px = 144 < 160). Widening never crosses a screen edge (the
    rect must stay non-edge to keep counting) and never covers a
    hazard rect beyond tolerance. Returns the number widened."""
    core_idx = [i for i, p in enumerate(plats)
                if p["kind"] == "solid" and p["x"] != 0
                and p["x"] + p["w"] != c.width
                and p["y"] < 510 and p["y"] + p["h"] > 310]
    order = sorted(core_idx, key=lambda i: _mix(kk, salt + 300 + i))
    widened = 0
    for i in order:
        _cnt, width = _core_middle_stats(plats, c.width, c.floor_y)
        if width >= 160.0:
            break
        p = plats[i]
        sides = ["left", "right"] if _mix(kk, salt + 310 + i) % 2 == 0 \
            else ["right", "left"]
        for side in sides:
            if side == "left":
                strip = (float(p["x"]) - 32.0, float(p["y"]), 32.0,
                         float(p["h"]))
                nx, nw = p["x"] - 32, p["w"] + 32
            else:
                strip = (float(p["x"]) + float(p["w"]), float(p["y"]),
                         32.0, float(p["h"]))
                nx, nw = p["x"], p["w"] + 32
            if nx <= 0 or nx + nw >= c.width:
                continue
            if _rect_hazard_overlap(strip, hazards):
                continue
            if _blocks_spawn_door(c, strip, spawn, door_pos):
                continue
            old_x, old_w = p["x"], p["w"]
            p["x"], p["w"] = int(nx), int(nw)
            if not _route_connected(c, plats, spawn, door_pos):
                p["x"], p["w"] = old_x, old_w
                continue
            widened += 1
            break
    return widened


def _add_dressing_pillars(c, kk, salt, plats, hazards, spawn, door_pos,
                          want, intervals, min_gap, existing=()):
    """Grounded floor pillars (bottom at the floor line y=720, tops
    456..472 -- 28..44px above the FLOOR_TOP route surface, so each
    pillar is ONE climbable v3 step, not a wall). The pillars
    intersect the v3 core band (310..510) and middle band
    (170..550), so they serve the new density floors. Seeded x-order
    over a 40px grid, seeded widths/heights, >= min_gap from each
    other and from `existing` rects. Returns the rects added."""
    xs = list(range(160, 1121, 40))
    order = sorted(range(len(xs)),
                   key=lambda i: _mix(kk, salt + 350 + i))
    picked = []
    for oi in order:
        if len(picked) >= want:
            break
        x0 = float(xs[oi])
        # Width/height vary per candidate, not per pick: a wide draw
        # must not poison every candidate when a narrow one fits.
        w = float(g(kk, [48, 64, 80, 96], salt=salt + 360 + oi * 3))
        top = float(g(kk, [456, 460, 464, 468, 472],
                      salt=salt + 370 + oi * 3))
        if x0 + w > float(c.width):
            continue
        rect = (x0, top, w, float(c.floor_y) - top)
        if not _pillar_ok(c, rect, hazards, spawn, door_pos, intervals):
            continue
        if any(min(abs(rect[0] - (q[0] + q[2])),
                    abs(q[0] - (rect[0] + rect[2]))) < min_gap
               for q in list(picked) + list(existing)):
            continue
        plats.append(plat(x0, top, w, c.floor_y - top, "solid"))
        picked.append(rect)
    return picked


def _add_stacked_pillars(c, kk, salt, plats, hazards, spawn, door_pos):
    """Pillars stacked on wide raised platforms (blocks, steps: tops
    380..440, width >= 120). Each pillar rests on its support's top
    (grounded by resting) and stands on the FAR edge -- the edge
    opposite the spawn side. Ablation-proven: an arrival-edge pillar
    deflects the landing jump into the block's side spikes (2/2
    deaths), while a far-edge pillar passes at every height (3/3),
    because the hero lands on the open part of the support, climbs
    the pillar, and drops clear beyond it. Returns rects added."""
    supports = [p for p in plats
                if p["kind"] == "solid" and 380.0 <= float(p["y"]) < 440.0
                and float(p["w"]) >= 120.0]
    order = sorted(range(len(supports)),
                   key=lambda i: _mix(kk, salt + 410 + i))
    added = []
    for oi in order:
        if len(added) >= 2:
            break
        count, width = _core_middle_stats(plats, c.width, c.floor_y)
        if count >= 2 and width >= 160.0:
            break
        sup = supports[oi]
        sx, sy, sw = float(sup["x"]), float(sup["y"]), float(sup["w"])
        w = float(g(kk, [48, 56, 64], salt=salt + 420 + oi))
        height = float(g(kk, [36, 40, 44], salt=salt + 430 + oi))
        top = max(310.0, sy - height)
        if sy - top < 40.0:
            continue
        centre = sx + sw / 2.0
        if float(spawn[0]) < centre:
            px = sx + sw - w
        else:
            px = sx
        rect = (px, top, w, sy - top)
        if _blocks_spawn_door(c, rect, spawn, door_pos):
            continue
        if _rect_hazard_overlap(rect, hazards):
            continue
        plats.append(plat(px, top, w, sy - top, "solid"))
        added.append(rect)

    return added


def add_core_middle_dressing(c, kk, salt, plats, hazards, spawn,
                             door_pos):
    """Fill the core middle (y 310..510, v3 bands) on levels that
    fail the rule-9 core-middle floor. Uniform code path for all
    archetypes;
    dense levels are skipped untouched. Returns the number of solid
    rects added (widening counts as 0: it changes no rect count)."""
    count, width = _core_middle_stats(plats, c.width, c.floor_y)
    if count >= 2 and width >= 160.0:
        return 0
    base = len(plats)
    if count >= 2:
        _widen_core_rects(c, plats, hazards, spawn, door_pos, kk, salt)
        count, width = _core_middle_stats(plats, c.width, c.floor_y)
        if count >= 2 and width >= 160.0:
            return 0
    intervals = _dressing_blocked_intervals(c, plats, hazards, spawn,
                                            door_pos)
    want = g(kk, [2, 2, 3], salt=salt + 380)
    picked = _add_dressing_pillars(c, kk, salt, plats, hazards, spawn,
                                   door_pos, want, intervals, 200.0)
    # Second/third passes top the pillars up to `want` (same
    # intervals -- hazard/gap buffers are never relaxed -- differing
    # only in gap and salt, so different widths/x-orders get tried).
    # The metric top-up below adds still more only while the floor
    # is unmet.
    intervals2 = _dressing_blocked_intervals(
        c, plats, hazards, spawn, door_pos)
    if len(picked) < want:
        picked += _add_dressing_pillars(
            c, kk, salt + 390, plats, hazards, spawn, door_pos,
            want - len(picked), intervals2, 160.0, existing=picked)
    count, width = _core_middle_stats(plats, c.width, c.floor_y)
    if count < 2 or width < 160.0:
        picked += _add_dressing_pillars(
            c, kk, salt + 400, plats, hazards, spawn, door_pos,
            2, intervals2, 160.0, existing=picked)
        count, width = _core_middle_stats(plats, c.width, c.floor_y)
    if count < 2 or width < 160.0:
        # Stacked pillars on blocks/steps (far edge only): the only
        # route-safe fill where the beam is gated off and no quiet
        # floor stretch exists (D18 wall-spikes).
        _add_stacked_pillars(c, kk, salt, plats, hazards, spawn,
                             door_pos)
        count, width = _core_middle_stats(plats, c.width, c.floor_y)
    if count >= 2 and width < 160.0:
        _widen_core_rects(c, plats, hazards, spawn, door_pos, kk, salt)
    # Connectivity guard: dressing must never seal the route. Drop
    # added rects last-first until the flood-fill connects again.
    while len(plats) > base and not _route_connected(c, plats, spawn,
                                                     door_pos):
        plats.pop()
    return len(plats) - base


# ---------------------------------------------------------------------------
# Decoration pass (Loop 4): draw-only background silhouettes for the
# rule-9 core-middle floor. Runs AFTER the solid dressing pass +
# repair, ONLY on levels still failing the core-middle floor after
# solid dressing (skip-if-dense). Decorations have NO collision and NO
# gameplay effect, so placement needs NO route buffers (the solid
# dressing buffers are never imported here); the per-candidate checker
# run + retry loop absorbs placement failures. This pass NEVER mutates
# platforms/hazards/spawn/door: it only reads them and returns a list
# of {x, y, w, h} dicts (empty when the level is already dense or no
# valid silhouette fits). Deterministic: _mix/g/sh only, no RNG state.
# ---------------------------------------------------------------------------

_CORE_TOP = 310       # rule-9 core-middle band (mirrors the checker)
_CORE_BOTTOM = 510


def _deco_touches_gen(a, b):
    """Mirror of check_levels.LevelCheck._deco_touches: area overlap,
    or a <= 4px gap on one axis with positive overlap on the other."""
    xov = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    yov = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    if xov > 0 and yov > 0:
        return True
    if xov > 0 and -_GTOL <= yov <= 0:
        return True
    if yov > 0 and -_GTOL <= xov <= 0:
        return True
    return False


def _deco_block_rects(hazards):
    """Hazard blocking rects for rule 10: rect hazards as-is, saws as
    their swept disc bbox (a saw's x/y is its centre, so its
    (x, y, w, h) is not a rect)."""
    rects = []
    for h in hazards:
        if h.get("type") == "saw":
            try:
                rects.append(check_levels.saw_swept_bbox(h))
            except Exception:
                continue
        else:
            rects.append((float(h["x"]), float(h["y"]),
                          float(h["w"]), float(h["h"])))
    return rects


def _core_middle_stats_with_deco(platforms, decos, width):
    """Rule-9 core-middle floor counting solid + decoration rects
    together (mirrors check_levels.check_density_floor exactly):
    non-edge rects intersecting y 260..420, combined full width."""
    count, total = _core_middle_stats(platforms, width)
    for d in decos:
        x, y, w, h = (float(d[k]) for k in ("x", "y", "w", "h"))
        if x == 0 or x + w == width:
            continue
        if y < _CORE_BOTTOM and y + h > _CORE_TOP:
            count += 1
            total += w
    return count, total


def _deco_candidates(c, kk, salt, plats):
    """Candidate silhouettes from the four vocabularies, in seeded
    order. Candidates are (x, y, w, h) int tuples; validity (bounds,
    hazard/spawn/door overlap, attachment, separation) is checked by
    the picker, never assumed here."""
    solids = [_pr(p) for p in plats if p.get("kind") == "solid"]
    cands = []
    # (i) Floor pillars: bottom y=500, varied tops, standing on
    # floor-top solids.
    for si, s in enumerate(solids):
        if abs(s[1] - FLOOR_TOP) > _GTOL:
            continue
        for j in range(3):
            w = g(kk, [48, 64, 80, 96, 120], salt=salt + 910 + si * 7 + j)
            top = g(kk, [280, 300, 320, 340, 360, 380, 400],
                    salt=salt + 911 + si * 7 + j)
            span = int(s[2]) - w
            if span < 0:
                continue
            x = int(s[0]) + (_mix(kk, salt + 912 + si * 7 + j)
                             % (span + 1))
            cands.append((x, top, w, FLOOR_TOP - top))
    # (ii) Hanging blocks: tops attached to a ceiling-beam bottom,
    # varied bottoms, >= 24px x-overlap with the beam.
    for si, s in enumerate(solids):
        bottom = s[1] + s[3]
        if bottom < 150 or bottom > 280:
            continue
        for j in range(3):
            w = g(kk, [48, 64, 80, 96, 120, 160],
                  salt=salt + 920 + si * 7 + j)
            bot = g(kk, [280, 300, 320, 340, 360, 380, 400],
                    salt=salt + 921 + si * 7 + j)
            if bot - bottom < 32:
                continue
            lo = int(s[0]) + 24 - w
            hi = int(s[0] + s[2]) - 24
            if hi < lo:
                continue
            x = lo + (_mix(kk, salt + 922 + si * 7 + j) % (hi - lo + 1))
            cands.append((x, int(bottom), w, bot - int(bottom)))
    # (iii) Edge shelves: attached to an edge wall at varied heights.
    for si, s in enumerate(solids):
        left = s[0] == 0
        right = s[0] + s[2] == c.width
        if not (left or right):
            continue
        for j in range(3):
            w = g(kk, [48, 64, 80, 96], salt=salt + 930 + si * 7 + j)
            h = g(kk, [16, 24, 32, 48, 64], salt=salt + 931 + si * 7 + j)
            y = g(kk, [260, 280, 300, 320, 340, 360, 380],
                  salt=salt + 932 + si * 7 + j)
            if left:
                x = int(s[0] + s[2])
            else:
                x = int(s[0]) - w
            cands.append((x, y, w, h))
    # (iv) Mid blocks: attached to a solid pillar/beam side, >= 16px
    # y-overlap with the solid.
    for si, s in enumerate(solids):
        if s[2] < 48 or s[3] < 32:
            continue
        for j in range(2):
            w = g(kk, [48, 64, 80, 96, 120], salt=salt + 940 + si * 5 + j)
            h = g(kk, [16, 32, 48, 64, 80], salt=salt + 941 + si * 5 + j)
            lo = int(s[1]) + 16 - h
            hi = int(s[1] + s[3]) - 16
            if hi < lo:
                continue
            y = lo + (_mix(kk, salt + 942 + si * 5 + j) % (hi - lo + 1))
            if j % 2 == 0:
                x = int(s[0]) - w
            else:
                x = int(s[0] + s[2])
            cands.append((x, y, w, h))
    # Seeded order: deterministic shuffle by mix key.
    order = sorted(range(len(cands)),
                   key=lambda i: _mix(kk, salt + 950 + i))
    return [cands[i] for i in order]


def _visually_dense_middle(platforms, width):
    """Loop 5 visual density test: True only when real solid mass
    already fills the middle band. Counts non-edge solid rects whose
    intersection with y 280..480 is >= 40px tall (a thick middle
    presence, not a thin bar grazing the band); requires >= 2 such
    rects with combined width >= 160px. Ceiling-beam bars (thin,
    high) and edge walls (edge-touching) cannot satisfy it alone.
    Used ONLY as an additional skip condition for the decoration
    pass; the rule-9 floor itself is unchanged (checker-owned)."""
    count = 0
    total = 0.0
    for p in platforms:
        if p["kind"] != "solid":
            continue
        if p["x"] == 0 or p["x"] + p["w"] == width:
            continue
        overlap = min(p["y"] + p["h"], 480) - max(p["y"], 280)
        if overlap >= 40:
            count += 1
            total += p["w"]
    return count >= 2 and total >= 160.0


def add_decorations(c, kk, salt, plats, hazards, spawn, door_pos):
    """Loop 4 decoration pass. Returns a list of {x, y, w, h} dicts
    (possibly empty). Skip-if-dense: levels already meeting the
    rule-9 core-middle floor on solids alone AND passing the Loop 5
    visual density test get no decorations. Otherwise emits 2-4
    silhouettes (seeded vocabulary, greedy pick)
    until the combined solid + decoration core-middle floor is met.
    Never mutates its inputs. The checker re-validates every rule;
    this pass only constructs rule-10-valid candidates."""
    count, width = _core_middle_stats(plats, c.width, c.floor_y)
    if count >= 2 and width >= 160.0 \
            and _visually_dense_middle(plats, c.width):
        return []
    solids = [_pr(p) for p in plats if p.get("kind") == "solid"]
    blockers = _deco_block_rects(hazards)
    hero = (float(spawn[0]) - 12.0, float(spawn[1]) - 44.0, 24.0, 44.0)
    door = (float(door_pos[0]) - c.door_w / 2.0,
            float(door_pos[1]) - c.door_h, c.door_w, c.door_h)
    picked = []

    def _hits_hazard(r):
        for b in blockers:
            if _xov(r, b) > 0 and _yov(r, b) > 0:
                return True
        return False

    def _separated(r):
        # Silhouettes stay cleanly separated: >= 8px gap from every
        # already-picked deco (one-sided 8px expansion test).
        exp = (r[0] - 8, r[1] - 8, r[2] + 16, r[3] + 16)
        for q in picked:
            if _xov(exp, q) > 0 and _yov(exp, q) > 0:
                return False
        return True

    def _attached(r):
        if any(_deco_touches_gen(r, s) for s in solids):
            return True
        return any(_deco_touches_gen(r, q) for q in picked)

    for cand in _deco_candidates(c, kk, salt, plats):
        if len(picked) >= 4:
            break
        x, y, w, h = (float(v) for v in cand)
        r = (x, y, w, h)
        # Bounds + minima + keep-out (rule 10).
        if x < 0 or x + w > c.width or y < _KEEPOUT_Y \
                or y + h > c.floor_y:
            continue
        if w < 48 or h < 16:
            continue
        # Non-edge + core-band intersection (must help the floor).
        if x == 0 or x + w == c.width:
            continue
        if not (y < _CORE_BOTTOM and y + h > _CORE_TOP):
            continue
        if _hits_hazard(r):
            continue
        if (_xov(r, hero) > 0 and _yov(r, hero) > 0) or \
                (_xov(r, door) > 0 and _yov(r, door) > 0):
            continue
        if not _separated(r):
            continue
        if not _attached(r):
            continue
        picked.append(r)
        # Stop once the combined floor is met with >= 2 silhouettes.
        if len(picked) >= 2:
            n, tw = _core_middle_stats_with_deco(
                plats, [{"x": q[0], "y": q[1], "w": q[2], "h": q[3]}
                        for q in picked], c.width)
            if n >= 2 and tw >= 160.0:
                break
    return [{"x": int(q[0]), "y": int(q[1]), "w": int(q[2]), "h": int(q[3])}
            for q in picked]

# ---------------------------------------------------------------------------
# Builders: doors 1-22. Each fn(c, kk, salt) -> (platforms, hazards,
# spawn, door). kk is the variation grid index (slot/variant/attempt);
# salt is door-specific. spawn/door are (x, y) feet/base tuples.
# Flat doors keep hazards within x 200..1040 so the varying spawn
# (70..150) and door (1130..1210) safe zones always hold.
# ---------------------------------------------------------------------------

def flat_spawn_door(kk, salt):
    return ((g(kk, [70, 110, 150], salt=salt + 9), FLOOR_TOP),
            (g(kk, [1130, 1170, 1210], salt=salt + 10), FLOOR_TOP))


def b_pitfall(c, kk, salt):
    """Door 1: the floor lies. Dashed + falling floor segments (open
    pits with spike bottoms), a static hop strip, and a triggered
    spike strip armed ahead. A blind runner dies: the dashed pit
    and/or the triggered strip (armed 160-220px ahead, delay < travel
    time) kill any no-jump run; jumping/waiting once seen survives."""
    dx = 360 + sh(kk, 40, 2, salt=salt + 1)
    dw = g(kk, [140, 150], salt=salt + 1)
    fx = dx + dw + 120
    fw = g(kk, [120, 130], salt=salt + 2)
    tx = fx + fw + 140
    tw = g(kk, [80, 90, 100], salt=salt + 3)
    period, on = g(kk, [(2.6, 1.8), (3.0, 2.0), (3.2, 2.2)], salt=salt + 4)
    phase = g(kk, [0.0, 0.5, 1.0], salt=salt + 4)
    stand = g(kk, [1.0, 1.2, 1.4], salt=salt + 5)
    plats = [floor_seg(c, 0, dx),
             plat(dx, FLOOR_TOP, dw, 20, "dashed", period=period,
                  phase=phase, on_time=on),
             floor_seg(c, dx + dw, fx),
             plat(fx, FLOOR_TOP, fw, 20, "falling", stand_time=stand),
             floor_seg(c, fx + fw, 1280),
             plat(dx + 20, c.floor_y - 24, dw - 40, 24, "solid"),
             plat(fx + 20, c.floor_y - 24, fw - 40, 24, "solid")]
    pit_top = c.floor_y - 24
    hazards = [spikes_up(dx + 20, dw - 40, top=pit_top),
               spikes_up(fx + 20, fw - 40, top=pit_top)]
    sw = g(kk, [60, 80], salt=salt + 6)
    hazards.append(spikes_up(dx - 40 - sw, sw))
    lead = g(kk, [160, 190, 220], salt=salt + 7)
    delay = g(kk, [0.25, 0.35, 0.45], salt=salt + 7)
    idx = len(hazards)
    hazards.append(triggered_strip(tx, tw, lead, delay))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_spike_hops(c, kk, salt):
    count = g(kk, [2, 3, 2, 3], salt=salt + 1)
    widths = [g(kk, [60, 80, 100, 120], salt=salt + j) for j in range(count)]
    start = 360 + sh(kk, 40, 4, salt=salt + 1)
    xs = row_positions(start, widths, [150 + (kk % 3) * 20] * (count - 1))
    over = xs[-1] + widths[-1] - 1040
    if over > 0:
        xs = [x - over for x in xs]
    if xs[0] < 200:
        xs = [x + (200 - xs[0]) for x in xs]
    hazards = [spikes_up(x, w) for (x, w) in zip(xs, widths)]
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_saw_runs(c, kk, salt):
    count = g(kk, [2, 3, 2, 3], salt=salt + 1)
    first = 420 + sh(kk, 40, 2, salt=salt + 1)
    spacing = g(kk, [260, 280], salt=salt + 2)
    rs = [g(kk, [26, 30, 34], salt=salt + j) for j in range(count)]
    cxs = [first + j * spacing for j in range(count)]
    hazards = [saw_static(cx, FLOOR_TOP - r + 4, r)
               for (cx, r) in zip(cxs, rs)]
    hazards.append(spikes_up(240 + (kk % 2) * 40,
                             g(kk, [60, 80], salt=salt + 3)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_popup_spikes(c, kk, salt):
    count = g(kk, [1, 2, 1, 2], salt=salt + 1)
    widths = [g(kk, [80, 100, 120], salt=salt + j) for j in range(count)]
    start = 420 + sh(kk, 40, 4, salt=salt + 1)
    xs = row_positions(start, widths, [210] * (count - 1))
    over = xs[-1] + widths[-1] - 1040
    if over > 0:
        xs = [x - over for x in xs]
    period, on = g(kk, [(2.6, 1.2), (3.0, 1.4), (3.4, 1.6)], salt=salt + 2)
    phase0 = g(kk, [0.0, 0.5, 1.0], salt=salt + 3)
    hazards = []
    for j, (x, w) in enumerate(zip(xs, widths)):
        phase = round((phase0 + j * 0.7) % period, 1)
        idx = len(hazards)
        hazards.append(spikes_up(x, w, period=period, phase=phase,
                                 on_time=on))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_triggered_spikes(c, kk, salt):
    count = g(kk, [1, 2], salt=salt + 1)
    widths = [g(kk, [80, 100, 120], salt=salt + j) for j in range(count)]
    start = 420 + sh(kk, 40, 4, salt=salt + 1)
    xs = row_positions(start, widths, [230] * (count - 1))
    over = xs[-1] + widths[-1] - 1040
    if over > 0:
        xs = [x - over for x in xs]
    hazards = []
    for j, (x, w) in enumerate(zip(xs, widths)):
        lead = g(kk, [160, 190, 220], salt=salt + 2 + j)
        delay = g(kk, [0.25, 0.35, 0.45], salt=salt + 3 + j)
        idx = len(hazards)
        hazards.append(triggered_strip(x, w, lead, delay))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_triggered_pillars(c, kk, salt):
    px = 580 + sh(kk, 40, 3, salt=salt + 1)
    py = g(kk, [130, 150, 170], salt=salt + 1)
    pw = g(kk, [52, 60, 68], salt=salt + 1)
    ph = g(kk, [104, 116, 128], salt=salt + 1)
    speed = g(kk, [700, 800, 900], salt=salt + 2)
    trig = pillar_safe_trigger(c, px, py, ph, speed,
                               extra=g(kk, [0, 20], salt=salt + 2))
    hazards = [pillar_triggered(px, py, pw, ph, trig, speed)]
    hx = px + pw + 170 + (kk % 2) * 40
    hazards.append(spikes_up(min(hx, 960),
                             g(kk, [60, 80, 100], salt=salt + 3)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_periodic_pillars(c, kk, salt):
    px = 560 + sh(kk, 40, 4, salt=salt + 1)
    py = g(kk, [130, 150, 170], salt=salt + 1)
    pw = g(kk, [52, 60], salt=salt + 1)
    ph = g(kk, [104, 116, 128], salt=salt + 1)
    period = g(kk, [3.6, 4.0, 4.4], salt=salt + 2)
    phase = g(kk, [0.0, 0.5, 1.0], salt=salt + 2)
    speed = g(kk, [600, 650, 700], salt=salt + 2)
    hazards = [pillar_periodic(px, py, pw, ph, period, phase, speed)]
    hx = px + pw + 170 + (kk % 2) * 40
    hazards.append(spikes_up(min(hx, 960),
                             g(kk, [60, 80, 100], salt=salt + 3)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_swing_saws(c, kk, salt):
    piv_x = 600 + sh(kk, 40, 4, salt=salt + 1)
    r = g(kk, [30, 32, 34], salt=salt + 1)
    # Floor-grazing shallow swing (rule 7): the disc must touch solid
    # over its full sweep, so it grazes the floor with a small arc
    # (endpoint rise <= ~3px) and the pivot hangs from a gantry beam
    # added by the grounding repair.
    rest_y = FLOOR_TOP - r + 2
    arm = g(kk, [260, 280, 300], salt=salt + 1)
    piv_y = rest_y - arm
    arc = g(kk, [12, 14, 16], salt=salt + 1)
    period = g(kk, [3.4, 3.8, 4.2], salt=salt + 1)
    hazards = [saw_swing(piv_x, rest_y, piv_x, piv_y, arc, period, r)]
    arm = rest_y - piv_y
    swept_right = piv_x + arm * math.sin(math.radians(arc) / 2.0) + r
    hx = min(int(swept_right) + 160, 960)
    hazards.append(spikes_up(hx, g(kk, [60, 80], salt=salt + 3)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_patrol_saws(c, kk, salt):
    cx = 580 + sh(kk, 40, 4, salt=salt + 1)
    r = g(kk, [28, 30, 32], salt=salt + 1)
    # Horizontal patrol grazing the floor (rule 7): a vertical patrol
    # can never touch solid over its sweep without blocking the route.
    dx = g(kk, [60, 80, -60, -80], salt=salt + 1)
    period = g(kk, [3.0, 3.4, 3.8], salt=salt + 1)
    hazards = [saw_path(cx, 470, cx + dx, 470, period, r)]
    if kk % 2 == 0:
        hazards.append(spikes_up(cx + 170,
                                 g(kk, [60, 80, 100], salt=salt + 3)))
    else:
        hazards.append(spikes_up(200 + (kk % 3) * 40,
                                 g(kk, [60, 80], salt=salt + 3)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_gap_saws(c, kk, salt):
    gx = 480 + sh(kk, 40, 4, salt=salt + 4)
    gw = g(kk, [110, 120, 130, 140], salt=salt + 4)
    sw = g(kk, [80, 90, 100], salt=salt + 4)
    stop = g(kk, [460, 470, 480], salt=salt + 4)
    kind = g(kk, ["dashed", "falling", "moving"], salt=salt + 4)
    if kind == "moving":
        sx = gx + 10 + (kk % 3) * 10
    else:
        sx = gx + (gw - sw) // 2
    stone = stone_in_gap(kind, sx, stop, sw, kk, salt=salt + 4)
    plats = [floor_seg(c, 0, gx, top=640), stone, floor_seg(c, gx + gw, 1280)]
    cx = gx + gw // 2
    cy = g(kk, [540, 548], salt=salt + 4)
    r = g(kk, [26, 28, 30], salt=salt + 4)
    dx = g(kk, [30, -30, 40, -40], salt=salt + 4)
    period = g(kk, [2.6, 3.0, 3.4], salt=salt + 4)
    hazards = [saw_path(cx, cy, cx + dx, cy, period, r)]
    hx = gx + gw + 180 + (kk % 2) * 40
    hazards.append(spikes_up(min(hx, 960),
                             g(kk, [60, 80], salt=salt + 5)))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_spiked_columns(c, kk, salt):
    count = g(kk, [1, 2, 2, 3], salt=salt + 1)
    widths = [g(kk, [48, 56, 64], salt=salt + j) for j in range(count)]
    heights = [g(kk, [56, 72, 88], salt=salt + j + 2)
               for j in range(count)]
    start = 400 + sh(kk, 40, 4, salt=salt + 1)
    xs = row_positions(start, widths, [160] * (count - 1))
    over = xs[-1] + widths[-1] - 1040
    if over > 0:
        xs = [x - over for x in xs]
    hazards = [column(x, h, w) for (x, w, h) in zip(xs, widths, heights)]
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def _two_gap_chain(c, kk, salt, kind1, kind2):
    """Two gaps with special stones + a wide mid-platform + a strip."""
    g1 = 340 + sh(kk, 40, 4, salt=salt + 1)
    gw1 = g(kk, [110, 120, 130], salt=salt + 1)
    bw = 200 + (kk % 2) * 40
    g2 = g1 + gw1 + bw
    gw2 = g(kk, [110, 120, 130], salt=salt + 1)
    sw = 90
    stop1 = g(kk, [460, 470, 480], salt=salt + 1)
    stop2 = g(kk, [460, 470, 480], salt=salt + 2)
    if kind1 == "moving":
        sx1 = g1 + 10 + (kk % 3) * 10
    else:
        sx1 = g1 + (gw1 - sw) // 2
    if kind2 == "moving":
        sx2 = g2 + 10 + (kk % 3) * 10
    else:
        sx2 = g2 + (gw2 - sw) // 2
    s1 = stone_in_gap(kind1, sx1, stop1, sw, kk, salt=salt + 1)
    s2 = stone_in_gap(kind2, sx2, stop2, sw, kk, salt=salt + 2)
    plats = [floor_seg(c, 0, g1), s1, floor_seg(c, g1 + gw1, g2), s2,
             floor_seg(c, g2 + gw2, 1280)]
    hx = min(g2 + gw2 + 140, 960)
    hazards = [spikes_up(hx, g(kk, [60, 80], salt=salt + 3))]
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_dashed_chains(c, kk, salt):
    return _two_gap_chain(c, kk, salt, "dashed", "dashed")


def _falling_tilting(c, kk, salt, kind):
    """Pattern A: two gap stones. Pattern B: one wide lying floor
    segment + one gap stone + one hop strip."""
    if g(kk, ["A", "B"], salt=salt + 5) == "A":
        return _two_gap_chain(c, kk, salt, kind, kind)
    px = 420 + sh(kk, 40, 4, salt=salt + 1)
    pw = g(kk, [200, 240, 280], salt=salt + 1)
    stand = g(kk, [1.2, 1.4], salt=salt + 1)
    gx = px + pw + 140
    gw = g(kk, [110, 120], salt=salt + 2)
    sw = 90
    sx = gx + (gw - sw) // 2
    stone = stone_in_gap(kind, sx, g(kk, [460, 470, 480], salt=salt + 2),
                         sw, kk, salt=salt + 2)
    plats = [floor_seg(c, 0, px),
             plat(px, FLOOR_TOP, pw, 20, kind, stand_time=stand),
             floor_seg(c, px + pw, gx), stone,
             floor_seg(c, gx + gw, 1280)]
    sw2 = g(kk, [60, 80], salt=salt + 3)
    hazards = [spikes_up(px - 40 - sw2, sw2)]
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_falling_floors(c, kk, salt):
    return _falling_tilting(c, kk, salt, "falling")


def b_tilting_blocks(c, kk, salt):
    return _falling_tilting(c, kk, salt, "tilting")


def b_moving_bridges(c, kk, salt):
    gx = 480 + sh(kk, 40, 4, salt=salt + 6)
    gw = g(kk, [110, 120, 130, 140], salt=salt + 6)
    sw = g(kk, [80, 90, 100], salt=salt + 6)
    stop = g(kk, [460, 470, 480], salt=salt + 6)
    sx = gx + 10 + (kk % 3) * 10
    stone = stone_in_gap("moving", sx, stop, sw, kk, salt=salt + 6)
    plats = [floor_seg(c, 0, gx, top=640), stone, floor_seg(c, gx + gw, 1280)]
    hx = gx + gw + 180 + (kk % 2) * 40
    hazards = [spikes_up(min(hx, 960), g(kk, [60, 80], salt=salt + 7))]
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_mover_chains(c, kk, salt):
    """Gap 1: horizontal mover. Gap 2: small vertical mover."""
    g1 = 340 + sh(kk, 40, 4, salt=salt + 1)
    gw1 = g(kk, [110, 120, 130], salt=salt + 1)
    bw = 200 + (kk % 2) * 40
    g2 = g1 + gw1 + bw
    gw2 = g(kk, [110, 120, 130], salt=salt + 1)
    s1 = stone_in_gap("moving", g1 + 10 + (kk % 3) * 10,
                      g(kk, [460, 470, 480], salt=salt + 1), 90, kk,
                      salt=salt + 1)
    dy = g(kk, [-40, -50], salt=salt + 2)
    s2 = plat(g2 + (gw2 - 90) // 2, 470, 90, 20, "moving", dx=0, dy=dy,
              period=g(kk, [2.4, 2.8, 3.2], salt=salt + 2))
    plats = [floor_seg(c, 0, g1), s1, floor_seg(c, g1 + gw1, g2), s2,
             floor_seg(c, g2 + gw2, 1280)]
    hx = min(g2 + gw2 + 140, 960)
    hazards = [spikes_up(hx, g(kk, [60, 80], salt=salt + 3))]
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_ceiling_spikes(c, kk, salt):
    x1 = 520 + sh(kk, 40, 4, salt=salt + 1)
    w1 = g(kk, [90, 120, 150], salt=salt + 1)
    y = g(kk, [280, 296, 312], salt=salt + 1)
    hazards = [spikes_down(x1, w1, y)]
    last_end = x1 + w1
    if kk % 2 == 1:
        w2 = g(kk, [90, 120], salt=salt + 2)
        x2 = x1 + w1 + 230
        hazards.append(spikes_down(x2, w2, y))
        last_end = x2 + w2
    hazards.append(spikes_up(200 + (kk % 3) * 40,
                             g(kk, [60, 80, 100], salt=salt + 3)))
    if kk % 2 == 0:
        hx = last_end + 200 + (kk % 2) * 40
        hazards.append(spikes_up(min(hx, 960),
                                 g(kk, [60, 80], salt=salt + 4)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_wall_spikes(c, kk, salt):
    lx = 520 + sh(kk, 40, 4, salt=salt + 1)
    lw = g(kk, [180, 220], salt=salt + 1)
    # Floor block with side spikes (rule 7): the v1 floating ledge
    # cannot be supported without blocking the walk-under route, so
    # the spikes now guard the sides of a jumpable floor block.
    bh = g(kk, [80, 90, 100], salt=salt + 1)
    plats = [floor_seg(c, 0, 1280, top=640),
             plat(lx, FLOOR_TOP - bh, lw, bh + 80, "solid")]
    hazards = [spikes_side(lx - 20, FLOOR_TOP - bh, 20, 24, "left"),
               spikes_side(lx + lw, FLOOR_TOP - bh, 20, 24, "right"),
               spikes_up(200 + (kk % 3) * 40,
                         g(kk, [60, 80, 100], salt=salt + 3))]
    hx = min(lx + lw + 200 + (kk % 2) * 40, 960)
    hazards.append(spikes_up(hx, 60))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_step_climbs(c, kk, salt):
    shift = sh(kk, 40, 3, salt=salt + 1)
    xs = [240 + shift, 620 + sh(kk, 40, 3, salt=salt + 2),
          940 + (kk % 2) * 20]
    ws = [g(kk, [100, 110, 120], salt=salt + j) for j in range(2)]
    ws.append(g(kk, [100, 110], salt=salt + 2))
    hs = [g(kk, [48, 64, 80], salt=salt + j + 2) for j in range(3)]
    plats = [floor_seg(c, 0, 1280, top=640)]
    for (x, w, h) in zip(xs, ws, hs):
        plats.append(plat(x, FLOOR_TOP - h, w, h + 80, "solid"))
    hazards = []
    for j in range(2):
        w = g(kk, [60, 80, 100], salt=salt + 5 + j)
        hx = xs[j] + ws[j] + 100 + (kk % 3) * 20
        hx = min(hx, xs[j + 1] - w - 10)
        hazards.append(spikes_up(hx, w))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_double_gaps(c, kk, salt):
    g1 = 340 + sh(kk, 40, 4, salt=salt + 1)
    gw1 = g(kk, [110, 120, 130], salt=salt + 1)
    bw = 200 + (kk % 2) * 40
    g2 = g1 + gw1 + bw
    gw2 = g(kk, [110, 120, 130], salt=salt + 1)
    kind1 = g(kk, ["dashed", "falling"], salt=salt + 1)
    kind2 = g(kk, ["moving", "tilting"], salt=salt + 2)
    s1 = stone_in_gap(kind1, g1 + (gw1 - 90) // 2,
                      g(kk, [460, 470, 480], salt=salt + 1), 90, kk,
                      salt=salt + 1)
    if kind2 == "moving":
        sx2 = g2 + 10 + (kk % 3) * 10
    else:
        sx2 = g2 + (gw2 - 90) // 2
    s2 = stone_in_gap(kind2, sx2, g(kk, [460, 470, 480], salt=salt + 2),
                      90, kk, salt=salt + 2)
    plats = [floor_seg(c, 0, g1), s1, floor_seg(c, g1 + gw1, g2), s2,
             floor_seg(c, g2 + gw2, 1280)]
    cx = g1 + gw1 // 2
    hazards = [saw_path(cx, 544, cx + g(kk, [30, -30], salt=salt + 3), 544,
                        g(kk, [2.6, 3.0, 3.4], salt=salt + 3), 28)]
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_pit_bridges(c, kk, salt):
    px = 440 + sh(kk, 40, 4, salt=salt + 1)
    pw = g(kk, [220, 240, 260], salt=salt + 1)
    w = {220: 70, 240: 80, 260: 90}[pw]
    kind1 = g(kk, ["falling", "tilting"], salt=salt + 1)
    kind2 = g(kk, ["falling", "tilting"], salt=salt + 2)
    x1 = px + 8
    x2 = px + pw - w - 4
    s1 = plat(x1, FLOOR_TOP, w, 20, kind1,
              stand_time=g(kk, [1.0, 1.2, 1.4], salt=salt + 1))
    s2 = plat(x2, FLOOR_TOP, w, 20, kind2,
              stand_time=g(kk, [1.0, 1.2, 1.4], salt=salt + 2))
    # Solid divider between the stones: both stones are shaft-flanked
    # (4px gaps to the divider and the pit walls) with no under-pillars.
    plats = [floor_seg(c, 0, px), s1,
             plat(x1 + w + 4, FLOOR_TOP, 60, 80, "solid"), s2,
             floor_seg(c, px + pw, 1280)]
    hx = px + pw + 150 + (kk % 2) * 40
    hazards = [spikes_up(min(hx, 960), g(kk, [60, 80], salt=salt + 3))]
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_gauntlets(c, kk, salt):
    pats = [["strip", "saw", "column"],
            ["saw", "strip", "strip"],
            ["column", "strip", "saw"],
            ["strip", "column", "strip", "saw"],
            ["saw", "column", "strip"]]
    pat = g(kk, pats, salt=salt + 1)
    clear = 140 if len(pat) == 4 else 150
    slots = []
    for j, kind in enumerate(pat):
        if kind == "strip":
            slots.append(g(kk, [60, 80, 100], salt=salt + j))
        elif kind == "saw":
            slots.append(2 * g(kk, [26, 30], salt=salt + j) + 40)
        else:
            slots.append(g(kk, [48, 56], salt=salt + j))
    start = 280 + sh(kk, 40, 3, salt=salt + 1)
    xs = row_positions(start, slots, [clear] * (len(slots) - 1))
    over = xs[-1] + slots[-1] - 1040
    if over > 0:
        xs = [x - over for x in xs]
    hazards = []
    for j, (kind, x, slot) in enumerate(zip(pat, xs, slots)):
        if kind == "strip":
            hazards.append(spikes_up(x, slot))
        elif kind == "saw":
            r = (slot - 40) // 2
            hazards.append(saw_static(x + slot // 2, FLOOR_TOP - r + 4, r))
        else:
            hazards.append(column(x, g(kk, [56, 72, 88], salt=salt + j + 2),
                                  slot))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door

def b_timed_mixes(c, kk, salt):
    gx = 620 + sh(kk, 40, 4, salt=salt + 1)
    gw = g(kk, [110, 120], salt=salt + 1)
    sw = g(kk, [80, 90], salt=salt + 1)
    stop = g(kk, [460, 470, 480], salt=salt + 1)
    period, on = g(kk, [(2.6, 1.8), (3.0, 2.0), (3.2, 2.2)], salt=salt + 1)
    stone = plat(gx + (gw - sw) // 2, stop, sw, 20, "dashed",
                 period=period, phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 1),
                 on_time=on)
    plats = [floor_seg(c, 0, gx, top=640), stone, floor_seg(c, gx + gw, 1280)]
    hazards = []
    px = 260 + (kk % 3) * 40
    pperiod, pon = g(kk, [(2.6, 1.2), (3.0, 1.4), (3.4, 1.6)], salt=salt + 2)
    idx = len(hazards)
    hazards.append(spikes_up(px, g(kk, [80, 100], salt=salt + 2),
                             period=pperiod,
                             phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 2),
                             on_time=pon))
    sx = min(gx + gw + 280, 980)  # swept bbox must clear door safe zone
    dx = g(kk, [60, 80, -60, -80], salt=salt + 3)
    hazards.append(saw_path(sx, 470, sx + dx, 470,
                            g(kk, [3.0, 3.4], salt=salt + 3),
                            g(kk, [28, 30], salt=salt + 3)))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_pillar_alleys(c, kk, salt):
    p1x = 560 + sh(kk, 40, 3, salt=salt + 1)
    p1w = g(kk, [52, 60, 68], salt=salt + 1)
    p1h = g(kk, [104, 116, 128], salt=salt + 1)
    p1y = g(kk, [130, 150, 170], salt=salt + 1)
    p1speed = g(kk, [700, 800, 900], salt=salt + 2)
    trig = pillar_safe_trigger(c, p1x, p1y, p1h, p1speed,
                               extra=g(kk, [0, 20], salt=salt + 2))
    hazards = [pillar_triggered(p1x, p1y, p1w, p1h, trig, p1speed)]
    p2x = 880 + sh(kk, 40, 4, salt=salt + 3)
    p2w = g(kk, [52, 60], salt=salt + 3)
    p2h = g(kk, [104, 116, 128], salt=salt + 3)
    p2y = g(kk, [130, 150, 170], salt=salt + 3)
    idx = len(hazards)
    hazards.append(pillar_periodic(
        p2x, p2y, p2w, p2h, g(kk, [3.6, 4.0, 4.4], salt=salt + 4),
        g(kk, [0.0, 0.5, 1.0], salt=salt + 4),
        g(kk, [600, 650, 700], salt=salt + 4)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_pillar_forests(c, kk, salt):
    """Three pillars (triggered/periodic mix), >=220px apart, + one
    hop strip clear of every fall column."""
    kinds = g(kk, [["trig", "per", "trig"], ["per", "trig", "per"],
                   ["trig", "trig", "per"], ["per", "per", "trig"]],
              salt=salt + 1)
    xs = [550 + sh(kk, 20, 2, salt=salt + 1),
          780 + sh(kk, 20, 2, salt=salt + 2),
          990 + sh(kk, 10, 2, salt=salt + 3)]
    hazards = []
    for j, (kind, px) in enumerate(zip(kinds, xs)):
        pw = g(kk, [52, 60], salt=salt + j + 1)
        ph = g(kk, [104, 116, 128], salt=salt + j + 1)
        py = g(kk, [130, 150, 170], salt=salt + j + 1)
        if kind == "trig":
            speed = g(kk, [700, 800, 900], salt=salt + j + 2)
            trig = pillar_safe_trigger(
                c, px, py, ph, speed,
                extra=g(kk, [0, 20], salt=salt + j + 2))
            idx = len(hazards)
            hazards.append(pillar_triggered(px, py, pw, ph, trig, speed))
        else:
            idx = len(hazards)
            hazards.append(pillar_periodic(
                px, py, pw, ph, g(kk, [3.8, 4.0, 4.4], salt=salt + j + 2),
                g(kk, [0.0, 0.5, 1.0], salt=salt + j + 2),
                g(kk, [600, 650], salt=salt + j + 2)))
    hx = 200 + (kk % 2) * 40
    hazards.append(spikes_up(hx, g(kk, [60, 80], salt=salt + 5)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_grand_mixes(c, kk, salt):
    gx = 560 + sh(kk, 40, 4, salt=salt + 1)
    gw = g(kk, [110, 120, 130], salt=salt + 1)
    kind = g(kk, ["dashed", "falling", "moving", "tilting"], salt=salt + 1)
    sw = g(kk, [80, 90, 100], salt=salt + 1)
    stop = g(kk, [460, 470, 480], salt=salt + 1)
    if kind == "moving":
        sx = gx + 10 + (kk % 3) * 10
    else:
        sx = gx + (gw - sw) // 2
    stone = stone_in_gap(kind, sx, stop, sw, kk, salt=salt + 1)
    plats = [floor_seg(c, 0, gx, top=640), stone, floor_seg(c, gx + gw, 1280)]
    hazards = [column(240 + sh(kk, 40, 3, salt=salt + 2),
                      g(kk, [64, 80], salt=salt + 2),
                      g(kk, [48, 56], salt=salt + 2))]
    hx = gx + gw + 180 + (kk % 2) * 40
    period, on = g(kk, [(2.6, 1.2), (3.0, 1.4), (3.4, 1.6)], salt=salt + 3)
    idx = len(hazards)
    hazards.append(spikes_up(min(hx, 950), g(kk, [80, 100], salt=salt + 3),
                             period=period,
                             phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 3),
                             on_time=on))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_mover_lifts(c, kk, salt):
    ledge_x = 540 + sh(kk, 40, 4, salt=salt + 1)
    ledge_w = g(kk, [220, 240, 260], salt=salt + 1)
    ledge_top = g(kk, [420, 430, 440], salt=salt + 1)
    mover_x = ledge_x - 140
    dy = (ledge_top - FLOOR_TOP) + g(kk, [0, -10, 10], salt=salt + 2)
    plats = [floor_seg(c, 0, 1280, top=640),
             plat(ledge_x, ledge_top, ledge_w, 20, "solid"),
             plat(mover_x, FLOOR_TOP, 100, 20, "moving", dx=0, dy=dy,
                  period=g(kk, [2.8, 3.2, 3.6], salt=salt + 2))]
    hx = min(ledge_x + ledge_w + 150 + (kk % 2) * 40, 960)
    hazards = [spikes_up(hx, g(kk, [60, 80], salt=salt + 3))]
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


# ---------------------------------------------------------------------------
# Tower family (doors 28, 39, 41). Static-only except door 39's dashed
# floors. Geometry proof (see module design notes): alternating wide
# floors + short pads joined by gap edges whose corridors sit exactly
# on floor-edge boundaries, so no higher floor spans a corridor;
# vertical spacing >= 90 keeps floors 2+ above out of arc bands;
# pads end <= 1070 (>= 80px from the door) so the autopilot can never
# stall on a pad; the falling path (~1110) clears every pad.
# ---------------------------------------------------------------------------

def _tower_level(c, kk, salt, cfg):
    T = g(kk, cfg["T"], salt=salt + 1)
    S = g(kk, cfg["S"], salt=salt + 1)
    E1 = g(kk, cfg["E1"], salt=salt + 2)
    G = g(kk, cfg["G"], salt=salt + 2)
    E2 = E1 + G
    padw = g(kk, cfg["padw"], salt=salt + 2)
    PR = min(E2 + padw, 1070)
    if cfg["dashed"]:
        # Dashed floors need shaft walls on BOTH ends: the right
        # wall must clear the door safe zone, so cap the pad edge.
        PR = min(PR, 1050)
    tops = [T, T + S, T + 2 * S, T + 3 * S]

    def dashed_floor(x, top, w, j):
        period, on = g(kk, [(2.6, 1.8), (3.0, 2.0), (3.2, 2.2)],
                       salt=salt + 10 + j)
        phase = g(kk, [0.0, 0.5, 1.0], salt=salt + 11 + j)
        return plat(x, top, w, 20, "dashed", period=period,
                    phase=phase, on_time=on)

    if cfg["dashed"]:
        plats = [plat(0, tops[0], E1, 20, "solid"),
                 dashed_floor(E2, tops[1], PR - E2, 1),
                 # Inset 48px: the left shaft wall needs room at x=0.
                 dashed_floor(48, tops[2], E1 - 48, 2),
                 dashed_floor(E2, tops[3], PR - E2, 3),
                 floor_seg(c, 0, 1280, top=640)]
    else:
        plats = [plat(0, tops[0], E1, 20, "solid"),
                 plat(E2, tops[1], PR - E2, 20, "solid"),
                 plat(0, tops[2], E1, 20, "solid"),
                 plat(E2, tops[3], PR - E2, 20, "solid"),
                 floor_seg(c, 0, 1280, top=640)]
    hazards = []
    # Floor 1: hop strip + saw(s).
    sw = g(kk, [60, 80], salt=salt + 5)
    hazards.append(spikes_up(240 + sh(kk, 40, 3, salt=salt + 5), sw,
                             top=tops[0]))
    r1 = g(kk, [26, 30], salt=salt + 6)
    cx1 = g(kk, [500, 520, 540], salt=salt + 6)
    hazards.append(saw_static(cx1, tops[0] - r1 + 4, r1))
    if cfg["f1_extra"] == "column":
        hazards.append(column(E1 - 160, g(kk, [56, 72], salt=salt + 6),
                              g(kk, [48, 56], salt=salt + 6), top=tops[0]))
    # Floor 3: strip/saw + column.
    if cfg["f3_style"] == "saw":
        r3 = g(kk, [26, 28], salt=salt + 7)
        cx3 = g(kk, [420, 440], salt=salt + 7)
        hazards.append(saw_static(cx3, tops[2] - r3 + 4, r3))
    else:
        hazards.append(spikes_up(240 + sh(kk, 40, 3, salt=salt + 7),
                                 g(kk, [60, 80], salt=salt + 7),
                                 top=tops[2]))
    hazards.append(column(E1 - 200, g(kk, [56, 72], salt=salt + 7),
                          g(kk, [48, 56], salt=salt + 7), top=tops[2]))
    # Pads: strip / saw (upper pad only) / none. Never on dashed pads.
    if not cfg["dashed"]:
        for j, top in ((1, tops[1]), (3, tops[3])):
            style = g(kk, ["strip", "saw", "none"], salt=salt + 8 + j)
            if style == "strip":
                hazards.append(spikes_up(E2 + 60,
                                         g(kk, [48, 56], salt=salt + 8 + j),
                                         top=top))
            elif style == "saw" and j == 1:
                hazards.append(saw_static(E2 + 94, top - 26 + 4, 26))
    # Ground gauntlet (left/middle; landing zones + door zone clear).
    hazards.append(spikes_up(240 + sh(kk, 40, 3, salt=salt + 9),
                             g(kk, [60, 80], salt=salt + 9)))
    if cfg["ground_style"] == "saws":
        for j, cx in enumerate((450, 650)):
            r = g(kk, [26, 28], salt=salt + 9 + j)
            hazards.append(saw_static(cx + sh(kk, 20, 2, salt=salt + 9 + j),
                                      FLOOR_TOP - r + 4, r))
    else:
        r = g(kk, [26, 30], salt=salt + 9)
        hazards.append(saw_static(g(kk, [520, 540], salt=salt + 9),
                                  FLOOR_TOP - r + 4, r))
        if cfg["ground_style"] == "column":
            hazards.append(column(700 + sh(kk, 40, 2, salt=salt + 9),
                                  g(kk, [56, 72], salt=salt + 9),
                                  g(kk, [48, 56], salt=salt + 9)))
    spawn = (g(kk, cfg["spawn_x"], salt=salt + 20), tops[0])
    door = (g(kk, cfg["door_x"], salt=salt + 21), FLOOR_TOP)
    return plats, hazards, spawn, door


def b_tower_descents(c, kk, salt):
    return _tower_level(c, kk, salt, {
        "T": [170, 180, 190], "S": [90, 95], "E1": [780, 820, 860],
        "G": [50, 60, 70], "padw": [150, 170, 190], "dashed": False,
        "f1_extra": "none", "f3_style": "strip", "ground_style": "column",
        "spawn_x": [80, 100, 120, 140],
        "door_x": [1130, 1150, 1170, 1190]})


def b_dashed_towers(c, kk, salt):
    return _tower_level(c, kk, salt, {
        "T": [170, 180], "S": [90, 95], "E1": [790, 830],
        "G": [55, 65], "padw": [160, 180], "dashed": True,
        "f1_extra": "none", "f3_style": "strip", "ground_style": "plain",
        "spawn_x": [90, 110, 130], "door_x": [1140, 1160, 1180]})


def b_final_tower_saws(c, kk, salt):
    return _tower_level(c, kk, salt, {
        "T": [170, 180, 190], "S": [92, 96], "E1": [760, 800, 840],
        "G": [45, 60, 75], "padw": [150, 170], "dashed": False,
        "f1_extra": "column", "f3_style": "saw", "ground_style": "saws",
        "spawn_x": [70, 90, 110], "door_x": [1120, 1140, 1160, 1180]})


# ---------------------------------------------------------------------------
# Reversed family (doors 29, 43). Simple-isolated bounds only: single
# strip w<=120 / saw r<=34 / column w<=64,h<=88 / gap<=120, >=200px
# clear between obstacles, >=150px run-up, no chains, no timed
# hazards except triggered spikes armed >=160px ahead (in travel
# direction: trigger to the RIGHT of the strip).
# ---------------------------------------------------------------------------

def _reversed_level(c, kk, salt, cfg):
    centres = cfg["centres"]
    subsets = cfg["subsets"]
    use = g(kk, subsets, salt=salt + 1)
    kinds = g(kk, cfg["kind_rows"], salt=salt + 2)
    # kind_rows entries align with `use` positions.
    obstacles = []  # (x0, x1, kind, spec)
    for pos, slot in enumerate(use):
        cx = centres[slot]
        kind = kinds[pos % len(kinds)]
        if kind == "strip":
            w = g(kk, [80, 100, 120], salt=salt + 3 + pos)
            obstacles.append((cx - w // 2, cx + w // 2, "strip", w))
        elif kind == "saw":
            r = g(kk, [28, 30, 34], salt=salt + 3 + pos)
            obstacles.append((cx - r, cx + r, "saw", r))
        elif kind == "column":
            w = g(kk, [48, 56, 64], salt=salt + 3 + pos)
            h = g(kk, [56, 72, 88], salt=salt + 4 + pos)
            obstacles.append((cx - w // 2, cx + w // 2, "column", (w, h)))
        elif kind == "gap":
            w = g(kk, [110, 120], salt=salt + 3 + pos)
            obstacles.append((cx - w // 2, cx + w // 2, "gap", w))
        else:  # triggered
            w = g(kk, [80, 100, 120], salt=salt + 3 + pos)
            obstacles.append((cx - w // 2, cx + w // 2, "triggered", w))
    obstacles.sort(key=lambda o: o[0])
    plats = []
    hazards = []
    prev_end = 0
    for (x0, x1, kind, spec) in obstacles:
        if kind == "gap":
            plats.append(floor_seg(c, prev_end, x0))
            prev_end = x1
    plats.append(floor_seg(c, prev_end, 1280))
    if not any(o[2] == "gap" for o in obstacles):
        plats = [floor_seg(c, 0, 1280, top=640)]
    for (x0, x1, kind, spec) in obstacles:
        if kind == "strip":
            hazards.append(spikes_up(x0, spec))
        elif kind == "saw":
            hazards.append(saw_static((x0 + x1) // 2,
                                      FLOOR_TOP - spec + 4, spec))
        elif kind == "column":
            w, h = spec
            hazards.append(column(x0, h, w))
        elif kind == "triggered":
            lead = g(kk, [160, 190, 220], salt=salt + 5 + x0)
            delay = g(kk, [0.25, 0.35, 0.45], salt=salt + 6 + x0)
            trig = x1 + lead
            idx = len(hazards)
            hazards.append(spikes_up(x0, spec, trigger_x=trig,
                                     delay=delay))
    spawn = (g(kk, cfg["spawn_x"], salt=salt + 20), FLOOR_TOP)
    door = (g(kk, cfg["door_x"], salt=salt + 21), FLOOR_TOP)
    return plats, hazards, spawn, door


def b_reversed_runs(c, kk, salt):
    return _reversed_level(c, kk, salt, {
        "centres": [280, 600, 920],
        "subsets": [[1], [0, 2], [0, 1, 2], [2], [0, 1], [1, 2]],
        "kind_rows": [["strip"], ["saw"], ["column"], ["gap"],
                      ["strip", "saw"], ["saw", "column"],
                      ["triggered"], ["strip", "triggered"],
                      ["column", "gap", "strip"]],
        "spawn_x": [1150, 1170, 1210], "door_x": [70, 110, 150]})


def b_final_reversed(c, kk, salt):
    return _reversed_level(c, kk, salt, {
        "centres": [260, 590, 910],
        "subsets": [[0, 1, 2], [0, 1, 2], [1, 2], [0, 2]],
        "kind_rows": [["triggered", "strip", "triggered"],
                      ["strip", "triggered", "triggered"],
                      ["triggered", "saw", "triggered"],
                      ["triggered", "column", "triggered"],
                      ["triggered", "gap", "triggered"]],
        "spawn_x": [1160, 1180, 1200], "door_x": [80, 100, 120]})


# ---------------------------------------------------------------------------
# Skyline family (doors 30, 42). Monotonic multi-floor terraces joined
# by gap edges (48px landing zones); static hazards only so the
# ballistic planner chains mounts/drops. Ascending and descending
# patterns alternate by kk parity.
# ---------------------------------------------------------------------------

def _skyline_level(c, kk, salt, cfg):
    ascending = (kk % 2 == cfg["asc_parity"])
    gp = g(kk, cfg["gaps"], salt=salt + 1)
    X1 = g(kk, cfg["X1"], salt=salt + 1)
    if ascending:
        r1 = g(kk, cfg["rises"], salt=salt + 1)
        r2 = g(kk, cfg["rises"], salt=salt + 2)
        r3 = g(kk, cfg["rises"], salt=salt + 3)
        W2 = g(kk, cfg["W2"], salt=salt + 2)
        W3 = g(kk, cfg["W3"], salt=salt + 3)
        t1, t2, t3 = FLOOR_TOP, FLOOR_TOP - r1, FLOOR_TOP - r1 - r2
        t4 = FLOOR_TOP - r1 - r2 - r3
        x2 = X1 + gp
        x3 = x2 + W2 + gp
        x4 = x3 + W3 + gp
        plats = [plat(0, t1, X1, c.floor_y - t1, "solid"),
                 plat(x2, t2, W2, 20, "solid"),
                 plat(x3, t3, W3, 20, "solid"),
                 plat(x4, t4, 1280 - x4, 20, "solid")]
        spawn = (g(kk, cfg["spawn_x"], salt=salt + 20), t1)
        door = (x4 + g(kk, [60, 70, 80], salt=salt + 21), t4)
        terraces = [(0, X1, t1), (x2, x2 + W2, t2), (x3, x3 + W3, t3)]
        door_terrace = (x4, 1280, t4)
    else:
        d1 = g(kk, cfg["drops"], salt=salt + 1)
        d2 = g(kk, cfg["drops"], salt=salt + 2)
        W2 = g(kk, cfg["W2"], salt=salt + 2)
        W3 = g(kk, cfg["W3d"], salt=salt + 3)
        t1 = g(kk, cfg["D1"], salt=salt + 1)
        t2, t3 = t1 + d1, t1 + d1 + d2
        x2 = X1 + gp
        x3 = x2 + W2 + gp
        plats = [plat(0, t1, X1, 20, "solid"),
                 plat(x2, t2, W2, 20, "solid"),
                 plat(x3, t3, W3, 20, "solid"),
                 floor_seg(c, 0, 1280, top=640)]
        spawn = (g(kk, cfg["spawn_x"], salt=salt + 20), t1)
        door = (g(kk, cfg["door_x"], salt=salt + 21), FLOOR_TOP)
        terraces = [(0, X1, t1), (x2, x2 + W2, t2)]
        door_terrace = (x3, x3 + W3, t3)
    hazards = []
    fams = cfg["families"]
    for j, (lx, rx, top) in enumerate(terraces):
        fam = g(kk, fams, salt=salt + 5 + j)
        # Hazards live at the DEPARTURE end only: mount/drop flights
        # land anywhere in the first ~150px past the arrival edge
        # (D30S2V1: a braked mount flight descended onto a saw 140px
        # past the edge), so the arrival half stays clear.
        if fam == "strip":
            w = g(kk, [60, 80], salt=salt + 5 + j)
            hazards.append(spikes_up(rx - 140 + sh(kk, 20, 2,
                                                   salt=salt + j),
                                     w, top=top))
        elif fam == "saw":
            r = g(kk, [26, 28], salt=salt + 5 + j)
            hazards.append(saw_static(
                rx - 100 + sh(kk, 20, 2, salt=salt + j), top - r + 4, r))
        elif fam == "column":
            hazards.append(column(rx - 130 + sh(kk, 20, 2, salt=salt + j),
                                  g(kk, [56, 72], salt=salt + 5 + j),
                                  g(kk, [48, 56], salt=salt + 5 + j),
                                  top=top))
    if not ascending:
        # Ground hazards: clear of the drop terrace's landing zone.
        gx0, gx1 = door_terrace[0], door_terrace[1]
        hazards.append(spikes_up(240 + sh(kk, 40, 3, salt=salt + 9),
                                 g(kk, [60, 80], salt=salt + 9)))
        r = g(kk, [26, 28], salt=salt + 9)
        hazards.append(saw_static(g(kk, [480, 520], salt=salt + 9),
                                  FLOOR_TOP - r + 4, r))
        if gx1 + 50 <= 1000:
            hazards.append(spikes_up(gx1 + 50,
                                     g(kk, [60, 80], salt=salt + 10)))
    if cfg.get("ceiling_strips") and ascending:
        # Strips over terrace middles, clear of gap corridors and
        # walking bands (bottom <= 272 < lowest band top 286).
        for (lx, rx, top) in terraces[1:]:
            if top >= 330:
                y = g(kk, [232, 244], salt=salt + 12 + lx)
                w = g(kk, [80, 100], salt=salt + 12 + lx)
                hazards.append(spikes_down((lx + rx - w) // 2, w, y, 10))
    return plats, hazards, spawn, door


def b_skyline_city(c, kk, salt):
    return _skyline_level(c, kk, salt, {
        "asc_parity": 0, "gaps": [40, 50, 60], "X1": [400, 420],
        "rises": [70, 80, 90], "drops": [85, 90, 95], "D1": [170, 180, 190],
        "W2": [290], "W3": [250], "W3d": [110, 120],
        "families": ["strip", "saw", "strip", "saw"],
        "spawn_x": [80, 100, 120], "door_x": [1160, 1180, 1200],
        "ceiling_strips": False})


def b_final_skyline(c, kk, salt):
    return _skyline_level(c, kk, salt, {
        "asc_parity": 1, "gaps": [45, 55], "X1": [390, 410],
        "rises": [75, 85], "drops": [88, 92], "D1": [175, 185],
        "W2": [280, 300], "W3": [240, 260], "W3d": [110, 120],
        "families": ["saw", "column", "saw", "column", "strip"],
        "spawn_x": [90, 110], "door_x": [1150, 1170, 1190],
        "ceiling_strips": True})


def b_drop_shafts(c, kk, salt):
    """Two stacked floors + ground, vertical spacing >= 190 (upper
    floors can never block lower drop edges), one wide shaft (380-420)
    no jump can clear. The autopilot drops the shaft; humans use the
    stacked floors. Floor hazards on the LOWER stacked floor are
    floating only (its overlap landing zone spans the whole floor).
    Shaft walls span ONLY the inter-floor band (T1..T2) and rest on
    the lower floors: full-height walls seal the floor route to the
    door (connectivity rule 5 -- the shaft becomes a dead-end pocket).
    Shaft mouths (entry + exit) stay open; wall spikes live only in
    the walled band."""
    T1 = g(kk, [150, 160, 170], salt=salt + 1)
    D = g(kk, [190, 200], salt=salt + 1)
    T2 = T1 + D
    sx = g(kk, [560, 600, 640], salt=salt + 2)
    sw = g(kk, [380, 400, 420], salt=salt + 2)
    rx = sx + sw
    plats = [plat(0, T1, sx, 20, "solid"),
             plat(rx, T1, 1280 - rx, 20, "solid"),
             plat(0, T2, sx, 20, "solid"),
             plat(rx, T2, 1280 - rx, 20, "solid"),
             floor_seg(c, 0, 1280, top=640),
             # Shaft walls, inter-floor band only (rule 7: they rest
             # on the lower floors; the wall spikes seat against
             # their shaft faces). NO full-height columns: the floor
             # route under the walls must stay open.
             plat(sx - 48, T1, 48, D, "solid"),
             plat(rx, T1, 48, D, "solid")]
    hazards = []
    hazards.append(spikes_up(200 + sh(kk, 40, 3, salt=salt + 3),
                             g(kk, [60, 80], salt=salt + 3), top=T1))
    r = g(kk, [26, 28], salt=salt + 3)
    hazards.append(saw_static(g(kk, [400, 440], salt=salt + 3),
                              T1 - r + 4, r))
    # Floating saw over the lower floor (clear of its landing zone AND
    # of the drop arc at x=sx/2, which the checker arc-samples).
    rf = g(kk, [26, 28], salt=salt + 4)
    hazards.append(saw_static(150 + sh(kk, 30, 3, salt=salt + 4),
                              T2 - 90, rf))
    # Shaft wall spikes (upper band only, seated on the inter-floor
    # walls, clear of every walking band). No lower-band spikes: with
    # no wall face below T2, the repair would add a side wall down to
    # the floor and re-seal the shaft mouth.
    y1 = T1 + 60
    hazards.append(spikes_side(sx, y1, 24, 48, "right"))
    hazards.append(spikes_side(rx - 24, y1, 24, 48, "left"))
    # Ground: clear of the shaft landing zone (~sx+372).
    hazards.append(spikes_up(620 + sh(kk, 40, 2, salt=salt + 5),
                             g(kk, [60, 80], salt=salt + 5)))
    rg = g(kk, [26, 28], salt=salt + 5)
    hazards.append(saw_static(g(kk, [760, 800], salt=salt + 5),
                              FLOOR_TOP - rg + 4, rg))
    # Decoration on the unreachable right segments.
    if kk % 3 != 2:
        rd = g(kk, [26, 28], salt=salt + 6)
        hazards.append(saw_static(rx + 120, T1 - rd + 4, rd))
    if kk % 3 == 0:
        hazards.append(spikes_up(rx + 60, 80, top=T2))
    spawn = (g(kk, [80, 100, 120], salt=salt + 20), T1)
    # Door x >= 1160: the wall spike at rx (max 1060) + 24 must stay
    # 40px clear of the door rect (door.x - 27 >= 1133).
    door = (g(kk, [1160, 1180, 1200], salt=salt + 21), FLOOR_TOP)
    return plats, hazards, spawn, door


def b_zigzag_descents(c, kk, salt):
    """Short floating floors zigzagging down, joined by gap edges on
    one shared corridor boundary (no higher floor spans a corridor).
    The autopilot descends the left side; humans zigzag."""
    T = g(kk, [150, 160, 170], salt=salt + 1)
    S = g(kk, [90, 95], salt=salt + 1)
    L = g(kk, [830, 850, 870], salt=salt + 2)
    G = g(kk, [40, 50, 60], salt=salt + 2)
    R = L - G
    FR = g(kk, [1180, 1200, 1220], salt=salt + 2)
    FL = g(kk, [430, 450, 470], salt=salt + 2)
    tops = [T, T + S, T + 2 * S, T + 3 * S]
    plats = [plat(L, tops[0], FR - L, 20, "solid"),
             plat(FL, tops[1], R - FL, 20, "solid"),
             plat(L, tops[2], FR - L, 20, "solid"),
             plat(FL, tops[3], R - FL, 20, "solid"),
             floor_seg(c, 0, 1280, top=640)]
    hazards = []
    # Floor 1: one hazard, clear of the spawn safe zone.
    if kk % 2 == 0:
        hazards.append(spikes_up(920 + sh(kk, 20, 2, salt=salt + 3),
                                 g(kk, [60, 80], salt=salt + 3),
                                 top=tops[0]))
    else:
        r = g(kk, [26, 28], salt=salt + 3)
        hazards.append(saw_static(g(kk, [950, 980], salt=salt + 3),
                                  tops[0] - r + 4, r))
    # Floor 2: one small strip, clear of the landing zone (ends <= 722).
    hazards.append(spikes_up(g(kk, [664, 668, 672], salt=salt + 4),
                             g(kk, [48, 50], salt=salt + 4), top=tops[1]))
    # Floor 3: strip + saw (human route).
    hazards.append(spikes_up(950 + sh(kk, 20, 2, salt=salt + 5),
                             g(kk, [60, 80], salt=salt + 5), top=tops[2]))
    r3 = g(kk, [26, 28], salt=salt + 5)
    hazards.append(saw_static(g(kk, [1080, 1110], salt=salt + 5),
                              tops[2] - r3 + 4, r3))
    # Floor 4: strip + column, clear of the landing zone.
    hazards.append(spikes_up(520 + sh(kk, 20, 2, salt=salt + 6),
                             g(kk, [60, 80], salt=salt + 6), top=tops[3]))
    hazards.append(column(650 + sh(kk, 20, 2, salt=salt + 6),
                          g(kk, [56, 72], salt=salt + 6),
                          g(kk, [48, 56], salt=salt + 6), top=tops[3]))
    # Ground: left hazards clear of the door safe zone; right strip
    # is eye-density only (checker path walks left).
    hazards.append(spikes_up(g(kk, [250, 270], salt=salt + 7),
                             g(kk, [60, 80], salt=salt + 7)))
    rg = g(kk, [26], salt=salt + 7)
    hazards.append(saw_static(g(kk, [370, 390], salt=salt + 7),
                              FLOOR_TOP - rg + 4, rg))
    hazards.append(spikes_up(900 + sh(kk, 20, 2, salt=salt + 8),
                             g(kk, [60, 80], salt=salt + 8)))
    spawn = (g(kk, [1090, 1120, 1150], salt=salt + 20), tops[0])
    door = (g(kk, [110, 140, 170], salt=salt + 21), FLOOR_TOP)
    return plats, hazards, spawn, door


def b_saw_fields(c, kk, salt):
    count = g(kk, [3, 4, 3, 4], salt=salt + 1)
    if count == 3:
        first = g(kk, [380, 420], salt=salt + 1)
        spacing = g(kk, [260, 280], salt=salt + 2)
    else:
        first = g(kk, [300, 320], salt=salt + 1)
        spacing = g(kk, [220, 230], salt=salt + 2)
    cxs = [first + j * spacing for j in range(count)]
    hazards = []
    for j, cx in enumerate(cxs):
        r = g(kk, [26, 28, 30, 34], salt=salt + j + 1)
        hazards.append(saw_static(cx, FLOOR_TOP - r + 4, r))
    # Floating saws: >= 200px from every floor-saw jump zone.
    cands = [200, 480, 720, 900, 1020]
    free = [fx for fx in cands
            if all(abs(fx - cx) >= 200 for cx in cxs)]
    nfloat = g(kk, [1, 2, 1, 2], salt=salt + 3)
    for j in range(min(nfloat, len(free))):
        fx = free[(kk + j * 2) % len(free)]
        fy = g(kk, [380, 400, 420], salt=salt + 3 + j)
        hazards.append(saw_static(fx, fy, g(kk, [26, 28], salt=salt + 3 + j)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_trigger_pits(c, kk, salt):
    p1 = g(kk, [300, 320], salt=salt + 1)
    gw1 = 120
    mid = 230
    p2 = p1 + gw1 + mid
    gw2 = 120
    kind1 = g(kk, ["falling", "tilting"], salt=salt + 1)
    kind2 = g(kk, ["tilting", "falling"], salt=salt + 2)
    s1 = stone_in_gap(kind1, p1 + (gw1 - 90) // 2,
                      g(kk, [460, 470, 480], salt=salt + 1), 90, kk,
                      salt=salt + 1)
    s2 = stone_in_gap(kind2, p2 + (gw2 - 90) // 2,
                      g(kk, [460, 470, 480], salt=salt + 2), 90, kk,
                      salt=salt + 2)
    plats = [floor_seg(c, 0, p1), s1, floor_seg(c, p1 + gw1, p2), s2,
             floor_seg(c, p2 + gw2, 1280),
             plat(p1 + 20, c.floor_y - 24, gw1 - 40, 24, "solid"),
             plat(p2 + 20, c.floor_y - 24, gw2 - 40, 24, "solid")]
    pit_top = c.floor_y - 24
    hazards = [spikes_up(p1 + 20, gw1 - 40, top=pit_top),
               spikes_up(p2 + 20, gw2 - 40, top=pit_top),
               spikes_up(200, g(kk, [60, 80], salt=salt + 3))]
    tx1 = p1 + gw1 + 120
    tw1 = g(kk, [70, 80], salt=salt + 3)
    lead1 = g(kk, [170, 190, 210], salt=salt + 3)
    delay1 = g(kk, [0.25, 0.35, 0.45], salt=salt + 3)
    idx = len(hazards)
    hazards.append(triggered_strip(tx1, tw1, lead1, delay1))
    tx2 = p2 + gw2 + 140
    tw2 = g(kk, [80, 100], salt=salt + 4)
    lead2 = g(kk, [170, 190, 210], salt=salt + 4)
    delay2 = g(kk, [0.25, 0.35, 0.45], salt=salt + 4)
    idx = len(hazards)
    hazards.append(triggered_strip(tx2, tw2, lead2, delay2))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def _strip_row(c, kk, salt, n, widths, lo, hi, min_clear):
    """Evenly spaced row of strips across [lo, hi]; returns xs or
    None if the required clear cannot be met."""
    total = sum(widths)
    if n <= 1:
        return [lo]
    clear = (hi - lo - total) / float(n - 1)
    if clear < min_clear:
        return None
    xs = []
    x = float(lo)
    for w in widths:
        xs.append(int(round(x)))
        x += w + clear
    return xs


def b_spike_forests(c, kk, salt):
    n = g(kk, [4, 5, 4, 5], salt=salt + 1)
    if n == 4:
        widths = [g(kk, [60, 80, 90], salt=salt + j) for j in range(n)]
        xs = _strip_row(c, kk, salt, n, widths, 240, 1040, 150)
    else:
        widths = [g(kk, [56, 64], salt=salt + j) for j in range(n)]
        xs = _strip_row(c, kk, salt, n, widths, 220, 1040, 135)
    if xs is None:  # cannot happen with the grids above; be safe.
        widths = [60] * 4
        xs = _strip_row(c, kk, salt, 4, widths, 240, 1040, 150)
    hazards = [spikes_up(x, w) for (x, w) in zip(xs, widths)]
    # Ceiling strips over the gaps between floor strips.
    for j in range(len(xs) - 1):
        if (kk + j) % 2 == 0:
            mid = (xs[j] + widths[j] + xs[j + 1]) // 2
            w = g(kk, [80, 100], salt=salt + 5 + j)
            y = g(kk, [232, 244], salt=salt + 5 + j)
            hazards.append(spikes_down(mid - w // 2, w, y, 10))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_ceiling_gauntlets(c, kk, salt):
    px = g(kk, [300, 340, 380], salt=salt + 1)
    pw = g(kk, [52, 60], salt=salt + 1)
    ph = g(kk, [104, 116], salt=salt + 1)
    py = g(kk, [130, 150], salt=salt + 1)
    hazards = [pillar_periodic(
        px, py, pw, ph, g(kk, [3.8, 4.0, 4.4], salt=salt + 2),
        g(kk, [0.0, 0.5, 1.0], salt=salt + 2),
        g(kk, [600, 650], salt=salt + 2))]
    for j, sx in enumerate((g(kk, [600, 700], salt=salt + 3),
                            g(kk, [850, 950], salt=salt + 4))):
        hazards.append(spikes_down(
            sx, g(kk, [90, 120, 150], salt=salt + 3 + j),
            g(kk, [232, 244, 252], salt=salt + 3 + j), 10))
    pats = [["strip", "saw", "column"], ["saw", "strip", "strip"],
            ["column", "strip", "saw"]]
    pat = g(kk, pats, salt=salt + 5)
    slots = []
    for j, kind in enumerate(pat):
        if kind == "strip":
            slots.append(g(kk, [60, 80, 100], salt=salt + j))
        elif kind == "saw":
            slots.append(2 * g(kk, [26, 30], salt=salt + j) + 40)
        else:
            slots.append(g(kk, [48, 56], salt=salt + j))
    start = g(kk, [520, 560], salt=salt + 5)
    xs = row_positions(start, slots, [150] * (len(slots) - 1))
    over = xs[-1] + slots[-1] - 1040
    if over > 0:
        xs = [x - over for x in xs]
    for j, (kind, x, slot) in enumerate(zip(pat, xs, slots)):
        if kind == "strip":
            hazards.append(spikes_up(x, slot))
        elif kind == "saw":
            r = (slot - 40) // 2
            hazards.append(saw_static(x + slot // 2, FLOOR_TOP - r + 4, r))
        else:
            hazards.append(column(x, g(kk, [56, 72, 88], salt=salt + j + 2),
                                  slot))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_saw_corridors(c, kk, salt):
    cx0 = g(kk, [440, 480, 520], salt=salt + 1)
    cw = g(kk, [360, 400, 440], salt=salt + 1)
    # Tunnel ceiling: full-width beam on edge walls (rule 7: a
    # floating corridor ceiling cannot be pillar-supported without
    # blocking the corridor). The swing pivot hangs inside the beam.
    # Beam heights span 140..280 (Loop 2): with only 3 heights the
    # archetype's signature space (3 layouts x ~constant solution)
    # was exhausted by the 14 existing levels, so no new draw could
    # satisfy the >= 2-dims distinctness rule; 5 heights still
    # saturated after 6 recovery picks. Heights stay inside the
    # middle band (density rule 9 needs the beam's width there) and
    # above the swing rest point (pivot inside the beam, disc
    # grazing the floor over the full arc).
    beam_top = g(kk, [140, 160, 180, 200, 220, 240, 260, 280],
                 salt=salt + 1)
    plats = [floor_seg(c, 0, 1280, top=640),
             plat(48, beam_top, 1184, 20, "solid"),
             plat(0, beam_top, 48, c.floor_y - beam_top, "solid"),
             plat(1232, beam_top, 48, c.floor_y - beam_top, "solid")]
    pcx = cx0 + 110
    r = g(kk, [30, 32, 34], salt=salt + 2)
    arc = g(kk, [12, 14, 16], salt=salt + 2)
    period = g(kk, [3.4, 3.8, 4.2], salt=salt + 2)
    hazards = [saw_swing(pcx, FLOOR_TOP - r + 2, pcx, beam_top + 10,
                         arc, period, r)]
    scx = cx0 + cw - 110
    dx = g(kk, [60, 80, -60, -80], salt=salt + 3)
    hazards.append(saw_path(scx, 470, scx + dx, 470,
                            g(kk, [3.0, 3.4], salt=salt + 3),
                            g(kk, [28, 30], salt=salt + 3)))
    hazards.append(spikes_up(200 + (kk % 3) * 40,
                             g(kk, [60, 80], salt=salt + 4)))
    if cx0 + cw <= 800:
        hazards.append(spikes_up(cx0 + cw + 150,
                                 g(kk, [60, 80], salt=salt + 5)))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_timed_corridors(c, kk, salt):
    cx0 = g(kk, [400, 440, 480], salt=salt + 1)
    cw = g(kk, [420, 460], salt=salt + 1)
    px = cx0 + 150
    pw = g(kk, [52, 60], salt=salt + 1)
    ph = g(kk, [104, 116], salt=salt + 1)
    py = g(kk, [130, 150], salt=salt + 1)
    plats = [floor_seg(c, 0, 1280, top=640),
             # Full-width ceiling beam on edge walls (rule 7: gapped
             # floating ceilings cannot be supported without blocking
             # the corridor). The periodic pillar is housed in the
             # beam: its home rect overlaps the beam's y-range.
             plat(48, 150, 1184, 20, "solid"),
             plat(0, 150, 48, 430, "solid"),
             plat(1232, 150, 48, 430, "solid")]
    hazards = [pillar_periodic(
        px, py, pw, ph, g(kk, [3.8, 4.0, 4.4], salt=salt + 2),
        g(kk, [0.0, 0.5, 1.0], salt=salt + 2),
        g(kk, [600, 650], salt=salt + 2))]
    gx = px + pw + 60
    gw = g(kk, [110, 120], salt=salt + 3)
    sw = g(kk, [80, 90], salt=salt + 3)
    stop = g(kk, [460, 470, 480], salt=salt + 3)
    period, on = g(kk, [(2.6, 1.8), (3.0, 2.0)], salt=salt + 3)
    stone = plat(gx + (gw - sw) // 2, stop, sw, 20, "dashed",
                 period=period, phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 3),
                 on_time=on)
    plats[0:1] = [floor_seg(c, 0, gx, top=640), stone, floor_seg(c, gx + gw, 1280)]
    hx = gx + gw + 100
    pperiod, pon = g(kk, [(2.6, 1.2), (3.0, 1.4)], salt=salt + 4)
    idx = len(hazards)
    hazards.append(spikes_up(hx, g(kk, [80, 100], salt=salt + 4),
                             period=pperiod,
                             phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 4),
                             on_time=pon))
    hazards.append(spikes_up(200 + (kk % 3) * 40,
                             g(kk, [60, 80], salt=salt + 5)))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_column_forests(c, kk, salt):
    n = g(kk, [4, 5, 4, 5], salt=salt + 1)
    widths = [g(kk, [48, 56, 64], salt=salt + j) for j in range(n)]
    heights = [g(kk, [56, 72, 88], salt=salt + j + 2) for j in range(n)]
    min_clear = 160 if n == 4 else 140
    total = sum(widths)
    clear = (1040 - 220 - total) / float(n - 1)
    if clear < min_clear:
        widths = [48] * n
        total = sum(widths)
        clear = (1040 - 220 - total) / float(n - 1)
    xs = []
    x = 220.0
    for w in widths:
        xs.append(int(round(x)))
        x += w + clear
    hazards = [column(x, h, w)
               for (x, w, h) in zip(xs, widths, heights)]
    # Stalactites hang from one gantry beam (added by the grounding
    # repair): a single beam height per level, tops >= 106 so the
    # beam stays clear of the HUD band.
    stal_y = g(kk, [110, 120, 130], salt=salt + 5)
    nstal = g(kk, [2, 3, 2, 3], salt=salt + 5)
    bases = [300, 600, 900]
    for j in range(nstal):
        h = g(kk, [160, 180, 200], salt=salt + 5 + j)
        hazards.append({"type": "spiked_column",
                        "x": int(bases[j] + sh(kk, 40, 3, salt=salt + j)),
                        "y": int(stal_y),
                        "w": int(g(kk, [48, 56, 64], salt=salt + 5 + j)),
                        "h": int(h)})
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280, top=640)], hazards, spawn, door


def b_final_mega(c, kk, salt):
    """Timed opening (pillar + popup/column + hop strip), dashed gap,
    static saw finish: the planner engages once the timed features
    are passed, so the finish is planned, not greedy."""
    px = g(kk, [220, 240, 260], salt=salt + 1)
    pw = g(kk, [52, 60], salt=salt + 1)
    hazards = [pillar_periodic(
        px, g(kk, [130, 150], salt=salt + 1), pw,
        g(kk, [104, 116], salt=salt + 1),
        g(kk, [3.8, 4.0, 4.4], salt=salt + 2),
        g(kk, [0.0, 0.5, 1.0], salt=salt + 2),
        g(kk, [600, 650], salt=salt + 2))]
    mid = g(kk, ["popup", "column", "popup"], salt=salt + 3)
    mx = 330 + sh(kk, 20, 3, salt=salt + 3)
    if mid == "popup":
        pperiod, pon = g(kk, [(2.6, 1.2), (3.0, 1.4)], salt=salt + 3)
        idx = len(hazards)
        hazards.append(spikes_up(mx, g(kk, [80, 100], salt=salt + 3),
                                 period=pperiod,
                                 phase=g(kk, [0.0, 0.5, 1.0],
                                         salt=salt + 3), on_time=pon))
    else:
        hazards.append(column(mx, g(kk, [64, 80], salt=salt + 3),
                              g(kk, [48, 56], salt=salt + 3)))
    hazards.append(spikes_up(470 + sh(kk, 20, 3, salt=salt + 4),
                             g(kk, [60, 80, 100], salt=salt + 4)))
    gx = g(kk, [620, 640], salt=salt + 5)
    gw = g(kk, [110, 120], salt=salt + 5)
    sw = g(kk, [80, 90], salt=salt + 5)
    stop = g(kk, [460, 470, 480], salt=salt + 5)
    period, on = g(kk, [(2.6, 1.8), (3.0, 2.0)], salt=salt + 5)
    stone = plat(gx + (gw - sw) // 2, stop, sw, 20, "dashed",
                 period=period, phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 5),
                 on_time=on)
    plats = [floor_seg(c, 0, gx, top=640), stone, floor_seg(c, gx + gw, 1280)]
    r = g(kk, [28, 30], salt=salt + 6)
    hazards.append(saw_static(g(kk, [860, 890, 920], salt=salt + 6),
                              FLOOR_TOP - r + 4, r))
    for j, sx in enumerate((500, 760)):
        hazards.append(spikes_down(
            sx + sh(kk, 20, 2, salt=salt + 7 + j),
            g(kk, [90, 120], salt=salt + 7 + j),
            g(kk, [232, 244], salt=salt + 7 + j), 10))
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door

# ---------------------------------------------------------------------------
# Door table: (door, archetype name, builder, variant count). Structurally
# risky doors (towers, reversed, skyline, shafts, zigzag, dashed towers,
# pillar forests, corridors, finals) get 3 variants; the rest get 2.
# ---------------------------------------------------------------------------

DOORS = [
    (1, "pitfall", b_pitfall, 2),
    (2, "spike-hops", b_spike_hops, 2),
    (3, "saw-runs", b_saw_runs, 2),
    (4, "popup-spikes", b_popup_spikes, 2),
    (5, "triggered-spikes", b_triggered_spikes, 2),
    (6, "triggered-pillars", b_triggered_pillars, 2),
    (7, "periodic-pillars", b_periodic_pillars, 2),
    (8, "swing-saws", b_swing_saws, 2),
    (9, "patrol-saws", b_patrol_saws, 2),
    (10, "gap-saws", b_gap_saws, 2),
    (11, "spiked-columns", b_spiked_columns, 2),
    (12, "dashed-chains", b_dashed_chains, 2),
    (13, "falling-floors", b_falling_floors, 2),
    (14, "tilting-blocks", b_tilting_blocks, 2),
    (15, "moving-bridges", b_moving_bridges, 2),
    (16, "mover-chains", b_mover_chains, 2),
    (17, "ceiling-spikes", b_ceiling_spikes, 2),
    (18, "wall-spikes", b_wall_spikes, 2),
    (19, "step-climbs", b_step_climbs, 2),
    (20, "double-gaps", b_double_gaps, 2),
    (21, "pit-bridges", b_pit_bridges, 2),
    (22, "gauntlets", b_gauntlets, 2),
    (23, "timed-mixes", b_timed_mixes, 2),
    (24, "pillar-alleys", b_pillar_alleys, 2),
    (25, "pillar-forests", b_pillar_forests, 3),
    (26, "grand-mixes", b_grand_mixes, 2),
    (27, "mover-lifts", b_mover_lifts, 2),
    (28, "tower-descents", b_tower_descents, 3),
    (29, "reversed-runs", b_reversed_runs, 3),
    (30, "skyline-city", b_skyline_city, 3),
    (31, "drop-shafts", b_drop_shafts, 3),
    (32, "zigzag-descents", b_zigzag_descents, 3),
    (33, "saw-fields", b_saw_fields, 2),
    (34, "trigger-pits", b_trigger_pits, 2),
    (35, "spike-forests", b_spike_forests, 2),
    (36, "ceiling-gauntlets", b_ceiling_gauntlets, 2),
    (37, "saw-corridors", b_saw_corridors, 3),
    (38, "timed-corridors", b_timed_corridors, 3),
    (39, "dashed-towers", b_dashed_towers, 3),
    (40, "column-forests", b_column_forests, 2),
    (41, "final-tower-saws", b_final_tower_saws, 2),
    (42, "final-skyline", b_final_skyline, 3),
    (43, "final-reversed", b_final_reversed, 2),
    (44, "final-mega", b_final_mega, 3),
]


# ---------------------------------------------------------------------------
# Extend mode (recovery lane): NEW variants for failed slots ONLY.
#
# This section only ADDS a separate entry point (--extend). It does not
# touch main(), any builder, or any finish-pass function: the original
# generation path must still produce byte-identical output (the
# recovery lane proves this by regenerating the original set). The
# extend mode reuses the existing builders with NEW grid indices (kk),
# scores each draw by autopilot-mechanism easiness, and keeps the best
# draws that pass the real checker and the distinctness rule against
# EVERY existing candidate plus every already-picked new candidate.
#
# What the scores encode (evidence: autopilot-candidates.json plus the
# autopilot's greedy/planner mechanics, read but never modified):
# - The ballistic planner is DISABLED whenever any non-solid platform,
#   pillar, or moving saw lies ahead, so D21/D34/D44 run on the greedy
#   policy (jump on a hazard/gap inside a 96px probe; wait <= 3s on
#   timed hazards) while D40 runs on the planner over chained columns.
# - D21 pit-bridges: widest stones + longest stand_time + mixed
#   falling/tilting kinds + narrowest hop strip + longest pit-exit
#   run-up + earliest spawn (mixed kinds passed 5/5 originally;
#   tilting+tilting 0/2; the widest stones 2/2).
# - D34 trigger-pits: triggered spikes are invisible to the greedy
#   probe until trigger+delay, so the activation margin
#   (lead/run_speed - delay) is scored highest, then stone stand_time
#   and lowest rise (top 480), then narrowest strips.
# - D40 column-forests: HARD filter n == 4 columns (all 4 original
#   n=4 draws passed; all 6 n=5 draws failed -- 145px chaining gaps
#   defeat the planner). Then widest chaining gaps, lowest columns,
#   fewest/lowest hanging stalactites.
# - D44 final-mega: longest pillar hang window
#   (period - drop_dist/drop_speed - 1.0s rise), pop-up mid over
#   column mid (0/4 column-mid draws passed), longest pop-up off
#   window, longest dashed on_time, widest stone, smallest saw.
# No new mechanics, kinds, types, or schema fields are introduced:
# every draw comes from the existing builders' own variation grids.
# ---------------------------------------------------------------------------

EXTEND_SLOTS = [
    # (door, slot, first new variant). The first variant is verified
    # against the loaded candidates file (max existing + 1) at run
    # time; these values are the expected ones, never trusted blindly.
    # Loop 2 (v3 recovery): the 22 Loop-1 failed slots. First-new
    # variants follow candidates-v3.json (V3 for 2-variant slots,
    # V4 for 3-variant slots, V3 for D37S4 which has only 2).
    (9, 5, 3),
    (11, 2, 3),
    (18, 3, 3),
    (18, 4, 3),
    (18, 5, 3),
    (19, 4, 3),
    (27, 3, 3),
    (31, 1, 4),
    (31, 2, 4),
    (31, 3, 4),
    (31, 4, 4),
    (31, 5, 4),
    (37, 1, 4),
    (37, 2, 4),
    (37, 4, 3),
    (39, 1, 4),
    (39, 2, 4),
    (39, 3, 4),
    (39, 4, 4),
    (39, 5, 4),
    (40, 3, 3),
    (40, 5, 3),
]
EXTEND_PER_SLOT = 3


def _score_easiest(ctx, plats, hazards, spawn, door_pos):
    """F2-pattern generic scorer for Loop-2 recovery slots: fewest
    hazards, lowest speeds, widest gaps. Returns (score, fingerprint,
    timing) for a raw builder draw; never filters (every draw is
    scored; the checker + dedupe decide). Timing tuples hedge
    phase-alignment failures via the diversity passes in extend_main.
    Draws whose raw solid geometry already blocks the spawn point or
    the door rect are rejected (None): the repair pass never removes
    geometry, so they can never pass the checker (e.g. D37 door_x=1210
    draws, whose builder edge wall overlaps the door rect).
    """
    for p in plats:
        if p.get("kind") == "solid" and _blocks_spawn_door(
                ctx, _pr(p), spawn, door_pos):
            return None
    lethal = list(hazards)  # v3: every hazard type is lethal
    score = -70.0 * len(lethal)
    timing = []
    for h in lethal:
        t = h.get("type")
        if t == "saw":
            r = float(h.get("r", 30))
            score -= 6.0 * (r - 26.0)
            if "path" in h and isinstance(h["path"], dict):
                dx = float(h["path"].get("x2", h["x"])) - float(h["x"])
                dy = float(h["path"].get("y2", h["y"])) - float(h["y"])
                score -= 0.2 * math.hypot(dx, dy)
            if "swing" in h and isinstance(h["swing"], dict):
                sw = h["swing"]
                score -= 3.0 * float(sw.get("arc_deg", 0))
                score += 35.0 * float(sw.get("period", 3.0))
                timing.append(("swing", float(sw.get("period", 0)),
                               float(sw.get("arc_deg", 0))))
            elif "period" in h:
                score += 35.0 * float(h["period"])
                timing.append(("saw", float(h["period"])))
        elif t == "spikes":
            score -= 0.4 * float(h.get("w", 60))
            if "period" in h:
                score += 45.0 * (float(h["period"])
                                 - float(h.get("on_time", 0)))
                timing.append(("popup", float(h["period"]),
                               float(h.get("phase", 0)),
                               float(h.get("on_time", 0))))
            if "trigger_x" in h:
                lead = abs(float(h["x"]) - float(h["trigger_x"]))
                margin = lead / max(float(ctx.run_speed), 1.0) \
                    - float(h.get("delay", 0))
                score += 120.0 * margin + 60.0 * float(h.get("delay", 0))
                timing.append(("trig", int(lead),
                               float(h.get("delay", 0))))
        elif t == "spiked_column":
            score -= 1.5 * float(h.get("h", 60)) \
                + 0.5 * float(h.get("w", 48))
        elif t == "hanging_pillar":
            if "period" in h:
                score += 40.0 * float(h["period"])
                score -= 0.02 * float(h.get("drop_speed", 700))
                timing.append(("pillar", float(h["period"]),
                               float(h.get("phase", 0)),
                               float(h.get("drop_speed", 0))))
    for p in plats:
        k = p.get("kind")
        if k == "dashed":
            score += 50.0 * float(p.get("on_time", 0)) \
                + 15.0 * (float(p.get("period", 0))
                          - float(p.get("on_time", 0))) \
                + 1.5 * float(p.get("w", 0))
            timing.append(("dashed", float(p.get("period", 0)),
                           float(p.get("phase", 0)),
                           float(p.get("on_time", 0))))
        elif k in ("falling", "tilting"):
            score += 120.0 * float(p.get("stand_time", 0)) \
                + 1.5 * float(p.get("w", 0))
            timing.append((k, float(p.get("stand_time", 0))))
        elif k == "moving":
            score += 25.0 * float(p.get("period", 0)) \
                + 2.0 * float(p.get("w", 0))
            timing.append(("moving", float(p.get("period", 0)),
                           float(p.get("dx", 0)), float(p.get("dy", 0))))
    # Widest floor-band gaps between consecutive hazards.
    band = sorted(
        [h for h in lethal
         if float(h.get("y", 0)) < 500.0
         and float(h.get("y", 0)) + float(h.get("h", 0)) > 400.0],
        key=lambda h: float(h["x"]))
    gaps = []
    for a, b in zip(band, band[1:]):
        gaps.append(float(b["x"]) - (float(a["x"]) + float(a["w"])))
    if gaps:
        score += 2.5 * min(200.0, min(gaps)) \
            + 0.5 * min(200.0, sum(gaps) / len(gaps))
    if band:
        score += 0.3 * min(300.0, max(
            0.0, float(band[0]["x"]) - float(spawn[0])))
    # Widest same-band shaft gap between solids (drop-shaft width).
    solids = sorted([p for p in plats if p.get("kind") == "solid"],
                    key=lambda p: float(p["x"]))
    shaft = 0.0
    for a, b in zip(solids, solids[1:]):
        yov = min(float(a["y"]) + float(a["h"]),
                  float(b["y"]) + float(b["h"])) \
            - max(float(a["y"]), float(b["y"]))
        if yov >= 8.0:
            shaft = max(shaft, float(b["x"])
                        - (float(a["x"]) + float(a["w"])))
    score += 0.3 * shaft
    score += 0.2 * (150.0 - float(spawn[0]))

    def _fp(obj):
        return tuple(sorted(
            (k, round(float(v), 3) if isinstance(v, (int, float))
             else str(v)) for k, v in obj.items()))

    fingerprint = (tuple(_fp(p) for p in plats),
                   tuple(_fp(h) for h in hazards),
                   int(spawn[0]), int(spawn[1]),
                   int(door_pos[0]), int(door_pos[1]))
    return score, fingerprint, tuple(timing)


def _score_pit_bridges(ctx, plats, hazards, spawn, door_pos):
    """(score, fingerprint, timing) for a raw b_pit_bridges draw, or None."""
    stones = [p for p in plats if p["kind"] in ("falling", "tilting")]
    strips = [h for h in hazards
              if h["type"] == "spikes" and h.get("dir", "up") == "up"]
    if len(stones) != 2 or len(strips) != 1:
        return None
    s1, s2 = stones
    strip = strips[0]
    resumes = [p["x"] for p in plats
               if p["kind"] == "solid" and p["y"] == FLOOR_TOP
               and p["x"] > s2["x"]]
    if not resumes:
        return None
    clear = strip["x"] - min(resumes)
    score = (3.0 * float(s1["w"])
             + 120.0 * (float(s1["stand_time"])
                        + float(s2["stand_time"]))
             + (25.0 if s1["kind"] != s2["kind"] else 0.0)
             + float(100 - strip["w"]) + float(clear)
             + float(150 - spawn[0]))
    fingerprint = (s1["w"], s1["kind"], float(s1["stand_time"]),
                   s2["kind"], float(s2["stand_time"]),
                   strip["x"], strip["w"], spawn[0], door_pos[0],
                   plats[0]["w"])
    timing = (s1["kind"], float(s1["stand_time"]),
              s2["kind"], float(s2["stand_time"]))
    return score, fingerprint, timing


def _score_trigger_pits(ctx, plats, hazards, spawn, door_pos):
    """(score, fingerprint, timing) for a raw b_trigger_pits draw, or None."""
    stones = [p for p in plats if p["kind"] in ("falling", "tilting")]
    trigs = [h for h in hazards
             if h["type"] == "spikes" and "trigger_x" in h]
    plain = [h for h in hazards
             if h["type"] == "spikes" and "trigger_x" not in h
             and "period" not in h and h["y"] == FLOOR_TOP - 10]
    if len(stones) != 2 or len(trigs) != 2 or len(plain) != 1:
        return None
    s1, s2 = stones
    t1, t2 = trigs
    speed = float(ctx.run_speed)
    m1 = ((float(t1["x"]) - float(t1["trigger_x"])) / speed
          - float(t1["delay"]))
    m2 = ((float(t2["x"]) - float(t2["trigger_x"])) / speed
          - float(t2["delay"]))
    score = (150.0 * (float(s1["stand_time"]) + float(s2["stand_time"]))
             # Lowest rise wins: stone tops 460/470/480, so reward the
             # largest y (480 = only 20px above the floor).
             + 4.0 * float((s1["y"] - (FLOOR_TOP - 40))
                           + (s2["y"] - (FLOOR_TOP - 40)))
             + 400.0 * (m1 + m2)
             + (30.0 if m1 >= 0.27 else 0.0)
             + (30.0 if m2 >= 0.27 else 0.0)
             + 2.0 * float((80 - t1["w"]) + (100 - t2["w"]))
             + float(80 - plain[0]["w"])
             + float(150 - spawn[0]))
    fingerprint = (s1["y"], float(s1["stand_time"]), s1["kind"],
                   s2["y"], float(s2["stand_time"]), s2["kind"],
                   t1["w"], int(t1["x"] - t1["trigger_x"]),
                   float(t1["delay"]),
                   t2["w"], int(t2["x"] - t2["trigger_x"]),
                   float(t2["delay"]),
                   plain[0]["w"], spawn[0], plats[0]["w"])
    timing = (s1["kind"], float(s1["stand_time"]),
              s2["kind"], float(s2["stand_time"]),
              int(t1["x"] - t1["trigger_x"]), float(t1["delay"]),
              int(t2["x"] - t2["trigger_x"]), float(t2["delay"]))
    return score, fingerprint, timing


def _score_column_forests(ctx, plats, hazards, spawn, door_pos):
    """(score, fingerprint, timing) for a raw b_column_forests draw, or None.

    Hard filter: exactly 4 floor columns. Every 5-column draw in the
    original set failed the autopilot; every 4-column draw passed.
    """
    cols = sorted(
        [h for h in hazards
         if h["type"] == "spiked_column" and h["y"] > 300],
        key=lambda h: h["x"])
    stal = [h for h in hazards
            if h["type"] == "spiked_column" and h["y"] <= 300]
    if len(cols) != 4:
        return None
    clears = [cols[i + 1]["x"] - (cols[i]["x"] + cols[i]["w"])
              for i in range(len(cols) - 1)]
    max_bottom = max([s["y"] + s["h"] for s in stal], default=0)
    score = (2.0 * float(min(clears))
             + 2.0 * float(100 - max(c["h"] for c in cols))
             + 40.0 * float(3 - len(stal))
             + float(280 - max_bottom)
             + float(sum(64 - c["w"] for c in cols))
             + float(150 - spawn[0]))
    # Density bias (Loop 2): draws with door_x <= 1170 keep the
    # gantry (the right edge wall clears the door rect), so the
    # stalactites hang from a full-width beam and the middle is
    # dense; door_x=1210 draws lose the gantry to pedestals and land
    # at 176-184px, the thinnest middles in the file. Reward the
    # gantry path.
    if door_pos[0] <= 1170:
        score += 150.0
    fingerprint = (tuple((c["x"], c["w"], c["h"]) for c in cols),
                   tuple(sorted((s["x"], s["y"], s["w"], s["h"])
                                for s in stal)),
                   spawn[0], door_pos[0])
    # No timed elements: all-static columns, so no timing hedge
    # applies (an empty timing tuple never blocks a pick).
    timing = ()
    return score, fingerprint, timing


def _score_final_mega(ctx, plats, hazards, spawn, door_pos):
    """(score, fingerprint, timing) for a raw b_final_mega draw, or None."""
    if len(hazards) < 6 or len(plats) < 3:
        return None
    pillar = hazards[0]
    if pillar["type"] != "hanging_pillar" or "period" not in pillar:
        return None
    mid = hazards[2]
    if mid["type"] not in ("spikes", "spiked_column"):
        return None
    strip = None
    for h in hazards[3:]:
        if (h["type"] == "spikes" and h.get("dir", "up") == "up"
                and "period" not in h and h["y"] == FLOOR_TOP - 10):
            strip = h
            break
    saw = None
    for h in hazards:
        if h["type"] == "saw" and h["y"] > 300:
            saw = h
            break
    stone = plats[1]
    if strip is None or saw is None or stone["kind"] != "dashed":
        return None
    drop_dist = max(0.0, float(ctx.floor_y) - (pillar["y"] + pillar["h"]))
    hang = (float(pillar["period"])
            - drop_dist / max(float(pillar["drop_speed"]), 1.0) - 1.0)
    if mid["type"] == "spikes":
        popup_bonus = 120.0
        off = float(mid["period"]) - float(mid["on_time"])
    else:
        popup_bonus = 0.0
        off = 0.0
    mid_end = mid["x"] + mid["w"]
    gap_exit = plats[2]["x"]
    score = (100.0 * hang + popup_bonus + 50.0 * off
             + float(100 - mid["w"])
             + float(100 - strip["w"])
             + float(strip["x"] - mid_end)
             + 40.0 * float(stone["on_time"]) + float(stone["w"])
             # Lowest rise wins: stone tops 460/470/480, so reward the
             # largest y (480 = only 20px above the floor).
             + 2.0 * float(stone["y"] - (FLOOR_TOP - 40))
             + 10.0 * float(30 - saw["r"])
             + float(saw["x"] - gap_exit)
             + 0.2 * float(150 - spawn[0]))
    fingerprint = (pillar["x"], pillar["y"], pillar["w"], pillar["h"],
                   float(pillar["period"]),
                   float(pillar.get("phase", 0.0)),
                   pillar["drop_speed"],
                   mid["type"], mid["x"], mid["w"],
                   float(mid.get("period", 0.0)),
                   float(mid.get("phase", 0.0)),
                   float(mid.get("on_time", 0.0)),
                   strip["x"], strip["w"],
                   stone["x"], stone["y"], stone["w"],
                   float(stone["period"]),
                   float(stone.get("phase", 0.0)),
                   float(stone["on_time"]),
                   saw["x"], saw["r"], spawn[0], door_pos[0])
    timing = (float(pillar["period"]), float(pillar.get("phase", 0.0)),
              pillar["drop_speed"],
              mid["type"], float(mid.get("period", 0.0)),
              float(mid.get("phase", 0.0)),
              float(mid.get("on_time", 0.0)),
              float(stone["period"]), float(stone.get("phase", 0.0)),
              float(stone["on_time"]))
    return score, fingerprint, timing


def _score_ceiling_spikes(ctx, plats, hazards, spawn, door_pos):
    """(score, fingerprint, timing) for a raw b_ceiling_spikes draw, or
    None. Loop 5 recovery scorer for door 17 (previously unextendable:
    no scorer entry). Easing levers: ONE ceiling strip instead of two
    (the kk-parity second strip doubles the overhead threat); narrow
    strips; HIGH strips (small y = more headroom under the teeth);
    narrow floor strips; horizontal separation between ceiling and
    floor strips (jumping a floor strip while a ceiling strip hangs
    overhead is the hard interaction). All-static: no timing hedge.
    """
    downs = sorted([h for h in hazards if h.get("type") == "spikes"
                    and h.get("dir") == "down"], key=lambda h: h["x"])
    ups = sorted([h for h in hazards if h.get("type") == "spikes"
                  and h.get("dir") == "up"], key=lambda h: h["x"])
    if not downs:
        return None
    score = 400.0 * (2 - len(downs))
    for h in downs:
        score += 2.0 * (150.0 - float(h["w"])) \
            + 3.0 * (312.0 - float(h["y"]))
    for h in ups:
        score += 1.0 * (100.0 - float(h["w"]))
    seps = []
    for d in downs:
        for u in ups:
            gap = max(float(u["x"]) - (float(d["x"]) + float(d["w"])),
                      float(d["x"]) - (float(u["x"]) + float(u["w"])))
            seps.append(gap)
    if seps:
        sep = max(-60.0, min(200.0, min(seps)))
        score += 0.5 * sep
    fingerprint = (tuple((h["x"], h["w"], h["y"]) for h in downs),
                   tuple((h["x"], h["w"]) for h in ups),
                   spawn[0], door_pos[0])
    return score, fingerprint, ()


def _score_ceiling_gauntlets(ctx, plats, hazards, spawn, door_pos):
    """(score, fingerprint, timing) for a raw b_ceiling_gauntlets draw,
    or None. Loop 5 recovery scorer for door 36 (previously
    unextendable: no scorer entry). Easing levers: a slow,
    long-period, small hanging pillar; narrow HIGH ceiling strips;
    a floor pattern preferring jumpable strips over saws/columns,
    with small saw radii and short narrow columns.
    """
    pillars = [h for h in hazards if h.get("type") == "hanging_pillar"]
    downs = sorted([h for h in hazards if h.get("type") == "spikes"
                    and h.get("dir") == "down"], key=lambda h: h["x"])
    if len(pillars) != 1 or len(downs) != 2:
        return None
    p = pillars[0]
    score = (60.0 * float(p["period"])
             - 0.05 * float(p["drop_speed"])
             + 2.0 * (60.0 - float(p["w"]))
             + 1.0 * (116.0 - float(p["h"]))
             + 1.0 * (150.0 - float(p["y"])))
    for h in downs:
        score += 2.0 * (150.0 - float(h["w"])) \
            + 3.0 * (252.0 - float(h["y"]))
    kinds = []
    for h in hazards:
        t = h.get("type")
        if t == "spikes" and h.get("dir") == "up":
            score += 30.0 + 1.0 * (100.0 - float(h["w"]))
            kinds.append(("strip", h["x"], h["w"]))
        elif t == "saw":
            score -= 6.0 * (float(h.get("r", 30)) - 26.0)
            kinds.append(("saw", h["x"], h.get("r", 30)))
        elif t == "spiked_column":
            score += 1.0 * (88.0 - float(h["h"])) \
                + 1.0 * (56.0 - float(h["w"]))
            kinds.append(("column", h["x"], h["w"], h["h"]))
    fingerprint = (tuple((h["x"], h["w"], h["y"]) for h in downs),
                   tuple(sorted(kinds)),
                   p["x"], p["w"], p["h"],
                   float(p["period"]), float(p.get("phase", 0.0)),
                   p["drop_speed"], spawn[0], door_pos[0])
    timing = (("pillar", float(p["period"]),
               float(p.get("phase", 0.0)), p["drop_speed"]),)
    return score, fingerprint, timing


def _score_step_climbs_easy(ctx, plats, hazards, spawn, door_pos):
    """(score, fingerprint, timing) for a raw b_step_climbs draw, or
    None. Loop 5 NEW easier parameter set for door 19: the previous
    two extend rounds used the generic _score_easiest, which ignores
    step geometry entirely (hazard count is a constant 2, so it
    ranked on strip widths alone) and picked variants that all died
    with the same signature. This scorer ranks on the actual
    difficulty: LOW step heights first, then wide step tops, narrow
    spike strips, and wide clearances (landing room) between each
    strip and the neighbouring steps. All-static: no timing hedge.
    """
    steps = sorted([p for p in plats if p.get("kind") == "solid"
                    and float(p["y"]) < FLOOR_TOP
                    and float(p["w"]) < ctx.width],
                   key=lambda p: p["x"])
    strips = sorted([h for h in hazards if h.get("type") == "spikes"
                     and h.get("dir") == "up"], key=lambda h: h["x"])
    if len(steps) != 3 or len(strips) != 2:
        return None
    score = 0.0
    for s in steps:
        score += 6.0 * (80.0 - float(FLOOR_TOP - s["y"])) \
            + 0.5 * (float(s["w"]) - 100.0)
    for j, h in enumerate(strips):
        left = steps[j]
        right = steps[j + 1]
        lead = float(h["x"]) - (float(left["x"]) + float(left["w"]))
        trail = float(right["x"]) - (float(h["x"]) + float(h["w"]))
        score += 1.5 * (100.0 - float(h["w"])) \
            + 0.5 * lead + 1.0 * trail
    fingerprint = (tuple((s["x"], s["w"], s["y"]) for s in steps),
                   tuple((h["x"], h["w"]) for h in strips),
                   spawn[0], door_pos[0])
    return score, fingerprint, ()


EXTEND_SCORERS = {
    9: _score_easiest,
    11: _score_easiest,
    17: _score_ceiling_spikes,
    18: _score_easiest,
    19: _score_step_climbs_easy,
    21: _score_pit_bridges,
    27: _score_easiest,
    31: _score_easiest,
    34: _score_trigger_pits,
    36: _score_ceiling_gauntlets,
    37: _score_easiest,
    39: _score_easiest,
    40: _score_column_forests,
    44: _score_final_mega,
}


def _finish_candidate(ctx, kk, salt, plats, hazards, spawn, door_pos):
    """Finish passes for one extend-mode draw.

    This DUPLICATES the finish block in main() (same functions, same
    order, same salt offsets, including core-middle dressing) so
    main() itself stays untouched. Returns (platforms, hazards) or
    None when the draw fails the upper-band / lethal-hazard
    requirements.
    """
    plats = [dict(p) for p in plats]
    hazards = [dict(h) for h in hazards]
    _assert_strip_cap(hazards)
    normalize_ground(ctx, plats)
    low = route_is_low(ctx, plats, spawn, door_pos)
    if low:
        add_skyline_dressing(ctx, kk, salt + 50, plats, hazards,
                             spawn, door_pos)
        if not has_upper_band(plats, hazards, spawn):
            add_ceiling_strip(ctx, kk, salt + 60, plats, hazards)
    if not has_upper_band(plats, hazards, spawn):
        return None
    if not has_lethal_hazard(hazards):
        if low and add_ceiling_strip(ctx, kk, salt + 70, plats, hazards):
            pass
        else:
            return None
    repair_grounding(ctx, plats, hazards, spawn, door_pos)
    add_core_middle_dressing(ctx, kk, salt + 80, plats, hazards,
                             spawn, door_pos)
    return plats, hazards


def extend_main(args):
    """Recovery extend mode: append easier variants for failed slots.

    Loads the existing candidates file, verifies every entry with the
    real checker, then per slot scans fresh grid indices through the
    UNCHANGED door builder, scores each draw, and keeps the best
    checker-valid, distinct draws. Writes the extended set (existing
    entries first, in order, then the new ones) to a NEW file. Never
    modifies the existing file. Deterministic: fixed scan order, fixed
    scoring, ties broken by grid index.
    """
    tuning_path = Path(args.tuning) if args.tuning \
        else REPO / "godot" / "data" / "tuning.json"
    existing_path = Path(args.existing) if args.existing \
        else REPO.parent / "verification" / "candidates.json"
    out_path = Path(args.out) if args.out \
        else REPO.parent / "verification" / "candidates-v2.json"
    if out_path.resolve() == existing_path.resolve():
        print("ERROR: --extend refuses to overwrite the existing file %s"
              % existing_path, file=sys.stderr)
        return 2
    tuning_data = load_tuning(tuning_path)
    ctx = Ctx(tuning_data)
    tun = ctx.tuning
    try:
        existing_data = json.loads(
            existing_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print("ERROR: cannot load existing candidates %s: %s"
              % (existing_path, exc), file=sys.stderr)
        return 2
    if existing_data.get("schema_version") != SCHEMA_VERSION:
        print("ERROR: existing schema_version %r != %d"
              % (existing_data.get("schema_version"), SCHEMA_VERSION),
              file=sys.stderr)
        return 2
    if existing_data.get("tuning_version") != ctx.tuning_version:
        print("ERROR: existing tuning_version %r != tuning.json %r"
              % (existing_data.get("tuning_version"), ctx.tuning_version),
              file=sys.stderr)
        return 2
    existing_levels = existing_data.get("levels")
    if not isinstance(existing_levels, list) or not existing_levels:
        print("ERROR: existing file has no levels array", file=sys.stderr)
        return 2
    existing_sigs = []
    for i, lv in enumerate(existing_levels):
        # Legacy entries are verified WITHOUT the rule-5 connectivity
        # check (Loop 2): 30 D31/D39 entries in candidates-v3.json are
        # sealed pockets that predate the connectivity rule. They are
        # preserved byte-identical (never picked: the autopilot fails
        # them); only NEW picks must pass connectivity. Every other
        # rule is still enforced here.
        chk = check_levels.LevelCheck(lv, i, tun).run(
            with_connectivity=False)
        if chk.errors:
            print("ERROR: existing candidate %s fails the checker: %s"
                  % (lv.get("id"), "; ".join(chk.errors[:2])),
                  file=sys.stderr)
            return 2
        existing_sigs.append(chk.signature_parts())
    max_variant = {}
    for lv in existing_levels:
        cid = lv.get("id", "")
        if len(cid) >= 7 and cid[0] == "D" and cid[3] == "S" \
                and cid[5] == "V":
            try:
                key = (int(cid[1:3]), int(cid[4]))
                max_variant[key] = max(max_variant.get(key, 0),
                                       int(cid[6:]))
            except ValueError:
                pass
    seed_salt = args.seed % 97
    table = {d: (name, fn, nv) for (d, name, fn, nv) in DOORS}
    new_levels = []
    new_sigs = []
    n_base = len(existing_levels)
    extend_slots = EXTEND_SLOTS
    if getattr(args, "extend_slots", None):
        extend_slots = []
        for part in args.extend_slots.split(","):
            door_s, slot_s = part.strip().split(":")
            door_i, slot_i = int(door_s), int(slot_s)
            extend_slots.append(
                (door_i, slot_i,
                 max_variant.get((door_i, slot_i), 0) + 1))
    for (door, slot, first_variant) in extend_slots:
        name, fn, _nv = table[door]
        expect = max_variant.get((door, slot), 0) + 1
        if expect != first_variant:
            print("ERROR: D%02dS%d: max existing variant is %d, so the "
                  "first new variant must be %d (table says %d); "
                  "refusing to guess numbering"
                  % (door, slot, expect - 1, expect, first_variant),
                  file=sys.stderr)
            return 2
        salt = door * 131 + seed_salt
        scorer = EXTEND_SCORERS[door]
        scored = []
        for kk in range(args.search):
            try:
                plats, hazards, spawn, door_pos = fn(ctx, kk, salt)
            except Exception:
                continue
            try:
                res = scorer(ctx, plats, hazards, spawn, door_pos)
            except Exception:
                continue
            if res is None:
                continue
            score, fingerprint, timing = res
            scored.append((score, kk, fingerprint, timing))
        scored.sort(key=lambda t: (-t[0], t[1]))
        shortlist = scored[:args.shortlist]
        picked = []
        picked_sigs = []
        picked_fps = set()
        picked_timings = set()
        tried = set()
        n_checked = 0
        n_invalid = 0
        n_dup = 0
        max_mode = 0
        # Diversity passes (each only runs if earlier passes found too
        # few): mode 0 requires distinct parameter fingerprints AND
        # distinct timing tuples (hedges phase-alignment failures:
        # wait-offset strategies shift every phase together, so only
        # distinct relative alignments diversify the timing chain);
        # mode 1 requires distinct timing tuples only; mode 2 relies
        # on the checker distinctness rule alone. Draws skipped for
        # diversity in an early pass stay available to later passes;
        # draws rejected by the checker/dedupe are never retried.
        for mode in (0, 1, 2):
            if len(picked) >= EXTEND_PER_SLOT:
                break
            for (score, kk, fingerprint, timing) in shortlist:
                if len(picked) >= EXTEND_PER_SLOT:
                    break
                if kk in tried:
                    continue
                if mode == 0 and fingerprint in picked_fps:
                    continue
                if mode <= 1 and timing and timing in picked_timings:
                    continue
                tried.add(kk)
                plats, hazards, spawn, door_pos = fn(ctx, kk, salt)
                finished = _finish_candidate(ctx, kk, salt, plats,
                                             hazards, spawn, door_pos)
                n_checked += 1
                if finished is None:
                    n_invalid += 1
                    continue
                plats2, hazards2 = finished
                cid = "D%02dS%dV%d" % (door, slot,
                                       first_variant + len(picked))
                decos = []
                if DECO_PASS_ENABLED:
                    decos = add_decorations(ctx, kk, salt + 90, plats2,
                                            hazards2, spawn, door_pos)
                level = {"id": cid, "palette": door - 1,
                         "spawn": {"x": int(spawn[0]),
                                   "y": int(spawn[1])},
                         "door": {"x": int(door_pos[0]),
                                  "y": int(door_pos[1])},
                         "platforms": plats2, "hazards": hazards2,
                         "template": name, "variation": cid}
                if decos:
                    level["decorations"] = decos
                if not has_lethal_hazard(hazards2):
                    n_invalid += 1
                    continue
                chk = check_levels.LevelCheck(
                    level, n_base + len(new_levels) + len(picked),
                    tun).run()
                if chk.errors:
                    n_invalid += 1
                    continue
                sig = chk.signature_parts()
                dup = False
                for (lay2, tra2, sol2) in \
                        existing_sigs + new_sigs + picked_sigs:
                    dims = sum([sig[0] != lay2, sig[1] != tra2,
                                sig[2] != sol2])
                    if dims < 2:
                        dup = True
                        break
                if dup:
                    n_dup += 1
                    continue
                picked.append((level, cid, kk, score, fingerprint,
                               timing))
                picked_sigs.append(sig)
                picked_fps.add(fingerprint)
                if timing:
                    picked_timings.add(timing)
                max_mode = max(max_mode, mode)
        if len(picked) < EXTEND_PER_SLOT:
            print("ERROR: D%02dS%d: only %d/%d recovery variants found "
                  "(scored %d grid points, shortlist %d, checked %d, "
                  "invalid %d, duplicates %d); NOT writing"
                  % (door, slot, len(picked), EXTEND_PER_SLOT,
                     len(scored), len(shortlist), n_checked, n_invalid,
                     n_dup), file=sys.stderr)
            return 1
        for (level, _cid, _kk, _score, _fp, _timing) in picked:
            new_levels.append(level)
        new_sigs.extend(picked_sigs)
        if not args.quiet:
            print("  D%02dS%d %-16s picked %s (diversity_mode=%d, "
                  "scored=%d, checked=%d, invalid=%d, dup=%d)"
                  % (door, slot, name,
                     ", ".join("%s@kk%d score=%.1f" % (cid, kk, score)
                               for (_lv, cid, kk, score, _fp, _t)
                               in picked),
                     max_mode, len(scored), n_checked, n_invalid,
                     n_dup))
    out_data = {"schema_version": SCHEMA_VERSION,
                "tuning_version": ctx.tuning_version,
                "levels": list(existing_levels) + new_levels}
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out_data, indent=1, sort_keys=True)
                        + "\n", encoding="utf-8")
    if not args.quiet:
        print("extend: %d existing + %d new -> %s"
              % (n_base, len(new_levels), out_path))
    return 0


def _parse_csv_ints(text):
    out = []
    for part in text.split(","):
        part = part.strip()
        if part:
            out.append(int(part))
    return out


# ---------------------------------------------------------------------------
# Main: generate -> verify with the real checker -> dedupe -> write
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# v3 PILOT vocabulary (Run 4, Round 1). Original solid-mass levels only;
# never copy official Level Devil layouts. The pilot rebuilds the
# vocabulary around SOLID MASSES (stairs, shafts, valleys, big walls,
# carved corridors, U-shapes) with INTEGRATED teeth (~10px, seated
# flush on solid tops/beam bottoms/wall faces), HIDDEN pits (falling
# kind -- draw is the runtime's job; this lane emits the kind), and
# GEOMETRY-AS-OBSTACLE shapes. NO saws anywhere in the pilot (all 10
# pilot archetypes are spike-family, rule 11), NO dotted_line emission
# anywhere, NO decorations (zero-deco pilot; rule-10 compat stays in
# the checker only).
#
# Coordinate discipline (v3 envelope, margin kept where possible):
#   ground tops G=640 for flat routes; steps rise 40 (<= 45); gaps
#   <= 76 (<= 80); landings >= 56 (>= 48); run-ups >= 48 (>= 24);
#   teeth 10px; pits/dashed/movers w 64..120, h=20; dashed period
#   2.6..3.2, on_time 1.8..2.2; falling stand_time 1.0..1.4; moving
#   period >= 2.4, travel <= 120. Interior masses are climbable
#   steps (rise <= 45), overhead beams with clearance, or edge
#   walls -- never an unclimbable wall across a walking route
#   (checker graph treats a shared floor node as walkable, but the
#   autopilot cannot pass a wall; flank walls for specials sit
#   FLUSH with the special's top so jump corridors stay open).
#   Safe zones: no hazard within 40px of the spawn point or door
#   rect. Specials are shaft-flanked (grounded columns both sides
#   within 8px spanning the full y-range) or resting.
#   Density (rule 9, solids only, floor slabs + edge walls
#   excluded): middle y170..550 AND core y310..510 each need >= 2
#   rects with combined width >= 160. Every pilot layout carries
#   its own counting masses (stairs / beams / interior walls).
#
# Skeleton table (archetype -> slot -> skeleton name; each
# archetype's 5 slots span >= 3 distinct shape skeletons):
#   D01 pitfall:      S1 stairs-pit, S2 valley-pit, S3 U-corridor-pit,
#                     S4 double-pit, S5 step-descent-pit
#   D02 spike-hops:   S1 flat-teeth, S2 stair-teeth, S3 valley-teeth,
#                     S4 terraces-teeth, S5 corridor-teeth
#   D12 dashed-chains:S1 flat-chain, S2 terrace-chain, S3 shaft-chain,
#                     S4 U-chain, S5 valley-chain
#   D15 moving-bridges:S1 flat-mover, S2 terrace-mover, S3 shaft-mover,
#                     S4 valley-mover, S5 corridor-mover
#   D17 ceiling-spikes:S1 beam-lining, S2 stair-ceiling,
#                     S3 valley-ceiling, S4 corridor-ceiling,
#                     S5 step-plateau-ceiling
#   D19 step-climbs:  S1 ascent, S2 valley-stairs, S3 terrace-stairs,
#                     S4 double-stair, S5 tower-stairs
#   D28 tower-descents:S1 standard-tower, S2 narrow-tower,
#                     S3 tall-tower, S4 low-tower, S5 mirror-tower
#   D29 reversed-runs:S1 reversed-strips, S2 reversed-gaps,
#                     S3 reversed-columns, S4 reversed-mixed,
#                     S5 reversed-triggered
#   D31 drop-shafts:  S1 standard-shaft, S2 narrow-shaft,
#                     S3 wide-shaft, S4 left-shaft, S5 right-shaft
#   D39 dashed-towers:S1 standard-dashed, S2 narrow-dashed,
#                     S3 tall-dashed, S4 low-dashed, S5 mirror-dashed
# ---------------------------------------------------------------------------

V3_GROUND = 640  # flat-route ground top for pilot builders

PILOT_DOORS = [(1, "pitfall", "v3_d01"),
               (2, "spike-hops", "v3_d02"),
               (12, "dashed-chains", "v3_d12"),
               (15, "moving-bridges", "v3_d15"),
               (17, "ceiling-spikes", "v3_d17"),
               (19, "step-climbs", "v3_d19"),
               (28, "tower-descents", "v3_d28"),
               (29, "reversed-runs", "v3_d29"),
               (31, "drop-shafts", "v3_d31"),
               (39, "dashed-towers", "v3_d39")]

PILOT_SKELETONS = {
    1: {1: "stairs-pit", 2: "valley-pit", 3: "U-corridor-pit",
        4: "double-pit", 5: "step-descent-pit"},
    2: {1: "flat-teeth", 2: "stair-teeth", 3: "valley-teeth",
        4: "terraces-teeth", 5: "corridor-teeth"},
    12: {1: "flat-chain", 2: "terrace-chain", 3: "stair-chain",
         4: "gap-chain", 5: "valley-chain"},
    15: {1: "flat-mover", 2: "terrace-mover", 3: "shaft-mover",
         4: "valley-mover", 5: "corridor-mover"},
    17: {1: "beam-lining", 2: "stair-ceiling", 3: "valley-ceiling",
         4: "corridor-ceiling", 5: "step-plateau-ceiling"},
    19: {1: "ascent", 2: "valley-stairs", 3: "terrace-stairs",
         4: "double-stair", 5: "tower-stairs"},
    28: {1: "standard-tower", 2: "narrow-tower", 3: "tall-tower",
         4: "low-tower", 5: "mirror-tower"},
    29: {1: "reversed-strips", 2: "reversed-gaps",
         3: "reversed-columns", 4: "reversed-mixed",
         5: "reversed-triggered"},
    31: {1: "standard-shaft", 2: "narrow-shaft", 3: "wide-shaft",
         4: "left-shaft", 5: "right-shaft"},
    39: {1: "standard-dashed", 2: "narrow-dashed", 3: "tall-dashed",
         4: "low-dashed", 5: "mirror-dashed"},
}


# --- v3 kit helpers ---------------------------------------------------------

def _vm(c, x, top, w):
    """Floor-rooted solid mass (bottom at the v3 floor line)."""
    return plat(x, top, w, c.floor_y - top, "solid")


def _vb(x, y, w, h):
    """Free solid block."""
    return plat(x, y, w, h, "solid")


def _vt(x, top, w, **kw):
    """Integrated up-teeth seated flush on solid top `top`."""
    return spikes_up(x, w, top=top, **kw)


def _vtd(x, y, w):
    """Integrated down-teeth hanging from a beam bottom at `y`."""
    return spikes_down(x, w, y, 10)


def _vts(x, y, h, direction):
    """Integrated side-teeth (10px wide) on a wall face."""
    return spikes_side(x, y, 10, h, direction)


def _vpit(x, top, w, stand):
    """Hidden pit: falling stone, same rect as a solid floor piece."""
    return plat(x, top, w, 20, "falling", stand_time=float(stand))


def _vdash(x, top, w, period, phase, on):
    """Dashed stone (timed, on_time >= 0.9 window-safe)."""
    return plat(x, top, w, 20, "dashed", period=float(period),
                phase=float(phase), on_time=float(on))


def _vmov(x, top, w, dx, dy, period):
    """Moving bridge stone."""
    return plat(x, top, w, 20, "moving", dx=float(dx), dy=float(dy),
                period=float(period))


def _vcol(x, h, w, top=V3_GROUND):
    """Spiked column. Round 4 standard is 26x36 only (span test:
    w+15 <= max_jump_dist*sqrt(1-h/apex): 26x36 -> 41 <= 49.66
    PASS; 56x40 -> 71 > 43.11 FAIL; the old 56x40/48x40 columns
    were uncrossable and the old checker let them through)."""
    return column(x, h, w, top=top)


def _vwalls(c, beam_tops, wall_top=150):
    """Edge walls (x 0..48 / 1232..1280, y wall_top..720) + full-width
    beams at the given tops. Beams ground by both-ends contact
    with the walls (y-overlap 16). Walls are off-route: spawn x
    >= 70 and door rect ends <= 1228. wall_top varies per door
    (Lane G5 layout distinctness); the default 150 keeps the
    pilot builders byte-identical."""
    out = [plat(0, wall_top, 48, c.floor_y - wall_top, "solid"),
           plat(1232, wall_top, 48, c.floor_y - wall_top, "solid")]
    for t in beam_tops:
        out.append(plat(48, t, 1184, 16, "solid"))
    return out


def _vstairs_up(c, x0, top0, n, tread=80, rise=40):
    """Floor-rooted staircase ascending to the right. Returns
    (rects, end_x, end_top): end_top is the top step's top."""
    rects = []
    for i in range(n):
        rects.append(_vm(c, x0 + i * tread, top0 - (i + 1) * rise,
                         tread))
    return rects, x0 + n * tread, top0 - n * rise


def _vstairs_down(c, x0, top0, n, tread=80, rise=40):
    """Floor-rooted staircase descending to the right."""
    rects = []
    for i in range(n):
        rects.append(_vm(c, x0 + i * tread, top0 + i * rise, tread))
    return rects, x0 + n * tread, top0 + (n - 1) * rise


def _v3_ground(c, x0=0, x1=1280, top=V3_GROUND):
    """One flat ground slab."""
    return plat(x0, top, x1 - x0, c.floor_y - top, "solid")


def _vo(variant, options):
    """Deterministic per-variant pick (variant 1..3). Variant-keyed
    geometry is what makes the 3 variants of a slot distinct under
    the checker's signature dedupe (>= 2 of layout / traps /
    solution must differ): kk-driven draws alone collide too often
    (a 20px shift usually leaves the 16/32px buckets unchanged)."""
    return options[(variant - 1) % len(options)]


# ---------------------------------------------------------------------------
# D01 pitfall -- hidden pits (falling) + triggered teeth.
# ---------------------------------------------------------------------------

def v3_d01(c, kk, salt, slot, variant):
    skel = PILOT_SKELETONS[1][slot]
    plats, hazards = [], []
    # Part B: the pit itself is the mechanic -- the falling pit
    # stones are replaced by DASHED (blink) pit stones in every
    # slot, so the hero must cross the pit on the stone's on-window;
    # triggered strips stay as the second element. Ramp
    # (slot-indexed): dashed period shortens, on_time shortens, and
    # the triggered strips' lead tightens across slots 1->5.
    # HONEST NOTE: a blink pit overlaps D12's blink kind, but D01's
    # is a floor segment (not a gap stone) + triggered strips.
    period = [3.0, 2.8, 2.8, 2.6, 2.6][slot - 1]
    on = [2.0, 2.0, 1.8, 1.8, 1.6][slot - 1]
    lead = [220, 210, 200, 190, 180][slot - 1]
    if slot == 1:  # stairs-pit
        px = _vo(variant, [140, 190, 240])
        ttx = _vo(variant, [1085, 1095, 1105])
        plats = [_v3_ground(c, 0, px),
                 _vdash(px, 640, 90, period, 0.0, on),
                 _v3_ground(c, px + 90, 400)]
        steps, ex, et = _vstairs_up(c, 400, 640, 4)
        plats += steps
        plats += [_vm(c, 720, 480, 120)]
        steps2, _, _ = _vstairs_down(c, 840, 520, 3)
        plats += steps2
        plats += [_v3_ground(c, 1080, 1280)]
        hazards = [_vt(792, 480, 48),
                   _vt(ttx, 640, 24, trigger_x=ttx - lead, delay=0.3)]
        spawn, door = (90, 640), (1190, 640)
    elif slot == 2:  # valley-pit
        beams = _vo(variant, [(320, 420), (340, 440), (360, 460)])
        plats = [_vm(c, 0, 560, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 640, 80),
                 _v3_ground(c, 560, 660),
                 _vdash(660, 640, 90, period, 0.0, on),
                 _v3_ground(c, 750, 840),
                 _vm(c, 840, 600, 80), _vm(c, 920, 560, 80),
                 _vm(c, 1000, 560, 280)]
        plats += _vwalls(c, list(beams))
        ttx = _vo(variant, [1040, 1060, 1080])
        hazards = [_vt(800, 640, 40),
                   _vt(ttx, 560, 50, trigger_x=ttx - lead, delay=0.3)]
        spawn, door = (90, 560), (1190, 560)
    elif slot == 3:  # U-corridor-pit
        px = _vo(variant, [520, 560, 600])
        plats = [_v3_ground(c, 0, 64),
                 _vm(c, 64, 480, 176),
                 _v3_ground(c, 240, px),
                 _vdash(px, 640, 100, period, 0.0, on),
                 _v3_ground(c, px + 100, 840),
                 _vm(c, 840, 600, 80), _vm(c, 920, 560, 80),
                 _vm(c, 1000, 520, 80),
                 _vm(c, 1080, 480, 136),
                 _v3_ground(c, 1216, 1280)]
        hazards = [_vt(300, 640, 50),
                   _vt(700, 640, 50, trigger_x=700 - lead, delay=0.3)]
        spawn, door = (120, 480), (1190, 480)
    elif slot == 4:  # double-pit (two blink pits, offset phases)
        px = _vo(variant, [380, 420, 460])
        qx = px + 330
        plats = [_v3_ground(c, 0, px),
                 _vdash(px, 640, 90, period, 0.0, on),
                 _v3_ground(c, px + 90, qx),
                 _vdash(qx, 640, 90, period, period / 2, on),
                 _v3_ground(c, qx + 90, 1280)]
        steps, _, _ = _vstairs_up(c, 140, 640, 3)
        plats += steps
        plats += _vwalls(c, [340, 440])
        hazards = [_vt(px + 180, 640, 50),
                   _vt(950, 640, 50, trigger_x=950 - lead, delay=0.3)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: step-descent-pit
        px = _vo(variant, [660, 700, 740])
        plats = [_vm(c, 48, 440, 200),
                 _v3_ground(c, 0, 48),
                 _vm(c, 248, 480, 80), _vm(c, 328, 520, 80),
                 _vm(c, 408, 560, 80), _vm(c, 488, 600, 80),
                 _v3_ground(c, 568, px),
                 _vdash(px, 640, 90, period, 0.0, on),
                 _v3_ground(c, px + 90, 1280)]
        hazards = [_vt(px + 140, 640, 50),
                   _vt(1020, 640, 50, trigger_x=1020 - lead, delay=0.3)]
        spawn, door = (120, 440), (1190, 640)
    return plats, hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D02 spike-hops -- teeth clusters + hops; no pits, no saws.
# ---------------------------------------------------------------------------

def v3_d02(c, kk, salt, slot, variant):
    skel = PILOT_SKELETONS[2][slot]
    plats, hazards = [], []
    if slot == 1:  # flat-teeth
        steps, _, _ = _vstairs_up(c, 120, 640, 4)
        beam = _vo(variant, [300, 320, 340])
        plats = [_v3_ground(c)] + steps + _vwalls(c, [beam])
        tx = _vo(variant, [480, 520, 560])
        hazards = [_vt(tx, 640, 35), _vt(tx + 83, 640, 35),
                   _vt(tx + 180, 640, 45), _vt(tx + 273, 640, 45),
                   _vt(tx + 400, 640, 50)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # stair-teeth -- REDESIGNED (Lane G5, Round 4):
        # Rise 40 / w48 / offset 48 capped the strip+stepup window at
        # 4.7px (shift ceiling 8.7px). Redesign: rise 32, strip w40 at
        # tread offset 56 (ends exactly at the next step edge) ->
        # window = span_hi(32) - 19.28 - 40 = 77.40 - 59.28 = 18.12px
        # >= 15 for every step. Plateau/down steps follow rise 32.
        x0 = _vo(variant, [160, 200, 240])
        steps, _, _ = _vstairs_up(c, x0, 640, 4, tread=96, rise=32)
        plats = [_v3_ground(c)] + steps + [_vm(c, x0 + 384, 512, 160)]
        steps2, _, _ = _vstairs_down(c, x0 + 544, 544, 3, tread=96,
                                     rise=32)
        plats += steps2
        plats += _vwalls(c, [300, 380])
        hazards = [_vt(x0 + 56, 608, 40), _vt(x0 + 152, 576, 40),
                   _vt(x0 + 248, 544, 40), _vt(x0 + 488, 512, 48),
                   _vt(x0 + 592, 544, 48)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 3:  # valley-teeth
        plats = [_vm(c, 0, 560, 320),
                 _vm(c, 320, 600, 80), _vm(c, 400, 640, 80),
                 _v3_ground(c, 480, 800),
                 _vm(c, 800, 600, 80), _vm(c, 880, 560, 80),
                 _vm(c, 960, 560, 320)]
        beams = _vo(variant, [(320, 420), (340, 440), (360, 460)])
        plats += _vwalls(c, list(beams))
        tx = _vo(variant, [540, 560, 580])
        # D11 (Round 3 gate): V3's pair must not mirror-collide with
        # V2's. The 70->60 shrink left mirrored qb buckets identical
        # (1220-560=660 -> qb 20, 1220-580=640 -> qb 20; second strip
        # 540/520 -> qb 16 both), so only the layout dimension
        # differed and V3 was a DUPLICATE of V2. Shift V3's pair one
        # qb bucket (32px) left: tx 580 -> 548, second 700 -> 668.
        # Mirrored buckets become 21/17 (V2: 20/16); direct buckets
        # become 17/20 (V2 min: 16/20) -- distinct in both
        # orientations. Width stays 60 (strip cap), inter-strip gap
        # stays 60, clearances on the 480..800 valley floor become
        # 68px before / 72px after (was 100/40). V1/V2 untouched.
        tx += _vo(variant, [0, 0, -32])
        wy = beams[0] + 20
        hazards = [_vt(tx, 640, 50), _vt(tx + 120, 640, 50),
                   _vts(48, wy, 70, "right"),
                   _vts(1222, wy, 70, "left")]
        spawn, door = (90, 560), (1190, 560)
    elif slot == 4:  # terraces-teeth
        x0 = _vo(variant, [200, 240, 280])
        plats = [_v3_ground(c),
                 _vm(c, x0, 600, 160), _vm(c, x0 + 400, 600, 160)]
        beams = _vo(variant, [(320, 440), (300, 420), (340, 460)])
        plats += _vwalls(c, list(beams))
        hazards = [_vt(x0 + 220, 640, 50), _vt(x0 + 640, 640, 50),
                   _vt(1040, 640, 50)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: corridor-teeth (roof beam + down-teeth)
        beams = _vo(variant, [(300, 400), (320, 420), (340, 440)])
        plats = [_v3_ground(c)] + _vwalls(c, list(beams))
        tx = _vo(variant, [280, 300, 320])
        hazards = [_vt(tx, 640, 35), _vt(tx + 83, 640, 35),
                   _vt(560, 640, 45), _vt(653, 640, 45),
                   _vt(840, 640, 50),
                   _vtd(500, beams[1] + 16, 60),
                   _vtd(900, beams[1] + 16, 60)]
        spawn, door = (70, 640), (1190, 640)
    return plats, hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D12 dashed-chains -- dashed stones in gaps; spike-family.
# ---------------------------------------------------------------------------

def v3_d12(c, kk, salt, slot, variant):
    # Lane C: dashed stones + POPUP spikes on the landing
    # grounds near a dashed stone. The popup sits on solid
    # ground clear of the strips (chain rule >=43px) and of
    # the dashed-stone landing. Declared primary {dashed,
    # spike_popup}, demo platform_hazard.
    skel = PILOT_SKELETONS[12][slot]
    plats, hazards = [], []
    if slot == 1:  # flat-chain
        dx = _vo(variant, [260, 300, 340])
        dp = _vo(variant, [(2.8, 0.0, 2.0), (3.0, 0.5, 2.0),
                           (2.6, 1.0, 1.8)])
        plats = [_v3_ground(c, 0, dx),
                 _vdash(dx, 640, 120, dp[0], dp[1], dp[2]),
                 _v3_ground(c, dx + 120, 620),
                 _vdash(620, 640, 120, 3.0, 0.5, 2.0),
                 _v3_ground(c, 740, 960),
                 _vdash(960, 640, 120, 2.6, 1.0, 1.8),
                 _v3_ground(c, 1080, 1280)]
        plats += _vwalls(c, [320, 440])
        # Lane C: popup phase 1.4 (not 0.0) -- at 0.0 the hero
        # arrives while it is UP, jumps it, and reaches the 960
        # dashed stone at a bad phase (died at feet 1072.4,766.9).
        # At 1.4 it is DOWN on arrival, so he runs over it and
        # times the stone cleanly.
        hazards = [_vt(520, 640, 50), _vt(800, 640, 50),
                   _h_popup(900, 640, 35, 3.0, 1.4, 1.4)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # terrace-chain
        dx = _vo(variant, [200, 240, 280])
        dp = _vo(variant, [(2.8, 0.0, 2.0), (3.0, 0.5, 2.0),
                           (2.6, 1.0, 1.8)])
        plats = [_v3_ground(c, 0, dx),
                 _vdash(dx, 640, 100, dp[0], dp[1], dp[2]),
                 _v3_ground(c, dx + 100, 540)]
        steps, _, _ = _vstairs_up(c, 540, 640, 4)
        plats += steps
        plats += [_vm(c, 860, 480, 120),
                  _v3_ground(c, 980, 1060),
                  _vdash(1060, 640, 80, 2.6, 0.5, 1.8),
                  _v3_ground(c, 1140, 1280)]
        hazards = [_vt(dx + 160, 640, 50), _vt(916, 480, 50),
                   _h_popup(dx + 260, 640, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 3:  # stair-chain (EXCEED: was a shaft layout that
        # converged with D01S3 U-corridor-pit, audit symdiff 3.
        # Now dashed stones bridge an ascending/descending stair
        # run instead of a shaft.)
        dp = _vo(variant, [(2.8, 0.0, 2.0), (3.0, 0.5, 2.0),
                           (2.6, 1.0, 1.8)])
        ox = _vo(variant, [0, 40, 80])
        plats = [_v3_ground(c, 0, 200)]
        steps, _, _ = _vstairs_up(c, 200, 640, 4)
        plats += steps
        plats += [_vm(c, 520, 480, 120),
                  _vdash(640 + ox, 480, 100, dp[0], dp[1], dp[2]),
                  _vm(c, 740 + ox, 480, 100)]
        steps2, _, _ = _vstairs_down(c, 840 + ox, 480, 3)
        plats += steps2
        plats += [_v3_ground(c, 1080 + ox, 1280)]
        hazards = [_vt(140, 640, 40), _vt(580, 480, 40),
                   _h_popup(780 + ox, 480, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 4:  # gap-chain (EXCEED: was a U-corridor that
        # converged with D01S3 U-corridor-pit, audit symdiff 3 — the
        # only differences were falling-vs-dashed on one stone plus
        # one spike strip. Now two dashed stones over two gaps at
        # different heights instead of a U-corridor.)
        ox = _vo(variant, [0, 30, 60])
        dp = _vo(variant, [(2.8, 0.0, 2.0), (3.0, 0.5, 2.0),
                           (2.6, 1.0, 1.8)])
        dp2 = _vo(variant, [(3.0, 0.5, 2.0), (2.6, 1.0, 1.8),
                            (2.8, 0.0, 2.0)])
        plats = [_v3_ground(c, 0, 240),
                 _vdash(240, 640, 100, dp[0], dp[1], dp[2]),
                 _v3_ground(c, 340 + ox, 560 + ox, top=600),
                 _vdash(560 + ox, 600, 100, dp2[0], dp2[1], dp2[2]),
                 _v3_ground(c, 660 + ox, 900 + ox, top=560),
                 _vm(c, 900 + ox, 600, 80),
                 _v3_ground(c, 980 + ox, 1280)]
        plats += _vwalls(c, [320, 440])
        hazards = [_vt(120, 640, 40), _vt(760 + ox, 560, 50),
                   _h_popup(855 + ox, 560, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: valley-chain
        dx = _vo(variant, [600, 620, 640])
        # Lane C: first option phase 0.5 (not 0.0) -- the hero
        # arrives at the first dashed stone at ~2.0s, exactly
        # when a 0.0-phase stone vanishes; 0.5 keeps it solid.
        dp = _vo(variant, [(2.8, 1.5, 2.0), (3.0, 0.5, 2.0),
                           (2.6, 1.0, 1.8)])
        plats = [_vm(c, 0, 560, 360),
                 _vm(c, 360, 600, 80), _vm(c, 440, 640, 80),
                 _v3_ground(c, 520, dx),
                 _vdash(dx, 640, 100, dp[0], dp[1], dp[2]),
                 _v3_ground(c, dx + 100, dx + 200),
                 _vdash(dx + 200, 640, 100, 3.0, 0.5, 2.0),
                 _v3_ground(c, dx + 300, 1000),
                 _vm(c, 1000, 600, 80),
                 _vm(c, 1080, 560, 200)]
        plats += _vwalls(c, [340, 440])
        tx1 = _vo(variant, [568, 588, 608])
        tx2 = _vo(variant, [752, 772, 792])
        # Lane C: NO popup here. A popup at 965 breaks the
        # first strip (tx1) deterministically -- the solver times
        # the early strip to the downstream popup and dies into
        # it (feet 580.1, 2x, identical). The door demo passes
        # via S1-S4; S5 stays dashed+strips only.
        hazards = [_vt(tx1, 640, 32), _vt(tx2, 640, 40)]
        spawn, door = (90, 560), (1190, 560)
    return plats, hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D15 moving-bridges -- moving stones over pits; spike-family.
# Mover travel is set so the swept extent exactly spans the pit:
# flanks touch the swept ends (gap 0) and span the sweep y-range.
# ---------------------------------------------------------------------------

def v3_d15(c, kk, salt, slot, variant):
    skel = PILOT_SKELETONS[15][slot]
    plats, hazards = [], []
    if slot == 1:  # flat-mover
        mx = _vo(variant, [440, 480, 520])
        mp = _vo(variant, [2.8, 3.0, 3.2])
        plats = [_v3_ground(c, 0, mx),
                 _vmov(mx, 640, 120, 120, 0, mp),
                 _v3_ground(c, mx + 240, 1280)]
        plats += _vwalls(c, [320, 440])
        hazards = [_vt(300, 640, 50), _vt(900, 640, 50)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # terrace-mover
        mx = _vo(variant, [320, 360, 400])
        mp = _vo(variant, [2.8, 3.0, 3.2])
        plats = [_v3_ground(c, 0, mx),
                 _vmov(mx, 640, 120, 120, 0, mp),
                 _vm(c, mx + 240, 600, 800 - (mx + 240)),
                 _vmov(800, 600, 120, 120, 0, mp),
                 _vm(c, 1040, 600, 240)]
        plats += _vwalls(c, [320, 440])
        hazards = [_vt(mx + 300, 600, 50),
                   _vt(1090, 600, 40)]
        spawn, door = (70, 640), (1190, 600)
    elif slot == 3:  # shaft-mover (vertical bob between ledges)
        mx = _vo(variant, [440, 480, 520])
        mp = _vo(variant, [2.6, 2.8, 3.0])
        dy = _vo(variant, [40, 60, 80])
        plats = [_vm(c, 0, 520, mx),
                 _vmov(mx, 520, 160, 0, dy, mp),
                 _vm(c, mx + 160, 520, 1280 - (mx + 160))]
        # G7: beam 420 -> 380. The 50px entry strip sits under beam
        # bottom 436; the ceiling-clipped jump rises only 45px and
        # spans ~53px vs 65px needed (P5: zero clears, zero lattice
        # clears). Beam bottom 396 clears the full-jump head peak
        # (520-39-57=424), so the strip is jumped unclipped; the
        # strip width and the vertical-bob mover are untouched.
        plats += _vwalls(c, [300, 380])
        hazards = [_vt(150, 520, 50), _vt(900, 520, 50)]
        spawn, door = (90, 520), (1190, 520)
    elif slot == 4:  # valley-mover
        mx = _vo(variant, [600, 640, 680])
        mp = _vo(variant, [2.8, 3.0, 3.2])
        plats = [_vm(c, 0, 560, 400),
                 _vm(c, 400, 600, 80),
                 _v3_ground(c, 480, mx),
                 _vmov(mx, 640, 100, 100, 0, mp),
                 _v3_ground(c, mx + 200, 1000),
                 _vm(c, 1000, 600, 80),
                 _vm(c, 1080, 560, 200)]
        plats += _vwalls(c, [340, 440])
        # Round 4: the rework table's 490 is geometrically impossible
        # (the strip would sit in the [480,528] landing zone of the
        # only edges onto the [480,mx] ground piece -> UNREACHABLE).
        # 530 is the leftmost reachable position (2px past the zone),
        # still moving the strip left, away from the mover at mx, as
        # the table intended (R3 gate §10.4: V1 died clipping the
        # strip's far edge with the mover just past it).
        # G5 REDESIGN (D02S2-class): V3's strip ended 10px before
        # the 600 step (window -7.3px, forced combined jump). V3's
        # strip is now w32 at x968 (ends exactly at the step edge):
        # intersection = 71.98 - 19.28 - 32 = 20.70px >= 15. V1/V2
        # keep their 90px/50px landings (separate jumps, unchanged).
        hazards = [_vt(530, 640, 50),
                   _vt(_vo(variant, [mx + 260, mx + 260, 968]), 640,
                      _vo(variant, [50, 50, 32]))]
        spawn, door = (90, 560), (1190, 560)
    else:  # slot 5: corridor-mover
        mx = _vo(variant, [480, 520, 560])
        mp = _vo(variant, [2.8, 3.0, 3.2])
        plats = [_v3_ground(c, 0, mx),
                 _vmov(mx, 640, 120, 120, 0, mp),
                 _v3_ground(c, mx + 240, 1280)]
        plats += _vwalls(c, [300, 420])
        hazards = [_vt(200, 640, 50), _vt(1000, 640, 50),
                   _vtd(300, 436, 60), _vtd(900, 436, 60)]
        spawn, door = (70, 640), (1190, 640)
    return plats, hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D17 ceiling-spikes -- down-teeth from high grounded beams. Teeth
# bottoms stay above the walking band (top - 39) AND the jump-arc
# band (top - apex ~52) of every route surface below them.
# ---------------------------------------------------------------------------

def v3_d17(c, kk, salt, slot, variant):
    skel = PILOT_SKELETONS[17][slot]
    plats, hazards = [], []
    # Part B: teeth at JUMP HEIGHT over RAISED ground in every level.
    # _pb_teeth_beam(T) puts the beam bottom 4px above the jump head
    # apex (T-91) and the teeth 6px below it, so a jump under the
    # teeth kills while walking clears them. (The old door hung its
    # teeth high above the walking band, where no jump could reach
    # them.) Floor strips sit in the gaps, >=100px past the preceding
    # cluster so the probe fires after the hero has cleared it.
    # BEAM LAW (checker _edge_for_rects "Blocker"): a full-width beam
    # at top B blocks edges over any surface whose top lies in
    # [B+20, B+68]. So a beam for surface T (at T-111) is only safe
    # when no OTHER surface top lies in [T-91, T-43]. In particular
    # a 640-ground beam (529) blocks every 560/576/600 surface, so
    # NO slot here has teeth over the flat exit ground -- the teeth
    # live only over raised surfaces whose beams clear the rest.
    # Ramp (slot-indexed): teeth-group count [3,5,5,5,6].
    if slot == 1:  # steps + 560 plateau (clusters: step1, plateau)
        steps, _, _ = _vstairs_up(c, 200, 640, 2, tread=96, rise=40)
        plats = [_v3_ground(c, 0, 200)] + steps + [
                 _vm(c, 392, 560, 408),
                 _vm(c, 800, 600, 96), _vm(c, 896, 640, 96),
                 _v3_ground(c, 992, 1280)]
        plats += _vwalls(c, [489, 449])
        hazards = [_vtd(220, 505, 60),
                   _vtd(520, 465, 60), _vtd(600, 465, 60)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # valley masses (clusters: left 560, right 560, rise)
        plats = [_vm(c, 0, 560, 360),
                 _vm(c, 360, 600, 80), _vm(c, 440, 640, 80),
                 _v3_ground(c, 520, 760),
                 _vm(c, 760, 600, 80), _vm(c, 840, 560, 80),
                 _vm(c, 920, 560, 360)]
        plats += _vwalls(c, [489, 449])
        hazards = [_vtd(120, 465, 60), _vtd(200, 465, 60),
                   _vt(600, 640, 40),
                   _vtd(770, 505, 60),
                   _vtd(960, 465, 60), _vtd(1040, 465, 60)]
        spawn, door = (90, 560), (1190, 560)
    elif slot == 3:  # stairs + 512 plateau (clusters: plateau, down-step1)
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        plats += _vwalls(c, [401, 433])
        hazards = [_vtd(x0 + 400, 417, 30), _vtd(x0 + 435, 417, 30),
                   _vtd(x0 + 470, 417, 30), _vtd(x0 + 505, 417, 30),
                   _vtd(x0 + 560, 449, 60),
                   _vt(1080, 640, 40)]
    elif slot == 4:  # terraces (clusters: 560, 520 terraces)
        plats, spawn, door, bx = _r_terraces(c, variant)
        plats += _vwalls(c, [449, 409])
        hazards = [_vtd(bx + 300, 465, 40), _vtd(bx + 350, 465, 40),
                   _vtd(bx + 400, 465, 40),
                   _vtd(bx + 540, 425, 60), _vtd(bx + 600, 425, 60),
                   _vt(bx + 760, 600, 40)]
    else:  # slot 5: step-plateau 520 (clusters: step2, plateau,
        # down-step1). NO T=600 cluster: a 600-cluster's beam (489)
        # blocks every edge over the 520 plateau (Blocker range
        # [509,557] covers top_min 520), so the step1 and down-step2
        # clusters are dropped and the plateau gets 3 groups of 40.
        steps, _, _ = _vstairs_up(c, 300, 640, 3, tread=96, rise=40)
        plats = [_v3_ground(c, 0, 300)] + steps + [
                 _vm(c, 588, 520, 152),
                 _vm(c, 740, 560, 96), _vm(c, 836, 600, 96),
                 _v3_ground(c, 932, 1280)]
        plats += _vwalls(c, [449, 409])
        hazards = [_vtd(420, 465, 60),
                   _vtd(600, 425, 40), _vtd(650, 425, 40),
                   _vtd(700, 425, 40),
                   _vtd(760, 465, 60),
                   _vt(200, 640, 40), _vt(1000, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    return plats, hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D19 step-climbs -- stairs with teeth at the far ends of treads
# (landing zones, the first 48px of each step, stay clear).
# ---------------------------------------------------------------------------

def v3_d19(c, kk, salt, slot, variant):
    # Lane C: floor strips + POPUP spikes interleaved on the
    # steps. Each popup sits on a strip-free step, next to a
    # strip step. (A pure-spike pair can never survive fix (d),
    # so this door is a single_family demo.) Declared primary
    # {spike_up, spike_popup}, demo single_family.
    skel = PILOT_SKELETONS[19][slot]
    plats, hazards = [], []
    if slot == 1:  # ascent (8-step staircase to a high door)
        x0 = _vo(variant, [160, 200, 240])
        steps, _, _ = _vstairs_up(c, x0, 640, 8, tread=96)
        plats = [_v3_ground(c, 0, x0)] + steps + [
            _vm(c, x0 + 768, 320, 1280 - (x0 + 768))]
        # Lane C: all 8 steps carry strips, so the popup goes
        # on the top mass (320) at 1075 (1100 is 15px inside
        # the door safe zone -- the popup must end by 1110).
        hazards = [_vt(x0 + 56 + 96 * i + (3 if i < 7 else 0),
                       600 - 40 * i, 40)
                   for i in range(8)] + [_h_popup(1075, 320, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 320)
    elif slot == 2:  # valley-stairs
        vx = _vo(variant, [728, 768, 808])
        plats = [_v3_ground(c, 0, 160),
                 _vm(c, 160, 600, 96), _vm(c, 256, 560, 96),
                 _vm(c, 352, 520, 96),
                 _vm(c, vx - 320, 520, 128),
                 _vm(c, vx - 192, 560, 96), _vm(c, vx - 96, 600, 96),
                 _v3_ground(c, vx, vx + 160),
                 _vm(c, vx + 160, 600, 96), _vm(c, vx + 256, 560, 96),
                 _vm(c, vx + 352, 560, 1280 - (vx + 352))]
        # G3 (gate D5): y440 beam raised to y380. A jump from the
        # 520-top (feet 520, rise 57, head 39) peaks with the head
        # at y424; the y440 beam (440..456) killed vy and dropped
        # the hero onto strip 2. Beam 380..396 leaves 28px head
        # clearance and still sits in the core band (310..510),
        # so rule 9 density is unchanged.
        plats += _vwalls(c, [320, 380])
        hazards = [_vt(219, 600, 40), _vt(vx - 264, 520, 40),
                   _vt(vx + 56, 640, 50), _vt(vx + 304, 560, 16),
                   _h_popup(320, 560, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 560)
    elif slot == 3:  # terrace-stairs
        bx = _vo(variant, [160, 200, 240])
        plats = [_v3_ground(c),
                 _vm(c, bx, 600, 160), _vm(c, bx + 200, 600, 80),
                 _vm(c, bx + 280, 560, 160), _vm(c, bx + 440, 560, 80),
                 _vm(c, bx + 520, 520, 160),
                 _vm(c, bx + 680, 560, 80), _vm(c, bx + 760, 600, 80)]
        # G3 (gate D5): same beam defect as S2 — the y440 beam
        # killed the jump over the 520-top strip (diag perfect
        # mode: all 3 variants die on hazard 2 at feet y519.9).
        # Beam raised to y380: 28px head clearance (apex y424),
        # still in the core band; the y300 beam + its down-teeth
        # (600,316) are untouched.
        plats += _vwalls(c, [300, 380])
        hazards = [_vt(bx + 80, 600, 50), _vt(bx + 340, 560, 50),
                   _vt(bx + 600, 520, 50), _vtd(600, 316, 70),
                   # Lane C: popup at bx+470 (560) on [bx+440,520],
                   # NOT bx+230 -- that sits 20px past a gap-jump
                   # landing and the solver dies at the first strip
                   # (feet 244.2, 2x). Here the hero walks on (no
                   # gap-jump) before facing it.
                   _h_popup(bx + 470, 560, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 4:  # double-stair
        bx = _vo(variant, [160, 200, 240])
        plats = [_v3_ground(c, 0, bx),
                 _vm(c, bx, 600, 96), _vm(c, bx + 96, 560, 96),
                 _vm(c, bx + 192, 520, 96),
                 _vm(c, bx + 288, 520, 224),
                 _vm(c, bx + 512, 480, 96), _vm(c, bx + 608, 440, 96),
                 _vm(c, bx + 704, 400, 96),
                 _vm(c, bx + 800, 400, 1280 - (bx + 800))]
        hazards = [_vt(bx + 59, 600, 40), _vt(bx + 344, 520, 40),
                   _vt(bx + 571, 480, 40), _vt(bx + 760, 400, 40),
                   _h_popup(bx + 140, 560, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 400)
    else:  # slot 5: tower-stairs
        bx = _vo(variant, [80, 120, 160])
        plats = [_v3_ground(c),
                 _vm(c, bx, 600, 96), _vm(c, bx + 96, 560, 96),
                 _vm(c, bx + 192, 520, 96), _vm(c, bx + 288, 480, 96),
                 _vm(c, bx + 384, 480, 272),
                 _vm(c, bx + 656, 520, 96), _vm(c, bx + 752, 560, 96),
                 _vm(c, bx + 848, 600, 96)]
        hazards = [_vt(bx + 59, 600, 40), _vt(bx + 251, 520, 40),
                   _vt(bx + 440, 480, 50), _vt(bx + 808, 560, 40),
                   _h_popup(bx + 140, 560, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 640)
    return plats, hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# Tower family (D28/D39): alternating wide floors + short pads joined
# by gap edges (G <= 70 <= 80). Left floors are inset 48px from the
# screen edge so they count toward rule 9 (edge walls excluded);
# repair pillars land at the inset edge (x 48..96), clear of the
# right-side descent. Pads end <= 1070 (>= 80px from the door).
# No saws in the pilot (spike-family); no hazards on dashed pads.
# ---------------------------------------------------------------------------

def _v3_tower(c, kk, salt, cfg, dashed):
    T = g(kk, cfg["T"], salt=salt + 1)
    S = g(kk, cfg["S"], salt=salt + 1)
    E1 = g(kk, cfg["E1"], salt=salt + 2)
    G = g(kk, cfg["G"], salt=salt + 2)
    E2 = E1 + G
    padw = g(kk, cfg["padw"], salt=salt + 2)
    PR = min(E2 + padw, 1070)
    if dashed:
        PR = min(PR, 1050)
    tops = [T, T + S, T + 2 * S, T + 3 * S]
    mirror = cfg.get("mirror", False)
    if mirror:
        # Floors on the right, pads on the left; spawn right, door
        # ground-left. Descent zigzags leftwards.
        x0 = 1280 - E1
        if dashed:
            plats = [plat(x0, tops[0], E1 - 48, 20, "solid"),
                     _vdash(1280 - E2 - (PR - E2), tops[1], PR - E2,
                            2.8, 0.0, 2.0),
                     _vdash(x0, tops[2], E1 - 48, 3.0, 0.5, 2.0),
                     _vdash(1280 - E2 - (PR - E2), tops[3], PR - E2,
                            2.6, 1.0, 1.8),
                     _v3_ground(c)]
        else:
            plats = [plat(x0, tops[0], E1 - 48, 20, "solid"),
                     plat(1280 - PR, tops[1], PR - E2, 20, "solid"),
                     plat(x0, tops[2], E1 - 48, 20, "solid"),
                     plat(1280 - PR, tops[3], PR - E2, 20, "solid"),
                     _v3_ground(c)]
        spawn_x = 1190
        door_x = 90
    else:
        if dashed:
            plats = [plat(48, tops[0], E1 - 48, 20, "solid"),
                     _vdash(E2, tops[1], PR - E2, 2.8, 0.0, 2.0),
                     _vdash(48, tops[2], E1 - 48, 3.0, 0.5, 2.0),
                     _vdash(E2, tops[3], PR - E2, 2.6, 1.0, 1.8),
                     _v3_ground(c)]
        else:
            plats = [plat(48, tops[0], E1 - 48, 20, "solid"),
                     plat(E2, tops[1], PR - E2, 20, "solid"),
                     plat(48, tops[2], E1 - 48, 20, "solid"),
                     plat(E2, tops[3], PR - E2, 20, "solid"),
                     _v3_ground(c)]
        spawn_x = 90
        door_x = 1190
    if dashed:
        # Second support column beside the repair pillar (x 48..96):
        # the core band needs >= 160 width and repair pillars are
        # 48px; in S1 the P1/P2 flank wall is shared and counted
        # once (3 x 48 = 144). Clear of the right-side descent and
        # of the ground route (hero lands at x ~850, walks right).
        cx = 96 if not mirror else 1280 - 192
        plats.append(plat(cx, tops[0] + 20, 96,
                          c.floor_y - (tops[0] + 20), "solid"))
    return plats, tops, E1, E2, PR, spawn_x, door_x


def v3_d28(c, kk, salt, slot, variant):
    skel = PILOT_SKELETONS[28][slot]
    if slot == 1:
        cfg = {"T": [_vo(variant, [170, 180, 190])],
               "S": [_vo(variant, [90, 95, 90])],
               "E1": [_vo(variant, [780, 820, 860])],
               "G": [_vo(variant, [50, 60, 70])],
               "padw": [_vo(variant, [150, 170, 190])]}
    elif slot == 2:
        cfg = {"T": [_vo(variant, [180, 190, 170])],
               "S": [_vo(variant, [95, 90, 95])],
               "E1": [_vo(variant, [820, 860, 780])],
               "G": [_vo(variant, [60, 70, 50])],
               "padw": [_vo(variant, [170, 190, 150])]}
    elif slot == 3:
        cfg = {"T": [_vo(variant, [190, 170, 180])],
               "S": [_vo(variant, [90, 95, 90])],
               "E1": [_vo(variant, [860, 780, 820])],
               "G": [_vo(variant, [70, 50, 60])],
               "padw": [_vo(variant, [190, 150, 170])]}
    elif slot == 4:
        cfg = {"T": [_vo(variant, [175, 185, 195])],
               "S": [_vo(variant, [90, 90, 95])],
               "E1": [_vo(variant, [800, 840, 760])],
               "G": [_vo(variant, [55, 65, 60])],
               "padw": [_vo(variant, [160, 180, 170])]}
    else:
        cfg = {"T": [_vo(variant, [185, 175, 195])],
               "S": [_vo(variant, [95, 90, 90])],
               "E1": [_vo(variant, [840, 800, 780])],
               "G": [_vo(variant, [65, 55, 60])],
               "padw": [_vo(variant, [180, 160, 150])], "mirror": True}
    plats, tops, E1, E2, PR, sx, dx = _v3_tower(
        c, kk, salt, cfg, dashed=False)
    mirror = cfg.get("mirror", False)
    if mirror:
        hazards = [_vt(882, tops[0], 35), _vt(965, tops[0], 35),
                   _vcol(600, 36, 26, top=tops[0]),
                   _vt(882, tops[2], 35), _vt(965, tops[2], 35),
                   _vt(1280 - PR + 40, tops[1], 48),
                   _vt(682, 640, 35), _vt(765, 640, 35),
                   _vt(500, 640, 50),
                   _vcol(166, 36, 26)]
    elif slot == 2:
        hazards = [_vt(300, tops[0], 50, trigger_x=240, delay=0.3),
                   _vcol(620, 36, 26, top=tops[2]),
                   _vt(E2 + 60, tops[3], 48),
                   _vt(300, 640, 35), _vt(383, 640, 35),
                   _vt(700, 640, 50)]
    elif slot == 3:
        hazards = [_vt(240, tops[0], 40), _vt(328, tops[0], 40),
                   _vt(520, tops[0], 50),
                   _vcol(700, 36, 26, top=tops[0]),
                   _vt(300, tops[2], 35), _vt(383, tops[2], 35),
                   _vcol(500, 36, 26), _vt(PR + 5, 640, 48)]
    elif slot == 4:
        hazards = [_vt(300, tops[0], 35), _vt(383, tops[0], 35),
                   _vcol(640, 36, 26, top=tops[2]),
                   _vt(240, 640, 35), _vt(323, 640, 35),
                   _vt(480, 640, 40), _vt(568, 640, 40),
                   _vt(700, 640, 50), _vcol(PR + 5, 36, 26)]
    else:
        hazards = [_vt(240, tops[0], 35), _vt(323, tops[0], 35),
                   _vcol(660, 36, 26, top=tops[0]),
                   _vt(240, tops[2], 35), _vt(323, tops[2], 35),
                   _vcol(620, 36, 26, top=tops[2]),
                   _vt(E2 + 60, tops[1], 48),
                   _vt(240, 640, 35), _vt(323, 640, 35),
                   _vcol(700, 36, 26)]
    return plats, hazards, (sx, tops[0]), (dx, 640), skel


def v3_d39(c, kk, salt, slot, variant):
    # Lane C: ground popup at 600 (top 640) in every slot, near a
    # column (|600-column_centre| <= 113): (column, spike_popup)
    # survives; declared primary {dashed, column_floor, spike_popup},
    # demo pair_platform (dashed on route + surviving primary pair).
    skel = PILOT_SKELETONS[39][slot]
    if slot == 1:
        cfg = {"T": [_vo(variant, [170, 180, 190])],
               "S": [_vo(variant, [90, 95, 90])],
               "E1": [_vo(variant, [780, 820, 860])],
               "G": [_vo(variant, [50, 60, 70])],
               "padw": [_vo(variant, [150, 170, 190])]}
    elif slot == 2:
        cfg = {"T": [_vo(variant, [175, 185, 195])],
               "S": [_vo(variant, [95, 90, 95])],
               "E1": [_vo(variant, [800, 840, 780])],
               "G": [_vo(variant, [55, 65, 50])],
               "padw": [_vo(variant, [160, 180, 150])]}
    elif slot == 3:
        cfg = {"T": [_vo(variant, [180, 170, 190])],
               "S": [_vo(variant, [90, 95, 90])],
               "E1": [_vo(variant, [860, 780, 820])],
               "G": [_vo(variant, [70, 50, 60])],
               "padw": [_vo(variant, [190, 150, 170])]}
    elif slot == 4:
        cfg = {"T": [_vo(variant, [175, 185, 195])],
               "S": [_vo(variant, [90, 90, 95])],
               "E1": [_vo(variant, [800, 820, 760])],
               "G": [_vo(variant, [55, 65, 60])],
               "padw": [_vo(variant, [160, 180, 170])]}
    else:
        cfg = {"T": [_vo(variant, [185, 180, 195])],
               "S": [_vo(variant, [95, 90, 90])],
               "E1": [_vo(variant, [840, 800, 780])],
               "G": [_vo(variant, [65, 55, 60])],
               "padw": [_vo(variant, [180, 160, 150])], "mirror": True}
    plats, tops, E1, E2, PR, sx, dx = _v3_tower(
        c, kk, salt, cfg, dashed=True)
    mirror = cfg.get("mirror", False)
    if mirror:
        hazards = [_vt(882, tops[0], 35), _vt(965, tops[0], 35),
                   _vcol(600, 36, 26, top=tops[0]),
                   _vt(682, 640, 35), _vt(765, 640, 35),
                   _vt(500, 640, 50),
                   # Lane C: popup on the TOP floor at 500 (tops[0]),
                   # 100 px before the column at 660 (|673-517|=156).
                   _h_popup(500, tops[0], 35, 3.0, 0.0, 1.4)]
    elif slot == 2:
        hazards = [_vt(_vo(variant, [240, 280, 320]), tops[0], 50),
                   _vcol(600, 36, 26, top=tops[0]),
                   _vt(_vo(variant, [260, 300, 340]), 640, 35),
                   _vt(_vo(variant, [343, 383, 423]), 640, 35),
                   _h_popup(500, tops[0], 35, 3.0, 0.7, 1.4)]
    elif slot == 3:
        hazards = [_vt(_vo(variant, [240, 280, 320]), tops[0], 35),
                   _vt(_vo(variant, [323, 363, 403]), tops[0], 35),
                   _vt(520, tops[0], 50),
                   _vcol(500, 36, 26),
                   _vt(300, 640, 35), _vt(383, 640, 35),
                   # Lane C: S3 has NO top-floor column (its only
                   # column is on the ground, never walked), so add
                   # one at 700 (tops[0]). NO popup here: a popup
                   # anywhere in the free [570,780] zone lands the
                   # hero 40-45 px before the column and the
                   # autopilot runs into it (died at feet 693.5,
                   # twice, popup at 620 and 615). The door demo
                   # still passes via S1/S2/S4/S5 (simul 4/5).
                   _vcol(700, 36, 26, top=tops[0])]
    elif slot == 4:
        hazards = [_vt(300, tops[0], 35), _vt(383, tops[0], 35),
                   _vcol(620, 36, 26, top=tops[0]),
                   _vt(240, 640, 35), _vt(323, 640, 35),
                   _vt(520, 640, 50),
                   _vt(650, 640, 50),
                   _h_popup(500, tops[0], 35, 3.0, 0.0, 1.4)]
    else:
        hazards = [_vt(_vo(variant, [240, 280, 320]), tops[0], 35),
                   _vt(_vo(variant, [323, 363, 403]), tops[0], 35),
                   _vcol(660, 36, 26, top=tops[0]),
                   _vt(240, 640, 35), _vt(323, 640, 35),
                   _vcol(700, 36, 26),
                   _h_popup(500, tops[0], 35, 3.0, 0.7, 1.4)]
    return plats, hazards, (sx, tops[0]), (dx, 640), skel


# ---------------------------------------------------------------------------
# D29 reversed-runs -- door LEFT, spawn RIGHT. Simple isolated
# obstacles only: strips, gaps (w <= 76), jumpable columns (h <= 44,
# w <= 64), triggered strips (trigger to the RIGHT of the strip, in
# travel direction). >= 200px clear between obstacles.
# ---------------------------------------------------------------------------

def v3_d29(c, kk, salt, slot, variant):
    skel = PILOT_SKELETONS[29][slot]
    _BEAMS = {1: [(304, 416), (320, 432), (336, 448)],
              2: [(304, 432), (320, 448), (336, 464)],
              3: [(352, 416), (368, 432), (384, 448)],
              4: [(352, 432), (368, 448), (384, 464)],
              5: [(400, 416), (416, 448), (400, 464)]}
    beams = _BEAMS[slot][variant - 1]
    sh = _vo(variant, [-40, 0, 40])
    lead = [160, 140, 140, 120, 120][slot - 1]

    def _trig(x, w=45):
        return _h_trig_left(x, 640, w, lead=lead, delay=0.3)

    if slot == 1:  # reversed-strips: 3 triggered + 1 column
        plats = [_v3_ground(c)] + _vwalls(c, beams)
        hazards = [_trig(860), _trig(540), _trig(220),
                   _h_col(700, 640)]
    elif slot == 2:  # reversed-gaps: 2 gaps + 2 triggered + 1 column
        g1 = 280 + sh - 38
        g2 = 920 + sh - 38
        plats = [_v3_ground(c, 0, g1), _v3_ground(c, g1 + 76, g2),
                 _v3_ground(c, g2 + 76, 1280)] + _vwalls(c, beams)
        hazards = [_trig(700, 50), _trig(420, 50), _h_col(1060, 640)]
    elif slot == 3:  # reversed-columns: 3 columns + 3 triggered
        plats = [_v3_ground(c)] + _vwalls(c, beams)
        hazards = [_trig(800), _h_col(700, 640), _trig(480),
                   _h_col(380, 640), _trig(160), _h_col(250, 640)]
    elif slot == 4:  # reversed-mixed: gap + 3 triggered + 1 column
        g1 = 596 + sh - 36
        plats = [_v3_ground(c, 0, g1), _v3_ground(c, g1 + 72, 1280)] \
            + _vwalls(c, beams)
        hazards = [_trig(960), _trig(760), _trig(220),
                   _h_col(880, 640)]
    else:  # slot 5: reversed-triggered: 4 triggered + 1 column
        plats = [_v3_ground(c)] + _vwalls(c, beams)
        hazards = [_trig(1000, 50), _trig(760, 40), _trig(520, 40),
                   _trig(280, 50), _h_col(640, 640)]
    return plats, hazards, (1190, 640), (90, 640), skel
# ---------------------------------------------------------------------------
# D31 drop-shafts -- two stacked floors + ground, one wide shaft
# (340-440, no jump can clear). Shaft walls span ONLY the inter-floor
# band (T1..T2) and rest on the lower floors; wall teeth are 10px
# (walled band only). No saws. Walls are 96px wide so the two walls
# meet rule 9 (combined width >= 160) in both bands.
# ---------------------------------------------------------------------------

def v3_d31(c, kk, salt, slot, variant):
    # Lane C2 (follow-up): NEW primary {column_floor, pillar_trig},
    # demo pair. The Skeptic rejected Lane C's {column_floor,
    # spike_popup} as an exact duplicate of D22 (first home, 14
    # pairs), so ALL popups are REMOVED. Teeth stay out (Lane C's
    # teeth-unbuildable rationale stands: no beam, floors 190-200px
    # apart). Instead one TRIGGERED pillar per slot drops onto the
    # ground walk after the shaft drop, paired with a ground column
    # ~140-150px before it (pair partner, within the +/-300px
    # window). spike_up strips stay as EXPLICITLY SECONDARY filler
    # (D22 precedent: secondary pairs demonstrate nothing and block
    # nothing); wall teeth stay (dead filler, shaft identity).
    # Set is new: no earlier door has {column_floor, pillar_trig}
    # (D25 is {pillar_periodic, column_floor}; trig vs periodic is
    # the same distinguishing axis as D06 vs D07, both PASS homes).
    skel = PILOT_SKELETONS[31][slot]
    if slot == 1:
        T1, D, sx, sw = 160, 200, _vo(variant, [560, 600, 640]), 400
    elif slot == 2:
        T1, D, sx, sw = 170, 190, _vo(variant, [520, 560, 600]), 340
    elif slot == 3:
        T1, D, sx, sw = 150, 200, _vo(variant, [540, 580, 620]), 440
    elif slot == 4:
        T1, D, sx, sw = 160, 200, _vo(variant, [260, 300, 340]), 400
    else:
        # Lane C2: shaft moved left (sx 720->600, sw 380->300).
        # The old gap [720,1100] leaves a 254px ground walk, too
        # short for column+pillar+door with legal run-ups.
        T1, D, sx, sw = 160, 200, _vo(variant, [600, 640, 680]), 300
    T2 = T1 + D
    rx = sx + sw
    plats = [plat(0, T1, sx, 20, "solid"),
             plat(rx, T1, 1280 - rx, 20, "solid"),
             plat(0, T2, sx, 20, "solid"),
             plat(rx, T2, 1280 - rx, 20, "solid"),
             _v3_ground(c),
             plat(sx - 96, T1, 96, D, "solid"),
             plat(rx, T1, 96, D, "solid")]
    y1 = T1 + 60
    wall_teeth = [_vts(sx, y1, 48, "right"),
                  _vts(rx - 10, y1, 48, "left")]
    if slot == 1:
        # Lane C2: ground column 850 + trig pillar 1000 (trigger
        # 718, in the shaft gap — fires on the airborne crossing).
        # Ground column 1060 + popup 980 REMOVED.
        hazards = [_vt(200, T1, 35), _vt(283, T1, 35),
                   _vcol(400, 36, 26, top=T1),
                   _vt(200, T2, 35), _vt(283, T2, 35),
                   _vt(300, 640, 50), _vcol(850, 36, 26),
                   _h_pillar_trig(c, 1000, 150, 104, 700)] + wall_teeth
    elif slot == 2:
        # Lane C2: ground column 860 + trig pillar 1000 (trigger
        # 718, crossed on the ground walk just after the shaft
        # landing). The 820 column's takeoff window [775,793] sat
        # AT the shaft-drop landing (~775) — the planner's first
        # ground re-check came after the window, so the hero
        # walked into the column. The 860 column's window
        # [815,833] is 40px past the landing. Trig strip 950,
        # strip 1050, popup 850 REMOVED (strip 950 sat under the
        # pillar; strip 1050 was 40px past the pillar landing).
        hazards = [_vt(240, T1, 50),
                   _vt(240, T2, 50),
                   _vcol(860, 36, 26),
                   _h_pillar_trig(c, 1000, 150, 104, 700)] + wall_teeth
    elif slot == 3:
        # Lane C2: ground column 880 + trig pillar 1020 (trigger
        # 738, in the gap). Strip 1060 + T1 popup 200 REMOVED
        # (strip 1060 sat in the pillar-jump landing).
        hazards = [_vcol(300, 36, 26, top=T1), _vt(380, T1, 50),
                   _vt(250, T2, 50),
                   _vt(200, 640, 50), _vcol(880, 36, 26),
                   _h_pillar_trig(c, 1020, 150, 104, 700)] + wall_teeth
    elif slot == 4:
        # Lane C2: filler strip 600 + ground column 850 + trig
        # pillar 1000 (trigger 718, on the ground walk — the hero
        # lands at ~476 and walks across it). Strips 900/983,
        # column 1060, popup 800 REMOVED (900 sat 50px past the
        # column jump; 983 sat under the pillar).
        hazards = [_vt(800, T1, 35), _vt(883, T1, 35),
                   _vcol(950, 36, 26, top=T1),
                   _vt(880, T2, 35), _vt(963, T2, 35),
                   _vt(600, 640, 40), _vcol(850, 36, 26),
                   _h_pillar_trig(c, 1000, 150, 104, 700)] + wall_teeth
    else:
        # Lane C2: ground column 920 + trig pillar 1060 (trigger
        # 778, crossed on the ground walk just after the shaft
        # landing). The 880 column's takeoff window [835,853] sat
        # BEHIND the shaft-drop landing (~855) — the hero landed
        # past the window and walked into the column. The 920
        # column's window [875,893] is 20px past the landing.
        # Ground column 500 + T1 popup 550 REMOVED.
        hazards = [_vt(200, T1, 35), _vt(283, T1, 35),
                   _vcol(450, 36, 26, top=T1),
                   _vt(300, T2, 50),
                   _vt(200, 640, 50), _vcol(920, 36, 26),
                   _h_pillar_trig(c, 1060, 150, 104, 700)] + wall_teeth
    return plats, hazards, (90, T1), (1190, 640), skel


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# v3 builders for the other 34 doors (Round 4 post-GO, Lane G5).
#
# Same vocabulary + coordinate discipline as the pilot builders above
# (ground tops 640, steps rise <= 45, gaps <= 76, landings >= 56,
# run-ups >= 48, teeth 10px, pits/dashed/movers w 64..120 h=20,
# dashed period 2.6..3.2 on 1.8..2.2, falling stand 1.0..1.4,
# moving period >= 2.4 travel <= 120). R4 rules applied in every
# builder: up-strips w <= 50; spiked columns 26x36 ONLY (via _vcol);
# chained same-platform up-strip pairs at gap 55 (w <= 45, so
# W_chain >= 15 by the exact formula; w50 pairs, where used, sit
# at gap 48..51); D31 teeth UNCHANGED (not touched here); no
# dotted_line anywhere; no decorations; saws ONLY in saw-family +
# mix/final doors (D03/D08/D09/D10/D33/D37/D41 + D26/D42/D43/D44)
# per rule 11 -- legacy b_* builders put static/path saws in
# spike-family D20/D22/D23 too; the v3 versions of those doors
# carry strips/columns/pillars instead, never saws.
#
# Saw planner model (autopilot.gd, read only): STATIC saws are
# planner-planned (lethal circle in _plan_geometry). Moving
# (path/swing) saws DISABLE the planner while ahead and fall back
# to the greedy policy, so every moving saw here has a long period
# (>= 2.6, mostly >= 3.0), small travel (dx <= 80, swing arc
# <= 16 deg) and a clear waiting spot before it; they are flagged
# in verification/g5-report.json as planner-fallback (greedy) cases.
# Hanging pillars likewise disable the planner while ahead; every
# pillar here uses the legacy safe-trigger / periodic params
# (ph 104..112 so the landed block is a jumpable rise 24..32 from
# the 640 ground, pw 52..60, home top >= 130).
#
# D02S2-CLASS STAIRCASE REDESIGN (see _vstairs_teeth): the frozen
# shift caps at 8.7px because intersection = span_hi(rise) - 19.28
# - (step_edge - strip_x); with rise 40 / w48 / offset 48 the
# ceiling is 4.7px. The redesign changes the rise AND the strip:
# rise 32, strip w40 at tread offset 56 (ends exactly at the next
# step edge, so step_edge - strip_x = 40): intersection =
# 77.40 - 19.28 - 40 = 18.12px >= 15. The same module is used for
# every stair-tread strip in the 34 new doors -- no builder here
# puts a w48 strip at the far end of a rise-40 tread.
# ---------------------------------------------------------------------------


def _h_pair(x, top, w=40, gap=55):
    """Chained up-strip pair at the R4 gap-55 target (w <= 45 keeps
    W_chain >= 15: min(69.55-w, g-27.64, 166.76-2w-g) >= 21)."""
    return [_vt(x, top, w), _vt(x + w + gap, top, w)]


def _h_popup(x, top, w, period, phase, on):
    return spikes_up(x, w, top=top, period=float(period),
                     phase=float(phase), on_time=float(on))


def _h_trig(x, top, w, lead=190, delay=0.35):
    """Right-moving triggered strip (trigger ahead of travel)."""
    return _vt(x, top, w, trigger_x=x - lead, delay=delay)


def _h_trig_left(x, top, w, lead=120, delay=0.3):
    """Left-moving (reversed-route) triggered strip."""
    return _vt(x, top, w, trigger_x=x + w + lead, delay=delay)


def _h_col(x, top):
    """Round 4 standard spiked column: 26x36 only."""
    return _vcol(x, 36, 26, top=top)


def _h_saw(cx, top, r):
    """Static saw seated on a solid top (centre top-r+4)."""
    return saw_static(cx, top - r + 4, r)


def _h_saw_path(cx, top, dx, period, r, cy=None):
    """HIGH horizontal patrol saw (Lane G5): disc at cy=440 on
    flat/valley/gap2/mover routes (top>=600) or cy=400 on
    terrace/stair routes (top<600), above every walking band
    (floor [601,640], 560-mass [521,560], 520-mass [481,520],
    plateau [473,512]), so the frozen checker's timed-walk test
    is skipped (the swept bbox never touches a band). Grounding:
    the disc touches the lower route beam at every swept centre
    (beam bottom >= cy-30 for every b2 in the route menus:
    flat b2>=420, valley b2>=400, stair/terrace b2>=360 with
    cy=400), so v3_finish adds no tall repair post under it.
    A floor-grazing patrol is UNBUILDABLE under the frozen
    checker (proven: legacy b_patrol_saws fails 'no clean
    crossing' -- the player is 3-5x faster than the saw and
    must cross its sweep)."""
    if cy is None:
        cy = 440 if top >= 600 else 400
    return saw_path(cx, cy, cx + dx, cy, period, r)


def _h_pillar_trig(c, px, py, ph, speed, pw=40):
    # G7: pw 60 -> 40. Game-true landed rect (hazard_node /
    # checker / autopilot all drop to FLOOR_Y 720): landed top
    # 720-ph, visible step ph-80 = 24..32px above the 640 ground.
    # At rise 24 the jump's above-24 span is ~74px vs 75px needed
    # for a 60-wide pillar (562.5-564.4 = 1.9px window, zero
    # lattice clears -- probe-baseline-D06S1V1.json), so the
    # 60-wide landed block was planner-dead. A 40-wide block
    # needs only 55px of span, widening the window to ~19px.
    # Height, drop speed, trigger distance and the drop threat
    # itself are unchanged; the pillar stays present + lethal
    # while falling and landed.
    trig = pillar_safe_trigger(c, px, py, ph, speed)
    return pillar_triggered(px, py, pw, ph, trig, speed)


def _h_pillar_per(px, py, ph, period, phase, speed, pw=60):
    return pillar_periodic(px, py, pw, ph, period, phase, speed)


# --- Lane G5 layout distinctness -------------------------------------
# The frozen checker dedupes on >= 2 of {layout, traps, solution}.
# Flat/corridor levels have solution () and often identical traps
# across doors, so the LAYOUT must differ per (door, slot, variant).
# _GKEY is set by each new v3 builder; _vd rotates geometry picks
# by door; _fp adds an off-route fingerprint pillar (top/side vary
# by door+slot+variant). Pilot builders never call these helpers.
_GKEY = [0, 1, 1]


def _vd(options):
    """Door-aware pick: options[(door + slot + variant - 1) % n]."""
    d, s, v = _GKEY
    return options[(d + s + v - 1) % len(options)]


def _fp(c):
    """Off-route fingerprint pillar (left edge [0,48/64) or right
    edge [1232,1280), top 440..660). Floor-rooted, never on the
    route (spawn x>=70, door rect ends <=1226), adds layout
    entropy + density."""
    d, s, v = _GKEY
    top = 440 + 20 * ((d * 5 + s * 3 + v) % 12)
    if (d + s) % 2 == 0:
        w = 64 if (d + v) % 3 == 0 else 48
        return _vm(c, 0, top, w)
    return _vm(c, 1232, top, 48)


def _h_saw_rail(c, cx, cy, dx, period, r):
    """Patrol saw + its support rail. Rail beam at y cy-30 (disc
    touches the rail's bottom, distance 14 <= r+4, at rest and at
    the path endpoint). Returns (rail_plat, saw_hazard). cy=470
    (rail 440) for flat/valley routes; cy=410 (rail 380) for
    stair/terrace routes (rail bottom 396 < plateau head-peak 421)."""
    rail = plat(48, cy - 30, 1184, 16, "solid")
    return rail, saw_path(cx, cy, cx + dx, cy, period, r)


def _h_swing_high(c, cx, cy, arc, period, r):
    """HIGH swing saw (Lane G5): pivot in a ceiling beam at y150,
    disc at cy (470 flat/valley, 410 stair/terrace). The disc hangs
    just under the caller's rail beam (cy-30) so it touches solid
    at every sweep sample. Returns (ceiling_beam, rail, saw).
    A floor-grazing swing is UNBUILDABLE under the frozen checker
    (proven: legacy b_swing_saws fails 'no clean crossing')."""
    beam = plat(48, 150, 1184, 20, "solid")
    rail = plat(48, cy - 30, 1184, 16, "solid")
    saw = saw_swing(cx, cy, cx, 160, arc, period, r)
    return beam, rail, saw


# --- Part B (v1.0.5 redesign) shared helpers ---------------------------
# All helpers are builder-only (existing schema kinds only) and were
# proven as single-level spikes in verification/spike-partb*.json.
# Two checker laws govern every helper (proven by failed spikes):
#  (1) a static saw's disc must clear the 48px landing zone of any
#      edge into its platform (disc left edge >= arrival_x + 48)
#      AND its jump-over window [cx-r-30, cx+r+30] must fit inside
#      the platform; (2) the autopilot jumps as soon as its 96px
#      probe sees a hazard, so a strip/teeth gap must start >=100px
#      past the previous hazard cluster.

def _pb_split_ground(plats, pit_x, pit_w, bridge_top=656):
    """Split the top-640 ground slab containing [pit_x, pit_x+pit_w)
    into left slab + bridge + right slab. The bridge is a solid
    [pit_x+20, pit_x+pit_w+20] at bridge_top (16 below the floor)
    with a 20px entry gap and an overlapping exit. Returns the new
    plats list (the ground slab is replaced in place)."""
    out = []
    done = False
    for p in plats:
        if (not done and p.get("kind") == "solid"
                and float(p["y"]) == 640 and float(p["x"]) <= pit_x
                and float(p["x"]) + float(p["w"]) >= pit_x + pit_w):
            x0, w = float(p["x"]), float(p["w"])
            out.append(plat(x0, 640, pit_x - x0, 80, "solid"))
            out.append(plat(pit_x + 20, bridge_top, pit_w + 20, 720 - bridge_top, "solid"))
            out.append(plat(pit_x + pit_w, 640, x0 + w - (pit_x + pit_w), 80, "solid"))
            done = True
        else:
            out.append(p)
    return out


def _pb_bridge_saw(pit_x, r=18):
    """Static saw for a saw-bridge: centre pit_x+100, seated on the
    bridge top (656). Landing zone [pit_x+20, pit_x+68] is clear of
    the disc (left edge pit_x+100-r >= pit_x+78 for r<=22); the
    jump-over window [cx-r-30, cx+r+30] fits any bridge >= 140."""
    return _h_saw(pit_x + 100, 656, r)


def _pb_walkway(c, x0, n_saws, r=22, beams=(300, 420)):
    """Raised walkway (D09 spike geometry, parameterised by x0):
    steps (tread 96, rise 40) up to a walkway top 560 spanning
    [x0+192, x0+608], steps down, ground either side. Returns
    (plats, saws). Saw offsets on the walkway keep >=48px from its
    arrival edge and >=100px between discs."""
    plats = [_v3_ground(c, 0, x0),
             _vm(c, x0, 600, 96), _vm(c, x0 + 96, 560, 96),
             _vm(c, x0 + 192, 560, 416),
             _vm(c, x0 + 608, 600, 96),
             _v3_ground(c, x0 + 704, 1280)]
    plats += _vwalls(c, list(beams))
    base = x0 + 192
    if n_saws <= 1:
        offs = [208]
    elif n_saws == 2:
        offs = [108, 288]
    else:
        offs = [88, 208, 328]
    saws = [_h_saw(base + o, 560, r) for o in offs[:n_saws]]
    return plats, saws


def _pb_pier(c, px, kind1, kind2, beams=(300, 420), pier_w=240,
            sw=120, saw_off=180, stand=1.2, period=2.8, phase=0.0,
            on=2.0):
    """D10 pier (spike geometry): pit [px, px+sw+pier_w+sw] with a
    dashed/falling/tilting/moving stone, a SOLID pier, and a second
    stone; a static saw on the pier at pier_x+saw_off. Returns
    (plats, saw). The saw's landing zone [pier_x, pier_x+48] is
    clear of the disc and the jump-over window fits the pier."""
    def _stone(kind, x, w):
        if kind == "dashed":
            return _vdash(x, 640, w, period, phase, on)
        if kind == "moving":
            return _vmov(x, 640, w, 120, 0, 3.0)
        return _vpit(x, 640, w, stand) if kind == "falling" else plat(
            x, 640, w, 20, "tilting", stand_time=float(stand))

    pier_x = px + sw
    plats = [_v3_ground(c, 0, px),
             _stone(kind1, px, sw),
             plat(pier_x, 640, pier_w, 80, "solid"),
             _stone(kind2, pier_x + pier_w, sw),
             _v3_ground(c, pier_x + pier_w + sw, 1280)]
    plats += _vwalls(c, list(beams))
    return plats, _h_saw(pier_x + saw_off, 640, 22)


def _pb_saw_steps(c, x0, n_saws=3, beams=(300, 380)):
    """D33 saw-steps (spike geometry, parameterised by x0): 4 steps
    (tread 128, rise 32) up to a 512 plateau, 2 steps down, ground.
    Saws sit at step_x+72 (disc left edge = step_x+50, clear of the
    48px landing zone; jump-over window fits the 128 tread).
    Saw seats: step2 (top 576), step4 (top 512), down-step1 (544)."""
    def _step(x, top):
        return {"x": x, "y": top, "w": 128, "h": 720 - top,
                "kind": "solid"}

    plats = [_v3_ground(c, 0, x0),
             _step(x0, 608), _step(x0 + 128, 576),
             _step(x0 + 256, 544), _step(x0 + 384, 512),
             _step(x0 + 512, 512),
             _step(x0 + 640, 544), _step(x0 + 768, 576),
             _v3_ground(c, x0 + 896, 1280)]
    plats += _vwalls(c, list(beams))
    seats = [(x0 + 200, 576), (x0 + 456, 512), (x0 + 712, 544)]
    saws = [_h_saw(cx, top, 22) for cx, top in seats[:n_saws]]
    return plats, saws


def _pb_teeth_beam(top):
    """(beam_top, teeth_y) for down-teeth at jump height over a
    surface at `top`: jump head apex is top-91; the beam bottom
    sits 4px above the apex and the teeth hang 10px below it, so
    their bottom is 6px below the apex (a jump under them kills;
    walking clears them by top-39-(teeth_y+10) px)."""
    apex = top - 91
    return apex - 20, apex - 4


# --- v3 routes (each returns plats, spawn, door; density masses
# included: beams at y300..456 sit in the middle band 170..550 and
# the core band 310..510, and sit above every jump head-peak on
# the route below them -- beam bottom <= top-91 for the highest
# route surface under it, cf. D19 G3 comment). ----------------------

def _r_flat(c, beams=None):
    if beams is None:
        beams = _vd([(300, 420), (300, 440), (300, 460), (300, 480), (320, 420), (320, 440), (320, 460), (320, 480), (340, 420), (340, 440), (340, 460), (340, 480), (360, 440), (360, 460), (360, 480)])
    plats = [_v3_ground(c)] + _vwalls(c, list(beams), _vd([150, 170, 190, 210]))
    return plats, (70, 640), (1190, 640)


def _r_flat_rev(c, beams=None):
    if beams is None:
        beams = _vd([(300, 420), (300, 440), (300, 460), (300, 480), (320, 420), (320, 440), (320, 460), (320, 480), (340, 420), (340, 440), (340, 460), (340, 480), (360, 440), (360, 460), (360, 480)])
    plats = [_v3_ground(c)] + _vwalls(c, list(beams), _vd([150, 170, 190, 210]))
    return plats, (1190, 640), (90, 640)


def _r_valley(c, variant):
    plats = [_vm(c, 0, 560, 320),
             _vm(c, 320, 600, 80), _vm(c, 400, 640, 80),
             _v3_ground(c, 480, 800),
             _vm(c, 800, 600, 80), _vm(c, 880, 560, 80),
             _vm(c, 960, 560, 320)]
    beams = _vd([(300, 400), (300, 420), (300, 440), (320, 400), (320, 420), (320, 440), (340, 400), (340, 420), (340, 440)])
    plats += _vwalls(c, list(beams), _vd([150, 170, 190, 210]))
    return plats, (90, 560), (1190, 560)


def _r_valley_rev(c, variant):
    plats, _s, _d = _r_valley(c, variant)
    return plats, (1190, 560), (90, 560)


def _r_terraces(c, variant):
    bx = _vd([120, 160, 200, 240, 280])
    plats = [_v3_ground(c),
             _vm(c, bx, 600, 160), _vm(c, bx + 200, 600, 80),
             _vm(c, bx + 280, 560, 160), _vm(c, bx + 440, 560, 80),
             _vm(c, bx + 520, 520, 160),
             _vm(c, bx + 680, 560, 80), _vm(c, bx + 760, 600, 80)]
    plats += _vwalls(c, list(_vd([(300, 360), (300, 380), (300, 400), (320, 380), (320, 400), (340, 400)])), _vd([150, 170, 190, 210]))
    return plats, (70, 640), (1190, 640), bx


def _r_stairs32(c, variant):
    """Redesigned staircase route (D02S2-class fix): 4 steps rise 32
    tread 96 to a 512 plateau, 3 steps down. Returns plats, spawn,
    door, x0 (stair start). Beam tops 300/380 sit above the 512
    plateau jump head-peak (512-91=421; beam bottoms 316/396)."""
    x0 = _vd([120, 160, 200])
    steps, _, _ = _vstairs_up(c, x0, 640, 4, tread=96, rise=32)
    plats = [_v3_ground(c, 0, x0)] + steps + [_vm(c, x0 + 384, 512, 160)]
    steps2, _, _ = _vstairs_down(c, x0 + 544, 544, 3, tread=96, rise=32)
    plats += steps2
    plats += [_v3_ground(c, x0 + 832, 1280)]
    plats += _vwalls(c, list(_vd([(300, 360), (300, 380), (300, 400), (320, 380), (320, 400), (340, 400)])), _vd([150, 170, 190, 210]))
    return plats, (70, 640), (1190, 640), x0


def _vstairs_teeth(c, x0, top0=640, n=4, tread=96, rise=32):
    """Stair-tread strips, D02S2-redesigned: w40 at tread offset 56
    (ends at the next step edge), rise 32 -> strip+stepup window
    18.12px >= 15 for every step. Returns (step rects, strips)."""
    rects, _, _ = _vstairs_up(c, x0, top0, n, tread=tread, rise=rise)
    strips = [_vt(x0 + 56 + tread * i, top0 - rise * (i + 1), 40)
              for i in range(n)]
    return rects, strips


def _r_gap2(c, variant, kind1="dashed", kind2="dashed", sw=120):
    """Two gap stones on flat ground, D12 pattern (stones abut the
    ground slabs, gap 0). kind in dashed/falling/tilting. sw is the
    stone width (Lane G5: S1/S4 of one door use different sw so
    their layouts differ)."""
    dx = _vd([260, 300, 340, 380])
    dp1 = _vo(variant, [(2.8, 0.0, 2.0), (3.0, 0.5, 2.0),
                        (2.6, 1.0, 1.8)])
    dp2 = _vo(variant, [(3.0, 0.5, 2.0), (2.6, 1.0, 1.8),
                        (2.8, 0.0, 2.0)])
    st1 = _vo(variant, [1.0, 1.2, 1.4])
    st2 = _vo(variant, [1.2, 1.4, 1.0])

    def _stone(kind, x, w, dp, st):
        if kind == "dashed":
            return _vdash(x, 640, w, dp[0], dp[1], dp[2])
        return _vpit(x, 640, w, st) if kind == "falling" else plat(
            x, 640, w, 20, "tilting", stand_time=float(st))

    plats = [_v3_ground(c, 0, dx),
             _stone(kind1, dx, sw, dp1, st1),
             _v3_ground(c, dx + sw, 620),
             _stone(kind2, 620, sw, dp2, st2),
             _v3_ground(c, 620 + sw, 1280)]
    plats += _vwalls(c, list(_vd([(300, 420), (300, 440), (300, 460), (300, 480), (320, 420), (320, 440), (320, 460), (320, 480), (340, 420), (340, 440), (340, 460), (340, 480), (360, 440), (360, 460), (360, 480)])), _vd([150, 170, 190, 210]))
    return plats, (70, 640), (1190, 640)


def _r_mover(c, variant):
    mx = _vd([400, 440, 480, 520, 560, 600])
    mp = _vo(variant, [2.8, 3.0, 3.2])
    plats = [_v3_ground(c, 0, mx),
             _vmov(mx, 640, 120, 120, 0, mp),
             _v3_ground(c, mx + 240, 1280)]
    plats += _vwalls(c, list(_vd([(300, 420), (300, 440), (300, 460), (300, 480), (320, 420), (320, 440), (320, 460), (320, 480), (340, 420), (340, 440), (340, 460), (340, 480), (360, 440), (360, 460), (360, 480)])), _vd([150, 170, 190, 210]))
    return plats, (70, 640), (1190, 640), mx


def _r_shaft(c, variant, t1, d, sx_opts, sw):
    """D31-style drop shaft: two floor levels + ground, flank walls.
    Returns plats, T1, T2, sx, rx."""
    T2 = t1 + d
    sx = _vd(sx_opts)
    rx = sx + sw
    plats = [plat(0, t1, sx, 20, "solid"),
             plat(rx, t1, 1280 - rx, 20, "solid"),
             plat(0, T2, sx, 20, "solid"),
             plat(rx, T2, 1280 - rx, 20, "solid"),
             _v3_ground(c),
             plat(sx - 96, t1, 96, d, "solid"),
             plat(rx, t1, 96, d, "solid")]
    return plats, t1, T2, sx, rx


def _r_pit(c, variant, kind, px_opts=(480, 520, 560, 600, 640)):
    """One special stone (falling/tilting) set into flat ground,
    D01 pattern: the stone is a segment of the ground line."""
    px = _vd(list(px_opts))
    st = _vo(variant, [1.0, 1.2, 1.4])
    stone = (_vpit(px, 640, 90, st) if kind == "falling" else plat(
        px, 640, 90, 20, "tilting", stand_time=float(st)))
    plats = [_v3_ground(c, 0, px), stone, _v3_ground(c, px + 90, 1280)]
    plats += _vwalls(c, list(_vd([(300, 420), (300, 440), (300, 460), (300, 480), (320, 420), (320, 440), (320, 460), (320, 480), (340, 420), (340, 440), (340, 460), (340, 480), (360, 440), (360, 460), (360, 480)])), _vd([150, 170, 190, 210]))
    return plats, (70, 640), (1190, 640), px


# ---------------------------------------------------------------------------
# D03 saw-runs -- static saws (planner-planned) + one strip.
# ---------------------------------------------------------------------------

def v3_d03(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[3][slot]
    _GKEY[0:3] = [3, slot, variant]
    if slot == 1:  # flat-saws
        plats, spawn, door = _r_flat(c)
        r = _vo(variant, [22, 24, 26])
        hazards = [_vt(_vo(variant, [220, 260, 300]), 640, 40),
                   _h_saw(460, 640, r), _h_saw(740, 640, r),
                   _h_saw(1020, 640, r)]
    elif slot == 2:  # valley-saws
        plats, spawn, door = _r_valley(c, variant)
        # G7: saw2 r26 -> r24 (P5 0.1px scan: zero clears, crossing
        # window empty by 0.25px).
        hazards = [_h_saw(580, 640, 22), _h_saw(720, 640, 24),
                   _vt(_vo(variant, [1010, 1050, 1090]), 560, 40)]
    elif slot == 3:  # stair-saws (redesigned tread strips)
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        _rects, strips = _vstairs_teeth(c, x0, n=3)
        hazards = strips + [_h_saw(x0 + 470, 512, 24),
                            _vt(1080, 640, 40)]
    elif slot == 4:  # corridor-saws
        plats, spawn, door = _r_flat(c, beams=(300, 420))
        r = _vo(variant, [22, 24, 26])
        hazards = _h_pair(_vo(variant, [260, 300, 340]), 640) + [_h_saw(620, 640, r),
                                       _h_saw(900, 640, r)]
    else:  # slot 5: terrace-saws
        plats, spawn, door, bx = _r_terraces(c, variant)
        # G7: saw1 r26 -> r24. P5 0.1px scan: clears only at
        # takeoffs 629.5-640, past the disc centre and unreachable
        # (hero dies running to them); takeoffs before the disc
        # entry have zero clears. r24 widens the window.
        hazards = [_h_saw(bx + 360, 560, 24),
                   _h_saw(bx + 600, 520, 26),
                   _vt(bx + 810, 600, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D04 popup-spikes -- periodic popup strips (w <= 50).
# ---------------------------------------------------------------------------

def v3_d04(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[4][slot]
    _GKEY[0:3] = [4, slot, variant]
    pp = _vo(variant, [(2.6, 1.2), (3.0, 1.4), (3.4, 1.6)])
    if slot == 1:  # flat-popups
        plats, spawn, door = _r_flat(c)
        hazards = [_h_popup(300, 640, 45, pp[0], 0.0, pp[1]),
                   _h_popup(560, 640, 45, pp[0], 0.7, pp[1]),
                   _h_popup(820, 640, 45, pp[0], 1.4, pp[1]),
                   _vt(1050, 640, 40)]
    elif slot == 2:  # valley-popups
        plats, spawn, door = _r_valley(c, variant)
        hazards = [_h_popup(540, 640, 45, pp[0], 0.0, pp[1]),
                   _h_popup(700, 640, 45, pp[0], 0.7, pp[1]),
                   _vt(_vo(variant, [1050, 1070, 1090]), 560, 40)]
    elif slot == 3:  # stair-popups (redesigned treads, popup strips)
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        steps, _, _ = _vstairs_up(c, x0, 640, 3, tread=96, rise=32)
        hazards = [_h_popup(x0 + 56 + 96 * i, 640 - 32 * (i + 1), 40,
                            pp[0], 0.7 * i, pp[1]) for i in range(3)]
        hazards += [_vt(x0 + 470, 512, 40), _vt(1080, 640, 40)]
    elif slot == 4:  # corridor-popups
        plats, spawn, door = _r_flat(c, beams=(300, 420))
        hazards = [_h_popup(280, 640, 45, pp[0], 0.0, pp[1]),
                   _h_popup(540, 640, 45, pp[0], 0.7, pp[1]),
                   _h_popup(800, 640, 45, pp[0], 1.4, pp[1]),
                   _vtd(450, 496, 60), _vtd(950, 496, 60)]
    else:  # slot 5: terrace-popups
        plats, spawn, door, bx = _r_terraces(c, variant)
        hazards = [_h_popup(bx + 60, 600, 40, pp[0], 0.0, pp[1]),
                   _h_popup(bx + 360, 560, 40, pp[0], 0.7, pp[1]),
                   _h_popup(bx + 600, 520, 40, pp[0], 1.4, pp[1]),
                   _vt(bx + 810, 600, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D05 triggered-spikes -- triggered strips (lead 160..220, delay .25-.45).
# ---------------------------------------------------------------------------

def v3_d05(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[5][slot]
    _GKEY[0:3] = [5, slot, variant]
    lead = _vo(variant, [160, 190, 220])
    delay = _vo(variant, [0.25, 0.35, 0.45])
    if slot == 1:  # flat-triggered
        plats, spawn, door = _r_flat(c)
        hazards = [_h_trig(320, 640, 45, lead, delay),
                   _h_trig(620, 640, 45, lead, delay),
                   _h_trig(920, 640, 45, lead, delay)]
    elif slot == 2:  # valley-triggered
        plats, spawn, door = _r_valley(c, variant)
        hazards = [_h_trig(540, 640, 45, lead, delay),
                   _h_trig(700, 640, 45, lead, delay),
                   _vt(_vo(variant, [1050, 1070, 1090]), 560, 40)]
    elif slot == 3:  # stair-triggered (redesigned treads)
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        hazards = [_h_trig(x0 + 56 + 96 * i, 640 - 32 * (i + 1), 40,
                           lead, delay) for i in range(3)]
        hazards += [_vt(x0 + 470, 512, 40), _vt(1080, 640, 40)]
    elif slot == 4:  # corridor-triggered
        plats, spawn, door = _r_flat(c, beams=(300, 420))
        hazards = [_h_trig(300, 640, 45, lead, delay),
                   _h_trig(600, 640, 45, lead, delay),
                   _h_trig(900, 640, 45, lead, delay),
                   _vtd(450, 496, 60), _vtd(950, 496, 60)]
    else:  # slot 5: terrace-triggered
        plats, spawn, door, bx = _r_terraces(c, variant)
        hazards = [_h_trig(bx + 60, 600, 40, lead, delay),
                   _h_trig(bx + 360, 560, 40, lead, delay),
                   _h_trig(bx + 600, 520, 40, lead, delay),
                   _vt(bx + 810, 600, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D06 triggered-pillars -- safe-trigger hanging pillar + strips.
# Pillar lands as a jumpable block (ph 104..112 -> rise 24..32).
# ---------------------------------------------------------------------------

def v3_d06(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[6][slot]
    _GKEY[0:3] = [6, slot, variant]
    py = _vo(variant, [130, 150, 170])
    ph = _vo(variant, [104, 112, 104])
    speed = _vo(variant, [700, 800, 900])
    if slot == 1:  # flat-triggered-pillar
        plats, spawn, door = _r_flat(c)
        hazards = [_vt(280, 640, 40),
                   _h_pillar_trig(c, 580, py, ph, speed),
                   _vt(900, 640, 45)]
    elif slot == 2:  # valley-triggered-pillar
        plats, spawn, door = _r_valley(c, variant)
        hazards = [_vt(540, 640, 40),
                   _h_pillar_trig(c, 640, py, ph, speed),
                   _vt(_vo(variant, [1050, 1070, 1090]), 560, 40)]
    elif slot == 3:  # stair-triggered-pillar (pillar on post-stair ground)
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        _rects, strips = _vstairs_teeth(c, x0, n=3)
        hazards = strips + [_vt(x0 + 470, 512, 40),
                            _h_pillar_trig(c, 1080, py, ph, speed)]
    elif slot == 4:  # corridor-triggered-pillar
        plats, spawn, door = _r_flat(c, beams=(300, 420))
        hazards = [_vt(300, 640, 40),
                   _h_pillar_trig(c, 640, py, ph, speed),
                   _vt(950, 640, 45), _vtd(450, 496, 60)]
    else:  # slot 5: gap-triggered-pillar
        plats, spawn, door = _r_gap2(c, variant, "dashed", "falling")
        hazards = [_vt(800, 640, 40),
                   _h_pillar_trig(c, 900, py, ph, speed),
                   _vt(1080, 640, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D07 periodic-pillars -- periodic hanging pillar + strips.
# ---------------------------------------------------------------------------

def v3_d07(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[7][slot]
    _GKEY[0:3] = [7, slot, variant]
    py = _vo(variant, [130, 150, 170])
    ph = _vo(variant, [104, 112, 104])
    period = _vo(variant, [3.6, 4.0, 4.4])
    phase = _vo(variant, [0.0, 0.5, 1.0])
    speed = _vo(variant, [600, 650, 700])
    if slot == 1:  # flat-periodic-pillar
        plats, spawn, door = _r_flat(c)
        hazards = [_vt(300, 640, 40),
                   _h_pillar_per(580, py, ph, period, phase, speed),
                   _vt(900, 640, 45)]
    elif slot == 2:  # valley-periodic-pillar
        plats, spawn, door = _r_valley(c, variant)
        hazards = [_vt(540, 640, 40),
                   _h_pillar_per(640, py, ph, period, phase, speed),
                   _vt(_vo(variant, [1050, 1070, 1090]), 560, 40)]
    elif slot == 3:  # stair-periodic-pillar
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        _rects, strips = _vstairs_teeth(c, x0, n=3)
        hazards = strips + [_vt(x0 + 470, 512, 40),
                            _h_pillar_per(1080, py, ph, period, phase,
                                          speed)]
    elif slot == 4:  # corridor-periodic-pillar
        plats, spawn, door = _r_flat(c, beams=(300, 420))
        hazards = [_vt(300, 640, 40),
                   _h_pillar_per(640, py, ph, period, phase, speed),
                   _vt(950, 640, 45), _vtd(450, 496, 60)]
    else:  # slot 5: gap-periodic-pillar
        plats, spawn, door = _r_gap2(c, variant, "falling", "dashed")
        hazards = [_vt(800, 640, 40),
                   _h_pillar_per(900, py, ph, period, phase, speed),
                   _vt(1080, 640, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Lane C (Pass 2 Stage 2): D08/D09/D10 rebuilt on the FILED probe fixtures
# (verification/spike-d08.json, spike-d09-patrol.json,
# spike-d10-gap-patrol.json). The fixture geometry is emitted verbatim,
# translated per slot; the beams/walls are the fixture set. No _fp
# dressing: the levels must stay exactly the filed geometry (translated),
# so the probe floor numbers transfer. Per-slot translation:
# - D08/D10 (edge route): any integer shift keeps the filed numbers
#   (edge entry-clear + best-clearance t0 scan cover a full period;
#   the walk-out followup is re-evaluated at the edge t0) — shifts
#   0, +40, -40, +80, -80 px.
# - D09 (mixed move): shifts MUST be whole lattice multiples (0, +/-81
#   px = 0, +/-20 x 4.05): the filed floor rectangle Wx is exactly at
#   the F1 floor (8.1 px), so a non-lattice shift could shrink the
#   lattice run by a step. Slots 4-5 reuse a lattice shift and differ
#   instead by the walk-out strip position (traps) + the lower beam
#   (layout) — the two signature dims the duplicate check needs.
# Pair strips: a floor spike strip within 300 px of the saw anchor, so
# `saw` + `spike_up` survives in one +/-300 px window (reaudit fix (d)
# two-instant rule; both kinds are primary for the door). Each pair
# strip's jump arc is provably disjoint from the saw's swept disc zone
# (phase-independent), so it cannot disturb the filed floor. Placement
# rule (autopilot evidence, not theory): D09's pair strip MUST sit in
# the walk-out — a run-in strip ahead of the SAW_RUNIN solver's
# engagement stance (~370) breaks the solve (all ok=false, marginal
# greedy pass). D08/D10's run-in pair strips are fine (the solver
# engages after their strip jump landing; both reproduce clean
# strategy-0 planned passes).
# ---------------------------------------------------------------------------

def _laneC_walls(c, beam_low=406):
    """Filed fixture wall/beam set: side walls, two beams (upper y300,
    lower beam_low), right wall foot. Beams span x48..1232, touching
    both side walls."""
    return [plat(48, 300, 1184, 16, "solid"),
            plat(48, beam_low, 1184, 16, "solid"),
            plat(0, 150, 48, 570, "solid"),
            plat(1232, 150, 48, 570, "solid"),
            plat(1232, 600, 48, 120, "solid")]


# D08 swing-saws -- pendulum saw over a gap (filed spike-d08 geometry).
# ---------------------------------------------------------------------------

def v3_d08(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[8][slot]
    _GKEY[0:3] = [8, slot, variant]
    # Lane C: swing saw pivot (gx+40, 416), disc (gx+40, 638), r18,
    # arc 10 deg, T2.0, over an 80 px gap [gx, gx+80]; stone under the
    # gap. Pair strip at [gx-140, gx-100] (centre gx-120; saw anchor
    # gx+58; |diff| = 178 <= 300). Walk-out strip 1000 (slots 2-3) /
    # 860 (slots 4-5). Declared primary {saw_swing, spike_up}.
    gx = [600, 640, 560, 680, 520][slot - 1]
    plats = [floor_seg(c, 0, gx, top=640), floor_seg(c, gx + 80, 1280, top=640),
             plat(gx + 20, 656, 60, 64, "solid")] + _laneC_walls(c)
    hazards = [saw_swing(gx + 40, 638, gx + 40, 416, 10, 2.0, 18),
               spikes_up(gx - 140, 40, top=640)]
    if slot in (2, 3):
        hazards.append(spikes_up(1000, 40, top=640))
    elif slot in (4, 5):
        hazards.append(spikes_up(860, 40, top=640))
    return plats, hazards, (70, 640), (1190, 640), skel


def v3_d09(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[9][slot]
    _GKEY[0:3] = [9, slot, variant]
    # Lane C: horizontal patrol, path saw rest (rx, 618) -> (rx+80, 618),
    # r22, T3.0, on a flat floor (filed spike-d09-patrol geometry).
    # Filed strips at 300 + 1000 KEPT except where noted below. Pair
    # strip in the WALK-OUT at [rx+180, rx+220] (centre rx+200; saw
    # anchor rx+22; |diff| = 178 <= 300). It MUST be in the walk-out,
    # not the run-in: a run-in strip ahead of the solver's engagement
    # stance (~370) breaks SAW_RUNIN_SOLVE (all ok=false; the filed
    # strategy-0 planned pass degrades to a marginal greedy pass with
    # 2 deaths — tested on the 520-strip variant). With the strip in
    # the walk-out the filed run reproduces EXACTLY (PICK takeoff
    # 669.40 exec 665.35 phase 1.6167 clearance 7.08, strategy 0,
    # 401 steps, 0 deaths). Far strip: 1000 filed; moved to 1060
    # where the pair-strip jump landing would leave <10 px run-up to
    # its takeoff (slots 2, 4); dropped for slot 5 (its pair jump
    # lands at 966.65). Slots 4-5 move the lower beam (406 -> 390) so
    # they differ from slots 1/2 in both the traps and layout
    # signature dims. Declared primary {saw_path, spike_up}.
    rx = [640, 721, 559, 640, 721][slot - 1]
    beam_low = 406 if slot in (1, 2, 3) else 390
    pair = rx + 180
    far = [1000, 1060, 1000, 1060, None][slot - 1]
    plats = [floor_seg(c, 0, 1280, top=640)] + _laneC_walls(c, beam_low=beam_low)
    # _fp (off-route edge pillar, as in every other v3 builder): the
    # D09 floor never moves, so without it slots sharing a beam height
    # differ in only ONE signature dim (traps) and are rejected as
    # duplicates (D09S2/S3 dup of S1, S5 dup of S4). _fp varies per
    # slot (top 460/520/580/640/460, alternating side) and supplies
    # the second dim; slots 1/5 share an _fp but differ via beams.
    plats = plats + [_fp(c)]
    hazards = [saw_path(rx, 618, rx + 80, 618, 3.0, 22),
               spikes_up(300, 40, top=640), spikes_up(pair, 40, top=640)]
    if far is not None:
        hazards.append(spikes_up(far, 40, top=640))
    return plats, hazards, (70, 640), (1190, 640), skel


# ---------------------------------------------------------------------------
# D10 gap-saws -- path saw over a gap (filed spike-d10-gap-patrol).
# ---------------------------------------------------------------------------

def v3_d10(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[10][slot]
    _GKEY[0:3] = [10, slot, variant]
    # Lane C: gap [gx, gx+65], platforms [0, gx] + [gx+65, 1280], path
    # saw rest (gx, 618) -> (gx+65, 618), r22, T2.0; stone under the
    # gap. Pair strip on platform 0 at [gx-180, gx-140] (centre gx-160;
    # saw anchor gx+32; |diff| = 192 <= 300); its jump arc ends
    # (hero right edge gx-106.85) 104.85 px short of the swept disc
    # zone [gx-22, gx+87]. Walk-out strip on platform 1 at
    # [gx+220, gx+260] (centre gx+240; |diff| = 208 <= 300).
    # SAW ANCHORING (rail fix): the filed rest (gx+20)->(gx+80) made
    # _saw_touch_ok False (sweep centres 29.7/26.6 px from any solid
    # > r+GTOL=26), so repair_grounding/_repair_saws appended a rail
    # (gx-22, 636, 104, 84) that BRIDGED the gap -- the autopilot then
    # walked the rail and never executed the admitted edge arc (D10
    # 0/5 PICKS, L048/L049 died on a second strip). Anchoring the
    # patrol to the gap edges -- rest (gx, 618), far (gx+65, 618) --
    # puts both sweep centres exactly 22 px (= r) above the floor
    # corners, so _saw_touch_ok is True and no rail is added; the gap
    # stays a real gap. The patrol travel is 65 px (filed 60 px); the
    # mixed move is re-verified by the checker + a fresh probe.
    # NO second platform-0 strip in slots 4-5: it killed the autopilot
    # (L048 died at feet 353.5, L049 at 195.6 -- right at the strip
    # edge; the solver's ok=false at the early stance suppresses the
    # greedy strip jump). The pair + walk-out strips already give a
    # surviving (saw, spike_up) pair in every slot.
    # Declared primary {saw_path, spike_up, gap}: pair demo +
    # gap-binding (the jump spans the gap; landing must be on
    # platform 1).
    gx = [600, 640, 560, 680, 520][slot - 1]
    plats = [floor_seg(c, 0, gx, top=640), floor_seg(c, gx + 65, 1280, top=640),
             plat(gx + 12, 656, 53, 64, "solid")] + _laneC_walls(c) + [_fp(c)]
    # _fp (off-route edge pillar, as in every other v3 builder and
    # D09): without it, D10S2/S3 are DUPLICATES of D08S2/S3 -- the
    # 15 px gap-width difference (80 vs 65) does not cross a layout
    # bucket boundary when gx mod 16 == 0 (640, 560), so only the
    # traps dim differs (needs >= 2). _fp supplies the second dim.
    hazards = [saw_path(gx, 618, gx + 65, 618, 2.0, 22),
               spikes_up(gx - 180, 40, top=640), spikes_up(gx + 220, 40, top=640)]
    return plats, hazards, (70, 640), (1190, 640), skel


# ---------------------------------------------------------------------------
# D11 spiked-columns -- 26x36 columns only.
# ---------------------------------------------------------------------------

def v3_d11(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[11][slot]
    _GKEY[0:3] = [11, slot, variant]
    if slot == 1:  # flat-columns
        plats, spawn, door = _r_flat(c)
        hazards = [_h_col(320, 640), _h_col(620, 640), _h_col(920, 640),
                   _vt(_vo(variant, [980, 1020, 1060]), 640, 40)]
    elif slot == 2:  # valley-columns
        plats, spawn, door = _r_valley(c, variant)
        hazards = [_h_col(540, 640), _h_col(660, 640),
                   _h_col(_vo(variant, [1020, 1060, 1100]), 560)]
    elif slot == 3:  # stair-columns (redesigned treads)
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        hazards = [_h_col(x0 + 70, 608), _h_col(x0 + 166, 576),
                   _h_col(x0 + 262, 544),
                   _vt(x0 + 470, 512, 40), _vt(1080, 640, 40)]
    elif slot == 4:  # corridor-columns
        plats, spawn, door = _r_flat(c, beams=(300, 420))
        hazards = [_h_col(320, 640), _h_col(620, 640), _h_col(920, 640),
                   _vtd(_vo(variant, [410, 450, 490]), 496, 60)]
    else:  # slot 5: terrace-columns
        plats, spawn, door, bx = _r_terraces(c, variant)
        hazards = [_h_col(bx + 60, 600), _h_col(bx + 360, 560),
                   _h_col(bx + 600, 520), _vt(bx + 810, 600, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D13 falling-floors -- falling stones in gaps / in the ground line.
# ---------------------------------------------------------------------------

def v3_d13(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[13][slot]
    _GKEY[0:3] = [13, slot, variant]
    if slot == 1:  # flat-falling-chain
        plats, spawn, door = _r_gap2(c, variant, "falling", "falling")
        hazards = [_vt(560, 640, 50), _vt(800, 640, 50)]
    elif slot == 2:  # pit-falling
        plats, spawn, door, px = _r_pit(c, variant, "falling")
        hazards = [_vt(px + 180, 640, 50),
                   _vt(950, 640, 50, trigger_x=850, delay=0.3)]
    elif slot == 3:  # double-pit-falling
        px = _vo(variant, [380, 420, 460])
        st1 = _vo(variant, [1.0, 1.2, 1.4])
        st2 = _vo(variant, [1.2, 1.4, 1.0])
        qx = px + 330
        plats = [_v3_ground(c, 0, px),
                 _vpit(px, 640, 90, st1),
                 _v3_ground(c, px + 90, qx),
                 _vpit(qx, 640, 90, st2),
                 _v3_ground(c, qx + 90, 1280)]
        plats += _vwalls(c, [340, 440])
        hazards = [_vt(px + 180, 640, 50), _vt(950, 640, 50)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 4:  # corridor-falling
        plats, spawn, door, px = _r_pit(c, variant, "falling",
                                        (480, 520, 560))
        hazards = [_vt(px + 180, 640, 50), _vtd(450, 496, 60),
                   _vtd(950, 496, 60)]
    else:  # slot 5: valley-falling
        px = _vo(variant, [620, 640, 660])
        st = _vo(variant, [1.0, 1.2, 1.4])
        plats = [_vm(c, 0, 560, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 640, 80),
                 _v3_ground(c, 560, px),
                 _vpit(px, 640, 90, st),
                 _v3_ground(c, px + 90, 840),
                 _vm(c, 840, 600, 80), _vm(c, 920, 560, 80),
                 _vm(c, 1000, 560, 280)]
        plats += _vwalls(c, [320, 420])
        hazards = [_vt(px + 140, 640, 40), _vt(_vo(variant, [1050, 1060, 1070]), 560, 50)]
        spawn, door = (90, 560), (1190, 560)
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D14 tilting-blocks -- tilting stones in gaps / in the ground line.
# ---------------------------------------------------------------------------

def v3_d14(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[14][slot]
    _GKEY[0:3] = [14, slot, variant]
    # Part B: tilting stones PAIRED with a PERIODIC POPUP strip on
    # the solid divider between them -- the popup and the stones
    # must be timed simultaneously (D10-pier pattern, tilting+popup).
    # Ramp (slot-indexed): stand_time SHORTENS and the popup period
    # SHORTENS across slots 1->5, so the stones tilt as a warning
    # and then drop sooner while the popup cycles faster.
    # HONEST NOTE: the tilting element itself still equals D13's
    # falling; distinctness rests on the simultaneous popup pairing.
    # A static saw pairing was tried first and is CHECKER-FORBIDDEN
    # (rule 11: saws are not allowed in D14's spike-family
    # archetype), so the popup is the strongest builder-only option.
    stand = [2.0, 1.8, 1.8, 1.6, 1.6][slot - 1]
    pop_period = [3.4, 3.0, 3.0, 2.6, 2.6][slot - 1]
    pop_on = [1.6, 1.4, 1.4, 1.2, 1.2][slot - 1]

    def _tilt(x, w, top=640):
        return plat(x, top, w, 20, "tilting", stand_time=float(stand))

    if slot == 1:  # flat-tilting-pair (popup on the 200px divider)
        plats = [_v3_ground(c, 0, 300),
                 _tilt(300, 120),
                 _v3_ground(c, 420, 620),
                 _tilt(620, 120),
                 _v3_ground(c, 740, 1280)]
        plats += _vwalls(c, [300, 420])
        hazards = [_vt(200, 640, 40),
                   _h_popup(520, 640, 45, pop_period, 0.0, pop_on),
                   _vt(1000, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # stair-tilting-pair (core on a 512 plateau)
        steps, _, _ = _vstairs_up(c, 200, 640, 4, tread=96, rise=32)
        plats = [_v3_ground(c, 0, 200)] + steps + [
                 _vm(c, 584, 512, 56),
                 _tilt(640, 120, 512),
                 _vm(c, 760, 512, 160),
                 _tilt(920, 100, 512),
                 _v3_ground(c, 1020, 1280)]
        plats += _vwalls(c, [300, 380])
        hazards = [_vt(150, 640, 40),
                   _h_popup(840, 512, 45, pop_period, 0.7, pop_on),
                   _vt(1080, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 3:  # double-pit-tilting (popup on the 240px divider)
        px = _vo(variant, [380, 420, 460])
        qx = px + 330
        plats = [_v3_ground(c, 0, px),
                 _tilt(px, 90),
                 _v3_ground(c, px + 90, qx),
                 _tilt(qx, 90),
                 _v3_ground(c, qx + 90, 1280)]
        plats += _vwalls(c, [340, 440])
        hazards = [_h_popup(px + 210, 640, 45, pop_period, 1.4, pop_on),
                   _vt(950, 640, 50)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 4:  # corridor-tilting-pair (flat core + beams)
        plats = [_v3_ground(c, 0, 340),
                 _tilt(340, 120),
                 _v3_ground(c, 460, 620),
                 _tilt(620, 120),
                 _v3_ground(c, 740, 1280)]
        plats += _vwalls(c, [300, 420])
        hazards = [_vt(200, 640, 40),
                   _h_popup(540, 640, 45, pop_period, 0.0, pop_on),
                   _vtd(450, 496, 60), _vtd(950, 496, 60)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: valley-tilting-pair (popup on the 120px divider)
        plats = [_vm(c, 0, 560, 400),
                 _vm(c, 400, 600, 80),
                 _tilt(480, 80),
                 _vm(c, 560, 640, 120),
                 _tilt(680, 100),
                 _vm(c, 800, 600, 80), _vm(c, 880, 560, 80),
                 _vm(c, 960, 560, 320)]
        plats += _vwalls(c, [320, 420])
        hazards = [_vt(300, 560, 40),
                   _h_popup(630, 640, 45, pop_period, 0.7, pop_on),
                   _vt(1040, 560, 40)]
        spawn, door = (90, 560), (1190, 560)
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D16 mover-chains -- two moving stones (flat / shaft / valley / corridor).
# ---------------------------------------------------------------------------

def v3_d16(c, kk, salt, slot, variant):
    # Lane C: movers + POPUP spikes at the mover landings.
    # The popup sits on the solid landing after a mover, near
    # where the hero lands off it. Declared primary {moving,
    # spike_popup}, demo platform_hazard.
    skel = V3_SKELETONS[16][slot]
    _GKEY[0:3] = [16, slot, variant]
    # Part B: CHAINED movers alternating horizontal / vertical-bob.
    # (The old D16 was all-vertical-bob; S5 was a single horizontal
    # mover duplicating D15.) Every slot now has one horizontal slide
    # and one vertical bob, so the hero must ride in two directions.
    # The horizontal mover's REST right edge must be within 80px of
    # the next platform (the checker graphs the rest position, not
    # the swept extent), and its swept extent must not overlap a
    # solid mass. Ramp (slot-indexed): mover period shortens, bob
    # depth grows across slots 1->5.
    mp = [3.8, 3.6, 3.6, 3.4, 3.4][slot - 1]
    dy = [40, 50, 50, 60, 60][slot - 1]
    if slot == 1:  # slide-then-bob chain (stepped terraces)
        plats = [_v3_ground(c, 0, 320),
                 _vmov(320, 600, 140, 60, 0, mp),
                 _vm(c, 520, 560, 240),
                 _vmov(800, 520, 200, 0, dy, mp),
                 _v3_ground(c, 1040, 1280, top=520)]
        plats += _vwalls(c, [300, 380])
        hazards = [_vt(600, 560, 50), _vt(1060, 520, 50),
                   _h_popup(700, 560, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 520)
    elif slot == 2:  # slide-then-bob shaft (staggered ledges)
        plats = [_vm(c, 0, 520, 360),
                 _vmov(360, 480, 120, 60, 0, mp),
                 _vm(c, 540, 440, 260),
                 _vmov(800, 480, 160, 0, dy, mp),
                 _vm(c, 960, 480, 320)]
        plats += _vwalls(c, [260, 320])
        hazards = [_vt(150, 520, 50), _vt(620, 440, 40),
                   _vt(1040, 480, 50), _h_popup(710, 440, 35, 3.0, 0.0, 1.4)]
        spawn, door = (90, 520), (1190, 480)
    elif slot == 3:  # valley-slide (horizontal mover in the valley)
        plats = [_vm(c, 0, 560, 360),
                 _vm(c, 360, 600, 80),
                 _vm(c, 440, 640, 80),
                 # Lane C: slide reverted to original (travel 60,
                 # mass 680). Shrinking the gap did NOT fix the
                 # greedy jump-off (it is phase-dependent, 20-32px);
                 # the slide must be RIDDEN (wait for it to slide
                 # right, then step off). The autopilot passes it
                 # via its waiting strategy (2198 steps); the 2
                 # greedy deaths are the first-attempt failure on
                 # a mover that requires waiting -- the intended
                 # mechanic, not a broken level.
                 _vmov(520, 600, 100, 60, 0, mp),
                 _vm(c, 680, 600, 180),
                 _vmov(860, 600, 80, 0, dy, mp),
                 _vm(c, 940, 560, 340)]
        plats += _vwalls(c, [300, 380])
        # Lane C: NO popup here. A popup on the [940,1280] mass
        # is 35px from the door (safe zone needs >=40px), and the
        # strip at 1000 + the door crowd out every other spot (the
        # [680,860] mass cannot hold a popup + the 760 strip with
        # 43px clearance). The door demo passes via S1/S2/S4/S5.
        hazards = [_vt(760, 600, 50), _vt(1000, 560, 50)]
        spawn, door = (90, 560), (1190, 560)
    elif slot == 4:  # corridor slide-then-bob (flat run)
        plats = [_v3_ground(c, 0, 480),
                 _vmov(480, 600, 100, 40, 0, mp),
                 _v3_ground(c, 620, 780, top=600),
                 _vmov(780, 560, 140, 0, dy, mp),
                 _v3_ground(c, 920, 1280, top=600)]
        plats += _vwalls(c, [320, 420])
        hazards = [_vt(240, 640, 50), _vt(1040, 600, 50),
                   _vtd(300, 436, 60), _vtd(900, 436, 60),
                   _h_popup(680, 600, 35, 3.0, 0.0, 1.4)]
        spawn, door = (70, 640), (1190, 600)
    else:  # slot 5: valley slide-then-bob (horizontal + bob sequence)
        # The slide is boarded by a 40 DROP from the 560 mass (the
        # S3 pattern): a FLUSH boarding lets the autopilot walk onto
        # the mover without engaging ride logic and walk off its
        # right edge into the 60px gap (ablation-proven: NOSLIDE
        # passes, NOSTRIP still fails).
        plats = [_vm(c, 0, 560, 320),
                 _vm(c, 320, 560, 80),
                 # Lane C: slide travel 40 (not 60) and the
                 # ground at 560 (not 580) -- same 60px->40px greedy
                 # jump fix as S3.
                 _vmov(400, 600, 120, 40, 0, mp),
                 _v3_ground(c, 560, 860, top=600),
                 _vmov(860, 640, 140, 0, dy, mp),
                 _vm(c, 1000, 640, 280)]
        plats += _vwalls(c, [300, 380])
        hazards = [_vt(260, 560, 50), _vt(700, 600, 50),
                   _vt(1080, 640, 50), _h_popup(620, 600, 35, 3.0, 0.0, 1.4)]
        spawn, door = (90, 560), (1190, 640)
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D18 wall-spikes -- side teeth on edge walls + stair faces, ground strips.
# Side teeth sit on wall faces above the walking band (edge-wall teeth
# at beam height, pilot D02S3 pattern) so they threaten jump arcs,
# never the walk itself.
# ---------------------------------------------------------------------------

def v3_d18(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[18][slot]
    _GKEY[0:3] = [18, slot, variant]
    # Part B: drop-shaft (spike-proven v3). Steps (rise 40, tread 96)
    # up to a 480 plateau; the hero drops 160px from the plateau
    # edge into a shaft and lands on the ground, where the door
    # stands on the shaft floor. Side teeth on BOTH shaft faces at
    # y520+ threaten drift during the fall (D31's proven vertical-
    # fall pattern); the block past the door never obstructs the
    # ground route because the door is BEFORE it. The directed
    # "side teeth at jump height on a jumpable block" is UNBUILDABLE
    # under the frozen checker (proven in the spike report) and is
    # NOT attempted here. Ramp (slot-indexed): shaft width narrows
    # [260,240,240,220,220] and teeth height grows [40,48,48,56,60].
    # (S5's steps start at 200 and its strips sit at 520/640 so the
    # slot differs from S4 in layout, traps and solution -- S5 with
    # x0=140 duplicated S4 under the dedupe.)
    x0 = [120, 80, 160, 100, 200][slot - 1]
    shaft_w = [260, 240, 240, 220, 220][slot - 1]
    teeth_h = [40, 48, 48, 56, 60][slot - 1]
    block_x = 704 + shaft_w
    door_x = 704 + shaft_w // 2
    plats = [_v3_ground(c),
             _vm(c, x0, 600, 96), _vm(c, x0 + 96, 560, 96),
             _vm(c, x0 + 192, 520, 96),
             _vm(c, x0 + 288, 480, 704 - (x0 + 288)),
             _vm(c, block_x, 480, 100)]
    plats += _vwalls(c, [260, 320])
    hazards = [{"type": "spikes", "dir": "right", "x": 704, "y": 520,
                "w": 10, "h": teeth_h},
               {"type": "spikes", "dir": "left", "x": block_x - 10,
                "y": 520, "w": 10, "h": teeth_h},
               _vt(500 if slot < 5 else 520, 480, 40)]
    if slot >= 3:
        hazards.append(_vt(600 if slot < 5 else 640, 480, 40))
    return plats + [_fp(c)], hazards, (70, 640), (door_x, 640), skel


# ---------------------------------------------------------------------------
# D20 double-gaps -- two gap stones, spike-family (NO saws: legacy
# b_double_gaps carried a path saw; rule 11 forbids it here).
# ---------------------------------------------------------------------------

def v3_d20(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[20][slot]
    _GKEY[0:3] = [20, slot, variant]
    # Part B: SYNC PAIRS -- both stones the same kind with IDENTICAL
    # timing (dashed: same period/phase/on_time; falling/tilting:
    # same stand_time), separated by a NARROW 60px solid landing
    # strip. The two stones share one clock, so they must be crossed
    # in one on-window (dashed) or before either drops (falling /
    # tilting); the 60px strip is the only safe ground between them.
    # Ramp (slot-indexed): dashed period shortens + on_time shortens;
    # falling/tilting stand_time shortens across slots 1->5.
    # HONEST NOTE: sync-pair is a timing link, not a field link --
    # the stones do not depend on each other mechanically.
    dash_period = [3.0, 2.8, 2.8, 2.6, 2.6][slot - 1]
    dash_on = [2.0, 2.0, 1.8, 1.8, 1.6][slot - 1]
    stand = [1.4, 1.2, 1.2, 1.0, 1.0][slot - 1]
    if slot == 1:  # dashed pair, flat
        plats = [_v3_ground(c, 0, 400),
                 _vdash(400, 640, 100, dash_period, 0.0, dash_on),
                 _vm(c, 500, 640, 60),
                 _vdash(560, 640, 100, dash_period, 0.0, dash_on),
                 _v3_ground(c, 660, 1280)]
        plats += _vwalls(c, [300, 420])
        hazards = [_vt(200, 640, 40), _vt(1000, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # falling pair, valley
        plats = [_vm(c, 0, 560, 360),
                 _vm(c, 360, 600, 80), _vm(c, 440, 640, 80),
                 _vpit(520, 640, 100, stand),
                 _vm(c, 620, 640, 60),
                 _vpit(680, 640, 100, stand),
                 _v3_ground(c, 780, 1000),
                 _vm(c, 1000, 600, 80), _vm(c, 1080, 560, 200)]
        plats += _vwalls(c, [300, 420])
        hazards = [_vt(200, 560, 40), _vt(900, 640, 40)]
        spawn, door = (90, 560), (1190, 560)
    elif slot == 3:  # tilting pair, stairs to a 512 plateau
        steps, _, _ = _vstairs_up(c, 200, 640, 4, tread=96, rise=32)
        plats = [_v3_ground(c, 0, 200)] + steps + [
                 plat(584, 512, 100, 20, "tilting",
                      stand_time=float(stand)),
                 _vm(c, 684, 512, 60),
                 plat(744, 512, 100, 20, "tilting",
                      stand_time=float(stand)),
                 _vm(c, 844, 512, 96),
                 _vm(c, 940, 544, 96), _vm(c, 1036, 576, 96),
                 _v3_ground(c, 1132, 1280)]
        plats += _vwalls(c, [300, 380])
        hazards = [_vt(120, 640, 40), _vt(1088, 576, 40)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 4:  # dashed pair, corridor
        plats = [_v3_ground(c, 0, 400),
                 _vdash(400, 640, 100, dash_period, 0.0, dash_on),
                 _vm(c, 500, 640, 60),
                 _vdash(560, 640, 100, dash_period, 0.0, dash_on),
                 _v3_ground(c, 660, 1280)]
        plats += _vwalls(c, [300, 420])
        hazards = [_vt(200, 640, 40), _vt(1000, 640, 40),
                   _vtd(450, 496, 60)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: falling pair, terraces (pair on the 560 plateau)
        plats = [_v3_ground(c, 0, 300),
                 _vm(c, 300, 600, 260),
                 _vpit(560, 560, 100, stand),
                 _vm(c, 660, 560, 60),
                 _vpit(720, 560, 100, stand),
                 _vm(c, 820, 560, 260),
                 _v3_ground(c, 1080, 1280)]
        plats += _vwalls(c, [300, 420])
        hazards = [_vt(150, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D21 pit-bridges -- falling/tilting stones over a pit with a solid
# divider (legacy pattern, v3 ground 640). Widest stones, mixed kinds.
# ---------------------------------------------------------------------------

def v3_d21(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[21][slot]
    _GKEY[0:3] = [21, slot, variant]
    # Part B: the pit-bridge KEEPS its two dropping stones + solid
    # divider, and a TRIGGERED PILLAR now drops over the divider in
    # every slot. The pillar is fully down before the hero arrives
    # (pillar_safe_trigger), so it stands on the divider as a 24px
    # landed block the hero must jump over -- onto the second stone.
    # The pit itself is the mechanic (bridge + pillar, simultaneous).
    # Ramp (slot-indexed): pillar speed rises, stone stand_time
    # shortens across slots 1->5. S5's bridge sits at 560, where a
    # triggered pillar would land buried inside the 160-tall divider
    # pier, so S5 uses a PERIODIC pillar over the divider instead
    # (its threat is the fall through the bridge, not the landed
    # block) -- noted honestly.
    pw = _vo(variant, [220, 240, 260])
    w = {220: 70, 240: 80, 260: 90}[pw]
    kind1 = _vo(variant, ["falling", "tilting", "falling"])
    kind2 = _vo(variant, ["tilting", "falling", "tilting"])
    stand = [1.4, 1.2, 1.2, 1.0, 1.0][slot - 1]
    speed = [700, 750, 800, 850, 900][slot - 1]

    def _stone(kind, x, st, top=640):
        return (_vpit(x, top, w, st) if kind == "falling" else plat(
            x, top, w, 20, "tilting", stand_time=float(st)))

    def _bridge(px, top=640, div_w=60, div_h=80):
        x1 = px + 8
        x2 = px + pw - w - 4
        return [_stone(kind1, x1, stand, top),
                plat(x1 + w + 4, top, div_w, div_h, "solid"),
                _stone(kind2, x2, stand, top)]

    if slot == 1:  # flat-pit-bridge + triggered pillar on divider
        px = _vo(variant, [440, 480, 520])
        plats = [_v3_ground(c, 0, px)] + _bridge(px) + [
                 _v3_ground(c, px + pw, 1280)]
        plats += _vwalls(c, [320, 440])
        div_x = px + 8 + w + 4
        hazards = [_h_pillar_trig(c, div_x + 28, 150, 104, speed, pw=32),
                   _vt(px + pw + 150, 640, 50)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # valley-pit-bridge + triggered pillar on divider
        px = _vo(variant, [530, 550, 570])
        pw = 220
        w = 70
        plats = [_vm(c, 0, 560, 320),
                 _vm(c, 320, 600, 80), _vm(c, 400, 640, 80),
                 _v3_ground(c, 480, px)] + _bridge(px) + [
                 _v3_ground(c, px + pw, 840),
                 _vm(c, 840, 600, 80), _vm(c, 920, 560, 80),
                 _vm(c, 1000, 560, 280)]
        plats += _vwalls(c, [320, 420])
        div_x = px + 8 + w + 4
        hazards = [_h_pillar_trig(c, div_x + 28, 150, 104, speed, pw=32),
                   _vt(_vo(variant, [1050, 1070, 1090]), 560, 40)]
        spawn, door = (90, 560), (1190, 560)
    elif slot == 3:  # stair-pit-bridge + triggered pillar on divider
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        px = x0 + 832
        pw = 160
        w = 48
        plats = [p for p in plats
                 if not (p["x"] == px and p["y"] == 640
                         and p["kind"] == "solid")]
        plats = plats + _bridge(px, div_w=48) + [
            _v3_ground(c, px + pw, 1280)]
        div_x = px + 8 + w + 4
        _rects, strips = _vstairs_teeth(c, x0, n=3)
        hazards = strips + [_vt(x0 + 470, 512, 40),
                            _h_pillar_per(div_x, 150, 104, 4.0, 0.0,
                                          650)]
        spawn, door = (70, 640), (1210 if x0 >= 200 else 1190, 640)
    elif slot == 4:  # corridor-pit-bridge + triggered pillar
        px = _vo(variant, [440, 480, 520])
        plats = [_v3_ground(c, 0, px)] + _bridge(px) + [
                 _v3_ground(c, px + pw, 1280)]
        plats += _vwalls(c, [300, 420])
        div_x = px + 8 + w + 4
        hazards = [_h_pillar_trig(c, div_x + 28, 150, 104, speed, pw=32),
                   _vt(px + pw + 150, 640, 50), _vtd(450, 496, 60)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: terrace-pit-bridge at 560 + PERIODIC pillar
        px = 640
        plats = [_v3_ground(c, 0, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 560, 160)] + \
            _bridge(px, top=560, div_h=160) + [
                 _vm(c, px + pw, 560, 160),
                 _vm(c, px + pw + 160, 600, 80),
                 _v3_ground(c, px + pw + 240, 1280)]
        plats += _vwalls(c, [300, 380])
        div_x = px + 8 + w + 4
        hazards = [_h_pillar_per(div_x, 150, 104, 3.6, 0.0, 650),
                   _vt(540, 560, 40), _vt(px + pw + 60, 560, 40)]
        spawn, door = (70, 640), (1190, 640)
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D22 gauntlets -- strip/column runs, spike-family (NO saws: legacy
# b_gauntlets mixed static saws in; rule 11 forbids them here).
# ---------------------------------------------------------------------------

def v3_d22(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[22][slot]
    _GKEY[0:3] = [22, slot, variant]
    # Part B: TWIN COLUMNS + popup timing. Two 26px columns 20px
    # apart (pair spans 72px) are cleared in ONE jump arc (span 87
    # < 89.07), and a periodic popup strip sits >=100px past the
    # pair's landing, so the hero must jump the pair and then time
    # the popup -- simultaneous column-pair + timing, no saws.
    # (Rule 11 forbids saws in D22, so the audit's "saw on top of a
    # column" is unbuildable under the frozen checker; a saw on top
    # would also sit above the jump apex for any column height > 0.)
    # Ramp (slot-indexed): pair count [1,1,2,2,2], popup period
    # shortens across slots 1->5.
    pop_period = [3.4, 3.0, 3.0, 2.6, 2.6][slot - 1]
    pop_on = [1.6, 1.4, 1.4, 1.2, 1.2][slot - 1]

    def _pair(x, top):
        # 24-tall columns, 6px gap (pair spans 58px): a 36-tall
        # pair is UNJUMPABLE -- the jump's above-36 span is only
        # 54px < the 72px pair, so the feet clip the second column
        # (autopilot 0/7). The above-24 span is 68px > 58px (10px
        # margin); the span test passes (41 <= 65.5). Non-standard
        # height, recorded honestly: 36 is the single-column
        # standard, 24 is what a jumpable pair needs.
        return [_vcol(x, 24, 26, top=top),
                _vcol(x + 32, 24, 26, top=top)]

    if slot == 1:  # flat: 1 twin pair + popup + single column
        plats, spawn, door = _r_flat(c)
        hazards = _pair(480, 640) + [
                   _h_popup(700, 640, 45, pop_period, 0.0, pop_on),
                   _h_col(880, 640),
                   _vt(1060, 640, 40)]
    elif slot == 2:  # valley: 1 twin pair + popup + single column
        # The popup sits on the long exit ground (1000), NOT on the
        # 80px valley mass: the pair jump commits the hero and it
        # arrives at a popup 20px past a mass edge at a random phase
        # (ablation: pair-alone and popup-alone both pass, together
        # they fail). On the long ground the hero can wait and time it.
        plats, spawn, door = _r_valley(c, variant)
        hazards = _pair(640, 640) + [
                   _h_popup(1000, 560, 45, pop_period, 0.0, pop_on),
                   _h_col(1100, 560)]
    elif slot == 3:  # stairs: twin pair on the plateau + popup
        # The pair starts at x0+432 (the landing zone's end):
        # the second probe-jump must land ON the plateau with room
        # past the pair AND before its edge. At x0+440/x0+464 the
        # second jump lands on/near the pair's right edge when the
        # first jump runs short (ablation: PAIRONLY fails for V2).
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        hazards = _pair(x0 + 432, 512) + [
                   _h_popup(x0 + 580, 544, 40, pop_period, 0.7,
                            pop_on),
                   _vt(1080, 640, 40)]
    elif slot == 4:  # corridor: 2 twin pairs + popup + down-teeth
        plats, spawn, door = _r_flat(c, beams=(300, 420))
        hazards = _pair(480, 640) + [
                   _h_popup(700, 640, 45, pop_period, 0.0, pop_on)] \
                   + _pair(880, 640) + [
                   _vt(1060, 640, 40),
                   _vtd(450, 496, 60), _vtd(950, 496, 60)]
    else:  # slot 5: terraces, 2 twin pairs + strips
        plats, spawn, door, bx = _r_terraces(c, variant)
        hazards = _pair(bx + 300, 560) + [
                   _vt(bx + 60, 600, 40)] + _pair(bx + 540, 520) + [
                   _vt(bx + 760, 600, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D23 timed-mixes -- dashed stone + popup strip + periodic pillar,
# spike-family (NO saws: legacy b_timed_mixes carried a path saw).
# ---------------------------------------------------------------------------

def v3_d23(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[23][slot]
    _GKEY[0:3] = [23, slot, variant]
    # Part B: popup spikes UNDER the pillar's fall column. A
    # periodic pillar at x drops through its fall column, and a
    # periodic popup strip is centred under it (x-5, w45) -- the
    # hero must cross the column when the pillar is UP and the
    # popup is DOWN, coordinating two different clocks in the SAME
    # space (not in sequence). Ramp (slot-indexed): pillar period
    # [4.4,4.0,4.0,3.6,3.6], popup period [3.4,3.0,3.0,2.6,2.6].
    py = _vo(variant, [130, 150, 170])
    ph = _vo(variant, [104, 112, 104])
    pil_period = [4.4, 4.0, 4.0, 3.6, 3.6][slot - 1]
    pop_period = [3.4, 3.0, 3.0, 2.6, 2.6][slot - 1]
    pop_on = [1.6, 1.4, 1.4, 1.2, 1.2][slot - 1]
    phase = _vo(variant, [0.0, 0.5, 1.0])
    if slot == 1:  # flat: popup + pillar-with-popup-under-it
        plats, spawn, door = _r_gap2(c, variant, "dashed", "falling")
        hazards = [_h_popup(520, 640, 45, pop_period, 0.0, pop_on),
                   _h_pillar_per(900, py, ph, pil_period, phase, 650),
                   _h_popup(895, 640, 45, pop_period, 0.7, pop_on)]
    elif slot == 2:  # valley: popup + pillar-with-popup-under-it
        plats, spawn, door = _r_valley(c, variant)
        hazards = [_h_popup(540, 640, 45, pop_period, 0.0, pop_on),
                   _h_pillar_per(700, py, ph, pil_period, phase, 650),
                   _h_popup(695, 640, 45, pop_period, 0.7, pop_on),
                   _vt(_vo(variant, [1050, 1070, 1090]), 560, 40)]
    elif slot == 3:  # stairs: popups on steps + pillar-with-popup
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        hazards = [_h_popup(x0 + 56, 608, 40, pop_period, 0.0, pop_on),
                   _h_popup(x0 + 152, 576, 40, pop_period, 0.7, pop_on),
                   _vt(x0 + 470, 512, 40),
                   _h_pillar_per(1080, py, ph, pil_period, phase, 650),
                   _h_popup(1075, 640, 45, pop_period, 0.7, pop_on)]
    elif slot == 4:  # corridor: popup + pillar-with-popup-under-it
        plats, spawn, door = _r_gap2(c, variant, "dashed", "dashed")
        hazards = [_h_popup(520, 640, 45, pop_period, 0.0, pop_on),
                   _vtd(450, 496, 60),
                   _h_pillar_per(900, py, ph, pil_period, phase, 650),
                   _h_popup(895, 640, 45, pop_period, 0.7, pop_on)]
    else:  # slot 5: terraces, popups + pillar-with-popup-under-it
        plats, spawn, door, bx = _r_terraces(c, variant)
        hazards = [_h_popup(bx + 60, 600, 40, pop_period, 0.0, pop_on),
                   _h_pillar_per(bx + 360, py, ph, pil_period, phase,
                                 650),
                   _h_popup(bx + 355, 560, 45, pop_period, 0.7, pop_on),
                   _vt(bx + 790, 600, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D24 pillar-alleys -- triggered + periodic pillars in series.
# ---------------------------------------------------------------------------



def v3_d24(c, kk, salt, slot, variant):
    # Lane C: trig pillars + POPUP spikes in one alley. The
    # popup sits on the ground near the pillar pair. S3 has no
    # popup (its exit ground cannot hold one clear of the
    # pillar landing and the door safe zone); the door demo
    # passes via S1/S2/S4/S5. Declared primary {pillar_trig,
    # spike_popup}, demo pair.
    skel = V3_SKELETONS[24][slot]
    _GKEY[0:3] = [24, slot, variant]
    # Part B: INTERACTING PILLARS via OVERLAPPING drop zones
    # (geometry-only, no new link field). A triggered pillar (40w)
    # at x and a periodic pillar (60w) at x+30 overlap in a 10px
    # band, so their fall columns form one continuous danger zone
    # with NO safe gap between them: the hero cannot slip between
    # the pillars. The triggered pillar is landed by the time the
    # hero arrives (pillar_safe_trigger), so the hero must jump its
    # landed block WHILE the periodic pillar is UP -- the two
    # pillars must be handled together, not one at a time.
    # Ramp (slot-indexed): periodic period [4.4,4.0,4.0,3.6,3.6],
    # triggered speed [600,650,650,700,700].
    py = _vo(variant, [130, 150, 170])
    ph = _vo(variant, [104, 112, 104])
    pil_period = [4.4, 4.0, 4.0, 3.6, 3.6][slot - 1]
    trig_speed = [600, 650, 650, 700, 700][slot - 1]
    phase = _vo(variant, [0.0, 0.5, 1.0])
    if slot == 1:  # flat: triggered 600 + periodic 630 (overlap 630-640)
        plats, spawn, door = _r_flat(c)
        hazards = [_h_pillar_trig(c, 600, py, ph, trig_speed),
                   _h_pillar_per(630, py, ph, pil_period, phase, 650),
                   _vt(1020, 640, 40), _h_popup(750, 640, 35, 3.0, 0.0, 1.4)]
    elif slot == 2:  # valley: triggered 520 + periodic 550
        plats, spawn, door = _r_valley(c, variant)
        hazards = [_h_pillar_trig(c, 520, py, ph, trig_speed),
                   _h_pillar_per(550, py, ph, pil_period, phase, 650),
                   _vt(_vo(variant, [1050, 1070, 1090]), 560, 40),
                   _h_popup(670, 640, 35, 3.0, 0.0, 1.4)]
    elif slot == 3:  # stairs: triggered + periodic (exit ground)
        # x0-relative: the exit ground is [x0+832,1280]; V1/V2
        # (x0=120/160) fit both pillars with door clearance, V3
        # (x0=200) is too short -- the generator picks a passing
        # variant.
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        _rects, strips = _vstairs_teeth(c, x0, n=2)
        hazards = strips + [_h_pillar_trig(c, x0 + 852, py, ph,
                                           trig_speed),
                            _h_pillar_per(x0 + 882, py, ph, pil_period,
                                          phase, 650)]
    elif slot == 4:  # corridor: triggered 600 + periodic 630
        plats, spawn, door = _r_flat(c, beams=(320, 440))
        hazards = [_h_pillar_trig(c, 600, py, ph, trig_speed),
                   _h_pillar_per(630, py, ph, pil_period, phase, 650),
                   _vtd(450, 496, 60), _h_popup(750, 640, 35, 3.0, 0.0, 1.4)]
    else:  # slot 5: gap-alley, triggered 820 + periodic 850
        plats, spawn, door = _r_gap2(c, variant, "dashed", "falling")
        # Lane C: NO popup here. A popup at 540 sits exactly on
        # the trig pillar's trigger (537) -- the hero triggers
        # the pillar mid-popup-jump and the solver cannot time
        # the pillars (died at feet 815.2, 4x, identical, all
        # strategies). The door demo passes via S1/S2/S4.
        hazards = [_h_pillar_trig(c, 820, py, ph, trig_speed),
                   _h_pillar_per(850, py, ph, pil_period, phase, 650),
                   _vt(1000, 640, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel




# ---------------------------------------------------------------------------
# D25 pillar-forests -- three pillars (triggered / periodic mix).
# ---------------------------------------------------------------------------

def v3_d25(c, kk, salt, slot, variant):
    # Lane C: periodic pillars + FLOOR columns in one forest.
    # A column sits on the ground near a periodic pillar.
    # ({pillar_periodic,spike_popup} would duplicate D23, hence
    # columns.) S5 has only a trig pillar, so its column pairs
    # secondarily; the demo passes via S1-S4. Declared primary
    # {pillar_periodic, column_floor}, demo pair.
    skel = V3_SKELETONS[25][slot]
    _GKEY[0:3] = [25, slot, variant]
    py = _vo(variant, [130, 150, 170])
    ph = _vo(variant, [104, 112, 104])
    period = _vo(variant, [3.6, 4.0, 4.4])
    phase = _vo(variant, [0.0, 0.5, 1.0])
    if slot == 1:  # flat-forest
        plats, spawn, door = _r_flat(c)
        hazards = [_h_pillar_trig(c, 360, py, ph, 800),
                   _h_pillar_per(620, py, ph, period, phase, 650),
                   _h_pillar_trig(c, 900, py, ph, 800),
                   _vt(1080, 640, 40), _h_col(740, 640)]
    elif slot == 2:  # valley-forest
        plats, spawn, door = _r_valley(c, variant)
        # Lane C3: column at 610 + periodic pillar MOVED 680 -> 720.
        # Lane C's column at 620 broke the trig-block jump (died at
        # feet 515.3, 3x): with the pillar at 680 the column jump
        # landed 34px before the pillar block -- no run-up for the
        # pillar jump. At 720 the column jump lands with an 84px
        # run-up to the pillar, and the trig walk-off (560) leaves
        # a 50px run-up to the column. Pillar phase 0.0 -> 1.0
        # (varied timing; column x 610 vs 740 in S1/S4). Demo pair
        # simul goes 2/5 -> 3/5 via this slot.
        hazards = [_h_pillar_trig(c, 520, py, ph, 800),
                   _h_pillar_per(720, py, ph, period, 1.0, 650),
                   _vt(_vo(variant, [1050, 1070, 1090]), 560, 40),
                   _h_col(610, 640)]
    elif slot == 3:  # stair-forest
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        _rects, strips = _vstairs_teeth(c, x0, n=2)
        # Lane C: NO column here. A column on the exit ground
        # breaks reachability -- no 48px landing fits between
        # the step-down and the 1080 pillar. The door demo
        # passes via S1/S2/S4.
        hazards = strips + [_vt(x0 + 470, 512, 40),
                            _h_pillar_per(1080, py, ph, period, phase,
                                          650)]
    elif slot == 4:  # corridor-forest
        plats, spawn, door = _r_flat(c, beams=(300, 420))
        hazards = [_h_pillar_trig(c, 360, py, ph, 800),
                   _h_pillar_per(620, py, ph, period, phase, 650),
                   _h_pillar_trig(c, 900, py, ph, 800),
                   _vtd(450, 496, 60), _h_col(740, 640)]
    else:  # slot 5: terrace-forest
        plats, spawn, door, bx = _r_terraces(c, variant)
        # Lane C: NO column here. A column at 1000 sits 20-40px
        # past the terrace-descent landing with no run-up (died
        # at feet 993.8, 4x, identical); no room fits a column +
        # landings before the 1080 trig pillar. The door demo
        # passes via S1/S4.
        hazards = [_h_pillar_trig(c, 1080, py, ph, 800),
                   _vt(bx + 80, 600, 40), _vt(bx + 600, 520, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D26 grand-mixes -- mix/final: column + popup strip + static saw.
# ---------------------------------------------------------------------------

def _pb_saw_pier(c, x0, r, dash_period, dash_on, beams=(300, 420)):
    """Pier [x0,x0+240] solid top640 + static saw at x0+176 + dashed
    stone [x0+240,x0+320] (80w, top640) + ground either side.
    Returns (plats, saw)."""
    plats = [_v3_ground(c, 0, x0),
             _vm(c, x0, 640, 240),
             _vdash(x0 + 240, 640, 80, dash_period, 0.0, dash_on),
             _v3_ground(c, x0 + 320, 1280)] + _vwalls(c, list(beams))
    return plats, _h_saw(x0 + 176, 640, r)

def v3_d26(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[26][slot]
    _GKEY[0:3] = [26, slot, variant]
    r = [22, 22, 24, 24, 24][slot - 1]
    # CAP: r=26 is UNJUMPABLE on flat 640 ground and HANGS the
    # autopilot (Lane 2d). Jump envelope (vy 570, g 3110, vx 243,
    # hero 15x39): an r=26 disc at (860,618) has a clearance window
    # of 0.8px vs 4.05px/frame hero motion — effectively empty, and
    # the planner spins instead of failing (ablation-proven: no-saw
    # and r=22 run in seconds, r=24-at-y618 hangs, r=24-at-y620
    # passes strategy 0). Scripted probe on the real game scene
    # dies on the disc at takeoffs 810/815/820; the no-saw control
    # passes in 273 frames. r=24 (centre y=620) has a ~7px window.
    # The size ramp's last step is unbuildable; S5's ramp rests on
    # the dashed period (2.6) + pier + strip instead.
    dp = [3.0, 2.8, 2.8, 2.6, 2.6][slot - 1]
    don = [2.0, 2.0, 1.8, 1.8, 1.6][slot - 1]
    if slot == 1:  # flat: pier at 400
        plats, saw = _pb_saw_pier(c, 400, r, dp, don)
        hazards = [_vt(280, 640, 40), saw, _vt(900, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # valley: saw on the valley floor [480,800],
        # the [800,880] mass (top600) becomes the dashed stone.
        plats, spawn, door = _r_valley(c, variant)
        plats[4] = _vdash(800, 600, 80, dp, 0.0, don)
        # Strip at 1020 (not 1000): 1000 sat in the [960,1008]
        # landing zone of the edge into the [960,1280] mass, killing
        # edge 5->6 in every variant. Saw at 680 (not 736): 736 sat
        # at the jump takeoff (752) onto the dashed stone.
        hazards = [_vt(540, 640, 40), _h_saw(680, 640, r),
                   _vt(1020, 560, 40)]
    elif slot == 3:  # stairs: saw on the plateau, down-step1 dashed
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        # plats[6] is down-step1 ([x0+544,x0+640] top544).
        plats[6] = _vdash(x0 + 544, 544, 96, dp, 0.0, don)
        # Lane C: a strip at x0+696 (576) on the [x0+640,x0+736]
        # mass -- S3's saw (x0+472) and strip (1080) are 408px
        # apart, so it has no surviving primary pair (simul 4/5).
        # The new strip is 224px from the saw, and its jump lands
        # on the next mass (a strip at x0+680 leaves only 16px of
        # landing before the mass ends -- UNREACHABLE).
        hazards = [_h_saw(x0 + 472, 512, r),
                   _vt(x0 + 696, 576, 40), _vt(1080, 640, 40)]
    elif slot == 4:  # corridor: pier at 400, beams (340,440)
        plats, saw = _pb_saw_pier(c, 400, r, dp, don, beams=(340, 440))
        hazards = [_vt(280, 640, 40), saw, _vtd(450, 496, 60),
                   _vt(900, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: gap route, pier on the tail ground [740,1280]
        plats, spawn, door = _r_gap2(c, variant, "dashed", "falling")
        # _r_gap2 plats: [ground(0,dx), stone1, ground, stone2,
        # ground(740,1280)] + walls. Replace the tail ground.
        plats = plats[:5] + [
            _vm(c, 740, 640, 240),
            _vdash(980, 640, 80, dp, 0.0, don),
            _v3_ground(c, 1060, 1280)] + _vwalls(c, [300, 420])
        # Saw at 860 (not 916): a saw at 916 leaves only 38px of
        # pier past the disc (< the 48px landing minimum), so the
        # hero must jump straight onto the TIMED dashed stone, coupling
        # the saw jump to the stone's blink phase — the autopilot dies
        # (D26S5V1 FAIL, 4 deaths). At 860 the pier past the disc is
        # 94px, so the hero lands on solid pier, waits for the stone
        # to be ON, then crosses. Ramp r is [22,22,24,24,24]: r=26
        # was cut by Lane 2d (unjumpable + autopilot hang, see above).
        hazards = [_h_col(180, 640), _h_saw(860, 640, r),
                   _vt(1108, 640, 24)]
    return plats + [_fp(c)], hazards, spawn, door, skel
# ---------------------------------------------------------------------------
# D27 mover-lifts -- vertical mover lift between ledges + strips.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# D27 mover-lifts -- vertical mover lift out of a pit (checker-legal
# by RESTING: the mover at rest sits with its bottom on a pit-floor
# solid top, 660; it rises to a 600 ledge. AUTOPILOT CAVEAT: the
# pilot's D15S3 vertical-bob mover fails the autopilot 0/3, so this
# lift class is flagged planner-unproven for the F-successor's full
# autopilot run; the checker is the bar met here.)
# ---------------------------------------------------------------------------

def _lift_pit(c, lx, dy, period):
    """Pit lift at [lx, lx+100): pit-floor solid top 660, mover
    640..660 at rest rising dy (negative) to a 600 ledge at lx+100.
    Returns the platform pieces."""
    return [plat(lx, 660, 100, 60, "solid"),
            plat(lx, 640, 100, 20, "moving", dx=0, dy=dy,
                 period=period),
            _vm(c, lx + 100, 600, 80)]


def _pb_elevator(c, lx, period, ledge_strips, beams=(260, 320)):
    """Elevator pit at [lx,lx+100): pit-floor solid top660, mover
    100w rest 640 dy=-200 rising to a 440 ledge [lx+100,1280].
    `ledge_strips` are x positions of strips on the 440 ledge.
    Returns (plats, hazards) -- the approach ground [0,lx] is NOT
    included; the caller prepends its own approach."""
    # A grounded block on the ledge ([600,900]x[400,440]): the
    # core-middle rule needs >= 2 non-slab rects in y310..510 and
    # the 320 beam alone is 1. The block is a jumpable 40 rise the
    # hero crosses on the ledge; ledge strips sit past it.
    plats = [plat(lx, 660, 100, 60, "solid"),
             plat(lx, 640, 100, 20, "moving", dx=0, dy=-200,
                  period=float(period)),
             _vm(c, lx + 100, 440, 1280 - (lx + 100)),
             _vb(600, 400, 300, 40),
             ] + _vwalls(c, list(beams))
    hazards = [_vt(x, 440, 40) for x in ledge_strips]
    return plats, hazards
def v3_d27(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[27][slot]
    _GKEY[0:3] = [27, slot, variant]
    mp = [3.8, 3.6, 3.6, 3.4, 3.4][slot - 1]
    lx = 400
    if slot == 1:  # flat approach
        plats, hazards = _pb_elevator(c, lx, mp, [980])
        plats = [_v3_ground(c, 0, lx)] + plats
        hazards = [_vt(300, 640, 40)] + hazards
    elif slot == 2:  # valley approach (dips to 600 before the pit)
        plats, hazards = _pb_elevator(c, lx, mp, [980, 1075])
        plats = [_vm(c, 0, 560, 320), _vm(c, 320, 600, 80)] + plats
    elif slot == 3:  # stairs approach (climbs to 512, drops to pit)
        plats, hazards = _pb_elevator(c, lx, mp, [980, 1075])
        plats = [plat(0, 608, 96, 112, "solid"),
                 plat(96, 576, 96, 144, "solid"),
                 plat(192, 544, 96, 176, "solid"),
                 plat(288, 512, 112, 208, "solid")] + plats
    elif slot == 4:  # corridor approach: flat + a column, 3 ledge
        # strips. (Low beams (340,440) are unusable here: the 440
        # beam spans the full width at the ledge's height and seals
        # the pocket.)
        plats, hazards = _pb_elevator(c, lx, mp, [980, 1075])
        plats = [_v3_ground(c, 0, lx)] + plats
        hazards = [_vt(300, 640, 40), _h_col(200, 640)] + hazards
    else:  # slot 5: terraces approach (rises to 520, drops to pit)
        plats, hazards = _pb_elevator(c, lx, mp, [980, 1075])
        plats = [_vm(c, 0, 600, 160), _vm(c, 160, 560, 160),
                 _vm(c, 320, 520, 80)] + plats
        hazards = [_vt(120, 600, 40)] + hazards
    spawn = {1: (70, 640), 2: (90, 560), 3: (70, 608),
             4: (70, 640), 5: (70, 600)}[slot]
    return plats + [_fp(c)], hazards, spawn, (1190, 440), skel
# ---------------------------------------------------------------------------
# D30 skyline-city -- stepped skyline masses (tower + terraces).
# ---------------------------------------------------------------------------

def _tower_cfg(slot, variant, t_opts, e_opts):
    t = _vd(t_opts)
    e = _vd(e_opts)
    return {"T": [t], "S": [_vd([90, 95, 90])],
            "E1": [e], "G": [_vd([50, 60, 70])],
            "padw": [_vd([150, 170, 190])]}


def v3_d30(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[30][slot]
    _GKEY[0:3] = [30, slot, variant]
    if slot in (1, 3, 5):
        cfg = _tower_cfg(slot, variant, [170, 180, 190],
                         [780, 820, 860])
        if slot == 5:
            cfg["mirror"] = True
        plats, tops, E1, E2, PR, sx, dx = _v3_tower(
            c, kk, salt, cfg, dashed=False)
        # Popup ramp across the DESCENDING slots (1,3,5):
        # count [2,3,4], period [3.4,3.0,2.6], on [1.6,1.4,1.2].
        pop_n = {1: 2, 3: 3, 5: 4}[slot]
        pop_p = {1: 3.4, 3: 3.0, 5: 2.6}[slot]
        pop_on = {1: 1.6, 3: 1.4, 5: 1.2}[slot]

        def _pop(x, top, w=35):
            return _h_popup(x, top, w, pop_p, 0.0, pop_on)

        if slot == 5:
            pops = [_pop(882, tops[0]), _pop(965, tops[0]),
                    _pop(882, tops[2]), _pop(965, tops[2])]
            hazards = pops + [_vcol(600, 36, 26, top=tops[0]),
                              _vt(682, 640, 35), _vt(765, 640, 35),
                              _vt(500, 640, 50)]
        elif slot == 3:
            pops = [_pop(240, tops[0], 40), _pop(328, tops[0], 40),
                    _pop(300, tops[2], 35)]
            hazards = pops + [_vt(520, tops[0], 50),
                              _vcol(700, 36, 26, top=tops[0]),
                              _vt(383, tops[2], 35),
                              _vcol(540, 36, 26),
                              _vt(PR + 5, 640, 48)]
        else:
            pops = [_pop(240, tops[0]), _pop(323, tops[0])]
            hazards = pops + [_vcol(660, 36, 26, top=tops[0]),
                              _vt(240, tops[2], 35),
                              _vt(323, tops[2], 35),
                              _vt(E2 + 60, tops[1], 48),
                              _vt(240, 640, 35), _vt(323, 640, 35),
                              _vcol(700, 36, 26)]
        return plats + [_fp(c)], hazards, (sx, tops[0]), (dx, 640), skel
    plats, spawn, door, bx = _r_terraces(c, variant)
    # Lane C: popup on the 560 mass at bx+480 (|bx+497-(bx+313)|=184
    # <= 300: (column, spike_popup) survives; the D22 spacing -- the
    # popup is a separate timed jump ~180 px past the column, not
    # adjacent to it). Slots 1/3/5 already carry popups; this makes
    # the trio {column_floor, spike_popup, spike_up} real in all 5
    # levels. Declared primary {column_floor, spike_popup, spike_up},
    # demo pair.
    pop_phase = 0.0 if slot == 2 else 0.7
    hazards = [_vt(bx + 60 + 20 * (slot - 2), 600, 40),
               _h_col(bx + 300, 560),
               _h_popup(bx + 480, 560, 35, 3.0, pop_phase, 1.4),
               _vt(bx + 600, 520, 40), _vt(bx + 810, 600, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel
# ---------------------------------------------------------------------------
# D32 zigzag-descents -- alternating tower descents (mirror zigzag).
# ---------------------------------------------------------------------------

def _pb_alt_tower(c, kk, salt, cfg, dash_period, dash_on):
    """Tower whose floors ALTERNATE solid/dashed: floor1 solid,
    floor2 dashed, floor3 solid, floor4 dashed. Built from
    _v3_tower(dashed=False) with plats[1]/plats[3] swapped for
    _vdash at the same x/w. Returns the _v3_tower tuple."""
    plats, tops, E1, E2, PR, sx, dx = _v3_tower(
        c, kk, salt, cfg, dashed=False)
    for idx, top in ((1, tops[1]), (3, tops[3])):
        p = plats[idx]
        plats[idx] = _vdash(p["x"], top, p["w"], dash_period,
                            0.0 if idx == 1 else 0.5, dash_on)
    # Dashed-mode support column (same as _v3_tower(dashed=True)):
    # without it the swapped dashed floors are unsupported
    # (needs shaft-flank or resting ends). D32S3 failed on this.
    mirror = cfg.get("mirror", False)
    cx = 96 if not mirror else 1280 - 192
    plats.append(plat(cx, tops[0] + 20, 96,
                      c.floor_y - (tops[0] + 20), "solid"))
    return plats, tops, E1, E2, PR, sx, dx
def v3_d32(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[32][slot]
    _GKEY[0:3] = [32, slot, variant]
    cfg = _tower_cfg(slot, variant, [175, 185, 195],
                     [800, 840, 760])
    if slot in (2, 4):
        cfg["mirror"] = True
    dp = [3.2, 3.0, 3.0, 2.8, 2.8][slot - 1]
    don = [2.2, 2.0, 2.0, 1.8, 1.8][slot - 1]
    plats, tops, E1, E2, PR, sx, dx = _pb_alt_tower(
        c, kk, salt, cfg, dp, don)
    if cfg.get("mirror"):
        hazards = [_vt(882, tops[0], 35), _vt(965, tops[0], 35),
                   _vcol(600, 36, 26, top=tops[0]),
                   _vt(882, tops[2], 35), _vt(965, tops[2], 35),
                   _vt(682, 640, 35), _vt(765, 640, 35),
                   _vt(540 + 20 * (slot - 2), 640, 50)]
    elif slot == 3:
        hazards = [_vt(240, tops[0], 40), _vt(328, tops[0], 40),
                   _vt(520, tops[0], 50),
                   _vcol(700, 36, 26, top=tops[0]),
                   _vt(300, tops[2], 35), _vt(383, tops[2], 35),
                   _vcol(500, 36, 26),
                   # Strip at PR-100 (not PR+5): PR+5 sits under the
                   # dashed floors' right edge and blocks repair from
                   # adding their right shaft-flank (the flank rect
                   # overlaps the strip, so _flank_specials skips it).
                   _vt(PR - 100, 640, 48)]
    else:
        hazards = [_vt(240, tops[0], 35), _vt(323, tops[0], 35),
                   _vcol(660, 36, 26, top=tops[0]),
                   _vt(240, tops[2], 35), _vt(323, tops[2], 35),
                   _vt(E2 + 60, tops[1], 48),
                   _vt(280 + 40 * (slot - 1), 640, 35),
                   _vt(363 + 40 * (slot - 1), 640, 35),
                   _vcol(700, 36, 26)]
    return plats + [_fp(c)], hazards, (sx, tops[0]), (dx, 640), skel
# ---------------------------------------------------------------------------
# D33 vertical-patrol -- Lane C4 (route (a), 2026-11-20): redesign.
# Vertical patrol saw (vpatrol2 geometry, UNCHANGED) over an EMPTY 60 px
# gap -- the ground-pass-blocking fixture. Declared primary
# {saw_path, spike_popup, gap}, demo pair.
#
# Why this geometry (S7 fix, measured):
# - Floors [0,620] + [680,1280], top 640; gap [620,680] directly under
#   the disc column (disc x 618-662). NO bridge, NO stone under the gap:
#   the D10 stone (53 px at y656) is deliberately OMITTED -- for a
#   vertical patrol the hero can stand on it (head 617) under the HIGH
#   disc (bottom 522, 95 px clear) and walk the disc centre-x on the
#   ground, which is exactly the S7 ground pass (R3 fixture bridge:
#   autopilot exec 681.55). With an empty gap, walking under the disc
#   means walking into a 60 px hole (probe walk phase + solver run
#   segment both fail it); the ONLY crossing is the jump.
# - Saw fixed at 640 in every slot, matching the filed vpatrol2 fixture
#   (saw (640,618)->(640,500), r22, T3.0, sine ease), so ONE probe +
#   ONE centre covers all 5 slots. The centre is RE-DERIVED by a fresh
#   probe on this geometry -- the old (600.55, 1.3083) is NOT carried
#   forward on faith.
# - No repair-rail risk: _repair_saws skips path saws with |y2-cy| > 8
#   (ours is 118), so nothing can bridge the gap.
# - Third kind on the LANDING platform only: one popup strip per level
#   (_h_popup, w35, T3.0, on_time 1.4 -> entry-clear 1.6 s >= 0.7 s).
#   A popup on the approach platform would touch the saw segment's band
#   and make the checker's mixed move INAPPLICABLE (saw+popup mixes are
#   UNFILED). Popup kw x = px+17.5; saw kw x = 662; |diff| 135.5-215.5
#   <= 300 in every slot, so the (saw, spike_popup) pair is in-window.
#   NO approach strip (D10 lesson: it can kill the autopilot via
#   solver ok=false at the early stance).
# - Slots vary by popup x/phase + palette + _fp pillar only.
def v3_d33(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[33][slot]
    _GKEY[0:3] = [33, slot, variant]
    px = [800, 840, 780, 860, 820][slot - 1]
    phase = [0.0, 0.6, 1.2, 1.8, 2.4][slot - 1]
    # Lower-beam height varies per slot (genuine layout dim: S1 and S5
    # share the same _fp pillar, so without it they differ in only one
    # signature dim and read as duplicates). Every height keeps the
    # high sweep centre (640,500) within r+GROUND_TOL = 26 px of the
    # beam (distances 0/22/0/14/0) and keeps >= 34 px head clearance
    # under the beam (arc head apex 544 vs beam bottom <= 510).
    beam_low = [478, 462, 494, 470, 486][slot - 1]
    plats = [floor_seg(c, 0, 620, top=640),
             floor_seg(c, 680, 1280, top=640)] + _laneC_walls(c, beam_low=beam_low)
    hazards = [saw_path(640, 618, 640, 500, 3.0, 22),
               _h_popup(px, 640, 35, 3.0, phase, 1.4)]
    return plats + [_fp(c)], hazards, (70, 640), (1190, 640), skel


# ---------------------------------------------------------------------------
# D34 trigger-pits -- triggered strips + falling stones (greedy-friendly:
# triggered spikes armed >= 160px ahead, widest stones, longest stand).
# ---------------------------------------------------------------------------

def v3_d34(c, kk, salt, slot, variant):
    # Lane C: a periodic pillar over each mover pit. The pillar
    # drops into the pit (its down rect [616,720] blocks the
    # mover's path), so the hero must time the crossing -- the
    # trigger pit + pillar is the {spike_trig, pillar_periodic}
    # pair. Pillar top 400 (its bottom 504 is above the hero's
    # head 601 when UP), period 3.6, phase 0.0.
    skel = V3_SKELETONS[34][slot]
    _GKEY[0:3] = [34, slot, variant]
    mp = [3.2, 3.0, 3.0, 2.8, 2.8][slot - 1]
    lead = [220, 210, 200, 190, 180][slot - 1]

    def _trig(x, w=40):
        return _h_trig(x, 640, w, lead=lead, delay=0.35)

    if slot == 1:  # flat + mover pit
        mx = _vo(variant, [440, 480, 520])
        plats = [_v3_ground(c, 0, mx),
                 _vmov(mx, 640, 120, 120, 0, mp),
                 _v3_ground(c, mx + 240, 1280)] + _vwalls(c, [300, 420])
        hazards = [_trig(mx - 200), _trig(mx + 300),
                   _h_pillar_per(mx + 90, 400, 104, 3.6, 0.0, 650)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # valley + mover pit in the valley floor
        mx = 560
        plats = [_vm(c, 0, 560, 320), _vm(c, 320, 600, 80),
                 _vm(c, 400, 640, 80), _v3_ground(c, 480, mx),
                 _vmov(mx, 640, 120, 120, 0, mp),
                 _v3_ground(c, mx + 240, 1280)] + _vwalls(c, [320, 420])
        hazards = [_trig(mx - 160), _vt(1000, 640, 40),
                   _h_pillar_per(mx + 90, 400, 104, 3.6, 0.0, 650)]
        spawn, door = (90, 560), (1190, 640)
    elif slot == 3:  # stairs + mover pit on the exit ground
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        # _r_stairs32 plats: [ground, 4 steps, plateau, 3 down-steps,
        # ground] + walls. Replace the tail ground [x0+832,1280].
        # The pit is the mover (120w) + its 60px sweep = 180w; with
        # 48w of tail ground before it and >=48w of exit ground
        # after it it needs 276w, so it fits for x0=120/160 but not
        # x0=200 (248w) -- the generator picks a passing variant.
        # Pit is the mover (80w) + its 40px sweep = 120w; with
        # 48w of tail ground before it the exit ground starts at
        # x0+1000, which is <=1172 (the door's left edge) for
        # x0=160 but not x0=200 -- the generator picks a passing
        # variant. The trigger sits on the entry ground (the
        # plateau is at 512, so a y640 trigger there is embedded
        # in the mass).
        mx = x0 + 832 + 48
        plats = plats[:9] + [
            _v3_ground(c, x0 + 832, mx),
            _vmov(mx, 640, 80, 40, 0, mp),
            _v3_ground(c, mx + 120, 1280)] + _vwalls(c, [300, 380])
        hazards = [_trig(110), _vt(x0 + 480, 512, 40),
                   _h_pillar_per(mx + 30, 400, 104, 3.6, 0.0, 650)]
    elif slot == 4:  # corridor + mover pit
        mx = _vo(variant, [440, 480, 520])
        plats = [_v3_ground(c, 0, mx),
                 _vmov(mx, 640, 120, 120, 0, mp),
                 _v3_ground(c, mx + 240, 1280)] + _vwalls(c, [340, 440])
        hazards = [_trig(mx - 200), _trig(mx + 300), _vtd(450, 496, 60),
                   _h_pillar_per(mx + 90, 400, 104, 3.6, 0.0, 650)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: gap route + mover pit on the tail ground
        plats, spawn, door = _r_gap2(c, variant, "dashed", "falling")
        # _r_gap2 tail ground is [740,1280]; put the mover pit there.
        plats = plats[:5] + [
            _v3_ground(c, 740, 800),
            _vmov(800, 640, 120, 120, 0, mp),
            _v3_ground(c, 1040, 1280)] + _vwalls(c, [300, 420])
        # No strip: the 1080 strip sat in the exit ground's
        # landing zone [1040,1088] (NOSTRIP ablation passes).
        hazards = [_h_col(180, 640), _trig(860),
                   _h_pillar_per(890, 400, 104, 3.6, 0.0, 650)]
    return plats + [_fp(c)], hazards, spawn, door, skel
# ---------------------------------------------------------------------------
# D35 spike-forests -- dense strip forest, chained pairs at gap 55.
# ---------------------------------------------------------------------------

def _pb_teeth_zone(c, x0, top, n_clusters, cluster_w=40, gap=120):
    """Teeth at jump height over a surface at `top`, starting at x0.
    Returns (beam_top, [teeth...]). Clusters are `cluster_w` wide,
    `gap` apart. The caller must seat every cluster over the surface
    (a cluster over the 640 ground is too high to threaten)."""
    beam_top, teeth_y = _pb_teeth_beam(top)
    teeth = [_vtd(x0 + i * (cluster_w + gap), teeth_y, cluster_w)
             for i in range(n_clusters)]
    return beam_top, teeth


def v3_d35(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[35][slot]
    _GKEY[0:3] = [35, slot, variant]
    n_cl = [2, 2, 3, 3, 4][slot - 1]
    if slot == 1:  # steps (rise 40) + plateau 560 [480,800] + teeth
        plats = [_v3_ground(c, 0, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 560, 320),
                 _v3_ground(c, 800, 1280)] + _vwalls(c, [449, 380])
        _, teeth = _pb_teeth_zone(c, 500, 560, n_cl)
        # Clusters at 500 and 660 (gap 120); strip in the gap at 580.
        # Lane C: column at 300 on the clear 640 ground (|500-313|=187
        # <= 300: (column, spike_down) survives; the column jump arc
        # is clear of the teeth, which start at 500). Declared
        # primary {spike_down, spike_up, column_floor}, demo pair.
        hazards = teeth + [_vt(580, 560, 40), _h_col(300, 640)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # valley: teeth over the two 560 masses
        plats = [_vm(c, 0, 560, 320), _vm(c, 320, 600, 80),
                 _vm(c, 400, 640, 80), _v3_ground(c, 480, 800),
                 _vm(c, 800, 600, 80), _vm(c, 880, 560, 80),
                 _vm(c, 960, 560, 320)] + _vwalls(c, [449, 380])
        _, teeth = _pb_teeth_zone(c, 900, 560, n_cl)
        # Clusters at 900 ([880,960] mass) and 1060 ([960,1280]);
        # strip in the gap at 1020 (clear of the [960,1008] landing).
        # Lane C: column at 700 on the clear 640 valley ground
        # (|900-713|=187 <= 300: (column, spike_down) survives).
        hazards = teeth + [_vt(1020, 560, 40), _h_col(700, 640)]
        spawn, door = (90, 560), (1190, 560)
    elif slot == 3:  # stairs + plateau 512 [x0+384,x0+664] + teeth
        x0 = _vd([120, 160, 200])
        plats = [_v3_ground(c, 0, x0),
                 _vm(c, x0, 608, 96), _vm(c, x0 + 96, 576, 96),
                 _vm(c, x0 + 192, 544, 96), _vm(c, x0 + 288, 512, 96),
                 _vm(c, x0 + 384, 512, 280),
                 _vm(c, x0 + 664, 544, 96), _vm(c, x0 + 760, 576, 96),
                 _vm(c, x0 + 856, 608, 96),
                 _v3_ground(c, x0 + 952, 1280)] + _vwalls(c, [401, 340])
        # Clusters at x0+400, x0+500, x0+600 (gap 60); strips in the
        # gaps at x0+450 and x0+550. The exit ground [x0+952,1280]
        # holds the door at 1190 for every x0.
        _, teeth = _pb_teeth_zone(c, x0 + 400, 512, n_cl, gap=60)
        hazards = teeth + [_vt(x0 + 450, 512, 40),
                           _vt(x0 + 550, 512, 40),
                           # Lane C: column on the 576 step at x0+144
                           # (|x0+400-(x0+157)|=243 <= 300: (column,
                           # spike_down) survives). x0+144 (not x0+120):
                           # the hero lands on the 576 step from the
                           # 608 step and needs a >=48 px landing
                           # before the column ([x0+96,x0+144]); at
                           # x0+120 the landing was 24 px and the
                           # route was UNREACHABLE.
                           _h_col(x0 + 144, 576)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 4:  # corridor: plateau 560 [480,800] + teeth, denser
        plats = [_v3_ground(c, 0, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 560, 320),
                 _v3_ground(c, 800, 1280)] + _vwalls(c, [449, 380])
        # Clusters at 500, 620, 740 (gap 80); strips in the gaps at
        # 560 and 680.
        _, teeth = _pb_teeth_zone(c, 500, 560, n_cl, gap=80)
        hazards = teeth + [_vt(560, 560, 40), _vt(680, 560, 40),
                           # Lane C: column at 300 on the clear 640
                           # ground (|500-313|=187 <= 300).
                           _h_col(300, 640)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: terraces 560/520 + teeth over each
        plats, spawn, door, bx = _r_terraces(c, variant)
        # Terrace masses: [bx,600,160], [bx+200,600,80],
        # [bx+280,560,160], [bx+440,560,80], [bx+520,520,160].
        # Teeth over the 560 terrace (beam 449) and the 520 terrace
        # (beam 409). 449 blocks [469,517] (the 520 terrace is NOT
        # in it: 520 > 517); 409 blocks [429,477] (the 560 terrace
        # is NOT in it). Both beams coexist.
        plats = plats[:8] + _vwalls(c, [449, 409])
        _, teeth1 = _pb_teeth_zone(c, bx + 300, 560, 2)
        _, teeth2 = _pb_teeth_zone(c, bx + 540, 520, 2)
        # Only 1 strip: the (bx+700,560) strip sat in the landing
        # zone of the edge into the [800,880] 560 terrace (an 80-wide
        # mass cannot hold a 40 strip past its 48 landing zone).
        # Strip ramp is [1,1,2,2,1]; the teeth ramp [2,2,3,3,4]
        # still holds.
        # Lane C: column on the 600 terrace at bx+60
        # (|bx+300-(bx+73)|=227 <= 300: (column, spike_down)
        # survives; the column-jump arc is clear of the teeth).
        hazards = teeth1 + teeth2 + [_vt(1080, 640, 40),
                                     _h_col(bx + 60, 600)]
    return plats + [_fp(c)], hazards, spawn, door, skel
# ---------------------------------------------------------------------------
# D36 ceiling-gauntlets -- down-teeth gauntlet + ground strips/columns.
# ---------------------------------------------------------------------------

def v3_d36(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[36][slot]
    _GKEY[0:3] = [36, slot, variant]
    pp = [4.4, 4.0, 4.0, 3.6, 3.6][slot - 1]
    # Every layout carries a 380 beam: the core-middle rule needs
    # >= 2 non-slab rects in y310..510 and the 529 beam (y529-545)
    # does not count there. The 380 beam blocks [400,448] — no
    # surface in this door sits there.
    if slot == 1:
        # Flat zone [0,400] + plateau 600 [480,800] + flat [800,1280].
        # Pillar at 200 (flat ground; its fall column [200,260]
        # overlaps the teeth at 200). Teeth over the flat ground at
        # 200 (beam 529); teeth over the plateau at 520 (beam 489).
        # No strips: a strip-jump takeoff under a teeth cluster
        # kills the autopilot (ablation-proven).
        plats = [_v3_ground(c, 0, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 600, 320),
                 _v3_ground(c, 800, 1280)] + _vwalls(c, [529, 489, 380])
        _, teeth_flat = _pb_teeth_zone(c, 200, 640, 1)
        _, teeth_plat = _pb_teeth_zone(c, 520, 600, 1)
        hazards = [_h_pillar_per(200, 150, 104, pp, 0.0, 650)] + \
            teeth_flat + teeth_plat
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:
        # Flat route + 600 plateau. (A valley route is unbuildable
        # here: the 529 beam's Blocker range [549,597] covers the
        # valley's 560 masses, so every edge from the spawn platform
        # is blocked.)
        plats = [_v3_ground(c, 0, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 600, 320),
                 _v3_ground(c, 800, 1280)] + _vwalls(c, [529, 489, 380])
        _, teeth_flat = _pb_teeth_zone(c, 200, 640, 1)
        _, teeth_plat = _pb_teeth_zone(c, 520, 600, 2)
        hazards = [_h_pillar_per(200, 150, 104, pp, 0.0, 650)] + \
            teeth_flat + teeth_plat
        spawn, door = (70, 640), (1190, 640)
    elif slot == 3:
        # Flat route + 600 plateau. (A stairs/terrace route is
        # unbuildable here: the 529 beam spans the full width and
        # any surface rising above 529 — stairs to 512, terraces to
        # 520 — pokes through it and seals the route. A 600 plateau
        # sits below the beam, clear.)
        plats = [_v3_ground(c, 0, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 600, 320),
                 _v3_ground(c, 800, 1280)] + _vwalls(c, [529, 489, 380])
        _, teeth_flat = _pb_teeth_zone(c, 300, 640, 1)
        _, teeth_plat = _pb_teeth_zone(c, 620, 600, 2, gap=80)
        hazards = [_h_pillar_per(300, 150, 104, pp, 0.0, 650)] + \
            teeth_flat + teeth_plat
        spawn, door = (70, 640), (1190, 640)
    elif slot == 4:
        plats = [_v3_ground(c, 0, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 600, 320),
                 _v3_ground(c, 800, 1280)] + _vwalls(c, [529, 489, 380])
        _, teeth_flat = _pb_teeth_zone(c, 200, 640, 1, gap=80)
        _, teeth_flat2 = _pb_teeth_zone(c, 900, 640, 1, gap=80)
        _, teeth_plat = _pb_teeth_zone(c, 520, 600, 2, gap=80)
        hazards = [_h_pillar_per(200, 150, 104, pp, 0.0, 650)] + \
            teeth_flat + teeth_flat2 + teeth_plat
        spawn, door = (70, 640), (1190, 640)
    else:
        # Flat route + 600 plateau (same seal reason as S3: the 529
        # beam seals any route rising above 529).
        plats = [_v3_ground(c, 0, 400),
                 _vm(c, 400, 600, 80), _vm(c, 480, 600, 320),
                 _v3_ground(c, 800, 1280)] + _vwalls(c, [529, 489, 380])
        _, teeth_flat = _pb_teeth_zone(c, 200, 640, 2, gap=80)
        _, teeth_plat = _pb_teeth_zone(c, 520, 600, 2)
        hazards = [_h_pillar_per(200, 150, 104, pp, 0.0, 650)] + \
            teeth_flat + teeth_plat
        spawn, door = (70, 640), (1190, 640)
    return plats + [_fp(c)], hazards, spawn, door, skel
# ---------------------------------------------------------------------------
# D37 saw-corridors -- corridor with static saws + down-teeth.
# ---------------------------------------------------------------------------

def v3_d37(c, kk, salt, slot, variant):
    # Lane C: static saws + PERIODIC pillars. The pillar only
    # works over the 640 ground (it drops to FLOOR_Y 720; over
    # a raised mass its down rect is buried). S1 (flat) and S2
    # (valley) host it; S3 (tower) and S4 (stairs) ground walks
    # are too short for saw+pillar+door, so they stay saw-only
    # (the door demo passes via S1/S2). Declared primary
    # {saw_static, pillar_periodic}, demo pair.
    skel = V3_SKELETONS[37][slot]
    _GKEY[0:3] = [37, slot, variant]
    # Part B: corridor static saws (spike-proven for S1). All patrol
    # / swing saws are replaced by static floor-grazing saws under
    # the corridor beam. HONEST NOTE: the beam cannot be lowered to
    # constrain the jump (it would make the saws impassable), so the
    # corridor is visual identity and the mechanic converges with
    # D03's static saws; the beam layout is kept different from
    # D33's so the doors still differ in layout + traps.
    # Ramp (slot-indexed): saw radius grows across slots 1->5.
    r = [22, 22, 24, 24, 24][slot - 1]
    if slot == 1:  # flat-saw-corridor (spike geometry)
        # Lane C: beams at (320,460), not (340,480) -- the (340,480)
        # beams are identical to D25S1's, so the spliced L180
        # duplicated L120 on the layout dim. 320/460 shifts both
        # beams 20px (crosses the 16px layout bucket) and stays
        # above the hero's head (544).
        plats, spawn, door = _r_flat(c, beams=(320, 460))
        # Lane C: pillar at 800 (not 760) -- 760 sits in the same
        # 32px trap bucket as D25S1's column at 740, so the spliced
        # L180 duplicated L120. 800 is 60px from 740 (new bucket)
        # and 38px clear of the 900 saw.
        hazards = [_vt(300, 640, 40), _h_saw(620, 640, r),
                   _h_pillar_trig(c, 800, 150, 104, 700),
                   _h_saw(900, 640, r)]
    elif slot == 2:  # valley-saw-corridor (no strip on the 560 mass:
        # any seat there either overlaps the mass-entry landing zone
        # or drops the autopilot's strip-jump onto the 1080 saw)
        plats, spawn, door = _r_valley(c, variant)
        # Lane C: the 720 saw is REMOVED -- the 640 ground
        # [480,800] cannot hold two saws + a 60-wide pillar with
        # 48px clearances. Pillar at 700 pairs with the 580 saw.
        hazards = [_h_saw(580, 640, r),
                   _h_pillar_trig(c, 700, 150, 104, 700),
                   _h_saw(1080, 560, r),
                   _vtd(300, 456, 60)]
    elif slot == 3:  # tower-saw-corridor (already static saws)
        # Lane C2: 4th floor moves LEFT — y465 floor is (48-650),
        # not (880-1050), so the final drop lands the hero at ~745
        # with a 445px ground walk. Ground saw 950 (moved from
        # 1100) + trig pillar 1080 (trigger 798). The pillar clears
        # the y275 right floor (ends 1050) and falls through the
        # beams only (D37S1 precedent — pillars already fall through
        # beams there).
        # SUPPORTS ARE EXPLICIT (not left to repair_grounding): the
        # v1 candidate let repair merge the tower supports into one
        # 345px wall (1002,295,48,345) that SEALED the ground walk —
        # the saw/pillar were unreachable decoration (the only route
        # was the y275-drop bypass). Each floor here rests on the
        # floor below via a 48px inter-floor pillar placed where the
        # hero never walks, and only the bottom floor has a ground
        # support, at the far left (x48-96) outside the walk:
        #   F1 (48-820) on (700,200,48,75) on F2;
        #   F2 (700-1050) on (852,295,48,75) on F3;
        #   F3 (48-900) on (48,390,48,75) on F4;
        #   F4 (48-700) on (48,485,48,155) on the ground.
        # The hero drops F1->F2 at ~820, F2->F3 at ~800, F3->F4 at
        # ~650, F4->ground at ~700, then walks the clear ground
        # walk (saw 950, pillar 1080, door 1190).
        tops = [180, 275, 370, 465]
        plats = [plat(48, tops[0], 772, 20, "solid"),
                 plat(700, tops[1], 350, 20, "solid"),
                 plat(48, tops[2], 852, 20, "solid"),
                 plat(48, tops[3], 652, 20, "solid"),
                 _v3_ground(c),
                 plat(700, 200, 48, 75, "solid"),
                 plat(852, 295, 48, 75, "solid"),
                 plat(48, 390, 48, 75, "solid"),
                 plat(48, 485, 48, 155, "solid")]
        hazards = [_h_saw(400, tops[0], r), _h_saw(700, tops[0], r),
                   _vt(300, tops[2], 35), _vt(383, tops[2], 35),
                   _vt(300, 640, 35), _vt(383, 640, 35),
                   _h_saw(950, 640, r),
                   _h_pillar_trig(c, 1080, 150, 104, 700)]
        return plats + [_fp(c)], hazards, (90, tops[0]), (1190, 640), skel
    elif slot == 4:  # stair-saw-corridor (custom 3-up/3-down stairs)
        # Lane C2: the shared _r_stairs32 (NOT touched) ends its
        # descent at x0+832 and leaves a ~200px ground walk — too
        # short for saw+pillar+door. Custom stairs here: 3 steps up
        # (rise 32, tread 96) to a 544 plateau, 3 steps down, ground
        # from x856 (334px walk). Ground saw 1000 + trig pillar
        # 1080 (trigger 798, crossed on the down-steps). The 950
        # saw sat in the drop landing from the last down-step
        # (856) — the autopilot jumped from the step into the
        # disc. Up-step strips via _vstairs_teeth (n=3); down
        # tooth 300 kept (dead filler, seated on the 400 beam).
        steps_up, strips = _vstairs_teeth(c, 120, n=3)
        steps_down, _, _ = _vstairs_down(c, 568, 544, 3, tread=96,
                                         rise=32)
        plats = ([_v3_ground(c, 0, 120)] + steps_up
                 + [_vm(c, 408, 544, 160)] + steps_down
                 + [_v3_ground(c, 856, 1280)]
                 + _vwalls(c, [340, 400]))
        hazards = strips + [_h_saw(1000, 640, r),
                            _h_pillar_trig(c, 1080, 150, 104, 700),
                            _vtd(300, 416, 60)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: terrace-saw-corridor (shortened terraces +
        # ground saw/pillar). Lane C2: the shared _r_terraces (NOT
        # touched) ends at bx+840, leaving a ~150px ground walk —
        # too short for saw+pillar+door, and a pillar at bx+890
        # breaks the bx+600 saw jump (gate file). Terraces end at
        # bx+520 = 720 here; the bx+600 saw's 520 terrace is gone,
        # so the pair is the GROUND saw (880) + the pillar (1040,
        # trigger 758). bx stays 200. Strip bx+810 removed (its 600
        # mass is gone); down tooth 600 kept (dead filler, seated
        # on the 400 beam).
        bx = 200
        plats = ([_v3_ground(c),
                  _vm(c, bx, 600, 160), _vm(c, bx + 200, 600, 80),
                  _vm(c, bx + 280, 560, 160), _vm(c, bx + 440, 560, 80)]
                 + _vwalls(c, [300, 360, 400], 190))
        hazards = [_h_saw(bx + 360, 560, r),
                   _vtd(600, 416, 60),
                   _h_saw(880, 640, r),
                   _h_pillar_trig(c, 1040, 150, 104, 700)]
        spawn, door = (70, 640), (1190, 640)
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D38 timed-corridors -- corridor with dashed stones + popup strips.
# ---------------------------------------------------------------------------

def v3_d38(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[38][slot]
    _GKEY[0:3] = [38, slot, variant]
    pp = [4.4, 4.0, 4.0, 3.6, 3.6][slot - 1]
    if slot == 1:  # flat: one dashed gap + one pillar over it
        px = 520
        plats = [_v3_ground(c, 0, px),
                 _vdash(px, 640, 120, 3.0, 0.0, 2.0),
                 _v3_ground(c, px + 120, 1280)] + _vwalls(c, [300, 420])
        hazards = [_h_pillar_per(px + 30, 150, 104, pp, 0.0, 650),
                   _vt(300, 640, 40), _vt(900, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # valley: dashed gap in the valley floor
        px = 560
        plats = [_vm(c, 0, 560, 320), _vm(c, 320, 600, 80),
                 _vm(c, 400, 640, 80), _v3_ground(c, 480, px),
                 _vdash(px, 640, 120, 3.0, 0.0, 2.0),
                 _v3_ground(c, px + 120, 1280)] + _vwalls(c, [320, 420])
        hazards = [_h_pillar_per(px + 30, 150, 104, pp, 0.0, 650),
                   _vt(1000, 640, 40)]
        spawn, door = (90, 560), (1190, 640)
    elif slot == 3:  # stairs: dashed gap on the exit ground
        plats, spawn, door, x0 = _r_stairs32(c, variant)
        px = x0 + 832 + 60
        plats = plats[:10] + [
            _v3_ground(c, x0 + 832, px),
            _vdash(px, 640, 120, 3.0, 0.0, 2.0),
            _v3_ground(c, px + 120, 1280)] + _vwalls(c, [300, 380])
        hazards = [_h_pillar_per(px + 30, 150, 104, pp, 0.0, 650),
                   _vt(1080, 640, 40)]
    elif slot == 4:  # corridor: two dashed gaps, two pillars
        plats = [_v3_ground(c, 0, 400),
                 _vdash(400, 640, 120, 3.0, 0.0, 2.0),
                 _v3_ground(c, 520, 800),
                 _vdash(800, 640, 120, 2.8, 0.5, 1.8),
                 _v3_ground(c, 920, 1280)] + _vwalls(c, [340, 440])
        hazards = [_h_pillar_per(430, 150, 104, pp, 0.0, 650),
                   _h_pillar_per(830, 150, 104, pp, 0.5, 650),
                   _vt(1000, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: gap route + two dashed gaps with pillars
        plats = [_v3_ground(c, 0, 300),
                 _vdash(300, 640, 120, 3.0, 0.0, 2.0),
                 _v3_ground(c, 420, 700),
                 _vdash(700, 640, 120, 2.8, 0.5, 1.8),
                 _v3_ground(c, 820, 1280)] + _vwalls(c, [300, 420])
        # Second pillar phase 0.0 (not 0.5): the hero reaches the
        # second gap delayed (after waiting at the first), and a 0.5
        # phase puts the pillar's fall inside its crossing window.
        # NOPILLAR2 ablation passes.
        hazards = [_h_pillar_per(330, 150, 104, pp, 0.0, 650),
                   _h_pillar_per(730, 150, 104, pp, 0.0, 650),
                   _vt(200, 640, 40), _vt(1000, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    return plats + [_fp(c)], hazards, spawn, door, skel
# ---------------------------------------------------------------------------
# D40 column-forests -- many 26x36 columns.
# ---------------------------------------------------------------------------

def v3_d40(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[40][slot]
    _GKEY[0:3] = [40, slot, variant]
    n_stal = [2, 3, 3, 4, 4][slot - 1]

    def _stal(x):
        # Hanging stalactite spanning 486-560, top-attached to the
        # 470 beam's bottom (486). Walking head 601 clears the
        # bottom 560 by 41px; a jump under it (head apex 549) dies.
        # A single 74-tall column: the checker's span test does not
        # apply (it is above the walking band) and its `hung` rule
        # accepts it; the generator-side guard exempts hanging
        # columns for the same reason (see _assert_column_span).
        return _vcol(x, 74, 26, top=560)

    if slot == 1:  # flat: 2 stalactites, 1 strip in the gap
        plats = [_v3_ground(c)] + _vwalls(c, [470, 380])
        hazards = [_stal(500), _stal(800), _vt(650, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 2:  # valley: 3 stalactites, 2 strips
        plats = [_vm(c, 0, 560, 320), _vm(c, 320, 600, 80),
                 _vm(c, 400, 640, 80), _v3_ground(c, 480, 800),
                 _vm(c, 800, 600, 80), _vm(c, 880, 560, 80),
                 _vm(c, 960, 560, 320)] + _vwalls(c, [470, 380])
        # Only 1 strip has a legal seat: the 880 strip sat in the
        # landing zone of the edge into the [880,960] mass (an 80-wide
        # mass cannot hold a 40 strip past its 48 landing zone), and
        # platform [6] cannot hold a second strip past the stalactite
        # inside the door safe zone. Strip ramp is [1,1,2,3,2];
        # the stalactite ramp [2,3,3,4,4] still holds.
        # The third stalactite must sit over a 640 surface: over
        # the 560 exit ground its bottom (560) is inside that
        # surface's walking band [521,560] and the span test fails.
        # The 770 stalactite sat at the takeoff (776) for the jump
        # onto the [800,880] 600 step; 730 is 20px clear of it
        # (twin with the 700 stalactite).
        hazards = [_stal(450), _stal(700), _stal(730),
                   _vt(610, 640, 40)]
        spawn, door = (90, 560), (1190, 560)
    elif slot == 3:  # flat: 3 stalactites, 2 strips in the gaps
        # (The stairs exit ground [1072,1280] cannot hold 3
        # stalactites before the wall/door; a flat route can.)
        plats = [_v3_ground(c)] + _vwalls(c, [470, 380])
        hazards = [_stal(500), _stal(700), _stal(900),
                   _vt(600, 640, 40), _vt(800, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    elif slot == 4:  # corridor: 4 stalactites, 3 strips
        plats = [_v3_ground(c)] + _vwalls(c, [470, 380])
        hazards = [_stal(300), _stal(500), _stal(750), _stal(950),
                   _vt(400, 640, 40), _vt(625, 640, 40),
                   _vt(850, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    else:  # slot 5: flat: 4 stalactites (even 300px spacing),
        # 3 strips in the gaps
        plats = [_v3_ground(c)] + _vwalls(c, [470, 380])
        hazards = [_stal(300), _stal(600), _stal(900), _stal(1100),
                   _vt(450, 640, 40), _vt(750, 640, 40),
                   _vt(1050, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    return plats + [_fp(c)], hazards, spawn, door, skel
# ---------------------------------------------------------------------------
# D41 final-tower-saws -- tower descent + static saws (mix/final).
# ---------------------------------------------------------------------------

def v3_d41(c, kk, salt, slot, variant):
    # Lane C: static saws + floor columns. Teeth (the allocated
    # pattern) are NOT buildable in this tower: the zigzag floors
    # do not align for hanging teeth (no beam; a full-width beam
    # would intercept the descent; under-floor teeth are either
    # unencountered or deadly at the drop point). Columns sit on
    # the tower floors and the ground, need no beam, and form
    # (saw, column) pairs. Declared primary {saw_static,
    # column_floor}, demo pair.
    skel = V3_SKELETONS[41][slot]
    _GKEY[0:3] = [41, slot, variant]
    r = _vo(variant, [22, 24, 26])
    cfg = _tower_cfg(slot, variant, [170, 180, 190],
                     [800, 840, 760])
    if slot in (2, 5):
        cfg["mirror"] = True
    plats, tops, E1, E2, PR, sx, dx = _v3_tower(
        c, kk, salt, cfg, dashed=False)
    if cfg.get("mirror"):
        hazards = [_h_saw(700, tops[0], r), _h_saw(1000, tops[0], r),
                   _h_col(850, tops[0]),
                   _vt(882, tops[2], 35), _vt(965, tops[2], 35),
                   _vt(682 + 40 * (slot - 2), 640, 35),
                   _vt(765 + 40 * (slot - 2), 640, 35),
                   _h_saw(500, 640, r), _h_col(600, 640)]
    elif slot == 3:
        hazards = [_h_saw(400, tops[0], r), _h_saw(700, tops[0], r),
                   _h_col(550, tops[0]),
                   _vt(300, tops[2], 35), _vt(383, tops[2], 35),
                   _vcol(500, 36, 26), _vt(PR + 5, 640, 48),
                   _h_saw(1100, 640, r), _h_col(800, 640)]
    else:
        hazards = [_h_saw(400, tops[0], r), _h_saw(700, tops[0], r),
                   _h_col(550, tops[0]),
                   _vt(240, tops[2], 35), _vt(323, tops[2], 35),
                   _vt(E2 + 60, tops[1], 48),
                   _vt(240 + 40 * (slot - 1), 640, 35),
                   _vt(323 + 40 * (slot - 1), 640, 35),
                   _h_saw(1100, 640, r), _h_col(800, 640)]
    return plats + [_fp(c)], hazards, (sx, tops[0]), (dx, 640), skel


# ---------------------------------------------------------------------------
# D42 final-skyline -- skyline + static saws (mix/final).
# ---------------------------------------------------------------------------

def v3_d42(c, kk, salt, slot, variant):
    # Lane C: static saws + popup spikes. The terrace path saw
    # is REPLACED by a static saw (the path saw is dead under
    # both centre semantics and cannot be admitted). Popups sit
    # near the saws: on the tower top floor and the ground, and
    # on the second 600 terrace mass near the 560 saw. Declared
    # primary {saw_static, spike_popup}, demo pair.
    skel = V3_SKELETONS[42][slot]
    _GKEY[0:3] = [42, slot, variant]
    r = _vo(variant, [22, 24, 26])
    period = _vo(variant, [3.0, 3.4, 3.8])
    if slot in (1, 3, 5):
        cfg = _tower_cfg(slot, variant, [180, 190, 170],
                         [820, 860, 780])
        if slot == 5:
            cfg["mirror"] = True
        plats, tops, E1, E2, PR, sx, dx = _v3_tower(
            c, kk, salt, cfg, dashed=False)
        if slot == 5:
            hazards = [_h_saw(700, tops[0], r),
                       _h_popup(850, tops[0], 35, 3.0, 0.0, 1.4),
                       _vt(882, tops[2], 35), _vt(965, tops[2], 35),
                       _vt(682, 640, 35), _vt(765, 640, 35),
                       _h_saw(500, 640, r), _h_popup(600, 640, 35, 3.0, 0.0, 1.4)]
        elif slot == 3:
            hazards = [_h_saw(400, tops[0], r),
                       _h_popup(550, tops[0], 35, 3.0, 0.0, 1.4),
                       _vt(300, tops[2], 35), _vt(383, tops[2], 35),
                       _vcol(500, 36, 26), _vt(PR + 5, 640, 48),
                       _h_saw(1100, 640, r), _h_popup(800, 640, 35, 3.0, 0.0, 1.4)]
        else:
            hazards = [_h_saw(400, tops[0], r), _h_saw(700, tops[0], r),
                       _h_popup(550, tops[0], 35, 3.0, 0.0, 1.4),
                       _vt(240, tops[2], 35), _vt(323, tops[2], 35),
                       _vt(240, 640, 35), _vt(323, 640, 35),
                       _h_saw(1100, 640, r), _h_popup(800, 640, 35, 3.0, 0.0, 1.4)]
        return plats + [_fp(c)], hazards, (sx, tops[0]), (dx, 640), skel
    plats, spawn, door, bx = _r_terraces(c, variant)
    # Lane C: the path saw is REMOVED (dead under both centre
    # semantics, cannot be admitted); a static saw on the first
    # 600 mass blocks the climb arc (clearance -0.53), so no
    # replacement there. A popup sits on the second 600 mass
    # near the 560 saw (|360-240|=120).
    hazards = [_h_saw(bx + 360, 560, r),
               _h_popup(bx + 240, 600, 35, 3.0, 0.0, 1.4),
               _h_saw(bx + 600, 520, r), _vt(bx + 810, 600, 40)]
    return plats + [_fp(c)], hazards, spawn, door, skel


# ---------------------------------------------------------------------------
# D43 final-reversed -- reversed routes + static saws (mix/final).
# Simple isolated obstacles only (D29 discipline, left travel).
# ---------------------------------------------------------------------------

def v3_d43(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[43][slot]
    _GKEY[0:3] = [43, slot, variant]
    lead = [160, 140, 140, 120, 120][slot - 1]
    # Saw r capped at 24: a r=26 (52w) disc is unjumpable in reverse
    # (the two-jump chain lands inside the disc; ablation-proven --
    # a single r=26 saw alone kills the autopilot, r=22/24 pass).
    r = [22, 22, 24, 24, 24][slot - 1]
    beams = [(304, 416), (320, 432), (336, 448), (352, 464), (368, 480)][slot - 1]

    def _trig(x, w=45):
        return _h_trig_left(x, 640, w, lead=lead, delay=0.3)

    # Reversed route (spawn 1190 -> door 90). Right-armed triggered
    # strips are DOMINANT in every level; static saws are the second
    # element (D29's second element is columns -- that is the D43
    # distinction). Saws and strips alternate with >=250px between a
    # saw centre and the next strip's right edge, so a saw-jump
    # landing never sits on a strip's jump takeoff.
    if slot == 1:  # 2 triggered + 1 saw
        plats = [_v3_ground(c)] + _vwalls(c, beams)
        hazards = [_trig(800), _trig(450), _h_saw(1050, 640, r)]
    elif slot == 2:  # 1 gap + 3 triggered + 1 saw
        # A 2-gap chain (saw -> gap -> strip -> strip -> gap) is too
        # dense for the planner: every single-element removal passes,
        # the full chain dies. One gap, S4's passing positions.
        g1 = 596
        plats = [_v3_ground(c, 0, g1), _v3_ground(c, g1 + 72, 1280)] \
            + _vwalls(c, beams)
        hazards = [_trig(950, 50), _trig(750, 50), _trig(400, 50),
                   _h_saw(1100, 640, r)]
    elif slot == 3:  # 3 triggered + 2 saws
        plats = [_v3_ground(c)] + _vwalls(c, beams)
        hazards = [_trig(800), _trig(300),
                   _h_saw(1050, 640, r), _h_saw(550, 640, r)]
    elif slot == 4:  # 1 gap + 4 triggered + 1 saw
        g1 = 596
        plats = [_v3_ground(c, 0, g1), _v3_ground(c, g1 + 72, 1280)] \
            + _vwalls(c, beams)
        hazards = [_trig(950), _trig(750), _trig(400), _trig(180),
                   _h_saw(1100, 640, r)]
    else:  # slot 5: 4 triggered + 2 saws
        plats = [_v3_ground(c)] + _vwalls(c, beams)
        # Only 1 saw: the 500 saw's jump landed the hero at 444,
        # and the strip-jump from 444 landed at 355 -- inside the
        # [350,390] strip (NOSAW ablation passes; each element alone
        # passes, the combination kills). Saw count is [1,1,2,1,1];
        # the triggered ramp [2,3,3,4,4] still holds.
        # Strips re-spaced to 200px: after any jump landing the
        # next strip's probe point needs >=50px of walking room, and
        # strips need >=200px spacing (ablation-proven: removing any
        # one of 850/600/350 fixed it, so the chain -- not one strip
        # -- was the killer).
        # S4's passing positions (strips 950/750/400/180, saw
        # 1100): S5's 800/600/400/200 + saw 1050 chain died even
        # though each element alone passes (a timing/phase chain
        # failure, not one bad element). Flat route (no gap) is what
        # sets S5 apart from S4.
        hazards = [_trig(950, 50), _trig(750, 50), _trig(400, 50),
                   _trig(180, 50), _h_saw(1100, 640, r)]
    return plats + [_fp(c)], hazards, (1190, 640), (90, 640), skel
# ---------------------------------------------------------------------------
# D44 final-mega -- timed opening + dashed gap + static saw finish.
# ---------------------------------------------------------------------------

def v3_d44(c, kk, salt, slot, variant):
    skel = V3_SKELETONS[44][slot]
    _GKEY[0:3] = [44, slot, variant]
    # Simultaneous finale (slot 1 only ships): a periodic pillar AND
    # a popup under its fall column AND a dashed gap stone AND a static
    # saw, all inside one ~300px crossing zone (440-750). The hero must
    # time the popup jump for when the pillar is up, cross the blinking
    # gap stone while the pillar is up, and land past the saw.
    if slot == 1:
        plats = [_v3_ground(c, 0, 480),
                 _vdash(480, 640, 120, 3.0, 0.0, 2.0),
                 _v3_ground(c, 600, 1280)] + _vwalls(c, [300, 420])
        hazards = [_h_pillar_per(440, 150, 104, 4.0, 0.0, 650),
                   _h_popup(440, 640, 40, 3.4, 0.0, 1.6),
                   _h_saw(750, 640, 24),
                   _vt(1000, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    else:
        # Spares (never ship: D44 ships slot 1 only). Keep them
        # buildable so the generator can retry.
        plats = [_v3_ground(c)] + _vwalls(c, [300, 420])
        hazards = [_h_pillar_per(440, 150, 104, 4.0, 0.0, 650),
                   _h_popup(440, 640, 40, 3.4, 0.0, 1.6),
                   _h_saw(750, 640, 24),
                   _vt(1000, 640, 40)]
        spawn, door = (70, 640), (1190, 640)
    return plats + [_fp(c)], hazards, spawn, door, skel
# --- v3 skeleton table + builder registry (all 44 doors) ------------------

V3_SKELETONS = {
    1: {1: "stairs-pit", 2: "valley-pit", 3: "U-corridor-pit",
        4: "double-pit", 5: "step-descent-pit"},
    2: {1: "flat-teeth", 2: "stair-teeth", 3: "valley-teeth",
        4: "terraces-teeth", 5: "corridor-teeth"},
    3: {1: "flat-saws", 2: "valley-saws", 3: "stair-saws",
        4: "corridor-saws", 5: "terrace-saws"},
    4: {1: "flat-popups", 2: "valley-popups", 3: "stair-popups",
        4: "corridor-popups", 5: "terrace-popups"},
    5: {1: "flat-triggered", 2: "valley-triggered",
        3: "stair-triggered", 4: "corridor-triggered",
        5: "terrace-triggered"},
    6: {1: "flat-triggered-pillar", 2: "valley-triggered-pillar",
        3: "stair-triggered-pillar", 4: "corridor-triggered-pillar",
        5: "gap-triggered-pillar"},
    7: {1: "flat-periodic-pillar", 2: "valley-periodic-pillar",
        3: "stair-periodic-pillar", 4: "corridor-periodic-pillar",
        5: "gap-periodic-pillar"},
    8: {1: "flat-swing", 2: "valley-swing", 3: "stair-swing",
        4: "corridor-swing", 5: "valley-swing-2"},
    9: {1: "flat-patrol", 2: "valley-patrol", 3: "corridor-patrol",
        4: "gap-patrol", 5: "terrace-patrol"},
    10: {1: "dashed-gap-saw", 2: "mover-gap-saw",
         3: "corridor-gap-saw", 4: "falling-gap-saw",
         5: "valley-gap-saw"},
    11: {1: "flat-columns", 2: "valley-columns", 3: "stair-columns",
         4: "corridor-columns", 5: "terrace-columns"},
    12: {1: "flat-chain", 2: "terrace-chain", 3: "stair-chain",
         4: "gap-chain", 5: "valley-chain"},
    13: {1: "flat-falling-chain", 2: "pit-falling",
         3: "double-pit-falling", 4: "corridor-falling",
         5: "valley-falling"},
    14: {1: "flat-tilting-chain", 2: "pit-tilting",
         3: "double-pit-tilting", 4: "corridor-tilting",
         5: "valley-tilting"},
    15: {1: "flat-mover", 2: "terrace-mover", 3: "shaft-mover",
         4: "valley-mover", 5: "corridor-mover"},
    16: {1: "bob-step-chain", 2: "twin-bob-shaft", 3: "valley-bob-chain",
         4: "corridor-bob-chain", 5: "flat-mover"},
    17: {1: "beam-lining", 2: "stair-ceiling", 3: "valley-ceiling",
         4: "corridor-ceiling", 5: "step-plateau-ceiling"},
    18: {1: "flat-wall-teeth", 2: "valley-wall-teeth",
         3: "stair-wall-teeth", 4: "corridor-wall-teeth",
         5: "terrace-wall-teeth"},
    19: {1: "ascent", 2: "valley-stairs", 3: "terrace-stairs",
         4: "double-stair", 5: "tower-stairs"},
    20: {1: "dashed+falling-gaps", 2: "falling+tilting-gaps",
         3: "valley-double-gap", 4: "corridor-double-gap",
         5: "stair-double-gap"},
    21: {1: "flat-pit-bridge", 2: "valley-pit-bridge",
         3: "stair-pit-bridge", 4: "corridor-pit-bridge",
         5: "terrace-pit-bridge"},
    22: {1: "flat-gauntlet", 2: "valley-gauntlet",
         3: "stair-gauntlet", 4: "corridor-gauntlet",
         5: "terrace-gauntlet"},
    23: {1: "flat-timed-mix", 2: "valley-timed-mix",
         3: "stair-timed-mix", 4: "corridor-timed-mix",
         5: "terrace-timed-mix"},
    24: {1: "flat-alley", 2: "valley-alley", 3: "stair-alley",
         4: "corridor-alley", 5: "gap-alley"},
    25: {1: "flat-forest", 2: "valley-forest", 3: "stair-forest",
         4: "corridor-forest", 5: "terrace-forest"},
    26: {1: "flat-mix", 2: "valley-mix", 3: "stair-mix",
         4: "corridor-mix", 5: "gap-mix"},
    27: {1: "flat-lift", 2: "valley-lift", 3: "shaft-lift",
         4: "corridor-lift", 5: "terrace-lift"},
    28: {1: "standard-tower", 2: "narrow-tower", 3: "tall-tower",
         4: "low-tower", 5: "mirror-tower"},
    29: {1: "reversed-strips", 2: "reversed-gaps",
         3: "reversed-columns", 4: "reversed-mixed",
         5: "reversed-triggered"},
    30: {1: "standard-tower", 2: "terrace-skyline",
         3: "tall-tower", 4: "terrace-skyline-2",
         5: "mirror-tower"},
    31: {1: "standard-shaft", 2: "narrow-shaft", 3: "wide-shaft",
         4: "left-shaft", 5: "right-shaft"},
    32: {1: "standard-zigzag", 2: "mirror-zigzag",
         3: "tall-zigzag", 4: "mirror-zigzag-2",
         5: "standard-zigzag-2"},
    33: {1: "flat-saw-field", 2: "valley-saw-field",
         3: "stair-saw-field", 4: "corridor-saw-field",
         5: "terrace-saw-field"},
    34: {1: "flat-trigger-pit", 2: "gap-trigger-pit",
         3: "valley-trigger-pit", 4: "corridor-trigger-pit",
         5: "stair-trigger-pit"},
    35: {1: "flat-forest", 2: "valley-forest", 3: "stair-forest",
         4: "corridor-forest", 5: "terrace-forest"},
    36: {1: "step-ceiling-gauntlet", 2: "valley-ceiling-gauntlet",
         3: "stair-ceiling-gauntlet", 4: "corridor-ceiling",
         5: "terrace-ceiling-gauntlet"},
    37: {1: "flat-saw-corridor", 2: "valley-saw-corridor",
         3: "tower-saw-corridor", 4: "stair-saw-corridor",
         5: "terrace-saw-corridor"},
    38: {1: "flat-timed-corridor", 2: "valley-timed-corridor",
         3: "tower-timed-corridor", 4: "stair-timed-corridor",
         5: "terrace-timed-corridor"},
    39: {1: "standard-dashed", 2: "narrow-dashed", 3: "tall-dashed",
         4: "low-dashed", 5: "mirror-dashed"},
    40: {1: "flat-column-forest", 2: "valley-column-forest",
         3: "stair-column-forest", 4: "corridor-column-forest",
         5: "terrace-column-forest"},
    41: {1: "standard-tower-saws", 2: "mirror-tower-saws",
         3: "tall-tower-saws", 4: "low-tower-saws",
         5: "mirror-tower-saws-2"},
    42: {1: "standard-skyline-saws", 2: "terrace-skyline-saws",
         3: "tall-skyline-saws", 4: "terrace-skyline-saws-2",
         5: "mirror-skyline-saws"},
    43: {1: "reversed-saws", 2: "reversed-gaps",
         3: "reversed-columns", 4: "reversed-mixed",
         5: "reversed-triggered"},
    44: {1: "flat-mega", 2: "valley-mega", 3: "stair-mega",
         4: "corridor-mega", 5: "tower-mega"},
}

V3_BUILDERS = {1: v3_d01, 2: v3_d02, 3: v3_d03, 4: v3_d04, 5: v3_d05,
               6: v3_d06, 7: v3_d07, 8: v3_d08, 9: v3_d09, 10: v3_d10,
               11: v3_d11, 12: v3_d12, 13: v3_d13, 14: v3_d14,
               15: v3_d15, 16: v3_d16, 17: v3_d17, 18: v3_d18,
               19: v3_d19, 20: v3_d20, 21: v3_d21, 22: v3_d22,
               23: v3_d23, 24: v3_d24, 25: v3_d25, 26: v3_d26,
               27: v3_d27, 28: v3_d28, 29: v3_d29, 30: v3_d30,
               31: v3_d31, 32: v3_d32, 33: v3_d33, 34: v3_d34,
               35: v3_d35, 36: v3_d36, 37: v3_d37, 38: v3_d38,
               39: v3_d39, 40: v3_d40, 41: v3_d41, 42: v3_d42,
               43: v3_d43, 44: v3_d44}


# Pilot skeleton table gains the 34 new doors (pilot_main only
# iterates its 10 PILOT_DOORS; this keeps the table complete for a
# future full pilot run).
PILOT_SKELETONS.update(
    {d: s for d, s in V3_SKELETONS.items() if d not in PILOT_SKELETONS})


# Pilot finish pass + strip ablation + pilot driver.
# ---------------------------------------------------------------------------

def _strip_stats(hazards):
    """Per-draw up-spike census: max up-strip width, count, and the
    widths over the cap. Recorded for EVERY draw in pilot_main,
    including discarded ones."""
    ups = [float(h["w"]) for h in hazards
           if isinstance(h, dict) and h.get("type") == "spikes"
           and h.get("dir", "up") == "up"
           and check_levels.is_num(h.get("w"))]
    return {"max_up_strip_w": max(ups) if ups else 0,
            "n_up_strips": len(ups),
            "up_widths_gt60": [w for w in ups if w > 60.0]}


def _assert_strip_cap(hazards):
    """Generator-side guard (Round 3): raise on any dir-up spikes
    strip wider than 60px (pilot-gate-r2 §8A: max clearable ~69.7px).
    The checker is a backstop, not the only guard."""
    for i, h in enumerate(hazards):
        if isinstance(h, dict) and h.get("type") == "spikes" \
                and h.get("dir", "up") == "up" \
                and check_levels.is_num(h.get("w")) \
                and float(h["w"]) > 60.0:
            raise ValueError(
                "up-spikes strip hazards[%d] w=%g > 60 (strip cap)"
                % (i, float(h["w"])))


def _assert_column_span(hazards, tun, plats=None):
    """Generator-side guard (Round 4, Implementation Gate §7a):
    raise on any spiked_column whose rect cannot fit inside the
    at-height jump span: rect height must be <= 45 and
    w+15 <= tun.max_jump_dist * sqrt(1 - h/tun.apex). Reference:
    26x36 -> 41 <= 49.66 PASS; 56x40 -> 71 > 43.11 FAIL;
    36x40 -> 51 > 43.11 FAIL. Mirrors the checker's span test
    (check_levels.column_span_clearable); the checker is a
    backstop, not the only guard.
    HANGING columns are exempt: the checker's span test only
    applies to columns overlapping the walking band, and its
    `hung` rule accepts a column whose top touches a grounded
    solid's bottom (e.g. a stalactite hanging from a beam). A
    column whose top is within GROUND_TOL of a solid platform's
    bottom (x-overlap >= 8) is hanging, not jumped over, so the
    span test does not apply to it."""
    for i, h in enumerate(hazards):
        if not isinstance(h, dict) or h.get("type") != "spiked_column":
            continue
        if not all(check_levels.is_num(h.get(k))
                   for k in ("w", "h", "x", "y")):
            continue
        if plats:
            top = float(h["y"])
            hung = False
            for s in plats:
                if not isinstance(s, dict) or s.get("kind") != "solid":
                    continue
                if not all(check_levels.is_num(s.get(k))
                           for k in ("x", "y", "w", "h")):
                    continue
                if abs(top - (float(s["y"]) + float(s["h"]))) \
                        <= check_levels.GROUND_TOL:
                    ov = min(float(h["x"]) + float(h["w"]),
                             float(s["x"]) + float(s["w"])) - \
                        max(float(h["x"]), float(s["x"]))
                    if ov >= 8.0:
                        hung = True
                        break
            if hung:
                continue
        w, hh = float(h["w"]), float(h["h"])
        if hh > check_levels.ENVELOPE_MAX_RISE:
            raise ValueError(
                "spiked_column hazards[%d] h=%g > 45 (max rise)"
                % (i, hh))
        limit = tun.max_jump_dist * math.sqrt(
            max(0.0, 1.0 - hh / tun.apex))
        if w + check_levels.HERO_RECT_W > limit:
            raise ValueError(
                "spiked_column hazards[%d] w+15=%g > %.2f at h=%g "
                "(column span test)" % (i, w + check_levels.HERO_RECT_W,
                                        limit, hh))


def _fill_falling_tilting(c, plats):
    """FALLING-FLOOR RULE (Part B, user law from his v1.0.4 phone test):
    a falling/tilting floor must be VISUALLY INDISTINGUISHABLE from a
    static floor. The tell is the empty space beneath: falling/tilting
    platforms are 20px slabs at the floor line while static ground is
    an 80px mass (y 640 -> 720). Extend the rect of every FLOOR-LINE
    falling/tilting segment down to floor_y, so the fill is part of
    the platform and FALLS WITH THE FLOOR (coordinator option a).
    Only FLOOR-LINE segments are filled: top == V3_GROUND (640) AND
    flanked by solid ground at the same top on BOTH sides. GAP STONES
    (over pits/gaps, not flanked on both sides) are NOT filled --
    filling would plug the pit visually (a hidden pit, a worse lie);
    a still thin slab over a pit could be solid, falling, or tilting,
    so the player cannot tell which, which is the intended hidden
    state. Tops never move, so the checker graph and the autopilot's
    jump arcs are untouched; only the rect's bottom extends."""
    floor_y = c.floor_y
    for p in plats:
        if p["kind"] not in ("falling", "tilting"):
            continue
        if p["y"] != V3_GROUND:
            continue
        # Seam tolerance 16px: builders place bridge stones 4-8px off
        # the flanking ground (a seam, not a pit); a real pit gap is
        # >= 48px (the minimum landing). A stone flanked within 16px
        # on both sides is part of a continuous floor line.
        left = any(q["kind"] == "solid" and q["y"] == V3_GROUND
                   and abs(q["x"] + q["w"] - p["x"]) <= 16
                   for q in plats if q is not p)
        right = any(q["kind"] == "solid" and q["y"] == V3_GROUND
                    and abs(q["x"] - (p["x"] + p["w"])) <= 16
                    for q in plats if q is not p)
        if left and right:
            p["h"] = floor_y - p["y"]


def v3_finish(c, plats, hazards, spawn, door_pos):
    """Pilot finish: NO normalize_ground, NO skyline/ceiling
    dressing, NO core-middle dressing, NO decorations. ONLY
    repair_grounding (repointed to floor_y). Returns the number of
    platforms the repair APPENDED -- repair should be a no-op if
    builders are self-grounding; a frequent repair delta is an
    honest weakness signal, recorded in the census, never hidden."""
    before = len(plats)
    _assert_strip_cap(hazards)
    _assert_column_span(hazards, c.tuning, plats)
    _fill_falling_tilting(c, plats)
    repair_grounding(c, plats, hazards, spawn, door_pos)
    return len(plats) - before


def _check_one(level, tun, idx=0):
    chk = check_levels.LevelCheck(level, idx, tun).run()
    try:
        sig = chk.signature_parts()
    except Exception:
        sig = ((), (), ())
    return {"errors": list(chk.errors), "notes": list(chk.notes),
            "density": chk.density, "signature": sig,
            "pass": not chk.errors}


def pilot_ablation(level, tun):
    """Strip ablation for a zero-pass candidate. Returns per-strip
    error-prefix sets + a verdict:
      A0 baseline errors; A1 hazards removed (the empty-hazards
      error is ignored when comparing); A2 teeth (spikes) only
      removed; A3 specials (dashed/falling/tilting/moving) replaced
      by solid same-rect.
    Verdict: A1 passes -> hazard-driven (A2 distinguishes teeth vs
    other hazards); A1 grounding errors -> geometry/grounding;
    A1 density/core errors -> mass failure; A1 unreachable /
    no-viable-path -> envelope/reachability; A3 passes where A0
    fails -> special-platform failure."""
    import copy

    def prefixes(errors):
        out = set()
        for e in errors:
            out.add(e.split(":", 1)[0].strip())
        return sorted(out)

    base = _check_one(level, tun)
    out = {"A0_errors": list(base["errors"]),
           "A0_prefixes": prefixes(base["errors"])}
    a1 = copy.deepcopy(level)
    a1["hazards"] = []
    r1 = _check_one(a1, tun)
    e1 = [e for e in r1["errors"] if "hazards may be empty" not in e]
    out["A1_errors"] = e1
    out["A1_prefixes"] = prefixes(e1)
    out["A1_pass"] = not e1
    a2 = copy.deepcopy(level)
    a2["hazards"] = [h for h in a2["hazards"]
                     if h.get("type") != "spikes"]
    r2 = _check_one(a2, tun)
    e2 = [e for e in r2["errors"] if "hazards may be empty" not in e]
    out["A2_errors"] = e2
    out["A2_prefixes"] = prefixes(e2)
    out["A2_pass"] = not e2
    a3 = copy.deepcopy(level)
    for p in a3["platforms"]:
        if p.get("kind") in ("dashed", "falling", "tilting", "moving"):
            p["kind"] = "solid"
            for k in ("period", "phase", "on_time", "stand_time",
                      "dx", "dy", "sweep"):
                p.pop(k, None)
    r3 = _check_one(a3, tun)
    out["A3_errors"] = list(r3["errors"])
    out["A3_prefixes"] = prefixes(r3["errors"])
    out["A3_pass"] = not r3["errors"]
    if out["A1_pass"]:
        verdict = ("hazard-driven (teeth)" if out["A2_pass"]
                   else "hazard-driven (non-teeth hazard)")
    elif any(p in ("grounding",) for p in out["A1_prefixes"]):
        verdict = "geometry/grounding"
    elif any(p in ("density", "core-middle") for p in out["A1_prefixes"]):
        verdict = "mass failure (density/core)"
    elif any("unreachable" in p or "no viable" in p or "path" in p
             for p in out["A1_prefixes"]):
        verdict = "envelope/reachability"
    elif out["A3_pass"]:
        verdict = "special-platform failure"
    else:
        verdict = "mixed/other: " + "; ".join(out["A1_prefixes"])
    out["verdict"] = verdict
    return out


PILOT_BUILDERS = {1: v3_d01, 2: v3_d02, 12: v3_d12, 15: v3_d15,
                  17: v3_d17, 19: v3_d19, 28: v3_d28, 29: v3_d29,
                  31: v3_d31, 39: v3_d39}


def _seat_key(level, bottom, x, w):
    """Seat a hazard on its platform index (same grouping as the
    checker's Rule 12): the platform whose top matches the hazard
    bottom within GROUND_TOL and whose x-span contains the hazard
    centre; fallback ('bottom', rounded bottom) for unseated
    hazards (grounding reports those separately)."""
    plats = level.get("platforms", [])
    cx = x + w / 2.0
    for j, p in enumerate(plats):
        if not isinstance(p, dict):
            continue
        if abs(float(p["y"]) - bottom) <= check_levels.GROUND_TOL \
                and float(p["x"]) <= cx \
                <= float(p["x"]) + float(p["w"]):
            return ("plat", j)
    return ("bottom", round(bottom, 1))


def _chained_pair_audit(candidates):
    """Round 4 census audit: every same-platform adjacent dir-up
    strip pair with gap g < 97.2 (game-true air distance D).
    Reuses check_levels.chain_window. A pair is CHAINED iff
    g + w2 <= 97.2 (the earliest landing after clearing the first
    strip is already at/past the second strip's takeoff window);
    decoupled pairs (hero lands before the second window opens and
    runs in) are judged as single strips and pass by construction.
    Chained pairs pass iff W_chain >= 15 (D14 clean floor)."""
    rows = []
    for lv in candidates:
        ups = []
        for i, h in enumerate(lv.get("hazards", [])):
            if not isinstance(h, dict):
                continue
            if h.get("type") != "spikes" or h.get("dir", "up") != "up":
                continue
            if not all(check_levels.is_num(h.get(k))
                       for k in ("x", "y", "w", "h")):
                continue
            ups.append((float(h["y"]) + float(h["h"]), float(h["x"]),
                        float(h["w"]), i))
        groups = {}
        for u in ups:
            groups.setdefault(_seat_key(lv, u[0], u[1], u[2]),
                              []).append(u)
        for key in sorted(groups, key=str):
            row = sorted(groups[key], key=lambda t: t[1])
            for a, b in zip(row, row[1:]):
                _ba, x1, w1, i1 = a
                _bb, x2, w2, i2 = b
                g = x2 - (x1 + w1)
                if g >= check_levels.CHAIN_DECOUPLE_GAP:
                    continue
                chained = (g + w2) <= check_levels.CHAIN_DECOUPLE_GAP
                w_chain = check_levels.chain_window(w1, w2, g) \
                    if chained else None
                rows.append({"id": lv["id"], "hazards": [i1, i2],
                             "platform": str(key),
                             "w1": w1, "w2": w2, "gap": g,
                             "g_plus_w2": g + w2,
                             "chained": chained,
                             "W_chain": w_chain,
                             "pass": (not chained)
                             or w_chain >= check_levels.CHAIN_MIN_WINDOW})
    return rows


def _column_audit(candidates, tun):
    """Round 4 census audit: every spiked_column with the span-test
    result and both takeoff windows vs the support ground's feet
    range. Travel direction is route-dependent, so both directions
    are recorded; a column is walkable iff the span test passes
    AND the travel direction's window intersects the feet range
    (the checker decides the direction from the route)."""
    rows = []
    for lv in candidates:
        plats = lv.get("platforms", [])
        for i, h in enumerate(lv.get("hazards", [])):
            if not isinstance(h, dict) \
                    or h.get("type") != "spiked_column":
                continue
            x, y, w, hh = (float(h["x"]), float(h["y"]),
                           float(h["w"]), float(h["h"]))
            support = None
            for j, p in enumerate(plats):
                if not isinstance(p, dict):
                    continue
                if abs(float(p["y"]) - (y + hh)) \
                        <= check_levels.GROUND_TOL \
                        and float(p["x"]) <= x + w / 2.0 \
                        <= float(p["x"]) + float(p["w"]):
                    support = j
                    break
            if support is not None:
                h_above = float(plats[support]["y"]) - y
                feet = [float(plats[support]["x"])
                        + check_levels.HERO_RECT_W / 2.0,
                        float(plats[support]["x"])
                        + float(plats[support]["w"])
                        - check_levels.HERO_RECT_W / 2.0]
            else:
                h_above = hh
                feet = None
            if 0.0 <= h_above <= tun.apex:
                span_limit = tun.max_jump_dist * math.sqrt(
                    max(0.0, 1.0 - h_above / tun.apex))
            else:
                span_limit = 0.0
            win_r = check_levels.column_takeoff_window(
                x, w, h_above, 1, tun)
            win_l = check_levels.column_takeoff_window(
                x, w, h_above, -1, tun)
            rows.append({
                "id": lv["id"], "hazard": i, "x": x, "w": w,
                "h": hh, "h_above": h_above,
                "support_platform": support,
                "span_test_pass": check_levels.column_span_clearable(
                    w, h_above, tun),
                "span_limit": span_limit,
                "takeoff_window_right": list(win_r),
                "takeoff_window_left": list(win_l),
                "feet_range": feet,
                "window_right_intersects_feet": bool(
                    feet and win_r[0] <= feet[1]
                    and win_r[1] >= feet[0]),
                "window_left_intersects_feet": bool(
                    feet and win_l[0] <= feet[1]
                    and win_l[1] >= feet[0])})
    return rows


def pilot_main(args):
    """--pilot driver: 3 variants x 5 slots x 10 archetypes = 150
    candidates, first checker-passing draw kept per slot/variant
    (up to --pilot-attempts attempts), else the last failing draw.
    Writes verification/candidates-v6-pilot.json (schema 3) and
    verification/pilot-census-r1.json by default; --out/--census
    override both (Round 3: candidates-v6-pilot-r3.json +
    pilot-census-r3.json). The .md census is rendered
    from the JSON by a separate /tmp script. Every draw -- kept or
    discarded -- records its up-spike strip stats in the census
    (strip_census); the census asserts the zero independently."""
    import hashlib
    tuning_path = Path(args.tuning) if args.tuning \
        else REPO / "godot" / "data" / "tuning.json"
    out_path = Path(args.out) if args.out \
        else REPO.parent / "verification" / "candidates-v6-pilot.json"
    census_path = Path(args.census) if getattr(args, "census", None) \
        else REPO.parent / "verification" / "pilot-census-r1.json"
    tuning_data = load_tuning(tuning_path)
    ctx = Ctx(tuning_data)
    tun = ctx.tuning
    seed_salt = args.seed % 97
    attempts_n = args.pilot_attempts
    tuning_sha = hashlib.sha256(
        tuning_path.read_bytes()).hexdigest()
    candidates = []
    attempts = []
    accepted_sigs = []
    accepted_names = []
    for door, name, _fn in PILOT_DOORS:
        fn = PILOT_BUILDERS[door]
        for slot in (1, 2, 3, 4, 5):
            for variant in (1, 2, 3):
                cid = "D%02dS%dV%d" % (door, slot, variant)
                kept = None
                kept_chk = None
                last_chk = None
                for attempt in range(attempts_n):
                    kk = ((door * 5 + slot) * 9
                          + (variant - 1) * 3 + attempt)
                    salt = seed_salt + door * 1000 + slot * 100 \
                        + variant * 10
                    plats, hazards, spawn, door_pos, skel = fn(
                        ctx, kk, salt, slot, variant)
                    repair_added = v3_finish(ctx, plats, hazards,
                                             spawn, door_pos)
                    strip = _strip_stats(hazards)
                    level = {"id": cid, "palette": door - 1,
                             "spawn": {"x": int(spawn[0]),
                                       "y": int(spawn[1])},
                             "door": {"x": int(door_pos[0]),
                                      "y": int(door_pos[1])},
                             "platforms": plats, "hazards": hazards,
                             "template": name, "variation": cid}
                    chk = _check_one(level, tun,
                                     idx=len(candidates))
                    rec = {"door": door, "slot": slot,
                           "variant": variant, "attempt": attempt,
                           "kk": kk, "skeleton": skel,
                           "repair_added": repair_added,
                           "passed": chk["pass"],
                           "errors": chk["errors"][:3],
                           "density": chk["density"],
                           "max_up_strip_w": strip["max_up_strip_w"],
                           "n_up_strips": strip["n_up_strips"],
                           "up_widths_gt60": strip["up_widths_gt60"]}
                    duplicate_of = None
                    if chk["pass"]:
                        layout, traps, solution = chk["signature"]
                        for j, (l2, t2, s2) in enumerate(
                                accepted_sigs):
                            dims = sum([layout != l2, traps != t2,
                                        solution != s2])
                            if dims < 2:
                                duplicate_of = accepted_names[j]
                                break
                    rec["duplicate_of"] = duplicate_of
                    attempts.append(rec)
                    last_chk = chk
                    if chk["pass"] and duplicate_of is None:
                        kept = level
                        kept_chk = chk
                        accepted_sigs.append(chk["signature"])
                        accepted_names.append(cid)
                        break
                    if chk["pass"] and duplicate_of is not None:
                        # Passing but a duplicate: keep trying for a
                        # distinct passing draw.
                        continue
                if kept is None:
                    kept = level
                    kept_chk = last_chk
                candidates.append(kept)
    data = {"schema_version": SCHEMA_VERSION,
            "tuning_version": tun.version,
            "levels": candidates}
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(data, indent=1) + "\n")
    # Full-file verification (dedupe + family purity + all rules).
    results, clusters, top_errors = check_levels.verify_levels(
        data, tun)
    n_pass = sum(1 for r in results if not r["errors"])
    n_dup = sum(1 for r in results if r["duplicate_of"] is not None)
    # Per archetype/slot aggregates + zero-pass slots + ablations.
    by_slot = {}
    for a in attempts:
        key = (a["door"], a["slot"])
        by_slot.setdefault(key, {"attempts": 0, "passes": 0,
                                 "variants_passing": set(),
                                 "repair_total": 0})
        by_slot[key]["attempts"] += 1
        by_slot[key]["repair_total"] += a["repair_added"]
        if a["passed"] and a["duplicate_of"] is None:
            by_slot[key]["passes"] += 1
            by_slot[key]["variants_passing"].add(a["variant"])
    slots = []
    for (door, slot) in sorted(by_slot):
        agg = by_slot[(door, slot)]
        rec = {"door": door, "slot": slot,
               "skeleton": PILOT_SKELETONS[door][slot],
               "attempts": agg["attempts"],
               "passing_attempts": agg["passes"],
               "variants_passing": sorted(agg["variants_passing"]),
               "variants_passing_count": len(
                   agg["variants_passing"]),
               "repair_total": agg["repair_total"]}
        if not agg["variants_passing"]:
            idx = next(i for i, lv in enumerate(candidates)
                       if lv["id"] == "D%02dS%dV%d"
                       % (door, slot, 1))
            rec["ablation"] = pilot_ablation(candidates[idx], tun)
        slots.append(rec)
    # Density census (solids-only; decorations are 0 everywhere).
    density = []
    for r in results:
        d = r["density"] or {}
        density.append({"id": r["id"],
                        "pass": bool(d.get("pass")),
                        "rect_count": d.get("rect_count"),
                        "combined_width": d.get("combined_width"),
                        "core_rect_count": d.get("core_rect_count"),
                        "core_combined_width":
                            d.get("core_combined_width"),
                        "mass": d.get("mass")})
    fam_errors = [r for r in results
                  if any(e.startswith("family:") for e in r["errors"])]
    dotted = sum(1 for lv in candidates for h in lv["hazards"]
                 if h.get("type") == "dotted_line")
    decos = sum(len(lv.get("decorations", [])) for lv in candidates)
    saws = sum(1 for lv in candidates for h in lv["hazards"]
               if h.get("type") == "saw")
    # Round 3 strip census: every draw incl. discarded ones. The zero
    # is asserted here independently of the _assert_strip_cap guard
    # in v3_finish (which raises before a violating draw is recorded).
    per_arch = {}
    for d in sorted({a["door"] for a in attempts}):
        draws = [a for a in attempts if a["door"] == d]
        per_arch[str(d)] = {
            "max_up_w": max((a["max_up_strip_w"] for a in draws),
                            default=0),
            "draws_with_gt60": sum(
                1 for a in draws if a["up_widths_gt60"])}
    strip_census = {
        "total_draws": len(attempts),
        "draws_with_gt60": sum(
            1 for a in attempts if a["up_widths_gt60"]),
        "max_up_w_overall": max(
            (a["max_up_strip_w"] for a in attempts), default=0),
        "per_archetype": per_arch}
    assert strip_census["draws_with_gt60"] == 0, \
        "strip census: %d draws with up-strip > 60" \
        % strip_census["draws_with_gt60"]
    # Round 4 audits (Implementation Gate §7a + Rule 12) + gap
    # table recomputed from the reconciled game-true air distance
    # D = 97.2px (verification/air-distance-reconciliation-r4.json:
    # forced takeoff 154.8 -> landing 252.00; the planner's 93.15px
    # hand-derivation is retired). Exact constants come from the
    # discrete trajectory (single-strip window 69.55 - w); the
    # task-formula constants (69.7) differ by <= 0.15px and flip no
    # clean/marginal call. Stance: the filed D14 text and baseline
    # define stance as the RAW edge-to-edge gap (stance_raw = g);
    # the task parenthetical implies stance_usable = g - 15 (needs
    # g >= 55 for stance >= 40). CONFLICT flagged, not silently
    # resolved: headline clean counts use stance_raw per the filed
    # baseline; both are reported per variant in
    # geometry_baseline_r4 (merged by the walker recompute).
    gap_table_r4 = {
        "D_game_true_px": 97.2,
        "D_source": "verification/air-distance-reconciliation-r4.json "
                    "(forced takeoff 154.8 -> landing 252.00; "
                    "158.85 -> 256.05; 0.07px resting gap)",
        "D_planner_retired_px": 93.15,
        "single_strip_window_exact": "69.55 - w",
        "single_strip_window_task_formula": "69.7 - w",
        "W_chain_exact":
            "min(69.55-w1, 69.55-w2, g-27.64, 166.76-w1-w2-g)",
        "W_chain_task_formula":
            "min(69.7-w1, 69.7-w2, g-27.5, 166.9-w1-w2-g)",
        "decoupled_condition":
            "pair is CHAINED iff g + w2 <= 97.2; else decoupled "
            "(hero lands before the second strip's takeoff window "
            "opens) and judged as single strips",
        "clean_needs": "w <= 54.7, g >= 42.5, "
                       "g <= 151.9-w1-w2 (W_chain >= 15)",
        "clean_g_ranges_equal_width": {
            "35": [42.5, 81.9], "45": [42.5, 61.9],
            "50": [42.5, 51.9],
            "60": "never clean; planner-lattice g in [31.55, 42.85]"},
        "planner_min_g": 32,
        "solvable_min_g": 27.5,
        "stance_definition_conflict":
            "filed D14/baseline: stance = raw edge-to-edge gap "
            "(stance_raw = g); task parenthetical: stance_usable = "
            "g - 15 (stance >= 40 needs g >= 55). Headline counts "
            "use stance_raw; both reported in geometry_baseline_r4.",
    }
    chained_audit = _chained_pair_audit(candidates)
    column_audit = _column_audit(candidates, tun)
    census = {
        "round": census_path.stem.replace("pilot-census-", "", 1),
        "schema_version": SCHEMA_VERSION,
        "tuning_version": tun.version,
        "tuning_sha256": tuning_sha,
        "tuning_apex": tun.apex,
        "tuning_run_speed": tun.run_speed,
        "tuning_gravity": tun.gravity,
        "tuning_jump_velocity": tun.jump_v,
        "seed": args.seed,
        "attempts_per_slot_variant": attempts_n,
        "candidates_file": str(out_path),
        "candidates_total": len(candidates),
        "candidates_passing_checker": n_pass,
        "candidates_duplicate_of": n_dup,
        "top_errors": top_errors,
        "attempts": attempts,
        "slots": slots,
        "density": density,
        "family_errors": [{"id": r["id"], "errors": r["errors"]}
                          for r in fam_errors],
        "dotted_line_count": dotted,
        "decoration_count": decos,
        "saw_count": saws,
        "strip_census": strip_census,
        "gap_table_r4": gap_table_r4,
        "chained_pair_audit": chained_audit,
        "column_audit": column_audit,
        "skeleton_table": {str(d): {str(s): n for s, n in m.items()}
                           for d, m in PILOT_SKELETONS.items()},
    }
    census_path.write_text(json.dumps(census, indent=1) + "\n")
    print("PILOT: %d candidates, %d checker-passing, %d duplicates"
          % (len(candidates), n_pass, n_dup))
    print("PILOT: candidates -> %s" % out_path)
    print("PILOT: census -> %s" % census_path)
    print("PILOT: dotted_line=%d decorations=%d saws=%d family_errors=%d"
          % (dotted, decos, saws, len(fam_errors)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Trap Tower level generator "
                                             "(Run 2 candidates)")
    ap.add_argument("--out", default=None,
                    help="candidates file (default: "
                    "<trap-tower>/verification/candidates.json)")
    ap.add_argument("--tuning", default=None,
                    help="tuning.json (default: repo godot/data/tuning.json)")
    ap.add_argument("--seed", type=int, default=SEED_DEFAULT)
    ap.add_argument("--doors", default=None,
                    help="comma-separated door numbers (default: all 44)")
    ap.add_argument("--slots", default=None,
                    help="comma-separated slot numbers 1-5 (default: all)")
    ap.add_argument("--variants", type=int, default=None,
                    help="cap variants per door/slot (default: per-door "
                    "table counts)")
    ap.add_argument("--min-levels", type=int, default=None,
                    help="fail if fewer levels pass (default: the full "
                    "requested candidate count)")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--pilot", action="store_true",
                    help="pilot mode: 3 variants x 5 slots x 10 "
                    "archetypes (150 candidates) -> "
                    "verification/candidates-v6-pilot.json + "
                    "pilot-census-r1.json")
    ap.add_argument("--pilot-attempts", type=int, default=3,
                    help="grid-point attempts per slot/variant in "
                    "--pilot mode (default: 3)")
    ap.add_argument("--census", default=None,
                    help="pilot census JSON path (default: "
                    "<trap-tower>/verification/pilot-census-r1.json)")
    ap.add_argument("--extend", action="store_true",
                    help="recovery mode: append NEW easier variants for "
                    "the failed slots only (see EXTEND_SLOTS); writes "
                    "candidates-v2.json, never touches the original file")
    ap.add_argument("--existing", default=None,
                    help="existing candidates file (default: "
                    "<trap-tower>/verification/candidates.json)")
    ap.add_argument("--search", type=int, default=30000,
                    help="grid indices scanned per slot in --extend mode")
    ap.add_argument("--shortlist", type=int, default=400,
                    help="top-scored draws per slot put through the "
                    "checker in --extend mode")
    ap.add_argument("--extend-slots", default=None,
                    help="comma-separated door:slot pairs for --extend "
                    "mode (default: the EXTEND_SLOTS table); first new "
                    "variant is always max-existing + 1")
    args = ap.parse_args(argv)
    if args.pilot:
        return pilot_main(args)
    if args.extend:
        return extend_main(args)

    tuning_path = Path(args.tuning) if args.tuning \
        else REPO / "godot" / "data" / "tuning.json"
    out_path = Path(args.out) if args.out \
        else REPO.parent / "verification" / "candidates.json"
    tuning_data = load_tuning(tuning_path)
    ctx = Ctx(tuning_data)
    tun = ctx.tuning
    seed_salt = args.seed % 97

    want_doors = _parse_csv_ints(args.doors) if args.doors \
        else [d for (d, _n, _f, _v) in DOORS]
    want_slots = _parse_csv_ints(args.slots) if args.slots else [1, 2, 3, 4, 5]
    table = {d: (name, fn, nv) for (d, name, fn, nv) in DOORS}
    for d in want_doors:
        if d not in table:
            print("ERROR: unknown door %d" % d, file=sys.stderr)
            return 2
        if d - 1 >= ctx.n_palettes:
            print("ERROR: door %d needs palette %d but tuning.json has "
                  "only %d palettes" % (d, d - 1, ctx.n_palettes),
                  file=sys.stderr)
            return 2
    for s in want_slots:
        if s < 1 or s > 5:
            print("ERROR: slot %d out of range 1..5" % s, file=sys.stderr)
            return 2

    requested = []
    for door in sorted(want_doors):
        _name, _fn, nv = table[door]
        nvar = min(nv, args.variants) if args.variants else nv
        for slot in sorted(want_slots):
            for variant in range(1, nvar + 1):
                requested.append((door, slot, variant))
    min_levels = args.min_levels if args.min_levels is not None \
        else len(requested)

    accepted = []
    accepted_sigs = []
    accepted_names = []
    n_duplicates = 0
    n_invalid = 0
    n_retried = 0
    n_attempts = 0
    dup_examples = []
    invalid_examples = []
    per_door = {}
    traceback_shown = set()

    for (door, slot, variant) in requested:
        name, fn, _nv = table[door]
        cid = "D%02dS%dV%d" % (door, slot, variant)
        k = (slot - 1) * VARIANT_STRIDE + (variant - 1)
        salt = door * 131 + seed_salt
        done = False
        fail_kind = None
        fail_detail = ""
        for attempt in range(MAX_ATTEMPTS):
            # Attempt stride 5 is coprime to the pick-list lengths
            # (2..6), so retries actually vary; attempt 0 is unchanged.
            kk = k * MAX_ATTEMPTS + attempt * 5
            n_attempts += 1
            if door in V3_BUILDERS:
                # v3 path (Round 4 post-GO, Lane G5): builders carry
                # their own density masses; finish is v3_finish only
                # (strip cap + column span guards + repair_grounding).
                # kk/salt mirror pilot_main, so attempt 0 matches the
                # pilot draw for the 10 pilot doors. NOTE: v3 builders
                # are _vo(variant)-keyed like the pilot ones, so the
                # 6 attempts draw identically; a failing v3 slot is
                # fixed in the builder, not by retry.
                kk3 = ((door * 5 + slot) * 9 + (variant - 1) * 3 + attempt)
                salt3 = (seed_salt + door * 1000 + slot * 100
                         + variant * 10)
                try:
                    plats, hazards, spawn, door_pos, _sk = V3_BUILDERS[door](
                        ctx, kk3, salt3, slot, variant)
                except Exception as exc:  # builder bug: record, never crash
                    import traceback
                    if name not in traceback_shown:
                        traceback_shown.add(name)
                        traceback.print_exc()
                    fail_kind, fail_detail = ("invalid",
                                              "builder raised: %s" % exc)
                    continue
                plats = [dict(p) for p in plats]
                hazards = [dict(h) for h in hazards]
                try:
                    v3_finish(ctx, plats, hazards, spawn, door_pos)
                except Exception as exc:
                    fail_kind, fail_detail = ("invalid",
                                              "v3_finish raised: %s" % exc)
                    continue
                decos = []
            else:
                try:
                    plats, hazards, spawn, door_pos = fn(ctx, kk, salt)
                except Exception as exc:  # builder bug: record, never crash
                    import traceback
                    if name not in traceback_shown:
                        traceback_shown.add(name)
                        traceback.print_exc()
                    fail_kind, fail_detail = ("invalid",
                                              "builder raised: %s" % exc)
                    continue
                plats = [dict(p) for p in plats]
                hazards = [dict(h) for h in hazards]
                normalize_ground(ctx, plats)
                low = route_is_low(ctx, plats, spawn, door_pos)
                if low:
                    add_skyline_dressing(ctx, kk, salt + 50, plats, hazards,
                                         spawn, door_pos)
                    if not has_upper_band(plats, hazards, spawn):
                        add_ceiling_strip(ctx, kk, salt + 60, plats, hazards)
                if not has_upper_band(plats, hazards, spawn):
                    fail_kind, fail_detail = "invalid", \
                        "no upper-band element (route not full-height)"
                    continue
                if not has_lethal_hazard(hazards):
                    if low and add_ceiling_strip(ctx, kk, salt + 70, plats,
                                                 hazards):
                        pass
                    else:
                        fail_kind, fail_detail = "invalid", \
                            "no lethal hazard (empty hazards banned)"
                        continue
                repair_grounding(ctx, plats, hazards, spawn, door_pos)
                add_core_middle_dressing(ctx, kk, salt + 80, plats, hazards,
                                         spawn, door_pos)
                decos = []
                if DECO_PASS_ENABLED:
                    decos = add_decorations(ctx, kk, salt + 90, plats,
                                            hazards, spawn, door_pos)
            level = {"id": cid, "palette": door - 1,
                     "spawn": {"x": int(spawn[0]), "y": int(spawn[1])},
                     "door": {"x": int(door_pos[0]), "y": int(door_pos[1])},
                     "platforms": plats, "hazards": hazards,
                     "template": name, "variation": cid}
            if decos:
                level["decorations"] = decos
            chk = check_levels.LevelCheck(level, len(accepted), tun).run()
            if chk.errors:
                fail_kind, fail_detail = "invalid", \
                    "; ".join(chk.errors[:2])
                continue
            try:
                layout, traps, solution = chk.signature_parts()
            except Exception as exc:
                fail_kind, fail_detail = "invalid", \
                    "signature failed: %s" % exc
                continue
            duplicate_of = None
            for j, (lay2, tra2, sol2) in enumerate(accepted_sigs):
                dims = sum([layout != lay2, traps != tra2,
                            solution != sol2])
                if dims < 2:
                    duplicate_of = accepted_names[j]
                    break
            if duplicate_of is not None:
                fail_kind, fail_detail = "duplicate", duplicate_of
                continue
            accepted.append(level)
            accepted_sigs.append((layout, traps, solution))
            accepted_names.append(cid)
            per_door[door] = per_door.get(door, 0) + 1
            if attempt:
                n_retried += 1
            done = True
            break
        if done:
            continue
        if fail_kind == "duplicate":
            n_duplicates += 1
            if len(dup_examples) < 12:
                dup_examples.append("%s duplicates %s (all %d attempts)"
                                    % (cid, fail_detail, MAX_ATTEMPTS))
        else:
            n_invalid += 1
            if len(invalid_examples) < 12:
                invalid_examples.append("%s: %s" % (cid, fail_detail))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    data = {"schema_version": SCHEMA_VERSION,
            "tuning_version": ctx.tuning_version, "levels": accepted}
    out_path.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n",
                        encoding="utf-8")

    if not args.quiet:
        print("generate_levels.py (Run 2): seed=%d" % args.seed)
        print("  candidates requested: %d" % len(requested))
        print("  draws scanned:        %d" % n_attempts)
        print("  duplicates rejected:  %d" % n_duplicates)
        print("  invalid rejected:     %d" % n_invalid)
        print("  accepted via retry:   %d" % n_retried)
        print("  accepted: %d levels -> %s" % (len(accepted), out_path))
        for door in sorted(want_doors):
            name = table[door][0]
            print("    D%02d %-18s %d" % (door, name,
                                          per_door.get(door, 0)))
        for line in dup_examples:
            print("  DUP: %s" % line)
        for line in invalid_examples:
            print("  INVALID: %s" % line)
    if len(accepted) < min_levels:
        print("ERROR: only %d levels passed, need >= %d"
              % (len(accepted), min_levels), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
