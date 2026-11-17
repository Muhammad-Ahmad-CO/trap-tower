class_name TTLevelData
extends RefCounted

# Strict runtime validation of res://data/levels.json per LEVEL_SCHEMA.md v1.
# Mirrors tools/check_levels.py rules (a)-(c): versions, fields, unknown
# kind/type = hard error, bounds, safe zones, standing on solid ground.
# Fail fast: any error returns a message; the Game scene refuses to load.

const SCHEMA_VERSION := 1
const SAFE_ZONE := 40.0
const GROUND_TOL := 4.0
const MIN_PLATFORM_H := 16.0
const SAW_R_MIN := 26.0
const SAW_R_MAX := 60.0
const DASHED_MIN_ON := 0.9
const DASHED_MIN_OFF := 0.5
const FALL_MIN_STAND := 0.45
const MOVING_MIN_PERIOD := 1.6
const MIN_DELAY := 0.25

const PLATFORM_KINDS = ["solid", "dashed", "falling", "tilting", "moving"]
const HAZARD_TYPES = ["spikes", "saw", "spiked_column", "hanging_pillar", "dotted_line"]
const SPIKE_DIRS = ["up", "down", "left", "right"]
const STABLE_KINDS = ["solid", "moving"]


static func load_levels(path := "res://data/levels.json") -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"levels": [], "error": "levels file missing: " + path}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"levels": [], "error": "levels.json is not a JSON object"}
	var tuning := TTuning.load_tuning()
	if tuning.is_empty():
		return {"levels": [], "error": "tuning.json missing or invalid"}
	var err := validate_file(parsed, tuning)
	if err != "":
		return {"levels": [], "error": err}
	return {"levels": parsed["levels"], "error": ""}


static func validate_file(data: Dictionary, tuning: Dictionary) -> String:
	if int(data.get("schema_version", -1)) != SCHEMA_VERSION:
		return "schema_version must be %d" % SCHEMA_VERSION
	if int(data.get("tuning_version", -1)) != int(tuning.get("tuning_version", -2)):
		return "tuning_version mismatch with tuning.json"
	var levels: Variant = data.get("levels", null)
	if typeof(levels) != TYPE_ARRAY or (levels as Array).is_empty():
		return "levels must be a non-empty array"
	var seen := {}
	var idx := 0
	for lv in levels:
		if typeof(lv) != TYPE_DICTIONARY:
			return "levels[%d] is not an object" % idx
		var id := str(lv.get("id", ""))
		if id == "":
			return "levels[%d] missing id" % idx
		if seen.has(id):
			return "duplicate level id " + id
		seen[id] = true
		var err := validate_level(lv, idx, tuning)
		if err != "":
			return "level %s: %s" % [id, err]
		idx += 1
	return ""


static func validate_level(lv: Dictionary, index: int, tuning: Dictionary) -> String:
	for f in ["id", "palette", "spawn", "door", "platforms", "hazards", "template", "variation"]:
		var e := _req(lv, f, "level")
		if e != "":
			return e
	if not (lv["id"] is String) or str(lv["id"]) == "":
		return "id must be a non-empty string"
	var pals: Array = tuning.get("palettes", [])
	if not _is_int_num(lv["palette"]) or int(lv["palette"]) < 0 or int(lv["palette"]) >= pals.size():
		return "palette out of range"
	for key in ["template", "variation"]:
		if not (lv[key] is String) or str(lv[key]) == "":
			return key + " must be a non-empty string"
	for key in ["spawn", "door"]:
		var pt: Variant = lv[key]
		if typeof(pt) != TYPE_DICTIONARY or not _is_num(pt.get("x")) or not _is_num(pt.get("y")):
			return key + " must be {x, y} numbers"
	if typeof(lv["platforms"]) != TYPE_ARRAY or (lv["platforms"] as Array).is_empty():
		return "platforms must be a non-empty array"
	if typeof(lv["hazards"]) != TYPE_ARRAY:
		return "hazards must be an array"
	if (lv["hazards"] as Array).is_empty() and index >= 3:
		return "hazards may be empty only for the first 3 teaching levels"
	var i := 0
	for p in lv["platforms"]:
		var e := _validate_platform(p, i, tuning)
		if e != "":
			return e
		i += 1
	i = 0
	for h in lv["hazards"]:
		var e2 := _validate_hazard(h, i, lv)
		if e2 != "":
			return e2
		i += 1
	return _validate_geometry(lv, tuning)


