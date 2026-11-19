# N2 UI probe (Lane B verification, Run 3 / v1.0.3). Headless SceneTree script.
#
# Instantiates the REAL map scene and game scene and asserts interface
# behaviour through real code paths (scene _ready, direct LevelNode
# taps, button handlers, real hazard deaths, ConfigFile fixtures):
#   map loads with the final levels.json; _total == 215
#   215 level nodes, labels 1..215 in order; locked <=> idx > highest;
#   current <=> idx == highest; "Made by Ahmed" in the map header
#   NO open_picker method exists (flat map, no door picker)
#   locked-node tap is a no-op (level_index unchanged, no scene change)
#   direct node tap sets TTState.level_index + opens that exact level
#   HUD shows the pixel-font level NUMBER (level_number) at idx 0/12/214, incl. restart
#   pause + restart hidden + TAP TO RETRY shown during the dead state
#   (input-edge retry respawns; tap-only, no auto-retry)
#   win on a MID level (idx 12) returns to the map, completes the id,
#   advances highest to 13, and the new map's current node is 13
#   skip returns to the map, advances highest, never completes;
#   skip on the last level does not crash or overflow highest
#   pause freezes the player + panel visible + HUD visible
#   resume/restart/exit work and paused=false after each; ESC path
#   Skip hidden at 0-2 deaths, visible at >=3 (via real deaths)
#   settings persist to settings.cfg + AudioServer bus state applied
#   a v2-format save (save_version 2) is ignored under save_version 3;
#   a v3 save is honoured (positive control)
#   scroll to max makes the last node reachable/visible
#
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s tools/probes/ui_probe.gd
# Prints PASS/FAIL per assertion and exits 0 only if all pass.
# HEADLESS LIMITS (stated plainly, NOT verified here): rendered
# legibility, finger feel, F9 latency, audible audio, non-16:9 letterbox.
# Glow/marker rendering is asserted via the LevelNode `current` flag
# that drives the draw code; pixels are covered by screenshots.
extends SceneTree

