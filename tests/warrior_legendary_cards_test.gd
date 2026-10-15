## 四张正式传说卡的结算、武器回手、候选分组与普通奖励隔离。
extends SceneTree

const CARD_IDS:Array[String] = ["fortress", "eternity", "blood_feast", "endless_power"];
var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_catalog_and_rewards();
	_test_fortress();
	_test_eternity();
	_test_eternity_full_hand();
	_test_blood_feast();
	_test_endless_power();
	await _test_card_text();
	await process_frame;
	await create_timer(0.5).timeout; # 仅等待测试退出时的混音线程释放。
	print("战士正式传说卡检查完成，失败数：%d" % _failures);
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
	# 固定6伤害测试对手，保证观察完整武器周期，避免依赖正式敌人的平衡数值。
	var encounter:EncounterDefinition = load("res://battle/data/encounters/cave_crawler_encounter.tres").duplicate();
	var enemy:EnemyDefinition = encounter.enemy_definition.duplicate();
	var damage:CombatEffectDefinition = CombatEffectDefinition.new();
	damage.effect_type = CombatEffectDefinition.EffectType.DAMAGE;
	damage.target_type = CombatEffectDefinition.TargetType.OPPONENT;
	damage.amount = 6;
	var action:EnemyActionDefinition = EnemyActionDefinition.new();
	action.action_id = "test_attack_6";
	action.intent_text = "测试攻击";
	action.effects = [damage];
	enemy.action_pattern = [action];
	encounter.enemy_definition = enemy;
	_expect(controller.start_battle(encounter, load("res://combatants/data/player.tres"), cards, 50, 50), "正式传说卡测试战斗应启动");
	return controller;


## 只调整测试牌堆的位置，不改正式资源的词条。
func _put_in_hand(state:BattleState, id:String)->CardInstance:
	for card in state.hand:
		if card.definition.card_id == id:
			return card;
	for pile in [state.draw_pile, state.discard_pile]:
		for card in pile:
			if card.definition.card_id == id:
				pile.erase(card);
				pile.append(state.hand.pop_back());
				state.hand.append(card);
				return card;
	return null;


func _test_catalog_and_rewards()->void:
	var character:CharacterDefinition = load("res://characters/data/warrior.tres");
	var pool:Array[CardDefinition] = character.reward_card_pool;
	_expect(not character.is_invalid() and pool.size() == 27, "角色卡池27张，ID唯一且合法");
	var names:Array[String] = ["坚城", "永恒", "鲜血狂宴", "无尽之力"];
	var costs:Array[int] = [2, 1, 2, 0];
	var types:Array[int] = [2, 3, 0, 0];
	for index in range(CARD_IDS.size()):
		var card:CardDefinition = _card(CARD_IDS[index]);
		_expect(card.card_id == CARD_IDS[index] and card.card_name == names[index] and card.base_energy_cost == costs[index] and card.card_type == types[index], "传说卡身份、费用和类型符合草案");
		_expect(pool.has(card) and card.rarity == CardDefinition.CardRarity.LEGENDARY and not card.is_invalid(), "传说卡已进入角色卡池");
		_expect(card.exhausts_on_play == (index >= 2) and card.is_innate == (index == 1) and card.retains_on_turn_end == (index == 1), "只给永恒固有保留，只给两张攻击牌打出消耗");
	_expect(CardPoolSampler.filter_pool(pool, [CardDefinition.CardRarity.LEGENDARY]).size() == 4, "传说分组有4张正式候选");
	var reward_pool:Array[CardDefinition] = CardPoolSampler.filter_pool(pool, CardPoolSampler.REWARD_RARITIES);
	_expect(reward_pool.size() == 23, "普通战斗仍有23张非传说候选");
	for id in CARD_IDS:
		_expect(not reward_pool.has(_card(id)), "普通奖励过滤传说：%s" % id);
	for rarity in [CardDefinition.CardRarity.RARE, CardDefinition.CardRarity.EPIC, CardDefinition.CardRarity.LEGENDARY]:
		var candidates:Array[CardDefinition] = CardPoolSampler.sample(pool, 3, [rarity]);
		_expect(candidates.size() == 3 and candidates[0] != candidates[1] and candidates[0] != candidates[2] and candidates[1] != candidates[2], "三个开局分组均能抽出3张不同候选");
		for card in candidates:
			_expect(card.rarity == rarity, "候选稀有度正确");
	var main:Node = load("res://main.tscn").instantiate();
	root.add_child(main);
	var flow:GameFlowController = main.get_node("game_flow_controller");
	# 固定线性测试配置只用于卡牌机制隔离；正式地图在branch_map_test验证。
	flow.run_definition = load("res://tests/fixtures/linear_run.tres");
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
			_expect(reward_pool.has(view.card_definition), "正式冒险奖励页只展示非传说候选");
		reward._reward_card_views[0].pressed.emit();
	_expect(flow.run_state.owned_cards.size() == 10 and flow.current_page is MapView and pool.size() == 27, "开局构筑及一次奖励流程与正式源卡池保持正确");
	main.queue_free();


