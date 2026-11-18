extends Node

# Screenshot capture ONLY: renders REAL frames through the real
# map/game scenes and real UI paths (picker, settings, pause, death,
# skip). Never draws mockups. No gameplay code is touched.
# Run under Xvfb with a real rendering driver (NOT --headless):
#   xvfb-run -a <godot> --path <project> res://scenes/screenshot.tscn -- \
#     --shot-levels L001,L006,L011 --shot-out <dir>
# Defaults: first stage of doors 1, 2, 3 + 3 more distinct doors,
# selected by door from the shipped file; out dir
# $HOME/workspace/trap-tower/verification/shots. Always captures:
# map.png (fresh progress), map_progress.png (mid-progress fixture),
# picker.png (picker via open_picker), settings.png (settings via
# open_settings), pause.png (pause overlay via the real pause path),
# death.png (REAL hazard death, captured inside the dead state),
# skip.png (3 REAL deaths, then Skip visible), level_<ID>.png for each
# selected level, plus ONE level at a second trap phase
# (level_<ID>_phase2.png, longer settle).
# Progress fixtures are written to user://progress.cfg (save_version 2)
# before map captures; a FRESH empty progress is restored at the end.

var _out_dir := ""
var _level_ids: Array[String] = []
var _levels: Array = []


func _ready() -> void:
	_run()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var levels_arg := ""
	var out_arg := ""
	var i := 0
	while i < args.size():
		if args[i] == "--shot-levels" and i + 1 < args.size():
			levels_arg = args[i + 1]
			i += 2
		elif args[i] == "--shot-out" and i + 1 < args.size():
			out_arg = args[i + 1]
			i += 2
		else:
			i += 1
	if out_arg == "":
		_out_dir = OS.get_environment("HOME") + "/workspace/trap-tower/verification/shots"
	else:
		_out_dir = out_arg
	var derr := DirAccess.make_dir_recursive_absolute(_out_dir)
	if derr != OK:
		print("SHOT ERROR: cannot create out dir ", _out_dir, " err=", derr)
		get_tree().quit(1)
		return

	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("SHOT ERROR: ", str(loaded["error"]))
		get_tree().quit(1)
		return
	_levels = loaded["levels"]
	var index_by_id := {}
	for idx in range(_levels.size()):
		index_by_id[str(_levels[idx].get("id", ""))] = idx
	if levels_arg == "":
		_level_ids = _default_level_ids()
	else:
		for part in levels_arg.split(","):
			var id := part.strip_edges()
			if id != "":
				_level_ids.append(id)
		for id in _level_ids:
			if not index_by_id.has(id):
				print("SHOT ERROR: unknown level id ", id)
				get_tree().quit(1)
				return
	print("SHOT viewport=", get_viewport().get_visible_rect().size, " out=", _out_dir, " levels=", _level_ids)

	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")

	# Map, fresh progress.
	_write_progress(0, [])
	var map_inst: Node = map_scene.instantiate()
	add_child(map_inst)
	await _settle_and_capture(_out_dir + "/map.png", 0.5)
	await _remove(map_inst)

	# Map, mid-progress fixture + picker + settings on one instance.
	var mid := _levels.size() / 2
	var done_ids: Array[String] = []
	for k in range(mini(42, _levels.size())):
		done_ids.append(str(_levels[k].get("id", "")))
	_write_progress(mid, done_ids)
	map_inst = map_scene.instantiate()
	add_child(map_inst)
	await _settle_and_capture(_out_dir + "/map_progress.png", 0.6)
	var doors := (_levels.size() + 4) / 5
	var picker_door := mini(8, doors - 1)
	map_inst.call("open_picker", picker_door)
	await _capture_now(_out_dir + "/picker.png")
	map_inst.call("close_picker")
	map_inst.call("open_settings")
	await _capture_now(_out_dir + "/settings.png")
	map_inst.call("close_settings")
	await _remove(map_inst)

	# Game states: pause, death, skip — one instance, real paths.
	var death_idx := _find_death_level()
	if death_idx < 0:
		print("SHOT ERROR: no level with a directly lethal hazard found")
		get_tree().quit(1)
		return
	TTState.level_index = death_idx
	var game_inst: Node = game_scene.instantiate()
	add_child(game_inst)
	await _settle(0.6)
	game_inst.call("pause_game")
	await _capture_now(_out_dir + "/pause.png")
	game_inst.call("resume_game")
	await _settle(0.2)
	if not await _kill_player(game_inst):
		print("SHOT ERROR: could not force a real hazard death")
		get_tree().quit(1)
		return
	await _capture_now(_out_dir + "/death.png")
	await _wait_retry(game_inst)
	for k in range(2):
		if not await _kill_player(game_inst):
			print("SHOT ERROR: could not force death ", k + 2, " for skip shot")
			get_tree().quit(1)
			return
		await _wait_retry(game_inst)
	await _settle(0.3)
	var hud: Node = game_inst.get("hud")
	print("SHOT skip visible=", hud.call("is_skip_visible"), " deaths=", game_inst.get("deaths"))
	await _capture_now(_out_dir + "/skip.png")
	await _remove(game_inst)

	# Level shots, one instance each.
	for id in _level_ids:
		TTState.level_index = int(index_by_id[id])
		game_inst = game_scene.instantiate()
		add_child(game_inst)
		await _settle_and_capture(_out_dir + "/level_" + id + ".png", 1.0)
		await _remove(game_inst)

	# One level at a second trap phase (different settle time).
	TTState.level_index = int(index_by_id[_level_ids[0]])
	game_inst = game_scene.instantiate()
	add_child(game_inst)
	await _settle_and_capture(_out_dir + "/level_" + _level_ids[0] + "_phase2.png", 2.6)
	await _remove(game_inst)

	# Restore a FRESH empty progress at the end.
	_write_progress(0, [])
	print("SHOT DONE")
	get_tree().quit(0)


