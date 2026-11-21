extends SceneTree

# Lane F2 probe (v1.0.5 Part B): daily challenge + nightmare mode.
# Headless SceneTree script — real map/game scenes, real save files,
# real physics (wins are triggered by teleporting the hero into the
# door rect, the same technique the UI probe uses; passability itself
# is proven by the autopilot: daily 12/12, nightmare 215/215).
# Asserts:
#   v1.0.4 save compat (progress section only -> daily_best empty,
#     nightmare locked + not cleared, nightmare.cfg empty)
#   daily determinism (same date -> identical level, in-engine)
#   map has DAILY + NIGHTMARE buttons; DAILY opens an overlay with
#     today's date + NOT DONE YET; PLAY starts the daily level
#     (TTState.daily, HUD mode DAILY)
#   daily win records daily_best[today] (completed + best_time) and
#     touches NOTHING else (no completed id, no best_times entry,
#     no ghost, highest unchanged)
#   nightmare locked on a fresh save (overlay states the 215-level
#     requirement + DONE 0/215); tapping the locked button never
#     starts a level
#   nightmare unlocks when all 215 are complete (refresh_unlock
#     persists the flag); the map button toggles NIGHTMARE ON, and a
#     stage tap then starts a mirrored + tightened level (spawn x
#     mirrored, falling stand_time 1.0 -> 0.6, HUD NIGHTMARE)
#   nightmare win records ONLY nightmare.cfg (best_times stays
#     empty, completed unchanged); the 215th nightmare win sets
#     nightmare_cleared + unlocks NIGHTMARE SLAYER
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s <abs path>/f2_daily_nightmare_probe.gd
# Prints F2 PASS/FAIL per assertion, exits 0 only if all pass.
# Restores a FRESH save (deletes progress.cfg + nightmare.cfg) at end.

