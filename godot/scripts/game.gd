extends Node2D

# Game scene (res://scenes/game.tscn). Loads levels.json in normal play;
# build_level(level_dict, tuning_dict) builds one given level directly
# (verifier entry point). Death/win rules live in the built TTRuntime;
# this node mirrors deaths / level_completed, polls the touch controls
# into the player, drives the HUD, shows the death-retry prompt and the
# pause overlay, handles skip/restart, and returns to the map on win
# (short delay so the win is observable before the scene changes).
#
# Frozen contracts kept here: N3 stale-build guard (clear ALL children
# BEFORE validation); deaths mirrored every physics frame including the
# dead state; pause contract (HUD + overlay ALWAYS, everything else
# INHERIT, paused=false on every exit path); touch controls forced to
# PROCESS_MODE_ALWAYS so finger tracking stays correct across pause.

# Pause overlay root: PROCESS_MODE_ALWAYS, so it still receives _input
# while the tree is paused and ESC can exit to the map from pause.
# (The game node's own _input is gated while paused.) It only acts
# while visible, so it never double-fires with game _input.
class PauseOverlay extends Control:
	signal esc_pressed

	func _input(event: InputEvent) -> void:
		if not visible:
			return
		if event is InputEventKey:
			var key := event as InputEventKey
			if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
				esc_pressed.emit()


var tuning: Dictionary = {}
var levels: Array = []
var level_index := 0
var current_level: Dictionary = {}
var builder: TTBuilder = null
var runtime: TTRuntime = null
var player: TTPlayer = null
var hud: TTHUD = null
var controls: TTTouchControls = null
var spawn_point := Vector2.ZERO
var deaths := 0
var level_completed := false
# Lane F3: stat persistence is ON only for real play (_ready with
# levels.json loaded). The build_level verifier path (autopilot /
# probes) leaves it OFF unless a test sets it explicitly, so gate
# runs never pollute the player's deaths / best times / ghosts.
var persist_stats := false
var _ghost_node: TTGhost = null
var _ghost_rec: Array = []
var _rec_timer := 0.0
var _attempt_time := 0.0
var _session_time := 0.0
var _was_dead := false
var _ghost_on := true
var _pause_ghost_btn: TTHUD.IconButton = null
var _level_ids: Array = []
var touch_left := false
var touch_right := false
var touch_jump := false
var _win_delay := -1.0
var _win_saved := false
var _wipe_started := false
var _error := false
var _last_deaths := 0
var _paused := false
var _pause_overlay: Control = null
var _death_label: TTPixelLabel = null
var _death_burst: TTDeathParticles = null
var _confetti: TTConfetti = null
var _wipe: TTWipe = null
var _hero_beat := -1.0
# Lane F1: hidden star in this level (null when already collected or
# when the level has no star) + whether this run is a bonus level.
var _star: TTStar = null
var _star_id := ""
var _is_bonus := false
# Lane F2: daily challenge / nightmare mode for this run (from
# TTState; set in _ready, never changed mid-run).
var _is_daily := false
var _daily_date := ""
var _is_nightmare := false


