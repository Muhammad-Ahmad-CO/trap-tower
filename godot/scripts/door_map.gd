class_name TTDoorMap
extends RefCounted

# Single source of truth for the v1.0.5 door grouping, derived
# programmatically from verification/exceed/assembly-mapping-exceed.json
# (output sha256 350de95b == live levels.json). 44 doors, 215 stages.
# Door 3 has 4 stages (L011-014); door 44 is the single-stage FINAL
# door (L215 final-mega). NEVER derive doors by dividing the level
# index: door 3 breaks that from door 4 on. One template per door, and all
# 44 templates are DISTINCT (zero duplicates) — every door's
# obstacle type differs from every other door's. One palette per
# door: door N uses palette N-1. Slots are variants of one gimmick;
# no difficulty-ramp claim is made anywhere.

# Per door: first level index (0-based), stage count, template, palette.
const DOORS := [
	{"first": 0, "count": 5, "template": "pitfall", "palette": 0},
	{"first": 5, "count": 5, "template": "spike-hops", "palette": 1},
	{"first": 10, "count": 4, "template": "saw-runs", "palette": 2},
	{"first": 14, "count": 5, "template": "popup-spikes", "palette": 3},
	{"first": 19, "count": 5, "template": "triggered-spikes", "palette": 4},
	{"first": 24, "count": 5, "template": "triggered-pillars", "palette": 5},
	{"first": 29, "count": 5, "template": "periodic-pillars", "palette": 6},
	{"first": 34, "count": 5, "template": "swing-saws", "palette": 7},
	{"first": 39, "count": 5, "template": "patrol-saws", "palette": 8},
	{"first": 44, "count": 5, "template": "gap-saws", "palette": 9},
	{"first": 49, "count": 5, "template": "spiked-columns", "palette": 10},
	{"first": 54, "count": 5, "template": "dashed-chains", "palette": 11},
	{"first": 59, "count": 5, "template": "falling-floors", "palette": 12},
	{"first": 64, "count": 5, "template": "tilting-blocks", "palette": 13},
	{"first": 69, "count": 5, "template": "moving-bridges", "palette": 14},
	{"first": 74, "count": 5, "template": "mover-chains", "palette": 15},
	{"first": 79, "count": 5, "template": "ceiling-spikes", "palette": 16},
	{"first": 84, "count": 5, "template": "wall-spikes", "palette": 17},
	{"first": 89, "count": 5, "template": "step-climbs", "palette": 18},
	{"first": 94, "count": 5, "template": "double-gaps", "palette": 19},
	{"first": 99, "count": 5, "template": "pit-bridges", "palette": 20},
	{"first": 104, "count": 5, "template": "gauntlets", "palette": 21},
	{"first": 109, "count": 5, "template": "timed-mixes", "palette": 22},
	{"first": 114, "count": 5, "template": "pillar-alleys", "palette": 23},
	{"first": 119, "count": 5, "template": "pillar-forests", "palette": 24},
	{"first": 124, "count": 5, "template": "grand-mixes", "palette": 25},
	{"first": 129, "count": 5, "template": "mover-lifts", "palette": 26},
	{"first": 134, "count": 5, "template": "tower-descents", "palette": 27},
	{"first": 139, "count": 5, "template": "reversed-runs", "palette": 28},
	{"first": 144, "count": 5, "template": "skyline-city", "palette": 29},
	{"first": 149, "count": 5, "template": "drop-shafts", "palette": 30},
	{"first": 154, "count": 5, "template": "zigzag-descents", "palette": 31},
	{"first": 159, "count": 5, "template": "saw-fields", "palette": 32},
	{"first": 164, "count": 5, "template": "trigger-pits", "palette": 33},
	{"first": 169, "count": 5, "template": "spike-forests", "palette": 34},
	{"first": 174, "count": 5, "template": "ceiling-gauntlets", "palette": 35},
	{"first": 179, "count": 5, "template": "saw-corridors", "palette": 36},
	{"first": 184, "count": 5, "template": "timed-corridors", "palette": 37},
	{"first": 189, "count": 5, "template": "dashed-towers", "palette": 38},
	{"first": 194, "count": 5, "template": "column-forests", "palette": 39},
	{"first": 199, "count": 5, "template": "final-tower-saws", "palette": 40},
	{"first": 204, "count": 5, "template": "final-skyline", "palette": 41},
	{"first": 209, "count": 5, "template": "final-reversed", "palette": 42},
	{"first": 214, "count": 1, "template": "final-mega", "palette": 43},
]

static func door_count() -> int:
	return DOORS.size()

static func door_of(level_index: int) -> int:
	for d in range(DOORS.size()):
		var row: Dictionary = DOORS[d]
		if level_index >= int(row["first"]) and level_index < int(row["first"]) + int(row["count"]):
			return d + 1
	return DOORS.size()

static func door_first_index(door: int) -> int:
	if door < 1 or door > DOORS.size():
		return 0
	return int(DOORS[door - 1]["first"])

static func door_levels(door: int) -> Array:
	var out: Array = []
	if door < 1 or door > DOORS.size():
		return out
	var row: Dictionary = DOORS[door - 1]
	for i in range(int(row["count"])):
		out.append(int(row["first"]) + i)
	return out

static func door_template(door: int) -> String:
	if door < 1 or door > DOORS.size():
		return ""
	return str(DOORS[door - 1]["template"])

static func door_palette(door: int) -> int:
	if door < 1 or door > DOORS.size():
		return 0
	return int(DOORS[door - 1]["palette"])
