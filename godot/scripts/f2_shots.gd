extends Node

# Lane F2 screenshot driver: renders REAL frames through the real
# map/game scenes and real UI paths (never mockups). Run under Xvfb
# with a real rendering driver (NOT --headless):
#   xvfb-run -a <godot> --path <project> res://scenes/f2_shots.tscn -- \
#     --shot-out <dir>
# Captures into <dir> (default ~/workspace/trap-tower/verification/shots-f2):
#   map_f2.png          fresh map, DAILY + NIGHTMARE buttons (locked)
#   nightmare_locked.png  locked overlay: requirement + DONE 0/215
#   daily_overlay.png   daily overlay: today's date + NOT DONE YET
#   daily_play.png      real daily level (today's seed), hero mid-run,
#                       DAILY tag under the level chip
#   daily_done.png      daily overlay after a win: DONE - BEST m:ss
#                       (display fixture: daily_best written directly;
#                       the real win->record path is proven by the
#                       F2 probe, not by this capture)
#   map_nightmare_on.png  all-215 map, NIGHTMARE armed (NIGHTMARE ON)
#   nightmare_play.png  real L001 in nightmare mode: mirrored layout
#                       (door on the left, spawn on the right) +
#                       NIGHTMARE tag, hero driving left
# Progress fixtures are written to user://progress.cfg; a FRESH empty
# progress + no nightmare.cfg are restored at the end.

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
		_out_dir = OS.get_environment("HOME") + "/workspace/trap-tower/verification/shots-f2"
	else:
		_out_dir = out_arg
	var derr := DirAccess.make_dir_recursive_absolute(_out_dir)
	if derr != OK:
		print("F2SHOT ERROR: cannot create out dir ", _out_dir, " err=", derr)
		get_tree().quit(1)
		return
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("F2SHOT ERROR: ", str(loaded.get("error")))
		get_tree().quit(1)
		return
	var levels: Array = loaded["levels"]
	var ids: Array = []
	for lv in levels:
		ids.append(str((lv as Dictionary).get("id", "")))
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	var today := TTDaily.today_string()

	# 1. Fresh map: DAILY + NIGHTMARE buttons, nightmare locked.
	_wipe_saves()
	_write_progress(0, [])
	TTState.return_door = -1
	TTState.daily = false
	TTState.nightmare = false
	TTState.nightmare_armed = false
	var map_inst: Node = map_scene.instantiate()
	add_child(map_inst)
	await _settle_and_capture(_out_dir + "/map_f2.png", 0.6)
	# 2. Locked nightmare overlay.
	var nm_btn := _find_text_button(map_inst, "NIGHTMARE")
	if nm_btn != null:
		_click_control(nm_btn)
	await _settle_and_capture(_out_dir + "/nightmare_locked.png", 0.4)
	map_inst.call("close_nightmare_overlay")
	await _settle(0.3)
	# 3. Daily overlay (not done yet).
	var daily_btn := _find_text_button(map_inst, "DAILY")
	if daily_btn != null:
		_click_control(daily_btn)
	await _settle_and_capture(_out_dir + "/daily_overlay.png", 0.4)
	await _remove(map_inst)

	# 4. Real daily level playing (today's seed), short drive right.
	TTState.return_door = -1
	TTState.daily = true
	TTState.daily_date = today
	TTState.nightmare = false
	TTState.bonus = false
	TTState.level_index = 0
	var game_inst: Node = game_scene.instantiate()
	add_child(game_inst)
	await _settle(0.6)
	Input.action_press("move_right")
	await _settle(0.9)
	Input.action_release("move_right")
	await _capture_now(_out_dir + "/daily_play.png")
	await _remove(game_inst)

	# 5. Daily overlay after a win (fixture-written best time).
	TTState.daily = false
	TTProgress.save_features_patch({"daily_best": {today: {"completed": true, "best_time": 23.4}}})
	map_inst = map_scene.instantiate()
	add_child(map_inst)
	await _settle(0.6)
	map_inst.call("open_daily")
	await _capture_now(_out_dir + "/daily_done.png")
	await _remove(map_inst)

	# 6. All-215 map: arm nightmare, capture NIGHTMARE ON.
	_write_progress(214, ids)
	TTNightmare.refresh_unlock()
	TTState.nightmare_armed = false
	map_inst = map_scene.instantiate()
	add_child(map_inst)
	await _settle(0.6)
	var nm_btn2 := _find_text_button(map_inst, "NIGHTMARE")
	if nm_btn2 != null:
		_click_control(nm_btn2)
	await _settle_and_capture(_out_dir + "/map_nightmare_on.png", 0.4)
	await _remove(map_inst)

	# 7. Real nightmare L001 playing: mirrored, faster traps.
	TTState.return_door = -1
	TTState.daily = false
	TTState.nightmare = true
	TTState.bonus = false
	TTState.level_index = 0
	game_inst = game_scene.instantiate()
	add_child(game_inst)
	await _settle(0.6)
	Input.action_press("move_left")
	await _settle(0.5)
	Input.action_release("move_left")
	await _capture_now(_out_dir + "/nightmare_play.png")
	await _remove(game_inst)

	_wipe_saves()
	TTState.daily = false
	TTState.daily_date = ""
	TTState.nightmare = false
	TTState.nightmare_armed = false
	TTState.return_door = -1
	print("F2SHOT DONE")
	get_tree().quit(0)


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


func _traverse(node: Node, out: Array) -> void:
	out.append(node)
	for child in node.get_children():
		_traverse(child, out)


func _find_text_button(parent: Node, text: String) -> Control:
	var all: Array = []
	_traverse(parent, all)
	for n in all:
		if n is Control and str(n.get("text")) == text:
			return n
	return null


func _click_control(btn: Control) -> void:
	var pos: Vector2 = btn.size * 0.5
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	btn.call("_gui_input", press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = pos
	btn.call("_gui_input", release)


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
	print("F2SHOT saved ", path, " err=", err, " size=", img.get_size())


func _remove(inst: Node) -> void:
	remove_child(inst)
	inst.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
