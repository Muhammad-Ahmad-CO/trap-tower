class_name TTRuntime
extends Node2D

# Root node of a built level. Owns the per-level rules: hazard death,
# fall death, door win. Exposes deaths / level_completed / dead for the
# game node and the verifier.
#
# DEATH-FLOW CONTRACT (frozen, LEVEL_SCHEMA.md v3): deaths increments
# SYNCHRONOUSLY inside _die(), in the death frame — never at retry
# time. The dead state then holds: hero hidden + player physics off,
# traps held visible (no trap/platform reset until retry). Retry happens
# on an input edge ONLY (key press / screen touch / mouse click,
# ignoring the death frame itself) — TAP-ONLY, NO AUTO-RETRY. The
# 0.6s auto-retry timer from v1.0.3 was REMOVED in v1.0.4 (Round 4,
# Lane Vis decision): the frozen schema says "respawn on TAP (tap-only,
# NO auto-retry)" and the timer contradicted it — a dead player must
# wait for the player's tap, never respawn by itself. At retry the SAME
# player node respawns at spawn and all trap/platform clocks reset, so
# retries are deterministic. _physics_process early-returns while dead:
# no double-death, no win check while dead. The autopilot ends its
# attempt on the deaths increase and rebuilds, so the dead state never
# gates death detection.

var player: TTPlayer = null
var platforms: Array = []
var hazards: Array = []
var door: TTDoor = null
var spawn_feet := Vector2.ZERO
var spawn_centre := Vector2.ZERO
var deaths := 0
var level_completed := false
var dead := false

var _death_gen := 0
var _death_process_frame := -1


func setup(p_player: TTPlayer, p_platforms: Array, p_hazards: Array, p_door: TTDoor, p_spawn_feet: Vector2) -> void:
	player = p_player
	platforms = p_platforms
	hazards = p_hazards
	door = p_door
	spawn_feet = p_spawn_feet
	spawn_centre = p_spawn_feet + Vector2(0, -player.ph * 0.5)
	dead = false


func _physics_process(_delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	if dead:
		return
	if level_completed:
		return
	var prect := player.player_rect()
	for h in hazards:
		if h.kills(prect):
			_die()
			return
	if player.feet_pos().y > TTuning.FALL_DEATH_Y:
		_die()
		return
	if door != null and prect.intersects(door.door_rect()):
		level_completed = true


func _unhandled_input(event: InputEvent) -> void:
	if not dead:
		return
	# Ignore the death frame itself: input dispatched in the same
	# rendered frame as the death must not instantly retry.
	if Engine.get_process_frames() <= _death_process_frame:
		return
	var edge := false
	if event is InputEventKey:
		var key := event as InputEventKey
		edge = key.pressed and not key.echo
	elif event is InputEventScreenTouch:
		edge = (event as InputEventScreenTouch).pressed
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		edge = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	if edge:
		_retry()


func _die() -> void:
	# Synchronous: the deaths increase IS the death signal for the
	# autopilot and the game mirror. Everything else is the hold state.
	deaths += 1
	dead = true
	_death_gen += 1
	_death_process_frame = Engine.get_process_frames()
	if player != null and is_instance_valid(player):
		player.velocity = Vector2.ZERO
		player.visible = false
		player.set_physics_process(false)
	# Traps/platforms are deliberately NOT reset here: they stay held
	# visible until retry. No auto-retry timer (tap-only, see contract).


func _retry() -> void:
	if not dead:
		return
	dead = false
	if player == null or not is_instance_valid(player):
		return
	# Respawn FIRST: hazard reset_state() reads the player position.
	player.global_position = spawn_centre
	player.velocity = Vector2.ZERO
	player.reset_state()
	player.visible = true
	player.set_physics_process(true)
	for p in platforms:
		p.reset_state()
	for h in hazards:
		h.reset_state()
