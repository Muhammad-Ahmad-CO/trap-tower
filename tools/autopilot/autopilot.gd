# Trap Tower headless autopilot (Lane B).
#
# Plays every level in the SHIPPED godot/data/levels.json through REAL
# CharacterBody2D physics with the SHIPPED godot/data/tuning.json.
# Deterministic: fixed seed, fixed 60 Hz timestep (--fixed-fps 60).
#
# MODES (reported per level, never hidden):
#   game    -- level built through the game's real loader/builder code
#              (scene/script discovery, see _try_game_build). The player
#              is driven via Input actions or the game's own touch/input
#              properties. This is the only mode that counts toward the
#              VERIFIED count.
#   harness -- game builder not found: the level is built here from the
#              shipped JSON + shipped tuning with CharacterBody2D /
#              StaticBody2D / AnimatableBody2D nodes. Real physics, but
#              NOT the game's code paths: diagnostic evidence only.
#   blocked -- --mode game was forced and no game builder was found.
#
# Policy: greedy move-toward-door; jump on hazard/gap/wall/mount; WAIT on
# safe ground when a timed hazard blocks the path; up to 4 wait-offset
# strategies per level (offsets across one trap period). Death/timeout/
# no-progress retries the next strategy. All strategies failing = FAIL.
# On solid-ground approaches with only static hazards ahead, a ballistic
# planner replaces the fixed-lookahead jump trigger: it simulates the
# exact discrete jump trajectory from the frozen tuning constants and
# picks a takeoff whose flight clears the obstacle(s) and lands in a
# stance from which the next obstacle is itself jumpable (chained
# obstacles). Timed/moving/pillar approaches keep the greedy policy.
# False negatives are acceptable (level simply doesn't ship). False
# positives are not: a PASS requires reaching the door rect through
# physics simulation.
#
# Usage (see run_autopilot.sh):
#   godot --headless --fixed-fps 60 --path <project> -s autopilot.gd --
#       --levels <levels.json> --tuning <tuning.json> --out <report.json>
#       [--mode auto|game|harness] [--steps N] [--strategies N]
#       [--seed N] [--only L001,L002] [--selftest]
extends SceneTree

const LOOKAHEAD := 96.0
const BLOCK_WAIT_MAX := 3.0
const NO_PROGRESS_LIMIT := 480
const BLOCKED_FRAMES_JUMP := 12

# Ballistic planner constants (geometry margins only; all physics comes
# from tuning.json via _player_cfg, never from literals here).
const PLAN_HORIZON := 420.0
const PLAN_MAX_TAKEOFF_AHEAD := 360.0
const PLAN_MARGIN := 4.0
const PLAN_MIN_RUNUP := 24.0
const PLAN_FOLLOWUP_CHECKS := 3
const PLAN_RECHECK_DIST := 24.0
const PLAN_MAX_FRAMES := 90
const PLAN_DT := 1.0 / 60.0

# ---------------------------------------------------------------------------
# Harness physics bodies (fallback mode only; game mode reuses game code).
# ---------------------------------------------------------------------------

class HarnessPlayer extends CharacterBody2D:
	var tun: Dictionary = {}
	var input_dir: float = 0.0
	var jump_just: bool = false

	func _physics_process(delta: float) -> void:
		var accel: float = float(tun["acceleration"])
		if not is_on_floor():
			accel *= float(tun["air_control"])
		velocity.x = move_toward(velocity.x, input_dir * float(tun["run_speed"]),
				accel * delta)
		if is_on_floor():
			# Grounded: no gravity accumulation (matches docs pattern and
			# avoids instant max-fall-speed when walking off a ledge).
			if velocity.y > 0.0:
				velocity.y = 0.0
		else:
			velocity.y = minf(velocity.y + float(tun["gravity"]) * delta,
					float(tun["max_fall_speed"]))
		if jump_just and is_on_floor():
			velocity.y = float(tun["jump_velocity"])
		jump_just = false
		move_and_slide()


class MovingPlatform extends AnimatableBody2D:
	var rest: Vector2 = Vector2.ZERO
	var offset: Vector2 = Vector2.ZERO
	var period: float = 2.0
	var elapsed: float = 0.0
	var plat_size: Vector2 = Vector2.ZERO

	func _physics_process(delta: float) -> void:
		elapsed += delta
		var f: float = 0.5 - 0.5 * cos(TAU * elapsed / period)
		var target: Vector2 = rest + offset * f
		constant_linear_velocity = (target - position) / maxf(delta, 0.0001)
		position = target


class DashedPlatform extends StaticBody2D:
	var period: float = 2.0
	var phase: float = 0.0
	var on_time: float = 1.0
	var elapsed: float = 0.0
	var solid_now: bool = true
	var shape: CollisionShape2D = null
	var plat_size: Vector2 = Vector2.ZERO

	func _physics_process(delta: float) -> void:
		elapsed += delta
		var solid: bool = fposmod(elapsed - phase, period) < on_time
		if solid != solid_now:
			solid_now = solid
			shape.set_deferred("disabled", not solid)
			set_deferred("collision_layer", 2 if solid else 0)


class FallingPlatform extends StaticBody2D:
	var stand_time: float = 0.5
	var gravity: float = 2200.0
	var stood_time: float = 0.0
	var stood: bool = false
	var falling: bool = false
	var fall_vel: float = 0.0
	var shape: CollisionShape2D = null
	var plat_size: Vector2 = Vector2.ZERO

	func _physics_process(delta: float) -> void:
		if falling:
			fall_vel += gravity * delta
			position.y += fall_vel * delta
			return
		# Stand timer latches: stepping off does not reset it (trap-like).
		if stood:
			stood_time += delta
			if stood_time >= stand_time:
				falling = true
				shape.set_deferred("disabled", true)
				set_deferred("collision_layer", 0)
		stood = false


class HangingPillar extends AnimatableBody2D:
	var rest_pos: Vector2 = Vector2.ZERO
	var period: float = 0.0  # 0 = triggered, not periodic
	var phase: float = 0.0
	var drop_speed: float = 700.0
	var drop_dist: float = 0.0
	var elapsed: float = 0.0
	var triggered: bool = false
	var landed: bool = false
	var lethal_now: bool = false
	var plat_size: Vector2 = Vector2.ZERO

	func _physics_process(delta: float) -> void:
		elapsed += delta
		if period > 0.0:
			var drop_time: float = drop_dist / maxf(drop_speed, 1.0)
			var hang_time: float = maxf(0.0, period - drop_time - 1.0)
			var cyc: float = fposmod(elapsed - phase, period)
			if cyc < hang_time:
				position.y = rest_pos.y
				lethal_now = false
			elif cyc < hang_time + drop_time:
				position.y = rest_pos.y + drop_speed * (cyc - hang_time)
				lethal_now = true
			else:
				var frac: float = (cyc - hang_time - drop_time) / 1.0
				position.y = rest_pos.y + drop_dist * (1.0 - minf(1.0, frac))
				lethal_now = true
		elif triggered and not landed:
			lethal_now = true
			position.y += drop_speed * delta
			if position.y >= rest_pos.y + drop_dist:
				position.y = rest_pos.y + drop_dist
				landed = true
				# Landed pillar stays down; overlap = crushed (lethal).
				lethal_now = true


# ---------------------------------------------------------------------------
# Main script
# ---------------------------------------------------------------------------

var _args: Dictionary = {}
var _tun: Dictionary = {}
var _player_cfg: Dictionary = {}
var _bar_y: float = 580.0
var _door_w: float = 54.0
var _door_h: float = 84.0

# Per-attempt state.
var _elapsed: float = 0.0
var _prev_feet_x: float = 0.0
var _trig_times: Dictionary = {}
var _block_wait: float = 0.0
var _last_dir: float = 1.0
var _blocked_frames: int = 0
var _best_dist: float = 1e9
var _noprogress: int = 0
var _wait_remaining: float = 0.0
var _plat_nodes: Array = []
var _pillar_nodes: Dictionary = {}
var _level_root: Node = null
var _player: CharacterBody2D = null
var _drive_kind: String = "none"  # harness | actions | props
var _action_names: Array = []
var _prop_nodes: Dictionary = {}
var _spawn_pos: Vector2 = Vector2.ZERO
var _has_moved_away: bool = false
var _game_node: Node = null
var _deaths_seen: int = -1
var _plan_x: float = 0.0
var _plan_active: bool = false
var _plan_brake_x: float = -1.0
var _plan_next_check_x: float = -1e9
var _plan_prev_on_floor: bool = false
var _flight_brake_x: float = -1.0
var _flight_active: bool = false


