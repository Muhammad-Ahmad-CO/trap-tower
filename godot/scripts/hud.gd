class_name TTHUD
extends Node2D

# 5 squares, top centre: filled = levels completed in the current block
# of 5 (block = levels 5k+1..5k+5, in shipped order). The current level
# counts only after completion. No other in-level HUD.

var filled := 0
var sq_col := Color.WHITE
var bg_col := Color.WHITE
var size := 34.0
var gap := 16.0
var top := 18.0


func setup(pal: Dictionary, filled_count: int) -> void:
	sq_col = TTuning.col(str(pal.get("trap", "#2B0A8A")))
	bg_col = TTuning.col(str(pal.get("bg", "#FFFFFF")))
	filled = filled_count
	# Drawing only: HUD renders above all level art.
	z_index = 100


func _draw() -> void:
	var total := 5.0 * size + 4.0 * gap
	var x0 := (1280.0 - total) * 0.5
	# Opaque backing for the whole HUD row, drawn before the squares:
	# level art running in the gaps between squares (e.g. the L008
	# pillar rope, which sits in the gap left of square #2, not behind
	# a square) also passes behind the HUD instead of threading the
	# row. Same background colour as the level background, so it is
	# invisible except where it occludes level art. Drawing only.
	draw_rect(Rect2(x0, top, total, size), bg_col)
	for i in range(5):
		var r := Rect2(x0 + float(i) * (size + gap), top, size, size)
		if i < filled:
			draw_rect(r, sq_col)
		else:
			# Opaque background fill first: level art (e.g. a hanging
			# pillar rope) passes behind the HUD instead of showing
			# through the empty square.
			draw_rect(r, bg_col)
			draw_rect(r, sq_col, false, 4.0)
