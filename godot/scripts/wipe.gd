class_name TTWipe
extends Control

# ORIGINAL jaw-close transition (LEVEL_SCHEMA.md v3): two dark-red
# full-width panels slide in from the top and bottom edges to cover
# the screen, then slide back out to reveal. The panels stay FULL-WIDTH
# RECTANGLES; the only jaw feature is SEMICIRCULAR bumps (rounded
# teeth) on the panels' leading edges, top row offset half a pitch from
# the bottom row so the teeth interlock at full close. Our own design
# (NOT the reference's mouth shape): no triangular / pointed / jagged
# teeth, no fangs, no lips, no tongue, no saliva, no inner-mouth cavity
# colour, no eyes, no jaw outline beyond the panel rectangles, no
# separate mouth sprite. Duration ~0.25s total.
# Yellow rule (decided, so it cannot drift into a lip): a 4px yellow
# line is drawn ONLY as (a) the panels' leading edges while moving
# (_frac < 1.0), and (b) ONE 4px seam centred on the meeting line
# (y 358-362) at full close, drawn BEFORE the teeth so it shows only
# as short dashes between the interlocked bumps — never a continuous
# band, never a lip shape.
# Usage: add as a child of the scene root, call cover() then (after
# the scene change, in the new scene) reveal(). Both are awaitable:
# `await wipe.cover()` / `await wipe.reveal()`. Never blocks input
# (mouse_filter IGNORE); process_mode ALWAYS so it animates across
# pause boundaries.

signal cover_finished
signal reveal_finished

const DARK_RED := Color(0.43, 0.04, 0.04)
const YELLOW := Color(1.0, 0.824, 0.247)

# Jaw teeth: semicircular bumps on the leading edges only.
# Radius 26, pitch 128 (10 top teeth, 11 bottom teeth incl. the two
# half-clipped edge teeth); bottom row offset half a pitch (64) so the
# rows interlock at close. Adjacent top/bottom tooth centres are 64
# apart while 2 * radius is 52, so a 12 px slot stays open at the
# meeting line — that slot is where the yellow seam shows through.
# (Radius 32 closed the slot exactly and hid the seam entirely;
# verified on the captured fully-covered frame, then fixed.)
const TOOTH_R := 26.0
const TOOTH_PITCH := 128.0
const TOOTH_TOP_FIRST_X := 64.0
const TOOTH_BOTTOM_FIRST_X := 0.0

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
	# Panels stay full-width rectangles — no jaw-shaped silhouette.
	draw_rect(Rect2(0, 0, 1280, half), DARK_RED)
	draw_rect(Rect2(0, 720 - half, 1280, half), DARK_RED)
	if _frac < 1.0:
		# Thin yellow leading edges where the panels meet the scene.
		draw_rect(Rect2(0, half - 2.0, 1280, 4.0), YELLOW)
		draw_rect(Rect2(0, 720 - half - 2.0, 1280, 4.0), YELLOW)
	else:
		# ONE 4px seam on the tooth-meeting line (y 358-362), drawn
		# BEFORE the teeth: visible only as dashes between the bumps.
		draw_rect(Rect2(0, 358.0, 1280, 4.0), YELLOW)
	# Semicircular teeth on the leading edges, drawn last in the same
	# dark red as the panels (each circle's inner half merges with its
	# panel; only the bump protrudes).
	_draw_teeth(half, true)
	_draw_teeth(half, false)


# One row of semicircular bumps centred on a panel's leading edge.
# Top row starts at x=64, bottom row at x=0 (half-pitch offset, so the
# rows interlock at full close instead of meeting tip-to-tip).
func _draw_teeth(half: float, is_top: bool) -> void:
	var y := half if is_top else 720.0 - half
	var x := TOOTH_TOP_FIRST_X if is_top else TOOTH_BOTTOM_FIRST_X
	while x <= 1280.0:
		draw_circle(Vector2(x, y), TOOTH_R, DARK_RED)
		x += TOOTH_PITCH
