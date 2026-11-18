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

Physics numbers are ALWAYS loaded from godot/data/tuning.json, never
duplicated here. Design envelope (conservative harness envelope from
tuning.json): rise <= 100, gap <= 170, landing >= 48, run-up >= 60,
timed-hazard safe window >= 0.7s. All jumps are designed well inside
it with visible landings, run-ups, and safe waiting spots before every
timed hazard.

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
SCHEMA_VERSION = 2  # LEVEL_SCHEMA.md v2 (frozen contract version)
FLOOR_TOP = 500     # level-design choice (schema example uses 500); the
                    # control bar starts at tuning.json control_bar.y.
VARIANT_STRIDE = 3  # fixed stride so pilot (variant 1) stages are the
                    # same grid points as bulk variant-1 stages.
MAX_ATTEMPTS = 6    # grid-point retries per candidate before rejection.
DECO_PASS_ENABLED = True  # Test hook ONLY: the deco-diff proof flips
# this off to show disabled-vs-enabled generations differ ONLY in the
# `decorations` array. Production generation always leaves it on.


# ---------------------------------------------------------------------------
# Tuning (single source of truth -- loaded, never hand-copied)
# ---------------------------------------------------------------------------

class Ctx:
    def __init__(self, tuning_data):
        self.tuning = check_levels.Tuning(tuning_data)
        self.tuning_version = self.tuning.version
        self.width = int(self.tuning.width)
        self.bar_y = int(self.tuning.bar_y)
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
    return plat(x1, top, x2 - x1, c.bar_y - top, "solid")


def spikes_up(x, w, top=FLOOR_TOP, **kw):
    d = {"type": "spikes", "x": int(x), "y": int(top - 24),
         "w": int(w), "h": 24, "dir": "up"}
    d.update(kw)
    return d


def spikes_down(x, w, y, h=28):
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
    drop_dist = max(0.0, c.bar_y - (py + ph))
    land_time = drop_dist / max(float(speed), 1.0)
    dist = int(math.ceil(land_time * c.run_speed)) + 120 + extra
    return px - dist


def pillar_periodic(x, y, w, h, period, phase, speed):
    return {"type": "hanging_pillar", "x": int(x), "y": int(y),
            "w": int(w), "h": int(h), "period": float(period),
            "phase": float(phase), "drop_speed": int(speed)}


def dotted(hazards, x, y, w, h, linked):
    """Append a dotted-line warning linked to hazards[linked]."""
    hazards.append({"type": "dotted_line", "x": int(x), "y": int(y),
                    "w": int(w), "h": int(h), "linked": int(linked)})


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
    the main ground line extends to the control-bar line (y = bar_y).
    Tops never move, so physics is untouched; pits stay open (no
    platform = gap). Floating ledges/stones whose bottoms stay above
    the floor line are untouched."""
    for p in platforms:
        if p["kind"] != "solid":
            continue
        if p["y"] == FLOOR_TOP:
            p["h"] = c.bar_y - p["y"]
        elif p["y"] < FLOOR_TOP < p["y"] + p["h"] < c.bar_y:
            p["h"] = c.bar_y - p["y"]


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
        if h["type"] != "dotted_line" and h["y"] < 300:
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
    spike/saw toppings seated on the beam tops. Beams stay clear of
    every jump arc band on low routes (route tops >= 420, so arc
    bands start at y >= 267) and the walls stand beyond the
    spawn/door x-ranges, so dressing can never block the route --
    unlike pillar-grounded ledges, whose floor pillars would wall
    off the flat walking route. Skipped entirely when an edge wall
    would block the door rect (the retry loop tries another grid
    point). Returns the number of beams."""
    for wx in (0, c.width - 48):
        wall_rect = (float(wx), 150.0, 48.0, float(c.bar_y) - 150.0)
        if _blocks_spawn_door(c, wall_rect, spawn, door_pos):
            return 0
        if _rect_hazard_overlap(wall_rect, hazards):
            return 0
    tops = [150, 160, 170, 180, 190, 200, 210, 220, 230, 240]
    n = g(kk, [1, 2, 2, 3], salt=salt)
    chosen = []
    for i in range(n):
        top = g(kk, tops, salt=salt + i * 5)
        # Beams >= 48px apart: a topping spike strip (24px tall) on
        # one beam must never area-overlap the beam above it (rule 7),
        # and a down-spike strip (28px) under one beam must clear the
        # beam below. The old 20px spacing guaranteed such overlaps.
        if any(abs(top - t) < 48 for t in chosen):
            continue
        chosen.append(top)
    if not chosen:
        return 0
    wall_top = min(chosen)
    for wx in (0, c.width - 48):
        platforms.append(plat(wx, wall_top, 48, c.bar_y - wall_top,
                              "solid"))
    excl = dressing_exclusions(hazards)
    toppings = ["spikes", "saw", "none", "spikes", "saw"]
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
            w = 80 if topping == "spikes" else 60
            if any(_overlaps(x0, x0 + w, e0, e1) for (e0, e1) in excl):
                continue
            if topping == "spikes":
                sw = g(kk, [48, 64, 80], salt=salt + j)
                top_rect = (float(x0), float(top - 24), float(sw), 24.0)
                if any(p["kind"] == "solid"
                       and _xov(top_rect, _pr(p)) > _GTOL
                       and _yov(top_rect, _pr(p)) > _GTOL
                       for p in platforms):
                    continue
                hazards.append(spikes_up(x0, sw, top=top))
            else:
                r = g(kk, [26, 28], salt=salt + j)
                hazards.append(saw_static(x0 + 30, top - r + 4, r))
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
        if t == "dotted_line":
            soft.append((h["x"] - 20, h["x"] + h["w"] + 20))
        elif t == "saw" and "path" not in h and "swing" not in h:
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
        hazards.append(spikes_down(x0, w, y, 28))
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
    return any(h["type"] != "dotted_line" for h in hazards)


