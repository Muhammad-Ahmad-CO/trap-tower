class_name TTCoin
extends Node2D

# Coin collectible (Lane U1, M1). Own art, code-drawn like the
# hero/star: a small round gold coin with a darker outline ring, an
# embossed inner ring and a gentle pulse + glint. Deliberately
# distinct from the official's coin art (round coin, no copied
# sprite) and from the star (5-point, r15): this is a plain circle,
# r10. No collision body, no physics: the game polls collect_rect()
# against the hero rect. Collecting is optional and can never block
# the door/exit. No HUD coin counter (the official has none).
# Coins live in the level dict (`coins: [{x, y}]`, D04 only) and are
# built by TTBuilder; persistence is `coins_collected` in TTProgress
# (ids "L015:0" = level id + coin index).

const COIN_R := 10.0

var centre := Vector2.ZERO
var collected := false
var _t := 0.0


func setup(pos: Vector2) -> void:
	centre = pos
	position = pos
	z_index = 15


func collect_rect() -> Rect2:
	return Rect2(centre - Vector2(COIN_R, COIN_R), Vector2(COIN_R * 2.0, COIN_R * 2.0))


func _process(delta: float) -> void:
	if collected:
		return
	_t += delta
	queue_redraw()


func _draw() -> void:
	if collected:
		return
	var pulse := 1.0 + 0.06 * sin(_t * 3.0)
	var r := COIN_R * pulse
	# Darker outline ring first, then the bright gold face.
	draw_circle(Vector2.ZERO, r + 1.5, Color.html("B45309"))
	draw_circle(Vector2.ZERO, r, Color.html("FFD23F"))
	# Embossed inner ring (darker gold arc): the coin's own detail,
	# drawn, not a sprite.
	draw_arc(Vector2.ZERO, r * 0.55, 0.0, TAU, 24, Color.html("D97706"), 2.0, true)
	# Glint: a small white 4-point sparkle, upper-left, fading in/out.
	var a := 0.30 + 0.30 * sin(_t * 3.0 + 1.0)
	var g := 4.0
	var c := Vector2(-r * 0.35, -r * 0.35)
	var glint := PackedVector2Array([
		c + Vector2(0, -g), c + Vector2(g * 0.25, -g * 0.25), c + Vector2(g, 0),
		c + Vector2(g * 0.25, g * 0.25), c + Vector2(0, g), c + Vector2(-g * 0.25, g * 0.25),
		c + Vector2(-g, 0), c + Vector2(-g * 0.25, -g * 0.25)])
	draw_colored_polygon(glint, Color(1, 1, 1, a))