func _ready() -> void:
	TTAudio.ensure_audio(get_tree())
	tuning = TTuning.load_tuning()
	_is_bonus = TTState.bonus
	_is_daily = TTState.daily
	_daily_date = TTState.daily_date
	_is_nightmare = TTState.nightmare
	var loaded: Dictionary
	if _is_daily:
		# Daily challenge: one generated level, not levels.json.
		# The level dict is validated by _build_from_dict like any
		# other level; persist_stats stays on (deaths + play time
		# are global stats) but the win path records ONLY the daily
		# best, never completed / best_times / ghosts.
		var daily_level := TTDaily.generate_for_date(_daily_date)
		levels = [daily_level]
		_level_ids = [str(daily_level.get("id", ""))]
		level_index = 0
		persist_stats = true
		_ghost_on = bool(TTProgress.load_progress().get("ghost_visible", true))
		_build_from_dict(levels[level_index], tuning, level_index)
		return
	if _is_bonus:
		loaded = TTLevelData.load_levels("res://data/bonus_levels.json")
	else:
		loaded = TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		_show_error(str(loaded["error"]))
		return
	levels = loaded["levels"]
	if _is_nightmare:
		# Nightmare: the same 215 levels, mirrored + tightened at
		# runtime (levels.json untouched). The transformed dicts are
		# schema-valid, so _build_from_dict validates them normally.
		var nm: Array = []
		for lv in levels:
			nm.append(TTNightmare.apply(lv))
		levels = nm
	persist_stats = true
	_ghost_on = bool(TTProgress.load_progress().get("ghost_visible", true))
	for lv in levels:
		_level_ids.append(str((lv as Dictionary).get("id", "")))
	level_index = clampi(TTState.level_index, 0, levels.size() - 1)
	_build_from_dict(levels[level_index], tuning, level_index)


func build_level(level: Dictionary, p_tuning: Dictionary) -> void:
	tuning = p_tuning
	_build_from_dict(level, tuning, 0)


func _build_from_dict(level: Dictionary, p_tuning: Dictionary, index: int) -> void:
	tuning = p_tuning
	# N3 STALE-BUILD GUARD: clear ALL children BEFORE validation, and
	# drop every stale node ref, so a validation failure leaves an
	# empty tree (no stale player for the autopilot to find).
	for child in get_children():
		remove_child(child)
		child.queue_free()
	builder = null
	runtime = null
	player = null
	hud = null
	controls = null
	_star = null
	_star_id = ""
	_pause_overlay = null
	_death_label = null
	_death_burst = null
	_confetti = null
	_wipe = null
	_ghost_node = null
	_pause_ghost_btn = null
	_ghost_rec = []
	_rec_timer = 0.0
	_attempt_time = 0.0
	_was_dead = false
	_hero_beat = -1.0
	_paused = false
	var err := TTLevelData.validate_level(level, index, p_tuning)
	if err != "":
		_show_error("level " + str(level.get("id", "?")) + ": " + err)
		return
	_error = false
	current_level = level
	builder = TTBuilder.new()
	runtime = builder.build_level(level, p_tuning) as TTRuntime
	var pal: Dictionary = builder.palette
	spawn_point = builder.spawn_point
	var bg := ColorRect.new()
	bg.color = TTuning.col(str(pal.get("bg", "#E8871E")))
	bg.position = Vector2.ZERO
	bg.size = Vector2(1280, 720)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	add_child(runtime)
	player = builder.player
	# Lane F1: selected skin + hidden star (real play only — the
	# verifier build_level path leaves persist_stats false, so gates
	# never read the save or spawn a collectible).
	if persist_stats:
		var _prog := TTProgress.load_progress()
		if player != null:
			player.apply_skin(TTSkins.skin_by_id(str(_prog.get("selected_skin", "default"))))
		_spawn_star(str(level.get("id", "")), _prog)
	# Lane F3 ghost: the saved best-run path for this level, drawn
	# by a visual-only Node2D (no collision, no gameplay effect).
	# Empty when no best run exists yet (first play of the level).
	_ghost_node = TTGhost.new()
	_ghost_node.z_index = 60
	add_child(_ghost_node)
	_ghost_node.set_samples(TTProgress.load_ghost(str(level.get("id", ""))))
	_ghost_node.set_ghost_visible(_ghost_on)
	hud = TTHUD.new()
	var mode_text := "DAILY" if _is_daily else ("NIGHTMARE" if _is_nightmare else "")
	hud.setup(pal, index + 1, not _ghost_node.samples.is_empty(), _ghost_on, mode_text)
	hud.pause_pressed.connect(_on_pause_button)
	hud.restart_pressed.connect(restart_level)
	hud.skip_pressed.connect(_on_skip_pressed)
	hud.ghost_toggled.connect(_set_ghost_visible)
	add_child(hud)
	var controls_scene: PackedScene = load("res://scenes/touch_controls.tscn")
	controls = controls_scene.instantiate() as TTTouchControls
	controls.setup(p_tuning, pal)
	# Pause contract: finger tracking must stay correct across pause.
	controls.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(controls)
	_build_death_label()
	_build_pause_overlay(pal)
	_death_burst = TTDeathParticles.new()
	add_child(_death_burst)
	_confetti = TTConfetti.new()
	add_child(_confetti)
	# Original wipe reveal on level start (map -> level), then a brief
	# hero-less beat before the hero appears (schema Hero section).
	# Physics runs during the beat; only visibility is delayed.
	_wipe = TTWipe.new()
	add_child(_wipe)
	_wipe.reveal()
	if player != null:
		player.visible = false
		_hero_beat = 0.35
	deaths = 0
	_last_deaths = 0
	level_completed = false
	touch_left = false
	touch_right = false
	touch_jump = false
	_win_delay = -1.0
	_win_saved = false
	_wipe_started = false


