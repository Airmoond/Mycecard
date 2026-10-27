## 武器回归检查：独立实例、装备替换、攻击机会、损坏去向、强化与界面入口。
## 运行方式：Godot --headless --path <项目目录> --script res://tests/weapon_data_test.gd
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	var definition:CardDefinition = _weapon_card_definition();
	_expect(not definition.is_invalid(), "仅装备、没有附加效果的武器定义应合法");
	var first:CardInstance = _instance(definition);
	var second:CardInstance = _instance(definition);
	_expect(first.weapon != second.weapon, "同种武器的两张牌必须有独立状态");
	_expect(first.weapon.definition == second.weapon.definition, "武器实例可以共享只读定义");

	# 此处只检查重装恢复；强化效果的耐久规则由下方流程用例验证。
	first.weapon.current_attack += 8;
	first.weapon.max_durability += 2;
	first.weapon.current_durability = 0;
	first.weapon.restore_durability();
	_expect(first.weapon.current_attack == 11 and first.weapon.max_durability == 5, "重装不能重置已有强化");
	_expect(first.weapon.current_durability == 5, "重装应恢复到强化后的最大耐久");
	_expect(second.weapon.current_attack == 3 and second.weapon.current_durability == 3, "强化与损耗不能影响另一张同名武器");
	_expect(definition.weapon_definition.base_attack == 3 and definition.weapon_definition.base_max_durability == 3, "战斗变化不能写回静态定义");
	_expect(first.weapon.definition.break_destination == WeaponDefinition.BreakDestination.RETURN_TO_HAND, "恢复耐久不能改变损坏去向");

	var next_battle_card:CardInstance = _instance(definition);
	_expect(next_battle_card.weapon.current_attack == 3 and next_battle_card.weapon.max_durability == 3 and next_battle_card.weapon.current_durability == 3, "新战斗实例不能继承旧强化");
	var ordinary:CardInstance = _instance(load("res://cards/data/strike.tres"));
	_expect(ordinary.weapon == null, "普通卡牌不需要武器实例");
	_expect(WeaponDefinition.new().break_destination == WeaponDefinition.BreakDestination.EXHAUST, "普通武器默认损坏消耗");

	_test_plain_weapon_equipment();
	_test_replacement_and_re_equip();
	_test_full_hand_replacement();
	_test_lethal_equipment_effect();
	_test_attack_opportunity();
	_test_attack_return_and_re_equip();
	_test_full_hand_attack_break();
	_test_blocked_and_zero_damage();
	_test_lethal_weapon_attack();
	_test_enhancement_requirements();
	_test_enhancement_durability();
	_test_repeated_enhancement();
	_test_enhancement_persistence();
	await process_frame;
	print("武器数据、装备、攻击与强化检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _weapon_card_definition()->CardDefinition:
	var weapon_definition:WeaponDefinition = WeaponDefinition.new();
	weapon_definition.base_attack = 3;
	weapon_definition.base_max_durability = 3;
	weapon_definition.break_destination = WeaponDefinition.BreakDestination.RETURN_TO_HAND;
	var definition:CardDefinition = CardDefinition.new();
	definition.card_id = "test_weapon";
	definition.card_name = "测试武器";
	definition.description = "仅用于检查数据，不加入正式卡池";
	definition.card_type = CardDefinition.CardType.WEAPON;
	definition.base_energy_cost = 1;
	definition.weapon_definition = weapon_definition;
	return definition;


func _instance(definition:CardDefinition)->CardInstance:
	var card:CardInstance = CardInstance.new();
	_expect(card.card_instance_init(definition), "卡牌实例应能正确初始化");
	return card;


## 使用真实场景测试装备与出牌流程；小牌组保证首回合能抽到全部测试牌。
func _controller(definitions:Array[CardDefinition])->BattleController:
	var scene:PackedScene = load("res://battle/battle.tscn");
	var page:Control = scene.instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(
		load("res://battle/encounters/data/cave_crawler_encounter.tres"),
		load("res://combatants/players/data/player.tres"), definitions, 50, 50
	), "测试战斗应能初始化");
	return controller;


