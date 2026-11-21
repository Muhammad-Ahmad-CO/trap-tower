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
  at at least one point of its sweep (rule 7); a swing pivot must lie
  inside a solid beam. Swing connectors draw as a thin SOLID-COLOUR bar (silhouette-
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
   shipped slots MUST span >= 3 distinct shape skeletons (documented skeleton
   table); eyes-on review judges within-group visual diversity every
   loop — 5 copies of one layout are a defect even if signatures differ.
   (D3 ships 4 slots; D44 ships 1 slot, a single level, so the >= 3
   skeleton span does not apply to it.)
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
     <= r + 4) at AT LEAST ONE swept sample (rest / path endpoint /
     13-sample swing arc) for a MOVING saw (path/swing) — Stage 2 §4.3
     R1: a gap-patrol disc inherently cannot touch solid over the gap,
     so the old every-sample rule made every gap-patrol geometry fail
     by construction. A STATIC saw (single centre) must touch at that
     centre. Swing pivots must lie inside a solid beam.
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
  without marking the current one complete, then returns to the map
  with the played door's picker auto-opened.
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
  level unlocked) and returns to the map with the played door's picker
  auto-opened. There is NO auto-chain into the next level: no stage
  ever auto-advances to the next stage.
- Level select is a WORLD MAP: ONE organic island silhouette (original
  shape/colours) with ONE winding trail; 44 door nodes sit ON the
  trail in shipped order (scrollable vertically, snake-like but organic
  — varying x, no rigid grid), joined by thin crack-style path lines;
  the current door glows with a triangle marker; completed doors show a
  check; locked doors are dimmed + show a lock + are unclickable.
  Tapping a door opens its stage picker: a dismissible overlay (close X
  + tap-outside to close) listing that door's stages — one stage = one
  level — with the obstacle type as the picker subtitle. There is no
  auto-select and no NEXT button in the picker; tapping a stage plays
  exactly that level. After a win or a skip, the map returns with the
  played door's picker auto-opened (TTState.return_door); pause-exit
  returns to the plain map with no picker open. A stage never
  auto-advances to the next stage. Door state is derived from the save,
  never stored per door: a door is unlocked iff its first stage index
  <= highest_unlocked; the current door is the door of
  highest_unlocked; a door is done iff all of its stage IDs are in the
  completed set. Big chunky pixel-font "TRAP TOWER" title + "Made by
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

## Structure (v1.0.5 door structure)

- Levels ship grouped into 44 doors on the island map (215 stages
  total; one stage = one level). Each door shares one obstacle type
  (template) and one palette (door N = palette N-1). All 44 templates
  are distinct — no two doors share an obstacle type. The grouping is
  the frozen door table in `godot/scripts/door_map.gd` (class
  `TTDoorMap`), derived from
  `verification/exceed/assembly-mapping-exceed.json` (sha 350de95b =
  live `levels.json`); never derive a door from the level index by
  arithmetic — door 3 has 4 stages, so doors 4+ shift by one. Most
  doors have 5 stages; door 3 has 4 (L011-014) and door 44 has 1
  (L215). Within a door, the stages are variants of the one gimmick;
  no ordering claim is made about the slots.

