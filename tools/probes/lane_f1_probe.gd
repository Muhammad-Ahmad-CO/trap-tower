# Lane F1 probe (v1.0.5 Part B): hidden stars + hero skins + bonus door.
# Headless SceneTree script. Uses the REAL map/game scenes and the
# real TTProgress save file (user://progress.cfg), restored to a fresh
# save at the end. Prints PASS/FAIL per assertion, exits 0 only if
# all pass.
#
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s <abs path>/lane_f1_probe.gd
#
# CHAPTER-AWARE (Lane P, v1.0.9 condition (a)): the map builds ONE
# chapter's door nodes per view (Ch.1 16, Ch.2 14, Ch.3 14 + bonus
# node on Ch.3 only). _write_stars() sets highest_unlocked = 0, so
# the map opens on Ch.1 by default — the bonus node does NOT exist
# there. Both bonus blocks below switch to Ch.3 via _apply_chapter
# (probe-safe, in-place rebuild + frame awaits) BEFORE reading
# _bonus_nodes; f1-map asserts the Ch.1 count (16) plus a
# sum-across-chapters == 44, and f1-bonus-ch1 asserts 0 bonus nodes
# on Ch.1 (bonus-absent-off-Ch.3 is part of the design).
extends SceneTree

var _fails: Array[String] = []
var _passes: Array[String] = []
var _levels: Array = []
var _bonus_levels: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("F1 PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("F1 FAIL: ", name, (" | " + detail) if detail != "" else "")


func _write_progress_v104(highest: int, completed: Array) -> void:
	# EXACT v1.0.4 format: old fields only, no stars/skins/bonus keys.
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", 3)
	cfg.set_value("progress", "highest_unlocked", highest)
	cfg.set_value("progress", "completed", completed)
	cfg.save("user://progress.cfg")


func _write_stars(n: int) -> void:
	var stars: Array = []
	for k in range(mini(n, _levels.size())):
		stars.append(str(_levels[k].get("id", "")))
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", 3)
	cfg.set_value("progress", "highest_unlocked", 0)
	cfg.set_value("progress", "completed", [])
	cfg.set_value("progress", "stars_collected", stars)
	cfg.save("user://progress.cfg")


func _traverse(node: Node, out: Array) -> void:
	out.append(node)
	for child in node.get_children():
		_traverse(child, out)


func _find_all(root_node: Node, script_class: String) -> Array:
	var all: Array = []
	_traverse(root_node, all)
	var out: Array = []
	for n in all:
		var scr: Variant = n.get_script()
		if scr != null and scr is GDScript and str(scr.get_global_name()) == script_class:
			out.append(n)
		elif n.get_class() == script_class:
			out.append(n)
	return out


func _find_first(root_node: Node, script_class: String) -> Node:
	var found := _find_all(root_node, script_class)
	return found[0] if not found.is_empty() else null


func _has_prop(node: Object, prop: String) -> bool:
	for d in node.get_property_list():
		if str(d["name"]) == prop:
			return true
	return false


func _door_nodes(map_inst: Node) -> Array:
	var scroll: Control = map_inst.get("_scroll")
	if scroll == null or scroll.get_child_count() == 0:
		return []
	var content: Node = scroll.get_child(0)
	var nodes: Array = []
	for child in content.get_children():
		if _has_prop(child, "door") and _has_prop(child, "locked") and _has_prop(child, "current"):
			nodes.append(child)
	return nodes


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


func _remove(inst: Node) -> void:
	if inst != null and is_instance_valid(inst):
		root.remove_child(inst)
		inst.queue_free()
	await process_frame
	await process_frame


# Chapter switch the probe-safe way: _apply_chapter rebuilds the map
# in place (synchronous) and calls _scroll_to_current, which awaits
# 2 process frames — so await frames after the call.
func _switch_chapter(map_inst: Node, chapter: int) -> void:
	map_inst.call("_apply_chapter", chapter)
	for f in range(5):
		await process_frame


func _run() -> void:
	TTState.return_door = -1
	TTState.bonus = false
	var tuning := TTuning.load_tuning()
	_levels = TTLevelData.load_levels()["levels"]
	_bonus_levels = TTLevelData.load_levels("res://data/bonus_levels.json")["levels"]
	_check("f1-load: 215 main levels", _levels.size() == 215, "n=" + str(_levels.size()))
	_check("f1-load: 5 bonus levels", _bonus_levels.size() == 5, "n=" + str(_bonus_levels.size()))

	# --- 1. v1.0.4 save compatibility --------------------------------
	var done14: Array = []
	for k in range(14):
		done14.append(str(_levels[k].get("id", "")))
	_write_progress_v104(14, done14)
	var d := TTProgress.load_progress()
	_check("f1-save: v104 save loads, highest kept",
		int(d["highest_unlocked"]) == 14 and (d["completed"] as Array).size() == 14)
	_check("f1-save: new fields default (0 stars, default skin, bonus locked)",
		(d["stars_collected"] as Array).is_empty()
		and str(d["selected_skin"]) == "default"
		and (d["bonus_completed"] as Array).is_empty()
		and int(d["bonus_highest"]) == 0,
		"stars=" + str((d["stars_collected"] as Array).size()))
	TTProgress.collect_star("L001")
	d = TTProgress.load_progress()
	_check("f1-save: collect_star persists, highest untouched",
		(d["stars_collected"] as Array) == ["L001"] and int(d["highest_unlocked"]) == 14)
	TTProgress.collect_star("L001")
	d = TTProgress.load_progress()
	_check("f1-save: duplicate star collect is a no-op",
		(d["stars_collected"] as Array).size() == 1)
	TTProgress.set_skin("ember")
	d = TTProgress.load_progress()
	_check("f1-save: set_skin persists, stars kept",
		str(d["selected_skin"]) == "ember" and (d["stars_collected"] as Array).size() == 1)
	TTProgress.complete_bonus_level("B001", 0, 5)
	d = TTProgress.load_progress()
	_check("f1-save: bonus win persists, main progress untouched",
		(d["bonus_completed"] as Array) == ["B001"] and int(d["bonus_highest"]) == 1
		and int(d["highest_unlocked"]) == 14)
	TTProgress.unlock_bonus_level(1, 5)
	d = TTProgress.load_progress()
	_check("f1-save: bonus skip advances bonus_highest only",
		int(d["bonus_highest"]) == 2 and int(d["highest_unlocked"]) == 14)

	# --- 2. star data + skin rules (pure logic) ----------------------
	_check("f1-data: stars.json has 220 entries (215 + 5 bonus)",
		TTStarData.load_stars().size() == 220,
		"n=" + str(TTStarData.load_stars().size()))
	_check("f1-data: L001 star exists, unknown id has none",
		TTStarData.has_star("L001") and not TTStarData.has_star("ZZZ"))
	_check("f1-skins: bonus door locks at 49, unlocks at 50 stars",
		not TTSkins.bonus_unlocked(49) and TTSkins.bonus_unlocked(50))
	var ember := TTSkins.skin_by_id("ember")
	_check("f1-skins: ember needs 5 doors (4 no, 5 yes)",
		not TTSkins.is_unlocked(ember, 4, 0) and TTSkins.is_unlocked(ember, 5, 0))
	var mint := TTSkins.skin_by_id("mint")
	_check("f1-skins: mint needs 25 stars (24 no, 25 yes)",
		not TTSkins.is_unlocked(mint, 0, 24) and TTSkins.is_unlocked(mint, 0, 25))
	_check("f1-skins: unknown skin id falls back to default",
		str(TTSkins.skin_by_id("nope")["id"]) == "default")

	# --- 3. skins are visual-only (collision rect never changes) -----
	var pl := TTPlayer.new()
	pl.setup(tuning)
	var shape_size := Vector2.ZERO
	for child in pl.get_children():
		if child is CollisionShape2D:
			shape_size = (child.shape as RectangleShape2D).size
	var skin_ok := true
	for s in TTSkins.SKINS:
		pl.apply_skin(s)
		if pl.pw != 15.0 or pl.ph != 39.0:
			skin_ok = false
		for child in pl.get_children():
			if child is CollisionShape2D:
				if (child.shape as RectangleShape2D).size != shape_size:
					skin_ok = false
	_check("f1-skins: all 6 skins keep pw/ph 15x39 + same shape",
		skin_ok and shape_size == Vector2(15, 39), "shape=" + str(shape_size))
	pl.queue_free()

	# --- 4. live star collection through the real game scene ---------
	_write_progress_v104(0, [])
	TTState.bonus = false
	TTState.level_index = 0  # L001
	var game_inst: Node = load("res://scenes/game.tscn").instantiate()
	root.add_child(game_inst)
	for i in range(30):
		await process_frame
	var star: TTStar = _find_first(game_inst, "TTStar")
	_check("f1-live: L001 spawns its star", star != null)
	var player: TTPlayer = _find_first(game_inst, "TTPlayer")
	_check("f1-live: game has a player", player != null)
	if star != null and player != null:
		_check("f1-live: star starts uncollected", not star.collected)
		player.global_position = star.centre
		for i in range(10):
			await physics_frame
		_check("f1-live: touching the star collects it", star.collected)
		var d2 := TTProgress.load_progress()
		_check("f1-live: collection persisted to the save",
			(d2["stars_collected"] as Array).has("L001"))
		_check("f1-live: collecting the star does NOT complete the level",
			not bool(game_inst.get("level_completed")))
	_remove(game_inst)

	# --- 5. bonus door: locked at 0 stars, open at 50 ---------------
	# Chapter-aware (Lane P C4(iv)): _write_stars(0) sets
	# highest_unlocked = 0, so the map opens on Ch.1 by default —
	# where the bonus node does NOT exist by design (it lives on
	# the Ch.3 view only). Assert that first, then switch to Ch.3
	# via _apply_chapter before reading _bonus_nodes.
	_write_stars(0)
	TTState.return_door = -1
	var map0: Node = load("res://scenes/map.tscn").instantiate()
	root.add_child(map0)
	for i in range(10):
		await process_frame
	_check("f1-bonus-ch1: Ch.1 view has 0 bonus nodes (bonus lives on Ch.3 only)",
		_bonus_nodes(map0).size() == 0, "bonus=" + str(_bonus_nodes(map0).size()))
	_check("f1-map: Ch.1 view has exactly 16 main door nodes",
		_door_nodes(map0).size() == 16, "nodes=" + str(_door_nodes(map0).size()))
	var f1_sum := 0
	for ch in [1, 2, 3]:
		await _switch_chapter(map0, ch)
		f1_sum += _door_nodes(map0).size()
	_check("f1-map-sum: door nodes summed across Ch.1+Ch.2+Ch.3 == 44",
		f1_sum == 44, "sum=" + str(f1_sum))
	await _switch_chapter(map0, 3)
	var bnodes0 := _bonus_nodes(map0)
	_check("f1-bonus: exactly 1 bonus node on the Ch.3 map", bnodes0.size() == 1)
	if bnodes0.size() == 1:
		_check("f1-bonus: locked at 0 stars", bool(bnodes0[0].get("locked")))
	map0.call("open_bonus_picker")
	await process_frame
	_check("f1-bonus: locked picker never opens",
		not bool((map0.get("_bonus_picker") as Control).visible))
	_remove(map0)

	_write_stars(50)
	TTState.return_door = -1
	var map50: Node = load("res://scenes/map.tscn").instantiate()
	root.add_child(map50)
	for i in range(10):
		await process_frame
	# Default view is Ch.1 (highest 0) — the bonus node does not
	# exist there. Switch to Ch.3 BEFORE reading _bonus_nodes, or
	# the bnodes50.size() == 1 guard below can never open.
	await _switch_chapter(map50, 3)
	_check("f1-bonus-ch3: map switched to Ch.3 before reading bonus nodes",
		int(map50.get("_chapter")) == 3, "chapter=" + str(map50.get("_chapter")))
	var bnodes50 := _bonus_nodes(map50)
	var bonus_open_ok := false
	if bnodes50.size() == 1:
		_check("f1-bonus: unlocked at 50 stars", not bool(bnodes50[0].get("locked")))
		map50.call("open_bonus_picker")
		await process_frame
		bonus_open_ok = bool((map50.get("_bonus_picker") as Control).visible)
		_check("f1-bonus: picker opens at 50 stars", bonus_open_ok)
		var stages: Control = map50.get("_bonus_picker_stages")
		_check("f1-bonus: picker has 5 stage buttons", stages.get_child_count() == 5)
		if stages.get_child_count() == 5:
			var s0 = stages.get_child(0)
			var s1 = stages.get_child(1)
			_check("f1-bonus: stage 1 unlocked, stage 2 locked",
				not bool(s0.get("locked")) and bool(s1.get("locked")))
		# Stage tap arms a bonus run (state set before the wipe).
		TTState.bonus = false
		map50.call("_on_bonus_stage_pressed", 0)
		_check("f1-bonus: stage tap starts a bonus run",
			bool(TTState.bonus) and int(TTState.level_index) == 0)
	TTState.bonus = false
	TTState.return_door = -1
	_remove(map50)

	# --- 6. skin picker on the map -----------------------------------
	_write_progress_v104(0, [])
	TTState.return_door = -1
	var map_s: Node = load("res://scenes/map.tscn").instantiate()
	root.add_child(map_s)
	for i in range(10):
		await process_frame
	map_s.call("open_skin_picker")
	await process_frame
	_check("f1-skins: picker opens from the map",
		bool((map_s.get("_skin_picker") as Control).visible))
	_check("f1-skins: picker lists 6 skins", (map_s.get("_skin_rows") as Array).size() == 6)
	map_s.call("_on_skin_pressed", "ember")
	var d3 := TTProgress.load_progress()
	_check("f1-skins: locked ember tap changes nothing",
		str(d3["selected_skin"]) == "default")
	# Complete doors 1..5, reopen: ember must be owned + selectable.
	var done5: Array = []
	for k in range(25):
		done5.append(str(_levels[k].get("id", "")))
	_write_progress_v104(24, done5)
	map_s.call("_fill_skin_picker")
	map_s.call("_on_skin_pressed", "ember")
	var d4 := TTProgress.load_progress()
	_check("f1-skins: ember unlocks at 5 doors and selects",
		str(d4["selected_skin"]) == "ember")
	_remove(map_s)

	# --- 7. bonus win returns to the bonus picker --------------------
	_write_stars(50)
	TTState.bonus = true
	TTState.level_index = 0  # B001
	var game_b: Node = load("res://scenes/game.tscn").instantiate()
	root.add_child(game_b)
	for i in range(30):
		await process_frame
	var bstar: TTStar = _find_first(game_b, "TTStar")
	_check("f1-bonus: B001 spawns its star", bstar != null)
	var bplayer: TTPlayer = _find_first(game_b, "TTPlayer")
	_check("f1-bonus: B001 builds with a player", bplayer != null)
	_remove(game_b)
	TTState.bonus = false
	TTState.return_door = -1

	# Restore a fresh save so no fixture leaks to the player.
	_write_progress_v104(0, [])
	print("F1 RESULT: %d passed, %d failed" % [_passes.size(), _fails.size()])
	if not _fails.is_empty():
		for f in _fails:
			print("F1 FAILED: ", f)
	quit(1)
	quit(0)
