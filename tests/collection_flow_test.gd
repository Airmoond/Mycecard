## 进入起点三选一、真实跨节点效果、圣杯胜利时序、防重与地图只读查看。
extends SceneTree

var failures:int = 0

func _initialize()->void:
	_run.call_deferred()

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1
		push_error(message)

func item(id:String)->CollectionDefinition:
	return load("res://collections/data/%s.tres" % id)

func drafted_state()->RunState:
	var state:RunState = RunState.new()
	expect(state.run_state_init(load("res://tests/fixtures/phase5_run.tres")), "藏品固定流程配置可初始化")
	for rarity in RunDefinition.DRAFT_RARITIES:
		state.choose_starting_card(CardPoolSampler.filter_pool(state.definition.character_definition.reward_card_pool, [rarity])[0])
	return state

func flow_start()->GameFlowController:
	var main:Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	var flow:GameFlowController = main.get_node("game_flow_controller")
	flow.run_definition = load("res://tests/fixtures/phase5_run.tres");
	flow.current_page.start_requested.emit()
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit()
	return flow

func choose(flow:GameFlowController, collection:CollectionDefinition)->void:
	var page:CollectionChoiceView = flow.current_page
	var index:int = page.collection_options.find(collection)
	expect(index >= 0, "选择页包含指定藏品")
	if index >= 0:
		page.choice_buttons[index].pressed.emit()

func _run()->void:
	_test_state_and_configuration()
	await _test_choice_layout_and_back()
	await _test_map_inspection()
	for id in ["copper_fang", "oathguard_emblem", "ember_chalice"]:
		await _test_adventure(id, false)
	await _test_adventure("ember_chalice", true)
	await process_frame
	await create_timer(0.5).timeout # 仅等待测试退出时的混音线程释放。
	print("藏品冒险流程检查完成，失败数：%d" % failures)
	quit(0 if failures == 0 else 1)

func _test_state_and_configuration()->void:
	var state:RunState = drafted_state()
	var bindings:Dictionary = state.node_encounters.duplicate()
	expect(state.selected_collection == null and not state.begin_collection_selection() and not state.choose_collection(item("copper_fang")), "未进起点不能选藏品")
	expect(state.enter_node("start") and not state.complete_current_node(), "配置藏品时不能跳过起点选择")
	expect(state.begin_collection_selection() and state.status == RunState.RunStatus.CHOOSING_COLLECTION and not state.is_invalid(), "进入起点开始选择，状态合法")
	var options:Array[CollectionDefinition] = state.collection_candidates.duplicate()
	expect(options.size() == 3 and state.collection_candidates.is_read_only(), "候选三件且保存为只读")
	for collection in state.definition.collection_pool:
		expect(options.has(collection) and not collection.is_invalid(), "三件真实资源完整展示")
	expect(not state.begin_collection_selection() and state.collection_candidates == options, "不能重抽选择候选")
	expect(not state.enter_node("route_a_1") and not state.complete_current_node() and not state.add_card(load("res://cards/data/strike.tres")), "选择中不能进线、完成节点或领取卡牌")
	expect(not state.choose_collection(item("copper_fang").duplicate()), "同名外部资源不能领取")
	expect(state.choose_collection(item("ember_chalice")) and not state.choose_collection(item("copper_fang")), "只领取一次原候选")
	expect(state.current_node_id.is_empty() and state.completed_node_ids == ["start"] and state.available_node_ids.size() == 3 and state.collection_candidates.is_empty() and state.owned_cards.size() == 9 and state.current_health == 50 and not state.is_invalid(), "选后完成起点，无加牌治疗，开放三入口")
	expect(bindings == state.node_encounters, "选藏品不修改开局敌人和Boss绑定")
	state.enter_node("route_a_1")
	state.max_health = 49
	state.current_health = 49
	expect(state.apply_normal_victory_collection() == 0, "满血胜利不溢出治疗")
	state.current_health = 40
	expect(state.apply_normal_victory_collection() == 0 and state.current_health == 40, "满血已触发的节点也不能随后补领治疗")
	state.complete_current_node()
	state.enter_node("route_a_2")
	expect(state.apply_normal_victory_collection() == 6 and state.current_health == 46 and state.max_health == 49, "下一普通节点按实际上限治疗一次")
	state.complete_current_node()
	state.enter_node("route_a_rest")
	expect(state.apply_normal_victory_collection() == 0, "休整不触发圣杯")
	state.heal(15)
	state.complete_current_node()
	state.enter_node("final_boss")
	state.current_health = 30
	expect(state.apply_normal_victory_collection() == 0 and state.current_health == 30, "Boss不触发普通战治疗")
	expect(state.run_state_init(load("res://tests/fixtures/phase5_run.tres")) and state.selected_collection == null and state.collection_candidates.is_empty() and state._normal_victory_collection_nodes.is_empty() and not state.is_invalid(), "重开清除持有、候选和回血记录")
	print("以下无效藏品配置报错为预期。")
	var invalid:RunDefinition = load("res://run/data/default_run.tres").duplicate()
	invalid.collection_pool = [item("copper_fang"), item("copper_fang"), item("ember_chalice")]
	expect(invalid.is_invalid(), "重复藏品ID拒绝启动")
	invalid = load("res://run/data/default_run.tres").duplicate()
	invalid.collection_option_count = 2
	expect(invalid.is_invalid(), "候选数不符合三选一时拒绝配置")
	var legacy:RunState = RunState.new()
	expect(legacy.run_state_init(load("res://tests/fixtures/linear_run.tres")), "没有藏品池的旧配置保持兼容")

