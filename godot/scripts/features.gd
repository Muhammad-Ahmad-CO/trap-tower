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


# --- Lane U4: chapters (M5) + hidden keys (M2) + chapter-complete (M8) ---
#
# CHAPTER API (the API Lane U5's speedrun/credits/celebration build
# on — see LANE-U4-REPORT.md for the full contract). Chapters derive
# from the FROZEN door table (TTDoorMap — never from level-index
# arithmetic): Ch.1 = doors 1-16 (playlist Ch.1 M1-M16), Ch.2 =
# doors 17-30 (playlist Ch.2 M1-M14), Ch.3 = doors 31-44. Chapter 3
# is a DESIGN label ("CHAPTER 3 - CONTINUATION", hyphen — the pixel
# font has no em dash), NOT an official playlist chapter. Chapter
# completion is always DERIVED from the completed set, never stored.
# Key level ids are the B4-approved spots (15 levels, 5 per chapter);
# keys_collected ids are "L016:0" (level id + key index), so the
# level part is the text before ":".

# id, first/last door (inclusive), final door, UI label, tuning
# palette index for the chapter's map island (M5 per-chapter map
# palette: Ch.1 orange/purple, Ch.2 pink/dark-red, Ch.3 cream/brown).
const CHAPTERS: Array = [
	{"id": 1, "first_door": 1, "last_door": 16, "final_door": 16,
		"label": "CHAPTER 1", "palette": 0},
	{"id": 2, "first_door": 17, "last_door": 30, "final_door": 30,
		"label": "CHAPTER 2", "palette": 16},
	{"id": 3, "first_door": 31, "last_door": 44, "final_door": 44,
		"label": "CHAPTER 3 - CONTINUATION", "palette": 43},
]

# B4-approved key spots: chapter number (as string) -> level ids in
# B4 order (Kx.1 .. Kx.5). The single source of truth for "which
# level holds a chapter key"; the splice (levels.json `keys` array)
# must match this table exactly.
const KEY_LEVEL_IDS: Dictionary = {
	"1": ["L002", "L016", "L022", "L025", "L079"],
	"2": ["L085", "L116", "L096", "L134", "L149"],
	"3": ["L152", "L193", "L171", "L157", "L215"],
}

const TOTAL_KEYS := 15


static func chapter_table() -> Array:
	return CHAPTERS


static func chapter_count() -> int:
	return CHAPTERS.size()


static func chapter_of_door(door: int) -> int:
	for ch in CHAPTERS:
		if door >= int(ch["first_door"]) and door <= int(ch["last_door"]):
			return int(ch["id"])
	return CHAPTERS.size()


static func chapter_of_level_index(idx: int) -> int:
	return chapter_of_door(TTDoorMap.door_of(idx))


# "L016" -> 15 -> door 4 -> chapter 1. Unknown/malformed ids fall
# back to the last chapter (never 0 — every level is in a chapter).
static func chapter_of_level_id(level_id: String) -> int:
	var s := str(level_id).split(":")[0]
	if s.length() != 4 or not s.begins_with("L"):
		return CHAPTERS.size()
	var n := int(s.substr(1, 3))
	if n < 1 or n > TOTAL_LEVELS:
		return CHAPTERS.size()
	return chapter_of_level_index(n - 1)


static func chapter_doors(chapter: int) -> Array:
	var out: Array = []
	for ch in CHAPTERS:
		if int(ch["id"]) == chapter:
			for d in range(int(ch["first_door"]), int(ch["last_door"]) + 1):
				out.append(d)
			return out
	return out


static func chapter_final_door(chapter: int) -> int:
	for ch in CHAPTERS:
		if int(ch["id"]) == chapter:
			return int(ch["final_door"])
	return 0


static func chapter_label(chapter: int) -> String:
	for ch in CHAPTERS:
		if int(ch["id"]) == chapter:
			return str(ch["label"])
	return "CHAPTER " + str(chapter)


static func chapter_palette(chapter: int) -> int:
	for ch in CHAPTERS:
		if int(ch["id"]) == chapter:
			return int(ch["palette"])
	return 0


# Stage ids of a chapter's doors. level_ids is the ordered list of
# all level ids (index -> id); when empty, ids are derived as
# "L%03d" (the game's own id format — game.gd builds pips this way).
static func chapter_level_ids(chapter: int, level_ids: Array = []) -> Array:
	var out: Array = []
	for door in chapter_doors(chapter):
		for idx in TTDoorMap.door_levels(door):
			if not level_ids.is_empty() and idx >= 0 and idx < level_ids.size():
				out.append(str(level_ids[idx]))
			else:
				out.append("L%03d" % (int(idx) + 1))
	return out


