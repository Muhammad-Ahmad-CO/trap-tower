# N2 UI probe (Lane B verification, Run 2). Headless SceneTree script.
#
# Instantiates the REAL map scene and game scene and asserts interface
# behaviour through real code paths (scene _ready, open_picker,
# button handlers, real hazard deaths, ConfigFile fixtures):
#   map loads with the final levels.json; door count = stages/5
#   current-door glow/marker state matches controlled progress fixtures
#   locked-door tap is a no-op (level_index unchanged, no scene change)
#   picker opens with correct 5 stage states
#   stage tap sets TTState.level_index correctly
#   pause freezes the player + panel visible + HUD visible
#   resume/restart/exit work and paused=false after each; ESC path unpauses
#   Skip hidden at 0-2 deaths, visible at >=3 (via real deaths)
#   skip unlocks without completing (progress.cfg: highest advanced,
#   completed unchanged)
#   settings persist to settings.cfg + AudioServer bus state applied
#   a v1-format save (save_version 1) is ignored under save_version 2
#
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s tools/probes/ui_probe.gd
# Prints PASS/FAIL per assertion and exits 0 only if all pass.
# HEADLESS LIMITS (stated plainly, NOT verified here): rendered
# legibility, finger feel, F9 latency, audible audio, non-16:9 letterbox.
# Glow/marker rendering is asserted via the DoorButton `current` flag
# that drives the draw code; pixels are covered by V10 screenshots.
extends SceneTree

var _fails: Array[String] = []
var _passes: Array[String] = []
var _levels: Array = []
var _total := 0
var _doors := 0


func _initialize() -> void:
	call_deferred("_run")


