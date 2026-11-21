extends SceneTree

# Lane F2: L130 nightmare passability probe. The greedy autopilot
# fails nightmare L130 (mover-lift, period 2.8 -> 1.82) in all
# wait-offset attempts, while normal L130 passes 0 deaths and
# mirrored-only passes 0 deaths. This probe plays the level with a
# HUMAN-TIMED policy on the real game scene (real physics).
# Nightmare L130 is MIRRORED: spawn x1210, door x90, the mover is
# at x620-720, the step + spike at x540-620 (spike x560), so the
# hero runs LEFT:
#   1. run left; at x~760 jump onto the mover (jump rise 57 clears
#      any mover height, max 40 above the floor)
#   2. ride the mover; WAIT until it is near the top (top <= 605),
#      then run left and jump at x<=650 over the step spike
#   3. run left to the door
# If the scripted crossing reaches the door, nightmare L130 is
# human-passable and the autopilot failure is a planner limit
# (it does not time movers), not an impassable level.
# Usage: godot --headless --fixed-fps 60 --path <project> -s <abs path>/f2_l130_probe.gd
# Prints L130PROBE PASS/FAIL, exits 0 only on PASS. Restores a
# FRESH save at the end (a win would otherwise record L130).

var _mover: Node = null


func _initialize() -> void:
	call_deferred("_run")


func _wipe_saves() -> void:
	DirAccess.remove_absolute(OS.get_user_data_dir() + "/progress.cfg")
	DirAccess.remove_absolute(OS.get_user_data_dir() + "/nightmare.cfg")
	DirAccess.remove_absolute(OS.get_user_data_dir() + "/ghosts.cfg")


func _mover_top() -> float:
	if _mover == null:
		return 9999.0
	var rect: Rect2 = _mover.get("rect")
	return float(_mover.position.y) - rect.size.y * 0.5


func _run() -> void:
	_wipe_saves()
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	TTState.return_door = -1
	TTState.daily = false
	TTState.nightmare = true
	TTState.bonus = false
	TTState.level_index = 129  # L130
	var game_inst: Node = game_scene.instantiate()
	root.add_child(game_inst)
	await physics_frame
	await physics_frame
	var runtime: Node = game_inst.get("runtime")
	var player: Node = game_inst.get("player")
	if runtime == null or player == null:
		print("L130PROBE ERROR: no runtime/player")
		_finish(false)
		return
	for p in runtime.get("platforms"):
		if str(p.get("kind")) == "moving":
			_mover = p
	if _mover == null:
		print("L130PROBE ERROR: no mover found")
		_finish(false)
		return
	print("L130PROBE mover rest top=", _mover_top(), " period=", _mover.get("period"),
		" spawn=", (game_inst.get("current_level") as Dictionary).get("spawn", {}))
	var died := false
	var phase := 0  # 0 approach + jump on, 1 ride + wait-high + jump off, 2 run to door
	var jumped_on := false
	var jumped_off := false
	var jumped_s1 := false  # floor spike x940-980, jumped from the right
	var jumped_s3 := false  # floor spike x240-280, jumped from the right
	for f in range(1500):
		await physics_frame
		if bool(game_inst.get("level_completed")):
			print("L130PROBE PASS: scripted timed crossing reached the door in ", f, " frames")
			_finish(true)
			return
		if player == null or not is_instance_valid(player):
			died = true
			break
		var runtime2: Node = game_inst.get("runtime")
		if runtime2 != null and runtime2.get("dead") == true:
			died = true
			break
		var hx: float = player.global_position.x
		var feet_y: float = player.call("feet_pos").y
		var top := _mover_top()
		var on_mover: bool = (player.call("is_on_floor") == true) and absf(feet_y - top) <= 4.0 and hx >= 605.0 and hx <= 735.0
		var in_dip: bool = (player.call("is_on_floor") == true) and absf(feet_y - 660.0) <= 4.0 and hx >= 620.0 and hx <= 720.0
		if phase == 0:
			if on_mover:
				phase = 1
			elif hx <= 1015.0 and hx > 985.0 and not jumped_s1:
				# Floor spike x940-980: jump over it from the right.
				player.set("input_override", -1)
				player.set("jump_override_edge", true)
				jumped_s1 = true
			elif hx <= 760.0 and not jumped_on:
				player.set("input_override", -1)
				player.set("jump_override_edge", true)
				jumped_on = true
			elif in_dip:
				# Fell into the dip under the mover: wait for it to
				# come down (top >= 630, only 30 above the dip
				# floor), then jump back onto it.
				if top >= 630.0:
					player.set("input_override", -1)
					player.set("jump_override_edge", true)
				else:
					player.set("input_override", 0)
			else:
				player.set("input_override", -1)
		elif phase == 1:
			if on_mover and top <= 608.0:
				player.set("input_override", -1)
				# Jump from near the mover's LEFT edge (x~632): the
				# flight then covers the 85px to the floor past the
				# step spike (x560-600) with margin. Jumping earlier
				# (x650) lands on the spike's left edge.
				if hx <= 632.0 and not jumped_off:
					player.set("jump_override_edge", true)
					jumped_off = true
			elif on_mover:
				player.set("input_override", 0)
			elif hx <= 545.0:
				# Landed on the floor past the step: run to the door.
				phase = 2
				player.set("input_override", -1)
			elif in_dip:
				phase = 0
				jumped_on = false
			else:
				# Airborne off the mover, or slipped off sideways:
				# keep running left.
				player.set("input_override", -1)
		else:
			if hx <= 315.0 and hx > 285.0 and not jumped_s3:
				player.set("input_override", -1)
				player.set("jump_override_edge", true)
				jumped_s3 = true
			else:
				player.set("input_override", -1)
	if died:
		var hx := 0.0
		if player != null and is_instance_valid(player):
			hx = player.global_position.x
		print("L130PROBE FAIL: hero died (mover top was ", _mover_top(), ", hero x=", hx, ")")
	else:
		print("L130PROBE FAIL: timeout, no door in 1500 frames")
	_finish(false)


func _finish(ok: bool) -> void:
	_wipe_saves()
	TTState.daily = false
	TTState.nightmare = false
	TTState.return_door = -1
	if ok:
		print("L130PROBE ALL PASS")
		quit(0)
	else:
		print("L130PROBE FAILED")
		quit(1)
