class_name TTTouchControls
extends Node2D

# Control bar (y 580..720) in EVERY level: left arrow, right arrow, and a
# LARGER jump button with a bold up arrow (never a house shape). Bar fill =
# trap colour; button fill = bg colour; arrow = trap colour.
# Multi-touch: each finger tracked by its InputEvent index; a button
# releases when its finger drags off it or lifts. No stuck input.
# Works standalone (default rects/colours) and via setup() from the game.

var bar_y := 580.0
var bar_col := Color.html("2B0A8A")
var btn_col := Color.html("E8871E")
var arrow_col := Color.html("2B0A8A")
var left_rect := Rect2(60, 600, 130, 100)
var right_rect := Rect2(220, 600, 130, 100)
var jump_rect := Rect2(920, 600, 210, 100)

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


func setup(tuning: Dictionary, pal: Dictionary) -> void:
	bar_y = float(tuning.get("control_bar", {}).get("y", 580))
	bar_col = TTuning.col(str(pal.get("trap", "#2B0A8A")))
	btn_col = TTuning.col(str(pal.get("bg", "#E8871E")))
	arrow_col = TTuning.col(str(pal.get("trap", "#2B0A8A")))
	# Drawing only: control bar renders above all level art.
	z_index = 100
	var y := bar_y + 20.0
	left_rect = Rect2(60, y, 130, 100)
	right_rect = Rect2(220, y, 130, 100)
	jump_rect = Rect2(920, y, 210, 100)
	queue_redraw()


func get_button_rect(button: String) -> Rect2:
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
	if left_rect.has_point(pos):
		return "left"
	if right_rect.has_point(pos):
		return "right"
	if jump_rect.has_point(pos):
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
	draw_rect(Rect2(0, bar_y, 1280, 720.0 - bar_y), bar_col)
	# 4px background-colour divider at the top edge of the control bar,
	# spanning the full width, so ground and bar read as separate bands
	# in palettes where platform colour == trap colour. btn_col is the
	# background colour; button rects start 20px below bar_y, so this
	# never overlaps a button. Drawing only.
	draw_rect(Rect2(0, bar_y, 1280, 4), btn_col)
	_draw_button(left_rect, "left")
	_draw_button(right_rect, "right")
	_draw_button(jump_rect, "jump")


func _draw_button(r: Rect2, button: String) -> void:
	var pressed := _held(button)
	var fill := arrow_col if pressed else btn_col
	var ac := btn_col if pressed else arrow_col
	draw_rect(r, fill)
	var c := r.get_center()
	var pts := PackedVector2Array()
	if button == "left":
		pts = PackedVector2Array([Vector2(c.x - 42, c.y), Vector2(c.x - 8, c.y - 30), Vector2(c.x - 8, c.y - 12), Vector2(c.x + 40, c.y - 12), Vector2(c.x + 40, c.y + 12), Vector2(c.x - 8, c.y + 12), Vector2(c.x - 8, c.y + 30)])
	elif button == "right":
		pts = PackedVector2Array([Vector2(c.x + 42, c.y), Vector2(c.x + 8, c.y - 30), Vector2(c.x + 8, c.y - 12), Vector2(c.x - 40, c.y - 12), Vector2(c.x - 40, c.y + 12), Vector2(c.x + 8, c.y + 12), Vector2(c.x + 8, c.y + 30)])
	else:
		pts = PackedVector2Array([Vector2(c.x, c.y - 38), Vector2(c.x + 34, c.y - 2), Vector2(c.x + 14, c.y - 2), Vector2(c.x + 14, c.y + 36), Vector2(c.x - 14, c.y + 36), Vector2(c.x - 14, c.y - 2), Vector2(c.x - 34, c.y - 2)])
	draw_colored_polygon(pts, ac)
