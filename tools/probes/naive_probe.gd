# Naive probe (Lane B verification, Run 3 / v1.0.3). Headless SceneTree script.
#
# Holds TOWARD THE DOOR and NEVER jumps, through the REAL runtime:
# the game scene's build_level() (TTBuilder -> TTRuntime/TTPlayer),
# scripted input via player.input_override, 60Hz physics steps.
# No autopilot policy, no jump edge ever set (jump_override_edge is
# never touched). The first levels must be lethal to a naive walker:
# a player who just holds toward the door must DIE, not stroll to it.
#
# Frozen die-set: final-file levels L001-L005 MUST die. The cause is
# recorded per level: hazard type (incl. which hazard) vs fall (feet
# y > 640) vs timeout/stuck. Timeout/stuck is NOT death and FAILS
# the die-set, as does reaching the door. L006-L010 are run and
# reported (informational; mostly expected to die) and never affect
# the exit code.
#
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s tools/probes/naive_probe.gd [-- --out <report.json>]
# Exits 0 only if all 5 die-set levels die. Prints one NAIVE line per
# level plus a summary. Separate probe by design: autopilot.gd is
# NOT modified for this.
extends SceneTree

const STEP_CAP := 3600  # 60s at 60Hz — generous; a walker crosses 1280px in ~4s.
const STUCK_WINDOW := 600  # frames of <10px movement at the end => "stuck".

var _fails: Array[String] = []
var _results: Array = []
var _out_path := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		if args[i] == "--out" and i + 1 < args.size():
			_out_path = args[i + 1]
			i += 2
		else:
			i += 1
	call_deferred("_run")


func _hazard_cause(runtime: Node, prect: Rect2) -> String:
	var hazards: Array = runtime.get("hazards")
	for idx in range(hazards.size()):
		var h: Node = hazards[idx]
		if bool(h.call("kills", prect)):
			var htype := str(h.get("htype"))
			if htype == "saw":
				return "hazard saw #%d centre=%s r=%s" % [idx, str(h.call("saw_centre_now")), str(h.get("radius"))]
			return "hazard %s #%d rect=%s" % [htype, idx, str(h.get("rect"))]
	return ""


func _play_level(level: Dictionary, tuning: Dictionary) -> Dictionary:
	var lid := str(level.get("id", "?"))
	var packed: PackedScene = load("res://scenes/game.tscn")
	var game: Node = packed.instantiate()
	root.add_child(game)
	await physics_frame
	await physics_frame
	game.call("build_level", level, tuning)
	await physics_frame
	await physics_frame
	var runtime: Node = game.get("runtime")
	var player: Node2D = game.get("player")
	if runtime == null or player == null:
		game.queue_free()
		await physics_frame
		return {"id": lid, "outcome": "build_failed", "cause": "no runtime/player", "steps": 0}
	var door: Dictionary = level["door"]
	var door_x := float(door["x"])
	var deaths_before := int(runtime.get("deaths"))
	var outcome := "timeout"
	var cause := ""
	var steps := 0
	var last_rect: Rect2 = player.call("player_rect")
	var last_feet_y := float(player.call("feet_pos").y)
	var window_start_pos := player.global_position
	var window_start_step := 0
	var final_pos := player.global_position
	while steps < STEP_CAP:
		# Scripted input ONLY: hold toward the door. Never jump:
		# jump_override_edge is never set anywhere in this probe.
		var feet: Vector2 = player.call("feet_pos")
		var dir := 0
		if feet.x < door_x - 4.0:
			dir = 1
		elif feet.x > door_x + 4.0:
			dir = -1
		player.set("input_override", dir)
		last_rect = player.call("player_rect")
		last_feet_y = float(feet.y)
		await physics_frame
		steps += 1
		final_pos = player.global_position
		if steps - window_start_step >= STUCK_WINDOW:
			window_start_pos = final_pos
			window_start_step = steps
		if int(runtime.get("deaths")) > deaths_before or bool(runtime.get("dead")):
			outcome = "died"
			var cur_rect: Rect2 = player.call("player_rect")
			var cur_feet_y := float(player.call("feet_pos").y)
			if cur_feet_y > 640.0 or last_feet_y > 640.0:
				cause = "fall feet_y=%.1f (y>640)" % maxf(cur_feet_y, last_feet_y)
			else:
				cause = _hazard_cause(runtime, cur_rect)
				if cause == "":
					cause = _hazard_cause(runtime, last_rect)
				if cause == "":
					cause = "hazard (unattributed: no hazard kills the death-frame rect; pos=%s)" % str(final_pos)
			break
		if bool(runtime.get("level_completed")):
			outcome = "door"
			cause = "reached the door without jumping"
			break
	if outcome == "timeout" and final_pos.distance_to(window_start_pos) < 10.0 and steps >= STUCK_WINDOW:
		outcome = "stuck"
		cause = "no death/door in %d steps; moved <10px in the last %d frames (pos=%s)" % [steps, STUCK_WINDOW, str(final_pos)]
	elif outcome == "timeout":
		cause = "no death/door in %d steps (final pos=%s)" % [steps, str(final_pos)]
	game.queue_free()
	await physics_frame
	await physics_frame
	return {"id": lid, "outcome": outcome, "cause": cause, "steps": steps}


func _run() -> void:
	print("NAIVE probe: hold toward door, NEVER jump, real runtime")
	var tuning: Dictionary = TTuning.load_tuning()
	var loaded := TTLevelData.load_levels()
	if str(loaded.get("error", "")) != "":
		print("NAIVE FAIL: load_levels error: ", str(loaded["error"]))
		quit(1)
		return
	var levels: Array = loaded["levels"]
	var by_id := {}
	for lv in levels:
		by_id[str(lv.get("id", ""))] = lv
	var die_set := ["L001", "L002", "L003", "L004", "L005"]
	var info_set := ["L006", "L007", "L008", "L009", "L010"]
	for lid in die_set + info_set:
		if not by_id.has(lid):
			print("NAIVE FAIL: level ", lid, " missing from the final file")
			_fails.append(lid + ":missing")
			continue
		var res := await _play_level(by_id[lid], tuning)
		res["die_set"] = die_set.has(lid)
		_results.append(res)
		print("NAIVE %s outcome=%s steps=%d cause=%s" % [lid, str(res["outcome"]), int(res["steps"]), str(res["cause"])])
		if die_set.has(lid) and str(res["outcome"]) != "died":
			_fails.append(lid + ":" + str(res["outcome"]))
	var died := 0
	for r in _results:
		if bool(r["die_set"]) and str(r["outcome"]) == "died":
			died += 1
	print("NAIVE SUMMARY: die-set deaths %d/5" % died)
	if _out_path != "":
		var f := FileAccess.open(_out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"die_set": die_set, "results": _results}, "\t"))
			f.close()
			print("NAIVE report: ", _out_path)
	if not _fails.is_empty():
		print("NAIVE FAILED: ", ", ".join(_fails))
		quit(1)
		return
	print("NAIVE ALL PASS: L001-L005 all die without jumping")
	quit(0)