| Door | Template | Levels | Palette |
|---|---|---|---|
| D1 | pitfall | L001-005 | 0 |
| D2 | spike-hops | L006-010 | 1 |
| D3 | saw-runs | L011-014 | 2 |
| D4 | popup-spikes | L015-019 | 3 |
| D5 | triggered-spikes | L020-024 | 4 |
| D6 | triggered-pillars | L025-029 | 5 |
| D7 | periodic-pillars | L030-034 | 6 |
| D8 | swing-saws | L035-039 | 7 |
| D9 | patrol-saws | L040-044 | 8 |
| D10 | gap-saws | L045-049 | 9 |
| D11 | spiked-columns | L050-054 | 10 |
| D12 | dashed-chains | L055-059 | 11 |
| D13 | falling-floors | L060-064 | 12 |
| D14 | tilting-blocks | L065-069 | 13 |
| D15 | moving-bridges | L070-074 | 14 |
| D16 | mover-chains | L075-079 | 15 |
| D17 | ceiling-spikes | L080-084 | 16 |
| D18 | wall-spikes | L085-089 | 17 |
| D19 | step-climbs | L090-094 | 18 |
| D20 | double-gaps | L095-099 | 19 |
| D21 | pit-bridges | L100-104 | 20 |
| D22 | gauntlets | L105-109 | 21 |
| D23 | timed-mixes | L110-114 | 22 |
| D24 | pillar-alleys | L115-119 | 23 |
| D25 | pillar-forests | L120-124 | 24 |
| D26 | grand-mixes | L125-129 | 25 |
| D27 | mover-lifts | L130-134 | 26 |
| D28 | tower-descents | L135-139 | 27 |
| D29 | reversed-runs | L140-144 | 28 |
| D30 | skyline-city | L145-149 | 29 |
| D31 | drop-shafts | L150-154 | 30 |
| D32 | zigzag-descents | L155-159 | 31 |
| D33 | saw-fields | L160-164 | 32 |
| D34 | trigger-pits | L165-169 | 33 |
| D35 | spike-forests | L170-174 | 34 |
| D36 | ceiling-gauntlets | L175-179 | 35 |
| D37 | saw-corridors | L180-184 | 36 |
| D38 | timed-corridors | L185-189 | 37 |
| D39 | dashed-towers | L190-194 | 38 |
| D40 | column-forests | L195-199 | 39 |
| D41 | final-tower-saws | L200-204 | 40 |
| D42 | final-skyline | L205-209 | 41 |
| D43 | final-reversed | L210-214 | 42 |
| D44 | final-mega | L215 | 43 |

## Part B (v1.0.5) — redesigned doors: mechanics + per-door ramp

The 2026-11-19 type-uniqueness audit found 26 of 44 doors duplicated
another door's mechanic (13 PASS / 5 BORDERLINE / 26 FAIL). Part B
regenerated the flagged doors' builders (same schema kinds/fields, no
new kinds). Template NAMES above are frozen identifiers (they appear in
`godot/scripts/door_map.gd` and in shipped `levels.json`); the MECHANIC
column below is what actually changed. "Distinct" means a different rule
the player must learn, not a different position/shape/count.

### Per-door ramp (new in Part B)

Every regenerated door carries slot-indexed tables inside its
`v3_dXX` builder: hazard count non-decreasing, timing periods
decreasing, speeds/leads tightening, and clear widths shrinking across
slots 1→5. The ramp is per-door (no global ramp parameter exists).
Where a count deviates from monotone (a seat proved unbuildable under
the frozen checker/autopilot), the deviation is recorded honestly
below — the ramp tables are the builders' actual tables, not targets.

