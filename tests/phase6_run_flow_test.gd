## 正式三实例在三个中间位置的真实冒险闭环、子页返回、防重复与多轮跳过。
extends SceneTree

var failures:int = 0;
const DEFAULT:RunDefinition = preload("res://run/data/default_run.tres");

func _initialize()->void:
	_run.call_deferred();

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1;
		push_error(message);

func config(kind:int)->RunDefinition:
	var definition:RunDefinition = DEFAULT.duplicate();
	var pool:Array[UnexpectedEncounterDefinition] = [];
	for content in DEFAULT.unexpected_encounter_pool:
		if content.kind == kind:
			pool.append(content);
	definition.unexpected_encounter_pool = pool;
	return definition;

func start(definition:RunDefinition, position:int = -1)->GameFlowController:
	var selected_seed:int = 961000;
	if position >= 0:
		selected_seed = -1;
		for value in range(961000, 961100):
			var probe:RunSession = RunSession.new();
			probe.initialize(definition, value);
			var ids:Array[String] = definition.map_definition.get_route_node_ids("a");
			if probe.state.get_node_type(ids[position]) == MapNodeDefinition.NodeType.UNEXPECTED:
				selected_seed = value;
				break;
		expect(selected_seed >= 0, "显式会话种子覆盖指定不期而遇位置");
	var main:Node = load("res://main.tscn").instantiate();
	var flow:GameFlowController = main.get_node("game_flow_controller");
	flow.run_definition = definition;
	flow.run_seed = selected_seed;
	root.add_child(main);
	flow._start_new_run();
	if position >= 0:
		var ids:Array[String] = definition.map_definition.get_route_node_ids("a");
		expect(flow.run_state.get_node_type(ids[position]) == MapNodeDefinition.NodeType.UNEXPECTED, "真实会话绑定与探测相同，保留三位置覆盖");
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
	(flow.current_page as MapView)._node_views["start"].node_button.pressed.emit();
	flow._handle_collection_selected(load("res://collections/data/ember_chalice.tres"));
	return flow;

func _run()->void:
	root.size = Vector2i(1280, 720);
	for kind in [UnexpectedEncounterDefinition.Kind.CAMP, UnexpectedEncounterDefinition.Kind.ALTAR, UnexpectedEncounterDefinition.Kind.FOUNTAIN]:
		for position in range(3):
			await _test_adventure(kind, position);
	await _test_heal_leave_and_affordability();
	await _test_multiple_rewards();
	# AudioServer retires stopped threaded OGG playback asynchronously after page disposal.
	await create_timer(0.5).timeout;
	print("第六阶段真实流程检查完成，失败数：%d" % failures);
	quit(1 if failures else 0);