func _initialize() -> void:
	call_deferred("_run")


func _parse_args() -> void:
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < raw.size():
		var a: String = raw[i]
		if a == "--selftest":
			_args["selftest"] = true
			i += 1
		elif a in ["--levels", "--tuning", "--out", "--mode", "--fixtures-dir",
				"--only"]:
			if i + 1 < raw.size():
				_args[a.trim_prefix("--")] = raw[i + 1]
			i += 2
		elif a in ["--steps", "--strategies", "--seed", "--max-levels"]:
			if i + 1 < raw.size():
				_args[a.trim_prefix("--")] = int(raw[i + 1])
			i += 2
		else:
			i += 1
	_args["mode"] = str(_args.get("mode", "auto"))
	_args["steps"] = int(_args.get("steps", 2700))
	_args["strategies"] = int(_args.get("strategies", 4))
	_args["seed"] = int(_args.get("seed", 12345))


func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text: String = f.get_as_text()
	f.close()
	return JSON.parse_string(text)


func _sha256_file(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _die(msg: String, code: int) -> void:
	push_error("autopilot: " + msg)
	print("AUTOPILOT ERROR: " + msg)
	quit(code)


# ---------------------------------------------------------------------------
# Analytic hazard state (shared sensing for both modes)
# ---------------------------------------------------------------------------

func _saw_centre(h: Dictionary, t: float) -> Vector2:
	var x: float = float(h["x"])
	var y: float = float(h["y"])
	if h.has("path"):
		var p: Dictionary = h["path"]
		var period: float = float(h["period"])
		var f: float = 0.5 - 0.5 * cos(TAU * t / period)
		return Vector2(x + (float(p["x2"]) - x) * f,
				y + (float(p["y2"]) - y) * f)
	if h.has("swing"):
		var s: Dictionary = h["swing"]
		var period: float = float(s["period"])
		var ang: float = deg_to_rad(float(s["arc_deg"])) * 0.5 \
				* sin(TAU * t / period)
		var off: Vector2 = Vector2(x - float(s["pivot_x"]),
				y - float(s["pivot_y"]))
		return Vector2(float(s["pivot_x"]), float(s["pivot_y"])) \
				+ off.rotated(ang)
	return Vector2(x, y)


func _popup_up(h: Dictionary, t: float) -> bool:
	return fposmod(t - float(h.get("phase", 0.0)),
			float(h["period"])) < float(h["on_time"])


func _triggered_active(h: Dictionary, idx: int) -> bool:
	# Generic trigger_x / delay gating (spikes etc.).
	if h.has("trigger_x"):
		if not _trig_times.has(idx):
			return false
		return _elapsed >= float(_trig_times[idx]) + float(h.get("delay", 0.0))
	return true


func _lethal_shapes(level: Dictionary) -> Array:
	"""Currently-lethal shapes: [{shape:Rect2|circle dict, timed:bool}]."""
	var out: Array = []
	var hazards: Array = level["hazards"]
	for idx in range(hazards.size()):
		var h: Dictionary = hazards[idx]
		var typ: String = str(h.get("type", ""))
		if typ == "dotted_line":
			continue
		if typ == "spikes":
			if h.has("period") and not _popup_up(h, _elapsed):
				continue
			if not _triggered_active(h, idx):
				continue
			out.append({"rect": Rect2(float(h["x"]), float(h["y"]),
					float(h["w"]), float(h["h"])),
					"timed": h.has("period")})
		elif typ == "saw":
			var c: Vector2 = _saw_centre(h, _elapsed)
			out.append({"centre": c, "radius": float(h["r"]),
					"timed": h.has("path") or h.has("swing")})
		elif typ == "spiked_column":
			if not _triggered_active(h, idx):
				continue
			out.append({"rect": Rect2(float(h["x"]), float(h["y"]),
					float(h["w"]), float(h["h"])), "timed": false})
		elif typ == "hanging_pillar":
			if _pillar_nodes.has(idx):
				var node: HangingPillar = _pillar_nodes[idx]
				if node.lethal_now:
					var sz: Vector2 = node.plat_size
					out.append({"rect": Rect2(
							node.global_position - sz / 2.0, sz),
							"timed": true})
			else:
				# Analytic pillar (game mode): periodic cycle or trigger.
				var rect := Rect2(float(h["x"]), float(h["y"]),
						float(h["w"]), float(h["h"]))
				var drop_dist: float = maxf(0.0,
						_bar_y - (rect.position.y + rect.size.y))
				var speed: float = float(h.get("drop_speed", 700.0))
				if h.has("period"):
					var drop_time: float = drop_dist / maxf(speed, 1.0)
					var hang: float = maxf(0.0,
							float(h["period"]) - drop_time - 1.0)
					var cyc: float = fposmod(
							_elapsed - float(h.get("phase", 0.0)),
							float(h["period"]))
					if cyc >= hang:
						var dy: float = 0.0
						if cyc < hang + drop_time:
							dy = speed * (cyc - hang)
						else:
							dy = drop_dist * (1.0 - minf(1.0,
									(cyc - hang - drop_time) / 1.0))
						rect.position.y += dy
						out.append({"rect": rect, "timed": true})
				else:
					if _trig_times.has(idx):
						var dy2: float = minf(drop_dist, speed * maxf(0.0,
								_elapsed - float(_trig_times[idx])))
						rect.position.y += dy2
						out.append({"rect": rect, "timed": true})
	return out


func _shape_hits_rect(shape: Dictionary, rect: Rect2) -> bool:
	if shape.has("rect"):
		return (shape["rect"] as Rect2).intersects(rect)
	var c: Vector2 = shape["centre"]
	var r: float = shape["radius"]
	var closest := Vector2(clampf(c.x, rect.position.x,
			rect.position.x + rect.size.x),
			clampf(c.y, rect.position.y, rect.position.y + rect.size.y))
	return closest.distance_to(c) < r


func _current_platform_rects(level: Dictionary) -> Array:
	"""Solid-now platform rects (Rect2) for gap/mount sensing."""
	var out: Array = []
	if _drive_kind == "harness" and not _plat_nodes.is_empty():
		for node in _plat_nodes:
			if node is DashedPlatform and not node.solid_now:
				continue
			if node is FallingPlatform and node.falling:
				continue
			var sz: Vector2 = node.get_meta("plat_size")
			out.append(Rect2(node.global_position - sz / 2.0, sz))
		return out
	for p in level["platforms"]:
		var r := Rect2(float(p["x"]), float(p["y"]), float(p["w"]),
				float(p["h"]))
		if str(p["kind"]) == "moving":
			var f: float = 0.5 - 0.5 * cos(TAU * _elapsed / float(p["period"]))
			r.position += Vector2(float(p["dx"]), float(p["dy"])) * f
		elif str(p["kind"]) == "dashed":
			if fposmod(_elapsed - float(p["phase"]),
					float(p["period"])) >= float(p["on_time"]):
				continue
		out.append(r)
	return out


# ---------------------------------------------------------------------------
# Harness level construction (fallback mode)
# ---------------------------------------------------------------------------

func _rect_body(body: CollisionObject2D, cx: float, cy: float,
		w: float, h: float) -> CollisionShape2D:
	body.position = Vector2(cx, cy)
	body.collision_layer = 2
	body.collision_mask = 0
	body.set_meta("plat_size", Vector2(w, h))
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(w, h)
	shape.shape = rect
	body.add_child(shape)
	return shape


func _build_harness_level(level: Dictionary) -> bool:
	_level_root = Node2D.new()
	_level_root.name = "AutopilotLevel"
	root.add_child(_level_root)
	_plat_nodes = []
	_pillar_nodes = {}
	for p in level["platforms"]:
		var kind: String = str(p["kind"])
		var cx: float = float(p["x"]) + float(p["w"]) / 2.0
		var cy: float = float(p["y"]) + float(p["h"]) / 2.0
		var body: CollisionObject2D = null
		var shape: CollisionShape2D = null
		if kind == "moving":
			var m := MovingPlatform.new()
			m.rest = Vector2(cx, cy)
			m.offset = Vector2(float(p["dx"]), float(p["dy"]))
			m.period = float(p["period"])
			m.plat_size = Vector2(float(p["w"]), float(p["h"]))
			body = m
			shape = _rect_body(body, cx, cy, float(p["w"]), float(p["h"]))
		elif kind == "dashed":
			var d := DashedPlatform.new()
			d.period = float(p["period"])
			d.phase = float(p["phase"])
			d.on_time = float(p["on_time"])
			d.plat_size = Vector2(float(p["w"]), float(p["h"]))
			body = d
			shape = _rect_body(body, cx, cy, float(p["w"]), float(p["h"]))
			d.shape = shape
		elif kind == "falling" or kind == "tilting":
			var f := FallingPlatform.new()
			f.stand_time = float(p["stand_time"])
			f.gravity = float(_player_cfg["gravity"])
			f.plat_size = Vector2(float(p["w"]), float(p["h"]))
			body = f
			shape = _rect_body(body, cx, cy, float(p["w"]), float(p["h"]))
			f.shape = shape
		else:
			body = StaticBody2D.new()
			shape = _rect_body(body, cx, cy, float(p["w"]), float(p["h"]))
		_level_root.add_child(body)
		_plat_nodes.append(body)
	# Hanging pillars are solid bodies (harness mode).
	var hazards: Array = level["hazards"]
	for idx in range(hazards.size()):
		var h: Dictionary = hazards[idx]
		if str(h.get("type", "")) != "hanging_pillar":
			continue
		var pil := HangingPillar.new()
		var cx2: float = float(h["x"]) + float(h["w"]) / 2.0
		var cy2: float = float(h["y"]) + float(h["h"]) / 2.0
		pil.rest_pos = Vector2(cx2, cy2)
		pil.drop_speed = float(h.get("drop_speed", 700.0))
		pil.drop_dist = maxf(0.0, _bar_y - (float(h["y"]) + float(h["h"])))
		pil.plat_size = Vector2(float(h["w"]), float(h["h"]))
		if h.has("period"):
			pil.period = float(h["period"])
			pil.phase = float(h.get("phase", 0.0))
		_rect_body(pil, cx2, cy2, float(h["w"]), float(h["h"]))
		_level_root.add_child(pil)
		_pillar_nodes[idx] = pil
	# Player.
	var spawn: Dictionary = level["spawn"]
	_player = HarnessPlayer.new()
	_player.tun = _player_cfg
	_player.collision_layer = 1
	_player.collision_mask = 2
	_player.floor_snap_length = 8.0
	_player.position = Vector2(float(spawn["x"]),
			float(spawn["y"]) - float(_player_cfg["height"]) / 2.0)
	var pshape := CollisionShape2D.new()
	var prect := RectangleShape2D.new()
	prect.size = Vector2(float(_player_cfg["width"]),
			float(_player_cfg["height"]))
	pshape.shape = prect
	_player.add_child(pshape)
	_level_root.add_child(_player)
	_spawn_pos = _player.position
	_drive_kind = "harness"
	return true


# ---------------------------------------------------------------------------
# Game-builder discovery (preferred mode)
# ---------------------------------------------------------------------------

const GAME_SCENES: Array = ["res://scenes/game.tscn", "res://scenes/Game.tscn",
	"res://game.tscn", "res://scenes/main.tscn", "res://main.tscn",
	"res://scenes/level.tscn", "res://scenes/gameplay.tscn"]
const GAME_SCRIPTS: Array = ["res://scripts/level_builder.gd",
	"res://scripts/game.gd", "res://scripts/level.gd",
	"res://scripts/builder.gd", "res://scripts/main.gd",
	"res://scripts/level_data.gd"]
const BUILD_METHODS: Array = ["build_level", "load_level", "setup_level",
	"create_level", "load_level_data", "set_level", "start_level",
	"build", "setup"]


func _find_player(node: Node) -> CharacterBody2D:
	if node is CharacterBody2D:
		return node
	for child in node.get_children():
		var found: CharacterBody2D = _find_player(child)
		if found != null:
			return found
	return null


func _property_names(obj: Object) -> Dictionary:
	var out: Dictionary = {}
	for d in obj.get_property_list():
		out[str(d["name"])] = true
	return out


func _detect_drive(game_node: Node, player: CharacterBody2D) -> String:
	# 1) Input actions.
	var sets: Array = [["move_left", "move_right", "jump"],
		["ui_left", "ui_right", "ui_accept"],
		["left", "right", "jump"]]
	for s in sets:
		var ok: bool = true
		for a in s:
			if not InputMap.has_action(a):
				ok = false
		if ok:
			_action_names = s
			return "actions"
	# 2) Touch/input properties on the player or game node.
	var left_names: Array = ["touch_left", "left_pressed",
		"move_left_pressed", "input_left", "left_held"]
	var right_names: Array = ["touch_right", "right_pressed",
		"move_right_pressed", "input_right", "right_held"]
	var jump_names: Array = ["touch_jump", "jump_pressed", "jump_requested",
		"jump_held", "input_jump"]
	var dir_names: Array = ["move_dir", "input_dir", "move_direction"]
	var nodes: Array = []
	if player != null:
		nodes.append(player)
	if game_node != null:
		nodes.append(game_node)
	_prop_nodes = {}
	for node in nodes:
		var props: Dictionary = _property_names(node)
		for arr: Array in [left_names, right_names, jump_names, dir_names]:
			for nm in arr:
				if props.has(nm) and not _prop_nodes.has(nm):
					_prop_nodes[nm] = node
	var has_left: bool = left_names.any(func(n: String) -> bool:
		return _prop_nodes.has(n))
	var has_right: bool = right_names.any(func(n: String) -> bool:
		return _prop_nodes.has(n))
	var has_jump: bool = jump_names.any(func(n: String) -> bool:
		return _prop_nodes.has(n))
	var has_dir: bool = dir_names.any(func(n: String) -> bool:
		return _prop_nodes.has(n))
	if (has_left and has_right and has_jump) or (has_dir and has_jump):
		return "props"
	return "none"


func _try_game_build(level: Dictionary) -> Dictionary:
	"""Returns {ok, mode, notes}. On success sets _level_root/_player."""
	var notes: Array = []
	# Candidate scenes first.
	for scene_path in GAME_SCENES:
		if not ResourceLoader.exists(scene_path):
			continue
		var packed: PackedScene = load(scene_path) as PackedScene
		if packed == null:
			continue
		var inst: Node = packed.instantiate()
		if inst == null:
			continue
		_level_root = inst
		root.add_child(inst)
		await physics_frame
		await physics_frame
		var built: bool = await _call_build_method(inst, level, notes)
		await physics_frame
		await physics_frame
		var player: CharacterBody2D = _find_player(inst)
		if player != null:
			var drive: String = _detect_drive(inst, player)
			if drive != "none":
				_player = player
				_game_node = inst
				_drive_kind = drive
				_spawn_pos = player.position
				return {"ok": true, "mode": "game",
						"notes": "scene %s build=%s drive=%s" % [
								scene_path, built, drive]}
			notes.append("scene %s: player found but no drivable input"
					% scene_path)
		else:
			notes.append("scene %s: no CharacterBody2D player" % scene_path)
		inst.queue_free()
		_level_root = null
		await physics_frame
		await physics_frame
	# Candidate builder scripts.
	for script_path in GAME_SCRIPTS:
		if not ResourceLoader.exists(script_path):
			continue
		var scr: Script = load(script_path) as Script
		if scr == null:
			continue
		var obj: Variant = scr.new()
		if obj is Node:
			_level_root = obj
			root.add_child(obj)
			await physics_frame
			await physics_frame
			await _call_build_method(obj, level, notes)
			await physics_frame
			await physics_frame
			var player2: CharacterBody2D = _find_player(obj)
			if player2 != null:
				var drive2: String = _detect_drive(obj, player2)
				if drive2 != "none":
					_player = player2
					_game_node = obj
					_drive_kind = drive2
					_spawn_pos = player2.position
					return {"ok": true, "mode": "game",
							"notes": "script %s drive=%s" % [script_path,
									drive2]}
			obj.queue_free()
			_level_root = null
			await physics_frame
			await physics_frame
		elif obj != null and obj.has_method("build_level"):
			var built_node: Variant = obj.call("build_level", level, _tun)
			if built_node is Node:
				_level_root = built_node
				root.add_child(built_node)
				await physics_frame
				await physics_frame
				var player3: CharacterBody2D = _find_player(built_node)
				if player3 != null:
					var drive3: String = _detect_drive(built_node, player3)
					if drive3 != "none":
						_player = player3
						_game_node = built_node
						_drive_kind = drive3
						_spawn_pos = player3.position
						return {"ok": true, "mode": "game",
								"notes": "RefCounted builder %s" % script_path}
				built_node.queue_free()
				_level_root = null
				await physics_frame
				await physics_frame
		notes.append("script %s: no usable build path" % script_path)
	return {"ok": false, "mode": "blocked",
			"notes": "; ".join(notes) if not notes.is_empty()
					else "no game scene/script found under res://"}


func _call_build_method(obj: Node, level: Dictionary,
		notes: Array) -> bool:
	for m in BUILD_METHODS:
		if obj.has_method(m):
			# Try (level, tuning) then (level). Wrong arity logs an
			# error and returns null; we check the tree afterwards.
			obj.call(m, level, _tun)
			notes.append("called %s(level, tuning)" % m)
			return true
	return false


func _teardown_level() -> void:
	_release_drive()
	if _level_root != null and is_instance_valid(_level_root):
		_level_root.queue_free()
	_level_root = null
	_player = null
	_game_node = null
	_plat_nodes = []
	_pillar_nodes = {}
	_drive_kind = "none"
	await physics_frame
	await physics_frame


func _release_drive() -> void:
	for a in _action_names:
		Input.action_release(a)
	_action_names = []
	_prop_nodes = {}


# ---------------------------------------------------------------------------
# Driving + observation
# ---------------------------------------------------------------------------

func _set_drive(dir: float, jump: bool) -> void:
	if _drive_kind == "harness":
		if _player != null and is_instance_valid(_player):
			_player.input_dir = dir
			if jump:
				_player.jump_just = true
	elif _drive_kind == "actions":
		if _action_names.size() == 3:
			_set_action(_action_names[0], dir < 0.0)
			_set_action(_action_names[1], dir > 0.0)
			_set_action(_action_names[2], jump)
	elif _drive_kind == "props":
		_set_prop(["touch_left", "left_pressed", "move_left_pressed",
				"input_left", "left_held"], dir < 0.0)
		_set_prop(["touch_right", "right_pressed", "move_right_pressed",
				"input_right", "right_held"], dir > 0.0)
		_set_prop(["touch_jump", "jump_pressed", "jump_requested",
				"jump_held", "input_jump"], jump)
		_set_prop(["move_dir", "input_dir", "move_direction"], dir)


func _set_action(action: String, pressed: bool) -> void:
	if pressed:
		Input.action_press(action)
	else:
		Input.action_release(action)


func _set_prop(names: Array, value: Variant) -> void:
	for nm in names:
		if _prop_nodes.has(nm):
			var node: Object = _prop_nodes[nm]
			if is_instance_valid(node):
				node.set(nm, value)
			return


func _feet_pos() -> Vector2:
	if _player == null or not is_instance_valid(_player):
		return Vector2.ZERO
	return _player.global_position \
			+ Vector2(0.0, float(_player_cfg["height"]) / 2.0)


func _player_rect() -> Rect2:
	var feet: Vector2 = _feet_pos()
	return Rect2(feet.x - float(_player_cfg["width"]) / 2.0,
			feet.y - float(_player_cfg["height"]),
			float(_player_cfg["width"]), float(_player_cfg["height"]))


func _door_rect(level: Dictionary) -> Rect2:
	var d: Dictionary = level["door"]
	return Rect2(float(d["x"]) - _door_w / 2.0, float(d["y"]) - _door_h,
			_door_w, _door_h)


func _on_floor() -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	return _player.is_on_floor()


func _update_triggers(level: Dictionary) -> void:
	var feet: Vector2 = _feet_pos()
	var hazards: Array = level["hazards"]
	for idx in range(hazards.size()):
		var h: Dictionary = hazards[idx]
		var tx: Variant = h.get("trigger_x", h.get("drop_trigger_x"))
		if tx == null or _trig_times.has(idx):
			continue
		var ftx: float = float(tx)
		if (_prev_feet_x - ftx) * (feet.x - ftx) <= 0.0 \
				and feet.x != _prev_feet_x:
			_trig_times[idx] = _elapsed
			if _pillar_nodes.has(idx):
				_pillar_nodes[idx].triggered = true
	_prev_feet_x = feet.x


func _floor_body() -> Object:
	# Godot 4 has no get_floor_body(); use the last move_and_slide
	# collisions and pick the one with an upward (floor-like) normal.
	if _player == null or not is_instance_valid(_player):
		return null
	for i in range(_player.get_slide_collision_count()):
		var col: KinematicCollision2D = _player.get_slide_collision(i)
		if col.get_normal().y < -0.5:
			return col.get_collider()
	return null


func _update_falling_flags() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var floor_body: Object = null
	if _player.is_on_floor():
		floor_body = _floor_body()
	for node in _plat_nodes:
		if node is FallingPlatform:
			node.stood = (floor_body == node)


func _check_died(level: Dictionary) -> bool:
	if _player == null or not is_instance_valid(_player):
		return true  # player freed: treat as death + rebuild
	var feet: Vector2 = _feet_pos()
	if feet.y > _bar_y + 40.0:
		return true
	if _drive_kind == "harness":
		var prect: Rect2 = _player_rect()
		for shape in _lethal_shapes(level):
			if _shape_hits_rect(shape, prect):
				return true
		return false
	# Game mode: respawn detection + deaths counter.
	if _game_node != null and is_instance_valid(_game_node):
		var props: Dictionary = _property_names(_game_node)
		if props.has("deaths"):
			var d: int = int(_game_node.get("deaths"))
			if _deaths_seen >= 0 and d > _deaths_seen:
				return true
			_deaths_seen = d
	if feet.distance_to(_spawn_pos + Vector2(0.0,
			float(_player_cfg["height"]) / 2.0)) > 60.0:
		_has_moved_away = true
	elif _has_moved_away and feet.distance_to(_spawn_pos + Vector2(0.0,
			float(_player_cfg["height"]) / 2.0)) < 8.0:
		return true
	return false


func _check_won(level: Dictionary) -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	if _door_rect(level).intersects(_player_rect()):
		return true
	if _game_node != null and is_instance_valid(_game_node):
		var props: Dictionary = _property_names(_game_node)
		for nm in ["level_completed", "completed", "won", "level_won"]:
			if props.has(nm) and bool(_game_node.get(nm)):
				return true
	return false


# ---------------------------------------------------------------------------
# Ballistic jump planner (static-geometry approaches only)
# ---------------------------------------------------------------------------
# The fixed-lookahead trigger mistimes jumps over tall/wide obstacles and
# chains poorly: it jumps as soon as a hazard enters a 96px probe, so a
# jump can land a few pixels before the next hazard, leaving no run-up
# for the re-jump, or fly clean over a step it should land on. The
# planner instead simulates the exact discrete trajectory the game
# integrates (jump velocity set on the jump frame, then gravity per
# 1/60s frame, horizontal move_toward with ground/air acceleration, all
# from the loaded tuning) for every frame-aligned takeoff along the
# current ground run, and picks one whose flight clears every lethal
# shape and wall, lands on solid ground, and leaves a stance from which
# the next obstacle is itself jumpable. Planning uses geometry +
# declarative trap params only: no level id or template is ever read.
# Scope: only when no moving/dashed/falling/tilting platform, hanging
# pillar, or moving (path/swing) saw lies anywhere ahead of the player;
# those approaches keep the greedy policy untouched, because any
# planner intervention before a timed feature can shift arrival timing
# at it (a planned jump before a pillar drop desyncs the greedy wait
# that makes those levels pass). Once the player is past the timed
# feature, the planner may engage for the static stretch that follows.
# Triggered and pop-up spikes are planned around as always-lethal
# rects: clearing them ballistically is safe in every phase, and
# waiting for them to "appear" is what made the greedy trigger jump
# too late.

func _plan_half_w() -> float:
	return float(_player_cfg["width"]) / 2.0


func _plan_height() -> float:
	return float(_player_cfg["height"])


func _plan_geometry(level: Dictionary, feet: Vector2) -> Dictionary:
	var hx0: float = feet.x - 40.0
	# Any timed feature anywhere ahead disables the planner outright
	# (see header): timing at it must stay exactly the greedy policy's.
	for p in level["platforms"]:
		if str(p["kind"]) != "solid":
			var sr: float = float(p["x"]) + float(p["w"]) \
					+ absf(float(p.get("dx", 0.0)))
			if sr > feet.x:
				return {"ok": false}
	for h in level["hazards"]:
		var typ0: String = str(h.get("type", ""))
		if typ0 == "hanging_pillar":
			if float(h["x"]) + float(h["w"]) > feet.x:
				return {"ok": false}
		elif typ0 == "saw" and (h.has("path") or h.has("swing")):
			var er: float
			if h.has("path"):
				er = maxf(float(h["x"]), float(h["path"]["x2"])) \
						+ float(h["r"])
			else:
				var s0: Dictionary = h["swing"]
				er = float(s0["pivot_x"]) + Vector2(float(h["x"]) - float(s0["pivot_x"]),
						float(h["y"]) - float(s0["pivot_y"])).length() \
						+ float(h["r"])
			if er > feet.x:
				return {"ok": false}
	var solids: Array = []
	for p in level["platforms"]:
		if str(p["kind"]) != "solid":
			continue
		var r := Rect2(float(p["x"]), float(p["y"]), float(p["w"]),
				float(p["h"]))
		if r.position.x + r.size.x >= hx0 \
				and r.position.x <= feet.x + 900.0:
			solids.append(r)
	var lethal: Array = []
	for h in level["hazards"]:
		var typ: String = str(h.get("type", ""))
		if typ == "dotted_line":
			continue
		if typ == "hanging_pillar":
			continue
		if typ == "saw" and (h.has("path") or h.has("swing")):
			continue
		if typ == "spikes" or typ == "spiked_column":
			var lr := Rect2(float(h["x"]) - PLAN_MARGIN,
					float(h["y"]) - PLAN_MARGIN,
					float(h["w"]) + 2.0 * PLAN_MARGIN,
					float(h["h"]) + 2.0 * PLAN_MARGIN)
			if lr.position.x + lr.size.x >= hx0 \
					and lr.position.x <= feet.x + 900.0:
				lethal.append({"rect": lr})
		elif typ == "saw":
			var c := Vector2(float(h["x"]), float(h["y"]))
			if c.x + float(h["r"]) >= hx0 \
					and c.x - float(h["r"]) <= feet.x + 900.0:
				lethal.append({"centre": c,
						"radius": float(h["r"]) + PLAN_MARGIN})
	return {"ok": true, "lethal": lethal, "solids": solids}


func _plan_trajectory() -> Dictionary:
	var g: float = float(_player_cfg["gravity"])
	var vy: float = float(_player_cfg["jump_velocity"])
	var maxfall: float = float(_player_cfg["max_fall_speed"])
	var offs: Array = []
	var falling: Array = []
	var off: float = 0.0
	for f in range(PLAN_MAX_FRAMES):
		if f > 0:
			vy = minf(vy + g * PLAN_DT, maxfall)
		off += vy * PLAN_DT
		offs.append(off)
		falling.append(vy > 0.0)
		if off > 220.0:
			break
	return {"offs": offs, "falling": falling}


func _plan_dx(vx0: float, dir: float, cache: Dictionary) -> Dictionary:
	var key: int = int(round(vx0))
	if cache.has(key):
		return cache[key]
	var accel: float = float(_player_cfg["acceleration"])
	var air: float = float(_player_cfg["air_control"])
	var speed: float = float(_player_cfg["run_speed"])
	var vx: float = vx0
	var dxs: Array = []
	var vxs: Array = []
	var dx: float = 0.0
	for f in range(PLAN_MAX_FRAMES):
		var a: float = accel if f == 0 else accel * air
		vx = move_toward(vx, dir * speed, a * PLAN_DT)
		dx += vx * PLAN_DT
		dxs.append(dx)
		vxs.append(vx)
	var res: Dictionary = {"dx": dxs, "vx": vxs}
	cache[key] = res
	return res


func _plan_dx_braked(vx0: float, dir: float, brake_frame: int,
		cache: Dictionary) -> Dictionary:
	# Horizontal motion with the stick released from brake_frame on:
	# velocity decays toward 0 at air acceleration, shortening the jump.
	# Vertical motion is unchanged (shared trajectory). brake_frame is
	# the count of full-speed frames before release.
	var key: String = "%d:%d" % [int(round(vx0)), brake_frame]
	if cache.has(key):
		return cache[key]
	var accel: float = float(_player_cfg["acceleration"])
	var air: float = float(_player_cfg["air_control"])
	var speed: float = float(_player_cfg["run_speed"])
	var vx: float = vx0
	var dxs: Array = []
	var vxs: Array = []
	var dx: float = 0.0
	for f in range(PLAN_MAX_FRAMES):
		var a: float = accel if f == 0 else accel * air
		var target: float = dir * speed if f < brake_frame else 0.0
		vx = move_toward(vx, target, a * PLAN_DT)
		dx += vx * PLAN_DT
		dxs.append(dx)
		vxs.append(vx)
	var res: Dictionary = {"dx": dxs, "vx": vxs}
	cache[key] = res
	return res


func _plan_flight(x0: float, y0: float, traj: Dictionary,
		horiz: Dictionary, lethal: Array, solids: Array) -> Dictionary:
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	var offs: Array = traj["offs"]
	var falling: Array = traj["falling"]
	var dxs: Array = horiz["dx"]
	var vxs: Array = horiz["vx"]
	var n: int = mini(offs.size(), dxs.size())
	var prev_feet: float = y0
	for f in range(n):
		var x: float = x0 + float(dxs[f])
		var feet: float = y0 + float(offs[f])
		var rect := Rect2(x - hw, feet - ph, 2.0 * hw, ph)
		for shape in lethal:
			if _shape_hits_rect(shape, rect):
				return {"ok": false, "fail_frame": f}
		if bool(falling[f]):
			for r in solids:
				var rr: Rect2 = r
				var top: float = rr.position.y
				if prev_feet <= top + 1.0 and feet >= top \
						and x >= rr.position.x - 6.0 \
						and x <= rr.position.x + rr.size.x + 6.0:
					var land_rect := Rect2(x - hw, top - ph, 2.0 * hw, ph)
					for shape2 in lethal:
						if _shape_hits_rect(shape2, land_rect):
							return {"ok": false, "fail_frame": f}
					for r2 in solids:
						var rr2: Rect2 = r2
						if rr2 != rr and rr2.intersects(land_rect):
							return {"ok": false, "fail_frame": f}
					return {"ok": true, "land_x": x, "land_y": top,
							"land_vx": float(vxs[f])}
		for r in solids:
			if (r as Rect2).intersects(rect):
				return {"ok": false, "fail_frame": f}
		if feet > _bar_y + 40.0:
			return {"ok": false, "fail_frame": f}
		prev_feet = feet
	return {"ok": false, "fail_frame": n}


func _plan_candidates(x0: float, y0: float, vx0: float, dir: float,
		lethal: Array, solids: Array) -> Array:
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	var accel: float = float(_player_cfg["acceleration"])
	var speed: float = float(_player_cfg["run_speed"])
	var out: Array = []
	var x: float = x0
	var vx: float = vx0
	for k in range(73):
		var rect := Rect2(x - hw, y0 - ph, 2.0 * hw, ph)
		var bad: bool = false
		for shape in lethal:
			if _shape_hits_rect(shape, rect):
				bad = true
				break
		if not bad:
			for r in solids:
				if (r as Rect2).intersects(rect):
					bad = true
					break
		if bad:
			break
		var grounded: bool = false
		for r in solids:
			var rr: Rect2 = r
			if absf(rr.position.y - y0) <= 3.0 and x >= rr.position.x \
					and x <= rr.position.x + rr.size.x:
				grounded = true
				break
		if not grounded:
			break
		out.append({"x": x, "vx": vx})
		if x - x0 >= PLAN_MAX_TAKEOFF_AHEAD:
			break
		vx = move_toward(vx, dir * speed, accel * PLAN_DT)
		x += vx * PLAN_DT
	return out


func _plan_next_entry(land_x: float, land_y: float, lethal: Array,
		solids: Array) -> float:
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	var best: float = 1e9
	for shape in lethal:
		if shape.has("rect"):
			var r: Rect2 = shape["rect"]
			if r.position.y + r.size.y > land_y - ph \
					and r.position.y < land_y:
				var e: float = r.position.x - hw
				if e > land_x - 28.0:
					best = minf(best, e)
		else:
			var c: Vector2 = shape["centre"]
			var rad: float = shape["radius"]
			if c.y + rad > land_y - ph and c.y - rad < land_y:
				var e2: float = c.x - rad - hw
				if e2 > land_x - 28.0:
					best = minf(best, e2)
	for r in solids:
		var rr: Rect2 = r
		if rr.position.y < land_y - 8.0 \
				and rr.position.y + rr.size.y > land_y - ph:
			var e3: float = rr.position.x - hw
			if e3 > land_x - 28.0:
				best = minf(best, e3)
	return best


func _plan_engaged(feet: Vector2, lethal: Array, solids: Array) -> bool:
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	for shape in lethal:
		if shape.has("rect"):
			var r: Rect2 = shape["rect"]
			if r.position.x - hw <= feet.x + PLAN_HORIZON \
					and r.position.x + r.size.x >= feet.x \
					and r.position.y + r.size.y >= feet.y - 170.0 \
					and r.position.y <= feet.y + 200.0:
				return true
		else:
			var c: Vector2 = shape["centre"]
			var rad: float = shape["radius"]
			if c.x - rad - hw <= feet.x + PLAN_HORIZON \
					and c.x + rad >= feet.x \
					and c.y + rad >= feet.y - 170.0 \
					and c.y - rad <= feet.y + 200.0:
				return true
	for r in solids:
		var rr: Rect2 = r
		if rr.position.y < feet.y - 8.0 \
				and rr.position.y + rr.size.y > feet.y - ph \
				and rr.position.x - hw <= feet.x + PLAN_HORIZON \
				and rr.position.x + rr.size.x >= feet.x:
			return true
	var seen_gap: bool = false
	var x: float = feet.x + 12.0
	while x <= feet.x + PLAN_HORIZON + 120.0:
		var g: bool = false
		for r in solids:
			var rr2: Rect2 = r
			if absf(rr2.position.y - feet.y) <= 3.0 \
					and x >= rr2.position.x \
					and x <= rr2.position.x + rr2.size.x:
				g = true
				break
		if not g:
			seen_gap = true
		elif seen_gap:
			return true
		x += 12.0
	return false


func _plan_required_runup(land_x: float, land_y: float, lethal: Array,
		solids: Array, traj: Dictionary, cache: Dictionary,
		dir: float) -> float:
	# Ground distance a stance needs before the next hard obstacle: the
	# distance travelled while rising above that obstacle's top (from
	# the simulated trajectory at full speed), plus decision slack. A
	# fixed run-up is wrong here: a 24px spike needs ~30px, an 88px
	# column needs ~66px. Returns 0 when nothing hard lies ahead, and
	# 1e9 when the obstacle cannot be cleared from this ground level.
	var entry: float = _plan_next_entry(land_x, land_y, lethal, solids)
	if entry > 1e8:
		return 0.0
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	var h_req: float = 0.0
	for shape in lethal:
		if shape.has("rect"):
			var r: Rect2 = shape["rect"]
			var e: float = r.position.x - hw
			if e > land_x - 28.0 and e <= entry + 12.0 \
					and r.position.y + r.size.y > land_y - ph \
					and r.position.y < land_y:
				h_req = maxf(h_req, land_y - r.position.y)
		else:
			var c: Vector2 = shape["centre"]
			var rad: float = shape["radius"]
			var e2: float = c.x - rad - hw
			if e2 > land_x - 28.0 and e2 <= entry + 12.0 \
					and c.y + rad > land_y - ph and c.y - rad < land_y:
				h_req = maxf(h_req, land_y - (c.y - rad))
	for r in solids:
		var rr: Rect2 = r
		var e3: float = rr.position.x - hw
		if e3 > land_x - 28.0 and e3 <= entry + 12.0 \
				and rr.position.y < land_y - 8.0 \
				and rr.position.y + rr.size.y > land_y - ph:
			h_req = maxf(h_req, land_y - rr.position.y)
	if h_req <= 0.0:
		return 0.0
	var horiz: Dictionary = _plan_dx(float(_player_cfg["run_speed"]), dir,
			cache)
	var offs: Array = traj["offs"]
	var dxs: Array = horiz["dx"]
	var need: float = h_req + PLAN_MARGIN
	var n: int = mini(offs.size(), dxs.size())
	for f in range(n):
		if -float(offs[f]) >= need:
			return maxf(float(dxs[f]) + 12.0, PLAN_MIN_RUNUP)
	return 1e9


func _plan_followup_ok(land_x: float, land_y: float, land_vx: float,
		dir: float, traj: Dictionary, cache: Dictionary, lethal: Array,
		solids: Array) -> bool:
	var cands: Array = _plan_candidates(land_x, land_y, land_vx, dir,
			lethal, solids)
	for cand in cands:
		var horiz: Dictionary = _plan_dx(float(cand["vx"]), dir, cache)
		var fl: Dictionary = _plan_flight(float(cand["x"]), land_y, traj,
				horiz, lethal, solids)
		if not bool(fl.get("ok", false)):
			continue
		var entry: float = _plan_next_entry(float(fl["land_x"]),
				float(fl["land_y"]), lethal, solids)
		if entry > 1e8:
			return true
		var need: float = _plan_required_runup(float(fl["land_x"]),
				float(fl["land_y"]), lethal, solids, traj, cache, dir)
		if entry - float(fl["land_x"]) >= need:
			return true
	return false


func _plan_pick(feasible: Array, dir: float, traj: Dictionary,
		cache: Dictionary, lethal: Array, solids: Array) -> Dictionary:
	if feasible.is_empty():
		return {"ok": false}
	for f in feasible:
		if float(f["runup"]) > 1e8:
			return {"ok": true, "takeoff": float(f["takeoff"]),
					"brake_x": float(f.get("brake_x", -1.0))}
	feasible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["runup"]) - float(b["runup"])) > 6.0:
			return float(a["runup"]) > float(b["runup"])
		return float(a["takeoff"]) < float(b["takeoff"]))
	var checked: int = 0
	for f in feasible:
		if float(f["runup"]) < 6.0:
			continue
		if checked >= PLAN_FOLLOWUP_CHECKS:
			break
		checked += 1
		if _plan_followup_ok(float(f["land_x"]), float(f["land_y"]),
				float(f["land_vx"]), dir, traj, cache, lethal, solids):
			return {"ok": true, "takeoff": float(f["takeoff"]),
					"brake_x": float(f.get("brake_x", -1.0))}
	return {"ok": false}


