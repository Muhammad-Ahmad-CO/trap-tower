# Trap Tower — Level Data Contract v2 (FROZEN by Lead Engineer)

This document is the single source of truth for level data. The generator
(`tools/generate_levels.py`), the runtime builder (`godot/scripts/`), and the
harness (`tools/check_levels.py` + autopilot) MUST implement exactly this
schema. No lane may change this file; changes go through the Lead only, with a
`schema_version` bump.

v2 changes vs v1 (Run 3, 18 Nov 2026): flat level structure (no doors of 5,
no 5-square HUD, no auto-chain); HUD shows the level number; new validation
rules 7–9 (grounding, HUD keep-out, density floor); runtime enforcement
scoping (warn-and-load for rules 7–8, see below). The level-object FIELDS
are unchanged — v2 is a contract/rules change, not a format change — but the
bump is required by this document's own rule, and v1 files MUST fail fast.

Loop 4 addition (within v2, NO bump): the optional `decorations` array,
rule 10, and the rule 9 core-middle redefinition. Backward-compatible
additive changes (new OPTIONAL fields, new harness-only rules) do NOT
require a version bump; breaking changes (field renames/removals,
required-field additions, meaning changes) do. Files with and without
`decorations` are both valid v2; the runtime and the harness MUST accept
both (a missing array means []).

## Files

- `godot/data/tuning.json` — physics + palette + HUD constants (frozen).
- `godot/data/levels.json` — the shipped levels. Sole producer: the assembly
  pipeline (generator → checker → autopilot → assembler). The harness and
  the runtime MUST read this exact file. Never hand-edit it.

## Coordinate system

- Viewport 1280x720, landscape, y grows downward.
- Level geometry lives in y 0..580. The bottom 140px (y 580..720) is the
  reserved control bar; NO platform, hazard, spawn, or door may use y >= 580.
- The top 90px (y 0..90) is the HUD band; see rule 8. NO drawn geometry may
  use y < 90.
- `x` 0..1280. All rects use top-left origin: `{x, y, w, h}`.
- `spawn` = player FEET CENTRE at level start. `door` = `{x: centre, y: base}`
  where base is the floor-top the door stands on. Door size is fixed
  (54x84, see tuning.json). The door rect must sit on solid ground.

## Top-level file

```json
{"schema_version": 2, "tuning_version": 1, "levels": [ ... ]}
```

`schema_version` and `tuning_version` must match the frozen values or the
runtime/harness must fail fast with an error (never silently load).

## Level object

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Stable ID, e.g. `"L001"`. IDs are assembly-versioned: within one shipped file they are never reused or reordered, but a regeneration that reorders geometry assigns new IDs and REQUIRES a save-version bump (see `progress.gd`), because unlock/save keys use IDs. |
| `palette` | int | yes | Index into `tuning.json` palettes. One palette per archetype group (palette = archetype index, 0-based). Palette alone NEVER makes a level distinct. |
| `spawn` | `{x, y}` | yes | Player feet centre. Must be on/above solid ground with a safe zone: no hazard rect within 40px. Feet y >= 134 (hero head clears the HUD band). |
| `door` | `{x, y}` | yes | Door centre/base. Must stand on solid ground with a safe zone: no hazard rect within 40px. Base y >= 174 (door top clears the HUD band). |
| `platforms` | array | yes | Solid / special platforms (below). At least the spawn and door ground. |
| `hazards` | array | yes | May be empty only for the first 3 levels in file order (validator rule). The generator emits NO empty-hazard levels: every level is lethal from level 1. |
| `decorations` | array | no | Background silhouettes (see Decorations). Draw-only: no collision, no gameplay effect. Missing = []. |
| `template` | string | yes | Generator archetype name (provenance only). |
| `variation` | string | yes | Archetype/slot/variant code, e.g. `"D03S2V1"` = archetype 3, slot 2, variant 1 (provenance + assembly key). |

## Platforms

Common: `{x, y, w, h, kind}`. `kind` is one of:

- `solid` — static solid rect.
- `dashed` — blinking platform. Extra: `period` (s), `phase` (s offset),
  `on_time` (s solid per cycle). Solid during `[phase, phase+on_time)` mod
  `period`, else non-solid and drawn dashed/faint. `on_time >= 0.9`,
  `period - on_time >= 0.5`.