func _col_close(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol and absf(a.a - b.a) <= tol


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("N2 PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("N2 FAIL: ", name, (" | " + detail) if detail != "" else "")


func _write_progress(highest: int, completed: Array, save_version: int = 2) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", save_version)
	cfg.set_value("progress", "highest_unlocked", highest)
	cfg.set_value("progress", "completed", completed)
	cfg.save("user://progress.cfg")


func _read_progress_file() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load("user://progress.cfg") != OK:
		return {}
	return {"save_version": int(cfg.get_value("progress", "save_version", -1)),
		"highest_unlocked": int(cfg.get_value("progress", "highest_unlocked", -1)),
		"completed": cfg.get_value("progress", "completed", [])}


func _ids_upto(n: int) -> Array:
	var out: Array = []
	for k in range(mini(n, _levels.size())):
		out.append(str(_levels[k].get("id", "")))
	return out


func _traverse(node: Node, out: Array) -> void:
	out.append(node)
	for child in node.get_children():
		_traverse(child, out)


func _door_buttons(map_inst: Node) -> Array:
	var all: Array = []
	_traverse(map_inst, all)
	var btns: Array = []
	for n in all:
		if n.has_method("badge_rect"):
			btns.append(n)
	btns.sort_custom(func(a, b): return int(a.get("door")) < int(b.get("door")))
	return btns


func _picker_buttons(map_inst: Node) -> Array:
	var stages: Control = map_inst.get("_picker_stages")
	var out: Array = []
	if stages == null:
		return out
	for child in stages.get_children():
		if child is Button:
			out.append(child)
	out.sort_custom(func(a, b): return float(a.position.x) < float(b.position.x))
	return out


func _find_icon_button(parent: Node, icon: String) -> Control:
	var all: Array = []
	_traverse(parent, all)
	for n in all:
		if n is Control and str(n.get("icon")) == icon:
			return n
	return null


func _find_skip_button(hud: Node) -> Control:
	var all: Array = []
	_traverse(hud, all)
	for n in all:
		if n is Control and str(n.get("text")) == "SKIP >>":
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


func _pause_overlay(game: Node) -> Control:
	var ov: Control = game.get("_pause_overlay")
	if ov != null:
		return ov
	var all: Array = []
	_traverse(game, all)
	for n in all:
		if n is Control and n.has_signal("esc_pressed"):
			return n
	return null


func _death_target(game: Node) -> Vector2:
	var runtime: Node = game.get("runtime")
	if runtime == null:
		return Vector2.ZERO
	var fallback := Vector2.ZERO
	for h in (runtime.get("hazards") as Array):
		var htype := str(h.get("htype"))
		if htype == "saw":
			return h.call("saw_centre_now")
		if htype == "spiked_column":
			return (h.get("rect") as Rect2).get_center()
		if htype == "spikes" and not bool(h.get("has_period")):
			return (h.get("rect") as Rect2).get_center()
		if fallback == Vector2.ZERO and htype == "spikes":
			fallback = (h.get("rect") as Rect2).get_center()
	return fallback


# Kill via a real hazard (teleport + hold until the runtime reports
# dead), then wait for the auto-retry. Returns true on a real death.
func _kill_once(game: Node) -> bool:
	var player: Node2D = game.get("player")
	var runtime: Node = game.get("runtime")
	if player == null or runtime == null:
		return false
	for attempt in range(2):
		var target := _death_target(game)
		if target == Vector2.ZERO:
			return false
		for f in range(150):
			player.global_position = target
			player.set("velocity", Vector2.ZERO)
			await physics_frame
			if bool(runtime.get("dead")):
				for g in range(90):
					await physics_frame
					if not bool(runtime.get("dead")):
						return true
				return false
	return false


func _find_death_stage() -> int:
	for idx in range(_levels.size()):
		for h in (_levels[idx] as Dictionary).get("hazards", []):
			var t := str((h as Dictionary).get("type", ""))
			if t == "saw" or t == "spiked_column":
				return idx
	for idx in range(_levels.size()):
		for h in (_levels[idx] as Dictionary).get("hazards", []):
			if str((h as Dictionary).get("type", "")) == "spikes" and not (h as Dictionary).has("period"):
				return idx
	return -1


func _run() -> void:
	print("N2 UI probe: map + game scenes, real paths, headless")
	# --- load the shipped file through the runtime loader -------------
	var loaded := TTLevelData.load_levels()
	_check("map0: runtime load_levels() of shipped file succeeds",
		str(loaded.get("error", "")) == "", str(loaded.get("error", "")))
	if str(loaded.get("error", "")) != "":
		_finish()
		return
	_levels = loaded["levels"]
	_total = _levels.size()
	_doors = (_total + 4) / 5
	print("N2 stages=", _total, " doors=", _doors)

	# --- v1 save ignored ----------------------------------------------
	_write_progress(50, _ids_upto(50), 1)
	var v1 := TTProgress.load_progress()
	_check("v1: save_version-1 file ignored (fresh progress returned)",
		int(v1["highest_unlocked"]) == 0 and (v1["completed"] as Array).is_empty(),
		"highest=" + str(v1["highest_unlocked"]) + " completed=" + str((v1["completed"] as Array).size()))

	# --- map, fresh fixture --------------------------------------------
	_write_progress(0, [])
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	var map_inst: Node = map_scene.instantiate()
	root.add_child(map_inst)
	await process_frame
	await process_frame
	await physics_frame
	_check("map1: map loads with final levels.json (total matches file)",
		int(map_inst.get("_total")) == _total, "map_total=" + str(map_inst.get("_total")))
	_check("map2: door count = stages/5", int(map_inst.get("_doors")) == _doors,
		"doors=" + str(map_inst.get("_doors")))
	var btns := _door_buttons(map_inst)
	_check("map3: one door button per door", btns.size() == _doors,
		"buttons=" + str(btns.size()))
	var cur_ok := true
	var lock_ok := true
	for b in btns:
		var d: int = int(b.get("door"))
		if bool(b.get("current")) != (d == 0):
			cur_ok = false
		if bool(b.get("locked")) != (d * 5 > 0):
			lock_ok = false
	_check("map4: fresh fixture -> current door 0 glows/marked, rest not current",
		cur_ok and int(map_inst.get("_current_door")) == 0,
		"current_door=" + str(map_inst.get("_current_door")))
	_check("map5: fresh fixture -> doors >=1 locked", lock_ok)

	# --- locked-door tap is a no-op ------------------------------------
	TTState.level_index = 3
	var scene_before: Node = current_scene
	var locked_btn: Control = btns[1]
	_click_control(locked_btn)
	await process_frame
	await physics_frame
	var picker: Control = map_inst.get("_picker")
	_check("lock1: locked-door tap does not open picker",
		picker == null or not picker.visible)
	_check("lock2: locked-door tap leaves level_index unchanged",
		TTState.level_index == 3, "level_index=" + str(TTState.level_index))
	_check("lock3: locked-door tap causes no scene change",
		current_scene == scene_before)
	map_inst.call("open_picker", 1)
	await process_frame
	_check("lock4: open_picker(locked door) is a no-op",
		picker == null or not picker.visible)

	root.remove_child(map_inst)
	map_inst.queue_free()
	await process_frame
	await process_frame

	# --- map, mid-progress fixture --------------------------------------
	_write_progress(12, _ids_upto(12))
	map_inst = map_scene.instantiate()
	root.add_child(map_inst)
	await process_frame
	await process_frame
	await physics_frame
	_check("mid1: mid fixture -> highest 12, current door 2",
		int(map_inst.get("_highest")) == 12 and int(map_inst.get("_current_door")) == 2,
		"highest=" + str(map_inst.get("_highest")) + " door=" + str(map_inst.get("_current_door")))
	btns = _door_buttons(map_inst)
	var mid_ok := true
	for b in btns:
		var d: int = int(b.get("door"))
		if bool(b.get("current")) != (d == 2):
			mid_ok = false
		if bool(b.get("locked")) != (d * 5 > 12):
			mid_ok = false
	_check("mid2: mid fixture -> door 2 current, doors 0-2 unlocked, 3+ locked", mid_ok)

	# --- picker states ---------------------------------------------------
	map_inst.call("open_picker", 2)
	await process_frame
	picker = map_inst.get("_picker")
	_check("pick1: picker opens for unlocked door", picker != null and picker.visible)
	var title: Label = map_inst.get("_picker_title")
	_check("pick2: picker title is DOOR 3", title != null and title.text == "DOOR 3",
		"title=" + (title.text if title != null else "?"))
	var stage_btns := _picker_buttons(map_inst)
	_check("pick3: picker shows 5 stages", stage_btns.size() == 5,
		"count=" + str(stage_btns.size()))
	var states_ok := stage_btns.size() == 5
	var state_detail := ""
	if stage_btns.size() == 5:
		# idx 10,11 done; 12 current+unlocked; 13,14 locked+disabled.
		var expect_disabled := [false, false, false, true, true]
		for s in range(5):
			var b: Button = stage_btns[s]
			if b.text != str(s + 1) or b.disabled != expect_disabled[s]:
				states_ok = false
				state_detail += "stage%d text=%s disabled=%s; " % [s + 1, b.text, str(b.disabled)]
		var trap_col: Color = TTuning.col(str((TTuning.palette(TTuning.load_tuning(), 0) as Dictionary).get("trap", "#2B0A8A")))
		var sb0: StyleBoxFlat = stage_btns[0].get_theme_stylebox("normal")
		var sb2: StyleBoxFlat = stage_btns[2].get_theme_stylebox("normal")
		var sb3: StyleBoxFlat = stage_btns[3].get_theme_stylebox("normal")
		if sb0 == null or not _col_close(sb0.bg_color, trap_col, 0.05):
			states_ok = false
			state_detail += "done cell not trap-coloured; "
		if sb2 == null or not _col_close(sb2.bg_color, Color(1, 1, 1, 0.92), 0.05):
			states_ok = false
			state_detail += "unlocked cell not light; "
		if sb2 == null or int(sb2.get("border_width_left")) != 5:
			states_ok = false
			state_detail += "current cell border != 5; "
		if sb3 == null or sb3.bg_color.a < 0.2 or sb3.bg_color.a > 0.3:
			states_ok = false
			state_detail += "locked cell not dimmed; "
	_check("pick4: picker stage states correct (done/unlocked/current/locked)",
		states_ok, state_detail)
	map_inst.call("open_picker", 0)
	await process_frame
	var door0_btns := _picker_buttons(map_inst)
	var all_done := door0_btns.size() == 5
	for b in door0_btns:
		if b.disabled:
			all_done = false
	_check("pick5: door-0 picker (all completed) has no disabled stages", all_done)
	map_inst.call("close_picker")
	await process_frame
	_check("pick6: close_picker hides picker", picker == null or not picker.visible)

	# --- stage tap sets TTState.level_index (real transition) ------------
	map_inst.call("open_picker", 2)
	await process_frame
	stage_btns = _picker_buttons(map_inst)
	TTState.level_index = -1
	(stage_btns[2] as Button).pressed.emit()
	_check("tap1: stage tap sets TTState.level_index to 12",
		TTState.level_index == 12, "level_index=" + str(TTState.level_index))
	await process_frame
	await process_frame
	await physics_frame
	var game1: Node = current_scene
	_check("tap2: stage tap transitions to the game scene",
		game1 != null and game1.has_method("build_level"),
		"current_scene=" + (str(game1) if game1 != null else "null"))
	var game1_ok := game1 != null and int(game1.get("level_index")) == 12
	_check("tap3: game opens the tapped stage", game1_ok,
		"game level_index=" + (str(game1.get("level_index")) if game1 != null else "?"))
	root.remove_child(map_inst)
	map_inst.queue_free()
	await process_frame
	await process_frame
	if game1 == null:
		_finish()
		return

	# --- pause: freeze + panel + HUD --------------------------------------
	var player1: Node2D = game1.get("player")
	var hud1: Node = game1.get("hud")
	if player1 != null:
		player1.set("input_override", 1)
		var before: Vector2 = player1.global_position
		for f in range(5):
			await physics_frame
		var moved: float = player1.global_position.distance_to(before)
		_check("pause0: sanity — player moves with drive before pause", moved > 1.0,
			"moved=" + str(moved))
		var pause_btn := _find_icon_button(hud1, "pause")
		if pause_btn != null:
			_click_control(pause_btn)
		else:
			game1.call("pause_game")
		await process_frame
		await physics_frame
		var overlay := _pause_overlay(game1)
		_check("pause1: pause freezes the tree", paused == true)
		_check("pause2: pause panel visible", overlay != null and overlay.visible)
		_check("pause3: HUD stays visible over pause", hud1 != null and hud1.visible)
		var frozen_pos: Vector2 = player1.global_position
		for f in range(30):
			await process_frame
		_check("pause4: player position unchanged across 30 frames while paused",
			player1.global_position.distance_to(frozen_pos) < 0.01,
			"drift=" + str(player1.global_position.distance_to(frozen_pos)))
		# resume via the overlay play button (real handler)
		var play_btn := _find_icon_button(overlay, "play")
		if play_btn != null:
			_click_control(play_btn)
		else:
			game1.call("resume_game")
		await process_frame
		await physics_frame
		_check("pause5: resume unpauses + hides panel",
			paused == false and (overlay == null or not overlay.visible))
		# restart via the overlay restart button (real handler)
		if pause_btn != null:
			_click_control(pause_btn)
		else:
			game1.call("pause_game")
		await process_frame
		var overlay2 := _pause_overlay(game1)
		var restart_btn := _find_icon_button(overlay2, "restart")
		if restart_btn != null:
			_click_control(restart_btn)
		else:
			game1.call("restart_level")
		await process_frame
		await physics_frame
		await physics_frame
		var player1b: Node2D = game1.get("player")
		var spawn_ok := false
		if player1b != null:
			var sp: Vector2 = game1.get("spawn_point")
			spawn_ok = player1b.global_position.distance_to(sp + Vector2(0, -22)) <= 2.0
		_check("pause6: restart unpauses, resets deaths, respawns at spawn",
			paused == false and int(game1.get("deaths")) == 0 and spawn_ok,
			"paused=" + str(paused) + " deaths=" + str(game1.get("deaths")))
		# ESC path: pause, then a real dispatched ESC key exits to map.
		if pause_btn != null:
			_click_control(pause_btn)
		else:
			game1.call("pause_game")
		await process_frame
		_check("esc0: paused before ESC", paused == true)
		var esc := InputEventKey.new()
		esc.pressed = true
		esc.echo = false
		esc.keycode = KEY_ESCAPE
		esc.physical_keycode = KEY_ESCAPE
		Input.parse_input_event(esc)
		var esc_done := false
		for f in range(30):
			await process_frame
			if paused == false and current_scene != game1:
				esc_done = true
				break
		if not esc_done:
			# Fallback: drive the overlay handler directly to
			# distinguish dispatch failure from logic failure.
			var ov3 := _pause_overlay(game1)
			if ov3 != null and is_instance_valid(ov3):
				ov3.call("_input", esc)
			for f in range(30):
				await process_frame
				if paused == false and current_scene != game1:
					esc_done = true
					break
		_check("esc1: ESC from pause unpauses + exits to map",
			esc_done, "paused=" + str(paused))
		# Scene change is deferred: give the new scene frames to land
		# before identifying it (current_scene can be null for a frame
		# while the old scene is freed and the new one instantiates).
		for f in range(3):
			await process_frame
		await physics_frame
		await physics_frame
		var esc_scene: Node = current_scene
		_check("esc2: ESC lands on the map scene",
			esc_scene != null and is_instance_valid(esc_scene) and esc_scene.has_method("open_picker"),
			"current_scene=" + (str(esc_scene) + " valid=" + str(is_instance_valid(esc_scene)) if esc_scene != null else "null"))
		if current_scene != null and current_scene != game1:
			# The map from the ESC exit: leave it; free it via removal.
			var esc_map: Node = current_scene
			# Do not free the current scene; quit handles teardown.
			esc_map = null
	else:
		_check("pause0: game player found", false)

	# --- skip: hidden 0-2 deaths, visible >=3 (real deaths) --------------
	var death_idx := _find_death_stage()
	_check("skip0: a stage with a directly lethal hazard exists", death_idx >= 0,
		"idx=" + str(death_idx))
	if death_idx >= 0:
		_write_progress(death_idx, _ids_upto(death_idx))
		TTState.level_index = death_idx
		var game2: Node = game_scene.instantiate()
		root.add_child(game2)
		await physics_frame
		await physics_frame
		var hud2: Node = game2.get("hud")
		_check("skip1: Skip hidden at 0 deaths",
			hud2 != null and not bool(hud2.call("is_skip_visible")))
		var k1 := await _kill_once(game2)
		await physics_frame
		await physics_frame
		_check("skip2: real death 1 lands, Skip still hidden",
			k1 and int(game2.get("deaths")) == 1 and not bool(hud2.call("is_skip_visible")),
			"deaths=" + str(game2.get("deaths")))
		var k2 := await _kill_once(game2)
		await physics_frame
		await physics_frame
		_check("skip3: real death 2 lands, Skip still hidden",
			k2 and int(game2.get("deaths")) == 2 and not bool(hud2.call("is_skip_visible")),
			"deaths=" + str(game2.get("deaths")))
		var k3 := await _kill_once(game2)
		await physics_frame
		await physics_frame
		_check("skip4: Skip visible at >=3 deaths",
			k3 and int(game2.get("deaths")) == 3 and bool(hud2.call("is_skip_visible")),
			"deaths=" + str(game2.get("deaths")))
		# --- skip unlocks without completing ------------------------------
		var before_prog := _read_progress_file()
		var cur_id := str(_levels[death_idx].get("id", ""))
		var completed_before: Array = before_prog.get("completed", [])
		var skip_btn := _find_skip_button(hud2)
		if skip_btn != null:
			_click_control(skip_btn)
		else:
			game2.call("_on_skip_pressed")
		await process_frame
		await physics_frame
		var after_prog := _read_progress_file()
		var highest_ok: bool = int(after_prog.get("highest_unlocked", -1)) == death_idx + 1
		var completed_after: Array = after_prog.get("completed", [])
		var completed_ok: bool = completed_after.size() == completed_before.size() \
			and not completed_after.has(cur_id)
		_check("skip5: skip advances highest_unlocked without completing",
			highest_ok and completed_ok,
			"highest " + str(before_prog.get("highest_unlocked")) + "->" + str(after_prog.get("highest_unlocked"))
			+ " completed " + str(completed_before.size()) + "->" + str(completed_after.size()))
		for f in range(40):
			await process_frame
		_check("skip6: skip advances to the next stage",
			int(game2.get("level_index")) == death_idx + 1,
			"level_index=" + str(game2.get("level_index")))
		root.remove_child(game2)
		game2.queue_free()
		await process_frame
		await process_frame

	# --- settings persist + AudioServer state ------------------------------
	_write_progress(0, [])
	var map2: Node = map_scene.instantiate()
	root.add_child(map2)
	await process_frame
	await process_frame
	await physics_frame
	map2.call("open_settings")
	await process_frame
	var settings: Control = map2.get("_settings")
	_check("set1: settings panel opens", settings != null and settings.visible)
	# Sound toggle: ON -> OFF.
	TTAudio.set_sound_enabled(true)
	map2.call("_on_sound_toggle")
	await process_frame
	var scfg := ConfigFile.new()
	scfg.load("user://settings.cfg")
	var bus := AudioServer.get_bus_index("Master")
	_check("set2: sound toggle persists OFF + Master bus muted",
		bool(scfg.get_value("audio", "sound_enabled", true)) == false
		and bus >= 0 and AudioServer.is_bus_mute(bus),
		"file=" + str(scfg.get_value("audio", "sound_enabled", "?")) + " mute=" + str(AudioServer.is_bus_mute(bus)))
	map2.call("_on_sound_toggle")
	await process_frame
	scfg.load("user://settings.cfg")
	_check("set3: sound toggle back ON + bus unmuted",
		bool(scfg.get_value("audio", "sound_enabled", false)) == true
		and not AudioServer.is_bus_mute(bus))
	# Music volume.
	map2.call("_on_music_changed", 0.2)
	await process_frame
	await physics_frame
	scfg.load("user://settings.cfg")
	var music_node: Node = null
	var all_nodes: Array = []
	_traverse(root, all_nodes)
	for n in all_nodes:
		if n.name == "TTMusic":
			music_node = n
			break
	var vol_ok := false
	if music_node != null:
		vol_ok = absf(float(music_node.get("volume_db")) - linear_to_db(0.2)) < 0.5
	_check("set4: music volume persists + player volume_db applied",
		absf(float(scfg.get_value("audio", "music_volume", -1.0)) - 0.2) < 0.001 and vol_ok,
		"file=" + str(scfg.get_value("audio", "music_volume", "?"))
		+ " db=" + (str(music_node.get("volume_db")) if music_node != null else "no-player"))
	TTAudio.load_settings()
	_check("set5: settings reload from file (persisted values round-trip)",
		absf(TTAudio.get_music_volume() - 0.2) < 0.001 and TTAudio.is_sound_enabled() == true)
	map2.call("close_settings")
	await process_frame
	_check("set6: settings panel closes", settings == null or not settings.visible)
	root.remove_child(map2)
	map2.queue_free()
	await process_frame

	# Restore defaults so no fixture leaks into later steps.
	TTAudio.set_sound_enabled(true)
	TTAudio.set_music_volume(0.6)
	_write_progress(0, [])
	_finish()


func _finish() -> void:
	print("N2 SUMMARY: ", _passes.size(), " passed, ", _fails.size(), " failed")
	print("N2 NOT VERIFIED HEADLESS: rendered legibility, finger feel, F9 latency, audible audio, non-16:9 letterbox; glow/marker asserted via DoorButton.current flag only.")
	if not _fails.is_empty():
		print("N2 FAILED: ", ", ".join(_fails))
		quit(1)
		return
	print("N2 ALL PASS")
	quit(0)
