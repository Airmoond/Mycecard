## 声音资产、淡化/静音/去重与实际效果采集；检查复合效果不能被净变化覆盖。
extends SceneTree

var failures:int = 0

func _initialize()->void:
	_run.call_deferred()

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1
		push_error(message)

func _run()->void:
	var manager:GameAudioManager = GameAudioManager.new()
	root.add_child(manager)
	for id:StringName in GameAudioManager.SFX_IDS:
		var stream:AudioStream = load("res://audio/sfx/%s.wav" % id)
		expect(stream != null and stream.get_length() > 0.06, "每条正式短声应具备可播放时长：%s" % id)
	for id:StringName in [&"exploration", &"combat"]:
		var stream:AudioStreamOggVorbis = manager._music[id].stream
		expect(stream.loop and stream.get_length() > 60.0, "两首实际OGG应支持完整循环：%s" % id)
		expect(absf(stream.get_length() - 68.5714375) < 0.005, "Godot循环长度应按EOS取完整乐句，排除解码尾包填充：%s" % id)
	manager.set_music_state(&"exploration")
	manager._process(0.8)
	var player:AudioStreamPlayer = manager._music[&"exploration"]
	var position:float = player.get_playback_position()
	manager.set_music_state(&"exploration")
	expect(manager._fade_elapsed == 0.8 and player.get_playback_position() >= position, "同状态不重启音乐或淡化")
	manager.set_music_state(&"combat")
	manager._process(0.15)
	manager.set_music_state(&"exploration")
	manager._process(0.1)
	manager.set_music_state(&"combat")
	manager._process(0.8)
	expect(manager.current_music_state == &"combat" and not player.playing, "快速切换只保留最后有效音乐")
	expect(is_equal_approx(float(manager._gains[&"combat"]), 1.0), "最终音乐应淡入到真实设定音量")
	manager.set_music_muted(true)
	expect(AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")), "音乐静音应关闭音乐总线")
	expect(manager.play_sfx(&"strike_hit", "test:hit"), "音乐静音时音效仍可实际播放")
	expect(not manager.play_sfx(&"strike_hit", "test:hit"), "同一真实结果重复回调不能再次播放")
	expect(manager.play_sfx(&"strike_hit", "test:hit:second"), "不同伤害段不能按声音类型误删")
	manager._process(0.06)
	expect(is_equal_approx(manager._duck_gain, db_to_linear(-4.0)), "命中压低按60ms到达目标增益")
	expect(manager.play_sfx(&"block_hit", "test:block:separate"), "不同结果的格挡命中仍可发声")
	manager._process(0.06)
	expect(is_equal_approx(manager._duck_gain, db_to_linear(-4.0)), "相同强度多个请求不累计将音乐越压越低")
	manager.set_sfx_muted(true)
	expect(not manager.play_sfx(&"card_play", "test:muted") and manager._duck_requests.is_empty(), "音效静音不发成功声或压低音乐")
	manager.set_sfx_muted(false)
	manager.set_music_muted(false)
	manager.set_master_muted(true)
	manager._process(1.0)
	expect(AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")) and AudioServer.is_bus_mute(AudioServer.get_bus_index("SFX")), "淡化之后总静音仍覆盖两条总线")
	manager.set_master_muted(false)
	manager.set_music_volume(0.0)
	manager.set_sfx_volume(0.0)
	expect(manager.music_volume == 0.0 and manager.sfx_volume == 0.0, "音量可独立降到零")
	await _test_mix_headroom(manager)
	_test_actual_results()
	await _test_scaled_afterimage()
	await _test_battle_lifecycle(manager)
	manager.queue_free()
	await process_frame
	await create_timer(0.5).timeout
	print("第六阶段音频与表现检查完成，失败数：%d" % failures)
	quit(0 if failures == 0 else 1)

func _test_mix_headroom(manager:GameAudioManager)->void:
	var capture:AudioEffectCapture = AudioEffectCapture.new()
	capture.buffer_length = 0.5
	AudioServer.add_bus_effect(0, capture)
	manager.set_music_volume(1.0)
	manager.set_sfx_volume(1.0)
	for voice:AudioStreamPlayer in manager._voices: voice.stop()
	for index:int in range(GameAudioManager.VOICE_COUNT):
		expect(manager.play_sfx(&"strike_hit", "burst:%d" % index), "真实不同命中可以占用音效池")
	expect(not manager.play_sfx(&"ui_confirm", "burst:low"), "池满时低优先级UI不能挤掉真实命中")
	expect(manager.play_sfx(&"victory", "burst:victory"), "池满时胜利提示应抢占低优先级声部")
	await create_timer(0.35).timeout
	var samples:PackedVector2Array = capture.get_buffer(capture.get_frames_available())
	var peak:float = 0.0
	for sample:Vector2 in samples: peak = maxf(peak, maxf(absf(sample.x), absf(sample.y)))
	expect(not samples.is_empty() and peak > 0.05, "检查必须采集实际混音输出，不能把静音当作无削波")
	expect(peak <= db_to_linear(-1.0) + 0.001, "满音量八声叠加与BGM仍应受真实-1dB输出上限约束")
	print("实际混音叠加峰值：%.6f" % peak)
	for index:int in range(AudioServer.get_bus_effect_count(0) - 1, -1, -1):
		if AudioServer.get_bus_effect(0, index) == capture: AudioServer.remove_bus_effect(0, index)
	for voice:AudioStreamPlayer in manager._voices: voice.stop()
	manager.set_music_volume(0.0)
	manager.set_sfx_volume(0.0)
	await create_timer(0.15).timeout

func _test_actual_results()->void:
	var attacker:CombatantState = CombatantState.new()
	attacker.combatant_init("玩家", 50)
	attacker.current_health = 40
	var target:CombatantState = CombatantState.new()
	target.combatant_init("敌人", 30)
	target.current_block = 4
	var results:Array[StringName] = []
	target.presentation_result.connect(func(kind:StringName, _amount:int)->void: results.append(kind))
	attacker.presentation_result.connect(func(kind:StringName, _amount:int)->void: results.append(kind))
	var effect:CombatEffectDefinition = CombatEffectDefinition.new()
	effect.amount = 10
	effect.heals_from_damage = true
	AttackDamageResolver.apply_effect(attacker, target, effect)
	expect(results == [&"block_hit", &"strike_hit", &"heal_gain"], "同一效果真实吸盾、扣血、按伤治疗各自采集")
	expect(target.current_health == 24 and attacker.current_health == 46, "表现信号不改变既有实际治疗规则")
	results.clear()
	target.current_block = 20
	target.take_damage(5)
	expect(results == [&"block_hit"], "全额格挡不伪造生命命中")
	results.clear()
	attacker.current_health = 50
	attacker.heal(15)
	expect(results.is_empty(), "满血治疗不出现收益声和虚假治疗浮字")
	attacker.current_health = 1
	var queue:ActionQueue = ActionQueue.new()
	queue.queue_lose_health(attacker, 2)
	queue.queue_block(attacker, 10)
	queue.resolve_all()
	expect(results == [&"health_loss"] and attacker.current_block == 0, "回合开始致死后的格挡不产生反馈")
	var state:BattleState = BattleState.new()
	state.current_available_energy = 2
	var energy:Array[int] = []
	state.presentation_result.connect(func(kind:StringName, amount:int)->void:
		if kind == &"energy": energy.append(amount))
	state.spend_energy(1)
	state.gain_energy(1)
	expect(energy == [-1, 1] and state.current_available_energy == 2, "扣费与回能分别采集，净零变化不隐藏实际支付")

func _test_scaled_afterimage()->void:
	# 1600设计画布在1280窗口中的0.8缩放；卡牌本地尺寸仍180×252。
	var holder:Control = Control.new()
	root.add_child(holder)
	holder.scale = Vector2(0.8, 0.8)
	var card:CardView = load("res://cards/card_view.tscn").instantiate()
	holder.add_child(card)
	var instance:CardInstance = CardInstance.new()
	instance.card_instance_init(load("res://cards/data/strike.tres"))
	card.bind_card_instance(instance)
	var presenter:BattlePresentation = BattlePresentation.new()
	root.add_child(presenter)
	var source_rect:Rect2 = card.get_global_rect()
	expect(source_rect.size.is_equal_approx(Vector2(144, 201.6)), "1280缩放条件应生成小于原生最小尺寸的全局矩形")
	var snapshot:CardFace = card.make_play_snapshot() as CardFace
	var original_art_size:Vector2 = card.card_face.artwork.size
	presenter.animate_card(snapshot, source_rect, Rect2(500, 120, 144, 201.6))
	expect(snapshot.custom_minimum_size.is_equal_approx(source_rect.size) and snapshot.size.is_equal_approx(source_rect.size), "出牌快照必须同步缩放后的最小尺寸，不能膨胀回180×252")
	expect(snapshot.get_global_rect().size.is_equal_approx(source_rect.size), "独立残影挂载到覆盖层后的实际占位应与原卡全局尺寸相等")
	expect(snapshot.artwork.size.is_equal_approx(original_art_size * 0.8), "残影原画与内层布局同步缩小，不能只改外层占位")
	holder.queue_free()
	await process_frame
	expect(is_instance_valid(snapshot), "手牌释放后独立残影仍可完成装饰动作")
	await create_timer(0.3).timeout
	expect(not is_instance_valid(snapshot), "出牌残影完成后应清理，不能留在新界面")
	presenter.present_result(&"block_gain", 7, Rect2(300, 100, 160, 180))
	var previous_session:String = presenter.session_id
	presenter.begin_session()
	expect(presenter.session_id != previous_session and presenter._surface.get_child_count() == 0 and presenter.observed_results.is_empty(), "重用战斗控制器时上一场浮字、闪光与会话记录同步清理")
	presenter.queue_free()
	await process_frame

func _test_battle_lifecycle(manager:GameAudioManager)->void:
	var host:OverlayHost = OverlayHost.new()
	root.add_child(host)
	var page:Control = load("res://battle/battle.tscn").instantiate()
	root.add_child(page)
	var controller:BattleController = page.get_node("battle_controller")
	controller.configure_services(manager, host)
	var encounter:EncounterDefinition = load("res://battle/data/encounters/cave_crawler_encounter.tres").duplicate()
	encounter.enemy_definition = encounter.enemy_definition.duplicate()
	encounter.enemy_definition.max_health = 1
	var strike:CardDefinition = load("res://cards/data/strike.tres")
	var deck:Array[CardDefinition] = [strike, strike, strike]
	expect(controller.start_battle(encounter, load("res://combatants/data/player.tres"), deck, 50, 50), "反馈生命周期场景应正常启动")
	await process_frame
	var count:int = manager.accepted_sfx.size()
	controller.battle_finished.connect(func(_win:bool, _hp:int, _maximum:int)->void: page.queue_free())
	controller._on_card_selected(controller.battle_state.hand[0])
	expect(controller.battle_state.current_phase == BattleState.BattlePhase.FINISHED, "致死同步完成不等待残影或音效")
	var ids:Array[StringName] = []
	for event:Dictionary in manager.accepted_sfx.slice(count): ids.append(event["id"])
	expect(ids.has(&"card_play") and ids.has(&"strike_hit") and ids.has(&"victory"), "切页前已把出牌、实际命中、一次胜利交给驻留音频")
	var toast:Control = host._toast
	expect(toast != null and toast.position.x == 18 and toast.position.y >= root.get_visible_rect().size.y - 62 and toast.size.x <= 210, "终局铜框短提示停留在左下角，不覆盖新页面中央标题和故事")
	controller._check_battle_result()
	var after:int = manager.accepted_sfx.size()
	controller._check_battle_result()
	expect(manager.accepted_sfx.size() == after, "重复胜负检查不重复播放胜利")
	await process_frame
	expect(not is_instance_valid(page), "旧战斗页面可立即释放，独立声音管理器继续存在")
	expect(is_instance_valid(manager), "驻留管理器不归旧战斗场景所有")
	expect(is_instance_valid(host) and is_instance_valid(toast), "跨页提示归应用浮层所有，不归声音节点或战斗页面")
	host.queue_free()
	await process_frame
