# Trap Tower — Level Data Contract v3 (FROZEN by Lead Engineer)

This document is the single source of truth for level data. The generator
(`tools/generate_levels.py`), the runtime builder (`godot/scripts/`), and the
harness (`tools/check_levels.py` + autopilot) MUST implement exactly this
schema. No lane may change this file; changes go through the Lead only, with a
`schema_version` bump.

v3 changes vs v2 (Run 4, 19 Nov 2026): full-height play area (floor y=720,
control bar abolished — controls overlay the play area); physics retuned to
measured official-game targets (rise ~57px, air ~97px, speed ~243px/s);
hero collision ~15x39; door fixed size 36x54 via a schema constant (the
`tuning.json` `door` entry is DEPRECATED and must not be read); the
`tuning.json` `control_bar` entry is DEPRECATED and must not be read
(floor source is `viewport.height` = 720); `dotted_line` hazard type
REMOVED; spikes are integrated teeth (lethal rect = drawn teeth rect);
`falling`/`tilting` draw identically to solid at rest (hidden pits);
density bands rescaled + floor-slab/edge exclusion; new rule 11
(hazard-family purity); HUD/controls/map/death/transition/font sections
rewritten (minimal HUD, chevron controls, organic island map, particle
death, wipe transition, code-drawn pixel font). The level-object FIELDS
are unchanged except the removal of `dotted_line` — but bounds, sizes,
and rule meanings change, so the bump is required and v2 files MUST fail
fast. SAVE_VERSION stays 3 (see Structure).

v2 changes vs v1 (Run 3): flat level structure; rules 7–9; warn-and-load
scoping. Loop 4 addition (within v2, no bump): optional `decorations`
array, rule 10, core-middle redefinition. Backward-compatible additive
changes (new OPTIONAL fields, new harness-only rules) do NOT require a
version bump; breaking changes (field renames/removals, required-field
additions, meaning changes) do.

## Files

- `godot/data/tuning.json` — physics + palette + HUD constants. Physics
  fields and player size were retuned in v3 (see Physics); ALL other
  fields are frozen. The `control_bar` and `door` entries are DEPRECATED:
  they remain present (readers hard-index them in old code) but MUST NOT
  be read by any v3 implementation; grep tripwires prove zero reads.
- `godot/data/levels.json` — the shipped levels. Sole producer: the assembly
  pipeline (generator → checker → autopilot → assembler). The harness and
  the runtime MUST read this exact file. Never hand-edit it.

## Physics (retuned v3 — measured official-game targets)

- Run speed ~243 px/s, CONSTANT. Movement is instant start/stop: full
  speed the frame input applies, dead stop the frame it releases. NO
  acceleration ramp, NO slide.
- Jump is FIXED height (no variable jump): rise ~57px, airtime ~0.4s,
  air distance ~97px. Probe baselines (re-baselined in v3; the v2
  baselines 159.7/276.0/665.1 are SUPERSEDED): rise ~57px (+/-10%), air
  distance ~97px (+/-10%), airtime ~0.4s, run speed ~243 px/s (+/-10%).
  Gravity/terminal velocity are derived by the runtime lane from these
  targets (implied ~2835 px/s^2 / ~600 px/s); measured probes decide.
- Hero collision rect ~15w x 39h (tuning `player` size). The drawn
  silhouette matches the collision rect (feet-aligned). No invisible
  hitbox: draw == collision by construction.
- Fall death: feet y > 760 (FLOOR_Y + 40) = death. Single constant,
  used identically by the runtime and the autopilot (death check +
  planner). There is no other fall threshold.

## Coordinate system

- Viewport 1280x720, landscape, y grows downward.
- Level geometry lives in y 90..720. The FULL screen is the play area:
  there is no reserved control bar. Touch controls overlay the play
  area as transparent outlines (see HUD / controls).
- FLOOR_Y = 720 = `viewport.height`. "Floor" in the grounding rule
  means bottom at y=720. There is no `bar_y` in v3.
- The top 90px (y 0..90) is the HUD band; see rule 8. NO drawn geometry
  may use y < 90.
- `x` 0..1280. All rects use top-left origin: `{x, y, w, h}`.
- `spawn` = player FEET CENTRE at level start. `door` = `{x: centre, y: base}`
  where base is the floor-top the door stands on. Door size is fixed
  (36x54, schema constant — see Door). The door rect must sit on solid
  ground. Trigger rect = drawn rect.

## Top-level file

```json
{"schema_version": 3, "tuning_version": 1, "levels": [ ... ]}
```

