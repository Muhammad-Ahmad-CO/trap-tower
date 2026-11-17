class_name TTuning
extends RefCounted

# Frozen physics/palette source of truth: res://data/tuning.json.
# Loaded at runtime; never hardcode different values elsewhere.

static var _cache: Dictionary = {}

static func load_tuning() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	var path := "res://data/tuning.json"
	if not FileAccess.file_exists(path):
		push_error("tuning.json missing: " + path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("tuning.json is not a JSON object")
		return {}
	_cache = parsed
	return _cache

static func col(hex: String, alpha := 1.0) -> Color:
	var c := Color.html(hex.trim_prefix("#"))
	c.a = alpha
	return c

static func palette(tuning: Dictionary, index: int) -> Dictionary:
	var pals: Array = tuning.get("palettes", [])
	if pals.is_empty():
		return {"bg": "#E8871E", "platform": "#2B0A8A", "trap": "#2B0A8A"}
	return pals[clampi(index, 0, pals.size() - 1)]