func _in_hand(controller:BattleController, definition:CardDefinition)->CardInstance:
	for card in controller.battle_state.hand:
		if card.definition == definition:
			return card;
	return null;


func _test_plain_weapon_equipment()->void:
	var definition:CardDefinition = _weapon_card_definition();
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	_expect(controller._card_is_playable(card), "无附加效果的武器应该可以装备");
	controller._on_card_selected(card);
	_expect(state.current_available_energy == 2, "装备1费武器应该扣除1能量");
	_expect(state.equipped_weapon == card and state.hand.is_empty(), "装备位应持有离手的原卡牌实例");
	_expect(state.resolving_card == null and state.discard_pile.is_empty() and state.exhaust_pile.is_empty(), "首次装备不应弃置或消耗武器");
	_expect(controller.weapon_label.text.contains("耐久：3 / 3"), "武器信息应显示当前与最大耐久");
	_expect(not state.is_invalid_battle(), "装备位也应计入牌数守恒");
	controller._on_end_turn_button_pressed();
	_expect(state.equipped_weapon == card and state.hand.is_empty(), "结束回合与抽牌不能把装备洗回手牌");
	_expect(state.battle_state_init(state.player_state, state.enemy_state, [card], 3, 5, 10), "测试状态应能重新初始化");
	_expect(state.equipped_weapon == null, "初始化新战斗必须清空装备位");
	controller.get_parent().queue_free();


func _test_replacement_and_re_equip()->void:
	var returning:CardDefinition = _weapon_card_definition();
	var ordinary:CardDefinition = _weapon_card_definition();
	ordinary.weapon_definition.break_destination = WeaponDefinition.BreakDestination.EXHAUST;
	var controller:BattleController = _controller([returning, ordinary]);
	var state:BattleState = controller.battle_state;
	var returning_card:CardInstance = _in_hand(controller, returning);
	var ordinary_card:CardInstance = _in_hand(controller, ordinary);
	controller._on_card_selected(returning_card);
	returning_card.weapon.current_attack = 11;
	returning_card.weapon.max_durability = 5;
	returning_card.weapon.current_durability = 1;
	state.current_available_energy = 0;
	controller._on_card_selected(ordinary_card);
	_expect(state.equipped_weapon == returning_card and state.hand.has(ordinary_card), "费用不足不能损坏旧武器或移动新武器");
	_expect(returning_card.weapon.current_durability == 1 and state.current_available_energy == 0, "失败换装不应改变耐久或能量");
	state.current_available_energy = 2;
	controller._on_card_selected(ordinary_card);
	_expect(state.equipped_weapon == ordinary_card and state.hand.has(returning_card), "特殊武器被替换时应原实例回手");
	_expect(returning_card.weapon.current_durability == 0 and state.exhaust_pile.is_empty(), "回手武器已损坏，但不算消耗");
	controller._on_card_selected(returning_card);
	_expect(state.equipped_weapon == returning_card and state.current_available_energy == 0, "回手武器重新装备仍需支付费用");
	_expect(state.exhaust_pile.size() == 1 and state.exhaust_pile.has(ordinary_card), "普通旧武器应恰好消耗一次");
	_expect(ordinary_card.weapon.current_durability == 0, "被替换的普通武器应标记为损坏");
	_expect(returning_card.weapon.current_attack == 11 and returning_card.weapon.current_durability == 5, "重装应保留强化并恢复最大耐久");
	_expect(controller.weapon_label.text.contains("耐久：5 / 5"), "重装后界面应显示强化后的耐久");
	_expect(not state.is_invalid_battle(), "换装、回手与重装后应保持牌数守恒");
	controller.get_parent().queue_free();


