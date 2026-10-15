## 不创建场景，直接验证冒险规则命令与状态守恒。
extends SceneTree

const DEFAULT:RunDefinition = preload("res://run/data/default_run.tres");
var failures:int = 0;

func _initialize()->void:
	call_deferred("_run");

func expect(condition:bool, message:String)->void:
	if not condition:
		failures += 1;
		push_error(message);

func _run()->void:
	_test_fixed_randomness();
	_test_complete_route_and_rewards();
	_test_defeat_and_stale_result();
	_test_events_and_atomic_cost();
	_test_remove_one_copy();
	_test_content_only_extension();
	_test_independent_option_candidates();
	_test_rejected_commands_are_atomic();
	print("RunSession模型检查完成，失败数：%d" % failures);
	quit(1 if failures else 0);

func session_ready(definition:RunDefinition = DEFAULT, seed_value:int = 360101)->RunSession:
	var session:RunSession = RunSession.new();
	expect(session.initialize(definition, seed_value), "合法配置可初始化会话");
	var initial_token:int = session.step_token;
	expect(not session.enter_node(definition.map_definition.starting_node_ids[0]) and session.step_token == initial_token, "构筑前不可推进地图，失败命令不消耗token");
	while session.state.status == RunState.RunStatus.DRAFTING:
		var candidates:Array[CardDefinition] = session.get_draft_candidates();
		var token:int = session.step_token;
		expect(candidates.is_read_only() and candidates == session.get_draft_candidates(), "当前构筑候选固定只读");
		expect(not session.choose_starting_card(candidates[0].duplicate(), token), "同名外部资源不能冒充构筑候选");
		expect(session.choose_starting_card(candidates[0], token), "构筑候选原引用可领取");
		expect(not session.choose_starting_card(candidates[0], token), "旧构筑token不能重复领卡");
		expect(not session.state.is_invalid(), "构筑每轮状态合法");
	if not definition.collection_pool.is_empty():
		expect(session.enter_node(definition.map_definition.starting_node_ids[0], session.step_token), "进入开始节点自动切到藏品选择");
		var selected:CollectionDefinition = definition.collection_pool[0];
		for item in definition.collection_pool:
			if item.effect_type == CollectionDefinition.EffectType.NORMAL_VICTORY_HEAL:
				selected = item;
		var token:int = session.step_token;
		expect(session.choose_collection(selected, token), "藏品选择完成开始节点");
		expect(not session.choose_collection(selected, token), "旧藏品token不能再次领取");
	expect(not session.state.is_invalid(), "开局完成后状态合法");
	return session;

func result_for(session:RunSession, victory:bool = true, health:int = 20, maximum:int = 50)->BattleResult:
	var request:Dictionary = session.get_battle_request();
	var result:BattleResult = BattleResult.new();
	result.battle_id = request["battle_id"];
	result.node_id = request["node_id"];
	result.victory = victory;
	result.player_health = health if victory else 0;
	result.player_max_health = maximum;
	return result;

func _signature(state:RunState)->Array[String]:
	var result:Array[String] = [];
	for node in state.definition.map_definition.nodes:
		var encounter:EncounterDefinition = state.get_node_encounter(node.node_id);
		var event:UnexpectedEncounterDefinition = state.get_unexpected_encounter(node.node_id);
		result.append("%s:%d:%s" % [node.node_id, state.get_node_type(node.node_id), encounter.encounter_id if encounter != null else event.encounter_id if event != null else ""]);
	return result;

func _test_fixed_randomness()->void:
	var first:RunSession = session_ready(DEFAULT, 360111);
	var second:RunSession = session_ready(DEFAULT, 360111);
	expect(_signature(first.state) == _signature(second.state), "显式同seed得到相同地图约束和内容绑定");
	var signature:Array[String] = _signature(first.state);
	for _index in range(100):
		first.state.random.battle.randi();
	for node_id in DEFAULT.map_definition.get_route_node_ids("a"):
		first.enter_node(node_id);
		second.enter_node(node_id);
		if first.state.status == RunState.RunStatus.CHOOSING_UNEXPECTED:
			first.resolve_unexpected("leave");
			second.resolve_unexpected("leave");
			first.continue_unexpected();
			second.continue_unexpected();
		else:
			first.submit_battle_result(result_for(first));
			second.submit_battle_result(result_for(second));
			expect(first.state.reward_state.candidates == second.state.reward_state.candidates, "战斗随机消费不改变冒险奖励随机流");
			break;
	expect(_signature(first.state) == signature, "查询与推进不会重抽地图绑定");

