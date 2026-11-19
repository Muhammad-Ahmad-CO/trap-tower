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
# obstacles). Timed moving/dashed crossings are solved as (departure,
# t_dep) timed plans with a ride/exit policy; hanging pillars and
# moving saws keep the greedy policy.
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
const PLAN_RECHECK_DIST := 24.0
const PLAN_MAX_FRAMES := 90
const PLAN_DT := 1.0 / 60.0
# Game-true flat-ground air distance (Round 4 Phase A, Task 1):
# a jump from a standing start lands 97.2 px out (24 frames at
# 4.05 px/frame), NOT the 93.15 px (23 frames) a nominal-y0 hand
# derivation gives. The 4.05 px difference is exactly one frame:
# the hero stands at feet.y = floor_top - 0.07 (Godot
# move_and_slide contact margin), and the discrete trajectory
# returns to ground level at frame 22 with offs[22] = +0.064 px,
# which is LESS than the 0.07 px gap, so the feet (159.99) are
# still 0.01 px above the floor top and is_on_floor() is false;
# the body penetrates the floor only on frame 23's move and lands
# at 252.0 from a 154.8 takeoff. _plan_flight already lands 97.2
# px out because it receives the REAL feet.y via _feet_pos(), so
# no trajectory change is needed here; chain/column windows below
# MUST use this 97.2 value. The retired 93.15 number assumed
# y0 = floor_top exactly. floor_snap_length is 6.0 (player.gd),
# not 8.0 (corrected in _build_harness_level, Round 4).
const PLAN_AIR_DX := 97.2
# One frame of run (243 px/s / 60 fps). A pass resting on a
# takeoff within one frame of a window edge is knife-edge:
# flagged marginal, never clean.
const PLAN_KNIFE_EDGE := 4.05

# Schema v3 constants (LEVEL_SCHEMA.md): FLOOR_Y = viewport height,
# fall death = FLOOR_Y + 40, door = 36x54 schema constant. The
# DEPRECATED tuning.json `control_bar` / `door` entries are never
# read (this harness is self-contained: it reads tuning/levels from
# CLI paths and must not depend on the game's TTuning class, so the
# constants are restated here with identical values; the cross-check
# asserts identical door rects across all four implementations).
const FLOOR_Y := 720.0
const FALL_DEATH_Y := 760.0
const DOOR_W := 36.0
const DOOR_H := 54.0
# V3 planning envelope (targets x 0.85): rise 45 / gap 80 / landing
# 48 / run-up 24. Rise gates the greedy mount window (PLAN_MAX_RISE);
# run-up is PLAN_MIN_RUNUP (already 24.0); gap/landing have no
# autopilot literal: gap capability emerges from the planner's exact
# trajectory simulation, and the landing minimum lives in the checker
# and the runtime validator.
const PLAN_MAX_RISE := 45.0

# ---------------------------------------------------------------------------
# Harness physics bodies (fallback mode only; game mode reuses game code).
# ---------------------------------------------------------------------------

class HarnessPlayer extends CharacterBody2D:
	var tun: Dictionary = {}
	var input_dir: float = 0.0
	var jump_just: bool = false

	func _physics_process(delta: float) -> void:
		# Instant start/stop, matching the game player (player.gd
		# sets velocity.x = dir * run_speed every frame; tuning
		# acceleration / air_control are planner-sim only, never
		# read by the game player).
		velocity.x = input_dir * float(tun["run_speed"])
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
var _plan_t_dep: float = -1.0
var _plan_timed_kind: String = ""
var _plan_board: bool = false
var _plan_t_exit: float = -1.0  # mover exit time of a timed plan, or -1
var _plan_blocked_by: String = ""  # column/strip no-window reason, or ""
var _plan_marginal: bool = false  # picked takeoff is knife-edge (<1 frame from a window edge)
var _last_blocked_by: String = ""  # set by _plan_required_runup / _compute_plan
var _ride_since: float = -1.0  # _elapsed when the current ride started, or -1
var _ride_best_t: float = -1.0  # _elapsed when ride progress last improved
var _ride_best: float = -1e9  # best feet.x * dir seen while riding


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
					"timed": h.has("period"), "kind": typ})
		elif typ == "saw":
			var c: Vector2 = _saw_centre(h, _elapsed)
			out.append({"centre": c, "radius": float(h["r"]),
					"timed": h.has("path") or h.has("swing")})
		elif typ == "spiked_column":
			if not _triggered_active(h, idx):
				continue
			out.append({"rect": Rect2(float(h["x"]), float(h["y"]),
					float(h["w"]), float(h["h"])), "timed": false,
					"kind": typ})
		elif typ == "hanging_pillar":
			if _pillar_nodes.has(idx):
				var node: HangingPillar = _pillar_nodes[idx]
				if node.lethal_now:
					var sz: Vector2 = node.plat_size
					out.append({"rect": Rect2(
							node.global_position - sz / 2.0, sz),
							"timed": true, "kind": typ,
							"landed": bool(node.landed)})
			else:
				# Analytic pillar (game mode): periodic cycle or trigger.
				var rect := Rect2(float(h["x"]), float(h["y"]),
						float(h["w"]), float(h["h"]))
				var drop_dist: float = maxf(0.0,
						FLOOR_Y - (rect.position.y + rect.size.y))
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
						out.append({"rect": rect, "timed": true,
								"kind": typ, "landed": false})
				else:
					if _trig_times.has(idx):
						var dy2: float = minf(drop_dist, speed * maxf(0.0,
								_elapsed - float(_trig_times[idx])))
						rect.position.y += dy2
						# P6: a triggered pillar that finished its
						# drop stays down forever; it is a landed
						# step, not a timed hazard to wait for.
						var landed2: bool = dy2 >= drop_dist - 0.001
						out.append({"rect": rect, "timed": true,
								"kind": typ, "landed": landed2})
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
		pil.drop_dist = maxf(0.0, FLOOR_Y - (float(h["y"]) + float(h["h"])))
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
	# 6.0, matching player.gd (the 8.0 here was wrong; Round 4).
	_player.floor_snap_length = 6.0
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
	return Rect2(float(d["x"]) - DOOR_W / 2.0, float(d["y"]) - DOOR_H,
			DOOR_W, DOOR_H)


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
	if feet.y > FALL_DEATH_Y:
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
# Scope (Round 3): falling/tilting platforms count as solid when the
# hero can cross them inside stand_time; moving/dashed platforms are
# time-parameterised geometry (sampled at flight time) plus a timed
# (departure, t_dep) plan for the crossing itself. Only hanging
# pillars and moving (path/swing) saws still disable the planner
# outright, because a planned jump before a pillar drop desyncs the
# greedy wait that makes those levels pass. Once the player is past
# such a feature, the planner may engage for the static stretch that
# follows.
# Triggered and pop-up spikes are planned around as always-lethal
# rects: clearing them ballistically is safe in every phase, and
# waiting for them to "appear" is what made the greedy trigger jump
# too late.

# --- Round 3 (Lane P) helpers -------------------------------------------
# Time-parameterised platform geometry. All phase math uses attempt time
# (_elapsed resets per attempt), never wall time.

func _mover_rect_at(p: Dictionary, t: float) -> Rect2:
	var f: float = 0.5 - 0.5 * cos(TAU * t / float(p["period"]))
	return Rect2(float(p["x"]) + float(p.get("dx", 0.0)) * f,
			float(p["y"]) + float(p.get("dy", 0.0)) * f,
			float(p["w"]), float(p["h"]))


func _dashed_solid_at(p: Dictionary, t: float) -> bool:
	return fposmod(t - float(p.get("phase", 0.0)),
			float(p["period"])) < float(p["on_time"])


func _timed_rect_at(p: Dictionary, t: float) -> Dictionary:
	# {"rect": Rect2, "solid": bool} for a moving/dashed platform at time t.
	if str(p["kind"]) == "moving":
		return {"rect": _mover_rect_at(p, t), "solid": true}
	return {"rect": Rect2(float(p["x"]), float(p["y"]), float(p["w"]),
			float(p["h"])), "solid": _dashed_solid_at(p, t)}


func _strip_window(r: Rect2, dir: float, ground_y: float,
		traj: Dictionary = {}) -> Dictionary:
	# Height-aware takeoff window for a ground-sitting up-spike strip:
	# the hero's feet must clear the strip's top (ground_y - r.y
	# above the ground line) across the whole rect-overlap span
	# [rx0-hw, rx1+hw]. X_lo/X_hi are the x-offsets where the
	# trajectory's rise first reaches / last stays above that height
	# (linear interpolation between frames). For 10px teeth this
	# reproduces the measured window [takeoff+4.1, takeoff+88.8];
	# for taller strips it shrinks, and an empty window proves the
	# strip unjumpable in one jump (e.g. the selftest fixture's
	# 60x24 strip: 70.8px clearance span < 75px needed).
	var hw: float = _plan_half_w()
	var h: float = ground_y - r.position.y
	var t: Dictionary = traj if not traj.is_empty() else _plan_trajectory()
	var offs: Array = t["offs"]
	var step: float = float(_player_cfg["run_speed"]) * PLAN_DT
	var first: int = -1
	var last: int = -1
	for f in range(offs.size()):
		if -float(offs[f]) >= h:
			if first < 0:
				first = f
			last = f
	if first < 0:
		return {"lo": 0.0, "hi": -1.0, "ok": false}
	var x_lo: float
	if first == 0:
		x_lo = step
	else:
		var r0: float = -float(offs[first - 1])
		var r1: float = -float(offs[first])
		var frac: float = (h - r0) / maxf(0.001, r1 - r0)
		x_lo = float(first) * step + frac * step
	var x_hi: float
	if last >= offs.size() - 1:
		x_hi = float(last + 1) * step
	else:
		var ra: float = -float(offs[last])
		var rb: float = -float(offs[last + 1])
		var frac2: float = (ra - h) / maxf(0.001, ra - rb)
		x_hi = float(last + 1) * step + frac2 * step
	var rx0: float = r.position.x
	var rx1: float = r.position.x + r.size.x
	var lo: float = rx1 + hw - x_hi if dir > 0.0 else rx1 + hw + x_lo
	var hi: float = rx0 - hw - x_lo if dir > 0.0 else rx0 - hw + x_hi
	return {"lo": lo, "hi": hi, "ok": lo <= hi}


# --- Round 4 (Lane P4) helpers -------------------------------------------
# Chain windows, column windows, blocked_by reasons. All windows are
# derived from the game-true air distance PLAN_AIR_DX = 97.2 (see the
# constant's comment); the retired planner-nominal 93.15 appears
# nowhere here.

func _rise_span(h: float, traj: Dictionary) -> Dictionary:
	# Takeoff-relative offsets [x_lo, x_hi] where the discrete
	# trajectory's rise is >= h (same frame math as _strip_window).
	var t: Dictionary = traj if not traj.is_empty() else _plan_trajectory()
	var offs: Array = t["offs"]
	var step: float = float(_player_cfg["run_speed"]) * PLAN_DT
	var first: int = -1
	var last: int = -1
	for f in range(offs.size()):
		if -float(offs[f]) >= h:
			if first < 0:
				first = f
			last = f
	if first < 0:
		return {"x_lo": 0.0, "x_hi": -1.0, "ok": false}
	var x_lo: float
	if first == 0:
		x_lo = step
	else:
		var r0: float = -float(offs[first - 1])
		var r1: float = -float(offs[first])
		x_lo = float(first) * step \
				+ (h - r0) / maxf(0.001, r1 - r0) * step
	var x_hi: float
	if last >= offs.size() - 1:
		x_hi = float(last + 1) * step
	else:
		var ra: float = -float(offs[last])
		var rb: float = -float(offs[last + 1])
		x_hi = float(last + 1) * step \
				+ (ra - h) / maxf(0.001, ra - rb) * step
	return {"x_lo": x_lo, "x_hi": x_hi, "ok": x_lo <= x_hi}


func _chain_window(w1: Dictionary, w2: Dictionary,
		land_lo: float, land_hi: float, dir: float) -> Dictionary:
	# Chained-pair window W = W1 n ((L n W2) - dir * PLAN_AIR_DX),
	# where L = [land_lo, land_hi] is the margin-only landing zone
	# between the two strips and D = 97.2 is the game-true air
	# distance (a takeoff lands dir * D ahead of itself). The shift
	# is a translation, so the interval keeps its orientation in
	# both directions. Returns the window plus its centre: the
	# planner picks the CENTRE of W, never the earliest lattice
	# point (the earliest point sits on the window edge and dies
	# on any one-frame slip).
	var llo: float = maxf(land_lo, float(w2["lo"]))
	var lhi: float = minf(land_hi, float(w2["hi"]))
	if llo > lhi:
		return {"lo": 0.0, "hi": -1.0, "ok": false, "centre": 0.0}
	var shift: float = -dir * PLAN_AIR_DX
	var lo: float = maxf(float(w1["lo"]), llo + shift)
	var hi: float = minf(float(w1["hi"]), lhi + shift)
	var ok: bool = lo <= hi
	return {"lo": lo, "hi": hi, "ok": ok,
			"centre": (lo + hi) * 0.5 if ok else 0.0}


func _chain_landing_zone(near_r: Rect2, far_r: Rect2,
		dir: float) -> Dictionary:
	# Margin-only landing zone L between two consecutive strips on
	# the same ground line: the gap between their PLAN_MARGIN-
	# inflated rects, minus the hero half-width on each side.
	# near_r is the strip nearer the hero, far_r the farther one.
	var hw: float = _plan_half_w()
	var lo: float
	var hi: float
	if dir > 0.0:
		lo = near_r.position.x + near_r.size.x + PLAN_MARGIN + hw
		hi = far_r.position.x - PLAN_MARGIN - hw
	else:
		lo = far_r.position.x + far_r.size.x + PLAN_MARGIN + hw
		hi = near_r.position.x - PLAN_MARGIN - hw
	return {"lo": lo, "hi": hi, "ok": lo <= hi}


