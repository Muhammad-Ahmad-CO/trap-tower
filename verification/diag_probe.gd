# Diagnostic probe (Round 2, Lane V). NOT a gate tool: it replays one
# candidate level at a time through the REAL loader + builder with a
# SIMPLE greedy policy (run toward the door; jump when a hazard, a
# mountable step, or a gap is ahead) and logs WHERE the hero dies and
# WHAT kills it (hazard rect id/type, fall, timeout). Purpose: explain
# autopilot failures, not replace the autopilot.
#
# Run:
#   <godot> --headless --fixed-fps 60 --path <repo>/godot \
#       -s <repo>/verification/diag_probe.gd -- \
#       --levels <candidates.json> --ids D02S1V1,D01S2V1 \
#       --out /tmp/diag.json
extends SceneTree

const LOOKAHEAD := 96.0
const MAX_FRAMES := 1200


func _initialize() -> void:
	call_deferred("_run")


func _parse_args() -> Dictionary:
	var out := {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i := 0
	while i < raw.size():
		if raw[i] in ["--levels", "--ids", "--out", "--mode"] and i + 1 < raw.size():
			out[raw[i].trim_prefix("--")] = raw[i + 1]
			i += 2
		else:
			i += 1
	return out


func _lethal_rects(level: Dictionary) -> Array:
	var rects: Array = []
	var idx := 0
	for h in level["hazards"]:
		var t := str(h.get("type", ""))
		if t == "spikes" or t == "spiked_column":
			rects.append({"id": idx, "type": t,
				"rect": Rect2(float(h["x"]), float(h["y"]),
					float(h["w"]), float(h["h"]))})
		idx += 1
	return rects


# _jump_perfect v2 state (reset per level in _play_one).
var _v2_air_frames := 0
var _v2_brake_frame := -1
var _v2_mount_active := false


func _run() -> void:
	var args := _parse_args()
	var levels_path: String = str(args.get("levels", ""))
	var ids: Array = str(args.get("ids", "")).split(",")
	var out_path: String = str(args.get("out", "/tmp/diag.json"))
	if levels_path == "" or ids.is_empty():
		print("DIAG ERROR: --levels and --ids required")
		quit(2)
		return
	var tuning: Dictionary = TTuning.load_tuning()
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(levels_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		print("DIAG ERROR: levels file is not a JSON object")
		quit(2)
		return
	var by_id := {}
	for lv in parsed["levels"]:
		by_id[str(lv.get("id", ""))] = lv
	var results: Array = []
	for lid in ids:
		lid = lid.strip_edges()
		if not by_id.has(lid):
			results.append({"id": lid, "outcome": "missing"})
			continue
		var level: Dictionary = by_id[lid]
		var err: String = TTLevelData.validate_file(
			{"schema_version": 3, "tuning_version": 1, "levels": [level]},
			tuning)
		if err != "":
			results.append({"id": lid, "outcome": "invalid", "error": err})
			continue
		results.append(await _play_one(level, tuning,
			str(args.get("mode", "greedy"))))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"tool": "diag_probe r2", "results": results}))
	f.close()
	print("DIAG DONE n=%d out=%s" % [results.size(), out_path])
	quit(0)


