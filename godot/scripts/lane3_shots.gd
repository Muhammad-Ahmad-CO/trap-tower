extends Node

# Lane 3 (v1.0.5 Part B final verification) screenshot driver.
# Renders REAL frames through the real map/game scenes (never mockups).
# Run under Xvfb with a real rendering driver (NOT --headless):
#   xvfb-run -a <godot> --path <project> res://scenes/lane3_shots.tscn -- \
#     --shot-out <dir>
# Captures into <dir> (default ~/workspace/trap-tower/verification/shots-lane3):
#   map_l3.png              fresh map
#   picker_l3.png           door 1 picker open on the map
#   level_l3.png            L001 playing, hero driven right
#   death_l3.png            L006, hero dead on spikes (TAP TO RETRY)
#   pause_l3.png            L001 paused (pause overlay)
#   falling_l3.png          L060 (D13S1) at spawn: falling floor segments
#                           x340-460 and x620-740 in view, unmarked
#   triggered_l3.png        L020 (D05S1) at spawn: triggered strips
#                           invisible before their trigger is crossed
#   buttons_L001_rest.png / buttons_L001_pressed.png   palette 0 (light)
#   buttons_L066_rest.png / buttons_L066_pressed.png   palette 13 (dark)
#                           pressed = RIGHT + JUMP held via real
#                           InputEventScreenTouch at the hit-rect centres
# Progress fixtures are written to user://progress.cfg; a FRESH empty
# progress is restored at the end.

var _out_dir := ""


