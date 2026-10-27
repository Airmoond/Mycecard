## 保留格挡能力的费用、归档、持续效果与跨战斗生命周期检查。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_player_retention();
	_test_insufficient_energy();
	_test_duplicates_and_exhaust();
	_test_force_clear_and_independence();
	_test_enemy_retention();
	_test_new_battle_reset();
	_test_lethal_effect_order();
	await process_frame;
	print("保留格挡能力检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _power_effect()->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = CombatEffectDefinition.EffectType.APPLY_POWER;
	effect.target_type = CombatEffectDefinition.TargetType.SELF;
	effect.power_definition = load("res://battle/powers/data/retain_block.tres");
	return effect;


func _power_card()->CardDefinition:
	var definition:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	definition.card_id = "test_retain_block";
	definition.card_name = "测试坚城";
	definition.description = "本场战斗，回合开始时不再自动清空格挡。";
	definition.card_type = CardDefinition.CardType.POWER;
	definition.base_energy_cost = 2;
	definition.effects = [_power_effect()];
	return definition;


func _effect(type:CombatEffectDefinition.EffectType, amount:int, target:CombatEffectDefinition.TargetType)->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = type;
	effect.amount = amount;
	effect.target_type = target;
	return effect;


func _action(effects:Array[CombatEffectDefinition])->EnemyActionDefinition:
	var action:EnemyActionDefinition = EnemyActionDefinition.new();
	action.action_id = "test_power_action";
	action.intent_text = "测试行动";
	action.effects = effects;
	return action;


func _controller(cards:Array[CardDefinition], actions:Array[EnemyActionDefinition] = [])->BattleController:
	var encounter:EncounterDefinition = load("res://battle/encounters/data/cave_crawler_encounter.tres").duplicate();
	encounter.enemy_definition = encounter.enemy_definition.duplicate();
	if actions.is_empty():
		actions = [_action([_effect(CombatEffectDefinition.EffectType.DAMAGE, 7, CombatEffectDefinition.TargetType.OPPONENT)])];
	encounter.enemy_definition.action_pattern = actions;
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(encounter, load("res://combatants/players/data/player.tres"), cards, 50, 50), "能力测试战斗应启动");
	return controller;


func _in_hand(controller:BattleController, definition:CardDefinition)->CardInstance:
	for card in controller.battle_state.hand:
		if card.definition == definition:
			return card;
	return null;


func _test_player_retention()->void:
	var definition:CardDefinition = _power_card();
	_expect(not definition.is_invalid() and definition.effects[0].amount == 0, "持续能力不应要求填写无意义的数值");
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	state.player_state.gain_block(12);
	controller._on_card_selected(state.hand[0]);
	_expect(state.current_available_energy == 1 and state.played_power_cards.size() == 1, "2费能力正常扣费并退出循环");
	_expect(controller.player_view.power_label.visible and controller.player_view.power_label.text == "能力：坚城", "施加后显示能力名称");
	_expect(controller.player_view.power_label.tooltip_text.contains("不再自动清空格挡"), "悬停说明来自能力定义");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_block == 5 and state.player_state.current_health == 50, "12格挡抵消7伤害后保留5至下一回合");
	_expect(state.hand.is_empty() and state.player_state.powers.size() == 1, "能力牌不再抽回，能力仍生效");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_block == 0 and state.player_state.current_health == 48, "保留格挡仍被后续伤害正常消耗");
	controller.get_parent().queue_free();
	controller = _controller([load("res://cards/data/defend.tres")]);
	controller.battle_state.player_state.gain_block(12);
	controller._on_end_turn_button_pressed();
	_expect(controller.battle_state.player_state.current_block == 0, "没有能力时仍自动清空剩余格挡");
	controller.get_parent().queue_free();


func _test_insufficient_energy()->void:
	var definition:CardDefinition = _power_card();
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	state.current_available_energy = 1;
	var card:CardInstance = state.hand[0];
	_expect(not controller._card_is_playable(card), "费用不足时不能使用");
	controller._on_card_selected(card);
	_expect(state.current_available_energy == 1 and state.hand.has(card) and state.played_power_cards.is_empty() and state.player_state.powers.is_empty(), "费用不足不扣费、不归档、不施加能力");
	controller.get_parent().queue_free();


