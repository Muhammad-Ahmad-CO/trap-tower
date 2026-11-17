class_name TTBuilder
extends RefCounted

# Builds one level dict into a node tree. build_level(level_dict,
# tuning_dict) returns the level root node (a TTRuntime) with the
# CharacterBody2D player under it. Unknown kind/type is a loud error
# (callers validate with TTLevelData first and fail fast).

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