func _test_complete_route_and_rewards()->void:
	var definition:RunDefinition = DEFAULT.duplicate();
	definition.reward_selection_count = 3;
	var session:RunSession = session_ready(definition, 360121);
	var state:RunState = session.state;
	var battles:int = 0;
	var events:int = 0;
	var added:int = 0;
	var initial_count:int = state.owned_cards.size();
	for node_id in definition.map_definition.get_route_node_ids("a"):
		expect(session.enter_node(node_id, session.step_token), "只按所选路线进入下一节点");
		expect(not session.enter_node("route_b_1"), "当前节点处理期间不能换线");
		if state.status == RunState.RunStatus.CHOOSING_UNEXPECTED:
			events += 1;
			var token:int = session.step_token;
			expect(session.resolve_unexpected("leave", null, -1, token), "事件离开生成结构化一次性结果");
			expect(not session.resolve_unexpected("leave", null, -1, token), "事件结果不能重复提交");
			expect(session.continue_unexpected(session.step_token), "确认结果后才完成事件节点");
		else:
			battles += 1;
			expect(state.status == RunState.RunStatus.IN_BATTLE and not state.complete_current_node(), "未接收胜利前战斗节点不能直接完成");
			var request:Dictionary = session.get_battle_request();
			expect(request["owned_cards"].is_read_only() and request["battle_id"] == session.get_battle_request()["battle_id"], "战斗请求身份稳定且牌组快照只读");
			var result:BattleResult = result_for(session, true, 20, 45);
			expect(session.submit_battle_result(result), "合法普通胜利进入奖励");
			var expected_health:int = 20 + state.selected_collection.amount;
			expect(state.current_health == expected_health and state.max_health == 45, "胜利先同步生命上限并仅治疗一次");
			var candidates:Array[CardDefinition] = state.reward_state.candidates;
			var token:int = session.step_token;
			expect(candidates.is_read_only() and state.reward_state.remaining_rounds == 3 and state.reward_state.round_index == 0, "首轮三张固定候选与三轮进度归状态保存");
			expect(not session.choose_reward(candidates[0].duplicate(), token) and session.step_token == token, "伪造奖励卡不发卡或消费轮次");
			expect(not session.submit_battle_result(result) and state.current_health == expected_health and state.reward_state.candidates == candidates, "重复战斗结果不能重放治疗或刷新候选");
			expect(session.skip_reward(token), "跳过只消费当前奖励轮次");
			expect(not session.choose_reward(candidates[0], token) and state.reward_state.remaining_rounds == 2, "上一轮迟到领取不能影响新一轮");
			var choice:CardDefinition = state.reward_state.candidates[0];
			expect(session.choose_reward(choice, session.step_token), "第二轮可领取当前固定候选");
			added += 1;
			expect(session.skip_reward(session.step_token), "第三轮跳过完成节点");
			expect(state.reward_state == null and state.current_node_id.is_empty() and state.reward_history[node_id].selections.size() == 3 and state.current_health == expected_health, "结束奖励推进一次，保留历史且不重放胜利");
		expect(not state.is_invalid(), "每个节点完成后的全局状态合法");
	expect(session.enter_node("final_boss", session.step_token), "三中间节点完成后可进入Boss");
	expect(session.submit_battle_result(result_for(session, true, 3, 45)), "Boss胜利直接结束冒险");
	expect(state.status == RunState.RunStatus.VICTORY and state.completed_node_ids.size() == 5 and state.reward_state == null and state.available_node_ids.is_empty(), "全路线终局无奖励和可进入节点");
	expect(battles == 2 and events == 1 and state.owned_cards.size() == initial_count + added and state.current_health == 3 and not state.is_invalid(), "整局两普通战斗一事件，Boss不触发圣杯");
	expect(not session.skip_reward() and not session.enter_node("start"), "终局不接受旧选择或地图命令");

