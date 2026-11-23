extends Control

# World map: the START screen (no separate title screen). ONE organic
# island silhouette (original shape/colours) with ONE winding trail;
# 44 door nodes sit ON the trail in shipped order (scrollable
# vertically, snake-like but organic — varying x, no rigid grid),
# joined by thin crack-style path lines; the current door glows with a
# triangle marker; completed doors show a check; locked doors are
# dimmed + show a lock + are unclickable. Tapping an unlocked door
# opens a dismissible picker overlay (open_picker) listing that door's
# stages — one obstacle type per door, a different type per door
# (see TTDoorMap). Unlock derives from the highest unlocked level
# index, never from the completed-ID set; a door is done only when
# ALL its stage IDs are completed. Big chunky pixel-font "TRAP TOWER"
# title + "Made by Ahmed" visible on first view; settings wrench
# top-right. Settings (sound toggle + music volume + close) live on
# the map screen only. Subtle idle animation: the current door's glow
# pulses, its triangle marker bobs, and a soft ring breathes around
# it. Audio settings are applied and music is started in _ready.
# After a win/skip, game.gd sets TTState.return_door and the map
# re-opens that door's picker on top of the map; cold start and
# pause/ESC exits show a plain map (return_door defaults to -1).
# Lane U4 (M5 chapters): the map is split into 3 chapters (Ch.1
# doors 1-16, Ch.2 doors 17-30, Ch.3 doors 31-44, TTFeatures table);
# chapter tabs in the header switch the island view, each chapter
# with its own island palette, and a horizontal chapter wipe
# (ChapterWipe, left/right panels — a wipe variant, NOT the mouth
# shape) covers the switch. All 44 doors stay reachable; unlock
# derivation (highest_unlocked) is unchanged. Lane U4 (M2): a skull
# counter (SkullCounter, n/5 for the viewed chapter) sits under the
# STARS label. Lane U4 (M8): a chapter-complete overlay opens when
# TTState.chapter_complete is set by a win (original humour text +
# the chapter's death count); for Chapter 3 it sets
# TTState.pending_credits so Lane U5's credits open after it (N4).

const NODES_PER_ROW := 9
const ROW_H := 140.0
const NODE_W := 110.0
const NODE_H := 110.0
const GRID_Y0 := 60.0
# Dark ink for numbers/locks/checks on light fills (see _number_col_for).
const DARK_INK := Color(0.10, 0.04, 0.35)


# Pixel-level legibility: five palettes have light trap colours
# (#F9FAFB, #FBBF24, #F5D76E, #E0F2FE, #93C5FD) and most locked fills
# lighten past 0.5 luminance, where a white number/lock washes out
# (seen in screenshots: doors 14/21/31/36/41 nearly unreadable).
# Pick the number/lock ink from the fill's luminance instead.
static func _number_col_for(fill: Color, locked: bool) -> Color:
	var lum := 0.2126 * fill.r + 0.7152 * fill.g + 0.0722 * fill.b
	if lum > 0.50:
		return Color(DARK_INK.r, DARK_INK.g, DARK_INK.b, 0.75 if locked else 1.0)
	return Color(1, 1, 1, 0.6 if locked else 1.0)


# Deterministic per-index jitter in [-1, 1] (same every run, no RNG
# state): breaks the rigid grid so the trail reads organic.
static func _jitter(idx: int, salt: float) -> float:
	var v := sin(float(idx) * 12.9898 + salt * 78.233) * 43758.5453
	return v - floor(v)