# Lane F1: spawn this level's hidden star (if any and not already
# collected). The star is a plain Node2D under the level runtime:
# no collision, no physics — the game polls its rect each frame.
func _spawn_star(level_id: String, prog: Dictionary) -> void:
	_star = null
	_star_id = ""
	if (prog.get("stars_collected", []) as Array).has(level_id):
		return
	var pos := TTStarData.star_for(level_id)
	if pos == Vector2.INF:
		return
	_star = TTStar.new()
	_star.setup(pos)
	_star_id = level_id
	runtime.add_child(_star)


func _build_death_label() -> void:
	# "TAP TO RETRY" in yellow pixel font, upper centre (~16% down
	# the screen). Pixel font, not a Label (schema: ALL in-game text
	# in the code-drawn pixel font).
	_death_label = TTPixelLabel.new()
	_death_label.text = "TAP TO RETRY"
	_death_label.pixel_size = 5
	_death_label.color = TTHUD.HUD_YELLOW
	_death_label.align = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.width = 1280.0
	_death_label.position = Vector2(0, 115)
	# Above level art, below the pause overlay (90) and HUD (100):
	# upper centre, never overlapping the HUD buttons at y 16..64.
	_death_label.z_index = 80
	_death_label.visible = false
	add_child(_death_label)


func _build_pause_overlay(pal: Dictionary) -> void:
	var has_ghost := _ghost_node != null and not _ghost_node.samples.is_empty()
	var trap_col := TTuning.col(str(pal.get("trap", "#2B0A8A")))
	var bg_col := TTuning.col(str(pal.get("bg", "#E8871E")))
	var overlay := PauseOverlay.new()
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	overlay.position = Vector2.ZERO
	overlay.size = Vector2(1280, 720)
	overlay.visible = false
	overlay.esc_pressed.connect(_exit_to_map)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.position = Vector2.ZERO
	dim.size = Vector2(1280, 720)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	var panel := Panel.new()
	panel.position = Vector2(360, 230)
	panel.size = Vector2(560, 260)
	var psb := StyleBoxFlat.new()
	psb.bg_color = bg_col.lightened(0.45)
	psb.set_corner_radius_all(24)
	panel.add_theme_stylebox_override("panel", psb)
	overlay.add_child(panel)
	var icons: Array[String] = ["exit", "restart", "play"]
	for i in range(3):
		var b := TTHUD.IconButton.new()
		b.icon = icons[i]
		b.fill = TTHUD.HUD_DARK_RED
		b.icon_col = TTHUD.HUD_YELLOW
		b.position = Vector2(456 + i * 136, 312)
		b.size = Vector2(96, 96)
		b.corner_radius = 16
		overlay.add_child(b)
		if i == 0:
			b.pressed.connect(_exit_to_map)
		elif i == 1:
			b.pressed.connect(restart_level)
		else:
			b.pressed.connect(resume_game)
	# Lane F3: ghost toggle inside the pause panel (below the three
	# icon buttons, still inside the 560x260 panel: y 420..476).
	# Shown only when this level has a saved ghost.
	if has_ghost:
		_pause_ghost_btn = TTHUD.IconButton.new()
		_pause_ghost_btn.text = "GHOST ON" if _ghost_on else "GHOST OFF"
		_pause_ghost_btn.font_size = 26
		_pause_ghost_btn.fill = TTHUD.HUD_DARK_RED
		_pause_ghost_btn.icon_col = TTHUD.HUD_YELLOW
		_pause_ghost_btn.position = Vector2(490, 420)
		_pause_ghost_btn.size = Vector2(300, 56)
		_pause_ghost_btn.corner_radius = 14
		_pause_ghost_btn.pressed.connect(_on_pause_ghost_toggle)
		overlay.add_child(_pause_ghost_btn)
	# Below the HUD (100) so the HUD stays visible over the panel.
	overlay.z_index = 90
	add_child(overlay)
	_pause_overlay = overlay


