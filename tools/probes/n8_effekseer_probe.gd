# N8 Effekseer-vs-fallback discrimination probe (Lane 8 final re-verification,
# Trap Tower v1.0.5). SceneTree script, run under Xvfb with REAL rendering
# (NOT --headless):
#   xvfb-run -a <godot> --display-driver x11 --rendering-driver opengl3 \
#     --fixed-fps 60 --path <project> \
#     -s /home/hatch/workspace/trap-tower/repo/tools/probes/n8_effekseer_probe.gd
#
# Triggers all three effects through the REAL game paths (hazard death,
# hard landing, door win) and, for each, prints the live discriminator:
#   * the fx flag (_fx_mode / _dust_fx) — while true, the code-drawn
#     _draw()/_draw_dust() is a no-op (see death_particles.gd,
#     confetti_particles.gd, player.gd), so NOTHING code-drawn can appear;
#   * alive_count (30 / 6 / 36);
#   * the live emitter node(s): class name + is_playing();
#   * count of EffekseerEmitter2D nodes in the live scene tree.
# Captures fresh screenshots at burst peak into
# verification/shots-v105-final2/n8_fx_{death,dust,confetti}.png.
# Quits 0 only if every check passes. Restores a FRESH empty progress.
# No gameplay code is touched by this probe.

extends SceneTree

