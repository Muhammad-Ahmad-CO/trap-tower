extends Control

# Level select: minimal scrollable grid of numbers only (no stars, no
# clutter). Locked levels dimmed + disabled. Completed levels filled.

func _ready() -> void:
	var tuning := TTuning.load_tuning()
	var pal: Dictionary = TTuning.palette(tuning, 0)
	var bg_col := TTuning.col(str(pal.get("bg", "#E8871E")))
	var trap_col := TTuning.col(str(pal.get("trap", "#2B0A8A")))
	var bg := ColorRect.new()
	bg.color = bg_col
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		var err := Label.new()
		err.text = "Level data error:\n" + str(loaded["error"])
		err.position = Vector2(80, 200)
		err.size = Vector2(1120, 200)
		err.add_theme_font_size_override("font_size", 32)
		add_child(err)
		return
	var levels: Array = loaded["levels"]
	var progress := TTProgress.load_progress()
	var unlocked: int = int(progress["highest_unlocked"])
	var done: Array = progress["completed"]
	var back := Button.new()
	back.text = "Back"
	back.position = Vector2(40, 24)
	back.size = Vector2(180, 64)
	back.add_theme_font_size_override("font_size", 32)
	var sb := StyleBoxFlat.new()
	sb.bg_color = trap_col
	sb.set_corner_radius_all(12)
	back.add_theme_stylebox_override("normal", sb)
	back.add_theme_stylebox_override("hover", sb)
	back.add_theme_stylebox_override("pressed", sb)
	back.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	back.add_theme_color_override("font_color", Color.WHITE)
	back.add_theme_color_override("font_hover_color", Color.WHITE)
	back.add_theme_color_override("font_pressed_color", Color.WHITE)
	back.pressed.connect(_on_back)
	add_child(back)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(190, 110)
	scroll.size = Vector2(900, 590)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 18)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for i in range(levels.size()):
		var level: Dictionary = levels[i]
		var b := Button.new()
		b.text = str(i + 1)
		b.custom_minimum_size = Vector2(160, 90)
		b.add_theme_font_size_override("font_size", 36)
		var cell := StyleBoxFlat.new()
		cell.set_corner_radius_all(12)
		if i <= unlocked and done.has(str(level.get("id", ""))):
			cell.bg_color = trap_col
			b.add_theme_color_override("font_color", Color.WHITE)
		elif i <= unlocked:
			cell.bg_color = Color(1, 1, 1, 0.85)
			b.add_theme_color_override("font_color", trap_col)
		else:
			cell.bg_color = Color(0, 0, 0, 0.25)
			b.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
			b.disabled = true
		b.add_theme_stylebox_override("normal", cell)
		b.add_theme_stylebox_override("hover", cell)
		b.add_theme_stylebox_override("pressed", cell)
		b.add_theme_stylebox_override("disabled", cell)
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.pressed.connect(_on_level_pressed.bind(i))
		grid.add_child(b)


func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _on_level_pressed(idx: int) -> void:
	TTState.level_index = idx
	get_tree().change_scene_to_file("res://scenes/game.tscn")
