extends Control

# World map: the START screen (no separate title screen). Code-drawn
# island map in flat palette-0 colours: one small arch node per level
# (215 in shipped order) along a winding dotted snake path, the current
# level glowing with a small triangle marker above it, completed levels
# marked with a check badge, locked levels dimmed + unclickable. Each
# node is filled with its own level's palette trap colour, so archetype
# groups read as colour bands. Tapping an unlocked node plays exactly
# that level; tapping a locked node does nothing. Settings wrench
# top-right; "Made by Ahmed" in the fixed header and at the map bottom.
# Node count derives from levels.json; the map is taller than 720, so it
# lives in a vertical ScrollContainer with a computed content height.
# open_settings() / close_settings() are public: the screenshot tool
# drives these real paths. Audio settings are applied and music is
# started in _ready.

const COLS := 9
const ROW_H := 140.0
const NODE_W := 110.0
const NODE_H := 110.0
const GRID_X0 := 57.0
const GRID_DX := 132.0
const GRID_Y0 := 60.0


# One level node on the map. Release-activated (see IconButton note):
# the press is never accepted, so a drag still scrolls the map.
class LevelNode extends Control:
	signal pressed

	var level := 0
	var locked := false
	var current := false
	var done := false
	var fill := Color(0.17, 0.04, 0.54)
	var outline_col := Color.WHITE
	var number_col := Color.WHITE
	var glow_col := Color(1.0, 0.9, 0.4, 0.28)
	var marker_col := Color.html("FFD23F")
	var _press_pos := Vector2.ZERO
	var _press_inside := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_inside = true
				_press_pos = event.position
			else:
				var fire: bool = _press_inside and Rect2(Vector2.ZERO, size).has_point(event.position) and event.position.distance_to(_press_pos) <= 16.0
				_press_inside = false
				if fire and not locked:
					pressed.emit()

	func _draw() -> void:
		var cx := size.x * 0.5
		if current:
			draw_circle(Vector2(cx, 58), 56.0, glow_col)
			var tri := PackedVector2Array([Vector2(cx - 14, 2), Vector2(cx + 14, 2), Vector2(cx, 20)])
			draw_colored_polygon(tri, marker_col)
		var aw := 76.0
		var ah := 76.0
		var ax := cx - aw * 0.5
		var ay := 28.0
		var rad := aw * 0.5
		var cy := ay + rad
		draw_circle(Vector2(cx, cy), rad, fill)
		draw_rect(Rect2(ax, cy, aw, ah - rad), fill)
		draw_arc(Vector2(cx, cy), rad, PI, TAU, 20, outline_col, 3.0, true)
		draw_line(Vector2(ax, cy), Vector2(ax, ay + ah), outline_col, 3.0, true)
		draw_line(Vector2(ax + aw, cy), Vector2(ax + aw, ay + ah), outline_col, 3.0, true)
		if current:
			draw_arc(Vector2(cx, cy), rad + 3.0, PI, TAU, 20, marker_col, 3.0, true)
		var font := get_theme_default_font()
		draw_string(font, Vector2(0, ay + 49.0), str(level + 1), HORIZONTAL_ALIGNMENT_CENTER, size.x, 30, number_col)
		if done and not locked:
			var bc := Vector2(size.x - 18.0, 18.0)
			draw_circle(bc, 11.0, Color.WHITE)
			draw_line(bc + Vector2(-6, 0), bc + Vector2(-2, 4), fill, 3.0, true)
			draw_line(bc + Vector2(-2, 4), bc + Vector2(6, -5), fill, 3.0, true)


# Island blob + dotted path behind the nodes. Never interactive.
class MapArt extends Control:
	var island_col := Color.html("E8871E")
	var dot_col := Color.html("2B0A8A")
	var centres: Array[Vector2] = []
	var content_h := 3520.0

	func _draw() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = island_col
		sb.set_corner_radius_all(90)
		draw_style_box(sb, Rect2(30, 30, 1220, content_h - 150.0))
		for i in range(centres.size() - 1):
			var a := centres[i]
			var b := centres[i + 1]
			var dist := a.distance_to(b)
			var n := maxi(1, int(dist / 26.0))
			for k in range(n + 1):
				draw_circle(a.lerp(b, float(k) / float(n)), 5.0, dot_col)