func _default_level_ids() -> Array[String]:
	# First stage of doors 1, 2, 3 + 3 more distinct doors spread
	# across the file. Door d's first stage is index d*5.
	var doors := (_levels.size() + 4) / 5
	var picks: Array[int] = []
	for d in [0, 1, 2]:
		if d < doors and not picks.has(d):
			picks.append(d)
	for frac in [0.25, 0.5, 0.98]:
		var d2 := int(float(doors) * frac)
		if d2 < doors and not picks.has(d2):
			picks.append(d2)
	var d3 := 3
	while picks.size() < 6 and d3 < doors:
		if not picks.has(d3):
			picks.append(d3)
		d3 += 1
	var ids: Array[String] = []
	for d in picks:
		ids.append(str(_levels[d * 5].get("id", "")))
	return ids


func _find_death_level() -> int:
	# Prefer a level with a directly lethal hazard: static spikes, a
	# saw, or a spiked column. Hanging pillars (lethal only once
	# dropped) and dotted lines (never lethal) are skipped.
	for pass_no in range(2):
		for idx in range(_levels.size()):
			for h in (_levels[idx] as Dictionary).get("hazards", []):
				var htype := str((h as Dictionary).get("type", ""))
				if htype == "saw" or htype == "spiked_column":
					return idx
				if htype == "spikes" and (pass_no == 1 or not (h as Dictionary).has("period")):
					return idx
	return -1


func _pick_death_target(game_inst: Node) -> Vector2:
	var runtime: Node = game_inst.get("runtime")
	if runtime == null:
		return Vector2.ZERO
	var hazards: Array = runtime.get("hazards")
	var fallback := Vector2.ZERO
	for h in hazards:
		var htype := str(h.get("htype"))
		if htype == "saw":
			return h.call("saw_centre_now")
		if htype == "spiked_column":
			return (h.get("rect") as Rect2).get_center()
		if htype == "spikes" and not bool(h.get("has_period")):
			return (h.get("rect") as Rect2).get_center()
		if fallback == Vector2.ZERO and htype == "spikes":
			fallback = (h.get("rect") as Rect2).get_center()
	return fallback


# Teleport the player onto a real hazard and hold it there until the
# runtime reports dead. Returns false if no death within the budget.
func _kill_player(game_inst: Node) -> bool:
	var player := game_inst.get("player") as Node2D
	var runtime: Node = game_inst.get("runtime")
	if player == null or runtime == null:
		return false
	for attempt in range(2):
		var target := _pick_death_target(game_inst)
		if target == Vector2.ZERO:
			return false
		for f in range(150):
			player.global_position = target
			player.set("velocity", Vector2.ZERO)
			await get_tree().physics_frame
			if bool(runtime.get("dead")):
				return true
	return false


func _wait_retry(game_inst: Node) -> void:
	var runtime: Node = game_inst.get("runtime")
	if runtime == null:
		return
	for f in range(90):
		if not bool(runtime.get("dead")):
			return
		await get_tree().physics_frame


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
	# Capture after a drawn frame, without a long settle: the death
	# shot must land inside the 0.6s dead state.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("SHOT saved ", path, " err=", err, " size=", img.get_size(), " format=", img.get_format())


func _remove(inst: Node) -> void:
	remove_child(inst)
	inst.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