func _test_choice_layout_and_back()->void:
	var flow:GameFlowController = flow_start()
	var state:RunState = flow.run_state
	expect(flow.current_page is MapView and state.selected_collection == null, "三轮选牌完成后先显示地图")
	flow._handle_map_node_selected("start")
	expect(flow.current_page is CollectionChoiceView and state.current_node_id == "start" and state.completed_node_ids.is_empty() and state.available_node_ids.is_empty(), "点击起点才进入藏品选择，支线未开放")
	var page:CollectionChoiceView = flow.current_page
	var options:Array[CollectionDefinition] = page.collection_options.duplicate()
	flow._show_collection_choice()
	expect((flow.current_page as CollectionChoiceView).collection_options == options and state.collection_candidates == options, "重建页面不重抽候选")
	page.collection_selected.emit(options[0])
	expect(flow.current_page is CollectionChoiceView and state.selected_collection == null, "旧选择页面信号不能提交")
	for dimensions in [Vector2i(1024, 600), Vector2i(1920, 1080)]:
		root.size = dimensions
		await process_frame
		await process_frame
		page = flow.current_page
		for panel:Control in page.options_container.get_children():
			expect(page.get_global_rect().encloses(panel.get_global_rect()), "三选一候选在窗口范围内")
			var label:Label = panel.get_child(0).get_node("description")
			expect(label.get_line_count() * label.get_line_height() <= label.size.y + 1, "完整藏品描述不裁切")
			expect(label.text.length() > 0, "候选效果有描述")
	page.back_button.pressed.emit()
	expect(flow.run_state == null and flow.current_page is MainMenu, "选择中返回菜单释放未完成冒险")
	page.collection_selected.emit(options[0])
	expect(flow.run_state == null, "返回后旧候选不创建或修改冒险")
	flow.current_page.start_requested.emit()
	expect(flow.run_state != state and flow.current_page is StartingDraftView and flow.run_state.selected_collection == null, "重新开始从选牌起，不继承藏品")
	flow.get_parent().queue_free()
	await process_frame

