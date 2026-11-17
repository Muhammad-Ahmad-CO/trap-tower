#!/usr/bin/env python3
"""Trap Tower level generator (sole producer of godot/data/levels.json).

Data-driven: ~25 hand-designed ORIGINAL templates x systematic variations.
Every candidate is verified with the repo's own static verifier
(tools/check_levels.py, imported -- never copied) before it is accepted:
schema + reachability + timing windows + the LEVEL_SCHEMA.md distinctness
rule (canonical signature EXCLUDING palette; >= 2 of {layout geometry,
trap set/params, solution path} must differ). Palette-only / mirror-only /
trivial-shift duplicates are rejected, as are schema-invalid candidates.

Physics numbers are ALWAYS loaded from godot/data/tuning.json, never
duplicated here. Design envelope (conservative harness envelope from
tuning.json): rise <= 100, gap <= 170, landing >= 48, run-up >= 60,
timed-hazard safe window >= 0.7s. All jumps are designed well inside it
(rise <= 90, gap <= 160) with visible landings, run-ups, and safe waiting
spots before every timed hazard, so the greedy autopilot (move toward the
door, jump on hazard/gap/wall, wait on safe ground before timed hazards)
can solve every level. No backtracking, no mid-air waits, no pixel-perfect
jumps, no leaps of faith.

Deterministic: fixed seed, fixed variation grids. Stdlib only.

Ground normalization (defect #1 fix): every solid platform on the main
ground line extends to the control-bar line (y = bar_y from tuning);
the old alternating 64/80px floor depths left visible slits. Pits stay
open (no platform = gap); tops never move.

Density (defect #4 fix): every non-teaching level carries >= 1
upper-band element (top above y=300, lowest point >= 200px above the
takeoff surface below it). Levels whose template already proves one
(triggered/periodic hanging pillars) keep it; all others gain one
static ceiling-spike strip placed clear of every jump arc (see
add_upper_band). Static strips never disable the autopilot's
ballistic planner, unlike moving/dashed/falling/tilting platforms,
hanging pillars, and path/swing saws.

Usage:
  python3 tools/generate_levels.py [--out PATH] [--tuning PATH]
                                   [--seed N] [--min-levels N]
                                   [--keep-ids FILE]

With --keep-ids FILE (one level ID per line), generation runs exactly
as before (same seed/logic, deterministic) and the generated levels
are then filtered to the listed IDs, preserving generation order,
original IDs, schema_version, tuning_version, and every kept level's
content byte-for-byte. Unknown IDs in the file are a hard error and
nothing is written.
"""

import argparse
import json
import math
import random
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
SPAWN = (70, 500)
DOOR = (1210, 500)


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
        self.door_w = self.tuning.door_w
        self.door_h = self.tuning.door_h
        self.n_palettes = self.tuning.n_palettes
        self.apex = self.tuning.apex


