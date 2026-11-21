class_name TTConfetti
extends Node2D

# Door-enter celebration (EXCEED, 19 Nov 2026 — the reference has no
# celebration at all): on entering the door the hero's win bursts into
# small coloured squares (white / HUD yellow / HUD dark-red only —
# the palette discipline's allowed accent colours) that fly up/out,
# fall with gravity and fade over ~0.9s. Draw-only: no collision, no
# gameplay effect. `alive_count` exposes the live piece count for
# probes; `active` is true while any piece lives.
#
# EFFEKSEER (Lane 7, v1.0.5): the burst is drawn by the authored
# res://assets/effects/door_confetti.efkefc, spawned once per tint
# (white / yellow / dark-red, 12 pieces each == 36). `alive_count`
# mirrors the live Effekseer pieces (12 per playing emitter). If the
# plugin or the effect is unavailable, spawn_burst falls back to the
# code-drawn burst below — never a crash, never a missing burst.

const PIECE_N := 36
const PIECE_LIFE := 0.9
const PIECES_PER_SPAWN := 12

const COLOURS: Array[Color] = [
	Color(1, 1, 1),
	Color(1.0, 0.824, 0.247),
	Color(0.43, 0.04, 0.04),
]

var _pieces: Array = []
var alive_count := 0
var active := false
var _fx_mode := false
var _emitters: Array = []


func _init() -> void:
	# Above level art + hero, below the HUD (100).
	z_index = 60


func spawn_burst(at: Vector2) -> void:
	_pieces = []
	_emitters = []
	_fx_mode = false
	# Effekseer first (one 12-piece spawn per tint); the code burst
	# below stays as the fallback.
	var fx := EffekseerFX.confetti_effect()
	if fx != null:
		var ok := true
		for tint in EffekseerFX.CONFETTI_COLOURS:
			var e := EffekseerFX.spawn_one_shot(fx, self, to_local(at), tint)
			if e == null:
				ok = false
				break
			_emitters.append(e)
		if ok:
			_fx_mode = true
			alive_count = PIECE_N
			active = true
			set_process(true)
			queue_redraw()
			return
		_emitters = []
	var rng := RandomNumberGenerator.new()
	rng.seed = int(Time.get_ticks_msec()) + int(at.x) * 7 + int(at.y) * 13
	for i in range(PIECE_N):
		var ang := rng.randf_range(-PI * 0.9, -PI * 0.1)
		var speed := rng.randf_range(150.0, 550.0)
		_pieces.append({
			"pos": at,
			"vel": Vector2(cos(ang), sin(ang)) * speed,
			"size": rng.randf_range(5.0, 9.0),
			"life": PIECE_LIFE * rng.randf_range(0.7, 1.0),
			"max_life": PIECE_LIFE,
			"col": COLOURS[rng.randi_range(0, COLOURS.size() - 1)],
		})
	alive_count = _pieces.size()
	active = true
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	if _fx_mode:
		# Effekseer draws; mirror its live state for probes.
		var n := 0
		for e in _emitters:
			if is_instance_valid(e) and bool(e.call("is_playing")):
				n += PIECES_PER_SPAWN
		alive_count = n
		if n == 0:
			active = false
			_emitters = []
			set_process(false)
		return
	if _pieces.is_empty():
		active = false
		alive_count = 0
		set_process(false)
		return
	var keep: Array = []
	for p in _pieces:
		var d: Dictionary = p
		d["vel"] = (d["vel"] as Vector2) + Vector2(0, 700.0) * delta
		d["pos"] = (d["pos"] as Vector2) + (d["vel"] as Vector2) * delta
		d["life"] = float(d["life"]) - delta
		if float(d["life"]) > 0.0:
			keep.append(d)
	_pieces = keep
	alive_count = _pieces.size()
	if _pieces.is_empty():
		active = false
		set_process(false)
	queue_redraw()


func _draw() -> void:
	if _fx_mode:
		return  # Effekseer draws the burst; nothing to draw here.
	for p in _pieces:
		var d: Dictionary = p
		var s := float(d["size"])
		var pos: Vector2 = d["pos"]
		var col: Color = d["col"]
		col.a = clampf(float(d["life"]) / float(d["max_life"]), 0.0, 1.0)
		draw_rect(Rect2(pos - Vector2(s * 0.5, s * 0.5), Vector2(s, s)), col)
