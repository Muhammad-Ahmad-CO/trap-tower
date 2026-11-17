extends SceneTree

# Headless smoke load: builds level node trees from IN-MEMORY test dicts
# (never touches levels.json) and prints OK/ERROR.
# Run: <godot> --headless --path <project> -s res://scripts/smoke_load.gd

func _initialize() -> void:
	var tuning: Dictionary = (load("res://scripts/tuning.gd") as GDScript).load_tuning()
	if tuning.is_empty():
		print("SMOKE ERROR: tuning.json missing or invalid")
		quit(1)
		return
	var data_script: GDScript = load("res://scripts/level_data.gd")
	var builder_script: GDScript = load("res://scripts/level_builder.gd")
	var lv1 := {
		"id": "L001", "palette": 4, "template": "smoke", "variation": "plain",
		"spawn": {"x": 70, "y": 500}, "door": {"x": 1210, "y": 500},
		"platforms": [{"x": 0, "y": 500, "w": 1280, "h": 80, "kind": "solid"}],
		"hazards": [],
	}
	var lv2 := {
		"id": "L002", "palette": 1, "template": "smoke", "variation": "dashed-popup",
		"spawn": {"x": 70, "y": 500}, "door": {"x": 1210, "y": 500},
		"platforms": [
			{"x": 0, "y": 500, "w": 560, "h": 80, "kind": "solid"},
			{"x": 380, "y": 420, "w": 120, "h": 20, "kind": "solid"},
			{"x": 580, "y": 470, "w": 80, "h": 16, "kind": "dashed", "period": 2.4, "phase": 0.0, "on_time": 1.6},
			{"x": 680, "y": 500, "w": 600, "h": 80, "kind": "solid"},
		],
		"hazards": [
			{"type": "spikes", "x": 300, "y": 476, "w": 120, "h": 24, "dir": "up", "period": 2.4, "phase": 0.0, "on_time": 1.2},
			{"type": "dotted_line", "x": 280, "y": 440, "w": 160, "h": 8, "linked": 0},
		],
	}
	var data := {"schema_version": 1, "tuning_version": 1, "levels": [lv1, lv2]}
	var err: String = data_script.validate_file(data, tuning)
	if err != "":
		print("SMOKE ERROR: validation failed: ", err)
		quit(1)
		return
	var bad := {"id": "LX", "palette": 0, "template": "smoke", "variation": "bad",
		"spawn": {"x": 70, "y": 500}, "door": {"x": 1210, "y": 500},
		"platforms": [{"x": 0, "y": 500, "w": 1280, "h": 80, "kind": "teleport"}],
		"hazards": []}
	if str(data_script.validate_level(bad, 0, tuning)) == "":
		print("SMOKE ERROR: unknown kind was not rejected")
		quit(1)
		return
	print("SMOKE negative check OK (unknown kind rejected)")
	for lv in [lv1, lv2]:
		var builder: RefCounted = builder_script.new()
		var built: Variant = builder.call("build_level", lv, tuning)
		if not (built is Node):
			print("SMOKE ERROR: build_level did not return a node for ", lv["id"])
			quit(1)
			return
		root.add_child(built)
		var player: CharacterBody2D = _find_player(built)
		if player == null:
			print("SMOKE ERROR: no CharacterBody2D player under built node for ", lv["id"])
			quit(1)
			return
		var plats: Array = builder.get("platforms")
		var hazards: Array = builder.get("hazards")
		print("SMOKE level ", lv["id"], ": platforms=", plats.size(), " hazards=", hazards.size(), " deaths=", built.get("deaths"), " completed=", built.get("level_completed"))
		if str(lv["id"]) == "L002":
			var kinds: Array = []
			for p in plats:
				kinds.append(p.kind)
			if not kinds.has("dashed"):
				print("SMOKE ERROR: dashed platform missing in build")
				quit(1)
				return
			var overlap := Rect2(330, 480, 28, 44)
			if not bool(hazards[0].kills(overlap)):
				print("SMOKE ERROR: pop-up spikes not lethal while up (t=0)")
				quit(1)
				return
			if bool(hazards[1].kills(overlap)):
				print("SMOKE ERROR: dotted_line killed (must never be lethal)")
				quit(1)
				return
			print("SMOKE L002 trap checks OK (dashed present, popup lethal, dotted safe)")
	for action in ["move_left", "move_right", "jump"]:
		if not InputMap.has_action(action) or InputMap.action_get_events(action).is_empty():
			print("SMOKE ERROR: input action missing or unbound: ", action)
			quit(1)
			return
	print("SMOKE input actions OK (move_left/move_right/jump bound)")
	var tc_scene: PackedScene = load("res://scenes/touch_controls.tscn")
	var tc: Node = tc_scene.instantiate()
	root.add_child(tc)
	for b in ["left", "right", "jump"]:
		var r: Rect2 = tc.call("get_button_rect", b)
		if r.size.x <= 0 or r.size.y <= 0:
			print("SMOKE ERROR: empty button rect for ", b)
			quit(1)
			return
	var st: Dictionary = tc.call("get_input_state")
	if not (st.has("left") and st.has("right") and st.has("jump")):
		print("SMOKE ERROR: get_input_state missing keys")
		quit(1)
		return
	print("SMOKE touch controls OK (3 button rects + get_input_state)")
	print("SMOKE OK: 2 levels built from in-memory dicts")
	quit(0)


func _find_player(node: Node) -> CharacterBody2D:
	if node is CharacterBody2D:
		return node
	for child in node.get_children():
		var found := _find_player(child)
		if found != null:
			return found
	return null
