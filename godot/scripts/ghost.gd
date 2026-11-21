class_name TTGhost
extends Node2D

# Lane F3 (v1.0.5 Part B): the ghost run. VISUAL ONLY by construction:
# a plain Node2D with no CollisionShape2D, no physics body, no
# collision layer/mask, no input — it can never touch the hero,
# hazards, platforms or the door, and it never blocks the floor
# (a 15x39 translucent silhouette, drawn under the HUD).
#
# Samples: Array of Vector3(x, y, facing), centre origin like the
# hero (player.global_position), recorded at 10 Hz by game.gd.
# Playback is driven from outside: the game node sets
# `playback_time` to the current attempt time every frame, so the
# ghost replays the recorded path in sync with the attempt clock
# (death/retry resets both together). Facing comes from the sample
# so the silhouette mirrors the recorded run.

const SAMPLE_DT := 0.1
const MAX_SAMPLES := 600  # 60 s at 10 Hz; longer runs truncate.
const GHOST_COL := Color(0.55, 0.85, 1.0, 0.50)
const GHOST_EDGE := Color(1.0, 1.0, 1.0, 0.35)

# Same body proportions as the hero (player.gd pw 15, ph 39).
const PW := 15.0
const PH := 39.0

var samples: Array = []
var playback_time := 0.0
var ghost_visible := true


func set_samples(p_samples: Array) -> void:
	samples = p_samples.duplicate()
	playback_time = 0.0
	visible = ghost_visible and not samples.is_empty()
	queue_redraw()


func set_ghost_visible(v: bool) -> void:
	ghost_visible = v
	visible = ghost_visible and not samples.is_empty()
	queue_redraw()


# Position the ghost would be at `t` seconds into the recording
# (clamped to the last sample). Used by the probe to assert the
# ghost follows the recorded path; the draw code uses the same math.
func position_at(t: float) -> Vector2:
	if samples.is_empty():
		return Vector2.ZERO
	var idx := clampi(int(t / SAMPLE_DT), 0, samples.size() - 1)
	var s: Vector3 = samples[idx]
	return Vector2(s.x, s.y)


func facing_at(t: float) -> int:
	if samples.is_empty():
		return 1
	var idx := clampi(int(t / SAMPLE_DT), 0, samples.size() - 1)
	var s: Vector3 = samples[idx]
	return 1 if s.z >= 0.0 else -1


func _process(_delta: float) -> void:
	if visible and not samples.is_empty():
		queue_redraw()


func _draw() -> void:
	if samples.is_empty() or not ghost_visible:
		return
	var idx := clampi(int(playback_time / SAMPLE_DT), 0, samples.size() - 1)
	var s: Vector3 = samples[idx]
	var facing := 1 if s.z >= 0.0 else -1
	# Draw in LOCAL space at the sample position (the node itself
	# sits at the origin of the game scene, so local == global).
	var feet_y := PH * 0.5
	var head_c := Vector2(s.x, s.y - feet_y + 6.0)
	var torso_tl := Vector2(s.x - 5.0, s.y - 8.0)
	var torso_br := Vector2(s.x + 5.0, s.y + 6.0)
	# Faint halo first so the ghost reads as a ghost on any palette.
	draw_circle(head_c, 8.0, GHOST_EDGE)
	draw_circle(Vector2(s.x, s.y), 24.0, Color(0.55, 0.85, 1.0, 0.08))
	# Legs (same swing-free standing pose as the hero at rest):
	# hips at +5, feet planted at +PH/2, exactly the hero's rect.
	draw_line(Vector2(s.x - 3.0, s.y + 5.0), Vector2(s.x - 3.0, s.y + PH * 0.5), GHOST_COL, 4.0)
	draw_line(Vector2(s.x + 3.0, s.y + 5.0), Vector2(s.x + 3.0, s.y + PH * 0.5), GHOST_COL, 4.0)
	draw_rect(Rect2(torso_tl, torso_br - torso_tl), GHOST_COL)
	# Arm reaching in the recorded facing direction.
	draw_line(Vector2(s.x, s.y - 4.0), Vector2(s.x + float(facing) * 6.0, s.y + 3.0), GHOST_COL, 3.0)
	draw_circle(head_c, 6.0, GHOST_COL)