func _column_window(col: Rect2, ground_y: float, dir: float,
		ground_rect: Rect2, traj: Dictionary = {}) -> Dictionary:
	# Takeoff window for a spiked column, from three constraints
	# (ALL must hold; missing any one was a Round 3 gap):
	#  (a) rise: the flight must stay above the column top across
	#      the whole rect-overlap span (span(h) math, same as
	#      _strip_window). When h_req = 0 this condition is vacuous
	#      on its own, so it must NOT be the only check.
	#  (b) landing-past: the flight must land PAST the column
	#      (landing rect clear of the margined column), using the
	#      game-true air distance PLAN_AIR_DX for a same-level
	#      landing (a drop landing only flies further, so the
	#      same-level bound is the strictest).
	#  (c) takeoff-ground: the takeoff ground must extend under
	#      the takeoff point (rect-overlap: centre within
	#      [ground.x - hw, ground.x + ground.w + hw]). The P3
	#      capsule's 18.24 px window was overstated exactly
	#      because it ignored (c): the step ends at x = 560, so
	#      the true upper bound is 560 + hw = 567.5.
	# Returns blocked_by when no takeoff exists; the planner then
	# refuses the jump instead of dying on the column.
	var hw: float = _plan_half_w()
	var h: float = ground_y - col.position.y
	var span: Dictionary = _rise_span(h, traj)
	if not bool(span.get("ok", false)):
		return {"lo": 0.0, "hi": -1.0, "ok": false, "centre": 0.0,
				"blocked_by": "column_no_rise: span %.2f < %.2f" % [
						float(span["x_hi"]) - float(span["x_lo"]),
						col.size.x + 2.0 * hw]}
	var x_lo: float = float(span["x_lo"])
	var x_hi: float = float(span["x_hi"])
	var cx0: float = col.position.x
	var cx1: float = col.position.x + col.size.x
	var lo_rise: float = cx1 + hw - x_hi if dir > 0.0 \
			else cx1 + hw + x_lo
	var hi_rise: float = cx0 - hw - x_lo if dir > 0.0 \
			else cx0 - hw + x_hi
	# (b) landing-past, same-level air distance. For dir > 0 the
	# bound is a lower bound on the takeoff (landing must reach
	# past the column's far side); for dir < 0 it is an upper
	# bound (landing must reach past the column's near side).
	var land_need: float = cx1 + PLAN_MARGIN + hw if dir > 0.0 \
			else cx0 - PLAN_MARGIN - hw
	var land_bound: float = land_need - dir * PLAN_AIR_DX
	# (c) takeoff-ground bounds.
	var g_lo: float = ground_rect.position.x - hw
	var g_hi: float = ground_rect.position.x + ground_rect.size.x + hw
	var lo: float = maxf(lo_rise, land_bound) if dir > 0.0 \
			else maxf(lo_rise, g_lo)
	var hi: float = minf(hi_rise, g_hi) if dir > 0.0 \
			else minf(hi_rise, land_bound)
	if dir > 0.0:
		lo = maxf(lo, g_lo)
	else:
		hi = minf(hi, g_hi)
	var ok: bool = lo <= hi
	if not ok:
		return {"lo": lo, "hi": hi, "ok": false, "centre": 0.0,
				"blocked_by": "column_no_window: rise [%.2f, %.2f] land-past-bound %.2f ground [%.2f, %.2f]" % [
						lo_rise, hi_rise, land_bound, g_lo, g_hi]}
	return {"lo": lo, "hi": hi, "ok": true,
			"centre": (lo + hi) * 0.5, "blocked_by": ""}


func _ground_rect_at(x: float, y: float, solids: Array) -> Rect2:
	# Solid rect the point (x, y) stands on (top within 3 px),
	# lip-aware: the hero rect may overlap the edge by up to hw.
	var hw: float = _plan_half_w()
	for r in solids:
		var rr: Rect2 = r
		if absf(rr.position.y - y) <= 3.0 \
				and x >= rr.position.x - hw \
				and x <= rr.position.x + rr.size.x + hw:
			return rr
	return Rect2()


func _strip_applicable_window(lethal: Array, strip_r: Rect2,
		ground_y: float, dir: float,
		traj: Dictionary = {}) -> Dictionary:
	# The window that governs a jump over strip_r: the CHAIN
	# window W when strip_r is the first of a chained pair on the
	# same ground line, else the single-strip window W1. Mirrored
	# for dir < 0 (the second strip is the one further left).
	var w1: Dictionary = _strip_window(strip_r, dir, ground_y, traj)
	if not bool(w1.get("ok", false)):
		return {"lo": 0.0, "hi": -1.0, "ok": false, "centre": 0.0,
				"kind": "strip"}
	var best2 := Rect2()
	var best_dist: float = 1e9
	for shape in lethal:
		if not shape.has("rect"):
			continue
		if str(shape.get("kind", "")) == "spiked_column":
			continue
		var r: Rect2 = shape["rect"]
		if r == strip_r:
			continue
		if absf(r.position.y + r.size.y - ground_y) > 14.0:
			continue
		# Second strip must lie ahead of the first (in `dir`),
		# within one chain reach (gap between strips < air range).
		var dist: float = (r.position.x - strip_r.position.x) * dir
		if dist < 0.0 or dist > 320.0:
			continue
		if dist < best_dist:
			best_dist = dist
			best2 = r
	if best_dist > 1e8:
		return {"lo": float(w1["lo"]), "hi": float(w1["hi"]),
				"ok": true, "centre": (float(w1["lo"])
						+ float(w1["hi"])) * 0.5, "kind": "strip"}
	var w2: Dictionary = _strip_window(best2, dir, ground_y, traj)
	if not bool(w2.get("ok", false)):
		return {"lo": float(w1["lo"]), "hi": float(w1["hi"]),
				"ok": true, "centre": (float(w1["lo"])
						+ float(w1["hi"])) * 0.5, "kind": "strip"}
	var zone: Dictionary = _chain_landing_zone(strip_r, best2, dir)
	if not bool(zone.get("ok", false)):
		return {"lo": float(w1["lo"]), "hi": float(w1["hi"]),
				"ok": true, "centre": (float(w1["lo"])
						+ float(w1["hi"])) * 0.5, "kind": "strip"}
	var w: Dictionary = _chain_window(w1, w2, float(zone["lo"]),
			float(zone["hi"]), dir)
	if not bool(w.get("ok", false)):
		# Chained pair with an empty chain window: the first jump
		# cannot land in a spot with a valid second jump. The
		# single-strip window is not a substitute (it lands the
		# hero with no way out), so the chain window governs and
		# the pair is blocked.
		return {"lo": float(w["lo"]), "hi": float(w["hi"]),
				"ok": false, "centre": 0.0, "kind": "chain",
				"blocked_by": "chain_no_window"}
	w["kind"] = "chain"
	return w


func _plan_entry_none(entry: float, dir: float) -> bool:
	return entry > 1e8 if dir > 0.0 else entry < -1e8


func _plan_entry_dist(entry: float, land_x: float, dir: float) -> float:
	return (entry - land_x) * dir


func _plan_reached(feet: Vector2, dir: float) -> bool:
	return feet.x >= _plan_x - 0.1 if dir > 0.0 \
			else feet.x <= _plan_x + 0.1


func _plan_overshot(feet: Vector2, dir: float) -> bool:
	return feet.x > _plan_x + 12.0 if dir > 0.0 \
			else feet.x < _plan_x - 12.0


func _recheck_due(feet: Vector2, dir: float) -> bool:
	if absf(_plan_next_check_x) > 1e8:
		return true  # sentinel from reset: always due once
	return feet.x >= _plan_next_check_x if dir > 0.0 \
			else feet.x <= _plan_next_check_x


func _nearest_strip(level: Dictionary, feet: Vector2,
		dir: float) -> Dictionary:
	# Nearest ground-sitting up-spike strip ahead + its takeoff window.
	var best_r := Rect2()
	var best_dist: float = 1e9
	var found: bool = false
	for shape in _lethal_shapes(level):
		if not shape.has("rect"):
			continue
		var r: Rect2 = shape["rect"]
		if absf(r.position.y + r.size.y - feet.y) > 14.0:
			continue
		var near: float = r.position.x if dir > 0.0 \
				else r.position.x + r.size.x
		var dist: float = (near - feet.x) * dir
		if dist < -20.0:
			continue
		if dist < best_dist:
			best_dist = dist
			best_r = r
			found = true
	if not found:
		return {"ok": false}
	var win: Dictionary = _strip_window(best_r, dir, feet.y)
	return {"ok": bool(win["ok"]), "rect": best_r,
			"lo": float(win["lo"]), "hi": float(win["hi"])}


func _mover_ride_state(level: Dictionary, feet: Vector2, on_floor: bool,
		dir: float) -> Dictionary:
	# Riding = standing on a moving platform (no solid underfoot at
	# this x). Returns step_off / jump_off exit decisions, plus --
	# Round 4 -- the intra-mover walk target (walk_to), the mover's
	# period (2-period safety net), the mover rect, and a mountable
	# higher destination (mount_dest) for the jump-off: the old
	# code only accepted SAME-LEVEL solids as exits, so on D15S2
	# (destination 40 px above the mover) step_off/jump_off were
	# false in every phase of every period and the hero rode
	# forever. The mount exit is decided by the exact flight sim
	# in _ride_jump_off, not by this function.
	if not on_floor:
		return {"riding": false}
	for p in level["platforms"]:
		if str(p["kind"]) != "moving":
			continue
		var r: Rect2 = _mover_rect_at(p, _elapsed)
		if absf(r.position.y - feet.y) > 3.0:
			continue
		if feet.x < r.position.x or feet.x > r.position.x + r.size.x:
			continue
		var on_solid: bool = false
		for q in level["platforms"]:
			if str(q["kind"]) != "solid":
				continue
			if absf(float(q["y"]) - feet.y) <= 3.0 \
					and feet.x >= float(q["x"]) \
					and feet.x <= float(q["x"]) + float(q["w"]):
				on_solid = true
				break
		if on_solid:
			continue
		var step_off: bool = false
		var jump_off: bool = false
		if dir > 0.0:
			var l2: float = 1e9
			for q in level["platforms"]:
				if str(q["kind"]) != "solid":
					continue
				if absf(float(q["y"]) - feet.y) > 3.0:
					continue
				if float(q["x"]) >= float(p["x"]) + float(p["w"]) - 1.0:
					l2 = minf(l2, float(q["x"]))
			if l2 < 1e8:
				var edge: float = r.position.x + r.size.x
				step_off = edge >= l2 - 8.0
				jump_off = not step_off and (l2 - edge) <= 40.0
		else:
			var l2b: float = -1e9
			for q in level["platforms"]:
				if str(q["kind"]) != "solid":
					continue
				if absf(float(q["y"]) - feet.y) > 3.0:
					continue
				if float(q["x"]) + float(q["w"]) <= float(p["x"]) + 1.0:
					l2b = maxf(l2b, float(q["x"]) + float(q["w"]))
			if l2b > -1e8:
				var edge2: float = r.position.x
				step_off = edge2 <= l2b + 8.0
				jump_off = not step_off and (edge2 - l2b) <= 40.0
		# Intra-mover walk target: stand just inside the exit
		# edge so the mover cannot slide out from under the hero
		# (the D15S2 lip stranding: waiting still at x~327.3
		# while the mover slid away).
		var hw2: float = _plan_half_w()
		var walk_to: float = r.position.x + r.size.x - hw2 - 1.0 \
				if dir > 0.0 else r.position.x + hw2 + 1.0
		# Mountable higher destination in `dir` (top up to
		# PLAN_MAX_RISE above the mover): the jump-off target.
		var mount_dest: Dictionary = {}
		var best_md: float = 1e9
		for q in level["platforms"]:
			if str(q["kind"]) != "solid":
				continue
			var qtop: float = float(q["y"])
			if qtop < feet.y - PLAN_MAX_RISE or qtop >= feet.y - 3.0:
				continue
			var qnear: float = float(q["x"]) if dir > 0.0 \
					else float(q["x"]) + float(q["w"])
			var mdist: float = (qnear - feet.x) * dir
			if mdist < -20.0 or mdist > 320.0:
				continue
			if mdist < best_md:
				best_md = mdist
				mount_dest = {"x": qnear, "top": qtop}
		return {"riding": true, "step_off": step_off,
				"jump_off": jump_off, "walk_to": walk_to,
				"period": float(p.get("period", 0.0)),
				"mover_rect": r, "mount_dest": mount_dest}
	return {"riding": false}


func _plan_half_w() -> float:
	return float(_player_cfg["width"]) / 2.0


func _plan_height() -> float:
	return float(_player_cfg["height"])


