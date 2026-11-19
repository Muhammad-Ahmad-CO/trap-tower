# N1 death-flow probe (Lane B verification, Run 2). Headless SceneTree script.
#
# Builds a REAL level through the game's builder (game scene build_level ->
# TTBuilder) and scripts hazard deaths by teleporting the player onto a
# real hazard. Asserts the frozen death-flow contract:
#   (a) deaths increments synchronously in the death frame (runtime, and
#       the game mirror within 1 physics step)
#   (b) hero hidden + "TAP TO RETRY" prompt visible during the dead state
#   (c) traps held: a triggered pillar stays down and a falling platform
#       stays fallen (no reset) while dead
#   (d) input-edge retry (real dispatched key event) respawns + resets traps
#   (e) NO auto-retry: the dead state holds indefinitely with no input
#       (tap-only, LEVEL_SCHEMA.md v3 — the v1.0.3 0.6s auto-retry timer
#       was REMOVED in v1.0.4); an input edge after the hold still
#       respawns + resets traps
#   (f) a second death after retry works (and touch-edge retry works)
#
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s tools/probes/death_flow_probe.gd [-- --mode full|noauto]
#   --mode full (default): phase 1 (input-edge) + phase 2 (no-auto-retry hold, fresh instance, no input)
#   --mode noauto: phase 2 only, in a fresh process (the truly separate no-input run)
# Prints PASS/FAIL per assertion and exits 0 only if all pass.
# NOTE: death timing is counted in physics frames at fixed 60fps.
# Tap-only: there is NO auto-retry timer any more (v1.0.4); the dead
# state must hold until an input edge arrives, however long that takes.
extends SceneTree

