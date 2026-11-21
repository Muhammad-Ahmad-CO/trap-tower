class_name TTNightmare
extends RefCounted

# Lane F2 (v1.0.5 Part B): Nightmare mode. The same 215 levels, but
# a REAL difficulty step, applied at RUNTIME (levels.json is never
# changed): every level is x-mirrored AND its trap timings are
# tightened. Quantified step (means over all 215 shipped levels;
# every transformed level still passes the static checker, and the
# full 215-level nightmare autopilot passes 215/215 — see
# verification/f2/):
#   x-mirror: 215/215 levels (the whole route is reversed, so the
#     player re-learns every level; the autopilot passes the mirrored
#     set identically to the normal set, i.e. mirroring preserves
#     passability exactly).
#   dashed / moving / saw periods x0.65 (on_time scales with the
#     period, so the off-time stays >= 0.52s): dashed on_time mean
#     1.96s -> 1.28s (-35%), moving periods 3.02s -> 1.96s (-35%),
#     saw periods 3.00s -> 1.95s (-35%).
#   spike pop-up period/on_time x0.8: on_time 1.20s -> 0.96s.
#   falling/tilting stand_time x0.6: mean 1.09s -> 0.65s (-40%).
#   hanging-pillar period x0.8 (hang window mean 1.83s -> 1.21s,
#     -34%) and drop_speed x1.15. (The first 0.65 pillar scale broke
#     L121 for the autopilot even at 8 wait strategies, so pillars
#     are softened to 0.8 — the honest limit found in testing.)
#   trigger delays are NOT scaled: they already sit at/near the
#     0.25s schema minimum.
# All scaled values stay inside the schema minima, so a nightmare
# level is still a valid v3 level (the Python mirror in
# verification/f2/nightmare_transform.py produces byte-equivalent
# values and passes check_levels.py 215/215).
#
# Unlock: ONLY after all 215 levels are complete (the same condition
# as TTFeatures "all_215" / TOWER MASTER: completed.size() >= 215).
# refresh_unlock() sets nightmare_unlocked the first time the
# condition is met; the map calls it on ready and the win path calls
# it after a normal win.
#
# Clearing: "clears Nightmare" = completes all 215 levels in
# nightmare mode. Per-level nightmare progress lives in a SEPARATE
# user://nightmare.cfg (never in best_times/ghosts, so normal-mode
# progress is never corrupted by a nightmare run). When the 215th
# nightmare level is cleared, nightmare_cleared is set in the main
# save (F3's NIGHTMARE SLAYER achievement reads that field).

const PATH := "user://nightmare.cfg"
const WIDTH := 1280.0
const PERIOD_SCALE := 0.65
const POPUP_SCALE := 0.8
const STAND_SCALE := 0.6
const PILLAR_PERIOD_SCALE := 0.8
const DROP_SPEED_SCALE := 1.15


# --- the transform ----------------------------------------------------

