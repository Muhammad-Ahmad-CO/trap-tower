# DRAFT screenshot driver (Lane Vis, Round 4). Renders the REAL game
# scene through build_level with hand-written v3-valid fixture levels
# (original geometry, visual fixtures only — NOT shipped levels), plus
# a standalone render of the map island art (MapArt + LevelNode inner
# classes) and a pixel-font specimen.
#
# WHY A DRIVER: the shipped levels.json is still schema v2 (Lane F's
# v3 file has not landed) and the frozen v3 runtime fail-fasts on it,
# so res://scenes/screenshot.tscn and the real map scene cannot run
# yet. This driver proves the VISUAL systems now (chevrons, HUD,
# pixel font, hero, door, death burst, pause, skip, island map) and
# the FINAL screenshots must be re-taken with screenshot.tscn against
# the new v3 file when it lands. Every shot here is labelled DRAFT.
#
# Run (real rendering, NOT headless):
#   xvfb-run -a <godot> --path <project> -s tools/probes/draft_shots_r4.gd -- --out <dir>
extends SceneTree

var _out_dir := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		if args[i] == "--out" and i + 1 < args.size():
			_out_dir = args[i + 1]
			i += 2
		else:
			i += 1
	if _out_dir == "":
		_out_dir = OS.get_environment("HOME") + "/workspace/trap-tower/verification/screenshots-r4"
	call_deferred("_run")


func _flat() -> Dictionary:
	return {"id": "DRAFT-FLAT", "palette": 0, "template": "draft", "variation": "flat",
		"spawn": {"x": 150, "y": 360}, "door": {"x": 1150, "y": 360},
		"platforms": [{"x": 0, "y": 360, "w": 1280, "h": 360, "kind": "solid"}],
		"hazards": [
			{"type": "spikes", "x": 380, "y": 350, "w": 80, "h": 10, "dir": "up"},
			{"type": "spikes", "x": 640, "y": 350, "w": 80, "h": 10, "dir": "up"},
			{"type": "spikes", "x": 900, "y": 350, "w": 80, "h": 10, "dir": "up"},
		]}


func _stairs() -> Dictionary:
	# Gold palette (12): HUD-contrast proof on a light-gold level.
	return {"id": "DRAFT-STAIRS", "palette": 12, "template": "draft", "variation": "stairs",
		"spawn": {"x": 150, "y": 380}, "door": {"x": 1150, "y": 380},
		"platforms": [
			{"x": 0, "y": 680, "w": 1280, "h": 40, "kind": "solid"},
			{"x": 0, "y": 380, "w": 300, "h": 340, "kind": "solid"},
			{"x": 300, "y": 480, "w": 150, "h": 240, "kind": "solid"},
			{"x": 450, "y": 580, "w": 150, "h": 140, "kind": "solid"},
			{"x": 680, "y": 580, "w": 150, "h": 140, "kind": "solid"},
			{"x": 830, "y": 480, "w": 150, "h": 240, "kind": "solid"},
			{"x": 980, "y": 380, "w": 300, "h": 340, "kind": "solid"},
		],
		"hazards": [
			{"type": "spikes", "x": 600, "y": 670, "w": 60, "h": 10, "dir": "up"},
			{"type": "spikes", "x": 830, "y": 470, "w": 60, "h": 10, "dir": "up"},
		]}


func _tower() -> Dictionary:
	return {"id": "DRAFT-TOWER", "palette": 4, "template": "draft", "variation": "tower",
		"spawn": {"x": 200, "y": 680}, "door": {"x": 1150, "y": 680},
		"platforms": [
			{"x": 0, "y": 680, "w": 1280, "h": 40, "kind": "solid"},
			{"x": 0, "y": 90, "w": 120, "h": 630, "kind": "solid"},
			{"x": 560, "y": 90, "w": 80, "h": 590, "kind": "solid"},
			{"x": 760, "y": 200, "w": 80, "h": 480, "kind": "solid"},
		],
		"hazards": [
			{"type": "spikes", "x": 900, "y": 670, "w": 60, "h": 10, "dir": "up"},
			{"type": "saw", "x": 700, "y": 620, "w": 48, "h": 48, "r": 24},
		]}