func _test_fortress()->void:
	var controller:BattleController = _controller([_card("fortress"), _card("fortress")]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_block(12);
	controller._on_card_selected(state.hand[0]);
	_expect(state.current_available_energy == 1 and state.played_power_cards.size() == 1 and state.player_state.powers.size() == 1, "坚城2费，施加能力并退出循环");
	state.gain_energy(1);
	controller._on_card_selected(state.hand[0]);
	_expect(state.played_power_cards.size() == 2 and state.player_state.powers.size() == 1, "重复坚城归档两张但能力不叠加");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_block == 6 and state.player_state.current_health == 50 and state.hand.is_empty(), "12格挡抵消敌人6伤害，余6保留到下回合");
	controller.get_parent().queue_free();


func _test_eternity()->void:
	var deck:Array[CardDefinition] = [_card("eternity"), _card("war_god_blessing")];
	for index in range(8):
		deck.append(_card("defend"));
	var controller:BattleController = _controller(deck);
	var state:BattleState = controller.battle_state;
	var eternal:CardInstance = state.hand[0];
	_expect(eternal.definition == _card("eternity") and eternal.weapon.current_attack == 3 and eternal.weapon.current_durability == 3, "正式永恒固有起手，基础3攻3耐久");
	controller._on_end_turn_button_pressed();
	_expect(state.hand.has(eternal), "未打出的永恒保留原实例");
	controller._on_card_selected(eternal);
	controller._on_card_selected(_put_in_hand(state, "war_god_blessing"));
	_expect(state.current_available_energy == 1 and eternal.weapon.current_attack == 11 and eternal.weapon.current_durability == 5, "永恒1费装备，祝福强化为11攻5耐久");
	for index in range(5):
		# 保证敌人存活，以真实攻击耗尽五点耐久。
		state.enemy_state.current_block = 1000;
		controller._on_weapon_attack_requested();
		if index < 4:
			controller._on_end_turn_button_pressed();
	_expect(state.equipped_weapon == null and state.hand.has(eternal) and not state.exhaust_pile.has(eternal), "耐久耗尽后原实例回手，不消耗");
	controller._on_card_selected(eternal);
	_expect(state.equipped_weapon == eternal and eternal.weapon.current_attack == 11 and eternal.weapon.current_durability == 5, "重装恢复强化后的最大耐久并保留攻击");
	_expect(not state.weapon_attack_available and not state.is_invalid_battle(), "重装不刷新攻击机会，牌区守恒");
	_expect(_card("eternity").weapon_definition.base_attack == 3 and _card("eternity").weapon_definition.base_max_durability == 3, "强化不污染正式资源");
	_expect(controller.start_battle(load("res://battle/data/encounters/cave_crawler_encounter.tres"), load("res://combatants/data/player.tres"), [_card("eternity")], 50, 50), "永恒可带入下一战");
	var next_card:CardInstance = controller.battle_state.hand[0];
	_expect(next_card != eternal and next_card.weapon.current_attack == 3 and next_card.weapon.current_durability == 3 and next_card.weapon.max_durability == 3, "下一战创建新实例，强化和旧耐久不延续");
	controller.get_parent().queue_free();


