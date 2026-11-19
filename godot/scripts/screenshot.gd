extends Node

# Screenshot capture ONLY: renders REAL frames through the real
# map/game scenes and real UI paths (settings, pause, death,
# skip). Never draws mockups. No gameplay code is touched.
# Run under Xvfb with a real rendering driver (NOT --headless):
#   xvfb-run -a <godot> --path <project> res://scenes/screenshot.tscn -- \
#     --shot-levels L001,L006,L011 --shot-out <dir>
# Defaults: the explicit flat list in _default_level_ids() (first
# level of each archetype group + extras + dark-palette halo shots);
# out dir $HOME/workspace/trap-tower/verification/shots. Always captures:
# map.png (fresh progress), map_progress.png (mid-progress fixture),
# map_scrolled.png (same mid-progress map, scrolled to max),
# settings.png (settings via open_settings), pause.png (pause overlay
# via the real pause path), death.png (REAL hazard death, captured
# inside the dead state), skip.png (3 REAL deaths, then Skip visible),
# level_<ID>.png for each selected level, plus phase-2 pairs
# (level_<ID>_phase2.png at 2.6s vs the 1.0s shot) for L098, L036,
# L056 and L031, each gated on a pixel diff > 0 (a 0-diff pair is
# INVALID — it proves no second trap phase, the v2 L001 lesson).
# There is NO picker in v3: no picker.png is captured.
# Progress fixtures are written to user://progress.cfg (save_version 3)
# before map captures; a FRESH empty progress is restored at the end.

var _out_dir := ""
var _level_ids: Array[String] = []
var _levels: Array = []
var _phase_gate_failed := false


