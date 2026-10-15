extends SceneTree

var failures:int = 0;
const DEFAULT:RunDefinition = preload("res://run/data/default_run.tres");

func _initialize()->void:
	call_deferred("_run");

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1;
		push_error(message);

func drafted(definition:RunDefinition = DEFAULT)->RunState:
	var state:RunState = RunState.new();
	expect(state.run_state_init(definition), "第六阶段配置能够创建新局");
	for rarity in RunDefinition.DRAFT_RARITIES:
		state.choose_starting_card(CardPoolSampler.filter_pool(definition.character_definition.reward_card_pool, [rarity])[0]);
	state.enter_node("start");
	state.begin_collection_selection();
	state.choose_collection(definition.collection_pool[0]);
	return state;

func event_state(kind:int)->RunState:
	var definition:RunDefinition = DEFAULT.duplicate();
	for content in DEFAULT.unexpected_encounter_pool:
		if content.kind == kind:
			var pool:Array[UnexpectedEncounterDefinition] = [];
			pool.append(content);
			definition.unexpected_encounter_pool = pool;
	seed(960020 + kind);
	var state:RunState = drafted(definition);
	for node_id in definition.map_definition.get_route_node_ids("a"):
		expect(state.enter_node(node_id), "按路线顺序进入节点");
		if state.get_node_type(node_id) == MapNodeDefinition.NodeType.UNEXPECTED:
			break;
		expect(state.complete_current_node(), "模型检查推进此前普通节点");
	expect(not state.complete_current_node(), "尚未选择的不期而遇不可直接完成");
	expect(state.begin_unexpected_encounter(), "进入不期而遇并生成固定候选");
	return state;

func _run()->void:
	_test_random_bindings();
	_test_camp();
	_test_altar();
	_test_fountain();
	_test_reset_and_legacy();
	print("第六阶段局内状态检查完成，失败数：%d" % failures);
	quit(1 if failures else 0);

func _test_random_bindings()->void:
	var map:MapDefinition = DEFAULT.map_definition;
	var original_types:Array[int] = [];
	for node in map.nodes:
		original_types.append(node.node_type);
	var positions:Dictionary = {};
	var contents:Dictionary = {};
	var repeated:bool = false;
	for sample in range(72):
		seed(960000 + sample);
		var state:RunState = drafted();
		expect(state.node_types.size() == 9 and state.node_types.is_read_only() and state.node_encounters.size() == 7 and state.node_encounters.is_read_only() and state.node_unexpected_encounters.size() == 3 and state.node_unexpected_encounters.is_read_only(), "9位置类型与7战斗和3实例一次性只读绑定");
		expect(state.get_node_type("start") == MapNodeDefinition.NodeType.START and state.get_node_type("final_boss") == MapNodeDefinition.NodeType.BOSS, "开始与Boss类型固定");
		var event_ids:Array[String] = [];
		for route in map.get_route_ids():
			var battle_ids:Array[String] = [];
			var event_count:int = 0;
			var nodes:Array[String] = map.get_route_node_ids(route);
			for index in range(nodes.size()):
				var node_id:String = nodes[index];
				if state.node_requires_encounter(node_id):
					battle_ids.append(state.get_node_encounter(node_id).enemy_definition.combatant_id);
				else:
					event_count += 1;
					positions[index] = true;
					var content:UnexpectedEncounterDefinition = state.get_unexpected_encounter(node_id);
					expect(content != null and state.get_node_encounter(node_id) == null, "不期而遇只绑定内容，不伪装战斗");
					contents[content.encounter_id] = true;
					event_ids.append(content.encounter_id);
			expect(battle_ids.size() == 2 and battle_ids[0] != battle_ids[1] and event_count == 1, "每路两战斗不重复并有一个不期而遇");
		if event_ids[0] == event_ids[1] or event_ids[1] == event_ids[2] or event_ids[0] == event_ids[2]:
			repeated = true;
		expect(not state.is_invalid(), "随机状态校验合法");
	expect(positions.size() == 3 and contents.size() == 3 and repeated, "固定样本覆盖三种位置与三个内容，跨路线允许重复");
	for index in range(map.nodes.size()):
		expect(map.nodes[index].node_type == original_types[index] and (map.nodes[index].route_id.is_empty() or map.nodes[index].heal_amount == 0), "随机结果不回写地图且没有旧自动15回血");

