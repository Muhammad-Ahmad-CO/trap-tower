class_name EffekseerFX
# Shared Effekseer spawn helper (Lane 7, Trap Tower v1.0.5).
#
# Loads the two authored .efkefc effects once and spawns them.
# Every spawn reports success, so callers can fall back to the existing
# code-drawn particles when the plugin or an effect is unavailable.
# Never crashes: if the plugin classes / singleton / effect are missing,
# the helpers return null / false and the caller keeps the old visuals.
#
# Units (calibrated against the Godot plugin, see verification notes):
# 1 effect unit == 1 screen pixel at emitter scale 1; velocity is per
# frame; effect -Y == screen down.

const DEATH_PATH := "res://assets/effects/death_burst.efkefc"
const CONFETTI_PATH := "res://assets/effects/door_confetti.efkefc"

# Door confetti tints (same palette as the code-drawn pieces): white,
# HUD yellow, HUD dark-red. One 12-piece effect spawn per tint == 36.
const CONFETTI_COLOURS: Array[Color] = [
	Color(1, 1, 1),
	Color(1.0, 0.824, 0.247),
	Color(0.43, 0.04, 0.04),
]

static var _death: Resource = null
static var _confetti: Resource = null
static var _checked := false
static var _available := false


static func available() -> bool:
	if not _checked:
		_checked = true
		_available = ClassDB.class_exists("EffekseerEmitter2D") \
			and Engine.has_singleton("EffekseerSystem")
	return _available


static func _load(path: String) -> Resource:
	if not available():
		return null
	var fx: Resource = load(path)
	return fx


static func death_effect() -> Resource:
	if _death == null:
		_death = _load(DEATH_PATH)
	return _death


static func confetti_effect() -> Resource:
	if _confetti == null:
		_confetti = _load(CONFETTI_PATH)
	return _confetti


# One-shot emitter: plays once, frees itself when finished (autofree).
# Returns the emitter node, or null when the effect could not spawn.
# `at` is in the parent's local space; `tint` multiplies the effect colour.
static func spawn_one_shot(effect: Resource, parent: Node, at: Vector2, tint: Color) -> Node:
	if effect == null or parent == null:
		return null
	var emitter: Node = ClassDB.instantiate("EffekseerEmitter2D")
	if emitter == null:
		return null
	emitter.set("effect", effect)
	emitter.set("autoplay", false)
	emitter.set("autofree", true)
	if tint != Color(1, 1, 1):
		emitter.set("color", tint)
	parent.add_child(emitter)
	emitter.position = at
	emitter.call("play")
	return emitter
