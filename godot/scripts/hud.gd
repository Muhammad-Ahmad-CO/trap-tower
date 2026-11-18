class_name TTHUD
extends Node2D

# In-game HUD. Top-centre: the level indicator, text "LEVEL N"
# (1-based; the game passes the level number at setup). Top-left: pause +
# restart icon buttons. Top-right: "SKIP >>", visible ONLY when deaths
# in the current level reach 3 (game pushes deaths per frame; the HUD
# owns no save state). HUD buttons live at y 16..64, far above the
# control bar (y 580..720), so hit-testing never double-fires with it.
# The HUD root is PROCESS_MODE_ALWAYS so its buttons stay clickable
# while the tree is paused; children inherit that mode.

signal pause_pressed
signal restart_pressed
signal skip_pressed


# One small reusable icon/text button. Code-drawn (no text needed for
# icons; `text` draws a centred label instead of an icon). Used by the
# HUD, the pause panel (game.gd) and the map wrench (map.gd) via
# TTHUD.IconButton. Press-mode (default): fires on press. Release-mode
# (activate_on_release, for buttons inside a ScrollContainer): fires on
# release inside the rect after a press that did not drag, and never
# accepts the press event so the scroll container can still scroll.
class IconButton extends Control:
	signal pressed

	var icon := ""
	var text := ""
	var fill := Color(0.17, 0.04, 0.54)
	var icon_col := Color.WHITE
	var font_size := 30
	var corner_radius := 10
	var activate_on_release := false
	var _is_pressed := false
	var _press_inside := false
	var _press_pos := Vector2.ZERO

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		mouse_exited.connect(_on_mouse_exited)

	func _on_mouse_exited() -> void:
		_is_pressed = false
		_press_inside = false
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_is_pressed = true
				_press_inside = true
				_press_pos = event.position
				queue_redraw()
				if not activate_on_release:
					pressed.emit()
					accept_event()
			else:
				var fire := false
				if activate_on_release and _press_inside:
					fire = Rect2(Vector2.ZERO, size).has_point(event.position) and event.position.distance_to(_press_pos) <= 16.0
				_is_pressed = false
				_press_inside = false
				queue_redraw()
				if fire:
					pressed.emit()

	func _draw() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = fill.darkened(0.25) if _is_pressed else fill
		sb.set_corner_radius_all(corner_radius)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		if text != "":
			var font := get_theme_default_font()
			var y := size.y * 0.5 + float(font_size) * 0.36
			draw_string(font, Vector2(0, y), text, HORIZONTAL_ALIGNMENT_CENTER, size.x, font_size, icon_col)
		elif icon != "":
			_draw_icon(icon)

	func _draw_icon(kind: String) -> void:
		var c := size * 0.5
		var u := minf(size.x, size.y)
		var col := icon_col
		if kind == "pause":
			draw_rect(Rect2(c.x - 0.26 * u, c.y - 0.28 * u, 0.18 * u, 0.56 * u), col)
			draw_rect(Rect2(c.x + 0.08 * u, c.y - 0.28 * u, 0.18 * u, 0.56 * u), col)
		elif kind == "play":
			var pts := PackedVector2Array([
				Vector2(c.x - 0.16 * u, c.y - 0.26 * u),
				Vector2(c.x - 0.16 * u, c.y + 0.26 * u),
				Vector2(c.x + 0.28 * u, c.y),
			])
			draw_colored_polygon(pts, col)
		elif kind == "restart":
			var r := 0.30 * u
			var a0 := 0.9
			draw_arc(c, r, a0, a0 + 4.6, 28, col, 0.10 * u, true)
			var p := c + Vector2(cos(a0), sin(a0)) * r
			var tangent := Vector2(sin(a0), -cos(a0))
			var normal := Vector2(cos(a0), sin(a0))
			var head := PackedVector2Array([
				p + tangent * 0.18 * u,
				p - tangent * 0.06 * u + normal * 0.12 * u,
				p - tangent * 0.06 * u - normal * 0.12 * u,
			])
			draw_colored_polygon(head, col)
		elif kind == "exit":
			# Door/arch on the right with a bold arrow exiting it
			# leftward: reads as "exit to map" at 96x96. Thick
			# strokes match the restart/wrench glyphs.
			var door_tl := Vector2(c.x + 0.06 * u, c.y - 0.30 * u)
			var door_w := 0.30 * u
			var door_h := 0.60 * u
			var arc_c := Vector2(door_tl.x + door_w * 0.5, door_tl.y + door_w * 0.5)
			draw_arc(arc_c, door_w * 0.5, PI, TAU, 14, col, 0.11 * u, true)
			draw_line(Vector2(door_tl.x, arc_c.y), Vector2(door_tl.x, door_tl.y + door_h), col, 0.11 * u, true)
			draw_line(Vector2(door_tl.x + door_w, arc_c.y), Vector2(door_tl.x + door_w, door_tl.y + door_h), col, 0.11 * u, true)
			var ay := c.y
			draw_line(Vector2(c.x + 0.24 * u, ay), Vector2(c.x - 0.16 * u, ay), col, 0.10 * u, true)
			var head2 := PackedVector2Array([
				Vector2(c.x - 0.34 * u, ay),
				Vector2(c.x - 0.14 * u, ay - 0.13 * u),
				Vector2(c.x - 0.14 * u, ay + 0.13 * u),
			])
			draw_colored_polygon(head2, col)
		elif kind == "wrench":
			var handle_a := c + Vector2(-0.30, 0.30) * u
			var handle_b := c + Vector2(0.08, -0.08) * u
			draw_line(handle_a, handle_b, col, 0.11 * u, true)
			var jaw_c := c + Vector2(0.20, -0.20) * u
			draw_arc(jaw_c, 0.20 * u, -0.6, 4.2, 20, col, 0.10 * u, true)