func _test_adventure(kind:int, position:int)->void:
	var flow:GameFlowController = start(config(kind), position);
	var state:RunState = flow.run_state;
	state.current_health = 30;
	state.max_health = 49;
	var types:Dictionary = state.node_types.duplicate();
	var encounters:Dictionary = state.node_encounters.duplicate();
	var contents:Dictionary = state.node_unexpected_encounters.duplicate();
	var initial_count:int = state.owned_cards.size();
	var ordinary_battles:int = 0;
	var ids:Array[String] = state.definition.map_definition.get_route_node_ids("a");
	for node_id in ids:
		var map:MapView = flow.current_page;
		map._node_views[node_id].node_button.pressed.emit();
		if types[node_id] == MapNodeDefinition.NodeType.BATTLE:
			ordinary_battles += 1;
			var controller:BattleController = flow.current_page.get_node("battle_controller");
			expect(controller.battle_state.enemy_state.definition == encounters[node_id].enemy_definition, "真实战斗与地图绑定敌人一致");
			expect(controller.battle_state.hand.size() + controller.battle_state.draw_pile.size() == state.owned_cards.size(), "后续战斗使用不期而遇后的实际牌组");
			controller.battle_state.player_state.take_unblocked_damage(3);
			var before_victory:int = controller.battle_state.player_state.current_health;
			controller.battle_state.enemy_state.take_unblocked_damage(1000);
			controller._check_battle_result();
			expect(flow.current_page is RewardView and state.current_node_id == node_id, "普通胜利进入三选一但尚未完成节点");
			var healed:int = mini(before_victory + 6, state.max_health);
			expect(state.current_health == healed, "圣杯在奖励页面前恢复一次");
			var reward:RewardView = flow.current_page;
			var count:int = state.owned_cards.size();
			if ordinary_battles == 1:
				reward.skip_button.pressed.emit();
				expect(state.owned_cards.size() == count and state.current_health == healed and state.completed_node_ids.has(node_id), "跳过不加牌不撤回或重放治疗，正常完成节点");
			else:
				reward._reward_card_views[0].pressed.emit();
				expect(state.owned_cards.size() == count + 1, "另一普通战斗依旧可以领取一张卡");
			reward.reward_skipped.emit();
			reward.reward_selected.emit(reward.reward_options[0]);
			controller.battle_finished.emit(true, 1, 49);
			expect(state.current_health == healed and state.owned_cards.size() == count + (0 if ordinary_battles == 1 else 1), "旧奖励和旧胜利回调不能更改牌组或生命");
		else:
			expect(flow.current_page is UnexpectedEncounterView and state.status == RunState.RunStatus.CHOOSING_UNEXPECTED and not state.completed_node_ids.has(node_id), "进入不期而遇停留在选择状态");
			var page:UnexpectedEncounterView = flow.current_page;
			var candidates:Array = state.unexpected_candidates[node_id].duplicate();
			var before_health:int = state.current_health;
			var count:int = state.owned_cards.size();
			if kind == UnexpectedEncounterDefinition.Kind.FOUNTAIN:
				page.option_buttons["remove"].pressed.emit();
				var old_view:CardChoiceView = page.card_views[0];
				var first:CardDefinition = old_view.card_definition;
				var copies:int = state.owned_cards.count(first);
				page.option_buttons["back"].pressed.emit();
				old_view.card_selected.emit(first);
				expect(state.owned_cards.size() == count and state.unexpected_results.is_empty(), "删除子页取消不删牌，旧卡视图不能提交");
				page.option_buttons["remove"].pressed.emit();
				page.card_views[0].pressed.emit();
				expect(state.owned_cards.size() == count - 1 and state.owned_cards.count(first) == copies - 1, "泉水删掉实际拥有的一份卡牌");
			else:
				page.option_buttons["card"].pressed.emit();
				page.option_buttons["back"].pressed.emit();
				expect(state.current_health == before_health and state.owned_cards.size() == count and state.unexpected_candidates[node_id] == candidates, "卡牌子页返回不支付、不发卡、不重抽");
				flow._show_unexpected_encounter();
				page.option_selected.emit("leave", null, -1);
				expect(state.unexpected_results.is_empty(), "旧内容页面输入不能完成新页面节点");
				page = flow.current_page;
				page.option_buttons["card"].pressed.emit();
				var choice:CardDefinition = page.card_views[0].card_definition;
				page.card_views[0].pressed.emit();
				expect(state.owned_cards.size() == count + 1 and state.owned_cards.back() == choice, "选定固定候选后加牌一次");
			page.option_selected.emit("heal", null, -1);
			var result_page:UnexpectedEncounterView = flow.current_page;
			expect(result_page != page and state.status == RunState.RunStatus.UNEXPECTED_RESULT and not state.completed_node_ids.has(node_id), "一次结果显示后仍等待继续，不能重复收益");
			expect(state.current_health == before_health - (8 if kind == UnexpectedEncounterDefinition.Kind.ALTAR else 0), "祭坛只失8当前生命，其余选牌删牌不自带旧回血");
			expect(not state._normal_victory_collection_nodes.has(node_id), "非战斗结果不触发圣杯");
			result_page.option_buttons["continue"].pressed.emit();
			result_page.continue_requested.emit();
			expect(state.completed_node_ids.has(node_id) and flow.current_page is MapView, "继续仅完成一次并返回地图");
		expect(state.node_types == types and state.node_encounters == encounters and state.node_unexpected_encounters == contents and not state.is_invalid(), "流程保持初始化绑定与合法进度");
	expect(ordinary_battles == 2 and state.owned_cards.size() == initial_count + (0 if kind == UnexpectedEncounterDefinition.Kind.FOUNTAIN else 2), "完整支线两战一遇，牌组随真实选择变化");
	(flow.current_page as MapView)._node_views["final_boss"].node_button.pressed.emit();
	var boss:BattleController = flow.current_page.get_node("battle_controller");
	boss.battle_state.enemy_state.take_unblocked_damage(1000);
	boss._check_battle_result();
	expect(flow.current_page is RunResult and state.status == RunState.RunStatus.VICTORY and state.completed_node_ids.size() == 5 and not state.is_invalid(), "完成选线五节点并战胜Boss即可胜利");
	flow.current_page.restart_requested.emit();
	flow.current_page.start_requested.emit();
	expect(flow.run_state != state and flow.run_state.unexpected_candidates.is_empty() and flow.run_state.unexpected_results.is_empty() and flow.run_state.owned_cards.size() == 6, "胜利重开重置不期而遇与牌组");
	flow.get_parent().queue_free();
	await process_frame;

