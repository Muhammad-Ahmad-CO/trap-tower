extends SceneTree

# Lane F2 probe: export daily-challenge levels for given dates using
# the REAL GDScript generator (TTDaily), and check determinism in
# engine: same date twice -> byte-identical level; different dates ->
# different levels. Writes one combined levels.json (schema v3) for
# the Python static checker + autopilot, and asserts every level
# passes TTLevelData validation with ZERO visual-rule warnings.
# Usage:
#   godot --headless --fixed-fps 60 --path <project> -s <this> --
#     --dates 2026-11-20,2026-11-30,2026-12-01 --out /tmp/daily.json
# Defaults: 12 dates incl. month/year boundaries; out
# ~/workspace/trap-tower/verification/f2/daily-sample.json
# Restores nothing (writes no save files). Exits 0 only if all pass.

var _fails: Array[String] = []
var _passes: Array[String] = []


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passes.append(name)
		print("F2DAILY PASS: ", name, (" | " + detail) if detail != "" else "")
	else:
		_fails.append(name)
		print("F2DAILY FAIL: ", name, (" | " + detail) if detail != "" else "")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var dates_arg := ""
	var out_arg := ""
	var i := 0
	while i < args.size():
		if args[i] == "--dates" and i + 1 < args.size():
			dates_arg = args[i + 1]
			i += 2
		elif args[i] == "--out" and i + 1 < args.size():
			out_arg = args[i + 1]
			i += 2
		else:
			i += 1
	var dates: Array[String] = []
	if dates_arg == "":
		dates = ["2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22",
			"2026-11-30", "2026-12-01", "2026-12-25", "2026-12-31",
			"2027-01-01", "2027-02-28", "2027-03-01", "2027-06-15"]
	else:
		for d in dates_arg.split(","):
			dates.append(d.strip_edges())
	if out_arg == "":
		out_arg = OS.get_environment("HOME") + "/workspace/trap-tower/verification/f2/daily-sample.json"
	var tuning := TTuning.load_tuning()
	_check("load0: tuning loads", not tuning.is_empty())
	var levels: Array = []
	var seen_sigs: Dictionary = {}
	for date in dates:
		var a: Dictionary = TTDaily.generate_for_date(date)
		var b: Dictionary = TTDaily.generate_for_date(date)
		_check("det-" + date + ": same date -> identical level",
			JSON.stringify(a) == JSON.stringify(b))
		var sig := JSON.stringify(a)
		_check("uniq-" + date + ": level differs from every other sampled date",
			not seen_sigs.has(sig), "id=" + str(a.get("id", "?")))
		seen_sigs[sig] = true
		var err := TTLevelData.validate_level(a, 0, tuning)
		_check("valid-" + date + ": runtime validation passes", err == "", err)
		var warns := TTLevelData.validate_visual_rules(a, tuning)
		_check("warn-" + date + ": zero visual-rule warnings", warns.is_empty(),
			"warnings=" + str(warns))
		levels.append(a)
	var data := {"schema_version": 3, "tuning_version": 1, "levels": levels}
	var f := FileAccess.open(out_arg, FileAccess.WRITE)
	if f == null:
		print("F2DAILY ERROR: cannot write ", out_arg)
		quit(1)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	print("F2DAILY WROTE: ", out_arg, " levels=", levels.size())
	print("F2DAILY SUMMARY: ", _passes.size(), " passed, ", _fails.size(), " failed")
	if not _fails.is_empty():
		print("F2DAILY FAILED: ", ", ".join(_fails))
		quit(1)
		return
	print("F2DAILY ALL PASS")
	quit(0)
