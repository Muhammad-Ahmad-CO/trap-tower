class_name TTPlayer
extends CharacterBody2D

# Centre origin (position = body centre; feet = position + (0, ph/2)).
# This matches the verifier's assumption (feet = position + height/2).
# Physics values come from tuning.json (setup). No coyote time /
# jump buffer: frozen tuning sets both to 0.
#
# Schema v3 movement: INSTANT start/stop, CONSTANT run speed. Full
# speed the frame input applies, dead stop the frame it releases.
# NO acceleration ramp, NO slide. The tuning `acceleration` /
# `air_control` fields are retained in tuning.json for the autopilot
# planner simulation only; this script deliberately never reads them.
# Jump is FIXED height (no variable jump, no jump cut).

# Pure-black hero, a code constant (LEVEL_SCHEMA.md Hero): the frozen
# tuning `hero` colours are bypassed and never read.
const HERO_COL := Color(0.0, 0.0, 0.0)
# Thin light outline ONLY when the level background is dark. Gated on
# sRGB relative luminance of the bg colour (see set_background).
# Threshold 0.15 sits in the empty band between the darkest light bg
# (0.286, palette 3) and the lightest dark bg (0.061, palette 35).
# Affected palettes (outline ON): 13, 20, 30, 35, 40. All other
# palettes: no outline.
const OUTLINE_LUM_THRESHOLD := 0.15
const OUTLINE_COL := Color(1.0, 1.0, 1.0)

var pw := 15.0
var ph := 39.0
var gravity := 3110.0
var jump_velocity := -570.0
var run_speed := 243.0
var max_fall := 600.0

# Touch input, written by the game node from the touch controls.
var touch_left := false
var touch_right := false
var touch_jump := false
var _jump_prev := false
# Probe/autopilot override: -2 = none (normal keyboard + touch input).
var input_override := -2
var jump_override_edge := false
var facing := 1
var run_phase := 0.0
var _dark_bg := false
var _squash := 0.0
var _sq_x := 1.0
var _sq_y := 1.0
# EXCEED landing dust (draw-only): white puffs at the feet on hard
# landings; they rise slightly, fade in ~0.35s, never touch physics.
var _dust: Array = []


func setup(tuning: Dictionary) -> void:
	var pl: Dictionary = tuning.get("player", {})
	pw = float(pl.get("width", 15))
	ph = float(pl.get("height", 39))
	gravity = float(pl.get("gravity", 3110.0))
	jump_velocity = float(pl.get("jump_velocity", -570.0))
	run_speed = float(pl.get("run_speed", 243.0))
	max_fall = float(pl.get("max_fall_speed", 600.0))
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(pw, ph)
	shape.shape = rect
	add_child(shape)
	collision_layer = 2
	collision_mask = 1
	floor_snap_length = 6.0


# Called by the builder with the level background colour. The outline
# gate uses the BACKGROUND luminance only (schema Hero section).
func set_background(bg: Color) -> void:
	_dark_bg = _rel_luminance(bg) < OUTLINE_LUM_THRESHOLD
	queue_redraw()


static func _rel_luminance(c: Color) -> float:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var b := _lin(c.b)
	return 0.2126 * r + 0.7152 * g + 0.0722 * b


static func _lin(c: float) -> float:
	if c <= 0.04045:
		return c / 12.92
	return pow((c + 0.055) / 1.055, 2.4)


func _ready() -> void:
	_ensure_action("move_left", [KEY_LEFT, KEY_A])
	_ensure_action("move_right", [KEY_RIGHT, KEY_D])
	_ensure_action("jump", [KEY_SPACE, KEY_UP, KEY_W])


func _ensure_action(action: StringName, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	if InputMap.action_get_events(action).is_empty():
		for k in keys:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)


func reset_state() -> void:
	_jump_prev = false
	run_phase = 0.0
	facing = 1
	_squash = 0.0
	_dust = []


func _spawn_dust() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(Time.get_ticks_msec()) + int(global_position.x)
	for i in range(6):
		_dust.append({
			"pos": Vector2(rng.randf_range(-10.0, 10.0), ph * 0.5 - 2.0),
			"vel": Vector2(rng.randf_range(-45.0, 45.0),
				rng.randf_range(-55.0, -15.0)),
			"size": rng.randf_range(4.0, 8.0),
			"life": 0.35,
			"max_life": 0.35,
		})


func _update_dust(delta: float) -> void:
	if _dust.is_empty():
		return
	var keep: Array = []
	for d in _dust:
		var dd: Dictionary = d
		dd["pos"] = (dd["pos"] as Vector2) + (dd["vel"] as Vector2) * delta
		dd["vel"] = (dd["vel"] as Vector2) + Vector2(0, 40.0) * delta
		dd["life"] = float(dd["life"]) - delta
		if float(dd["life"]) > 0.0:
			keep.append(dd)
	_dust = keep


