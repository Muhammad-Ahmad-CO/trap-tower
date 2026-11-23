class_name TTHUD
extends Node2D

# In-game HUD (LEVEL_SCHEMA.md v3, amended v1.0.9 Lane A). Top-centre:
# the door-progress indicator — FIVE small SQUARES (pips), filled =
# completed stages in the current door (official: 2 filled + 3
# outlined at progress 2/5). The number chip is REMOVED: the pips are
# the ONLY top-centre element. Top-left: pause + restart + back icon
# buttons (Lane M11 v1.0.9: back returns to the plain map).
# Top-right: "SKIP >>", visible ONLY when deaths in the current level
# reach 3 (game pushes deaths per frame; the HUD owns no save state).
# Lane U4 (M2): skull icon + "n/5" (hidden keys found in this level's
# chapter, 5 per chapter) in a row UNDER the pips — pips y 12..35,
# skull row y 40..56, mode tag y 56..77 (unchanged), Lane U5's
# speedrun timer y 84 (its spot is reserved here, do not move the
# mode tag down). The skull row is drawn by the HUD; the game owns
# the counts (setup params, bump_keys on collect).
# HUD accent colours (dark-red + yellow) are FIXED code constants,
# independent of the level palette, and never clash with any palette
# (proven on gold palettes, the v1.0.3 contrast minor). During the death
# state set_dead(true) hides pause + restart + back (+ skip): only the
# top-centre indicator stays. The HUD root is PROCESS_MODE_ALWAYS so
# its buttons stay clickable while the tree is paused; children
# inherit that mode.

signal pause_pressed
signal restart_pressed
signal back_pressed
signal skip_pressed
signal ghost_toggled(enabled: bool)

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
			# EXIT, unambiguous at 1x (O4 fix): a door arch whose
			# right jamb is BROKEN where a bold arrow passes through
			# it, pointing RIGHT out of the door — the arrow tip
			# sticks out past the door frame, so it cannot read as
			# "back" (left arrow) or a lowercase "n". Thick strokes
			# match the restart/wrench glyphs. Restart/play untouched.
			var hw := 0.28 * u
			var top := c.y - 0.30 * u
			var bot := c.y + 0.30 * u
			var arc_c := Vector2(c.x, top + hw)
			var ay := c.y
			var w := 0.11 * u
			draw_arc(arc_c, hw, PI, TAU, 16, col, w, true)
			draw_line(Vector2(c.x - hw, arc_c.y), Vector2(c.x - hw, bot), col, w, true)
			# Right jamb in two segments, gap at the arrow's height.
			draw_line(Vector2(c.x + hw, arc_c.y), Vector2(c.x + hw, ay - 0.10 * u), col, w, true)
			draw_line(Vector2(c.x + hw, ay + 0.10 * u), Vector2(c.x + hw, bot), col, w, true)
			draw_line(Vector2(c.x - hw, bot), Vector2(c.x + hw, bot), col, w, true)
			# N3: arrowhead enlarged (was tip +0.44u, half-height
			# 0.15u; now +0.47u / 0.19u, shaft +0.30u at 0.11u) so
			# it reads bigger at 1x on the 96px pause button; the
			# tip still stops inside the button (edge is 0.50u).
			# Arch + jambs + restart/play untouched.
			draw_line(Vector2(c.x - 0.20 * u, ay), Vector2(c.x + 0.30 * u, ay), col, 0.11 * u, true)
			var head2 := PackedVector2Array([
				Vector2(c.x + 0.47 * u, ay),
				Vector2(c.x + 0.24 * u, ay - 0.19 * u),
				Vector2(c.x + 0.24 * u, ay + 0.19 * u),
			])
			draw_colored_polygon(head2, col)
		elif kind == "back":
			# BACK (Lane M11 v1.0.9): a straight LEFT arrow — the
			# mirror of the exit glyph's arrow, without the door.
			# Same stroke vocabulary as exit (0.11u) and the same
			# arrowhead proportions (tip 0.47u from centre, 0.19u
			# half-height), so it reads at 48px and cannot be
			# confused with pause (two bars) or restart (arc).
			var ay2 := c.y
			draw_line(Vector2(c.x + 0.30 * u, ay2), Vector2(c.x - 0.30 * u, ay2), col, 0.11 * u, true)
			var head3 := PackedVector2Array([
				Vector2(c.x - 0.47 * u, ay2),
				Vector2(c.x - 0.24 * u, ay2 - 0.19 * u),
				Vector2(c.x - 0.24 * u, ay2 + 0.19 * u),
			])
			draw_colored_polygon(head3, col)
		elif kind == "wrench":
			var handle_a := c + Vector2(-0.30, 0.30) * u
			var handle_b := c + Vector2(0.08, -0.08) * u
			draw_line(handle_a, handle_b, col, 0.11 * u, true)
			var jaw_c := c + Vector2(0.20, -0.20) * u
			draw_arc(jaw_c, 0.20 * u, -0.6, 4.2, 20, col, 0.10 * u, true)


