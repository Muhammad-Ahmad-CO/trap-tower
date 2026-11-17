extends Node2D

# Game scene (res://scenes/game.tscn). Loads levels.json in normal play;
# build_level(level_dict, tuning_dict) builds one given level directly
# (verifier entry point). Death/win rules live in the built TTRuntime;
# this node mirrors deaths / level_completed, polls the touch controls
# into the player, draws the HUD, and advances on win (short delay so
# the win is observable before the next level builds).

var tuning: Dictionary = {}
var levels: Array = []
var level_index := 0
var current_level: Dictionary = {}
var builder: TTBuilder = null
var runtime: TTRuntime = null
var player: TTPlayer = null
var controls: TTTouchControls = null
var spawn_point := Vector2.ZERO
var deaths := 0
var level_completed := false
var touch_left := false
var touch_right := false
var touch_jump := false
var _win_delay := -1.0
var _win_saved := false
var _error := false


func _ready() -> void:
	tuning = TTuning.load_tuning()
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		_show_error(str(loaded["error"]))
		return
	levels = loaded["levels"]
	level_index = clampi(TTState.level_index, 0, levels.size() - 1)
	_build_from_dict(levels[level_index], tuning, level_index)


func build_level(level: Dictionary, p_tuning: Dictionary) -> void:
	tuning = p_tuning
	_build_from_dict(level, tuning, 0)


func _build_from_dict(level: Dictionary, p_tuning: Dictionary, index: int) -> void:
	var err := TTLevelData.validate_level(level, index, p_tuning)
	if err != "":
		_show_error("level " + str(level.get("id", "?")) + ": " + err)
		return
	_error = false
	for child in get_children():
		remove_child(child)
		child.queue_free()
	current_level = level
	builder = TTBuilder.new()
	runtime = builder.build_level(level, p_tuning) as TTRuntime
	var pal: Dictionary = builder.palette
	spawn_point = builder.spawn_point
	var bg := ColorRect.new()
	bg.color = TTuning.col(str(pal.get("bg", "#E8871E")))
	bg.position = Vector2.ZERO
	bg.size = Vector2(1280, 720)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	add_child(runtime)
	player = builder.player
	var hud := TTHUD.new()
	hud.setup(pal, _block_filled())
	add_child(hud)
	var controls_scene: PackedScene = load("res://scenes/touch_controls.tscn")
	controls = controls_scene.instantiate() as TTTouchControls
	controls.setup(p_tuning, pal)
	add_child(controls)
	deaths = 0
	level_completed = false
	touch_left = false
	touch_right = false
	touch_jump = false
	_win_delay = -1.0
	_win_saved = false


func _block_filled() -> int:
	if levels.is_empty():
		return 0
	var progress := TTProgress.load_progress()
	var done: Array = progress["completed"]
	var start := (level_index / 5) * 5
	var count := 0
	for i in range(start, mini(start + 5, levels.size())):
		if done.has(str(levels[i].get("id", ""))):
			count += 1
	return count


func _physics_process(_delta: float) -> void:
	if _error or runtime == null or not is_instance_valid(runtime):
		return
	deaths = runtime.deaths
	level_completed = runtime.level_completed
	if controls != null and player != null and is_instance_valid(player):
		var st := controls.get_input_state()
		touch_left = bool(st["left"])
		touch_right = bool(st["right"])
		touch_jump = bool(st["jump"])
		player.touch_left = touch_left
		player.touch_right = touch_right
		player.touch_jump = touch_jump
	if runtime.level_completed and not _win_saved:
		_win_saved = true
		if not levels.is_empty():
			TTProgress.complete_level(str(current_level.get("id", "")), level_index, levels.size())
			_win_delay = 0.3


func _process(delta: float) -> void:
	if _win_delay < 0.0:
		return
	_win_delay -= delta
	if _win_delay > 0.0:
		return
	_win_delay = -1.0
	if level_index + 1 >= levels.size():
		get_tree().change_scene_to_file("res://scenes/level_select.tscn")
	else:
		level_index += 1
		TTState.level_index = level_index
		_build_from_dict(levels[level_index], tuning, level_index)


func _show_error(msg: String) -> void:
	_error = true
	push_error("Trap Tower: " + msg)
	var label := Label.new()
	label.text = "Level data error:\n" + msg
	label.position = Vector2(80, 200)
	label.size = Vector2(1120, 200)
	label.add_theme_font_size_override("font_size", 32)
	add_child(label)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			get_tree().change_scene_to_file("res://scenes/menu.tscn")
