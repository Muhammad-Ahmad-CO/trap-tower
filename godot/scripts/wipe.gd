class_name TTWipe
extends Control

# ORIGINAL wipe transition (LEVEL_SCHEMA.md v3): two dark-red panels
# slide in from the top and bottom edges to cover the screen, then
# slide back out to reveal — with a thin yellow leading edge. Our own
# design (NOT the reference's mouth shape). Duration ~0.25s total.
# Usage: add as a child of the scene root, call cover() then (after
# the scene change, in the new scene) reveal(). Both are awaitable:
# `await wipe.cover()` / `await wipe.reveal()`. Never blocks input
# (mouse_filter IGNORE); process_mode ALWAYS so it animates across
# pause boundaries.

signal cover_finished
signal reveal_finished

const DARK_RED := Color(0.43, 0.04, 0.04)
const YELLOW := Color(1.0, 0.824, 0.247)

var _frac := 0.0
var _animating := false
var _anim_t := 0.0
var _anim_dur := 0.12
var _anim_dir := 0  # +1 covering, -1 revealing


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = Vector2(1280, 720)
	z_index = 200


# Slide the panels in (0 -> covered). Resolves when fully covered.
func cover(dur: float = 0.12) -> void:
	_animating = true
	_anim_t = 0.0
	_anim_dur = maxf(0.01, dur)
	_anim_dir = 1
	set_process(true)
	await cover_finished


# Slide the panels out (covered -> 0). Resolves when fully revealed.
func reveal(dur: float = 0.13) -> void:
	_frac = 1.0
	_animating = true
	_anim_t = 0.0
	_anim_dur = maxf(0.01, dur)
	_anim_dir = -1
	set_process(true)
	queue_redraw()
	await reveal_finished


func _process(delta: float) -> void:
	if not _animating:
		set_process(false)
		return
	_anim_t += delta
	var f := clampf(_anim_t / _anim_dur, 0.0, 1.0)
	# Ease-out for cover, ease-in for reveal: fast start, soft landing.
	var e := 1.0 - (1.0 - f) * (1.0 - f) if _anim_dir == 1 else f * f
	_frac = e if _anim_dir == 1 else 1.0 - e
	queue_redraw()
	if f >= 1.0:
		_animating = false
		set_process(false)
		if _anim_dir == 1:
			cover_finished.emit()
		else:
			reveal_finished.emit()


func _draw() -> void:
	if _frac <= 0.0:
		return
	var half := 360.0 * _frac
	# Top panel slides down from y=0; bottom panel slides up from y=720.
	draw_rect(Rect2(0, 0, 1280, half), DARK_RED)
	draw_rect(Rect2(0, 720 - half, 1280, half), DARK_RED)
	if _frac < 1.0:
		# Thin yellow leading edges where the panels meet the scene.
		draw_rect(Rect2(0, half - 2.0, 1280, 4.0), YELLOW)
		draw_rect(Rect2(0, 720 - half - 2.0, 1280, 4.0), YELLOW)