func _plan_geometry(level: Dictionary, feet: Vector2,
		dir: float) -> Dictionary:
	# Direction-aware window: geometry only on the approach side.
	var hx_lo: float = feet.x - 40.0 if dir > 0.0 else feet.x - 900.0
	var hx_hi: float = feet.x + 900.0 if dir > 0.0 else feet.x + 40.0
	# Solids first (P6): the pillar timing check below windows the
	# landed pillar against the stance ground, so solids must exist
	# before the disable loop runs. (Moved up unchanged from below.)
	var solids: Array = []
	var timed: Array = []
	var flight_solids: Array = []
	for p in level["platforms"]:
		var kind: String = str(p["kind"])
		var r := Rect2(float(p["x"]), float(p["y"]), float(p["w"]),
				float(p["h"]))
		var span_lo: float = r.position.x - absf(float(p.get("dx", 0.0)))
		var span_hi: float = r.position.x + r.size.x \
				+ absf(float(p.get("dx", 0.0)))
		if span_hi < hx_lo or span_lo > hx_hi:
			continue
		if kind == "solid":
			solids.append(r)
		elif kind == "falling" or kind == "tilting":
			# Solid-if-crossable-in-stand_time: crossing the platform
			# at run speed must fit inside stand_time (90px at
			# 243px/s = 0.37s < stand_time 1.0-1.2s). A platform too
			# wide to cross before it falls blocks flights but is
			# never a landing.
			var cross: float = float(p["w"]) \
					/ float(_player_cfg["run_speed"])
			if cross <= float(p.get("stand_time", 1.0)):
				solids.append(r)
			else:
				flight_solids.append(r)
		elif kind == "moving" or kind == "dashed":
			# Time-parameterised geometry, never ok:false: the
			# planner samples these rects at flight time instead.
			timed.append(p)
	# P6: landed rects of triggered pillars proven down by takeoff
	# time (see the pillar branch below); the lethal loop turns
	# them into static column obstacles.
	var landed_pillars: Array = []
	# Hanging pillars / moving saws ahead still disable the planner:
	# their lethal timing stays the greedy policy's business.
	# P5: scoped to the planning horizon (PLAN_HORIZON ahead),
	# not ANY feature anywhere ahead. The old blanket disable
	# killed the planner for the whole level (e.g. D07S3's stair
	# strips 400+ px before its pillar at 1080, D08's strips
	# before its swing saw): a feature beyond the horizon cannot
	# affect any flight the planner can propose from here, and
	# the planner re-checks every 24 px, so it disengages again
	# as the feature enters the horizon.
	for hidx in range(level["hazards"].size()):
		var h: Dictionary = level["hazards"][hidx]
		var typ0: String = str(h.get("type", ""))
		if typ0 == "hanging_pillar":
			var px0: float = float(h["x"])
			var px1: float = px0 + float(h["w"])
			var ahead: bool = (dir > 0.0 and px1 > feet.x \
						and px0 < feet.x + PLAN_HORIZON) \
					or (dir < 0.0 and px0 < feet.x \
						and px1 > feet.x - PLAN_HORIZON)
			if not ahead:
				continue
			# P5: a PERIODIC pillar only disables the planner
			# while it is dropping/rising, or about to drop.
			# While hanging it is harmless (hazard_node kills()
			# is false and its solid is disabled), and the
			# blanket disable killed the saw plan behind it
			# (D44S2V1: pillar at 540 disabled the planner for
			# the whole approach, so the hero ran greedily into
			# the saw at 600 while the pillar was still high).
			# Phase math mirrors hazard_node._update_pillar:
			# hang_time = period - drop_time - 1.0, cyc =
			# fposmod(elapsed - phase, period). The 0.75 s
			# buffer covers passing under the pillar
			# ((60 + 15) / 243 = 0.31 s) plus one flight
			# (0.38 s); the planner re-checks every 24 px, so
			# it disengages again as the drop approaches.
			if h.has("period"):
				var skip_disable: bool = false
				var per: float = float(h.get("period", 0.0))
				var dsp: float = float(h.get("drop_speed", 0.0))
				if per > 0.0 and dsp > 0.0:
					var dd: float = maxf(0.0, feet.y
							- (float(h["y"]) + float(h["h"])))
					var dt: float = dd / dsp
					var ht: float = maxf(0.0, per - dt - 1.0)
					var cyc: float = fposmod(_elapsed
							- float(h.get("phase", 0.0)), per)
					if ht - cyc >= 0.75:
						skip_disable = true
				if not skip_disable:
					return {"ok": false}
				continue
			# P6: a TRIGGERED pillar is a static step once it is
			# down -- it stays down until restart (hazard_node:
			# pillar_hanging = false forever after the drop), so
			# the old blanket disable ("drop is hero-triggered,
			# not phase-predictable") made the hero run greedily
			# into the landed wall (D06S1V1: died at feet 576.3
			# on landed pillar [580,616,40,104], takeoff ~572,
			# ~8 px past G7's proven window end 564.4). Treat it
			# as a landed column when it will be down by the
			# earliest window takeoff: the drop is fully timed
			# (trigger_x + drop_time), and the window's column
			# math is the same _column_window the planner already
			# uses for spiked columns. Until then keep the
			# disable; the planner re-checks every 24 px and the
			# drop finishes while the hero is still ~130 px out
			# (trigger ~260 px before the pillar, drop <= 0.75 s
			# = ~180 px of run), so the plan forms in time.
			var home_y: float = float(h["y"])
			var pil_h: float = float(h["h"])
			var drop_dist: float = maxf(0.0,
					FLOOR_Y - (home_y + pil_h))
			var drop_speed: float = float(h.get("drop_speed", 700.0))
			var drop_time: float = drop_dist / maxf(drop_speed, 1.0)
			var trig_x: float = float(h.get("drop_trigger_x", 0.0))
			var t_land: float
			if _trig_times.has(hidx):
				t_land = maxf(0.0, drop_time - (_elapsed
						- float(_trig_times[hidx])))
			else:
				t_land = maxf(0.0, (trig_x - feet.x) * dir
						/ float(_player_cfg["run_speed"])) \
						+ drop_time
			var landed_r := Rect2(float(h["x"]), FLOOR_Y - pil_h,
					float(h["w"]), pil_h)
			# P6 fix: the takeoff ground is the ground under the
			# pillar, not the stance ground. D06S5's floor is
			# segmented (solid/dashed/solid/falling/solid): the
			# stance ground (the falling platform [620,640,120,20])
			# ends at 740 while the pillar takeoff window sits at
			# ~865 on the floor slab [740,640,540,80], so the
			# stance ground made the window empty and the planner
			# stayed disabled (hero died greedily on the 800
			# spikes). The takeoff is ~35 px before the pillar,
			# so the pillar's own ground is the takeoff ground;
			# fall back to the stance ground when the pillar
			# stands over a gap.
			var near_x: float = landed_r.position.x if dir > 0.0 \
					else landed_r.position.x + landed_r.size.x
			var ground_r: Rect2 = _ground_rect_at(near_x, feet.y,
					solids)
			if ground_r.size.x <= 0.0:
				ground_r = _ground_rect_at(feet.x, feet.y, solids)
			var safe: bool = false
			if ground_r.size.x > 0.0:
				var cwin: Dictionary = _column_window(landed_r,
						feet.y, dir, ground_r)
				if bool(cwin.get("ok", false)):
					# Earliest takeoff the window allows, in
					# travel order; the pick can only take off
					# at or after the window, never before it,
					# so the window edge is the conservative
					# arrival time. The 0.02 s margin covers the
					# one-frame slop between the autopilot's
					# trigger record and the game's own trigger
					# detection -- nothing more is needed:
					# t_land already OVERSTATES the remaining
					# drop (the trigger is recorded up to a
					# frame late), and the jump can only fire
					# late (first step past the takeoff), never
					# early. A bigger margin strands the hero
					# (D06S5V1: landed 9.8 px / 0.04 s short of
					# the window with the pillar already down).
					var edge: float = float(cwin["lo"]) \
							if dir > 0.0 else float(cwin["hi"])
					var t_takeoff: float = maxf(0.0,
							(edge - feet.x) * dir
							/ float(_player_cfg["run_speed"]))
					safe = t_takeoff >= t_land + 0.02
			if not safe:
				return {"ok": false}
			landed_pillars.append(landed_r)
		elif typ0 == "saw" and (h.has("path") or h.has("swing")):
			# P6: disable only when the disc's ACTUAL swept box can
			# meet a body the planner could put there. The old
			# full-circle reach for swing saws (pivot +/- reach)
			# disabled the planner for the whole approach (D08S3:
			# the 12-degree swing at 1080 sweeps x 1033..1127 but
			# the circle claimed 818..1342, killing the stair
			# plans while the hero was still at x~600), and a disc
			# far above the hero's jump apex (D08S4/S5: disc bottom
			# y~436, apex body-top y~544 from the floor) can never
			# be hit at all. Swept box: 13-sample arc for swing
			# (the checker's sampling), segment bbox for path.
			# Body band: apex body-top (feet.y - 57 rise - 39
			# height) widened by one mount (45) for followup
			# flights, down to the deepest drop landing in one
			# flight (feet.y + 220). The planner re-checks every
			# 24 px, so the disable re-engages as the saw enters
			# the band.
			var bx0: float
			var bx1: float
			var by0: float
			var by1: float
			if h.has("path"):
				var pth: Dictionary = h["path"]
				var prr: float = float(h["r"])
				bx0 = minf(float(h["x"]), float(pth["x2"])) - prr
				bx1 = maxf(float(h["x"]), float(pth["x2"])) + prr
				by0 = minf(float(h["y"]), float(pth["y2"])) - prr
				by1 = maxf(float(h["y"]), float(pth["y2"])) + prr
			else:
				var s0: Dictionary = h["swing"]
				var piv := Vector2(float(s0["pivot_x"]),
						float(s0["pivot_y"]))
				var off: Vector2 = Vector2(float(h["x"]),
						float(h["y"])) - piv
				var half_arc: float = deg_to_rad(
						float(s0["arc_deg"])) * 0.5
				var srr: float = float(h["r"])
				bx0 = 1e9
				bx1 = -1e9
				by0 = 1e9
				by1 = -1e9
				for k in range(13):
					var ang: float = -half_arc + 2.0 * half_arc \
							* float(k) / 12.0
					var c: Vector2 = piv + off.rotated(ang)
					bx0 = minf(bx0, c.x - srr)
					bx1 = maxf(bx1, c.x + srr)
					by0 = minf(by0, c.y - srr)
					by1 = maxf(by1, c.y + srr)
			var band_top: float = feet.y - 141.0
			var band_bot: float = feet.y + 220.0
			var x_hit: bool = (dir > 0.0 and bx1 > feet.x \
						and bx0 < feet.x + PLAN_HORIZON) \
					or (dir < 0.0 and bx0 < feet.x \
						and bx1 > feet.x - PLAN_HORIZON)
			var y_hit: bool = by1 > band_top and by0 < band_bot
			if x_hit and y_hit:
				return {"ok": false}
	var lethal: Array = []
	for h in level["hazards"]:
		var typ: String = str(h.get("type", ""))
		if typ == "dotted_line":
			continue
		if typ == "hanging_pillar":
			# P6: a triggered pillar proven landed (see the disable
			# loop above) is a static column in the planner's
			# lethal set -- kind spiked_column, so the planner
			# windows it with _column_window and plans over it
			# (D06/D24/D25). Periodic pillars and unlanded
			# triggered pillars stay excluded: their drop is still
			# the greedy wait's business. Pillar x values are
			# unique within a level, so the x match is exact.
			for pr in landed_pillars:
				if absf(float(pr.position.x) - float(h["x"])) < 0.5:
					var lr := Rect2(pr.position.x - PLAN_MARGIN,
							pr.position.y - PLAN_MARGIN,
							pr.size.x + 2.0 * PLAN_MARGIN,
							pr.size.y + 2.0 * PLAN_MARGIN)
					if lr.position.x + lr.size.x >= hx_lo \
							and lr.position.x <= hx_hi:
						lethal.append({"rect": pr, "land_rect": lr,
								"kind": "spiked_column"})
			continue
		if typ == "saw" and (h.has("path") or h.has("swing")):
			continue
		if typ == "spikes" or typ == "spiked_column":
			# REAL rect for takeoff/standing/flight checks; the 4px
			# margin lives ONLY on the landing rect (land_rect).
			var real := Rect2(float(h["x"]), float(h["y"]),
					float(h["w"]), float(h["h"]))
			var lr := Rect2(float(h["x"]) - PLAN_MARGIN,
					float(h["y"]) - PLAN_MARGIN,
					float(h["w"]) + 2.0 * PLAN_MARGIN,
					float(h["h"]) + 2.0 * PLAN_MARGIN)
			if lr.position.x + lr.size.x >= hx_lo \
					and lr.position.x <= hx_hi:
				# Round 4: carry the hazard kind so the planner
				# can tell a spiked_column (column window +
				# blocked_by) from a spikes strip (strip/chain
				# window) in _plan_required_runup.
				lethal.append({"rect": real, "land_rect": lr,
						"kind": typ})
		elif typ == "saw":
			var c := Vector2(float(h["x"]), float(h["y"]))
			if c.x + float(h["r"]) >= hx_lo \
					and c.x - float(h["r"]) <= hx_hi:
				# P5: the planner's flight/standing checks use
				# the REAL disc radius (the game's kills() test
				# is closest-distance < r, no margin). The old
				# r + PLAN_MARGIN erased the only crossing
				# takeoffs for floor saws (D03S1V2: the late
				# window [414, 415] grazes at 27 px from a
				# 24 px disc -- real-clear by 3 px, margin-
				# rejected) and truncated _plan_candidates at
				# stances the game accepts. The margin survives
				# ONLY as "land_radius" for the landing check
				# in _plan_flight, where it guards the
				# landing-position model error.
				lethal.append({"centre": c,
						"radius": float(h["r"]),
						"land_radius": float(h["r"]) + PLAN_MARGIN})
	return {"ok": true, "lethal": lethal, "solids": solids,
			"timed": timed, "flight_solids": flight_solids}


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
	# Instant game player (player.gd): velocity.x = dir * run_speed
	# every frame; no accel ramp. vx0 is irrelevant to the motion and
	# survives only in the cache key / signature.
	var speed: float = float(_player_cfg["run_speed"])
	var vx: float = dir * speed
	var dxs: Array = []
	var vxs: Array = []
	var dx: float = 0.0
	for f in range(PLAN_MAX_FRAMES):
		dx += vx * PLAN_DT
		dxs.append(dx)
		vxs.append(vx)
	var res: Dictionary = {"dx": dxs, "vx": vxs}
	cache[key] = res
	return res


func _plan_dx_braked(vx0: float, dir: float, brake_frame: int,
		cache: Dictionary) -> Dictionary:
	# Horizontal motion with the stick released from brake_frame on:
	# velocity is dir * run_speed before, 0 at brake_frame immediately
	# (instant stop -- no decay). Vertical motion is unchanged
	# (shared trajectory). brake_frame is the count of full-speed
	# frames before release.
	var key: String = "%d:%d" % [int(round(vx0)), brake_frame]
	if cache.has(key):
		return cache[key]
	var speed: float = float(_player_cfg["run_speed"])
	var dxs: Array = []
	var vxs: Array = []
	var dx: float = 0.0
	for f in range(PLAN_MAX_FRAMES):
		var vx: float = dir * speed if f < brake_frame else 0.0
		dx += vx * PLAN_DT
		dxs.append(dx)
		vxs.append(vx)
	var res: Dictionary = {"dx": dxs, "vx": vxs}
	cache[key] = res
	return res