var level_number := 1
# Lane A (v1.0.9): door-progress pips. _pips_total = stages in the
# current door (5 normally; D03 has 4, D44 has 1); _pips_filled =
# completed stages in this door. level_number is KEPT (probes read
# it) but no longer drawn — the pips replace the number chip.
var _pips_filled := 0
var _pips_total := 5
# Pip geometry, measured from the official frames (ref_t14.png,
# viewport x 172..1744, scale 1.228): 5 squares 29x29 frame px =
# 23x23 game px, y 15..43 frame = 12..35 game, pitch 30 game px,
# span x 569..713 game (centred on 640). Filled pips are solid;
# unfilled pips are outline-only.
const PIP_SIZE := 23.0
const PIP_PITCH := 30.0
const PIP_Y := 12.0
const PIP_BORDER := 2.0
var _mode_text := ""
var _deaths := 0
# Lane U4 (M2): hidden keys found in this level's chapter (0..5).
# Set by setup(); bump_keys() increments the display on a collect
# (the game owns the save, the HUD only displays).
var _keys_found := 0
var _keys_total := 5
var _pause_btn: IconButton = null
var _restart_btn: IconButton = null
var _back_btn: IconButton = null
var _skip_btn: IconButton = null
var _ghost_btn: IconButton = null
var _ghost_on := true
var _has_ghost := false
var _dead := false
# Lane U5 (M4 speedrun): live run timer under the pips. A plain
# TTPixelLabel child (hidden until a speedrun run drives it via
# show_speedrun_timer / set_speedrun_time); the game, not the HUD,
# owns the run clock. No chapter logic here.
var _speedrun_label: TTPixelLabel = null
var _speedrun_visible := false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(_pal: Dictionary, p_level_number: int, p_has_ghost: bool = false, p_ghost_on: bool = true, p_mode_text: String = "", p_pips_filled: int = 0, p_pips_total: int = 5, p_keys_found: int = 0, p_keys_total: int = 5) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	level_number = p_level_number
	_pips_filled = clampi(p_pips_filled, 0, maxi(1, p_pips_total))
	_pips_total = maxi(1, p_pips_total)
	# Lane U4 (M2): skull n/5 for this level's chapter.
	_keys_found = clampi(p_keys_found, 0, maxi(1, p_keys_total))
	_keys_total = maxi(1, p_keys_total)
	_has_ghost = p_has_ghost
	_ghost_on = p_ghost_on
	# Lane F2: "DAILY" / "NIGHTMARE" tag under the pips ("" =
	# normal play, no tag). Drawing only; the pips are untouched.
	_mode_text = p_mode_text
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
	# Lane M11 (v1.0.9): back-to-map button, after restart — pause
	# (16,16), restart (76,16), back (136,16), all 48x48, 12px gaps.
	_back_btn = IconButton.new()
	_back_btn.icon = "back"
	_back_btn.fill = HUD_DARK_RED
	_back_btn.icon_col = HUD_YELLOW
	_back_btn.position = Vector2(136, 16)
	_back_btn.size = Vector2(48, 48)
	_back_btn.pressed.connect(_on_back_btn)
	add_child(_back_btn)
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
	# Lane F3 ghost toggle: top-right, left of SKIP (848..1012, SKIP
	# starts at 1024). Shown ONLY when this level has a saved ghost;
	# a level with no best run yet has nothing to toggle. ON = dark
	# red fill + yellow text (matches the other HUD buttons); OFF =
	# dimmed grey so the state reads at a glance. The toggle only
	# hides the ghost drawing — it never touches gameplay.
	_ghost_btn = IconButton.new()
	_ghost_btn.text = "GHOST"
	_ghost_btn.font_size = 22
	_ghost_btn.position = Vector2(848, 16)
	_ghost_btn.size = Vector2(164, 48)
	_ghost_btn.visible = _has_ghost
	_ghost_btn.pressed.connect(_on_ghost_btn)
	add_child(_ghost_btn)
	_refresh_ghost_btn()
	# Lane U5 (M4): speedrun timer, centred under the pips (y 84,
	# below the mode tag at y 56). Hidden by default; a speedrun run
	# shows it and pushes the live time every frame. Tenths format
	# ("0:00.0") so a race time reads precisely; same yellow as the
	# mode tag, so it reads on every palette like the pips do.
	_speedrun_label = TTPixelLabel.new()
	_speedrun_label.text = "0:00.0"
	_speedrun_label.pixel_size = 4
	_speedrun_label.color = HUD_YELLOW
	_speedrun_label.align = HORIZONTAL_ALIGNMENT_CENTER
	_speedrun_label.width = 1280.0
	_speedrun_label.position = Vector2(0, 84)
	_speedrun_label.visible = false
	add_child(_speedrun_label)


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


