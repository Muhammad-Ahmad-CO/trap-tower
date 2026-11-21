class_name TTProgress
extends RefCounted

# Save: ConfigFile user://progress.cfg, save_version 3.
# Keys use stable level IDs, never array indices. highest_unlocked is monotonic.
# Version 2: the Run 2 redesign replaced every level ID/geometry, so a
# version mismatch returns fresh progress (the old file is left alone
# until the next save — downgrade-resurrection is documented, not fixed).
# Version 3: the Run 3 flatten + regeneration replaced every level
# ID/geometry again, so v2 saves are ignored (fresh progress), never
# migrated. Same rule as v2, new version number only.
#
# SHARED SAVE-FIELD CONTRACT (v1.0.5 Part B, see TTFeatures header):
# every lane's fields live in this ONE file, all with defaults, so a
# v1.0.4 save (old fields only) loads cleanly and no lane's save path
# wipes another lane's data. Every save path below writes ALL fields.
#   F1 stars/skins/bonus: stars_collected [], selected_skin "default",
#     bonus_completed [], bonus_highest 0 (bonus door locked).
#   F3 achievements/stats/ghost: deaths 0, total_time 0.0,
#     best_times {}, achievements_unlocked [], best_improved_count 0,
#     ghost_visible true; ghosts live in a SEPARATE user://ghosts.cfg.
#   Daily / nightmare lanes: daily_best {}, nightmare_cleared false.
# A v1.0.4 save file on disk keeps working: load_progress() fills
# every new field from its default.

const PATH := "user://progress.cfg"
const GHOST_PATH := "user://ghosts.cfg"
const SAVE_VERSION := 3
# Lane F3 ghost bounds: at most 12 levels, 600 samples each (10 Hz,
# 60 s). The game recorder already caps at 600; save_ghost enforces
# it too, so a direct caller can never bloat ghosts.cfg.
const MAX_GHOST_LEVELS := 12


static func load_progress() -> Dictionary:
	var data := {"save_version": SAVE_VERSION, "highest_unlocked": 0, "completed": [],
		"stars_collected": [], "skins_owned": [], "selected_skin": "default",
		"bonus_completed": [], "bonus_highest": 0,
		"deaths": 0, "total_time": 0.0, "best_times": {},
		"achievements_unlocked": [], "best_improved_count": 0,
		"ghost_visible": true, "daily_best": {}, "nightmare_unlocked": false,
		"nightmare_cleared": false}
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return data
	if int(cfg.get_value("progress", "save_version", SAVE_VERSION)) != SAVE_VERSION:
		return data
	data["highest_unlocked"] = maxi(0, int(cfg.get_value("progress", "highest_unlocked", 0)))
	var done: Array = []
	for id in cfg.get_value("progress", "completed", []):
		done.append(str(id))
	data["completed"] = done
	var stars: Array = []
	for id in cfg.get_value("progress", "stars_collected", []):
		stars.append(str(id))
	data["stars_collected"] = stars
	data["selected_skin"] = str(cfg.get_value("progress", "selected_skin", "default"))
	var skins: Array = []
	for id in cfg.get_value("progress", "skins_owned", []):
		skins.append(str(id))
	data["skins_owned"] = skins
	var bonus_done: Array = []
	for id in cfg.get_value("progress", "bonus_completed", []):
		bonus_done.append(str(id))
	data["bonus_completed"] = bonus_done
	data["bonus_highest"] = maxi(0, int(cfg.get_value("progress", "bonus_highest", 0)))
	data["deaths"] = maxi(0, int(cfg.get_value("progress", "deaths", 0)))
	data["total_time"] = maxf(0.0, float(cfg.get_value("progress", "total_time", 0.0)))
	var best: Dictionary = {}
	for k in (cfg.get_value("progress", "best_times", {}) as Dictionary).keys():
		best[str(k)] = float((cfg.get_value("progress", "best_times", {}) as Dictionary)[k])
	data["best_times"] = best
	var ach: Array = []
	for id in cfg.get_value("progress", "achievements_unlocked", []):
		ach.append(str(id))
	data["achievements_unlocked"] = ach
	data["best_improved_count"] = maxi(0, int(cfg.get_value("progress", "best_improved_count", 0)))
	data["ghost_visible"] = bool(cfg.get_value("progress", "ghost_visible", true))
	var daily: Dictionary = {}
	for k in (cfg.get_value("progress", "daily_best", {}) as Dictionary).keys():
		daily[str(k)] = (cfg.get_value("progress", "daily_best", {}) as Dictionary)[k]
	data["daily_best"] = daily
	data["nightmare_unlocked"] = bool(cfg.get_value("progress", "nightmare_unlocked", false))
	data["nightmare_cleared"] = bool(cfg.get_value("progress", "nightmare_cleared", false))
	return data