func _plan_flight(x0: float, y0: float, traj: Dictionary,
		horiz: Dictionary, lethal: Array, solids: Array,
		t0: float = -1.0, timed: Array = [],
		flight_solids: Array = [], _clipped: bool = false) -> Dictionary:
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	# Mutable copies: ceiling clipping (below) rebuilds the
	# trajectory from the bump frame with vy = 0.
	var offs: Array = (traj["offs"] as Array).duplicate()
	var falling: Array = (traj["falling"] as Array).duplicate()
	var dxs: Array = horiz["dx"]
	var vxs: Array = horiz["vx"]
	var n: int = mini(offs.size(), dxs.size())
	var start_t: float = _elapsed if t0 < 0.0 else t0
	var prev_feet: float = y0
	for f in range(n):
		var x: float = x0 + float(dxs[f])
		var feet: float = y0 + float(offs[f])
		var rect := Rect2(x - hw, feet - ph, 2.0 * hw, ph)
		for shape in lethal:
			if _shape_hits_rect(shape, rect):
				return {"ok": false, "fail_frame": f}
		# Timed rects sampled at this flight frame's time.
		var t: float = start_t + float(f) * PLAN_DT
		var landable: Array = []
		landable.append_array(solids)
		var blocking: Array = []
		blocking.append_array(solids)
		blocking.append_array(flight_solids)
		for tp in timed:
			var tr: Dictionary = _timed_rect_at(tp, t)
			if bool(tr["solid"]):
				var trr: Rect2 = tr["rect"]
				landable.append(trr)
				blocking.append(trr)
		if bool(falling[f]):
			for r in landable:
				var rr: Rect2 = r
				var top: float = rr.position.y
				# Crossing-point landing test (Round 4): the body
				# lands on a top face only if it overlaps the
				# solid at the moment its feet cross the top
				# plane (linear interpolation between the
				# previous and current frame). The physics engine
				# collides on the swept shape, but a swept
				# INTERVAL overstates the overlap: it also counts
				# a corner the body reaches only AFTER falling
				# below the top, which the game resolves as a
				# wall hit, not a floor landing (D15S2 mover-2
				# exit: the sweep overlapped the solid by 0.97 px
				# at feet 604.4, 4.4 px below its top, so the
				# planner "landed" the flight at 1033.5 while the
				# game slid the hero down the solid's left face
				# to its death at 1036.5). The old endpoint-centre
				# test (x within [span - 6, span + 6]) missed the
				# other side of the same coin (D02S4V1: hop from
				# 272.5, endpoint 369.7, 9.7 px past block 1's
				# edge at 360, but the f=22 rect overlapped the
				# block by 1.85 px -- the game grants is_on_floor()
				# for exactly one frame there). The crossing x
				# catches the lip (crossing x ~365.7, rect
				# overlaps the block by 1.8 px) and rejects the
				# corner clip (crossing x ~1025.4, rect ends
				# 7.1 px short of the solid).
				var px: float = x if f == 0 \
						else x0 + float(dxs[f - 1])
				var alpha: float = clampf((top - prev_feet) \
						/ maxf(0.001, feet - prev_feet), 0.0, 1.0)
				var cross_x: float = px + (x - px) * alpha
				if prev_feet <= top + 1.0 and feet >= top \
						and cross_x - hw < rr.position.x + rr.size.x \
						and cross_x + hw > rr.position.x:
					var land_rect := Rect2(x - hw, top - ph, 2.0 * hw, ph)
					for shape2 in lethal:
						# Landing check uses the MARGINED rect only
						# for rect hazards, and the MARGINED disc
						# (land_radius) for saws: a landing must
						# keep 4 px clear of the disc, while the
						# in-flight check uses the real radius
						# (P5: the margin erased the only crossing
						# takeoffs for floor saws).
						var lshape: Dictionary = shape2
						if shape2.has("land_rect"):
							lshape = {"rect": shape2["land_rect"]}
						elif shape2.has("land_radius"):
							lshape = {"centre": shape2["centre"],
									"radius": shape2["land_radius"]}
						if _shape_hits_rect(lshape, land_rect):
							return {"ok": false, "fail_frame": f}
					for r2 in solids:
						var rr2: Rect2 = r2
						if rr2 != rr and rr2.intersects(land_rect):
							return {"ok": false, "fail_frame": f}
					# P5 lip slide (D11S5V1, D02S2): the crossing
					# test grants a landing whose rect overlaps
					# the solid by only a couple of px (a lip),
					# but the game slides the hero TWO frames
					# past the planner's crossing x before the
					# floor check fails -- the hero's ACTUAL
					# stance is 8.1 px past the predicted
					# land_x, and from there the followup finds
					# no grounded stance at all (D11S5V1: sim
					# 920.5, game 928.6, grounded range ends
					# 927.5; the hero then falls onto the
					# spikes). When the crossing overlap is under
					# half the hero width (7.5 px), shift the
					# granted land_x two frames in the travel
					# direction so every downstream check
					# (usefulness, followup, pick) is evaluated
					# from where the hero really ends up. A solid
					# landing (overlap >= 7.5 px) is untouched; a
					# lip the game grants for one frame (D02S4V1,
					# 1.85 px) still counts, just from its slid
					# position.
					var overlap: float = minf(cross_x + hw,
							rr.position.x + rr.size.x) \
							- maxf(cross_x - hw, rr.position.x)
					var land_x2: float = x
					# Only slide a landing the hero is still
					# RUNNING into (land_vx != 0): a braked
					# flight stops dead on the lip (no momentum
					# to carry it past the edge), so its landing
					# is where the sim says it is. Sliding a
					# braked lip landing broke D08S2/D22S5/
					# D30S2/D30S4, whose routes land braked on
					# step lips and jump again from the one-frame
					# floor (D02S4V1 pattern).
					if overlap < 7.5 and absf(float(vxs[f])) > 0.0:
						var dir_s: float = 1.0
						for d in dxs:
							if float(d) != 0.0:
								dir_s = 1.0 if float(d) > 0.0 else -1.0
								break
						land_x2 = x + dir_s * 8.1
					return {"ok": true, "land_x": land_x2, "land_y": top,
							"land_vx": float(vxs[f]), "land_frame": f}
		for r in blocking:
			if (r as Rect2).intersects(rect):
				# P5 ceiling clip (head bump): a solid whose
				# bottom is well above the takeoff ground line
				# is a ceiling, not a wall. The real game zeroes
				# vy on the head hit and the hero falls back --
				# the flight continues, clipped, and can still
				# clear a low strip (D15S3/D16S2/D27S3: floor
				# y520, beam bottom y436, full-jump head at
				# y424 -- every flight was rejected, though a
				# clipped jump still rises 45 px, far above the
				# 10 px teeth). Rebuild the trajectory from the
				# bump frame with vy = 0 and re-simulate. A wall
				# (bottom at/below the ground line) still fails.
				if not _clipped and not bool(falling[f]) \
						and (r as Rect2).position.y \
								+ (r as Rect2).size.y <= y0 - 30.0:
					var new_offs: Array = offs.slice(0, f)
					var new_falling: Array = falling.slice(0, f)
					var vy2: float = 0.0
					var off2: float = float(offs[f - 1]) if f > 0 \
							else 0.0
					var g2: float = float(_player_cfg["gravity"])
					var mf2: float = float(
							_player_cfg["max_fall_speed"])
					for k in range(f, n):
						if k == f:
							new_offs.append(off2)
							new_falling.append(false)
						else:
							vy2 = minf(vy2 + g2 * PLAN_DT, mf2)
							off2 += vy2 * PLAN_DT
							new_offs.append(off2)
							new_falling.append(vy2 > 0.0)
					return _plan_flight(x0, y0,
							{"offs": new_offs,
									"falling": new_falling},
							horiz, lethal, solids, t0, timed,
							flight_solids, true)
				return {"ok": false, "fail_frame": f}
		if feet > FALL_DEATH_Y:
			return {"ok": false, "fail_frame": f}
		prev_feet = feet
	return {"ok": false, "fail_frame": n}


func _plan_candidates(x0: float, y0: float, vx0: float, dir: float,
		lethal: Array, solids: Array, timed: Array = [],
		t_now: float = -1.0) -> Array:
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	var speed: float = float(_player_cfg["run_speed"])
	var step: float = speed * PLAN_DT  # 4.05 px/frame, from step 1
	var now: float = _elapsed if t_now < 0.0 else t_now
	var out: Array = []
	var x: float = x0
	for k in range(90):
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
		# Grounded = the hero RECT still overlaps the ground
		# (centre within [x - hw, x + w + hw]), not centre-within-
		# span: the game grants is_on_floor() for exactly one frame
		# on an edge lip (D02S4V1: 1.8 px overlap), and a planned
		# takeoff from that lip frame is valid. The same lip rule
		# bounds the column window's takeoff-ground constraint
		# (P3: step ends at 560, last lip takeoff 564.1).
		var grounded: bool = false
		for r in solids:
			var rr: Rect2 = r
			if absf(rr.position.y - y0) <= 3.0 \
					and x >= rr.position.x - hw \
					and x <= rr.position.x + rr.size.x + hw:
				grounded = true
				break
		if not grounded:
			for tp in timed:
				var tr: Dictionary = _timed_rect_at(tp, now)
				if not bool(tr["solid"]):
					continue
				var trr: Rect2 = tr["rect"]
				if absf(trr.position.y - y0) <= 3.0 \
						and x >= trr.position.x - hw \
						and x <= trr.position.x + trr.size.x + hw:
					grounded = true
					break
		if not grounded:
			break
		out.append({"x": x, "vx": dir * speed})
		if absf(x - x0) >= PLAN_MAX_TAKEOFF_AHEAD:
			break
		x += dir * step
	return out


func _plan_next_entry(land_x: float, land_y: float, lethal: Array,
		solids: Array, dir: float, door_x: float) -> float:
	# Nearest hard entry ahead in `dir`. Entries beyond the door, and
	# unmountable tops (>57px above land_y) that do not reach the
	# ground line, never generate an entry -- so a landing past the
	# last spike yields 1e9/-1e9 and the _plan_pick shortcut fires.
	# The right wall (1232,150) is excluded by the door rule.
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	var best: float = 1e9 if dir > 0.0 else -1e9
	for shape in lethal:
		if shape.has("rect"):
			var r: Rect2 = shape["rect"]
			if r.position.y + r.size.y > land_y - ph \
					and r.position.y < land_y:
				if land_y - r.position.y > 57.0 \
						and r.position.y + r.size.y <= land_y - 39.0:
					continue
				var e: float = r.position.x - hw if dir > 0.0 \
						else r.position.x + r.size.x + hw
				if dir > 0.0:
					if e > door_x - 18.0:
						continue
					if e > land_x - 28.0:
						best = minf(best, e)
				else:
					if e < door_x + 18.0:
						continue
					if e < land_x + 28.0:
						best = maxf(best, e)
		else:
			var c: Vector2 = shape["centre"]
			var rad: float = shape["radius"]
			if c.y + rad > land_y - ph and c.y - rad < land_y:
				if land_y - (c.y - rad) > 57.0 \
						and c.y + rad <= land_y - 39.0:
					continue
				var e2: float = c.x - rad - hw if dir > 0.0 \
						else c.x + rad + hw
				if dir > 0.0:
					if e2 > door_x - 18.0:
						continue
					if e2 > land_x - 28.0:
						best = minf(best, e2)
				else:
					if e2 < door_x + 18.0:
						continue
					if e2 < land_x + 28.0:
						best = maxf(best, e2)
	for r in solids:
		var rr: Rect2 = r
		if rr.position.y < land_y - 8.0 \
				and rr.position.y + rr.size.y > land_y - ph:
			if land_y - rr.position.y > 57.0 \
					and rr.position.y + rr.size.y <= land_y - 39.0:
				continue
			var e3: float = rr.position.x - hw if dir > 0.0 \
					else rr.position.x + rr.size.x + hw
			if dir > 0.0:
				if e3 > door_x - 18.0:
					continue
				if e3 > land_x - 28.0:
					best = minf(best, e3)
			else:
				if e3 < door_x + 18.0:
					continue
				if e3 < land_x + 28.0:
					best = maxf(best, e3)
	return best


# NOTE (v3): the 170.0 vertical window below is a conservative
# planner-engagement window retained unchanged from v2. Wider is
# safe (the planner simulates the exact trajectory and only takes
# over when a plan is feasible); shrinking it to the new rise would
# be a behaviour change beyond the constant repoints, so it stays
# pending a Lead decision. See the Round 1 report, deferred sites.
func _plan_engaged(feet: Vector2, lethal: Array, solids: Array,
		dir: float, timed: Array = []) -> bool:
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	var a_lo: float = feet.x if dir > 0.0 else feet.x - PLAN_HORIZON
	var a_hi: float = feet.x + PLAN_HORIZON if dir > 0.0 else feet.x
	for shape in lethal:
		if shape.has("rect"):
			var r: Rect2 = shape["rect"]
			if r.position.x - hw <= a_hi \
					and r.position.x + r.size.x + hw >= a_lo \
					and r.position.y + r.size.y >= feet.y - 170.0 \
					and r.position.y <= feet.y + 200.0:
				return true
		else:
			var c: Vector2 = shape["centre"]
			var rad: float = shape["radius"]
			if c.x - rad - hw <= a_hi \
					and c.x + rad + hw >= a_lo \
					and c.y + rad >= feet.y - 170.0 \
					and c.y - rad <= feet.y + 200.0:
				return true
	for r in solids:
		var rr: Rect2 = r
		if rr.position.y < feet.y - 8.0 \
				and rr.position.y + rr.size.y > feet.y - ph \
				and rr.position.x - hw <= a_hi \
				and rr.position.x + rr.size.x + hw >= a_lo:
			return true
	var seen_gap: bool = false
	var x: float = feet.x + dir * 12.0
	var end_x: float = feet.x + dir * (PLAN_HORIZON + 120.0)
	while (dir > 0.0 and x <= end_x) or (dir < 0.0 and x >= end_x):
		var g: bool = false
		for r in solids:
			var rr2: Rect2 = r
			if absf(rr2.position.y - feet.y) <= 3.0 \
					and x >= rr2.position.x \
					and x <= rr2.position.x + rr2.size.x:
				g = true
				break
		if not g:
			for tp in timed:
				var tr: Dictionary = _timed_rect_at(tp, _elapsed)
				if not bool(tr["solid"]):
					continue
				var trr: Rect2 = tr["rect"]
				if absf(trr.position.y - feet.y) <= 3.0 \
						and x >= trr.position.x \
						and x <= trr.position.x + trr.size.x:
					g = true
					break
		if not g:
			seen_gap = true
		elif seen_gap:
			return true
		x += dir * 12.0
	return false


