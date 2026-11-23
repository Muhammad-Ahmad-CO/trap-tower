# V5 UI probe (Lane 2 verification, v1.0.5 door map + picker). Headless
# SceneTree script.
#
# Instantiates the REAL map scene and game scene and asserts interface
# behaviour through real code paths (scene _ready, real door/stage taps,
# button handlers, real hazard deaths, ConfigFile fixtures):
#   TTDoorMap static table: 44 doors, door_of boundaries, stage lists,
#   templates (door 3 saw-runs / 4 stages, door 44 final-mega / 1 stage)
#   map loads with the final levels.json; _total == 215
#   CHAPTER-AWARE (Lane P, v1.0.9 condition (a)): the map builds ONE
#   chapter's door nodes per view — Ch.1 = doors 1..16 (16 nodes),
#   Ch.2 = doors 17..30 (14), Ch.3 = doors 31..44 (14) + the bonus
#   node (Ch.3 only). Every per-view count below asserts the exact
#   count for its fixture's chapter (default chapter =
#   chapter_of_door(door_of(highest))); a sum-across-chapters check
#   (chap4) proves 16+14+14 == 44 in total. _is_map_scene derives
#   its expected count from the map's own _chapter.
#   per-chapter door nodes, labels in order within the chapter;
#   locked <=> first stage > highest; current <=> door holds
#   highest; done <=> ALL stage IDs completed (never derived
#   from highest)
#   cold start never auto-opens the picker (picker hidden, return_door -1)
#   door tap opens the picker (title "DOOR N", obstacle subtitle,
#   stage buttons with GLOBAL level numbers, check/lock states);
#   NO NEXT button, no auto-select (no scene change on open)
#   locked door tap is a no-op (picker stays closed)
#   locked stage tap is a no-op (level_index unchanged, still on map)
#   picker dismisses via the X button AND via tap-outside (dim button)
#   stage tap sets TTState.level_index + opens that exact level
#   WIN on a stage returns to the map WITH the picker open for the
#   played door — and explicitly NOT the next level: TTState.level_index
#   unchanged, current scene is the map (no build_level), picker showing
#   completing a stage marks it done + advances highest
#   SKIP after 3 deaths returns to the SAME door's picker, advances
#   highest without completing; skip on the last level: no crash,
#   no highest overflow, picker for door 44
#   pause-exit (exit icon) and ESC return to the PLAIN map (picker
#   closed, return_door cleared to -1)
#   v1.0.4 save fixtures load correctly (save_version 3): fresh,
#   mid-progress highest=14, highest=214 incl. L215 completed ->
#   door 44 done, inconsistent completed-without-highest (lock still
#   derives from highest, never from completed)
#   settings still work (persist + AudioServer state)
#   HUD pixel-font level NUMBER at idx 0/12/214
#   M11 back button (C5a, contract-gated): hud signal back_pressed +
#   is_back_visible() / back_rect() at (136,16) 48x48; click back
#   mid-play / while paused -> plain map, return_door -1; click back
#   during the win delay -> no-op (win completes via its own path);
#   double-tap -> single exit; back hidden in death state; back
#   from a bonus level -> plain map. These checks DEFER (listed,
#   never claimed passing) on a tree where the M11 contract is
#   absent, and execute on the merged tree.
#
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s tools/probes/ui_probe_v105.gd
# Prints PASS/FAIL per assertion and exits 0 only if all pass.
# HEADLESS LIMITS (stated plainly, NOT verified here): rendered
# legibility, finger feel, F9 latency, audible audio, non-16:9 letterbox.
# Glow/marker rendering is asserted via the DoorNode `current` flag
# that drives the draw code; pixels are covered by screenshots.
extends SceneTree