- `falling` — falls after being stood on. Extra: `stand_time` (s, >= 0.45)
  then falls with gravity; it does NOT respawn until level restart.
- `tilting` — tilts then drops after being stood on. Extra: `stand_time`
  (s, >= 0.45). Behaviour = falling + rotation visual. Same respawn rule.
- `moving` — moves between two points. Extra: `dx`, `dy` (offset of second
  point), `period` (s, full round trip, >= 1.6). Moves smoothly (sine ease).
  The platform carries the player (standard Godot moving-platform behaviour).

All platforms: `w >= 48` (harness landing minimum), `h >= 16`, inside
0..1280 / 0..580. Platforms may overlap/touch to form floors and walls.
Every platform MUST satisfy the grounding rule (rule 7).

## Decorations

Optional rects: `{x, y, w, h}`. Drawn by the runtime builder in the
decoration tint (`trap` lerped 55% toward `bg`), BELOW platforms, hazards,
hero, and door (background layer). NO collision body, NO gameplay effect,
NO grounding requirement — but every rect MUST look attached: it must
touch (edge-adjacent within 4px) a solid platform rect, or another
decoration rect that does (chain to a solid). Decorations MUST respect
the HUD keep-out (rule 8: no drawn pixel y < 90), MUST NOT overlap any
hazard rect (area overlap > 0 fails), and MUST NOT overlap the spawn hero
rect or the door rect. The autopilot and the reachability/connectivity
checks MUST ignore decorations entirely (open space). Dedupe signatures
MUST exclude decorations. The assembler MUST preserve decorations
verbatim and include them in geometry-identity verification.
`w >= 48`, `h >= 16`, inside 0..1280 / 90..580.

## Hazards

