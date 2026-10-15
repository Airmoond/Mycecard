## 应用浮层、输入阻挡、所有权与已提交规则的显示失败恢复。
extends SceneTree

var failures:int = 0

func _initialize()->void:
	_run.call_deferred()

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1
		push_error(message)

func escape(host:OverlayHost)->void:
	var event:InputEventKey = InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.pressed = true
	host._input(event)

func _run()->void:
	await _test_owned_overlays()
	await _test_settings_and_recovery()
	# 音频混音线程在停止播放器后异步释放OGG播放实例。
	await create_timer(0.5).timeout
	print("浮层生命周期与恢复检查完成，失败数：%d" % failures)
	quit(0 if failures == 0 else 1)

func _test_owned_overlays()->void:
	var host:OverlayHost = OverlayHost.new()
	root.add_child(host)
	var owner:Control = Control.new()
	root.add_child(owner)
	var baseline:int = owner.tree_exiting.get_connections().size()
	for index in range(8):
		var preview:Control = Control.new()
		host.attach_hover(preview, owner)
		expect(owner.tree_exiting.get_connections().size() == baseline + 1, "每个悬停仅注册一个所有者退出连接")
		host.release_hover(preview)
		expect(owner.tree_exiting.get_connections().size() == baseline, "反复悬停关闭不累积退出连接")
	await process_frame
	var inspector:CardInspector = load("res://ui/inspect/card_inspector.tscn").instantiate()
	host.attach_page_modal(inspector, owner)
	var cards:Array[CardDefinition] = [load("res://cards/data/strike.tres")]
	expect(inspector.setup_definitions(cards, "测试牌组"), "查看器使用实际卡牌内容")
	expect(host.has_blocking_modal(), "查看器注册阻挡背景输入")
	var blocked_hover:Control = Control.new()
	host.attach_hover(blocked_hover, owner)
	expect(blocked_hover.is_queued_for_deletion() and host._hover_owners.is_empty(), "模态期间不创建可见悬停")
	owner.queue_free()
	await process_frame
	await process_frame
	expect(not is_instance_valid(inspector) and not host.has_blocking_modal() and host._modals.is_empty(), "页面退出时释放宿主中的页面查看器和输入锁")
	host.queue_free()
	await process_frame