func _test_defeat_and_stale_result()->void:
	var session:RunSession = session_ready(load("res://tests/fixtures/linear_run.tres"), 360131);
	expect(session.enter_node("goblin_battle"), "旧线性地图可进入实际战斗阶段");
	var wrong:BattleResult = result_for(session);
	wrong.node_id = "rest_site";
	var token:int = session.step_token;
	expect(not session.submit_battle_result(wrong) and session.step_token == token, "错节点战斗结果无副作用");
	var old_result:BattleResult = result_for(session, false);
	expect(session.submit_battle_result(old_result) and session.state.status == RunState.RunStatus.DEFEAT and session.state.current_node_id == "goblin_battle" and session.state.available_node_ids.is_empty(), "合法败北保留失败节点并关闭入口");
	expect(not session.state.is_invalid(), "失败终局状态合法");
	session.initialize(load("res://tests/fixtures/linear_run.tres"), 360131);
	while session.state.status == RunState.RunStatus.DRAFTING:
		session.choose_starting_card(session.get_draft_candidates()[0]);
	session.enter_node("goblin_battle");
	expect(not session.submit_battle_result(old_result) and session.state.status == RunState.RunStatus.IN_BATTLE, "上一局战斗身份不能写入同名新节点");

func event_session(kind:int, seed_value:int = 360141)->RunSession:
	var definition:RunDefinition = DEFAULT.duplicate();
	var content_pool:Array[UnexpectedEncounterDefinition] = [];
	for content in DEFAULT.unexpected_encounter_pool:
		if content.kind == kind:
			content_pool.append(content);
	definition.unexpected_encounter_pool = content_pool;
	return session_at_event(definition, seed_value);

func session_at_event(definition:RunDefinition, seed_value:int)->RunSession:
	var session:RunSession = session_ready(definition, seed_value);
	for node_id in definition.map_definition.get_route_node_ids("a"):
		session.enter_node(node_id);
		if session.state.status == RunState.RunStatus.CHOOSING_UNEXPECTED:
			return session;
		session.submit_battle_result(result_for(session, true, 20));
		while session.state.status == RunState.RunStatus.CHOOSING_REWARD:
			session.skip_reward();
	expect(false, "每条路线必有一个不期而遇");
	return session;

func _test_events_and_atomic_cost()->void:
	var session:RunSession = event_session(UnexpectedEncounterDefinition.Kind.ALTAR);
	var state:RunState = session.state;
	var candidates:Array[CardDefinition] = session.get_unexpected_candidates("card");
	var token:int = session.step_token;
	var count:int = state.owned_cards.size();
	state.current_health = 8;
	expect(not session.get_option_view_data()[0]["enabled"] and not session.resolve_unexpected("card", candidates[0], -1, token), "生命8显示不可支付且规则拒绝提交");
	expect(state.current_health == 8 and state.owned_cards.size() == count and state.unexpected_results.is_empty() and session.step_token == token, "支付失败无部分收益及状态推进");
	state.current_health = 9;
	expect(not session.resolve_unexpected("card", candidates[0].duplicate(), -1, token), "同名祭坛伪候选不扣血");
	expect(session.get_unexpected_candidates("card") == candidates and session.resolve_unexpected("card", candidates[0], -1, token), "候选查询不重抽且确认才支付8同步领卡");
	expect(state.current_health == 1 and state.owned_cards.size() == count + 1 and not state.unexpected_results[state.current_node_id].has("summary"), "模型保留结构化结果而非拼接UI文本");
	var display:Dictionary = session.get_unexpected_result_view_data();
	expect(display["health_cost"] == 8 and display["card_name"] == candidates[0].card_name and not display["template"].is_empty(), "结果查询提供配置模板与真实结果字段");
	expect(not session.resolve_unexpected("card", candidates[0], -1, token) and state.current_health == 1, "旧输入不能再次支付");
	expect(session.continue_unexpected(session.step_token) and not state.is_invalid(), "祭坛结果完成一次且状态合法");
	session = event_session(UnexpectedEncounterDefinition.Kind.CAMP);
	state = session.state;
	state.current_health = 42;
	state.max_health = 49;
	var healed_nodes:int = state._normal_victory_collection_nodes.size();
	expect(session.resolve_unexpected("heal", null, -1, session.step_token), "营地执行配置的治疗操作");
	expect(state.current_health == 49 and session.last_command_result["actual_heal"] == 7 and state._normal_victory_collection_nodes.size() == healed_nodes, "治疗封顶报告实际值且事件不触发圣杯");

