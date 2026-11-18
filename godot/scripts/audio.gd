class_name TTAudio
extends RefCounted

# Honest audio: runtime-generated AudioStreamWAV PCM tones only, zero
# binary assets. Death blip (descending sine), win blip (ascending
# sine), short procedural music loop (sine arpeggio, looped).
# Settings live in user://settings.cfg (sound toggle = Master-bus mute,
# music volume = music player volume_db) and are applied at startup.
# The music/SFX players are children of the SceneTree root, which
# persists across scene changes, so music keeps playing from map to
# game and across pause. ensure_audio() is idempotent and called from
# map _ready and game _ready; if a player already exists in the tree
# it is reused, never restarted. No autoload is used.
# Settings are folded into this file (no separate settings.gd).

const SETTINGS_PATH := "user://settings.cfg"
const MIX_RATE := 22050

static var _tree: SceneTree = null
static var _music_player: AudioStreamPlayer = null
static var _sfx_player: AudioStreamPlayer = null
static var _death_stream: AudioStreamWAV = null
static var _win_stream: AudioStreamWAV = null
static var _music_stream: AudioStreamWAV = null
static var _sound_enabled := true
static var _music_volume := 0.6
static var _settings_loaded := false
static var _music_queued := false
static var _sfx_queued := false
static var _sfx_play_queued := false


static func ensure_audio(tree: SceneTree) -> void:
	_tree = tree
	if not _settings_loaded:
		load_settings()
	_ensure_players()
	_apply_settings()


static func load_settings() -> void:
	_sound_enabled = true
	_music_volume = 0.6
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		_sound_enabled = bool(cfg.get_value("audio", "sound_enabled", true))
		_music_volume = clampf(float(cfg.get_value("audio", "music_volume", 0.6)), 0.0, 1.0)
	_settings_loaded = true


static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "sound_enabled", _sound_enabled)
	cfg.set_value("audio", "music_volume", _music_volume)
	cfg.save(SETTINGS_PATH)
	_settings_loaded = true


static func set_sound_enabled(enabled: bool) -> void:
	_sound_enabled = enabled
	_apply_settings()
	save_settings()


static func is_sound_enabled() -> bool:
	if not _settings_loaded:
		load_settings()
	return _sound_enabled


static func set_music_volume(volume: float) -> void:
	_music_volume = clampf(volume, 0.0, 1.0)
	_apply_settings()
	save_settings()


static func get_music_volume() -> float:
	if not _settings_loaded:
		load_settings()
	return _music_volume


static func play_death() -> void:
	_play(_death_tone())


static func play_win() -> void:
	_play(_win_tone())


static func _apply_settings() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus >= 0:
		AudioServer.set_bus_mute(bus, not _sound_enabled)
	if is_instance_valid(_music_player):
		_music_player.volume_db = _vol_db(_music_volume)


static func _vol_db(volume: float) -> float:
	if volume <= 0.001:
		return -60.0
	return linear_to_db(volume)


static func _ensure_players() -> void:
	if _tree == null:
		return
	var root := _tree.root
	if root == null:
		return
	# Players are added DEFERRED: ensure_audio runs from scene _ready,
	# while the tree is still setting up children, and a direct
	# add_child to root fails there ("Parent node is busy"). Deferred
	# add + play run in queue order at idle, so the player is in the
	# tree before play() runs. The stream is set once at creation and
	# never touched again, so music is never restarted by a later
	# ensure_audio call and keeps playing across scene changes.
	if not is_instance_valid(_music_player):
		_music_player = AudioStreamPlayer.new()
		_music_player.name = "TTMusic"
		_music_player.process_mode = Node.PROCESS_MODE_ALWAYS
		_music_player.stream = _music_tone()
		_music_player.volume_db = _vol_db(_music_volume)
		_music_queued = true
		root.add_child.call_deferred(_music_player)
		_music_player.play.call_deferred()
	elif _music_player.is_inside_tree():
		_music_player.volume_db = _vol_db(_music_volume)
		if not _music_player.playing:
			_music_player.play()
	elif not _music_queued:
		_music_player.volume_db = _vol_db(_music_volume)
		_music_queued = true
		root.add_child.call_deferred(_music_player)
		_music_player.play.call_deferred()
	if not is_instance_valid(_sfx_player):
		_sfx_player = AudioStreamPlayer.new()
		_sfx_player.name = "TTSFX"
		_sfx_player.process_mode = Node.PROCESS_MODE_ALWAYS
		_sfx_queued = true
		root.add_child.call_deferred(_sfx_player)
	elif not _sfx_player.is_inside_tree() and not _sfx_queued:
		_sfx_queued = true
		root.add_child.call_deferred(_sfx_player)


static func _play(stream: AudioStreamWAV) -> void:
	if not is_instance_valid(_sfx_player):
		_ensure_players()
	if not is_instance_valid(_sfx_player):
		return
	_sfx_player.stream = stream
	if _sfx_player.is_inside_tree():
		_sfx_player.play()
	elif not _sfx_play_queued:
		_sfx_play_queued = true
		_sfx_player.play.call_deferred()


static func _death_tone() -> AudioStreamWAV:
	if _death_stream == null:
		_death_stream = _make_sweep(0.18, 700.0, 160.0, 0.5)
	return _death_stream


static func _win_tone() -> AudioStreamWAV:
	if _win_stream == null:
		_win_stream = _make_sweep(0.28, 520.0, 1040.0, 0.5)
	return _win_stream


static func _music_tone() -> AudioStreamWAV:
	if _music_stream == null:
		_music_stream = _make_music()
	return _music_stream


# One sine sweep with attack + decay envelope. 8-bit PCM, unsigned
# samples centred on 128.
static func _make_sweep(dur: float, freq_from: float, freq_to: float, amp: float) -> AudioStreamWAV:
	var n := int(dur * float(MIX_RATE))
	var data := PackedByteArray()
	data.resize(n)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / float(MIX_RATE)
		var frac := t / dur
		var freq := lerpf(freq_from, freq_to, frac)
		phase += TAU * freq / float(MIX_RATE)
		var attack := smoothstep(0.0, 0.008, t)
		var env := attack * (1.0 - frac)
		var s := sin(phase) * amp * env
		data[i] = clampi(128 + int(127.0 * s), 0, 255)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	return stream


# Gentle 2-second sine arpeggio (A4 - C#5 - E5 - C#5), 0.5s per note,
# each note faded in/out so the loop point is click-free.
static func _make_music() -> AudioStreamWAV:
	var notes: Array[float] = [440.0, 554.37, 659.26, 554.37]
	var note_dur := 0.5
	var total_dur := note_dur * float(notes.size())
	var n := int(total_dur * float(MIX_RATE))
	var data := PackedByteArray()
	data.resize(n)
	for i in range(n):
		var t := float(i) / float(MIX_RATE)
		var idx := clampi(int(t / note_dur), 0, notes.size() - 1)
		var local := fmod(t, note_dur)
		var env := smoothstep(0.0, 0.04, local) * (1.0 - smoothstep(note_dur - 0.04, note_dur, local))
		var s := sin(TAU * notes[idx] * local) * 0.32 * env
		data[i] = clampi(128 + int(127.0 * s), 0, 255)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = n
	return stream
