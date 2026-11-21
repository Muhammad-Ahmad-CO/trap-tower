extends Control

# Loading screen: plays the user's Google Flow preloader video full-screen on
# cold start, then transitions to the map. Video is Ogg Theora (.ogv) — Godot
# 4.3 VideoStreamPlayer plays Theora ONLY; MP4/H.264 will NOT play.
# Fallback (video missing/unloadable): orange screen + TRAP TOWER label +
# code-drawn LOADING bar, then map. No extra bar is drawn over the video
# itself — the video already has its own loading bar.
# Tap / click / any key skips. Safety timer forces the map at 8 s if the
# video stalls, so the player can never be stuck on a black screen.

const VIDEO_PATH := "res://assets/preloader.ogv"
const MAP_SCENE := "res://scenes/map.tscn"
const BG_COLOR := Color(238.0 / 255.0, 77.0 / 255.0, 42.0 / 255.0)
const SAFETY_TIMEOUT := 8.0
const FALLBACK_DURATION := 2.5

var _player: VideoStreamPlayer
var _transitioned := false
var _elapsed := 0.0
var _fallback := false
var _fallback_bar: ColorRect
var _fallback_bar_bg: ColorRect


func _ready() -> void:
	# Orange background first: never a black flash before the first frame.
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = BG_COLOR
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_player = VideoStreamPlayer.new()
	_player.name = "PreloaderVideo"
	_player.set_anchors_preset(Control.PRESET_FULL_RECT)
	# NOTE: Godot 4.3 VideoStreamPlayer has NO expand_mode property (verified
	# via ClassDB: no such property/constant). It draws the video stretched to
	# the control rect, and the video is exactly 1280x720 = viewport size, so
	# the full-rect player fills the screen exactly with no distortion.
	_player.finished.connect(_go_to_map)
	add_child(_player)

	var stream: VideoStream = null
	if ResourceLoader.exists(VIDEO_PATH):
		stream = load(VIDEO_PATH) as VideoStream
	if stream != null:
		_player.stream = stream
		_player.play()
	else:
		_fallback = true
		_build_fallback()


func _process(delta: float) -> void:
	if _transitioned:
		return
	_elapsed += delta
	if _fallback:
		_update_fallback()
		if _elapsed >= FALLBACK_DURATION:
			_go_to_map()
	elif _elapsed >= SAFETY_TIMEOUT:
		# Video stalled (decode error, driver issue) — never trap the player.
		_go_to_map()


func _input(event: InputEvent) -> void:
	if _transitioned:
		return
	if event is InputEventScreenTouch and event.pressed:
		_go_to_map()
	elif event is InputEventMouseButton and event.pressed:
		_go_to_map()
	elif event is InputEventKey and event.pressed and not event.echo:
		_go_to_map()


func _go_to_map() -> void:
	if _transitioned:
		return
	_transitioned = true
	get_tree().change_scene_to_file(MAP_SCENE)


func _build_fallback() -> void:
	var title := Label.new()
	title.name = "FallbackTitle"
	title.text = "TRAP TOWER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.position = Vector2(0, 180)
	title.size = Vector2(1280, 90)
	add_child(title)

	var hint := Label.new()
	hint.name = "FallbackHint"
	hint.text = "LOADING..."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 28)
	hint.add_theme_color_override("font_color", Color.WHITE)
	hint.position = Vector2(0, 560)
	hint.size = Vector2(1280, 40)
	add_child(hint)

	_fallback_bar_bg = ColorRect.new()
	_fallback_bar_bg.name = "FallbackBarBg"
	_fallback_bar_bg.color = Color(0, 0, 0, 0.35)
	_fallback_bar_bg.position = Vector2(440, 610)
	_fallback_bar_bg.size = Vector2(400, 16)
	add_child(_fallback_bar_bg)

	_fallback_bar = ColorRect.new()
	_fallback_bar.name = "FallbackBar"
	_fallback_bar.color = Color.WHITE
	_fallback_bar.position = Vector2(440, 610)
	_fallback_bar.size = Vector2(0, 16)
	add_child(_fallback_bar)


func _update_fallback() -> void:
	if _fallback_bar == null:
		return
	var frac: float = clampf(_elapsed / FALLBACK_DURATION, 0.0, 1.0)
	_fallback_bar.size = Vector2(400.0 * frac, 16)