func _physics_process(_delta: float) -> void:
	if _error or runtime == null or not is_instance_valid(runtime):
		return
	# Mirrored EVERY physics frame, including the dead state.
	deaths = runtime.deaths
	level_completed = runtime.level_completed
	# Played time accrues while the level is live (including the
	# dead-wait); flushed on win / skip / exit / restart.
	if not level_completed:
		_session_time += _delta
	if deaths > _last_deaths:
		_last_deaths = deaths
		if persist_stats:
			TTProgress.record_death()
		TTAudio.play_death()
		# Death particle burst at the hero's death position, then the
		# TAP TO RETRY prompt (schema: burst first, prompt after).
		if _death_burst != null and player != null and is_instance_valid(player):
			_death_burst.spawn_burst(player.global_position)
	if _death_label != null and is_instance_valid(_death_label):
		_death_label.visible = runtime.dead
	if hud != null and is_instance_valid(hud):
		hud.set_deaths(deaths)
		# Death state: pause + restart (+ skip) hidden; only the
		# top-centre level indicator stays.
		hud.set_dead(runtime.dead)
	# Lane F3 ghost recorder: 10 Hz position samples of the current
	# attempt, capped at 600 (60 s). A death-retry restarts the
	# attempt clock AND the recording, so a saved ghost is always
	# one clean spawn-to-door run (the fastest one wins the save).
	if _was_dead and not runtime.dead:
		_attempt_time = 0.0
		_rec_timer = 0.0
		_ghost_rec = []
	_was_dead = runtime.dead
	if not runtime.dead and not level_completed and player != null and is_instance_valid(player):
		_attempt_time += _delta
		_rec_timer += _delta
		while _rec_timer >= TTGhost.SAMPLE_DT and _ghost_rec.size() < TTGhost.MAX_SAMPLES:
			_rec_timer -= TTGhost.SAMPLE_DT
			_ghost_rec.append(Vector3(player.global_position.x, player.global_position.y, float(player.facing)))
	if controls != null and player != null and is_instance_valid(player):
		var st := controls.get_input_state()
		touch_left = bool(st["left"])
		touch_right = bool(st["right"])
		touch_jump = bool(st["jump"])
		player.touch_left = touch_left
		player.touch_right = touch_right
		player.touch_jump = touch_jump
	# Lane F1 star: collect on touch. Real play only (persist_stats),
	# never while dead or after the win — and collecting is optional:
	# it never gates the door/exit.
	if persist_stats and _star != null and is_instance_valid(_star) and not _star.collected \
			and player != null and is_instance_valid(player) \
			and not runtime.dead and not level_completed:
		if player.player_rect().intersects(_star.collect_rect()):
			_star.collected = true
			_star.visible = false
			TTProgress.collect_star(_star_id)
			TTProgress.check_achievements(_level_ids)
			TTAudio.play_skip()
			_star = null
	if runtime.level_completed and not _win_saved:
		_win_saved = true
		TTAudio.play_win()
		# EXCEED: door-enter celebration — confetti burst at the door
		# (the reference has no celebration at all). The wipe is
		# DELAYED so the burst is actually visible: the win delay
		# is 0.9s and the wipe only starts covering at 0.3s left,
		# so the player sees ~0.6s of confetti before the transition.
		if _confetti != null and builder != null and builder.door != null:
			_confetti.spawn_burst(builder.door.centre)
		if not levels.is_empty():
			if _is_daily:
				# Daily win: no tower progress at all — the daily
				# best is recorded below (record_win), and the map
				# returns plain (no door picker for a daily level).
				TTState.return_door = -1
			elif _is_bonus:
				TTProgress.complete_bonus_level(str(current_level.get("id", "")), level_index, levels.size())
				# Bonus win returns to the BONUS door picker (45).
				TTState.return_door = 45
			elif _is_nightmare:
				# Nightmare win: per-level nightmare progress only
				# (separate file) — never complete_level or
				# best_times, so normal progress is untouched. The
				# door picker reopens and stays nightmare-armed.
				TTNightmare.record_win(str(current_level.get("id", "")))
				TTState.return_door = TTDoorMap.door_of(level_index)
			else:
				TTProgress.complete_level(str(current_level.get("id", "")), level_index, levels.size())
				# v1.0.5: return to this level's door picker (on the map),
				# set BEFORE the win delay — never auto-advance to a level.
				TTState.return_door = TTDoorMap.door_of(level_index)
				# A normal win can be the 215th: unlock Nightmare.
				TTNightmare.refresh_unlock()
			_win_delay = 0.9
			_wipe_started = false
		if persist_stats and not _is_bonus:
			# Best time + ghost (only the fastest run is kept) +
			# achievement check. Called AFTER complete_level so the
			# door achievements see this win. In verifier mode the
			# id list is just this level, so door checks stay safe.
			# NOTE: _win_delay stays -1 in verifier mode (levels
			# empty), exactly as before — the scene must NOT change
			# under the autopilot / probes.
			# Lane F2: daily records ONLY the daily best (no
			# best_times/ghost for a daily id); nightmare records
			# nothing here (its progress is already saved above).
			if _is_daily:
				TTDaily.record_win(_daily_date, _attempt_time)
			elif not _is_nightmare:
				var ids_for_eval: Array = _level_ids if not _level_ids.is_empty() else [str(current_level.get("id", ""))]
				TTProgress.record_level_win(str(current_level.get("id", "")), _attempt_time, _ghost_rec, ids_for_eval)
			_flush_session_time()


