class_name TTLevelData
extends RefCounted

# Strict runtime validation of res://data/levels.json per LEVEL_SCHEMA.md v3.
# Mirrors tools/check_levels.py rules 1-4: versions, fields, unknown
# kind/type = hard error, bounds, safe zones, standing on solid ground.
# Fail fast: any error returns a message; the Game scene refuses to load.
# Rules 7-8 (grounding, HUD keep-out) are WARN-AND-LOAD here: see
# validate_visual_rules. They never block loading; the harness enforces
# them hard. Rule 9 (density) is harness-only and is not checked here.

const SCHEMA_VERSION := 3
const SAFE_ZONE := 40.0
const GROUND_TOL := 4.0
const MIN_PLATFORM_H := 16.0
const SAW_R_MIN := 18.0
const SAW_R_MAX := 40.0
const DASHED_MIN_ON := 0.9
const DASHED_MIN_OFF := 0.5
const FALL_MIN_STAND := 0.45
const MOVING_MIN_PERIOD := 1.6
const MIN_DELAY := 0.25
const HUD_KEEPOUT_Y := 90.0
const SPAWN_MIN_Y := 134.0
const DOOR_MIN_Y := 174.0
const SHAFT_TOL := 8.0
const REST_OVERLAP := 48.0
const SWING_SAMPLES := 13

const PLATFORM_KINDS = ["solid", "dashed", "falling", "tilting", "moving"]
const HAZARD_TYPES = ["spikes", "saw", "spiked_column", "hanging_pillar"]
const SPIKE_DIRS = ["up", "down", "left", "right"]
const STABLE_KINDS = ["solid", "moving"]


static func load_levels(path := "res://data/levels.json") -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"levels": [], "error": "levels file missing: " + path, "warnings": []}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"levels": [], "error": "levels.json is not a JSON object", "warnings": []}
	var tuning := TTuning.load_tuning()
	if tuning.is_empty():
		return {"levels": [], "error": "tuning.json missing or invalid", "warnings": []}
	var err := validate_file(parsed, tuning)
	if err != "":
		return {"levels": [], "error": err, "warnings": []}
	# Warn-and-load visual rules (7-8): warnings never block loading.
	var warnings: Array[String] = []
	for lv in parsed["levels"]:
		for w in validate_visual_rules(lv, tuning):
			push_warning(w)
			warnings.append(w)
	return {"levels": parsed["levels"], "error": "", "warnings": warnings}


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
	# `decorations` is optional (missing = []): accepted as-is, never
	# validated or warned on here (LEVEL_SCHEMA.md rule 10 is
	# harness-only; the builder draws whatever array is present).
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
			return where + ": r outside 18..40"
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
	var floor_y := TTuning.FLOOR_Y
	var env: Dictionary = tuning.get("harness_envelope", {})
	var min_landing := float(env.get("min_landing_width", 48))
	var door_w := TTuning.DOOR_W
	var door_h := TTuning.DOOR_H
	var plats: Array = lv["platforms"]
	for idx in range(plats.size()):
		var p: Dictionary = plats[idx]
		var x := float(p["x"])
		var y := float(p["y"])
		var w := float(p["w"])
		var h := float(p["h"])
		if x < 0 or y < 0 or x + w > W or y + h > floor_y:
			return "platforms[%d] outside bounds" % idx
		if w < min_landing:
			return "platforms[%d] w < landing minimum" % idx
		if h < MIN_PLATFORM_H:
			return "platforms[%d] h < 16" % idx
		if str(p["kind"]) == "moving":
			var x2 := x + float(p["dx"])
			var y2 := y + float(p["dy"])
			if x2 < 0 or y2 < 0 or x2 + w > W or y2 + h > floor_y:
				return "platforms[%d] moving end outside bounds" % idx
	var hazards: Array = lv["hazards"]
	for idx in range(hazards.size()):
		var hz: Dictionary = hazards[idx]
		var htype := str(hz["type"])
		if htype == "saw":
			var cx := float(hz["x"])
			var cy := float(hz["y"])
			if cx < 0 or cx > W or cy < 0 or cy > floor_y:
				return "hazards[%d] saw centre outside bounds" % idx
			if hz.has("path"):
				var path: Dictionary = hz["path"]
				if float(path["x2"]) < 0 or float(path["x2"]) > W or float(path["y2"]) < 0 or float(path["y2"]) > floor_y:
					return "hazards[%d] saw path end outside bounds" % idx
			if hz.has("swing"):
				var sw: Dictionary = hz["swing"]
				if float(sw["pivot_x"]) < 0 or float(sw["pivot_x"]) > W or float(sw["pivot_y"]) < 0 or float(sw["pivot_y"]) > floor_y:
					return "hazards[%d] saw pivot outside bounds" % idx
		else:
			var hx := float(hz["x"])
			var hy := float(hz["y"])
			var hw := float(hz["w"])
			var hh := float(hz["h"])
			if hx < 0 or hy < 0 or hx + hw > W or hy + hh > floor_y:
				return "hazards[%d] outside bounds" % idx
	var spawn: Dictionary = lv["spawn"]
	var door: Dictionary = lv["door"]
	var sx := float(spawn["x"])
	var sy := float(spawn["y"])
	if sx < 0 or sx > W or sy < 0 or sy > floor_y:
		return "spawn outside bounds"
	var drect := Rect2(float(door["x"]) - door_w * 0.5, float(door["y"]) - door_h, door_w, door_h)
	if drect.position.x < 0 or drect.position.y < 0 or drect.end.x > W or drect.end.y > floor_y:
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