func is_ghost_visible() -> bool:
	return _ghost_btn != null and _ghost_btn.visible


func is_ghost_on() -> bool:
	return _ghost_on


# Lane U5 (M4 speedrun): show/hide the run timer + push the live
# time. The M4 run loop (game.gd stub until U4's chapter API lands)
# calls show_speedrun_timer(true) at run start and set_speedrun_time
# every physics frame; set_speedrun_time is a no-op while hidden so
# a stray call can never flash the timer in normal play.
func show_speedrun_timer(v: bool) -> void:
	_speedrun_visible = v
	if _speedrun_label != null:
		_speedrun_label.visible = v


func is_speedrun_timer_visible() -> bool:
	return _speedrun_visible


func set_speedrun_time(seconds: float) -> void:
	if not _speedrun_visible or _speedrun_label == null:
		return
	_speedrun_label.text = TTFeatures.format_time_tenths(seconds)


func speedrun_time_text() -> String:
	if _speedrun_label == null:
		return ""
	return _speedrun_label.text


# Lane A (v1.0.9): pip accessors for probes — the drawn rects and
# the filled count, so the UI probe can assert pips without pixels.
func get_pip_rects() -> Array:
	var total_w := float(_pips_total) * PIP_SIZE \
			+ float(_pips_total - 1) * (PIP_PITCH - PIP_SIZE)
	var x0 := (1280.0 - total_w) * 0.5
	var out: Array = []
	for i in range(_pips_total):
		out.append(Rect2(x0 + float(i) * PIP_PITCH, PIP_Y,
				PIP_SIZE, PIP_SIZE))
	return out


func pip_filled_count() -> int:
	return _pips_filled


func pip_total_count() -> int:
	return _pips_total


# Lane U4 (M2): skull-counter accessors for probes + the game.
# set_keys replaces the displayed count (level start); bump_keys
# increments it by one on a collect (capped at the chapter total).
func keys_found_count() -> int:
	return _keys_found


func keys_total_count() -> int:
	return _keys_total


func keys_text() -> String:
	return str(_keys_found) + "/" + str(_keys_total)


func set_keys(found: int, total: int) -> void:
	_keys_total = maxi(1, total)
	_keys_found = clampi(found, 0, _keys_total)
	queue_redraw()


func bump_keys() -> void:
	_keys_found = mini(_keys_found + 1, _keys_total)
	queue_redraw()


# Skull-row geometry for probes: the skull icon box (16x16) + the
# "n/5" text run beside it, band y 40..56 under the pips.
func get_skull_rect() -> Rect2:
	return Rect2(600.0, 40.0, 80.0, 16.0)