func _test_remove_one_copy()->void:
	var session:RunSession = event_session(UnexpectedEncounterDefinition.Kind.FOUNTAIN);
	var state:RunState = session.state;
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	var copies:int = state.owned_cards.count(strike);
	var index:int = state.owned_cards.find(strike, state.owned_cards.find(strike) + 1);
	var count:int = state.owned_cards.size();
	expect(index >= 0, "开局含多份同名牌作为删副本验证");
	expect(not session.resolve_unexpected("remove", state.owned_cards.back(), index, session.step_token), "索引目标引用不匹配不可删除");
	expect(session.resolve_unexpected("remove", strike, index, session.step_token) and state.owned_cards.count(strike) == copies - 1 and state.owned_cards.size() == count - 1 and session.last_command_result["removed_deck_index"] == index, "删除实际选择索引的一份而非按名字删全部");
	session = event_session(UnexpectedEncounterDefinition.Kind.FOUNTAIN);
	session.state.owned_cards = [strike];
	expect(not session.get_option_view_data()[0]["enabled"] and not session.resolve_unexpected("remove", strike, 0), "最后一张受规则及界面资格查询保护");
	expect(session.resolve_unexpected("leave"), "不能删牌仍可无代价离开");

func _test_content_only_extension()->void:
	var content:UnexpectedEncounterDefinition = UnexpectedEncounterDefinition.new();
	content.encounter_id = "test_new_content";
	content.display_name = "测试旅人";
	content.story = "新的内容只组合既有操作。";
	var rest:UnexpectedEncounterOptionDefinition = UnexpectedEncounterOptionDefinition.new();
	rest.option_id = "recover_new";
	rest.label = "旅人施药";
	rest.result_text = "恢复{actual_heal}";
	rest.operation = UnexpectedEncounterOptionDefinition.Operation.HEAL;
	rest.heal_amount = 4;
	var leave:UnexpectedEncounterOptionDefinition = UnexpectedEncounterOptionDefinition.new();
	leave.option_id = "decline_new";
	leave.label = "继续旅途";
	leave.result_text = "你继续旅途。";
	content.options = [rest, leave];
	var definition:RunDefinition = DEFAULT.duplicate();
	definition.unexpected_encounter_pool = [content];
	expect(not definition.is_invalid(), "新实例仅配置选项即可加入现有池，无需Kind规则");
	var session:RunSession = session_at_event(definition, 360161);
	session.state.current_health = 20;
	var queries:Array[Dictionary] = session.get_option_view_data();
	expect(queries.size() == 2 and queries[0]["option_id"] == "recover_new" and queries[0]["selection_kind"] == UnexpectedEncounterOptionDefinition.SelectionKind.NONE, "通用查询返回新内容任意选项ID和操作方式");
	expect(session.resolve_unexpected("recover_new") and session.state.current_health == 24 and session.get_unexpected_result_view_data()["template"] == rest.result_text, "局部执行器不认识内容名也能执行既有治疗操作");