static func chapter_levels_total(chapter: int) -> int:
	return chapter_level_ids(chapter).size()


static func chapter_levels_done(data: Dictionary, chapter: int, level_ids: Array = []) -> int:
	var completed: Array = data.get("completed", [])
	var n := 0
	for lid in chapter_level_ids(chapter, level_ids):
		if completed.has(lid):
			n += 1
	return n


# True when EVERY stage id of the chapter is in `completed`.
# Derived only — nothing about chapters is ever stored per chapter.
static func chapter_complete(data: Dictionary, chapter: int, level_ids: Array = []) -> bool:
	var completed: Array = data.get("completed", [])
	var ids := chapter_level_ids(chapter, level_ids)
	if ids.is_empty():
		return false
	for lid in ids:
		if not completed.has(lid):
			return false
	return true


static func chapter_keys_total(chapter: int) -> int:
	return (KEY_LEVEL_IDS.get(str(chapter), []) as Array).size()


# Collected keys in a chapter: keys_collected ids ("L016:0") whose
# level part is one of this chapter's KEY_LEVEL_IDS. Counts each
# level once even if a level ever held two keys.
static func chapter_keys_collected(data: Dictionary, chapter: int) -> int:
	var want: Array = KEY_LEVEL_IDS.get(str(chapter), [])
	if want.is_empty():
		return 0
	var have: Array = data.get("keys_collected", [])
	var seen: Array = []
	for kid in have:
		var lid := str(kid).split(":")[0]
		if want.has(lid) and not seen.has(lid):
			seen.append(lid)
	return seen.size()


static func total_keys_collected(data: Dictionary) -> int:
	var have: Array = data.get("keys_collected", [])
	var seen: Array = []
	for kid in have:
		var lid := str(kid).split(":")[0]
		if not seen.has(lid):
			seen.append(lid)
	return seen.size()


# Deaths recorded while playing a level of this chapter
# (TTProgress.chapter_deaths, B2 option (a): {"1": n, ...}).
static func chapter_deaths(data: Dictionary, chapter: int) -> int:
	var d: Dictionary = data.get("chapter_deaths", {})
	return maxi(0, int(d.get(str(chapter), 0)))


# Fastest single-level best time inside a chapter (best_times only);
# -1.0 when the chapter has no best time yet. A chapter helper for
# the map Best display; the speedrun best itself is Lane U5's
# `speedrun_best` save field, not this.
static func chapter_best_level_time(data: Dictionary, chapter: int, level_ids: Array = []) -> float:
	var best_times: Dictionary = data.get("best_times", {})
	var best := -1.0
	for lid in chapter_level_ids(chapter, level_ids):
		var t := float(best_times.get(lid, -1.0))
		if t > 0.0 and (best < 0.0 or t < best):
			best = t
	return best


# --- Lane U5: speedrun (M4) + celebration trigger (M9) -------------

# Speedrun timer with tenths ("2:05.4"): a speedrun best is a race
# time, so tenths matter where format_time ("2:05") would hide them.
# All glyphs (digits, ":", ".") are in the pixel font.
static func format_time_tenths(seconds: float) -> String:
	if seconds <= 0.0:
		return "0:00.0"
	var total := int(seconds)
	var mins := total / 60
	var secs := total % 60
	var tenths := int(seconds * 10.0) % 10
	return str(mins) + ":" + ("%02d" % secs) + "." + str(tenths)


# Best speedrun time for a chapter, display-ready: "--:--" when no
# run is saved yet (same placeholder as the M3 Best label), else
# the tenths format. Chapter is a plain int; no chapter table here.
static func speedrun_best_label(data: Dictionary, chapter: int) -> String:
	var best: Dictionary = data.get("speedrun_best", {})
	var t := float(best.get(str(chapter), -1.0))
	if t <= 0.0:
		return "--:--"
	return format_time_tenths(t)


# M9 celebration trigger (GATE-AMENDMENT-1 N5, pinned): PRIMARY =
# all 15 chapter keys collected (U4's TOTAL_KEYS); FALLBACK = all 215
# stars collected. Returns "keys", "stars", or "" (nothing achieved
# yet). The caller (map.gd) compares this against the save's
# celebration_seen so each trigger fires once. Reads keys_collected
# defensively (.get, []) so it works before U4's key system lands.
static func celebration_kind(data: Dictionary) -> String:
	var keys: Array = data.get("keys_collected", [])
	if keys.size() >= TOTAL_KEYS:
		return "keys"
	var stars: Array = data.get("stars_collected", [])
	if stars.size() >= TOTAL_LEVELS:
		return "stars"
	return ""