func _test_eternity_full_hand()->void:
	var deck:Array[CardDefinition] = [_card("eternity")];
	for index in range(12):
		deck.append(_card("defend"));
	var controller:BattleController = _controller(deck);
	var state:BattleState = controller.battle_state;
	var eternal:CardInstance = state.hand[0];
	controller._on_card_selected(eternal);
	state.draw_multiple_cards(10);
	eternal.weapon.current_durability = 1; # 测试最后一点耐久与满手组合。
	controller._on_weapon_attack_requested();
	_expect(state.hand.size() == 10 and state.discard_pile.has(eternal) and state.exhaust_pile.is_empty() and not state.is_invalid_battle(), "满手损坏时永恒进入弃牌堆");
	controller.get_parent().queue_free();


func _test_blood_feast()->void:
	var controller:BattleController = _controller([_card("blood_feast")]);
	var state:BattleState = controller.battle_state;
	state.player_state.current_health = 30;
	state.enemy_state.current_health = 4;
	state.enemy_state.gain_block(3);
	var card:CardInstance = state.hand[0];
	var reported_health:Array[int] = [];
	controller.battle_finished.connect(func(victory:bool, health:int, _max_health:int)->void:
		reported_health.append(health);
		_expect(victory and state.exhaust_pile.has(card), "鲜血狂宴先治疗和消耗归档，再报告胜利");
	);
	controller._on_card_selected(card);
	_expect(state.current_available_energy == 1 and state.player_state.current_health == 34 and reported_health == [34], "2费伤害10，有3格挡、4生命时仅回复实际失血4");
	controller.get_parent().queue_free();


func _test_endless_power()->void:
	var controller:BattleController = _controller([_card("endless_power"), _card("endless_power"), _card("strike"), _card("eternity")]);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(_put_in_hand(state, "endless_power"));
	_expect(state.current_available_energy == 3 and state.attack_card_energy_this_turn == 1 and state.exhaust_pile.size() == 1, "第一张0费无尽之力不触发自身，消耗后额度保留");
	controller._on_card_selected(_put_in_hand(state, "endless_power"));
	_expect(state.current_available_energy == 4 and state.attack_card_energy_this_turn == 2 and state.exhaust_pile.size() == 2, "第二张由已有额度回1能量，随后叠至2");
	controller._on_card_selected(_put_in_hand(state, "eternity"));
	controller._on_weapon_attack_requested();
	_expect(state.current_available_energy == 3, "正式永恒装备和武器攻击不触发攻击牌回能");
	controller._on_card_selected(_put_in_hand(state, "strike"));
	_expect(state.current_available_energy == 4 and state.enemy_state.current_health == 9, "后续打击付1回2，伤害依次6+6+3+6");
	controller._on_end_turn_button_pressed();
	_expect(state.attack_card_energy_this_turn == 0 and state.current_available_energy == 3 and not state.is_invalid_battle(), "下回合回能额度已清零，能量恢复基础值");
	controller.get_parent().queue_free();


func _test_card_text()->void:
	var views:Array[Control] = [];
	for id in CARD_IDS:
		var definition:CardDefinition = _card(id);
		var reward:CardChoiceView = load("res://ui/cards/card_choice_view.tscn").instantiate();
		root.add_child(reward);
		reward.setup(definition);
		_expect(reward.card_definition == definition, "传说卡可由候选卡组件显示");
		views.append(reward);
		var hand:CardView = load("res://cards/card_view.tscn").instantiate();
		hand.size = Vector2(140, 200);
		root.add_child(hand);
		var instance:CardInstance = CardInstance.new();
		instance.card_instance_init(definition);
		hand.bind_card_instance(instance);
		_expect(hand.card_instance == instance, "传说卡可显示为手牌");
		views.append(hand);
	await process_frame;
	await process_frame;
	for view in views:
		var description:RichTextLabel = view.get_node("card_face/description_label");
		_expect(description.get_content_height() <= description.size.y, "传说卡文案不能超出描述区：%s" % view.get_node("card_face/name_label").text);
		_expect(not description.text.contains("{damage_"), "伤害占位符已替换");
		view.queue_free();
