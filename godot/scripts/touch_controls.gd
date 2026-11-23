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

# Drawn outline rects (logical 1280x720). BOTTOM corners, official
# positions (v1.0.9 Lane A2, IMPLEMENTATION-GATE.md): left/right
# chevrons bottom-left, jump chevron bottom-right, all sitting on the
# floor line (bottom y 692). CORRECTED 22 Nov ~19:00 PKT — Lane A's
# rects (64/320/1106, y 627) were the coordinator's eyeball estimates
# and were WRONG; these are the coordinator's PIXEL-MEASURED rects
# from ref_t14.png + ref_t8.png (outline colour #fdb754, both frames
# agree exactly): uniform ~173x72 at y 620. The buttons overlay the
# play area, so the press fill stays semi-transparent
# (PRESS_FILL_ALPHA 0.35) and the floor stays visible through a
# pressed chevron. Chevron shapes stay ours (never a roof/house shape
# for jump); only the rects moved.
# PRESS_FILL_ALPHA (Lane 2c, Part B): the press fill MUST stay
# semi-transparent. The user found on his own phone test of v1.0.4
# (20 Nov 04:03 PKT) that the buttons HIDE the floor behind them —
# the old opaque press fill (alpha 1.0) covered the floor/hazards
# exactly while the player holds move/jump, i.e. most of the time.
# At 0.35 the floor edge and hazards stay clearly visible through a
# pressed chevron. The fill COLOUR is per button (Lane A2): the
# palette colour contrasting with the MAJORITY surface under that
# button — BG colour where >=50% of the button sits over solid
# platforms, SOLID (platform) colour otherwise — because the old
# sky-contrast tint was invisible where a button sits over solid
# geometry (L066 right button: 0 px changed when held).
const PRESS_FILL_ALPHA := 0.35
var left_rect := Rect2(60, 620, 173, 72)
var right_rect := Rect2(295, 620, 173, 72)
var jump_rect := Rect2(1049, 620, 173, 72)
# Generous hitboxes, larger than the drawn outlines (recomputed in
# setup(); defaults match the standalone rects above).
var left_hit := Rect2(38, 598, 217, 116)
var right_hit := Rect2(273, 598, 217, 116)
var jump_hit := Rect2(1027, 598, 217, 116)

var light_col := Color.html("E8871E")
var dark_col := Color.html("2B0A8A")

# Press-fill colour (legacy single value): the palette colour
# CONTRASTING with the sky the buttons sit over (set in setup();
# default = dark, matching the default orange sky). Tint fix, 21 Nov.
# Kept for the standalone path (no platform data); the game path now
# uses the per-button fills below (Lane A2).
var press_col := Color.html("2B0A8A")

# Per-button press fills (Lane A2): each button's fill contrasts with
# the MAJORITY surface under that button (BG colour if >=50% of the
# button's area is over solid platforms, else the SOLID/platform
# colour). Set in setup() from the level's solid rects; the matching
# coverage fractions are kept for probes.
var press_fill_left := Color.html("2B0A8A")
var press_fill_right := Color.html("2B0A8A")
var press_fill_jump := Color.html("2B0A8A")
var press_cov_left := 0.0
var press_cov_right := 0.0
var press_cov_jump := 0.0

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


func setup(_tuning: Dictionary, pal: Dictionary, p_solids: Array = []) -> void:
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
	# Legacy sky-contrast tint (21 Nov tint fix): the palette colour
	# that CONTRASTS with the sky — dark on light skies, light on
	# dark skies. Still the fallback when no platform data is passed
	# (standalone path); the game path overrides per button below.
	press_col = dark_col if bg_is_light else light_col
	# Drawing only: controls render above all level art.
	z_index = 100
	left_rect = Rect2(60, 620, 173, 72)
	right_rect = Rect2(295, 620, 173, 72)
	jump_rect = Rect2(1049, 620, 173, 72)
	_refresh_hits()
	# Lane A2 press fill: per button, the palette colour contrasting
	# with the MAJORITY surface under that button. p_solids are the
	# level's solid platform rects (Rect2, game.gd passes them);
	# >=50% of the button over solid -> BG colour (contrasts with
	# the solid), else the SOLID/platform colour (contrasts with
	# the sky). Alpha stays PRESS_FILL_ALPHA.
	var solid_col := TTuning.col(str(pal.get("platform", "#2B0A8A")))
	if p_solids.is_empty():
		press_fill_left = press_col
		press_fill_right = press_col
		press_fill_jump = press_col
		press_cov_left = 0.0
		press_cov_right = 0.0
		press_cov_jump = 0.0
	else:
		press_cov_left = _solid_coverage(left_rect, p_solids)
		press_cov_right = _solid_coverage(right_rect, p_solids)
		press_cov_jump = _solid_coverage(jump_rect, p_solids)
		press_fill_left = bg if press_cov_left >= 0.5 else solid_col
		press_fill_right = bg if press_cov_right >= 0.5 else solid_col
		press_fill_jump = bg if press_cov_jump >= 0.5 else solid_col
	queue_redraw()