func _play_one(level: Dictionary, tuning: Dictionary,
		mode: String) -> Dictionary:
	var lid := str(level.get("id", "?"))
	var builder := TTBuilder.new()
	var rt: Node = builder.build_level(level, tuning)
	root.add_child(rt)
	var player: CharacterBody2D = builder.player
	var door: Dictionary = level["door"]
	var dir := 1.0
	if float(door["x"]) < float(level["spawn"]["x"]):
		dir = -1.0
	player.set("input_override", int(dir))
	var lethal: Array = _lethal_rects(level)
	var plats: Array = level["platforms"]
	var trace: Array = []
	_v2_air_frames = 0
	_v2_brake_frame = -1
	_v2_mount_active = false
	var frame := 0
	var outcome := "timeout"
	var death := {}
	await physics_frame
	await physics_frame
	while frame < MAX_FRAMES:
		await physics_frame
		frame += 1
		var feet: Vector2 = player.call("feet_pos")
		var on_floor: bool = player.is_on_floor()
		# Jump decision. Perfect mode runs every frame (not only
		# on_floor) so a braked mount jump can release the stick mid-air.
		if mode == "perfect":
			_jump_perfect(level, lethal, plats, feet, dir, player, on_floor)
		elif on_floor:
			_jump_greedy(lethal, plats, feet, dir, player)
		if frame % 6 == 0:
			trace.append({"t": snappedf(frame / 60.0, 0.01),
				"x": snappedf(feet.x, 0.1), "y": snappedf(feet.y, 0.1),
				"vx": snappedf(player.velocity.x, 0.1),
				"vy": snappedf(player.velocity.y, 0.1),
				"floor": on_floor})
		if bool(rt.get("dead")):
			outcome = "died"
			var prect: Rect2 = player.call("player_rect")
			death = {"t": snappedf(frame / 60.0, 0.01),
				"x": snappedf(feet.x, 0.1), "y": snappedf(feet.y, 0.1),
				"cause": "unknown"}
			if feet.y > 760.0:
				death["cause"] = "fall"
			else:
				for lr in lethal:
					if (lr["rect"] as Rect2).intersects(prect):
						death["cause"] = str(lr["type"])
						death["hazard_id"] = lr["id"]
						death["hazard_rect"] = [lr["rect"].position.x,
							lr["rect"].position.y, lr["rect"].size.x,
							lr["rect"].size.y]
						break
			break
		if bool(rt.get("level_completed")):
			outcome = "door"
			break
	var res := {"id": lid, "outcome": outcome, "frames": frame,
		"death": death, "trace_tail": trace.slice(maxi(0, trace.size() - 12))}
	root.remove_child(rt)
	rt.queue_free()
	await physics_frame
	await physics_frame
	return res

func _ground_ahead(plats: Array, feet: Vector2, dir: float) -> bool:
	for probe_dx in [30.0, 60.0, 90.0]:
		var px: float = feet.x + dir * probe_dx
		for p in plats:
			var r := Rect2(float(p["x"]), float(p["y"]),
				float(p["w"]), float(p["h"]))
			if r.position.x <= px and px <= r.position.x + r.size.x \
					and feet.y - 6.0 <= r.position.y \
					and r.position.y <= feet.y + 14.0:
				return true
	return false


func _mount_ahead(plats: Array, feet: Vector2, dir: float) -> bool:
	for p in plats:
		var top: float = float(p["y"])
		if top < feet.y - 8.0 and top >= feet.y - 45.0:
			var near_edge: float = float(p["x"]) if dir > 0.0 \
				else float(p["x"]) + float(p["w"])
			var dist_edge: float = (near_edge - feet.x) * dir
			if dist_edge >= -10.0 and dist_edge <= 70.0:
				return true
	return false


func _jump_greedy(lethal: Array, plats: Array, feet: Vector2,
		dir: float, player: CharacterBody2D) -> void:
	var probe := Rect2(
		feet.x if dir > 0.0 else feet.x - LOOKAHEAD,
		feet.y - 48.0, LOOKAHEAD, 52.0)
	var hazard_ahead := false
	for lr in lethal:
		if (lr["rect"] as Rect2).intersects(probe):
			hazard_ahead = true
			break
	var ground_ahead := _ground_ahead(plats, feet, dir)
	var mount := _mount_ahead(plats, feet, dir)
	var gap_ahead: bool = not ground_ahead and not mount
	if hazard_ahead or mount or gap_ahead:
		player.set("jump_override_edge", true)


