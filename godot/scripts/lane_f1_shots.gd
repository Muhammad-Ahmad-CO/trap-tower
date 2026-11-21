extends Node

# Lane F1 screenshots ONLY: renders REAL frames through the real
# map/game scenes and real UI paths (skin picker, bonus picker,
# star visible / collected, bonus level, skinned hero). Never draws
# mockups. Run under Xvfb with a real rendering driver (NOT --headless):
#   xvfb-run -a <godot> --path <project> res://scenes/lane_f1_shots.tscn -- \
#     --shot-out <dir>
# Defaults: out dir $HOME/workspace/trap-tower/verification/lane-f1.
# Progress fixtures are written to user://progress.cfg; a FRESH empty
# progress is restored at the end.

var _out_dir := ""
var _levels: Array = []


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
		_out_dir = OS.get_environment("HOME") + "/workspace/trap-tower/verification/lane-f1"
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
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	TTState.return_door = -1
	TTState.bonus = false

	# 1. Map, fresh progress (STARS 0/215, bonus door locked).
	_write_f1_progress(0, [], [], "default")
	var map_inst: Node = map_scene.instantiate()
	add_child(map_inst)
	await _settle_and_capture(_out_dir + "/map_f1_fresh.png", 0.6)
	# Same instance, scrolled to the bottom row: bonus door visible.
	var scroll: ScrollContainer = map_inst.get("_scroll")
	if scroll != null:
		scroll.scroll_vertical = 100000.0
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
	await _capture_now(_out_dir + "/map_f1_bonus_locked.png")
	map_inst.call("open_skin_picker")
	await _settle(0.3)
	await _capture_now(_out_dir + "/map_f1_skins.png")
	map_inst.call("close_skin_picker")
	await _remove(map_inst)

	# 2. Map, 50 stars: bonus door unlocked (bottom row) + its picker.
	var stars50: Array = []
	for k in range(50):
		stars50.append(str(_levels[k].get("id", "")))
	_write_f1_progress(0, [], stars50, "default")
	map_inst = map_scene.instantiate()
	add_child(map_inst)
	await _settle(0.6)
	scroll = map_inst.get("_scroll")
	if scroll != null:
		scroll.scroll_vertical = 100000.0
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
	await _capture_now(_out_dir + "/map_f1_bonus_unlocked.png")
	map_inst.call("open_bonus_picker")
	await _settle(0.3)
	await _capture_now(_out_dir + "/map_f1_bonus_picker.png")
	map_inst.call("close_bonus_picker")
	await _remove(map_inst)

	# 3. Skin picker with progress: 15 doors done + 25 stars, so
	# EMBER / FROST / MINT are owned, GOLD / GHOST still locked.
	var done75: Array = []
	for k in range(75):
		done75.append(str(_levels[k].get("id", "")))
	var stars25: Array = []
	for k in range(25):
		stars25.append(str(_levels[k].get("id", "")))
	_write_f1_progress(74, done75, stars25, "default")
	map_inst = map_scene.instantiate()
	add_child(map_inst)
	await _settle(0.6)
	map_inst.call("open_skin_picker")
	await _settle(0.3)
	await _capture_now(_out_dir + "/map_f1_skins_progress.png")
	await _remove(map_inst)

	# 4. Game L001 at 1.0s: the hidden star is visible in-frame.
	# Fresh progress first: shot 3's fixture already owns L001's
	# star, and _spawn_star correctly hides collected stars.
	_write_f1_progress(0, [], [], "default")
	TTState.bonus = false
	TTState.level_index = 0
	var game_inst: Node = game_scene.instantiate()
	add_child(game_inst)
	await _settle_and_capture(_out_dir + "/level_L001_star.png", 1.0)
	# Same instance: teleport the hero onto the star, wait for the
	# collection, then capture (star gone, hero at the star spot).
	var star: Node = _find_star(game_inst)
	var player: Node = game_inst.get("player")
	if star != null and player != null:
		player.global_position = star.get("centre")
		for f in range(20):
			await get_tree().physics_frame
		print("SHOT star collected=", star.get("collected"))
	await _capture_now(_out_dir + "/level_L001_star_collected.png")
	await _remove(game_inst)

	# 5. Bonus level B001 at 1.0s (star visible too).
	_write_f1_progress(0, [], [], "default")
	TTState.bonus = true
	TTState.level_index = 0
	game_inst = game_scene.instantiate()
	add_child(game_inst)
	await _settle_and_capture(_out_dir + "/bonus_B001.png", 1.0)
	await _remove(game_inst)
	TTState.bonus = false

	# 6. Skinned hero in-game: EMBER selected (5 doors done).
	var done25: Array = []
	for k in range(25):
		done25.append(str(_levels[k].get("id", "")))
	_write_f1_progress(24, done25, [], "ember")
	TTState.bonus = false
	TTState.level_index = 0
	game_inst = game_scene.instantiate()
	add_child(game_inst)
	await _settle_and_capture(_out_dir + "/level_L001_skin_ember.png", 1.0)
	await _remove(game_inst)

	_write_f1_progress(0, [], [], "default")
	print("SHOT F1 DONE")
	get_tree().quit(0)


func _find_star(game_inst: Node) -> Node:
	var all: Array = []
	_traverse(game_inst, all)
	for n in all:
		var scr: Variant = n.get_script()
		if scr != null and scr is GDScript and str(scr.get_global_name()) == "TTStar":
			return n
	return null


func _traverse(node: Node, out: Array) -> void:
	out.append(node)
	for child in node.get_children():
		_traverse(child, out)


func _write_f1_progress(highest: int, completed_ids: Array, stars: Array, skin: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", TTProgress.SAVE_VERSION)
	cfg.set_value("progress", "highest_unlocked", highest)
	cfg.set_value("progress", "completed", completed_ids)
	cfg.set_value("progress", "stars_collected", stars)
	cfg.set_value("progress", "selected_skin", skin)
	cfg.set_value("progress", "bonus_completed", [])
	cfg.set_value("progress", "bonus_highest", 0)
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
	print("SHOT saved ", path, " err=", err, " size=", img.get_size(), " format=", img.get_format())


func _remove(inst: Node) -> void:
	if inst != null and is_instance_valid(inst):
		remove_child(inst)
		inst.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