func set_ghost(on: bool) -> void:
	_ghost_on = on
	_refresh_ghost_btn()


func _refresh_ghost_btn() -> void:
	if _ghost_btn == null:
		return
	if _ghost_on:
		_ghost_btn.fill = HUD_DARK_RED
		_ghost_btn.icon_col = HUD_YELLOW
	else:
		_ghost_btn.fill = Color(0.25, 0.25, 0.28)
		_ghost_btn.icon_col = Color(0.75, 0.75, 0.78)
	_ghost_btn.queue_redraw()


func _on_ghost_btn() -> void:
	_ghost_on = not _ghost_on
	_refresh_ghost_btn()
	ghost_toggled.emit(_ghost_on)


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
	if _back_btn != null:
		_back_btn.visible = not _dead
	_refresh_skip()


func is_dead_hidden() -> bool:
	return _dead


func _on_pause_btn() -> void:
	pause_pressed.emit()


func _on_restart_btn() -> void:
	restart_pressed.emit()


func _on_back_btn() -> void:
	back_pressed.emit()


# Lane M11 (v1.0.9): back-button probe accessors, mirroring
# is_skip_visible() / get_pip_rects().
func is_back_visible() -> bool:
	return _back_btn != null and _back_btn.visible


func back_rect() -> Rect2:
	if _back_btn == null:
		return Rect2()
	return Rect2(_back_btn.position, _back_btn.size)


func _on_skip_btn() -> void:
	skip_pressed.emit()


func _draw() -> void:
	# Lane A (v1.0.9): FIVE small squares top-centre, filled =
	# completed stages in the current door. Fixed accents: readable
	# on every palette. Filled pip = yellow fill + dark-red border;
	# unfilled pip = dark-red border only (transparent interior, so
	# the sky shows through). The old number chip is REMOVED.
	var rects := get_pip_rects()
	for i in range(rects.size()):
		var r: Rect2 = rects[i]
		if i < _pips_filled:
			draw_rect(r, HUD_YELLOW)
		draw_rect(r, HUD_DARK_RED, false, PIP_BORDER)
	# Lane U4 (M2): skull icon + "n/5" under the pips (band y 40..56,
	# pixel size 2 so the row clears the mode tag at y 56). The skull
	# is code-drawn (white cranium + dark-red outline/eyes/jaw) so it
	# reads on every palette; the count is yellow pixel text.
	var sk := get_skull_rect()
	var sc := Vector2(sk.position.x + 8.0, sk.position.y + 6.0)
	draw_circle(sc, 6.5, HUD_DARK_RED)
	draw_circle(sc, 5.5, Color.WHITE)
	draw_rect(Rect2(sc.x - 3.0, sc.y + 4.0, 6.0, 5.0), HUD_DARK_RED)
	draw_rect(Rect2(sc.x - 2.0, sc.y + 4.0, 4.0, 4.0), Color.WHITE)
	draw_line(Vector2(sc.x - 0.7, sc.y + 4.0), Vector2(sc.x - 0.7, sc.y + 8.0), HUD_DARK_RED, 1.0, true)
	draw_line(Vector2(sc.x + 0.7, sc.y + 4.0), Vector2(sc.x + 0.7, sc.y + 8.0), HUD_DARK_RED, 1.0, true)
	draw_circle(sc + Vector2(-2.2, -1.0), 1.4, HUD_DARK_RED)
	draw_circle(sc + Vector2(2.2, -1.0), 1.4, HUD_DARK_RED)
	TTPixelFont.draw_text(self, keys_text(), Vector2(sk.position.x + 22.0, sk.position.y + 1.0), 2, HUD_YELLOW, HORIZONTAL_ALIGNMENT_LEFT, 60.0)
	if _mode_text != "":
		# Mode tag under the pips (y 56..77, still inside the HUD
		# band): small yellow pixel text, centred on the screen.
		TTPixelFont.draw_text(self, _mode_text, Vector2(0, 56), 3, HUD_YELLOW, HORIZONTAL_ALIGNMENT_CENTER, 1280.0)
