class_name TTDaily
extends RefCounted

# Lane F2 (v1.0.5 Part B): the daily challenge. One NEW level per
# day, SEEDED BY THE DATE: the same date always produces the same
# level (same level for everyone that day), a different date produces
# a different level. The game cannot run the Python generator, so
# generation happens here, in GDScript, in the SAME level-dict format
# as levels.json (schema v3, LEVEL_SCHEMA.md). The layout is the
# game's own design language, kept deliberately conservative so the
# static checker + autopilot pass every day:
#   flat floor (top y=640) with ONE falling segment (shaft-flanked,
#   like shipped L001), a stepped hill up and down (rise 40/step,
#   jump rise is ~57, so every step is climbable), and a static
#   up-spike strip on the wide hill plateau (shipped L001 does the
#   same on a step top), plus an optional second strip on the flat
#   right floor when it fits >= 96px past the floor start.
# Seeded per day: hill height (4-5 steps), plateau width, falling
# segment position/width/stand_time, approach width (shifts the whole
# hill), spike widths/positions, palette. No saws, no pillars, no
# dashed/moving platforms in the daily level: spikes + falling floor
# + hill is the daily mix, and every sampled date is verified
# passable by the harness (see verification/f2/).
#
# Save contract (TTProgress): daily_best[YYYY-MM-DD] =
# {"completed": bool, "best_time": float}. A daily win never touches
# completed / best_times / ghosts: the daily level has no place in
# the 215-level tower.

const FLOOR_TOP := 640.0
const FLOOR_Y := 720.0
const WIDTH := 1280.0
const MAX_SPIKE_W := 50.0
const DOOR_SAFE_X := 1132.0


# --- date helpers ----------------------------------------------------

static func today_string() -> String:
	return Time.get_date_string_from_system()


static func seed_for_date(date_str: String) -> int:
	var parts := date_str.split("-")
	if parts.size() != 3:
		return 0
	return int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2])


static func date_valid(date_str: String) -> bool:
	var parts := date_str.split("-")
	if parts.size() != 3:
		return false
	var y := int(parts[0])
	var m := int(parts[1])
	var d := int(parts[2])
	return y >= 2026 and m >= 1 and m <= 12 and d >= 1 and d <= 31


# --- deterministic PRNG (xorshift32, seeded per date) -----------------

var _s := 1


func _next_u32() -> int:
	_s ^= (_s << 13) & 0xFFFFFFFF
	_s ^= (_s >> 17) & 0xFFFFFFFF
	_s ^= (_s << 5) & 0xFFFFFFFF
	_s &= 0xFFFFFFFF
	if _s == 0:
		_s = 0x9E3779B9
	return _s


func _int(n: int) -> int:
	if n <= 1:
		return 0
	return int(_next_u32() % n)


# --- generation ------------------------------------------------------

static func generate_for_date(date_str: String) -> Dictionary:
	var gen := TTDaily.new()
	return gen._generate(date_str)