func _test_independent_option_candidates()->void:
	var content:UnexpectedEncounterDefinition = UnexpectedEncounterDefinition.new();
	content.encounter_id = "test_two_choices";
	content.display_name = "双卷轴";
	content.story = "每组选牌选项保存自己的固定候选。";
	var common:UnexpectedEncounterOptionDefinition = UnexpectedEncounterOptionDefinition.new();
	common.option_id = "learn_common";
	common.label = "普通技艺";
	common.result_text = "获得{card_name}";
	common.operation = UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD;
	common.card_rarities = [CardDefinition.CardRarity.COMMON];
	common.excluded_card_ids = ["strike", "defend"];
	var rare:UnexpectedEncounterOptionDefinition = UnexpectedEncounterOptionDefinition.new();
	rare.option_id = "learn_rare";
	rare.label = "稀有技艺";
	rare.result_text = "获得{card_name}";
	rare.operation = UnexpectedEncounterOptionDefinition.Operation.GAIN_CARD;
	rare.card_rarities = [CardDefinition.CardRarity.RARE];
	var leave:UnexpectedEncounterOptionDefinition = UnexpectedEncounterOptionDefinition.new();
	leave.option_id = "leave";
	leave.label = "离开";
	leave.result_text = "继续旅途。";
	content.options = [common, rare, leave];
	var definition:RunDefinition = DEFAULT.duplicate();
	definition.unexpected_encounter_pool = [content];
	var session:RunSession = session_at_event(definition, 360171);
	var common_cards:Array[CardDefinition] = session.get_unexpected_candidates(common.option_id);
	var rare_cards:Array[CardDefinition] = session.get_unexpected_candidates(rare.option_id);
	var token:int = session.step_token;
	expect(common_cards.size() == 3 and rare_cards.size() == 3 and common_cards.is_read_only() and rare_cards.is_read_only(), "同节点不同选项分别保存三张候选");
	expect(session.state.unexpected_candidates[session.state.current_node_id] == common_cards and not session.state.is_invalid(), "第一组兼容候选与完整按选项状态同时合法");
	expect(not session.resolve_unexpected(rare.option_id, common_cards[0], -1, token), "其他选项的合法候选也不能跨组选入");
	expect(session.get_unexpected_candidates(rare.option_id) == rare_cards and session.resolve_unexpected(rare.option_id, rare_cards[0], -1, token), "拒绝跨组候选不重抽，当前组选牌可提交");
	expect(not session.resolve_unexpected(common.option_id, common_cards[0]) and not session.state.is_invalid(), "选定一项后整个节点只提交一次");

func _test_rejected_commands_are_atomic()->void:
	var session:RunSession = session_ready(DEFAULT, 360181);
	var state:RunState = session.state;
	var entry_id:String = DEFAULT.map_definition.get_route_node_ids("a")[0];
	var original_types:Dictionary = state.node_types;
	var changed_types:Dictionary = original_types.duplicate();
	changed_types[entry_id] = MapNodeDefinition.NodeType.ROUTE_SLOT;
	state.node_types = changed_types;
	var token:int = session.step_token;
	var available:Array[String] = state.available_node_ids.duplicate();
	var random_state:int = state.random.run.state;
	expect(not session.enter_node(entry_id, token) and state.available_node_ids == available and state.current_node_id.is_empty() and state.selected_route_id.is_empty() and session.step_token == token and state.random.run.state == random_state, "无法执行的节点类型不先占节点、选线或推进随机流");
	state.node_types = original_types;
	var linear:RunSession = session_ready(load("res://tests/fixtures/linear_run.tres"), 360182);
	linear.enter_node("goblin_battle");
	var result:BattleResult = result_for(linear, true, 0);
	var health:int = linear.state.current_health;
	var active:String = linear.state.active_battle_id;
	token = linear.step_token;
	random_state = linear.state.random.run.state;
	expect(not linear.submit_battle_result(result) and linear.state.current_health == health and linear.state.active_battle_id == active and linear.state.processed_battle_results.is_empty() and linear.state.reward_state == null and linear.step_token == token and linear.state.random.run.state == random_state, "不一致胜利生命的失败提交完全保留战斗与随机状态");