`schema_version` and `tuning_version` must match the frozen values or the
runtime/harness must fail fast with an error (never silently load). A v2
file MUST be rejected with the exact error `schema_version must be 3`.

## Level object

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Stable ID, e.g. `"L001"`. IDs are assembly-versioned: within one shipped file they are never reused or reordered. Assembly order is frozen archetype-major (see Structure). |
| `palette` | int | yes | Index into `tuning.json` palettes. One palette per archetype group (palette = archetype index, 0-based). Palette alone NEVER makes a level distinct. |
| `spawn` | `{x, y}` | yes | Player feet centre. Must be on/above solid ground with a safe zone: no hazard rect within 40px. Feet y >= 134 (kept conservatively: HUD 90 + hero 39 = 129 minimum; 134 keeps a 5px margin). |
| `door` | `{x, y}` | yes | Door centre/base. Must stand on solid ground with a safe zone: no hazard rect within 40px. Base y >= 174 (kept conservatively: HUD 90 + door 54 = 144 minimum; 174 keeps the door clear of the HUD chip row). |
| `platforms` | array | yes | Solid / special platforms (below). At least the spawn and door ground. |
| `hazards` | array | yes | May be empty only for the first 3 levels in file order (validator rule). The generator emits NO empty-hazard levels: every level is lethal from level 1. |
| `decorations` | array | no | Background silhouettes (see Decorations). Draw-only. Missing = []. The SHIPPED file SHOULD contain zero decorations (see rule 10); any exception needs Lead approval. |
| `template` | string | yes | Generator archetype name (provenance only). |
| `variation` | string | yes | Archetype/slot/variant code, e.g. `"D03S2V1"` = archetype 3, slot 2, variant 1 (provenance + assembly key). |

## Platforms

Common: `{x, y, w, h, kind}`. `kind` is one of:

- `solid` — static solid rect. Solid masses are built by composing
  `solid` rects: stairs, shafts, valleys, walls, carved corridors,
  U-shapes. Geometry itself is the obstacle: levels must read as bold
  silhouettes across the whole frame, never 'flat floor + objects'.
- `dashed` — blinking platform. Extra: `period` (s), `phase` (s offset),
  `on_time` (s solid per cycle). Solid during `[phase, phase+on_time)` mod
  `period`, else non-solid and drawn dashed/faint. `on_time >= 0.9`,
  `period - on_time >= 0.5`. Blink states stay visible: this is mechanic
  visibility, NOT a trigger warning.
- `falling` — HIDDEN PIT. Falls after being stood on. Extra: `stand_time`
  (s, >= 0.45) then falls with gravity; it does NOT respawn until level
  restart. At rest it MUST draw IDENTICALLY to surrounding solid: same
  fill, no seam, no outline, no marker, no colour difference. The floor
  lies: no visual cue distinguishes it before it fires.
- `tilting` — tilts then drops after being stood on. Extra: `stand_time`
  (s, >= 0.45). Behaviour = falling + rotation visual. Same respawn rule.
  At rest it MUST draw identically to solid (same rule as `falling`);
  tilt animation only AFTER triggering.
- `moving` — moves between two points. Extra: `dx`, `dy` (offset of second
  point), `period` (s, full round trip, >= 1.6). Moves smoothly (sine ease).
  The platform carries the player (standard Godot moving-platform behaviour).

All platforms: `w >= 48` (harness landing minimum), `h >= 16`, inside
0..1280 / 90..720. Platforms may overlap/touch to form floors and walls.
Every platform MUST satisfy the grounding rule (rule 7).

## Door

Fixed size 36w x 54h. SMALL white rounded-top rectangle with a thin dark
outline. This size is a SCHEMA CONSTANT: the runtime, checker, generator,
and autopilot MUST all use 36x54 from this document. The `tuning.json`
`door` entry (54x84) is DEPRECATED and must not be read. A cross-check
MUST assert identical door rects across all four implementations on the
shipped file.

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
`w >= 48`, `h >= 16`, inside 0..1280 / 90..720.

## Hazards