var level_number := 1
var trap_col := Color.WHITE
var bg_col := Color.WHITE
var _deaths := 0
var _skip_btn: IconButton = null


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(pal: Dictionary, p_level_number: int) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	trap_col = TTuning.col(str(pal.get("trap", "#2B0A8A")))
	bg_col = TTuning.col(str(pal.get("bg", "#FFFFFF")))
	level_number = p_level_number
	# Drawing only: HUD renders above all level art.
	z_index = 100
	var yellow := Color.html("FFD23F")
	var pause_btn := IconButton.new()
	pause_btn.icon = "pause"
	pause_btn.fill = trap_col
	pause_btn.icon_col = yellow
	pause_btn.position = Vector2(16, 16)
	pause_btn.size = Vector2(48, 48)
	pause_btn.pressed.connect(_on_pause_btn)
	add_child(pause_btn)
	var restart_btn := IconButton.new()
	restart_btn.icon = "restart"
	restart_btn.fill = trap_col
	restart_btn.icon_col = yellow
	restart_btn.position = Vector2(76, 16)
	restart_btn.size = Vector2(48, 48)
	restart_btn.pressed.connect(_on_restart_btn)
	add_child(restart_btn)
	_skip_btn = IconButton.new()
	_skip_btn.text = "SKIP >>"
	_skip_btn.font_size = 26
	_skip_btn.fill = trap_col
	_skip_btn.icon_col = yellow
	_skip_btn.position = Vector2(1114, 16)
	_skip_btn.size = Vector2(150, 48)
	_skip_btn.visible = false
	_skip_btn.pressed.connect(_on_skip_btn)
	add_child(_skip_btn)


func set_deaths(death_count: int) -> void:
	if death_count == _deaths:
		return
	_deaths = death_count
	if _skip_btn != null:
		_skip_btn.visible = _deaths >= 3


func is_skip_visible() -> bool:
	return _skip_btn != null and _skip_btn.visible


func _on_pause_btn() -> void:
	pause_pressed.emit()


func _on_restart_btn() -> void:
	restart_pressed.emit()


func _on_skip_btn() -> void:
	skip_pressed.emit()


func _draw() -> void:
	var text := "LEVEL %d" % level_number
	# Node2D has no theme: the fallback font is the only font source.
	var font := ThemeDB.fallback_font
	var font_size := 34
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var pad := 16.0
	var top := 18.0
	var band_h := 34.0
	# Opaque backing behind the text span, drawn first: level art
	# passes behind the HUD instead of threading through the indicator
	# row. Same background colour as the level background, so it is
	# invisible except where it occludes level art. Drawing only.
	draw_rect(Rect2((1280.0 - w) * 0.5 - pad, top, w + pad * 2.0, band_h), bg_col)
	var baseline := top + band_h * 0.5 + float(font_size) * 0.36
	draw_string(font, Vector2(0, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, 1280.0, font_size, trap_col)
