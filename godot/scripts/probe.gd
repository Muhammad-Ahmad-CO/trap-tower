extends Node2D

# V3 PROBE (headless): measures the REAL jump with retuned tuning using
# the actual player script + real physics. Phase 1: full-speed run + jump
# on flat ground -> max rise px + max horizontal air distance px +
# airtime + takeoff speed. Phase 2: 80px pit at the v3 envelope gap
# (0.85 x measured air distance) -> PASS/FAIL.
# Targets (LEVEL_SCHEMA.md v3, +/-10%): rise ~57px, air ~97px,
# airtime ~0.4s, run speed ~243px/s. The v2 baselines (159.7/276.0/
# 665.1) are SUPERSEDED and must never be asserted again.
# Run: <godot> --headless --path <project> res://scenes/probe.tscn

const TARGET_RISE := 57.0
const TARGET_AIR_DIST := 97.0
const TARGET_AIRTIME := 0.4
const TARGET_SPEED := 243.0
const TOL := 0.10
const GAP_PX := 80.0

var tuning: Dictionary = {}
var player: TTPlayer = null
var floor_nodes: Array = []
var state := "run"
var sim_time := 0.0
var takeoff_feet := Vector2.ZERO
var takeoff_speed := 0.0
var min_feet_y := 0.0
var air_time := 0.0
var rise_px := 0.0
var air_dist_px := 0.0
var gap_result := "UNTESTED"
var gap_land_x := 0.0
var jumped := false
var run_speed := 243.0


func _ready() -> void:
	tuning = TTuning.load_tuning()
	var pl: Dictionary = tuning.get("player", {})
	run_speed = float(pl.get("run_speed", 243.0))
	_setup_flat()


func _gravity() -> float:
	var pl: Dictionary = tuning.get("player", {})
	return float(pl.get("gravity", 3110.0))


func _setup_flat() -> void:
	_clear_world()
	var floor := TTPlatform.new()
	floor.setup({"x": -2000, "y": 500, "w": 6000, "h": 80, "kind": "solid"}, Color(0.2, 0.2, 0.2), _gravity())
	add_child(floor)
	floor_nodes.append(floor)
	player = TTPlayer.new()
	player.setup(tuning)
	player.position = Vector2(0, 500 - player.ph * 0.5)
	add_child(player)
	player.input_override = 1
	state = "run"


func _setup_gap() -> void:
	_clear_world()
	var a := TTPlatform.new()
	a.setup({"x": -2000, "y": 500, "w": 2400, "h": 80, "kind": "solid"}, Color(0.2, 0.2, 0.2), _gravity())
	add_child(a)
	floor_nodes.append(a)
	# Gap: platform A ends at x=400; platform B starts at 400+80=480.
	var b := TTPlatform.new()
	b.setup({"x": 480, "y": 500, "w": 2000, "h": 80, "kind": "solid"}, Color(0.2, 0.2, 0.2), _gravity())
	add_child(b)
	floor_nodes.append(b)
	player = TTPlayer.new()
	player.setup(tuning)
	player.position = Vector2(0, 500 - player.ph * 0.5)
	add_child(player)
	player.input_override = 1
	jumped = false
	air_time = 0.0
	state = "gap_run"


func _clear_world() -> void:
	for n in floor_nodes:
		if is_instance_valid(n):
			n.queue_free()
	floor_nodes.clear()
	if player != null and is_instance_valid(player):
		player.queue_free()
	player = null


func _physics_process(delta: float) -> void:
	sim_time += delta
	if sim_time > 30.0:
		print("PROBE ERROR: timeout in state ", state)
		get_tree().quit(1)
		return
	if player == null or not is_instance_valid(player):
		return
	if state == "run":
		if player.is_on_floor() and player.velocity.x >= run_speed * 0.99:
			takeoff_feet = player.feet_pos()
			takeoff_speed = player.velocity.x
			min_feet_y = takeoff_feet.y
			player.jump_override_edge = true
			air_time = 0.0
			state = "wait_air"
	elif state == "wait_air":
		if not player.is_on_floor():
			state = "air"
	elif state == "air":
		air_time += delta
		min_feet_y = minf(min_feet_y, player.feet_pos().y)
		if player.is_on_floor() and air_time > 0.1:
			var land := player.feet_pos()
			rise_px = takeoff_feet.y - min_feet_y
			air_dist_px = land.x - takeoff_feet.x
			print("PROBE flat_jump rise_px=%.1f air_dist_px=%.1f takeoff_speed=%.1f air_time=%.3f" % [rise_px, air_dist_px, takeoff_speed, air_time])
			state = "switching"
			_setup_gap.call_deferred()
	elif state == "gap_run":
		# 620.0 is PROBE-LOCAL: 120px below the probe floor top
		# (y=500), not a level floor constant (FLOOR_Y=720).
		if player.feet_pos().y > 620.0:
			gap_result = "FAIL"
			gap_land_x = player.global_position.x
			_finish()
		elif not jumped and player.global_position.x >= 396.0 and player.is_on_floor():
			player.jump_override_edge = true
			jumped = true
			air_time = 0.0
			state = "gap_wait"
	elif state == "gap_wait":
		if not player.is_on_floor():
			state = "gap_air"
	elif state == "gap_air":
		air_time += delta
		if player.is_on_floor() and air_time > 0.1:
			gap_land_x = player.global_position.x
			if gap_land_x >= 480.0 and absf(player.feet_pos().y - 500.0) < 4.0:
				gap_result = "PASS"
			else:
				gap_result = "FAIL"
			_finish()
		elif player.feet_pos().y > 620.0:
			gap_result = "FAIL"
			gap_land_x = player.global_position.x
			_finish()


func _within(v: float, target: float) -> bool:
	return absf(v - target) <= target * TOL


func _finish() -> void:
	print("PROBE gap80_px=%s land_x=%.1f" % [gap_result, gap_land_x])
	var ok := _within(rise_px, TARGET_RISE) and _within(air_dist_px, TARGET_AIR_DIST) and _within(air_time, TARGET_AIRTIME) and _within(takeoff_speed, TARGET_SPEED) and gap_result == "PASS"
	print("PROBE BASELINE rise=%.1f (target %.0f, %+.1f%%) air=%.1f (target %.0f, %+.1f%%) airtime=%.3f (target %.1f, %+.1f%%) speed=%.1f (target %.0f, %+.1f%%) gap80=%s" % [rise_px, TARGET_RISE, (rise_px / TARGET_RISE - 1.0) * 100.0, air_dist_px, TARGET_AIR_DIST, (air_dist_px / TARGET_AIR_DIST - 1.0) * 100.0, air_time, TARGET_AIRTIME, (air_time / TARGET_AIRTIME - 1.0) * 100.0, takeoff_speed, TARGET_SPEED, (takeoff_speed / TARGET_SPEED - 1.0) * 100.0, gap_result])
	if ok:
		print("PROBE HEADLINE: ENVELOPE OK rise=%.1f gap=%.1f" % [rise_px, air_dist_px])
	else:
		print("PROBE HEADLINE: ENVELOPE FAIL rise=%.1f (need 51.3..62.7) gap=%.1f (need 87.3..106.7) airtime=%.3f (need 0.36..0.44) speed=%.1f (need 218.7..267.3) gap80=%s" % [rise_px, air_dist_px, air_time, takeoff_speed, gap_result])
	print("PROBE DONE")
	get_tree().quit(0 if ok else 1)
