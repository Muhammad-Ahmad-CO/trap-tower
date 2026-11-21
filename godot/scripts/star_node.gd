class_name TTStar
extends Node2D

# Hidden-star collectible (Lane F1). Own art, code-drawn like the
# hero/chevrons: a 5-point gold star with a darker outline and a
# gentle pulse + sparkle. No collision body, no physics: the game
# polls collect_rect() against the hero rect. Collecting is
# optional and can never block the door/exit.

const STAR_R := 14.0

var centre := Vector2.ZERO
var collected := false
var _t := 0.0


func setup(pos: Vector2) -> void:
	centre = pos
	position = pos
	z_index = 15


func collect_rect() -> Rect2:
	return Rect2(centre - Vector2(STAR_R, STAR_R), Vector2(STAR_R * 2.0, STAR_R * 2.0))


func _process(delta: float) -> void:
	if collected:
		return
	_t += delta
	queue_redraw()


static func star_points(r_out: float, r_in: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(10):
		var r := r_out if i % 2 == 0 else r_in
		var ang := -PI * 0.5 + float(i) * PI / 5.0
		pts.append(Vector2(cos(ang), sin(ang)) * r)
	return pts


func _draw() -> void:
	if collected:
		return
	var pulse := 1.0 + 0.08 * sin(_t * 3.0)
	var outer := 15.0 * pulse
	var inner := 6.5 * pulse
	# Darker outline first (slightly larger star), then the gold fill.
	draw_colored_polygon(star_points(outer + 2.0, inner + 1.5), Color.html("B45309"))
	draw_colored_polygon(star_points(outer, inner), Color.html("FFD23F"))
	# Sparkle: a small white 4-point glint that fades in/out.
	var a := 0.35 + 0.35 * sin(_t * 3.0 + 1.0)
	var g := 5.0
	var glint := PackedVector2Array([
		Vector2(0, -g), Vector2(g * 0.25, -g * 0.25), Vector2(g, 0),
		Vector2(g * 0.25, g * 0.25), Vector2(0, g), Vector2(-g * 0.25, g * 0.25),
		Vector2(-g, 0), Vector2(-g * 0.25, -g * 0.25)])
	draw_colored_polygon(glint, Color(1, 1, 1, a))
