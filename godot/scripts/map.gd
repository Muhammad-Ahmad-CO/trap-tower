extends Control

# World map: the START screen (no separate title screen). Code-drawn
# island map in flat palette-0 colours: door arches along a winding
# dotted snake path, the current door glowing with a small triangle
# marker above it, locked doors dimmed + unclickable. Door tap opens a
# 5-stage picker; the PLAY badge on the current door starts its first
# incomplete stage (else stage 1). Settings wrench top-right.
# Behaviour follows the Level Devil study; all art here is original
# (our colours, our door shape, our layout) — nothing is copied.
# Door count derives from levels.json (ceil(total / 5)); the map is
# taller than 720, so it lives in a vertical ScrollContainer.
# open_picker(door) / open_settings() are public: the screenshot tool
# drives these real paths. Audio settings are applied and music is
# started in _ready.

const COLS := 6
const ROW_H := 170.0
const DOOR_W := 130.0
const DOOR_H := 170.0
const GRID_X0 := 60.0
const GRID_DX := 206.0
const GRID_Y0 := 60.0


# One door arch on the map. Release-activated (see IconButton note):
# the press is never accepted, so a drag still scrolls the map.
class DoorButton extends Control:
	signal pressed
	signal play_pressed

	var door := 0
	var locked := false
	var current := false
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

	func badge_rect() -> Rect2:
		return Rect2(Vector2(size.x - 50.0, 2.0), Vector2(46, 46))

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_inside = true
				_press_pos = event.position
			else:
				var fire: bool = _press_inside and Rect2(Vector2.ZERO, size).has_point(event.position) and event.position.distance_to(_press_pos) <= 16.0
				_press_inside = false
				if fire and not locked:
					if current and badge_rect().has_point(event.position):
						play_pressed.emit()
					else:
						pressed.emit()

	func _draw() -> void:
		var cx := size.x * 0.5
		if current:
			draw_circle(Vector2(cx, 92), 92.0, glow_col)
			var tri := PackedVector2Array([Vector2(cx - 14, 2), Vector2(cx + 14, 2), Vector2(cx, 22)])
			draw_colored_polygon(tri, marker_col)
		var aw := 84.0
		var ah := 112.0
		var ax := cx - aw * 0.5
		var ay := 40.0
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
		draw_string(font, Vector2(0, ay + 78.0), str(door + 1), HORIZONTAL_ALIGNMENT_CENTER, size.x, 34, number_col)
		if current:
			var b := badge_rect()
			draw_circle(b.get_center(), 21.0, marker_col)
			var bc := b.get_center()
			var play := PackedVector2Array([
				Vector2(bc.x - 6, bc.y - 10),
				Vector2(bc.x - 6, bc.y + 10),
				Vector2(bc.x + 11, bc.y),
			])
			draw_colored_polygon(play, fill)


# Island blob + dotted path behind the doors. Never interactive.
class MapArt extends Control:
	var island_col := Color.html("E8871E")
	var dot_col := Color.html("2B0A8A")
	var centres: Array[Vector2] = []
	var content_h := 1600.0

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
var _doors := 0
var _highest := 0
var _completed: Array = []
var _bg_col := Color.html("E8871E")
var _trap_col := Color.html("2B0A8A")
var _scroll: ScrollContainer = null
var _content_h := 1600.0
var _current_door := 0
var _picker: Control = null
var _picker_title: Label = null
var _picker_stages: Control = null
var _picker_door := -1
var _settings: Control = null
var _sound_btn: Button = null
var _music_slider: HSlider = null


func _ready() -> void:
	TTAudio.ensure_audio(get_tree())
	var tuning := TTuning.load_tuning()
	var pal: Dictionary = TTuning.palette(tuning, 0)
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
		_build_picker()
		_build_settings()
		return
	_levels = loaded["levels"]
	_total = _levels.size()
	_doors = (_total + 4) / 5
	var progress := TTProgress.load_progress()
	_highest = clampi(int(progress["highest_unlocked"]), 0, maxi(0, _total - 1))
	_completed = progress["completed"]
	# Door unlock derives from highest_unlocked (index), never completed.
	_current_door = _highest / 5
	_build_map()
	_build_picker()
	_build_settings()
	_scroll_to_current()


func _door_pos(door: int) -> Vector2:
	var row := door / COLS
	var slot := door % COLS
	var col := slot if row % 2 == 0 else COLS - 1 - slot
	return Vector2(GRID_X0 + float(col) * GRID_DX, GRID_Y0 + float(row) * ROW_H)