func _maze() -> Dictionary:
	# Dark palette (35): hero-outline proof (luminance-gated outline).
	return {"id": "DRAFT-MAZE", "palette": 35, "template": "draft", "variation": "maze",
		"spawn": {"x": 100, "y": 680}, "door": {"x": 1000, "y": 420},
		"platforms": [
			{"x": 0, "y": 680, "w": 1280, "h": 40, "kind": "solid"},
			{"x": 200, "y": 440, "w": 48, "h": 240, "kind": "solid"},
			{"x": 1032, "y": 440, "w": 48, "h": 240, "kind": "solid"},
			{"x": 200, "y": 420, "w": 880, "h": 20, "kind": "solid"},
			{"x": 0, "y": 200, "w": 500, "h": 20, "kind": "solid"},
			{"x": 452, "y": 220, "w": 48, "h": 460, "kind": "solid"},
		],
		"hazards": [
			{"type": "spikes", "x": 500, "y": 670, "w": 80, "h": 10, "dir": "up"},
			{"type": "spikes", "x": 700, "y": 410, "w": 60, "h": 10, "dir": "up"},
		]}


func _pit() -> Dictionary:
	# Falling + tilting segments flush with the floor: at rest they
	# must read as ONE continuous floor (no seam, no marker).
	return {"id": "DRAFT-PIT", "palette": 0, "template": "draft", "variation": "pit",
		"spawn": {"x": 150, "y": 680}, "door": {"x": 1150, "y": 680},
		"platforms": [
			{"x": 0, "y": 680, "w": 500, "h": 40, "kind": "solid"},
			{"x": 500, "y": 680, "w": 200, "h": 40, "kind": "falling", "stand_time": 0.5},
			{"x": 700, "y": 680, "w": 200, "h": 40, "kind": "tilting", "stand_time": 0.5},
			{"x": 900, "y": 680, "w": 380, "h": 40, "kind": "solid"},
		],
		"hazards": [
			{"type": "spikes", "x": 950, "y": 670, "w": 60, "h": 10, "dir": "up"},
		]}


func _trigger() -> Dictionary:
	# Trigger-gated spikes: invisible until the player crosses
	# trigger_x, then they pop out over ~0.1s.
	return {"id": "DRAFT-TRIGGER", "palette": 0, "template": "draft", "variation": "trigger",
		"spawn": {"x": 150, "y": 680}, "door": {"x": 1150, "y": 680},
		"platforms": [{"x": 0, "y": 680, "w": 1280, "h": 40, "kind": "solid"}],
		"hazards": [
			{"type": "spikes", "x": 700, "y": 670, "w": 80, "h": 10, "dir": "up", "trigger_x": 500, "delay": 0.25},
		]}


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
	print("DRAFT SHOT saved ", path, " err=", err, " size=", img.get_size())


func _remove(inst: Node) -> void:
	root.remove_child(inst)
	inst.queue_free()
	await process_frame
	await process_frame


func _send_retry_key() -> void:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.echo = false
	ev.keycode = KEY_ENTER
	ev.physical_keycode = KEY_ENTER
	Input.parse_input_event(ev)


func _kill(game_inst: Node) -> bool:
	var player := game_inst.get("player") as Node2D
	var runtime: Node = game_inst.get("runtime")
	if player == null or runtime == null:
		return false
	var target := Vector2.ZERO
	for h in (runtime.get("hazards") as Array):
		if str(h.get("htype")) == "spikes":
			target = (h.get("rect") as Rect2).get_center()
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


func _wait_alive(game_inst: Node) -> bool:
	var runtime: Node = game_inst.get("runtime")
	for f in range(60):
		await physics_frame
		if not bool(runtime.get("dead")):
			return true
	return false