# Warn-and-load visual rules 7 (grounding) and 8 (HUD keep-out) from
# LEVEL_SCHEMA.md v3. Returns one string per violation, each naming the
# level id and the rule. Callers must run validate_level first: this
# function assumes fields exist and geometry is in bounds. It mirrors
# the checker's geometric predicates; deliberate simplifications where
# the schema text leaves a reading open (the verification lane
# cross-checks zero warnings on the shipped file, so drift surfaces):
# - Swing arcs are 13 UNIFORM samples from -half-arc to +half-arc
#   (the motion-time sine sampling in _hazard_near_door covers the
#   same extremes but clusters samples; uniform sampling matches the
#   schema's "13-sample swing arc" wording).
# - Path saws are checked at endpoints only, per the schema wording;
#   the path interior is not sampled (exact for the y-extent, since
#   the path is a straight segment).
# - Resting support must be GROUNDED solids, with the checker's
#   combined-overlap rule: one support with >= 48px overlap, or both
#   end regions on supports totalling >= 48px (gap <= 4).
# - Ends-touching has NO shape test (Lead decision, LEVEL_SCHEMA.md
#   v3 rule 7): "vertical" means grounded-via-fixpoint. Any grounded
#   solid counts if the y-overlap is >= 8px.
# - Pillar-connected follows the checker exactly: the pillar must
#   itself be grounded (fixpoint), w >= 48, top touching the
#   platform bottom (gap <= 4), x-span within the platform span.
# - Shaft columns must span the sweep y-range within a 4px slack.
# - Resting for dashed/falling/tilting/moving uses the same
#   combined-overlap rule as solids (checker _resting_on).
# - Hazard supports (spike seats, saw touch, column bottom) may be
#   ANY solid rect, with >= 8px overlap (checker seating rule); a
#   floating support is flagged once by the platform rule instead of
#   once per hazard. Grounded is required only where the schema says
#   so: down-spike beams, column beams, swing pivots, and shaft
#   columns.
# - Moving platforms: shaft-flanking uses the full sweep rect;
#   resting uses the home rect.
static func validate_visual_rules(lv: Dictionary, tuning: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var id := str(lv.get("id", "?"))
	var floor_y := TTuning.FLOOR_Y
	var plats: Array = lv.get("platforms", [])
	var hazards: Array = lv.get("hazards", [])
	var grounded := _vis_grounded_flags(plats, floor_y)
	for i in range(plats.size()):
		var p: Dictionary = plats[i]
		var kind := str(p.get("kind", ""))
		if kind == "solid":
			if not grounded[i]:
				out.append("level %s rule 7: platforms[%d] solid is not grounded (floating)" % [id, i])
		elif not _vis_platform_supported(i, plats, grounded):
			out.append("level %s rule 7: platforms[%d] %s is neither shaft-flanked nor resting" % [id, i, kind])
	for i in range(hazards.size()):
		_vis_check_hazard_grounding(hazards[i], i, plats, grounded, floor_y, id, out)
	# Rule 8: no drawn extent in y < 90; spawn feet >= 134; door >= 174.
	var spawn: Dictionary = lv.get("spawn", {})
	if float(spawn.get("y", 0)) < SPAWN_MIN_Y:
		out.append("level %s rule 8: spawn feet y < 134 (hero head enters HUD band)" % id)
	var door: Dictionary = lv.get("door", {})
	if float(door.get("y", 0)) < DOOR_MIN_Y:
		out.append("level %s rule 8: door base y < 174 (door top enters HUD band)" % id)
	for i in range(plats.size()):
		var sweep := _vis_sweep_rect(plats[i])
		if sweep.position.y < HUD_KEEPOUT_Y:
			out.append("level %s rule 8: platforms[%d] drawn extent enters HUD band (y < 90)" % [id, i])
	for i in range(hazards.size()):
		var h: Dictionary = hazards[i]
		if str(h.get("type", "")) == "saw":
			var r := float(h.get("r", 0))
			for c in _vis_saw_centres(h):
				if c.y - r < HUD_KEEPOUT_Y:
					out.append("level %s rule 8: hazards[%d] saw disc enters HUD band (y < 90)" % [id, i])
					break
		elif float(h.get("y", 0)) < HUD_KEEPOUT_Y:
			out.append("level %s rule 8: hazards[%d] drawn extent enters HUD band (y < 90)" % [id, i])
	return out


static func _vis_rect(p: Dictionary) -> Rect2:
	return Rect2(float(p.get("x", 0)), float(p.get("y", 0)), float(p.get("w", 0)), float(p.get("h", 0)))


static func _vis_sweep_rect(p: Dictionary) -> Rect2:
	var r := _vis_rect(p)
	if str(p.get("kind", "")) == "moving":
		var end := Rect2(r.position + Vector2(float(p.get("dx", 0)), float(p.get("dy", 0))), r.size)
		return r.merge(end)
	return r


static func _vis_x_overlap(a: Rect2, b: Rect2) -> float:
	return minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)