var _out := "/home/hatch/workspace/trap-tower/verification/shots-v105-final2"
var _fails: Array[String] = []
var _passes: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("N8 PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("N8 FAIL: ", name, (" | " + detail) if detail != "" else "")


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


func _run() -> void:
	print("N8 EffekseerFX.available()=", EffekseerFX.available(),
		" class_exists(EffekseerEmitter2D)=", ClassDB.class_exists("EffekseerEmitter2D"),
		" has_singleton(EffekseerSystem)=", Engine.has_singleton("EffekseerSystem"))
	_check("plugin-available", EffekseerFX.available()
		and ClassDB.class_exists("EffekseerEmitter2D")
		and Engine.has_singleton("EffekseerSystem"))
	_check("death-effect-loads", EffekseerFX.death_effect() != null)
	_check("confetti-effect-loads", EffekseerFX.confetti_effect() != null)
	_check("dust-effect-loads", EffekseerFX.dust_effect() != null)

	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("N8 ERROR: ", str(loaded["error"]))
		quit(1)
		return
	var levels: Array = loaded["levels"]
	var death_idx := -1
	for idx in range(levels.size()):
		for h in (levels[idx] as Dictionary).get("hazards", []):
			if str((h as Dictionary).get("type", "")) in ["saw", "spiked_column", "spikes"]:
				death_idx = idx
				break
		if death_idx >= 0:
			break
	_check("death-level-found", death_idx >= 0, "idx=" + str(death_idx))
	if death_idx < 0:
		death_idx = 0
	_write_progress(0, [])
	TTState.level_index = death_idx
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	var game_inst: Node = game_scene.instantiate()
	root.add_child(game_inst)
	await _settle(0.6)

	# --- (1) DEATH BURST via a real hazard death ----------------------
	var killed := await _kill_player(game_inst, levels[death_idx])
	_check("death-real", killed, "forced a real hazard death")
	if killed:
		await physics_frame
		var burst: Node = game_inst.get("_death_burst")
		var fx_mode := bool(burst.get("_fx_mode")) if burst != null else false
		var n := int(burst.get("alive_count")) if burst != null else -1
		var em: Node = burst.get("_emitter") if burst != null else null
		var em_cls := em.get_class() if em != null and is_instance_valid(em) else "<none>"
		var em_playing := bool(em.call("is_playing")) if em != null and is_instance_valid(em) else false
		var tree_ems := _count_emitters(game_inst)
		print("N8 DEATH: _fx_mode=", fx_mode, " alive_count=", n,
			" emitter_class=", em_cls, " is_playing=", em_playing,
			" tree_emitters=", tree_ems.size())
		_check("death-fx-mode", fx_mode, "_fx_mode=true => code _draw() is a no-op")
		_check("death-alive-30", n == 30, "alive_count=" + str(n))
		_check("death-emitter-effekseer", em_cls == "EffekseerEmitter2D"
			and em_playing, "class=" + em_cls + " playing=" + str(em_playing))
		_check("death-tree-emitters", tree_ems.size() == 1,
			"count=" + str(tree_ems.size()))
		# Capture mid-burst (~0.15s): at spawn+0.05s the 30 squares are
		# still a compact cluster at the death spot.
		await _settle(0.15)
		await _capture_now(_out + "/n8_fx_death.png")
		await _wait_retry(game_inst)
		await _settle(0.3)

	# --- (2) LANDING DUST via a hard landing --------------------------
	var player := game_inst.get("player") as Node2D
	var runtime: Node = game_inst.get("runtime")
	var landed := false
	var dust_fx := false
	var dust_n := 0
	if player != null:
		var spawn_d: Dictionary = (levels[death_idx] as Dictionary)["spawn"]
		player.global_position = Vector2(float(spawn_d["x"]), float(spawn_d["y"]) - 120.0)
		player.set("velocity", Vector2.ZERO)
		for f in range(120):
			await physics_frame
			if float(player.get("_squash")) > 0.5:
				landed = true
				dust_fx = bool(player.get("_dust_fx"))
				dust_n = (player.get("_dust") as Array).size()
				break
	print("N8 DUST: landed=", landed, " _dust_fx=", dust_fx, " _dust.size()=", dust_n)
	_check("dust-landed", landed, "squash>0.5 on hard landing")
	_check("dust-fx-mode", dust_fx, "_dust_fx=true => code _draw_dust() is a no-op")
	_check("dust-entries-6", dust_n == 6, "entries=" + str(dust_n))
	if landed:
		await _capture_now(_out + "/n8_fx_dust.png")

	# --- (3) DOOR CONFETTI via a real door win ------------------------
	var confetti_n := -1
	var conf_fx := false
	var conf_emitters: Array = []
	if player != null and runtime != null:
		var door_d: Dictionary = (levels[death_idx] as Dictionary)["door"]
		var door_xy := Vector2(float(door_d["x"]), float(door_d["y"]))
		for f in range(120):
			player.global_position = door_xy + Vector2(0, -10)
			player.set("velocity", Vector2.ZERO)
			await physics_frame
			if bool(game_inst.get("level_completed")):
				break
		await process_frame
		var conf: Node = game_inst.get("_confetti")
		if conf != null:
			confetti_n = int(conf.get("alive_count"))
			conf_fx = bool(conf.get("_fx_mode"))
			conf_emitters = conf.get("_emitters")
		var playing := 0
		var classes: Array = []
		for e in conf_emitters:
			if is_instance_valid(e):
				classes.append(e.get_class())
				if bool(e.call("is_playing")):
					playing += 1
		print("N8 CONFETTI: _fx_mode=", conf_fx, " alive_count=", confetti_n,
			" emitters=", conf_emitters.size(), " classes=", str(classes),
			" playing=", playing)
		_check("confetti-fx-mode", conf_fx, "_fx_mode=true => code _draw() is a no-op")
		_check("confetti-alive-36", confetti_n == 36, "alive_count=" + str(confetti_n))
		_check("confetti-emitters-3", conf_emitters.size() == 3
			and playing == 3, "emitters=" + str(conf_emitters.size())
			+ " playing=" + str(playing) + " classes=" + str(classes))
		if confetti_n > 0:
			await _capture_now(_out + "/n8_fx_confetti.png")

	root.remove_child(game_inst)
	game_inst.queue_free()
	await process_frame
	await process_frame
	_write_progress(0, [])
	print("N8 DONE passes=", _passes.size(), " fails=", _fails.size())
	if _fails.is_empty():
		quit(0)
	else:
		quit(1)


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
		await physics_frame
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
		await physics_frame


func _write_progress(highest: int, completed: Array) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "save_version", TTProgress.SAVE_VERSION)
	cfg.set_value("progress", "highest_unlocked", highest)
	cfg.set_value("progress", "completed", completed)
	cfg.save("user://progress.cfg")


func _settle(seconds: float) -> void:
	await create_timer(seconds).timeout
	await process_frame
	await process_frame


func _capture_now(path: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var err := img.save_png(path)
	print("N8 saved ", path, " err=", err, " size=", img.get_size())
