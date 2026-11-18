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
SCHEMA_VERSION = 1  # LEVEL_SCHEMA.md (frozen contract version)
FLOOR_TOP = 500     # level-design choice (schema example uses 500); the
                    # control bar starts at tuning.json control_bar.y.
VARIANT_STRIDE = 3  # fixed stride so pilot (variant 1) stages are the
                    # same grid points as bulk variant-1 stages.
MAX_ATTEMPTS = 6    # grid-point retries per candidate before rejection.


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
    skyline dressing + ceiling strips are then provably clear of every
    jump arc (head at apex >= 380-153-44 = 183 > strip/ledge bottoms),
    every checker arc band, and every walking band. High routes
    (towers/terraces) carry their own upper structure instead."""
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


def add_skyline_dressing(c, kk, salt, platforms, hazards):
    """High isolated ledges (tops 60..140, bottoms <= 160) with spike
    or saw toppings, for LOW routes only. Ledges are unreachable
    decoration: >100px above every route surface and clear of every
    arc band, walking band, probe rect, and safe zone (see
    route_is_low). Toppings are ground-sitting spikes / static saws,
    so they cannot break the checker. Returns the number of ledges."""
    excl = dressing_exclusions(hazards)
    tops = [60, 100, 140, 80, 120]
    widths = [140, 180, 120, 200, 160]
    toppings = ["spikes", "saw", "none", "spikes", "saw"]
    n = g(kk, [2, 3, 3, 2], salt=salt)
    placed = []
    tried = 0
    for i in range(n):
        w = g(kk, widths, salt=salt + i * 3)
        top = g(kk, tops, salt=salt + i * 5)
        # Spread slot starts across the screen by (kk, i).
        starts = [x0 for x0 in range(140, 1181 - w, 40)]
        if not starts:
            continue
        order = [(tried * 5 + kk * 3 + i * 7) % len(starts)]
        order += [(order[0] + j * 3) % len(starts)
                  for j in range(1, len(starts))]
        for oi in order:
            tried += 1
            x0 = starts[oi]
            if any(_overlaps(x0, x0 + w, e0, e1) for (e0, e1) in excl):
                continue
            if any(_overlaps(x0 - 40, x0 + w + 40, p0, p1)
                   for (p0, p1) in placed):
                continue
            platforms.append(plat(x0, top, w, 20, "solid"))
            placed.append((x0, x0 + w))
            topping = g(kk, toppings, salt=salt + i * 7 + 1)
            if topping == "spikes":
                sw = g(kk, [48, 64, 80], salt=salt + i)
                sx = x0 + (w - sw) // 2
                hazards.append(spikes_up(sx, sw, top=top))
            elif topping == "saw":
                r = g(kk, [26, 28], salt=salt + i)
                hazards.append(saw_static(x0 + w // 2, top - r + 4, r))
            break
    return len(placed)


def add_ceiling_strip(c, kk, salt, platforms, hazards):
    """One static dir-down ceiling spike strip for LOW routes that
    still lack an upper-band element. Tier-a (bottom 260..280) with
    220px buffers around raised takeoffs/gaps; tier-b (bottom
    168..192) only where it clears the highest takeoff's jump head
    (bottom <= min_takeoff_top - 200). Returns True if placed."""
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
                              for (e0, e1) in hard)]
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
             floor_seg(c, fx + fw, 1280)]
    hazards = [spikes_up(dx + 20, dw - 40, top=c.bar_y),
               spikes_up(fx + 20, fw - 40, top=c.bar_y)]
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
    piv_y = g(kk, [120, 140], salt=salt + 1)
    rest_y = g(kk, [425, 430, 435], salt=salt + 1)
    r = g(kk, [30, 32, 34], salt=salt + 1)
    arc = g(kk, [50, 60, 70], salt=salt + 1)
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
    y2 = g(kk, [348, 358, 368], salt=salt + 1)
    period = g(kk, [3.0, 3.4, 3.8], salt=salt + 1)
    hazards = [saw_path(cx, 468, cx, y2, period, r)]
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
    ly = g(kk, [280, 296], salt=salt + 1)
    plats = [floor_seg(c, 0, 1280), plat(lx, ly, lw, 24, "solid")]
    hazards = [spikes_side(lx - 20, ly, 20, 24, "left"),
               spikes_side(lx + lw, ly, 20, 24, "right"),
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
    x1 = px + 20
    x2 = x1 + w + 30
    s1 = plat(x1, FLOOR_TOP, w, 20, kind1,
              stand_time=g(kk, [1.0, 1.2, 1.4], salt=salt + 1))
    s2 = plat(x2, FLOOR_TOP, w, 20, kind2,
              stand_time=g(kk, [1.0, 1.2, 1.4], salt=salt + 2))
    plats = [floor_seg(c, 0, px), s1, s2, floor_seg(c, px + pw, 1280)]
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
    sx = min(gx + gw + 280, 1000)  # swept bbox must clear door safe zone
    hazards.append(saw_path(sx, 468, sx, g(kk, [348, 358], salt=salt + 3),
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
                 dashed_floor(0, tops[2], E1, 2),
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
        "T": [100, 110, 120], "S": [90, 95], "E1": [780, 820, 860],
        "G": [50, 60, 70], "padw": [150, 170, 190], "dashed": False,
        "f1_extra": "none", "f3_style": "strip", "ground_style": "column",
        "spawn_x": [80, 100, 120, 140],
        "door_x": [1130, 1150, 1170, 1190]})


def b_dashed_towers(c, kk, salt):
    return _tower_level(c, kk, salt, {
        "T": [105, 115], "S": [90, 95], "E1": [790, 830],
        "G": [55, 65], "padw": [160, 180], "dashed": True,
        "f1_extra": "none", "f3_style": "strip", "ground_style": "plain",
        "spawn_x": [90, 110, 130], "door_x": [1140, 1160, 1180]})


def b_final_tower_saws(c, kk, salt):
    return _tower_level(c, kk, salt, {
        "T": [90, 110, 130], "S": [92, 96], "E1": [760, 800, 840],
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
    floating only (its overlap landing zone spans the whole floor)."""
    T1 = g(kk, [120, 130, 140], salt=salt + 1)
    D = g(kk, [190, 200], salt=salt + 1)
    T2 = T1 + D
    sx = g(kk, [560, 600, 640], salt=salt + 2)
    sw = g(kk, [380, 400, 420], salt=salt + 2)
    rx = sx + sw
    plats = [plat(0, T1, sx, 20, "solid"),
             plat(rx, T1, 1280 - rx, 20, "solid"),
             plat(0, T2, sx, 20, "solid"),
             plat(rx, T2, 1280 - rx, 20, "solid"),
             floor_seg(c, 0, 1280)]
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
    # Shaft wall spikes (between floors, clear of every walking band).
    y1 = T1 + 60
    y2 = T2 + 60
    hazards.append(spikes_side(sx - 24, y1, 24, 48, "right"))
    hazards.append(spikes_side(rx, y1, 24, 48, "left"))
    if kk % 2 == 0:
        hazards.append(spikes_side(sx - 24, y2, 24, 48, "right"))
        hazards.append(spikes_side(rx, y2, 24, 48, "left"))
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
    # Door x >= 1160: the y2 wall spike at rx (max 1060) + 24 must stay
    # 40px clear of the door rect (door.x - 27 >= 1133).
    door = (g(kk, [1160, 1180, 1200], salt=salt + 21), FLOOR_TOP)
    return plats, hazards, spawn, door