func _test_map_inspection()->void:
	var flow:GameFlowController = flow_start()
	var map:MapView = flow.current_page
	var state:RunState = flow.run_state
	var bindings:Dictionary = state.node_encounters.duplicate()
	map.collection_button.pressed.emit()
	expect(is_instance_valid(map._collection_inspector) and map._collection_inspector.collection == null, "未领藏品也能查看明确空态")
	map._node_views["start"].node_button.pressed.emit()
	map._on_map_node_pressed("start")
	expect(flow.current_page == map and state.current_node_id.is_empty(), "查看期间不能进入起点")
	map._collection_inspector.close_button.pressed.emit()
	await process_frame
	map._node_views["start"].node_button.pressed.emit()
	choose(flow, item("copper_fang"))
	map = flow.current_page
	map.collection_button.pressed.emit()
	var inspector:CollectionInspector = map._collection_inspector
	expect(inspector.collection == state.selected_collection and inspector.description_label.text == state.selected_collection.description and inspector.icon_view.texture == state.selected_collection.icon, "持有查看显示真实名称图标与效果")
	var count:int = map.get_child_count()
	map.collection_button.pressed.emit()
	map._open_collection_inspector()
	expect(map.get_child_count() == count and map._collection_inspector == inspector, "快速点击不叠加查看窗口")
	map._on_map_node_pressed("route_a_1")
	expect(state.selected_route_id.is_empty() and state.current_node_id.is_empty() and state.node_encounters == bindings and state.owned_cards.size() == 9, "查看不推进地图、加牌或重抽")
	var escape:InputEventKey = InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	inspector._unhandled_key_input(escape)
	await process_frame
	expect(not is_instance_valid(map._collection_inspector) and not map._node_views["route_a_1"].node_button.disabled, "Esc关闭后恢复本来可进入节点")
	flow.get_parent().queue_free()
	await process_frame

func _test_adventure(id:String, defeat:bool)->void:
	var flow:GameFlowController = flow_start()
	flow._handle_map_node_selected("start")
	var page:CollectionChoiceView = flow.current_page
	var collection:CollectionDefinition = item(id)
	choose(flow, collection)
	var state:RunState = flow.run_state
	page.collection_selected.emit(item("ember_chalice"))
	expect(state.selected_collection == collection and flow.current_page is MapView, "领取后旧页面不能替换藏品")
	state.current_health = 40
	state.max_health = 49
	for step in range(1, 3):
		flow._handle_map_node_selected("route_a_%d" % step)
		var controller:BattleController = flow.current_page.get_node("battle_controller")
		var player:CombatantState = controller.battle_state.player_state
		expect(controller.selected_collection == collection, "当前藏品注入每场战斗")
		expect(player.strength == (1 if id == "copper_fang" else 0) and player.current_block == (3 if id == "oathguard_emblem" else 0), "真实战斗开局力量和格挡正确")
		if defeat:
			player.take_unblocked_damage(1000)
			controller._check_battle_result()
			expect(state.current_health == 0 and state.status == RunState.RunStatus.DEFEAT and state.owned_cards.size() == 9 and state._normal_victory_collection_nodes.is_empty(), "战败不治疗、不奖励")
			flow.get_parent().queue_free()
			await process_frame
			return
		player.current_health = 40
		controller.battle_state.enemy_state.take_unblocked_damage(1000)
		controller._check_battle_result()
		var expected_hp:int = 46 if id == "ember_chalice" else 40
		expect(flow.current_page is RewardView and state.current_health == expected_hp and state.max_health == 49, "胜利回写后、奖励前圣杯按实际生命治疗")
		controller.battle_finished.emit(true, 40, 49)
		flow._handle_battle_finished(true, 40, 49)
		expect(state.current_health == expected_hp, "旧胜利回调既不覆盖回血也不重复触发")
		(flow.current_page as RewardView)._reward_card_views[0].pressed.emit()
		expect(state.selected_collection == collection and state.owned_cards.size() == 9 + step and not state.is_invalid(), "战后持有保留，奖励不包含藏品")
	flow._handle_map_node_selected("route_a_rest")
	expect(state.current_health == 49 and state.max_health == 49, "休整按血祭后的实际最大生命封顶")
	flow._handle_map_node_selected("final_boss")
	var boss:BattleController = flow.current_page.get_node("battle_controller")
	expect(boss.selected_collection == collection, "Boss战继续持有同件藏品")
	boss.battle_state.player_state.current_health = 30
	boss.battle_state.enemy_state.take_unblocked_damage(1000)
	boss._check_battle_result()
	expect(state.current_health == 30 and state.status == RunState.RunStatus.VICTORY and state.owned_cards.size() == 11 and not state.is_invalid(), "Boss胜利无圣杯治疗或普通奖励")
	flow.current_page.restart_requested.emit()
	flow.current_page.start_requested.emit()
	expect(flow.run_state != state and flow.run_state.selected_collection == null and flow.run_state.max_health == 50 and flow.run_state.collection_candidates.is_empty() and flow.current_page is StartingDraftView, "胜利重开清理藏品、候选、生命和触发历史")
	flow.get_parent().queue_free()
	await process_frame