func _compute_plan(level: Dictionary, feet: Vector2,
		dir: float) -> Dictionary:
	var geo: Dictionary = _plan_geometry(level, feet)
	if not bool(geo.get("ok", false)):
		return {"ok": false}
	var lethal: Array = geo["lethal"]
	var solids: Array = geo["solids"]
	if not _plan_engaged(feet, lethal, solids):
		return {"ok": false}
	var vx0: float = 0.0
	if _player != null and is_instance_valid(_player):
		vx0 = _player.velocity.x
	var traj: Dictionary = _plan_trajectory()
	var cache: Dictionary = {}
	var cands: Array = _plan_candidates(feet.x, feet.y, vx0, dir, lethal,
			solids)
	var feasible: Array = []
	var fail_frames: Dictionary = {}
	for ci in range(cands.size()):
		var cand: Dictionary = cands[ci]
		var horiz: Dictionary = _plan_dx(float(cand["vx"]), dir, cache)
		var fl: Dictionary = _plan_flight(float(cand["x"]), feet.y, traj,
				horiz, lethal, solids)
		if not bool(fl.get("ok", false)):
			fail_frames[ci] = int(fl.get("fail_frame", 0))
			continue
		var entry: float = _plan_next_entry(float(fl["land_x"]),
				float(fl["land_y"]), lethal, solids)
		feasible.append({"takeoff": float(cand["x"]),
				"land_x": float(fl["land_x"]),
				"land_y": float(fl["land_y"]),
				"land_vx": float(fl["land_vx"]),
				"runup": entry - float(fl["land_x"]),
				"brake_x": -1.0})
	var picked: Dictionary = _plan_pick(feasible, dir, traj, cache,
			lethal, solids)
	if bool(picked.get("ok", false)):
		return picked
	# Fallback: shorten the jump by releasing the stick mid-air. Some
	# tight chains are infeasible at full speed (the full-speed landing
	# overshoots the gap before the next obstacle) but feasible when
	# the flight is braked to land earlier in the gap. Only brake
	# frames up to the no-brake failure frame can change the outcome.
	var braked: Array = []
	for ci in range(cands.size()):
		var cand2: Dictionary = cands[ci]
		var fail_at: int = int(fail_frames.get(ci, 999))
		for bf in [8, 12, 16, 20, 24, 28, 32, 36, 40, 44]:
			if bf > fail_at and fail_frames.has(ci):
				continue
			var horiz2: Dictionary = _plan_dx_braked(float(cand2["vx"]),
					dir, bf, cache)
			var fl2: Dictionary = _plan_flight(float(cand2["x"]), feet.y,
					traj, horiz2, lethal, solids)
			if not bool(fl2.get("ok", false)):
				continue
			var entry2: float = _plan_next_entry(float(fl2["land_x"]),
					float(fl2["land_y"]), lethal, solids)
			var dxs2: Array = horiz2["dx"]
			var brake_x: float = float(cand2["x"]) + float(dxs2[bf - 1]) \
					- 3.0
			braked.append({"takeoff": float(cand2["x"]),
					"land_x": float(fl2["land_x"]),
					"land_y": float(fl2["land_y"]),
					"land_vx": float(fl2["land_vx"]),
					"runup": entry2 - float(fl2["land_x"]),
					"brake_x": brake_x})
	return _plan_pick(braked, dir, traj, cache, lethal, solids)


