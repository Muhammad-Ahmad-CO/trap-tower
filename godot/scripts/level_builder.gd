class_name TTBuilder
extends RefCounted

# Builds one level dict into a node tree. build_level(level_dict,
# tuning_dict) returns the level root node (a TTRuntime) with the
# CharacterBody2D player under it. Unknown kind/type is a loud error
# (callers validate with TTLevelData first and fail fast).

# Draw-only background silhouette (LEVEL_SCHEMA.md rule 10): a plain
# Node2D with no collision body and no gameplay effect. One per
# decoration entry, drawn below platforms/hazards/hero/door.
# Lane U2 (M10-full): each entry may carry an OPTIONAL `shape`
# ("rect" | "cloud" | "tree" | "hill" | "palm", default "rect").
# Every shape is drawn COMPOSED of rects/circles in deco_col ONLY
# (same strict 2-colour discipline — no new colours; shapes are
# original silhouettes in the deco tint, never a copy of the
# official's cloud/tree art). Every primitive stays inside the
# entry's bounding rect, which is exactly what the checker
# validates (rule 10: attachment, keep-out, no hazard/spawn/door
# overlap, w >= 48, h >= 16).
const DECO_SHAPES = ["rect", "cloud", "tree", "hill", "palm"]

class DecoRect extends Node2D:
	var rect := Rect2()
	var deco_col := Color.WHITE
	var shape := "rect"

	func setup(d: Dictionary, color: Color) -> void:
		rect = Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("w", 0.0)), float(d.get("h", 0.0)))
		deco_col = color
		shape = str(d.get("shape", "rect"))
		# Background layer: z 0 draws ABOVE the opaque bg ColorRect
		# (game.gd adds bg before the runtime node, so same-z tree
		# order puts runtime children over it) and BELOW platforms
		# (z 0, added after decorations), door (z 1), hazards
		# (z 10), and the player (z 20). z -1 drew UNDER the bg.
		z_index = 0
		position = rect.position

	func _draw() -> void:
		match shape:
			"cloud":
				_draw_cloud()
			"tree":
				_draw_tree()
			"hill":
				_draw_hill()
			"palm":
				_draw_palm()
			_:
				draw_rect(Rect2(Vector2.ZERO, rect.size), deco_col)

	# Cloud: three overlapping puffs over a flat base slab.
	func _draw_cloud() -> void:
		var w := rect.size.x
		var h := rect.size.y
		draw_rect(Rect2(0, h * 0.55, w, h * 0.45), deco_col)
		draw_circle(Vector2(w * 0.22, h * 0.55), h * 0.32, deco_col)
		draw_circle(Vector2(w * 0.50, h * 0.42), h * 0.38, deco_col)
		draw_circle(Vector2(w * 0.78, h * 0.55), h * 0.30, deco_col)

	# Tree: centred trunk, bottom-anchored, with a three-circle canopy.
	func _draw_tree() -> void:
		var w := rect.size.x
		var h := rect.size.y
		draw_rect(Rect2(w * 0.44, h * 0.55, w * 0.12, h * 0.45), deco_col)
		draw_circle(Vector2(w * 0.30, h * 0.40), h * 0.28, deco_col)
		draw_circle(Vector2(w * 0.50, h * 0.34), h * 0.32, deco_col)
		draw_circle(Vector2(w * 0.70, h * 0.40), h * 0.28, deco_col)

	# Hill: blocky stepped dome, wide at the base, narrow at the crest.
	func _draw_hill() -> void:
		var w := rect.size.x
		var h := rect.size.y
		draw_rect(Rect2(w * 0.30, h * 0.15, w * 0.40, h * 0.20), deco_col)
		draw_rect(Rect2(w * 0.15, h * 0.35, w * 0.70, h * 0.20), deco_col)
		draw_rect(Rect2(w * 0.05, h * 0.55, w * 0.90, h * 0.20), deco_col)
		draw_rect(Rect2(0, h * 0.75, w, h * 0.25), deco_col)

	# Palm: leaning trunk of three stacked rects, a crown circle,
	# and five thin fronds fanning from the crown (rotated rects).
	func _draw_palm() -> void:
		var w := rect.size.x
		var h := rect.size.y
		var crown := Vector2(w * 0.45, h * 0.30)
		var flen := 0.34 * minf(w, h)
		var fth := 0.09 * h
		# Frond angles from straight-up: -55, -25, 0, +25, +55 deg.
		# draw_set_transform rotates around the crown; the frond
		# rect runs from the crown outward along local +x.
		var angles := [-145.0, -115.0, -90.0, -65.0, -35.0]
		for a in angles:
			draw_set_transform(crown, deg_to_rad(a), Vector2.ONE)
			draw_rect(Rect2(0, -fth * 0.5, flen, fth), deco_col)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		draw_circle(crown, h * 0.10, deco_col)
		draw_rect(Rect2(w * 0.38, h * 0.32, w * 0.13, h * 0.26), deco_col)
		draw_rect(Rect2(w * 0.42, h * 0.56, w * 0.13, h * 0.24), deco_col)
		draw_rect(Rect2(w * 0.46, h * 0.78, w * 0.13, h * 0.22), deco_col)


