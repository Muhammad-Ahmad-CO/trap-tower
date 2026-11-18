class_name TTBuilder
extends RefCounted

# Builds one level dict into a node tree. build_level(level_dict,
# tuning_dict) returns the level root node (a TTRuntime) with the
# CharacterBody2D player under it. Unknown kind/type is a loud error
# (callers validate with TTLevelData first and fail fast).

# Draw-only background silhouette (LEVEL_SCHEMA.md rule 10): a plain
# Node2D with no collision body and no gameplay effect. One per
# decoration rect, drawn below platforms/hazards/hero/door.
class DecoRect extends Node2D:
	var rect := Rect2()
	var deco_col := Color.WHITE

	func setup(d: Dictionary, color: Color) -> void:
		rect = Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("w", 0.0)), float(d.get("h", 0.0)))
		deco_col = color
		# Background layer: z 0 draws ABOVE the opaque bg ColorRect
		# (game.gd adds bg before the runtime node, so same-z tree
		# order puts runtime children over it) and BELOW platforms
		# (z 0, added after decorations), door (z 1), hazards
		# (z 10), and the player (z 20). z -1 drew UNDER the bg.
		z_index = 0
		position = rect.position

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, rect.size), deco_col)


var root: TTRuntime = null
var player: TTPlayer = null
var platforms: Array = []
var hazards: Array = []
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
	var bar_y := float(tuning.get("control_bar", {}).get("y", 580))
	platforms = []
	hazards = []
	player = TTPlayer.new()
	player.setup(tuning)
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
		var deco := DecoRect.new()
		deco.setup(d, deco_col)
		rt.add_child(deco)
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
		node.setup(h, trap_col, player, bar_y)
		rt.add_child(node)
		hazards.append(node)
	rt.add_child(player)
	rt.setup(player, platforms, hazards, door, spawn_point)
	return rt