var _fails: Array[String] = []
var _passes: Array[String] = []
var _levels: Array = []
var _total := 0
var _deferred: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("V5 PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("V5 FAIL: ", name, (" | " + detail) if detail != "" else "")


func _defer(name: String, reason: String) -> void:
	_deferred.append(name)
	print("V5 DEFERRED: ", name, " | ", reason)


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


# DoorNodes live in the ScrollContainer's content Control. Detected by
# their own `door` property (LevelNode has `level`, StageButton lives
# under the picker, never in the scroll content).
func _door_nodes(map_inst: Node) -> Array:
	var scroll: Control = map_inst.get("_scroll")
	if scroll == null or scroll.get_child_count() == 0:
		return []
	var content: Node = scroll.get_child(0)
	var nodes: Array = []
	for child in content.get_children():
		if _has_prop(child, "door") and _has_prop(child, "locked") and _has_prop(child, "current"):
			nodes.append(child)
	nodes.sort_custom(func(a, b): return int(a.get("door")) < int(b.get("door")))
	return nodes


# BonusDoorNode carries `bonus_door` (== 45), never `door`, so
# _door_nodes never counts it; this helper counts it separately.
func _bonus_nodes(map_inst: Node) -> Array:
	var scroll: Control = map_inst.get("_scroll")
	if scroll == null or scroll.get_child_count() == 0:
		return []
	var content: Node = scroll.get_child(0)
	var nodes: Array = []
	for child in content.get_children():
		if _has_prop(child, "bonus_door"):
			nodes.append(child)
	return nodes


# Expected main-door count for the chapter the map is VIEWING
# (TTFeatures chapter table: Ch.1 16, Ch.2 14, Ch.3 14).
func _chapter_door_count(map_inst: Node) -> int:
	return (TTFeatures.chapter_doors(int(map_inst.get("_chapter"))) as Array).size()


# Chapter switch the probe-safe way: _apply_chapter rebuilds the map
# in place (synchronous) and calls _scroll_to_current, which awaits
# 2 process frames — so await frames after the call.
func _switch_chapter(map_inst: Node, chapter: int) -> void:
	map_inst.call("_apply_chapter", chapter)
	for f in range(5):
		await process_frame


func _stage_buttons(map_inst: Node) -> Array:
	var stages: Control = map_inst.get("_picker_stages")
	if stages == null:
		return []
	var out: Array = []
	for child in stages.get_children():
		if _has_prop(child, "level") and _has_prop(child, "locked") and _has_prop(child, "done"):
			out.append(child)
	out.sort_custom(func(a, b): return int(a.get("level")) < int(b.get("level")))
	return out


func _picker_visible(map_inst: Node) -> bool:
	var p: Control = map_inst.get("_picker")
	return p != null and p.visible


func _picker_door(map_inst: Node) -> int:
	return int(map_inst.get("_picker_door"))


func _picker_title(map_inst: Node) -> String:
	var t: Node = map_inst.get("_picker_title")
	return str(t.get("text")) if t != null else ""


func _picker_subtitle(map_inst: Node) -> String:
	var t: Node = map_inst.get("_picker_subtitle")
	return str(t.get("text")) if t != null else ""


# Chapter-derived recognition (Lane P C4(iii)): the expected node
# count comes from the map's OWN _chapter via the TTFeatures
# chapter table — never a bare 44, never a bare "14 or 16", so a
# wrong-chapter build cannot pass recognition. (The game scene has
# no _total/_chapter props, so it still fails here.)
func _is_map_scene(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if not _has_prop(node, "_total") or not _has_prop(node, "_chapter"):
		return false
	if int(node.get("_total")) != 215:
		return false
	return _door_nodes(node).size() == _chapter_door_count(node)


func _find_icon_button(parent: Node, icon: String) -> Control:
	var all: Array = []
	_traverse(parent, all)
	for n in all:
		if n is Control and str(n.get("icon")) == icon:
			return n
	return null


func _find_text_button(parent: Node, text: String) -> Control:
	var all: Array = []
	_traverse(parent, all)
	for n in all:
		if n is Control and str(n.get("text")) == text:
			return n
	return null


func _find_skip_button(hud: Node) -> Control:
	var all: Array = []
	_traverse(hud, all)
	for n in all:
		if n is Control and str(n.get("text")) == "SKIP >>":
			return n
	return null


func _find_dim_button(map_inst: Node) -> Control:
	var p: Control = map_inst.get("_picker")
	if p == null:
		return null
	for child in p.get_children():
		if child is Button and child.size == Vector2(1280, 720) and str(child.get("text")) == "":
			return child
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


# Topmost STOP-filter control under `parent` at a viewport point:
# later siblings are on top, so walk children in reverse. A nested
# child only counts if every ancestor up to `parent` is visible and
# does not IGNORE mouse. (Structural hit-test: proves which control a
# real tap at that point lands on, without relying on headless input
# routing — see pick16 note.)
func _topmost_at(parent: Node, point: Vector2) -> Control:
	var kids := parent.get_children()
	kids.reverse()
	for child in kids:
		if not (child is Control):
			continue
		var c := child as Control
		if not c.visible:
			continue
		if not c.get_global_rect().has_point(point):
			continue
		if c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			continue
		var inner := _topmost_at(c, point)
		if inner != null:
			return inner
		if c.mouse_filter == Control.MOUSE_FILTER_STOP:
			return c
	return null


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
# (win/skip return-to-map, past the 0.9s win delay + wipe). Returns
# the map or null. 240 frames covers the 0.9s delay + 0.12s wipe +
# the map's 2-frame return-door settle at 60fps.
func _wait_for_map(old_scene: Node) -> Node:
	for f in range(240):
		await process_frame
		var cur: Node = current_scene
		if cur != null and cur != old_scene and _is_map_scene(cur):
			return cur
	return null


# Wait until current_scene is a game scene different from `old_scene`
# (stage tap -> level, past the 0.12s wipe cover).
func _wait_for_game(old_scene: Node) -> Node:
	for f in range(120):
		await process_frame
		var cur: Node = current_scene
		if cur != null and cur != old_scene and cur.has_method("build_level"):
			return cur
	return null


func _run() -> void:
	print("V5 UI probe (v1.0.5 door map + picker): map + game scenes, real paths, headless")
	# --- load the shipped file through the runtime loader -------------
	var loaded := TTLevelData.load_levels()
	_check("load0: runtime load_levels() of shipped file succeeds",
		str(loaded.get("error", "")) == "", str(loaded.get("error", "")))
	if str(loaded.get("error", "")) != "":
		_finish()
		return
	_levels = loaded["levels"]
	_total = _levels.size()
	print("V5 levels=", _total, " warnings=", (loaded.get("warnings", []) as Array).size())
	_check("load1: shipped file has exactly 215 levels", _total == 215,
		"total=" + str(_total))
	# Identity-pinned (Lane P C4(i)): exactly the 2 documented L118
	# rule-7 warnings — size == 2 AND both strings match exactly.
	# Count-only would pass if the L118 warnings vanished and two
	# different warnings appeared; this does not.
	var _warns: Array = loaded.get("warnings", [])
	_check("load2: load_levels returns exactly the 2 documented L118 rule-7 warnings",
		_warns.size() == 2
		and _warns.has("level L118 rule 7: platforms[2] dashed is neither shaft-flanked nor resting")
		and _warns.has("level L118 rule 7: platforms[3] dashed is neither shaft-flanked nor resting"),
		"warnings=" + str(_warns))

	# --- TTDoorMap static table -----------------------------------------
	_check("door0: TTDoorMap.door_count() == 44", TTDoorMap.door_count() == 44,
		"count=" + str(TTDoorMap.door_count()))
	var door_sum := 0
	for d in range(1, 45):
		door_sum += (TTDoorMap.door_levels(d) as Array).size()
	_check("door1: 44 doors hold 215 stages in total", door_sum == 215,
		"sum=" + str(door_sum))
	_check("door2: door_of boundaries (0->1, 10->3, 14->4, 209->43, 214->44)",
		TTDoorMap.door_of(0) == 1 and TTDoorMap.door_of(10) == 3
		and TTDoorMap.door_of(14) == 4 and TTDoorMap.door_of(209) == 43
		and TTDoorMap.door_of(214) == 44,
		"door_of(10)=" + str(TTDoorMap.door_of(10)) + " door_of(14)=" + str(TTDoorMap.door_of(14)))
	_check("door3: door 3 has 4 stages L011-014, door 44 has 1 stage L215",
		(TTDoorMap.door_levels(3) as Array) == [10, 11, 12, 13]
		and (TTDoorMap.door_levels(44) as Array) == [214],
		"d3=" + str(TTDoorMap.door_levels(3)) + " d44=" + str(TTDoorMap.door_levels(44)))
	_check("door4: templates distinct per door (1 pitfall, 3 saw-runs, 44 final-mega)",
		TTDoorMap.door_template(1) == "pitfall"
		and TTDoorMap.door_template(3) == "saw-runs"
		and TTDoorMap.door_template(14) == "tilting-blocks"
		and TTDoorMap.door_template(44) == "final-mega",
		"d14=" + TTDoorMap.door_template(14))

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

	# --- map, fresh fixture: cold start, Ch.1 = 16 doors ----------------
	TTState.return_door = -1
	_write_progress(0, [])
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	var map_inst: Node = map_scene.instantiate()
	root.add_child(map_inst)
	await process_frame
	await process_frame
	await physics_frame
	await process_frame
	await process_frame
	_check("map1: map _total == 215", int(map_inst.get("_total")) == 215,
		"map_total=" + str(map_inst.get("_total")))
	var nodes := _door_nodes(map_inst)
	_check("map2: Ch.1 view (highest 0) has 16 door nodes", nodes.size() == 16,
		"nodes=" + str(nodes.size()))
	var labels_ok := nodes.size() == 16
	for i in range(nodes.size()):
		if int(nodes[i].get("door")) != i + 1:
			labels_ok = false
			break
	_check("map3: door labels 1..16 in order (Ch.1)", labels_ok)
	var cur_ok := nodes.size() == 16
	var lock_ok := nodes.size() == 16
	var done_ok := nodes.size() == 16
	for n in nodes:
		var d: int = int(n.get("door"))
		if bool(n.get("current")) != (d == 1):
			cur_ok = false
		if bool(n.get("locked")) != (d > 1):
			lock_ok = false
		if bool(n.get("done")):
			done_ok = false
	_check("map4: fresh fixture -> current <=> door 1 only",
		cur_ok and int(map_inst.get("_highest")) == 0,
		"highest=" + str(map_inst.get("_highest")))
	_check("map5: fresh fixture -> locked <=> door > 1", lock_ok)
	_check("map6: fresh fixture -> no door marked done", done_ok)
	_check("map7: map HAS open_picker (door picker API present)",
		map_inst.has_method("open_picker"))
	var header_ok := false
	var all_labels: Array = []
	_traverse(map_inst, all_labels)
	# Logo integration (20 Nov 2026): the header grew — the logo plaque
	# is 176px tall, so the credit now sits at y186 and the scroll
	# viewport at y214 (was y84 / y148). The assertion's intent is
	# unchanged (credit visible in the header, above the scroll
	# viewport), but the bound is now derived from the real viewport
	# position instead of the old hardcoded 104.
	var viewport_y := 148.0
	var sc = map_inst.get("_scroll")
	if sc != null and sc is Control:
		viewport_y = (sc as Control).position.y
	for n in all_labels:
		if str(n.get("text")) == "Made by Ahmed" and n is Node2D and (n as Node2D).position.y < viewport_y:
			header_ok = true
	_check("map8: 'Made by Ahmed' visible in the map header", header_ok)
	_check("cold1: cold start never auto-opens the picker",
		not _picker_visible(map_inst) and TTState.return_door == -1 and _picker_door(map_inst) == 0,
		"picker_visible=" + str(_picker_visible(map_inst)) + " return_door=" + str(TTState.return_door))

	# --- locked door tap is a no-op --------------------------------------
	TTState.level_index = 3
	var scene_before: Node = current_scene
	_click_control(nodes[1])
	await process_frame
	await physics_frame
	_check("lock1: locked-door tap leaves picker closed",
		not _picker_visible(map_inst) and _picker_door(map_inst) == 0)
	_check("lock2: locked-door tap causes no scene change",
		current_scene == scene_before)
	_check("lock3: locked-door tap leaves level_index unchanged",
		TTState.level_index == 3, "level_index=" + str(TTState.level_index))
	# open_picker on a locked door directly is also a no-op.
	map_inst.call("open_picker", 2)
	await process_frame
	_check("lock4: open_picker(2) on locked door is a no-op",
		not _picker_visible(map_inst) and _picker_door(map_inst) == 0)

	# --- door 1 tap opens the picker --------------------------------------
	_click_control(nodes[0])
	await process_frame
	await physics_frame
	_check("pick1: door 1 tap opens the picker",
		_picker_visible(map_inst) and _picker_door(map_inst) == 1,
		"door=" + str(_picker_door(map_inst)))
	_check("pick2: picker title is 'DOOR 1'",
		_picker_title(map_inst) == "DOOR 1", "title=" + _picker_title(map_inst))
	_check("pick3: picker subtitle is the door obstacle type 'PITFALL'",
		_picker_subtitle(map_inst) == "PITFALL", "subtitle=" + _picker_subtitle(map_inst))
	var stages := _stage_buttons(map_inst)
	_check("pick4: door 1 picker has 5 stage buttons", stages.size() == 5,
		"stages=" + str(stages.size()))
	var stage_nums_ok := stages.size() == 5
	var stage_lock_ok := stages.size() == 5
	var stage_done_ok := stages.size() == 5
	for i in range(stages.size()):
		if int(stages[i].get("level")) != i:
			stage_nums_ok = false
		if bool(stages[i].get("locked")) != (i > 0):
			stage_lock_ok = false
		if bool(stages[i].get("done")):
			stage_done_ok = false
	_check("pick5: stage buttons carry GLOBAL level numbers 1..5 (levels 0..4)",
		stage_nums_ok)
	_check("pick6: fresh picker -> stage 1 unlocked, stages 2-5 locked", stage_lock_ok)
	_check("pick7: fresh picker -> no stage marked done", stage_done_ok)
	_check("pick8: picker has NO NEXT button (no auto-advance affordance)",
		_find_text_button(map_inst.get("_picker"), "NEXT") == null
		and _find_text_button(map_inst.get("_picker"), "NEXT >>") == null)
	_check("pick9: opening the picker does not change the scene",
		current_scene == scene_before)
	# Locked stage tap is a no-op (stage idx 1, level 2).
	TTState.level_index = -1
	_click_control(stages[1])
	await process_frame
	await physics_frame
	_check("pick10: locked-stage tap leaves level_index unchanged",
		TTState.level_index == -1, "level_index=" + str(TTState.level_index))
	_check("pick11: locked-stage tap leaves picker open on door 1",
		_picker_visible(map_inst) and _picker_door(map_inst) == 1)
	# Dismiss via the X button.
	var close_btn := _find_text_button(map_inst.get("_picker"), "X")
	_check("pick12: picker close X button exists", close_btn != null)
	if close_btn != null:
		_click_control(close_btn)
		await process_frame
		_check("pick13: X button dismisses the picker",
			not _picker_visible(map_inst) and _picker_door(map_inst) == 0)
	# Reopen, dismiss via tap-outside (dim button, point outside panel).
	map_inst.call("open_picker", 1)
	await process_frame
	_check("pick14: open_picker(1) reopens the picker",
		_picker_visible(map_inst) and _picker_door(map_inst) == 1)
	var dim_btn := _find_dim_button(map_inst)
	_check("pick15: tap-outside dim button exists under the picker", dim_btn != null)
	# Tap-outside, headless evidence (NOT a literal tap): viewport-
	# routed mouse input does not reach ANY control's _gui_input in
	# this headless SceneTree setup — proven by /tmp/dim_diag2.gd,
	# where a routed click on the X button AND on a door node both
	# did nothing, while direct _gui_input on those same controls
	# works (pick1/pick13 pass). So the literal tap cannot be
	# exercised headless; instead prove the two halves that make it
	# work: (a) a real tap at (100,100) — outside the panel — lands
	# on the dim button (topmost STOP control there), and (b) the dim
	# button's pressed signal is wired to close_picker (emit closes).
	# A direct _gui_input call on a stock Button is NOT used: it
	# hangs the headless run (/tmp/dim_diag.gd method A).
	var top := _topmost_at(map_inst.get("_picker"), Vector2(100, 100))
	_check("pick16: tap-outside point (100,100) lands on the dim button (topmost STOP control)",
		top == dim_btn,
		"topmost=" + (str(top) if top != null else "null"))
	if dim_btn != null:
		var conns := dim_btn.get_signal_connection_list("pressed")
		_check("pick17: dim button pressed has exactly 1 connection",
			conns.size() == 1, "connections=" + str(conns.size()))
		dim_btn.emit_signal("pressed")
		await process_frame
		_check("pick18: dim button pressed closes the picker (close_picker wiring)",
			not _picker_visible(map_inst) and _picker_door(map_inst) == 0)
	root.remove_child(map_inst)
	map_inst.queue_free()
	await process_frame
	await process_frame

	# --- map, mid-progress fixture (highest=14) ---------------------------
	_write_progress(14, _ids_upto(14))
	map_inst = map_scene.instantiate()
	root.add_child(map_inst)
	await process_frame
	await process_frame
	await physics_frame
	await process_frame
	await process_frame
	_check("mid1: mid fixture -> highest 14",
		int(map_inst.get("_highest")) == 14,
		"highest=" + str(map_inst.get("_highest")))
	nodes = _door_nodes(map_inst)
	var mid_ok := nodes.size() == 16
	var mid_done_ok := nodes.size() == 16
	for n in nodes:
		var d2: int = int(n.get("door"))
		if bool(n.get("current")) != (d2 == 4):
			mid_ok = false
		if bool(n.get("locked")) != (d2 > 4):
			mid_ok = false
		# Doors 1-3 fully completed (ids up to 14 cover L001-014);
		# door 4 holds highest (idx 14) so not all its stages done.
		if bool(n.get("done")) != (d2 <= 3):
			mid_done_ok = false
	_check("mid2: mid fixture -> door 4 current, doors 1-4 unlocked, 5+ locked", mid_ok)
	_check("mid3: mid fixture -> doors 1-3 done, door 4+ not done", mid_done_ok)
	# Door 3 picker: 4 stages, all done, subtitle SAW-RUNS.
	map_inst.call("open_picker", 3)
	await process_frame
	_check("mid4: door 3 picker title 'DOOR 3' + subtitle 'SAW-RUNS'",
		_picker_title(map_inst) == "DOOR 3" and _picker_subtitle(map_inst) == "SAW-RUNS",
		"title=" + _picker_title(map_inst) + " subtitle=" + _picker_subtitle(map_inst))
	stages = _stage_buttons(map_inst)
	_check("mid5: door 3 picker has exactly 4 stage buttons", stages.size() == 4,
		"stages=" + str(stages.size()))
	var d3_ok := stages.size() == 4
	for i in range(stages.size()):
		if int(stages[i].get("level")) != 10 + i:
			d3_ok = false
		if bool(stages[i].get("locked")) or not bool(stages[i].get("done")):
			d3_ok = false
	_check("mid6: door 3 stages are levels 11-14, all unlocked + done", d3_ok)
	# Door 14 picker (first stage 64) is locked at highest 14.
	map_inst.call("close_picker")
	await process_frame
	map_inst.call("open_picker", 14)
	await process_frame
	_check("mid7: open_picker(14) on locked door is a no-op at highest 14",
		not _picker_visible(map_inst) and _picker_door(map_inst) == 0)
	# Door 4 picker: 5 stages, stage idx 14 unlocked, 15-18 locked.
	map_inst.call("open_picker", 4)
	await process_frame
	stages = _stage_buttons(map_inst)
	_check("mid8: door 4 picker has 5 stage buttons", stages.size() == 5,
		"stages=" + str(stages.size()))
	var d4_ok := stages.size() == 5
	for i in range(stages.size()):
		if int(stages[i].get("level")) != 14 + i:
			d4_ok = false
		if bool(stages[i].get("locked")) != (i > 0):
			d4_ok = false
	_check("mid9: door 4 stages are levels 15-19, first unlocked, rest locked", d4_ok)
	# Scroll to max: the last door is reachable/visible.
	var scroll: ScrollContainer = map_inst.get("_scroll")
	var content_h: float = float(map_inst.get("_content_h"))
	scroll.scroll_vertical = 100000.0
	await process_frame
	await process_frame
	await physics_frame
	var last_node: Control = nodes[nodes.size() - 1]
	var last_rect: Rect2 = last_node.get_global_rect()
	var expected_max: float = maxf(0.0, content_h - float(scroll.size.y))
	_check("scroll1: scroll_vertical=max -> last door reachable/visible",
		absf(float(scroll.scroll_vertical) - expected_max) <= 1.0
		and last_rect.position.y < 720.0 and last_rect.end.y > float(scroll.position.y),
		"scroll=" + str(scroll.scroll_vertical) + " max=" + str(expected_max)
		+ " last_rect=" + str(last_rect))

	# --- stage tap sets TTState.level_index + opens that exact level ------
	# Picker for door 3 is closed above; reopen it, tap stage idx 12.
	map_inst.call("open_picker", 3)
	await process_frame
	stages = _stage_buttons(map_inst)
	TTState.level_index = -1
	var scene_before_tap: Node = current_scene
	_click_control(stages[2])
	_check("tap1: stage tap sets TTState.level_index to 12",
		TTState.level_index == 12, "level_index=" + str(TTState.level_index))
	var game1: Node = await _wait_for_game(scene_before_tap)
	_check("tap2: stage tap transitions to the game scene", game1 != null,
		"current_scene=" + (str(game1) if game1 != null else "null"))
	_check("tap3: game opens the tapped level (idx 12)",
		game1 != null and int(game1.get("level_index")) == 12,
		"game level_index=" + (str(game1.get("level_index")) if game1 != null else "?"))
	if game1 == null:
		_finish()
		return
	# The tapped map instance was freed by the scene change; do not touch it.
	var hud1: Node = game1.get("hud")
	_check("hud1: HUD shows LEVEL 13 at idx 12",
		hud1 != null and int(hud1.get("level_number")) == 13,
		"level_number=" + (str(hud1.get("level_number")) if hud1 != null else "?"))
	if is_instance_valid(game1):
		root.remove_child(game1)
		game1.queue_free()
	await process_frame
	await process_frame

	# --- HUD "LEVEL N" at idx 0 and idx 214 --------------------------------
	TTState.level_index = 0
	var game0: Node = game_scene.instantiate()
	root.add_child(game0)
	await physics_frame
	await physics_frame
	var hud0: Node = game0.get("hud")
	_check("hud2: HUD shows LEVEL 1 at idx 0",
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
	_check("hud3: HUD shows LEVEL 215 at idx 214",
		hud214 != null and int(hud214.get("level_number")) == 215,
		"level_number=" + (str(hud214.get("level_number")) if hud214 != null else "?"))
	root.remove_child(game214)
	game214.queue_free()
	await process_frame
	await process_frame

	# --- win on a MID level (idx 12): return to map WITH picker -----------
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
	_check("win2: win returns to the map scene (past 0.9s delay, no auto-chain)",
		win_map != null)
	if win_map != null:
		# The new map's _maybe_open_return_door settles 2 frames after
		# _ready; give it a few more before asserting picker state.
		for f in range(5):
			await process_frame
		_check("win3: after win the current scene is the MAP (not a game scene)",
			not win_map.has_method("build_level"),
			"current_scene=" + str(win_map))
		_check("win4: NO auto-advance — TTState.level_index is still 12",
			TTState.level_index == 12, "level_index=" + str(TTState.level_index))
		_check("win5: after win the picker is OPEN for the played door (3)",
			_picker_visible(win_map) and _picker_door(win_map) == 3,
			"picker_visible=" + str(_picker_visible(win_map)) + " door=" + str(_picker_door(win_map)))
		_check("win6: auto-returned picker title 'DOOR 3' + subtitle 'SAW-RUNS'",
			_picker_title(win_map) == "DOOR 3" and _picker_subtitle(win_map) == "SAW-RUNS",
			"title=" + _picker_title(win_map) + " subtitle=" + _picker_subtitle(win_map))
		var win_stages := _stage_buttons(win_map)
		_check("win7: auto-returned picker shows door 3's 4 stages",
			win_stages.size() == 4, "stages=" + str(win_stages.size()))
	var win_prog := _read_progress_file()
	_check("win8: win marks id complete + highest==13",
		(win_prog.get("completed", []) as Array).has(win_id)
		and int(win_prog.get("highest_unlocked", -1)) == 13,
		"completed_has=" + win_id + " highest=" + str(win_prog.get("highest_unlocked", -1)))
	var win_map_ok := false
	if win_map != null:
		var win_nodes := _door_nodes(win_map)
		# highest 13 still sits inside door 3 (stages 10-13): door 3
		# is CURRENT, and NOT done yet — L014 (idx 13) is still open.
		win_map_ok = int(win_map.get("_highest")) == 13 and win_nodes.size() == 16 \
			and bool(win_nodes[2].get("current")) and not bool(win_nodes[2].get("done")) \
			and not bool(win_nodes[3].get("current"))
	_check("win9: new map: highest 13, door 3 current (L014 still open), door 4 not current", win_map_ok)
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
		var death_door := TTDoorMap.door_of(death_idx)
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
		_check("skip2: real death 1 lands, input-edge retry respawns, Skip still hidden",
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
		if skip_map != null:
			for f in range(5):
				await process_frame
			_check("skip6: skip returns to the SAME door's picker (door " + str(death_door) + ")",
				_picker_visible(skip_map) and _picker_door(skip_map) == death_door,
				"picker_visible=" + str(_picker_visible(skip_map)) + " door=" + str(_picker_door(skip_map)))
			_check("skip7: skip does NOT auto-advance — level_index still the skipped level",
				TTState.level_index == death_idx, "level_index=" + str(TTState.level_index))
		var after_prog := _read_progress_file()
		var highest_ok: bool = int(after_prog.get("highest_unlocked", -1)) == death_idx + 1
		var completed_after: Array = after_prog.get("completed", [])
		var completed_ok: bool = completed_after.size() == completed_before.size() \
			and not completed_after.has(cur_id)
		_check("skip8: skip advances highest_unlocked without completing",
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
		_check("skip9: skip on last level returns to map, no crash, no highest overflow",
			lk1 and lk2 and lk3 and last_map != null
			and int(last_after.get("highest_unlocked", -1)) == 214
			and (last_after.get("completed", []) as Array).size() == (last_before.get("completed", []) as Array).size(),
			"kills=" + str(lk1) + "/" + str(lk2) + "/" + str(lk3)
			+ " highest=" + str(last_after.get("highest_unlocked", -1))
			+ " completed=" + str((last_after.get("completed", []) as Array).size()))
		if last_map != null:
			for f in range(5):
				await process_frame
			_check("skip10: skip on last level returns to door 44's picker",
				_picker_visible(last_map) and _picker_door(last_map) == 44,
				"picker_visible=" + str(_picker_visible(last_map)) + " door=" + str(_picker_door(last_map)))
		if is_instance_valid(game_last):
			root.remove_child(game_last)
			game_last.queue_free()
		await process_frame
		await process_frame

	# --- pause-exit returns to the PLAIN map -------------------------------
	TTState.return_door = -1
	_write_progress(0, [])
	TTState.level_index = 0
	var scene_before_pause: Node = current_scene
	var game3: Node = game_scene.instantiate()
	root.add_child(game3)
	await physics_frame
	await physics_frame
	game3.call("pause_game")
	await process_frame
	await physics_frame
	var overlay3 := _pause_overlay(game3)
	_check("pause1: pause freezes the tree + panel visible",
		paused == true and overlay3 != null and overlay3.visible)
	var exit_btn := _find_icon_button(overlay3, "exit") if overlay3 != null else null
	_check("pause2: pause overlay has an exit button", exit_btn != null)
	if exit_btn != null:
		_click_control(exit_btn)
	var pause_map := await _wait_for_map(scene_before_pause)
	_check("pause3: pause-exit returns to the map scene", pause_map != null)
	if pause_map != null:
		for f in range(5):
			await process_frame
		_check("pause4: pause-exit map is PLAIN (picker closed)",
			not _picker_visible(pause_map) and _picker_door(pause_map) == 0,
			"picker_visible=" + str(_picker_visible(pause_map)))
		_check("pause5: pause-exit clears return_door to -1",
			TTState.return_door == -1, "return_door=" + str(TTState.return_door))
	if is_instance_valid(game3):
		root.remove_child(game3)
		game3.queue_free()
	await process_frame
	await process_frame

	# --- ESC (unpaused) returns to the PLAIN map ---------------------------
	TTState.return_door = -1
	TTState.level_index = 0
	var scene_before_esc: Node = current_scene
	var game4: Node = game_scene.instantiate()
	root.add_child(game4)
	await physics_frame
	await physics_frame
	var esc := InputEventKey.new()
	esc.pressed = true
	esc.echo = false
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	Input.parse_input_event(esc)
	var esc_done := false
	for f in range(30):
		await process_frame
		if paused == false and current_scene != game4 and _is_map_scene(current_scene):
			esc_done = true
			break
	if not esc_done:
		game4.call("_input", esc)
		for f in range(30):
			await process_frame
			if paused == false and current_scene != game4 and _is_map_scene(current_scene):
				esc_done = true
				break
	_check("esc1: ESC from game unpauses + exits to map", esc_done,
		"paused=" + str(paused))
	var esc_map: Node = current_scene
	_check("esc2: ESC lands on the map scene (chapter door-node count)",
		_is_map_scene(esc_map),
		"current_scene=" + (str(esc_map) if esc_map != null else "null"))
	if esc_map != null and _is_map_scene(esc_map):
		for f in range(5):
			await process_frame
		# RACE FIX (Lane 7b): the ESC scene change is deferred, so the map
		# captured at esc2 may be freed while the 5-frame await above runs.
		# Re-fetch the LIVE scene now and evaluate esc3 in this same frame
		# (no await between re-fetch and _check, so no deferred change can
		# free it mid-check). If the live scene is somehow not a valid map,
		# fail esc3 alone with a clear message instead of a script error
		# aborting the whole run.
		esc_map = current_scene
		if esc_map == null or not is_instance_valid(esc_map) or not _is_map_scene(esc_map):
			_check("esc3: ESC map is PLAIN (picker closed, return_door -1)",
				false,
				"RACE: live map scene unavailable after re-fetch")
		else:
			_check("esc3: ESC map is PLAIN (picker closed, return_door -1)",
				not _picker_visible(esc_map) and _picker_door(esc_map) == 0
				and TTState.return_door == -1,
				"picker_visible=" + str(_picker_visible(esc_map)) + " return_door=" + str(TTState.return_door))
	if is_instance_valid(game4):
		root.remove_child(game4)
		game4.queue_free()
	await process_frame
	await process_frame

	# --- M11 back-to-map button (Skeptic C5a; contract-gated) -----------
	# Mandated M11 interface contract (INTAKE / LANE-M11-BRIEF):
	# hud signal `back_pressed`; accessors `is_back_visible()` and
	# `back_rect()`; back button at (136,16), 48x48, after restart;
	# hidden by set_dead(true); game connects back_pressed to the
	# exit path with the C1 guards (re-entrancy flag on _exit_to_map
	# + win-delay no-op mirroring _on_skip_pressed). M11 IS merged
	# on this tree, so the contract is present and all seven checks
	# EXECUTE. On a tree where the contract is absent they DEFER
	# (listed in _deferred, never claimed as passing). A partial
	# contract (signal present, accessor missing) FAILS the affected
	# check instead of deferring — that is a contract mismatch for
	# the coordinator to fix at merge, not a pass.
	var m11_names: Array[String] = ["m11-0", "m11-1", "m11-2", "m11-3", "m11-4", "m11-5", "m11-6"]
	TTState.return_door = -1
	_write_progress(0, [])
	TTState.level_index = 0
	var scene_before_m11: Node = current_scene
	var game_m0: Node = game_scene.instantiate()
	root.add_child(game_m0)
	await physics_frame
	await physics_frame
	var hud_m0: Node = game_m0.get("hud")
	var m11_present: bool = hud_m0 != null and hud_m0.has_signal("back_pressed") \
		and hud_m0.has_method("is_back_visible") and hud_m0.has_method("back_rect")
	if not m11_present:
		for mn in m11_names:
			_defer(mn + ": M11 back-button check",
				"M11 contract absent in this tree (no back_pressed / is_back_visible / back_rect on HUD) — deferred to coordinator live-tree run after M11 merge")
		if is_instance_valid(game_m0):
			root.remove_child(game_m0)
			game_m0.queue_free()
		await process_frame
		await process_frame
	else:
		var back_btn := _find_icon_button(hud_m0, "back")
		var br_m0: Rect2 = hud_m0.call("back_rect")
		_check("m11-0: back button exists at (136,16) 48x48 and is visible mid-play",
			back_btn != null and bool(hud_m0.call("is_back_visible"))
			and br_m0 == Rect2(136, 16, 48, 48),
			"back_rect=" + str(br_m0))
		# m11-1: click back mid-play -> plain map, picker closed, return_door -1.
		if back_btn != null:
			_click_control(back_btn)
		var m11_map := await _wait_for_map(scene_before_m11)
		_check("m11-1: back mid-play returns to the plain map (picker closed, return_door -1)",
			m11_map != null and not _picker_visible(m11_map) and _picker_door(m11_map) == 0
			and TTState.return_door == -1,
			"map=" + str(m11_map != null) + " return_door=" + str(TTState.return_door))
		# m11-2: click back while paused -> same plain-map exit.
		TTState.return_door = -1
		TTState.level_index = 0
		var scene_before_m2: Node = current_scene
		var game_m2: Node = game_scene.instantiate()
		root.add_child(game_m2)
		await physics_frame
		await physics_frame
		game_m2.call("pause_game")
		await process_frame
		await physics_frame
		var hud_m2: Node = game_m2.get("hud")
		var back_m2 := _find_icon_button(hud_m2, "back") if hud_m2 != null else null
		if back_m2 != null:
			_click_control(back_m2)
		var m2_map := await _wait_for_map(scene_before_m2)
		_check("m11-2: back while paused returns to the plain map (picker closed, return_door -1)",
			m2_map != null and not _picker_visible(m2_map) and _picker_door(m2_map) == 0
			and TTState.return_door == -1 and paused == false,
			"map=" + str(m2_map != null) + " paused=" + str(paused))
		if is_instance_valid(game_m2):
			root.remove_child(game_m2)
			game_m2.queue_free()
		await process_frame
		await process_frame
		# m11-3: click back during the 0.9s win delay -> no-op; the win
		# completes via its own path (picker OPEN for the played door).
		_write_progress(12, _ids_upto(12))
		TTState.level_index = 12
		var scene_before_m3: Node = current_scene
		var game_m3: Node = game_scene.instantiate()
		root.add_child(game_m3)
		await physics_frame
		await physics_frame
		var runtime_m3: Node = game_m3.get("runtime")
		var player_m3: Node2D = game_m3.get("player")
		var door_m3: Node = runtime_m3.get("door") if runtime_m3 != null else null
		var drect_m3 := Rect2()
		if door_m3 != null:
			drect_m3 = door_m3.call("door_rect")
		var won_m3 := false
		if player_m3 != null and runtime_m3 != null and drect_m3.size.x > 0.0:
			var target_m3 := drect_m3.get_center()
			for f in range(60):
				player_m3.global_position = target_m3
				player_m3.set("velocity", Vector2.ZERO)
				await physics_frame
				if bool(runtime_m3.get("level_completed")):
					won_m3 = true
					break
		# Let game._process arm the win delay, then tap back inside it.
		await physics_frame
		await physics_frame
		var hud_m3: Node = game_m3.get("hud")
		var back_m3 := _find_icon_button(hud_m3, "back") if hud_m3 != null else null
		var delay_armed: bool = won_m3 and game_m3 != null and float(game_m3.get("_win_delay")) >= 0.0
		if back_m3 != null:
			_click_control(back_m3)
		var m3_map := await _wait_for_map(scene_before_m3)
		if m3_map != null:
			for f in range(5):
				await process_frame
		_check("m11-3: back during the win delay is a no-op — win completes to door 3's picker",
			delay_armed and m3_map != null and _picker_visible(m3_map) and _picker_door(m3_map) == 3
			and TTState.level_index == 12,
			"won=" + str(won_m3) + " delay_armed=" + str(delay_armed)
			+ " picker_door=" + (str(_picker_door(m3_map)) if m3_map != null else "?"))
		if is_instance_valid(game_m3):
			root.remove_child(game_m3)
			game_m3.queue_free()
		await process_frame
		await process_frame
		# m11-4: double-tap back -> single exit, no error (plain map).
		TTState.return_door = -1
		TTState.level_index = 0
		var scene_before_m4: Node = current_scene
		var game_m4: Node = game_scene.instantiate()
		root.add_child(game_m4)
		await physics_frame
		await physics_frame
		var hud_m4: Node = game_m4.get("hud")
		var back_m4 := _find_icon_button(hud_m4, "back") if hud_m4 != null else null
		if back_m4 != null:
			_click_control(back_m4)
			_click_control(back_m4)
		var m4_map := await _wait_for_map(scene_before_m4)
		_check("m11-4: double-tap back exits once to the plain map (picker closed, return_door -1)",
			m4_map != null and not _picker_visible(m4_map) and _picker_door(m4_map) == 0
			and TTState.return_door == -1 and paused == false,
			"map=" + str(m4_map != null) + " return_door=" + str(TTState.return_door))
		if is_instance_valid(game_m4):
			root.remove_child(game_m4)
			game_m4.queue_free()
		await process_frame
		await process_frame
		# m11-5: back hidden in death state.
		TTState.level_index = 0
		var game_m5: Node = game_scene.instantiate()
		root.add_child(game_m5)
		await physics_frame
		await physics_frame
		var hud_m5: Node = game_m5.get("hud")
		var back_m5 := _find_icon_button(hud_m5, "back") if hud_m5 != null else null
		if hud_m5 != null:
			hud_m5.call("set_dead", true)
		_check("m11-5: back hidden in death state (is_back_visible() == false after set_dead(true))",
			hud_m5 != null and not bool(hud_m5.call("is_back_visible"))
			and (back_m5 == null or not back_m5.visible),
			"is_back_visible=" + (str(hud_m5.call("is_back_visible")) if hud_m5 != null else "?"))
		if hud_m5 != null:
			hud_m5.call("set_dead", false)
		if is_instance_valid(game_m5):
			root.remove_child(game_m5)
			game_m5.queue_free()
		await process_frame
		await process_frame
		# m11-6 (C5b): back from a BONUS level -> plain map, return_door -1.
		TTState.return_door = -1
		TTState.bonus = true
		TTState.level_index = 0
		var scene_before_m6: Node = current_scene
		var game_m6: Node = game_scene.instantiate()
		root.add_child(game_m6)
		await physics_frame
		await physics_frame
		var hud_m6: Node = game_m6.get("hud")
		var back_m6 := _find_icon_button(hud_m6, "back") if hud_m6 != null else null
		if back_m6 != null:
			_click_control(back_m6)
		var m6_map := await _wait_for_map(scene_before_m6)
		_check("m11-6: back from a bonus level returns to the plain map (picker closed, return_door -1)",
			m6_map != null and not _picker_visible(m6_map) and _picker_door(m6_map) == 0
			and TTState.return_door == -1,
			"map=" + str(m6_map != null) + " return_door=" + str(TTState.return_door))
		TTState.bonus = false
		TTState.return_door = -1
		if is_instance_valid(game_m6):
			root.remove_child(game_m6)
			game_m6.queue_free()
		await process_frame
		await process_frame

	# --- highest=214 fixture: door 44 done, 1 stage -----------------------
	_write_progress(214, _ids_upto(215))
	map_inst = map_scene.instantiate()
	root.add_child(map_inst)
	await process_frame
	await process_frame
	await physics_frame
	await process_frame
	await process_frame
	_check("end1: highest=214 fixture -> highest 214",
		int(map_inst.get("_highest")) == 214,
		"highest=" + str(map_inst.get("_highest")))
	nodes = _door_nodes(map_inst)
	var end_ok := nodes.size() == 14
	var end_done_ok := nodes.size() == 14
	for n in nodes:
		var d3: int = int(n.get("door"))
		if bool(n.get("locked")):
			end_ok = false
		if bool(n.get("current")) != (d3 == 44):
			end_ok = false
		if bool(n.get("done")) != true:
			end_done_ok = false
	_check("end2: highest=214 -> all 14 Ch.3 doors unlocked, door 44 current", end_ok)
	_check("end3: highest=214 + all ids completed -> every door done", end_done_ok)
	map_inst.call("open_picker", 44)
	await process_frame
	_check("end4: door 44 picker title 'DOOR 44' + subtitle 'FINAL-MEGA'",
		_picker_title(map_inst) == "DOOR 44" and _picker_subtitle(map_inst) == "FINAL-MEGA",
		"title=" + _picker_title(map_inst) + " subtitle=" + _picker_subtitle(map_inst))
	stages = _stage_buttons(map_inst)
	_check("end5: door 44 picker has exactly 1 stage button", stages.size() == 1,
		"stages=" + str(stages.size()))
	var d44_ok := stages.size() == 1
	if stages.size() == 1:
		d44_ok = int(stages[0].get("level")) == 214 and not bool(stages[0].get("locked")) \
			and bool(stages[0].get("done"))
	_check("end6: door 44 stage is level 215, unlocked + done", d44_ok)
	root.remove_child(map_inst)
	map_inst.queue_free()
	await process_frame
	await process_frame

	# --- inconsistent fixture: completed-without-highest -------------------
	# highest=0 but L001 + L006-L010 completed: door 2's stages are all
	# complete yet the door must stay LOCKED (unlock derives from
	# highest_unlocked, never from completed).
	var inconsistent: Array = ["L001", "L006", "L007", "L008", "L009", "L010"]
	_write_progress(0, inconsistent)
	map_inst = map_scene.instantiate()
	root.add_child(map_inst)
	await process_frame
	await process_frame
	await physics_frame
	await process_frame
	await process_frame
	nodes = _door_nodes(map_inst)
	var inc_ok := nodes.size() == 16
	if nodes.size() == 16:
		inc_ok = bool(nodes[1].get("locked")) and not bool(nodes[0].get("done")) \
			and bool(nodes[1].get("done"))
	_check("inc1: inconsistent fixture -> door 2 locked despite all its stages completed; door 1 not done",
		inc_ok,
		"door1 done=" + (str(nodes[0].get("done")) if nodes.size() == 16 else "?")
		+ " door2 locked=" + (str(nodes[1].get("locked")) if nodes.size() == 16 else "?")
		+ " door2 done=" + (str(nodes[1].get("done")) if nodes.size() == 16 else "?"))
	map_inst.call("open_picker", 2)
	await process_frame
	_check("inc2: open_picker(2) on the locked door is a no-op despite completed stages",
		not _picker_visible(map_inst) and _picker_door(map_inst) == 0)
	map_inst.call("open_picker", 1)
	await process_frame
	stages = _stage_buttons(map_inst)
	var inc_stage_ok := stages.size() == 5
	if stages.size() == 5:
		# highest 0: stage 1 (idx 0) done + unlocked; stage 2 (idx 1)
		# is LOCKED (idx 1 > highest 0) and not done.
		inc_stage_ok = bool(stages[0].get("done")) and not bool(stages[0].get("locked")) \
			and bool(stages[1].get("locked")) and not bool(stages[1].get("done"))
	_check("inc3: door 1 picker -> stage 1 done+unlocked, stage 2 locked+not done",
		inc_stage_ok)
	root.remove_child(map_inst)
	map_inst.queue_free()
	await process_frame
	await process_frame

	# --- chapter views: per-chapter counts + sum == 44 -----------------
	# Fresh fixture (highest 0) opens on Ch.1 by map.gd:893
	# (_chapter = chapter_of_door(door_of(_highest))). Switch with
	# _apply_chapter (probe-safe, in-place) and assert each view's
	# exact door range + bonus presence (bonus node: Ch.3 only).
	_write_progress(0, [])
	var cmap: Node = map_scene.instantiate()
	root.add_child(cmap)
	await process_frame
	await process_frame
	await physics_frame
	await process_frame
	await process_frame
	var ch1_nodes := _door_nodes(cmap)
	var ch1_doors: Array = []
	for n in ch1_nodes:
		ch1_doors.append(int(n.get("door")))
	_check("chap1: Ch.1 view (highest 0) has 16 door nodes, doors 1..16, 0 bonus nodes",
		int(cmap.get("_chapter")) == 1 and ch1_nodes.size() == 16
		and ch1_doors == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
		and _bonus_nodes(cmap).size() == 0,
		"chapter=" + str(cmap.get("_chapter")) + " nodes=" + str(ch1_nodes.size())
		+ " bonus=" + str(_bonus_nodes(cmap).size()))
	await _switch_chapter(cmap, 2)
	var ch2_nodes := _door_nodes(cmap)
	var ch2_doors: Array = []
	for n in ch2_nodes:
		ch2_doors.append(int(n.get("door")))
	_check("chap2: Ch.2 view has 14 door nodes, doors 17..30, 0 bonus nodes",
		int(cmap.get("_chapter")) == 2 and ch2_nodes.size() == 14
		and ch2_doors == [17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30]
		and _bonus_nodes(cmap).size() == 0,
		"chapter=" + str(cmap.get("_chapter")) + " nodes=" + str(ch2_nodes.size())
		+ " bonus=" + str(_bonus_nodes(cmap).size()))
	await _switch_chapter(cmap, 3)
	var ch3_nodes := _door_nodes(cmap)
	var ch3_doors: Array = []
	for n in ch3_nodes:
		ch3_doors.append(int(n.get("door")))
	_check("chap3: Ch.3 view has 14 door nodes, doors 31..44, 1 bonus node",
		int(cmap.get("_chapter")) == 3 and ch3_nodes.size() == 14
		and ch3_doors == [31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44]
		and _bonus_nodes(cmap).size() == 1,
		"chapter=" + str(cmap.get("_chapter")) + " nodes=" + str(ch3_nodes.size())
		+ " bonus=" + str(_bonus_nodes(cmap).size()))
	_check("chap4: door nodes summed across Ch.1+Ch.2+Ch.3 == 44",
		ch1_nodes.size() + ch2_nodes.size() + ch3_nodes.size() == 44,
		"sum=" + str(ch1_nodes.size() + ch2_nodes.size() + ch3_nodes.size()))
	var tabs: Array = cmap.get("_chapter_tabs")
	var tab_ok := tabs.size() == 3
	var tab_sel := false
	for entry in tabs:
		if int(entry["chapter"]) == int(cmap.get("_chapter")):
			tab_sel = true
	_check("chap5: chapter tabs exist (3) and the selected tab follows the viewed chapter",
		tab_ok and tab_sel, "tabs=" + str(tabs.size()) + " chapter=" + str(cmap.get("_chapter")))
	root.remove_child(cmap)
	cmap.queue_free()
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
	TTState.return_door = -1
	_write_progress(0, [])
	_finish()


func _finish() -> void:
	print("V5 SUMMARY: ", _passes.size(), " passed, ", _fails.size(), " failed, ", _deferred.size(), " deferred (not executed)")
	if not _deferred.is_empty():
		print("V5 DEFERRED (contract absent — run on merged tree, never claimed passing): ", ", ".join(_deferred))
	print("V5 NOT VERIFIED HEADLESS: rendered legibility, finger feel, F9 latency, audible audio, non-16:9 letterbox; glow/marker asserted via DoorNode.current flag only.")
	if not _fails.is_empty():
		print("V5 FAILED: ", ", ".join(_fails))
		quit(1)
		return
	print("V5 ALL PASS")
	quit(0)