static func _save(data: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", SAVE_VERSION)
	cfg.set_value("progress", "highest_unlocked", int(data["highest_unlocked"]))
	cfg.set_value("progress", "completed", data["completed"])
	cfg.set_value("progress", "stars_collected", data["stars_collected"])
	cfg.set_value("progress", "skins_owned", data.get("skins_owned", []))
	cfg.set_value("progress", "selected_skin", str(data["selected_skin"]))
	cfg.set_value("progress", "bonus_completed", data["bonus_completed"])
	cfg.set_value("progress", "bonus_highest", int(data["bonus_highest"]))
	cfg.set_value("progress", "deaths", int(data["deaths"]))
	cfg.set_value("progress", "total_time", float(data["total_time"]))
	cfg.set_value("progress", "best_times", data["best_times"])
	cfg.set_value("progress", "achievements_unlocked", data["achievements_unlocked"])
	cfg.set_value("progress", "best_improved_count", int(data["best_improved_count"]))
	cfg.set_value("progress", "ghost_visible", bool(data["ghost_visible"]))
	cfg.set_value("progress", "daily_best", data["daily_best"])
	cfg.set_value("progress", "nightmare_unlocked", bool(data.get("nightmare_unlocked", false)))
	cfg.set_value("progress", "nightmare_cleared", bool(data["nightmare_cleared"]))
	cfg.save(PATH)


static func complete_level(level_id: String, level_index: int, total: int) -> void:
	if total <= 0:
		return
	var data := load_progress()
	var done: Array = data["completed"]
	if not done.has(level_id):
		done.append(level_id)
	data["highest_unlocked"] = maxi(int(data["highest_unlocked"]), mini(level_index + 1, total - 1))
	_save(data)


# Skip: advance highest_unlocked monotonically (same cap as
# complete_level) WITHOUT appending to `completed`. No-op on the last
# stage, and no-op when the next stage is already unlocked.
static func unlock_level(level_index: int, total: int) -> void:
	if total <= 0:
		return
	if level_index >= total - 1:
		return
	var data := load_progress()
	var next := mini(level_index + 1, total - 1)
	if next <= int(data["highest_unlocked"]):
		return
	data["highest_unlocked"] = next
	_save(data)


# --- Lane F1: stars, skins, bonus door -------------------------------

static func collect_star(level_id: String) -> void:
	var data := load_progress()
	var stars: Array = data["stars_collected"]
	if stars.has(level_id):
		return
	stars.append(level_id)
	_save(data)


static func set_skin(skin_id: String) -> void:
	var data := load_progress()
	data["selected_skin"] = TTSkins.skin_by_id(skin_id)["id"]
	_save(data)


static func complete_bonus_level(level_id: String, level_index: int, total: int) -> void:
	if total <= 0:
		return
	var data := load_progress()
	var done: Array = data["bonus_completed"]
	if not done.has(level_id):
		done.append(level_id)
	data["bonus_highest"] = maxi(int(data["bonus_highest"]), mini(level_index + 1, total - 1))
	_save(data)


static func unlock_bonus_level(level_index: int, total: int) -> void:
	if total <= 0:
		return
	if level_index >= total - 1:
		return
	var data := load_progress()
	var next := mini(level_index + 1, total - 1)
	if next <= int(data["bonus_highest"]):
		return
	data["bonus_highest"] = next
	_save(data)


# --- Lane F3: deaths, play time, best times, ghosts, achievements ---

# Append every newly-met achievement to the save. Shared by
# record_death / record_level_win / check_achievements so all three
# unlock through the same path. level_ids [] skips the door checks.
static func _unlock_new(data: Dictionary, level_ids: Array, today_override: String = "") -> Array:
	var newly := TTFeatures.evaluate(data, level_ids, today_override)
	if newly.is_empty():
		return newly
	var unlocked: Array = data["achievements_unlocked"]
	for a in newly:
		if not unlocked.has(a):
			unlocked.append(a)
	data["achievements_unlocked"] = unlocked
	return newly


# Re-evaluate every achievement against the current save and persist
# any newly met ones. Other lanes call this after they change stars,
# daily_best or nightmare_cleared. Returns newly unlocked IDs.
static func check_achievements(level_ids: Array = [], today_override: String = "") -> Array:
	var data := load_progress()
	var newly := _unlock_new(data, level_ids, today_override)
	_save(data)
	return newly


# Merge the given feature keys into the save (other lanes / tests
# use this to set stars, daily_best or nightmare_cleared without
# touching progress). Unknown keys are ignored.
static func save_features_patch(patch: Dictionary) -> void:
	var data := load_progress()
	var allowed: Array = ["stars_collected", "skins_owned", "selected_skin",
		"bonus_completed", "bonus_highest", "daily_best", "nightmare_unlocked",
		"nightmare_cleared", "deaths", "total_time", "best_times",
		"achievements_unlocked", "best_improved_count", "ghost_visible"]
	for k in patch.keys():
		if allowed.has(str(k)):
			data[str(k)] = patch[k]
	_save(data)


# One death. Returns the achievement IDs unlocked by this death
# (deaths_100 at 100, deaths_500 at 500; usually []).
static func record_death() -> Array:
	var data := load_progress()
	data["deaths"] = int(data["deaths"]) + 1
	var newly := _unlock_new(data, [])
	_save(data)
	return newly


static func add_play_time(seconds: float) -> void:
	if seconds <= 0.0:
		return
	var data := load_progress()
	data["total_time"] = float(data["total_time"]) + seconds
	_save(data)


static func set_ghost_visible(v: bool) -> void:
	var data := load_progress()
	data["ghost_visible"] = v
	_save(data)


# Best time + ghost (only the fastest run is kept) + achievement
# check. Called AFTER complete_level so door achievements see the
# win. First completion saves the ghost (fastest so far); a later
# faster run overwrites it and counts as beating a previous best.
static func record_level_win(level_id: String, attempt_time: float, ghost_rec: Array, level_ids: Array) -> void:
	var data := load_progress()
	var best_times: Dictionary = data["best_times"]
	var prev := float(best_times.get(level_id, -1.0))
	var is_first := prev < 0.0
	var improved := false
	if attempt_time > 0.0:
		if is_first:
			best_times[level_id] = attempt_time
		elif attempt_time < prev:
			best_times[level_id] = attempt_time
			data["best_improved_count"] = int(data["best_improved_count"]) + 1
			improved = true
	data["best_times"] = best_times
	if is_first or improved:
		save_ghost(level_id, ghost_rec)
	_unlock_new(data, level_ids)
	_save(data)


# Ghosts live in a separate file so the (large) sample arrays never
# bloat progress.cfg. Samples are Vector3(x, y, facing), recorded at
# 10 Hz by game.gd; stored as plain [x, y, z] triples (ConfigFile
# round-trips plain arrays most reliably). ghosts_meta holds a
# whole-second save timestamp per level; ghosts_seq holds a monotonic
# save-order counter per level and is the SOLE prune order (Lane 3b:
# timestamps are coarse and the clock is non-monotonic, so they
# cannot order saves at all).
static func load_ghost(level_id: String) -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(GHOST_PATH) != OK:
		return []
	var out: Array = []
	for s in cfg.get_value("ghosts", level_id, []):
		if s is Vector3:
			out.append(s)
		elif s is Array and (s as Array).size() >= 3:
			out.append(Vector3(float(s[0]), float(s[1]), float(s[2])))
	return out


static func save_ghost(level_id: String, samples: Array) -> void:
	var cfg := ConfigFile.new()
	cfg.load(GHOST_PATH)
	var plain: Array = []
	var n := mini(samples.size(), TTGhost.MAX_SAMPLES)
	for i in range(n):
		var s: Variant = samples[i]
		if s is Vector3:
			plain.append([int(round(s.x)), int(round(s.y)), 1 if s.z >= 0.0 else -1])
		elif s is Array and (s as Array).size() >= 3:
			plain.append([int(round(float(s[0]))), int(round(float(s[1]))), 1 if float(s[2]) >= 0.0 else -1])
	cfg.set_value("ghosts", level_id, plain)
	cfg.set_value("ghosts_meta", level_id, Time.get_unix_time_from_system())
	# Monotonic save-order sequence (Lane 3b fix): ghosts_meta
	# timestamps are whole seconds AND the clock is not monotonic
	# (observed in-sandbox: a just-saved ghost stamped 1795148936
	# while older entries held 1795150000), so timestamps cannot
	# order saves at all — the old time-only sort kept the OLDEST
	# 12 ghosts and erased the newest one. Every save gets a
	# strictly increasing seq in ghosts_seq, and the prune sorts on
	# seq ALONE: the 12 most recently SAVED ghosts survive, whatever
	# the clock does. Legacy files have no ghosts_seq section: their
	# entries get seqs in stored key order (never wiped, never
	# reordered), then saving continues as normal. A re-save of an
	# existing ghost bumps it to the newest seq.
	var seqs: Dictionary = {}
	var max_seq := 0
	if cfg.has_section("ghosts_seq"):
		for k in cfg.get_section_keys("ghosts_seq"):
			seqs[str(k)] = int(cfg.get_value("ghosts_seq", k, 0))
			max_seq = maxi(max_seq, int(seqs[str(k)]))
	var is_resave := seqs.has(level_id)
	if cfg.has_section("ghosts"):
		for k in cfg.get_section_keys("ghosts"):
			if not seqs.has(str(k)):
				max_seq += 1
				seqs[str(k)] = max_seq
	if is_resave:
		max_seq += 1
		seqs[level_id] = max_seq
	for k in seqs.keys():
		cfg.set_value("ghosts_seq", str(k), int(seqs[k]))
	if cfg.has_section("ghosts"):
		var keys: Array = []
		for k in cfg.get_section_keys("ghosts"):
			keys.append(str(k))
		if keys.size() > MAX_GHOST_LEVELS:
			keys.sort_custom(func(a, b): return int(seqs[a]) < int(seqs[b]))
			for k in keys.slice(0, keys.size() - MAX_GHOST_LEVELS):
				cfg.erase_section_key("ghosts", k)
				cfg.erase_section_key("ghosts_meta", k)
				cfg.erase_section_key("ghosts_seq", k)
	cfg.save(GHOST_PATH)


static func ghost_count() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(GHOST_PATH) != OK:
		return 0
	var count := 0
	if cfg.has_section("ghosts"):
		for k in cfg.get_section_keys("ghosts"):
			if not (cfg.get_value("ghosts", k, []) as Array).is_empty():
				count += 1
	return count