# Perfect-play v2 (D19S2 solvability test ONLY).
#
# (a) Strip windows are computed relative to the step-top ground
# (feet.y = strip bottom) and are HEIGHT-AWARE: the feet must clear
# the strip's top across the whole rect-overlap span, with the
# rise/offset table interpolated from the discrete trajectory
# (vy=-570 frame 0, then +3110/60 per frame capped at 600, 4.05px/f).
# For 10px teeth this reproduces the v1 window; for taller strips it
# shrinks. D19S2 strip [216,590,40,10] on step-top 600 -> window
# [174.5, 204.5] (width 30).
# (b) The strip takeoff is chosen by landing-target / wall clearance,
# not earliest-in-window: the sim must clear the strip, put the
# hero's feet <= the next step's top when the rect's right edge
# reaches the step face (centre 248.5 for D19S2), and land on that
# step. From the rise table, takeoffs 184-204 give feet ~556-547 at
# the wall and land on (256,560). Both the chosen takeoff and one
# frame later (+4.05px, the actual takeoff can slip a frame) must pass.
# (c) The mount jump onto the strip's step is braked/shortened (stick
# released mid-air, instant stop) so it lands in [167.5, 204.5] --
# fully on the step (face + half-width) and no later than the strip
# window's end -- instead of flying long onto the strip.
# A strip with no valid takeoff is unjumpable by this criterion: do
# not jump early (record the death as-is).
func _strip_window_v2(r: Rect2, dir: float, ground_y: float) -> Dictionary:
	var hw := 7.5
	var h: float = ground_y - r.position.y
	var offs: Array = []
	var vy := -570.0
	var off := 0.0
	for f in range(90):
		if f > 0:
			vy = minf(vy + 3110.0 / 60.0, 600.0)
		off += vy / 60.0
		offs.append(off)
		if off > 220.0:
			break
	var first := -1
	var last := -1
	for f in range(offs.size()):
		if -float(offs[f]) >= h:
			if first < 0:
				first = f
			last = f
	if first < 0:
		return {"lo": 0.0, "hi": -1.0, "ok": false}
	var x_lo: float
	if first == 0:
		x_lo = 4.05
	else:
		var r0: float = -float(offs[first - 1])
		var r1: float = -float(offs[first])
		var frac: float = (h - r0) / maxf(0.001, r1 - r0)
		x_lo = float(first) * 4.05 + frac * 4.05
	var x_hi: float
	if last >= offs.size() - 1:
		x_hi = float(last + 1) * 4.05
	else:
		var ra: float = -float(offs[last])
		var rb: float = -float(offs[last + 1])
		var frac2: float = (ra - h) / maxf(0.001, ra - rb)
		x_hi = float(last + 1) * 4.05 + frac2 * 4.05
	var rx0: float = r.position.x
	var rx1: float = r.position.x + r.size.x
	var lo: float = rx1 + hw - x_hi if dir > 0.0 else rx1 + hw + x_lo
	var hi: float = rx0 - hw - x_lo if dir > 0.0 else rx0 - hw + x_hi
	return {"lo": lo, "hi": hi, "ok": lo <= hi}


# Discrete jump sim, same integration as TTPlayer. brake_frame >= 0:
# vx = 0 from that flight frame on (instant stop). face_x >= 0:
# record feet the first frame the rect's near edge reaches the face.
# Returns {ok, land_x, land_y, face_feet, why}.
func _sim_jump(takeoff_x: float, feet_y: float, dir: float,
		plats: Array, lethal: Array, brake_frame: int = -1,
		face_x: float = -1.0) -> Dictionary:
	var hw := 7.5
	var ph := 39.0
	var x := takeoff_x
	var y := feet_y
	var vy := -570.0
	var prev_y := y
	var face_feet := -1.0
	for f in range(90):
		if f > 0:
			vy = minf(vy + 3110.0 / 60.0, 600.0)
		var vx := 243.0 * dir
		if brake_frame >= 0 and f >= brake_frame:
			vx = 0.0
		x += vx / 60.0
		y += vy / 60.0
		var rect := Rect2(x - hw, y - ph, 2.0 * hw, ph)
		for lr in lethal:
			if (lr["rect"] as Rect2).intersects(rect):
				return {"ok": false, "why": "strip", "face_feet": face_feet}
		if face_x >= 0.0 and face_feet < 0.0:
			if (dir > 0.0 and x + hw >= face_x) \
					or (dir < 0.0 and x - hw <= face_x):
				face_feet = y
		if vy > 0.0:
			for p in plats:
				var r := Rect2(float(p["x"]), float(p["y"]),
						float(p["w"]), float(p["h"]))
				if prev_y <= r.position.y + 1.0 and y >= r.position.y \
						and x >= r.position.x - 6.0 \
						and x <= r.position.x + r.size.x + 6.0:
					return {"ok": true, "land_x": x, "land_y": r.position.y,
							"face_feet": face_feet}
		for p in plats:
			var r := Rect2(float(p["x"]), float(p["y"]),
					float(p["w"]), float(p["h"]))
			if r.intersects(rect):
				return {"ok": false, "why": "wall", "face_feet": face_feet,
						"wall_x": r.position.x, "feet_y": y}
		if y > 760.0:
			return {"ok": false, "why": "fall", "face_feet": face_feet}
		prev_y = y
	return {"ok": false, "why": "timeout", "face_feet": face_feet}