func _plan_required_runup(land_x: float, land_y: float, lethal: Array,
		solids: Array, traj: Dictionary, cache: Dictionary,
		dir: float, door_x: float, t_land: float = -1.0,
		timed: Array = [], flight_solids: Array = []) -> float:
	# Ground distance a stance needs before the next hard obstacle.
	# Returns 0 when nothing hard lies ahead, and 1e9 when the
	# obstacle cannot be cleared from this ground level.
	var entry: float = _plan_next_entry(land_x, land_y, lethal, solids,
			dir, door_x)
	if _plan_entry_none(entry, dir):
		return 0.0
	var hw: float = _plan_half_w()
	var ph: float = _plan_height()
	var step: float = float(_player_cfg["run_speed"]) * PLAN_DT
	# Strip run-up is WINDOW-based: at least one frame-aligned
	# takeoff (4.05px grid from the landing) must exist inside the
	# strip's applicable takeoff window -- the CHAIN window when
	# this strip is the first of a chained pair, else the single-
	# strip window. Round 4 dir<0 fix: the old code only searched
	# forward from land_x, so for dir < 0 it returned 1e9 whenever
	# land_x was past the window (i.e. always), killing every
	# leftward chained-strip plan (D29S1 0/3 in R3).
	for shape in lethal:
		if not shape.has("rect"):
			continue
		if str(shape.get("kind", "")) == "spiked_column":
			continue
		var r: Rect2 = shape["rect"]
		if absf(r.position.y + r.size.y - land_y) > 14.0:
			continue
		var e: float = r.position.x - hw if dir > 0.0 \
				else r.position.x + r.size.x + hw
		var at_entry: bool = (e > land_x - 28.0 and e <= entry + 12.0) \
				if dir > 0.0 \
				else (e < land_x + 28.0 and e >= entry - 12.0)
		if not at_entry:
			continue
		var win: Dictionary = _strip_applicable_window(lethal, r,
				land_y, dir, traj)
		if not bool(win.get("ok", false)):
			_last_blocked_by = str(win.get("blocked_by",
					"strip_no_window"))
			return 1e9
		var lo: float = float(win["lo"])
		var hi: float = float(win["hi"])
		var first: float = land_x
		if dir > 0.0:
			if lo > land_x:
				first = land_x + ceil((lo - land_x) / step) * step
			if first <= hi:
				return first - land_x
		else:
			if hi < land_x:
				first = land_x - ceil((land_x - hi) / step) * step
			if first >= lo:
				return land_x - first
		_last_blocked_by = "strip_no_lattice_point"
		return 1e9
	# Column run-up is COLUMN-WINDOW-based (Round 4): when the
	# next hard obstacle is a spiked column, the stance needs a
	# lattice takeoff inside the column window (landing-past +
	# takeoff-ground). The old rise-only path returned 0.0 when
	# h_req = 0 (column top level with the stance, e.g. P3 from
	# the step top), which is vacuous -- the planner then took the
	# earliest candidate takeoff and died on the column. Landing-
	# past governs instead; the greedy earliest-takeoff path is
	# suppressed here.
	for shape in lethal:
		if not shape.has("rect"):
			continue
		if str(shape.get("kind", "")) != "spiked_column":
			continue
		var c: Rect2 = shape["rect"]
		var ce: float = c.position.x - hw if dir > 0.0 \
				else c.position.x + c.size.x + hw
		var at_entry_c: bool = (ce > land_x - 28.0 \
						and ce <= entry + 12.0) if dir > 0.0 \
				else (ce < land_x + 28.0 and ce >= entry - 12.0)
		if not at_entry_c:
			continue
		var ground_c: Rect2 = _ground_rect_at(land_x, land_y, solids)
		if ground_c.size.x <= 0.0:
			_last_blocked_by = "column_no_ground"
			return 1e9
		var cwin: Dictionary = _column_window(c, land_y, dir,
				ground_c, traj)
		if not bool(cwin.get("ok", false)):
			_last_blocked_by = str(cwin.get("blocked_by",
					"column_no_window"))
			return 1e9
		var clo: float = float(cwin["lo"])
		var chi: float = float(cwin["hi"])
		var cfirst: float = land_x
		if dir > 0.0:
			if clo > land_x:
				cfirst = land_x + ceil((clo - land_x) / step) * step
			if cfirst <= chi:
				return cfirst - land_x
		else:
			if chi < land_x:
				cfirst = land_x - ceil((land_x - chi) / step) * step
			if cfirst >= clo:
				return land_x - cfirst
		_last_blocked_by = "column_no_lattice_point"
		return 1e9
	# P5 saw branch: the rise-based need below is WRONG for a
	# disc. It models the saw as a flat wall of height
	# land_y - (c.y - rad) at the margined entry plane and
	# demands ~28 px of runup before that plane -- but a jump
	# over a disc can take off 8 px before the disc (D03S1V2:
	# stance 406, crossing takeoff 414, entry dist 22.5 <
	# rise-need 28.35, so every followup was rejected although
	# the game clears it). For a saw, the need is the distance
	# to the first lattice takeoff whose simulated flight
	# actually CROSSES the disc (lands with its rect past the
	# disc's far side). Static saws only: a moving saw never
	# reaches this branch (the planner is disabled inside its
	# horizon, and _plan_geometry excludes moving saws).
	for shape in lethal:
		if shape.has("rect"):
			continue
		var c: Vector2 = shape["centre"]
		var rad: float = shape["radius"]
		var es: float = c.x - rad - hw if dir > 0.0 \
				else c.x + rad + hw
		var at_entry_s: bool = (es > land_x - 28.0 \
						and es <= entry + 12.0) if dir > 0.0 \
				else (es < land_x + 28.0 and es >= entry - 12.0)
		if not at_entry_s:
			continue
		if c.y + rad <= land_y - ph or c.y - rad >= land_y:
			continue
		if dir > 0.0 and es > door_x - 18.0:
			continue
		if dir < 0.0 and es < door_x + 18.0:
			continue
		var step_s: float = float(_player_cfg["run_speed"]) * PLAN_DT
		var cands_s: Array = _plan_candidates(land_x, land_y,
				dir * float(_player_cfg["run_speed"]), dir, lethal,
				solids, timed, t_land)
		for cand_s in cands_s:
			var tk: float = float(cand_s["x"])
			var k_s: int = int(round(absf(tk - land_x) / step_s))
			var tt_s: float = t_land
			if t_land >= 0.0:
				tt_s = t_land + float(k_s) * PLAN_DT
			else:
				tt_s = _elapsed + float(k_s) * PLAN_DT
			var hz_s: Dictionary = _plan_dx(float(cand_s["vx"]),
					dir, cache)
			var fl_s: Dictionary = _plan_flight(tk, land_y, traj,
					hz_s, lethal, solids, tt_s, timed, flight_solids)
			if not bool(fl_s.get("ok", false)):
				continue
			var past: bool = (float(fl_s["land_x"]) \
							> c.x + rad + hw) if dir > 0.0 \
					else (float(fl_s["land_x"]) < c.x - rad - hw)
			if past:
				return absf(tk - land_x)
		_last_blocked_by = "saw_no_crossing_takeoff"
		return 1e9
	# Rise-based need, ONLY for solid step-ups (and saws/columns):
	# the distance travelled while rising above the obstacle's top.
	var h_req: float = 0.0
	for shape in lethal:
		if shape.has("rect"):
			var r: Rect2 = shape["rect"]
			var e: float = r.position.x - hw if dir > 0.0 \
				else r.position.x + r.size.x + hw
			var at_entry2: bool = (e > land_x - 28.0 and e <= entry + 12.0) \
				if dir > 0.0 \
				else (e < land_x + 28.0 and e >= entry - 12.0)
			if at_entry2 and r.position.y + r.size.y > land_y - ph \
					and r.position.y < land_y:
				if land_y - r.position.y > 57.0 \
						and r.position.y + r.size.y <= land_y - 39.0:
					continue
				if dir > 0.0 and e > door_x - 18.0:
					continue
				if dir < 0.0 and e < door_x + 18.0:
					continue
				h_req = maxf(h_req, land_y - r.position.y)
		else:
			var c: Vector2 = shape["centre"]
			var rad: float = shape["radius"]
			var e2: float = c.x - rad - hw if dir > 0.0 \
				else c.x + rad + hw
			var at_entry3: bool = (e2 > land_x - 28.0 and e2 <= entry + 12.0) \
				if dir > 0.0 \
				else (e2 < land_x + 28.0 and e2 >= entry - 12.0)
			if at_entry3 and c.y + rad > land_y - ph and c.y - rad < land_y:
				if land_y - (c.y - rad) > 57.0 \
						and c.y + rad <= land_y - 39.0:
					continue
				if dir > 0.0 and e2 > door_x - 18.0:
					continue
				if dir < 0.0 and e2 < door_x + 18.0:
					continue
				h_req = maxf(h_req, land_y - (c.y - rad))
	for r in solids:
		var rr: Rect2 = r
		var e3: float = rr.position.x - hw if dir > 0.0 \
				else rr.position.x + rr.size.x + hw
		var at_entry4: bool = (e3 > land_x - 28.0 and e3 <= entry + 12.0) \
				if dir > 0.0 \
				else (e3 < land_x + 28.0 and e3 >= entry - 12.0)
		if at_entry4 and rr.position.y < land_y - 8.0 \
				and rr.position.y + rr.size.y > land_y - ph:
			if land_y - rr.position.y > 57.0 \
					and rr.position.y + rr.size.y <= land_y - 39.0:
				continue
			if dir > 0.0 and e3 > door_x - 18.0:
				continue
			if dir < 0.0 and e3 < door_x + 18.0:
				continue
			h_req = maxf(h_req, land_y - rr.position.y)
	if h_req <= 0.0:
		return 0.0
	# P5 mount window (replaces the old rise+margin formula):
	# the old need = dx to reach rise h_req + 4 px (28.35 px
	# for a 40 px step) conflated the flight's rise distance
	# with the ground runup, and the 4 px margin rejected
	# mounts the exact flight sim clears (D03S2V1: stance
	# 771.3, step face entry 792.5, 21.2 px available -- the
	# flight from 771.3 clears the face, the sim proves it,
	# the proxy said no). The exact condition is a takeoff
	# WINDOW: _rise_span(h_req) gives the takeoff-relative
	# offsets where the trajectory is above the step top, so
	# takeoffs in [entry - x_hi, entry - x_lo] (dir > 0) clear
	# the face; the stance needs only the distance to the
	# first lattice takeoff inside that window (0 when the
	# landing itself is in-window). The frame-exact flight
	# sim in _plan_followup_ok remains the arbiter for the
	# actual clearance; this proxy only asks whether a
	# lattice takeoff exists in the window.
	var span2: Dictionary = _rise_span(h_req, traj)
	if not bool(span2.get("ok", false)):
		_last_blocked_by = "mount_no_rise"
		return 1e9
	var step2: float = float(_player_cfg["run_speed"]) * PLAN_DT
	var wlo: float
	var whi: float
	if dir > 0.0:
		wlo = entry - float(span2["x_hi"])
		whi = entry - float(span2["x_lo"])
	else:
		wlo = entry + float(span2["x_lo"])
		whi = entry + float(span2["x_hi"])
	var first2: float
	if dir > 0.0:
		first2 = land_x + maxf(0.0,
				ceil((wlo - land_x) / step2) * step2)
		if first2 <= whi:
			return first2 - land_x
	else:
		first2 = land_x - maxf(0.0,
				ceil((land_x - whi) / step2) * step2)
		if first2 >= wlo:
			return land_x - first2
	_last_blocked_by = "mount_no_lattice_point"
	return 1e9


func _plan_followup_ok(land_x: float, land_y: float, land_vx: float,
		dir: float, traj: Dictionary, cache: Dictionary, lethal: Array,
		solids: Array, door_x: float, t_land: float = -1.0,
		timed: Array = [], flight_solids: Array = []) -> bool:
	# P5: a stance with no hard entry ahead AND continuous ground
	# to the door needs no followup jump (D08S2V1: the saw jump
	# lands at 1147 past the last saw, door at 1190 on the same
	# platform; every full jump from there flies into the right
	# wall at 1232, so the old code rejected the saw jump that
	# lands there -- the hero just runs to the door). A gap ahead
	# still needs a jump, so require the stance's ground solid to
	# reach the door.
	var entry_here: float = _plan_next_entry(land_x, land_y, lethal,
			solids, dir, door_x)
	if _plan_entry_none(entry_here, dir):
		var hw0: float = _plan_half_w()
		for r in solids:
			var rr: Rect2 = r
			if absf(rr.position.y - land_y) <= 3.0 \
					and land_x >= rr.position.x - hw0 \
					and land_x <= rr.position.x + rr.size.x + hw0:
				var far: float = rr.position.x + rr.size.x \
						if dir > 0.0 else rr.position.x
				if (dir > 0.0 and far >= door_x - 18.0) \
						or (dir < 0.0 and far <= door_x + 18.0):
					return true
	var cands: Array = _plan_candidates(land_x, land_y, land_vx, dir,
			lethal, solids, timed, t_land)
	var step: float = float(_player_cfg["run_speed"]) * PLAN_DT
	for cand in cands:
		var t_takeoff: float = t_land
		if t_land >= 0.0:
			# Frame count from the landing to the takeoff (always
			# non-negative; the old signed form time-travelled for
			# dir < 0, desyncing timed followup flights).
			var k: int = int(round(absf(float(cand["x"]) - land_x)
					/ step))
			t_takeoff = t_land + float(k) * PLAN_DT
		var horiz: Dictionary = _plan_dx(float(cand["vx"]), dir, cache)
		var fl: Dictionary = _plan_flight(float(cand["x"]), land_y, traj,
				horiz, lethal, solids, t_takeoff, timed, flight_solids)
		if not bool(fl.get("ok", false)):
			continue
		var entry: float = _plan_next_entry(float(fl["land_x"]),
				float(fl["land_y"]), lethal, solids, dir, door_x)
		if _plan_entry_none(entry, dir):
			return true
		var t_land2: float = -1.0
		if t_land >= 0.0:
			t_land2 = t_takeoff \
					+ float(fl.get("land_frame", 0)) * PLAN_DT
		var need: float = _plan_required_runup(float(fl["land_x"]),
				float(fl["land_y"]), lethal, solids, traj, cache, dir,
				door_x, t_land2, timed, flight_solids)
		if _plan_entry_dist(entry, float(fl["land_x"]), dir) >= need:
			return true
	return false


