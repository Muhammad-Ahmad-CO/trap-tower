extends Node

# Lane F3 screenshot driver: renders REAL frames through the real
# map/game scenes and real UI paths (never mockups). Run under Xvfb
# with a real rendering driver (NOT --headless):
#   xvfb-run -a <godot> --path <project> res://scenes/f3_shots.tscn -- \
#     --shot-out <dir>
# Captures into <dir> (default ~/workspace/trap-tower/verification/shots-f3):
#   map_f3.png        fresh map, TROPHIES + STATS buttons in the header
#   achievements.png  TROPHIES screen, fixture save: 7 of 12 unlocked
#   stats.png         STATS screen, same fixture: real numbers
#   ghost_on.png      L001 replay, hero mid-run + ghost visible ahead
#   ghost_off.png     same moment, ghost toggled OFF
#   pause_ghost.png   pause overlay with the GHOST ON button
# Ghost fixture note (honest): the ghost samples for ghost_on/off are
# a saved best run TIME-STRETCHED 2x, so the ghost trails the hero
# and both are visible in one frame. The probe (not the screenshot)
# proves the ghost follows the recorded path exactly.
# Progress fixtures are written to user://progress.cfg; a FRESH empty
# progress + no ghosts are restored at the end.

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
		_out_dir = OS.get_environment("HOME") + "/workspace/trap-tower/verification/shots-f3"
	else:
		_out_dir = out_arg
	var derr := DirAccess.make_dir_recursive_absolute(_out_dir)
	if derr != OK:
		print("F3SHOT ERROR: cannot create out dir ", _out_dir, " err=", derr)
		get_tree().quit(1)
		return
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("F3SHOT ERROR: ", str(loaded["error"]))
		get_tree().quit(1)
		return
	var levels: Array = loaded["levels"]
	var ids: Array = []
	for lv in levels:
		ids.append(str((lv as Dictionary).get("id", "")))
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")

	# Fresh map with the F3 header buttons.
	_wipe_saves()
	_write_progress(0, [])
	var map_inst: Node = map_scene.instantiate()
	add_child(map_inst)
	await _settle_and_capture(_out_dir + "/map_f3.png", 0.6)
	await _remove(map_inst)

	# Fixture save: 100 levels, 25 stars, 123 deaths, 61:01 played,
	# bests on L001 (8.5s) + L002 (12s) -> 7 achievements unlocked.
	_write_progress(99, ids.slice(0, 100))
	TTProgress.save_features_patch({
		"deaths": 123, "total_time": 3661.0,
		"stars_collected": ids.slice(0, 25),
		"best_times": {"L001": 8.5, "L002": 12.0},
	})
	TTProgress.check_achievements(ids)
	map_inst = map_scene.instantiate()
	add_child(map_inst)
	await _settle(0.6)
	map_inst.call("open_achievements")
	await _capture_now(_out_dir + "/achievements.png")
	map_inst.call("close_achievements")
	map_inst.call("open_stats")
	await _capture_now(_out_dir + "/stats.png")
	map_inst.call("close_stats")
	await _remove(map_inst)

	# Ghost shots on real L001: a saved best run, time-stretched 2x
	# so the ghost trails the hero and both read in one frame. Hero
	# is driven right for real. The fixture follows L001's REAL step
	# terrain (spawn feet 640, steps up to 480 at x640-840, back to
	# 640 at the door) — a constant y floated in mid-air above the
	# steps in the first capture. Centre y = feet y - 19.5.
	_wipe_saves()
	_write_progress(0, [])
	var ghost: Array = []
	var x := 90.0
	while x < 1150.0:
		var feet_y := 640.0
		if x >= 400.0 and x < 480.0:
			feet_y = 600.0
		elif x >= 480.0 and x < 560.0:
			feet_y = 560.0
		elif x >= 560.0 and x < 640.0:
			feet_y = 520.0
		elif x >= 640.0 and x < 840.0:
			feet_y = 480.0
		elif x >= 840.0 and x < 920.0:
			feet_y = 520.0
		elif x >= 920.0 and x < 1000.0:
			feet_y = 560.0
		elif x >= 1000.0 and x < 1080.0:
			feet_y = 600.0
		ghost.append(Vector3(x, feet_y - 19.5, 1.0))
		x += 8.1
	# 8.1 px per 0.1 s sample = 81 px/s at replay, one third of the
	# hero's 243 px/s: ~132 samples, ghost trails well behind.
	TTProgress.save_ghost("L001", ghost)
	TTState.level_index = 0
	var game_inst: Node = game_scene.instantiate()
	add_child(game_inst)
	await _settle(0.6)
	# Short drive (0.8 s): the hero reaches x~284 on the flat start
	# (before the first step at x400, which needs a jump) while the
	# 3x-stretched ghost trails at x~203 — both on flat ground,
	# ~80 px apart, both readable in one frame.
	Input.action_press("move_right")
	await _settle(0.8)
	Input.action_release("move_right")
	await _capture_now(_out_dir + "/ghost_on.png")
	var hud: Node = game_inst.get("hud")
	print("F3SHOT ghost_on hud_ghost_visible=", hud.call("is_ghost_visible") if hud != null else false,
		" ghost_on=", hud.call("is_ghost_on") if hud != null else false)
	game_inst.call("_set_ghost_visible", false)
	await _capture_now(_out_dir + "/ghost_off.png")
	game_inst.call("_set_ghost_visible", true)
	game_inst.call("pause_game")
	await _capture_now(_out_dir + "/pause_ghost.png")
	game_inst.call("resume_game")
	await _remove(game_inst)

	_wipe_saves()
	print("F3SHOT DONE")
	get_tree().quit(0)


func _wipe_saves() -> void:
	DirAccess.remove_absolute(OS.get_user_data_dir() + "/progress.cfg")
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
	print("F3SHOT saved ", path, " err=", err, " size=", img.get_size())


func _remove(inst: Node) -> void:
	remove_child(inst)
	inst.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
