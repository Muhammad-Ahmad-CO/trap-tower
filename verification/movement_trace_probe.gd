# Movement trace probe (Round 1, Lane R). Loads a flat-ground schema-v3
# fixture level through the REAL loader + builder, drives scripted
# inputs (run right at constant speed, jumps at fixed x points), and
# dumps a 60fps feet-position trace as JSON. Round 2 compares this
# trace against hero-track.json; this script only produces the trace.
#
# Run:
#   <godot> --headless --fixed-fps 60 --path <repo>/godot \
#       -s <repo>/verification/movement_trace_probe.gd -- \
#       --fixture /tmp/tt_trace_fixture.json \
#       --out ~/workspace/trap-tower/verification/movement-trace-r1.json
# Defaults: --fixture /tmp/tt_trace_fixture.json, --out
#   $HOME/workspace/trap-tower/verification/movement-trace-r1.json.
# Exits 0 on success, 2 on fixture/load failure.
extends SceneTree

const JUMP_POINTS := [300.0, 600.0, 900.0]
const STOP_X := 1150.0
const MAX_FRAMES := 600


func _initialize() -> void:
	call_deferred("_run")


func _parse_args() -> Dictionary:
	var out := {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i := 0
	while i < raw.size():
		if raw[i] in ["--fixture", "--out"] and i + 1 < raw.size():
			out[raw[i].trim_prefix("--")] = raw[i + 1]
			i += 2
		else:
			i += 1
	return out


func _run() -> void:
	var args := _parse_args()
	var fixture_path: String = str(args.get("fixture", "/tmp/tt_trace_fixture.json"))
	var out_path: String = str(args.get("out", OS.get_environment("HOME") + "/workspace/trap-tower/verification/movement-trace-r1.json"))
	if not FileAccess.file_exists(fixture_path):
		print("TRACE ERROR: fixture missing: " + fixture_path)
		quit(2)
		return
	var tuning_script: GDScript = load("res://scripts/tuning.gd")
	var tuning: Dictionary = tuning_script.load_tuning()
	if tuning.is_empty():
		print("TRACE ERROR: tuning.json missing or invalid")
		quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(fixture_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		print("TRACE ERROR: fixture is not a JSON object")
		quit(2)
		return
	var data_script: GDScript = load("res://scripts/level_data.gd")
	var err: String = data_script.validate_file(parsed, tuning)
	if err != "":
		print("TRACE ERROR: fixture rejected: " + err)
		quit(2)
		return
	var level: Dictionary = (parsed["levels"] as Array)[0]
	var warnings: Array = data_script.validate_visual_rules(level, tuning)
	print("TRACE fixture OK: warnings=%d" % warnings.size())
	var builder_script: GDScript = load("res://scripts/level_builder.gd")
	var builder: RefCounted = builder_script.new()
	var rt: Node = builder.call("build_level", level, tuning)
	root.add_child(rt)
	var player: CharacterBody2D = builder.get("player")
	player.set("input_override", 1)
	# Settle one frame so the player is on the floor before sampling.
	await physics_frame
	await physics_frame
	var samples: Array = []
	var jumped: Dictionary = {}
	var frame := 0
	while frame < MAX_FRAMES:
		await physics_frame
		frame += 1
		var feet: Vector2 = player.call("feet_pos")
		var on_floor: bool = player.is_on_floor()
		for jp in JUMP_POINTS:
			if not jumped.has(jp) and feet.x >= jp and on_floor:
				player.set("jump_override_edge", true)
				jumped[jp] = true
		samples.append({
			"t": snappedf(frame / 60.0, 0.001),
			"x": snappedf(feet.x, 0.01),
			"y": snappedf(feet.y, 0.01),
			"vx": snappedf(player.velocity.x, 0.01),
			"vy": snappedf(player.velocity.y, 0.01),
			"on_floor": on_floor,
		})
		if feet.x >= STOP_X:
			break
		if bool(rt.get("dead")) or bool(rt.get("level_completed")):
			print("TRACE NOTE: stopped early (dead/completed) at frame %d" % frame)
			break
	var report := {
		"tool": "trap-tower movement trace probe (Round 1)",
		"fixture": fixture_path,
		"fps": 60,
		"jump_points": JUMP_POINTS,
		"stop_x": STOP_X,
		"samples": samples.size(),
		"trace": samples,
	}
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		print("TRACE ERROR: cannot write " + out_path)
		quit(2)
		return
	f.store_string(JSON.stringify(report))
	f.close()
	print("TRACE DONE samples=%d out=%s" % [samples.size(), out_path])
	quit(0)
