# Trap Tower autopilot (Lane B)

Headless Godot playthrough of every level in the shipped
`godot/data/levels.json` through **real `CharacterBody2D` physics** with
the shipped `godot/data/tuning.json`. Deterministic: fixed seed, fixed
60 Hz timestep (`--fixed-fps 60`).

## Modes (reported per level, never hidden)

| Mode | Meaning | Counts toward VERIFIED? |
|---|---|---|
| `game` | Level built through the game's real loader/builder code (discovered scene/script, see below) and driven via Input actions or the game's own input properties. | **Yes** |
| `harness` | No game builder found. Level built here from the shipped JSON + shipped tuning with `CharacterBody2D`/`StaticBody2D`/`AnimatableBody2D` nodes. Real physics, but not the game's code paths. | **No — diagnostic only** |
| `blocked` | `--mode game` forced and no game builder was found. | No |

`--mode auto` (default) prefers `game` and falls back to `harness`,
recording which was used. A PASS requires reaching the door rect through
physics simulation. False negatives are acceptable (the level simply
doesn't ship); false positives are not.

## Policy

Greedy move-toward-door; jump when a hazard, gap, wall, or mountable
platform is ahead; WAIT on safe ground (up to 3 s) when a *timed* hazard
blocks the path. Each level is retried with up to 4 wait-offset
strategies (0, 0.25, 0.5, 0.75 × trap period). Death, timeout
(45 s / 2700 steps), or no-progress retries the next strategy; all
strategies failing = FAIL with the last failure reason.

On solid-ground approaches with only static hazards ahead, a ballistic
planner replaces the fixed 96 px jump trigger. It simulates the exact
discrete jump trajectory from the frozen tuning constants (jump
velocity, gravity, run speed, accelerations — loaded from
`tuning.json`, never hardcoded) for every frame-aligned takeoff along
the current ground run, and picks a takeoff whose flight clears every
lethal shape and wall, lands on solid ground, and leaves a stance with
enough run-up for the next obstacle — where "enough" is computed from
that obstacle's height via the same trajectory. Chained obstacles are
verified with a follow-up jump search from the landing stance. When no
full-speed jump chains (the landing would overshoot the gap before the
next obstacle), the planner falls back to a braked flight: releasing
the stick mid-air shortens the jump so it lands earlier in the gap.
Triggered and pop-up spikes are planned around as always-lethal rects.
The planner never reads a level id or template and never skips a level;
a PASS still requires reaching the door rect through real physics.
When a moving/dashed/falling/tilting platform, hanging pillar, or
moving (path/swing) saw lies anywhere ahead of the player, the planner
stays off and the greedy policy runs untouched, so planner timing can
never desync a timed approach; once past the timed feature it may
engage for the static stretch that follows.

## Running

```bash
# Full suite against the shipped files (game project must exist):
tools/autopilot/run_autopilot.sh

# Explicit paths / game-only mode:
tools/autopilot/run_autopilot.sh -- --levels godot/data/levels.json \
    --tuning godot/data/tuning.json --out /tmp/autopilot-report.json \
    --mode game

# One level, harness mode:
tools/autopilot/run_autopilot.sh -- --levels godot/data/levels.json \
    --tuning godot/data/tuning.json --out /tmp/one.json \
    --mode harness --only L001
```

Exit code: 0 = all levels passed; 1 = any FAIL/blocked; 2 = usage/file
error. The JSON report records the `levels.json` sha256 + count verified.

## Self-test (no game project needed)

The self-test plays the positive fixture (must PASS twice with identical
step counts, proving determinism) and the impossible-jump fixture (must
FAIL), in harness mode. It needs a minimal probe project to run Godot in:

```bash
mkdir -p /tmp/trap-tower-probe
printf '[application]\nconfig/name="Trap Tower Probe"\n\n[display]\nwindow/size/viewport_width=1280\nwindow/size/viewport_height=720\n\n[physics]\ncommon/physics_ticks_per_second=60\n' \
  > /tmp/trap-tower-probe/project.godot
tools/autopilot/run_autopilot.sh --project /tmp/trap-tower-probe -- \
    --selftest --tuning "$HOME/workspace/trap-tower/repo/godot/data/tuning.json"

(Paths must be absolute: Godot resolves relative paths against the
`--path` project directory, not the shell's working directory.)
```

## Expected game interface (for the Implementation lane / Lead)

The adapter discovers the game without any Lane B edits to game code. It
tries, in order:

- Scenes: `res://scenes/game.tscn`, `res://scenes/Game.tscn`,
  `res://game.tscn`, `res://scenes/main.tscn`, `res://main.tscn`,
  `res://scenes/level.tscn`, `res://scenes/gameplay.tscn`
- Scripts: `res://scripts/level_builder.gd`, `res://scripts/game.gd`,
  `res://scripts/level.gd`, `res://scripts/builder.gd`,
  `res://scripts/main.gd`, `res://scripts/level_data.gd`
- Build methods: `build_level`, `load_level`, `setup_level`,
  `create_level`, `load_level_data`, `set_level`, `start_level`, `build`,
  `setup` — called as `method(level_dict, tuning_dict)`
- Player: first `CharacterBody2D` under the built node
- Driving: Input actions (`move_left`/`move_right`/`jump`, or
  `ui_left`/`ui_right`/`ui_accept`, or `left`/`right`/`jump`); otherwise
  script properties (`touch_left`/`touch_right`/`touch_jump`, or
  `move_dir` + a jump property) on the player or game node
- Death: player respawn at spawn, player freed, or a `deaths` property
  increasing. Win: door-rect overlap, or a `level_completed`/`completed`/
  `won` property turning true.

If the game uses different names, game mode reports `blocked` (or falls
back to `harness` in `auto` mode) with notes saying what was tried —
never a silent substitution. Aligning the game to the names above (or
extending the discovery lists in `autopilot.gd`, Lane B) restores
game-mode verification.

## Known harness-mode approximations

- Harness bodies re-implement the *contract* (tuning physics + declarative
  trap params), not the game's scripts: moving-platform carrying uses
  `AnimatableBody2D.constant_linear_velocity`; falling-platform stand
  timers latch; landed pillars crush on overlap; death is a manual
  rect/circle overlap check each physics frame.
- The greedy policy cannot solve levels needing backtracking, waiting
  mid-air, or pixel-perfect sequences; such levels FAIL here (false
  negatives) and simply don't ship. The ballistic planner covers
  static-geometry chains (including braked short jumps) but not
  moving/falling-platform timing: bridge crossings keep the greedy
  policy and can still fail there.
- `--fixed-fps 60` makes physics deterministic; wall-clock timing,
  rendering, and audio are not exercised.
