class_name TTSkins
extends RefCounted

# Hero skins (Lane F1, v1.0.5 Part B). VISUAL ONLY: a skin changes the
# hero's drawn colours/shape, never the collision rect (15x39), speed
# or jump — the static checker and autopilot are unaffected by design.
# The DEFAULT hero is unchanged (pure black, classic shape).
#
# Unlock rules (earned, never bought — there is no shop, no ads):
#   EMBER  — complete 5 doors        FROST — complete 15 doors
#   MINT   — collect 25 stars        GOLD  — collect 75 stars
#   GHOST  — complete all 44 doors
# Bonus door (the 45th, bonus-only) unlocks at 50 stars of 215:
# early enough to reward real star-hunting (about a quarter of the
# stars, reachable around door 10-12 for a hunter), late enough that
# it is earned, not given — and it never gates the main 44 doors.

const BONUS_DOOR_STARS := 50

const SKINS := [
	{"id": "default", "name": "SHADOW", "body": "#000000", "accent": "#FFFFFF",
		"shape": "classic", "doors": 0, "stars": 0, "rule": "OWNED"},
	{"id": "ember", "name": "EMBER", "body": "#E2483D", "accent": "#FFD23F",
		"shape": "stripe", "doors": 5, "stars": 0, "rule": "5 DOORS"},
	{"id": "frost", "name": "FROST", "body": "#7DD3F0", "accent": "#FFFFFF",
		"shape": "cap", "doors": 15, "stars": 0, "rule": "15 DOORS"},
	{"id": "mint", "name": "MINT", "body": "#2FBF71", "accent": "#FFFFFF",
		"shape": "horns", "doors": 0, "stars": 25, "rule": "25 STARS"},
	{"id": "gold", "name": "GOLD", "body": "#FFD23F", "accent": "#B45309",
		"shape": "stripe", "doors": 0, "stars": 75, "rule": "75 STARS"},
	{"id": "ghost", "name": "GHOST", "body": "#F2F2F2", "accent": "#1A1A2E",
		"shape": "cap", "doors": 44, "stars": 0, "rule": "ALL DOORS"},
]


static func skin_by_id(skin_id: String) -> Dictionary:
	for s in SKINS:
		if str(s["id"]) == skin_id:
			return s
	return SKINS[0]


static func doors_completed(completed: Array, levels: Array) -> int:
	var done := 0
	for door in range(1, TTDoorMap.door_count() + 1):
		var all_done := true
		for idx in TTDoorMap.door_levels(door):
			if idx < 0 or idx >= levels.size():
				all_done = false
				break
			if not completed.has(str(levels[idx].get("id", ""))):
				all_done = false
				break
		if all_done:
			done += 1
	return done


static func is_unlocked(skin: Dictionary, doors_done: int, stars_count: int) -> bool:
	return doors_done >= int(skin.get("doors", 0)) and stars_count >= int(skin.get("stars", 0))


static func bonus_unlocked(stars_count: int) -> bool:
	return stars_count >= BONUS_DOOR_STARS