func _process(delta: float) -> void:
	# Lane F3: the ghost replays on the attempt clock, so it stays
	# in sync with the hero across death-retry resets.
	if _ghost_node != null and is_instance_valid(_ghost_node):
		_ghost_node.playback_time = _attempt_time
	# Hero-less beat after the level-start transition: the hero
	# appears once the beat expires (physics already running).
	if _hero_beat > 0.0:
		_hero_beat -= delta
		if _hero_beat <= 0.0:
			_hero_beat = -1.0
			if player != null and is_instance_valid(player):
				if runtime == null or not bool(runtime.get("dead")):
					player.visible = true
	if _win_delay < 0.0:
		return
	_win_delay -= delta
	# EXCEED: the win wipe starts only at 0.3s left, so the door
	# confetti plays uncovered for ~0.6s first. The skip path covers
	# immediately (it sets _wipe_started), so this never re-fires.
	if _win_delay <= 0.3 and not _wipe_started:
		_wipe_started = true
		if _wipe != null:
			_wipe.cover()
	if _win_delay > 0.0:
		return
	_win_delay = -1.0
	get_tree().paused = false
	_paused = false
	# Win and skip both return to the map. There is no auto-chain
	# into the next level.
	get_tree().change_scene_to_file("res://scenes/map.tscn")


