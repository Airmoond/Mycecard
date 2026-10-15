## 页面容器外的驻留音乐与短音效管理器；播放、混音和静音从不推进游戏规则。
class_name GameAudioManager
extends Node

signal sfx_accepted(sound_id:StringName, event_id:String)
signal music_changed(state:StringName)

const SFX_IDS:Array[StringName] = [&"ui_confirm", &"ui_invalid", &"card_play", &"strike_hit", &"block_gain", &"block_hit", &"weapon_break", &"heal_gain", &"end_turn", &"victory", &"defeat"]
const CROSSFADE_SECONDS:float = 0.8
const VOICE_COUNT:int = 8

var music_volume:float = 0.65
var sfx_volume:float = 0.80
var music_muted:bool = false
var sfx_muted:bool = false
var master_muted:bool = false
var current_music_state:StringName = &"silence"
## 保留有限的真实播放记录，便于检查重复回调与实际结果触发。
var accepted_sfx:Array[Dictionary] = []
var _music:Dictionary = {}
var _streams:Dictionary = {}
var _voices:Array[AudioStreamPlayer] = []
var _priorities:Array[int] = []
var _voice_ids:Array[StringName] = []
var _gains:Dictionary = {&"exploration":0.0, &"combat":0.0}
var _from_gains:Dictionary = {&"exploration":0.0, &"combat":0.0}
var _targets:Dictionary = {&"exploration":0.0, &"combat":0.0}
var _positions:Dictionary = {&"exploration":0.0, &"combat":0.0}
var _fade_elapsed:float = CROSSFADE_SECONDS
var _seen_events:Dictionary = {}
var _duck_requests:Array[Dictionary] = []
var _duck_gain:float = 1.0
var _duck_target_gain:float = 1.0
var _duck_from_gain:float = 1.0
var _duck_elapsed:float = 0.30
var _last_invalid_ms:int = -1000
var _master_limiter:AudioEffectHardLimiter
var _shutdown:bool = false
var _active_playbacks:Array[WeakRef] = []

func _ready()->void:
	if _shutdown:
		return
	add_to_group("game_audio")
	# 全池叠加仍保持输出余量；只添加本管理器拥有的限制器，保留项目已有效果。
	var has_limiter:bool = false
	for index:int in range(AudioServer.get_bus_effect_count(0)):
		if AudioServer.get_bus_effect(0, index) is AudioEffectHardLimiter:
			has_limiter = true
	if not has_limiter:
		_master_limiter = AudioEffectHardLimiter.new()
		_master_limiter.ceiling_db = -1.0
		_master_limiter.release = 0.10
		AudioServer.add_bus_effect(0, _master_limiter)
	for bus_name:String in ["Music", "SFX"]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)
			AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")
	for state:StringName in [&"exploration", &"combat"]:
		var player:AudioStreamPlayer = AudioStreamPlayer.new()
		player.name = "music_" + String(state)
		player.bus = &"Music"
		var stream:AudioStreamOggVorbis = load("res://audio/music/%s.ogg" % state).duplicate() as AudioStreamOggVorbis
		stream.loop = true
		player.stream = stream
		add_child(player)
		_music[state] = player
	for sound_id:StringName in SFX_IDS:
		_streams[sound_id] = load("res://audio/sfx/%s.wav" % sound_id)
	for index:int in range(VOICE_COUNT):
		var voice:AudioStreamPlayer = AudioStreamPlayer.new()
		voice.name = "short_sound_%d" % index
		voice.bus = &"SFX"
		add_child(voice)
		_voices.append(voice)
		_priorities.append(-1)
		_voice_ids.append(&"")
	_apply_mutes()
	_update_volumes()

