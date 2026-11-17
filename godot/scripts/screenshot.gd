extends Node

# Screenshot capture ONLY: renders REAL frames of the built game through
# the real game/menu/level-select scenes (real builder, HUD, controls).
# Never draws mockups. No gameplay code is touched.
# Run under Xvfb with a real rendering driver (NOT --headless):
#   xvfb-run -a <godot> --path <project> res://scenes/screenshot.tscn -- \
#     --shot-levels L012,L032,L022,L008 --shot-out <dir>
# Defaults: levels L012,L032,L022,L008; out dir
# $HOME/workspace/trap-tower/verification/shots. Also always captures
# menu.png and level_select.png.

var _out_dir := ""
var _level_ids: Array[String] = []


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
	if levels_arg == "":
		levels_arg = "L012,L032,L022,L008"
	for part in levels_arg.split(","):
		var id := part.strip_edges()
		if id != "":
			_level_ids.append(id)
	if out_arg == "":
		_out_dir = OS.get_environment("HOME") + "/workspace/trap-tower/verification/shots"
	else:
		_out_dir = out_arg
	var derr := DirAccess.make_dir_recursive_absolute(_out_dir)
	if derr != OK:
		print("SHOT ERROR: cannot create out dir ", _out_dir, " err=", derr)
		get_tree().quit(1)
		return
	print("SHOT viewport=", get_viewport().get_visible_rect().size, " out=", _out_dir, " levels=", _level_ids)

	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("SHOT ERROR: ", str(loaded["error"]))
		get_tree().quit(1)
		return
	var levels: Array = loaded["levels"]
	var index_by_id := {}
	for idx in range(levels.size()):
		index_by_id[str(levels[idx].get("id", ""))] = idx
	for id in _level_ids:
		if not index_by_id.has(id):
			print("SHOT ERROR: unknown level id ", id)
			get_tree().quit(1)
			return

	var game_scene: PackedScene = load("res://scenes/game.tscn")
	for id in _level_ids:
		TTState.level_index = int(index_by_id[id])
		var inst: Node = game_scene.instantiate()
		add_child(inst)
		await _settle_and_capture(_out_dir + "/level_" + id + ".png")
		_remove(inst)

	var menu_scene: PackedScene = load("res://scenes/menu.tscn")
	var menu_inst: Node = menu_scene.instantiate()
	add_child(menu_inst)
	await _settle_and_capture(_out_dir + "/menu.png")
	_remove(menu_inst)

	var select_scene: PackedScene = load("res://scenes/level_select.tscn")
	var select_inst: Node = select_scene.instantiate()
	add_child(select_inst)
	await _settle_and_capture(_out_dir + "/level_select.png")
	_remove(select_inst)

	print("SHOT DONE")
	get_tree().quit(0)


func _settle_and_capture(path: String) -> void:
	# ~1.0s of physics/render frames so traps settle into a
	# representative pose, then capture after a drawn frame.
	await get_tree().create_timer(1.0).timeout
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