func _run() -> void:
	var derr := DirAccess.make_dir_recursive_absolute(_out_dir)
	if derr != OK:
		print("DRAFT SHOT ERROR: cannot create out dir ", _out_dir)
		quit(1)
		return
	var tuning: Dictionary = TTuning.load_tuning()
	var game_scene: PackedScene = load("res://scenes/game.tscn")
	var fixtures: Array = [_flat(), _stairs(), _tower(), _maze(), _pit(), _trigger()]
	for lv in fixtures:
		var err := TTLevelData.validate_level(lv, 0, tuning)
		if err != "":
			print("DRAFT SHOT ERROR: fixture ", str(lv.get("id", "?")), " invalid: ", err)
			quit(1)
			return
	print("DRAFT fixtures validated: ", fixtures.size())

	# Gameplay shots, one real game instance each.
	for lv in fixtures:
		var game_inst: Node = game_scene.instantiate()
		root.add_child(game_inst)
		await physics_frame
		await physics_frame
		game_inst.call("build_level", lv, tuning)
		await _settle(1.0)
		await _capture_now(_out_dir + "/draft_" + str(lv.get("id", "?")) + ".png")
		await _remove(game_inst)

	# Death / pause / skip states on the flat fixture (real paths).
	var flat: Dictionary = _flat()
	var game2: Node = game_scene.instantiate()
	root.add_child(game2)
	await physics_frame
	await physics_frame
	game2.call("build_level", flat, tuning)
	await _settle(1.0)
	game2.call("pause_game")
	await _capture_now(_out_dir + "/draft_pause.png")
	game2.call("resume_game")
	await _settle(0.2)
	if not await _kill(game2):
		print("DRAFT SHOT ERROR: could not force a real hazard death")
		quit(1)
		return
	# Capture immediately: burst lives ~0.3s, prompt + hidden HUD.
	await _capture_now(_out_dir + "/draft_death.png")
	_send_retry_key()
	if not await _wait_alive(game2):
		print("DRAFT SHOT ERROR: retry did not respawn")
		quit(1)
		return
	for k in range(2):
		if not await _kill(game2):
			print("DRAFT SHOT ERROR: could not force death ", k + 2)
			quit(1)
			return
		_send_retry_key()
		if not await _wait_alive(game2):
			print("DRAFT SHOT ERROR: retry ", k + 2, " did not respawn")
			quit(1)
			return
	await _settle(0.3)
	var hud: Node = game2.get("hud")
	print("DRAFT skip visible=", hud.call("is_skip_visible"), " deaths=", game2.get("deaths"))
	await _capture_now(_out_dir + "/draft_skip.png")
	await _remove(game2)

	# Wipe mid-reveal + pressed-chevron states on the flat fixture.
	var game3: Node = game_scene.instantiate()
	root.add_child(game3)
	await physics_frame
	await physics_frame
	game3.call("build_level", flat, tuning)
	await _settle(1.0)
	# The driver builds the level directly (no map cover first), so
	# play cover -> reveal explicitly and catch the wipe mid-reveal
	# (idle frames, not physics frames: the wipe animates in _process).
	var wipe: Node = game3.get("_wipe")
	await wipe.cover()
	await _capture_now(_out_dir + "/draft_wipe_cover.png")
	# Frozen mid-reveal: under Xvfb each frame takes ~0.1s of real
	# time, so the 0.13s reveal completes in 1-2 frames and can never
	# be caught live. Freeze the REAL _draw at a real intermediate
	# frac (0.55) instead — same panels + yellow leading edges the
	# player sees mid-transition.
	wipe.set("_animating", false)
	wipe.set("_frac", 0.55)
	wipe.set_process(false)
	wipe.queue_redraw()
	for _i in range(2):
		await process_frame
	var wimg: Image = root.get_texture().get_image()
	wimg.save_png(_out_dir + "/draft_wipe.png")
	print("DRAFT SHOT saved: ", _out_dir + "/draft_wipe.png")
	await _settle(1.0)
	var press := InputEventScreenTouch.new()
	press.pressed = true
	press.index = 0
	press.position = Vector2(1055, 635)
	Input.parse_input_event(press)
	await _settle(0.15)
	await _capture_now(_out_dir + "/draft_pressed.png")
	press.pressed = false
	Input.parse_input_event(press)
	await _remove(game3)

	# Triggered-spike pop-out: invisible before the trigger, half
	# teeth mid-pop (~0.05s after activation), full teeth after.
	var trig: Dictionary = _trigger()
	var game4: Node = game_scene.instantiate()
	root.add_child(game4)
	await physics_frame
	await physics_frame
	game4.call("build_level", trig, tuning)
	await _settle(1.0)
	await _capture_now(_out_dir + "/draft_trigger_before.png")
	var tplayer := game4.get("player") as Node2D
	tplayer.global_position = Vector2(520, 660)
	tplayer.set("velocity", Vector2.ZERO)
	# Pop starts at trigger+delay (0.25s) and takes 0.1s: capture
	# IMMEDIATELY at 0.28s (pop ~0.3, ~3px teeth) — _capture_now's
	# own 4-frame wait would overshoot into full teeth.
	await _settle(0.28)
	var pimg: Image = root.get_texture().get_image()
	pimg.save_png(_out_dir + "/draft_trigger_pop.png")
	print("DRAFT SHOT saved: ", _out_dir + "/draft_trigger_pop.png")
	await _settle(0.15)
	await _capture_now(_out_dir + "/draft_trigger_after.png")
	await _remove(game4)

	# Standalone map-island render (real MapArt + LevelNode classes):
	# the real map scene cannot run until the v3 levels.json lands.
	var map_script: GDScript = load("res://scripts/map.gd")
	var art: Control = (map_script.MapArt as GDScript).new()
	var wrap := Control.new()
	wrap.position = Vector2.ZERO
	wrap.size = Vector2(1280, 720)
	var bg := ColorRect.new()
	bg.color = Color.html("2B0A8A")
	bg.position = Vector2.ZERO
	bg.size = Vector2(1280, 720)
	wrap.add_child(bg)
	# The real map puts the island inside a ScrollContainer at
	# y=104: render the same offset here so the title/credit clear
	# the first node row exactly like the real scene.
	var screen := Control.new()
	screen.position = Vector2(0, 104)
	screen.size = Vector2(1280, 616)
	screen.clip_contents = true
	wrap.add_child(screen)
	art.island_col = Color.html("E8871E")
	art.island_edge_col = Color.html("E8871E").darkened(0.25)
	art.dot_col = Color.html("2B0A8A")
	art.nodes_per_row = 9
	art.content_h = 720.0
	art.position = Vector2.ZERO
	art.size = Vector2(1280, 720)
	screen.add_child(art)
	var centres: Array[Vector2] = []
	for idx in range(27):
		var row := idx / 9
		var slot := idx % 9
		var col := slot if row % 2 == 0 else 8 - slot
		var jx := (sin(float(idx) * 12.9898 + 78.233) * 43758.5453)
		jx = (jx - floor(jx) - 0.5) * 56.0
		var jy := (sin(float(idx) * 12.9898 + 156.466) * 43758.5453)
		jy = (jy - floor(jy) - 0.5) * 22.0
		var x := clampf(57.0 + float(col) * 132.0 + jx, 20.0, 1280.0 - 130.0)
		var y := 60.0 + float(row) * 140.0 + jy
		centres.append(Vector2(x + 55.0, y + 62.0))
	art.centres = centres
	art.current_centre = centres[7]
	for idx in range(27):
		var node: Control = (map_script.LevelNode as GDScript).new()
		node.level = idx
		node.locked = idx > 7
		node.current = idx == 7
		node.done = idx < 7
		if node.locked:
			node.fill = Color.html("7C2D12").lerp(Color.html("E8871E"), 0.45)
			node.outline_col = Color(1, 1, 1, 0.55)
			node.number_col = Color(1, 1, 1, 0.6)
		else:
			node.fill = Color.html("2B0A8A") if idx % 2 == 0 else Color.html("7C2D12")
			node.outline_col = Color.WHITE
			node.number_col = Color.WHITE
		node.position = centres[idx] - Vector2(55.0, 62.0)
		node.size = Vector2(110, 110)
		screen.add_child(node)
	var title := TTPixelLabel.new()
	title.text = "TRAP TOWER"
	title.pixel_size = 9
	title.color = Color.html("E8871E")
	title.align = HORIZONTAL_ALIGNMENT_CENTER
	title.width = 1280.0
	title.position = Vector2(0, 16)
	wrap.add_child(title)
	var credit := TTPixelLabel.new()
	credit.text = "Made by Ahmed"
	credit.pixel_size = 3
	credit.color = Color.html("E8871E")
	credit.align = HORIZONTAL_ALIGNMENT_CENTER
	credit.width = 1280.0
	credit.position = Vector2(0, 84)
	wrap.add_child(credit)
	root.add_child(wrap)
	await _settle(0.6)
	await _capture_now(_out_dir + "/draft_map.png")
	await _remove(wrap)

	# Pixel-font specimen: every size the game uses, on one panel.
	var spec := Control.new()
	spec.position = Vector2.ZERO
	spec.size = Vector2(1280, 720)
	var sbg := ColorRect.new()
	sbg.color = Color.html("1A1A2E")
	sbg.position = Vector2.ZERO
	sbg.size = Vector2(1280, 720)
	spec.add_child(sbg)
	var rows: Array = [
		["TRAP TOWER", 9, Color.html("E8871E"), 40.0],
		["Made by Ahmed", 4, Color.html("E8871E"), 130.0],
		["TAP TO RETRY", 5, Color.html("FFD23F"), 200.0],
		["SKIP >>", 5, Color.html("FFD23F"), 260.0],
		["37", 5, Color.html("FFD23F"), 320.0],
		["SETTINGS  SOUND  MUSIC  ON  OFF  CLOSE", 5, Color.WHITE, 380.0],
		["0123456789", 5, Color.WHITE, 440.0],
		["abcdefghijklmnopqrstuvwxyz", 4, Color.WHITE, 510.0],
		["ABCDEFGHIJKLMNOPQRSTUVWXYZ", 4, Color.WHITE, 560.0],
		["Level data error", 5, Color.html("FFD23F"), 620.0],
	]
	for r in rows:
		var lab := TTPixelLabel.new()
		lab.text = str(r[0])
		lab.pixel_size = int(r[1])
		lab.color = r[2]
		lab.align = HORIZONTAL_ALIGNMENT_CENTER
		lab.width = 1280.0
		lab.position = Vector2(0, float(r[3]))
		spec.add_child(lab)
	root.add_child(spec)
	await _settle(0.4)
	await _capture_now(_out_dir + "/draft_font_specimen.png")
	await _remove(spec)

	print("DRAFT SHOT DONE")
	quit(0)