## 同状态请求保持播放位置；快速切换以当前增益开始新的淡化，没有过期回调。
func set_music_state(state:StringName)->void:
	if _shutdown or state not in [&"exploration", &"combat", &"silence"] or state == current_music_state:
		return
	current_music_state = state
	_from_gains = _gains.duplicate()
	_fade_elapsed = 0.0
	for track:StringName in [&"exploration", &"combat"]:
		_targets[track] = 1.0 if track == state else 0.0
		var player:AudioStreamPlayer = _music.get(track)
		if track == state and player != null and not player.playing:
			player.play(float(_positions[track]))
			_track_playback(player)
	music_changed.emit(state)

## event_id标识同一来源的一个真实结果；不同伤害段使用不同标识，不按音效名去重。
func play_sfx(sound_id:StringName, event_id:String = "", priority:int = -1)->bool:
	if _shutdown or not _streams.has(sound_id) or sfx_muted or master_muted:
		return false
	if not event_id.is_empty() and _seen_events.has(event_id):
		return false
	if sound_id == &"ui_invalid":
		var now_ms:int = Time.get_ticks_msec()
		if now_ms - _last_invalid_ms < 250:
			return false
		_last_invalid_ms = now_ms
	var incoming_priority:int = _priority(sound_id) if priority < 0 else priority
	var ui_count:int = 0
	var slot:int = -1
	var lowest_priority:int = 100
	var lowest_slot:int = -1
	for index:int in range(_voices.size()):
		if not _voices[index].playing:
			if slot < 0:
				slot = index
		else:
			if String(_voice_ids[index]).begins_with("ui_"):
				ui_count += 1
			if _priorities[index] < lowest_priority:
				lowest_priority = _priorities[index]
				lowest_slot = index
	if String(sound_id).begins_with("ui_") and ui_count >= 2:
		return false
	if slot < 0:
		if incoming_priority <= lowest_priority:
			return false
		slot = lowest_slot
	_voices[slot].stop()
	_voices[slot].stream = _streams[sound_id]
	_voices[slot].volume_db = -4.0 if sound_id == &"block_hit" else -3.0 if String(sound_id).begins_with("ui_") else 0.0
	_priorities[slot] = incoming_priority
	_voice_ids[slot] = sound_id
	_voices[slot].play()
	_track_playback(_voices[slot])
	if not event_id.is_empty():
		_seen_events[event_id] = true
		if _seen_events.size() > 2048:
			_seen_events.erase(_seen_events.keys()[0])
	accepted_sfx.append({"id":sound_id, "event_id":event_id})
	if accepted_sfx.size() > 128:
		accepted_sfx.pop_front()
	if incoming_priority >= 3:
		_duck_requests.append({"seconds":float(_voices[slot].stream.get_length()) + 0.12,
			"gain":db_to_linear(-8.0 if incoming_priority >= 4 else -4.0)})
	sfx_accepted.emit(sound_id, event_id)
	return true

func _priority(sound_id:StringName)->int:
	if sound_id in [&"victory", &"defeat"]:
		return 4
	if sound_id in [&"strike_hit", &"block_hit", &"weapon_break"]:
		return 3
	return 0 if String(sound_id).begins_with("ui_") else 2

func _process(delta:float)->void:
	_fade_elapsed = minf(CROSSFADE_SECONDS, _fade_elapsed + delta)
	var progress:float = _fade_elapsed / CROSSFADE_SECONDS
	for track:StringName in [&"exploration", &"combat"]:
		_gains[track] = lerpf(float(_from_gains[track]), float(_targets[track]), progress)
		var player:AudioStreamPlayer = _music.get(track)
		if player != null and player.playing and progress >= 1.0 and float(_targets[track]) == 0.0:
			_positions[track] = fmod(player.get_playback_position(), maxf(0.01, player.stream.get_length()))
			player.stop()
	var target_duck:float = 1.0
	for index:int in range(_duck_requests.size() - 1, -1, -1):
		_duck_requests[index]["seconds"] = float(_duck_requests[index]["seconds"]) - delta
		if float(_duck_requests[index]["seconds"]) <= 0.0:
			_duck_requests.remove_at(index)
		else:
			target_duck = minf(target_duck, float(_duck_requests[index]["gain"]))
	if sfx_muted or master_muted:
		target_duck = 1.0
	if not is_equal_approx(target_duck, _duck_target_gain):
		_duck_from_gain = _duck_gain
		_duck_target_gain = target_duck
		_duck_elapsed = 0.0
	var duck_seconds:float = 0.06 if _duck_target_gain < _duck_from_gain else 0.30
	_duck_elapsed = minf(duck_seconds, _duck_elapsed + delta)
	_duck_gain = lerpf(_duck_from_gain, _duck_target_gain, _duck_elapsed / duck_seconds)
	_update_volumes()