func _test_heal_leave_and_affordability()->void:
	for kind in [UnexpectedEncounterDefinition.Kind.CAMP, UnexpectedEncounterDefinition.Kind.ALTAR, UnexpectedEncounterDefinition.Kind.FOUNTAIN]:
		var flow:GameFlowController = start(config(kind), 0);
		var state:RunState = flow.run_state;
		state.current_health = 8;
		var node_id:String = state.definition.map_definition.get_route_node_ids("a")[0];
		flow._handle_map_node_selected(node_id);
		var page:UnexpectedEncounterView = flow.current_page;
		if kind == UnexpectedEncounterDefinition.Kind.ALTAR:
			expect(page.option_buttons["card"].disabled, "8生命祭坛交换入口禁用");
			page.option_buttons["leave"].pressed.emit();
			expect(state.current_health == 8, "祭坛离开不扣生命");
		else:
			page.option_buttons["heal"].pressed.emit();
			expect(state.current_health == 8 + (15 if kind == UnexpectedEncounterDefinition.Kind.CAMP else 8), "两个治疗实例执行各自数值");
		(flow.current_page as UnexpectedEncounterView).option_buttons["continue"].pressed.emit();
		flow.get_parent().queue_free();
		await process_frame;

func _test_multiple_rewards()->void:
	var definition:RunDefinition = load("res://tests/fixtures/linear_run.tres").duplicate();
	definition.reward_selection_count = 3;
	var main:Node = load("res://main.tscn").instantiate();
	var flow:GameFlowController = main.get_node("game_flow_controller");
	flow.run_definition = definition;
	flow.run_seed = 962000;
	root.add_child(main);
	flow._start_new_run();
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
	flow._handle_map_node_selected("goblin_battle");
	var controller:BattleController = flow.current_page.get_node("battle_controller");
	controller.battle_state.enemy_state.take_unblocked_damage(1000);
	controller._check_battle_result();
	var count:int = flow.run_state.owned_cards.size();
	(flow.current_page as RewardView)._reward_card_views[0].pressed.emit();
	var second:RewardView = flow.current_page;
	second.skip_button.pressed.emit();
	second.reward_skipped.emit();
	expect(flow.current_page is RewardView and flow.run_state.reward_state.remaining_rounds == 1 and flow.run_state.owned_cards.size() == count + 1 and not flow.run_state.completed_node_ids.has("goblin_battle"), "多轮跳过只消耗当前轮，旧信号不跳过下一轮");
	(flow.current_page as RewardView)._reward_card_views[0].pressed.emit();
	expect(flow.current_page is MapView and flow.run_state.owned_cards.size() == count + 2 and flow.run_state.completed_node_ids.has("goblin_battle"), "三轮领取/跳过/领取共得两张并完成节点");
	main.queue_free();
	await process_frame;