# The step-up platform immediately after the strip (its face at the
# strip's far edge), if any. {} = no step after the strip.
func _step_after_strip(plats: Array, r: Rect2, feet: Vector2,
		dir: float) -> Dictionary:
	var edge: float = r.position.x + r.size.x if dir > 0.0 \
			else r.position.x
	for p in plats:
		var top: float = float(p["y"])
		if top >= feet.y - 8.0:
			continue
		var face: float = float(p["x"]) if dir > 0.0 \
				else float(p["x"]) + float(p["w"])
		if absf(face - edge) <= 2.0:
			return {"face": face, "top": top,
					"rect": Rect2(float(p["x"]), float(p["y"]),
							float(p["w"]), float(p["h"]))}
	return {}


# One takeoff passes iff the sim clears the strip, clears the step
# face (feet <= step top when the rect's near edge reaches the face)
# and lands on the step (or, with no step after the strip, lands back
# on the same ground past the strip).
func _sim_strip_takeoff(t: float, feet_y: float, dir: float,
		plats: Array, lethal: Array, target: Dictionary) -> bool:
	var face_x := -1.0
	var face_top := 0.0
	if not target.is_empty():
		face_x = float(target["face"])
		face_top = float(target["top"])
	var sim := _sim_jump(t, feet_y, dir, plats, lethal, -1, face_x)
	if not bool(sim.get("ok", false)):
		return false
	if target.is_empty():
		# Feet y jitters ~0.08px under floor snap; 1.0px still only
		# matches the same ground (step tops differ by >=20px).
		return absf(float(sim["land_y"]) - feet_y) <= 1.0
	if absf(float(sim["land_y"]) - face_top) > 0.01:
		return false
	var tr: Rect2 = target["rect"]
	if float(sim["land_x"]) < tr.position.x \
			or float(sim["land_x"]) > tr.position.x + tr.size.x:
		return false
	var ff: float = float(sim.get("face_feet", -1.0))
	return ff >= 0.0 and ff <= face_top


# Earliest takeoff in the window that clears at both t and t+4.05
# (the actual takeoff can slip one frame past the chosen point).
# -1.0 = no takeoff in the window clears: unjumpable by this criterion.
func _choose_strip_takeoff(lo: float, hi: float, feet: Vector2,
		dir: float, plats: Array, lethal: Array,
		target: Dictionary) -> float:
	var t := lo
	while t <= hi:
		if _sim_strip_takeoff(t, feet.y, dir, plats, lethal, target) \
				and _sim_strip_takeoff(t + 4.05, feet.y, dir, plats,
						lethal, target):
			return t
		t += 4.05
	return -1.0


# Choose (takeoff, brake_frame) for the mount jump onto the strip's
# step so the sim lands in [land_lo, land_hi] on the mount top.
# {} = no such jump (fall back to the greedy mount trigger).
func _choose_mount_jump(feet: Vector2, dir: float, plats: Array,
		lethal: Array, land_lo: float, land_hi: float,
		target_top: float) -> Dictionary:
	var t := feet.x
	var guard := 0
	while t <= feet.x + 90.0 and guard < 24:
		guard += 1
		for b in [-1, 8, 10, 12, 14, 16, 18, 20, 22, 24]:
			var ok := true
			for tt in [t, t + 4.05]:
				var sim := _sim_jump(tt, feet.y, dir, plats, lethal, b)
				if not bool(sim.get("ok", false)) \
						or absf(float(sim["land_y"]) - target_top) > 0.01 \
						or float(sim["land_x"]) < land_lo \
						or float(sim["land_x"]) > land_hi:
					ok = false
					break
			if ok:
				return {"takeoff": t, "brake_frame": b}
		t += 4.05
	return {}