func feet_pos() -> Vector2:
	return global_position + Vector2(0, ph * 0.5)


func player_rect() -> Rect2:
	return Rect2(global_position - Vector2(pw * 0.5, ph * 0.5), Vector2(pw, ph))


func _physics_process(delta: float) -> void:
	var dir := 0
	var want_jump := false
	if input_override != -2:
		dir = input_override
		want_jump = jump_override_edge
		jump_override_edge = false
	else:
		dir = int(Input.is_action_pressed("move_right")) - int(Input.is_action_pressed("move_left"))
		if touch_right:
			dir += 1
		if touch_left:
			dir -= 1
		dir = clampi(dir, -1, 1)
		var held := Input.is_action_pressed("jump") or touch_jump
		want_jump = held and not _jump_prev
		_jump_prev = held
	if dir != 0:
		facing = dir
	# Instant start/stop: velocity.x IS the target, every frame.
	velocity.x = float(dir) * run_speed
	var was_air := not is_on_floor()
	velocity.y = minf(velocity.y + gravity * delta, max_fall)
	if want_jump and is_on_floor():
		velocity.y = jump_velocity
		TTAudio.play_jump()
	var fall_vy := velocity.y
	move_and_slide()
	if was_air and is_on_floor() and fall_vy > 200.0:
		_squash = 1.0
		TTAudio.play_land()
		_spawn_dust()
	if _squash > 0.0:
		_squash = maxf(0.0, _squash - delta / 0.12)
	_update_dust(delta)
	if is_on_floor() and absf(velocity.x) > 10.0:
		run_phase += delta * absf(velocity.x) * 0.055
	queue_redraw()


# Squash mapping (DRAW-ONLY): scales the silhouette around the feet
# line so the feet stay planted; the collision shape never changes.
func _map(p: Vector2) -> Vector2:
	var feet_y := ph * 0.5
	return Vector2(p.x * _sq_x, feet_y + (p.y - feet_y) * _sq_y)


func _draw() -> void:
	# Drawn silhouette matches the collision rect (pw x ph, centre
	# origin, feet at +ph/2) at rest: head top touches -ph/2, feet
	# touch +ph/2, torso/head inside the rect width. During the run
	# cycle the legs swing past the rect sides (draw-only; the
	# collision rect never changes) so distinct leg-spread poses are
	# visible in screenshots.
	_sq_x = 1.0 + 0.22 * _squash
	_sq_y = 1.0 - 0.18 * _squash
	if _dark_bg:
		_draw_pose(OUTLINE_COL, 1.5)
	_draw_pose(HERO_COL, 0.0)
	_draw_dust()


func _draw_dust() -> void:
	for d in _dust:
		var dd: Dictionary = d
		var a := clampf(float(dd["life"]) / float(dd["max_life"]), 0.0, 1.0) * 0.7
		draw_circle(dd["pos"], float(dd["size"]), Color(1, 1, 1, a))


func _draw_pose(col: Color, grow: float) -> void:
	var feet_y := ph * 0.5
	var head_r := 6.0 + grow
	var head_c := _map(Vector2(0, -feet_y + 6.0))
	var swing := 0.0
	var air := not is_on_floor()
	if air:
		swing = 7.0
	elif absf(velocity.x) > 10.0:
		swing = sin(run_phase) * 8.0
	var hip_l := _map(Vector2(-3, 5))
	var hip_r := _map(Vector2(3, 5))
	var foot_l: Vector2
	var foot_r: Vector2
	if air:
		foot_l = _map(Vector2(-7, feet_y - 2.5))
		foot_r = _map(Vector2(6, feet_y - 4.5))
	else:
		foot_l = _map(Vector2(-3 + swing, feet_y))
		foot_r = _map(Vector2(3 - swing, feet_y))
	_draw_leg(hip_l, foot_l, col, 4.0 + grow * 2.0)
	_draw_leg(hip_r, foot_r, col, 4.0 + grow * 2.0)
	var torso_tl := _map(Vector2(-5, -8))
	var torso_br := _map(Vector2(5, 6))
	var torso := Rect2(torso_tl, torso_br - torso_tl).grow(grow)
	draw_rect(torso, col)
	var shoulder := _map(Vector2(0, -4))
	var hand := _map(Vector2(facing * 6.0 - swing * 0.6, 3))
	draw_line(shoulder, hand, col, 3.0 + grow * 2.0)
	draw_circle(head_c, head_r, col)


# Legs stop half a line-width short of the foot point so the drawn
# foot bottom lands on the collision rect's bottom edge (feet-aligned,
# no overshoot below the rect).
func _draw_leg(hip: Vector2, foot: Vector2, col: Color, width: float) -> void:
	var d := foot - hip
	var len := d.length()
	if len > width * 0.5:
		foot = foot - d / len * (width * 0.5)
	draw_line(hip, foot, col, width)
