## 六张正式稀有卡的资源、组合结算、奖励到下一战与卡面文字检查。
extends SceneTree

## 本组检查覆盖的六张正式稀有卡标识。
const CARD_IDS:Array[String] = ["battle_trance", "ancient_ritual", "strength_power", "open_wound", "thorns", "uppercut"];
## 本次检查累计的失败次数，用于汇总和设置进程退出状态。
var _failures:int = 0;


## 延迟运行检查，使场景树完成初始化后再创建测试场景。
func _initialize()->void:
	_run.call_deferred();


## 运行战士稀有卡牌检查，输出汇总并以失败数决定进程退出状态。
func _run()->void:
	_test_catalog();
	_test_draw_restriction();
	_test_energy_and_strength();
	_test_damage_and_statuses();
	_test_reward_to_next_battle();
	await _test_card_text();
	await process_frame;
	await create_timer(0.5).timeout; # 仅等待已释放播放器的混音线程收尾。
	print("战士正式稀有卡检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


## 条件不成立时累计失败次数并报告指定消息；不立即中止后续检查。
func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


## 按标识加载正式卡牌定义。
func _card(id:String)->CardDefinition:
	return load("res://cards/data/%s.tres" % id);


## 挂载正式战斗页面，以指定牌组启动稀有卡测试。
func _controller(cards:Array[CardDefinition])->BattleController:
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), cards, 50, 50), "正式卡测试战斗应启动");
	return controller;


## 按定义引用查找指定战斗状态的手牌；未找到时返回 [code]null[/code]。
func _in_hand(state:BattleState, definition:CardDefinition)->CardInstance:
	for card in state.hand:
		if card.definition == definition:
			return card;
	return null;


## 验证正式稀有卡资源身份、费用、类型、卡池归属及稀有度分组。
func _test_catalog()->void:
	var character:CharacterDefinition = load("res://characters/data/warrior.tres");
	_expect(not character.is_invalid() and character.reward_card_pool.size() == 27, "战士卡池包含9张普通、6张稀有、8张史诗、4张传说，ID均唯一且资源合法");
	var expected_names:Array[String] = ["背水一战", "古代仪典", "力量！！！", "开放性伤口", "荆棘", "上勾拳！"];
	var expected_costs:Array[int] = [0, 1, 1, 2, 1, 2];
	var expected_types:Array[int] = [1, 1, 2, 0, 1, 0];
	for index in range(CARD_IDS.size()):
		var card:CardDefinition = _card(CARD_IDS[index]);
		_expect(card.card_id == CARD_IDS[index] and card.card_name == expected_names[index] and not card.is_invalid(), "正式卡ID、名称与资源合法性正确");
		_expect(card.rarity == CardDefinition.CardRarity.RARE and card.base_energy_cost == expected_costs[index] and card.card_type == expected_types[index], "稀有度、费用和类型符合草案");
		_expect(card.exhausts_on_play == (card.card_id == "ancient_ritual") and not card.is_innate and not card.retains_on_turn_end, "只给古代仪典消耗，不额外添加词条");
		_expect(character.reward_card_pool.has(card), "新卡已进入正式角色卡池");
	_expect(CardPoolSampler.filter_pool(character.reward_card_pool, [CardDefinition.CardRarity.RARE]).size() == 6, "稀有分组现在具备6张正式候选");


## 验证正式背水一战先抽牌后禁抽、正常弃置及下一回合解禁。
func _test_draw_restriction()->void:
	var definition:CardDefinition = _card("battle_trance");
	var deck:Array[CardDefinition] = [definition];
	for index in range(7):
		deck.append(_card("defend"));
	var controller:BattleController = _controller(deck);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = _in_hand(state, definition);
	# 只在测试中换一个起手位置，固定待测卡；保留全部原实例及正式词条。
	if card == null:
		for candidate in state.draw_pile:
			if candidate.definition == definition:
				card = candidate;
				break;
		state.draw_pile.erase(card);
		state.draw_pile.append(state.hand.pop_back());
		state.hand.append(card);
	controller._on_card_selected(card);
	_expect(state.hand.size() == 7 and state.draw_blocked_this_turn and state.current_available_energy == 3, "正式背水一战0费，先抽3张再禁抽");
	_expect(state.discard_pile.has(card) and not state.is_invalid_battle(), "技能正常弃置，牌区守恒");
	controller._on_end_turn_button_pressed();
	_expect(not state.draw_blocked_this_turn and state.hand.size() == 5, "正式卡带来的限制在下一回合解除");
	controller.get_parent().queue_free();


## 验证古代仪典支付后回能并消耗，以及力量能力牌的支付、归档和后续伤害。
func _test_energy_and_strength()->void:
	var ritual:CardDefinition = _card("ancient_ritual");
	var strength:CardDefinition = _card("strength_power");
	var controller:BattleController = _controller([ritual, strength, _card("strike")]);
	var state:BattleState = controller.battle_state;
	var ritual_card:CardInstance = _in_hand(state, ritual);
	controller._on_card_selected(ritual_card);
	_expect(state.current_available_energy == 5 and state.exhaust_pile.has(ritual_card), "古代仪典先支付1再获得3，净增2且消耗");
	var strength_card:CardInstance = _in_hand(state, strength);
	controller._on_card_selected(strength_card);
	_expect(state.current_available_energy == 4 and state.player_state.strength == 2 and state.played_power_cards.has(strength_card), "力量！！！支付1获得2力量，按能力牌归档");
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 22 and state.player_state.powers.is_empty(), "后续攻击加2伤害，即时力量无需创建持续能力记录");
	controller.get_parent().queue_free();