Common: `{type, x, y, w, h}` + type params. Contact with a hazard rect/circle
= death, instant level restart. Optional trigger fields on ANY hazard:
`trigger_x` (activates only after the player's x first passes this value),
`delay` (s after trigger before the hazard becomes lethal, >= 0.25).

Types:

- `spikes` — serrated strip. Extra: `dir`: `"up"` (default), `"down"`,
  `"left"`, `"right"`. Optional pop-up timing: `period`, `phase`,
  `on_time` (lethal only while up; same minima as dashed). Static if no
  `period`. Drawn as triangles in trap colour on the given edge. Must be
  seated on a solid surface (rule 7).
- `saw` — semicircular saw blade. Extra: `r` (radius, 26..60),
  `path`: `{"x2", "y2"}` end point + `period` (round trip, >= 1.6) for a
  moving saw, OR `swing`: `{"pivot_x", "pivot_y", "arc_deg", "period"}` for
  a pendulum saw. `x,y` = centre at rest / path start. Lethal circle = r.
  The disc must touch solid geometry over its full sweep (rule 7); a swing
  pivot must lie inside a solid beam. The runtime draws a chain from the
  pivot to the disc centre for swing saws.
- `spiked_column` — static hazard rect (a wall/column with spikes on both
  sides). No extra params. Must never fully block the only path: at least
  one route must pass it (over, under, or around) per the harness graph.
  Must be grounded: bottom on a solid top/floor, or top attached under a
  grounded beam (rule 7).
- `hanging_pillar` — block hanging from above that drops. Extra:
  `drop_trigger_x` (drops when player x passes it) OR `period`/`phase`
  (periodic drop + rise). `drop_speed` (px/s, default 700). While hanging
  it is solid; while falling/rising, contact = death. After a periodic
  drop it rises back over 1.0s. Triggered pillars stay down until restart.
  Home rect top >= 90 (rule 8); hung by definition (exempt from rule 7).
  The runtime draws its cable from y=90, not y=0.
- `dotted_line` — VISUAL WARNING ONLY, never lethal by itself. Extra:
  `linked` = index of the hazard in this level's `hazards` array that it
  warns about. Drawn as a dotted line in trap colour. Every triggered or
  pop-up hazard SHOULD have a dotted line near its trigger point. Subject
  to rule 8 only; exempt from rule 7 (warning marker, not an obstacle).

## Validation rules

Rules 1–6 are validity rules, enforced identically by the runtime and the
harness (hard fail). Rules 7–8 are validity rules enforced HARD by the
harness (checker) and WARN-AND-LOAD by the runtime: the runtime logs each
violation (`push_warning`) but still loads the level, so a rule-drift
difference can never brick the game on-device. The shipped file MUST
produce ZERO runtime warnings (proven by the load probe on the final
file). Rule 9 is a generation-quality rule enforced by the harness only
(checker fail + report); the runtime does not check it.

1. Schema/tuning versions match; all required fields present; unknown
   `kind`/`type` = hard error (never skip silently).
2. All geometry inside 0..1280 / 0..580; platform `w >= 48`, `h >= 16`.
3. Spawn and door safe zones (40px, no hazard rect/circle overlap).
4. Spawn stands on solid ground (a platform top within 4px below spawn y,
   spanning spawn x); door stands on solid ground likewise.
5. Harness reachability: platform graph from spawn platform to door
   platform using the frozen envelope (rise <= 100, gap <= 170, landing
   >= 48, run-up >= 60). Timed hazards on the chosen path must leave a
   safe window >= 0.7s. PLUS connectivity: flood-fill of empty space
   (8px grid, 4-connected) from the spawn feet cell to the door base
   cell, with `solid` platforms as walls and all other platforms and
   hazards as open, MUST connect. (The graph alone cannot see solid
   walls sealing a route; connectivity catches sealed pockets.) This
   is a PRE-FILTER only; the autopilot decides. Harness-only: the
   runtime does not implement the graph or connectivity checks.
6. Distinctness: canonical signature = platform graph + hazard multiset
   (type + normalised position bucket) + trap params + solution jump
   sequence, EXCLUDING palette. Two levels are distinct only if signatures
   differ AND they differ in >= 2 of {layout geometry, trap set/params,
   solution path}. Palette-only, mirror-only, or trivial-shift variants
   are duplicates and must be rejected.
7. GROUNDING — no floating geometry, ever. "Grounded" is the least
   fixpoint: a platform is grounded iff it is a floor (bottom at
   y=580), or rests on grounded support(s), or is pillar-connected to
   grounded support, or has both ends touching grounded supports.
   There is NO shape test: a support counts by groundedness, not by
   looking tall ("vertical" in earlier drafts meant grounded-via-
   fixpoint and is not a separate h>=w requirement).
   - `solid`: supported iff resting (bottom on supporting platform
     top(s), COMBINED x-overlap >= 48 across supports, gap <= 4) OR
     pillar-connected (a solid pillar w >= 48 whose top touches the
     platform bottom within 4px, whose bottom touches a grounded
     support top within 4px, and whose x-span lies within the
     platform x-span) OR floor (bottom at y=580) OR both ends
     touching grounded solids (each end overlapping a grounded solid
     with y-overlap >= 8).
   - `dashed` / `falling` / `tilting` / `moving`: NO under-pillars.
     Supported iff shaft-flanked (grounded solid columns on BOTH sides
     within 8px of the ends, spanning the platform's full y-range / full
     sweep range) OR resting (ends on solid tops, gap <= 4).
   - `spikes`: seated — `up`: bottom within 4px of a solid top;
     `down`: top within 4px of a grounded beam bottom; `left`/`right`:
     side face within 4px of a solid side. Pit-bottom spikes with no
     pit-floor solid are forbidden.
   - `saw`: the disc must touch a solid rect (centre-to-rect distance
     <= r + 4) at rest AND at every swept sample (path endpoints and
     13-sample swing arc). Swing pivots must lie inside a solid beam.
   - `spiked_column`: bottom on a solid top/floor, or top attached under
     a grounded beam bottom.
   - Rect hazards (`spikes`, `spiked_column`) must not area-overlap
     solid rects beyond the 4px seating tolerance: an intersection
     rect with width > 4 AND height > 4 fails. (A support post hidden
     behind a hazard reads as floating geometry.) Saws (disc geometry),
     `hanging_pillar` (beam mounts), and `dotted_line` (indicators)
     are exempt. Harness only.
   - `hanging_pillar` and `dotted_line`: exempt (see Hazard types).
8. HUD KEEP-OUT — no DRAWN extent in y < 90: no platform rect, hazard
   rect, saw disc (centre ± r over the full sweep), pillar home rect, or
   dotted-line rect may have any drawn pixel with y < 90. Spawn feet
   y >= 134. Door base y >= 174.
9. DENSITY FLOOR (harness only): every level must have >= 2 solid rects
   intersecting the middle band y 150..450, with combined intersected
   width >= 160px. (Pillars, beams, and columns count.) PLUS a
   CORE-MIDDLE floor: excluding rects that touch the screen edges
   (x == 0 or x + w == 1280, i.e. the edge walls), every level must
   have >= 2 rects (solid platforms AND/OR decorations) intersecting
   y 260..420, with combined width >= 160px. (The y 150..450 floor is
   satisfied by ceiling beams alone; the core-middle floor bans the
   visibly empty middle.)
   Eyes-on screenshot review is the final density judge; these floors
   only ban empty middles mechanically.
10. DECORATIONS (harness only, except the runtime draw + key acceptance):
    the `decorations` array, if present, MUST satisfy the Decorations
    section (attachment chain, keep-out, no hazard/spawn/door overlap,
    bounds). The runtime MUST accept files with and without the array,
    MUST draw decorations (tint + background layer), and MUST NOT create
    collision for them. The runtime neither validates nor warns on
    decorations. The harness counts solid + decoration rects together
    for the rule 9 core-middle floor.

## HUD / controls (frozen meanings)

- Top-centre: the level indicator, text `LEVEL N` (1-based, N = level
  index + 1), in trap colour on an opaque background-colour backing, in
  the same flat minimal style. No squares, no other counters.
- Top-left: pause button + restart button (icon buttons, no text).
  Top-right: Skip button ("SKIP >>"), visible ONLY after >= 3 deaths
  in the current level. Skip unlocks the next level without marking
  the current one complete, then returns to the map.
- Pause: centred panel with 3 icon buttons (exit to map, restart,
  resume); the game tree is frozen behind it; the HUD stays visible.
- Death: NO game-over screen. The character vanishes, traps stay
  visible in their triggered state, a "TAP TO RETRY" prompt shows, and
  the level restarts (respawn at level start + full trap reset) on the
  next input or after a short auto-retry delay. The `deaths` counter
  increments synchronously in the death frame.
- Win: completing a level saves progress (ID marked complete, next
  level unlocked) and returns to the map. There is NO auto-chain into
  the next level.
- Level select is a WORLD MAP: 215 individually selectable level nodes
  (one per level, in shipped order, grouped visually by archetype
  palette), joined by a dotted path, the current level glowing with a
  marker, completed levels marked, locked levels dimmed + unclickable.
  Tapping a node plays exactly that level. There is NO door picker.
  Unlock derives from the highest unlocked level index, never from the
  completed-ID set. "Made by Ahmed" is visible in the map header.
- Control bar (y 580..720) in EVERY level: left arrow, right arrow, and a
  LARGER jump button (bold up arrow, ~1.6x move-button width). Never a
  house/roof shape. Bar fill = trap colour; button fill = bg colour; arrow
  = trap colour. Multi-touch: move + jump simultaneously.
- No other in-level HUD: no deaths, timer, or score on the play screen.
  Settings (sound toggle + music volume + close) live on the map screen
  only.

## Structure (Run 3, flat)

- Levels ship FLAT: 215 individually selectable levels in archetype-major
  order (43 archetype groups x 5 levels; each group shares one gimmick
  and one palette). There are no doors, no stages-within-doors, and no
  multiple-of-5 requirement on the shipped file beyond the 200-level
  floor (target 215).
- Candidate levels carry IDs of the form `D{archetype:02d}S{slot}V{variant}`
  and are assembled into the shipped file by `tools/assemble_levels.py`
  (first passing variant per archetype/slot; incomplete archetypes
  contribute only their passing slots — no whole-group drop). If fewer
  than 215 pass, assembly tops up from spare archetype D44's passing
  slots (in slot order) up to 215; below 200 the assembly FAILS loudly.
  The shipped file is re-verified end-to-end after assembly; the verified
  count is read from the shipped file's own verification report, never
  from the candidates report.
- Save compatibility: level IDs are assembly-versioned; this regeneration
  REQUIRES the save-version bump in `progress.gd` (SAVE_VERSION 3):
  v1.0.2 saves are ignored (fresh progress), never migrated.

## Example (minimal teaching level)

```json
{
  "id": "L001", "palette": 4, "template": "walk-to-door", "variation": "base",
  "spawn": {"x": 70, "y": 500}, "door": {"x": 1210, "y": 500},
  "platforms": [{"x": 0, "y": 500, "w": 1280, "h": 80, "kind": "solid"}],
  "hazards": []
}
```