var root: TTRuntime = null
var player: TTPlayer = null
var platforms: Array = []
var hazards: Array = []
var coins: Array = []
var door: TTDoor = null
var palette: Dictionary = {}
var spawn_point := Vector2.ZERO


func build_level(level: Dictionary, tuning: Dictionary) -> Node:
	var rt := TTRuntime.new()
	rt.name = "Level"
	root = rt
	palette = TTuning.palette(tuning, int(level.get("palette", 0)))
	var plat_col := TTuning.col(str(palette.get("platform", "#2B0A8A")))
	var trap_col := TTuning.col(str(palette.get("trap", "#2B0A8A")))
	var bg_col := TTuning.col(str(palette.get("bg", "#E8871E")))
	var deco_col := trap_col.lerp(bg_col, 0.55)
	var pl: Dictionary = tuning.get("player", {})
	var gravity := float(pl.get("gravity", 2200.0))
	var floor_y := TTuning.FLOOR_Y
	platforms = []
	hazards = []
	coins = []
	player = TTPlayer.new()
	player.setup(tuning)
	player.set_background(bg_col)
	# Drawing only: keep the player above hazards (z 10), as before
	# (it was added last); z-order only, no physics/behaviour change.
	player.z_index = 20
	var spawn: Dictionary = level.get("spawn", {})
	spawn_point = Vector2(float(spawn.get("x", 70)), float(spawn.get("y", 500)))
	player.position = spawn_point + Vector2(0, -player.ph * 0.5)
	# Decorations: draw-only, background layer, never added to the
	# platforms/hazards arrays (no collision, no gameplay effect).
	# Missing array = none. Malformed entries are skipped silently:
	# rule 10 validation is harness-only, the runtime never warns.
	for d in level.get("decorations", []):
		if typeof(d) != TYPE_DICTIONARY:
			continue
		# Unknown shape = hard error (level_data.gd rejects it at
		# load time; this is the second line of defence — never
		# silently draw a rect for a shape we do not know).
		var shp := str(d.get("shape", "rect"))
		if not DECO_SHAPES.has(shp):
			push_error("builder: unknown deco shape '" + shp + "' (hard error)")
			continue
		var deco := DecoRect.new()
		deco.setup(d, deco_col)
		rt.add_child(deco)
	# Lane U1 (M1): coins — code-drawn TTCoin nodes, z 15, no
	# collision, no gameplay effect except the game's collect poll.
	# Missing array = none. Malformed entries are skipped silently:
	# shape validation is harness-only (tools/check_levels.py), the
	# runtime never warns — same treatment as decorations.
	for c in level.get("coins", []):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var coin := TTCoin.new()
		coin.setup(Vector2(float(c.get("x", 0.0)), float(c.get("y", 0.0))))
		rt.add_child(coin)
		coins.append(coin)
	for p in level.get("platforms", []):
		var kind := str(p.get("kind", ""))
		if not TTLevelData.PLATFORM_KINDS.has(kind):
			push_error("builder: unknown platform kind '" + kind + "' (hard error)")
			continue
		var node := TTPlatform.new()
		node.setup(p, plat_col, gravity)
		node.player = player
		rt.add_child(node)
		platforms.append(node)
	door = TTDoor.new()
	door.setup(level.get("door", {}), tuning)
	rt.add_child(door)
	for h in level.get("hazards", []):
		var htype := str(h.get("type", ""))
		if not TTLevelData.HAZARD_TYPES.has(htype):
			push_error("builder: unknown hazard type '" + htype + "' (hard error)")
			continue
		var node := TTHazard.new()
		node.setup(h, trap_col, player, floor_y)
		rt.add_child(node)
		hazards.append(node)
	rt.add_child(player)
	rt.setup(player, platforms, hazards, door, spawn_point)
	return rt
