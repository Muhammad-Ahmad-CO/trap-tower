class_name TTProgress
extends RefCounted

# Save: ConfigFile user://progress.cfg, save_version 2.
# Keys use stable level IDs, never array indices. highest_unlocked is monotonic.
# Version 2: the Run 2 redesign replaced every level ID/geometry, so a
# version mismatch returns fresh progress (the old file is left alone
# until the next save — downgrade-resurrection is documented, not fixed).

const PATH := "user://progress.cfg"
const SAVE_VERSION := 2

static func load_progress() -> Dictionary:
	var data := {"save_version": SAVE_VERSION, "highest_unlocked": 0, "completed": []}
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
	return data

static func complete_level(level_id: String, level_index: int, total: int) -> void:
	if total <= 0:
		return
	var data := load_progress()
	var done: Array = data["completed"]
	if not done.has(level_id):
		done.append(level_id)
	data["highest_unlocked"] = maxi(int(data["highest_unlocked"]), mini(level_index + 1, total - 1))
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", SAVE_VERSION)
	cfg.set_value("progress", "highest_unlocked", int(data["highest_unlocked"]))
	cfg.set_value("progress", "completed", done)
	cfg.save(PATH)

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
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", SAVE_VERSION)
	cfg.set_value("progress", "highest_unlocked", next)
	cfg.set_value("progress", "completed", data["completed"])
	cfg.save(PATH)