func _plan_pick(feasible: Array, dir: float, traj: Dictionary,
		cache: Dictionary, lethal: Array, solids: Array, door_x: float,
		t0: float = -1.0, timed: Array = [],
		flight_solids: Array = [], win: Dictionary = {}) -> Dictionary:
	# Round 4 pick rule (restores the R2 behaviour that R3 lost,
	# plus the chain centre-pick):
	#  * runup > 1e8 (landing past the last obstacle): pick the
	#    takeoff nearest the applicable window's CENTRE when a
	#    window is known, else the first -- never the earliest
	#    lattice point by default (a chain/column window edge is
	#    a knife-edge: one frame of slip kills).
	#  * otherwise sort runup DESC (R2), tie-broken by distance
	#    to the window centre, then takeoff ASC in `dir`; skip
	#    runup < 6.0 (R2 skip: a <6 px stance cannot host the
	#    next jump's lattice point); first candidate passing
	#    follow-up wins. No top-N cap (R3 kept that part).
	#  * the pick carries "marginal": true when its takeoff lies
	#    within one frame (4.05 px) of a window edge -- flagged
	#    marginal, never clean.
	if feasible.is_empty():
		return {"ok": false}
	var win_ok: bool = bool(win.get("ok", false))
	var win_centre: float = float(win.get("centre", 0.0))
	var mk_pick := func(f: Dictionary) -> Dictionary:
		var tk: float = float(f["takeoff"])
		var marg: bool = false
		if win_ok:
			marg = tk - float(win["lo"]) < PLAN_KNIFE_EDGE \
					or float(win["hi"]) - tk < PLAN_KNIFE_EDGE
		return {"ok": true, "takeoff": tk,
				"brake_x": float(f.get("brake_x", -1.0)),
				"t_dep": float(f.get("t_dep", -1.0)),
				"timed_kind": str(f.get("timed_kind", "")),
				"board": bool(f.get("board", false)),
				"marginal": marg}
	var past_last: Array = []
	for f in feasible:
		if float(f["runup"]) > 1e8:
			past_last.append(f)
	if not past_last.is_empty():
		# P5: the past-last branch used to return the first (or
		# centre-nearest) candidate WITHOUT a followup check, on
		# the assumption that landing past the last obstacle is
		# always good. It is not: a landing can be past the last
		# COUNTED entry yet still dead -- D11S5V1's lip landing
		# at 936.7 on the 560 platform has no counted entry
		# ahead (the strip 40 px below is not an entry) but is
		# ungrounded (grounded range ends 927.5), so the hero
		# cannot take the next jump and falls onto the spikes.
		# Filter past-last candidates by followup, in the same
		# order (centre-nearest first when a window is known,
		# else first); if none passes, fall through to the main
		# loop, which applies the same check to every candidate.
		if win_ok:
			past_last.sort_custom(func(a: Dictionary,
					b: Dictionary) -> bool:
				return absf(float(a["takeoff"]) - win_centre) \
						< absf(float(b["takeoff"]) - win_centre))
		for f in past_last:
			if _plan_followup_ok(float(f["land_x"]),
					float(f["land_y"]), float(f["land_vx"]), dir,
					traj, cache, lethal, solids, door_x,
					float(f.get("t_land", -1.0)), timed, flight_solids):
				return mk_pick.call(f)
	var chain_active: bool = win_ok \
			and str(win.get("kind", "")) == "chain"
	feasible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if chain_active:
			# Chained jump: the window centre governs, not the
			# earliest takeoff (the earliest point is the window
			# edge; D28S3V1 died one lattice step before the
			# window opened for exactly this reason).
			var da: float = absf(float(a["takeoff"]) - win_centre)
			var db: float = absf(float(b["takeoff"]) - win_centre)
			if absf(da - db) > 0.01:
				return da < db
			return float(a["runup"]) > float(b["runup"])
		if absf(float(a["runup"]) - float(b["runup"])) > 6.0:
			return float(a["runup"]) > float(b["runup"])
		if win_ok:
			var da2: float = absf(float(a["takeoff"]) - win_centre)
			var db2: float = absf(float(b["takeoff"]) - win_centre)
			if absf(da2 - db2) > 0.01:
				return da2 < db2
		return float(a["takeoff"]) * dir < float(b["takeoff"]) * dir)
	for f in feasible:
		if float(f["runup"]) < 6.0:
			continue
		if _plan_followup_ok(float(f["land_x"]), float(f["land_y"]),
				float(f["land_vx"]), dir, traj, cache, lethal, solids,
				door_x, float(f.get("t_land", -1.0)), timed, flight_solids):
			return mk_pick.call(f)
	return {"ok": false}


# Timed departure plans (Round 3): a moving/dashed crossing is
# solved as an earliest feasible (departure point, t_dep) pair, not
# as a static jump. All phase math uses attempt time (_elapsed).
# Round 4: a mover plan ALSO carries its exit (t_exit, exit_x) --
# the strip jump and the mover departure are planned JOINTLY, and
# the ride exit is timed from the same solve instead of being left
# to a wait that never resolves (D15S2: the hero boarded fine and
# then rode forever because the exit search only accepted
# same-level solids while the destination sits 40 px higher).
func _timed_departure_for(p: Dictionary, feet: Vector2, dir: float,
		speed: float, level: Dictionary = {}) -> Dictionary:
	var r0 := Rect2(float(p["x"]), float(p["y"]), float(p["w"]),
			float(p["h"]))
	if str(p["kind"]) == "dashed":
		var period: float = float(p["period"])
		var on_time: float = float(p["on_time"])
		var phase: float = float(p.get("phase", 0.0))
		var dep_x: float = r0.position.x if dir > 0.0 \
				else r0.position.x + r0.size.x
		var travel: float = maxf(0.0, (dep_x - feet.x) * dir / speed)
		# Crossing duration: centre from near edge to far edge + hw,
		# plus a 0.1s margin.
		var dur: float = (r0.size.x + _plan_half_w()) / speed + 0.1
		for k in range(-2, 9):
			var istart: float = phase + float(k) * period
			var iend: float = istart + on_time
			var s: float = maxf(_elapsed + travel, istart)
			if s + dur <= iend:
				return {"ok": true, "takeoff": dep_x, "brake_x": -1.0,
						"t_dep": s, "timed_kind": "dashed",
						"board": true, "engaged": true,
						"t_exit": -1.0, "exit_x": -1.0}
		return {"ok": false}
	# Moving: board when the mover's near edge is at the gap edge
	# (within 8px). Mover phase is _elapsed-based (no phase offset).
	var period2: float = float(p["period"])
	var dx: float = float(p.get("dx", 0.0))
	if absf(dx) < 1.0:
		return {"ok": false}
	var dep2: float = r0.position.x - _plan_half_w() if dir > 0.0 \
			else r0.position.x + r0.size.x + _plan_half_w()
	var travel2: float = maxf(0.0, (dep2 - feet.x) * dir / speed)
	var f_hi: float = clampf(8.0 / absf(dx), 0.0, 1.0)
	var theta: float = acos(1.0 - 2.0 * f_hi)
	var t_a: float = theta * period2 / TAU
	var earliest: float = _elapsed + travel2
	for k in range(0, 4):
		var base: float = float(k) * period2
		for win in [[base, base + t_a],
				[base + period2 - t_a, base + period2]]:
			var ws: float = float(win[0])
			var we: float = float(win[1])
			if we < earliest:
				continue
			var s: float = maxf(earliest, ws)
			# Hero needs ~0.15s to step fully onto the mover.
			if s + 0.15 <= we:
				# Joint exit: first time after boarding when the
				# mover's exit edge is within jump range
				# (PLAN_AIR_DX) of a mountable destination solid
				# (top within PLAN_MAX_RISE above the mover, or
				# level with it). Sampled over two periods; -1
				# when no such time exists (the ride branch's
				# 2-period safety net then owns the exit).
				var t_exit: float = -1.0
				var exit_x: float = -1.0
				if not level.is_empty():
					var dest_near: float = 1e9 if dir > 0.0 else -1e9
					for q in level["platforms"]:
						if str(q["kind"]) != "solid":
							continue
						var qtop: float = float(q["y"])
						if qtop < feet.y - PLAN_MAX_RISE \
								or qtop > feet.y + 3.0:
							continue
						if dir > 0.0:
							if float(q["x"]) > float(p["x"]) \
									and float(q["x"]) < dest_near:
								dest_near = float(q["x"])
						else:
							var qfar: float = float(q["x"]) \
									+ float(q["w"])
							if qfar < float(p["x"]) \
									and qfar > dest_near:
								dest_near = qfar
					if absf(dest_near) < 1e8:
						var t_end: float = s + 2.0 * period2
						var tt: float = s + 0.15
						while tt <= t_end:
							var mr: Rect2 = _mover_rect_at(p, tt)
							var edge: float = mr.position.x \
									+ mr.size.x if dir > 0.0 \
									else mr.position.x
							var gap: float = (dest_near - edge) \
									* dir
							if gap <= PLAN_AIR_DX:
								t_exit = tt
								exit_x = edge - dir \
										* (_plan_half_w() + 1.0)
								break
							tt += PLAN_DT
				return {"ok": true, "takeoff": dep2, "brake_x": -1.0,
						"t_dep": s, "timed_kind": "mover",
						"board": true, "engaged": true,
						"t_exit": t_exit, "exit_x": exit_x}
	return {"ok": false}


func _timed_departure_plan(level: Dictionary, feet: Vector2,
		dir: float, timed: Array) -> Dictionary:
	# Earliest feasible (departure point, t_dep) for the nearest
	# moving/dashed platform the hero must cross at this level.
	# Returns {"ok": false} when no timed platform is the immediate
	# crossing (static planning proceeds).
	var speed: float = float(_player_cfg["run_speed"])
	var ordered: Array = timed.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ea: float = (float(a["x"]) - feet.x) * dir
		var eb: float = (float(b["x"]) - feet.x) * dir
		return ea < eb)
	for p in ordered:
		var r0 := Rect2(float(p["x"]), float(p["y"]), float(p["w"]),
				float(p["h"]))
		if absf(r0.position.y - feet.y) > 3.0:
			continue
		var near_edge: float = r0.position.x if dir > 0.0 \
				else r0.position.x + r0.size.x
		var dist: float = (near_edge - feet.x) * dir
		if dist < -20.0 or dist > 200.0:
			continue
		# Already standing on it: riding, not departing.
		var cur: Dictionary = _timed_rect_at(p, _elapsed)
		if bool(cur["solid"]):
			var cr: Rect2 = cur["rect"]
			if absf(cr.position.y - feet.y) <= 3.0 \
					and feet.x >= cr.position.x \
					and feet.x <= cr.position.x + cr.size.x:
				continue
		var plan: Dictionary = _timed_departure_for(p, feet, dir, speed,
				level)
		if bool(plan.get("ok", false)):
			return plan
	return {"ok": false}


func _plan_ground_at(x: float, y: float, solids: Array,
		timed: Array, t: float) -> Rect2:
	# Solid/timed rect the point (x, y) stands on (top within 3px),
	# or an empty rect when standing on nothing.
	for r in solids:
		var rr: Rect2 = r
		if x >= rr.position.x and x <= rr.position.x + rr.size.x \
				and absf(rr.position.y - y) <= 3.0:
			return rr
	for p in timed:
		var cur: Dictionary = _timed_rect_at(p, t)
		if bool(cur.get("solid", false)):
			var cr: Rect2 = cur["rect"]
			if x >= cr.position.x and x <= cr.position.x + cr.size.x \
					and absf(cr.position.y - y) <= 3.0:
				return cr
	return Rect2()


func _plan_flight_useful(land_x: float, land_y: float, feet: Vector2,
		entry0: float, lethal: Array, solids: Array, timed: Array,
		dir: float, door_x: float, t0: float, t_land: float) -> bool:
	# A candidate jump is useful only if it makes progress past the
	# immediate obstacle. Without this, _plan_pick (earliest feasible)
	# picks no-op jumps that land before the obstacle (takeoff 70 and
	# 163 on D15S1V1, both landing on the same ground with the strip
	# still ahead), wasting the approach and chaining into the timed
	# shadow bug below. Useful when any of:
	#  (1) it lands on a different level (mount / drop);
	#  (2) the next entry ahead changed (cleared a lethal / wall);
	#  (3) it crossed a gap (landing ground starts past the takeoff
	#      ground's far edge).
	if absf(land_y - feet.y) > 1.0:
		return true
	var entry_after: float = _plan_next_entry(land_x, land_y, lethal,
			solids, dir, door_x)
	if entry_after != entry0:
		return true
	var g0: Rect2 = _plan_ground_at(feet.x, feet.y, solids, timed, t0)
	var g1: Rect2 = _plan_ground_at(land_x, land_y, solids, timed, t_land)
	if g0.size.x > 0.0 and g1.size.x > 0.0 and g0 != g1:
		if dir > 0.0 \
				and g1.position.x > g0.position.x + g0.size.x + 0.5:
			return true
		if dir < 0.0 \
				and g1.position.x + g1.size.x < g0.position.x - 0.5:
			return true
	return false