func _update_volumes()->void:
	for track:StringName in _music:
		var player:AudioStreamPlayer = _music[track]
		player.volume_db = linear_to_db(maxf(0.00001, float(_gains[track]) * _duck_gain * music_volume))
	var index:int = AudioServer.get_bus_index("SFX")
	if index >= 0:
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(0.00001, sfx_volume)))

func _apply_mutes()->void:
	for pair:Array in [["Music", music_muted or master_muted], ["SFX", sfx_muted or master_muted]]:
		var index:int = AudioServer.get_bus_index(pair[0])
		if index >= 0:
			AudioServer.set_bus_mute(index, pair[1])

func set_music_volume(value:float)->void:
	music_volume = clampf(value, 0.0, 1.0)
	_update_volumes()

func set_sfx_volume(value:float)->void:
	sfx_volume = clampf(value, 0.0, 1.0)
	_update_volumes()

func set_music_muted(value:bool)->void:
	music_muted = value
	_apply_mutes()

func set_sfx_muted(value:bool)->void:
	sfx_muted = value
	if value:
		_clear_duck()
	_apply_mutes()

func set_master_muted(value:bool)->void:
	master_muted = value
	if value:
		_clear_duck()
	_apply_mutes()

func _clear_duck()->void:
	_duck_requests.clear()
	_duck_gain = 1.0
	_duck_target_gain = 1.0
	_duck_from_gain = 1.0
	_duck_elapsed = 0.30

## stop() 后引擎仍可能持有播放实例；弱引用也覆盖声池换用时尚未释放的旧实例。
func _track_playback(player:AudioStreamPlayer)->void:
	for index:int in range(_active_playbacks.size() - 1, -1, -1):
		if _active_playbacks[index].get_ref() == null:
			_active_playbacks.remove_at(index)
	if player.has_stream_playback():
		_active_playbacks.append(weakref(player.get_stream_playback()))

func shutdown_complete()->bool:
	if not _shutdown:
		return false
	for playback:WeakRef in _active_playbacks:
		if playback.get_ref() != null:
			return false
	_active_playbacks.clear()
	return true

## 继续推进主线程和混音线程，直到实际播放对象释放；超时由调用方报告并结束退出。
func wait_for_shutdown(timeout_seconds:float = 5.0)->bool:
	var deadline:int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while not shutdown_complete():
		if Time.get_ticks_msec() >= deadline:
			return false
		await get_tree().process_frame
	return true

## 退出准备先停止并释放播放源，让混音线程在引擎结束前完成异步清理。
func shutdown()->void:
	if _shutdown:
		return
	_shutdown = true
	set_process(false)
	current_music_state = &"silence"
	_clear_duck()
	for player:AudioStreamPlayer in _music.values():
		player.stop()
		player.stream = null
	for voice:AudioStreamPlayer in _voices:
		voice.stop()
		voice.stream = null
	_streams.clear()
	_music.clear()
	if _master_limiter != null:
		for index:int in range(AudioServer.get_bus_effect_count(0) - 1, -1, -1):
			if AudioServer.get_bus_effect(0, index) == _master_limiter:
				AudioServer.remove_bus_effect(0, index)
		_master_limiter = null

func _exit_tree()->void:
	shutdown()
