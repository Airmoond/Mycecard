## 分支拓扑、随机结果稳定、选路、真实奖励与生命衔接、胜败重开及窗口布局。
extends SceneTree

var failures:int = 0
## 第五阶段固定内容回归；第六阶段随机类型在 phase6_run_state/flow_test 验证。
const DEFAULT_RUN:String = "res://tests/fixtures/phase5_run.tres"

func _initialize()->void:
	_run.call_deferred()

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1
		push_error(message)

func drafted_state(value:int)->RunState:
	seed(value)
	var state:RunState = RunState.new()
	expect(state.run_state_init(load(DEFAULT_RUN)), "默认分支冒险可初始化")
	for rarity in RunDefinition.DRAFT_RARITIES:
		var options:Array[CardDefinition] = CardPoolSampler.filter_pool(state.definition.character_definition.reward_card_pool, [rarity])
		expect(state.choose_starting_card(options[0]), "构筑提交合法候选")
	return state

func _run()->void:
	_test_structure_and_sampling()
	_test_progression()
	await _test_view()
	for route in ["a", "b", "c"]:
		await _test_flow(route, "")
	await _test_flow("b", "route_b_2")
	await _test_flow("c", "final_boss")
	await create_timer(0.5).timeout # 等待已释放播放器的混音线程收尾，不改变规则或断言。
	print("分支地图检查完成，失败数：%d" % failures)
	quit(0 if failures == 0 else 1)

func _test_structure_and_sampling()->void:
	var definition:RunDefinition = load(DEFAULT_RUN)
	var map:MapDefinition = definition.map_definition
	expect(not definition.is_invalid() and map.is_branch_map and map.nodes.size() == 11, "默认五层11节点配置合法")
	expect(map.starting_node_ids == ["start"] and map.get_route_ids() == ["a", "b", "c"], "一个起点与三条独立支线")
	var normal_pool:Array[EncounterDefinition] = definition.normal_encounter_pool.duplicate()
	var boss_pool:Array[EncounterDefinition] = definition.boss_encounter_pool.duplicate()
	var seen_normals:Dictionary = {}
	var seen_bosses:Dictionary = {}
	for value in range(96):
		var state:RunState = drafted_state(930000 + value)
		expect(state.node_encounters.size() == 7 and not state.is_invalid(), "六个普通位置与一个最终Boss一次性绑定")
		for route in map.get_route_ids():
			var ids:Array[String] = map.get_route_node_ids(route)
			expect(ids.size() == 3, "每条支线三个节点")
			var first:EncounterDefinition = state.get_node_encounter(ids[0])
			var second:EncounterDefinition = state.get_node_encounter(ids[1])
			expect(normal_pool.has(first) and normal_pool.has(second) and first.enemy_definition.combatant_id != second.enemy_definition.combatant_id, "同路线两普通敌人不同，且属于普通池")
			seen_normals[first.enemy_definition.combatant_id] = true
			seen_normals[second.enemy_definition.combatant_id] = true
		var boss:EncounterDefinition = state.get_node_encounter("final_boss")
		expect(boss_pool.has(boss), "最终Boss属于Boss池")
		seen_bosses[boss.enemy_definition.combatant_id] = true
		var bindings:Dictionary = state.node_encounters.duplicate()
		state.enter_node("start")
		state.begin_collection_selection()
		state.choose_collection(state.definition.collection_pool[0])
		expect(bindings == state.node_encounters, "开始节点不重新抽取遭遇")
		expect(state.get_node_display_name("final_boss") == boss.enemy_definition.display_name, "地图Boss名称与绑定敌人一致")
	expect(seen_normals.size() == normal_pool.size() and seen_bosses.size() == boss_pool.size(), "固定种子样本覆盖全部现有普通敌人与三种Boss")
	expect(definition.normal_encounter_pool == normal_pool and definition.boss_encounter_pool == boss_pool, "抽样不修改候选池顺序或内容")
	for node in map.nodes:
		expect(node.encounter_definition == null, "随机结果不回写静态地图节点")
	print("以下三份无效分支配置的报错为预期。")
	for mutation in range(3):
		var invalid_map:MapDefinition = map.duplicate(true)
		match mutation:
			0: invalid_map.get_node_by_id("route_a_1").next_node_ids = ["route_b_2"]
			1: invalid_map.get_node_by_id("route_b_rest").next_node_ids = ["route_b_1"]
			2: invalid_map.get_node_by_id("route_c_rest").next_node_ids = []
		expect(invalid_map.is_invalid(), "拒绝跨路线、环路和死路")

