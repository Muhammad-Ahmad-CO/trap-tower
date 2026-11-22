extends Control

# Loading screen (simple, professional — no video):
# dark charcoal background, the Trap Tower logo centred, one thin gold
# loading bar below it and a small LOADING + percentage label.
# Shows ONLY on cold start (main_scene); level returns go directly to
# map.tscn, so this screen never appears on level return.
# The bar fills over LOAD_DURATION, then the map opens. Tap / click /
# any key skips. Safety timer forces the map at 8 s so the player can
# never be stuck. Fallback (logo asset missing/unloadable): code-drawn
# TRAP TOWER text title + the same bar, never a black flash or a crash.

const LOGO_PATH := "res://assets/logo.png"
const MAP_SCENE := "res://scenes/map.tscn"
const BG_COLOR := Color(26.0 / 255.0, 29.0 / 255.0, 34.0 / 255.0)
const TRACK_COLOR := Color(58.0 / 255.0, 63.0 / 255.0, 70.0 / 255.0)
const BAR_COLOR := Color(201.0 / 255.0, 162.0 / 255.0, 39.0 / 255.0)
const LABEL_COLOR := Color(185.0 / 255.0, 190.0 / 255.0, 198.0 / 255.0)
const LOAD_DURATION := 2.2
const SAFETY_TIMEOUT := 8.0
const BAR_WIDTH := 320.0
const BAR_HEIGHT := 6.0
const BAR_X := 480.0
const BAR_Y := 520.0

var _transitioned := false
var _elapsed := 0.0
var _bar_fill: ColorRect
var _label: Label


func _ready() -> void:
	# Charcoal background first: never a black flash before the first frame.
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = BG_COLOR
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Logo plaque, centred. 1318x1054 source shown at 440x352 (same aspect).
	var logo_tex: Texture2D = null
	if ResourceLoader.exists(LOGO_PATH):
		logo_tex = load(LOGO_PATH) as Texture2D
	if logo_tex != null:
		var logo := TextureRect.new()
		logo.name = "Logo"
		logo.texture = logo_tex
		logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		logo.position = Vector2(420, 110)
		logo.size = Vector2(440, 352)
		add_child(logo)
	else:
		_build_text_title()

	# Thin loading bar: dark track + gold fill (fill grows from 0).
	var track := ColorRect.new()
	track.name = "BarTrack"
	track.color = TRACK_COLOR
	track.position = Vector2(BAR_X, BAR_Y)
	track.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	add_child(track)

	_bar_fill = ColorRect.new()
	_bar_fill.name = "BarFill"
	_bar_fill.color = BAR_COLOR
	_bar_fill.position = Vector2(BAR_X, BAR_Y)
	_bar_fill.size = Vector2(0, BAR_HEIGHT)
	add_child(_bar_fill)

	_label = Label.new()
	_label.name = "LoadingLabel"
	_label.text = "LOADING 0%"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", LABEL_COLOR)
	_label.position = Vector2(0, 540)
	_label.size = Vector2(1280, 28)
	add_child(_label)


func _process(delta: float) -> void:
	if _transitioned:
		return
	_elapsed += delta
	var frac: float = clampf(_elapsed / LOAD_DURATION, 0.0, 1.0)
	_bar_fill.size = Vector2(BAR_WIDTH * frac, BAR_HEIGHT)
	_label.text = "LOADING %d%%" % int(frac * 100.0)
	if frac >= 1.0:
		_go_to_map()
	elif _elapsed >= SAFETY_TIMEOUT:
		# Should never trigger (fill ends at 2.2 s); backstop only.
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


func _build_text_title() -> void:
	var title := Label.new()
	title.name = "TextTitle"
	title.text = "TRAP TOWER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.position = Vector2(0, 220)
	title.size = Vector2(1280, 90)
	add_child(title)