# Fraction of `button`'s area covered by the solid rects in
# `solids` (exact union area of the button∩solid intersections, via
# x-slab decomposition — solids that overlap each other are never
# double-counted). 0.0 when nothing is under the button.
static func _solid_coverage(button: Rect2, solids: Array) -> float:
	var hits: Array = []
	for s in solids:
		var r: Rect2 = s
		var inter := button.intersection(r)
		if inter.size.x > 0.0 and inter.size.y > 0.0:
			hits.append(inter)
	if hits.is_empty():
		return 0.0
	var xs: Array = []
	for h in hits:
		xs.append(h.position.x)
		xs.append(h.end.x)
	xs.sort()
	var area := 0.0
	for i in range(xs.size() - 1):
		var x0: float = xs[i]
		var x1: float = xs[i + 1]
		if x1 <= x0:
			continue
		var ys: Array = []
		for h in hits:
			if h.position.x <= x0 and h.end.x >= x1:
				ys.append(Vector2(h.position.y, h.end.y))
		if ys.is_empty():
			continue
		ys.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
		var covered := 0.0
		var cur0 := -1.0
		var cur1 := -1.0
		for iv in ys:
			if cur0 < 0.0:
				cur0 = iv.x
				cur1 = iv.y
			elif iv.x <= cur1:
				cur1 = maxf(cur1, iv.y)
			else:
				covered += cur1 - cur0
				cur0 = iv.x
				cur1 = iv.y
		if cur0 >= 0.0:
			covered += cur1 - cur0
		area += (x1 - x0) * covered
	return clampf(area / button.get_area(), 0.0, 1.0)


func _refresh_hits() -> void:
	# Generous hitboxes (22px grow), clipped to the 1280x720
	# viewport. With the corrected rects the jump hitbox ends at
	# x=1244, inside the viewport; the clip is kept as a guard so a
	# future rect move can never push a hitbox off-screen.
	var view := Rect2(0, 0, 1280, 720)
	left_hit = left_rect.grow(22.0).intersection(view)
	right_hit = right_rect.grow(22.0).intersection(view)
	jump_hit = jump_rect.grow(22.0).intersection(view)


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


func get_press_fill(button: String) -> Color:
	# Lane A2 probe accessor: the fill colour this button draws
	# when held (BG colour if >=50% over solid, else SOLID colour).
	if button == "left":
		return press_fill_left
	if button == "right":
		return press_fill_right
	if button == "jump":
		return press_fill_jump
	return press_col


func get_press_coverage(button: String) -> float:
	# Lane A2 probe accessor: fraction of the button's area over
	# solid platforms (0.0 with no platform data passed).
	if button == "left":
		return press_cov_left
	if button == "right":
		return press_cov_right
	if button == "jump":
		return press_cov_jump
	return 0.0


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
# at rest; fill-on-press fills the chevron with the per-button press
# fill (Lane A2: BG colour where >=50% of the button sits over solid
# platforms, else the SOLID/platform colour — each contrasts with the
# majority surface under that button) at PRESS_FILL_ALPHA —
# semi-transparent, so the floor and hazards underneath stay visible
# while the button is held. Pressed and rest share the same dark-edge
# + light outline; only the fill differs, so the pressed state reads
# on light and dark palettes, over sky AND over solid.
# (The old sky-contrast fill did NOT read over solid: on L066 the
# light fill over the white platform floor changed 0 px when held.
# Tint history: 21 Nov sky-contrast fix; 22 Nov Lane A2 per-button
# majority-surface fix.)
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
		var fill_col := get_press_fill(button)
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
