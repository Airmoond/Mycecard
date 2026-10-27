## 血红披风：下回合开始触发、每份独立、坚城并存、致死中断与能力生命周期。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_activation_and_repetition();
	_test_retained_block();
	_test_stacking();
	_test_lethal_interruption();
	_test_cost_and_new_battle();
	_test_owner_turn();
	await process_frame;
	print("回合开始能力检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _power_effect()->CombatEffectDefinition:
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = CombatEffectDefinition.EffectType.APPLY_POWER;
	effect.power_definition = load("res://battle/powers/data/blood_cloak.tres");
	return effect;


func _card()->CardDefinition:
	var definition:CardDefinition = load("res://cards/data/defend.tres").duplicate();
	definition.card_id = "test_blood_cloak";
	definition.card_name = "测试血红披风";
	definition.description = "每个玩家回合开始时，失去1生命，获得10格挡。";
	definition.card_type = CardDefinition.CardType.POWER;
	definition.effects = [_power_effect()];
	return definition;


func _action(effects:Array[CombatEffectDefinition])->EnemyActionDefinition:
	var action:EnemyActionDefinition = EnemyActionDefinition.new();
	action.action_id = "test_cloak_action";
	action.intent_text = "测试行动";
	action.effects = effects;
	return action;


func _controller(cards:Array[CardDefinition], actions:Array[EnemyActionDefinition] = [])->BattleController:
	var encounter:EncounterDefinition = load("res://battle/encounters/data/cave_crawler_encounter.tres").duplicate();
	encounter.enemy_definition = encounter.enemy_definition.duplicate();
	if actions.is_empty():
		var block:CombatEffectDefinition = CombatEffectDefinition.new();
		block.effect_type = CombatEffectDefinition.EffectType.BLOCK;
		block.amount = 1;
		actions = [_action([block])]; # 敌人不造成伤害，便于观察披风失血。
	encounter.enemy_definition.action_pattern = actions;
	var deck:Array[CardDefinition] = cards.duplicate();
	deck.append(load("res://cards/data/defend.tres"));
	deck.append(load("res://cards/data/defend.tres"));
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(encounter, load("res://combatants/players/data/player.tres"), deck, 50, 50), "回合开始能力测试应能启动");
	return controller;


func _play_powers(controller:BattleController)->void:
	for card in controller.battle_state.hand.duplicate():
		if card.definition.card_type == CardDefinition.CardType.POWER:
			controller._on_card_selected(card);


func _test_activation_and_repetition()->void:
	var controller:BattleController = _controller([_card()]);
	var state:BattleState = controller.battle_state;
	_play_powers(controller);
	_expect(state.player_state.current_health == 50 and state.player_state.current_block == 0 and state.current_available_energy == 2, "1费只获得能力，不立即触发");
	_expect(state.played_power_cards.size() == 1 and controller.player_view.power_label.text == "能力：血红披风", "正常退出牌堆循环并显示能力");
	state.player_state.gain_strength(10);
	state.player_state.apply_weak(3, false);
	state.player_state.apply_vulnerable(3, false);
	state.prevent_draw_for_turn();
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_health == 49 and state.player_state.current_block == 10, "下个玩家回合触发一次，失血不受攻击状态影响");
	_expect(state.hand.size() == 2 and not state.draw_blocked_this_turn, "存活后解除旧禁抽并正常抽牌");
	controller._refresh_battle_view();
	controller._refresh_battle_view();
	_expect(state.player_state.current_health == 49, "刷新界面不重复触发能力");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_health == 48 and state.player_state.current_block == 10 and state.current_turn_number == 3, "以后每个玩家回合继续触发，旧格挡先清空");
	controller.get_parent().queue_free();


func _test_retained_block()->void:
	for retains in [false, true]:
		var controller:BattleController = _controller([_card()]);
		var state:BattleState = controller.battle_state;
		_play_powers(controller);
		if retains:
			state.player_state.apply_power(load("res://battle/powers/data/retain_block.tres"));
		state.player_state.gain_block(7);
		controller._on_end_turn_button_pressed();
		_expect(state.player_state.current_block == (17 if retains else 10), "先按坚城处理旧格挡，再增加披风的10格挡");
		_expect(state.player_state.current_health == 49, "保留格挡不会抵消披风的直接失血");
		controller.get_parent().queue_free();