static func _vis_y_overlap(a: Rect2, b: Rect2) -> float:
	return minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)


static func _vis_saw_centres(h: Dictionary) -> Array[Vector2]:
	var rest := Vector2(float(h.get("x", 0)), float(h.get("y", 0)))
	if h.has("swing"):
		var sw: Dictionary = h["swing"]
		var pivot := Vector2(float(sw.get("pivot_x", 0)), float(sw.get("pivot_y", 0)))
		var half := deg_to_rad(float(sw.get("arc_deg", 0))) * 0.5
		var centres: Array[Vector2] = []
		for k in range(SWING_SAMPLES):
			var frac := -1.0 + 2.0 * float(k) / float(SWING_SAMPLES - 1)
			centres.append(pivot + (rest - pivot).rotated(half * frac))
		return centres
	var centres2: Array[Vector2] = [rest]
	if h.has("path"):
		var path: Dictionary = h["path"]
		centres2.append(Vector2(float(path.get("x2", 0)), float(path.get("y2", 0))))
	return centres2


# Fixpoint: a solid is grounded if it stands on the floor, rests on a
# grounded solid, is pillar-connected to a grounded solid,
# or has both ends touching grounded solids.
static func _vis_grounded_flags(plats: Array, floor_y: float) -> Array:
	var grounded: Array = []
	for i in range(plats.size()):
		grounded.append(false)
	var changed := true
	var guard := 0
	while changed and guard <= plats.size() + 1:
		changed = false
		guard += 1
		for i in range(plats.size()):
			if str(plats[i].get("kind", "")) != "solid" or grounded[i]:
				continue
			if _vis_solid_grounded(i, plats, grounded, floor_y):
				grounded[i] = true
				changed = true
	return grounded