# ---------------------------------------------------------------------------
# Greedy policy
# ---------------------------------------------------------------------------

func _decide(level: Dictionary) -> Dictionary:
	var feet: Vector2 = _feet_pos()
	var door: Dictionary = level["door"]
	var dx: float = float(door["x"]) - feet.x
	var dir: float = 0.0
	if absf(dx) > 24.0:
		dir = signf(dx)
		_last_dir = dir
	else:
		dir = 0.0
	var facing: float = dir if dir != 0.0 else _last_dir
	var on_floor: bool = _on_floor()
	# A plan is tied to one ground approach: any air/ground transition
	# invalidates it so the next approach is re-planned from real state.
	# Landing also ends any in-flight braking.
	if _plan_prev_on_floor and not on_floor:
		_plan_active = false
	elif not _plan_prev_on_floor and on_floor:
		_plan_active = false
		_plan_next_check_x = -1e9
		_flight_active = false
		_flight_brake_x = -1.0
	_plan_prev_on_floor = on_floor
	# Probe rect ahead.
	var probe := Rect2(
			feet.x if facing > 0.0 else feet.x - LOOKAHEAD,
			feet.y - 48.0, LOOKAHEAD, 52.0)
	var hazard_ahead: bool = false
	var timed_ahead: bool = false
	for shape in _lethal_shapes(level):
		if _shape_hits_rect(shape, probe):
			hazard_ahead = true
			if bool(shape.get("timed", false)):
				timed_ahead = true
	# Ground / gap / mount sensing from current platform rects.
	var rects: Array = _current_platform_rects(level)
	var ground_ahead: bool = false
	for probe_dx in [30.0, 60.0, 90.0]:
		var px: float = feet.x + facing * probe_dx
		for r in rects:
			if r.position.x <= px and px <= r.position.x + r.size.x \
					and feet.y - 6.0 <= r.position.y \
					and r.position.y <= feet.y + 14.0:
				ground_ahead = true
				break
		if ground_ahead:
			break
	var mount: bool = false
	for r in rects:
		var top: float = r.position.y
		if top < feet.y - 8.0 and top >= feet.y - 100.0:
			var near_edge: float = r.position.x if facing > 0.0 \
					else r.position.x + r.size.x
			var dist_edge: float = (near_edge - feet.x) * facing
			if dist_edge >= -10.0 and dist_edge <= 70.0:
				mount = true
				break
	var gap_ahead: bool = on_floor and not ground_ahead and not mount
	# Blocked (wall) detection.
	if on_floor and dir != 0.0 and _player != null \
			and absf(_player.velocity.x) < 20.0:
		_blocked_frames += 1
	else:
		_blocked_frames = 0
	var blocked: bool = _blocked_frames > BLOCKED_FRAMES_JUMP
	# Timed hazard blocking safe ground: WAIT, then force a jump.
	var safe_here: bool = true
	var prect: Rect2 = _player_rect()
	for shape in _lethal_shapes(level):
		if _shape_hits_rect(shape, prect):
			safe_here = false
			break
	if timed_ahead and on_floor and safe_here and dir != 0.0:
		_block_wait += 1.0 / 60.0
		if _block_wait < BLOCK_WAIT_MAX:
			_plan_active = false
			return {"dir": 0.0, "jump": false, "waiting": true}
		_block_wait = 0.0
	else:
		_block_wait = 0.0
	# Ballistic plan: when one holds, it owns the jump decision until
	# its takeoff point (the greedy trigger firing early is exactly
	# what mistimes chained jumps). A wall hit means the plan is stale.
	var planned_jump: bool = false
	var plan_holds: bool = false
	if blocked:
		_plan_active = false
	elif on_floor and dir != 0.0 and facing > 0.0:
		if _plan_active:
			if feet.x >= _plan_x - 0.1:
				planned_jump = true
				_flight_brake_x = _plan_brake_x
				_flight_active = _plan_brake_x >= 0.0
				_plan_active = false
			elif feet.x > _plan_x + 12.0:
				_plan_active = false
			else:
				plan_holds = true
		if not _plan_active and not planned_jump \
				and feet.x >= _plan_next_check_x:
			var plan: Dictionary = _compute_plan(level, feet, dir)
			if bool(plan.get("ok", false)):
				_plan_x = float(plan["takeoff"])
				_plan_brake_x = float(plan.get("brake_x", -1.0))
				_plan_active = true
				if feet.x >= _plan_x - 0.1:
					planned_jump = true
					_flight_brake_x = _plan_brake_x
					_flight_active = _plan_brake_x >= 0.0
					_plan_active = false
				else:
					plan_holds = true
			else:
				_plan_next_check_x = feet.x + PLAN_RECHECK_DIST
	var jump: bool = false
	if planned_jump:
		jump = true
	elif not plan_holds and on_floor \
			and (hazard_ahead or gap_ahead or mount or blocked):
		jump = true
	if blocked:
		_blocked_frames = 0
	# In-flight braking for a planned shortened jump: release the stick
	# once past the brake point so the flight lands earlier in the gap.
	if not on_floor and _flight_active and _flight_brake_x >= 0.0 \
			and feet.x >= _flight_brake_x:
		dir = 0.0
	return {"dir": dir, "jump": jump, "waiting": false}