func _test_progression()->void:
	var state:RunState = drafted_state(901)
	state.current_health = 20
	expect(not state.enter_node("route_a_1") and not state.enter_node("final_boss"), "起点完成前不开放分支与Boss")
	expect(state.enter_node("start") and state.begin_collection_selection() and state.choose_collection(state.definition.collection_pool[0]), "完成起点")
	expect(state.current_health == 20 and state.owned_cards.size() == 9, "开始节点不治疗、不加牌")
	expect(state.available_node_ids == ["route_a_1", "route_b_1", "route_c_1"], "起点同时开放三条路线入口")
	expect(state.enter_node("route_b_1") and state.selected_route_id == "b", "第一次进入战斗锁定路线")
	expect(not state.enter_node("route_a_1") and not state.enter_node("route_b_2"), "处理当前战斗时不能进入其他节点")
	expect(state.complete_current_node() and state.available_node_ids == ["route_b_2"], "只开放所选路线后继")
	expect(not state.can_enter_node("route_a_1") and not state.can_enter_node("route_c_1") and not state.enter_node("route_b_1"), "不可换线或回退")
	expect(state.enter_node("route_b_2") and state.complete_current_node(), "完成第二场普通战斗")
	expect(state.enter_node("route_b_rest") and state.heal(15) == 15 and state.complete_current_node(), "休整后进入Boss层")
	expect(not state.enter_node("route_b_rest") and state.current_health == 35, "不能重复治疗")
	expect(state.enter_node("final_boss") and state.complete_current_node() and state.mark_victory(), "完成所选五节点路径即胜利")
	expect(state.completed_node_ids == ["start", "route_b_1", "route_b_2", "route_b_rest", "final_boss"] and not state.is_invalid(), "胜利无需完成其余六节点")
	expect(state.run_state_init(load(DEFAULT_RUN)) and state.selected_route_id.is_empty() and state.completed_node_ids.is_empty() and state.available_node_ids == ["start"] and state.status == RunState.RunStatus.DRAFTING, "重新初始化清除路线和进度")

func _test_view()->void:
	var state:RunState = drafted_state(905)
	var bindings:Dictionary = state.node_encounters.duplicate()
	var map:MapView = load("res://run/map/map_view.tscn").instantiate()
	root.add_child(map)
	expect(map.setup(state.definition.map_definition, state), "地图可绑定真实随机局")
	for dimensions in [Vector2i(1024, 600), Vector2i(1920, 1080), Vector2i(1280, 720)]:
		root.size = dimensions
		await process_frame
		await process_frame
		map.refresh_map()
		await process_frame
		expect(map.node_layer.get_child_count() == 11 and map.connection_layer.get_child_count() == 12, "刷新与缩放不叠加节点或连线")
		var rectangles:Array[Rect2] = []
		for node:MapNodeView in map._node_views.values():
			var rectangle:Rect2 = Rect2(node.position, node.size * node.scale)
			expect(Rect2(Vector2.ZERO, map.size).encloses(rectangle), "节点在地图范围内：%s" % node.node_definition.node_id)
			for other in rectangles:
				expect(not rectangle.intersects(other), "窗口尺寸下节点不重叠")
			rectangles.append(rectangle)
			if node.node_definition.requires_encounter():
				expect(node.node_button.text.contains(state.get_node_display_name(node.node_definition.node_id)), "地图显示本局真实敌人名")
			var minimum:Vector2 = node.node_button.get_minimum_size()
			expect(minimum.x <= node.size.x and minimum.y <= node.size.y, "三行文字完整容纳：%s" % node.node_definition.node_id)
		expect(bindings == state.node_encounters, "刷新与改变窗口不重新抽取")
	state.enter_node("start")
	state.begin_collection_selection()
	state.choose_collection(state.definition.collection_pool[0])
	state.enter_node("route_a_1")
	state.complete_current_node()
	map.refresh_map()
	expect(map._node_views["route_b_1"].node_button.disabled and map._node_views["route_b_1"].node_button.text.contains("未选路线"), "未选路线可见且锁定")
	expect(not map._node_views["route_a_2"].node_button.disabled, "本路线下一节点可进入")
	map.queue_free()
	await process_frame

