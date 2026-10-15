## 正常退出先清理驻留音频与输入；重复请求和迟到播放不能重新激活服务。
extends SceneTree

var failures:int = 0

func _initialize()->void:
	_run.call_deferred()

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1
		push_error(message)

func _run()->void:
	var main:Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	var flow:GameFlowController = main.get_node("game_flow_controller")
	var audio:GameAudioManager = main.get_node("audio_manager")
	var settings:AudioSettings = main.get_node("sound_controls")
	var players:Array[AudioStreamPlayer] = []
	for player:AudioStreamPlayer in audio._music.values():
		players.append(player)
	expect(not auto_accept_quit and audio.current_music_state == &"exploration", "应用接管窗口关闭，并已启动真实驻留音乐")
	expect(audio.play_sfx(&"strike_hit", "shutdown:test"), "退出前声音服务能够播放")
	for index:int in range(GameAudioManager.VOICE_COUNT - 1):
		expect(audio.play_sfx(&"strike_hit", "shutdown:fill:%d" % index), "声池中的每条播放实例都被登记")
	expect(audio.play_sfx(&"victory", "shutdown:replace"), "高优先级声音替换旧播放，退出仍须回收旧实例")
	audio.set_music_state(&"combat")
	audio.set_music_state(&"exploration")
	settings.opener.pressed.emit()
	var page:Control = flow.current_page
	var generation:int = flow.router.generation
	expect(main.prepare_shutdown(), "首次退出准备被接受")
	expect(not main.prepare_shutdown(), "重复退出准备只执行一次")
	expect(audio._shutdown and not audio.is_processing() and audio.current_music_state == &"silence", "退出后停止音乐状态和逐帧混音调整")
	for player:AudioStreamPlayer in players:
		expect(not player.playing and player.stream == null, "退出准备立即释放每条实际音乐播放源")
	for voice:AudioStreamPlayer in audio._voices:
		expect(not voice.playing and voice.stream == null, "退出准备立即释放每条实际短声源")
	expect(audio._music.is_empty() and audio._streams.is_empty() and audio._duck_requests.is_empty(), "播放源与压低请求在引擎退出前清理")
	expect(not audio.play_sfx(&"victory", "shutdown:late"), "迟到音效不能重新激活退出后的服务")
	audio.set_music_state(&"combat")
	expect(audio.current_music_state == &"silence", "迟到音乐切换不能重新激活播放器")
	expect(not page.can_process() and not settings.can_process() and root.gui_disable_input, "退出准备关闭页面、设置与视口输入")
	expect(flow.current_page == page and flow.router.generation == generation and flow.run_state == null, "退出清理不重新切页或创建冒险")
	audio.shutdown()
	expect(await audio.wait_for_shutdown(), "退出等待覆盖混音线程持有的播放实例，直到实际释放")
	expect(audio.shutdown_complete() and audio._active_playbacks.is_empty(), "实际播放对象释放后可重复查询完成")
	main.queue_free()
	await process_frame
	await process_frame
	print("应用退出生命周期检查完成，失败数：%d" % failures)
	quit(0 if failures == 0 else 1)
