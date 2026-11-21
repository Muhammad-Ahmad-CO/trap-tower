class_name TTTouchControls
extends Node2D

# Overlay controls (LEVEL_SCHEMA.md v3): THREE large transparent
# OUTLINED chevrons overlaying the play area — NO solid bar, NO filled
# buttons at rest. Left chevron, right chevron, and a LARGER up/roof
# chevron for jump (never a house shape). Outline colour = the level's
# LIGHT colour (the lighter of bg/trap); fill-on-press feedback.
# Generous hitboxes (larger than the drawn outlines). Multi-touch:
# each finger tracked by its InputEvent index; a button releases when
# its finger drags off it or lifts. No stuck input.
# Works standalone (default rects/colours) and via setup() from the game.

# Drawn outline rects (logical 1280x720). Upper-middle sky band, per the
# user's white box on his phone screenshot (21 Nov 15:04 PKT): move
# chevrons at the band's left end, jump chevron at the band's right end,
# all vertically centred in the band (centre y ~286). The band sits below
# the HUD and above the floor and the hero's jump arc on ground levels;
# on high-platform levels the hero may pass behind the transparent
# outlines (rest state has no fill; press fill is 0.35, so the hero and
# hazards stay visible through a pressed chevron).
# PRESS_FILL_ALPHA (Lane 2c, Part B): the press fill MUST stay
# semi-transparent. The user found on his own phone test of v1.0.4
# (20 Nov 04:03 PKT) that the buttons HIDE the floor behind them —
# the old opaque press fill (alpha 1.0) covered the floor/hazards
# exactly while the player holds move/jump, i.e. most of the time.
# At 0.35 the floor edge and hazards stay clearly visible through a
# pressed chevron. The fill COLOUR is press_col — the palette colour
# contrasting with the sky (dark on light skies, light on dark skies)
# — because a light_col fill was invisible on L001, where light_col IS
# the orange sky (tint fix, 21 Nov; verified on L001 + L066, see
# verification/tint-fix/).
const PRESS_FILL_ALPHA := 0.35
var left_rect := Rect2(100, 246, 180, 80)
var right_rect := Rect2(310, 246, 180, 80)
var jump_rect := Rect2(970, 241, 210, 90)
# Generous hitboxes, larger than the drawn outlines (recomputed in
# setup(); defaults match the standalone rects above).
var left_hit := Rect2(78, 224, 224, 124)
var right_hit := Rect2(288, 224, 224, 124)
var jump_hit := Rect2(948, 219, 254, 134)

var light_col := Color.html("E8871E")
var dark_col := Color.html("2B0A8A")

# Press-fill colour: the palette colour CONTRASTING with the sky the
# buttons sit over (set in setup(); default = dark, matching the
# default orange sky). Tint fix, 21 Nov.
var press_col := Color.html("2B0A8A")

var _fingers := {}

var touch_left: bool:
	get:
		return _held("left")
var touch_right: bool:
	get:
		return _held("right")
var touch_jump: bool:
	get:
		return _held("jump")


func setup(_tuning: Dictionary, pal: Dictionary) -> void:
	# Schema v3: the DEPRECATED tuning `control_bar` entry is never
	# read. Colour = the lighter of the level's bg/trap.
	var bg := TTuning.col(str(pal.get("bg", "#E8871E")))
	var trap := TTuning.col(str(pal.get("trap", "#2B0A8A")))
	var bg_is_light := _luminance(bg) >= _luminance(trap)
	if bg_is_light:
		light_col = bg
		dark_col = trap
	else:
		light_col = trap
		dark_col = bg
	# Press fill = the palette colour that CONTRASTS with the sky the
	# buttons sit over (the other palette colour): dark on light skies,
	# light on dark skies. Tint fix (21 Nov): the old light_col fill was
	# invisible on L001 because light_col IS the orange sky.
	press_col = dark_col if bg_is_light else light_col
	# Drawing only: controls render above all level art.
	z_index = 100
	left_rect = Rect2(100, 246, 180, 80)
	right_rect = Rect2(310, 246, 180, 80)
	jump_rect = Rect2(970, 241, 210, 90)
	_refresh_hits()
	queue_redraw()


func _refresh_hits() -> void:
	left_hit = left_rect.grow(22.0)
	right_hit = right_rect.grow(22.0)
	jump_hit = jump_rect.grow(22.0)


static func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func get_button_rect(button: String) -> Rect2:
	# Hitboxes (generous): the touch test and the game inject at the
	# hit-rect centre, which matches the drawn outline centre.
	if button == "left":
		return left_hit
	if button == "right":
		return right_hit
	if button == "jump":
		return jump_hit
	return Rect2()