func _flush_session_time() -> void:
	if not persist_stats or _session_time <= 0.0:
		_session_time = 0.0
		return
	TTProgress.add_play_time(_session_time)
	_session_time = 0.0


func _set_ghost_visible(v: bool) -> void:
	_ghost_on = v
	if _ghost_node != null and is_instance_valid(_ghost_node):
		_ghost_node.set_ghost_visible(v)
	if hud != null and is_instance_valid(hud):
		hud.set_ghost(v)
	if _pause_ghost_btn != null and is_instance_valid(_pause_ghost_btn):
		_pause_ghost_btn.text = "GHOST ON" if v else "GHOST OFF"
		_pause_ghost_btn.queue_redraw()
	if persist_stats:
		TTProgress.set_ghost_visible(v)


func _on_pause_ghost_toggle() -> void:
	_set_ghost_visible(not _ghost_on)


func pause_game() -> void:
	if _error or _paused:
		return
	_paused = true
	if _pause_overlay != null:
		_pause_overlay.visible = true
	get_tree().paused = true


func resume_game() -> void:
	if not _paused:
		return
	_paused = false
	if _pause_overlay != null:
		_pause_overlay.visible = false
	get_tree().paused = false


func restart_level() -> void:
	_flush_session_time()
	get_tree().paused = false
	_paused = false
	if _pause_overlay != null:
		_pause_overlay.visible = false
	if levels.is_empty():
		if current_level.is_empty():
			return
		_build_from_dict(current_level, tuning, 0)
	else:
		_build_from_dict(levels[level_index], tuning, level_index)


func _on_pause_button() -> void:
	if _paused:
		resume_game()
	else:
		pause_game()


func _on_skip_pressed() -> void:
	if levels.is_empty() or _win_saved or _win_delay >= 0.0:
		return
	if deaths < 3:
		return
	# Unpause first: _process (which returns to the map) is frozen
	# while paused.
	resume_game()
	# Skip unlocks the next level WITHOUT marking this one complete
	# and WITHOUT the win sound, then returns to the map like a win.
	# EXCEED: the skip gets its own two-note chirp.
	TTAudio.play_skip()
	_flush_session_time()
	if _is_daily:
		# Daily skip: no progress effect at all, plain map return.
		TTState.return_door = -1
	elif _is_bonus:
		TTProgress.unlock_bonus_level(level_index, levels.size())
		# Bonus skip returns to the BONUS door picker (45).
		TTState.return_door = 45
	else:
		TTProgress.unlock_level(level_index, levels.size())
		# v1.0.5: return to this level's door picker (on the map), set
		# BEFORE the return delay — never auto-advance to a level.
		TTState.return_door = TTDoorMap.door_of(level_index)
	_win_saved = true
	if _wipe != null:
		_wipe.cover()
	_wipe_started = true
	_win_delay = 0.3


func _exit_to_map() -> void:
	# v1.0.5: pause exit / ESC exit returns to a PLAIN map — no picker.
	_flush_session_time()
	TTState.return_door = -1
	get_tree().paused = false
	_paused = false
	# Original wipe covers the exit before the scene changes.
	if _wipe != null:
		await _wipe.cover()
	get_tree().change_scene_to_file("res://scenes/map.tscn")


func _show_error(msg: String) -> void:
	_error = true
	push_error("Trap Tower: " + msg)
	var label := Label.new()
	label.text = "Level data error:\n" + msg
	label.position = Vector2(80, 200)
	label.size = Vector2(1120, 200)
	label.add_theme_font_size_override("font_size", 32)
	add_child(label)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			_exit_to_map()
