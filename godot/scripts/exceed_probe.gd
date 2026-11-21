extends Node

# EXCEED probe (19 Nov 2026): evidences the juice items headlessly
# where possible and with REAL rendered frames where pixels matter.
# Run under Xvfb (real rendering driver, NOT --headless):
#   xvfb-run -a <godot> --path <project> res://scenes/exceed_probe.tscn
# Captures to verification/exceed/shots/:
#   map_idle_t0.png / map_idle_t1.png (idle ring animation, 1.0s apart)
#   death_burst_new.png (burst at death, alive_count printed)
#   landing_squash.png (squash at a hard landing — ZERO dust, Fix 1)
#   confetti.png (door-enter celebration, alive_count printed)
# Prints: tone log (jump/land/death/win/skip), wipe cover/reveal ms.
# Quits 0 only if every check passes; a FRESH empty progress is
# restored at the end. No gameplay code is touched by this probe.

var _out_dir := ""
var _fails: Array[String] = []
var _passes: Array[String] = []


func _ready() -> void:
	_run()


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("EXCEED PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("EXCEED FAIL: ", name, (" | " + detail) if detail != "" else "")


func _run() -> void:
	_out_dir = OS.get_environment("HOME") + "/workspace/trap-tower/verification/exceed/shots"
	var derr := DirAccess.make_dir_recursive_absolute(_out_dir)
	if derr != OK:
		print("EXCEED ERROR: cannot create out dir ", _out_dir)
		get_tree().quit(1)
		return
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("EXCEED ERROR: ", str(loaded["error"]))
		get_tree().quit(1)
		return
	var levels: Array = loaded["levels"]

	# --- (f) audio: every action logs its tone -------------------------
	TTAudio.ensure_audio(get_tree())
	TTAudio.play_jump()
	TTAudio.play_land()
	TTAudio.play_death()
	TTAudio.play_win()
	TTAudio.play_skip()
	var log: Array = TTAudio.get_tone_log()
	print("EXCEED tone_log=", log)
	_check("audio-log", log == ["jump", "land", "death", "win", "skip"],
		"tones fired in order: " + str(log))

	# --- (d) wipe timing ----------------------------------------------
	# Warm up first: the first frames after startup can carry a huge
	# delta (slow first render), which would finish the 0.12s cover
	# in a single frame and fake the measurement.
	for i in range(5):
		await get_tree().process_frame
	var wipe := TTWipe.new()
	add_child(wipe)
	var t0 := Time.get_ticks_msec()
	await wipe.cover()
	var cover_ms := Time.get_ticks_msec() - t0
	_check("wipe-cover", cover_ms >= 100 and cover_ms <= 250,
		"cover_ms=" + str(cover_ms) + " frac=" + str(wipe.get("_frac")))
	t0 = Time.get_ticks_msec()
	await wipe.reveal()
	var reveal_ms := Time.get_ticks_msec() - t0
	_check("wipe-reveal", reveal_ms >= 100 and reveal_ms <= 250,
		"reveal_ms=" + str(reveal_ms) + " frac=" + str(wipe.get("_frac")))
	remove_child(wipe)
	wipe.queue_free()

	# --- (e) map idle animation: two frames 1.0s apart ----------------
	_write_progress(0, [])
	var map_scene: PackedScene = load("res://scenes/map.tscn")
	var map_inst: Node = map_scene.instantiate()
	add_child(map_inst)
	await _settle_and_capture(_out_dir + "/map_idle_t0.png", 0.5)
	await _settle_and_capture(_out_dir + "/map_idle_t1.png", 1.0)
	_remove(map_inst)

	# --- game-level juice: death burst, landing, confetti -------------
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	var death_idx := _find_death_level(levels)
	_check("death-level-found", death_idx >= 0, "idx=" + str(death_idx))
	if death_idx < 0:
		death_idx = 0
	TTState.level_index = death_idx
	var game_inst: Node = game_scene.instantiate()
	add_child(game_inst)
	await _settle(0.6)

	# (a) death burst: real hazard death, capture at the burst peak.
	var killed := await _kill_player(game_inst, levels[death_idx])
	_check("death-real", killed, "forced a real hazard death on L001")
	if killed:
		# game.gd mirrors deaths in ITS _physics_process, which runs
		# BEFORE the runtime's _die() in the death frame — so the
		# burst spawns one frame after the dead flag appears.
		await get_tree().physics_frame
		var burst: Node = game_inst.get("_death_burst")
		var n := int(burst.get("alive_count")) if burst != null else -1
		_check("death-burst-count", n >= 25,
			"alive_count=" + str(n) + " (old burst was 14)")
		await _capture_now(_out_dir + "/death_burst_new.png")
		# Retry (tap-only) to clear the dead state for the next test.
		await _wait_retry(game_inst)
		await _settle(0.3)

	# (b) landing squash, ZERO dust (Fix 1, phone verdict 21 Nov 2026):
	# drop the hero 250px above its spawn onto safe ground (spawn has
	# a 40px hazard-free zone). The landing dust is REMOVED — no code
	# puffs, no Effekseer emitter on the player. Squash + land sound
	# are the only landing feedback left.
	var player := game_inst.get("player") as Node2D
	var runtime: Node = game_inst.get("runtime")
	var landed := false
	var squash_v := 0.0
	var dust_gone := false
	var dust_emitters := -1
	if player != null:
		var spawn_d: Dictionary = (levels[death_idx] as Dictionary)["spawn"]
		var drop_from := Vector2(float(spawn_d["x"]), float(spawn_d["y"]) - 120.0)
		player.global_position = drop_from
		player.set("velocity", Vector2.ZERO)
		for f in range(120):
			await get_tree().physics_frame
			var sq := float(player.get("_squash"))
			if sq > 0.5:
				landed = true
				squash_v = sq
				# _dust / _dust_fx no longer exist on the player, and
				# no EffekseerEmitter2D may be parented to it.
				dust_gone = player.get("_dust") == null \
					and player.get("_dust_fx") == null
				dust_emitters = _count_emitters(player).size()
				break
	_check("landing-squash", landed,
		"squash=" + str(squash_v))
	_check("landing-zero-dust", landed and dust_gone and dust_emitters == 0,
		"_dust/_dust_fx gone=" + str(dust_gone)
		+ " player_emitters=" + str(dust_emitters) + " (must be 0)")
	if landed:
		await _capture_now(_out_dir + "/landing_squash.png")

	# (c) door celebration: teleport onto the door, capture the burst.
	var confetti_n := -1
	if player != null and runtime != null:
		var door_d: Dictionary = (levels[death_idx] as Dictionary)["door"]
		var door_xy := Vector2(float(door_d["x"]), float(door_d["y"]))
		for f in range(120):
			player.global_position = door_xy + Vector2(0, -10)
			player.set("velocity", Vector2.ZERO)
			await get_tree().physics_frame
			if bool(game_inst.get("level_completed")):
				break
		# The win branch spawns confetti in the same frame the
		# completion is mirrored, and the win wipe is delayed so the
		# burst stays uncovered for ~0.6s — a settled capture shows
		# it mid-burst.
		await get_tree().process_frame
		var conf: Node = game_inst.get("_confetti")
		if conf != null:
			confetti_n = int(conf.get("alive_count"))
		_check("confetti-count", confetti_n >= 30,
			"alive_count=" + str(confetti_n) + " (door burst, 36 pieces)")
		if confetti_n > 0:
			await _capture_now(_out_dir + "/confetti.png")
	_remove(game_inst)

	_write_progress(0, [])
	print("EXCEED DONE passes=", _passes.size(), " fails=", _fails.size())
	if _fails.is_empty():
		get_tree().quit(0)
	else:
		get_tree().quit(1)


func _count_emitters(inst: Node) -> Array:
	var found: Array = []
	var stack: Array = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_class() == "EffekseerEmitter2D":
			found.append(n)
		for c in n.get_children():
			stack.append(c)
	return found


func _find_death_level(levels: Array) -> int:
	for pass_no in range(2):
		for idx in range(levels.size()):
			for h in (levels[idx] as Dictionary).get("hazards", []):
				var htype := str((h as Dictionary).get("type", ""))
				if htype == "saw" or htype == "spiked_column":
					return idx
				if htype == "spikes" and (pass_no == 1 or not (h as Dictionary).has("period")):
					return idx
	return -1


func _kill_player(game_inst: Node, level: Dictionary) -> bool:
	var player := game_inst.get("player") as Node2D
	var runtime: Node = game_inst.get("runtime")
	if player == null or runtime == null:
		return false
	var target := Vector2.ZERO
	for h in level.get("hazards", []):
		if str((h as Dictionary).get("type", "")) == "spikes":
			target = Vector2(float((h as Dictionary).get("x", 0)) + float((h as Dictionary).get("w", 0)) * 0.5,
				float((h as Dictionary).get("y", 0)) + 5.0)
			break
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
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("EXCEED saved ", path, " err=", err, " size=", img.get_size())


func _remove(inst: Node) -> void:
	remove_child(inst)
	inst.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
