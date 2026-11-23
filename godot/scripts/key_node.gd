class_name TTKey
extends Node2D

# Hidden-key collectible (Lane U4, M2). Own art, code-drawn like the
# hero/star/coin: a small gold key lying flat — a round bow (ring) on
# the left, a straight shaft, two teeth at the right end — with a
# darker outline and a gentle pulse + glint. Deliberately distinct
# from the official's key art (no copied sprite) and from the star
# (5-point, r15) and the coin (plain circle, r10): this is a KEY
# shape, ~30 px wide. No collision body, no physics: the game polls
# collect_rect() against the hero rect. Collecting is optional and
# can never block the door/exit. No HUD key counter beyond the
# skull n/5 (the official's counter — one key per chapter slot).
# Keys live in the level dict (`keys: [{x, y}]`, 15 levels, 5 per
# chapter) and are spawned by game.gd like stars; persistence is
# `keys_collected` in TTProgress (ids "L016:0" = level id + key index).

const KEY_R := 14.0

var centre := Vector2.ZERO
var collected := false
var _t := 0.0


func setup(pos: Vector2) -> void:
	centre = pos
	position = pos
	z_index = 15


func collect_rect() -> Rect2:
	return Rect2(centre - Vector2(KEY_R, KEY_R), Vector2(KEY_R * 2.0, KEY_R * 2.0))


func _process(delta: float) -> void:
	if collected:
		return
	_t += delta
	queue_redraw()


func _draw() -> void:
	if collected:
		return
	var pulse := 1.0 + 0.06 * sin(_t * 3.0)
	# Bow: a ring at the left (centre x -9), drawn as two arcs so
	# the dark outline shows on both sides of the gold ring.
	var bow := Vector2(-9.0, 0.0) * pulse
	var r := 6.0 * pulse
	draw_arc(bow, r, 0.0, TAU, 20, Color.html("B45309"), 4.5, true)
	draw_arc(bow, r, 0.0, TAU, 20, Color.html("FFD23F"), 2.5, true)
	# Shaft: dark under-stroke, then gold, from the bow to the teeth.
	var a := Vector2(-3.5, 0.0) * pulse
	var b := Vector2(12.0, 0.0) * pulse
	draw_line(a, b, Color.html("B45309"), 5.0, true)
	draw_line(a, b, Color.html("FFD23F"), 3.0, true)
	# Teeth: two short bars hanging below the shaft near its end.
	# Dark outline rect first, gold inset on top of it.
	for tooth in [Vector4(6.0, 0.0, 3.5, 7.0), Vector4(10.5, 0.0, 3.5, 5.0)]:
		var tr := Rect2(tooth.x * pulse, tooth.y * pulse,
				tooth.z * pulse, tooth.w * pulse)
		draw_rect(tr, Color.html("B45309"))
		draw_rect(Rect2(tr.position + Vector2(0.75, 0.0),
				Vector2(tr.size.x - 1.5, tr.size.y - 0.75)), Color.html("FFD23F"))
	# Glint: a small white 4-point sparkle on the bow, fading in/out.
	var ga := 0.30 + 0.30 * sin(_t * 3.0 + 1.0)
	var g := 4.0
	var c := bow + Vector2(-1.0, -1.0)
	var glint := PackedVector2Array([
		c + Vector2(0, -g), c + Vector2(g * 0.25, -g * 0.25), c + Vector2(g, 0),
		c + Vector2(g * 0.25, g * 0.25), c + Vector2(0, g), c + Vector2(-g * 0.25, g * 0.25),
		c + Vector2(-g, 0), c + Vector2(-g * 0.25, -g * 0.25)])
	draw_colored_polygon(glint, Color(1, 1, 1, ga))