static func _validate_platform(p: Variant, i: int, _tuning: Dictionary) -> String:
	var where := "platforms[%d]" % i
	if typeof(p) != TYPE_DICTIONARY:
		return where + " is not an object"
	for f in ["x", "y", "w", "h", "kind"]:
		var e := _req(p, f, where)
		if e != "":
			return e
	var kind := str(p["kind"])
	if not PLATFORM_KINDS.has(kind):
		return "%s: unknown kind '%s' (hard error)" % [where, kind]
	for f in ["x", "y", "w", "h"]:
		var e2 := _req_num(p, f, where, 0.0, false)
		if e2 != "":
			return e2
	if kind == "dashed":
		for f in ["period", "phase", "on_time"]:
			var e3 := _req_num(p, f, where, 0.0, true)
			if e3 != "":
				return e3
		if float(p["on_time"]) < DASHED_MIN_ON:
			return where + ": on_time < 0.9"
		if float(p["period"]) - float(p["on_time"]) < DASHED_MIN_OFF:
			return where + ": off-time < 0.5"
	elif kind == "falling" or kind == "tilting":
		return _req_num(p, "stand_time", where, FALL_MIN_STAND, true)
	elif kind == "moving":
		for f in ["dx", "dy"]:
			var e4 := _req_num(p, f, where, 0.0, false)
			if e4 != "":
				return e4
		return _req_num(p, "period", where, MOVING_MIN_PERIOD, true)
	return ""


static func _validate_hazard(h: Variant, i: int, lv: Dictionary) -> String:
	var where := "hazards[%d]" % i
	if typeof(h) != TYPE_DICTIONARY:
		return where + " is not an object"
	for f in ["type", "x", "y", "w", "h"]:
		var e := _req(h, f, where)
		if e != "":
			return e
	var htype := str(h["type"])
	if not HAZARD_TYPES.has(htype):
		return "%s: unknown type '%s' (hard error)" % [where, htype]
	for f in ["x", "y", "w", "h"]:
		var e2 := _req_num(h, f, where, 0.0, false)
		if e2 != "":
			return e2
	if h.has("delay"):
		var e3 := _req_num(h, "delay", where, MIN_DELAY, true)
		if e3 != "":
			return e3
	if h.has("trigger_x"):
		var e4 := _req_num(h, "trigger_x", where, 0.0, false)
		if e4 != "":
			return e4
	if htype == "spikes":
		var d := str(h.get("dir", "up"))
		if not SPIKE_DIRS.has(d):
			return where + ": unknown dir '" + d + "'"
		if h.has("period"):
			for f in ["period", "phase", "on_time"]:
				var e5 := _req_num(h, f, where, 0.0, true)
				if e5 != "":
					return e5
			if float(h["on_time"]) < DASHED_MIN_ON:
				return where + ": on_time < 0.9"
			if float(h["period"]) - float(h["on_time"]) < DASHED_MIN_OFF:
				return where + ": off-time < 0.5"
	elif htype == "saw":
		var e6 := _req_num(h, "r", where, 0.0, false)
		if e6 != "":
			return e6
		var r := float(h["r"])
		if r < SAW_R_MIN or r > SAW_R_MAX:
			return where + ": r outside 26..60"
		var has_path: bool = h.has("path")
		var has_swing: bool = h.has("swing")
		if has_path and has_swing:
			return where + ": saw has both path and swing"
		if has_path:
			var path: Variant = h["path"]
			if typeof(path) != TYPE_DICTIONARY:
				return where + ": path must be an object"
			for f in ["x2", "y2"]:
				var e7 := _req_num(path, f, where + ".path", 0.0, false)
				if e7 != "":
					return e7
			return _req_num(h, "period", where, MOVING_MIN_PERIOD, true)
		if has_swing:
			var sw: Variant = h["swing"]
			if typeof(sw) != TYPE_DICTIONARY:
				return where + ": swing must be an object"
			for f in ["pivot_x", "pivot_y", "arc_deg"]:
				var e8 := _req_num(sw, f, where + ".swing", 0.0, false)
				if e8 != "":
					return e8
			return _req_num(sw, "period", where + ".swing", MOVING_MIN_PERIOD, true)
	elif htype == "hanging_pillar":
		var has_trig: bool = h.has("drop_trigger_x")
		var has_per: bool = h.has("period")
		if has_trig == has_per:
			return where + ": hanging_pillar needs exactly one of drop_trigger_x / period"
		if has_trig:
			var e9 := _req_num(h, "drop_trigger_x", where, 0.0, false)
			if e9 != "":
				return e9
		if has_per:
			var e10 := _req_num(h, "period", where, 0.0, true)
			if e10 != "":
				return e10
			var e11 := _req_num(h, "phase", where, 0.0, true)
			if e11 != "":
				return e11
		if h.has("drop_speed"):
			return _req_num(h, "drop_speed", where, 1.0, true)
	elif htype == "dotted_line":
		var linked: Variant = h.get("linked", null)
		if not _is_int_num(linked) or int(linked) < 0 or int(linked) >= (lv["hazards"] as Array).size():
			return where + ": linked is not a valid hazard index"
		if int(linked) == i:
			return where + ": linked to itself"
	return ""


