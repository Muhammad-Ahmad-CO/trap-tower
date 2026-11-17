class_name TTPlatform
extends AnimatableBody2D

# One node for all platform kinds, driven only by declarative level params.
# solid: static. dashed: blinking solid/faint. falling/tilting: drops after
# stand_time (no respawn until restart). moving: sine round trip, carries player.

var kind := "solid"
var rect := Rect2()
var plat_col := Color.WHITE
var period := 0.0
var phase := 0.0
var on_time := 0.0
var stand_time := 0.0
var move_offset := Vector2.ZERO
var gravity := 2200.0
var elapsed := 0.0
var start_pos := Vector2.ZERO
var falling := false
var fall_vy := 0.0
var stand_timer := 0.0
var solid_now := true
var player: TTPlayer = null
var _shape: CollisionShape2D = null


func setup(d: Dictionary, color: Color, p_gravity: float) -> void:
	kind = str(d.get("kind", "solid"))
	rect = Rect2(float(d["x"]), float(d["y"]), float(d["w"]), float(d["h"]))
	plat_col = color
	# Drawing only: platforms are the bottom layer; hazards (z 10),
	# the door (z 1) and the player render above them.
	z_index = 0
	gravity = p_gravity
	period = float(d.get("period", 0.0))
	phase = float(d.get("phase", 0.0))
	on_time = float(d.get("on_time", 0.0))
	stand_time = float(d.get("stand_time", 0.0))
	move_offset = Vector2(float(d.get("dx", 0.0)), float(d.get("dy", 0.0)))
	position = rect.get_center()
	start_pos = position
	_shape = CollisionShape2D.new()
	var rs := RectangleShape2D.new()
	rs.size = rect.size
	_shape.shape = rs
	add_child(_shape)
	collision_layer = 1
	collision_mask = 0
	sync_to_physics = true


func reset_state() -> void:
	elapsed = 0.0
	falling = false
	fall_vy = 0.0
	stand_timer = 0.0
	solid_now = true
	rotation = 0.0
	position = start_pos
	if _shape != null:
		_shape.disabled = false
	queue_redraw()


func _physics_process(delta: float) -> void:
	elapsed += delta
	if kind == "dashed" and period > 0.0:
		solid_now = fposmod(elapsed - phase, period) < on_time
		_shape.disabled = not solid_now
		queue_redraw()
	elif kind == "falling" or kind == "tilting":
		if not falling:
			if _player_standing():
				stand_timer += delta
				if stand_timer >= stand_time:
					falling = true
			else:
				stand_timer = 0.0
		if falling:
			fall_vy += gravity * delta
			position.y += fall_vy * delta
			if kind == "tilting":
				rotation += delta * 0.9
			if position.y - rect.size.y * 0.5 > 660.0:
				_shape.disabled = true
			queue_redraw()
	elif kind == "moving" and period > 0.0:
		var f := 0.5 - 0.5 * cos(TAU * fposmod(elapsed, period) / period)
		position = start_pos + move_offset * f


func _player_standing() -> bool:
	if player == null:
		return false
	if not player.is_on_floor():
		return false
	var top := position.y - rect.size.y * 0.5
	if absf(player.feet_pos().y - top) > 4.0:
		return false
	return player.global_position.x >= position.x - rect.size.x * 0.5 and player.global_position.x <= position.x + rect.size.x * 0.5


func _draw() -> void:
	var r := Rect2(-rect.size * 0.5, rect.size)
	if kind == "dashed" and not solid_now:
		var faint := plat_col
		faint.a = 0.25
		draw_rect(r, faint)
		_draw_dashed_rect(r, plat_col)
	else:
		draw_rect(r, plat_col)
		if (kind == "falling" or kind == "tilting") and stand_timer > 0.0 and not falling:
			draw_rect(Rect2(r.position, Vector2(r.size.x, 4)), Color(0, 0, 0, 0.25))


func _draw_dashed_rect(r: Rect2, col: Color) -> void:
	var seg := 14.0
	var gap := 10.0
	var x := r.position.x
	while x < r.end.x:
		var x2 := minf(x + seg, r.end.x)
		draw_line(Vector2(x, r.position.y), Vector2(x2, r.position.y), col, 3.0)
		draw_line(Vector2(x, r.end.y), Vector2(x2, r.end.y), col, 3.0)
		x += seg + gap
	var y := r.position.y
	while y < r.end.y:
		var y2 := minf(y + seg, r.end.y)
		draw_line(Vector2(r.position.x, y), Vector2(r.position.x, y2), col, 3.0)
		draw_line(Vector2(r.end.x, y), Vector2(r.end.x, y2), col, 3.0)
		y += seg + gap