## 验证正式伤害与减益卡的目标、数值、效果顺序和普通弃置。
func _test_damage_and_statuses()->void:
	for values in [["open_wound", 2, 8, 0, 2, 0], ["thorns", 1, 0, 7, 1, 0], ["uppercut", 2, 13, 0, 1, 1]]:
		var definition:CardDefinition = _card(values[0]);
		var controller:BattleController = _controller([definition]);
		var state:BattleState = controller.battle_state;
		controller._on_card_selected(state.hand[0]);
		_expect(state.current_available_energy == 3 - values[1] and state.enemy_state.current_health == 30 - values[2], "伤害先于本牌易伤，伤害与费用符合草案：%s" % values[0]);
		_expect(state.player_state.current_block == values[3] and state.enemy_state.vulnerable_turns == values[4] and state.enemy_state.weak_turns == values[5], "格挡给自己，易伤／虚弱给敌人：%s" % values[0]);
		_expect(state.player_state.vulnerable_turns == 0 and state.player_state.weak_turns == 0 and state.discard_pile.size() == 1, "不误给玩家减益，卡牌正常弃置");
		controller.get_parent().queue_free();


## 验证开局与奖励获得的正式稀有卡进入后续战斗，且不污染源角色卡池。
func _test_reward_to_next_battle()->void:
	for id in CARD_IDS:
		var definition:CardDefinition = _card(id);
		var main:Node = load("res://main.tscn").instantiate();
		var flow:GameFlowController = main.get_node("game_flow_controller");
		flow.run_definition = load("res://tests/fixtures/linear_run.tres").duplicate();
		flow.run_definition.character_definition = flow.run_definition.character_definition.duplicate();
		# 缩小测试候选池，保证逐张验证实际卡牌；正式角色配置不变。
		flow.run_definition.character_definition.reward_card_pool = [definition, _card("heavy_strike"), _card("lethal_blade"), _card("fortress")];
		root.add_child(main);
		flow._start_new_run();
		for _round in range(3):
			(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
		flow._handle_map_node_selected("goblin_battle");
		var controller:BattleController = flow.current_page.get_node("battle_controller");
		controller.battle_state.enemy_state.take_unblocked_damage(100);
		controller._check_battle_result();
		for index in range(flow.run_definition.reward_selection_count):
			var reward:RewardView = flow.current_page as RewardView;
			for view in reward._reward_card_views:
				if view.card_definition == definition:
					_expect(not view.card_face.description_label.text.contains("{damage_"), "实际奖励页正确填入伤害文案");
					view.pressed.emit();
					break;
		_expect(flow.run_state.owned_cards.count(definition) == 2 and flow.run_state.owned_cards.size() == 10, "开局选择与战后奖励各获得一张同种新卡");
		flow._handle_map_node_selected("rest_site");
		flow._handle_map_node_selected("ruin_guard_boss");
		controller = flow.current_page.get_node("battle_controller");
		var instances:Array[CardInstance] = [];
		for card in controller.battle_state.hand + controller.battle_state.draw_pile:
			if card.definition == definition:
				instances.append(card);
		_expect(instances.size() == 2 and instances[0] != instances[1], "下一战为奖励获得的每张卡创建独立实例");
		main.queue_free();
	_expect(load("res://characters/data/warrior.tres").reward_card_pool.size() == 27, "整局测试不修改正式角色卡池");


## 验证正式稀有卡在候选和手牌中的完整文案及基础伤害替换。
func _test_card_text()->void:
	var views:Array[Control] = [];
	for id in CARD_IDS:
		var definition:CardDefinition = _card(id);
		var reward:CardChoiceView = load("res://ui/cards/card_choice_view.tscn").instantiate();
		root.add_child(reward);
		reward.setup(definition);
		_expect(reward.card_definition == definition, "正式卡可显示为奖励卡");
		views.append(reward);
		var hand:CardView = load("res://cards/card_view.tscn").instantiate();
		hand.size = Vector2(140, 200);
		root.add_child(hand);
		var instance:CardInstance = CardInstance.new();
		instance.card_instance_init(definition);
		hand.bind_card_instance(instance);
		_expect(hand.card_instance == instance, "正式卡可显示为战斗手牌");
		views.append(hand);
	await process_frame;
	await process_frame;
	for view in views:
		var description:RichTextLabel = view.get_node("card_face/description_label");
		_expect(description.get_content_height() <= description.size.y, "正式卡基础文案不能超出描述区：%s" % view.get_node("card_face/name_label").text);
		_expect(not description.text.contains("{damage_"), "基础卡面无未替换伤害占位符");
		view.queue_free();
