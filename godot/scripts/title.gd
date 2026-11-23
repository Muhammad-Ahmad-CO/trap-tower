extends Control

# Title screen (Lane U5, M6 — 1 Player ONLY).
# Original screen, own layout: dark trap-purple background, the Trap
# Tower logo plaque centred (pixel-text TRAP TOWER fallback when the
# logo PNG has not landed), "Made by Ahmed", and ONE entry card:
# "1 Player". There is deliberately NO 2-player card — 2-player is
# HELD for the user's explicit decision (GATE-AMENDMENT-1 / checklist
# M6) and must not be built into v1.0.9.
# Cold-start flow: preloader (loading.tscn) -> title -> map. The
# map is the only exit: tapping 1 Player (or Enter/Space) opens
# map.tscn. Level returns go to the map directly, never back here.

const LOGO_PATH := "res://assets/logo.png"
const MAP_SCENE := "res://scenes/map.tscn"
# Const-legal constructor form (Color.html() is NOT a constant
# expression in GDScript): #2B0A8A trap purple, #FFD23F gold.
const BG_COLOR := Color(0.1686, 0.0392, 0.5412)
const GOLD := Color(1.0, 0.8235, 0.2471)
const DARK_INK := Color(0.10, 0.04, 0.35)

var _transitioned := false


func _ready() -> void:
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = BG_COLOR
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Logo plaque, centred (same 440x352 presentation as the
	# preloader). Fallback: code-drawn pixel-text title, never a
	# black flash or a crash when the PNG is absent.
	if ResourceLoader.exists(LOGO_PATH):
		var logo := TextureRect.new()
		logo.name = "Logo"
		logo.texture = load(LOGO_PATH)
		logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		logo.position = Vector2(420, 80)
		logo.size = Vector2(440, 352)
		add_child(logo)
	else:
		var title := TTPixelLabel.new()
		title.name = "TextTitle"
		title.text = "TRAP TOWER"
		title.pixel_size = 9
		title.color = GOLD
		title.align = HORIZONTAL_ALIGNMENT_CENTER
		title.width = 1280.0
		title.position = Vector2(0, 220)
		add_child(title)

	var credit := TTPixelLabel.new()
	credit.name = "Credit"
	credit.text = "Made by Ahmed"
	credit.pixel_size = 4
	credit.color = GOLD
	credit.align = HORIZONTAL_ALIGNMENT_CENTER
	credit.width = 1280.0
	credit.position = Vector2(0, 452)
	add_child(credit)

	# The single entry card. Gold fill + dark ink (same pairing as
	# the map's gold buttons), centred, big enough to tap.
	var play := TTHUD.IconButton.new()
	play.name = "PlayButton"
	play.text = "1 PLAYER"
	play.font_size = 34
	play.fill = GOLD
	play.icon_col = DARK_INK
	play.corner_radius = 14
	play.position = Vector2(440, 520)
	play.size = Vector2(400, 72)
	play.pressed.connect(_on_play_pressed)
	add_child(play)

	var hint := TTPixelLabel.new()
	hint.name = "Hint"
	hint.text = "TAP 1 PLAYER TO PLAY"
	hint.pixel_size = 3
	hint.color = Color(1, 1, 1, 0.75)
	hint.align = HORIZONTAL_ALIGNMENT_CENTER
	hint.width = 1280.0
	hint.position = Vector2(0, 612)
	add_child(hint)


func _input(event: InputEvent) -> void:
	if _transitioned:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER or key.keycode == KEY_SPACE:
			_on_play_pressed()


func _on_play_pressed() -> void:
	if _transitioned:
		return
	_transitioned = true
	get_tree().change_scene_to_file(MAP_SCENE)