func _ready() -> void:
	_run()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var levels_arg := ""
	var out_arg := ""
	var i := 0
	while i < args.size():
		if args[i] == "--shot-levels" and i + 1 < args.size():
			levels_arg = args[i + 1]
			i += 2
		elif args[i] == "--shot-out" and i + 1 < args.size():
			out_arg = args[i + 1]
			i += 2
		else:
			i += 1
	if out_arg == "":
		_out_dir = OS.get_environment("HOME") + "/workspace/trap-tower/verification/shots"
	else:
		_out_dir = out_arg
	var derr := DirAccess.make_dir_recursive_absolute(_out_dir)
	if derr != OK:
		print("SHOT ERROR: cannot create out dir ", _out_dir, " err=", derr)
		get_tree().quit(1)
		return

	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("SHOT ERROR: ", str(loaded["error"]))
		get_tree().quit(1)
		return
	_levels = loaded["levels"]
	var index_by_id := {}
	for idx in range(_levels.size()):
		index_by_id[str(_levels[idx].get("id", ""))] = idx
	if levels_arg == "":
		_level_ids = _default_level_ids()
	else:
		for part in levels_arg.split(","):
			var id := part.strip_edges()
			if id != "":
				_level_ids.append(id)
	for id in _level_ids:
		if not index_by_id.has(id):
			print("SHOT ERROR: unknown level id ", id)
			get_tree().quit(1)
			return
	print("SHOT viewport=", get_viewport().get_visible_rect().size, " out=", _out_dir, " levels=", _level_ids)

	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var game_scene: PackedScene = load("res://scenes/game.tscn")

	# Map, fresh progress.
	_write_progress(0, [])
	var map_inst: Node = map_scene.instantiate()
	add_child(map_inst)
	await _settle_and_capture(_out_dir + "/map.png", 0.5)
	await _remove(map_inst)

	# Map, mid-progress fixture (completed ids consistent with
	# highest: ids up to `mid`, not a mismatched count) + scrolled
	# map + settings on one instance. No picker exists in v3.
	var mid := _levels.size() / 2
	var done_ids: Array[String] = []
	for k in range(mini(mid, _levels.size())):
		done_ids.append(str(_levels[k].get("id", "")))
	_write_progress(mid, done_ids)
	map_inst = map_scene.instantiate()
	add_child(map_inst)
	await _settle_and_capture(_out_dir + "/map_progress.png", 0.6)
	var scroll: ScrollContainer = map_inst.get("_scroll")
	if scroll != null:
		scroll.scroll_vertical = 100000.0
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
	await _capture_now(_out_dir + "/map_scrolled.png")
	map_inst.call("open_settings")
	await _capture_now(_out_dir + "/settings.png")
	map_inst.call("close_settings")
	await _remove(map_inst)

	# Game states: pause, death, skip — one instance, real paths.
	var death_idx := _find_death_level()
	if death_idx < 0:
		print("SHOT ERROR: no level with a directly lethal hazard found")
		get_tree().quit(1)
		return
	TTState.level_index = death_idx
	var game_inst: Node = game_scene.instantiate()
	add_child(game_inst)
	await _settle(0.6)
	game_inst.call("pause_game")
	await _capture_now(_out_dir + "/pause.png")
	game_inst.call("resume_game")
	await _settle(0.2)
	if not await _kill_player(game_inst):
		print("SHOT ERROR: could not force a real hazard death")
		get_tree().quit(1)
		return
	await _capture_now(_out_dir + "/death.png")
	await _wait_retry(game_inst)
	for k in range(2):
		if not await _kill_player(game_inst):
			print("SHOT ERROR: could not force death ", k + 2, " for skip shot")
			get_tree().quit(1)
			return
		await _wait_retry(game_inst)
	await _settle(0.3)
	var hud: Node = game_inst.get("hud")
	print("SHOT skip visible=", hud.call("is_skip_visible"), " deaths=", game_inst.get("deaths"))
	await _capture_now(_out_dir + "/skip.png")
	await _remove(game_inst)

	# Level shots, one instance each.
	for id in _level_ids:
		TTState.level_index = int(index_by_id[id])
		game_inst = game_scene.instantiate()
		add_child(game_inst)
		await _settle_and_capture(_out_dir + "/level_" + id + ".png", 1.0)
		await _remove(game_inst)

	# Phase-2 pairs (Loop 4, derived from the NEW assembly mapping +
	# runtime timing code; one per timed archetype). First capture
	# 1.0s; second capture at the per-pair time below. A 0-diff pair
	# is INVALID.
	# L056 D12S2V1 dashed (installed v3 set; the old D12S1V1 periods
	# 3.2/3.0 in this comment were STALE — the installed periods are
	# 2.8/2.6, under which 3.3s is solid again, so the pair was
	# pixel-identical): A period 2.8 phase 0 on 2.0, B period 2.6
	# phase 0.5 on 1.8. At 1.0s both ON (dark); at 2.5s both OFF
	# (fposmod(2.5,2.8)=2.5>=2.0; fposmod(2.0,2.6)=2.0>=1.8).
	# L031 D07S2V1 periodic pillar (installed v3 set; old cycle-3.5
	# math was STALE — installed period is 3.6, so 4.5s lands back at
	# home): drop_dist 486, drop_speed 600 -> drop_time 0.81,
	# hang_time 1.79. At 1.0s home (offset 0); at 2.5s dropping,
	# offset 600*(2.5-1.79)=426px.
	# L071 D15S1V1 mover: sine f=0.933 at 1.0s vs 0.067 at 2.6s
	#   (period 2.4, dx 70 -> ~61px apart).
	# L036 D08S1V1 swing saw: angle +5.77deg at 1.0s vs -5.97deg at
	#   2.6s (arc 12deg, period 3.4).
	var phase_pairs: Array = [["L056", 2.5], ["L031", 2.5], ["L071", 2.6], ["L036", 2.6]]
	for pair in phase_pairs:
		var pair_id: String = pair[0]
		var pair_t2: float = pair[1]
		if not index_by_id.has(pair_id):
			print("SHOT PHASEDIFF ERROR: unknown level id ", pair_id)
			_phase_gate_failed = true
			continue
		TTState.level_index = int(index_by_id[pair_id])
		game_inst = game_scene.instantiate()
		add_child(game_inst)
		await _settle_and_capture(_out_dir + "/level_" + pair_id + ".png", 1.0)
		await _remove(game_inst)
		TTState.level_index = int(index_by_id[pair_id])
		game_inst = game_scene.instantiate()
		add_child(game_inst)
		await _settle_and_capture(_out_dir + "/level_" + pair_id + "_phase2.png", pair_t2)
		await _remove(game_inst)
		var diff := _pixel_diff(_out_dir + "/level_" + pair_id + ".png",
			_out_dir + "/level_" + pair_id + "_phase2.png")
		print("SHOT PHASEDIFF ", pair_id, " diff_pixels=", diff)
		if diff <= 0:
			_phase_gate_failed = true
			print("SHOT PHASEDIFF INVALID: ", pair_id, " pair is pixel-identical (no second trap phase proven)")

	# Restore a FRESH empty progress at the end.
	_write_progress(0, [])
	if _phase_gate_failed:
		print("SHOT PHASEDIFF GATE FAILED: at least one phase pair is invalid; captures are saved, fresh progress restored")
		get_tree().quit(1)
		return
	print("SHOT DONE")
	get_tree().quit(0)