# ---------------------------------------------------------------------------
# Grounding repair (LEVEL_SCHEMA.md v2 rules 7-8). Builders emit the
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
    Saws, hanging_pillar and dotted_line are exempt, as in the
    checker. Used by every repair/dressing pass that ADDS a solid:
    added geometry must never hide a support behind a hazard."""
    for h in hazards:
        if h.get("type") not in ("spikes", "spiked_column"):
            continue
        hr = (float(h["x"]), float(h["y"]), float(h["w"]),
              float(h["h"]))
        if _xov(rect, hr) > _GTOL and _yov(rect, hr) > _GTOL:
            return True
    return False


def _core_middle_stats(platforms, width):
    """(count, combined width) for the LEVEL_SCHEMA.md rule 9
    core-middle floor: non-edge solid rects intersecting y 260..420.
    Mirrors check_levels.check_density_floor exactly."""
    count = 0
    total = 0.0
    for p in platforms:
        if p["kind"] != "solid":
            continue
        if p["x"] == 0 or p["x"] + p["w"] == width:
            continue
        if p["y"] < 420 and p["y"] + p["h"] > 260:
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


def _grounded_solids_gen(plats, bar_y):
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
            ok = abs(bottom - bar_y) <= _GTOL
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
    bar_y = float(c.bar_y)
    for _round in range(12):
        grounded, rects = _grounded_solids_gen(plats, bar_y)
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
            grounded, rects = _grounded_solids_gen(plats, bar_y)
            if i in grounded:
                continue
            r = rects[i]
            bottom = r[1] + r[3]
            if bottom < _KEEPOUT_Y or bottom > bar_y:
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
                    top = bar_y
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
    bar_y = float(c.bar_y)
    specials = [i for i, p in enumerate(plats)
                if p["kind"] in ("dashed", "falling", "tilting",
                                 "moving")]
    for idx in specials:
        grounded, rects = _grounded_solids_gen(plats, bar_y)
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
            bottom = bar_y if top is None else top
            if bottom - y0 < 16.0:
                bottom = bar_y
            rect = (wx, y0, 48.0, bottom - y0)
            if _blocks_spawn_door(c, rect, spawn, door_pos):
                continue
            if _rect_hazard_overlap(rect, hazards):
                continue
            if _has_rect(plats, rect):
                continue
            plats.append(plat(wx, y0, 48, bottom - y0, "solid"))


def _beam_needs(plats, hazards, grounded, rects, bar_y):
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
            on_top = abs(bottom - bar_y) <= _GTOL or any(
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
        plats, spawn, door_pos, float(c.width), float(c.bar_y),
        float(c.door_w), float(c.door_h)) is None


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
    bar_y = float(c.bar_y)
    grounded, rects = _grounded_solids_gen(plats, bar_y)
    needs = [(b, t, x0, x1) for (b, t, x0, x1) in
             _beam_needs(plats, hazards, grounded, rects, bar_y)
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
    grounded2, rects2 = _grounded_solids_gen(plats, bar_y)
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
    grounded3, _r3 = _grounded_solids_gen(plats, bar_y)
    local_ok = len(plats) > base \
        and all(i in grounded3 for i in range(base, len(plats))) \
        and _route_connected(c, plats, spawn, door_pos)
    if local_ok:
        return
    del plats[base:]
    # --- Attempt 2: full-width edge-wall gantry, connectivity-gated.
    # Kept ONLY when the route stays on one side of the beam; a
    # sealing gantry is rolled back in full.
    grounded, rects = _grounded_solids_gen(plats, bar_y)
    wall_top = min(t for _b, t, _x0, _x1 in needs)
    walls = []
    for wx in (0.0, c.width - 48.0):
        top = _support_top_below(rects, grounded, wx, wx + 48.0,
                                 wall_top + 16.0)
        bottom = bar_y if top is None else top
        if bottom - wall_top < 16.0:
            bottom = bar_y
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
    bar_y = float(c.bar_y)
    for h in hazards:
        if h.get("type") != "saw" \
                or not isinstance(h.get("r"), (int, float)):
            continue
        grounded, rects = _grounded_solids_gen(plats, bar_y)
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
            top = min(max_cy + r - 4.0, bar_y - 16.0)
            rx0 = max(0.0, min_cx - r)
            rx1 = min(float(c.width), max_cx + r)
            if rx1 - rx0 < 48.0:
                rx1 = min(float(c.width), rx0 + 48.0)
                rx0 = max(0.0, rx1 - 48.0)
            rect = (rx0, top, rx1 - rx0, bar_y - top)
            if _blocks_spawn_door(c, rect, spawn, door_pos):
                continue
            if _rect_hazard_overlap(rect, hazards):
                continue
            if _has_rect(plats, rect):
                continue
            plats.append(plat(rx0, top, rx1 - rx0, bar_y - top, "solid"))
        elif "swing" in h:
            continue
        else:
            top = cy + r - 2.0
            px = min(max(cx - 24.0, 0.0), c.width - 48.0)
            support = _support_top_below(rects, grounded, px, px + 48.0,
                                         top + 16.0)
            bottom = bar_y if support is None else support
            if bottom - top < 16.0:
                bottom = bar_y
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
    bar_y = float(c.bar_y)
    for h in hazards:
        t = h.get("type")
        grounded, rects = _grounded_solids_gen(plats, bar_y)
        if t == "spikes" and not _spikes_seated_gen(h, plats, rects,
                                                    grounded):
            d = h.get("dir", "up")
            x, y, w, hh = (float(h[k]) for k in ("x", "y", "w", "h"))
            if d == "up":
                bottom = y + hh
                if bottom > bar_y - 16.0:
                    continue
                w2 = max(w, 48.0)
                x2 = min(max(x, 0.0), c.width - w2)
                rect = (x2, bottom, w2, bar_y - bottom)
                if _blocks_spawn_door(c, rect, spawn, door_pos):
                    continue
                if _rect_hazard_overlap(rect, hazards):
                    continue
                if not _has_rect(plats, rect):
                    plats.append(plat(x2, bottom, w2, bar_y - bottom,
                                      "solid"))
            elif d in ("left", "right"):
                for wx in (x + w, x - 48.0):
                    if wx < 0 or wx + 48.0 > c.width:
                        continue
                    support = _support_top_below(
                        rects, grounded, wx, wx + 48.0, y + hh)
                    bottom = bar_y if support is None else support
                    if bottom - y < 16.0:
                        bottom = bar_y
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
            on_top = abs(bottom - bar_y) <= _GTOL or any(
                abs(bottom - s[1]) <= _GTOL and _xov(r, s) >= 8.0
                for s in solids)
            hung = any(j in grounded
                       and abs(top - (rects[j][1] + rects[j][3])) <= _GTOL
                       and _xov(r, rects[j]) >= 8.0
                       for j in range(len(rects)))
            if on_top or hung:
                continue
            if bottom > bar_y - 16.0:
                continue
            w2 = max(r[2], 48.0)
            x2 = min(max(r[0], 0.0), c.width - w2)
            rect = (x2, bottom, w2, bar_y - bottom)
            if _blocks_spawn_door(c, rect, spawn, door_pos):
                continue
            if _rect_hazard_overlap(rect, hazards):
                continue
            if not _has_rect(plats, rect):
                plats.append(plat(x2, bottom, w2, bar_y - bottom,
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
        if t == "dotted_line":
            continue
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
    for h in hazards:
        if h.get("type") != "dotted_line":
            continue
        hr = (float(h["x"]), float(h["y"]), float(h["w"]),
              float(h["h"]))
        if _xov(rect, hr) > 0.0 and _yov(rect, hr) > 0.0:
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
                and p["y"] < 420 and p["y"] + p["h"] > 260]
    order = sorted(core_idx, key=lambda i: _mix(kk, salt + 300 + i))
    widened = 0
    for i in order:
        _cnt, width = _core_middle_stats(plats, c.width)
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


def _add_beam_bars(c, kk, salt, plats, hazards, spawn, door_pos,
                   beam_top):
    """Connector bars between the ceiling beam stack and the mid beam.
    Each bar rests on the mid beam (bottom = beam_top + 4, within the
    4px resting tolerance) and overlaps the lowest stack beam covering
    its x-span by 8px, so it reads as one joined structure. At most
    2 bars, >= 160px apart. Returns the number added."""
    placed = []
    xs = list(range(120, 1121, 80))
    order = sorted(range(len(xs)),
                   key=lambda i: _mix(kk, salt + 320 + i))
    for oi in order:
        if len(placed) >= 2:
            break
        bx = float(xs[oi])
        bw = float(g(kk, [48, 64], salt=salt + 330 + len(placed)))
        anchor_bottom = None
        for p in plats:
            if p["kind"] != "solid" or p["h"] > 24:
                continue
            if p["x"] <= bx and p["x"] + p["w"] >= bx + bw:
                bottom = float(p["y"]) + float(p["h"])
                if bottom <= beam_top - 4.0 and bottom >= 100.0:
                    if anchor_bottom is None or bottom > anchor_bottom:
                        anchor_bottom = bottom
        if anchor_bottom is None:
            continue
        top = anchor_bottom - 8.0
        bottom = float(beam_top) + 4.0
        if bottom - top < 16.0 or top < _KEEPOUT_Y:
            continue
        rect = (bx, top, bw, bottom - top)
        if _blocks_spawn_door(c, rect, spawn, door_pos):
            continue
        if _rect_hazard_overlap(rect, hazards):
            continue
        if any(abs(bx - px) < 160.0 for px in placed):
            continue
        plats.append(plat(bx, top, bw, bottom - top, "solid"))
        placed.append(bx)
    return len(placed)


def _try_mid_beam(c, kk, salt, plats, hazards, spawn, door_pos):
    """One full-width mid beam (y 260..268) on the existing edge
    walls, plus connector bars. Gated: no route platform top in
    [260, 481) -- a jump from such a takeoff reaches the beam band
    (head apex crosses y 260..284), and the checker blocker rule
    does not catch it (beam bottom 284 < top_min - apex for those
    takeoffs), so the beam would head-bump the autopilot on raised
    stones/steps. Full-width thin beams (the ceiling stack itself)
    are excluded from the gate: the hero never stands on them.
    Also requires edge walls spanning the beam band and no rect
    hazard crossing the beam. Beam bottom <= 284 stays clear of the
    jump-arc head apex (~297 physical, ~303 checker) on floor-level
    routes. Returns the number of rects added."""
    for p in plats:
        if p["w"] >= 1000 and p["h"] <= 20:
            continue
        tops = [float(p["y"])]
        if p["kind"] == "moving":
            tops.append(float(p["y"]) + float(p.get("dy", 0)))
        if any(260.0 <= t < 481.0 for t in tops):
            return 0
    for side in (0.0, float(c.width) - 48.0):
        if not any(p["kind"] == "solid" and float(p["x"]) == side
                   and float(p["y"]) <= 268.0
                   and float(p["y"]) + float(p["h"]) >= 284.0
                   for p in plats):
            return 0
    tops = [260, 264, 268]
    rot = _mix(kk, salt + 340) % len(tops)
    tops = tops[rot:] + tops[:rot]
    for top in tops:
        rect = (48.0, float(top), float(c.width) - 96.0, 16.0)
        if _blocks_spawn_door(c, rect, spawn, door_pos):
            continue
        if _rect_hazard_overlap(rect, hazards):
            continue
        # Keep the beam clear of other thin horizontal solids in its
        # band (no merged slabs); vertical walls may cross it.
        if any(p["kind"] == "solid" and p["h"] <= 20
               and _xov(rect, _pr(p)) > 48.0
               and _yov(rect, _pr(p)) > 0.0 for p in plats):
            continue
        plats.append(plat(48, top, c.width - 96, 16, "solid"))
        return 1 + _add_beam_bars(c, kk, salt, plats, hazards,
                                  spawn, door_pos, top)
    return 0


def _add_dressing_pillars(c, kk, salt, plats, hazards, spawn, door_pos,
                          want, intervals, min_gap, existing=()):
    """Grounded floor pillars (bottom at the control-bar line, tops
    400..416). Seeded x-order over a 40px grid, seeded widths/heights,
    >= min_gap from each other and from `existing` rects. Returns the
    rects added."""
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
        top = float(g(kk, [400, 404, 408, 412, 416],
                      salt=salt + 370 + oi * 3))
        if x0 + w > float(c.width):
            continue
        rect = (x0, top, w, float(c.bar_y) - top)
        if not _pillar_ok(c, rect, hazards, spawn, door_pos, intervals):
            continue
        if any(min(abs(rect[0] - (q[0] + q[2])),
                    abs(q[0] - (rect[0] + rect[2]))) < min_gap
               for q in list(picked) + list(existing)):
            continue
        plats.append(plat(x0, top, w, c.bar_y - top, "solid"))
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
        count, width = _core_middle_stats(plats, c.width)
        if count >= 2 and width >= 160.0:
            break
        sup = supports[oi]
        sx, sy, sw = float(sup["x"]), float(sup["y"]), float(sup["w"])
        w = float(g(kk, [48, 56, 64], salt=salt + 420 + oi))
        height = float(g(kk, [80, 100, 120], salt=salt + 430 + oi))
        top = max(260.0, sy - height)
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
        # Plinth: when the support's top sits at/below the core band
        # edge (y >= 420) the support itself does not count, so the
        # stacked pillar alone leaves count == 1. A 16px plinth under
        # the pillar (pillar width + 48) is the second core rect and
        # does not change the landing surface -- a full-width cap was
        # ablation-proven lethal (it shifts the landing point into
        # the block's side spikes), while the plinth passes clean.
        count, width = _core_middle_stats(plats, c.width)
        if (count < 2 or width < 160.0) and 420.0 <= sy < 436.0:
            pw = w + 48.0
            ppx, ppy = px - 24.0, sy - 16.0
            prect = (ppx, ppy, pw, 16.0)
            dotted = any(
                h["type"] == "dotted_line"
                and _overlap(prect, _rect_of(h))
                for h in hazards)
            if (0.0 <= ppx and ppx + pw <= 1280.0
                    and not _blocks_spawn_door(c, prect, spawn,
                                               door_pos)
                    and not _rect_hazard_overlap(prect, hazards)
                    and not dotted):
                plats.append(plat(ppx, ppy, pw, 16.0, "solid"))
                added.append(prect)
    return added


def add_core_middle_dressing(c, kk, salt, plats, hazards, spawn,
                             door_pos):
    """Fill the core middle (y 260..420) on levels that fail the
    rule-9 core-middle floor. Uniform code path for all archetypes;
    dense levels are skipped untouched. Returns the number of solid
    rects added (widening counts as 0: it changes no rect count)."""
    count, width = _core_middle_stats(plats, c.width)
    if count >= 2 and width >= 160.0:
        return 0
    base = len(plats)
    if count >= 2:
        _widen_core_rects(c, plats, hazards, spawn, door_pos, kk, salt)
        count, width = _core_middle_stats(plats, c.width)
        if count >= 2 and width >= 160.0:
            return 0
    _try_mid_beam(c, kk, salt, plats, hazards, spawn, door_pos)
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
    count, width = _core_middle_stats(plats, c.width)
    if count < 2 or width < 160.0:
        picked += _add_dressing_pillars(
            c, kk, salt + 400, plats, hazards, spawn, door_pos,
            2, intervals2, 160.0, existing=picked)
        count, width = _core_middle_stats(plats, c.width)
    if count < 2 or width < 160.0:
        # Stacked pillars on blocks/steps (far edge only): the only
        # route-safe fill where the beam is gated off and no quiet
        # floor stretch exists (D18 wall-spikes).
        _add_stacked_pillars(c, kk, salt, plats, hazards, spawn,
                             door_pos)
        count, width = _core_middle_stats(plats, c.width)
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

_CORE_TOP = 260       # rule-9 core-middle band (mirrors the checker)
_CORE_BOTTOM = 420


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
    count, width = _core_middle_stats(plats, c.width)
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
                or y + h > c.bar_y:
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
             plat(dx + 20, c.bar_y - 24, dw - 40, 24, "solid"),
             plat(fx + 20, c.bar_y - 24, fw - 40, 24, "solid")]
    pit_top = c.bar_y - 24
    hazards = [spikes_up(dx + 20, dw - 40, top=pit_top),
               spikes_up(fx + 20, fw - 40, top=pit_top)]
    sw = g(kk, [60, 80], salt=salt + 6)
    hazards.append(spikes_up(dx - 40 - sw, sw))
    lead = g(kk, [160, 190, 220], salt=salt + 7)
    delay = g(kk, [0.25, 0.35, 0.45], salt=salt + 7)
    idx = len(hazards)
    hazards.append(triggered_strip(tx, tw, lead, delay))
    dotted(hazards, tx - lead - 8, 400, 16, 96, idx)
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
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
        dotted(hazards, x, 420, w, 8, idx)
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
        dotted(hazards, x - lead - 8, 400, 16, 96, idx)
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


def b_triggered_pillars(c, kk, salt):
    px = 580 + sh(kk, 40, 3, salt=salt + 1)
    py = g(kk, [130, 150, 170], salt=salt + 1)
    pw = g(kk, [52, 60, 68], salt=salt + 1)
    ph = g(kk, [104, 116, 128], salt=salt + 1)
    speed = g(kk, [700, 800, 900], salt=salt + 2)
    trig = pillar_safe_trigger(c, px, py, ph, speed,
                               extra=g(kk, [0, 20], salt=salt + 2))
    hazards = [pillar_triggered(px, py, pw, ph, trig, speed)]
    dotted(hazards, trig - 8, 400, 16, 96, 0)
    hx = px + pw + 170 + (kk % 2) * 40
    hazards.append(spikes_up(min(hx, 960),
                             g(kk, [60, 80, 100], salt=salt + 3)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


def b_periodic_pillars(c, kk, salt):
    px = 560 + sh(kk, 40, 4, salt=salt + 1)
    py = g(kk, [130, 150, 170], salt=salt + 1)
    pw = g(kk, [52, 60], salt=salt + 1)
    ph = g(kk, [104, 116, 128], salt=salt + 1)
    period = g(kk, [3.6, 4.0, 4.4], salt=salt + 2)
    phase = g(kk, [0.0, 0.5, 1.0], salt=salt + 2)
    speed = g(kk, [600, 650, 700], salt=salt + 2)
    hazards = [pillar_periodic(px, py, pw, ph, period, phase, speed)]
    dotted(hazards, px - 10, 345, pw + 20, 8, 0)
    hx = px + pw + 170 + (kk % 2) * 40
    hazards.append(spikes_up(min(hx, 960),
                             g(kk, [60, 80, 100], salt=salt + 3)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
    dotted(hazards, piv_x - 40, 200, 80, 8, 0)
    arm = rest_y - piv_y
    swept_right = piv_x + arm * math.sin(math.radians(arc) / 2.0) + r
    hx = min(int(swept_right) + 160, 960)
    hazards.append(spikes_up(hx, g(kk, [60, 80], salt=salt + 3)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
    plats = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
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
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
    plats = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
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
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


def b_wall_spikes(c, kk, salt):
    lx = 520 + sh(kk, 40, 4, salt=salt + 1)
    lw = g(kk, [180, 220], salt=salt + 1)
    # Floor block with side spikes (rule 7): the v1 floating ledge
    # cannot be supported without blocking the walk-under route, so
    # the spikes now guard the sides of a jumpable floor block.
    bh = g(kk, [80, 90, 100], salt=salt + 1)
    plats = [floor_seg(c, 0, 1280),
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
    plats = [floor_seg(c, 0, 1280)]
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
    return [floor_seg(c, 0, 1280)], hazards, spawn, door

def b_timed_mixes(c, kk, salt):
    gx = 620 + sh(kk, 40, 4, salt=salt + 1)
    gw = g(kk, [110, 120], salt=salt + 1)
    sw = g(kk, [80, 90], salt=salt + 1)
    stop = g(kk, [460, 470, 480], salt=salt + 1)
    period, on = g(kk, [(2.6, 1.8), (3.0, 2.0), (3.2, 2.2)], salt=salt + 1)
    stone = plat(gx + (gw - sw) // 2, stop, sw, 20, "dashed",
                 period=period, phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 1),
                 on_time=on)
    plats = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
    hazards = []
    px = 260 + (kk % 3) * 40
    pperiod, pon = g(kk, [(2.6, 1.2), (3.0, 1.4), (3.4, 1.6)], salt=salt + 2)
    idx = len(hazards)
    hazards.append(spikes_up(px, g(kk, [80, 100], salt=salt + 2),
                             period=pperiod,
                             phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 2),
                             on_time=pon))
    dotted(hazards, px, 420, 100, 8, idx)
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
    dotted(hazards, trig - 8, 400, 16, 96, 0)
    p2x = 880 + sh(kk, 40, 4, salt=salt + 3)
    p2w = g(kk, [52, 60], salt=salt + 3)
    p2h = g(kk, [104, 116, 128], salt=salt + 3)
    p2y = g(kk, [130, 150, 170], salt=salt + 3)
    idx = len(hazards)
    hazards.append(pillar_periodic(
        p2x, p2y, p2w, p2h, g(kk, [3.6, 4.0, 4.4], salt=salt + 4),
        g(kk, [0.0, 0.5, 1.0], salt=salt + 4),
        g(kk, [600, 650, 700], salt=salt + 4)))
    dotted(hazards, p2x - 10, 345, p2w + 20, 8, idx)
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
            dotted(hazards, trig - 8, 400, 16, 96, idx)
        else:
            idx = len(hazards)
            hazards.append(pillar_periodic(
                px, py, pw, ph, g(kk, [3.8, 4.0, 4.4], salt=salt + j + 2),
                g(kk, [0.0, 0.5, 1.0], salt=salt + j + 2),
                g(kk, [600, 650], salt=salt + j + 2)))
            dotted(hazards, px - 10, 345, pw + 20, 8, idx)
    hx = 200 + (kk % 2) * 40
    hazards.append(spikes_up(hx, g(kk, [60, 80], salt=salt + 5)))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
    plats = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
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
    dotted(hazards, min(hx, 950), 420, 100, 8, idx)
    spawn, door = flat_spawn_door(kk, salt)
    return plats, hazards, spawn, door


def b_mover_lifts(c, kk, salt):
    ledge_x = 540 + sh(kk, 40, 4, salt=salt + 1)
    ledge_w = g(kk, [220, 240, 260], salt=salt + 1)
    ledge_top = g(kk, [420, 430, 440], salt=salt + 1)
    mover_x = ledge_x - 140
    dy = (ledge_top - FLOOR_TOP) + g(kk, [0, -10, 10], salt=salt + 2)
    plats = [floor_seg(c, 0, 1280),
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
                 floor_seg(c, 0, 1280)]
    else:
        plats = [plat(0, tops[0], E1, 20, "solid"),
                 plat(E2, tops[1], PR - E2, 20, "solid"),
                 plat(0, tops[2], E1, 20, "solid"),
                 plat(E2, tops[3], PR - E2, 20, "solid"),
                 floor_seg(c, 0, 1280)]
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
        plats = [floor_seg(c, 0, 1280)]
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
            dotted(hazards, trig - 8, 400, 16, 96, idx)
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
        plats = [plat(0, t1, X1, c.bar_y - t1, "solid"),
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
                 floor_seg(c, 0, 1280)]
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
                hazards.append(spikes_down((lx + rx - w) // 2, w, y, 28))
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
             floor_seg(c, 0, 1280),
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
             floor_seg(c, 0, 1280)]
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
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
             plat(p1 + 20, c.bar_y - 24, gw1 - 40, 24, "solid"),
             plat(p2 + 20, c.bar_y - 24, gw2 - 40, 24, "solid")]
    pit_top = c.bar_y - 24
    hazards = [spikes_up(p1 + 20, gw1 - 40, top=pit_top),
               spikes_up(p2 + 20, gw2 - 40, top=pit_top),
               spikes_up(200, g(kk, [60, 80], salt=salt + 3))]
    tx1 = p1 + gw1 + 120
    tw1 = g(kk, [70, 80], salt=salt + 3)
    lead1 = g(kk, [170, 190, 210], salt=salt + 3)
    delay1 = g(kk, [0.25, 0.35, 0.45], salt=salt + 3)
    idx = len(hazards)
    hazards.append(triggered_strip(tx1, tw1, lead1, delay1))
    dotted(hazards, tx1 - lead1 - 8, 400, 16, 96, idx)
    tx2 = p2 + gw2 + 140
    tw2 = g(kk, [80, 100], salt=salt + 4)
    lead2 = g(kk, [170, 190, 210], salt=salt + 4)
    delay2 = g(kk, [0.25, 0.35, 0.45], salt=salt + 4)
    idx = len(hazards)
    hazards.append(triggered_strip(tx2, tw2, lead2, delay2))
    dotted(hazards, tx2 - lead2 - 8, 400, 16, 96, idx)
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
            hazards.append(spikes_down(mid - w // 2, w, y, 28))
    spawn, door = flat_spawn_door(kk, salt)
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


def b_ceiling_gauntlets(c, kk, salt):
    px = g(kk, [300, 340, 380], salt=salt + 1)
    pw = g(kk, [52, 60], salt=salt + 1)
    ph = g(kk, [104, 116], salt=salt + 1)
    py = g(kk, [130, 150], salt=salt + 1)
    hazards = [pillar_periodic(
        px, py, pw, ph, g(kk, [3.8, 4.0, 4.4], salt=salt + 2),
        g(kk, [0.0, 0.5, 1.0], salt=salt + 2),
        g(kk, [600, 650], salt=salt + 2))]
    dotted(hazards, px - 10, 345, pw + 20, 8, 0)
    for j, sx in enumerate((g(kk, [600, 700], salt=salt + 3),
                            g(kk, [850, 950], salt=salt + 4))):
        hazards.append(spikes_down(
            sx, g(kk, [90, 120, 150], salt=salt + 3 + j),
            g(kk, [232, 244, 252], salt=salt + 3 + j), 28))
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
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
    plats = [floor_seg(c, 0, 1280),
             plat(48, beam_top, 1184, 20, "solid"),
             plat(0, beam_top, 48, c.bar_y - beam_top, "solid"),
             plat(1232, beam_top, 48, c.bar_y - beam_top, "solid")]
    pcx = cx0 + 110
    r = g(kk, [30, 32, 34], salt=salt + 2)
    arc = g(kk, [12, 14, 16], salt=salt + 2)
    period = g(kk, [3.4, 3.8, 4.2], salt=salt + 2)
    hazards = [saw_swing(pcx, FLOOR_TOP - r + 2, pcx, beam_top + 10,
                         arc, period, r)]
    dotted(hazards, pcx - 40, 200, 80, 8, 0)
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
    plats = [floor_seg(c, 0, 1280),
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
    dotted(hazards, px - 10, 345, pw + 20, 8, 0)
    gx = px + pw + 60
    gw = g(kk, [110, 120], salt=salt + 3)
    sw = g(kk, [80, 90], salt=salt + 3)
    stop = g(kk, [460, 470, 480], salt=salt + 3)
    period, on = g(kk, [(2.6, 1.8), (3.0, 2.0)], salt=salt + 3)
    stone = plat(gx + (gw - sw) // 2, stop, sw, 20, "dashed",
                 period=period, phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 3),
                 on_time=on)
    plats[0:1] = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
    hx = gx + gw + 100
    pperiod, pon = g(kk, [(2.6, 1.2), (3.0, 1.4)], salt=salt + 4)
    idx = len(hazards)
    hazards.append(spikes_up(hx, g(kk, [80, 100], salt=salt + 4),
                             period=pperiod,
                             phase=g(kk, [0.0, 0.5, 1.0], salt=salt + 4),
                             on_time=pon))
    dotted(hazards, hx, 420, 100, 8, idx)
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
    return [floor_seg(c, 0, 1280)], hazards, spawn, door


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
    dotted(hazards, px - 10, 345, pw + 20, 8, 0)
    mid = g(kk, ["popup", "column", "popup"], salt=salt + 3)
    mx = 330 + sh(kk, 20, 3, salt=salt + 3)
    if mid == "popup":
        pperiod, pon = g(kk, [(2.6, 1.2), (3.0, 1.4)], salt=salt + 3)
        idx = len(hazards)
        hazards.append(spikes_up(mx, g(kk, [80, 100], salt=salt + 3),
                                 period=pperiod,
                                 phase=g(kk, [0.0, 0.5, 1.0],
                                         salt=salt + 3), on_time=pon))
        dotted(hazards, mx, 420, 100, 8, idx)
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
    plats = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
    r = g(kk, [28, 30], salt=salt + 6)
    hazards.append(saw_static(g(kk, [860, 890, 920], salt=salt + 6),
                              FLOOR_TOP - r + 4, r))
    for j, sx in enumerate((500, 760)):
        hazards.append(spikes_down(
            sx + sh(kk, 20, 2, salt=salt + 7 + j),
            g(kk, [90, 120], salt=salt + 7 + j),
            g(kk, [232, 244], salt=salt + 7 + j), 28))
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
    lethal = [h for h in hazards if h.get("type") != "dotted_line"]
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
             and "period" not in h and h["y"] == FLOOR_TOP - 24]
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
                and "period" not in h and h["y"] == FLOOR_TOP - 24):
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
    drop_dist = max(0.0, float(ctx.bar_y) - (pillar["y"] + pillar["h"]))
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
            try:
                plats, hazards, spawn, door_pos = fn(ctx, kk, salt)
            except Exception as exc:  # builder bug: record, never crash
                import traceback
                if name not in traceback_shown:
                    traceback_shown.add(name)
                    traceback.print_exc()
                fail_kind, fail_detail = "invalid", "builder raised: %s" % exc
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
