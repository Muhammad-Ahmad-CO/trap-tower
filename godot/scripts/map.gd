extends Control

# World map: the START screen (no separate title screen). ONE organic
# island silhouette (original shape/colours) with ONE winding trail;
# all 215 level nodes sit ON the trail in shipped order (scrollable
# vertically, snake-like but organic — varying x, no rigid grid),
# joined by thin crack-style path lines; the current node glows with a
# triangle marker; completed nodes show a check; locked nodes are
# dimmed + show a lock + are unclickable. Tapping a node plays exactly
# that level. There is NO door picker. Unlock derives from the highest
# unlocked level index, never from the completed-ID set. Big chunky
# pixel-font "TRAP TOWER" title + "Made by Ahmed" visible on first
# view; settings wrench top-right. Settings (sound toggle + music
# volume + close) live on the map screen only. Subtle idle animation:
# the current node's glow pulses, its triangle marker bobs, and a soft
# ring breathes around it. Audio settings are applied and music is
# started in _ready.

const NODES_PER_ROW := 9
const ROW_H := 140.0
const NODE_W := 110.0
const NODE_H := 110.0
const GRID_Y0 := 60.0


# Deterministic per-index jitter in [-1, 1] (same every run, no RNG
# state): breaks the rigid grid so the trail reads organic.
static func _jitter(idx: int, salt: float) -> float:
	var v := sin(float(idx) * 12.9898 + salt * 78.233) * 43758.5453
	return v - floor(v)


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
	var _pulse_t := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		set_process(current)

	func _process(delta: float) -> void:
		if not current:
			set_process(false)
			return
		# Idle animation: glow pulse + triangle bob (current node only).
		_pulse_t += delta
		queue_redraw()

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
			var pulse := 0.20 + 0.10 * sin(_pulse_t * 3.0)
			var gc := glow_col
			gc.a = pulse
			draw_circle(Vector2(cx, 58), 56.0, gc)
			var bob := sin(_pulse_t * 3.0) * 3.0
			var tri := PackedVector2Array([Vector2(cx - 14, 2 + bob), Vector2(cx + 14, 2 + bob), Vector2(cx, 20 + bob)])
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
		# Pixel-font node number, centred in the arch (upper half, so
		# the lock below never overlaps it).
		TTPixelFont.draw_text(self, str(level + 1), Vector2(0, ay + 30.0), 4, number_col, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		if locked:
			# Small padlock at the foot of the arch: shackle arc +
			# body, in the dimmed number colour.
			var lock_c := Vector2(cx, ay + ah - 12.0)
			draw_arc(lock_c, 5.5, PI, TAU, 12, number_col, 3.0, true)
			draw_rect(Rect2(lock_c.x - 8, lock_c.y, 16, 12), number_col)
		elif done:
			var bc := Vector2(size.x - 18.0, 18.0)
			draw_circle(bc, 11.0, Color.WHITE)
			draw_line(bc + Vector2(-6, 0), bc + Vector2(-2, 4), fill, 3.0, true)
			draw_line(bc + Vector2(-2, 4), bc + Vector2(6, -5), fill, 3.0, true)


# Organic island + crack path behind the nodes. Never interactive.
# The island is ONE smooth blob polygon: per row, the node x-range
# widened by a wobbly margin, capped top and bottom — so navy
# background stays visible around it and the silhouette reads
# organic, never a full-bleed rectangle. A darker rim outlines it.
# The trail is a thin crack-style jagged line joining consecutive
# node centres.
class MapArt extends Control:
	var island_col := Color.html("E8871E")
	var island_edge_col := Color.html("E8871E").darkened(0.25)
	var dot_col := Color.html("2B0A8A")
	var ring_col := Color(1.0, 0.824, 0.247, 0.5)
	var centres: Array[Vector2] = []
	var nodes_per_row := 9
	var current_centre := Vector2.ZERO
	var content_h := 3520.0
	var _t := 0.0

	func _process(delta: float) -> void:
		# Subtle idle animation: a soft ring breathes around the
		# current node. One redraw per frame for the whole island.
		_t += delta
		queue_redraw()

	func _island_polygon() -> PackedVector2Array:
		if centres.is_empty():
			return PackedVector2Array()
		var rows := (centres.size() + nodes_per_row - 1) / nodes_per_row
		var left_pts: Array[Vector2] = []
		var right_pts: Array[Vector2] = []
		for r in range(rows):
			var lo := r * nodes_per_row
			var hi := mini(lo + nodes_per_row, centres.size())
			var min_x := 1e9
			var max_x := -1e9
			var cy := 0.0
			for k in range(lo, hi):
				min_x = minf(min_x, centres[k].x)
				max_x = maxf(max_x, centres[k].x)
				cy = centres[k].y
			var wob := sin(float(r) * 1.7) * 26.0
			left_pts.append(Vector2(min_x - 105.0 + wob, cy))
			right_pts.append(Vector2(max_x + 105.0 - wob, cy))
		var poly := PackedVector2Array()
		# Top cap: above the first row, spanning the row width.
		var top_y: float = left_pts[0].y - 120.0
		poly.append(Vector2((left_pts[0].x + right_pts[0].x) * 0.5 - 260.0, top_y + 40.0))
		poly.append(Vector2((left_pts[0].x + right_pts[0].x) * 0.5 + 260.0, top_y + 40.0))
		for p in right_pts:
			poly.append(p)
		# Bottom cap: below the last row.
		var bot_y: float = left_pts[left_pts.size() - 1].y + 120.0
		poly.append(Vector2((left_pts[left_pts.size() - 1].x + right_pts[right_pts.size() - 1].x) * 0.5 + 240.0, bot_y - 40.0))
		poly.append(Vector2((left_pts[left_pts.size() - 1].x + right_pts[right_pts.size() - 1].x) * 0.5 - 240.0, bot_y - 40.0))
		for i in range(left_pts.size() - 1, -1, -1):
			poly.append(left_pts[i])
		return poly

	func _draw() -> void:
		var poly := _island_polygon()
		if poly.size() >= 3:
			# Darker rim first (thick outline), then the island fill:
			# the rim shows as a ~7px edge around the blob.
			var closed := poly + PackedVector2Array([poly[0]])
			draw_polyline(closed, island_edge_col, 14.0, true)
			draw_colored_polygon(poly, island_col)
		# Crack-style path: jagged two-segment line between nodes.
		for i in range(centres.size() - 1):
			var a := centres[i]
			var b := centres[i + 1]
			var mid3 := a.lerp(b, 0.5)
			var perp := (b - a).orthogonal().normalized()
			var j := (sin(float(i) * 7.13) * 0.5) * 14.0
			mid3 += perp * j
			draw_line(a, mid3, dot_col, 3.0, true)
			draw_line(mid3, b, dot_col, 3.0, true)
		# Breathing ring around the current node.
		if current_centre != Vector2.ZERO:
			var r := 66.0 + 5.0 * sin(_t * 2.0)
			var rc := ring_col
			rc.a = 0.35 + 0.15 * sin(_t * 2.0)
			draw_arc(current_centre, r, 0, TAU, 40, rc, 3.0, true)


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
var _sound_btn: TTHUD.IconButton = null
var _music_slider: HSlider = null
var _wipe: TTWipe = null


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
	var title := TTPixelLabel.new()
	title.text = "TRAP TOWER"
	title.pixel_size = 9
	title.color = _bg_col
	title.align = HORIZONTAL_ALIGNMENT_CENTER
	title.width = 1280.0
	title.position = Vector2(0, 16)
	add_child(title)
	var credit_top := TTPixelLabel.new()
	credit_top.text = "Made by Ahmed"
	credit_top.pixel_size = 3
	credit_top.color = _bg_col
	credit_top.align = HORIZONTAL_ALIGNMENT_CENTER
	credit_top.width = 1280.0
	credit_top.position = Vector2(0, 84)
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
		var err := TTPixelLabel.new()
		err.text = "Level data error"
		err.pixel_size = 5
		err.color = _bg_col
		err.position = Vector2(80, 200)
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
	# Original wipe reveal on entering the map.
	_wipe = TTWipe.new()
	add_child(_wipe)
	_wipe.reveal()


func _node_pos(idx: int) -> Vector2:
	# Snake rows (9 per row, direction alternates), but every node's
	# x/y carries deterministic jitter so the trail winds organically
	# instead of sitting on a rigid grid.
	var row := idx / NODES_PER_ROW
	var slot := idx % NODES_PER_ROW
	var col := slot if row % 2 == 0 else NODES_PER_ROW - 1 - slot
	var base_x := 57.0 + float(col) * 132.0
	var jx := (_jitter(idx, 1.0) - 0.5) * 56.0
	var jy := (_jitter(idx, 2.0) - 0.5) * 22.0
	var x := clampf(base_x + jx, 20.0, 1280.0 - NODE_W - 20.0)
	var y := GRID_Y0 + float(row) * ROW_H + jy
	return Vector2(x, y)


func _build_map() -> void:
	var rows := (_total + NODES_PER_ROW - 1) / NODES_PER_ROW
	_content_h = GRID_Y0 + float(rows) * ROW_H + 100.0
	_scroll = ScrollContainer.new()
	# Scroll viewport starts BELOW the header credit (credit_top
	# glyphs end at y=105): was y=104, so the island's top edge
	# clipped the bottom 1-2px rows of "Made by Ahmed" on any
	# scrolled map (seen in screenshots-final map_progress /
	# map_scrolled). 112 clears it by 7px.
	_scroll.position = Vector2(0, 112)
	_scroll.size = Vector2(1280, 608)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	var content := Control.new()
	content.custom_minimum_size = Vector2(1280, _content_h)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(content)
	var art := MapArt.new()
	art.island_col = _bg_col
	art.island_edge_col = _bg_col.darkened(0.25)
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
	art.current_centre = centres[_highest] if not centres.is_empty() else Vector2.ZERO
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
	var credit := TTPixelLabel.new()
	credit.text = "Made by Ahmed"
	credit.pixel_size = 4
	credit.color = _bg_col
	credit.align = HORIZONTAL_ALIGNMENT_CENTER
	credit.width = 1280.0
	credit.position = Vector2(0, _content_h - 64)
	content.add_child(credit)


func _scroll_to_current() -> void:
	if _scroll == null:
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if _scroll == null or not is_instance_valid(_scroll):
		return
	var y := _node_pos(_highest).y
	_scroll.scroll_vertical = clampf(y - 180.0, 0.0, maxf(0.0, _content_h - 608.0))


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
	var title := TTPixelLabel.new()
	title.text = "SETTINGS"
	title.pixel_size = 6
	title.color = _trap_col
	title.align = HORIZONTAL_ALIGNMENT_CENTER
	title.width = 700.0
	title.position = Vector2(290, 182)
	_settings.add_child(title)
	var sound_label := TTPixelLabel.new()
	sound_label.text = "SOUND"
	sound_label.pixel_size = 5
	sound_label.color = _trap_col
	sound_label.position = Vector2(340, 276)
	_settings.add_child(sound_label)
	_sound_btn = _make_text_button("ON", Vector2(700, 262), Vector2(200, 64), 30, _trap_col, Color.WHITE)
	_sound_btn.pressed.connect(_on_sound_toggle)
	_settings.add_child(_sound_btn)
	var music_label := TTPixelLabel.new()
	music_label.text = "MUSIC"
	music_label.pixel_size = 5
	music_label.color = _trap_col
	music_label.position = Vector2(340, 366)
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
	_sound_btn.queue_redraw()
	_music_slider.value = TTAudio.get_music_volume()
	_settings.visible = true


func close_settings() -> void:
	if _settings != null:
		_settings.visible = false


func _on_sound_toggle() -> void:
	TTAudio.set_sound_enabled(not TTAudio.is_sound_enabled())
	_sound_btn.text = "ON" if TTAudio.is_sound_enabled() else "OFF"
	_sound_btn.queue_redraw()


func _on_music_changed(value: float) -> void:
	TTAudio.set_music_volume(value)


func _make_text_button(text: String, pos: Vector2, size: Vector2, font_size: int, fill: Color, font_col: Color) -> TTHUD.IconButton:
	var b := TTHUD.IconButton.new()
	b.text = text
	b.position = pos
	b.size = size
	b.font_size = font_size
	b.fill = fill
	b.icon_col = font_col
	b.corner_radius = 14
	return b


func _on_level_pressed(idx: int) -> void:
	if idx < 0 or idx >= _total or idx > _highest:
		return
	_start_level(idx)


func _start_level(idx: int) -> void:
	TTState.level_index = idx
	get_tree().paused = false
	# Original wipe covers the map -> level transition.
	if _wipe != null:
		await _wipe.cover()
	get_tree().change_scene_to_file("res://scenes/game.tscn")