func _strip_below_engageable(base: float, feet: Vector2, dir: float,
		solids: Array) -> bool:
	# A strip on a ground line BELOW the hero is the governing
	# obstacle only when its line is the IMMEDIATE next line
	# below and it starts ahead within the drop horizon (120 px):
	# the hero is about to drop onto that line and jump the strip
	# from there (D19S2V1: strip at 784 on the 640-step, 40 px
	# below the 600-step, line starting 83 px ahead). A strip two
	# lines down (D19S5V2: 560-step under the 480-step with the
	# 520-step between) or far ahead (D15S4V1: 640-step 390 px
	# ahead of the spawn) is not yet the obstacle -- engaging it
	# early plans a premature jump from the wrong line (the broad
	# 14 px -> 200 px widening broke D15S4V1 and D19S5V2/V3).
	if base <= feet.y + 14.0:
		return false
	var drop_found: bool = false
	for r in solids:
		var rr: Rect2 = r
		if absf(rr.position.y - base) > 3.0:
			continue
		var st: float = rr.position.x if dir > 0.0 \
				else rr.position.x + rr.size.x
		var d: float = (st - feet.x) * dir
		if d >= 0.0 and d <= 120.0:
			drop_found = true
			break
	if not drop_found:
		return false
	# No intermediate line between the hero and the strip's line
	# may start ahead within the horizon.
	for r in solids:
		var rr: Rect2 = r
		var top: float = rr.position.y
		if top <= feet.y + 14.0 or top >= base - 3.0:
			continue
		var st2: float = rr.position.x if dir > 0.0 \
				else rr.position.x + rr.size.x
		var d2: float = (st2 - feet.x) * dir
		if d2 >= 0.0 and d2 <= 120.0:
			return false
	return true


func _active_window(level: Dictionary, feet: Vector2, dir: float,
		lethal: Array, solids: Array, timed: Array, t0: float,
		traj: Dictionary) -> Dictionary:
	# The window governing the next jump (chain > strip > column,
	# by nearest entry): the chain window when the next obstacle
	# is the first of a chained strip pair, else the single-strip
	# window, else the column window. Drives _plan_pick's
	# centre-pick / marginal flag and surfaces blocked_by when no
	# takeoff exists.
	var hw: float = _plan_half_w()
	var strip_r := Rect2()
	var strip_entry: float = 1e9 if dir > 0.0 else -1e9
	var strip_found: bool = false
	var col_r := Rect2()
	var col_entry: float = 1e9 if dir > 0.0 else -1e9
	var col_found: bool = false
	for shape in lethal:
		if not shape.has("rect"):
			continue
		var r: Rect2 = shape["rect"]
		if str(shape.get("kind", "")) == "spiked_column":
			var ce: float = r.position.x - hw if dir > 0.0 \
					else r.position.x + r.size.x + hw
			var cdist: float = (ce - feet.x) * dir
			if cdist < -28.0:
				continue
			if r.position.y + r.size.y <= feet.y - PLAN_MAX_RISE - 12.0 \
					or r.position.y > feet.y + 3.0:
				continue
			if (dir > 0.0 and ce < col_entry) \
					or (dir < 0.0 and ce > col_entry):
				col_entry = ce
				col_r = r
				col_found = true
			continue
		# Same-line strips (|base - feet.y| <= 14) always engage.
		# A strip on a line BELOW engages only when that line is
		# the immediate next line below (see
		# _strip_below_engageable); a strip on a line ABOVE is
		# not yet reachable.
		var sbase2: float = r.position.y + r.size.y
		if absf(sbase2 - feet.y) > 14.0 \
				and not _strip_below_engageable(sbase2, feet, dir,
						solids):
			continue
		var se: float = r.position.x - hw if dir > 0.0 \
				else r.position.x + r.size.x + hw
		var sdist: float = (se - feet.x) * dir
		if sdist < -28.0:
			continue
		if (dir > 0.0 and se < strip_entry) \
				or (dir < 0.0 and se > strip_entry):
			strip_entry = se
			strip_r = r
			strip_found = true
	var strip_first: bool = strip_found and (not col_found \
			or (dir > 0.0 and strip_entry <= col_entry) \
			or (dir < 0.0 and strip_entry >= col_entry))
	if strip_first:
		var w: Dictionary = _strip_applicable_window(lethal, strip_r,
				feet.y, dir, traj)
		return w
	if col_found:
		var ground: Rect2 = _plan_ground_at(feet.x, feet.y, solids,
				timed, t0)
		if ground.size.x <= 0.0:
			return {"lo": 0.0, "hi": -1.0, "ok": false, "centre": 0.0,
					"kind": "column", "blocked_by": "column_no_ground"}
		var cw: Dictionary = _column_window(col_r, feet.y, dir,
				ground, traj)
		cw["kind"] = "column"
		return cw
	return {"lo": 0.0, "hi": -1.0, "ok": false, "centre": 0.0,
			"kind": "none", "blocked_by": ""}


func _next_strip_ahead(level: Dictionary, feet: Vector2,
		dir: float) -> Dictionary:
	# Nearest up-spike strip ahead in `dir` on ANY ground line
	# within the planner's vertical engagement window (used by the
	# fallback gap suppression: the strip may sit a floor below
	# the hero's current lip, so _nearest_strip's same-line filter
	# must not hide it).
	var best_r := Rect2()
	var best_dist: float = 1e9
	var found: bool = false
	for shape in _lethal_shapes(level):
		if not shape.has("rect"):
			continue
		var r: Rect2 = shape["rect"]
		if r.position.y + r.size.y < feet.y - 170.0 \
				or r.position.y > feet.y + 200.0:
			continue
		var near: float = r.position.x if dir > 0.0 \
				else r.position.x + r.size.x
		var dist: float = (near - feet.x) * dir
		if dist < -20.0 or dist > 420.0:
			continue
		if dist < best_dist:
			best_dist = dist
			best_r = r
			found = true
	if not found:
		return {"ok": false}
	var win: Dictionary = _strip_window(best_r, dir,
			best_r.position.y + best_r.size.y)
	return {"ok": bool(win["ok"]), "rect": best_r,
			"lo": float(win["lo"]), "hi": float(win["hi"])}


func _drop_landing_exists(level: Dictionary, feet: Vector2,
		dir: float) -> bool:
	# True when solid ground continues IMMEDIATELY below ahead
	# (a step-down, not a pit): a solid whose top is 8-200 px
	# below the hero and whose span starts within 30 px ahead.
	# Dropping onto it is safe, so a gap jump must not fire.
	# The 30 px horizon matches the first ground probe (30 px):
	# the gap jump fires as soon as the edge is < 30 px ahead,
	# so a drop landing 12-30 px ahead was invisible to this
	# check and the hero jumped into the strip below instead
	# (D19S2V1-3 regression: the 640-step starts 26.2 px ahead
	# of the 600-step edge; the old planner dropped here).
	for p in level["platforms"]:
		if str(p["kind"]) != "solid":
			continue
		var top: float = float(p["y"])
		if top <= feet.y + 8.0 or top > feet.y + 200.0:
			continue
		var px: float = float(p["x"])
		var pw: float = float(p["w"])
		if dir > 0.0:
			if px <= feet.x + 30.0 and px + pw >= feet.x:
				return true
		else:
			if px + pw >= feet.x - 30.0 and px <= feet.x:
				return true
	return false


func _ride_jump_off(level: Dictionary, feet: Vector2, dir: float,
		ride: Dictionary) -> bool:
	# Exact-sim jump-off from a mover: jump only when a full
	# simulated flight from the hero's CURRENT position lands on
	# a solid past the mover's exit edge, at the same level or
	# mounted above it (D15S2: destination 40 px up, landing
	# 560-608.5, clear of the strip at 620). The flight sim is
	# the arbiter -- no rise/gap approximation. Drops off the
	# mover are never taken here (a blind drop is not an exit).
	if not bool(ride.get("riding", false)):
		return false
	var geo: Dictionary = _plan_geometry(level, feet, dir)
	if not bool(geo.get("ok", false)):
		return false
	var traj: Dictionary = _plan_trajectory()
	var cache: Dictionary = {}
	var horiz: Dictionary = _plan_dx(float(_player_cfg["run_speed"]),
			dir, cache)
	var fl: Dictionary = _plan_flight(feet.x, feet.y, traj, horiz,
			geo["lethal"], geo["solids"], _elapsed, geo["timed"],
			geo["flight_solids"])
	if not bool(fl.get("ok", false)):
		return false
	if float(fl["land_y"]) > feet.y + 3.0:
		return false
	var mr: Rect2 = ride.get("mover_rect", Rect2())
	var edge: float = mr.position.x + mr.size.x if dir > 0.0 \
			else mr.position.x
	if dir > 0.0 and float(fl["land_x"]) <= edge:
		return false
	if dir < 0.0 and float(fl["land_x"]) >= edge:
		return false
	return true