static func _validate_geometry(lv: Dictionary, tuning: Dictionary) -> String:
	var vp: Dictionary = tuning.get("viewport", {"width": 1280, "height": 720})
	var W := float(vp.get("width", 1280))
	var bar_y := float(tuning.get("control_bar", {}).get("y", 580))
	var env: Dictionary = tuning.get("harness_envelope", {})
	var min_landing := float(env.get("min_landing_width", 48))
	var door_d: Dictionary = tuning.get("door", {})
	var door_w := float(door_d.get("width", 54))
	var door_h := float(door_d.get("height", 84))
	var plats: Array = lv["platforms"]
	for idx in range(plats.size()):
		var p: Dictionary = plats[idx]
		var x := float(p["x"])
		var y := float(p["y"])
		var w := float(p["w"])
		var h := float(p["h"])
		if x < 0 or y < 0 or x + w > W or y + h > bar_y:
			return "platforms[%d] outside bounds" % idx
		if w < min_landing:
			return "platforms[%d] w < landing minimum" % idx
		if h < MIN_PLATFORM_H:
			return "platforms[%d] h < 16" % idx
		if str(p["kind"]) == "moving":
			var x2 := x + float(p["dx"])
			var y2 := y + float(p["dy"])
			if x2 < 0 or y2 < 0 or x2 + w > W or y2 + h > bar_y:
				return "platforms[%d] moving end outside bounds" % idx
	var hazards: Array = lv["hazards"]
	for idx in range(hazards.size()):
		var hz: Dictionary = hazards[idx]
		var htype := str(hz["type"])
		if htype == "saw":
			var cx := float(hz["x"])
			var cy := float(hz["y"])
			if cx < 0 or cx > W or cy < 0 or cy > bar_y:
				return "hazards[%d] saw centre outside bounds" % idx
			if hz.has("path"):
				var path: Dictionary = hz["path"]
				if float(path["x2"]) < 0 or float(path["x2"]) > W or float(path["y2"]) < 0 or float(path["y2"]) > bar_y:
					return "hazards[%d] saw path end outside bounds" % idx
			if hz.has("swing"):
				var sw: Dictionary = hz["swing"]
				if float(sw["pivot_x"]) < 0 or float(sw["pivot_x"]) > W or float(sw["pivot_y"]) < 0 or float(sw["pivot_y"]) > bar_y:
					return "hazards[%d] saw pivot outside bounds" % idx
		else:
			var hx := float(hz["x"])
			var hy := float(hz["y"])
			var hw := float(hz["w"])
			var hh := float(hz["h"])
			if hx < 0 or hy < 0 or hx + hw > W or hy + hh > bar_y:
				return "hazards[%d] outside bounds" % idx
	var spawn: Dictionary = lv["spawn"]
	var door: Dictionary = lv["door"]
	var sx := float(spawn["x"])
	var sy := float(spawn["y"])
	if sx < 0 or sx > W or sy < 0 or sy > bar_y:
		return "spawn outside bounds"
	var drect := Rect2(float(door["x"]) - door_w * 0.5, float(door["y"]) - door_h, door_w, door_h)
	if drect.position.x < 0 or drect.position.y < 0 or drect.end.x > W or drect.end.y > bar_y:
		return "door rect outside bounds"
	var near := _hazard_near_point(lv, sx, sy)
	if near != "":
		return "spawn safe zone violated by " + near
	if _hazard_near_door(lv, drect):
		return "door safe zone violated"
	for p2 in plats:
		var pr := Rect2(float(p2["x"]), float(p2["y"]), float(p2["w"]), float(p2["h"]))
		if sx > pr.position.x and sx < pr.end.x and sy > pr.position.y and sy < pr.end.y:
			return "spawn is inside a platform"
		if pr.intersects(drect):
			return "door rect blocked by a platform"
	var spawn_ground := _ground_kinds(lv, sx, sy)
	var door_ground := _ground_kinds(lv, float(door["x"]), float(door["y"]))
	if spawn_ground.is_empty():
		return "spawn does not stand on solid ground"
	if not _has_stable(spawn_ground):
		return "spawn stands only on timed/falling ground"
	if door_ground.is_empty():
		return "door does not stand on solid ground"
	if not _has_stable(door_ground):
		return "door stands only on timed/falling ground"
	return ""