# ---------------------------------------------------------------------------
# Attempts / levels
# ---------------------------------------------------------------------------

func _trap_period(level: Dictionary) -> float:
	var best: float = 2.0
	for p in level["platforms"]:
		if p.has("period"):
			best = maxf(best, float(p["period"]))
	for h in level["hazards"]:
		if h.has("period"):
			best = maxf(best, float(h["period"]))
		if h.has("swing"):
			best = maxf(best, float(h["swing"]["period"]))
	return best


func _reset_attempt_state(wait_offset: float) -> void:
	_elapsed = 0.0
	_trig_times = {}
	_block_wait = 0.0
	_blocked_frames = 0
	_best_dist = 1e9
	_noprogress = 0
	_wait_remaining = wait_offset
	_has_moved_away = false
	_deaths_seen = -1
	_plan_active = false
	_plan_brake_x = -1.0
	_plan_next_check_x = -1e9
	_plan_prev_on_floor = false
	_flight_active = false
	_flight_brake_x = -1.0


func _play_attempt(level: Dictionary, steps_cap: int) -> Dictionary:
	var steps: int = 0
	_prev_feet_x = _feet_pos().x
	while steps < steps_cap:
		await physics_frame
		steps += 1
		_elapsed += 1.0 / 60.0
		_update_triggers(level)
		_update_falling_flags()
		if _check_died(level):
			return {"outcome": "died", "steps": steps}
		if _check_won(level):
			return {"outcome": "door", "steps": steps}
		var feet: Vector2 = _feet_pos()
		var door: Dictionary = level["door"]
		var dist: float = absf(float(door["x"]) - feet.x) \
				+ absf(float(door["y"]) - feet.y) * 0.5
		if _wait_remaining > 0.0:
			_wait_remaining -= 1.0 / 60.0
			_set_drive(0.0, false)
			continue
		var decision: Dictionary = _decide(level)
		if not bool(decision.get("waiting", false)):
			if dist < _best_dist - 4.0:
				_best_dist = dist
				_noprogress = 0
			else:
				_noprogress += 1
				if _noprogress > NO_PROGRESS_LIMIT:
					return {"outcome": "no-progress", "steps": steps}
		_set_drive(float(decision["dir"]), bool(decision["jump"]))
	return {"outcome": "timeout", "steps": steps}