Common: `{type, x, y, w, h}` + type params. Contact with a hazard rect/circle
= death. Optional trigger fields on ANY hazard:
`trigger_x` (activates only after the player's x first passes this value),
`delay` (s after trigger before the hazard becomes lethal, >= 0.25).
THERE ARE NO TRIGGER INDICATORS: no dotted lines, no popup lines, no
warning glyphs of any kind anywhere in the game. Triggered hazards are
invisible before they fire. The `dotted_line` type from v2 is REMOVED:
it is an unknown type and MUST hard-error in the checker and the runtime.

Types:

- `spikes` — INTEGRATED TEETH. Tiny teeth growing OUT of a solid surface,
  drawn in the SAME colour as the solid, as part of the silhouette.
  Tooth height ~1/4 hero height (~10px). Extra: `dir`: `"up"` (default),
  `"down"`, `"left"`, `"right"`. The data rect IS the teeth cluster rect:
  lethal rect = drawn teeth rect, no mismatch by construction. Optional
  pop-up timing: `period`, `phase`, `on_time` (lethal only while up;
  same minima as dashed). Static if no `period`. Triggered teeth pop
  out from inside the solid FAST (~0.1s), invisible before triggering.
  Must be seated on a solid surface (rule 7). Placements: floor
  clusters, wall teeth, ceiling teeth, full stair-edge linings,
  shaft-wall teeth.
- `saw` — small saw blade, seated INTO the geometry. Extra: `r` (radius,
  18..40), `path`: `{"x2", "y2"}` end point + `period` (round trip,
  >= 1.6) for a moving saw, OR `swing`: `{"pivot_x", "pivot_y",
  "arc_deg", "period"}` for a pendulum saw. `x,y` = centre at rest /
  path start. Lethal circle = r. The disc must touch solid geometry
  over its full sweep (rule 7); a swing pivot must lie inside a solid
  beam. Swing connectors draw as a thin SOLID-COLOUR bar (silhouette-
  consistent); NO gears, brackets, bolts, or machine-like mounts. Saws
  appear ONLY in saw-family + mix/final archetypes (rule 11). The disc
  draws in the solid colour; no extra colours.
- `spiked_column` — static hazard rect (a wall/column with teeth on both
  sides, same colour as the solid). No extra params. Must never fully
  block the only path: at least one route must pass it (over, under, or
  around) per the harness graph. Must be grounded: bottom on a solid
  top/floor, or top attached under a grounded beam (rule 7).
- `hanging_pillar` — block hanging from above that drops. Extra:
  `drop_trigger_x` (drops when player x passes it) OR `period`/`phase`
  (periodic drop + rise). `drop_speed` (px/s, default 700). While hanging
  it is solid; while falling/rising, contact = death. After a periodic
  drop it rises back over 1.0s. Triggered pillars stay down until restart.
  Home rect top >= 90 (rule 8); hung by definition (exempt from rule 7).
  The runtime draws its cable from y=90, not y=0. Drop distance is to
  FLOOR_Y (720); drop timing derives from the drop distance identically
  in the checker, runtime, and autopilot.

## Validation rules

Rules 1–6 are validity rules, enforced identically by the runtime and the
harness (hard fail). Rules 7–8 are validity rules enforced HARD by the
harness (checker) and WARN-AND-LOAD by the runtime: the runtime logs each
violation (`push_warning`) but still loads the level, so a rule-drift
difference can never brick the game on-device. The shipped file MUST
produce ZERO runtime warnings (proven by the load probe on the final
file). Rules 9–11 are generation-quality rules enforced by the harness
only (checker fail + report); the runtime does not check them.

1. Schema/tuning versions match; all required fields present; unknown
   `kind`/`type` = hard error (never skip silently). `dotted_line` is
   unknown in v3.
2. All geometry inside 0..1280 / 90..720; platform `w >= 48`, `h >= 16`.
3. Spawn and door safe zones (40px, no hazard rect/circle overlap).
4. Spawn stands on solid ground (a platform top within 4px below spawn y,
   spanning spawn x); door stands on solid ground likewise.
5. Harness reachability: platform graph from spawn platform to door
   platform using the v3 envelope (step rise <= 45, gap <= 80, landing
   >= 48, run-up >= 24). Timed hazards on the chosen path must leave a
   safe window >= 0.7s. PLUS connectivity: flood-fill of empty space
   (8px grid, 4-connected) from the spawn feet cell to the door base
   cell, with `solid` platforms as walls and all other platforms and
   hazards as open, MUST connect. (The graph alone cannot see solid
   walls sealing a route; connectivity catches sealed pockets.) This
   is a PRE-FILTER only; the autopilot decides. Harness-only: the
   runtime does not implement the graph or connectivity checks. The
   envelope derives from measured probe values x 0.85 (see Physics);
   envelope changes go through the Lead only.
6. Distinctness: canonical signature = platform graph + hazard multiset
   (type + normalised position bucket) + trap params + solution jump
   sequence, EXCLUDING palette. Two levels are distinct only if signatures
   differ AND they differ in >= 2 of {layout geometry, trap set/params,
   solution path}. Palette-only, mirror-only, or trivial-shift variants
   are duplicates and must be rejected. VARIETY RULE: each archetype's
   5 slots MUST span >= 3 distinct shape skeletons (documented skeleton
   table); eyes-on review judges within-group visual diversity every
   loop — 5 copies of one layout are a defect even if signatures differ.
7. GROUNDING — no floating geometry, ever. "Grounded" is the least
   fixpoint: a platform is grounded iff it is a floor (bottom at
   y=720), or rests on grounded support(s), or is pillar-connected to
   grounded support, or has both ends touching grounded supports.
   There is NO shape test: a support counts by groundedness, not by
   looking tall.
   - `solid`: supported iff resting (bottom on supporting platform
     top(s), COMBINED x-overlap >= 48 across supports, gap <= 4) OR
     pillar-connected (a solid pillar w >= 48 whose top touches the
     platform bottom within 4px, whose bottom touches a grounded
     support top within 4px, and whose x-span lies within the
     platform x-span) OR floor (bottom at y=720) OR both ends
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
     behind a hazard reads as floating geometry.) Saws (disc geometry)
     and `hanging_pillar` (beam mounts) are exempt. Harness only.
   - `hanging_pillar`: exempt (see Hazard types).