## 新牌离手后先处理旧武器回手，再执行抽牌附加效果，避免抢占回手空位。
func _test_full_hand_replacement()->void:
	var returning:CardDefinition = _weapon_card_definition();
	var replacement:CardDefinition = _weapon_card_definition();
	var draw:CombatEffectDefinition = CombatEffectDefinition.new();
	draw.effect_type = CombatEffectDefinition.EffectType.DRAW;
	draw.amount = 1;
	replacement.effects.append(draw);
	var filler:CardDefinition = load("res://cards/data/strike.tres");
	var controller:BattleController = _controller([returning, replacement, filler]);
	var state:BattleState = controller.battle_state;
	var old_card:CardInstance = _in_hand(controller, returning);
	var new_card:CardInstance = _in_hand(controller, replacement);
	var filler_card:CardInstance = _in_hand(controller, filler);
	controller._on_card_selected(old_card);
	state.discard_card_from_hand(filler_card);
	# 将测试规则设为1张手牌上限，此时手中只有待装备的新武器。
	state.max_hand_size = 1;
	state.cards_per_turn = 1;
	controller._on_card_selected(new_card);
	_expect(state.hand.size() == 1 and state.hand.has(old_card), "满手换装后旧武器应占用新牌腾出的空位");
	_expect(state.discard_pile.has(filler_card), "满手时附加抽牌应正常停止，不能挤掉回手武器");
	_expect(state.equipped_weapon == new_card and not state.is_invalid_battle(), "满手换装后状态应合法");
	controller.get_parent().queue_free();


func _test_lethal_equipment_effect()->void:
	var definition:CardDefinition = _weapon_card_definition();
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	definition.effects.assign(strike.effects);
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	state.enemy_state.current_health = 1;
	var results:Array[bool] = [];
	controller.battle_finished.connect(func(victory:bool, _health:int, _max_health:int)->void:
		results.append(victory);
		_expect(state.equipped_weapon == card and state.resolving_card == null, "结果信号发出前武器必须已进入装备位");
	);
	controller._on_card_selected(card);
	_expect(results.size() == 1 and results[0], "武器附加致命效果应正常结算一次胜利");
	_expect(not state.is_invalid_battle(), "致命附加效果后武器归属仍应正确");
	controller.get_parent().queue_free();


func _test_attack_opportunity()->void:
	var first:CardDefinition = _weapon_card_definition();
	var second:CardDefinition = _weapon_card_definition();
	var controller:BattleController = _controller([first, second]);
	var state:BattleState = controller.battle_state;
	var first_card:CardInstance = _in_hand(controller, first);
	var second_card:CardInstance = _in_hand(controller, second);
	_expect(not state.attack_with_weapon() and state.weapon_attack_available, "未装备时不能攻击，也不消耗机会");
	_expect(controller.hand_area.get_node_or_null("weapon_attack") == null, "未装备时没有临时入口");
	controller._on_card_selected(first_card);
	var attack_view:Button = controller.hand_area.get_node("weapon_attack");
	_expect(controller.hand_area.get_child_count() == state.hand.size() + 1, "临时入口只增加界面节点，不增加真实卡牌");
	state.current_available_energy = 0;
	var health_before:int = state.enemy_state.current_health;
	attack_view.pressed.emit();
	_expect(state.enemy_state.current_health == health_before - 3 and first_card.weapon.current_durability == 2, "装备当回合可以攻击，扣除伤害和1耐久");
	_expect(state.current_available_energy == 0 and state.resolving_card == null and state.discard_pile.is_empty(), "武器攻击无需能量，不进入出牌或弃牌流程");
	_expect(controller.hand_area.get_node_or_null("weapon_attack") == null, "攻击后临时入口移除");
	attack_view.pressed.emit();# 同一帧内旧按钮还未释放，也不能重复攻击。
	_expect(state.enemy_state.current_health == health_before - 3 and first_card.weapon.current_durability == 2, "重复点击不能再次伤害或损耗耐久");
	state.current_available_energy = 1;
	controller._on_card_selected(second_card);
	_expect(not state.can_attack_with_weapon(), "攻击后换装不能刷新机会");
	controller._on_end_turn_button_pressed();
	_expect(state.can_attack_with_weapon(), "下回合恢复一次攻击机会");
	controller._on_end_turn_button_pressed();# 未使用的机会不能累积。
	controller._on_weapon_attack_requested();
	controller._on_weapon_attack_requested();
	_expect(second_card.weapon.current_durability == 2, "未使用的机会不会累积到后续回合");
	_expect(not state.is_invalid_battle(), "攻击与换装后真实卡牌数量守恒");
	controller.get_parent().queue_free();