func _build_map() -> void:
	var rows := (_doors + COLS - 1) / COLS
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
	for door in range(_doors):
		centres.append(_door_pos(door) + Vector2(DOOR_W * 0.5, 92.0))
	art.centres = centres
	for door in range(_doors):
		var btn := DoorButton.new()
		btn.door = door
		btn.locked = door * 5 > _highest
		btn.current = door == _current_door
		if btn.locked:
			btn.fill = _trap_col.lerp(_bg_col, 0.45)
			btn.outline_col = Color(1, 1, 1, 0.55)
			btn.number_col = Color(1, 1, 1, 0.6)
		else:
			btn.fill = _trap_col
			btn.outline_col = Color.WHITE
			btn.number_col = Color.WHITE
		btn.position = _door_pos(door)
		btn.size = Vector2(DOOR_W, DOOR_H)
		btn.pressed.connect(_on_door_pressed.bind(door))
		btn.play_pressed.connect(_on_door_play.bind(door))
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
	var y := _door_pos(_current_door).y
	_scroll.scroll_vertical = clampf(y - 180.0, 0.0, maxf(0.0, _content_h - 616.0))


func _build_picker() -> void:
	_picker = Control.new()
	_picker.position = Vector2.ZERO
	_picker.size = Vector2(1280, 720)
	_picker.visible = false
	add_child(_picker)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	_picker.add_child(dim)
	var panel := Panel.new()
	panel.position = Vector2(250, 140)
	panel.size = Vector2(780, 440)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _bg_col.lightened(0.45)
	sb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	_picker.add_child(panel)
	_picker_title = Label.new()
	_picker_title.position = Vector2(250, 162)
	_picker_title.size = Vector2(780, 60)
	_picker_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_picker_title.add_theme_font_size_override("font_size", 44)
	_picker_title.add_theme_color_override("font_color", _trap_col)
	_picker_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_picker.add_child(_picker_title)
	_picker_stages = Control.new()
	_picker_stages.position = Vector2.ZERO
	_picker_stages.size = Vector2(1280, 720)
	_picker_stages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_picker.add_child(_picker_stages)
	var close := _make_text_button("CLOSE", Vector2(530, 472), Vector2(220, 64), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_picker)
	_picker.add_child(close)


func open_picker(door: int) -> void:
	if _picker == null or door < 0 or door >= _doors:
		return
	if door * 5 > _highest:
		return
	_picker_door = door
	_refresh_picker()
	_picker.visible = true


func close_picker() -> void:
	if _picker != null:
		_picker.visible = false


func _refresh_picker() -> void:
	_picker_title.text = "DOOR %d" % (_picker_door + 1)
	for child in _picker_stages.get_children():
		_picker_stages.remove_child(child)
		child.queue_free()
	var stages := mini(5, _total - _picker_door * 5)
	for s in range(stages):
		var idx := _picker_door * 5 + s
		var level: Dictionary = _levels[idx]
		var done := _completed.has(str(level.get("id", "")))
		var unlocked := idx <= _highest
		var is_current := idx == _highest
		var b := Button.new()
		b.text = str(s + 1)
		b.position = Vector2(300 + s * 140, 260)
		b.size = Vector2(120, 120)
		b.add_theme_font_size_override("font_size", 44)
		var cell := StyleBoxFlat.new()
		cell.set_corner_radius_all(16)
		if done:
			cell.bg_color = _trap_col
			b.add_theme_color_override("font_color", Color.WHITE)
		elif unlocked:
			cell.bg_color = Color(1, 1, 1, 0.92)
			b.add_theme_color_override("font_color", _trap_col)
		else:
			cell.bg_color = Color(0, 0, 0, 0.25)
			b.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
			b.disabled = true
		if is_current:
			cell.border_color = Color.html("FFD23F")
			cell.set_border_width_all(5)
		b.add_theme_stylebox_override("normal", cell)
		b.add_theme_stylebox_override("hover", cell)
		b.add_theme_stylebox_override("pressed", cell)
		b.add_theme_stylebox_override("disabled", cell)
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.pressed.connect(_on_stage_pressed.bind(idx))
		_picker_stages.add_child(b)


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


func _on_door_pressed(door: int) -> void:
	open_picker(door)


func _on_door_play(door: int) -> void:
	var start := door * 5
	var stages := mini(5, _total - door * 5)
	for s in range(stages):
		var idx := door * 5 + s
		var level: Dictionary = _levels[idx]
		if idx <= _highest and not _completed.has(str(level.get("id", ""))):
			start = idx
			break
	_start_stage(start)


func _on_stage_pressed(idx: int) -> void:
	_start_stage(idx)


func _start_stage(idx: int) -> void:
	TTState.level_index = idx
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/game.tscn")