# Checker _resting_on exactly: one grounded support with x-overlap
# >= 48, or both end regions (third = max(8, w/3)) on grounded
# supports with >= 8px each and combined overlap >= 48. Gap <= 4.
static func _vis_resting_on(r: Rect2, plats: Array, grounded: Array) -> bool:
	var bottom := r.end.y
	var total := 0.0
	var left_ok := false
	var right_ok := false
	var third := maxf(8.0, r.size.x / 3.0)
	var left_region := Rect2(r.position, Vector2(third, r.size.y))
	var right_region := Rect2(Vector2(r.end.x - third, r.position.y), Vector2(third, r.size.y))
	for j in range(plats.size()):
		if not grounded[j]:
			continue
		var s := _vis_rect(plats[j])
		if absf(bottom - s.position.y) > GROUND_TOL:
			continue
		var ov := _vis_x_overlap(r, s)
		if ov >= REST_OVERLAP:
			return true
		total += maxf(0.0, ov)
		if _vis_x_overlap(left_region, s) >= 8.0:
			left_ok = true
		if _vis_x_overlap(right_region, s) >= 8.0:
			right_ok = true
	return left_ok and right_ok and total >= REST_OVERLAP


static func _vis_solid_grounded(i: int, plats: Array, grounded: Array, floor_y: float) -> bool:
	var r := _vis_rect(plats[i])
	if absf(r.end.y - floor_y) <= GROUND_TOL:
		return true
	if _vis_resting_on(r, plats, grounded):
		return true
	for j in range(plats.size()):
		if j == i or not grounded[j]:
			continue
		var q2 := _vis_rect(plats[j])
		if q2.size.x < REST_OVERLAP:
			continue
		if absf(q2.position.y - r.end.y) > GROUND_TOL:
			continue
		if q2.position.x < r.position.x or q2.end.x > r.end.x:
			continue
		return true
	var left := false
	var right := false
	for j in range(plats.size()):
		if j == i or not grounded[j]:
			continue
		var q3 := _vis_rect(plats[j])
		if _vis_y_overlap(r, q3) < 8.0:
			continue
		if absf(q3.end.x - r.position.x) <= GROUND_TOL:
			left = true
		if absf(q3.position.x - r.end.x) <= GROUND_TOL:
			right = true
	return left and right


static func _vis_platform_supported(i: int, plats: Array, grounded: Array) -> bool:
	var home := _vis_rect(plats[i])
	var sweep := _vis_sweep_rect(plats[i])
	if _vis_resting_on(home, plats, grounded):
		return true
	var left := false
	var right := false
	for j in range(plats.size()):
		if j == i or str(plats[j].get("kind", "")) != "solid" or not grounded[j]:
			continue
		var q := _vis_rect(plats[j])
		if q.position.y > sweep.position.y + GROUND_TOL or q.end.y < sweep.end.y - GROUND_TOL:
			continue
		var lgap := sweep.position.x - q.end.x
		var rgap := q.position.x - sweep.end.x
		if lgap >= -GROUND_TOL and lgap <= SHAFT_TOL:
			left = true
		if rgap >= -GROUND_TOL and rgap <= SHAFT_TOL:
			right = true
	return left and right