func _test_settings_and_recovery()->void:
	var main:Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	var flow:GameFlowController = main.get_node("game_flow_controller")
	flow.run_definition = load("res://tests/fixtures/phase5_run.tres")
	flow.run_seed = 960623
	var host:OverlayHost = main.get_node("overlay_host")
	var settings:AudioSettings = main.get_node("sound_controls")
	var audio:GameAudioManager = main.get_node("audio_manager")
	settings.opener.pressed.emit()
	settings.music_volume.value = 0.27
	settings.sfx_volume.value = 0.43
	settings.music_mute.button_pressed = true
	settings.sfx_mute.button_pressed = true
	expect(is_equal_approx(audio.music_volume, 0.27) and is_equal_approx(audio.sfx_volume, 0.43) and audio.music_muted and audio.sfx_muted, "独立声音场景的控件真实提交音量与静音")
	escape(host)
	expect(not settings.overlay.visible and not host.has_blocking_modal(), "Esc关闭声音设置并释放阻挡")
	var baseline:int = settings.tree_exiting.get_connections().size()
	for index in range(5):
		settings.opener.pressed.emit()
		settings.close_button.pressed.emit()
	expect(settings.tree_exiting.get_connections().size() == baseline, "重复开关设置不累积宿主退出连接")
	var invalid_root:Control = Control.new()
	var invalid_scene:PackedScene = PackedScene.new()
	expect(invalid_scene.pack(invalid_root) == OK, "创建测试用错误根场景")
	invalid_root.free()
	var valid_draft:PackedScene = flow.starting_draft_scene
	flow.starting_draft_scene = invalid_scene
	(flow.current_page as MainMenu).start_button.pressed.emit()
	expect(flow.current_page is MainMenu and flow.run_session == null and host.has_blocking_modal(), "新局页面失败时保留菜单，不提前公开待显示会话")
	flow.starting_draft_scene = valid_draft
	host._navigation_error.retry_button.pressed.emit()
	expect(flow.current_page is StartingDraftView and flow.run_session != null, "新局恢复重试原构筑意图，不返回菜单或重新抽样")
	var old_draft:StartingDraftView = flow.current_page
	flow.starting_draft_scene = invalid_scene
	old_draft._card_views[0].pressed.emit()
	var draft_session:RunSession = flow.run_session
	var draft_token:int = draft_session.step_token
	old_draft.back_requested.emit()
	expect(flow.run_session == draft_session and flow.current_page == old_draft and draft_session.step_token == draft_token, "构筑选择已提交但下一页失败时，旧页迟到返回不可清空会话")
	flow.starting_draft_scene = valid_draft
	host._navigation_error.retry_button.pressed.emit()
	for round_index in range(2):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit()
	var map:MapView = flow.current_page
	map.deck_button.pressed.emit()
	var inspector:CardInspector = map._card_inspector
	settings.opener.pressed.emit()
	escape(host)
	expect(not settings.overlay.visible and is_instance_valid(inspector) and host.has_blocking_modal(), "Esc一次只关闭最上层设置，保留下面的牌组查看器")
	map._on_map_node_pressed("start")
	expect(flow.current_page == map and flow.run_state.current_node_id.is_empty(), "查看期间即使直接触发入口也不能进入节点")
	escape(host)
	await process_frame
	expect(not is_instance_valid(inspector) and not host.has_blocking_modal() and not map._node_views["start"].node_button.disabled, "第二次Esc关闭查看器后恢复地图操作")
	map._node_views["start"].node_button.pressed.emit()
	var choice:CollectionChoiceView = flow.current_page
	var chalice:CollectionDefinition = load("res://collections/data/ember_chalice.tres")
	var valid_map:PackedScene = flow.map_scene
	flow.map_scene = invalid_scene
	choice.choice_buttons[choice.collection_options.find(chalice)].pressed.emit()
	var collection_token:int = flow.run_session.step_token
	choice.back_requested.emit()
	expect(flow.run_session == draft_session and flow.run_state.selected_collection == chalice and flow.run_session.step_token == collection_token, "藏品已提交但地图失败时，旧页返回步骤失效")
	flow.map_scene = valid_map
	host._navigation_error.retry_button.pressed.emit()
	(flow.current_page as MapView)._node_views["route_a_1"].node_button.pressed.emit()
	var battle:BattleView = flow.current_page
	var controller:BattleController = battle.get_controller()
	expect(controller.battle_state.hand.size() > 0 and controller.session.is_active(), "页面成功提交后才激活战斗并抽牌")
	settings.opener.pressed.emit()
	var phase:int = controller.battle_state.current_phase
	var energy:int = controller.battle_state.current_available_energy
	controller._on_end_turn_button_pressed()
	controller._on_card_selected(controller.battle_state.hand[0])
	expect(controller.battle_state.current_phase == phase and controller.battle_state.current_available_energy == energy, "设置浮层阻挡真实战斗命令")
	var valid_scene:PackedScene = flow.reward_scene
	flow.reward_scene = invalid_scene
	controller.battle_state.player_state.current_health = 31
	controller.battle_state.enemy_state.take_unblocked_damage(10000)
	controller._check_battle_result()
	var health:int = flow.run_state.current_health
	var candidates:Array[CardDefinition] = flow.run_state.reward_state.candidates.duplicate()
	var token:int = flow.run_session.step_token
	expect(flow.current_page == battle and flow.run_state.status == RunState.RunStatus.CHOOSING_REWARD and host.has_blocking_modal(), "规则提交后页面准备失败，保留旧页并给出恢复入口")
	expect(health == 37, "圣杯真实胜利治疗仅在提交结果时执行一次")
	controller._check_battle_result()
	expect(flow.run_state.current_health == health and flow.run_session.step_token == token and flow.run_state.reward_state.candidates == candidates, "重复终局回调不重复治疗、重抽或推进")
	escape(host)
	expect(not settings.overlay.visible and is_instance_valid(host._navigation_error) and flow.current_page == battle, "先开设置后出现下层导航错误，Esc仍只关闭最高显示层")
	flow.reward_scene = valid_scene
	host._navigation_error.retry_button.pressed.emit()
	expect(flow.current_page is RewardView and not host.has_blocking_modal(), "修正场景后重试只按既有规则状态恢复奖励展示")
	expect((flow.current_page as RewardView).reward_options == candidates and flow.run_state.current_health == health and flow.run_session.step_token == token, "恢复页面保留原候选、治疗和步骤身份")
	var old_reward:RewardView = flow.current_page
	var old_size:int = flow.run_state.owned_cards.size()
	old_reward.skip_button.pressed.emit()
	old_reward.reward_selected.emit(candidates[0])
	expect(flow.current_page is MapView and flow.run_state.owned_cards.size() == old_size, "奖励跳过后旧页领取信号失效")
	expect(is_equal_approx(audio.music_volume, 0.27) and audio.music_muted and audio.sfx_muted and is_equal_approx(audio.sfx_volume, 0.43), "声音设置跨地图、战斗和奖励保留")
	main.queue_free()
	await process_frame
	await process_frame
