class_name TTFeatures
extends RefCounted

# Lane F3 (v1.0.5 Part B): achievements + stats logic. PURE logic —
# no file IO, no scene tree. All persistence lives in TTProgress;
# this class only defines the achievement table, evaluates unlock
# conditions from a save-data Dictionary (the TTProgress contract
# fields), and formats stats numbers. Every string here uses only
# glyphs in the code-drawn pixel font (A-Z, a-z, 0-9, space and the
# documented punctuation set) — never an em dash, quote or emoji.
#
# Save-field contract (shared with the stars/daily/nightmare lanes):
#   stars_collected: Array of level IDs
#   daily_best: Dictionary date "YYYY-MM-DD" -> {"completed": bool, "best_time": float}
#   nightmare_cleared: bool
#   deaths: int ; total_time: float ; best_times: Dictionary level ID -> float
#   achievements_unlocked: Array of achievement IDs
#   ghosts: (kept in a separate user://ghosts.cfg by TTProgress)
# Extra F3-owned field: best_improved_count (int) — how many times the
# player has beaten a previous best time; drives GHOST RACER.

const TOTAL_LEVELS := 215
const DAILY_STREAK_TARGET := 3

# id, title, description. 12 achievements.
const ACHIEVEMENTS: Array = [
	{"id": "first_steps", "title": "FIRST STEPS", "desc": "Finish your first level."},
	{"id": "first_door", "title": "DOOR OPENER", "desc": "Finish all stages of one door."},
	{"id": "first_star", "title": "STAR HUNTER", "desc": "Collect your first hidden star."},
	{"id": "star_50", "title": "STAR COLLECTOR", "desc": "Collect 50 hidden stars."},
	{"id": "star_door", "title": "DOOR OF STARS", "desc": "Find every star in one door."},
	{"id": "deaths_100", "title": "NEVER GIVE UP", "desc": "Die 100 times and keep going."},
	{"id": "deaths_500", "title": "TRAP MAGNET", "desc": "Die 500 times. Ouch."},
	{"id": "speedster", "title": "SPEEDSTER", "desc": "Finish a level in under 10 seconds."},
	{"id": "ghost_racer", "title": "GHOST RACER", "desc": "Beat your own best time."},
	{"id": "all_215", "title": "TOWER MASTER", "desc": "Finish all 215 levels."},
	{"id": "nightmare_cleared", "title": "NIGHTMARE SLAYER", "desc": "Clear Nightmare mode."},
	{"id": "daily_streak", "title": "DAILY GRIND", "desc": "Daily challenge 3 days in a row."},
]


static func achievement_ids() -> Array:
	var out: Array = []
	for a in ACHIEVEMENTS:
		out.append(str(a["id"]))
	return out


static func achievement_by_id(ach_id: String) -> Dictionary:
	for a in ACHIEVEMENTS:
		if str(a["id"]) == ach_id:
			return a
	return {}


# Evaluate unlock conditions against save data. level_ids is the
# ordered list of all level IDs (index -> id); pass [] and the
# door-based checks (first_door, star_door) simply never fire, so
# callers that only changed deaths/stars can pass [] safely — but
# the win path and check_achievements() always pass the real list.
# today_override ("YYYY-MM-DD") exists only for tests; "" = system date.
# Returns the achievement IDs that are BOTH met AND not yet unlocked.
static func evaluate(data: Dictionary, level_ids: Array = [], today_override: String = "") -> Array:
	var unlocked: Array = data.get("achievements_unlocked", [])
	var completed: Array = data.get("completed", [])
	var stars: Array = data.get("stars_collected", [])
	var deaths := int(data.get("deaths", 0))
	var best_times: Dictionary = data.get("best_times", {})
	var out: Array = []
	for a in ACHIEVEMENTS:
		var ach_id := str(a["id"])
		if unlocked.has(ach_id):
			continue
		var met := false
		match ach_id:
			"first_steps":
				met = completed.size() >= 1
			"first_door":
				met = _any_door_done(completed, level_ids)
			"first_star":
				met = stars.size() >= 1
			"star_50":
				met = stars.size() >= 50
			"star_door":
				met = _any_door_stars(stars, level_ids)
			"deaths_100":
				met = deaths >= 100
			"deaths_500":
				met = deaths >= 500
			"speedster":
				for v in best_times.values():
					if float(v) < 10.0 and float(v) > 0.0:
						met = true
						break
			"ghost_racer":
				met = int(data.get("best_improved_count", 0)) >= 1
			"all_215":
				met = completed.size() >= TOTAL_LEVELS
			"nightmare_cleared":
				met = bool(data.get("nightmare_cleared", false))
			"daily_streak":
				met = daily_streak(data, today_override) >= DAILY_STREAK_TARGET
		if met:
			out.append(ach_id)
	return out