static func apply(level: Dictionary) -> Dictionary:
	var lv: Dictionary = (level as Dictionary).duplicate(true)
	# Mirror first: x' = WIDTH - x - w for rects, x' = WIDTH - x
	# for points (spawn/door/saw centres). Moving platforms flip
	# their travel direction; spike dirs swap left/right.
	for p in lv.get("platforms", []):
		var pd: Dictionary = p
		pd["x"] = WIDTH - float(pd.get("x", 0.0)) - float(pd.get("w", 0.0))
		if str(pd.get("kind", "")) == "moving":
			pd["dx"] = -float(pd.get("dx", 0.0))
		if str(pd.get("kind", "")) == "dashed":
			pd["period"] = float(pd.get("period", 0.0)) * PERIOD_SCALE
			pd["on_time"] = float(pd.get("on_time", 0.0)) * PERIOD_SCALE
		elif str(pd.get("kind", "")) == "falling" or str(pd.get("kind", "")) == "tilting":
			pd["stand_time"] = float(pd.get("stand_time", 0.0)) * STAND_SCALE
		elif str(pd.get("kind", "")) == "moving":
			pd["period"] = float(pd.get("period", 0.0)) * PERIOD_SCALE
	for h in lv.get("hazards", []):
		var hd: Dictionary = h
		var htype := str(hd.get("type", ""))
		if htype == "saw":
			hd["x"] = WIDTH - float(hd.get("x", 0.0))
			if hd.has("path"):
				var path: Dictionary = hd["path"]
				path["x2"] = WIDTH - float(path.get("x2", 0.0))
			if hd.has("swing"):
				var sw: Dictionary = hd["swing"]
				sw["pivot_x"] = WIDTH - float(sw.get("pivot_x", 0.0))
		else:
			hd["x"] = WIDTH - float(hd.get("x", 0.0)) - float(hd.get("w", 0.0))
		if htype == "spikes" and str(hd.get("dir", "up")) == "left":
			hd["dir"] = "right"
		elif htype == "spikes" and str(hd.get("dir", "up")) == "right":
			hd["dir"] = "left"
		if hd.has("trigger_x"):
			hd["trigger_x"] = WIDTH - float(hd.get("trigger_x", 0.0))
		if hd.has("drop_trigger_x"):
			hd["drop_trigger_x"] = WIDTH - float(hd.get("drop_trigger_x", 0.0))
		if htype == "spikes" and hd.has("period"):
			hd["period"] = float(hd.get("period", 0.0)) * POPUP_SCALE
			hd["on_time"] = float(hd.get("on_time", 0.0)) * POPUP_SCALE
		elif htype == "saw":
			if hd.has("path"):
				hd["period"] = float(hd.get("period", 0.0)) * PERIOD_SCALE
			if hd.has("swing"):
				var sw2: Dictionary = hd["swing"]
				sw2["period"] = float(sw2.get("period", 0.0)) * PERIOD_SCALE
		elif htype == "hanging_pillar":
			if hd.has("period"):
				hd["period"] = float(hd.get("period", 0.0)) * PILLAR_PERIOD_SCALE
			if hd.has("drop_speed"):
				hd["drop_speed"] = float(hd.get("drop_speed", 0.0)) * DROP_SPEED_SCALE
	var spawn: Dictionary = lv.get("spawn", {})
	spawn["x"] = WIDTH - float(spawn.get("x", 0.0))
	var door: Dictionary = lv.get("door", {})
	door["x"] = WIDTH - float(door.get("x", 0.0))
	return lv


# --- unlock ------------------------------------------------------------

static func all_complete(data: Dictionary) -> bool:
	return (data.get("completed", []) as Array).size() >= TTFeatures.TOTAL_LEVELS


static func is_unlocked(data: Dictionary) -> bool:
	return bool(data.get("nightmare_unlocked", false)) or all_complete(data)


# Persist nightmare_unlocked the first time the condition is met.
# Idempotent; safe to call from the map and the win path.
static func refresh_unlock() -> bool:
	var data := TTProgress.load_progress()
	if bool(data.get("nightmare_unlocked", false)):
		return true
	if not all_complete(data):
		return false
	TTProgress.save_features_patch({"nightmare_unlocked": true})
	return true


# --- per-level nightmare progress (separate file) ----------------------

static func load_completed() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return []
	var out: Array = []
	for id in cfg.get_value("nightmare", "completed", []):
		out.append(str(id))
	return out


static func _save_completed(done: Array) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("nightmare", "completed", done)
	cfg.save(PATH)


# Record one nightmare win. Returns {"count": int, "cleared": bool}.
# When the 215th level is cleared, nightmare_cleared is set in the
# main save and the achievement check runs (NIGHTMARE SLAYER).
static func record_win(level_id: String) -> Dictionary:
	var done := load_completed()
	if not done.has(level_id):
		done.append(level_id)
		_save_completed(done)
	var cleared := done.size() >= TTFeatures.TOTAL_LEVELS
	if cleared:
		var data := TTProgress.load_progress()
		if not bool(data.get("nightmare_cleared", false)):
			TTProgress.save_features_patch({"nightmare_cleared": true})
			TTProgress.check_achievements([])
	return {"count": done.size(), "cleared": cleared}