var _levels: Array = []
var _total := 0
var _highest := 0
var _completed: Array = []
var _tuning: Dictionary = {}
var _bg_col := Color.html("E8871E")
var _trap_col := Color.html("2B0A8A")
var _scroll: ScrollContainer = null
var _content_h := 3520.0
var _settings: Control = null
var _sound_btn: Button = null
var _music_slider: HSlider = null


func _ready() -> void:
	TTAudio.ensure_audio(get_tree())
	_tuning = TTuning.load_tuning()
	var pal: Dictionary = TTuning.palette(_tuning, 0)
	_bg_col = TTuning.col(str(pal.get("bg", "#E8871E")))
	_trap_col = TTuning.col(str(pal.get("trap", "#2B0A8A")))
	var bg := ColorRect.new()
	bg.color = _trap_col
	bg.position = Vector2.ZERO
	bg.size = Vector2(1280, 720)
	add_child(bg)
	var title := Label.new()
	title.text = "TRAP TOWER"
	title.position = Vector2(0, 16)
	title.size = Vector2(1280, 80)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", _bg_col)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)
	var credit_top := Label.new()
	credit_top.text = "Made by Ahmed"
	credit_top.position = Vector2(0, 80)
	credit_top.size = Vector2(1280, 24)
	credit_top.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	credit_top.add_theme_font_size_override("font_size", 18)
	credit_top.add_theme_color_override("font_color", _bg_col)
	credit_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(credit_top)
	var wrench := TTHUD.IconButton.new()
	wrench.icon = "wrench"
	wrench.fill = _bg_col
	wrench.icon_col = _trap_col
	wrench.position = Vector2(1196, 20)
	wrench.size = Vector2(64, 64)
	wrench.corner_radius = 12
	wrench.pressed.connect(open_settings)
	add_child(wrench)
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		var err := Label.new()
		err.text = "Level data error:\n" + str(loaded["error"])
		err.position = Vector2(80, 200)
		err.size = Vector2(1120, 200)
		err.add_theme_font_size_override("font_size", 32)
		err.add_theme_color_override("font_color", _bg_col)
		add_child(err)
		_build_settings()
		return
	_levels = loaded["levels"]
	_total = _levels.size()
	var progress := TTProgress.load_progress()
	_highest = clampi(int(progress["highest_unlocked"]), 0, maxi(0, _total - 1))
	_completed = progress["completed"]
	# Unlock derives from highest_unlocked (index), never completed.
	_build_map()
	_build_settings()
	_scroll_to_current()


func _node_pos(idx: int) -> Vector2:
	var row := idx / COLS
	var slot := idx % COLS
	var col := slot if row % 2 == 0 else COLS - 1 - slot
	return Vector2(GRID_X0 + float(col) * GRID_DX, GRID_Y0 + float(row) * ROW_H)


func _build_map() -> void:
	var rows := (_total + COLS - 1) / COLS
	_content_h = GRID_Y0 + float(rows) * ROW_H + 100.0
	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(0, 104)
	_scroll.size = Vector2(1280, 616)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	var content := Control.new()
	content.custom_minimum_size = Vector2(1280, _content_h)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(content)
	var art := MapArt.new()
	art.island_col = _bg_col
	art.dot_col = _trap_col
	art.content_h = _content_h
	art.position = Vector2.ZERO
	art.size = Vector2(1280, _content_h)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(art)
	var centres: Array[Vector2] = []
	for idx in range(_total):
		centres.append(_node_pos(idx) + Vector2(NODE_W * 0.5, 62.0))
	art.centres = centres
	for idx in range(_total):
		var level: Dictionary = _levels[idx]
		var pal: Dictionary = TTuning.palette(_tuning, int(level.get("palette", 0)))
		var trap := TTuning.col(str(pal.get("trap", "#2B0A8A")))
		var btn := LevelNode.new()
		btn.level = idx
		btn.locked = idx > _highest
		btn.current = idx == _highest
		btn.done = _completed.has(str(level.get("id", "")))
		if btn.locked:
			btn.fill = trap.lerp(_bg_col, 0.45)
			btn.outline_col = Color(1, 1, 1, 0.55)
			btn.number_col = Color(1, 1, 1, 0.6)
		else:
			btn.fill = trap
			btn.outline_col = Color.WHITE
			btn.number_col = Color.WHITE
		btn.position = _node_pos(idx)
		btn.size = Vector2(NODE_W, NODE_H)
		btn.pressed.connect(_on_level_pressed.bind(idx))
		content.add_child(btn)
	var credit := Label.new()
	credit.text = "Made by Ahmed"
	credit.position = Vector2(0, _content_h - 64)
	credit.size = Vector2(1280, 44)
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	credit.add_theme_font_size_override("font_size", 28)
	credit.add_theme_color_override("font_color", _bg_col)
	credit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(credit)


