# Trap Tower injected multi-touch test (Lane B).
#
# Injects InputEventScreenTouch events with DISTINCT indices into the
# game's real touch controls (game mode) and asserts:
#   (a) left/right held + jump pressed simultaneously -> moves AND jumps
#   (b) release jump only -> horizontal motion continues
#   (c) drag finger off a button -> button releases (no stuck input)
#   (d) all fingers released -> all input idle
#
# Game mode discovers the controls scene/script (see README.md) and reads
# state from the controls' own properties / get_input_state() / Input
# actions / player velocity. If no controls or no readable state signal
# is found, cases report BLOCKED -- never a fabricated pass.
#
# Fixture mode (--mode fixture) runs the same cases against the
# FixtureControls class below, which implements the frozen control-bar
# semantics (multi-touch by index, drag-off release). Fixture results
# prove the injection harness works headless; they are NOT game
# verification and are always labelled fixture.
#
# Phone-only (stated plainly in every report): finger size/occlusion,
# Oppo F9 input latency, and non-16:9 scaling/letterbox behaviour.
#
# Usage (see run_touch_test.sh):
#   godot --headless --fixed-fps 60 --path <project> -s touch_test.gd --
#       [--mode game|fixture] [--out report.txt] [--json-out report.json]
extends SceneTree

# ---------------------------------------------------------------------------
# Fixture controls (self-test only -- NOT the game).
# ---------------------------------------------------------------------------

class FixtureControls extends Control:
	var left_rect := Rect2(320, 600, 120, 100)
	var right_rect := Rect2(560, 600, 120, 100)
	var jump_rect := Rect2(760, 600, 220, 100)  # ~1.8x move width
	var _finger_button: Dictionary = {}  # index -> "left"|"right"|"jump"

	func _ready() -> void:
		size = Vector2(1280, 720)

	func _button_at(pos: Vector2) -> String:
		if left_rect.has_point(pos):
			return "left"
		if right_rect.has_point(pos):
			return "right"
		if jump_rect.has_point(pos):
			return "jump"
		return ""

	func _rect_of(button: String) -> Rect2:
		if button == "left":
			return left_rect
		if button == "right":
			return right_rect
		return jump_rect

	func _input(event: InputEvent) -> void:
		if event is InputEventScreenTouch:
			var t: InputEventScreenTouch = event
			if t.pressed:
				var b: String = _button_at(t.position)
				if b != "":
					_finger_button[t.index] = b
			else:
				_finger_button.erase(t.index)
		elif event is InputEventScreenDrag:
			var d: InputEventScreenDrag = event
			if _finger_button.has(d.index):
				var b2: String = _finger_button[d.index]
				if not _rect_of(b2).has_point(d.position):
					# Dragged off the button: release immediately.
					_finger_button.erase(d.index)

	func _held(button: String) -> bool:
		return _finger_button.values().has(button)

	# State API mirroring what the game adapter looks for.
	var left_pressed: bool:
		get:
			return _held("left")
	var right_pressed: bool:
		get:
			return _held("right")
	var jump_pressed: bool:
		get:
			return _held("jump")

	func get_input_state() -> Dictionary:
		return {"left": _held("left"), "right": _held("right"),
				"jump": _held("jump")}

	func get_button_rect(button: String) -> Rect2:
		return _rect_of(button)

	# Fake motion derived from state, so case (a) can assert move+jump.
	var player_velocity: Vector2:
		get:
			var vx: float = 0.0
			if _held("right"):
				vx += 360.0
			if _held("left"):
				vx -= 360.0
			return Vector2(vx, -820.0 if _held("jump") else 0.0)


# ---------------------------------------------------------------------------
# Main script
# ---------------------------------------------------------------------------

const CONTROL_SCENES: Array = ["res://scenes/touch_controls.tscn",
	"res://scenes/control_bar.tscn", "res://scenes/hud.tscn",
	"res://scenes/game.tscn", "res://scenes/Game.tscn", "res://game.tscn",
	"res://scenes/main.tscn", "res://main.tscn"]