def b_zigzag_descents(c, kk, salt):
    """Short floating floors zigzagging down, joined by gap edges on
    one shared corridor boundary (no higher floor spans a corridor).
    The autopilot descends the left side; humans zigzag."""
    T = g(kk, [90, 95, 100], salt=salt + 1)
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
             floor_seg(c, p2 + gw2, 1280)]
    hazards = [spikes_up(p1 + 20, gw1 - 40, top=c.bar_y),
               spikes_up(p2 + 20, gw2 - 40, top=c.bar_y),
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
    plats = [floor_seg(c, 0, 1280), plat(cx0, 300, cw, 20, "solid")]
    pcx = cx0 + 110
    r = g(kk, [30, 32, 34], salt=salt + 2)
    arc = g(kk, [50, 60, 70], salt=salt + 2)
    period = g(kk, [3.4, 3.8, 4.2], salt=salt + 2)
    hazards = [saw_swing(pcx, 430, pcx, 300, arc, period, r)]
    dotted(hazards, pcx - 40, 200, 80, 8, 0)
    scx = cx0 + cw - 110
    hazards.append(saw_path(scx, 468, scx, g(kk, [348, 358], salt=salt + 3),
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
             plat(cx0, 300, px - 30 - cx0, 20, "solid"),
             plat(px + pw + 30, 300, cx0 + cw - (px + pw + 30), 20, "solid")]
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
    stal = [(40, 200), (60, 200), (40, 220), (60, 180), (80, 200)]
    nstal = g(kk, [2, 3, 2, 3], salt=salt + 5)
    bases = [300, 600, 900]
    for j in range(nstal):
        y, h = g(kk, stal, salt=salt + 5 + j)
        hazards.append({"type": "spiked_column",
                        "x": int(bases[j] + sh(kk, 40, 3, salt=salt + j)),
                        "y": int(y),
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
    (21, 3, 3),
    (34, 1, 3),
    (40, 5, 3),
    (44, 2, 4),
    (44, 3, 4),
    (44, 4, 4),
]
EXTEND_PER_SLOT = 3


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


EXTEND_SCORERS = {
    21: _score_pit_bridges,
    34: _score_trigger_pits,
    40: _score_column_forests,
    44: _score_final_mega,
}


def _finish_candidate(ctx, kk, salt, plats, hazards, spawn, door_pos):
    """Finish passes for one extend-mode draw.

    This DUPLICATES the finish block in main() (same functions, same
    order, same salt offsets) so main() itself stays untouched. Returns
    (platforms, hazards) or None when the draw fails the upper-band /
    lethal-hazard requirements.
    """
    plats = [dict(p) for p in plats]
    hazards = [dict(h) for h in hazards]
    normalize_ground(ctx, plats)
    low = route_is_low(ctx, plats, spawn, door_pos)
    if low:
        add_skyline_dressing(ctx, kk, salt + 50, plats, hazards)
        if not has_upper_band(plats, hazards, spawn):
            add_ceiling_strip(ctx, kk, salt + 60, plats, hazards)
    if not has_upper_band(plats, hazards, spawn):
        return None
    if not has_lethal_hazard(hazards):
        if low and add_ceiling_strip(ctx, kk, salt + 70, plats, hazards):
            pass
        else:
            return None
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
        chk = check_levels.LevelCheck(lv, i, tun).run()
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
    for (door, slot, first_variant) in EXTEND_SLOTS:
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
                level = {"id": cid, "palette": door - 1,
                         "spawn": {"x": int(spawn[0]),
                                   "y": int(spawn[1])},
                         "door": {"x": int(door_pos[0]),
                                  "y": int(door_pos[1])},
                         "platforms": plats2, "hazards": hazards2,
                         "template": name, "variation": cid}
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
                add_skyline_dressing(ctx, kk, salt + 50, plats, hazards)
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
            level = {"id": cid, "palette": door - 1,
                     "spawn": {"x": int(spawn[0]), "y": int(spawn[1])},
                     "door": {"x": int(door_pos[0]), "y": int(door_pos[1])},
                     "platforms": plats, "hazards": hazards,
                     "template": name, "variation": cid}
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