func _validate_level_contract(level: Dictionary) -> String:
	# Unknown kind/type = hard error (LEVEL_SCHEMA.md). The runtime
	# must fail fast on these, so the autopilot must never silently
	# play such a level as if it were valid (that would risk a false
	# positive the game itself would refuse to load).
	var kinds: Dictionary = {"solid": true, "dashed": true,
			"falling": true, "tilting": true, "moving": true}
	var types: Dictionary = {"spikes": true, "saw": true,
			"spiked_column": true, "hanging_pillar": true,
			"dotted_line": true}
	for p in level.get("platforms", []):
		if not kinds.has(str(p.get("kind", ""))):
			return "unknown_kind: " + str(p.get("kind", ""))
	for h in level.get("hazards", []):
		if not types.has(str(h.get("type", ""))):
			return "unknown_type: " + str(h.get("type", ""))
	return ""


func _play_level(level: Dictionary, mode: String, steps_cap: int,
		n_strategies: int) -> Dictionary:
	var lid: String = str(level.get("id", "?"))
	var contract_error: String = _validate_level_contract(level)
	if contract_error != "":
		return {"id": lid, "pass": false, "mode": mode, "strategy": -1,
				"steps": 0, "deaths": 0, "reason": contract_error,
				"notes": "rejected before play: unknown kind/type",
				"attempts": []}
	var period: float = _trap_period(level)
	var offsets: Array = [0.0, 0.25, 0.5, 0.75]
	var attempts: Array = []
	var used_mode: String = mode
	var notes: String = ""
	var deaths: int = 0
	for si in range(mini(n_strategies, offsets.size())):
		var wait_offset: float = minf(float(offsets[si]) * period, 4.0)
		# Build (fresh instance per attempt).
		var build_ok: bool = false
		if mode == "game" or mode == "auto":
			var res: Dictionary = await _try_game_build(level)
			if bool(res.get("ok", false)):
				build_ok = true
				used_mode = "game"
				notes = str(res.get("notes", ""))
			elif mode == "game":
				return {"id": lid, "pass": false, "mode": "blocked",
						"strategy": -1, "steps": 0, "deaths": 0,
						"reason": "blocked_no_game_builder",
						"notes": str(res.get("notes", "")),
						"attempts": attempts}
			else:
				notes = "game builder not found; harness fallback " \
						+ "(" + str(res.get("notes", "")) + ")"
				_build_harness_level(level)
				build_ok = true
				used_mode = "harness"
		else:  # harness forced
			_build_harness_level(level)
			build_ok = true
			used_mode = "harness"
		if not build_ok:
			return {"id": lid, "pass": false, "mode": used_mode,
					"strategy": si, "steps": 0, "deaths": deaths,
					"reason": "build_failed", "notes": notes,
					"attempts": attempts}
		await physics_frame
		await physics_frame
		_reset_attempt_state(wait_offset)
		_prev_feet_x = _feet_pos().x
		var attempt: Dictionary = await _play_attempt(level, steps_cap)
		attempt["strategy"] = si
		attempt["wait_offset"] = wait_offset
		attempts.append(attempt)
		await _teardown_level()
		if str(attempt["outcome"]) == "door":
			return {"id": lid, "pass": true, "mode": used_mode,
					"strategy": si, "steps": int(attempt["steps"]),
					"deaths": deaths, "reason": "door",
					"notes": notes, "attempts": attempts}
		if str(attempt["outcome"]) == "died":
			deaths += 1
	var last: Dictionary = attempts[attempts.size() - 1] if not attempts.is_empty() else {}
	return {"id": lid, "pass": false, "mode": used_mode,
			"strategy": -1, "steps": int(last.get("steps", 0)),
			"deaths": deaths,
			"reason": str(last.get("outcome", "failed")),
			"notes": notes, "attempts": attempts}


