# Trap Tower injected multi-touch test (Lane B)

Injects `InputEventScreenTouch` events with **distinct indices** into the
game's real touch controls, headless, and asserts the frozen control-bar
behaviour:

| Case | Assertion |
|---|---|
| (a) | Left held (index 0) + jump pressed (index 1) simultaneously → player moves AND jumps |
| (b) | Release jump only → horizontal motion continues |
| (c) | Drag finger off a button → button releases (no stuck input) |
| (d) | All fingers released → all input idle |

State is read from the controls' own properties, `get_input_state()`,
Input actions, or player velocity — whichever the game exposes. If no
controls or no readable state signal is found, cases report **BLOCKED**,
never a fabricated pass.

## Running

```bash
# Game mode (default): report to verification/
tools/touch_test/run_touch_test.sh

# Fixture self-test (no game project needed; see probe project below):
tools/touch_test/run_touch_test.sh --project /tmp/trap-tower-probe -- \
    --mode fixture --out /tmp/touch-fixture.txt
```

Exit code: 0 = all cases passed; 1 = any FAIL/BLOCKED; 2 = usage error.

## Fixture self-test

`--mode fixture` runs the same cases against the `FixtureControls`
class in `touch_test.gd`, which implements the frozen semantics
(multi-touch tracked by finger index, release on drag-off). It proves
the injection harness works headless. Fixture results are **not** game
verification and are always labelled fixture.

Probe project (shared with the autopilot self-test):

```bash
mkdir -p /tmp/trap-tower-probe
printf '[application]\nconfig/name="Trap Tower Probe"\n\n[display]\nwindow/size/viewport_width=1280\nwindow/size/viewport_height=720\n\n[physics]\ncommon/physics_ticks_per_second=60\n' \
  > /tmp/trap-tower-probe/project.godot
```

## Expected game interface (for the Implementation lane / Lead)

Discovery tries, in order:

- Scenes: `res://scenes/touch_controls.tscn`, `res://scenes/control_bar.tscn`,
  `res://scenes/hud.tscn`, `res://scenes/game.tscn`,
  `res://scenes/Game.tscn`, `res://game.tscn`, `res://scenes/main.tscn`,
  `res://main.tscn`
- Scripts: `res://scripts/touch_controls.gd`, `res://scripts/control_bar.gd`,
  `res://scripts/touch_buttons.gd`, `res://scripts/hud.gd`,
  `res://scripts/game.gd`
- Button rects: a `get_button_rect("left"|"right"|"jump")` method, or child
  `Control` nodes named with `left`/`right`/`jump` and non-empty global rects
- State: `get_input_state()` returning `{left, right, jump}`, boolean
  properties (`touch_left`/`touch_right`/`touch_jump`,
  `left_pressed`/`right_pressed`/`jump_pressed`, …), or Input actions
  (`move_left`/`move_right`/`jump`, `ui_*`, or `left`/`right`/`jump`)
- The controls must handle `InputEventScreenTouch`/`InputEventScreenDrag`
  via `_input`/`_gui_input` for injection to reach them

If the game uses different names, cases report BLOCKED with notes saying
what was tried. Aligning the game to the names above (or extending the
discovery lists in `touch_test.gd`, Lane B) restores game-mode testing.

## Phone-only — stated plainly in every report

Finger size/occlusion, Oppo F9 input latency, and non-16:9
scaling/letterbox behaviour cannot be verified headless and are never
claimed here. Only a phone test covers them.
