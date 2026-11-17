class_name TTRuntime
extends Node2D

# Root node of a built level. Owns the per-level rules: hazard death,
# fall death, door win. On death the SAME player node respawns at spawn
# (never freed) and all trap/platform clocks reset, so retries are
# deterministic. Exposes deaths / level_completed for the verifier.

var player: TTPlayer = null
var platforms: Array = []
var hazards: Array = []
var door: TTDoor = null
var spawn_feet := Vector2.ZERO
var spawn_centre := Vector2.ZERO
var deaths := 0
var level_completed := false


func setup(p_player: TTPlayer, p_platforms: Array, p_hazards: Array, p_door: TTDoor, p_spawn_feet: Vector2) -> void:
	player = p_player
	platforms = p_platforms
	hazards = p_hazards
	door = p_door
	spawn_feet = p_spawn_feet
	spawn_centre = p_spawn_feet + Vector2(0, -player.ph * 0.5)


func _physics_process(_delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	if level_completed:
		return
	var prect := player.player_rect()
	for h in hazards:
		if h.kills(prect):
			_die()
			return
	if player.feet_pos().y > 640.0:
		_die()
		return
	if door != null and prect.intersects(door.door_rect()):
		level_completed = true


func _die() -> void:
	deaths += 1
	player.global_position = spawn_centre
	player.velocity = Vector2.ZERO
	player.reset_state()
	for p in platforms:
		p.reset_state()
	for h in hazards:
		h.reset_state()
