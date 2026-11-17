extends Control

# Menu: title, Play (highest unlocked level), level-select entry,
# "Made by Ahmed" credit. Flat colours from palette 0, default font only.

func _ready() -> void:
	var tuning := TTuning.load_tuning()
	var pal: Dictionary = TTuning.palette(tuning, 0)
	var bg_col := TTuning.col(str(pal.get("bg", "#E8871E")))
	var trap_col := TTuning.col(str(pal.get("trap", "#2B0A8A")))
	var bg := ColorRect.new()
	bg.color = bg_col
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var title := Label.new()
	title.text = "TRAP TOWER"
	title.position = Vector2(0, 130)
	title.size = Vector2(1280, 130)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 110)
	title.add_theme_color_override("font_color", trap_col)
	add_child(title)
	var play := _make_button("PLAY", trap_col, Color.WHITE, Vector2(460, 330), Vector2(360, 90), 44)
	play.pressed.connect(_on_play)
	add_child(play)
	var levels_btn := _make_button("LEVELS", trap_col, Color.WHITE, Vector2(460, 450), Vector2(360, 90), 44)
	levels_btn.pressed.connect(_on_levels)
	add_child(levels_btn)
	var credit := Label.new()
	credit.text = "Made by Ahmed"
	credit.position = Vector2(0, 620)
	credit.size = Vector2(1280, 50)
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	credit.add_theme_font_size_override("font_size", 30)
	credit.add_theme_color_override("font_color", trap_col)
	add_child(credit)


func _make_button(text: String, fill: Color, font_col: Color, pos: Vector2, size: Vector2, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = size
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", font_col)
	b.add_theme_color_override("font_pressed_color", font_col)
	b.add_theme_color_override("font_hover_color", font_col)
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(14)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


func _on_play() -> void:
	var progress := TTProgress.load_progress()
	var loaded := TTLevelData.load_levels()
	var total := (loaded["levels"] as Array).size()
	if total <= 0:
		return
	TTState.level_index = clampi(int(progress["highest_unlocked"]), 0, total - 1)
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_levels() -> void:
	get_tree().change_scene_to_file("res://scenes/level_select.tscn")