var _fails: Array[String] = []
var _passes: Array[String] = []
var _levels: Array = []
var _ids: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("F2 PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("F2 FAIL: ", name, (" | " + detail) if detail != "" else "")


func _user_file(name: String) -> String:
	return OS.get_user_data_dir() + "/" + name


func _wipe_saves() -> void:
	DirAccess.remove_absolute(_user_file("progress.cfg"))
	DirAccess.remove_absolute(_user_file("nightmare.cfg"))
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


func _find_text_button(parent: Node, text: String) -> Control:
	var all: Array = []
	_traverse(parent, all)
	for n in all:
		if n is Control and str(n.get("text")) == text:
			return n
	return null


func _click_control(btn: Control) -> void:
	var pos: Vector2 = btn.size * 0.5
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	btn.call("_gui_input", press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = pos
	btn.call("_gui_input", release)


func _teleport_win(game_inst: Node) -> bool:
	var runtime: Node = game_inst.get("runtime")
	var player: Node2D = game_inst.get("player")
	if runtime == null or player == null:
		return false
	var door_node: Node = runtime.get("door")
	if door_node == null:
		return false
	var door_rect: Rect2 = door_node.call("door_rect")
	if door_rect.size.x <= 0.0:
		return false
	var target := door_rect.get_center()
	for f in range(60):
		player.global_position = target
		player.set("velocity", Vector2.ZERO)
		await physics_frame
		if bool(runtime.get("level_completed")):
			return true
	return false


func _run() -> void:
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("F2 ERROR: ", str(loaded["error"]))
		_finish()
		return
	_levels = loaded["levels"]
	for lv in _levels:
		_ids.append(str((lv as Dictionary).get("id", "")))
	_check("load0: 215 levels loaded", _levels.size() == 215, "total=" + str(_levels.size()))
	var today := TTDaily.today_string()
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")

	# --- 1. v1.0.4 save compat --------------------------------------
	_wipe_saves()
	_write_progress(14, _ids.slice(0, 14))
	var d0 := TTProgress.load_progress()
	_check("compat1: v1.0.4 save loads, daily_best empty, nightmare locked",
		(d0["daily_best"] as Dictionary).is_empty()
		and bool(d0["nightmare_unlocked"]) == false
		and bool(d0["nightmare_cleared"]) == false
		and TTNightmare.load_completed().is_empty(),
		"daily=" + str(d0["daily_best"]) + " nm_unlocked=" + str(d0["nightmare_unlocked"]))
	_check("compat2: nightmare NOT unlocked at 14/215",
		not TTNightmare.is_unlocked(d0) and not TTNightmare.refresh_unlock())

	# --- 2. daily determinism (in-engine) ----------------------------
	var da: Dictionary = TTDaily.generate_for_date(today)
	var db: Dictionary = TTDaily.generate_for_date(today)
	_check("daily1: same date -> identical level (in-engine)",
		JSON.stringify(da) == JSON.stringify(db), "id=" + str(da.get("id", "?")))
	var dc: Dictionary = TTDaily.generate_for_date("2026-12-25")
	_check("daily2: different date -> different level",
		JSON.stringify(da) != JSON.stringify(dc))
	_check("daily3: daily level id is date-seeded",
		str(da.get("id", "")) == "DAILY-" + today)

	# --- 3. map: DAILY + NIGHTMARE buttons ---------------------------
	TTState.return_door = -1
	TTState.daily = false
	TTState.nightmare = false
	TTState.nightmare_armed = false
	var map_inst: Node = map_scene.instantiate()
	root.add_child(map_inst)
	await process_frame
	await process_frame
	await physics_frame
	var daily_btn := _find_text_button(map_inst, "DAILY")
	var nm_btn := _find_text_button(map_inst, "NIGHTMARE")
	_check("map1: map has a DAILY button", daily_btn != null)
	_check("map2: map has a NIGHTMARE button", nm_btn != null)
	_check("map3: fresh save -> nightmare locked in the map state",
		not bool(map_inst.get("_nightmare_unlocked")))
	# Locked nightmare: tap opens the locked overlay (requirement +
	# DONE 0/215... here 14/215), never starts a level.
	if nm_btn != null:
		_click_control(nm_btn)
		await process_frame
		var nm_ov: Control = map_inst.get("_nightmare_overlay")
		_check("map4: locked NIGHTMARE tap opens the locked overlay",
			nm_ov != null and nm_ov.visible)
		var nm_texts := _label_texts(nm_ov) if nm_ov != null else []
		_check("map5: locked overlay states the 215 requirement + DONE 14/215 (two lines)",
			nm_texts.has("LOCKED - FINISH ALL 215 LEVELS") and nm_texts.has("DONE 14/215"),
			"texts=" + str(nm_texts))
		_check("map6: locked tap causes no scene change + no armed flag",
			map_inst.is_inside_tree()
			and (current_scene == null or not current_scene.has_method("build_level"))
			and not bool(map_inst.get("_nightmare_armed")),
			"armed=" + str(map_inst.get("_nightmare_armed")))
		map_inst.call("close_nightmare_overlay")
		await process_frame
	# Daily overlay: today's date + NOT DONE YET.
	if daily_btn != null:
		_click_control(daily_btn)
		await process_frame
		var d_ov: Control = map_inst.get("_daily_overlay")
		_check("map7: DAILY tap opens the daily overlay",
			d_ov != null and d_ov.visible)
		var d_texts := _label_texts(d_ov) if d_ov != null else []
		_check("map8: daily overlay shows today's date + NOT DONE YET / NEW LEVEL EVERY DAY",
			d_texts.has("TODAY " + today) and d_texts.has("NOT DONE YET") and d_texts.has("NEW LEVEL EVERY DAY"),
			"texts=" + str(d_texts))
		_check("map9: daily overlay has a PLAY button",
			_find_text_button(d_ov, "PLAY") != null if d_ov != null else false)
	root.remove_child(map_inst)
	map_inst.queue_free()
	await process_frame
	await process_frame

	# --- 4. daily PLAY -> daily level, win records only daily_best ---
	TTState.return_door = -1
	TTState.daily = true
	TTState.daily_date = today
	TTState.nightmare = false
	TTState.bonus = false
	TTState.level_index = 0
	var game_daily: Node = game_scene.instantiate()
	root.add_child(game_daily)
	await physics_frame
	await physics_frame
	_check("play1: daily game loads with _is_daily + HUD mode DAILY",
		bool(game_daily.get("_is_daily"))
		and str((game_daily.get("hud") as Node).get("_mode_text")) == "DAILY",
		"mode=" + str((game_daily.get("hud") as Node).get("_mode_text")) if game_daily.get("hud") != null else "?")
	_check("play2: daily level id is today's date-seeded id",
		str((game_daily.get("current_level") as Dictionary).get("id", "")) == "DAILY-" + today)
	var won_daily := await _teleport_win(game_daily)
	_check("play3: teleport into the daily door completes the level", won_daily)
	# The win delay (0.9s) + wipe + scene change run in _process;
	# wait for the map to come back, then read the save.
	for f in range(240):
		await process_frame
		if current_scene != game_daily and current_scene != null and current_scene.has_method("open_picker"):
			break
	var d1 := TTProgress.load_progress()
	var rec: Dictionary = (d1["daily_best"] as Dictionary).get(today, {})
	_check("play4: daily win records daily_best[today] completed + best_time",
		bool(rec.get("completed", false)) and float(rec.get("best_time", 0.0)) > 0.0,
		"rec=" + str(rec))
	_check("play5: daily win touches NO tower progress (no daily id in completed/best_times, highest still 14)",
		not (d1["completed"] as Array).has("DAILY-" + today)
		and not (d1["best_times"] as Dictionary).has("DAILY-" + today)
		and int(d1["highest_unlocked"]) == 14,
		"highest=" + str(d1["highest_unlocked"]) + " best_times=" + str((d1["best_times"] as Dictionary).keys()))
	_check("play6: daily win saves no ghost for the daily id",
		TTProgress.load_ghost("DAILY-" + today).is_empty())
	if is_instance_valid(game_daily):
		root.remove_child(game_daily)
		game_daily.queue_free()
	await process_frame
	await process_frame
	# Daily overlay now shows DONE + the best time.
	TTState.return_door = -1
	TTState.daily = false
	var map2: Node = map_scene.instantiate()
	root.add_child(map2)
	await process_frame
	await process_frame
	await physics_frame
	var daily_btn2 := _find_text_button(map2, "DAILY DONE")
	_check("map10: after a daily win the map button reads DAILY DONE", daily_btn2 != null)
	map2.call("open_daily")
	await process_frame
	var d_texts2 := _label_texts(map2.get("_daily_overlay"))
	var best_str := TTFeatures.format_time(float(rec.get("best_time", 0.0)))
	_check("map11: daily overlay shows DONE + best time after a win",
		d_texts2.has("DONE - BEST " + best_str), "texts=" + str(d_texts2))
	root.remove_child(map2)
	map2.queue_free()
	await process_frame
	await process_frame

	# --- 5. nightmare unlock at 215/215 ------------------------------
	_write_progress(214, _ids)
	TTProgress.save_features_patch({"daily_best": {today: {"completed": true, "best_time": 30.0}}})
	var unlocked := TTNightmare.refresh_unlock()
	var d2 := TTProgress.load_progress()
	_check("nm1: all 215 complete -> refresh_unlock persists nightmare_unlocked",
		unlocked and bool(d2["nightmare_unlocked"]), "unlocked=" + str(d2["nightmare_unlocked"]))
	TTState.return_door = -1
	TTState.nightmare_armed = false
	var map3: Node = map_scene.instantiate()
	root.add_child(map3)
	await process_frame
	await process_frame
	await physics_frame
	_check("nm2: unlocked map shows nightmare unlocked",
		bool(map3.get("_nightmare_unlocked")))
	var nm_btn3 := _find_text_button(map3, "NIGHTMARE")
	_check("nm3: unlocked map has the NIGHTMARE button", nm_btn3 != null)
	if nm_btn3 != null:
		_click_control(nm_btn3)
		await process_frame
		_check("nm4: NIGHTMARE tap arms the mode (button reads NIGHTMARE ON)",
			bool(map3.get("_nightmare_armed")) and _find_text_button(map3, "NIGHTMARE ON") != null,
			"armed=" + str(map3.get("_nightmare_armed")))
	# Stage tap while armed starts a NIGHTMARE run (via the real
	# picker path: open door 1, tap stage 1).
	map3.call("open_picker", 1)
	await process_frame
	var stages: Control = map3.get("_picker_stages")
	var stage_btn: Control = null
	for child in stages.get_children():
		if int(child.get("level")) == 0:
			stage_btn = child
	_check("nm5: door 1 picker has stage 1", stage_btn != null)
	if stage_btn != null:
		TTState.level_index = -1
		_click_control(stage_btn)
		_check("nm6: armed stage tap sets TTState.nightmare + level_index 0",
			TTState.nightmare and TTState.level_index == 0,
			"nightmare=" + str(TTState.nightmare) + " idx=" + str(TTState.level_index))
	var game_nm: Node = null
	for f in range(120):
		await process_frame
		if current_scene != null and current_scene != map3 and current_scene.has_method("build_level"):
			game_nm = current_scene
			break
	_check("nm7: armed stage tap transitions to the game scene", game_nm != null)
	if game_nm == null:
		_finish()
		return
	await physics_frame
	await physics_frame
	_check("nm8: nightmare game is _is_nightmare + HUD mode NIGHTMARE",
		bool(game_nm.get("_is_nightmare"))
		and str((game_nm.get("hud") as Node).get("_mode_text")) == "NIGHTMARE")
	var nm_level: Dictionary = game_nm.get("current_level")
	_check("nm9: nightmare level is x-mirrored (L001 spawn 90 -> 1190)",
		int(float((nm_level.get("spawn", {}) as Dictionary).get("x", 0))) == 1190,
		"spawn_x=" + str((nm_level.get("spawn", {}) as Dictionary).get("x", "?")))
	var stand_ok := false
	for p in (game_nm.get("runtime") as Node).get("platforms"):
		if str(p.get("kind")) == "falling" and absf(float(p.get("stand_time")) - 0.6) < 0.001:
			stand_ok = true
	_check("nm10: nightmare falling stand_time tightened 1.0 -> 0.6", stand_ok)
	var won_nm := await _teleport_win(game_nm)
	_check("nm11: teleport into the nightmare door completes the level", won_nm)
	for f in range(240):
		await process_frame
		if current_scene != game_nm and current_scene != null and current_scene.has_method("open_picker"):
			break
	var nm_done := TTNightmare.load_completed()
	var d3 := TTProgress.load_progress()
	_check("nm12: nightmare win records ONLY nightmare.cfg (L001 there, best_times still empty)",
		nm_done.has("L001") and (d3["best_times"] as Dictionary).is_empty()
		and (d3["completed"] as Array).size() == 215,
		"nm_done=" + str(nm_done) + " best=" + str((d3["best_times"] as Dictionary).keys()))
	_check("nm13: nightmare win does NOT set nightmare_cleared at 1/215",
		not bool(d3["nightmare_cleared"]))
	if is_instance_valid(game_nm):
		root.remove_child(game_nm)
		game_nm.queue_free()
	await process_frame
	await process_frame

	# --- 6. the 215th nightmare win clears the mode ------------------
	var rest: Array = []
	for id in _ids:
		if id != "L001":
			rest.append(id)
	var cfg := ConfigFile.new()
	cfg.set_value("nightmare", "completed", rest)
	cfg.save("user://nightmare.cfg")
	TTState.return_door = -1
	TTState.daily = false
	TTState.nightmare = true
	TTState.bonus = false
	TTState.level_index = 0
	var game_nm2: Node = game_scene.instantiate()
	root.add_child(game_nm2)
	await physics_frame
	await physics_frame
	var won_nm2 := await _teleport_win(game_nm2)
	_check("nm14: 215th nightmare level completes", won_nm2)
	for f in range(240):
		await process_frame
		if current_scene != game_nm2 and current_scene != null and current_scene.has_method("open_picker"):
			break
	var d4 := TTProgress.load_progress()
	_check("nm15: 215th nightmare win sets nightmare_cleared",
		bool(d4["nightmare_cleared"]),
		"cleared=" + str(d4["nightmare_cleared"]))
	_check("nm16: clearing nightmare unlocks NIGHTMARE SLAYER",
		(d4["achievements_unlocked"] as Array).has("nightmare_cleared"),
		"unlocked=" + str(d4["achievements_unlocked"]))
	if is_instance_valid(game_nm2):
		root.remove_child(game_nm2)
		game_nm2.queue_free()
	await process_frame
	await process_frame

	# Restore a FRESH save so no fixture leaks into later steps.
	_wipe_saves()
	TTState.daily = false
	TTState.daily_date = ""
	TTState.nightmare = false
	TTState.nightmare_armed = false
	TTState.return_door = -1
	_finish()


func _finish() -> void:
	print("F2 SUMMARY: ", _passes.size(), " passed, ", _fails.size(), " failed")
	if not _fails.is_empty():
		print("F2 FAILED: ", ", ".join(_fails))
		quit(1)
		return
	print("F2 ALL PASS")
	quit(0)