static func _vis_check_hazard_grounding(h: Dictionary, i: int, plats: Array, grounded: Array, floor_y: float, id: String, out: Array[String]) -> void:
	var htype := str(h.get("type", ""))
	if htype == "hanging_pillar" or htype == "dotted_line":
		return
	var r := _vis_rect(h)
	if htype == "spikes":
		var dir := str(h.get("dir", "up"))
		var seated := false
		for j in range(plats.size()):
			if str(plats[j].get("kind", "")) != "solid":
				continue
			var q := _vis_rect(plats[j])
			if dir == "up":
				if absf(q.position.y - r.end.y) <= GROUND_TOL and _vis_x_overlap(r, q) >= 8.0:
					seated = true
			elif dir == "down":
				if grounded[j] and absf(q.end.y - r.position.y) <= GROUND_TOL and _vis_x_overlap(r, q) >= 8.0:
					seated = true
			elif dir == "left":
				if absf(q.position.x - r.end.x) <= GROUND_TOL and _vis_y_overlap(r, q) >= 8.0:
					seated = true
			elif dir == "right":
				if absf(q.end.x - r.position.x) <= GROUND_TOL and _vis_y_overlap(r, q) >= 8.0:
					seated = true
		if not seated:
			out.append("level %s rule 7: hazards[%d] spikes (%s) are not seated on a solid surface" % [id, i, dir])
	elif htype == "saw":
		var rad := float(h.get("r", 0))
		var centres := _vis_saw_centres(h)
		# Rule 7 (Stage 2 §4.3 R1, mirrors check_levels.py): a MOVING saw
		# (path/swing) is grounded iff AT LEAST ONE swept centre touches
		# solid. A gap-patrol disc inherently cannot touch solid over the
		# gap, so the old per-sample rule warned on every such saw by
		# construction. Static saws have one centre, so the rule is
		# unchanged for them.
		var moving := h.has("path") or h.has("swing")
		var any_touches := false
		for k in range(centres.size()):
			var touches := false
			for j in range(plats.size()):
				if str(plats[j].get("kind", "")) != "solid":
					continue
				if _point_rect_dist(centres[k].x, centres[k].y, _vis_rect(plats[j])) <= rad + GROUND_TOL:
					touches = true
					break
			if touches:
				any_touches = true
				break
			if not moving:
				out.append("level %s rule 7: hazards[%d] saw disc does not touch solid geometry at sweep sample %d" % [id, i, k])
				break
		if moving and not any_touches:
			out.append("level %s rule 7: hazards[%d] saw disc does not touch solid geometry at any sweep sample" % [id, i])
		if h.has("swing"):
			var sw: Dictionary = h["swing"]
			var pivot := Vector2(float(sw.get("pivot_x", 0)), float(sw.get("pivot_y", 0)))
			var inside := false
			for j in range(plats.size()):
				if str(plats[j].get("kind", "")) != "solid" or not grounded[j]:
					continue
				var q2 := _vis_rect(plats[j])
				if pivot.x >= q2.position.x and pivot.x <= q2.end.x and pivot.y >= q2.position.y and pivot.y <= q2.end.y:
					inside = true
					break
			if not inside:
				out.append("level %s rule 7: hazards[%d] swing pivot is not inside a solid beam" % [id, i])
	elif htype == "spiked_column":
		var ok := absf(r.end.y - floor_y) <= GROUND_TOL
		for j in range(plats.size()):
			if str(plats[j].get("kind", "")) != "solid":
				continue
			var q3 := _vis_rect(plats[j])
			if absf(q3.position.y - r.end.y) <= GROUND_TOL and _vis_x_overlap(r, q3) >= 8.0:
				ok = true
			if grounded[j] and absf(q3.end.y - r.position.y) <= GROUND_TOL and _vis_x_overlap(r, q3) >= 8.0:
				ok = true
		if not ok:
			out.append("level %s rule 7: hazards[%d] spiked_column is neither grounded nor hung from a beam" % [id, i])


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