func _test_duplicates_and_exhaust()->void:
	var first:CardDefinition = _power_card();
	var second:CardDefinition = _power_card();
	second.exhausts_on_play = true;
	second.effects[0].repeat_count = 3;
	second.effects[0].power_definition = second.effects[0].power_definition.duplicate();
	var controller:BattleController = _controller([first, second]);
	var state:BattleState = controller.battle_state;
	controller._on_card_selected(_in_hand(controller, first));
	state.gain_energy(2);
	controller._on_card_selected(_in_hand(controller, second));
	_expect(state.player_state.powers.size() == 1, "同类能力即使用不同资源并重复施加，也不叠加");
	_expect(state.current_available_energy == 1 and state.played_power_cards.size() == 1 and state.exhaust_pile.size() == 1, "两张牌各自正常支付费用并按词条归档");
	state.player_state.gain_block(12);
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_block == 5 and state.hand.is_empty(), "能力卡消耗后效果继续，牌不回收");
	_expect(not state.is_invalid_battle(), "能力归档后真实卡牌数量仍守恒");
	controller.get_parent().queue_free();


func _test_force_clear_and_independence()->void:
	var first:CombatantState = CombatantState.new();
	var second:CombatantState = CombatantState.new();
	first.combatant_init("甲", 50);
	second.combatant_init("乙", 50);
	var power:PowerDefinition = load("res://battle/powers/data/retain_block.tres");
	first.apply_power(power);
	first.gain_block(12);
	first.clear_block();
	_expect(first.current_block == 0 and first.has_power(PowerDefinition.PowerType.RETAIN_BLOCK), "显式清空格挡不受能力阻止，也不移除能力");
	first.gain_block(5);
	first.clear_block_at_turn_start();
	second.gain_block(5);
	second.clear_block_at_turn_start();
	_expect(first.current_block == 5 and second.current_block == 0 and second.powers.is_empty(), "持有能力的状态归角色所有");
	_expect(power.display_name == "坚城" and not power.is_invalid(), "施加能力不修改静态定义");


func _test_enemy_retention()->void:
	var controller:BattleController = _controller([load("res://cards/data/defend.tres")], [
		_action([_power_effect(), _effect(CombatEffectDefinition.EffectType.BLOCK, 12, CombatEffectDefinition.TargetType.SELF)]),
		_action([_effect(CombatEffectDefinition.EffectType.BLOCK, 1, CombatEffectDefinition.TargetType.SELF)])
	]);
	_expect(controller.enemy_view.intent_label.text.contains("自身获得坚城"), "敌人意图支持施加能力");
	controller._on_end_turn_button_pressed();
	controller._on_end_turn_button_pressed();
	_expect(controller.battle_state.enemy_state.current_block == 13, "敌人回合开始也遵守保留格挡规则");
	_expect(controller.enemy_view.power_label.visible and controller.battle_state.player_state.powers.is_empty(), "能力显示属于施加目标");
	controller.get_parent().queue_free();


func _test_new_battle_reset()->void:
	var definition:CardDefinition = _power_card();
	var controller:BattleController = _controller([definition]);
	controller._on_card_selected(controller.battle_state.hand[0]);
	controller.battle_state.enemy_state.apply_power(definition.effects[0].power_definition);
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), [definition], 50, 50), "下一场应重新启动");
	var state:BattleState = controller.battle_state;
	_expect(state.player_state.powers.is_empty() and state.enemy_state.powers.is_empty() and state.hand.size() == 1 and state.played_power_cards.is_empty(), "新战斗清空能力与归档，能力牌重新进入牌组");
	_expect(not controller.player_view.power_label.visible and not controller.enemy_view.power_label.visible, "新战斗能力显示清空");
	state.player_state.apply_power(definition.effects[0].power_definition);
	state.player_state.combatant_init_from_definition(load("res://combatants/players/data/player.tres"));
	_expect(state.player_state.powers.is_empty(), "重新初始化同一角色也清空能力");
	controller.get_parent().queue_free();


func _test_lethal_effect_order()->void:
	var definition:CardDefinition = _power_card();
	definition.effects.push_front(_effect(CombatEffectDefinition.EffectType.LOSE_HEALTH, 50, CombatEffectDefinition.TargetType.SELF));
	var controller:BattleController = _controller([definition]);
	controller._on_card_selected(controller.battle_state.hand[0]);
	_expect(controller.battle_state.player_state.powers.is_empty() and controller.battle_state.played_power_cards.size() == 1 and controller.battle_state.is_defeat(), "前序失血致死时不施加后续能力，但仍归档并失败");
	controller.get_parent().queue_free();