func _generate(date_str: String) -> Dictionary:
	var date := date_str
	if not date_valid(date):
		date = today_string()
	var seed := seed_for_date(date)
	_s = (seed ^ 0x9E3779B9) & 0xFFFFFFFF
	if _s == 0:
		_s = 0x9E3779B9
	# Hill: N steps up (rise 40 each) to a plateau, N steps down.
	# N=4 -> peak top 480 (core band needs rects with top < 510:
	# the 480 steps + plateau satisfy it); N=5 -> peak top 440.
	var n_steps := 4 + _int(2)
	# Step width is seeded per date (72/80/88 for N=4, 56/64/72 for
	# N=5): it changes the jump distances, so the solution signature
	# differs between dates that otherwise share the same hill.
	var step_w := (72.0 if n_steps == 4 else 56.0) + 8.0 * float(_int(3))
	var peak_top := FLOOR_TOP - 40.0 * float(n_steps)
	# Wide plateau (144..192): it carries the daily spike strip, and
	# the strip needs >= 32px of run-up and landing on both sides.
	var plateau_w := 144.0 + 16.0 * float(_int(4))
	# Falling segment in the left floor: position 150/166, width
	# 80/96, stand_time 0.8..1.2s. The slab after it is 48..176 wide
	# (the seeded approach width shifts the whole hill right, so
	# different dates differ in layout, not just in traps).
	var fall_x := 150.0 + 16.0 * float(_int(2))
	var fall_w := 80.0 + 16.0 * float(_int(2))
	var stand_time := 0.8 + 0.1 * float(_int(5))
	var mid_w := 48.0 + 16.0 * float(_int(3)) + 32.0 * float(_int(4)) + 64.0 * float(_int(3))
	var hill_x0 := fall_x + fall_w + mid_w
	var hill_w := 2.0 * float(n_steps) * step_w + plateau_w
	var hill_x1 := hill_x0 + hill_w
	# The right floor must stay >= 80 wide (the door stands on it):
	# if the seeded hill runs too far right, pull the hill back by
	# cutting the approach slab first, then the plateau (never below
	# 48 / 144). Still fully determined by the date.
	var overflow := hill_x1 - (WIDTH - 80.0)
	if overflow > 0.0:
		var cut := minf(overflow, mid_w - 48.0)
		mid_w -= cut
		overflow -= cut
	if overflow > 0.0:
		var cut2 := minf(overflow, plateau_w - 144.0)
		plateau_w -= cut2
		overflow -= cut2
	hill_x0 = fall_x + fall_w + mid_w
	hill_w = 2.0 * float(n_steps) * step_w + plateau_w
	hill_x1 = hill_x0 + hill_w
	# Right floor runs from the hill to the right edge; the door
	# stands on it at x=1190.
	var plats: Array = []
	plats.append({"x": 0.0, "y": FLOOR_TOP, "w": fall_x, "h": 80.0, "kind": "solid"})
	plats.append({"x": fall_x, "y": FLOOR_TOP, "w": fall_w, "h": 20.0,
		"kind": "falling", "stand_time": stand_time})
	plats.append({"x": fall_x + fall_w, "y": FLOOR_TOP, "w": mid_w, "h": 80.0, "kind": "solid"})
	for i in range(n_steps):
		var top := FLOOR_TOP - 40.0 * float(i + 1)
		plats.append({"x": hill_x0 + float(i) * step_w, "y": top,
			"w": step_w, "h": FLOOR_Y - top, "kind": "solid"})
	var plateau_x := hill_x0 + float(n_steps) * step_w
	plats.append({"x": plateau_x, "y": peak_top,
		"w": plateau_w, "h": FLOOR_Y - peak_top, "kind": "solid"})
	for j in range(n_steps):
		var top2 := peak_top + 40.0 * float(j + 1)
		plats.append({"x": plateau_x + plateau_w + float(j) * step_w,
			"y": top2, "w": step_w, "h": FLOOR_Y - top2, "kind": "solid"})
	plats.append({"x": hill_x1, "y": FLOOR_TOP, "w": WIDTH - hill_x1, "h": 80.0, "kind": "solid"})
	# Spikes. The GUARANTEED strip sits on the plateau top (shipped
	# L001 does exactly this: a spike strip on a step top): w 30/40,
	# >= 48px of flat plateau on both sides, so the hero can run in,
	# jump it, and land. A SECOND strip goes on the flat right floor
	# ONLY when it fits >= 96px past the floor start (a strip right
	# at the floor edge breaks the graph edge onto the floor — the
	# hero would have to jump it with no run-up) and ends before
	# x=1132 (the door safe zone). The two strips sit on different
	# platforms, so they are never a chained pair.
	var hazards: Array = []
	var pw_spike_w := 30.0 + 10.0 * float(_int(2))
	# Offset in 8px steps inside [48, plateau_w - w - 48]: the
	# landing zone (first 48px of the plateau, where the hero
	# arrives from the last up-step) must be hazard-free, and the
	# hero needs >= 48px after the strip to land before the edge.
	var off_slots := int((plateau_w - pw_spike_w - 96.0) / 8.0) + 1
	var pw_off := 48.0 + 8.0 * float(_int(maxi(1, off_slots)))
	hazards.append({"type": "spikes", "dir": "up", "x": plateau_x + pw_off,
		"y": peak_top - 10.0, "w": pw_spike_w, "h": 10.0})
	if hill_x1 + 96.0 + 30.0 <= DOOR_SAFE_X and _int(2) == 0:
		var rw := 30.0 + 10.0 * float(_int(2))
		var rx := hill_x1 + 96.0 + 16.0 * float(_int(2))
		if rx + rw <= DOOR_SAFE_X:
			hazards.append({"type": "spikes", "dir": "up", "x": rx,
				"y": FLOOR_TOP - 10.0, "w": rw, "h": 10.0})
	return {
		"id": "DAILY-" + date,
		"palette": seed % 44,
		"template": "daily-challenge",
		"variation": "DAILY-" + date,
		"spawn": {"x": 70.0, "y": FLOOR_TOP},
		"door": {"x": 1190.0, "y": FLOOR_TOP},
		"platforms": plats,
		"hazards": hazards,
	}


# --- save: record a daily win ----------------------------------------
# Keeps the best time for that date; never touches completed /
# best_times / ghosts. Runs the achievement check so a 3-day daily
# streak unlocks DAILY GRIND. Returns newly unlocked achievement IDs.

static func record_win(date_str: String, attempt_time: float) -> Array:
	var data := TTProgress.load_progress()
	var daily: Dictionary = data.get("daily_best", {})
	var rec: Dictionary = daily.get(date_str, {})
	var prev := float(rec.get("best_time", -1.0))
	if attempt_time > 0.0 and (prev < 0.0 or attempt_time < prev):
		rec["best_time"] = attempt_time
	rec["completed"] = true
	daily[date_str] = rec
	TTProgress.save_features_patch({"daily_best": daily})
	return TTProgress.check_achievements([], date_str)


static func best_for(date_str: String, data: Dictionary) -> Dictionary:
	var daily: Dictionary = data.get("daily_best", {})
	return daily.get(date_str, {})
