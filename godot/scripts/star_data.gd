class_name TTStarData
extends RefCounted

# Hidden-star positions: res://data/stars.json, keyed by level ID
# (L001..L215 + B001..B005). NEVER in levels.json — the level file is
# owned by Lane 2b and the star file is owned by Lane F1.
# Missing file / bad entry = no star (never a load error): the game
# must keep working if the star file is absent.

const PATH := "res://data/stars.json"

static var _cache: Dictionary = {}
static var _loaded := false


static func load_stars() -> Dictionary:
	if _loaded:
		return _cache
	_loaded = true
	if not FileAccess.file_exists(PATH):
		return _cache
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if typeof(parsed) == TYPE_DICTIONARY:
		_cache = parsed
	return _cache


static func star_for(level_id: String) -> Vector2:
	var stars := load_stars()
	if not stars.has(level_id):
		return Vector2.INF
	var d: Variant = stars[level_id]
	if typeof(d) != TYPE_DICTIONARY:
		return Vector2.INF
	if not d.has("x") or not d.has("y"):
		return Vector2.INF
	return Vector2(float(d["x"]), float(d["y"]))


static func has_star(level_id: String) -> bool:
	return star_for(level_id) != Vector2.INF
