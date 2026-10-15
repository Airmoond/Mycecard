## 可在场景编辑的声音设置；只调用音频接口，不推进冒险。
class_name AudioSettings
extends CanvasLayer

var audio:GameAudioManager
var overlay_host:OverlayHost
@onready var overlay:Control = %sound_overlay
@onready var opener:Button = %sound_button
@onready var close_button:Button = %close_sound_settings
@onready var music_volume:HSlider = %music_volume
@onready var sfx_volume:HSlider = %sfx_volume
@onready var music_mute:CheckButton = %music_mute
@onready var sfx_mute:CheckButton = %sfx_mute
@onready var master_mute:CheckButton = %master_mute

func configure_services(audio_service:GameAudioManager, host:OverlayHost)->void:
	audio = audio_service
	overlay_host = host

func _ready()->void:
	layer = OverlayHost.LAYER_SETTINGS
	opener.pressed.connect(_open)
	close_button.pressed.connect(_close)
	if audio == null:
		opener.disabled = true
		return
	music_volume.value_changed.connect(audio.set_music_volume)
	sfx_volume.value_changed.connect(audio.set_sfx_volume)
	music_mute.toggled.connect(audio.set_music_muted)
	sfx_mute.toggled.connect(audio.set_sfx_muted)
	master_mute.toggled.connect(audio.set_master_muted)
	_sync_values()

func _sync_values()->void:
	music_volume.set_value_no_signal(audio.music_volume)
	sfx_volume.set_value_no_signal(audio.sfx_volume)
	music_mute.set_pressed_no_signal(audio.music_muted)
	sfx_mute.set_pressed_no_signal(audio.sfx_muted)
	master_mute.set_pressed_no_signal(audio.master_muted)

func _open()->void:
	if overlay.visible or audio == null:
		return
	_sync_values()
	overlay.show()
	if overlay_host != null:
		overlay_host.register_modal(overlay, self, _close)
	audio.play_sfx(&"ui_confirm")
	close_button.grab_focus()

func _close()->void:
	if not overlay.visible:
		return
	overlay.hide()
	if overlay_host != null:
		overlay_host.unregister_modal(overlay)
	audio.play_sfx(&"ui_confirm")
	opener.grab_focus()
