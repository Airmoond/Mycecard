## 正式页面主题、音量入口、共用卡面与随机地图的整合检查；可选GPU截图。
extends SceneTree

var failures:int = 0
var capture:bool = false
var output_dir:String = "res://release/refactor/screenshots"

func _initialize()->void:
	capture = "--capture" in OS.get_cmdline_user_args()
	_run.call_deferred()

func expect(value:bool, message:String)->void:
	if not value:
		failures += 1
		push_error(message)

func frames()->void:
	for _frame in range(4):
		await process_frame

func save_screen(name:String)->void:
	await frames()
	if not capture:
		return
	await create_timer(0.55).timeout
	await RenderingServer.frame_post_draw
	var picture:Image = root.get_texture().get_image()
	expect(not picture.is_empty(), "GPU已绘制实际页面")
	if not picture.is_empty():
		picture.save_png(output_dir.path_join(name + ".png"))

func _run()->void:
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1920, 1080)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	var main:Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	var flow:GameFlowController = main.get_node("game_flow_controller")
	flow.run_seed = 961000
	var audio:GameAudioManager = main.get_node("audio_manager")
	expect(audio.current_music_state == &"exploration", "主界面开始探索音乐")
	expect(main.get_node("page_container").theme != null, "跨页面继承同一套主题")
	await save_screen("01-main-menu")
	var settings:CanvasLayer = main.get_node("sound_controls")
	settings.opener.pressed.emit()
	expect(settings.overlay.visible, "全局声音入口实际打开")
	audio.set_music_muted(true)
	audio.set_sfx_volume(0.35)
	audio.set_sfx_muted(true)
	expect(AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")) and AudioServer.is_bus_mute(AudioServer.get_bus_index("SFX")), "独立音频静音已生效")
	await save_screen("02-audio-settings")
	settings.close_button.pressed.emit()
	var old_menu:MainMenu = flow.current_page
	old_menu.start_button.pressed.emit()
	var current_run:RunState = flow.run_state
	old_menu.start_requested.emit()
	expect(flow.run_state == current_run and flow.current_page is StartingDraftView, "旧菜单不能重新创建当前冒险")
	await save_screen("03-starting-draft")
	for _round in range(3):
		var old_draft:StartingDraftView = flow.current_page
		old_draft._card_views[0].pressed.emit()
		old_draft.back_requested.emit()
		expect(flow.run_state == current_run, "旧构筑页返回不能清空新页面")
	var state:RunState = flow.run_state
	var map:MapView = flow.current_page
	map._node_views["start"].node_button.pressed.emit()
	await save_screen("04-collection-choice")
	(flow.current_page as CollectionChoiceView).choice_buttons[0].pressed.emit()
	await save_screen("05-route-map")
	for dimensions:Vector2i in [Vector2i(1280, 720), Vector2i(1024, 600)]:
		root.size = dimensions
		await frames()
		map = flow.current_page
		for view:MapNodeView in map._node_views.values():
			expect(map.get_global_rect().encloses(view.get_global_rect()), "地图所有固定位置在页面内")
	root.size = Vector2i(1920, 1080)
	map.deck_button.pressed.emit()
	await save_screen("06-deck-inspector")
	map._card_inspector.close_button.pressed.emit()
	var routes:Array[String] = state.definition.map_definition.get_route_node_ids("a")
	var saw_battle:bool = false
	for node_id:String in routes:
		(flow.current_page as MapView)._node_views[node_id].node_button.pressed.emit()
		if state.get_node_type(node_id) == MapNodeDefinition.NodeType.UNEXPECTED:
			var encounter:UnexpectedEncounterView = flow.current_page
			await save_screen("07-unexpected-encounter")
			encounter.option_buttons["leave"].pressed.emit()
			await save_screen("08-unexpected-result")
			(flow.current_page as UnexpectedEncounterView).option_buttons["continue"].pressed.emit()
		else:
			var controller:BattleController = flow.current_page.get_node("battle_controller")
			expect(audio.current_music_state == &"combat", "实际进入战斗才切战斗音乐")
			if not saw_battle:
				saw_battle = true
				await save_screen("09-battle")
				var before:int = controller.battle_state.current_available_energy
				for instance:CardInstance in controller.battle_state.hand.duplicate():
					if instance.current_energy_cost <= before and instance.definition.card_id != "war_god_blessing":
						controller._on_card_selected(instance)
						break
				expect(controller.battle_state.current_available_energy <= before + 3, "表现不虚构资源")
				await save_screen("10-battle-after-play")
			controller.battle_state.enemy_state.take_unblocked_damage(10000)
			controller._check_battle_result()
			expect(audio.current_music_state == &"exploration", "普通胜利奖励恢复探索音乐")
			await save_screen("11-card-reward")
			(flow.current_page as RewardView).skip_button.pressed.emit()
	expect(audio.music_muted and audio.sfx_muted and is_equal_approx(audio.sfx_volume, 0.35), "声音设置跨页面保持")
	(flow.current_page as MapView)._node_views["final_boss"].node_button.pressed.emit()
	var boss:BattleController = flow.current_page.get_node("battle_controller")
	boss.battle_state.enemy_state.take_unblocked_damage(10000)
	boss._check_battle_result()
	await save_screen("12-victory")
	var old_result:RunResult = flow.current_page
	old_result.restart_button.pressed.emit()
	expect(flow.current_page is MainMenu and flow.run_state == null, "胜利正常回菜单并清除旧局")
	var menu:MainMenu = flow.current_page
	menu.start_button.pressed.emit()
	var new_run:RunState = flow.run_state
	menu.start_requested.emit()
	old_result.restart_requested.emit()
	expect(flow.run_state == new_run and flow.current_page is StartingDraftView, "重新开始后旧菜单与旧结算不会覆盖新局")
	main.queue_free()
	await frames()
	await _check_three_encounter_pages()
	await create_timer(0.5).timeout
	print("第六阶段视觉整合检查完成，失败数：%d" % failures)
	quit(1 if failures else 0)

## 三份正式插画和选择页都进入真实流程，并检查小窗口内的完整入口。
func _check_three_encounter_pages()->void:
	var default:RunDefinition = load("res://run/data/default_run.tres")
	for index in range(default.unexpected_encounter_pool.size()):
		var content:UnexpectedEncounterDefinition = default.unexpected_encounter_pool[index]
		var definition:RunDefinition = default.duplicate()
		var pool:Array[UnexpectedEncounterDefinition] = [content]
		definition.unexpected_encounter_pool = pool
		var routes:Array[String] = definition.map_definition.get_route_node_ids("a")
		var selected_seed:int = -1
		for value in range(961000, 961100):
			var probe:RunSession = RunSession.new()
			probe.initialize(definition, value)
			if probe.state.get_node_type(routes[0]) == MapNodeDefinition.NodeType.UNEXPECTED:
				selected_seed = value
				break
		expect(selected_seed >= 0, "找到不期而遇在首个位置的正式随机结果")
		var main:Node = load("res://main.tscn").instantiate()
		var flow:GameFlowController = main.get_node("game_flow_controller")
		flow.run_definition = definition
		flow.run_seed = selected_seed
		root.add_child(main)
		flow._start_new_run()
		expect(flow.run_state.get_node_type(routes[0]) == MapNodeDefinition.NodeType.UNEXPECTED, "真实页面会话与显式种子探测保持相同首位实例")
		for _round in range(3):
			(flow.current_page as StartingDraftView)._card_views[0].pressed.emit()
		(flow.current_page as MapView)._node_views["start"].node_button.pressed.emit()
		(flow.current_page as CollectionChoiceView).choice_buttons[0].pressed.emit()
		(flow.current_page as MapView)._node_views[routes[0]].node_button.pressed.emit()
		var page:UnexpectedEncounterView = flow.current_page
		expect(page.artwork_view.texture == content.artwork and content.artwork != null, "实例展示独立正式插画")
		root.size = Vector2i(1920, 1080)
		await save_screen("%02d-%s" % [13 + index, content.encounter_id])
		root.size = Vector2i(1024, 600)
		await frames()
		for button:Button in page.option_buttons.values():
			expect(page.get_global_rect().encloses(button.get_global_rect()), "小窗口初始选项全部在视口内")
		var health:int = flow.run_state.current_health
		var count:int = flow.run_state.owned_cards.size()
		var option:String = "remove" if content.kind == UnexpectedEncounterDefinition.Kind.FOUNTAIN else "card"
		page.option_buttons[option].pressed.emit()
		await frames()
		for card:CardChoiceView in page.card_views:
			expect(page.get_global_rect().encloses(card.get_global_rect()), "小窗口选牌或删除卡面完整在视口内")
		expect(page.get_global_rect().encloses(page.option_buttons["back"].get_global_rect()), "小窗口选牌返回入口可见")
		root.size = Vector2i(1280, 720)
		await save_screen("%02d-%s-selection" % [16 + index, content.encounter_id])
		page.option_buttons["back"].pressed.emit()
		expect(flow.run_state.current_health == health and flow.run_state.owned_cards.size() == count, "返回选项不支付或修改牌组")
		page.option_buttons["leave"].pressed.emit()
		(flow.current_page as UnexpectedEncounterView).option_buttons["continue"].pressed.emit()
		expect(flow.current_page is MapView and flow.run_state.completed_node_ids.has(routes[0]), "正式插画与选牌页不影响节点完成")
		main.queue_free()
		await frames()
