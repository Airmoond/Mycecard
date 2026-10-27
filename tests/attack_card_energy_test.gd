## 无尽之力：先付费后触发已有回能，每张攻击牌一次，注册、叠加与回合到期。
extends SceneTree

var _failures:int = 0;


func _initialize()->void:
	_run.call_deferred();


func _run()->void:
	_test_activation_and_stacking();
	_test_card_type_and_weapon();
	_test_payment_and_timing();
	_test_health_loss_interruption();
	_test_lethal_attack();
	_test_expiration();
	_test_new_battle();
	await process_frame;
	print("攻击牌回能检查完成，失败数：%d" % _failures);
	quit(0 if _failures == 0 else 1);


func _expect(condition:bool, message:String)->void:
	if not condition:
		_failures += 1;
		push_error(message);


func _buff()->CardDefinition:
	var definition:CardDefinition = load("res://cards/data/strike.tres").duplicate();
	definition.card_id = "test_endless_power";
	definition.card_name = "测试无尽之力";
	definition.description = "消耗。造成6伤害。本回合后续每打出一张攻击牌回复1能量。";
	definition.base_energy_cost = 0;
	definition.exhausts_on_play = true;
	var effect:CombatEffectDefinition = CombatEffectDefinition.new();
	effect.effect_type = CombatEffectDefinition.EffectType.GAIN_ATTACK_CARD_ENERGY;
	effect.amount = 1;
	definition.effects = [definition.effects[0], effect];
	return definition;


func _controller(cards:Array[CardDefinition])->BattleController:
	var page:Control = load("res://battle/battle.tscn").instantiate();
	root.add_child(page);
	var controller:BattleController = page.get_node("battle_controller");
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), cards, 50, 50), "攻击牌回能测试应能启动");
	return controller;


func _play(controller:BattleController, definition:CardDefinition)->void:
	for card in controller.battle_state.hand:
		if card.definition == definition:
			controller._on_card_selected(card);
			return;
	_expect(false, "测试卡应在手牌中");


func _test_activation_and_stacking()->void:
	var first:CardDefinition = _buff();
	var second:CardDefinition = _buff();
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	var controller:BattleController = _controller([first, second, strike]);
	var state:BattleState = controller.battle_state;
	_play(controller, first);
	_expect(state.current_available_energy == 3 and state.attack_card_energy_this_turn == 1 and state.exhaust_pile.size() == 1, "第一张0费攻击不触发自身，消耗后效果保留");
	_play(controller, second);
	_expect(state.current_available_energy == 4 and state.attack_card_energy_this_turn == 2 and state.exhaust_pile.size() == 2, "第二张先由已有1层回能，再叠加到2");
	_play(controller, strike);
	_expect(state.current_available_energy == 5 and state.enemy_state.current_health == 12, "后续1费攻击先付费再回2能量，伤害照常结算");
	_expect(controller.energy_label.tooltip_text.contains("回复2能量") and state.energy_per_turn == 3, "能量悬停说明当前回能额度，基础能量不变");
	_expect(not state.is_invalid_battle(), "回能不复制或丢失卡牌");
	controller.get_parent().queue_free();


func _test_card_type_and_weapon()->void:
	var buff:CardDefinition = _buff();
	var multihit:CardDefinition = load("res://cards/data/strike.tres").duplicate(true);
	multihit.effects[0].amount = 1;
	multihit.effects[0].repeat_count = 3;
	var skill:CardDefinition = load("res://cards/data/strike.tres").duplicate();
	skill.card_type = CardDefinition.CardType.SKILL;
	var zero_cost:CardDefinition = load("res://cards/data/strike.tres").duplicate(true);
	zero_cost.base_energy_cost = 0;
	zero_cost.effects[0].is_attack_damage = false;
	var weapon:CardDefinition = CardDefinition.new();
	weapon.card_id = "test_energy_weapon";
	weapon.card_name = "测试武器";
	weapon.description = "用于检查武器攻击不回能。";
	weapon.card_type = CardDefinition.CardType.WEAPON;
	weapon.weapon_definition = WeaponDefinition.new();
	weapon.weapon_definition.base_attack = 2;
	var controller:BattleController = _controller([buff, multihit, skill, zero_cost, weapon]);
	var state:BattleState = controller.battle_state;
	_play(controller, buff);
	_play(controller, multihit);
	_expect(state.current_available_energy == 3, "三段攻击只按一张牌回能一次");
	_play(controller, skill);
	_expect(state.current_available_energy == 2, "技能即使造成攻击伤害也不触发攻击牌回能");
	_play(controller, zero_cost);
	_expect(state.current_available_energy == 3, "0费攻击牌也触发，依据卡牌类型而非伤害类别");
	_play(controller, weapon);
	controller._on_weapon_attack_requested();
	_expect(state.current_available_energy == 3 and state.hand.is_empty(), "装备武器与独立武器攻击均不触发回能");
	controller.get_parent().queue_free();


