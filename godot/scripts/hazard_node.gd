class_name TTHazard
extends Node2D

# ONE generic trap interpreter. Behaviour comes only from the declarative
# level dict: trigger_x/delay gating, pop-up period/phase/on_time, saw
# path/swing, hanging-pillar drop trigger or periodic cycle. No hidden timers.
# Node sits at origin; all drawing uses level-space coordinates.
# dotted_line is a visual warning only and never kills.

var htype := "spikes"
var rect := Rect2()
var trap_col := Color.WHITE
var dir := "up"
var radius := 30.0
var period := 0.0
var phase := 0.0
var on_time := 0.0
var has_period := false
var trigger_x := 0.0
var has_trigger := false
var delay := 0.0
var drop_trigger_x := 0.0
var has_drop_trigger := false
var drop_speed := 700.0
var path_end := Vector2.ZERO
var has_path := false
var swing_pivot := Vector2.ZERO
var swing_arc := 0.0
var swing_period := 0.0
var has_swing := false
var linked := -1
var bar_y := 580.0

var elapsed := 0.0
var triggered := false
var trigger_time := 0.0
var prev_player_x := 0.0
var player: TTPlayer = null
var saw_rest := Vector2.ZERO
var pillar_home := Vector2.ZERO
var pillar_offset := 0.0
var pillar_dropped := false
var pillar_hanging := true
var _solid_shape: CollisionShape2D = null


func setup(d: Dictionary, color: Color, p_player: TTPlayer, p_bar_y: float) -> void:
	htype = str(d.get("type", "spikes"))
	trap_col = color
	# Drawing only: hazards render above platforms (z 0) and the door (z 1).
	z_index = 10
	player = p_player
	bar_y = p_bar_y
	rect = Rect2(float(d["x"]), float(d["y"]), float(d["w"]), float(d["h"]))
	dir = str(d.get("dir", "up"))
	radius = float(d.get("r", 30.0))
	has_period = d.has("period")
	period = float(d.get("period", 0.0))
	phase = float(d.get("phase", 0.0))
	on_time = float(d.get("on_time", 0.0))
	has_trigger = d.has("trigger_x")
	trigger_x = float(d.get("trigger_x", 0.0))
	delay = float(d.get("delay", 0.0))
	has_drop_trigger = d.has("drop_trigger_x")
	drop_trigger_x = float(d.get("drop_trigger_x", 0.0))
	drop_speed = float(d.get("drop_speed", 700.0))
	linked = int(d.get("linked", -1))
	if htype == "saw":
		saw_rest = Vector2(float(d["x"]), float(d["y"]))
		if d.has("path"):
			var path: Dictionary = d["path"]
			path_end = Vector2(float(path["x2"]), float(path["y2"]))
			has_path = true
		if d.has("swing"):
			var sw: Dictionary = d["swing"]
			swing_pivot = Vector2(float(sw["pivot_x"]), float(sw["pivot_y"]))
			swing_arc = float(sw["arc_deg"])
			swing_period = float(sw["period"])
			has_swing = true
	if htype == "hanging_pillar":
		pillar_home = rect.position
		var body := StaticBody2D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		_solid_shape = CollisionShape2D.new()
		var rs := RectangleShape2D.new()
		rs.size = rect.size
		_solid_shape.shape = rs
		body.add_child(_solid_shape)
		body.position = rect.get_center()
		add_child(body)
	if player != null:
		prev_player_x = player.global_position.x


func reset_state() -> void:
	elapsed = 0.0
	triggered = false
	trigger_time = 0.0
	pillar_dropped = false
	pillar_offset = 0.0
	pillar_hanging = true
	if player != null:
		prev_player_x = player.global_position.x
	if _solid_shape != null:
		_solid_shape.disabled = false
		var body := _solid_shape.get_parent() as StaticBody2D
		if body != null:
			body.position = rect.get_center()
	queue_redraw()