var _fails: Array[String] = []
var _passes: Array[String] = []
var _mode := "full"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "noauto":
			_mode = "noauto"
		elif a == "full":
			_mode = "full"
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("N1 PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("N1 FAIL: ", name, (" | " + detail) if detail != "" else "")


func _level() -> Dictionary:
	return {
		"id": "PROBE1", "palette": 0, "template": "probe", "variation": "probe",
		"spawn": {"x": 70, "y": 500}, "door": {"x": 1210, "y": 500},
		"platforms": [
			{"x": 0, "y": 500, "w": 1280, "h": 80, "kind": "solid"},
			{"x": 800, "y": 420, "w": 100, "h": 20, "kind": "falling", "stand_time": 0.5},
		],
		"hazards": [
			{"type": "spikes", "x": 300, "y": 476, "w": 80, "h": 24, "dir": "up"},
			{"type": "hanging_pillar", "x": 600, "y": 100, "w": 60, "h": 80,
				"drop_trigger_x": 500, "drop_speed": 700},
		],
	}


func _build_game() -> Node:
	var tuning: Dictionary = TTuning.load_tuning()
	var packed: PackedScene = load("res://scenes/game.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await physics_frame
	await physics_frame
	game.call("build_level", _level(), tuning)
	await physics_frame
	await physics_frame
	return game


func _nodes(game: Node) -> Dictionary:
	var runtime: Node = game.get("runtime")
	var player: Node2D = game.get("player")
	var pillar: Node = null
	var platform: Node = null
	if runtime != null:
		for h in (runtime.get("hazards") as Array):
			if str(h.get("htype")) == "hanging_pillar":
				pillar = h
		for p in (runtime.get("platforms") as Array):
			if str(p.get("kind")) == "falling":
				platform = p
	return {"runtime": runtime, "player": player, "pillar": pillar, "platform": platform}


# Pixel-font death prompt (game.gd builds a TTPixelLabel, not a
# Label, since v1.0.4). Found by text + visibility, never by type.
func _death_label(game: Node) -> Node:
	for child in game.get_children():
		if str(child.get("text")) == "TAP TO RETRY":
			return child
	return null


# HUD pause/restart buttons (IconButtons under the HUD node), for the
# death-state hidden check.
func _hud_button(hud: Node, icon: String) -> Control:
	for child in hud.get_children():
		if child is Control and str(child.get("icon")) == icon:
			return child
	return null


func _death_burst(game: Node) -> Node:
	for child in game.get_children():
		if child.get_script() != null and str(child.get_script().resource_path).ends_with("death_particles.gd"):
			return child
	return null


func _hold(player: Node2D, pos: Vector2) -> void:
	player.global_position = pos
	player.set("velocity", Vector2.ZERO)


# Teleport across the pillar trigger and wait until the pillar is fully
# down (offset == drop distance 400). Returns frames waited, or -1.
func _trigger_pillar(n: Dictionary) -> int:
	var player: Node2D = n["player"]
	var pillar: Node = n["pillar"]
	for f in range(120):
		_hold(player, Vector2(540, 478))
		await physics_frame
		if bool(pillar.get("pillar_dropped")) and float(pillar.get("pillar_offset")) >= 399.0:
			return f + 1
	return -1


# Stand on the falling platform until it starts falling. Returns frames, or -1.
func _drop_platform(n: Dictionary) -> int:
	var player: Node2D = n["player"]
	var platform: Node = n["platform"]
	for f in range(120):
		if not bool(platform.get("falling")):
			_hold(player, Vector2(850, 398))
		await physics_frame
		if bool(platform.get("falling")):
			return f + 1
	return -1


# Teleport onto the spikes and wait for death. Returns a dict with the
# death frame count, runtime deaths at detection, and game-mirror lag
# in additional physics frames (0 or 1 allowed).
func _kill(n: Dictionary, game: Node) -> Dictionary:
	var player: Node2D = n["player"]
	var runtime: Node = n["runtime"]
	var before: int = int(runtime.get("deaths"))
	for f in range(150):
		_hold(player, Vector2(340, 478))
		await physics_frame
		if bool(runtime.get("dead")):
			var deaths_at: int = int(runtime.get("deaths"))
			var lag := 0
			while int(game.get("deaths")) != deaths_at and lag < 3:
				await physics_frame
				lag += 1
			return {"frames": f + 1, "before": before, "deaths_at": deaths_at,
					"mirror_lag": lag, "game_deaths": int(game.get("deaths"))}
	return {"frames": -1, "before": before, "deaths_at": -1, "mirror_lag": -1, "game_deaths": -1}


func _traps_reset(n: Dictionary) -> Dictionary:
	var pillar: Node = n["pillar"]
	var platform: Node = n["platform"]
	var start_pos: Vector2 = platform.get("start_pos")
	return {
		"pillar_offset": float(pillar.get("pillar_offset")),
		"pillar_dropped": bool(pillar.get("pillar_dropped")),
		"pillar_hanging": bool(pillar.get("pillar_hanging")),
		"platform_falling": bool(platform.get("falling")),
		"platform_dy": float((platform as Node2D).position.y - start_pos.y),
	}


func _send_key(keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.echo = false
	ev.keycode = keycode
	ev.physical_keycode = keycode
	Input.parse_input_event(ev)


func _send_key_release(keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.pressed = false
	ev.echo = false
	ev.keycode = keycode
	ev.physical_keycode = keycode
	Input.parse_input_event(ev)


func _send_touch() -> void:
	var ev := InputEventScreenTouch.new()
	ev.pressed = true
	ev.index = 0
	ev.position = Vector2(640, 300)
	Input.parse_input_event(ev)


func _run() -> void:
	print("N1 death-flow probe mode=", _mode)
	if _mode == "full":
		await _phase_input_edge()
	await _phase_no_auto_retry()
	print("N1 SUMMARY: ", _passes.size(), " passed, ", _fails.size(), " failed")
	if not _fails.is_empty():
		print("N1 FAILED: ", ", ".join(_fails))
		quit(1)
		return
	print("N1 ALL PASS")
	quit(0)


func _phase_input_edge() -> void:
	print("N1 phase 1: input-edge retry")
	var game := await _build_game()
	var n := _nodes(game)
	_check("setup: game+runtime+player+pillar+platform built", game != null
		and n["runtime"] != null and n["player"] != null
		and n["pillar"] != null and n["platform"] != null)
	if n["runtime"] == null or n["player"] == null:
		return
	var runtime: Node = n["runtime"]
	var player: Node2D = n["player"]
	var pillar: Node = n["pillar"]
	var platform: Node = n["platform"]

	var trig_frames := await _trigger_pillar(n)
	_check("setup: triggered pillar fully down before death", trig_frames > 0,
		"frames=" + str(trig_frames) + " offset=" + str(pillar.get("pillar_offset")))
	var drop_frames := await _drop_platform(n)
	_check("setup: falling platform dropped before death", drop_frames > 0,
		"frames=" + str(drop_frames))
	# Let the platform fall clear, then die on the spikes.
	for f in range(10):
		await physics_frame
	var plat_start: Vector2 = platform.get("start_pos")

	# --- (a) synchronous deaths increment -------------------------------
	var kill := await _kill(n, game)
	_check("a1: death detected on real hazard", int(kill["frames"]) > 0,
		"frames=" + str(kill["frames"]))
	_check("a2: runtime deaths incremented synchronously in death frame",
		int(kill["deaths_at"]) == int(kill["before"]) + 1,
		"before=" + str(kill["before"]) + " at=" + str(kill["deaths_at"]))
	_check("a3: game mirror matches within 1 physics step",
		int(kill["game_deaths"]) == int(kill["deaths_at"]) and int(kill["mirror_lag"]) <= 1,
		"game=" + str(kill["game_deaths"]) + " lag=" + str(kill["mirror_lag"]))

	# --- (b) hero hidden + prompt visible -------------------------------
	await physics_frame
	var label := _death_label(game)
	_check("b1: hero hidden during dead state", not player.visible)
	_check("b2: TAP TO RETRY prompt visible during dead state",
		label != null and label.visible,
		"label_found=" + str(label != null))
	# --- (b2) v1.0.4 visuals: HUD buttons hidden + burst fired --------
	var hud: Node = game.get("hud")
	var pause_btn := _hud_button(hud, "pause") if hud != null else null
	var restart_btn := _hud_button(hud, "restart") if hud != null else null
	_check("b3: pause + restart buttons HIDDEN during dead state",
		pause_btn != null and restart_btn != null
		and not pause_btn.visible and not restart_btn.visible,
		"pause_visible=" + str(pause_btn.visible if pause_btn != null else "?")
		+ " restart_visible=" + str(restart_btn.visible if restart_btn != null else "?"))
	var burst := _death_burst(game)
	_check("b4: death particle burst fired (particles alive in dead state)",
		burst != null and int(burst.get("alive_count")) > 0,
		"alive=" + str(burst.get("alive_count") if burst != null else "?"))

	# --- (c) traps held while dead (10 frames, no input) -----------------
	var held_ok := true
	var held_detail := ""
	for f in range(10):
		await physics_frame
		if not bool(runtime.get("dead")):
			held_ok = false
			held_detail = "respawned early at hold frame " + str(f)
			break
		if not bool(pillar.get("pillar_dropped")) or float(pillar.get("pillar_offset")) < 399.0:
			held_ok = false
			held_detail = "pillar reset at hold frame " + str(f)
			break
		if not bool(platform.get("falling")) or float((platform as Node2D).position.y - plat_start.y) < 10.0:
			held_ok = false
			held_detail = "platform reset at hold frame " + str(f)
			break
		if int(runtime.get("deaths")) != 1:
			held_ok = false
			held_detail = "deaths changed while dead"
			break
	_check("c1: traps held while dead (pillar down, platform fallen, no early retry)",
		held_ok, held_detail + " pillar_offset=" + str(pillar.get("pillar_offset"))
		+ " platform_dy=" + str(float((platform as Node2D).position.y - plat_start.y)))

	# --- (d) input-edge retry (real dispatched key event) ----------------
	# Tap-only (v1.0.4): there is no auto-retry timer any more, so a
	# retry within 10 frames of the key event proves the input path.
	var frames_since_death := 11
	# ENTER, not Space: any key edge retries, and Space is also the
	# jump key, so a Space retry respawns AND jumps (observed: the
	# player rose ~27px in 2 frames after a Space retry — the retry
	# input doubles as jump input; expected, not a defect). ENTER
	# isolates the retry so the respawn position can be checked exactly.
	_send_key(KEY_ENTER)
	var retry_frames := -1
	for f in range(12):
		await physics_frame
		frames_since_death += 1
		if not bool(runtime.get("dead")):
			retry_frames = f + 1
			break
	_send_key_release(KEY_ENTER)
	_check("d1: input-edge retry respawns quickly (before auto-retry window)",
		retry_frames > 0 and frames_since_death < 30,
		"retry_after_event=" + str(retry_frames) + " frames_since_death=" + str(frames_since_death))
	await physics_frame
	await physics_frame
	var spawn_centre := Vector2(70, 480.5)
	var pos_ok: bool = player.global_position.distance_to(spawn_centre) <= 2.0
	_check("d2: retry respawns player at spawn", pos_ok,
		"pos=" + str(player.global_position))
	_check("d3: hero visible + physics on after retry",
		player.visible and player.is_physics_processing())
	var st := _traps_reset(n)
	_check("d4: retry resets traps (pillar up, platform home)", st["pillar_offset"] == 0.0
		and not bool(st["pillar_dropped"]) and bool(st["pillar_hanging"])
		and not bool(st["platform_falling"]) and absf(float(st["platform_dy"])) < 0.5,
		"pillar_offset=" + str(st["pillar_offset"]) + " dropped=" + str(st["pillar_dropped"])
		+ " platform_dy=" + str(st["platform_dy"]))
	_check("d5: deaths stays 1 after retry (no increment at retry)",
		int(runtime.get("deaths")) == 1 and int(game.get("deaths")) == 1)
	label = _death_label(game)
	_check("d6: prompt hidden after retry", label == null or not label.visible)
	_check("d7: HUD pause + restart visible again after retry",
		pause_btn != null and restart_btn != null
		and pause_btn.visible and restart_btn.visible,
		"pause_visible=" + str(pause_btn.visible if pause_btn != null else "?")
		+ " restart_visible=" + str(restart_btn.visible if restart_btn != null else "?"))

	# --- (f) second death after retry + touch-edge retry -----------------
	var trig2 := await _trigger_pillar(n)
	_check("f0: pillar re-triggers after retry", trig2 > 0)
	var kill2 := await _kill(n, game)
	_check("f1: second death after retry works", int(kill2["frames"]) > 0
		and int(kill2["deaths_at"]) == 2,
		"deaths=" + str(kill2["deaths_at"]))
	_send_touch()
	var retry2 := -1
	for f in range(12):
		await physics_frame
		if not bool(runtime.get("dead")):
			retry2 = f + 1
			break
	_check("f2: touch-edge retry respawns quickly", retry2 > 0,
		"frames=" + str(retry2))
	await physics_frame
	await physics_frame
	_check("f3: second retry respawns at spawn + pillar reset",
		player.global_position.distance_to(spawn_centre) <= 2.0
		and float(pillar.get("pillar_offset")) == 0.0
		and not bool(pillar.get("pillar_dropped")))

	game.queue_free()
	await physics_frame
	await physics_frame


func _phase_no_auto_retry() -> void:
	print("N1 phase 2: NO auto-retry, NO input events sent (tap-only)")
	var game := await _build_game()
	var n := _nodes(game)
	if n["runtime"] == null or n["player"] == null:
		_check("setup: phase-2 game built", false)
		return
	var runtime: Node = n["runtime"]
	var player: Node2D = n["player"]
	var pillar: Node = n["pillar"]
	var platform: Node = n["platform"]
	var trig_frames := await _trigger_pillar(n)
	var drop_frames := await _drop_platform(n)
	_check("e0: phase-2 traps armed before death", trig_frames > 0 and drop_frames > 0,
		"pillar_frames=" + str(trig_frames) + " platform_frames=" + str(drop_frames))
	for f in range(10):
		await physics_frame
	var kill := await _kill(n, game)
	_check("e1: phase-2 death detected", int(kill["frames"]) > 0
		and int(kill["deaths_at"]) == 1, "deaths=" + str(kill["deaths_at"]))
	# NO input from here on. Tap-only: the dead state must HOLD
	# indefinitely — 90 frames (1.5s, far past the old 0.6s timer)
	# with no respawn, no trap reset, no deaths change.
	var held_frames := 0
	var still_dead := true
	for f in range(90):
		await physics_frame
		if bool(runtime.get("dead")):
			held_frames += 1
		else:
			still_dead = false
			break
	_check("e2: dead state holds 90 frames with no input (no auto-retry)",
		still_dead and held_frames >= 90,
		"held_frames=" + str(held_frames))
	_check("e3: deaths stays 1 while held (no respawn, no re-death)",
		int(runtime.get("deaths")) == 1 and int(game.get("deaths")) == 1)
	# Now a real input edge must still retry, even after the long hold.
	_send_key(KEY_ENTER)
	var retry_frame := -1
	for f in range(12):
		await physics_frame
		if not bool(runtime.get("dead")):
			retry_frame = f + 1
			break
	_send_key_release(KEY_ENTER)
	_check("e4: input-edge retry respawns after the long hold",
		retry_frame > 0, "retry_frame=" + str(retry_frame))
	await physics_frame
	await physics_frame
	var spawn_centre := Vector2(70, 480.5)
	_check("e5: retry after hold respawns at spawn, hero visible",
		player.global_position.distance_to(spawn_centre) <= 2.0 and player.visible,
		"pos=" + str(player.global_position))
	var st := _traps_reset(n)
	_check("e6: retry after hold resets traps", st["pillar_offset"] == 0.0
		and not bool(st["pillar_dropped"]) and bool(st["pillar_hanging"])
		and not bool(st["platform_falling"]) and absf(float(st["platform_dy"])) < 0.5,
		"pillar_offset=" + str(st["pillar_offset"]) + " platform_dy=" + str(st["platform_dy"]))
	_check("e7: deaths stays 1 after retry", int(runtime.get("deaths")) == 1)
	game.queue_free()
	await physics_frame
	await physics_frame
