extends SceneTree

# Lane F3 probe (v1.0.5 Part B): ghost run + achievements + stats.
# Headless SceneTree script — real game/map scenes, real save files,
# real physics. Asserts:
#   v1.0.4 save compat (progress section only -> all new fields default)
#   every achievement triggers from its condition AND persists
#   ghost: real recording via build_level + input drive, replay
#     follows the recorded path, ghost has no collision bodies,
#     completion frame count identical with ghost on vs off,
#     HUD + pause toggles hide/show the ghost
#   ghost caps: 600 samples/level, 12 levels max
#   achievements + stats screens show REAL numbers from the save
#   TTProgress.complete_level / unlock_level preserve the features
#     section (regression guard for the v1.0.4 save)
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s <abs path>/f3_ghost_achievements_probe.gd
# Prints F3 PASS/FAIL per assertion, exits 0 only if all pass.
# Restores a FRESH save (deletes progress.cfg + ghosts.cfg) at the end.

var _fails: Array[String] = []
var _passes: Array[String] = []
var _levels: Array = []
var _ids: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("F3 PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("F3 FAIL: ", name, (" | " + detail) if detail != "" else "")


func _user_file(name: String) -> String:
	return OS.get_user_data_dir() + "/" + name


func _wipe_saves() -> void:
	DirAccess.remove_absolute(_user_file("progress.cfg"))
	DirAccess.remove_absolute(_user_file("ghosts.cfg"))


func _write_progress(highest: int, completed: Array) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", TTProgress.SAVE_VERSION)
	cfg.set_value("progress", "highest_unlocked", highest)
	cfg.set_value("progress", "completed", completed)
	cfg.save("user://progress.cfg")


func _traverse(node: Node, out: Array) -> void:
	out.append(node)
	for child in node.get_children():
		_traverse(child, out)


func _label_texts(root_node: Node) -> Array:
	var out: Array = []
	var all: Array = []
	_traverse(root_node, all)
	for n in all:
		if n.get("text") != null and str(n.get("text")) != "":
			out.append(str(n.get("text")))
	return out


func _flat_level() -> Dictionary:
	# Flat, hazard-free level (same shape as the smoke-test level):
	# spawn x70, door x1210, one solid floor. The hero runs right
	# and wins in ~4.7 s with no jumps needed.
	return {
		"id": "L001", "palette": 4, "template": "f3-flat", "variation": "plain",
		"spawn": {"x": 70, "y": 500}, "door": {"x": 1210, "y": 500},
		"platforms": [{"x": 0, "y": 500, "w": 1280, "h": 80, "kind": "solid"}],
		"hazards": [],
	}


func _drive_to_win(game_inst: Node, max_frames: int = 900) -> int:
	var player: Node = game_inst.get("player")
	if player == null:
		return -1
	player.set("input_override", 1)
	for f in range(max_frames):
		await physics_frame
		if bool(game_inst.get("level_completed")):
			return f
	return -1


func _run() -> void:
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("F3 ERROR: ", str(loaded["error"]))
		_finish()
		return
	_levels = loaded["levels"]
	for lv in _levels:
		_ids.append(str((lv as Dictionary).get("id", "")))
	_check("load0: 215 levels loaded", _levels.size() == 215, "total=" + str(_levels.size()))
	var tuning := TTuning.load_tuning()

	# --- 1. v1.0.4 save compat --------------------------------------
	_wipe_saves()
	_write_progress(14, _ids.slice(0, 14))
	var d0 := TTProgress.load_progress()
	_check("compat1: v1.0.4 save loads (highest/completed kept)",
		int(d0["highest_unlocked"]) == 14 and (d0["completed"] as Array).size() == 14,
		"highest=" + str(d0["highest_unlocked"]))
	_check("compat2: new fields default on a v1.0.4 save",
		int(d0["deaths"]) == 0 and float(d0["total_time"]) == 0.0
		and (d0["stars_collected"] as Array).is_empty()
		and (d0["achievements_unlocked"] as Array).is_empty()
		and (d0["best_times"] as Dictionary).is_empty()
		and bool(d0["nightmare_cleared"]) == false
		and bool(d0["nightmare_unlocked"]) == false
		and bool(d0["ghost_visible"]) == true
		and str(d0["selected_skin"]) == "default",
		"deaths=" + str(d0["deaths"]) + " stars=" + str((d0["stars_collected"] as Array).size()))
	_check("compat3: no ghost stored for a v1.0.4 save",
		TTProgress.ghost_count() == 0 and TTProgress.load_ghost("L001").is_empty())
	# complete_level must NOT wipe the features section (regression
	# guard: the old code rewrote the file with progress keys only).
	TTProgress.save_features_patch({"deaths": 7})
	TTProgress.complete_level("L015", 14, 215)
	var d0b := TTProgress.load_progress()
	_check("compat4: complete_level preserves features section",
		int(d0b["deaths"]) == 7 and (d0b["completed"] as Array).has("L015"),
		"deaths=" + str(d0b["deaths"]) + " completed=" + str((d0b["completed"] as Array).size()))
	TTProgress.unlock_level(14, 215)
	var d0c := TTProgress.load_progress()
	_check("compat5: unlock_level preserves features section",
		int(d0c["deaths"]) == 7 and int(d0c["highest_unlocked"]) == 15,
		"highest=" + str(d0c["highest_unlocked"]))

	# --- 2. deaths achievement ---------------------------------------
	TTProgress.save_features_patch({"deaths": 99, "achievements_unlocked": []})
	var un1 := TTProgress.record_death()
	var d1 := TTProgress.load_progress()
	_check("ach1: deaths 99 + 1 death unlocks NEVER GIVE UP + persists",
		un1.has("deaths_100") and int(d1["deaths"]) == 100
		and (d1["achievements_unlocked"] as Array).has("deaths_100"),
		"unlocked=" + str(un1))
	var un1b := TTProgress.record_death()
	_check("ach1b: deaths_100 does not re-unlock",
		not un1b.has("deaths_100") and int(TTProgress.load_progress()["deaths"]) == 101)

	# --- 3. door achievements ----------------------------------------
	_wipe_saves()
	_write_progress(4, _ids.slice(0, 5))
	var un2 := TTProgress.check_achievements(_ids)
	_check("ach2: completing door 1 unlocks FIRST STEPS + DOOR OPENER",
		un2.has("first_steps") and un2.has("first_door"),
		"unlocked=" + str(un2))
	var d2 := TTProgress.load_progress()
	_check("ach2b: door achievements persist after reload",
		(d2["achievements_unlocked"] as Array).has("first_steps")
		and (d2["achievements_unlocked"] as Array).has("first_door"))

	# --- 4. star achievements (simulated F1 save data) ---------------
	TTProgress.save_features_patch({"stars_collected": _ids.slice(0, 5)})
	var un3 := TTProgress.check_achievements(_ids)
	_check("ach3: 5 stars in door 1 unlocks STAR HUNTER + DOOR OF STARS",
		un3.has("first_star") and un3.has("star_door"),
		"unlocked=" + str(un3))
	var fifty: Array = []
	for k in range(50):
		fifty.append(_ids[k])
	TTProgress.save_features_patch({"stars_collected": fifty})
	var un3b := TTProgress.check_achievements(_ids)
	_check("ach3b: 50 stars unlocks STAR COLLECTOR",
		un3b.has("star_50"), "unlocked=" + str(un3b))

	# --- 5. nightmare / speedster / ghost racer / all-215 / daily ---
	TTProgress.save_features_patch({"nightmare_cleared": true})
	var un4 := TTProgress.check_achievements(_ids)
	_check("ach4: nightmare_cleared unlocks NIGHTMARE SLAYER",
		un4.has("nightmare_cleared"), "unlocked=" + str(un4))
	TTProgress.save_features_patch({"best_times": {"L001": 8.5}})
	var un5 := TTProgress.check_achievements(_ids)
	_check("ach5: best time 8.5s unlocks SPEEDSTER",
		un5.has("speedster"), "unlocked=" + str(un5))
	TTProgress.save_features_patch({"best_improved_count": 1})
	var un6 := TTProgress.check_achievements(_ids)
	_check("ach6: beating a best time unlocks GHOST RACER",
		un6.has("ghost_racer"), "unlocked=" + str(un6))
	var today := Time.get_date_string_from_system()
	var daily := {}
	for back in range(3):
		var key := Time.get_date_string_from_unix_time(Time.get_unix_time_from_system() - back * 86400)
		daily[key] = {"completed": true, "best_time": 30.0}
	TTProgress.save_features_patch({"daily_best": daily})
	var un7 := TTProgress.check_achievements(_ids, today)
	_check("ach7: 3-day daily streak unlocks DAILY GRIND",
		un7.has("daily_streak"), "unlocked=" + str(un7) + " today=" + today)
	TTProgress.save_features_patch({"deaths": 500})
	var un8 := TTProgress.check_achievements(_ids)
	_check("ach8: 500 deaths unlocks TRAP MAGNET",
		un8.has("deaths_500"), "unlocked=" + str(un8))
	# NOTE: _write_progress writes a progress-only file (the old
	# fixture-writer shape) which drops the features section, so
	# the accumulated feature fixture is re-applied AFTER it.
	_write_progress(214, _ids)
	TTProgress.save_features_patch({
		"deaths": 500, "stars_collected": fifty,
		"best_times": {"L001": 8.5}, "best_improved_count": 1,
		"nightmare_cleared": true, "daily_best": daily,
	})
	var un9 := TTProgress.check_achievements(_ids, today)
	_check("ach9: all 215 levels unlocks TOWER MASTER",
		un9.has("all_215"), "unlocked=" + str(un9))
	var d9 := TTProgress.load_progress()
	_check("ach9b: all 12 achievements unlocked in this fixture run",
		(d9["achievements_unlocked"] as Array).size() == 12,
		"count=" + str((d9["achievements_unlocked"] as Array).size())
		+ " unlocked=" + str(d9["achievements_unlocked"]))

	# --- 6. ghost caps ------------------------------------------------
	var big: Array = []
	for i in range(700):
		big.append(Vector3(float(i), 480.0, 1.0))
	TTProgress.save_ghost("L001", big)
	var loaded_big := TTProgress.load_ghost("L001")
	_check("ghost1: 700 samples truncate to the 600 cap",
		loaded_big.size() == 600, "size=" + str(loaded_big.size()))
	for k in range(15):
		var sm: Array = [Vector3(70.0, 480.0, 1.0)]
		TTProgress.save_ghost("L%03d" % (k + 1), sm)
	_check("ghost2: ghost levels cap at 12 (LRU prune)",
		TTProgress.ghost_count() <= 12,
		"count=" + str(TTProgress.ghost_count()))
	_check("ghost2b: newest ghost survives the prune",
		not TTProgress.load_ghost("L015").is_empty())

	# --- 7. real ghost record + replay -------------------------------
	_wipe_saves()
	_write_progress(0, [])
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	var game_inst: Node = game_scene.instantiate()
	root.add_child(game_inst)
	await process_frame
	await process_frame
	game_inst.call("build_level", _flat_level(), tuning)
	game_inst.set("persist_stats", true)
	var frames_to_win := await _drive_to_win(game_inst)
	_check("ghost3: scripted run wins the flat level (real recorder)",
		frames_to_win > 0, "frames=" + str(frames_to_win))
	var d10 := TTProgress.load_progress()
	var best_times: Dictionary = d10["best_times"]
	_check("ghost4: win saves a best time for L001",
		best_times.has("L001") and float(best_times["L001"]) > 0.0,
		"best=" + str(best_times.get("L001", "?")))
	var ghost_samples := TTProgress.load_ghost("L001")
	_check("ghost5: win saves a ghost (bounded, non-empty)",
		ghost_samples.size() > 20 and ghost_samples.size() <= 600,
		"samples=" + str(ghost_samples.size()))
	var mono := true
	for i in range(1, ghost_samples.size()):
		if float((ghost_samples[i] as Vector3).x) < float((ghost_samples[i - 1] as Vector3).x) - 1.0:
			mono = false
			break
	_check("ghost6: recorded ghost moves right along the run path",
		mono and float((ghost_samples[ghost_samples.size() - 1] as Vector3).x) > 1000.0,
		"last_x=" + str(float((ghost_samples[ghost_samples.size() - 1] as Vector3).x)))
	var d10b := TTProgress.load_progress()
	_check("ghost7: first win also unlocks FIRST STEPS + SPEEDSTER",
		(d10b["achievements_unlocked"] as Array).has("first_steps")
		and (d10b["achievements_unlocked"] as Array).has("speedster"),
		"unlocked=" + str(d10b["achievements_unlocked"]))
	root.remove_child(game_inst)
	game_inst.queue_free()
	await process_frame
	await process_frame

	# Replay: the saved ghost loads, plays back on the attempt clock,
	# and has no physics bodies.
	var game2: Node = game_scene.instantiate()
	root.add_child(game2)
	await process_frame
	await process_frame
	game2.call("build_level", _flat_level(), tuning)
	var ghost_node: Node = game2.get("_ghost_node")
	_check("ghost8: replay loads the saved ghost into the level",
		ghost_node != null and not (ghost_node.get("samples") as Array).is_empty(),
		"samples=" + str((ghost_node.get("samples") as Array).size() if ghost_node != null else 0))
	var has_body := false
	if ghost_node != null:
		var gnodes: Array = []
		_traverse(ghost_node, gnodes)
		for n in gnodes:
			if n is CollisionShape2D or n is PhysicsBody2D:
				has_body = true
	_check("ghost9: ghost node has NO collision shapes or physics bodies",
		not has_body)
	var hud: Node = game2.get("hud")
	_check("ghost10: HUD shows the GHOST toggle when a ghost exists",
		hud != null and bool(hud.call("is_ghost_visible")) and bool(hud.call("is_ghost_on")))
	var f2 := await _drive_to_win(game2)
	_check("ghost11: replay with ghost ON completes the level",
		f2 > 0, "frames=" + str(f2))
	if ghost_node != null:
		var gx: float = (ghost_node.call("position_at", float(ghost_node.get("playback_time"))) as Vector2).x
		var hero: Node = game2.get("player")
		var hx := float(hero.get("global_position").x) if hero != null else 0.0
		_check("ghost12: ghost follows the recorded path (near the hero)",
			gx > 150.0 and absf(gx - hx) < 120.0,
			"ghost_x=" + str(gx) + " hero_x=" + str(hx))
	# Toggle: HUD path hides the ghost, pause path shows the state.
	game2.call("_set_ghost_visible", false)
	_check("ghost13: ghost toggle OFF hides the ghost node",
		ghost_node != null and not bool(ghost_node.get("visible"))
		and hud != null and not bool(hud.call("is_ghost_on")))
	game2.call("_set_ghost_visible", true)
	_check("ghost13b: ghost toggle ON shows it again",
		ghost_node != null and bool(ghost_node.get("visible"))
		and hud != null and bool(hud.call("is_ghost_on")))
	game2.call("pause_game")
	var pause_btn: Node = game2.get("_pause_ghost_btn")
	_check("ghost14: pause menu has a GHOST ON button when a ghost exists",
		pause_btn != null and str(pause_btn.get("text")) == "GHOST ON")
	game2.call("_on_pause_ghost_toggle")
	_check("ghost14b: pause toggle flips to GHOST OFF + hides ghost",
		pause_btn != null and str(pause_btn.get("text")) == "GHOST OFF"
		and ghost_node != null and not bool(ghost_node.get("visible")))
	game2.call("resume_game")
	root.remove_child(game2)
	game2.queue_free()
	await process_frame
	await process_frame

	# Ghost on vs off: identical completion (no gameplay effect).
	var game3: Node = game_scene.instantiate()
	root.add_child(game3)
	await process_frame
	await process_frame
	game3.call("build_level", _flat_level(), tuning)
	var frames_on := await _drive_to_win(game3)
	root.remove_child(game3)
	game3.queue_free()
	await process_frame
	await process_frame
	var game4: Node = game_scene.instantiate()
	root.add_child(game4)
	await process_frame
	await process_frame
	game4.call("build_level", _flat_level(), tuning)
	game4.call("_set_ghost_visible", false)
	var frames_off := await _drive_to_win(game4)
	root.remove_child(game4)
	game4.queue_free()
	await process_frame
	await process_frame
	_check("ghost15: hero completes identically with ghost on vs off",
		frames_on > 0 and frames_on == frames_off,
		"on=" + str(frames_on) + " off=" + str(frames_off))

	# --- 8. screens show REAL numbers --------------------------------
	_write_progress(99, _ids.slice(0, 100))
	TTProgress.save_features_patch({
		"deaths": 123, "total_time": 3661.0,
		"stars_collected": _ids.slice(0, 25),
		"best_times": {"L001": 8.5, "L002": 12.0},
	})
	# The screen shows stored unlock state, so evaluate the fixture
	# first (5 DONE: first steps/door/star, 100 deaths, speedster).
	TTProgress.check_achievements(_ids)
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var map_inst: Node = map_scene.instantiate()
	root.add_child(map_inst)
	await process_frame
	await process_frame
	await process_frame
	map_inst.call("open_stats")
	await process_frame
	var stats_texts := _label_texts(map_inst.get("_stats"))
	_check("stats1: stats screen shows real deaths",
		stats_texts.has("123"), "texts=" + str(stats_texts))
	_check("stats2: stats screen shows real time played 61:01",
		stats_texts.has("61:01"))
	_check("stats3: stats screen shows real completion 47%",
		stats_texts.has("47%"))
	_check("stats4: stats screen shows real stars 25/215 + levels 100/215",
		stats_texts.has("25/215") and stats_texts.has("100/215"))
	_check("stats5: stats screen shows real fastest level L001 0:08",
		stats_texts.has("L001 0:08"))
	_check("stats6: stats screen shows real best-total 0:20",
		stats_texts.has("0:20"))
	map_inst.call("close_stats")
	map_inst.call("open_achievements")
	await process_frame
	var ach_root: Node = map_inst.get("_achievements")
	_check("ach10: achievements screen opens from the map",
		ach_root != null and bool(ach_root.get("visible")))
	var ach_texts := _label_texts(ach_root)
	_check("ach11: achievements screen lists all 12 with states",
		ach_texts.has("DOOR OPENER") and ach_texts.has("TOWER MASTER")
		and ach_texts.has("DONE") and ach_texts.has("LOCKED"),
		"found=" + str(ach_texts.size()) + " labels texts=" + str(ach_texts))
	var rows := 0
	var all_nodes: Array = []
	_traverse(map_inst.get("_ach_list"), all_nodes)
	for n in all_nodes:
		if n is Panel:
			rows += 1
	_check("ach12: achievements screen has 12 rows",
		rows == 12, "rows=" + str(rows))
	# Map buttons exist (TROPHIES + STATS on the header).
	var map_texts := _label_texts(map_inst)
	_check("map1: map header has TROPHIES + STATS buttons",
		map_texts.has("TROPHIES") and map_texts.has("STATS"))
	root.remove_child(map_inst)
	map_inst.queue_free()
	await process_frame
	await process_frame

	# Restore a FRESH save so no fixture leaks into later steps.
	_wipe_saves()
	_finish()


func _finish() -> void:
	print("F3 SUMMARY: ", _passes.size(), " passed, ", _fails.size(), " failed")
	if not _fails.is_empty():
		print("F3 FAILED: ", ", ".join(_fails))
		quit(1)
		return
	print("F3 ALL PASS")
	quit(0)