func _test_stacking()->void:
	var first:CardDefinition = _card();
	var second:CardDefinition = _card();
	second.exhausts_on_play = true;
	var controller:BattleController = _controller([first, second]);
	var state:BattleState = controller.battle_state;
	_play_powers(controller);
	_expect(state.player_state.powers.size() == 2 and state.played_power_cards.size() == 1 and state.exhaust_pile.size() == 1, "每次施加保留一份，来源卡消耗不移除能力");
	controller._on_end_turn_button_pressed();
	_expect(state.player_state.current_health == 48 and state.player_state.current_block == 20, "两份分别失血并获得格挡");
	_expect(controller.player_view.power_label.text == "能力：血红披风、血红披风", "能力列表显示两份披风");
	_expect(first.effects[0].power_definition.health_loss == 1 and first.effects[0].power_definition.block_gain == 10 and not state.is_invalid_battle(), "重复施加不修改静态数值，牌区守恒");
	controller.get_parent().queue_free();


func _test_lethal_interruption()->void:
	for values in [[1, 3, 0], [2, 2, 10]]:
		var cards:Array[CardDefinition] = [];
		for index in range(values[1]):
			cards.append(_card());
		var controller:BattleController = _controller(cards);
		var state:BattleState = controller.battle_state;
		_play_powers(controller);
		state.player_state.current_health = values[0];
		var results:Array[bool] = [];
		controller.battle_finished.connect(func(victory:bool, health:int, _max_health:int)->void:
			results.append(victory);
			_expect(not victory and health == 0 and state.player_state.current_block == values[2], "致死后保留此前已获得格挡，不再执行后续格挡");
			_expect(state.hand.is_empty() and state.discard_pile.size() == 2 and state.draw_pile.is_empty(), "致死后不抽牌，也不洗弃牌堆");
		);
		controller._on_end_turn_button_pressed();
		controller._on_end_turn_button_pressed();
		controller.action_queue.resolve_all();
		_expect(results.size() == 1 and state.current_phase == BattleState.BattlePhase.FINISHED, "只报告一次失败，不恢复可操作阶段");
		_expect(state.played_power_cards.size() == values[1] and not state.is_invalid_battle(), "能力来源卡早已归档，致死时不重复归档");
		controller.get_parent().queue_free();


func _test_cost_and_new_battle()->void:
	var definition:CardDefinition = _card();
	var controller:BattleController = _controller([definition]);
	var state:BattleState = controller.battle_state;
	state.current_available_energy = 0;
	_play_powers(controller);
	_expect(state.player_state.powers.is_empty() and state.hand.size() == 3, "费用不足不能获得能力或移牌");
	state.gain_energy(1);
	_play_powers(controller);
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), [definition], 40, 50), "新战斗应能启动");
	_expect(controller.battle_state.player_state.powers.is_empty() and controller.battle_state.player_state.current_health == 40 and controller.battle_state.player_state.current_block == 0, "新战斗不继承能力，也不误触发起手失血");
	_expect(controller.battle_state.hand.size() == 1 and not controller.player_view.power_label.visible, "来源卡重新入牌组，旧能力提示清空");
	controller.get_parent().queue_free();


func _test_owner_turn()->void:
	var block_attack:CombatEffectDefinition = CombatEffectDefinition.new();
	block_attack.effect_type = CombatEffectDefinition.EffectType.DAMAGE;
	block_attack.target_type = CombatEffectDefinition.TargetType.OPPONENT;
	block_attack.damage_source = CombatEffectDefinition.DamageSource.CURRENT_BLOCK;
	var controller:BattleController = _controller([], [_action([_power_effect()]), _action([block_attack])]);
	var state:BattleState = controller.battle_state;
	controller._on_end_turn_button_pressed();
	_expect(state.enemy_state.current_health == 30 and state.player_state.current_health == 50, "敌人获得能力时与随后的玩家回合均不立即触发");
	_expect(controller.enemy_view.intent_label.text.contains("10"), "敌人按格挡攻击预览包含即将触发的能力格挡");
	controller._on_end_turn_button_pressed();
	_expect(state.enemy_state.current_health == 29 and state.enemy_state.current_block == 10 and state.player_state.current_health == 40, "共享能力按持有者自身回合触发，先获得格挡再执行行动");
	state.enemy_state.current_health = 1;
	controller._on_end_turn_button_pressed();
	_expect(state.is_victory() and state.enemy_state.current_block == 0 and state.enemy_state.powers.size() == 1, "敌人回合开始失血致死也停止后续格挡与行动");
	controller.get_parent().queue_free();