func get_drawn_rect(button: String) -> Rect2:
	if button == "left":
		return left_rect
	if button == "right":
		return right_rect
	if button == "jump":
		return jump_rect
	return Rect2()


func get_input_state() -> Dictionary:
	return {"left": _held("left"), "right": _held("right"), "jump": _held("jump")}


func _held(button: String) -> bool:
	for key in _fingers:
		if str(_fingers[key]) == button:
			return true
	return false


func _button_at(pos: Vector2) -> String:
	if left_hit.has_point(pos):
		return "left"
	if right_hit.has_point(pos):
		return "right"
	if jump_hit.has_point(pos):
		return "jump"
	return ""


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			var b := _button_at_viewport(touch.position)
			if b != "":
				_fingers[touch.index] = b
				queue_redraw()
		elif _fingers.has(touch.index):
			_fingers.erase(touch.index)
			queue_redraw()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if _fingers.has(drag.index):
			var held_btn := str(_fingers[drag.index])
			if _button_at_viewport(drag.position) != held_btn:
				_fingers.erase(drag.index)
				queue_redraw()


func _button_at_viewport(viewport_pos: Vector2) -> String:
	# _input positions arrive in screen space under stretch
	# (canvas_items + keep); map them into logical 1280x720 canvas space.
	# Fall back to the raw position so a path that already delivers
	# logical coordinates still hits the buttons.
	var b := _button_at(_to_local(viewport_pos))
	if b != "":
		return b
	return _button_at(viewport_pos)


func _to_local(screen_pos: Vector2) -> Vector2:
	var viewport_pos: Vector2 = get_viewport().get_screen_transform() * screen_pos
	return get_global_transform_with_canvas().affine_inverse() * viewport_pos


func _draw() -> void:
	_draw_button(left_rect, "left")
	_draw_button(right_rect, "right")
	_draw_button(jump_rect, "jump")


# One outlined chevron. Outline = light colour, 5px, transparent fill
# at rest; fill-on-press fills the chevron with press_col (the palette
# colour contrasting with the sky — dark on light skies, light on dark
# skies) at PRESS_FILL_ALPHA — semi-transparent, so the floor and
# hazards underneath stay visible while the button is held. Pressed
# and rest share the same dark-edge + light outline; only the fill
# differs, so the pressed state reads on light and dark palettes.
# (A light_col fill did NOT read on light palettes: on L001 light_col
# IS the orange sky, so pressed == rest pixel-for-pixel. Tint fix,
# 21 Nov.)
func _draw_button(r: Rect2, button: String) -> void:
	var pressed := _held(button)
	var c := r.get_center()
	var pts := PackedVector2Array()
	if button == "left":
		pts = PackedVector2Array([
			Vector2(r.position.x, c.y),
			Vector2(r.position.x + 34, r.position.y),
			Vector2(r.end.x, r.position.y),
			Vector2(r.end.x, r.end.y),
			Vector2(r.position.x + 34, r.end.y),
		])
	elif button == "right":
		pts = PackedVector2Array([
			Vector2(r.end.x, c.y),
			Vector2(r.end.x - 34, r.position.y),
			Vector2(r.position.x, r.position.y),
			Vector2(r.position.x, r.end.y),
			Vector2(r.end.x - 34, r.end.y),
		])
	else:
		# Jump: wide low roof chevron, apex above the button centre.
		pts = PackedVector2Array([
			Vector2(c.x, c.y - 38),
			Vector2(r.end.x, c.y + 6),
			Vector2(r.end.x, r.end.y),
			Vector2(r.position.x, r.end.y),
			Vector2(r.position.x, c.y + 6),
		])
	if pressed:
		var fill_col := press_col
		fill_col.a = PRESS_FILL_ALPHA
		draw_colored_polygon(pts, fill_col)
		var closed := pts + PackedVector2Array([pts[0]])
		draw_polyline(closed, dark_col, 9.0, true)
		draw_polyline(closed, light_col, 5.0, true)
	else:
		var closed2 := pts + PackedVector2Array([pts[0]])
		# Dark edge behind the light outline (both palette colours):
		# the chevron stays readable where it crosses light
		# platforms on dark palettes, and on light backgrounds —
		# the reference's chevrons carry the same soft dark edge.
		draw_polyline(closed2, dark_col, 9.0, true)
		draw_polyline(closed2, light_col, 5.0, true)