func _default_level_ids() -> Array[String]:
	# EXPLICIT flat list (v3, no doors): first level of each
	# archetype group (5-level groups, first = index 0,5,10,...),
	# PLUS extras L003, L008, L013, PLUS dark-palette halo shots
	# L061, L101, L151, L176, L201 (several already in the flat
	# list; duplicates removed, order kept).
	var explicit: Array[String] = ["L001", "L006", "L011", "L016", "L021",
		"L026", "L031", "L036", "L041", "L046", "L051", "L056", "L061",
		"L066", "L071", "L076", "L081", "L086", "L091", "L096", "L101",
		"L106", "L111", "L116", "L121", "L126", "L131", "L136", "L141",
		"L146", "L151", "L156", "L161", "L166", "L171", "L176", "L181",
		"L186", "L191", "L196", "L201", "L206", "L211",
		"L003", "L008", "L013",
		"L061", "L101", "L151", "L176", "L201"]
	var ids: Array[String] = []
	for id in explicit:
		if not ids.has(id):
			ids.append(id)
	return ids


func _pixel_diff(path_a: String, path_b: String) -> int:
	var a := Image.load_from_file(path_a)
	var b := Image.load_from_file(path_b)
	if a == null or b == null:
		print("SHOT PHASEDIFF ERROR: could not load pair images")
		return -1
	if a.get_size() != b.get_size():
		print("SHOT PHASEDIFF ERROR: pair image sizes differ")
		return -1
	if a.get_format() != b.get_format():
		a.convert(Image.FORMAT_RGBA8)
		b.convert(Image.FORMAT_RGBA8)
	var da := a.get_data()
	var db := b.get_data()
	if da.size() != db.size():
		return -1
	var diff := 0
	var px := 0
	while px < da.size():
		if da[px] != db[px] or da[px + 1] != db[px + 1] or da[px + 2] != db[px + 2] or da[px + 3] != db[px + 3]:
			diff += 1
		px += 4
	return diff


func _find_death_level() -> int:
	# Prefer a level with a directly lethal hazard: static spikes, a
	# saw, or a spiked column. Hanging pillars (lethal only once
	# dropped) and dotted lines (never lethal) are skipped.
	for pass_no in range(2):
		for idx in range(_levels.size()):
			for h in (_levels[idx] as Dictionary).get("hazards", []):
				var htype := str((h as Dictionary).get("type", ""))
				if htype == "saw" or htype == "spiked_column":
					return idx
				if htype == "spikes" and (pass_no == 1 or not (h as Dictionary).has("period")):
					return idx
	return -1


func _pick_death_target(game_inst: Node) -> Vector2:
	var runtime: Node = game_inst.get("runtime")
	if runtime == null:
		return Vector2.ZERO
	var hazards: Array = runtime.get("hazards")
	var fallback := Vector2.ZERO
	for h in hazards:
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


# Teleport the player onto a real hazard and hold it there until the
# runtime reports dead. Returns false if no death within the budget.
func _kill_player(game_inst: Node) -> bool:
	var player := game_inst.get("player") as Node2D
	var runtime: Node = game_inst.get("runtime")
	if player == null or runtime == null:
		return false
	for attempt in range(2):
		var target := _pick_death_target(game_inst)
		if target == Vector2.ZERO:
			return false
		for f in range(150):
			player.global_position = target
			player.set("velocity", Vector2.ZERO)
			await get_tree().physics_frame
			if bool(runtime.get("dead")):
				return true
	return false


func _wait_retry(game_inst: Node) -> void:
	# Tap-only retry (v1.0.4, no auto-retry timer): send a REAL input
	# edge (ENTER key) and wait for the dead state to clear.
	var runtime: Node = game_inst.get("runtime")
	if runtime == null:
		return
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.echo = false
	ev.keycode = KEY_ENTER
	ev.physical_keycode = KEY_ENTER
	Input.parse_input_event(ev)
	for f in range(90):
		if not bool(runtime.get("dead")):
			return
		await get_tree().physics_frame


func _write_progress(highest: int, completed_ids: Array) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", TTProgress.SAVE_VERSION)
	cfg.set_value("progress", "highest_unlocked", highest)
	cfg.set_value("progress", "completed", completed_ids)
	cfg.save("user://progress.cfg")


func _settle(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	await get_tree().process_frame
	await get_tree().process_frame


func _settle_and_capture(path: String, seconds: float) -> void:
	await _settle(seconds)
	await _capture_now(path)


func _capture_now(path: String) -> void:
	# Capture after a drawn frame, without a long settle: the death
	# shot must land inside the dead state (tap-only: it holds until
	# an input edge, so there is no timer to race).
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("SHOT saved ", path, " err=", err, " size=", img.get_size(), " format=", img.get_format())


func _remove(inst: Node) -> void:
	remove_child(inst)
	inst.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
