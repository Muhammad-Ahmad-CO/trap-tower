extends SceneTree

# Preloader probe (verification ONLY, never shipped as gameplay):
# instantiates res://scenes/loading.tscn under a real renderer (Xvfb),
# logs VideoStreamPlayer state per second, saves a mid-video screenshot
# (~2 s) and a post-transition screenshot (~7 s, must be the map), and
# exits 0 ONLY if the video actually played (stream_position advanced past
# 3 s) AND the scene changed to Map. Exit 1 otherwise.
# Run: xvfb-run -a <godot> --display-driver x11 --rendering-driver opengl3 \
#        --path <project> -s res://scripts/preloader_probe.gd
# NOTE: when run with -s, this script IS the main loop, so current_scene is
# null until loading.gd itself calls change_scene_to_file. The loading node
# is therefore tracked via a stored reference, NOT via current_scene.
# MainLoop._process returns true to QUIT — this probe must return false
# until it decides to quit.

const OUT_DIR := "/home/hatch/workspace/trap-tower/verification/pass2/preloader"

var _elapsed := 0.0
var _last_log_sec := -1
var _max_position := 0.0
var _saw_playing := false
var _mid_saved := false
var _post_saved := false
var _done := false
var _loading_node: Node = null


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/loading.tscn") as PackedScene
	if packed == null:
		print("PRELOADER PROBE FAIL: loading.tscn did not load")
		quit(1)
		return
	_loading_node = packed.instantiate()
	root.add_child(_loading_node)
	print("PRELOADER PROBE: loading scene instantiated")


func _process(delta: float) -> bool:
	if _done:
		return false
	_elapsed += delta
	var sec := int(_elapsed)
	if sec != _last_log_sec:
		_last_log_sec = sec
		_log_state(sec)
	if not _mid_saved and _elapsed >= 2.0:
		_mid_saved = true
		_save_shot("loading_mid.png")
	if not _post_saved and _elapsed >= 7.0:
		_post_saved = true
		_save_shot("loading_after_map.png")
		_evaluate()
	if _elapsed >= 12.0 and not _done:
		print("PRELOADER PROBE FAIL: timed out at 12 s without evaluation")
		quit(1)
	return false


func _log_state(sec: int) -> void:
	var scene_name := "(none)"
	if current_scene != null:
		scene_name = current_scene.name
	elif _loading_node != null and is_instance_valid(_loading_node):
		scene_name = "Loading(instantiated)"
	var player := _find_player()
	if player != null:
		var pos: float = player.stream_position
		if pos > _max_position:
			_max_position = pos
		if player.is_playing():
			_saw_playing = true
		print("PRELOADER PROBE t=", sec, "s scene=", scene_name,
			" playing=", player.is_playing(), " pos=", snappedf(pos, 0.01))
	else:
		print("PRELOADER PROBE t=", sec, "s scene=", scene_name,
			" player=(none — scene changed or fallback)")


func _find_player() -> VideoStreamPlayer:
	if _loading_node == null or not is_instance_valid(_loading_node):
		return null
	return _loading_node.find_child("PreloaderVideo", true, false) as VideoStreamPlayer


func _save_shot(fname: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		print("PRELOADER PROBE FAIL: viewport image null for ", fname)
		return
	var err := img.save_png(OUT_DIR + "/" + fname)
	print("PRELOADER PROBE shot ", fname, " err=", err,
		" size=", img.get_width(), "x", img.get_height())


func _evaluate() -> void:
	_done = true
	var scene_name := "(none)"
	if current_scene != null:
		scene_name = current_scene.name
	print("PRELOADER PROBE RESULT: max_pos=", snappedf(_max_position, 0.01),
		" saw_playing=", _saw_playing, " final_scene=", scene_name)
	if not _saw_playing:
		print("PRELOADER PROBE FAIL: video never reported playing")
		quit(1)
		return
	if _max_position < 3.0:
		print("PRELOADER PROBE FAIL: stream_position only reached ", _max_position)
		quit(1)
		return
	if scene_name != "Map":
		print("PRELOADER PROBE FAIL: final scene is ", scene_name, ", expected Map")
		quit(1)
		return
	print("PRELOADER PROBE PASS: video played and transitioned to Map")
	quit(0)