var _fails: Array[String] = []
var _passes: Array[String] = []
var _levels: Array = []
var _total := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("N2 PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("N2 FAIL: ", name, (" | " + detail) if detail != "" else "")


func _write_progress(highest: int, completed: Array, save_version: int = 3) -> void:
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


func _has_prop(node: Object, prop: String) -> bool:
	for d in node.get_property_list():
		if str(d["name"]) == prop:
			return true
	return false


# LevelNodes live in the ScrollContainer's content Control. Detected by
# their own properties (level/locked/current/done), never by open_picker
# or any picker API (there is none in v3).
func _level_nodes(map_inst: Node) -> Array:
	var scroll: Control = map_inst.get("_scroll")
	if scroll == null or scroll.get_child_count() == 0:
		return []
	var content: Node = scroll.get_child(0)
	var nodes: Array = []
	for child in content.get_children():
		if _has_prop(child, "level") and _has_prop(child, "locked") and _has_prop(child, "current"):
			nodes.append(child)
	nodes.sort_custom(func(a, b): return int(a.get("level")) < int(b.get("level")))
	return nodes


func _is_map_scene(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if not _has_prop(node, "_total"):
		return false
	return _level_nodes(node).size() == 215


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
# dead), then retry via a REAL input edge (tap-only, v1.0.4 — there is
# no auto-retry timer any more). With retry=false the dead state is
# left held so the caller can assert death-state visuals first.
# Returns true on a real death (and a successful retry when asked).
func _send_retry_key() -> void:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.echo = false
	ev.keycode = KEY_ENTER
	ev.physical_keycode = KEY_ENTER
	Input.parse_input_event(ev)


func _wait_alive(game: Node, frames: int = 30) -> bool:
	var runtime: Node = game.get("runtime")
	if runtime == null:
		return false
	for f in range(frames):
		await physics_frame
		if not bool(runtime.get("dead")):
			return true
	return false


func _death_prompt_visible(game: Node) -> bool:
	for child in game.get_children():
		if str(child.get("text")) == "TAP TO RETRY":
			return bool(child.visible)
	return false


func _hud_button_visible(hud: Node, icon: String) -> Variant:
	for child in hud.get_children():
		if child is Control and str(child.get("icon")) == icon:
			return bool(child.visible)
	return null


func _kill_once(game: Node, retry: bool = true) -> bool:
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
				if not retry:
					return true
				_send_retry_key()
				return await _wait_alive(game)
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


# Wait until current_scene is a map scene different from `old_scene`
# (win/skip return-to-map, past the 0.3s delay). Returns the map or null.
func _wait_for_map(old_scene: Node) -> Node:
	for f in range(120):
		await process_frame
		var cur: Node = current_scene
		if cur != null and cur != old_scene and _is_map_scene(cur):
			return cur
	return null


func _run() -> void:
	print("N2 UI probe (v3 flat map): map + game scenes, real paths, headless")
	# --- load the shipped file through the runtime loader -------------
	var loaded := TTLevelData.load_levels()
	_check("load0: runtime load_levels() of shipped file succeeds",
		str(loaded.get("error", "")) == "", str(loaded.get("error", "")))
	if str(loaded.get("error", "")) != "":
		_finish()
		return
	_levels = loaded["levels"]
	_total = _levels.size()
	print("N2 levels=", _total, " warnings=", (loaded.get("warnings", []) as Array).size())
	_check("load1: shipped file has exactly 215 levels", _total == 215,
		"total=" + str(_total))
	_check("load2: load_levels returns ZERO visual-rule warnings",
		(loaded.get("warnings", []) as Array).is_empty(),
		"warnings=" + str((loaded.get("warnings", []) as Array).size()))

	# --- save-version tests ---------------------------------------------
	_write_progress(50, _ids_upto(50), 2)
	var v2 := TTProgress.load_progress()
	_check("save1: save_version-2 file ignored under version 3 (fresh progress)",
		int(v2["highest_unlocked"]) == 0 and (v2["completed"] as Array).is_empty(),
		"highest=" + str(v2["highest_unlocked"]) + " completed=" + str((v2["completed"] as Array).size()))
	_write_progress(50, _ids_upto(50), 3)
	var v3 := TTProgress.load_progress()
	_check("save2: save_version-3 fixture honoured (positive control)",
		int(v3["highest_unlocked"]) == 50 and (v3["completed"] as Array).size() == 50,
		"highest=" + str(v3["highest_unlocked"]) + " completed=" + str((v3["completed"] as Array).size()))
	_write_progress(0, [])
	var def_prog := _read_progress_file()
	_check("save3: _write_progress default save_version is 3",
		int(def_prog.get("save_version", -1)) == 3,
		"save_version=" + str(def_prog.get("save_version", -1)))

	# --- map, fresh fixture --------------------------------------------
	_write_progress(0, [])
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	var map_inst: Node = map_scene.instantiate()
	root.add_child(map_inst)
	await process_frame
	await process_frame
	await physics_frame
	_check("map1: map _total == 215", int(map_inst.get("_total")) == 215,
		"map_total=" + str(map_inst.get("_total")))
	var nodes := _level_nodes(map_inst)
	_check("map2: 215 level nodes on the map", nodes.size() == 215,
		"nodes=" + str(nodes.size()))
	var labels_ok := nodes.size() == 215
	for i in range(nodes.size()):
		if int(nodes[i].get("level")) != i:
			labels_ok = false
			break
	_check("map3: node labels 1..215 in order (level 0..214)",
		labels_ok)
	var cur_ok := nodes.size() == 215
	var lock_ok := nodes.size() == 215
	var done_ok := nodes.size() == 215
	for n in nodes:
		var idx: int = int(n.get("level"))
		if bool(n.get("current")) != (idx == 0):
			cur_ok = false
		if bool(n.get("locked")) != (idx > 0):
			lock_ok = false
		if bool(n.get("done")):
			done_ok = false
	_check("map4: fresh fixture -> current <=> idx==highest (node 0 only)",
		cur_ok and int(map_inst.get("_highest")) == 0,
		"highest=" + str(map_inst.get("_highest")))
	_check("map5: fresh fixture -> locked <=> idx>highest", lock_ok)
	_check("map6: NO open_picker method exists on the map",
		not map_inst.has_method("open_picker"))
	var header_ok := false
	var all_labels: Array = []
	_traverse(map_inst, all_labels)
	for n in all_labels:
		# Pixel-font credit (TTPixelLabel, not a Label, since v1.0.4).
		if str(n.get("text")) == "Made by Ahmed" and n is Node2D and (n as Node2D).position.y < 104.0:
			header_ok = true
	_check("map7: 'Made by Ahmed' visible in the map header", header_ok)
	_check("map8: fresh fixture -> no node marked done", done_ok)

	# --- locked-node tap is a no-op ------------------------------------
	TTState.level_index = 3
	var scene_before: Node = current_scene
	_click_control(nodes[1])
	await process_frame
	await physics_frame
	_check("lock1: locked-node tap causes no scene change",
		current_scene == scene_before)
	_check("lock2: locked-node tap leaves level_index unchanged",
		TTState.level_index == 3, "level_index=" + str(TTState.level_index))
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
	_check("mid1: mid fixture -> highest 12",
		int(map_inst.get("_highest")) == 12,
		"highest=" + str(map_inst.get("_highest")))
	nodes = _level_nodes(map_inst)
	var mid_ok := nodes.size() == 215
	var mid_done_ok := nodes.size() == 215
	for n in nodes:
		var idx2: int = int(n.get("level"))
		if bool(n.get("current")) != (idx2 == 12):
			mid_ok = false
		if bool(n.get("locked")) != (idx2 > 12):
			mid_ok = false
		if bool(n.get("done")) != (idx2 < 12):
			mid_done_ok = false
	_check("mid2: mid fixture -> node 12 current, 0-12 unlocked, 13+ locked", mid_ok)
	_check("mid3: mid fixture -> nodes 0-11 done, 12+ not done", mid_done_ok)

	# --- scroll test ------------------------------------------------------
	var scroll: ScrollContainer = map_inst.get("_scroll")
	var content_h: float = float(map_inst.get("_content_h"))
	scroll.scroll_vertical = 100000.0
	await process_frame
	await process_frame
	await physics_frame
	var last_node: Control = nodes[nodes.size() - 1]
	var last_rect: Rect2 = last_node.get_global_rect()
	# Viewport height comes from the scroll container itself (was a
	# hardcoded 616.0; the map viewport moved to 608 high when its top
	# moved 104 -> 112 to clear the header credit, so the max moved
	# 2904 -> 2912 — the old constant failed the check, not the map).
	var expected_max: float = maxf(0.0, content_h - float(scroll.size.y))
	_check("scroll1: scroll_vertical=max -> last node reachable/visible",
		absf(float(scroll.scroll_vertical) - expected_max) <= 1.0
		and last_rect.position.y < 720.0 and last_rect.end.y > float(scroll.position.y),
		"scroll=" + str(scroll.scroll_vertical) + " max=" + str(expected_max)
		+ " last_rect=" + str(last_rect))

	# --- direct node tap sets TTState.level_index (real transition) -------
	TTState.level_index = -1
	_click_control(nodes[12])
	_check("tap1: direct node tap sets TTState.level_index to 12",
		TTState.level_index == 12, "level_index=" + str(TTState.level_index))
	# The map->level transition awaits the 0.12s wipe cover before the
	# scene change, so a fixed 2-frame wait races it (tap2 failed on
	# the fixed wait even though the transition itself works — same
	# wait-for-scene pattern _wait_for_map already uses below).
	var game1: Node = null
	for f in range(60):
		await process_frame
		var cur: Node = current_scene
		if cur != null and cur.has_method("build_level"):
			game1 = cur
			break
	_check("tap2: node tap transitions to the game scene",
		game1 != null and game1.has_method("build_level"),
		"current_scene=" + (str(game1) if game1 != null else "null"))
	var game1_ok := game1 != null and int(game1.get("level_index")) == 12
	_check("tap3: game opens the tapped level (idx 12)", game1_ok,
		"game level_index=" + (str(game1.get("level_index")) if game1 != null else "?"))
	if game1 == null:
		_finish()
		return
	# The tapped map instance was freed by the scene change; do not touch it.

	# --- HUD "LEVEL N" at idx 12, incl. after restart ----------------------
	var hud1: Node = game1.get("hud")
	_check("hud1: HUD shows LEVEL 13 at idx 12 (no set_filled method)",
		hud1 != null and int(hud1.get("level_number")) == 13
		and not hud1.has_method("set_filled"),
		"level_number=" + (str(hud1.get("level_number")) if hud1 != null else "?"))
	game1.call("restart_level")
	await process_frame
	await physics_frame
	await physics_frame
	var hud1b: Node = game1.get("hud")
	_check("hud2: HUD still LEVEL 13 after restart",
		hud1b != null and int(hud1b.get("level_number")) == 13,
		"level_number=" + (str(hud1b.get("level_number")) if hud1b != null else "?"))
	hud1 = hud1b

	# --- pause: freeze + panel + HUD --------------------------------------
	var player1: Node2D = game1.get("player")
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
		var play_btn := _find_icon_button(overlay, "play")
		if play_btn != null:
			_click_control(play_btn)
		else:
			game1.call("resume_game")
		await process_frame
		await physics_frame
		_check("pause5: resume unpauses + hides panel",
			paused == false and (overlay == null or not overlay.visible))
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
			# Respawn offset is -ph/2 from the builder (level_builder
			# line 62); ph is 39.0 in v3, so -19.5 — the old hardcoded
			# -22 was the v2 hero height (44) and missed by 2.5px.
			var ph: float = float(player1b.get("ph"))
			spawn_ok = player1b.global_position.distance_to(sp + Vector2(0, -ph * 0.5)) <= 2.0
		_check("pause6: restart unpauses, resets deaths, respawns at spawn",
			paused == false and int(game1.get("deaths")) == 0 and spawn_ok,
			"paused=" + str(paused) + " deaths=" + str(game1.get("deaths")))
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
		for f in range(3):
			await process_frame
		await physics_frame
		await physics_frame
		var esc_scene: Node = current_scene
		_check("esc2: ESC lands on the map scene (215 level nodes, no picker API)",
			_is_map_scene(esc_scene),
			"current_scene=" + (str(esc_scene) if esc_scene != null else "null"))
	else:
		_check("pause0: game player found", false)

	# --- HUD "LEVEL N" at idx 0 and idx 214 --------------------------------
	TTState.level_index = 0
	var game0: Node = game_scene.instantiate()
	root.add_child(game0)
	await physics_frame
	await physics_frame
	var hud0: Node = game0.get("hud")
	_check("hud3: HUD shows LEVEL 1 at idx 0",
		hud0 != null and int(hud0.get("level_number")) == 1,
		"level_number=" + (str(hud0.get("level_number")) if hud0 != null else "?"))
	root.remove_child(game0)
	game0.queue_free()
	await process_frame
	await process_frame
	TTState.level_index = 214
	var game214: Node = game_scene.instantiate()
	root.add_child(game214)
	await physics_frame
	await physics_frame
	var hud214: Node = game214.get("hud")
	_check("hud4: HUD shows LEVEL 215 at idx 214",
		hud214 != null and int(hud214.get("level_number")) == 215,
		"level_number=" + (str(hud214.get("level_number")) if hud214 != null else "?"))
	root.remove_child(game214)
	game214.queue_free()
	await process_frame
	await process_frame

	# --- win test on a MID level (idx 12): return to map -------------------
	_write_progress(12, _ids_upto(12))
	var win_id := str(_levels[12].get("id", ""))
	var scene_before_win: Node = current_scene
	TTState.level_index = 12
	var game_win: Node = game_scene.instantiate()
	root.add_child(game_win)
	await physics_frame
	await physics_frame
	var runtime_win: Node = game_win.get("runtime")
	var player_win: Node2D = game_win.get("player")
	var door_rect := Rect2()
	var door_node: Node = runtime_win.get("door") if runtime_win != null else null
	if door_node != null:
		door_rect = door_node.call("door_rect")
	var won := false
	if player_win != null and runtime_win != null and door_rect.size.x > 0.0:
		var target := door_rect.get_center()
		for f in range(60):
			player_win.global_position = target
			player_win.set("velocity", Vector2.ZERO)
			await physics_frame
			if bool(runtime_win.get("level_completed")):
				won = true
				break
	_check("win1: teleport into door rect completes the mid level",
		won, "door_rect=" + str(door_rect))
	var win_map := await _wait_for_map(scene_before_win)
	_check("win2: win returns to the map scene (past 0.3s delay, no auto-chain)",
		win_map != null)
	var win_prog := _read_progress_file()
	_check("win3: win marks id complete + highest==13",
		(win_prog.get("completed", []) as Array).has(win_id)
		and int(win_prog.get("highest_unlocked", -1)) == 13,
		"completed_has=" + win_id + " highest=" + str(win_prog.get("highest_unlocked", -1)))
	var win_map_ok := false
	if win_map != null:
		var win_nodes := _level_nodes(win_map)
		win_map_ok = int(win_map.get("_highest")) == 13 and win_nodes.size() == 215 \
			and bool(win_nodes[13].get("current")) and not bool(win_nodes[13].get("locked"))
	_check("win4: new map current node is 13", win_map_ok)
	if is_instance_valid(game_win):
		root.remove_child(game_win)
		game_win.queue_free()
	await process_frame
	await process_frame

	# --- skip: hidden 0-2 deaths, visible >=3 (real deaths) --------------
	var death_idx := _find_death_stage()
	_check("skip0: a level with a directly lethal hazard exists", death_idx >= 0,
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
		# Death-state visuals (v1.0.4): hold the FIRST death (no retry
		# yet) and assert the HUD hides + the prompt shows, then retry
		# via a real input edge.
		var k1 := await _kill_once(game2, false)
		await physics_frame
		await physics_frame
		var pause_hid: Variant = _hud_button_visible(hud2, "pause") if hud2 != null else null
		var restart_hid: Variant = _hud_button_visible(hud2, "restart") if hud2 != null else null
		_check("skip0b: pause + restart HIDDEN during dead state, TAP TO RETRY shown",
			k1 and pause_hid == false and restart_hid == false and _death_prompt_visible(game2),
			"pause_visible=" + str(pause_hid) + " restart_visible=" + str(restart_hid)
			+ " prompt=" + str(_death_prompt_visible(game2)))
		_send_retry_key()
		var alive0 := await _wait_alive(game2)
		await physics_frame
		await physics_frame
		_check("skip2: real death 1 lands, input-edge retry respawns, Skip still hidden",
			k1 and alive0 and int(game2.get("deaths")) == 1 and not bool(hud2.call("is_skip_visible")),
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
		var before_prog := _read_progress_file()
		var cur_id := str(_levels[death_idx].get("id", ""))
		var completed_before: Array = before_prog.get("completed", [])
		var scene_before_skip: Node = current_scene
		var skip_btn := _find_skip_button(hud2)
		if skip_btn != null:
			_click_control(skip_btn)
		else:
			game2.call("_on_skip_pressed")
		var skip_map := await _wait_for_map(scene_before_skip)
		_check("skip5: skip returns to the map scene", skip_map != null)
		var after_prog := _read_progress_file()
		var highest_ok: bool = int(after_prog.get("highest_unlocked", -1)) == death_idx + 1
		var completed_after: Array = after_prog.get("completed", [])
		var completed_ok: bool = completed_after.size() == completed_before.size() \
			and not completed_after.has(cur_id)
		_check("skip6: skip advances highest_unlocked without completing",
			highest_ok and completed_ok,
			"highest " + str(before_prog.get("highest_unlocked")) + "->" + str(after_prog.get("highest_unlocked"))
			+ " completed " + str(completed_before.size()) + "->" + str(completed_after.size()))
		if is_instance_valid(game2):
			root.remove_child(game2)
			game2.queue_free()
		await process_frame
		await process_frame

		# --- skip on the LAST level: no crash, no overflow -----------------
		_write_progress(214, _ids_upto(214))
		TTState.level_index = 214
		var game_last: Node = game_scene.instantiate()
		root.add_child(game_last)
		await physics_frame
		await physics_frame
		var hud_last: Node = game_last.get("hud")
		var lk1 := await _kill_once(game_last)
		var lk2 := await _kill_once(game_last)
		var lk3 := await _kill_once(game_last)
		await physics_frame
		var last_before := _read_progress_file()
		var scene_before_last: Node = current_scene
		var last_skip_btn := _find_skip_button(hud_last)
		if last_skip_btn != null and bool(hud_last.call("is_skip_visible")):
			_click_control(last_skip_btn)
		else:
			game_last.call("_on_skip_pressed")
		var last_map := await _wait_for_map(scene_before_last)
		var last_after := _read_progress_file()
		_check("skip7: skip on last level returns to map, no crash, no highest overflow",
			lk1 and lk2 and lk3 and last_map != null
			and int(last_after.get("highest_unlocked", -1)) == 214
			and (last_after.get("completed", []) as Array).size() == (last_before.get("completed", []) as Array).size(),
			"kills=" + str(lk1) + "/" + str(lk2) + "/" + str(lk3)
			+ " highest=" + str(last_after.get("highest_unlocked", -1))
			+ " completed=" + str((last_after.get("completed", []) as Array).size()))
		if is_instance_valid(game_last):
			root.remove_child(game_last)
			game_last.queue_free()
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
	print("N2 NOT VERIFIED HEADLESS: rendered legibility, finger feel, F9 latency, audible audio, non-16:9 letterbox; glow/marker asserted via LevelNode.current flag only.")
	if not _fails.is_empty():
		print("N2 FAILED: ", ", ".join(_fails))
		quit(1)
		return
	print("N2 ALL PASS")
	quit(0)