8. HUD KEEP-OUT — no DRAWN extent in y < 90: no platform rect, hazard
   rect, saw disc (centre ± r over the full sweep), or pillar home rect
   may have any drawn pixel with y < 90. Spawn feet y >= 134. Door base
   y >= 174.
9. DENSITY FLOOR (harness only): every level must have >= 2 solid rects
   intersecting the middle band y 170..550, with combined intersected
   width >= 160px — EXCLUDING floor slabs (rects touching y=720 and
   spanning >= 50% of the width) and edge walls (x == 0 or x + w ==
   1280), which must not satisfy the floor by themselves. PLUS a
   CORE-MIDDLE floor: excluding floor slabs and edge walls, every level
   must have >= 2 rects (solid platforms AND/OR decorations) intersecting
   y 310..510, with combined width >= 160px. (The middle floor is
   satisfied by ceiling beams alone; the core-middle floor bans the
   visibly empty middle.) The checker ALSO reports a mass metric (solid
   area fraction + per-column solid coverage) for every level; there is
   NO hard mass threshold — silhouette is judged eyes-on against the
   reference frames. Eyes-on screenshot review is the final density
   judge; these floors only ban empty middles mechanically.
10. DECORATIONS (harness only, except the runtime draw + key acceptance):
    the `decorations` array, if present, MUST satisfy the Decorations
    section (attachment chain, keep-out, no hazard/spawn/door overlap,
    bounds). The runtime MUST accept files with and without the array,
    MUST draw decorations (tint + background layer), and MUST NOT create
    collision for them. The runtime neither validates nor warns on
    decorations. The harness counts solid + decoration rects together
    for the rule 9 core-middle floor. SHIPPED-FILE RULE: the shipped
    file SHOULD contain zero decorations (strict 2-colour discipline);
    any decoration-bearing shipped level needs explicit Lead approval
    with eyes-on evidence recorded.
11. HAZARD-FAMILY PURITY (harness only): saw hazards appear ONLY in
    saw-family archetypes (D03, D08, D09, D10, D33, D37, D41) and
    mix/final archetypes (D26, D42, D43, D44). Spike-family archetypes
    carry spikes, pits, and pillars only — no saws. The generator
    publishes the archetype→family table; the checker enforces it.

## Hero

- Pure-black silhouette, ~15w x 39h, matching the collision rect
  (feet-aligned). Run-cycle leg animation + landing squash are
  DRAW-ONLY (collision shape unchanged by animation). Colour is a code
  constant (pure black), bypassing the frozen tuning hero colours.
- Visibility: a thin light outline is drawn ONLY when the level
  background is dark (luminance-gated; threshold + affected palette
  list recorded). Screenshots on the darkest palettes MUST prove the
  hero is visible AND that no outline appears on light palettes.
- A brief hero-less beat follows the level-start transition before the
  hero appears.

## HUD / controls (frozen meanings)

- Top-centre: the level indicator — a SMALL pixel-font level NUMBER
  (e.g. `37`), yellow on a small dark-red chip. The number is the ONLY
  top-centre element. No squares, no other counters.
- Top-left: pause button + restart button — SMALL dark-red square
  buttons with yellow glyphs (pause = two bars; restart = square +
  circular arrow; original drawings). Top-right: Skip button
  ("SKIP >>", same dark-red/yellow minimal style), visible ONLY after
  >= 3 deaths in the current level. Skip unlocks the next level
  without marking the current one complete, then returns to the map.
