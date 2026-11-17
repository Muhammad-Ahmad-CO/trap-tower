# Trap Tower — Level Data Contract v1 (FROZEN by Lead Engineer)

This document is the single source of truth for level data. The generator
(`tools/generate_levels.py`), the runtime builder (`godot/scripts/`), and the
harness (`tools/check_levels.py` + autopilot) MUST implement exactly this
schema. No lane may change this file; changes go through the Lead only, with a
`schema_version` bump.

## Files

- `godot/data/tuning.json` — physics + palette + HUD constants (frozen).
- `godot/data/levels.json` — the shipped levels. Sole producer: the generator.
  The harness and the runtime MUST read this exact file. Never hand-edit it
  except through the generator.

## Coordinate system

- Viewport 1280x720, landscape, y grows downward.
- Level geometry lives in y 0..580. The bottom 140px (y 580..720) is the
  reserved control bar; NO platform, hazard, spawn, or door may use y >= 580.
- `x` 0..1280. All rects use top-left origin: `{x, y, w, h}`.
- `spawn` = player FEET CENTRE at level start. `door` = `{x: centre, y: base}`
  where base is the floor-top the door stands on. Door size is fixed
  (54x84, see tuning.json). The door rect must sit on solid ground.

## Top-level file

```json
{"schema_version": 1, "tuning_version": 1, "levels": [ ... ]}
```

`schema_version` and `tuning_version` must match the frozen values or the
runtime/harness must fail fast with an error (never silently load).

## Level object

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Stable ID, e.g. `"L001"`. Never reused, never reordered. Unlock/save keys use IDs, not array indices. |
| `palette` | int | yes | Index into `tuning.json` palettes. Rotates; palette alone NEVER makes a level distinct. |
| `spawn` | `{x, y}` | yes | Player feet centre. Must be on/above solid ground with a safe zone: no hazard rect within 40px. |
| `door` | `{x, y}` | yes | Door centre/base. Must stand on solid ground with a safe zone: no hazard rect within 40px. |
| `platforms` | array | yes | Solid / special platforms (below). At least the spawn and door ground. |
| `hazards` | array | yes | May be empty only for the first 3 teaching levels. Otherwise >= 1. |
| `template` | string | yes | Generator template name (provenance only). |
| `variation` | string | yes | Variation label (provenance only). |

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

## Hazards

Common: `{type, x, y, w, h}` + type params. Contact with a hazard rect/circle
= death, instant level restart. Optional trigger fields on ANY hazard:
`trigger_x` (activates only after the player's x first passes this value),
`delay` (s after trigger before the hazard becomes lethal, >= 0.25).

Types:

- `spikes` — serrated strip. Extra: `dir`: `"up"` (default), `"down"`,
  `"left"`, `"right"`. Optional pop-up timing: `period`, `phase`,
  `on_time` (lethal only while up; same minima as dashed). Static if no
  `period`. Drawn as triangles in trap colour on the given edge.
- `saw` — semicircular saw blade. Extra: `r` (radius, 26..60),
  `path`: `{"x2", "y2"}` end point + `period` (round trip, >= 1.6) for a
  moving saw, OR `swing`: `{"pivot_x", "pivot_y", "arc_deg", "period"}` for
  a pendulum saw. `x,y` = centre at rest / path start. Lethal circle = r.
- `spiked_column` — static hazard rect (a wall/column with spikes on both
  sides). No extra params. Must never fully block the only path: at least
  one route must pass it (over, under, or around) per the harness graph.
- `hanging_pillar` — block hanging from above that drops. Extra:
  `drop_trigger_x` (drops when player x passes it) OR `period`/`phase`
  (periodic drop + rise). `drop_speed` (px/s, default 700). While hanging
  it is solid; while falling/rising, contact = death. After a periodic
  drop it rises back over 1.0s. Triggered pillars stay down until restart.
- `dotted_line` — VISUAL WARNING ONLY, never lethal by itself. Extra:
  `linked` = index of the hazard in this level's `hazards` array that it
  warns about. Drawn as a dotted line in trap colour. Every triggered or
  pop-up hazard SHOULD have a dotted line near its trigger point.

## Validation rules (runtime + harness must enforce identically)

1. Schema/tuning versions match; all required fields present; unknown
   `kind`/`type` = hard error (never skip silently).
2. All geometry inside 0..1280 / 0..580; platform `w >= 48`, `h >= 16`.
3. Spawn and door safe zones (40px, no hazard rect/circle overlap).
4. Spawn stands on solid ground (a platform top within 4px below spawn y,
   spanning spawn x); door stands on solid ground likewise.
5. Harness reachability: platform graph from spawn platform to door
   platform using the frozen envelope (rise <= 100, gap <= 170, landing
   >= 48, run-up >= 60). Timed hazards on the chosen path must leave a
   safe window >= 0.7s. This is a PRE-FILTER only; the autopilot decides.
6. Distinctness: canonical signature = platform graph + hazard multiset
   (type + normalised position bucket) + trap params + solution jump
   sequence, EXCLUDING palette. Two levels are distinct only if signatures
   differ AND they differ in >= 2 of {layout geometry, trap set/params,
   solution path}. Palette-only, mirror-only, or trivial-shift variants
   are duplicates and must be rejected.

## HUD / controls (frozen meanings)

- 5 squares, top centre: filled = levels completed in the current block of
  5 (block = levels 5k+1..5k+5, in shipped order). The current level counts
  only after completion.
- Control bar (y 580..720) in EVERY level: left arrow, right arrow, and a
  LARGER jump button (bold up arrow, ~1.6x move-button width). Never a
  house/roof shape. Bar fill = trap colour; button fill = bg colour; arrow
  = trap colour. Multi-touch: move + jump simultaneously.
- No other in-level HUD: no level number, deaths, timer, or score on the
  play screen. Level numbers live only in level select.

## Example (minimal teaching level)

```json
{
  "id": "L001", "palette": 4, "template": "walk-to-door", "variation": "base",
  "spawn": {"x": 70, "y": 500}, "door": {"x": 1210, "y": 500},
  "platforms": [{"x": 0, "y": 500, "w": 1280, "h": 80, "kind": "solid"}],
  "hazards": []
}
```