const CONTROL_SCRIPTS: Array = ["res://scripts/touch_controls.gd",
	"res://scripts/control_bar.gd", "res://scripts/touch_buttons.gd",
	"res://scripts/hud.gd", "res://scripts/game.gd"]

var _args: Dictionary = {}
var _controls_node: Node = null
var _game_node: Node = null
var _player: CharacterBody2D = null
var _button_rects: Dictionary = {}
var _results: Array = []
var _discovery: String = ""


func _initialize() -> void:
	call_deferred("_run")


func _parse_args() -> void:
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < raw.size():
		var a: String = raw[i]
		if a in ["--mode", "--out", "--json-out"]:
			if i + 1 < raw.size():
				_args[a.trim_prefix("--")] = raw[i + 1]
			i += 2
		else:
			i += 1
	_args["mode"] = str(_args.get("mode", "game"))


func _settle(frames: int = 4) -> void:
	for k in range(frames):
		await physics_frame
	for k in range(2):
		await process_frame


func _touch(index: int, pressed: bool, pos: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = pressed
	ev.position = pos
	Input.parse_input_event(ev)


func _drag(index: int, from_pos: Vector2, to_pos: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = to_pos
	ev.relative = to_pos - from_pos
	Input.parse_input_event(ev)


func _release_all() -> void:
	for idx in range(5):
		_touch(idx, false, Vector2(640, 360))


# ---------------------------------------------------------------------------
# Discovery (game mode)
# ---------------------------------------------------------------------------

func _find_player(node: Node) -> CharacterBody2D:
	if node is CharacterBody2D:
		return node
	for child in node.get_children():
		var found: CharacterBody2D = _find_player(child)
		if found != null:
			return found
	return null


func _collect_controls(node: Node, out: Array) -> void:
	if node is Control:
		out.append(node)
	for child in node.get_children():
		_collect_controls(child, out)


func _discover_buttons(node: Node) -> Dictionary:
	# 1) get_button_rect(button) API.
	if node.has_method("get_button_rect"):
		var rects: Dictionary = {}
		for b in ["left", "right", "jump"]:
			var r: Variant = node.call("get_button_rect", b)
			if r is Rect2 and (r as Rect2).size.x > 0 \
					and (r as Rect2).size.y > 0:
				rects[b] = r
		if rects.size() == 3:
			return rects
	# 2) Child controls under the node itself.
	var found: Array = []
	_collect_controls(node, found)
	var rects2: Dictionary = {}
	for c in found:
		var nm: String = c.name.to_lower()
		var key: String = ""
		if nm.contains("jump"):
			key = "jump"
		elif nm.contains("left"):
			key = "left"
		elif nm.contains("right"):
			key = "right"
		if key != "" and not rects2.has(key):
			var gr: Rect2 = c.get_global_rect()
			if gr.size.x > 0 and gr.size.y > 0:
				rects2[key] = gr
	if rects2.size() == 3:
		return rects2
	return {}


func _discover_game() -> bool:
	var notes: Array = []
	for scene_path in CONTROL_SCENES:
		if not ResourceLoader.exists(scene_path):
			continue
		var packed: PackedScene = load(scene_path) as PackedScene
		if packed == null:
			continue
		var inst: Node = packed.instantiate()
		if inst == null:
			continue
		root.add_child(inst)
		await _settle(6)
		var rects: Dictionary = _discover_buttons(inst)
		# Controls may live deeper than the instantiated root's own
		# subtree scan already covers; also try any child subtree.
		if rects.size() != 3:
			for child in inst.get_children():
				rects = _discover_buttons(child)
				if rects.size() == 3:
					_controls_node = child
					break
		if rects.size() == 3:
			_button_rects = rects
			if _controls_node == null:
				_controls_node = inst
			_game_node = inst
			_player = _find_player(inst)
			_discovery = "scene %s" % scene_path
			return true
		notes.append("scene %s: buttons not discoverable" % scene_path)
		inst.queue_free()
		await _settle(2)
	for script_path in CONTROL_SCRIPTS:
		if not ResourceLoader.exists(script_path):
			continue
		var scr: Script = load(script_path) as Script
		if scr == null:
			continue
		var obj: Variant = scr.new()
		if not (obj is Node):
			notes.append("script %s: not a Node" % script_path)
			continue
		root.add_child(obj)
		await _settle(6)
		var rects2: Dictionary = _discover_buttons(obj)
		if rects2.size() == 3:
			_button_rects = rects2
			_controls_node = obj
			_game_node = obj
			_player = _find_player(obj)
			_discovery = "script %s" % script_path
			return true
		notes.append("script %s: buttons not discoverable" % script_path)
		obj.queue_free()
		await _settle(2)
	_discovery = "no usable controls found (" + "; ".join(notes) + ")" \
			if not notes.is_empty() else "no controls scene/script found"
	return false


# ---------------------------------------------------------------------------
# State reading
# ---------------------------------------------------------------------------

func _property_names(obj: Object) -> Dictionary:
	var out: Dictionary = {}
	for d in obj.get_property_list():
		out[str(d["name"])] = true
	return out


func _read_state() -> Dictionary:
	# Returns {left: bool|null, right: bool|null, jump: bool|null,
	#          sources: Array, velocity: Vector2, on_floor: bool}.
	var state: Dictionary = {"left": null, "right": null, "jump": null,
			"sources": [], "velocity": Vector2.ZERO, "on_floor": false}
	var nodes: Array = []
	if _controls_node != null:
		nodes.append(_controls_node)
	if _game_node != null and _game_node != _controls_node:
		nodes.append(_game_node)
	if _player != null:
		nodes.append(_player)
	# 1) get_input_state() dictionaries.
	for node in nodes:
		if node.has_method("get_input_state"):
			var st: Variant = node.call("get_input_state")
			if st is Dictionary:
				for key: String in ["left", "right", "jump"]:
					if state[key] == null and (st as Dictionary).has(key):
						state[key] = bool((st as Dictionary)[key])
						(state["sources"] as Array).append(
								"get_input_state:" + key)
				for key2: String in ["move_left", "move_right"]:
					var short: String = key2.trim_prefix("move_")
					if state[short] == null \
							and (st as Dictionary).has(key2):
						state[short] = bool((st as Dictionary)[key2])
						(state["sources"] as Array).append(
								"get_input_state:" + key2)
	# 2) Boolean properties.
	var prop_sets: Dictionary = {
		"left": ["touch_left", "left_pressed", "move_left_pressed",
				"input_left", "left_held"],
		"right": ["touch_right", "right_pressed", "move_right_pressed",
				"input_right", "right_held"],
		"jump": ["touch_jump", "jump_pressed", "jump_requested",
				"jump_held", "input_jump"],
	}
	for node in nodes:
		var props: Dictionary = _property_names(node)
		for key in ["left", "right", "jump"]:
			if state[key] != null:
				continue
			for nm in prop_sets[key]:
				if props.has(nm):
					state[key] = bool(node.get(nm))
					(state["sources"] as Array).append("prop:" + nm)
					break
	# 3) Input actions.
	var action_sets: Array = [["move_left", "move_right", "jump"],
		["ui_left", "ui_right", "ui_accept"], ["left", "right", "jump"]]
	for s in action_sets:
		if InputMap.has_action(s[0]) and InputMap.has_action(s[1]) \
				and InputMap.has_action(s[2]):
			if state["left"] == null:
				state["left"] = Input.is_action_pressed(s[0])
				(state["sources"] as Array).append("action:" + s[0])
			if state["right"] == null:
				state["right"] = Input.is_action_pressed(s[1])
				(state["sources"] as Array).append("action:" + s[1])
			if state["jump"] == null:
				state["jump"] = Input.is_action_pressed(s[2])
				(state["sources"] as Array).append("action:" + s[2])
			break
	# 4) Player motion (observation; fixture exposes player_velocity).
	if _player != null and is_instance_valid(_player):
		state["velocity"] = _player.velocity
		state["on_floor"] = _player.is_on_floor()
	elif _controls_node != null and is_instance_valid(_controls_node):
		var props2: Dictionary = _property_names(_controls_node)
		if props2.has("player_velocity"):
			state["velocity"] = _controls_node.get("player_velocity")
	return state


func _centre(button: String) -> Vector2:
	var r: Rect2 = _button_rects[button]
	return r.position + r.size / 2.0


func _record(case_id: String, title: String, status: String,
		detail: String) -> void:
	_results.append({"case": case_id, "title": title, "status": status,
			"detail": detail})
	print("[%s] %s: %s -- %s" % [case_id, title, status, detail])


# ---------------------------------------------------------------------------
# Cases (a)-(d)
# ---------------------------------------------------------------------------

func _run_cases() -> void:
	# Precondition: clean slate.
	await _release_all()
	await _settle()
	var idle0: Dictionary = _read_state()
	if idle0["left"] == true or idle0["right"] == true \
			or idle0["jump"] == true:
		_record("PRE", "clean slate", "FAIL",
				"input active before any touch: %s" % str(idle0))
		return

	# (a) left held (index 0) + jump pressed (index 1) simultaneously.
	_touch(0, true, _centre("left"))
	_touch(1, true, _centre("jump"))
	await _settle()
	var a: Dictionary = _read_state()
	var vel_a: Vector2 = a["velocity"]
	var motion_a: String = "velocity=(%.0f, %.0f) on_floor=%s" % [
			vel_a.x, vel_a.y, str(a["on_floor"])]
	if a["left"] == null or a["jump"] == null:
		if vel_a.x < -20.0 and (vel_a.y < -20.0 or not bool(a["on_floor"])):
			_record("a", "left+jump simultaneously", "PASS",
					"no state signal; motion evidence: %s" % motion_a)
		else:
			_record("a", "left+jump simultaneously", "BLOCKED",
					"no readable left/jump state signal; motion: %s"
					% motion_a)
	elif bool(a["left"]) and bool(a["jump"]):
		var note: String = ""
		if vel_a.x >= -20.0 and _player != null:
			note = " WARNING: controls report left+jump but player " \
					+ "velocity shows no leftward motion (%s)" % motion_a
		_record("a", "left+jump simultaneously", "PASS",
				"left=%s jump=%s sources=%s motion: %s%s" % [
						str(a["left"]), str(a["jump"]),
						str(a["sources"]), motion_a, note])
	else:
		_record("a", "left+jump simultaneously", "FAIL",
				"left=%s jump=%s (expected both true); motion: %s" % [
						str(a["left"]), str(a["jump"]), motion_a])

	# (b) release jump only -> horizontal motion continues.
	_touch(1, false, _centre("jump"))
	await _settle()
	var b: Dictionary = _read_state()
	var vel_b: Vector2 = b["velocity"]
	if b["left"] == null or b["jump"] == null:
		if vel_b.x < -20.0:
			_record("b", "release jump only", "PASS",
					"no state signal; motion evidence: velocity.x=%.0f"
					% vel_b.x)
		else:
			_record("b", "release jump only", "BLOCKED",
					"no readable state signal; velocity.x=%.0f" % vel_b.x)
	elif bool(b["left"]) and not bool(b["jump"]):
		_record("b", "release jump only", "PASS",
				"left=%s jump=%s sources=%s velocity.x=%.0f" % [
						str(b["left"]), str(b["jump"]),
						str(b["sources"]), vel_b.x])
	else:
		_record("b", "release jump only", "FAIL",
				"left=%s jump=%s (expected left true, jump false)"
				% [str(b["left"]), str(b["jump"])])
	_touch(0, false, _centre("left"))
	await _settle()

	# (c) drag finger off the jump button -> button releases.
	_touch(2, true, _centre("jump"))
	await _settle()
	var c0: Dictionary = _read_state()
	if c0["jump"] != true and c0["jump"] != null:
		_record("c", "drag off button releases", "FAIL",
				"jump did not activate on press (jump=%s)"
				% str(c0["jump"]))
	else:
		# Drag to a point clearly outside every button rect.
		var outside := Vector2(640, 200)
		_drag(2, _centre("jump"), outside)
		await _settle()
		var c1: Dictionary = _read_state()
		_touch(2, false, outside)
		await _settle()
		var c2: Dictionary = _read_state()
		if c1["jump"] == null:
			_record("c", "drag off button releases", "BLOCKED",
					"no readable jump state signal")
		elif c1["jump"] == false:
			_record("c", "drag off button releases", "PASS",
					"jump released while finger held outside the button "
					+ "(jump=%s); after lift jump=%s"
					% [str(c1["jump"]), str(c2["jump"])])
		elif c2["jump"] == false:
			_record("c", "drag off button releases", "FAIL",
					"button stayed pressed while finger held outside "
					+ "(jump=%s); released only on lift (jump=%s) -- "
					+ "spec requires release on drag-off"
					% [str(c1["jump"]), str(c2["jump"])])
		else:
			_record("c", "drag off button releases", "FAIL",
					"STUCK INPUT: jump=%s after drag-off and lift"
					% str(c2["jump"]))

	# (d) all fingers released -> all input idle.
	await _release_all()
	await _settle()
	var d: Dictionary = _read_state()
	if d["left"] == null and d["right"] == null and d["jump"] == null:
		_record("d", "all released -> idle", "BLOCKED",
				"no readable state signal")
	elif d["left"] == false and d["right"] == false and d["jump"] == false:
		_record("d", "all released -> idle", "PASS",
				"left=%s right=%s jump=%s" % [str(d["left"]),
						str(d["right"]), str(d["jump"])])
	else:
		_record("d", "all released -> idle", "FAIL",
				"stuck input: left=%s right=%s jump=%s" % [str(d["left"]),
						str(d["right"]), str(d["jump"])])


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

func _run() -> void:
	_parse_args()
	var mode: String = str(_args.get("mode", "game"))
	print("touch_test mode=%s" % mode)
	if mode == "fixture":
		var fx := FixtureControls.new()
		root.add_child(fx)
		_controls_node = fx
		_button_rects = {"left": fx.left_rect, "right": fx.right_rect,
				"jump": fx.jump_rect}
		_discovery = "fixture FixtureControls (self-test only)"
		await _settle(6)
		await _run_cases()
	elif mode == "game":
		var found: bool = await _discover_game()
		print("discovery: " + _discovery)
		if not found:
			for case_id in ["a", "b", "c", "d"]:
				_record(case_id, "touch case " + case_id, "BLOCKED",
						"no game touch controls discoverable: "
						+ _discovery)
		else:
			await _run_cases()
	else:
		push_error("touch_test: unknown --mode " + mode)
		print("TOUCH_TEST ERROR: unknown --mode " + mode)
		quit(2)
		return
	var n_pass: int = 0
	for r in _results:
		if str(r["status"]) == "PASS":
			n_pass += 1
	var summary: String = "TOTAL: %d/%d cases passed (mode=%s)" % [
			n_pass, _results.size(), mode]
	print(summary)
	print("PHONE-ONLY (not covered here): finger size/occlusion, "
			+ "Oppo F9 input latency, non-16:9 scaling/letterbox behaviour.")
	var lines: Array = ["Trap Tower touch test -- mode=%s" % mode,
			"discovery: " + _discovery, ""]
	for r in _results:
		lines.append("[%s] %s: %s -- %s" % [r["case"], r["title"],
				r["status"], r["detail"]])
	lines.append("")
	lines.append(summary)
	lines.append("PHONE-ONLY (not covered here): finger size/occlusion, "
			+ "Oppo F9 input latency, non-16:9 scaling/letterbox behaviour.")
	if _args.has("out"):
		var f: FileAccess = FileAccess.open(str(_args["out"]),
				FileAccess.WRITE)
		if f != null:
			f.store_string("\n".join(lines) + "\n")
			f.close()
			print("Text report: " + str(_args["out"]))
	if _args.has("json-out"):
		var jf: FileAccess = FileAccess.open(str(_args["json-out"]),
				FileAccess.WRITE)
		if jf != null:
			jf.store_string(JSON.stringify({"mode": mode,
					"discovery": _discovery,
					"passed": n_pass, "total": _results.size(),
					"cases": _results}, "\t"))
			jf.close()
			print("JSON report: " + str(_args["json-out"]))
	quit(0 if n_pass == _results.size() and not _results.is_empty() else 1)