func _test_flow(route:String, defeat_node:String)->void:
	seed(940100 + route.unicode_at(0) + defeat_node.length())
	var main:Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	var flow:GameFlowController = main.get_node("game_flow_controller")
	flow.run_definition = load(DEFAULT_RUN);
	flow.current_page.start_requested.emit()
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit()
	var state:RunState = flow.run_state
	var bindings:Dictionary = state.node_encounters.duplicate()
	state.current_health = 20
	state.max_health = 49
	var start_page:MapView = flow.current_page
	start_page._node_views["start"].node_button.pressed.emit()
	expect(state.current_health == 20 and state.owned_cards.size() == 9 and flow.current_page is CollectionChoiceView, "进入开始节点先三选一藏品，不治疗、不加牌")
	flow._handle_collection_selected(load("res://collections/data/oathguard_emblem.tres"))
	expect(flow.current_page is MapView, "选完藏品再开放支线")
	start_page.node_selected.emit("route_%s_1" % route)
	expect(flow.current_page is MapView and state.selected_route_id.is_empty(), "已替换地图的残余信号不能选择路线")
	for index in range(1, 3):
		var node_id:String = "route_%s_%d" % [route, index]
		var page:MapView = flow.current_page
		page._node_views[node_id].node_button.pressed.emit()
		var controller:BattleController = flow.current_page.get_node("battle_controller")
		expect(controller.battle_state.enemy_state.definition == bindings[node_id].enemy_definition, "战斗使用地图上已显示的随机敌人")
		expect(controller.battle_state.player_state.current_health == 20 and controller.battle_state.player_state.max_health == 49, "跨普通战斗保持实际生命与上限")
		if defeat_node == node_id:
			controller.battle_state.player_state.take_unblocked_damage(1000)
			controller._check_battle_result()
			expect(flow.current_page is RunResult and state.status == RunState.RunStatus.DEFEAT and state.owned_cards.size() == 10 and not state.completed_node_ids.has(node_id), "第二战失败无奖励、不完成节点")
			main.queue_free()
			await process_frame
			return
		controller.battle_state.enemy_state.take_unblocked_damage(1000)
		controller._check_battle_result()
		expect(flow.current_page is RewardView and state.current_node_id == node_id and not state.completed_node_ids.has(node_id), "胜利后领取奖励前不推进")
		var reward:RewardView = flow.current_page
		var chosen:CardDefinition = reward.reward_options[0]
		reward._reward_card_views[0].pressed.emit()
		expect(flow.current_page is MapView and state.owned_cards.size() == 9 + index and state.owned_cards.back() == chosen, "每场实际只加一张奖励卡")
		reward.reward_selected.emit(chosen)
		expect(state.owned_cards.size() == 9 + index, "旧奖励信号不重复加牌")
		expect(state.node_encounters == bindings and state.selected_route_id == route and not state.is_invalid(), "返回地图保持随机结果及路线")
	flow._handle_map_node_selected("route_%s_rest" % route)
	expect(state.current_health == 35 and state.max_health == 49 and state.owned_cards.size() == 11, "休整实际恢复15，Boss前11张牌")
	flow._handle_map_node_selected("final_boss")
	var boss_controller:BattleController = flow.current_page.get_node("battle_controller")
	expect(boss_controller.battle_state.enemy_state.definition == bindings["final_boss"].enemy_definition, "最终战使用开局固定的随机Boss")
	expect(boss_controller.battle_state.hand.size() + boss_controller.battle_state.draw_pile.size() == 11, "全部11张牌进入Boss战")
	if defeat_node == "final_boss":
		boss_controller.battle_state.player_state.take_unblocked_damage(1000)
	else:
		boss_controller.battle_state.enemy_state.take_unblocked_damage(1000)
	boss_controller._check_battle_result()
	expect(flow.current_page is RunResult and state.status == (RunState.RunStatus.DEFEAT if not defeat_node.is_empty() else RunState.RunStatus.VICTORY) and not state.is_invalid(), "Boss胜败正确结算")
	flow.current_page.restart_requested.emit()
	expect(flow.run_state == null and flow.current_page is MainMenu, "再次启程释放旧局")
	flow.current_page.start_requested.emit()
	expect(flow.run_state != state and flow.run_state.current_health == 50 and flow.run_state.max_health == 50 and flow.run_state.owned_cards.size() == 6 and flow.run_state.selected_route_id.is_empty(), "重开恢复干净构筑与地图进度")
	main.queue_free()
	await process_frame