func _test_camp()->void:
	var state:RunState = event_state(UnexpectedEncounterDefinition.Kind.CAMP);
	var node_id:String = state.current_node_id;
	var candidates:Array = state.unexpected_candidates[node_id];
	expect(candidates.size() == 3 and candidates.is_read_only(), "营地保存三张固定普通候选");
	for card in candidates:
		expect(card.rarity == CardDefinition.CardRarity.COMMON and card.card_id not in ["strike", "defend"], "营地不提供基础打击防御");
	expect(state.begin_unexpected_encounter() and state.unexpected_candidates[node_id] == candidates, "重复准备不重抽候选");
	state.current_health = 42;
	state.max_health = 49;
	var count:int = state.owned_cards.size();
	expect(state.resolve_unexpected_encounter("heal") and state.current_health == 49 and state.max_health == 49 and state.unexpected_results[node_id]["actual_heal"] == 7, "營地按运行时最大生命封顶，只恢复实际7点");
	expect(not state.resolve_unexpected_encounter("card", candidates[0]) and state.owned_cards.size() == count, "结果不可重复选择或同时领卡");
	expect(not state.complete_current_node() and state.continue_unexpected_encounter() and not state.continue_unexpected_encounter() and not state.is_invalid(), "结果页确认继续后仅完成一次");
	state = event_state(UnexpectedEncounterDefinition.Kind.CAMP);
	state.current_health = 20;
	var choice:CardDefinition = state.unexpected_candidates[state.current_node_id][0];
	expect(not state.resolve_unexpected_encounter("card", choice.duplicate()), "同名外部卡不是候选原引用");
	expect(state.resolve_unexpected_encounter("card", choice) and state.current_health == 20 and state.owned_cards.back() == choice and state.owned_cards.size() == count + 1, "营地选牌不自动恢复15生命");

func _test_altar()->void:
	var state:RunState = event_state(UnexpectedEncounterDefinition.Kind.ALTAR);
	var choice:CardDefinition = state.unexpected_candidates[state.current_node_id][0];
	for card in state.unexpected_candidates[state.current_node_id]:
		expect(card.rarity in [CardDefinition.CardRarity.RARE, CardDefinition.CardRarity.EPIC], "祭坛候选仅来自合并稀有史诗池");
	var count:int = state.owned_cards.size();
	state.current_health = 8;
	expect(not state.resolve_unexpected_encounter("card", choice) and state.current_health == 8 and state.owned_cards.size() == count and state.unexpected_results.is_empty(), "生命8不能支付，不扣生命且无部分收益");
	state.current_health = 9;
	expect(state.resolve_unexpected_encounter("card", choice) and state.current_health == 1 and state.owned_cards.size() == count + 1, "生命9支付8后存活并同期加牌");
	expect(not state.resolve_unexpected_encounter("card", choice) and state.current_health == 1 and not state.is_invalid(), "祭坛支付仅一次");
	state = event_state(UnexpectedEncounterDefinition.Kind.ALTAR);
	state.current_health = 1;
	expect(state.resolve_unexpected_encounter("leave") and state.current_health == 1 and state.owned_cards.size() == count, "低生命可离开无代价");

func _test_fountain()->void:
	var state:RunState = event_state(UnexpectedEncounterDefinition.Kind.FOUNTAIN);
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	var count:int = state.owned_cards.size();
	var copies:int = state.owned_cards.count(strike);
	var index:int = state.owned_cards.find(strike);
	expect(not state.resolve_unexpected_encounter("remove", strike, -1) and not state.resolve_unexpected_encounter("remove", state.owned_cards.back(), index), "无效位置或目标不匹配不能删牌");
	expect(state.resolve_unexpected_encounter("remove", strike, index) and state.owned_cards.size() == count - 1 and state.owned_cards.count(strike) == copies - 1, "只删除选中的同名一份");
	expect(not state.resolve_unexpected_encounter("remove", strike, index) and state.current_health == state.max_health, "重复删牌无效且泉水删牌不额外回血");
	state = event_state(UnexpectedEncounterDefinition.Kind.FOUNTAIN);
	state.current_health = 40;
	state.max_health = 45;
	expect(state.resolve_unexpected_encounter("heal") and state.current_health == 45 and state.unexpected_results[state.current_node_id]["actual_heal"] == 5, "泉水恢复8按实际上限封顶");
	state = event_state(UnexpectedEncounterDefinition.Kind.FOUNTAIN);
	state.owned_cards = [strike];
	expect(not state.resolve_unexpected_encounter("remove", strike, 0), "保留最后一张卡，避免创建空战斗牌组");
	expect(state.resolve_unexpected_encounter("leave") and state.owned_cards.size() == 1, "无法删最后一张时仍可离开");

func _test_reset_and_legacy()->void:
	var state:RunState = event_state(UnexpectedEncounterDefinition.Kind.CAMP);
	state.selected_collection = load("res://collections/data/ember_chalice.tres");
	expect(state.apply_normal_victory_collection() == 0 and state._normal_victory_collection_nodes.is_empty(), "不期而遇不触发圣杯");
	state.resolve_unexpected_encounter("leave");
	expect(state.node_unexpected_encounters.values()[0] == state.node_unexpected_encounters.values()[1] and state.unexpected_candidates.size() == 1 and state.unexpected_results.size() == 1, "跨路线可绑定同一只读定义，但只为实际进入位置保存独立候选与结果");
	expect(state.run_state_init(DEFAULT) and state.unexpected_candidates.is_empty() and state.unexpected_results.is_empty() and state.current_health == 50 and state.owned_cards.size() == 6, "新局清除候选结果与旧牌组生命");
	var legacy:RunState = RunState.new();
	expect(legacy.run_state_init(load("res://tests/fixtures/phase5_run.tres")) and legacy.node_types.is_empty() and legacy.get_node_type("route_a_rest") == MapNodeDefinition.NodeType.REST, "第五阶段静态分支仍兼容");
	expect(legacy.run_state_init(load("res://tests/fixtures/linear_run.tres")) and legacy.node_types.is_empty(), "旧线性地图仍兼容");
