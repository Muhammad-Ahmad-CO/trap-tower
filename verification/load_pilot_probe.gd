# Pilot load probe (Round 2, Lane V). Loads the pilot candidates file
# through the REAL runtime loader + builder (TTLevelData.load_levels +
# TTBuilder.build_level) and records per-level load errors and
# visual-rule warnings (rules 7-8 warn-and-load). This is the
# checker-pass / runtime-warning drift cross-check: every checker-PASS
# level must load with ZERO warnings.
#
# Also asserts the door rect on the real TTDoor node: a synthetic door
# at (1210, 680) must report Rect2(1192, 626, 36, 54), and every built
# level's door node must report (door.x - 18, door.y - 54, 36, 54).
#
# Run:
#   <godot> --headless --fixed-fps 60 --path <repo>/godot \
#       -s <repo>/verification/load_pilot_probe.gd -- \
#       --levels <candidates.json> --out <report.json>
# Exit 0 iff 0 load errors AND 0 warnings AND all door rects exact.
extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _parse_args() -> Dictionary:
	var out := {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i := 0
	while i < raw.size():
		if raw[i] in ["--levels", "--out"] and i + 1 < raw.size():
			out[raw[i].trim_prefix("--")] = raw[i + 1]
			i += 2
		else:
			i += 1
	return out


func _run() -> void:
	var args := _parse_args()
	var levels_path: String = str(args.get("levels", ""))
	var out_path: String = str(args.get("out", ""))
	if levels_path == "" or out_path == "":
		print("LOAD PILOT ERROR: --levels and --out required")
		quit(2)
		return
	var tuning: Dictionary = TTuning.load_tuning()
	if tuning.is_empty():
		print("LOAD PILOT ERROR: tuning.json missing or invalid")
		quit(1)
		return
	var loaded: Dictionary = TTLevelData.load_levels(levels_path)
	var load_err := str(loaded.get("error", ""))
	print("LOAD PILOT: load_levels error='%s'" % load_err)
	var levels: Array = loaded.get("levels", [])
	print("LOAD PILOT: levels=%d" % levels.size())
	var load_warnings: Array = loaded.get("warnings", [])
	print("LOAD PILOT: load_levels warnings=%d" % load_warnings.size())
	for w in load_warnings:
		print("LOAD PILOT WARNING: " + str(w))
	# Per-level visual-rule warnings (attributed) + build check.
	var per_level: Array = []
	var built_ok := 0
	var build_fail: Array = []
	var door_bad: Array = []
	for lv in levels:
		var lid := str(lv.get("id", "?"))
		var warns: Array = TTLevelData.validate_visual_rules(lv, tuning)
		var entry := {"id": lid, "warnings": warns, "built": false,
			"door_rect": []}
		var builder := TTBuilder.new()
		var node: Variant = builder.build_level(lv, tuning)
		if node is Node:
			root.add_child(node)
			var player: Node = builder.player
			var door_node: Node = builder.door
			if player != null and player is CharacterBody2D \
					and not (builder.platforms as Array).is_empty() \
					and door_node != null:
				entry["built"] = true
				built_ok += 1
				var dr: Rect2 = door_node.call("door_rect")
				entry["door_rect"] = [dr.position.x, dr.position.y,
					dr.size.x, dr.size.y]
				var exp := Rect2(float(lv["door"]["x"]) - 18.0,
					float(lv["door"]["y"]) - 54.0, 36.0, 54.0)
				if dr != exp:
					door_bad.append({"id": lid, "got": entry["door_rect"],
						"expected": [exp.position.x, exp.position.y,
							exp.size.x, exp.size.y]})
			else:
				build_fail.append(lid + ": missing player/platforms/door")
			await physics_frame
			root.remove_child(node)
			node.queue_free()
			await physics_frame
		else:
			build_fail.append(lid + ": build_level returned non-node")
		per_level.append(entry)
	# Synthetic door-rect check: door at (1210, 680) -> (1192, 626, 36, 54).
	var synth := TTDoor.new()
	synth.setup({"x": 1210, "y": 680}, tuning)
	var sdr: Rect2 = synth.door_rect()
	var synth_ok: bool = sdr == Rect2(1192, 626, 36, 54)
	print("LOAD PILOT: synthetic door (1210,680) rect=%s expected=(1192, 626, 36, 54) ok=%s"
		% [str(sdr), str(synth_ok)])
	var total_warns := 0
	for e in per_level:
		total_warns += (e["warnings"] as Array).size()
	print("LOAD PILOT: built=%d/%d build_fail=%d door_bad=%d per_level_warnings=%d"
		% [built_ok, levels.size(), build_fail.size(), door_bad.size(),
			total_warns])
	for f in build_fail:
		print("LOAD PILOT BUILD FAIL: " + str(f))
	for d in door_bad:
		print("LOAD PILOT DOOR MISMATCH: " + str(d))
	var report := {"tool": "load_pilot_probe r2", "levels_path": levels_path,
		"levels": levels.size(), "load_error": load_err,
		"load_warnings": load_warnings, "built_ok": built_ok,
		"build_fail": build_fail, "door_bad": door_bad,
		"synthetic_door_rect": [sdr.position.x, sdr.position.y,
			sdr.size.x, sdr.size.y], "synthetic_door_ok": synth_ok,
		"per_level": per_level}
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(report))
	f.close()
	var ok: bool = load_err == "" and load_warnings.is_empty() \
		and total_warns == 0 and build_fail.is_empty() \
		and door_bad.is_empty() and synth_ok \
		and built_ok == levels.size()
	print("LOAD PILOT DONE ok=%s out=%s" % [str(ok), out_path])
	quit(0 if ok else 1)
