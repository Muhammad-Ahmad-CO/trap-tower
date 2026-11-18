extends Node2D

# Game scene (res://scenes/game.tscn). Loads levels.json in normal play;
# build_level(level_dict, tuning_dict) builds one given level directly
# (verifier entry point). Death/win rules live in the built TTRuntime;
# this node mirrors deaths / level_completed, polls the touch controls
# into the player, drives the HUD, shows the death-retry prompt and the
# pause overlay, handles skip/restart, and advances on win (short delay
# so the win is observable before the next level builds).
#
# Frozen contracts kept here: N3 stale-build guard (clear ALL children
# BEFORE validation); deaths mirrored every physics frame including the
# dead state; pause contract (HUD + overlay ALWAYS, everything else
# INHERIT, paused=false on every exit path); touch controls forced to
# PROCESS_MODE_ALWAYS so finger tracking stays correct across pause.

# Pause overlay root: PROCESS_MODE_ALWAYS, so it still receives _input
# while the tree is paused and ESC can exit to the map from pause.
# (The game node's own _input is gated while paused.) It only acts
# while visible, so it never double-fires with game _input.
class PauseOverlay extends Control:
	signal esc_pressed

	func _input(event: InputEvent) -> void:
		if not visible:
			return
		if event is InputEventKey:
			var key := event as InputEventKey
			if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
				esc_pressed.emit()


var tuning: Dictionary = {}
var levels: Array = []
var level_index := 0
var current_level: Dictionary = {}
var builder: TTBuilder = null
var runtime: TTRuntime = null
var player: TTPlayer = null
var hud: TTHUD = null
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
var _last_deaths := 0
var _paused := false
var _pause_overlay: Control = null
var _death_label: Label = null


func _ready() -> void:
	TTAudio.ensure_audio(get_tree())
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
	tuning = p_tuning
	# N3 STALE-BUILD GUARD: clear ALL children BEFORE validation, and
	# drop every stale node ref, so a validation failure leaves an
	# empty tree (no stale player for the autopilot to find).
	for child in get_children():
		remove_child(child)
		child.queue_free()
	builder = null
	runtime = null
	player = null
	hud = null
	controls = null
	_pause_overlay = null
	_death_label = null
	_paused = false
	var err := TTLevelData.validate_level(level, index, p_tuning)
	if err != "":
		_show_error("level " + str(level.get("id", "?")) + ": " + err)
		return
	_error = false
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
	hud = TTHUD.new()
	hud.setup(pal, _block_filled())
	hud.pause_pressed.connect(_on_pause_button)
	hud.restart_pressed.connect(restart_level)
	hud.skip_pressed.connect(_on_skip_pressed)
	add_child(hud)
	var controls_scene: PackedScene = load("res://scenes/touch_controls.tscn")
	controls = controls_scene.instantiate() as TTTouchControls
	controls.setup(p_tuning, pal)
	# Pause contract: finger tracking must stay correct across pause.
	controls.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(controls)
	_build_death_label()
	_build_pause_overlay(pal)
	deaths = 0
	_last_deaths = 0
	level_completed = false
	touch_left = false
	touch_right = false
	touch_jump = false
	_win_delay = -1.0
	_win_saved = false


func _build_death_label() -> void:
	_death_label = Label.new()
	_death_label.text = "TAP TO RETRY"
	_death_label.position = Vector2(0, 190)
	_death_label.size = Vector2(1280, 60)
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.add_theme_font_size_override("font_size", 44)
	_death_label.add_theme_color_override("font_color", Color.html("FFD23F"))
	_death_label.add_theme_color_override("font_outline_color", Color.html("0A1F44"))
	_death_label.add_theme_constant_override("outline_size", 8)
	_death_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Above level art, below the pause overlay (90) and HUD (100):
	# upper third, never overlapping the HUD buttons at y 16..64.
	_death_label.z_index = 80
	_death_label.visible = false
	add_child(_death_label)


func _build_pause_overlay(pal: Dictionary) -> void:
	var trap_col := TTuning.col(str(pal.get("trap", "#2B0A8A")))
	var bg_col := TTuning.col(str(pal.get("bg", "#E8871E")))
	var overlay := PauseOverlay.new()
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	overlay.position = Vector2.ZERO
	overlay.size = Vector2(1280, 720)
	overlay.visible = false
	overlay.esc_pressed.connect(_exit_to_map)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	var panel := Panel.new()
	panel.position = Vector2(360, 230)
	panel.size = Vector2(560, 260)
	var psb := StyleBoxFlat.new()
	psb.bg_color = bg_col.lightened(0.45)
	psb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", psb)
	overlay.add_child(panel)
	var icons: Array[String] = ["exit", "restart", "play"]
	for i in range(3):
		var b := TTHUD.IconButton.new()
		b.icon = icons[i]
		b.fill = trap_col
		b.icon_col = Color.html("FFD23F")
		b.position = Vector2(456 + i * 136, 312)
		b.size = Vector2(96, 96)
		b.corner_radius = 16
		overlay.add_child(b)
		if i == 0:
			b.pressed.connect(_exit_to_map)
		elif i == 1:
			b.pressed.connect(restart_level)
		else:
			b.pressed.connect(resume_game)
	# Below the HUD (100) so the HUD stays visible over the panel.
	overlay.z_index = 90
	add_child(overlay)
	_pause_overlay = overlay


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
	# Mirrored EVERY physics frame, including the dead state.
	deaths = runtime.deaths
	level_completed = runtime.level_completed
	if deaths > _last_deaths:
		_last_deaths = deaths
		TTAudio.play_death()
	if _death_label != null and is_instance_valid(_death_label):
		_death_label.visible = runtime.dead
	if hud != null and is_instance_valid(hud):
		hud.set_deaths(deaths)
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
		TTAudio.play_win()
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
	get_tree().paused = false
	_paused = false
	if level_index + 1 >= levels.size():
		get_tree().change_scene_to_file("res://scenes/map.tscn")
	else:
		level_index += 1
		TTState.level_index = level_index
		_build_from_dict(levels[level_index], tuning, level_index)


func pause_game() -> void:
	if _error or _paused:
		return
	_paused = true
	if _pause_overlay != null:
		_pause_overlay.visible = true
	get_tree().paused = true


func resume_game() -> void:
	if not _paused:
		return
	_paused = false
	if _pause_overlay != null:
		_pause_overlay.visible = false
	get_tree().paused = false


func restart_level() -> void:
	get_tree().paused = false
	_paused = false
	if _pause_overlay != null:
		_pause_overlay.visible = false
	if levels.is_empty():
		if current_level.is_empty():
			return
		_build_from_dict(current_level, tuning, 0)
	else:
		_build_from_dict(levels[level_index], tuning, level_index)


func _on_pause_button() -> void:
	if _paused:
		resume_game()
	else:
		pause_game()


func _on_skip_pressed() -> void:
	if levels.is_empty() or _win_saved or _win_delay >= 0.0:
		return
	if deaths < 3:
		return
	# Unpause first: _process (which advances) is frozen while paused.
	resume_game()
	# Skip unlocks the next stage WITHOUT marking this one complete
	# and WITHOUT the win sound, then advances like a win.
	TTProgress.unlock_level(level_index, levels.size())
	_win_saved = true
	_win_delay = 0.3


func _exit_to_map() -> void:
	get_tree().paused = false
	_paused = false
	get_tree().change_scene_to_file("res://scenes/map.tscn")


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
			_exit_to_map()
