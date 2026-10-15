## 应用装配：驻留主题、声音、浮层；业务状态由流程会话持有。
extends Node

const AUDIO_SETTINGS_SCENE:PackedScene = preload("res://ui/audio_settings.tscn")
const SMOKE_ARGUMENT:String = "--smoke-quit-after-frames="
var _closing:bool = false

func _enter_tree()->void:
	$page_container.theme = FantasyTheme.build_theme()

func _ready()->void:
	get_tree().auto_accept_quit = false
	var settings:AudioSettings = AUDIO_SETTINGS_SCENE.instantiate()
	settings.name = "sound_controls"
	settings.configure_services($audio_manager, $overlay_host)
	add_child(settings)
	for argument:String in OS.get_cmdline_user_args():
		if argument.begins_with(SMOKE_ARGUMENT):
			var frames:int = clampi(argument.trim_prefix(SMOKE_ARGUMENT).to_int(), 1, 3600)
			_smoke_exit.call_deferred(frames)
			break

func _notification(what:int)->void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		request_quit()

## 用户关闭窗口与独立启动验收共用正常退出，业务不等待音频或动画结果。
func prepare_shutdown()->bool:
	if _closing:
		return false
	_closing = true
	$page_container.process_mode = Node.PROCESS_MODE_DISABLED
	$overlay_host.process_mode = Node.PROCESS_MODE_DISABLED
	var settings:AudioSettings = get_node_or_null("sound_controls") as AudioSettings
	if settings != null:
		settings.process_mode = Node.PROCESS_MODE_DISABLED
	$overlay_host.clear_transient()
	$audio_manager.shutdown()
	get_window().gui_disable_input = true
	return true

func request_quit()->void:
	if not prepare_shutdown():
		return
	if not await $audio_manager.wait_for_shutdown():
		push_error("Mycecard audio shutdown timed out")
		get_tree().quit(1)
		return
	print("Mycecard orderly shutdown complete")
	get_tree().quit()

func _smoke_exit(frames:int)->void:
	for frame_index in range(frames):
		if _closing:
			return
		await get_tree().process_frame
	request_quit()