func _test_payment_and_timing()->void:
	var buff:CardDefinition = _buff();
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	var controller:BattleController = _controller([buff, strike]);
	var state:BattleState = controller.battle_state;
	state.current_available_energy = 0;
	_play(controller, buff);
	var card:CardInstance = state.hand[0];
	_expect(not controller._card_is_playable(card), "不能用即将获得的回能支付当前费用");
	controller._on_card_selected(card);
	_expect(state.current_available_energy == 0 and state.hand.has(card) and state.enemy_state.current_health == 24, "费用不足不回能、不移牌、不造成伤害");
	state.gain_energy(1);
	_expect(state.begin_card_play(card), "费用足够时成功开始出牌");
	_expect(state.current_available_energy == 1 and state.resolving_card == card and state.enemy_state.current_health == 24, "扣费后立即回能，此时尚未执行伤害");
	_expect(not state.begin_card_play(card) and state.current_available_energy == 1, "同一张结算中卡不能重复触发");
	controller._queue_card_effect(card);
	controller.action_queue.resolve_all();
	state.finish_card_play();
	_expect(not state.begin_card_play(card) and state.current_available_energy == 1 and state.enemy_state.current_health == 18, "归档后的重复提交不再次回能");
	controller.get_parent().queue_free();


func _test_health_loss_interruption()->void:
	var loss:CombatEffectDefinition = CombatEffectDefinition.new();
	loss.effect_type = CombatEffectDefinition.EffectType.LOSE_HEALTH;
	loss.amount = 50;
	var buff:CardDefinition = _buff();
	var lethal:CardDefinition = _buff();
	lethal.base_energy_cost = 1;
	lethal.effects.push_front(loss);
	var controller:BattleController = _controller([buff, lethal]);
	var state:BattleState = controller.battle_state;
	_play(controller, buff);
	_play(controller, lethal);
	_expect(state.is_defeat() and state.current_available_energy == 3, "回能已在效果前发生，随后失血致死也不撤回");
	_expect(state.attack_card_energy_this_turn == 1 and state.enemy_state.current_health == 24 and state.exhaust_pile.size() == 2, "致死中断后续伤害和注册，卡牌仍消耗归档");
	controller.get_parent().queue_free();
	controller = _controller([lethal]);
	_play(controller, lethal);
	_expect(controller.battle_state.attack_card_energy_this_turn == 0, "没有执行到注册效果时不能提前获得回能额度");
	controller.get_parent().queue_free();


func _test_lethal_attack()->void:
	var buff:CardDefinition = _buff();
	var strike:CardDefinition = load("res://cards/data/strike.tres");
	var controller:BattleController = _controller([buff, strike]);
	var state:BattleState = controller.battle_state;
	_play(controller, buff);
	state.enemy_state.current_health = 1;
	var results:Array[bool] = [];
	controller.battle_finished.connect(func(victory:bool, _health:int, _max_health:int)->void:
		results.append(victory);
		_expect(victory and state.current_available_energy == 3 and state.discard_pile.size() == 1 and state.resolving_card == null, "致命攻击在胜利报告前完成回能与归档");
	);
	_play(controller, strike);
	controller._check_battle_result();
	_expect(results.size() == 1, "结果只报告一次");
	controller.get_parent().queue_free();


func _test_expiration()->void:
	for enemy_kills in [false, true]:
		var buff:CardDefinition = _buff();
		var strike:CardDefinition = load("res://cards/data/strike.tres");
		var controller:BattleController = _controller([buff, strike]);
		var state:BattleState = controller.battle_state;
		_play(controller, buff);
		if enemy_kills:
			state.player_state.current_health = 1;
			controller.battle_finished.connect(func(_victory:bool, _health:int, _max_health:int)->void:
				_expect(state.attack_card_energy_this_turn == 0, "在敌人行动前失效，即使未进入下一玩家回合");
			);
		controller._on_end_turn_button_pressed();
		_expect(state.attack_card_energy_this_turn == 0 and controller.energy_label.tooltip_text.is_empty(), "回合结束清除额度与提示");
		if not enemy_kills:
			_play(controller, strike);
			_expect(state.current_available_energy == 2, "下一回合攻击牌不再回能");
		controller.get_parent().queue_free();


func _test_new_battle()->void:
	var buff:CardDefinition = _buff();
	var controller:BattleController = _controller([buff]);
	_play(controller, buff);
	_expect(controller.start_battle(load("res://battle/encounters/data/cave_crawler_encounter.tres"), load("res://combatants/players/data/player.tres"), [buff], 50, 50), "可开始新战斗");
	var state:BattleState = controller.battle_state;
	_expect(state.attack_card_energy_this_turn == 0 and state.current_available_energy == 3 and state.exhaust_pile.is_empty(), "新战斗清空回能与消耗记录");
	_play(controller, buff);
	_expect(state.attack_card_energy_this_turn == 1 and state.current_available_energy == 3, "重新获得效果也不触发自身");
	controller.get_parent().queue_free();