- HUD accent colours (dark-red + yellow) are FIXED code constants,
  independent of the level palette, and MUST never clash with any
  palette (proven on gold palettes, the v1.0.3 contrast minor).
- Pause: centred panel with 3 icon buttons (exit to map, restart,
  resume); the game tree is frozen behind it; the HUD stays visible.
- Death: NO game-over screen. Sequence: (1) hero vanishes in a burst
  of small black squares (~6-10px, scattered up/out, ~0.3s); (2) THEN
  "TAP TO RETRY" in yellow pixel font, upper centre (~16% down the
  screen); (3) respawn on TAP (tap-only, NO auto-retry) with full trap
  reset. During the death state the pause + restart buttons are HIDDEN;
  only the top-centre indicator stays. The level stays fully visible
  behind. The `deaths` counter increments synchronously in the death
  frame.
- Win: completing a level saves progress (ID marked complete, next
  level unlocked) and returns to the map. There is NO auto-chain into
  the next level.
- Level select is a WORLD MAP: ONE organic island silhouette (original
  shape/colours) with ONE winding trail; all 215 level nodes sit ON the
  trail in shipped order (scrollable vertically, snake-like but organic
  — varying x, no rigid grid), joined by thin crack-style path lines;
  the current node glows with a triangle marker; completed nodes show a
  check; locked nodes are dimmed + show a lock + are unclickable.
  Tapping a node plays exactly that level. There is NO door picker.
  Unlock derives from the highest unlocked level index, never from the
  completed-ID set. Big chunky pixel-font "TRAP TOWER" title + "Made by
  Ahmed" visible on first view; settings wrench top-right. Settings
  (sound toggle + music volume + close) live on the map screen only.
- Touch controls (EVERY level, overlaying the play area — NO solid
  bar): THREE large transparent outlined shapes in the level's light
  colour (the lighter of bg/trap): left chevron, right chevron, and a
  LARGER up/roof chevron for jump. Transparent fill; fill-on-press
  feedback; generous hitboxes (larger than the drawn outlines). Jump
  chevron is the largest. Multi-touch: move + jump simultaneously. No
  button-occlusion rule: geometry may sit behind the transparent
  outlines (as in the reference); eyes-on review checks bottom-corner
  readability. Never a house/roof shape for jump — the jump control is
  an up CHEVRON.
- Transitions: an ORIGINAL wipe (two panels / iris in the accent
  colour — NOT the reference's mouth shape) between map↔level and on
  level complete. Duration ~0.25s. Probes handle the delay explicitly.
- Pixel font: ALL in-game text (title, TAP TO RETRY, level number,
  SKIP, settings labels, map labels) in a chunky code-drawn bitmap
  pixel font with ORIGINAL glyphs (no binary assets). Charset: A-Z,
  0-9, space, `>`, `:`, `-`, `!`, `.`, `'`, `/`, plus any glyph the
  inventoried strings require (glyph inventory + coverage probe
  required). Legibility proven by screenshots at every size used.
- Palette discipline: strictly 2 colours per level (bg + solid) +
  BLACK (hero, particles) + WHITE (door) + fixed dark-red/yellow HUD
  accents. No other colours in level geometry. Teeth and saws draw in
  the solid colour. The map has its own fixed palette (it is not a
  level).
- No other in-level HUD: no deaths, timer, or score on the play screen.

## Structure (Run 3 flat structure, kept)

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
  ID ASSIGNMENT IS FROZEN: shipped IDs L001..L215 follow archetype-major
  order (D01S1..D43S5 in order); D44 spares are appended at the end
  ONLY as top-up. The assembly mapping file records the exact
  ID→(archetype,slot,variant) table. The shipped file is re-verified
  end-to-end after assembly; the verified count is read from the shipped
  file's own verification report, never from the candidates report.
- Save compatibility: SAVE_VERSION stays 3. Unlock derives from the
  highest unlocked INDEX, which survives regeneration correctly; the
  completed-ID checkmarks may map to different geometry after a
  regeneration — accepted as cosmetic (documented in the run ledger).
  A save-version bump would wipe the user's unlock progress and is NOT
  used.

## Example (minimal teaching level)

```json
{
  "id": "L001", "palette": 4, "template": "walk-to-door", "variation": "base",
  "spawn": {"x": 70, "y": 680}, "door": {"x": 1210, "y": 680},
  "platforms": [{"x": 0, "y": 680, "w": 1280, "h": 40, "kind": "solid"}],
  "hazards": []
}
```
