## 正式史诗武器与强化资源：出牌组合、奖励接入和卡面文字。
extends SceneTree

const CARD_IDS:Array[String] = ["bloodthirsty_sword", "lethal_blade", "war_god_blessing"];
var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_catalog();
	_test_sword_trigger();
	_test_blessing_and_replacement();
	_test_blade_break();
	_test_reward_to_battle();
	await _test_card_text();
	await process_frame;
	await create_timer(0.5).timeout; # 仅等待测试退出时的混音线程释放。
	print("战士正式武器卡检查完成，失败数：%d" % _failures);
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
	_expect(controller.start_battle(load("res://battle/data/encounters/cave_crawler_encounter.tres"), load("res://combatants/data/player.tres"), cards, 50, 50), "正式武器测试战斗应启动");
	return controller;


## 测试中固定所需卡的位置；只交换原实例，不给正式资源追加固有词条。
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
	_expect(not character.is_invalid() and character.reward_card_pool.size() == 27, "正式卡池共27张且合法");
	var names:Array[String] = ["嗜血长剑", "致命之刃", "战神祝福"];
	var costs:Array[int] = [2, 3, 1];
	for index in range(CARD_IDS.size()):
		var card:CardDefinition = _card(CARD_IDS[index]);
		_expect(card.card_id == CARD_IDS[index] and card.card_name == names[index] and card.base_energy_cost == costs[index], "卡名、ID与费用符合草案");
		_expect(character.reward_card_pool.has(card) and card.rarity == CardDefinition.CardRarity.EPIC and not card.is_invalid(), "正式史诗资源已入池");
		_expect(card.exhausts_on_play == (CARD_IDS[index] == "war_god_blessing") and not card.is_innate and not card.retains_on_turn_end, "祝福打出消耗，两把武器不附加打出消耗、固有或保留");
		_expect(card.card_type == (CardDefinition.CardType.WEAPON if index < 2 else CardDefinition.CardType.SKILL), "两把武器与一张技能类型正确");
		if index < 2:
			_expect(card.effects.is_empty() and card.weapon_definition.break_destination == WeaponDefinition.BreakDestination.EXHAUST, "武器无装备附加效果，损坏消耗");
	_expect(CardPoolSampler.filter_pool(character.reward_card_pool, [CardDefinition.CardRarity.EPIC]).size() == 8, "史诗分组具备8张正式候选");


func _test_sword_trigger()->void:
	var deck:Array[CardDefinition] = [_card("bloodthirsty_sword")];
	for index in range(7):
		deck.append(_card("defend"));
	var controller:BattleController = _controller(deck);
	var state:BattleState = controller.battle_state;
	var sword:CardInstance = _put_in_hand(state, "bloodthirsty_sword");
	controller._on_card_selected(sword);
	_expect(state.current_available_energy == 1 and state.equipped_weapon == sword and state.player_state.strength == 0, "嗜血长剑2费装备，不在装备时触发力量");
	var attack:Button = controller.hand_area.get_node("weapon_attack");
	_expect(not attack.disabled and attack.tooltip_text.contains("预计伤害：8"), "正式武器装备后可通过实际按钮攻击");
	attack.pressed.emit();
	_expect(state.enemy_state.current_health == 22 and state.player_state.strength == 1 and state.hand.size() == 5, "先伤害8，再获得1力量并抽1张");
	_expect(sword.weapon.current_durability == 2 and not state.weapon_attack_available, "攻击消耗机会与1耐久");
	controller._on_end_turn_button_pressed();
	state.prevent_draw_for_turn();
	controller._on_weapon_attack_requested();
	_expect(state.enemy_state.current_health == 13 and state.player_state.strength == 2 and state.hand.size() == 5, "下次伤害9；禁抽不阻止力量触发");
	_expect(sword.weapon.current_durability == 1 and not state.is_invalid_battle(), "正式武器攻击后牌区守恒");
	controller.get_parent().queue_free();


func _test_blessing_and_replacement()->void:
	var controller:BattleController = _controller([_card("bloodthirsty_sword"), _card("war_god_blessing"), _card("lethal_blade")]);
	var state:BattleState = controller.battle_state;
	var blessing:CardInstance = _put_in_hand(state, "war_god_blessing");
	controller._on_card_selected(blessing);
	_expect(state.current_available_energy == 3 and state.hand.has(blessing), "无武器不能打出祝福，不扣费用");
	var sword:CardInstance = _put_in_hand(state, "bloodthirsty_sword");
	controller._on_card_selected(sword);
	controller._on_weapon_attack_requested();
	controller._on_card_selected(blessing);
	_expect(state.current_available_energy == 0 and state.exhaust_pile.has(blessing) and not state.discard_pile.has(blessing), "祝福支付1费后消耗");
	_expect(sword.weapon.current_attack == 16 and sword.weapon.current_durability == 4 and sword.weapon.max_durability == 5, "受损武器2/3变4/5，攻击8变16");
	_expect(not state.weapon_attack_available, "强化不刷新武器攻击机会");
	state.gain_energy(3);
	var blade:CardInstance = _put_in_hand(state, "lethal_blade");
	controller._on_card_selected(blade);
	_expect(state.equipped_weapon == blade and state.exhaust_pile.has(sword) and not state.weapon_attack_available, "换装使旧武器消耗，不刷新机会");
	_expect(blade.weapon.current_attack == 15 and blade.weapon.current_durability == 2, "新武器不继承旧武器强化");
	_expect(_card("bloodthirsty_sword").weapon_definition.base_attack == 8 and _card("bloodthirsty_sword").weapon_definition.base_max_durability == 3 and not state.is_invalid_battle(), "强化不污染静态资源");
	controller.get_parent().queue_free();


