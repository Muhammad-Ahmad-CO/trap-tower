class_name TTPlayer
extends CharacterBody2D

# Centre origin (position = body centre; feet = position + (0, ph/2)).
# This matches the verifier's assumption (feet = position + height/2).
# All physics values come from tuning.json (setup). No coyote time /
# jump buffer: frozen tuning sets both to 0.

var pw := 28.0
var ph := 44.0
var gravity := 2200.0
var jump_velocity := -820.0
var run_speed := 360.0
var accel := 2400.0
var air_control := 0.85
var max_fall := 1200.0
var body_col := Color(0.04, 0.12, 0.27)
var eye_col := Color.WHITE

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


func setup(tuning: Dictionary) -> void:
	var pl: Dictionary = tuning.get("player", {})
	pw = float(pl.get("width", 28))
	ph = float(pl.get("height", 44))
	gravity = float(pl.get("gravity", 2200.0))
	jump_velocity = float(pl.get("jump_velocity", -820.0))
	run_speed = float(pl.get("run_speed", 360.0))
	accel = float(pl.get("acceleration", 2400.0))
	air_control = float(pl.get("air_control", 0.85))
	max_fall = float(pl.get("max_fall_speed", 1200.0))
	var hero: Dictionary = tuning.get("hero", {})
	body_col = TTuning.col(str(hero.get("body", "#0A1F44")))
	eye_col = TTuning.col(str(hero.get("eye", "#FFFFFF")))
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(pw, ph)
	shape.shape = rect
	add_child(shape)
	collision_layer = 2
	collision_mask = 1
	floor_snap_length = 6.0


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
	var target := float(dir) * run_speed
	var a := accel
	if not is_on_floor():
		a = accel * air_control
	velocity.x = move_toward(velocity.x, target, a * delta)
	velocity.y = minf(velocity.y + gravity * delta, max_fall)
	if want_jump and is_on_floor():
		velocity.y = jump_velocity
	move_and_slide()
	if is_on_floor() and absf(velocity.x) > 10.0:
		run_phase += delta * absf(velocity.x) * 0.055
	queue_redraw()


func _draw() -> void:
	# Navy runner, 1 white eye, simple leg animation. Centre origin.
	var swing := 0.0
	var air := not is_on_floor()
	if air:
		swing = 7.0
	elif absf(velocity.x) > 10.0:
		swing = sin(run_phase) * 6.0
	var hip_l := Vector2(-4, 10)
	var hip_r := Vector2(4, 10)
	var foot_l := Vector2(-4 + swing, 22)
	var foot_r := Vector2(4 - swing, 22)
	if air:
		foot_l = Vector2(-8, 20)
		foot_r = Vector2(7, 18)
	draw_line(hip_l, foot_l, body_col, 5.0)
	draw_line(hip_r, foot_r, body_col, 5.0)
	draw_rect(Rect2(-9, -10, 18, 22), body_col)
	draw_line(Vector2(0, -6), Vector2(facing * 10, 2 - swing * 0.4), body_col, 4.0)
	draw_circle(Vector2(0, -14), 8.0, body_col)
	draw_circle(Vector2(facing * 4.0, -15), 2.5, eye_col)