func _scroll_to_current() -> void:
	if _scroll == null:
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if _scroll == null or not is_instance_valid(_scroll):
		return
	var y := _node_pos(_highest).y
	_scroll.scroll_vertical = clampf(y - 180.0, 0.0, maxf(0.0, _content_h - 616.0))


func _build_settings() -> void:
	_settings = Control.new()
	_settings.position = Vector2.ZERO
	_settings.size = Vector2(1280, 720)
	_settings.visible = false
	add_child(_settings)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	_settings.add_child(dim)
	var panel := Panel.new()
	panel.position = Vector2(290, 160)
	panel.size = Vector2(700, 400)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _bg_col.lightened(0.45)
	sb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	_settings.add_child(panel)
	var title := Label.new()
	title.text = "SETTINGS"
	title.position = Vector2(290, 182)
	title.size = Vector2(700, 56)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", _trap_col)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings.add_child(title)
	var sound_label := Label.new()
	sound_label.text = "SOUND"
	sound_label.position = Vector2(340, 268)
	sound_label.size = Vector2(160, 56)
	sound_label.add_theme_font_size_override("font_size", 32)
	sound_label.add_theme_color_override("font_color", _trap_col)
	sound_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings.add_child(sound_label)
	_sound_btn = _make_text_button("ON", Vector2(700, 262), Vector2(200, 64), 30, _trap_col, Color.WHITE)
	_sound_btn.pressed.connect(_on_sound_toggle)
	_settings.add_child(_sound_btn)
	var music_label := Label.new()
	music_label.text = "MUSIC"
	music_label.position = Vector2(340, 358)
	music_label.size = Vector2(160, 56)
	music_label.add_theme_font_size_override("font_size", 32)
	music_label.add_theme_color_override("font_color", _trap_col)
	music_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings.add_child(music_label)
	_music_slider = HSlider.new()
	_music_slider.position = Vector2(520, 362)
	_music_slider.size = Vector2(380, 48)
	_music_slider.min_value = 0.0
	_music_slider.max_value = 1.0
	_music_slider.step = 0.05
	_music_slider.value = TTAudio.get_music_volume()
	_music_slider.value_changed.connect(_on_music_changed)
	_settings.add_child(_music_slider)
	var close := _make_text_button("CLOSE", Vector2(530, 472), Vector2(220, 64), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_settings)
	_settings.add_child(close)


func open_settings() -> void:
	if _settings == null:
		return
	_sound_btn.text = "ON" if TTAudio.is_sound_enabled() else "OFF"
	_music_slider.value = TTAudio.get_music_volume()
	_settings.visible = true


func close_settings() -> void:
	if _settings != null:
		_settings.visible = false


func _on_sound_toggle() -> void:
	TTAudio.set_sound_enabled(not TTAudio.is_sound_enabled())
	_sound_btn.text = "ON" if TTAudio.is_sound_enabled() else "OFF"


func _on_music_changed(value: float) -> void:
	TTAudio.set_music_volume(value)


func _make_text_button(text: String, pos: Vector2, size: Vector2, font_size: int, fill: Color, font_col: Color) -> Button:
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


func _on_level_pressed(idx: int) -> void:
	if idx < 0 or idx >= _total or idx > _highest:
		return
	_start_level(idx)


func _start_level(idx: int) -> void:
	TTState.level_index = idx
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/game.tscn")