func _physics_process(delta: float) -> void:
	elapsed += delta
	if player != null:
		var px := player.global_position.x
		if has_trigger and not triggered:
			if (prev_player_x - trigger_x) * (px - trigger_x) <= 0.0 and px != prev_player_x:
				triggered = true
				trigger_time = elapsed
		if has_drop_trigger and not pillar_dropped:
			if (prev_player_x - drop_trigger_x) * (px - drop_trigger_x) <= 0.0 and px != prev_player_x:
				pillar_dropped = true
				trigger_time = elapsed
		prev_player_x = px
	if htype == "hanging_pillar":
		_update_pillar()
	if htype == "saw" or htype == "spikes" or htype == "hanging_pillar":
		queue_redraw()


func _update_pillar() -> void:
	var drop_dist := maxf(0.0, bar_y - (pillar_home.y + rect.size.y))
	if has_drop_trigger:
		if pillar_dropped:
			pillar_offset = minf(drop_dist, drop_speed * maxf(0.0, elapsed - trigger_time))
			pillar_hanging = false
		else:
			pillar_offset = 0.0
			pillar_hanging = true
	elif has_period and period > 0.0:
		var drop_time := drop_dist / drop_speed if drop_speed > 0.0 else 0.0
		var hang_time := maxf(0.0, period - drop_time - 1.0)
		var cyc := fposmod(elapsed - phase, period)
		if cyc < hang_time:
			pillar_offset = 0.0
			pillar_hanging = true
		elif cyc < hang_time + drop_time:
			pillar_offset = drop_speed * (cyc - hang_time)
			pillar_hanging = false
		else:
			var frac := (cyc - hang_time - drop_time) / 1.0
			pillar_offset = drop_dist * (1.0 - minf(1.0, frac))
			pillar_hanging = false
	if _solid_shape != null:
		_solid_shape.disabled = not pillar_hanging
		var body := _solid_shape.get_parent() as StaticBody2D
		if body != null:
			body.position = rect.get_center() + Vector2(0, pillar_offset)


func saw_centre_now() -> Vector2:
	if has_path and period > 0.0:
		var f := 0.5 - 0.5 * cos(TAU * fposmod(elapsed, period) / period)
		return saw_rest.lerp(path_end, f)
	if has_swing and swing_period > 0.0:
		var ang := deg_to_rad(swing_arc) * 0.5 * sin(TAU * elapsed / swing_period)
		return swing_pivot + (saw_rest - swing_pivot).rotated(ang)
	return saw_rest


func popup_up() -> bool:
	if not has_period or period <= 0.0:
		return true
	return fposmod(elapsed - phase, period) < on_time


func trigger_active() -> bool:
	if not has_trigger:
		return true
	return triggered and elapsed >= trigger_time + delay


func kills(prect: Rect2) -> bool:
	if htype == "dotted_line":
		return false
	if not trigger_active():
		return false
	if htype == "spikes":
		if has_period and not popup_up():
			return false
		return rect.intersects(prect)
	if htype == "saw":
		return _circle_rect(saw_centre_now(), radius, prect)
	if htype == "spiked_column":
		return rect.intersects(prect)
	if htype == "hanging_pillar":
		if pillar_hanging:
			return false
		var r := Rect2(pillar_home + Vector2(0, pillar_offset), rect.size)
		return r.intersects(prect)
	return false


func _circle_rect(c: Vector2, r: float, r2: Rect2) -> bool:
	var dx := maxf(r2.position.x - c.x, 0.0)
	dx = maxf(dx, c.x - r2.end.x)
	var dy := maxf(r2.position.y - c.y, 0.0)
	dy = maxf(dy, c.y - r2.end.y)
	return Vector2(dx, dy).length() < r


func _draw() -> void:
	if htype == "spikes":
		_draw_spikes()
	elif htype == "saw":
		_draw_saw()
	elif htype == "spiked_column":
		_draw_column()
	elif htype == "hanging_pillar":
		_draw_pillar()
	elif htype == "dotted_line":
		_draw_dotted()


