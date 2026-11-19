class_name TTHUD
extends Node2D

# In-game HUD (LEVEL_SCHEMA.md v3). Top-centre: the level indicator —
# a SMALL pixel-font level NUMBER (e.g. `37`), yellow on a small
# dark-red chip. The number is the ONLY top-centre element. No squares,
# no other counters. Top-left: pause + restart icon buttons. Top-right:
# "SKIP >>", visible ONLY when deaths in the current level reach 3
# (game pushes deaths per frame; the HUD owns no save state).
# HUD accent colours (dark-red + yellow) are FIXED code constants,
# independent of the level palette, and never clash with any palette
# (proven on gold palettes, the v1.0.3 contrast minor). During the death
# state set_dead(true) hides pause + restart (+ skip): only the
# top-centre indicator stays. The HUD root is PROCESS_MODE_ALWAYS so
# its buttons stay clickable while the tree is paused; children
# inherit that mode.

signal pause_pressed
signal restart_pressed
signal skip_pressed

# Fixed HUD accents (schema: independent of the level palette).
const HUD_DARK_RED := Color(0.43, 0.04, 0.04)
const HUD_YELLOW := Color(1.0, 0.824, 0.247)


# One small reusable icon/text button. Code-drawn (icons drawn as
# shapes; `text` draws a centred pixel-font label instead of an icon).
# Used by the HUD, the pause panel (game.gd) and the map wrench
# (map.gd) via TTHUD.IconButton. Press-mode (default): fires on press.
# Release-mode (activate_on_release, for buttons inside a
# ScrollContainer): fires on release inside the rect after a press
# that did not drag, and never accepts the press event so the scroll
# container can still scroll.
class IconButton extends Control:
	signal pressed

	var icon := ""
	var text := ""
	var fill := TTHUD.HUD_DARK_RED
	var icon_col := TTHUD.HUD_YELLOW
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
			var px := maxi(3, int(font_size / 5.0))
			var ty := (size.y - float(TTPixelFont.GLYPH_H * px)) * 0.5
			TTPixelFont.draw_text(self, text, Vector2(0, ty), px, icon_col, HORIZONTAL_ALIGNMENT_CENTER, size.x)
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
var _deaths := 0
var _pause_btn: IconButton = null
var _restart_btn: IconButton = null
var _skip_btn: IconButton = null
var _dead := false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(_pal: Dictionary, p_level_number: int) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	level_number = p_level_number
	# Drawing only: HUD renders above all level art.
	z_index = 100
	_pause_btn = IconButton.new()
	_pause_btn.icon = "pause"
	_pause_btn.fill = HUD_DARK_RED
	_pause_btn.icon_col = HUD_YELLOW
	_pause_btn.position = Vector2(16, 16)
	_pause_btn.size = Vector2(48, 48)
	_pause_btn.pressed.connect(_on_pause_btn)
	add_child(_pause_btn)
	_restart_btn = IconButton.new()
	_restart_btn.icon = "restart"
	_restart_btn.fill = HUD_DARK_RED
	_restart_btn.icon_col = HUD_YELLOW
	_restart_btn.position = Vector2(76, 16)
	_restart_btn.size = Vector2(48, 48)
	_restart_btn.pressed.connect(_on_restart_btn)
	add_child(_restart_btn)
	_skip_btn = IconButton.new()
	_skip_btn.text = "SKIP >>"
	_skip_btn.font_size = 22
	_skip_btn.fill = HUD_DARK_RED
	_skip_btn.icon_col = HUD_YELLOW
	_skip_btn.position = Vector2(1024, 16)
	_skip_btn.size = Vector2(240, 48)
	_skip_btn.visible = false
	_skip_btn.pressed.connect(_on_skip_btn)
	add_child(_skip_btn)


func set_deaths(death_count: int) -> void:
	if death_count == _deaths:
		return
	_deaths = death_count
	_refresh_skip()


func _refresh_skip() -> void:
	if _skip_btn != null:
		_skip_btn.visible = (not _dead) and _deaths >= 3


func is_skip_visible() -> bool:
	return _skip_btn != null and _skip_btn.visible


# Death state: pause + restart (+ skip) hidden; only the top-centre
# level indicator stays. Called every physics frame by the game node.
func set_dead(is_dead: bool) -> void:
	if is_dead == _dead:
		return
	_dead = is_dead
	if _pause_btn != null:
		_pause_btn.visible = not _dead
	if _restart_btn != null:
		_restart_btn.visible = not _dead
	_refresh_skip()


func is_dead_hidden() -> bool:
	return _dead


func _on_pause_btn() -> void:
	pause_pressed.emit()


func _on_restart_btn() -> void:
	restart_pressed.emit()


func _on_skip_btn() -> void:
	skip_pressed.emit()


func _draw() -> void:
	# Small pixel-font level NUMBER on a small dark-red chip,
	# top-centre. Fixed accents: readable on every palette.
	var text := str(level_number)
	var px := 5
	var tw := TTPixelFont.text_width(text, px)
	var pad := 12.0
	var chip_w := tw + pad * 2.0
	var chip_h := 38.0
	var top := 14.0
	var x := (1280.0 - chip_w) * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = HUD_DARK_RED
	sb.set_corner_radius_all(8)
	draw_style_box(sb, Rect2(x, top, chip_w, chip_h))
	var ty := top + (chip_h - float(TTPixelFont.GLYPH_H * px)) * 0.5
	TTPixelFont.draw_text(self, text, Vector2(x, ty), px, HUD_YELLOW, HORIZONTAL_ALIGNMENT_CENTER, chip_w)