static func _hazard_near_point(lv: Dictionary, px: float, py: float) -> String:
	for h in lv["hazards"]:
		var htype := str(h["type"])
		if htype == "dotted_line":
			continue
		if htype == "saw":
			var r := float(h["r"])
			var pts: Array[Vector2] = [Vector2(float(h["x"]), float(h["y"]))]
			if h.has("path"):
				var path: Dictionary = h["path"]
				var end := Vector2(float(path["x2"]), float(path["y2"]))
				if _seg_point_dist(px, py, pts[0], end) - r < SAFE_ZONE:
					return "saw"
				pts.append(end)
			if h.has("swing"):
				var sw: Dictionary = h["swing"]
				var pivot := Vector2(float(sw["pivot_x"]), float(sw["pivot_y"]))
				for frac in [-1.0, 0.0, 1.0]:
					var ang: float = deg_to_rad(float(sw["arc_deg"])) * 0.5 * frac
					pts.append(pivot + (pts[0] - pivot).rotated(ang))
			for c in pts:
				if Vector2(px, py).distance_to(c) - r < SAFE_ZONE:
					return "saw"
		else:
			var rect := Rect2(float(h["x"]), float(h["y"]), float(h["w"]), float(h["h"]))
			if _point_rect_dist(px, py, rect) < SAFE_ZONE:
				return htype
	return ""


static func _hazard_near_door(lv: Dictionary, drect: Rect2) -> bool:
	var exp := Rect2(drect.position - Vector2(SAFE_ZONE, SAFE_ZONE), drect.size + Vector2(SAFE_ZONE * 2.0, SAFE_ZONE * 2.0))
	for h in lv["hazards"]:
		var htype := str(h["type"])
		if htype == "dotted_line":
			continue
		if htype == "saw":
			var r := float(h["r"])
			var rest := Vector2(float(h["x"]), float(h["y"]))
			var centres: Array[Vector2] = [rest]
			if h.has("path"):
				var path: Dictionary = h["path"]
				var end := Vector2(float(path["x2"]), float(path["y2"]))
				for k in range(13):
					centres.append(rest.lerp(end, float(k) / 12.0))
			if h.has("swing"):
				var sw: Dictionary = h["swing"]
				var pivot := Vector2(float(sw["pivot_x"]), float(sw["pivot_y"]))
				for k in range(13):
					var ang := deg_to_rad(float(sw["arc_deg"])) * 0.5 * sin(TAU * float(k) / 12.0)
					centres.append(pivot + (rest - pivot).rotated(ang))
			for c in centres:
				if _point_rect_dist(c.x, c.y, exp) < r:
					return true
		else:
			var rect := Rect2(float(h["x"]), float(h["y"]), float(h["w"]), float(h["h"]))
			if rect.intersects(exp):
				return true
	return false


static func _ground_kinds(lv: Dictionary, px: float, py: float) -> Array:
	var kinds: Array = []
	for p in lv["platforms"]:
		if absf(float(p["y"]) - py) <= GROUND_TOL and float(p["x"]) <= px and px <= float(p["x"]) + float(p["w"]):
			kinds.append(str(p["kind"]))
	return kinds


static func _has_stable(kinds: Array) -> bool:
	for k in kinds:
		if STABLE_KINDS.has(str(k)):
			return true
	return false


static func _is_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


# JSON.parse_string returns floats for JSON numbers, so integer-valued
# fields (palette, linked) must accept integral floats too. A strict
# `is int` check rejects every level loaded from the shipped JSON file.
static func _is_int_num(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	if typeof(v) == TYPE_FLOAT:
		return float(v) == floor(float(v))
	return false


static func _req(d: Dictionary, key: String, where: String) -> String:
	if not d.has(key):
		return "%s: missing '%s'" % [where, key]
	return ""


static func _req_num(d: Dictionary, key: String, where: String, min_v: float, check_min: bool) -> String:
	var e := _req(d, key, where)
	if e != "":
		return e
	if not _is_num(d[key]):
		return "%s: '%s' must be a number" % [where, key]
	if check_min and float(d[key]) < min_v:
		return "%s: '%s'=%s below minimum %s" % [where, key, str(d[key]), str(min_v)]
	return ""


static func _point_rect_dist(px: float, py: float, r: Rect2) -> float:
	var dx := maxf(r.position.x - px, 0.0)
	dx = maxf(dx, px - r.end.x)
	var dy := maxf(r.position.y - py, 0.0)
	dy = maxf(dy, py - r.end.y)
	return Vector2(dx, dy).length()


static func _seg_point_dist(px: float, py: float, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var denom := ab.length_squared()
	var t := 0.0
	if denom > 0.0:
		t = clampf((Vector2(px, py) - a).dot(ab) / denom, 0.0, 1.0)
	return Vector2(px, py).distance_to(a + ab * t)