static func _any_door_done(completed: Array, level_ids: Array) -> bool:
	if level_ids.is_empty():
		return false
	for door in range(1, TTDoorMap.door_count() + 1):
		var all_done := true
		for idx in TTDoorMap.door_levels(door):
			if idx < 0 or idx >= level_ids.size():
				all_done = false
				break
			if not completed.has(str(level_ids[idx])):
				all_done = false
				break
		if all_done:
			return true
	return false


# All stars in a door: every stage ID of that door is in
# stars_collected. Door 44 has a single stage, so one star there
# counts — that is the honest reading of "every star in one door".
static func _any_door_stars(stars: Array, level_ids: Array) -> bool:
	if level_ids.is_empty() or stars.is_empty():
		return false
	for door in range(1, TTDoorMap.door_count() + 1):
		var all_star := true
		for idx in TTDoorMap.door_levels(door):
			if idx < 0 or idx >= level_ids.size():
				all_star = false
				break
			if not stars.has(str(level_ids[idx])):
				all_star = false
				break
		if all_star:
			return true
	return false


# Consecutive daily-challenge days ending today (if today is not
# completed yet, the streak is counted back from yesterday, so a
# player who finished yesterday is not zeroed at midnight).
static func daily_streak(data: Dictionary, today_override: String = "") -> int:
	var daily: Dictionary = data.get("daily_best", {})
	if daily.is_empty():
		return 0
	var today := today_override
	if today == "":
		today = Time.get_date_string_from_system()
	var base_unix := Time.get_unix_time_from_datetime_dict(_date_dict(today))
	if base_unix < 0:
		return 0
	var streak := 0
	# Day 0 = today; if today is not completed, day 0 is skipped and
	# the count starts at yesterday (a single one-day grace).
	var start_offset := 0
	if not _day_completed(daily, base_unix, 0):
		start_offset = 1
	for off in range(start_offset, start_offset + 366):
		if _day_completed(daily, base_unix, off):
			streak += 1
		else:
			break
	return streak


static func _day_completed(daily: Dictionary, base_unix: int, days_back: int) -> bool:
	var key := Time.get_date_string_from_unix_time(base_unix - days_back * 86400)
	var rec: Dictionary = daily.get(key, {})
	return bool(rec.get("completed", false))


static func _date_dict(date_str: String) -> Dictionary:
	var parts := date_str.split("-")
	if parts.size() != 3:
		return {}
	return {"year": int(parts[0]), "month": int(parts[1]), "day": int(parts[2]),
		"hour": 12, "minute": 0, "second": 0}


# --- Stats helpers: every number comes from the save, never a literal.

static func completion_pct(data: Dictionary) -> int:
	var done: Array = data.get("completed", [])
	if TOTAL_LEVELS <= 0:
		return 0
	return int(round(float(done.size()) / float(TOTAL_LEVELS) * 100.0))


static func best_total(data: Dictionary) -> float:
	var total := 0.0
	var best_times: Dictionary = data.get("best_times", {})
	for v in best_times.values():
		total += float(v)
	return total


static func fastest_level(data: Dictionary) -> Dictionary:
	var best_times: Dictionary = data.get("best_times", {})
	var best_id := ""
	var best_t := -1.0
	for k in best_times.keys():
		var t := float(best_times[k])
		if t > 0.0 and (best_t < 0.0 or t < best_t):
			best_t = t
			best_id = str(k)
	if best_id == "":
		return {}
	return {"id": best_id, "time": best_t}


static func format_time(seconds: float) -> String:
	if seconds <= 0.0:
		return "0:00"
	var total := int(seconds)
	var mins := total / 60
	var secs := total % 60
	return str(mins) + ":" + ("%02d" % secs)


static func stats_rows(data: Dictionary, ghost_count: int) -> Array:
	# Each row: {"label": String, "value": String}. All values are
	# read from the save; empty states show 0 / "-" honestly.
	var completed: Array = data.get("completed", [])
	var stars: Array = data.get("stars_collected", [])
	var best_times: Dictionary = data.get("best_times", {})
	var fast := fastest_level(data)
	var fast_val := "-"
	if not fast.is_empty():
		fast_val = str(fast["id"]) + " " + format_time(float(fast["time"]))
	return [
		{"label": "LEVELS DONE", "value": str(completed.size()) + "/215"},
		{"label": "COMPLETION", "value": str(completion_pct(data)) + "%"},
		{"label": "STARS", "value": str(stars.size()) + "/215"},
		{"label": "DEATHS", "value": str(int(data.get("deaths", 0)))},
		{"label": "TIME PLAYED", "value": format_time(float(data.get("total_time", 0.0)))},
		{"label": "BEST TOTAL", "value": format_time(best_total(data))},
		{"label": "FASTEST LEVEL", "value": fast_val},
		{"label": "LEVELS WITH BEST", "value": str(best_times.size()) + "/215"},
		{"label": "DAILY STREAK", "value": str(daily_streak(data)) + " DAYS"},
		{"label": "GHOSTS SAVED", "value": str(ghost_count)},
	]