func _test_blade_break()->void:
	var controller:BattleController = _controller([_card("lethal_blade")]);
	var state:BattleState = controller.battle_state;
	var blade:CardInstance = state.hand[0];
	controller._on_card_selected(blade);
	state.enemy_state.gain_block(20);
	controller._on_weapon_attack_requested();
	_expect(state.current_available_energy == 0 and state.enemy_state.current_health == 15 and state.enemy_state.current_block == 20, "3费致命之刃扣15生命，保留20格挡");
	_expect(blade.weapon.current_durability == 1 and state.player_state.strength == 0, "扣耐久，无嗜血长剑触发");
	controller._on_end_turn_button_pressed();
	state.enemy_state.gain_block(20);
	var results:Array[bool] = [];
	controller.battle_finished.connect(func(victory:bool, _health:int, _max_health:int)->void:
		results.append(victory);
		_expect(state.exhaust_pile.has(blade) and state.equipped_weapon == null, "致命攻击先损坏消耗再报告胜利");
	);
	controller._on_weapon_attack_requested();
	_expect(results == [true] and state.enemy_state.current_block == 20 and not state.is_invalid_battle(), "第二次攻击击杀且不削减格挡，归档守恒");
	controller.get_parent().queue_free();


func _test_reward_to_battle()->void:
	var main:Node = load("res://main.tscn").instantiate();
	var flow:GameFlowController = main.get_node("game_flow_controller");
	flow.run_definition = load("res://tests/fixtures/linear_run.tres").duplicate();
	flow.run_definition.character_definition = flow.run_definition.character_definition.duplicate();
	# 测试保留可配置多轮奖励，四张非传说全部展示；另配齐开局稀有度。
	flow.run_definition.character_definition.reward_card_pool = [_card(CARD_IDS[0]), _card(CARD_IDS[1]), _card(CARD_IDS[2]), _card("battle_trance"), _card("fortress")];
	flow.run_definition.reward_option_count = 4;
	flow.run_definition.reward_selection_count = 3;
	root.add_child(main);
	flow._start_new_run();
	for _round in range(3):
		(flow.current_page as StartingDraftView)._card_views[0].pressed.emit();
	flow._handle_map_node_selected("goblin_battle");
	var controller:BattleController = flow.current_page.get_node("battle_controller");
	controller.battle_state.enemy_state.take_unblocked_damage(100);
	controller._check_battle_result();
	for id in CARD_IDS:
		var reward:RewardView = flow.current_page as RewardView;
		for view in reward._reward_card_views:
			if view.card_definition == _card(id):
				view.pressed.emit();
				break;
		_expect(flow.run_state.owned_cards.count(_card(id)) == (2 if id == "bloodthirsty_sword" else 1), "实际奖励获得新卡：%s" % id);
	flow._handle_map_node_selected("rest_site");
	flow._handle_map_node_selected("ruin_guard_boss");
	controller = flow.current_page.get_node("battle_controller");
	var state:BattleState = controller.battle_state;
	var enemy_health_before:int = state.enemy_state.current_health;
	controller._on_card_selected(_put_in_hand(state, "bloodthirsty_sword"));
	controller._on_card_selected(_put_in_hand(state, "war_god_blessing"));
	controller.hand_area.get_node("weapon_attack").pressed.emit();
	_expect(state.enemy_state.current_health == enemy_health_before - 16 and state.player_state.strength == 1 and state.equipped_weapon.weapon.current_durability == 4, "奖励武器与祝福进入Boss战，按16伤害结算并触发");
	_expect(flow.run_state.owned_cards.size() == 12 and not state.is_invalid_battle(), "配置三轮奖励后牌组真实持有12张，战斗牌区守恒");
	_expect(load("res://characters/data/warrior.tres").reward_card_pool.size() == 27, "测试池不污染正式卡池");
	main.queue_free();


func _test_card_text()->void:
	var views:Array[Control] = [];
	for id in CARD_IDS:
		var definition:CardDefinition = _card(id);
		var reward:CardChoiceView = load("res://ui/cards/card_choice_view.tscn").instantiate();
		root.add_child(reward);
		reward.setup(definition);
		_expect(reward.card_definition == definition, "新卡可显示为奖励");
		views.append(reward);
		var hand:CardView = load("res://cards/card_view.tscn").instantiate();
		hand.size = Vector2(140, 200);
		root.add_child(hand);
		var instance:CardInstance = CardInstance.new();
		instance.card_instance_init(definition);
		hand.bind_card_instance(instance);
		_expect(hand.card_instance == instance, "新卡可显示为手牌");
		views.append(hand);
	await process_frame;
	await process_frame;
	for view in views:
		var description:RichTextLabel = view.get_node("card_face/description_label");
		_expect(description.get_content_height() <= description.size.y, "武器与祝福文案不能超出描述区：%s" % view.get_node("card_face/name_label").text);
		view.queue_free();