| Door | Part B mechanic (rule the player must learn) | Ramp (slots 1→5) |
|---|---|---|
| D01 | Blink pit: a floor segment blinks (dashed) while triggered strips pop on approach. | dashed period [3.0,2.8,2.8,2.6,2.6], on [2.0,2.0,1.8,1.8,1.6]; triggered lead [220,210,200,190,180]. S4 double-pit uses offset phases. |
| D08 | Saw-bridge: a STATIC floor-grazing saw on a narrow bridge over a pit — jump the pit while clearing the saw. (Moving/patrol saws are unbuildable under the frozen checker+autopilot; see run ledger.) | saw r [18,20,20,22,22]; pit_w [160,160,160,140,140]. |
| D09 | Raised walkway: static saws grazing an elevated walkway, gaps below. | n_saws [1,2,2,2,3] (S4 capped at 2: 3 saws at 120px centres make the bot jump into the next disc). |
| D10 | Pier saw: a STATIC saw on a mid-gap solid pier; path is dashed/falling stones. | stone stand [1.4,1.2,1.2,1.0,1.0]; period [3.0,2.8,2.8,2.6,2.6]. |
| D14 | Tilting stone + periodic popup on the same divider, simultaneous. (Distinctness rests on the popup pairing; tilting alone equals D13's falling.) | stand [2.0,1.8,1.8,1.6,1.6]; popup period [3.4,3.0,3.0,2.6,2.6], on [1.6,1.4,1.4,1.2,1.2]. |
| D16 | Chained movers: one horizontal slide + one vertical bob per slot; board the slide by a 40 drop, never flush. | period [3.8,3.6,3.6,3.4,3.4]; bob dy [40,50,50,60,60]. |
| D17 | Ceiling teeth at jump height over raised ground, every level (don't jump high here). | teeth groups [3,5,5,5,5] (S5 lost a group to the beam Blocker law). |
| D18 | Drop-shaft: fall a narrow shaft, climb in, door on the shaft floor; side teeth at jump height in the shaft. | shaft width [260,240,240,220,220] (narrowing); teeth height [40,48,48,56,60]. |
| D20 | Sync pairs: both gap stones crossed in ONE jump arc (linked pair via geometry, no new field). | dashed period [3.0,2.8,2.8,2.6,2.6], on [2.0,2.0,1.8,1.8,1.6]; falling/tilting stand [1.4,1.2,1.2,1.0,1.0]. |
| D21 | Pit-bridge + triggered pillar over the divider (pillar lands as a block to jump over). S3/S5 use a periodic pillar instead (a triggered pillar would land buried / overshoot). | pillar speed [700,750,800,850,900]; stand [1.4,1.2,1.2,1.0,1.0]. |
| D22 | Twin columns + popup: two 24-tall columns 6px apart cleared in ONE jump arc, plus a periodic popup past the landing. (36-tall twin pairs are unjumpable; rule 11 forbids saws here.) | popup period [3.4,3.0,3.0,2.6,2.6], on [1.6,1.4,1.4,1.2,1.2]; pair count [1,1,1,2,2]. |
| D23 | Popup UNDER the pillar's fall column: two different clocks in the same space. | pillar period [4.4,4.0,4.0,3.6,3.6]; popup period [3.4,3.0,3.0,2.6,2.6]. |
| D24 | Overlapping drop zones: a triggered pillar (40w) + a periodic pillar (60w) overlapping 10px — one continuous danger zone, no safe gap. | periodic period [4.4,4.0,4.0,3.6,3.6]; triggered speed [600,650,650,700,700]. |
| D25 | Three overlapping pillars (triggered + periodic + triggered, 120px continuous zone). | same as D24. |
| D26 | Pier + static saw + dashed stone after the pier (saw seated on a solid pier, never over a dashed stone — saw touch is checked against SOLID rects only). | saw r [22,22,24,24,26]; dashed period [3.0,2.8,2.8,2.6,2.6], on [2.0,2.0,1.8,1.8,1.6]. |
| D27 | Elevator restored: a mover (dy=-200) carries the player to a 440 ledge. (Required mover rides are autopilot-provable: strategy 2, 0 deaths.) | mover period [3.8,3.6,3.6,3.4,3.4]; ledge strips tighten per slot. dy stays -200 in every slot (changing it moves the ledge and breaks beam clearance). |
| D29 | Reversed, triggered strips armed from the right DOMINANT in every level + columns. (Mechanic is D05's triggered strip, mirrored; distinctness rests on the reversed route + column pairing.) | triggered count [2,3,3,4,4]; lead [160,140,140,120,120] (decreasing = tighter). |
| D30 | Descending slots (1,3,5) only: tower-floor static strips become periodic popups. Ascending slots (2,4) unchanged. | descending popup count [2,3,4]; period [3.4,3.0,2.6], on [1.6,1.4,1.2]. |
| D32 | Tower floors ALTERNATE solid/dashed (floor1 solid, floor2 dashed, floor3 solid, floor4 dashed). Distinct from D39 (all dashed) and D28 (all solid). | dashed period [3.2,3.0,3.0,2.8,2.8], on [2.2,2.0,2.0,1.8,1.8]. |
| D33 | Saw-steps: static saws seated on ascending/descending steps at three heights. | n_saws [2,2,3,3,3]. |
| D34 | Mover pit: the pit's floor is a moving stone the player rides across, plus triggered strips. | mover period [3.2,3.0,3.0,2.8,2.8]; triggered lead [220,210,200,190,180]. S3 pit is 120w (80w mover + 40px sweep); fits x0=160 but not x0=200. |
| D35 | Ceiling teeth at jump height over raised ground (beam bottom 4px above the jump head apex; walking clears them, jumping kills). | teeth clusters [2,2,3,3,4]; strip count [1,1,2,2,1] (S5 has 1: its second strip sat in a landing zone). |
| D36 | Periodic pillar AND ceiling teeth at jump height over raised ground, simultaneous. NO strips (a strip-jump takeoff under a teeth cluster kills the autopilot; ablation-proven). | pillar period [4.4,4.0,4.0,3.6,3.6]; teeth clusters [2,3,3,4,4]. |
| D37 | Corridor static saws under the corridor beam. (Mechanic converges with D03; the corridor is visual identity — recorded honestly.) | saw r [22,22,24,24,24]. |
| D38 | Dashed gap INSIDE the pillar's fall column: cross the blinking stone while the pillar is up. | pillar period [4.4,4.0,4.0,3.6,3.6]; pillar count [1,1,1,2,2]. |
| D40 | Hanging stalactites: spiked columns top-attached under a grounded beam at jump height (don't jump under them). A solid hanger block cannot hang (grounding needs rest-on or pillar-from-below); a single 74-tall hanging column is accepted by the checker's `hung` rule and the generator-side span guard exempts hanging columns. A stalactite only works over a 640 surface (walking head 601 clears the 560 bottom by 41px). | stalactite count [2,3,3,4,4]; strip count [1,1,2,3,3] (S2 has 1: its second strip had no legal seat). |
| D43 | Reversed, triggered strips armed from the right DOMINANT in every level + static saws (D29's second element is columns — that is the D43 distinction). Saw r capped at 24: a r=26 (52w) disc is unjumpable in reverse. | triggered count [2,2,3,4,4] (S2 has 2: a post-gap strip is unplaceable); lead [160,140,140,120,120]; saw r [22,22,24,24,24]; saw count [1,1,2,1,1]. |
| D44 | Simultaneous finale (slot 1 only; slots 2-5 are spares): a periodic pillar AND a popup under its fall column AND a dashed gap stone AND a static saw, all inside one ~300px crossing zone — not a sequence. | No ramp (single level). |

### O2 mass (Part B)

Where a flagged door was regenerated, massive solid slabs are preferred
over thin ~12px beams (steps, plateaus, piers, bridges). Full O2 overhaul
(replacing beams with slabs everywhere) is out of scope — beams are
needed for grounding, and unflagged doors were not redesigned for mass
alone.

### Honest distinctness gaps remaining (Part B)

- D14: distinctness rests on the tilting+popup pairing; if the auditor
  still calls it a duplicate of D13, it needs a coordinator ruling
  (a rising stone needs a NEW kind = schema change).
- D29/D43: the mechanic is D05's triggered strip, mirrored; distinctness
  rests on the reversed route + the second element (columns for D29,
  saws for D43). If the auditor still calls them D05-mirrored, that is
  a coordinator ruling, not a builder fix.
- D37: the mechanic converges with D03 (static saws under a beam); the
  corridor is visual identity.
- D18: distinctness from D31 rests on the narrow block-gap geometry
  (the shaft is D31's vertical-fall pattern with a climb-in and the
  door on the shaft floor).
- D08: D01 (pit) + D03 (static saw), not a wholly new kind; pendulum
  timing is lost (moving saws are unbuildable).
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
  highest unlocked INDEX, which survives regeneration correctly; door
  state is derived from it (see Level select above), so no per-door
  state is stored. The completed-ID checkmarks may map to different
  geometry after a regeneration — accepted as cosmetic (documented in
  the run ledger). A save-version bump would wipe the user's unlock
  progress and is NOT used.

## Example (minimal teaching level)

```json
{
  "id": "L001", "palette": 4, "template": "walk-to-door", "variation": "base",
  "spawn": {"x": 70, "y": 680}, "door": {"x": 1210, "y": 680},
  "platforms": [{"x": 0, "y": 680, "w": 1280, "h": 40, "kind": "solid"}],
  "hazards": []
}
```