func _maybe_mount_jump(lethal: Array, plats: Array, feet: Vector2,
		dir: float, player: CharacterBody2D) -> void:
	# Find the mount target: nearest platform whose top is above feet
	# and whose near face is ahead within 70px.
	var target := {}
	var face := 0.0
	for p in plats:
		var top: float = float(p["y"])
		if top < feet.y - 8.0 and top >= feet.y - 45.0:
			var near_edge: float = float(p["x"]) if dir > 0.0 \
				else float(p["x"]) + float(p["w"])
			var d: float = (near_edge - feet.x) * dir
			if d >= -10.0 and d <= 70.0:
				target = p
				face = near_edge
				break
	if target.is_empty():
		# Gap (no mount): greedy jump.
		player.set("jump_override_edge", true)
		return
	# Next strip sitting on the mount target's top?
	var strip_r := Rect2()
	var strip_found := false
	for lr in lethal:
		if str(lr["type"]) != "spikes":
			continue
		var r: Rect2 = lr["rect"]
		if absf(r.position.y + r.size.y - float(target["y"])) > 14.0:
			continue
		if dir > 0.0 and r.position.x >= float(target["x"]) \
				and r.position.x < float(target["x"]) + float(target["w"]):
			strip_r = r
			strip_found = true
			break
		if dir < 0.0 and r.position.x + r.size.x \
					<= float(target["x"]) + float(target["w"]) \
				and r.position.x + r.size.x > float(target["x"]):
			strip_r = r
			strip_found = true
			break
	if not strip_found:
		player.set("jump_override_edge", true)
		return
	var win := _strip_window_v2(strip_r, dir, float(target["y"]))
	# Land fully on the step (face + half-width) and no later than the
	# strip window's end, so the strip jump can still fire from it.
	var land_lo: float = face + 7.5 if dir > 0.0 else face - 7.5
	var land_hi: float = float(win["hi"]) if dir > 0.0 \
			else float(win["lo"])
	if dir < 0.0:
		var tmp := land_lo
		land_lo = land_hi
		land_hi = tmp
	var choice := _choose_mount_jump(feet, dir, plats, lethal,
			land_lo, land_hi, float(target["y"]))
	if choice.is_empty():
		player.set("jump_override_edge", true)
		return
	var mt: float = float(choice["takeoff"])
	if feet.x >= mt - 0.1:
		_v2_brake_frame = int(choice["brake_frame"])
		_v2_mount_active = true
		player.set("jump_override_edge", true)


func _jump_perfect(level: Dictionary, lethal: Array, plats: Array,
		feet: Vector2, dir: float, player: CharacterBody2D,
		on_floor: bool) -> void:
	# Mid-air: braking for a shortened mount jump.
	if not on_floor:
		_v2_air_frames += 1
		if _v2_mount_active and _v2_brake_frame >= 0 \
				and _v2_air_frames >= _v2_brake_frame:
			player.set("input_override", 0)
		return
	_v2_air_frames = 0
	# Landed: restore run input after a braked mount jump.
	if _v2_mount_active:
		_v2_mount_active = false
		player.set("input_override", int(dir))
	# Nearest ground-sitting up-spike strip ahead (same ground level).
	var best: Dictionary = {}
	var best_dist := 1e9
	for lr in lethal:
		if str(lr["type"]) != "spikes":
			continue
		var r: Rect2 = lr["rect"]
		if absf(r.position.y + r.size.y - feet.y) > 14.0:
			continue
		var near: float = r.position.x if dir > 0.0 \
				else r.position.x + r.size.x
		var dist: float = (near - feet.x) * dir
		if dist < -20.0:
			continue
		if dist < best_dist:
			best_dist = dist
			best = lr
	if not best.is_empty():
		var r: Rect2 = best["rect"]
		var win := _strip_window_v2(r, dir, feet.y)
		if not bool(win["ok"]):
			# Unjumpable strip: no takeoff exists; do not jump early
			# (record the death as-is).
			return
		var lo: float = float(win["lo"])
		var hi: float = float(win["hi"])
		var target := _step_after_strip(plats, r, feet, dir)
		var chosen := _choose_strip_takeoff(lo, hi, feet, dir, plats,
				lethal, target)
		if chosen >= 0.0:
			if feet.x >= chosen - 0.1:
				player.set("jump_override_edge", true)
				return
			# Window not reached yet: hold off; mounts/gaps within
			# the window approach still need jumping.
			if not _mount_ahead(plats, feet, dir) \
					and _ground_ahead(plats, feet, dir):
				return
		else:
			# No takeoff in the window clears + lands: unjumpable
			# by this criterion; do not jump early.
			return
	if _mount_ahead(plats, feet, dir) \
			or not _ground_ahead(plats, feet, dir):
		_maybe_mount_jump(lethal, plats, feet, dir, player)