func _test_attack_return_and_re_equip()->void:
	var controller:BattleController = _controller([_weapon_card_definition()]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	controller._on_card_selected(card);
	card.weapon.current_durability = 1;
	controller._on_weapon_attack_requested();
	_expect(state.equipped_weapon == null and state.hand.has(card), "最后耐久攻击后原武器应损坏回手");
	_expect(state.exhaust_pile.is_empty() and card.weapon.current_durability == 0, "回手型武器不算消耗");
	controller._on_card_selected(card);
	_expect(card.weapon.current_durability == 3 and not state.can_attack_with_weapon(), "重装恢复耐久但不能再次攻击");
	controller._on_end_turn_button_pressed();
	_expect(state.can_attack_with_weapon(), "重装后下回合可以再次攻击");
	state.current_phase = BattleState.BattlePhase.ENEMY_TURN;
	_expect(not state.attack_with_weapon() and state.weapon_attack_available, "敌人回合不能使用武器攻击");
	_expect(not state.is_invalid_battle(), "攻击回手重装后牌区保持正确");
	controller.get_parent().queue_free();


func _test_full_hand_attack_break()->void:
	var weapon_definition:CardDefinition = _weapon_card_definition();
	var filler:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	filler.exhausts_on_play = true;
	var controller:BattleController = _controller([weapon_definition, filler]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = _in_hand(controller, weapon_definition);
	var filler_card:CardInstance = _in_hand(controller, filler);
	controller._on_card_selected(card);
	card.weapon.current_attack = 11;
	card.weapon.max_durability = 5;
	card.weapon.current_durability = 1;
	state.max_hand_size = 1;
	state.cards_per_turn = 1;
	controller._refresh_battle_view();
	_expect(controller.hand_area.get_child_count() == 2, "真实手牌已满也仍有武器攻击入口");
	controller._on_weapon_attack_requested();
	_expect(state.hand.size() == 1 and state.discard_pile.has(card) and state.exhaust_pile.is_empty(), "满手损坏时永恒进入弃牌堆");
	controller._on_card_selected(filler_card);
	_expect(state.draw_one_card() == card, "腾出空位后能通过正常洗牌抽回同一把武器");
	controller._on_card_selected(card);
	_expect(card.weapon.current_attack == 11 and card.weapon.current_durability == 5, "弃牌后抽回重装仍保留强化并恢复耐久");
	_expect(not state.can_attack_with_weapon() and not state.is_invalid_battle(), "满手回收不增加攻击机会，也不丢牌");
	controller.get_parent().queue_free();


func _test_blocked_and_zero_damage()->void:
	var definition:CardDefinition = _weapon_card_definition();
	definition.weapon_definition.break_destination = WeaponDefinition.BreakDestination.EXHAUST;
	definition.weapon_definition.base_max_durability = 2;
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = state.hand[0];
	controller._on_card_selected(card);
	state.enemy_state.current_block = 4;
	var health_before:int = state.enemy_state.current_health;
	controller._on_weapon_attack_requested();
	_expect(state.enemy_state.current_health == health_before and state.enemy_state.current_block == 1, "武器攻击正常被格挡抵消");
	_expect(card.weapon.current_durability == 1 and not state.weapon_attack_available, "完全格挡也消耗机会与耐久");
	controller._on_end_turn_button_pressed();
	card.weapon.current_attack = 0;
	controller._on_weapon_attack_requested();
	_expect(state.enemy_state.current_health == health_before and not state.weapon_attack_available, "0攻击仍正常使用一次机会");
	_expect(state.equipped_weapon == null and state.exhaust_pile.size() == 1 and state.exhaust_pile.has(card), "0伤害也扣最后耐久并消耗普通武器");
	_expect(not state.is_invalid_battle(), "普通武器损坏后牌区正确");
	controller.get_parent().queue_free();


func _test_lethal_weapon_attack()->void:
	for destination in [WeaponDefinition.BreakDestination.EXHAUST, WeaponDefinition.BreakDestination.RETURN_TO_HAND]:
		var definition:CardDefinition = _weapon_card_definition();
		definition.weapon_definition.break_destination = destination;
		definition.weapon_definition.base_max_durability = 1;
		var controller:BattleController = _controller([definition]);
		var state:BattleState = controller.battle_state;
		var card:CardInstance = state.hand[0];
		controller._on_card_selected(card);
		state.enemy_state.current_health = 1;
		var results:Array[bool] = [];
		controller.battle_finished.connect(func(victory:bool, _health:int, _max_health:int)->void:
			results.append(victory);
			_expect(state.equipped_weapon == null and card.weapon.current_durability == 0, "致命攻击发出结果前必须完成损坏");
			var final_pile:Array[CardInstance] = state.exhaust_pile if destination == WeaponDefinition.BreakDestination.EXHAUST else state.hand;
			_expect(final_pile.has(card), "致命攻击发出结果前必须完成消耗或回手");
		);
		controller._on_weapon_attack_requested();
		controller._on_weapon_attack_requested();
		_expect(results.size() == 1 and results[0], "致命武器攻击只报告一次胜利");
		_expect(controller.hand_area.get_node_or_null("weapon_attack") == null, "战斗结束后不残留攻击入口");
		_expect(not state.is_invalid_battle(), "致命攻击后牌区保持正确");
		controller.get_parent().queue_free();


## 测试用1费消耗技能，只使用已确认的+8攻击、+2耐久规则。
func _enhancement_definition()->CardDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = CombatEffectDefinition.EffectType.ENHANCE_WEAPON;
	effect.target_type = CombatEffectDefinition.TargetType.SELF;
	effect.amount = 8;
	effect.durability_bonus = 2;
	var definition:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	definition.card_id = "test_enhancement";
	definition.card_name = "测试强化";
	definition.description = "武器获得8攻击和2耐久。消耗。";
	definition.exhausts_on_play = true;
	definition.effects = [effect];
	return definition;


func _test_enhancement_requirements()->void:
	var enhancement:CardDefinition = _enhancement_definition();
	var weapon_definition:CardDefinition = _weapon_card_definition();
	var controller:BattleController = _controller([enhancement, weapon_definition]);
	var state:BattleState = controller.battle_state;
	var card:CardInstance = _in_hand(controller, enhancement);
	var weapon_card:CardInstance = _in_hand(controller, weapon_definition);
	_expect(not controller._card_is_playable(card), "无装备时强化牌应显示不可用，即使手中有武器");
	controller._on_card_selected(card);
	_expect(state.current_available_energy == 3 and state.hand.has(card) and state.resolving_card == null, "无装备时点击强化牌不扣费、不移牌");
	_expect(state.exhaust_pile.is_empty(), "无装备时强化牌不会被消耗");
	controller._on_card_selected(weapon_card);
	_expect(controller._card_is_playable(card), "装备后强化牌应变为可用");
	state.current_available_energy = 0;
	_expect(not controller._card_is_playable(card), "强化牌仍需要足够费用");
	controller._on_card_selected(card);
	_expect(weapon_card.weapon.current_attack == 3 and weapon_card.weapon.current_durability == 3 and state.hand.has(card), "费用不足不能强化或移牌");
	controller.get_parent().queue_free();


func _test_enhancement_durability()->void:
	for starting_durability in [1, 3]:
		var enhancement:CardDefinition = _enhancement_definition();
		var weapon_definition:CardDefinition = _weapon_card_definition();
		var controller:BattleController = _controller([enhancement, weapon_definition, weapon_definition]);
		var state:BattleState = controller.battle_state;
		var weapon_card:CardInstance = _in_hand(controller, weapon_definition);
		controller._on_card_selected(weapon_card);
		var other_weapon:CardInstance = _in_hand(controller, weapon_definition);
		weapon_card.weapon.current_durability = starting_durability;
		state.weapon_attack_available = false;
		var card:CardInstance = _in_hand(controller, enhancement);
		controller._on_card_selected(card);
		_expect(weapon_card.weapon.current_attack == 11 and weapon_card.weapon.max_durability == 5, "强化应增加8攻击与2最大耐久");
		_expect(weapon_card.weapon.current_durability == starting_durability + 2, "当前耐久加2，受损武器不会被直接修满");
		_expect(state.current_available_energy == 1 and state.exhaust_pile.has(card), "强化正常扣费并归档");
		_expect(not state.weapon_attack_available, "强化不能刷新攻击机会");
		_expect(other_weapon.weapon.current_attack == 3 and other_weapon.weapon.max_durability == 3, "强化不能影响另一张同名武器");
		_expect(weapon_definition.weapon_definition.base_attack == 3 and weapon_definition.weapon_definition.base_max_durability == 3, "强化不能污染静态武器定义");
		_expect(controller.weapon_label.text.contains("耐久：%d / 5" % (starting_durability + 2)), "装备标签应显示强化后的耐久");
		controller._on_end_turn_button_pressed();
		var health_before:int = state.enemy_state.current_health;
		controller._on_weapon_attack_requested();
		_expect(state.enemy_state.current_health == health_before - 11, "下一次攻击应使用强化后的攻击力");
		_expect(not state.is_invalid_battle(), "强化与攻击后卡牌归属正确");
		controller.get_parent().queue_free();


func _test_repeated_enhancement()->void:
	var enhancement:CardDefinition = _enhancement_definition();
	enhancement.effects[0].repeat_count = 2;
	var weapon_definition:CardDefinition = _weapon_card_definition();
	var controller:BattleController = _controller([enhancement, weapon_definition]);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(_in_hand(controller, weapon_definition));
	var weapon:WeaponInstance = state.equipped_weapon.weapon;
	weapon.current_durability = 1;
	controller._on_card_selected(_in_hand(controller, enhancement));
	_expect(weapon.current_attack == 19 and weapon.max_durability == 7 and weapon.current_durability == 5, "重复强化按次数累加攻击、最大耐久和当前耐久");
	_expect(state.current_available_energy == 1 and state.exhaust_pile.size() == 1, "重复效果只支付一次费用、归档一次");
	controller.get_parent().queue_free();


func _test_enhancement_persistence()->void:
	var enhancement:CardDefinition = _enhancement_definition();
	var returning:CardDefinition = _weapon_card_definition();
	returning.retains_on_turn_end = true;
	var replacement:CardDefinition = _weapon_card_definition();
	replacement.weapon_definition.break_destination = WeaponDefinition.BreakDestination.EXHAUST;
	var controller:BattleController = _controller([enhancement, returning, replacement]);
	var state:BattleState = controller.battle_state;
	var returning_card:CardInstance = _in_hand(controller, returning);
	controller._on_card_selected(returning_card);
	controller._on_card_selected(_in_hand(controller, enhancement));
	controller._on_card_selected(_in_hand(controller, replacement));
	_expect(state.hand.has(returning_card) and returning_card.weapon.current_attack == 11, "被替换回手仍保留实际效果产生的强化");
	controller._on_end_turn_button_pressed();
	controller._on_card_selected(returning_card);
	_expect(returning_card.weapon.current_attack == 11 and returning_card.weapon.current_durability == 5, "回手重装后恢复强化后的最大耐久");
	_expect(not state.is_invalid_battle(), "强化回手重装后牌数守恒");
	_expect(controller.start_battle(
		load("res://battle/encounters/data/cave_crawler_encounter.tres"),
		load("res://combatants/players/data/player.tres"), [returning], 50, 50
	), "下一场战斗应正常启动");
	var fresh:CardInstance = controller.battle_state.hand[0];
	_expect(fresh != returning_card and fresh.weapon.current_attack == 3 and fresh.weapon.max_durability == 3, "新战斗应创建未强化的全新实例");
	controller.get_parent().queue_free();