# ---------------------------------------------------------------------------
# Self-test (fixture levels, harness mode, determinism check)
# ---------------------------------------------------------------------------

func _fixture_path(name: String) -> String:
	if _args.has("fixtures-dir"):
		var p: String = str(_args["fixtures-dir"]) + "/" + name
		if FileAccess.file_exists(p):
			return p
	var script_path: String = get_script().resource_path
	var base: String = script_path.get_base_dir()
	for cand in [base + "/../fixtures/" + name,
			base + "/fixtures/" + name]:
		if FileAccess.file_exists(cand):
			return cand
	return ""


func _run_selftest() -> void:
	print("autopilot --selftest (harness mode)")
	var tuning_path: String = str(_args.get("tuning",
			"res://data/tuning.json"))
	var tun_data: Variant = _load_json(tuning_path)
	if tun_data == null or not (tun_data is Dictionary):
		_die("selftest needs --tuning <tuning.json>", 2)
		return
	_setup_tuning(tun_data)
	seed(int(_args.get("seed", 12345)))
	var pos_path: String = _fixture_path("positive.json")
	var imp_path: String = _fixture_path("negative_impossible.json")
	if pos_path == "" or imp_path == "":
		_die("selftest fixtures not found (pass --fixtures-dir)", 2)
		return
	var pos_data: Dictionary = _load_json(pos_path)
	var imp_data: Dictionary = _load_json(imp_path)
	var pos_level: Dictionary = pos_data["levels"][0]
	var imp_level: Dictionary = imp_data["levels"][0]
	var r1: Dictionary = await _play_level(pos_level, "harness", 2700, 4)
	var r2: Dictionary = await _play_level(pos_level, "harness", 2700, 4)
	var r3: Dictionary = await _play_level(imp_level, "harness", 2700, 4)
	print("  positive run 1: pass=%s steps=%s strategy=%s" % [
			r1["pass"], r1["steps"], r1["strategy"]])
	print("  positive run 2: pass=%s steps=%s strategy=%s" % [
			r2["pass"], r2["steps"], r2["strategy"]])
	print("  impossible: pass=%s reason=%s" % [r3["pass"], r3["reason"]])
	var ok: bool = bool(r1["pass"]) and bool(r2["pass"]) \
			and int(r1["steps"]) == int(r2["steps"]) \
			and not bool(r3["pass"])
	print("SELFTEST %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

func _setup_tuning(tun_data: Dictionary) -> void:
	_tun = tun_data
	_player_cfg = tun_data["player"]
	_bar_y = float(tun_data["control_bar"]["y"])
	_door_w = float(tun_data["door"]["width"])
	_door_h = float(tun_data["door"]["height"])


func _run() -> void:
	_parse_args()
	if bool(_args.get("selftest", false)):
		await _run_selftest()
		return
	var levels_path: String = str(_args.get("levels",
			"res://data/levels.json"))
	var tuning_path: String = str(_args.get("tuning",
			"res://data/tuning.json"))
	var mode: String = str(_args.get("mode", "auto"))
	if mode not in ["auto", "game", "harness"]:
		_die("unknown --mode %s (auto|game|harness)" % mode, 2)
		return
	var tun_data: Variant = _load_json(tuning_path)
	if tun_data == null or not (tun_data is Dictionary):
		_die("cannot load tuning.json: " + tuning_path, 2)
		return
	_setup_tuning(tun_data)
	var data: Variant = _load_json(levels_path)
	if data == null or not (data is Dictionary) \
			or not (data as Dictionary).has("levels"):
		_die("cannot load levels.json: " + levels_path, 2)
		return
	# Fail fast on version mismatch, exactly as the runtime must
	# (LEVEL_SCHEMA.md: never silently load mismatched data).
	if int((data as Dictionary).get("schema_version", -1)) != 1:
		_die("schema_version %s != frozen 1 in %s" % [
				str((data as Dictionary).get("schema_version")),
				levels_path], 2)
		return
	if int((data as Dictionary).get("tuning_version", -1)) \
			!= int(tun_data.get("tuning_version", -2)):
		_die("tuning_version mismatch between levels.json and tuning.json",
				2)
		return
	var levels: Array = (data as Dictionary)["levels"]
	if _args.has("only"):
		var wanted: Dictionary = {}
		for lid in str(_args["only"]).split(","):
			wanted[lid.strip_edges()] = true
		levels = levels.filter(func(lv: Dictionary) -> bool:
			return wanted.has(str(lv.get("id", ""))))
	if _args.has("max-levels"):
		levels = levels.slice(0, int(_args["max-levels"]))
	seed(int(_args.get("seed", 12345)))
	var sha: String = _sha256_file(levels_path)
	var results: Array = []
	var n_pass: int = 0
	for level in levels:
		var res: Dictionary = await _play_level(level, mode,
				int(_args["steps"]), int(_args["strategies"]))
		results.append(res)
		if bool(res["pass"]):
			n_pass += 1
		print("%s: %s mode=%s strategy=%s steps=%s deaths=%s reason=%s" % [
				res["id"], "PASS" if res["pass"] else "FAIL", res["mode"],
				res["strategy"], res["steps"], res["deaths"], res["reason"]])
	var report: Dictionary = {
		"tool": "trap-tower autopilot",
		"levels_path": levels_path,
		"levels_sha256": sha,
		"tuning_path": tuning_path,
		"level_count": results.size(),
		"passed": n_pass,
		"seed": int(_args.get("seed", 12345)),
		"steps_cap": int(_args["steps"]),
		"strategies": int(_args["strategies"]),
		"mode_requested": mode,
		"results": results,
	}
	if _args.has("out"):
		var out_path: String = str(_args["out"])
		var f: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(report, "\t"))
			f.close()
			print("JSON report: " + out_path)
	print("TOTAL: %d/%d levels passed (levels.json sha256 %s)"
			% [n_pass, results.size(), sha])
	quit(0 if n_pass == results.size() else 1)
