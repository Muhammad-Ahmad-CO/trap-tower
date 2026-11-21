class_name TTDeathParticles
extends Node2D

# Death particle burst (LEVEL_SCHEMA.md v3): on death the hero vanishes
# in a burst of small black squares (~6-10px, scattered up/out, ~0.3s).
# EXCEED (19 Nov 2026): snappier + bigger than the match-phase burst
# (coordinator: the old 14-piece cluster read modest): 30 pieces,
# 8-16px, 200-700 px/s, 0.45s life, harder gravity. Draw-only: no
# collision, no gameplay effect. `alive_count` exposes the live
# particle count for probes; `active` is true while any particle lives.
#
# EFFEKSEER (Lane 7, v1.0.5): the burst is drawn by the authored
# res://assets/effects/death_burst.efkefc (30 black squares, same motion
# model as the code burst). `alive_count` mirrors the live Effekseer
# particles (30 while the emitter plays, 0 when done). If the plugin or
# the effect is unavailable, spawn_burst falls back to the code-drawn
# burst below — never a crash, never a missing burst.

const BURST_N := 30
const BURST_LIFE := 0.45

var _parts: Array = []
var alive_count := 0
var active := false
var _fx_mode := false
var _emitter: Node = null


func _init() -> void:
	# Above level art + hero, below the HUD (100) and death prompt (80).
	z_index = 60


func spawn_burst(at: Vector2) -> void:
	_parts = []
	_emitter = null
	_fx_mode = false
	# Effekseer first; the code burst below stays as the fallback.
	var fx := EffekseerFX.death_effect()
	if fx != null:
		var e := EffekseerFX.spawn_one_shot(fx, self, to_local(at), Color(1, 1, 1))
		if e != null:
			_emitter = e
			_fx_mode = true
			alive_count = BURST_N
			active = true
			set_process(true)
			queue_redraw()
			return
	var rng := RandomNumberGenerator.new()
	rng.seed = int(Time.get_ticks_msec()) + int(at.x) * 7 + int(at.y) * 13
	for i in range(BURST_N):
		var ang := rng.randf_range(-PI * 0.85, -PI * 0.15)
		var speed := rng.randf_range(200.0, 700.0)
		_parts.append({
			"pos": at,
			"vel": Vector2(cos(ang), sin(ang)) * speed,
			"size": rng.randf_range(8.0, 16.0),
			"life": BURST_LIFE * rng.randf_range(0.8, 1.0),
		})
	alive_count = _parts.size()
	active = true
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	if _fx_mode:
		# Effekseer draws; mirror its live state for probes.
		if _emitter != null and is_instance_valid(_emitter) and bool(_emitter.call("is_playing")):
			alive_count = BURST_N
			return
		alive_count = 0
		active = false
		_emitter = null
		set_process(false)
		return
	if _parts.is_empty():
		active = false
		alive_count = 0
		set_process(false)
		return
	var keep: Array = []
	for p in _parts:
		var d: Dictionary = p
		d["vel"] = (d["vel"] as Vector2) + Vector2(0, 1200.0) * delta
		d["pos"] = (d["pos"] as Vector2) + (d["vel"] as Vector2) * delta
		d["life"] = float(d["life"]) - delta
		if float(d["life"]) > 0.0:
			keep.append(d)
	_parts = keep
	alive_count = _parts.size()
	if _parts.is_empty():
		active = false
		set_process(false)
	queue_redraw()


func _draw() -> void:
	if _fx_mode:
		return  # Effekseer draws the burst; nothing to draw here.
	for p in _parts:
		var d: Dictionary = p
		var s := float(d["size"])
		var pos: Vector2 = d["pos"]
		draw_rect(Rect2(pos - Vector2(s * 0.5, s * 0.5), Vector2(s, s)), Color(0, 0, 0))