# One level node on the map. Release-activated (see IconButton note):
# the press is never accepted, so a drag still scrolls the map.
class LevelNode extends Control:
	signal pressed

	var level := 0
	var locked := false
	var current := false
	var done := false
	var fill := Color(0.17, 0.04, 0.54)
	var outline_col := Color.WHITE
	var number_col := Color.WHITE
	var glow_col := Color(1.0, 0.9, 0.4, 0.28)
	var marker_col := Color.html("FFD23F")
	var _press_pos := Vector2.ZERO
	var _press_inside := false
	var _pulse_t := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		set_process(current)

	func _process(delta: float) -> void:
		if not current:
			set_process(false)
			return
		# Idle animation: glow pulse + triangle bob (current node only).
		_pulse_t += delta
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_inside = true
				_press_pos = event.position
			else:
				var fire: bool = _press_inside and Rect2(Vector2.ZERO, size).has_point(event.position) and event.position.distance_to(_press_pos) <= 16.0
				_press_inside = false
				if fire and not locked:
					pressed.emit()

	func _draw() -> void:
		var cx := size.x * 0.5
		if current:
			var pulse := 0.20 + 0.10 * sin(_pulse_t * 3.0)
			var gc := glow_col
			gc.a = pulse
			draw_circle(Vector2(cx, 58), 56.0, gc)
			var bob := sin(_pulse_t * 3.0) * 3.0
			var tri := PackedVector2Array([Vector2(cx - 14, 2 + bob), Vector2(cx + 14, 2 + bob), Vector2(cx, 20 + bob)])
			draw_colored_polygon(tri, marker_col)
		var aw := 76.0
		var ah := 76.0
		var ax := cx - aw * 0.5
		var ay := 28.0
		var rad := aw * 0.5
		var cy := ay + rad
		draw_circle(Vector2(cx, cy), rad, fill)
		draw_rect(Rect2(ax, cy, aw, ah - rad), fill)
		draw_arc(Vector2(cx, cy), rad, PI, TAU, 20, outline_col, 3.0, true)
		draw_line(Vector2(ax, cy), Vector2(ax, ay + ah), outline_col, 3.0, true)
		draw_line(Vector2(ax + aw, cy), Vector2(ax + aw, ay + ah), outline_col, 3.0, true)
		if current:
			draw_arc(Vector2(cx, cy), rad + 3.0, PI, TAU, 20, marker_col, 3.0, true)
		# Pixel-font node number, centred in the arch (upper half, so
		# the lock below never overlaps it).
		TTPixelFont.draw_text(self, str(level + 1), Vector2(0, ay + 30.0), 4, number_col, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		if locked:
			# Small padlock at the foot of the arch: shackle arc +
			# body, in the dimmed number colour.
			var lock_c := Vector2(cx, ay + ah - 12.0)
			draw_arc(lock_c, 5.5, PI, TAU, 12, number_col, 3.0, true)
			draw_rect(Rect2(lock_c.x - 8, lock_c.y, 16, 12), number_col)
		elif done:
			var bc := Vector2(size.x - 18.0, 18.0)
			draw_circle(bc, 11.0, Color.WHITE)
			draw_line(bc + Vector2(-6, 0), bc + Vector2(-2, 4), fill, 3.0, true)
			draw_line(bc + Vector2(-2, 4), bc + Vector2(6, -5), fill, 3.0, true)


# One door node on the map. Same arch-drawing language as LevelNode
# (arch + pixel-font number + lock at the foot + check badge), but the
# number is the DOOR number (1-44) and the state is per door: locked
# iff its first stage is beyond highest_unlocked; current iff it holds
# highest_unlocked; done iff ALL its stage IDs are completed.
# LevelNode is kept intact above (draft probe references it).
class DoorNode extends Control:
	signal pressed

	var door := 1
	var locked := false
	var current := false
	var done := false
	var fill := Color(0.17, 0.04, 0.54)
	var outline_col := Color.WHITE
	var number_col := Color.WHITE
	var glow_col := Color(1.0, 0.9, 0.4, 0.28)
	var marker_col := Color.html("FFD23F")
	var _press_pos := Vector2.ZERO
	var _press_inside := false
	var _pulse_t := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		set_process(current)

	func _process(delta: float) -> void:
		if not current:
			set_process(false)
			return
		# Idle animation: glow pulse + triangle bob (current door only).
		_pulse_t += delta
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_inside = true
				_press_pos = event.position
			else:
				var fire: bool = _press_inside and Rect2(Vector2.ZERO, size).has_point(event.position) and event.position.distance_to(_press_pos) <= 16.0
				_press_inside = false
				if fire and not locked:
					pressed.emit()

	func _draw() -> void:
		var cx := size.x * 0.5
		if current:
			var pulse := 0.20 + 0.10 * sin(_pulse_t * 3.0)
			var gc := glow_col
			gc.a = pulse
			draw_circle(Vector2(cx, 58), 56.0, gc)
			var bob := sin(_pulse_t * 3.0) * 3.0
			var tri := PackedVector2Array([Vector2(cx - 14, 2 + bob), Vector2(cx + 14, 2 + bob), Vector2(cx, 20 + bob)])
			draw_colored_polygon(tri, marker_col)
		var aw := 76.0
		var ah := 76.0
		var ax := cx - aw * 0.5
		var ay := 28.0
		var rad := aw * 0.5
		var cy := ay + rad
		draw_circle(Vector2(cx, cy), rad, fill)
		draw_rect(Rect2(ax, cy, aw, ah - rad), fill)
		draw_arc(Vector2(cx, cy), rad, PI, TAU, 20, outline_col, 3.0, true)
		draw_line(Vector2(ax, cy), Vector2(ax, ay + ah), outline_col, 3.0, true)
		draw_line(Vector2(ax + aw, cy), Vector2(ax + aw, ay + ah), outline_col, 3.0, true)
		if current:
			draw_arc(Vector2(cx, cy), rad + 3.0, PI, TAU, 20, marker_col, 3.0, true)
		# Pixel-font door number, centred in the arch (upper half, so
		# the lock below never overlaps it).
		TTPixelFont.draw_text(self, str(door), Vector2(0, ay + 30.0), 4, number_col, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		if locked:
			# Small padlock at the foot of the arch: shackle arc +
			# body, in the dimmed number colour.
			var lock_c := Vector2(cx, ay + ah - 12.0)
			draw_arc(lock_c, 5.5, PI, TAU, 12, number_col, 3.0, true)
			draw_rect(Rect2(lock_c.x - 8, lock_c.y, 16, 12), number_col)
		elif done:
			# Badge: white disc with a dark-ink check + dark outline,
			# so it reads on light fills too (a fill-coloured check
			# would vanish on the near-white traps).
			var bc := Vector2(size.x - 18.0, 18.0)
			draw_circle(bc, 11.0, Color.WHITE)
			draw_arc(bc, 11.0, 0, TAU, 24, DARK_INK, 2.0, true)
			draw_line(bc + Vector2(-6, 0), bc + Vector2(-2, 4), DARK_INK, 3.0, true)
			draw_line(bc + Vector2(-2, 4), bc + Vector2(6, -5), DARK_INK, 3.0, true)


# One stage button inside the door picker. Release-activated (a drag
# never fires it). Pixel-font stage number; done stages show a drawn
# check, locked stages a drawn padlock (the pixel font has no check
# or lock glyphs, so both are drawn like the map node's marks).
class StageButton extends Control:
	signal pressed

	var level := 0
	var locked := false
	var done := false
	var fill := Color(0.17, 0.04, 0.54)
	var number_col := Color.WHITE
	var _press_pos := Vector2.ZERO
	var _press_inside := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_inside = true
				_press_pos = event.position
			else:
				var fire: bool = _press_inside and Rect2(Vector2.ZERO, size).has_point(event.position) and event.position.distance_to(_press_pos) <= 16.0
				_press_inside = false
				if fire and not locked:
					pressed.emit()

	func _draw() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = fill
		sb.set_corner_radius_all(14)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		# Stage number: the global level number (1-215), centred.
		TTPixelFont.draw_text(self, str(level + 1), Vector2(0, (size.y - 7.0 * 5.0) * 0.5), 5, number_col, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		if locked:
			var lock_c := Vector2(size.x * 0.5, size.y - 16.0)
			draw_arc(lock_c, 5.5, PI, TAU, 12, number_col, 3.0, true)
			draw_rect(Rect2(lock_c.x - 8, lock_c.y, 16, 12), number_col)
		elif done:
			var bc := Vector2(size.x - 16.0, 16.0)
			draw_circle(bc, 10.0, Color.WHITE)
			draw_arc(bc, 10.0, 0, TAU, 24, DARK_INK, 2.0, true)
			draw_line(bc + Vector2(-5, 0), bc + Vector2(-1, 4), DARK_INK, 3.0, true)
			draw_line(bc + Vector2(-1, 4), bc + Vector2(5, -4), DARK_INK, 3.0, true)


# One bonus-door node on the map (Lane F1, v1.0.5 Part B). The 45th
# door, bonus-only: same arch language as DoorNode, number "45", a
# gold star badge when unlocked, a padlock at the foot when locked
# (under 50 stars), a check badge when all 5 bonus stages are done.
# Deliberately NOT a DoorNode and with NO `door` property (it uses
# `bonus_door`): the UI probe counts DoorNodes as exactly 44, and
# this node must never be counted among them.
class BonusDoorNode extends Control:
	signal pressed

	var bonus_door := 45
	var locked := false
	var current := false
	var done := false
	var fill := Color.html("FFD23F")
	var outline_col := Color.WHITE
	var number_col := Color(0.10, 0.04, 0.35)
	var _press_pos := Vector2.ZERO
	var _press_inside := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_inside = true
				_press_pos = event.position
			else:
				var fire: bool = _press_inside and Rect2(Vector2.ZERO, size).has_point(event.position) and event.position.distance_to(_press_pos) <= 16.0
				_press_inside = false
				if fire and not locked:
					pressed.emit()

	func _draw() -> void:
		var cx := size.x * 0.5
		var aw := 76.0
		var ah := 76.0
		var ax := cx - aw * 0.5
		var ay := 28.0
		var rad := aw * 0.5
		var cy := ay + rad
		draw_circle(Vector2(cx, cy), rad, fill)
		draw_rect(Rect2(ax, cy, aw, ah - rad), fill)
		draw_arc(Vector2(cx, cy), rad, PI, TAU, 20, outline_col, 3.0, true)
		draw_line(Vector2(ax, cy), Vector2(ax, ay + ah), outline_col, 3.0, true)
		draw_line(Vector2(ax + aw, cy), Vector2(ax + aw, ay + ah), outline_col, 3.0, true)
		TTPixelFont.draw_text(self, "45", Vector2(0, ay + 30.0), 4, number_col, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		if locked:
			var lock_c := Vector2(cx, ay + ah - 12.0)
			draw_arc(lock_c, 5.5, PI, TAU, 12, number_col, 3.0, true)
			draw_rect(Rect2(lock_c.x - 8, lock_c.y, 16, 12), number_col)
		elif done:
			var bc := Vector2(size.x - 18.0, 18.0)
			draw_circle(bc, 11.0, Color.WHITE)
			draw_arc(bc, 11.0, 0, TAU, 24, DARK_INK, 2.0, true)
			draw_line(bc + Vector2(-6, 0), bc + Vector2(-2, 4), DARK_INK, 3.0, true)
			draw_line(bc + Vector2(-2, 4), bc + Vector2(6, -5), DARK_INK, 3.0, true)
		else:
			# Gold star badge (unlocked, not yet done): the same
			# 5-point star the levels hide, drawn at badge size.
			var bc := Vector2(size.x - 18.0, 18.0)
			var pts := PackedVector2Array()
			for p in TTStar.star_points(10.0, 4.2):
				pts.append(p + bc)
			draw_colored_polygon(pts, Color.html("FFD23F"))


# One small hidden arched door (Lane U5, M12). Same arch language as
# DoorNode (circle + jambs + outline) at 44x56 with NO number and NO
# label: it sits in the settings panel's bottom-right corner and
# opens the bonus door. Release-activated like the other map nodes,
# so a drag never fires it.
class SecretDoorButton extends Control:
	signal pressed

	var _press_pos := Vector2.ZERO
	var _press_inside := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_inside = true
				_press_pos = event.position
			else:
				var fire: bool = _press_inside and Rect2(Vector2.ZERO, size).has_point(event.position) and event.position.distance_to(_press_pos) <= 16.0
				_press_inside = false
				if fire:
					pressed.emit()

	func _draw() -> void:
		var cx := size.x * 0.5
		var aw := 40.0
		var ah := 52.0
		var ax := cx - aw * 0.5
		var ay := 2.0
		var rad := aw * 0.5
		var cy := ay + rad
		var fill := Color.html("2B0A8A")
		var outline_col := Color(1, 1, 1, 0.85)
		draw_circle(Vector2(cx, cy), rad, fill)
		draw_rect(Rect2(ax, cy, aw, ah - rad), fill)
		draw_arc(Vector2(cx, cy), rad, PI, TAU, 20, outline_col, 2.5, true)
		draw_line(Vector2(ax, cy), Vector2(ax, ay + ah), outline_col, 2.5, true)
		draw_line(Vector2(ax + aw, cy), Vector2(ax + aw, ay + ah), outline_col, 2.5, true)
		# Tiny gold knob so the arch reads as a door at 1x.
		draw_circle(Vector2(cx + 10.0, cy + 16.0), 3.0, Color.html("FFD23F"))


# Organic island + crack path behind the nodes. Never interactive.
# The island is ONE smooth blob polygon: per row, the node x-range
# widened by a wobbly margin, capped top and bottom — so navy
# background stays visible around it and the silhouette reads
# organic, never a full-bleed rectangle. A darker rim outlines it.
# The trail is a thin crack-style jagged line joining consecutive
# node centres.
class MapArt extends Control:
	var island_col := Color.html("E8871E")
	var island_edge_col := Color.html("E8871E").darkened(0.25)
	var dot_col := Color.html("2B0A8A")
	var ring_col := Color(1.0, 0.824, 0.247, 0.5)
	var centres: Array[Vector2] = []
	var nodes_per_row := 9
	var current_centre := Vector2.ZERO
	var content_h := 3520.0
	var _t := 0.0

	func _process(delta: float) -> void:
		# Subtle idle animation: a soft ring breathes around the
		# current node. One redraw per frame for the whole island.
		_t += delta
		queue_redraw()

	func _island_polygon() -> PackedVector2Array:
		if centres.is_empty():
			return PackedVector2Array()
		var rows := (centres.size() + nodes_per_row - 1) / nodes_per_row
		var left_pts: Array[Vector2] = []
		var right_pts: Array[Vector2] = []
		for r in range(rows):
			var lo := r * nodes_per_row
			var hi := mini(lo + nodes_per_row, centres.size())
			var min_x := 1e9
			var max_x := -1e9
			var cy := 0.0
			for k in range(lo, hi):
				min_x = minf(min_x, centres[k].x)
				max_x = maxf(max_x, centres[k].x)
				cy = centres[k].y
			var wob := sin(float(r) * 1.7) * 26.0
			left_pts.append(Vector2(min_x - 105.0 + wob, cy))
			right_pts.append(Vector2(max_x + 105.0 - wob, cy))
		# Control ring, clockwise from the top cap: top centre, right
		# side top->bottom, bottom centre, left side bottom->top.
		var ctrl: Array[Vector2] = []
		var top_mid := Vector2((left_pts[0].x + right_pts[0].x) * 0.5, left_pts[0].y - 120.0)
		var bot_mid := Vector2((left_pts[left_pts.size() - 1].x + right_pts[right_pts.size() - 1].x) * 0.5, left_pts[left_pts.size() - 1].y + 80.0)
		# +80, NOT +120: the bottom "Made by Ahmed" credit sits at
		# content_h - 64 (last row centre + 114), and the lobe
		# midpoints below push the edge ~18px further down — +120
		# put the island edge through the credit text (seen in
		# map_scrolled.png). +80 keeps ~14px of clear water.
		ctrl.append(top_mid)
		for p in right_pts:
			ctrl.append(p)
		ctrl.append(bot_mid)
		for i in range(left_pts.size() - 1, -1, -1):
			ctrl.append(left_pts[i])
		# Lobe/scallop points (O1 fix, round 2): ONE radial midpoint
		# per edge was NOT enough — its push runs nearly parallel
		# to the long top flanks, so both flanks still measured as
		# straight diagonals (Lane 5, fresh map.png: max deviation
		# 1.18 px left / 1.39 px right over 270-300 px runs).
		# Each edge now gets points offset PERPENDICULAR to the
		# edge, alternating outward lobe / inward bay, at a ~130 px
		# scallop pitch, so no run stays straight (modelled
		# offline first: top flanks 20.9/25.6 px LS deviation,
		# worst 200 px window 4.3 px, crest min-y unchanged).
		# The offset lists run centre->side; edges 11 (left top)
		# and 5 (right bottom) run side->centre in the ring, so
		# their t is mirrored (1-t). Top: a bay near the crest
		# (so the dome peaks), lobe, bay, lobe, lobe near the
		# side — never a bay there, doors 8/9 sit ~10 px under
		# the edge. Bottom: capped outward (+12/+16, less than
		# the old +18) with a shallow saddle, so the bottom
		# "Made by Ahmed" credit keeps its clearance (modelled
		# 34.0 px, unchanged). Sides: one inward bay per
		# row-segment, alternating depth, so no 140 px side run
		# stays straight. Top/bottom caps (+120/-120 and +80)
		# are UNCHANGED.
		var centroid := Vector2.ZERO
		for p in ctrl:
			centroid += p
		centroid /= float(ctrl.size())
		var top_seq: Array = [[0.14, -8.0], [0.30, 24.0], [0.48, -10.0], [0.66, 26.0], [0.84, 20.0]]
		var bot_seq: Array = [[0.25, 12.0], [0.50, -4.0], [0.75, 16.0]]
		var aug: Array[Vector2] = []
		for i in range(ctrl.size()):
			var a := ctrl[i]
			var b := ctrl[(i + 1) % ctrl.size()]
			aug.append(a)
			var mid := (a + b) * 0.5
			var out := (mid - centroid).normalized()
			var edir := (b - a).normalized()
			var north := edir.orthogonal()
			if north.dot(out) < 0.0:
				north = -north
			if i == 0 or i == 11:
				# Edge 11 runs side->centre, so BOTH mirror t AND
				# iterate the list in reverse — otherwise the
				# points land in decreasing-t order and the ring
				# zigzags back on itself (self-intersecting
				# polygon: Godot triangulation fails, 391 errors
				# in the probe log; caught by tri_test.gd).
				var tseq: Array = top_seq.duplicate()
				if i == 11:
					tseq.reverse()
				for s in tseq:
					var t: float = float(s[0]) if i == 0 else 1.0 - float(s[0])
					aug.append(a + (b - a) * t + north * float(s[1]))
			elif i == 5 or i == 6:
				var bseq: Array = bot_seq.duplicate()
				if i == 5:
					bseq.reverse()
				for s in bseq:
					var t: float = float(s[0]) if i == 6 else 1.0 - float(s[0])
					aug.append(a + (b - a) * t + north * float(s[1]))
			else:
				var depth := 28.0 if i % 2 == 0 else 18.0
				aug.append(mid - north * depth)
		return _catmull_closed(aug, 8)

	# Closed Catmull-Rom spline through the control points: a smooth
	# curve with no straight runs and no sharp corners. Own art only.
	static func _catmull_closed(pts: Array[Vector2], subdiv: int) -> PackedVector2Array:
		var n := pts.size()
		var out := PackedVector2Array()
		if n < 3:
			return PackedVector2Array(pts)
		for i in range(n):
			var p0: Vector2 = pts[(i - 1 + n) % n]
			var p1: Vector2 = pts[i]
			var p2: Vector2 = pts[(i + 1) % n]
			var p3: Vector2 = pts[(i + 2) % n]
			for s in range(subdiv):
				var t := float(s) / float(subdiv)
				var t2 := t * t
				var t3 := t2 * t
				out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
		return out

	func _draw() -> void:
		var poly := _island_polygon()
		if poly.size() >= 3:
			# Darker rim first (thick outline), then the island fill:
			# the rim shows as a ~7px edge around the blob.
			var closed := poly + PackedVector2Array([poly[0]])
			draw_polyline(closed, island_edge_col, 14.0, true)
			draw_colored_polygon(poly, island_col)
		# Crack-style path: jagged two-segment line between nodes.
		for i in range(centres.size() - 1):
			var a := centres[i]
			var b := centres[i + 1]
			var mid3 := a.lerp(b, 0.5)
			var perp := (b - a).orthogonal().normalized()
			var j := (sin(float(i) * 7.13) * 0.5) * 14.0
			mid3 += perp * j
			draw_line(a, mid3, dot_col, 3.0, true)
			draw_line(mid3, b, dot_col, 3.0, true)
		# Breathing ring around the current node.
		if current_centre != Vector2.ZERO:
			var r := 66.0 + 5.0 * sin(_t * 2.0)
			var rc := ring_col
			rc.a = 0.35 + 0.15 * sin(_t * 2.0)
			draw_arc(current_centre, r, 0, TAU, 40, rc, 3.0, true)


# Lane U4 (M2): skull + "n/5" counter for one chapter. Code-drawn
# skull (white cranium, dark-red outline/eyes/jaw — the same skull
# language as the HUD row) with yellow pixel text right-aligned in
# the control; the skull sits immediately left of the text.
class SkullCounter extends Control:
	var n := 0
	var total := 5
	var text_col := Color(1.0, 0.824, 0.247)

	func set_keys(p_n: int, p_total: int) -> void:
		total = maxi(1, p_total)
		n = clampi(p_n, 0, total)
		queue_redraw()

	func keys_text() -> String:
		return str(n) + "/" + str(total)

	func _draw() -> void:
		var t := keys_text()
		var tw := TTPixelFont.text_width(t, 3)
		var tx := size.x - tw
		var sc := Vector2(tx - 30.0, size.y * 0.5 - 2.0)
		draw_circle(sc, 8.0, Color(0.43, 0.04, 0.04))
		draw_circle(sc, 7.0, Color.WHITE)
		draw_rect(Rect2(sc.x - 4.0, sc.y + 5.0, 8.0, 6.0), Color(0.43, 0.04, 0.04))
		draw_rect(Rect2(sc.x - 3.0, sc.y + 5.0, 6.0, 5.0), Color.WHITE)
		draw_line(Vector2(sc.x - 1.0, sc.y + 5.0), Vector2(sc.x - 1.0, sc.y + 10.0), Color(0.43, 0.04, 0.04), 1.0, true)
		draw_line(Vector2(sc.x + 1.0, sc.y + 5.0), Vector2(sc.x + 1.0, sc.y + 10.0), Color(0.43, 0.04, 0.04), 1.0, true)
		draw_circle(sc + Vector2(-2.8, -1.0), 1.8, Color(0.43, 0.04, 0.04))
		draw_circle(sc + Vector2(2.8, -1.0), 1.8, Color(0.43, 0.04, 0.04))
		TTPixelFont.draw_text(self, t, Vector2(0, (size.y - 21.0) * 0.5), 3, text_col, HORIZONTAL_ALIGNMENT_RIGHT, size.x)


# Lane U4 (M5): the world-change transition. An ORIGINAL wipe
# variant: two panels slide in from the LEFT and RIGHT edges to
# cover the screen (TTWipe slides top/bottom), then slide back out
# to reveal — with a thin yellow leading edge, in the target
# chapter's trap colour. Our own design (NOT the reference's mouth
# shape). Awaitable like TTWipe: `await wipe.cover()` /
# `await wipe.reveal()`. Never blocks input (mouse_filter IGNORE);
# process_mode ALWAYS so it animates across pause boundaries.
class ChapterWipe extends Control:
	signal cover_finished
	signal reveal_finished

	var panel_col := Color(0.43, 0.04, 0.04)
	var edge_col := Color(1.0, 0.824, 0.247)
	var _frac := 0.0
	var _animating := false
	var _anim_t := 0.0
	var _anim_dur := 0.15
	var _anim_dir := 0  # +1 covering, -1 revealing

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		position = Vector2.ZERO
		size = Vector2(1280, 720)
		z_index = 200

	func set_colors(col: Color) -> void:
		panel_col = col
		queue_redraw()

	func cover(dur: float = 0.15) -> void:
		_animating = true
		_anim_t = 0.0
		_anim_dur = maxf(0.01, dur)
		_anim_dir = 1
		set_process(true)
		await cover_finished

	func reveal(dur: float = 0.16) -> void:
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
		var half := 640.0 * _frac
		# Left panel slides in from x=0; right panel from x=1280.
		draw_rect(Rect2(0, 0, half, 720), panel_col)
		draw_rect(Rect2(1280 - half, 0, half, 720), panel_col)
		if _frac < 1.0:
			# Thin yellow leading edges where the panels meet the scene.
			draw_rect(Rect2(half - 2.0, 0, 4.0, 720), edge_col)
			draw_rect(Rect2(1280 - half - 2.0, 0, 4.0, 720), edge_col)


var _levels: Array = []
var _total := 0
var _highest := 0
var _completed: Array = []
var _tuning: Dictionary = {}
var _bg_col := Color.html("E8871E")
var _trap_col := Color.html("2B0A8A")
var _scroll: ScrollContainer = null
# Logo integration (user picked logo 1, 20 Nov 2026): true when the
# logo PNG (assets/logo.png) is present; the header reflows around it
# (credit + viewport move down) and falls back to the pixel-text title
# when the binary has not landed yet.
var _logo_present := false
var _content_h := 3520.0
var _settings: Control = null
var _sound_btn: TTHUD.IconButton = null
var _music_slider: HSlider = null
var _wipe: TTWipe = null
var _picker: Control = null
var _picker_panel: Panel = null
var _picker_title: TTPixelLabel = null
var _picker_subtitle: TTPixelLabel = null
var _picker_stages: Control = null
var _picker_door := 0
# Lane F3: achievements + stats overlays (own screens, reachable
# from the map). Built once, re-filled with live save numbers on
# every open — the numbers are always read from the save, never
# placeholders.
var _achievements: Control = null
var _ach_list: Control = null
var _stats: Control = null
var _stats_list: Control = null
# Lane F1: stars / skins / bonus door (own overlays below).
var _stars_count := 0
var _doors_done := 0
var _selected_skin := "default"
var _bonus_highest := 0
var _bonus_completed: Array = []
var _bonus_levels: Array = []
var _stars_label: TTPixelLabel = null
var _skin_picker: Control = null
var _skin_rows: Array = []
var _bonus_picker: Control = null
var _bonus_picker_panel: Panel = null
var _bonus_picker_title: TTPixelLabel = null
var _bonus_picker_subtitle: TTPixelLabel = null
var _bonus_picker_stages: Control = null
# Lane F2: daily challenge + nightmare mode (own overlays below).
var _nightmare_unlocked := false
var _nightmare_armed := false
var _daily_btn: TTHUD.IconButton = null
var _nightmare_btn: TTHUD.IconButton = null
var _daily_overlay: Control = null
var _daily_date_label: TTPixelLabel = null
var _daily_status1_label: TTPixelLabel = null
var _daily_status2_label: TTPixelLabel = null
var _nightmare_overlay: Control = null
var _nightmare_status1_label: TTPixelLabel = null
var _nightmare_status2_label: TTPixelLabel = null
# Lane U5: end screens (M7 credits, M9 celebration) + secret door (M12).
var _credits: Control = null
var _celebration: Control = null
var _celebration_kind_label: TTPixelLabel = null
var _celebration_kind := ""
var _secret_door: SecretDoorButton = null
# Lane U5 (M4 speedrun): applied after U4's chapter API landed
# (see M4-SPEEDRUN-STUB.md). Overlay + rows built by
# _build_speedrun_overlay; _speedrun_rows holds {"button", "label",
# "chapter"} per chapter row.
var _speedrun_overlay: Control = null
var _speedrun_rows: Array = []
# Lane U4 (M5 chapters + M2 keys + M8 chapter-complete).
var _chapter := 1
var _chapter_tabs: Array = []
var _chapter_switching := false
var _chapter_wipe: ChapterWipe = null
var _skull_counter: SkullCounter = null
var _best_label: TTPixelLabel = null
var _m8: Control = null
var _m8_title: TTPixelLabel = null
var _m8_sub: TTPixelLabel = null
var _m8_line1: TTPixelLabel = null
var _m8_line2: TTPixelLabel = null
var _m8_deaths: TTPixelLabel = null
var _m8_closer: TTPixelLabel = null
var _m8_chapter := 0
var _pending_return_door := -1


func _ready() -> void:
	TTAudio.ensure_audio(get_tree())
	_tuning = TTuning.load_tuning()
	var pal: Dictionary = TTuning.palette(_tuning, 0)
	_bg_col = TTuning.col(str(pal.get("bg", "#E8871E")))
	_trap_col = TTuning.col(str(pal.get("trap", "#2B0A8A")))
	var bg := ColorRect.new()
	bg.color = _trap_col
	bg.position = Vector2.ZERO
	bg.size = Vector2(1280, 720)
	add_child(bg)
	# New logo (user picked logo 1, 20 Nov 2026): pixel-font TRAP
	# TOWER, tiny hero jumping over spikes, orange background
	# (assets/logo.png, 1318x1054 content crop). Shown as a 220x176
	# plaque centred at the top; the old pixel-text title is the
	# fallback when the PNG is absent (fresh checkout before the
	# binary lands via the browser route).
	_logo_present = ResourceLoader.exists("res://assets/logo.png")
	if _logo_present:
		var logo := TextureRect.new()
		logo.texture = load("res://assets/logo.png")
		logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		logo.stretch_mode = TextureRect.STRETCH_SCALE
		logo.position = Vector2(530, 4)
		logo.size = Vector2(220, 176)
		add_child(logo)
	else:
		var title := TTPixelLabel.new()
		title.text = "TRAP TOWER"
		title.pixel_size = 9
		title.color = _bg_col
		title.align = HORIZONTAL_ALIGNMENT_CENTER
		title.width = 1280.0
		title.position = Vector2(0, 16)
		add_child(title)
	var credit_top := TTPixelLabel.new()
	credit_top.text = "Made by Ahmed"
	credit_top.pixel_size = 3
	credit_top.color = _bg_col
	credit_top.align = HORIZONTAL_ALIGNMENT_CENTER
	credit_top.width = 1280.0
	# With the logo the credit sits directly under the plaque
	# (plaque ends y180); without it, the old y84 slot under the
	# pixel-text title.
	credit_top.position = Vector2(0, 186) if _logo_present else Vector2(0, 84)
	add_child(credit_top)
	var wrench := TTHUD.IconButton.new()
	wrench.icon = "wrench"
	wrench.fill = _bg_col
	wrench.icon_col = _trap_col
	wrench.position = Vector2(1196, 20)
	wrench.size = Vector2(64, 64)
	wrench.corner_radius = 12
	wrench.pressed.connect(open_settings)
	add_child(wrench)
	# Lane F3: TROPHIES + STATS, top-left. The centred logo plaque
	# spans x 530..750, so these end at x 364 with room to spare.
	# Font 22 (px4): TROPHIES is 188px wide, STATS 116px — both fit
	# their buttons with room. (Font 26/px5 made TROPHIES 235px in a
	# 190px button and clipped it to "ROPHIE" in screenshots.)
	# Buttons end at x 364; the centred title starts past x 374.
	var trophies := _make_text_button("TROPHIES", Vector2(16, 20), Vector2(200, 56), 22, _bg_col, _trap_col)
	trophies.pressed.connect(open_achievements)
	add_child(trophies)
	var stats_btn := _make_text_button("STATS", Vector2(224, 20), Vector2(140, 56), 22, _bg_col, _trap_col)
	stats_btn.pressed.connect(open_stats)
	add_child(stats_btn)
	# Lane F1: SKINS, top-right (logo plaque ends ~x750, wrench starts
	# x1196): 1010..1180 leaves room on both sides.
	var skins_btn := _make_text_button("SKINS", Vector2(1010, 20), Vector2(170, 56), 26, _bg_col, _trap_col)
	skins_btn.pressed.connect(open_skin_picker)
	add_child(skins_btn)
	# Lane F2: DAILY + NIGHTMARE, second header row (y 84, under
	# TROPHIES/STATS): the centred "Made by Ahmed" credit sits below
	# the logo plaque (y 186) when the logo is present, so 16..464 is
	# free on this row. The scroll viewport moves down to y 214 to
	# clear the credit under the plaque (y 148 without the logo).
	_daily_btn = _make_text_button("DAILY", Vector2(16, 84), Vector2(200, 56), 22, _bg_col, _trap_col)
	_daily_btn.pressed.connect(open_daily)
	add_child(_daily_btn)
	_nightmare_btn = _make_text_button("NIGHTMARE", Vector2(224, 84), Vector2(240, 56), 22, _bg_col, _trap_col)
	_nightmare_btn.pressed.connect(_on_nightmare_button)
	add_child(_nightmare_btn)
	_refresh_mode_buttons()
	# Lane U4 (M5): chapter tabs as a third header row on the LEFT
	# (x 16..452, y 148): DAILY/NIGHTMARE end at y 140, the scroll
	# viewport starts at y 214, and the centred logo plaque
	# (x 530..750, y 4..180) plus its credit (y 186) leave this
	# strip clear. (An earlier revision put the tabs at y 84,
	# x 480..916 — straight across the middle of the logo plaque;
	# screenshots caught it: the logo's middle band was hidden
	# behind the tabs. Never place header controls in x 530..750,
	# y 4..180.) The tabs are built on the default chapter 1 and
	# re-filled once the save is loaded below.
	_build_chapter_tabs()
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		var err := TTPixelLabel.new()
		err.text = "Level data error"
		err.pixel_size = 5
		err.color = _bg_col
		err.position = Vector2(80, 200)
		add_child(err)
		_build_settings()
		return
	_levels = loaded["levels"]
	_total = _levels.size()
	var progress := TTProgress.load_progress()
	_highest = clampi(int(progress["highest_unlocked"]), 0, maxi(0, _total - 1))
	_completed = progress["completed"]
	# Lane F1: star/skin/bonus state, read once here from the save.
	_stars_count = (progress["stars_collected"] as Array).size()
	_selected_skin = str(progress.get("selected_skin", "default"))
	_bonus_completed = progress["bonus_completed"]
	_bonus_highest = int(progress["bonus_highest"])
	_doors_done = TTSkins.doors_completed(_completed, _levels)
	var bonus_loaded := TTLevelData.load_levels("res://data/bonus_levels.json")
	_bonus_levels = [] if str(bonus_loaded.get("error", "")) != "" else bonus_loaded["levels"]
	# Lane F2: nightmare unlock is computed from the save (all 215
	# complete) and persisted the first time it is met; the DAILY /
	# NIGHTMARE buttons are re-filled with the real state now.
	TTNightmare.refresh_unlock()
	_nightmare_unlocked = TTNightmare.is_unlocked(progress)
	_nightmare_armed = TTState.nightmare_armed and _nightmare_unlocked
	_refresh_mode_buttons()
	# Lane U4: the map opens on the chapter holding the current door
	# (the door `highest_unlocked` sits in — never stored).
	_chapter = TTFeatures.chapter_of_door(TTDoorMap.door_of(_highest))
	_refresh_chapter_tabs()
	# Star count, top-right under the SKINS button: right-aligned so
	# it never touches the centred "Made by Ahmed" credit (ends ~x745).
	_stars_label = TTPixelLabel.new()
	_stars_label.text = "STARS " + str(_stars_count) + "/215"
	_stars_label.pixel_size = 3
	_stars_label.color = _bg_col
	_stars_label.align = HORIZONTAL_ALIGNMENT_RIGHT
	_stars_label.width = 280.0
	_stars_label.position = Vector2(980, 84)
	add_child(_stars_label)
	# Lane U4 (M2): skull n/5 for the viewed chapter, under STARS
	# (y 112..140, above the scroll viewport at y 148/214).
	_skull_counter = SkullCounter.new()
	_skull_counter.position = Vector2(980, 112)
	_skull_counter.size = Vector2(280, 28)
	_skull_counter.text_col = _bg_col
	add_child(_skull_counter)
	_refresh_skull_counter()
	# Unlock derives from highest_unlocked (index), never completed.
	_build_map()
	_build_settings()
	_build_picker()
	_build_skin_picker()
	_build_bonus_picker()
	_build_achievements()
	_build_stats()
	_build_daily_overlay()
	_build_nightmare_overlay()
	_build_credits()
	_build_celebration()
	_build_speedrun_overlay()
	_build_chapter_complete()
	_scroll_to_current()
	_maybe_open_return_door()
	# Lane V (M3): "Best --:--" timer, bottom-left of the map, matching the
	# official Ch.1 map (frames-31/f002). Shows the fastest completed level
	# time; "--:--" when no level has a best time yet. Added last so it
	# overlays the map scroll content, like the official's label.
	_best_label = TTPixelLabel.new()
	var _fastest: Dictionary = TTFeatures.fastest_level(progress)
	if _fastest.is_empty():
		_best_label.text = "Best --:--"
	else:
		_best_label.text = "Best " + TTFeatures.format_time(float(_fastest.get("time", 0.0)))
	_best_label.pixel_size = 3
	# Lane U3 (M3 fix): _bg_col (#E8871E) is ALSO the island fill, so the
	# label was invisible on the orange island (verified: fresh vs
	# seeded map screenshots differ by 0 px in the label box). DARK_INK
	# is the map's own dark ink for light fills (see _number_col_for);
	# the map palette is fixed (palette 0), so the island is always
	# this orange and dark ink is always readable on it.
	_best_label.color = DARK_INK
	_best_label.align = HORIZONTAL_ALIGNMENT_LEFT
	_best_label.width = 300.0
	_best_label.position = Vector2(16, 684)
	add_child(_best_label)
	# Lane U5 (M4): "Speedrun" button, bottom-left above the
	# Best label (official Ch.2 map, frames-17/f001). Applied
	# after U4's chapter API landed (see M4-SPEEDRUN-STUB.md).
	var speedrun_btn := _make_text_button("SPEEDRUN", Vector2(16, 612), Vector2(220, 56), 22, _bg_col, _trap_col)
	speedrun_btn.pressed.connect(open_speedrun)
	add_child(speedrun_btn)
	# Original wipe reveal on entering the map.
	_wipe = TTWipe.new()
	add_child(_wipe)
	_wipe.reveal()
	# Lane U5: end screens (M7/M9) are checked last, in the same
	# frame as the _maybe_open_return_door call above — its 2-frame
	# await has not resumed yet, so stashing return_door inside the
	# check still suppresses the auto-picker.
	_check_end_game_screens()
	# Lane U4 (M5): the chapter wipe (left/right panels) is built
	# once and reused for every chapter switch.
	_chapter_wipe = ChapterWipe.new()
	add_child(_chapter_wipe)


func _node_pos(idx: int) -> Vector2:
	# Snake rows (9 per row, direction alternates), but every node's
	# x/y carries deterministic jitter so the trail winds organically
	# instead of sitting on a rigid grid.
	var row := idx / NODES_PER_ROW
	var slot := idx % NODES_PER_ROW
	var col := slot if row % 2 == 0 else NODES_PER_ROW - 1 - slot
	var base_x := 57.0 + float(col) * 132.0
	var jx := (_jitter(idx, 1.0) - 0.5) * 56.0
	var jy := (_jitter(idx, 2.0) - 0.5) * 22.0
	var x := clampf(base_x + jx, 20.0, 1280.0 - NODE_W - 20.0)
	var y := GRID_Y0 + float(row) * ROW_H + jy
	return Vector2(x, y)


func _build_map() -> void:
	# Lane U4 (M5): ONE chapter's door nodes (9 per row); content
	# height follows this chapter's rows, and MapArt adapts from the
	# centres automatically. Node positions are CHAPTER-LOCAL
	# (_node_pos(local index)), so every chapter's island starts at
	# the top. All 44 doors stay reachable — the tabs switch the
	# view, nothing is ever removed from the game. Unlock derivation
	# (highest_unlocked) is unchanged. Called once in _ready and
	# again on every chapter switch (the old ScrollContainer is
	# freed first). The bonus door (45th) lives in the Chapter 3
	# view only (end-game content, locked until 50 stars).
	var doors: Array = TTFeatures.chapter_doors(_chapter)
	var rows := (doors.size() + NODES_PER_ROW - 1) / NODES_PER_ROW
	_content_h = GRID_Y0 + float(rows) * ROW_H + 100.0
	if _scroll != null:
		remove_child(_scroll)
		_scroll.queue_free()
		_scroll = null
	_scroll = ScrollContainer.new()
	# Scroll viewport starts BELOW the header credit: with the logo
	# the credit glyphs end ~y207, so y214 clears it by 7px (was
	# y148 / credit ends y105 without the logo).
	_scroll.position = Vector2(0, 214) if _logo_present else Vector2(0, 148)
	_scroll.size = Vector2(1280, 506) if _logo_present else Vector2(1280, 572)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	var content := Control.new()
	content.custom_minimum_size = Vector2(1280, _content_h)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(content)
	# Lane U4 (M5): per-chapter map palette (TTFeatures chapter
	# table -> tuning palette): the ISLAND changes colour per
	# chapter; the outer background + header stay palette 0 (their
	# contrast is verified as-is). Ch.1 orange/purple, Ch.2
	# pink/dark-red, Ch.3 cream/brown.
	var ch_pal: Dictionary = TTuning.palette(_tuning, TTFeatures.chapter_palette(_chapter))
	var island_col := TTuning.col(str(ch_pal.get("bg", "#E8871E")))
	var island_trap := TTuning.col(str(ch_pal.get("trap", "#2B0A8A")))
	var art := MapArt.new()
	art.island_col = island_col
	art.island_edge_col = island_col.darkened(0.25)
	art.dot_col = island_trap
	art.content_h = _content_h
	art.position = Vector2.ZERO
	art.size = Vector2(1280, _content_h)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(art)
	var centres: Array[Vector2] = []
	for li in range(doors.size()):
		centres.append(_node_pos(li) + Vector2(NODE_W * 0.5, 62.0))
	# Lane F1: the bonus door is the trail stop after this chapter's
	# last door (Chapter 3 only), so the island + crack path include
	# it like any door.
	if _chapter == 3:
		centres.append(_node_pos(doors.size()) + Vector2(NODE_W * 0.5, 62.0))
	art.centres = centres
	var current_door := TTDoorMap.door_of(_highest)
	var current_li := doors.find(current_door)
	art.current_centre = centres[current_li] if current_li >= 0 and not centres.is_empty() else Vector2.ZERO
	for li in range(doors.size()):
		var door: int = doors[li]
		var first := TTDoorMap.door_first_index(door)
		var trap := TTuning.col(str(TTuning.palette(_tuning, TTDoorMap.door_palette(door)).get("trap", "#2B0A8A")))
		var btn := DoorNode.new()
		btn.door = door
		btn.locked = first > _highest
		btn.current = door == current_door
		# Done only when ALL this door's stage IDs are completed —
		# never derived from highest_unlocked.
		btn.done = true
		for idx in TTDoorMap.door_levels(door):
			if not _completed.has(str(_levels[idx].get("id", ""))):
				btn.done = false
				break
		if btn.locked:
			btn.fill = trap.lerp(_bg_col, 0.45)
			btn.outline_col = Color(1, 1, 1, 0.55)
			btn.number_col = _number_col_for(btn.fill, true)
		else:
			btn.fill = trap
			btn.outline_col = Color.WHITE
			btn.number_col = _number_col_for(btn.fill, false)
		btn.position = _node_pos(li)
		btn.size = Vector2(NODE_W, NODE_H)
		btn.pressed.connect(_on_door_pressed.bind(door))
		content.add_child(btn)
	if _chapter == 3:
		# Lane F1: bonus door (45th). Locked until 50 stars; gold fill
		# when unlocked (dark number ink — gold on white is unreadable),
		# dimmed + lock when locked; done when all 5 bonus stages are done.
		var bonus_unlocked := TTSkins.bonus_unlocked(_stars_count)
		var bonus_btn := BonusDoorNode.new()
		bonus_btn.locked = not bonus_unlocked
		bonus_btn.current = false
		bonus_btn.done = not _bonus_levels.is_empty()
		for idx in range(_bonus_levels.size()):
			if not _bonus_completed.has(str(_bonus_levels[idx].get("id", ""))):
				bonus_btn.done = false
				break
		if bonus_btn.locked:
			bonus_btn.fill = Color.html("FFD23F").lerp(_bg_col, 0.55)
			bonus_btn.outline_col = Color(1, 1, 1, 0.55)
			bonus_btn.number_col = Color(0.10, 0.04, 0.35, 0.75)
		else:
			bonus_btn.fill = Color.html("FFD23F")
			bonus_btn.outline_col = Color.WHITE
			bonus_btn.number_col = Color(0.10, 0.04, 0.35)
		bonus_btn.position = _node_pos(doors.size())
		bonus_btn.size = Vector2(NODE_W, NODE_H)
		bonus_btn.pressed.connect(_on_bonus_door_pressed)
		content.add_child(bonus_btn)
	var credit := TTPixelLabel.new()
	credit.text = "Made by Ahmed"
	credit.pixel_size = 4
	credit.color = _bg_col
	credit.align = HORIZONTAL_ALIGNMENT_CENTER
	credit.width = 1280.0
	credit.position = Vector2(0, _content_h - 64)
	content.add_child(credit)


func _scroll_to_current() -> void:
	if _scroll == null:
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if _scroll == null or not is_instance_valid(_scroll):
		return
	# Lane U4: scroll to the current door when it is in the VIEWED
	# chapter (chapter-local index); otherwise the top (a chapter
	# the player has not reached yet has no current door in it).
	var s := 0.0
	var doors: Array = TTFeatures.chapter_doors(_chapter)
	var li := doors.find(TTDoorMap.door_of(_highest))
	if li >= 0:
		var y := _node_pos(li).y
		s = clampf(y - 180.0, 0.0, maxf(0.0, _content_h - 572.0))
	# N1: snap so the top visible row is fully in view or fully
	# hidden. The old s landed mid-row (e.g. s=160 left doors 1-9
	# as ~10 px slivers at the top edge in map_progress.png).
	# Node tops/bottoms in a row vary by the deterministic
	# jitter (±11 px), so the boundary is the row's ACTUAL
	# min top / max bottom, not the nominal row_y — snapping to
	# the nominal bottom (170) still left up to 11 px slivers
	# of the lowest doors (seen on the first fix6 shot). If s
	# cuts the row, snap to the nearer of min-top (show the row
	# fully) / max-bottom (hide it fully). s=0 (cold start, row
	# 0 fully visible) is left alone. Free scrolling is
	# untouched — this only sets the auto-scroll landing spot.
	var row := int(floor((s - GRID_Y0) / ROW_H))
	if row >= 0:
		var min_top := 1e9
		var max_bottom := -1e9
		for k in range(NODES_PER_ROW):
			var idx := row * NODES_PER_ROW + k
			if idx >= doors.size():
				break
			var ny := _node_pos(idx).y
			min_top = minf(min_top, ny)
			max_bottom = maxf(max_bottom, ny + NODE_H)
		if s > min_top and s < max_bottom:
			if max_bottom - s >= NODE_H * 0.5:
				s = min_top
			else:
				s = max_bottom
			s = clampf(s, 0.0, maxf(0.0, _content_h - 572.0))
	_scroll.scroll_vertical = s


# --- Lane U4: chapters (M5) + map skull counter (M2) ---------------

func _build_chapter_tabs() -> void:
	# Three tabs in the free header stretch (x 480..916, y 84):
	# DAILY/NIGHTMARE end at x 464, STARS starts at x 980. The
	# no-logo fallback credit sits at y 84 too — but logo.png ships
	# in the repo, so the fallback never triggers in a real build
	# (noted in LANE-U4-REPORT.md).
	_chapter_tabs = []
	var labels: Array[String] = ["CH 1", "CH 2", "CH 3"]
	for i in range(3):
		var b := _make_text_button(labels[i], Vector2(16 + i * 148, 148), Vector2(140, 56), 26, _bg_col, _trap_col)
		b.pressed.connect(_on_chapter_tab.bind(i + 1))
		add_child(b)
		_chapter_tabs.append({"button": b, "chapter": i + 1})
	_refresh_chapter_tabs()


func _refresh_chapter_tabs() -> void:
	# Selected tab = gold fill (stands out from the other header
	# buttons); unselected = the standard orange header fill.
	for entry in _chapter_tabs:
		var b: TTHUD.IconButton = entry["button"]
		if int(entry["chapter"]) == _chapter:
			b.fill = Color.html("FFD23F")
		else:
			b.fill = _bg_col
		b.icon_col = _trap_col
		b.queue_redraw()


func _on_chapter_tab(chapter: int) -> void:
	if chapter == _chapter or _chapter_switching:
		return
	await _switch_chapter(chapter, true)


func _switch_chapter(chapter: int, animate: bool = true) -> void:
	if chapter == _chapter or _chapter_switching:
		return
	_chapter_switching = true
	if animate and _chapter_wipe != null:
		# The wipe wears the TARGET chapter's trap colour.
		var ch_pal: Dictionary = TTuning.palette(_tuning, TTFeatures.chapter_palette(chapter))
		_chapter_wipe.set_colors(TTuning.col(str(ch_pal.get("trap", "#2B0A8A"))))
		await _chapter_wipe.cover()
		_apply_chapter(chapter)
		if _chapter_wipe != null and is_instance_valid(_chapter_wipe):
			await _chapter_wipe.reveal()
	else:
		_apply_chapter(chapter)
	_chapter_switching = false


func _apply_chapter(chapter: int) -> void:
	_chapter = clampi(chapter, 1, TTFeatures.chapter_count())
	_build_map()
	_refresh_chapter_tabs()
	_refresh_skull_counter()
	_scroll_to_current()


func _refresh_skull_counter() -> void:
	if _skull_counter == null:
		return
	var data := TTProgress.load_progress()
	_skull_counter.set_keys(
		TTFeatures.chapter_keys_collected(data, _chapter),
		TTFeatures.chapter_keys_total(_chapter))


func _build_settings() -> void:
	_settings = Control.new()
	_settings.position = Vector2.ZERO
	_settings.size = Vector2(1280, 720)
	_settings.visible = false
	add_child(_settings)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	_settings.add_child(dim)
	var panel := Panel.new()
	panel.position = Vector2(290, 160)
	panel.size = Vector2(700, 400)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _bg_col.lightened(0.45)
	sb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	_settings.add_child(panel)
	var title := TTPixelLabel.new()
	title.text = "SETTINGS"
	title.pixel_size = 6
	title.color = _trap_col
	title.align = HORIZONTAL_ALIGNMENT_CENTER
	title.width = 700.0
	title.position = Vector2(290, 182)
	_settings.add_child(title)
	var sound_label := TTPixelLabel.new()
	sound_label.text = "SOUND"
	sound_label.pixel_size = 5
	sound_label.color = _trap_col
	sound_label.position = Vector2(340, 276)
	_settings.add_child(sound_label)
	_sound_btn = _make_text_button("ON", Vector2(700, 262), Vector2(200, 64), 30, _trap_col, Color.WHITE)
	_sound_btn.pressed.connect(_on_sound_toggle)
	_settings.add_child(_sound_btn)
	var music_label := TTPixelLabel.new()
	music_label.text = "MUSIC"
	music_label.pixel_size = 5
	music_label.color = _trap_col
	music_label.position = Vector2(340, 366)
	_settings.add_child(music_label)
	_music_slider = HSlider.new()
	_music_slider.position = Vector2(520, 362)
	_music_slider.size = Vector2(380, 48)
	_music_slider.min_value = 0.0
	_music_slider.max_value = 1.0
	_music_slider.step = 0.05
	_music_slider.value = TTAudio.get_music_volume()
	_music_slider.value_changed.connect(_on_music_changed)
	_settings.add_child(_music_slider)
	# Lane U5 (M12 secret door): a small arched door tucked in the
	# panel's bottom-right corner (916, 492, 44x56 — inside the
	# 700x400 panel, clear of CLOSE at x530..750 and the music
	# slider at x520..900/y362..410). No label, no button chrome:
	# it reads as a little door in the panel corner, not a menu
	# item. Opens the existing bonus door (45th, 50 stars) when
	# unlocked; while locked it stays shut with no response.
	_secret_door = SecretDoorButton.new()
	_secret_door.name = "SecretDoor"
	_secret_door.position = Vector2(916, 492)
	_secret_door.size = Vector2(44, 56)
	_secret_door.pressed.connect(_on_secret_door_pressed)
	_settings.add_child(_secret_door)
	var close := _make_text_button("CLOSE", Vector2(530, 472), Vector2(220, 64), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_settings)
	_settings.add_child(close)


func open_settings() -> void:
	if _settings == null:
		return
	_sound_btn.text = "ON" if TTAudio.is_sound_enabled() else "OFF"
	_sound_btn.queue_redraw()
	_music_slider.value = TTAudio.get_music_volume()
	_settings.visible = true


func close_settings() -> void:
	if _settings != null:
		_settings.visible = false


func _on_sound_toggle() -> void:
	TTAudio.set_sound_enabled(not TTAudio.is_sound_enabled())
	_sound_btn.text = "ON" if TTAudio.is_sound_enabled() else "OFF"
	_sound_btn.queue_redraw()


func _on_music_changed(value: float) -> void:
	TTAudio.set_music_volume(value)


# Lane U5 (M12): the hidden settings door opens the bonus picker
# (same picker as the 45th door node) — but only while the bonus
# door is unlocked (50 stars). Locked: no response, the door stays
# shut (a hidden door that announced itself would not be hidden).
func _on_secret_door_pressed() -> void:
	if not TTSkins.bonus_unlocked(_stars_count):
		return
	close_settings()
	open_bonus_picker()


func _make_text_button(text: String, pos: Vector2, size: Vector2, font_size: int, fill: Color, font_col: Color) -> TTHUD.IconButton:
	var b := TTHUD.IconButton.new()
	b.text = text
	b.position = pos
	b.size = size
	b.font_size = font_size
	b.fill = fill
	b.icon_col = font_col
	b.corner_radius = 14
	return b


func _build_picker() -> void:
	# Dismissible overlay over the VISIBLE map: dim background,
	# panel with close X; tapping outside the panel dismisses.
	# The dim is a transparent full-screen button UNDER the panel:
	# clicks on the panel (or its buttons) never reach it, clicks
	# anywhere else close the picker.
	_picker = Control.new()
	_picker.position = Vector2.ZERO
	_picker.size = Vector2(1280, 720)
	_picker.visible = false
	add_child(_picker)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	_picker.add_child(dim)
	var dim_btn := Button.new()
	dim_btn.position = Vector2.ZERO
	dim_btn.size = Vector2(1280, 720)
	dim_btn.flat = true
	dim_btn.text = ""
	var empty := StyleBoxEmpty.new()
	dim_btn.add_theme_stylebox_override("normal", empty)
	dim_btn.add_theme_stylebox_override("hover", empty)
	dim_btn.add_theme_stylebox_override("pressed", empty)
	dim_btn.add_theme_stylebox_override("focus", empty)
	dim_btn.pressed.connect(close_picker)
	_picker.add_child(dim_btn)
	var panel := Panel.new()
	panel.position = Vector2(290, 160)
	# Content-sized (O5 fix): title (182) + subtitle (248) + stage
	# buttons (330..426) + 24px bottom padding = bottom 450, so the
	# panel is 700x290 — no ~134px of empty peach below the buttons.
	# Stage buttons sit in ONE horizontal row, so the height is the
	# same for a 1-stage door and a 5-stage door; open_picker()
	# re-asserts it from the stage geometry every time it opens.
	panel.size = Vector2(700, 290)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _bg_col.lightened(0.45)
	sb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	_picker.add_child(panel)
	_picker_panel = panel
	_picker_title = TTPixelLabel.new()
	_picker_title.text = "DOOR 1"
	_picker_title.pixel_size = 6
	_picker_title.color = _trap_col
	_picker_title.align = HORIZONTAL_ALIGNMENT_CENTER
	_picker_title.width = 700.0
	_picker_title.position = Vector2(290, 182)
	_picker.add_child(_picker_title)
	# Obstacle type of this door, e.g. "SAW-RUNS": the same type for
	# all stages in the door, a different type for every other door.
	_picker_subtitle = TTPixelLabel.new()
	_picker_subtitle.text = ""
	_picker_subtitle.pixel_size = 4
	_picker_subtitle.color = _trap_col
	_picker_subtitle.align = HORIZONTAL_ALIGNMENT_CENTER
	_picker_subtitle.width = 700.0
	_picker_subtitle.position = Vector2(290, 248)
	_picker.add_child(_picker_subtitle)
	_picker_stages = Control.new()
	_picker_stages.position = Vector2.ZERO
	_picker_stages.size = Vector2(1280, 720)
	_picker_stages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_picker.add_child(_picker_stages)
	var close := _make_text_button("X", Vector2(920, 176), Vector2(56, 56), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_picker)
	_picker.add_child(close)


func open_picker(door: int) -> void:
	if _picker == null:
		return
	if door < 1 or door > TTDoorMap.door_count():
		return
	# Locked doors never open the picker (their tap is a no-op).
	if TTDoorMap.door_first_index(door) > _highest:
		return
	_picker_door = door
	_picker_title.text = "DOOR " + str(door)
	_picker_subtitle.text = TTDoorMap.door_template(door).to_upper()
	for child in _picker_stages.get_children():
		_picker_stages.remove_child(child)
		child.queue_free()
	var stages: Array = TTDoorMap.door_levels(door)
	var bw := 96.0
	var gap := 16.0
	var total_w := float(stages.size()) * bw + float(stages.size() - 1) * gap
	var x0 := 290.0 + (700.0 - total_w) * 0.5
	for i in range(stages.size()):
		var idx: int = stages[i]
		var trap := TTuning.col(str(TTuning.palette(_tuning, TTDoorMap.door_palette(door)).get("trap", "#2B0A8A")))
		var b := StageButton.new()
		b.level = idx
		b.locked = idx > _highest
		b.done = _completed.has(str(_levels[idx].get("id", "")))
		if b.locked:
			b.fill = trap.lerp(_bg_col, 0.45)
			b.number_col = _number_col_for(b.fill, true)
		elif b.done:
			b.fill = trap
			# Gold number only on dark fills; on light fills the
			# luminance-picked dark ink (gold on yellow is unreadable).
			if _number_col_for(b.fill, false) == Color.WHITE:
				b.number_col = Color.html("FFD23F")
			else:
				b.number_col = _number_col_for(b.fill, false)
		else:
			b.fill = trap
			b.number_col = _number_col_for(b.fill, false)
		b.position = Vector2(x0 + float(i) * (bw + gap), 330)
		b.size = Vector2(bw, 96)
		b.pressed.connect(_on_stage_pressed.bind(idx))
		_picker_stages.add_child(b)
	if _picker_panel != null:
		# Content-sized every open (O5): stage buttons end at
		# y=426; panel bottom = 426 + 24px padding = 450.
		_picker_panel.size = Vector2(700, 450.0 - 160.0)
	# No auto-select/highlight of the next stage, no NEXT button:
	# the player picks a stage, or dismisses the picker.
	_picker.visible = true


func close_picker() -> void:
	if _picker != null:
		_picker.visible = false
	_picker_door = 0


# --- Lane U4: chapter-complete end screen (M8) --------------------
# Original humour text (own wording — NOT the official's "YOU
# ESCAPED" line) + the player's death count FOR THAT CHAPTER
# (chapter_deaths). Same dismissible overlay pattern as the picker
# (dim + panel + CLOSE). Order pinned (N4): after L215 this M8
# screen (Ch.3) shows FIRST; closing it sets
# TTState.pending_credits so Lane U5's end-credits open after it.

func _build_chapter_complete() -> void:
	_m8 = Control.new()
	_m8.position = Vector2.ZERO
	_m8.size = Vector2(1280, 720)
	_m8.visible = false
	add_child(_m8)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	_m8.add_child(dim)
	var panel := Panel.new()
	panel.position = Vector2(290, 90)
	panel.size = Vector2(700, 540)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _bg_col.lightened(0.45)
	sb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	_m8.add_child(panel)
	_m8_title = TTPixelLabel.new()
	_m8_title.text = "CHAPTER 1 COMPLETE!"
	_m8_title.pixel_size = 6
	_m8_title.color = _trap_col
	_m8_title.align = HORIZONTAL_ALIGNMENT_CENTER
	_m8_title.width = 700.0
	_m8_title.position = Vector2(290, 112)
	_m8.add_child(_m8_title)
	_m8_sub = TTPixelLabel.new()
	_m8_sub.text = ""
	_m8_sub.pixel_size = 4
	_m8_sub.color = _trap_col
	_m8_sub.align = HORIZONTAL_ALIGNMENT_CENTER
	_m8_sub.width = 700.0
	_m8_sub.position = Vector2(290, 172)
	_m8.add_child(_m8_sub)
	_m8_line1 = TTPixelLabel.new()
	_m8_line1.text = ""
	_m8_line1.pixel_size = 4
	_m8_line1.color = _trap_col
	_m8_line1.align = HORIZONTAL_ALIGNMENT_CENTER
	_m8_line1.width = 700.0
	_m8_line1.position = Vector2(290, 232)
	_m8.add_child(_m8_line1)
	_m8_line2 = TTPixelLabel.new()
	_m8_line2.text = ""
	_m8_line2.pixel_size = 4
	_m8_line2.color = _trap_col
	_m8_line2.align = HORIZONTAL_ALIGNMENT_CENTER
	_m8_line2.width = 700.0
	_m8_line2.position = Vector2(290, 282)
	_m8.add_child(_m8_line2)
	_m8_deaths = TTPixelLabel.new()
	_m8_deaths.text = ""
	_m8_deaths.pixel_size = 3
	_m8_deaths.color = _trap_col
	_m8_deaths.align = HORIZONTAL_ALIGNMENT_CENTER
	_m8_deaths.width = 700.0
	_m8_deaths.position = Vector2(290, 342)
	_m8.add_child(_m8_deaths)
	_m8_closer = TTPixelLabel.new()
	_m8_closer.text = ""
	_m8_closer.pixel_size = 4
	_m8_closer.color = _trap_col
	_m8_closer.align = HORIZONTAL_ALIGNMENT_CENTER
	_m8_closer.width = 700.0
	_m8_closer.position = Vector2(290, 402)
	_m8.add_child(_m8_closer)
	var close := _make_text_button("CLOSE", Vector2(530, 556), Vector2(220, 56), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(_on_chapter_complete_close)
	_m8.add_child(close)


func open_chapter_complete(chapter: int) -> void:
	if _m8 == null:
		return
	_m8_chapter = clampi(chapter, 1, TTFeatures.chapter_count())
	var data := TTProgress.load_progress()
	var deaths := TTFeatures.chapter_deaths(data, _m8_chapter)
	_m8_title.text = "CHAPTER " + str(_m8_chapter) + " COMPLETE!"
	# Chapter 3's UI label is honestly "CHAPTER 3 - CONTINUATION"
	# (a design label, NOT an official playlist chapter — N3).
	_m8_sub.text = "CHAPTER 3 - CONTINUATION" if _m8_chapter == 3 else ""
	match _m8_chapter:
		1:
			_m8_line1.text = "YOU SURVIVED EVERY TRAP."
			_m8_line2.text = "THE TOWER IS BUILDING MORE."
			_m8_closer.text = "HA! IT COUNTED EVERY ONE."
		2:
			_m8_line1.text = "TWO CHAPTERS DOWN. THE TOWER"
			_m8_line2.text = "IS RUNNING OUT OF TRICKS."
			_m8_closer.text = "OR IS IT? ONE LEFT. HA!"
		_:
			_m8_line1.text = "YOU BEAT THE WHOLE TOWER!"
			_m8_line2.text = "THE DEVIL IS TAKING NOTES."
			_m8_closer.text = "FREE AT LAST. HA HA HA!"
	_m8_deaths.text = "YOU DIED " + str(deaths) + " TIMES IN CHAPTER " + str(_m8_chapter) + "."
	for lab in [_m8_title, _m8_sub, _m8_line1, _m8_line2, _m8_deaths, _m8_closer]:
		(lab as TTPixelLabel).queue_redraw()
	_m8.visible = true


func close_chapter_complete() -> void:
	if _m8 != null:
		_m8.visible = false


func _on_chapter_complete_close() -> void:
	var ch := _m8_chapter
	close_chapter_complete()
	_m8_chapter = 0
	if ch == 3:
		# N4: M8 (Ch.3 complete) FIRST, then M7 end-credits.
		# U5 HOOK: Lane U5's open_credits() consumes
		# TTState.pending_credits (set here, cleared there).
		TTState.pending_credits = true
		open_credits()
		return
	if _pending_return_door >= 1:
		var door := _pending_return_door
		_pending_return_door = -1
		# The win advanced highest_unlocked into the NEXT chapter;
		# go back to the played door's chapter (no wipe — the M8
		# overlay just covered the screen) and open its picker.
		_apply_chapter(TTFeatures.chapter_of_door(door))
		open_picker(door)


func _maybe_open_return_door() -> void:
	# Win/skip return: after the map's 2-frame scroll settle, reopen
	# the played door's picker on top of the map. The flag defaults
	# to -1, so a cold start never auto-opens; it is cleared on
	# consume so a later visit stays plain.
	await get_tree().process_frame
	await get_tree().process_frame
	var door := TTState.return_door
	TTState.return_door = -1
	# Lane U4 (M8): a chapter-complete win opens the M8 overlay
	# INSTEAD of the picker; the picker waits until the overlay
	# closes (the played door is stored in _pending_return_door).
	var ch := TTState.chapter_complete
	TTState.chapter_complete = 0
	if ch >= 1:
		# Keep a door stashed by _check_end_game_screens (M7/M9):
		# its return_door was already consumed there, so door is -1
		# here and must NOT clobber the stash.
		if door >= 1:
			_pending_return_door = door
		open_chapter_complete(ch)
		return
	if door == 45:
		# Lane F1: bonus win/skip returns to the BONUS picker.
		open_bonus_picker()
	elif door >= 1:
		open_picker(door)


func _on_door_pressed(door: int) -> void:
	if door < 1 or door > TTDoorMap.door_count():
		return
	if TTDoorMap.door_first_index(door) > _highest:
		return
	open_picker(door)


func _on_stage_pressed(idx: int) -> void:
	if idx < 0 or idx >= _total or idx > _highest:
		return
	_start_level(idx)


func _start_level(idx: int) -> void:
	TTState.bonus = false
	TTState.daily = false
	TTState.daily_date = ""
	TTState.nightmare = _nightmare_armed
	TTState.speedrun_chapter = 0  # Lane U5 STUB (M4): a normal level never inherits a stale run flag.
	TTState.level_index = idx
	get_tree().paused = false
	# Original wipe covers the map -> level transition.
	if _wipe != null:
		await _wipe.cover()
	get_tree().change_scene_to_file("res://scenes/game.tscn")

# --- Lane F1: skin picker + bonus door picker -------------------------
# Both overlays mirror the door picker's dismissible pattern (dim
# background, panel, X close, tap-outside dismisses).

func _build_skin_picker() -> void:
	_skin_picker = Control.new()
	_skin_picker.position = Vector2.ZERO
	_skin_picker.size = Vector2(1280, 720)
	_skin_picker.visible = false
	add_child(_skin_picker)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	_skin_picker.add_child(dim)
	var dim_btn := Button.new()
	dim_btn.position = Vector2.ZERO
	dim_btn.size = Vector2(1280, 720)
	dim_btn.flat = true
	dim_btn.text = ""
	var empty := StyleBoxEmpty.new()
	dim_btn.add_theme_stylebox_override("normal", empty)
	dim_btn.add_theme_stylebox_override("hover", empty)
	dim_btn.add_theme_stylebox_override("pressed", empty)
	dim_btn.add_theme_stylebox_override("focus", empty)
	dim_btn.pressed.connect(close_skin_picker)
	_skin_picker.add_child(dim_btn)
	var panel := Panel.new()
	panel.position = Vector2(290, 140)
	panel.size = Vector2(700, 440)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _bg_col.lightened(0.45)
	sb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	_skin_picker.add_child(panel)
	var title := TTPixelLabel.new()
	title.text = "SKINS"
	title.pixel_size = 6
	title.color = _trap_col
	title.align = HORIZONTAL_ALIGNMENT_CENTER
	title.width = 700.0
	title.position = Vector2(290, 162)
	_skin_picker.add_child(title)
	var sub := TTPixelLabel.new()
	sub.text = "HERO LOOK - VISUAL ONLY"
	sub.pixel_size = 4
	sub.color = _trap_col
	sub.align = HORIZONTAL_ALIGNMENT_CENTER
	sub.width = 700.0
	sub.position = Vector2(290, 228)
	_skin_picker.add_child(sub)
	_skin_rows = []
	for i in range(TTSkins.SKINS.size()):
		var skin: Dictionary = TTSkins.SKINS[i]
		var col := i % 3
		var row := i / 3
		var b := TTHUD.IconButton.new()
		b.text = str(skin["name"])
		b.position = Vector2(330 + col * 210, 280 + row * 110)
		b.size = Vector2(200, 64)
		b.font_size = 26
		b.corner_radius = 14
		b.pressed.connect(_on_skin_pressed.bind(str(skin["id"])))
		_skin_picker.add_child(b)
		var lab := TTPixelLabel.new()
		lab.text = ""
		lab.pixel_size = 3
		lab.color = _trap_col
		lab.align = HORIZONTAL_ALIGNMENT_CENTER
		lab.width = 200.0
		lab.position = Vector2(330 + col * 210, 350 + row * 110)
		_skin_picker.add_child(lab)
		_skin_rows.append({"button": b, "label": lab, "skin": skin})
	var close := _make_text_button("CLOSE", Vector2(530, 500), Vector2(220, 64), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_skin_picker)
	_skin_picker.add_child(close)


func open_skin_picker() -> void:
	if _skin_picker == null:
		return
	_fill_skin_picker()
	_skin_picker.visible = true


func close_skin_picker() -> void:
	if _skin_picker != null:
		_skin_picker.visible = false


func _fill_skin_picker() -> void:
	# Live numbers every open: doors/stars may have changed since
	# the map was built (a win returns here with fresh progress) —
	# so completed IDs are re-read from the save too, not just the
	# star/skin fields.
	var progress := TTProgress.load_progress()
	_completed = progress["completed"]
	_stars_count = (progress["stars_collected"] as Array).size()
	_selected_skin = str(progress.get("selected_skin", "default"))
	_doors_done = TTSkins.doors_completed(_completed, _levels)
	for entry in _skin_rows:
		var skin: Dictionary = entry["skin"]
		var b: TTHUD.IconButton = entry["button"]
		var lab: TTPixelLabel = entry["label"]
		var body := TTuning.col(str(skin.get("body", "#000000")))
		var unlocked := TTSkins.is_unlocked(skin, _doors_done, _stars_count)
		var selected := str(skin["id"]) == _selected_skin
		if selected:
			b.fill = body
			lab.text = "SELECTED"
		elif unlocked:
			b.fill = body
			lab.text = "TAP TO USE"
		else:
			# Locked: show only the short requirement ("5 DOORS",
			# "25 STARS" ...). Longer strings overflow the 200px
			# cell at pixel_size 3 and collide with the neighbours
			# (seen in screenshots: "OWNED - TAP TO USE" is 321px).
			b.fill = body.lerp(_bg_col.lightened(0.45), 0.6)
			lab.text = str(skin.get("rule", ""))
		# Light fills (GOLD, GHOST, FROST) need dark ink; dark
		# fills need white ink — same luminance rule as the map.
		var lum := 0.2126 * b.fill.r + 0.7152 * b.fill.g + 0.0722 * b.fill.b
		b.icon_col = Color(0.10, 0.04, 0.35) if lum > 0.50 else Color.WHITE
		b.queue_redraw()
		lab.queue_redraw()


func _on_skin_pressed(skin_id: String) -> void:
	var skin := TTSkins.skin_by_id(skin_id)
	if not TTSkins.is_unlocked(skin, _doors_done, _stars_count):
		return
	TTProgress.set_skin(skin_id)
	_selected_skin = skin_id
	_fill_skin_picker()


func _build_bonus_picker() -> void:
	_bonus_picker = Control.new()
	_bonus_picker.position = Vector2.ZERO
	_bonus_picker.size = Vector2(1280, 720)
	_bonus_picker.visible = false
	add_child(_bonus_picker)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	_bonus_picker.add_child(dim)
	var dim_btn := Button.new()
	dim_btn.position = Vector2.ZERO
	dim_btn.size = Vector2(1280, 720)
	dim_btn.flat = true
	dim_btn.text = ""
	var empty := StyleBoxEmpty.new()
	dim_btn.add_theme_stylebox_override("normal", empty)
	dim_btn.add_theme_stylebox_override("hover", empty)
	dim_btn.add_theme_stylebox_override("pressed", empty)
	dim_btn.add_theme_stylebox_override("focus", empty)
	dim_btn.pressed.connect(close_bonus_picker)
	_bonus_picker.add_child(dim_btn)
	var panel := Panel.new()
	panel.position = Vector2(290, 160)
	panel.size = Vector2(700, 290)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _bg_col.lightened(0.45)
	sb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	_bonus_picker.add_child(panel)
	_bonus_picker_panel = panel
	_bonus_picker_title = TTPixelLabel.new()
	_bonus_picker_title.text = "BONUS DOOR"
	_bonus_picker_title.pixel_size = 6
	_bonus_picker_title.color = _trap_col
	_bonus_picker_title.align = HORIZONTAL_ALIGNMENT_CENTER
	_bonus_picker_title.width = 700.0
	_bonus_picker_title.position = Vector2(290, 182)
	_bonus_picker.add_child(_bonus_picker_title)
	_bonus_picker_subtitle = TTPixelLabel.new()
	_bonus_picker_subtitle.text = "STAR HUNT"
	_bonus_picker_subtitle.pixel_size = 4
	_bonus_picker_subtitle.color = _trap_col
	_bonus_picker_subtitle.align = HORIZONTAL_ALIGNMENT_CENTER
	_bonus_picker_subtitle.width = 700.0
	_bonus_picker_subtitle.position = Vector2(290, 248)
	_bonus_picker.add_child(_bonus_picker_subtitle)
	_bonus_picker_stages = Control.new()
	_bonus_picker_stages.position = Vector2.ZERO
	_bonus_picker_stages.size = Vector2(1280, 720)
	_bonus_picker_stages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bonus_picker.add_child(_bonus_picker_stages)
	var close := _make_text_button("X", Vector2(920, 176), Vector2(56, 56), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_bonus_picker)
	_bonus_picker.add_child(close)


func open_bonus_picker() -> void:
	if _bonus_picker == null or _bonus_levels.is_empty():
		return
	# Locked bonus doors never open the picker (their tap is a no-op).
	if not TTSkins.bonus_unlocked(_stars_count):
		return
	_bonus_picker_title.text = "BONUS DOOR"
	_bonus_picker_subtitle.text = "STAR HUNT - " + str(_stars_count) + " STARS"
	for child in _bonus_picker_stages.get_children():
		_bonus_picker_stages.remove_child(child)
		child.queue_free()
	var trap := Color.html("FFD23F")
	var bw := 96.0
	var gap := 16.0
	var total_w := float(_bonus_levels.size()) * bw + float(_bonus_levels.size() - 1) * gap
	var x0 := 290.0 + (700.0 - total_w) * 0.5
	for i in range(_bonus_levels.size()):
		var b := StageButton.new()
		b.level = i
		b.locked = i > _bonus_highest
		b.done = _bonus_completed.has(str(_bonus_levels[i].get("id", "")))
		if b.locked:
			b.fill = trap.lerp(_bg_col, 0.45)
			b.number_col = _number_col_for(b.fill, true)
		else:
			b.fill = trap
			b.number_col = Color(0.10, 0.04, 0.35)
		b.position = Vector2(x0 + float(i) * (bw + gap), 330)
		b.size = Vector2(bw, 96)
		b.pressed.connect(_on_bonus_stage_pressed.bind(i))
		_bonus_picker_stages.add_child(b)
	if _bonus_picker_panel != null:
		_bonus_picker_panel.size = Vector2(700, 450.0 - 160.0)
	_bonus_picker.visible = true


func close_bonus_picker() -> void:
	if _bonus_picker != null:
		_bonus_picker.visible = false


func _on_bonus_door_pressed() -> void:
	if not TTSkins.bonus_unlocked(_stars_count):
		return
	open_bonus_picker()


func _on_bonus_stage_pressed(idx: int) -> void:
	if idx < 0 or idx >= _bonus_levels.size() or idx > _bonus_highest:
		return
	_start_bonus_level(idx)


func _start_bonus_level(idx: int) -> void:
	TTState.bonus = true
	TTState.daily = false
	TTState.daily_date = ""
	TTState.speedrun_chapter = 0  # Lane U5 STUB (M4): see _start_level.
	TTState.nightmare = false
	TTState.level_index = idx
	get_tree().paused = false
	# Original wipe covers the map -> level transition.
	if _wipe != null:
		await _wipe.cover()
	get_tree().change_scene_to_file("res://scenes/game.tscn")

# --- Lane F3: achievements + stats screens ---------------------------

func _overlay_shell(title_text: String) -> Dictionary:
	# Shared dim + panel + title + CLOSE for the F3 screens.
	# Panel (290, 90) 700x540; title at y 112; content 170..530;
	# CLOSE at (530, 556) 220x56. Returns {"root": Control,
	# "panel": Panel} — the caller adds its own content + close.
	var root := Control.new()
	root.position = Vector2.ZERO
	root.size = Vector2(1280, 720)
	root.visible = false
	add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	root.add_child(dim)
	var panel := Panel.new()
	panel.position = Vector2(290, 90)
	panel.size = Vector2(700, 540)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _bg_col.lightened(0.45)
	sb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	root.add_child(panel)
	var title := TTPixelLabel.new()
	title.text = title_text
	title.pixel_size = 6
	title.color = _trap_col
	title.align = HORIZONTAL_ALIGNMENT_CENTER
	title.width = 700.0
	title.position = Vector2(290, 112)
	root.add_child(title)
	return {"root": root, "panel": panel}


func _build_achievements() -> void:
	var shell := _overlay_shell("TROPHIES")
	_achievements = shell["root"]
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(320, 170)
	scroll.size = Vector2(640, 360)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_achievements.add_child(scroll)
	_ach_list = Control.new()
	_ach_list.custom_minimum_size = Vector2(640, float(TTFeatures.ACHIEVEMENTS.size() * 70))
	_ach_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(_ach_list)
	var close := _make_text_button("CLOSE", Vector2(530, 556), Vector2(220, 56), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_achievements)
	_achievements.add_child(close)


func open_achievements() -> void:
	if _achievements == null:
		return
	_fill_achievements()
	_achievements.visible = true


func close_achievements() -> void:
	if _achievements != null:
		_achievements.visible = false


func _fill_achievements() -> void:
	for child in _ach_list.get_children():
		_ach_list.remove_child(child)
		child.queue_free()
	var data := TTProgress.load_progress()
	var unlocked: Array = data.get("achievements_unlocked", [])
	var y := 0.0
	for a in TTFeatures.ACHIEVEMENTS:
		var ach_id := str(a["id"])
		var done := unlocked.has(ach_id)
		var row := Panel.new()
		row.position = Vector2(0, y)
		row.size = Vector2(640, 62)
		var rsb := StyleBoxFlat.new()
		if done:
			rsb.bg_color = Color(1.0, 0.824, 0.247, 0.30)
		else:
			rsb.bg_color = Color(0, 0, 0, 0.08)
		rsb.set_corner_radius_all(10)
		row.add_theme_stylebox_override("panel", rsb)
		_ach_list.add_child(row)
		var t := TTPixelLabel.new()
		t.text = str(a["title"])
		t.pixel_size = 4
		t.color = _trap_col if done else Color(0.35, 0.30, 0.45)
		t.position = Vector2(16, 8)
		row.add_child(t)
		var d := TTPixelLabel.new()
		d.text = str(a["desc"])
		d.pixel_size = 3
		d.color = _trap_col if done else Color(0.45, 0.40, 0.55)
		d.position = Vector2(16, 36)
		row.add_child(d)
		var st := TTPixelLabel.new()
		st.text = "DONE" if done else "LOCKED"
		st.pixel_size = 4
		st.color = Color.html("B8860B") if done else Color(0.45, 0.40, 0.55)
		st.align = HORIZONTAL_ALIGNMENT_RIGHT
		st.width = 640.0 - 32.0
		st.position = Vector2(16, 8)
		row.add_child(st)
		y += 70.0


func _build_stats() -> void:
	var shell := _overlay_shell("STATS")
	_stats = shell["root"]
	_stats_list = Control.new()
	_stats_list.position = Vector2.ZERO
	_stats_list.size = Vector2(1280, 720)
	_stats_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats.add_child(_stats_list)
	var close := _make_text_button("CLOSE", Vector2(530, 556), Vector2(220, 56), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_stats)
	_stats.add_child(close)


func open_stats() -> void:
	if _stats == null:
		return
	_fill_stats()
	_stats.visible = true


func close_stats() -> void:
	if _stats != null:
		_stats.visible = false


func _fill_stats() -> void:
	for child in _stats_list.get_children():
		_stats_list.remove_child(child)
		child.queue_free()
	var data := TTProgress.load_progress()
	var rows := TTFeatures.stats_rows(data, TTProgress.ghost_count())
	var y := 170.0
	for r in rows:
		var lab := TTPixelLabel.new()
		lab.text = str(r["label"])
		lab.pixel_size = 4
		lab.color = _trap_col
		lab.position = Vector2(330, y)
		_stats_list.add_child(lab)
		var val := TTPixelLabel.new()
		val.text = str(r["value"])
		val.pixel_size = 4
		val.color = _trap_col
		val.align = HORIZONTAL_ALIGNMENT_RIGHT
		val.width = 620.0
		val.position = Vector2(330, y)
		_stats_list.add_child(val)
		y += 38.0


# --- Lane F2: daily challenge + nightmare mode ------------------------
# DAILY (second header row): opens an overlay with today's date, the
# completion + best time FOR THAT DAY, and PLAY. NIGHTMARE (same
# row): locked until all 215 levels are complete (dimmed button;
# tapping it opens an overlay stating the requirement + X/215 done);
# once unlocked it toggles nightmare mode ON/OFF (gold when armed),
# and door-picker stage taps then start nightmare runs.

func _refresh_mode_buttons() -> void:
	if _daily_btn == null or _nightmare_btn == null:
		return
	var data := TTProgress.load_progress()
	var today := TTDaily.today_string()
	var rec: Dictionary = TTDaily.best_for(today, data)
	var done_today := bool(rec.get("completed", false))
	if done_today:
		_daily_btn.text = "DAILY DONE"
		_daily_btn.font_size = 18
	else:
		_daily_btn.text = "DAILY"
		_daily_btn.font_size = 22
	_daily_btn.queue_redraw()
	if not _nightmare_unlocked:
		_nightmare_btn.text = "NIGHTMARE"
		_nightmare_btn.font_size = 22
		_nightmare_btn.fill = Color(0.40, 0.40, 0.45)
		_nightmare_btn.icon_col = Color(0.80, 0.80, 0.85)
	elif _nightmare_armed:
		_nightmare_btn.text = "NIGHTMARE ON"
		_nightmare_btn.font_size = 18
		_nightmare_btn.fill = Color.html("FFD23F")
		_nightmare_btn.icon_col = _trap_col
	else:
		_nightmare_btn.text = "NIGHTMARE"
		_nightmare_btn.font_size = 22
		_nightmare_btn.fill = _bg_col
		_nightmare_btn.icon_col = _trap_col
	_nightmare_btn.queue_redraw()


func _build_daily_overlay() -> void:
	var shell := _overlay_shell("DAILY CHALLENGE")
	_daily_overlay = shell["root"]
	_daily_date_label = TTPixelLabel.new()
	_daily_date_label.text = ""
	_daily_date_label.pixel_size = 4
	_daily_date_label.color = _trap_col
	_daily_date_label.align = HORIZONTAL_ALIGNMENT_CENTER
	_daily_date_label.width = 700.0
	_daily_date_label.position = Vector2(290, 190)
	_daily_overlay.add_child(_daily_date_label)
	# Two status lines: a single line ("NOT DONE YET - NEW LEVEL
	# EVERY DAY", 36 chars) overflows the 700px panel at pixel_size
	# 4, so the status is split — line 1 + line 2, each <= 19 chars.
	_daily_status1_label = TTPixelLabel.new()
	_daily_status1_label.text = ""
	_daily_status1_label.pixel_size = 4
	_daily_status1_label.color = _trap_col
	_daily_status1_label.align = HORIZONTAL_ALIGNMENT_CENTER
	_daily_status1_label.width = 700.0
	_daily_status1_label.position = Vector2(290, 250)
	_daily_overlay.add_child(_daily_status1_label)
	_daily_status2_label = TTPixelLabel.new()
	_daily_status2_label.text = ""
	_daily_status2_label.pixel_size = 4
	_daily_status2_label.color = _trap_col
	_daily_status2_label.align = HORIZONTAL_ALIGNMENT_CENTER
	_daily_status2_label.width = 700.0
	_daily_status2_label.position = Vector2(290, 300)
	_daily_overlay.add_child(_daily_status2_label)
	var play := _make_text_button("PLAY", Vector2(530, 370), Vector2(220, 64), 30, _trap_col, Color.html("FFD23F"))
	play.pressed.connect(_on_daily_play)
	_daily_overlay.add_child(play)
	var close := _make_text_button("CLOSE", Vector2(530, 460), Vector2(220, 64), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_daily)
	_daily_overlay.add_child(close)


func open_daily() -> void:
	if _daily_overlay == null:
		return
	var data := TTProgress.load_progress()
	var today := TTDaily.today_string()
	var rec: Dictionary = TTDaily.best_for(today, data)
	_daily_date_label.text = "TODAY " + today
	if bool(rec.get("completed", false)):
		_daily_status1_label.text = "DONE - BEST " + TTFeatures.format_time(float(rec.get("best_time", 0.0)))
		_daily_status2_label.text = ""
	else:
		_daily_status1_label.text = "NOT DONE YET"
		_daily_status2_label.text = "NEW LEVEL EVERY DAY"
	_daily_date_label.queue_redraw()
	_daily_status1_label.queue_redraw()
	_daily_status2_label.queue_redraw()
	_daily_overlay.visible = true


func close_daily() -> void:
	if _daily_overlay != null:
		_daily_overlay.visible = false


func _on_daily_play() -> void:
	close_daily()
	_start_daily()


func _start_daily() -> void:
	TTState.bonus = false
	TTState.daily = true
	TTState.daily_date = TTDaily.today_string()
	TTState.nightmare = false
	TTState.speedrun_chapter = 0  # Lane U5 STUB (M4): see _start_level.
	TTState.level_index = 0
	get_tree().paused = false
	if _wipe != null:
		await _wipe.cover()
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _build_nightmare_overlay() -> void:
	var shell := _overlay_shell("NIGHTMARE")
	_nightmare_overlay = shell["root"]
	# Two status lines at pixel_size 3: the single line
	# ("LOCKED - FINISH ALL 215 LEVELS - DONE 0/215", 44 chars)
	# overflows the 700px panel at pixel_size 4, and even its first
	# half (31 chars) needs size 3 to fit inside the panel.
	_nightmare_status1_label = TTPixelLabel.new()
	_nightmare_status1_label.text = ""
	_nightmare_status1_label.pixel_size = 3
	_nightmare_status1_label.color = _trap_col
	_nightmare_status1_label.align = HORIZONTAL_ALIGNMENT_CENTER
	_nightmare_status1_label.width = 700.0
	_nightmare_status1_label.position = Vector2(290, 240)
	_nightmare_overlay.add_child(_nightmare_status1_label)
	_nightmare_status2_label = TTPixelLabel.new()
	_nightmare_status2_label.text = ""
	_nightmare_status2_label.pixel_size = 3
	_nightmare_status2_label.color = _trap_col
	_nightmare_status2_label.align = HORIZONTAL_ALIGNMENT_CENTER
	_nightmare_status2_label.width = 700.0
	_nightmare_status2_label.position = Vector2(290, 285)
	_nightmare_overlay.add_child(_nightmare_status2_label)
	var close := _make_text_button("CLOSE", Vector2(530, 440), Vector2(220, 64), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_nightmare_overlay)
	_nightmare_overlay.add_child(close)


func _on_nightmare_button() -> void:
	if not _nightmare_unlocked:
		open_nightmare_locked()
		return
	_nightmare_armed = not _nightmare_armed
	TTState.nightmare_armed = _nightmare_armed
	_refresh_mode_buttons()


func open_nightmare_locked() -> void:
	if _nightmare_overlay == null:
		return
	var data := TTProgress.load_progress()
	var done := (data.get("completed", []) as Array).size()
	_nightmare_status1_label.text = "LOCKED - FINISH ALL 215 LEVELS"
	_nightmare_status2_label.text = "DONE " + str(done) + "/215"
	_nightmare_status1_label.queue_redraw()
	_nightmare_status2_label.queue_redraw()
	_nightmare_overlay.visible = true


func close_nightmare_overlay() -> void:
	if _nightmare_overlay != null:
		_nightmare_overlay.visible = false


# --- Lane U5: end screens (M7 credits, M9 celebration) -------------
# Original art/text throughout; nothing is copied from the official.
# Credits wording is ours ("made by Ahmed" is the user's own credit
# line, already on the map — the official's "LEVEL DEVIL by Adam
# Corey aka @Unept" line is never used). The celebration keeps the
# official's STRUCTURE (billboard + hill + house, checklist M9) with
# our own drawing and our own words ("TOWER CLEAR!", never the
# official's "You did it. you're Free." billboard).

# Celebration backdrop: sky + sun + clouds + green hill + house +
# trees + wooden billboard with a gold star. Drawn, never interactive.
class CelebrationArt extends Control:
	func _draw() -> void:
		# Sun, top-left.
		draw_circle(Vector2(100, 90), 42.0, Color.html("FFD23F"))
		# Clouds: two puffs of overlapping white circles.
		for c in [Vector2(250, 110), Vector2(950, 80)]:
			var s := 1.0 if c.x < 500.0 else 0.8
			draw_circle(c + Vector2(-26, 6) * s, 24.0 * s, Color(1, 1, 1, 0.9))
			draw_circle(c, 30.0 * s, Color(1, 1, 1, 0.9))
			draw_circle(c + Vector2(28, 8) * s, 22.0 * s, Color(1, 1, 1, 0.9))
		# Green hill: one smooth mound, crest ~y530 at centre.
		var hill := PackedVector2Array()
		for i in range(33):
			var x := float(i) * 1280.0 / 32.0
			var y := 620.0 - 90.0 * sin(PI * x / 1280.0)
			hill.append(Vector2(x, y))
		hill.append(Vector2(1280, 720))
		hill.append(Vector2(0, 720))
		draw_colored_polygon(hill, Color.html("58A83C"))
		# Billboard: long posts down to the hill + wooden board.
		var post_col := Color.html("6B4423")
		draw_rect(Rect2(470, 330, 10, 208), post_col)
		draw_rect(Rect2(800, 330, 10, 208), post_col)
		draw_rect(Rect2(440, 180, 400, 150), Color.html("8A5A2B"))
		draw_rect(Rect2(440, 180, 400, 150), Color.html("6B4423"), false, 6.0)
		# Gold star above the board.
		var star := PackedVector2Array()
		for p in TTStar.star_points(22.0, 9.0):
			star.append(p + Vector2(640, 150))
		draw_colored_polygon(star, Color.html("FFD23F"))
		# House on the hill (base y545 meets the hill surface).
		draw_rect(Rect2(860, 465, 120, 80), Color.html("C98A4B"))
		var roof := PackedVector2Array([Vector2(850, 465), Vector2(990, 465), Vector2(920, 415)])
		draw_colored_polygon(roof, Color.html("B03A2E"))
		draw_rect(Rect2(910, 505, 24, 40), Color.html("5B3A1E"))
		draw_rect(Rect2(875, 480, 20, 20), Color.html("FFD23F"))
		# Trees: trunk + round canopy, bases on the hill surface.
		for t in [Vector2(180, 582), Vector2(300, 559)]:
			draw_rect(Rect2(t.x - 7, t.y - 40, 14, 40), Color.html("6B4423"))
			draw_circle(Vector2(t.x, t.y - 62), 30.0, Color.html("3E7D2C"))
			draw_circle(Vector2(t.x, t.y - 84), 22.0, Color.html("3E7D2C"))


func _build_credits() -> void:
	# M7 end-credits: the F3 overlay shell (dim + peach panel +
	# title) with our own credit lines. CONTINUE marks the credits
	# seen (one-shot) and opens whatever the return chain holds.
	var shell := _overlay_shell("THE END")
	_credits = shell["root"]
	var lines: Array = [
		["YOU FINISHED", 5, 190.0],
		["ALL 215 LEVELS!", 5, 250.0],
		["THANKS FOR PLAYING", 4, 305.0],
		["TRAP TOWER", 5, 360.0],
		["MADE BY AHMED", 4, 415.0],
		["BUILT WITH GODOT", 3, 470.0],
	]
	for entry in lines:
		var lab := TTPixelLabel.new()
		lab.text = str(entry[0])
		lab.pixel_size = int(entry[1])
		lab.color = _trap_col
		lab.align = HORIZONTAL_ALIGNMENT_CENTER
		lab.width = 700.0
		lab.position = Vector2(290, float(entry[2]))
		_credits.add_child(lab)
	var cont := _make_text_button("CONTINUE", Vector2(530, 556), Vector2(220, 56), 22, _trap_col, Color.html("FFD23F"))
	cont.pressed.connect(close_credits)
	_credits.add_child(cont)


func open_credits() -> void:
	TTState.pending_credits = false
	if _credits != null:
		_credits.visible = true


func close_credits() -> void:
	if _credits != null:
		_credits.visible = false
	TTProgress.mark_credits_seen()
	_open_pending_return()


func _build_celebration() -> void:
	# M9 celebration: full-screen scene (sky + hill + house +
	# billboard), NOT a panel overlay — it is a place, not a menu.
	_celebration = Control.new()
	_celebration.position = Vector2.ZERO
	_celebration.size = Vector2(1280, 720)
	_celebration.visible = false
	add_child(_celebration)
	var sky := ColorRect.new()
	sky.color = Color.html("7EC8E3")
	sky.position = Vector2.ZERO
	sky.size = Vector2(1280, 720)
	_celebration.add_child(sky)
	var art := CelebrationArt.new()
	art.position = Vector2.ZERO
	art.size = Vector2(1280, 720)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_celebration.add_child(art)
	var title := TTPixelLabel.new()
	title.text = "TOWER CLEAR!"
	title.pixel_size = 5
	title.color = Color.WHITE
	title.align = HORIZONTAL_ALIGNMENT_CENTER
	title.width = 400.0
	title.position = Vector2(440, 208)
	_celebration.add_child(title)
	_celebration_kind_label = TTPixelLabel.new()
	_celebration_kind_label.text = "ALL 215 STARS!"
	_celebration_kind_label.pixel_size = 4
	_celebration_kind_label.color = Color.WHITE
	_celebration_kind_label.align = HORIZONTAL_ALIGNMENT_CENTER
	_celebration_kind_label.width = 400.0
	_celebration_kind_label.position = Vector2(440, 268)
	_celebration.add_child(_celebration_kind_label)
	var thanks := TTPixelLabel.new()
	thanks.text = "THANKS FOR PLAYING"
	thanks.pixel_size = 3
	thanks.color = Color.WHITE
	thanks.align = HORIZONTAL_ALIGNMENT_CENTER
	thanks.width = 1280.0
	thanks.position = Vector2(0, 672)
	_celebration.add_child(thanks)
	var cont := _make_text_button("CONTINUE", Vector2(530, 600), Vector2(220, 56), 22, _trap_col, Color.html("FFD23F"))
	cont.pressed.connect(close_celebration)
	_celebration.add_child(cont)


# M9 open: kind is "keys" (all 15 chapter keys, PRIMARY) or "stars"
# (all 215 stars, FALLBACK). The screen names which one was achieved
# (N5) — the billboard line is set here, not hard-coded.
func open_celebration(kind: String) -> void:
	if _celebration == null:
		return
	_celebration_kind = kind
	if _celebration_kind_label != null:
		if kind == "keys":
			_celebration_kind_label.text = "ALL 15 KEYS!"
		else:
			_celebration_kind_label.text = "ALL 215 STARS!"
		_celebration_kind_label.queue_redraw()
	if _best_label != null:
		_best_label.visible = false
	_celebration.visible = true


func close_celebration() -> void:
	if _celebration != null:
		_celebration.visible = false
	if _best_label != null:
		_best_label.visible = true
	TTProgress.mark_celebration_seen(_celebration_kind)
	_celebration_kind = ""
	_open_pending_return()


# N4 PINNED order: M8 chapter-complete (Ch.3) FIRST, then M7 credits.
# Wired by the coordinator after U4 landed (23 Nov 2026): the final
# end screen opens M8 for Chapter 3; M8's close handler chains
# open_credits() via TTState.pending_credits (see
# _on_chapter_complete_close). M8's screen is open_chapter_complete.
func _show_final_end_screens() -> void:
	open_chapter_complete(3)


# Checked once at the end of _ready. M7 trigger: L215 completed +
# credits not yet seen (any map open — the win return AND a veteran
# player's first post-update open). M9 trigger: the N5 kind, when it
# differs from the already-celebrated one. An end screen stashes the
# return door and clears TTState so the auto-picker stays shut; the
# picker opens from _open_pending_return when the screen closes.
func _check_end_game_screens() -> void:
	var data := TTProgress.load_progress()
	var done: Array = data.get("completed", [])
	if done.has("L215") and not bool(data.get("credits_seen", false)):
		_pending_return_door = TTState.return_door
		TTState.return_door = -1
		_show_final_end_screens()
		return
	var kind := TTFeatures.celebration_kind(data)
	if kind != "" and str(data.get("celebration_seen", "")) != kind:
		_pending_return_door = TTState.return_door
		TTState.return_door = -1
		open_celebration(kind)


# After an end screen closes: a still-pending celebration fires
# first (so M7 credits are followed by M9 when both are owed), else
# the stashed return door's picker opens (45 = bonus picker).
func _open_pending_return() -> void:
	var data := TTProgress.load_progress()
	var kind := TTFeatures.celebration_kind(data)
	if kind != "" and str(data.get("celebration_seen", "")) != kind:
		open_celebration(kind)
		return
	var door := _pending_return_door
	_pending_return_door = -1
	if door == 45:
		open_bonus_picker()
	elif door >= 1:
		open_picker(door)


# --- Lane U5 (M4 speedrun) — APPLIED after U4 landed ---------------
# Everything below calls U4's chapter API. Applied by the coordinator
# after U4 landed, in this order: U5 applicable patches,
# U4 chapter API, then this stub. See M4-SPEEDRUN-STUB.md.

func _build_speedrun_overlay() -> void:
	# One row per chapter: name + best speedrun time. Rows are
	# re-filled with live save numbers on every open.
	var shell := _overlay_shell("SPEEDRUN")
	_speedrun_overlay = shell["root"]
	_speedrun_rows = []
	for ch in [1, 2, 3]:
		var y := 190.0 + float(ch - 1) * 110.0
		var b := _make_text_button("CHAPTER " + str(ch), Vector2(330, y), Vector2(280, 64), 26, _bg_col, _trap_col)
		b.pressed.connect(_on_speedrun_chapter.bind(ch))
		_speedrun_overlay.add_child(b)
		var lab := TTPixelLabel.new()
		lab.text = "BEST --:--"
		lab.pixel_size = 4
		lab.color = _trap_col
		lab.align = HORIZONTAL_ALIGNMENT_RIGHT
		lab.width = 300.0
		lab.position = Vector2(640, y + 16)
		_speedrun_overlay.add_child(lab)
		_speedrun_rows.append({"button": b, "label": lab, "chapter": ch})
	var close := _make_text_button("CLOSE", Vector2(530, 556), Vector2(220, 56), 30, _trap_col, Color.html("FFD23F"))
	close.pressed.connect(close_speedrun)
	_speedrun_overlay.add_child(close)


func open_speedrun() -> void:
	if _speedrun_overlay == null:
		return
	_fill_speedrun()
	_speedrun_overlay.visible = true


func close_speedrun() -> void:
	if _speedrun_overlay != null:
		_speedrun_overlay.visible = false


func _fill_speedrun() -> void:
	var data := TTProgress.load_progress()
	for entry in _speedrun_rows:
		var ch := int(entry["chapter"])
		var lab: TTPixelLabel = entry["label"]
		# U4's API is chapter_label (resolved at merge: the stub's
		# expected chapter_name does not exist; the label is
		# "Chapter 3 - Continuation" per N3 — hyphen, no em-dash,
		# so the pixel font renders it).
		lab.text = "BEST " + TTFeatures.speedrun_best_label(data, ch)
		var b: TTHUD.IconButton = entry["button"]
		b.text = str(TTFeatures.chapter_label(ch)).to_upper()
		b.queue_redraw()
		lab.queue_redraw()


func _on_speedrun_chapter(chapter: int) -> void:
	# Doors in order (U4's chapter_doors API).
	var doors: Array = TTFeatures.chapter_doors(chapter)
	if doors.is_empty():
		return
	# A locked chapter cannot start: its first door must be unlocked.
	if TTDoorMap.door_first_index(int(doors[0])) > _highest:
		return
	_start_speedrun(chapter)


func _start_speedrun(chapter: int) -> void:
	# Doors in order (U4's chapter_doors API).
	var doors: Array = TTFeatures.chapter_doors(chapter)
	if doors.is_empty():
		return
	close_speedrun()
	TTState.bonus = false
	TTState.daily = false
	TTState.daily_date = ""
	TTState.nightmare = false
	TTState.speedrun_chapter = chapter
	TTState.level_index = TTDoorMap.door_first_index(int(doors[0]))
	get_tree().paused = false
	if _wipe != null:
		await _wipe.cover()
	get_tree().change_scene_to_file("res://scenes/game.tscn")
