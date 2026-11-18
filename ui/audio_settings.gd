## 可在场景编辑的声音设置；只调用音频接口，不推进冒险。
class_name AudioSettings
extends CanvasLayer

## 此设置窗口控制的驻留音频服务。
var audio:GameAudioManager
## 负责设置窗口模态登记和输入阻挡的应用浮层服务。
var overlay_host:OverlayHost
@onready var overlay:Control = %sound_overlay
@onready var opener:Button = %sound_button
@onready var close_button:Button = %close_sound_settings
@onready var music_volume:HSlider = %music_volume
@onready var sfx_volume:HSlider = %sfx_volume
@onready var music_mute:CheckButton = %music_mute
@onready var sfx_mute:CheckButton = %sfx_mute
@onready var master_mute:CheckButton = %master_mute

## 绑定声音设置控制的音频服务及登记模态窗口的共享浮层服务。
func configure_services(audio_service:GameAudioManager, host:OverlayHost)->void:
	audio = audio_service
	overlay_host = host

## 设置应用级显示层并连接控件；没有音频服务时禁用设置入口。
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

## 读取音频服务当前设置并无信号地更新控件，避免同步显示时反向触发设置操作。
func _sync_values()->void:
	music_volume.set_value_no_signal(audio.music_volume)
	sfx_volume.set_value_no_signal(audio.sfx_volume)
	music_mute.set_pressed_no_signal(audio.music_muted)
	sfx_mute.set_pressed_no_signal(audio.sfx_muted)
	master_mute.set_pressed_no_signal(audio.master_muted)

## 同步并显示声音设置，登记模态阻挡并将焦点移到关闭按钮；已打开或没有音频服务时忽略。
func _open()->void:
	if overlay.visible or audio == null:
		return
	_sync_values()
	overlay.show()
	if overlay_host != null:
		overlay_host.register_modal(overlay, self, _close)
	audio.play_sfx(&"ui_confirm")
	close_button.grab_focus()

## 隐藏已打开的设置，取消模态登记并把焦点还给入口按钮。
func _close()->void:
	if not overlay.visible:
		return
	overlay.hide()
	if overlay_host != null:
		overlay_host.unregister_modal(overlay)
	audio.play_sfx(&"ui_confirm")
	opener.grab_focus()
