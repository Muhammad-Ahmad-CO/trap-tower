# Pixel probe (Round 2, Lane V). Renders REAL frames through the real
# builder under Xvfb (NOT --headless) and captures PNGs proving
# draw-vs-collision alignment:
#  (a) hero drawn silhouette vs its 15x39 collision rect (red overlay),
#      on a LIGHT palette (outline OFF) and a DARK palette (outline ON),
#      in two run-cycle poses (legs together vs legs apart);
#  (b) door drawn rect vs its 36x54 trigger rect (green overlay),
#      including the brief's case door (1210, 680) -> (1192, 626, 36, 54).
# Fixture runs use the flat trace fixture re-paletted (safe flat ground
# so the hero can run freely for pose capture); candidate runs capture
# real pilot levels standing at spawn.
#
# Run:
#   xvfb-run -a <godot> --fixed-fps 60 --path <repo>/godot \
#       -s <repo>/verification/pixel_probe.gd -- \
#       --levels <candidates.json> --fixture /tmp/tt_trace_fixture.json \
#       --ids D01S1V1,D31S1V1 --out <dir>
# Exit 0 iff every capture is a non-blank 1280x720 image.
extends SceneTree

class Overlay extends Node2D:
	var player: Node = null
	var door: Node = null

	func _draw() -> void:
		if player != null and is_instance_valid(player):
			var pr: Rect2 = player.call("player_rect")
			draw_rect(pr, Color(1, 0, 0), false, 2.0)
		if door != null and is_instance_valid(door):
			var dr: Rect2 = door.call("door_rect")
			draw_rect(dr, Color(0, 1, 0), false, 2.0)


func _initialize() -> void:
	call_deferred("_run")


func _parse_args() -> Dictionary:
	var out := {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i := 0
	while i < raw.size():
		if raw[i] in ["--levels", "--fixture", "--ids", "--out"] \
				and i + 1 < raw.size():
			out[raw[i].trim_prefix("--")] = raw[i + 1]
			i += 2
		else:
			i += 1
	return out


func _capture(out_path: String) -> Dictionary:
	await process_frame
	await process_frame
	var tex: Texture2D = root.get_texture()
	var img: Image = tex.get_image()
	var ok: bool = img != null and img.get_width() == 1280 \
		and img.get_height() == 720
	var distinct := {}
	if ok:
		for y in range(0, 720, 12):
			for x in range(0, 1280, 12):
				distinct[img.get_pixel(x, y)] = true
		ok = distinct.size() >= 3
	if ok:
		var err: Error = img.save_png(out_path)
		ok = err == OK
	return {"path": out_path, "ok": ok, "distinct": distinct.size()}


func _run() -> void:
	var args := _parse_args()
	var levels_path: String = str(args.get("levels", ""))
	var fixture_path: String = str(args.get("fixture", ""))
	var ids: Array = str(args.get("ids", "")).split(",")
	var out_dir: String = str(args.get("out", ""))
	if levels_path == "" or out_dir == "":
		print("PIXEL ERROR: --levels and --out required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	var tuning: Dictionary = TTuning.load_tuning()
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(levels_path))
	var by_id := {}
	for lv in parsed["levels"]:
		by_id[str(lv.get("id", ""))] = lv
	var results: Array = []
	# Fixture runs: flat ground, two palettes (light 0 / dark 30).
	var fix_parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(fixture_path))
	var fix_level: Dictionary = (fix_parsed["levels"] as Array)[0]
	for pal in [0, 30]:
		var lv: Dictionary = fix_level.duplicate(true)
		lv["palette"] = pal
		lv["id"] = "FIXTURE_P%d" % pal
		results.append(await _shoot(lv, tuning, out_dir, true))
	# Candidate standing shots.
	for lid in ids:
		lid = lid.strip_edges()
		if by_id.has(lid):
			results.append(await _shoot(by_id[lid], tuning, out_dir,
				false))
	var f := FileAccess.open(out_dir + "/pixel-summary.json",
		FileAccess.WRITE)
	f.store_string(JSON.stringify({"tool": "pixel_probe r2",
		"results": results}))
	f.close()
	var all_ok: bool = true
	for r in results:
		for c in r["captures"]:
			if not bool(c.get("ok", false)):
				all_ok = false
	print("PIXEL DONE all_ok=%s" % str(all_ok))
	quit(0 if all_ok else 1)


func _shoot(level: Dictionary, tuning: Dictionary, out_dir: String,
		run_poses: bool) -> Dictionary:
	var lid := str(level.get("id", "?"))
	var builder := TTBuilder.new()
	var rt: Node = builder.build_level(level, tuning)
	var pal: Dictionary = builder.palette
	var bg := ColorRect.new()
	bg.color = TTuning.col(str(pal.get("bg", "#E8871E")))
	bg.position = Vector2.ZERO
	bg.size = Vector2(1280, 720)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	root.add_child(rt)
	var player: Node = builder.player
	var door_node: Node = builder.door
	var dr: Rect2 = door_node.call("door_rect")
	var res := {"id": lid, "palette": int(level.get("palette", -1)),
		"bg": str(pal.get("bg", "")),
		"dark_bg_outline": bool(player.get("_dark_bg")),
		"door_rect": [dr.position.x, dr.position.y, dr.size.x, dr.size.y],
		"captures": []}
	await process_frame
	await process_frame
	await process_frame
	res["captures"].append(await _capture(
		out_dir + "/" + lid + "_clean.png"))
	var ov := Overlay.new()
	ov.z_index = 200
	ov.player = player
	ov.door = door_node
	root.add_child(ov)
	res["captures"].append(await _capture(
		out_dir + "/" + lid + "_overlay_stand.png"))
	if run_poses:
		player.set("input_override", 1)
		var got_spread := false
		var got_together := false
		var guard := 0
		while guard < 600 and not (got_spread and got_together):
			await process_frame
			guard += 1
			if bool(rt.get("dead")) or bool(rt.get("level_completed")):
				break
			var rp: float = float(player.get("run_phase"))
			var s: float = sin(rp)
			if not got_spread and s < -0.95:
				res["captures"].append(await _capture(
					out_dir + "/" + lid + "_overlay_spread.png"))
				res["spread_run_phase"] = rp
				got_spread = true
			elif not got_together and absf(s) < 0.15:
				res["captures"].append(await _capture(
					out_dir + "/" + lid + "_overlay_together.png"))
				res["together_run_phase"] = rp
				got_together = true
		res["poses_captured"] = [got_spread, got_together]
	root.remove_child(rt)
	rt.queue_free()
	root.remove_child(bg)
	bg.queue_free()
	root.remove_child(ov)
	ov.queue_free()
	await process_frame
	await process_frame
	return res