func _draw_spikes() -> void:
	var up := popup_up()
	var h_scale := 1.0 if up else 0.25
	var col := trap_col
	if has_period and not up:
		col = Color(trap_col.r, trap_col.g, trap_col.b, 0.45)
	if dir == "up" or dir == "down":
		var n := maxi(1, int(rect.size.x / 18.0))
		var tw := rect.size.x / n
		for i in range(n):
			var x0 := rect.position.x + i * tw
			var pts := PackedVector2Array()
			if dir == "up":
				pts = PackedVector2Array([Vector2(x0, rect.end.y), Vector2(x0 + tw, rect.end.y), Vector2(x0 + tw * 0.5, rect.end.y - rect.size.y * h_scale)])
			else:
				pts = PackedVector2Array([Vector2(x0, rect.position.y), Vector2(x0 + tw, rect.position.y), Vector2(x0 + tw * 0.5, rect.position.y + rect.size.y * h_scale)])
			draw_colored_polygon(pts, col)
	else:
		var n2 := maxi(1, int(rect.size.y / 18.0))
		var th := rect.size.y / n2
		for i in range(n2):
			var y0 := rect.position.y + i * th
			var pts2 := PackedVector2Array()
			if dir == "left":
				pts2 = PackedVector2Array([Vector2(rect.end.x, y0), Vector2(rect.end.x, y0 + th), Vector2(rect.end.x - rect.size.x * h_scale, y0 + th * 0.5)])
			else:
				pts2 = PackedVector2Array([Vector2(rect.position.x, y0), Vector2(rect.position.x, y0 + th), Vector2(rect.position.x + rect.size.x * h_scale, y0 + th * 0.5)])
			draw_colored_polygon(pts2, col)


func _draw_saw() -> void:
	# Full toothed disc: outer tips sit exactly on the lethal circle
	# (centre + radius from level data, same values kills() uses).
	# The whole disc is drawn; z_index 10 keeps it above floor platforms.
	# Centre, radius and hitbox are unchanged.
	var c := saw_centre_now()
	var teeth := 18
	var pts := PackedVector2Array()
	for i in range(teeth * 2):
		var ang := TAU * float(i) / float(teeth * 2)
		var rr := radius if i % 2 == 0 else radius * 0.78
		pts.append(c + Vector2(cos(ang), sin(ang)) * rr)
	draw_colored_polygon(pts, trap_col)


func _draw_column() -> void:
	draw_rect(rect, trap_col)
	var n := maxi(1, int(rect.size.y / 18.0))
	var th := rect.size.y / n
	for i in range(n):
		var y0 := rect.position.y + i * th
		var ym := y0 + th * 0.5
		draw_colored_polygon(PackedVector2Array([Vector2(rect.position.x, y0), Vector2(rect.position.x, y0 + th), Vector2(rect.position.x - 10, ym)]), trap_col)
		draw_colored_polygon(PackedVector2Array([Vector2(rect.end.x, y0), Vector2(rect.end.x, y0 + th), Vector2(rect.end.x + 10, ym)]), trap_col)


func _draw_pillar() -> void:
	var top := pillar_home.y + pillar_offset
	var cx := pillar_home.x + rect.size.x * 0.5
	if pillar_hanging:
		draw_line(Vector2(cx, 0), Vector2(cx, top), trap_col, 3.0)
	draw_rect(Rect2(pillar_home.x, top, rect.size.x, rect.size.y), trap_col)


func _draw_dotted() -> void:
	var step := 14.0
	if rect.size.x >= rect.size.y:
		var y := rect.get_center().y
		var x := rect.position.x + 4.0
		while x <= rect.end.x:
			draw_circle(Vector2(x, y), 3.0, trap_col)
			x += step
	else:
		var x2 := rect.get_center().x
		var y2 := rect.position.y + 4.0
		while y2 <= rect.end.y:
			draw_circle(Vector2(x2, y2), 3.0, trap_col)
			y2 += step