def load_tuning(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Variation-grid helpers (coarse steps only, so signature buckets differ)
# ---------------------------------------------------------------------------

def g(vi, opts, salt=0):
    """Cyclic pick from an option list (deterministic variation grid)."""
    return opts[(vi + salt) % len(opts)]


def sh(vi, step, n, salt=0):
    """Centred coarse shift: n steps of `step` px, e.g. -60,-20,20,60."""
    return ((vi + salt) % n) * step - ((n - 1) * step) // 2


def row_positions(start, widths, clears):
    """Left-to-right x positions for widths with `clears` gaps between."""
    xs = [start]
    for i, w in enumerate(widths[:-1]):
        xs.append(xs[-1] + w + clears[i])
    return xs


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


def pillar_periodic(x, y, w, h, period, phase, speed):
    return {"type": "hanging_pillar", "x": int(x), "y": int(y),
            "w": int(w), "h": int(h), "period": float(period),
            "phase": float(phase), "drop_speed": int(speed)}


def dotted(hazards, x, y, w, h, linked):
    """Append a dotted-line warning linked to hazards[linked]."""
    hazards.append({"type": "dotted_line", "x": int(x), "y": int(y),
                    "w": int(w), "h": int(h), "linked": int(linked)})


def stone_in_gap(kind, sx, top, w, vi, salt=0):
    """A gap-bridging special platform (dashed/falling/tilting/moving)."""
    if kind == "dashed":
        period, on = g(vi, [(2.6, 1.8), (3.0, 2.0), (3.2, 2.2),
                            (2.8, 1.9)], salt=salt)
        return plat(sx, top, w, 20, "dashed", period=period,
                    phase=g(vi, [0.0, 0.5, 1.0], salt=salt + 1),
                    on_time=on)
    if kind in ("falling", "tilting"):
        return plat(sx, top, w, 20, kind,
                    stand_time=g(vi, [1.0, 1.2, 1.4], salt=salt))
    # moving: horizontal shuttle, small travel, generous period.
    return plat(sx, top, w, 20, "moving",
                dx=g(vi, [50, 60, 70, 80], salt=salt), dy=0,
                period=g(vi, [2.4, 2.8, 3.2], salt=salt + 1))


# ---------------------------------------------------------------------------
# Finish pass: step block (layout variety) + floor split (layout variety)
# ---------------------------------------------------------------------------

def _overlaps(a0, a1, b0, b1):
    return a0 < b1 and b0 < a1


def exclusion_intervals(c, platforms, hazards):
    """x-intervals where a step block must NOT go (jump/landing/timing
    safety: blocks are mount-jumped by the autopilot, so they must stay
    clear of gaps, timed-hazard zones, pillar drop zones, and anything
    hanging low enough to bonk a jump arc)."""
    excl = []
    # Gaps between floor segments.
    floors = sorted([p for p in platforms
                     if p["kind"] == "solid" and p["y"] == FLOOR_TOP],
                    key=lambda p: p["x"])
    for a, b in zip(floors, floors[1:]):
        if b["x"] > a["x"] + a["w"]:
            excl.append((a["x"] + a["w"] - 50, b["x"] + 50))
    for p in platforms:
        if p["kind"] == "solid" and p["y"] != FLOOR_TOP:
            if p["y"] + p["h"] <= 340:
                excl.append((p["x"] - 200, p["x"] + p["w"] + 200))
            else:
                excl.append((p["x"] - 70, p["x"] + p["w"] + 70))
        elif p["kind"] in ("dashed", "falling", "tilting", "moving"):
            xs = [p["x"], p["x"] + p.get("dx", 0)]
            excl.append((min(xs) - 80, max(xs) + p["w"] + 80))
    for h in hazards:
        t = h["type"]
        if t == "dotted_line":
            continue
        if t == "spikes":
            if h.get("dir", "up") == "up":
                x0 = h["x"]
                if "trigger_x" in h:
                    x0 = min(x0, h["trigger_x"])
                excl.append((x0 - 70, h["x"] + h["w"] + 70))
            else:
                excl.append((h["x"] - 200, h["x"] + h["w"] + 200))
        elif t == "spiked_column":
            excl.append((h["x"] - 70, h["x"] + h["w"] + 70))
        elif t == "saw":
            if "swing" in h:
                s = h["swing"]
                L = abs(h["y"] - s["pivot_y"])
                half = L * math.sin(math.radians(s["arc_deg"]) / 2.0) \
                    + h["r"]
                excl.append((h["x"] - half - 40, h["x"] + half + 40))
            elif "path" in h:
                if h["y"] >= 510:  # gap saw below floor level
                    continue
                excl.append((h["x"] - h["r"] - 80, h["x"] + h["r"] + 80))
            else:
                excl.append((h["x"] - h["r"] - 70, h["x"] + h["r"] + 70))
        elif t == "hanging_pillar":
            excl.append((h["x"] - 170, h["x"] + h["w"] + 170))
    return excl


def add_step_block(c, rng, vi, platforms, hazards, salt=0):
    """One mountable step block (rise 48-80) in a verified-clear slot.
    Gives every level layout/solution variety the floor alone lacks.
    The slot is spread across ALL fitting slots by (salt, vi) so
    different templates/variations do not funnel onto one layout."""
    excl = exclusion_intervals(c, platforms, hazards)
    w = g(vi, [100, 120, 140], salt=11 + salt)
    h = g(vi, [48, 64, 80], salt=12 + salt)
    fitting = [x0 for x0 in range(200, 1061, 40)
               if x0 + w <= 1160 and not any(
                   _overlaps(x0, x0 + w, e0, e1) for (e0, e1) in excl)]
    if not fitting:
        return False
    x0 = fitting[(salt * 7 + vi * 3) % len(fitting)]
    platforms.append(plat(x0, FLOOR_TOP - h, w, h + 80, "solid"))
    return True


def split_forbidden(c, platforms, hazards):
    """x-intervals where a floor-split seam must NOT go. A seam edge is
    a zero-gap edge whose corridor is a single point: any hazard near
    it can reject the edge (landing-zone overlap, jump-arc overlap, or
    the per-node saw jump-over span test), orphaning the door side.
    Keep-outs cover all of those, plus every non-floor platform (a
    block/ledge/stone straddling the seam blocks the seam edge)."""
    forb = []
    for h in hazards:
        t = h["type"]
        if t == "dotted_line":
            continue
        if t == "saw" and "swing" in h:
            s = h["swing"]
            L = abs(h["y"] - s["pivot_y"])
            half = L * math.sin(math.radians(s["arc_deg"]) / 2.0) + h["r"]
            forb.append((h["x"] - half - 30, h["x"] + half + 30))
        elif t == "saw" and "path" in h and h["y"] >= 510:
            continue  # gap saw below floor level; seams never reach gaps
        elif t == "saw":
            # Keep-out must cover the whole jump-over span
            # [cx-r-30, cx+r+30] the verifier tests per platform node,
            # plus margin: a seam inside the span orphans the saw.
            forb.append((h["x"] - h["r"] - 55, h["x"] + h["r"] + 35))
        else:
            forb.append((h["x"] - 55, h["x"] + h["w"] + 10))
    for p in platforms:
        if p["kind"] == "solid" and p["y"] == FLOOR_TOP:
            continue
        forb.append((p["x"] - 30, p["x"] + p["w"] + 30))
        if p["kind"] == "moving":
            x2 = p["x"] + p.get("dx", 0)
            forb.append((x2 - 30, x2 + p["w"] + 30))
    return forb


def add_floor_splits(c, ti, vi, platforms, hazards, extra=0):
    """Split long floor segments at clear x positions (invisible seams,
    same top). Pure layout/solution-signature variety; nothing changes
    physically. The seam COUNT varies (0/1/2) so the solution jump
    sequence differs too, and seam positions spread across all fitting
    spots by (template, variation, extra)."""
    r = (ti * 3 + vi + extra * 2) % 6
    n = 0 if r == 0 else (2 if r == 3 else 1)
    for k in range(n):
        forb = split_forbidden(c, platforms, hazards)
        pairs = []
        for i, p in enumerate(platforms):
            if not (p["kind"] == "solid" and p["y"] == FLOOR_TOP
                    and p["w"] >= 300):
                continue
            x1, x2 = p["x"], p["x"] + p["w"]
            for x in range(320, 1041, 40):
                if x < x1 + 60 or x > x2 - 60:
                    continue
                if any(e0 <= x <= e1 for (e0, e1) in forb):
                    continue
                pairs.append((i, x))
        if not pairs:
            break
        i, x = pairs[(ti * 5 + vi * 3 + k * 2 + extra * 7) % len(pairs)]
        p = platforms[i]
        x1, x2 = p["x"], p["x"] + p["w"]
        platforms[i:i + 1] = [floor_seg(c, x1, x),
                              floor_seg(c, x, x2)]
    return True


def normalize_ground(c, platforms):
    """Ground normalization (defect #1 fix): every solid platform on
    the main ground line extends to the control-bar line (y = bar_y).
    Tops never move, so physics is untouched; pits stay open (no
    platform = gap). Floating ledges/stones whose bottoms stay above
    the floor line are untouched. (The old alternating 64/80px depths
    left background-coloured slits inside the ground mass.)"""
    for p in platforms:
        if p["kind"] != "solid":
            continue
        if p["y"] == FLOOR_TOP:
            p["h"] = c.bar_y - p["y"]
        elif p["y"] < FLOOR_TOP < p["y"] + p["h"] < c.bar_y:
            # A solid reaching past the floor line but stopping short
            # of the bar line would read as a floating slab: extend it.
            p["h"] = c.bar_y - p["y"]


# ---------------------------------------------------------------------------
# Upper-band density (defect #4 fix)
# ---------------------------------------------------------------------------
# Rule (strict): top above y=300 AND lowest point >= 200px above the
# takeoff surface below it. Jump apex from the frozen tuning is
# ~153px, so above floor takeoffs (500) a strip bottom <= 280 clears
# every jump arc's head (500-153-44 = 303) by >= 23px and the static
# checker's arc band (top >= 347) by >= 67px. Where a raised takeoff
# (step block / ledge / mover top, highest 420) could launch a jump
# under the strip, the strip goes HIGH (bottom <= 192), clearing
# step-jump heads (420-153-44 = 223) by >= 31px and every checker arc
# band (top >= 267) outright. Only STATIC ceiling spikes are added:
# they never disable the autopilot's ballistic planner.

UPPER_TOP = 300
STRIP_H = 28


def has_upper_band(platforms, hazards):
    """True if an existing element already satisfies the strict
    upper-band rule. Hanging pillars (the proven pillar templates)
    qualify with bottom <= 300 over the floor takeoff; ceiling/side
    spikes and floating columns/platforms need bottom <= 280 (head
    clearance over floor jumps)."""
    for h in hazards:
        t = h["type"]
        if t == "hanging_pillar":
            if h["y"] < UPPER_TOP and h["y"] + h["h"] <= 300:
                return True
        elif t == "spikes" and h.get("dir", "up") != "up":
            if h["y"] < UPPER_TOP and h["y"] + h["h"] <= 280:
                return True
        elif t == "spiked_column":
            if h["y"] < UPPER_TOP and h["h"] >= 120 \
                    and h["y"] + h["h"] <= 280:
                return True
    for p in platforms:
        if p["kind"] in ("dashed", "moving") and p["y"] < UPPER_TOP \
                and p["y"] + p["h"] <= 280:
            return True
    return False


def _platform_positions(p):
    """Rest rect + moving offset rect, as (x, y, w, h)."""
    r = (p["x"], p["y"], p["w"], p["h"])
    if p["kind"] == "moving":
        return [r, (r[0] + p.get("dx", 0), r[1] + p.get("dy", 0),
                    r[2], r[3])]
    return [r]


def _swing_swept_x(h):
    s = h["swing"]
    arm = abs(h["y"] - s["pivot_y"])
    half = arm * math.sin(math.radians(s["arc_deg"]) / 2.0) + h["r"]
    return (h["x"] - half, h["x"] + half)


def upper_exclusions(c, platforms, hazards, include_takeoffs):
    """Hard x-intervals a new ceiling strip must avoid. With
    include_takeoffs, raised takeoffs (any platform top above the
    floor, both moving positions) and gaps get 220px buffers, so no
    jump launched from a raised surface can pass under a low strip.
    Hanging pillars, existing high spikes, and moving-saw swept
    volumes are always excluded. Raised takeoffs are always excluded
    over their exact x-range (so the only surface directly below a
    new strip is the floor); with include_takeoffs they additionally
    get 220px buffers, so no jump launched from a raised surface can
    pass under a low strip."""
    excl = []
    for p in platforms:
        for (x, y, w, hh) in _platform_positions(p):
            if y < FLOOR_TOP:
                buf = 220 if include_takeoffs else 0
                excl.append((x - buf, x + w + buf))
    if include_takeoffs:
        floors = sorted([p for p in platforms
                         if p["kind"] == "solid" and p["y"] == FLOOR_TOP],
                        key=lambda p: p["x"])
        for a, b in zip(floors, floors[1:]):
            if b["x"] > a["x"] + a["w"]:
                excl.append((a["x"] + a["w"] - 220, b["x"] + 220))
    for h in hazards:
        t = h["type"]
        if t == "hanging_pillar":
            excl.append((h["x"] - 60, h["x"] + h["w"] + 60))
        elif t == "spikes" and h.get("dir", "up") != "up":
            excl.append((h["x"] - 60, h["x"] + h["w"] + 60))
        elif t == "saw":
            if "swing" in h:
                x0, x1 = _swing_swept_x(h)
                excl.append((x0 - 60, x1 + 60))
            elif "path" in h and h["y"] < 510:
                x2 = h["path"]["x2"]
                excl.append((min(h["x"], x2) - h["r"] - 60,
                             max(h["x"], x2) + h["r"] + 60))
    return excl


def _soft_exclusions(hazards):
    """x-intervals the strip prefers to avoid (floor hazards + dotted
    warnings): visual separation only -- the strip clears every floor
    jump arc regardless of horizontal position."""
    excl = []
    for h in hazards:
        t = h["type"]
        if t == "dotted_line":
            excl.append((h["x"] - 20, h["x"] + h["w"] + 20))
        elif t == "saw" and "path" not in h and "swing" not in h:
            excl.append((h["x"] - h["r"] - 80, h["x"] + h["r"] + 80))
        elif t == "spiked_column":
            excl.append((h["x"] - 80, h["x"] + h["w"] + 80))
        elif t == "spikes" and h.get("dir", "up") == "up":
            excl.append((h["x"] - 80, h["x"] + h["w"] + 80))
    return excl


def add_upper_band(c, ti, vi, platforms, hazards, extra=0):
    """Ensure one upper-band element. Returns 'existing' if the level
    already qualifies, 'tier-a' for a low strip (bottom 260-280) over
    plain floor, 'tier-b' for a high strip (bottom 168-192) where
    raised takeoffs crowd the level, 'fallback' for the last-resort
    high strip, or None if no slot exists (caller rejects).
    Deterministic: slot/params spread by (template, variation, extra).
    The strip is a static dir-down spike hazard: an existing schema
    type, no new fields, no dotted warning needed (it is neither
    triggered nor pop-up)."""
    if has_upper_band(platforms, hazards):
        return "existing"
    soft = _soft_exclusions(hazards)
    for tier, ys, takeoffs in (("tier-a", [232, 244, 252], True),
                               ("tier-b", [140, 152, 164], False)):
        w = g(vi, [90, 120, 150], salt=31 + ti + extra * 2)
        y = g(vi, ys, salt=32 + ti + extra)
        hard = upper_exclusions(c, platforms, hazards, takeoffs)
        fitting = [x0 for x0 in range(200, 1081 - w, 40)
                   if not any(_overlaps(x0, x0 + w, e0, e1)
                              for (e0, e1) in hard)]
        if not fitting:
            continue
        preferred = [x0 for x0 in fitting
                     if not any(_overlaps(x0, x0 + w, e0, e1)
                                for (e0, e1) in soft)]
        pool = preferred or fitting
        x0 = pool[(ti * 11 + vi * 5 + extra * 3) % len(pool)]
        hazards.append(spikes_down(x0, w, y, STRIP_H))
        return tier
    # Fine-grained last resort: the SAME tier-b (high strip) hard
    # rules, a smaller strip, and 20px steps. The strip still clears
    # every takeoff surface below it; only the slot search is finer.
    hard = upper_exclusions(c, platforms, hazards, False)
    for x0 in range(160, 1081 - 90, 20):
        if not any(_overlaps(x0, x0 + 90, e0, e1)
                   for (e0, e1) in hard):
            hazards.append(spikes_down(x0, 90, 140, STRIP_H))
            return "fallback"
    return None


def ensure_hazard(c, vi, platforms, hazards):
    """Safety net: levels after the first 3 must carry >= 1 lethal
    hazard (LEVEL_SCHEMA.md). Adds a spike strip in a verified-clear
    slot, or returns False if no safe slot exists (caller rejects)."""
    if any(h["type"] != "dotted_line" for h in hazards):
        return True
    excl = exclusion_intervals(c, platforms, hazards)
    for x in range(240, 1001, 40):
        if any(_overlaps(x, x + 80, e0 - 80, e1 + 80) for (e0, e1) in excl):
            continue
        hazards.append(spikes_up(x, 80))
        return True
    return False

# ---------------------------------------------------------------------------
# Templates. Each fn(c, rng, vi) -> (platforms, hazards).
# vi indexes the systematic variation grid; every variation changes BOTH
# geometry (coarse >= 40px / >= 16px steps) AND trap params/positions, so
# layout and trap signature dimensions both differ (distinctness needs 2).
# ---------------------------------------------------------------------------

def t_walk(c, rng, vi):
    """L001 teaching: walk to the door. No hazards."""
    return [floor_seg(c, 0, 1280)], []


def t_spike_hops(c, rng, vi):
    """Teaching + variations: static spike strips to hop over."""
    plats = [floor_seg(c, 0, 1280)]
    if vi == 0:  # L002: one small hop.
        specs = [(520, 80)]
    else:
        count = g(vi, [2, 3, 2, 3, 1, 2, 3, 2, 3, 2], salt=1)
        widths = [g(vi, [60, 80, 100, 120], salt=k) for k in range(count)]
        start = 360 + sh(vi, 40, 4, salt=1)
        xs = row_positions(start, widths, [150 + (vi % 3) * 20] * (count - 1))
        over = xs[-1] + widths[-1] - 1080
        if over > 0:
            xs = [x - over for x in xs]
        if xs[0] < 200:
            xs = [x + (200 - xs[0]) for x in xs]
        specs = list(zip(xs, widths))
    return plats, [spikes_up(x, w) for (x, w) in specs]


def t_dashed_bridge(c, rng, vi):
    """Teaching + variations: one gap bridged by a blinking platform.
    Total gap <= 140, so a full jump clears it even when the stone is
    off; the stone is a safe mid-hop when on."""
    if vi == 0:  # L003: one dashed platform, no hazards (index 2: allowed).
        gx, gw, sw, stop = 560, 120, 80, 470
        period, on, phase = 2.4, 1.6, 0.0
    else:
        gx = 480 + sh(vi, 40, 4, salt=2)
        gw = g(vi, [110, 120, 130, 140], salt=2)
        sw = g(vi, [80, 90, 100], salt=2)
        stop = g(vi, [460, 470, 480], salt=2)
        period, on = g(vi, [(2.6, 1.8), (3.0, 2.0), (3.2, 2.2),
                            (2.8, 1.9)], salt=2)
        phase = g(vi, [0.0, 0.5, 1.0], salt=2)
    sx = gx + (gw - sw) // 2
    plats = [floor_seg(c, 0, gx),
             plat(sx, stop, sw, 20, "dashed", period=period,
                  phase=phase, on_time=on),
             floor_seg(c, gx + gw, 1280)]
    hazards = []
    if vi >= 1:
        hx = gx + gw + 180 + (vi % 2) * 40
        hazards = [spikes_up(hx, g(vi, [60, 80, 100], salt=3))]
    return plats, hazards


def t_saw_jump(c, rng, vi):
    """Static saw blades to jump over (one per teaching level)."""
    count = 1 if vi == 0 else g(vi, [1, 2, 1, 2, 1, 2], salt=1)
    first = 600 if vi == 0 else 480 + sh(vi, 40, 4, salt=1)
    rs = [g(vi, [26, 30, 34], salt=k) for k in range(count)]
    cxs = [first]
    for _ in range(1, count):
        cxs.append(cxs[-1] + 300 + (vi % 2) * 40)
    hazards = [saw_static(cx, FLOOR_TOP - r + 4, r)
               for (cx, r) in zip(cxs, rs)]
    return [floor_seg(c, 0, 1280)], hazards


def t_popup_spikes(c, rng, vi):
    """Pop-up spike strips (lethal only while up) + dotted warnings.
    Off-time >= 1.2s: wait for the down-phase, then walk across."""
    count = 1 if vi == 0 else g(vi, [1, 2, 1, 2], salt=1)
    widths = [g(vi, [80, 100, 120], salt=k) for k in range(count)]
    start = 420 + sh(vi, 40, 4, salt=1)
    xs = row_positions(start, widths, [210] * (count - 1))
    period, on = g(vi, [(2.6, 1.2), (3.0, 1.4), (3.4, 1.6)], salt=2)
    phase0 = g(vi, [0.0, 0.5, 1.0], salt=3)
    hazards = []
    for k, (x, w) in enumerate(zip(xs, widths)):
        phase = round((phase0 + k * 0.7) % period, 1)
        idx = len(hazards)
        hazards.append(spikes_up(x, w, period=period, phase=phase,
                                 on_time=on))
        dotted(hazards, x, 420, w, 8, idx)
    return [floor_seg(c, 0, 1280)], hazards


def _gap_with_stone(c, vi, kind, salt):
    """Shared one-gap skeleton: gap + one special-platform stone + a
    spike strip on the far floor (safe landing + run-up respected)."""
    gx = 480 + sh(vi, 40, 4, salt=salt)
    gw = g(vi, [110, 120, 130, 140], salt=salt)
    sw = g(vi, [80, 90, 100], salt=salt)
    stop = g(vi, [460, 470, 480], salt=salt)
    if kind == "moving":
        sx = gx + 10 + (vi % 3) * 10
    else:
        sx = gx + (gw - sw) // 2
    stone = stone_in_gap(kind, sx, stop, sw, vi, salt=salt)
    plats = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
    hx = gx + gw + 180 + (vi % 2) * 40
    hazards = [spikes_up(hx, g(vi, [60, 80], salt=salt + 1))]
    return plats, hazards


def t_falling_floor(c, rng, vi):
    """Falling platform stone in a gap (stand_time >= 1.0s: cross
    calmly; the gap is jumpable even if the stone has dropped)."""
    return _gap_with_stone(c, vi, "falling", salt=5)


def t_moving_bridge(c, rng, vi):
    """Moving platform shuttling in a gap (small travel, slow period)."""
    return _gap_with_stone(c, vi, "moving", salt=6)


def t_pillar_drop(c, rng, vi):
    """Triggered hanging pillar: it drops when the player passes the
    trigger 150-200px ahead, lands before arrival, and is jumped over
    as a low (24-52px) block. Dotted warning at the trigger point.
    Pillar rests high (bottom <= 298): never blocks a jump arc."""
    px = 560 + sh(vi, 40, 4, salt=1)
    py = g(vi, [130, 150, 170], salt=1)
    pw = g(vi, [52, 60, 68], salt=1)
    ph = g(vi, [104, 116, 128], salt=1)
    trig = px - g(vi, [150, 180, 200], salt=2)
    speed = g(vi, [700, 800, 900], salt=2)
    hazards = [pillar_triggered(px, py, pw, ph, trig, speed)]
    dotted(hazards, trig - 8, 400, 16, 96, 0)
    if vi >= 1:
        hx = px + pw + 170 + (vi % 2) * 40
        hazards.append(spikes_up(hx, g(vi, [60, 80, 100], salt=3)))
    return [floor_seg(c, 0, 1280)], hazards


def t_swing_saw(c, rng, vi):
    """Pendulum saw over the path: blade dips into head height only
    near the centre of its swing; wait for it to swing away, then pass
    under. Long period (>= 3.4s), generous safe window."""
    piv_x = 600 + sh(vi, 40, 4, salt=1)
    piv_y = g(vi, [120, 140], salt=1)
    rest_y = g(vi, [425, 430, 435], salt=1)
    r = g(vi, [30, 32, 34], salt=1)
    arc = g(vi, [50, 60, 70], salt=1)
    period = g(vi, [3.4, 3.8, 4.2], salt=1)
    hazards = [saw_swing(piv_x, rest_y, piv_x, piv_y, arc, period, r)]
    dotted(hazards, piv_x - 40, 200, 80, 8, 0)
    if vi >= 1:
        L = rest_y - piv_y
        swept_right = piv_x + L * math.sin(math.radians(arc) / 2.0) + r
        hx = min(int(swept_right) + 160, 1000)
        hazards.append(spikes_up(hx, g(vi, [60, 80], salt=3)))
    return [floor_seg(c, 0, 1280)], hazards


def t_patrol_saw(c, rng, vi):
    """Saw patrolling vertically above the path: it dips into the
    walking band only at the bottom of its travel; wait for it to
    rise, then pass under."""
    cx = 580 + sh(vi, 40, 4, salt=1)
    r = g(vi, [28, 30, 32], salt=1)
    y2 = g(vi, [348, 358, 368], salt=1)
    period = g(vi, [3.0, 3.4, 3.8], salt=1)
    hazards = [saw_path(cx, 468, cx, y2, period, r)]
    if vi >= 1:
        if vi % 2 == 0:
            hx = cx + 170
            hazards.append(spikes_up(hx, g(vi, [60, 80, 100], salt=3)))
        else:
            hx = 200 + (vi % 3) * 40
            hazards.append(spikes_up(hx, g(vi, [60, 80], salt=3)))
    return [floor_seg(c, 0, 1280)], hazards


def t_spiked_column(c, rng, vi):
    """Short spiked columns (56-88px tall, 48-64 wide) to jump over."""
    count = g(vi, [1, 2, 2, 3], salt=1)
    widths = [g(vi, [48, 56, 64], salt=k) for k in range(count)]
    heights = [g(vi, [56, 72, 88], salt=k + 2) for k in range(count)]
    start = 400 + sh(vi, 40, 4, salt=1)
    xs = row_positions(start, widths, [160] * (count - 1))
    over = xs[-1] + widths[-1] - 1080
    if over > 0:
        xs = [x - over for x in xs]
    hazards = [column(x, h, w) for (x, w, h) in zip(xs, widths, heights)]
    return [floor_seg(c, 0, 1280)], hazards


def t_tilting_block(c, rng, vi):
    """Tilting block stone in a gap (drops after stand_time, like the
    falling floor with a tilt visual)."""
    return _gap_with_stone(c, vi, "tilting", salt=7)


def t_triggered_spikes(c, rng, vi):
    """Spike strips that arm only after the player passes a trigger
    160-220px ahead (short delay): by the time the player arrives the
    strip is up and visible, and is jumped like a static strip.
    Dotted warning at each trigger point."""
    count = g(vi, [1, 2], salt=1)
    widths = [g(vi, [80, 100, 120], salt=k) for k in range(count)]
    start = 420 + sh(vi, 40, 4, salt=1)
    xs = row_positions(start, widths, [230] * (count - 1))
    hazards = []
    for k, (x, w) in enumerate(zip(xs, widths)):
        trig = x - g(vi, [160, 190, 220], salt=2 + k)
        delay = g(vi, [0.25, 0.35, 0.45], salt=3 + k)
        idx = len(hazards)
        hazards.append(spikes_up(x, w, trigger_x=trig, delay=delay))
        dotted(hazards, trig - 8, 400, 16, 96, idx)
    return [floor_seg(c, 0, 1280)], hazards

def t_pillar_periodic(c, rng, vi):
    """Periodic hanging pillar: long hang (>= 2.4s), slow drop, then a
    1s rise. Wait on safe ground while it falls/rises, cross under it
    while it hangs high. Narrow block, dotted warning underneath."""
    px = 560 + sh(vi, 40, 4, salt=1)
    py = g(vi, [130, 150, 170], salt=1)
    pw = g(vi, [52, 60], salt=1)
    ph = g(vi, [104, 116, 128], salt=1)
    period = g(vi, [3.6, 4.0, 4.4], salt=2)
    phase = g(vi, [0.0, 0.5, 1.0], salt=2)
    speed = g(vi, [600, 650, 700], salt=2)
    hazards = [pillar_periodic(px, py, pw, ph, period, phase, speed)]
    dotted(hazards, px - 10, 345, pw + 20, 8, 0)
    if vi >= 1:
        hx = px + pw + 170 + (vi % 2) * 40
        hazards.append(spikes_up(hx, g(vi, [60, 80, 100], salt=3)))
    return [floor_seg(c, 0, 1280)], hazards


def t_gap_saw(c, rng, vi):
    """Saw patrolling horizontally inside a gap, below floor level:
    it threatens a short jump, never the walk. A stone bridges the
    gap; the gap itself is jumpable."""
    gx = 480 + sh(vi, 40, 4, salt=4)
    gw = g(vi, [110, 120, 130, 140], salt=4)
    sw = g(vi, [80, 90, 100], salt=4)
    stop = g(vi, [460, 470, 480], salt=4)
    kind = g(vi, ["dashed", "falling", "moving"], salt=4)
    if kind == "moving":
        sx = gx + 10 + (vi % 3) * 10
    else:
        sx = gx + (gw - sw) // 2
    stone = stone_in_gap(kind, sx, stop, sw, vi, salt=4)
    plats = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
    cx = gx + gw // 2
    cy = g(vi, [540, 548], salt=4)
    r = g(vi, [26, 28, 30], salt=4)
    dx = g(vi, [30, -30, 40, -40], salt=4)
    period = g(vi, [2.6, 3.0, 3.4], salt=4)
    hazards = [saw_path(cx, cy, cx + dx, cy, period, r)]
    hx = gx + gw + 180 + (vi % 2) * 40
    hazards.append(spikes_up(hx, g(vi, [60, 80], salt=5)))
    return plats, hazards


def t_ceiling_spikes(c, rng, vi):
    """Down-pointing spike strips hung high (bottom <= 340: above the
    walking band and above every jump arc that starts outside their
    200px jump-free buffers). Floor hops live outside the buffers."""
    x1 = 520 + sh(vi, 40, 4, salt=1)
    w1 = g(vi, [90, 120, 150], salt=1)
    y = g(vi, [280, 296, 312], salt=1)
    hazards = [spikes_down(x1, w1, y)]
    last_end = x1 + w1
    if vi % 2 == 1:
        w2 = g(vi, [90, 120], salt=2)
        x2 = x1 + w1 + 230
        hazards.append(spikes_down(x2, w2, y))
        last_end = x2 + w2
    hazards.append(spikes_up(200 + (vi % 3) * 40,
                             g(vi, [60, 80, 100], salt=3)))
    if vi % 2 == 0:
        hx = last_end + 200 + (vi % 2) * 40
        hazards.append(spikes_up(hx, g(vi, [60, 80], salt=4)))
    return [floor_seg(c, 0, 1280)], hazards


def t_wall_spikes(c, rng, vi):
    """Floating ledge with side spikes on both ends, hung high (bottom
    <= 320): purely a visual threat above the walk; floor hops live
    outside its 200px jump-free buffers."""
    lx = 520 + sh(vi, 40, 4, salt=1)
    lw = g(vi, [180, 220], salt=1)
    ly = g(vi, [280, 296], salt=1)
    plats = [floor_seg(c, 0, 1280), plat(lx, ly, lw, 24, "solid")]
    hazards = [spikes_side(lx - 20, ly, 20, 24, "left"),
               spikes_side(lx + lw, ly, 20, 24, "right"),
               spikes_up(200 + (vi % 3) * 40,
                         g(vi, [60, 80, 100], salt=3))]
    hx = min(lx + lw + 200 + (vi % 2) * 40, 1020)
    hazards.append(spikes_up(hx, 60))
    return plats, hazards


def t_step_climb(c, rng, vi):
    """Three mountable step blocks with spike hops in the wide gaps
    between them. Drops land on clear floor; hop landings land on the
    next block top (clear) or clear floor."""
    shift = sh(vi, 40, 3, salt=1)
    xs = [240 + shift, 620 + sh(vi, 40, 3, salt=2),
          1000 + sh(vi, 40, 4, salt=3)]
    ws = [g(vi, [100, 110, 120], salt=k) for k in range(2)]
    ws.append(g(vi, [100, 110], salt=2))
    hs = [g(vi, [48, 64, 80], salt=k + 2) for k in range(3)]
    plats = [floor_seg(c, 0, 1280)]
    for (x, w, h) in zip(xs, ws, hs):
        plats.append(plat(x, FLOOR_TOP - h, w, h + 80, "solid"))
    hazards = []
    for k in range(2):
        w = g(vi, [60, 80, 100], salt=5 + k)
        hx = xs[k] + ws[k] + 100 + (vi % 3) * 20
        hx = min(hx, xs[k + 1] - w - 10)
        hazards.append(spikes_up(hx, w))
    return plats, hazards


def t_double_gap(c, rng, vi):
    """Two gaps with a wide mid-platform (>= 200px: landing + run-up).
    One gap carries a below-floor patrol saw; stones bridge both."""
    g1 = 340 + sh(vi, 40, 4, salt=1)
    gw1 = g(vi, [110, 120, 130], salt=1)
    bw = 200 + (vi % 2) * 40
    g2 = g1 + gw1 + bw
    gw2 = g(vi, [110, 120, 130], salt=1)
    kind1 = g(vi, ["dashed", "falling"], salt=1)
    kind2 = g(vi, ["moving", "tilting"], salt=2)
    s1 = stone_in_gap(kind1, g1 + (gw1 - 90) // 2,
                      g(vi, [460, 470, 480], salt=1), 90, vi, salt=1)
    if kind2 == "moving":
        sx2 = g2 + 10 + (vi % 3) * 10
    else:
        sx2 = g2 + (gw2 - 90) // 2
    s2 = stone_in_gap(kind2, sx2, g(vi, [460, 470, 480], salt=2),
                      90, vi, salt=2)
    plats = [floor_seg(c, 0, g1), s1, floor_seg(c, g1 + gw1, g2), s2,
             floor_seg(c, g2 + gw2, 1280)]
    cx = g1 + gw1 // 2
    hazards = [saw_path(cx, 544, cx + g(vi, [30, -30], salt=3), 544,
                        g(vi, [2.6, 3.0, 3.4], salt=3), 28)]
    return plats, hazards


def t_pit_bridge(c, rng, vi):
    """Wide pit (220-260px: no direct jump) bridged by two falling /
    tilting stones at floor height with a 30px step between them.
    Walk across calmly: stand_time >= 1.0s, crossing takes ~0.7s."""
    px = 440 + sh(vi, 40, 4, salt=1)
    pw = g(vi, [220, 240, 260], salt=1)
    w = {220: 70, 240: 80, 260: 90}[pw]
    kind1 = g(vi, ["falling", "tilting"], salt=1)
    kind2 = g(vi, ["falling", "tilting"], salt=2)
    x1 = px + 20
    x2 = x1 + w + 30
    s1 = plat(x1, FLOOR_TOP, w, 20, kind1,
              stand_time=g(vi, [1.0, 1.2, 1.4], salt=1))
    s2 = plat(x2, FLOOR_TOP, w, 20, kind2,
              stand_time=g(vi, [1.0, 1.2, 1.4], salt=2))
    plats = [floor_seg(c, 0, px), s1, s2, floor_seg(c, px + pw, 1280)]
    hx = px + pw + 150 + (vi % 2) * 40
    hazards = [spikes_up(hx, g(vi, [60, 80], salt=3))]
    return plats, hazards


def t_gauntlet(c, rng, vi):
    """Dense flat-floor gauntlet: 3-4 static traps in a row (strips,
    saws, columns), each with >= 150px clear floor for landing +
    run-up."""
    pats = [["strip", "saw", "column"],
            ["saw", "strip", "strip"],
            ["column", "strip", "saw"],
            ["strip", "column", "strip", "saw"],
            ["saw", "column", "strip"]]
    pat = g(vi, pats, salt=1)
    slots = []
    for k, kind in enumerate(pat):
        if kind == "strip":
            slots.append(g(vi, [60, 80, 100, 120], salt=k))
        elif kind == "saw":
            slots.append(2 * g(vi, [26, 30, 34], salt=k) + 40)
        else:
            slots.append(g(vi, [48, 56, 64], salt=k))
    start = 340 + sh(vi, 40, 4, salt=1)
    xs = row_positions(start, slots, [150] * (len(slots) - 1))
    over = xs[-1] + slots[-1] - 1080
    if over > 0:
        xs = [x - over for x in xs]
    hazards = []
    for k, (kind, x, slot) in enumerate(zip(pat, xs, slots)):
        if kind == "strip":
            hazards.append(spikes_up(x, slot))
        elif kind == "saw":
            r = (slot - 40) // 2
            hazards.append(saw_static(x + slot // 2, FLOOR_TOP - r + 4, r))
        else:
            hazards.append(column(x, g(vi, [56, 72, 88], salt=k + 2),
                                  slot))
    return [floor_seg(c, 0, 1280)], hazards


def t_timed_mix(c, rng, vi):
    """Timed combination: pop-up strip, dashed gap stone, and a
    vertical patrol saw -- each with its own waiting room."""
    gx = 620 + sh(vi, 40, 4, salt=1)
    gw = g(vi, [110, 120], salt=1)
    sw = g(vi, [80, 90], salt=1)
    stop = g(vi, [460, 470, 480], salt=1)
    period, on = g(vi, [(2.6, 1.8), (3.0, 2.0), (3.2, 2.2)], salt=1)
    stone = plat(gx + (gw - sw) // 2, stop, sw, 20, "dashed",
                 period=period, phase=g(vi, [0.0, 0.5, 1.0], salt=1),
                 on_time=on)
    plats = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
    hazards = []
    px = 260 + (vi % 3) * 40
    pperiod, pon = g(vi, [(2.6, 1.2), (3.0, 1.4), (3.4, 1.6)], salt=2)
    idx = len(hazards)
    hazards.append(spikes_up(px, g(vi, [80, 100], salt=2),
                             period=pperiod,
                             phase=g(vi, [0.0, 0.5, 1.0], salt=2),
                             on_time=pon))
    dotted(hazards, px, 420, 100, 8, idx)
    sx = gx + gw + 280
    hazards.append(saw_path(sx, 468, sx, g(vi, [348, 358], salt=3),
                            g(vi, [3.0, 3.4], salt=3),
                            g(vi, [28, 30], salt=3)))
    return plats, hazards


def t_pillar_alley(c, rng, vi):
    """Two pillars: one triggered, one periodic, with a fully
    jump-free corridor between them. Floor-split seam supplies the
    layout variety (no step block fits the buffers)."""
    p1x = 420 + sh(vi, 40, 4, salt=1)
    p1w = g(vi, [52, 60, 68], salt=1)
    p1h = g(vi, [104, 116, 128], salt=1)
    p1y = g(vi, [130, 150, 170], salt=1)
    trig = p1x - g(vi, [150, 180, 200], salt=2)
    hazards = [pillar_triggered(p1x, p1y, p1w, p1h, trig,
                                g(vi, [700, 800, 900], salt=2))]
    dotted(hazards, trig - 8, 400, 16, 96, 0)
    p2x = 880 + sh(vi, 40, 4, salt=3)
    p2w = g(vi, [52, 60], salt=3)
    p2h = g(vi, [104, 116, 128], salt=3)
    p2y = g(vi, [130, 150, 170], salt=3)
    idx = len(hazards)
    hazards.append(pillar_periodic(
        p2x, p2y, p2w, p2h, g(vi, [3.6, 4.0, 4.4], salt=4),
        g(vi, [0.0, 0.5, 1.0], salt=4), g(vi, [600, 650, 700], salt=4)))
    dotted(hazards, p2x - 10, 345, p2w + 20, 8, idx)
    return [floor_seg(c, 0, 1280)], hazards


def t_grand_mix(c, rng, vi):
    """Three trap families in one level: spiked column, gap stone
    (kind varies), pop-up strip -- each in its own stretch."""
    gx = 560 + sh(vi, 40, 4, salt=1)
    gw = g(vi, [110, 120, 130], salt=1)
    kind = g(vi, ["dashed", "falling", "moving", "tilting"], salt=1)
    sw = g(vi, [80, 90, 100], salt=1)
    stop = g(vi, [460, 470, 480], salt=1)
    if kind == "moving":
        sx = gx + 10 + (vi % 3) * 10
    else:
        sx = gx + (gw - sw) // 2
    stone = stone_in_gap(kind, sx, stop, sw, vi, salt=1)
    plats = [floor_seg(c, 0, gx), stone, floor_seg(c, gx + gw, 1280)]
    hazards = [column(220 + sh(vi, 40, 3, salt=2),
                      g(vi, [64, 80], salt=2),
                      g(vi, [48, 56], salt=2))]
    hx = gx + gw + 180 + (vi % 2) * 40
    period, on = g(vi, [(2.6, 1.2), (3.0, 1.4), (3.4, 1.6)], salt=3)
    idx = len(hazards)
    hazards.append(spikes_up(hx, g(vi, [80, 100], salt=3),
                             period=period,
                             phase=g(vi, [0.0, 0.5, 1.0], salt=3),
                             on_time=on))
    dotted(hazards, hx, 420, 100, 8, idx)
    return plats, hazards


def t_mover_lift(c, rng, vi):
    """Vertical moving platform lifting the player to a raised ledge.
    The ledge is also directly mount-jumpable from the floor, so the
    lift is a helper, never a single point of failure."""
    ledge_x = 540 + sh(vi, 40, 4, salt=1)
    ledge_w = g(vi, [220, 240, 260], salt=1)
    ledge_top = g(vi, [420, 430, 440], salt=1)
    mover_x = ledge_x - 140
    dy = (ledge_top - FLOOR_TOP) + g(vi, [0, -10, 10], salt=2)
    plats = [floor_seg(c, 0, 1280),
             plat(ledge_x, ledge_top, ledge_w, 20, "solid"),
             plat(mover_x, FLOOR_TOP, 100, 20, "moving", dx=0, dy=dy,
                  period=g(vi, [2.8, 3.2, 3.6], salt=2))]
    hx = min(ledge_x + ledge_w + 150 + (vi % 2) * 40, 1020)
    hazards = [spikes_up(hx, g(vi, [60, 80], salt=3))]
    return plats, hazards


# (template name, builder, variation count). The first 10 builders'
# v0 entries are the teaching sequence, emitted first, in this order.
TEMPLATES = [
    ("walk-to-door", t_walk, 1),
    ("spike-hops", t_spike_hops, 11),
    ("dashed-bridge", t_dashed_bridge, 11),
    ("saw-jump", t_saw_jump, 11),
    ("popup-spikes", t_popup_spikes, 11),
    ("falling-floor", t_falling_floor, 11),
    ("moving-bridge", t_moving_bridge, 11),
    ("pillar-drop", t_pillar_drop, 11),
    ("swing-saw", t_swing_saw, 11),
    ("patrol-saw", t_patrol_saw, 11),
    ("spiked-column", t_spiked_column, 11),
    ("tilting-block", t_tilting_block, 11),
    ("triggered-spikes", t_triggered_spikes, 11),
    ("pillar-periodic", t_pillar_periodic, 11),
    ("gap-saw", t_gap_saw, 11),
    ("ceiling-spikes", t_ceiling_spikes, 11),
    ("wall-spikes", t_wall_spikes, 11),
    ("step-climb", t_step_climb, 11),
    ("double-gap", t_double_gap, 11),
    ("pit-bridge", t_pit_bridge, 11),
    ("gauntlet", t_gauntlet, 11),
    ("timed-mix", t_timed_mix, 11),
    ("pillar-alley", t_pillar_alley, 11),
    ("grand-mix", t_grand_mix, 11),
    ("mover-lift", t_mover_lift, 11),
]

TEACHING_COUNT = 10  # first 10 templates' v0, in order, are L001..L010


def ordered_candidates():
    """Teaching bases first (L001..L010), then every other variation
    in template order. Order is stable: IDs/palettes follow it."""
    ordered = [(ti, 0) for ti in range(TEACHING_COUNT)]
    for ti, (_name, _fn, n) in enumerate(TEMPLATES):
        for vi in range(n):
            if ti < TEACHING_COUNT and vi == 0:
                continue
            ordered.append((ti, vi))
    return ordered


def load_keep_ids(path):
    """Read a --keep-ids file: one level ID per line, blank lines
    skipped. Returns the IDs in file order, duplicates removed."""
    ids = []
    seen = set()
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        lid = line.strip()
        if not lid or lid in seen:
            continue
        seen.add(lid)
        ids.append(lid)
    return ids


# ---------------------------------------------------------------------------
# Main: generate -> verify with the real checker -> dedupe -> write
# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="Trap Tower level generator")
    ap.add_argument("--out", default=None,
                    help="levels.json (default: repo godot/data/levels.json)")
    ap.add_argument("--tuning", default=None,
                    help="tuning.json (default: repo godot/data/tuning.json)")
    ap.add_argument("--seed", type=int, default=SEED_DEFAULT)
    ap.add_argument("--min-levels", type=int, default=240,
                    help="fail if fewer levels pass verification")
    ap.add_argument("--keep-ids", default=None, metavar="FILE",
                    help="keep only the level IDs listed in FILE (one per "
                    "line); generation is unchanged, filtering happens "
                    "after IDs are assigned so kept levels keep their "
                    "original IDs and content byte-for-byte")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    tuning_path = Path(args.tuning) if args.tuning \
        else REPO / "godot" / "data" / "tuning.json"
    out_path = Path(args.out) if args.out \
        else REPO / "godot" / "data" / "levels.json"
    tuning_data = load_tuning(tuning_path)
    ctx = Ctx(tuning_data)
    tun = ctx.tuning
    rng = random.Random(args.seed)

    accepted = []          # level dicts (no id/palette yet)
    accepted_sigs = []     # (layout, traps, solution) per accepted level
    accepted_names = []    # "template/vXX" per accepted level
    n_candidates = 0
    n_duplicates = 0
    n_invalid = 0
    n_retried = 0
    dup_examples = []
    invalid_examples = []
    per_template = {}
    upper_tally = {}

    for (ti, vi) in ordered_candidates():
        name, fn, _n = TEMPLATES[ti]
        n_candidates += 1
        # A candidate that collides on distinctness is retried with
        # different finish-pass geometry (step-block slot, seam
        # positions/count, upper-band strip) -- all safety-preserving --
        # before it counts as a duplicate. The template design itself
        # never changes across retries.
        done = False
        fail_kind = None
        fail_detail = ""
        for extra in range(6):
            plats, hazards = fn(ctx, rng, vi)
            if name != "step-climb":
                add_step_block(ctx, rng, vi, plats, hazards,
                               salt=ti + extra * 13)
            add_floor_splits(ctx, ti, vi, plats, hazards, extra=extra)
            normalize_ground(ctx, plats)
            # Density (defect #4): teaching bases keep their clean
            # look; every other level must carry (or already have) an
            # upper-band element before it can be accepted.
            if ti < TEACHING_COUNT and vi == 0:
                upper = "teaching"
            else:
                upper = add_upper_band(ctx, ti, vi, plats, hazards,
                                       extra=extra)
            if upper is None:
                fail_kind, fail_detail = "invalid", \
                    "no upper-band slot"
                continue
            index = len(accepted)
            if index >= 3 and not ensure_hazard(ctx, vi, plats, hazards):
                fail_kind, fail_detail = "invalid", \
                    "no safe slot for a required hazard"
                continue
            level = {"id": "PENDING", "palette": 0,
                     "spawn": {"x": SPAWN[0], "y": SPAWN[1]},
                     "door": {"x": DOOR[0], "y": DOOR[1]},
                     "platforms": plats, "hazards": hazards,
                     "template": name,
                     "variation": "v%02d" % vi
                     + ("r%d" % extra if extra else "")}
            chk = check_levels.LevelCheck(level, index, tun).run()
            if chk.errors:
                fail_kind, fail_detail = "invalid", \
                    "; ".join(chk.errors[:2])
                continue
            try:
                layout, traps, solution = chk.signature_parts()
            except Exception as exc:  # signatures never mask real errors
                fail_kind, fail_detail = "invalid", \
                    "signature failed: %s" % exc
                continue
            # Distinctness, EXACTLY as LEVEL_SCHEMA.md / check_levels.py:
            # distinct iff >= 2 of {layout, traps, solution} differ from
            # EVERY already-accepted level (palette excluded from sigs).
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
            accepted_names.append("%s/v%02d" % (name, vi))
            per_template[name] = per_template.get(name, 0) + 1
            upper_tally[upper] = upper_tally.get(upper, 0) + 1
            if extra:
                n_retried += 1
            done = True
            break
        if done:
            continue
        if fail_kind == "duplicate":
            n_duplicates += 1
            if len(dup_examples) < 12:
                dup_examples.append("%s/v%02d duplicates %s (all retries)"
                                    % (name, vi, fail_detail))
        else:
            n_invalid += 1
            if len(invalid_examples) < 12:
                invalid_examples.append("%s/v%02d: %s" % (name, vi,
                                                          fail_detail))

    for i, level in enumerate(accepted):
        level["id"] = "L%03d" % (i + 1)
        level["palette"] = i % ctx.n_palettes
    n_generated = len(accepted)
    dropped_ids = []
    if args.keep_ids:
        # Filter AFTER ID/palette assignment: kept levels keep their
        # original IDs and content untouched; order is generation order.
        # Validation happens before anything is written.
        try:
            keep_list = load_keep_ids(args.keep_ids)
        except OSError as exc:
            print("ERROR: cannot read --keep-ids file %s: %s"
                  % (args.keep_ids, exc), file=sys.stderr)
            return 2
        keep = set(keep_list)
        generated_ids = {level["id"] for level in accepted}
        unknown = [lid for lid in keep_list if lid not in generated_ids]
        if unknown:
            print("ERROR: --keep-ids lists %d unknown level ID(s): %s"
                  % (len(unknown), ", ".join(unknown)), file=sys.stderr)
            return 2
        dropped_ids = [level["id"] for level in accepted
                       if level["id"] not in keep]
        accepted = [level for level in accepted if level["id"] in keep]
    out_path.parent.mkdir(parents=True, exist_ok=True)
    data = {"schema_version": SCHEMA_VERSION,
            "tuning_version": ctx.tuning_version, "levels": accepted}
    out_path.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n",
                        encoding="utf-8")

    if not args.quiet:
        print("generate_levels.py: seed=%d" % args.seed)
        print("  candidates generated: %d" % n_candidates)
        print("  duplicates rejected:  %d" % n_duplicates)
        print("  schema-invalid rejected: %d" % n_invalid)
        print("  accepted via finish retry: %d" % n_retried)
        print("  accepted: %d levels -> %s" % (len(accepted), out_path))
        if args.keep_ids:
            print("  keep-ids filter: kept %d of %d generated "
                  "(dropped %d: %s)"
                  % (len(accepted), n_generated, len(dropped_ids),
                     ", ".join(dropped_ids) if dropped_ids else "none"))
        print("  upper-band: %s"
              % ", ".join("%s=%d" % kv for kv in sorted(upper_tally.items())))
        for name, _fn, _n in TEMPLATES:
            print("    %-18s %d" % (name, per_template.get(name, 0)))
        for line in dup_examples:
            print("  DUP: %s" % line)
        for line in invalid_examples:
            print("  INVALID: %s" % line)
    if len(accepted) < args.min_levels:
        print("ERROR: only %d levels passed, need >= %d"
              % (len(accepted), args.min_levels), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