func _compute_plan(level: Dictionary, feet: Vector2,
		dir: float) -> Dictionary:
	var geo: Dictionary = _plan_geometry(level, feet, dir)
	if not bool(geo.get("ok", false)):
		return {"ok": false, "engaged": false}
	var lethal: Array = geo["lethal"]
	var solids: Array = geo["solids"]
	var timed: Array = geo["timed"]
	var flight_solids: Array = geo["flight_solids"]
	var door_x: float = float(level["door"]["x"])
	# Nearest plain entry ahead (lethal / wall / step face). Gaps
	# produce no entry here, so this is the obstacle a timed plan
	# must not shadow.
	var entry0: float = _plan_next_entry(feet.x, feet.y, lethal,
			solids, dir, door_x)
	# Timed departure first: a mover/dashed crossing is solved as
	# (takeoff, t_dep), not as a static jump -- but ONLY when it is
	# the immediate action. If a plain obstacle lies between the hero
	# and the timed takeoff (strip at 300 vs mover takeoff 432.5 on
	# D15S1V1; strip at 520 vs dashed takeoff ~612 on D12S1V1),
	# returning the timed plan makes _decide hold the plan and run
	# straight into the strip. Fall through to plain planning; the
	# timed plan is re-solved after the strip jump lands.
	var tp: Dictionary = _timed_departure_plan(level, feet, dir, timed)
	if bool(tp.get("ok", false)):
		var tp_takeoff: float = float(tp.get("takeoff", 0.0))
		var shadowed: bool = (dir > 0.0 and entry0 < tp_takeoff) \
				or (dir < 0.0 and entry0 > tp_takeoff)
		if not shadowed:
			return tp
	if not _plan_engaged(feet, lethal, solids, dir, timed):
		return {"ok": false, "engaged": false}
	var vx0: float = 0.0
	if _player != null and is_instance_valid(_player):
		vx0 = _player.velocity.x
	var traj: Dictionary = _plan_trajectory()
	var cache: Dictionary = {}
	var t0: float = _elapsed
	_last_blocked_by = ""
	var active_win: Dictionary = _active_window(level, feet, dir,
			lethal, solids, timed, t0, traj)
	if not bool(active_win.get("ok", false)) \
			and str(active_win.get("blocked_by", "")) != "":
		_last_blocked_by = str(active_win["blocked_by"])
	var cands: Array = _plan_candidates(feet.x, feet.y, vx0, dir, lethal,
			solids, timed, t0)
	var feasible: Array = []
	var fail_frames: Dictionary = {}
	for ci in range(cands.size()):
		var cand: Dictionary = cands[ci]
		var horiz: Dictionary = _plan_dx(float(cand["vx"]), dir, cache)
		var fl: Dictionary = _plan_flight(float(cand["x"]), feet.y, traj,
				horiz, lethal, solids, t0, timed, flight_solids)
		if not bool(fl.get("ok", false)):
			fail_frames[ci] = int(fl.get("fail_frame", 0))
			continue
		var entry: float = _plan_next_entry(float(fl["land_x"]),
				float(fl["land_y"]), lethal, solids, dir, door_x)
		if not _plan_flight_useful(float(fl["land_x"]),
				float(fl["land_y"]), feet, entry0, lethal, solids,
				timed, dir, door_x, t0,
				t0 + float(fl.get("land_frame", 0)) * PLAN_DT):
			continue
		feasible.append({"takeoff": float(cand["x"]),
				"land_x": float(fl["land_x"]),
				"land_y": float(fl["land_y"]),
				"land_vx": float(fl["land_vx"]),
				"runup": _plan_entry_dist(entry, float(fl["land_x"]), dir),
				"brake_x": -1.0,
				"t_land": t0 + float(fl.get("land_frame", 0)) * PLAN_DT})
	var picked: Dictionary = _plan_pick(feasible, dir, traj, cache,
			lethal, solids, door_x, t0, timed, flight_solids, active_win)
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
					traj, horiz2, lethal, solids, t0, timed, flight_solids)
			if not bool(fl2.get("ok", false)):
				continue
			var entry2: float = _plan_next_entry(float(fl2["land_x"]),
					float(fl2["land_y"]), lethal, solids, dir, door_x)
			if not _plan_flight_useful(float(fl2["land_x"]),
					float(fl2["land_y"]), feet, entry0, lethal, solids,
					timed, dir, door_x, t0,
					t0 + float(fl2.get("land_frame", 0)) * PLAN_DT):
				continue
			var dxs2: Array = horiz2["dx"]
			# Brake margin in the direction of travel (dxs2 is
			# signed; the old literal -3.0 pointed the wrong way
			# for dir < 0).
			var brake_x: float = float(cand2["x"]) + float(dxs2[bf - 1]) \
					- 3.0 * dir
			braked.append({"takeoff": float(cand2["x"]),
					"land_x": float(fl2["land_x"]),
					"land_y": float(fl2["land_y"]),
					"land_vx": float(fl2["land_vx"]),
					"runup": _plan_entry_dist(entry2, float(fl2["land_x"]), dir),
					"brake_x": brake_x,
					"t_land": t0 + float(fl2.get("land_frame", 0)) * PLAN_DT})
	var bp: Dictionary = _plan_pick(braked, dir, traj, cache, lethal,
			solids, door_x, t0, timed, flight_solids, active_win)
	if bool(bp.get("ok", false)):
		return bp
	if _last_blocked_by != "":
		return {"ok": false, "engaged": true,
				"blocked_by": _last_blocked_by}
	return {"ok": false, "engaged": true}


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
	# Timed-platform wait state at entry (waiting for a departure, or
	# riding a mover) must not count as blocked: velocity is ~0 in
	# both cases by design.
	var timed_waiting: bool = _plan_active and _plan_timed_kind != "" \
			and _elapsed < _plan_t_dep
	# Riding a mover: exit by stepping off when its edge reaches
	# the next solid, by a simulated jump-off onto a mountable or
	# same-level destination past the gap (D15S2: the destination
	# sits 40 px above the mover, so the old same-level-only exit
	# never fired in 7.1 periods), or by the 2-period safety net.
	# While riding with no exit yet, WALK on the mover toward the
	# exit edge: waiting still lets the mover slide out from under
	# the hero onto a static floor lip (x~327.3 on D15S2). Riding
	# decisions stay waiting=true so the no-progress counter does
	# not kill a healthy ride (mover progress is periodic).
	var ride: Dictionary = _mover_ride_state(level, feet, on_floor, dir)
	if bool(ride.get("riding", false)):
		if _ride_since < 0.0:
			_ride_since = _elapsed
			_ride_best = feet.x * dir
			_ride_best_t = _elapsed
		if feet.x * dir > _ride_best + 1.0:
			_ride_best = feet.x * dir
			_ride_best_t = _elapsed
		if bool(ride.get("step_off", false)):
			_ride_since = -1.0
			_plan_t_exit = -1.0
			return {"dir": dir, "jump": false, "waiting": false}
		if bool(ride.get("jump_off", false)):
			_ride_since = -1.0
			_plan_t_exit = -1.0
			return {"dir": dir, "jump": true, "waiting": false}
		if _ride_jump_off(level, feet, dir, ride):
			_ride_since = -1.0
			_plan_t_exit = -1.0
			return {"dir": dir, "jump": true, "waiting": false}
		# 2-period safety net: still riding after two full mover
		# periods without progress (or past the jointly planned
		# t_exit + 0.5 s): force one mount-off attempt, then
		# re-arm. Without it D15S2 rode to the 2700-step timeout.
		var rperiod: float = float(ride.get("period", 0.0))
		var deadline: float = -1.0
		if rperiod > 0.0:
			deadline = _ride_best_t + 2.0 * rperiod
		if _plan_t_exit > 0.0:
			var exit_deadline: float = _plan_t_exit + 0.5
			deadline = exit_deadline if deadline < 0.0 \
					else minf(deadline, exit_deadline)
		if deadline > 0.0 and _elapsed >= deadline:
			_ride_since = -1.0
			_plan_t_exit = -1.0
			return {"dir": dir, "jump": true, "waiting": false}
		var walk_to: float = float(ride.get("walk_to", feet.x))
		var wdir: float = 0.0
		if walk_to - feet.x > 2.0:
			wdir = 1.0
		elif feet.x - walk_to > 2.0:
			wdir = -1.0
		return {"dir": wdir, "jump": false, "waiting": true}
	_ride_since = -1.0
	# Probe rect ahead.
	var probe := Rect2(
			feet.x if facing > 0.0 else feet.x - LOOKAHEAD,
			feet.y - 48.0, LOOKAHEAD, 52.0)
	var hazard_ahead: bool = false
	var timed_ahead: bool = false
	for shape in _lethal_shapes(level):
		if _shape_hits_rect(shape, probe):
			hazard_ahead = true
			# P6: a fully-landed triggered pillar never rises again,
			# so waiting for it is pointless -- the 3 s wait + forced
			# blind jump is exactly how the hero died on it (D06S1:
			# waited at ~488, forced jump into the landed wall).
			# The planner owns its jump; other timed shapes wait.
			if bool(shape.get("timed", false)) \
					and not bool(shape.get("landed", false)):
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
		if top < feet.y - 8.0 and top >= feet.y - PLAN_MAX_RISE:
			var near_edge: float = r.position.x if facing > 0.0 \
					else r.position.x + r.size.x
			var dist_edge: float = (near_edge - feet.x) * facing
			if dist_edge >= -10.0 and dist_edge <= 70.0:
				mount = true
				break
	var gap_ahead: bool = on_floor and not ground_ahead and not mount
	# Blocked (wall) detection.
	if on_floor and dir != 0.0 and not timed_waiting \
			and _player != null \
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
	# Timed-platform departure: hold on safe ground until t_dep.
	if _plan_active and _plan_timed_kind != "" and _elapsed < _plan_t_dep \
			and on_floor and absf(feet.x - _plan_x) <= 12.0:
		var not_passed: bool = feet.x <= _plan_x + 0.1 if dir > 0.0 \
				else feet.x >= _plan_x - 0.1
		if not_passed:
			return {"dir": 0.0, "jump": false, "waiting": true}
	# Ballistic plan: when one holds, it owns the jump decision until
	# its takeoff point (the greedy trigger firing early is exactly
	# what mistimes chained jumps). A wall hit means the plan is stale.
	var planned_jump: bool = false
	var plan_holds: bool = false
	var wait_at_dep: bool = false
	if blocked:
		_plan_active = false
	elif on_floor and dir != 0.0:
		if _plan_active:
			if _plan_reached(feet, dir):
				if _plan_board:
					_plan_active = false
					_plan_board = false
				else:
					planned_jump = true
					_flight_brake_x = _plan_brake_x
					_flight_active = _plan_brake_x >= 0.0
					_plan_active = false
			elif _plan_overshot(feet, dir):
				_plan_active = false
			else:
				plan_holds = true
		if not _plan_active and not planned_jump \
				and _recheck_due(feet, dir):
			var plan: Dictionary = _compute_plan(level, feet, dir)
			if bool(plan.get("ok", false)):
				_plan_x = float(plan["takeoff"])
				_plan_brake_x = float(plan.get("brake_x", -1.0))
				_plan_t_dep = float(plan.get("t_dep", -1.0))
				_plan_timed_kind = str(plan.get("timed_kind", ""))
				_plan_board = bool(plan.get("board", false))
				_plan_t_exit = float(plan.get("t_exit", -1.0))
				_plan_marginal = _plan_marginal \
						or bool(plan.get("marginal", false))
				_plan_blocked_by = ""
				_plan_active = true
				if _plan_reached(feet, dir):
					if _plan_board and _plan_timed_kind != "" \
							and _elapsed < _plan_t_dep:
						# Fresh timed plan, already at the departure
						# point but t_dep not reached: wait here.
						wait_at_dep = true
					elif _plan_board:
						_plan_active = false
						_plan_board = false
					else:
						planned_jump = true
						_flight_brake_x = _plan_brake_x
						_flight_active = _plan_brake_x >= 0.0
						_plan_active = false
				else:
					plan_holds = true
			else:
				if str(plan.get("blocked_by", "")) != "":
					_plan_blocked_by = str(plan["blocked_by"])
				var recheck: float = 4.05 \
						if bool(plan.get("engaged", false)) \
						else PLAN_RECHECK_DIST
				_plan_next_check_x = feet.x + dir * recheck
	if wait_at_dep:
		return {"dir": 0.0, "jump": false, "waiting": true}
	var jump: bool = false
	if planned_jump:
		jump = true
	elif not plan_holds and on_floor:
		# Window-owned strip jump (Round 4): a strip jumps ONLY
		# when the current position lies INSIDE its applicable
		# takeoff window (the CHAIN window when chained, else the
		# single-strip window). The old `feet.x >= lo - 4.05`
		# fired one frame (one lattice step) early, assuming the
		# takeoff happens 4.05 px AFTER the decision -- but the
		# takeoff IS the decision position (D28S3V1: fired at
		# 495.0, window [498.66, 508.22]). Lattice membership is
		# the only test; there is no early fire in either
		# direction (mirrored for dir < 0).
		var strip: Dictionary = _nearest_strip(level, feet, dir)
		var strip_jump: bool = false
		var strip_hold: bool = false
		var strip_passed: bool = false
		if bool(strip.get("ok", false)):
			var win0: Dictionary = _strip_applicable_window(
					_lethal_shapes(level), strip["rect"] as Rect2,
					feet.y, dir)
			if bool(win0.get("ok", false)):
				var lo: float = float(win0["lo"])
				var hi: float = float(win0["hi"])
				if feet.x >= lo and feet.x <= hi:
					strip_jump = true
				elif (dir > 0.0 and feet.x < lo) \
						or (dir < 0.0 and feet.x > hi):
					strip_hold = true
				elif (dir > 0.0 and feet.x > hi) \
						or (dir < 0.0 and feet.x < lo):
					# Past the window's far end but not yet at
					# the strip: any jump now clips it (the
					# window is the set of takeoffs that clear).
					# The crude probe jump must not fire here
					# (D02S4V1: fired at 410.2, 2 px past the
					# window end, and died on the strip).
					strip_passed = true
		# A strip window ahead owns the jump decision even when
		# the strip sits a floor below the hero's current lip
		# (D02S4V1: the gap trigger fired jump 3 from a one-frame
		# edge-lip landing, 29 px before the window opened).
		# When the window has not opened yet and the hero can
		# drop onto solid ground below, DROP instead of jumping.
		var strip_ahead_unopened: bool = false
		if not strip_jump:
			var nx: Dictionary = _next_strip_ahead(level, feet, dir)
			if bool(nx.get("ok", false)):
				var nlo: float = float(nx["lo"])
				var nhi: float = float(nx["hi"])
				if feet.x < nlo or feet.x > nhi:
					if _drop_landing_exists(level, feet, dir):
						strip_ahead_unopened = true
		# A blocked column refuses the jump too (Round 4, task 2):
		# when the governing window is a column with no takeoff,
		# the crude probe jump would only die on the column -- the
		# planner refuses rather than jumping. Same _active_window
		# the planner uses, so the refusal is consistent.
		var column_blocked: bool = false
		var geo0: Dictionary = _plan_geometry(level, feet, dir)
		if bool(geo0.get("ok", false)):
			var aw0: Dictionary = _active_window(level, feet, dir,
					geo0["lethal"], geo0["solids"], geo0["timed"],
					_elapsed, _plan_trajectory())
			if str(aw0.get("kind", "")) == "column" \
					and not bool(aw0.get("ok", false)) \
					and str(aw0.get("blocked_by", "")) != "":
				column_blocked = true
		if strip_hold and not gap_ahead and not mount and not blocked:
			jump = false
		elif (hazard_ahead and not strip_passed \
				and not column_blocked) \
				or mount or blocked or strip_jump:
			jump = true
		elif gap_ahead:
			# Drop, don't jump: when solid ground continues
			# immediately below ahead (a step-down, D17S2V2's
			# 480->520 drop under the 800 ceiling strip), running
			# off the edge and falling is the play -- jumping
			# rises into the ceiling strip. A real pit (no drop
			# landing) still jumps.
			if strip_ahead_unopened \
					or _drop_landing_exists(level, feet, dir):
				jump = false
			else:
				jump = true
	if blocked:
		_blocked_frames = 0
	# In-flight braking for a planned shortened jump: release the stick
	# once past the brake point so the flight lands earlier in the gap.
	# Round 4 dir<0 fix: the old `feet.x >= brake_x` test is true
	# from the jump frame when moving left (feet.x only decreases),
	# so every braked leftward flight stopped instantly.
	if not on_floor and _flight_active and _flight_brake_x >= 0.0 \
			and ((_last_dir > 0.0 and feet.x >= _flight_brake_x) \
			or (_last_dir < 0.0 and feet.x <= _flight_brake_x)):
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
	_plan_t_dep = -1.0
	_plan_timed_kind = ""
	_plan_board = false
	_plan_t_exit = -1.0
	_plan_blocked_by = ""
	_plan_marginal = false
	_last_blocked_by = ""
	_ride_since = -1.0
	_ride_best = -1e9
	_ride_best_t = -1.0


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
			return {"outcome": "died", "steps": steps,
					"marginal": _plan_marginal,
					"blocked_by": _plan_blocked_by}
		if _check_won(level):
			return {"outcome": "door", "steps": steps,
					"marginal": _plan_marginal,
					"blocked_by": _plan_blocked_by}
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
					return {"outcome": "no-progress", "steps": steps,
							"marginal": _plan_marginal,
							"blocked_by": _plan_blocked_by}
		_set_drive(float(decision["dir"]), bool(decision["jump"]))
	return {"outcome": "timeout", "steps": steps,
			"marginal": _plan_marginal,
			"blocked_by": _plan_blocked_by}


func _validate_level_contract(level: Dictionary) -> String:
	# Unknown kind/type = hard error (LEVEL_SCHEMA.md). The runtime
	# must fail fast on these, so the autopilot must never silently
	# play such a level as if it were valid (that would risk a false
	# positive the game itself would refuse to load).
	var kinds: Dictionary = {"solid": true, "dashed": true,
			"falling": true, "tilting": true, "moving": true}
	# NOTE (Round 3, item 12): dotted_line is NOT in this map on
	# purpose -- the runtime hard-errors on it (schema v3), so the
	# autopilot must reject such a level as unknown_type instead of
	# silently playing it.
	var types: Dictionary = {"spikes": true, "saw": true,
			"spiked_column": true, "hanging_pillar": true}
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
					"notes": notes, "attempts": attempts,
					"marginal": bool(attempt.get("marginal", false)),
					"blocked_by": str(attempt.get("blocked_by", ""))}
		if str(attempt["outcome"]) == "died":
			deaths += 1
	var last: Dictionary = attempts[attempts.size() - 1] if not attempts.is_empty() else {}
	return {"id": lid, "pass": false, "mode": used_mode,
			"strategy": -1, "steps": int(last.get("steps", 0)),
			"deaths": deaths,
			"reason": str(last.get("outcome", "failed")),
			"notes": notes, "attempts": attempts,
			"marginal": bool(last.get("marginal", false)),
			"blocked_by": str(last.get("blocked_by", ""))}


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
	# Floor/door come from the schema constants above, NOT from the
	# DEPRECATED tuning.json `control_bar` / `door` entries.


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
	if int((data as Dictionary).get("schema_version", -1)) != 3:
		_die("schema_version %s != frozen 3 in %s" % [
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