func _ready() -> void:
	_run()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_arg := ""
	var i := 0
	while i < args.size():
		if args[i] == "--shot-out" and i + 1 < args.size():
			out_arg = args[i + 1]
			i += 2
		else:
			i += 1
	if out_arg == "":
		_out_dir = OS.get_environment("HOME") + "/workspace/trap-tower/verification/shots-lane3"
	else:
		_out_dir = out_arg
	var derr := DirAccess.make_dir_recursive_absolute(_out_dir)
	if derr != OK:
		print("L3SHOT ERROR: cannot create out dir ", _out_dir, " err=", derr)
		get_tree().quit(1)
		return
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("L3SHOT ERROR: ", str(loaded.get("error")))
		get_tree().quit(1)
		return
	var levels: Array = loaded["levels"]
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")

	# 1-2. Fresh map + door 1 picker.
	_wipe_saves()
	_write_progress(0, [])
	TTState.return_door = -1
	TTState.daily = false
	TTState.nightmare = false
	TTState.nightmare_armed = false
	var map_inst: Node = map_scene.instantiate()
	add_child(map_inst)
	await _settle_and_capture(_out_dir + "/map_l3.png", 0.6)
	map_inst.call("open_picker", 1)
	await _settle_and_capture(_out_dir + "/picker_l3.png", 0.4)
	await _remove(map_inst)

	# 3. L001 playing, hero driven right.
	var game_inst: Node = _start_level(game_scene, 0)
	await _settle(0.6)
	Input.action_press("move_right")
	await _settle(0.9)
	Input.action_release("move_right")
	await _capture_now(_out_dir + "/level_l3.png")
	await _remove(game_inst)

	# 4. L006 death: teleport-hold the hero onto the first floor spike
	# (x480-515, y630). Running right without jumping stalls on the
	# 40px steps and never reaches the spikes, so drive-right cannot
	# produce a death here. Death is tap-only with no auto-retry, so
	# the dead state holds for the capture.
	game_inst = _start_level(game_scene, 5)
	await _settle(0.5)
	var dplayer: Node = game_inst.get("player")
	var druntime: Node = game_inst.get("runtime")
	var dead := false
	for k in range(120):
		dplayer.global_position = Vector2(497, 622)
		dplayer.set("velocity", Vector2.ZERO)
		await get_tree().physics_frame
		if bool(druntime.get("dead")):
			dead = true
			break
	print("L3SHOT death reached: ", dead)
	await _settle_and_capture(_out_dir + "/death_l3.png", 0.3)
	await _remove(game_inst)

	# 5. L001 paused.
	game_inst = _start_level(game_scene, 0)
	await _settle(0.6)
	Input.action_press("move_right")
	await _settle(0.5)
	Input.action_release("move_right")
	game_inst.call("pause_game")
	await _capture_now(_out_dir + "/pause_l3.png")
	game_inst.call("resume_game")
	await _remove(game_inst)

	# 6. L060 (D13S1) falling floors, at spawn, unmarked.
	game_inst = _start_level(game_scene, 59)
	await _settle_and_capture(_out_dir + "/falling_l3.png", 0.8)
	await _remove(game_inst)

	# 7. L020 (D05S1) triggered strips at spawn: must show nothing.
	game_inst = _start_level(game_scene, 19)
	await _settle_and_capture(_out_dir + "/triggered_l3.png", 0.8)
	await _remove(game_inst)

	# 8-9. Buttons: rest vs pressed, light (L001) + dark (L066) palettes.
	for spec in [["L001", 0], ["L066", 65]]:
		var tag: String = spec[0]
		var idx: int = spec[1]
		game_inst = _start_level(game_scene, idx)
		await _settle(0.6)
		await _capture_now(_out_dir + "/buttons_" + tag + "_rest.png")
		var ctrls: Node = game_inst.get("controls")
		var rc: Rect2 = ctrls.call("get_button_rect", "right")
		var jc: Rect2 = ctrls.call("get_button_rect", "jump")
		_touch(0, true, rc.get_center())
		_touch(1, true, jc.get_center())
		# Short settle (0.12s): in L066 the first floor spike sits at
		# x150-190, 80px from spawn — a 0.4s hold runs the hero onto
		# it, the death clears the pressed state before capture.
		# 0.12s moves the hero ~29px (still alive) with both buttons
		# visibly pressed.
		await get_tree().create_timer(0.12).timeout
		await get_tree().process_frame
		await get_tree().process_frame
		print("L3SHOT pressed ", tag, " right=", ctrls.get("touch_right"),
			" jump=", ctrls.get("touch_jump"),
			" right_centre=", rc.get_center(), " jump_centre=", jc.get_center())
		await _capture_now(_out_dir + "/buttons_" + tag + "_pressed.png")
		_touch(0, false, rc.get_center())
		_touch(1, false, jc.get_center())
		await _remove(game_inst)

	_wipe_saves()
	TTState.daily = false
	TTState.nightmare = false
	TTState.nightmare_armed = false
	TTState.return_door = -1
	print("L3SHOT DONE")
	get_tree().quit(0)


func _start_level(game_scene: PackedScene, level_index: int) -> Node:
	TTState.return_door = -1
	TTState.daily = false
	TTState.nightmare = false
	TTState.bonus = false
	TTState.level_index = level_index
	var game_inst: Node = game_scene.instantiate()
	add_child(game_inst)
	return game_inst


func _touch(index: int, pressed: bool, pos: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = pressed
	ev.position = pos
	Input.parse_input_event(ev)


func _wipe_saves() -> void:
	DirAccess.remove_absolute(OS.get_user_data_dir() + "/progress.cfg")
	DirAccess.remove_absolute(OS.get_user_data_dir() + "/nightmare.cfg")
	DirAccess.remove_absolute(OS.get_user_data_dir() + "/ghosts.cfg")


func _write_progress(highest: int, completed_ids: Array) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", TTProgress.SAVE_VERSION)
	cfg.set_value("progress", "highest_unlocked", highest)
	cfg.set_value("progress", "completed", completed_ids)
	cfg.save("user://progress.cfg")


func _settle(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	await get_tree().process_frame
	await get_tree().process_frame


func _settle_and_capture(path: String, seconds: float) -> void:
	await _settle(seconds)
	await _capture_now(path)


func _capture_now(path: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("L3SHOT saved ", path, " err=", err, " size=", img.get_size())


func _remove(inst: Node) -> void:
	remove_child(inst)
	inst.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
