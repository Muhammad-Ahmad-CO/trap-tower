# Final-file runtime load probe (Lane B, Run 2 V4). Headless SceneTree script.
#
# smoke_load.gd uses in-memory dicts and does NOT cover the shipped file.
# This probe loads the REAL res://data/levels.json through the game's own
# TTLevelData.load_levels() + validate_file, then builds EVERY level
# through TTBuilder and checks each build yields a runtime with a player,
# platforms and hazards. Prints counts and exits 0 only if all 215 build.
# Also asserts the checker<->runtime agreement: load_levels must return
# ZERO visual-rule warnings on the final file, and schema_version == 3.
#
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s tools/probes/load_final_probe.gd
extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var tuning: Dictionary = TTuning.load_tuning()
	if tuning.is_empty():
		print("LOAD FINAL FAIL: tuning.json missing or invalid")
		quit(1)
		return
	print("LOAD FINAL: tuning_version=", tuning.get("tuning_version"),
		" palettes=", (tuning.get("palettes", []) as Array).size())
	var loaded := TTLevelData.load_levels()
	var err := str(loaded.get("error", ""))
	if err != "":
		print("LOAD FINAL FAIL: load_levels error: ", err)
		quit(1)
		return
	var levels: Array = loaded["levels"]
	print("LOAD FINAL: load_levels OK, levels=", levels.size())
	var warnings: Array = loaded.get("warnings", [])
	print("LOAD FINAL: warnings=", warnings.size())
	for w in warnings:
		print("LOAD FINAL WARNING: ", w)
	if not warnings.is_empty():
		print("LOAD FINAL FAIL: ", warnings.size(), " visual-rule warning(s) on the final file (checker/runtime drift)")
		quit(1)
		return
	# Schema version on the raw file: must be 3 (v3 contract).
	var raw_text0 := FileAccess.get_file_as_string("res://data/levels.json")
	var parsed0: Variant = JSON.parse_string(raw_text0)
	if typeof(parsed0) != TYPE_DICTIONARY or int((parsed0 as Dictionary).get("schema_version", -1)) != 3:
		print("LOAD FINAL FAIL: schema_version != 3 on the final file")
		quit(1)
		return
	print("LOAD FINAL: schema_version=3 OK, warnings=0 OK")
	# validate_file a second time on the raw parsed JSON (independent path).
	var raw_text := FileAccess.get_file_as_string("res://data/levels.json")
	var parsed: Variant = JSON.parse_string(raw_text)
	var verr := TTLevelData.validate_file(parsed, tuning)
	if verr != "":
		print("LOAD FINAL FAIL: validate_file: ", verr)
		quit(1)
		return
	print("LOAD FINAL: validate_file OK")
	var built := 0
	var failed: Array[String] = []
	for lv in levels:
		var builder := TTBuilder.new()
		var node: Variant = builder.build_level(lv, tuning)
		if not (node is Node):
			failed.append(str(lv.get("id", "?")) + ": build_level returned non-node")
			continue
		root.add_child(node)
		var player: Node = builder.player
		var plats: Array = builder.platforms
		var hazards: Array = builder.hazards
		if player == null or not (player is CharacterBody2D):
			failed.append(str(lv.get("id", "?")) + ": no CharacterBody2D player")
		elif plats.is_empty():
			failed.append(str(lv.get("id", "?")) + ": no platforms built")
		elif hazards.is_empty():
			# v1.0.9 Lane F: the no-hazard-kind exception doors
			# (D06/D15/D20/D36) hold ZERO hazards by design -- their
			# mechanic platforms ARE the challenge. The probe enforces
			# the SAME condition the checker + runtime validator do
			# (TTLevelData._no_hazard_kind_exception: >= 3 mechanic
			# platforms); a level that lost both hazards and mechanic
			# platforms still fails here, as does any non-exempt door
			# with no hazards. Never weaken: this is the exception,
			# not an exemption from having a challenge.
			if TTLevelData._no_hazard_kind_exception(lv):
				built += 1
			else:
				failed.append(str(lv.get("id", "?")) + ": no hazards built (Run 2 ban)")
		else:
			built += 1
		# Step one physics frame so node setup runs, then free.
		await physics_frame
		root.remove_child(node)
		node.queue_free()
		await physics_frame
	print("LOAD FINAL: built ", built, "/", levels.size(), " levels through TTBuilder")
	if not failed.is_empty():
		for f in failed:
			print("LOAD FINAL FAIL: ", f)
		quit(1)
		return
	print("LOAD FINAL OK: all ", levels.size(), " shipped levels load + validate + build")
	quit(0)
