## 剩余草案卡的正式配置、组合结算、真实分页选择与奖励流转。
extends SceneTree

const NEW_IDS:Array[String] = ["shield_slam", "blood_sacrifice", "technical_fighting", "overpower", "blood_cloak", "pommel_strike", "iron_wave", "shrug_it_off", "intimidate", "trade_wounds"];
var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_catalog();
	_test_simple_cards();
	_test_draw_cards();
	_test_shield_slam();
	_test_blood_sacrifice();
	_test_cloak();
	_test_trade_wounds();
	await _test_draft_and_rewards();
	await _test_text();
	await process_frame;
	# 驻留音乐停止后，混音线程需要完成OGG播放实例的异步释放。
	await create_timer(0.5).timeout;
	print("剩余战士草案卡检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _card(id:String)->CardDefinition:
	return load("res://cards/data/%s.tres" % id);


func _controller(cards:Array[CardDefinition])->BattleController:
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	# 使用独立40生命对手验证卡牌结算，不依赖正式Boss的平衡血量。
	var encounter:EncounterDefinition = load("res://battle/data/encounters/ruin_guard_encounter.tres").duplicate();
	var enemy:EnemyDefinition = encounter.enemy_definition.duplicate();
	enemy.max_health = 40;
	encounter.enemy_definition = enemy;
	_expect(controller.start_battle(encounter, load("res://combatants/data/player.tres"), cards, 50, 50), "正式卡测试使用独立40生命对手");
	return controller;


## 固定测试起手，不给资源追加固有，也不复制或删除实例。
func _put_in_hand(state:BattleState, id:String)->CardInstance:
	for card in state.hand:
		if card.definition.card_id == id:
			return card;
	for card in state.draw_pile:
		if card.definition.card_id == id:
			state.draw_pile.erase(card);
			state.draw_pile.append(state.hand.pop_back());
			state.hand.append(card);
			return card;
	return null;


func _test_catalog()->void:
	var character:CharacterDefinition = load("res://characters/data/warrior.tres");
	var names:Array[String] = ["盾牌猛击", "血祭", "技巧型格斗", "力量碾压", "血红披风", "剑柄打击", "铁斩波", "耸肩无视", "颤栗", "以伤换伤"];
	var types:Array[int] = [0, 1, 1, 0, 2, 0, 0, 1, 1, 1];
	_expect(not character.is_invalid() and character.reward_card_pool.size() == 27, "24张草案加3张旧卡，总池27张且合法");
	for index in range(NEW_IDS.size()):
		var card:CardDefinition = _card(NEW_IDS[index]);
		_expect(character.reward_card_pool.has(card) and card.card_name == names[index] and card.card_id == NEW_IDS[index] and not card.is_invalid(), "正式资源身份正确且入池");
		_expect(card.card_type == types[index] and card.rarity == (2 if index < 5 else 0) and card.base_energy_cost == (3 if index == 3 else 1), "类型、稀有度、费用符合草案");
		_expect(card.exhausts_on_play == (index in [2, 8]) and not card.is_innate and not card.retains_on_turn_end, "只有技巧型格斗与颤栗打出消耗，不把血祭的减少上限当作消耗词条");
	for pair in [[0, 9], [1, 6], [2, 8], [3, 4]]:
		_expect(CardPoolSampler.filter_pool(character.reward_card_pool, [pair[0]]).size() == pair[1], "卡池稀有度数量正确");
	_expect(_card("double_strike").effects[0].amount == 5 and _card("double_strike").effects[0].repeat_count == 2, "双重打击更新为5点两次");


func _test_simple_cards()->void:
	for values in [["overpower", 3, 32, 0, 0], ["iron_wave", 1, 5, 5, 0], ["intimidate", 1, 0, 0, 3], ["double_strike", 1, 10, 0, 0]]:
		var controller:BattleController = _controller([_card(values[0])]);
		var state:BattleState = controller.battle_state;
		var card:CardInstance = state.hand[0];
		controller._on_card_selected(card);
		_expect(state.current_available_energy == 3 - values[1] and state.enemy_state.current_health == 40 - values[2] and state.player_state.current_block == values[3] and state.enemy_state.vulnerable_turns == values[4], "正式卡数值与目标正确：%s" % values[0]);
		_expect((state.exhaust_pile.has(card) if values[0] == "intimidate" else state.discard_pile.has(card)) and not state.is_invalid_battle(), "普通弃置或消耗归档正确");
		controller.get_parent().queue_free();


func _test_draw_cards()->void:
	for values in [["pommel_strike", 9, 0, 0, 1], ["shrug_it_off", 0, 8, 0, 1], ["technical_fighting", 0, 0, 2, 3]]:
		var deck:Array[CardDefinition] = [_card(values[0])];
		for index in range(8):
			deck.append(_card("defend"));
		var controller:BattleController = _controller(deck);
		var state:BattleState = controller.battle_state;
		var card:CardInstance = _put_in_hand(state, values[0]);
		controller._on_card_selected(card);
		_expect(state.enemy_state.current_health == 40 - values[1] and state.player_state.current_block == values[2] and state.enemy_state.weak_turns == values[3] and state.player_state.weak_turns == 0, "伤害/格挡/敌人虚弱目标正确：%s" % values[0]);
		_expect(state.hand.size() == 4 + values[4] and state.current_available_energy == 2, "1费抽牌数量正确，正在打出的牌不抽回");
		_expect((state.exhaust_pile.has(card) if values[0] == "technical_fighting" else state.discard_pile.has(card)) and not state.is_invalid_battle(), "抽牌后归档正确且牌区守恒");
		controller.get_parent().queue_free();


func _test_shield_slam()->void:
	var controller:BattleController = _controller([_card("shield_slam")]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_block(10);
	state.player_state.gain_strength(2);
	state.player_state.apply_weak(1, false);
	state.enemy_state.apply_vulnerable(1, false);
	controller._refresh_battle_view();
	var view:CardView = controller.hand_area.get_child(0);
	_expect(view.card_face.description_label.text.contains("13点伤害"), "盾牌猛击按格挡10+力量2再乘倍率，预览13");
	controller._on_card_selected(state.hand[0]);
	_expect(state.enemy_state.current_health == 27 and state.player_state.current_block == 10, "实际伤害13且不消耗自己的格挡");
	_expect(_card("shield_slam").format_description().contains("X点伤害"), "非战斗界面动态值显示X");
	controller.get_parent().queue_free();


func _test_blood_sacrifice()->void:
	var controller:BattleController = _controller([_card("blood_sacrifice")]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	controller._on_card_selected(card);
	_expect(state.player_state.max_health == 49 and state.player_state.current_health == 49 and state.player_state.current_block == 14 and state.discard_pile.has(card), "血祭减少上限1，满血压到49，获得14格挡且普通弃置");
	controller.get_parent().queue_free();
	controller = _controller([_card("blood_sacrifice")]);
	state = controller.battle_state;
	state.player_state.max_health = 1;
	state.player_state.current_health = 1;
	controller._on_card_selected(state.hand[0]);
	_expect(state.hand.size() == 1 and state.current_available_energy == 3 and state.player_state.current_block == 0, "上限1时拒绝打出，不扣费用");
	controller.get_parent().queue_free();


func _test_cloak()->void:
	var controller:BattleController = _controller([_card("blood_cloak"), _card("blood_cloak"), _card("defend")]);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(_put_in_hand(state, "blood_cloak"));
	controller._on_card_selected(_put_in_hand(state, "blood_cloak"));
	_expect(state.player_state.current_health == 50 and state.player_state.current_block == 0 and state.played_power_cards.size() == 2, "两张披风打出时只注册并归档");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_health == 48 and state.player_state.current_block == 20 and state.hand.size() == 1, "敌人首轮仅格挡，下个玩家回合两份披风依次失血换格挡，存活后抽牌");
	controller.get_parent().queue_free();


func _test_trade_wounds()->void:
	var controller:BattleController = _controller([_card("trade_wounds")]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_block(7);
	state.player_state.gain_strength(2);
	state.player_state.apply_weak(1, false);
	state.enemy_state.apply_vulnerable(1, false);
	state.attack_card_energy_this_turn = 2;
	controller._on_card_selected(state.hand[0]);
	_expect(state.player_state.current_health == 49 and state.player_state.current_block == 7 and state.enemy_state.current_health == 25, "失血不扣格挡；12+2后乘0.75与1.5取整，伤害15");
	_expect(state.current_available_energy == 2 and state.discard_pile.size() == 1, "技能造成攻击伤害，但不触发攻击牌回能且不消耗");
	controller.get_parent().queue_free();
	controller = _controller([_card("trade_wounds")]);
	state = controller.battle_state;
	state.player_state.current_health = 1;
	controller._on_card_selected(state.hand[0]);
	_expect(state.is_defeat() and state.enemy_state.current_health == 40 and state.discard_pile.size() == 1, "先失血致死时不执行后续12伤害，归档后失败");
	controller.get_parent().queue_free();


## 探测真实会话候选的固定种子，不改卡池或向RewardState注入候选。
## 战斗抽牌使用独立随机流，纯会话探测与正式战斗得到同一奖励。
func _reward_seed(definition:RunDefinition, target:CardDefinition, chosen:CardDefinition)->int:
	for seed_value in range(128):
		var probe:RunSession = RunSession.new();
		if not probe.initialize(definition, seed_value):
			break;
		if not probe.choose_starting_card(probe.get_draft_candidates()[0]) or not probe.choose_starting_card(chosen) or not probe.choose_starting_card(probe.get_draft_candidates()[0]) or not probe.enter_node("goblin_battle"):
			break;
		var result:BattleResult = BattleResult.new();
		result.battle_id = probe.state.active_battle_id;
		result.node_id = probe.state.current_node_id;
		result.victory = true;
		result.player_health = probe.state.current_health;
		result.player_max_health = probe.state.max_health;
		if probe.submit_battle_result(result) and probe.state.reward_state.candidates.has(target):
			return seed_value;
	_expect(false, "固定种子探测必须覆盖待测卡牌的真实奖励候选：%s" % target.card_id);
	return -1;


func _test_draft_and_rewards()->void:
	for id in NEW_IDS:
		var target:CardDefinition = _card(id);
		var chosen:CardDefinition = target if target.rarity == CardDefinition.CardRarity.EPIC else _card("blood_cloak");
		var definition:RunDefinition = load("res://tests/fixtures/linear_run.tres");
		var seed_value:int = _reward_seed(definition, target, chosen);
		if seed_value < 0:
			continue;
		var main:Node = load("res://main.tscn").instantiate();
		var flow:GameFlowController = main.get_node("game_flow_controller");
		# 固定线性测试配置只用于卡牌机制隔离；正式地图在branch_map_test验证。
		flow.run_definition = definition;
		flow.run_seed = seed_value;
		root.add_child(main);
		flow._start_new_run();
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
		var epic:StartingDraftView = flow.current_page as StartingDraftView;
		_expect(epic.candidates.size() == 8 and epic.get_page_count() == 2, "正式史诗8张自动分两页");
		epic._change_page(epic.candidates.find(chosen) / 6);
		for view in epic._card_views:
			if view.card_definition == chosen:
				view.pressed.emit();
				break;
		_expect(flow.run_state.owned_cards.has(chosen), "新增史诗可通过真实开局候选取得");
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
		flow._handle_map_node_selected("goblin_battle");
		var controller:BattleController = flow.current_page.get_node("battle_controller");
		# 验证每个新资源通过现有奖励页选入牌组，候选选择本身已由抽样测试覆盖。
		controller.battle_state.enemy_state.take_unblocked_damage(100);
		controller._check_battle_result();
		var reward:RewardView = flow.current_page;
		_expect(flow.run_state.reward_state.candidates.has(target) and reward.reward_options == flow.run_state.reward_state.candidates, "新增非传说卡显示为真实会话奖励候选");
		for view:CardChoiceView in reward._reward_card_views:
			if view.card_definition == target:
				view.pressed.emit();
				break;
		_expect(flow.current_page is MapView and flow.run_state.owned_cards.back() == _card(id) and flow.run_state.owned_cards.size() == 10, "通过奖励组件加入真实牌组");
		flow._handle_map_node_selected("rest_site");
		flow._handle_map_node_selected("ruin_guard_boss");
		controller = flow.current_page.get_node("battle_controller");
		var count:int = 0;
		for card in controller.battle_state.hand + controller.battle_state.draw_pile:
			if card.definition == _card(id):
				count += 1;
		_expect(count == (2 if _card(id).rarity == CardDefinition.CardRarity.EPIC else 1), "下一战为开局和奖励取得的新卡创建实例");
		main.queue_free();
		await process_frame;


func _test_text()->void:
	var views:Array[Control] = [];
	for id in NEW_IDS:
		var definition:CardDefinition = _card(id);
		var reward:CardChoiceView = load("res://ui/cards/card_choice_view.tscn").instantiate();
		root.add_child(reward);
		reward.setup(definition);
		views.append(reward);
		var hand:CardView = load("res://cards/card_view.tscn").instantiate();
		hand.size = Vector2(140, 200);
		root.add_child(hand);
		var card:CardInstance = CardInstance.new();
		card.card_instance_init(definition);
		hand.bind_card_instance(card);
		views.append(hand);
	await process_frame;
	await process_frame;
	for view in views:
		var description:RichTextLabel = view.get_node("card_face/description_label");
		_expect(description.get_content_height() <= description.size.y and not description.text.contains("{damage_"), "现有卡面可容纳基础文案且占位符已替换：%s" % view.get_node("card_face/name_label").text);
		view.queue_free();
